defmodule Eva.Extension.DesktopMac.ProtocolTest do
  use ExUnit.Case, async: true

  alias Eva.Extension.DesktopMac.Protocol

  describe "split_lines/2" do
    test "returns no lines for empty input" do
      assert Protocol.split_lines("", "") == {[], ""}
    end

    test "splits a single complete line" do
      assert Protocol.split_lines("", "{\"a\":1}\n") == {["{\"a\":1}"], ""}
    end

    test "preserves a trailing incomplete frame" do
      assert Protocol.split_lines("", "{\"a\":1") == {[], "{\"a\":1"}
    end

    test "reassembles a frame fragmented across chunks" do
      {lines, buf} = Protocol.split_lines("", "{\"a")
      assert lines == []
      assert buf == "{\"a"

      {lines, buf} = Protocol.split_lines(buf, "\":1}\n{\"b")
      assert lines == ["{\"a\":1}"]
      assert buf == "{\"b"
    end

    test "handles multiple frames in one chunk" do
      assert Protocol.split_lines("", "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n") ==
               {["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"], ""}
    end

    test "drops blank lines" do
      assert Protocol.split_lines("", "{\"a\":1}\n\n\n{\"b\":2}\n") ==
               {["{\"a\":1}", "{\"b\":2}"], ""}
    end

    test "carries the trailing remainder into the next call" do
      {_, buf} = Protocol.split_lines("", "{\"a\":1}\npartial")
      assert buf == "partial"
    end
  end

  describe "decode/1" do
    test "decodes a JSON object" do
      assert {:ok, %{"id" => 1}} = Protocol.decode("{\"id\":1}")
    end

    test "rejects non-object JSON" do
      assert {:error, {:not_a_map, _}} = Protocol.decode("[1,2,3]")
    end

    test "rejects malformed JSON" do
      assert {:error, _reason} = Protocol.decode("this is not json")
    end
  end

  describe "encode_request/3" do
    test "encodes a newline-terminated JSON object" do
      encoded = Protocol.encode_request(1, "ping", %{})
      assert String.ends_with?(encoded, "\n")
      assert {:ok, %{"id" => 1, "method" => "ping", "params" => %{}}} = JSON.decode(encoded)
    end
  end
end
