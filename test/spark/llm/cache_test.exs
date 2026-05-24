defmodule Spark.LLM.CacheTest do
  use ExUnit.Case, async: true

  alias Spark.LLM.Cache

  describe "build_messages/2" do
    test "builds empty list from empty parts" do
      assert Cache.build_messages([]) == []
    end

    test "builds messages in correct order" do
      messages =
        Cache.build_messages(
          static_prefix: [%{role: "system", content: "You are an AI."}],
          project_rules: [%{role: "system", content: "Use Elixir conventions."}],
          gold_memory: [%{role: "system", content: "Past knowledge here."}],
          silver_memory: [%{role: "system", content: "Session summary."}],
          session_history: [
            %{role: "user", content: "Fix bug"},
            %{role: "assistant", content: "Done"}
          ],
          current_user_input: [%{role: "user", content: "New request"}]
        )

      # First message should be version marker
      assert [%{role: "system", content: content} | rest] = messages
      assert String.starts_with?(content, "[spark:prefix_version:")

      # Then static content
      assert Enum.at(rest, 0).content == "You are an AI."
      assert Enum.at(rest, 1).content == "Use Elixir conventions."
      assert Enum.at(rest, 2).content == "Past knowledge here."

      # Then dynamic (after boundary marker)
      assert Enum.at(rest, 3).content == "[spark:dynamic_boundary]"
      assert Enum.at(rest, 4).content == "Session summary."
      assert Enum.at(rest, 5).content == "Fix bug"
      assert Enum.at(rest, 6).content == "Done"
      assert Enum.at(rest, 7).content == "New request"
    end

    test "omits version marker when no static content" do
      messages = Cache.build_messages(session_history: [%{role: "user", content: "Hello"}])

      # No version marker since no static content
      refute Enum.any?(messages, fn m ->
               String.starts_with?(Map.get(m, :content, ""), "[spark:prefix_version:")
             end)
    end

    test "includes version in prefix marker" do
      messages =
        Cache.build_messages(
          [static_prefix: [%{role: "system", content: "System prompt"}]],
          prompt_version: "v2"
        )

      assert [%{content: "[spark:prefix_version:v2]"} | _] = messages
    end

    test "handles worker_result category" do
      messages =
        Cache.build_messages(
          static_prefix: [%{role: "system", content: "Sys"}],
          worker_result: [%{role: "assistant", content: "Task completed"}]
        )

      # Should include worker_result at the end
      assert List.last(messages).content == "Task completed"
    end

    test "skips nil/missing categories" do
      messages =
        Cache.build_messages(
          static_prefix: [%{role: "system", content: "Sys"}],
          gold_memory: nil,
          session_history: [%{role: "user", content: "Hi"}]
        )

      # version marker + sys + hi + boundary = 4
      assert length(messages) == 4
    end
  end

  describe "prefix_hash/1" do
    test "hash is stable with same static content" do
      messages =
        Cache.build_messages(
          static_prefix: [%{role: "system", content: "Fixed prompt"}],
          session_history: [%{role: "user", content: "Hello"}]
        )

      hash1 = Cache.prefix_hash(messages)
      hash2 = Cache.prefix_hash(messages)
      assert hash1 == hash2
    end

    test "hash changes when static content changes" do
      messages1 =
        Cache.build_messages(
          [
            static_prefix: [%{role: "system", content: "Prompt A"}]
          ],
          prompt_version: "v1"
        )

      messages2 =
        Cache.build_messages(
          [
            static_prefix: [%{role: "system", content: "Prompt B"}]
          ],
          prompt_version: "v1"
        )

      refute Cache.prefix_hash(messages1) == Cache.prefix_hash(messages2)
    end

    test "hash changes when prompt version changes" do
      messages_v1 =
        Cache.build_messages(
          [
            static_prefix: [%{role: "system", content: "Same prompt"}]
          ],
          prompt_version: "v1"
        )

      messages_v2 =
        Cache.build_messages(
          [
            static_prefix: [%{role: "system", content: "Same prompt"}]
          ],
          prompt_version: "v2"
        )

      refute Cache.prefix_hash(messages_v1) == Cache.prefix_hash(messages_v2)
    end

    test "dynamic content changes do not alter prefix hash" do
      base =
        Cache.build_messages(
          static_prefix: [%{role: "system", content: "System prompt"}],
          project_rules: [%{role: "system", content: "Rules"}],
          session_history: [%{role: "user", content: "First question"}]
        )

      modified =
        Cache.build_messages(
          static_prefix: [%{role: "system", content: "System prompt"}],
          project_rules: [%{role: "system", content: "Rules"}],
          session_history: [
            %{role: "user", content: "First question"},
            %{role: "assistant", content: "First answer"},
            %{role: "user", content: "Second question"}
          ]
        )

      assert Cache.prefix_hash(base) == Cache.prefix_hash(modified)
    end

    test "hash is a 64-char hex string (SHA256)" do
      messages = Cache.build_messages(static_prefix: [%{role: "system", content: "Prompt"}])

      hash = Cache.prefix_hash(messages)
      assert is_binary(hash)
      assert String.length(hash) == 64
      assert String.match?(hash, ~r/^[0-9a-f]+$/)
    end
  end

  describe "split_static_dynamic/1" do
    test "splits at system/user boundary" do
      messages =
        Cache.build_messages(
          static_prefix: [%{role: "system", content: "Sys prompt"}],
          project_rules: [%{role: "system", content: "Rules"}],
          session_history: [
            %{role: "user", content: "Question"},
            %{role: "assistant", content: "Answer"}
          ]
        )

      {static, dynamic} = Cache.split_static_dynamic(messages)

      # Static should include version marker + system messages
      assert Enum.all?(static, fn m -> m.role == "system" end)
      # Dynamic should start with user/assistant
      assert length(dynamic) >= 1
      assert hd(dynamic).role in ["user", "assistant"]
    end

    test "all messages are static when no dynamic content" do
      messages =
        Cache.build_messages(
          static_prefix: [%{role: "system", content: "Sys"}],
          project_rules: [%{role: "system", content: "Rules"}]
        )

      {static, dynamic} = Cache.split_static_dynamic(messages)
      assert length(static) >= 2
      assert dynamic == []
    end

    test "empty input returns empty tuples" do
      assert {[], []} = Cache.split_static_dynamic([])
    end
  end

  describe "invalidate/2" do
    test "returns ok with metadata" do
      assert {:ok, meta} = Cache.invalidate(:prompt_reload)
      assert Map.has_key?(meta, :invalidated_at)
      assert Map.has_key?(meta, :reason)
      assert Map.has_key?(meta, :new_version)
    end

    test "reason is preserved" do
      {:ok, meta} = Cache.invalidate(:config_reload, %{trigger: "file_watch"})
      assert meta.reason == :config_reload
      assert meta.trigger == "file_watch"
    end

    test "new_version is unique across calls" do
      {:ok, meta1} = Cache.invalidate(:test)
      {:ok, meta2} = Cache.invalidate(:test)
      refute meta1.new_version == meta2.new_version
    end

    test "dynamic compaction doesn't alter prefix hash" do
      # Simulate compaction: replace session history with summary
      before_compaction =
        Cache.build_messages(
          static_prefix: [%{role: "system", content: "You are helpful."}],
          project_rules: [%{role: "system", content: "Use SOLID."}],
          session_history: [
            %{role: "user", content: "Q1"},
            %{role: "assistant", content: "A1"},
            %{role: "user", content: "Q2"},
            %{role: "assistant", content: "A2"}
          ]
        )

      after_compaction =
        Cache.build_messages(
          static_prefix: [%{role: "system", content: "You are helpful."}],
          project_rules: [%{role: "system", content: "Use SOLID."}],
          silver_memory: [%{role: "system", content: "Session: Q1→A1, Q2→A2"}]
        )

      assert Cache.prefix_hash(before_compaction) == Cache.prefix_hash(after_compaction)
    end
  end
end
