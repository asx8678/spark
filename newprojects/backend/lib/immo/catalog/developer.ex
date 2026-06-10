defmodule Immo.Catalog.Developer do
  @moduledoc """
  `developers` (§5.1) — the tenant-bearing entity. P1-E2.1.

  Per §5.1:
    * `name` string, required
    * `slug` citext, unique, immutable after first publish (§3.8)
    * `description` jsonb i18n
    * `logo_media_id` uuid fk → media, nullable
    * `contact` jsonb (phone, email, website, address)
    * `seo` jsonb i18n
    * `published_at` timestamptz nullable (null = draft)

  P1-E1.1 shipped a minimal stub (id, name, slug, timestamps). P1-E2.1
  added the remaining columns via the `UpgradeDevelopers` migration
  and the `AddDevelopersLogoMediaIdFk` migration (after `media` was
  in place).

  The P1-E1.1 `belongs_to :developer` on `Immo.Accounts.User` and the
  `users.developer_id` FK point here, so the table already exists.
  P1-E2.2 will land the changeset logic, slug-immutability guard,
  and the publish transition (sets `published_at`).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "developers" do
    field :name, :string
    field :slug, :string

    # §5.1 (P1-E2.1): full jsonb/i18n/media/timestamp fields
    field :description, :map
    field :contact, :map
    field :seo, :map
    field :published_at, :utc_datetime
    belongs_to :logo_media, Immo.Catalog.Media

    timestamps(type: :utc_datetime)
  end
end
