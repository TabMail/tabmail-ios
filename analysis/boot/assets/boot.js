/* TabMail iOS — Boot/Foreground/NSE flow analysis — shared interactive engine.
   Dependency-free. A page defines BOOT_DATA and calls BootFlow.render(BOOT_DATA). */
(function () {
  "use strict";

  const KIND_LABEL = {
    main: "Blocks main / UI thread",
    mainlite: "Small main-thread work",
    dbw: "GRDB write (serialized)",
    dbr: "GRDB read",
    cpu: "Background CPU / actor",
    net: "Network · IMAP · HTTP",
    llm: "LLM backend call",
    ml: "CoreML load / FTS open",
    defer: "Deferred · fire-and-forget",
  };
  const KIND_ICON = {
    main: "■", mainlite: "▫", dbw: "✎", dbr: "◔", cpu: "⚙",
    net: "☁", llm: "✦", ml: "◆", defer: "⋯",
  };
  const BLOCKING_KINDS = new Set(["main", "mainlite"]);

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"]/g, c =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  }
  function el(tag, cls, html) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    return e;
  }
  function fmtMs(ms) {
    if (ms == null) return "—";
    if (ms >= 1000) return (ms / 1000).toFixed(ms % 1000 === 0 ? 0 : 1) + "s";
    return ms + "ms";
  }

  const BootFlow = {
    render(cfg) {
      this.cfg = cfg;
      document.title = cfg.docTitle || cfg.title;
      const root = document.getElementById("flow-root");

      // index jobs by id
      this.jobById = {};
      cfg.jobs.forEach(j => { this.jobById[j.id] = j; });
      this.activeLanes = new Set(cfg.lanes.map(l => l.id));
      this.blockMode = false;
      this.optMode = false;

      root.appendChild(this._hero());
      if (cfg.callouts) cfg.callouts.forEach(c => root.appendChild(this._callout(c)));

      const sec = el("div", "section");
      sec.appendChild(el("h2", null, "Job timeline · concurrency map"));
      sec.appendChild(el("div", "desc",
        "Swimlanes are execution contexts; bars are jobs positioned by approximate start &amp; duration. " +
        "Click any bar for file:line, what it does, and whether it blocks the main thread. " +
        "Bars marked ★ have an optimization note. Short bars are widened to a readable minimum, so width ≠ exact time."));
      sec.appendChild(this._controls());
      sec.appendChild(this._gantt());
      sec.appendChild(this._legend());
      sec.appendChild(el("div", "note",
        "Timings are architectural estimates from the code paths (not a profiler trace), except where a number is cited from device logs. " +
        "To get real numbers, read the <code>BackgroundSyncLogger</code> <code>stepLog/fgStep</code> lines and <code>MainActorStallDetector</code> output on a Release/TestFlight build."));
      root.appendChild(sec);

      if (cfg.hotspots && cfg.hotspots.length) {
        const hs = el("div", "section");
        hs.appendChild(el("h2", null, "Optimization hotspots"));
        hs.appendChild(el("div", "desc", "Ranked by impact on perceived boot / foreground latency. Click a code ref to highlight the job above."));
        hs.appendChild(this._hotspots());
        root.appendChild(hs);
      }

      const tb = el("div", "section");
      tb.appendChild(el("h2", null, "All jobs (raw)"));
      const det = el("details", "raw");
      det.appendChild(el("summary", null, "Show full job table (" + cfg.jobs.length + " jobs)"));
      const sx = el("div", "scrollx");
      sx.appendChild(this._table());
      det.appendChild(sx);
      tb.appendChild(det);
      root.appendChild(tb);

      root.appendChild(this._drawer());
    },

    _hero() {
      const c = this.cfg;
      const h = el("div", "hero");
      h.innerHTML =
        '<span class="pill ' + esc(c.flavor) + '">' + esc(c.kicker) + '</span>' +
        "<h1>" + esc(c.title) + "</h1>" +
        '<div class="sub">' + c.sub + "</div>";
      return h;
    },

    _callout(c) {
      const d = el("div", "callout " + (c.tip ? "tip" : ""));
      d.innerHTML = "<b>" + c.title + "</b> " + c.body +
        (c.why ? '<div class="why">' + c.why + "</div>" : "");
      return d;
    },

    _controls() {
      const wrap = el("div", "controls");
      // lane filters
      const g1 = el("div", "grp");
      g1.appendChild(el("span", "lbl", "Lanes"));
      this.cfg.lanes.forEach(l => {
        const chip = el("span", "chip", '<span class="dot k-' + l.kindHint + '"></span>' + esc(l.label));
        chip.onclick = () => {
          if (this.activeLanes.has(l.id)) { this.activeLanes.delete(l.id); chip.classList.add("off"); }
          else { this.activeLanes.add(l.id); chip.classList.remove("off"); }
          this._renderTracks();
        };
        g1.appendChild(chip);
      });
      wrap.appendChild(g1);

      // modes
      const g2 = el("div", "grp");
      g2.appendChild(el("span", "lbl", "Highlight"));
      const cBlock = el("span", "chip toggle warnmode", "● Blocking main thread");
      cBlock.onclick = () => { this.blockMode = !this.blockMode; cBlock.classList.toggle("on", this.blockMode); this._applyHighlight(); };
      const cOpt = el("span", "chip toggle optmode", "★ Optimization targets");
      cOpt.onclick = () => { this.optMode = !this.optMode; cOpt.classList.toggle("on", this.optMode); this._applyHighlight(); };
      g2.appendChild(cBlock); g2.appendChild(cOpt);
      wrap.appendChild(g2);
      return wrap;
    },

    _scale(ms) { return ms * this.cfg.pxPerMs; },

    _gantt() {
      const c = this.cfg;
      const width = this._scale(c.maxTime);
      const g = el("div", "gantt");
      const wrap = el("div", "gantt-wrap");

      // labels column
      const labs = el("div", "gantt-labels");
      labs.appendChild(el("div", "lab axis-sp", "time →"));
      if (c.phases && c.phases.length) labs.appendChild(el("div", "lab phase-sp", "phase"));
      c.lanes.forEach(l => {
        labs.appendChild(el("div", "lab", '<span class="swatch k-' + l.kindHint + '"></span>' + esc(l.label)));
      });
      wrap.appendChild(labs);

      // scroll + inner
      const scroll = el("div", "gantt-scroll");
      const inner = el("div", "gantt-inner");
      inner.style.width = width + "px";

      // axis
      const axis = el("div", "axis-row");
      const step = c.gridStep;
      for (let t = 0; t <= c.maxTime; t += step) {
        const tick = el("div", "axis-tick");
        tick.style.left = this._scale(t) + "px";
        tick.appendChild(el("span", null, fmtMs(t)));
        axis.appendChild(tick);
      }
      inner.appendChild(axis);

      // phases
      if (c.phases && c.phases.length) {
        const prow = el("div", "phase-row");
        c.phases.forEach((p, i) => {
          const b = el("div", "phase-band", esc(p.label));
          b.style.left = this._scale(p.start) + "px";
          b.style.width = Math.max(this._scale(p.end - p.start), 30) + "px";
          b.style.background = p.color || "rgba(255,255,255,.04)";
          prow.appendChild(b);
        });
        inner.appendChild(prow);
      }

      this._tracksHost = el("div", "tracks");
      inner.appendChild(this._tracksHost);
      scroll.appendChild(inner);
      wrap.appendChild(scroll);
      g.appendChild(wrap);
      this._labsHost = labs;
      this._innerWidth = width;
      // initial tracks
      setTimeout(() => this._renderTracks(), 0);
      return g;
    },

    _renderTracks() {
      const c = this.cfg;
      const host = this._tracksHost;
      host.innerHTML = "";
      // rebuild label rows to match active lanes
      // (keep axis + phase spacers, drop lane labels then re-add)
      const labs = this._labsHost;
      [...labs.querySelectorAll(".lab:not(.axis-sp):not(.phase-sp)")].forEach(n => n.remove());

      c.lanes.forEach(lane => {
        if (!this.activeLanes.has(lane.id)) return;
        labs.appendChild(el("div", "lab", '<span class="swatch k-' + lane.kindHint + '"></span>' + esc(lane.label)));
        const track = el("div", "track");
        // gridlines
        for (let t = 0; t <= c.maxTime; t += c.gridStep) {
          const gl = el("div", "gridline"); gl.style.left = this._scale(t) + "px"; track.appendChild(gl);
        }
        // bars
        c.jobs.filter(j => j.lane === lane.id).forEach(j => track.appendChild(this._bar(j)));
        // markers that belong to this lane row? markers are global overlay; add to first track only
        host.appendChild(track);
      });

      // global markers overlay (spanning all tracks): append absolute lines into host
      if (c.markers) {
        host.style.position = "relative";
        c.markers.forEach(m => {
          const line = el("div", "marker");
          line.style.left = this._scale(m.t) + "px";
          line.style.background = m.color || "#fff";
          line.innerHTML = '<span class="ml" style="background:' + (m.color || "#fff") + ';color:' + (m.text || "#000") + '">' + esc(m.label) + "</span>";
          host.appendChild(line);
        });
      }
      this._applyHighlight();
    },

    _bar(j) {
      const b = el("div", "bar k-" + j.kind + (j.opt ? " opt" : ""));
      b.style.left = this._scale(j.start) + "px";
      b.style.width = Math.max(this._scale(j.dur), 58) + "px";
      b.dataset.id = j.id;
      b.tabIndex = 0;
      b.innerHTML = '<span class="ico">' + KIND_ICON[j.kind] + "</span>" + esc(j.label);
      b.title = j.label + "  ·  " + fmtMs(j.start) + "–" + fmtMs(j.start + j.dur) + "  ·  " + KIND_LABEL[j.kind];
      const open = () => this._openJob(j.id);
      b.onclick = open;
      b.onkeydown = e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); open(); } };
      return b;
    },

    _applyHighlight() {
      const bars = this._tracksHost.querySelectorAll(".bar");
      bars.forEach(b => {
        const j = this.jobById[b.dataset.id];
        b.classList.remove("dim", "pulse");
        if (this.blockMode && !BLOCKING_KINDS.has(j.kind)) b.classList.add("dim");
        if (this.optMode) {
          if (j.opt) b.classList.add("pulse");
          else if (!this.blockMode) b.classList.add("dim");
        }
      });
    },

    _legend() {
      const l = el("div", "legend");
      Object.keys(KIND_LABEL).forEach(k => {
        l.appendChild(el("div", "li", '<span class="dot k-' + k + '"></span>' + esc(KIND_LABEL[k])));
      });
      return l;
    },

    _hotspots() {
      const grid = el("div", "hotspots");
      this.cfg.hotspots.forEach((h, i) => {
        const card = el("div", "hot " + (h.sev || "med"));
        let refs = "";
        if (h.jobs && h.jobs.length) {
          refs = '<div class="refs">' + h.jobs.map(id =>
            '<span class="r" data-id="' + esc(id) + '">' + esc((this.jobById[id] && this.jobById[id].file) || id) + "</span>").join("") + "</div>";
        }
        card.innerHTML =
          '<div class="ht"><span class="n">' + (i + 1) + '</span><h4>' + esc(h.title) + '</h4>' +
          '<span class="sev ' + (h.sev || "med") + '">' + esc(h.sev || "med") + "</span></div>" +
          '<div class="prob">' + h.problem + "</div>" +
          '<div class="fix"><div class="h">Proposed fix</div>' + h.fix + "</div>" + refs;
        card.querySelectorAll(".refs .r").forEach(r => {
          r.onclick = () => {
            const id = r.dataset.id;
            // make sure lane is visible
            const j = this.jobById[id];
            if (j) { this.activeLanes.add(j.lane); this._renderTracks(); this._openJob(id); }
          };
        });
        grid.appendChild(card);
      });
      return grid;
    },

    _table() {
      const t = el("table", "tbl");
      t.innerHTML = "<thead><tr><th>Job</th><th>Lane</th><th>Start</th><th>Dur</th><th>Main?</th><th>file:line</th></tr></thead>";
      const tb = el("tbody");
      [...this.cfg.jobs].sort((a, b) => a.start - b.start).forEach(j => {
        const lane = this.cfg.lanes.find(l => l.id === j.lane);
        const tr = el("tr");
        const blocks = BLOCKING_KINDS.has(j.kind);
        tr.innerHTML =
          "<td><span class='kdot k-" + j.kind + "'></span>" + esc(j.label) + (j.opt ? " ★" : "") + "</td>" +
          "<td>" + esc(lane ? lane.label : j.lane) + "</td>" +
          "<td>" + fmtMs(j.start) + "</td>" +
          "<td>" + fmtMs(j.dur) + "</td>" +
          "<td><span class='badge " + (blocks ? "block'>blocks" : "async'>async") + "</span></td>" +
          "<td class='t-file mono'>" + esc(j.file || "—") + "</td>";
        tr.onclick = () => this._openJob(j.id);
        tb.appendChild(tr);
      });
      t.appendChild(tb);
      return t;
    },

    _drawer() {
      const scrim = el("div", "drawer-scrim");
      const dr = el("div", "drawer");
      dr.innerHTML =
        '<div class="dh"><span class="kindtag"></span><h3></h3><span class="x">×</span></div>' +
        '<div class="db"></div>';
      scrim.onclick = () => this._closeJob();
      dr.querySelector(".x").onclick = () => this._closeJob();
      document.body.appendChild(scrim);
      document.body.appendChild(dr);
      this._scrim = scrim; this._dr = dr;
      document.addEventListener("keydown", e => { if (e.key === "Escape") this._closeJob(); });
      return el("span");
    },

    _openJob(id) {
      const j = this.jobById[id];
      if (!j) return;
      const lane = this.cfg.lanes.find(l => l.id === j.lane);
      const tag = this._dr.querySelector(".kindtag");
      tag.textContent = KIND_ICON[j.kind] + " " + KIND_LABEL[j.kind];
      tag.style.background = getComputedStyle(document.documentElement).getPropertyValue("--k-" + j.kind).trim() || "#444";
      if (j.kind === "mainlite") tag.style.color = "#241500";
      else tag.style.color = "#fff";
      this._dr.querySelector("h3").textContent = j.label;
      const blocks = BLOCKING_KINDS.has(j.kind);
      const db = this._dr.querySelector(".db");
      db.innerHTML =
        '<dl class="meta">' +
        "<dt>Lane</dt><dd>" + esc(lane ? lane.label : j.lane) + "</dd>" +
        "<dt>Window</dt><dd>" + fmtMs(j.start) + " – " + fmtMs(j.start + j.dur) + " (~" + fmtMs(j.dur) + ")</dd>" +
        "<dt>Main thread</dt><dd>" + (blocks ? "<b style='color:#ff9b9b'>YES — blocks UI</b>" : "No — runs off-main / suspends") + "</dd>" +
        (j.qos ? "<dt>QoS</dt><dd class='mono'>" + esc(j.qos) + "</dd>" : "") +
        (j.file ? "<dt>Code</dt><dd><span class='fileref mono'>" + esc(j.file) + "</span></dd>" : "") +
        "</dl>" +
        '<div class="body">' + (j.detail || "<p>—</p>") + "</div>" +
        (j.optimize ? '<div class="optbox"><div class="h">★ Optimization' +
          (j.optSev ? ' &nbsp;<span class="sev ' + j.optSev + '">' + j.optSev + "</span>" : "") +
          "</div>" + j.optimize + "</div>" : "");
      this._scrim.classList.add("open");
      this._dr.classList.add("open");
    },
    _closeJob() { this._scrim.classList.remove("open"); this._dr.classList.remove("open"); },
  };

  window.BootFlow = BootFlow;

  // Shared nav highlighter
  window.markNav = function (id) {
    document.querySelectorAll(".nav .links a").forEach(a => {
      a.classList.toggle("active", a.dataset.page === id);
    });
  };
})();
