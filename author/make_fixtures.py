#!/usr/bin/env python3
"""make_fixtures.py - generate the WAV fixtures in t/data/ (author tool, not run by `make test`).

The WAV files are built byte by byte with struct/numpy from the RIFF/WAVE
layout, independently of PDL::IO::WAV, so that the tests compare the module
against a second implementation instead of against itself.

For every fixture it also writes NAME.txt with the expected samples
(first line: "channels frames kind", then one line per frame) and adds an entry
to manifest.json.  Integer fixtures store the raw values exactly as they are
in the file (8-bit PCM: unsigned 0..255).

    python3 author/make_fixtures.py          # run from the dist root
"""
import json
import os
import struct

import numpy as np

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 't', 'data')
GUID_TAIL = bytes([0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00,
                   0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
manifest = {}


def chunk(cid, body):
    """RIFF chunk with the pad byte for odd sizes."""
    return cid + struct.pack('<I', len(body)) + body + (b'\0' if len(body) & 1 else b'')


def fmt_plain(tag, ch, rate, bits, size18=False):
    align = ch * bits // 8
    body = struct.pack('<HHIIHH', tag, ch, rate, rate * align, align, bits)
    if size18:
        body += struct.pack('<H', 0)
    return chunk(b'fmt ', body)


def fmt_ext(subtag, ch, rate, container_bits, valid_bits, mask):
    align = ch * container_bits // 8
    body = struct.pack('<HHIIHH', 0xFFFE, ch, rate, rate * align, align, container_bits)
    body += struct.pack('<HHI', 22, valid_bits, mask)
    body += struct.pack('<H', subtag) + GUID_TAIL
    return chunk(b'fmt ', body)


def riff(chunks, container=b'RIFF', size=None):
    body = b'WAVE' + b''.join(chunks)
    return container + struct.pack('<I', len(body) if size is None else size) + body


def ints(rng, n, ch, lo, hi):
    """int64 (n, ch): extremes first, then uniform over the whole range."""
    x = rng.randint(lo, hi + 1, size=(n, ch)).astype(np.int64)
    edge = [lo, hi, -1 if lo < 0 else lo + 1, 0 if lo < 0 else (lo + hi) // 2, 1]
    for i, v in enumerate(edge):
        x[i % n, :] = v
    return x


def pcm_bytes(x, bits):
    """Little-endian interleaved bytes of an int64 (n, ch) array."""
    if bits == 8:
        return x.astype('<u1').tobytes()
    if bits == 16:
        return x.astype('<i2').tobytes()
    if bits == 24:
        return x.astype('<i4').view('u1').reshape(-1, 4)[:, :3].tobytes()
    if bits == 32:
        return x.astype('<i4').tobytes()
    raise ValueError(bits)


def save(name, wav, expected, kind, **meta):
    n, ch = expected.shape
    with open(os.path.join(OUT, name + '.wav'), 'wb') as f:
        f.write(wav)
    with open(os.path.join(OUT, name + '.txt'), 'w') as f:
        f.write('%d %d %s\n' % (ch, n, kind))
        for row in expected:
            f.write(' '.join(repr(float(v)) if kind == 'float' else str(int(v)) for v in row) + '\n')
    meta.update(channels=ch, frames=n, kind=kind)
    manifest[name] = meta


def pcm_fixture(name, bits, ch, n, seed, rate=48000, **kw):
    rng = np.random.RandomState(seed)
    if bits == 8:
        x = ints(rng, n, ch, 0, 255)
    else:
        x = ints(rng, n, ch, -(1 << (bits - 1)), (1 << (bits - 1)) - 1)
    data = pcm_bytes(x, bits)
    chunks = [fmt_plain(1, ch, rate, bits), chunk(b'data', data)]
    save(name, riff(chunks), x, 'int', format='pcm', bits=bits, rate=rate, **kw)
    return x


def float_fixture(name, bits, ch, n, seed, rate=44100, **kw):
    rng = np.random.RandomState(seed)
    if bits == 32:       # multiples of 1/256: exactly representable in float32
        x = rng.randint(-256, 256, size=(n, ch)).astype(np.float64) / 256.0
        x[0, :] = -1.0
        x[1 % n, :] = 255 / 256.0
        data = x.astype('<f4').tobytes()
    else:
        x = rng.uniform(-1, 1, size=(n, ch))
        x[0, :] = -1.0
        data = x.astype('<f8').tobytes()
    chunks = [fmt_plain(3, ch, rate, bits), chunk(b'data', data)]
    save(name, riff(chunks), x, 'float', format='float', bits=bits, rate=rate, **kw)
    return x


os.makedirs(OUT, exist_ok=True)

# --- plain files, every format x channel layout ---------------------------
pcm_fixture('pcm8_mono_odd',   8, 1, 1001, 1)      # odd data size -> pad byte after data
pcm_fixture('pcm8_stereo',     8, 2, 997, 2)
pcm_fixture('pcm16_mono',     16, 1, 997, 3)
pcm_fixture('pcm16_stereo',   16, 2, 997, 4)
pcm_fixture('pcm24_mono',     24, 1, 997, 5)
pcm_fixture('pcm24_stereo',   24, 2, 997, 6)
pcm_fixture('pcm32_stereo',   32, 2, 997, 7)
float_fixture('f32_stereo',   32, 2, 997, 8)
float_fixture('f64_mono',     64, 1, 997, 9)

# --- structure variations ---------------------------------------------------
rng = np.random.RandomState(10)
x = ints(rng, 400, 2, -32768, 32767)
data = pcm_bytes(x, 16)
junk = chunk(b'JUNK', b'abcde')                       # odd size, padded
lst = chunk(b'LIST', b'INFOISFT' + struct.pack('<I', 6) + b'abcde\0')
save('pcm16_chunks_before',
     riff([junk, fmt_plain(1, 2, 8000, 16), lst, chunk(b'data', data)]),
     x, 'int', format='pcm', bits=16, rate=8000, note='JUNK/LIST before and between fmt and data')
save('pcm16_chunks_after',
     riff([fmt_plain(1, 2, 8000, 16), chunk(b'data', data), lst, junk]),
     x, 'int', format='pcm', bits=16, rate=8000, note='LIST/JUNK after data')
save('pcm16_fmt18',
     riff([fmt_plain(1, 2, 8000, 16, size18=True), chunk(b'data', data)]),
     x, 'int', format='pcm', bits=16, rate=8000, note='fmt chunk of 18 bytes (cbSize = 0)')

# truncated: data chunk claims 1000 bytes more than the file holds
whole = riff([fmt_plain(1, 2, 8000, 16), b'data' + struct.pack('<I', len(data) + 1000) + data])
save('pcm16_truncated', whole, x, 'int', format='pcm', bits=16, rate=8000, truncated=1)

# streaming writer: data size 0xFFFFFFFF, runs to end of file
whole = riff([fmt_plain(1, 2, 8000, 16), b'data' + struct.pack('<I', 0xFFFFFFFF) + data])
save('pcm16_stream', whole, x, 'int', format='pcm', bits=16, rate=8000, truncated=1)

# RF64 with a ds64 chunk and 0xFFFFFFFF placeholders
ds64 = chunk(b'ds64', struct.pack('<QQQI', 0, len(data), len(x), 0))
whole = riff([ds64, fmt_plain(1, 2, 8000, 16), b'data' + struct.pack('<I', 0xFFFFFFFF) + data],
             container=b'RF64', size=0xFFFFFFFF)
save('rf64_pcm16', whole, x, 'int', format='pcm', bits=16, rate=8000, container='RF64')

# --- WAVE_FORMAT_EXTENSIBLE -----------------------------------------------------
rng = np.random.RandomState(11)
x = ints(rng, 300, 6, -32768, 32767)
save('ext_pcm16_6ch',
     riff([fmt_ext(1, 6, 48000, 16, 16, 0x3F), chunk(b'data', pcm_bytes(x, 16))]),
     x, 'int', format='pcm', bits=16, rate=48000, extensible=1, channel_mask=0x3F)

rng = np.random.RandomState(12)
x = ints(rng, 500, 2, -(1 << 23), (1 << 23) - 1)
save('ext_pcm24',
     riff([fmt_ext(1, 2, 96000, 24, 24, 0x3), chunk(b'data', pcm_bytes(x, 24))]),
     x, 'int', format='pcm', bits=24, rate=96000, extensible=1, channel_mask=0x3)

# 24 valid bits left-justified in 32-bit containers (what many drivers write)
rng = np.random.RandomState(13)
x24 = ints(rng, 500, 2, -(1 << 23), (1 << 23) - 1)
x = x24 << 8
save('ext_pcm32_valid24',
     riff([fmt_ext(1, 2, 96000, 32, 24, 0x3), chunk(b'data', pcm_bytes(x, 32))]),
     x, 'int', format='pcm', bits=32, rate=96000, extensible=1, valid_bits=24)

rng = np.random.RandomState(14)
x = rng.randint(-256, 256, size=(300, 2)).astype(np.float64) / 256.0
save('ext_f32',
     riff([fmt_ext(3, 2, 48000, 32, 32, 0x3), chunk(b'data', x.astype('<f4').tobytes())]),
     x, 'float', format='float', bits=32, rate=48000, extensible=1)

with open(os.path.join(OUT, 'manifest.json'), 'w') as f:
    json.dump(manifest, f, indent=1, sort_keys=True)
print('wrote %d fixtures to %s' % (len(manifest), os.path.normpath(OUT)))
