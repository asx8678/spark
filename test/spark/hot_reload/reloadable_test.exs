defmodule Spark.HotReload.ReloadableTest do
  use ExUnit.Case, async: true

  alias Spark.HotReload.Reloadable

  # A test module that implements the Reloadable behaviour
  defmodule TestReloadable do
    @behaviour Spark.HotReload.Reloadable

    @impl true
    def reload_key, do: {:test, :example}

    @impl true
    def version, do: "v1.0.0"

    @impl true
    def validate_reload(_opts), do: :ok

    @impl true
    def before_reload(state), do: {:ok, state}

    @impl true
    def after_reload(state, _metadata), do: {:ok, state}
  end

  # A module that does NOT implement Reloadable
  defmodule NotReloadable do
    def some_function, do: :ok
  end

  describe "implements?/1" do
    test "returns true for a module implementing all callbacks" do
      assert Reloadable.implements?(TestReloadable)
    end

    test "returns false for a module not implementing the behaviour" do
      refute Reloadable.implements?(NotReloadable)
    end

    test "returns false for a non-existent module" do
      refute Reloadable.implements?(NonExistentModule12345)
    end

    test "returns false for nil" do
      refute Reloadable.implements?(nil)
    end
  end

  describe "validate/2" do
    test "calls validate_reload on a valid reloadable module" do
      assert :ok = Reloadable.validate(TestReloadable)
    end

    test "returns error for non-reloadable module" do
      assert {:error, {:not_reloadable, NotReloadable}} = Reloadable.validate(NotReloadable)
    end

    test "passes opts to validate_reload" do
      # Our test module accepts any opts
      assert :ok = Reloadable.validate(TestReloadable, %{force: true})
    end
  end

  describe "before_reload/2" do
    test "calls before_reload on a valid reloadable module" do
      assert {:ok, :my_state} = Reloadable.before_reload(TestReloadable, :my_state)
    end

    test "returns error for non-reloadable module" do
      assert {:error, {:not_reloadable, NotReloadable}} =
               Reloadable.before_reload(NotReloadable, :state)
    end
  end

  describe "after_reload/2" do
    test "calls after_reload on a valid reloadable module" do
      assert {:ok, :my_state} = Reloadable.after_reload(TestReloadable, :my_state, %{})
    end

    test "passes metadata to after_reload" do
      assert {:ok, :my_state} =
               Reloadable.after_reload(TestReloadable, :my_state, %{version: "v2"})
    end

    test "returns error for non-reloadable module" do
      assert {:error, {:not_reloadable, NotReloadable}} =
               Reloadable.after_reload(NotReloadable, :state, %{})
    end
  end

  describe "behaviour contract" do
    test "reload_key returns a tuple" do
      assert match?({_, _}, TestReloadable.reload_key())
    end

    test "version returns a string" do
      assert is_binary(TestReloadable.version())
    end

    test "validate_reload returns ok or error" do
      result = TestReloadable.validate_reload(%{})
      assert result == :ok or match?({:error, _}, result)
    end

    test "before_reload returns ok tuple or error tuple" do
      result = TestReloadable.before_reload(:state)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "after_reload returns ok tuple or error tuple" do
      result = TestReloadable.after_reload(:state, %{})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # A reloadable that rejects validation
  defmodule RejectingReloadable do
    @behaviour Spark.HotReload.Reloadable

    @impl true
    def reload_key, do: {:test, :rejecting}

    @impl true
    def version, do: "v1.0.0"

    @impl true
    def validate_reload(_opts), do: {:error, :rejected}

    @impl true
    def before_reload(_state), do: {:error, :no_before}

    @impl true
    def after_reload(_state, _metadata), do: {:error, :no_after}
  end

  describe "modules that reject reload" do
    test "validate returns the rejection" do
      assert {:error, :rejected} = Reloadable.validate(RejectingReloadable)
    end

    test "before_reload propagates rejection" do
      assert {:error, :no_before} = Reloadable.before_reload(RejectingReloadable, :state)
    end

    test "after_reload propagates rejection" do
      assert {:error, :no_after} = Reloadable.after_reload(RejectingReloadable, :state, %{})
    end

    test "implements? still returns true" do
      assert Reloadable.implements?(RejectingReloadable)
    end
  end
end
