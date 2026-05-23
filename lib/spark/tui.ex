defmodule Spark.TUI do
  @moduledoc "Entry point for the Spark terminal UI."

  def run(_opts \\ []) do
    TermUI.App.run(Spark.TermUI, backend: :raw)
  end
end
