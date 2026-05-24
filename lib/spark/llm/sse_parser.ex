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
      trimmed == "" ->
        :ignore

      # SSE comments / keepalive
      String.starts_with?(trimmed, ":") ->
        :ignore

      # [DONE] sentinel
      trimmed == "data: [DONE]" ->
        {:done}

      trimmed == "data: [DONE]\n" ->
        {:done}

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

  @spec parse_line(term()) :: {:error, term()}
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
    {results, buffer} = parse_stream(raw_bytes, "")

    # parse_stream/1 receives complete data — flush any remaining buffer
    case buffer do
      "" ->
        results

      _ ->
        case parse_line(buffer) do
          :ignore -> results
          {:done} -> stop_on_done(results ++ [{:done}])
          {:ok, parsed} -> results ++ [{:ok, parsed}]
          {:error, reason} -> results ++ [{:error, reason}]
        end
    end
  end

  @doc """
  Parses a raw SSE byte stream with a carry-over buffer.

  When a TCP packet splits a JSON line mid-way, the incomplete
  fragment is kept in `buffer` for the next call. Returns a
  `{results, remaining_buffer}` tuple.

  Example:
      {r1, buf} = parse_stream("data: {\\"cho", "")
      {r2, _}  = parse_stream("ices\\":...}\\n", buf)
  """
  @spec parse_stream(binary(), binary()) ::
          {[{:ok, map()} | {:done} | {:error, term()}], binary()}
  def parse_stream(raw_bytes, buffer)
      when is_binary(raw_bytes) and is_binary(buffer) do
    combined = buffer <> raw_bytes

    {lines_to_parse, remaining_buffer} =
      if String.ends_with?(combined, "\n") do
        {String.split(combined, "\n"), ""}
      else
        parts = String.split(combined, "\n")
        {Enum.drop(parts, -1), List.last(parts)}
      end

    results =
      lines_to_parse
      |> Enum.map(&parse_line/1)
      |> Enum.reject(&(&1 == :ignore))
      |> stop_on_done()

    # If DONE was encountered, discard any remaining buffer
    final_buffer =
      if Enum.any?(results, &match?({:done}, &1)) do
        ""
      else
        remaining_buffer
      end

    {results, final_buffer}
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
