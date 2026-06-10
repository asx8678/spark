defmodule Immo.Repo.Migrations.CreateInquiries do
  @moduledoc """
  P1-E2.1 §5.7 — `inquiries` (leads).

  At least one of `listing_id` / `project_id` is expected (an inquiry
  has to be about *something*); the DB does not enforce that one is
  non-null because a future "general contact" inquiry might target
  neither. The application layer (P1-E6) is the right place for that
  validation.

  `status` is a string with values `new | contacted | closed` per
  §5.7 — stored as a string column with no DB-level CHECK; the
  changeset enforces the allowlist.

  Retention: a retention job (Oban, §5.7) purges closed inquiries
  after `INQUIRY_RETENTION_DAYS` (default 365). The column to
  filter on is `updated_at` (when the inquiry moved to `closed`),
  so the index on `(status, updated_at)` is what the retention
  query will hit.
  """

  use Ecto.Migration

  def change do
    create table(:inquiries, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("uuidv7()")

      add :listing_id, references(:listings, type: :binary_id, on_delete: :nilify_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :handled_by_user_id, references(:users, on_delete: :nilify_all)

      add :name, :string, null: false
      add :email, :citext, null: false
      add :phone, :string
      add :message, :text, null: false
      add :locale, :string, size: 5
      add :consent, :boolean, null: false, default: false
      add :source, :string

      add :status, :string, null: false, default: "new"

      timestamps(type: :timestamptz)
    end

    # Retention job hits this; the inquiry inbox filter hits (status)
    # and (handled_by_user_id).
    create index(:inquiries, [:status, desc: :updated_at])
    create index(:inquiries, [:listing_id])
    create index(:inquiries, [:project_id])
    create index(:inquiries, [:handled_by_user_id])
    create index(:inquiries, [:email])
  end
end
