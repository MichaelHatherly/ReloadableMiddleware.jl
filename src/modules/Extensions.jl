module Extensions

#
# Imports:
#

import HTTP

#
# Exports:
#

export bonito_middleware

#
# Exceptions:
#

struct ExtensionError <: Exception
    msg::String
end

#
# Bonito extension interface:
#

"""
    bonito_middleware(; [prefix::String])

Add this to your server middleware stack to handle `Bonito.jl` connections. The
`prefix` keyword can be used to customise Bonito handling endpoints. By default
if is an auto-generated string that should not conflict with any typically
named routes.

Ensure that `Bonito` is manually imported into your Julia server process rather
than assuming that a 3rd-party package has already imported it.

Once added to your `middleware` stack of your `dev` and `prod` server calls you
can embed `Bonito.App` objects into rendered HTML views and they will
transpartently connect to the server without additional setup.
`HypertextTemplates.jl` provides out-of-the-box integration with `Bonito.App`
objects such that you can simply interpolate them into the element macros.
"""
function bonito_middleware(; prefix::String = _bonito_prefix())
    startswith(prefix, "/") || ArgumentError("`prefix` must start with a `/`.")
    endswith(prefix, "/") && ArgumentError("`prefix` must not end with a `/`.")
    return _bonito_middleware(nothing, prefix)
end

function _bonito_prefix()
    uid = string(rand(UInt); base = 62)
    return "/bonito-$uid"
end

# The real implementation is located in the `Bonito` extension module.
function _bonito_middleware(::Any, ::String)
    throw(ExtensionError("`Bonito.jl` is not loaded into your process."))
end

end
