defmodule Immo.AuditLog do
  @moduledoc """
  `audit_log` (§5.12) — every admin mutation writes a row.

  Per §5.12:
    * `user_id` fk → users (nullable: a system-triggered mutation has
      no human actor).
    * `action` — short verb (`publish`, `unpublish`, `update`,
      `create`, `delete`, ...).
    * `entity_type`, `entity_id` — polymorphic (same shape as `media`'s
      attachment); no FK at the DB level.
    * `diff` jsonb — `%{"before" => ..., "after" => ...}` with only
      the changed fields. The shape is decided by the
      `Immo.AuditLog` context (P1-E2.4) that wraps every admin
      mutation; the schema just holds the bytes.

  Indexes: `(user_id, inserted_at desc)` for the audit viewer
  (admin-only surface per §6.2); `(entity_type, entity_id, inserted_at
  desc)` for the "show me all writes that touched this record" debug
  view.

  The `at` field is `inserted_at` — we don't add a separate column.
  The audit viewer reads it as `at` via the schema's
  `field :at, :inserted_at` alias (in P1-E2.4). The migration
  creates only `inserted_at` (no `updated_at`); audit rows are
  immutable.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_log" do
    belongs_to :user, Immo.Accounts.User

    field :action, :string
    field :entity_type, :string
    field :entity_id, :binary_id
    field :diff, :map

    # `updated_at: false` on the migration side; we still get
    # `inserted_at` from Ecto's timestamps.
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
