module Server

#
# Imports:
#

import ..Reviser
import ..Reloader
import ..Router
import ..Responses
import ..Watcher
import ..Browser
import ..Errors
import ..Docs

import Dates
import HTTP
import HypertextTemplates
import Sockets

#
# Exports:
#

export dev
export prod

#
# Stream request middleware:
#

# From Oxygen.jl.
function decorate_request(; ip, stream)
    return function (handle)
        return function (request::HTTP.Request)
            request.context[:ip] = ip
            request.context[:stream] = stream
            return handle(request)
        end
    end
end

"""
    stream_handler(middleware; access_log = access_log_line)

Wrap a request middleware stack as an `HTTP.Stream` handler. `access_log`
formats one log line per request from `(stream, peer, status)`; pass
`nothing` to log none.
"""
function stream_handler(middleware; access_log = access_log_line)
    return function (stream)
        peer = HTTP.peeraddr(stream)
        ip = peer_ip(peer)
        handle_stream = HTTP.streamhandler(middleware |> decorate_request(; ip, stream))
        # An exception that escapes makes the server answer 500 on its own,
        # after this function returns.
        status = 500
        try
            handle_stream(stream)
            status = stream.response.status
        catch error
            _intercept_disconnect(error)
            status = stream.response.status
        finally
            log_access(access_log, stream, peer, status)
        end
        return nothing
    end
end

peer_ip(::Nothing) = nothing
function peer_ip(peer)
    octets = peer.ip
    length(octets) == 4 && return Sockets.IPv4(octets...)
    return Sockets.IPv6(foldl((n, b) -> n << 8 | b, octets; init = UInt128(0)))
end

log_access(::Nothing, stream, peer, status) = nothing
function log_access(format, stream, peer, status)
    @info format(stream, peer, status) _group = :access
    return nothing
end

function access_log_line(stream, peer, status)
    request = stream.message
    time = Dates.format(Dates.now(), Dates.dateformat"yyyy-mm-dd\THH:MM:SS")
    protocol = "HTTP/$(request.proto_major).$(request.proto_minor)"
    return "$time - $peer - \"$(request.method) $(request.target) $protocol\" $status"
end

# A client that disconnects while its response is still being written
# surfaces as a broken pipe or a reset on the write. Nobody is left to tell.
# On Windows the errnum is the Winsock code: WSAECONNABORTED, WSAECONNRESET,
# WSAESHUTDOWN.
const DISCONNECT_ERRNOS = Sys.iswindows() ?
    (Libc.EPIPE, Libc.ECONNRESET, 10053, 10054, 10058) :
    (Libc.EPIPE, Libc.ECONNRESET)

function _intercept_disconnect(error::SystemError)
    if error.prefix == "write" && error.errnum in DISCONNECT_ERRNOS
        @debug "client disconnected before the response completed, ignoring." error
        return nothing
    else
        rethrow(error)
    end
end
# Reseau reports a zero-byte write as EOF.
function _intercept_disconnect(error::EOFError)
    @debug "client disconnected before the response completed, ignoring." error
    return nothing
end
_intercept_disconnect(error) = rethrow(error)

function filter_changes(includes)
    return function (changes)
        changes = filter(changes) do change
            _, ext = splitext(change.path)
            return ext in includes
        end
        return changes
    end
end

struct DevServer
    http_server::HTTP.Server
    folder_watcher::Watcher.FolderWatcher
    docs::String
end

function Base.show(io::IO, dev::DevServer)
    url = server_url(dev.http_server)
    println(io, "$DevServer(")
    println(io, "  url = $url,")
    println(io, "  docs = $(url)$(dev.docs),")
    return print(io, ")")
end

function Base.close(server::DevServer)
    HTTP.forceclose(server.http_server)
    close(server.folder_watcher)
    return nothing
end

server_url(http_server) = "http://127.0.0.1:$(HTTP.port(http_server))"

"""
    dev(; port = 8080, router_modules, middleware, watch_file_types, docs, errors, access_log, kwargs...)

Start up a development server. Code revision via `Revise` integration is
enabled if that package is loaded. The provided router modules reflect changes
to router structure on code revisions. When file types in the provided
`watch_file_types` change then automatic browser reloading occurs, which
hot-swaps the current DOM with the updated DOM for the current URL. If using
the `HypertextTemplates` package for view templates then source code lookup is
enabled via mouse hover and `Ctrl+1` (for router location) and `Ctrl+2` (for
template location).

Returns a server `Task` and the file watcher object and runs the server in the
background so that the REPL can be used to inspect server state.

This function automatically tries to open your web browser to the server
address once it has started the server. If you are on macOS and your browser is
a Chromium-based one then if a tab is already open at the correct URL then it
will reload that tab, otherwise it will open a new browser tab.

The `docs` route provides an overview of all available routes defined within
the application.

The `errors` route provides an overview of all thrown errors and their
stacktraces. Errors can be inspected within the details view of each error.
Source links will navigate your editor to the specific file and line of the
stacktrace.

`access_log` formats the line logged for each request, see
[`stream_handler`](@ref). Pass `nothing` to silence the log. Remaining
`kwargs` go to `HTTP.listen!`.
"""
function dev(;
        port = 8080,
        router_modules = [],
        middleware = [],
        watch_file_types = (".jl",),
        docs = "/docs/",
        errors = "/errors/",
        access_log = access_log_line,
        kwargs...,
    )
    router = Router.router_reloader_middleware(vcat(router_modules))
    reloader = Reloader.ReloaderMiddleware(filter_changes(watch_file_types))
    middleware = [
        Reviser.ReviseMiddleware,
        reloader.middleware,
        HypertextTemplates.TemplateFileLookup,
        Errors.error_reporting_middleware(errors),
        middleware...,
        Docs.middleware(router_modules, docs),
        router,
    ]
    handler = stream_handler(reduce(|>, reverse(middleware)); access_log)

    http_server = HTTP.listen!(handler, port; kwargs...)

    # Once the server is running check that the route works, and then open the
    # browser at that URL.
    url = server_url(http_server)
    HTTP.get(url)
    Browser.browser(url)

    return DevServer(http_server, reloader.watcher, docs)
end

"""
    prod(; port = 8080, router_modules = [], middleware = [], access_log, kwargs...)

Start up a production server. No code revision, auto-reload, or template lookup
is enabled for this server, unlike the `dev` server. This function blocks until
the server is closed. `access_log` is as for [`dev`](@ref).
"""
function prod(; port = 8080, router_modules = [], middleware = [], access_log = access_log_line, kwargs...)
    router, _, _ = Router.routes(router_modules)
    middleware = [middleware..., router]
    handler = stream_handler(reduce(|>, reverse(middleware)); access_log)
    return HTTP.listen(handler, port; kwargs...)
end

end
