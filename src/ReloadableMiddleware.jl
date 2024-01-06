module ReloadableMiddleware

# Imports.

import Dates
import HTTP
import JSON3
import MIMEs
import MacroTools
import PackageExtensionCompat
import StructTypes
import Tricks
import URIs

# Exports.

export @req
export url
export HotReloader
export ModuleRouter
export RouteTable
export ServerStateProvider
export server_state

# Template `create`r.

module Templates

struct CreateTemplateDispatchType end

"""
    ReloadableMiddleware.Templates.create(; dir, interactive)

Create a new webapp skeleton using an opioniated package selection.
This function is only available when `PkgTemplates` is also loaded.
"""
create(; kws...) = _create(CreateTemplateDispatchType(); kws...)

_create(::Any; kws...) =
    error("`PkgTemplates` is not loaded. Please load it first before using this function.")

end

# Module router.

struct Optional end

struct Req{Method,Path,Params,Query,QueryDefaults,Form,FormDefaults}
    request::HTTP.Request
    params::Params
    query::Query
    form::Form
end

const QUERY_DEFAULTS = () -> (;)
const FORM_DEFAULTS = () -> (;)

function ReqTypeBuilder(
    method::String,
    path::String;
    params = @NamedTuple{},
    query = @NamedTuple{},
    query_defaults = QUERY_DEFAULTS,
    form = @NamedTuple{},
    form_defaults = FORM_DEFAULTS,
)
    method in ("*", "GET", "POST", "PUT", "DELETE", "PATCH") || error("invalid HTTP method")
    return Req{
        Symbol(method),
        Symbol(path),
        params,
        query,
        typeof(query_defaults),
        form,
        typeof(form_defaults),
    }
end

"""
    url(route, params=(;); query=(;))::String

Construct a URL from a route function, params, and query. This is useful for
generating URLs without having to hardcode them in your templates. The function
will throw an error if the route function does not match the provided params and
query so that all generated URLs are valid.
"""
url(route::Function, params::NamedTuple = (;); query::NamedTuple = (;)) = _url(route, params, query)

@generated function _url(
    f::Function,
    params::Params,
    query::Query,
) where {Params<:NamedTuple,Query<:NamedTuple}
    T = Tuple{<:Req{<:Any,<:Any,Params,Query}}
    quote
        ms = Tricks.static_methods(f, $T)
        count = length(ms)
        count < 1 && error("route function has no matching methods.")
        count > 1 && error("route function has more than one matching method.")
        return _gen_url(only(ms).sig, params, query)::String
    end
end

@generated function _gen_url(::Type{Tuple{F,T}}, params, query) where {F,T}
    path = _get_path(T)
    segments = split(path, "/"; keepempty = false)
    expr = Expr(:string, "/")
    no_params = true
    for (nth, segment) in enumerate(segments)
        if nth > 1
            push!(expr.args, "/")
        end
        if startswith(segment, "{") && endswith(segment, "}")
            key = Symbol(segment[2:end-1])
            push!(expr.args, :(_escape_uri(params.$key)))
            no_params = false
        else
            push!(expr.args, :($segment))
        end
    end
    if no_params
        return Expr(:string, path, :(_format_query(query)))
    else
        push!(expr.args, :(_format_query(query)))
        return expr
    end
end
_get_path(::Type{<:Req{Method,Path}}) where {Method,Path} = String(Path)

function _format_query(nt::NamedTuple)
    buffer = IOBuffer()
    print(buffer, "?")
    for (nth, (k, v)) in enumerate(pairs(nt))
        nth > 1 && print(buffer, "&")
        if isa(v, Union{AbstractVector,Tuple})
            for (nth, each) in enumerate(v)
                nth > 1 && print(buffer, "&")
                print(buffer, k, "=", _escape_uri(each))
            end
        else
            print(buffer, k, "=", _escape_uri(v))
        end
    end
    return String(take!(buffer))
end
_format_query(::@NamedTuple{}) = ""

_escape_uri(v) = HTTP.URIs.escapeuri(string(v))

"""
    @req method path [param={}] [query={}] [form={}]

Define an HTTP route type that will unpack an `HTTP.Request` into a `Req` object
that is fully typed and expected to contain the correct parameters, query
parameters, and form parameters. See the README for detailed documentation.
"""
macro req(method, path, kws...)
    return _req_macro(method, path, kws...)
end

function _req_macro(method, path, kws...)
    method = String(method)
    path, params = _parse_path(path)
    keywords = []
    for kw in kws
        type, defaults = _parse_curly(kw)
        isnothing(type) || push!(keywords, type)
        isnothing(defaults) || push!(keywords, defaults)
    end
    return esc(
        :($(ReloadableMiddleware).ReqTypeBuilder($(method), $(path); $(params), $(keywords...))),
    )
end

function _parse_path(p::Expr)
    if Meta.isexpr(p, :string)
        params = []
        parts = map(p.args) do arg
            if isa(arg, String)
                arg
            elseif isa(arg, Symbol)
                push!(params, Expr(:(::), arg, :String))
                "{$(arg)}"
            else
                if MacroTools.@capture(arg, key_::type_)
                    push!(params, arg)
                    "{$(key)}"
                else
                    error("invalid path expression")
                end
            end
        end
        path = join(parts)
        return path, Expr(:kw, :params, :(@NamedTuple{$(params...)}))
    else
        error("invalid path expression")
    end
end
_parse_path(p::String) = p, Expr(:kw, :params, :(@NamedTuple{}))

function _parse_curly(ex::Expr)
    if MacroTools.@capture(ex, keyword_ = {args__})
        defaults = []
        fields = []
        for arg in args
            if MacroTools.@capture(arg, key_ = default_)
                if MacroTools.@capture(key, key_inner_::type_)
                    push!(defaults, Expr(:kw, key_inner, :(() -> $(default))))
                    push!(fields, Expr(:(::), key_inner, type))
                else
                    if isa(key, Symbol)
                        push!(defaults, Expr(:kw, key, :(() -> $(default))))
                        push!(fields, Expr(:(::), key, :String))
                    else
                        error("invalid curly expression")
                    end
                end
            else
                if MacroTools.@capture(arg, key_::type_)
                    push!(fields, Expr(:(::), key, type))
                else
                    if MacroTools.@capture(arg, key_)
                        push!(fields, Expr(:(::), key, :String))
                    else
                        error("invalid curly expression")
                    end
                end
            end
        end
        defaults =
            isempty(defaults) ? nothing :
            :($(Symbol(keyword, :_defaults)) = () -> (; $(defaults...)))
        fields = isempty(fields) ? nothing : :($keyword = @NamedTuple{$(fields...)})
        fields, defaults
    else
        error("invalid keyword expression")
    end
end

struct ReqBuilder{R,F} <: Function
    handler::F
end

ReqBuilder(R, f::F) where {F} = ReqBuilder{R,F}(f)

function (rb::ReqBuilder{Req{Method,Path,Params,Query,QueryDefaults,Form,FormDefaults}})(
    req::HTTP.Request,
) where {Method,Path,Params,Query,QueryDefaults,Form,FormDefaults}
    params = _build_params(Params, req)
    query = _build_query(Query, QueryDefaults.instance(), req)
    form = _build_form(Form, FormDefaults.instance(), req)
    return rb.handler(
        Req{Method,Path,Params,Query,QueryDefaults,Form,FormDefaults}(req, params, query, form),
    )
end

type_tuple_to_tuple(::Type{Tuple{}}) = ()
type_tuple_to_tuple(T::Type{<:Tuple}) =
    (Base.tuple_type_head(T), type_tuple_to_tuple(Base.tuple_type_tail(T))...)

_parse(::Type{T}, vec::Vector{String}) where {T} = _parse(T, only(vec))
_parse(::Type{Vector{T}}, vec::Vector{String}) where {T} = [_parse(T, each) for each in vec]

_parse(::Type{String}, value::String) = value
_parse(::Type{T}, value::Union{HTTP.Multipart,String}) where {T} =
    _parse(T, StructTypes.StructType(T), value)

# Handle scalar types using StructTypes deserialization to support such custom
# types as Enums. Fallback to Base.parse for other types, such as
# `Colors.Colorant` which uses `parse` to support parsing color names.
function _parse(
    ::Type{T},
    ::Union{
        StructTypes.StringType,
        StructTypes.NumberType,
        StructTypes.BoolType,
        StructTypes.NullType,
    },
    value::String,
) where {T}
    return StructTypes.constructfrom(T, value)
end
_parse(::Type{T}, ::StructTypes.StructType, value::String) where {T} = Base.parse(T, value)
_parse(::Type{T}, ::StructTypes.StructType, value::HTTP.Multipart) where {T} = T(value)

function _parse_kv_or_error(
    req::HTTP.Request,
    defaults::NamedTuple,
    dict::Dict{String},
    key::Symbol,
    T::Type,
    keys,
)
    str_key = String(key)
    if haskey(dict, str_key)
        value = dict[str_key]
        return _parse(T, value)::T
    else
        if hasproperty(defaults, key)
            return getproperty(defaults, key)()::T
        else
            error("missing key '$key' in $(req)")
        end
    end
end

function _build_params(::Type{NamedTuple{K,T}}, req::HTTP.Request)::NamedTuple{K,T} where {K,T}
    return _build_nt(K, T, req, (;), HTTP.getparams(req))
end
_build_params(::Type{@NamedTuple{}}, ::HTTP.Request) = (;)

function _build_query(
    ::Type{NamedTuple{K,T}},
    defaults,
    req::HTTP.Request,
)::NamedTuple{K,T} where {K,T}
    uri = URIs.URI(req.target)
    params = _queryparams(uri)
    return _build_nt(K, T, req, defaults, params)
end
_build_query(::Type{@NamedTuple{}}, ::HTTP.Request) = (;)

function _build_form(
    ::Type{NamedTuple{K,T}},
    defaults,
    req::HTTP.Request,
)::NamedTuple{K,T} where {K,T}
    content_type = _content_type(req)
    if startswith(content_type, "multipart/form-data")
        parts = _multipart_form(req)
        return _build_nt(K, T, req, defaults, parts)
    elseif content_type == "application/json"
        return JSON3.read(req.body, NamedTuple{K,T}; allow_inf = true)
    else
        params = _queryparams(String(req.body))
        return _build_nt(K, T, req, defaults, params)
    end
end
_build_form(::Type{@NamedTuple{}}, ::HTTP.Request) = (;)

function _build_nt(K, T, req, defaults, dict)
    ts = type_tuple_to_tuple(T)
    return NamedTuple{K,T}((
        _parse_kv_or_error(req, defaults, dict, k, t, K) for (k, t) in zip(K, ts)
    ))
end

function _multipart_form(req::HTTP.Request)
    dict = Dict{String,HTTP.Multipart}()
    for part in HTTP.parse_multipart_form(req)
        dict[part.name] = part
    end
    return dict
end

function _queryparams(pairs::Vector{Pair{String,String}})
    dict = Dict{String,Vector{String}}()
    for (key, value) in pairs
        push!(get!(Vector{String}, dict, key), value)
    end
    return dict
end
_queryparams(s::String) = _queryparams(URIs.queryparampairs(s))
_queryparams(uri::URIs.URI) = _queryparams(URIs.queryparampairs(uri))

function _content_type(req::HTTP.Request)
    for (k, v) in req.headers
        if k == "Content-Type"
            return v
        end
    end
    return ""
end

"""
    ModuleRouter(mod::Module; api_route = "/api")
    ModuleRouter(mods::Vector{Module}; api_route = "/api")

A router that automatically registers all functions in a module as routes if
they have a `@target` annotation. When `Revise` is loaded then the router will
be automatically updated when anything in the module changes, such as new
routes, or removed routes.

`api_route` is the route prefix that will be used for displaying the route table
and information about all routes defined by this router. You can change the name
of this route by passing a different value to `api_route`. Navigating to this
route will show a table of all routes that are registered in the module(s). This
is a useful debugging tool to see what routes are available and what their
signatures are along with any written documentation. When not in a development
environment (no `Revise` loaded) then this route will not be available.
"""
mutable struct ModuleRouter
    base::HTTP.Router
    mods::Vector{Module}
    mtimes::Dict{String,Float64}
    router::HTTP.Router
    api::String

    function ModuleRouter(mods::Vector{Module}; api = "/api")
        if !startswith(api, "/")
            error("`api` must be a valid route path starting with a `/`.")
        end
        r = HTTP.Router()
        return new(r, mods, Dict(), _build_router(r, mods, api), api)
    end
    ModuleRouter(mod::Module) = ModuleRouter([mod])
end
(mr::ModuleRouter)(req::HTTP.Request) = _handle_router_call(mr, req)

_handle_router_call(mr, req) = _router_call(mr, req)
_router_call(mr::ModuleRouter, req::HTTP.Request) = mr.router(req)

function _build_router(base::HTTP.Router, modules::Vector{Module}, api::String)
    return _build_router_impl!(HTTP.Router(base), modules, api)
end

function _build_router_impl!(router, modules::Vector{Module}, api)
    routes = []
    for mod in modules
        for name in names(mod; all = true)
            if isdefined(mod, name) && !Base.isdeprecated(mod, name)
                object = getfield(mod, name)
                if isa(object, Function)
                    for m in methods(object, mod)
                        _register_route!(
                            router,
                            routes,
                            object,
                            mod,
                            _tuple_type_head(Base.tuple_type_tail(m.sig)),
                        )
                    end
                end
            end
        end
    end
    _add_api_routes!(router, routes, api)
    return router
end

_tuple_type_head(::Type{Tuple{}}) = nothing
_tuple_type_head(T::Type{<:Tuple}) = fieldtype(T, 1)

function _register_route!(
    router::HTTP.Router,
    routes::Vector,
    handler::F,
    mod::Module,
    REQ::Type{<:Req{Method,Path}},
) where {F<:Function,Method,Path}
    method = String(Method)
    path = String(Path)
    HTTP.register!(router, method, path, ReqBuilder{REQ,F}(handler))
    push!(routes, (; method, path, handler, mod, sig = REQ))
    return nothing
end
_register_route!(::HTTP.Router, ::Vector, ::Function, mod::Module, other) = nothing

_add_api_routes!(router, routes, api) = nothing

struct RouteInfo
    method::String
    path::String
    handler::Function
    mod::Module
    file::String
    line::Int

    function RouteInfo(method, path, handler, mod, sig)
        m = only(methods(handler, Tuple{sig}))
        return new(String(method), String(path), handler, mod, String(m.file), m.line)
    end
end

"""
    RouteTable(mod::Module)
    RouteTable(mods::Vector{Module})

Show a table of all routes that are registered in the provided module(s).

Useful for debugging and introspection of the `ModuleRouter` middleware.
"""
struct RouteTable
    routes::Vector{RouteInfo}

    function RouteTable(mods::Union{Module,Vector{Module}})
        return new(_build_router_impl!([], vcat(mods), "/api"))
    end
end

function Base.show(io::IO, table::RouteTable)
    method_width = 0
    path_width = 0
    module_width = 0
    function_width = 0
    for route in table.routes
        method_width = max(method_width, length(route.method))
        path_width = max(path_width, length(route.path))
        module_width = max(module_width, length(string(route.mod)))
        function_width = max(function_width, length(string(route.handler)))
    end
    sort!(table.routes, by = route -> (route.path, route.method))
    for (nth, route) in enumerate(table.routes)
        nth > 1 && println(io)
        print(io, lpad(string(nth), ndigits(length(table.routes)));)
        print(io, " ")
        printstyled(io, rpad(route.method, method_width), bold = true, color = :blue)
        print(io, " ")
        printstyled(io, rpad(route.path, path_width), bold = true, color = :green)
        print(io, " ")
        print(io, lpad(string(route.mod), module_width))
        print(io, ".")
        printstyled(io, rpad(string(route.handler), function_width), bold = true, color = :magenta)
        print(io, " ")
        print(io, "$(route.file):$(route.line)")
    end
end

function _register_route!(
    routes::Vector,
    ::Vector,
    handler::F,
    mod::Module,
    REQ::Type{<:Req{Method,Path}},
) where {F<:Function,Method,Path}
    push!(routes, RouteInfo(Method, Path, handler, mod, REQ))
    return nothing
end
_register_route!(::Vector, ::Vector, ::Function, mod::Module, other) = nothing

# Server state.

const _SERVER_STATE_KEY = gensym(:server_state)

"""
    ServerStateProvider(state)

Middleware that adds a `state` object to the request context. This is useful
for storing state that should be shared between routes. Access the state with
`server_state(req)`.
"""
function ServerStateProvider(state)
    function (handler)
        function (req::HTTP.Request)
            req.context[_SERVER_STATE_KEY] = state
            return handler(req)
        end
    end
end

function server_state(req::HTTP.Request)
    key = _SERVER_STATE_KEY
    if haskey(req.context, key)
        return req.context[key]
    else
        error("server state not set")
    end
end
server_state(req::Req) = server_state(req.request)

# Hot reloading with server sent events and Revise.

struct HotReloaderDispatchType end

"""
    HotReloader() -> (; server, refresh, middleware)

Define middleware to hot-reload webpages during local development. When
`Revise` is not loaded then this middleware does nothing. `refresh` is a
zero-argument function that triggers a reload event for all clients.
`middleware` is the middleware function that should be added to the server.

The middleware will automatically add a `<script>` tag to the response that
will connect to the server sent event stream. When a reload event is received
then the page will be reloaded. This is done by morphing the DOM using
`Idiomorph` rather than performing a full page refresh.

This middleware integrates with `Revise` to ensure that prior to any requests
being handled that any pending revisions are applied. This means that you can
edit your code and then immediately see the changes in the browser without
having to manually refresh the page or run `Revise.revise()` in the REPL
manually.

## Example

```julia
using Revise
using HTTP
using ReloadableMiddleware

function serve()
    router = HTTP.Router()
    # register some routes here...
    
    # Create the hot-reloading middleware.
    hot = HotReloader()

    server = HTTP.serve!(
        router |>
        # Add the hot-reloading middleware at the top of the stack, since it
        # needs to run first.
        hot.middleware,
        HTTP.Sockets.localhost,
        8080;
    )
    custom_watcher_function() do event
        # Do something with the event.
        # ...

        # Then trigger a `refresh` function.
        hot.refresh()
    end
end
```
"""
HotReloader() = _hot_reloader_middleware(HotReloaderDispatchType())

function _hot_reloader_middleware(::Any)
    @info "Hot reloading disabled"
    function refresh()
        error("refreshing a non-development server is not supported.")
    end
    function middleware(handler)
        function (req)
            return handler(req)
        end
    end
    return (; server = nothing, middleware, refresh)
end

function __init__()
    PackageExtensionCompat.@require_extensions
end

end # module ReloadableMiddleware
