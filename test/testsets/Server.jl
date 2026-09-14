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

    # Runs `f(server, logger)` with the server's logs captured. The server
    # starts under the test logger so its connection tasks inherit it.
    function with_access_log(f, handler)
        logger = Test.TestLogger()
        result = Base.with_logger(logger) do
            server = HTTP.listen!(Server.stream_handler(handler), 0; listenany = true)
            try
                f(server, logger)
            finally
                close(server)
            end
        end
        return result, logger
    end

    access_lines(logger) = [log.message for log in logger.logs if log.group == :access]

    # The exception an escaped handler error was logged with, for failure output.
    function logged_errors(logger)
        return [
            repr(log.kwargs[:exception][1]) for
                log in logger.logs if log.level == Test.Logging.Error
        ]
    end

    access_line(target, status) =
        Regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2} - 127\\.0\\.0\\.1:\\d+ - \"GET $target HTTP/1\\.1\" $status\$")

    @testset "handler that returns a plain response" begin
        seen_ip = Ref{Any}(nothing)
        handler = function (request)
            seen_ip[] = request.context[:ip]
            return HTTP.Response(200, "plain")
        end

        response, logger = with_access_log(handler) do server, _
            HTTP.get("$(Server.server_url(server))/path")
        end
        @test response.status == 200
        @test String(response.body) == "plain"
        @test seen_ip[] == Sockets.ip"127.0.0.1"
        @test any(line -> occursin(access_line("/path", 200), line), access_lines(logger))
    end

    @testset "access log can be silenced" begin
        handler = request -> HTTP.Response(200, "quiet")
        logger = Test.TestLogger()
        response = Base.with_logger(logger) do
            server = HTTP.listen!(Server.stream_handler(handler; access_log = nothing), 0; listenany = true)
            try
                HTTP.get("$(Server.server_url(server))/path")
            finally
                close(server)
            end
        end
        @test response.status == 200
        @test isempty(logger.logs)
    end

    @testset "handler that throws logs a 500" begin
        handler = request -> throw(ErrorException("boom"))

        response, logger = with_access_log(handler) do server, _
            HTTP.get("$(Server.server_url(server))/path"; status_exception = false, retry = false)
        end
        @test response.status == 500
        @test any(line -> occursin(access_line("/path", 500), line), access_lines(logger))
        @test only(logged_errors(logger)) == "ErrorException(\"boom\")"
    end

    @testset "client that disconnects mid-write logs the response status" begin
        handler = function (request)
            sleep(0.5)
            return HTTP.Response(200, "x"^(64 * 1024 * 1024))
        end

        _, logger = with_access_log(handler) do server, logger
            port = HTTP.port(server)
            sock = Sockets.connect("127.0.0.1", port)
            raw_get(sock, port, "/path")
            close(sock)
            timedwait(30.0; pollint = 0.1) do
                any(log -> log.group == :access, logger.logs)
            end
        end
        @test logged_errors(logger) == []
        @test any(line -> occursin(access_line("/path", 200), line), access_lines(logger))
    end

    @testset "handlers run in the latest world" begin
        Core.eval(@__MODULE__, :(world_probe() = "before"))
        handler = request -> HTTP.Response(200, world_probe())

        response, _ = with_access_log(ReloadableMiddleware.Reviser.ReviseMiddleware(handler)) do server, _
            Core.eval(@__MODULE__, :(world_probe() = "after"))
            HTTP.get("$(Server.server_url(server))/path")
        end
        @test String(response.body) == "after"
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
