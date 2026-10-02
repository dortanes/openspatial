# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#     "torch==2.4.1",
#     "torchaudio==2.4.1",
#     "demucs==4.0.1",
#     "coremltools==9.0",
#     "numpy",
#     "soundfile",
#     "onnxruntime",
#     "demucs-onnx @ git+https://github.com/StemSplit/demucs-onnx@85db5c80aba33f0f2bdf88034a4be6539feec85b",
# ]
# ///
"""Export the vocals specialist of HT-Demucs FT as a Core ML model that runs entirely on the Neural Engine.

    uv run separation/export.py path/to/music.wav

The STFT and the input statistics stay outside the model, where the app computes them in full precision:

Inputs:  spectrum (1, 4, 2048, 336): left real, left imaginary, right real, right imaginary of the
         Demucs STFT of 7.8 s at 44.1 kHz, normalised by its mean and unbiased standard deviation;
         mix (1, 2, 8, 43008): the same 343,980 samples normalised the same way, in 8 rows, zero after the end.
Outputs: vocals_spectrum in the spectrum's layout and vocals_wave in the mix's layout, both normalised.
         vocals = inverse STFT(vocals_spectrum * std + mean) + vocals_wave * std_mix + mean_mix.

The music file only checks precision; any song with vocals works.
"""
import copy
import shutil
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import soundfile
import torch
import torch.nn.functional as F
import torchaudio
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
from demucs.pretrained import get_model
from demucs_onnx.export.patch import patch_htdemucs_for_onnx

import folded

LENGTH = 343980  # 7.8 s at 44.1 kHz, the segment the model was trained on
WIDTH = 43008  # LENGTH folded into folded.ROWS rows, divisible by 16 for the two stride-4 levels
VOCALS = 3  # drums, bass, other, vocals
SPECIALIST = "04573f0d"  # the vocals model of the htdemucs_ft bag
OUT = Path(__file__).parent / "out"


@register_torch_op(torch_alias=["int"], override=True)
def _int(context, node):
    # With a fixed input length every shape is a constant; the stock converter rejects one-element arrays.
    x = _get_inputs(context, node, expected=1)[0]
    if x.val is not None:
        context.add(mb.const(val=np.int32(int(np.array(x.val).reshape(-1)[0])), name=node.name))
    else:
        context.add(mb.cast(x=x, dtype="int32", name=node.name))


class Core(torch.nn.Module):
    """HTDemucs.forward between the normalised inputs and the normalised vocals."""

    def __init__(self, model):
        super().__init__()
        self.m = model

    def forward(self, x, xt):
        m = self.m
        B, C, Fq, T = x.shape
        t0, l1 = folded.encode(m.tencoder[0], xt, LENGTH)
        t1, l2 = folded.encode(m.tencoder[1], t0, l1)
        t1 = folded.unfold(t1, l2)
        t2 = m.tencoder[2](t1)
        t3 = m.tencoder[3](t2)
        saved, lengths = [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            x = encode(x, None)
            if idx == 0:
                frequencies = torch.from_numpy(np.arange(x.shape[-2]))
                x = x + m.freq_emb_scale * m.freq_emb(frequencies).t()[None, :, :, None].expand_as(x)
            saved.append(x)
        b, c, f, t = x.shape
        x = m.channel_upsampler(x.reshape(b, c, f * t)).reshape(b, -1, f, t)
        x, xt = m.crosstransformer(x, m.channel_upsampler_t(t3))
        b, c, f, t = x.shape
        x = m.channel_downsampler(x.reshape(b, c, f * t)).reshape(b, -1, f, t)
        xt = m.channel_downsampler_t(xt)
        for decode in m.decoder:
            x, _ = decode(x, saved.pop(-1), lengths.pop(-1))
        xt, _ = m.tdecoder[0](xt, t3, t2.shape[-1])
        xt, _ = m.tdecoder[1](xt, t2, l2)
        # The third decoder leaves the length limit only at its transposed convolution.
        layer = m.tdecoder[2]
        y = layer.dconv(F.glu(layer.rewrite(xt + t1), dim=1))
        y = folded.fold(y, folded.ROWS, WIDTH // 16)
        xt = F.gelu(folded.conv_transpose(layer.conv_tr, y, layer.pad, l1))
        xt = folded.decode(m.tdecoder[3], xt, t0, l1, LENGTH)
        S = len(m.sources)
        x = x.view(B, S, -1, Fq, T)[:, VOCALS]
        xt = xt.view(B, S, -1, folded.ROWS, WIDTH)[:, VOCALS]
        return x, xt * folded.mask(LENGTH, folded.ROWS, WIDTH)


def load_segment(path):
    audio, rate = soundfile.read(path, dtype="float32", always_2d=True)
    audio = torchaudio.functional.resample(torch.from_numpy(audio.T.copy()), rate, 44100)
    start = max(0, (audio.shape[-1] - LENGTH) // 2)
    segment = audio[:2, start:start + LENGTH]
    assert segment.shape == (2, LENGTH), "the music file must be stereo and at least 7.8 s long"
    return segment[None]


def main():
    original = get_model(SPECIALIST).eval()
    model = patch_htdemucs_for_onnx(copy.deepcopy(original))
    for layer in model.decoder:
        layer.conv_tr = folded.FrequencyConvTranspose(layer.conv_tr)
    for layer in model.tdecoder:
        layer.conv_tr = folded.PolyphaseConvTranspose1d(layer.conv_tr)
    core = Core(model).eval()

    audio = load_segment(sys.argv[1])
    with torch.no_grad():
        z = original._spec(audio)
        spectrum = original._magnitude(z)
        reference = original(audio)[:, VOCALS]
        mean, std = spectrum.mean(), spectrum.std()
        mean_mix, std_mix = audio.mean(), audio.std()
        spectrum_in = (spectrum - mean) / (1e-5 + std)
        mix_in = folded.fold((audio - mean_mix) / (1e-5 + std_mix), folded.ROWS, WIDTH)

    def vocals(spectrum_out, wave_out):
        spectrum_out = spectrum_out * std + mean
        wave = folded.unfold(wave_out, LENGTH) * std_mix + mean_mix
        return original._ispec(original._mask(z, spectrum_out[:, None]), LENGTH)[:, 0] + wave

    def error(result):
        return 10 * np.log10(float(((result - reference) ** 2).mean() / (reference ** 2).mean()))

    with torch.no_grad():
        rewritten = vocals(*core(spectrum_in, mix_in))
    print(f"rewritten model vs original: {error(rewritten):.1f} dB")

    traced = torch.jit.trace(core, (spectrum_in, mix_in), check_trace=False)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="spectrum", shape=tuple(spectrum_in.shape)), ct.TensorType(name="mix", shape=tuple(mix_in.shape))],
        outputs=[ct.TensorType(name="vocals_spectrum"), ct.TensorType(name="vocals_wave")],
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel.short_description = "Vocals specialist of HT-Demucs FT, rewritten for the Neural Engine; STFT outside."
    mlmodel.author = "Meta Platforms, Inc. (HT-Demucs); Neural Engine rewrite by OpenSpatial"
    mlmodel.license = "MIT"
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir()
    package = OUT / "HTDemucsVocals.mlpackage"
    mlmodel.save(str(package))

    out = mlmodel.predict({"spectrum": spectrum_in.numpy(), "mix": mix_in.numpy()})
    converted = vocals(torch.from_numpy(out["vocals_spectrum"]).float(), torch.from_numpy(out["vocals_wave"]).float())
    print(f"Core ML on the Neural Engine vs original: {error(converted):.1f} dB")
    archive = shutil.make_archive(str(package), "zip", OUT, package.name)
    print(archive)


if __name__ == "__main__":
    main()
