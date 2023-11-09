module Resources

using BundledWebResources
using RelocatableFolders

const DIST = RelocatableFolders.@path joinpath(@__DIR__, "dist")

function output_css()
    @comptime LocalResource(DIST, "output.css")
end

end
