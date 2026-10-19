#!/usr/bin/env perl
# wav_read_bench.pl — WAV 読み込み2方式の時間とピークメモリ比較(STIM009 で使用)
#   perl wav_read_bench.pl big.wav old|new
#   前提: 44 バイトヘッダ・16bit・2ch の WAV(比較専用の簡易版)
# 現行方式(全体 slurp → substr → zeroes に代入)と、データ部を ndarray に直接 read する方式の比較
use strict; use warnings; use PDL; use Time::HiRes qw(time);
my $f = shift;
sub rss { open my $s, '<', "/proc/$$/status"; while (<$s>) { return $1/1024 if /VmHWM:\s+(\d+)/ } }
my $mode = shift;
my $t = time; my $x;
if ($mode eq 'old') {
  open my $fh, '<:raw', $f or die; my $raw = do { local $/; <$fh> };
  my $bytes = substr($raw, 44); my $n = length($bytes) / 4;
  $x = zeroes(short, 2, $n); ${ $x->get_dataref } = $bytes; $x->upd_data;
} else {
  open my $fh, '<:raw', $f or die; my $len = (-s $f) - 44; seek $fh, 44, 0;
  $x = PDL->new_from_specification(short, 2, $len / 4);
  read($fh, ${ $x->get_dataref }, $len) == $len or die; $x->upd_data;
}
printf "%-4s %.3f s  peak RSS %.0f MB  sum=%s\n", $mode, time - $t, rss(), $x->slice('0,0:9')->sum;
