defmodule Spark.LLM.SSEParser do
  @moduledoc """
  Parse OpenAI-compatible Server-Sent Events (SSE) streaming chunks.

  Pure, stateless module. Handles the `data: {...}` format used by
  OpenAI, Wafer AI, and compatible APIs.
  """

  @doc """
  Parses a single SSE line.

  Returns:
    - `{:ok, parsed_map}` — valid JSON data line
    - `{:done}` — `data: [DONE]` sentinel
    - `:ignore` — empty lines, comments, keepalives
    - `{:error, reason}` — malformed data
  """
  @spec parse_line(String.t()) ::
          {:ok, map()} | {:done} | :ignore | {:error, term()}
  def parse_line(line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      # Empty lines
      trimmed == "" -> :ignore

      # SSE comments / keepalive
      String.starts_with?(trimmed, ":") -> :ignore

      # [DONE] sentinel
      trimmed == "data: [DONE]" -> {:done}
      trimmed == "data: [DONE]\n" -> {:done}

      # Data line with JSON
      String.starts_with?(trimmed, "data: ") ->
        json_str = String.trim_leading(trimmed, "data: ")

        case Jason.decode(json_str) do
          {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
          {:ok, _} -> {:error, {:unexpected_json_type, json_str}}
          {:error, reason} -> {:error, {:json_decode_error, reason}}
        end

      # Data line without space (non-standard but some APIs do this)
      String.starts_with?(trimmed, "data:") ->
        json_str = String.trim_leading(trimmed, "data:")

        # Could be [DONE] without space
        if String.trim(json_str) == "[DONE]" do
          {:done}
        else
          case Jason.decode(String.trim(json_str)) do
            {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
            {:ok, _} -> {:error, {:unexpected_json_type, json_str}}
            {:error, reason} -> {:error, {:json_decode_error, reason}}
          end
        end

      # Unknown line format
      true ->
        :ignore
    end
  end

  def parse_line(_), do: {:error, :invalid_input}

  @doc """
  Parses a raw SSE byte stream, splitting on newlines and
  parsing each line. Returns a list of parsed results,
  filtering out `:ignore` entries.

  Stops parsing if `{:done}` is encountered (does not include
  `{:done}` in results, but includes it in the return as the
  final element for completeness).
  """
  @spec parse_stream(binary()) :: [{:ok, map()} | {:done} | {:error, term()}]
  def parse_stream(raw_bytes) when is_binary(raw_bytes) do
    raw_bytes
    |> String.split("\n")
    |> Enum.map(&parse_line/1)
    |> Enum.reject(&(&1 == :ignore))
    |> stop_on_done()
  end

  defp stop_on_done(results) do
    case Enum.split_while(results, fn
      {:done} -> false
      _ -> true
    end) do
      {before_done, [{:done} | _rest]} -> before_done ++ [{:done}]
      {before_done, []} -> before_done
    end
  end
end
