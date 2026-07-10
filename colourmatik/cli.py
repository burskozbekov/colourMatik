"""colourMatik CLI:  colourmatik SOURCE REFERENCE -o out.cube

SOURCE    = the clip/frame to be recoloured  (your "video 2")
REFERENCE = the clip/frame to match its colours TO  (your "video 1")
"""
from __future__ import annotations
import argparse
from pathlib import Path

from . import io as cmio
from .match import match, format_report
from .lut import write_cube, apply_lut
from .viz import make_comparison
from .metrics import image_delta_e00, summarize


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="colourmatik", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("source", help="clip/frame to recolour (video 2)")
    p.add_argument("reference", help="clip/frame to match to (video 1)")
    p.add_argument("-o", "--out", default="colourMatik.cube", help="output .cube LUT")
    p.add_argument("--tf", default="sRGB", help="transfer function: sRGB | Rec709 | BT1886")
    p.add_argument("--size", type=int, default=65, help="3D LUT size (default 65)")
    p.add_argument("--distribution", action="store_true",
                   help="different scenes / no shared content (distribution match)")
    p.add_argument("--no-skin", action="store_true",
                   help="disable skin-tone protection (on by default)")
    p.add_argument("--frames", type=int, default=3,
                   help="frames to pool from each video for fitting (default 3)")
    p.add_argument("--src-time", type=float, default=None, help="seconds into SOURCE video")
    p.add_argument("--ref-time", type=float, default=None, help="seconds into REFERENCE video")
    p.add_argument("--preview", default=None,
                   help="write a before/after montage PNG (default: <out>.preview.png)")
    p.add_argument("--no-preview", action="store_true", help="skip the preview image")
    args = p.parse_args(argv)

    src = cmio.load_any(args.source, args.src_time, frames=args.frames)
    ref = cmio.load_any(args.reference, args.ref_time, frames=args.frames)

    res = match(src, ref, corresponded=not args.distribution, tf=args.tf,
                size=args.size, skin_protect=not args.no_skin)
    title = f"colourMatik {Path(args.source).stem}->{Path(args.reference).stem}"
    write_cube(args.out, res.lut, title=title)

    print(format_report(res))
    print(f"  wrote LUT     : {args.out}  ({args.size}^3, .cube)")

    if not args.no_preview:
        # single representative frames -> clean montage regardless of --frames
        src1 = cmio.load_any(args.source, args.src_time, frames=1)
        ref1 = cmio.load_any(args.reference, args.ref_time, frames=1)
        matched1 = apply_lut(src1, res.lut)
        db = da = None
        corresponded = not args.distribution
        if corresponded and src1.shape == ref1.shape:
            db = summarize(image_delta_e00(src1, ref1, args.tf))["mean"]
            da = summarize(image_delta_e00(matched1, ref1, args.tf))["mean"]
        prev = args.preview or (str(Path(args.out).with_suffix("")) + ".preview.png")
        make_comparison(ref1, src1, matched1, prev, db, da, show_error=corresponded, tf=args.tf)
        print(f"  wrote preview : {prev}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
