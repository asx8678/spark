defmodule Spark.TUI.LayoutTest do
  use ExUnit.Case, async: true

  alias Spark.TUI.Layout
  alias TermUI.Component.RenderNode

  # ── 1. Canvas/Deck height calculations ────────────────────────────────

  describe "canvas_height/1" do
    test "standard 24-row terminal returns 20 (floor 24 * 0.85)" do
      assert Layout.canvas_height(24) == 20
    end

    test "40-row terminal returns 34" do
      assert Layout.canvas_height(40) == 34
    end

    test "10-row small terminal returns 8" do
      assert Layout.canvas_height(10) == 8
    end

    test "80-row large terminal returns 68" do
      assert Layout.canvas_height(80) == 68
    end

    test "single row terminal returns 0" do
      assert Layout.canvas_height(1) == 0
    end

    test "always returns a non-negative integer" do
      for h <- 1..200 do
        assert Layout.canvas_height(h) >= 0
      end
    end

    test "canvas ratio is approximately 0.85" do
      # For large heights, canvas_height/h should approach 0.85
      ratio = Layout.canvas_height(1000) / 1000
      assert_in_delta ratio, 0.85, 0.001
    end
  end

  describe "deck_height/1" do
    test "standard 24-row terminal returns 4" do
      assert Layout.deck_height(24) == 4
    end

    test "40-row terminal returns 6" do
      assert Layout.deck_height(40) == 6
    end

    test "10-row small terminal returns 2" do
      assert Layout.deck_height(10) == 2
    end

    test "80-row large terminal returns 12" do
      assert Layout.deck_height(80) == 12
    end

    test "always returns a non-negative integer" do
      for h <- 1..200 do
        assert Layout.deck_height(h) >= 0
      end
    end
  end

  describe "canvas_height + deck_height == total height (partition invariant)" do
    test "holds for height 24" do
      assert Layout.canvas_height(24) + Layout.deck_height(24) == 24
    end

    test "holds for height 40" do
      assert Layout.canvas_height(40) + Layout.deck_height(40) == 40
    end

    test "holds for all sizes from 1 to 200" do
      for h <- 1..200 do
        assert Layout.canvas_height(h) + Layout.deck_height(h) == h,
               "Partition invariant broken for height #{h}"
      end
    end

    test "holds for minimum terminal size 40×10" do
      assert Layout.canvas_height(10) + Layout.deck_height(10) == 10
    end

    test "holds for maximum terminal size 200×60" do
      assert Layout.canvas_height(60) + Layout.deck_height(60) == 60
    end
  end

  # ── 2. Content padding ────────────────────────────────────────────────

  describe "pad_content/3" do
    test "pads shorter lines with spaces to target width" do
      result = Layout.pad_content(["hi"], 10, 1)
      assert result == ["hi        "]
    end

    test "truncates lines longer than target width" do
      result = Layout.pad_content(["abcdefghijklmnopqrstuvwxyz"], 10, 1)
      assert length(result) == 1
      # DisplayWidth.truncate ensures display width <= 10
      assert TermUI.Renderer.DisplayWidth.string_width(hd(result)) <= 10
    end

    test "adds empty lines to reach target height" do
      result = Layout.pad_content(["one"], 10, 4)
      assert length(result) == 4
      assert hd(result) =~ ~r/^one\s*$/
      # Remaining lines should be spaces only
      for line <- Enum.drop(result, 1) do
        assert String.trim(line) == ""
      end
    end

    test "does not truncate lines when input exceeds target height" do
      # pad_content only pads shorter content — it does NOT truncate excess lines
      # This is by design: the caller (render_dashboard) controls line count via content functions
      result = Layout.pad_content(["a", "b", "c", "d", "e"], 5, 3)
      assert length(result) == 5
    end

    test "handles empty input by padding to target height" do
      result = Layout.pad_content([], 10, 3)
      assert length(result) == 3

      for line <- result do
        assert String.trim(line) == ""
      end
    end

    test "handles empty input with zero target height" do
      result = Layout.pad_content([], 10, 0)
      assert result == []
    end

    test "each padded line has correct display width" do
      result = Layout.pad_content(["short", "medium line"], 20, 4)

      for line <- result do
        assert TermUI.Renderer.DisplayWidth.string_width(line) == 20
      end
    end

    test "preserves content of correctly-sized lines" do
      result = Layout.pad_content(["hello     "], 10, 1)
      assert hd(result) == "hello     "
    end

    test "handles single character width" do
      result = Layout.pad_content(["abc"], 1, 1)
      assert length(result) == 1
      assert TermUI.Renderer.DisplayWidth.string_width(hd(result)) <= 1
    end
  end

  # ── 3. Dashboard rendering ────────────────────────────────────────────

  describe "render_dashboard/3" do
    test "produces a vertical stack component tree" do
      tree =
        Layout.render_dashboard(
          {80, 24},
          fn -> ["Canvas content"] end,
          fn -> ["Deck content"] end
        )

      assert %RenderNode{type: :stack, direction: :vertical} = tree
    end

    test "has correct number of rows for 80×24 terminal" do
      tree =
        Layout.render_dashboard(
          {80, 24},
          fn -> ["Canvas"] end,
          fn -> ["Deck"] end
        )

      assert length(tree.children) == 24
    end

    test "top border starts with ┌" do
      tree =
        Layout.render_dashboard(
          {80, 24},
          fn -> [] end,
          fn -> [] end
        )

      top = hd(tree.children)
      assert render_node_text(top) =~ "┌"
    end

    test "bottom border ends with ┘" do
      tree =
        Layout.render_dashboard(
          {80, 24},
          fn -> [] end,
          fn -> [] end
        )

      bot = List.last(tree.children)
      assert render_node_text(bot) =~ "┘"
    end

    test "mid border has ├ and ┤" do
      tree =
        Layout.render_dashboard(
          {80, 24},
          fn -> [] end,
          fn -> [] end
        )

      # 24 rows, no status -> content_height = 21, ch = canvas_height(21) = 17
      ch = Layout.canvas_height(21)
      mid_index = 1 + ch
      mid = Enum.at(tree.children, mid_index)
      mid_text = render_node_text(mid)
      assert mid_text =~ "├"
      assert mid_text =~ "┤"
    end

    test "does not crash with empty canvas and deck content" do
      tree =
        Layout.render_dashboard(
          {80, 24},
          fn -> [] end,
          fn -> [] end
        )

      assert %RenderNode{type: :stack} = tree
    end

    test "handles content that exceeds zone height by slicing it to canvas height" do
      many_lines = Enum.map(1..30, fn i -> "Line #{i}" end)

      tree =
        Layout.render_dashboard(
          {80, 24},
          fn -> many_lines end,
          fn -> ["Deck"] end
        )

      assert length(tree.children) == 24
    end

    test "content rows have border pipes on both sides" do
      tree =
        Layout.render_dashboard(
          {80, 24},
          fn -> ["Hello world"] end,
          fn -> ["Prompt > "] end
        )

      # First content row (index 1, after top border)
      first_content = Enum.at(tree.children, 1)
      text = render_node_text(first_content)
      assert text =~ "│"
    end

    test "with status_line option renders the status line" do
      tree_with_status =
        Layout.render_dashboard(
          {80, 24},
          fn -> [] end,
          fn -> [] end,
          status_line: {"Ready", :green}
        )

      # Status line should be rendered at the index: 1 (top) + canvas_height(20)
      status_index = 1 + Layout.canvas_height(20)
      status_node = Enum.at(tree_with_status.children, status_index)
      assert render_node_text(status_node) =~ "Ready"
    end

    test "renders correctly for minimum terminal 40×10" do
      tree =
        Layout.render_dashboard(
          {40, 10},
          fn -> ["Small canvas"] end,
          fn -> ["Tiny deck"] end
        )

      assert length(tree.children) == 10
    end

    test "renders correctly for large terminal 200×60" do
      tree =
        Layout.render_dashboard(
          {200, 60},
          fn -> ["Big canvas"] end,
          fn -> ["Big deck"] end
        )

      assert length(tree.children) == 60
    end

    test "nil status_line maintains total height" do
      tree =
        Layout.render_dashboard(
          {80, 24},
          fn -> [] end,
          fn -> [] end,
          status_line: nil
        )

      assert length(tree.children) == 24
    end
  end

  # ── 4. Edge cases ─────────────────────────────────────────────────────

  describe "edge cases" do
    test "pad_content with Unicode CJK characters (double-width)" do
      # Each CJK char is 2 columns wide
      result = Layout.pad_content(["日本語テスト"], 10, 1)
      assert length(result) == 1
      assert TermUI.Renderer.DisplayWidth.string_width(hd(result)) <= 10
    end

    test "pad_content with emoji characters" do
      # Emoji are typically 2 columns wide
      result = Layout.pad_content(["🎉🚀"], 10, 1)
      assert length(result) == 1
      assert TermUI.Renderer.DisplayWidth.string_width(hd(result)) <= 10
    end

    test "pad_content with mixed ASCII and Unicode" do
      result = Layout.pad_content(["Hello 世界"], 10, 1)
      assert length(result) == 1
      # "Hello 世界" = 5 + 1 + 4 = 10 display width, should fit exactly
      assert TermUI.Renderer.DisplayWidth.string_width(hd(result)) == 10
    end

    test "pad_content with ANSI escape sequences (treated as regular chars)" do
      # ANSI sequences are regular string characters from Elixir's perspective
      # DisplayWidth will count them as printable chars (they aren't filtered)
      ansi_line = "\e[31mRed Text\e[0m"
      result = Layout.pad_content([ansi_line], 20, 1)
      assert length(result) == 1
      # The result should not crash — graceful handling
      assert is_binary(hd(result))
    end

    test "pad_content with zero width and zero height — still returns fitted lines" do
      # pad_content doesn't remove lines, it only adds padding
      # So with 1 input line and target_height 0, we still get that 1 line
      result = Layout.pad_content(["anything"], 0, 0)
      assert length(result) == 1
      assert hd(result) == ""
    end

    test "pad_content with zero width and positive height" do
      result = Layout.pad_content(["x"], 0, 2)
      assert length(result) == 2
    end

    test "canvas_height and deck_height for odd heights partition correctly" do
      # Test some odd heights where floor might leave remainder
      for h <- [3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23] do
        ch = Layout.canvas_height(h)
        dh = Layout.deck_height(h)
        assert ch + dh == h, "Odd height #{h}: #{ch} + #{dh} != #{h}"
      end
    end

    test "render_dashboard with single character width doesn't crash" do
      # Extremely narrow terminal — content width would be negative or zero
      # width - 4 = -3, but pad_content should handle it gracefully
      tree =
        Layout.render_dashboard(
          {6, 10},
          fn -> [] end,
          fn -> [] end
        )

      assert %RenderNode{type: :stack} = tree
    end
  end

  # ── 5. Terminal size helpers ──────────────────────────────────────────

  describe "terminal_width/0" do
    test "returns 80 when TermUI Terminal is unavailable" do
      # TermUI.Terminal is a GenServer that won't be running in tests,
      # so the rescue/catch clause should return @default_width = 80
      assert Layout.terminal_width() == 80
    end
  end

  describe "terminal_height/0" do
    test "returns 24 when TermUI Terminal is unavailable" do
      # Same as above — GenServer not started in test env
      assert Layout.terminal_height() == 24
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp render_node_text(%RenderNode{type: :text, content: content}), do: content

  defp render_node_text(%RenderNode{type: :box, children: children}) do
    children
    |> Enum.map(&render_node_text/1)
    |> Enum.join("")
  end

  defp render_node_text(%RenderNode{type: :stack, children: children}) do
    children
    |> Enum.map(&render_node_text/1)
    |> Enum.join("")
  end

  defp render_node_text(%RenderNode{type: :empty}), do: ""

  defp render_node_text(_), do: ""
end
