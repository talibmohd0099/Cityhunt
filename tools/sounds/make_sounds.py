#!/usr/bin/env python3
"""
make_sounds.py - offline renderer for the Lost City sound effects (Godot port).

The browser game (index.html, "AUDIO" section: initAudio, envG, outNode, noiseSrc, sThud, sGrowl,
sClicks, sHeart, sStep, sChime, sClick, sSob, sThunder, sSiren, sStinger, and sAlarm) synthesises
all of its audio live with WebAudio.  Godot needs files, so this script re-implements the WebAudio
building blocks those functions use and renders every sound offline:

    python3 tools/sounds/make_sounds.py

Python 3 standard library only.  Output goes to godot/assets/sounds/: mono 16-bit PCM WAV at
22050 Hz, plus sounds.json (the manifest).  Every random choice comes from a fixed seed, so the
output is identical on every run.

What is emulated (and how closely)
  * OscillatorNode: sine / square / sawtooth / triangle, phase 0 at start(), with a-rate
    frequency automation and modulation (LFO -> GainNode -> frequency).  Square and saw are
    band-limited (PolyBLEP) and scaled by SAW_SQUARE_NORM, because Chrome normalises its built-in
    wavetables by the peak of the full-band table (Gibbs overshoot 1.179).  Triangle and sine
    have peak 1.
  * AudioBufferSourceNode noise: the game's two 2 s buffers (AU.noise white, AU.brown
    "last=(last+0.02*w)/1.02; out=last*3.5"), started at a random offset of 0-1.5 s, optional
    playbackRate with linear interpolation.  As in WebAudio these sources do NOT loop: they fall
    silent at the end of the 2 s buffer (this matters for sThunder and long sGrowls, see notes).
  * BiquadFilterNode lowpass / highpass / bandpass: WebAudio spec (Audio EQ Cookbook) formulas.
    Lowpass/highpass read Q as a resonance in dB (Q_lin = 10^(Q/20); default Q=1 -> 1.122,
    about +1 dB at the cutoff); bandpass reads Q linearly (default 1).  See LPHP_DEFAULT_Q_DB.
    Automated frequencies get per-sample coefficients (as in Chrome).
  * AudioParam automation: setValueAtTime, linearRampToValueAtTime,
    exponentialRampToValueAtTime, setTargetAtTime, evaluated per sample.
  * DelayNode + feedback GainNode loop (sSiren).

Sample rate
  Everything is rendered at FS = 44100 Hz, close to the 44.1/48 kHz the browser runs at, so
  filters near the top of the band (the 4-8 kHz lowpasses) and oscillator band-limiting behave
  as they do in the browser.  The result goes through a Kaiser half-band FIR down to 22050 Hz.
  The brown-noise one-pole depends on sample rate (at 48 kHz its corner is about 150 Hz), so it
  is re-tuned to sound like the 48 kHz buffer (JS_RATE), and white noise is scaled so its
  per-Hz level matches too.

Loudness contract (the manifest's "gain")
  Each JS sound is rendered at the level the JS produces for vol=1, i.e. the signal that enters
  outNode(vol, pan, lp), with no per-call gain, pan or lowpass.  The per-call lowpass is
  distance/occlusion and the Godot side does it.  Lowpasses that are always the same are baked
  in: sChime 6000, sClick 8000, sHeart 300, sStinger 3000, sThunder 900, sSiren 1600,
  sStep 5200 wet / 2600 dry.  Each file is then peak-normalised to 0.9 and
      gain = original_peak / 0.9
  so playing a file at linear volume  vol * gain  (volume_db = linear_to_db(vol*gain))
  reproduces the JS amplitude, before the master gain (0.95*SET.vol/100) and the master
  DynamicsCompressor (threshold -14 dB, ratio 4, knee 30, attack 3 ms, release 250 ms).
  The new physics sounds get a designed peak level on the same scale (level= in
  build_specs), so their gain = level / 0.9.

Loops
  The loop files are exactly periodic, so the last sample flows into the first as in the middle
  of the file.  Noise loops use a circular noise excitation, filtered after a 0.5 s pre-roll
  taken from the end of the same excitation, so every filter is in steady state.  The drone's
  sines complete whole cycles in 5 s.  The alarm is 10 whole LFO periods, so the carrier also
  completes whole cycles (5000).  The FIR decimation of loops is circular as well.  A loop file
  holds one period of L frames plus one guard frame (a copy of frame 0) and a RIFF 'smpl'
  chunk with a forward loop start=0, end=L.  Godot's WAV importer reads that chunk when
  edit/loop_mode is "Detect From WAV" (the default) and wraps at L; a manual Forward loop with
  the default loop_end=-1 also resolves to L.  The manifest lists L as loop_end.
"""

import array
import json
import math
import os
import random
import struct
import sys
import time
import wave

# ----------------------------------------------------------------------------- configuration
OUT_RATE = 22050            # file sample rate
OVERSAMPLE = 2
FS = OUT_RATE * OVERSAMPLE  # internal render rate (44100)
JS_RATE = 48000             # sample rate the browser game is assumed to run at (noise character)
PEAK = 0.9                  # normalisation target
SEED = 20260925             # master seed, every sound gets random.Random(f"{SEED}:{name}")

# WebAudio lowpass/highpass Q is a resonance in dB; the attribute's default value is 1 (dB),
# i.e. linear Q = 10^(1/20) = 1.122.  Set to -3.0103 to get a flat Butterworth (Q = 0.7071).
LPHP_DEFAULT_Q_DB = 1.0
# Chrome normalises built-in square/saw wavetables by the full-band table's Gibbs peak.
SAW_SQUARE_NORM = 1.0 / 1.1789797
# Uniform white noise has the same variance at any rate; scale so the per-Hz density matches
# the 48 kHz buffer (0.37 dB).
WHITE_SCALE = math.sqrt(FS / JS_RATE)
# JS brown noise: last = (last + 0.02 w)/1.02 at JS_RATE.  Same time constant and same
# low-frequency density at FS:
_P48 = 1.0 / 1.02
BROWN_POLE = _P48 ** (JS_RATE / FS)
BROWN_GAIN = (0.02 / 1.02) * ((1.0 - BROWN_POLE) / (1.0 - _P48)) * math.sqrt(FS / JS_RATE)
# noiseSrc() plays the 2 s AU buffers from a random 0-1.5 s offset with loop=false, so a source
# asked for longer goes silent at the buffer end.  For sThunder that cuts the brown rumble after
# 0.5-2 s although its envelope runs to 5.5 s.  True reproduces that; False renders the full
# 5.5 s rumble the envelope asks for.  (sGrowl's noise is cut the same way and always rendered
# faithfully: it is a minor part of the growl.)
FAITHFUL_BUFFER_TRUNCATION = True

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, '..', '..', 'godot', 'assets', 'sounds'))

TWO_PI = 2.0 * math.pi


def N(sec):
    """Number of internal samples in `sec` seconds."""
    return int(round(sec * FS))


def t2i(t):
    """First internal sample index whose time is >= t."""
    return int(math.ceil(t * FS - 1e-7))


# ----------------------------------------------------------------------------- vector helpers
def zeros(n):
    return [0.0] * n


def mul(a, b):
    return [x * y for x, y in zip(a, b)]


def scale(a, g):
    return [x * g for x in a]


def add(a, b):
    return [x + y for x, y in zip(a, b)]


def add_at(dst, src, i0=0, g=1.0):
    """dst[i0:] += g*src (clipped to dst)."""
    n = len(dst)
    if i0 >= n:
        return
    m = min(len(src), n - i0)
    dst[i0:i0 + m] = [a + g * b for a, b in zip(dst[i0:i0 + m], src)]


def add_circular(dst, src, i0, g=1.0):
    """dst[(i0+k) % len] += g*src[k] (for loops)."""
    L = len(dst)
    for k, v in enumerate(src):
        dst[(i0 + k) % L] += g * v


def fade_out(x, sec):
    """Half-cosine fade to exactly 0 over the last `sec` seconds (in place)."""
    m = min(len(x), max(1, N(sec)))
    for k in range(m):
        x[-1 - k] *= 0.5 - 0.5 * math.cos(math.pi * k / m)
    return x


# ----------------------------------------------------------------------------- AudioParam
class Param:
    """WebAudio AudioParam with a-rate automation, evaluated at sample times k/FS."""

    def __init__(self, value):
        self.value = float(value)
        self.ev = []

    def set(self, v, t):
        self.ev.append((t, 'set', float(v), 0.0))
        return self

    def lin(self, v, t):
        self.ev.append((t, 'lin', float(v), 0.0))
        return self

    def exp(self, v, t):
        self.ev.append((t, 'exp', float(v), 0.0))
        return self

    def target(self, v, t, tau):
        self.ev.append((t, 'target', float(v), float(tau)))
        return self

    @staticmethod
    def _state_value(st, t):
        if st[0] == 'hold':
            return st[1]
        _, t0, v0, v1, tau = st
        return v1 + (v0 - v1) * math.exp(-(t - t0) / tau)

    @staticmethod
    def _fill(out, i0, i1, st):
        if i1 <= i0:
            return
        if st[0] == 'hold':
            out[i0:i1] = [st[1]] * (i1 - i0)
        else:
            _, t0, v0, v1, tau = st
            for i in range(i0, i1):
                out[i] = v1 + (v0 - v1) * math.exp(-(i / FS - t0) / tau)

    @staticmethod
    def _ramp(out, i0, i1, t0, v0, t1, v1, kind):
        if i1 <= i0:
            return
        span = t1 - t0
        if span <= 0.0:
            out[i0:i1] = [v1] * (i1 - i0)
        elif kind == 'lin':
            dv = v1 - v0
            for i in range(i0, i1):
                out[i] = v0 + dv * ((i / FS - t0) / span)
        elif v0 == 0.0 or v1 == 0.0 or (v0 > 0.0) != (v1 > 0.0):
            out[i0:i1] = [v0] * (i1 - i0)          # spec: invalid exponential ramp holds V0
        else:
            lr = math.log(v1 / v0) / span
            ex = math.exp
            for i in range(i0, i1):
                out[i] = v0 * ex(lr * (i / FS - t0))

    def render(self, n):
        if not self.ev:
            return [self.value] * n
        ev = sorted(self.ev, key=lambda e: e[0])   # stable: same-time events keep call order
        out = [0.0] * n
        idx = 0
        st = ('hold', self.value)                  # intrinsic value until the first event
        at, av = 0.0, self.value                   # (time, value) a following ramp starts from
        for (t, kind, v, tau) in ev:
            end = min(n, max(idx, t2i(t)))
            if kind in ('lin', 'exp'):
                self._ramp(out, idx, end, at, av, t, v, kind)
                st = ('hold', v)
                at, av = t, v
            else:
                self._fill(out, idx, end, st)
                v0 = self._state_value(st, t)
                if kind == 'set':
                    st = ('hold', v)
                    at, av = t, v
                else:
                    st = ('target', t, v0, v, tau)
                    at, av = t, v0
            idx = end
        self._fill(out, idx, n, st)
        return out


def envG(t, a, peak, d):
    """The game's envG(): 0.0001 -> exp to peak in a seconds -> exp to 0.0001 in d seconds."""
    return Param(1.0).set(0.0001, t).exp(max(peak, 0.0002), t + a).exp(0.0001, t + a + d)


# ----------------------------------------------------------------------------- sources
def osc(n, typ, freq, start=0.0, stop=None, fm=None):
    """OscillatorNode.  freq: number or Param (intrinsic value); fm: per-sample list added to the
    frequency (an LFO through a GainNode connected to .frequency).  Phase 0 at start."""
    out = [0.0] * n
    i0 = max(0, t2i(start))
    i1 = n if stop is None else min(n, t2i(stop))
    if i0 >= i1:
        return out
    if isinstance(freq, Param):
        fa = freq.render(n) if freq.ev else None
        fc = freq.value
    else:
        fa, fc = None, float(freq)
    if fm is not None:
        fa = [fc + m for m in fm] if fa is None else [a + m for a, m in zip(fa, fm)]
    inv = 1.0 / FS
    sin = math.sin
    if typ == 'sine':
        if fa is None:
            w = TWO_PI * fc * inv
            for i in range(i0, i1):
                out[i] = sin(w * (i - i0))
        else:
            p = 0.0
            for i in range(i0, i1):
                out[i] = sin(TWO_PI * p)
                p += fa[i] * inv
                p -= math.floor(p)
        return out
    if typ == 'triangle':
        # harmonics fall at 12 dB/octave; at 44.1 kHz naive aliasing is below -65 dB
        p = 0.0
        for i in range(i0, i1):
            q = p + 0.25
            q -= math.floor(q)
            out[i] = 1.0 - 4.0 * abs(q - 0.5)
            p += (fa[i] if fa is not None else fc) * inv
            p -= math.floor(p)
        return out
    norm = SAW_SQUARE_NORM
    saw = typ == 'sawtooth'
    if not saw and typ != 'square':
        raise ValueError(typ)
    p = 0.0
    for i in range(i0, i1):
        dt = (fa[i] if fa is not None else fc) * inv
        if saw:
            # WebAudio saw: 0 at phase 0, rising to +1, jump to -1 at half cycle
            t = p + 0.5
            if t >= 1.0:
                t -= 1.0
            v = 2.0 * t - 1.0
            if t < dt:
                x = t / dt
                v -= x + x - x * x - 1.0
            elif t > 1.0 - dt:
                x = (t - 1.0) / dt
                v -= x * x + x + x + 1.0
        else:
            # WebAudio square: +1 for the first half cycle
            v = 1.0 if p < 0.5 else -1.0
            if p < dt:
                x = p / dt
                v += x + x - x * x - 1.0
            elif p > 1.0 - dt:
                x = (p - 1.0) / dt
                v += x * x + x + x + 1.0
            t = p + 0.5
            if t >= 1.0:
                t -= 1.0
            if t < dt:
                x = t / dt
                v -= x + x - x * x - 1.0
            elif t > 1.0 - dt:
                x = (t - 1.0) / dt
                v -= x * x + x + x + 1.0
        out[i] = v * norm
        p += dt
        p -= math.floor(p)
    return out


def white(rng, n, g=1.0):
    """Math.random()*2-1 (times g)."""
    r = rng.random
    return [(r() * 2.0 - 1.0) * g for _ in range(n)]


def brown_of(w):
    """initAudio brown noise, from uniform(-1,1) white input, re-tuned to sound like JS_RATE."""
    p, g = BROWN_POLE, BROWN_GAIN
    last = 0.0
    out = [0.0] * len(w)
    for i, v in enumerate(w):
        last = p * last + g * v
        out[i] = 3.5 * last
    return out


def brown_noise(rng, n):
    """Fresh brown noise already in steady state (the 1-pole settles in ~1 ms)."""
    pre = 400
    return brown_of(white(rng, n + pre))[pre:]


def noise_src(n, buf, t, dur, rate=None, offset=0.0):
    """The game's noiseSrc(): buffer source started at t with `offset` seconds into the buffer,
    stopped at t+dur, loop=false (silent once the buffer end is reached)."""
    out = [0.0] * n
    i0 = max(0, t2i(t))
    i1 = min(n, t2i(t + dur))
    L = len(buf)
    if not rate or rate == 1.0:
        s = int(round(offset * FS))
        cnt = max(0, min(i1 - i0, L - s))
        out[i0:i0 + cnt] = buf[s:s + cnt]
    else:
        pos = offset * FS
        for i in range(i0, i1):
            k = int(pos)
            if k + 1 >= L:
                break
            a = buf[k]
            out[i] = a + (buf[k + 1] - a) * (pos - k)
            pos += rate
    return out


def noise_len(t_dur, offset, rate=1.0):
    """How long noise_src actually sounds (seconds)."""
    return min(t_dur, (2.0 - offset) / rate)


# ----------------------------------------------------------------------------- processors
def bq_coefs(typ, f, Q):
    f = min(max(f, 1.0), FS * 0.5 - 1.0)
    w0 = TWO_PI * f / FS
    cw = math.cos(w0)
    sw = math.sin(w0)
    if typ == 'lowpass':
        alpha = sw / (2.0 * 10.0 ** (Q / 20.0))
        b0 = (1.0 - cw) * 0.5
        b1 = 1.0 - cw
        b2 = b0
    elif typ == 'highpass':
        alpha = sw / (2.0 * 10.0 ** (Q / 20.0))
        b0 = (1.0 + cw) * 0.5
        b1 = -(1.0 + cw)
        b2 = b0
    elif typ == 'bandpass':
        alpha = sw / (2.0 * Q)
        b0 = alpha
        b1 = 0.0
        b2 = -alpha
    else:
        raise ValueError(typ)
    a0 = 1.0 + alpha
    return b0 / a0, b1 / a0, b2 / a0, (-2.0 * cw) / a0, (1.0 - alpha) / a0


def biquad(x, typ, freq, Q=None):
    """BiquadFilterNode (direct form I).  freq: number or Param (per-sample coefficients)."""
    if Q is None:
        Q = LPHP_DEFAULT_Q_DB if typ in ('lowpass', 'highpass') else 1.0
    n = len(x)
    y = [0.0] * n
    x1 = x2 = y1 = y2 = 0.0
    if isinstance(freq, Param) and freq.ev:
        fa = freq.render(n)
        last_f = None
        for i in range(n):
            f = fa[i]
            if f != last_f:
                b0, b1, b2, a1, a2 = bq_coefs(typ, f, Q)
                last_f = f
            xi = x[i]
            yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = xi
            y2 = y1
            y1 = yi
            y[i] = yi
        return y
    f = freq.value if isinstance(freq, Param) else float(freq)
    b0, b1, b2, a1, a2 = bq_coefs(typ, f, Q)
    for i in range(n):
        xi = x[i]
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = xi
        y2 = y1
        y1 = yi
        y[i] = yi
    return y


def delay_feedback(x, delay, fb):
    """x -> DelayNode(delay) <-> GainNode(fb) loop; returns the feedback gain's output
    (sSiren sends it to `out` next to the dry signal)."""
    D = N(delay)
    n = len(x)
    e = [0.0] * n
    for i in range(D, n):
        e[i] = fb * (x[i - D] + e[i - D])
    return e


def decay_env(n, attack, tau, t0=0.0):
    """Linear attack then exponential decay (time constant tau) starting at t0.  Used by the
    new sounds."""
    out = [0.0] * n
    i0 = max(0, t2i(t0))
    ia = max(1, N(attack))
    k = math.exp(-1.0 / (tau * FS))
    v = 1.0
    for i in range(i0, n):
        j = i - i0
        if j < ia:
            out[i] = j / ia
        else:
            out[i] = v
            v *= k
    return out


def add_partial(out, f, t0, amp, tau, attack=0.0005):
    """Add a decaying sine partial (phase 0 at t0, linear attack, exponential decay)."""
    n = len(out)
    i0 = t2i(t0)
    ia = max(1, N(attack))
    k = math.exp(-1.0 / (tau * FS))
    iend = min(n, i0 + int(tau * FS * 9.5))       # ~ -82 dB
    w = TWO_PI * f / FS
    env = amp
    sin = math.sin
    for i in range(max(0, i0), iend):
        j = i - i0
        if j < ia:
            out[i] += amp * (j / ia) * sin(w * j)
        else:
            out[i] += env * sin(w * j)
            env *= k


# ----------------------------------------------------------------------------- resampling
def _bessel_i0(x):
    s = term = 1.0
    k = 1
    while term > 1e-14 * s:
        term *= (x / (2.0 * k)) ** 2
        s += term
        k += 1
    return s


def halfband_taps(K=47, beta=7.0):
    """Kaiser-windowed half-band lowpass: 2K+1 = 95 taps; about 70 dB stopband from about
    12.05 kHz, passband flat to about 10 kHz at the 44.1 kHz input rate.  Returns the odd taps
    [(j, h_j)]; h_0 = 0.5 and the even taps are 0."""
    M = K + 1
    taps = []
    for j in range(1, K + 1, 2):
        ideal = math.sin(math.pi * j / 2.0) / (math.pi * j)
        r = j / M
        taps.append([j, ideal * _bessel_i0(beta * math.sqrt(1.0 - r * r)) / _bessel_i0(beta)])
    s = sum(h for _, h in taps)
    for t in taps:
        t[1] *= 0.25 / s                 # unity DC gain: 0.5 + 2*sum(odd) = 1
    return taps


TAPS = halfband_taps()


def decimate(x, circular=False):
    """FS -> OUT_RATE, zero phase.  circular=True treats x as one period of a loop."""
    x = list(x)
    if len(x) % 2:
        if circular:
            raise ValueError('loop length must be even at the internal rate')
        x.append(0.0)
    M = len(x) // 2
    ev = x[0::2]
    od = x[1::2]
    P = (TAPS[-1][0] + 1) // 2 + 1
    if circular:
        odp = od[-P:] + od + od[:P]
    else:
        odp = [0.0] * P + od + [0.0] * P
    y = [0.5 * v for v in ev]
    for j, h in TAPS:
        a = (j - 1) // 2
        b = (j + 1) // 2
        s1 = odp[P + a:P + a + M]
        s2 = odp[P - b:P - b + M]
        y = [yy + h * (u + w) for yy, u, w in zip(y, s1, s2)]
    return y


def finish_oneshot(x):
    """Decimate, cut the tail once it stays below -80 dB of the peak, end on an exact 0."""
    y = decimate(x)
    pk = max(abs(v) for v in y) or 1.0
    thr = pk * 1e-4
    last = len(y) - 1
    while last > 0 and abs(y[last]) < thr:
        last -= 1
    y = y[:min(len(y), last + 1 + int(0.002 * OUT_RATE))]
    m = min(len(y), int(0.003 * OUT_RATE))
    for k in range(m):
        y[-1 - k] *= 0.5 - 0.5 * math.cos(math.pi * k / m)
    return y


def finish_loop(x):
    return decimate(x, circular=True)


def periodic(rng, L, chain, preroll=0.5):
    """Exactly periodic filtered noise: circular white excitation (uniform -1..1) of L samples;
    the chain (brown generator and filters) is run over [last `preroll` s of it] + [all of it] and
    the pre-roll is dropped, so every recursive filter is in steady state and sample L-1 flows
    into sample 0."""
    w = white(rng, L)
    P = N(preroll)
    return chain(w[-P:] + w)[P:]


# ----------------------------------------------------------------------------- AU buffers
_AU = {}


def AU(name):
    """AU.noise / AU.brown: 2 s buffers built once, like initAudio (at the internal rate)."""
    if not _AU:
        r = random.Random('%d:initAudio' % SEED)
        _AU['noise'] = white(r, 2 * FS, WHITE_SCALE)
        _AU['brown'] = brown_of(white(r, 2 * FS))
    return _AU[name]


# ============================================================================= JS sounds
def js_thud(rng):
    """sThud: monster footstep."""
    n = N(0.75)
    t = 0.0
    f = Param(78).set(78, t).exp(30, t + 0.35)
    out = mul(osc(n, 'sine', f, t, t + 0.7), envG(t, 0.01, 1.0, 0.5).render(n))
    o1 = rng.random() * 1.5
    nb = biquad(noise_src(n, AU('brown'), t, 0.5, offset=o1), 'lowpass', 500)
    out = add(out, mul(nb, envG(t, 0.005, 1.2, 0.35).render(n)))
    o2 = rng.random() * 1.5
    nw = biquad(noise_src(n, AU('noise'), t, 0.2, offset=o2), 'bandpass', 1400)
    out = add(out, mul(nw, envG(t, 0.003, 0.18, 0.12).render(n)))
    return out, {'noise_offsets': [round(o1, 3), round(o2, 3)]}


def js_growl(rng, dur, roar):
    """sGrowl(vol,pan,lp,dur,roar)."""
    n = N(dur + 0.15)
    t = 0.0
    bpf = (Param(350).set(260 if roar else 180, t)
           .lin(900 if roar else 320, t + dur * 0.35)
           .lin(300 if roar else 160, t + dur))
    g = (Param(1).set(0.0001, t).exp(1, t + (0.12 if roar else 0.3))
         .set(1, t + dur * 0.6).exp(0.0001, t + dur))
    src = zeros(n)
    for f in (44, 46.5, 69):
        fp = Param(f).set(f * (1.6 if roar else 1), t).lin(f * (1.1 if roar else 0.85), t + dur)
        lfo = osc(n, 'sine', 23 if roar else 13, t, t + dur + 0.1)
        src = add(src, osc(n, 'sawtooth', fp, t, t + dur + 0.1, fm=scale(lfo, f * 0.08)))
    off = rng.random() * 1.5
    src = add(src, scale(noise_src(n, AU('noise'), t, dur + 0.1, offset=off), 0.7 if roar else 0.35))
    y = mul(biquad(src, 'bandpass', bpf, 3), g.render(n))
    return y, {'dur': dur, 'roar': roar, 'noise_offset': round(off, 3),
               'noise_s': round(noise_len(dur + 0.1, off), 3)}


def js_clicks(rng):
    """sClicks: 6-13 square blips through a 900 Hz bandpass.  Note the JS spaces click i at
    i*(0.045+rand*0.03), so neighbouring clicks may overlap or swap order."""
    k = 6 + int(rng.random() * 8)
    times, freqs = [], []
    for i in range(k):
        times.append(i * (0.045 + rng.random() * 0.03))
        freqs.append(180 + rng.random() * 120)
    n = N(max(times) + 0.08)
    out = zeros(n)
    m = N(0.07)
    for t, fr in zip(times, freqs):
        y = biquad(osc(m, 'square', fr, 0, 0.05), 'bandpass', 900, 4)
        add_at(out, mul(y, envG(0, 0.002, 0.5, 0.03).render(m)), t2i(t))
    return out, {'count': k}


def js_heart(rng):
    """sHeart: two sine thumps, fixed outNode lowpass 300 baked."""
    n = N(0.47)
    out = zeros(n)
    m = N(0.26)
    for dt, a in ((0.0, 1.0), (0.16, 0.7)):
        f = Param(58).set(58, 0).exp(38, 0.12)
        add_at(out, mul(osc(m, 'sine', f, 0, 0.25), envG(0, 0.012, a, 0.14).render(m)), t2i(dt))
    return biquad(out, 'lowpass', 300), {}


def js_step(rng, wet, rate):
    """sStep: noise tick, fixed outNode lowpass (5200 wet / 2600 dry) baked."""
    n = N(0.2)
    off = rng.random() * 1.5
    s = noise_src(n, AU('noise'), 0, 0.12, rate=rate, offset=off)
    s = biquad(s, 'highpass', 900 if wet else 400)
    s = mul(s, envG(0, 0.004, 1, 0.07).render(n))
    return biquad(s, 'lowpass', 5200 if wet else 2600), {'rate': round(rate, 3)}


def js_chime(rng):
    """sChime: C5/G5/C6 sines, fixed outNode lowpass 6000 baked."""
    n = N(2.05)
    out = zeros(n)
    for f, a in ((523.25, 1.0), (783.99, 0.6), (1046.5, 0.3)):
        out = add(out, mul(osc(n, 'sine', f, 0, 2), envG(0, 0.01, a, 1.8).render(n)))
    return biquad(out, 'lowpass', 6000), {}


def js_click(rng):
    """sClick: 2400 Hz square blip, fixed outNode lowpass 8000 baked.  (At 22050 Hz only its
    2400 and 7200 Hz harmonics fit; in the browser the 12/16.8 kHz ones were ~ -20 dB.)"""
    n = N(0.06)
    y = mul(osc(n, 'square', 2400, 0, 0.04), envG(0, 0.001, 0.4, 0.018).render(n))
    return biquad(y, 'lowpass', 8000), {}


SOB_PULSES = ((0.0, 0.16, 520, 470), (0.26, 0.14, 540, 480),
              (0.48, 0.14, 530, 470), (0.78, 0.75, 560, 360))


def js_sob(rng):
    """sSob: four triangle 'sob' pulses with 7 Hz vibrato plus breath noise, bandpass 1150."""
    n = N(1.65)
    src = zeros(n)
    offs = []
    for dt, dur, f0, f1 in SOB_PULSES:
        m = N(dur + 0.06)
        i0 = t2i(dt)
        fp = Param(f0).set(f0, 0).lin(f1, dur)
        fm = scale(osc(m, 'sine', 7, 0, dur + 0.05), 14)
        o = osc(m, 'triangle', fp, 0, dur + 0.05, fm=fm)
        g = Param(1).set(0.0001, 0).exp(0.9, 0.04).exp(0.0001, dur)
        add_at(src, mul(o, g.render(m)), i0)
        off = rng.random() * 1.5
        offs.append(round(off, 3))
        nz = noise_src(m, AU('noise'), 0, dur, offset=off)
        ng = Param(1).set(0.0001, 0).exp(0.25, 0.03).exp(0.0001, dur)
        add_at(src, mul(nz, ng.render(m)), i0)
    return biquad(src, 'bandpass', 1150, 1.6), {'noise_offsets': offs}


def js_thunder(rng, off_lo, off_hi):
    """sThunder: brown-noise rumble + white crack, fixed outNode lowpass 900 baked."""
    off = off_lo + rng.random() * (off_hi - off_lo)
    if FAITHFUL_BUFFER_TRUNCATION:
        rumble = noise_len(6.0, off)
        n = N(max(rumble, 0.62) + 0.08)
        b = noise_src(n, AU('brown'), 0, 6, offset=off)
    else:
        rumble = 5.5
        n = N(5.6)
        b = brown_noise(rng, n)
    g = Param(1).set(0.0001, 0).exp(1, 0.15).exp(0.4, 1.2).exp(0.0001, 5.5)
    out = mul(b, g.render(n))
    o2 = rng.random() * 1.5
    n2 = biquad(noise_src(n, AU('noise'), 0, 0.6, offset=o2), 'lowpass', 1800)
    out = add(out, mul(n2, envG(0, 0.01, 0.3, 0.5).render(n)))
    return biquad(out, 'lowpass', 900), {'noise_offset': round(off, 3), 'rumble_s': round(rumble, 3)}


def js_siren(rng):
    """sSiren: far police wail (620-980 Hz, 1.4 s cycle), 0.33 s echo with 0.45 feedback,
    fixed outNode lowpass 1600 baked."""
    dur = 10.0
    n = N(11.0)
    fp = Param(440)
    k = 0
    while k < dur / 1.4:
        fp.set(620, k * 1.4).lin(980, k * 1.4 + 0.7).lin(620, k * 1.4 + 1.4)
        k += 1
    o = osc(n, 'sine', fp, 0, dur + 0.1)
    g = Param(1).set(0.0001, 0).exp(1, 2.5).set(1, dur - 3).exp(0.0001, dur)
    dry = mul(o, g.render(n))
    wet = delay_feedback(dry, 0.33, 0.45)
    return biquad(add(dry, wet), 'lowpass', 1600), {}


def js_stinger(rng):
    """sStinger: detuned low saws + noise through a 200->2400->300 Hz lowpass sweep,
    fixed outNode lowpass 3000 baked."""
    n = N(1.75)
    fp = Param(350).set(200, 0).exp(2400, 0.25).exp(300, 1.6)
    src = zeros(n)
    for fr in (55, 58.3, 82.4, 110):
        src = add(src, mul(osc(n, 'sawtooth', fr, 0, 1.7), envG(0, 0.02, 0.4, 1.5).render(n)))
    off = rng.random() * 1.5
    src = add(src, mul(noise_src(n, AU('noise'), 0, 0.5, offset=off), envG(0, 0.005, 0.6, 0.35).render(n)))
    y = biquad(src, 'lowpass', fp)
    return biquad(y, 'lowpass', 3000), {'noise_offset': round(off, 3)}


# ----- loops from initAudio / sAlarm
def loop_rain_hiss(rng):
    """AU.noise -> highpass 600 -> AU.rainLP (lowpass, initial 4200)."""
    L = N(5.0)
    return periodic(rng, L, lambda w: biquad(biquad(scale(w, WHITE_SCALE), 'highpass', 600),
                                             'lowpass', 4200)), {'seconds': 5.0}


def loop_rain_body(rng):
    """AU.brown -> bandpass 800 Q0.5 -> AU.rainLP2 (lowpass 2200)."""
    L = N(5.5)
    return periodic(rng, L, lambda w: biquad(biquad(brown_of(w), 'bandpass', 800, 0.5),
                                             'lowpass', 2200)), {'seconds': 5.5}


def loop_wind(rng):
    """AU.brown -> AU.windLP (lowpass 380)."""
    L = N(6.0)
    return periodic(rng, L, lambda w: biquad(brown_of(w), 'lowpass', 380)), {'seconds': 6.0}


def loop_drone(rng):
    """Tension drone: sines 41 / 41.6 (x0.5) and 61.8 Hz (x0.25) + AU.brown -> bandpass 220 Q2
    x0.25.  5 s = 205 / 208 / 309 whole cycles."""
    L = N(5.0)
    out = zeros(L)
    for f, a in ((41.0, 0.5), (41.6, 0.5), (61.8, 0.25)):
        w = TWO_PI * f / FS
        out = [v + a * math.sin(w * i) for i, v in enumerate(out)]
    nz = periodic(rng, L, lambda w: biquad(brown_of(w), 'bandpass', 220, 2))
    return add(out, scale(nz, 0.25)), {'seconds': 5.0}


def loop_alarm(rng):
    """sAlarm: sawtooth 1050 Hz + 2.1 Hz sine LFO x380 Hz on frequency -> lowpass 3000.
    10 LFO periods (4.7619 s); the carrier then advances exactly 5000 cycles."""
    L = N(10.0 / 2.1)
    n = 2 * L                                     # first period = filter/oscillator pre-roll
    lfo = scale(osc(n, 'sine', 2.1), 380)
    y = biquad(osc(n, 'sawtooth', 1050, fm=lfo), 'lowpass', 3000)
    return y[L:], {'seconds': round(L / FS, 5), 'lfo_periods': 10}


# ============================================================================= new sounds
def new_clang(rng):
    """Metal trash can knocked.  Recipe: an impact and one rebound 85-150 ms later (32-48 %).
    Each hit = white-noise burst (0.4 ms attack, 16 ms decay) -> bandpass ~2 kHz Q1.4 (x2.4), plus 4
    inharmonic sine partials of a thin cylinder (base 265-345 Hz x 1, ~1.56, ~2.5, ~4.1,
    capped at 1500 Hz) decaying with tau 170/130/95/65 ms, each with a +0.65 % detuned twin at
    30 % for a metallic beat.  About 0.62 s with an 80 ms fade."""
    n = N(0.62)
    out = zeros(n)
    base = rng.uniform(265.0, 345.0)
    ratios = (1.0, rng.uniform(1.50, 1.62), rng.uniform(2.38, 2.62), rng.uniform(3.90, 4.35))
    freqs = [min(1500.0, base * r) for r in ratios]
    amps = (0.50, 0.40, 0.28, 0.18)
    taus = (0.17, 0.13, 0.095, 0.065)
    reb = rng.uniform(0.085, 0.15)
    for th, ha in ((0.0, 1.0), (reb, rng.uniform(0.32, 0.48))):
        m = N(0.09)
        b = biquad(mul(white(rng, m), decay_env(m, 0.0004, 0.016)), 'bandpass',
                   rng.uniform(1850, 2250), 1.4)
        add_at(out, b, t2i(th), 2.4 * ha)
        for f, a, tau in zip(freqs, amps, taus):
            a *= ha * rng.uniform(0.8, 1.2)
            tau *= rng.uniform(0.85, 1.15) * (1.0 if th == 0.0 else 0.8)
            add_partial(out, f * rng.uniform(0.997, 1.003), th, a, tau, attack=0.0004)
            add_partial(out, f * 1.0065, th, a * 0.3, tau * 0.8, attack=0.0004)
    fade_out(out, 0.08)
    return out, {'base_hz': round(base, 1), 'partials_hz': [round(f, 1) for f in freqs],
                 'rebound_s': round(reb, 3)}


def new_plastic(rng):
    """Plastic traffic cone knocked over: dull hollow knock and a softer second tap 45-70 ms
    later as it lands.  Each tap = sine 185-235 Hz dropping 28 % in 50 ms (tau 26 ms) + white
    burst (tau 7 ms) -> bandpass 620-820 Hz Q2.5 (hollow body) + tiny highpassed tick; all
    -> lowpass 3500 (dull).  About 0.16 s."""
    n = N(0.16)
    out = zeros(n)
    f0 = rng.uniform(185.0, 235.0)
    fres = rng.uniform(620.0, 820.0)
    tap2 = rng.uniform(0.045, 0.07)
    m = N(0.11)
    for th, ha in ((0.0, 1.0), (tap2, rng.uniform(0.3, 0.45))):
        fp = Param(f0).set(f0, 0).exp(f0 * 0.72, 0.05)
        body = mul(osc(m, 'sine', fp), decay_env(m, 0.001, 0.026))
        hol = biquad(mul(white(rng, m), decay_env(m, 0.0005, 0.007)), 'bandpass',
                     fres * rng.uniform(0.95, 1.05), 2.5)
        tick = biquad(mul(white(rng, m), decay_env(m, 0.0002, 0.0015)), 'highpass', 2500)
        y = [0.6 * a + 2.4 * b + 0.25 * c for a, b, c in zip(body, hol, tick)]
        add_at(out, y, t2i(th), ha)
    out = biquad(out, 'lowpass', 3500)
    fade_out(out, 0.02)
    return out, {'body_hz': round(f0, 1), 'hollow_hz': round(fres, 1), 'tap2_s': round(tap2, 3)}


def new_card(rng):
    """Cardboard box thump, very soft and low: brown noise -> lowpass 320 (3 ms attack, 45 ms
    decay) + sine 105->62 Hz (tau 35 ms) + a papery white burst -> bandpass 1500 Q0.8 (tau
    12 ms), then a small flap 55-85 ms later (brown -> lowpass 400, tau 20 ms).  About 0.22 s."""
    n = N(0.22)
    thump = mul(biquad(brown_noise(rng, n), 'lowpass', 320), decay_env(n, 0.003, 0.045))
    fp = Param(105).set(105, 0).exp(62, 0.07)
    body = mul(osc(n, 'sine', fp), decay_env(n, 0.002, 0.035))
    paper = biquad(mul(white(rng, n), decay_env(n, 0.001, 0.012)), 'bandpass', 1500, 0.8)
    out = [2.6 * a + 0.3 * b + 0.3 * c for a, b, c in zip(thump, body, paper)]
    flap_t = rng.uniform(0.055, 0.085)
    m = N(0.1)
    flap = mul(biquad(brown_noise(rng, m), 'lowpass', 400), decay_env(m, 0.002, 0.02))
    add_at(out, flap, t2i(flap_t), 0.9)
    fade_out(out, 0.03)
    return out, {'flap_s': round(flap_t, 3)}


def new_clink(rng):
    """Glass bottle tapping the ground: tick (white -> highpass 3000, tau 1.2 ms) + 3 sine
    partials 2.6-5 kHz (f1, ~1.41 f1, ~1.64 f1; tau 50/34/24 ms), then a lighter bounce tap
    60-90 ms later.  About 0.2 s."""
    n = N(0.2)
    out = zeros(n)
    f1 = rng.uniform(2600.0, 3300.0)
    fr = (f1, min(4950.0, f1 * rng.uniform(1.36, 1.46)), min(5000.0, f1 * rng.uniform(1.58, 1.70)))
    amps = (0.5, 0.3, 0.2)
    taus = (0.05, 0.034, 0.024)
    tap2 = rng.uniform(0.06, 0.09)
    m = N(0.02)
    for th, ha in ((0.0, 1.0), (tap2, rng.uniform(0.3, 0.45))):
        tick = biquad(mul(white(rng, m), decay_env(m, 0.0001, 0.0012)), 'highpass', 3000)
        add_at(out, tick, t2i(th), 0.5 * ha)
        for f, a, tau in zip(fr, amps, taus):
            add_partial(out, f, th, a * ha * rng.uniform(0.6, 1.3), tau * rng.uniform(0.85, 1.15),
                        attack=0.0003)
    fade_out(out, 0.025)
    return out, {'partials_hz': [round(f, 1) for f in fr], 'tap2_s': round(tap2, 3)}


def new_shatter(rng):
    """Glass bottle smashing: bright impact (white -> highpass 1800, tau 50 ms) + sizzle (white
    -> bandpass 5000 Q0.8, tau 140 ms) + crunch (white -> bandpass 1100 Q1.3, tau 20 ms) + a
    small low knock (brown -> lowpass 280), then 45-65 tiny random clinks (sine 2.4-8 kHz, tau
    6-30 ms, times ~ exponential with mean 0.12 s, level decaying with t) and 4-6 bigger shards
    (1.7-3.2 kHz).  About 0.72 s with a 60 ms fade."""
    n = N(0.72)
    impact = mul(biquad(white(rng, n), 'highpass', 1800), decay_env(n, 0.0005, 0.05))
    sizzle = mul(biquad(white(rng, n), 'bandpass', 5000, 0.8), decay_env(n, 0.001, 0.14))
    crunch = mul(biquad(white(rng, n), 'bandpass', 1100, 1.3), decay_env(n, 0.0005, 0.02))
    knock = mul(biquad(brown_noise(rng, n), 'lowpass', 280), decay_env(n, 0.001, 0.025))
    out = [0.9 * a + 1.1 * b + 1.3 * c + 2.0 * d for a, b, c, d in zip(impact, sizzle, crunch, knock)]
    cnt = rng.randint(45, 65)
    for _ in range(cnt):
        t = 0.004 + min(0.6, rng.expovariate(1.0 / 0.12))
        f = rng.uniform(2400.0, 8000.0)
        a = rng.uniform(0.04, 0.2) * math.exp(-t / 0.3)
        tau = rng.uniform(0.006, 0.03)
        add_partial(out, f, t, a, tau, attack=0.0002)
        add_partial(out, min(9500.0, f * rng.uniform(1.3, 1.6)), t, a * 0.4, tau * 0.7, attack=0.0002)
    shards = rng.randint(4, 6)
    for _ in range(shards):
        t = rng.uniform(0.05, 0.45)
        f = rng.uniform(1700.0, 3200.0)
        add_partial(out, f, t, rng.uniform(0.12, 0.22), rng.uniform(0.03, 0.06), attack=0.0003)
        add_partial(out, f * rng.uniform(1.45, 1.75), t, 0.06, 0.025, attack=0.0003)
    fade_out(out, 0.06)
    return out, {'clinks': cnt, 'shards': shards}


def _pop(rng, f, Q, tau, amp):
    """One crackle: white burst (0.2 ms attack, decay tau) -> bandpass f/Q."""
    m = N(tau * 8.0 + 0.004)
    return scale(biquad(mul(white(rng, m), decay_env(m, 0.0002, tau)), 'bandpass', f, Q), amp)


def new_boom(rng):
    """Car explosion.  sub thump: sine 56-66 Hz -> exp drop to half (about 30 Hz) over 0.9 s,
    4 ms attack, tau 0.5 s.  Blast: white -> lowpass sweeping 4500 -> 260 Hz in 0.6 s, tau
    0.11 s.  Body: brown noise -> lowpass 1300 -> 170 Hz over 3.4 s with envelope 20 ms attack,
    0.55 e^-t/0.3 + 0.45 e^-t/1.1 (a rumble that rolls for about 3 s).  Crackle tail: pops
    (bandpassed 1.2-5 kHz white bursts, 0.4-2 ms) at a Poisson rate 40 e^-(t/1.0) + 5 per
    second from 0.1 s to 3.8 s, level fading with t.  4 s, last 0.6 s faded."""
    n = N(4.0)
    f0 = rng.uniform(56.0, 66.0)
    fp = Param(f0).set(f0, 0).exp(f0 * 0.5, 0.9)
    sub = mul(osc(n, 'sine', fp), decay_env(n, 0.004, 0.5))
    lp = Param(4500).set(4500, 0).exp(260, 0.6)
    m = N(1.2)
    blast = mul(biquad(white(rng, m), 'lowpass', lp, 0.0), decay_env(m, 0.001, 0.11))
    body_env = decay_env(n, 0.02, 0.3)
    slow = decay_env(n, 0.02, 1.1)
    body_env = [0.55 * a + 0.45 * b for a, b in zip(body_env, slow)]
    blp = Param(1300).set(1300, 0).exp(170, 3.4)
    body = mul(biquad(brown_noise(rng, n), 'lowpass', blp, 0.0), body_env)
    out = [1.0 * a + 4.0 * b for a, b in zip(sub, body)]
    add_at(out, blast, 0, 1.5)
    t = 0.1
    lam_max = 45.0
    pops = 0
    while True:
        t += rng.expovariate(lam_max)
        if t >= 3.8:
            break
        if rng.random() < (40.0 * math.exp(-(t - 0.1) / 1.0) + 5.0) / lam_max:
            a = rng.uniform(0.05, 0.22) * (0.35 + 0.65 * math.exp(-t / 1.3))
            add_at(out, _pop(rng, rng.uniform(1200, 5000), rng.uniform(1.2, 2.2),
                             rng.uniform(0.0004, 0.002), a), t2i(t))
            pops += 1
    fade_out(out, 0.6)
    return out, {'sub_hz': round(f0, 1), 'crackles': pops}


def new_fire_loop(rng):
    """Burning fire loop (5 s, exactly periodic).  Bed: rumble (brown -> lowpass 220) x (1 +
    0.22 sin 0.6 Hz + 0.12 sin 1.4 Hz), roar (white -> bandpass 380 Q0.8) x (1 + 0.35 sin 0.8 Hz
    + 0.2 sin 2.2 Hz), faint hiss (white -> highpass 2200 -> lowpass 7000) x (1 + 0.5 sin 3 Hz);
    every modulator completes whole cycles in 5 s.  On top, the crackle that makes it read as
    fire: Poisson 18/s pops (white bursts of 0.3-2.5 ms -> bandpass 1-6 kHz Q1.2-3, level 0.5 +
    2.5 r^3 so most are small and a few are loud snaps, each loud snap followed by 1-3 echo
    pops 4-30 ms later) plus 4 sizzle clusters of 6-14 tiny 3-7 kHz pops.  Pops are added
    circularly so they wrap across the loop point."""
    Ls = 5.0
    L = N(Ls)
    two = TWO_PI / FS
    rum = periodic(rng, L, lambda w: biquad(brown_of(w), 'lowpass', 220))
    roar = periodic(rng, L, lambda w: biquad(w, 'bandpass', 380, 0.8))
    hiss = periodic(rng, L, lambda w: biquad(biquad(w, 'highpass', 2200), 'lowpass', 7000))
    out = [0.0] * L
    for i in range(L):
        m1 = 1.0 + 0.22 * math.sin(two * 0.6 * i) + 0.12 * math.sin(two * 1.4 * i + 1.3)
        m2 = 1.0 + 0.35 * math.sin(two * 0.8 * i + 0.4) + 0.2 * math.sin(two * 2.2 * i + 2.0)
        m3 = 1.0 + 0.5 * math.sin(two * 3.0 * i + 0.7)
        out[i] = 1.2 * rum[i] * m1 + 0.9 * roar[i] * m2 + 0.03 * hiss[i] * m3
    t = 0.0
    pops = 0
    while True:
        t += rng.expovariate(18.0)
        if t >= Ls:
            break
        r = rng.random()
        amp = 0.5 + 2.5 * r ** 3
        add_circular(out, _pop(rng, rng.uniform(1000, 6000), rng.uniform(1.2, 3.0),
                               rng.uniform(0.0003, 0.0025), amp), t2i(t))
        pops += 1
        if r > 0.85:
            tt = t
            for _ in range(rng.randint(1, 3)):
                tt += rng.uniform(0.004, 0.03)
                add_circular(out, _pop(rng, rng.uniform(1500, 6000), 2.0, rng.uniform(0.0003, 0.001),
                                       amp * rng.uniform(0.3, 0.6)), t2i(tt))
    for _ in range(4):
        tc = rng.uniform(0.0, Ls)
        span = rng.uniform(0.08, 0.2)
        for _ in range(rng.randint(6, 14)):
            add_circular(out, _pop(rng, rng.uniform(3000, 7000), 2.0, rng.uniform(0.0002, 0.0006),
                                   rng.uniform(0.15, 0.4)), t2i(tc + rng.uniform(0, span)))
    return out, {'seconds': Ls, 'crackles': pops}


def new_ignite(rng):
    """Fuel catching fire: rising whoosh (white -> bandpass Q1.2 swept 300 -> 3000 Hz in 0.35 s
    then down to 1500 Hz; gain 0.02 -> 1 at 0.3 s -> 0.3 at 0.55 s -> 0.0005 at 0.95 s) over a
    softer low 'fwump' (brown -> lowpass 450, swelling from 0.08 s to a peak at 0.28 s) and 8-12
    crackles from 0.2 s on.  About 1 s."""
    n = N(1.0)
    bp = Param(300).set(300, 0).exp(3000, 0.35).exp(1500, 0.95)
    g = Param(1).set(0.02, 0).exp(1, 0.3).exp(0.3, 0.55).exp(0.0005, 0.95)
    whoosh = mul(biquad(white(rng, n), 'bandpass', bp, 1.2), g.render(n))
    fg = Param(1).set(0.001, 0).set(0.001, 0.08).exp(1, 0.28).exp(0.0005, 0.95)
    fwump = mul(biquad(brown_noise(rng, n), 'lowpass', 450), fg.render(n))
    out = [2.0 * a + 2.2 * b for a, b in zip(whoosh, fwump)]
    k = rng.randint(8, 12)
    for _ in range(k):
        t = rng.uniform(0.2, 0.9)
        add_at(out, _pop(rng, rng.uniform(1300, 5000), rng.uniform(1.2, 2.5),
                         rng.uniform(0.0004, 0.0015), rng.uniform(0.3, 0.8)), t2i(t))
    fade_out(out, 0.05)
    return out, {'crackles': k}


def new_ring(rng):
    """Ear ringing after a blast: sine at 3800 Hz with wobble (+-9 Hz at 4.6 Hz and +-4 Hz at
    0.7 Hz vibrato, 7 % tremolo at 5.3 Hz), 60 ms fade-in, level 0.75 e^-t/0.9 + 0.25 e^-t/2.0,
    and a half-cosine taper over the last 0.5 s.  3.2 s."""
    n = N(3.2)
    out = [0.0] * n
    p = 0.0
    inv = 1.0 / FS
    for i in range(n):
        t = i * inv
        f = 3800.0 + 9.0 * math.sin(TWO_PI * 4.6 * t) + 4.0 * math.sin(TWO_PI * 0.7 * t + 1.0)
        env = min(1.0, t / 0.06) * (0.75 * math.exp(-t / 0.9) + 0.25 * math.exp(-t / 2.0))
        env *= 1.0 + 0.07 * math.sin(TWO_PI * 5.3 * t)
        out[i] = env * math.sin(TWO_PI * p)
        p += f * inv
        p -= math.floor(p)
    fade_out(out, 0.5)
    return out, {'hz': 3800}


# ============================================================================= sound table
def _strata(rng, lo, hi, k):
    """k representative random draws in [lo, hi): one from the central half of each of k equal
    sub-ranges, ascending (so a handful of variants covers the JS distribution evenly)."""
    w = (hi - lo) / k
    return [lo + w * (i + 0.25 + 0.5 * rng.random()) for i in range(k)]


def build_specs():
    specs = []

    def spec(key, source, notes, variants, loop=False, vol=None, level=None):
        specs.append({'key': key, 'source': source, 'notes': notes, 'variants': variants,
                      'loop': loop, 'vol': vol, 'level': level})

    # --- loops
    spec('rain_hiss_loop', 'initAudio: AU.noise -> highpass 600 -> AU.rainLP (4200)',
         'Ambient, non-positional. JS gain = (under?0.03 : inside?0.05 : 0.085) * rv, '
         'rv = (1-0.8*G.quiet) * SET.rain/100 * WX.i^0.8, smoothed (setTargetAtTime tau 0.6 s). '
         'JS rainLP is dynamic: under 350 Hz, inside 1000 Hz, outdoors 3000+1600*WX.i (tau 0.3 s); '
         'the file has the initial 4200 Hz baked in, so add a bus low-pass only when the target is '
         'below ~4200 Hz. JS loops a 2 s noise buffer; this is 5 s of non-repeating noise.',
         [('rain_hiss_loop', loop_rain_hiss)], loop=True)
    spec('rain_body_loop', 'initAudio: AU.brown -> bandpass 800 Q0.5 -> AU.rainLP2 (2200)',
         'Ambient, non-positional. JS gain = (under?0.06:0.13) * rv (same rv as rain_hiss, tau 0.6 s). '
         'rainLP2 is dynamic: under 250 Hz, inside 650 Hz, outdoors 2200 Hz (baked).',
         [('rain_body_loop', loop_rain_body)], loop=True)
    spec('wind_loop', 'initAudio: AU.brown -> AU.windLP (lowpass 380)',
         'Ambient, non-positional. JS gain = (under?0.03 : 0.08+0.06*max(0,sin(G.time*0.13))) * '
         '(1-0.8*G.quiet), tau 1.0 s. The 380 Hz lowpass is static (baked).',
         [('wind_loop', loop_wind)], loop=True)
    spec('drone_loop', 'initAudio: tension drone (sines 41/41.6/61.8 + AU.brown -> bandpass 220 Q2 x0.25)',
         'Non-positional. JS gain AU.droneG = ten*0.16 (tau 0.8 s), ten = max(CHASE?1:0, '
         'clamp(1-dPM/55,0,1)) in explore/escape, else 0 (tau 0.5 s on loss, 0.3 s on menu). '
         '5 s = whole cycles of every sine.',
         [('drone_loop', loop_drone)], loop=True)
    spec('alarm_loop', 'sAlarm: sawtooth 1050 Hz, 2.1 Hz LFO x380 Hz on frequency, lowpass 3000',
         'Car alarm, positional, bypasses outNode. JS gain = posParams(car, ref 26).vol * 0.22 * '
         'min(1, alarmT/0.6) (setTargetAtTime tau 0.08); its lowpass follows min(3000, pp.lp) '
         '(tau 0.1): 3000 is baked, add a low-pass only when pp.lp < 3000; pan follows pp.pan. '
         'Sounds for alarmT = 14 s, then gain -> 0 (tau 0.05); 60 s cooldown per car. '
         'Loop = 10 LFO periods (4.7619 s).',
         [('alarm_loop', loop_alarm)], loop=True)
    spec('siren', 'sSiren', 'Far police siren, one-shot 10 s with its 0.33 s / 0.45 feedback echo baked. '
         'Every rand(35,70) s; fixed vol 0.035, pan rand(-0.9,0.9), lowpass 1600 baked.',
         [('siren', js_siren)], vol=0.035)

    # --- JS one-shots
    spec('thud', 'sThud', 'Monster footstep: sThud(v, pp.pan, pp.lp), pp = posParams(foot, ref CHASE?34:26), '
         'v = pp.vol*(fore?1:0.75)*(CHASE?1.4:1)*(menu?0.6:1), skipped if v < 0.004; lp = distance/'
         'occlusion (not baked). Phantom steps: 4 thuds 0.62 s apart, vol 0.5, lp 420, pan jitter '
         '+-0.1, 22 m behind the camera. Variants differ only in their noise segments. '
         'posParams(x,y,z,ref) used by all positional sounds: d = horizontal distance to the camera, '
         'vol = 1/(1+(d/ref)^2), pan = -sin(rel)*0.85 (rel = angle from camera yaw), lp = '
         '16000*exp(-d/45)+300, x0.6 if behind; lp = min(lp,260) if exactly one of player/source is '
         'underground (y < -2), else min(lp,700) without line of sight.',
         [('thud_%d' % (i + 1), js_thud) for i in range(3)])
    spec('growl', 'sGrowl roar=false', 'From vocal(v): pp = posParams(monster, ref 30) (posParams: see thud), vol = pp.vol*v*0.8, '
         'pan/lp from pp, dur = rand(1.2,2.0) (files at 1.2/1.6/2.0 s). v = 0.8 for idle vocalising '
         '(every rand(9,18) s within 70 m), v = 0.5 on 50 % of switches to INVESTIGATE. Half of '
         'vocal() calls play clicks instead.',
         [('growl_%d' % (i + 1), (lambda d: lambda r: js_growl(r, d, False))(d))
          for i, d in enumerate((1.2, 1.6, 2.0))])
    spec('roar', 'sGrowl roar=true', 'roar_1 (1.4 s): lose(), vol 0.9, lp 4000, pan pp.pan (ref 30). '
         'roar_2 (1.8 s): startChase, vol max(0.35, pp.vol*1.3) (ref 40), lp max(pp.lp,1500), 14 s '
         'cooldown, always with stinger. roar_3 (2.4 s): beginEscape, vol max(0.25, pp.vol) (ref 60), '
         'lp pp.lp.',
         [('roar_%d' % (i + 1), (lambda d: lambda r: js_growl(r, d, True))(d))
          for i, d in enumerate((1.4, 1.8, 2.4))])
    spec('clicks', 'sClicks', 'Monster clicks from vocal(v): vol = pp.vol*v (ref 30), pan/lp from pp '
         '(see growl). Each variant has its own random click count/timing/pitch.',
         [('clicks_%d' % (i + 1), js_clicks) for i in range(3)])
    spec('heart', 'sHeart', 'Heartbeat: sHeart(0.2+0.4*close), pan 0, lowpass 300 baked; retriggered '
         'every lerp(1.1,0.4,close) s while close > 0.05 in explore/escape; close = CHASE?1 : '
         'clamp(1-(dPM-6)/24,0,1).',
         [('heart', js_heart)])
    step_rng = random.Random('%d:step_rates' % SEED)
    wet_rates = _strata(step_rng, 0.8, 1.2, 4)
    dry_rates = _strata(step_rng, 0.8, 1.2, 4)
    spec('step_wet', 'sStep wet=true', 'Player footstep outdoors: sStep(vol, true), vol sprint 0.16 / '
         'run 0.1 / walk 0.05 / crouch 0.025; pan rand(-0.1,0.1); lowpass 5200 baked. JS picks '
         'playbackRate rand(0.8,1.2) per step; the 4 files cover that range (params.rate).',
         [('step_wet_%d' % (i + 1), (lambda q: lambda r: js_step(r, True, q))(q))
          for i, q in enumerate(wet_rates)])
    spec('step_dry', 'sStep wet=false', 'Player footstep inside buildings or underground (wet = '
         '!inInterior && y > -1): same volumes/pan as step_wet; lowpass 2600 baked.',
         [('step_dry_%d' % (i + 1), (lambda q: lambda r: js_step(r, False, q))(q))
          for i, q in enumerate(dry_rates)])
    spec('chime', 'sChime', 'Clue found / win. Fixed vol 0.13, pan 0, lowpass 6000 baked.',
         [('chime', js_chime)], vol=0.13)
    spec('ui_click', 'sClick', 'Flashlight toggle, dialog choice. Fixed vol 0.18, pan 0.2, lowpass '
         '8000 baked.', [('ui_click', js_click)], vol=0.18)
    spec('sob', 'sSob', "Child crying, positional sSob(vol, pp.pan, pp.lp), skipped if vol < 0.003. "
         "Call sites: hiding pp.vol*0.9 (ref 9); scared 0.7 (ref 8); 'wait' 0.6 (ref 10); following "
         "0.6 (ref 8); cry clue max(0.05, pp.vol*0.8) (ref 12) with lp = min(pp.lp,1500); 'help' "
         "pp.vol (ref 6). Variants differ only in breath noise.",
         [('sob_%d' % (i + 1), js_sob) for i in range(2)])
    th_ranges = [(0.1875, 0.5625), (0.9375, 1.3125)]   # central halves of [0,0.75) and [0.75,1.5)
    spec('thunder', 'sThunder', 'sThunder(vol), vol = 0.35+0.3*s, s = rand(0.5,1)*(0.5+0.5*WX.i), '
         'rand(0.8,2.4) s after a lightning flash; pan rand(-0.5,0.5); lowpass 900 baked. JS plays '
         'the 2 s AU.brown buffer from a random 0-1.5 s offset without looping, so the rumble stops '
         'after 0.5-2 s even though the envelope runs to 5.5 s. The files reproduce that '
         '(params.rumble_s). Set FAITHFUL_BUFFER_TRUNCATION=False for the full 5.5 s roll.',
         [('thunder_%d' % (i + 1), (lambda a, b: lambda r: js_thunder(r, a, b))(*rg))
          for i, rg in enumerate(th_ranges)])
    spec('stinger', 'sStinger', 'Chase stinger (startChase, with roar_2). Fixed vol 0.3, pan 0, '
         'lowpass 3000 baked.', [('stinger', js_stinger)], vol=0.3)

    # --- new sounds (physics feature)
    spec('clang', 'new', 'Metal trash can knocked. Suggested: positional, vol = 1/(1+(d/18)^2) scaled '
         'by impact speed, pitch_scale 0.95-1.05, distance/occlusion lowpass as posParams.',
         [('clang_%d' % (i + 1), new_clang) for i in range(3)], level=0.9)
    spec('plastic', 'new', 'Plastic traffic cone knocked over. Suggested ref distance 10, vol scaled by '
         'impact speed.', [('plastic_%d' % (i + 1), new_plastic) for i in range(2)], level=0.5)
    spec('card', 'new', 'Cardboard box thump (very soft). Suggested ref distance 6.',
         [('card_%d' % (i + 1), new_card) for i in range(2)], level=0.3)
    spec('clink', 'new', 'Glass bottle tapping the ground. Suggested ref distance 8.',
         [('clink_%d' % (i + 1), new_clink) for i in range(2)], level=0.4)
    spec('shatter', 'new', 'Glass bottle smashing. Suggested ref distance 14; loud enough to be a '
         'noise event for the monster.', [('shatter_%d' % (i + 1), new_shatter) for i in range(2)],
         level=0.8)
    spec('boom', 'new', 'Car explosion. Suggested ref distance 60, add camera shake; follow with ring '
         '(if close) and fire_loop at the wreck. Big peak: the master compressor (threshold -14 dB, '
         'ratio 4) will squash it, as the JS master bus would.',
         [('boom_%d' % (i + 1), new_boom) for i in range(2)], level=1.2)
    spec('fire_loop', 'new', 'Burning wreck, positional loop. Suggested ref distance 10; fade in over '
         '~1 s after ignite.', [('fire_loop', new_fire_loop)], loop=True, level=0.5)
    spec('ignite', 'new', 'Fuel catching fire (quick rising whoosh). Suggested ref distance 12; start '
         'fire_loop ~0.6 s in.', [('ignite', new_ignite)], level=0.7)
    spec('ring', 'new', 'Ear ringing after a nearby blast. Non-positional; vol ~ 1-d/25 (skip beyond '
         '25 m). While it plays, duck other buses and low-pass them to ~1 kHz for ~2 s.',
         [('ring', new_ring)], level=0.2)
    return specs


# ============================================================================= output
def write_wav(path, samples, loop=False):
    """16-bit mono PCM WAV.  For loops, `samples` is one period of L frames; the file gets L+1
    frames (the extra last frame is a copy of frame 0, a guard for interpolating across the
    wrap) and a 'smpl' chunk with one forward loop start=0, end=L.  Godot wraps when the play
    position reaches loop_end, so it plays frames 0..L-1 and repeats exactly; with a manual
    Loop Mode = Forward and the default loop_end = -1 it resolves to frames-1 = L as well."""
    L = len(samples)
    if loop:
        samples = list(samples) + [samples[0]]
    ints = array.array('h', [int(round(max(-1.0, min(1.0, v)) * 32767.0)) for v in samples])
    if sys.byteorder != 'little':
        ints.byteswap()
    raw = ints.tobytes()
    chunks = [b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, OUT_RATE, OUT_RATE * 2, 2, 16)]
    if loop:
        smpl = struct.pack('<9I', 0, 0, int(round(1e9 / OUT_RATE)), 60, 0, 0, 0, 1, 0)
        smpl += struct.pack('<6I', 0, 0, 0, L, 0, 0)
        chunks.append(b'smpl' + struct.pack('<I', len(smpl)) + smpl)
    chunks.append(b'data' + struct.pack('<I', len(raw)) + raw + (b'\0' if len(raw) % 2 else b''))
    body = b'WAVE' + b''.join(chunks)
    with open(path, 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', len(body)) + body)


def read_wav(path):
    with wave.open(path, 'rb') as w:
        info = (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes())
        a = array.array('h')
        a.frombytes(w.readframes(w.getnframes()))
    if sys.byteorder != 'little':
        a.byteswap()
    return info, a


def check_file(path, loop):
    """Re-read a written file and measure it."""
    (ch, sw, sr, nf), a = read_wav(path)
    problems = []
    if (ch, sw, sr) != (1, 2, OUT_RATE):
        problems.append('format %s' % ((ch, sw, sr),))
    n = len(a)
    pk = max(abs(v) for v in a) / 32767.0
    rms = math.sqrt(sum(v * v for v in a) / n) / 32767.0
    clipped = sum(1 for v in a if v >= 32767 or v <= -32767)
    if clipped:
        problems.append('%d clipped samples' % clipped)
    if pk > PEAK + 0.001:
        problems.append('peak %.4f > %.2f' % (pk, PEAK))
    if rms < 1e-3:
        problems.append('near silent')
    r = {'frames': n, 'dur': n / OUT_RATE, 'peak': pk, 'rms_db': 20 * math.log10(max(rms, 1e-9)),
         'problems': problems}
    if loop:
        if a[-1] != a[0]:
            problems.append('guard frame != frame 0')
        a = a[:-1]
        n = len(a)
        r['frames'] = n
        r['dur'] = n / OUT_RATE
        # Seamless means the wrap (last sample -> first) looks like any other point of the file.
        # First differences can legitimately be large at the wrap (e.g. every drone sine starts
        # at phase 0, i.e. at full slope), so the test is on the second difference (a click shows
        # up as a spike there), ranked against every other sample of the file.
        c = list(a[-2:]) + list(a[:2])            # a[-2], a[-1] | a[0], a[1]
        d2 = sorted(abs(a[i - 1] - 2 * a[i] + a[i + 1]) for i in range(1, n - 1))

        def pct(v):
            lo, hi = 0, len(d2)
            while lo < hi:
                mid = (lo + hi) // 2
                if d2[mid] < v:
                    lo = mid + 1
                else:
                    hi = mid
            return 100.0 * lo / len(d2)

        wrap2 = max(abs(c[0] - 2 * c[1] + c[2]), abs(c[1] - 2 * c[2] + c[3]))
        r['jump'] = abs(a[0] - a[-1]) / 32767.0
        r['d2_pct'] = pct(wrap2)
        m = int(0.05 * OUT_RATE)

        def lev(s):
            return 20 * math.log10(max(1e-9, math.sqrt(sum(v * v for v in s) / len(s)) / 32767.0))

        r['edge_db'] = (lev(a[-m:]), lev(a[:m]))
        if r['d2_pct'] > 99.5:
            problems.append('loop wrap is a curvature outlier (click)')
    return r


def main():
    t_start = time.time()
    os.makedirs(OUT_DIR, exist_ok=True)
    manifest = {}
    written = []
    for sp in build_specs():
        entry = {'files': [], 'loop': sp['loop'], 'gain': [], 'source': sp['source'],
                 'notes': sp['notes'], 'durations': [], 'params': []}
        if sp['vol'] is not None:
            entry['vol'] = sp['vol']
        for stem, fn in sp['variants']:
            t0 = time.time()
            rng = random.Random('%d:%s' % (SEED, stem))
            x, params = fn(rng)
            if sp['loop']:
                y = finish_loop(x)
            else:
                y = finish_oneshot(x)
            if not all(math.isfinite(v) for v in y):
                raise RuntimeError('%s: non-finite samples' % stem)
            pk = max(abs(v) for v in y)
            if pk <= 0.0:
                raise RuntimeError('%s: silent' % stem)
            gain = (sp['level'] if sp['level'] is not None else pk) / PEAK
            y = [v * (PEAK / pk) for v in y]
            fname = stem + '.wav'
            write_wav(os.path.join(OUT_DIR, fname), y, loop=sp['loop'])
            entry['files'].append(fname)
            entry['gain'].append(round(gain, 5))
            entry['durations'].append(round(len(y) / OUT_RATE, 4))
            if sp['loop']:
                entry.setdefault('loop_end', []).append(len(y))
            entry['params'].append(params)
            written.append((fname, sp['loop'], pk))
            print('  rendered %-18s %6.3f s  raw peak %.4f  (%.1f s)'
                  % (fname, len(y) / OUT_RATE, pk, time.time() - t0), flush=True)
        if sp['loop']:
            entry['notes'] += (' File = loop_end frames + 1 guard frame (copy of frame 0); '
                               'smpl chunk loops [0, loop_end).')
        manifest[sp['key']] = entry
    with open(os.path.join(OUT_DIR, 'sounds.json'), 'w') as f:
        json.dump(manifest, f, indent=2)
        f.write('\n')

    # ---- verification pass (re-reads every file from disk)
    print('\n%-20s %8s %7s %8s  %s' % ('file', 'seconds', 'peak', 'rms dB', 'loop junction / problems'))
    bad = 0
    total = 0
    for fname, loop, _ in written:
        path = os.path.join(OUT_DIR, fname)
        total += os.path.getsize(path)
        r = check_file(path, loop)
        extra = ''
        if loop:
            extra = ('wrap step %.4f, wrap curvature at %.1f%% of file, rms last/first 50 ms '
                     '%.1f/%.1f dB' % (r['jump'], r['d2_pct'], r['edge_db'][0], r['edge_db'][1]))
        if r['problems']:
            bad += 1
            extra += ' PROBLEMS: ' + '; '.join(r['problems'])
        print('%-20s %8.3f %7.4f %8.1f  %s' % (fname, r['dur'], r['peak'], r['rms_db'], extra))
    total += os.path.getsize(os.path.join(OUT_DIR, 'sounds.json'))
    print('\n%d files, %.1f KiB (incl. sounds.json), %d with problems, %.1f s total'
          % (len(written), total / 1024.0, bad, time.time() - t_start))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
