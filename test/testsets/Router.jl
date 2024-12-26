using ReloadableMiddleware
using Revise
using Test

import HTTP

module Routes

using ReloadableMiddleware.Router
using ReloadableMiddleware.Responses: NoConvert


@GET "/" function index(req)
    NoConvert("/")
end

@GET "/path-string/{id}" function path_string(req; path::@NamedTuple{id})
    return NoConvert(path.id)
end

@GET "/path-int/{id}" function path_int(req; path::@NamedTuple{id::Int})
    return NoConvert(path.id)
end

@GET "/query-string" function query_string(req; query::@NamedTuple{id})
    return NoConvert(query.id)
end

@GET "/query-int" function (req; query::@NamedTuple{id::Int})
    return NoConvert(query.id)
end

@POST "/body-string" function (req; body::@NamedTuple{id})
    return NoConvert(body.id)
end

@POST "/body-int" function (req; body::@NamedTuple{id::Int})
    return NoConvert(body.id)
end

@POST "/body-json-string" function (req; body::JSON{@NamedTuple{id}})
    return NoConvert(body.json.id)
end

@POST "/body-json-int" function (req; body::JSON{@NamedTuple{id::Int}})
    return NoConvert(body.json.id)
end

@enum Fruit apple banana pineapple

@GET "/path-enum/{fruit}" function path_enum(req; path::@NamedTuple{fruit::Fruit})
    return NoConvert(path.fruit)
end

@GET "/query-enum" function (req; query::@NamedTuple{fruit::Fruit})
    return NoConvert(query.fruit)
end

@POST "/body-enum" function (req; body::@NamedTuple{fruit::Fruit})
    return NoConvert(body.fruit)
end

@GET "/combined/{path}/{id}" function combined_path_and_query(
    req;
    path::@NamedTuple{path::Int, id::Base.UUID},
    query::@NamedTuple{a::Int, b::String},
)
    return NoConvert((path, query))
end

@PATCH "/patch" function (req; query::@NamedTuple{id})
    return NoConvert(query.id)
end

@DELETE "/delete" function (req; query::@NamedTuple{id})
    return NoConvert(query.id)
end

@POST "/multipart" function (req; body::Multipart{@NamedTuple{file::RawFile}})
    return NoConvert(body.multipart.file)
end

@POST "/multipart-typed" function (
    req; body::Multipart{@NamedTuple{file::File{@NamedTuple{id::Int}}}}
)
    return NoConvert(body.multipart.file)
end

@STREAM "/stream" function (stream)
    #
end

@WEBSOCKET "/ws" function (ws)
    #
end

module API

using ReloadableMiddleware.Router
using ReloadableMiddleware.Responses: NoConvert

function middleware_1(handler)
    function (req)
        push!(get!(req.context, :stack, []), (1, :before))
        res = handler(req)
        push!(res.value.stack, (1, :after))
        return res
    end
end

function middleware_2(handler)
    function (req)
        push!(get!(req.context, :stack, []), (2, :before))
        res = handler(req)
        push!(res.value.stack, (2, :after))
        return res
    end
end

@prefix "/api/{version}"

@middleware function module_specific_middleware(handler)
    return reduce(|>, reverse((middleware_1, middleware_2)); init = handler)
end

@GET "/{id}" function api_endpoint(req; path::@NamedTuple{version::VersionNumber, id::Int})
    return NoConvert((version = path.version, id = path.id, stack = req.context[:stack]))
end

end

end

@testset "Router" begin
    router = ReloadableMiddleware.Router.router_reloader_middleware([Routes, Routes.API])

    @test router(HTTP.Request("GET", "/")).value == "/"
    @test router(HTTP.Request("GET", "/unknown")).status == 404
    @test router(HTTP.Request("POST", "/")).status == 405

    @test router(HTTP.Request("GET", "/path-string/1")).value == "1"
    @test router(HTTP.Request("GET", "/path-int/1")).value == 1

    @test router(HTTP.Request("GET", "/query-string?id=1")).value == "1"
    @test router(HTTP.Request("GET", "/query-int?id=1")).value == 1

    urlencoded = "Content-Type" => "application/x-www-urlencoded"
    @test router(HTTP.Request("POST", "/body-string", [urlencoded], "id=1")).value == "1"
    @test router(HTTP.Request("POST", "/body-int", [urlencoded], "id=1")).value == 1

    json = "Content-Type" => "application/json"
    @test router(HTTP.Request("POST", "/body-json-string", [json], "{\"id\": \"1\"}")).value == "1"
    @test router(HTTP.Request("POST", "/body-json-int", [json], "{\"id\": 1}")).value == 1

    @test router(HTTP.Request("GET", "/path-enum/apple")).value == Routes.apple
    @test router(HTTP.Request("GET", "/query-enum?fruit=banana")).value == Routes.banana
    @test router(HTTP.Request("POST", "/body-enum", [urlencoded], "fruit=pineapple")).value ==
          Routes.pineapple

    @test router(HTTP.Request("PATCH", "/patch?id=1")).value == "1"
    @test router(HTTP.Request("DELETE", "/delete?id=1")).value == "1"

    let boundary = "---------------------------26803618931735398227726670333"
        filename = "file.txt"
        content = "content"
        contenttype = "text/plain"
        body = "--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"$filename\"\r\nContent-Type: $contenttype\r\n\r\n$content\r\n--$boundary--\r\n"
        res =
            router(
                HTTP.Request(
                    "POST",
                    "/multipart",
                    [
                        "Content-Type" => "multipart/form-data; boundary=$boundary",
                        "Content-Length" => length(body),
                    ],
                    body,
                ),
            ).value
        @test isa(res, ReloadableMiddleware.Router.File)
        @test res.filename == filename
        @test res.data == Vector{UInt8}(content)
        @test res.contenttype == contenttype
    end

    let boundary = "---------------------------26803618931735398227726670333"
        filename = "file.txt"
        content = "id=1"
        contenttype = "application/x-www-form-urlencoded"
        body = "--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"$filename\"\r\nContent-Type: $contenttype\r\n\r\n$content\r\n--$boundary--\r\n"
        res =
            router(
                HTTP.Request(
                    "POST",
                    "/multipart-typed",
                    [
                        "Content-Type" => "multipart/form-data; boundary=$boundary",
                        "Content-Length" => length(body),
                    ],
                    body,
                ),
            ).value
        @test isa(res, ReloadableMiddleware.Router.File)
        @test res.filename == filename
        @test res.data.id == 1
        @test res.contenttype == contenttype
    end

    let boundary = "---------------------------26803618931735398227726670333"
        filename = "file.txt"
        content = "{\"id\": 1}"
        contenttype = "application/json"
        body = "--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"$filename\"\r\nContent-Type: $contenttype\r\n\r\n$content\r\n--$boundary--\r\n"
        res =
            router(
                HTTP.Request(
                    "POST",
                    "/multipart-typed",
                    [
                        "Content-Type" => "multipart/form-data; boundary=$boundary",
                        "Content-Length" => length(body),
                    ],
                    body,
                ),
            ).value
        @test isa(res, ReloadableMiddleware.Router.File)
        @test res.filename == filename
        @test res.data.id == 1
        @test res.contenttype == contenttype
    end

    @test router(HTTP.Request("GET", "/api/v1/1")).value == (
        version = v"1.0.0",
        id = 1,
        stack = [(1, :before), (2, :before), (2, :after), (1, :after)],
    )
    @test router(HTTP.Request("GET", "/api/v2.1.0/2")).value == (
        version = v"2.1.0",
        id = 2,
        stack = Any[(1, :before), (2, :before), (2, :after), (1, :after)],
    )

    @testset "URL builder" begin
        @test Routes.index() == "/"
        @test_throws ReloadableMiddleware.Router.TypeConversionError Routes.index(;
            path = (; id = 1),
            query = (a = "1"),
        ) == "/"

        @test Routes.query_string(; query = (; id = "1")) == "/query-string?id=1"
        @test Routes.query_string(; query = (; id = "&")) == "/query-string?id=%26"

        @test Routes.path_string(; path = (; id = "1")) == "/path-string/1"
        @test Routes.path_int(; path = (; id = 1)) == "/path-int/1"
        @test_throws ReloadableMiddleware.Router.TypeConversionError Routes.path_int(;
            path = (; id = "x"),
        ) == "/path-int/x"
        @test Routes.path_enum(; path = (; fruit = Routes.apple)) == "/path-enum/apple"

        @test Routes.API.api_endpoint(; path = (; version = v"1", id = 1)) == "/api/1.0.0/1"
        @test_throws ReloadableMiddleware.Router.TypeConversionError Routes.API.api_endpoint(;
            path = (; version = :foo, id = "bar"),
        ) == "/api/foo/bar"

        @test Routes.combined_path_and_query(;
            path = (; path = 1, id = 0),
            query = (; a = 1, b = "2"),
        ) == "/combined/1/00000000-0000-0000-0000-000000000000?a=1&b=2"
    end
end
