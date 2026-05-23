defmodule Spark.Types.Plan do
  @moduledoc """
  Represents the Orchestrator's output after user input — a structured plan
  of tasks requiring CLI approval before execution.

  The Orchestrator may generate a plan but may not execute it.
  CLI approval is required before tasks are sent to the Dispatcher.
  The approved plan should be logged to Bronze memory.
  """

  alias Spark.Types.Task

  @type approval_status :: :draft | :awaiting_approval | :approved | :rejected | :modified

  @type t :: %__MODULE__{
          id: String.t(),
          user_goal: String.t(),
          summary: String.t(),
          tasks: [Task.t()],
          approval_status: approval_status(),
          created_at: DateTime.t(),
          approved_at: DateTime.t() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :user_goal,
    :summary,
    tasks: [],
    approval_status: :draft,
    created_at: nil,
    approved_at: nil,
    metadata: %{}
  ]

  @doc """
  Creates a new Plan with auto-generated id and timestamp.
  """
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    defaults = %{created_at: now, id: attrs[:id] || generate_id()}
    struct!(__MODULE__, Map.merge(defaults, attrs))
  end

  @doc """
  Validates a Plan struct, including nested task validation.
  """
  def validate(%__MODULE__{} = plan) do
    errors = []

    errors =
      if is_nil(plan.id) or plan.id == "",
        do: errors ++ [{:id, "must not be empty"}],
        else: errors

    errors =
      if is_nil(plan.user_goal) or plan.user_goal == "",
        do: errors ++ [{:user_goal, "must not be empty"}],
        else: errors

    errors =
      if is_nil(plan.summary) or plan.summary == "",
        do: errors ++ [{:summary, "must not be empty"}],
        else: errors

    errors =
      if plan.tasks == [],
        do: errors ++ [{:tasks, "must not be empty"}],
        else: errors

    # Check for duplicate task IDs
    task_ids = Enum.map(plan.tasks, & &1.id)
    duplicate_ids = task_ids -- Enum.uniq(task_ids)
    errors =
      if duplicate_ids != [],
        do: errors ++ [{:tasks, "duplicate task ids: #{inspect(duplicate_ids)}"}],
        else: errors

    # Validate nested tasks
    task_errors =
      Enum.flat_map(plan.tasks, fn task ->
        case Task.validate(task) do
          :ok -> []
          {:error, task_errs} -> [{:task_validation, {task.id, task_errs}}]
        end
      end)

    errors = errors ++ task_errors

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc """
  Transitions plan to :awaiting_approval status.
  """
  def awaiting_approval(%__MODULE__{} = plan) do
    %{plan | approval_status: :awaiting_approval}
  end

  @doc """
  Approves a plan that is :awaiting_approval. Sets approved_at timestamp.
  Returns {:ok, plan} or {:error, reason}.
  """
  def approve(%__MODULE__{approval_status: :awaiting_approval} = plan) do
    {:ok, %{plan | approval_status: :approved, approved_at: DateTime.utc_now()}}
  end

  def approve(%__MODULE__{approval_status: status}) do
    {:error, "cannot approve plan with status: #{status}"}
  end

  @doc """
  Rejects a plan that is :awaiting_approval.
  """
  def reject(%__MODULE__{approval_status: :awaiting_approval} = plan) do
    {:ok, %{plan | approval_status: :rejected}}
  end

  def reject(%__MODULE__{approval_status: status}) do
    {:error, "cannot reject plan with status: #{status}"}
  end

  @doc """
  Modifies a plan, resetting approval status and merging extra metadata.
  """
  def modify(%__MODULE__{} = plan, extra_metadata \\ %{}) do
    %{plan | approval_status: :modified, metadata: Map.merge(plan.metadata, extra_metadata)}
  end

  @doc """
  Returns all task IDs in the plan.
  """
  def task_ids(%__MODULE__{tasks: tasks}), do: Enum.map(tasks, & &1.id)

  defp generate_id do
    "plan_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
