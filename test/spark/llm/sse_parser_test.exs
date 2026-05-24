defmodule Spark.LLM.SSEParserTest do
  use ExUnit.Case, async: true

  alias Spark.LLM.SSEParser

  describe "parse_line/1" do
    test "parses valid data line" do
      line = ~s(data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello"}}]})

      assert {:ok, parsed} = SSEParser.parse_line(line)
      assert parsed["id"] == "chatcmpl-1"
      assert parsed["choices"] != nil
    end

    test "parses data line with usage" do
      line =
        ~s(data: {"id":"chatcmpl-2","choices":[{"delta":{"content":" world"}}],"usage":{"prompt_tokens":10}})

      assert {:ok, parsed} = SSEParser.parse_line(line)
      assert parsed["usage"]["prompt_tokens"] == 10
    end

    test "detects [DONE] sentinel" do
      assert {:done} = SSEParser.parse_line("data: [DONE]")
    end

    test "detects [DONE] without space after colon" do
      assert {:done} = SSEParser.parse_line("data:[DONE]")
    end

    test "ignores empty lines" do
      assert :ignore = SSEParser.parse_line("")
      assert :ignore = SSEParser.parse_line("   ")
    end

    test "ignores keepalive comments" do
      assert :ignore = SSEParser.parse_line(": keepalive")
      assert :ignore = SSEParser.parse_line(": ping")
      assert :ignore = SSEParser.parse_line(":")
    end

    test "returns error for malformed JSON" do
      line = "data: {not valid json!!!"
      assert {:error, {:json_decode_error, _}} = SSEParser.parse_line(line)
    end

    test "returns error for non-object JSON" do
      line = "data: [1,2,3]"
      assert {:error, {:unexpected_json_type, _}} = SSEParser.parse_line(line)
    end

    test "ignores unknown line formats" do
      assert :ignore = SSEParser.parse_line("event: message")
      assert :ignore = SSEParser.parse_line("id: 123")
    end

    test "returns error for non-string input" do
      assert {:error, :invalid_input} = SSEParser.parse_line(42)
    end

    test "parses tool_calls in delta" do
      line =
        ~s(data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"read_file","arguments":"{}"}}]}}]})

      assert {:ok, parsed} = SSEParser.parse_line(line)
      [choice | _] = parsed["choices"]
      assert choice["delta"]["tool_calls"] != nil
    end
  end

  describe "parse_stream/1" do
    test "parses single data line" do
      stream = ~s(data: {"id":"1","choices":[{"delta":{"content":"Hi"}}]})

      assert [{:ok, parsed}] = SSEParser.parse_stream(stream)
      assert parsed["id"] == "1"
    end

    test "parses multiple lines" do
      stream =
        Enum.join(
          [
            ~s(data: {"id":"1","choices":[{"delta":{"content":"Hello"}}]}),
            "",
            ~s(data: {"id":"2","choices":[{"delta":{"content":" World"}}]})
          ],
          "\n"
        )

      results = SSEParser.parse_stream(stream)
      assert length(results) == 2
      assert match?([{:ok, _}, {:ok, _}], results)
    end

    test "handles [DONE] at end of stream" do
      stream =
        Enum.join(
          [
            ~s(data: {"id":"1","choices":[{"delta":{"content":"End"}}]}),
            "",
            "data: [DONE]"
          ],
          "\n"
        )

      results = SSEParser.parse_stream(stream)
      assert length(results) == 2
      assert {:done} == List.last(results)
    end

    test "filters out empty lines and comments" do
      stream =
        Enum.join(
          [
            ": keepalive",
            "",
            ~s(data: {"id":"1","choices":[{"delta":{"content":"X"}}]}),
            "",
            "data: [DONE]"
          ],
          "\n"
        )

      results = SSEParser.parse_stream(stream)
      assert length(results) == 2
    end

    test "handles malformed line in stream" do
      stream =
        Enum.join(
          [
            ~s(data: {"id":"1","choices":[{"delta":{"content":"OK"}}]}),
            "",
            "data: {bad json",
            "",
            "data: [DONE]"
          ],
          "\n"
        )

      results = SSEParser.parse_stream(stream)
      assert length(results) == 3
      assert match?([{:ok, _}, {:error, _}, {:done}], results)
    end

    test "mixed stream with done" do
      stream =
        Enum.join(
          [
            ~s(data: {"id":"c1","choices":[{"delta":{"content":"H"}}]}),
            "",
            ~s(data: {"id":"c2","choices":[{"delta":{"content":"i"}}]}),
            "",
            "data: [DONE]"
          ],
          "\n"
        )

      results = SSEParser.parse_stream(stream)
      assert [{:ok, _}, {:ok, _}, {:done}] = results
    end

    test "stops after DONE" do
      stream =
        Enum.join(
          [
            ~s(data: {"id":"1","choices":[{"delta":{"content":"before"}}]}),
            "",
            "data: [DONE]",
            "",
            ~s(data: {"id":"2","choices":[{"delta":{"content":"after"}}]})
          ],
          "\n"
        )

      results = SSEParser.parse_stream(stream)
      assert [{:ok, _}, {:done}] = results
    end
  end

  describe "parse_stream/2 (buffered)" do
    test "returns empty results and buffer when line is incomplete" do
      partial = "data: {\"id\""

      {results, buffer} = SSEParser.parse_stream(partial, "")
      assert results == []
      assert buffer == partial
    end

    test "reassembles split JSON line across two packets" do
      first_packet = "data: {\"id\":\"1\",\"choices\""
      second_packet = ~s(:[{"delta":{"content":"Hi"}}]}) <> "\n\ndata: [DONE]\n"

      {results1, buffer1} = SSEParser.parse_stream(first_packet, "")
      assert results1 == []
      assert buffer1 == first_packet

      {results2, buffer2} = SSEParser.parse_stream(second_packet, buffer1)
      assert length(results2) == 2
      assert {:ok, parsed} = Enum.at(results2, 0)
      assert parsed["id"] == "1"
      assert {:done} = List.last(results2)
      assert buffer2 == ""
    end

    test "preserves existing buffer when new data is also incomplete" do
      # Split: data: {"choices  → first: data: {"cho, second: ices
      first_partial = "data: {\"cho"
      {results1, buf1} = SSEParser.parse_stream(first_partial, "")
      assert results1 == []

      {results2, buf2} = SSEParser.parse_stream("ices", buf1)
      assert results2 == []
      assert buf2 == "data: {\"choices"
    end

    test "clears buffer after DONE" do
      stream = "data: [DONE]\ndata: leftover"
      {results, buffer} = SSEParser.parse_stream(stream, "")
      assert [{:done}] = results
      assert buffer == ""
    end

    test "empty input with empty buffer" do
      {results, buffer} = SSEParser.parse_stream("", "")
      assert results == []
      assert buffer == ""
    end

    test "empty input with existing buffer preserves it" do
      {results, buffer} = SSEParser.parse_stream("", "data: {\"id\"")
      assert results == []
      assert buffer == "data: {\"id\""
    end

    test "complete lines pass through, partial is buffered" do
      stream = "data: {\"id\":\"1\"}\n\ndata: {\"id\":\"2\""
      {results, buffer} = SSEParser.parse_stream(stream, "")

      assert length(results) == 1
      assert {:ok, parsed} = hd(results)
      assert parsed["id"] == "1"
      assert buffer == "data: {\"id\":\"2\""
    end

    test "parse_stream/1 backward compatibility" do
      stream = ~s(data: {"id":"1","choices":[{"delta":{"content":"Hi"}}]})

      # parse_stream/1 returns just the results list (no tuple)
      assert [{:ok, _}] = SSEParser.parse_stream(stream)
    end
  end
end
