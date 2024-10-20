module Reloader

import ..Watcher

import HTTP

"""
    ReloaderMiddleware(; config...)

Adding `ReloaderMiddleware` to a server middleware stack will cause the browser
tab to refetch the page content whenever `Revise` detects source file changes.
The newly fetched content will be merged into the current page content using
the DOM morphing provided by https://github.com/bigskysoftware/idiomorph.

Add this middleware directly *after* `ReviseMiddleware`.
"""
function ReloaderMiddleware(user_callback = identity; config...)
    condition = Condition()
    function callback(changes)
        changes = Base.@invokelatest user_callback(changes)
        if isempty(changes)
            # Filtered changes contains no changes.
        else
            notify(condition)
        end
    end
    watcher = Watcher.FolderWatcher(callback; config...)

    uuid = string(rand(UInt); base = 62)
    address = "/reloader-events-$uuid"

    function middleware(handler)
        return function (req)
            # Dispatch to a separate function such that that function can be
            # revised, otherwise writing that function's logic here would result in
            # non-revisable handler code.
            return reloader_middleware(handler, req, address, condition)
        end
    end

    return (; watcher, middleware)
end

# See `ext/ReloadableMiddlewareReviseExt.jl` for the method defintion of
# `reloader_middleware` that loads `Revise` and calls back into the main
# defintion below.

function reloader_middleware(handler, req, address, condition)
    if req.method == "GET" && req.target == address
        stream = req.context[:stream]
        if isopen(stream)
            return reload(stream, condition)
        end
    end
    return append_reloader_script(handler(req), address)
end

function reload(stream::HTTP.Stream, condition::Condition)
    HTTP.setheader(stream, "Access-Control-Allow-Methods" => "GET, OPTIONS")
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")

    if HTTP.method(stream.message) == "OPTIONS"
        return HTTP.Response(200, "")
    else
        HTTP.setheader(stream, "Content-Type" => "text/event-stream")
        HTTP.setheader(stream, "Cache-Control" => "no-cache")

        wait(condition)
        if isopen(stream)
            HTTP.startwrite(stream)
            @debug "🔄 sending reload event"
            try
                write(stream, "\ndata: reload\n\n")
            catch error
                # Can fail if the user has reloaded their browser window
                # manually. In that case, we just ignore the error.
                @debug "failed to send reload event" error
            finally
                HTTP.closewrite(stream)
                return HTTP.Response(200, "Stream complete.")
            end
        else
            return HTTP.Response(500, "Stream is no longer open.")
        end
    end
end

function append_reloader_script(response::HTTP.Response, address::String)
    if contains_html_content_type(response.headers)
        tags = "</head>"
        script = """
        <script src="https://unpkg.com/idiomorph@0.3.0/dist/idiomorph.js"></script>
        <script>
        (function () {
            const event = new EventSource("$address");
            event.onmessage = async function (event) {
                if (event.data === "reload") {
                    try {
                        const response = await fetch(location.pathname);
                        const text = await response.text();
                        const stripped = text.replace("<!DOCTYPE html>", "");
                        try {
                            Idiomorph.morph(document.documentElement, stripped, { morphStyle: 'outerHTML' });
                            window.dispatchEvent(new Event("ReloadableMiddleware:HotReload"));
                        } catch (error) {
                            console.warn("Failed to morph DOM, reloading instead.\\n", error);
                            location.reload();
                        };
                    } catch (error) {
                        console.warn("Failed to fetch page.\\n", error);
                    };
                };
            };
        })();
        </script>
        $tags
        """
        response.body = codeunits(replace(String(response.body), tags => script))
        HTTP.setheader(response, "Content-Length" => string(sizeof(response.body)))
    end
    return response
end
append_reloader_script(response, ::String) = response

function contains_html_content_type(headers)
    for (key, value) in headers
        if key == "Content-Type" && startswith(value, "text/html")
            return true
        end
    end
    return false
end

end
