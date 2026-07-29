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
/* ---- Phase 8: log viewer component (admin-console UI redesign phase 2) ---- */
.log-surface-base{background:var(--color-accent-900);color:var(--color-accent-200);font-family:var(--font-mono);font-size:13px;line-height:1.8;padding:16px;overflow-y:auto;white-space:pre-wrap;word-break:break-all}
.log-surface-mini{font-size:12px;line-height:1.6;padding:12px;height:120px}
.log-surface-full{height:330px}
body.detached-logs .log-surface-full{height:calc(100vh - 150px)}
.log-time{color:var(--color-accent-200)}
.log-sub{color:var(--color-accent-400)}
.log-error{color:#e39c92}
.log-hit{background:color-mix(in srgb, #e3c992 35%, transparent)}
.log-toolbar{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:8px}
.log-search{display:flex;align-items:center;gap:6px;border:1px solid var(--color-divider);background:var(--color-surface);padding:4px 8px;flex:1 1 220px}
.log-search input{border:none;outline:none;background:transparent;color:var(--color-text);font-family:var(--font-mono);font-size:12px;flex:1;min-width:0}
.log-match-count{font-family:var(--font-mono);font-size:11px;color:var(--color-neutral-600);white-space:nowrap}
.log-chips{display:flex;flex-wrap:wrap;gap:4px}
.tag-outline{display:inline-block;padding:2px 8px;border:1px solid var(--color-accent);color:var(--color-accent-700);font-family:var(--font-mono);font-size:11px;cursor:pointer;background:transparent}
.tag-neutral{display:inline-block;padding:2px 8px;border:1px solid var(--color-divider);color:var(--color-neutral-700);font-family:var(--font-mono);font-size:11px;cursor:pointer;background:transparent}
.log-toolbar-actions{display:flex;align-items:center;gap:10px;margin-left:auto}
.log-follow{display:flex;align-items:center;gap:4px;font-size:11px;color:var(--color-neutral-700);white-space:nowrap}
.icon-btn{width:28px;height:28px;display:inline-flex;align-items:center;justify-content:center;border:1px solid var(--color-divider);background:transparent;color:var(--color-neutral-700);cursor:pointer;padding:0}
.icon-btn:hover{background:color-mix(in srgb, var(--color-text) 7%, transparent)}
body.detached-logs .titlebar,body.detached-logs .tab-bar,body.detached-logs .state-strip{display:none}
body.detached-logs main{max-width:none;padding:0}
body.detached-logs .tab-panel{padding:16px}
/* ---- delegate sections ---- */
#delegate-cards{margin-top:14px;display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:14px}
/* ---- mini buttons (datasource test, tls ops) ---- */
.mini-btn{padding:3px 9px;border:1px solid var(--color-accent);background:transparent;color:var(--color-accent);cursor:pointer;font-size:11px;font-weight:600;white-space:nowrap;font-family:var(--font-heading)}
.mini-btn:hover{background:var(--color-accent);color:var(--color-bg)}
/* ---- shared divider (also used by renderModels()) ---- */
.ds-divider{grid-column:1/-1;height:1px;background:var(--color-divider)}
/* ---- Data tab: master-detail (Phase 10: admin-console UI redesign phase 4) ---- */
.data-layout{display:grid;grid-template-columns:300px 1fr;min-height:520px;border:1px solid var(--color-divider)}
.data-rail{border-right:1px solid var(--color-divider);display:flex;flex-direction:column}
.data-rail-head{display:flex;justify-content:space-between;align-items:center;padding:12px 14px;border-bottom:1px solid var(--color-divider)}
.data-rail-head h2{font-family:var(--font-heading);font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:var(--color-neutral-700)}
.data-rail-list{flex:1;overflow-y:auto}
.data-row{display:flex;align-items:flex-start;gap:8px;padding:8px 14px;border-left:3px solid transparent;cursor:pointer;font-family:var(--font-mono);font-size:13px}
.data-row:hover{background:color-mix(in srgb, var(--color-text) 4%, transparent)}
.data-row.selected{border-left-color:var(--color-accent);background:var(--color-neutral-100)}
.data-status-square{width:7px;height:7px;margin-top:4px;flex-shrink:0;background:var(--color-accent)}
.data-status-square.failing{background:var(--color-alert)}
.data-status-square.not-tested{background:transparent;border:1px solid var(--color-neutral-400)}
.data-row-name{font-weight:600}
.data-row-sub{font-size:11px;color:var(--color-neutral-700);font-family:var(--font-body)}
.data-rail-footnote{padding:10px 14px;font-size:11px;color:var(--color-neutral-600);border-top:1px solid var(--color-divider)}
.data-detail{padding:16px}
.data-detail-head{display:flex;justify-content:space-between;align-items:flex-start;gap:16px}
.data-alias-name{font-family:var(--font-heading);font-weight:600;font-size:28px}
.data-tag{display:inline-block;padding:2px 8px;font-family:var(--font-mono);font-size:11px;margin-left:8px;border:1px solid}
.data-tag-ok{border-color:var(--color-accent);color:var(--color-accent-700)}
.data-tag-failing{border-color:var(--color-alert);color:var(--color-alert-text)}
.data-tag-not-tested{border-color:var(--color-neutral-400);color:var(--color-neutral-700)}
.data-subtitle{color:var(--color-neutral-700);font-size:13px;margin-top:4px}
.data-detail-actions{display:flex;gap:8px;flex-shrink:0}
.data-failure-banner{border:1px solid var(--color-alert);padding:12px 14px;margin-top:14px;font-size:13px}
.data-failure-time{color:var(--color-neutral-600);font-size:12px;margin-top:4px}
.data-failure-note{margin-top:8px;font-size:12px;color:var(--color-alert-text)}
.data-profiles{margin-top:20px}
.data-profile-card{border:1px solid var(--color-divider);padding:10px 12px;margin-top:8px}
.data-profile-card.active{border-color:var(--color-accent)}
.data-profile-head{display:flex;justify-content:space-between;align-items:center}
.data-profile-host{font-family:var(--font-mono);font-size:12px;margin-top:4px}
.data-profile-status{font-size:12px;color:var(--color-neutral-700);margin-top:2px}
.data-switch-rule{font-size:12px;color:var(--color-neutral-700);margin-top:8px;max-width:640px}
.data-history{margin-top:20px}
.data-history-table{width:100%;border-collapse:collapse;font-size:12px}
.data-history-table th{text-align:left;font-weight:600;color:var(--color-neutral-700);text-transform:uppercase;letter-spacing:.04em;font-size:11px;padding:4px 8px;border-bottom:1px solid var(--color-divider)}
.data-history-table td{padding:4px 8px;border-bottom:1px solid var(--color-divider);font-family:var(--font-mono)}
/* ---- actions catalog (Phase 9: admin-console UI redesign phase 3) ---- */
.action-btn{padding:5px 12px;border:1px solid var(--color-accent);background:transparent;color:var(--color-accent);cursor:pointer;font-size:12px;font-weight:600;font-family:var(--font-heading);transition:background .15s,color .15s}
.action-btn:hover{background:var(--color-accent);color:var(--color-bg)}
.action-btn.destructive{border-color:var(--color-alert);color:var(--color-alert)}
.action-btn.destructive:hover{background:var(--color-alert);color:var(--color-bg)}
.action-btn:disabled{opacity:.5;cursor:not-allowed;background:transparent}
.action-group{border:1px solid var(--color-divider);margin-bottom:14px}
.action-group-head{display:flex;justify-content:space-between;align-items:baseline;padding:10px 14px;border-bottom:1px solid var(--color-divider);background:var(--color-neutral-100)}
.action-group-head h2{font-family:var(--font-heading);font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:var(--color-neutral-700);margin:0}
.action-group-count{font-family:var(--font-mono);font-size:11px;color:var(--color-neutral-700)}
.action-row{display:flex;justify-content:space-between;gap:16px;padding:14px;border:1px solid var(--color-divider);margin:10px 14px}
.action-row.destructive{border-color:var(--color-alert)}
.action-row.inert{opacity:.6}
.action-title{font-family:var(--font-heading);font-weight:600;font-size:20px}
.action-tag{display:inline-block;padding:2px 8px;font-family:var(--font-mono);font-size:11px;margin-left:8px}
.action-tag-running{border:1px solid var(--color-accent);color:var(--color-accent-700)}
.action-tag-destructive{border:1px solid var(--color-alert);color:var(--color-alert-text)}
.action-desc{max-width:640px;color:var(--color-neutral-700);font-size:13px;margin-top:6px}
.action-meta{font-family:var(--font-mono);font-size:12px;color:var(--color-neutral-600);margin-top:6px}
.action-consequence{border-left:3px solid var(--color-alert);background:var(--color-alert-fill);color:var(--color-alert-text);padding:8px 12px;margin-top:8px;font-size:12px;max-width:640px}
.action-controls{flex:0 0 150px;display:flex;flex-direction:column;align-items:flex-end;gap:6px;text-align:right}
.action-ghost{background:none;border:none;padding:0;color:var(--color-accent-700);font-family:var(--font-heading);font-weight:600;font-size:12px;cursor:pointer;text-decoration:underline}
.action-ghost:hover{color:var(--color-accent)}
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
      <div class="card" id="models-card"><h2>Models</h2><div id="models-content"><div class="row"><span class="rl">Loading…</span></div></div></div>
      <div class="card" id="log-card">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
          <h2 style="margin-bottom:0">Recent Log</h2>
          <div style="display:flex;align-items:center;gap:8px">
            <span id="log-next-refresh" style="font-size:11px;color:var(--color-neutral-600)"></span>
            <button class="mini-btn" onclick="showTab('logs')">Open full view</button>
            <button class="icon-btn" onclick="openLogsWindow()" title="Open in new window" aria-label="Open in new window">⧉</button>
          </div>
        </div>
        <div class="log-surface-base log-surface-mini" id="log-box">Loading…</div>
      </div>
      <div id="delegate-cards"></div>
    </div>
    <div class="tab-panel" id="tab-data">
      <div class="data-layout">
        <div class="data-rail">
          <div class="data-rail-head">
            <h2 id="data-rail-count">Datasources · 0</h2>
            <button class="action-ghost" onclick="testAllDatasources()">Test all</button>
          </div>
          <div class="data-rail-list" id="data-rail-list"></div>
          <div class="data-rail-footnote">Aliases are read from the datasources file at startup; editing it needs a restart.</div>
        </div>
        <div class="data-detail" id="data-detail"><div class="placeholder">No datasources registered</div></div>
      </div>
    </div>
    <div class="tab-panel" id="tab-logs">
      <div class="log-toolbar">
        <div class="log-search">
          <span style="font-size:13px;color:var(--color-neutral-600)">⌕</span>
          <input type="text" id="logs-search-input" placeholder="search logs…" autocomplete="off" spellcheck="false">
          <span class="log-match-count" id="logs-match-count"></span>
        </div>
        <div class="log-chips" id="logs-chips"></div>
        <div class="log-toolbar-actions">
          <label class="log-follow"><input type="checkbox" id="logs-follow-checkbox" checked> Follow</label>
          <button class="mini-btn" onclick="copyLogs()">Copy</button>
          <button class="mini-btn" onclick="downloadLogs()">Download .log</button>
          <button class="mini-btn" style="border-color:var(--color-alert);color:var(--color-alert)" onclick="clearLogBuffer()">Clear buffer</button>
          <button class="icon-btn" onclick="openLogsWindow()" title="Open in new window" aria-label="Open in new window">⧉</button>
        </div>
      </div>
      <div class="log-surface-base log-surface-full" id="logs-surface">Loading…</div>
      <div class="log-footer">
        <span id="logs-footer-count"></span>
        <span id="logs-next-refresh">…</span>
      </div>
    </div>
    <div class="tab-panel" id="tab-actions"><div id="actions-catalog"></div></div>
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
let logFilter = { query: '', subsystem: 'all', follow: true };
let lastLogEntries = [];
let lastLogTotal = 0;
let lastLogCapacity = 0;
let logsWindowRef = null;
const isDetached = new URLSearchParams(location.search).get('detached') === 'logs';

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
      api('/api/logs?count=500'), api('/api/routes'), api('/api/datasources'),
      api('/api/metrics'), api('/api/actions'), api('/api/models'),
    ]);
    setServing(true);
    renderStatus(status);
    renderStateStrip(status, metrics);
    renderTLS(tls);
    renderACME(acme);
    handleLogsData(logs);
    renderRoutes(routes);
    renderDataTab(datasources);
    renderMetrics(metrics);
    renderModels(models);
    // Re-rendered every cycle (not just on first load) so an action whose
    // description reflects live state — e.g. a crawl-report delegate
    // showing "Running now — 340/1,989 pages" — updates without a reload.
    renderActionsCatalog(actions.actions || []);
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

// ---- Phase 8: log viewer component (admin-console UI redesign phase 2) ----
// One shared rendering path feeds two DOM mounts: the small Overview "Recent
// log" card (#log-box, always last 6 lines, no toolbar) and the full surface
// (#logs-surface) used identically by the Logs tab and a detached popup
// window (the popup is just this same page reloaded with ?detached=logs --
// see isDetached above and showDashboard() below).

function parseLogEntry(e) {
  const m = /^\[([^\]]+)\]\s*(.*)$/s.exec(e.message);
  return {
    ts: e.ts,
    subsystem: m ? m[1] : null,
    body: m ? m[2] : e.message,
    isError: !!e.isError,
    raw: e.message,
  };
}

function fmtClock(ts) {
  const d = new Date(ts * 1000);
  const pad = n => String(n).padStart(2, '0');
  return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

function escRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Wraps matches of `query` inside already-HTML-escaped `escapedText`. Never
// call this on raw/unescaped text -- the query itself is escaped for regex
// purposes only, not for HTML, so it must be matched against text that has
// already had esc() applied.
function highlightText(escapedText, query) {
  if (!query) return escapedText;
  const re = new RegExp(escRe(esc(query)), 'ig');
  return escapedText.replace(re, m => '<mark class="log-hit">' + m + '</mark>');
}

function logLineHTML(entry, query) {
  const time = '<span class="log-time">' + fmtClock(entry.ts) + '</span>';
  const sub = entry.subsystem ? '<span class="log-sub">[' + esc(entry.subsystem) + ']</span> ' : '';
  const body = highlightText(esc(entry.body), query);
  const line = time + ' ' + sub + body;
  return entry.isError ? '<span class="log-error">' + line + '</span>' : line;
}

function matchesQuery(entry, query) {
  if (!query) return false;
  const q = query.toLowerCase();
  return entry.raw.toLowerCase().includes(q);
}

function computeSubsystemCounts(entries) {
  const counts = new Map();
  for (const e of entries) {
    const key = e.subsystem || 'general';
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  return counts;
}

function renderFilterChips(el, counts, active, total) {
  let h = '<span class="' + (active === 'all' ? 'tag-outline' : 'tag-neutral') + '" onclick="setLogSubsystem(\'all\')">all ' + total + '</span>';
  for (const [name, count] of counts) {
    const cls = active === name ? 'tag-outline' : 'tag-neutral';
    const safe = esc(name).replace(/'/g, "\\'");
    h += '<span class="' + cls + '" onclick="setLogSubsystem(\'' + safe + '\')">' + esc(name) + ' ' + count + '</span>';
  }
  el.innerHTML = h;
}

function setLogSubsystem(name) {
  logFilter.subsystem = name;
  renderLogsView();
}

// Shared surface renderer -- `opts.follow` forces scroll-to-bottom
// unconditionally (the design's explicit Follow control), replacing the old
// near-bottom scroll heuristic entirely.
function renderLogSurface(el, entries, opts) {
  const query = opts.query || '';
  const filtered = opts.subsystem && opts.subsystem !== 'all'
    ? entries.filter(e => (e.subsystem || 'general') === opts.subsystem)
    : entries;
  el.innerHTML = filtered.length
    ? filtered.map(e => logLineHTML(e, query)).join('\n')
    : '(no log lines captured yet)';
  if (opts.follow) el.scrollTop = el.scrollHeight;
  return filtered;
}

function handleLogsData(logs) {
  lastLogEntries = (logs.entries || []).map(parseLogEntry);
  lastLogTotal = logs.totalCaptured;
  lastLogCapacity = logs.capacity || 0;
  renderMiniLog();
  renderLogsView();
}

function renderMiniLog() {
  const box = document.getElementById('log-box');
  if (!box) return;
  renderLogSurface(box, lastLogEntries.slice(-6), { follow: true, query: '', subsystem: 'all' });
}

function renderLogsView() {
  const surface = document.getElementById('logs-surface');
  if (!surface) return;
  const counts = computeSubsystemCounts(lastLogEntries);
  renderFilterChips(document.getElementById('logs-chips'), counts, logFilter.subsystem, lastLogEntries.length);
  const shown = renderLogSurface(surface, lastLogEntries, logFilter);
  const matchCount = logFilter.query ? shown.filter(e => matchesQuery(e, logFilter.query)).length : 0;
  document.getElementById('logs-match-count').textContent = logFilter.query ? matchCount + ' matches' : '';
  document.getElementById('logs-footer-count').textContent =
    'showing ' + lastLogTotal + ' captured · buffer holds ' + lastLogCapacity + ', oldest dropped';
}

function currentLogsText() {
  const filtered = logFilter.subsystem && logFilter.subsystem !== 'all'
    ? lastLogEntries.filter(e => (e.subsystem || 'general') === logFilter.subsystem)
    : lastLogEntries;
  return filtered.map(e => fmtClock(e.ts) + ' ' + e.raw).join('\n');
}

async function copyLogs() {
  try {
    await navigator.clipboard.writeText(currentLogsText());
    showToast('Logs copied to clipboard', 'ok');
  } catch (e) {
    showToast('Copy failed: ' + e.message, 'err');
  }
}

function downloadLogs() {
  const blob = new Blob([currentLogsText()], { type: 'text/plain' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'admin-console-logs-' + Date.now() + '.log';
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

async function clearLogBuffer() {
  if (!confirm('Clear the log buffer? This cannot be undone.')) return;
  try {
    const r = await fetch('/api/logs', { method: 'DELETE', headers: { ...hdr(), 'X-Admin-CSRF': '1' } });
    if (r.status === 401) { logout(); return; }
    if (!r.ok) throw new Error(r.statusText);
    showToast('Log buffer cleared', 'ok');
    const logs = await api('/api/logs?count=500');
    handleLogsData(logs);
  } catch (e) {
    showToast('Clear failed: ' + e.message, 'err');
  }
}

// Remembers each detached viewer's last size/position across opens, keyed by
// viewer name (only "logs" exists today; future viewers get their own key).
function loadWinRect(viewer, fallback) {
  try {
    const saved = JSON.parse(localStorage.getItem('perfectAdminWinRect:' + viewer) || 'null');
    return saved || fallback;
  } catch (e) {
    return fallback;
  }
}

function saveWinRect(viewer) {
  localStorage.setItem('perfectAdminWinRect:' + viewer, JSON.stringify({
    w: window.outerWidth, h: window.outerHeight, x: window.screenX, y: window.screenY,
  }));
}

function openLogsWindow() {
  if (logsWindowRef && !logsWindowRef.closed) { logsWindowRef.focus(); return; }
  const rect = loadWinRect('logs', { w: 900, h: 620, x: window.screenX + 40, y: window.screenY + 40 });
  logsWindowRef = window.open(
    location.pathname + '?detached=logs',
    'perfect-admin-logs',
    'width=' + rect.w + ',height=' + rect.h + ',left=' + rect.x + ',top=' + rect.y
  );
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

// ---- Phase 10: Data tab master-detail (admin-console UI redesign phase 4) ----

let dataState = { selected: null, datasources: [] };

function renderDataTab(d) {
  dataState.datasources = d.datasources || [];
  document.getElementById('data-rail-count').textContent = 'Datasources · ' + dataState.datasources.length;
  if (!dataState.selected || !dataState.datasources.some(ds => ds.name === dataState.selected)) {
    dataState.selected = dataState.datasources.length ? dataState.datasources[0].name : null;
  }
  renderDataRail();
  renderDataDetail();
}

function dataStatusLabel(status) {
  if (status === 'failing') return 'failing';
  if (status === 'not-tested') return 'not tested';
  return 'ok';
}

function renderDataRail() {
  const el = document.getElementById('data-rail-list');
  if (!dataState.datasources.length) { el.innerHTML = ''; return; }
  el.innerHTML = dataState.datasources.map(ds => {
    const safeName = esc(ds.name).replace(/'/g, "\\'");
    const selected = ds.name === dataState.selected ? ' selected' : '';
    const sqClass = ds.status === 'failing' ? 'failing' : ds.status === 'not-tested' ? 'not-tested' : '';
    let sub = esc(ds.driver) + ' · ' + esc(ds.schema);
    if (ds.status === 'failing') sub += ' · failing ' + ds.consecutiveFailures + '×';
    return '<div class="data-row' + selected + '" onclick="selectDatasource(\'' + safeName + '\')">' +
      '<span class="data-status-square ' + sqClass + '"></span>' +
      '<span><div class="data-row-name">' + esc(ds.alias || ds.name) + '</div>' +
      '<div class="data-row-sub">' + sub + '</div></span></div>';
  }).join('');
}

function selectDatasource(name) {
  dataState.selected = name;
  renderDataRail();
  renderDataDetail();
}

function renderDataDetail() {
  const el = document.getElementById('data-detail');
  const ds = dataState.datasources.find(d => d.name === dataState.selected);
  if (!ds) { el.innerHTML = '<div class="placeholder">No datasources registered</div>'; return; }
  const safeName = esc(ds.name).replace(/'/g, "\\'");
  const tagClass = ds.status === 'failing' ? 'data-tag-failing' : ds.status === 'not-tested' ? 'data-tag-not-tested' : 'data-tag-ok';
  let h = '<div class="data-detail-head">';
  h += '<div><span class="data-alias-name">' + esc(ds.alias || ds.name) + '</span>' +
    '<span class="data-tag ' + tagClass + '">' + esc(dataStatusLabel(ds.status)) + '</span>' +
    '<div class="data-subtitle">' + esc(ds.driver) + ' · ' + esc(ds.schema) + '</div></div>';
  h += '<div class="data-detail-actions">' +
    '<button class="mini-btn" onclick="testDS(\'' + safeName + '\')">Test connection</button>' +
    '<button class="action-ghost" onclick="followInLogs(\'' + safeName + '\')">See in Logs</button></div>';
  h += '</div>';
  h += renderFailureBanner(ds);
  h += renderConnectionProfiles(ds);
  h += renderAttemptHistory(ds);
  el.innerHTML = h;
}

function renderFailureBanner(ds) {
  if (ds.status !== 'failing' || !ds.lastAttempt) return '';
  let h = '<div class="data-failure-banner">' + esc(ds.lastAttempt.message);
  h += '<div class="data-failure-time">Last attempt ' + fmtClock(ds.lastAttempt.ts) + '</div>';
  if (ds.correlationNote) h += '<div class="data-failure-note">' + esc(ds.correlationNote) + '</div>';
  h += '</div>';
  return h;
}

function renderConnectionProfiles(ds) {
  const configs = ds.configs || [];
  if (!configs.length) return '';
  const safeName = esc(ds.name).replace(/'/g, "\\'");
  const history = ds.history || [];
  let h = '<div class="data-profiles"><h6>Connection profile</h6>';
  h += configs.map(c => {
    const activeCls = c.isActive ? ' active' : '';
    const lastForProfile = history.slice().reverse().find(a => a.profile === c.label);
    const statusLine = lastForProfile
      ? (lastForProfile.success ? 'ok' : 'failing') + (lastForProfile.latencyMs != null ? ' · ' + Math.round(lastForProfile.latencyMs) + 'ms' : '')
      : 'not tested';
    const safeId = esc(c.id).replace(/'/g, "\\'");
    const switchBtn = c.isActive ? '' :
      '<button class="mini-btn" onclick="switchDS(\'' + safeName + '\',\'' + safeId + '\')">Switch</button>';
    return '<div class="data-profile-card' + activeCls + '">' +
      '<div class="data-profile-head"><strong>' + esc(c.label) + '</strong>' +
      (c.isActive ? '<span class="data-tag data-tag-ok">active</span>' : switchBtn) + '</div>' +
      '<div class="data-profile-host">' + esc(c.description) + '</div>' +
      '<div class="data-profile-status">' + statusLine + '</div></div>';
  }).join('');
  h += '<div class="data-switch-rule">Applies immediately for new queries, tested on switch; in-flight queries finish on the old profile.</div>';
  h += '</div>';
  return h;
}

function renderAttemptHistory(ds) {
  const history = (ds.history || []).slice().reverse();
  let h = '<div class="data-history"><h6>Attempt history</h6>';
  if (!history.length) {
    return h + '<div class="placeholder">No attempts recorded yet.</div></div>';
  }
  h += '<table class="data-history-table"><thead><tr><th>Time</th><th>Profile</th><th>Latency</th><th>Result</th></tr></thead><tbody>';
  h += history.map(a => {
    const latency = a.latencyMs != null ? Math.round(a.latencyMs) + 'ms' : '—';
    const result = a.success ? 'ok' : esc(a.message);
    return '<tr><td>' + fmtClock(a.ts) + '</td><td>' + esc(a.profile) + '</td><td>' + latency + '</td><td>' + result + '</td></tr>';
  }).join('');
  h += '</tbody></table></div>';
  return h;
}

async function testAllDatasources() {
  for (const ds of dataState.datasources) {
    await testDS(ds.name);
  }
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
    api('/api/datasources').then(renderDataTab).catch(() => {});
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
    api('/api/datasources').then(renderDataTab).catch(() => {});
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

// ---- Phase 9: Actions catalog (admin-console UI redesign phase 3) ----
// Fetched as part of refresh()'s Promise.all so the catalog (and any live
// status a delegate bakes into an action's description) updates on every
// periodic tick, not just once at page load.

function titleCaseCategory(s) {
  // "tls" is the one real category value that's an acronym, not a word --
  // every other category (general/maintenance/data/gateway/tenant/...) gets
  // generic title-casing, not a hardcoded list.
  if (String(s).toLowerCase() === 'tls') return 'TLS';
  return String(s).replace(/\b\w/g, c => c.toUpperCase());
}

// A single-quoted JS string literal, safe to embed inside a double-quoted HTML
// attribute: escapes backslashes/single-quotes for the JS literal delimiter,
// and &/</>/" for the surrounding HTML attribute delimiter.
function attrJsString(s) {
  return "'" + String(s)
    .replace(/\\/g, '\\\\').replace(/'/g, "\\'")
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;') + "'";
}

function actionButtonHTML(a) {
  const escapedName = esc(a.name).replace(/'/g, "\\'");
  if (a.isInert) {
    const reason = a.name === 'reload-tls' ? 'No TLS configured' : 'Not available';
    return '<button class="action-btn" disabled>' + esc(reason) + '</button>';
  }
  if (a.isRunning) {
    return '<button class="action-btn" disabled>Already running</button>' +
      '<button class="action-ghost" onclick="followInLogs(\'' + escapedName + '\')">Follow in Logs</button>';
  }
  if (a.isDestructive) {
    const verb = (a.label.split(' ')[0] || a.label) + '…';
    const extra = a.name === 'clear-logs'
      ? '<button class="action-ghost" onclick="downloadLogs()">Download first</button>' : '';
    const conseq = a.consequence ? attrJsString(a.consequence) : 'null';
    return extra + '<button class="action-btn destructive" onclick="runAction(\'' + escapedName +
      '\', true, ' + conseq + ')">' + esc(verb) + '</button>';
  }
  return '<button class="action-btn" onclick="runAction(\'' + escapedName + '\', false, null)">Run</button>';
}

function actionRowHTML(a) {
  const cls = 'action-row' + (a.isDestructive ? ' destructive' : '') + (a.isInert ? ' inert' : '');
  let head = '<span class="action-title">' + esc(a.label) + '</span>';
  if (a.isRunning) head += '<span class="action-tag action-tag-running">running</span>';
  if (a.isDestructive) head += '<span class="action-tag action-tag-destructive">destructive · confirms</span>';
  let main = '<div style="max-width:100%">' + head;
  if (a.description) main += '<p class="action-desc">' + esc(a.description) + '</p>';
  if (a.lastResult) main += '<div class="action-meta">Last result: ' + esc(a.lastResult) + '</div>';
  if (a.isDestructive && a.consequence) main += '<div class="action-consequence">' + esc(a.consequence) + '</div>';
  main += '</div>';
  return '<div class="' + cls + '">' + main + '<div class="action-controls">' + actionButtonHTML(a) + '</div></div>';
}

function renderActionsCatalog(actions) {
  const el = document.getElementById('actions-catalog');
  if (!el) return;
  if (!actions.length) { el.innerHTML = '<div class="placeholder">No actions available.</div>'; return; }
  const cats = {};
  for (const a of actions) {
    const c = a.category || 'general';
    (cats[c] = cats[c] || []).push(a);
  }
  let h = '';
  for (const [cat, acts] of Object.entries(cats)) {
    const destructiveCount = acts.filter(a => a.isDestructive).length;
    h += '<div class="action-group"><div class="action-group-head"><h2>' + esc(titleCaseCategory(cat)) + '</h2>' +
      '<span class="action-group-count">' + acts.length + ' action' + (acts.length === 1 ? '' : 's') +
      ' · ' + destructiveCount + ' destructive</span></div>' + acts.map(actionRowHTML).join('') + '</div>';
  }
  el.innerHTML = h;
}

function followInLogs(name) {
  showTab('logs');
  logFilter.query = name;
  const input = document.getElementById('logs-search-input');
  if (input) input.value = name;
  renderLogsView();
}

async function runAction(name, isDestructive, consequence) {
  if (isDestructive && !confirm(consequence || 'This action is destructive. Proceed?')) return;
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
    if (name === 'clear-logs') api('/api/logs?count=500').then(handleLogsData).catch(() => {});
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
  if (isDetached) {
    document.body.classList.add('detached-logs');
    showTab('logs');
    window.addEventListener('beforeunload', () => saveWinRect('logs'));
  }
  refresh();
  clearInterval(refreshIntervalId);
  countdown = 5;
  refreshIntervalId = setInterval(() => {
    countdown--;
    const label = 'refresh in ' + countdown + 's';
    const logNext = document.getElementById('log-next-refresh');
    const logsNext = document.getElementById('logs-next-refresh');
    if (logNext) logNext.textContent = label;
    if (logsNext) logsNext.textContent = label;
    if (countdown <= 0) { countdown = 5; refresh(); }
  }, 1000);
}

// Enter key in token field
document.getElementById('token-input').addEventListener('keydown', e => {
  if (e.key === 'Enter') connect();
});

// Logs viewer toolbar listeners (present in every document — the detached
// window is this same page, just with chrome hidden via body.detached-logs).
document.getElementById('logs-search-input').addEventListener('input', e => {
  logFilter.query = e.target.value;
  renderLogsView();
});
document.getElementById('logs-follow-checkbox').addEventListener('change', e => {
  logFilter.follow = e.target.checked;
  renderLogsView();
});

// Auto-connect if a token is already in sessionStorage
if (token) showDashboard();
</script>
"""#
}
