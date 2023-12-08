import Pkg

Pkg.activate(@__DIR__)

import TailwindCSS
task = TailwindCSS.watch(; after_rebuild = () -> @info "Build finished.")
