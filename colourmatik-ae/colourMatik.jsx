// colourMatik — After Effects panel (ScriptUI).
// Same workflow AND look as the Premiere panel: pick a REFERENCE clip, select the
// TARGET layer, MATCH & APPLY. Calls the local engine (127.0.0.1:8765) via curl,
// adds the native "colourMatik" effect and points it at the freshly baked LUT slot.
// Intensity dials strength live (0-200%).
//
// AE has no UXP, so this is ExtendScript/ScriptUI with custom-drawn controls to
// mirror the Premiere panel's colours + layout as closely as ScriptUI allows.
// Networking uses the system `curl` via system.callSystem (macOS + Win10 17063+).
// by Sevki Bugra Ozbek - catheadai.com

(function (thisObj) {
    var SERVER = "http://127.0.0.1:8765";
    var EFFECT_MATCH = "catheadai colourMatik";
    var EFFECT_NAME = "colourMatik";
    var W = 300;                 // content width
    var state = { refPath: null, mode: "different", look: "exact" };

    // ---- palette (mirrors the Premiere panel) --------------------------------
    var C = {
        blue:  [0.078, 0.451, 0.902],   // #1473e6
        blue2: [0.306, 0.631, 0.969],   // #4ea1f7
        green: [0.200, 0.671, 0.373],   // #33ab5f
        gold:  [0.886, 0.639, 0.243],   // #e2a33e
        red:   [0.890, 0.282, 0.314],   // #e34850
        text:  [0.835, 0.835, 0.835],   // #d4d4d4
        sec:   [0.561, 0.561, 0.561],   // #8f8f8f
        line:  [0.239, 0.239, 0.239],   // #3d3d3d
        fld:   [0.106, 0.106, 0.118],   // field bg
        seg:   [0.145, 0.153, 0.176],   // segment bg
        white: [1, 1, 1]
    };
    function font(sz, bold) {
        try { return ScriptUI.newFont("Helvetica", bold ? "Bold" : "Regular", sz); }
        catch (e) { try { return ScriptUI.newFont("dialog", bold ? "Bold" : "Regular", sz); } catch (e2) { return undefined; } }
    }
    var F = { reg: font(12, false), bold: font(12, true), lbl: font(9, true), big: font(13, true), logo: font(15, true) };

    // ---- draw helpers --------------------------------------------------------
    function rect(g, x, y, w, h, col) { g.newPath(); g.rectPath(x, y, w, h); g.fillPath(g.newBrush(g.BrushType.SOLID_COLOR, col)); }
    function stroke(g, x, y, w, h, col) { g.newPath(); g.rectPath(x, y, w, h); g.strokePath(g.newPen(g.PenType.SOLID_COLOR, col, 1)); }
    function str(g, s, x, y, col, f) { g.drawString(s, g.newPen(g.PenType.SOLID_COLOR, col, 1), x, y, f || F.reg); }
    function strC(g, s, w, h, col, f) { f = f || F.reg; var m; try { m = g.measureString(s, f, w); } catch (e) { m = [g.measureString(s, f)[0], 14]; } str(g, s, (w - m[0]) / 2, (h - m[1]) / 2, col, f); }

    // ---- tiny io / net helpers ----------------------------------------------
    function tmpPath(n) { return Folder.temp.fsName + "/" + n; }
    function writeText(p, t) { var f = new File(p); f.encoding = "UTF-8"; if (!f.open("w")) return false; f.write(t); f.close(); return true; }
    function readText(p) { var f = new File(p); if (!f.exists) return ""; f.encoding = "UTF-8"; if (!f.open("r")) return ""; var s = f.read(); f.close(); return s; }
    function baseName(p) { if (!p) return ""; var a = p.split(/[\\\/]/); return a[a.length - 1]; }
    function m1(s, re) { var m = s.match(re); return m ? m[1] : null; }
    function jstr(s) { return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'; }

    // self-grant AE's file/network permission (best-effort; the installer also sets it)
    function enableSecurity() {
        var secs = ["Main Pref Section v2", "Main Pref Section"], on = false;
        for (var i = 0; i < secs.length; i++) {
            try { if (app.preferences.getPrefAsLong(secs[i], "Pref_SCRIPTING_FILE_NETWORK_SECURITY", PREFType.PREF_Type_MACHINE_INDEPENDENT) === 1) on = true; } catch (e) {}
        }
        if (on) return true;
        for (var j = 0; j < secs.length; j++) {
            try { app.preferences.savePrefAsLong(secs[j], "Pref_SCRIPTING_FILE_NETWORK_SECURITY", 1, PREFType.PREF_Type_MACHINE_INDEPENDENT); } catch (e2) {}
        }
        try { app.preferences.saveToDisk(); app.preferences.reload(); } catch (e3) {}
        try { return app.preferences.getPrefAsLong("Main Pref Section v2", "Pref_SCRIPTING_FILE_NETWORK_SECURITY", PREFType.PREF_Type_MACHINE_INDEPENDENT) === 1; } catch (e4) { return false; }
    }
    function curlPost(endpoint, body) {
        var req = tmpPath("cmk_ae_req.json"), resp = tmpPath("cmk_ae_resp.json");
        if (!writeText(req, body)) throw new Error("Can't write temp files (enable AE scripting/network permission).");
        var rf = new File(resp); if (rf.exists) rf.remove();
        system.callSystem('curl -s -X POST "' + SERVER + endpoint + '" -H "Content-Type: application/json" --data-binary "@' + req + '" -o "' + resp + '"');
        return readText(resp);
    }

    // ---- AE project actions --------------------------------------------------
    function activeComp() { var c = app.project ? app.project.activeItem : null; return (c && c instanceof CompItem) ? c : null; }
    function selLayer(comp) {
        var s = comp.selectedLayers;
        for (var i = 0; i < s.length; i++) { try { if (s[i].source && s[i].source.mainSource && s[i].source.mainSource.file) return s[i]; } catch (e) {} }
        return null;
    }
    function srcPathOf(L) { try { return L.source.mainSource.file.fsName; } catch (e) { return null; } }
    function ensureEffect(L) {
        var par = L.property("ADBE Effect Parade");
        for (var i = 1; i <= par.numProperties; i++) { var p = par.property(i); if (p && (p.matchName === EFFECT_MATCH || p.name === EFFECT_NAME)) return p; }
        try { return par.addProperty(EFFECT_MATCH); } catch (e) { return par.addProperty(EFFECT_NAME); }
    }
    function setP(fx, n, v) { try { fx.property(n).setValue(v); return true; } catch (e) { return false; } }

    // ---- workflow ------------------------------------------------------------
    function doMatch(ui) {
        var comp = activeComp(); if (!comp) return ui.status("Open a composition first.", "error");
        var L = selLayer(comp); if (!L) return ui.status("Select the TARGET footage layer in the timeline.", "error");
        if (!state.refPath) return ui.status("Pick a REFERENCE clip first.", "error");
        var sp = srcPathOf(L); if (!sp) return ui.status("The selected layer has no source file.", "error");
        if (!enableSecurity()) return ui.status("Enable AE Preferences > Scripting & Expressions > Allow Scripts to Write Files and Access Network.", "error");

        ui.status("Matching… After Effects pauses for a few seconds.", "busy");
        var body = '{"source_path":' + jstr(sp) + ',"reference_path":' + jstr(state.refPath) +
                   ',"mode":"' + state.mode + '","tf":"sRGB","frames":7,"look":"' + state.look + '"}';
        var resp; try { resp = curlPost("/match_paths", body); } catch (e) { return ui.status(String(e.message || e), "error"); }
        if (!resp) return ui.status("Can't reach the engine at " + SERVER + " — is colourMatik running?", "error");
        if (!/"ok"\s*:\s*true/.test(resp)) return ui.status("Match failed: " + (m1(resp, /"error"\s*:\s*"([^"]*)"/) || "unknown"), "error");
        var rid = m1(resp, /"rid"\s*:\s*"([a-f0-9]+)"/); if (!rid) return ui.status("Match returned no id.", "error");
        var resp2; try { resp2 = curlPost("/effect_lut", '{"rid":"' + rid + '"}'); } catch (e2) { return ui.status(String(e2.message || e2), "error"); }
        var slot = m1(resp2 || "", /"slot"\s*:\s*(\d+)/); if (!slot) return ui.status("Couldn't bake the effect LUT slot.", "error");

        app.beginUndoGroup("colourMatik: Match & Apply");
        try { var fx = ensureEffect(L); setP(fx, "Match Slot", parseInt(slot, 10)); setP(fx, "Intensity", 100); ui.setIntensity(100); }
        catch (e3) { app.endUndoGroup(); return ui.status("Applied the match, but couldn't add the effect: " + e3, "error"); }
        app.endUndoGroup();
        var lbl = m1(resp, /"method_label"\s*:\s*"([^"]*)"/) || m1(resp, /"method"\s*:\s*"([^"]*)"/) || "";
        ui.status("Done — " + lbl + ". Drag Intensity to adjust (live).", "done");
    }
    function applyIntensityLive(v) {
        var comp = activeComp(); if (!comp) return; var L = selLayer(comp); if (!L) return;
        var par = L.property("ADBE Effect Parade");
        for (var i = 1; i <= par.numProperties; i++) { var p = par.property(i); if (p && (p.matchName === EFFECT_MATCH || p.name === EFFECT_NAME)) { app.beginUndoGroup("colourMatik: Intensity"); setP(p, "Intensity", v); app.endUndoGroup(); return; } }
    }

    // ---- custom-drawn controls ----------------------------------------------
    // a flat clickable "button" via iconbutton + onDraw
    function makeBtn(parent, w, h, drawFn, onClick) {
        var b = parent.add("iconbutton", undefined, undefined, { style: "toolbutton" });
        b.preferredSize = [w, h];
        b.onDraw = function () { try { drawFn(this.graphics, this.size[0], this.size[1]); } catch (e) {} };
        if (onClick) b.onClick = onClick;
        return b;
    }
    // Force a custom control to repaint. onDraw isn't a notify-able event, so the
    // reliable trigger is re-assigning size (invalidates -> repaint); try a couple.
    function redraw(c) { try { c.size = c.size; } catch (e) {} try { c.notify("onDraw"); } catch (e2) {} }

    // ---- UI ------------------------------------------------------------------
    function build(thisObj) {
        var win = (thisObj instanceof Panel) ? thisObj : new Window("palette", "colourMatik", undefined, { resizeable: true });
        win.orientation = "column"; win.alignChildren = ["left", "top"]; win.spacing = 12; win.margins = 14;

        // brand header: 3 colour bars + colourMatik
        makeBtn(win, W, 30, function (g, w, h) {
            var bx = 0, bw = 6, gap = 1, top = 6, bh = 18;
            rect(g, bx, top, bw, bh, C.blue2); rect(g, bx + bw + gap, top, bw, bh, C.green); rect(g, bx + 2 * (bw + gap), top, bw, bh, C.gold);
            var tx = 3 * (bw + gap) + 8;
            str(g, "colour", tx, 6, C.text, F.logo);
            var mw; try { mw = g.measureString("colour", F.logo)[0]; } catch (e) { mw = 46; }
            str(g, "Matik", tx + mw, 6, C.blue2, F.logo);
        });
        sep(win);

        function labelRow(t) { var s = win.add("statictext", undefined, t); s.graphics.foregroundColor = s.graphics.newPen(s.graphics.PenType.SOLID_COLOR, C.sec, 1); try { s.graphics.font = F.lbl; } catch (e) {} return s; }

        // Reference
        labelRow("REFERENCE — THE LOOK TO COPY");
        var refState = { name: "No clip selected", set: false };
        var refRow = win.add("group"); refRow.spacing = 8; refRow.alignChildren = ["left", "center"];
        makeBtn(refRow, 34, 30, function (g, w, h) { rect(g, 0, 0, w, h, C.fld); stroke(g, 0, 0, w, h, C.line); strC(g, "◉", w, h, C.blue2, F.big); }, function () {
            var f = File.openDialog("Choose the REFERENCE clip (the look to copy)");
            if (f) { state.refPath = f.fsName; refState.name = baseName(state.refPath); refState.set = true; redraw(refField); }
        });
        var refField = makeBtn(refRow, W - 34 - 8, 30, function (g, w, h) { rect(g, 0, 0, w, h, C.fld); stroke(g, 0, 0, w, h, C.line); str(g, refState.name, 10, (h - 12) / 2, refState.set ? C.green : C.sec, F.reg); });

        // Target
        labelRow("TARGET — THE SELECTED FOOTAGE LAYER");
        var tgt = win.add("statictext", undefined, "colourMatik uses the layer you select in the timeline.");
        tgt.graphics.foregroundColor = tgt.graphics.newPen(tgt.graphics.PenType.SOLID_COLOR, C.sec, 1);

        // segmented control (two options)
        function segmented(sel0, a, b, onSel) {
            var st = { sel: sel0 };
            var g = win.add("group"); g.spacing = 0; g.alignChildren = ["left", "center"];
            var halves = [];
            function drawHalf(idx, label) {
                return function (gr, w, h) {
                    var on = (st.sel === idx);
                    rect(gr, 0, 0, w, h, on ? C.blue : C.seg);
                    if (idx === 0) stroke(gr, 0, 0, w, h, C.line); else stroke(gr, 0, 0, w, h, C.line);
                    strC(gr, label, w, h, on ? C.white : C.sec, F.bold);
                };
            }
            var hw = W / 2;
            halves[0] = makeBtn(g, hw, 30, drawHalf(0, a), function () { st.sel = 0; redraw(halves[0]); redraw(halves[1]); onSel(0); });
            halves[1] = makeBtn(g, hw, 30, drawHalf(1, b), function () { st.sel = 1; redraw(halves[0]); redraw(halves[1]); onSel(1); });
            return st;
        }
        labelRow("SCENE");
        segmented(0, "Different scene", "Same scene", function (i) { state.mode = i === 0 ? "different" : "same"; });
        labelRow("MATCH TYPE");
        segmented(0, "Accurate", "Cinematic AI", function (i) { state.look = i === 0 ? "exact" : "ai_grade"; });

        // MATCH & APPLY (big blue)
        var runBtn = makeBtn(win, W, 38, function (g, w, h) { rect(g, 0, 0, w, h, C.blue); strC(g, "MATCH & APPLY", w, h, C.white, F.big); }, function () {
            runBtn.enabled = false; try { doMatch(ui); } finally { runBtn.enabled = true; }
        });

        // Intensity
        labelRow("INTENSITY");
        var iRow = win.add("group"); iRow.alignChildren = ["left", "center"]; iRow.spacing = 8;
        var sInt = iRow.add("slider", undefined, 100, 0, 200); sInt.preferredSize = [W - 56, 18];
        var vInt = iRow.add("statictext", undefined, "100%"); vInt.preferredSize.width = 48;
        vInt.graphics.foregroundColor = vInt.graphics.newPen(vInt.graphics.PenType.SOLID_COLOR, C.blue2, 1); try { vInt.graphics.font = F.bold; } catch (e) {}

        sep(win);
        // status
        var statText = "Pick a reference, select a layer, Match & Apply.";
        var statCol = C.sec;
        var statBox = makeBtn(win, W, 46, function (g, w, h) { rect(g, 0, 0, w, h, C.fld); stroke(g, 0, 0, w, h, C.line); str(g, statText, 10, 8, statCol, F.reg); });
        statBox.enabled = true;

        // footer
        var foot = win.add("statictext", undefined, "colourMatik · Local · nothing uploaded · catheadai.com");
        foot.graphics.foregroundColor = foot.graphics.newPen(foot.graphics.PenType.SOLID_COLOR, C.sec, 1);

        var ui = {
            status: function (msg, kind) { statText = msg; statCol = kind === "error" ? C.red : kind === "done" ? C.green : kind === "busy" ? C.blue2 : C.sec; redraw(statBox); },
            setIntensity: function (v) { sInt.value = v; vInt.text = Math.round(v) + "%"; }
        };
        sInt.onChanging = function () { vInt.text = Math.round(sInt.value) + "%"; };
        sInt.onChange = function () { applyIntensityLive(Math.round(sInt.value)); };

        win.onResizing = win.onResize = function () { this.layout.resize(); };
        win.layout.layout(true);
        return win;
    }
    function sep(win) { var p = win.add("panel"); p.alignment = ["fill", "top"]; p.preferredSize.height = 1; p.maximumSize.height = 1; }

    var w = build(thisObj);
    try { enableSecurity(); } catch (e) {}
    if (w instanceof Window) { w.center(); w.show(); }
})(this);
