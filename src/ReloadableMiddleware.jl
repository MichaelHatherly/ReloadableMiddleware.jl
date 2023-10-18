module ReloadableMiddleware

# Imports.

import Dates
import HTTP
import MIMEs

# Exports.

export @target, ModuleRouter, ServerStateMiddleware, HotReloader, server_state

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

# Hot reloading with server sent events and Revise.

struct HotReloaderDispatchType end

"""
    HotReloader() -> (; refresh, middleware)

Define middleware to hot-reload webpages during local development. When
`Revise` is not loaded then this middleware does nothing. `refresh` is a
zero-argument function that triggers a reload event for all clients.
`middleware` is the middleware function that should be added to the server.
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
    return (; middleware, refresh)
end

end # module ReloadableMiddleware
