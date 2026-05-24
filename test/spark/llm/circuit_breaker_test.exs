defmodule Spark.LLM.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias Spark.LLM.CircuitBreaker

  setup do
    # Start the GenServer (and ETS table) for each test
    {:ok, pid} = CircuitBreaker.start_link(name: :test_cb)
    # Clean up any stale state for our test provider
    :ets.delete(:spark_circuit_breakers, :test_provider)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    :ok
  end

  describe "allow?/1" do
    test "allows calls when circuit is closed (default)" do
      assert CircuitBreaker.allow?(:test_provider) == true
    end

    test "fails open when ETS table does not exist" do
      # Delete the table to simulate it not existing
      :ets.delete(:spark_circuit_breakers)
      assert CircuitBreaker.allow?(:test_provider) == true
    end
  end

  describe "success/1 and failure/1" do
    test "success resets failure count" do
      CircuitBreaker.failure(:test_provider)
      CircuitBreaker.failure(:test_provider)
      # Only 2 failures — circuit still closed
      assert CircuitBreaker.allow?(:test_provider) == true

      CircuitBreaker.success(:test_provider)
      # Now failure count is reset; need 3 fresh failures to open
      CircuitBreaker.failure(:test_provider)
      assert CircuitBreaker.allow?(:test_provider) == true
    end

    test "3 failures within window opens the circuit" do
      CircuitBreaker.failure(:test_provider)
      CircuitBreaker.failure(:test_provider)
      assert CircuitBreaker.allow?(:test_provider) == true

      CircuitBreaker.failure(:test_provider)
      assert match?({:error, :circuit_open, _}, CircuitBreaker.allow?(:test_provider))
    end

    test "success in half-open state closes the circuit" do
      # Open the circuit
      CircuitBreaker.failure(:test_provider)
      CircuitBreaker.failure(:test_provider)
      CircuitBreaker.failure(:test_provider)
      assert match?({:error, :circuit_open, _}, CircuitBreaker.allow?(:test_provider))

      # Manually set half-open for testing (simulate cooldown expiry)
      :ets.insert(:spark_circuit_breakers, {:test_provider, :half_open, [], 0})

      # Allow the probe
      assert CircuitBreaker.allow?(:test_provider) == false ||
               match?({:error, :circuit_open, _}, CircuitBreaker.allow?(:test_provider))

      # Success closes the circuit
      CircuitBreaker.success(:test_provider)
      assert CircuitBreaker.allow?(:test_provider) == true
    end

    test "failure in half-open state re-opens the circuit" do
      # Open the circuit
      CircuitBreaker.failure(:test_provider)
      CircuitBreaker.failure(:test_provider)
      CircuitBreaker.failure(:test_provider)

      # Manually set half-open
      :ets.insert(:spark_circuit_breakers, {:test_provider, :half_open, [], 0})

      CircuitBreaker.failure(:test_provider)

      # Should be open again
      assert match?({:error, :circuit_open, _}, CircuitBreaker.allow?(:test_provider))
    end
  end

  describe "half-open probe" do
    test "only one probe is allowed in half-open state" do
      # Open the circuit
      CircuitBreaker.failure(:test_provider)
      CircuitBreaker.failure(:test_provider)
      CircuitBreaker.failure(:test_provider)

      # Manually set half-open with an old opened_at
      :ets.insert(:spark_circuit_breakers, {:test_provider, :half_open, [], 0})

      # First allow? in half-open blocks (only the transition from open allows one)
      assert match?({:error, :circuit_open, _}, CircuitBreaker.allow?(:test_provider))
    end

    test "open circuit allows probe after cooldown" do
      # Open the circuit 31 seconds ago
      opened_at = System.monotonic_time(:millisecond) - 31_000
      :ets.insert(:spark_circuit_breakers, {:test_provider, :open, [], opened_at})

      # Should allow one probe (transition to half-open)
      assert CircuitBreaker.allow?(:test_provider) == true
    end
  end

  describe "4xx errors should not trip the circuit" do
    test "circuit breaker has no special 4xx handling — that is WaferProvider's job" do
      # The circuit breaker itself just counts failures; WaferProvider
      # decides which HTTP statuses count as failures.
      CircuitBreaker.failure(:test_provider)
      CircuitBreaker.failure(:test_provider)
      assert CircuitBreaker.allow?(:test_provider) == true
    end
  end
end
