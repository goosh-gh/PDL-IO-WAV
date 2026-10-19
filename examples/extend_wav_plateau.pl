#!/usr/bin/env perl
# extend_wav_plateau.pl
#
# 何をするスクリプトか:
#   WAV(PCM 8/16/24/32bit または float 32/64bit)の「立ち上がり」と「立ち下がり」は
#   そのまま残し、その間の平坦部(プラトー)を繰り返しコピーして長い WAV を作る。
#   STIM009 の電圧確認用に standard.wav を延長する用途。
#
#   つなぎ目でプチ音(段差)が出ないように、
#     1. 繰り返し区間 [a, b) の終わり b を、b の前後の波形が a の前後の波形と
#        最もよく一致する位置に選ぶ(正弦波なら位相のそろう位置 = 整数周期)
#     2. 繰り返しは区間まるごと(整数回)だけ使い、途中で切らない。
#        そのため出力長は --dur に最も近い「区間長の整数倍」にそろう
#   つなぎ目での折れ(2階差分)と、区間内の最大値を表示する。
#
# 使い方:
#   perl extend_wav_plateau.pl standard.wav --dur 10
#     第1引数  入力WAV($ARGV[0])。出力は入力のbasenameに _<dur>s を付けた名前で
#              カレントディレクトリに書き出す(例: standard_10s.wav)
#              出力は入力と同じ形式(ビット数・PCM/float)で書く
#     --dur   出力の全長(秒)。実際の長さは区間長の整数倍に丸められる
#     --thr   平坦部の自動検出しきい値(5 ms ブロックごとの最大振幅が
#             全体最大の thr 倍以上のところを平坦部とする。既定 0.98)
#     --a/--b 平坦部の開始/終了の目安を秒で手動指定(自動検出を上書き)。
#             b はこの位置から手前に向かって一致の良い位置を探す
#     --search 終点 b を探す範囲(秒, 既定 0.05)。最低周波数の 1 周期以上にする
#
# 実装メモ: 入力は PDL::IO::WAV の rwav で保存された値のまま (チャンネル, 時間) に読む。
#   解析(平坦部の検出、b の探索、つなぎ目の検査)は必要な区間だけを double にして行い、
#   全体を double にはしない。出力は 1 回だけ確保した配列に先頭・繰り返し・末尾を
#   view 経由で書き込み、そのまま wwav に渡す。

use strict;
use warnings;
use Getopt::Long;
use File::Basename qw(fileparse);
use PDL;
use PDL::IO::WAV;

my ($dur, $thr, $ta, $tb, $search) = (undef, 0.98, undef, undef, 0.05);
GetOptions('dur=f' => \$dur, 'thr=f' => \$thr, 'a=f' => \$ta, 'b=f' => \$tb,
           'search=f' => \$search) or die "bad options\n";
my $infile = $ARGV[0];
defined $infile or die "使い方: perl $0 input.wav --dur 秒\n";
defined $dur    or die "--dur (秒) を指定してください\n";

# 出力名: <入力のbasename>_<dur>s.wav をカレントディレクトリに
my ($base) = fileparse($infile, qr/\.[^.]*$/);
my $outfile = "${base}_${dur}s.wav";

# ---- WAV 読み込み(保存された値のまま。dims = (チャンネル, 時間)) ----
my ($x, $hdr) = rwav($infile);
my ($ch, $n, $rate) = @$hdr{qw(channels frames rate)};
my $center = ($hdr->{format} eq 'pcm' && $hdr->{bits} == 8) ? 128 : 0;   # 8bit PCM は無符号(中心128)

# 解析用: 渡された区間だけを double(8bit は中心を 0 に)にする
sub as_double {
    my ($p) = @_;
    my $d = $p->double;
    return $center ? $d - $center : $d;
}

# ---- 平坦部の目安 [a, bmax) ----
my ($a, $bmax);
my $B = int(0.005 * $rate) || 1;                     # 5 ms ブロック
if (defined $ta && defined $tb) {
    ($a, $bmax) = (int($ta * $rate + 0.5), int($tb * $rate + 0.5));
} else {
    my $nb = int($n / $B);
    $nb >= 1 or die "入力が短すぎます\n";
    # (ch*B, nb) の view(コピーしない)。ブロックごとの最大・最小から |x-center| の最大を出す
    my $blocks = $x->slice(':,0:' . ($nb * $B - 1))->splitdim(1, $B)->clump(0, 1);
    my $hi  = $blocks->maximum->double - $center;
    my $lo  = $center - $blocks->minimum->double;
    my $blk = cat($hi, $lo)->xchg(0, 1)->maximum;                        # (nb) ブロック最大振幅
    my $idx = which($blk >= $thr * $blk->max->sclr);
    # 立ち上がり/立ち下がりにかかるブロックを避けて 1 ブロックずつ内側に入る
    $a    = ($idx->min->sclr + 1) * $B;
    $bmax = ($idx->max->sclr)     * $B;
}

# ---- 終点 b を探す: b 前後の波形が a 前後の波形と最も一致する位置 ----
my $m  = 16;                                         # 比較する片側サンプル数
my $S  = int($search * $rate);
my $lo = $bmax - $S; $lo = $a + $m + 1 if $lo < $a + $m + 1;
($a - $m >= 0 && $bmax + $m <= $n && $lo < $bmax)
    or die "平坦部が短すぎるか範囲が不正: a=$a bmax=$bmax n=$n\n";
my $seg0 = $a - $m;                                  # 解析に使う区間 [a-m, bmax+m) だけ double にする
my $seg  = as_double($x->slice(":,$seg0:" . ($bmax + $m - 1)));          # (ch, nseg)
my $ref  = $seg->slice(':,0:' . (2 * $m - 1));                            # a 前後 (ch, 2m)
my $cand = sequence(long, $bmax - $lo + 1) + $lo;                         # 候補 b
my $off  = sequence(long, 2 * $m) - $m;
my $win  = $seg->dice_axis(1, ($off->dummy(1, $cand->nelem) + ($cand - $seg0)->dummy(0, 2 * $m))->flat)
             ->reshape($ch, 2 * $m, $cand->nelem);                        # (ch, 2m, ncand)
my $err  = (($win - $ref) ** 2)->sumover->sumover;                        # (ncand)
my $b    = $cand->at($err->minimum_ind->sclr);
my $L    = $b - $a;

# ---- 切り貼り: 立ち上がり + 区間の整数回繰り返し + 立ち下がり ----
my $mid_target = int($dur * $rate + 0.5) - $a - ($n - $b);
$mid_target >= 0 or die "--dur が短すぎます(立ち上がり+立ち下がりだけで超えています)\n";
my $reps  = int($mid_target / $L + 0.5); $reps = 1 if $reps < 1;
my $total = $a + $L * $reps + ($n - $b);
my $y = PDL->new_from_specification($x->type, $ch, $total);                 # 全体を 1 回だけ確保
$y->slice(':,0:' . ($a - 1)) .= $x->slice(':,0:' . ($a - 1));
my $mid_view = $y->slice(':,' . $a . ':' . ($a + $L * $reps - 1))->splitdim(1, $L);   # (ch, L, reps) の view
$mid_view .= $x->slice(":,$a:" . ($b - 1))->dummy(2, $reps);                           # 区間を reps 回ぶん一度に書く
$y->slice(':,' . ($a + $L * $reps) . ':-1') .= $x->slice(":,$b:-1");

# ---- つなぎ目の折れチェック ----
# 2階差分 s[i+1]-2s[i]+s[i-1] は波形の「折れ」に敏感。つなぎ目(… b-2, b-1 | a, a+1 …)
# での値と、区間内での最大値を比べる
my $j    = as_double($x->slice(':,' . ($b - 2) . ':' . ($b - 1))->glue(1, $x->slice(":,$a:" . ($a + 1))));
my $c2_join = abs($j->slice(':,2:-1') - 2 * $j->slice(':,1:-2') + $j->slice(':,0:-3'))->max->sclr;
my $sg   = as_double($x->slice(":,$a:" . ($b - 1)));
my $c2_norm = abs($sg->slice(':,2:-1') - 2 * $sg->slice(':,1:-2') + $sg->slice(':,0:-3'))->max->sclr;
printf STDERR "入力 %d サンプル (%.4f s), rate=%d, ch=%d\n", $n, $n / $rate, $rate, $ch;
printf STDERR "繰り返し区間 [%d,%d) = %d サンプル (%.5f s) × %d 回\n", $a, $b, $L, $L / $rate, $reps;
printf STDERR "つなぎ目の折れ(2階差分) %.4g / 区間内の最大 %.4g\n", $c2_join, $c2_norm;
warn "注意: つなぎ目の折れが区間内より大きい。--search を広げるか --a/--b を見直してください\n"
    if $c2_join > 1.1 * $c2_norm;

# ---- WAV 書き出し(入力と同じ形式) ----
wwav($outfile, $y, rate => $rate, format => $hdr->{format}, bits => $hdr->{bits},
     ($hdr->{extensible} ? (extensible => 1, channel_mask => $hdr->{channel_mask}) : ()));
printf STDERR "出力 %s: %d サンプル (%.4f s)\n", $outfile, $total, $total / $rate;
