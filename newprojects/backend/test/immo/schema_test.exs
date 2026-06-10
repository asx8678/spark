defmodule Immo.SchemaTest do
  @moduledoc """
  P1-E2.1 acceptance tests for the §5.1–§5.12 migrations.

  These tests run against the live database (DataCase sandbox) and
  assert the schema-level invariants the §16 AC calls out:

    * every §5.1–§5.12 table exists
    * defaults match the spec (country MA, currency MAD, http_status
      301, featured false)
    * the uuid v7 PK shape (`uuidv7()` default) is in place
    * the citext extension is enabled
    * citext columns (slugs, email) are typed as such

  The "EXPLAIN GIN/partial used" AC for the indexes lands in P1-E2.6
  (seeds + EXPLAIN); the existence of the indexes is verified
  separately in `Immo.IndexTest`.
  """

  use Immo.DataCase, async: true

  alias Immo.Repo

  defp regclass(name) do
    %{rows: [[row]]} = Repo.query!("SELECT to_regclass($1)::text", ["public.#{name}"])
    row
  end

  defp column_default(table, column) do
    %{rows: [[row]]} =
      Repo.query!(
        "SELECT column_default::text FROM information_schema.columns WHERE table_schema='public' AND table_name=$1 AND column_name=$2",
        [table, column]
      )

    row
  end

  defp column_udt(table, column) do
    %{rows: [[row]]} =
      Repo.query!(
        "SELECT udt_name FROM information_schema.columns WHERE table_schema='public' AND table_name=$1 AND column_name=$2",
        [table, column]
      )

    row
  end

  describe "§5.1–§5.12 table existence" do
    for table <-
          ~w(property_types projects listings custom_fields media inquiries subscriptions payments builds redirects audit_log) do
      test "table #{table} exists" do
        assert regclass(unquote(table)) == unquote(table)
      end
    end
  end

  describe "§5.2 projects defaults" do
    test "country defaults to 'MA' (ISO-3166 alpha-2)" do
      assert String.contains?(column_default("projects", "country"), "'MA'")
    end

    test "status defaults to 'preselling'" do
      assert String.contains?(column_default("projects", "status"), "'preselling'")
    end

    test "featured defaults to false" do
      assert String.contains?(column_default("projects", "featured"), "false")
    end
  end

  describe "§5.4 listings defaults" do
    test "currency defaults to 'MAD'" do
      assert String.contains?(column_default("listings", "currency"), "'MAD'")
    end

    test "status defaults to 'available'" do
      assert String.contains?(column_default("listings", "status"), "'available'")
    end

    test "price_on_request defaults to false" do
      assert String.contains?(column_default("listings", "price_on_request"), "false")
    end
  end

  describe "§5.5 custom_fields defaults" do
    test "searchable defaults to false" do
      assert String.contains?(column_default("custom_fields", "searchable"), "false")
    end

    test "required defaults to false" do
      assert String.contains?(column_default("custom_fields", "required"), "false")
    end
  end

  describe "§5.6 media defaults" do
    test "position defaults to 0" do
      assert column_default("media", "position") == "0"
    end
  end

  describe "§5.7 inquiries defaults" do
    test "status defaults to 'new'" do
      assert String.contains?(column_default("inquiries", "status"), "'new'")
    end

    test "consent defaults to false" do
      assert String.contains?(column_default("inquiries", "consent"), "false")
    end
  end

  describe "§5.10 builds defaults" do
    test "status defaults to 'queued'" do
      assert String.contains?(column_default("builds", "status"), "'queued'")
    end
  end

  describe "§5.11 redirects defaults" do
    test "http_status defaults to 301" do
      assert column_default("redirects", "http_status") == "301"
    end
  end

  describe "citext extension is enabled (§5 preamble)" do
    test "citext is in pg_extension" do
      %{rows: [[extname]]} =
        Repo.query!("SELECT extname FROM pg_extension WHERE extname = 'citext'")

      assert extname == "citext"
    end
  end

  describe "citext columns (slugs + email)" do
    test "developers.slug is citext" do
      assert column_udt("developers", "slug") == "citext"
    end

    test "projects.slug is citext" do
      assert column_udt("projects", "slug") == "citext"
    end

    test "listings.slug is citext" do
      assert column_udt("listings", "slug") == "citext"
    end

    test "property_types.key is citext" do
      assert column_udt("property_types", "key") == "citext"
    end

    test "custom_fields.key is citext" do
      assert column_udt("custom_fields", "key") == "citext"
    end

    test "redirects.old_path is citext" do
      assert column_udt("redirects", "old_path") == "citext"
    end

    test "users.email is citext" do
      assert column_udt("users", "email") == "citext"
    end
  end

  describe "uuid v7 PK on every §5 table" do
    for table <-
          ~w(property_types projects listings custom_fields media inquiries subscriptions payments builds redirects audit_log) do
      test "#{table}.id default is uuidv7()" do
        assert column_default(unquote(table), "id") == "uuidv7()",
               "Expected #{unquote(table)}.id default to be 'uuidv7()', got #{inspect(column_default(unquote(table), "id"))}"
      end
    end
  end
end
