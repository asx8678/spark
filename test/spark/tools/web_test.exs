defmodule Spark.Tools.WebTest do
  use ExUnit.Case, async: false

  alias Spark.Tools.{WebFetch, WebSearch}

  describe "WebFetch.execute/2" do
    test "returns error when url is missing" do
      assert {:error, reason} = WebFetch.execute(%{}, %{})
      assert reason.reason == :missing_url
    end

    # Note: Real network tests are intentionally skipped to avoid flakiness.
    # Uncomment for integration testing:
    #
    # test "fetches a real URL", %{project_root: _root} do
    #   assert {:ok, result} = WebFetch.execute(%{url: "https://example.com"}, %{timeout_ms: 10_000})
    #   assert result.status == 200
    #   assert is_binary(result.title)
    #   assert is_binary(result.text)
    # end
  end

  describe "WebSearch.execute/2" do
    test "returns placeholder response with query" do
      assert {:ok, result} = WebSearch.execute(%{query: "Elixir programming"}, %{})
      assert result.query == "Elixir programming"
      assert result.status == :placeholder
      assert is_binary(result.note)
      assert is_binary(result.suggestion)
    end

    test "returns error when query is missing" do
      assert {:error, reason} = WebSearch.execute(%{}, %{})
      assert reason.reason == :missing_query
    end
  end

  describe "WebFetch schema and metadata" do
    test "WebFetch has correct name" do
      assert WebFetch.name() == "web_fetch"
    end

    test "WebFetch has medium risk" do
      assert WebFetch.risk() == :medium
    end

    test "WebSearch has correct name" do
      assert WebSearch.name() == "web_search"
    end

    test "WebSearch has low risk" do
      assert WebSearch.risk() == :low
    end
  end
end
