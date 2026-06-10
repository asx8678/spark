defmodule Immo.Repo.Migrations.CreateListings do
  @moduledoc """
  P1-E2.1 §5.4 — `listings` (units / standalone items).

  Per §5.4 the slug is **citext unique per property_type**, not globally.
  The composite unique index `(property_type_id, slug)` enforces this
  at the DB level. `project_id` is nullable (null = standalone for
  plots, resales, rentals); the FK uses `on_delete: :restrict` so a
  project cannot be deleted while listings reference it.

  The big one: `attributes` jsonb. The §5.4/§5.5 spec says values live
  in this jsonb and are validated at the application layer against
  `property_types.schema_hints` + `custom_fields` (R9 — no EAV tables).
  The GIN index uses `jsonb_path_ops` (per §5.4) — the smaller, faster
  operator class that supports only the `@@` operator, which is exactly
  what the search island (§6.4) uses.

  The partial index `WHERE published_at IS NOT NULL` is per §5.4 and
  is the index that powers `Catalog.published/1` (§5.13). The
  `(property_type_id, status, published_at)` composite covers the
  list/index queries.
  """

  use Ecto.Migration

  def change do
    create table(:listings, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict)

      add :property_type_id, references(:property_types, type: :binary_id, on_delete: :restrict),
        null: false

      add :title, :map
      add :slug, :citext, null: false

      add :description, :map

      add :price, :decimal, precision: 14, scale: 2
      add :price_on_request, :boolean, default: false, null: false
      add :currency, :string, size: 3, default: "MAD", null: false

      add :status, :string, null: false, default: "available"

      add :address, :string
      add :city, :string
      add :region, :string

      add :lat, :float
      add :lng, :float

      add :surface_m2, :decimal, precision: 10, scale: 2

      add :attributes, :map

      add :seo, :map

      add :published_at, :timestamptz

      timestamps(type: :timestamptz)
    end

    # §5.4: slug unique per property_type (not globally)
    create unique_index(:listings, [:property_type_id, :slug])

    # §5.4: GIN on attributes with jsonb_path_ops (smaller, supports @@ only)
    execute(
      "CREATE INDEX listings_attributes_gin ON listings USING GIN (attributes jsonb_path_ops)",
      "DROP INDEX listings_attributes_gin"
    )

    # §5.4: composite for list queries
    create index(:listings, [:property_type_id, :status, :published_at])

    # §5.4: secondary indexes
    create index(:listings, [:city])
    create index(:listings, [:price])

    # §5.4: (lat, lng) btree pair for bbox queries (D7 — no PostGIS)
    create index(:listings, [:lat, :lng])

    # §5.4: partial index for published rows — this is the index that
    # powers `Catalog.published/1` (§5.13) and the sitemap endpoint.
    create index(:listings, [:published_at],
             where: "published_at IS NOT NULL",
             name: "listings_published_partial_idx"
           )
  end
end
