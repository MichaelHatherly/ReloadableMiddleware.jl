using ReloadableMiddleware
using Test

using ReloadableMiddleware.Context

import HTTP

@testset "Context" begin
    middleware = Context.middleware(; a=1, b=[2])(identity)
    @test context(middleware(HTTP.Request("GET", "/"))) == (; a=1, b=[2])
end
