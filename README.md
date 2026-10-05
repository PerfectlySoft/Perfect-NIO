<p align="center">
    <a href="https://developer.apple.com/swift/" target="_blank">
        <img src="https://img.shields.io/badge/Swift-6.2-orange.svg?style=flat" alt="Swift 6.2">
    </a>
    <a href="https://developer.apple.com/swift/" target="_blank">
        <img src="https://img.shields.io/badge/Platforms-macOS%2012%2B%20%7C%20Linux-lightgray.svg?style=flat" alt="Platforms macOS 12+ | Linux">
    </a>
    <a href="http://perfect.org/licensing.html" target="_blank">
        <img src="https://img.shields.io/badge/License-Apache-lightgrey.svg?style=flat" alt="License Apache">
    </a>
</p>

# PerfectNIO

A Swift 6 HTTP(S) server library built on SwiftNIO. Routes are a composable, strongly-typed pipeline: each step accepts one type and produces another, terminating in an `HTTPOutput` that writes the response. This is the modernized rewrite target for the Perfect ecosystem's HTTP layer.

**Role:** PerfectNIO is the core HTTP/server layer here — depended on directly by `FMTestApp` and `PerfectTemplate`, and includes multi-tenant TLS, an admin console, and graceful restart support. Logging is done via `import Logging` (apple/swift-log) directly — there is no dependency on Perfect-Logger.

The pre-Swift-6 version of this package is preserved on the [`legacy`](../../tree/legacy) branch.

- [Quick start](#quick-start)
- [Package.swift](#packageswift)
- [Routing](#routing)
- [Route operations](#route-operations)
- [HTTP methods](#http-methods)
- [Output types](#output-types)
- [Custom HTTPOutput](#custom-httpoutput)
- [WebSocket](#websocket)
- [TLS / HTTPS](#tls--https)
- [Admin console](#admin-console)
- [PerfectNIOCRUD](#perfectniocrud)
- [Reference](#reference)
- [Linux support](#linux-support)

---

## Quick start

```swift
// Sources/MyServer/main.swift
import PerfectNIO

let routes = root { "Hello, world!" }.text()
try await Server(routes: routes, port: 8080).run()
```

Build and run with `swift run`. The server listens on port 8080 and responds to every request with `Hello, world!`.

> **Request bodies are capped at 10 MiB by default, uploads included.** The whole body is held in memory before your route runs, so the server refuses anything larger with **413 Payload Too Large** (see [Request body size limit](#request-body-size-limit)). If your app accepts larger uploads, raise the cap when you create the server:
>
> ```swift
> try await Server(routes: routes, port: 8080, maxRequestBodySize: 100 * 1024 * 1024).run()  // 100 MiB; nil = no limit
> ```

The package also builds a `PerfectNIOExe` executable target (`Sources/PerfectNIOExe/main.swift`) — a minimal smoke-test binary, not a required entry point. Host applications define their own executable target as shown above.

### Scoped server (useful in tests)

```swift
try await Server(routes: routes, port: 8080).withServer { boundPort in
    // server is live; boundPort is the actually-bound port (useful when port: 0)
}
// server has shut down
```

---

## Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/PerfectlySoft/Perfect-NIO.git", branch: "main"),
],
targets: [
    .target(
        name: "MyServer",
        dependencies: [
            .product(name: "PerfectNIO", package: "Perfect-NIO"),
        ]
    ),
]
```

Your code will typically `import PerfectNIO`. The library re-exports `NIO`, `NIOHTTP1`, and `NIOSSL`, so you usually do not need to import those separately.

**In-ecosystem consumers** (Perfect-Lasso, `FMTestApp`, `PerfectTemplate`) use the same GitHub URL above — no local sibling checkout is needed. This package's own `Package.swift` likewise resolves `PerfectNIOCRUD` and the `PerfectNIOMySQLTests` test target's `Perfect-CRUD`/`Perfect-MySQL` dependencies via `.package(url:, branch: "main")`, not a local path. Cloning this repo on its own and running `swift build`/`swift test` works standalone; fast local cross-repo iteration during development uses a gitignored SwiftPM mirror (`swift package config set-mirror`) instead of editing `Package.swift`.

There is no `PerfectNIOMustache` target — an earlier version of this package had one, but it was deliberately removed (dead weight pulling in an unresurrected `PerfectLib`). Mustache template output is not currently available.

---

## Routing

### root()

Every route tree starts with `root()`. It creates a single route at `/` that passes the `HTTPRequest` through unchanged.

```swift
root()                          // Routes<HTTPRequest, HTTPRequest>
root { "Hello" }               // Routes<HTTPRequest, String> — ignores the request
root { req in req.path }       // Routes<HTTPRequest, String> — uses the request
```

### Path components

Append path segments using Swift dynamic member lookup or the `path` function:

```swift
root().hello.world { "Hello, world!" }.text()   // serves /hello/world
root().path("hello").path("world") { "Hello" }.text()
root().path("hello/world") { "Hello" }.text()   // equivalent
```

Numeric path components are valid via dynamic member lookup even though Swift does not normally allow them as identifiers:

```swift
root().v1.path("2024").reports { loadReports() }.json()
```

### Combining routes

Use `dir` to compose multiple routes into one. `dir` throws `RouteError.duplicatedRoutes` if any two routes resolve to the same URI.

```swift
let routes = try root().dir(
    root().hello { "Hello" },
    root().bye   { "Bye"   }
).text()

try await Server(routes: routes, port: 8080).run()
// serves /hello and /bye
```

Closure form — the argument `$0` is a stand-in for the parent route:

```swift
let routes = try root().v1.dir {[
    $0.foo1 { "OK1" },
    $0.foo2 { "OK2" },
    $0.foo3 { "OK3" },
]}.text()
// serves /v1/foo1, /v1/foo2, /v1/foo3
```

Because routes are strongly typed, all routes passed to `dir` must share the same `OutType`. Mismatches are caught at compile time.

---

## Route operations

All route closures are `async throws`. Return a value to pass it to the next operation, or throw to abort the request.

### map

Transform the current output value into something new.

```swift
// Routes<HTTPRequest, [String]>
let routes = try root().dir {[
    $0.a { 1 }.map { "\($0)" },            // Int → String
    $0.b { [1, 2, 3] }.map { "\($0)" },    // each Int → String
]}.text()
```

### ext

Match a file extension in the URI. Useful for serving the same data in multiple formats.

```swift
struct Report: Codable, CustomStringConvertible {
    let id: Int
    var description: String { "Report \(id)" }
}
let base = root().reports { Report(id: 1) }
let routes = try root().dir(
    base.ext("json").json(),   // /reports.json
    base.ext("txt").text()     // /reports.txt
)
```

### wild

Match a single path segment as a wildcard.

```swift
// /*/suffix — captures the first segment
root().wild { $1 }.suffix.text()

// Named wildcard — value stored in req.uriVariables
root().v1.wild(name: "id").info
    .request { _, req in req.uriVariables["id"] ?? "" }
    .text()
```

### trailing

Match all remaining path segments.

```swift
// /files/** — captures everything after /files/
root().files.trailing { $1 }.text()
// /files/docs/2024/report.txt → "docs/2024/report.txt"
```

### request

Re-expose the `HTTPRequest` to a handler that has already moved to a different value.

```swift
root().hello { "Hello" }.request { greeting, req in
    "\(greeting) from \(req.path)"
}.text()
```

### readBody

Read the request body and branch on content type.

```swift
root().upload.POST.readBody { _, content in
    switch content {
    case .multiPartForm(let form): return "multipart: \(form.bodySpecs.count) parts"
    case .urlForm(let q):          return "form: \(q["name"].first ?? "")"
    case .other(let bytes):        return "raw: \(bytes.count) bytes"
    case .none:                    return "empty"
    }
}.text()
```

#### Request body size limit

The server reads the entire request body into memory before the route runs. That includes multipart file uploads, which are only written to temporary files once the whole body has arrived. To keep one request from exhausting memory, bodies are limited by `Server.maxRequestBodySize`:

- **Default: 10 MiB** (`Server.defaultMaxRequestBodySize`). Set a larger value for servers that take big uploads, or `nil` for no limit. A negative value is treated as 0.
- A request whose `Content-Length` is over the limit gets **413 Payload Too Large** as soon as its headers arrive, before any of the body is read. A chunked body gets the 413 as soon as it grows past the limit. Your route never runs.
- The connection is closed after a 413.
- The limit is per request. Every open connection can hold up to this much at once, so size it with your expected number of concurrent uploads in mind.

```swift
// Accept uploads up to 250 MiB.
let server = Server(routes: routes, port: 8080, maxRequestBodySize: 250 * 1024 * 1024)
```

Uploads are also subject to the process's file-size limit (`RLIMIT_FSIZE`, e.g. `ulimit -f`): an upload that can't be written to its temporary file fails with 413 (file too large) or 507 (disk full). The server ignores `SIGXFSZ` when it starts, unless your app has already set its own handling for it, so hitting that limit fails the request instead of killing the process.

### decode

Read and decode the request body as a `Decodable` type. If the body (or the query and path values) can't be decoded into the type, the client gets **400 Bad Request**; the decoding error itself is logged, not sent back.

```swift
struct CreateUser: Decodable { let name: String; let email: String }

// Decoded value replaces the pipeline value
root().POST.users.decode(CreateUser.self) { user in
    "\(user.name) created"
}.text()

// Both the previous value and the decoded value are available
root().POST.users
    .decode(CreateUser.self) { prev, user in user }
    .json()
```

### statusCheck

Inspect the current value and return an HTTP status. Any non-2xx status aborts the request.

```swift
root().admin
    .statusCheck { req in req.headers["X-Admin-Key"].first == "secret" ? .ok : .forbidden }
    .map { "Welcome, admin" }
    .text()
```

### unwrap

Safely unwrap an `Optional` output. Aborts with 500 if the value is `nil`.

```swift
let routes = try root().dir(
    root().found  { Optional("value") },
    root().missing { Optional<String>.none }
).unwrap { $0 }.text()
// /found → "value", /missing → 500
```

### Auth pattern — statusCheck + unwrap

The canonical auth gate pattern:

```swift
struct Session: Sendable {
    let userId: String
}

func session(from req: any HTTPRequest) -> Session? {
    guard let token = req.headers["Authorization"].first else { return nil }
    return validateToken(token).map { Session(userId: $0) }
}

let protected = root(session(from:))
    .statusCheck { $0 == nil ? .unauthorized : .ok }
    .unwrap { $0 }

// All routes chained from `protected` have access to a non-nil Session
let routes = protected.request { session, _ in session.userId }.text()
```

---

## HTTP methods

Without a method constraint, a route answers any HTTP method. Constrain with a property:

```swift
let routes = try root().dir {[
    $0.GET.users   { listUsers()   }.json(),
    $0.POST.users  { createUser()  }.json(),
    $0.DELETE.users { deleteUsers() }.text(),
]}.text()
```

Accept multiple methods with `method(_:)`:

```swift
root().method(.GET, .HEAD).ping { "pong" }.text()
```

---

## Output types

### text()

Returns the value's `description` with `Content-Type: text/plain`.

```swift
root { 42 }.text()                       // "42"
root { Date() }.text()                    // ISO date string
root().hello { "Hello, world!" }.text()
```

### json()

Encodes an `Encodable` value as JSON with `Content-Type: application/json`.

```swift
struct User: Codable { let id: Int; let name: String }
root().user { User(id: 1, name: "Alice") }.json()
```

### compressed()

Wraps any `HTTPOutput` with gzip/deflate compression. Content shorter than ~14 KB or with an image/video/audio content type is passed through uncompressed.

```swift
root { BytesOutput(body: largeBytes) as HTTPOutput }.compressed()
```

### FileOutput

Serves a local file.

```swift
root().logo {
    try FileOutput(localPath: "/var/www/logo.png") as HTTPOutput
}.ext("png")
```

---

## Custom HTTPOutput

Subclass `HTTPOutput` to produce body data in chunks. Return `nil` from `nextChunk` to signal end of body.

```swift
class StreamOutput: HTTPOutput, @unchecked Sendable {
    var page = 0

    override func head(request: HTTPRequestInfo) -> HTTPHead? {
        HTTPHead(headers: HTTPHeaders([("Content-Type", "text/plain")]))
    }

    override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
        guard page < 16 else { return nil }
        let chunk = String(repeating: "\(page % 10)", count: 1024)
        page += 1
        var buf = allocator.buffer(capacity: chunk.utf8.count)
        buf.writeString(chunk)
        return buf
    }
}

// Combine with .compressed() for streaming compression
let route = root { StreamOutput() as HTTPOutput }.compressed()
```

`closed()` is called once the response is fully written (or on error). Override it to release resources.

```swift
class FileStreamOutput: HTTPOutput, @unchecked Sendable {
    let handle: FileHandle
    init(path: String) throws {
        guard let h = FileHandle(forReadingAtPath: path) else {
            throw ErrorOutput(status: .notFound)
        }
        handle = h
    }
    override func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer? {
        let data = handle.readData(ofLength: 65536)
        guard !data.isEmpty else { return nil }
        var buf = allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        return buf
    }
    override func closed() { handle.closeFile() }
}
```

---

## WebSocket

Declare a WebSocket endpoint with `webSocket(protocol:options:_:)`. The callback runs through the normal route pipeline and returns a `WebSocketHandler` — a closure that drives the live connection.

```swift
let echoRoute = root().echo.webSocket(protocol: "echo") { _ -> WebSocketHandler in
    return { ws in
        while true {
            do {
                switch try await ws.readMessage() {
                case .text(let s):   try await ws.writeMessage(.text(s))
                case .binary(let b): try await ws.writeMessage(.binary(b))
                case .close:         try await ws.writeMessage(.close); return
                default:             break
                }
            } catch { return }
        }
    }
}
```

A WebSocket handshake to a path that does not have a `webSocket()` route is served as ordinary HTTP (returning the route's natural status, typically 404) — per RFC 6455 §4.2.2. Only `webSocket()` routes run during the handshake; any other route runs once, as plain HTTP. A route that returns a hand-built `WebSocketUpgradeHTTPOutput` (its initializer is deprecated) does not upgrade and answers 426 Upgrade Required.

### WebSocketOption

| Option | Effect |
|---|---|
| `.manualClose` | Handler must reply to `.close` frames itself; otherwise auto-close-echo is sent |
| `.manualPing` | Handler must reply to `.ping` frames; otherwise auto-pong is sent |

---

## TLS / HTTPS

Pass a `TLSConfiguration` to `Server`. The private key and certificate can be loaded from PEM files or from embedded bytes.

```swift
import NIOSSL

let cert = try NIOSSLCertificate(file: "/etc/ssl/cert.pem", format: .pem)
let key  = try NIOSSLPrivateKey(file: "/etc/ssl/key.pem",  format: .pem)
let tls  = TLSConfiguration.makeServerConfiguration(
    certificateChain: [.certificate(cert)],
    privateKey: .privateKey(key)
)

try await Server(routes: routes, port: 443, tls: tls).run()
```

### Advanced: multi-tenant / hot-reloadable TLS

Beyond the single static `TLSConfiguration` shown above, `Sources/PerfectNIO` also contains real infrastructure for live, multi-tenant, per-domain TLS:

- `TLSContextManager` — maps hostnames to `NIOSSLContext`s, selected via SNI at handshake time; assign it to `Server`'s `tlsManager` property (see [Reference > Server](#server)) to serve multiple domains, each with its own certificate, from one process.
- `CertificateWatcher` — watches certificate files on disk and hot-reloads them into the manager without dropping connections (e.g. after `certbot renew`).
- `ACMEChallengeResponder` — answers HTTP-01 ACME challenges inline in the route pipeline.
- `SNIPeekHandler` — peeks the ClientHello's SNI extension before the TLS handshake completes, to route to the right context.

`PerfectAdminConsole`'s TLS Domains card and `POST /api/tls/reload` / `DELETE /api/tls/domain` endpoints (below) operate on exactly this `tlsManager`.

---

## Admin console

`PerfectAdminConsole` is an optional SPM library target that starts a lightweight read/write admin server bound exclusively to `127.0.0.1`. It is never included unless the host application explicitly depends on it.

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/PerfectlySoft/Perfect-NIO.git", branch: "main"),
],
targets: [
    .target(
        name: "MyServer",
        dependencies: [
            .product(name: "PerfectNIO", package: "Perfect-NIO"),
            .product(name: "PerfectAdminConsole", package: "Perfect-NIO"),
        ]
    ),
]
```

### Basic setup

```swift
import PerfectAdminConsole

let logCapture = LogCapture()          // optional — omit if you don't need log tail
let admin = try AdminConsole(
    port: 8990,
    tokenFilePath: "/var/run/myapp-admin.token",
    tlsManager: certManager,           // optional — from PerfectNIO TLS setup
    acmeResponder: acme,               // optional
    logCapture: logCapture,
    delegate: myServer                 // optional — see AdminConsoleDelegate below
)
async let _ = admin.run()             // binds 127.0.0.1:8990, prints token path to stderr
```

The token file is created at startup with `chmod 600`. Read it once to authenticate:

```bash
TOKEN=$(cat /var/run/myapp-admin.token)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8990/api/status | jq
```

### Web dashboard

`GET /` (no auth) serves a self-contained HTML/CSS/JS dashboard — no
external resources. Open
`http://127.0.0.1:<port>` in a browser, paste the token from the file
above into the field, and click **Connect**. By default the token
**persists across restarts** (reused from disk unless `forceNewToken: true`
was passed to `init`) — the gate's why-line and the "Remember on this
machine" checkbox reflect this instance's actual `tokenRotatesOnRestart`
value rather than assuming a restart always invalidates it. Checking
"Remember" keeps the token in `localStorage` (survives closing the
browser); leaving it unchecked keeps the old `sessionStorage` behavior
(cleared on tab close or on a 401).

Once connected, the dashboard polls every endpoint on a 5-second cycle
(visible as "refresh in Ns" under the log cards) and renders a titlebar +
state strip that are always visible, plus five tabs — **Overview**, **Data**,
**Logs**, **Actions**, **Settings** — with a sixth, non-tab-bar **report**
screen reached by drilling into a specific action run.

The **state strip**, under the titlebar, is present on every tab: a
serving/unreachable dot, admin/`serverPort` ports, uptime, error rate,
active connections, and — while a long-running job is in flight — a
progress chip with a name, bar, and completed/total count.

- **Overview** — a two-column summary landing page:
  - **Needs attention** — datasources with `status == .failing` and recent job runs that didn't succeed, each with a **Test now**/**See report**/**See in Logs** action; the card header itself shows a live failing count, and collapses to "Nothing else outstanding" when clean.
  - **Activity** — the in-flight job (if any) plus recent job runs, most recent first; **Expand**/**Collapse** toggles between a compact 3-row view and the full list, and the card can pop into its own remembered-size browser window.
  - **Recent Log** — the last 6 captured `LogCapture` lines; **Open full view** jumps to the Logs tab, or the card can be detached into its own window the same way as Activity.
  - **Traffic** — requests/errors summed over the trailing rate-bucket history, a bar sparkline (error buckets highlighted), and the top 3 busiest routes.
  - **Datasources** — one row per datasource with a status square (ok/failing/not-tested) and a link into the Data tab.
  - **Quick actions** — non-destructive `AdminAction`s only; destructive actions are deliberately excluded here and only run from the Actions tab.
- **Data** — a **Models** card (schema browser: one entry per registered model, its columns, types, and PK/optional badges) above a master-detail **datasource browser**: a left rail listing every datasource (status square, alias, driver/schema, failure count) with a **Test all** button, and a right detail pane for the selected datasource showing its status tag, a **Test connection** button, a failure banner with the last error and any delegate-supplied correlation note, its connection profiles (with a **Switch** button on any non-active profile), and a full attempt-history table.
- **Logs** — a toolbar (free-text search with a live match count, per-subsystem filter chips derived from the `[subsystem]` prefix on captured lines, a **Follow** checkbox, **Copy**/**Download .log**/**Clear buffer** buttons, and a detach-to-window button) above the full scrolling log surface; a footer shows "showing N captured · buffer holds M, oldest dropped".
- **Actions** — the full `AdminAction` catalog grouped by `category` into collapsible groups (each with a count and destructive-count badge). Each row shows the label, a running/destructive tag, a `description` that can be **built fresh on every `availableActions()` call** to reflect live delegate state (e.g. "Running now — 340/1,989 items") and updates every refresh cycle without a reload, the last result if any, and a consequence warning for destructive actions. Destructive actions require a confirm dialog; unavailable ("inert") actions — e.g. reload-TLS with no TLS configured — render disabled with a reason.
- **Settings** — an **Admin access** card (bind address, auth scheme, token file path, and whether the token rotates on restart), one card per delegate `AdditionalStatusSection` (alert-flagged keys highlighted), and **Copy all as text**. TLS Domains and ACME Challenges live here too, but auto-collapse under a "NOT IN USE ON THIS SERVER" strip with a **Show anyway** toggle when TLS/ACME aren't configured on this instance; when TLS is configured, per-domain **Reload**/**Remove** buttons are shown.

The **report** screen isn't on the tab bar — it's reached via "See report" from
Needs Attention or Activity, and shows a structured per-run breakdown for any
`AdminActionReport` a delegate returns (e.g. a crawl grouped by failure
cause): summary stats, status filter chips, per-group result tables, a
"N of M failures share one cause" callout when one group dominates, plus
**Download CSV** and **Re-run** buttons. It isn't restored on reconnect —
navigating away and back starts you back on Overview (or whichever tab was
last active).

If a request fails (network error, or a 500), the titlebar's "updated
HH:MM:SS" text is replaced with "error: ...". A 401 anywhere logs the
session out and returns to the token-entry screen.

### Phase 1 — read-only API

All endpoints require `Authorization: Bearer <token>`.

| Endpoint | Response |
|---|---|
| `GET /` | HTML dashboard (no auth — loads the token-entry form) |
| `GET /api/status` | Server uptime, TLS domain count, ACME pending challenges, delegate sections |
| `GET /api/tls` | `{domains: [String], hasDefault: Bool}` |
| `GET /api/acme` | `{pendingChallenges: Int}` |
| `GET /api/logs?count=N` | `{lines: [String], totalCaptured: Int}` — last N lines from `LogCapture` |
| `GET /api/routes` | `{routes: [String]}` — from delegate |
| `GET /api/actions` | `{actions: [...]}` — available actions (built-in + delegate) |

### Phase 2 — actions and CSRF

Mutating endpoints require `Authorization: Bearer <token>` **and** `X-Admin-CSRF: 1`. When an `Origin` header is present it must equal `http://127.0.0.1:<port>`.

| Endpoint | Body | Effect |
|---|---|---|
| `GET /api/actions` | — | List built-in + delegate actions |
| `POST /api/actions` | `{"action": "clear-logs"}` | Clear the log ring buffer |
| `POST /api/actions` | `{"action": "reload-tls"}` | Ask delegate to reload all TLS certs |
| `DELETE /api/logs` | — | Clear log ring buffer immediately |

### Phase 3 — datasource management

| Endpoint | Body | Response |
|---|---|---|
| `GET /api/datasources` | — | `{datasources: [{name, alias, schema, driver}]}` |
| `POST /api/datasources/test` | `{"name": "mysql-main"}` | `{success, message, latencyMs?}` |

```bash
TOKEN=$(cat /var/run/myapp-admin.token)

# List datasources
curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8990/api/datasources | jq

# Test a specific connection
curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Admin-CSRF: 1" \
  -H "Content-Type: application/json" \
  -d '{"name":"mysql-main"}' \
  http://127.0.0.1:8990/api/datasources/test | jq
```

### Phase 4 — TLS operations and metrics

| Endpoint | Body | Effect |
|---|---|---|
| `GET /api/metrics` | — | `{totalRequests, totalErrors, activeConnections, routeCounts, errorRate}` |
| `POST /api/tls/reload` | `{"hostname": "example.com"}` | Hot-reload cert via `delegate.reloadTLSCertificate(for:)` |
| `DELETE /api/tls/domain` | `{"hostname": "example.com"}` | Remove hostname from live TLS map |

```bash
TOKEN=$(cat /var/run/myapp-admin.token)

# Metrics snapshot
curl -s -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8990/api/metrics | jq

# Reload a specific domain's cert (after certbot renewed it)
curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Admin-CSRF: 1" \
  -H "Content-Type: application/json" \
  -d '{"hostname":"example.com"}' \
  http://127.0.0.1:8990/api/tls/reload | jq

# Remove a domain from the live TLS map
curl -s -X DELETE \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Admin-CSRF: 1" \
  -H "Content-Type: application/json" \
  -d '{"hostname":"old-tenant.example.com"}' \
  http://127.0.0.1:8990/api/tls/domain | jq
```

### Phase 5 — live datasource config switching

The config switcher lets operators change a datasource's active configuration at runtime without restarting the server. It is intentionally framework-agnostic: the `id` field in `DatasourceConfigInfo` is an opaque string your delegate maps to whatever switching mechanism you use.

| Endpoint | Body | Effect |
|---|---|---|
| `GET /api/datasources` | — | Returns each datasource including its `configs[]` array |
| `POST /api/datasources/switch` | `{"name": "mysql-main", "config": "staging"}` | Calls `delegate.switchDatasource(name:to:)` |

```bash
TOKEN=$(cat /var/run/myapp-admin.token)

# Switch mysql-main to the staging config
curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Admin-CSRF: 1" \
  -H "Content-Type: application/json" \
  -d '{"name":"mysql-main","config":"staging"}' \
  http://127.0.0.1:8990/api/datasources/switch | jq
# {"success":true,"message":"Switched to staging (appdb_staging)","latencyMs":12.4}
```

Typical `id` values by framework:
- **Lasso** — path to an alternate `.conf` file (e.g. `/etc/lasso/datasources/staging.conf`)
- **MySQL pool** — a named profile key (e.g. `"staging"`) that triggers a pool reconnect
- **Custom API** — an env profile name (`"dev"`, `"staging"`, `"prod"`) or any stable key

### Phase 6 — model schema browser

A read-only panel listing the ORM models/tables your host application knows about — schema (table/column shape) only, never row data. `PerfectAdminConsole` has no dependency on any ORM (including Perfect-CRUD): your delegate converts its own reflected schema into the framework-agnostic `ModelInfo`/`ModelColumnInfo` types.

| Endpoint | Response |
|---|---|
| `GET /api/models` | `{models: [{name, label, columns: [{name, typeName, isPrimaryKey, isOptional}]}]}` |

```swift
func registeredModels() async -> [ModelInfo] {
    [
        ModelInfo(name: "User", columns: [
            ModelColumnInfo(name: "id", typeName: "Int", isPrimaryKey: true),
            ModelColumnInfo(name: "email", typeName: "String"),
            ModelColumnInfo(name: "nickname", typeName: "String", isOptional: true),
        ]),
    ]
}
```

If your models are Perfect-CRUD `Codable` types, `Decodable.CRUDTableStructure()` (Perfect-CRUD, public as of its `f01b8c0` and later commits) reflects a type's actual table/column shape for you, rather than hand-describing it:

```swift
func registeredModels() async -> [ModelInfo] {
    guard let structure = try? User.CRUDTableStructure() else { return [] }
    return [ModelInfo(name: structure.tableName, columns: structure.columns.map {
        ModelColumnInfo(name: $0.name, typeName: String(describing: $0.type),
                         isPrimaryKey: $0.properties.contains(.primaryKey), isOptional: $0.optional)
    })]
}
```

### AdminConsoleDelegate

Implement this protocol (all methods have default implementations) to expose host-specific data and actions:

```swift
import PerfectAdminConsole

actor MyServer: AdminConsoleDelegate {
    // Phase 1 — status
    var serverPort: Int { 9090 }
    var serverStartTime: Date { startedAt }
    var registeredRoutes: [RouteInfo] { routes.map { RouteInfo(uri: $0.key) } }
    func additionalStatusSections() async -> [AdminStatusSection] {
        [AdminStatusSection(title: "Database", items: [("pool", "\(pool.count)")])]
    }

    // Phase 2 — actions
    func availableActions() async -> [AdminAction] {
        [AdminAction(name: "flush-cache", label: "Flush Cache",
                     description: "Evict all cached responses.", category: "maintenance")]
    }
    func executeAction(_ name: String) async throws -> AdminActionResult {
        switch name {
        case "flush-cache": cache.removeAll(); return .ok("Cache flushed")
        default: return .failed("Unknown action: \(name)")
        }
    }
    func reloadTLSCertificates() async throws {
        try await certManager.setCertificate(for: "example.com", config: loadCert())
    }

    // Phase 3 — datasources
    func registeredDatasources() async -> [DatasourceInfo] {
        [DatasourceInfo(name: "mysql-main", alias: "MainDB", schema: "appdb", driver: "MySQL")]
    }
    func testDatasource(name: String) async throws -> DatasourceTestResult {
        let start = Date()
        do {
            try await pool.ping()
            return .ok(latencyMs: Date().timeIntervalSince(start) * 1000)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // Phase 4 — TLS per-domain reload
    func reloadTLSCertificate(for hostname: String) async throws {
        guard let watcher = certWatchers[hostname] else {
            throw AdminError.unknownHostname(hostname)
        }
        try await watcher.reload()
    }

    // Phase 5 — live config switching (Lasso example)
    func availableConfigs(for datasource: String) async -> [DatasourceConfigInfo] {
        guard datasource == "lasso-main" else { return [] }
        return [
            DatasourceConfigInfo(id: "/etc/lasso/ds/production.conf",
                                 label: "Production", description: "mysql-prod / appdb",
                                 isActive: currentConfig == "production"),
            DatasourceConfigInfo(id: "/etc/lasso/ds/staging.conf",
                                 label: "Staging", description: "mysql-stage / appdb_staging",
                                 isActive: currentConfig == "staging"),
        ]
    }
    func switchDatasource(name: String, to configID: String) async throws -> DatasourceTestResult {
        let start = Date()
        do {
            try await lassoPool.reloadConfig(from: configID)
            currentConfig = configID.contains("staging") ? "staging" : "production"
            let ms = Date().timeIntervalSince(start) * 1000
            return .ok(latencyMs: ms, message: "Switched to \(currentConfig)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // Phase 6 — model schema browser
    func registeredModels() async -> [ModelInfo] {
        guard let structure = try? User.CRUDTableStructure() else { return [] }
        return [ModelInfo(name: structure.tableName, columns: structure.columns.map {
            ModelColumnInfo(name: $0.name, typeName: String(describing: $0.type),
                             isPrimaryKey: $0.properties.contains(.primaryKey), isOptional: $0.optional)
        })]
    }
}
```

### AdminMetrics — request counters

Pass an `AdminMetrics` instance to `AdminConsole.init` and feed it from your route handlers:

```swift
let metrics = AdminMetrics()
let admin = try AdminConsole(port: 8990, tokenFilePath: tokenPath, metrics: metrics)

// In each route handler:
await metrics.recordRequest(route: "GET:///api/posts")

// On error paths:
await metrics.recordError()

// Around TCP connections (optional):
await metrics.beginConnection()
defer { Task { await metrics.endConnection() } }
```

`GET /api/metrics` returns a snapshot with `totalRequests`, `totalErrors`, `activeConnections`, `routeCounts` (top routes by name), and a computed `errorRate`.

### LogCapture — feeding log lines

`LogCapture` is a Swift actor with a configurable ring buffer (default 500 lines). Integrate it with your logging stack:

```swift
let capture = LogCapture(capacity: 500)

// Manual:
await capture.capture("2026-07-14 10:00:00 [INFO] Server started")

// With swift-log via MultiplexLogHandler + a custom LogHandler that calls capture.capture(_:)
```

---

## PerfectNIOCRUD

`PerfectNIOCRUD` is a thin bridge target (`Sources/PerfectNIOCRUD/RouteCRUD.swift`) that adds two route operators, `.db(_:_:)` and `.table(_:_:_:)`, exposing a Perfect-CRUD `Database`/`Table` into the route pipeline so handlers can query/mutate through Perfect-CRUD without hand-wiring a connection per request. It depends on the local `../Perfect-CRUD` package (see [Package.swift](#packageswift)), and is exercised by the `PerfectNIOMySQLTests` test target against Perfect-MySQL.

```swift
dependencies: [
    .product(name: "PerfectNIO", package: "Perfect-NIO"),
    .product(name: "PerfectNIOCRUD", package: "Perfect-NIO"),
]
```

```swift
import PerfectNIOCRUD

struct User: Codable, Sendable { let id: Int; let name: String }

// .db — hand the raw Database through to your own closure
let routes = root().users.db(makeDatabase()) { _, db in
    try db.table(User.self).select()
}.json()

// .table — go straight to a Table<User, Database<C>>
let routes2 = root().users.table(makeDatabase(), User.self) { _, table in
    try table.select()
}.json()
```

### Pooled routes

`.db(pool:_:)`/`.table(pool:_:_:)` are pool-based counterparts to the `@autoclosure`-based overloads above, distinguished by the `pool:` label so existing call sites keep resolving unchanged. Build one `DatabaseConnectionPool` at server startup (see Perfect-CRUD's own README for `DatabaseConnectionPool` itself) and switch call sites to it instead of constructing a fresh `Database` per request:

```swift
let pool = try DatabaseConnectionPool(
    configuration: .init(minConnections: 1, maxConnections: 10),
    makeConnection: { try MySQLDatabaseConfiguration(database: "mydb", host: "localhost") }
)

let routes = root().users.db(pool: pool) { _, db in
    try db.table(User.self).select()
}.json()

let routes2 = root().users.table(pool: pool, User.self) { _, table in
    try table.select()
}.json()
```

Both internally acquire a connection, run your closure, and release it back to the pool afterward — even on throw. They use the pool's manual `acquire()`/`release(_:)` pairing rather than `withConnection(_:)`, since `OutType` at this point in a route chain is commonly `HTTPRequest`, a non-`Sendable` protocol existential that can't cross `withConnection`'s `Sendable`-body boundary.

---

## Reference

### Server

```swift
public struct Server: Sendable {
    public var routes: Routes<HTTPRequest, HTTPOutput>
    public var host: String              // default "0.0.0.0"
    public var port: Int
    public var tls: TLSConfiguration?
    public var tlsManager: TLSContextManager?  // live-updatable per-domain (SNI) TLS; takes
                                                // precedence over `tls` when both are set —
                                                // see "Advanced: multi-tenant / hot-reloadable TLS"
    public var idleTimeout: TimeAmount?  // default .seconds(60) — nil disables
    public var reusePortCount: Int       // default 1; >1 opens multiple sockets in *this* process via SO_REUSEPORT
    public var alwaysReusePort: Bool     // default false; sets SO_REUSEPORT on a single socket so a
                                          // *different* process can bind the same port concurrently —
                                          // the primitive a graceful hand-off restart needs: start a new
                                          // process, confirm it's bound and healthy, only then stop the old
                                          // one — with zero window where the port refuses connections.
    public var maxRequestBodySize: Int?  // default 10 MiB (Server.defaultMaxRequestBodySize); nil = no limit.
                                          // Larger bodies, uploads included, get 413 — see "Request body size limit"

    public init(routes:, host:, port:, tls:, idleTimeout:, reusePortCount:, alwaysReusePort:, maxRequestBodySize:)

    /// Serve until the surrounding Task is cancelled.
    public func run() async throws

    /// Bind, run body, then shut down (structured-concurrency lifecycle).
    @discardableResult
    public func withServer<R>(_ body: (_ boundPort: Int) async throws -> R) async throws -> R
}
```

`maxRequestBodySize` caps how large a request body the server will read into memory. **The 10 MiB default applies to file uploads too**; raise it if your app accepts bigger ones. See [Request body size limit](#request-body-size-limit).

Errors thrown from a route: an `ErrorOutput` (or `TerminationType.error`) is sent as-is, with its status and text. Any other error becomes **500 Internal server error.** with a generic body; the error itself is logged (label `perfect.nio.server`), never sent to the client.

`idleTimeout` closes connections that have no inbound reads for the specified duration. It is a defense against idle keep-alive connections and basic slowloris. Note: it measures *reads*, so streaming endpoints that take longer than the timeout to produce their first byte should use a larger value or `nil`.

### root()

```swift
public func root() -> Routes<HTTPRequest, HTTPRequest>
public func root<T>(_ call: @Sendable @escaping (any HTTPRequest) async throws -> T) -> Routes<HTTPRequest, T>
public func root<T>(_ call: @Sendable @escaping () async throws -> T) -> Routes<HTTPRequest, T>
public func root<T>(path: String, _ type: T.Type) -> Routes<T, T>
```

### Routes\<InType, OutType\>

```swift
@dynamicMemberLookup
public struct Routes<InType, OutType>: Sendable {
    // Instantiated only via root() or by chaining operations.
}
```

### HTTPRequest

```swift
public protocol HTTPRequest: AnyObject {
    var method: HTTPMethod { get }
    var uri: String { get }
    var headers: HTTPHeaders { get }
    var uriVariables: [String: String] { get set }
    var path: String { get }
    var searchArgs: QueryDecoder? { get }
    var contentType: String? { get }
    var contentLength: Int { get }
    var contentRead: Int { get }
    var contentConsumed: Int { get }
    var localAddress: SocketAddress? { get }
    var remoteAddress: SocketAddress? { get }
    var cookies: [String: String] { get }          // extension — parsed from Cookie header
    func readSomeContent() async throws -> [ByteBuffer]
    func readContent() async throws -> HTTPRequestContentType
}
```

### HTTPOutput

```swift
open class HTTPOutput: @unchecked Sendable {
    public init()
    open func head(request: HTTPRequestInfo) -> HTTPHead?
    open func nextChunk(allocator: ByteBufferAllocator) async throws -> ByteBuffer?
    open func closed()
}
```

### HTTPRequestContentType

```swift
public enum HTTPRequestContentType {
    case none
    case multiPartForm(MimeReader)
    case urlForm(QueryDecoder)
    case other([UInt8])
}
```

### QueryDecoder

```swift
public struct QueryDecoder {
    public init(_ c: [UInt8])
    public subscript(_ key: String) -> [String]   // ["value"] or [] if absent
    public func map<T>(_ call: ((String, String)) throws -> T) rethrows -> [T]
    public func get(_ key: String) -> [ArraySlice<UInt8>]
}
```

Usage:

```swift
// From a URL query string
if let args = request.searchArgs {
    let ids = args["id"]   // [String]
}

// From a URL-encoded POST body
root().POST.readBody { _, content in
    guard case .urlForm(let q) = content else { return "bad" }
    return q["name"].first ?? ""
}.text()
```

### RouteError

```swift
public enum RouteError: Error {
    case duplicatedRoutes([String])
}
```

### HTTP methods

```swift
public extension Routes {
    var GET: Routes { method(.GET) }
    var POST: Routes { method(.POST) }
    var PUT: Routes { method(.PUT) }
    var DELETE: Routes { method(.DELETE) }
    var OPTIONS: Routes { method(.OPTIONS) }
    func method(_ method: HTTPMethod, _ rest: HTTPMethod...) -> Routes
}
```

### WebSocket

```swift
public enum WebSocketMessage: Sendable {
    case close
    case ping, pong
    case text(String), binary([UInt8])
}

public enum WebSocketOption: Sendable {
    case manualClose
    case manualPing
}

public protocol WebSocket: Sendable {
    var options: [WebSocketOption] { get }
    func readMessage() async throws -> WebSocketMessage
    func writeMessage(_ message: WebSocketMessage) async throws
}

public typealias WebSocketHandler = @Sendable (WebSocket) async -> Void

public extension Routes {
    func webSocket(protocol: String,
                   options: [WebSocketOption] = [],
                   _ callback: @Sendable @escaping (OutType) async throws -> WebSocketHandler)
        -> Routes<InType, HTTPOutput>
}
```

### routes.describe

Enumerate all registered route URIs (available on `Routes<HTTPRequest, HTTPOutput>`):

```swift
for desc in routes.describe {
    print(desc.uri)   // e.g. "/v1/users", "GET:///v1/users"
}
```

---

## Linux support

The PerfectNIO library is expected to compile and run on Linux — SwiftNIO is fully cross-platform, and the `CZlib` system library target includes an `apt` provider (`zlib1g-dev`).

The `platforms: [.macOS(.v26)]` entry in `Package.swift` specifies the minimum **macOS** deployment target only — `.v26` is a very new (leading-edge) macOS requirement, not a typo; if you're targeting an older macOS you'll need to fork/pin an earlier commit. Linux support is always implicit in SwiftPM and is not restricted by that entry, and no explicit Linux platform entry is declared.

> **Research needed:** Linux support has not been CI-verified as part of this resurrection. `URLSessionWebSocketTask` availability in `swift-corelibs-foundation` on Linux needs confirmation before the test suite can be declared Linux-clean. The `LinuxMain.swift` file was intentionally removed — Swift 5.4+ auto-discovers tests on Linux via `swift test` without it. Separately, `swift build`/`swift test` for this repo currently requires the sibling `../Perfect-CRUD` and `../Perfect-MySQL` checkouts to be present regardless of platform (see [Package.swift](#packageswift)).

To build and test on Linux:

```bash
# Install system dependencies (Ubuntu/Debian)
apt-get install libssl-dev zlib1g-dev

swift build
swift test
```

### macOS

`swift build` / `swift run` / `swift test` work the same way locally on macOS — see [Quick start](#quick-start). No extra system packages are required; `CZlib`/libz ships with the OS.

### Live MySQL integration tests

`Tests/PerfectNIOMySQLTests/MySQLIntegrationTests.swift` exercises `PerfectNIOCRUD` against a real MySQL instance and is skipped by default. Set `MYSQL_TESTS=1` in the environment to run it:

```bash
MYSQL_TESTS=1 swift test
```
