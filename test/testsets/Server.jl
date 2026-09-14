using ReloadableMiddleware
using Revise
using Test

import ReloadableMiddleware.Server

import HTTP
import Sockets

module ServerStreamRoutes

    using ReloadableMiddleware.Router

    import HTTP

    @STREAM "/events" function (stream)
        HTTP.startwrite(stream)
        write(stream, "data: hello\n\n")
        return ""
    end

end

# A handler that streams its own response (SSE) must produce exactly one HTTP
# response on the wire. Writing a second response, or injecting bytes after
# the handler returns, desynchronizes every later response on a keep-alive
# connection.
@testset "Server" begin
    # Collects raw bytes from the socket so assertions can inspect the exact
    # wire format, including any spurious bytes after a response terminator.
    function wire_reader(sock)
        received = IOBuffer()
        @async try
            while !eof(sock)
                write(received, readavailable(sock))
            end
        catch
        end
        return received
    end

    wire_bytes(received) = String(take!(copy(received)))

    # Waits until the received bytes contain `n` chunked-body terminators,
    # then a grace period so trailing spurious bytes get captured.
    function await_responses(received, n; timeout = 60.0, grace = 0.5)
        terminated = timedwait(timeout; pollint = 0.05) do
            count("0\r\n\r\n", wire_bytes(received)) >= n
        end
        sleep(grace)
        return terminated
    end

    function raw_get(sock, port, target)
        write(
            sock,
            "GET $target HTTP/1.1\r\n" *
                "Host: 127.0.0.1:$(port)\r\n" *
                "Accept: text/event-stream\r\n\r\n",
        )
    end

    function assert_single_responses(received, n)
        data = wire_bytes(received)
        @test count("HTTP/1.1", data) == n
        @test count("0\r\n\r\n", data) == n
        @test endswith(data, "0\r\n\r\n")
        return data
    end

    @testset "handler that streams its own response" begin
        handler = function (request)
            stream = request.context[:stream]::HTTP.Stream
            HTTP.setheader(stream, "Content-Type" => "text/event-stream")
            HTTP.startwrite(stream)
            write(stream, "data: hello\n\n")
            return HTTP.Response(200)
        end

        server = HTTP.listen!(Server.stream_handler(handler), 0; listenany = true)
        port = HTTP.port(server)
        sock = Sockets.connect("127.0.0.1", port)
        try
            received = wire_reader(sock)

            raw_get(sock, port, "/events")
            @test await_responses(received, 1) === :ok
            data = assert_single_responses(received, 1)
            @test contains(data, "data: hello")

            # The connection must stay reusable and in sync.
            raw_get(sock, port, "/events")
            @test await_responses(received, 2) === :ok
            assert_single_responses(received, 2)
        finally
            close(sock)
            close(server)
        end
    end

    @testset "handler that returns a plain response" begin
        seen_ip = Ref{Any}(nothing)
        handler = function (request)
            seen_ip[] = request.context[:ip]
            return HTTP.Response(200, "plain")
        end

        logger = Test.TestLogger()
        response = Base.with_logger(logger) do
            server = HTTP.listen!(Server.stream_handler(handler), 0; listenany = true)
            try
                HTTP.get("$(Server.server_url(server))/path")
            finally
                close(server)
            end
        end
        @test response.status == 200
        @test String(response.body) == "plain"
        @test seen_ip[] == Sockets.ip"127.0.0.1"
        access_line = r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2} - 127\.0\.0\.1:\d+ - \"GET /path HTTP/1\.1\" 200$"
        @test any(log -> log.group == :access && occursin(access_line, log.message), logger.logs)
    end

    @testset "STREAM route" begin
        router, _, _ = ReloadableMiddleware.Router.routes([ServerStreamRoutes])

        server = HTTP.listen!(Server.stream_handler(router), 0; listenany = true)
        port = HTTP.port(server)
        sock = Sockets.connect("127.0.0.1", port)
        try
            received = wire_reader(sock)

            raw_get(sock, port, "/events")
            @test await_responses(received, 1) === :ok
            data = assert_single_responses(received, 1)
            @test contains(data, "data: hello")
        finally
            close(sock)
            close(server)
        end
    end

    @testset "reloader stream" begin
        handler = function (request)
            stream = request.context[:stream]::HTTP.Stream
            condition = Threads.Condition()
            @async begin
                sleep(0.2)
                lock(condition) do
                    notify(condition)
                end
            end
            return ReloadableMiddleware.Reloader.reload(stream, condition)
        end

        server = HTTP.listen!(Server.stream_handler(handler), 0; listenany = true)
        port = HTTP.port(server)
        sock = Sockets.connect("127.0.0.1", port)
        try
            received = wire_reader(sock)

            raw_get(sock, port, "/reload")
            @test await_responses(received, 1) === :ok
            data = assert_single_responses(received, 1)
            @test contains(data, "data: reload")
        finally
            close(sock)
            close(server)
        end
    end
end
