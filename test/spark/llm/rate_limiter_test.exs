defmodule Spark.LLM.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Spark.LLM.RateLimiter

  setup do
    {:ok, pid} = RateLimiter.start_link(name: :test_rl)
    :ets.delete(:spark_rate_limiters, :test_provider)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    :ok
  end

  describe "acquire/1" do
    test "allows first call" do
      assert RateLimiter.acquire(:test_provider) == :ok
    end

    test "fails open when ETS table does not exist" do
      :ets.delete(:spark_rate_limiters)
      assert RateLimiter.acquire(:test_provider) == :ok
    end

    test "rate limits after burst capacity is exhausted" do
      # Drain the entire burst capacity (50 tokens, first acquire uses 1)
      for _ <- 1..49 do
        assert RateLimiter.acquire(:test_provider) == :ok
      end

      # 50th token is the last
      assert RateLimiter.acquire(:test_provider) == :ok

      # 51st should be rate limited
      assert match?({:error, :rate_limited, _}, RateLimiter.acquire(:test_provider))
    end

    test "tokens refill over time" do
      # Drain all tokens
      for _ <- 1..50 do
        RateLimiter.acquire(:test_provider)
      end

      # Should be rate limited
      assert match?({:error, :rate_limited, _}, RateLimiter.acquire(:test_provider))

      # Simulate time passing by manipulating the last_refill timestamp
      # Set last_refill to 1 second ago so 10 tokens refill
      now = System.monotonic_time(:millisecond)
      :ets.insert(:spark_rate_limiters, {:test_provider, 0, now - 1000})

      # Should be able to acquire again
      assert RateLimiter.acquire(:test_provider) == :ok
    end

    test "burst capacity is capped at 50" do
      # Even after a long time, tokens should not exceed 50
      now = System.monotonic_time(:millisecond)
      :ets.insert(:spark_rate_limiters, {:test_provider, 45, now - 10_000})

      # Should get 50 tokens after refill (capped), then acquire 1 = 49 remaining
      assert RateLimiter.acquire(:test_provider) == :ok

      # Check we have 49 tokens remaining
      [{:test_provider, tokens, _}] = :ets.lookup(:spark_rate_limiters, :test_provider)
      assert tokens == 49
    end
  end

  describe "per-provider isolation" do
    test "different providers have independent buckets" do
      # Drain provider A
      for _ <- 1..50 do
        RateLimiter.acquire(:provider_a)
      end

      # Provider B should still have tokens
      assert RateLimiter.acquire(:provider_b) == :ok
    end
  end
end
