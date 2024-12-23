using ReloadableMiddleware
using Test

import ReloadableMiddleware.Docs

import HTTP

@testset "Docs" begin
    mods = [Docs.Routes]
    middleware = Docs.middleware(mods, "/docs/")(identity)

    res = middleware(HTTP.Request("GET", "/docs/"))
    @test isa(res, HTTP.Response)
    body = String(res.body)
    @test startswith(body, "<!DOCTYPE html>")
    @test contains(body, "API Docs")
    @test contains(body, "API Documetation")

    req = HTTP.Request("GET", "/docs/ReloadableMiddleware.Docs.Routes/GET%20%2F")
    req.context[:template_lookup] = "/template-lookup"
    res = middleware(req)
    @test isa(res, HTTP.Response)
    body = String(res.body)
    @test startswith(body, "<!DOCTYPE html>")
    @test contains(body, "GET /")
    @test contains(body, "/template-lookup")
end
