# `Router`

This module provides the route macros `@GET`, `@POST`, `@PUT`, `@PATCH`, and
`@DELETE` matching their HTTP verbs, along with `@STREAM` and `@WEBSOCKET`
macros. These are used to define `HTTP` route handlers within the enclosing
`module`.

Routes must be defined within a submodule, or submodules, of the Julia package
that implements your application. For example, a `Routes` module:

```julia
module Routes

using ReloadableMiddleware.Router
```

Handler functions can be named or unnamed function definitions. Named functions
can later be referenced in HTML templates via [Validated router paths](@ref).

```julia
@GET "/" function (req)
    # Anything can be returned from the handler. It will be converted
    # to an `HTTP.Response` automatically. See the `Responses` module
    # for details.
    return "page content..."
end
```

## `path` parameters

Use the same `{}` syntax as `HTTP`. Additionally include a `path` keyword that
declares the type of each path parameter. `StructTypes` is used for the
deserialization of these parameters.

```julia
@GET "/page/{id}" function (req; path::@NamedTuple{id::Int})
    @show path.id
    # ...
end
```

## `body` parameters

Post requests specify their typed body contents as below. This is
expected to be urlencoded `Content-Type`.

```julia
@POST "/form" function (req; body::@NamedTuple{a::String,b::Base.UUID})
    @show body.a, body.b
    # ...
end
```

## `query` parameters

Query parameters are specified using the `query` keyword. These are urlencoded
values, and are deserialized, like the previous examples using `StructTypes`.

```julia
@GET "/search" function (req; query::@NamedTuple{q::String})
    @show query.q
    # ...
end
```

## `JSON3.jl` integration

JSON data can be deserialized using the `JSON` type. Anything that the `JSON3`
package handles can be handled with this type. `allow_inf` is set to `true` for
deserialization.

```julia
@POST "/api/v1/info" function (req; body::JSON{Vector{Float64}})
    @show vec = body.json
    # ...
end
```

## Multipart form data

Multipart form data can be deserialized using the `Multipart` and `RawFile`
type as below.

```julia
@POST "/file-upload" function (req; body::Multipart{@NamedTuple{file::RawFile}})
    @show body.multipart.file body.multipart.data
    # ...
end
```

Multipart form data can also be deserialized using the `Multipart` and `File`
type as below. `.data` will contain a `Vector{Int}` rather than raw bytes. The
`Content-Type` of the part denotes how it will be deserialized, either as JSON
or urlencoded.

```julia
@POST "/file-upload-typed" function (
    req;
    body::Multipart{@NamedTuple{file::File{Vector{Int}}}},
)
    @show body.multipart.file body.multipart.data
    # ...
end
```

## Scoped Routes

The `@prefix` and `@middleware` macros allow for defining "scoped" routes. This
provides a way to group a set of routes under a common path prefix and a scoped
set of middleware that should be applied in addition to the `Server`-level
middleware.

These macros work on the module-level, ie. only a single usage per-module is
allowed and affects all routes defined within the module. Use different modules
to separate different sets of routes, for example a `Routes.API` module to
define a JSON API that lives under a `/api/v1` route prefix.

```julia
module Routes

@GET "/" function (req)
    # The actual `/` handler.
end

module API

@prefix "/api/v1"

@middleware function (handler)
    function (req)
        # Run custom middleware code here. Only runs for routes under `/api/v1`.
        return handler(req)
    end
end

@GET "/" function (req)
    # Handles `/api/v1`, not `/`.
end

end

end
```

## Validated router paths

You can construct valid paths to any defined route by calling the route handler
function with no positional arguments and either/both of the `path` and `query`
keyword arguments. If called with invalid values it will fail at runtime to
construct the path. This only works for named route handler functions.

```julia
@GET "/users/{id}" function user_details(req; path::@NamedTuple{id::Int})
    # ...
end

# ...

user_details(; path = (; id = 1)) == "/users/1"
user_details(; path = (; id = "id")) # Throws an error.
```

```@autodocs
Modules = [
    ReloadableMiddleware.Router,
]
```
