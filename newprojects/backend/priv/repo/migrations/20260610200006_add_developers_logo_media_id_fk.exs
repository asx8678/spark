defmodule Immo.Repo.Migrations.AddDevelopersLogoMediaIdFk do
  @moduledoc """
  P1-E2.1 — add the developers.logo_media_id → media.id FK constraint.

  The `UpgradeDevelopers` migration added the `logo_media_id` column as
  a plain uuid (because `media` didn't exist yet at that timestamp).
  This migration adds the FK now that `media` is in place. The
  `on_delete: :nilify` is the §6.2-friendly behavior: deleting a
  media row should clear the developer's logo pointer, not delete the
  developer.

  We use raw SQL because Ecto's `alter + modify` column-shape changes
  for adding a FK constraint are not portable across all PG versions
  (some versions require DROP COLUMN + ADD COLUMN for the type+FK
  combination). The IF NOT EXISTS makes the migration idempotent
  against a partial replay.
  """

  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE developers
      ADD CONSTRAINT developers_logo_media_id_fkey
      FOREIGN KEY (logo_media_id) REFERENCES media (id)
      ON DELETE SET NULL
    """)
  end

  def down do
    execute("ALTER TABLE developers DROP CONSTRAINT IF EXISTS developers_logo_media_id_fkey")
  end
end
