module ReloadableMiddlewareProfileCanvasExt

import Dates
import ReloadableMiddleware
import ProfileCanvas
import ProfileCanvas.Profile

function ReloadableMiddleware._handle_profiler(::ReloadableMiddleware.ProfilerDispatchType, args)
    if startswith(args.req.target, args.route)
        # We never profile the profiler router itself. Insert the server state
        # into the request and that those routes need to be able to display the
        # profile data. Then pass the request to the profiler router instead of
        # the user-provided router.
        ReloadableMiddleware._include_server_state!(args.req, (; args.profiles, args.route))
        return args.profiler_router(args.req)
    else
        # Users can choose what to requests to profile based on the `matcher`
        # function or regex that they set in the `Profiler` middleware. By
        # default everything is profiled.
        if _perform_match(args.req, args.matcher)
            profiler_type, sample_rate = _query_profiler_type(args.req, args.type)

            profile = nothing
            response = nothing

            timestamp = Dates.now()

            if profiler_type == :allocs
                @static if isdefined(ProfileCanvas.Profile, :Allocs)
                    Profile.Allocs.clear()
                    response = Profile.Allocs.@profile sample_rate args.handler(args.req)
                    profile = html(ProfileCanvas.view_allocs(Profile.Allocs.fetch()))
                else
                    error("no support for :allocs profiling in this version of Julia.")
                end
            elseif profiler_type == :default
                Profile.clear()
                response = Profile.@profile args.handler(args.req)
                profile = html(ProfileCanvas.view(Profile.fetch()))
            else
                error("invalid profiler type: $profiler_type.")
            end

            # Neither of these should ever be `nothing` at this point.
            isnothing(response) && error("unreachable reached")
            isnothing(profile) && error("unreachable reached")

            if !isempty(profile)
                vec = get!(ReloadableMiddleware.ProfileStorage, args.profiles, args.req.target)
                # Discard the oldest profile data if we've reached the limit.
                length(vec) >= args.limit && popfirst!(vec)
                push!(vec, (; timestamp, profile))
            end

            # Finally, return the response that the user needs.
            return response
        else
            return args.handler(args.req)
        end
    end
end

_perform_match(req, matcher::Base.Callable) = matcher(req)
_perform_match(req, matcher::Regex) = match(matcher, req.target) !== nothing

_query_profiler_type(req, type::Function) = _verify_profiler_settings(type(req))
_query_profiler_type(req, type::Symbol) = _verify_profiler_settings(type)

function _verify_profiler_settings((type, sample_rate)::Tuple{Symbol,Float64})
    if !(type in (:default, :allocs))
        @warn "Invalid profiler type, setting to default instead" type
        type = :default
    end
    if !(0 ≤ sample_rate ≤ 1)
        @warn "Invalid profiler sample rate, setting to 0.1 instead" sample_rate
        sample_rate = 0.1
    end
    return type, sample_rate
end
function _verify_profiler_settings(other)
    @warn "Invalid profiler settings, setting to default instead" other
    return :default, 0.1
end
_verify_profiler_settings(type::Symbol) = _verify_profiler_settings((type, 0.1))

# Adapted from the `ProfileCanvas` package but don't write to a file.
function html(profile)
    id = "profiler-container-$(round(Int, rand()*100000))"
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <title>Profile Results</title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            #$(id) {
                margin: 0;
                padding: 0;
                width: 100vw;
                height: 100vh;
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif, "Apple Color Emoji", "Segoe UI Emoji";
                overflow: hidden;
            }
            body {
                margin: 0;
                padding: 0;
            }
        </style>
    </head>
    <body>
        <div id="$(id)"></div>
        <script type="module">
            const ProfileCanvas = await import('$(ProfileCanvas.jlprofile_data_uri())')
            const viewer = new ProfileCanvas.ProfileViewer("#$(id)", $(ProfileCanvas.JSON.json(profile.data)), "$(profile.typ)")
        </script>
    </body>
    </html>
    """
end
html(::Nothing) = ""

end
