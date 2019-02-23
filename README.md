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

<a href="#usage">Package.swift Usage</a>

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

The type of object returned by `root` is a `Routes` object. Routes is defined simply as:

```swift
public struct Routes<InType, OutType> {}
```

A `Routes` object encompasses one or more paths with their associated functions. For a particular route, all enclosed functions accept `InType` and return `OutType`.

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

This may be required in cases where your desired path component string conflicts with a built-in func (*\*list these somewhere simply*) or contains characters which are invalid for Swift identifiers. You may also simply prefer it stylistically, or may be using variable path names. These are all good reasons why one might want to use the `path` func over dynamic member lookup.

All further examples in this document use dynamic member lookup.

Note that paths which begin with a number, or consist wholly of numbers, are valid when using dynamic member lookup, even though they would normally not be when used as a property or func. This is a bit of a digression, but, for example:

```swift
let route = root().1234 { "This is cool" }.text()

struct MyTotallyUnrelatedStruct {
	func 1234() -> String { ... } // compilation error
}
```

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

Dir can be called and passed either a variadic number of routes, an array of routes, or a closure which accepts a stand-in route and returns an array of routes to append. Let's look closer at this last case.

```swift
let foos = try root().v1.dir{[
	$0.foo1 { "OK1" },
	$0.foo2 { "OK2" },
	$0.foo3 { "OK3" },
]}.text()
```

This produces the following routes: `/v1/foo1`, `/v1/foo2`, and `/v1/foo3`, which each have the `text()` func applied to them.

It's important to note that because routes are strongly typed, all routes that are passed to `dir` must accept whatever type of value the preceeding function returns. Any misuse will be caught at compilation time.

The following case passes the current request's `path` URI to two different routes which each modify the value in some way and then pass it down the line.

```swift
let route = try root { $0.path }.v1.dir {[
	$0.upper { $0.uppercased() },
	$0.lower { $0.lowercased() }
]}.text()			
```

The above produces the following routes: `/v1/upper` and `/v1/lower`.

### HTTP Method

Unless otherwise indicated, a route will serve for any HTTP method (GET, POST, etc.). Calling one of the method properties on a route will force it to serve only with the method indicated. 

```swift
let route = try root().dir {[
	$0.GET.foo1 { "GET OK" },
	$0.POST.foo2 { "POST OK" },
]}.text()
```

Above, two routes are added, both with a URI of `/`. However, one accepts only GET and the other only POST.

If you wish a route to serve more than one HTTP method, the `method` func will facilitate this.

```swift
let route = root().method(.GET, .POST).foo { "GET or POST OK" }.text()
```

This will creat a route `/foo` which will answer to either GET or POST.

Applying a method like this to routes which have already had methods applied to them will remove the old method and apply the new.

### Route Operations

A variety of operations can be applied to a route. These operations include:

#### map
Transform an output in some way producing a new output or a sequence of output values.

Definitions:

```swift
public extension Routes {
	/// Add a function mapping the input to the output.
	func map<NewOut>(_ call: @escaping (OutType) throws -> NewOut) -> Routes<InType, NewOut>
	/// Add a function mapping the input to the output.
	func map<NewOut>(_ call: @escaping () throws -> NewOut) -> Routes<InType, NewOut>
	/// Map the values of a Collection to a new Array.
	func map<NewOut>(_ call: @escaping (OutType.Element) throws -> NewOut) -> Routes<InType, Array<NewOut>> where OutType: Collection 
}
```

Example:

```swift
let route = try root().dir {[
	$0.a { 1 }.map { "\($0)" }.text(),
	$0.b { [1,2,3] }.map { (i: Int) -> String in "\(i)" }.json()
]}
```

#### ext
Apply a file extension to the routes.

Definitions:

```swift
public extension Routes {
	/// Adds the indicated file extension to the route set.
	func ext(_ ext: String) -> Routes
	/// Adds the indicated file extension to the route set.
	/// Optionally set the response's content type.
	/// The given function accepts the input value and returns a new value.
	func ext<NewOut>(_ ext: String,
					  contentType: String? = nil,
					  _ call: @escaping (OutType) throws -> NewOut) -> Routes<InType, NewOut>
}
```

Example:

The following returns a `Foo` object to the client and makes the object available as either `json` or `text` by adding an appropriate file extension to the route URI.

```swift
struct Foo: Codable, CustomStringConvertible {
	var description: String {
		return "foo-data \(id)/\(date)"
	}
	let id: UUID
	let date: Date
}
let fooRoute = root().foo { Foo(id: UUID(), date: Date()) }
let route = try root().dir(
			fooRoute.ext("json").json(),
			fooRoute.ext("txt").text())
```

This will produce the routes `/foo.json` and `/foo.txt`.

#### wild
Apply a wildcard path segment.

Definitions:

```swift
public extension Routes {
	/// Adds a wildcard path component to the route set.
	/// The given function accepts the input value and the value for that wildcard path component, as given by the HTTP client,
	/// and returns a new value.
	func wild<NewOut>(_ call: @escaping (OutType, String) throws -> NewOut) -> Routes<InType, NewOut>
	/// Adds a wildcard path component to the route set.
	/// Gives the wildcard path component a variable name and the path component value is added as a request urlVariable.
	func wild(name: String) -> Routes
}
```

Example:

```swift
let route = root().wild { $1 }.foo.text()
```

Above, the route `/*/foo` is created. The "*" can be any string, which is then echoed back to the client.

WIldcard path components can also be given a name. This will make the component available through the `HTTPRequest.uriVariables` property, or for use during Decodable `decode` operations.

Example:

```swift
struct Req: Codable {
	let id: UUID
	let action: String
}
let route = root().v1
	.wild(name: "id")
	.wild(name: "action")
	.decode(Req.self) { return "\($1.id) - \($1.action)" }
	.text()
```

The above creates the route `/v1/*/*`. The "id" and "action" wildcards are saved and used during decoding of the `Req` object. The `Req` properties are then echoed back to the client.

#### trailing
Apply a trailing wildcard path segment

Definitions:

```swift
public extension Routes {
	/// Adds a trailing-wildcard to the route set.
	/// The given function accepts the input value and the value for the remaining path components, as given by the HTTP client,
	/// and returns a new value.
	func trailing<NewOut>(_ call: @escaping (OutType, String) throws -> NewOut) -> Routes<InType, NewOut>
}
```

Example:

```swift
let route = root().foo.trailing { $1 }.text()
```

The route `/foo/**` is created, with "**" matching any subsequent path components. The remaining path components String is available as the second argument (the first argument is still the current `HTTPRequest` object), and is then echoed back to the client. If a client accessed the URI `/foo/OK/OK`, the String "OK/OK" would be made available as the trailing wildcard value.

#### request
Access the HTTPRequest object. 

While all routes start off by receiving the current HTTPRequest object, it can often be more convenient to begin passing other values down your route pipeline but then go back to the request object for some cause.

Definitions:

```swift
public extension Routes {
	/// Adds the current HTTPRequest as a parameter to the function.
	func request<NewOut>(_ call: @escaping (OutType, HTTPRequest) throws -> NewOut) -> Routes<InType, NewOut> 
}
```

Example:

```swift
let route = root().foo { "OK" }.request { $1.path }.text()
```

This route URI is `/foo`. It echos back the request path by first discarding the HTTPRequest but then grabbing it again using the `request` func. The request is always provided as the second argument.

#### readBody
Read the client body data and deliver it to the provided callback.

Definitions:

```swift
public extension Routes {
	func readBody<NewOut>(_ call: @escaping (OutType, HTTPRequestContentType) throws -> NewOut) -> Routes<InType, NewOut>
}
```

Example:

```swift
let route = root().POST.readBody {
	(req: HTTPRequest, content: HTTPRequestContentType) -> String in
	switch content {
	case .urlForm: return "url-encoded"
	case .multiPartForm: return "multi-part"
	case .other: return "other"
	case .none:	return "none"
	}
}.text()
```

This example accepts a POST request at `/`. It reads the submitted body and returns a String describing what type the data was.

#### statusCheck
Assert some condition by returning either 'OK' (200..<300 status code) or failing.

Definitions:

```swift
public extension Routes {
	/// The caller can inspect the given input value and choose to return an HTTP error code.
	/// If any code outside of 200..<300 is return the request is aborted.
	func statusCheck(_ handler: @escaping (OutType) throws -> HTTPResponseStatus) -> Routes<InType, OutType>
	/// The caller can choose to return an HTTP error code.
	/// If any code outside of 200..<300 is return the request is aborted.
	func statusCheck(_ handler: @escaping () throws -> HTTPResponseStatus) -> Routes<InType, OutType>
}
```

Example:

```swift
let route = try root().dir {[
	$0.a,
	$0.b
]}.statusCheck {
	req in
	guard req.path != "/b" else {
		return .internalServerError
	}
	return .ok
}.map { req in "OK" }.text()
```

This route will serve the URIs `/a` and `/b`. However, the request will be deliberately failed with `.internalServerError` if the `/b` URI is accessed. After the function given to `statusCheck` is called, the route continues with the previous value. You can see this in the call to `map` where its first parameter reverts back to the current request after the status check.

#### decode
Read and decode the client body as a Decodable object.

Decode offers a few variants to fit different use cases.

Definitions:

```swift
public extension Routes {
	/// Read the client content body and then attempt to decode it as the indicated `Decodable` type.
	/// Both the original input value and the newly decoded object are delivered to the provided function.
	func decode<Type: Decodable, NewOut>(_ type: Type.Type,
					     _ handler: @escaping (OutType, Type) throws -> NewOut) -> Routes<InType, NewOut>
	/// Read the client content body and then attempt to decode it as the indicated `Decodable` type.
	/// The newly decoded object is delivered to the provided function.
	func decode<Type: Decodable, NewOut>(_ type: Type.Type,
					     _ handler: @escaping (Type) throws -> NewOut) -> Routes<InType, NewOut>
	/// Read the client content body and then attempt to decode it as the indicated `Decodable` type.
	/// The newly decoded object becomes the route set's new output value.
	func decode<Type: Decodable>(_ type: Type.Type) -> Routes<InType, Type>
	/// Decode the request body into the desired type, or throw an error.
	/// This function would be used after the content body has already been read.
	func decode<A: Decodable>(_ type: A.Type, content: HTTPRequestContentType) throws -> A
}
```

Example:

```swift
struct Foo: Codable {
	let id: UUID
	let date: Date
}
let route = try root().POST.dir{[
	$0.1.decode(Foo.self),
	$0.2.decode(Foo.self) { $1 },
	$0.3.decode(Foo.self) { $0 },
]}.json()
```

This example will serve the URIs `/1`, `/2`, and `/3`. It decodes the POST body in three different ways. #1 decodes the body and returns it as the new value (discarding the HTTPRequest). #2 decodes the body and calls the closure with the previous value, the HTTPRequest, and with the newly decoded Foo object. This case simply returns the Foo as the new value. #3 decodes the body and accepts it in a closure which accepts only one argument. This also is simply returned as the new value. Finally, regardless of which URI was hit, the value is converted to json and returns to the client.

#### unwrap
Unwrap an Optional value, or fail the request if the value is nil.

Definitions:

```swift
public extension Routes {
	/// If the output type is an `Optional`, this function permits it to be safely unwraped.
	/// If it can not be unwrapped the request is terminated.
	/// The provided function is called with the unwrapped value.
	func unwrap<U, NewOut>(_ call: @escaping (U) throws -> NewOut) -> Routes<InType, NewOut> where OutType == Optional<U>
}
```

Example:

```swift
let route = try root().dir {[
	$0.a { nil },
	$0.b { "OK" }
]}.unwrap { $0 }.text()
```

The above creates `/a` and `/b`. `/a` returns a nil `String?` while `/b` returns "OK". Either route's value will go through the `unwrap` func. If the value is nil, the request will be failed with an `.internalServerError`. (KRJ: address this. needs to be more flexible wrt response status code.)

#### async
Execute a task asynchronously, out of the NIO event loop.

When performing lengthy or blocking operations, such as external URL requests or database operations, it is vital that the operation be moved out of the NIO event loop. This `async` func lets you do just that. The activity moves into a new thread out of the NIO event loop within which you have free reign. When your activity has completed, signal the provided EventLoopPromise with your return value by calling either `success` or `fail`.

Definitions:

```swift
public extension Routes {
	/// Run the call asynchronously on a non-event loop thread.
	/// Caller must succeed or fail the given promise to continue the request.
	func async<NewOut>(_ call: @escaping (OutType, EventLoopPromise<NewOut>) -> ()) -> Routes<InType, NewOut>
}
```

Example:

```swift
let route = root().async {
	(req: HTTPRequest, p: EventLoopPromise<String>) in
	sleep(1)
	p.succeed(result: "OK")
}.text()
```

The above spins off an asynchronous activity (in this case, sleeping for 1 second) and then signals that it is complete. The value that it submits to the promise, "OK", is sent to the client.

It's important to note that subsequent activities for the route will occur on the NIO event loop.

#### text
Use a `CustomStringConvertible` as the output with a text/plain content type.

Definitions:

```swift
public extension Routes where OutType: CustomStringConvertible {
	func text() -> Routes<InType, HTTPOutput>
}
```

Example:

```swift
let route = root { 1 }.text()
```

Above, the route `/` is created which serves the stringified number 1.

#### json
Use an `Encodable` as the output with the application/json content type.

Definitions:

```swift
public extension Routes where OutType: Encodable {
	func json() -> Routes<InType, HTTPOutput>
}
```

Example:

```swift
struct Foo: Codable {
	let id: UUID
	let date: Date
}
let route = root().foo { Foo(id: UUID(), date: Date()) }.json()
```

This example create a route `/foo` which returns a Foo object. The Foo is converted to JSON and sent to the client.

#### compressed

Outgoing client content can be compressed using either gzip or deflate algorithms by calling the `compressed()` function on any route returning HTTPOutput.

```swift
/// Compresses eligible output
public extension Routes where OutType: HTTPOutput {
	func compressed() -> Routes<InType, HTTPOutput>
}
```

Compressed content takes HTTPOutput and then selectively compresses and sends the content to the client. If the source HTTPOutput object specifies a response Content-Length and that content length is less than 14k, the response will not be compressed. If the source HTTPoutput specifies a content-type and that type begins with "image/", "video/", or "audio/", the response will not be compressed.

Example:

```swift
class StreamOutput: HTTPOutput {
	var counter = 0
	override init() {
		super.init()
		kind = .stream
	}
	override func body(promise: EventLoopPromise<IOData?>, allocator: ByteBufferAllocator) {
		if counter > 15 {
			promise.succeed(result: nil)
		} else {
			let toSend = String(repeating: "\(counter % 10)", count: 1024)
			counter += 1
			let ary = Array(toSend.utf8)
			var buf = allocator.buffer(capacity: ary.count)
			buf.write(bytes: ary)
			promise.succeed(result: .byteBuffer(buf))
		}
	}
}
let route = root() { return StreamOutput() as HTTPOutput }.compressed()
```

This example streams text content to the client. The usage of `.compressed()` at the end of the route will turn on content compression.

### HTTPOutput

Considering a complete set of routes as a function, it would look like:

`(HTTPRequest) -> HTTPOutput`

<a href="httpoutput">`HTTPOutput`</a> is a base class which can optionally set the HTTP response status, headers and body data. Several concrete HTTPOutput implementations are provided for you, but you can add your own custom output by sub-classing and returning your object.

Built-in HTTPOutput types include `HTTPOutputError`, which can be thrown, JSONOutput, TextOutput, CompressedOutput, FileOutput, MustacheOutput, and BytesOutput.

```swift
/// The response output for the client
open class HTTPOutput {
	/// Indicates how the `body` func data, and possibly content-length, should be handled
	var kind: HTTPOutputResponseHint
	/// Optional HTTP head
	open func head(request: HTTPRequestHead) -> HTTPHead?
	/// Produce body data
	/// Set nil on last chunk
	/// Call promise.fail upon failure
	open func body(promise: EventLoopPromise<IOData?>, allocator: ByteBufferAllocator)
}
```

#### FileOutput

File content can be returned from a route by using the `FileOutput` type.

```swift
public class FileOutput: HTTPOutput {
	public init(localPath: String) throws
}
```

Example:

```swift
let route = root().test {
	try FileOutput(localPath: "/tmp/test.txt") as HTTPOutput
}.ext("txt")
```

This example serves the route /test.txt and returns the content of a local file. If the file does not exist or is not readable then an Error will be thrown.

#### MustacheOutput

Content from mustache templates can be returned from a route by using the `MustacheOutput` type. 

```swift
public class MustacheOutput: HTTPOutput {
	public init(templatePath: String,
				inputs: [String:Any],
				contentType: String) throws 
}
```

Example:

```swift
let route = root().test {
	try MustacheOutput(templatePath: tmpFilePath,
					   inputs: ["key1":"value1", "key2":"value2"],
					   contentType: "text/html") as HTTPOutput
}.ext("html")
```

This example processes and serves a mustache template file as text/html.

### Caveats

make notes on:
using diseparate types in `dir`
ordering of `wild` and `decode` wrt path variables
doing blocking activities in a non-async func

*TBD:*

* Logging - use the new sss logging stuff

### Reference

<a name="root"></a>
#### root()

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

<a name="routes"></a>
#### Routes\<InType, OutType\>

```swift
/// Main routes object.
/// Created by calling `root()` or by chaining a function from an existing route.
public struct Routes<InType, OutType> {
	// Routes can not be directly instantiated.
	// All functionality is provided through extensions.
}
```

<a name="httprequest"></a>
#### HTTPRequest

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
	var localAddress: SocketAddress? { get }
	var remoteAddress: SocketAddress? { get }
	func readSomeContent() -> EventLoopFuture<[ByteBuffer]>
	func readContent() -> EventLoopFuture<HTTPRequestContentType>
}
```

<a name="querydecoder"></a>
#### QueryDecoder

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
#### dir

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

<a name="routeerror"></a>
#### RouteError

```swift
/// An error occurring during process of building a set of routes.
public enum RouteError: Error, CustomStringConvertible {
	case duplicatedRoutes([String])
	public var description: String
}
```

<a name="httpoutput"></a>
#### HTTPOutput

```swift
/// The response output for the client
open class HTTPOutput {
	/// Indicates how the `body` func data, and possibly content-length, should be handled
	var kind: HTTPOutputResponseKind
	/// Optional HTTP head
	open func head(request: HTTPRequestHead) -> HTTPHead?
	/// Produce body data
	/// Set nil on last chunk
	/// Call promise.fail upon failure
	open func body(promise: EventLoopPromise<IOData?>, allocator: ByteBufferAllocator)
}
```

<a name="httprequestcontenttype"></a>
#### HTTPRequestContentType

```swift
/// Client content which has been read and parsed (if needed).
public enum HTTPRequestContentType {
	/// There was no content provided by the client.
	case none
	/// A multi-part form/file upload.
	case multiPartForm(MimeReader)
	/// A url-encoded form.
	case urlForm(QueryDecoder)
	/// Some other sort of content.
	case other([UInt8])
}
```

<a name="listeningroutes"></a>
#### ListeningRoutes

```swift
/// Routes which have been bound to a port and have started listening for connections.
public protocol ListeningRoutes {
	/// Stop listening for requests
	@discardableResult
	func stop() -> ListeningRoutes
	/// Wait, perhaps forever, until the routes have stopped listening for requests.
	func wait() throws
}
```

<a name="boundroutes"></a>
#### BoundRoutes

```swift
/// Routes which have been bound to a port but are not yet listening for requests.
public protocol BoundRoutes {
	/// The port
	var port: Int { get }
	/// The address
	var address: String { get }
	/// Start listening
	func listen() throws -> ListeningRoutes
}
```

<a name="methods"></a>
#### HTTP Methods

```swift
public extension Routes {
	var GET: Routes<InType, OutType>
	var POST: Routes
	var PUT: Routes
	var DELETE: Routes
	var OPTIONS: Routes
	func method(_ method: HTTPMethod, _ methods: HTTPMethod...) -> Routes
}
```

<a name="usage"></a>
### Package.swift Usage

In your Package.swift:

```swift
.package(url: "https://github.com/PerfectlySoft/Perfect-NIO.git", .branch("master"))
```

Your code may need to `import PerfectNIO`, `import NIO`, `import NIOHTTP1`, or `import NIOOpenSSL`.
