defmodule ImmoWeb.ApiSpec do
  @moduledoc """
  §6.3 / P1-E5.5 — the `open_api_spex` source of truth for `/api/v1`.

  The spec is the **single** place that the wire contract lives
  for the read API. Every controller action advertises an
  `open_api_spex` operation (via the controller-level plug +
  `open_api_operation` macro); the spec here declares the
  reusable components (security schemes, problem+json error
  schema, list envelope, record shapes). The generated JSON
  file lands at `priv/static/openapi.json` and is consumed by
  the frontend codegen (P2-E2) and the §16 release-gate
  "spec drift fails CI" check.

  ## Why a module-level spec, not per-controller

  OpenAPI lets you split the spec across modules and merge
  them at export time, but for a single bounded API surface
  (the read API — 9 routes today, none more likely) one
  module keeps the diff reviewable and the generation
  command simple. The controller-level operation macros
  reference the component schemas declared here by name.

  ## Versioning

  Additive fields are non-breaking by contract (§6.3). Any
  breaking change (removing a field, renaming a property,
  tightening a status code) lands in `/api/v2` — not here.

  ## Curl consumer

  The companion `docs/api-curl-matrix.md` shows the
  per-tier × per-state matrix the spec describes. The
  spec is the source; the doc is the executable
  documentation.
  """

  alias OpenApiSpex.{
    Components,
    Info,
    MediaType,
    OpenApi,
    Operation,
    Parameter,
    PathItem,
    Response,
    Schema,
    SecurityScheme,
    Server
  }

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [
        # §6.3 — the API is served from the same host as the
        # site (api.<domain> per §10.1 path 1/2) for build/render
        # tokens. The dev default is localhost.
        %Server{url: "http://localhost:4000", description: "Local development"},
        %Server{url: "https://api.immo.local", description: "Staging"}
      ],
      info: %Info{
        title: "Immo Real-Estate Platform — Read API",
        version: "1.0.0",
        description: """
        §6.3 / §10.1 — the `/api/v1` read API for the Immo
        platform. Three auth tiers (`build` = BUILD_TOKEN,
        `render` = RENDER_TOKEN, `public` = anonymous). The
        build and render tiers are *disjoint* — a render
        token is rejected on a build endpoint and vice versa.
        Errors are RFC 9457 `application/problem+json`.
        """
      },
      components: %Components{
        securitySchemes: %{
          "build_bearer" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description:
              "BUILD_TOKEN (§10.1 path 1). Build-tier read API for the " <>
                "scheduled build's content loaders. Comma-separated " <>
                "set accepted for zero-downtime rotation."
          },
          "render_bearer" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description:
              "RENDER_TOKEN (§10.1 path 2). Render-tier read API for the " <>
                "Worker SSR's single-record lookups + freshness check."
          }
        },
        schemas: schemas()
      },
      paths: paths_map()
    }
  end

  ## Path catalogue
  ##
  ## The build + render + public operations are declared in
  ## the controllers themselves (`open_api_operation` macro)
  ## so the controller stays the single source for an action's
  ## contract. The Paths map here references those operations
  ## by pointer (`$ref` to the operation id) — open_api_spex
  ## does the merge at export time.

  defp paths_map do
    %{
      "/projects" => %PathItem{
        get: %Operation{
          operationId: "BuildController.projects",
          tags: ["build"],
          summary: "List published projects",
          description:
            "Full publishable dump of all projects. Cursor-paginated; " <>
              "`since` powers incremental loader sync. All queries " <>
              "compose `Catalog.published/1` so draft, future-published, " <>
              "and billing-gated records are absent.",
          security: [%{"build_bearer" => []}],
          parameters: list_query_params(),
          responses: list_responses()
        }
      },
      "/listings" => %PathItem{
        get: %Operation{
          operationId: "BuildController.listings",
          tags: ["build"],
          summary: "List published listings",
          security: [%{"build_bearer" => []}],
          parameters: list_query_params(),
          responses: list_responses()
        }
      },
      "/developers" => %PathItem{
        get: %Operation{
          operationId: "BuildController.developers",
          tags: ["build"],
          summary: "List published developers",
          security: [%{"build_bearer" => []}],
          parameters: list_query_params(),
          responses: list_responses()
        }
      },
      "/property_types" => %PathItem{
        get: %Operation{
          operationId: "BuildController.property_types",
          tags: ["build"],
          summary: "List all property types",
          description:
            "Every row is considered published (PropertyType has no " <>
              "`published_at` field). Each record carries `filter_config` " <>
              "(merged with searchable custom fields) and `url_segment` " <>
              "(per-locale).",
          security: [%{"build_bearer" => []}],
          parameters: list_query_params(),
          responses: list_responses()
        }
      },
      "/meta/sitemap" => %PathItem{
        get: %Operation{
          operationId: "BuildController.sitemap",
          tags: ["build"],
          summary: "Sitemap entries: all public paths + lastmod + locale alternates",
          security: [%{"build_bearer" => []}],
          responses: list_responses()
        }
      },
      "/redirects" => %PathItem{
        get: %Operation{
          operationId: "BuildController.redirects",
          tags: ["build"],
          summary: "Active redirects (old_path, new_path, http_status)",
          security: [%{"build_bearer" => []}],
          responses: list_responses()
        }
      },

      # Render tier — single records (§6.3 row 1-2, freshness)
      "/projects/{slug}" => %PathItem{
        get: %Operation{
          operationId: "RenderController.project",
          tags: ["render"],
          summary: "Single published project (all locales, embedded media, listings summary)",
          security: [%{"render_bearer" => []}],
          parameters: [
            %Parameter{
              name: :slug,
              in: :path,
              required: true,
              schema: %Schema{type: :string},
              description: "Project slug"
            }
          ],
          responses: single_record_responses()
        }
      },
      "/developers/{slug}" => %PathItem{
        get: %Operation{
          operationId: "RenderController.developer",
          tags: ["render"],
          summary: "Single published developer (all locales, embedded media, projects summary)",
          security: [%{"render_bearer" => []}],
          parameters: [
            %Parameter{
              name: :slug,
              in: :path,
              required: true,
              schema: %Schema{type: :string}
            }
          ],
          responses: single_record_responses()
        }
      },
      "/listings/{type_key}/{slug}" => %PathItem{
        get: %Operation{
          operationId: "RenderController.listing",
          tags: ["render"],
          summary: "Single published listing (all locales, embedded media, project summary)",
          security: [%{"render_bearer" => []}],
          parameters: [
            %Parameter{
              name: :type_key,
              in: :path,
              required: true,
              schema: %Schema{type: :string}
            },
            %Parameter{
              name: :slug,
              in: :path,
              required: true,
              schema: %Schema{type: :string}
            }
          ],
          responses: single_record_responses()
        }
      },
      "/internal/freshness" => %PathItem{
        get: %Operation{
          operationId: "RenderController.freshness",
          tags: ["render"],
          summary:
            "Freshness check for a public path — returns `updated_at` " <>
              "or 404. Documented §3.5 KV-alternative; implemented, " <>
              "unused by default.",
          security: [%{"render_bearer" => []}],
          parameters: [
            %Parameter{
              name: :path,
              in: :query,
              required: true,
              schema: %Schema{type: :string},
              description: "Public path (e.g. `/projets/casablanca/le-jardin`)"
            }
          ],
          responses: single_record_responses()
        }
      }
    }
  end

  ## Reusable parameters

  defp list_query_params do
    [
      %Parameter{
        name: :cursor,
        in: :query,
        required: false,
        schema: %Schema{type: :string},
        description: "Opaque keyset cursor (base64-encoded id)"
      },
      %Parameter{
        name: :limit,
        in: :query,
        required: false,
        schema: %Schema{type: :integer, maximum: 100, default: 50},
        description: "Page size, clamped at 100"
      },
      %Parameter{
        name: :since,
        in: :query,
        required: false,
        schema: %Schema{type: :string, format: :"date-time"},
        description: "ISO-8601 timestamp; only records with `updated_at > since`"
      }
    ]
  end

  ## Reusable response shapes

  defp list_responses do
    %{
      200 => %Response{
        description: "OK — `{data: [...], meta: {next_cursor, count}}`",
        content: %{"application/json" => %MediaType{schema: list_envelope_schema()}}
      },
      304 => %Response{description: "ETag match — empty body"},
      401 => problem_response("Unauthorized (build token missing or wrong tier)"),
      500 => problem_response("Server error")
    }
  end

  defp single_record_responses do
    %{
      200 => %Response{description: "OK — `{data: {record, ...}}`"},
      304 => %Response{description: "ETag match — empty body"},
      401 => problem_response("Unauthorized"),
      404 => problem_response("Not found (or not published)"),
      422 => problem_response("Unprocessable (e.g. missing `path` on freshness)"),
      500 => problem_response("Server error")
    }
  end

  defp problem_response(description) do
    %Response{
      description: description,
      content: %{
        "application/problem+json" => %MediaType{
          schema: %OpenApiSpex.Reference{"$ref": "#/components/schemas/ProblemJson"}
        }
      }
    }
  end

  ## Schemas

  # `{data: [...], meta: {next_cursor, count}}` — the §6.3 list
  # envelope every build-tier list endpoint returns. The `data`
  # array is generic — the actual record shape is documented at
  # the operation level (per-endpoint). The `meta.next_cursor` is
  # an opaque base64-encoded id (or nil on the final page).
  defp list_envelope_schema do
    %Schema{
      title: "ListEnvelope",
      type: :object,
      required: [:data, :meta],
      properties: %{
        data: %Schema{
          type: :array,
          items: %Schema{type: :object, additionalProperties: true}
        },
        meta: %Schema{
          type: :object,
          required: [:count, :next_cursor],
          properties: %{
            count: %Schema{type: :integer, minimum: 0},
            next_cursor: %Schema{
              type: :string,
              nullable: true,
              description: "Opaque cursor for the next page, or `null` on the final page"
            }
          }
        }
      }
    }
  end

  # RFC 9457 — every /api/v1 error returns a `ProblemJson`
  # body with `application/problem+json` content-type. The
  # Phoenix `ErrorJSON` fallback is wired to emit this shape;
  # controllers' `FallbackController.not_found/1` does too.
  defp schemas do
    %{
      "ProblemJson" => %Schema{
        title: "ProblemJson",
        description: "RFC 9457 — `application/problem+json`",
        type: :object,
        required: [:type, :title, :status],
        properties: %{
          type: %Schema{type: :string, format: :uri},
          title: %Schema{type: :string},
          status: %Schema{type: :integer},
          detail: %Schema{type: :string, nullable: true},
          instance: %Schema{type: :string, nullable: true}
        }
      },
      "ListEnvelope" => list_envelope_schema()
    }
  end
end
