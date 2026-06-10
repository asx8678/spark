defmodule Immo.Catalog.CustomField do
  @moduledoc """
  `custom_fields` (§5.5) — admin-defined, per property type (R9).

  Per §5.5:
    * `property_type_id` fk.
    * `key` citext unique per type.
    * `label` jsonb i18n.
    * `field_type` enum: `string | integer | decimal | boolean |
      select | multiselect | date`. Stored as a string; the changeset
      in P1-E2.2 validates against the allowlist.
    * `options` jsonb (for `select` / `multiselect`).
    * `searchable` boolean — adds a facet to `filter_config` at read
      time (the merge logic lives in P1-E2.2).
    * `required` boolean.
    * `position` integer.

  Values live inside `listings.attributes` under the field key — no
  EAV tables. R9.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "custom_fields" do
    belongs_to :property_type, Immo.Catalog.PropertyType

    field :key, :string
    field :label, :map
    field :field_type, :string
    field :options, :map
    field :searchable, :boolean, default: false
    field :required, :boolean, default: false
    field :position, :integer

    timestamps(type: :utc_datetime)
  end
end
