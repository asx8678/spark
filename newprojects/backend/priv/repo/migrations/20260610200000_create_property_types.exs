defmodule Immo.Repo.Migrations.CreatePropertyTypes do
  @moduledoc """
  P1-E2.1 §5.3 — `property_types` (configurable categories, R9).

  Per §5 preamble: `id uuid` v7 PK, timestamptz timestamps, citext slugs.
  `key` is the unique programmatic identifier (`apartment`, `land`, ...).
  `label` and `url_segment` are i18n jsonb maps; the frontend renders
  per-locale labels and the route segment in fr/ar/en.

  This table has no FK and is referenced by `listings` and `custom_fields`,
  so it migrates first (after the existing P1-E1.1 tables).
  """

  use Ecto.Migration

  def change do
    create table(:property_types, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")
      add :key, :citext, null: false
      add :label, :map
      add :url_segment, :map
      add :filter_config, :map
      add :schema_hints, :map
      add :position, :integer, default: 0, null: false

      timestamps(type: :timestamptz)
    end

    create unique_index(:property_types, [:key])
    create index(:property_types, [:position])
  end
end
