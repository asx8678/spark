defmodule Spark.State do
  @moduledoc """
  Orchestrator state struct tracking session, phase, plan, and results.

  Phases: :awaiting_input → :planning → :awaiting_approval → :executing → :reviewing → :completed
  """

  @type phase ::
          :awaiting_input
          | :planning
          | :awaiting_approval
          | :executing
          | :reviewing
          | :completed

  @type t :: %__MODULE__{
          session_id: String.t(),
          phase: phase(),
          model: String.t() | nil,
          prompt_version: String.t() | nil,
          cached_prefix: [map()],
          cached_prefix_hash: String.t() | nil,
          history: [map()],
          active_plan: Spark.Types.Plan.t() | nil,
          completed_results: %{String.t() => Spark.Types.WorkerResult.t()},
          failed_results: %{String.t() => Spark.Types.WorkerResult.t()},
          memory_refs: [String.t()],
          schema_version: pos_integer()
        }

  defstruct [
    :session_id,
    :phase,
    :model,
    :prompt_version,
    :cached_prefix,
    :cached_prefix_hash,
    :history,
    :active_plan,
    :completed_results,
    :failed_results,
    :memory_refs,
    :schema_version
  ]

  @defaults [
    phase: :awaiting_input,
    cached_prefix: [],
    cached_prefix_hash: nil,
    history: [],
    active_plan: nil,
    completed_results: %{},
    failed_results: %{},
    memory_refs: [],
    schema_version: 1
  ]

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    id = opts[:session_id] || "sess_" <> (Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false))
    model = opts[:model] || Spark.Config.get([:llm, :orchestrator_model])
    defaults = Keyword.put(@defaults, :session_id, id)
    defaults = Keyword.put(defaults, :model, model)
    defaults = Keyword.put(defaults, :prompt_version, opts[:prompt_version] || "1")

    struct!(__MODULE__, Keyword.merge(defaults, opts))
  end

  @spec add_result(t(), Spark.Types.WorkerResult.t()) :: t()
  def add_result(state, result),
    do: %{state | completed_results: Map.put(state.completed_results, result.task_id, result)}

  @spec add_failed(t(), Spark.Types.WorkerResult.t()) :: t()
  def add_failed(state, result),
    do: %{state | failed_results: Map.put(state.failed_results, result.task_id, result)}

  @spec all_results(t()) :: %{String.t() => Spark.Types.WorkerResult.t()}
  def all_results(state), do: Map.merge(state.completed_results, state.failed_results)

  @spec phase(t()) :: phase()
  def phase(state), do: state.phase
end
