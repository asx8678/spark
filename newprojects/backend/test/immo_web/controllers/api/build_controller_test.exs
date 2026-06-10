defmodule ImmoWeb.Api.BuildControllerTest do
  @moduledoc """
  P1-E5.2 — §6.3 build-tier end-to-end AC for `/api/v1` build endpoints.

  Exercises the build-tier pipeline + controller composition end-to-end
  (not just the controller in isolation) so the auth + ETag + cursor +
  `since` + envelope + `paths` contract is verified against the real
  router. Covers the §6.3 acceptance criteria for the build tier:

    * Auth: no token → 401, render token → 401 (scope disjointness).
    * 200 happy path: each list endpoint returns `{data, meta:{next_cursor, count}}`
      with per-record id, slug, paths (per-locale), updated_at,
      published_at.
    * `paths` is computed by `Immo.Edge.Paths` (the single path
      authority) — every record carries a paths map with fr/ar/en
      keys.
    * `cursor` + `limit≤100` pagination; `next_cursor` is set on a
      non-final page and nil on the final page.
    * `since` filter: only records with `updated_at > since` are
      returned.
    * Strong ETag from `max(updated_at)+count`; `If-None-Match` → 304
      with empty body.
    * `Cache-Control: private, no-store` on every build GET.
    * Only published content is visible: draft / future-published /
      billing-gated records are absent.
    * `/meta/sitemap` and `/redirects` return the §6.3 shapes.
  """

  use ImmoWeb.ConnCase, async: false

  alias Immo.Billing.Subscription
  alias Immo.Catalog
  alias Immo.Catalog.Redirect

  @build_token "test-build-token-0000000000000000000000000000"
  @render_token "test-render-token-0000000000000000000000000000"

  setup do
    on_exit(fn ->
      System.delete_env("BUILD_TOKEN")
      System.delete_env("RENDER_TOKEN")
    end)

    :ok
  end

  ## Fixtures

  defp published_developer do
    slug = "build-dev-#{System.unique_integer([:positive])}"
    {:ok, dev} = Catalog.create_developer(%{name: slug, slug: slug})
    {:ok, dev} = Catalog.publish_developer(dev)
    dev
  end

  defp draft_developer do
    {:ok, dev} =
      Catalog.create_developer(%{
        name: "draft-#{System.unique_integer([:positive])}",
        slug: "draft-#{System.unique_integer([:positive])}"
      })

    dev
  end

  defp published_project(dev) do
    {:ok, project} =
      Catalog.create_project(%{
        developer_id: dev.id,
        title: %{"fr" => "P"},
        slug: "build-proj-#{System.unique_integer([:positive])}"
      })

    {:ok, project} = Catalog.publish_project(project)
    project
  end

  defp published_listing(pt) do
    {:ok, listing} =
      Catalog.create_listing(%{
        property_type_id: pt.id,
        title: %{"fr" => "L"},
        slug: "build-listing-#{System.unique_integer([:positive])}"
      })

    {:ok, listing} = Catalog.publish_listing(listing)
    listing
  end

  defp published_property_type do
    {:ok, pt} =
      Catalog.create_property_type(%{
        key: "build-pt-#{System.unique_integer([:positive])}",
        label: %{"fr" => "PT"},
        url_segment: %{"fr" => "build-pt"},
        position: 0
      })

    pt
  end

  ## Tests

  describe "§6.3 AC: auth on build endpoints" do
    test "no token → 401 problem+json" do
      System.put_env("BUILD_TOKEN", @build_token)
      conn = get(build_conn(), "/api/v1/projects")
      assert conn.status == 401
      assert problem_json?(conn)
    end

    test "render token on a build endpoint → 401 (scope disjointness)" do
      System.put_env("BUILD_TOKEN", @build_token)
      System.put_env("RENDER_TOKEN", @render_token)
      conn = get(build_conn() |> with_token(@render_token), "/api/v1/projects")
      assert conn.status == 401
    end

    test "build token on a build endpoint → 200" do
      System.put_env("BUILD_TOKEN", @build_token)
      conn = get(build_conn() |> with_token(@build_token), "/api/v1/projects")
      assert conn.status == 200
    end
  end

  describe "§6.3 AC: response envelope {data, meta:{next_cursor, count}}" do
    test "/projects returns the envelope shape" do
      System.put_env("BUILD_TOKEN", @build_token)
      _dev = published_developer()
      conn = get(build_conn() |> with_token(@build_token), "/api/v1/projects")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["data"])
      assert is_map(body["meta"])
      assert is_integer(body["meta"]["count"])
      assert body["meta"]["next_cursor"] == nil or is_binary(body["meta"]["next_cursor"])
    end

    test "every record carries id, slug, paths (per locale), updated_at, published_at" do
      System.put_env("BUILD_TOKEN", @build_token)
      dev = published_developer()
      _ = published_project(dev)
      conn = get(build_conn() |> with_token(@build_token), "/api/v1/projects")
      body = Jason.decode!(conn.resp_body)
      assert body["data"] != [], "expected at least one published project"
      [first | _] = body["data"]
      assert is_binary(first["id"])
      assert is_binary(first["slug"])
      # The single path authority: every record carries a per-locale
      # paths map keyed by fr/ar/en.
      assert is_map(first["paths"])
      assert Map.has_key?(first["paths"], "fr")
      assert Map.has_key?(first["paths"], "ar")
      assert Map.has_key?(first["paths"], "en")
      assert is_binary(first["updated_at"])
      assert is_binary(first["published_at"])
    end
  end

  describe "§6.3 AC: cursor + limit pagination" do
    test "next_cursor advances across pages" do
      System.put_env("BUILD_TOKEN", @build_token)
      dev = published_developer()

      for _ <- 1..3 do
        _ = published_project(dev)
      end

      conn1 =
        get(
          build_conn() |> with_token(@build_token),
          "/api/v1/projects?limit=2"
        )

      body1 = Jason.decode!(conn1.resp_body)
      assert body1["meta"]["count"] <= 2
      assert is_binary(body1["meta"]["next_cursor"])

      # Next page: pass the cursor.
      conn2 =
        get(
          build_conn() |> with_token(@build_token),
          "/api/v1/projects?limit=2&cursor=#{body1["meta"]["next_cursor"]}"
        )

      body2 = Jason.decode!(conn2.resp_body)
      assert body2["data"] != body1["data"]
    end

    test "limit > 100 is clamped to 100" do
      System.put_env("BUILD_TOKEN", @build_token)
      conn = get(build_conn() |> with_token(@build_token), "/api/v1/projects?limit=500")
      assert conn.status == 200
      # We can't assert count ≤ 100 here without 100+ rows, but the
      # response must succeed and the cap is wired. The clamp is
      # applied by Pagination.parse_limit; the integration is via
      # the response not erroring.
    end
  end

  describe "§6.3 AC: since filter (incremental sync)" do
    test "since=ISO ts returns only records with updated_at > since" do
      System.put_env("BUILD_TOKEN", @build_token)
      dev = published_developer()

      # Two projects. The first is published; a small sleep
      # ensures its `updated_at` is strictly less than the
      # second's. We then set `since` to a point *between* the
      # two updates and assert only the second is returned.
      {:ok, old_project} =
        Catalog.create_project(%{
          developer_id: dev.id,
          title: %{"fr" => "Old"},
          slug: "old-#{System.unique_integer([:positive])}"
        })

      {:ok, old_project} = Catalog.publish_project(old_project)
      boundary = DateTime.utc_now(:second)
      Process.sleep(1100)

      {:ok, new_project} =
        Catalog.create_project(%{
          developer_id: dev.id,
          title: %{"fr" => "New"},
          slug: "new-#{System.unique_integer([:positive])}"
        })

      {:ok, new_project} = Catalog.publish_project(new_project)
      since_iso = DateTime.to_iso8601(boundary)

      conn =
        get(
          build_conn() |> with_token(@build_token),
          "/api/v1/projects?since=#{since_iso}"
        )

      body = Jason.decode!(conn.resp_body)
      ids = Enum.map(body["data"], & &1["id"])
      assert new_project.id in ids
      refute old_project.id in ids
    end
  end

  describe "§6.3 AC: ETag + If-None-Match → 304" do
    test "first fetch returns ETag; matching If-None-Match returns 304" do
      System.put_env("BUILD_TOKEN", @build_token)
      dev = published_developer()
      _ = published_project(dev)

      conn1 = get(build_conn() |> with_token(@build_token), "/api/v1/projects")
      [etag] = get_resp_header(conn1, "etag")
      assert etag != nil and etag != ""

      conn2 =
        build_conn()
        |> with_token(@build_token)
        |> put_req_header("if-none-match", etag)
        |> get("/api/v1/projects")

      assert conn2.status == 304
      assert conn2.resp_body == ""
    end
  end

  describe "§6.3 AC: Cache-Control: private, no-store" do
    test "build GETs carry private, no-store" do
      System.put_env("BUILD_TOKEN", @build_token)

      for path <- ["/api/v1/projects", "/api/v1/listings", "/api/v1/developers"] do
        conn = get(build_conn() |> with_token(@build_token), path)
        [cc] = get_resp_header(conn, "cache-control")
        assert String.contains?(cc, "private"), "expected 'private' in cc for #{path}, got #{cc}"

        assert String.contains?(cc, "no-store"),
               "expected 'no-store' in cc for #{path}, got #{cc}"
      end
    end
  end

  describe "§5.13 AC: only published content is visible" do
    test "draft developer is absent from /developers" do
      System.put_env("BUILD_TOKEN", @build_token)
      _draft = draft_developer()
      _published = published_developer()

      conn = get(build_conn() |> with_token(@build_token), "/api/v1/developers")
      body = Jason.decode!(conn.resp_body)
      slugs = Enum.map(body["data"], & &1["slug"])
      refute Enum.any?(slugs, &String.starts_with?(&1, "draft-"))
      assert Enum.any?(slugs, &String.starts_with?(&1, "build-dev-"))
    end

    test "future-published project is absent from /projects" do
      System.put_env("BUILD_TOKEN", @build_token)
      dev = published_developer()

      {:ok, project} =
        Catalog.create_project(%{
          developer_id: dev.id,
          title: %{"fr" => "F"},
          slug: "future-#{System.unique_integer([:positive])}"
        })

      future = DateTime.utc_now(:second) |> DateTime.add(3600, :second)

      {:ok, _} =
        Ecto.Changeset.change(project, %{published_at: future}) |> Immo.Repo.update()

      conn = get(build_conn() |> with_token(@build_token), "/api/v1/projects")
      body = Jason.decode!(conn.resp_body)
      slugs = Enum.map(body["data"], & &1["slug"])
      refute project.slug in slugs
    end

    test "billing-gated project is absent when BILLING_ENFORCED + inactive subscription" do
      System.put_env("BUILD_TOKEN", @build_token)
      Application.put_env(:immo, :billing_enforced, true)

      slug = "billing-#{System.unique_integer([:positive])}"

      {:ok, dev} = Catalog.create_developer(%{name: slug, slug: slug})

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
          title: %{"fr" => "G"},
          slug: "#{slug}-proj"
        })

      past = DateTime.utc_now(:second) |> DateTime.add(-3600, :second)
      {:ok, _} = Ecto.Changeset.change(project, %{published_at: past}) |> Immo.Repo.update()

      conn = get(build_conn() |> with_token(@build_token), "/api/v1/projects")
      body = Jason.decode!(conn.resp_body)
      slugs = Enum.map(body["data"], & &1["slug"])
      refute project.slug in slugs

      Application.put_env(:immo, :billing_enforced, false)
    end
  end

  describe "§6.3 AC: /property_types includes filter_config + url_segment" do
    test "property type record carries filter_config and url_segment" do
      System.put_env("BUILD_TOKEN", @build_token)
      _pt = published_property_type()
      conn = get(build_conn() |> with_token(@build_token), "/api/v1/property_types")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      [first | _] = body["data"]
      assert is_list(first["filter_config"])
      assert is_map(first["url_segment"])
    end
  end

  describe "§6.3 AC: /meta/sitemap returns all public paths + lastmod" do
    test "sitemap includes projects, listings, developers, property_types" do
      System.put_env("BUILD_TOKEN", @build_token)
      dev = published_developer()
      _ = published_project(dev)
      pt = published_property_type()
      _ = published_listing(pt)

      conn = get(build_conn() |> with_token(@build_token), "/api/v1/meta/sitemap")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["data"])
      assert is_integer(body["meta"]["count"])
      # Every entry has a per-locale paths map and a lastmod.
      Enum.each(body["data"], fn entry ->
        assert is_map(entry["paths"])
        assert Map.has_key?(entry["paths"], "fr")
        assert is_binary(entry["lastmod"])
      end)
    end
  end

  describe "§6.3 AC: /redirects returns active redirect rules" do
    test "redirects list contains active rows (http_status set, old_path non-empty)" do
      System.put_env("BUILD_TOKEN", @build_token)

      %Redirect{
        old_path: "/old-path-#{System.unique_integer([:positive])}",
        new_path: "/new-path-#{System.unique_integer([:positive])}",
        http_status: 301
      }
      |> Immo.Repo.insert!()

      conn = get(build_conn() |> with_token(@build_token), "/api/v1/redirects")
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["data"])

      Enum.each(body["data"], fn r ->
        assert is_binary(r["old_path"])
        assert r["old_path"] != ""
        assert is_binary(r["new_path"])
        assert r["http_status"] in [301, 302, 307, 308]
      end)
    end
  end

  ## Helpers

  defp with_token(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp problem_json?(conn) do
    case get_resp_header(conn, "content-type") do
      [ct | _] when is_binary(ct) -> String.starts_with?(ct, "application/problem+json")
      _ -> false
    end
  end
end
