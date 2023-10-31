module ReloadableMiddleware

# Imports.

import Dates
import HTTP
import JSON3
import MIMEs
import MacroTools
import URIs

# Exports.

export @req, ModuleRouter, ServerStateProvider, HotReloader, server_state

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
_parse(::Type{T}, value::String) where {T} = Base.parse(T, value)

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
    if _header_contains(req, "Content-Type" => "application/json")
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

function _queryparams(pairs::Vector{Pair{String,String}})
    dict = Dict{String,Vector{String}}()
    for (key, value) in pairs
        push!(get!(Vector{String}, dict, key), value)
    end
    return dict
end
_queryparams(s::String) = _queryparams(URIs.queryparampairs(s))
_queryparams(uri::URIs.URI) = _queryparams(URIs.queryparampairs(uri))

function _header_contains(req::HTTP.Request, (key, value)::Pair)
    for (k, v) in req.headers
        if k == key
            return v == value
        end
    end
    return false
end

"""
    ModuleRouter(mod::Module)
    ModuleRouter(mods::Vector{Module})

A router that automatically registers all functions in a module as routes if
they have a `@target` annotation. When `Revise` is loaded then the router will
be automatically updated when anything in the module changes, such as new
routes, or removed routes.
"""
mutable struct ModuleRouter
    base::HTTP.Router
    mods::Vector{Module}
    mtimes::Dict{String,Float64}
    router::HTTP.Router

    function ModuleRouter(mods::Vector{Module})
        r = HTTP.Router()
        return new(r, mods, Dict(), _build_router(r, mods))
    end
    ModuleRouter(mod::Module) = ModuleRouter([mod])
end
(mr::ModuleRouter)(req::HTTP.Request) = _handle_router_call(mr, req)

_handle_router_call(mr, req) = _router_call(mr, req)
_router_call(mr::ModuleRouter, req::HTTP.Request) = mr.router(req)

function _build_router(base::HTTP.Router, modules::Vector{Module})
    router = HTTP.Router(base)
    for mod in modules
        for name in names(mod; all = true)
            if isdefined(mod, name) && !Base.isdeprecated(mod, name)
                object = getfield(mod, name)
                if isa(object, Function)
                    for m in methods(object, mod)
                        _register_route!(
                            router,
                            object,
                            _tuple_type_head(Base.tuple_type_tail(m.sig)),
                        )
                    end
                end
            end
        end
    end
    return router
end

_tuple_type_head(::Type{Tuple{}}) = nothing
_tuple_type_head(T::Type{<:Tuple}) = fieldtype(T, 1)

function _register_route!(
    router::HTTP.Router,
    handler::F,
    REQ::Type{<:Req{Method,Path}},
) where {F<:Function,Method,Path}
    HTTP.register!(router, String(Method), String(Path), ReqBuilder{REQ,F}(handler))
    return nothing
end
_register_route!(::HTTP.Router, ::Function, other) = nothing

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

end # module ReloadableMiddleware
