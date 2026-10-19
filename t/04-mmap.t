# rwav(mmap => 1): zero-copy, copy-on-write view of the data chunk.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use File::Temp qw(tempdir);
use PDL::LiteF;
use PDL::IO::WAV qw(:all);
use TestUtil;

plan skip_all => 'File::Map is not installed' unless eval { require File::Map; 1 };
plan skip_all => 'mmap views are only used on little-endian hosts'
    if unpack('N', pack('L', 1)) == 1;

my $tmp = tempdir(CLEANUP => 1);
my $f   = "$tmp/m.wav";
my $dir = "$FindBin::Bin/data";

# every non-24-bit fixture: mapped view equals the normal read
my $man = do { require JSON::PP; JSON::PP::decode_json(slurp("$dir/manifest.json")) };
for my $name (sort keys %$man) {
    my $m = $man->{$name};
    next if $m->{bits} == 24 && $m->{format} eq 'pcm';
    my ($x, $h) = rwav("$dir/$name.wav", mmap => 1);
    is($h->{mmap}, 1, "$name: mapped");
    ok(same($x, scalar rwav("$dir/$name.wav")), "$name: mapped values equal the normal read");
    is('' . $x->type, type_for($m->{format}, $m->{bits}), "$name: type");
}

# 24-bit PCM cannot be viewed as a typed array: normal read, flagged
{
    my ($x, $h) = rwav("$dir/pcm24_stereo.wav", mmap => 1);
    is($h->{mmap}, 0, '24-bit: falls back to a normal read');
    ok(same($x, read_expected("$dir/pcm24_stereo.txt")), '24-bit: values correct after the fallback');
}

# window of a large-ish file
{
    my $big = short(((sequence(longlong, 2, 100000) * 2654435761) % 65536) - 32768);
    wwav($f, $big, rate => 48000);
    my ($x, $h) = rwav($f, mmap => 1, start => 12345, frames => 777);
    is($h->{mmap}, 1, 'window: mapped');
    ok(same($x, $big->slice(':,12345:13121')), 'window: values');
    ok(same(scalar rwav($f, mmap => 1, start => 100000), zeroes(short, 2, 0)), 'empty window is a normal empty ndarray')
        or diag(join ',', rwav($f, mmap => 1, start => 100000)->dims);

    # copy-on-write: changing the view must not touch the file
    my $before = slurp($f);
    my $y = rwav($f, mmap => 1);
    $y += 1;
    $y->slice(':,0:9') .= 7;
    is(slurp($f), $before, 'in-place changes of the mapped array leave the file untouched');
    ok(same(scalar rwav($f), $big), 'file still reads back unchanged');

    # normalisation / signed make a real copy, so the flag drops
    my ($d, $hd) = rwav($f, mmap => 1, normalize => 1);
    is($hd->{mmap}, 0, 'normalize: no longer a mapped array');
    ok(same($d, $big->double / 32768), 'normalize: values');

    # a mapped array can be written out again
    my $z = rwav($f, mmap => 1);
    my $f2 = "$tmp/m2.wav";
    wwav($f2, $z, rate => 48000);
    is(slurp($f2), $before, 'wwav of a mapped array reproduces the file byte for byte');
    wwav($f2, $z->slice(':,100:900'), rate => 48000);
    ok(same(scalar rwav($f2), $big->slice(':,100:900')), 'wwav of a slice of a mapped array');
}

done_testing;
