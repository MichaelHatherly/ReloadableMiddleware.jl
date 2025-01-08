# `Context`

Context middleware allows for the storage of arbitrary data that can be
accessed by request handlers. This is useful for storing data that is shared
between all routes, such as a database connection pool.

```@autodocs
Modules = [
    ReloadableMiddleware.Context,
]
```
