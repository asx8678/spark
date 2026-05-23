defmodule Spark.LLM.WaferProvider do
  @moduledoc """
  LLM provider for Wafer AI / OpenAI-compatible API.

  Default base URL: `https://pass.wafer.ai/v1`

  Uses `Req` for HTTP. Supports both synchronous completions
  and SSE streaming via `Spark.LLM.SSEParser`.

  **Safety**: API keys are never logged in full. Error messages
  truncate the key to the first 4 characters.
  """

  @behaviour Spark.LLM.Provider

  @default_base_url "https://pass.wafer.ai/v1"

  @impl true
  def complete(messages, opts) do
    base_url = Map.get(opts, :base_url) || @default_base_url
    model = Map.get(opts, :model) || "deepseek-chat"
    api_key = Map.get(opts, :api_key) || ""

    url = "#{base_url}/chat/completions"

    body = build_body(messages, model, false, opts)
    headers = build_headers(api_key)

    case Req.post(url, json: body, headers: headers, receive_timeout: Map.get(opts, :timeout_ms, 120_000)) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        {:ok, parse_response(response_body)}

      {:ok, %Req.Response{status: 401}} ->
        {:error, {:auth_error, mask_key(api_key)}}

      {:ok, %Req.Response{status: 429, body: body}} ->
        {:error, {:rate_limited, get_retry_after(body)}}

      {:ok, %Req.Response{status: status, body: body}} when status >= 500 ->
        {:error, {:server_error, status, truncate_body(body)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, truncate_body(body)}}

      {:error, reason} ->
        {:error, {:request_error, reason}}
    end
  end

  @impl true
  def stream(messages, opts, callback) do
    base_url = Map.get(opts, :base_url) || @default_base_url
    model = Map.get(opts, :model) || "deepseek-chat"
    api_key = Map.get(opts, :api_key) || ""

    url = "#{base_url}/chat/completions"
    body = build_body(messages, model, true, opts)
    headers = build_headers(api_key)

    _accumulated = %{
      id: nil,
      model: model,
      choices: [%{message: %{role: "assistant", content: ""}}],
      usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    }

    try do
      Req.post!(url,
        json: body,
        headers: headers,
        into: fn {:data, chunk}, {req, acc} ->
          parsed = Spark.LLM.SSEParser.parse_stream(chunk)

          new_acc =
            Enum.reduce(parsed, acc, fn
              {:ok, data}, inner_acc ->
                content = get_in(data, ["choices", Access.at(0), "delta", "content"]) || ""
                if content != "" do
                  callback.({:chunk, %{delta: %{content: content}}})
                end
                inner_acc

              {:done}, inner_acc -> inner_acc
              {:error, _}, inner_acc -> inner_acc
              _, inner_acc -> inner_acc
            end)

          {:cont, req, new_acc}
        end,
        receive_timeout: Map.get(opts, :timeout_ms, 120_000)
      )
      |> then(fn
        %Req.Response{body: final_acc} when is_map(final_acc) ->
          callback.({:done, {:ok, final_acc}})
          {:ok, final_acc}
        _ ->
          {:error, :unexpected_stream_result}
      end)
    rescue
      e ->
      {:error, {:stream_error, Exception.message(e)}}
    end
  end

  # --- Public (for testability) ---

  @doc """
  Parses a raw API response body into normalized response shape.
  """
  @spec parse_response(map()) :: map()
  def parse_response(body) when is_map(body) do
    %{
      id: Map.get(body, "id", "unknown"),
      model: Map.get(body, "model", "unknown"),
      choices: parse_choices(Map.get(body, "choices", [])),
      usage: parse_usage(Map.get(body, "usage", %{}))
    }
  end

  def parse_response(_), do: %{
    id: "unknown", model: "unknown",
    choices: [], usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
  }

  @doc """
  Masks an API key for safe logging. Shows first 4 chars only.
  """
  @spec mask_key(String.t() | nil) :: String.t()
  def mask_key(key) when is_binary(key) and byte_size(key) > 4 do
    String.slice(key, 0, 4) <> "...***"
  end
  def mask_key(_), do: "***"

  # --- Private ---

  defp build_body(messages, model, stream, opts) do
    base = %{model: model, messages: messages, stream: stream}

    Enum.reduce([:temperature, :max_tokens, :top_p, :tools, :tool_choice], base, fn key, acc ->
      case Map.get(opts, key) do
        nil -> acc
        val -> Map.put(acc, key, val)
      end
    end)
  end

  defp build_headers(api_key) do
    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp parse_choices(choices) when is_list(choices) do
    Enum.map(choices, fn choice ->
      %{
        message: %{
          role: get_in(choice, ["message", "role"]) || "assistant",
          content: get_in(choice, ["message", "content"]) || "",
          tool_calls: get_in(choice, ["message", "tool_calls"])
        }
      }
    end)
  end

  defp parse_choices(_), do: []

  defp parse_usage(usage) when is_map(usage) do
    %{
      prompt_tokens: Map.get(usage, "prompt_tokens", 0),
      completion_tokens: Map.get(usage, "completion_tokens", 0),
      total_tokens: Map.get(usage, "total_tokens", 0)
    }
  end

  defp parse_usage(_), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  defp get_retry_after(body) when is_map(body) do
    Map.get(body, "retry_after") || (Map.get(body, "error", %{}) |> Map.get("retry_after"))
  end
  defp get_retry_after(_), do: nil

  defp truncate_body(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp truncate_body(body), do: body
end
