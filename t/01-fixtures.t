# Read the fixtures built by author/make_fixtures.py (an independent writer)
# and compare every sample with the expected values written next to them.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP qw(decode_json);
use PDL::LiteF;
use PDL::IO::WAV qw(:all);
use TestUtil;

my $dir = "$FindBin::Bin/data";
my $man = decode_json(slurp("$dir/manifest.json"));
my @names = sort keys %$man;
plan tests => 14 * @names + 7;

for my $name (@names) {
    my $m   = $man->{$name};
    my $wav = "$dir/$name.wav";
    my $exp = read_expected("$dir/$name.txt");
    my ($ch, $n, $bits, $fmt) = @$m{qw(channels frames bits format)};

    # header
    my $h = wav_header($wav);
    is_deeply([ @$h{qw(channels frames bits format rate)} ],
              [ $ch, $n, $bits, $fmt, $m->{rate} ], "$name: header");
    is($h->{extensible}, $m->{extensible} // 0, "$name: extensible flag");
    is($h->{container}, $m->{container} // 'RIFF', "$name: container");
    is($h->{truncated} // 0, $m->{truncated} // 0, "$name: truncated flag");

    # samples, exactly as stored
    my ($x, $rh) = rwav($wav);
    is('' . $x->type, type_for($fmt, $bits), "$name: type");
    ok(same($x, $exp), "$name: all $ch x $n samples equal");
    ok(!same($x, $exp + 1), "$name: [negative control] values +1 are not equal");
    ok(!same($x->mv(1, 0)->rotate(1)->mv(0, 1), $exp), "$name: [negative control] frame shift is not equal");

    # normalised
    my $want = $fmt eq 'float' ? $exp
             : $bits == 8      ? ($exp - 128) / 128
             :                   $exp / 2 ** ($bits - 1);
    my $d = rwav($wav, normalize => 1);
    is('' . $d->type, 'double', "$name: normalize => 1 gives double");
    ok(same($d, $want), "$name: normalised values exact");
    my $f = rwav($wav, normalize => 'float');
    is('' . $f->type, 'float', "$name: normalize => 'float' gives float");

    # partial reads
    my $a0 = $n > 150 ? 100 : 1;
    my $p  = rwav($wav, start => $a0, frames => 37);
    ok(same($p, $exp->slice(":,$a0:" . ($a0 + 36))), "$name: start/frames window equals the slice");
    my $tail = rwav($wav, start => $n - 5, frames => 1000);
    ok(same($tail, $exp->slice(':,' . ($n - 5) . ':-1')), "$name: frames past the end are clamped");
    my $none = rwav($wav, start => $n);
    is(join(',', $none->dims), "$ch,0", "$name: start == frames gives an empty (ch,0) ndarray");
}

# 8-bit signed option
{
    my $exp = read_expected("$dir/pcm8_stereo.txt");
    my $s = rwav("$dir/pcm8_stereo.wav", signed => 1);
    is('' . $s->type, 'sbyte', 'signed => 1: type sbyte');
    ok(same($s, $exp - 128), 'signed => 1: values are raw - 128');
    my $u = rwav("$dir/pcm8_stereo.wav");
    ok(same($u, $exp), 'default: 8-bit stays unsigned (0..255)');
}

# scalar context returns just the ndarray; list context also the header
{
    my $x = rwav("$dir/pcm16_mono.wav");
    isa_ok($x, 'PDL', 'scalar context');
    my ($y, $h) = rwav("$dir/pcm16_mono.wav", start => 10, frames => 20);
    is_deeply([ @$h{qw(read_start read_frames frames)} ], [ 10, 20, 997 ],
              'header reports read_start, read_frames and total frames');
}

# chunk list of a file with extra chunks
{
    my $h = wav_header("$dir/pcm16_chunks_before.wav");
    is_deeply([ map { $_->[0] } @{ $h->{chunks} } ], [ 'JUNK', 'fmt ', 'LIST', 'data' ],
              'chunks before data are listed in file order');
    $h = wav_header("$dir/pcm16_chunks_after.wav");
    is_deeply([ map { $_->[0] } @{ $h->{chunks} } ], [ 'fmt ', 'data', 'LIST', 'JUNK' ],
              'chunks after data are listed too');
}
