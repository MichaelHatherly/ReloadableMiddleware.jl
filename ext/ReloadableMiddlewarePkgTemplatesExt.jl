module ReloadableMiddlewarePkgTemplatesExt

using PkgTemplates
import PkgTemplates: Pkg, Plugin, Template, posthook, with_project, view, @plugin, @with_kw_noshow
import ReloadableMiddleware

TEMPLATES() = joinpath(@__DIR__, "templates")

function ReloadableMiddleware.Templates._create(
    ::ReloadableMiddleware.Templates.CreateTemplateDispatchType;
    dir::AbstractString = pwd(),
    interactive::Bool = true,
    pkg::Union{Nothing,AbstractString} = nothing,
    git::Bool = true,
    kws...,
)
    pkg = isnothing(pkg) ? PkgTemplates.prompt(Template, String, :pkg) : pkg
    plugins = [
        WebApp(),
        PkgTemplates.ProjectFile(),
        PkgTemplates.SrcDir(; file = joinpath(TEMPLATES(), "module.jl")),
        git ? PkgTemplates.Git() : !PkgTemplates.Git,
        PkgTemplates.Tests(; project = true),
        PkgTemplates.Formatter(),
        PkgTemplates.Codecov(),
        PkgTemplates.GitHubActions(),
        PkgTemplates.Dependabot(),
        !PkgTemplates.Readme,
        !PkgTemplates.TagBot,
    ]
    template = PkgTemplates.Template(; plugins, dir, interactive, kws...)
    return template(pkg)
end

function pkg_deps()
    return [
        Pkg.PackageSpec(; kws...) for kws in [
            (; name = "HTTP", uuid = "cd3eb016-35fb-5094-929b-558a96fad6f3"),
            (; name = "HypertextTemplates", uuid = "c7d46f9d-34c3-4420-bf57-257f25aec718"),
            (; name = "BundledWebResources", uuid = "56c11eb9-1257-4f49-abe4-0ac93e2bfd0a"),
            (; name = "ReloadableMiddleware", uuid = "6b39ad65-d4e1-4a6a-9d75-56e3fde28494"),
            (; name = "RelocatableFolders", uuid = "05181044-ff0b-4ac5-8273-598c1e38db00"),
            (; name = "TailwindCSS", uuid = "70f3efdd-15fb-48e9-aed6-b5748bd45f5a"),
        ]
    ]
end

@plugin struct WebApp <: Plugin
    name::String = "WebApp"
end

view(::WebApp, t::PkgTemplates.Template, pkg::AbstractString) = Dict{String,String}()

function posthook(::WebApp, ::Template, pkg_dir::AbstractString)
    pkg = PkgTemplates.pkg_name(pkg_dir)

    function gen_module(dir::String, file::String)
        mkpath(dir)
        rendered = PkgTemplates.render_file(joinpath(TEMPLATES(), file), Dict{String,String}())
        PkgTemplates.gen_file(joinpath(dir, file), rendered)
    end

    src_dir = joinpath(pkg_dir, "src")

    gen_module(src_dir, "tailwind.config.js")
    gen_module(src_dir, "input.css")

    resources = joinpath(src_dir, "Resources")
    gen_module(resources, "Resources.jl")
    mkdir(joinpath(resources, "dist"))
    touch(joinpath(resources, "dist", "output.css"))

    routes_dir = joinpath(src_dir, "Routes")
    gen_module(routes_dir, "Routes.jl")

    templates_dir = joinpath(src_dir, "Templates")
    gen_module(templates_dir, "Templates.jl")
    gen_module(joinpath(templates_dir, "layouts"), "default.html")
    gen_module(joinpath(templates_dir, "pages"), "index.html")

    server_dir = joinpath(src_dir, "Server")
    gen_module(server_dir, "Server.jl")

    rendered = PkgTemplates.render_file(
        joinpath(TEMPLATES(), "README.md"),
        Dict{String,String}("PKG" => pkg),
    )
    PkgTemplates.gen_file(joinpath(pkg_dir, "README.md"), rendered)

    with_project(pkg_dir) do
        Pkg.add(pkg_deps())
    end
end

end
