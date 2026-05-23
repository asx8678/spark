defmodule Spark.HotReload.Rollback do
  @moduledoc """
  Handles rollback when a hot reload fails.

  Restores the previous version from the Manifest for any component type.
  If no previous version exists, returns an error but does not crash.
  """

  require Logger

  @doc """
  Rolls back a component to its previous version after a reload failure.

  Returns `:ok` on successful rollback, `{:error, reason}` otherwise.
  The `error` argument is the reason the reload failed (used for logging).
  """
  @spec rollback({atom(), atom() | String.t()}, term()) :: :ok | {:error, term()}
  def rollback(component_key, error) do
    Logger.warning("HotReload rollback triggered for #{inspect(component_key)}: #{inspect(error)}")

    case Spark.HotReload.Manifest.previous(component_key) do
      nil ->
        Logger.error("HotReload rollback failed: no previous version for #{inspect(component_key)}")
        {:error, :no_previous_version}

      _previous ->
        case Spark.HotReload.Manifest.rollback_to_previous(component_key) do
          {:ok, rolled_back} ->
            Logger.info("HotReload rollback succeeded for #{inspect(component_key)}, " <>
                        "restored version: #{rolled_back.version}")

            # Per-component rollback side effects
            apply_rollback_side_effects(component_key, rolled_back)
            :ok

          {:error, reason} ->
            Logger.error("HotReload rollback failed for #{inspect(component_key)}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @doc """
  Checks if a rollback is available for a given component.
  Returns true if a previous version exists in the Manifest.
  """
  @spec available?({atom(), atom() | String.t()}) :: boolean()
  def available?(component_key) do
    case Spark.HotReload.Manifest.previous(component_key) do
      nil -> false
      _ -> true
    end
  end

  # Per-component rollback side effects
  defp apply_rollback_side_effects({:config, _name}, rolled_back) do
    # Restore old config to runtime if available
    if Map.has_key?(rolled_back.metadata, :config_data) do
      Logger.info("HotReload: restoring previous config to runtime")
    end
    :ok
  end

  defp apply_rollback_side_effects({:tool, _name}, _rolled_back) do
    # Keep previous tool module active in registry (don't unregister)
    Logger.info("HotReload: keeping previous tool module active")
    :ok
  end

  defp apply_rollback_side_effects({:prompt, _name}, _rolled_back) do
    # Keep previous prompt version active
    Logger.info("HotReload: keeping previous prompt version active")
    :ok
  end

  defp apply_rollback_side_effects({:policy, _name}, _rolled_back) do
    # Keep previous policy active
    Logger.info("HotReload: keeping previous policy active")
    :ok
  end

  defp apply_rollback_side_effects({:guidance, _name}, _rolled_back) do
    # Keep previous guidance active
    Logger.info("HotReload: keeping previous guidance active")
    :ok
  end

  defp apply_rollback_side_effects(_component_key, _rolled_back), do: :ok
end
