defmodule Eva.Extension.DesktopMac do
  @moduledoc """
  A macOS desktop extension: observe the screen, inspect the accessibility hierarchy,
  and act on controls with clicks, keys, text, scroll, and drag.

  The extension is stateless: `setup/1` returns the three tools, whose executors talk to
  the single machine-global `Eva.Extension.DesktopMac.Helper` process. That helper owns a
  `Port` to the native `EvaDesktopHelper.app`, which is where macOS permissions and
  automation state live.
  """

  use Eva.Core.Extension

  alias Eva.Core.Extension.Spec
  alias Eva.Extension.DesktopMac.Tools

  @impl true
  def setup(_ctx) do
    {:ok, %Spec{tools: Tools.definitions(), guidelines: Tools.guidelines()}}
  end
end
