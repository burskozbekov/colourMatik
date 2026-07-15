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
function cm_activeComp() { var c = app.project ? app.project.activeItem : null; return (c && c instanceof CompItem) ? c : null; }
function cm_selLayer(comp) {
    var s = comp.selectedLayers, i;
    for (i = 0; i < s.length; i++) {
        try { if (s[i].source && s[i].source.mainSource && (s[i].source.mainSource instanceof FileSource) && s[i].source.mainSource.file) return s[i]; } catch (e) {}
    }
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

/* (A) read the currently-selected TARGET layer's source path + its layer index */
function cm_getSelectedSourcePath() {
    try {
        var comp = cm_activeComp(); if (!comp) return cm_res(false, "Open a composition first.");
        var L = cm_selLayer(comp);  if (!L)   return cm_res(false, "Select a footage layer in the timeline.");
        var path = L.source.mainSource.file.fsName;
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
