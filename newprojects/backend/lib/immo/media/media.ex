defmodule Immo.Media.Media do
  @moduledoc """
  `media` (§5.6) — polymorphic attachment to Project / Listing / Developer.

  Per §6.1, this schema lives under the `Immo.Media` context (P1-E2.5
  fences the boundary up front; P1-E4 fleshes out the upload +
  derivative-pipeline behavior). The module moved from
  `Immo.Catalog.Media` to `Immo.Media.Media` in P1-E2.5 so the
  Catalog doesn't own media (§5.6 is "media records, presigned R2
  uploads, derivative jobs" — a Media concern, not a Catalog
  concern). The `belongs_to` references from `developers.logo_media`
  and from `Immo.Catalog.Project`/`Immo.Catalog.Listing` polymorphic
  attachments update to this module name.

  Per §5.6:
    * `attachable_type` + `attachable_id` — polymorphic. The DB
      carries a string + uuid pair; referential integrity to the
      named table is enforced at the context layer (§6.1
      `Immo.Media`). The composite index on
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
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @attachable_types ~w(Project Listing Developer)
  @kinds ~w(photo floorplan brochure document logo)

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

  @doc """
  The set of valid `kind` values. Stored as a string; the changeset
  allowlist below is the runtime check.
  """
  def kinds, do: @kinds

  @doc """
  Base create changeset for new media records. The P1-E4 upload
  pipeline calls this; P1-E2.5 ships the field-level invariants
  (FK-shape validation, enum allowlist, position default) so a
  future caller can't write malformed data even before P1-E4 lands.
  """
  def create_changeset(media, attrs) do
    media
    |> cast(attrs, [
      :attachable_type,
      :attachable_id,
      :kind,
      :r2_key,
      :content_type,
      :byte_size,
      :width,
      :height,
      :blurhash,
      :alt,
      :position
    ])
    |> validate_required([:attachable_type, :attachable_id, :kind, :r2_key])
    |> validate_inclusion(:attachable_type, @attachable_types)
    |> validate_inclusion(:kind, @kinds)
    |> validate_r2_key_shape()
    |> unique_constraint(:r2_key)
  end

  # The §5.6 r2_key is `media/{attachable_type}/{attachable_id}/{sha256}.{ext}`.
  # We don't pin the full prefix (it changes as the storage layout
  # evolves) but we do enforce a sane shape: non-empty, slash-
  # separated path components, and a recognised file extension.
  defp validate_r2_key_shape(changeset) do
    r2_key = get_field(changeset, :r2_key)

    if is_binary(r2_key) and String.contains?(r2_key, "/") and
         Regex.match?(~r/\.[a-z0-9]+$/, r2_key) do
      changeset
    else
      add_error(changeset, :r2_key, "must be a path like 'media/.../sha.ext'")
    end
  end
end
