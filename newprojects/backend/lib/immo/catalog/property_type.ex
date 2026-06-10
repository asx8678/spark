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
      form rendering and API validation (consumed by
      `Immo.Catalog.Listing`'s attributes validation).
    * `position` integer.

  The `has_many :custom_fields` association is the loading path the
  R9 attributes validation uses — `Immo.Catalog.preload_property_type/2`
  eager-loads it so the listing changeset can match attribute keys
  against the per-type custom fields without a separate query.

  P1-E2.2 changesets:
    * `key` lowercase, kebab-case, globally unique.
    * `label` and `url_segment` are i18n maps — non-empty.
    * `position` non-negative integer.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "property_types" do
    field :key, :string
    field :label, :map
    field :url_segment, :map
    field :filter_config, {:array, :map}
    field :schema_hints, :map
    field :position, :integer

    has_many :custom_fields, Immo.Catalog.CustomField

    timestamps(type: :utc_datetime)
  end

  def create_changeset(property_type, attrs) do
    property_type
    |> cast(attrs, [:key, :label, :url_segment, :filter_config, :schema_hints, :position])
    |> validate_required([:key, :label, :url_segment, :position])
    |> validate_key_format()
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint(:key)
  end

  def update_changeset(property_type, attrs) do
    property_type
    |> cast(attrs, [:key, :label, :url_segment, :filter_config, :schema_hints, :position])
    |> validate_required([:key, :label, :url_segment, :position])
    |> validate_key_format()
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint(:key)
  end

  defp validate_key_format(changeset) do
    changeset
    |> validate_length(:key, min: 2, max: 40)
    |> validate_format(:key, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must be lowercase kebab-case"
    )
  end
end
