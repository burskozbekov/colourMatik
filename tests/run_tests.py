"""Ground-truth accuracy + LUT-correctness tests for colourMatik.

Run:  ./.venv/bin/python -m tests.run_tests
"""
from __future__ import annotations
import sys
from pathlib import Path
import numpy as np
import colour

from colourmatik.colorspace import decode, encode
from colourmatik.match import match, format_report
from colourmatik.lut import build_lut, write_cube, apply_lut
from colourmatik import transforms as tf_mod
from tests import synth

OUT = Path(__file__).parent / "_out"
OUT.mkdir(exist_ok=True)
FAILS = []


def check(name, cond, detail=""):
    tag = "PASS" if cond else "FAIL"
    print(f"  [{tag}] {name}   {detail}")
    if not cond:
        FAILS.append(name)


def save(name, enc):
    from colourmatik.io import save_image
    save_image(OUT / name, enc)


def test_accuracy():
    print("\n=== 1. Ground-truth colour-match accuracy ===")
    ref = synth.build_reference()
    save("reference.png", ref)

    cases = {
        "linear": (synth.distort_linear, 1.0),      # affine -> expect near-perfect
        "nonlinear": (synth.distort_nonlinear, 2.0),  # tone+sat -> expect excellent
    }
    for cname, (distort, thresh) in cases.items():
        src = distort(ref)                 # simulated "video 2"
        save(f"{cname}_distorted.png", src)
        res = match(src, ref, corresponded=True, size=65)
        print(f"\n-- distortion: {cname} --")
        print(format_report(res))
        matched = apply_lut(src, res.lut)
        save(f"{cname}_matched.png", matched)

        b, a = res.de_before["mean"], res.de_after["mean"]
        check(f"{cname}: LUT accuracy mean dE00 < {thresh}", a < thresh, f"(got {a:.3f})")
        check(f"{cname}: improved >=5x", b / max(a, 1e-9) >= 5.0,
              f"(before {b:.2f} -> after {a:.3f}, {b/max(a,1e-9):.1f}x)")


def test_distribution():
    """Distribution mode: match WITHOUT using pixel correspondence.
    We still secretly have ground truth (same scene, known grade) so we can
    measure real dE00 even though the matcher only saw the two distributions."""
    print("\n=== 4. Distribution mode (no correspondence) ===")
    ref = synth.build_reference()
    src = synth.distort_nonlinear(ref)  # aligned GT exists, but matcher won't use it
    res = match(src, ref, corresponded=False, size=65)
    print(format_report(res))
    matched = apply_lut(src, res.lut)
    from colourmatik.metrics import image_delta_e00, summarize
    b = summarize(image_delta_e00(src, ref))["mean"]
    a = summarize(image_delta_e00(matched, ref))["mean"]
    print(f"  (ground-truth check) per-pixel dE00: before {b:.3f} -> after {a:.3f}")
    check("distribution: IDT beats/equals MKL", res.scores["idt"] <= res.scores["mkl"] + 1e-6,
          f"(idt {res.scores['idt']:.3f} vs mkl {res.scores['mkl']:.3f})")
    check("distribution: recolour improves real dE00 >=3x", b / max(a, 1e-9) >= 3.0,
          f"(before {b:.2f} -> after {a:.3f}, {b/max(a,1e-9):.1f}x)")


def test_skin():
    """Skin-tone protection: detection specificity + weighted fit lowers skin dE00."""
    print("\n=== 5. Skin-tone protection ===")
    from colourmatik.skin import skin_probability
    from colourmatik import transforms as tfm
    from colourmatik.colorspace import decode, encoded_to_lab
    from colourmatik.metrics import delta_e00

    ref, mask = synth.build_portrait()
    save("portrait_reference.png", ref)
    p = skin_probability(ref)
    face_p, bg_p = float(p[mask].mean()), float(p[~mask].mean())
    check("skin detected on face", face_p > 0.5, f"(face prob {face_p:.2f})")
    check("skin NOT on background", bg_p < 0.15, f"(bg prob {bg_p:.2f})")

    # Constrained model (poly1) so protection must trade off -> effect is visible.
    src = synth.distort_nonlinear(ref)
    S_lin, T_lin = decode(src).reshape(-1, 3), decode(ref).reshape(-1, 3)
    skin_p = skin_probability(src).reshape(-1)
    ref_lab = encoded_to_lab(ref).reshape(-1, 3)
    m = mask.reshape(-1)

    def skin_de(weights):
        f = tfm.fit_polynomial(S_lin, T_lin, degree=1, weights=weights)
        lut = build_lut(f, size=33)
        out_lab = encoded_to_lab(apply_lut(src, lut)).reshape(-1, 3)
        return float(delta_e00(out_lab[m], ref_lab[m]).mean())

    de_plain = skin_de(None)
    de_prot = skin_de(1.0 + 8.0 * skin_p)
    print(f"  skin dE00 (poly1):  unprotected {de_plain:.3f} -> protected {de_prot:.3f}")
    check("skin protection lowers skin dE00", de_prot < de_plain - 1e-3,
          f"({de_plain:.3f} -> {de_prot:.3f})")

    res = match(src, ref, corresponded=True, size=65, skin_protect=True)
    check("match reports skin accuracy", res.de_skin_after is not None,
          f"(skin dE00 {res.de_skin_after})")


def test_lut_correctness():
    print("\n=== 2. .cube correctness vs independent reader (colour-science) ===")
    ref = synth.build_reference()
    src = synth.distort_nonlinear(ref)

    # fit a real transform, bake to LUT, write .cube
    S = decode(src).reshape(-1, 3)
    T = decode(ref).reshape(-1, 3)
    f = tf_mod.fit_polynomial(S, T, degree=3)
    lut = build_lut(f, size=33)
    cube = OUT / "roundtrip.cube"
    write_cube(cube, lut, title="roundtrip")

    # intended transform, evaluated directly (ground truth for the LUT)
    out_direct = np.clip(encode(np.clip(f(decode(src.reshape(-1, 3))), 0, None)), 0, 1)

    # our own LUT application
    out_mine = apply_lut(src, lut).reshape(-1, 3)

    # independent, spec-correct reader applies the WRITTEN FILE
    lut3d = colour.io.read_LUT(str(cube))
    out_colour = np.clip(np.asarray(lut3d.apply(src)).reshape(-1, 3), 0, 1)

    d_mine = float(np.mean(np.abs(out_mine - out_direct)))
    d_colour = float(np.mean(np.abs(out_colour - out_direct)))
    d_cross = float(np.max(np.abs(out_mine - out_colour)))

    check("our apply matches intended transform", d_mine < 5e-3, f"(mean|d|={d_mine:.5f})")
    check("WRITTEN .cube (read by colour-science) matches intended transform",
          d_colour < 5e-3, f"(mean|d|={d_colour:.5f})  <- ordering/format proof")
    check("our apply == colour-science apply", d_cross < 5e-3, f"(max|d|={d_cross:.5f})")


def test_identity():
    print("\n=== 3. Identity LUT sanity ===")
    ref = synth.build_reference()
    ident = build_lut(lambda x: x, size=33)
    out = apply_lut(ref, ident)
    d = float(np.max(np.abs(out - ref)))
    check("identity transform LUT ~ passthrough", d < 5e-3, f"(max|d|={d:.5f})")


if __name__ == "__main__":
    test_accuracy()
    test_distribution()
    test_skin()
    test_lut_correctness()
    test_identity()
    print("\n" + ("=" * 48))
    if FAILS:
        print(f"FAILED: {len(FAILS)} -> {FAILS}")
        sys.exit(1)
    print("ALL TESTS PASSED")
