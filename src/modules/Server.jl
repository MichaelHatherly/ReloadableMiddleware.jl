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
    function (handle)
        function (request::HTTP.Request)
            request.context[:ip] = ip
            request.context[:stream] = stream
            return handle(request)
        end
    end
end

function stream_handler(middleware)
    function (stream)
        ip, _ = Sockets.getpeername(stream)
        handle_stream = HTTP.streamhandler(middleware |> decorate_request(; ip, stream))
        try
            return handle_stream(stream)
        catch error
            return _intercept_epipe_error(error)
        end
    end
end

# Intermittant broken pipe errors seem to show up every now and then due to
# currently unknown reasons. They appear benign so we ignore them here.
function _intercept_epipe_error(error::Base.IOError)
    if error.msg == "write: broken pipe (EPIPE)" && error.code == -32
        @debug "caught 'broken pipe' error, ignoring." error
        return nothing
    else
        rethrow(error)
    end
end
_intercept_epipe_error(error) = rethrow(error)

function filter_changes(includes)
    function (changes)
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
    print(io, ")")
end

function Base.close(server::DevServer)
    HTTP.forceclose(server.http_server)
    close(server.folder_watcher)
    return nothing
end

server_url(http_server) = "http://$(http_server.listener.hostname):$(http_server.listener.hostport)"

logging_format() = HTTP.logfmt"$time_iso8601 - $remote_addr:$remote_port - \"$request\" $status"

"""
    dev(; router_modules, middleware, watch_file_types, docs, errors, kwargs...)

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
"""
function dev(;
    router_modules = [],
    middleware = [],
    watch_file_types = (".jl",),
    docs = "/docs/",
    errors = "/errors/",
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
    handler = stream_handler(reduce(|>, reverse(middleware)))

    http_server = HTTP.serve!(handler; access_log = logging_format(), kwargs..., stream = true)

    # Once the server is running check that the route works, and then open the
    # browser at that URL.
    url = server_url(http_server)
    HTTP.get(url)
    Browser.browser(url)

    return DevServer(http_server, reloader.watcher, docs)
end

"""
    prod(; port = 8080, router_modules = [], middleware = [], kwargs...)

Start up a production server. No code revision, auto-reload, or template lookup
is enabled for this server, unlike the `dev` server. This function blocks until
the server is closed.
"""
function prod(; port = 8080, router_modules = [], middleware = [], kwargs...)
    router, _, _ = Router.routes(router_modules)
    middleware = [middleware..., router]
    handler = stream_handler(reduce(|>, reverse(middleware)))
    HTTP.serve(handler, port; access_log = logging_format(), kwargs..., stream = true)
end

end
