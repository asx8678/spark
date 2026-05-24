defmodule Spark.Types.TaskRequest do
  @moduledoc """
  Typed request envelope for the Planning Agent → Coding Agent protocol.

  When the Orchestrator dispatches tasks to the Dispatcher, each task is
  wrapped in a TaskRequest that carries session context, timeout, and a
  unique request ID. This is the formal contract for cross-agent handoff —
  replacing ad-hoc map/tuple passing with a validated struct.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          plan_id: String.t(),
          task_spec: map(),
          context: map(),
          timeout_ms: pos_integer(),
          created_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :plan_id,
    :task_spec,
    context: %{},
    timeout_ms: 300_000,
    created_at: nil
  ]

  @doc """
  Creates a new TaskRequest with auto-generated id and timestamp.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    defaults = %{created_at: now, id: attrs[:id] || generate_id()}
    struct!(__MODULE__, Map.merge(defaults, attrs))
  end

  @doc """
  Validates a TaskRequest struct. Returns :ok or {:error, list_of_errors}.
  """
  @spec validate(t()) :: :ok | {:error, [{atom(), String.t()}]}
  def validate(%__MODULE__{} = req) do
    errors = []

    errors =
      if is_nil(req.id) or req.id == "",
        do: errors ++ [{:id, "must not be empty"}],
        else: errors

    errors =
      if is_nil(req.plan_id) or req.plan_id == "",
        do: errors ++ [{:plan_id, "must not be empty"}],
        else: errors

    errors =
      if not is_map(req.task_spec) or map_size(req.task_spec) == 0,
        do: errors ++ [{:task_spec, "must be a non-empty map"}],
        else: errors

    errors =
      if not is_map(req.context),
        do: errors ++ [{:context, "must be a map"}],
        else: errors

    errors =
      if not is_integer(req.timeout_ms) or req.timeout_ms <= 0,
        do: errors ++ [{:timeout_ms, "must be a positive integer"}],
        else: errors

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp generate_id do
    "req_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
