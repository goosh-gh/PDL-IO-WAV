# Author test: compare with sox, ffmpeg and Python's wave module.
# Not run by `make test`; run with  prove -l xt/
# Skips whatever tool is not installed.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../t/lib";
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use PDL::LiteF;
use PDL::IO::WAV qw(:all);
use TestUtil;

sub have { my ($cmd) = @_; return scalar grep { -x "$_/$cmd" } split /:/, $ENV{PATH} }
my ($sox, $ffmpeg, $py) = (have('sox'), have('ffmpeg'), have('python3'));
plan skip_all => 'sox, ffmpeg and python3 are all missing' unless $sox || $ffmpeg || $py;

my $tmp  = tempdir(CLEANUP => 1);
my $dir  = "$FindBin::Bin/../t/data";
my $f    = "$tmp/x.wav";
my $dec  = "$tmp/dec.raw";

# little-endian float64 file -> ndarray (ch, n)
sub load_f64 {
    my ($file, $ch) = @_;
    my $raw = slurp($file);
    my $n = length($raw) / 8 / $ch;
    my $x = PDL->new_from_specification(double(), $ch, $n);
    ${ $x->get_dataref } = $raw;
    $x->upd_data;
    return $x;
}
# sox holds every sample as a 32-bit integer, so float data comes back
# quantised to 2^-31; compare with that tolerance
sub close_to { my ($got, $exp) = @_; return 0 unless join(',', $got->dims) eq join(',', $exp->dims);
               return (($got->double - $exp->double)->abs->max->sclr <= 2 ** -30) ? 1 : 0 }
sub sox_decode {                      # any file sox understands -> normalised doubles
    my ($file, $ch) = @_;
    system('sox', '-V1', $file, '-D', '-e', 'floating-point', '-b', '64', '-t', 'raw', $dec) == 0 or return;
    return load_f64($dec, $ch);
}

if ($sox) {
    # 1. every fixture: sox must agree with the expected values (checks the fixtures themselves)
    #    and with rwav
    my $man = decode_json(slurp("$dir/manifest.json"));
    for my $name (sort keys %$man) {
        my $m = $man->{$name};
        next if $m->{container} && $m->{container} eq 'RF64';       # sox cannot read RF64
        next if $m->{truncated};                                     # sox repairs these differently
        next if ($m->{valid_bits} // $m->{bits}) < $m->{bits};       # sox: "padded samples is not supported yet"
        my $want = rwav("$dir/$name.wav", normalize => 1);
        my $got  = sox_decode("$dir/$name.wav", $m->{channels});
        my $cmp  = $m->{format} eq 'float' ? \&close_to : \&same;
        ok(defined $got && $cmp->($got, $want), "sox decodes fixture $name to the same values as rwav");
    }

    # 2. files made by sox
    for my $spec ([ 8, 1 ], [ 16, 2 ], [ 24, 1 ], [ 24, 2 ], [ 32, 2 ], [ 16, 3 ], [ 24, 6 ]) {
        my ($bits, $ch) = @$spec;
        system('sox', '-V1', '-D', '-n', '-r', '44100', '-b', $bits, '-c', $ch, $f,
               'synth', '0.4', 'whitenoise', 'gain', '-3') == 0 or die "sox failed";
        my $got = rwav($f, normalize => 1);
        my $ref = sox_decode($f, $ch);
        ok(same($got, $ref), "sox-made ${bits}-bit ${ch}ch file: rwav equals sox's own decode");
        is(wav_header($f)->{bits}, $bits, "sox-made ${bits}-bit ${ch}ch file: bits");
    }
    system('sox', '-V1', '-D', '-n', '-r', '44100', '-e', 'floating-point', '-b', 32, '-c', 2, $f,
           'synth', '0.3', 'whitenoise') == 0 or die;
    ok(close_to(scalar rwav($f), sox_decode($f, 2)), 'sox-made float32 file');
    system('sox', '-V1', '-D', '-n', '-r', '44100', '-e', 'floating-point', '-b', 64, '-c', 1, $f,
           'synth', '0.3', 'whitenoise') == 0 or die;
    ok(close_to(scalar rwav($f), sox_decode($f, 1)), 'sox-made float64 file');

    # 3. files made by wwav, read by sox
    my $k = sin(sequence(double, 2, 3000) * 0.011) * 0.8;
    for my $bits (8, 16, 24, 32) {
        wwav($f, $k, rate => 32000, format => 'pcm', bits => $bits);
        my $info = `sox --i -b $f`;  chomp $info;
        is($info, $bits, "sox reads the wwav $bits-bit file as $bits bit");
        is(`sox --i -c $f` + 0, 2, "sox: 2 channels");
        is(`sox --i -r $f` + 0, 32000, "sox: rate");
        is(`sox --i -s $f` + 0, 3000, "sox: 3000 samples per channel");
        ok(same(sox_decode($f, 2), rwav($f, normalize => 1)), "sox decodes the wwav $bits-bit file to what rwav reads");
    }
    for my $bits (32, 64) {
        wwav($f, $bits == 32 ? $k->float : $k, rate => 32000);
        ok(close_to(sox_decode($f, 2), scalar rwav($f)), "sox decodes the wwav float$bits file to what rwav reads");
    }
    # 3 and 6 channels (WAVE_FORMAT_EXTENSIBLE)
    for my $ch (3, 6) {
        my $m = sin(sequence(double, $ch, 1000) * 0.07) * 0.5;
        wwav($f, $m, rate => 48000, bits => 24);
        is(`sox --i -c $f` + 0, $ch, "sox reads the wwav ${ch}-channel extensible file");
        ok(same(sox_decode($f, $ch), rwav($f, normalize => 1)), "sox decodes the ${ch}-channel 24-bit file like rwav");
    }
}

if ($ffmpeg) {
    for my $codec (qw(pcm_u8 pcm_s16le pcm_s24le pcm_s32le pcm_f32le pcm_f64le)) {
        system("ffmpeg -v error -y -f lavfi -i 'sine=frequency=440:duration=0.3:sample_rate=44100' "
             . "-af 'pan=stereo|c0=c0|c1=0.5*c0' -c:a $codec $f") == 0 or die "ffmpeg failed";
        my $got = rwav($f, normalize => 1);
        system("ffmpeg -v error -y -i $f -f f64le -c:a pcm_f64le $dec") == 0 or die;
        ok(same($got, load_f64($dec, 2)), "ffmpeg-made $codec file: rwav equals ffmpeg's decode");
    }
    # RF64
    system("ffmpeg -v error -y -f lavfi -i 'sine=frequency=440:duration=0.3:sample_rate=44100' "
         . "-rf64 always -c:a pcm_s16le $f") == 0 or die;
    my $h = wav_header($f);
    is($h->{container}, 'RF64', 'ffmpeg -rf64 always: RF64 container');
    system("ffmpeg -v error -y -i $f -f f64le -c:a pcm_f64le $dec") == 0 or die;
    ok(same(scalar rwav($f, normalize => 1), load_f64($dec, 1)), 'ffmpeg-made RF64 file reads like ffmpeg decodes it');

    # files from wwav read by ffmpeg
    my $k = sin(sequence(double, 2, 2000) * 0.02) * 0.7;
    for my $spec ([ 'pcm', 16 ], [ 'pcm', 24 ], [ 'pcm', 32 ], [ 'float', 32 ], [ 'float', 64 ]) {
        my ($fmt, $bits) = @$spec;
        wwav($f, $k, rate => 44100, format => $fmt, bits => $bits);
        system("ffmpeg -v error -y -i $f -f f64le -c:a pcm_f64le $dec") == 0
            or fail("ffmpeg cannot read the wwav $fmt $bits file");
        ok(same(load_f64($dec, 2), rwav($f, normalize => 1)), "ffmpeg decodes the wwav $fmt $bits file like rwav");
    }
}

if ($py) {
    # Python's wave module: plain PCM only
    my $k = short(((sequence(longlong, 2, 777) * 2654435761) % 65536) - 32768);
    wwav($f, $k, rate => 11025);
    my $out = `python3 -I -c "import wave,sys; w=wave.open(sys.argv[1]); print(w.getnchannels(), w.getframerate(), w.getsampwidth(), w.getnframes()); sys.stdout.flush(); sys.stdout.buffer.write(w.readframes(w.getnframes()))" $f`;
    my ($line, $rest) = split /\n/, $out, 2;
    is($line, '2 11025 2 777', "python wave reads the wwav 16-bit file's header");
    my $px = short([ unpack('s<*', $rest) ])->reshape(2, 777);
    ok(same($px, $k), "python wave returns the samples wwav wrote");
    wwav($f, ((sequence(longlong, 1, 500) * 7919) % 16777216 - 8388608)->long, rate => 8000, bits => 24);
    $out = `python3 -I -c "import wave,sys; w=wave.open(sys.argv[1]); print(w.getnchannels(), w.getsampwidth()); sys.stdout.flush(); sys.stdout.buffer.write(w.readframes(w.getnframes()))" $f`;
    ($line, $rest) = split /\n/, $out, 2;
    is($line, '1 3', 'python wave reads the wwav 24-bit mono file');
    my @b = unpack('C*', $rest);
    my @v; push @v, ($b[3*$_] | $b[3*$_+1] << 8 | $b[3*$_+2] << 16) - (($b[3*$_+2] & 0x80) ? 1 << 24 : 0) for 0 .. 499;
    ok(same(pdl(\@v)->reshape(1, 500), ((sequence(longlong, 1, 500) * 7919) % 16777216 - 8388608)), 'python wave returns the 24-bit samples wwav wrote');
}

done_testing;
