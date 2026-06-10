# Seed script.
#
# Seeds the development database with the minimum staff/tenant fixtures
# required to exercise the admin login + RBAC substrate delivered by
# P1-E1.1. P1-E2 will replace this with a realistic catalog seed
# (≥3 property types, ≥40 listings, fr/ar content, etc.).
#
# The seed is idempotent: running it twice does not duplicate rows.

alias Immo.Repo
alias Immo.Accounts
alias Immo.Catalog.Developer

# Demo developer — P1-E2.1 owns the full schema; this is a stub record
# sufficient to demonstrate tenant scoping for a `developer_user` in
# the P1-E1.3 role-matrix tests.
developer =
  case Repo.get_by(Developer, slug: "demo-developer") do
    nil ->
      %Developer{id: Ecto.UUID.generate(), name: "Demo Developer", slug: "demo-developer"}
      |> Repo.insert!()

    existing ->
      existing
  end

# Seed admin. Password is intentionally a long generated value; for
# local dev the operator is expected to override `ADMIN_EMAIL` and
# `ADMIN_PASSWORD` in `.env` before first run, then re-run seeds.
admin_email = System.get_env("ADMIN_EMAIL", "admin@immo.local")
admin_password = System.get_env("ADMIN_PASSWORD", "ChangeMe!ChangeMe!2026")

case Accounts.get_user_by_email(admin_email) do
  nil ->
    {:ok, admin} =
      Accounts.register_staff_user(%{
        email: admin_email,
        password: admin_password,
        role: :admin
      })

    IO.puts("[seed] created admin user #{admin.email} (role: #{admin.role})")

  %Accounts.User{} ->
    IO.puts("[seed] admin user #{admin_email} already present, skipping")
end

# Sample editor (for tests / local click-through).
editor_email = System.get_env("EDITOR_EMAIL", "editor@immo.local")
editor_password = System.get_env("EDITOR_PASSWORD", "ChangeMe!ChangeMe!2026")

case Accounts.get_user_by_email(editor_email) do
  nil ->
    {:ok, _editor} =
      Accounts.register_staff_user(%{
        email: editor_email,
        password: editor_password,
        role: :editor
      })

    IO.puts("[seed] created editor user #{editor_email}")

  %Accounts.User{} ->
    IO.puts("[seed] editor user #{editor_email} already present, skipping")
end

# Sample developer_user (tenant-scoped). Bound to `developer` above so
# role-matrix tests can exercise cross-tenant denial.
dev_user_email = System.get_env("DEVELOPER_USER_EMAIL", "dev-user@immo.local")
dev_user_password = System.get_env("DEVELOPER_USER_PASSWORD", "ChangeMe!ChangeMe!2026")

case Accounts.get_user_by_email(dev_user_email) do
  nil ->
    {:ok, _dev_user} =
      Accounts.register_staff_user(%{
        email: dev_user_email,
        password: dev_user_password,
        role: :developer_user,
        developer_id: developer.id
      })

    IO.puts("[seed] created developer_user #{dev_user_email} (bound to #{developer.slug})")

  %Accounts.User{} ->
    IO.puts("[seed] developer_user #{dev_user_email} already present, skipping")
end
