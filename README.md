# ReloadableMiddleware.jl

_`Revise`-compatible hot-reloading middleware for web development in Julia_

Development utilities for improving your workflow when building web
applications in pure-Julia. This package integrates with `Revise` and `HTTP` to
allow for automatic hot-reloading pages with "in-place" DOM-swapping rather
than full-page refreshes.

## Project Scaffolding

To scaffold a new web app project using this package and a collection of other
useful packages you can run the following copy-paste code in the Julia REPL. It
will launch an interactive prompt to ask you for some details about your project
and then create all the starter files for you.

```julia
julia> import Pkg
       Pkg.activate(; temp = true)
       Pkg.add(["ReloadableMiddleware", "PkgTemplates"])
       using ReloadableMiddleware
       ReloadableMiddleware.Templates.create()

```

This will avoid polluting your global environment with packages and will create
a new project in the current directory.

## `HotReloader`

A `HotReloader` can be added to the top of a `HTTP` router stack to enable
hot-reloading of page content.

```julia
using HTTP
using ReloadableMiddleware

hot = HotReloader()
router = HTTP.Router()

# Add some routes to the `router`...

HTTP.serve!(router |> hot.middleware, HTTP.Sockets.localhost, 8080)

# Later on:
hot.refresh() # Refresh the page.
```

Calling `hot.refresh()` will cause any clients connected to the server to
reload their page. The reload is done "in-place" by swapping out the DOM
content with the new content for a page rather than doing a full page refresh.

This does not perform any file-watching or other automatic reloading. It is
intended to be used in conjunction with separate file-watching utilities such
as the `FileWatching` module.

## `ModuleRouter`

This type can be used to automatically create an `HTTP.Router` based on the functions
defined in a given module, or modules. The router automatically updates itself when
changes are detected by `Revise` if a `HotReloader` is present in the router stack.

You can define functions within a module that should act as endpoints for the
router with the `@req` macro. Some examples follow which describe the general
form of the `@req` macro and what it supports.

```julia
module Routes

function index(req::@req GET "/")
    # Just a plain GET / request.
end

function search(req::@req GET "/search" query = {q})
    # GET /search?q=... where the `q` parameter is left as a `String` value.
end

function table(req::@req GET "/table" query = {page::Int})
    # GET /table?page=... where the `page` parameter is parsed as an `Int` for pagination.
    # When `page` is not parsable to an `Int` then we don't call this function, and an error
    # is returned to the client. So we can guarantee that `page` exists and is an `Int` here.
end

function user_account(req::@req GET "/user/$(id::Base.UUID)")
    # GET /user/{id} where the `id` parameter is parsed as a `UUID`. When not parsable to a
    # `UUID` then we don't call this function, and an error is returned to the client.
end

function blog_post(req::@req GET "/blog/$(title)")
    # GET /blog/{title} where the `title` parameter is parsed as a `String`.
end

# Use `(` and `)` when you need multi-line syntax.
function edit_post(
    req::@req(
        POST,
        "/blog/$(title)",
        query = {
            author,
            content = "blank content",
            date::Dates.Date
        },
    )
)
    # POST /blog/{title} where the `title` parameter is parsed as a `String`. Form data is
    # pass via URL query parameters. If it fails to parse then we don't call this function, and
    # an error is returned to the client. `content` is optional and defaults to `"blank content"`
    # if not provided.
end

function edit_post_form_data(
    req::@req(
        POST,
        "/blog/$(title)",
        form = {
            author,
            content = "blank content",
            date::Dates.Date
        }
    )
)
    # POST /blog/{title} where the `title` parameter is parsed as a `String`. Data form data is
    # parsed from the request body. If it fails to parse then we don't call this function, and
    # an error is returned to the client. `content` is optional and defaults to `"blank content"`.
end

end
```

To turn the above `Router` module into a router we can do the following:

```julia
router = MoudleRouter(Routes)

HTTP.serve(router, HTTP.Sockets.localhost, 8080)
```

Note that the `ModuleRouter` automatically integrates with the `HotReloader`
middleware if it is included in the router stack. This means that you can make
changes to the `Routes` module and have them automatically reflected in the
running server as soon as changes are made and you save the file.

### `@req` syntax

```julia
@req(method, path, [query], [form])
```

where `method` can be any of

- `GET`
- `POST`
- `PUT`
- `DELETE`
- `PATCH`
- `"*"` (due to Julia's macro syntax this must be a string literal)

`path` is either a plain `String` literal representing the path, or a string
literal with interpolated values. Interpolated values are parsed as follows:

- `$(x)` is parsed as a `String` value for the field named `x`.
- `$(x::T)` is parsed as a value of type `T` where `T` is any type that can be
  parsed from a `String` via `Base.parse` for the field named `x`.

These values are then available as fields in the `params` field of the `Req` object
passed to the function. For example, the following function:

```julia
function get_post(req::@req GET "/blog/$(id::Base.UUID)")
    req.params.id # This is a `Base.UUID` value.
end
```

The optional `query` and `form` fields are used to parse query parameters and
form data respectively. These fields are parsed as follows:

- `query = {x}` or `form = {x}` is parsed as a query parameter named `x` which
  is parsed as a `String` value.
- `query = {x::T}` or `form = {x::T}` is parsed as a query parameter named `x`
  which is parsed as a value of type `T` where `T` is any type that can be
  parsed from a `String` via `Base.parse`, the same as for `params` above.
  If the parameter needs to contain multiple values, e.g. `a=1&a=2` then `T` can
  be a `Vector` of the type of the individual values in which case the value of
  `a` will be `["1", "2"]` when `Vector{String}` is specified.
- any number of fields can be specified in the `{...}` syntax, separated by
  commas.
- default values can be specified by using `x = default` instead of `x` in the
  above syntax. Or `x::T = default` for a typed default value. These values are
  created on-demand when the parameter is not present in the request and are not
  created until needed.

`form` data by default assumes that the request body syntax is
`application/x-www-form-urlencoded` and that that the `Content-Type` header is
set to `application/x-www-form-urlencoded`. Parsing of this text is done using
`URIs.parseparams(s::AbstractString)`.

#### JSON form data

JSON data parsing can be enabled by setting the `Content-Type` header to
`application/json` in the request. This will cause the `form` fields to be
parsed as JSON instead of as form data. The `{...}` syntax is still used, so
each field in the `NamedTuple` to is parsed is a JSON-parsed value. `JSON3.jl`
is used for the parsing, and as such we support using custom Julia types for
the resulting values so long as suitable `StructType` definitions are provided.
Please see the `JSON3.jl` documentation for more information on this topic.

```julia
struct CustomType
    x::Int
    y::Float64
end

function json_endpoint(req::@req POST "/json" form = {x::CustomType})
    # `x` is parsed as a `CustomType` value.
end
```

The HTTP request would then need to be sent as follows:

```http
POST /json HTTP/1.1
Content-Type: application/json

{
    "x": {
        "x": 1,
        "y": 2.0
    }
}
```
