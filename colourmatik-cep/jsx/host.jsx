/* jsx/host.jsx — colourMatik After Effects ExtendScript host bridge (ES3).
 * ONLY AE project work; NO networking (the panel does all HTTP via Node http).
 * Every entry function returns a JSON STRING built by hand (ES3 has no JSON.stringify;
 * Windows fsName paths contain backslashes that must be escaped).
 * Effect identity (colourmatik-fx/colourMatik.cpp): Match Name "catheadai colourMatik",
 * params "Intensity" and "Match Slot" (float sliders).
 */
/* The Premiere (MediaCore) build's match name is "catheadai colourMatik"; the AE
 * build's is "catheadaiAEcolorMatik" (distinct so AE doesn't flag a duplicate).
 * BOTH display as "colourMatik". Match on any of these; add by the AE match name,
 * then the display name, then the Premiere match name. */
var CM_EFFECT_MATCH   = "catheadai colourMatik";
var CM_EFFECT_MATCH_AE = "catheadaiAEcolorMatik";
var CM_EFFECT_NAME    = "colourMatik";
var CM_ADD_NAMES = [CM_EFFECT_MATCH_AE, CM_EFFECT_NAME, CM_EFFECT_MATCH];

function cm_esc(s) {
    s = String(s); var o = "", i, c;
    for (i = 0; i < s.length; i++) {
        c = s.charAt(i);
        if (c === '\\') o += '\\\\'; else if (c === '"') o += '\\"';
        else if (c === '\n') o += '\\n'; else if (c === '\r') o += '\\r';
        else if (c === '\t') o += '\\t'; else o += c;
    }
    return o;
}
function cm_res(ok, msg, extra) {
    var s = '{"ok":' + (ok ? 'true' : 'false') + ',"message":"' + cm_esc(msg) + '"';
    if (extra) s += ',' + extra;
    return s + '}';
}
// $.global survives across separate CEP evalScript calls in the same ES engine —
// where we remember the last-good comp between button clicks.
if (typeof $.global.cmLastCompId === "undefined") $.global.cmLastCompId = 0;

// Resolve a CompItem using ONLY safe, context-free reads (these never throw the
// modal; activeItem just returns null when the panel has focus).
function cm_pickComp() {
    var proj = null;
    try { proj = app.project; } catch (eP) {}
    if (!proj) return null;
    var c = null, i;
    // 1) the active item, if it's already a comp
    try { c = proj.activeItem; } catch (e0) { c = null; }
    if (c && c instanceof CompItem) { $.global.cmLastCompId = c.id; return c; }
    // 2) the comp in the active viewer — ONLY if it's a Composition viewer
    try {
        var v = app.activeViewer;
        if (v && v.type === ViewerType.VIEWER_COMPOSITION) {
            v.setActive();
            c = proj.activeItem;
            if (c && c instanceof CompItem) { $.global.cmLastCompId = c.id; return c; }
        }
    } catch (e1) {}
    // 3) a comp selected in the Project panel
    try {
        var sel = proj.selection;
        for (i = 0; i < sel.length; i++) if (sel[i] instanceof CompItem) { $.global.cmLastCompId = sel[i].id; return sel[i]; }
    } catch (e2) {}
    // 4) the last comp we successfully used (itemByID is AE 13+)
    try {
        var id = $.global.cmLastCompId;
        if (id) { var it = null; try { it = proj.itemByID(id); } catch (eB) {} if (it && it instanceof CompItem) return it; }
    } catch (e3) {}
    // 5) last resort: exactly one comp in the project
    try {
        var only = null, n = 0, j;
        for (j = 1; j <= proj.numItems; j++) if (proj.item(j) instanceof CompItem) { n++; only = proj.item(j); if (n > 1) break; }
        if (n === 1) return only;
    } catch (e4) {}
    return null;
}

// Establish a valid AE "current context" and return the active CompItem (or null).
// openInViewer() is the load-bearing call: unlike setActive() (which only re-focuses
// an ALREADY-open comp viewer), it OPENS + focuses a Composition viewer from nothing,
// so beginUndoGroup / saveFrameToPng / addProperty afterwards can never hit
// "{no current context}". Selection is preserved (it lives on the CompItem).
function cm_context() {
    var comp = cm_pickComp();
    if (!comp) return null;
    try { var vw = comp.openInViewer(); if (vw) vw.setActive(); } catch (e0) {}
    try { if (app.activeViewer && app.activeViewer.type === ViewerType.VIEWER_COMPOSITION) app.activeViewer.setActive(); } catch (e1) {}
    $.global.cmLastCompId = comp.id;
    return comp;
}
function cm_activeComp() { return cm_context(); }
/* first selected layer that can hold effects (footage, precomp, solid, text, shape) */
function cm_selLayer(comp) {
    var s = comp.selectedLayers, i;
    for (i = 0; i < s.length; i++) { try { if (s[i] instanceof AVLayer) return s[i]; } catch (e) {} }
    for (i = 0; i < s.length; i++) { try { if (s[i].property("ADBE Effect Parade")) return s[i]; } catch (e2) {} }
    return null;
}

/* Resolve a layer to a still image the engine can read. Footage-with-file uses the
 * file directly; a PRECOMP (or solid/text/shape) is rendered to a temp PNG.
 * Returns { path: string|null, diag: string } — diag surfaces WHY it failed. */
var _cmDiag = "";
// Does the file exist AND is it readable? File.exists is cached by ExtendScript and
// unreliable after an external write (saveFrameToPng); open("r") forces a real stat.
function cm_fileReadable(path) {
    var f = new File(path); f.encoding = "BINARY";
    if (f.open("r")) { f.close(); return true; }
    return false;
}
function cm_layerImagePath(L) {
    _cmDiag = "";
    // 1) plain footage file
    try {
        if (L.source && L.source.mainSource && (L.source.mainSource instanceof FileSource) && L.source.mainSource.file)
            return L.source.mainSource.file.fsName;
    } catch (e) {}
    // 2) render a frame: the precomp's OWN comp, else the containing comp
    var target = null;
    try { if (L.source && (L.source instanceof CompItem)) target = L.source; } catch (e2) {}
    if (!target) { try { target = cm_activeComp(); } catch (e3) {} }
    if (!target) { _cmDiag += "no-renderable-comp "; return null; }
    if (typeof target.saveFrameToPng !== "function") { _cmDiag += "needs AE 2022+ "; return null; }

    // IMPORTANT: do NOT use Folder.temp — on macOS AE that is the sandbox-protected
    // ".../T/TemporaryItems" folder, which the (separately-launched) engine process
    // gets "Operation not permitted" reading. Write to colourMatik's own support
    // folder, which the engine reads freely.
    var dir = new Folder(Folder.userData.fsName + "/colourMatik/aeframes");
    try { if (!dir.exists) dir.create(); } catch (eD) {}
    // No Folder.temp fallback: the engine cannot read TemporaryItems (TCC), so a
    // frame written there is guaranteed to fail later with a confusing error.
    if (!dir.exists) { _cmDiag += "cannot create colourMatik/aeframes "; return null; }
    // Prune old frames so the folder doesn't grow unbounded — but ONLY old ones.
    // The reference and the target both live here between captures; deleting
    // everything on each capture destroyed the previously captured frame and made
    // precomp-to-precomp matching always fail with "file not found".
    try {
        var old = dir.getFiles("cmk_*.png"), oi, now = (new Date()).getTime();
        if (old) for (oi = 0; oi < old.length; oi++) {
            try { if (now - old[oi].modified.getTime() > 2 * 3600 * 1000) old[oi].remove(); } catch (eR) {}
        }
    } catch (eP) {}
    var png = new File(dir.fsName + "/cmk_" + (new Date()).getTime() + ".png");
    try {
        // Render at the comp's CURRENT time (mapped into the precomp), not frame 0 —
        // frame 0 is often a slate/empty/green-screen frame that has nothing to do
        // with what the user is looking at, and matching on it gives absurd results.
        var t = 0;
        try {
            var host = cm_activeComp();
            if (host) { t = host.time; if (target !== host) t = host.time - L.startTime; }
        } catch (eT) { t = 0; }
        try {
            var maxT = target.duration - target.frameDuration;
            if (t > maxT) t = maxT;
            if (t < 0) t = 0;
        } catch (eC) { t = 0; }
        target.saveFrameToPng(t, png);
        // saveFrameToPng QUEUES the render — the file lands on disk a moment later.
        // Wait until the file is readable AND its size has stopped growing (two
        // consecutive equal non-zero lengths), so the engine never reads a
        // half-written PNG.
        var w, lastLen = -1;
        for (w = 0; w < 150; w++) {
            var pf = new File(png.fsName); pf.encoding = "BINARY";
            if (pf.open("r")) {
                var len = pf.length; pf.close();
                if (len > 0 && len === lastLen) return png.fsName;
                lastLen = len;
            }
            $.sleep(100);
        }
        _cmDiag += "png-render-timeout ";
        return null;
    } catch (e4) { _cmDiag += "render error: " + e4.toString() + " "; return null; }
}
/* Resolve the target layer by index, VERIFIED by name. AE layer indices shift on
 * every reorder/delete — blindly trusting a stale index applies the effect to an
 * unrelated layer. If the name no longer matches, find the layer by its (unique)
 * name; if it's ambiguous or gone, return null so the caller errors loudly
 * instead of silently grading the wrong layer. */
function cm_layerByIndex(comp, idx, name) {
    idx = Number(idx);
    var L = null;
    if (idx && idx >= 1 && idx <= comp.numLayers) { try { L = comp.layer(idx); } catch (e) {} }
    if (!name) return L || cm_selLayer(comp);   // legacy path: no identity available
    if (L && L.name === name) return L;
    var k, cand = null, n = 0;
    for (k = 1; k <= comp.numLayers; k++) {
        try { if (comp.layer(k).name === name) { cand = comp.layer(k); n++; } } catch (e2) {}
    }
    return (n === 1) ? cand : null;
}
function cm_findEffect(L) {
    var par = L.property("ADBE Effect Parade"), i, p;
    for (i = 1; i <= par.numProperties; i++) {
        p = par.property(i);
        if (p && (p.name === CM_EFFECT_NAME || p.matchName === CM_EFFECT_MATCH || p.matchName === CM_EFFECT_MATCH_AE)) return p;
    }
    return null;
}
/* add the colourMatik effect, trying each known name (AE match, display, Pr match) */
function cm_addEffect(par) {
    var k, nm;
    for (k = 0; k < CM_ADD_NAMES.length; k++) {
        nm = CM_ADD_NAMES[k];
        try { if (par.canAddProperty(nm)) return par.addProperty(nm); } catch (e) {}
    }
    return null;
}

/* (A) read the currently-selected layer's image path (file, or rendered PNG for a
 *     precomp/solid/etc.) + its layer index */
function cm_getSelectedSourcePath() {
    try {
        var comp = cm_activeComp(); if (!comp) return cm_res(false, "Open a composition first.");
        var L = cm_selLayer(comp);  if (!L)   return cm_res(false, "Select a layer in the timeline.");
        var path = cm_layerImagePath(L);
        if (!path) return cm_res(false, "Couldn't read '" + L.name + "'. " + _cmDiag);
        // compId pins the apply to THIS comp — cm_apply must not guess from whatever
        // viewer happens to be active minutes later when the match finishes.
        return cm_res(true, "OK", '"path":"' + cm_esc(path) + '","layerName":"' + cm_esc(L.name) + '","layerIndex":' + L.index + ',"compId":' + comp.id);
    } catch (e) { return cm_res(false, "Error: " + e.toString()); }
}

/* Establish context on the comp captured at match time (by id); fall back to the
 * old guess only if that comp no longer exists. */
function cm_compForApply(compId) {
    var comp = null;
    try {
        var it = app.project.itemByID(Number(compId));
        if (it && (it instanceof CompItem)) comp = it;
    } catch (e) {}
    if (comp) {
        try { var vw = comp.openInViewer(); if (vw) vw.setActive(); } catch (e2) {}
        try { $.global.cmLastCompId = comp.id; } catch (e3) {}
        return comp;
    }
    return cm_context();
}

/* (B) apply/ensure the effect on the TARGET layer (by remembered index) + set both params.
 * cm_context() (openInViewer) MUST run BEFORE beginUndoGroup — beginUndoGroup itself
 * needs a valid current context, so establishing it first is the fix. */
function cm_apply(slot, intensity, layerIndex, compId, layerName) {
    var comp = compId ? cm_compForApply(compId) : cm_context();
    if (!comp) return cm_res(false, "Open a composition first.");
    app.beginUndoGroup("colourMatik: Match & Apply");
    try {
        var L = cm_layerByIndex(comp, layerIndex, layerName);
        if (!L) return cm_res(false, "The TARGET layer" + (layerName ? " '" + layerName + "'" : "") + " is no longer in '" + comp.name + "' — re-select it and match again.");
        var par = L.property("ADBE Effect Parade"); if (!par) return cm_res(false, "This layer cannot hold effects.");
        var fx = cm_findEffect(L);
        if (!fx) {
            fx = cm_addEffect(par);
            if (!fx) return cm_res(false, "colourMatik effect not installed — restart After Effects once after installing it.");
        }
        // Set params — and VERIFY they stuck. A silent miss here means the effect
        // stays at slot 0 (= identity, no colour change), so report it loudly.
        var pSlot = fx.property("Match Slot"), pInt = fx.property("Intensity");
        if (!pSlot || !pInt) {
            // fall back to scanning by name (localized/odd hosts)
            var q, pp;
            for (q = 1; q <= fx.numProperties; q++) {
                pp = fx.property(q);
                if (!pp) continue;
                if (!pSlot && pp.name === "Match Slot") pSlot = pp;
                if (!pInt && pp.name === "Intensity") pInt = pp;
            }
        }
        if (!pSlot) return cm_res(false, "Effect added but its 'Match Slot' param wasn't found — is an old colourMatik build installed? Restart After Effects.");
        if (pSlot.numKeys === 0) pSlot.setValue(Number(slot));
        if (pInt && pInt.numKeys === 0) pInt.setValue(Number(intensity));
        var gotSlot = -1; try { gotSlot = pSlot.value; } catch (eV) {}
        if (Math.round(gotSlot) !== Math.round(Number(slot)))
            return cm_res(false, "Couldn't set Match Slot (wanted " + slot + ", effect has " + gotSlot + "). Remove keyframes from the effect and retry.");
        return cm_res(true, "Applied", '"layer":"' + cm_esc(L.name) + '","slot":' + Math.round(gotSlot));
    } catch (e) { return cm_res(false, "Applied the match, but couldn't add the effect: " + e.toString()); }
    finally { app.endUndoGroup(); }
}

/* (C) live intensity — re-set only the Intensity param on the TARGET layer's effect */
function cm_setIntensity(v, layerIndex, compId, layerName) {
    var comp = compId ? cm_compForApply(compId) : cm_context();
    if (!comp) return cm_res(false, "No comp — open a composition first.");
    app.beginUndoGroup("colourMatik: Intensity");
    try {
        var L = cm_layerByIndex(comp, layerIndex, layerName); if (!L) return cm_res(false, "No layer.");
        var fx = cm_findEffect(L); if (!fx) return cm_res(false, "No colourMatik effect on the layer.");
        var pInt = fx.property("Intensity");
        if (pInt && pInt.numKeys === 0) pInt.setValue(Number(v));
        return cm_res(true, "OK");
    } catch (e) { return cm_res(false, "intensity error: " + e.toString()); }
    finally { app.endUndoGroup(); }
}
