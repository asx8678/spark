defmodule Spark.Memory.Bronze do
  @moduledoc """
  Bronze memory — append-only JSONL event log per session.

  File: ~/.spark/sessions/<session_id>.jsonl

  Each line is a JSON object:
    {
      "ts": "2025-01-01T00:00:00Z",
      "type": "user_input_received",
      "source": "orchestrator",
      "payload": { ... },
      "meta": { "hash": "..." | null, "truncated": false }
    }

  - Payloads >10KB are truncated and a SHA-256 hash of the full
    content is stored in meta.hash.
  - Secret keys (api_key, secret, token, password) are redacted.
  - Auto-logs EventBus events when subscribed.
  """

  alias Spark.Config
  alias Spark.EventBus
  alias Spark.Memory

  @max_payload_bytes 10_000
  @subscribed_key :spark_bronze_subscribed

  # --- Public API ---

  @doc """
  Appends an event entry to the session's Bronze JSONL file.
  Returns :ok or {:error, reason}.
  """
  @spec append(String.t(), map()) :: :ok | {:error, term()}
  def append(session_id, event) when is_binary(session_id) do
    if not bronze_enabled?() do
      {:error, :bronze_disabled}
    else
      entry = build_entry(event)
      path = session_path(session_id)
      File.mkdir_p!(Path.dirname(path))

      line = Jason.encode!(entry) <> "\n"

      case File.write(path, line, [:append]) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Reads all entries from a session's Bronze JSONL file.
  Returns {:ok, [map()]} or {:error, reason}.
  """
  @spec read(String.t()) :: {:ok, [map()]} | {:error, term()}
  def read(session_id) when is_binary(session_id) do
    path = session_path(session_id)

    case File.read(path) do
      {:ok, content} ->
        entries =
          content
          |> String.trim_trailing()
          |> String.split("\n")
          |> Enum.map(fn line ->
            case Jason.decode(line) do
              {:ok, entry} -> entry
              {:error, _} -> %{"raw" => line, "error" => true}
            end
          end)

        {:ok, entries}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Subscribes to EventBus "spark:events" and auto-logs incoming events.
  Call from a process that will receive handle_info.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    if not bronze_enabled?() do
      {:error, :bronze_disabled}
    else
      EventBus.subscribe("spark:events")
      Process.put(@subscribed_key, true)
      :ok
    end
  end

  @doc """
  Handles an EventBus event struct received via handle_info.
  Appends it to the session's Bronze log.

  Returns :ok, :skipped (not an Event or disabled), or {:error, reason}.
  """
  @spec handle_event(map(), String.t()) :: :ok | :skipped | {:error, term()}
  def handle_event(%Spark.Types.Event{} = event, session_id) do
    cond do
      not bronze_enabled?() ->
        :skipped

      event.type not in interesting_events() ->
        :skipped

      true ->
        append(session_id, %{
          type: event.type,
          source: event.source,
          payload: event.payload,
          session_id: event.session_id,
          plan_id: event.plan_id,
          task_id: event.task_id
        })
    end
  end

  def handle_event(_other, _session_id), do: :skipped

  @doc """
  Returns the file path for a session's Bronze JSONL file.
  """
  @spec session_path(String.t()) :: String.t()
  def session_path(session_id) do
    Path.join([Config.home_dir(), "sessions", "#{session_id}.jsonl"])
  end

  @doc "Returns whether Bronze logging is enabled."
  @spec bronze_enabled?() :: boolean()
  def bronze_enabled? do
    Config.get([:memory, :bronze_enabled], true) in [true, "true"]
  end

  # --- Event types worth logging ---

  defp interesting_events do
    ~w(
      user_input_received
      plan_created plan_awaiting_approval plan_approved plan_rejected
      task_queued task_started task_completed task_failed task_retried
      worker_started worker_stopped
      tool_started tool_completed tool_failed
      orchestrator_review_started orchestrator_review_completed
      memory_written
      hot_reload_started hot_reload_completed hot_reload_failed
      config_reloaded prompt_reloaded tool_reloaded policy_reloaded code_reloaded
      llm_call_started llm_call_completed llm_call_failed
    )a
  end

  # --- Entry building ---

  defp build_entry(event) do
    type = Map.get(event, :type, Map.get(event, "type", :unknown))
    source = Map.get(event, :source, Map.get(event, "source", :unknown))
    raw_payload = Map.get(event, :payload, %{})

    {payload, meta} =
      raw_payload
      |> Memory.filter_secrets()
      |> truncate_payload()

    %{
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => to_string(type),
      "source" => to_string(source),
      "payload" => payload,
      "meta" => meta
    }
  end

  defp truncate_payload(payload) when is_map(payload) do
    encoded = Jason.encode!(payload)
    byte_size = byte_size(encoded)

    if byte_size > @max_payload_bytes do
      hash = :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
      # Keep first ~1KB of the payload as a preview
      preview =
        payload
        |> Enum.take(5)
        |> Map.new()

      meta = %{"hash" => hash, "truncated" => true, "original_bytes" => byte_size}
      {Map.put(preview, "_truncated", true), meta}
    else
      {payload, %{"hash" => nil, "truncated" => false}}
    end
  end

  defp truncate_payload(other) do
    {other, %{"hash" => nil, "truncated" => false}}
  end
end
