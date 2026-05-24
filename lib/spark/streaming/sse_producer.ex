defmodule Spark.Streaming.SSEProducer do
  @moduledoc """
  GenStage producer that fetches SSE chunks from an LLM API on demand.

  Starts an HTTP request in a separate linked process. The HTTP process
  sends parsed SSE events to this producer, which buffers them and
  dispatches to consumers as demand allows. This provides backpressure —
  the producer only dispatches events when consumers request them,
  preventing mailbox flooding on the Worker process.

  ## Event format

  Dispatched events are one of:
    - `{:chunk, %{delta: %{content: content}}}` — a content delta
    - `{:done, {:ok, response}}` — stream completed successfully
    - `{:error, reason}` — an error occurred

  ## Lifecycle

  The producer is ephemeral — started per streaming request and stopped
  when the stream completes or errors. The HTTP process is linked so
  crashes propagate as `:EXIT` signals (trapped via `Process.flag`).
  """

  use GenStage

  require Logger

  alias Spark.LLM.SSEParser

  # --- Public API ---

  @doc """
  Starts the SSE producer linked to the calling process.

  Expects `{url, body, headers, req_opts}` as the first argument and
  a keyword list of extra options:
    - `:caller_pid` — pid to notify with `{:pipeline_done, result}` on completion
    - `:model` — model name (fallback for the response)
    - `:api_key` — API key (for error masking)
  """
  @spec start_link({{String.t(), map(), list(), keyword()}, keyword()}) ::
          GenServer.on_start()
  def start_link({{url, body, headers, req_opts}, extra}) do
    GenStage.start_link(__MODULE__, {{url, body, headers, req_opts}, extra})
  end

  # --- GenStage callbacks ---

  @impl true
  def init({{url, body, headers, req_opts}, extra}) do
    Process.flag(:trap_exit, true)

    state = %{
      url: url,
      body: body,
      headers: headers,
      req_opts: req_opts,
      caller_pid: Keyword.get(extra, :caller_pid),
      model: Keyword.get(extra, :model, "unknown"),
      api_key: Keyword.get(extra, :api_key, ""),
      demand: 0,
      buffer: [],
      http_pid: nil,
      done: false
    }

    {:producer, state}
  end

  @impl true
  def handle_demand(incoming_demand, state) do
    state = %{state | demand: state.demand + incoming_demand}
    state = maybe_start_http(state)
    dispatch_buffer(state)
  end

  # --- HTTP process messages ---

  @impl true
  def handle_info({:sse_event, event}, state) do
    state = %{state | buffer: state.buffer ++ [event]}
    dispatch_buffer(state)
  end

  def handle_info({:sse_result, {req, %Req.Response{status: 200} = _resp}}, state) do
    final_acc = req.private[:sse_acc] || build_default_acc(state.model)
    complete_response = build_complete_response(final_acc, state.model)

    state =
      %{state | buffer: state.buffer ++ [{:done, {:ok, complete_response}}], done: true}
      |> notify_caller({:ok, complete_response})

    dispatch_buffer(state)
  end

  def handle_info({:sse_result, {_req, %Req.Response{status: 401}}}, state) do
    reason = {:auth_error, mask_key(state.api_key)}
    state = buffer_error_and_notify(state, reason)
    dispatch_buffer(state)
  end

  def handle_info({:sse_result, {_req, %Req.Response{status: 429, body: body}}}, state) do
    reason = {:rate_limited, get_retry_after(body)}
    state = buffer_error_and_notify(state, reason)
    dispatch_buffer(state)
  end

  def handle_info({:sse_result, {_req, %Req.Response{status: status, body: body}}}, state)
      when status >= 500 do
    reason = {:server_error, status, truncate_body(body)}
    state = buffer_error_and_notify(state, reason)
    dispatch_buffer(state)
  end

  def handle_info({:sse_result, {_req, %Req.Response{status: status, body: body}}}, state) do
    reason = {:http_error, status, truncate_body(body)}
    state = buffer_error_and_notify(state, reason)
    dispatch_buffer(state)
  end

  # HTTP process crashed (linked, trap_exit enabled)
  def handle_info({:EXIT, pid, reason}, %{http_pid: pid} = state) when reason != :normal do
    Logger.warning("SSEProducer HTTP process exited: #{inspect(reason)}")

    error_reason =
      case reason do
        {:timeout, _} -> :stream_timeout
        other -> {:http_exit, other}
      end

    state =
      %{state | http_pid: nil}
      |> buffer_error_and_notify(error_reason)

    dispatch_buffer(state)
  end

  def handle_info({:EXIT, _pid, :normal}, state) do
    {:noreply, %{state | http_pid: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.http_pid && Process.alive?(state.http_pid) do
      Process.exit(state.http_pid, :shutdown)
    end

    :ok
  end

  # --- Private: HTTP request ---

  defp maybe_start_http(%{http_pid: nil, done: false} = state) do
    producer = self()
    model = state.model

    pid =
      spawn_link(fn ->
        http_task(producer, state.url, state.body, state.headers, state.req_opts, model)
      end)

    %{state | http_pid: pid}
  end

  defp maybe_start_http(state), do: state

  defp http_task(producer, url, body, headers, req_opts, model) do
    timeout = Keyword.get(req_opts, :timeout, 120_000)

    # SSE accumulator is stored in req.private.sse_acc so that the
    # resp remains a %Req.Response{} struct (Req validates this).
    initial_acc = %{
      sse_buffer: "",
      id: nil,
      model: model,
      content: "",
      usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    }

    try do
      req =
        Req.new(
          method: :post,
          url: url,
          json: body,
          headers: headers,
          finch: Spark.FinchPool,
          into: fn {:data, chunk}, {req, resp} ->
            acc = req.private[:sse_acc] || initial_acc

            {parsed, remaining_buffer} = SSEParser.parse_stream(chunk, acc.sse_buffer)

            new_acc =
              Enum.reduce(parsed, %{acc | sse_buffer: remaining_buffer}, fn
                {:ok, data}, inner_acc ->
                  delta_content =
                    get_in(data, ["choices", Access.at(0), "delta", "content"]) || ""

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
                    send(producer, {:sse_event, {:chunk, %{delta: %{content: delta_content}}}})
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
      send(producer, {:sse_result, {req, resp}})
    catch
      kind, reason ->
        send(producer, {:sse_result, %Req.Response{status: 0, body: %{error: {kind, reason}}}})
    end
  end

  # --- Private: dispatch ---

  defp dispatch_buffer(state) do
    {to_dispatch, remaining} = Enum.split(state.buffer, state.demand)
    new_demand = state.demand - length(to_dispatch)
    new_state = %{state | buffer: remaining, demand: new_demand}

    if to_dispatch != [] do
      {:noreply, to_dispatch, new_state}
    else
      {:noreply, new_state}
    end
  end

  # --- Private: response construction ---

  defp build_complete_response(final_acc, default_model) do
    %{
      id: Map.get(final_acc, :id) || "unknown",
      model: Map.get(final_acc, :model) || default_model,
      choices: [
        %{message: %{role: "assistant", content: Map.get(final_acc, :content, "")}}
      ],
      usage:
        Map.get(final_acc, :usage, %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0})
    }
  end

  defp build_default_acc(model) do
    %{
      sse_buffer: "",
      id: nil,
      model: model,
      content: "",
      usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    }
  end

  defp buffer_error_and_notify(state, reason) do
    if state.caller_pid do
      send(state.caller_pid, {:pipeline_done, {:error, reason}})
    end

    %{state | buffer: state.buffer ++ [{:error, reason}], done: true}
  end

  defp notify_caller(state, result) do
    if state.caller_pid do
      send(state.caller_pid, {:pipeline_done, result})
    end

    state
  end

  # --- Private: HTTP helpers (duplicated from WaferProvider for isolation) ---

  defp parse_usage(usage) when is_map(usage) do
    %{
      prompt_tokens: Map.get(usage, "prompt_tokens", 0),
      completion_tokens: Map.get(usage, "completion_tokens", 0),
      total_tokens: Map.get(usage, "total_tokens", 0)
    }
  end

  defp parse_usage(_), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  defp mask_key(key) when is_binary(key) and byte_size(key) > 4 do
    String.slice(key, 0, 4) <> "...***"
  end

  defp mask_key(_), do: "***"

  defp get_retry_after(body) when is_map(body) do
    Map.get(body, "retry_after") || Map.get(body, "error", %{}) |> Map.get("retry_after")
  end

  defp get_retry_after(_), do: nil

  defp truncate_body(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp truncate_body(body), do: body
end
