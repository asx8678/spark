defmodule Spark.FakeWorker.Crash do
  @moduledoc """
  Test fake worker that crashes immediately for crash handling tests.
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
  def init(_opts) do
    {:ok, %{}, {:continue, :crash}}
  end

  @impl true
  def handle_continue(:crash, _state) do
    raise "simulated worker crash"
  end
end
