# `Responses`

This module is responsible for serializing returned values from route handlers
into valid `HTTP.Response`s. Any value returned from a handler is supported.
`String`s are content-sniffed using `HTTP.sniff` to determine `Content-Type`.
`Base.Docs.HTML` and `Base.Docs.Text` are set to `text/html` and `text/plain`
respectively. Simple values such as numbers, symbols, and characters are sent
as `text/plain`. Other values are serialized as `application/json` using the
`JSON` package, using the `allownan = true` keyword.

The module exports a `response` helper function that allows for declaring the
intended serialization mime type, along with other options such as `attachment`
and `filename` which effect the `Content-Disposition` header.

```@autodocs
Modules = [
    ReloadableMiddleware.Responses,
]
```
