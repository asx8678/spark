defmodule Immo.Edge.Build do
  @moduledoc """
  `builds` (§5.10) — the rebuild pipeline state, §3.2.

  Per §5.10:
    * `status` enum: `queued | running | succeeded | failed | skipped`.
    * `trigger` enum: `cron | manual`.
    * `content_snapshot_at` — the `since` cursor used for the build's
      `/api/v1?since=` load.
    * `started_at`, `finished_at` — wall-clock of the run.
    * `built_at` — the `built_at` recorded in the static site's
      `__build.json` (written by the Worker after deploy).
    * `error` — failure text (the build dashboard banner reads this).
    * `git_sha` — which commit produced the snapshot.

  The `Immo.Edge` context (P1-E2.5) owns the deploy-hook client and
  the KV writes for freshness; the build runner itself (Oban cron)
  is in P1-E2.5 too (a stub).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(queued running succeeded failed skipped)
  @triggers ~w(cron manual)

  schema "builds" do
    field :status, :string, default: "queued"
    field :trigger, :string

    field :content_snapshot_at, :utc_datetime
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :built_at, :utc_datetime

    field :error, :string
    field :git_sha, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Allowed status values per §5.10."
  def statuses, do: @statuses

  @doc "Allowed trigger values per §5.10."
  def triggers, do: @triggers

  @doc """
  Base create changeset for a new build. Called by the Oban cron
  worker (P1-E2.5 stubs that) and by the manual "Rebuild now"
  button in the admin UI (P1-E3).
  """
  def create_changeset(build, attrs) do
    build
    |> cast(attrs, [
      :status,
      :trigger,
      :content_snapshot_at,
      :started_at,
      :finished_at,
      :built_at,
      :error,
      :git_sha
    ])
    |> validate_required([:trigger])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:trigger, @triggers)
  end

  @doc """
  Apply a status transition. The Oban worker calls this as the
  build progresses (queued → running → succeeded/failed). The
  changeset is a one-purpose helper so callers don't reach into
  the schema directly.
  """
  def transition_changeset(build, new_status, attrs \\ %{}) do
    build
    |> cast(attrs, [:started_at, :finished_at, :built_at, :error, :git_sha])
    |> Ecto.Changeset.change(%{status: new_status})
    |> validate_inclusion(:status, @statuses)
  end
end
