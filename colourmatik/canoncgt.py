"""Optional LOCAL AI #2 — CanonCGT (CVPR 2026), reference-based colour grading.

CanonCGT is a learned model that, from a (source, reference) image pair, predicts
an image-adaptive 3D LUT in two stages (a 'canonicalizer' LUT that strips the
source's own style, then a 'grading' LUT that imposes the reference's look). Both
stages are global 3D-LUT transforms applied with grid_sample, so the whole thing
is a global colour function → it bakes cleanly into our .cube with no artifacts,
stays flicker-free, and runs on the Mac GPU (MPS). Apache-2.0 licensed.

We run it on a downscaled (source, reference), read back the recoloured source,
and fit our smooth lattice LUT to the (source → recoloured) pixel pairs — then it
competes as just another candidate that the engine scores and may auto-select.
Degrades gracefully: if torch or the vendored repo/weights are missing, returns
None and the caller falls back to the classical / SegFormer methods.
"""
from __future__ import annotations
import os
import sys
import threading
import numpy as np

from .lut import resample_lut
from . import transforms as tf_mod

_REPO = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "vendor", "CanonCGT")
_WEIGHTS = os.path.join(_REPO, "pretrained", "SSL_updated_251111.pth")
_CFG = os.path.join(_REPO, "configs", "Stage3_SSL_training_Flickr2K_PPR10K_LSDIR.yaml")
_MODEL = None            # cached (model, device) or False if unavailable
_CG_LOCK = threading.Lock()   # serialize lazy load + shared-model inference (FastAPI threadpool)


def available() -> bool:
    return _load() is not None


def _load():
    global _MODEL
    if _MODEL is not None:
        return _MODEL if _MODEL is not False else None
    with _CG_LOCK:
        if _MODEL is not None:
            return _MODEL if _MODEL is not False else None
        return _load_locked()


def _load_locked():
    global _MODEL
    try:
        import torch
        import yaml
        import argparse
        if not os.path.exists(_WEIGHTS):
            raise FileNotFoundError(_WEIGHTS)
        if _REPO not in sys.path:
            sys.path.insert(0, _REPO)          # repo uses top-level `models`/`utils` imports
        from models.networks.SSL_training import CanonCGT_SSL
        d = {"gpu": "0", "yaml_path": _CFG, "pretrained_path": _WEIGHTS}
        d.update(yaml.safe_load(open(_CFG)))
        cfg = argparse.Namespace(**d)
        model = CanonCGT_SSL(cfg)
        ck = torch.load(_WEIGHTS, map_location="cpu")
        model.load_state_dict(ck.get("model_state_dict", ck), strict=False)
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        model.to(device).eval()
        _MODEL = (model, device)
    except Exception:
        _MODEL = False
        return None
    return _MODEL


def _resize(enc: np.ndarray, max_side: int) -> np.ndarray:
    from PIL import Image
    h, w = enc.shape[:2]
    s = max_side / float(max(h, w))
    if s >= 1.0:
        return enc
    im = Image.fromarray((np.clip(enc, 0, 1) * 255 + 0.5).astype("uint8"))
    im = im.resize((max(1, int(w * s)), max(1, int(h * s))))
    return np.asarray(im).astype(np.float64) / 255.0


def canon_lut(src_enc: np.ndarray, ref_enc: np.ndarray, tf: str, *,
              size: int = 65, lattice_L: int = 25, max_side: int = 512,
              seed: int = 0) -> "np.ndarray | None":
    """Run CanonCGT on (src, ref) and bake its recolouring into a size^3 LUT.
    Returns the LUT (indexed [r,g,b]) or None if the model isn't available."""
    m = _load()
    if m is None:
        return None
    import torch
    model, device = m
    s = _resize(src_enc, max_side)
    r = _resize(ref_enc, max_side)

    def _infer(dev):
        it = torch.from_numpy(s).permute(2, 0, 1)[None].float().to(dev)
        rt = torch.from_numpy(r).permute(2, 0, 1)[None].float().to(dev)
        with torch.no_grad():
            return model(it, rt)["restyled"][0].float().cpu()

    with _CG_LOCK:                                   # serialize inference on the shared model
        try:
            o = _infer(device)
        except Exception:                            # e.g. an MPS-unsupported op -> retry on CPU
            if device == "cpu":
                return None
            try:
                model.to("cpu")
                o = _infer("cpu")
            except Exception:
                return None
            finally:
                model.to(device)

    o = o.clamp(0, 1)
    if not bool(torch.isfinite(o).all()):            # NaN/Inf -> skip, don't ship a broken grade
        return None
    out = o.permute(1, 2, 0).numpy().astype(np.float64)      # (h,w,3) recoloured source
    # corresponded fit: same pixels, source -> recoloured (both display-encoded)
    Sp = s.reshape(-1, 3)
    Tp = out.reshape(-1, 3)
    rng = np.random.default_rng(seed)
    n = Sp.shape[0]
    k = min(n, 120_000)
    idx = rng.choice(n, k, replace=False) if n > k else np.arange(n)
    lat = tf_mod.fit_lut_lattice(Sp[idx], Tp[idx], L=lattice_L)
    return resample_lut(lat, size)
