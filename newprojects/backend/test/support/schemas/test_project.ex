defmodule Immo.TestSchemas.TestProject do
  @moduledoc """
  Test fixture schema for `Immo.Catalog.scoped_query/2` and
  `Scope.assert_owns_entity/2` tests.

  A real `Immo.Catalog.Project` schema lands in P1-E2.1; this stub
  exists now so the §5.8 tenant-scoping contract has a concrete
  surface to test against without waiting for P1-E2. When P1-E2
  lands, the production schema can be substituted and the test
  signature stays the same.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "test_projects" do
    field :title, :string
    field :slug, :string
    # The §5.8 tenant-binding column. The scoped_query filter compares
    # against this field; the assert_owns_entity check matches it
    # against scope.tenant_id.
    field :developer_id, :binary_id

    timestamps(type: :utc_datetime)
  end
end
