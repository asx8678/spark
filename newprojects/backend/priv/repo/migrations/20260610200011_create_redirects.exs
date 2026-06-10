defmodule Immo.Repo.Migrations.CreateRedirects do
  @moduledoc """
  P1-E2.1 §5.11 — `redirects` (slug-change tracking, §3.8).

  Per §5.11:
    * `old_path` citext unique — the path before the slug change
    * `new_path` — the new path
    * `http_status` int default 301 (the spec calls out 301 as the
      permanent-redirect default)
    * `reason` — free-form note for the admin

  The Worker entry (the frontend) consults `redirects.json` (a build
  artifact generated from this table) before serving any URL, so
  slug changes are picked up at the edge with no origin request.
  """

  use Ecto.Migration

  def change do
    create table(:redirects, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :old_path, :citext, null: false
      add :new_path, :string, null: false
      add :http_status, :integer, null: false, default: 301
      add :reason, :string

      timestamps(type: :timestamptz)
    end

    create unique_index(:redirects, [:old_path])
  end
end
