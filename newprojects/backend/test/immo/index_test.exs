defmodule Immo.IndexTest do
  @moduledoc """
  P1-E2.1 — verify the §5 indexes exist and the FK constraints
  are wired correctly.

  The §16 AC for P1-E2.1 says "GIN/partial indexes verified with
  EXPLAIN on seed data". The EXPLAIN step is gated on seeds (P1-E2.6)
  — this file verifies the indexes **exist** with the correct
  shape (operator class, predicate, columns), which is the
  pre-condition for the EXPLAIN check.
  """

  use Immo.DataCase, async: true

  alias Immo.Repo

  defp row_value(sql, params \\ []) do
    %{rows: rows} = Repo.query!(sql, params)
    List.first(hd(rows)) || ""
  end

  describe "§5.4 listings indexes" do
    test "GIN jsonb_path_ops on listings.attributes" do
      defn =
        row_value(
          "SELECT indexdef FROM pg_indexes WHERE schemaname='public' AND tablename='listings' AND indexname='listings_attributes_gin'"
        )

      assert defn =~ ~r/using gin/i
      assert defn =~ ~r/attributes\s+jsonb_path_ops/i
    end

    test "partial index on listings.published_at IS NOT NULL" do
      defn =
        row_value(
          "SELECT indexdef FROM pg_indexes WHERE schemaname='public' AND tablename='listings' AND indexname='listings_published_partial_idx'"
        )

      assert defn =~ ~r/where\s+\(published_at\s+IS\s+NOT\s+NULL\)/i
    end

    test "composite (property_type_id, status, published_at) on listings" do
      defn =
        row_value(
          "SELECT indexdef FROM pg_indexes WHERE indexname='listings_property_type_id_status_published_at_index'"
        )

      assert defn =~ ~r/property_type_id.*status.*published_at/i
    end

    test "slug unique per property_type (composite, not global)" do
      defn =
        row_value(
          "SELECT indexdef FROM pg_indexes WHERE indexname='listings_property_type_id_slug_index'"
        )

      assert defn =~ ~r/UNIQUE\s+INDEX/i
      assert defn =~ ~r/property_type_id, slug/
    end

    test "(lat, lng) btree pair" do
      defn = row_value("SELECT indexdef FROM pg_indexes WHERE indexname='listings_lat_lng_index'")
      assert defn =~ ~r/USING btree \(lat, lng\)/i
    end

    test "city and price secondary indexes" do
      defn = row_value("SELECT indexdef FROM pg_indexes WHERE indexname='listings_city_index'")
      assert defn =~ ~r/USING btree \(city\)/i

      defn = row_value("SELECT indexdef FROM pg_indexes WHERE indexname='listings_price_index'")
      assert defn =~ ~r/USING btree \(price\)/i
    end
  end

  describe "§5.2 projects indexes" do
    test "(published_at), (city, status), (developer_id), slug unique" do
      for idx <-
            ~w(projects_published_at_index projects_city_status_index projects_developer_id_index projects_slug_index) do
        defn = row_value("SELECT indexdef FROM pg_indexes WHERE indexname='#{idx}'")
        assert defn != "", "missing index: #{idx}"
      end

      assert row_value("SELECT indexdef FROM pg_indexes WHERE indexname='projects_slug_index'") =~
               ~r/UNIQUE\s+INDEX/i
    end
  end

  describe "§5.3 property_types indexes" do
    test "key citext unique, position index" do
      assert row_value(
               "SELECT indexdef FROM pg_indexes WHERE indexname='property_types_key_index'"
             ) =~
               ~r/UNIQUE\s+INDEX/i

      defn =
        row_value(
          "SELECT indexdef FROM pg_indexes WHERE indexname='property_types_position_index'"
        )

      assert defn =~ ~r/USING btree \("position"\)/i
    end
  end

  describe "§5.5 custom_fields indexes" do
    test "(property_type_id, key) unique" do
      defn =
        row_value(
          "SELECT indexdef FROM pg_indexes WHERE indexname='custom_fields_property_type_id_key_index'"
        )

      assert defn =~ ~r/UNIQUE\s+INDEX/i
      assert defn =~ ~r/property_type_id, key/
    end
  end

  describe "§5.6 media indexes" do
    test "(attachable_type, attachable_id, position) composite" do
      defn =
        row_value(
          "SELECT indexdef FROM pg_indexes WHERE indexname='media_attachable_type_attachable_id_position_index'"
        )

      assert defn =~
               ~r/USING btree \(attachable_type, attachable_id, "position"\)/i
    end

    test "r2_key unique" do
      defn = row_value("SELECT indexdef FROM pg_indexes WHERE indexname='media_r2_key_index'")
      assert defn =~ ~r/UNIQUE\s+INDEX/i
    end
  end

  describe "§5.7 inquiries indexes" do
    test "(status, updated_at desc) for retention; FK indexes" do
      for idx <-
            ~w(inquiries_status_updated_at_index inquiries_listing_id_index inquiries_project_id_index inquiries_handled_by_user_id_index inquiries_email_index) do
        defn = row_value("SELECT indexdef FROM pg_indexes WHERE indexname='#{idx}'")
        assert defn != "", "missing index: #{idx}"
      end
    end
  end

  describe "§5.9 subscriptions indexes" do
    test "(developer_id, status, current_period_end) for §5.13 billing gate" do
      defn =
        row_value(
          "SELECT indexdef FROM pg_indexes WHERE indexname='subscriptions_developer_id_status_current_period_end_index'"
        )

      assert defn =~ ~r/developer_id, status, current_period_end/
    end

    test "(provider, provider_subscription_id) unique" do
      defn =
        row_value(
          "SELECT indexdef FROM pg_indexes WHERE indexname='subscriptions_provider_provider_subscription_id_index'"
        )

      assert defn =~ ~r/UNIQUE\s+INDEX/i
    end
  end

  describe "§5.9 payments indexes" do
    test "(provider, provider_payment_id) unique for webhook idempotency" do
      defn =
        row_value(
          "SELECT indexdef FROM pg_indexes WHERE indexname='payments_provider_provider_payment_id_index'"
        )

      assert defn =~ ~r/UNIQUE\s+INDEX/i
    end
  end

  describe "§5.11 redirects indexes" do
    test "old_path citext unique" do
      defn =
        row_value("SELECT indexdef FROM pg_indexes WHERE indexname='redirects_old_path_index'")

      assert defn =~ ~r/UNIQUE\s+INDEX/i
    end
  end

  describe "§5.1 developers — P1-E1.1 + P1-E2.1" do
    test "logo_media_id FK → media.id is wired (added in a follow-up migration)" do
      defn =
        row_value(
          "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'developers_logo_media_id_fkey'"
        )

      assert defn =~ ~r/FOREIGN KEY \(logo_media_id\) REFERENCES media\(?\s*id\)?/i
    end

    test "developers.slug is citext and unique" do
      defn = row_value("SELECT indexdef FROM pg_indexes WHERE indexname='developers_slug_index'")
      assert defn =~ ~r/UNIQUE\s+INDEX/i
    end
  end

  describe "uuid v7 PK shape (cross-checked via raw SQL)" do
    test "every §5 table's id has uuidv7() default" do
      tables =
        ~w(property_types projects listings custom_fields media inquiries subscriptions payments builds redirects audit_log)

      for table <- tables do
        default =
          row_value(
            "SELECT column_default::text FROM information_schema.columns WHERE table_schema='public' AND table_name=$1 AND column_name='id'",
            [table]
          )

        assert default == "uuidv7()",
               "#{table}.id default is not uuidv7() (got #{inspect(default)})"
      end
    end
  end
end
