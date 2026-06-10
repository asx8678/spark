defmodule Immo.TestSchemas.NoTenant do
  @moduledoc """
  Test fixture schema that intentionally has no `developer_id` field.

  Used by `Immo.Catalog.ScopedQueryTest` to exercise the fail-closed
  guard: `Immo.Catalog.scoped_query/2` raises `ArgumentError` when
  called on a schema missing the `developer_id` field. The schema is
  registered as an Ecto source (`"no_tenant"`) only via the Ecto
  introspection call (`__schema__/1`); it does not need a migration
  because the test never inserts a row.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "no_tenant" do
    field :name, :string
  end
end
