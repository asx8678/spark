defmodule Spark.FakeWorker do
  @moduledoc """
  Test fake worker for Dispatcher testing. Simulates work with a small delay,
  then publishes a task_completed event and exits normally.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec child_spec(keyword()) :: map()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @impl true
  def init(opts) do
    task = Keyword.get(opts, :task)
    delay_ms = Keyword.get(opts, :delay_ms, 10)
    session_id = Keyword.get(opts, :session_id)
    plan_id = Keyword.get(opts, :plan_id)

    Process.send_after(self(), :complete, delay_ms)
    {:ok, %{task: task, session_id: session_id, plan_id: plan_id}}
  end

  @impl true
  def handle_info(:complete, state) do
    if state.task do
      Spark.EventBus.publish_task(state.task.id, :task_completed, %{
        task_id: state.task.id,
        result: "fake success"
      })
    end

    {:stop, :normal, state}
  end
end
