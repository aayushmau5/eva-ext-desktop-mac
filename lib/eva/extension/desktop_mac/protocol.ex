defmodule Eva.Extension.DesktopMac.Protocol do
  @moduledoc """
  Newline-delimited JSON framing for the helper port.

  The native helper writes one JSON object per line to stdout. Bytes arrive in arbitrary
  chunks — a single frame can span several `{:data, ...}` messages, and one chunk can hold
  several frames — so `split_lines/2` holds whatever is left over after the last newline.
  """

  @max_frame_bytes 32 * 1024 * 1024

  @spec encode_request(pos_integer(), String.t(), map()) :: binary()
  def encode_request(id, method, params)
      when is_integer(id) and is_binary(method) and is_map(params) do
    JSON.encode!(%{"id" => id, "method" => method, "params" => params}) <> "\n"
  end

  @doc """
  Appends `data` to `buffer` and cuts it at every newline.

  Returns the complete lines and the trailing incomplete remainder. Blank lines are
  dropped rather than passed on to be decoded.
  """
  @spec split_lines(binary(), binary()) :: {[binary()], binary()}
  def split_lines(buffer, data) when is_binary(buffer) and is_binary(data) do
    {complete, [remainder]} =
      (buffer <> data)
      |> String.split("\n")
      |> Enum.split(-1)

    {Enum.reject(complete, &(&1 == "")), remainder}
  end

  @doc """
  Decodes one protocol frame. A frame must be a JSON object.
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(line) when is_binary(line) do
    case JSON.decode(line) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, other} -> {:error, {:not_a_map, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The maximum number of bytes the helper may write for a single response line.
  """
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @max_frame_bytes
end
