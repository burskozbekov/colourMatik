"""colourMatik local web app — drag two clips, match colours, download the .cube.

Run:  ./.venv/bin/python -m colourmatik.webapp      (then open http://localhost:8765)
Everything stays on your machine; nothing is uploaded anywhere.
"""
from __future__ import annotations
import base64
import shutil
import tempfile
import uuid
from pathlib import Path

from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import HTMLResponse, JSONResponse, FileResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

import base64 as _b64
import threading
import traceback
from . import __version__
import numpy as np
from . import io as cmio
from . import colorspace as cs
from .match import match, format_report
from .lut import write_cube, apply_lut, apply_lut_points, apply_intensity, resample_lut
from .viz import make_comparison
from .metrics import image_delta_e00, summarize

app = FastAPI(title="colourMatik")
# UXP panels (and any local caller) fetch this server cross-origin.
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"],
                   allow_headers=["*"])
WORK = Path(tempfile.gettempdir()) / "colourmatik_web"
WORK.mkdir(exist_ok=True)
_RESULTS: dict[str, Path] = {}
_JOBS: dict[str, dict] = {}  # rid -> {lut, tf, src1, ref1, corresponded} for live re-baking
_LOCK = threading.Lock()     # serialize LUT-folder writes (avoid concurrent-write races)
_MAX_CACHE = 32              # cap the in-memory caches — each job holds a LUT + frames (~MBs)


def _remember(rid: str, cube: Path, job: dict | None = None) -> None:
    """Store a match's result + evict the oldest so memory AND disk can't grow
    unbounded (each match holds a LUT + frames in RAM and a WORK/<uuid> dir on disk)."""
    with _LOCK:
        _RESULTS[rid] = cube
        if job is not None:
            _JOBS[rid] = job
        while len(_RESULTS) > _MAX_CACHE:
            old_rid, old_cube = next(iter(_RESULTS.items()))
            _RESULTS.pop(old_rid, None)
            try:                                    # delete the evicted match's WORK dir
                d = Path(old_cube).parent
                if d.parent == WORK and d.exists():
                    shutil.rmtree(d, ignore_errors=True)
            except Exception:
                pass
        while len(_JOBS) > _MAX_CACHE:
            _JOBS.pop(next(iter(_JOBS)), None)

# Premiere scans these at launch; we drop the LUT here so it shows in the
# Lumetri Input-LUT / Creative-Look dropdowns (folder names drift across installs).
_LUT_DIRS = [
    Path.home() / "Library/Application Support/Adobe/Common/LUTs/Creative",
    Path.home() / "Library/Application Support/Adobe/Common/LUTs/Technical",
    Path.home() / "Library/Application Support/Adobe/Common/LUTs/Input",
]


def _install_lut(lut, tf: str, name: str = "colourMatik") -> None:
    with _LOCK:
        for d in _LUT_DIRS:
            try:
                d.mkdir(parents=True, exist_ok=True)
                write_cube(d / f"{name}.cube", lut, title=name)
            except Exception:
                pass


# The native "colourMatik" effect reads its 33^3 LUT from a per-match "slot" file
# here. A NEW slot number each call is what makes the effect reload (it caches by
# slot), so the panel just points the effect's Slot param at the returned number.
_SLOT_DIR = Path.home() / "Library/Application Support/colourMatik"
_SLOT_COUNTER = _SLOT_DIR / ".next_slot"
_EFFECT_LUT_SIZE = 33  # must match CM_LUT_SIZE in the native effect


def _next_slot() -> int:
    with _LOCK:
        _SLOT_DIR.mkdir(parents=True, exist_ok=True)
        try:
            n = int(_SLOT_COUNTER.read_text().strip())
        except Exception:
            n = 0
        n = n % 99999 + 1  # cycle 1..99999; never 0 (0 = effect's "no LUT" default)
        try:
            _SLOT_COUNTER.write_text(str(n))
        except Exception:
            pass
        return n


_METHOD_LABELS = {
    "canon": "AI grade (CanonCGT)",
    "neural": "AI scene-match",
    "idt": "distribution (IDT)",
    "mkl": "linear (MKL)",
    "lattice": "3D lattice",
    "poly1": "linear fit", "poly2": "polynomial", "poly3": "polynomial",
}


def _method_label(m: str) -> str:
    return _METHOD_LABELS.get(m, m)


def _preview_dataurl(ref1, src1, matched1, tf, corresponded, job: Path) -> tuple[str, dict | None, dict | None]:
    db = da = None
    if corresponded and src1.shape == ref1.shape:
        db = summarize(image_delta_e00(src1, ref1, tf))["mean"]
        da = summarize(image_delta_e00(matched1, ref1, tf))["mean"]
    prev = job / "preview.png"
    make_comparison(ref1, src1, matched1, prev, db, da, show_error=corresponded, tf=tf)
    return "data:image/png;base64," + _b64.b64encode(prev.read_bytes()).decode(), db, da


def _save_upload(up: UploadFile, dst_dir: Path) -> Path:
    suffix = Path(up.filename or "clip").suffix or ".mp4"
    dst = dst_dir / f"in_{uuid.uuid4().hex}{suffix}"
    with dst.open("wb") as f:
        shutil.copyfileobj(up.file, f)
    return dst


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return PAGE


def _process(src_path: Path, ref_path: Path, mode: str, tf: str, frames: int,
             job: Path, title: str, look: str = "exact") -> dict:
    corresponded = (mode == "same")
    # Frame pooling (3 stacked frames) helps the classical distribution methods, but the
    # learned look-transfer (CanonCGT) analyses ONE coherent image — give it a single frame.
    f = 1 if look == "ai_grade" else frames
    src = cmio.load_any(src_path, frames=f)
    ref = cmio.load_any(ref_path, frames=f)
    res = match(src, ref, corresponded=corresponded, tf=tf, look=look)

    cube = job / "colourMatik.cube"
    write_cube(cube, res.lut, title=title)
    _install_lut(res.lut, tf)  # expose in Premiere LUT dropdowns (visible after next launch)

    src1 = cmio.load_any(src_path, frames=1)
    ref1 = cmio.load_any(ref_path, frames=1)
    matched1 = apply_lut(src1, res.lut)
    preview, db, da = _preview_dataurl(ref1, src1, matched1, tf, corresponded, job)

    rid = uuid.uuid4().hex
    _remember(rid, cube, {"lut": res.lut, "tf": tf, "src1": src1, "ref1": ref1,
                          "corresponded": corresponded})
    return {
        "ok": True,
        "rid": rid,
        "report": format_report(res),
        "method": res.method,
        "method_label": _method_label(res.method),
        "ai_used": res.method in ("neural", "canon"),
        "metric": res.score_metric,
        "scores": res.scores,
        "de_before": db,
        "de_after": da,
        "de_skin_after": res.de_skin_after,
        "corresponded": corresponded,
        "cube_path": str(cube),
        "preview": preview,
        "download": f"/download/{rid}",
    }


@app.post("/match")
def do_match(source: UploadFile = File(...), reference: UploadFile = File(...),
             mode: str = Form("different"), tf: str = Form("sRGB"),
             frames: int = Form(3)):
    job = WORK / uuid.uuid4().hex
    job.mkdir(parents=True, exist_ok=True)
    try:
        src_path = _save_upload(source, job)
        ref_path = _save_upload(reference, job)
        return JSONResponse(_process(src_path, ref_path, mode, tf, frames, job,
                                     f"colourMatik {Path(source.filename).stem}"))
    except Exception as e:
        traceback.print_exc()
        return JSONResponse({"ok": False, "error": f"{type(e).__name__}: {e}"}, status_code=400)


class PathReq(BaseModel):
    source_path: str
    reference_path: str
    mode: str = "different"
    tf: str = "sRGB"
    frames: int = 3
    look: str = "exact"        # "exact" = accuracy contest; "ai_grade" = CanonCGT look


@app.post("/match_paths")
def match_paths(req: PathReq):
    """Match by on-disk file paths — used by the Premiere UXP panel (which sends the
    selected clips' media paths). Reads files directly; nothing is uploaded."""
    job = WORK / uuid.uuid4().hex
    job.mkdir(parents=True, exist_ok=True)
    try:
        src = Path(req.source_path)
        ref = Path(req.reference_path)
        if not src.exists() or not ref.exists():
            return JSONResponse({"ok": False, "error": "file not found"}, status_code=400)
        return JSONResponse(_process(src, ref, req.mode, req.tf, req.frames, job,
                                     f"colourMatik {src.stem}", look=req.look))
    except Exception as e:
        traceback.print_exc()
        return JSONResponse({"ok": False, "error": f"{type(e).__name__}: {e}"}, status_code=400)


class BakeReq(BaseModel):
    rid: str
    intensity: float = 1.0  # 1.0 = full match; panel maps 0..150% -> 0..1.5


@app.post("/bake")
def bake(req: BakeReq):
    """Re-bake a prior match at a new intensity: updates the preview live and
    rewrites the .cube (+ LUT dropdowns). intensity<1 weaker, >1 stronger."""
    j = _JOBS.get(req.rid)
    if j is None:
        return JSONResponse({"ok": False, "error": "unknown rid"}, status_code=404)
    try:
        baked = apply_intensity(j["lut"], float(req.intensity))
        job = WORK / uuid.uuid4().hex
        job.mkdir(parents=True, exist_ok=True)
        cube = job / "colourMatik.cube"
        write_cube(cube, baked, title=f"colourMatik {int(round(req.intensity * 100))}%")
        _install_lut(baked, j["tf"])
        matched = apply_lut(j["src1"], baked)
        preview, _db, da = _preview_dataurl(j["ref1"], j["src1"], matched, j["tf"],
                                            j["corresponded"], job)
        rid2 = uuid.uuid4().hex
        _remember(rid2, cube)
        return JSONResponse({"ok": True, "download": f"/download/{rid2}",
                             "cube_path": str(cube), "preview": preview, "de_after": da})
    except Exception as e:
        traceback.print_exc()
        return JSONResponse({"ok": False, "error": f"{type(e).__name__}: {e}"}, status_code=400)


def _decompose_lut(lut, tf: str) -> dict:
    """Project the match LUT onto settable Lumetri sliders (WB + exposure + contrast
    + saturation), computed in linear light by probing the LUT."""
    eps = 1e-4
    # neutral grey ramp -> per-channel gains
    greys = np.linspace(0.10, 0.90, 9)[:, None] * np.ones((1, 3))
    lin_in = cs.decode(greys, tf)
    lin_out = cs.decode(apply_lut_points(lut, greys), tf)
    k = np.array([np.median(lin_out[:, c] / np.maximum(lin_in[:, c], eps)) for c in range(3)])
    k = np.maximum(k, eps)
    g = float(np.exp(np.mean(np.log(k))))            # overall gain (geometric mean)
    r = k / g                                        # per-channel white-balance ratio (∏r=1)

    exposure = float(np.clip(np.log2(max(g, eps)), -4, 4))
    FW = 130.0                                       # WB scale -> Lumetri -100..100 (calibrated)
    temperature = float(np.clip(FW * (np.log(r[0]) - np.log(r[2])) / 2.0, -100, 100))
    tint = float(np.clip(FW * (np.log(r[1]) - (np.log(r[0]) + np.log(r[2])) / 2.0), -100, 100))

    # contrast from the neutral tone slope (log-log), 0 for a pure gain
    lg_in = np.log(np.maximum(lin_in.mean(1), eps))
    lg_out = np.log(np.maximum(lin_out.mean(1) / g, eps))
    slope = float(np.polyfit(lg_in, lg_out, 1)[0])
    contrast = float(np.clip(60.0 * (slope - 1.0), -100, 100))

    # saturation from probing saturated primaries/secondaries
    prim = np.array([[.75, .15, .15], [.15, .75, .15], [.15, .15, .75],
                     [.75, .75, .15], [.15, .75, .75], [.75, .15, .75]])
    pin = cs.decode(prim, tf)
    pout = cs.decode(apply_lut_points(lut, prim), tf)
    chroma = lambda x: float(np.mean(np.linalg.norm(x - x.mean(1, keepdims=True), axis=1)))
    saturation = float(np.clip(100.0 * chroma(pout) / max(chroma(pin), eps), 0, 200))

    return {"Exposure": round(exposure, 3), "Temperature": round(temperature, 1),
            "Tint": round(tint, 1), "Contrast": round(contrast, 1),
            "Saturation": round(saturation, 1)}


@app.post("/decompose")
def decompose(req: BakeReq):
    """Return the match as settable Lumetri slider values (auto-applied by the panel,
    no dropdown). intensity scales the deltas from neutral."""
    j = _JOBS.get(req.rid)
    if j is None:
        return JSONResponse({"ok": False, "error": "unknown rid"}, status_code=404)
    try:
        base = _decompose_lut(j["lut"], j["tf"])
        return {"ok": True, "params": base}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse({"ok": False, "error": f"{type(e).__name__}: {e}"}, status_code=400)


class EffectLutReq(BaseModel):
    rid: str
    intensity: float = 1.0  # baked at full strength by default; the effect's own
    #                         Intensity slider does the live dialing, so leave at 1.0


@app.post("/effect_lut")
def effect_lut(req: EffectLutReq):
    """Write the match as a 33^3 .cube into a fresh slot the native colourMatik
    effect reads. Returns the slot number for the panel to set on the effect."""
    j = _JOBS.get(req.rid)
    if j is None:
        return JSONResponse({"ok": False, "error": "unknown rid"}, status_code=404)
    try:
        lut = j["lut"]
        if req.intensity != 1.0:
            lut = apply_intensity(lut, float(req.intensity))
        lut33 = resample_lut(lut, _EFFECT_LUT_SIZE)
        slot = _next_slot()
        path = _SLOT_DIR / f"slot_{slot}.cube"
        write_cube(path, lut33, title=f"colourMatik slot {slot}")
        return {"ok": True, "slot": slot, "path": str(path)}
    except Exception as e:
        traceback.print_exc()
        return JSONResponse({"ok": False, "error": f"{type(e).__name__}: {e}"}, status_code=400)


@app.get("/version")
def version():
    return {"name": "colourMatik", "version": __version__}


@app.get("/download/{rid}")
def download(rid: str):
    path = _RESULTS.get(rid)
    if not path or not path.exists():
        return JSONResponse({"error": "not found"}, status_code=404)
    return FileResponse(path, filename="colourMatik.cube", media_type="text/plain")


PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>colourMatik</title>
<style>
:root{--bg:#0e0f13;--card:#171922;--line:#262a36;--fg:#e8eaf0;--mut:#9aa3b2;--acc:#5b8cff;--good:#39d98a}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.wrap{max-width:1040px;margin:0 auto;padding:32px 20px 80px}
h1{font-size:26px;margin:0 0 2px;letter-spacing:.3px}
h1 b{color:var(--acc)}.sub{color:var(--mut);margin:0 0 26px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}
.drop{background:var(--card);border:1.5px dashed var(--line);border-radius:14px;padding:22px;
text-align:center;cursor:pointer;transition:.15s}
.drop:hover,.drop.hot{border-color:var(--acc);background:#1b1e2b}
.drop .t{font-weight:600}.drop .h{color:var(--mut);font-size:13px;margin-top:4px}
.drop .f{margin-top:10px;color:var(--good);font-size:13px;word-break:break-all;min-height:18px}
.tag{display:inline-block;font-size:12px;color:var(--mut);border:1px solid var(--line);
border-radius:999px;padding:2px 10px;margin-bottom:8px}
.opts{display:flex;gap:20px;flex-wrap:wrap;align-items:center;margin:22px 0}
.opts label{color:var(--mut);cursor:pointer}.opts input{accent-color:var(--acc);margin-right:6px}
button.go{background:var(--acc);color:#fff;border:0;border-radius:12px;padding:13px 26px;
font-size:16px;font-weight:600;cursor:pointer}button.go:disabled{opacity:.5;cursor:default}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:20px;margin-top:22px}
.hidden{display:none}.row{display:flex;gap:26px;flex-wrap:wrap;align-items:center;margin-bottom:14px}
.stat .n{font-size:30px;font-weight:700}.stat.good .n{color:var(--good)}
.stat .l{color:var(--mut);font-size:12px}
img.prev{width:100%;border-radius:10px;border:1px solid var(--line)}
pre{background:#0b0c10;border:1px solid var(--line);border-radius:10px;padding:14px;overflow:auto;
color:var(--mut);font-size:12.5px}
a.dl{display:inline-block;background:var(--good);color:#062;border-radius:12px;padding:12px 22px;
font-weight:700;text-decoration:none;margin-top:6px}
.note{color:var(--mut);font-size:13px;margin-top:14px;line-height:1.7}
.spin{width:20px;height:20px;border:3px solid #fff5;border-top-color:#fff;border-radius:50%;
display:inline-block;vertical-align:-4px;margin-right:8px;animation:s .7s linear infinite}
@keyframes s{to{transform:rotate(360deg)}}
</style></head><body><div class="wrap">
<h1><b>colour</b>Matik</h1>
<p class="sub">Match your source clip's colours to a reference. Measured accuracy (ΔE00), fully on your machine.</p>
<div class="grid">
  <div><span class="tag">REFERENCE — THE LOOK TO COPY</span>
    <div class="drop" id="dropRef"><div class="t">Reference clip</div>
    <div class="h">The clip whose colours we sample</div><div class="f" id="fRef"></div>
    <input type="file" id="inRef" accept="video/*,image/*" class="hidden"></div></div>
  <div><span class="tag">SOURCE — RECOLOUR THIS</span>
    <div class="drop" id="dropSrc"><div class="t">Source clip</div>
    <div class="h">The clip we recolour</div><div class="f" id="fSrc"></div>
    <input type="file" id="inSrc" accept="video/*,image/*" class="hidden"></div></div>
</div>
<div class="opts">
  <span style="color:var(--mut)">These two clips are:</span>
  <label><input type="radio" name="mode" value="different" checked>Different scene</label>
  <label><input type="radio" name="mode" value="same">Same scene (aligned)</label>
</div>
<button class="go" id="go" disabled>Match Colours</button>
<div class="card hidden" id="result"></div>
<div style="margin-top:28px;text-align:center;color:var(--mut);font-size:12px;border-top:1px solid var(--line);padding-top:16px">
  by <b style="color:var(--fg)">Sevki Bugra Ozbek</b> · <a href="https://catheadai.com" style="color:var(--acc);text-decoration:none">catheadai.com</a>
</div>
<script>
const $=s=>document.querySelector(s);let fRef=null,fSrc=null;
function wire(drop,input,label,set){const d=$(drop),i=$(input);
 d.onclick=()=>i.click();
 d.ondragover=e=>{e.preventDefault();d.classList.add('hot')};
 d.ondragleave=()=>d.classList.remove('hot');
 d.ondrop=e=>{e.preventDefault();d.classList.remove('hot');if(e.dataTransfer.files[0]){i.files=e.dataTransfer.files;pick()}};
 i.onchange=pick;
 function pick(){const f=i.files[0];if(f){$(label).textContent='✓ '+f.name;set(f);check()}}}
wire('#dropRef','#inRef','#fRef',f=>fRef=f);
wire('#dropSrc','#inSrc','#fSrc',f=>fSrc=f);
function check(){$('#go').disabled=!(fRef&&fSrc)}
$('#go').onclick=async()=>{
 const btn=$('#go');btn.disabled=true;btn.innerHTML='<span class=spin></span>Matching…';
 const r=$('#result');r.classList.remove('hidden');r.innerHTML='<p class=note>Extracting frames, choosing the best method…</p>';
 const fd=new FormData();fd.append('reference',fRef);fd.append('source',fSrc);
 fd.append('mode',document.querySelector('input[name=mode]:checked').value);
 try{const res=await fetch('/match',{method:'POST',body:fd});const j=await res.json();
  if(!j.ok){r.innerHTML='<p class=note style="color:#ff6b6b">Error: '+j.error+'</p>';}
  else{render(j);}
 }catch(e){r.innerHTML='<p class=note style="color:#ff6b6b">Error: '+e+'</p>';}
 btn.disabled=false;btn.textContent='Match Colours';
};
function render(j){const v=x=>x==null?'—':x.toFixed(2);
 const acc=j.de_after!=null?(j.de_after<2?'good':''):'';
 let stats=j.de_after!=null?`
   <div class="stat"><div class="n">${v(j.de_before)}</div><div class="l">BEFORE ΔE00</div></div>
   <div class="stat ${acc}"><div class="n">${v(j.de_after)}</div><div class="l">AFTER ΔE00 ${j.de_after<2?'(imperceptible)':''}</div></div>`
   :`<div class="stat"><div class="l">Distribution matched (method: ${j.method}). Cross-scene pixel-ΔE isn't defined — judge by the preview.</div></div>`;
 $('#result').innerHTML=`
   <div class="row">${stats}<div class="stat"><div class="n">${j.method}</div><div class="l">METHOD</div></div></div>
   <img class="prev" src="${j.preview}">
   <p class="note"><b>Next steps:</b><br>1) Download the <b>.cube</b> below.<br>
   2) In Premiere select your source clip → <b>Lumetri Color ▸ Basic Correction ▸ Input LUT ▸ Browse…</b> → pick this .cube.<br>
   3) The colours snap to the reference. Fine-tune on top if you like.</p>
   <a class="dl" href="${j.download}" download>⬇︎ Download colourMatik.cube</a>
   <details style="margin-top:16px"><summary style="color:var(--mut);cursor:pointer">Technical report</summary><pre>${j.report}</pre></details>`;
}
</script>
</div></body></html>"""


def run(host: str = "127.0.0.1", port: int = 8765):
    import uvicorn
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    run()
