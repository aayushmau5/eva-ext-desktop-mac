defmodule Eva.Extension.DesktopMac.Application do
  @moduledoc """
  Everything this extension needs to run, owned by this extension.

  The `Helper` is one global process shared by every session attached to this extension
  node: the helper and its macOS automation state are machine-global, so per-session
  helpers would be misleading and could race each other. `Eva.Core.Extension.Node` is what
  makes this VM an extension node, found by Eva as `desktop_mac`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Eva.Extension.DesktopMac.Helper,
      {Eva.Core.Extension.Node, node_options()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  # `config :eva_desktop_mac, cluster: [...]` overrides the node options, which is
  # occasionally useful and always useful in tests.
  defp node_options do
    Keyword.merge(
      [name: "desktop_mac", module: Eva.Extension.DesktopMac],
      Application.get_env(:eva_desktop_mac, :cluster, [])
    )
  end
end
