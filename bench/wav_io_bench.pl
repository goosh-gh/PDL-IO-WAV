#!/usr/bin/env perl
# wav_io_bench.pl - time and peak memory of WAV reading/writing variants
#
# What it does:
#   Runs every variant below in its own perl process (so the peak resident
#   size of one variant is not polluted by the previous one) on a 10-minute,
#   48 kHz, 2-channel file and prints a table of time and peak RSS.
#   Variants named "old" are the code that PDL::IO::WAV replaced
#   (slurp -> substr -> assign to zeroes()); the others use the module.
#
# Usage:
#   perl -Ilib bench/wav_io_bench.pl [workdir]      # default workdir: /tmp/wav_io_bench
#     creates big16.wav and big24.wav in workdir on first use, then runs all variants
#   perl -Ilib bench/wav_io_bench.pl --one MODE FILE   # a single variant (used internally)
#
# Peak RSS: VmHWM from /proc on Linux; elsewhere the RSS at exit from ps(1).

use strict;
use warnings;
use Time::HiRes qw(time);
use PDL::LiteF;
use PDL::IO::WAV qw(:all);

$PDL::IO::WAV::BLOCK = $ENV{WAV_BLOCK} if $ENV{WAV_BLOCK};     # frames per internal block
my $RATE = 48000;
my $SECS = 600;

sub peak_rss_mb {
    if (open my $s, '<', "/proc/$$/status") {
        while (<$s>) { return $1 / 1024 if /^VmHWM:\s+(\d+)/ }
    }
    my $kb = `ps -o rss= -p $$`;
    return ($kb + 0) / 1024;
}

# ---- variants -------------------------------------------------------------------

# the old reader, as in extend_wav_plateau.pl (44-byte header assumed here)
sub read_old {
    my ($f, $type, $bps) = @_;
    open my $fh, '<:raw', $f or die;
    my $raw   = do { local $/; <$fh> };
    my $bytes = substr($raw, 44);
    my $n = length($bytes) / (2 * $bps);
    my $x = zeroes($type, 2, $n);
    ${ $x->get_dataref } = $bytes;
    $x->upd_data;
    return $x;
}

# 24-bit with plain PDL arithmetic: three long conversions, shifts, sign fix
sub read24_arith {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die;
    seek $fh, 44, 0;
    my $nb = (-s $f) - 44;
    my $b = PDL->new_from_specification(byte(), 3, $nb / 3);
    read($fh, ${ $b->get_dataref }, $nb) == $nb or die;
    $b->upd_data;
    my $v = $b->slice('(0)')->long + ($b->slice('(1)')->long << 8) + ($b->slice('(2)')->long << 16);
    $v -= ($v & 0x800000) << 1;
    return $v->reshape(2, $v->nelem / 2);
}

# 24-bit via a byte(4, N) staging array and a copy into the long's buffer (no view)
sub read24_stage {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die;
    seek $fh, 44, 0;
    my $nb = (-s $f) - 44;
    my $in = PDL->new_from_specification(byte(), 3, $nb / 3);
    read($fh, ${ $in->get_dataref }, $nb) == $nb or die;
    $in->upd_data;
    my $st = zeroes(byte(), 4, $nb / 3);
    $st->slice('1:3') .= $in;
    undef $in;
    my $x = PDL->new_from_specification(long(), 2, $nb / 6);
    ${ $x->get_dataref } = ${ $st->get_dataref };
    $x->upd_data;
    $x->inplace->shiftright(8);
    return $x;
}

sub write_old {
    my ($f, $x) = @_;
    my $data = ${ $x->get_dataref };
    my $hdr = pack('a4 V a4 a4 V v v V V v v a4 V', 'RIFF', 36 + length($data), 'WAVE', 'fmt ', 16,
                   1, 2, $RATE, $RATE * 4, 4, 16, 'data', length($data));
    open my $out, '>:raw', $f or die;
    print $out $hdr, $data;
    close $out;
}

my %mode = (
    read16_old     => sub { read_old($_[0], short(), 2) },
    read16_new     => sub { scalar rwav($_[0]) },
    read16_mmap    => sub { my $x = rwav($_[0], mmap => 1); $x->slice(':,1000:1100')->sum; $x },
    read16_window  => sub { scalar rwav($_[0], start => 300 * $RATE, frames => $RATE) },
    read16_norm    => sub { scalar rwav($_[0], normalize => 1) },
    read24_arith   => sub { read24_arith($_[0]) },
    read24_stage   => sub { read24_stage($_[0]) },
    read24_new     => sub { scalar rwav($_[0]) },
    write16_old    => sub { my $x = rwav($_[0]); my $t = time; write_old("$_[0].out", $x); $t },
    write16_new    => sub { my $x = rwav($_[0]); my $t = time; wwav("$_[0].out", $x, rate => $RATE); $t },
    write16_quant  => sub { my $x = rwav($_[0], normalize => 1); my $t = time; wwav("$_[0].out", $x, rate => $RATE, bits => 16); $t },
    write24_new    => sub { my $x = rwav($_[0]); my $t = time; wwav("$_[0].out", $x, rate => $RATE, bits => 24); $t },
);
# for the write_* variants only the write itself is timed (the read is set-up)
my %write_only = map { $_ => 1 } qw(write16_old write16_new write16_quant write24_new);

if (@ARGV && $ARGV[0] eq '--one') {
    my (undef, $name, $file) = @ARGV;
    my $t0 = time;
    my $r = $mode{$name}->($file);
    my $dt = $write_only{$name} ? time - $r : time - $t0;
    printf "%-14s %7.3f s   peak RSS %6.0f MB\n", $name, $dt, peak_rss_mb();
    unlink "$file.out";
    exit 0;
}

my $dir = shift @ARGV // '/tmp/wav_io_bench';
mkdir $dir unless -d $dir;
my ($f16, $f24) = ("$dir/big16.wav", "$dir/big24.wav");
unless (-s $f16) {
    my $n = $RATE * $SECS;
    my $x = short(((sequence(longlong, 2, $n) * 2654435761) % 65536) - 32768);
    wwav($f16, $x, rate => $RATE);
}
unless (-s $f24) {
    my $n = $RATE * $SECS;
    my $x = long(((sequence(longlong, 2, $n) * 2654435761) % 16777216) - 8388608);
    wwav($f24, $x, rate => $RATE, bits => 24);
}
printf "files: %s %.0f MB, %s %.0f MB   (10 min, 48 kHz, 2 ch)\n\n",
       $f16, (-s $f16) / 1e6, $f24, (-s $f24) / 1e6;

for my $name (qw(read16_old read16_new read16_mmap read16_window read16_norm
                 write16_old write16_new write16_quant
                 read24_arith read24_stage read24_new write24_new)) {
    my $file = $name =~ /24/ ? $f24 : $f16;
    system($^X, (map { "-I$_" } @INC[0 .. 0]), $0, '--one', $name, $file) == 0
        or print "$name: failed\n";
}
