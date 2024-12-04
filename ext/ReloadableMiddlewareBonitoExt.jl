module ReloadableMiddlewareBonitoExt

#=
This extension provides integration with the `Bonito.jl` package so that you
can embed live `Bonito.App` objects within rendered pages that are served by
`ReloadableMiddleware.Router` and let the server handle the Bonito-specific
communication and asset handling instead of having a separate server usually
handles it for plain-`Bonito`.

The user-inferface for this extension is simply to add a middleware to their
`dev` and `prod` server calls. This middleware is called `bonito_middleware`.

```julia
import Bonito

function prod()
    ReloadableMiddleware.Server.prod(
        middleware = [ReloadableMiddleware.Extensions.bonito_middleware()],
        # ...
    )
end
```

Note that `Bonito` must be loaded into your server process otherwise
`bonito_middleware()` will throw an error. Ideally ensure that you manually do
the `import` rather than assuming that some 3rd-party package is doing it for
you.

Then in any of your views create `Bonito.App` objects and embed them directly
into the rendered HTML. The simplest approach is with `HypertextTemplates.jl`
since that includes an integration that will automatically render the objects
that are interpolated into any element macros.

```julia
function view()
    app = App() do session
        # ...
    end
    return @render @div {class = "flex justify-content"} $app
end
```

Connections will automatically get cleaned up when the WebSocket is closed,
hence there is no manual management required by the user.
=#

#
# Imports:
#

import Bonito
import HTTP
import ReloadableMiddleware

#
# Abstract types:
#

abstract type AbstractBonitoContext end

#
# Bonito asset serving:
#

struct BonitoAssetServer <: Bonito.AbstractAssetServer
    endpoint::String
    files::Dict{String,Bonito.AbstractAsset}
    lock::ReentrantLock

    function BonitoAssetServer(endpoint::String)
        endpoint = "$endpoint/assets/"
        return new(endpoint, Dict{String,Bonito.AbstractAsset}(), ReentrantLock())
    end
end

function Bonito.url(s::BonitoAssetServer, asset::Bonito.AbstractAsset)
    if Bonito.is_online(asset)
        return Bonito.online_path(asset)
    else
        key = Bonito.unique_file_key(asset)
        url = "$(s.endpoint)$(key)"
        lock(s.lock) do
            @debug "registering bonito asset" url
            s.files[url] = asset
        end
        return url
    end
end

Bonito.setup_asset_server(::BonitoAssetServer) = nothing

function _bonito_assets_handler(request::HTTP.Request, context::AbstractBonitoContext)
    files = context.assets.files
    if haskey(files, request.target)
        @debug "found bonito asset" target = request.target
        return _asset_response(files[request.target])
    else
        return HTTP.Response(404)
    end
end

function _asset_response(asset::Bonito.BinaryAsset)
    body = asset.data
    return HTTP.Response(
        200,
        [
            # TODO: maybe add some cache control headers.
            "Content-Type" => "application/octet-stream",
            "Content-Length" => "$(sizeof(body))",
        ];
        body,
    )
end
function _asset_response(asset::Bonito.Asset)
    filepath = Bonito.local_path(asset)
    body = read(filepath)
    return HTTP.Response(
        200,
        [
            # TODO: maybe add some cache control headers.
            "Content-Type" => Bonito.file_mimetype(filepath),
            "Content-Length" => "$(sizeof(body))",
        ];
        body,
    )
end

#
# WebSocket connection:
#

mutable struct WebSocketConnection{T<:AbstractBonitoContext} <: Bonito.FrontendConnection
    context::T
    endpoint::String
    session::Union{Bonito.Session,Nothing}
    handler::Bonito.WebSocketHandler
end

struct BonitoContext <: AbstractBonitoContext
    assets::BonitoAssetServer
    endpoint::String
    cleanup_policy::Bonito.CleanupPolicy
    cleanup_timer::Timer
    open_connections::Dict{String,WebSocketConnection{BonitoContext}}
    lock::ReentrantLock

    function BonitoContext(
        assets::BonitoAssetServer,
        prefix::String;
        cleanup_policy::Bonito.CleanupPolicy = Bonito.DefaultCleanupPolicy(),
        cleanup_interval::Integer = 5,
    )
        endpoint = "$prefix/websocket/"
        lock = ReentrantLock()
        open_connections = Dict{String,WebSocketConnection{BonitoContext}}()
        cleanup_timer = Timer(cleanup_interval; interval = cleanup_interval) do timer
            try
                cleanup_bonito(lock, open_connections, cleanup_policy)
            catch error
                @error "failed to run bonito cleanup" exception = (error, catch_backtrace())
            end
        end
        return new(assets, endpoint, cleanup_policy, cleanup_timer, open_connections, lock)
    end
end

Base.isopen(ws::WebSocketConnection{BonitoContext}) = Base.isopen(ws.handler)
Base.write(ws::WebSocketConnection{BonitoContext}, binary) = Base.write(ws.handler, binary)
Base.close(ws::WebSocketConnection{BonitoContext}) = Base.close(ws.handler)

function Bonito.setup_connection(session::Bonito.Session{WebSocketConnection{BonitoContext}})
    @debug "setting up bonito connection" id = session.id
    connection = session.connection
    connection.session = session
    context = connection.context
    lock(context.lock) do
        context.open_connections[session.id] = connection
    end
    return Bonito.setup_websocket_connection_js(connection.endpoint, session)
end

function _bonito_websocket_handler(
    websocket::HTTP.WebSockets.WebSocket,
    session_id::String,
    context::BonitoContext,
)
    connection = lock(context.lock) do
        get(context.open_connections, session_id, nothing)
    end

    if isnothing(connection)
        @debug "bonito connection for session does not exist" id = session_id
        close(websocket)
    else
        session = connection.session
        handler = connection.handler
        try
            @debug "bonito websocket connection started" id = session_id
            Bonito.run_connection_loop(session, handler, websocket)
        finally
            @debug "bonito websocket connection ended" id = session_id
            if Bonito.allow_soft_close(context.cleanup_policy)
                Bonito.soft_close(session)
            else
                close(session)
                lock(context.lock) do
                    delete!(context.open_connections, session_id)
                end
            end
        end
    end

    return nothing
end

#
# Middleware provider:
#

function ReloadableMiddleware.Extensions._bonito_middleware(::Nothing, prefix::String)
    assets = BonitoAssetServer(prefix)
    context = BonitoContext(assets, prefix)
    Bonito.register_connection!(WebSocketConnection{BonitoContext}) do
        return WebSocketConnection{BonitoContext}(
            context,
            context.endpoint,
            nothing,
            Bonito.WebSocketHandler(),
        )
    end
    Bonito.register_asset_server!(BonitoAssetServer) do
        return assets
    end
    function (handler)
        function (stream)
            if _is_bonito(stream, prefix)
                return _handle_bonito_request(stream, context)
            else
                return handler(stream)
            end
        end
    end
end

_is_bonito(req::HTTP.Request, prefix::String) = startswith(req.target, prefix)
_is_bonito(stream::HTTP.Stream, prefix::String) = _is_bonito(stream.request, prefix)

function _handle_bonito_request(request::HTTP.Request, context::BonitoContext)
    target = request.target
    if startswith(target, context.endpoint)
        WS = HTTP.WebSockets
        if WS.isupgrade(request)
            stream = request.context[:stream]::HTTP.Stream
            WS.upgrade(stream) do ws
                session_id = String(strip(replace(target, context.endpoint => "")))
                _bonito_websocket_handler(ws, session_id, context)
            end
        end
        return request.response
    elseif startswith(target, context.assets.endpoint) && request.method == "GET"
        return _bonito_assets_handler(request, context)
    else
        @error "unknown route in bonito request handler" target
        return HTTP.Response(404)
    end
end

#
# Cleanup:
#

function cleanup_bonito(
    reentrant_lock::ReentrantLock,
    open_connections::Dict{String,WebSocketConnection{BonitoContext}},
    cleanup_policy::Bonito.CleanupPolicy,
)
    lock(reentrant_lock) do
        remove = Set{WebSocketConnection{BonitoContext}}()
        for connection in values(open_connections)
            if Bonito.should_cleanup(cleanup_policy, connection.session)
                @debug "attempting to clean up connection" id = connection.session.id
                push!(remove, connection)
            end
        end
        for connection in remove
            session = connection.session
            if !isnothing(session)
                delete!(open_connections, session.id)
                close(session)
                @debug "cleaned up connection" id = session.id
            end
        end
    end
end

end
