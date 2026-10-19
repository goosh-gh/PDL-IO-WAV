#!/usr/bin/env perl
# make_wav.pl
#
# 何をするスクリプトか:
#   テスト用の WAV を作る(PDL::IO::WAV の wwav の動作確認、STIM009 の電圧確認用の
#   入力波形づくり)。波形の種類・周波数・振幅(dBFS)・長さ・モノ/ステレオ・
#   ビット数をコマンドラインで指定し、書き出したあと rwav で読み戻して検査する。
#
# 使い方:
#   perl make_wav.pl out.wav --wave sine --freq 1000 --level -6 --dur 2
#   perl make_wav.pl out.wav --wave white --level -20 --dur 5 --channels 2
#   perl make_wav.pl out.wav --wave sine --freq 440 --freq2 660 --channels 2 --bits 24
#   perl make_wav.pl out.wav --wave pink --level -18 --format float --bits 32
#
#   第1引数  出力 WAV のファイル名(必須)
#   --wave      sine | square | triangle | sawtooth | white | pink   (既定 sine)
#   --freq      周波数 Hz(周期波形のみ。既定 440)
#   --freq2     ステレオの右チャンネルの周波数 Hz(既定 = --freq)
#   --phase     右チャンネルの位相差 度(周期波形のみ。既定 0)
#   --level     振幅 dBFS(既定 -6)。0 dBFS = フルスケール(±1.0)。
#                 周期波形(sine/square/triangle/sawtooth)は「ピーク」の dBFS
#                 (正弦波なら RMS はこれより 3.01 dB 低い)。
#                 ノイズ(white/pink)は「RMS」の dBFS(ピークはこれよりおよそ 12 dB 高い)。
#   --amp       振幅を線形値(ピーク、0〜1)で指定する。--level より優先
#   --dur       長さ 秒(既定 1)
#   --channels  1(モノ)または 2(ステレオ)。ノイズは左右で独立(既定 1)
#   --rate      サンプリング周波数 Hz(既定 48000)
#   --bits      PCM のビット数 8/16/24/32、--format float のときは 32/64(既定 16)
#   --format    pcm | float(既定 pcm)
#   --rise      立ち上がり時間 ms(始めに 0 から振幅まで raised-cosine で上げる。既定 5。0 で無し)
#   --fall      立ち下がり時間 ms(終わりに振幅から 0 まで下げる。既定 5。0 で無し)
#   --fade      --rise と --fall を同じ値にする省略形(--rise/--fall があればそちらが優先)
#   --seed      ノイズの乱数の種(既定: 毎回変わる)
#
# 立ち上がり/立ち下がり(--rise/--fall)は STIM009 の standard.wav のような「立ち上がり + 平坦部 + 立ち下がり」の
#   波形づくりにも使える(平坦部を延ばすのは extend_wav_plateau.pl)。
#
# 実装メモ: 波形は 1 回の PDL 演算(サンプル番号の ndarray から)で作り、Perl のサンプル
#   ループは使わない。square/triangle/sawtooth は帯域制限していない素直な波形で、高い
#   周波数では折り返し(エイリアシング)成分が出る。pink は白色ノイズを FFT で 1/√f に整形する。
#   書き出し後に rwav(normalize => 1) で読み戻し、量子化誤差(1 LSB 以内か)、ピーク/RMS、
#   周期波形では上向きゼロ交差から数えた周波数を表示する。

use strict;
use warnings;
use Getopt::Long;
use PDL;
use PDL::FFT;
use PDL::IO::WAV;

my %o = (wave => 'sine', freq => 440, level => -6, dur => 1, channels => 1,
         rate => 48000, bits => 16, format => 'pcm', phase => 0);
GetOptions(\%o, qw(wave=s freq=f freq2=f phase=f level=f amp=f dur=f channels=i
                   rate=i bits=i format=s rise=f fall=f fade=f seed=i)) or die "bad options\n";
my $outfile = $ARGV[0] // die "使い方: perl $0 out.wav [--wave sine|square|triangle|sawtooth|white|pink]"
                            . " [--freq Hz] [--level dBFS] [--dur 秒] [--channels 1|2] ...\n";

my %periodic = map { $_ => 1 } qw(sine square triangle sawtooth);
my %noise    = map { $_ => 1 } qw(white pink);
$periodic{$o{wave}} || $noise{$o{wave}} or die "--wave は sine/square/triangle/sawtooth/white/pink のどれか\n";
$o{channels} == 1 || $o{channels} == 2 or die "--channels は 1 か 2\n";
$o{dur} > 0 && $o{rate} > 0 or die "--dur と --rate は正の数\n";
$o{format} =~ /^(pcm|float)$/ or die "--format は pcm か float\n";
if ($o{format} eq 'pcm') { grep { $_ == $o{bits} } 8, 16, 24, 32 or die "PCM の --bits は 8/16/24/32\n" }
else                     { grep { $_ == $o{bits} } 32, 64        or die "float の --bits は 32/64\n" }
$o{rise} //= $o{fade} // 5;
$o{fall} //= $o{fade} // 5;
$o{rise} >= 0 && $o{fall} >= 0 or die "--rise と --fall は 0 以上(ms)\n";
$o{freq2} //= $o{freq};
if ($periodic{$o{wave}}) {
    for my $f ($o{freq}, $o{freq2}) {
        $f > 0 && $f < $o{rate} / 2 or die "周波数は 0 より大きくナイキスト(rate/2 = " . $o{rate} / 2 . " Hz)未満\n";
    }
}
my $amp = defined $o{amp} ? $o{amp} : 10 ** ($o{level} / 20);
$amp > 0 or die "振幅が 0 以下です\n";
my $n = int($o{dur} * $o{rate} + 0.5);
$n >= 2 or die "短すぎます\n";
if (defined $o{seed}) {                                  # 種の設定: PDL 2.085 は srand、2.104 は srandom
    my $seed_sub = PDL->can('srandom') || PDL->can('srand') or die "PDL に乱数の種を設定する関数がありません\n";
    $seed_sub->($o{seed});
}

# ---- 波形(振幅 1 に正規化したものを作ってから amp を掛ける) ----
my $t = sequence(double, $n) / $o{rate};                 # 時刻 [s]

# 周期波形: 位相 ph (0..1) から作る
sub periodic_wave {
    my ($wave, $freq, $phase_deg) = @_;
    my $x  = $freq * $t + $phase_deg / 360;
    my $ph = $x - floor($x);                             # 0 <= ph < 1
    return sin(6.283185307179586 * $ph)                  if $wave eq 'sine';
    return 1 - 2 * ($ph >= 0.5)                          if $wave eq 'square';   # 前半 +1、後半 -1
    return 2 * $ph - 1                                   if $wave eq 'sawtooth';
    my $q = $ph + 0.25; $q = $q - floor($q);             # triangle: 0 から上がり始める
    return 1 - 2 * abs(2 * $q - 1);
}

# ノイズ: RMS = 1 の系列
sub white_noise { grandom($n) }                          # 平均 0、標準偏差 1(RMS 1)
sub pink_noise {
    my $m = 1; $m *= 2 while $m < $n;                    # FFT は 2 のべき長で
    my $re = grandom($m);
    my $im = zeroes(double, $m);
    fft($re, $im);                                       # その場で複素 FFT(PDL::FFT)
    my $k = sequence(double, $m);
    $k = $k - ($k > $m / 2) * $m;                        # 負の周波数側は折り返して対称にする
    $k = abs($k); $k->slice('0') .= 1;                   # DC は 1 のまま(後で 0 にする)
    my $g = 1 / sqrt($k);                                # 電力が 1/f -> 振幅は 1/√f
    $g->slice('0') .= 0;                                 # DC 成分は除く
    $re *= $g; $im *= $g;
    ifft($re, $im);
    my $p = $re->slice("0:" . ($n - 1))->copy;
    return $p / sqrt(($p ** 2)->avg);                    # RMS = 1
}

my $y = zeroes(double, $o{channels}, $n);                # dims (チャンネル, 時間)
for my $c (0 .. $o{channels} - 1) {
    my $s;
    if ($periodic{$o{wave}}) {
        $s = periodic_wave($o{wave}, $c ? $o{freq2} : $o{freq}, $c ? $o{phase} : 0);
    } else {
        $s = $o{wave} eq 'white' ? white_noise() : pink_noise();
    }
    $y->slice("($c),:") .= $s * $amp;
}

# 立ち上がり/立ち下がり(raised-cosine。0 ms なら付けない)
my $nr = int($o{rise} / 1000 * $o{rate} + 0.5);
my $nf = int($o{fall} / 1000 * $o{rate} + 0.5);
$nr + $nf <= $n or die sprintf("--rise (%g ms) と --fall (%g ms) の合計が --dur (%g ms) を超えています\n",
                               $o{rise}, $o{fall}, $o{dur} * 1000);
if ($nr > 0) {
    my $ramp = 0.5 - 0.5 * cos(3.141592653589793 * (sequence(double, $nr) + 0.5) / $nr);   # 0 -> 1
    $y->slice(':,0:' . ($nr - 1)) *= $ramp->dummy(0, $o{channels});
}
if ($nf > 0) {
    my $ramp = 0.5 + 0.5 * cos(3.141592653589793 * (sequence(double, $nf) + 0.5) / $nf);   # 1 -> 0
    $y->slice(':,' . ($n - $nf) . ':-1') *= $ramp->dummy(0, $o{channels});
}

# ---- 書き出し ----
my $peak0 = $y->abs->max->sclr;
warn sprintf("注意: ピークが %.3f で ±1 を超えます。PCM では飽和(クリップ)します\n", $peak0)
    if $peak0 > 1 && $o{format} eq 'pcm';
wwav($outfile, $y, rate => $o{rate}, format => $o{format}, bits => $o{bits});

# ---- 読み戻して検査 ----
my ($r, $h) = rwav($outfile, normalize => 1);            # double, フルスケール = ±1
my $lsb = $o{format} eq 'pcm' ? 2 ** (1 - $o{bits}) : 0;
my $yin = $y;
$yin = $yin->clip(-1, 1) if $o{format} eq 'pcm';
my $err = ($r - $yin)->abs->max->sclr;
printf STDERR "出力 %s: %s %d bit, %d Hz, %d ch, %d サンプル (%.4f s)\n", $outfile,
    $o{format}, $o{bits}, $h->{rate}, $h->{channels}, $h->{frames}, $h->{frames} / $h->{rate};
for my $c (0 .. $h->{channels} - 1) {
    my $v    = $r->slice("($c),:");
    my $pk   = $v->abs->max->sclr;
    my $rms  = sqrt(($v ** 2)->avg->sclr);
    my $line = sprintf "  ch%d: ピーク %.2f dBFS, RMS %.2f dBFS", $c + 1,
        20 * log($pk) / log(10), 20 * log($rms) / log(10);
    if ($periodic{$o{wave}}) {
        # 上向きゼロ交差の位置(サンプル番号)の最初と最後の間隔から周波数を出す
        # (立ち上がり/立ち下がりの区間は振幅が小さく量子化の影響が大きいので、平坦部だけで数える)
        my $pl = ($n - $nf - $nr >= 4) ? $v->slice($nr . ':' . ($n - $nf - 1)) : $v;
        my $ix = which(($pl->slice('1:-1') >= 0) & ($pl->slice('0:-2') < 0));
        my $k  = $ix->nelem;
        $line .= $k >= 2
            ? sprintf(", 周波数(平坦部のゼロ交差から) %.2f Hz (指定 %g Hz)",
                      ($k - 1) * $o{rate} / ($ix->at($k - 1) - $ix->at(0)), $c ? $o{freq2} : $o{freq})
            : ', 周波数: ゼロ交差が少なすぎて測れません';
    }
    print STDERR "$line\n";
}
if ($o{format} eq 'pcm') {
    printf STDERR "読み戻しの最大誤差 %.3g (1 LSB = %.3g): %s\n", $err, $lsb,
        $err <= $lsb ? 'OK(1 LSB 以内)' : '量子化誤差が 1 LSB を超えています';
} else {
    my $tol = $o{bits} == 32 ? $peak0 * 2 ** -23 : 0;    # float32 の丸め(float64 は完全一致)
    printf STDERR "読み戻しの最大誤差 %.3g: %s\n", $err, $err <= $tol ? 'OK' : '不一致';
}
