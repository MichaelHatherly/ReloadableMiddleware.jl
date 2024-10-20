# ReloadableMiddleware.jl

*`Revise`-compatible hot-reloading middleware for web development in Julia*

This package provides a collection of utilities and HTTP middleware that
improves developer experience while working on server-based Julia projects.

## Exported Modules

The following modules are exported and make up the public API of this package.

### `Server`

Provides the `dev` and `prod` function. These start up a "development" and
"production" server respectively. The `dev` server includes features such as:

#### `dev` features

##### Automatic Page Updates

Automatic page updates on file changes without refreshing browser tabs. This
will watch all source files for changes and push the updated HTML to the
browser via SSE (server sent events). New HTML content is swapped with the
current HTML with [`idiomorph`](https://github.com/bigskysoftware/idiomorph).

This feature integrates with `Revise` and a router auto-reloader, which allows
for addition and removal of route definitions in the server without the need to
restart it. The usual limitations of `Revise` apply to this feature, ie. no
`struct` re-definitions, etc.

##### Automatic Browser Tab Opening

When starting up a `dev` server a browser tab is opened pointing to the `/`
route. On macOS if using a Chromium-based browser then if there is alread a tab
open pointing at this server then it is reused. This uses the same approach
used by [Vite](https://vite.dev/).

##### Source Code Lookup

"DOM-to-Source" lookup, via `HypertextTemplates.jl`. When using this package
for template rendering source information for all nodes in the rendered web
page are stored and can be used to jump to the source location in your default
editor by selecting a part of the webpage, typically some text, and pressing
`Ctrl+2`. Pressing `Ctrl+1` will jump to the root `@render` macro call that
generated the element, which can be useful if the current state of a page
consists of HTML generated by different routes. This feature requires `Revise`
to be imported for it to function.

##### `/docs/` route

All documentation for defined routes that make up the application is available
at the `/docs/` route. This change be changed via the `docs` keyword provided
by `dev`. This provides a summary overview and details view for each route,
which includes any attached docstrings, `path`, `query`, and `body` types,
along with source code links that will open your default editor to the source
of the route.

##### `/errors/` route

Any errors that are thrown during development cause a separate browser tab to
open with an interactive view of the stacktrace and error message. Source links
in the stacktrace are clickable and open your default editor at that location.

The `/errors/` root route itself lists all errors that the application has
encountered while running, and allows you to navigate back to previous errors.

The name of this route change be changed if it conflicts with your application
by changing the `errors` keyword in the `dev` call.

#### `prod` features

The `prod` function removes all the above features of `dev`. Aside from that
the interface is identical. Ensure that `Revise` is not loaded when running a
server via `prod` in production since you may leak source location information
from rendered templates.

### `Router`

This module provides the route macros `@GET`, `@POST`, `@PUT`, `@PATCH`, and
`@DELETE` matching their HTTP verbs, along with `@STREAM` and `@WEBSOCKET`
macros. These are used to define `HTTP` route handlers within the enclosing
`module`. They all follow the pattern below:

```julia
module Routes

using ReloadableMiddleware.Router

# Handler functions must be unnamed function definitions.
@GET "/" function (req)
    # Anything can be returned from the handler. It will be converted
    # to an `HTTP.Response` automatically. See the `Responses` section
    # below for details.
    return "page content..."
end

# Use the same `{}` syntax as `HTTP`. Additionally include a `path` keyword
# that declares the type of each path parameter. `StructTypes` is used for
# the deserialization of these parameters.
@GET "/page/{id}" function (req; path::@NamedTuple{id::Int})
    @show path.id
    # ...
end

# Post requests specify their typed body contents as below. This is
# expected to be urlencoded `Content-Type`.
@POST "/form" function (req; body::@NamedTuple{a::String,b::Base.UUID})
    @show body.a, body.b
    # ...
end

# Query parameters are specified using the `query` keyword. These are
# urlencoded values, and are deserialized, like the previous examples
# using `StructTypes`.
@GET "/search" function (req; query::@NamedTuple{q::String})
    @show query.q
    # ...
end

# JSON data can be deserialized using the `JSON` type. Anything that
# the `JSON3` package handles can be handled with this type. `allow_inf`
# is set to `true` for deserialization.
@POST "/api/v1/info" function (req; body::JSON{Vector{Float64}})
    @show vec = body.json
    # ...
end

# Multipart form data can be deserialized using the `Multipart` and `RawFile`
# type as below.
@POST "/file-upload" function (req; body::Multipart{@NamedTuple{file::RawFile}})
    @show body.multipart.file body.multipart.data
    # ...
end

# Multipart form data can be deserialized using the `Multipart` and `File`
# type as below. `.data` will contain a `Vector{Int}` rather than raw bytes.
# The `Content-Type` of the part denotes how it will be deserialized, either
# as JSON or urlencoded.
@POST "/file-upload-typed" function (req; body::Multipart{@NamedTuple{file::File{Vector{Int}}}})
    @show body.multipart.file body.multipart.data
    # ...
end
```

### `Responses`

This module is responsible for serializing returned values from route handlers
into valid `HTTP.Response`s. Any value returned from a handler is supported.
`String`s are content-sniffed using `HTTP.sniff` to determine `Content-Type`.
`Base.Docs.HTML` and `Base.Docs.Text` are set to `text/html` and `text/plain`
respectively. Simple values such as numbers, symbols, and characters are sent
as `text/plain`. Other values are serialized as `application/json` using the
`JSON3` package, using the `allow_inf = true` keyword.

The module exports a `response` helper function that allows for declaring the
intended serialization mime type, along with other options such as `attachment`
and `filename` which effect the `Content-Disposition` header.
