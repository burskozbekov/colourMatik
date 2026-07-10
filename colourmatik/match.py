"""Orchestrator: try candidate transforms, measure dE00 on the actual output,
keep the most accurate, bake it to a LUT, and report before/after accuracy.

Every candidate is scored the same way — by the dE00 of its *display-encoded
output* (i.e. exactly what the .cube will do) versus the reference — so the winner
is chosen on true deliverable accuracy, not on fitting-space proxies.
"""
from __future__ import annotations
from dataclasses import dataclass, field
import numpy as np

from . import colorspace as cs
from . import transforms as tf_mod
from .metrics import (delta_e00, image_delta_e00, sliced_wasserstein,
                      summarize, verdict)
from .lut import build_lut, apply_lut, apply_lut_points, resample_lut
from .skin import skin_probability, skin_mask


@dataclass
class MatchResult:
    method: str
    scores: dict
    lut: np.ndarray
    tf: str
    corresponded: bool
    score_metric: str = "dE00"
    de_before: dict | None = None
    de_after: dict | None = None
    de_skin_before: float | None = None
    de_skin_after: float | None = None
    notes: list = field(default_factory=list)


def match(src_enc: np.ndarray, tgt_enc: np.ndarray, *, corresponded: bool = True,
          tf: str = "sRGB", size: int = 65, degrees=(1, 2, 3),
          lattice_L: int = 25, sample: int = 300_000, seed: int = 0,
          skin_protect: bool = True, skin_weight: float = 8.0,
          neural: bool = True, look: str = "exact") -> MatchResult:
    """Match `src_enc` (video 2) to `tgt_enc` (video 1). Returns winning LUT + report.

    Every candidate is turned into its actual `size^3` LUT, that LUT is applied to
    the source, and the result's mean dE00 vs the reference is the score — so the
    winner is chosen on exactly what ships, not on a fitting-space proxy.

    skin_protect weights skin pixels up during fitting (eyes are most critical of
    skin), so the match protects skin tones even at a small cost elsewhere.
    """
    # Sanitize inputs: display-referred [0,1], no NaN/Inf (e.g. a 32-bit float TIFF
    # can carry NaN). Keeps every downstream path — classical, SegFormer, CanonCGT — safe.
    src_enc = np.nan_to_num(np.clip(np.asarray(src_enc, dtype=np.float64), 0.0, 1.0))
    tgt_enc = np.nan_to_num(np.clip(np.asarray(tgt_enc, dtype=np.float64), 0.0, 1.0))

    # "AI cinematic grade" mode: use the CanonCGT learned reference grade directly,
    # instead of the accuracy contest. This is a photorealistic *look* transfer, not a
    # literal distribution match, so it is NOT scored against the classical candidates.
    if look == "ai_grade":
        try:
            from . import canoncgt as cg_mod
            lut = cg_mod.canon_lut(src_enc, tgt_enc, tf, size=size,
                                   lattice_L=lattice_L, seed=seed)
        except Exception:
            lut = None
        if lut is not None:
            res = MatchResult(method="canon", scores={"canon": 0.0}, lut=lut, tf=tf,
                              corresponded=corresponded,
                              score_metric="AI cinematic grade (CanonCGT)")
            res.notes.append("AI cinematic grade (CanonCGT): learned photorealistic "
                             "reference grade (a look transfer, not a literal match).")
            if corresponded and src_enc.shape == tgt_enc.shape:
                res.de_before = summarize(image_delta_e00(src_enc, tgt_enc, tf))
                res.de_after = summarize(image_delta_e00(apply_lut(src_enc, lut), tgt_enc, tf))
            return res
        # CanonCGT unavailable -> fall through to the classical accuracy contest.

    # Corresponded mode needs pixel-aligned frames; if the two clips differ in
    # resolution, resize the reference onto the source grid so correspondence (and
    # the same-index sampling below) is well-defined instead of crashing.
    if corresponded and src_enc.shape[:2] != tgt_enc.shape[:2]:
        from PIL import Image
        h, w = src_enc.shape[:2]
        _rt = Image.fromarray((np.clip(tgt_enc, 0, 1) * 255 + 0.5).astype("uint8"))
        tgt_enc = np.asarray(_rt.resize((w, h))).astype(np.float64) / 255.0

    S_lin = cs.decode(src_enc, tf).reshape(-1, 3)
    T_lin = cs.decode(tgt_enc, tf).reshape(-1, 3)
    S_enc = src_enc.reshape(-1, 3)
    T_enc = tgt_enc.reshape(-1, 3)

    rng = np.random.default_rng(seed)

    def _pick(n_total):
        return (rng.choice(n_total, sample, replace=False)
                if n_total > sample else np.arange(n_total))

    idx = _pick(S_enc.shape[0])          # source sample indices (used downstream)
    Sf_lin, Sf_enc = S_lin[idx], S_enc[idx]
    if corresponded:
        # aligned pixels: the reference must be sampled at the SAME indices
        Tf_lin, Tf_enc = T_lin[idx], T_enc[idx]
    else:
        # independent distributions: sample the reference on its own (clips may
        # differ in resolution / frame count, so indices need not match)
        tidx = _pick(T_enc.shape[0])
        Tf_lin, Tf_enc = T_lin[tidx], T_enc[tidx]

    weights = None
    if skin_protect:
        skin_p = skin_probability(S_enc)[idx]
        if skin_p.max() > 0.2:  # only when some skin is actually present
            weights = 1.0 + skin_weight * skin_p

    luts: dict = {}
    nctx = None  # local-AI (segmentation) context, set in distribution mode if available
    if corresponded:
        # Same content, pixel-aligned: learn the exact map from source->target pairs.
        for d in degrees:
            f = tf_mod.fit_polynomial(Sf_lin, Tf_lin, degree=d, weights=weights)
            luts[f"poly{d}"] = build_lut(f, size=size, tf=tf)
        luts["lattice"] = resample_lut(
            tf_mod.fit_lut_lattice(Sf_enc, Tf_enc, L=lattice_L, weights=weights), size)
        luts["mkl"] = build_lut(tf_mod.fit_mkl(Sf_lin, Tf_lin), size=size, tf=tf)
    else:
        # Different scenes / not aligned: match the colour DISTRIBUTIONS.
        luts["mkl"] = build_lut(tf_mod.fit_mkl(Sf_lin, Tf_lin), size=size, tf=tf)  # linear
        transported = np.clip(tf_mod.fit_idt(Sf_lin, Tf_lin, seed=seed), 0.0, None)  # nonlinear
        lat = tf_mod.fit_lut_lattice(Sf_enc, cs.encode(transported, tf),
                                     L=lattice_L, weights=weights)
        luts["idt"] = resample_lut(lat, size)
        # Local-AI candidate #1: scene segmentation -> region-to-region transport.
        if neural:
            try:
                from . import neural as nn_mod
                nctx = nn_mod.prepare(src_enc, tgt_enc, tf, size=size,
                                      lattice_L=lattice_L, seed=seed)
                if nctx is not None:
                    luts["neural"] = nctx.lut
            except Exception:
                nctx = None

    # Score every candidate LUT on exactly what it will output.
    scores = {}
    if corresponded:
        metric = "dE00"
        tgt_lab = cs.encoded_to_lab(T_enc, tf)
        for name, lut in luts.items():
            out_lab = cs.encoded_to_lab(apply_lut_points(lut, S_enc), tf)
            scores[name] = float(np.mean(delta_e00(out_lab, tgt_lab)))
    elif nctx is not None:
        # AI available: judge each candidate by how well it matches the reference
        # REGION BY REGION (sky↔sky, skin↔skin) — the cross-scene accuracy that a
        # single global distribution distance misses.
        metric = "semantic Wasserstein (AI region-matched)"
        for name, lut in luts.items():
            scores[name] = nctx.semantic_distance(apply_lut_points(lut, Sf_enc), idx)
    else:
        metric = "sliced-Wasserstein (Lab)"
        tgt_lab = cs.encoded_to_lab(Tf_enc, tf)
        for name, lut in luts.items():
            out_lab = cs.encoded_to_lab(apply_lut_points(lut, Sf_enc), tf)
            scores[name] = sliced_wasserstein(out_lab, tgt_lab, seed=seed)

    best = min(scores, key=scores.get)
    res = MatchResult(method=best, scores=scores, lut=luts[best], tf=tf,
                      corresponded=corresponded, score_metric=metric)

    if corresponded and src_enc.shape == tgt_enc.shape:
        de_b = image_delta_e00(src_enc, tgt_enc, tf)
        de_a = image_delta_e00(apply_lut(src_enc, luts[best]), tgt_enc, tf)
        res.de_before = summarize(de_b)
        res.de_after = summarize(de_a)
        sm = skin_mask(S_enc)
        if sm.sum() > 50:
            res.de_skin_before = float(de_b[sm].mean())
            res.de_skin_after = float(de_a[sm].mean())
    else:
        res.notes.append("Distribution mode: matched colour distributions "
                         "(no per-pixel ground truth).")
    return res


def format_report(res: MatchResult) -> str:
    lines = ["colourMatik — match report",
             f"  working space : {res.tf}",
             f"  mode          : {'corresponded' if res.corresponded else 'distribution'}",
             f"  candidates (lower is better, {res.score_metric}):"]
    for name, s in sorted(res.scores.items(), key=lambda kv: kv[1]):
        star = "  <- chosen" if name == res.method else ""
        lines.append(f"      {name:<8}: {s:6.3f}{star}")
    if res.de_before and res.de_after:
        b, a = res.de_before, res.de_after
        lines += ["  applied-LUT accuracy (per-pixel dE00):",
                  f"      before : mean {b['mean']:.3f}  p95 {b['p95']:.3f}  max {b['max']:.3f}",
                  f"      after  : mean {a['mean']:.3f}  p95 {a['p95']:.3f}  max {a['max']:.3f}   [{verdict(a['mean'])}]",
                  f"      improvement: {b['mean'] / max(a['mean'], 1e-9):.1f}x lower dE00"]
    if res.de_skin_after is not None:
        lines.append(f"  skin-tone accuracy: dE00 {res.de_skin_before:.3f} -> "
                     f"{res.de_skin_after:.3f}   [{verdict(res.de_skin_after)}]")
    for n in res.notes:
        lines.append(f"  note: {n}")
    return "\n".join(lines)
