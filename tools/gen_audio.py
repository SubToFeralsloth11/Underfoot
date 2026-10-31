#!/usr/bin/env python3
"""Underfoot audio generator (deterministic, seeded).

Usage:  python3 tools/gen_audio.py

Writes:
  audio/sfx/<name>.ogg    mono 44.1 kHz sound effects (`*_loop` files loop seamlessly)
  audio/music/<name>.ogg  mono 44.1 kHz music stems, every file exactly 32.0 s
                          (90 BPM, 48 beats, 12 bars of 4/4, D minor / dorian).
                          bed_<layer> is the base; intense1..3_<layer> are stems
                          meant to be mixed ON TOP of the bed in sync.

Pipeline: synthesise float -> peak-normalise to -3 dBFS -> 16-bit WAV ->
Ogg Vorbis (ffmpeg libvorbis -q:a 4 when available, otherwise libsndfile's
Vorbis encoder at the equivalent quality) -> delete WAV.
"""
import os
import shutil
import subprocess
import sys
import zlib

import numpy as np
import soundfile as sf
from scipy.signal import butter, fftconvolve, lfilter, sosfilt

SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "audio")
PEAK_DB = -3.0
SFX_Q = 4  # vorbis quality (0..10)
MUSIC_Q = 4
BPM = 90
BEAT = 60.0 / BPM
MUSIC_BEATS = 48
MUSIC_N = int(round(MUSIC_BEATS * BEAT * SR))  # 1,411,200 samples = 32.0 s


# ----------------------------------------------------------------------------
# basic helpers
# ----------------------------------------------------------------------------
def N(d):
    return max(1, int(round(d * SR)))


def tt(n):
    return np.arange(n) / SR


def mtof(m):
    return 440.0 * 2.0 ** ((m - 69) / 12.0)


def rng_for(name):
    return np.random.default_rng(zlib.crc32(name.encode()))


def _sos(kind, f, order):
    nyq = SR / 2 * 0.98
    if kind == "bandpass":
        f = [max(10.0, f[0]), min(nyq, f[1])]
    else:
        f = min(max(f, 10.0), nyq)
    return butter(order, f, btype=kind, fs=SR, output="sos")


def lp(x, f, o=2):
    return sosfilt(_sos("lowpass", f, o), x)


def hp(x, f, o=2):
    return sosfilt(_sos("highpass", f, o), x)


def bp(x, lo, hi, o=2):
    return sosfilt(_sos("bandpass", (lo, hi), o), x)


def cfilt(x, lo=None, hi=None, order=2):
    """Zero-phase circular (wrap-around) filter: keeps loops seamless."""
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1.0 / SR)
    H = np.ones_like(f)
    if hi:
        H *= 1.0 / np.sqrt(1.0 + (f / hi) ** (2 * order))
    if lo:
        H *= 1.0 / np.sqrt(1.0 + (lo / np.maximum(f, 1e-3)) ** (2 * order))
    return np.fft.irfft(X * H, len(x))


def svf(x, fc, q=0.707, mode="bp"):
    """Time-varying TPT state-variable filter (fc may be an array)."""
    n = len(x)
    fc = np.broadcast_to(np.asarray(fc, float), (n,))
    g = np.tan(np.pi * np.clip(fc, 20, SR * 0.45) / SR)
    k = 1.0 / q
    a1 = 1.0 / (1.0 + g * (g + k))
    a2 = g * a1
    a3 = g * a2
    a1, a2, a3, xs = a1.tolist(), a2.tolist(), a3.tolist(), x.tolist()
    ic1 = ic2 = 0.0
    lo = [0.0] * n
    band = [0.0] * n
    for i in range(n):
        v3 = xs[i] - ic2
        v1 = a1[i] * ic1 + a2[i] * v3
        v2 = ic2 + a2[i] * ic1 + a3[i] * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        lo[i] = v2
        band[i] = v1
    lo = np.array(lo)
    band = np.array(band)
    if mode == "lp":
        return lo
    if mode == "bp":
        return band * k
    return x - k * band - lo


def phase(freq, n, ph0=0.0):
    f = np.broadcast_to(np.asarray(freq, float), (n,))
    return 2 * np.pi * np.cumsum(f) / SR + ph0


def sine(freq, n, ph0=0.0):
    return np.sin(phase(freq, n, ph0))


def tri(freq, n, ph0=0.0):
    return 2 / np.pi * np.arcsin(np.sin(phase(freq, n, ph0)))


def blsaw(freq, n, ph0=0.0):
    """PolyBLEP band-limited sawtooth."""
    f = np.broadcast_to(np.asarray(freq, float), (n,))
    dt = f / SR
    t = (ph0 + np.cumsum(dt)) % 1.0
    y = 2 * t - 1
    m = t < dt
    x = t[m] / dt[m]
    y[m] -= x + x - x * x - 1
    m = t > 1 - dt
    x = (t[m] - 1) / dt[m]
    y[m] -= x * x + x + x + 1
    return y


def sweep(f0, f1, n, curve="exp"):
    u = np.linspace(0, 1, n)
    if curve == "exp":
        return f0 * (f1 / f0) ** u
    return f0 + (f1 - f0) * u


def expdec(n, tau):
    return np.exp(-tt(n) / tau)


def smooth_ar(n, a, r):
    """Raised-cosine attack/release envelope over n samples."""
    e = np.ones(n)
    na, nr = min(N(a), n // 2), min(N(r), n // 2)
    if na > 1:
        e[:na] = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, na))
    if nr > 1:
        e[-nr:] *= 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, nr))
    return e


def hold_env(n, a, hold, r):
    """Attack a, full level until `hold` s, release r (all seconds)."""
    t = tt(n)
    e = np.clip(t / max(a, 1e-4), 0, 1)
    e = 0.5 - 0.5 * np.cos(np.pi * e)
    rel = t > hold
    e[rel] *= np.clip(1 - (t[rel] - hold) / r, 0, 1) ** 2
    return e


def noise(rng, n):
    return rng.standard_normal(n)


def brown(rng, n):
    x = np.cumsum(rng.standard_normal(n))
    x = hp(x, 20, 1)
    return x / (np.max(np.abs(x)) + 1e-9)


def mix_at(buf, x, start_s, gain=1.0):
    """Add x into buf at start time (s), truncating (one-shot SFX)."""
    s = int(round(start_s * SR))
    if s >= len(buf):
        return
    k = min(len(x), len(buf) - s)
    buf[s:s + k] += x[:k] * gain


def place(buf, x, pos):
    """Circular add at sample position pos (wraps around: seamless loops)."""
    n = len(buf)
    s = int(round(pos)) % n
    i = 0
    while i < len(x):
        k = min(len(x) - i, n - s)
        buf[s:s + k] += x[i:i + k]
        i += k
        s = 0


def fit(x, dur):
    n = N(dur)
    if len(x) >= n:
        return x[:n].copy()
    return np.concatenate([x, np.zeros(n - len(x))])


def grains(rng, n, count, glen=(0.0008, 0.004), density=None, amp=None):
    """Sum of tiny Hann-windowed noise grains (crunch / crackle)."""
    buf = np.zeros(n)
    if density is not None:
        p = np.maximum(density, 0) + 1e-12
        starts = rng.choice(n, size=count, p=p / p.sum())
    else:
        starts = rng.integers(0, n, size=count)
    for s in starts:
        L = max(4, int(rng.uniform(*glen) * SR))
        g = rng.standard_normal(L) * np.hanning(L) * rng.uniform(0.2, 1.0) ** 2
        if amp is not None:
            g *= amp[min(s, n - 1)]
        k = min(L, n - s)
        buf[s:s + k] += g[:k]
    return buf


def reverb(x, rt=0.8, mix=0.2, seed=1, lo=150, hi=6000):
    rng = np.random.default_rng(seed)
    m = N(rt * 1.3)
    ir = rng.standard_normal(m) * np.exp(-6.9 * tt(m) / rt)
    ir = bp(ir, lo, hi)
    ir /= np.sqrt(np.sum(ir ** 2))
    wet = fftconvolve(x, ir)
    out = wet * mix
    out[:len(x)] += x * (1 - mix)
    return out


def creverb(x, rt=1.5, mix=0.25, seed=7, lo=150, hi=6000):
    """Circular convolution reverb: tail wraps to the start (seamless loops)."""
    n = len(x)
    rng = np.random.default_rng(seed)
    m = min(n, N(rt * 1.3))
    ir = np.zeros(n)
    ir[:m] = rng.standard_normal(m) * np.exp(-6.9 * tt(m) / rt)
    ir = cfilt(ir, lo, hi)
    ir /= np.sqrt(np.sum(ir ** 2))
    wet = np.fft.irfft(np.fft.rfft(x) * np.fft.rfft(ir), n)
    return x * (1 - mix) + wet * mix


def loopf(f, n):
    """Round a frequency so it completes a whole number of cycles in n samples."""
    return max(1, round(f * n / SR)) * SR / n


def periodic_lfo(rng, n, cycles=(1, 2, 3), depth=1.0):
    """Smooth random LFO built only from whole-cycle sines (loop-safe)."""
    t = np.arange(n) / n
    y = np.zeros(n)
    for c in cycles:
        y += rng.uniform(0.3, 1.0) / c * np.sin(2 * np.pi * c * t + rng.uniform(0, 2 * np.pi))
    y /= np.max(np.abs(y)) + 1e-9
    return y * depth


# ----------------------------------------------------------------------------
# reusable voices
# ----------------------------------------------------------------------------
def click(rng, dur=0.004, lo=2000, hi=9000):
    n = N(dur)
    return bp(rng.standard_normal(n) * np.hanning(n), lo, hi)


def thump(f0, f1, dur, tau, rng=None, noise_amt=0.3, noise_hi=400):
    n = N(dur)
    y = sine(sweep(f0, f1, n), n) * expdec(n, tau)
    if rng is not None and noise_amt:
        y += lp(rng.standard_normal(n), noise_hi) * expdec(n, tau * 0.5) * noise_amt
    return y * smooth_ar(n, 0.001, 0.005)


def bell(m, dur=1.0, bright=1.0):
    n = N(dur)
    t = tt(n)
    f = mtof(m) if m < 200 else m
    y = np.zeros(n)
    for ratio, a, dk in ((1, 1.0, 0.5), (2.0, 0.35, 0.3), (2.76, 0.45 * bright, 0.22),
                         (5.4, 0.22 * bright, 0.1), (8.93, 0.1 * bright, 0.05)):
        if f * ratio < 18000:
            y += a * np.sin(2 * np.pi * f * ratio * t) * np.exp(-t / (dur * dk))
    return y * smooth_ar(n, 0.001, 0.01)


def marimba(m, dur=1.2, vel=1.0):
    n = N(dur)
    t = tt(n)
    f = mtof(m)
    y = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.4)
    y += 0.3 * np.sin(2 * np.pi * 3.93 * f * t) * np.exp(-t / 0.07)
    if 9.2 * f < 18000:
        y += 0.08 * np.sin(2 * np.pi * 9.2 * f * t) * np.exp(-t / 0.02)
    return y * smooth_ar(n, 0.002, 0.05) * vel


def pluck(m, dur=1.0, bright=4000, rho=0.996, vel=1.0, seed=0):
    f = mtof(m)
    n = N(dur)
    D = max(2, int(round(SR / f)))
    rng = np.random.default_rng(seed + m)
    x = np.zeros(n)
    exc = lp(rng.standard_normal(D), bright)
    x[:D] = exc
    a = np.zeros(D + 2)
    a[0] = 1.0
    a[D] = -0.5 * rho
    a[D + 1] = -0.5 * rho
    y = lfilter([1.0], a, x)
    y /= np.max(np.abs(y)) + 1e-9
    return y * smooth_ar(n, 0.001, 0.05) * vel


def ep(m, dur=1.5, vel=1.0, wow_ph=0.0):
    """Lo-fi FM electric piano with slight tape wow."""
    n = N(dur + 0.3)
    t = tt(n)
    f = mtof(m) * (1 + 0.0025 * np.sin(2 * np.pi * 0.6 * t + wow_ph))
    ph = phase(f, n)
    index = 1.4 * np.exp(-t / 0.25) + 0.25
    y = np.sin(ph + index * np.sin(ph))
    y += 0.12 * np.sin(4 * ph) * np.exp(-t / 0.04)
    env = np.exp(-t / 1.4) * hold_env(n, 0.003, dur, 0.3)
    return y * env * vel


def pad(ms, dur, cutoff=1200, attack=0.6, release=1.2, detune=0.09, seed=0):
    rng = np.random.default_rng(seed)
    n = N(dur + release)
    out = np.zeros(n)
    for m in ms:
        f = mtof(m)
        for d in (-detune, 0.0, detune):
            out += blsaw(f * 2 ** (d / 12), n, rng.random())
    out = lp(out, cutoff, 2) / (3 * len(ms))
    return out * hold_env(n, attack, dur, release)


def strings_trem(ms, dur, rate=6.0, cutoff=3000, seed=0):
    n = N(dur + 0.4)
    t = tt(n)
    y = pad(ms, dur, cutoff=cutoff, attack=0.15, release=0.4, detune=0.12, seed=seed)[:n]
    trem = 0.55 + 0.45 * (0.5 + 0.5 * np.cos(2 * np.pi * rate * t))
    return y * trem


def stab(ms, dur=0.25, cutoff=2200, seed=0):
    n = N(dur + 0.15)
    t = tt(n)
    rng = np.random.default_rng(seed)
    y = np.zeros(n)
    for m in ms:
        for d in (-0.1, 0.1):
            y += blsaw(mtof(m) * 2 ** (d / 12), n, rng.random())
    y += 0.6 * np.sign(np.sin(phase(mtof(min(ms) - 12), n)))
    y = lp(y, cutoff, 2) / (2 * len(ms) + 1)
    return y * np.exp(-t / (dur * 0.5)) * smooth_ar(n, 0.003, 0.05)


def bass(m, dur, kind="sub", seed=0):
    n = N(dur + 0.05)
    t = tt(n)
    f = mtof(m)
    if kind == "sub":
        y = np.sin(phase(f, n)) + 0.25 * lp(blsaw(f, n), 500)
        env = hold_env(n, 0.006, dur, 0.05) * (0.7 + 0.3 * np.exp(-t / 0.12))
    elif kind == "pluck":
        y = pluck(m, dur + 0.05, bright=1800, rho=0.995, seed=seed) + 0.6 * np.sin(phase(f, n))
        env = hold_env(n, 0.002, dur, 0.05)
    else:  # round
        y = np.sin(phase(f, n)) + 0.3 * tri(2 * f, n)
        y = lp(y, 500)
        env = hold_env(n, 0.01, dur, 0.06) * (0.6 + 0.4 * np.exp(-t / 0.2))
    return y * env


# drums --------------------------------------------------------------------
def kick(rng, f0=130, f1=45, tau=0.18, dur=0.4, clicky=0.3):
    n = N(dur)
    t = tt(n)
    fr = f1 + (f0 - f1) * np.exp(-t / 0.03)
    y = np.sin(phase(fr, n)) * np.exp(-t / tau)
    c = np.zeros(n)
    cl = click(rng, 0.003, 1000, 6000)
    c[:len(cl)] = cl
    return (y + clicky * c / (np.max(np.abs(c)) + 1e-9)) * smooth_ar(n, 0.0005, 0.01)


def snare(rng, dur=0.25, tone=190, tau=0.12, lo=1200, hi=8000):
    n = N(dur)
    t = tt(n)
    nz = bp(rng.standard_normal(n), lo, hi) * np.exp(-t / tau)
    tn = np.sin(2 * np.pi * tone * t) * np.exp(-t / 0.05)
    return (nz * 1.4 + 0.6 * tn) * smooth_ar(n, 0.0005, 0.01)


def hat(rng, dur=0.06, tau=0.02, lo=7000):
    n = N(dur)
    return hp(rng.standard_normal(n), lo, 2) * expdec(n, tau) * smooth_ar(n, 0.0005, 0.005)


def shaker(rng, dur=0.09):
    n = N(dur)
    t = tt(n)
    env = (t / 0.03) * np.exp(1 - t / 0.03)
    return bp(rng.standard_normal(n), 4000, 11000) * env * smooth_ar(n, 0.001, 0.01)


def woodclick(rng, f=1500, dur=0.05):
    n = N(dur)
    t = tt(n)
    y = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.012) + 0.5 * np.sin(2 * np.pi * f * 1.6 * t) * np.exp(-t / 0.006)
    return y * smooth_ar(n, 0.0005, 0.005)


def tom(rng, f=110, dur=0.4):
    n = N(dur)
    t = tt(n)
    fr = f * (1 + 0.5 * np.exp(-t / 0.04))
    y = np.sin(phase(fr, n)) * np.exp(-t / 0.15)
    y += 0.2 * bp(rng.standard_normal(n), 300, 2000) * np.exp(-t / 0.03)
    return y * smooth_ar(n, 0.0005, 0.01)


def crash(rng, dur=2.0):
    n = N(dur)
    t = tt(n)
    y = hp(rng.standard_normal(n), 3500, 2) * np.exp(-t / 0.6)
    for r in (1.0, 1.47, 2.09, 2.83):
        y += 0.15 * np.sin(2 * np.pi * 3200 * r * t) * np.exp(-t / 0.4)
    return y * smooth_ar(n, 0.001, 0.05)


# ----------------------------------------------------------------------------
# SFX
# ----------------------------------------------------------------------------
SFX = {}


def sfx(name, loop=False):
    def deco(fn):
        SFX[name] = (fn, loop)
        return fn
    return deco


def make_dig(i):
    def fn(rng):
        dur = (0.18, 0.24, 0.29)[i]
        centre = (2600, 1900, 3200)[i]
        n = N(dur)
        u = np.linspace(0, 1, n)
        env = (u + 0.02) ** (0.25 + 0.1 * i) * (1 - u) ** (1.2 + 0.4 * i)
        env /= env.max()
        crunch = grains(rng, n, (110, 150, 180)[i], density=env, amp=env)
        crunch = bp(crunch, centre * 0.45, centre * 2.6)
        rough = np.abs(lp(rng.standard_normal(n), 60 + 30 * i))
        rough /= rough.max()
        body = bp(rng.standard_normal(n), 250 + 60 * i, 1100) * env * (0.4 + rough) * 0.35
        th = thump((150, 120, 170)[i], 70, 0.08, 0.025, rng, 0.4)
        y = crunch / (np.abs(crunch).max() + 1e-9) + body / (np.abs(body).max() + 1e-9) * 0.5
        mix_at(y, th, 0.0, 0.5)
        return y
    return fn


for _i in range(3):
    sfx(f"dig_{_i + 1}")(make_dig(_i))


@sfx("collapse")
def _collapse(rng):
    dur = 1.5
    n = N(dur)
    t = tt(n)
    env = np.minimum(1, t / 0.04) * np.exp(-t / 0.55)
    rum = lp(brown(rng, n), 160, 4) * env
    rum /= np.abs(rum).max()
    y = rum * 0.9
    mix_at(y, thump(70, 32, 0.8, 0.25, rng, 0.6), 0.0, 0.9)
    dens = np.exp(-t / 0.45)
    cr = bp(grains(rng, n, 500, glen=(0.001, 0.006), density=dens, amp=dens), 600, 5000)
    y += cr / np.abs(cr).max() * 0.35
    for _ in range(14):
        s = rng.uniform(0.02, 1.1)
        mix_at(y, thump(rng.uniform(90, 160), 50, 0.15, 0.04, rng, 0.5), s,
               0.35 * np.exp(-s / 0.6))
    return y


@sfx("chain")
def _chain(rng):
    y = np.zeros(N(0.6))
    for k, (m, s) in enumerate(((86, 0.0), (89, 0.11), (93, 0.22))):
        b = bell(m, 0.38 - 0.03 * k, bright=0.8)
        mix_at(b, click(rng, 0.003, 3000, 12000), 0.0, 0.3)
        mix_at(y, b, s, 0.75 + 0.12 * k)
    return fit(reverb(y, 0.5, 0.18, 3), 0.6)


@sfx("bite")
def _bite(rng):
    y = np.zeros(N(0.09))
    n = N(0.03)
    snap = sine(sweep(2000, 600, n), n) * expdec(n, 0.008)
    mix_at(y, snap, 0.0, 0.7)
    mix_at(y, click(rng, 0.004, 2500, 10000), 0.0, 1.0)
    mix_at(y, click(rng, 0.003, 3000, 10000), 0.028, 0.6)
    return y


@sfx("fight")
def _fight(rng):
    dur = 0.5
    n = N(dur)
    t = tt(n)
    am = np.abs(lp(rng.standard_normal(n), 25))
    am /= am.max()
    rustle = bp(rng.standard_normal(n), 1000, 5000) * am * smooth_ar(n, 0.02, 0.1)
    y = rustle * 0.35
    for _ in range(7):
        s = rng.uniform(0.0, 0.42)
        m = N(0.025)
        snap = sine(sweep(rng.uniform(1500, 2600), 500, m), m) * expdec(m, 0.006)
        mix_at(y, snap, s, rng.uniform(0.3, 0.6))
        mix_at(y, click(rng, 0.004, 2000, 10000), s, rng.uniform(0.5, 1.0))
    for _ in range(4):
        mix_at(y, thump(rng.uniform(140, 220), 90, 0.06, 0.02, rng, 0.3), rng.uniform(0, 0.4), 0.4)
    return y


@sfx("hatch")
def _hatch(rng):
    y = np.zeros(N(0.8))
    n = N(0.06)
    pop = sine(sweep(420, 140, n), n) * expdec(n, 0.02)
    mix_at(y, pop, 0.0, 1.0)
    mix_at(y, lp(rng.standard_normal(N(0.01)), 2500) * np.hanning(N(0.01)), 0.0, 0.4)
    pent = [86, 89, 91, 93, 96, 98]
    for k in range(7):
        s = 0.04 + k * 0.05 + rng.uniform(0, 0.02)
        mix_at(y, bell(int(rng.choice(pent)), 0.3, 0.5), s, 0.28 * (1 - k / 9))
    return fit(reverb(y, 0.6, 0.2, 5), 0.8)


@sfx("lay_egg")
def _lay_egg(rng):
    n = N(0.14)
    t = tt(n)
    y = sine(sweep(300, 470, n), n) * smooth_ar(n, 0.01, 0.06) * np.exp(-t / 0.08)
    y += 0.25 * sine(sweep(600, 940, n), n) * smooth_ar(n, 0.01, 0.06) * np.exp(-t / 0.04)
    return y


@sfx("death")
def _death(rng):
    y = np.zeros(N(0.25))
    n = N(0.13)
    t = tt(n)
    f = sweep(2300, 1100, n) * (1 + 0.04 * np.sin(2 * np.pi * 35 * t))
    sq = sine(f, n) * smooth_ar(n, 0.005, 0.04)
    mix_at(y, sq, 0.0, 0.6)
    m = N(0.08)
    cr = bp(grains(rng, m, 40, amp=np.exp(-tt(m) / 0.03)), 1000, 7000)
    mix_at(y, cr / np.abs(cr).max(), 0.11, 0.8)
    mix_at(y, thump(160, 80, 0.06, 0.02, rng, 0.3), 0.11, 0.4)
    return y


@sfx("alert")
def _alert(rng):
    y = np.zeros(N(0.6))
    for f, s in ((880, 0.0), (659.26, 0.29)):
        n = N(0.27)
        tone = 0.6 * tri(f, n) + 0.4 * lp(np.sign(np.sin(phase(f, n))), 3000)
        mix_at(y, tone * smooth_ar(n, 0.006, 0.05), s)
    return y


@sfx("telegraph")
def _telegraph(rng):
    dur = 1.2
    n = N(dur)
    t = tt(n)
    base = np.sin(phase(55, n)) + 0.6 * np.sin(phase(55.8, n)) + 0.5 * lp(blsaw(55, n), 260)
    pulse = np.zeros(n)
    for k, s in enumerate((0.0, 0.4, 0.8)):
        m = N(0.38)
        p = np.sin(np.linspace(0, np.pi, m)) ** 1.5 * (0.7 + 0.15 * k)
        mix_at(pulse, p, s)
    rum = lp(brown(rng, n), 120, 2) * 0.3
    return (base * pulse + rum * pulse) * smooth_ar(n, 0.005, 0.05)


@sfx("splash")
def _splash(rng):
    dur = 0.7
    n = N(dur)
    t = tt(n)
    burst = bp(rng.standard_normal(n), 500, 7000) * np.minimum(1, t / 0.005) * np.exp(-t / 0.09)
    y = burst
    for _ in range(9):
        s = rng.uniform(0.03, 0.45)
        m = N(0.05)
        f0 = rng.uniform(700, 1600)
        blip = sine(sweep(f0, f0 * 2.2, m), m) * expdec(m, 0.015) * smooth_ar(m, 0.001, 0.01)
        mix_at(y, blip, s, rng.uniform(0.15, 0.4) * np.exp(-s / 0.3))
    return y


@sfx("swoop")
def _swoop(rng):
    dur = 0.8
    n = N(dur)
    t = tt(n)
    fc = np.interp(t, [0, 0.45, 0.8], [400, 2600, 500])
    y = svf(rng.standard_normal(n), fc, q=1.5, mode="bp")
    env = np.exp(-((t - 0.45) / 0.17) ** 2)
    flutter = 0.8 + 0.2 * np.sin(2 * np.pi * 13 * t)
    return y * env * flutter * smooth_ar(n, 0.01, 0.05)


@sfx("spray_hiss")
def _spray(rng):
    dur = 1.2
    n = N(dur)
    t = tt(n)
    y = hp(rng.standard_normal(n), 3000, 2) + 0.8 * bp(rng.standard_normal(n), 6000, 9500)
    jit = 1 + 0.1 * lp(rng.standard_normal(n), 30) / 0.1
    jit = np.clip(jit, 0.7, 1.3)
    env = hold_env(n, 0.03, 1.0, 0.18)
    y = y * env * jit
    mix_at(y, click(rng, 0.005, 1000, 6000), 0.0, 2.0)
    return y


@sfx("meow")
def _meow(rng):
    dur = 0.7
    n = N(dur)
    t = tt(n)
    f0 = np.interp(t, [0, 0.22, 0.7], [520, 760, 430]) * (1 + 0.015 * np.sin(2 * np.pi * 6 * t))
    src = blsaw(f0, n) + 0.3 * rng.standard_normal(n) * 0.05
    f1 = np.interp(t, [0, 0.25, 0.7], [350, 900, 420])
    f2 = np.interp(t, [0, 0.25, 0.7], [2300, 1400, 850])
    y = svf(src, f1, q=5, mode="bp") + 0.6 * svf(src, f2, q=7, mode="bp")
    return y * hold_env(n, 0.06, 0.45, 0.25)


@sfx("purr_loop", loop=True)
def _purr(rng):
    L = N(2.0)
    rate = 26  # pulses per second, 52 per loop
    buf = np.zeros(L)
    breath = 0.65 + 0.35 * np.sin(2 * np.pi * 2 * np.arange(L) / L - np.pi / 2)
    for k in range(rate * 2):
        pos = (k + rng.uniform(-0.08, 0.08)) * SR / rate
        m = N(0.03)
        g = rng.standard_normal(m) * np.hanning(m) + 1.5 * np.sin(2 * np.pi * 52 * tt(m)) * np.hanning(m)
        place(buf, g * breath[int(pos) % L], pos)
    return cfilt(buf, 30, 500)


@sfx("mower_loop", loop=True)
def _mower(rng):
    L = N(2.0)
    t = np.arange(L) / L
    wob = 1 + 0.03 * np.sin(2 * np.pi * t)  # one whole cycle -> whole-cycle phase
    f = loopf(32, L) * wob
    ph = np.cumsum(f) / SR  # cycles
    frac = ph % 1.0
    amps = 0.8 + 0.2 * rng.random(int(np.ceil(ph[-1])) + 2)
    amps[int(np.floor(ph[-1]))] = amps[0]
    pulse = np.exp(-frac / 0.12) * amps[np.floor(ph).astype(int)]
    y = pulse - pulse.mean()
    y += 0.25 * np.sin(2 * np.pi * 8 * np.cumsum(f) / SR)
    y += 0.08 * np.sin(2 * np.pi * 37 * np.cumsum(f) / SR)  # blade whine
    y += 0.25 * cfilt(rng.standard_normal(L), 300, 3000)
    return cfilt(y, 40, 2500)


@sfx("sprinkler_loop", loop=True)
def _sprinkler(rng):
    L = N(2.0)
    buf = np.zeros(L)
    tick_times = list(np.arange(0.0, 1.35, 0.15))
    for s in tick_times:
        m = N(0.03)
        tk = hp(rng.standard_normal(m), 1500) * expdec(m, 0.004)
        tk += 0.6 * np.sin(2 * np.pi * 2600 * tt(m)) * expdec(m, 0.006)
        place(buf, tk, s * SR)
    for s in np.arange(1.42, 1.95, 0.035):  # fast ratchet return
        m = N(0.015)
        place(buf, hp(rng.standard_normal(m), 2500) * expdec(m, 0.002) * 0.5, s * SR)
    spray_env = np.zeros(L)
    for s in tick_times:
        m = N(0.15)
        place(spray_env, np.exp(-tt(m) / 0.05), s * SR)
    spray = cfilt(rng.standard_normal(L), 2500, 9000) * (0.25 + spray_env)
    return buf + 0.35 * spray


@sfx("rain_loop", loop=True)
def _rain(rng):
    L = N(4.0)
    bed = cfilt(rng.standard_normal(L), 400, 7000)
    bed *= 1 + 0.15 * periodic_lfo(rng, L, (1, 2, 5))
    drops = np.zeros(L)
    for _ in range(260):
        m = N(0.02)
        f0 = rng.uniform(1500, 5000)
        d = np.sin(2 * np.pi * f0 * tt(m)) * expdec(m, 0.004) * rng.uniform(0.1, 1) ** 2
        place(drops, d, rng.integers(0, L))
    return bed / np.abs(bed).max() * 0.6 + drops / np.abs(drops).max() * 0.4


@sfx("wind_loop", loop=True)
def _wind(rng):
    L = N(4.0)
    y = np.zeros(L)
    for lo, hi, cyc in ((150, 500, (1, 2)), (400, 1200, (1, 3)), (900, 2500, (2, 3))):
        band = cfilt(rng.standard_normal(L), lo, hi, 2)
        band /= np.abs(band).max()
        gust = 0.5 + 0.5 * periodic_lfo(rng, L, cyc)
        y += band * gust ** 2
    return y


@sfx("creak_loop", loop=True)
def _creak(rng):
    L = N(4.0)
    buf = np.zeros(L)
    for s, d in ((0.3, 0.45), (1.6, 0.3), (2.5, 0.5), (3.55, 0.25)):
        n = N(d)
        t = tt(n)
        rate = np.interp(t, [0, d], [rng.uniform(40, 70), rng.uniform(90, 140)])
        ph = np.cumsum(rate) / SR
        imp = np.zeros(n)
        idx = np.nonzero(np.diff(np.floor(ph)) > 0)[0]
        imp[idx] = rng.uniform(0.5, 1, len(idx))
        f = rng.uniform(350, 900)
        cr = bp(imp, f * 0.8, f * 1.25, 2) * smooth_ar(n, 0.05, 0.1)
        place(buf, cr / (np.abs(cr).max() + 1e-9) * rng.uniform(0.6, 1.0), s * SR)
    trickle = np.zeros(L)
    for _ in range(80):
        m = N(0.003)
        place(trickle, rng.standard_normal(m) * np.hanning(m) * rng.uniform(0.1, 1), rng.integers(0, L))
    trickle = cfilt(trickle, 1500, 6000)
    rum = cfilt(rng.standard_normal(L), 30, 120)
    return buf + 0.25 * trickle / np.abs(trickle).max() + 0.12 * rum / np.abs(rum).max()


@sfx("birds_loop", loop=True)
def _birds(rng):
    L = N(6.0)
    buf = np.zeros(L)
    for s in (0.2, 1.4, 2.3, 3.6, 4.5, 5.3):
        notes = rng.integers(2, 6)
        base = rng.uniform(2500, 4500)
        pos = s
        for k in range(notes):
            d = rng.uniform(0.04, 0.09)
            n = N(d)
            f = sweep(base * rng.uniform(0.9, 1.3), base * rng.uniform(1.1, 1.6), n)
            ch = np.sin(phase(f, n)) * np.sin(np.linspace(0, np.pi, n)) ** 2
            place(buf, ch * rng.uniform(0.4, 1), pos * SR)
            pos += d + rng.uniform(0.02, 0.06)
    buf = cfilt(buf, 1500, 8000)
    buf = creverb(buf, 0.5, 0.2, seed=11, lo=1000, hi=9000)
    return buf + 0.03 * cfilt(rng.standard_normal(L), 200, 2000)


@sfx("house_hum_loop", loop=True)
def _hum(rng):
    L = N(4.0)
    t = np.arange(L) / SR
    y = (np.sin(2 * np.pi * 60 * t) + 0.6 * np.sin(2 * np.pi * 120 * t)
         + 0.35 * np.sin(2 * np.pi * 120.25 * t) + 0.25 * np.sin(2 * np.pi * 180 * t)
         + 0.15 * np.sin(2 * np.pi * 240 * t) + 0.06 * np.sin(2 * np.pi * 360 * t))
    y *= 1 + 0.05 * periodic_lfo(rng, L, (1, 3))
    y += 0.4 * cfilt(rng.standard_normal(L), 40, 500)
    return y


@sfx("pickup")
def _pickup(rng):
    y = np.zeros(N(0.06))
    n = N(0.04)
    mix_at(y, np.sin(2 * np.pi * 1700 * tt(n)) * expdec(n, 0.008), 0.0, 0.6)
    mix_at(y, click(rng, 0.003, 2500, 9000), 0.0, 0.8)
    return y


@sfx("deposit")
def _deposit(rng):
    return fit(thump(190, 85, 0.2, 0.05, rng, 0.5, 600), 0.2)


@sfx("build")
def _build(rng):
    y = np.zeros(N(0.35))
    mix_at(y, thump(120, 50, 0.35, 0.08, rng, 0.6, 500), 0.0)
    m = N(0.1)
    cr = bp(grains(rng, m, 50, amp=np.exp(-tt(m) / 0.03)), 1200, 6000)
    mix_at(y, cr / np.abs(cr).max(), 0.0, 0.35)
    return y


@sfx("ui_click")
def _ui_click(rng):
    n = N(0.05)
    y = np.sin(2 * np.pi * 1250 * tt(n)) * expdec(n, 0.01)
    y[:N(0.002)] += click(rng, 0.002, 3000, 10000)[:N(0.002)] * 0.5
    return y


@sfx("ui_hover")
def _ui_hover(rng):
    n = N(0.035)
    return np.sin(2 * np.pi * 2100 * tt(n)) * np.sin(np.linspace(0, np.pi, n)) ** 2


def ui_whoosh(rng, up):
    dur = 0.28
    n = N(dur)
    t = tt(n)
    fc = sweep(500, 4000, n) if up else sweep(4000, 500, n)
    y = svf(rng.standard_normal(n), fc, q=1.2, mode="bp")
    tone = np.sin(phase(sweep(420, 840, n) if up else sweep(840, 420, n), n))
    env = np.sin(np.linspace(0, np.pi, n)) ** 1.5
    return (y * 0.8 + tone * 0.25) * env


sfx("ui_open")(lambda rng: ui_whoosh(rng, True))
sfx("ui_close")(lambda rng: ui_whoosh(rng, False))


@sfx("toast")
def _toast(rng):
    y = np.zeros(N(0.9))
    mix_at(y, bell(81, 0.8, 0.6), 0.0)
    mix_at(y, bell(88, 0.6, 0.4), 0.0, 0.3)
    return fit(reverb(y, 0.5, 0.15, 9), 0.9)


@sfx("unlock")
def _unlock(rng):
    y = np.zeros(N(1.0))
    for k, m in enumerate((74, 77, 81, 86, 89, 93, 98)):
        mix_at(y, bell(m, 0.5, 0.7), k * 0.065, 0.55 + 0.05 * k)
    n = N(0.9)
    sh = hp(rng.standard_normal(n), 6000) * np.sin(np.linspace(0, np.pi, n)) ** 2
    sh *= 0.5 + 0.5 * (rng.random(n) > 0.995).astype(float) * 4
    mix_at(y, lp(sh, 12000), 0.05, 0.12)
    return fit(reverb(y, 0.9, 0.25, 13), 1.0)


def brass(ms, dur, cutoff=2500, attack=0.03, seed=0):
    n = N(dur + 0.3)
    t = tt(n)
    rng = np.random.default_rng(seed)
    y = np.zeros(n)
    for m in ms:
        for d in (-0.08, 0.08):
            y += blsaw(mtof(m) * 2 ** (d / 12) * (1 + 0.003 * np.sin(2 * np.pi * 5 * t)), n, rng.random())
    fc = cutoff * (0.4 + 0.6 * np.minimum(1, t / max(attack * 3, 1e-3)))
    y = svf(y / (2 * len(ms)), fc, q=0.8, mode="lp")
    return y * hold_env(n, attack, dur, 0.3)


@sfx("victory")
def _victory(rng):
    y = np.zeros(N(2.5))
    for m, s, d in ((74, 0.0, 0.12), (78, 0.13, 0.12), (81, 0.26, 0.12), (81, 0.45, 0.2), (86, 0.7, 1.4)):
        mix_at(y, brass([m], d, 3500, 0.01, seed=m), s, 0.55)
        mix_at(y, bell(m, 0.6, 0.5), s, 0.25)
    mix_at(y, brass([50, 57, 62, 66, 69], 1.4, 2200, 0.08, seed=3), 0.7, 0.6)
    for s in (0.0, 0.45, 0.7):
        mix_at(y, tom(rng, 90, 0.5), s, 0.5)
    mix_at(y, crash(rng, 1.8), 0.7, 0.25)
    return fit(reverb(y, 1.0, 0.2, 17), 2.5)


@sfx("defeat")
def _defeat(rng):
    y = np.zeros(N(2.5))
    for m, s, d in ((69, 0.0, 0.3), (67, 0.35, 0.3), (65, 0.7, 0.3), (64, 1.05, 0.3)):
        n = N(d + 0.1)
        tone = lp(blsaw(mtof(m), n), 1400) + 0.6 * tri(mtof(m), n)
        mix_at(y, tone * hold_env(n, 0.02, d, 0.1), s, 0.5)
    n = N(1.1)
    t = tt(n)
    f = mtof(62) * np.where(t < 0.5, 1.0, 2 ** (-1.0 * (t - 0.5) / 0.6 / 12 * 1.5))
    f = f * (1 + 0.01 * np.sin(2 * np.pi * 5 * t))
    last = lp(blsaw(f, n), 1100) + 0.6 * tri(f, n)
    mix_at(y, last * hold_env(n, 0.03, 0.75, 0.35), 1.4, 0.55)
    mix_at(y, pad([50, 53, 57], 1.8, 800, 0.6, 0.5, seed=4), 0.0, 0.5)
    return fit(reverb(y, 1.0, 0.2, 19), 2.5)


@sfx("flight")
def _flight(rng):
    dur = 1.5
    n = N(dur)
    t = tt(n)
    rate = sweep(20, 42, n)
    flut = 0.5 + 0.5 * np.sin(phase(rate, n))
    fc = sweep(600, 3200, n)
    wings = svf(rng.standard_normal(n), fc, q=1.0, mode="bp") * flut ** 2
    buzz = lp(blsaw(sweep(170, 380, n), n), 1500) * (0.7 + 0.3 * flut)
    env = hold_env(n, 0.25, 0.9, 0.6)
    return (wings + 0.25 * buzz) * env


@sfx("cat_swat")
def _cat_swat(rng):
    y = np.zeros(N(0.6))
    n = N(0.16)
    sw = svf(rng.standard_normal(n), sweep(3500, 600, n), q=1.3, mode="bp")
    mix_at(y, sw * np.sin(np.linspace(0, np.pi, n)) ** 1.2, 0.0, 0.8)
    mix_at(y, thump(110, 42, 0.42, 0.1, rng, 0.8, 500), 0.16, 1.0)
    return y


@sfx("footstep")
def _footstep(rng):
    y = np.zeros(N(1.0))
    mix_at(y, thump(60, 32, 0.6, 0.14, rng, 0.9, 220), 0.0)
    return fit(lp(reverb(y, 0.7, 0.25, 23, 60, 1200), 900), 1.0)


@sfx("exterminator")
def _exterminator(rng):
    y = np.zeros(N(2.0))
    mix_at(y, brass([38, 45, 50, 51], 1.3, 1600, 0.06, seed=31), 0.0, 1.0)
    mix_at(y, thump(55, 28, 1.2, 0.35, rng, 0.5, 200), 0.0, 0.9)
    return fit(reverb(y, 1.2, 0.2, 29, 80, 4000), 2.0)


# ----------------------------------------------------------------------------
# MUSIC: 12 bars, 90 BPM, D minor / dorian, exactly MUSIC_N samples, circular
# ----------------------------------------------------------------------------
BARS = ["Dm", "Dm", "Bb", "C", "Dm", "F", "G", "Am", "Bb", "C", "Dm", "Am"]
CHORDS = {"Dm": (2, "m"), "Bb": (10, "M"), "C": (0, "M"), "F": (5, "M"), "G": (7, "M"), "Am": (9, "m")}
SEVENTH = {"Dm": 0, "Bb": 9, "C": 10, "F": 4, "G": 5, "Am": 7}
PENT = {2, 5, 7, 9, 0}  # D minor pentatonic


def pcs(ch, seventh=False):
    r, q = CHORDS[ch]
    s = [r % 12, (r + (3 if q == "m" else 4)) % 12, (r + 7) % 12]
    if seventh:
        s.append(SEVENTH[ch])
    return s


def voice(p, lo, hi):
    return [m for m in range(lo, hi + 1) if m % 12 in p]


def root(ch, lo):
    r = CHORDS[ch][0]
    return next(m for m in range(lo, lo + 12) if m % 12 == r)


def mbuf():
    return np.zeros(MUSIC_N)


def at(buf, x, beat, gain=1.0):
    place(buf, x * gain, beat * BEAT * SR)


def norm_part(x):
    return x / (np.abs(x).max() + 1e-12)


def drone(ms, cutoff=400, seed=0, depth=0.3):
    rng = np.random.default_rng(seed)
    y = mbuf()
    for m in ms:
        f = loopf(mtof(m), MUSIC_N)
        y += np.sin(phase(f, MUSIC_N, rng.uniform(0, 6.28)))
        y += 0.4 * cfilt(blsaw(loopf(f * 1.003, MUSIC_N), MUSIC_N, rng.random()), None, cutoff)
    return y * (1 + depth * periodic_lfo(rng, MUSIC_N, (2, 4)))


def chord_pad(cutoff, lo=52, hi=64, seed=0, attack=0.8):
    y = mbuf()
    for b, ch in enumerate(BARS):
        y_note = pad(voice(pcs(ch), lo, hi), 4 * BEAT, cutoff, attack, 1.5, seed=seed + b)
        at(y, y_note, b * 4)
    return y


def walk_melody(rng, prob, lo, hi, grid=0.5, snap_beats=(0,)):
    """Deterministic pentatonic random-walk melody -> list of (beat, midi, vel)."""
    pool = [m for m in range(lo, hi + 1) if m % 12 in PENT]
    idx = len(pool) // 2
    out = []
    steps = int(MUSIC_BEATS / grid)
    for s in range(steps):
        beat = s * grid
        bar = int(beat // 4)
        inbar = beat % 4
        p = prob * (1.6 if inbar == 0 else 1.0 if inbar % 1 == 0 else 0.6)
        if rng.random() > p:
            continue
        idx = int(np.clip(idx + rng.choice([-2, -1, -1, 1, 1, 2]), 0, len(pool) - 1))
        m = pool[idx]
        if inbar in snap_beats:
            ct = voice(pcs(BARS[bar]), lo, hi)
            m = min(ct, key=lambda c: abs(c - m))
            idx = min(range(len(pool)), key=lambda i: abs(pool[i] - m))
        out.append((beat, m, rng.uniform(0.6, 1.0)))
    return out


def drums_pulse(layer, rng):
    y = mbuf()
    for bar in range(12):
        b0 = bar * 4
        if layer == "nest":
            for b in (0, 2):
                at(y, lp(kick(rng, 90, 40, 0.2, 0.4, 0.05), 900), b0 + b, 0.8)
            for e in range(8):
                acc = 0.9 if e % 2 else 0.45
                at(y, woodclick(rng, 1400 if e % 4 == 3 else 1100), b0 + e * 0.5, acc * 0.35)
            for s in range(16):
                at(y, shaker(rng), b0 + s * 0.25, 0.12 if s % 2 else 0.06)
            if bar % 2 == 1:
                at(y, tom(rng, 95, 0.4), b0 + 3.5, 0.35)
        elif layer == "surface":
            for b in (0, 2.5):
                at(y, kick(rng, 120, 48, 0.15, 0.35, 0.2), b0 + b, 0.75)
            for b in (1, 3):
                at(y, woodclick(rng, 1900, 0.04), b0 + b, 0.4)
                at(y, snare(rng, 0.15, 220, 0.05, 2000, 9000), b0 + b, 0.25)
            for e in range(8):
                at(y, shaker(rng), b0 + e * 0.5, 0.22 if e % 2 else 0.12)
            for e in range(4):
                at(y, hat(rng), b0 + e + 0.5, 0.18)
        else:  # house: muffled boom-bap
            sw = 0.08
            for b in (0, 2.5):
                at(y, kick(rng, 110, 45, 0.22, 0.45, 0.1), b0 + b, 0.9)
            if bar % 2 == 1:
                at(y, kick(rng, 110, 45, 0.22, 0.45, 0.1), b0 + 3.5 + sw, 0.5)
            for b in (1, 3):
                at(y, snare(rng, 0.25, 180, 0.1, 900, 5000), b0 + b, 0.55)
            for e in range(8):
                at(y, hat(rng, 0.05, 0.02, 5000), b0 + e * 0.5 + (sw if e % 2 else 0), 0.2 if e % 2 else 0.3)
    return y


def drums_full(layer, rng):
    y = mbuf()
    kf = {"nest": (95, 40), "surface": (130, 48), "house": (115, 45)}[layer]
    for bar in range(12):
        b0 = bar * 4
        for b in (0, 1, 2, 3):
            at(y, kick(rng, kf[0], kf[1], 0.18, 0.4, 0.25), b0 + b, 1.0)
        at(y, kick(rng, kf[0], kf[1], 0.18, 0.4, 0.25), b0 + 2.75, 0.6)
        for b in (1, 3):
            at(y, snare(rng, 0.3, 190, 0.13), b0 + b, 0.9)
        at(y, snare(rng, 0.12, 200, 0.04), b0 + 3.75, 0.2)
        for s in range(16):
            at(y, hat(rng, 0.05, 0.015), b0 + s * 0.25, 0.3 if s % 2 == 0 else 0.15)
        if bar % 4 == 3:  # tom fill on the last beat of each 4-bar phrase
            for k, f in enumerate((180, 150, 120, 95)):
                at(y, tom(rng, f, 0.35), b0 + 3 + k * 0.25, 0.7)
        if bar % 4 == 0:
            at(y, crash(rng, 2.2), b0, 0.35 if bar == 0 else 0.25)
    if layer == "nest":
        y += 0.3 * cfilt(y, None, 300)  # deeper, cavernous thump
    return y


def bass_line(layer, seed):
    y = mbuf()
    kind = {"nest": "sub", "surface": "pluck", "house": "round"}[layer]
    pat = [0, 0, 12, 0, 7, 0, 12, 7]
    for bar, ch in enumerate(BARS):
        r = root(ch, 33)
        for e, iv in enumerate(pat):
            vel = 1.0 if e in (0, 4) else 0.75
            at(y, bass(r + iv, 0.45 * BEAT, kind, seed), bar * 4 + e * 0.5, vel)
    return y


def tension(layer, seed):
    y = mbuf()
    lo, hi = {"nest": (57, 64), "surface": (69, 77), "house": (64, 72)}[layer]
    for bar, ch in enumerate(BARS):
        g = (0.45, 0.6, 0.78, 1.0)[bar % 4]
        top = voice(pcs(ch), lo, hi)[-2:]
        at(y, strings_trem(top, 4 * BEAT, 6.0, 2600 if layer == "surface" else 1700, seed + bar), bar * 4, g)
    if layer == "nest":  # low minor-2nd unease (A / Bb) swelling per phrase
        for ph in range(3):
            at(y, pad([45, 46], 16 * BEAT - 1.5, 500, 6.0, 1.5, seed=seed + 50 + ph), ph * 16, 0.6)
    return y


def stabs(layer, seed):
    y = mbuf()
    cut = {"nest": 1500, "surface": 2600, "house": 1300}[layer]
    for bar, ch in enumerate(BARS):
        ms = voice(pcs(ch), 57, 69)[:3]
        hits = [0, 1.5, 3.0] + ([3.5] if bar % 4 == 3 else [])
        for h in hits:
            at(y, stab(ms, 0.22, cut, seed + bar), bar * 4 + h, 1.0 if h == 0 else 0.75)
    return y


def crackle(rng):
    y = mbuf()
    for _ in range(260):
        m = rng.integers(2, 12)
        place(y, rng.standard_normal(m) * rng.uniform(0.2, 1) ** 2, rng.integers(0, MUSIC_N))
    y = cfilt(y, 800, 7000)
    hiss = cfilt(rng.standard_normal(MUSIC_N), 1500, 6000)
    return norm_part(y) * 0.6 + norm_part(hiss) * 0.06


def music_layer(layer):
    rng = rng_for("music_" + layer)
    out = {}
    if layer == "nest":
        bed = norm_part(drone([38, 45], 380, seed=1)) * 0.55
        bed += norm_part(chord_pad(700, 50, 62, seed=10, attack=1.2)) * 0.35
        mel = mbuf()
        for beat, m, v in walk_melody(rng, 0.32, 62, 79):
            at(mel, marimba(m, 1.4, v), beat)
        bed += norm_part(mel) * 0.45
        bed = creverb(cfilt(bed, 30, 5000), 2.2, 0.3, seed=101)
        verb, hi = (1.6, 0.18), 4500
    elif layer == "surface":
        pl = mbuf()
        arp = [0, 2, 1, 3, 2, 4, 3, 1]
        for bar, ch in enumerate(BARS):
            notes = voice(set(pcs(ch)) | PENT, 62, 81)
            notes = [m for m in notes if m % 12 in pcs(ch) or m % 12 in PENT][::2][:6]
            for e, ix in enumerate(arp):
                if rng.random() < 0.18 and e % 2:
                    continue
                at(pl, pluck(notes[ix % len(notes)], 1.0, 4500, 0.995, rng.uniform(0.6, 1.0), seed=bar * 8 + e),
                   bar * 4 + e * 0.5)
        bed = norm_part(pl) * 0.5
        bed += norm_part(chord_pad(2200, 57, 69, seed=20, attack=1.5)) * 0.3
        air = cfilt(rng.standard_normal(MUSIC_N), 3000, 9000)
        bed += norm_part(air * (0.6 + 0.4 * periodic_lfo(rng, MUSIC_N, (1, 3)))) * 0.06
        bed = creverb(cfilt(bed, 40, 12000), 1.2, 0.2, seed=102)
        verb, hi = (1.0, 0.15), 12000
    else:
        keys = mbuf()
        for bar, ch in enumerate(BARS):
            ms = voice(pcs(ch, True), 57, 71)[:4]
            for h, d, v in ((0, 1.4, 1.0), (1.5 + 0.08, 0.9, 0.7), (3.0, 0.8, 0.8)):
                for k, m in enumerate(ms):
                    at(keys, ep(m, d * BEAT, v * 0.8, wow_ph=bar + k), bar * 4 + h + 0.012 * k)
        mel = mbuf()
        for beat, m, v in walk_melody(rng, 0.2, 69, 81, grid=0.5, snap_beats=(0, 2)):
            at(mel, ep(m, 0.9, v, wow_ph=beat), beat + (0.08 if beat % 1 else 0))
        bed = norm_part(keys) * 0.6 + norm_part(mel) * 0.35
        bed = cfilt(bed, 60, 1500, 2)
        bed += crackle(rng) * 0.08
        bed = creverb(bed, 0.8, 0.15, seed=103, hi=3000)
        verb, hi = (0.6, 0.12), 3500
    out[f"bed_{layer}"] = bed

    def finish_stem(x, seed):
        return creverb(cfilt(x, 30, hi), verb[0], verb[1], seed=seed, hi=min(hi, 8000))

    seed = 200 + ["nest", "surface", "house"].index(layer) * 10
    out[f"intense1_{layer}"] = finish_stem(drums_pulse(layer, rng), seed)
    i2 = norm_part(bass_line(layer, seed)) * 0.7 + norm_part(tension(layer, seed)) * 0.45
    out[f"intense2_{layer}"] = finish_stem(i2, seed + 1)
    i3 = norm_part(drums_full(layer, rng)) * 0.75 + norm_part(stabs(layer, seed)) * 0.45
    out[f"intense3_{layer}"] = finish_stem(i3, seed + 2)
    return out


MENU_MELODY = [
    # (bar, beat, midi, dur_beats)
    (0, 0, 69, 2), (0, 2, 65, 1), (0, 3, 67, 1),
    (1, 0, 69, 3), (1, 3, 74, 1),
    (2, 0, 74, 2), (2, 2, 72, 1), (2, 3, 70, 1),
    (3, 0, 72, 3), (3, 3, 67, 1),
    (4, 0, 69, 2), (4, 2, 74, 1), (4, 3, 76, 1),
    (5, 0, 77, 2), (5, 2, 76, 1), (5, 3, 72, 1),
    (6, 0, 74, 2), (6, 2, 71, 1), (6, 3, 67, 1),
    (7, 0, 69, 3), (7, 3, 72, 1),
    (8, 0, 74, 1.5), (8, 1.5, 77, 1.5), (8, 3, 74, 1),
    (9, 0, 76, 2), (9, 2, 79, 1), (9, 3, 76, 1),
    (10, 0, 77, 2), (10, 2, 76, 1), (10, 3, 74, 1),
    (11, 0, 76, 2), (11, 2, 72, 1), (11, 3, 64, 1),
]


def music_menu():
    rng = rng_for("music_menu")
    padl = chord_pad(1000, 50, 64, seed=40, attack=1.5)
    box = mbuf()
    for bar, beat, m, d in MENU_MELODY:
        at(box, bell(m + 12, max(1.2, d * BEAT * 1.5), 0.35), bar * 4 + beat, 0.8)
        at(box, marimba(m, 1.0, 0.4), bar * 4 + beat)
    low = mbuf()
    for bar, ch in enumerate(BARS):
        at(low, marimba(root(ch, 38), 2.0, 0.9), bar * 4)
        at(low, marimba(root(ch, 38) + 7, 1.5, 0.5), bar * 4 + 2)
    y = norm_part(padl) * 0.4 + norm_part(box) * 0.45 + norm_part(low) * 0.35
    y += norm_part(cfilt(rng.standard_normal(MUSIC_N), 2500, 8000)) * 0.02
    return creverb(cfilt(y, 30, 9000), 2.5, 0.3, seed=104)


# ----------------------------------------------------------------------------
# output
# ----------------------------------------------------------------------------
def finish(x, loop):
    x = np.asarray(x, float)
    if loop:
        x = x - x.mean()
    else:
        x = hp(x, 20, 1)
        n = len(x)
        fi, fo = min(N(0.002), n // 4), min(N(0.01), n // 4)
        x[:fi] *= np.linspace(0, 1, fi)
        x[-fo:] *= np.linspace(1, 0, fo) ** 2
    peak = np.max(np.abs(x))
    if not np.isfinite(peak) or peak <= 0:
        raise RuntimeError("silent or invalid signal")
    return x * (10 ** (PEAK_DB / 20) / peak)


def has_libvorbis():
    if not shutil.which("ffmpeg"):
        return False
    r = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True)
    return "libvorbis" in r.stdout


def write_ogg(path, x, quality, use_ffmpeg):
    wav = path[:-4] + ".wav"
    pcm = np.round(x * 32767).astype(np.int16)
    sf.write(wav, pcm, SR, subtype="PCM_16")
    if use_ffmpeg:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-c:a", "libvorbis",
                        "-q:a", str(quality), path], check=True)
    else:
        data, sr = sf.read(wav, dtype="float32")
        sf.write(path, data, sr, format="OGG", subtype="VORBIS",
                 compression_level=1.0 - quality / 10.0)
    os.remove(wav)
    return int(np.max(np.abs(pcm)))


def main():
    sfx_dir = os.path.join(OUT, "sfx")
    mus_dir = os.path.join(OUT, "music")
    os.makedirs(sfx_dir, exist_ok=True)
    os.makedirs(mus_dir, exist_ok=True)
    use_ffmpeg = has_libvorbis()
    print("encoder:", "ffmpeg libvorbis" if use_ffmpeg else "libsndfile vorbis (ffmpeg lacks libvorbis)")
    report = []

    for name, (fn, loop) in SFX.items():
        x = finish(fn(rng_for(name)), loop)
        pk = write_ogg(os.path.join(sfx_dir, name + ".ogg"), x, SFX_Q, use_ffmpeg)
        report.append(("sfx", name, len(x), pk, loop, x))
        print(f"sfx   {name:16s} {len(x) / SR:6.3f}s")

    tracks = {}
    for layer in ("nest", "surface", "house"):
        tracks.update(music_layer(layer))
    tracks["menu"] = music_menu()
    for name, x in tracks.items():
        assert len(x) == MUSIC_N, (name, len(x))
        x = finish(x, True)
        pk = write_ogg(os.path.join(mus_dir, name + ".ogg"), x, MUSIC_Q, use_ffmpeg)
        report.append(("music", name, len(x), pk, True, x))
        print(f"music {name:16s} {len(x) / SR:6.3f}s")

    worst = max(r[3] for r in report)
    print(f"max int16 peak before encoding: {worst} / 32767 ({20 * np.log10(worst / 32767):.2f} dBFS)")
    for kind, name, n, pk, loop, x in report:
        if loop:
            seam = abs(x[0] - x[-1]) / (np.max(np.abs(np.diff(x))) + 1e-12)
            if seam > 1.0:
                print(f"WARNING seam jump {kind}/{name}: {seam:.2f}x the largest in-loop step")


if __name__ == "__main__":
    sys.exit(main())
