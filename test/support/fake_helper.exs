# A fake native helper for transport tests. Reads newline-delimited JSON requests on
# stdin and writes newline-delimited JSON responses on stdout, like EvaDesktopHelper.
#
# Usage: elixir fake_helper.exs <mode>
#
# Modes:
#   normal     — respond to every request with a canned ok result
#   fragment   — write each response in several small chunks (exercises buffering)
#   malformed  — write a non-JSON line (exercises malformed-frame handling)
#   silent     — read forever, never respond (exercises timeouts)
#   exit       — exit immediately with a non-zero status (exercises crash handling)
#   exit_clean — exit immediately with status 0 (exercises clean-stop handling)

mode = System.argv() |> List.first() || "normal"

defmodule FakeHelper do
  def run(mode) do
    case mode do
      "exit" -> exit_after_line(1)
      "exit_clean" -> exit_after_line(0)
      "silent" -> silent_loop()
      _ -> loop(mode)
    end
  end

  # Block on the request line, then exit, so the port is provably open when the request
  # arrives and the exit is a consequence of the request rather than a startup race.
  defp exit_after_line(code) do
    case IO.read(:stdio, :line) do
      :eof -> System.halt(code)
      {:error, _reason} -> System.halt(code)
      _data -> System.halt(code)
    end
  end

  defp loop(mode) do
    case IO.read(:stdio, :line) do
      :eof ->
        System.halt(0)

      {:error, _reason} ->
        System.halt(0)

      data ->
        handle_line(mode, data)
        loop(mode)
    end
  end

  defp silent_loop do
    case IO.read(:stdio, :line) do
      :eof -> System.halt(0)
      {:error, _reason} -> System.halt(0)
      _data -> silent_loop()
    end
  end

  defp handle_line(mode, line) do
    case JSON.decode(line) do
      {:ok, %{"id" => id, "method" => method}} when is_integer(id) ->
        respond(mode, id, method)

      _ ->
        safe_write(
          ~s({"id":0,"ok":false,"error":{"code":"invalid_request","message":"bad request"}}\n)
        )
    end
  end

  defp respond(mode, id, method) do
    case mode do
      "malformed" ->
        safe_write("this is not json\n")

      "fragment" ->
        json = JSON.encode!(%{"id" => id, "ok" => true, "result" => result_for(method)}) <> "\n"
        n = byte_size(json)
        mid = div(n, 3)
        safe_write(binary_part(json, 0, mid))
        Process.sleep(5)
        safe_write(binary_part(json, mid, n - mid))

      _ ->
        safe_write(
          JSON.encode!(%{"id" => id, "ok" => true, "result" => result_for(method)}) <> "\n"
        )
    end
  end

  # The port can be closed out from under us during test teardown; ignore the EPIPE.
  defp safe_write(data) do
    try do
      IO.write(data)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp result_for("status"), do: %{"fake" => true, "method" => "status"}
  defp result_for("ping"), do: %{"pong" => true}
  defp result_for(other), do: %{"fake" => true, "method" => other}
end

FakeHelper.run(mode)
