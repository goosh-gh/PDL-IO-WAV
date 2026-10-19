package PDL::IO::WAV;

use strict;
use warnings;
use Carp qw(croak);
use PDL::LiteF;

our $VERSION = '0.01';

use Exporter 'import';
our @EXPORT      = qw(rwav wwav);
our @EXPORT_OK   = qw(wav_header);
our %EXPORT_TAGS = (all => [@EXPORT, @EXPORT_OK]);

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

my $BIG_ENDIAN = (unpack('N', pack('L', 1)) == 1) ? 1 : 0;

# One sysread()/syswrite() call never moves more than this many bytes
# (read() with a count above INT_MAX fails with EINVAL on macOS).
my $IO_MAX = 1 << 28;

# Frames per block for the paths that convert while streaming
# (24-bit pack/unpack, float -> PCM quantisation, ...).
our $BLOCK = 1 << 17;

# Tail of the KSDATAFORMAT_SUBTYPE_* GUIDs used by WAVE_FORMAT_EXTENSIBLE;
# the first two bytes of the GUID are the plain format tag (1 = PCM, 3 = float).
my $GUID_TAIL = "\x00\x00\x00\x00\x10\x00\x80\x00\x00\xAA\x00\x38\x9B\x71";

# Speaker masks written for WAVE_FORMAT_EXTENSIBLE files (same defaults as ffmpeg).
my %DEFAULT_MASK = (1 => 0x4, 2 => 0x3, 3 => 0x7, 4 => 0x33,
                    5 => 0x37, 6 => 0x3F, 7 => 0x13F, 8 => 0x63F);

# ---------------------------------------------------------------------------
# Low-level helpers
# ---------------------------------------------------------------------------

# PDL type for (format, container bits); 24-bit PCM is returned as long.
sub _ptype {
    my ($format, $bits) = @_;
    if ($format eq 'pcm') {
        return byte()  if $bits == 8;
        return short() if $bits == 16;
        return long()  if $bits == 24 || $bits == 32;
    }
    elsif ($format eq 'float') {
        return float()  if $bits == 32;
        return double() if $bits == 64;
    }
    return;
}

# Read exactly $nbytes into $$bufref starting at buffer offset 0, from the
# current file position.  sysread() with an offset writes in place, so a
# pre-sized ndarray buffer is filled without being reallocated.
sub _read_exact {
    my ($fh, $bufref, $nbytes, $file) = @_;
    my $got = 0;
    $$bufref = '' if $nbytes == 0;
    while ($got < $nbytes) {
        my $want = $nbytes - $got;
        $want = $IO_MAX if $want > $IO_MAX;
        my $r = sysread($fh, $$bufref, $want, $got);
        croak "$file: read error: $!" unless defined $r;
        croak "$file: unexpected end of file (wanted $nbytes bytes, got $got)"
            if $r == 0;
        $got += $r;
    }
    return $got;
}

sub _write_all {
    my ($fh, $dataref, $file) = @_;
    my $len = length $$dataref;
    my $off = 0;
    while ($off < $len) {
        my $want = $len - $off;
        $want = $IO_MAX if $want > $IO_MAX;
        my $w = syswrite($fh, $$dataref, $want, $off);
        croak "$file: write error: $!" unless defined $w;
        $off += $w;
    }
    return;
}

sub _bswap {
    my ($x, $bits) = @_;
    return $x unless $BIG_ENDIAN && $bits > 8;
    $x->bswap2 if $bits == 16;
    $x->bswap4 if $bits == 32;
    $x->bswap8 if $bits == 64;
    return $x;
}

# A zero-copy view: a new ndarray of $type and @dims that shares the memory of
# $parent starting at byte $off.  Writes through the view change the parent.
# PDL up to 2.085 has PDL::set_data_by_offset (the call PDL::IO::FlexRaw::mapflex
# used); PDL 2.104 has no such method, and mapflex uses PDL->new_around_datasv
# on the parent's data scalar instead, which this does as well.
sub _view {
    my ($type, $parent, $off, @dims) = @_;
    my $v;
    if (PDL->can('set_data_by_offset')) {
        # type and dims are set on an empty ndarray, so nothing is allocated for the view
        # (new_from_specification + get_dataref would allocate and zero a full-size buffer)
        $v = PDL->initialize;
        $v->set_datatype($type->enum);
        $v->setdims(\@dims);
        eval { $parent->get_dataref };  # allocate a lazily created parent (dies for a mapped file: fine)
        $v->set_data_by_offset($parent, $off);
    } else {
        my $dsv = $parent->get_dataref;                 # reference to the parent's data scalar
        # a very small ndarray keeps its data inside the struct; get_dataref then made a copy in
        # the scalar, so point the parent at that scalar to make both share one buffer
        # (refused for a mapped file, whose data already is the scalar: fine)
        eval { $parent->upd_data(1) };
        my $len = 1; $len *= $_ for @dims;
        $len *= PDL::Core::howbig($type);
        $v = PDL->new_around_datasv(0 + $dsv, $off);    # keeps a reference count on the scalar
        $v->set_datatype($type->enum);
        $v->setdims(\@dims);
        $v->set_donttouchdata($len);
    }
    return $v;
}

# ---------------------------------------------------------------------------
# Header parsing
# ---------------------------------------------------------------------------

sub _scan {
    my ($fh, $fsize, $file) = @_;
    $fsize >= 12 or croak "$file: too short to be a WAV file";

    my $buf = '';
    sysseek($fh, 0, 0);
    _read_exact($fh, \$buf, 12, $file);
    my ($container, undef, $form) = unpack 'a4 V a4', $buf;
    ($container eq 'RIFF' || $container eq 'RF64') && $form eq 'WAVE'
        or croak "$file: not a RIFF/WAVE file";

    my %h = (container => $container, chunks => []);
    my ($fmt, $ds64_data);
    my $pos = 12;

    while ($pos + 8 <= $fsize) {
        sysseek($fh, $pos, 0) or croak "$file: seek failed: $!";
        _read_exact($fh, \$buf, 8, $file);
        my ($id, $size) = unpack 'a4 V', $buf;
        my $body = $pos + 8;

        if ($id eq 'ds64' && !defined $ds64_data) {
            $size >= 24 or croak "$file: ds64 chunk too short";
            _read_exact($fh, \$buf, 24, $file);
            my (undef, undef, $dlo, $dhi) = unpack 'V V V V', $buf;
            $ds64_data = $dlo + $dhi * 4294967296;
        }
        elsif ($id eq 'fmt ' && !defined $fmt) {
            $size >= 16 or croak "$file: fmt chunk too short";
            my $n = $size < 40 ? $size : 40;
            _read_exact($fh, \$buf, $n, $file);
            $fmt = $buf;
        }
        elsif ($id eq 'data' && !defined $h{data_offset}) {
            defined $fmt or croak "$file: data chunk before fmt chunk";
            $size = $ds64_data if $size == 0xFFFFFFFF && defined $ds64_data;
            my $avail = $fsize - $body;
            if ($size > $avail) {       # truncated file, or a streaming writer's 0xFFFFFFFF
                $size = $avail;
                $h{truncated} = 1;
            }
            $h{data_offset} = $body;
            $h{data_bytes}  = $size;
        }

        push @{ $h{chunks} }, [$id, $body, $size];
        $pos = $body + $size + ($size & 1);
    }

    defined $fmt              or croak "$file: no fmt chunk";
    defined $h{data_offset}   or croak "$file: no data chunk";

    my ($tag, $ch, $rate, undef, $align, $bits) = unpack 'v v V V v v', $fmt;
    $h{extensible} = 0;
    $h{valid_bits} = $bits;
    if ($tag == 0xFFFE) {
        length($fmt) >= 40 or croak "$file: WAVE_FORMAT_EXTENSIBLE with a short fmt chunk";
        my ($cb, $valid, $mask) = unpack 'v v V', substr($fmt, 16, 8);
        my $guid = substr($fmt, 24, 16);
        substr($guid, 2) eq $GUID_TAIL
            or croak "$file: unsupported WAVE_FORMAT_EXTENSIBLE SubFormat";
        $tag = unpack 'v', $guid;
        @h{qw(extensible valid_bits channel_mask)} = (1, $valid, $mask);
    }

    my $format = $tag == 1 ? 'pcm' : $tag == 3 ? 'float' : undef;
    defined $format
        or croak "$file: unsupported format tag $tag (only integer PCM and IEEE float)";
    $ch >= 1 or croak "$file: zero channels";
    $bits % 8 == 0 && defined _ptype($format, $bits)
        or croak "$file: unsupported sample format ($format, $bits bits)";
    $align == $ch * $bits / 8
        or croak "$file: block alignment $align does not match $ch channels x $bits bits";

    @h{qw(format channels rate bits block_align)} = ($format, $ch, $rate, $bits, $align);
    $h{type}   = '' . _ptype($format, $bits);
    $h{frames} = int($h{data_bytes} / $align);
    return \%h;
}

sub wav_header {
    my ($file) = @_;
    defined $file or croak 'wav_header: file name required';
    open my $fh, '<:raw', $file or croak "wav_header: cannot open $file: $!";
    my $h = _scan($fh, -s $fh, $file);
    close $fh;
    return $h;
}

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

# 24-bit PCM -> long without a Perl loop over samples.  The long array is
# allocated once; a byte view of it receives each 3-byte sample in the upper
# three bytes of its 32-bit word (sample << 8), and one in-place arithmetic
# shift right by 8 then sign-extends everything.
sub _read_pcm24 {
    my ($fh, $h, $off, $n, $file) = @_;
    my $ch = $h->{channels};
    my $x  = zeroes(long(), $ch, $n);
    my $xb = _view(byte(), $x, 0, 4, $ch * $n);
    sysseek($fh, $off, 0) or croak "$file: seek failed: $!";
    for (my $s = 0; $s < $n; $s += $BLOCK) {
        my $m  = $n - $s < $BLOCK ? $n - $s : $BLOCK;
        my $in = PDL->new_from_specification(byte(), 3, $ch * $m);
        _read_exact($fh, $in->get_dataref, 3 * $ch * $m, $file);
        $in->upd_data;
        # One 1-D strided assignment per byte lane: a single (3, N) assignment has
        # a tiny inner dimension, which PDL loops over about 1.5x slower.
        my $range = ($ch * $s) . ':' . ($ch * ($s + $m) - 1);
        for my $k (0 .. 2) {
            my $slot = $BIG_ENDIAN ? $k : $k + 1;       # word byte that receives file byte $k
            my $lane = $BIG_ENDIAN ? 2 - $k : $k;       # BE: file byte 0 is the least significant
            $xb->slice("($slot),$range") .= $in->slice("($lane)");
        }
    }
    $x->inplace->shiftright(8);
    return $x;
}

sub _read_frames {
    my ($fh, $h, $start, $n, $file) = @_;
    my ($ch, $bits) = @$h{qw(channels bits)};
    my $off = $h->{data_offset} + $start * $h->{block_align};
    my $pt  = _ptype($h->{format}, $bits);

    return zeroes($pt, $ch, 0) if $n == 0;
    return _read_pcm24($fh, $h, $off, $n, $file)
        if $h->{format} eq 'pcm' && $bits == 24;

    my $x = PDL->new_from_specification($pt, $ch, $n);
    sysseek($fh, $off, 0) or croak "$file: seek failed: $!";
    _read_exact($fh, $x->get_dataref, $n * $h->{block_align}, $file);
    $x->upd_data;
    return _bswap($x, $bits);
}

sub rwav {
    my ($file, %opt) = @_;
    defined $file or croak 'rwav: file name required';
    my %known = map { $_ => 1 } qw(start frames normalize signed mmap);
    for my $k (sort keys %opt) {
        croak "rwav: unknown option '$k'" unless $known{$k};
    }
    my $norm = $opt{normalize};
    if ($norm) {
        $norm =~ /\A(?:1|float|double)\z/i
            or croak "rwav: normalize must be 1, 'double' or 'float'";
    }

    open my $fh, '<:raw', $file or croak "rwav: cannot open $file: $!";
    my $fsize = -s $fh;
    my $h = _scan($fh, $fsize, $file);

    my $start = $opt{start} // 0;
    $start == int($start) && $start >= 0 && $start <= $h->{frames}
        or croak "rwav: start must be an integer in 0..$h->{frames}";
    my $count = $opt{frames} // ($h->{frames} - $start);
    $count == int($count) && $count >= 0
        or croak 'rwav: frames must be a non-negative integer';
    $count = $h->{frames} - $start if $start + $count > $h->{frames};
    @$h{qw(read_start read_frames mmap)} = ($start, $count, 0);

    my ($ch, $bits, $format) = @$h{qw(channels bits format)};
    my $x;

    # Optional memory-mapped view (needs File::Map; little-endian host; not 24-bit)
    if ($opt{mmap} && $count > 0 && !$BIG_ENDIAN && !($format eq 'pcm' && $bits == 24)
        && eval { require File::Map; 1 }) {
        my $map = eval {
            my $d = PDL->zeroes(byte());
            # not shared + writable = copy-on-write private mapping, so stray
            # in-place operations cannot crash or touch the file
            $d->set_data_by_file_map($file, $fsize, 0, 1, 0, 0644, 0);
            $d;
        };
        if ($map) {
            $x = _view(_ptype($format, $bits), $map,
                       $h->{data_offset} + $start * $h->{block_align}, $ch, $count);
            $h->{mmap} = 1;
        }
    }
    $x = _read_frames($fh, $h, $start, $count, $file) unless defined $x;
    close $fh;

    if ($norm) {
        my $nt = lc($norm) eq 'float' ? float() : double();
        if ($format eq 'pcm') {
            my $y = $x->convert($nt);       # integer -> float always makes a new array
            $y -= 128 if $bits == 8;        # 8-bit PCM is unsigned, centred on 128
            $y *= 2 ** -($bits - 1);        # power of two: exact
            $x = $y;
        }
        else {
            $x = $x->convert($nt);
        }
        $h->{mmap} = 0;
    }
    elsif ($opt{signed} && $format eq 'pcm' && $bits == 8) {
        $x = ($x - 128)->sbyte;             # byte arithmetic wraps modulo 256
        $h->{mmap} = 0;
    }

    return wantarray ? ($x, $h) : $x;
}

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

# float/double (-1..1) -> integer PCM of $bits: scaled by 2**(bits-1),
# rounded half to even, clipped to the representable range.
sub _quantize {
    my ($c, $bits) = @_;
    # A sum is NaN or Inf as soon as one element is.  Two-stage sumover is about
    # five times faster than ->sum on a (ch, m) block.
    my $s = $c->sumover->sumover->sclr;
    $s == $s && $s > -9**9**9 && $s < 9**9**9
        or croak 'wwav: NaN or Inf in the data cannot be written as PCM';
    my $scale = 2 ** ($bits - 1);
    my $y = $c->double * $scale;            # a new array even for double input
    $y->inplace->rint;
    $y->inplace->clip(-$scale, $scale - 1);
    if ($bits == 8) {                       # 8-bit PCM is unsigned, centred on 128
        $y += 128;
        return $y->byte;
    }
    return $bits == 16 ? $y->short : $y->long;
}

# long (ch, m) -> (3, ch*m) byte slice holding the low three bytes of each word
sub _low3 {
    my ($c) = @_;
    my $cp = $c->copy;                      # physical and contiguous
    my $nel = $cp->nelem;
    my $v  = _view(byte(), $cp, 0, 4, $nel);
    my $o  = PDL->new_from_specification(byte(), 3, $nel);
    for my $k (0 .. 2) {                    # 1-D strided copies, see _read_pcm24
        $o->slice("($k)") .= $v->slice('(' . ($BIG_ENDIAN ? 3 - $k : $k) . ')');
    }
    return $o;
}

sub _fmt_chunk {
    my (%p) = @_;
    my $tag   = $p{format} eq 'float' ? 3 : 1;
    my $align = $p{channels} * $p{bits} / 8;
    my @base  = ($p{channels}, $p{rate}, $p{rate} * $align, $align, $p{bits});
    if ($p{extensible}) {
        my $mask = $p{channel_mask} // $DEFAULT_MASK{ $p{channels} } // 0;
        return pack('v v V V v v  v v V  v', 0xFFFE, @base, 22, $p{bits}, $mask, $tag) . $GUID_TAIL;
    }
    return pack('v v V V v v', $tag, @base) if $tag == 1;
    return pack('v v V V v v  v', $tag, @base, 0);      # float: 18-byte fmt (cbSize = 0)
}

sub wwav {
    my ($file, $pdl, %opt) = @_;
    defined $file && length $file or croak 'wwav: file name required';
    UNIVERSAL::isa($pdl, 'PDL') or croak 'wwav: second argument must be an ndarray';
    my %known = map { $_ => 1 } qw(rate bits format extensible channel_mask);
    for my $k (sort keys %opt) {
        croak "wwav: unknown option '$k'" unless $known{$k};
    }

    my $rate = $opt{rate};
    defined $rate && $rate == int($rate) && $rate > 0 && $rate <= 0xFFFFFFFF
        or croak 'wwav: rate => samples per second is required';

    # dims: (channels, frames), or (frames) for mono
    my $nd = $pdl->ndims;
    my ($ch, $n);
    if    ($nd == 1) { ($ch, $n) = (1, $pdl->dim(0)) }
    elsif ($nd == 2) { ($ch, $n) = $pdl->dims }
    else {
        croak 'wwav: expected dims (channels, frames) or (frames), got ('
            . join(',', $pdl->dims) . ')';
    }
    ($ch >= 1 && $ch <= 1024)
        or croak "wwav: $ch channels - dims must be (channels, frames); use ->xchg(0,1) for (frames, channels)";

    my $tn = '' . $pdl->type;
    my $float_in = ($tn eq 'float' || $tn eq 'double') ? 1 : 0;
    my $format = $opt{format};
    my $bits   = $opt{bits};
    if (defined $format) {
        $format = lc $format;
        $format =~ /\A(?:pcm|float)\z/ or croak "wwav: format must be 'pcm' or 'float'";
    }
    else {
        # float input stays float unless bits asks for 8/16/24-bit PCM
        $format = ($float_in && (!defined $bits || $bits == 32 || $bits == 64)) ? 'float' : 'pcm';
    }

    my $mode;
    if (!$float_in) {
        $format eq 'pcm' or croak "wwav: format => 'float' needs a float or double ndarray";
        my %natural = (byte => 8, sbyte => 8, short => 16, long => 32);
        my $nat = $natural{$tn}
            // croak "wwav: unsupported ndarray type '$tn' (byte, sbyte, short, long, float, double)";
        $bits //= $nat;
        if    ($bits == $nat)                  { $mode = $tn eq 'sbyte' ? 'sbyte' : 'direct' }
        elsif ($tn eq 'long' && $bits == 24)   { $mode = 'pack24' }
        else {
            croak "wwav: cannot write $tn data as $bits-bit PCM "
                . '(integers are written as they are; only long -> 24 bit is allowed)';
        }
    }
    elsif ($format eq 'float') {
        my $nat = $tn eq 'float' ? 32 : 64;
        $bits //= $nat;
        $bits == 32 || $bits == 64 or croak 'wwav: float format needs bits => 32 or 64';
        $mode = $bits == $nat ? 'direct' : 'tofloat';
    }
    else {
        $bits //= 16;
        $bits =~ /\A(?:8|16|24|32)\z/ or croak 'wwav: PCM bits must be 8, 16, 24 or 32';
        $mode = 'quant';
    }

    my $align  = $ch * $bits / 8;
    my $dbytes = $n * $align;
    my $ext    = $opt{extensible} // ($ch > 2 ? 1 : 0);
    my $fmt    = _fmt_chunk(format => $format, channels => $ch, rate => $rate, bits => $bits,
                            extensible => $ext, channel_mask => $opt{channel_mask});
    my $fact   = $format eq 'float' ? pack('a4 V V', 'fact', 4, $n) : '';
    my $pad    = $dbytes & 1;
    my $riff   = 4 + 8 + length($fmt) + length($fact) + 8 + $dbytes + $pad;
    $riff <= 0xFFFFFFFF
        or croak 'wwav: data larger than 4 GiB would need RF64, which is not supported for writing';
    my $head = pack('a4 V a4', 'RIFF', $riff, 'WAVE')
             . pack('a4 V', 'fmt ', length $fmt) . $fmt . $fact
             . pack('a4 V', 'data', $dbytes);

    open my $fh, '>:raw', $file or croak "wwav: cannot write $file: $!";
    _write_all($fh, \$head, $file);

    # No conversion: the ndarray's own buffer is the data chunk.  (A memory-mapped
    # ndarray refuses get_dataref, or returns more than its data; it goes through
    # the block loop like any other case that needs a copy.)
    my $whole = ($mode eq 'direct' && !$BIG_ENDIAN && $n > 0) ? eval { $pdl->get_dataref } : undef;
    # PDL 2.104 gives a mapped view the scalar of the whole file: use it only if it is exactly the data
    undef $whole if defined $whole && length($$whole) != $pdl->nelem * PDL::Core::howbig($pdl->type);
    if (defined $whole) {
        _write_all($fh, $whole, $file);
    }
    else {
        my $flat = $nd == 1 ? $pdl->dummy(0, 1) : $pdl;      # (1, n) for mono input
        for (my $s = 0; $s < $n; $s += $BLOCK) {
            my $m = $n - $s < $BLOCK ? $n - $s : $BLOCK;
            my $c = $flat->slice(':,' . $s . ':' . ($s + $m - 1));
            my $out;
            if    ($mode eq 'direct') { $out = $c->copy }
            elsif ($mode eq 'sbyte')  { $out = ($c->short + 128)->byte }
            elsif ($mode eq 'tofloat'){ $out = $c->convert($bits == 32 ? float() : double()) }
            else {
                my $q = $mode eq 'quant' ? _quantize($c, $bits) : $c;
                if ($mode eq 'pack24' || $bits == 24) {
                    if ($mode eq 'pack24') {
                        ($q->minimum->minimum->sclr >= -8388608 && $q->maximum->maximum->sclr <= 8388607)
                            or croak 'wwav: value outside the 24-bit range (-8388608..8388607)';
                    }
                    $out = _low3($q);
                }
                else { $out = $q }
            }
            $out = $out->copy if $BIG_ENDIAN && $bits > 8 && $bits != 24;
            _bswap($out, $bits) if $bits != 24;
            my $ref = $out->get_dataref;
            _write_all($fh, $ref, $file);
        }
    }
    _write_all($fh, \"\0", $file) if $pad;
    close $fh or croak "wwav: error closing $file: $!";

    return { file => $file, rate => $rate, channels => $ch, bits => $bits,
             format => $format, frames => $n, extensible => $ext ? 1 : 0,
             bytes => 8 + $riff };
}

1;

__END__

=head1 NAME

PDL::IO::WAV - read and write WAV files as PDL ndarrays

=head1 SYNOPSIS

  use PDL;
  use PDL::IO::WAV;

  my ($x, $hdr) = rwav('in.wav');           # dims (channels, frames), type as stored
  my $y    = rwav('in.wav', normalize => 1);          # double, full scale = +-1
  my $part = rwav('in.wav', start => 48000, frames => 4800);
  my $view = rwav('big.wav', mmap => 1);              # no copy, nothing read until used

  wwav('out.wav', $x, rate => $hdr->{rate});          # written as it is
  wwav('out.wav', $y, rate => 48000, format => 'pcm', bits => 24);   # quantise to 24-bit PCM

  my $info = wav_header('in.wav');          # header only, no sample data is read

=head1 DESCRIPTION

A pure Perl/PDL reader and writer for RIFF/WAVE files.  Sample data is read
with C<sysread> straight into the ndarray's buffer, so a file is never held
in memory more than once, and nothing loops over samples in Perl.

=head1 DIMENSIONS AND TYPES

Data are always C<(channels, frames)>: the interleaved order of the file
(L R L R ...), so reading needs no rearranging.  A mono file is C<(1, frames)>.
Use C<< ->xchg(0,1) >> for C<(frames, channels)>.

  file                        ndarray type   values
  PCM  8 bit                  byte           0..255 as stored (unsigned, centre 128)
  PCM 16 bit                  short          as stored
  PCM 24 bit                  long           as stored, sign-extended (-2**23 .. 2**23-1)
  PCM 32 bit                  long           as stored
  float 32 bit                float          as stored
  float 64 bit                double         as stored

=head1 FUNCTIONS

=head2 rwav

  my ($x, $hdr) = rwav($file, %options);
  my $x         = rwav($file, %options);

Reads C<$file>; in scalar context only the ndarray is returned.

=over 4

=item start => $frame, frames => $count

Read only C<$count> frames beginning at frame C<$start> (default: from the
beginning to the end).  A count that runs past the end is clamped;
C<start> equal to the number of frames gives an empty C<(channels, 0)> ndarray.
Only the requested part of the file is read.

=item normalize => 1 | 'double' | 'float'

Return doubles (or floats) with full scale mapped to +-1: integer PCM is
divided by C<2**(bits-1)> (8-bit PCM: C<(x-128)/128>).  The scaling is by a
power of two, so it is exact.  Float files are only converted to the
requested type.

=item signed => 1

8-bit PCM only: return C<sbyte> (C<x-128>) instead of C<byte>.  Ignored when
C<normalize> is given.

=item mmap => 1

Return a view of the file instead of reading it: no copy is made and pages
are loaded when they are first touched.  Needs L<File::Map>.  The mapping is
private and copy-on-write, so changing the ndarray in place never changes the
file.  Not available for 24-bit PCM (a 3-byte sample cannot be viewed as an
ndarray type) or on a big-endian host; there C<rwav> reads normally.
C<< $hdr->{mmap} >> tells which happened.  Changing the length of a file that
is mapped is up to the operating system and can crash the process.

=back

The header hash contains

  container     'RIFF' or 'RF64'
  format        'pcm' or 'float'
  rate          samples per second
  channels, bits, block_align
  frames        frames in the data chunk (the whole file, not only what was read)
  type          name of the ndarray type returned for raw reads
  extensible    1 for WAVE_FORMAT_EXTENSIBLE
  valid_bits    bits that carry data (extensible files; otherwise = bits)
  channel_mask  speaker mask (extensible files only)
  data_offset, data_bytes   position and size of the sample data in the file
  truncated     1 if the data chunk claimed more than the file holds
  chunks        [[id, offset, size], ...] for every chunk in file order
  read_start, read_frames   what this call returned
  mmap          1 if the ndarray is a mapped view of the file

=head2 wwav

  my $info = wwav($file, $ndarray, rate => 48000, %options);

Writes C<$ndarray> of dims C<(channels, frames)> (or C<(frames)> for mono).
C<rate> is required.  Returns a hash with C<file>, C<rate>, C<channels>,
C<bits>, C<format>, C<frames>, C<extensible> and C<bytes> (file size).

What is written depends on the ndarray type:

  type          default output            other bits / format
  byte          8-bit PCM, as it is
  sbyte         8-bit PCM, stored as x+128
  short         16-bit PCM, as it is
  long          32-bit PCM, as it is      bits => 24: 24-bit PCM (values must be in range, else error)
  float         float 32                  bits => 64: float 64;  bits => 8|16|24: quantised PCM
  double        float 64                  bits => 32: float 32;  bits => 8|16|24: quantised PCM

=over 4

=item bits => 8 | 16 | 24 | 32 (| 64 for float)

=item format => 'pcm' | 'float'

For float or double input C<bits> of 8, 16 or 24 selects PCM and 32 or 64
selects float.  To write 32-bit I<PCM> from float data say
C<< format => 'pcm', bits => 32 >>.  Integer data are written as they are and
never rescaled: C<bits> must match the type (C<long> may be written as 24).

=item extensible => 1, channel_mask => $mask

Write WAVE_FORMAT_EXTENSIBLE.  It is used automatically above two channels.

=back

Quantising float data to PCM multiplies by C<2**(bits-1)>, rounds half to
even and clips to the code range (-2**(bits-1) .. 2**(bits-1)-1), so +1.0
becomes the largest code.  This is the inverse of C<normalize>: values that
sit on the grid round-trip exactly.  NaN and Inf are refused.  The conversion
is done block by block (see L</$BLOCK>), so memory use does not grow with the
file.

The file is a canonical 44-byte-header file for PCM with one or two channels;
float files have an 18-byte C<fmt > chunk and a C<fact> chunk; a pad byte
follows an odd-sized data chunk.  Data larger than 4 GiB are refused (RF64 is
read, not written).

=head2 wav_header

  my $hdr = wav_header($file);

The same header hash as C<rwav> returns, without reading any samples.

=head1 FORMATS

Read: integer PCM 8/16/24/32 bit and IEEE float 32/64 bit, plain or
WAVE_FORMAT_EXTENSIBLE (the SubFormat GUID decides PCM or float), in C<RIFF>
and C<RF64> files.  Chunks before and after the data chunk
(C<LIST>, C<JUNK>, ...) are skipped, odd-sized chunks are handled, a data
chunk that claims more than the file holds (truncated file, or a streaming
writer's C<0xFFFFFFFF>) reads to the end of the file.

An extensible file whose valid bits are fewer than its container (say 24 valid
bits in 32) is returned at container width, as stored.

Anything else (A-law, mu-law, ADPCM, ..., sample sizes that are not whole
bytes, a block alignment that does not match channels x bits) is refused with an
error.

=head1 VARIABLES

=head2 $BLOCK

C<$PDL::IO::WAV::BLOCK>: frames per block in the paths that convert while
streaming (24-bit, quantising, sbyte, float width).  Default 131072.

=head1 IMPLEMENTATION NOTES

Direct reads use C<sysread> with an offset into the ndarray's buffer.  24-bit
PCM is expanded without a Perl loop: a byte-typed view of the destination
C<long> array (C<set_data_by_offset> in PDL 2.085, C<new_around_datasv> in 2.104,
the calls L<PDL::IO::FlexRaw>'s C<mapflex> uses) receives the three file bytes of each sample in the upper three bytes of
its 32-bit word, and one in-place arithmetic shift right by 8 sign-extends the
whole array.  Writing 24-bit data is the reverse.  C<mmap> maps the file
through L<File::Map> and puts a typed view at the data offset.

=head1 SEE ALSO

L<PDL>, L<PDL::IO::FlexRaw>, L<File::Map>, and the article
L<https://pdl.perl.org/advent/blog/2024/12/13/music/> (writing audio from PDL).

=head1 AUTHOR

Shugo Suwazono E<lt>zvb10512@nifty.ne.jpE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
