# 引き継ぎ: PDL::IO::WAV(新規)

## 目的

PDL で WAV ファイルを読み書きするモジュール `PDL::IO::WAV` を作る。STIM009 で書いた WAV 読み込みを土台にし、無駄なコピーと Perl ループを省く。外部ライブラリには頼らず、純 Perl/PDL で書く。

## 経緯(STIM009、2026-10-18〜19)

- STIM009(Mac の PsychoPy で聴覚刺激)で、電圧確認用の `standard.wav` が短すぎた。そこで立ち上がりと立ち下がりを残して平坦部を繰り返す `extend_wav_plateau.pl` を作り、波形を見るために `plot_wav_line.pl`(P:G:C、スライダ付き)を作った。
- 2本に同じ WAV 読み込みのコードが入っている。今後も STIM 系で聴覚刺激を確かめるたびに WAV を扱うので、モジュールに切り出すことにした。
- 添付: `extend_wav_plateau.pl`、`plot_wav_line.pl`、`wav_read_bench.pl`

## 既存のもの(2026-10-19 に調べた範囲)

- CPAN で `PDL::IO::WAV` は見つからなかった(検索のみ。metacpan のページは直接開けなかった)。
- `PDL::Audio` 1.2(2012-04): C の sndlib を同梱してビルドする作り。`raudio`/`waudio` で読み書きする。今の環境でビルドできるかは未確認。
- `Audio::SoundFile` 0.16(2009-12): PDL の ndarray で直接やり取りする口があると説明に書かれている。古い。
- `Audio::Wav`: 純 Perl で WAV を読み書きする。PDL とは関係ない。
- PDL 本体の `PDL::Demos::Sound`(pdl2 の `demo sound`)は WAV を扱わない。`byte` の ndarray で音を作り(8 kHz、8 bit 符号なし、モノラル)、`${$pdl->get_dataref}` を `aplay`/`play`/`sox` にパイプで流すだけ。

## 今のコードの作りと無駄(`extend_wav_plateau.pl`)

- `RIFF`/`WAVE` を確かめた後、チャンクを順にたどって `fmt ` と `data` を取り出す。奇数長のチャンクはパディング 1 バイトを考慮している。
- 対応形式は PCM 8/16/32 bit と float 32/64。24 bit は未対応。`WAVE_FORMAT_EXTENSIBLE`(0xFFFE)は中身を見ずに整数 PCM 扱いにしている(SubFormat を見ていない)。
- 次元は `(ch, n)`。WAV のインターリーブ(L R L R …)がそのまま並ぶ。
- big-endian 機では `bswap2`/`bswap4`/`bswap8` で並びを直す(コードは書いたが、big-endian 機では試していない)。
- 1 サンプルずつの Perl ループは無い。ただし同じデータを 3 回持つ:
  1. ファイル全体をスカラーに slurp
  2. `substr` で data 部分を切り出してもう 1 つ
  3. `zeroes` で 0 埋め確保した ndarray に `${get_dataref} = ...` でさらにコピー
- 呼び出し側でも無駄がある:
  - `plot_wav_line.pl` はファイル全体を `->double` にしていて、16 bit のデータならさらに 4 倍のメモリを使う。
  - `extend_wav_plateau.pl` も解析用に全体を `->double` にしている。
- 書き出しは `pack` で 44 バイトのヘッダ(`fmt ` の長さ 16)を作り、`${$y->get_dataref}` を書くだけ。

## 測定結果(Linux コンテナ、PDL 2.085、`wav_read_bench.pl`)

10 分・48 kHz・2ch・16 bit(110 MB)の WAV:

| 読み方 | 時間 | ピーク RSS(Perl 自体の約 17 MB を含む) |
|---|---|---|
| 今のやり方(slurp → substr → zeroes に代入) | 0.20 s | 347 MB |
| data 部を ndarray に直接 `read` | 0.10 s | 127 MB |

読み込んだ値は両方で一致した。直接読む形は次のとおり:

```perl
seek $fh, $data_offset, 0;
my $x = PDL->new_from_specification($type, $ch, $n);   # 0 埋めしない
read($fh, ${ $x->get_dataref }, $nbytes) == $nbytes or die;
$x->upd_data;
```

`wav_read_bench.pl` のメモリ計測は `/proc` を読むので Linux 専用。Mac で測るなら書き換えが要る。

## 新しいスレでやること

1. API を決める。たたき台:
   - `my ($pdl, $hdr) = rwav($file);` — `$pdl` の次元は `(ch, n)`、型はファイル通り。`$hdr` は `{rate, channels, bits, format => 'pcm'|'float', frames}`
   - `wwav($file, $pdl, rate => ..., bits => ..., format => ...)`
   - 1ch のとき `(1, n)` で返すか `(n)` で返すか。`(ch, n)` と `(n, ch)` のどちらを既定にするか(後で `->xchg` が要るかどうかに関わる)
   - 8 bit(符号なし、中心 128)をそのまま返すか、符号付きに直すオプションを付けるか
   - double に正規化(-1〜1)して返すオプションを付けるか
2. ヘッダは小さく読みながらチャンクをたどり、data は ndarray に直接 `read` する。ファイル全体の slurp はしない。
3. 24 bit PCM を読み書きする。PDL に 24 bit 型は無いので、3 バイトずつを `long` に広げる処理を Perl ループなしで書く(byte の ndarray を reshape して組み立てる、など)。
4. `WAVE_FORMAT_EXTENSIBLE` は SubFormat の GUID を見て、PCM か float かを判定する。
5. 長いファイルの一部だけを読む口を検討する(開始フレームと長さを指定して `seek` + `read`)。`PDL::IO::FastRaw` の mmap が使えるかも調べる。
6. 書き出しで 4 GB を超える場合の扱いを決める(RF64 に対応するか、エラーにするか)。
7. テスト: 形式ごと(8/16/24/32 PCM、float 32/64)×(1ch/2ch)で、読んで書いて読み直したら一致すること。`LIST` などの余分なチャンクを含むファイル、奇数長のチャンクを含むファイル。可能なら sox や Python の `wave` で作ったファイルとも突き合わせる。
8. 完成したら `extend_wav_plateau.pl` と `plot_wav_line.pl` をこのモジュールを使う形に書き換える。`plot_wav_line.pl` は表示区間だけを double にする。

## 方針(goosh)

- README には、動作を確かめた事実だけを書く。予定や「いずれやりたい」は書かない。
- push は goosh がローカルから行う。commit の文面も先に goosh が確認する。
- 渡すスクリプトには、中身が分かる名前を付け、冒頭に何をするものかを書く。
