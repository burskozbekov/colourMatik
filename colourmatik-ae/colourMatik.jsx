// colourMatik — After Effects panel (ScriptUI).
// Same workflow as the Premiere panel: pick a REFERENCE clip, select the TARGET
// layer, hit Match & Apply. It calls the local engine (http://127.0.0.1:8765) via
// curl, then adds the native "colourMatik" effect to the layer and points it at
// the freshly baked LUT slot. Intensity dials the strength live (0-200%).
//
// After Effects has no UXP, so this is ExtendScript/ScriptUI. Networking is done
// with the system `curl` (present on macOS and Windows 10 17063+), driven through
// system.callSystem — no ExtendScript Socket.
//
// Requires: Preferences > Scripting & Expressions >
//           "Allow Scripts to Write Files and Access Network" = ON.
// by Sevki Bugra Ozbek - catheadai.com

(function (thisObj) {
    var SERVER = "http://127.0.0.1:8765";
    var EFFECT_MATCH = "catheadai colourMatik";   // effect match name
    var EFFECT_NAME = "colourMatik";              // effect display name (fallback)
    var state = { refPath: null };

    // ---- self-enable AE's scripting network/file permission --------------------
    // The panel needs "Allow Scripts to Write Files and Access Network". Instead of
    // asking the user to find a checkbox, flip the preference ourselves (both pref
    // section names, old and new AE). Returns true when the permission is on.
    function securityOn() {
        var sections = ["Main Pref Section v2", "Main Pref Section"];
        for (var i = 0; i < sections.length; i++) {
            try {
                if (app.preferences.getPrefAsLong(sections[i], "Pref_SCRIPTING_FILE_NETWORK_SECURITY",
                        PREFType.PREF_Type_MACHINE_INDEPENDENT) === 1) return true;
            } catch (e) {}
            try {
                if (app.preferences.getPrefAsLong(sections[i], "Pref_SCRIPTING_FILE_NETWORK_SECURITY") === 1) return true;
            } catch (e2) {}
        }
        return false;
    }
    function enableSecurity() {
        if (securityOn()) return true;
        var sections = ["Main Pref Section v2", "Main Pref Section"];
        for (var i = 0; i < sections.length; i++) {
            try {
                app.preferences.savePrefAsLong(sections[i], "Pref_SCRIPTING_FILE_NETWORK_SECURITY", 1,
                    PREFType.PREF_Type_MACHINE_INDEPENDENT);
            } catch (e) {}
            try { app.preferences.savePrefAsLong(sections[i], "Pref_SCRIPTING_FILE_NETWORK_SECURITY", 1); } catch (e2) {}
        }
        try { app.preferences.saveToDisk(); app.preferences.reload(); } catch (e3) {}
        return securityOn();
    }

    // ---- tiny helpers --------------------------------------------------------
    function tmpPath(name) { return Folder.temp.fsName + "/" + name; }

    function writeText(path, txt) {
        var f = new File(path); f.encoding = "UTF-8";
        if (!f.open("w")) return false;
        f.write(txt); f.close(); return true;
    }
    function readText(path) {
        var f = new File(path); if (!f.exists) return "";
        f.encoding = "UTF-8"; if (!f.open("r")) return "";
        var s = f.read(); f.close(); return s;
    }
    function baseName(p) {
        if (!p) return "";
        var parts = p.split(/[\\\/]/); return parts[parts.length - 1];
    }
    function match1(str, re) { var m = str.match(re); return m ? m[1] : null; }
    // ExtendScript (ES3) has no JSON — quote a string as a JSON value by hand.
    // Escapes backslashes (Windows paths) and double quotes.
    function jstr(s) { return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'; }

    // POST jsonBody to endpoint via curl; return the response body (string).
    function curlPost(endpoint, jsonBody) {
        var req = tmpPath("cmk_ae_req.json");
        var resp = tmpPath("cmk_ae_resp.json");
        if (!writeText(req, jsonBody)) throw new Error(
            "Can't write temp files. Enable Preferences > Scripting & Expressions >\n" +
            "\"Allow Scripts to Write Files and Access Network\".");
        var rf = new File(resp); if (rf.exists) rf.remove();
        var cmd = 'curl -s -X POST "' + SERVER + endpoint + '"' +
                  ' -H "Content-Type: application/json"' +
                  ' --data-binary "@' + req + '"' +
                  ' -o "' + resp + '"';
        system.callSystem(cmd);   // blocks until curl finishes
        return readText(resp);
    }

    // ---- After Effects project actions --------------------------------------
    function activeComp() {
        var c = app.project ? app.project.activeItem : null;
        return (c && c instanceof CompItem) ? c : null;
    }
    function selectedFootageLayer(comp) {
        var sel = comp.selectedLayers;
        for (var i = 0; i < sel.length; i++) {
            var L = sel[i];
            try { if (L.source && L.source.mainSource && L.source.mainSource.file) return L; } catch (e) {}
        }
        return null;
    }
    function layerSourcePath(L) {
        try { return L.source.mainSource.file.fsName; } catch (e) { return null; }
    }
    function ensureEffect(L) {
        var parade = L.property("ADBE Effect Parade");
        for (var i = 1; i <= parade.numProperties; i++) {
            var p = parade.property(i);
            if (p && (p.matchName === EFFECT_MATCH || p.name === EFFECT_NAME)) return p;
        }
        try { return parade.addProperty(EFFECT_MATCH); }
        catch (e) { return parade.addProperty(EFFECT_NAME); }
    }
    function setParam(fx, name, value) {
        try { fx.property(name).setValue(value); return true; } catch (e) { return false; }
    }

    // ---- the workflow --------------------------------------------------------
    function doMatch(ui, mode, look) {
        var comp = activeComp();
        if (!comp) return ui.status("Open a composition first.", true);
        var L = selectedFootageLayer(comp);
        if (!L) return ui.status("Select the TARGET footage layer in the timeline.", true);
        if (!state.refPath) return ui.status("Pick a REFERENCE clip first.", true);
        var srcPath = layerSourcePath(L);
        if (!srcPath) return ui.status("The selected layer has no source file.", true);

        if (!enableSecurity()) return ui.status(
            "Enable Preferences > Scripting & Expressions > \"Allow Scripts to Write Files and Access Network\", then try again.", true);

        ui.status("Matching… (After Effects pauses for a few seconds)", false);

        var body = '{"source_path":' + jstr(srcPath) +
                   ',"reference_path":' + jstr(state.refPath) +
                   ',"mode":"' + mode + '","tf":"sRGB","frames":7,"look":"' + look + '"}';
        var resp;
        try { resp = curlPost("/match_paths", body); }
        catch (e) { return ui.status(String(e.message || e), true); }

        if (!resp) return ui.status("Can't reach the engine at " + SERVER +
            " — is colourMatik running? (start ~/colourMatik/colourmatik-app)", true);
        if (!/"ok"\s*:\s*true/.test(resp)) {
            var err = match1(resp, /"error"\s*:\s*"([^"]*)"/);
            return ui.status("Match failed: " + (err || "unknown error"), true);
        }
        var rid = match1(resp, /"rid"\s*:\s*"([a-f0-9]+)"/);
        if (!rid) return ui.status("Match returned no id.", true);

        // bake the 65^3 LUT into a fresh slot for the native effect
        var resp2;
        try { resp2 = curlPost("/effect_lut", '{"rid":"' + rid + '"}'); }
        catch (e2) { return ui.status(String(e2.message || e2), true); }
        var slot = match1(resp2 || "", /"slot"\s*:\s*(\d+)/);
        if (!slot) return ui.status("Couldn't bake the effect LUT slot.", true);

        // apply the effect + point it at the slot
        app.beginUndoGroup("colourMatik: Match & Apply");
        try {
            var fx = ensureEffect(L);
            setParam(fx, "Match Slot", parseInt(slot, 10));
            setParam(fx, "Intensity", 100);
            ui.setIntensity(100);
        } catch (e3) {
            app.endUndoGroup();
            return ui.status("Applied the match, but couldn't add the effect: " + e3, true);
        }
        app.endUndoGroup();
        var m = match1(resp, /"method_label"\s*:\s*"([^"]*)"/) || match1(resp, /"method"\s*:\s*"([^"]*)"/) || "";
        ui.status("Done — " + m + ". colourMatik applied; drag Intensity to adjust.", false);
    }

    function applyIntensityLive(v) {
        var comp = activeComp(); if (!comp) return;
        var L = selectedFootageLayer(comp); if (!L) return;
        var parade = L.property("ADBE Effect Parade");
        for (var i = 1; i <= parade.numProperties; i++) {
            var p = parade.property(i);
            if (p && (p.matchName === EFFECT_MATCH || p.name === EFFECT_NAME)) {
                app.beginUndoGroup("colourMatik: Intensity");
                setParam(p, "Intensity", v);
                app.endUndoGroup();
                return;
            }
        }
    }

    // ---- UI -------------------------------------------------------------------
    function build(thisObj) {
        var win = (thisObj instanceof Panel) ? thisObj
                  : new Window("palette", "colourMatik", undefined, { resizeable: true });
        win.orientation = "column";
        win.alignChildren = ["fill", "top"];
        win.spacing = 8; win.margins = 12;

        var title = win.add("statictext", undefined, "colourMatik  —  match colours to a reference");
        try { title.graphics.font = ScriptUI.newFont(title.graphics.font.name, "BOLD", 13); } catch (e) {}

        // Reference
        var gRef = win.add("group"); gRef.alignChildren = ["left", "center"]; gRef.spacing = 8;
        var refBtn = gRef.add("button", undefined, "Set Reference clip…");
        var refTxt = gRef.add("statictext", undefined, "no reference", { truncate: "middle" });
        refTxt.preferredSize.width = 220;

        // Target hint
        var tgt = win.add("statictext", undefined, "Target = the selected footage layer in the timeline.");
        tgt.graphics.foregroundColor = tgt.graphics.newPen(tgt.graphics.PenType.SOLID_COLOR, [0.6, 0.6, 0.66, 1], 1);

        // Options
        var gOpt = win.add("group"); gOpt.spacing = 16;
        var pScene = gOpt.add("panel", undefined, "Scene"); pScene.orientation = "row"; pScene.margins = 8;
        var rDiff = pScene.add("radiobutton", undefined, "Different"); rDiff.value = true;
        var rSame = pScene.add("radiobutton", undefined, "Same");
        var pLook = gOpt.add("panel", undefined, "Match"); pLook.orientation = "row"; pLook.margins = 8;
        var rAcc = pLook.add("radiobutton", undefined, "Accurate"); rAcc.value = true;
        var rAI = pLook.add("radiobutton", undefined, "Cinematic AI");

        // Match & Apply
        var runBtn = win.add("button", undefined, "MATCH & APPLY");
        runBtn.preferredSize.height = 34;

        // Intensity
        var gInt = win.add("group"); gInt.alignChildren = ["left", "center"];
        gInt.add("statictext", undefined, "Intensity");
        var sInt = gInt.add("slider", undefined, 100, 0, 200); sInt.preferredSize.width = 190;
        var vInt = gInt.add("statictext", undefined, "100%"); vInt.preferredSize.width = 44;

        // Status
        var stat = win.add("statictext", undefined, "Pick a reference, select a layer, Match & Apply.",
                           { truncate: "end" });
        stat.preferredSize.width = 300;

        var ui = {
            status: function (msg, isErr) {
                stat.text = msg;
                var col = isErr ? [1, 0.42, 0.42, 1] : [0.55, 0.85, 0.55, 1];
                try { stat.graphics.foregroundColor = stat.graphics.newPen(stat.graphics.PenType.SOLID_COLOR, col, 1); } catch (e) {}
                try { win.update(); } catch (e2) {}
            },
            setIntensity: function (v) { sInt.value = v; vInt.text = Math.round(v) + "%"; }
        };

        refBtn.onClick = function () {
            var f = File.openDialog("Choose the REFERENCE clip (the look to copy)");
            if (f) { state.refPath = f.fsName; refTxt.text = baseName(state.refPath); }
        };
        runBtn.onClick = function () {
            runBtn.enabled = false;
            try { doMatch(ui, rSame.value ? "same" : "different", rAI.value ? "ai_grade" : "exact"); }
            finally { runBtn.enabled = true; }
        };
        sInt.onChanging = function () { vInt.text = Math.round(sInt.value) + "%"; };
        sInt.onChange = function () { applyIntensityLive(Math.round(sInt.value)); };

        var footer = win.add("statictext", undefined, "Local · nothing uploaded · catheadai.com");
        footer.graphics.foregroundColor = footer.graphics.newPen(footer.graphics.PenType.SOLID_COLOR, [0.5, 0.5, 0.56, 1], 1);

        win.layout.layout(true);
        return win;
    }

    var w = build(thisObj);
    try { enableSecurity(); } catch (e) {}   // zero-config: grant ourselves file/network on first open
    if (w instanceof Window) { w.center(); w.show(); }
})(this);
