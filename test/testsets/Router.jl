using ReloadableMiddleware
using Revise
using Test

import HTTP

module Routes

using ReloadableMiddleware.Router

@GET "/" function (req)
    "/"
end

@GET "/path-string/{id}" function (req; path::@NamedTuple{id})
    return path.id
end

@GET "/path-int/{id}" function (req; path::@NamedTuple{id::Int})
    return path.id
end

@GET "/query-string" function (req; query::@NamedTuple{id})
    return query.id
end

@GET "/query-int" function (req; query::@NamedTuple{id::Int})
    return query.id
end

@POST "/body-string" function (req; body::@NamedTuple{id})
    return body.id
end

@POST "/body-int" function (req; body::@NamedTuple{id::Int})
    return body.id
end

@POST "/body-json-string" function (req; body::JSON{@NamedTuple{id}})
    return body.json.id
end

@POST "/body-json-int" function (req; body::JSON{@NamedTuple{id::Int}})
    return body.json.id
end

@enum Fruit apple banana pineapple

@GET "/path-enum/{fruit}" function (req; path::@NamedTuple{fruit::Fruit})
    return path.fruit
end

@GET "/query-enum" function (req; query::@NamedTuple{fruit::Fruit})
    return query.fruit
end

@POST "/body-enum" function (req; body::@NamedTuple{fruit::Fruit})
    return body.fruit
end

@PATCH "/patch" function (req; query::@NamedTuple{id})
    return query.id
end

@DELETE "/delete" function (req; query::@NamedTuple{id})
    return query.id
end

@POST "/multipart" function (req; body::Multipart{@NamedTuple{file::RawFile}})
    return body.multipart.file
end

@POST "/multipart-typed" function (req; body::Multipart{@NamedTuple{file::File{@NamedTuple{id::Int}}}})
    return body.multipart.file
end

@STREAM "/stream" function (stream)
    #
end

@WEBSOCKET "/ws" function (ws)
    #
end

end

@testset "Router" begin
    router = ReloadableMiddleware.Router.router_reloader_middleware([Routes])

    @test router(HTTP.Request("GET", "/")) == "/"
    @test router(HTTP.Request("GET", "/unknown")).status == 404
    @test router(HTTP.Request("POST", "/")).status == 405

    @test router(HTTP.Request("GET", "/path-string/1")) == "1"
    @test router(HTTP.Request("GET", "/path-int/1")) == 1

    @test router(HTTP.Request("GET", "/query-string?id=1")) == "1"
    @test router(HTTP.Request("GET", "/query-int?id=1")) == 1

    urlencoded = "Content-Type" => "application/x-www-urlencoded"
    @test router(HTTP.Request("POST", "/body-string", [urlencoded], "id=1")) == "1"
    @test router(HTTP.Request("POST", "/body-int", [urlencoded], "id=1")) == 1

    json = "Content-Type" => "application/json"
    @test router(HTTP.Request("POST", "/body-json-string", [json], "{\"id\": \"1\"}")) == "1"
    @test router(HTTP.Request("POST", "/body-json-int", [json], "{\"id\": 1}")) == 1

    @test router(HTTP.Request("GET", "/path-enum/apple")) == Routes.apple
    @test router(HTTP.Request("GET", "/query-enum?fruit=banana")) == Routes.banana
    @test router(HTTP.Request("POST", "/body-enum", [urlencoded], "fruit=pineapple")) ==
          Routes.pineapple

    @test router(HTTP.Request("PATCH", "/patch?id=1")) == "1"
    @test router(HTTP.Request("DELETE", "/delete?id=1")) == "1"

    let boundary = "---------------------------26803618931735398227726670333"
        filename = "file.txt"
        content = "content"
        contenttype = "text/plain"
        body = "--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"$filename\"\r\nContent-Type: $contenttype\r\n\r\n$content\r\n--$boundary--\r\n"
        res = router(
            HTTP.Request(
                "POST",
                "/multipart",
                [
                    "Content-Type" => "multipart/form-data; boundary=$boundary",
                    "Content-Length" => length(body),
                ],
                body,
            ),
        )
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
        res = router(
            HTTP.Request(
                "POST",
                "/multipart-typed",
                [
                    "Content-Type" => "multipart/form-data; boundary=$boundary",
                    "Content-Length" => length(body),
                ],
                body,
            ),
        )
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
        res = router(
            HTTP.Request(
                "POST",
                "/multipart-typed",
                [
                    "Content-Type" => "multipart/form-data; boundary=$boundary",
                    "Content-Length" => length(body),
                ],
                body,
            ),
        )
        @test isa(res, ReloadableMiddleware.Router.File)
        @test res.filename == filename
        @test res.data.id == 1
        @test res.contenttype == contenttype
    end
end
