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

# Revise middleware.

function ReloadableMiddleware._revise_middleware(
    ::ReloadableMiddleware.ReviseMiddlewareDispatchType,
    handler,
)
    return function (req::HTTP.Request)
        if !isempty(Revise.revision_queue)
            try
                @debug "Running revise"
                Revise.revise()
            catch error
                @error "Revise failed to revise" error
            end
        end
        return Base.invokelatest(handler, req)
    end
end

# Hot reloader.
#
# The hot reloader is a server sent event stream that triggers a reload of the
# page when `refresh()` is called. The hot reloader is injected into the
# response body of the HTML response and uses idiomorph to morph the DOM after
# fetching the new HTML for the current page.
#
# This code is not responsible for checking whether any specific files have
# changed. That should be handled separately by a file watcher task that
# then calls `refresh()` when a change is detected.

function ReloadableMiddleware._hot_reloader_middleware(
    ::ReloadableMiddleware.HotReloaderDispatchType,
    endpoint::AbstractString,
)
    @info "Hot reloading enabled"

    channels = Channel{Bool}[]

    function refresh()
        while !isempty(channels)
            channel = pop!(channels)
            put!(channel, true)
        end
    end

    idiomorph = BundledWebResources.ResourceRouter(ReloadableMiddleware.Idiomorph)

    function router(handler)
        function handle(req::HTTP.Request)
            return _hot_reload_transformer(idiomorph(handler)(req), endpoint)
        end
        function (stream::HTTP.Stream)
            target = HTTP.Messages.target(stream.message)
            if target == endpoint
                return _reload!(stream, channels)
            else
                return HTTP.streamhandler(handle)(stream)
            end
        end
    end

    (; router, refresh, stream = true)
end

function _reload!(stream::HTTP.Stream, channels::Vector{Channel{Bool}})
    HTTP.setheader(stream, "Access-Control-Allow-Origin" => "*")
    HTTP.setheader(stream, "Access-Control-Allow-Methods" => "GET, OPTIONS")
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")

    if HTTP.method(stream.message) == "OPTIONS"
        return nothing
    end

    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")

    channel = Channel{Bool}(1)
    push!(channels, channel)

    if take!(channel)
        try
            @info "sending reload event"
            write(stream, "\ndata: reload\n\n")
        catch
            # Can fail if the user has reloaded their browser window manually.
            # In that case, we just ignore the error.
        end
    end

    return nothing
end

# Injects the hot reloading script into the HTML response. Uses idiomorph to
# morph the DOM after fetching the new HTML for the current page. A server sent
# event is used to trigger the reload.
function _hot_reload_transformer(response::HTTP.Response, endpoint)
    if !isnothing(findfirst((==)("Content-Type" => "text/html"), response.headers))
        tags = "</head>"
        script = """
        <script src="$(pathof(ReloadableMiddleware.Idiomorph.idiomorph()))"></script>
        <script>
        const evtSource = new EventSource("$endpoint");
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
        1
        response.body = codeunits(replace(String(response.body), tags => script))
    end
    return response
end

end
