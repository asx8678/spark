defmodule Immo.Catalog.Project do
  @moduledoc """
  `projects` (§5.2) — new developments, headline entity.

  Per §5.2:
    * `developer_id` fk required (every project belongs to a developer).
    * `title` jsonb i18n, `slug` citext unique, immutable after first
      publish (§3.8).
    * `status` enum: `preselling | under_construction | delivered`.
    * `description` jsonb i18n.
    * `address`, `city`, `region`, `country` (ISO-3166 alpha-2, default
      `MA`).
    * `lat`, `lng` float nullable (filled by Geocode job, admin
      map-pin override).
    * `delivery_date` date nullable.
    * `amenities` jsonb — array of keys, rendered via i18n dictionary.
    * `seo` jsonb i18n.
    * `featured` boolean default false (drives home-page ordering).
    * `published_at` timestamptz nullable (publishing gated by the
      owning developer's active subscription — §5.13).

  Publishing is the §5.13 single-publish-predicate concern; the
  predicate is shared with `Listing` and is implemented as
  `Catalog.published/1` in P1-E2.3. P1-E2.2 lands the changesets
  and the slug-immutability guard.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    belongs_to :developer, Immo.Catalog.Developer

    field :title, :map
    field :slug, :string

    field :status, :string, default: "preselling"

    field :description, :map
    field :address, :string
    field :city, :string
    field :region, :string
    field :country, :string, default: "MA"
    field :lat, :float
    field :lng, :float
    field :delivery_date, :date
    field :amenities, :map
    field :seo, :map
    field :featured, :boolean, default: false
    field :published_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
