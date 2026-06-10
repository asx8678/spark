defmodule Immo.Catalog.CustomField do
  @moduledoc """
  `custom_fields` (§5.5) — admin-defined, per property type (R9).

  Per §5.5:
    * `property_type_id` fk.
    * `key` citext unique per type.
    * `label` jsonb i18n.
    * `field_type` enum: `string | integer | decimal | boolean |
      select | multiselect | date`.
    * `options` jsonb (for `select` / `multiselect`).
    * `searchable` boolean — adds a facet to `filter_config` at read
      time.
    * `required` boolean.
    * `position` integer.

  Values live inside `listings.attributes` under the field key — no
  EAV tables. R9. The `Immo.Catalog.Listing` changeset consumes the
  `field_type`/`options`/`required` triple to validate every key
  written into `attributes`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @field_types ~w(string integer decimal boolean select multiselect date)

  schema "custom_fields" do
    belongs_to :property_type, Immo.Catalog.PropertyType

    field :key, :string
    field :label, :map
    field :field_type, :string
    field :options, {:array, :string}
    field :searchable, :boolean, default: false
    field :required, :boolean, default: false
    field :position, :integer

    timestamps(type: :utc_datetime)
  end

  def create_changeset(custom_field, attrs) do
    custom_field
    |> cast(attrs, [
      :property_type_id,
      :key,
      :label,
      :field_type,
      :searchable,
      :required,
      :position
    ])
    |> put_options(attrs)
    |> validate_required([:property_type_id, :key, :label, :field_type, :position])
    |> validate_inclusion(:field_type, @field_types)
    |> validate_key_format()
    |> validate_options_shape()
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:property_type_id, :key])
    |> foreign_key_constraint(:property_type_id)
  end

  def update_changeset(custom_field, attrs) do
    custom_field
    |> cast(attrs, [
      :property_type_id,
      :key,
      :label,
      :field_type,
      :searchable,
      :required,
      :position
    ])
    |> put_options(attrs)
    |> validate_required([:property_type_id, :key, :label, :field_type, :position])
    |> validate_inclusion(:field_type, @field_types)
    |> validate_key_format()
    |> validate_options_shape()
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:property_type_id, :key])
    |> foreign_key_constraint(:property_type_id)
  end

  # `:options` is a jsonb column for `select`/`multiselect` field types
  # that holds a list of strings. The standard `:map` cast refuses a
  # list, so we accept both `options: [...]` and `options: %{...}`
  # via `put_change`. Validation in `validate_options_shape/1` then
  # checks the type based on `field_type`.
  defp put_options(changeset, attrs) do
    case attrs[:options] || attrs["options"] do
      nil ->
        changeset

      options when is_list(options) or is_map(options) ->
        put_change(changeset, :options, options)
    end
  end

  defp validate_key_format(changeset) do
    changeset
    |> validate_length(:key, min: 2, max: 40)
    |> validate_format(:key, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must be lowercase kebab-case"
    )
  end

  # `options` is required for `select` / `multiselect` (the shape is
  # enforced at the changeset level — the field is not a "soft" JSON
  # column). For other field_types, options must be nil.
  defp validate_options_shape(changeset) do
    field_type = get_field(changeset, :field_type)
    options = get_field(changeset, :options)

    cond do
      field_type in ["select", "multiselect"] and not is_list(options) ->
        add_error(changeset, :options, "must be a list of values for select/multiselect")

      field_type in ["select", "multiselect"] and options == [] ->
        add_error(changeset, :options, "must contain at least one value for select/multiselect")

      field_type not in ["select", "multiselect"] and not is_nil(options) ->
        add_error(changeset, :options, "must be nil for non-select field types")

      true ->
        changeset
    end
  end
end
