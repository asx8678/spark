defmodule Immo.Repo.Migrations.CreateCustomFields do
  @moduledoc """
  P1-E2.1 §5.5 — `custom_fields` (admin-defined, per property type — R9).

  Values live inside `listings.attributes` under the field key — no
  EAV tables. The `key` is `citext` and unique **per property_type**;
  the composite unique index `(property_type_id, key)` enforces this
  at the DB level.

  `field_type` is a string holding one of `string | integer | decimal |
  boolean | select | multiselect | date` per §5.5. The DB doesn't enforce
  the enum shape (we use a regular string column); the changeset in
  P1-E2.2 will validate against the same set.

  `options` jsonb is for `select` / `multiselect` field types; nullable
  for the others.
  """

  use Ecto.Migration

  def change do
    create table(:custom_fields, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :property_type_id,
          references(:property_types, type: :binary_id, on_delete: :delete_all), null: false

      add :key, :citext, null: false
      add :label, :map
      add :field_type, :string, null: false
      add :options, :map
      add :searchable, :boolean, default: false, null: false
      add :required, :boolean, default: false, null: false
      add :position, :integer, default: 0, null: false

      timestamps(type: :timestamptz)
    end

    # §5.5: key citext unique per type (composite)
    create unique_index(:custom_fields, [:property_type_id, :key])
    create index(:custom_fields, [:property_type_id, :position])
  end
end
