#!/usr/bin/env perl
# plot_wav_line.pl
#
# 何をするスクリプトか:
#   WAV ファイル(PCM 8/16/24/32bit または float 32/64bit)を読み込み、
#   横軸=時間(秒)、縦軸=振幅 の折れ線グラフを PDL::Graphics::Cairo で表示する。
#   チャンネルごとに別々の subplot に描く(1ch なら 1 枚、4ch なら縦に 4 枚)。
#   extend_wav_plateau.pl で作った延長波形(standard_10s.wav など)の確認用。
#
# 使い方:
#   perl plot_wav_line.pl standard_10s.wav
#   perl plot_wav_line.pl standard_10s.wav --sharey          # 全チャンネルの縦軸範囲をそろえる
#   perl plot_wav_line.pl standard_10s.wav --png snap.png --pos 0.5 --zoom 0.3
#       窓を開かずに 1 コマを PNG に保存して終わる(--pos/--zoom は下のスライダの位置 0〜1)
#
# 操作(giza-server の窓。タイトルバーにも同じ説明が出る):
#   横スライダ = 表示位置(時間軸のスクロール。左端=先頭の立ち上がり、右端=末尾の立ち下がり)
#   縦スライダ = 表示幅(時間軸のズーム。下=約20サンプル、上=全長。対数)。初期は 20 ms 幅
#                ※ 振幅(縦軸)を拡大するスライダではない
#   縦軸の範囲はチャンネルごとに全体の最小〜最大で固定(区間を動かしても振幅を比べられる)
#   表示区間の点数が窓の横ピクセルより多いときは、列ごとの min/max で描く
#
# 読み込み: PDL::IO::WAV の rwav。File::Map があれば mmap で開き(コピー無し・
#   読み込み待ち無し)、無ければ通常の読み込み。表示区間だけを double にして描く。
#   8bit PCM は中心 128 を 0 に直して表示する(それ以外は保存された値のまま)。
#
# 描画は examples/example_gs_slider.pl と同じ Driver::GS->show_interactive 方式。

use strict;
use warnings;
use Getopt::Long;
use File::Basename qw(basename);
use PDL;
use PDL::IO::WAV;
use PDL::Graphics::Cairo qw(figure);

my ($png, $pos0, $zoom0, $sharey, $mmap) = (undef, 0.0, undef, 0, 1);
GetOptions('png=s' => \$png, 'pos=f' => \$pos0, 'zoom=f' => \$zoom0,
           'sharey' => \$sharey, 'mmap!' => \$mmap) or die "bad options\n";
my $infile = $ARGV[0] // die "使い方: perl $0 input.wav [--sharey] [--png out.png --pos 0..1 --zoom 0..1]\n";

# ---- 読み込み(生の値のまま。mmap が使えれば全体をメモリに読まない) ----
my ($x, $hdr) = rwav($infile, mmap => $mmap);          # dims (チャンネル, 時間)
my ($ch, $n, $rate) = @$hdr{qw(channels frames rate)};
$n >= 4 or die "短すぎます($n サンプル)\n";
my $center = ($hdr->{format} eq 'pcm' && $hdr->{bits} == 8) ? 128 : 0;   # 8bit PCM は無符号

# 表示用に double へ(8bit は中心を 0 に)。大きな配列には使わず、描く点だけに使う
sub to_double {
    my ($p) = @_;
    my $d = $p->double;
    return $center ? $d - $center : $d;
}

# チャンネルごとの縦軸範囲(全体の最小〜最大 + 5% の余白)。
# xchg で時間を先頭次元にして、全チャンネルを 1 回の呼び出しで畳む
my $mn = $x->xchg(0, 1)->minimum->double - $center;
my $mx = $x->xchg(0, 1)->maximum->double - $center;
if ($sharey) { $mn .= $mn->min->sclr; $mx .= $mx->max->sclr }
my @ylim = map {
    my ($lo, $hi) = ($mn->at($_), $mx->at($_));
    my $pad = 0.05 * (($hi - $lo) || 1);
    [ $lo - $pad, $hi + $pad ];
} 0 .. $ch - 1;

# ---- スライダの意味 ----
# 横スライダ(id 0) = 表示位置(0=先頭 … 1=末尾)
# 縦スライダ(id 1) = 表示幅(0=狭い … 1=全体)。対数で wmin〜全長
my $T    = $n / $rate;
my $nmin = $n < 40 ? int($n / 2) : 20;                    # 表示幅の下限(サンプル数)
my $wmin = $nmin / $rate;
my $wmax = $T;
my $w0   = 0.02 < $wmax ? 0.02 : $wmax;                   # 初期表示幅 20 ms
my $v0   = log($w0 / $wmin) / log($wmax / $wmin);
my @color = qw(steelblue darkorange seagreen crimson);

my ($W0, $H0) = (900, $ch == 1 ? 400 : ($ch * 190 + 80 > 960 ? 960 : $ch * 190 + 80));

sub build_figure {
    my ($s, $W, $H) = @_;
    my $pos = $s->{0} // 0.0;
    my $v   = $s->{1} // $v0;
    my $win = $wmin * ($wmax / $wmin) ** $v;               # 表示幅 [s]
    $win = $T if $win > $T;
    my $t0  = $pos * ($T - $win);
    my $i0  = int($t0 * $rate);
    my $i1  = int(($t0 + $win) * $rate); $i1 = $n - 1 if $i1 > $n - 1;
    my $npt = $i1 - $i0 + 1;

    my $fig = figure(width => $W, height => $H);
    my @ax  = $fig->subplots($ch, 1);                      # 1ch は Axes 1 個、複数は縦に並んだ Axes のリスト
    @ax == $ch or die "subplots($ch,1) が " . scalar(@ax) . " 個の Axes を返しました\n";
    for my $c (0 .. $ch - 1) {
        my ($tt, $yy) = envelope($c, $i0, $i1, $W);
        $ax[$c]->line($tt, $yy, lw => 1.2, color => $color[$c % @color]);
        $ax[$c]->xlim($t0, $t0 + $win);
        $ax[$c]->ylim(@{ $ylim[$c] });
        $ax[$c]->ylabel($ch == 1 ? 'amplitude' : 'ch' . ($c + 1));
        $ax[$c]->xlabel('time [s]') if $c == $ch - 1;
    }
    $ax[0]->title(sprintf '%s   %.4f – %.4f s  (幅 %.4g s, %d 点)',
                  basename($infile), $t0, $t0 + $win, $win, $npt);
    $fig->tight_layout;
    # tight_layout sizes the left margin for the tick numbers only, so the rotated y label
    # (ch1, ch2, ...) falls outside the figure.  Make room for "2.00e+04" plus the label.
    my $ml = int(0.33 * $W); $ml = 100 if $ml > 100;
    $_->margin_left($ml) for @ax;
    return $fig;
}

# 点数が画面の横ピクセルより大幅に多いとき、ピクセル列ごとの min/max を
# 交互に並べて描く(塗りつぶしにならず、包絡とピークが正しく残る)。
# min/max は保存された値(整数のまま)の view 上で取り、描く 2×(列数) 点だけを double にする
# (表示区間の全点を double にしない)。割り切れない余りは最後の列として別に畳む。
sub envelope {
    my ($c, $i0, $i1, $W) = @_;
    my $raw = $x->slice("($c),$i0:$i1");                   # チャンネル c の表示区間(view)
    my $m   = $i1 - $i0 + 1;
    my $nb  = int($W) || 1;
    return ((sequence($m) + $i0) / $rate, to_double($raw)) if $m <= 4 * $nb;

    my $k     = int(($m + $nb - 1) / $nb);                 # 1 列 k 点
    my $nfull = int($m / $k);                              # k 点そろった列の数
    my $blk   = $raw->slice('0:' . ($nfull * $k - 1))->splitdim(0, $k);   # (k, nfull) の view
    my ($lo, $hi) = ($blk->minimum, $blk->maximum);        # 整数のまま (nfull)
    if ($nfull * $k < $m) {                                # 余りは最後の 1 列にする
        my $rest = $raw->slice($nfull * $k . ':-1');
        $lo = $lo->glue(0, $rest->min->flat);
        $hi = $hi->glue(0, $rest->max->flat);
    }
    my $mm = cat(to_double($lo), to_double($hi))->xchg(0, 1)->flat;       # mn0,mx0,mn1,mx1,…
    my $nbin = $lo->nelem;
    my $tb = ($i0 + sequence($nbin) * $k) / $rate;         # 各列の先頭サンプルの時刻
    my $t2 = cat($tb, $tb)->xchg(0, 1)->flat;
    return ($t2, $mm);
}

# ---- PNG に 1 コマ保存して終わる(窓なし) ----
if (defined $png) {
    my $zoom = $zoom0 // $v0;
    build_figure({ 0 => $pos0, 1 => $zoom }, $W0, $H0)->savefig($png);
    print STDERR "saved $png (pos=$pos0 zoom=$zoom, $ch ch, mmap=$hdr->{mmap})\n";
    exit 0;
}

# ---- 対話表示 ----
require PDL::Graphics::Cairo::Driver::GS;
my $title = sprintf '%s  |  横スライダ=表示位置(左端=先頭 … 右端=末尾)  |  '
                  . '縦スライダ=表示幅(下=約%dサンプル … 上=全長、対数。振幅の拡大ではない)',
                  basename($infile), $nmin;
my $gs = PDL::Graphics::Cairo::Driver::GS->new(width => $W0, height => $H0, title => $title);

$gs->show_interactive(
    init   => { 0 => $pos0, 1 => $zoom0 // $v0 },
    render => \&build_figure,
);
