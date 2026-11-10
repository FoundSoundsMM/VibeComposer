#!/usr/bin/env python3
"""Build lib/wavetables/vc_wavetables.wav from Adventure Kid's AKWF waveforms.

    python3 -I lib/tools/build-wavetables.py <AKWF folder> lib/wavetables

<AKWF folder> holds the AKWF-FREE "AKWF" sub-folders named below
(github.com/KristofferKarlAxelEkstrand/AKWF-FREE, CC0 1.0). Plain Python:
no numpy.

Eight banks, each a morph through eight waves picked from one AKWF family
at even steps of brightness (spectral centroid), dark to bright. What makes
the morph smooth, after the Synthesis Technology E350:

  phase coherent  within a bank every harmonic keeps one phase (whichever
                  set gives the bank's frames the least peak over RMS: each
                  key's own, the strongest key's per harmonic, or Newman's
                  low-crest phases), so a
                  crossfade between any two frames only moves harmonic
                  levels: nothing cancels, the middle of a morph never thins
  equal loudness  every frame has the same RMS
  dense           32 frames a bank, spectrally interpolated between the
                  eight keys, so neighbouring frames are near twins and a
                  per-sample crossfade between them is seamless
  mipmapped       six copies of everything, band-limited to 256, 128, 64,
                  32, 16 and 8 harmonics (a raised-cosine taper over the top
                  quarter), one per octave, so no note aliases

Layout: 16-bit mono, frames of 1025 samples (one cycle of 1024 plus the
first sample again, so linear interpolation never reads across a frame
edge), in the order level, bank, frame. The engine reads one buffer per
(level, bank): 32 x 1025 samples.
"""

import cmath
import json
import math
import os
import struct
import sys
import wave

BANKS = [
    ("BASIC", ["AKWF_bw_perfectwaves", "AKWF_bw_blended"]),
    ("HARMONIC", ["AKWF_sinharm"]),
    ("OVERTONE", ["AKWF_overtone"]),
    ("VOICE", ["AKWF_hvoice"]),
    ("ORGAN", ["AKWF_eorgan"]),
    ("FM", ["AKWF_fmsynth"]),
    ("CHIP", ["AKWF_oscchip"]),
    ("DIGITAL", ["AKWF_bitreduced"]),
]
KEYS = 8
FRAMES = 32
SIZE = 1024
LEVELS = [256, 128, 64, 32, 16, 8]
FEAT = 48          # harmonics compared when picking keys


def read_wav(path):
    with wave.open(path, "rb") as w:
        n, ch, sw = w.getnframes(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(n)
    if sw != 2:
        return None
    vals = struct.unpack("<%dh" % (n * ch), raw)
    x = [vals[i * ch] / 32768.0 for i in range(n)]
    m = sum(x) / len(x)
    return [v - m for v in x]


def dft(x, kmax):
    """Harmonics 1..kmax as complex amplitudes (cos-phase convention)."""
    n = len(x)
    out = []
    for k in range(1, kmax + 1):
        w = -2j * math.pi * k / n
        s = 0j
        for i, v in enumerate(x):
            s += v * cmath.exp(w * i)
        out.append(s * 2 / n)
    return out


def fft(a, inverse=False):
    """In-place iterative radix-2 FFT of a list of complex numbers."""
    n = len(a)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    length = 2
    sign = 1 if inverse else -1
    while length <= n:
        wl = cmath.exp(sign * 2j * math.pi / length)
        for i in range(0, n, length):
            w = 1 + 0j
            half = length // 2
            for k in range(half):
                u = a[i + k]
                v = a[i + k + half] * w
                a[i + k] = u + v
                a[i + k + half] = u - v
                w *= wl
        length <<= 1
    return a


def centroid(mags):
    e = sum(m * m for m in mags)
    if e <= 0:
        return 0
    return sum((k + 1) * m * m for k, m in enumerate(mags)) / e


def synth(mags, phases, hmax):
    """One cycle of SIZE samples: sum of m_k cos(2 pi k n / SIZE + phi_k)."""
    spec = [0j] * SIZE
    top = min(hmax, len(mags))
    t0 = 0.75 * hmax
    for k in range(1, top + 1):
        g = 1.0
        if k > t0:
            g = 0.5 * (1 + math.cos(math.pi * (k - t0) / (hmax - t0)))
        c = mags[k - 1] * g * cmath.exp(1j * phases[k - 1]) / 2
        spec[k] = c
        spec[SIZE - k] = c.conjugate()
    out = fft(spec, inverse=True)
    return [v.real for v in out]


def main():
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)
    frames_out = {}     # (level, bank, frame) -> samples
    manifest = []
    for b, (name, folders) in enumerate(BANKS):
        pool = []
        for f in folders:
            d = os.path.join(src, f)
            for fn in sorted(os.listdir(d)):
                if not fn.endswith(".wav"):
                    continue
                x = read_wav(os.path.join(d, fn))
                if not x or max(abs(v) for v in x) < 0.01:
                    continue
                feat = [abs(c) for c in dft(x, FEAT)]
                if sum(m * m for m in feat) <= 1e-9:
                    continue
                pool.append((centroid(feat), fn, x))
        pool.sort(key=lambda e: e[0])
        # eight keys at even steps of brightness, dark to bright
        picks = []
        for i in range(KEYS):
            e = pool[round(i * (len(pool) - 1) / (KEYS - 1))]
            if e not in picks:
                picks.append(e)
        keys = []
        for c, fn, x in picks:
            h = dft(x, min(len(x) // 2 - 1, LEVELS[0]))
            h += [0j] * (LEVELS[0] - len(h))
            mags = [abs(v) for v in h]
            rms = math.sqrt(sum(m * m for m in mags) / 2)
            keys.append({"file": fn, "mags": [m / rms for m in mags], "ph": [cmath.phase(v) for v in h]})
        # 32 frames, magnitudes interpolated between neighbouring keys,
        # every frame back to the same RMS
        nk = len(keys)
        fmags = []
        for f in range(FRAMES):
            s = f * (nk - 1) / (FRAMES - 1)
            i0 = min(int(math.floor(s)), nk - 2)
            t = s - i0
            mags = [(1 - t) * a + t * c for a, c in zip(keys[i0]["mags"], keys[i0 + 1]["mags"])]
            rms = math.sqrt(sum(m * m for m in mags) / 2)
            fmags.append([m / rms for m in mags])
        # one phase per harmonic for the whole bank, so the morph never
        # cancels. Which set: the one whose worst frame peaks least over its
        # RMS (headroom is shared by every bank) -- the strongest key's
        # phase per harmonic, each key's own, or Newman's low-crest phases
        H = LEVELS[0]
        cands = [("strongest", [max(keys, key=lambda kk: kk["mags"][k])["ph"][k] for k in range(H)])]
        for i, kk in enumerate(keys):
            cands.append(("key %d" % (i + 1), kk["ph"]))
        cands.append(("newman", [math.pi * (k * k) / H for k in range(H)]))
        best = None
        for label, ph in cands:
            crest = max(max(abs(v) for v in synth(m, ph, H)) for m in fmags)
            if best is None or crest < best[0]:
                best = (crest, label, ph)
        phases = best[2]
        for f in range(FRAMES):
            for L, hmax in enumerate(LEVELS):
                frames_out[(L, b, f)] = synth(fmags[f], phases, hmax)
        manifest.append({"bank": name, "keys": [k["file"] for k in keys], "phases": best[1],
                         "crest": round(best[0], 2)})
        print("%-9s %3d waves, phases %-9s crest %.1f -> %s" % (name, len(pool), best[1], best[0],
              ", ".join(k["file"].replace(".wav", "").replace("AKWF_", "") for k in keys)))

    peak = max(max(abs(v) for v in fr) for fr in frames_out.values())
    scale = 0.95 / peak
    data = bytearray()
    for L in range(len(LEVELS)):
        for b in range(len(BANKS)):
            for f in range(FRAMES):
                fr = frames_out[(L, b, f)]
                cyc = fr + [fr[0]]
                data += struct.pack("<%dh" % len(cyc), *[max(-32767, min(32767, round(v * scale * 32767))) for v in cyc])
    path = os.path.join(dst, "vc_wavetables.wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(48000)
        w.writeframes(bytes(data))
    with open(os.path.join(dst, "manifest.json"), "w") as fh:
        json.dump({"levels": LEVELS, "frames": FRAMES, "size": SIZE, "stride": SIZE + 1,
                   "banks": manifest, "rms_gain": scale}, fh, indent=1)
    print("wrote %s (%d bytes), rms gain %.4f" % (path, len(data) + 44, scale))


if __name__ == "__main__":
    main()
