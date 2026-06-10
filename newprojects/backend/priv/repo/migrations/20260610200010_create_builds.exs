defmodule Immo.Repo.Migrations.CreateBuilds do
  @moduledoc """
  P1-E2.1 §5.10 — `builds` (rebuild pipeline, §3.2).

  Per §5.10:
    * `status` enum: `queued | running | succeeded | failed | skipped`
    * `trigger` enum: `cron | manual`
    * `content_snapshot_at`: the `since` cursor from `/api/v1?since=` (the
      load-time `__build.json` value), useful for debugging a build that
      ran stale.
    * `built_at`: the `built_at` recorded in the static site's
      `__build.json` (written by the Worker after deploy).
    * `git_sha`: which commit produced the snapshot.
  """

  use Ecto.Migration

  def change do
    create table(:builds, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :status, :string, null: false, default: "queued"
      add :trigger, :string, null: false

      add :content_snapshot_at, :timestamptz
      add :started_at, :timestamptz
      add :finished_at, :timestamptz
      add :built_at, :timestamptz

      add :error, :text
      add :git_sha, :string

      timestamps(type: :timestamptz)
    end

    # Build dashboard is the main read: latest first.
    create index(:builds, desc: :inserted_at)
  end
end
