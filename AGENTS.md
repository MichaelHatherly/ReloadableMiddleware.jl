# ReloadableMiddleware

Julia HTTP middleware package providing hot-reloading dev server, routing, error handling, and docs.

## Project Structure

- `src/ReloadableMiddleware.jl` — main module, includes all submodules
- `src/modules/` — submodules: Router, Server, Responses, Errors, Docs, Browser, Context, FileWatching, Reloader, Reviser, Extensions
- `ext/` — package extensions for Bonito and Revise
- `test/testsets/` — test files mirror module names

## Development

### Formatting

Uses [Runic.jl](https://github.com/fredrikekre/Runic.jl) (zero-config formatter).

```bash
just format
```

### Testing

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

### Conventions

- Submodules are `include`d from `ReloadableMiddleware.jl`, not separate packages
- HTTP.jl is the web framework foundation
- `dev()` starts a hot-reloading dev server, `prod()` starts a production server
- Run `just format` before every commit
