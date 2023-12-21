using Colors
using JET
using ReloadableMiddleware
using Test
using Revise

import ReloadableMiddleware.HTTP

module Endpoints

import Base: ==
import ReloadableMiddleware.HTTP

using Colors
using EnumX
using ReloadableMiddleware

import ReloadableMiddleware.StructTypes

struct CustomJSONType
    a::Int
    b::String
end
StructTypes.StructType(::Type{CustomJSONType}) = StructTypes.Struct()

@enum Fruit apple banana pineapple
@enumx Veg broccoli carrot potato

struct FileContent
    filename::String
    content::Vector{UInt8}
end
(==)(a::FileContent, b::FileContent) = a.filename == b.filename && a.content == b.content

function FileContent(multipart::HTTP.Multipart)
    filename = multipart.filename
    content = take!(multipart.data)
    return FileContent(filename, content)
end

f_1(req::@req GET "/") = req
f_2(req::@req POST "/1/$id") = req
f_3(req::@req PATCH "/2/$(id::Int)") = req
f_4(req::@req PUT "/3/$(id::Base.UUID)") = req
f_5(req::@req DELETE "/4/$(id)/$(name)") = req
f_6(req::@req GET "/5/$(id::Float64)/$(name::String)") = req

g_1(req::@req GET "/g/" query = {s}) = req
g_2(req::@req POST "/g/1/$id" form = {s::Int}) = req
g_3(req::@req PATCH "/g/2/$(id::Int)" form = {s, t::Base.UUID}) = req
g_4(req::@req GET "/g/4/$(fruit::Fruit)") = req
g_5(req::@req GET "/g/5/$(veg::Veg.T)") = req
g_6(req::@req GET "/g/6/$(color::Colorant)") = req

h_1(req::@req GET "/h/" query = {s = "default"}) = req
h_2(req::@req POST "/h/1/$id" form = {s::Int = 123}) = req
function h_3(
    req::@req(
        PATCH,
        "/h/2/$(id::Int)",
        form = {s = "default", t::Base.UUID = Base.UUID("123e4567-e89b-12d3-a456-426655440000")}
    ),
)
    return req
end
function h_4(
    req::@req(POST, "/h/json", form = {a::Vector{Int}, b::Dict{String,Int}, c::CustomJSONType}),
)
    return req
end
function h_5(
    req::@req(
        POST,
        "/h/5/$(id::Int)",
        form = {ids::Vector{Int} = Int[], values::Vector{String}, target},
    ),
)
    return req
end
function h_6(
    req::@req(
        GET,
        "/h/6/$(id::Int)",
        query = {ids::Vector{Int} = Int[], values::Vector{String}, target},
    ),
)
    return req
end
function h_7(req::@req(POST, "/h/7/$(id::Int)", form = {file::FileContent},))
    return req
end

broken_1(req::@req GET "/broken/1/$id") = req.params.unknown
broken_2(req::@req GET "/broken/2/$id") = req.query.unknown
broken_3(req::@req GET "/broken/3/$id") = req.form.unknown

end

@testset "ReloadableMiddleware" begin
    router = ModuleRouter(Main.Endpoints)

    function _no_reports(res)
        @static if VERSION < v"1.9"
            _, count = res
            return count == 0
        else
            return isempty(JET.get_reports(res))
        end
    end

    function test_wrapper(; req, f, method, target, params, query, form)
        res = router(req)

        @test res.request.method == method
        @test startswith(target, res.request.target)
        @test res.params == params
        @test res.query == query
        @test res.form == form

        builder = ReloadableMiddleware.ReqBuilder(typeof(res), identity)
        @inferred builder(req)

        @inferred f(res)

        @test _no_reports(report_call(f, Tuple{typeof(res)}))
    end

    test_wrapper(
        req = HTTP.Request("GET", "/"),
        f = Endpoints.f_1,
        method = "GET",
        target = "/",
        params = (;),
        query = (;),
        form = (;),
    )

    @test router(HTTP.Request("GET", "/123")).status == 404

    test_wrapper(;
        req = HTTP.Request("POST", "/1/123"),
        f = Endpoints.f_2,
        method = "POST",
        target = "/1/123",
        params = (; id = "123"),
        query = (;),
        form = (;),
    )

    test_wrapper(
        req = HTTP.Request("PATCH", "/2/123"),
        f = Endpoints.f_3,
        method = "PATCH",
        target = "/2/123",
        params = (; id = 123),
        query = (;),
        form = (;),
    )

    test_wrapper(
        req = HTTP.Request("PUT", "/3/123e4567-e89b-12d3-a456-426655440000"),
        f = Endpoints.f_4,
        method = "PUT",
        target = "/3/123e4567-e89b-12d3-a456-426655440000",
        params = (; id = Base.UUID("123e4567-e89b-12d3-a456-426655440000")),
        query = (;),
        form = (;),
    )

    test_wrapper(
        req = HTTP.Request("DELETE", "/4/123/abc"),
        f = Endpoints.f_5,
        method = "DELETE",
        target = "/4/123/abc",
        params = (; id = "123", name = "abc"),
        query = (;),
        form = (;),
    )

    test_wrapper(
        req = HTTP.Request("GET", "/5/123.0/abc"),
        f = Endpoints.f_6,
        method = "GET",
        target = "/5/123.0/abc",
        params = (; id = 123.0, name = "abc"),
        query = (;),
        form = (;),
    )

    test_wrapper(
        req = HTTP.Request("GET", "/g/?s=abc"),
        f = Endpoints.g_1,
        method = "GET",
        target = "/g/?s=abc",
        params = (;),
        query = (; s = "abc"),
        form = (;),
    )

    test_wrapper(
        req = HTTP.Request(
            "POST",
            "/g/1/123",
            ["Content-Type" => "application/x-www-form-urlencoded"],
            "s=123",
        ),
        f = Endpoints.g_2,
        method = "POST",
        target = "/g/1/123",
        params = (; id = "123"),
        query = (;),
        form = (; s = 123),
    )

    test_wrapper(
        req = HTTP.Request(
            "PATCH",
            "/g/2/123",
            ["Content-Type" => "application/x-www-form-urlencoded"],
            "s=123&t=123e4567-e89b-12d3-a456-426655440000",
        ),
        f = Endpoints.g_3,
        method = "PATCH",
        target = "/g/2/123",
        params = (; id = 123),
        query = (;),
        form = (; s = "123", t = Base.UUID("123e4567-e89b-12d3-a456-426655440000")),
    )

    test_wrapper(
        req = HTTP.Request("GET", "/g/4/apple"),
        f = Endpoints.g_4,
        method = "GET",
        target = "/g/4/apple",
        params = (; fruit = Endpoints.apple),
        query = (;),
        form = (;),
    )

    test_wrapper(
        req = HTTP.Request("GET", "/g/5/broccoli"),
        f = Endpoints.g_5,
        method = "GET",
        target = "/g/5/broccoli",
        params = (; veg = Endpoints.Veg.broccoli),
        query = (;),
        form = (;),
    )

    test_wrapper(
        req = HTTP.Request("GET", "/g/6/DeepSkyBlue"),
        f = Endpoints.g_6,
        method = "GET",
        target = "/g/6/DeepSkyBlue",
        params = (; color = Colors.RGB{Colors.N0f8}(0.0, 0.749, 1.0)),
        query = (;),
        form = (;),
    )

    test_wrapper(
        req = HTTP.Request("GET", "/h/"),
        f = Endpoints.h_1,
        method = "GET",
        target = "/h/?s=default",
        params = (;),
        query = (; s = "default"),
        form = (;),
    )

    test_wrapper(
        req = HTTP.Request(
            "POST",
            "/h/1/123",
            ["Content-Type" => "application/x-www-form-urlencoded"],
            "s=124",
        ),
        f = Endpoints.h_2,
        method = "POST",
        target = "/h/1/123",
        params = (; id = "123"),
        query = (;),
        form = (; s = 124),
    )

    test_wrapper(
        req = HTTP.Request("POST", "/h/1/123"),
        f = Endpoints.h_2,
        method = "POST",
        target = "/h/1/123",
        params = (; id = "123"),
        query = (;),
        form = (; s = 123),
    )

    test_wrapper(
        req = HTTP.Request(
            "PATCH",
            "/h/2/123",
            ["Content-Type" => "application/x-www-form-urlencoded"],
            "s=123&t=123e4567-e89b-12d3-a456-426655440001",
        ),
        f = Endpoints.h_3,
        method = "PATCH",
        target = "/h/2/123",
        params = (; id = 123),
        query = (;),
        form = (; s = "123", t = Base.UUID("123e4567-e89b-12d3-a456-426655440001")),
    )

    test_wrapper(
        req = HTTP.Request("PATCH", "/h/2/123"),
        f = Endpoints.h_3,
        method = "PATCH",
        target = "/h/2/123",
        params = (; id = 123),
        query = (;),
        form = (; s = "default", t = Base.UUID("123e4567-e89b-12d3-a456-426655440000")),
    )

    test_wrapper(
        req = HTTP.Request(
            "POST",
            "/h/json",
            ["Content-Type" => "application/json"],
            "{\"a\": [1, 2], \"b\": {\"c\": 3, \"d\": 4}, \"c\": {\"a\": 0, \"b\": \"\"}}",
        ),
        f = Endpoints.h_4,
        method = "POST",
        target = "/h/json",
        params = (;),
        query = (;),
        form = (; a = [1, 2], b = Dict("c" => 3, "d" => 4), c = Endpoints.CustomJSONType(0, "")),
    )

    test_wrapper(
        req = HTTP.Request(
            "POST",
            "/h/5/123",
            ["Content-Type" => "application/x-www-form-urlencoded"],
            "ids=1&ids=2&values=a&values=b&target=123",
        ),
        f = Endpoints.h_5,
        method = "POST",
        target = "/h/5/123",
        params = (; id = 123),
        query = (;),
        form = (; ids = [1, 2], values = ["a", "b"], target = "123"),
    )

    test_wrapper(
        req = HTTP.Request("GET", "/h/6/123?ids=1&values=a&values=b&target=123"),
        f = Endpoints.h_6,
        method = "GET",
        target = "/h/6/123?ids=1&values=a&values=b&target=123",
        params = (; id = 123),
        query = (; ids = Int[1], values = String["a", "b"], target = "123"),
        form = (;),
    )

    let boundary = "---------------------------26803618931735398227726670333"
        filename = "file.txt"
        content = "content"
        body = "--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"$filename\"\r\nContent-Type: text/plain\r\n\r\n$content\r\n--$boundary--\r\n"
        headers = [
            "Content-Type" => "multipart/form-data; boundary=$boundary",
            "Content-Length" => length(body),
        ]
        test_wrapper(
            req = HTTP.Request("POST", "/h/7/123", headers, body),
            f = Endpoints.h_7,
            method = "POST",
            target = "/h/7/123",
            params = (; id = 123),
            query = (;),
            form = (; file = Endpoints.FileContent(filename, Vector{UInt8}(content)),),
        )
    end

    # Ensure that running JET on these kinds of endpoints shows up the
    # undefined variable errors that are present.
    for endpoint in (Endpoints.broken_1, Endpoints.broken_2, Endpoints.broken_3)
        for method in methods(endpoint)
            sig = Tuple{Base.tuple_type_head(Base.tuple_type_tail(method.sig))}
            @test !_no_reports(report_call(endpoint, sig))
        end
    end
    @test_throws ErrorException router(HTTP.Request("GET", "/broken/1/123"))
    @test_throws ErrorException router(HTTP.Request("GET", "/broken/2/123"))
    @test_throws ErrorException router(HTTP.Request("GET", "/broken/3/123"))

    table = ReloadableMiddleware.RouteTable(Main.Endpoints)
    text = sprint(show, table)
    @test contains(text, "GET")
    @test contains(text, "POST")
    @test contains(text, "PATCH")
    @test contains(text, "Endpoints")
    @test contains(text, "f_1")
    @test contains(text, "runtests.jl:41")

    @testset "api route" begin
        res = router(HTTP.Request("GET", "/api"))
        body = String(res.body)
        @test contains(body, "API Explorer")
        @test contains(body, "OVERVIEW")
        @test contains(body, "Happy exploring!")
        @test contains(body, "/h/5/{id}")

        res = router(HTTP.Request("GET", "/api/$(HTTP.URIs.escapeuri("/h/5/{id}"))/POST"))
        body = String(res.body)
        @test !contains(body, "API Explorer")
        @test contains(body, "OVERVIEW")
        @test contains(body, "No documentation defined")
        @test contains(body, "Vector{String}")
    end

    @testset "Templates" begin
        using PkgTemplates

        mktempdir() do dir
            cd(dir) do
                ReloadableMiddleware.Templates.create(;
                    interactive = false,
                    pkg = "App",
                    user = "fakeuser",
                    git = false,
                )

                @test isdir("App")

                @test isfile(joinpath("App", "Project.toml"))
                @test isfile(joinpath("App", "Manifest.toml"))

                @test isfile(joinpath("App", "src", "App.jl"))
                @test isfile(joinpath("App", "src", "Templates", "Templates.jl"))
                @test isfile(joinpath("App", "src", "Routes", "Routes.jl"))
                @test isfile(joinpath("App", "src", "Resources", "Resources.jl"))
                @test isfile(joinpath("App", "src", "Server", "Server.jl"))

                @test isfile(joinpath("App", "test", "runtests.jl"))
                @test isfile(joinpath("App", "README.md"))

                cmd = Base.julia_cmd()
                run(`$cmd --project=App -e 'using App'`)
            end
        end
    end
end
