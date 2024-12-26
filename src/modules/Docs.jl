module Docs

import ..Router
import ..Responses

import HTTP
import URIs

#
# Utilities:
#

route_key() = Symbol("##route##")
mods_key() = Symbol("##mods##")

#
# Resources:
#

module Resources

using BundledWebResources
using RelocatableFolders

@register function htmx()
    return Resource(
        "https://cdnjs.cloudflare.com/ajax/libs/htmx/2.0.3/htmx.min.js";
        sha256 = "491955cd1810747d7d7b9ccb936400afb760e06d25d53e4572b64b6563b2784e",
    )
end

@register function hljs_theme_css()
    return Resource(
        "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.10.0/styles/github-dark.min.css";
        sha256 = "9f208d022102b1d0c7aebfecd8e42ca7997d5de636649d2b31ea63093d809019",
    )
end

@register function hljs_js()
    return Resource(
        "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.10.0/highlight.min.js";
        sha256 = "471ef9ae90c407af440fcdc48edfeeb562106b3267bd12d99071c162fb52ed32",
    )
end

@register function hljs_julia_js()
    return Resource(
        "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.10.0/languages/julia.min.js";
        sha256 = "cbe9b739d37bc4e40ed7d9634a2a0f3d786576059eb95d373168ada9ca29ee34",
    )
end

const DIST = @path joinpath(@__DIR__, "dist")

@register function output_css()
    # Build with `tailwind --input input.css --output dist/output.css --watch`.
    return LocalResource(DIST, "output.css")
end

end

#
# Templates:
#

module Templates

import ..Resources

import HTTP
import URIs

using HypertextTemplates
using HypertextTemplates.Elements

@component function favicon(; text)
    @link {
        rel = "icon",
        href = SafeString(
            "data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>$text</text></svg>",
        ),
    }
end
@deftag macro favicon end

@component function header(; prefix, title = "API Docs")
    @head begin
        @title @text title
        @meta {charset = "UTF-8"}
        @meta {name = "viewport", content = "width=device-width, initial-scale=1.0"}
        @script {src = "$prefix$(pathof(Resources.htmx()))"}
        @link {href = "$prefix$(pathof(Resources.output_css()))", rel = "stylesheet"}
        @link {rel = "stylesheet", href = "$prefix$(pathof(Resources.hljs_theme_css()))"}
        # The colour scheme has a slightly different background colour compared
        # to the background provided by tailwind prose extension. So we hide
        # the HLJS one. Remove the added padding as well, since TW provides
        # some already.
        @style """
        pre code.hljs { padding: 0; }
        .hljs { background: transparent; }
        """
        @script {src = "$prefix$(pathof(Resources.hljs_js()))"}
        # Most other useful languages are included in the default bundle above,
        # we just need to add the Julia one manually.
        @script {src = "$prefix$(pathof(Resources.hljs_julia_js()))"}
        @favicon {text = "📚"}
    end
end
@deftag macro header end

@component function layout(; prefix, info, title)
    return @html begin
        @header {prefix, title}
        @body {class = "grid grid-cols-[max-content,1fr] gap-2 min-h-screen", "hx-boost" := "true"} begin
            @div {class = "p-2 bg-gray-100/50 border-r h-full"} begin
                @h1 {class = "text-center"} @a {
                    href = "$prefix/",
                    class = "py-2 text-xl font-bold text-blue-600/90 hover:text-blue-800",
                } "API Docs"
                @table begin
                    @tbody begin
                        for (mod, method, path, handler) in info
                            name = URIs.escapeuri(nameof(handler))
                            @tr {class = "m-2"} begin
                                @td @code {
                                    class = "p-1 bg-gray-200 text-xs font-bold rounded border",
                                } "$method"
                                @td @a {
                                    href = "$prefix/$mod/$name",
                                    class = "text-blue-600 hover:underline",
                                } begin
                                    @code {class = "p-1 text-xs"} "$path"
                                end
                            end
                        end
                    end
                end
            end
            @div {class = "m-2"} begin
                @__slot__
            end
        end
    end
end
@deftag macro layout end

@component function docs(; prefix, info)
    @layout {prefix, info, title = "API Docs"} begin
        @div {class = "prose"} begin
            @h1 "API Documetation"
            @p """
            All available routes are listed in the left panel. Click to
            navigate to the details view of each route. When making edits to
            the documentation and specification of routes the details page
            should live reload to show the most recent changes.
            """
            @p """
            The generated documentation for each route includes the method,
            path, path parameters, query parameters, body type, source
            location, and complete docstring.
            """
            @p """
            Clicking the source code location link will navigate your default
            editor to that particular line in the same way as stacktrace links
            generated by the exception interceptor does.
            """
        end
    end
end
@deftag macro docs end

@component function doc(;
    data_href,
    docs,
    handler_path,
    info,
    method,
    prefix,
    source_path,
    template_lookup,
    types,
)
    @layout {prefix, info, title = "$method $handler_path"} begin
        @div begin
            @code {class = "px-2 py-1 text-sm font-bold border rounded bg-gray-200"} @text method
            @code {class = "p-1 text-sm"} @text handler_path
        end
        @div {class = "py-2 prose"} begin
            @div {class = "border-b py-1"} begin
                @a {
                    title = "Source code location",
                    class = "text-blue-600 text-sm",
                    href = "#",
                    "data-href" := data_href,
                } begin
                    @text source_path
                end
            end
            if !isempty(types)
                @pre {class = "my-2"} begin
                    @code {class = "language-julia"} for type in types
                        @text type
                    end
                end
            end
            @text SafeString(docs)
        end
        @script @text SafeString("""
        window.addEventListener("ReloadableMiddleware:HotReload", (event) => {
            hljs.highlightAll();
        });
        (function () {
            hljs.highlightAll();
            const elements = document.querySelectorAll('[data-href]');
            elements.forEach(element => {
                element.addEventListener('click', () => {
                    const href = element.getAttribute('data-href');
                    fetch("$(template_lookup)", { method: "POST", body: href });
                });
            });
        })();
        """)
    end
end
@deftag macro doc end

end

#
# Routes:
#

module Routes

using ...Router

import ..Resources
import ..Docs
import ..Templates

using BundledWebResources

import HTTP
import HypertextTemplates
import URIs

@GET "/" function (req::HTTP.Request)
    mods = req.context[Docs.mods_key()]
    route = req.context[Docs.route_key()]
    prefix = rstrip(route, '/')
    info = Router.routes_info(mods)
    return HypertextTemplates.@render Templates.@docs {info, prefix}
end

@GET "/{mod}/{handler}" function (
    req::HTTP.Request;
    path::@NamedTuple{mod::String, handler::String},
)
    mods = req.context[Docs.mods_key()]
    mod = nothing
    for each in mods
        if path.mod == "$each"
            mod = each
            break
        end
    end
    isnothing(mod) && error("could not find correct module.")

    request_handler = getfield(mod, Symbol(URIs.unescapeuri(path.handler)))
    file, line = first(sort(functionloc.(methods(request_handler)); by = last))
    handler_type = getfield(mod, Router.handler_type()){nameof(request_handler)}()

    types = String[]
    for (name, type) in (
        ("path", Router.handler_path_type(handler_type)),
        ("query", Router.handler_query_type(handler_type)),
        ("body", Router.handler_body_type(handler_type)),
    )
        if !isnothing(type)
            str = replace(string(type), "$(Router)." => "")
            push!(types, "$name = $str\n")
        end
    end

    prefix_fn = Router.module_prefix(mod)
    prefix = prefix_fn()

    return HypertextTemplates.@render Templates.@doc({
        data_href = "$(file):$(line)",
        docs = sprint(show, "text/html", Base.Docs.doc(request_handler)),
        handler_path = string(prefix, Router.handler_path(handler_type)),
        info = Router.routes_info(mods),
        method = Router.method_string(Router.handler_method(handler_type)),
        prefix = rstrip(req.context[Docs.route_key()], '/'),
        source_path = "$(replace(file, homedir() => "~")):$(line)",
        template_lookup = req.context[:template_lookup],
        types,
    })
end

@GET "/static/**" function (req::HTTP.Request)
    @ResourceEndpoint(Resources, req)
end

end

#
# Middleware handler:
#

"""
Provides API docs for all router modules that the user has defined.
"""
function middleware(mods::Vector{Module}, route::String)
    startswith(route, "/") || error("docs route must start with a `/`.")
    endswith(route, "/") || error("docs route must end with a `/`.")
    router = Router.router_reloader_middleware([Routes])
    function (handler)
        function (request)
            return docs_handler(handler, request, router, route, mods)
        end
    end
end

# Extracted from the above function so that it is Revisable.
function docs_handler(
    handler,
    request::HTTP.Request,
    docs_router::Function,
    route::String,
    mods::Vector{Module},
)
    uri = URIs.URI(request.target)
    if startswith(uri.path, route)
        original_target = request.target
        _, rest = split(request.target, route; limit = 2)
        request.target = startswith(rest, "/") ? rest : "/$rest"
        request.context[mods_key()] = mods
        request.context[route_key()] = route
        response = docs_router(request)
        request.target = original_target
        return response
    else
        return handler(request)
    end
end

end
