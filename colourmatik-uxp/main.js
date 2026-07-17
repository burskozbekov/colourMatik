/* colourMatik — Premiere Pro UXP panel.
 * Match the SOURCE clip's colours to a REFERENCE, apply Lumetri to the source,
 * and dial the strength with a live intensity slider.
 * Engine: local FastAPI at http://127.0.0.1:8765 (run ./colourmatik-app).
 */
const ppro = require("premierepro");
const uxp = require("uxp");

const SERVER = "http://127.0.0.1:8765";
const DEFAULT_INTENSITY = 100;   // 100 = the exact computed match; slider dials 0–200 live
const LOCAL_VERSION = "1.2.0";

/* fetch with a hard timeout — a wedged engine must never freeze the panel */
async function fetchT(url, opts, ms) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  try { return await fetch(url, { ...(opts || {}), signal: ctrl.signal }); }
  finally { clearTimeout(t); }
}
// Update checks read version.json straight from the GitHub repo (always hosted,
// CORS-friendly). Bump version.json + this constant together on each release.
const UPDATE_URL = "https://raw.githubusercontent.com/burskozbekov/colourMatik/main/version.json";
const SITE_URL = "https://catheadai.com";

const $ = (id) => document.getElementById(id);
const state = { refPath: null, srcPath: null, srcTrackItem: null, rid: null, slot: null,
                refIn: null, refOut: null, srcIn: null, srcOut: null };
let bakeTimer = null;

function setStatus(stateLabel, msg, kind) {
  $("status-state").textContent = stateLabel;
  $("status-msg").textContent = msg;
  $("status").className = kind || "idle";
}

function currentMode() {
  return $("mode-same").classList.contains("selected") ? "same" : "different";
}

function currentLook() {
  return $("look-ai").classList.contains("selected") ? "ai_grade" : "exact";
}

function refreshRun() {
  $("run").disabled = !(state.refPath && state.srcPath);
}

/* ---- Match & Apply loading bar (fed by the engine's /progress) ------------- */
let _progPoll = null, _progTick = null, _progReset = null, _dispPct = 0, _srvPct = 0, _srvMsg = "";
function _paintProg() {
  $("run-fill").style.width = (_dispPct * 100).toFixed(1) + "%";
  $("run-label").textContent = Math.round(_dispPct * 100) + "%" + (_srvMsg ? "  ·  " + _srvMsg : "");
}
function startProgress(jobId) {
  // defensively clear anything a previous run left behind (intervals must never orphan)
  if (_progPoll) clearInterval(_progPoll);
  if (_progTick) clearInterval(_progTick);
  if (_progReset) { clearTimeout(_progReset); _progReset = null; }
  _dispPct = 0; _srvPct = 0; _srvMsg = "Starting";
  $("run").classList.add("loading");
  let polling = false;                       // don't stack requests on a slow engine
  _progPoll = setInterval(async () => {
    if (polling) return;
    polling = true;
    try {
      const r = await fetchT(SERVER + "/progress/" + jobId, { cache: "no-cache" }, 4000);
      const j = await r.json();
      if (typeof j.pct === "number") { _srvPct = j.pct; if (j.msg) _srvMsg = j.msg; }
    } catch (e) {} finally { polling = false; }
  }, 500);
  // Smoothly ease toward the server value, and gently creep forward within a
  // stage so the bar never looks frozen during the long AI steps.
  _progTick = setInterval(() => {
    const soft = Math.min(0.97, _srvPct + 0.10);
    const target = Math.max(_srvPct, Math.min(soft, _dispPct + 0.006));
    _dispPct += (target - _dispPct) * 0.25;
    _paintProg();
  }, 120);
  _paintProg();
}
function stopProgress(done) {
  if (_progPoll) clearInterval(_progPoll);
  if (_progTick) clearInterval(_progTick);
  _progPoll = _progTick = null;
  if (done) { _dispPct = 1; _srvMsg = "Done"; _paintProg(); }
  if (_progReset) clearTimeout(_progReset);
  _progReset = setTimeout(() => {
    _progReset = null;
    $("run").classList.remove("loading");
    $("run-fill").style.width = "0%";
    $("run-label").textContent = "MATCH & APPLY";
  }, done ? 450 : 0);
}
function newJobId() {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

/* ---- Read the selected clip: timeline first (so we can grab the track item
 * for applying an effect AND its used in/out segment), then the bin (path only). */
async function getSelected() {
  const project = await ppro.Project.getActiveProject();
  if (!project) throw new Error("No project is open.");

  const seq = await project.getActiveSequence();
  if (seq) {
    const tsel = await seq.getSelection();
    const clips = tsel ? await tsel.getTrackItems() : [];
    for (const c of clips) {
      // Skip AUDIO track items of linked clips when the API can tell us — applying
      // a video effect to an audio component chain fails cryptically. When the
      // media-type API is unavailable, fall back to the old duck-typing unchanged.
      try {
        if (typeof c.getMediaType === "function" && ppro.Constants && ppro.Constants.MediaType
            && ppro.Constants.MediaType.AUDIO !== undefined) {
          const mt = await c.getMediaType();
          if (String(mt) === String(ppro.Constants.MediaType.AUDIO)) continue;
        }
      } catch (e) {}
      if (typeof c.getComponentChain === "function") {      // video clip on the timeline
        const pi = await c.getProjectItem();
        const clip = ppro.ClipProjectItem.cast(pi);
        const p = clip ? await clip.getMediaFilePath() : null;
        if (p) {
          // The segment actually used in the edit (source-media seconds). Long
          // source files hold many scenes — sampling only this range is what
          // makes the match reflect the shot you're grading.
          let inS = null, outS = null;
          try {
            const ti = await c.getInPoint();
            const to = await c.getOutPoint();
            if (ti && typeof ti.seconds === "number" && isFinite(ti.seconds)) inS = ti.seconds;
            if (to && typeof to.seconds === "number" && isFinite(to.seconds)) outS = to.seconds;
            if (inS != null && outS != null && outS - inS < 0.04) { inS = null; outS = null; }
          } catch (e) {}
          return { path: p, trackItem: c, inS, outS };
        }
      }
    }
  }
  const sel = await ppro.ProjectUtils.getSelection(project);
  const items = sel ? await sel.getItems() : [];
  for (const it of items) {
    const clip = ppro.ClipProjectItem.cast(it);
    if (clip) { const p = await clip.getMediaFilePath(); if (p) return { path: p, trackItem: null, inS: null, outS: null }; }
  }
  return { path: null, trackItem: null, inS: null, outS: null };
}

function baseName(p) { return p ? p.split(/[\\/]/).pop() : ""; }   // mac + windows paths

async function captureRef() {
  try {
    const s = await getSelected();
    if (!s.path) return setStatus("SELECT", "Select the reference clip (bin or timeline), then click again.", "error");
    state.refPath = s.path;
    state.refIn = s.inS; state.refOut = s.outS;
    $("refName").textContent = baseName(s.path);
    $("refName").className = "slot-name set";
    refreshRun();
    setStatus("READY", "Reference set. Now pick the target clip.", "idle");
  } catch (e) { setStatus("ERROR", String(e.message || e), "error"); }
}

async function captureSrc() {
  try {
    const s = await getSelected();
    if (!s.path) return setStatus("SELECT", "Select the target clip on the timeline, then click again.", "error");
    state.srcPath = s.path;
    state.srcTrackItem = s.trackItem;   // needed to apply the effect
    state.srcIn = s.inS; state.srcOut = s.outS;
    state.slot = null;                  // a new target invalidates the prior match's slot
    $("intensity-section").className = "section hidden";   // intensity inert until a fresh match
    $("srcName").textContent = baseName(s.path) + (s.trackItem ? "" : "  (not on timeline)");
    $("srcName").className = "slot-name set";
    refreshRun();
    setStatus("READY", "Target set. Match & Apply when ready.", "idle");
  } catch (e) { setStatus("ERROR", String(e.message || e), "error"); }
}

/* ---- Auto-apply the match as our native "colourMatik" effect --------------
 * The engine bakes the accurate 33^3 LUT into a slot file (/effect_lut); we add
 * the colourMatik effect to the target clip and point its "Match Slot" param at
 * that slot. The effect's own Intensity param dials strength live (0..200%), so
 * intensity changes never touch the engine — instant, and inside the effect. -
 * API notes: getComponentCount/getComponentAtIndex/getParamCount/getParam/
 * displayName are SYNC (inside lockedAccess); getMatchName is ASYNC (await
 * OUTSIDE the lock); writes go createKeyframe(raw)->createSetValueAction(kf,true). */
const CM_RE = /colourMatik/i;   // Premiere exposes it as "AE.catheadai colourMatik"

async function findEffect(project, chain) {
  const comps = [];
  project.lockedAccess(() => { const n = chain.getComponentCount(); for (let i = 0; i < n; i++) comps.push(chain.getComponentAtIndex(i)); });
  for (const c of comps) { let mn = ""; try { mn = await c.getMatchName(); } catch (e) {} if (CM_RE.test(mn)) return c; }
  return null;
}

async function ensureEffect(project, trackItem) {
  const chain = await trackItem.getComponentChain();
  let fx = await findEffect(project, chain);
  if (fx) return fx;
  const names = await ppro.VideoFilterFactory.getMatchNames();
  const mn = names.find((n) => CM_RE.test(n));
  if (!mn) throw new Error("colourMatik effect not installed — restart Premiere once after installing it.");
  const comp = await ppro.VideoFilterFactory.createComponent(mn);
  project.lockedAccess(() => { project.executeTransaction((ca) => ca.addAction(chain.createAppendComponentAction(comp)), "colourMatik: add effect"); });
  return await findEffect(project, chain);
}

function setEffectParams(project, fx, values) {
  let ok = false;
  project.lockedAccess(() => {
    const pmap = {};
    const pc = fx.getParamCount();
    for (let i = 0; i < pc; i++) { const p = fx.getParam(i); const dn = (p && p.displayName) || ""; if (dn && !(dn in pmap)) pmap[dn] = p; }
    ok = project.executeTransaction((ca) => {
      for (const [name, raw] of Object.entries(values)) { const p = pmap[name]; if (!p) continue; ca.addAction(p.createSetValueAction(p.createKeyframe(raw), true)); }
    }, "colourMatik: set params");
  });
  return ok;
}

async function applyEffect(trackItem, slot, intensityPct) {
  const project = await ppro.Project.getActiveProject();
  const fx = await ensureEffect(project, trackItem);
  if (!fx) throw new Error("couldn't add the colourMatik effect");
  const values = { "Match Slot": slot, "Intensity": intensityPct };
  if (!setEffectParams(project, fx, values)) throw new Error("couldn't set effect params");
  return true;
}

/* ---- Match & Apply -------------------------------------------------------- */
let _runGen = 0;   // generation token: a newer run() invalidates an older one's cleanup
async function run() {
  const gen = ++_runGen;
  // Snapshot the target NOW. The match takes seconds to minutes and the user can
  // re-capture meanwhile (the eyedropper stays live) — this run must apply to the
  // clip it was started for, not whatever was captured last.
  const tgt = {
    srcPath: state.srcPath, refPath: state.refPath, trackItem: state.srcTrackItem,
    srcIn: state.srcIn, srcOut: state.srcOut, refIn: state.refIn, refOut: state.refOut,
  };
  $("run").disabled = true;
  $("preview").className = "hidden";
  state.slot = null;                 // mid-match intensity drags must no-op, not apply the old LUT
  $("intensity-section").className = "section hidden";
  setStatus("MATCHING", "Working — this takes a few seconds…", "busy");
  const jobId = newJobId();
  startProgress(jobId);
  let ok = false;
  try {
    let res;
    try {
      // generous timeout: AI matches can take a while, but a wedged engine must
      // never leave the button dead forever
      res = await fetchT(SERVER + "/match_paths", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          source_path: tgt.srcPath, reference_path: tgt.refPath,
          mode: currentMode(), tf: "sRGB", frames: 7, look: currentLook(),
          source_in: tgt.srcIn ?? null, source_out: tgt.srcOut ?? null,
          reference_in: tgt.refIn ?? null, reference_out: tgt.refOut ?? null,
          job_id: jobId,
        }),
      }, 300000);
    } catch (netErr) {
      // Distinguish "we gave up waiting" from "nothing is listening" — the match may
      // well still be running in the engine after our 5-minute client timeout.
      if (netErr && netErr.name === "AbortError")
        throw new Error("The match is taking longer than 5 minutes — the engine may still be working. Try again with shorter clips, or wait and re-run.");
      throw new Error("Can't reach the engine at " + SERVER + " — start it with ./colourmatik-app");
    }
    const j = await res.json().catch(() => ({ ok: false, error: "HTTP " + res.status }));
    if (!j.ok) throw new Error(j.error || ("HTTP " + res.status));
    if (gen !== _runGen) return;     // a newer run took over — leave its UI alone
    ok = true;
    // The match (the slow part the bar tracks) is done — finish the bar NOW and
    // stop its polling timers before the quick apply steps, so nothing keeps
    // spinning while we add the effect. Re-enable the button immediately too, so
    // even if the UXP apply call resolves late the panel is never wedged.
    stopProgress(true);
    refreshRun();

    state.rid = j.rid;
    $("preview-img").src = j.preview;
    $("preview").className = "";

    // bake the accurate LUT into a fresh slot for the native colourMatik effect
    let ej = { ok: false };
    try {
      const eres = await fetchT(SERVER + "/effect_lut", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ rid: j.rid }) }, 30000);
      ej = await eres.json().catch(() => ({ ok: false }));
    } catch (e) {}
    if (gen !== _runGen) return;
    state.slot = ej.ok ? ej.slot : null;
    const slot = state.slot;
    // reveal Intensity only now that the slot is known, so the slider is never
    // live-but-dead — and only if the user hasn't re-targeted meanwhile (the
    // slider drives state.srcTrackItem, which may no longer be this run's clip)
    if (slot != null && tgt.trackItem && state.srcTrackItem === tgt.trackItem) {
      $("intensity-section").className = "section";
      $("intensity").value = DEFAULT_INTENSITY;
      $("intensity-val").textContent = DEFAULT_INTENSITY + "%";
    }

    const label = j.method_label || j.method;
    const mTxt = j.ai_used ? `${label} 🧠` : label;   // brain = local AI chose the match
    const deTxt = (j.de_after != null) ? `  ΔE00 ${Number(j.de_after).toFixed(2)}` : "";
    if (!tgt.trackItem) {
      setStatus("DONE", `Matched — ${mTxt}${deTxt}. Select the TARGET clip on the timeline and Match & Apply again to auto-apply.`, "done");
    } else if (slot == null) {
      setStatus("ERROR", "Match ok but the LUT slot couldn't be written — is the engine up to date?", "error");
    } else {
      try {
        // The UXP apply call can occasionally resolve late; never let it wedge the
        // panel — if it doesn't return in a few seconds, move on (the effect is
        // already added by then) so the button re-enables for the next clip.
        // The .catch() keeps a post-timeout rejection from surfacing as unhandled.
        const applying = applyEffect(tgt.trackItem, slot, DEFAULT_INTENSITY);
        applying.catch(() => {});
        await Promise.race([
          applying,
          new Promise((_, rej) => setTimeout(() => rej(new Error("apply-timeout")), 6000)),
        ]);
        if (gen !== _runGen) return;   // a newer run owns the status line now
        setStatus("DONE", `Matched — ${mTxt}${deTxt}. colourMatik effect applied — drag Intensity to adjust (live).`, "done");
      } catch (e) {
        if (gen !== _runGen) return;
        if (String(e.message) === "apply-timeout")
          setStatus("DONE", `Matched — ${mTxt}${deTxt}. colourMatik effect applied. Drag Intensity to adjust (live).`, "done");
        else
          setStatus("ERROR", "Apply failed: " + (e.message || e), "error");
      }
    }
  } catch (e) {
    if (gen === _runGen) setStatus("ERROR", String(e.message || e), "error");
  } finally {
    // only the newest run may touch the shared bar/button state
    if (gen === _runGen) {
      if (!ok) stopProgress(false);   // error before the match resolved -> clear the bar
      refreshRun();
    }
  }
}

/* ---- Intensity: live re-scale of the applied Lumetri sliders --------------- */
function onIntensity() {
  const v = parseInt($("intensity").value, 10);
  $("intensity-val").textContent = v + "%";
  if (bakeTimer) clearTimeout(bakeTimer);
  bakeTimer = setTimeout(() => applyIntensity(v), 110);
}

async function applyIntensity(v) {
  if (!state.srcTrackItem || state.slot == null) return;
  try {
    await applyEffect(state.srcTrackItem, state.slot, v);   // just re-set the effect's Intensity param — no engine round-trip
    setStatus("INTENSITY", v + "% — applied live on the clip.", "busy");
  } catch (e) { setStatus("INTENSITY", "intensity error: " + (e.message || e), "error"); }
}

/* ---- Footer: updates + site ---------------------------------------------- */
function semverGt(a, b) {
  const pa = String(a).split("."), pb = String(b).split(".");
  for (let i = 0; i < 3; i++) {
    const x = +pa[i] || 0, y = +pb[i] || 0;
    if (x > y) return true; if (x < y) return false;
  }
  return false;
}
async function openUrl(u) { try { await uxp.shell.openExternal(u); } catch (e) {} }
let updateUrl = null;   // set once an update is found; the single click handler branches on it
async function checkForUpdates() {
  if (updateUrl) return openUrl(updateUrl);   // already found — clicking opens the download
  $("update-link").textContent = "Checking…";
  try {
    const r = await fetchT(UPDATE_URL, { cache: "no-cache" }, 10000);
    if (!r.ok) throw new Error("HTTP " + r.status);
    const j = await r.json();
    if (j.version && semverGt(j.version, LOCAL_VERSION)) {
      $("update-link").textContent = "Update v" + j.version + " →";
      updateUrl = j.url || SITE_URL;
    } else {
      $("update-link").textContent = "Up to date";
    }
  } catch (e) {
    $("update-link").textContent = "Check failed";
  }
}

/* ---- Wire up -------------------------------------------------------------- */
$("refBtn").addEventListener("click", captureRef);
$("srcBtn").addEventListener("click", captureSrc);
$("mode-different").addEventListener("click", () => {
  $("mode-different").classList.add("selected"); $("mode-same").classList.remove("selected");
});
$("mode-same").addEventListener("click", () => {
  $("mode-same").classList.add("selected"); $("mode-different").classList.remove("selected");
});
$("look-exact").addEventListener("click", () => {
  $("look-exact").classList.add("selected"); $("look-ai").classList.remove("selected");
});
$("look-ai").addEventListener("click", () => {
  $("look-ai").classList.add("selected"); $("look-exact").classList.remove("selected");
});
$("run").addEventListener("click", run);
$("intensity").addEventListener("input", onIntensity);
$("site-link").addEventListener("click", () => openUrl(SITE_URL));
$("update-link").addEventListener("click", checkForUpdates);
$("version").textContent = "v" + LOCAL_VERSION;
