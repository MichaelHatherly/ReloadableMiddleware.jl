using ReloadableMiddleware
using Test

import ReloadableMiddleware.Errors

import HTTP

@testset "Errors" begin
    errors_storage = []
    middleware = Errors.error_reporting_middleware("/errors/"; errors_storage)(identity)

    res = middleware(HTTP.Request("GET", "/errors/"))
    @test isa(res, HTTP.Response)
    body = String(res.body)
    @test startswith(body, "<!DOCTYPE html>")
    @test contains(body, "Server Error")

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
    body = String(res.body)
    @test startswith(body, "<!DOCTYPE html>")
    @test contains(body, "Server Error")
    @test contains(body, "DivideError")

    @testset "unresolvable source file" begin
        fake_path = "reloadable-middleware-nonexistent-$(rand(UInt32)).jl"
        @test Errors.find_source(fake_path) === nothing
        @test Errors.resolve_source_file(fake_path) == fake_path
        @test Errors.resolve_source_file(Symbol(fake_path)) == fake_path

        # Sanity: a file that does resolve is returned verbatim by `find_source`.
        real_path = @__FILE__
        @test Errors.find_source(real_path) == real_path
        @test Errors.resolve_source_file(real_path) == real_path
    end

    @testset "handler error is recorded" begin
        storage = []
        failing = Errors.error_reporting_middleware("/errors/"; errors_storage = storage)
        boom = failing(req -> throw(ErrorException("boom")))
        req = HTTP.Request("GET", "/boom"; headers = ["Host" => "127.0.0.1:8080"])
        res = withenv("CI" => "true") do
            @test_logs (:info, r"CI system detected") boom(req)
        end
        @test res.status == 500
        @test length(storage) == 1
        _, message, _ = storage[1]
        @test contains(message, "boom")
    end
end
