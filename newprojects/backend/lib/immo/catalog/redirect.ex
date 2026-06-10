defmodule Immo.Catalog.Redirect do
  @moduledoc """
  `redirects` (§5.11) — slug-change tracking, §3.8.

  Per §5.11:
    * `old_path` citext unique — the path before the slug change.
    * `new_path` — the new path.
    * `http_status` int default 301 (permanent redirect).
    * `reason` — free-form note for the admin.

  The Worker entry (the frontend) consults a build-time-generated
  `redirects.json` (built from this table by the build pipeline)
  before serving any URL, so slug changes propagate to the edge
  with zero origin traffic.

  When the admin (P1-E3) edits a slug, the slug-immutability guard
  in P1-E2.2 will:
    1. refuse the edit if the entity is published and the caller is
       not an admin (per §3.8 default + admin override)
    2. if the edit proceeds, write a `Redirect` here via
       `Immo.Catalog.record_slug_redirect/4` transactionally.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "redirects" do
    field :old_path, :string
    field :new_path, :string
    field :http_status, :integer, default: 301
    field :reason, :string

    timestamps(type: :utc_datetime)
  end

  def create_changeset(redirect, attrs) do
    redirect
    |> cast(attrs, [:old_path, :new_path, :http_status, :reason])
    |> validate_required([:old_path, :new_path])
    |> validate_inclusion(:http_status, [301, 302, 307, 308])
    |> unique_constraint(:old_path)
  end
end
