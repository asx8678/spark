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

  P1-E2.2: changesets (create/update with §3.8 slug lock),
  status enum allowlist, geo lat/lng range checks.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(preselling under_construction delivered)

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

  @doc """
  Create changeset.
  """
  def create_changeset(project, attrs) do
    project
    |> cast(attrs, [
      :developer_id,
      :title,
      :slug,
      :status,
      :description,
      :address,
      :city,
      :region,
      :country,
      :lat,
      :lng,
      :delivery_date,
      :amenities,
      :seo,
      :featured
    ])
    |> validate_required([:developer_id, :title, :slug])
    |> validate_slug_format()
    |> validate_inclusion(:status, @statuses)
    |> validate_country_code()
    |> validate_lat_lng()
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:developer_id)
  end

  @doc """
  Update changeset with §3.8 slug immutability.

  See `Immo.Catalog.Developer.update_changeset/3` for the `:actor_role`
  option semantics. KV dirty-marking on slug change is P4 scope; the
  redirects row is the only side effect P1-E2.2 owns.
  """
  def update_changeset(project, attrs, opts \\ []) do
    actor_role = Keyword.get(opts, :actor_role)

    project
    |> cast(attrs, [
      :developer_id,
      :title,
      :slug,
      :status,
      :description,
      :address,
      :city,
      :region,
      :country,
      :lat,
      :lng,
      :delivery_date,
      :amenities,
      :seo,
      :featured
    ])
    |> validate_required([:developer_id, :title, :slug])
    |> validate_slug_format()
    |> validate_inclusion(:status, @statuses)
    |> validate_country_code()
    |> validate_lat_lng()
    |> maybe_lock_slug(actor_role)
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:developer_id)
  end

  defp validate_slug_format(changeset) do
    changeset
    |> validate_length(:slug, min: 2, max: 120)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must be lowercase kebab-case"
    )
  end

  defp validate_country_code(changeset) do
    changeset
    |> validate_length(:country, is: 2, message: "must be an ISO-3166 alpha-2 code")
    |> validate_format(:country, ~r/^[A-Z]{2}$/, message: "must be uppercase ISO-3166 alpha-2")
  end

  # §5.2: lat/lng nullable float. Range checks keep the (lat,lng)
  # btree index path tight.
  defp validate_lat_lng(changeset) do
    changeset
    |> validate_number(:lat, greater_than_or_equal_to: -90.0, less_than_or_equal_to: 90.0)
    |> validate_number(:lng, greater_than_or_equal_to: -180.0, less_than_or_equal_to: 180.0)
  end

  defp maybe_lock_slug(changeset, :admin), do: changeset

  defp maybe_lock_slug(changeset, _role) do
    slug_changed? = get_field(changeset, :slug) != changeset.data.slug

    if slug_changed? and not is_nil(changeset.data.published_at) do
      add_error(changeset, :slug, "is immutable after first publish (admin override required)")
    else
      changeset
    end
  end
end
