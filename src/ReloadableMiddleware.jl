module ReloadableMiddleware

# Imports.

import Dates
import HTTP
import MIMEs

# Exports.

export @target,
    ModuleRouter,
    StaticFileRouter,
    ServerStateMiddleware,
    ReviseMiddleware,
    HotReloader,
    server_state

# Module router.

function target(func)
    return (; methods = nothing, path = nothing)
end

"""
    @target methods path handler

Macro for defining a path and methods for a route. This is used by `ModuleRouter` to
automatically register routes for all functions in a module.
"""
macro target(methods, path, handler)
    quote
        function $(ReloadableMiddleware).target(::typeof($(esc(handler))))
            return (; methods = $(methods), path = $(path))
        end
    end
end

mutable struct ModuleRouter
    base::HTTP.Router
    mods::Vector{Module}
    mtimes::Dict{String,Float64}
    router::HTTP.Router

    ModuleRouter(r::HTTP.Router, mods::Vector{Module}) =
        new(r, mods, Dict(), _build_router(r, mods))
    ModuleRouter(r::HTTP.Router, mod::Module) = ModuleRouter(r, [mod])
end
(mr::ModuleRouter)(req::HTTP.Request) = _handle_router_call(mr, req)

_handle_router_call(mr, req) = _router_call(mr, req)
_router_call(mr::ModuleRouter, req::HTTP.Request) = mr.router(req)

function _build_router(base::HTTP.Router, modules::Vector{Module})
    router = HTTP.Router(base)
    for mod in modules
        for name in names(mod; all = true)
            if isdefined(mod, name) && !Base.isdeprecated(mod, name)
                handler = getfield(mod, name)
                (; methods, path) = target(handler)
                _register_route!(router, methods, path, handler)
            end
        end
    end
    return router
end

function _register_route!(router::HTTP.Router, methods, path, handler)
    HTTP.register!(router, methods, path, handler)
    return nothing
end
_register_route!(::HTTP.Router, ::Nothing, ::Nothing, ::Any) = nothing

# Server state.

_server_state_key() = :server_state

function ServerStateMiddleware(state)
    function (handler)
        function (req::HTTP.Request)
            req.context[_server_state_key()] = state
            return handler(req)
        end
    end
end

function server_state(req::HTTP.Request)
    key = _server_state_key()
    if haskey(req.context, key)
        return req.context[key]
    else
        error("server state not set")
    end
end

function StaticFileRouter(dir::AbstractString)
    function (handler)
        function (req::HTTP.Request)
            return _static_file_router_impl(handler, req, dir)
        end
    end
end

function _static_file_router_impl(handler, req::HTTP.Request, dir::AbstractString)
    uri = HTTP.URIs.URI(req.target)
    file = joinpath(dir, lstrip(uri.path, '/'))
    if isfile(file)
        mime = MIMEs.mime_from_path(file)
        content_type = MIMEs.contenttype_from_mime(mime)
        return HTTP.Response(200, ["Content-Type" => content_type], read(file, String))
    else
        return handler(req)
    end
end

# Revise middleware.

struct ReviseMiddlewareDispatchType end

"""
    ReviseMiddleware(handler) -> handler

Revise middleware. This middleware will run `Revise.revise()` before handling
the request. When no `Revise` is imported in the environment then this
middleware does nothing.

Production deployments should not import `Revise`, but can leave this
middleware in place. It will do nothing, and simply provide the same inferface
for consumption, but with no reloading effect, or associated performance cost.
"""
ReviseMiddleware(handler) = _revise_middleware(ReviseMiddlewareDispatchType(), handler)

function _revise_middleware(type, handler)
    return function (req::HTTP.Request)
        return handler(req)
    end
end

# Hot reloading with server sent events.
#
# When `Revise` is used then the hot reloader will be activated. See the
# `Revise` ext package for its implementation. The implementation below is a
# fallback for when `Revise` is not used. It does nothing, and simply
# provides the same inferface for consumption, but with no reloading effect.

struct HotReloaderDispatchType end

"""
    HotReloader(; endpoint="/events/reload") -> (; router::Function, refresh::Function, stream::Bool)

Hot reloading middleware. This middleware will reload the browser when
the `.refresh` function is called. It is a 0-arg function that will send
an event to all clients listening and cause them to refresh the page.

`.router` is a `(handler) -> handler` function that can be piped with normal
`HTTP.Router`s.

`.stream` should be passed as a keyword argument to `HTTP.serve` when using
this middleware.
"""
HotReloader(; endpoint = "/events/reload") =
    _hot_reloader_middleware(HotReloaderDispatchType(), endpoint)

function _hot_reloader_middleware(::Any, endpoint::AbstractString)
    @info "Hot reloading disabled"

    refresh() = @warn "Hot reloading is not supported in this environment"

    function router(handler)
        function (req)
            return handler(req)
        end
    end

    (; router, refresh, stream = false)
end

module Idiomorph

using BundledWebResources

function idiomorph()
    @comptime Resource(
        "https://unpkg.com/idiomorph@0.0.9/dist/idiomorph.min.js";
        name = "idiomorph.js",
        sha256 = "b9b33450f762cd8510d70e9c5bc3da74ac38127da4089c1932b5898337d7833b",
    )
end

end

end # module ReloadableMiddleware
