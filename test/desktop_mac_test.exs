defmodule Eva.Extension.DesktopMacTest do
  use ExUnit.Case, async: true

  alias Eva.Core.Agent.Messages
  alias Eva.Extension.DesktopMac
  alias Eva.Extension.DesktopMac.Tools

  test "exposes exactly the three desktop tools" do
    assert Tools.definitions() |> Enum.map(& &1.name) ==
             ["desktop_status", "desktop_observe", "desktop_action"]
  end

  test "every tool is sequential" do
    assert Enum.all?(Tools.definitions(), &(&1.execution_mode == :sequential))
  end

  test "every tool has a description and an input schema" do
    for tool <- Tools.definitions() do
      assert is_binary(tool.description) and tool.description != ""
      assert is_map(tool.input_schema)
    end
  end

  test "desktop_status takes no arguments" do
    status = Enum.find(Tools.definitions(), &(&1.name == "desktop_status"))

    assert status.input_schema == %{
             "type" => "object",
             "properties" => %{},
             "additionalProperties" => false
           }
  end

  test "desktop_action declares the supported kinds" do
    action = Enum.find(Tools.definitions(), &(&1.name == "desktop_action"))
    kinds = get_in(action.input_schema, ["properties", "kind", "enum"])

    assert kinds == ["click", "type", "key", "press", "scroll", "wait", "double_click", "drag"]
  end

  test "desktop_action advertises common key aliases" do
    action = Enum.find(Tools.definitions(), &(&1.name == "desktop_action"))
    description = get_in(action.input_schema, ["properties", "keys", "description"])

    assert description =~ "ENTER"
    assert description =~ "RETURN"
  end

  test "desktop_action requires kind and observation_id" do
    action = Enum.find(Tools.definitions(), &(&1.name == "desktop_action"))
    assert action.input_schema["required"] == ["kind", "observation_id"]
  end

  test "guidelines warn about untrusted screen content" do
    assert Enum.any?(Tools.guidelines(), &String.contains?(&1, "prompt-injection"))
    assert Enum.any?(Tools.guidelines(), &String.contains?(&1, "Never rescale"))
    assert Enum.any?(Tools.guidelines(), &String.contains?(&1, "target ref"))
  end

  test "keeps only the latest desktop observation in provider context" do
    assert {:ok, %{hooks: [:context]}} = DesktopMac.setup(%{})

    old_desktop_result = %Messages.ToolResultMessage{
      tool_name: "desktop_observe",
      content: [
        %Messages.TextContent{text: "old desktop metadata"},
        %Messages.ImageContent{data: "old-desktop-image", mime_type: "image/png"}
      ]
    }

    other_tool_result = %Messages.ToolResultMessage{
      tool_name: "other_tool",
      content: [
        %Messages.ImageContent{data: "other-tool-image", mime_type: "image/png"}
      ]
    }

    latest_desktop_result = %Messages.ToolResultMessage{
      tool_name: "desktop_action",
      content: [
        %Messages.TextContent{text: "latest desktop metadata"},
        %Messages.ImageContent{data: "latest-desktop-image", mime_type: "image/png"}
      ]
    }

    messages = [old_desktop_result, other_tool_result, latest_desktop_result]

    assert {{:ok, transformed}, :state} =
             DesktopMac.handle_hook(:context, messages, :state)

    assert [old_result, ^other_tool_result, ^latest_desktop_result] = transformed
    assert old_result.content == [%Messages.TextContent{text: "Superseded desktop observation."}]
    assert old_desktop_result.content != old_result.content
  end

  test "observation results expose image content without duplicating base64 in details" do
    result =
      Tools.result("desktop_observe", {
        :ok,
        %{
          "observation_id" => "o1",
          "image" => %{"mime_type" => "image/jpeg", "width" => 10, "height" => 5},
          "screenshot_base64" => "aGVsbG8="
        }
      })

    assert [
             %Messages.TextContent{},
             %Messages.ImageContent{data: "aGVsbG8=", mime_type: "image/jpeg"}
           ] = result.content

    refute Map.has_key?(result.details, "screenshot_base64")
    assert result.details["observation_id"] == "o1"
  end

  test "desktop_action rejects missing kind-specific arguments before calling the helper" do
    action = Enum.find(Tools.definitions(), &(&1.name == "desktop_action"))
    result = action.executor.(%{"kind" => "click", "observation_id" => "o1"}, %{})

    assert result.details == %{"error" => "invalid_arguments", "tool" => "desktop_action"}
    assert [%Messages.TextContent{text: text}] = result.content
    assert text =~ "requires target or x and y"
  end

  test "desktop_action rejects unsupported keys before calling the helper" do
    action = Enum.find(Tools.definitions(), &(&1.name == "desktop_action"))

    result =
      action.executor.(
        %{"kind" => "key", "observation_id" => "o1", "keys" => ["HYPER", "K"]},
        %{}
      )

    assert result.details["error"] == "invalid_arguments"
    assert [%Messages.TextContent{text: text}] = result.content
    assert text =~ "unsupported key"
  end
end
