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
    # Camera log curves (published formulas, implemented by colour-science).
    # Matching log-to-log keeps the LUT in the log domain, so the user's own
    # downstream log->display conversion still applies untouched.
    "SLog3": "S-Log3",
    "CLog3": "Canon Log 3",
    "VLog": "V-Log",
    "Log3G10": "Log3G10",
    "AppleLog": "Apple Log Profile",
    "LogC3": "ARRI LogC3",
    "LogC4": "ARRI LogC4",
}


def resolve_tf(name: str) -> str:
    return _TF.get(name, name)


_DISPLAY_TFS = {"sRGB", "Rec709", "BT1886"}


def is_display_tf(name: str) -> bool:
    """True for display-referred curves, where linear [0,1] IS the gamut. Camera
    log curves are scene-referred: linear values far above 1.0 are legitimate
    highlights, so display-gamut mapping must not touch them."""
    return name in _DISPLAY_TFS or resolve_tf(name) in ("sRGB", "ITU-R BT.709", "ITU-R BT.1886")


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


# ---------------------------------------------------------------- Oklab
# Ottosson's Oklab (the CSS Color 4 space): near-CAM16-UCS perceptual uniformity
# at a trivial cost, and it fixes CIELAB's classic defect for grading work —
# blues drifting purple as lightness/chroma move. Reference constants from
# https://bottosson.github.io/posts/oklab/ (public-domain/MIT reference code).
_OK_M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                   [0.2119034982, 0.6806995451, 0.1073969566],
                   [0.0883024619, 0.2817188376, 0.6299787005]])
_OK_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                   [1.9779984951, -2.4285922050, 0.4505937099],
                   [0.0259040371, 0.7827717662, -0.8086757660]])
_OK_M1I = np.linalg.inv(_OK_M1)
_OK_M2I = np.linalg.inv(_OK_M2)


def linear_to_oklab(lin: np.ndarray) -> np.ndarray:
    """Linear sRGB -> Oklab. Shape (...,3) preserved. L in ~[0,1]."""
    lin = np.asarray(lin, dtype=np.float64)
    lms = lin @ _OK_M1.T
    lms = np.cbrt(np.clip(lms, 0.0, None))
    return lms @ _OK_M2.T


def oklab_to_linear(lab: np.ndarray) -> np.ndarray:
    """Oklab -> linear sRGB (may land outside [0,1] — that MEANS out of gamut)."""
    lms = np.asarray(lab, dtype=np.float64) @ _OK_M2I.T
    return (lms ** 3) @ _OK_M1I.T


def encoded_to_oklab(enc: np.ndarray, tf: str = "sRGB") -> np.ndarray:
    return linear_to_oklab(decode(enc, tf))
