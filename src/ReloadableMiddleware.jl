module ReloadableMiddleware

# Imports.

import Dates
import HTTP
import MIMEs
import URIs

# Exports.

export @req, ModuleRouter, ServerStateProvider, HotReloader, server_state

# Module router.

struct Opt{T} end

struct Req{Method,Path,Params,Query,Form}
    request::HTTP.Request
    params::Params
    query::Query
    form::Form
end

function _Req(
    method::String,
    path::String;
    params = @NamedTuple{},
    query = @NamedTuple{},
    form = @NamedTuple{}
)
    method in ("*", "GET", "POST", "PUT", "DELETE", "PATCH") || error("invalid HTTP method")
    return Req{Symbol(method),Symbol(path),params,query,form}
end

macro req(method, path, kws...)
    method = String(method)
    path, params = _parse_path(path)
    kws = [Expr(:kw, arg.args[1], :(@NamedTuple{$(arg.args[2].args...)})) for arg in kws]
    return esc(:($(ReloadableMiddleware)._Req($(method), $(path); $(params), $(kws...))))
end

function _parse_path(p::Expr)
    if Meta.isexpr(p, :string)
        params = []
        parts = map(p.args) do arg
            if isa(arg, String)
                arg
            else
                if Meta.isexpr(arg, :(::))
                    push!(params, arg)
                    "{$(arg.args[1])}"
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

struct ReqBuilder{R,F} <: Function
    handler::F
end

function (::ReqBuilder{Req{Method,Path,Params,Query,Form}})(
    req::HTTP.Request,
) where {Method,Path,Params,Query,Form}
    params = _build_params(Params, req)
    query = _build_query(Query, req)
    form = _build_form(Form, req)
    return Req{Method,Path,Params,Query,Form}(req, params, query, form)
end

type_tuple_to_tuple(::Type{Tuple{}}) = ()
type_tuple_to_tuple(T::Type{<:Tuple}) =
    (Base.tuple_type_head(T), type_tuple_to_tuple(Base.tuple_type_tail(T))...)

_parse(::Type{String}, value::String) = value
_parse(::Type{T}, value::String) where {T} = Base.parse(T, value)

function _parse_kv_or_error(
    req::HTTP.Request,
    dict::Dict{String,String},
    key::Symbol,
    T::Type,
    keys,
)
    key = String(key)
    if haskey(dict, key)
        value = dict[key]
        return _parse(T, value)::T
    else
        error("missing key '$key' in $(req)")
    end
end

function _build_params(::Type{NamedTuple{K,T}}, req::HTTP.Request)::NamedTuple{K,T} where {K,T}
    return _build_nt(K, T, req, HTTP.getparams(req))
end
_build_params(::Type{@NamedTuple{}}, ::HTTP.Request) = (;)

function _build_query(::Type{NamedTuple{K,T}}, req::HTTP.Request)::NamedTuple{K,T} where {K,T}
    return _build_nt(K, T, req, URIs.queryparams(URIs.URI(req.target)))
end
_build_query(::Type{@NamedTuple{}}, ::HTTP.Request) = (;)

function _build_form(::Type{NamedTuple{K,T}}, req::HTTP.Request)::NamedTuple{K,T} where {K,T}
    # TODO: make this less hacky. Support JSON-encoded form data too.
    return _build_nt(K, T, req, URIs.queryparams(URIs.URI("/?$(String(req.body))")))
end
_build_form(::Type{@NamedTuple{}}, ::HTTP.Request) = (;)

function _build_nt(K, T, req, dict)
    ts = type_tuple_to_tuple(T)
    return NamedTuple{K,T}((_parse_kv_or_error(req, dict, k, t, K) for (k, t) in zip(K, ts)))
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
                            Base.tuple_type_head(Base.tuple_type_tail(m.sig)),
                        )
                    end
                end
            end
        end
    end
    return router
end

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
