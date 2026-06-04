using ReloadableMiddleware
using Test

import HTTP
import Sockets

@testset "Server" begin
    @testset "stream_handler writes one response per request" begin
        # A middleware with two routes: one streams the response itself
        # through `request.context[:stream]` (the SSE pattern used by STREAM
        # routes and MCP), one returns a plain response for the adapter to
        # write.
        middleware = function (request::HTTP.Request)
            if request.target == "/sse"
                stream = request.context[:stream]::HTTP.Stream
                HTTP.setstatus(stream, 200)
                HTTP.setheader(stream, "Content-Type" => "text/event-stream")
                HTTP.startwrite(stream)
                write(stream, "data: hello\n\n")
                return request.response
            else
                return HTTP.Response(200, "plain")
            end
        end

        port = let
            listener = Sockets.listen(Sockets.localhost, 0)
            p = Int(Sockets.getsockname(listener)[2])
            close(listener)
            p
        end

        server = HTTP.serve!(
            ReloadableMiddleware.Server.stream_handler(middleware),
            "127.0.0.1",
            port;
            stream = true,
            verbose = -1,
        )

        sock = Sockets.connect("127.0.0.1", port)
        received = IOBuffer()
        @async try
            while !eof(sock)
                write(received, readavailable(sock))
            end
        catch
        end

        wire() = String(take!(copy(received)))

        # Wait until the received bytes contain `n` chunked terminators, then
        # a grace period so spurious trailing bytes get captured too.
        function await_terminators(n)
            timedwait(30.0; pollint = 0.05) do
                count("0\r\n\r\n", wire()) >= n
            end
            sleep(0.5)
        end

        try
            write(sock, "GET /sse HTTP/1.1\r\nHost: 127.0.0.1:$(port)\r\n\r\n")
            await_terminators(1)

            first_response = wire()
            @test count("HTTP/1.1", first_response) == 1
            @test count("0\r\n\r\n", first_response) == 1
            @test occursin("data: hello", first_response)

            # Reuse the connection. Any spurious bytes from the first
            # response desync this one.
            write(sock, "GET /plain HTTP/1.1\r\nHost: 127.0.0.1:$(port)\r\n\r\n")
            await_terminators(2)

            full = wire()
            second_response = full[(sizeof(first_response) + 1):end]
            @test startswith(second_response, "HTTP/1.1 200 OK\r\n")
            @test occursin("plain", second_response)
        finally
            close(sock)
            close(server)
        end
    end
end
