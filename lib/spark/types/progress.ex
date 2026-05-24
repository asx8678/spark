defmodule Spark.Types.Progress do
  @moduledoc """
  Progress report for the Agent Protocol.

  Workers and agents use this struct to report execution phase and
  completion percentage back to the Orchestrator or Dispatcher.
  """

  @type phase :: :investigating | :coding | :testing | :reviewing

  @type t :: %__MODULE__{
          task_id: String.t(),
          phase: phase(),
          detail: String.t(),
          percent: float(),
          timestamp: DateTime.t() | nil
        }

  defstruct [
    :task_id,
    :phase,
    :detail,
    percent: 0.0,
    timestamp: nil
  ]

  @doc """
  Creates a new Progress report with auto-generated timestamp.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    defaults = %{timestamp: DateTime.utc_now(), percent: 0.0}
    struct!(__MODULE__, Map.merge(defaults, attrs))
  end
end
