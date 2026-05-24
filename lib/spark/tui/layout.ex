defmodule Spark.TUI.Layout do
  @moduledoc """
  Dashboard layout engine for the Spark TUI.

  Provides the bordered split-pane layout with an 85/15 vertical
  split between the canvas zone and the command deck.

  ## Layout Structure

      ┌──────────────────────────────────────┐
      │  Canvas Zone (85% of height)         │
      │  Each line: │ {content} │            │
      │                                       │
      ├──────────────────────────────────────┤
      │  Command Deck (15% of height)        │
      │  Each line: │ {content} │            │
      └──────────────────────────────────────┘
  """

  import TermUI.Component.Helpers
  alias TermUI.Component.RenderNode
  alias TermUI.Renderer.Style
  alias TermUI.Renderer.DisplayWidth

  require Logger

  @default_width 80
  @default_height 24
  @canvas_ratio 0.85

  @border_style Style.new() |> Style.fg(:bright_black)

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Renders the full dashboard layout as a TermUI component tree.

  Takes terminal dimensions `{width, height}` and two content functions
  that each return a list of text lines for their respective zones.
  Returns a `stack(:vertical, ...)` component tree with bordered zones.

  ## Parameters

    * `{width, height}` — terminal dimensions in characters
    * `canvas_fn` — 0-arity function returning `[String.t()]` for the canvas zone
    * `deck_fn` — 0-arity function returning `[String.t()]` for the command deck zone

  ## Example

      Layout.render_dashboard({80, 24},
        fn -> ["Hello from canvas"] end,
        fn -> ["> Type here"] end
      )
  """
  @spec render_dashboard(
          {pos_integer(), pos_integer()},
          (-> [String.t()]),
          (-> [String.t()]),
          keyword()
        ) :: RenderNode.t()
  def render_dashboard({width, height}, canvas_fn, deck_fn, opts \\ []) do
    status_line = Keyword.get(opts, :status_line)
    scroll_top = Keyword.get(opts, :scroll_top, 0)

    border_rows = 3 + if status_line, do: 1, else: 0
    content_height = max(0, height - border_rows)
    ch = canvas_height(content_height)
    dh = deck_height(content_height)
    content_width = width - 4

    canvas_raw = canvas_fn.()
    max_scroll = max(0, length(canvas_raw) - ch)
    clamped_scroll = max(0, min(scroll_top, max_scroll))

    canvas_lines =
      canvas_raw
      |> Enum.drop(clamped_scroll)
      |> Enum.take(ch)
      |> pad_content(content_width, ch)

    deck_lines = deck_fn.() |> pad_content(content_width, dh)

    top = styled(text(border_line("┌", "─", "┐", width)), @border_style)
    mid = styled(text(border_line("├", "─", "┤", width)), @border_style)
    bot = styled(text(border_line("└", "─", "┘", width)), @border_style)

    canvas_rows = Enum.map(canvas_lines, &content_row(&1, width))
    deck_rows = Enum.map(deck_lines, &content_row(&1, width))

    status_row = build_status_row(status_line, width)

    stack(:vertical, [top] ++ canvas_rows ++ status_row ++ [mid] ++ deck_rows ++ [bot])
  end

  @doc """
  Returns the number of rows allocated to the canvas zone.

  Calculated as `floor(height * 0.85)`.
  """
  @spec canvas_height(pos_integer()) :: non_neg_integer()
  def canvas_height(height) when is_integer(height) and height > 0 do
    floor(height * @canvas_ratio)
  end

  @doc """
  Returns the number of rows allocated to the command deck zone.

  Calculated as the remaining rows after canvas allocation.
  """
  @spec deck_height(pos_integer()) :: non_neg_integer()
  def deck_height(height) when is_integer(height) and height > 0 do
    height - canvas_height(height)
  end

  @doc """
  Pads a list of text lines to fill a zone of the given width and height.

  Truncates lines longer than `target_width`, pads shorter lines with spaces,
  and appends empty lines to reach `target_height`.
  """
  @spec pad_content([String.t()], non_neg_integer(), non_neg_integer()) :: [String.t()]
  def pad_content(lines, target_width, target_height)
      when is_list(lines) and is_integer(target_width) and is_integer(target_height) do
    padded =
      Enum.map(lines, fn line ->
        fit_line(line, target_width)
      end)

    padding_count = max(0, target_height - length(padded))
    padding = List.duplicate(String.duplicate(" ", target_width), padding_count)

    padded ++ padding
  end

  # ── Terminal size helpers ──────────────────────────────────────────────

  @doc """
  Returns current terminal width with `80` as fallback.
  """
  @spec terminal_width() :: pos_integer()
  def terminal_width do
    case TermUI.Terminal.get_terminal_size() do
      {:ok, {_rows, cols}} -> cols
      _ -> @default_width
    end
  rescue
    _ -> @default_width
  catch
    :exit, _ -> @default_width
  end

  @doc """
  Returns current terminal height with `24` as fallback.
  """
  @spec terminal_height() :: pos_integer()
  def terminal_height do
    case TermUI.Terminal.get_terminal_size() do
      {:ok, {rows, _cols}} -> rows
      _ -> @default_height
    end
  rescue
    _ -> @default_height
  catch
    :exit, _ -> @default_height
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp border_line(left, fill, right, width) do
    left <> String.duplicate(fill, max(0, width - 2)) <> right
  end

  defp content_row(line, width) do
    content_width = width - 4
    fitted = fit_line(line, content_width)

    stack(:horizontal, [
      styled(text("│ "), @border_style),
      text(fitted),
      styled(text(" │"), @border_style)
    ])
  end

  defp build_status_row(nil, _width), do: []

  defp build_status_row({text_content, color}, width) when is_atom(color) do
    style = Style.new() |> Style.fg(color) |> Style.dim()
    content_width = width - 4
    fitted = fit_line(text_content, content_width)

    [
      stack(:horizontal, [
        styled(text("│ "), @border_style),
        styled(text(fitted), style),
        styled(text(" │"), @border_style)
      ])
    ]
  end

  defp fit_line(line, max_width) do
    {truncated, _} = DisplayWidth.truncate(line, max_width)
    DisplayWidth.pad(truncated, max_width)
  end
end
