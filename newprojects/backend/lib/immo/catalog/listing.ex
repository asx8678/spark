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
      sold/rented stay published with badge (SEO value) unless hidden.
    * `address`, `city`, `region` strings (inherit project location
      when `project_id` set and fields blank — done at the changeset
      layer in P1-E2.2).
    * `lat`, `lng` float nullable.
    * `surface_m2` numeric(10,2) nullable (universal enough to be a
      column, supporting sorting/filtering).
    * `attributes` jsonb — type-specific bag (bedrooms, bathrooms,
      floor, zoning, buildable_ratio, lease_term, ...), validated
      against `property_types.schema_hints` + `custom_fields` per R9.
    * `seo` jsonb i18n.
    * `published_at` timestamptz nullable.

  Publish predicate: shared with `Project` via `Catalog.published/1`
  (P1-E2.3, §5.13).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

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
end
