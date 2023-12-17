module ReloadableMiddlewareReviseExt

import Base.Docs
import BundledWebResources
import HTTP
import InteractiveUtils
import ReloadableMiddleware
import RelocatableFolders
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
        mr.router = Base.invokelatest(ReloadableMiddleware._build_router, mr.base, mr.mods, mr.api)
    end
    return Base.invokelatest(ReloadableMiddleware._router_call, mr, req)
end

function _updated_mtimes(current::Dict, mods::Vector{Module})
    mtimes = Dict{String,Float64}()
    for mod in mods
        root, files = Revise.modulefiles(mod)
        root = something(root, [])
        files = something(files, [])
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

# /api routes.

module Templates

import HTTP
import HypertextTemplates: @template_str, HypertextTemplates

template"views/api.html"
template"views/components.html"

function render(template::Function, args...; kws...)
    return HTTP.Response(
        200,
        ["Content-Type" => "text/html"],
        HypertextTemplates.render(template, args...; kws...),
    )
end

end

function docs(mod::Module, handler::Function, sig::Type{R}) where {R<:ReloadableMiddleware.Req}
    meta = Docs.meta(mod)
    sig = Tuple{sig}
    binding = Docs.aliasof(handler, sig)
    if haskey(meta, binding)
        docs = meta[binding].docs
        haskey(docs, sig) && return Docs.formatdoc(docs[sig])
    end
    return nothing
end

function api_view(req, routes, api)
    content = nothing
    metadata = nothing
    title = "API Explorer"
    endpoints = []
    for route in routes
        method = route.method
        path = route.path
        handler = route.handler
        mod = route.mod
        sig = route.sig
        url = "$api/$(HTTP.URIs.escapeuri(path))/$(method)"
        current = req.target == url
        if current
            content = docs(mod, handler, sig)
            file, line = functionloc(handler, Tuple{sig})
            file = HTTP.URIs.escapeuri(file)
            param, query, form = format_sig(sig)
            metadata = (; method, path, file, line, param, query, form)
            title = "$method $path"
        end
        push!(endpoints, (; method, url, name = path, current))
    end
    return Templates.render(
        Templates.api;
        api,
        endpoints,
        content,
        metadata,
        title,
        style_css = "$api/style.css",
    )
end

function format_sig(
    ::Type{<:ReloadableMiddleware.Req{M,P,param,query,query_defaults,form,form_defaults}},
) where {M,P,param,query,query_defaults,form,form_defaults}
    fmt(::Type{NamedTuple{names,types}}) where {names,types} = [
        (; name = string(name), type = string(type)) for
        (name, type) in zip(names, types.parameters)
    ]
    return (param = fmt(param), query = fmt(query), form = fmt(form))
end

const STYLE_CSS = RelocatableFolders.@path "views/dist/output.css"

function style_css(::HTTP.Request)
    return HTTP.Response(200, ["Content-Type" => "text/css"], read(STYLE_CSS, String))
end

function open_file(req)
    params = HTTP.getparams(req)
    file = params["file"]
    line = params["line"]
    if file == "nothing"
        return HTTP.Response(404, ["Content-Type" => "text/plain"], "")
    else
        file = HTTP.URIs.unescapeuri(file)
        line = something(tryparse(Int, line), 0)
        InteractiveUtils.edit(file, line)
        return HTTP.Response(200, ["Content-Type" => "text/plain"], "")
    end
end

function ReloadableMiddleware._add_api_routes!(router::HTTP.Router, routes, api::String)
    HTTP.register!(router, "POST", "$api/open-file/{file}/{line}", open_file)
    HTTP.register!(router, "GET", "$api/style.css", style_css)
    HTTP.register!(router, "GET", "$api/{path}/{method}", (req) -> api_view(req, routes, api))
    HTTP.register!(router, "GET", api, (req) -> api_view(req, routes, api))
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
        "https://unpkg.com/idiomorph@0.2.0/dist/idiomorph.min.js";
        name = "idiomorph.js",
        sha256 = "41a8b5d47f7b5d5d9980774ce072f32eda1a0cdc9d194d90dd2fe537cd534d4a",
    )
end

end

end
