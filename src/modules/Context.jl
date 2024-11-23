module Context

#
# Exports:
#

export context
export middleware

#
# Implementation:
#

const CONTEXT_KEY = gensym("##ctx##")

"""
    context([T], req) -> NamedTuple

Get the context namedtuple from the request `req`. Pass an optional `T` as the
first argument, which ensures that the returned context is of that type. Throws
an error if it isn't.
"""
context(req) = req.context[CONTEXT_KEY]::NamedTuple
context(T, req) = context(req)::T

"""
    Context.middleware(; items...)

A middleware provider that adds the `items` as entries in all request contexts.

```julia
Server.dev(;
    middleware = [Context.middleware(; db = SQLite.DB(file)), ...],
    # ...
)
```
"""
function middleware(; items...)
    ctx = NamedTuple(items)
    function (handler)
        function (request)
            request.context[CONTEXT_KEY] = ctx
            return handler(request)
        end
    end
end

end
