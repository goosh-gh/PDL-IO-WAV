# Things that must be refused, with a message that says why.

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
my $f   = "$tmp/bad.wav";

sub put { my ($bytes) = @_; open my $o, '>:raw', $f or die; print $o $bytes; close $o }
sub chunk { my ($id, $body) = @_; $id . pack('V', length $body) . $body . (length($body) & 1 ? "\0" : '') }
sub riff { my $b = 'WAVE' . join('', @_); 'RIFF' . pack('V', length $b) . $b }
sub fmt { my ($tag, $ch, $rate, $bits, $align) = @_;
          $align //= $ch * $bits / 8;
          chunk('fmt ', pack('v v V V v v', $tag, $ch, $rate, $rate * $align, $align, $bits)) }

# sanity: the helpers build a readable file
put(riff(fmt(1, 1, 8000, 16), chunk('data', pack('s<*', 1, 2, 3))));
is_deeply([ rwav($f)->list ], [ 1, 2, 3 ], 'helper-built file is readable (control for the cases below)');

put('RIFX' . 'x' x 40);
eval { rwav($f) };      like($@, qr/not a RIFF\/WAVE/, 'wrong magic');
put('RIFF');
eval { rwav($f) };      like($@, qr/too short/, 'file shorter than 12 bytes');
put(riff(chunk('data', "\0\0")));
eval { rwav($f) };      like($@, qr/data chunk before fmt/, 'data before fmt');
put(riff(fmt(1, 1, 8000, 16)));
eval { rwav($f) };      like($@, qr/no data chunk/, 'no data chunk');
put(riff(chunk('data', "")));
eval { rwav($f) };      like($@, qr/data chunk before fmt/, 'only a data chunk');
put(riff(chunk('LIST', 'abcd')));
eval { rwav($f) };      like($@, qr/no fmt chunk/, 'no fmt chunk');
put(riff(fmt(2, 1, 8000, 4), chunk('data', "\0\0")));
eval { rwav($f) };      like($@, qr/unsupported format tag 2/, 'ADPCM is refused');
put(riff(fmt(1, 1, 8000, 12, 2), chunk('data', "\0\0")));
eval { rwav($f) };      like($@, qr/unsupported sample format/, '12-bit samples are refused');
put(riff(fmt(1, 1, 8000, 16), chunk('data', "\0\0")) =~ s/(fmt .{4}.{12})\x02\x00/$1\x07\x00/sr);
eval { rwav($f) };      like($@, qr/block alignment/, 'block alignment that does not fit channels x bits');
put(riff(fmt(3, 1, 8000, 16), chunk('data', "\0\0")));
eval { rwav($f) };      like($@, qr/unsupported sample format \(float, 16 bits\)/, '16-bit float is refused');
put(riff(fmt(1, 0, 8000, 16, 2), chunk('data', "\0\0")));
eval { rwav($f) };      like($@, qr/zero channels/, 'zero channels');
{
    # EXTENSIBLE with an unknown SubFormat GUID
    my $body = pack('v v V V v v', 0xFFFE, 1, 8000, 16000, 2, 16) . pack('v v V', 22, 16, 4)
             . pack('v', 1) . ("\x01" x 14);
    put(riff(chunk('fmt ', $body), chunk('data', "\0\0")));
    eval { rwav($f) };  like($@, qr/SubFormat/, 'EXTENSIBLE with a foreign GUID is refused');
    put(riff(chunk('fmt ', substr($body, 0, 24)), chunk('data', "\0\0")));
    eval { rwav($f) };  like($@, qr/short fmt chunk/, 'EXTENSIBLE with a short fmt chunk is refused');
}
eval { rwav("$tmp/does-not-exist.wav") };
like($@, qr/cannot open/, 'missing file');

# options
put(riff(fmt(1, 1, 8000, 16), chunk('data', pack('s<*', 1 .. 10))));
eval { rwav($f, normalise => 1) };      like($@, qr/unknown option 'normalise'/, 'rwav: misspelt option');
eval { rwav($f, normalize => 'x') };    like($@, qr/normalize must be/, 'rwav: bad normalize value');
eval { rwav($f, start => 11) };         like($@, qr/start must be/, 'rwav: start past the end');
eval { rwav($f, start => -1) };         like($@, qr/start must be/, 'rwav: negative start');
eval { rwav($f, start => 1.5) };        like($@, qr/start must be/, 'rwav: fractional start');
eval { rwav($f, frames => -3) };        like($@, qr/frames must be/, 'rwav: negative frames');
eval { wav_header() };                  like($@, qr/file name required/, 'wav_header without a file name');

# wwav
my $x = short(1, 2, 3);
eval { wwav($f, $x) };                                  like($@, qr/rate/, 'wwav: rate is required');
eval { wwav($f, $x, rate => 0) };                       like($@, qr/rate/, 'wwav: rate 0');
eval { wwav($f, $x, rate => 8000.5) };                  like($@, qr/rate/, 'wwav: fractional rate');
eval { wwav($f, [1, 2, 3], rate => 8000) };             like($@, qr/ndarray/, 'wwav: a Perl array is not an ndarray');
eval { wwav($f, zeroes(short, 2, 2, 2), rate => 8000) }; like($@, qr/expected dims/, 'wwav: 3-D data');
eval { wwav($f, short(5), rate => 8000) };              like($@, qr/expected dims/, 'wwav: a scalar ndarray');
eval { wwav($f, zeroes(short, 5000, 3), rate => 8000) };
                                                        like($@, qr/xchg/, 'wwav: dims (frames, channels) get a hint');
eval { wwav($f, $x, rate => 8000, speed => 2) };        like($@, qr/unknown option 'speed'/, 'wwav: misspelt option');
eval { wwav($f, $x, rate => 8000, bits => 24) };        like($@, qr/cannot write short data as 24-bit/, 'wwav: short as 24-bit');
eval { wwav($f, $x, rate => 8000, bits => 8) };         like($@, qr/cannot write short data as 8-bit/, 'wwav: short as 8-bit');
eval { wwav($f, $x, rate => 8000, format => 'float') }; like($@, qr/needs a float or double/, 'wwav: integers as float');
eval { wwav($f, $x, rate => 8000, format => 'mp3') };   like($@, qr/format must be/, 'wwav: unknown format');
eval { wwav($f, ushort(1, 2), rate => 8000) };          like($@, qr/unsupported ndarray type 'ushort'/, 'wwav: ushort');
eval { wwav($f, longlong(1, 2), rate => 8000) };        like($@, qr/unsupported ndarray type/, 'wwav: longlong');
eval { wwav($f, double([0.5]), rate => 8000, format => 'float', bits => 16) };
                                                        like($@, qr/bits => 32 or 64/, 'wwav: 16-bit float');
eval { wwav($f, double([0.5]), rate => 8000, format => 'pcm', bits => 12) };
                                                        like($@, qr/PCM bits must be/, 'wwav: 12-bit PCM');
# more than 4 GiB of data: a broadcast view claims 2**32 frames without allocating anything
eval { wwav($f, zeroes(byte, 1)->dummy(1, 4294967296), rate => 8000) };
                                                        like($@, qr/4 GiB/, 'wwav: data above 4 GiB is refused (RF64 is not written)');
eval { wwav("$tmp/no/such/dir/x.wav", $x, rate => 8000) };
                                                        like($@, qr/cannot write/, 'wwav: unwritable path');

done_testing;
