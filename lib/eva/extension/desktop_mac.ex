defmodule Eva.Extension.DesktopMac do
  @moduledoc """
  A macOS desktop extension: observe the screen, inspect the accessibility hierarchy,
  and act on controls with clicks, keys, text, scroll, and drag.

  Tool executors talk to the single machine-global `Eva.Extension.DesktopMac.Helper`
  process. That helper owns a `Port` to the native `EvaDesktopHelper.app`, which is where
  macOS permissions and automation state live. A context hook removes superseded desktop
  screenshots from provider requests without changing the saved transcript.
  """

  use Eva.Core.Extension

  alias Eva.Core.Extension.Spec
  alias Eva.Extension.DesktopMac.Tools

  @observation_tools ~w(desktop_observe desktop_action)

  @impl true
  def setup(_ctx) do
    {:ok,
     %Spec{
       tools: Tools.definitions(),
       guidelines: Tools.guidelines(),
       hooks: [:context]
     }}
  end

  @impl true
  def handle_hook(:context, messages, state) do
    {{:ok, keep_latest_desktop_observation(messages)}, state}
  end

  defp keep_latest_desktop_observation(messages) do
    latest_index =
      messages
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {message, index}, latest ->
        if desktop_image_result?(message), do: index, else: latest
      end)

    messages
    |> Enum.with_index()
    |> Enum.map(fn
      {%Messages.ToolResultMessage{tool_name: tool_name} = message, index}
      when tool_name in @observation_tools and index != latest_index ->
        if desktop_image_result?(message) do
          %{message | content: [%Messages.TextContent{text: "Superseded desktop observation."}]}
        else
          message
        end

      {message, _index} ->
        message
    end)
  end

  defp desktop_image_result?(%Messages.ToolResultMessage{
         tool_name: tool_name,
         content: content
       })
       when tool_name in @observation_tools do
    Enum.any?(content, &match?(%Messages.ImageContent{}, &1))
  end

  defp desktop_image_result?(_message), do: false
end
