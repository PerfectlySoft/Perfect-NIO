<p align="center">
    <a href="https://developer.apple.com/swift/" target="_blank">
        <img src="https://img.shields.io/badge/Swift-4.2-orange.svg?style=flat" alt="Swift 4.2">
    </a>
    <a href="https://developer.apple.com/swift/" target="_blank">
        <img src="https://img.shields.io/badge/Platforms-macOS%20%7C%20Linux%20-lightgray.svg?style=flat" alt="Platforms macOS | Linux">
    </a>
    <a href="http://perfect.org/licensing.html" target="_blank">
        <img src="https://img.shields.io/badge/License-Apache-lightgrey.svg?style=flat" alt="License Apache">
    </a>
</p>

# Perfect 4 NIO

This project is a work in progress and should be considered **alpha quality** until this sentence is removed.

<a href="#usage"> Package.swift Usage</a>

### Intro

Perfect 4 NIO is a Swift based API server. It provides the ability to serve HTTP/S endpoints by creating one or more URI based routes and binding them to a port. Each route is built as a series of operations, each accepting and returning some sort of value. A route finally terminates and outputs to the client by returning an `HTTPOutput` object.

### Simple Routing

```swift
root { "Hello, world!" }.text()
```

This simple route would be applied to the root `/` of the server. It accepts nothing, Void, but returns a String. That string would be returned to the client with the text/plain content type.

However, that bit of code produces an unused value. To serve a route you must first bind it to a port, ask it to listen for requests, then (optionally) wait until the process is terminated.

```swift
try root { "Hello, world!" }.text().bind(port: 8080).listen().wait()
```

This will create a route and bind it to port 8080. It will then serve HTTP clients on that port until the process exits.

Each of these steps can be broken up as nessesary.

```swift
let route = root { "Hello, world!" }
let textOutput = route.text()
let boundServer = try textOutput.bind(port: 8080)
let listeningServer = try boundServer.listen()
try listeningServer.wait()	
```

### Root

The `root` function is used to create a route beginning with `/`. The root is, by default, a function accepting an <a href="#httprequest">`HTTPRequest`</a> and returning an `HTTPRequest`; an identity function. There are a few other variants of the `root` func. These are listed here: <a href="#root">root</a>.

### Paths

A route can have additional path components added to it by using Swift 4.2 dynamic member lookup.

```swift
let route = root().hello { "Hello, world!" }
```

Now the route serves itself on `/hello`.

```swift
let route = root().hello.world { "Hello, world!" }
```

Now the route serves itself on `/hello/world`.

Equivalently, you may use the `path` func to achieve the same thing.

```swift
let route = root().path("hello").path("world") { "Hello, world!" }
```
or

```swift
let route = root().path("hello/world") { "Hello, world!" }
```

This may be required in cases where your desired path component string conflicts with built-in funcs (*\*list these somewhere simply*) or contains characters which are invalid for Swift identifiers.

### Combining Routes

Most servers will want to service more than one URI. Routes can be combined in various ways. Combined routes behave as though they were one route. Combined routes can be bound and can listen for connections the same as an individual route can.

Routes are combined using the `dir` func. Dir will append the given routes to the receiver and return a new route object containing all of the routes.

```swift
let helloRoute = root().hello { "Hello, world!" }
let byeRoute = root().bye { "Bye, world!" }

let combinedRoutes = try root().v1.dir(helloRoute, byeRoute).text()

try combinedRoutes.bind(port: 8080).listen().wait()
```

The above creates two routes which can be accessed at the URIs `/v1/hello` and `/v1/bye`. These two routes are combined and then the `text()` func is applied to them so that they return a text/plain content type.

Dir will ensure that you are not adding any duplicate routes and will throw an Error if you are.



### Route Operations

A variety of operations can be applied to a route. These operations include:

* map - transform an output in some way producing a new output or a sequence of output values
* ext - apply a file extension to the routes
* wild - apply a wildcard path segment
* trailing - apple a trailing wildcard path segment
* request - access the HTTPRequest object
* readBody - ready the client body data
* statusCheck - assert some condition by returning either 'OK' (200..<300 status code) or failing
* decode - decode the client body as a Decodable type
* unwrap - unwrap an Optional value, or fail the request if the value is nil
* async - execute a task asynchronously, out of the NIO event loop
* stream - stream data to the client
* text - use a `CustomStringConvertible` as the output with a text/plain content type
* json - use an `Encodable` as the output with the appllication/json content type

### HTTP Method

<a name="root"></a>
### root Ref
```swift
/// Create a root route accepting/returning the HTTPRequest.
public func root() -> Routes<HTTPRequest, HTTPRequest>
/// Create a root route accepting the HTTPRequest and returning some new value.
public func root<NewOut>(_ call: @escaping (HTTPRequest) throws -> NewOut) -> Routes<HTTPRequest, NewOut>
/// Create a root route returning some new value.
public func root<NewOut>(_ call: @escaping () throws -> NewOut) -> Routes<HTTPRequest, NewOut>
/// Create a root route accepting and returning some new value.
public func root<NewOut>(path: String = "/", _ type: NewOut.Type) -> Routes<NewOut, NewOut>
```

<a name="httprequest"></a>
### HTTPRequest Ref
```swift
public protocol HTTPRequest {
	var method: HTTPMethod { get }
	var uri: String { get }
	var headers: HTTPHeaders { get }
	var uriVariables: [String:String] { get set }
	var path: String { get }
	var searchArgs: QueryDecoder? { get }
	var contentType: String? { get }
	var contentLength: Int { get }
	var contentRead: Int { get }
	var contentConsumed: Int { get }
	func readSomeContent() -> EventLoopFuture<[ByteBuffer]>
	func readContent() -> EventLoopFuture<HTTPRequestContentType>
}
```

<a name="querydecoder"></a>
### QueryDecoder Ref

```swift
public struct QueryDecoder {
	public init(_ c: [UInt8])
	public subscript(_ key: String) -> [String]
	public func map<T>(_ call: ((String,String)) throws -> T) rethrows -> [T]
	public func mapBytes<T>(_ call: ((String,ArraySlice<UInt8>)) throws -> T) rethrows -> [T]
	public func get(_ key: String) -> [ArraySlice<UInt8>]
}
```

<a name="dir"></a>
### dir Ref
```swift
/// These extensions append new route sets to an existing set.
public extension Routes {
	/// Append new routes to the set given a new output type and a function which receives a route object and returns an array of new routes.
	/// This permits a sort of shorthand for adding new routes.
	/// At times, Swift's type inference can fail to discern what the programmer intends when calling functions like this.
	/// Calling the second version of this method, the one accepting a `type: NewOut.Type` as the first parameter,
	/// can often clarify your intentions to the compiler. If you experience a compilation error with this function, try the other.
	func dir<NewOut>(_ call: (Routes<OutType, OutType>) throws -> [Routes<OutType, NewOut>]) throws -> Routes<InType, NewOut>
	/// Append new routes to the set given a new output type and a function which receives a route object and returns an array of new routes.
	/// This permits a sort of shorthand for adding new routes.
	/// The first `type` argument to this function serves to help type inference.
	func dir<NewOut>(type: NewOut.Type, _ call: (Routes<OutType, OutType>) -> [Routes<OutType, NewOut>]) throws -> Routes<InType, NewOut>
	/// Append new routes to this set given an array.
	func dir<NewOut>(_ registries: [Routes<OutType, NewOut>]) throws -> Routes<InType, NewOut>
	/// Append a new route set to this set.
	func dir<NewOut>(_ registry: Routes<OutType, NewOut>, _ registries: Routes<OutType, NewOut>...) throws -> Routes<InType, NewOut>
}
```

<a name="usage"></a>
### Package.swift Usage
In your Package.swift:
```swift
.package(url: "https://github.com/PerfectlySoft/Perfect-NIO.git", .branch("master"))
```

Your code may need to `import NIO`, `import NIOHTTP1`, or `import NIOOpenSSL`
