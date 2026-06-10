defmodule Immo.Catalog.PropertyType do
  @moduledoc """
  `property_types` (§5.3) — configurable categories, R9.

  Per §5.3:
    * `key` citext unique (`apartment`, `land`, `house`, ...).
    * `label` jsonb i18n — display name per locale.
    * `url_segment` jsonb i18n — e.g. fr `appartements`, drives routes
      `/{segment}/{city}/{slug}`.
    * `filter_config` jsonb — ordered facet list the search island
      renders: `[{key, kind, source, unit, min, max, options}]`.
    * `schema_hints` jsonb — known attribute keys + types for admin
      form rendering and API validation.
    * `position` integer.

  Referenced by `Listing` and `CustomField`. Migrations in P1-E2.1
  create this table with uuid v7 PK per the §5 preamble; the schema
  is the Ecto mapping. Changeset (slug immutability, position
  uniqueness) lands in P1-E2.2.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "property_types" do
    field :key, :string
    field :label, :map
    field :url_segment, :map
    field :filter_config, :map
    field :schema_hints, :map
    field :position, :integer

    timestamps(type: :utc_datetime)
  end
end
