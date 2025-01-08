# `Extensions`

This module offers interfaces that enhance features and behaviors of the
package but that rely on external Julia packages that are not direct
dependencies of `ReloadableMiddleware`.

## `bonito_middleware`

This middleware function provides integration with `Bonito.jl` such that users
can embed `Bonito.App`s into rendered pages without having to manually setup
WebSocket connections and handle closing unused sessions. Just add

```
middleware = [bonito_middleware(), ...]
```

to your `Server.prod` and `Server.dev` calls that launch your server. Then
embed `App`s into the rendered HTML from any routes and they will maintain an
open WebSocket with the backend. This is useful for such things as interactive
`WGLMakie` plots.

!!! tip "Response Headers"

    *Use a `Vary: *` header with pages that contain `Bonito` elements.*

    Note that when a user nagivates away from a page that contains an active
    `Bonito.App` the connection will be closed and the server will terminate the
    `Bonito.Session` and all associated assets that were being served for it to
    function. If a user then decides to navigate back to that page with their
    browser nagivation they *may* not get a newly requested page content, which
    means there is no running `Bonito` session to connect to. This is intentional.
    Use a `Vary: *` header for any pages that contain such dynamic content so that
    the browser is forced to do a full refetch of the page content. This will start
    up a new `Bonito` connection and session.

```@autodocs
Modules = [
    ReloadableMiddleware.Extensions,
]
```
