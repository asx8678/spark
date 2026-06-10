defmodule Immo.Repo.Migrations.CreateMedia do
  @moduledoc """
  P1-E2.1 §5.6 — `media` (polymorphic, attachable to Project/Listing/Developer).

  Polymorphic attachment: the (attachable_type, attachable_id) pair
  names the owner. There is no FK constraint at the column level because
  the attachment is to one of three tables; referential integrity is
  enforced in the context layer (P1-E2.2/§6.1 Immo.Media). The index
  on (attachable_type, attachable_id, position) makes the position
  reordering fast.

  The P1-E1.1 migration already created `developers` and `users` (with
  bigserial PKs); P1-E2.1's `media.id` is uuid v7 (binary_id) per
  the §5 spec.

  Order: created before `projects` and `listings` (which can carry media)
  and before `upgrade_developers` (which adds the `logo_media_id` FK →
  media).
  """

  use Ecto.Migration

  def change do
    create table(:media, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      # Polymorphic: attachable_type is one of "Project" | "Listing" | "Developer".
      # We use a string + uuid pair; the context layer enforces that the
      # attachable_id actually references a row of the named type.
      add :attachable_type, :string, null: false
      add :attachable_id, :binary_id, null: false

      add :kind, :string, null: false
      add :r2_key, :string, null: false
      add :content_type, :string
      add :byte_size, :bigint
      add :width, :integer
      add :height, :integer
      add :blurhash, :string

      # i18n: alt text is required for photos before publish (§5.6 / §6.2
      # "alt-text enforcement before publish"). The DB doesn't enforce
      # the i18n-map shape — that's the context's job — but the column
      # is jsonb and nullable so a draft upload with no alt text is
      # allowed.
      add :alt, :map

      add :position, :integer, default: 0, null: false

      timestamps(type: :timestamptz)
    end

    create index(:media, [:attachable_type, :attachable_id, :position])
    create index(:media, [:r2_key], unique: true)
  end
end
