defmodule Immo.AuditLog do
  @moduledoc """
  `audit_log` (§5.12) — every admin mutation writes a row.

  Per §5.12:
    * `user_id` — references `users.id` (nullable: a system-triggered
      mutation has no human actor). The `users.id` column type
      is `bigserial` from P1-E1.1; the audit_log `user_id` matches
      so the foreign key fits without a backfill. A future
      migration (when the rest of the system goes to uuid v7) will
      switch both columns in lockstep.
    * `action` — short verb (`publish`, `unpublish`, `update`,
      `create`, `delete`, ...).
    * `entity_type`, `entity_id` — polymorphic (same shape as `media`'s
      attachment); no FK at the DB level.
    * `diff` jsonb — `%{"before" => ..., "after" => ...}` with only
      the changed fields. The shape is decided by the
      `Immo.Audit` context that wraps every admin mutation; the
      schema just holds the bytes.

  Indexes: `(user_id, inserted_at desc)` for the audit viewer
  (admin-only surface per §6.2); `(entity_type, entity_id, inserted_at
  desc)` for the "show me all writes that touched this record" debug
  view.

  The `at` field is `inserted_at` — we don't add a separate column.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_log" do
    # `users.id` is bigserial in P1-E1.1 — the audit_log row stores
    # the integer id verbatim. The foreign key relationship is
    # not enforced at the schema layer (`belongs_to`) because
    # Ecto's `belongs_to` with `:integer` vs `:binary_id` would
    # diverge; instead we rely on the existing application-level
    # invariants (P1-E2.4 / §13) and a future migration to align
    # both columns. P1-E2.4 / §5.12: the audit row is the
    # compliance record; integrity of the user reference is
    # enforced by the staff-user lifecycle (a user_id in an audit
    # row is a snapshot of who did it at the time).
    field :user_id, :integer

    field :action, :string
    field :entity_type, :string
    field :entity_id, :binary_id
    field :diff, :map

    # `updated_at: false` on the migration side; we still get
    # `inserted_at` from Ecto's timestamps.
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
