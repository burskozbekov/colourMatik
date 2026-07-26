"""Optional LOCAL-AI colour matching.

A semantic-segmentation neural net (SegFormer, trained on ADE20K's 150 scene
classes: sky, person/skin, tree, grass, road, water, building, …) *understands*
each scene. We use that understanding to fix the classic failure of whole-frame
matching: when two shots have different content proportions (lots of sky in one,
little in the other), global statistics drag the wrong colours around.

The AI's job here is to REMOVE that bias: we build class-balanced sample sets —
each scene region contributes in matched proportion, sky paired with sky, skin
with skin — and then run the SAME smooth distribution transport (IDT) the
classical path uses. So the result is artifact-free and flicker-free (one smooth
global LUT), just aimed correctly. The engine still scores it against the maths
methods region-by-region and keeps whichever is most accurate.

Everything degrades gracefully: if torch / transformers / the model download
aren't available, prepare() returns None and the caller falls back to maths.
Runs on the Mac GPU (Metal / MPS) when present.
"""
from __future__ import annotations
import threading
import numpy as np

from . import colorspace as cs
from . import transforms as tf_mod
from .lut import resample_lut

# Primary: EoMT (CVPR 2025) — MIT code AND weights (DINOv2 backbone, Apache-2.0),
# so it is safe to use in a distributed tool, and its ADE20K masks measure better
# than SegFormer-B0's. Fallback: the old NVIDIA SegFormer (its weights carry a
# research-only license, so it is only used when EoMT can't load — old installs,
# no download). Both are ADE20K/150-class, so the region-matching logic is
# identical either way.
_EOMT_NAME = "tue-mps/ade20k_semantic_eomt_large_512"
_SEGFORMER_NAME = "nvidia/segformer-b0-finetuned-ade-512-512"
_SEG = None            # cached (model, processor, device) or False if unavailable
_SEG_LOCK = threading.Lock()   # serialize lazy load + shared-model inference (FastAPI threadpool)


def available() -> bool:
    return _load_seg() is not None


def loaded_nowait() -> bool:
    """True only if the model is usable RIGHT NOW, without waiting.

    While the startup warmup downloads EoMT (~1.2GB) it holds _SEG_LOCK; a match
    calling _load_seg() then would block on that lock for minutes — the exact
    frozen-bar stall the warmup exists to prevent. This check never blocks: if a
    load is in flight, the caller just skips the AI candidate for this match."""
    if _SEG is not None:
        return _SEG is not False
    if _SEG_LOCK.acquire(blocking=False):        # nothing loading -> load now
        _SEG_LOCK.release()
        return _load_seg() is not None
    return False                                  # warmup in flight -> skip


def _load_seg():
    global _SEG
    if _SEG is not None:
        return _SEG if _SEG is not False else None
    with _SEG_LOCK:                                # avoid a double-load race
        if _SEG is not None:
            return _SEG if _SEG is not False else None
        import_error = True
        try:
            import torch
            from transformers import AutoImageProcessor, AutoModelForUniversalSegmentation
            # Apple GPU, else an NVIDIA GPU (Windows/Linux), else the CPU.
            device = ("mps" if torch.backends.mps.is_available()
                      else "cuda" if torch.cuda.is_available() else "cpu")
            try:
                proc = AutoImageProcessor.from_pretrained(_EOMT_NAME)
                model = AutoModelForUniversalSegmentation.from_pretrained(_EOMT_NAME)
            except Exception:
                # EoMT unavailable (old transformers / download blocked) -> SegFormer
                from transformers import (SegformerImageProcessor,
                                          SegformerForSemanticSegmentation)
                proc = SegformerImageProcessor.from_pretrained(_SEGFORMER_NAME)
                model = SegformerForSemanticSegmentation.from_pretrained(_SEGFORMER_NAME)
            model.to(device).eval()
            _SEG = (model, proc, device)
        except Exception:
            _SEG = False
            return None
    return _SEG


def _to_u8(enc: np.ndarray) -> np.ndarray:
    return (np.clip(enc, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)


def _segment(enc: np.ndarray) -> np.ndarray | None:
    """enc: (H,W,3) display-encoded float [0,1] -> (H,W) int label map, or None."""
    seg = _load_seg()
    if seg is None:
        return None
    import torch
    from PIL import Image
    model, proc, device = seg
    img = Image.fromarray(_to_u8(enc))
    # Always segment at a MODEST resolution. We only use the masks to pool colours
    # per region, so 640px on the long side is plenty — and the models themselves
    # work at 512. Feeding multi-megapixel stacks (7 pooled frames!) cost seconds
    # per call in preprocessing and in the post-process upscale, for no gain.
    long_side = 640 if device != "cpu" else 448
    full_hw = (enc.shape[0], enc.shape[1])
    if max(img.size) > long_side:
        s = long_side / max(img.size)
        img = img.resize((max(1, int(img.width * s)), max(1, int(img.height * s))))
    small_hw = (img.height, img.width)

    def _run(dev):
        inputs = proc(images=img, return_tensors="pt").to(dev)
        with torch.no_grad():
            outputs = model(**inputs)
        # Works for both EoMT and SegFormer processors.
        seg_map = proc.post_process_semantic_segmentation(
            outputs, target_sizes=[small_hw])[0]
        lab = seg_map.detach().to("cpu").numpy().astype(np.int32)
        if lab.shape != full_hw:      # nearest-neighbour back to the frame grid
            lab = np.asarray(Image.fromarray(lab.astype(np.int32), mode="I")
                             .resize((full_hw[1], full_hw[0]), Image.NEAREST),
                             dtype=np.int32)
        return lab

    with _SEG_LOCK:                                   # serialize inference on the shared model
        try:
            return _run(device)
        except Exception:                             # e.g. an MPS-unsupported op -> retry on CPU
            if device == "cpu":
                return None
            try:
                model.to("cpu")
                return _run("cpu")
            except Exception:
                return None
            finally:
                model.to(device)


class NeuralResult:
    """The AI candidate LUT + a region-aware scorer for the engine's comparison."""

    def __init__(self, lut, src_labels_flat, ref_by_class_lab, tf, min_px,
                 src_map=None, ref_map=None):
        self.lut = lut                              # (size,size,size,3) smooth LUT
        self.src_labels = src_labels_flat           # (H*W,) class id per source pixel
        self.src_map = src_map                      # (H,W) label maps, reusable by
        self.ref_map = ref_map                      # the refine pass (see prepare)
        self.ref_lab = ref_by_class_lab             # {class: (n,3) ref Lab pixels}
        self.tf = tf
        self.min_px = min_px

    def semantic_distance(self, applied_enc: np.ndarray, idx: np.ndarray) -> float:
        """How well `applied_enc` (source after a candidate LUT, sampled at `idx`)
        matches the reference REGION BY REGION: size-weighted mean per-class Lab
        Wasserstein. Lower = better. Measured on the ACTUAL LUT output, so it
        reflects what the .cube really delivers."""
        from .metrics import sliced_wasserstein
        labs = cs.encoded_to_lab(np.clip(applied_enc, 0, 1), self.tf)
        lbl = self.src_labels[idx]
        total_w, total = 0.0, 0.0
        for c, ref_lab in self.ref_lab.items():
            m = lbl == c
            if m.sum() < self.min_px:
                continue
            w = float(min(m.sum(), ref_lab.shape[0]))
            total += w * sliced_wasserstein(labs[m], ref_lab, seed=0)
            total_w += w
        if total_w == 0:                            # no shared regions -> global
            all_ref = np.concatenate(list(self.ref_lab.values()), 0)
            return sliced_wasserstein(labs, all_ref, seed=0)
        return total / total_w


def prepare(src_enc: np.ndarray, tgt_enc: np.ndarray, tf: str, *,
            size: int = 65, lattice_L: int = 25, min_px: int = 1500,
            per_class_cap: int = 20000, seed: int = 0,
            src_labels=None, ref_labels=None) -> "NeuralResult | None":
    """Segment both frames, build class-balanced source/reference samples, and bake
    a smooth global LUT from an IDT transport of those samples. Returns a
    NeuralResult, or None if the AI model isn't available.

    `src_labels`/`ref_labels` let a caller pass segmentations it already has. The
    refine pass re-runs prepare() on (matched source, SAME reference): the
    reference segmentation is bit-identical to the one just computed, and a LUT
    only recolours the source — it never moves object boundaries — so reusing
    both maps is exact for the reference and faithful for the source, and it
    halves the AI cost of a match."""
    if src_labels is None:
        src_labels = _segment(src_enc)
    if ref_labels is None:
        ref_labels = _segment(tgt_enc)
    if src_labels is None or ref_labels is None:
        return None

    S_enc = src_enc.reshape(-1, 3)
    T_enc = tgt_enc.reshape(-1, 3)
    S_lin = cs.decode(S_enc, tf)
    T_lin = cs.decode(T_enc, tf)
    src_lbl = src_labels.reshape(-1)
    ref_lbl = ref_labels.reshape(-1)
    rng = np.random.default_rng(seed)

    # reference Lab per class (for region-aware scoring later)
    ref_lab = {}
    for c in np.unique(ref_lbl):
        m = ref_lbl == c
        if m.sum() >= min_px:
            ref_lab[int(c)] = cs.encoded_to_lab(T_enc[m], tf)

    # class-balanced paired samples: each shared region contributes equally from
    # BOTH clips, so the transport isn't dominated by whichever scene has more sky.
    S_bal, R_bal = [], []
    for c in ref_lab:                               # classes present in the reference
        sm = np.where(src_lbl == c)[0]
        rm = np.where(ref_lbl == c)[0]
        if sm.size < min_px or rm.size < min_px:
            continue
        k = min(sm.size, rm.size, per_class_cap)
        S_bal.append(S_lin[rng.choice(sm, k, replace=False)])
        R_bal.append(T_lin[rng.choice(rm, k, replace=False)])

    if not S_bal:                                   # no shared regions -> no AI edge
        return None
    # add a modest global spread so colours in unmatched regions still map sensibly
    # (separate caps: source and reference may differ in pixel count)
    gs = min(S_lin.shape[0], 20000)
    gr = min(T_lin.shape[0], 20000)
    S_bal.append(S_lin[rng.choice(S_lin.shape[0], gs, replace=False)])
    R_bal.append(T_lin[rng.choice(T_lin.shape[0], gr, replace=False)])
    S_bal = np.concatenate(S_bal, 0)
    R_bal = np.concatenate(R_bal, 0)

    # smooth transport (identical machinery to the classical 'idt' method -> no artifacts)
    transported = np.clip(tf_mod.fit_idt(S_bal, R_bal, seed=seed), 0.0, None)
    lat = tf_mod.fit_lut_lattice(cs.encode(S_bal, tf), cs.encode(transported, tf),
                                 L=lattice_L)
    lut = resample_lut(lat, size)
    return NeuralResult(lut, src_lbl, ref_lab, tf, min_px,
                        src_map=src_labels, ref_map=ref_labels)
