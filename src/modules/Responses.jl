module Responses

#
# Imports:
#

import HTTP
import JSON3

#
# Exports:
#

export response

#
# Response middleware:
#

function response_middleware(handler)
    function (request)
        return _response_middleware(handler, request)
    end
end

function _response_middleware(handler, request)
    result = handler(request)
    handle_response!(request, result)
    return request.response
end

#
# `response` implementation:
#

"""
    response(mime, object; attachment = false, filename = nothing)

Construct a response object from `object` in the provided `mime` type and set
the `Content-Disposition` based on `filename` and `attachment`. Will
automatically set `Content-Type` and `Content-Length` based on the `object` and
`mime` given. `mime` can either be a `MIME`, or a `String`.

When `object` is a `String` or `Vector{UInt8}` then no transformation is
applied to the `object` and it is instead used directly in the `Response`
object. Any other type is first rendered using `show(io, mime, object)` to
create the correct mime type output.
"""
function response(
    mime::MIME{T},
    object;
    filename::Union{String,Nothing} = nothing,
    attachment::Bool = false,
) where {T}
    charset = _charset(mime)
    content_type = "$T$charset"

    body = _response_bytes(mime, object)::Vector{UInt8}
    content_length = string(sizeof(body))

    res = HTTP.Response(
        200,
        ["Content-Type" => content_type, "Content-Length" => content_length],
        body,
    )

    # When an attachment is requested, make sure that the content disposition
    # is set so that the browser will download it as a file rather than
    # attempting to display it inline.
    if attachment
        filename = isnothing(filename) ? "" : "; filename=$(repr(filename))"
        HTTP.setheader(res, "Content-Disposition" => "attachment$filename")
    end

    return res
end
response(mime::AbstractString, object; kwargs...) = response(MIME(mime), object; kwargs...)

function _response_bytes(mime::MIME, object)
    buffer = IOBuffer()
    show(buffer, mime, object)
    return take!(buffer)::Vector{UInt8}
end
function _response_bytes(::MIME"application/json", object)
    buffer = IOBuffer()
    JSON3.write(buffer, object; allow_inf = true)
    return take!(buffer)::Vector{UInt8}
end
_response_bytes(::MIME, bytes::Vector{UInt8}) = bytes
_response_bytes(::MIME, bytes::String) = Vector{UInt8}(bytes)

_charset(::MIME) = ""
# Content-Types that need a charset set. We assume utf-8, since all `String`s
# are UTF-8.
_charset(::MIME"application/json") = "; charset=utf-8"
_charset(::MIME"application/xml") = "; charset=utf-8"
_charset(::MIME"image/svg+xml") = "; charset=utf-8"
_charset(::MIME"text/css") = "; charset=utf-8"
_charset(::MIME"text/csv") = "; charset=utf-8"
_charset(::MIME"text/html") = "; charset=utf-8"
_charset(::MIME"text/javascript") = "; charset=utf-8"
_charset(::MIME"text/plain") = "; charset=utf-8"

#
# Response handlers:
#

function handle_response!(req::HTTP.Request, res::HTTP.Response)
    req.response = res
end

function handle_response!(req::HTTP.Request, content::AbstractString)
    body = string(content)
    return _build_respose!(req.response, body, HTTP.sniff(body))
end

function handle_response!(req::HTTP.Request, html::Base.Docs.HTML)
    body = sprint(show, MIME"text/html"(), html)
    return _build_respose!(req.response, body, "text/html; charset=utf-8")
end

function handle_response!(req::HTTP.Request, text::Base.Docs.Text)
    body = sprint(show, MIME"text/plain"(), text)
    return _build_respose!(req.response, body, "text/plain; charset=utf-8")
end

function handle_response!(req::HTTP.Request, content::Union{Number,Bool,Char,Symbol})
    body = string(content)
    return _build_respose!(req.response, body, "text/plain; charset=utf-8")
end

function handle_response!(req::HTTP.Request, content::Any)
    body = JSON3.write(content; allow_inf = true)
    return _build_respose!(req.response, body, "application/json; charset=utf-8")
end

function _build_respose!(response, body, content_type)
    bytes = Vector{UInt8}(body)

    HTTP.setheader(response, "Content-Type" => content_type)
    HTTP.setheader(response, "Content-Length" => string(sizeof(bytes)))

    response.status = 200
    response.body = bytes::Vector{UInt8}

    return response
end

end
