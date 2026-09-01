defmodule Eva.Extension.DesktopMac.HelperTest do
  use ExUnit.Case, async: true

  alias Eva.Extension.DesktopMac.Helper

  defp fake_helper(mode) do
    elixir = System.find_executable("elixir") || "elixir"
    script = Path.expand("test/support/fake_helper.exs")
    {elixir, [script, mode]}
  end

  defp start_helper(name, mode) do
    start_supervised!({Helper, [name: name, command: fake_helper(mode)]})
    :ok
  end

  test "correlates a response by request id" do
    start_helper(:correlate, "normal")

    assert {:ok, %{"fake" => true, "method" => "status"}} =
             Helper.request(:correlate, "status", %{}, 5_000)
  end

  test "reassembles a response fragmented across chunks" do
    start_helper(:frag, "fragment")

    assert {:ok, %{"pong" => true}} = Helper.request(:frag, "ping", %{}, 5_000)
  end

  test "ignores a malformed frame and times out the pending request" do
    start_helper(:mal, "malformed")

    assert {:error, :request_timeout} = Helper.request(:mal, "ping", %{}, 200)
  end

  test "times out when the helper never responds" do
    start_helper(:silent, "silent")

    assert {:error, :request_timeout} = Helper.request(:silent, "ping", %{}, 100)
  end

  test "fails a pending request with the exit reason when the helper crashes" do
    start_helper(:crash, "exit")

    assert {:error, {:helper_exited, status}} = Helper.request(:crash, "ping", %{}, 5_000)
    assert status != 0
  end

  test "reports a clean stop and does not relaunch" do
    start_helper(:clean, "exit_clean")

    assert {:error, :helper_stopped} = Helper.request(:clean, "ping", %{}, 5_000)
  end

  test "returns an error immediately when the helper is unavailable" do
    start_supervised!({Helper, [name: :disabled_helper, command: :disabled]})

    assert {:error, :helper_unavailable} = Helper.request(:disabled_helper, "status", %{}, 5_000)
  end
end
