"""Skin-tone detection (a colour qualifier, like DaVinci's HSL qualifier).

Human eyes are most critical of skin, so we detect skin pixels and weight them
up during fitting — the match protects skin even at a small cost elsewhere.

This is a calibrated Cr/Cb ellipse model (Y-Cr-Cb), which cleanly separates skin
from reds and neutrals. It is NOT a neural segmenter; a local ONNX face-parsing
model can be dropped in later behind the same interface for hands-free portraits.
"""
from __future__ import annotations
import numpy as np
import cv2

# Skin cluster centre, calibrated on ColorChecker skin patches (8-bit Cr/Cb).
_CR0, _CB0, _SIG = 149.0, 113.0, 11.0


def skin_probability(enc: np.ndarray) -> np.ndarray:
    """Per-pixel soft skin weight in [0,1]. Accepts (H,W,3) or (N,3) encoded RGB."""
    shape = enc.shape
    flat = np.clip(enc.reshape(-1, 3), 0.0, 1.0)
    if flat.size == 0:                       # empty selection -> empty result (cv2 would assert)
        return np.zeros(shape[:-1], dtype=np.float64)
    rgb8 = (flat * 255.0 + 0.5).astype(np.uint8).reshape(-1, 1, 3)
    ycc = cv2.cvtColor(rgb8, cv2.COLOR_RGB2YCrCb).reshape(-1, 3).astype(np.float64)
    Y, Cr, Cb = ycc[:, 0], ycc[:, 1], ycc[:, 2]
    p = np.exp(-0.5 * (((Cr - _CR0) / _SIG) ** 2 + ((Cb - _CB0) / _SIG) ** 2))
    gate = np.clip((Y - 35) / 25.0, 0, 1) * np.clip((250 - Y) / 25.0, 0, 1)  # not black/white
    return (p * gate).reshape(shape[:-1])


def skin_mask(enc: np.ndarray, thresh: float = 0.5) -> np.ndarray:
    return skin_probability(enc) > thresh
