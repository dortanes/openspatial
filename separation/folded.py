"""HT-Demucs layers rewritten for the Neural Engine, each matching the original to float rounding.

- Signals longer than the Neural Engine's 65,536-sample limit are folded into rows, (B, C, L) as
  (B, C, R, W), zero beyond the valid length; convolutions read across row edges from halos.
- Strided transposed convolutions become ordinary ones: on the Neural Engine of an M4 Pro the
  transposed form came out at -10 dB error against -43 dB on the CPU.
- Frequency-strided ones run with frequency on the width axis, which the Neural Engine accepts.
"""
import numpy as np
import torch
import torch.nn.functional as F

ROWS = 8


def mask(length, rows, width):
    # Built in NumPy so tracing records a constant rather than a range computed on the device.
    return torch.from_numpy((np.arange(rows * width) < length).astype(np.float32).reshape(1, 1, rows, width))


def fold(x, rows, width):
    return F.pad(x, (0, rows * width - x.shape[-1])).reshape(x.shape[0], x.shape[1], rows, width)


def unfold(x, length):
    return x.reshape(x.shape[0], x.shape[1], -1)[..., :length]


def halo(x, left, right):
    """Each row with `left` samples of the previous row before it and `right` of the next after it."""
    parts = []
    if left:
        parts.append(F.pad(x[:, :, :-1], (0, 0, 1, 0))[..., -left:])
    parts.append(x)
    if right:
        parts.append(F.pad(x[:, :, 1:], (0, 0, 0, 1))[..., :right])
    return torch.cat(parts, dim=-1)


def conv(layer, x, length):
    """A Conv1d on a folded signal of valid `length`; returns the result and its valid length."""
    k, s, d, p = layer.kernel_size[0], layer.stride[0], layer.dilation[0], layer.padding[0]
    right = max(0, d * (k - 1) - p - s + 1)
    y = F.conv2d(halo(x, p, right), layer.weight.unsqueeze(2), layer.bias, stride=(1, s), dilation=(1, d))
    out = (length + 2 * p - d * (k - 1) - 1) // s + 1
    return y * mask(out, y.shape[2], y.shape[3]), out


def polyphase(x, weight, bias, stride):
    """A transposed convolution along the last axis with a kernel of twice its stride, as one ordinary
    convolution per output phase: phase r at step m is x[m] * w[r] + x[m - 1] * w[r + stride].
    `weight` is (C_in, C_out, ..., 2 * stride) as in PyTorch."""
    c_out = weight.shape[1]
    assert weight.shape[-1] == 2 * stride
    phases = [torch.stack([weight[..., r + stride], weight[..., r]], dim=-1) for r in range(stride)]
    kernel = torch.cat(phases, dim=1).transpose(0, 1)  # (stride * C_out, C_in, ..., 2)
    convolve = F.conv1d if x.dim() == 3 else F.conv2d
    y = convolve(F.pad(x, (1, 1)), kernel, None if bias is None else bias.repeat(stride))
    steps = y.shape[-1]
    y = y.reshape(y.shape[0], stride, c_out, *y.shape[2:])
    y = y.permute(0, *range(2, y.dim()), 1)  # (B, C_out, ..., steps, stride)
    return y.reshape(*y.shape[:-2], steps * stride)


class PolyphaseConvTranspose1d(torch.nn.Module):
    def __init__(self, layer):
        super().__init__()
        assert layer.padding == (0,) and layer.kernel_size[0] == 2 * layer.stride[0]
        self.weight, self.bias, self.stride = layer.weight, layer.bias, layer.stride[0]

    def forward(self, x):
        return polyphase(x, self.weight, self.bias, self.stride)


class FrequencyConvTranspose(torch.nn.Module):
    """A ConvTranspose2d striding along frequency, run with frequency on the width axis."""

    def __init__(self, layer):
        super().__init__()
        assert layer.kernel_size[1] == 1 and layer.stride[1] == 1 and layer.padding == (0, 0)
        self.weight = torch.nn.Parameter(layer.weight.detach().permute(0, 1, 3, 2).contiguous(), requires_grad=False)
        self.bias = layer.bias
        self.stride = layer.stride[0]

    def forward(self, x):
        return polyphase(x.transpose(2, 3), self.weight, self.bias, self.stride).transpose(2, 3)


def conv_transpose(layer, x, crop, length):
    """A kernel-8, stride-4 ConvTranspose1d whose output is then cropped to [crop, crop + length)."""
    s = layer.weight.shape[-1] // 2
    width = x.shape[-1]
    y = polyphase(halo(x, 1, 1), layer.weight.unsqueeze(2), layer.bias, s)
    # The halo starts one input early, s output samples before the row.
    y = y[..., s + crop:s + crop + s * width]
    return y * mask(length, y.shape[2], y.shape[3])


def group_norm(norm, x, length):
    """GroupNorm with one group over the channels and the valid samples."""
    m = mask(length, x.shape[2], x.shape[3])
    count = x.shape[1] * length
    centered = (x - x.sum(dim=(1, 2, 3), keepdim=True) / count) * m
    var = (centered * centered).sum(dim=(1, 2, 3), keepdim=True) / count
    y = centered * torch.rsqrt(var + norm.eps)
    return (y * norm.weight[None, :, None, None] + norm.bias[None, :, None, None]) * m


def dconv(block, x, length):
    for layer in block.layers:
        first, norm1, _, second, norm2, _, scale = layer
        h, _ = conv(first, x, length)
        h = F.gelu(group_norm(norm1, h, length))
        h, _ = conv(second, h, length)
        h = F.glu(group_norm(norm2, h, length), dim=1)
        x = x + scale.scale[None, :, None, None] * h
    return x


def encode(layer, x, length):
    """An HEncLayer of the time branch, which has no normalisations in this model."""
    padded = -(-length // layer.stride) * layer.stride
    y, out = conv(layer.conv, x, padded)
    y = dconv(layer.dconv, F.gelu(y), out)
    z, _ = conv(layer.rewrite, y, out)
    return F.glu(z, dim=1), out


def decode(layer, x, skip, length_in, length_out):
    y, _ = conv(layer.rewrite, x + skip, length_in)
    y = dconv(layer.dconv, F.glu(y, dim=1), length_in)
    z = conv_transpose(layer.conv_tr, y, layer.pad, length_out)
    return z if layer.last else F.gelu(z)
