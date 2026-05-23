Mix.Task.run("app.start", [])

IO.puts("=== Terminal Size Detection ===")

# Method 1: Erlang :io
IO.puts("Method 1 - :io.columns() / :io.rows():")
case {:io.columns(), :io.rows()} do
  {{:ok, cols}, {:ok, rows}} -> IO.puts("  :io => rows=#{rows}, cols=#{cols}")
  other -> IO.puts("  :io => #{inspect(other)}")
end

# Method 2: Environment variables
IO.puts("Method 2 - LINES/COLUMNS env:")
IO.puts("  LINES=#{System.get_env("LINES", "not set")}")
IO.puts("  COLUMNS=#{System.get_env("COLUMNS", "not set")}")

# Method 3: stty
IO.puts("Method 3 - stty size:")
case System.cmd("stty", ["size"]) do
  {output, 0} ->
    output = String.trim(output)
    IO.puts("  stty => #{output}")
  {error, code} ->
    IO.puts("  stty error (code=#{code}): #{error}")
end

# Method 4: TermUI's own detection
IO.puts("Method 4 - TermUI.Terminal.SizeDetector:")
IO.puts("  #{inspect(TermUI.Terminal.SizeDetector.detect())}")

# Method 5: Check if TermUI Terminal GenServer is running
IO.puts("Method 5 - TermUI Terminal process:")
IO.puts("  whereis=#{inspect(Process.whereis(TermUI.Terminal))}")

IO.puts("\n=== Environment Info ===")
IO.puts("TERM=#{System.get_env("TERM", "not set")}")
IO.puts("TERM_PROGRAM=#{System.get_env("TERM_PROGRAM", "not set")}")

IO.puts("\nDone.")
