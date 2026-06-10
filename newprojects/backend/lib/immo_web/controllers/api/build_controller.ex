defmodule ImmoWeb.Api.BuildController do
  @moduledoc """
  §6.3 — Build-tier read API for the `/api/v1` scheduled build's
  content loaders. Mounted on the `:api_build` pipeline (BUILD_TOKEN,
  §10.1 path 1).

  ## Endpoints (per §6.3 table)

    * `GET /api/v1/projects`         — paginated published projects
    * `GET /api/v1/listings`         — paginated published listings
    * `GET /api/v1/developers`       — paginated published developers
    * `GET /api/v1/property_types`   — property types (published only)
    * `GET /api/v1/meta/sitemap`     — all public paths + lastmod + locale alternates
    * `GET /api/v1/redirects`        — active redirect rules

  ## Query params (per §6.3)

    * `cursor` — opaque keyset cursor (base64-encoded id); pages are
      stable across requests with the same `since` window.
    * `limit`  — page size, clamped at 100 (default 50).
    * `since`  — ISO-8601 timestamp; only records with
      `updated_at > since` are returned (powers incremental sync).

  ## Response shape (per §6.3)

    List envelope: `{data: [...], meta: {next_cursor, count}}`
    Each record: `id`, `slug`, `path` (per locale via `Immo.Edge.Paths`),
    `updated_at`, `published_at`, i18n maps keyed by locale.

  ## Caching (per §6.3)

    Strong ETag from `max(updated_at)+count` of the page. Honor
    `If-None-Match` → 304 with empty body. `Cache-Control: private,
    no-store` (build-tier dumps must not be CDN-cached — they're
    the source of truth the build is consuming).

  ## §5.13 publish predicate

    All queries compose `Catalog.published/1` so unpublished,
    future-published, and billing-gated records are absent.

  ## Out of scope for P1-E5.2

    * OpenAPI spec on each action (P1-E5.5).
    * Render-tier single-record reads (P1-E5.3).
    * CORS + Hammer rate-limit plug on the `:api_public` pipeline
      (P1-E5.4).
  """

  use ImmoWeb.Api, :controller

  # §6.3 / P1-E5.5 — every build-tier action advertises an
  # `open_api_spex` operation. The full spec (descriptions,
  # security, parameters, responses) is in `ImmoWeb.ApiSpec`
  # — the per-action annotations here exist so open_api_spex's
  # introspection finds the action with the same operationId
  # the spec references. If you add or rename an action,
  # also update `ImmoWeb.ApiSpec.paths_map/0`.
  use OpenApiSpex.ControllerSpecs

  alias Immo.Catalog
  alias Immo.Catalog.{Developer, Listing, Project, PropertyType}
  alias Immo.Edge
  alias ImmoWeb.Api.Pagination
  alias ImmoWeb.Api.ResponseShape

  operation(:projects, summary: "List published projects (build tier)")
  operation(:listings, summary: "List published listings (build tier)")
  operation(:developers, summary: "List published developers (build tier)")
  operation(:property_types, summary: "List property types (build tier)")
  operation(:sitemap, summary: "Sitemap entries (build tier)")
  operation(:redirects, summary: "Active redirects (build tier)")

  # Per §6.3: limit clamped at 100. Default 50.
  @default_limit 50
  @max_limit 100

  @doc "`GET /api/v1/projects`"
  def projects(conn, params) do
    conn
    |> list_published(Project, params, &shape_project/1)
  end

  @doc "`GET /api/v1/listings`"
  def listings(conn, params) do
    conn
    |> list_published(Listing, params, &shape_listing/1)
  end

  @doc "`GET /api/v1/developers`"
  def developers(conn, params) do
    conn
    |> list_published(Developer, params, &shape_developer/1)
  end

  @doc "`GET /api/v1/property_types`"
  def property_types(conn, params) do
    page =
      Pagination.from_params(params, default_limit: @default_limit, max_limit: @max_limit)
      |> Pagination.apply(&Catalog.list_published_property_types/1)
      |> Pagination.fetch_all()

    payload = ResponseShape.envelope(page, &shape_property_type/1)
    respond_with_etag(conn, page, payload)
  end

  @doc "`GET /api/v1/meta/sitemap`"
  def sitemap(conn, _params) do
    projects = Catalog.list_published_projects()
    listings = Catalog.list_published_listings()
    developers = Catalog.list_published_developers()
    property_types = Catalog.list_published_property_types()

    paths =
      projects
      |> Enum.map(&sitemap_entry_for_project/1)
      |> Enum.concat(Enum.map(listings, &sitemap_entry_for_listing/1))
      |> Enum.concat(Enum.map(developers, &sitemap_entry_for_developer/1))
      |> Enum.concat(Enum.map(property_types, &sitemap_entry_for_property_type/1))

    conn
    |> put_status(200)
    |> json(%{data: paths, meta: %{count: length(paths)}})
  end

  @doc "`GET /api/v1/redirects`"
  def redirects(conn, _params) do
    active_redirects = Catalog.list_active_redirects()

    payload = %{
      data:
        Enum.map(active_redirects, fn r ->
          %{
            old_path: r.old_path,
            new_path: r.new_path,
            http_status: r.http_status || 301
          }
        end),
      meta: %{count: length(active_redirects)}
    }

    respond_with_etag(conn, nil, payload)
  end

  ## Implementation

  # The four entity list endpoints share this pipeline: load +
  # shape + envelope + ETag. The shape_fn is the only entity-
  # specific bit (different fields per record type).
  defp list_published(conn, schema_module, params, shape_fn) do
    page =
      Pagination.from_params(params, default_limit: @default_limit, max_limit: @max_limit)
      |> Pagination.apply(fn opts -> list_published_for(schema_module, opts) end)
      |> Pagination.fetch_all()

    payload = ResponseShape.envelope(page, shape_fn)
    respond_with_etag(conn, page, payload)
  end

  defp list_published_for(Project, opts), do: Catalog.list_published_projects(opts)
  defp list_published_for(Listing, opts), do: Catalog.list_published_listings(opts)
  defp list_published_for(Developer, opts), do: Catalog.list_published_developers(opts)
  defp list_published_for(PropertyType, opts), do: Catalog.list_published_property_types(opts)

  ## Record shapes — one per entity, matching the §6.3 response
  ## convention: id, slug, path (per locale), updated_at,
  ## published_at, i18n maps keyed by locale.

  defp shape_project(p) do
    %{
      id: p.id,
      slug: p.slug,
      paths: Edge.Paths.paths_for_all_locales(p),
      developer_id: p.developer_id,
      title: p.title || %{},
      description: p.description || %{},
      status: p.status,
      city: p.city,
      region: p.region,
      country: p.country,
      lat: p.lat,
      lng: p.lng,
      seo: p.seo || %{},
      updated_at: p.updated_at,
      published_at: p.published_at,
      inserted_at: p.inserted_at
    }
  end

  defp shape_listing(l) do
    %{
      id: l.id,
      slug: l.slug,
      paths: Edge.Paths.paths_for_all_locales(l),
      property_type_id: l.property_type_id,
      project_id: l.project_id,
      title: l.title || %{},
      description: l.description || %{},
      price: l.price,
      price_on_request: l.price_on_request,
      currency: l.currency,
      status: l.status,
      address: l.address,
      city: l.city,
      region: l.region,
      country: l.country,
      lat: l.lat,
      lng: l.lng,
      surface_m2: l.surface_m2,
      attributes: l.attributes || %{},
      seo: l.seo || %{},
      updated_at: l.updated_at,
      published_at: l.published_at,
      inserted_at: l.inserted_at
    }
  end

  defp shape_developer(d) do
    %{
      id: d.id,
      slug: d.slug,
      paths: Edge.Paths.paths_for_all_locales(d),
      name: d.name,
      description: d.description || %{},
      logo_media_id: d.logo_media_id,
      contact: d.contact || %{},
      seo: d.seo || %{},
      updated_at: d.updated_at,
      published_at: d.published_at,
      inserted_at: d.inserted_at
    }
  end

  # `PropertyType` has no `published_at` field — every row is
  # considered published once created. We emit `published_at`
  # as the row's `inserted_at` so the §6.3 envelope stays
  # consistent across entity types (every record carries
  # `published_at`); consumers should treat the value as
  # "the moment the type became visible to the public".
  # `url_segment` is included per §6.3 so consumers can build
  # the per-locale listing URLs (`/appartements/...`,
  # `/terrains/...`) without recomputing from the property
  # type's `key`.
  defp shape_property_type(pt) do
    %{
      id: pt.id,
      key: pt.key,
      label: pt.label || %{},
      url_segment: pt.url_segment || %{},
      paths: Edge.Paths.paths_for_all_locales(pt),
      filter_config: pt.filter_config || [],
      schema_hints: pt.schema_hints || %{},
      position: pt.position,
      updated_at: pt.updated_at,
      published_at: pt.inserted_at
    }
  end

  ## Sitemap entry helpers — one per entity. The entry shape is
  ## `{path, lastmod, alternates: %{fr: ..., ar: ..., en: ...}}`
  ## per §6.3.

  defp sitemap_entry_for_project(p) do
    sitemap_entry(p, Edge.Paths.paths_for_all_locales(p), p.updated_at)
  end

  defp sitemap_entry_for_listing(l) do
    sitemap_entry(l, Edge.Paths.paths_for_all_locales(l), l.updated_at)
  end

  defp sitemap_entry_for_developer(d) do
    sitemap_entry(d, Edge.Paths.paths_for_all_locales(d), d.updated_at)
  end

  defp sitemap_entry_for_property_type(pt) do
    sitemap_entry(pt, Edge.Paths.paths_for_all_locales(pt), pt.updated_at)
  end

  defp sitemap_entry(_record, paths, lastmod) do
    %{
      paths: paths,
      lastmod: lastmod
    }
  end

  ## ETag + Cache-Control response (per §6.3)

  defp respond_with_etag(conn, page, payload) do
    etag = strong_etag_for(page, payload)

    if etag_matches?(conn, etag) do
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", "private, no-store")
      |> send_resp(304, "")
    else
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", "private, no-store")
      |> json(payload)
    end
  end

  # Strong ETag per §6.3: derived from `max(updated_at)+count` of
  # the page. When the page is nil (e.g. the redirects endpoint
  # which has no cursor pagination), fall back to a content hash.
  defp strong_etag_for(%Pagination{records: records, count: count}, _payload) do
    max_updated =
      records
      |> Enum.map(& &1.updated_at)
      |> Enum.max_by(&(&1 || DateTime.utc_now()), fn -> DateTime.utc_now() end)

    raw = "#{max_updated |> DateTime.to_iso8601()}|#{count}"
    "\"#{:crypto.hash(:md5, raw) |> Base.encode16(case: :lower)}\""
  end

  defp strong_etag_for(_nil, payload) do
    raw = :erlang.term_to_binary(payload)
    "\"#{:crypto.hash(:md5, raw) |> Base.encode16(case: :lower)}\""
  end

  defp etag_matches?(conn, etag) do
    case get_req_header(conn, "if-none-match") do
      [if_none_match | _] -> String.trim(if_none_match) == etag
      _ -> false
    end
  end
end
