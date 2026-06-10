defmodule Immo.Repo.Migrations.UpgradeDevelopers do
  @moduledoc """
  P1-E2.1 §5.1 — upgrade the P1-E1.1 `developers` stub to the full §5.1 schema.

  The P1-E1.1 migration created `developers(id uuid, name, slug, timestamps)`
  as a minimal stub. This migration adds the §5.1 columns:

    * `description` jsonb i18n
    * `logo_media_id` uuid (FK → media is added by the
      `AddDevelopersLogoMediaIdFk` migration that runs after
      `media` is in place)
    * `contact` jsonb (phone, email, website, address)
    * `seo` jsonb i18n (title, meta_description, og fields)
    * `published_at` timestamptz nullable (null = draft)

  The existing `slug` is already citext unique per P1-E1.1; no change
  needed for the §3.8 immutability rule (enforced at the changeset
  level in P1-E2.2).
  """

  use Ecto.Migration

  def change do
    alter table(:developers) do
      add :description, :map
      add :logo_media_id, :binary_id
      add :contact, :map
      add :seo, :map
      add :published_at, :timestamptz
    end
  end
end
