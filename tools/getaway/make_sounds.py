#!/usr/bin/env python3
"""
make_sounds.py - synthesises the sounds the Getaway prototype needs that Lost City doesn't have.

    python3 tools/getaway/make_sounds.py

Writes into getaway/assets/sounds/:
  engine_loop.wav  a seamless 2 s engine drone; the game raises its pitch with speed
  siren_loop.wav   a seamless police wail (rising and falling), played behind the player
  whoosh.wav       a short rush of air for a near miss

Everything is made from sine waves and filtered noise with fixed seeds, so the files are the same on
every run and there are no licences to track. Needs numpy.
"""
import os
import wave

import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), '..', '..', 'getaway', 'assets', 'sounds')


def save(name, x, loop=False):
    x = np.asarray(x, dtype=np.float64)
    x = x / (np.max(np.abs(x)) + 1e-9) * 0.9
    pcm = (x * 32767).astype('<i2')
    path = os.path.join(OUT, name)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f'{name:18s} {len(x) / SR:5.2f} s{"  (loop)" if loop else ""}')


def lowpass(x, hz):
    """One-pole low-pass, run twice around the loop so the ends join up."""
    a = np.exp(-2 * np.pi * hz / SR)
    y = np.zeros_like(x)
    s = 0.0
    for _ in range(2):
        for i in range(len(x)):
            s = (1 - a) * x[i] + a * s
            y[i] = s
    return y


def looped_noise(n, seed, hz):
    """Band-limited noise that loops: filtered in the frequency domain, so it wraps around."""
    rng = np.random.default_rng(seed)
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / SR)
    spec *= 1 / (1 + (f / hz) ** 4)
    return np.fft.irfft(spec, n)


def engine():
    # every partial is a whole number of cycles in the loop, so it repeats without a click
    n = SR * 2
    t = np.arange(n) / SR
    base = 48.0   # Hz at pitch 1.0: a deep idle; the game plays it at up to ~2.4x
    x = np.zeros(n)
    for k, amp in [(1, 1.0), (2, 0.55), (3, 0.42), (4, 0.2), (6, 0.12), (8, 0.06)]:
        x += amp * np.sin(2 * np.pi * base * k * t + k * 0.7)
    # combustion roughness: the level wobbles with each firing
    x *= 1 + 0.25 * np.sin(2 * np.pi * base * 0.5 * t)
    x += 0.35 * looped_noise(n, 3, 900)
    x = np.tanh(x * 1.4)
    save('engine_loop.wav', x, loop=True)


def siren():
    # an American-style wail: the pitch sweeps 650 -> 1350 -> 650 Hz every 3 s. The phase is scaled so
    # it ends on a whole number of cycles.
    n = SR * 6
    t = np.arange(n) / SR
    f = 1000 + 350 * np.sin(2 * np.pi * t / 3.0 - np.pi / 2)
    ph = np.cumsum(f) / SR
    ph *= np.round(ph[-1]) / ph[-1]
    x = np.sin(2 * np.pi * ph) + 0.35 * np.sin(4 * np.pi * ph) + 0.15 * np.sin(6 * np.pi * ph)
    x = np.tanh(x * 2.0)
    # a little of the street: the echo off the buildings (wraps around the loop)
    x = x + 0.35 * np.roll(x, int(0.21 * SR)) + 0.18 * np.roll(x, int(0.47 * SR))
    save('siren_loop.wav', x, loop=True)


def whoosh():
    n = int(SR * 0.55)
    t = np.arange(n) / SR
    rng = np.random.default_rng(9)
    noise = rng.standard_normal(n)
    # the air rushes past: brighter as it gets close, then dies away
    env = np.exp(-((t - 0.16) / 0.09) ** 2) + 0.4 * np.exp(-np.maximum(t - 0.16, 0) / 0.12) * (t > 0.16)
    y = np.zeros(n)
    s = 0.0
    for i in range(n):
        hz = 400 + 2600 * np.exp(-((t[i] - 0.16) / 0.12) ** 2)
        a = np.exp(-2 * np.pi * hz / SR)
        s = (1 - a) * noise[i] + a * s
        y[i] = s
    save('whoosh.wav', y * env)


if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    engine()
    siren()
    whoosh()
