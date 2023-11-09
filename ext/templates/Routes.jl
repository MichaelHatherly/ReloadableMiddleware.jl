module Routes

import ..Templates

using ReloadableMiddleware

import HypertextTemplates
import HTTP

function response(code::Int, template, args...; kws...)
    return HTTP.Response(
        code,
        ["Content-Type" => "text/html"],
        HypertextTemplates.render(template, args...; kws...),
    )
end
response(template, args...; kws...) = response(200, template, args...; kws...)

function index(::@req GET "/")
    return response(Templates.index)
end

end
