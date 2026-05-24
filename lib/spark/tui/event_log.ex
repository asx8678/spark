defmodule Spark.TUI.EventLog do
  @moduledoc """
  ETS-backed ring buffer for capturing Spark EventBus events.

  Provides a safe, crash-proof bridge between the synchronous EventBus hook
  system and the Ratatouille TUI. Events are stored with monotonic integer
  keys for easy ordering, capped at 200 entries.
  """

  @table :spark_tui_event_log
  @max_entries 200

  # --- Public API ---

  @doc """
  Installs an EventBus hook that appends every published event.
  Idempotent — safe to call multiple times.
  """
  @spec install_hook() :: :ok
  def install_hook do
    ensure_table()
    Spark.EventBus.add_hook(:tui_event_log, fn event -> append(event) end)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Appends a normalized log entry to the ring buffer.
  Caps to #{@max_entries} newest entries by pruning oldest when over limit.
  Never crashes the caller.
  """
  @spec append(Spark.Types.Event.t()) :: :ok
  def append(%Spark.Types.Event{} = event) do
    ensure_table()

    entry = %{
      at: DateTime.utc_now(),
      type: event.type,
      topic: event.topic,
      source: event.source,
      session_id: event.session_id,
      plan_id: event.plan_id,
      task_id: event.task_id,
      payload: event.payload
    }

    key = System.unique_integer([:monotonic, :positive])
    :ets.insert(@table, {key, entry})
    prune()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def append(_), do: :ok

  @doc """
  Returns the newest `limit` entries, newest first.
  """
  @spec list(pos_integer()) :: [map()]
  def list(limit \\ 50) when is_integer(limit) and limit > 0 do
    ensure_table()

    :ets.tab2list(@table)
    |> Enum.sort_by(fn {key, _entry} -> key end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_key, entry} -> entry end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Clears all entries from the ring buffer.
  """
  @spec clear() :: :ok
  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # --- Private ---

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :named_table, :public, write_concurrency: true])

      _tid ->
        :ok
    end
  end

  defp prune do
    count = :ets.info(@table, :size)

    if count > @max_entries do
      # Find oldest entries to delete (smallest keys)
      keys =
        :ets.tab2list(@table)
        |> Enum.sort_by(fn {key, _} -> key end)
        |> Enum.take(count - @max_entries)
        |> Enum.map(fn {key, _} -> key end)

      Enum.each(keys, fn key -> :ets.delete(@table, key) end)
    end

    :ok
  rescue
    _ -> :ok
  end
end
