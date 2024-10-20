using ReloadableMiddleware
using Test

using ReloadableMiddleware.Browser

@testset "Browser" begin
    withenv("CI" => "true") do
        @test_logs (:info, "CI system detected, skip opening browser.") Browser.browser("http://localhost:8080")
    end
end
