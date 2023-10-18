module ReloadableMiddlewareReviseExt

import BundledWebResources
import HTTP
import ReloadableMiddleware
import Revise

# Module router reloading.

function ReloadableMiddleware._handle_router_call(
    mr::ReloadableMiddleware.ModuleRouter,
    req::HTTP.Request,
)
    changed, mtimes = _updated_mtimes(mr.mtimes, mr.mods)
    if changed
        @debug "updating stored mtimes"
        empty!(mr.mtimes)
        merge!(mr.mtimes, mtimes)

        @debug "rebuilding router"
        mr.router = Base.invokelatest(ReloadableMiddleware._build_router, mr.base, mr.mods)
    end
    return Base.invokelatest(ReloadableMiddleware._router_call, mr, req)
end

function _updated_mtimes(current::Dict, mods::Vector{Module})
    mtimes = Dict{String,Float64}()
    for mod in mods
        root, files = Revise.modulefiles(mod)
        for file in Set(vcat(root, files))
            mtimes[file] = mtime(file)
        end
    end
    for (file, mtime) in mtimes
        if !haskey(current, file) || current[file] != mtime
            @debug "file change detected" file new_mtime = mtime current_mtime =
                get(current, file, nothing)
            return true, mtimes
        end
    end
    return false, mtimes
end

# Hot reloader.

function ReloadableMiddleware._hot_reloader_middleware(
    ::ReloadableMiddleware.HotReloaderDispatchType,
)
    # Where the hot-reloader server will listen.
    host = HTTP.Sockets.localhost
    port, socket = HTTP.Sockets.listenany(host, rand(49152:65535))
    # Make the port more human-readable.
    port = Int(port)
    address = "http://$host:$port"

    # Keep track of all the clients that are listening for reload events.
    channels = Channel{Bool}[]

    # Trigger a reload event for all clients.
    function refresh()
        while !isempty(channels)
            put!(pop!(channels), true)
        end
    end

    function reload(stream::HTTP.Stream)
        HTTP.setheader(stream, "Access-Control-Allow-Origin" => "*")
        HTTP.setheader(stream, "Access-Control-Allow-Methods" => "GET, OPTIONS")
        HTTP.setheader(stream, "Content-Type" => "text/event-stream")

        if HTTP.method(stream.message) == "OPTIONS"
            return nothing
        else
            HTTP.setheader(stream, "Content-Type" => "text/event-stream")
            HTTP.setheader(stream, "Cache-Control" => "no-cache")

            channel = Channel{Bool}(1)
            push!(channels, channel)

            # Block until the channel gets a value pushed to it from the
            # refresh function.
            if take!(channel)
                @info "sending reload event"
                try
                    write(stream, "\ndata: reload\n\n")
                catch error
                    # Can fail if the user has reloaded their browser window
                    # manually. In that case, we just ignore the error.
                    @debug "failed to send reload event" error
                end
            end
            return nothing
        end
    end

    # Create the router that will handle requests for the reload event stream.
    router = HTTP.Router()
    HTTP.register!(router, "/", reload)

    # Close the listening socket so that we can reuse the port now.
    close(socket)

    # Start up a streaming HTTP server to handle requests for the reload event.
    # TODO: should perhaps have a safe way to close this server when not needed
    # anymore.
    server = HTTP.serve!(router, host, port; stream = true)

    # Provide the bundled idiomorph script as a resource. This is used to do
    # in-place swapping of the DOM when the page is reloaded rather than
    # performing a full-page refresh.
    idiomorph_router = BundledWebResources.ResourceRouter(Idiomorph)

    @info "Hot reloading enabled"
    function middleware(handler)
        # Ensure we intercept the request to handle requests for our bundled
        # idiomorph script.
        wrapped_handler = idiomorph_router(handler)
        return function (request)
            response = if isempty(Revise.revision_queue)
                # When there are no pending revisions, we just run the handler
                # as normal within the dynamic dispatch caused by
                # `invokelatest`.
                wrapped_handler(request)
            else
                try
                    @info "Running revise"
                    Revise.revise()
                catch error
                    @error "Revise failed to revise" error
                end
                Base.invokelatest(wrapped_handler, request)
            end
            return _insert_hot_reloader_script(response, address)
        end
    end

    return (; server, middleware, refresh)
end

# Injects the hot reloading script into the HTML response. Uses idiomorph to
# morph the DOM after fetching the new HTML for the current page. A server sent
# event is used to trigger the reload.
function _insert_hot_reloader_script(response::HTTP.Response, address::AbstractString)
    if !isnothing(findfirst((==)("Content-Type" => "text/html"), response.headers))
        tags = "</head>"
        script = """
        <script src="$(pathof(Idiomorph.idiomorph()))"></script>
        <script>
        const evtSource = new EventSource("$address");
        evtSource.onmessage = async function (event) {
            if (event.data === "reload") {
                const response = await fetch(location.pathname);
                const text = await response.text();
                Idiomorph.morph(document.documentElement, text);
            };
        };
        </script>
        $tags
        """
        response.body = codeunits(replace(String(response.body), tags => script))
    end
    return response
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

end
