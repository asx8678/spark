defmodule Immo.Repo.Migrations.CreateAuditLog do
  @moduledoc """
  P1-E2.1 §5.12 — `audit_log` (compliance + debugging "why did this
  page change").

  Per §5.12: every admin mutation writes a row. The thin context
  wrapper lives in P1-E2.4; this migration is the schema. The
  `entity_type`/`entity_id` pair names the affected record (same
  shape as `media`'s polymorphic attachment, but no FK at the DB
  level because entities span many tables).

  `diff` jsonb holds the before/after snapshot — the context decides
  the shape (typically `%{"before" => ..., "after" => ...}` with
  only the changed fields).

  `at` is the wall-clock timestamp of the write. We use `inserted_at`
  as the canonical field name; `at` is aliased on the schema in
  P1-E2.4 if a different name is desired at the read site.

  Indexes: `(user_id, inserted_at desc)` for the audit viewer
  (admin-only surface per §6.2), and `(entity_type, entity_id)`
  for the "show me all writes that touched this listing" debug view.
  """

  use Ecto.Migration

  def change do
    create table(:audit_log, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :user_id, references(:users, on_delete: :nilify_all)
      add :action, :string, null: false

      add :entity_type, :string, null: false
      add :entity_id, :binary_id, null: false

      add :diff, :map

      timestamps(type: :timestamptz, updated_at: false)
    end

    # Audit viewer: most recent writes for a user.
    create index(:audit_log, [:user_id, desc: :inserted_at])

    # "What touched this record" debug lookup.
    create index(:audit_log, [:entity_type, :entity_id, desc: :inserted_at])
  end
end
