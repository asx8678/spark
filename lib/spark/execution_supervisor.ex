defmodule Spark.ExecutionSupervisor do
  @moduledoc """
  :rest_for_one supervisor wrapping Guidance, Dispatcher, and Orchestrator.

  Child order: `[Guidance, Dispatcher, Orchestrator]`

  Restart semantics:
    - If Guidance crashes → Dispatcher + Orchestrator restart too
    - If Dispatcher crashes → Orchestrator restarts (re-syncs state)
    - If Orchestrator crashes → only Orchestrator restarts

  This supervisor itself is started with `:one_for_one` under the
  top-level Spark.Supervisor, so a full subtree crash doesn't take
  down unrelated services.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @spec init(term()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(_opts) do
    children = [
      {Spark.Guidance, []},
      {Spark.Dispatcher, []},
      {Spark.Orchestrator, []}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
