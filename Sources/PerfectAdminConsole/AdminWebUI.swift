//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2024 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//
//
// AdminWebUI — self-contained HTML/CSS/JS for the admin console browser UI.
// No external resources; no CDN; all assets inline.
//
// Phase 7 (admin-console UI redesign, direction "1b" -- see the design handoff
// this was built from): a 5-tab shell (Overview/Data/Logs/Actions/Settings)
// replacing the single-page card dump, plus a new square-cornered, Barlow-
// styled (system-ui fallback -- no network, no CDN) visual language. Only
// Overview and Settings have real content this phase; Data/Logs/Actions are
// placeholders pending their own redesign phases. Every existing render*()
// function and its backing element IDs are UNCHANGED -- this phase only
// restructures the surrounding chrome and where those elements live.

import Foundation
import PerfectNIO

enum AdminWebUI {

    /// Returns the complete HTML page as an HTTPOutput, injecting the token file
    /// path into the JavaScript so the auth-gate form can display it.
    static func response(tokenFilePath: String) -> HTTPOutput {
        // JSON-encode the path so special characters can't break the JS string literal.
        let jsonPath: String
        if let data = try? JSONEncoder().encode(tokenFilePath),
           let s = String(data: data, encoding: .utf8) {
            jsonPath = s
        } else {
            jsonPath = "\"\""
        }
        let html = pageTemplate.replacingOccurrences(of: "{{TOKEN_PATH_JSON}}", with: jsonPath)
        return BytesOutput(
            head: HTTPHead(status: .ok, headers: HTTPHeaders([
                ("Content-Type", "text/html; charset=utf-8"),
                ("Cache-Control", "no-store"),
            ])),
            body: Array(html.utf8)
        )
    }

    // MARK: - Page template
    // Uses #"..."# raw strings so JS backslashes and ${} are not interpreted by Swift.
    // The sole server-side substitution is {{TOKEN_PATH_JSON}} (replaced above).
    // Split into named pieces purely for readability/navigability -- concatenated at
    // Swift-compile-time into one self-contained HTML string, still shipped with no
    // build step, no bundler, no external resources.

    private static var pageTemplate: String {
        htmlHead + authGateBody + dashboardBody + scriptBlock + "</body>\n</html>\n"
    }

    private static let htmlHead = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Perfect Admin Console</title>
<style>
:root {
  --color-bg:#f2f2f3; --color-surface:#e9e9ea; --color-text:#1d1f20;
  --color-accent:#5980a6; --color-accent-600:#597ea3; --color-accent-700:#416180;
  --color-divider: color-mix(in srgb, #1d1f20 16%, transparent);
  --color-neutral-100:#f5f5f8; --color-neutral-200:#e7e7ea; --color-neutral-300:#d4d4d7;
  --color-neutral-400:#b7b7ba; --color-neutral-500:#98989b; --color-neutral-600:#7a7a7d;
  --color-neutral-700:#5d5d60; --color-neutral-800:#424244; --color-neutral-900:#2b2b2d;
  --color-accent-100:#eef6ff; --color-accent-200:#d6ebff; --color-accent-300:#b5d9fd;
  --color-accent-400:#94bce3; --color-accent-500:#749dc4; --color-accent-800:#2c455d;
  --color-accent-900:#1d2d3d;
  /* Functional addition, not in the design system itself: an ops console can't signal
     failure with the accent alone. */
  --color-alert:#a63d33; --color-alert-text:#7d2e26;
  --color-alert-fill: color-mix(in srgb, #a63d33 12%, transparent);
  /* No network/CDN allowed (localhost tool) -- system-ui stands in for Barlow/Barlow
     Condensed. Weight/uppercase/letter-spacing rules are still honored; only the
     specific typeface isn't. */
  --font-heading: system-ui, sans-serif;
  --font-body: system-ui, sans-serif;
  --font-mono: ui-monospace, 'SF Mono', Menlo, monospace;
  --space-1:3.4px; --space-2:6.8px; --space-3:10.2px; --space-4:13.6px; --space-6:20.4px; --space-8:27.2px;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--color-bg);color:var(--color-text);font-family:var(--font-body);font-size:14px;line-height:1.5;min-height:100vh}
a{color:var(--color-accent)}
h6{font-family:var(--font-heading);font-weight:600;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--color-neutral-700)}
code{font-family:var(--font-mono);font-size:12px;background:var(--color-neutral-200);padding:2px 6px}
/* ---- buttons (square, per the design system's own "blueprint frame" override) ---- */
.btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;cursor:pointer;text-decoration:none;
  font-family:var(--font-heading);font-weight:600;font-size:13px;color:var(--color-text);
  background:transparent;border:1px solid var(--color-divider);padding:6px 12px;border-radius:0}
.btn:hover{background:color-mix(in srgb, var(--color-text) 7%, transparent)}
.btn:disabled{opacity:.45;cursor:not-allowed}
.btn-primary{background:var(--color-accent);color:var(--color-bg);border-color:var(--color-accent)}
.btn-primary:hover{background:var(--color-accent-600)}
.btn-destructive{border-color:var(--color-alert);color:var(--color-alert)}
.btn-destructive:hover{background:var(--color-alert-fill)}
/* ---- auth gate ---- */
#auth-gate{display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;gap:14px;padding:24px}
#auth-gate h1{font-family:var(--font-heading);font-weight:600;font-size:22px}
#auth-gate p{color:var(--color-neutral-700);text-align:center;max-width:340px;font-size:13px}
#token-input{width:320px;max-width:100%;padding:10px 14px;border:1px solid var(--color-divider);background:var(--color-surface);color:var(--color-text);font-family:var(--font-mono);font-size:13px;outline:none;border-radius:0}
#token-input:focus-visible{outline:2px solid var(--color-accent);outline-offset:2px}
#connect-btn{padding:10px 28px;font-size:14px}
#auth-err{color:var(--color-alert);font-size:13px;display:none}
/* ---- dashboard chrome ---- */
#dashboard{display:none}
.titlebar{padding:12px 20px;border-bottom:1px solid var(--color-divider);display:flex;align-items:center;justify-content:space-between}
.brand{font-family:var(--font-heading);font-weight:600;font-size:19px;letter-spacing:.02em}
.host-label{font-size:12px;color:var(--color-neutral-600);margin-left:10px}
#refresh-badge{font-size:12px;color:var(--color-neutral-600);margin-right:10px}
.state-strip{display:flex;align-items:stretch;border-bottom:1px solid var(--color-divider);background:var(--color-neutral-100)}
.state-cell{padding:9px 20px;border-right:1px solid var(--color-divider);display:flex;flex-direction:column;justify-content:center}
.state-cell.state-serving{flex-direction:row;align-items:center;gap:8px}
.dot{width:8px;height:8px;border-radius:50%;background:var(--color-accent);display:inline-block}
.dot.alert{background:var(--color-alert)}
.state-key{font-size:10px;letter-spacing:.1em;text-transform:uppercase;color:var(--color-neutral-600)}
.state-val{font-family:var(--font-mono);font-size:13px}
.state-serving-label{font-family:var(--font-heading);font-weight:600;font-size:15px;letter-spacing:.04em}
.state-job{margin-left:auto;flex-direction:row;align-items:center;gap:8px;border-right:none}
.job-name{display:flex;align-items:center;gap:8px;border:1px solid var(--color-accent);padding:3px 9px}
.job-name .n{font-family:var(--font-heading);font-size:13px;color:var(--color-accent-700);letter-spacing:.04em}
.job-bar{width:80px;height:4px;background:var(--color-neutral-300);display:block}
.job-bar-fill{display:block;height:4px;background:var(--color-accent)}
.job-count{font-family:var(--font-mono);font-size:11px;color:var(--color-neutral-700)}
.tab-bar{display:flex;gap:2px;padding:0 20px;border-bottom:1px solid var(--color-divider)}
.tab-item{background:none;border:none;cursor:pointer;font-family:var(--font-heading);font-weight:600;font-size:15px;letter-spacing:.06em;text-transform:uppercase;padding:10px 16px;border-bottom:2px solid transparent;color:var(--color-neutral-700)}
.tab-item.active{border-bottom-color:var(--color-accent);color:var(--color-accent-700)}
.tab-item .problem-dot{width:6px;height:6px;background:var(--color-alert);display:inline-block;margin-left:6px;border-radius:0;vertical-align:middle}
.tab-panel{display:none;padding:20px}
.tab-panel.active{display:block}
main{max-width:1240px;margin:0 auto}
/* ---- cards (square, transparent per the design system) ---- */
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:14px;margin-bottom:14px}
.card{border:1px solid var(--color-divider);padding:14px;background:transparent}
.card h2{font-family:var(--font-heading);font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:var(--color-neutral-700);margin-bottom:12px}
.row{display:flex;justify-content:space-between;align-items:baseline;padding:5px 0;border-bottom:1px solid var(--color-divider);gap:8px}
.row:last-child{border-bottom:none}
.rl{color:var(--color-neutral-700);flex-shrink:0}
.rv{font-weight:500;text-align:right;word-break:break-all}
.tag{display:inline-block;padding:2px 8px;background:var(--color-neutral-100);color:var(--color-neutral-800);font-family:var(--font-mono);font-size:11px;margin:2px}
/* ---- log tail ---- */
#log-card{margin-top:0}
.log-box{background:var(--color-accent-900);color:var(--color-accent-200);font-family:var(--font-mono);font-size:12px;line-height:1.6;padding:12px;height:220px;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
.log-footer{display:flex;justify-content:space-between;font-size:12px;color:var(--color-neutral-600);margin-top:8px}
/* ---- delegate sections ---- */
#delegate-cards{margin-top:14px;display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:14px}
/* ---- mini buttons (datasource test, tls ops) ---- */
.mini-btn{padding:3px 9px;border:1px solid var(--color-accent);background:transparent;color:var(--color-accent);cursor:pointer;font-size:11px;font-weight:600;white-space:nowrap;font-family:var(--font-heading)}
.mini-btn:hover{background:var(--color-accent);color:var(--color-bg)}
/* ---- config switcher ---- */
.cfg-select{padding:3px 6px;border:1px solid var(--color-divider);background:var(--color-surface);color:var(--color-text);font-size:11px;cursor:pointer;max-width:220px;border-radius:0}
/* ---- datasource table (full-width, 3-column, nothing clipped) ---- */
#datasource-card{margin-bottom:14px}
.ds-table{display:grid;grid-template-columns:minmax(180px,1.3fr) minmax(220px,1.6fr) minmax(170px,auto);gap:8px 20px;align-items:start}
.ds-head{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.04em;color:var(--color-neutral-700)}
.ds-divider{grid-column:1/-1;height:1px;background:var(--color-divider)}
.ds-cell{min-width:0;padding:2px 0}
.ds-controls{display:flex;gap:6px;flex-wrap:wrap;align-items:center}
.ds-name{font-weight:600}
.ds-sub{color:var(--color-neutral-700);font-size:12px;margin-top:2px}
.ds-active{color:var(--color-accent-700);font-size:12px}
@media(max-width:680px){.ds-table{grid-template-columns:1fr}.ds-head{display:none}}
/* ---- actions section ---- */
#actions-section{margin-top:14px}
.action-btn{padding:5px 12px;border:1px solid var(--color-accent);background:transparent;color:var(--color-accent);cursor:pointer;font-size:12px;font-weight:600;font-family:var(--font-heading);transition:background .15s,color .15s}
.action-btn:hover{background:var(--color-accent);color:var(--color-bg)}
.action-btn.destructive{border-color:var(--color-alert);color:var(--color-alert)}
.action-btn.destructive:hover{background:var(--color-alert);color:var(--color-bg)}
/* ---- placeholder tab panels ---- */
.placeholder{color:var(--color-neutral-700);font-size:14px;padding:40px 0;text-align:center}
/* ---- toasts ---- */
#toast-container{position:fixed;bottom:20px;right:20px;display:flex;flex-direction:column;gap:8px;z-index:100;pointer-events:none}
.toast{padding:10px 16px;font-size:13px;background:var(--color-surface);border:1px solid var(--color-divider);box-shadow:0 3px 10px color-mix(in srgb, #2b2b2d 16%, transparent);max-width:320px;transition:opacity .4s;pointer-events:auto}
.toast-ok{border-left:3px solid var(--color-accent)}
.toast-err{border-left:3px solid var(--color-alert)}
.toast-fade{opacity:0}
</style>
</head>
<body>

"""#

    private static let authGateBody = #"""
<!-- ==================== AUTH GATE ==================== -->
<div id="auth-gate">
  <h1>Perfect Admin Console</h1>
  <p>Enter the bearer token from<br><code id="path-hint"></code></p>
  <input id="token-input" type="password" placeholder="paste token here" autocomplete="off" spellcheck="false">
  <button id="connect-btn" class="btn btn-primary" onclick="connect()">Connect</button>
  <span id="auth-err">Invalid token — check the file and try again.</span>
</div>

"""#

    private static let dashboardBody = #"""
<!-- ==================== DASHBOARD ==================== -->
<div id="dashboard">
  <div class="titlebar">
    <div><span class="brand">PERFECT ADMIN CONSOLE</span><span class="host-label" id="host-label"></span></div>
    <div style="display:flex;align-items:center">
      <span id="refresh-badge">connecting…</span>
      <button class="btn" onclick="logout()">Disconnect</button>
    </div>
  </div>
  <div class="state-strip">
    <div class="state-cell state-serving"><span class="dot" id="serving-dot"></span><span class="state-serving-label" id="serving-label">SERVING</span></div>
    <div class="state-cell"><span class="state-key">Site / Admin</span><span class="state-val" id="ports-val">—</span></div>
    <div class="state-cell"><span class="state-key">Uptime</span><span class="state-val" id="uptime-val">—</span></div>
    <div class="state-cell"><span class="state-key">Error rate</span><span class="state-val" id="errorrate-val">—</span></div>
    <div class="state-cell"><span class="state-key">Connections</span><span class="state-val" id="connections-val">—</span></div>
    <div class="state-cell state-job" id="job-chip" style="display:none">
      <span class="state-key">Running</span>
      <span class="job-name"><span class="n" id="job-name"></span><span class="job-bar"><span class="job-bar-fill" id="job-bar-fill"></span></span><span class="job-count" id="job-count"></span></span>
    </div>
  </div>
  <div class="tab-bar" id="tab-bar">
    <button class="tab-item active" data-tab="overview" onclick="showTab('overview')">Overview</button>
    <button class="tab-item" data-tab="data" onclick="showTab('data')">Data</button>
    <button class="tab-item" data-tab="logs" onclick="showTab('logs')">Logs</button>
    <button class="tab-item" data-tab="actions" onclick="showTab('actions')">Actions</button>
    <button class="tab-item" data-tab="settings" onclick="showTab('settings')">Settings</button>
  </div>
  <main>
    <div class="tab-panel active" id="tab-overview">
      <div class="grid">
        <div class="card"><h2>Server Status</h2><div id="status-rows"><div class="row"><span class="rl">Loading…</span></div></div></div>
        <div class="card"><h2>Metrics</h2><div id="metrics-rows"><div class="row"><span class="rl">Loading…</span></div></div></div>
      </div>
      <div class="card" id="datasource-card"><h2>Datasources</h2><div id="datasource-content"><div class="row"><span class="rl">Loading…</span></div></div></div>
      <div class="card" id="models-card"><h2>Models</h2><div id="models-content"><div class="row"><span class="rl">Loading…</span></div></div></div>
      <div class="card" id="log-card">
        <h2>Log Tail <span id="log-meta" style="font-weight:400;text-transform:none;letter-spacing:0;color:var(--color-neutral-600)"></span></h2>
        <div class="log-box" id="log-box">Loading…</div>
        <div class="log-footer">
          <span id="log-count-label"></span>
          <span id="next-refresh">…</span>
        </div>
      </div>
      <div id="delegate-cards"></div>
      <div id="actions-section"></div>
    </div>
    <div class="tab-panel" id="tab-data"><div class="placeholder">This tab is being redesigned — see Overview for now.</div></div>
    <div class="tab-panel" id="tab-logs"><div class="placeholder">This tab is being redesigned — see Overview for now.</div></div>
    <div class="tab-panel" id="tab-actions"><div class="placeholder">This tab is being redesigned — see Overview for now.</div></div>
    <div class="tab-panel" id="tab-settings">
      <div class="grid">
        <div class="card"><h2>TLS Domains</h2><div id="tls-content"><div class="row"><span class="rl">Loading…</span></div></div></div>
        <div class="card"><h2>ACME Challenges</h2><div id="acme-rows"><div class="row"><span class="rl">Loading…</span></div></div></div>
        <div class="card"><h2>Routes</h2><div id="routes-content"><div class="row"><span class="rl">Loading…</span></div></div></div>
      </div>
    </div>
  </main>
</div>
<div id="toast-container"></div>

"""#

    private static let scriptBlock = #"""
<script>
'use strict';
const KEY = 'perfectAdminToken';
let token = sessionStorage.getItem(KEY) || '';
let refreshIntervalId = null;
let countdown = 5;

// Inject server-side token path hint
document.getElementById('path-hint').textContent = {{TOKEN_PATH_JSON}};

function hdr() { return { 'Authorization': 'Bearer ' + token }; }

function esc(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function row(label, value) {
  return '<div class="row"><span class="rl">' + esc(label) + '</span><span class="rv">' + esc(value) + '</span></div>';
}

function fmtUptime(s) {
  if (s == null || s <= 0) return '—';
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return (d > 0 ? d + 'd ' : '') + (h > 0 ? h + 'h ' : '') + m + 'm';
}

// ---- Tab switching ----

function showTab(name) {
  document.querySelectorAll('.tab-panel').forEach(el => el.classList.toggle('active', el.id === 'tab-' + name));
  document.querySelectorAll('.tab-item').forEach(el => el.classList.toggle('active', el.dataset.tab === name));
}

// ---- State strip ----

function renderStateStrip(status, metrics) {
  const portsVal = (status.serverPort ? ':' + status.serverPort : '—') + ' / :' + status.adminPort;
  document.getElementById('ports-val').textContent = portsVal;
  document.getElementById('uptime-val').textContent = fmtUptime(status.uptimeSeconds);
  const rate = metrics && metrics.totalRequests > 0 ? (metrics.errorRate * 100).toFixed(1) + '%' : '—';
  document.getElementById('errorrate-val').textContent = rate;
  document.getElementById('connections-val').textContent = metrics ? String(metrics.activeConnections) : '—';

  const job = status.currentJob;
  const chip = document.getElementById('job-chip');
  if (job) {
    chip.style.display = '';
    document.getElementById('job-name').textContent = job.name;
    const pct = job.total > 0 ? Math.min(100, Math.round(job.completed / job.total * 100)) : 0;
    document.getElementById('job-bar-fill').style.width = pct + '%';
    document.getElementById('job-count').textContent = job.completed.toLocaleString() + '/' + job.total.toLocaleString();
  } else {
    chip.style.display = 'none';
  }
}

function setServing(isServing) {
  document.getElementById('serving-dot').classList.toggle('alert', !isServing);
  document.getElementById('serving-label').textContent = isServing ? 'SERVING' : 'UNREACHABLE';
}

async function api(path) {
  const r = await fetch(path, { headers: hdr() });
  if (r.status === 401) { logout(); throw new Error('401'); }
  if (!r.ok) throw new Error(r.statusText);
  return r.json();
}

async function refresh() {
  try {
    const [status, tls, acme, logs, routes, datasources, metrics, actions, models] = await Promise.all([
      api('/api/status'), api('/api/tls'), api('/api/acme'),
      api('/api/logs?count=100'), api('/api/routes'), api('/api/datasources'),
      api('/api/metrics'), api('/api/actions'), api('/api/models'),
    ]);
    setServing(true);
    renderStatus(status);
    renderStateStrip(status, metrics);
    renderTLS(tls);
    renderACME(acme);
    renderLogs(logs);
    renderRoutes(routes);
    renderDatasources(datasources);
    renderMetrics(metrics);
    renderModels(models);
    // Re-rendered every cycle (not just on first load) so an action whose
    // description reflects live state — e.g. a crawl-report delegate
    // showing "Running now — 340/1,989 pages" — updates without a reload.
    renderActions(actions.actions || []);
    if (status.additionalSections && status.additionalSections.length)
      renderDelegate(status.additionalSections);
    document.getElementById('refresh-badge').textContent =
      'live · updated ' + new Date().toLocaleTimeString();
  } catch(e) {
    if (e.message === '401') return;
    setServing(false);
    document.getElementById('refresh-badge').textContent = 'error: ' + e.message;
  }
}

function renderStatus(s) {
  let h = '';
  h += row('Admin port', s.adminPort);
  if (s.serverPort) h += row('Server port', s.serverPort);
  if (s.uptimeSeconds != null) h += row('Uptime', fmtUptime(s.uptimeSeconds));
  const tlsLabel = s.tlsDomainCount > 0
    ? s.tlsDomainCount + ' domain' + (s.tlsDomainCount !== 1 ? 's' : '') + (s.tlsHasDefault ? ' + default' : '')
    : (s.tlsHasDefault ? 'Default only' : 'Disabled');
  h += row('TLS', tlsLabel);
  h += row('ACME pending', s.acmePendingChallenges === 0 ? '✓ none' : String(s.acmePendingChallenges));
  document.getElementById('status-rows').innerHTML = h;
}

function renderTLS(t) {
  if (!t.domains.length && !t.hasDefault) {
    document.getElementById('tls-content').innerHTML =
      '<div class="row"><span class="rl" style="color:var(--color-neutral-600)">No TLS configured</span></div>';
    return;
  }
  let h = t.domains.map(d => {
    const safe = esc(d).replace(/'/g, "\\'");
    return '<div class="row">' +
      '<span class="rl" style="font-family:var(--font-mono);font-size:12px">' + esc(d) + '</span>' +
      '<span class="rv" style="display:flex;gap:4px">' +
      '<button class="mini-btn" onclick="tlsReload(\'' + safe + '\')">Reload</button>' +
      '<button class="mini-btn" style="border-color:var(--color-alert);color:var(--color-alert)" onclick="tlsRemove(\'' + safe + '\')">Remove</button>' +
      '</span></div>';
  }).join('');
  if (t.hasDefault) h += '<div class="row"><span class="rl">Default cert</span><span class="rv" style="color:var(--color-neutral-600);font-size:12px">registered</span></div>';
  document.getElementById('tls-content').innerHTML = h || '<span style="color:var(--color-neutral-600);font-size:13px">none</span>';
}

function renderACME(a) {
  document.getElementById('acme-rows').innerHTML =
    row('Pending challenges', a.pendingChallenges === 0 ? '✓ none' : String(a.pendingChallenges));
}

function renderLogs(l) {
  const box = document.getElementById('log-box');
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 60;
  box.textContent = l.lines.length ? l.lines.join('\n') : '(no log lines captured yet)';
  if (atBottom) box.scrollTop = box.scrollHeight;
  document.getElementById('log-count-label').textContent =
    'showing ' + l.lines.length + ' of ' + l.totalCaptured + ' captured';
}

function renderRoutes(r) {
  if (!r.routes.length) {
    document.getElementById('routes-content').innerHTML =
      '<div class="row"><span class="rl" style="color:var(--color-neutral-600)">No routes from delegate</span></div>';
    return;
  }
  document.getElementById('routes-content').innerHTML =
    r.routes.map(u => '<span class="tag">' + esc(u) + '</span>').join('');
}

// ---- Phase 4: metrics + TLS operations ----

function renderMetrics(m) {
  let h = '';
  h += row('Total requests', m.totalRequests.toLocaleString());
  h += row('Total errors', m.totalErrors.toLocaleString());
  h += row('Active connections', m.activeConnections.toLocaleString());
  const rate = m.totalRequests > 0
    ? (m.errorRate * 100).toFixed(1) + '%'
    : '—';
  h += row('Error rate', rate);
  const topRoutes = Object.entries(m.routeCounts || {})
    .sort((a, b) => b[1] - a[1]).slice(0, 5);
  if (topRoutes.length) {
    h += '<div style="margin-top:8px;font-size:11px;color:var(--color-neutral-600);font-weight:600;letter-spacing:.04em">TOP ROUTES</div>';
    for (const [route, count] of topRoutes)
      h += row(route, count.toLocaleString());
  }
  document.getElementById('metrics-rows').innerHTML = h;
}

async function tlsReload(hostname) {
  try {
    const r = await fetch('/api/tls/reload', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + token, 'X-Admin-CSRF': '1', 'Content-Type': 'application/json' },
      body: JSON.stringify({ hostname })
    });
    if (r.status === 401) { logout(); return; }
    const data = await r.json();
    showToast(data.message, data.success ? 'ok' : 'err');
  } catch(e) { showToast('Reload failed: ' + e.message, 'err'); }
}

async function tlsRemove(hostname) {
  if (!confirm('Remove TLS config for ' + hostname + '?\nThe next connection for this domain will fall back to the default cert or be refused.')) return;
  try {
    const r = await fetch('/api/tls/domain', {
      method: 'DELETE',
      headers: { 'Authorization': 'Bearer ' + token, 'X-Admin-CSRF': '1', 'Content-Type': 'application/json' },
      body: JSON.stringify({ hostname })
    });
    if (r.status === 401) { logout(); return; }
    const data = await r.json();
    showToast(data.message, data.success ? 'ok' : 'err');
    if (data.success) refresh();
  } catch(e) { showToast('Remove failed: ' + e.message, 'err'); }
}

// ---- Phase 3: datasources ----

function renderDatasources(d) {
  const el = document.getElementById('datasource-content');
  if (!d.datasources || !d.datasources.length) {
    el.innerHTML = '<div class="row"><span class="rl" style="color:var(--color-neutral-600)">No datasources registered</span></div>';
    return;
  }
  let h = '<div class="ds-table">';
  h += '<div class="ds-head">Datasource</div><div class="ds-head">Active Connection</div><div class="ds-head">Actions</div>';
  h += '<div class="ds-divider"></div>';
  h += d.datasources.map(ds => {
    const safeName = esc(ds.name).replace(/'/g, "\\'");
    const active = (ds.configs || []).find(c => c.isActive);
    const activeHTML = active
      ? '<div class="ds-active">● ' + esc(active.label) + '</div>' +
        (active.description ? '<div class="ds-sub">' + esc(active.description) + '</div>' : '')
      : '<div class="ds-sub">—</div>';
    // Config switcher: only shown when >1 config is available
    const configs = ds.configs || [];
    let controls = '';
    if (configs.length > 1) {
      const selId = 'cfg-' + ds.name.replace(/[^a-z0-9]/gi, '-');
      const opts = configs.map(c =>
        '<option value="' + esc(c.id) + '"' + (c.isActive ? ' selected' : '') + '>' + esc(c.label) + '</option>'
      ).join('');
      controls += '<select id="' + selId + '" class="cfg-select">' + opts + '</select>';
      controls += '<button class="mini-btn" onclick="switchDS(\'' + safeName + '\',document.getElementById(\'' + selId + '\').value)">Switch</button>';
    }
    controls += '<button class="mini-btn" onclick="testDS(\'' + safeName + '\')">Test</button>';
    return '<div class="ds-cell"><div class="ds-name">' + esc(ds.alias || ds.name) + '</div>' +
      '<div class="ds-sub">' + esc(ds.driver) + ' · ' + esc(ds.schema) + '</div></div>' +
      '<div class="ds-cell">' + activeHTML + '</div>' +
      '<div class="ds-cell ds-controls">' + controls + '</div>' +
      '<div class="ds-divider"></div>';
  }).join('');
  h += '</div>';
  el.innerHTML = h;
}

async function switchDS(name, configID) {
  if (!configID) return;
  try {
    const r = await fetch('/api/datasources/switch', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + token, 'X-Admin-CSRF': '1', 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, config: configID })
    });
    if (r.status === 401) { logout(); return; }
    const data = await r.json();
    const latency = data.latencyMs != null ? ' (' + Math.round(data.latencyMs) + 'ms)' : '';
    showToast(name + ': ' + data.message + latency, data.success ? 'ok' : 'err');
    // Refresh datasource card so the active config label updates
    if (data.success) api('/api/datasources').then(renderDatasources).catch(() => {});
  } catch(e) {
    showToast('Switch failed: ' + e.message, 'err');
  }
}

async function testDS(name) {
  try {
    const r = await fetch('/api/datasources/test', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + token, 'X-Admin-CSRF': '1', 'Content-Type': 'application/json' },
      body: JSON.stringify({ name })
    });
    if (r.status === 401) { logout(); return; }
    const data = await r.json();
    const latency = data.latencyMs != null ? ' (' + Math.round(data.latencyMs) + 'ms)' : '';
    showToast(name + ': ' + data.message + latency, data.success ? 'ok' : 'err');
  } catch(e) {
    showToast('Test failed: ' + e.message, 'err');
  }
}

// ---- Phase 6: model schema browser (ADR-0001 Phase 5) ----
// Schema only -- no row data or row-browsing UI in this first slice.

function renderModels(m) {
  const el = document.getElementById('models-content');
  if (!m.models || !m.models.length) {
    el.innerHTML = '<div class="row"><span class="rl" style="color:var(--color-neutral-600)">No models registered</span></div>';
    return;
  }
  el.innerHTML = m.models.map(model => {
    const cols = model.columns.map(c => {
      const badges = (c.isPrimaryKey ? ' <span class="mini-btn" style="pointer-events:none">PK</span>' : '') +
        (c.isOptional ? ' <span class="mini-btn" style="pointer-events:none">optional</span>' : '');
      return '<div class="row"><span class="rl">' + esc(c.name) + '</span>' +
        '<span class="rv">' + esc(c.typeName) + badges + '</span></div>';
    }).join('');
    return '<div class="row" style="border-bottom:none;padding-bottom:0"><span class="rl" style="font-weight:600">' +
      esc(model.label) + '</span><span class="rv" style="color:var(--color-neutral-600)">' +
      model.columns.length + ' column' + (model.columns.length === 1 ? '' : 's') + '</span></div>' + cols;
  }).join('<div class="ds-divider"></div>');
}

function renderDelegate(sections) {
  const el = document.getElementById('delegate-cards');
  el.innerHTML = sections.map(s => {
    const rows = Object.entries(s.items).map(([k,v]) => row(k, v)).join('');
    return '<div class="card"><h2>' + esc(s.title) + '</h2>' + rows + '</div>';
  }).join('');
}

// ---- Phase 2: actions ----
// Fetched as part of refresh()'s Promise.all so the actions section (and
// any live status a delegate bakes into an action's description) updates
// on every periodic tick, not just once at page load.

function renderActions(actions) {
  const el = document.getElementById('actions-section');
  if (!actions.length) { el.innerHTML = ''; return; }
  // Group by category
  const cats = {};
  for (const a of actions) {
    const c = a.category || 'general';
    (cats[c] = cats[c] || []).push(a);
  }
  let h = '<h6 style="margin-bottom:8px">Actions</h6>';
  h += '<div class="grid">';
  for (const [cat, acts] of Object.entries(cats)) {
    h += '<div class="card"><h2>' + esc(cat) + '</h2>';
    for (const a of acts) {
      h += '<div class="row" style="flex-direction:column;align-items:flex-start;gap:4px;padding:10px 0">';
      h += '<div style="display:flex;justify-content:space-between;width:100%;align-items:center;gap:8px">';
      h += '<strong style="font-size:13px">' + esc(a.label) + '</strong>';
      const cls = 'action-btn' + (a.isDestructive ? ' destructive' : '');
      const escaped = esc(a.name).replace(/'/g, "\\'");
      h += '<button class="' + cls + '" onclick="runAction(\'' + escaped + '\',' + (a.isDestructive ? 'true' : 'false') + ')">';
      h += a.isDestructive ? 'Run (!)' : 'Run';
      h += '</button></div>';
      if (a.description) h += '<span style="color:var(--color-neutral-600);font-size:12px">' + esc(a.description) + '</span>';
      h += '</div>';
    }
    h += '</div>';
  }
  h += '</div>';
  el.innerHTML = h;
}

async function runAction(name, isDestructive) {
  if (isDestructive && !confirm('This action is destructive. Proceed?')) return;
  try {
    const r = await fetch('/api/actions', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + token, 'X-Admin-CSRF': '1', 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: name })
    });
    if (r.status === 401) { logout(); return; }
    const result = await r.json();
    showToast(result.message, result.success ? 'ok' : 'err');
    // Immediately refresh the log view if we just cleared it
    if (name === 'clear-logs') api('/api/logs?count=100').then(renderLogs).catch(() => {});
  } catch(e) {
    showToast('Action failed: ' + e.message, 'err');
  }
}

function showToast(msg, type) {
  const t = document.createElement('div');
  t.className = 'toast toast-' + (type || 'ok');
  t.textContent = msg;
  document.getElementById('toast-container').appendChild(t);
  setTimeout(() => { t.classList.add('toast-fade'); setTimeout(() => t.remove(), 400); }, 3500);
}

async function connect() {
  const input = document.getElementById('token-input').value.trim();
  if (!input) return;
  token = input;
  document.getElementById('auth-err').style.display = 'none';
  try {
    await api('/api/status');
    sessionStorage.setItem(KEY, token);
    showDashboard();
  } catch(e) {
    if (e.message === '401') {
      document.getElementById('auth-err').style.display = 'block';
      token = '';
    }
  }
}

function logout() {
  sessionStorage.removeItem(KEY);
  token = '';
  clearInterval(refreshIntervalId);
  document.getElementById('dashboard').style.display = 'none';
  document.getElementById('auth-gate').style.display = 'flex';
}

function showDashboard() {
  document.getElementById('auth-gate').style.display = 'none';
  document.getElementById('dashboard').style.display = 'block';
  refresh();
  clearInterval(refreshIntervalId);
  countdown = 5;
  refreshIntervalId = setInterval(() => {
    countdown--;
    document.getElementById('next-refresh').textContent = 'refresh in ' + countdown + 's';
    if (countdown <= 0) { countdown = 5; refresh(); }
  }, 1000);
}

// Enter key in token field
document.getElementById('token-input').addEventListener('keydown', e => {
  if (e.key === 'Enter') connect();
});

// Auto-connect if a token is already in sessionStorage
if (token) showDashboard();
</script>
"""#
}
