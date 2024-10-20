using ReloadableMiddleware
using Test

import ReloadableMiddleware.Errors

import HTTP

@testset "Errors" begin
    errors_storage = []
    middleware = Errors.error_reporting_middleware("/errors/"; errors_storage)(identity)

    res = middleware(HTTP.Request("GET", "/errors/"))
    @test isa(res, String)
    @test startswith(res, "<!DOCTYPE html>")
    @test contains(res, "Server Error")

    error, st = try
        div(1, 0)
    catch error
        error, catch_backtrace()
    end
    timestamp, message, stack = Errors._process_stacktrace(error, st)
    push!(errors_storage, (timestamp, message, stack))

    req = HTTP.Request("GET", "/errors/1")
    req.context[:errors_storage] = errors_storage
    req.context[:template_lookup] = "/template-lookup"

    res = middleware(req)
    @test startswith(res, "<!DOCTYPE html>")
    @test contains(res, "Server Error")
    @test contains(res, "DivideError")
end
