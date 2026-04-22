import Bonito
import ReloadableMiddleware.Extensions

@testset "Extensions" begin
    bm = Extensions.bonito_middleware()
    @test isa(bm, Function)

    @testset "BinaryAsset session id" begin
        ext = Base.get_extension(ReloadableMiddleware, :ReloadableMiddlewareBonitoExt)
        session = Bonito.Session(Bonito.NoConnection(); asset_server = Bonito.NoServer())
        asset = Bonito.BinaryAsset(session, Dict(:payload => "hello"))
        @test ext._get_asset_session_id(asset) == session.id

        unrelated = Bonito.BinaryAsset(UInt8[0x00, 0x01, 0x02], "application/octet-stream")
        @test ext._get_asset_session_id(unrelated) === nothing
    end
end
