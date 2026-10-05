# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy", "scipy", "sofar"]
# ///
"""Export the rooms as 16-bit float response tables for the app.

Usage: uv run room/export.py [room ...]   (all rooms when none is named)

Each room is one loudspeaker re-aimed around the head by head rotation, with source azimuths 0-359° clockwise
from straight ahead; the room rotates with the source, so reflections are approximate. <room>_ring.f16 holds
[azimuth][ear][tap]. A room longer than the ring keeps the rest in <room>_tails.f16, [tail][ear][tap], one tail
for a loudspeaker at each of TAIL_AZIMUTHS, which the app holds still as the head turns. <room>.json gives the
sizes. Rooms inside the app go to app/brir; the others go to room/out as <room>.zip for the rooms release,
with their SHA-256 printed for app/Room.swift.
"""

import hashlib
import json
import shutil
import sys

import numpy as np
import sofar
from scipy.signal import fftconvolve, resample_poly

import render

RING_SIZE = 360
BLOCK = 512
# A room's ring: its direct sound and early reflections, 34 of the app's blocks.
RING_LENGTH = 34 * BLOCK
TAIL_AZIMUTHS = list(range(0, 360, 45))
# The left speaker's azimuth is searched among left head turns up to this many degrees.
MAX_SPEAKER_AZIMUTH = 90
BUNDLED = render.ROOT.parent / "app" / "brir"
DOWNLOADS = render.ROOT / "out"

# Measurements of the WDR broadcast studios: the left loudspeaker, the right one where it was measured, and
# seconds of response kept, about where the reverberation has decayed by 60 dB. None keeps the measurement whole.
ROOMS = {
    "cr1": dict(left="BRIR_CR1_KU_MICS_L.sofa", right="BRIR_CR1_KU_MICS_R.sofa", seconds=None, bundled=True),
    "cr7": dict(left="BRIR_CR7_KU_MICS_L.sofa", right="BRIR_CR7_KU_MICS_R.sofa", seconds=RING_LENGTH / render.FS, bundled=False),
    "sbs": dict(left="BRIR_SBS_KU_MICS_PAL.sofa", right="BRIR_SBS_KU_MICS_PAR.sofa", seconds=0.9, bundled=False),
    # The large studio has no right PA speaker; the left one mirrored stands in for it.
    "lbs": dict(left="BRIR_LBS_KU_MICS_PAL.sofa", right=None, seconds=1.75, bundled=False),
}
# The same dummy head with no room: anechoic responses on the horizontal circle at 1° steps.
FREE = "HRIR_CIRC360.sofa"


def load(path):
    sofa = sofar.read_sofa(str(path), verbose=False)
    views = np.asarray(sofa.ListenerView, dtype=float)[:, 0]
    return views, np.asarray(sofa.Data_IR, dtype=float)[:, :, 0, :]


def ild_db(h):
    return 10 * np.log10(np.sum(h[0] ** 2) / np.sum(h[1] ** 2))


def direct_itd_us(h, onset, upsample=8):
    """Interaural time difference of the first 2.5 ms of direct sound; negative when the left ear leads."""
    direct = resample_poly(h[:, max(onset - 24, 0) : onset + int(0.0025 * render.FS)], upsample, 1, axis=-1)
    lag = np.argmax(np.correlate(direct[0], direct[1], "full")) - (direct.shape[1] - 1)
    return lag / upsample / render.FS * 1e6


def room_ring(name, spec):
    """The left speaker re-aimed to every azimuth, and the speaker pair facing ahead, before equalization."""
    paths = [render.ROOT / "sofa" / spec["left"]] + ([render.ROOT / "sofa" / spec["right"]] if spec["right"] else [])
    render.fetch(paths)
    views, left = load(paths[0])

    def view(azimuth):
        return int(np.argmin(np.abs((views - azimuth + 180) % 360 - 180)))

    # Turning toward the left speaker puts it straight ahead, so its level difference vanishes there.
    toward_left = ild_db(left[view(30)]), ild_db(left[view(-30)])
    right_turn_sign = -1 if abs(toward_left[0]) < abs(toward_left[1]) else 1

    # The left speaker is straight ahead at the left head turn where its interaural time difference vanishes.
    # A source at clockwise azimuth a then needs a left head turn of a minus the speaker's azimuth.
    onset = int(np.argmax(np.abs(left).max(axis=(0, 1)) > 0.1 * np.abs(left).max()))
    itds = [direct_itd_us(left[view(-right_turn_sign * t)], onset) for t in range(MAX_SPEAKER_AZIMUTH + 1)]
    left_speaker_azimuth = -int(np.argmin(np.abs(itds)))
    print(name, "left speaker azimuth from ITD:", left_speaker_azimuth, "| right turn maps to SOFA view sign", right_turn_sign)

    ring = np.stack([left[view(-right_turn_sign * (a - left_speaker_azimuth))] for a in range(RING_SIZE)])
    if spec["right"]:
        right_views, right = load(paths[1])
        assert np.allclose(views, right_views)
        right_ahead = right[view(0)]
    else:
        right_ahead = left[view(0)][::-1]
    return ring, np.stack([left[view(0)], right_ahead])


def free_ring():
    """Anechoic responses of the dummy head at every azimuth, and the pair at ±30°."""
    path = render.ROOT / "sofa" / FREE
    render.fetch([path])
    sofa = sofar.read_sofa(str(path), verbose=False)
    assert int(np.asarray(sofa.Data_SamplingRate).ravel()[0]) == render.FS
    irs = np.asarray(sofa.Data_IR, dtype=float)
    # SOFA azimuths run counterclockwise; the ring runs clockwise.
    azimuths = np.asarray(sofa.SourcePosition, dtype=float)[:, 0]
    nearest = [int(np.argmin(np.abs((azimuths + a + 180) % 360 - 180))) for a in range(RING_SIZE)]
    ring = irs[nearest]
    return ring, np.stack([ring[RING_SIZE - 30], ring[30]])


def equalize(ring, pair, seconds):
    """Flattens the pair's average power response, sets the pair to about unity loudness, trims the silence
    before the direct sound and cuts the response at `seconds` with a fade over its last 15 percent."""
    eq = render.flattening_filter(list(pair))
    length = ring.shape[-1]

    def flatten(table):
        return fftconvolve(table, eq[None, None, :], axes=-1)[..., eq.size // 2 : eq.size // 2 + length]

    ring, pair = flatten(ring), flatten(pair)
    peak = max(np.max(np.abs(ring)), np.max(np.abs(pair)))
    onset = min(int(np.argmax(np.any(np.abs(table) > 1e-3 * peak, axis=tuple(range(table.ndim - 1))))) for table in (ring, pair))
    start = max(onset - 32, 0)
    gain = 0.5 / np.sqrt(np.mean(np.sum(pair**2, axis=(0, 2))))
    ring = ring[..., start:] * gain
    if seconds is not None:
        keep = min(ring.shape[-1], int(seconds * render.FS))
        fade = int(keep * 0.15)
        ring = ring[..., :keep].copy()
        ring[..., keep - fade :] *= np.cos(np.linspace(0, np.pi / 2, fade)) ** 2
    return ring


def write(name, ring, folder):
    folder.mkdir(parents=True, exist_ok=True)
    tails = ring[[azimuth for azimuth in TAIL_AZIMUTHS], :, RING_LENGTH:] if ring.shape[-1] > RING_LENGTH else None
    if tails is not None:
        ring = ring[..., :RING_LENGTH]
        tails.astype("<f2").tofile(folder / f"{name}_tails.f16")
    ring.astype("<f2").tofile(folder / f"{name}_ring.f16")
    header = {
        "length": ring.shape[-1],
        "ringSize": RING_SIZE,
        "sampleRate": render.FS,
        "tailLength": 0 if tails is None else tails.shape[-1],
        "tailAzimuths": TAIL_AZIMUTHS if tails is not None else [],
    }
    (folder / f"{name}.json").write_text(json.dumps(header) + "\n")
    print(name, header["length"], "ring taps,", header["tailLength"], "tail taps")


def main():
    names = sys.argv[1:] or ["free", *ROOMS]
    for name in names:
        if name == "free":
            ring, pair = free_ring()
            write(name, equalize(ring, pair, None), BUNDLED)
            continue
        spec = ROOMS[name]
        ring, pair = room_ring(name, spec)
        ring = equalize(ring, pair, spec["seconds"])
        if spec["bundled"]:
            write(name, ring, BUNDLED)
            continue
        staging = DOWNLOADS / name
        shutil.rmtree(staging, ignore_errors=True)
        write(name, ring, staging)
        archive = shutil.make_archive(str(DOWNLOADS / name), "zip", staging)
        digest = hashlib.sha256(open(archive, "rb").read()).hexdigest()
        print(name, "archive", archive, "sha256", digest)


if __name__ == "__main__":
    main()
