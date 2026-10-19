# PDL::IO::WAV

Read and write WAV files as PDL ndarrays. Pure Perl/PDL, no C and no external
library.

```perl
use PDL;
use PDL::IO::WAV;

my ($x, $hdr) = rwav('in.wav');                    # dims (channels, frames), type as stored
my $y    = rwav('in.wav', normalize => 1);         # double, full scale = +-1
my $part = rwav('in.wav', start => 48000, frames => 4800);
my $view = rwav('big.wav', mmap => 1);             # no copy; needs File::Map

wwav('out.wav', $x, rate => $hdr->{rate});
wwav('out.wav', $y, rate => 48000, format => 'pcm', bits => 24);   # quantise to 24-bit PCM
my $info = wav_header('in.wav');                   # header only
```

See `perldoc PDL::IO::WAV` for the options and the header hash.

## What works

Checked by the tests in `t/` and `xt/`:

- Read: integer PCM 8/16/24/32 bit, IEEE float 32/64 bit, plain or
  WAVE_FORMAT_EXTENSIBLE (PCM or float SubFormat; 24 valid bits in a 32-bit
  container), `RIFF` and `RF64` files, mono to 6 channels.
- Chunks before and after `data` (`LIST`, `JUNK`), odd-sized chunks, a `fmt `
  chunk of 18 bytes, a truncated file and a streaming writer's
  `0xFFFFFFFF` data size.
- Write: the same sample formats; float data can be quantised to 8/16/24/32-bit
  PCM (rounded half to even, clipped), integer data is written as it is;
  `long` can be written as 24-bit.
- `start`/`frames` windows, `normalize` (exact: power-of-two scaling), `signed`
  for 8-bit PCM, `mmap` (copy-on-write view; falls back to a normal read for
  24-bit PCM).
- Errors, not wrong output, for: not a WAV file, missing chunks, format tags
  other than PCM/float (tested with ADPCM), sample sizes that are not 8/16/24/32, mismatched block
  alignment, a foreign extensible SubFormat, integer data written with a
  `bits` that does not fit its type, 24-bit values out of range, NaN/Inf for
  PCM output, data above 4 GiB (RF64 is not written).

### Tests

```
perl Makefile.PL && make && make test      # 737 tests, about 1 second
prove -l xt/                               # needs sox, ffmpeg, python3 (each is skipped if missing)
```

- `t/01-fixtures.t` reads 19 files built byte by byte by `author/make_fixtures.py`
  (Python `struct`/`numpy`, independent of this module) and compares every
  sample with the values the generator wrote. `python3 author/make_fixtures.py`
  regenerates `t/data/`.
- `t/02-roundtrip.t` writes and reads back every type x 1/2/3 channels x
  0/1/2/7/1001 frames, checks the exact bytes of the headers, the quantising
  rules, and blocks of different sizes.
- Every test that compares data compares all elements, and has a negative
  control (values +1, frames shifted) that must not compare equal. With 20
  deliberate defects put into the module one at a time (no sign extension,
  wrong byte lane, no pad byte, floor instead of rint, wrong block offset, ...)
  the suite failed for all 20.
- `xt/10-crosscheck.t` compares with sox 14.4.2, ffmpeg and Python's `wave`:
  files made by those tools are read to the same values as they decode to
  themselves (including an `RF64` file from `ffmpeg -rf64 always`), and files
  written by `wwav` are read by them to the same values `rwav` returns.
  (sox cannot read an extensible file with valid bits below the container size,
  so that fixture is not compared with sox.)

Tested with perl 5.38.2 on Linux x86_64 (little-endian), with PDL 2.085 and with PDL 2.104
(`t/` and `xt/` pass with both; the example scripts give the same output with both).

## Measurements

`bench/wav_io_bench.pl`: 10 minutes, 48 kHz, 2 channels (16-bit: 115 MB,
24-bit: 173 MB). Intel Xeon 2.8 GHz, 2 vCPU, Linux, perl 5.38.2, PDL 2.085.
Each variant runs in its own process; "old" is the code in
`extend_wav_plateau.pl` before it used this module (whole file read into one
scalar, `substr`, then assigned to a `zeroes()` ndarray). Single runs; times
vary by about 20 % from run to run. Peak RSS includes perl itself (about 13 MB).
For the three rows marked `*` the peak includes the 460 MB double-precision input
that the benchmark creates before it times the write.

| | time | peak RSS |
|---|---|---|
| read 16-bit, old | 0.194 s | 343 MB |
| read 16-bit, `rwav` | 0.086 s | 123 MB |
| read 16-bit, `rwav(mmap => 1)` | 0.002 s | 14 MB |
| read 1 s window of 10 min, `rwav(start, frames)` | < 0.001 s | 13 MB |
| read 16-bit as double, `normalize => 1` | 0.470 s | 562 MB |
| write 16-bit, old (`pack` + `print`) | 0.072 s | 123 MB |
| write 16-bit, `wwav` | 0.056 s | 123 MB |
| write double as 16-bit PCM, `wwav(bits => 16)` * | 0.493 s | 563 MB |
| read 24-bit, plain PDL arithmetic | 2.158 s | 2320 MB |
| read 24-bit, staging array + copy | 0.518 s | 453 MB |
| read 24-bit, `rwav` | 0.343 s | 234 MB |
| write 24-bit from long, `wwav(bits => 24)` * | 0.790 s | 235 MB |

## Scripts in `examples/`

- `extend_wav_plateau.pl` - keeps the rise and fall of a WAV and repeats the
  flat part to make a longer file (STIM009 voltage checks). For PCM 8/16/32-bit
  input its output is byte-for-byte identical to the previous version of the
  script; it also handles 24-bit and keeps the input's format.
- `make_wav.pl` - writes a test WAV: sine, square, triangle, sawtooth, white or
  pink noise; frequency, level in dBFS, duration, 1 or 2 channels, PCM 8/16/24/32 or
  float 32/64. It reads the file back and prints the peak, the RMS, the frequency
  counted from zero crossings and the largest quantisation error (checked against
  sox `stat`, a numpy spectrum of the pink noise, with PDL 2.085 and 2.104).
- `plot_wav_line.pl` - waveform viewer for P:G:C (giza-server window), one
  subplot per channel; the window title names what each slider does.
  `--png FILE --pos P --zoom Z` writes one frame to a PNG without a window
  (checked with 1, 2 and 4 channels and with and without `mmap`).

## Install

```
perl Makefile.PL
make
make test
make install
```

Prerequisite: PDL. Optional: File::Map (for `mmap => 1`).

## License

Same terms as Perl itself (see `LICENSE`).
