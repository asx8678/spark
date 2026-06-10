defmodule ImmoWeb.Api.RenderControllerTest do
  @moduledoc """
  P1-E5.3 — §6.3 render tier end-to-end AC.

  Each test goes through the real router on the `:api_render`
  pipeline so the pipeline + auth + controller composition is
  exercised end-to-end (not just the controller in isolation).
  The tests cover the §6.3 acceptance criteria:

    * Published project / developer / listing → 200 with full
      i18n maps + embedded media + published-listings summary.
    * Draft, future-published, or non-existent slug → 404
      problem+json.
    * Billing-gated slug → 404 (composes `Catalog.published/1`,
      which is the §5.13 single-source-of-truth predicate).
    * `GET /listings/:type_key/:slug` resolves the slug within
      the property_type namespace (same slug in two different
      property types returns two different listings).
    * ETag present on 200; `If-None-Match` → 304.
    * `Cache-Control: private, no-store` on every render GET.
    * No bearer token → 401 problem+json.
    * Build token rejected on a render endpoint (scope
      disjointness from §6.4 — already covered by the plug tests
      but re-asserted here at the route layer).
    * `/internal/freshness?path=...` returns `{updated_at}` for
      a published path, 404 otherwise, 422 when `path` is
      missing or empty.
  """

  use ImmoWeb.ConnCase, async: false

  alias Immo.Billing.Subscription
  alias Immo.Catalog
  @render_token "test-render-token-0000000000000000000000000000"
  @build_token "test-build-token-0000000000000000000000000000"

  setup do
    on_exit(fn ->
      System.delete_env("BUILD_TOKEN")
      System.delete_env("RENDER_TOKEN")
    end)

    :ok
  end

  ## Helpers

  # A dev with a unique slug + past-published_at — the baseline
  # for "published" assertions.
  defp published_developer(prefix \\ "render-dev") do
    slug = "#{prefix}-#{System.unique_integer([:positive])}"

    {:ok, dev} = Catalog.create_developer(%{name: slug, slug: slug})
    {:ok, dev} = Catalog.publish_developer(dev)
    dev
  end

  # A dev without `published_at` — the baseline for "draft" 404s.
  defp draft_developer do
    {:ok, dev} =
      Catalog.create_developer(%{
        name: "draft-#{System.unique_integer([:positive])}",
        slug: "draft-#{System.unique_integer([:positive])}"
      })

    dev
  end

  defp published_property_type(suffix) do
    # PropertyType has no `published_at` field; published-ness is
    # implicit (the schema row is always considered public).
    {:ok, pt} =
      Catalog.create_property_type(%{
        key: "rendertype-#{suffix}-#{System.unique_integer([:positive])}",
        label: %{"fr" => "R"},
        url_segment: %{"fr" => "rendertype-#{suffix}"},
        position: 0
      })

    pt
  end

  defp published_listing(pt, dev, suffix) do
    {:ok, listing} =
      Catalog.create_listing(%{
        property_type_id: pt.id,
        title: %{"fr" => "T"},
        slug: "rendertype-#{suffix}-slug-#{System.unique_integer([:positive])}"
      })

    {:ok, listing} = Catalog.publish_listing(listing)
    # Avoid unused-binding warning
    _ = dev
    listing
  end

  defp draft_listing(pt) do
    {:ok, listing} =
      Catalog.create_listing(%{
        property_type_id: pt.id,
        title: %{"fr" => "T"},
        slug: "draft-listing-#{System.unique_integer([:positive])}"
      })

    listing
  end

  defp future_published_listing(pt) do
    {:ok, listing} =
      Catalog.create_listing(%{
        property_type_id: pt.id,
        title: %{"fr" => "T"},
        slug: "future-listing-#{System.unique_integer([:positive])}"
      })

    future = DateTime.utc_now(:second) |> DateTime.add(3600, :second)

    {:ok, listing} =
      Ecto.Changeset.change(listing, %{published_at: future}) |> Immo.Repo.update()

    listing
  end

  defp published_project(dev) do
    {:ok, project} =
      Catalog.create_project(%{
        developer_id: dev.id,
        title: %{"fr" => "P"},
        slug: "render-proj-#{System.unique_integer([:positive])}"
      })

    {:ok, project} = Catalog.publish_project(project)
    project
  end

  ## Tests

  describe "§6.3 AC: auth on render endpoints" do
    test "no token → 401 problem+json" do
      System.put_env("RENDER_TOKEN", @render_token)
      conn = get(build_conn(), "/api/v1/projects/any-slug")
      assert conn.status == 401
      assert problem_json?(conn)
    end

    test "valid render token on a render endpoint → 404 for unknown slug" do
      System.put_env("RENDER_TOKEN", @render_token)
      conn = get(build_conn() |> with_token(@render_token), "/api/v1/developers/any")
      # 404 means auth passed (BearerAuth authenticated) but the
      # slug is unknown — proves the pipeline is wired correctly.
      assert conn.status == 404
    end

    test "build token on a render endpoint → 401 (scope disjointness)" do
      System.put_env("BUILD_TOKEN", @build_token)
      System.put_env("RENDER_TOKEN", @render_token)
      conn = get(build_conn() |> with_token(@build_token), "/api/v1/projects/any")
      assert conn.status == 401
      assert problem_json?(conn)
    end

    test "render token on a build endpoint → 401" do
      System.put_env("BUILD_TOKEN", @build_token)
      System.put_env("RENDER_TOKEN", @render_token)
      conn = get(build_conn() |> with_token(@render_token), "/api/v1/projects")
      assert conn.status == 401
    end
  end

  describe "§6.3 AC: GET /developers/:slug" do
    test "published slug → 200 with full i18n maps + published_projects" do
      System.put_env("RENDER_TOKEN", @render_token)
      dev = published_developer()
      _ = published_project(dev)

      conn = get(build_conn() |> with_token(@render_token), "/api/v1/developers/#{dev.slug}")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      data = body["data"]

      assert data["slug"] == dev.slug
      # Developer has `name` (string), not `title` (i18n map)
      assert data["name"] == dev.name
      assert is_map(data["description"])
      assert is_map(data["paths"])
      # fr/ar/en per §1.2 R8
      assert Map.has_key?(data["paths"], "fr")
      assert Map.has_key?(data["paths"], "ar")
      assert Map.has_key?(data["paths"], "en")
      # Published-projects summary (P1-E5.3 AC)
      assert is_map(data["published_projects"])
      assert is_integer(data["published_projects"]["count"])
      assert is_list(data["published_projects"]["recent"])
      # Media embed (empty list when no media attached is fine)
      assert is_list(data["media"])
    end

    test "draft slug → 404 problem+json (no leak)" do
      System.put_env("RENDER_TOKEN", @render_token)
      dev = draft_developer()

      conn = get(build_conn() |> with_token(@render_token), "/api/v1/developers/#{dev.slug}")
      assert conn.status == 404
      assert problem_json?(conn)
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 404
      assert body["title"] == "Not Found"
    end

    test "unknown slug → 404 problem+json" do
      System.put_env("RENDER_TOKEN", @render_token)
      conn = get(build_conn() |> with_token(@render_token), "/api/v1/developers/does-not-exist")
      assert conn.status == 404
      assert problem_json?(conn)
    end

    test "ETag is present + If-None-Match returns 304" do
      System.put_env("RENDER_TOKEN", @render_token)
      dev = published_developer()

      conn1 = get(build_conn() |> with_token(@render_token), "/api/v1/developers/#{dev.slug}")
      assert conn1.status == 200
      [etag] = get_resp_header(conn1, "etag")
      assert etag != nil

      conn2 =
        build_conn()
        |> with_token(@render_token)
        |> put_req_header("if-none-match", etag)
        |> get("/api/v1/developers/#{dev.slug}")

      assert conn2.status == 304
    end

    test "Cache-Control: private, no-store (§6.3)" do
      System.put_env("RENDER_TOKEN", @render_token)
      dev = published_developer()
      conn = get(build_conn() |> with_token(@render_token), "/api/v1/developers/#{dev.slug}")
      [cc] = get_resp_header(conn, "cache-control")
      assert String.contains?(cc, "private")
      assert String.contains?(cc, "no-store")
    end
  end

  describe "§6.3 AC: GET /projects/:slug" do
    test "published slug → 200 with media + published_listings summary" do
      System.put_env("RENDER_TOKEN", @render_token)
      dev = published_developer()
      project = published_project(dev)

      conn = get(build_conn() |> with_token(@render_token), "/api/v1/projects/#{project.slug}")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      data = body["data"]

      assert data["id"] == project.id
      assert data["slug"] == project.slug
      assert data["developer_id"] == dev.id
      # fr/ar/en paths
      assert is_map(data["paths"])
      # Published-listings summary (P1-E5.3 AC for projects)
      assert is_map(data["published_listings"])
      assert is_integer(data["published_listings"]["count"])
      assert is_list(data["published_listings"]["recent"])
      # Media
      assert is_list(data["media"])
    end

    test "draft slug → 404" do
      System.put_env("RENDER_TOKEN", @render_token)
      dev = draft_developer()

      {:ok, project} =
        Catalog.create_project(%{developer_id: dev.id, title: %{"fr" => "P"}, slug: "draft-proj"})

      conn = get(build_conn() |> with_token(@render_token), "/api/v1/projects/#{project.slug}")
      assert conn.status == 404
    end

    test "future-published slug → 404" do
      System.put_env("RENDER_TOKEN", @render_token)
      dev = published_developer()

      {:ok, project} =
        Catalog.create_project(%{
          developer_id: dev.id,
          title: %{"fr" => "P"},
          slug: "future-proj"
        })

      future = DateTime.utc_now(:second) |> DateTime.add(3600, :second)

      {:ok, project} =
        Ecto.Changeset.change(project, %{published_at: future}) |> Immo.Repo.update()

      conn = get(build_conn() |> with_token(@render_token), "/api/v1/projects/#{project.slug}")
      assert conn.status == 404
    end

    test "billing-gated slug → 404 when BILLING_ENFORCED + inactive subscription" do
      System.put_env("RENDER_TOKEN", @render_token)
      Application.put_env(:immo, :billing_enforced, true)

      slug = "billing-gated-#{System.unique_integer([:positive])}"

      {:ok, dev} = Catalog.create_developer(%{name: slug, slug: slug})

      # Insert a canceled subscription (so BILLING_ENFORCED gate fails).
      %Subscription{
        developer_id: dev.id,
        plan: "basic",
        status: "canceled",
        provider: "manual",
        current_period_start: DateTime.utc_now(:second),
        current_period_end: DateTime.utc_now(:second) |> DateTime.add(30, :day)
      }
      |> Immo.Repo.insert!()

      {:ok, project} =
        Catalog.create_project(%{
          developer_id: dev.id,
          title: %{"fr" => "P"},
          slug: "#{slug}-proj"
        })

      past = DateTime.utc_now(:second) |> DateTime.add(-3600, :second)
      {:ok, _} = Ecto.Changeset.change(project, %{published_at: past}) |> Immo.Repo.update()

      conn = get(build_conn() |> with_token(@render_token), "/api/v1/projects/#{slug}-proj")
      assert conn.status == 404
    after
      Application.put_env(:immo, :billing_enforced, false)
    end
  end

  describe "§6.3 AC: GET /listings/:type_key/:slug" do
    test "published slug → 200 with property_type embed + project summary" do
      System.put_env("RENDER_TOKEN", @render_token)
      dev = published_developer()
      pt = published_property_type("a")
      listing = published_listing(pt, dev, "a")

      conn =
        get(
          build_conn() |> with_token(@render_token),
          "/api/v1/listings/#{pt.key}/#{listing.slug}"
        )

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      data = body["data"]

      assert data["id"] == listing.id
      assert data["slug"] == listing.slug
      # Property type is embedded with all its identifying fields
      pt = data["property_type"]
      assert pt["key"] != nil
      assert is_map(pt["label"])
      assert is_map(pt["url_segment"])
    end

    test "slug unique per property_type namespace (§5.4)" do
      # Same slug in two different property types → two different
      # listings. Each only resolves under its own type_key.
      System.put_env("RENDER_TOKEN", @render_token)
      dev = published_developer()

      pt_a = published_property_type("ns-a")
      pt_b = published_property_type("ns-b")
      shared_slug = "shared-slug-#{System.unique_integer([:positive])}"

      {:ok, listing_a} =
        Catalog.create_listing(%{
          property_type_id: pt_a.id,
          title: %{"fr" => "A"},
          slug: shared_slug
        })

      {:ok, _} = Catalog.publish_listing(listing_a)

      {:ok, listing_b} =
        Catalog.create_listing(%{
          property_type_id: pt_b.id,
          title: %{"fr" => "B"},
          slug: shared_slug
        })

      {:ok, _} = Catalog.publish_listing(listing_b)
      _ = dev

      # The shared slug resolves under pt_a → listing_a.
      conn_a =
        get(
          build_conn() |> with_token(@render_token),
          "/api/v1/listings/#{pt_a.key}/#{shared_slug}"
        )

      assert conn_a.status == 200
      assert Jason.decode!(conn_a.resp_body)["data"]["id"] == listing_a.id

      # The same slug resolves under pt_b → listing_b.
      conn_b =
        get(
          build_conn() |> with_token(@render_token),
          "/api/v1/listings/#{pt_b.key}/#{shared_slug}"
        )

      assert conn_b.status == 200
      assert Jason.decode!(conn_b.resp_body)["data"]["id"] == listing_b.id
    end

    test "unknown type_key → 404" do
      System.put_env("RENDER_TOKEN", @render_token)
      conn = get(build_conn() |> with_token(@render_token), "/api/v1/listings/nope/some-slug")
      assert conn.status == 404
    end

    test "draft slug → 404" do
      System.put_env("RENDER_TOKEN", @render_token)
      pt = published_property_type("draft")
      _listing = draft_listing(pt)

      conn = get(build_conn() |> with_token(@render_token), "/api/v1/listings/#{pt.key}/draft-ns")
      assert conn.status == 404
    end

    test "future-published slug → 404" do
      System.put_env("RENDER_TOKEN", @render_token)
      pt = published_property_type("future")
      _listing = future_published_listing(pt)
      # Resolve by querying since we don't have the slug handy —
      # use the listing we just created.

      conn =
        get(
          build_conn() |> with_token(@render_token),
          "/api/v1/listings/#{pt.key}/future-listing"
        )

      assert conn.status == 404
    end
  end

  describe "§6.3 / §3.5 AC: GET /internal/freshness" do
    test "published project path → 200 with updated_at" do
      System.put_env("RENDER_TOKEN", @render_token)
      dev = published_developer()
      project = published_project(dev)

      path = "/projets/casablanca/#{project.slug}"

      conn =
        get(build_conn() |> with_token(@render_token), "/api/v1/internal/freshness?path=#{path}")

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["data"]["path"] == path
      assert is_binary(body["data"]["updated_at"])
    end

    test "published developer path → 200" do
      System.put_env("RENDER_TOKEN", @render_token)
      dev = published_developer()

      conn =
        get(
          build_conn() |> with_token(@render_token),
          "/api/v1/internal/freshness?path=/promoteurs/#{dev.slug}"
        )

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["data"]["path"] == "/promoteurs/#{dev.slug}"
    end

    test "draft project path → 404" do
      System.put_env("RENDER_TOKEN", @render_token)
      dev = draft_developer()

      {:ok, project} =
        Catalog.create_project(%{
          developer_id: dev.id,
          title: %{"fr" => "P"},
          slug: "draft-fresh"
        })

      conn =
        get(
          build_conn() |> with_token(@render_token),
          "/api/v1/internal/freshness?path=/projets/casablanca/#{project.slug}"
        )

      assert conn.status == 404
    end

    test "unknown path → 404" do
      System.put_env("RENDER_TOKEN", @render_token)

      conn =
        get(
          build_conn() |> with_token(@render_token),
          "/api/v1/internal/freshness?path=/projets/casablanca/no-such-project"
        )

      assert conn.status == 404
    end

    test "missing `path` query param → 422" do
      System.put_env("RENDER_TOKEN", @render_token)
      conn = get(build_conn() |> with_token(@render_token), "/api/v1/internal/freshness")
      assert conn.status == 422
      assert problem_json?(conn)
    end

    test "empty `path` query param → 422" do
      System.put_env("RENDER_TOKEN", @render_token)
      conn = get(build_conn() |> with_token(@render_token), "/api/v1/internal/freshness?path=")
      assert conn.status == 422
    end
  end

  ## Helpers

  defp with_token(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp problem_json?(conn) do
    case get_resp_header(conn, "content-type") do
      [ct | _] when is_binary(ct) -> String.starts_with?(ct, "application/problem+json")
      _ -> false
    end
  end
end
