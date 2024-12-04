using Revise
using Test

@testset "ReloadableMiddleware" begin
    include("testsets/Browser.jl")
    include("testsets/Context.jl")
    include("testsets/Docs.jl")
    include("testsets/Errors.jl")
    include("testsets/Responses.jl")
    include("testsets/Router.jl")
    include("testsets/Extensions.jl")
end
