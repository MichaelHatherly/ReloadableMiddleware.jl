import Bonito
import ReloadableMiddleware.Extensions

@testset "Extensions" begin
    bm = Extensions.bonito_middleware()
    @test isa(bm, Function)
end
