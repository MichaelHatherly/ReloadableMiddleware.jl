module ReloadableMiddlewareReviseExt

import ReloadableMiddleware.Reviser
import Revise

function Reviser.revise_middleware(::Nothing, handler, req)
    mod = (; revise = Revise.revise, revision_queue = Revise.revision_queue)
    return Reviser.revise_middleware(mod, handler, req)
end

end
