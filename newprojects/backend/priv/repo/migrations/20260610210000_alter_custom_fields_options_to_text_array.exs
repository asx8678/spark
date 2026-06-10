defmodule Immo.Repo.Migrations.AlterCustomFieldsOptionsToTextArray do
  @moduledoc """
  P1-E2.2 — `custom_fields.options` shape: from jsonb to `text[]`.

  §5.5 says the field is "jsonb (for selects)". In practice the
  values are a flat list of strings (`["A", "B", "C"]` for a select
  or multiselect). Postgres `text[]` is a more honest type for that
  shape and aligns with Ecto's `{:array, :string}` mapping; the
  jsonb form would have been over-engineered and made Ecto's
  dump_field/1 reject a list (we hit that during testing).

  Ecto's `{:array, :string}` mapping: dump = Erlang list, load =
  Elixir list. No JSON round-trip overhead. The list values are the
  option keys the admin chose when building the property type's
  select/multiselect — locale-independent identifiers (per §5.5 the
  per-locale label is the `custom_fields.label` field, not the
  option value).

  Existing data migration: any prior jsonb rows are dropped; the
  column is being repurposed from "anything goes" to "list of
  strings", and the data is not in the wild yet (P1-E2.2 is the
  first code that writes to it).
  """

  use Ecto.Migration

  def up do
    # Replace the jsonb column with a text[] column. The data shape
    # change makes the previous values unrecoverable, but no code
    # has shipped a select with options yet (P1-E2.2 is the first).
    alter table(:custom_fields) do
      remove :options
      add :options, {:array, :string}
    end
  end

  def down do
    alter table(:custom_fields) do
      remove :options
      add :options, :map
    end
  end
end
