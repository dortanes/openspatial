# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy", "scipy", "sofar"]
# ///
"""Render a stereo track as two loudspeakers in a measured control room (KU100 BRIRs).

Usage: uv run render.py <track> [seconds]
Writes a loudness-matched original excerpt and the room rendering to out/.
"""

import subprocess
import sys
import urllib.request
from pathlib import Path

import numpy as np
import sofar
from scipy.io import wavfile
from scipy.signal import fftconvolve, firwin2

FS = 48000
ROOT = Path(__file__).parent
SPEAKERS = [ROOT / "sofa" / "BRIR_CR1_KU_MICS_L.sofa", ROOT / "sofa" / "BRIR_CR1_KU_MICS_R.sofa"]
SOURCE = "https://sofacoustics.org/data/database/thk/"


def fetch():
    """Downloads the speakers' measurements that are not in sofa/ yet."""
    for path in SPEAKERS:
        if not path.exists():
            path.parent.mkdir(exist_ok=True)
            print("downloading", path.name)
            urllib.request.urlretrieve(SOURCE + path.name, path)


def decode(track, seconds):
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-t", str(seconds), "-i", str(track), "-f", "f32le", "-ac", "2", "-ar", str(FS), "-"],
        check=True,
        capture_output=True,
    ).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).T.astype(float)


def brir(path, view_deg=0):
    sofa = sofar.read_sofa(str(path))
    assert int(np.asarray(sofa.Data_SamplingRate).ravel()[0]) == FS
    views = np.asarray(sofa.ListenerView, dtype=float)[:, 0]
    index = int(np.argmin(np.abs((views - view_deg + 180) % 360 - 180)))
    return np.asarray(sofa.Data_IR, dtype=float)[index, :, 0, :]


def flattening_filter(brirs, taps=4095, boost_db=10, cut_db=15):
    """One EQ for both ears that flattens the average power response of the speaker pair.

    The same filter on both ears leaves interaural cues untouched and removes only the
    overall coloration of room, dummy head and loudspeakers.
    """
    n = 1 << 16
    freqs = np.fft.rfftfreq(n, 1 / FS)
    power = np.mean([np.abs(np.fft.rfft(h, n, axis=-1)) ** 2 for h in brirs], axis=(0, 1))
    # Third-octave smoothing: average power over [f / 2^(1/6), f * 2^(1/6)].
    cumulative = np.concatenate([[0], np.cumsum(power)])
    lo = np.searchsorted(freqs, freqs / 2 ** (1 / 6))
    hi = np.maximum(np.searchsorted(freqs, freqs * 2 ** (1 / 6), side="right"), lo + 1)
    smoothed = (cumulative[hi] - cumulative[lo]) / (hi - lo)
    gain_db = -10 * np.log10(smoothed)
    gain_db -= np.median(gain_db[(freqs > 200) & (freqs < 2000)])
    band = (freqs >= 40) & (freqs <= 16000)
    gain_db = np.interp(freqs, freqs[band], gain_db[band])
    gain_db = np.clip(gain_db, -cut_db, boost_db)
    return firwin2(taps, freqs, 10 ** (gain_db / 20), fs=FS)


def write(path, signal, scale):
    wavfile.write(path, FS, (signal.T * scale * 32767).astype(np.int16))


def main():
    track = Path(sys.argv[1])
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 60
    music = decode(track, seconds)
    fetch()
    left, right = (brir(path) for path in SPEAKERS)
    room = fftconvolve(music[0][None, :], left, axes=-1) + fftconvolve(music[1][None, :], right, axes=-1)
    eq = flattening_filter([left, right])
    flat = fftconvolve(room, eq[None, :], axes=-1)[:, eq.size // 2 :][:, : room.shape[-1]]
    renders = {"original": music, "room": room, "room flat": flat}
    for name, signal in renders.items():
        renders[name] = signal * np.sqrt(np.mean(music**2) / np.mean(signal**2))
    scale = 0.9 / max(np.max(np.abs(signal)) for signal in renders.values())
    out = ROOT / "out"
    out.mkdir(exist_ok=True)
    for name, signal in renders.items():
        write(out / f"{track.stem} - {name}.wav", signal, scale)
    print("left speaker, ear energy L/R dB:", round(10 * np.log10(np.sum(left[0] ** 2) / np.sum(left[1] ** 2)), 1))


if __name__ == "__main__":
    main()
