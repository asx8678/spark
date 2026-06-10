defmodule Immo.Repo.Migrations.CreateTestProjects do
  use Ecto.Migration

  # Test-only schema for the §5.8 tenant-scoping test suite. P1-E1.2
  # exercises `Immo.Catalog.scoped_query/2` against a real table that
  # has a `developer_id` column; P1-E2.1 will replace this with the
  # production `projects` table. The table lives in all environments
  # (dev/test/prod) but is only ever inserted from the P1-E1.2 test
  # file; the application code never touches it.
  def change do
    create table(:test_projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string
      add :slug, :string
      add :developer_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create index(:test_projects, [:developer_id])
  end
end
