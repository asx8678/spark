defmodule Spark.TermUIDebug do
  @moduledoc """
  Minimal debug TermUI app — shows text and logs every event to stderr.
  Use with: mix run debug_termui.exs
  """

  import TermUI.Component.Helpers
  alias TermUI.Renderer.Style

  def init(_opts) do
    IO.puts(:stderr, "[TERMUI DEBUG] init called")
    %{msg: "Debug app loaded", tick_count: 0}
  end

  def view(state) do
    stack(:vertical, [
      styled(
        text("  Spark TUI Debug Mode  "),
        Style.new() |> Style.fg(:white) |> Style.bg(:red) |> Style.bold()
      ),
      text(""),
      text("  #{state.msg}"),
      text(""),
      text("  Press A for agents, P for plan, D for dashboard"),
      text("  Press Q to quit")
    ])
  end

  def event_to_msg(event, _state) do
    IO.puts(:stderr, "[TERMUI DEBUG] event_to_msg: #{inspect(event)}")

    cond do
      # Check for quit via char field
      is_map(event) && Map.get(event, :char) in ["q", "Q"] ->
        IO.puts(:stderr, "[TERMUI DEBUG] QUIT via char")
        {:msg, :quit}

      # Check for quit via key field
      is_map(event) && Map.get(event, :key) == :ctrl_c ->
        IO.puts(:stderr, "[TERMUI DEBUG] QUIT via ctrl_c")
        {:msg, :quit}

      # Printable characters
      is_map(event) && is_binary(Map.get(event, :char, "")) &&
          byte_size(Map.get(event, :char, "")) == 1 ->
        ch = Map.get(event, :char)
        <<codepoint::utf8>> = ch
        IO.puts(:stderr, "[TERMUI DEBUG] printable char: #{ch} codepoint=#{codepoint}")
        {:msg, {:event, %{ch: codepoint}}}

      # Special keys
      is_map(event) && is_atom(Map.get(event, :key)) ->
        key = Map.get(event, :key)
        IO.puts(:stderr, "[TERMUI DEBUG] special key: #{key}")

        case key do
          :enter -> {:msg, {:event, %{key: 0x0D}}}
          :escape -> {:msg, {:event, %{key: 0x1B}}}
          :up -> {:msg, {:event, %{key: 0xFFFF - 18}}}
          :down -> {:msg, {:event, %{key: 0xFFFF - 19}}}
          :backspace -> {:msg, {:event, %{key: 0x08}}}
          _ -> :ignore
        end

      is_map(event) && is_integer(Map.get(event, :interval)) && Map.get(event, :interval) > 0 ->
        IO.puts(:stderr, "[TERMUI DEBUG] tick")
        {:msg, :tick}

      true ->
        IO.puts(:stderr, "[TERMUI DEBUG] unhandled: #{inspect(event)}")
        :ignore
    end
  end

  def update(:tick, %{tick_count: count} = state) do
    {:ok, %{state | tick_count: count + 1}}
  end

  def update(:quit, state) do
    IO.puts(:stderr, "[TERMUI DEBUG] update quit")
    {state, [:quit]}
  end

  def update(msg, state) do
    IO.puts(:stderr, "[TERMUI DEBUG] update msg: #{inspect(msg)}")

    case msg do
      {:event, %{ch: ch}} ->
        IO.puts(:stderr, "[TERMUI DEBUG] char event: #{ch}")
        {:ok, %{state | msg: "Pressed: #{<<ch::utf8>>} (##{ch})"}}

      {:event, %{key: _key}} ->
        {:ok, %{state | msg: "Special key pressed"}}

      _ ->
        {:ok, state}
    end
  end

  def handle_info(msg, state) do
    IO.puts(:stderr, "[TERMUI DEBUG] handle_info: #{inspect(msg)}")
    {:ok, state}
  end
end
