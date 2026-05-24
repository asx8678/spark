defmodule Spark.Types.WorkerResult do
  @moduledoc """
  Represents Worker completion output.

  Workers must return structured output. Results must be forwarded
  to the Orchestrator and logged to memory. Failed results must
  include a reason and retry recommendation.
  """

  @type status :: :success | :failure | :partial

  @type t :: %__MODULE__{
          task_id: String.t(),
          worker_id: String.t(),
          status: status(),
          summary: String.t(),
          files_read: [String.t()],
          files_changed: [String.t()],
          commands_run: [String.t()],
          tests_run: [String.t()],
          diff: String.t() | nil,
          artifacts: [map()],
          errors: [map()],
          started_at: DateTime.t(),
          completed_at: DateTime.t(),
          token_usage: map()
        }

  defstruct [
    :task_id,
    :worker_id,
    :summary,
    status: :success,
    files_read: [],
    files_changed: [],
    commands_run: [],
    tests_run: [],
    diff: nil,
    artifacts: [],
    errors: [],
    started_at: nil,
    completed_at: nil,
    token_usage: %{}
  ]

  @doc """
  Creates a success result.
  """
  @spec success(map()) :: t()
  def success(attrs) when is_map(attrs) do
    build(:success, attrs)
  end

  @doc """
  Creates a failure result.
  """
  @spec failure(map()) :: t()
  def failure(attrs) when is_map(attrs) do
    build(:failure, attrs)
  end

  @doc """
  Creates a partial result.
  """
  @spec partial(map()) :: t()
  def partial(attrs) when is_map(attrs) do
    build(:partial, attrs)
  end

  defp build(status, attrs) do
    now = DateTime.utc_now()
    defaults = %{status: status, completed_at: now}
    struct!(__MODULE__, Map.merge(defaults, attrs))
  end

  @doc """
  Validates a WorkerResult struct.
  """
  @spec validate(t()) :: :ok | {:error, [{atom(), String.t()}]}
  def validate(%__MODULE__{} = result) do
    errors = []

    errors =
      if is_nil(result.task_id) or result.task_id == "",
        do: errors ++ [{:task_id, "must not be empty"}],
        else: errors

    errors =
      if is_nil(result.worker_id) or result.worker_id == "",
        do: errors ++ [{:worker_id, "must not be empty"}],
        else: errors

    errors =
      if result.status not in [:success, :failure, :partial],
        do: errors ++ [{:status, "invalid status"}],
        else: errors

    errors =
      if result.status in [:failure, :partial] and result.errors == [],
        do: errors ++ [{:errors, "failure/partial must include errors"}],
        else: errors

    errors =
      if is_nil(result.summary) or result.summary == "",
        do: errors ++ [{:summary, "must not be empty"}],
        else: errors

    # Check timestamp ordering
    errors =
      if result.started_at != nil and result.completed_at != nil do
        case DateTime.compare(result.completed_at, result.started_at) do
          :lt -> errors ++ [{:completed_at, "must be after started_at"}]
          _ -> errors
        end
      else
        errors
      end

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc """
  Determines if a failure result recommends retry.

  Recommends retry if errors contain retryable indicators (timeout, transient,
  temporary, connection, 429) and no non-retryable indicators (invalid_task,
  policy_denied, forbidden, permanent).
  """
  @spec retry_recommended?(t()) :: boolean()
  def retry_recommended?(%__MODULE__{status: :failure, errors: errors}) when errors != [] do
    retryable_indicators = ["timeout", "transient", "temporary", "connection", "429"]
    not_retryable = ["invalid_task", "policy_denied", "forbidden", "permanent"]

    has_retryable =
      Enum.any?(errors, fn e ->
        msg = Map.get(e, :reason, "") || Map.get(e, :message, "")
        Enum.any?(retryable_indicators, &String.contains?(String.downcase(msg), &1))
      end)

    has_non_retryable =
      Enum.any?(errors, fn e ->
        msg = Map.get(e, :reason, "") || Map.get(e, :message, "")
        Enum.any?(not_retryable, &String.contains?(String.downcase(msg), &1))
      end)

    has_retryable and not has_non_retryable
  end

  @spec retry_recommended?(term()) :: false
  def retry_recommended?(_), do: false
end
