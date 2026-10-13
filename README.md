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

The pre-Swift-6 version of this package is preserved on the [`legacy`](../../tree/legacy) branch. It was never tagged; see [Migrating from the legacy branch](#migrating-from-the-legacy-branch).

> **Version 0.x: the API may change between minor versions.** PerfectNIO starts at 0.1.0 and stays on 0.x until its API settles. Under semantic versioning a 0.x minor release (0.1 → 0.2) may contain breaking changes. `from: "0.1.0"` (as below) accepts any 0.x release; use `.upToNextMinor(from: "0.1.0")` to take only 0.1.x fixes. Release notes list every breaking change.

## Requirements

- Swift 6.2 or later (swift-tools-version 6.2). CI builds with Swift 6.2 and 6.4 on Linux and Xcode 26.0.1 and 26.6 on macOS.
- macOS 12 or later, or Linux (CI: Ubuntu 24.04). No iOS, tvOS or watchOS support.
- Linux: `zlib1g-dev` (and `pkg-config`) for the `CZlib` system library. macOS needs nothing extra.
- `PerfectNIOCRUD` depends on Perfect-CRUD 3 (`from: "3.0.1"`). Perfect-MySQL 4 is used only by this package's own MySQL tests; building the library products doesn't need a MySQL client library.

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
- [Security notes](#security-notes)
- [Upgrading from `main` before 0.1.0](#upgrading-from-main-before-010)
- [Migrating from the legacy branch](#migrating-from-the-legacy-branch)

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
    .package(url: "https://github.com/PerfectlySoft/Perfect-NIO.git", from: "0.1.0"),
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

This package depends on its Perfect siblings by released version (Perfect-CRUD `from: "3.0.1"`, Perfect-MySQL `from: "4.0.0"`), so a version-pinned consumer resolves cleanly. Cloning this repo on its own and running `swift build`/`swift test` works standalone; for cross-repo work on unreleased sibling changes, use a SwiftPM mirror (`swift package config set-mirror`) rather than editing `Package.swift`.

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

Builder form: the closure's argument `$0` stands in for the parent route, and each line is one child route:

```swift
let routes = try root().v1.dir {
    $0.foo1 { "OK1" }
    $0.foo2 { "OK2" }
    $0.foo3 { "OK3" }
}.text()
// serves /v1/foo1, /v1/foo2, /v1/foo3
```

Because routes are strongly typed, all routes passed to `dir` must share the same `OutType`. Mismatches are caught at compile time.

---

## Route operations

All route closures are `async throws`. Return a value to pass it to the next operation, or throw to abort the request.

### map

Transform the current output value into something new.

```swift
// The whole value: Int → String
let label = root().a { 1 }.map { (n: Int) in "Item \(n)" }.text()

// On a collection, map with an element closure maps each element: [Int] → [String]
let labels = root().b { [1, 2, 3] }.map { (n: Int) in "Item \(n)" }.json()

// …and with a closure over the whole collection, the collection: [Int] → Int
let total = root().c { [1, 2, 3] }.map { (all: [Int]) in all.reduce(0, +) }.text()
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

> The segment is raw request text, not percent-decoded. It is never `..`: a request with a `..` path segment, raw or encoded, is refused with 400 before routing (see [Security notes](#security-notes)). Still validate it before using it as a file name.

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

> The remainder is raw request text, not percent-decoded. It never contains a `..` segment: `/files/../secret.txt`, `/files/%2e%2e/secret.txt` and the like are refused with 400 before routing (see [Security notes](#security-notes)). It can still name hidden files or contain encoded characters, so validate it before joining it onto a directory for `FileOutput`.

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
struct CreateUser: Codable { let name: String; let email: String }

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
// Each child is already an HTTPOutput route (json()/text()), so dir needs no text() after it.
let routes = try root().dir {
    $0.GET.users    { listUsers()   }.json()
    $0.POST.users   { createUser()  }.json()
    $0.DELETE.users { deleteUsers() }.text()
}
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

Wraps any `HTTPOutput` with gzip/deflate compression, chosen from the request's `Accept-Encoding` (a coding refused with `q=0` is never used). Content shorter than ~14 KB or with an image/video/audio content type is passed through uncompressed. Partial (206) responses are never compressed. Every response carries `Vary: Accept-Encoding`, compressed or not.

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

A directory path serves its `index.html` (404 if there is none). Responses carry a quoted `ETag` (covering the file's path, size, inode and modification time to the nanosecond) and `Last-Modified`; `If-None-Match` (lists, weak tags, `*`) gets 304. A `Range: bytes=…` request is answered with 206 and the first satisfiable range, unless `If-Range` names a validator that no longer matches, in which case the whole file is sent; an unsatisfiable or malformed range gets the whole file. The file is read in chunks of up to 64 KiB. `localPath` is used as given: see [Security notes](#security-notes) before building it from request input.

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

A WebSocket handshake to a path that does not have a `webSocket()` route is served as ordinary HTTP (returning the route's natural status, typically 404) — per RFC 6455 §4.2.2. Only `webSocket()` routes run during the handshake; any other route runs once, as plain HTTP. A `webSocket()` route whose pipeline refuses the handshake (a `statusCheck` returning 403, a thrown `ErrorOutput`) also runs once: its result is the response. A handshake that isn't upgraded is answered with `Connection: close` and the connection is closed, because the HTTP parser can't continue on a connection that asked to upgrade. A route that returns a hand-built `WebSocketUpgradeHTTPOutput` (its initializer is deprecated) does not upgrade and answers 426 Upgrade Required.

The `protocol` argument is the subprotocol the endpoint speaks. When the client offers it in `Sec-WebSocket-Protocol`, the 101 response selects it (browsers fail a connection whose 101 selects none of the subprotocols they offered). A client that offers none, or only others, is still upgraded, without the header.

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

let chain = try NIOSSLCertificate.fromPEMFile("/etc/ssl/cert.pem")   // leaf first, then intermediates
let key   = try NIOSSLPrivateKey(file: "/etc/ssl/key.pem", format: .pem)
let tls   = TLSConfiguration.makeServerConfiguration(
    certificateChain: chain.map { .certificate($0) },
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
    .package(url: "https://github.com/PerfectlySoft/Perfect-NIO.git", from: "0.1.0"),
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

// pool, cache, certManager, certWatchers, lassoPool, loadCert() and AdminError stand for
// your app's own state and helpers.
actor MyServer: AdminConsoleDelegate {
    private var currentConfig = "production"

    // Phase 1 — status. The synchronous requirements must be nonisolated on an actor.
    nonisolated var serverPort: Int { 9090 }
    nonisolated let serverStartTime = Date()
    nonisolated var registeredRoutes: [RouteInfo] { appRoutes.describe.map { RouteInfo(uri: $0.uri) } }
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

`PerfectNIOCRUD` is a thin bridge target (`Sources/PerfectNIOCRUD/RouteCRUD.swift`) that adds two route operators, `.db(_:_:)` and `.table(_:_:_:)`, exposing a Perfect-CRUD `Database`/`Table` into the route pipeline so handlers can query/mutate through Perfect-CRUD without hand-wiring a connection per request. It depends on Perfect-CRUD 3 (see [Requirements](#requirements)), and is exercised by the `PerfectNIOMySQLTests` test target against Perfect-MySQL.

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
let routes = root().users.db(try makeDatabase()) { _, db in
    try db.table(User.self).select().map { $0 }
}.json()

// .table — go straight to a Table<User, Database<C>>
let routes2 = root().users.table(try makeDatabase(), User.self) { _, table in
    try table.select().map { $0 }
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
    try db.table(User.self).select().map { $0 }
}.json()

let routes2 = root().users.table(pool: pool, User.self) { _, table in
    try table.select().map { $0 }
}.json()
```

Both internally acquire a connection, run your closure, and release it back to the pool afterward — even on throw. They use the pool's manual `acquire()`/`release(_:)` pairing rather than `withConnection(_:)`, since `OutType` at this point in a route chain is any type, not necessarily `Sendable`, and `withConnection`'s body is `@Sendable`.

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
    /// Runs in the caller's isolation (nonisolated(nonsending)), so it can be called from the main actor.
    nonisolated(nonsending)
    public func withServer<R>(_ body: (_ boundPort: Int) async throws -> R) async throws -> R
}
```

`maxRequestBodySize` caps how large a request body the server will read into memory. **The 10 MiB default applies to file uploads too**; raise it if your app accepts bigger ones. See [Request body size limit](#request-body-size-limit).

Errors thrown from a route: an `ErrorOutput` (or `TerminationType.error`) is sent as-is, with its status and text. A failure to decode the request becomes **400 Bad Request** with a generic body. Any other error becomes **500 Internal server error.** with a generic body; the error itself is logged (label `perfect.nio.server`), never sent to the client.

`idleTimeout` closes idle connections. It runs from the moment a connection is accepted. While no response is pending (before the first request, while a request arrives, between keep-alive requests), a connection is idle when nothing has been read for the timeout, which covers a client that sends nothing, a stalled TLS handshake and a request head that never finishes. While a response is pending, a connection is idle only when the client has stopped reading: the response is backed up and nothing more of it has been written or has left the kernel's send buffer for the timeout. Slow but steady downloads, long polls and event streams are not cut off, as long as the client's own receive buffer drains within the timeout: TCP reopens a slow reader's window only after it has read a good part of its buffer, so a client with a 1 MB buffer reading 25 KB/s is silent for some 40 s, which the server can't tell from a stalled client (nginx's `send_timeout` works the same way). Keep the timeout generous if you serve slow clients; the default is 60 s. If the client closes its side while a response is pending, the connection is closed once nothing has been written for the timeout, so a client that disconnects from a slow route doesn't pin the socket; a route that never returns keeps a still-connected client's connection open. The timeout is removed when a connection upgrades to WebSocket. It resets on every byte, so a client trickling a request slowly is not bounded by it.

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
public protocol HTTPRequest: AnyObject, Sendable {
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

PerfectNIO builds and runs on Linux. CI builds every target with warnings as errors and runs the whole test suite on Ubuntu 24.04 with Swift 6.2 and 6.4, debug and release, the live MySQL tests included.

The `platforms: [.macOS(.v12)]` entry in `Package.swift` sets the minimum **macOS** deployment target only; Linux needs no platform entry.

To build and test on Linux:

```bash
# System dependencies (Ubuntu/Debian). libmysqlclient-dev is needed only for this
# package's own PerfectNIOMySQLTests target.
apt-get install pkg-config zlib1g-dev libmysqlclient-dev

swift build
swift test
```

### macOS

`swift build` / `swift run` / `swift test` work the same way locally on macOS — see [Quick start](#quick-start). The library needs no extra system packages (zlib ships with the OS). Building this package's tests needs a MySQL client library for Perfect-MySQL: `brew install mysql-client pkgconf` and `export PKG_CONFIG_PATH="$(brew --prefix mysql-client)/lib/pkgconfig"`.

### Live MySQL integration tests

`Tests/PerfectNIOMySQLTests` exercises `PerfectNIOCRUD` against a real MySQL server. The live tests are skipped unless `MYSQL_TESTS=1` and `MYSQL_TEST_PORT` name a test server; port 3306 is never assumed, and host `localhost` is refused because libmysql would use the Unix socket and ignore the port (see `MySQLTestEnvironment.swift` for every variable). The tests drop and recreate tables, so point them at a throwaway server:

```bash
container run -d --rm --name nio-mysql-test --publish 127.0.0.1:3307:3306 \
    --env MYSQL_ALLOW_EMPTY_PASSWORD=yes docker.io/library/mysql:8.4
MYSQL_TESTS=1 MYSQL_TEST_PORT=3307 swift test
```

With `MYSQL_REQUIRE_LIVE=1` (as in CI), an unconfigured or unreachable server fails the run instead of skipping.

---

## Security notes

- **Request bodies** are capped at 10 MiB by default (`maxRequestBodySize`); see [Request body size limit](#request-body-size-limit). The limit is per request, so total memory also scales with the number of connections.
- **Errors**: only an `ErrorOutput`'s text reaches the client. A `DecodingError` from decoding the request (the `decode` modifier, or an `HTTPRequest.decode(_:content:)` call whose error the handler lets escape; test for these with `error.isRequestDecodingFailure`; `error.originalUnderlyingError` gives the decoder's own underlying error) is answered 400 with a generic message. Any other error, including a `DecodingError` from the handler decoding its own data, is logged at error level and answered with a generic 500.
- **`..` segments are rejected.** A request whose path (everything before the first `?`) has a `..` segment, as sent or after percent-decoding repeated until nothing changes (`%2e%2e`, `.%2e`, nested `%25` encodings), with `/`, `%2f`, `\\` or `%5c` as separators, or a `..` segment followed by `;` or a NUL (`..;`, `..%00`), gets 400 before any route runs, WebSocket handshakes included. So does any request target containing `#` (clients never send a fragment). The strings `wild` and `trailing` hand you therefore never contain a `..` segment. Other dots (`a..b`, `.hidden`) are allowed. Paths are otherwise used as sent: not percent-decoded and not otherwise normalized, so still validate `wild`/`trailing` values before using them as file names (for example for `FileOutput(localPath:)`). PerfectNIO has no built-in static file route.
- **Response headers**: a header value containing CR or LF is refused by NIO's header validator; the connection is closed without a response rather than the header being split.
- **HTTP/1 framing**: requests with ambiguous framing (Content-Length with Transfer-Encoding, conflicting Content-Lengths, unknown transfer codings, obs-fold, bare LF) or two `Host` headers get 400 and the connection is closed. Responses are framed by the server: a body of unknown length is chunked on HTTP/1.1 and ends the connection on HTTP/1.0; HEAD, 204 and 304 responses carry no body. A route that returns an informational (1xx) status as its final response gets 500 and the connection is closed. An output's own `Content-Length` is checked: duplicates of one value are collapsed, conflicting or invalid values dropped, and a body that doesn't match it closes the connection after the response.
- **Upgrades**: WebSocket handshakes that aren't upgraded (wrong path, a refusing route, a missing key or a version other than 13) are answered as HTTP, then the connection is closed. A `webSocket` route answers a plain or malformed request with 426 and `Sec-WebSocket-Version: 13`. An offer to upgrade to anything else (`h2c`, …) is ignored and the request served as HTTP/1.1, then the connection is closed. There is no HTTP/2.

---

## Upgrading from `main` before 0.1.0

Two changes made for Swift 6.4 can stop code that built against `main` from compiling:

- **`SendableMetatype` on generic helpers.** `decode(_:)`, `json()`, `text()` and the element-wise `map` capture their type in `@Sendable` closures, so it must be `SendableMetatype`. Every concrete, non-isolated type already is, so ordinary call sites are unaffected, but a generic helper must add the constraint, and a type isolated to a global actor (a `@MainActor` class) can't be used:

  ```swift
  func decodeEndpoint<T: Decodable & SendableMetatype>(_: T.Type) -> Routes<HTTPRequest, T> {
      root().decode(T.self)
  }
  func jsonEndpoint<T: Encodable & SendableMetatype>(
      _ load: @Sendable @escaping () async throws -> T
  ) -> Routes<HTTPRequest, HTTPOutput> {
      root(load).json()
  }
  ```

  The same goes for `CustomStringConvertible & SendableMetatype` with `text()`, and `Collection & SendableMetatype` for `map` over elements.
- **`HTTPMethod` is no longer `Hashable`** through this package (it declared a public retroactive conformance of NIO's type). `Set<HTTPMethod>`, dictionaries keyed by `HTTPMethod`, and generics that require `Hashable` of it no longer compile. Key by `method.name`, or declare the conformance in your own module: `extension HTTPMethod: @retroactive Hashable { public func hash(into hasher: inout Hasher) { hasher.combine(name) } }`.

## Migrating from the legacy branch

The [`legacy`](../../tree/legacy) branch is the Swift 5 "Perfect 4 NIO" package (swift-tools-version 5.1, never tagged). 0.1.0 is a rewrite on Swift 6 concurrency that keeps the route-building style but is not source compatible. The main differences, not an exhaustive list:

- **Serving.** `routes.bind(port:).listen().wait()` is gone. Use `try await Server(routes: routes, port: 8080).run()` for a long-running server, or `withServer { port in … }` for a scoped one (tests). TLS, idle timeout, `SO_REUSEPORT` and the body size limit are `Server` properties.
- **Handlers are async and `@Sendable`.** Every route closure (`map`, `path`, `readBody`, `decode`, `statusCheck`, …) is `@Sendable` and may be `async`; captured state must be `Sendable`.
- **Custom outputs** subclass `HTTPOutput` and produce the body with `nextChunk(allocator:) async throws -> ByteBuffer?`, returning nil at the end.
- **WebSockets** are declared with `webSocket(protocol:options:_:)`, whose callback returns an async `WebSocketHandler` that reads and writes with `readMessage()`/`writeMessage(_:)`.
- **Dependencies.** PerfectLib, Perfect-Mustache, Perfect-MIME, Perfect-CZlib-src and Perfect-CURL are no longer used; there is no Mustache output. Logging uses apple/swift-log. Database routes moved to the separate `PerfectNIOCRUD` product, on Perfect-CRUD 3.
- **Platforms.** macOS 12+ (was 10.15) and Linux; Swift 6.2+.
