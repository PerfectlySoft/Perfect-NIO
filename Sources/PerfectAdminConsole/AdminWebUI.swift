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
/* ---- Phase 11: Settings tab (admin-console UI redesign phase 5) ---- */
.settings-header{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;margin-bottom:14px}
.settings-header p{color:var(--color-neutral-700);font-size:13px;max-width:640px}
.dashed-strip{border:1px dashed var(--color-neutral-400);padding:16px;margin-top:14px}
.settings-inert-heading{font-family:var(--font-heading);font-weight:600;font-size:17px}
/* ---- Phase 12: Overview redesign, crawl-report screen, token gate (admin-console UI redesign phase 6) ---- */
.overview-grid{display:grid;grid-template-columns:1.15fr .85fr;gap:14px;align-items:start}
@media (max-width:900px){.overview-grid{grid-template-columns:1fr}}
.overview-col{display:flex;flex-direction:column;gap:14px}
.attention-item{border-left:3px solid var(--color-alert);padding:8px 10px;margin-bottom:8px}
.attention-item.advisory{border-left-color:var(--color-neutral-400)}
.attention-item-title{font-weight:500;font-size:14px}
.attention-item-time{font-family:var(--font-mono);font-size:11px;color:var(--color-neutral-600)}
.attention-item-note{font-size:12px;color:var(--color-neutral-700);margin-top:2px}
.attention-item-actions{display:flex;gap:10px;align-items:center;margin-top:6px}
.activity-row{display:grid;grid-template-columns:1.4fr .8fr 1fr auto;gap:8px;align-items:center;padding:6px 0;border-bottom:1px solid var(--color-divider);font-size:12px}
.activity-row:last-child{border-bottom:none}
.traffic-numbers{display:flex;gap:24px;margin-bottom:10px}
.traffic-number-label{font-size:11px;color:var(--color-neutral-600);text-transform:uppercase;letter-spacing:.04em}
.traffic-number-value{font-family:var(--font-heading);font-weight:600;font-size:30px}
.traffic-spark{display:block;margin:6px 0 12px}
.gate-why{border-left:3px solid var(--color-accent);padding:6px 12px;text-align:left;font-size:12px;color:var(--color-neutral-700);max-width:340px}
.report-stats{display:flex;gap:24px;margin-bottom:14px}
.report-stat-label{font-size:11px;color:var(--color-neutral-600);text-transform:uppercase;letter-spacing:.04em}
.report-stat-value{font-family:var(--font-heading);font-weight:600;font-size:26px}
body.detached-activity .titlebar,body.detached-activity .tab-bar,body.detached-activity .state-strip{display:none}
body.detached-activity main{max-width:none;padding:0}
body.detached-activity .tab-panel{padding:16px}
body.detached-activity #attention-card,body.detached-activity #log-card,body.detached-activity .overview-col:last-child{display:none}
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
  <p class="gate-why" id="gate-why">This bearer token authenticates every admin API request.</p>
  <p>Enter the bearer token from<br><code id="path-hint"></code></p>
  <input id="token-input" type="password" placeholder="paste token here" autocomplete="off" spellcheck="false">
  <label class="log-follow" id="remember-row" style="display:none;justify-content:center">
    <input type="checkbox" id="remember-checkbox" checked> Remember on this machine
  </label>
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
      <div class="overview-grid">
        <div class="overview-col">
          <div class="card" id="attention-card"><h2>Needs attention</h2><div id="attention-rows"><div class="row"><span class="rl">Loading…</span></div></div></div>
          <div class="card" id="activity-card">
            <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
              <h2 style="margin-bottom:0">Activity</h2>
              <div style="display:flex;align-items:center;gap:8px">
                <button class="mini-btn" onclick="expandActivity()" id="activity-expand-btn">Expand</button>
                <button class="icon-btn" onclick="openDetachedWindow('activity')" title="Open in new window" aria-label="Open in new window">⧉</button>
              </div>
            </div>
            <div id="activity-rows"><div class="row"><span class="rl">Loading…</span></div></div>
          </div>
          <div class="card" id="log-card">
            <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
              <h2 style="margin-bottom:0">Recent Log</h2>
              <div style="display:flex;align-items:center;gap:8px">
                <span id="log-next-refresh" style="font-size:11px;color:var(--color-neutral-600)"></span>
                <button class="mini-btn" onclick="showTab('logs')">Open full view</button>
                <button class="icon-btn" onclick="openDetachedWindow('logs')" title="Open in new window" aria-label="Open in new window">⧉</button>
              </div>
            </div>
            <div class="log-surface-base log-surface-mini" id="log-box">Loading…</div>
          </div>
        </div>
        <div class="overview-col">
          <div class="card" id="traffic-card"><h2>Traffic</h2><div id="traffic-content"><div class="row"><span class="rl">Loading…</span></div></div></div>
          <div class="card" id="datasources-summary-card">
            <h2>Datasources</h2>
            <div id="datasources-summary-rows"></div>
            <button class="action-ghost" onclick="showTab('data')" style="margin-top:8px">Open Data tab</button>
          </div>
          <div class="card" id="quick-actions-card"><h2>Quick actions</h2><div id="quick-actions-rows"></div>
            <p style="font-size:11px;color:var(--color-neutral-600);margin-top:8px">Destructive actions live in the Actions tab only.</p>
          </div>
        </div>
      </div>
    </div>
    <div class="tab-panel" id="tab-data">
      <div class="card" id="models-card"><h2>Models</h2><div id="models-content"><div class="row"><span class="rl">Loading…</span></div></div></div>
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
          <button class="icon-btn" onclick="openDetachedWindow('logs')" title="Open in new window" aria-label="Open in new window">⧉</button>
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
      <div class="settings-header">
        <p>Values come from the environment and the datasources file at startup; changing one means editing config and restarting.</p>
        <button class="action-ghost" onclick="copySettingsText()">Copy all as text</button>
      </div>
      <div class="grid" id="settings-grid">
        <div id="admin-access-mount" style="display:contents"></div>
        <div id="settings-delegate-mount" style="display:contents"></div>
      </div>
      <div class="dashed-strip" id="settings-inert-strip" style="display:none">
        <div class="settings-inert-heading">NOT IN USE ON THIS SERVER</div>
        <p id="settings-inert-sentence"></p>
        <button class="action-ghost" id="settings-inert-toggle" onclick="toggleInertPanels()">Show anyway (0)</button>
      </div>
      <div class="grid" id="settings-inert-grid" style="margin-top:14px">
        <div class="card" id="tls-domains-card"><h2>TLS Domains</h2><div id="tls-content"><div class="row"><span class="rl">Loading…</span></div></div></div>
        <div class="card" id="acme-challenges-card"><h2>ACME Challenges</h2><div id="acme-rows"><div class="row"><span class="rl">Loading…</span></div></div></div>
      </div>
    </div>
    <div class="tab-panel" id="tab-report">
      <div id="report-content"><div class="placeholder">No report loaded</div></div>
    </div>
  </main>
</div>
<div id="toast-container"></div>

"""#

    private static let scriptBlock = #"""
<script>
'use strict';
const KEY = 'perfectAdminToken';
let token = localStorage.getItem(KEY) || sessionStorage.getItem(KEY) || '';
let refreshIntervalId = null;
let countdown = 5;
let logFilter = { query: '', subsystem: 'all', follow: true };
let lastLogEntries = [];
let lastLogTotal = 0;
let lastLogCapacity = 0;
let detachedWindowRefs = {};
const detachedViewer = new URLSearchParams(location.search).get('detached');

// Inject server-side token path hint
const tokenFilePath = {{TOKEN_PATH_JSON}};
document.getElementById('path-hint').textContent = tokenFilePath;
let lastStatus = null;
let lastActions = [];
let settingsInertExpanded = false;
let activityExpanded = false;
let currentReport = null;
let reportFilter = 'all';

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
  // 'report' is a drill-down reached from Activity/Actions, not a persistent tab-bar
  // entry — its content isn't regenerated on reconnect, so it's never restored.
  if (name !== 'report') sessionStorage.setItem('perfectAdminActiveTab', name);
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
  if (r.status === 401) { logout('expired'); throw new Error('401'); }
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
    lastStatus = status;
    lastActions = actions.actions || [];
    renderStateStrip(status, metrics);
    renderTLS(tls);
    renderACME(acme);
    handleLogsData(logs);
    renderAdminAccessCard(status);
    renderRoutes(routes);
    renderDelegateSections(status.additionalSections || []);
    renderSettingsInertStrip(status);
    renderDataTab(datasources);
    renderModels(models);
    renderTraffic(metrics);
    renderAttentionCard(datasources.datasources || [], status.recentJobRuns || [], lastActions);
    renderActivityCard(status.currentJob, status.recentJobRuns || []);
    renderDatasourcesSummary(datasources.datasources || []);
    renderQuickActions(lastActions);
    // Re-rendered every cycle (not just on first load) so an action whose
    // description reflects live state — e.g. a crawl-report delegate
    // showing "Running now — 340/1,989 pages" — updates without a reload.
    renderActionsCatalog(lastActions);
    document.getElementById('refresh-badge').textContent =
      'live · updated ' + new Date().toLocaleTimeString();
  } catch(e) {
    if (e.message === '401') return;
    setServing(false);
    document.getElementById('refresh-badge').textContent = 'error: ' + e.message;
  }
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
// see detachedViewer above and showDashboard() below).

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
    if (r.status === 401) { logout('expired'); return; }
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

// Generalized so any card can pop out to its own remembered-size/position
// window — "logs" was the only viewer through Phase 8; "activity" reuses
// the exact same mechanism, not a new one.
function openDetachedWindow(viewer) {
  const ref = detachedWindowRefs[viewer];
  if (ref && !ref.closed) { ref.focus(); return; }
  const rect = loadWinRect(viewer, { w: 900, h: 620, x: window.screenX + 40, y: window.screenY + 40 });
  detachedWindowRefs[viewer] = window.open(
    location.pathname + '?detached=' + viewer,
    'perfect-admin-' + viewer,
    'width=' + rect.w + ',height=' + rect.h + ',left=' + rect.x + ',top=' + rect.y
  );
}

function renderRoutes(r) {
  const label = document.getElementById('admin-routes-count-label');
  if (label) label.textContent = 'Registered routes · ' + r.routes.length;
  const tagsEl = document.getElementById('admin-routes-tags');
  if (!tagsEl) return;
  if (!r.routes.length) {
    tagsEl.innerHTML = '<span style="color:var(--color-neutral-600);font-size:12px">No routes from delegate</span>';
    return;
  }
  tagsEl.innerHTML = r.routes.map(u => '<span class="tag">' + esc(u) + '</span>').join('');
}

// ---- Phase 12: Traffic card (admin-console UI redesign phase 6) ----
// "Recent" numbers, not all-time totals — summed across the trailing
// rate-bucket history (an hour, at AdminMetrics' current 5-min/12-bucket
// sizing), which is what a Traffic card should show. All-time totals/error
// rate/connections already live in the state-strip on every tab.

function renderTrafficSparkline(history) {
  const w = 240, h = 40, barW = history.length ? w / history.length : w;
  const max = Math.max(1, ...history.map(b => b.requests));
  const bars = history.map((b, i) => {
    const barH = Math.max(1, Math.round((b.requests / max) * (h - 2)));
    const x = Math.round(i * barW);
    const fill = b.errors > 0 ? 'var(--color-alert)' : 'var(--color-accent-300)';
    return '<rect x="' + x + '" y="' + (h - barH) + '" width="' + Math.max(1, barW - 2) + '" height="' + barH + '" fill="' + fill + '"></rect>';
  }).join('');
  return '<svg class="traffic-spark" width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + ' ' + h + '">' + bars + '</svg>';
}

function renderTraffic(m) {
  const history = m.rateHistory || [];
  const requests = history.reduce((sum, b) => sum + b.requests, 0);
  const errors = history.reduce((sum, b) => sum + b.errors, 0);
  let h = '<div class="traffic-numbers">' +
    '<div><div class="traffic-number-label">Requests</div><div class="traffic-number-value">' + requests.toLocaleString() + '</div></div>' +
    '<div><div class="traffic-number-label">Errors</div><div class="traffic-number-value" style="' + (errors > 0 ? 'color:var(--color-alert-text)' : '') + '">' + errors.toLocaleString() + '</div></div>' +
    '</div>';
  h += renderTrafficSparkline(history);
  const topRoutes = Object.entries(m.routeCounts || {}).sort((a, b) => b[1] - a[1]).slice(0, 3);
  if (topRoutes.length) {
    h += '<div style="margin-top:4px;font-size:11px;color:var(--color-neutral-600);font-weight:600;letter-spacing:.04em">TOP ROUTES</div>';
    for (const [route, count] of topRoutes) h += row(route, count.toLocaleString());
  }
  document.getElementById('traffic-content').innerHTML = h;
}

// ---- Phase 12: Needs attention card ----
// Built entirely from data already fetched by refresh()'s Promise.all — no
// extra request. Failing datasources (typed `status` field) and failed
// recent job runs (typed `succeeded` boolean) are the two honest, already-
// typed "something's wrong" signals; nothing here is inferred from
// free-text messages.

function renderAttentionCard(datasources, jobRuns, actions) {
  const items = [];
  for (const ds of datasources) {
    if (ds.status !== 'failing') continue;
    const safeName = esc(ds.name).replace(/'/g, "\\'");
    items.push({
      title: "Datasource '" + (ds.alias || ds.name) + "' failing",
      time: ds.lastAttempt ? fmtClock(ds.lastAttempt.ts) : '',
      note: ds.correlationNote || (ds.lastAttempt ? ds.lastAttempt.message : ''),
      actionsHtml: '<button class="mini-btn" onclick="testDS(\'' + safeName + '\')">Test now</button>' +
        '<button class="action-ghost" onclick="followInLogs(\'' + safeName + '\')">See in Logs</button>',
    });
  }
  for (const run of jobRuns) {
    if (run.succeeded) continue;
    const safeName = esc(run.name).replace(/'/g, "\\'");
    items.push({
      title: "'" + run.name + "' failed",
      time: fmtClock(run.finishedAt),
      note: run.summary,
      actionsHtml: '<button class="action-ghost" onclick="openActionReport(\'' + safeName + '\')">See report</button>' +
        '<button class="action-ghost" onclick="followInLogs(\'' + safeName + '\')">See in Logs</button>',
    });
  }
  const el = document.getElementById('attention-rows');
  const heading = document.querySelector('#attention-card h2');
  if (heading) heading.textContent = items.length ? 'Needs attention · ' + items.length + ' failing' : 'Needs attention';
  if (!items.length) {
    el.innerHTML = '<div class="row"><span class="rl" style="color:var(--color-neutral-600)">Nothing else outstanding.</span></div>';
    return;
  }
  el.innerHTML = items.map(it =>
    '<div class="attention-item"><div class="attention-item-title">' + esc(it.title) + '</div>' +
    (it.time ? '<div class="attention-item-time">' + esc(it.time) + '</div>' : '') +
    (it.note ? '<div class="attention-item-note">' + esc(it.note) + '</div>' : '') +
    '<div class="attention-item-actions">' + it.actionsHtml + '</div></div>'
  ).join('');
}

// ---- Phase 12: Activity card ----
// currentJob() (in-flight) + recentJobRuns() (finished), most recent first.
// `activityExpanded` toggles compact (3 rows) vs full list, re-rendered from
// the last-fetched data rather than a re-fetch, matching the Settings tab's
// inert-strip toggle precedent.

let lastJobRuns = [];
let lastCurrentJob = null;

function renderActivityCard(currentJob, jobRuns) {
  lastCurrentJob = currentJob;
  lastJobRuns = jobRuns;
  renderActivityRows();
}

function activityRowHTML(name, stateHtml, startedLabel, actionHtml) {
  return '<div class="activity-row"><span>' + esc(name) + '</span>' + stateHtml +
    '<span style="font-family:var(--font-mono);color:var(--color-neutral-600)">' + esc(startedLabel) + '</span>' +
    '<span>' + actionHtml + '</span></div>';
}

function renderActivityRows() {
  const el = document.getElementById('activity-rows');
  const rows = [];
  if (lastCurrentJob) {
    const pct = lastCurrentJob.total > 0 ? Math.min(100, Math.round(lastCurrentJob.completed / lastCurrentJob.total * 100)) : 0;
    const safeName = esc(lastCurrentJob.name).replace(/'/g, "\\'");
    rows.push(activityRowHTML(
      lastCurrentJob.name,
      '<span class="job-bar"><span class="job-bar-fill" style="width:' + pct + '%"></span></span>',
      'running now',
      '<button class="action-ghost" onclick="followInLogs(\'' + safeName + '\')">Follow</button>'
    ));
  }
  const shown = activityExpanded ? lastJobRuns : lastJobRuns.slice(0, 3);
  for (const run of shown) {
    const safeName = esc(run.name).replace(/'/g, "\\'");
    const tag = run.succeeded
      ? '<span class="action-tag" style="border:1px solid var(--color-accent);color:var(--color-accent-700)">done</span>'
      : '<span class="action-tag action-tag-destructive">failed</span>';
    rows.push(activityRowHTML(run.name, tag, fmtClock(run.finishedAt), '<button class="action-ghost" onclick="openActionReport(\'' + safeName + '\')">Log</button>'));
  }
  if (!rows.length) { el.innerHTML = '<div class="row"><span class="rl" style="color:var(--color-neutral-600)">No jobs have run yet.</span></div>'; return; }
  el.innerHTML = rows.join('');
  const btn = document.getElementById('activity-expand-btn');
  if (btn) btn.textContent = activityExpanded ? 'Collapse' : 'Expand';
}

function expandActivity() {
  activityExpanded = !activityExpanded;
  renderActivityRows();
}

// ---- Phase 12: Datasources summary + Quick actions cards ----
// Both are filtered subsets of data the Data/Actions tabs already render in
// full — no new fetch, no new tracking.

function renderDatasourcesSummary(datasources) {
  const el = document.getElementById('datasources-summary-rows');
  if (!datasources.length) { el.innerHTML = '<div class="row"><span class="rl" style="color:var(--color-neutral-600)">No datasources registered</span></div>'; return; }
  el.innerHTML = datasources.map(ds => {
    const sqClass = ds.status === 'failing' ? 'failing' : ds.status === 'not-tested' ? 'not-tested' : '';
    return '<div class="row"><span class="rl" style="display:flex;align-items:center;gap:6px">' +
      '<span class="data-status-square ' + sqClass + '"></span>' + esc(ds.alias || ds.name) + '</span>' +
      '<span class="rv" style="font-size:12px;color:var(--color-neutral-600)">' + esc(dataStatusLabel(ds.status)) + '</span></div>';
  }).join('');
}

function renderQuickActions(actions) {
  const el = document.getElementById('quick-actions-rows');
  const safe = actions.filter(a => !a.isDestructive);
  if (!safe.length) { el.innerHTML = '<div class="row"><span class="rl" style="color:var(--color-neutral-600)">No non-destructive actions available</span></div>'; return; }
  el.innerHTML = safe.map(a =>
    '<div class="row"><span class="rl">' + esc(a.label) + '</span><span class="rv">' + actionButtonHTML(a) + '</span></div>'
  ).join('');
}

async function tlsReload(hostname) {
  try {
    const r = await fetch('/api/tls/reload', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + token, 'X-Admin-CSRF': '1', 'Content-Type': 'application/json' },
      body: JSON.stringify({ hostname })
    });
    if (r.status === 401) { logout('expired'); return; }
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
    if (r.status === 401) { logout('expired'); return; }
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
    if (r.status === 401) { logout('expired'); return; }
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
    if (r.status === 401) { logout('expired'); return; }
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

// ---- Phase 11: Settings tab (admin-console UI redesign phase 5) ----
// additionalStatusSections() moves its mount point here from Overview's old
// #delegate-cards (removed, not duplicated). Admin access is fully generic:
// bind/auth are protocol-level constants, token file reuses the value
// already injected for the auth-gate hint, "Rotates" reports this
// instance's real tokenRotatesOnRestart value rather than assuming restart
// always rotates. Sessions/ARMED-tag styling/live session counts are
// explicitly out of scope here -- Phase 6, Lasso-specific wiring.

function adminAccessCardHTML(status) {
  const bind = '127.0.0.1:' + status.adminPort;
  const rotates = status.tokenRotatesOnRestart
    ? 'on every restart'
    : 'persists across restarts (reused from disk)';
  return '<div class="card"><h2>Admin access</h2>' +
    row('Bind', bind) +
    row('Auth', 'Bearer token') +
    row('Token file', tokenFilePath) +
    row('Rotates', rotates) +
    '<div style="margin-top:10px;font-size:11px;font-weight:600;letter-spacing:.04em;color:var(--color-neutral-700)" id="admin-routes-count-label">Registered routes · 0</div>' +
    '<div style="margin-top:4px" id="admin-routes-tags"></div>' +
    '</div>';
}

function renderAdminAccessCard(status) {
  document.getElementById('admin-access-mount').innerHTML = adminAccessCardHTML(status);
}

function renderDelegateSections(sections) {
  const el = document.getElementById('settings-delegate-mount');
  el.innerHTML = (sections || []).map(s => {
    const alertKeys = new Set(s.alertKeys || []);
    const rows = Object.entries(s.items).map(([k, v]) =>
      alertKeys.has(k)
        ? '<div class="row"><span class="rl">' + esc(k) + '</span><span class="rv"><span class="data-tag data-tag-failing">' + esc(v) + '</span></span></div>'
        : row(k, v)
    ).join('');
    return '<div class="card"><h2>' + esc(s.title) + '</h2>' + rows + '</div>';
  }).join('');
}

function renderSettingsInertStrip(status) {
  const hasTLS = status.tlsDomainCount > 0 || status.tlsHasDefault;
  const acmeConfigured = !!status.acmeConfigured;
  const inert = [];
  if (!hasTLS) inert.push('TLS Domains');
  if (!acmeConfigured) inert.push('ACME Challenges');

  const tlsCard = document.getElementById('tls-domains-card');
  const acmeCard = document.getElementById('acme-challenges-card');
  if (tlsCard) tlsCard.style.display = (!hasTLS && !settingsInertExpanded) ? 'none' : '';
  if (acmeCard) acmeCard.style.display = (!acmeConfigured && !settingsInertExpanded) ? 'none' : '';

  const strip = document.getElementById('settings-inert-strip');
  if (!strip) return;
  if (!inert.length) { strip.style.display = 'none'; return; }
  strip.style.display = '';
  document.getElementById('settings-inert-sentence').textContent =
    inert.join(' and ') + (inert.length > 1 ? ' are' : ' is') + ' not in use on this server.';
  document.getElementById('settings-inert-toggle').textContent =
    (settingsInertExpanded ? 'Hide' : 'Show anyway') + ' (' + inert.length + ')';
}

function toggleInertPanels() {
  settingsInertExpanded = !settingsInertExpanded;
  if (lastStatus) renderSettingsInertStrip(lastStatus);
}

async function copySettingsText() {
  try {
    await navigator.clipboard.writeText(document.getElementById('tab-settings').innerText);
    showToast('Settings copied to clipboard', 'ok');
  } catch (e) {
    showToast('Copy failed: ' + e.message, 'err');
  }
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

// ---- Phase 12: Crawl-report-result screen (admin-console UI redesign phase 6) ----
// Ships as a 6th tab-panel rather than a modal -- nothing in this codebase has
// modal semantics (focus trap, backdrop-click, ESC) to build on, and a
// tab-panel reuses the exact showTab()/.tab-panel.active plumbing every other
// tab already uses. Generic: renders whatever AdminActionReport a delegate
// returns for any action, not just a crawl.

async function openActionReport(name) {
  try {
    const data = await api('/api/actions/report?name=' + encodeURIComponent(name));
    renderActionReportOverlay(data.report, name);
    showTab('report');
  } catch (e) {
    showToast('Could not load report: ' + e.message, 'err');
  }
}

function computeReportStatusCounts(report) {
  const counts = new Map();
  for (const g of report.groups) {
    for (const r of g.rows) counts.set(r.status, (counts.get(r.status) || 0) + 1);
  }
  return counts;
}

function renderReportFilterChips(report) {
  const counts = computeReportStatusCounts(report);
  const total = Array.from(counts.values()).reduce((a, b) => a + b, 0);
  let h = '<span class="' + (reportFilter === 'all' ? 'tag-outline' : 'tag-neutral') + '" onclick="setReportFilter(\'all\')">all ' + total + '</span>';
  for (const [status, count] of counts) {
    const cls = reportFilter === status ? 'tag-outline' : 'tag-neutral';
    const safe = esc(status).replace(/'/g, "\\'");
    h += '<span class="' + cls + '" onclick="setReportFilter(\'' + safe + '\')">' + esc(status) + ' ' + count + '</span>';
  }
  return h;
}

function setReportFilter(status) {
  reportFilter = status;
  if (currentReport) renderActionReportOverlay(currentReport, currentReport.actionName);
}

function renderActionReportOverlay(report, actionName) {
  currentReport = report;
  const el = document.getElementById('report-content');
  if (!report) {
    el.innerHTML = '<div class="placeholder">No report available for \'' + esc(actionName) + '\'.</div>';
    return;
  }
  const when = new Date(report.generatedAt * 1000).toLocaleString();
  const safeName = esc(actionName).replace(/'/g, "\\'");
  let h = '<div style="display:flex;justify-content:space-between;align-items:flex-start;gap:16px;margin-bottom:14px">';
  h += '<div><span class="action-ghost" onclick="showTab(\'actions\')">Actions</span> / ' +
    '<span style="font-family:var(--font-heading);font-weight:600;text-transform:uppercase;letter-spacing:.04em">' +
    esc(report.actionName) + '</span> · ' + esc(when) + '</div>';
  h += '<div style="display:flex;gap:8px;flex-shrink:0">' +
    '<button class="mini-btn" onclick="downloadReportCSV()">Download CSV</button>' +
    '<button class="mini-btn" onclick="reRunReportedAction(\'' + safeName + '\')">Re-run</button></div>';
  h += '</div>';
  if (report.summary) h += '<p style="color:var(--color-neutral-700);font-size:13px;margin-bottom:14px">' + esc(report.summary) + '</p>';
  h += '<div class="report-stats">' + report.stats.map(s =>
    '<div><div class="report-stat-label">' + esc(s.label) + '</div><div class="report-stat-value" style="' +
    (s.isAlert ? 'color:var(--color-alert-text)' : '') + '">' + esc(s.value) + '</div></div>'
  ).join('') + '</div>';
  h += '<div class="log-chips" style="margin-bottom:14px">' + renderReportFilterChips(report) + '</div>';
  for (const group of report.groups) {
    const rows = reportFilter === 'all' ? group.rows : group.rows.filter(r => r.status === reportFilter);
    if (!rows.length) continue;
    h += '<div class="action-group"><div class="action-group-head"><h2>' + esc(group.heading) + '</h2>' +
      '<span class="action-group-count">×' + rows.length + '</span></div>';
    h += '<table class="data-history-table"><thead><tr><th>Page</th><th>Status</th><th>Detail</th><th>Elapsed</th></tr></thead><tbody>';
    h += rows.map(r =>
      '<tr><td>' + esc(r.label) + '</td><td>' + esc(r.status) + '</td><td>' + esc(r.detail || '') + '</td>' +
      '<td>' + (r.elapsedMS != null ? r.elapsedMS + 'ms' : '—') + '</td></tr>'
    ).join('');
    h += '</tbody></table></div>';
  }
  const allRows = report.groups.flatMap(g => g.rows);
  const failing = allRows.filter(r => r.status !== 'clean' && r.status !== 'excluded');
  const topGroup = report.groups.slice().sort((a, b) => b.rows.length - a.rows.length)[0];
  if (topGroup && failing.length && topGroup.rows.length > 1) {
    h += '<p style="font-size:12px;color:var(--color-neutral-700);margin-top:8px">' +
      topGroup.rows.length + ' of ' + failing.length + ' failures share one cause: ' + esc(topGroup.heading) + '.</p>';
  }
  el.innerHTML = h;
}

function currentReportRows() {
  if (!currentReport) return [];
  return currentReport.groups.flatMap(g => g.rows.map(r => ({ heading: g.heading, ...r })));
}

function downloadReportCSV() {
  const rows = currentReportRows();
  const csvEscape = v => '"' + String(v == null ? '' : v).replace(/"/g, '""') + '"';
  const lines = ['Group,Page,Status,Detail,ElapsedMS'];
  for (const r of rows) lines.push([r.heading, r.label, r.status, r.detail, r.elapsedMS].map(csvEscape).join(','));
  const blob = new Blob([lines.join('\n')], { type: 'text/csv' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'admin-console-report-' + Date.now() + '.csv';
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

function reRunReportedAction(name) {
  const action = lastActions.find(a => a.name === name);
  if (!action) { showToast('Action no longer available', 'err'); return; }
  runAction(action.name, action.isDestructive, action.consequence);
}

async function runAction(name, isDestructive, consequence) {
  if (isDestructive && !confirm(consequence || 'This action is destructive. Proceed?')) return;
  try {
    const r = await fetch('/api/actions', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + token, 'X-Admin-CSRF': '1', 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: name })
    });
    if (r.status === 401) { logout('expired'); return; }
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
    const remember = document.getElementById('remember-checkbox').checked;
    if (remember) { localStorage.setItem(KEY, token); sessionStorage.removeItem(KEY); }
    else { sessionStorage.setItem(KEY, token); localStorage.removeItem(KEY); }
    showDashboard();
  } catch(e) {
    if (e.message === '401') {
      document.getElementById('auth-err').style.display = 'block';
      token = '';
    }
  }
}

// `reason === 'expired'` marks this as an auth-driven kick (a 401, not the
// Disconnect button) so the gate's why-line can tell the two apart on
// next load — see initGate().
function logout(reason) {
  sessionStorage.removeItem(KEY);
  localStorage.removeItem(KEY);
  token = '';
  clearInterval(refreshIntervalId);
  document.getElementById('dashboard').style.display = 'none';
  document.getElementById('auth-gate').style.display = 'flex';
  if (reason === 'expired') sessionStorage.setItem('perfectAdminKicked', '1');
}

// Best-effort: populates the gate's why-line and shows/hides the remember
// checkbox based on whether this instance's token survives a restart
// (fetched unauthenticated, since there's no token yet at this point).
// gate-info failing (e.g. an older server without this route) just leaves
// the static default why-line in place -- the token field still works.
async function initGate() {
  try {
    const info = await fetch('/api/gate-info').then(r => r.json());
    const wasKicked = sessionStorage.getItem('perfectAdminKicked') === '1';
    sessionStorage.removeItem('perfectAdminKicked');
    const why = document.getElementById('gate-why');
    if (wasKicked) {
      why.textContent = info.tokenRotatesOnRestart
        ? 'The server restarted and rotated its token. Paste the new one below.'
        : 'Your session token was rejected. Paste the current one below.';
    } else if (!info.tokenRotatesOnRestart) {
      why.textContent = 'This token persists across restarts — check "Remember" to skip re-pasting it next time.';
    }
    const rememberRow = document.getElementById('remember-row');
    if (rememberRow) rememberRow.style.display = info.tokenRotatesOnRestart ? 'none' : '';
  } catch (e) { /* best-effort */ }
}

function showDashboard() {
  document.getElementById('auth-gate').style.display = 'none';
  document.getElementById('dashboard').style.display = 'block';
  if (detachedViewer === 'logs') {
    document.body.classList.add('detached-logs');
    showTab('logs');
    window.addEventListener('beforeunload', () => saveWinRect('logs'));
  } else if (detachedViewer === 'activity') {
    document.body.classList.add('detached-activity');
    showTab('overview');
    window.addEventListener('beforeunload', () => saveWinRect('activity'));
  } else {
    const savedTab = sessionStorage.getItem('perfectAdminActiveTab');
    if (savedTab && savedTab !== 'report') showTab(savedTab);
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

// Auto-connect if a token is already remembered (localStorage) or from this
// same tab session (sessionStorage); otherwise populate the gate's why-line.
if (token) showDashboard();
else initGate();
</script>
"""#
}
