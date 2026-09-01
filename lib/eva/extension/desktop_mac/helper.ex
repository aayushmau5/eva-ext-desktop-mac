defmodule Eva.Extension.DesktopMac.Helper do
  @moduledoc """
  The single process that owns the native `EvaDesktopHelper.app`.

  One helper per extension node, shared by every session. It launches the native helper,
  owns its stdin/stdout `Port`, serializes requests through it, and converts responses
  into results the tools can turn into `Eva.Core.Agent.Tools.AgentToolResult`s.

  The native helper processes one request at a time; this GenServer correlates responses
  by monotonically increasing request ID and replies asynchronously, so a slow helper does
  not block the caller on an Erlang-level `call` timeout.
  """

  use GenServer

  require Logger

  alias Eva.Extension.DesktopMac.Protocol

  @default_timeout 30_000
  @relaunch_delay 1_000
  @max_crashes 5

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec status(timeout()) :: {:ok, map()} | {:error, term()}
  def status(timeout \\ @default_timeout), do: request(__MODULE__, "status", %{}, timeout)

  @spec observe(map(), timeout()) :: {:ok, map()} | {:error, term()}
  def observe(args, timeout \\ @default_timeout) when is_map(args),
    do: request(__MODULE__, "observe", args, timeout)

  @spec action(map(), timeout()) :: {:ok, map()} | {:error, term()}
  def action(args, timeout \\ @default_timeout) when is_map(args),
    do: request(__MODULE__, "action", args, timeout)

  @doc """
  Sends a request to a specific helper server. Tests start a named Helper with a fake
  command and call this directly; the `status/observe/action` wrappers target the global
  helper.
  """
  @spec request(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def request(server, method, params, timeout) when is_map(params) do
    GenServer.call(server, {:request, method, params, timeout}, timeout + 5_000)
  end

  @impl true
  def init(opts) do
    command = Keyword.get(opts, :command) || configured_command()

    case launch(command) do
      {:ok, port} -> {:ok, new_state(port, :running, command)}
      {:error, reason} -> {:ok, new_state(nil, {:error, reason}, command)}
    end
  end

  @impl true
  def handle_call({:request, method, params, timeout}, from, state) do
    case state.status do
      :running -> send_request(method, params, timeout, from, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, buffer} = Protocol.split_lines(state.buffer, data)

    if byte_size(buffer) > Protocol.max_frame_bytes() do
      Logger.error(
        "desktop helper: incomplete response exceeded #{Protocol.max_frame_bytes()} bytes; discarding"
      )

      {:noreply, %{state | buffer: ""}}
    else
      state =
        Enum.reduce(lines, %{state | buffer: buffer}, fn line, acc ->
          if byte_size(line) <= Protocol.max_frame_bytes() do
            handle_frame(line, acc)
          else
            Logger.error(
              "desktop helper: response exceeded #{Protocol.max_frame_bytes()} bytes; discarding"
            )

            acc
          end
        end)

      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = fail_pending(state, exit_reason(status))

    if status == 0 do
      # Clean, user-requested quit: do not relaunch.
      Logger.info("desktop helper: stopped (clean exit)")
      {:noreply, %{state | port: nil, status: {:error, :helper_stopped}}}
    else
      Logger.error("desktop helper: exited with status #{status}")

      {:noreply,
       schedule_relaunch(%{state | port: nil, status: {:error, {:helper_exited, status}}})}
    end
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, :request_timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(:relaunch, state) do
    case state.status do
      :running ->
        {:noreply, state}

      {:error, :helper_stopped} ->
        {:noreply, state}

      {:error, _reason} ->
        case launch(state.command) do
          {:ok, port} ->
            Logger.info("desktop helper: relaunched")
            {:noreply, %{new_state(port, :running, state.command) | restarts: state.restarts}}

          {:error, reason} ->
            {:noreply, schedule_relaunch(%{state | status: {:error, reason}})}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_port(state.port), do: Port.close(state.port)
    :ok
  end

  # -- Private --

  defp new_state(port, status, command) do
    %{
      port: port,
      buffer: "",
      pending: %{},
      next_id: 1,
      status: status,
      command: command,
      restarts: 0
    }
  end

  defp configured_command do
    case Application.get_env(:eva_desktop_mac, :helper, :default) do
      :default -> default_command()
      :disabled -> :disabled
      command -> command
    end
  end

  defp default_command do
    case :code.priv_dir(:eva_desktop_mac) do
      {:error, _} ->
        {:error, :helper_not_found}

      dir ->
        bin = Path.join([dir, "EvaDesktopHelper.app", "Contents", "MacOS", "EvaDesktopHelper"])

        if File.regular?(bin),
          do: {:ok, bin},
          else: {:error, {:helper_not_found, bin}}
    end
  end

  defp launch(:disabled), do: {:error, :helper_unavailable}

  defp launch({cmd, args}) when is_binary(cmd) and is_list(args), do: open_port(cmd, args)

  defp launch({:ok, cmd}) when is_binary(cmd), do: open_port(cmd, [])

  defp launch({:error, _reason} = error), do: error

  defp launch(other), do: {:error, {:invalid_helper_command, other}}

  defp open_port(cmd, args) do
    {:ok, Port.open({:spawn_executable, cmd}, [:binary, :exit_status, {:args, args}])}
  rescue
    e -> {:error, {:spawn_failed, Exception.message(e)}}
  end

  defp send_request(method, params, timeout, from, state) do
    id = state.next_id
    data = Protocol.encode_request(id, method, params)

    try do
      true = Port.command(state.port, data)
      timer = Process.send_after(self(), {:request_timeout, id}, timeout)
      pending = Map.put(state.pending, id, %{from: from, timer: timer})
      {:noreply, %{state | next_id: id + 1, pending: pending}}
    rescue
      _e ->
        {:reply, {:error, :helper_unavailable}, %{state | status: {:error, :helper_unavailable}}}
    end
  end

  defp handle_frame(line, state) do
    case Protocol.decode(line) do
      {:ok, %{"id" => id} = frame} when is_integer(id) ->
        handle_response(id, frame, state)

      {:ok, _frame} ->
        Logger.error("desktop helper: response frame with no id")
        state

      {:error, reason} ->
        Logger.error("desktop helper: malformed frame #{inspect(reason)}")
        state
    end
  end

  defp handle_response(id, frame, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        Logger.warning("desktop helper: response for unknown request #{id}")
        state

      {%{from: from, timer: timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, parse_response(frame))
        %{state | pending: pending, restarts: 0}
    end
  end

  defp parse_response(%{"ok" => true, "result" => result}), do: {:ok, result}

  defp parse_response(%{"ok" => false, "error" => %{"code" => code, "message" => message}})
       when is_binary(code) and is_binary(message),
       do: {:error, {:helper_error, code, message}}

  defp parse_response(%{"ok" => false} = frame),
    do: {:error, {:helper_error, "invalid_request", inspect(frame)}}

  defp parse_response(other), do: {:error, {:helper_error, "invalid_request", inspect(other)}}

  defp fail_pending(state, reason) do
    Enum.each(state.pending, fn {_id, %{from: from, timer: timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending: %{}}
  end

  defp schedule_relaunch(%{restarts: restarts} = state) when restarts >= @max_crashes do
    Logger.error("desktop helper: too many crashes; giving up")
    %{state | status: {:error, :helper_unavailable}}
  end

  defp schedule_relaunch(state) do
    Process.send_after(self(), :relaunch, @relaunch_delay)
    %{state | restarts: state.restarts + 1}
  end

  defp exit_reason(0), do: :helper_stopped
  defp exit_reason(status), do: {:helper_exited, status}
end
