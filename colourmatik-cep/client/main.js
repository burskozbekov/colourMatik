/* colourMatik — After Effects CEP panel.
 * Identical UI to the Premiere UXP panel (same index.html/CSS). Talks to the local
 * engine at 127.0.0.1:8765 via Node http (bypasses CORS), and drives the native
 * "colourMatik" effect through ExtendScript (jsx/host.jsx) via CSInterface.
 * Engine: ./colourmatik-app  ·  by Sevki Bugra Ozbek · catheadai.com
 */
"use strict";
var cs = new CSInterface();
// Load (or re-load) the ExtendScript bridge on every panel open, so host.jsx
// updates apply on a simple panel close/reopen — no AE restart needed.
try {
  var _jsxPath = cs.getSystemPath(SystemPath.EXTENSION).replace(/\\/g, "/") + "/jsx/host.jsx";
  cs.evalScript('$.evalFile("' + _jsxPath + '")');
} catch (e) {}
var SERVER_HOST = "127.0.0.1", SERVER_PORT = 8765;
var LOCAL_VERSION = "1.2.0";
var UPDATE_URL = "https://raw.githubusercontent.com/burskozbekov/colourMatik/main/version.json";
var SITE_URL = "https://catheadai.com";
var DEFAULT_INTENSITY = 100;

var _req = (typeof require !== "undefined") ? require : (typeof cep_node !== "undefined" ? cep_node.require : null);
var _Buffer = (typeof Buffer !== "undefined") ? Buffer : (typeof cep_node !== "undefined" ? cep_node.Buffer : null);
var _http = _req ? _req("http") : null;

var $ = function (id) { return document.getElementById(id); };
var state = { refPath: null, srcPath: null, srcLayerIndex: null, rid: null, slot: null };
var bakeTimer = null;

/* ---- transport: Node http (primary) or fetch (fallback) ------------------- */
function httpJSON(method, path, payload, timeoutMs) {
  return new Promise(function (resolve, reject) {
    var body = payload != null ? JSON.stringify(payload) : null;
    if (_http) {
      var headers = {};
      if (body != null) { headers["Content-Type"] = "application/json"; headers["Content-Length"] = _Buffer.byteLength(body); }
      var r = _http.request({ host: SERVER_HOST, port: SERVER_PORT, path: path, method: method, headers: headers }, function (res) {
        var buf = ""; res.setEncoding("utf8");
        res.on("data", function (d) { buf += d; });
        res.on("end", function () {
          var j = null; try { j = JSON.parse(buf); } catch (e) {}
          if (res.statusCode >= 200 && res.statusCode < 300) resolve(j || {});
          else reject(new Error((j && j.error) || ("HTTP " + res.statusCode)));
        });
      });
      r.on("error", function () { reject(new Error("Can't reach the engine at http://" + SERVER_HOST + ":" + SERVER_PORT + " — start it with ./colourmatik-app")); });
      r.setTimeout(timeoutMs || 300000, function () { r.destroy(new Error("timeout")); });
      if (body != null) r.write(body);
      r.end();
    } else {
      var ctrl = new AbortController();
      var t = setTimeout(function () { ctrl.abort(); }, timeoutMs || 300000);
      var opt = { method: method, signal: ctrl.signal };
      if (body != null) { opt.headers = { "Content-Type": "application/json" }; opt.body = body; }
      fetch("http://" + SERVER_HOST + ":" + SERVER_PORT + path, opt)
        .then(function (res) { return res.json(); })
        .then(function (j) { resolve(j || {}); })
        .catch(function () { reject(new Error("Can't reach the engine at http://" + SERVER_HOST + ":" + SERVER_PORT)); })
        .then(function () { clearTimeout(t); }, function () { clearTimeout(t); });
    }
  });
}
function postJSON(path, payload, timeoutMs) { return httpJSON("POST", path, payload, timeoutMs); }
function getJSON(path, timeoutMs) { return httpJSON("GET", path, null, timeoutMs); }

/* ---- ExtendScript bridge -------------------------------------------------- */
function evalHost(call) {
  return new Promise(function (resolve) {
    cs.evalScript(call, function (raw) {
      if (raw === "EvalScript error." || raw == null) { resolve({ ok: false, message: "After Effects script error." }); return; }
      var j = null; try { j = JSON.parse(raw); } catch (e) {}
      resolve(j || { ok: false, message: "Bad response from After Effects." });
    });
  });
}

/* ---- UI helpers ----------------------------------------------------------- */
function setStatus(stateLabel, msg, kind) {
  $("status-state").textContent = stateLabel;
  $("status-msg").textContent = msg;
  $("status").className = kind || "idle";
}
function currentMode() { return $("mode-same").classList.contains("selected") ? "same" : "different"; }
function currentLook() { return $("look-ai").classList.contains("selected") ? "ai_grade" : "exact"; }
function refreshRun() { $("run").disabled = !(state.refPath && state.srcPath); }
function baseName(p) { return p ? p.split(/[\\\/]/).pop() : ""; }

/* ---- Match & Apply loading bar (fed by GET /progress) --------------------- */
var _progPoll = null, _progTick = null, _progReset = null, _dispPct = 0, _srvPct = 0, _srvMsg = "";
function _paintProg() {
  $("run-fill").style.width = (_dispPct * 100).toFixed(1) + "%";
  $("run-label").textContent = Math.round(_dispPct * 100) + "%" + (_srvMsg ? "  ·  " + _srvMsg : "");
}
function startProgress(jobId) {
  if (_progPoll) clearInterval(_progPoll);
  if (_progTick) clearInterval(_progTick);
  if (_progReset) { clearTimeout(_progReset); _progReset = null; }
  _dispPct = 0; _srvPct = 0; _srvMsg = "Starting";
  $("run").classList.add("loading");
  var polling = false;
  _progPoll = setInterval(function () {
    if (polling) return; polling = true;
    getJSON("/progress/" + jobId, 4000).then(function (j) {
      if (j && typeof j.pct === "number") { _srvPct = j.pct; if (j.msg) _srvMsg = j.msg; }
    }).then(function () { polling = false; }, function () { polling = false; });
  }, 500);
  _progTick = setInterval(function () {
    var soft = Math.min(0.97, _srvPct + 0.10);
    var target = Math.max(_srvPct, Math.min(soft, _dispPct + 0.006));
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
  _progReset = setTimeout(function () {
    _progReset = null;
    $("run").classList.remove("loading");
    $("run-fill").style.width = "0%";
    $("run-label").textContent = "MATCH & APPLY";
  }, done ? 450 : 0);
}
function newJobId() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 8); }

/* ---- capture reference / target (the selected AE layer) ------------------- */
async function captureRef() {
  try {
    var s = await evalHost("cm_getSelectedSourcePath()");
    if (!s.ok) return setStatus("SELECT", s.message || "Select the reference layer, then click again.", "error");
    state.refPath = s.path;
    $("refName").textContent = baseName(s.path);
    $("refName").className = "slot-name set";
    refreshRun();
    setStatus("READY", "Reference set. Now pick the target layer.", "idle");
  } catch (e) { setStatus("ERROR", String(e.message || e), "error"); }
}
async function captureSrc() {
  try {
    var s = await evalHost("cm_getSelectedSourcePath()");
    if (!s.ok) return setStatus("SELECT", s.message || "Select the target layer, then click again.", "error");
    state.srcPath = s.path;
    state.srcLayerIndex = s.layerIndex;
    state.slot = null;
    $("intensity-section").className = "section hidden";
    $("srcName").textContent = baseName(s.path);
    $("srcName").className = "slot-name set";
    refreshRun();
    setStatus("READY", "Target set. Match & Apply when ready.", "idle");
  } catch (e) { setStatus("ERROR", String(e.message || e), "error"); }
}

/* ---- Match & Apply -------------------------------------------------------- */
var _runGen = 0;
async function run() {
  var gen = ++_runGen;
  $("run").disabled = true;
  $("preview").className = "hidden";
  state.slot = null;
  $("intensity-section").className = "section hidden";
  setStatus("MATCHING", "Working — this takes a few seconds…", "busy");
  var jobId = newJobId();
  startProgress(jobId);
  var ok = false;
  try {
    var j;
    try {
      j = await postJSON("/match_paths", {
        source_path: state.srcPath, reference_path: state.refPath,
        mode: currentMode(), tf: "sRGB", frames: 7, look: currentLook(), job_id: jobId
      }, 300000);
    } catch (netErr) { throw new Error(String(netErr.message || netErr)); }
    if (!j || !j.ok) throw new Error((j && j.error) || "match failed");
    if (gen !== _runGen) return;
    ok = true;
    stopProgress(true);
    refreshRun();

    state.rid = j.rid;
    if (j.preview) { $("preview-img").src = j.preview; $("preview").className = ""; }

    var ej = { ok: false };
    try { ej = await postJSON("/effect_lut", { rid: j.rid }, 30000); } catch (e) {}
    if (gen !== _runGen) return;
    state.slot = (ej && ej.ok) ? ej.slot : null;

    if (state.slot != null) {
      $("intensity-section").className = "section";
      $("intensity").value = DEFAULT_INTENSITY;
      $("intensity-val").textContent = DEFAULT_INTENSITY + "%";
    }

    var label = j.method_label || j.method || "";
    var mTxt = j.ai_used ? (label + " 🧠") : label;
    var deTxt = (j.de_after != null) ? ("  ΔE00 " + Number(j.de_after).toFixed(2)) : "";
    if (state.slot == null) {
      setStatus("ERROR", "Match ok but the LUT slot couldn't be written — is the engine up to date?", "error");
    } else {
      var ap = await evalHost("cm_apply(" + parseInt(state.slot, 10) + ", " + DEFAULT_INTENSITY + ", " + (state.srcLayerIndex || 0) + ")");
      if (gen !== _runGen) return;
      if (ap.ok) setStatus("DONE", "Matched — " + mTxt + deTxt + ". colourMatik applied — drag Intensity to adjust.", "done");
      else setStatus("ERROR", ap.message || "Apply failed.", "error");
    }
  } catch (e) {
    if (gen === _runGen) setStatus("ERROR", String(e.message || e), "error");
  } finally {
    if (gen === _runGen) { if (!ok) stopProgress(false); refreshRun(); }
  }
}

/* ---- Intensity: live re-set of the effect param --------------------------- */
function onIntensity() {
  var v = parseInt($("intensity").value, 10);
  $("intensity-val").textContent = v + "%";
  if (bakeTimer) clearTimeout(bakeTimer);
  bakeTimer = setTimeout(function () { applyIntensity(v); }, 110);
}
async function applyIntensity(v) {
  if (state.slot == null) return;
  try {
    var r = await evalHost("cm_setIntensity(" + v + ", " + (state.srcLayerIndex || 0) + ")");
    if (r.ok) setStatus("INTENSITY", v + "% — applied live on the layer.", "busy");
    else setStatus("INTENSITY", r.message || "intensity error", "error");
  } catch (e) { setStatus("INTENSITY", "intensity error: " + (e.message || e), "error"); }
}

/* ---- footer: updates + site ---------------------------------------------- */
function semverGt(a, b) {
  var pa = String(a).split("."), pb = String(b).split(".");
  for (var i = 0; i < 3; i++) { var x = +pa[i] || 0, y = +pb[i] || 0; if (x > y) return true; if (x < y) return false; }
  return false;
}
var updateUrl = null;
function checkForUpdates() {
  if (updateUrl) { cs.openURLInDefaultBrowser(updateUrl); return; }
  $("update-link").textContent = "Checking…";
  var done = function (txt) { $("update-link").textContent = txt; };
  var doFetch = function () {
    if (typeof fetch === "function") return fetch(UPDATE_URL, { cache: "no-store" }).then(function (r) { return r.json(); });
    return getJSONAbs(UPDATE_URL);
  };
  doFetch().then(function (j) {
    if (j && j.version && semverGt(j.version, LOCAL_VERSION)) { done("Update v" + j.version + " →"); updateUrl = j.url || SITE_URL; }
    else done("Up to date");
  }).catch(function () { done("Check failed"); });
}
function getJSONAbs(url) {
  return new Promise(function (resolve, reject) {
    try {
      var lib = _req(url.indexOf("https") === 0 ? "https" : "http");
      lib.get(url, function (res) { var b = ""; res.on("data", function (d) { b += d; }); res.on("end", function () { try { resolve(JSON.parse(b)); } catch (e) { reject(e); } }); }).on("error", reject);
    } catch (e) { reject(e); }
  });
}

/* ---- wire up -------------------------------------------------------------- */
$("refBtn").addEventListener("click", captureRef);
$("srcBtn").addEventListener("click", captureSrc);
$("mode-different").addEventListener("click", function () { $("mode-different").classList.add("selected"); $("mode-same").classList.remove("selected"); });
$("mode-same").addEventListener("click", function () { $("mode-same").classList.add("selected"); $("mode-different").classList.remove("selected"); });
$("look-exact").addEventListener("click", function () { $("look-exact").classList.add("selected"); $("look-ai").classList.remove("selected"); });
$("look-ai").addEventListener("click", function () { $("look-ai").classList.add("selected"); $("look-exact").classList.remove("selected"); });
$("run").addEventListener("click", run);
$("intensity").addEventListener("input", onIntensity);
$("site-link").addEventListener("click", function () { cs.openURLInDefaultBrowser(SITE_URL); });
$("update-link").addEventListener("click", checkForUpdates);
$("version").textContent = "v" + LOCAL_VERSION;

/* the panel's REFERENCE/TARGET labels say "from the selected clip" — in AE that's
   the selected layer, so update the two slot hints to read "layer". */
try {
  var refLbl = document.querySelectorAll(".field-label")[0];
  var tgtLbl = document.querySelectorAll(".field-label")[1];
  if (refLbl) refLbl.textContent = "REFERENCE — THE LOOK TO COPY";
  if (tgtLbl) tgtLbl.textContent = "TARGET — APPLY THE LOOK TO THIS";
} catch (e) {}
