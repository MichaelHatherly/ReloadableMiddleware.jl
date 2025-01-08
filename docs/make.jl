using Documenter
using ReloadableMiddleware

makedocs(
    sitename = "ReloadableMiddleware",
    format = Documenter.HTML(),
    modules = [ReloadableMiddleware],
    pages = [
        "index.md",
        "server.md",
        "router.md",
        "responses.md",
        "context.md",
        "extensions.md",
        "internals.md",
    ],
)

deploydocs(repo = "github.com/MichaelHatherly/ReloadableMiddleware.jl.git", push_preview = true)
