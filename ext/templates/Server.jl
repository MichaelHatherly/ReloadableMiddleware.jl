module Server

import ..Resources
import ..Routes
import ..Templates

import HTTP
import ReloadableMiddleware
import TailwindCSS
import HypertextTemplates
import BundledWebResources

function serve(; port::Int = 8080)
    state = Dict()

    hot = ReloadableMiddleware.HotReloader()

    server = HTTP.serve!(
        ReloadableMiddleware.ModuleRouter(Routes) |>
        ReloadableMiddleware.ServerStateProvider(state) |>
        BundledWebResources.ResourceRouter(Resources) |>
        HypertextTemplates.TemplateFileLookup |>
        hot.middleware,
        HTTP.Sockets.localhost,
        port;
    )

    watcher = TailwindCSS.watch(;
        root = dirname(@__DIR__),
        input = joinpath(@__DIR__, "..", "input.css"),
        output = joinpath(@__DIR__, "..", "Resources", "dist", "output.css"),
        after_rebuild = hot.refresh,
    )

    return (; server, watcher, state)
end

end
