Mix.Task.run("app.start", [])
IO.puts(:stderr, "[TERMUI DEBUG] Starting debug TermUI app...")
TermUI.App.run(Spark.TermUIDebug, backend: :auto)
IO.puts(:stderr, "[TERMUI DEBUG] Debug TermUI app finished.")
