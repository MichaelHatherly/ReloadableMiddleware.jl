module Router

#
# Imports:
#

import HTTP
import JSON3
import MacroTools
import Sockets
import StructTypes

#
# Exports:
#

export @DELETE
export @GET
export @PATCH
export @POST
export @PUT
export @STREAM
export @WEBSOCKET
export @route

export File
export RawFile
export JSON
export Multipart

#
# Method types:
#

abstract type AbstractMethod end

struct DELETE <: AbstractMethod end
struct GET <: AbstractMethod end
struct PATCH <: AbstractMethod end
struct POST <: AbstractMethod end
struct PUT <: AbstractMethod end
struct STREAM <: AbstractMethod end
struct WEBSOCKET <: AbstractMethod end

method_string(T::Type{<:AbstractMethod}) = String(nameof(T))

#
# Route macros:
#

"""
    @route METHOD path function (request | stream; [path], [query], [body])
        # ...
        return response
    end

`path` must be a valid `HTTP.register!` path, since that is what is used
internally to register routes.

`handler` is an unnamed function taking one positional argument, the
`HTTP.Request`, or `HTTP.Stream` for `@STREAM` and `@WEBSOCKET`. Three optional
keyword arguments are available for use. They are `path`, `query`, and `body`.
They must be type annotated with a concrete type that the request should be
deserialized into.
"""
macro route(method, path, handler)
    method_type = getfield(@__MODULE__, Symbol(method))
    method_type <: AbstractMethod || error("'$method' is not a valid method type.")
    return macrobody(__source__, __module__, method_type, path, handler)
end

"""
    @DELETE path function (request; [path], [query])
        # ...
        return response
    end

Register a `DELETE` method handler for the given `path`.

See [`@route`](@ref) for further details.
"""
macro DELETE(path, handler)
    return macrobody(__source__, __module__, DELETE, path, handler)
end

"""
    @GET path function (request; [path], [query])
        # ...
        return response
    end

Register a `GET` method handler for the given `path`.

See [`@route`](@ref) for further details.
"""
macro GET(path, handler)
    return macrobody(__source__, __module__, GET, path, handler)
end

"""
    @PATCH path function (request; [path], [query])
        # ...
        return response
    end

Register a `PATCH` method handler for the given `path`.

See [`@route`](@ref) for further details.
"""
macro PATCH(path, handler)
    return macrobody(__source__, __module__, PATCH, path, handler)
end

"""
    @POST path function (request; [path], [query], [body])
        # ...
        return response
    end

Register a `POST` method handler for the given `path`.

See [`@route`](@ref) for further details.
"""
macro POST(path, handler)
    return macrobody(__source__, __module__, POST, path, handler)
end

"""
    @PUT path function (request; [path], [query])
        # ...
        return response
    end

Register a `PUT` method handler for the given `path`.

See [`@route`](@ref) for further details.
"""
macro PUT(path, handler)
    return macrobody(__source__, __module__, PUT, path, handler)
end

"""
    @STREAM path function (stream; [path], [query])
        # ...
        return response
    end

Register a handler for server sent events for the given `path`.

See [`@route`](@ref) for further details.
"""
macro STREAM(path, handler)
    return macrobody(__source__, __module__, STREAM, path, handler)
end

"""
    @WEBSOCKET path function (stream; [path], [query])
        # ...
        return response
    end

Register a handler for websocket connections for the given `path`.

See [`@route`](@ref) for further details.
"""
macro WEBSOCKET(path, handler)
    return macrobody(__source__, __module__, WEBSOCKET, path, handler)
end

#
# Handler interface:
#

abstract type Handler end

handler_function(::Any) = nothing
handler_method(::Any) = nothing
handler_path(::Any) = nothing
handler_path_type(::Any) = nothing
handler_query_type(::Any) = nothing
handler_body_type(::Any) = nothing

#
# Macrobody builder:
#

function macrobody(__source__, __module__, method, path, handler::Expr)
    if MacroTools.@capture(handler, function (arg_; kwargs__)
        body__
    end | function (arg_)
        body__
    end)
        kwargs = isnothing(kwargs) ? [] : kwargs

        # We generate a 'stable' name for the anonymous function since
        # otherwise when Revise updates the code after changes we get a new
        # function, rather than just replacing the method attached to the
        # function. We escape the `*` characters in the generated function name
        # since it appears to trigger an error when Revising code due to some
        # use of a regex pattern based on function name. Swap those characters
        # out with ones that kind of look like `*`.
        escaped_path = replace(path, "*" => "✱")
        name = Symbol("$(nameof(method)) $(escaped_path)")
        ename = esc(name)
        handler = _name_anon_func(handler, name)

        eqname = esc(QuoteNode(name))

        # This is the type used to mark the methods associated with this
        # particular handler function.
        ehandler = esc(handler_type())

        # We extract the key words from the handler function such that we can
        # embed them as the returned values from `handler_*_type` methods
        # defined for this handler. Allows for the types to be stable in the
        # request parsing functions.
        parsed_keywords = _parse_keywords(kwargs)

        # Revising functions with keywords results in new keyword handler
        # methods being created on each revision. Swap out the keywords for a
        # namedtuple that we manually unpack to avoid this.
        handler = _swap_kws_for_nt_arg(handler, parsed_keywords)

        mod = @__MODULE__
        quote
            # This helps avoid Revise issues if you happen to duplicate route
            # definitions. Throws an error that will stop Revise from creating
            # the new handler.
            if isdefined($(__module__), $(eqname)) && !isempty(methods($(ename)))
                error($("handler is already defined elsewhere: `$(name)`."))
            end

            Core.@__doc__ $(esc(handler))

            # We only need one of these definitions per module, but to allow
            # for revision of route handlers we need to define it at every
            # macro callsite. This type is used to tag the method definitions
            # appearing below with the handler function's auto-generated name.
            isdefined($(__module__), $(esc(QuoteNode(handler_type())))) || struct $(ehandler){T} end

            # The below method definitions store the "state" of the router,
            # without having to manually deal with global state and
            # invalidating it when Revise happens to delete a route handler.
            # These methods are called when constructing an `HTTP.Router` such
            # that the route handler function that gets called has
            # well-inferred types for parsing requests in the required types.
            $(mod).handler_function(::$(ehandler){$(eqname)}) = $(ename)
            $(mod).handler_method(::$(ehandler){$(eqname)}) = $(method)
            $(mod).handler_path(::$(ehandler){$(eqname)}) = $(path)
            $(mod).handler_path_type(::$(ehandler){$(eqname)}) = $(esc(parsed_keywords.path))
            $(mod).handler_query_type(::$(ehandler){$(eqname)}) = $(esc(parsed_keywords.query))
            $(mod).handler_body_type(::$(ehandler){$(eqname)}) = $(esc(parsed_keywords.body))
            $(ename)
        end
    else
        error(
            "invalid route macro use, must be an unnamed function with no keyword arguments and exactly one positional argument.",
        )
    end
end

function _swap_kws_for_nt_arg(handler, parsed_keywords)
    kws = Symbol("#kws#")

    # Remove the keywords, add a 2nd positional argument instead.
    args = handler.args[1].args
    filter!(ex -> !Meta.isexpr(ex, :parameters), args)
    push!(args, :($kws::NamedTuple))

    # Unpack the fields of the namedtuple argument into local variables.
    body = handler.args[end].args
    unpacked = [:($k = $(kws).$k) for (k, v) in pairs(parsed_keywords) if !isnothing(v)]
    insert!(body, 2, Expr(:block, unpacked...))

    return handler
end

function _parse_keywords(kwargs)
    path = nothing
    query = nothing
    body = nothing
    for kw in kwargs
        if Meta.isexpr(kw, :(::), 2)
            name, type = kw.args
            if name === :path
                path = type
            elseif name === :query
                query = type
            elseif name === :body
                body = type
            else
                error("unsupported keyword argument named: $name")
            end
        else
            error("invalid route keyword: $kw")
        end
    end
    return (; path, query, body)
end

handler_type() = Symbol("#handlertype#")

function _name_anon_func(ex::Expr, name::Symbol)
    return Expr(:function, Expr(:call, name, ex.args[1].args...), ex.args[2:end]...)
end

# Route handlers:

function route_handler(type, user_handler)
    return route_handler(handler_method(type), type, user_handler)
end

# Drop keywords that are not required by the function `f` since they are
# `nothing` and not a suitable type.
_invoke_kw(f, req, path, query, body) = f(req, (; path, query, body))
_invoke_kw(f, req, path, query, ::Nothing) = f(req, (; path, query))
_invoke_kw(f, req, path, ::Nothing, body) = f(req, (; path, body))
_invoke_kw(f, req, ::Nothing, query, body) = f(req, (; query, body))
_invoke_kw(f, req, path, ::Nothing, ::Nothing) = f(req, (; path))
_invoke_kw(f, req, ::Nothing, query, ::Nothing) = f(req, (; query))
_invoke_kw(f, req, ::Nothing, ::Nothing, body) = f(req, (; body))
_invoke_kw(f, req, ::Nothing, ::Nothing, ::Nothing) = f(req, (;))

# Request parser:

function _request_parser_builder(type)
    path_type = handler_path_type(type)
    query_type = handler_query_type(type)
    body_type = handler_body_type(type)
    function _request_parser(req)
        return (;
            path = _path_parser(req, path_type),
            query = _query_parser(req, query_type),
            body = _body_parser(req, body_type),
        )
    end
end

SymDict(dict) = Dict{Symbol,String}(Symbol(k) => v for (k, v) in dict)

function _path_parser(req, type)
    params = SymDict(HTTP.getparams(req))
    return StructTypes.constructfrom(type, params)
end
_path_parser(_, ::Nothing) = nothing

function _query_parser(req, type)
    queries = SymDict(HTTP.URIs.queryparams(req))
    return StructTypes.constructfrom(type, queries)
end
_query_parser(_, ::Nothing) = nothing

function _body_parser(req, type)
    body = SymDict(HTTP.URIs.queryparams(String(req.body)))
    return StructTypes.constructfrom(type, body)
end
_body_parser(_, ::Nothing) = nothing

# JSON:

"""
    JSON{T}

Mark a `body` keyword in a route handler as being JSON data that should be
deserialized into type `T` using the `JSON3` package. Within the route handler
access the JSON values via `body.json`. `alllow_inf` is set to `true`.
"""
struct JSON{T}
    json::T
end

function _body_parser(req, ::Type{JSON{type}}) where {type}
    HTTP.headercontains(req, "Content-Type", "application/json") ||
        error("`JSON` body expected, but `Content-Type` is not `application/json`.")
    # TODO: maybe don't set `allow_inf`, allow it to be customizable.
    return JSON{type}(JSON3.read(req.body, type; allow_inf = true))
end

# Multipart form data:

"""
    Multipart{T}

Mark a `body` keyword in a route handler as being `multipart/form-data` that
should be parsed an deserialized using `HTTP.parse_multipart_form`. Each part
of the request body is deserialized using the appropriate deserializer for it's
Content-Type, e.g. `application/json` and `application/x-www-form-urlencoded`.
See the [`File`](@ref) type for marking a form part as being a file. If a field
in a multipart form is a checkbox deserialize it into `Union{Bool,Nothing}`
since if unchecked, it will not be sent as part of the request.
"""
struct Multipart{T}
    multipart::T
end

struct MultipartWrapper
    multipart::HTTP.Multipart
end

"""
    File{T}

Used within a `Multipart` `body` annotation to mark the form part as being a
file that should be converted into a `File` object. The `T` type parameter is
used to specify the type of the file contents for deserialization. When using
this rather than a `RawFile` the `Content-Type` for the file must be either
`application/json` or `application/x-www-form-urlencoded` to be suitable for
deserialization.
"""
struct File{T}
    filename::String
    data::T
    contenttype::String
end

"""
A type alias for `File{Vector{UInt8}}` useful for when the file contents is
unstructured, or you need to deserialize it after first processing the request
completely.
"""
const RawFile = File{Vector{UInt8}}

function File(T, m::HTTP.Multipart)
    bytes = take!(m.data)
    data = _file_bytes_convert(T, m.contenttype, bytes)
    return File{T}(m.filename, data, m.contenttype)
end

_file_bytes_convert(::Type{String}, ::String, bytes::Vector{UInt8}) = String(bytes)
function _file_bytes_convert(::Type{T}, contenttype::String, bytes::Vector{UInt8}) where {T}
    if contenttype == "application/json"
        return JSON3.read(String(bytes), T; allow_inf = true)
    elseif contenttype == "application/x-www-form-urlencoded"
        content = String(bytes)
        params = SymDict(HTTP.URIs.queryparams(content))
        return StructTypes.constructfrom(T, params)
    else
        error("unsupported contenttype in multipart form data: $contenttype")
    end
end

File(::Type{Vector{UInt8}}, m::HTTP.Multipart) =
    File(m.filename, take!(m.data)::Vector{UInt8}, m.contenttype)

function Base.show(io::IO, f::File{T}) where {T}
    filename = repr(f.filename)
    size = sizeof(f.data)
    contenttype = repr(f.contenttype)
    print(
        io,
        "$File(filename=$(filename), raw=$(T == Vector{UInt8}), size=$(size), contenttype=$(contenttype))",
    )
end

function _multipart_convert(::Type{T}, wrapper::MultipartWrapper) where {T}
    contenttype = wrapper.multipart.contenttype
    if contenttype == "text/plain"
        return __multipart_convert(T, wrapper)
    elseif contenttype == "application/json"
        return JSON3.read(String(take!(wrapper.multipart.data)), T; allow_inf = true)
    elseif contenttype == "application/x-www-form-urlencoded"
        content = String(take!(wrapper.multipart.data))
        params = SymDict(HTTP.URIs.queryparams(content))
        return StructTypes.constructfrom(T, params)
    else
        error("unknown contenttype: $contenttype")
    end
end

_multipart_convert(::Type{File{T}}, wrapper::MultipartWrapper) where {T} =
    File(T, wrapper.multipart)

function __multipart_convert(::Type{Union{Bool,Nothing}}, wrapper::MultipartWrapper)
    # TODO: confirm that this is actually correct.
    value = String(take!(wrapper.multipart.data))
    return value == "on"
end

function __multipart_convert(::Type{T}, wrapper::MultipartWrapper) where {T}
    return StructTypes.constructfrom(T, String(take!(wrapper.multipart.data)))
end

StructTypes.constructfrom(::Type{T}, wrapper::MultipartWrapper) where {T} =
    _multipart_convert(T, wrapper)

function _body_parser(req, ::Type{Multipart{type}}) where {type}
    content_type = HTTP.header(req, "Content-Type", "")
    startswith(content_type, "multipart/form-data") ||
        error("`Multipart` body expected, but `Content-Type` is not `multipart/form-data`.")

    items = Dict{Symbol,MultipartWrapper}()
    for part in HTTP.parse_multipart_form(req)
        items[Symbol(part.name)] = MultipartWrapper(part)
    end
    return Multipart{type}(StructTypes.constructfrom(type, items))
end

# Request handler:

function route_handler(::Type{METHOD}, type, user_handler) where {METHOD<:AbstractMethod}
    request_parser = _request_parser_builder(type)
    function request_handler(request::HTTP.Request)
        return _request_handler(request, user_handler, request_parser)
    end
end
function _request_handler(request::HTTP.Request, user_handler, request_parser)
    nt = request_parser(request)
    return _invoke_kw(user_handler, request, nt.path, nt.query, nt.body)
end

# Stream handler:

function route_handler(::Type{STREAM}, type, user_handler)
    request_parser = _request_parser_builder(type)
    function stream_handler(request::HTTP.Request)
        return _stream_handler(request, user_handler, request_parser)
    end
end
function _stream_handler(request::HTTP.Request, user_handler, request_parser)
    nt = request_parser(request)
    stream = request.context[:stream]::HTTP.Stream
    return _invoke_kw(user_handler, stream, nt.path, nt.query, nt.body)
end

# Websocket handler:

function route_handler(::Type{WEBSOCKET}, type, user_handler)
    request_parser = _request_parser_builder(type)
    function websocket_handler(request::HTTP.Request)
        return _websocket_handler(request, user_handler, request_parser)
    end
end
function _websocket_handler(request::HTTP.Request, user_handler, request_parser)
    # TODO: this is untested.
    WS = HTTP.WebSockets
    stream = request.context[:stream]::HTTP.Stream
    if WS.isupgrade(stream)
        return WS.upgrade(stream) do client_stream
            if WS.isclosed(client_stream)
                return nothing
            else
                for message in client_stream
                    nt = request_parser(request)
                    return _invoke_kw(user_handler, message, nt.path, nt.query, nt.body)
                end
            end
        end
    else
        nt = request_parser(request)
        return _invoke_kw(user_handler, stream, nt.path, nt.query, nt.body)
    end
end

"""
    routes(mod::Module | mods::Vector{Module})

Builds an `HTTP.Router` based on the currently defined route handlers in the
given modules. When run in a `dev` server each time the routes defined within
the provided modules change it will rebuild the router between requests such
that you do not need to restart the server to see changes reflected.
"""
function routes end

function routes(ms::Vector{Module})
    hts = handler_type()
    router = HTTP.Router()
    module_hashes = []
    functions = []
    for m in ms
        if isdefined(m, hts)
            ht = getfield(m, hts)
            all_names = names(m; all = true)
            for name in all_names
                if Base.isdeprecated(m, name)
                    # Skip it.
                else
                    type = ht{name}()
                    handler = handler_function(type)
                    if isnothing(handler)
                        # Skip it.
                    else
                        push!(functions, handler => _world_ages(handler))
                        path = handler_path(type)
                        method = handler_method(type)
                        wrapped_handler = route_handler(method, type, handler)
                        HTTP.register!(router, method_string(method), path, wrapped_handler)
                    end
                end
            end
            push!(module_hashes, hash(all_names))
        else
            error("module $m has no defined route handlers.")
        end
    end
    return router, module_hashes, functions
end
routes(m::Module) = routes([m])

function routes_info(ms::Vector{Module})
    hts = handler_type()
    output = []
    for m in ms
        if isdefined(m, hts)
            ht = getfield(m, hts)
            all_names = names(m; all = true)
            for name in all_names
                if Base.isdeprecated(m, name)
                    # Skip it.
                else
                    type = ht{name}()
                    handler = handler_function(type)
                    if isnothing(handler)
                        # Skip it.
                    else
                        path = handler_path(type)
                        method = method_string(handler_method(type))
                        push!(output, (m, method, path, handler))
                    end
                end
            end
        end
    end
    sort!(output; by = item -> (string(item[1]), item[2], item[3]))
    return output
end

# When route handler definitions change their primary world does as well. This
# is used to detect whether the router needs to be rebuilt due to handler
# revisions.
_world_ages(func) = [m.primary_world for m in methods(func)]

# Decide whether the router modules have changed. Based on whether the same
# names are defined in the module, and whether any of the handler functions
# have got different world ages compared to previously.
function _router_modules_changed(ms::Vector{Module}, module_hashes, functions)
    for (mod, current_hash) in zip(ms, module_hashes)
        new_hash = hash(names(mod; all = true))
        if new_hash !== current_hash
            @debug "module globals different" mod new_hash current_hash
            return true
        end
    end
    for (func, current_ages) in functions
        new_ages = _world_ages(func)
        if new_ages != current_ages
            @debug "world ages differ for handler function" func new_ages current_ages
            return true
        end
    end
    return false
end

# The below ref code is used to hot-swap the router of a live dev server
# without needing to restart it.

_router_ref(ms) = Ref(routes(ms))

function _new_router_ref(ref_lock, ref, ms)
    return lock(ref_lock) do
        _, module_hashes, functions = ref[]
        if _router_modules_changed(ms, module_hashes, functions)
            ref[] = _router_ref(ms)[]
            @debug "redefined router" modules = ms
        end
        return ref
    end
end

function router_reloader_middleware(router_modules)
    ref_lock = ReentrantLock()
    router_ref = Router._router_ref(router_modules)
    function (request::HTTP.Request)
        return _router_reloader_middleware(request, router_ref, ref_lock, router_modules)
    end
end

function _router_reloader_middleware(request, router_ref, ref_lock, router_modules)
    router, _, _ = Router._new_router_ref(ref_lock, router_ref, router_modules)[]
    return router(request)
end

end
