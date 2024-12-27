import Changelog

cd(dirname(@__DIR__)) do
    Changelog.generate(
        Changelog.CommonMark(),
        "CHANGELOG.md";
        repo = "MichaelHatherly/ReloadableMiddleware.jl",
    )
end