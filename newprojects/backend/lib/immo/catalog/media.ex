defmodule Immo.Catalog.Media do
  @moduledoc """
  `media` (§5.6) — polymorphic attachment to Project / Listing / Developer.

  Per §5.6:
    * `attachable_type` + `attachable_id` — polymorphic. The DB
      carries a string + uuid pair; referential integrity to the
      named table is enforced at the context layer (P1-E2.2 / §6.1
      Immo.Media). The composite index on
      `(attachable_type, attachable_id, position)` is what the
      reordering query hits.
    * `kind` enum: `photo | floorplan | brochure | document | logo`.
    * `r2_key` — `media/{attachable_type}/{attachable_id}/{content_sha256}.{ext}`.
      Unique so a re-upload of the same blob short-circuits the
      derivative pipeline.
    * `content_type`, `byte_size`, `width`, `height` — metadata.
    * `blurhash` — LQIP, computed by Oban (§8).
    * `alt` jsonb i18n — required for photos before publish (§6.2
      alt-text gate).
    * `position` integer.

  Direct-to-R2 upload pipeline (presign endpoint, Oban derivatives)
  is P1-E4. The shape of this schema is the contract P1-E4 builds
  against.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @attachable_types ~w(Project Listing Developer)

  schema "media" do
    field :attachable_type, :string
    field :attachable_id, :binary_id

    field :kind, :string
    field :r2_key, :string
    field :content_type, :string
    field :byte_size, :integer
    field :width, :integer
    field :height, :integer
    field :blurhash, :string

    field :alt, :map

    field :position, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc """
  The set of valid `attachable_type` values. Centralized so the
  P1-E2.2 changeset can validate against it.
  """
  def attachable_types, do: @attachable_types
end
