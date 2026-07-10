"""Synthetic ground-truth scenes + known colour distortions.

We build a rich reference image (24-patch ColorChecker + smooth gradients), then
apply a KNOWN distortion to simulate "a second camera". Because the distortion is
known and pixel-aligned, we have ground truth and can measure exactly how close
colourMatik gets it back (residual dE00 -> 0 == perfect).
"""
from __future__ import annotations
import numpy as np
from colourmatik.colorspace import decode, encode

# X-Rite ColorChecker, sRGB 8-bit rendered values (24 patches)
CC24 = np.array([
    [115, 82, 68], [194, 150, 130], [98, 122, 157], [87, 108, 67],
    [133, 128, 177], [103, 189, 170], [214, 126, 44], [80, 91, 166],
    [193, 90, 99], [94, 60, 108], [157, 188, 64], [224, 163, 46],
    [56, 61, 150], [70, 148, 73], [175, 54, 60], [231, 199, 31],
    [187, 86, 149], [8, 133, 161], [243, 243, 242], [200, 200, 200],
    [160, 160, 160], [122, 122, 121], [85, 85, 85], [52, 52, 52],
], dtype=np.float64) / 255.0

# Indices of the 6 neutral/grey patches (for white-balance / exposure checks)
NEUTRAL_IDX = [18, 19, 20, 21, 22, 23]


def build_reference(h: int = 480, w: int = 720) -> np.ndarray:
    """Encoded [0,1] RGB reference with a broad, continuous colour distribution."""
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    yy /= h
    xx /= w
    img = np.empty((h, w, 3))
    img[..., 0] = 0.15 + 0.70 * xx
    img[..., 1] = 0.15 + 0.70 * yy
    img[..., 2] = 0.50 + 0.35 * np.sin(2.0 * np.pi * (xx + yy))
    img = np.clip(img, 0.0, 1.0)

    # Overlay the 24 ColorChecker patches as a centred 4x6 grid.
    rows, cols = 4, 6
    ph, pw = h // (rows + 2), w // (cols + 2)
    y0, x0 = ph, pw
    for k in range(24):
        r, c = divmod(k, cols)
        ys, xs = y0 + r * ph, x0 + c * pw
        img[ys:ys + ph, xs:xs + pw, :] = CC24[k]
    return img


def build_portrait(h: int = 480, w: int = 720):
    """A SMALL skin-toned face on a colour-rich, non-skin background.

    Skin is a minority of pixels among many diverse colours, so a weak model must
    trade off — which is exactly where skin-weighting proves it protects skin.
    Returns (encoded_image, face_mask)."""
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    img = np.empty((h, w, 3))
    img[..., 0] = 0.10 + 0.28 * (xx / w)
    img[..., 1] = 0.22 + 0.45 * (yy / h)
    img[..., 2] = 0.30 + 0.40 * (1 - xx / w)
    img = np.clip(img, 0.0, 1.0)

    # tile the 22 NON-skin ColorChecker patches to make the background hard to fit
    nonskin = [k for k in range(24) if k not in (0, 1)]
    rows, cols = 4, 6
    ph, pw = h // rows, w // cols
    for i, k in enumerate(nonskin):
        r, c = divmod(i, cols)
        img[r * ph:(r + 1) * ph, c * pw:(c + 1) * pw, :] = CC24[k]

    # small face ellipse in the centre
    cy, cx, ry, rx = h * 0.5, w * 0.5, h * 0.13, w * 0.08
    e = ((yy - cy) / ry) ** 2 + ((xx - cx) / rx) ** 2
    mask = e <= 1.0
    skin = np.array([194, 150, 130]) / 255.0
    shade = (0.72 + 0.5 * np.clip(1.0 - e, 0, 1))[..., None]
    face = np.clip(skin[None, None, :] * shade, 0.0, 1.0)
    img = np.where(mask[..., None], face, img)
    return img, mask


def _tone_curve(x: np.ndarray, gamma: np.ndarray) -> np.ndarray:
    return np.clip(x, 0.0, None) ** gamma


def distort_linear(enc: np.ndarray, tf: str = "sRGB") -> np.ndarray:
    """Pure linear camera difference: white-balance gain + primary cross-mix.
    fit_linear (affine) should recover this essentially exactly (dE00 ~ 0)."""
    lin = decode(enc, tf)
    A = np.array([[1.10, 0.05, -0.03],
                  [-0.04, 0.94, 0.06],
                  [0.03, -0.07, 1.18]])
    lin2 = lin @ A.T
    return encode(np.clip(lin2, 0.0, None), tf)


def distort_nonlinear(enc: np.ndarray, tf: str = "sRGB") -> np.ndarray:
    """Realistic difference: WB gain + per-channel tone curve + saturation shift.
    Needs a nonlinear (poly) fit to recover well."""
    lin = decode(enc, tf)
    lin = lin * np.array([1.14, 1.00, 0.86])          # white balance
    lin = _tone_curve(lin, np.array([0.82, 0.90, 1.12]))  # per-channel gamma
    # saturation change around luma
    luma = lin @ np.array([0.2126, 0.7152, 0.0722])
    lin = luma[..., None] + 1.18 * (lin - luma[..., None])
    return encode(np.clip(lin, 0.0, None), tf)
