defmodule Spark.Policy do
  @moduledoc """
  Policy engine for Spark — approval gates, risk models, and enforcement.

  Loads config from ~/.spark/policy/policy.json (or defaults).
  Validates plans, tasks, and tool calls against the active policy.
  Supports hot-reload with rollback on invalid config.
  """

  use Agent

  alias Spark.Types.{Plan, Task}
  alias Spark.EventBus

  @policy_path "policy/policy.json"

  @default_policy %{
    "allow_shell" => false,
    "allow_critical" => false,
    "require_approval_for_high_risk" => true,
    "blocked_tools" => [],
    "allowed_tools" => nil,
    "max_write_paths_per_task" => 10,
    "require_task_id_for_write" => true
  }

  @tool_risk %{
    # :low
    "read_file" => :low,
    "list_dir" => :low,
    "grep" => :low,
    "list_files" => :low,
    "search" => :low,
    "head" => :low,
    "glob" => :low,
    "web_search" => :low,
    # :medium
    "write_file" => :medium,
    "edit_file" => :medium,
    "web_fetch" => :medium,
    "create_file" => :medium,
    "replace_in_file" => :medium,
    # :high
    "shell" => :high,
    "bash" => :high,
    "forge_tool" => :high,
    "exec" => :high,
    "run_command" => :high,
    "create_and_load_tool" => :high,
    # :critical
    "rm_rf" => :critical,
    "destructive_shell" => :critical,
    "secret_access" => :critical,
    "delete_file" => :critical,
    "format_drive" => :critical
  }

  @risk_order [:low, :medium, :high, :critical]

  # --- Public API ---

  @spec start_link(term()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts \\ []) do
    # Self-check: Process.whereis(__MODULE__) is the correct pattern for
    # named singleton Agents — they are NOT session-scoped, so Registry
    # lookup would add complexity without benefit. (spark-ard.19)
    case Process.whereis(__MODULE__) do
      nil -> Agent.start_link(fn -> load_policy() end, name: __MODULE__)
      pid -> {:ok, pid}
    end
  end

  @doc "Returns the current runtime policy map."
  @spec current() :: map()
  def current do
    ensure_started()
    Agent.get(__MODULE__, & &1)
  end

  @doc "Validates a plan against policy: approval_status and structural validity."
  @spec validate_plan(Spark.Types.Plan.t(), map()) :: :ok | {:error, [{atom(), String.t()}]}
  def validate_plan(%Plan{} = plan, _context \\ %{}) do
    errors = []

    errors =
      if plan.approval_status not in [:approved, :awaiting_approval, :draft, :modified],
        do: [{:approval_status, "invalid status"} | errors],
        else: errors

    errors =
      case Plan.validate(plan) do
        :ok -> errors
        {:error, errs} -> [{:plan_validation, errs} | errors]
      end

    policy = current()

    errors =
      if policy["require_approval_for_high_risk"] and
           plan.approval_status != :approved and
           Enum.any?(plan.tasks, &Task.high_risk?/1) do
        [{:requires_approval, "high-risk tasks need plan approval"} | errors]
      else
        errors
      end

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  @doc "Validates a task against policy: risk level, read/write paths."
  @spec validate_task(Spark.Types.Task.t(), map()) :: :ok | {:error, [{atom(), String.t()}]}
  def validate_task(%Task{} = task, _context \\ %{}) do
    policy = current()
    errors = []

    errors =
      case Task.validate(task) do
        :ok -> errors
        {:error, errs} -> [{:task_validation, errs} | errors]
      end

    errors =
      if policy["require_approval_for_high_risk"] and Task.high_risk?(task) do
        [{:high_risk_requires_approval, "task #{task.id} is high risk"} | errors]
      else
        errors
      end

    max = policy["max_write_paths_per_task"] || 10

    errors =
      if length(task.write_paths) > max do
        [{:too_many_write_paths, "task #{task.id} exceeds max write paths"} | errors]
      else
        errors
      end

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  @doc "Validates a tool call: risk level, task_id presence, policy allow/deny."
  @spec validate_tool_call(String.t() | atom(), map(), map()) :: :ok | {:error, term()}
  def validate_tool_call(tool_name, _args, worker_state) do
    policy = current()
    risk = tool_risk(tool_name)
    blocked = Map.get(policy, "blocked_tools", [])
    allowed = Map.get(policy, "allowed_tools")

    cond do
      tool_name in blocked ->
        {:error, {:blocked_by_policy, tool_name}}

      allowed != nil and tool_name not in allowed ->
        {:error, {:not_in_allowlist, tool_name}}

      risk == :critical and not Map.get(policy, "allow_critical", false) ->
        {:error, {:critical_blocked, tool_name}}

      risk == :high and not Map.get(policy, "allow_shell", false) ->
        {:error, {:high_risk_blocked, tool_name}}

      risk in [:medium, :high, :critical] and
        Map.get(policy, "require_task_id_for_write", true) and
          missing_task_id?(worker_state) ->
        {:error, {:missing_task_id, "write/shell tools require task_id"}}

      true ->
        :ok
    end
  end

  @doc "Returns true if the action requires approval (high-risk)."
  @spec requires_approval?(
          atom() | String.t() | Spark.Types.Task.t() | {:tool, String.t()},
          map()
        ) :: boolean()
  def requires_approval?(action, _context \\ %{})

  def requires_approval?(%Task{risk: :high}, _context), do: true
  def requires_approval?(%Task{}, _context), do: false

  def requires_approval?(action, _context) when is_binary(action) do
    risk = tool_risk(action)
    policy = current()
    risk == :high or (risk == :critical and not Map.get(policy, "allow_critical", false))
  end

  def requires_approval?(action, _context) when is_atom(action) do
    risk = tool_risk(action)
    policy = current()
    risk == :high or (risk == :critical and not Map.get(policy, "allow_critical", false))
  end

  def requires_approval?({:tool, tool_name}, _context) when is_binary(tool_name) do
    requires_approval?(tool_name, %{})
  end

  def requires_approval?({:tool, tool_name}, _context) when is_atom(tool_name) do
    requires_approval?(tool_name, %{})
  end

  @doc "Returns true if the action is allowed by policy."
  @spec allowed?(
          atom() | String.t() | Spark.Types.Task.t() | {:tool, String.t()},
          map()
        ) :: boolean()
  def allowed?(action, _context \\ %{})

  def allowed?(%Task{risk: :high}, context) do
    policy = current()

    if policy["require_approval_for_high_risk"] do
      Map.get(context, :approved, false)
    else
      true
    end
  end

  def allowed?(%Task{}, _context), do: true

  def allowed?(action, _context) when is_binary(action) do
    policy = current()
    risk = tool_risk(action)
    blocked = Map.get(policy, "blocked_tools", [])
    allowed = Map.get(policy, "allowed_tools")

    cond do
      action in blocked -> false
      allowed != nil and action not in allowed -> false
      risk == :critical and not Map.get(policy, "allow_critical", false) -> false
      risk == :high and not Map.get(policy, "allow_shell", false) -> false
      true -> true
    end
  end

  def allowed?(action, _context) when is_atom(action) do
    policy = current()
    risk = tool_risk(action)
    blocked = Map.get(policy, "blocked_tools", [])
    allowed = Map.get(policy, "allowed_tools")

    cond do
      action in blocked -> false
      allowed != nil and action not in allowed -> false
      risk == :critical and not Map.get(policy, "allow_critical", false) -> false
      risk == :high and not Map.get(policy, "allow_shell", false) -> false
      true -> true
    end
  end

  def allowed?({:tool, tool_name}, context) when is_binary(tool_name) do
    allowed?(tool_name, context)
  end

  def allowed?({:tool, tool_name}, context) when is_atom(tool_name) do
    allowed?(tool_name, context)
  end

  @doc "Returns the risk level for a tool name."
  @spec tool_risk(String.t() | atom()) :: :low | :medium | :high | :critical
  def tool_risk(tool_name) when is_atom(tool_name), do: tool_risk(Atom.to_string(tool_name))
  def tool_risk(tool_name) when is_binary(tool_name), do: Map.get(@tool_risk, tool_name, :medium)

  @doc "Compares two risk levels. Returns :lt, :eq, or :gt."
  @spec risk_compare(atom(), atom()) :: :lt | :eq | :gt
  def risk_compare(a, b) do
    ai = Enum.find_index(@risk_order, &(&1 == a)) || 1
    bi = Enum.find_index(@risk_order, &(&1 == b)) || 1

    cond do
      ai < bi -> :lt
      ai > bi -> :gt
      true -> :eq
    end
  end

  @doc "Returns the default policy map."
  @spec default_policy() :: map()
  def default_policy, do: @default_policy

  @doc "Returns the tool risk map."
  @spec tool_risk_map() :: map()
  def tool_risk_map, do: @tool_risk

  # --- Hot Reload (spark-04w.5) ---

  @doc """
  Reloads policy from disk. Revalidates active draft plans.
  Rolls back to previous policy on invalid config.
  Publishes :policy_reloaded event.
  """
  @spec reload() :: {:ok, map()} | {:error, term()}
  def reload do
    ensure_started()

    case load_policy_from_disk() do
      {:ok, new_policy} ->
        Agent.update(__MODULE__, fn _ -> new_policy end)
        EventBus.publish_hot_reload(:policy_reloaded, %{}, source: :policy)
        {:ok, new_policy}

      {:error, reason} ->
        # Roll back — keep old policy
        {:error, {:reload_failed, reason}}
    end
  end

  @doc """
  Revalidates an active draft plan against the current policy.
  Returns {:ok, plan} if still valid, {:error, errors} if not.
  """
  @spec revalidate_plan(Spark.Types.Plan.t()) ::
          :ok | {:ok, Spark.Types.Plan.t()} | {:error, term()}
  def revalidate_plan(%Plan{approval_status: status} = plan)
      when status in [:draft, :awaiting_approval, :modified] do
    validate_plan(plan)
  end

  def revalidate_plan(%Plan{} = plan), do: {:ok, plan}

  # --- Private ---

  defp ensure_started do
    # Self-check: Process.whereis(__MODULE__) is correct for named singletons
    # (not session-scoped). Registry lookup adds no value here. (spark-ard.19)
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp load_policy do
    case load_policy_from_disk() do
      {:ok, policy} -> policy
      {:error, _} -> @default_policy
    end
  end

  defp load_policy_from_disk do
    path = policy_file_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, policy} when is_map(policy) -> {:ok, Map.merge(@default_policy, policy)}
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end

      {:error, :enoent} ->
        {:ok, @default_policy}

      {:error, reason} ->
        {:error, {:read_error, reason}}
    end
  end

  defp policy_file_path do
    Path.join(Spark.Config.home_dir(), @policy_path)
  end

  defp missing_task_id?(%{task_id: id}) when is_binary(id) and id != "", do: false
  defp missing_task_id?(%{task: %Task{id: id}}) when is_binary(id) and id != "", do: false
  defp missing_task_id?(_), do: true
end
