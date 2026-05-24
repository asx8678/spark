defmodule Spark.Types.Event do
  @moduledoc """
  Universal event envelope for the Spark EventBus system.

  All runtime events use this normalized struct. No module should publish
  raw tuples directly except inside private tests.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          topic: String.t(),
          type: atom(),
          source: atom(),
          source_id: String.t() | nil,
          session_id: String.t(),
          plan_id: String.t() | nil,
          task_id: String.t() | nil,
          payload: map(),
          timestamp: DateTime.t()
        }

  defstruct [
    :id,
    :topic,
    :type,
    :source,
    :source_id,
    :session_id,
    :plan_id,
    :task_id,
    payload: %{},
    timestamp: nil
  ]

  @doc """
  Creates a new Event with auto-generated id and timestamp.
  """
  @spec new(atom(), map(), keyword()) :: t()
  def new(type, payload \\ %{}, opts \\ []) when is_atom(type) and is_map(payload) do
    now = DateTime.utc_now()
    id = opts[:id] || generate_id()
    topic = opts[:topic] || "spark:events"
    source = opts[:source] || :unknown
    session_id = opts[:session_id] || ""

    %__MODULE__{
      id: id,
      topic: topic,
      type: type,
      source: source,
      source_id: opts[:source_id],
      session_id: session_id,
      plan_id: opts[:plan_id],
      task_id: opts[:task_id],
      payload: payload,
      timestamp: now
    }
  end

  @doc """
  Validates an Event struct.
  """
  @spec validate(t()) :: :ok | {:error, [{atom(), String.t()}]}
  def validate(%__MODULE__{} = event) do
    errors = []

    errors =
      if is_nil(event.topic) or event.topic == "",
        do: errors ++ [{:topic, "must not be empty"}],
        else: errors

    errors =
      if is_nil(event.type),
        do: errors ++ [{:type, "must not be nil"}],
        else: errors

    errors =
      if is_nil(event.source),
        do: errors ++ [{:source, "must not be nil"}],
        else: errors

    errors =
      if is_nil(event.id) or event.id == "",
        do: errors ++ [{:id, "must not be empty"}],
        else: errors

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc """
  Convenience helper for hot reload events.
  """
  @spec hot_reload(atom(), map(), keyword()) :: t()
  def hot_reload(type, payload \\ %{}, opts \\ []) do
    opts = Keyword.merge([topic: "spark:hot_reload", source: :hot_reload], opts)
    new(type, payload, opts)
  end

  @doc """
  Convenience helper for task-scoped events.
  """
  @spec task_event(atom(), String.t(), map(), keyword()) :: t()
  def task_event(type, task_id, payload \\ %{}, opts \\ []) do
    opts = Keyword.merge([task_id: task_id, topic: "spark:task:#{task_id}"], opts)
    new(type, payload, opts)
  end

  @doc """
  Convenience helper for plan-scoped events.
  """
  @spec plan_event(atom(), String.t(), map(), keyword()) :: t()
  def plan_event(type, plan_id, payload \\ %{}, opts \\ []) do
    opts = Keyword.merge([plan_id: plan_id, topic: "spark:plan:#{plan_id}"], opts)
    new(type, payload, opts)
  end

  defp generate_id do
    "evt_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
