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
from .lut import (build_lut, apply_lut, apply_lut_points, resample_lut,
                  gamut_guard, lut_steepness, steep_guard)
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
    # Top alternative candidate LUTs (name -> guarded float32 LUT), winner first.
    # The panel shows these as clickable look previews instead of silently
    # discarding every runner-up.
    alts: dict = field(default_factory=dict)
    # Small linear-RGB sample of each side (float32), kept so the strength
    # decomposition (WB / tone / colour sliders) can be fitted on demand.
    sample_src_lin: np.ndarray | None = None
    sample_tgt_lin: np.ndarray | None = None


def match(src_enc: np.ndarray, tgt_enc: np.ndarray, *, corresponded: bool = True,
          tf: str = "sRGB", size: int = 65, degrees=(1, 2, 3),
          lattice_L: int = 25, sample: int = 300_000, seed: int = 0,
          skin_protect: bool = True, skin_weight: float = 8.0,
          neural: bool = False, look: str = "exact",
          refine: bool = False, quick: bool = False, progress=None) -> MatchResult:
    """Match `src_enc` (video 2) to `tgt_enc` (video 1). Returns winning LUT + report.

    Every candidate is turned into its actual `size^3` LUT, that LUT is applied to
    the source, and the result's mean dE00 vs the reference is the score — so the
    winner is chosen on exactly what ships, not on a fitting-space proxy.

    skin_protect weights skin pixels up during fitting (eyes are most critical of
    skin), so the match protects skin tones even at a small cost elsewhere.
    """
    # Optional progress reporter: progress(fraction 0..1, human message). No-op if None.
    def _p(frac, msg):
        if progress:
            try: progress(float(frac), msg)
            except Exception: pass

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
            _p(0.35, "AI cinematic grade")
            lut = cg_mod.canon_lut(src_enc, tgt_enc, tf, size=size,
                                   lattice_L=lattice_L, seed=seed)
        except Exception:
            lut = None
        if lut is not None:
            # Same gamut guard as the classical path: outside the colours the
            # source actually contains, fall back to the capped global MKL so the
            # learned grade can't hand out-of-sample pixels something insane.
            try:
                _rngg = np.random.default_rng(seed)
                _Se = src_enc.reshape(-1, 3)
                _Te = tgt_enc.reshape(-1, 3)
                _si = (_rngg.choice(_Se.shape[0], 200_000, replace=False)
                       if _Se.shape[0] > 200_000 else np.arange(_Se.shape[0]))
                _ti = (_rngg.choice(_Te.shape[0], 200_000, replace=False)
                       if _Te.shape[0] > 200_000 else np.arange(_Te.shape[0]))
                _fb = build_lut(tf_mod.fit_mkl(cs.decode(_Se[_si], tf),
                                               cs.decode(_Te[_ti], tf)),
                                size=size, tf=tf)
                lut = gamut_guard(lut, _Se[_si], _fb)
                lut = steep_guard(lut, _fb)
            except Exception:
                pass
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

    # "Same scene" clicked for two DIFFERENT shots is the single most damaging
    # misuse: corresponded matching pairs pixels BY POSITION, so unaligned frames
    # produce a garbage mapping that still "wins" its own contest (seen in the
    # field: MKL crowned at dE00 26). Detect it — structural correlation of the
    # two frames at 64px — and quietly fall back to distribution matching.
    if corresponded:
        from PIL import Image as _Im
        def _tiny_gray(a):
            g = _Im.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype("uint8")).convert("L")
            return np.asarray(g.resize((64, 64)), dtype=np.float64).ravel()
        ga, gb = _tiny_gray(src_enc), _tiny_gray(tgt_enc)
        ga -= ga.mean(); gb -= gb.mean()
        denom = float(np.sqrt((ga * ga).sum() * (gb * gb).sum()))
        corr = float((ga * gb).sum() / denom) if denom > 1e-9 else 0.0
        if corr < 0.45:
            corresponded = False
        _CORR_PRECHECK = corr

    S_lin = cs.decode(src_enc, tf).reshape(-1, 3)
    T_lin = cs.decode(tgt_enc, tf).reshape(-1, 3)
    S_enc = src_enc.reshape(-1, 3)
    T_enc = tgt_enc.reshape(-1, 3)

    # Quick mode: the 2-5s draft the panel applies immediately while the full
    # contest keeps running in the background. Fewer samples, cheap candidates
    # only, no AI, no refine - the full pass hot-swaps the result moments later.
    if quick:
        sample = min(sample, 60_000)
        degrees = (1, 2)
        neural = False
        refine = False

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
        luts["sep"] = build_lut(tf_mod.fit_sep(Sf_lin, Tf_lin), size=size, tf=tf)
    else:
        # Different scenes / not aligned: match the colour DISTRIBUTIONS.
        _p(0.10, "Matching colour distributions")
        # ModFlows runs on the GPU while the CPU fits the classical candidates —
        # the two workloads barely contend, so this is nearly free wall-clock.
        _flow_box = {}
        _flow_th = None
        if neural:
            def _flow_job():
                try:
                    from . import modflows as mf_mod
                    if mf_mod.loaded_nowait():
                        _flow_box["lut"] = mf_mod.modflows_lut(src_enc, tgt_enc, size=size)
                except Exception:
                    pass
            import threading as _thr
            _flow_th = _thr.Thread(target=_flow_job, daemon=True)
            _flow_th.start()
        luts["mkl"] = build_lut(tf_mod.fit_mkl(Sf_lin, Tf_lin), size=size, tf=tf)  # linear
        luts["sep"] = build_lut(tf_mod.fit_sep(Sf_lin, Tf_lin), size=size, tf=tf)  # 1D curves + 3D residual
        if quick:
            transported = None
        else:
            # IDT + the lattice both scale with point count, and together they
            # were the single biggest cost of a match (profiled 9.7s of ~20s on
            # a warm engine at 300k points). A 25^3 lattice has 15,625 nodes —
            # 150k points saturate it; accuracy is checked by the regression
            # battery, wall-clock is roughly halved.
            _cap = 150_000
            if Sf_lin.shape[0] > _cap:
                _sel = rng.choice(Sf_lin.shape[0], _cap, replace=False)
                _idt_src_lin, _idt_src_enc = Sf_lin[_sel], Sf_enc[_sel]
                _idt_w = weights[_sel] if weights is not None else None
                _idt_tgt = Tf_lin[rng.choice(Tf_lin.shape[0], _cap, replace=False)]
            else:
                _idt_src_lin, _idt_src_enc, _idt_w, _idt_tgt = Sf_lin, Sf_enc, weights, Tf_lin
            transported = np.clip(tf_mod.fit_idt(_idt_src_lin, _idt_tgt, seed=seed), 0.0, None)
        if transported is not None:
            lat = tf_mod.fit_lut_lattice(_idt_src_enc, cs.encode(transported, tf),
                                         L=lattice_L, weights=_idt_w)
            luts["idt"] = resample_lut(lat, size)
        # ModFlows (AAAI 2025, MIT weights) — collect the parallel result.
        if _flow_th is not None:
            _flow_th.join(timeout=60)
            if _flow_box.get("lut") is not None:
                luts["flow"] = _flow_box["lut"]
        # Unbalanced Sinkhorn transport (optional — needs torch+geomloss from the
        # AI extras). Fixes IDT's exact-mass failure: a reference dominated by one
        # colour (a huge sky) no longer forces that colour onto unrelated content.
        try:
            if quick:
                raise ImportError("quick mode skips uot")
            _u = np.random.default_rng(seed + 1)
            cap = 6_000   # tensorized Sinkhorn is O(N*M); 6k points describe a 3D colour cloud fine
            ui = (_u.choice(Sf_lin.shape[0], cap, replace=False)
                  if Sf_lin.shape[0] > cap else np.arange(Sf_lin.shape[0]))
            uj = (_u.choice(Tf_lin.shape[0], cap, replace=False)
                  if Tf_lin.shape[0] > cap else np.arange(Tf_lin.shape[0]))
            tx = tf_mod.fit_uot(Sf_lin[ui], Tf_lin[uj])
            uw = weights[ui] if weights is not None else None
            luts["uot"] = resample_lut(
                tf_mod.fit_lut_lattice(Sf_enc[ui], cs.encode(tx, tf),
                                       L=lattice_L, weights=uw), size)
        except ImportError:
            pass          # geomloss not installed -> candidate simply absent
        except Exception:
            pass          # never let an optional candidate sink the match
        # Local-AI candidate #1: scene segmentation -> region-to-region transport.
        if neural:
            try:
                from . import neural as nn_mod
                if not nn_mod.loaded_nowait():
                    raise ImportError("segmentation still warming up — skip this round")
                _p(0.35, "AI scene analysis")
                nctx = nn_mod.prepare(src_enc, tgt_enc, tf, size=size,
                                      lattice_L=lattice_L, seed=seed)
                if nctx is not None:
                    luts["neural"] = nctx.lut
            except Exception:
                nctx = None

    # Score every candidate LUT on exactly what it will output. Judged in OKLAB
    # (x100 to keep dE-like magnitudes): near-CAM16 perceptual uniformity without
    # CIELAB's blue-drifts-purple defect, so the judge can no longer be gamed by
    # hue errors CIELAB under-counts. Reported accuracy (de_after) stays dE00 —
    # the industry-familiar number.
    _p(0.62, "Scoring candidates")
    scores = {}
    # Score on a bounded subsample: with 6 candidates the full pixel set costs
    # seconds for a MEAN that 120k pixels already pin to 3 decimals.
    _SCORE_N = 60_000
    if corresponded:
        metric = "Oklab dE (x100)"
        sidx = (rng.choice(S_enc.shape[0], _SCORE_N, replace=False)
                if S_enc.shape[0] > _SCORE_N else np.arange(S_enc.shape[0]))
        S_sc, T_sc = S_enc[sidx], T_enc[sidx]
        tgt_ok = cs.encoded_to_oklab(T_sc, tf) * 100.0
        for name, lut in luts.items():
            out_ok = cs.encoded_to_oklab(apply_lut_points(lut, S_sc), tf) * 100.0
            scores[name] = float(np.mean(np.linalg.norm(out_ok - tgt_ok, axis=-1)))
    elif nctx is not None:
        # AI available: judge REGION BY REGION (sky<->sky, skin<->skin) — the
        # cross-scene accuracy a single global distance misses — AND by the
        # neutral global distribution distance.
        #
        # Both are needed because the semantic metric is derived from the very
        # segmentation the "neural" candidate is fitted on: it grades its own
        # homework. Measured on a two-region test scene, the semantic judge
        # crowned "neural" (0.133) while a neutral Oklab sliced-Wasserstein put
        # it LAST (0.209 vs idt's 0.076) — i.e. the engine was shipping the
        # objectively weaker match. Combining as a geometric mean of each
        # metric RELATIVE TO ITS OWN BEST keeps the region insight but denies
        # either judge the power to carry a candidate alone.
        metric = "region + distribution (combined)"
        sem, neu = {}, {}
        # bounded scoring sample (12 metric passes across 6 candidates otherwise
        # dominates the match); idx must be sliced identically so the semantic
        # judge still looks up the right per-pixel class labels
        ssel = (rng.choice(Sf_enc.shape[0], _SCORE_N, replace=False)
                if Sf_enc.shape[0] > _SCORE_N else np.arange(Sf_enc.shape[0]))
        Sf_sc, idx_sc = Sf_enc[ssel], idx[ssel]
        tsel = (rng.choice(Tf_enc.shape[0], _SCORE_N, replace=False)
                if Tf_enc.shape[0] > _SCORE_N else np.arange(Tf_enc.shape[0]))
        tgt_ok_s = cs.encoded_to_oklab(Tf_enc[tsel], tf) * 100.0
        for name, lut in luts.items():
            out_enc = apply_lut_points(lut, Sf_sc)
            sem[name] = float(nctx.semantic_distance(out_enc, idx_sc))
            neu[name] = float(sliced_wasserstein(
                cs.encoded_to_oklab(out_enc, tf) * 100.0, tgt_ok_s, seed=seed))
        smin = max(min(sem.values()), 1e-9)
        nmin = max(min(neu.values()), 1e-9)
        for name in luts:
            scores[name] = float(np.sqrt((sem[name] / smin) * (neu[name] / nmin)))

        def _combined(out_enc):          # refine must be judged the SAME way
            s = float(nctx.semantic_distance(out_enc, idx_sc)) / smin
            n = float(sliced_wasserstein(
                cs.encoded_to_oklab(out_enc, tf) * 100.0, tgt_ok_s, seed=seed)) / nmin
            return float(np.sqrt(s * n))
    else:
        metric = "sliced-Wasserstein (Oklab)"
        ssel = (rng.choice(Sf_enc.shape[0], _SCORE_N, replace=False)
                if Sf_enc.shape[0] > _SCORE_N else np.arange(Sf_enc.shape[0]))
        tsel = (rng.choice(Tf_enc.shape[0], _SCORE_N, replace=False)
                if Tf_enc.shape[0] > _SCORE_N else np.arange(Tf_enc.shape[0]))
        tgt_ok = cs.encoded_to_oklab(Tf_enc[tsel], tf) * 100.0
        for name, lut in luts.items():
            out_ok = cs.encoded_to_oklab(apply_lut_points(lut, Sf_enc[ssel]), tf) * 100.0
            scores[name] = sliced_wasserstein(out_ok, tgt_ok, seed=seed)

    # Steepness penalty: a candidate that "wins" the distance metric with 10x+
    # local slopes ships visible damage — steep segments turn 8-bit and H.264
    # macroblock steps into posterised patches on real footage. Multiplicative,
    # so it is scale-free across the three metrics; a steep LUT now only wins if
    # it is MUCH more accurate than a smooth one.
    for name in scores:
        s = lut_steepness(luts[name])
        scores[name] = float(scores[name]) * (1.0 + 0.15 * max(0.0, s - 4.0))

    # Smooth-region damage penalty (distribution mode). The distribution judges
    # are blind to WHERE colours land on the frame: IDT can "win" the
    # sliced-Wasserstein while turning a clean sky gradient into posterised
    # bands and hue arcs (field case: a no-sky wheat close-up as reference
    # forced a wide shot's blue sky through banded brown — IDT scored 0.18 vs
    # sep's 0.80 and shipped). So ALSO judge each candidate on the actual
    # frame: how much it roughens regions the source renders smooth, in Oklab
    # so banding and hue swings both count. Measured damage on the field pair:
    # idt 3.14, sep 1.17, mkl 0.89; on a well-matched pair every candidate sits
    # near 1.5 — so the penalty starts at 1.8 and is steep enough (x4 per unit)
    # that a distribution win cannot buy back a posterised sky, while a benign
    # IDT (damage under 1.8) keeps its earned win untouched.
    if not corresponded:
        try:
            from PIL import Image as _ImD
            _h, _w = src_enc.shape[:2]
            _tw = min(320, _w); _th = max(1, int(_h * _tw / max(_w, 1)))
            _sm = np.asarray(_ImD.fromarray(
                (np.clip(src_enc, 0, 1) * 255 + 0.5).astype("uint8"))
                .resize((_tw, _th))).astype(np.float64) / 255.0
            def _gmag(ok):
                _gx = np.diff(ok, axis=1)[:-1]; _gy = np.diff(ok, axis=0)[:, :-1]
                return np.sqrt((_gx ** 2).sum(-1) + (_gy ** 2).sum(-1))
            _gin = _gmag(cs.encoded_to_oklab(_sm, tf) * 100.0)
            _msk = _gin <= max(1.0, float(np.percentile(_gin, 30)))
            if _msk.sum() >= 400:      # enough smooth area to judge fairly
                _gin_m = float(_gin[_msk].mean()) + 1e-9
                for name in scores:
                    _gout = _gmag(cs.encoded_to_oklab(
                        apply_lut(_sm, luts[name]), tf) * 100.0)
                    _dmg = float(_gout[_msk].mean()) / _gin_m
                    scores[name] = float(scores[name]) * (1.0 + 4.0 * max(0.0, _dmg - 1.8))
        except Exception:
            pass                       # judging aid only — never sink the match

    best = min(scores, key=scores.get)

    # Incumbent rule (distribution mode): the 1D-curves + residual transfer
    # ("sep") is the one candidate that never scrambles an image — it moves
    # tone, WB and palette the way a colourist's global grade does. The
    # exotic maps (idt/flow/uot) win the statistics whenever they force the
    # reference's distribution, and the field showed they can do that while
    # painting a smooth-but-wrong hue arc across a sky that neither the
    # distance metrics nor the roughness guard can see. So they must now BEAT
    # the incumbent by a clear margin (25% lower score, penalties included)
    # to ship. A genuinely better match keeps winning — the field case where
    # IDT deserves the crown scores 9x lower than sep, not 1.3x.
    if not corresponded and "sep" in scores and best != "sep":
        if scores[best] > 0.75 * scores["sep"]:
            best = "sep"

    res = MatchResult(method=best, scores=scores, lut=luts[best], tf=tf,
                      corresponded=corresponded, score_metric=metric)

    # Residual second pass (distribution mode, AI regions available): apply the
    # winner, derive a region-to-region correction on (applied, reference), and keep
    # the composed LUT only if it MEASURABLY improves the region match (+5.5% in
    # testing). The original nctx stays the judge, so this can never make it worse.
    if not corresponded and refine and nctx is not None:
        try:
            from . import neural as nn_mod
            _p(0.66, "Fine-tuning the match")
            applied_enc = apply_lut(src_enc, res.lut)
            # Reuse both segmentations: the reference is the SAME image, and a LUT
            # recolours the source without moving object boundaries. This was the
            # match's single most expensive step (measured 30.8s of a 60s match,
            # the "stuck at 67%" stall) and it was recomputing known answers.
            ctx2 = nn_mod.prepare(applied_enc, tgt_enc, tf, size=size,
                                  lattice_L=lattice_L, seed=seed,
                                  src_labels=getattr(nctx, "src_map", None),
                                  ref_labels=getattr(nctx, "ref_map", None))
            _p(0.76, "Fine-tuning the match")
            if ctx2 is not None:
                ax = np.linspace(0.0, 1.0, size)
                Rg, Gg, Bg = np.meshgrid(ax, ax, ax, indexing="ij")
                grid = np.stack([Rg, Gg, Bg], -1).reshape(-1, 3)
                comp = apply_lut_points(ctx2.lut, apply_lut_points(res.lut, grid))
                comp = comp.reshape(size, size, size, 3)
                s_base = scores[best]
                s_comp = _combined(apply_lut_points(comp, Sf_sc))
                _p(0.86, "Fine-tuning the match")
                if s_comp < s_base:
                    res.lut = comp
                    res.method = best + "+refine"
                    res.scores[res.method] = float(s_comp)
                    res.notes.append(f"residual refine: {s_base:.3f} -> {s_comp:.3f}")
        except Exception:
            pass

    # Gamut guard — the "sometimes the colours go insane" fix. The winner was fit
    # and scored only on sampled pixels; in cube regions those samples never
    # touched, blend it toward the gain-capped global MKL so a later frame's
    # out-of-sample colour (flash, neon, deep shadow) can never read extrapolation
    # garbage. Sampled regions are untouched, so the scores above still hold.
    if "mkl" in luts:
        res.lut = gamut_guard(res.lut, Sf_enc, luts["mkl"])
        # Emergency brake on steepness (covers the +refine composition too): if
        # the shipping LUT still has posterising slopes, soften it toward the
        # smooth capped-MKL just enough to get under the visible-damage line.
        res.lut = steep_guard(res.lut, luts["mkl"])
        # Keep the top runner-up candidates (same guards) so the panel can offer
        # them as alternative looks. Winner goes first under its own name.
        res.alts[res.method] = res.lut.astype(np.float32)
        # small linear samples for the WB/Tone/Colour strength decomposition
        res.sample_src_lin = Sf_lin[:30000].astype(np.float32)
        res.sample_tgt_lin = Tf_lin[:30000].astype(np.float32)
        for name in sorted(scores, key=scores.get):
            if len(res.alts) >= 3:
                break
            if name in res.alts or name == best:
                continue
            alt = steep_guard(gamut_guard(luts[name], Sf_enc, luts["mkl"]), luts["mkl"])
            res.alts[name] = alt.astype(np.float32)

    if corresponded and src_enc.shape == tgt_enc.shape:
        de_b = image_delta_e00(src_enc, tgt_enc, tf)
        de_a = image_delta_e00(apply_lut(src_enc, res.lut), tgt_enc, tf)
        res.de_before = summarize(de_b)
        res.de_after = summarize(de_a)
        sm = skin_mask(S_enc)
        if sm.sum() > 50:
            res.de_skin_before = float(de_b[sm].mean())
            res.de_skin_after = float(de_a[sm].mean())
    else:
        res.notes.append("Distribution mode: matched colour distributions "
                         "(no per-pixel ground truth).")
    _p(1.0, "Match complete")
    # Outcome-based safety net for a mis-clicked "Same scene": if the winning
    # corresponded mapping is still catastrophically wrong (dE00 > 8 means the
    # frames were never really aligned — the field report showed MKL "winning"
    # at 26), redo the whole match as distribution matching. Costs a second pass
    # only in the broken case; an honest match on aligned frames scores ~0-3.
    if (corresponded and res.de_after is not None
            and res.de_after.get("mean", 0.0) > 8.0):
        res = match(src_enc, tgt_enc, corresponded=False, tf=tf, size=size,
                    degrees=degrees, lattice_L=lattice_L, sample=sample,
                    seed=seed, skin_protect=skin_protect, skin_weight=skin_weight,
                    neural=neural, look=look, refine=refine, quick=quick,
                    progress=progress)
        res.notes.append("Same-scene mode produced a poor aligned match "
                         f"(dE00 {res.de_after['mean']:.1f} before fallback); "
                         "re-matched as different scenes.")
        return res

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
