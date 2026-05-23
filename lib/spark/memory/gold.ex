defmodule Spark.Memory.Gold do
  @moduledoc """
  Gold memory — curated, persistent knowledge notes.

  File: ~/.spark/memory/gold.md

  This is NOT a raw log dump. Gold memory contains hand-curated
  or LLM-summarized knowledge: architectural decisions, user
  preferences, project constraints, tooling tips.

  Use `append_gold/1` to add a curated note and `read_gold/0`
  to retrieve the full file for LLM prefix inclusion.
  """

  alias Spark.Config

  @gold_filename "gold.md"

  # --- Public API ---

  @doc """
  Appends a curated note to Gold memory.
  Notes are timestamped and separated by horizontal rules.
  Returns :ok or {:error, reason}.
  """
  @spec append_gold(String.t()) :: :ok | {:error, term()}
  def append_gold(note) when is_binary(note) do
    if not gold_enabled?() do
      {:error, :gold_disabled}
    else
      path = gold_path()
      File.mkdir_p!(Path.dirname(path))

      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
      entry = "\n---\n## #{timestamp}\n\n#{note}\n"

      case File.write(path, entry, [:append]) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Reads the full Gold memory file content.
  Returns {:ok, content} or {:error, reason}.
  Returns {:ok, ""} if the file doesn't exist yet.
  """
  @spec read_gold() :: {:ok, String.t()} | {:error, term()}
  def read_gold do
    if not gold_enabled?() do
      {:error, :gold_disabled}
    else
      path = gold_path()

      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> {:ok, ""}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Returns the path to the Gold memory file.
  """
  @spec gold_path() :: String.t()
  def gold_path do
    Path.join(Config.home_dir(), "memory/#{@gold_filename}")
  end

  @doc "Returns whether Gold memory is enabled."
  def gold_enabled? do
    Config.get([:memory, :gold_enabled], true) in [true, "true"]
  end
end
