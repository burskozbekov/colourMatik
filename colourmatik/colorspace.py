"""Colour management: everything accurate happens in scene-linear light.

Input images are display-encoded (sRGB by default, or Rec.709 for video).
We decode to linear for the matching maths, and re-encode for the LUT / output.
"""
from __future__ import annotations
import numpy as np
import colour

_SRGB_CS = colour.RGB_COLOURSPACES["sRGB"]
_D65 = colour.CCS_ILLUMINANTS["CIE 1931 2 Degree Standard Observer"]["D65"]

# Transfer-function names understood by colour.cctf_{decoding,encoding}
_TF = {
    "sRGB": "sRGB",
    "Rec709": "ITU-R BT.709",
    "BT1886": "ITU-R BT.1886",
}


def resolve_tf(name: str) -> str:
    return _TF.get(name, name)


def decode(enc: np.ndarray, tf: str = "sRGB") -> np.ndarray:
    """Display-encoded [0,1] -> scene-linear."""
    return np.asarray(colour.cctf_decoding(enc, function=resolve_tf(tf)), dtype=np.float64)


def encode(lin: np.ndarray, tf: str = "sRGB") -> np.ndarray:
    """Scene-linear -> display-encoded [0,1]."""
    return np.asarray(colour.cctf_encoding(lin, function=resolve_tf(tf)), dtype=np.float64)


def linear_to_lab(lin: np.ndarray) -> np.ndarray:
    """Linear sRGB -> CIE L*a*b* (D65). Shape (...,3) preserved."""
    XYZ = colour.RGB_to_XYZ(lin, _SRGB_CS, apply_cctf_decoding=False)
    return colour.XYZ_to_Lab(XYZ, _D65)


def encoded_to_lab(enc: np.ndarray, tf: str = "sRGB") -> np.ndarray:
    return linear_to_lab(decode(enc, tf))
