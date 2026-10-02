# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy", "scipy", "sofar"]
# ///
"""Export the measured room as a flat float32 response table for the app.

cr1_ring.f32: the left loudspeaker re-aimed by head rotation, [azimuth][ear][tap], source azimuth 0-359°
clockwise from straight ahead. The room rotates with the source, so reflections are approximate.
"""

import json

import numpy as np
import sofar
from scipy.signal import fftconvolve, resample_poly

import render

RING_SIZE = 360
# The left speaker's azimuth is searched among left head turns up to this many degrees.
MAX_SPEAKER_AZIMUTH = 90
OUT = render.ROOT.parent / "app" / "brir"


def load(path):
    sofa = sofar.read_sofa(str(path))
    views = np.asarray(sofa.ListenerView, dtype=float)[:, 0]
    return views, np.asarray(sofa.Data_IR, dtype=float)[:, :, 0, :]


def ild_db(h):
    return 10 * np.log10(np.sum(h[0] ** 2) / np.sum(h[1] ** 2))


def direct_itd_us(h, onset, upsample=8):
    """Interaural time difference of the first 2.5 ms of direct sound; negative when the left ear leads."""
    direct = resample_poly(h[:, max(onset - 24, 0) : onset + int(0.0025 * render.FS)], upsample, 1, axis=-1)
    lag = np.argmax(np.correlate(direct[0], direct[1], "full")) - (direct.shape[1] - 1)
    return lag / upsample / render.FS * 1e6


def main():
    render.fetch()
    (views, left), (views_r, right) = (load(path) for path in render.SPEAKERS)
    assert np.allclose(views, views_r)

    def view(azimuth):
        return int(np.argmin(np.abs((views - azimuth + 180) % 360 - 180)))

    # Turning toward the left speaker puts it straight ahead, so its level difference vanishes there.
    toward_left = ild_db(left[view(30)]), ild_db(left[view(-30)])
    print("left speaker ILD dB at view +30 / -30:", np.round(toward_left, 1))
    right_turn_sign = -1 if abs(toward_left[0]) < abs(toward_left[1]) else 1

    # The left speaker is straight ahead at the left head turn where its interaural time difference vanishes.
    # A source at clockwise azimuth a then needs a left head turn of a minus the speaker's azimuth.
    onset = int(np.argmax(np.abs(left).max(axis=(0, 1)) > 0.1 * np.abs(left).max()))
    itds = [direct_itd_us(left[view(-right_turn_sign * t)], onset) for t in range(MAX_SPEAKER_AZIMUTH + 1)]
    left_speaker_azimuth = -int(np.argmin(np.abs(itds)))
    print("left speaker azimuth from ITD:", left_speaker_azimuth)

    eq = render.flattening_filter([left[view(0)], right[view(0)]])
    length = left.shape[-1]

    def flatten(table):
        return fftconvolve(table, eq[None, None, :], axes=-1)[..., eq.size // 2 : eq.size // 2 + length]

    ring = flatten(np.stack([left[view(-right_turn_sign * (a - left_speaker_azimuth))] for a in range(RING_SIZE)]))
    # The measured stereo pair facing ahead sets the level, so a stereo source plays at about unity loudness.
    pair = flatten(np.stack([left[view(0)], right[view(0)]]))

    peak = max(np.max(np.abs(ring)), np.max(np.abs(pair)))
    onset = min(int(np.argmax(np.any(np.abs(table) > 1e-3 * peak, axis=(0, 1)))) for table in (ring, pair))
    start = max(onset - 32, 0)
    gain = 0.5 / np.sqrt(np.mean(np.sum(pair**2, axis=(0, 2))))

    OUT.mkdir(exist_ok=True)
    (ring[..., start:] * gain).astype("<f4").tofile(OUT / "cr1_ring.f32")
    header = {"length": length - start, "ringSize": RING_SIZE, "sampleRate": render.FS}
    (OUT / "cr1.json").write_text(json.dumps(header) + "\n")
    print("ring ILD dB at 0/90/180/270:", [round(ild_db(ring[a]), 1) for a in (0, 90, 180, 270)])
    print("right turn maps to SOFA view sign", right_turn_sign, "| trimmed", start, "taps |", header)


if __name__ == "__main__":
    main()
