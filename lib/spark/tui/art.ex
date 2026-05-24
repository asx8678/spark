defmodule Spark.TUI.Art do
  @moduledoc """
  ASCII art and visual assets for the Spark TUI.

  Pure rendering functions returning styled TermUI text components.
  Every public function returns a list of `TermUI.Component.RenderNode.t()`.
  """

  import TermUI.Component.Helpers
  alias TermUI.Component.RenderNode
  alias TermUI.Renderer.Style

  @spinner_frames ~w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇]

  # ── Style constants ─────────────────────────────────────────────────────

  @banner_style Style.new() |> Style.fg(:cyan) |> Style.bold()
  @avatar_style Style.new() |> Style.fg(:yellow)
  @progress_fill_style Style.new() |> Style.fg(:green)
  @progress_empty_style Style.new() |> Style.fg(:bright_black)
  @spinner_style Style.new() |> Style.fg(:cyan)
  @divider_style Style.new() |> Style.fg(:bright_black)
  @scroll_style Style.new() |> Style.fg(:bright_black)

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Returns the Spark v4.1 welcome banner as a list of styled text components.

  Renders a centered box-drawing art piece with the Spark branding,
  version, and agent role descriptions.
  """
  @spec welcome_banner() :: [RenderNode.t()]
  def welcome_banner do
    lines = [
      "   ╔══════════════════════════════════════════╗",
      "   ║  🔮  S P A R K   v 4 . 1   🐶          ║",
      "   ║  Parallel Actor-Model Code Agent         ║",
      "   ║  Planning Agent: read-only investigation ║",
      "   ║  Coding Agent:  structured execution     ║",
      "   ╚══════════════════════════════════════════╝"
    ]

    Enum.map(lines, &styled(text(&1), @banner_style))
  end

  @doc """
  Returns an ASCII art avatar for the given agent type.

  - `:planning` → ASCII puppy face 🐶
  - `:coding` → ASCII robot 🤖
  """
  @spec agent_avatar(:planning | :coding) :: [RenderNode.t()]
  def agent_avatar(:planning) do
    lines = [
      "   __",
      " o-''|\\_____/)",
      "  \\_/|_)     )",
      "    \\  __  /",
      "    (_/ (_/"
    ]

    Enum.map(lines, &styled(text(&1), @avatar_style))
  end

  def agent_avatar(:coding) do
    lines = [
      "   [=|=]",
      "    |_|",
      "   /| |\\",
      "  _/ [_] \\_"
    ]

    Enum.map(lines, &styled(text(&1), @avatar_style))
  end

  @doc """
  Returns a progress bar as a list of styled text components.

  `percent` is an integer in `0..100`. `width` is the bar width
  excluding brackets and the percentage label.

  ## Example

      progress_bar(40, 10)
      # Renders: [████░░░░░░] 40%
  """
  @spec progress_bar(non_neg_integer(), pos_integer()) :: [RenderNode.t()]
  def progress_bar(percent, width)
      when is_integer(percent) and percent in 0..100 and
             is_integer(width) and width > 0 do
    filled = round(percent / 100 * width)
    empty = width - filled
    label = " #{percent}%"

    bar =
      stack(:horizontal, [
        styled(text("[" <> String.duplicate("█", filled)), @progress_fill_style),
        styled(text(String.duplicate("░", empty) <> "]" <> label), @progress_empty_style)
      ])

    [bar]
  end

  @doc """
  Returns a braille spinner character for the given frame index (0–7).

  Cycles through: ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇
  """
  @spec spinner(non_neg_integer()) :: [RenderNode.t()]
  def spinner(frame_index) when is_integer(frame_index) and frame_index >= 0 do
    idx = rem(frame_index, length(@spinner_frames))
    char = Enum.at(@spinner_frames, idx)
    [styled(text(char), @spinner_style)]
  end

  @doc """
  Returns a horizontal divider line as a list of styled text components.

  - `:thick` → `━━━━━━` (fills terminal width)
  - `:thin` → `──────` (fills terminal width)
  """
  @spec divider(:thick | :thin) :: [RenderNode.t()]
  def divider(:thick) do
    width = terminal_width()
    [styled(text(String.duplicate("━", width)), @divider_style)]
  end

  def divider(:thin) do
    width = terminal_width()
    [styled(text(String.duplicate("─", width)), @divider_style)]
  end

  @doc """
  Returns a scroll indicator as a list of styled text components.

  - `:up` → `  ▲ more above`
  - `:down` → `  ▼ more below`
  """
  @spec scroll_indicator(:up | :down) :: [RenderNode.t()]
  def scroll_indicator(:up) do
    [styled(text("  ▲ more above"), @scroll_style)]
  end

  def scroll_indicator(:down) do
    [styled(text("  ▼ more below"), @scroll_style)]
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp terminal_width do
    case TermUI.Terminal.get_terminal_size() do
      {:ok, {_rows, cols}} -> cols
      _ -> 80
    end
  rescue
    _ -> 80
  catch
    :exit, _ -> 80
  end
end
