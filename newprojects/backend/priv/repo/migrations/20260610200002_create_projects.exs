defmodule Immo.Repo.Migrations.CreateProjects do
  @moduledoc """
  P1-E2.1 §5.2 — `projects` (new developments, headline entity).

  i18n jsonb columns: `title` (jsonb with per-locale strings), `slug`
  (citext unique — immutable after first publish per §3.8), `description`,
  `amenities`, `seo`. The slug is citext per the §5 preamble; uniqueness
  is global across all projects.

  Indexes per §5.2: `(published_at)`, `(city, status)`, `(developer_id)`.
  The `featured` boolean drives the home-page ordering (§5.2 / §6.2
  home-page block).
  """

  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :developer_id, references(:developers, type: :binary_id, on_delete: :restrict),
        null: false

      add :title, :map
      add :slug, :citext, null: false

      add :status, :string, null: false, default: "preselling"

      add :description, :map
      add :address, :string
      add :city, :string
      add :region, :string
      add :country, :string, default: "MA", null: false, size: 2
      add :lat, :float
      add :lng, :float
      add :delivery_date, :date
      add :amenities, :map
      add :seo, :map
      add :featured, :boolean, default: false, null: false
      add :published_at, :timestamptz

      timestamps(type: :timestamptz)
    end

    create unique_index(:projects, [:slug])
    create index(:projects, [:published_at])
    create index(:projects, [:city, :status])
    create index(:projects, [:developer_id])
  end
end
