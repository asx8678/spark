defmodule Immo.Catalog.Developer do
  @moduledoc """
  Stub developer entity. P1-E2.1 will land the full §5.1 schema
  (description jsonb, contact jsonb, seo jsonb, logo_media_id,
  published_at, indexes). The `belongs_to :developer` on
  `Immo.Accounts.User` and the FK column `users.developer_id` need this
  module to exist as a compile target; that is the only reason for the
  presence of the stub today. Touch only what the FK requires: id, name,
  slug, timestamps.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "developers" do
    field :name, :string
    field :slug, :string

    timestamps(type: :utc_datetime)
  end
end
