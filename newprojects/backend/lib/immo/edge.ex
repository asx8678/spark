defmodule Immo.Edge do
  @moduledoc """
  Edge context — §6.1 bounded responsibility.

  Owns:
    * `builds` (§5.10) — the rebuild pipeline state.
    * Freshness — the Oban cron job that triggers a rebuild on
      §11 publish-affecting changes, and the KV writes that let
      the Worker entry know it's stale.
    * `Immo.Edge.Paths` — the single-path authority (P1-E5.2 fleshes
      this out; P1-E2.5 ships the placeholder).
    * The deploy-hook client (calls the Worker's deploy endpoint
      after a successful build).

  Out of scope for P1-E2.5:
    * The actual cron worker (P3/P4).
    * The KV-freshness writes (P3/P4).
    * The deploy-hook client (P3/P4).
    * The full `Immo.Edge.Paths` (P1-E5.2).
  """

  alias Immo.Edge.Build
  alias Immo.Repo

  ## Builds

  @doc "Get a build by id (raises if not found)."
  @spec get_build!(binary()) :: Build.t()
  def get_build!(id), do: Repo.get!(Build, id)

  @doc """
  List builds, newest first. The P3 build dashboard reads this.
  """
  @spec list_builds(keyword()) :: [Build.t()]
  def list_builds(opts \\ []) do
    import Ecto.Query, only: [order_by: 2, limit: 2, offset: 2]

    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    Build
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Insert a new build row. The Oban cron worker (P3) and the manual
  "Rebuild now" button in P1-E3 call this.
  """
  @spec create_build(map(), keyword()) :: {:ok, Build.t()} | {:error, Ecto.Changeset.t()}
  def create_build(attrs, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, build} <-
             %Build{} |> Build.create_changeset(attrs) |> Repo.insert(),
           :ok <-
             Immo.Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "create",
               entity: build,
               diff: Immo.Audit.create_diff(build)
             ) do
        {:ok, build}
      end
    end)
  end

  @doc """
  Move a build through its status (queued → running → succeeded /
  failed). The Oban worker calls this as the build progresses.
  """
  @spec transition_build(Build.t(), String.t(), keyword()) ::
          {:ok, Build.t()} | {:error, Ecto.Changeset.t()}
  def transition_build(build, new_status, opts \\ []) do
    old = build

    Repo.transact(fn ->
      with {:ok, updated} <- Repo.update(Build.transition_changeset(build, new_status)),
           :ok <-
             Immo.Audit.log_mutation(
               actor_user: opts[:actor_user],
               action: "transition",
               entity: updated,
               diff:
                 Immo.Audit.update_diff(old, updated, Build.transition_changeset(old, new_status))
             ) do
        {:ok, updated}
      end
    end)
  end
end
