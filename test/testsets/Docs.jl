using ReloadableMiddleware
using Test

import ReloadableMiddleware.Docs

import HTTP

@testset "Docs" begin
    mods = [Docs.Routes]
    middleware = Docs.middleware(mods, "/docs/")(identity)

    res = middleware(HTTP.Request("GET", "/docs/"))
    @test isa(res, String)
    @test startswith(res, "<!DOCTYPE html>")
    @test contains(res, "API Docs")
    @test contains(res, "API Documetation")

    req = HTTP.Request("GET", "/docs/ReloadableMiddleware.Docs.Routes/GET%20%2F")
    req.context[:template_lookup] = "/template-lookup"
    res = middleware(req)
    @test isa(res, String)
    @test startswith(res, "<!DOCTYPE html>")
    @test contains(res, "GET /")
    @test contains(res, "/template-lookup")
end
