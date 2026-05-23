Mix.Task.run("app.start", [])

defmodule TestApp do
  import TermUI.Component.Helpers
  alias TermUI.Renderer.Style

  def init(_opts) do
    %{count: 0}
  end

  def view(state) do
    stack(:vertical, [
      styled(text("  Test TermUI App  "), Style.new() |> Style.fg(:white) |> Style.bg(:blue) |> Style.bold()),
      text(""),
      text("  Count: #{state.count}", Style.new() |> Style.fg(:cyan)),
      text("  Press + to increment, - to decrement, q to quit"),
      text("  If you see this, TermUI is working!"),
    ])
  end

  def update(msg, state) do
    case msg do
      {:key, ?+} -> {:ok, %{state | count: state.count + 1}}
      {:key, ?-} -> {:ok, %{state | count: state.count - 1}}
      {:key, ?q} -> {:quit, state}
      {:key, ?Q} -> {:quit, state}
      _ -> {:ok, state}
    end
  end
end

IO.puts("Starting TermUI test...")
IO.puts("Press + to increment, - to decrement, q to quit")
TermUI.App.run(TestApp, backend: :auto)
IO.puts("TermUI test finished.")
