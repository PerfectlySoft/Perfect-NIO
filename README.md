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
Apply a file extension to the routes

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

#### wild
Apply a wildcard path segment

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

```

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

```

#### request
Access the HTTPRequest object

Definitions:

```swift
public extension Routes {
	/// Adds the current HTTPRequest as a parameter to the function.
	func request<NewOut>(_ call: @escaping (OutType, HTTPRequest) throws -> NewOut) -> Routes<InType, NewOut> 
}
```

Example:

```swift

```

#### readBody
Read the client body data

Definitions:

```swift
public extension Routes {
	func readBody<NewOut>(_ call: @escaping (OutType, HTTPRequestContentType) throws -> NewOut) -> Routes<InType, NewOut>
}
```

Example:

```swift

```

#### statusCheck
Assert some condition by returning either 'OK' (200..<300 status code) or failing

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

```

#### decode
Decode the client body as a Decodable type

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

```

#### unwrap
Unwrap an Optional value, or fail the request if the value is nil

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

```

#### async
Execute a task asynchronously, out of the NIO event loop

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

```

#### stream
Stream data to the client

Definitions:

```swift
public extension Routes {
	/// Stream bytes to the client. Caller should use the `StreamToken` to send data in chunks.
	/// Caller must call `StreamToken.complete()` when done.
	/// Response data is always sent using chunked encoding.
	func stream(_ call: @escaping (OutType, StreamToken) -> ()) -> Routes<InType, HTTPOutput>
}
```

Example:

```swift

```

#### text
Use a `CustomStringConvertible` as the output with a text/plain content type

Definitions:

```swift
public extension Routes where OutType: CustomStringConvertible {
	func text() -> Routes<InType, HTTPOutput>
}
```

Example:

```swift

```

#### json
Use an `Encodable` as the output with the application/json content type

Definitions:

```swift
public extension Routes where OutType: Encodable {
	func json() -> Routes<InType, HTTPOutput>
}
```

Example:

```swift

```


### HTTP Method

.GET and such

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
public protocol HTTPOutput {
	var status: HTTPResponseStatus? { get }
	var headers: HTTPHeaders? { get }
	var body: [UInt8]? { get }
}
```

<a name="streamtoken"></a>
#### StreamToken

```swift
/// An object given to a content streamer
public struct StreamToken {
	/// Push a chunk of bytes to the client.
	/// An error thrown from this call will generally indicate that the client has closed the connection.
	public func push(_ bytes: [UInt8]) throws
	/// Complete the response streaming.
	public func complete()
}
```

<a name="httprequestcontenttype"></a>
#### HTTPRequestContentType

```swift
public enum HTTPRequestContentType {
	case none,
		multiPartForm(MimeReader),
		urlForm(QueryDecoder),
		other([UInt8])
}
```

<a name="usage"></a>
### Package.swift Usage
In your Package.swift:
```swift
.package(url: "https://github.com/PerfectlySoft/Perfect-NIO.git", .branch("master"))
```

Your code may need to `import PerfectNIO`, `import NIO`, `import NIOHTTP1`, or `import NIOOpenSSL`.
