using ReloadableMiddleware
using Revise
using Test

import HTTP

using ReloadableMiddleware.Responses

@testset "Responses" begin
    handler = value -> Responses.response_middleware(req -> value)

    res = handler(1)(HTTP.Request("GET", "/"))
    @test String(res.body) == "1"
    @test only(HTTP.headers(res, "Content-Type")) == "text/plain; charset=utf-8"
    @test only(HTTP.headers(res, "Content-Length")) == "1"

    value = HTTP.Response(200, "content")
    res = handler(value)(HTTP.Request("GET", "/"))
    @test res === value

    res = handler([1])(HTTP.Request("GET", "/"))
    @test String(res.body) == "[1]"
    @test only(HTTP.headers(res, "Content-Type")) == "application/json; charset=utf-8"
    @test only(HTTP.headers(res, "Content-Length")) == "3"

    res = handler(Base.Docs.HTML("<p></p>"))(HTTP.Request("GET", "/"))
    @test String(res.body) == "<p></p>"
    @test only(HTTP.headers(res, "Content-Type")) == "text/html; charset=utf-8"
    @test only(HTTP.headers(res, "Content-Length")) == "7"

    res = handler("<p></p>")(HTTP.Request("GET", "/"))
    @test String(res.body) == "<p></p>"
    @test only(HTTP.headers(res, "Content-Type")) == "text/html; charset=utf-8"
    @test only(HTTP.headers(res, "Content-Length")) == "7"

    res = handler(Base.Docs.Text("<p></p>"))(HTTP.Request("GET", "/"))
    @test String(res.body) == "<p></p>"
    @test only(HTTP.headers(res, "Content-Type")) == "text/plain; charset=utf-8"
    @test only(HTTP.headers(res, "Content-Length")) == "7"

    res = handler(Responses.response("text/css", ""))(HTTP.Request("GET", "/"))
    @test String(res.body) == ""
    @test only(HTTP.headers(res, "Content-Type")) == "text/css; charset=utf-8"
    @test only(HTTP.headers(res, "Content-Length")) == "0"

    value = Responses.response("application/pdf", ""; attachment=true)
    res = handler(value)(HTTP.Request("GET", "/"))
    @test String(res.body) == ""
    @test only(HTTP.headers(res, "Content-Type")) == "application/pdf"
    @test only(HTTP.headers(res, "Content-Length")) == "0"
    @test only(HTTP.headers(res, "Content-Disposition")) == "attachment"

    value = Responses.response("application/pdf", ""; attachment=true, filename="file.pdf")
    res = handler(value)(HTTP.Request("GET", "/"))
    @test String(res.body) == ""
    @test only(HTTP.headers(res, "Content-Type")) == "application/pdf"
    @test only(HTTP.headers(res, "Content-Length")) == "0"
    @test only(HTTP.headers(res, "Content-Disposition")) == "attachment; filename=\"file.pdf\""

    struct Custom
        value::String
    end
    Base.show(io::IO, ::MIME"text/html", c::Custom) = print(io, "<p>$(c.value)</p>")

    value = Responses.response("text/html", Custom("value"))
    res = handler(value)(HTTP.Request("GET", "/"))
    @test String(res.body) == "<p>value</p>"
    @test only(HTTP.headers(res, "Content-Type")) == "text/html; charset=utf-8"
    @test only(HTTP.headers(res, "Content-Length")) == "12"
end
