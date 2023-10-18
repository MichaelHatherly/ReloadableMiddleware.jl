# ReloadableMiddleware.jl

_`Revise`-compatible hot-reloading middleware for web development in Julia_

Development utilities for improving your development workflow when building web
applications in pure-Julia. This package integrates with `Revise` and `HTTP` to
allow for automatic hot-reloading pages with "in-place" DOM-swapping rather
than full-page refreshes.

## `HotReloader`

A `HotReloader` can be added to the top of a `HTTP` router stack to enable
hot-reloading of page content.

```julia
using HTTP
using ReloadableMiddleware

hot = HotReloader()
router = HTTP.Router()

# Add some routes to the `router`...

HTTP.serve!(router |> hot.middleware, HTTP.Sockets.localhost, 8080)

# Later on:
hot.refresh() # Refresh the page.
```

Calling `hot.refresh()` will cause any clients connected to the server to
reload their page. The reload is done "in-place" by swapping out the DOM
content with the new content for a page rather than doing a full page refresh.

This does not perform any file-watching or other automatic reloading. It is
intended to be used in conjunction with separate file-watching utilities such
as the `FileWatching` module.

## `ModuleRouter`

This type can be used to automatically create an `HTTP.Router` based on the functions
defined in a given module, or modules. The router automatically updates itself when
changes are detected by `Revise` if a `HotReloader` is present in the router stack.

You can define functions within a module that should act as endpoints for the router
with the `@req` macro.
