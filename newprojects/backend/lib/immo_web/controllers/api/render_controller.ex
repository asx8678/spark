defmodule ImmoWeb.Api.RenderController do
  @moduledoc """
  §6.3 — Render-tier read API for the `/api/v1` SSR Worker's
  single-record lookups. Mounted on the `:api_render` pipeline
  (RENDER_TOKEN, §10.1 path 2).

  ## Endpoints (per §6.3 table)

    * `GET /api/v1/projects/:slug`
    * `GET /api/v1/listings/:type_key/:slug`
    * `GET /api/v1/developers/:slug`
    * `GET /api/v1/internal/freshness?path=...`

  ## Why a separate tier (§10.1)

  The render tier is hit on every cold-cache SSR miss between
  scheduled builds. Restricting it to a dedicated RENDER_TOKEN
  (disjoint from BUILD_TOKEN, §6.4) prevents cache-busting
  amplification: an attacker with a build token cannot force
  arbitrary SSR misses for any slug; the render token's holder
  is the SSR Worker, which already knows what it needs to fetch.

  ## Response shape (per §6.3)

  Single-record payload, **all locales present** (i18n maps
  keyed by locale, not a single-locale projection). Embedded
  media ordered by `position` (incl. `r2_key`, `blurhash`,
  `dimensions`, `alt`). For projects, a published-listings
  summary is embedded (P1-E5.3 AC).

  Missing or unpublished slugs → `404` problem+json (§6.3 — the
  §R3 immediate-404 behavior when an admin unpublishes a page).

  ## Caching (per §6.3)

  Strong ETag derived from the record's `updated_at`. `If-None-
  Match` → 304 with empty body. `Cache-Control: private, no-store`
  (the render consumer is the SSR Worker; KV caching happens
  upstream in P4, not here).

  ## §5.13 publish predicate

  All lookups compose `Catalog.published/1`. A record outside the
  predicate (draft / future-published / billing-gated) is a 404,
  never a leak.

  ## Out of scope for P1-E5.3

    * The SSR Worker that calls these (P4).
    * Switching the §3.5 freshness source from KV to
      `/internal/freshness` (P9 backlog).
    * OpenAPI spec on each action (P1-E5.5).
  """

  use ImmoWeb.Api, :controller

  # §6.3 / P1-E5.5 — every render-tier action advertises an
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
  alias Immo.Media

  import Ecto.Query, only: [where: 3]
  operation(:project, summary: "Single published project (render tier)")
  operation(:listing, summary: "Single published listing (render tier)")
  operation(:developer, summary: "Single published developer (render tier)")
  operation(:freshness, summary: "Freshness check for a public path (render tier)")

  @doc """
  `GET /api/v1/projects/:slug` — single published project record.

  Embeds:
    * `media` — `Immo.Media.list_media_for(:Project, project.id)`
      ordered by `position`.
    * `published_listings` — a `{count, recent: [...]}` summary
      per P1-E5.3 AC. `recent` carries at most 10 of the project's
      published listings, summary-style.
  """
  def project(conn, %{"slug" => slug}) do
    case Catalog.get_published_project_by_slug(slug) do
      %Project{} = project ->
        data =
          project
          |> shape_project()
          |> Map.put(:media, embedded_media_for_project(project))
          |> Map.put(:published_listings, published_listings_summary(project))

        respond_with_etag(conn, project, %{data: data})

      nil ->
        ImmoWeb.FallbackController.not_found(conn)
    end
  end

  def project(conn, _params), do: ImmoWeb.FallbackController.not_found(conn)

  @doc """
  `GET /api/v1/listings/:type_key/:slug` — single published listing.

  The `:type_key` is the property_type's `key` (e.g. `apartment`),
  not its URL segment. The URL is the §6.3 contract; the type
  resolution composes `Edge.Paths` to confirm the slug is unique
  within the type's namespace per §5.4.
  """
  def listing(conn, %{"type_key" => type_key, "slug" => slug}) do
    case resolve_listing(type_key, slug) do
      {:ok, %Listing{} = listing, %PropertyType{id: _id, key: _key} = pt} ->
        data =
          listing
          |> shape_listing(pt)
          |> Map.put(:media, embedded_media_for_listing(listing))
          |> Map.put(:project, project_summary_for_listing(listing))

        respond_with_etag(conn, listing, %{data: data})

      _ ->
        ImmoWeb.FallbackController.not_found(conn)
    end
  end

  def listing(conn, _params), do: ImmoWeb.FallbackController.not_found(conn)

  @doc """
  `GET /api/v1/developers/:slug` — single published developer.

  Embeds:
    * `media` (logo + any photos attached to the developer).
    * `published_projects` — a `{count, recent: [...]}` summary
      of the developer's published projects.
  """
  def developer(conn, %{"slug" => slug}) do
    case Catalog.get_published_developer_by_slug(slug) do
      %Developer{} = developer ->
        data =
          developer
          |> shape_developer()
          |> Map.put(:media, embedded_media_for_developer(developer))
          |> Map.put(:published_projects, published_projects_summary(developer))

        respond_with_etag(conn, developer, %{data: data})

      nil ->
        ImmoWeb.FallbackController.not_found(conn)
    end
  end

  def developer(conn, _params), do: ImmoWeb.FallbackController.not_found(conn)

  @doc """
  `GET /api/v1/internal/freshness?path=...` — the documented
  §3.5 KV-alternative for the freshness check. Returns the
  `updated_at` of the entity behind the path, or 404 if the
  path is unknown / unpublished.

  Implemented, **unused by default** per §6.3: the SSR Worker
  currently reads from Cloudflare KV (§3.5). P9 may flip the
  source if KV lag bites.
  """
  def freshness(conn, %{"path" => path}) when is_binary(path) and path != "" do
    case Catalog.freshness_for_path(path) do
      {:ok, %DateTime{} = updated_at} ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> json(%{
          data: %{path: path, updated_at: updated_at},
          meta: %{}
        })

      nil ->
        ImmoWeb.FallbackController.not_found(conn)
    end
  end

  def freshness(conn, _params) do
    # Missing or empty `path` is a 422 — the request is well-formed
    # but semantically incomplete. Using 404 here would conflate
    # "no path supplied" with "no entity for that path".
    conn
    |> put_resp_content_type("application/problem+json")
    |> send_resp(
      422,
      Jason.encode!(%{
        type: "https://docs.immo.local/errors/unprocessable",
        title: "Unprocessable Entity",
        status: 422,
        detail: "missing or empty `path` query parameter"
      })
    )
    |> halt()
  end

  ## Resolve helpers

  # Look up a published listing scoped to its property_type. Returns
  # `{:ok, listing, property_type}` for a hit, `:error` for any
  # miss (unknown type_key, unpublished type, unknown slug, or
  # unpublished listing). The caller 404s on `:error` so the
  # response never leaks which axis failed.
  defp resolve_listing(type_key, slug) do
    with %PropertyType{} = pt <- Catalog.get_published_property_type_by_key(type_key),
         %Listing{} = listing <- Catalog.get_published_listing(pt.id, slug) do
      {:ok, listing, pt}
    else
      _ -> :error
    end
  end

  ## Record shapes (full-locale, single-record payloads)

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
      address: p.address,
      delivery_date: p.delivery_date,
      amenities: p.amenities || %{},
      seo: p.seo || %{},
      featured: !!p.featured,
      updated_at: p.updated_at,
      published_at: p.published_at,
      inserted_at: p.inserted_at
    }
  end

  defp shape_listing(l, pt) do
    %{
      id: l.id,
      slug: l.slug,
      paths: Edge.Paths.paths_for_all_locales(l),
      property_type: %{
        id: pt.id,
        key: pt.key,
        label: pt.label || %{},
        url_segment: pt.url_segment || %{}
      },
      project_id: l.project_id,
      title: l.title || %{},
      description: l.description || %{},
      price: l.price,
      price_on_request: !!l.price_on_request,
      currency: l.currency,
      status: l.status,
      address: l.address,
      city: l.city,
      region: l.region,
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
      contact: d.contact || %{},
      logo_media_id: d.logo_media_id,
      seo: d.seo || %{},
      updated_at: d.updated_at,
      published_at: d.published_at,
      inserted_at: d.inserted_at
    }
  end

  ## Embedded media

  defp embedded_media_for_project(%Project{id: id}) do
    "Project" |> Media.list_media_for(id) |> Enum.map(&shape_media/1)
  end

  defp embedded_media_for_listing(%Listing{id: id}) do
    "Listing" |> Media.list_media_for(id) |> Enum.map(&shape_media/1)
  end

  defp embedded_media_for_developer(%Developer{id: id}) do
    "Developer" |> Media.list_media_for(id) |> Enum.map(&shape_media/1)
  end

  # The §6.3 media shape: id, r2_key, blurhash, dimensions, alt.
  # The `position` is included so consumers can reorder if the
  # composite index drifts; the `kind` so the renderer can branch
  # (photo vs floorplan vs brochure).
  defp shape_media(m) do
    %{
      id: m.id,
      kind: m.kind,
      r2_key: m.r2_key,
      content_type: m.content_type,
      byte_size: m.byte_size,
      width: m.width,
      height: m.height,
      blurhash: m.blurhash,
      alt: m.alt || %{},
      position: m.position
    }
  end

  ## Summary embed helpers

  # Published-listings summary for a project (P1-E5.3 AC).
  # `recent` is the most-recently-updated slice so the SSR Worker
  # can build a "Units in this project" block without a second
  # round-trip; `count` is the full count for the badge.
  defp published_listings_summary(%Project{id: project_id}) do
    listings =
      Listing
      |> Catalog.published()
      |> where([r], r.project_id == ^project_id)
      |> Catalog.order_by_recent(:updated_at, 10)
      |> Immo.Repo.all()

    %{
      count: Enum.count(listings),
      recent: Enum.map(listings, &shape_listing_summary/1)
    }
  end

  # Published-projects summary for a developer.
  defp published_projects_summary(%Developer{id: developer_id}) do
    projects =
      Project
      |> Catalog.published()
      |> where([r], r.developer_id == ^developer_id)
      |> Catalog.order_by_recent(:updated_at, 10)
      |> Immo.Repo.all()

    %{
      count: Enum.count(projects),
      recent: Enum.map(projects, &shape_project_summary/1)
    }
  end

  # Minimal project summary for a listing's `project` embed (when
  # the listing belongs to a project). The full project is on
  # `/api/v1/projects/:slug`; this is just enough to render
  # "Belongs to <project>" / breadcrumbs / a link.
  defp project_summary_for_listing(%Listing{project_id: nil}), do: nil

  defp project_summary_for_listing(%Listing{project_id: project_id}) do
    case Project |> Catalog.published() |> Immo.Repo.get(project_id) do
      %Project{} = p -> shape_project_summary(p)
      _ -> nil
    end
  end

  defp shape_listing_summary(l) do
    %{
      id: l.id,
      slug: l.slug,
      title: l.title || %{},
      price: l.price,
      currency: l.currency,
      surface_m2: l.surface_m2,
      city: l.city,
      updated_at: l.updated_at,
      published_at: l.published_at
    }
  end

  defp shape_project_summary(p) do
    %{
      id: p.id,
      slug: p.slug,
      title: p.title || %{},
      city: p.city,
      status: p.status,
      featured: !!p.featured,
      updated_at: p.updated_at,
      published_at: p.published_at
    }
  end

  ## ETag (§6.3 — all build/render GETs)

  # The render endpoints emit a strong ETag from the record's
  # `updated_at`. This is the same primitive the build tier uses,
  # but derived from a single record rather than a page of records.
  defp respond_with_etag(conn, record, payload) do
    etag = strong_etag_for(record)

    conn =
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("etag", etag)

    if etag_matches?(conn, etag) do
      send_resp(conn, 304, "")
    else
      json(conn, payload)
    end
  end

  defp strong_etag_for(%{updated_at: %DateTime{} = ts}) do
    raw = DateTime.to_iso8601(ts)
    "\"#{:crypto.hash(:md5, raw) |> Base.encode16(case: :lower)}\""
  end

  defp etag_matches?(conn, etag) do
    case get_req_header(conn, "if-none-match") do
      [if_none_match | _] -> String.trim(if_none_match) == etag
      _ -> false
    end
  end
end
