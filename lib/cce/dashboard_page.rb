# WHY: The dashboard must be FULLY self-contained — the served HTML inlines all
#      CSS and JS and draws its own charts, with no external network, CDN, or
#      remote fonts/scripts, consistent with CCE's offline/local posture
#      (DASHBOARD-SPEC §6).
# WHAT: One frozen HTML document. Its inline script fetches `/api/metrics` (same
#       origin, loopback) and renders KPIs, the two north-stars with up/down
#       indicators, hand-drawn SVG charts, and the recent-searches table.
# RESPONSIBILITIES:
#   - Own the single-page HTML/CSS/JS payload.
#   - Deliberately NOT compute metrics (the API does) or bind sockets (Server does).

module CCE
  module Dashboard
    module Page
      # The complete, self-contained dashboard document.
      HTML = <<~'HTML'
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>CCE Dashboard — Code Context Engine</title>
          <style>
            :root {
              --bg: #f6f7f9; --panel: #ffffff; --ink: #1b1f24; --muted: #5b636e;
              --line: #e2e6eb; --accent: #2f6df6; --good: #1a9d5a; --bad: #d24b4b;
              --bar: #6ea8fe; --grid: #eef1f5;
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --bg: #14171c; --panel: #1c2027; --ink: #e9edf2; --muted: #9aa3af;
                --line: #2a2f37; --accent: #6ea8fe; --good: #45c17e; --bad: #f0776f;
                --bar: #3f6fd6; --grid: #232830;
              }
            }
            :root[data-theme="dark"] {
              --bg: #14171c; --panel: #1c2027; --ink: #e9edf2; --muted: #9aa3af;
              --line: #2a2f37; --accent: #6ea8fe; --good: #45c17e; --bad: #f0776f;
              --bar: #3f6fd6; --grid: #232830;
            }
            * { box-sizing: border-box; }
            body {
              margin: 0; background: var(--bg); color: var(--ink);
              font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            }
            header { padding: 24px 24px 8px; }
            h1 { font-size: 20px; margin: 0; }
            .sub { color: var(--muted); font-size: 13px; margin-top: 4px; }
            main { padding: 8px 24px 48px; max-width: 1100px; }
            .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin: 16px 0; }
            .card { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 16px; }
            .card .label { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .04em; }
            .card .value { font-size: 26px; font-weight: 650; margin-top: 6px; }
            .ns { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin: 8px 0 16px; }
            @media (max-width: 720px) { .ns { grid-template-columns: 1fr; } }
            .panel { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 18px; }
            .panel h2 { font-size: 15px; margin: 0 0 4px; }
            .panel .hint { color: var(--muted); font-size: 12px; margin-bottom: 12px; }
            .delta { display: flex; align-items: baseline; gap: 10px; margin: 6px 0 14px; }
            .delta .big { font-size: 34px; font-weight: 700; }
            .dir { font-size: 14px; font-weight: 650; padding: 2px 8px; border-radius: 999px; }
            .dir.up { color: var(--good); background: color-mix(in srgb, var(--good) 14%, transparent); }
            .dir.down { color: var(--bad); background: color-mix(in srgb, var(--bad) 14%, transparent); }
            .dir.flat { color: var(--muted); background: color-mix(in srgb, var(--muted) 14%, transparent); }
            .prior { color: var(--muted); font-size: 13px; }
            svg { width: 100%; height: auto; display: block; }
            .chart-label { fill: var(--muted); font-size: 10px; }
            table { width: 100%; border-collapse: collapse; font-size: 13px; }
            th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); }
            th { color: var(--muted); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: .04em; }
            td.num { text-align: right; font-variant-numeric: tabular-nums; }
            .pill { font-size: 11px; padding: 1px 7px; border-radius: 999px; }
            .pill.helpful { color: var(--good); background: color-mix(in srgb, var(--good) 14%, transparent); }
            .pill.not_helpful { color: var(--bad); background: color-mix(in srgb, var(--bad) 14%, transparent); }
            .pill.none { color: var(--muted); background: color-mix(in srgb, var(--muted) 12%, transparent); }
            .empty { text-align: center; padding: 64px 24px; color: var(--muted); }
            .empty .big { font-size: 20px; color: var(--ink); margin-bottom: 8px; }
            code { background: color-mix(in srgb, var(--muted) 12%, transparent); padding: 1px 6px; border-radius: 6px; }
            footer { color: var(--muted); font-size: 12px; padding: 0 24px 32px; }
          </style>
        </head>
        <body>
          <header>
            <h1>CCE Dashboard</h1>
            <div class="sub">Code Context Engine &middot; observability for token/cost savings &amp; retrieval quality</div>
          </header>
          <main id="app"><div class="empty"><div class="big">Loading…</div></div></main>
          <footer id="foot"></footer>

          <script>
            "use strict";
            const $ = (tag, attrs = {}, kids = []) => {
              const el = document.createElementNS(
                tag === "svg" || tag === "rect" || tag === "path" || tag === "line" || tag === "text" || tag === "g"
                  ? "http://www.w3.org/2000/svg" : "http://www.w3.org/1999/xhtml", tag);
              for (const [k, v] of Object.entries(attrs)) {
                if (k === "class") el.setAttribute("class", v);
                else if (k === "text") el.textContent = v;
                else el.setAttribute(k, v);
              }
              (Array.isArray(kids) ? kids : [kids]).forEach(k => k && el.appendChild(k));
              return el;
            };
            const fmtInt = n => (n || 0).toLocaleString("en-US");
            const fmtPct = x => (x == null ? "—" : (x * 100).toFixed(1) + "%");
            const fmt3 = x => (x == null ? "—" : Number(x).toFixed(3));
            const dirGlyph = d => d === "up" ? "↑ improving" : d === "down" ? "↓ degrading" : "→ flat";

            function barChart(data, valueFn, opts = {}) {
              const W = 520, H = 140, pad = { l: 8, r: 8, t: 10, b: 22 };
              const svg = $("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": opts.aria || "chart" });
              const vals = data.map(valueFn);
              const max = Math.max(1e-9, ...vals);
              const n = data.length || 1;
              const bw = (W - pad.l - pad.r) / n;
              data.forEach((d, i) => {
                const v = valueFn(d);
                const h = (H - pad.t - pad.b) * (v / max);
                const x = pad.l + i * bw;
                const y = H - pad.b - h;
                svg.appendChild($("rect", { x: x + bw * 0.15, y, width: bw * 0.7, height: Math.max(0, h), rx: 2, fill: "var(--bar)" }));
                if (n <= 12) svg.appendChild($("text", { x: x + bw / 2, y: H - 8, "text-anchor": "middle", class: "chart-label", text: d.date.slice(5) }));
              });
              return svg;
            }

            function lineChart(data, valueFn, opts = {}) {
              const W = 520, H = 140, pad = { l: 8, r: 8, t: 10, b: 22 };
              const svg = $("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": opts.aria || "chart" });
              const n = data.length;
              const max = Math.max(1e-9, ...data.map(valueFn));
              const iw = (W - pad.l - pad.r);
              const pts = data.map((d, i) => {
                const x = pad.l + (n <= 1 ? iw / 2 : (iw * i) / (n - 1));
                const y = H - pad.b - (H - pad.t - pad.b) * (valueFn(d) / max);
                return [x, y];
              });
              if (pts.length) {
                const dstr = pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" ");
                svg.appendChild($("path", { d: dstr, fill: "none", stroke: "var(--accent)", "stroke-width": 2 }));
                pts.forEach(p => svg.appendChild($("rect", { x: p[0] - 2, y: p[1] - 2, width: 4, height: 4, rx: 2, fill: "var(--accent)" })));
              }
              data.forEach((d, i) => { if (n <= 12) svg.appendChild($("text", { x: pts[i][0], y: H - 8, "text-anchor": "middle", class: "chart-label", text: d.date.slice(5) })); });
              return svg;
            }

            function kpi(label, value) {
              return $("div", { class: "card" }, [$("div", { class: "label", text: label }), $("div", { class: "value", text: value })]);
            }

            function northStar(title, hint, big, dir, priorText, chart) {
              return $("div", { class: "panel" }, [
                $("h2", { text: title }),
                $("div", { class: "hint", text: hint }),
                $("div", { class: "delta" }, [
                  $("div", { class: "big", text: big }),
                  $("div", { class: "dir " + dir, text: dirGlyph(dir) })
                ]),
                $("div", { class: "prior", text: priorText }),
                $("div", { style: "margin-top:12px" }, [chart])
              ]);
            }

            function render(m) {
              const app = document.getElementById("app");
              app.textContent = "";
              const t = m.totals;
              const hasData = t.searches > 0 || t.feedback > 0 || t.indexes > 0;
              if (!hasData) {
                app.appendChild($("div", { class: "empty" }, [
                  $("div", { class: "big", text: "No data yet" }),
                  $("div", { text: "Run some searches, then reload. Try: cce search \"…\" then cce feedback <id> --helpful" })
                ]));
                return;
              }

              const kpis = $("div", { class: "kpis" }, [
                kpi("Tokens saved", fmtInt(t.tokens_saved)),
                kpi("Est. $ saved", "$" + (t.cost_saved_usd ?? 0).toFixed(2)),
                kpi("Searches", fmtInt(t.searches)),
                kpi("Helpful rate", fmtPct(t.helpful_rate))
              ]);
              app.appendChild(kpis);

              const daily = m.series.daily || [];
              const s = m.north_star.savings, q = m.north_star.quality;

              const savings = northStar(
                "North-star A · Token & cost savings",
                "Mean savings ratio, current 7 days vs the prior 7.",
                fmtPct(s.current.mean_savings_ratio), s.direction,
                "prior " + fmtPct(s.prior.mean_savings_ratio) + " · " + fmtInt(s.current.tokens_saved) + " tokens saved this window",
                barChart(daily, d => d.tokens_saved, { aria: "tokens saved per day" })
              );
              const quality = northStar(
                "North-star B · Retrieval quality",
                "Mean top-1 score, current 7 days vs the prior 7.",
                fmt3(q.current.mean_top_score), q.direction,
                "prior " + fmt3(q.prior.mean_top_score) + " · empty " + fmtPct(q.current.empty_rate) + " · helpful " + fmtPct(q.current.helpful_rate),
                lineChart(daily, d => d.mean_top_score, { aria: "mean top score per day" })
              );
              app.appendChild($("div", { class: "ns" }, [savings, quality]));

              // Secondary quality charts.
              app.appendChild($("div", { class: "ns" }, [
                $("div", { class: "panel" }, [$("h2", { text: "Empty-result rate / day" }), $("div", { class: "hint", text: "Share of searches returning nothing." }), lineChart(daily, d => d.empty_rate, { aria: "empty rate" })]),
                $("div", { class: "panel" }, [$("h2", { text: "Helpful vs not-helpful / day" }), $("div", { class: "hint", text: "Feedback split." }), barChart(daily, d => (d.helpful + d.not_helpful), { aria: "feedback volume" })])
              ]));

              // Recent searches table.
              const rows = (m.recent_searches || []).map(r => $("tr", {}, [
                $("td", { text: r.query || "" }),
                $("td", { class: "num", text: fmtInt(r.result_count) }),
                $("td", { text: r.top_kind || "" }),
                $("td", { class: "num", text: fmtInt(r.tokens_saved) }),
                $("td", { class: "num", text: fmt3(r.top_score) }),
                $("td", {}, [$("span", { class: "pill " + r.feedback, text: r.feedback.replace("_", "-") })])
              ]));
              const table = $("table", {}, [
                $("thead", {}, [$("tr", {}, [
                  $("th", { text: "Query" }), $("th", { class: "num", text: "Results" }),
                  $("th", { text: "Top kind" }),
                  $("th", { class: "num", text: "Tokens saved" }), $("th", { class: "num", text: "Top score" }), $("th", { text: "Feedback" })
                ])]),
                $("tbody", {}, rows)
              ]);
              app.appendChild($("div", { class: "panel", style: "margin-top:8px" }, [$("h2", { text: "Recent searches" }), $("div", { style: "overflow-x:auto" }, [table])]));
            }

            fetch("/api/metrics").then(r => r.json()).then(m => {
              render(m);
              const foot = document.getElementById("foot");
              foot.textContent = "Generated " + (m.generated_ts || "") + " · schema " + m.schema + " · read-only, loopback-only.";
            }).catch(e => {
              document.getElementById("app").innerHTML = '<div class="empty"><div class="big">Could not load metrics</div><div>' + String(e) + '</div></div>';
            });
          </script>
        </body>
        </html>
      HTML
    end
  end
end
