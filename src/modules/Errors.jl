module Errors

#
# Imports:
#

using HypertextTemplates

import ..Browser
import ..Router

import Dates
import HTTP
import Sockets

#
# Exports:
#

export error_reporting_middleware

#
# Implementation:
#

"""
    error_reporting_middleware(handler)

When route handlers throws errors this middleware catches those and opens up
the stacktrace in a separate browser tab. When clicking on file location links
within the stacktrace the default `EDITOR` will be used to open that file at
the correct location.
"""
function error_reporting_middleware(errors::String; errors_storage = [])
    startswith(errors, "/") || error("errors route must start with a `/`.")
    endswith(errors, "/") || error("errors route must end with a `/`.")
    router = Router.router_reloader_middleware([Routes])
    function (handler)
        function (request)
            return _error_reporting_middleware(request, handler, router, errors, errors_storage)
        end
    end
end

function _error_reporting_middleware(request, handler, errors_router, target, errors_storage)
    uri = HTTP.URIs.URI(request.target)
    if startswith(uri.path, target)
        original_target = request.target
        _, rest = split(request.target, target; limit = 2)
        request.target = startswith(rest, "/") ? rest : "/$rest"
        request.context[:errors_storage] = errors_storage
        request.context[:errors] = target
        response = errors_router(request)
        request.target = original_target
        return response
    else
        try
            return handler(request)
        catch error
            return _error_response(request, error, catch_backtrace(), target, errors_storage)
        end
    end
end

#
# Error page templates:
#

module Templates

import ..Errors

using HypertextTemplates
using HypertextTemplates.Elements

@component function error_page(; error, backtrace, template_lookup)
    @html begin
        @head begin
            @title "Server Error"
            @meta {charset = "UTF-8"}
            @meta {name = "viewport", content = "width=device-width, initial-scale=1.0"}
            @script {src = "https://cdn.tailwindcss.com"}
        end
        @body {class = ""} begin
            @pre {
                class = "border rounded border-red-600 bg-gray-100/50 p-2 m-1 text-xs overflow-x-auto",
            } begin
                @code @text error
            end
            for (section_name, section) in backtrace
                @div {class = "text-xs m-1"} begin
                    for (nth, (group_name, group)) in enumerate(section)
                        @details {class = "p-1", open = nth < 3} begin
                            @summary @code {
                                class = "cursor-pointer font-bold p-1 hover:text-gray-800",
                            } @text group_name
                            @ol {class = "p-1"} begin
                                for frame in group
                                    @li {class = "px-1 py-2"} begin
                                        @p begin
                                            @code {class = "bg-gray-200 p-1 rounded"} @text frame.func
                                            @text " "
                                            @a {
                                                href = "#",
                                                "data-href" := "$(frame.source_file):$(frame.line_number)",
                                                class = "text-blue-700 hover:underline",
                                            } begin
                                                @text Errors.rewrite_path(frame.source_file) ":$(frame.line_number)"
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            @script @text SafeString("""
            (function () {
                const elements = document.querySelectorAll('[data-href]');
                elements.forEach(element => {
                    element.addEventListener('click', () => {
                        const href = element.getAttribute('data-href');
                        fetch("$template_lookup", { method: "POST", body: href });
                    });
                });
            })();
            """)
        end
    end
end
@deftag macro error_page end

@component function all_errors(; errors, prefix)
    @html begin
        @head begin
            @title "Server Errors"
            @meta {charset = "UTF-8"}
            @meta {name = "viewport", content = "width=device-width, initial-scale=1.0"}
            @script {src = "https://cdn.tailwindcss.com"}
        end
        @body {class = "m-1"} begin
            count = length(errors)
            for (nth, (timestamp, error, backtrace)) in enumerate(reverse(errors))
                @div {class = ""} begin
                    @details {class = "text-xs", open = nth == 1} begin
                        @summary begin
                            @em {class = "font-bold font-mono"} @text timestamp
                            @a {
                                class = "px-1 font-bold text-blue-600 hover:text-blue-800",
                                href = "$prefix$(count - nth + 1)",
                            } "view"
                            @code {class = "p-1"} @text first(split(error, '\n'))
                        end
                        @pre {class = "p-2 border bg-gray-100/50"} @code @text error
                    end
                end
            end
        end
    end
end
@deftag macro all_errors end

end

#
# Route handlers:
#

module Routes

using ...Router

import ..Templates

using HypertextTemplates

import HTTP

@GET "/" function (req::HTTP.Request)
    errors_storage = req.context[:errors_storage]
    prefix = req.context[:errors]
    return @render Templates.@all_errors {errors = errors_storage, prefix}
end

@GET "/{id}" function (req::HTTP.Request; path::@NamedTuple{id::Int})
    errors_storage = req.context[:errors_storage]
    timestamp, error, backtrace = errors_storage[path.id]
    template_lookup = req.context[:template_lookup]
    return @render Templates.@error_page {error, backtrace, template_lookup}
end

end

#
# Stacktrace processing:
#

struct StackFrameWrapper
    sf::StackTraces.StackFrame
    n::Int
    StackFrameWrapper(tuple) = new(tuple...)
end

function _process_stacktrace(error, bt)
    clean = Base.process_backtrace(bt)
    wrapped = StackFrameWrapper.(clean)
    toplevel = findfirst(s -> StackTraces.is_top_level_frame(s.sf), wrapped)
    toplevel = toplevel === nothing ? length(wrapped) : toplevel
    user_frames = wrapped[1:toplevel]
    system_frames = wrapped[toplevel+1:end]
    function make_nodes(section_name, frames)
        output = []
        for (nth, frame_group) in enumerate(aggregate_modules(frames))
            m = module_of(first(frame_group))
            if m === :unknown
                for frame in frame_group
                    # TODO: see whether this is needed.
                end
            else
                group_output = []
                name =
                    m === :inlined ? "[inlined]" :
                    m === :toplevel ? "[top-level]" :
                    is_from_stdlib(m) ? "$(m)" :
                    is_from_base(m) ? "$(m)" :
                    is_from_core(m) ? "$(m)" : is_from_package(m) ? "$(m)" : "$(m)"
                for frame in frame_group
                    if !StackTraces.is_top_level_frame(frame.sf)
                        file_name = frame.sf.file
                        line_number = frame.sf.line
                        source_file = find_source(file_name)
                        func =
                            Base.isidentifier(frame.sf.func) ? String(frame.sf.func) :
                            "var\"$(frame.sf.func)\""
                        push!(group_output, (; source_file, line_number, func, name))
                    end
                end
                push!(output, (name, group_output))
            end
        end
        return section_name, output
    end
    message = sprint(showerror, error, context = :color => false)
    stack = [make_nodes(:user, user_frames), make_nodes(:system, system_frames)]
    return Dates.now(), message, stack
end

function find_source(file)
    # Binary versions of Julia have the wrong stdlib path, fix it.
    file = replace(string(file), normpath(Sys.BUILD_STDLIB_PATH) => Sys.STDLIB; count = 1)
    return Base.find_source_file(file)
end

function rewrite_path(path)
    fn(path, replacer) = replace(String(path), replacer; count = 1)
    path = fn(path, normpath(Sys.BUILD_STDLIB_PATH) => "@stdlib")
    path = fn(path, normpath(Sys.STDLIB) => "@stdlib")
    path = fn(path, homedir() => "~")
    return path
end

function _error_response(request, error, st, target, storage)
    timestamp, message, stack = _process_stacktrace(error, st)
    push!(storage, (timestamp, message, stack))
    id = length(storage)

    stream = request.context[:stream]
    ip, port = Sockets.getsockname(stream)
    address = "http://$(ip):$(Int(port))$(target)$(id)"
    Browser.browser(address)

    request.response.status = HTTP.StatusCodes.INTERNAL_SERVER_ERROR
    request.response.body = ""
    HTTP.setheader(request.response, "Content-Length" => "0")

    return request.response
end

is_htmx(req::HTTP.Request) = HTTP.headercontains(req, "HX-Request", "true")

rootmodule(m::Module) = m === Base ? m : m === parentmodule(m) ? m : rootmodule(parentmodule(m))
rootmodule(::Any) = nothing
modulepath(m::Module) = string(pkgdir(m))
modulepath(other) = ""

is_from_stdlib(m) = startswith(modulepath(rootmodule(m)), Sys.STDLIB)
is_from_base(m) = rootmodule(m) === Base
is_from_core(m) = rootmodule(m) === Core
is_from_package(m) = (r = rootmodule(m); !is_from_core(r) && !is_from_base(r) && !is_from_stdlib(r))

module_of(sf) =
    sf.sf.inlined ? :inlined :
    sf.sf.func === Symbol("top-level scope") ? :toplevel :
    isa(sf.sf.linfo, Core.MethodInstance) ? sf.sf.linfo.def.module : :unknown

aggregate_modules(stacktrace) = groupby(module_of, stacktrace)

# groupby utils, from IterTools.jl

macro ifsomething(ex)
    quote
        result = $(esc(ex))
        result === nothing && return nothing
        result
    end
end

struct GroupBy{I,F<:Base.Callable}
    keyfunc::F
    xs::I
end
Base.eltype(::Type{<:GroupBy{I}}) where {I} = Vector{eltype(I)}
Base.IteratorSize(::Type{<:GroupBy}) = Base.SizeUnknown()

function groupby(keyfunc::F, xs::I) where {F<:Base.Callable,I}
    GroupBy{I,F}(keyfunc, xs)
end

function Base.iterate(it::GroupBy{I,F}, state = nothing) where {I,F<:Base.Callable}
    if state === nothing
        prev_val, xs_state = @ifsomething iterate(it.xs)
        prev_key = it.keyfunc(prev_val)
        keep_going = true
    else
        keep_going, prev_key, prev_val, xs_state = state
        keep_going || return nothing
    end
    values = Vector{eltype(I)}()
    push!(values, prev_val)

    while true
        xs_iter = iterate(it.xs, xs_state)

        if xs_iter === nothing
            keep_going = false
            break
        end

        val, xs_state = xs_iter
        key = it.keyfunc(val)

        if key == prev_key
            push!(values, val)
        else
            prev_key = key
            prev_val = val
            break
        end
    end

    return (values, (keep_going, prev_key, prev_val, xs_state))
end

end
