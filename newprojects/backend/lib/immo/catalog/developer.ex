defmodule Immo.Catalog.Developer do
  @moduledoc """
  `developers` (§5.1) — the tenant-bearing entity.

  Per §5.1:
    * `name` string, required
    * `slug` citext, unique, immutable after first publish (§3.8)
    * `description` jsonb i18n
    * `logo_media_id` uuid fk → media, nullable
    * `contact` jsonb (phone, email, website, address)
    * `seo` jsonb i18n
    * `published_at` timestamptz nullable (null = draft)

  ## P1-E2.2 — slug immutability (§3.8)

  The `update_changeset/2` rejects a slug change once the developer
  has been published at least once (`published_at != nil`) unless the
  caller passes `%{actor_role: :admin}` (the admin override from
  §3.8). On a permitted slug change, the caller is expected to have
  already computed the redirect via `Catalog.record_slug_redirect/3`
  (which inserts a `redirects` row); the changeset itself just opens
  the lock.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "developers" do
    field :name, :string
    field :slug, :string

    field :description, :map
    field :contact, :map
    field :seo, :map
    field :published_at, :utc_datetime
    belongs_to :logo_media, Immo.Catalog.Media

    timestamps(type: :utc_datetime)
  end

  @doc """
  Initial-create changeset. Slug is required, must match the slug
  format, and is the only slug we ever write for this record; later
  changes go through `update_changeset/3` (which enforces the §3.8
  immutability rule).
  """
  def create_changeset(developer, attrs) do
    developer
    |> cast(attrs, [:name, :slug, :description, :contact, :seo, :logo_media_id])
    |> validate_required([:name, :slug])
    |> validate_slug_format()
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:logo_media_id)
  end

  @doc """
  Update changeset with the §3.8 slug immutability guard.

  ## Options

    * `:actor_role` — the role of the caller. When `:admin`, the slug
      is editable even after the developer has been published. For
      every other role, the slug is locked once `published_at` is set.

  Passing `actor_role: :admin` does NOT mint the redirects row — the
  caller does that via `Catalog.record_slug_redirect/3` (transactional
  with the update) so the §3.8 "old URL never dies" guarantee holds.
  """
  def update_changeset(developer, attrs, opts \\ []) do
    actor_role = Keyword.get(opts, :actor_role)

    developer
    |> cast(attrs, [:name, :slug, :description, :contact, :seo, :logo_media_id])
    |> validate_required([:name, :slug])
    |> validate_slug_format()
    |> maybe_lock_slug(actor_role)
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:logo_media_id)
  end

  defp validate_slug_format(changeset) do
    changeset
    |> validate_length(:slug, min: 2, max: 120)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must be lowercase kebab-case (a-z, 0-9, single dashes)"
    )
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
