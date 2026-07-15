/* jsx/host.jsx — colourMatik After Effects ExtendScript host bridge (ES3).
 * ONLY AE project work; NO networking (the panel does all HTTP via Node http).
 * Every entry function returns a JSON STRING built by hand (ES3 has no JSON.stringify;
 * Windows fsName paths contain backslashes that must be escaped).
 * Effect identity (colourmatik-fx/colourMatik.cpp): Match Name "catheadai colourMatik",
 * params "Intensity" and "Match Slot" (float sliders).
 */
var CM_EFFECT_MATCH = "catheadai colourMatik";
var CM_EFFECT_NAME  = "colourMatik";

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
function cm_activeComp() {
    // Reading app.project.activeItem while the CEP panel has focus can throw AE's
    // "internal verification failure {no current context}" alert. Giving the comp
    // viewer focus first (activeViewer.setActive()) restores a valid context —
    // the standard workaround used by CEP panels.
    var c = null;
    try { if (app.activeViewer) app.activeViewer.setActive(); } catch (e0) {}
    try { c = app.project ? app.project.activeItem : null; } catch (e1) { c = null; }
    if (c && c instanceof CompItem) return c;
    // fallback: if the project has exactly one comp, use it
    try {
        var only = null, n = 0, i;
        for (i = 1; i <= app.project.numItems; i++) {
            if (app.project.item(i) instanceof CompItem) { n++; only = app.project.item(i); if (n > 1) break; }
        }
        if (n === 1) return only;
    } catch (e2) {}
    return null;
}
/* first selected layer that can hold effects (footage, precomp, solid, text, shape) */
function cm_selLayer(comp) {
    var s = comp.selectedLayers, i;
    for (i = 0; i < s.length; i++) { try { if (s[i] instanceof AVLayer) return s[i]; } catch (e) {} }
    for (i = 0; i < s.length; i++) { try { if (s[i].property("ADBE Effect Parade")) return s[i]; } catch (e2) {} }
    return null;
}

/* Resolve a layer to a still image the engine can read. A footage layer with a
 * file uses the file directly; anything else (PRECOMP, solid, text, shape) is
 * rendered to a temp PNG at its current frame — so precomps just work. */
function cm_layerImagePath(L) {
    // 1) plain footage file
    try {
        if (L.source && L.source.mainSource && (L.source.mainSource instanceof FileSource) && L.source.mainSource.file)
            return L.source.mainSource.file.fsName;
    } catch (e) {}
    // 2) precomp -> render the SOURCE comp's current frame
    try {
        if (L.source && (L.source instanceof CompItem)) {
            var png1 = new File(Folder.temp.fsName + "/cmk_" + (new Date()).getTime() + "_" + L.index + ".png");
            L.source.saveFrameToPng(L.source.time, png1);
            if (png1.exists) return png1.fsName;
        }
    } catch (e2) {}
    // 3) any other AV layer -> render the CONTAINING comp's current frame (best effort)
    try {
        var comp = cm_activeComp();
        if (comp) {
            var png2 = new File(Folder.temp.fsName + "/cmk_" + (new Date()).getTime() + "_c.png");
            comp.saveFrameToPng(comp.time, png2);
            if (png2.exists) return png2.fsName;
        }
    } catch (e3) {}
    return null;
}
function cm_layerByIndex(comp, idx) {
    idx = Number(idx);
    if (idx && idx >= 1 && idx <= comp.numLayers) { try { return comp.layer(idx); } catch (e) {} }
    return cm_selLayer(comp);
}
function cm_findEffect(L) {
    var par = L.property("ADBE Effect Parade"), i, p;
    for (i = 1; i <= par.numProperties; i++) { p = par.property(i); if (p && (p.matchName === CM_EFFECT_MATCH || p.name === CM_EFFECT_NAME)) return p; }
    return null;
}

/* (A) read the currently-selected layer's image path (file, or rendered PNG for a
 *     precomp/solid/etc.) + its layer index */
function cm_getSelectedSourcePath() {
    try {
        var comp = cm_activeComp(); if (!comp) return cm_res(false, "Open a composition first.");
        var L = cm_selLayer(comp);  if (!L)   return cm_res(false, "Select a layer in the timeline.");
        var path = cm_layerImagePath(L);
        if (!path) return cm_res(false, "Couldn't read that layer — select a footage or precomp layer.");
        return cm_res(true, "OK", '"path":"' + cm_esc(path) + '","layerName":"' + cm_esc(L.name) + '","layerIndex":' + L.index);
    } catch (e) { return cm_res(false, "Error: " + e.toString()); }
}

/* (B) apply/ensure the effect on the TARGET layer (by remembered index) + set both params */
function cm_apply(slot, intensity, layerIndex) {
    app.beginUndoGroup("colourMatik: Match & Apply");
    try {
        var comp = cm_activeComp(); if (!comp) return cm_res(false, "Open a composition first.");
        var L = cm_layerByIndex(comp, layerIndex); if (!L) return cm_res(false, "Select the TARGET footage layer in the timeline.");
        var par = L.property("ADBE Effect Parade"); if (!par) return cm_res(false, "This layer cannot hold effects.");
        var fx = cm_findEffect(L);
        if (!fx) {
            if (!par.canAddProperty(CM_EFFECT_MATCH)) return cm_res(false, "colourMatik effect not installed — restart After Effects once after installing it.");
            fx = par.addProperty(CM_EFFECT_MATCH);
        }
        var pSlot = fx.property("Match Slot"), pInt = fx.property("Intensity");
        if (pSlot && pSlot.numKeys === 0) pSlot.setValue(Number(slot));
        if (pInt && pInt.numKeys === 0) pInt.setValue(Number(intensity));
        return cm_res(true, "Applied", '"layer":"' + cm_esc(L.name) + '"');
    } catch (e) { return cm_res(false, "Applied the match, but couldn't add the effect: " + e.toString()); }
    finally { app.endUndoGroup(); }
}

/* (C) live intensity — re-set only the Intensity param on the TARGET layer's effect */
function cm_setIntensity(v, layerIndex) {
    app.beginUndoGroup("colourMatik: Intensity");
    try {
        var comp = cm_activeComp(); if (!comp) return cm_res(false, "No comp.");
        var L = cm_layerByIndex(comp, layerIndex); if (!L) return cm_res(false, "No layer.");
        var fx = cm_findEffect(L); if (!fx) return cm_res(false, "No colourMatik effect on the layer.");
        var pInt = fx.property("Intensity");
        if (pInt && pInt.numKeys === 0) pInt.setValue(Number(v));
        return cm_res(true, "OK");
    } catch (e) { return cm_res(false, "intensity error: " + e.toString()); }
    finally { app.endUndoGroup(); }
}
