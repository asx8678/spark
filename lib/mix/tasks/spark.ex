defmodule Mix.Tasks.Spark do
  @moduledoc """
  Starts the Spark v4.0 interactive REPL.

  ## Usage

      mix spark

  This boots the OTP supervision tree and launches the
  Spark TUI. Use `mix spark --cli` for the legacy REPL.
  """
  use Mix.Task

  @shortdoc "Starts the Spark interactive REPL"

  @impl Mix.Task
  def run(args) do
    # Ensure the app is started
    Mix.Task.run("app.start", [])

    if "--cli" in args do
      {:ok, pid} = Spark.CLI.start_link()

      ref = Process.monitor(pid)
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    else
      Spark.TUI.run()
    end
  end
end
