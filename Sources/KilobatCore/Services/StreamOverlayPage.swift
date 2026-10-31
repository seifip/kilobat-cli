extension StreamOverlay {
    /// The overlay: a transparent page with one pill. The bat at the start is the status, as in Kilobat's Health:
    /// blue and smiling when the line is good, violet when it's slow, rose and frowning when it's poor.
    /// Options go in the URL: `?show=ping,jitter,loss,graph,speed&theme=dark|light|clear&size=s|m|l`.
    /// With Pro, `brand=0` hides the wordmark and `face=0` shows a plain dot instead of the bat.
    /// A game target names its data center on the pill ("CS2 · Frankfurt"); `server=0` hides it.
    static let page = #"""
    <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Kilobat overlay</title>
    <style>
    :root { --bg: rgba(12, 12, 19, 0.78); --edge: rgba(255, 255, 255, 0.10); --shine: rgba(255, 255, 255, 0.06); --text: #f1f3fc; --muted: #9ea3ba; --good: #66b3fa; --slow: #b096fa; --poor: #e08575; --eye: #0c0c13; }
    .light { --bg: rgba(255, 255, 255, 0.9); --edge: rgba(0, 0, 0, 0.08); --shine: rgba(255, 255, 255, 0.6); --text: #1c1d26; --muted: #6e7287; --good: #2f80e0; --slow: #7a5cf0; --poor: #c8553f; --eye: #ffffff; }
    html, body { margin: 0; background: transparent; overflow: hidden; }
    body { font: 600 15px/1 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; color: var(--text); font-variant-numeric: tabular-nums; -webkit-font-smoothing: antialiased; }
    .pill { --status: var(--muted); display: inline-flex; align-items: center; gap: 13px; padding: 9px 15px 9px 11px; margin: 8px; border-radius: 13px;
            background: var(--bg); box-shadow: inset 0 1px 0 var(--shine), 0 0 0 1px var(--edge), 0 6px 18px rgba(0, 0, 0, 0.22);
            backdrop-filter: blur(14px) saturate(1.3); -webkit-backdrop-filter: blur(14px) saturate(1.3); }
    .clear .pill { background: none; box-shadow: none; backdrop-filter: none; -webkit-backdrop-filter: none; text-shadow: 0 1px 2px rgba(0,0,0,.8), 0 0 8px rgba(0,0,0,.45); }
    .s .pill { font-size: 12px; gap: 10px; padding: 6px 11px 6px 8px; } .l .pill { font-size: 19px; gap: 16px; padding: 12px 19px 12px 14px; }
    .group { display: flex; align-items: baseline; gap: 4px; white-space: nowrap; }
    .rule { width: 1px; align-self: stretch; margin: 2px 0; background: var(--edge); }
    .face { width: 1.85em; height: 1.65em; flex: none; filter: drop-shadow(0 0 .35em color-mix(in srgb, var(--status) 55%, transparent)); }
    .face .body { fill: var(--status); transition: fill .4s; }
    .face .eye { fill: var(--eye); } .face .mouth { stroke: var(--eye); stroke-width: 1.4; stroke-linecap: round; fill: none; transition: d .4s; }
    .dot { width: .62em; height: .62em; border-radius: 50%; background: var(--status); box-shadow: 0 0 .55em var(--status); align-self: center; }
    .big { font-size: 1.4em; font-weight: 700; letter-spacing: -0.025em; min-width: 1.6em; text-align: right; }
    .unit, .label { color: var(--muted); font-weight: 500; font-size: .78em; }
    .value { min-width: 2.6em; }
    svg.graph { width: 6.2em; height: 1.55em; overflow: visible; }
    .graph .line { stroke: var(--status); transition: stroke .4s; } .graph .area { fill: var(--status); opacity: .16; transition: fill .4s; }
    .where { color: var(--muted); font-size: .74em; font-weight: 600; white-space: nowrap; margin-right: -4px; }
    .brand { color: var(--muted); font-size: .7em; font-weight: 700; letter-spacing: .02em; opacity: .85; }
    .hidden { display: none !important; }
    </style></head>
    <body><div class="pill" id="pill">
      <svg class="face" id="face" viewBox="0 0 30 27" aria-hidden="true">
        <path class="body" d="M1.2 5.9 Q6 14 10.2 9.7 L10.8 3.2 L15 6.8 L19.2 3.2 L19.8 9.7 Q24 14 28.8 5.9 L30 20.3 Q25.5 13.2 20.7 19.4 Q19.5 24.3 15 25.4 Q10.5 24.3 9.3 19.4 Q4.5 13.2 0 20.3 Z"/>
        <circle class="eye" cx="12.6" cy="13.5" r="1.1"/><circle class="eye" cx="17.4" cy="13.5" r="1.1"/>
        <path class="mouth" id="mouth" d="M12.3 17.8 Q15 20.3 17.7 17.8"/>
      </svg>
      <span class="dot hidden" id="dot"></span>
      <span class="where hidden" id="where"></span>
      <div class="group" id="ping"><span class="big" id="pingValue">—</span><span class="unit">ms</span></div>
      <div class="rule" id="rule1"></div>
      <div class="group" id="jitter"><span class="label">jitter</span><span class="value" id="jitterValue">—</span></div>
      <div class="group" id="loss"><span class="label">loss</span><span class="value" id="lossValue">—</span></div>
      <svg class="graph" id="graph" viewBox="0 0 100 24" preserveAspectRatio="none"><path class="area" id="area"/><path class="line" id="line" fill="none" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/></svg>
      <div class="group hidden" id="speed"><span class="label">↓</span><span class="value" id="down">—</span><span class="label">↑</span><span class="value" id="up">—</span></div>
      <span class="brand" id="brand">kilobat</span>
    </div>
    <script>
    const query = new URLSearchParams(location.search);
    const show = (query.get("show") || "ping,jitter,loss,graph").split(",");
    const $ = (id) => document.getElementById(id);
    for (const id of ["jitter", "loss", "graph", "speed"]) $(id).classList.toggle("hidden", !show.includes(id));
    $("rule1").classList.toggle("hidden", !show.includes("jitter") && !show.includes("loss"));
    document.body.classList.add(query.get("theme") || "dark", query.get("size") || "m");
    const rate = (b) => b == null ? "—" : b >= 1e6 ? (b / 1e6).toFixed(1) + " MB/s" : b >= 1e3 ? Math.round(b / 1e3) + " KB/s" : Math.round(b) + " B/s";
    const mouths = { good: "M12.3 17.8 Q15 20.3 17.7 17.8", slow: "M12.4 18.6 Q15 18.6 17.6 18.6", poor: "M12.3 19.6 Q15 17 17.7 19.6" };
    async function tick() {
      let d;
      try { d = await (await fetch("data.json", { cache: "no-store" })).json(); } catch { $("pingValue").textContent = "—"; return; }
      // Unbranded only when the app says Pro allows it; the free overlay keeps the name.
      $("brand").classList.toggle("hidden", d.unbrandedAllowed && query.get("brand") === "0");
      const plain = d.unbrandedAllowed && query.get("face") === "0";
      $("face").classList.toggle("hidden", plain); $("dot").classList.toggle("hidden", !plain);
      $("where").textContent = d.label || ""; $("where").classList.toggle("hidden", !d.label || query.get("server") === "0");
      const ping = d.pingMs, loss = d.lossPercent ?? 0, jitter = d.jitterMs ?? 0;
      const state = ping == null || loss >= 5 || ping > 150 ? "poor" : loss > 0 || ping > 60 || jitter > 20 ? "slow" : "good";
      $("pill").style.setProperty("--status", `var(--${state})`);
      $("mouth").setAttribute("d", mouths[state]);
      $("pingValue").textContent = ping == null ? "—" : Math.round(ping);
      $("jitterValue").textContent = d.jitterMs == null ? "—" : Math.round(d.jitterMs) + " ms";
      $("lossValue").textContent = d.lossPercent == null ? "—" : Math.round(loss) + "%";
      // A rare spike runs off the top instead of flattening the rest.
      const h = d.history || [], ok = h.filter((v) => v != null), top = Math.min(400, Math.max(40, ...ok)) * 1.15;
      let line = "", started = false;
      h.forEach((v, i) => { const x = (i / Math.max(1, h.length - 1)) * 100; if (v == null) { started = false; return; } const y = Math.max(1, 24 - (v / top) * 22); line += (started ? " L" : " M") + x.toFixed(1) + " " + y.toFixed(1); started = true; });
      $("line").setAttribute("d", line);
      $("area").setAttribute("d", line ? line + " L100 24 L0 24 Z" : "");
      if (d.downloadBytesPerSecond != null) { $("down").textContent = rate(d.downloadBytesPerSecond); $("up").textContent = rate(d.uploadBytesPerSecond); }
    }
    tick(); setInterval(tick, 1000);
    </script></body></html>
    """#
}
