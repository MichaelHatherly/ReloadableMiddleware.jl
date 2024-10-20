module Reviser

"""
    ReviseMiddleware(handler)

Adding `ReviseMiddleware` to a server middleware stack will result in each
request triggering a `Revise.jl` revision if there are unevaluated changes in
any tracked files. Use alongside `ReloaderMiddleware` to auto-reload the
browser on each change to the backend code.

Add this middleware at the very start of your server middleware stack. The
`ReloaderMiddleware` should appear directly afterwards.
"""
function ReviseMiddleware(handler)
    function (req)
        # Dispatch to a separate function such that that function can be
        # revised, otherwise writing that function's logic here would result in
        # non-revisable handler code.
        return revise_middleware(nothing, handler, req)
    end
end

# See `ext/ReloadableMiddlewareReviseExt.jl` for the method defintion of
# `revise_middleware` that loads `Revise` and calls back into the main
# defintion below.

function revise_middleware(Revise::NamedTuple, handler, req)
    if isempty(Revise.revision_queue)
        return handler(req)
    else
        try
            @debug "🔨 revising code"
            Revise.revise()
        catch error
            @error "Revise failed to run." error
        end
        Base.invokelatest(handler, req)
    end
end
revise_middleware(::Any, handler, req) = handler(req)

end
