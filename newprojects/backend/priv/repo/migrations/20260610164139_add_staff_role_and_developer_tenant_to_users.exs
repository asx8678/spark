defmodule Immo.Repo.Migrations.AddStaffRoleAndDeveloperTenantToUsers do
  use Ecto.Migration

  # P1-E2.1 will extend the developers table with the full §5.1 schema
  # (description jsonb, contact jsonb, seo jsonb, logo_media_id, published_at, …).
  # For P1-E1 we only need the FK target to exist, so admin/seed paths can resolve it.
  @disable_ddl_transaction true

  def up do
    # Create a minimal developers table; the full schema lands in P1-E2.1.
    create table(:developers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :citext, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:developers, [:slug])

    # Add role + developer_id to users.
    # `role` is the staff trust-path privilege set per §5.8 / §6.2 / A8.
    alter table(:users) do
      add :role, :string, null: false, default: "editor"
      add :developer_id, references(:developers, type: :binary_id, on_delete: :restrict)
    end

    # Invariant (§5.8): developer_id is required iff role = 'developer_user'.
    # The enum is open today; new staff roles may be added. The check is a
    # safety net even though the changeset enforces the same invariant.
    execute(
      """
      ALTER TABLE users
        ADD CONSTRAINT users_developer_id_required_iff_role_is_developer_user
        CHECK (
          (role = 'developer_user' AND developer_id IS NOT NULL)
          OR
          (role <> 'developer_user' AND developer_id IS NULL)
        )
      """,
      "ALTER TABLE users DROP CONSTRAINT users_developer_id_required_iff_role_is_developer_user"
    )

    # Tighten the role allowlist at the DB level too.
    execute(
      """
      ALTER TABLE users
        ADD CONSTRAINT users_role_allowlist
        CHECK (role IN ('admin', 'manager', 'editor', 'developer_user'))
      """,
      "ALTER TABLE users DROP CONSTRAINT users_role_allowlist"
    )
  end

  def down do
    alter table(:users) do
      remove :developer_id
      remove :role
    end

    drop table(:developers)
  end
end
