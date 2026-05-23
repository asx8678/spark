defmodule Spark.Types.Task do
  @moduledoc """
  Represents a single executable unit of work in the Spark system.

  Every Worker receives exactly one valid Task. Tasks that write files
  must have a non-empty id. Tasks with depends_on cannot run until
  dependencies are completed. Tasks with overlapping write_paths should
  not run concurrently unless explicitly marked safe.
  """

  @type status :: :queued | :running | :completed | :failed | :cancelled
  @type risk :: :low | :medium | :high

  @type t :: %__MODULE__{
          id: String.t(),
          plan_id: String.t(),
          title: String.t(),
          description: String.t(),
          context: map(),
          status: status(),
          priority: non_neg_integer(),
          depends_on: [String.t()],
          read_paths: [String.t()],
          write_paths: [String.t()],
          risk: risk(),
          max_retries: non_neg_integer(),
          retry_count: non_neg_integer(),
          timeout_ms: pos_integer(),
          created_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :plan_id,
    :title,
    :description,
    context: %{},
    status: :queued,
    priority: 0,
    depends_on: [],
    read_paths: [],
    write_paths: [],
    risk: :medium,
    max_retries: 3,
    retry_count: 0,
    timeout_ms: 300_000,
    created_at: nil,
    started_at: nil,
    completed_at: nil
  ]

  @doc """
  Creates a new Task with auto-generated id and timestamp.
  """
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    defaults = %{created_at: now, id: attrs[:id] || generate_id()}
    struct!(__MODULE__, Map.merge(defaults, attrs))
  end

  @doc """
  Validates a Task struct. Returns :ok or {:error, list_of_errors}.
  """
  def validate(%__MODULE__{} = task) do
    errors = []

    errors =
      if is_nil(task.id) or task.id == "",
        do: errors ++ [{:id, "must not be empty"}],
        else: errors

    errors =
      if is_nil(task.plan_id) or task.plan_id == "",
        do: errors ++ [{:plan_id, "must not be empty"}],
        else: errors

    errors =
      if task.risk not in [:low, :medium, :high],
        do: errors ++ [{:risk, "invalid risk"}],
        else: errors

    errors =
      if task.status not in [:queued, :running, :completed, :failed, :cancelled],
        do: errors ++ [{:status, "invalid status"}],
        else: errors

    errors =
      if task.retry_count < 0,
        do: errors ++ [{:retry_count, "cannot be negative"}],
        else: errors

    errors =
      if task.max_retries < 0,
        do: errors ++ [{:max_retries, "cannot be negative"}],
        else: errors

    errors =
      if task.timeout_ms <= 0,
        do: errors ++ [{:timeout_ms, "must be positive"}],
        else: errors

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc """
  Checks if a task is ready to run given a set of completed task IDs.
  Only queued tasks whose dependencies are all completed are ready.
  """
  def ready?(%__MODULE__{status: :queued, depends_on: deps}, completed_ids)
      when is_list(completed_ids) do
    Enum.all?(deps, &(&1 in completed_ids))
  end

  def ready?(%__MODULE__{}, _completed_ids), do: false

  @doc """
  Detects write path conflicts between two tasks.
  Returns true if both tasks have overlapping write_paths.
  """
  def write_conflicts?(
        %__MODULE__{write_paths: paths_a},
        %__MODULE__{write_paths: paths_b}
      )
      when paths_a != [] and paths_b != [] do
    not MapSet.disjoint?(MapSet.new(paths_a), MapSet.new(paths_b))
  end

  def write_conflicts?(_, _), do: false

  @doc """
  Returns true if the task is high risk.
  """
  def high_risk?(%__MODULE__{risk: :high}), do: true
  def high_risk?(%__MODULE__{}), do: false

  @doc """
  Increments retry count if under max_retries. Resets status to :queued.
  Returns {:ok, updated_task} or {:error, :max_retries_exceeded}.
  """
  def increment_retry(%__MODULE__{retry_count: count, max_retries: max} = task)
      when count < max do
    {:ok,
     %{task | retry_count: count + 1, status: :queued, started_at: nil, completed_at: nil}}
  end

  def increment_retry(%__MODULE__{}), do: {:error, :max_retries_exceeded}

  defp generate_id do
    "task_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
