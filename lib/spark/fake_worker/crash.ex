defmodule Spark.FakeWorker.Crash do
  @moduledoc """
  Test fake worker that crashes immediately for crash handling tests.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :crash}}
  end

  @impl true
  def handle_continue(:crash, _state) do
    raise "simulated worker crash"
  end
end
