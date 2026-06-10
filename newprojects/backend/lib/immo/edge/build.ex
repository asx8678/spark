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

  P1-E2.5's `Immo.Edge` context owns the deploy-hook client and the
  KV writes for freshness; the build runner itself (Oban cron) is
  in P1-E2.5 too.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

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
end
