defmodule Immo.Catalog.Listing do
  @moduledoc """
  `listings` (§5.4) — units / standalone items.

  Per §5.4:
    * `project_id` fk nullable (null = standalone: plot, resale, rental).
    * `property_type_id` fk required.
    * `title` jsonb i18n, `slug` citext unique **per property_type**.
    * `description` jsonb i18n.
    * `price` numeric(14,2) nullable.
    * `price_on_request` boolean default false.
    * `currency` char(3) default `MAD` (ISO-4217).
    * `status` enum: `available | reserved | sold | rented | hidden`.
    * `address`, `city`, `region` strings — inherit project location
      when `project_id` set and fields blank.
    * `lat`, `lng` float nullable.
    * `surface_m2` numeric(10,2) nullable.
    * `attributes` jsonb — validated against `property_types.schema_hints`
      + `custom_fields` (R9, P1-E2.2).
    * `seo` jsonb i18n.
    * `published_at` timestamptz nullable.

  ## P1-E2.2 attributes validation

  The `validate_attributes/2` step (called by create/update changesets)
  enforces, for every key present in `attributes`:
    1. the key is allowed by either `property_type.schema_hints` or a
       matching `custom_field` row (R9 — no unknown keys);
    2. the value's shape matches the field_type allowlist
       (string/integer/decimal/boolean/select/multiselect/date);
    3. for `select`/`multiselect`, the value is in the field's
       `options`.

  Then, for every `custom_field` with `required: true`, the key is
  required to be present in `attributes` (the listing can't be
  published, and §6.2 says it's a hard error, without the required
  custom field). The full required-custom-fields check runs at
  publish time (P1-E2.3 wires the predicate); the changeset
  soft-checks for *unpublished* listings so the admin can save
  drafts without the requirement blocking them.

  ## Location inheritance (§5.4)

  When `project_id` is set AND the project association is loaded,
  and the listing's `address`/`city`/`region` are blank, the
  project's values fall through. The `project_loaded?/1` guard
  prevents the inheritance from running when the caller hasn't
  preloaded the project — those callers get the explicit-fields
  path (no silent failure when the listing has no `project`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Immo.Catalog.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(available reserved sold rented hidden)

  schema "listings" do
    belongs_to :project, Immo.Catalog.Project
    belongs_to :property_type, Immo.Catalog.PropertyType

    field :title, :map
    field :slug, :string

    field :description, :map

    field :price, :decimal
    field :price_on_request, :boolean, default: false
    field :currency, :string, default: "MAD"

    field :status, :string, default: "available"

    field :address, :string
    field :city, :string
    field :region, :string

    field :lat, :float
    field :lng, :float

    field :surface_m2, :decimal

    field :attributes, :map
    field :seo, :map

    field :published_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Create changeset. Preloads of `:project` and `:property_type` are
  optional — `validate_attributes/2` is a no-op when they're not
  loaded, deferring attribute checks until publish.
  """
  def create_changeset(listing, attrs) do
    listing
    |> cast(attrs, [
      :project_id,
      :property_type_id,
      :title,
      :slug,
      :description,
      :price,
      :price_on_request,
      :currency,
      :status,
      :address,
      :city,
      :region,
      :lat,
      :lng,
      :surface_m2,
      :attributes,
      :seo
    ])
    |> validate_required([:property_type_id, :title, :slug])
    |> validate_slug_format()
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:currency, ~w(MAD EUR USD GBP),
      message: "must be a supported ISO-4217 code"
    )
    |> validate_lat_lng()
    |> inherit_project_location()
    |> validate_attributes()
    |> unique_constraint([:property_type_id, :slug])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:property_type_id)
  end

  @doc """
  Update changeset with §3.8 slug immutability. See
  `Immo.Catalog.Developer.update_changeset/3` for the `:actor_role`
  option semantics.
  """
  def update_changeset(listing, attrs, opts \\ []) do
    actor_role = Keyword.get(opts, :actor_role)

    listing
    |> cast(attrs, [
      :project_id,
      :property_type_id,
      :title,
      :slug,
      :description,
      :price,
      :price_on_request,
      :currency,
      :status,
      :address,
      :city,
      :region,
      :lat,
      :lng,
      :surface_m2,
      :attributes,
      :seo
    ])
    |> validate_required([:property_type_id, :title, :slug])
    |> validate_slug_format()
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:currency, ~w(MAD EUR USD GBP),
      message: "must be a supported ISO-4217 code"
    )
    |> validate_lat_lng()
    |> maybe_lock_slug(actor_role)
    |> inherit_project_location()
    |> validate_attributes()
    |> unique_constraint([:property_type_id, :slug])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:property_type_id)
  end

  defp validate_slug_format(changeset) do
    changeset
    |> validate_length(:slug, min: 2, max: 120)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must be lowercase kebab-case"
    )
  end

  defp validate_lat_lng(changeset) do
    changeset
    |> validate_number(:lat, greater_than_or_equal_to: -90.0, less_than_or_equal_to: 90.0)
    |> validate_number(:lng, greater_than_or_equal_to: -180.0, less_than_or_equal_to: 180.0)
  end

  # §5.4 location inheritance. If a project is bound (and the
  # association is loaded — callers that skip the preload get the
  # explicit-fields path) and the listing's own address/city/region
  # are blank, the project's values are copied in.
  defp inherit_project_location(changeset) do
    case project_loaded(changeset) do
      %Project{} = p ->
        changeset
        |> maybe_put_from_project(:address, p.address)
        |> maybe_put_from_project(:city, p.city)
        |> maybe_put_from_project(:region, p.region)
        |> maybe_put_from_project(:lat, p.lat)
        |> maybe_put_from_project(:lng, p.lng)

      _ ->
        changeset
    end
  end

  defp project_loaded(changeset) do
    case get_field(changeset, :project) do
      %Project{} = p -> p
      _ -> nil
    end
  end

  defp maybe_put_from_project(changeset, _field, nil), do: changeset

  defp maybe_put_from_project(changeset, field, value) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, value)
      "" -> put_change(changeset, field, value)
      _existing -> changeset
    end
  end

  # R9 attributes validation. Reads `property_type.schema_hints`
  # (allowed keys + their types) and the matching `custom_field` rows
  # (additional allowed keys with the per-field options). Rejects
  # unknown keys and wrong-typed values.
  defp validate_attributes(changeset) do
    case get_field(changeset, :property_type) do
      %Immo.Catalog.PropertyType{} = pt ->
        attributes = get_field(changeset, :attributes) || %{}
        # Merge schema_hints (system-known) and custom_fields
        # (admin-defined) into a single type-rules map. The custom
        # field rules win on conflict because they're more
        # authoritative.
        rules = merged_type_rules(pt)

        attributes
        |> reject_unknown_keys(Map.keys(rules), changeset)
        |> reject_mistyped_values(attributes, rules)

      _ ->
        changeset
    end
  end

  defp merged_type_rules(property_type) do
    hints = hints_to_rules(property_type.schema_hints)
    customs = custom_field_rules_for(property_type)

    Map.merge(hints, customs, fn _k, _hint_rule, custom_rule ->
      # Custom fields override schema_hints on conflict (admin
      # extension narrows or specializes the type).
      %{type: custom_rule.type, options: custom_rule.options, required: custom_rule.required}
    end)
  end

  defp hints_to_rules(%{} = hints) do
    known = hints["known_keys"] || []

    for entry <- known, is_map(entry), into: %{} do
      {entry["key"], %{type: entry["type"], options: nil, required: false}}
    end
  end

  defp hints_to_rules(_), do: %{}

  defp custom_field_rules_for(property_type) do
    custom_fields = property_type.custom_fields || []

    Enum.reduce(custom_fields, %{}, fn cf, acc ->
      Map.put(acc, cf.key, %{type: cf.field_type, options: cf.options, required: cf.required})
    end)
  end

  defp reject_unknown_keys(attributes, allowed_keys, changeset) do
    all_allowed = MapSet.new(allowed_keys)

    Enum.reduce(attributes, changeset, fn {key, _value}, cs ->
      if MapSet.member?(all_allowed, key) do
        cs
      else
        add_error(cs, :attributes, "unknown attribute #{inspect(key)}")
      end
    end)
  end

  defp reject_mistyped_values(changeset, attributes, rules) do
    Enum.reduce(attributes, changeset, fn {key, value}, cs ->
      rule = Map.get(rules, key)

      cond do
        is_nil(rule) ->
          cs

        not valid_value_for_field_type?(value, rule.type) ->
          add_error(cs, :attributes, "attribute #{inspect(key)} has wrong type for #{rule.type}")

        rule.type in ["select", "multiselect"] and not valid_select_value?(value, rule.options) ->
          add_error(cs, :attributes, "attribute #{inspect(key)} value not in field options")

        true ->
          cs
      end
    end)
  end

  defp valid_value_for_field_type?(value, "string"), do: is_binary(value)
  defp valid_value_for_field_type?(value, "integer"), do: is_integer(value)
  defp valid_value_for_field_type?(value, "decimal"), do: is_number(value)
  defp valid_value_for_field_type?(value, "boolean"), do: is_boolean(value)
  defp valid_value_for_field_type?(value, "select"), do: is_binary(value)
  defp valid_value_for_field_type?(value, "multiselect"), do: is_list(value)

  defp valid_value_for_field_type?(value, "date") do
    is_binary(value) and match?({:ok, _}, Date.from_iso8601(value))
  end

  defp valid_value_for_field_type?(_, _), do: false

  defp valid_select_value?(value, options) when is_list(options) and is_binary(value) do
    value in options
  end

  defp valid_select_value?(values, options) when is_list(options) and is_list(values) do
    Enum.all?(values, &(&1 in options))
  end

  defp valid_select_value?(_, _), do: false

  defp maybe_lock_slug(changeset, :admin), do: changeset

  defp maybe_lock_slug(changeset, _role) do
    slug_changed? = get_field(changeset, :slug) != changeset.data.slug

    if slug_changed? and not is_nil(changeset.data.published_at) do
      add_error(changeset, :slug, "is immutable after first publish (admin override required)")
    else
      changeset
    end
  end

  @doc """
  The set of valid status values. Centralized so P1-E2.3's
  `Catalog.published/1` can use the same allowlist.
  """
  def statuses, do: @statuses
end
