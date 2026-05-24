defmodule Spark.LLM.WaferProvider do
  @moduledoc """
  LLM provider for Wafer AI / OpenAI-compatible API.

  Default base URL: `https://pass.wafer.ai/v1`

  Uses `Req` for HTTP. Supports both synchronous completions
  and SSE streaming via `Spark.LLM.SSEParser`.

  **Resilience**: Circuit breaker (`Spark.LLM.CircuitBreaker`) and
  rate limiter (`Spark.LLM.RateLimiter`) are checked before every
  HTTP call. The circuit breaker tracks 5xx / timeout / connection
  errors but ignores 4xx client errors. Streaming calls are
  wrapped with `Task.async` / `Task.await` timeout protection.

  **Safety**: API keys are never logged in full. Error messages
  truncate the key to the first 4 characters.
  """

  @behaviour Spark.LLM.Provider

  require Logger

  @default_base_url "https://pass.wafer.ai/v1"
  @default_timeout_ms 120_000

  @impl true
  @spec complete([map()], map()) :: {:ok, map()} | {:error, term()}
  def complete(messages, opts) do
    Logger.metadata(provider: :wafer, model: Map.get(opts, :model) || "deepseek-chat")

    with :ok <- check_circuit(),
         :ok <- check_rate_limit() do
      do_complete(messages, opts)
    end
  end

  @impl true
  @spec stream([map()], map(), function()) :: {:ok, map()} | {:error, term()}
  def stream(messages, opts, callback) do
    Logger.metadata(provider: :wafer, model: Map.get(opts, :model) || "deepseek-chat")

    with :ok <- check_circuit(),
         :ok <- check_rate_limit() do
      do_stream(messages, opts, callback)
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

  def parse_response(_),
    do: %{
      id: "unknown",
      model: "unknown",
      choices: [],
      usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    }

  @doc """
  Masks an API key for safe logging. Shows first 4 chars only.
  """
  @spec mask_key(String.t() | nil) :: String.t()
  def mask_key(key) when is_binary(key) and byte_size(key) > 4 do
    String.slice(key, 0, 4) <> "...***"
  end

  def mask_key(_), do: "***"

  # --- Private: complete implementation ---

  defp do_complete(messages, opts) do
    base_url = Map.get(opts, :base_url) || @default_base_url
    model = Map.get(opts, :model) || "deepseek-chat"
    api_key = Map.get(opts, :api_key) || ""
    timeout = Map.get(opts, :receive_timeout, Map.get(opts, :timeout_ms, @default_timeout_ms))

    url = "#{base_url}/chat/completions"

    body = build_body(messages, model, false, opts)
    headers = build_headers(api_key)

    case Req.post(url,
           json: body,
           headers: headers,
           finch: Spark.FinchPool,
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        Spark.LLM.CircuitBreaker.success(:wafer)
        {:ok, parse_response(response_body)}

      {:ok, %Req.Response{status: 401}} ->
        {:error, {:auth_error, mask_key(api_key)}}

      {:ok, %Req.Response{status: 429, body: body}} ->
        {:error, {:rate_limited, get_retry_after(body)}}

      {:ok, %Req.Response{status: status, body: body}} when status >= 500 ->
        Spark.LLM.CircuitBreaker.failure(:wafer)
        {:error, {:server_error, status, truncate_body(body)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        # 4xx — client error, do NOT count as circuit breaker failure
        {:error, {:http_error, status, truncate_body(body)}}

      {:error, reason} ->
        Spark.LLM.CircuitBreaker.failure(:wafer)
        {:error, {:request_error, reason}}
    end
  end

  # --- Private: stream implementation ---

  defp do_stream(messages, opts, callback) do
    use_genstage = Spark.Config.get(["streaming", "adapter"], "direct") == "gen_stage"

    if use_genstage do
      do_stream_genstage(messages, opts, callback)
    else
      do_stream_direct(messages, opts, callback)
    end
  end

  # --- GenStage streaming path ---

  defp do_stream_genstage(messages, opts, callback) do
    base_url = Map.get(opts, :base_url) || @default_base_url
    model = Map.get(opts, :model) || "deepseek-chat"
    api_key = Map.get(opts, :api_key) || ""
    timeout = Map.get(opts, :receive_timeout, Map.get(opts, :timeout_ms, @default_timeout_ms))

    url = "#{base_url}/chat/completions"
    body = build_body(messages, model, true, opts)
    headers = build_headers(api_key)

    caller = self()

    {:ok, pipeline} =
      Spark.Streaming.Pipeline.start_link(
        request: {url, body, headers, [timeout: timeout]},
        consumer: {self(), callback},
        caller: caller,
        model: model,
        api_key: api_key
      )

    ref = Process.monitor(pipeline)

    result =
      receive do
        {:pipeline_done, {:ok, response}} ->
          Spark.LLM.CircuitBreaker.success(:wafer)
          callback.({:done, {:ok, response}})
          {:ok, response}

        {:pipeline_done, {:error, {:server_error, _, _} = reason}} ->
          Spark.LLM.CircuitBreaker.failure(:wafer)
          {:error, reason}

        {:pipeline_done, {:error, :stream_timeout}} ->
          Spark.LLM.CircuitBreaker.failure(:wafer)
          Logger.warning("WaferProvider (GenStage) stream timed out after #{timeout}ms")
          {:error, :stream_timeout}

        {:pipeline_done, {:error, reason}} ->
          {:error, reason}

        {:DOWN, ^ref, :process, ^pipeline, reason} ->
          Spark.LLM.CircuitBreaker.failure(:wafer)
          Logger.warning("WaferProvider (GenStage) pipeline crashed: #{inspect(reason)}")
          {:error, {:pipeline_crashed, reason}}
      after
        timeout + 5_000 ->
          Spark.LLM.CircuitBreaker.failure(:wafer)
          Logger.warning("WaferProvider (GenStage) stream timed out after #{timeout + 5_000}ms")
          {:error, :stream_timeout}
      end

    Process.demonitor(ref, [:flush])
    Spark.Streaming.Pipeline.stop(pipeline)

    result
  rescue
    e ->
      Spark.LLM.CircuitBreaker.failure(:wafer)
      {:error, {:stream_error, Exception.message(e)}}
  end

  # --- Direct streaming path (original implementation) ---

  defp do_stream_direct(messages, opts, callback) do
    base_url = Map.get(opts, :base_url) || @default_base_url
    model = Map.get(opts, :model) || "deepseek-chat"
    api_key = Map.get(opts, :api_key) || ""
    timeout = Map.get(opts, :receive_timeout, Map.get(opts, :timeout_ms, @default_timeout_ms))

    url = "#{base_url}/chat/completions"
    body = build_body(messages, model, true, opts)
    headers = build_headers(api_key)

    # SSE accumulator is stored in req.private.sse_acc so that the
    # resp remains a %Req.Response{} struct (Req validates this).
    initial_acc = %{
      sse_buffer: "",
      id: nil,
      model: model,
      content: "",
      usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    }

    task =
      Task.async(fn ->
        req =
          Req.new(
            method: :post,
            url: url,
            json: body,
            headers: headers,
            finch: Spark.FinchPool,
            into: fn {:data, chunk}, {req, resp} ->
              acc = req.private[:sse_acc] || initial_acc

              {parsed, remaining_buffer} =
                Spark.LLM.SSEParser.parse_stream(chunk, acc.sse_buffer)

              new_acc =
                Enum.reduce(parsed, %{acc | sse_buffer: remaining_buffer}, fn
                  {:ok, data}, inner_acc ->
                    delta_content =
                      get_in(data, ["choices", Access.at(0), "delta", "content"]) || ""

                    # Provider-exposed reasoning fields — display as transcript but don't pollute content
                    reasoning_text =
                      get_in(data, ["choices", Access.at(0), "delta", "reasoning_content"]) ||
                      get_in(data, ["choices", Access.at(0), "delta", "reasoning"]) ||
                      get_in(data, ["choices", Access.at(0), "delta", "thinking"]) || ""

                    chunk_id = Map.get(data, "id")
                    chunk_model = Map.get(data, "model")
                    chunk_usage = get_in(data, ["usage"])

                    inner_acc =
                      if chunk_id,
                        do: %{inner_acc | id: chunk_id},
                        else: inner_acc

                    inner_acc =
                      if chunk_model,
                        do: %{inner_acc | model: chunk_model},
                        else: inner_acc

                    inner_acc =
                      if delta_content != "",
                        do: %{inner_acc | content: inner_acc.content <> delta_content},
                        else: inner_acc

                    inner_acc =
                      if chunk_usage,
                        do: %{inner_acc | usage: parse_usage(chunk_usage)},
                        else: inner_acc

                    if delta_content != "" do
                      callback.({:chunk, %{delta: %{content: delta_content}}})
                    end

                    # Send reasoning as a separate visible chunk (tagged so TUI can label it)
                    if reasoning_text != "" do
                      callback.({:chunk, %{delta: %{content: reasoning_text}, type: :reasoning}})
                    end

                    inner_acc

                  {:done}, inner_acc ->
                    %{inner_acc | sse_buffer: ""}

                  {:error, _}, inner_acc ->
                    inner_acc

                  _, inner_acc ->
                    inner_acc
                end)

              req = Req.Request.put_private(req, :sse_acc, new_acc)
              {:cont, {req, resp}}
            end,
            receive_timeout: timeout
          )

        {req, resp} = Req.Request.run_request(req)
        {req, resp}
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {req, %Req.Response{status: 200} = _resp}} ->
        Spark.LLM.CircuitBreaker.success(:wafer)

        final_acc = req.private[:sse_acc] || initial_acc

        complete_response = %{
          id: final_acc.id || "unknown",
          model: final_acc.model || model,
          choices: [%{message: %{role: "assistant", content: final_acc.content}}],
          usage: final_acc.usage
        }

        callback.({:done, {:ok, complete_response}})
        {:ok, complete_response}

      {:ok, {_req, %Req.Response{status: 401}}} ->
        {:error, {:auth_error, mask_key(api_key)}}

      {:ok, {_req, %Req.Response{status: 429, body: body}}} ->
        {:error, {:rate_limited, get_retry_after(body)}}

      {:ok, {_req, %Req.Response{status: status, body: body}}} when status >= 500 ->
        Spark.LLM.CircuitBreaker.failure(:wafer)
        {:error, {:server_error, status, truncate_body(body)}}

      {:ok, {_req, %Req.Response{status: status, body: body}}} ->
        # 4xx client errors do not trip the circuit breaker
        {:error, {:http_error, status, truncate_body(body)}}

      {:ok, _} ->
        {:error, :unexpected_stream_result}

      nil ->
        Spark.LLM.CircuitBreaker.failure(:wafer)
        Logger.warning("WaferProvider stream timed out after #{timeout}ms")
        {:error, :stream_timeout}

      {:exit, reason} ->
        Spark.LLM.CircuitBreaker.failure(:wafer)
        Logger.warning("WaferProvider stream exited: #{inspect(reason)}")
        {:error, {:stream_error, inspect(reason)}}
    end
  rescue
    e ->
      Spark.LLM.CircuitBreaker.failure(:wafer)
      {:error, {:stream_error, Exception.message(e)}}
  end

  # --- Private: guards ---

  defp check_circuit do
    case Spark.LLM.CircuitBreaker.allow?(:wafer) do
      true -> :ok
      {:error, :circuit_open, remaining} -> {:error, {:circuit_open, remaining}}
    end
  end

  defp check_rate_limit do
    case Spark.LLM.RateLimiter.acquire(:wafer) do
      :ok -> :ok
      {:error, :rate_limited, retry_after} -> {:error, {:rate_limited, retry_after}}
    end
  end

  # --- Private: HTTP helpers ---

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
    Map.get(body, "retry_after") || Map.get(body, "error", %{}) |> Map.get("retry_after")
  end

  defp get_retry_after(_), do: nil

  defp truncate_body(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp truncate_body(body), do: body
end
