# wwav -> rwav round trips, written bytes, quantisation rules, block boundaries.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use File::Temp qw(tempdir);
use PDL::LiteF;
use PDL::IO::WAV qw(:all);
use TestUtil;

my $tmp = tempdir(CLEANUP => 1);
my $f   = "$tmp/t.wav";

# deterministic integers in lo..hi with the extremes first (no PDL random numbers)
sub gen_int {
    my ($ch, $n, $lo, $hi) = @_;
    my $span = $hi - $lo + 1;
    my $x = ((sequence(longlong, $ch, $n) * 2654435761) % $span) + $lo;
    if ($n > 1) {
        $x->slice(':,0') .= $lo;
        $x->slice(':,1') .= $hi;
    }
    return $x;
}

# --- integer types, channel counts, frame counts ---------------------------------
my @int_cases = (
    # type    bits  lo           hi
    [ byte,   8,    0,           255        ],
    [ short,  16,   -32768,      32767      ],
    [ long,   32,   -2**31,      2**31 - 1  ],
);
for my $case (@int_cases) {
    my ($t, $bits, $lo, $hi) = @$case;
    for my $ch (1, 2, 3) {
        for my $n (0, 1, 2, 7, 1001) {
            my $x = gen_int($ch, $n, $lo, $hi)->convert($t);
            my $info = wwav($f, $x, rate => 22050);
            my $label = "$t ${ch}ch ${n}fr";
            my $h = wav_header($f);
            is_deeply([ @$h{qw(format bits channels frames rate)} ],
                      [ 'pcm', $bits, $ch, $n, 22050 ], "$label: header");
            is($h->{extensible}, $ch > 2 ? 1 : 0, "$label: extensible only above 2 channels");
            is(-s $f, $info->{bytes}, "$label: file size = reported bytes");
            my $y = rwav($f);
            ok(same($y, $x), "$label: round trip exact");
            is('' . $y->type, '' . $t, "$label: type kept");
        }
    }
}

# --- 24-bit PCM from long -------------------------------------------------------------
for my $ch (1, 2, 3) {
    for my $n (0, 1, 2, 7, 1001) {
        my $x = gen_int($ch, $n, -8388608, 8388607)->long;
        wwav($f, $x, rate => 48000, bits => 24);
        my $h = wav_header($f);
        is_deeply([ @$h{qw(format bits channels frames)} ], [ 'pcm', 24, $ch, $n ], "24bit ${ch}ch ${n}fr: header");
        ok(same(scalar rwav($f), $x), "24bit ${ch}ch ${n}fr: round trip exact");
        is(-s $f, 44 + ($ch > 2 ? 24 : 0) + 3 * $ch * $n + ((3 * $ch * $n) & 1), "24bit ${ch}ch ${n}fr: file size");
    }
}
eval { wwav($f, long(8388608, 0), rate => 8000, bits => 24) };
like($@, qr/24-bit range/, '24-bit: a value above the range is refused, not clipped');
eval { wwav($f, long(0, -8388609), rate => 8000, bits => 24) };
like($@, qr/24-bit range/, '24-bit: a value below the range is refused, not clipped');

# --- sbyte is written as unsigned 8-bit ----------------------------------------------------
{
    my $x = gen_int(2, 301, -128, 127)->convert(sbyte);
    wwav($f, $x, rate => 8000);
    my $y = rwav($f);
    is('' . $y->type, 'byte', 'sbyte input: read back as byte');
    ok(same($y, $x + 128), 'sbyte input: stored with +128');
    ok(same(scalar rwav($f, signed => 1), $x), 'sbyte input: signed => 1 gives the original back');
}

# --- float and double ---------------------------------------------------------------------------------
{
    my $d = (sequence(double, 3, 500) - 700) / 1024;           # exact in float32 too
    wwav($f, $d, rate => 44100);
    my $h = wav_header($f);
    is_deeply([ @$h{qw(format bits)} ], [ 'float', 64 ], 'double input -> float64 file');
    ok(same(scalar rwav($f), $d), 'float64 round trip exact');

    wwav($f, $d->float, rate => 44100);
    $h = wav_header($f);
    is_deeply([ @$h{qw(format bits)} ], [ 'float', 32 ], 'float input -> float32 file');
    ok(same(scalar rwav($f), $d), 'float32 round trip exact');

    wwav($f, $d->float, rate => 44100, bits => 64);
    is(wav_header($f)->{bits}, 64, 'float32 data written as float64');
    ok(same(scalar rwav($f), $d), 'float32 -> float64 file keeps the values');

    my $r = random(double, 2, 400) * 2 - 1;
    wwav($f, $r, rate => 44100, bits => 32);
    is(wav_header($f)->{format}, 'float', 'float input with bits => 32 stays float');
    ok(same(scalar rwav($f), $r->float), 'double -> float32 file equals ->float');
}

# --- exact bytes of the header --------------------------------------------------------------------------
{
    my $x = short([[1, -2], [3, 4], [5, 6]]);                    # dims (2,3): 3 stereo frames
    wwav($f, $x, rate => 8000);
    my $want = pack('a4 V a4 a4 V v v V V v v a4 V', 'RIFF', 36 + 12, 'WAVE', 'fmt ', 16,
                    1, 2, 8000, 8000 * 4, 4, 16, 'data', 12) . pack('s<*', 1, -2, 3, 4, 5, 6);
    is(slurp($f), $want, 'stereo 16-bit file: all bytes as expected (44-byte header)');

    my $m = float([0.5, -0.25]);
    wwav($f, $m, rate => 8000);
    $want = pack('a4 V a4 a4 V v v V V v v v', 'RIFF', 4 + 8 + 18 + 12 + 8 + 8, 'WAVE', 'fmt ', 18,
                 3, 1, 8000, 8000 * 4, 4, 32, 0)
          . pack('a4 V V', 'fact', 4, 2) . pack('a4 V', 'data', 8) . pack('f<*', 0.5, -0.25);
    is(slurp($f), $want, 'mono float32 file: fmt of 18 bytes, fact chunk, data');

    my $odd = byte([1, 2, 3]);
    wwav($f, $odd, rate => 8000);
    my $bytes = slurp($f);
    is(length $bytes, 44 + 4, '8-bit mono, 3 frames: pad byte after the data chunk');
    is(substr($bytes, 4, 4), pack('V', 36 + 4), 'RIFF size counts the pad byte');
    is(substr($bytes, 40, 4), pack('V', 3), 'data size does not count the pad byte');
}
{
    my $x = short(sequence(3, 4));
    wwav($f, $x, rate => 8000);
    my $bytes = slurp($f);
    is(unpack('v', substr($bytes, 20, 2)), 0xFFFE, '3 channels: WAVE_FORMAT_EXTENSIBLE');
    is(unpack('V', substr($bytes, 16, 4)), 40, 'extensible fmt chunk is 40 bytes');
    is(unpack('v', substr($bytes, 36, 2)), 22, 'cbSize 22');
    is(unpack('v', substr($bytes, 38, 2)), 16, 'valid bits 16');
    is(unpack('V', substr($bytes, 40, 4)), 0x7, '3 channels: speaker mask 0x7');
    is(unpack('v', substr($bytes, 44, 2)), 1, 'SubFormat tag PCM');
    is(substr($bytes, 46, 14), "\x00\x00\x00\x00\x10\x00\x80\x00\x00\xAA\x00\x38\x9B\x71", 'SubFormat GUID tail');
    is(substr($bytes, 60, 4), 'data', 'data chunk follows the 40-byte fmt chunk');
    my $h = wav_header($f);
    is($h->{channel_mask}, 0x7, 'header reads the mask back');

    wwav($f, short(sequence(2, 4)), rate => 8000, extensible => 1, channel_mask => 0x3);
    $h = wav_header($f);
    is_deeply([ @$h{qw(extensible channels channel_mask)} ], [ 1, 2, 3 ], 'extensible => 1 forces the long form');
    ok(same(scalar rwav($f), short(sequence(2, 4))), 'forced extensible file reads back');
}

# --- quantising float -> PCM -----------------------------------------------------------------------------------
for my $bits (8, 16, 24, 32) {
    my $scale = 2 ** ($bits - 1);
    my $k = gen_int(2, 999, -$scale, $scale - 1);                 # longlong grid
    my $x = $k->double / $scale;
    wwav($f, $x, rate => 8000, format => 'pcm', bits => $bits);
    my $h = wav_header($f);
    is_deeply([ @$h{qw(format bits)} ], [ 'pcm', $bits ], "quantise $bits: PCM $bits file");
    ok(same(scalar rwav($f, normalize => 1), $x), "quantise $bits: grid values come back exactly");
    ok(same(scalar rwav($f), $bits == 8 ? $k + 128 : $k), "quantise $bits: integer codes are x * 2^" . ($bits - 1));

    my $r = sin(sequence(double, 1, 4000) * 0.37) * 0.9;           # off the grid
    wwav($f, $r, rate => 8000, format => 'pcm', bits => $bits);
    my $err = (rwav($f, normalize => 1) - $r)->abs->max->sclr;
    cmp_ok($err, '<=', 1 / $scale * (1 + 1e-12), "quantise $bits: error within half an LSB (1/2^$bits)");

    # beyond full scale is clipped to the code range
    wwav($f, pdl(2, -2, 1, -1, 0.5)->dummy(0, 1), rate => 8000, format => 'pcm', bits => $bits);
    my $c = rwav($f, normalize => 1)->flat;
    my @want = (($scale - 1) / $scale, -1, ($scale - 1) / $scale, -1, 0.5);
    is_deeply([ $c->list ], \@want, "quantise $bits: +-2 and +1.0 are clipped to the code range");
}
{
    # round half to even, in 16 bits
    my $x = pdl(0.5, 1.5, 2.5, 3.5, -0.5, -1.5) / 32768;
    wwav($f, $x, rate => 8000, bits => 16);
    is_deeply([ rwav($f)->flat->list ], [ 0, 2, 2, 4, 0, -2 ], 'quantise 16: halves round to even');
}
{
    my $x = float(sequence(1, 100)) / 128 - 0.3;
    wwav($f, $x, rate => 8000, bits => 16);
    ok(same(scalar rwav($f), ($x->double * 32768)->rint->short), 'quantise 16: float32 input');
    wwav($f, $x, rate => 8000, format => 'pcm', bits => 32);
    is(wav_header($f)->{bits}, 32, "format => 'pcm', bits => 32 gives 32-bit PCM from float input");
}
for my $bad (pdl('nan'), pdl('inf'), pdl('-inf')) {
    eval { wwav($f, $bad->dummy(0, 1), rate => 8000, bits => 16) };
    my $err = $@;       # stringifying an ndarray below runs an eval and would clear $@
    like($err, qr/NaN or Inf/, "non-finite value ($bad) is refused for PCM output");
}

# --- layouts the caller may pass ---------------------------------------------------------------------------------------
{
    my $m = short(sequence(500));
    wwav($f, $m, rate => 8000);
    my $y = rwav($f);
    is(join(',', $y->dims), '1,500', '1-D input is mono: read back as (1, n)');
    ok(same($y->slice('(0)'), $m), '1-D input: values');

    my $nc = short(gen_int(500, 3, -32768, 32767));                 # dims (frames, channels)
    wwav($f, $nc->xchg(0, 1), rate => 8000);                        # non-contiguous view
    ok(same(scalar rwav($f), $nc->xchg(0, 1)), 'transposed (non-contiguous) input, direct path');
    wwav($f, $nc->xchg(0, 1)->double / 32768, rate => 8000, bits => 16);
    ok(same(scalar rwav($f), $nc->xchg(0, 1)), 'transposed input, quantising path');

    my $sl = short(gen_int(2, 100, -32768, 32767))->slice(':,10:60');
    wwav($f, $sl, rate => 8000);
    ok(same(scalar rwav($f), $sl), 'slice input');
}

# --- blocks: sizes straddling the default internal block --------------------------------------------------------
{
    my $b = $PDL::IO::WAV::BLOCK;
    my $n = 3 * $b + 37;
    my $k = gen_int(2, $n, -8388608, 8388607);
    wwav($f, $k->long, rate => 48000, bits => 24);
    ok(same(scalar rwav($f), $k), "24-bit write + read across block boundaries ($n frames, block $b)");
    my $mid = rwav($f, start => $b - 5, frames => 20);
    ok(same($mid, $k->slice(':,' . ($b - 5) . ':' . ($b + 14))), '24-bit partial read across a block boundary');

    my $x = $k->double / 8388608;
    wwav($f, $x, rate => 48000, bits => 16);
    my $want = ($x * 32768)->rint->clip(-32768, 32767);
    ok(same(scalar rwav($f), $want), "quantise to 16-bit across block boundaries ($n frames)");
}

# --- every converting path with a tiny block, so many blocks and a short last one ------------------------------
{
    local $PDL::IO::WAV::BLOCK = 1000;
    my $n = 2501;
    for my $ch (1, 2, 3) {
        my $k24 = gen_int($ch, $n, -8388608, 8388607);
        wwav($f, $k24->long, rate => 8000, bits => 24);
        ok(same(scalar rwav($f), $k24), "small blocks: 24-bit ${ch}ch write + read");
        ok(same(scalar rwav($f, start => 995, frames => 1012), $k24->slice(':,995:2006')), "small blocks: 24-bit ${ch}ch window over two block edges");

        for my $bits (8, 16, 24, 32) {
            my $scale = 2 ** ($bits - 1);
            my $x = gen_int($ch, $n, -$scale, $scale - 1)->double / $scale;
            wwav($f, $x, rate => 8000, format => 'pcm', bits => $bits);
            ok(same(scalar rwav($f, normalize => 1), $x), "small blocks: quantise $bits ${ch}ch");
        }

        my $sb = gen_int($ch, $n, -128, 127)->convert(sbyte);
        wwav($f, $sb, rate => 8000);
        ok(same(scalar rwav($f), $sb + 128), "small blocks: sbyte ${ch}ch");

        my $fl = (gen_int($ch, $n, -1000, 1000)->double / 1024)->float;
        wwav($f, $fl, rate => 8000, bits => 64);
        ok(same(scalar rwav($f), $fl), "small blocks: float32 -> float64 ${ch}ch");
        wwav($f, $fl->xchg(0, 1)->xchg(0, 1)->slice(':,3:2000'), rate => 8000);
        ok(same(scalar rwav($f), $fl->slice(':,3:2000')), "small blocks: slice input ${ch}ch");
    }
}

done_testing;
