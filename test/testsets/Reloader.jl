using ReloadableMiddleware
using Test

import ReloadableMiddleware.Reloader

import HTTP

@testset "Reloader" begin
    address = "/reloader-events-test"
    condition = Threads.Condition()
    handler = req -> HTTP.Response(200, "passed through")

    @testset "OPTIONS preflight on the reload address" begin
        req = HTTP.Request("OPTIONS", address)
        res = Reloader.reloader_middleware(handler, req, address, condition)
        @test res.status == 200
        @test HTTP.header(res, "Access-Control-Allow-Methods") == "GET, OPTIONS"
        @test String(res.body) == ""
    end

    @testset "other targets pass through" begin
        req = HTTP.Request("OPTIONS", "/elsewhere")
        res = Reloader.reloader_middleware(handler, req, address, condition)
        @test String(res.body) == "passed through"
    end
end
