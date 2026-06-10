defmodule ImmoWeb.Router do
  use ImmoWeb, :router

  import ImmoWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ImmoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # §6.4 — machine-token auth tiers for /api/v1. Three pipelines:
  #   :api_build   — BearerAuth :build, full paginated dumps
  #   :api_render  — BearerAuth :render, single-record reads
  #   :api_public  — CORS + Hammer rate limit (P1-E5.4), no auth
  # Scopes are disjoint: a render token never authenticates on a
  # build endpoint, and vice versa. The plug's init/1 fixes the
  # scope from the pipeline, never infers it from the token.
  pipeline :api_build do
    plug :accepts, ["json"]
    plug ImmoWeb.Plugs.BearerAuth, :build
  end

  pipeline :api_render do
    plug :accepts, ["json"]
    plug ImmoWeb.Plugs.BearerAuth, :render
  end

  pipeline :api_public do
    plug :accepts, ["json"]
    # CORS + Hammer rate-limit plug live in P1-E5.4.
  end

  # §6.2 admin: every route under /admin requires the user to be
  # authenticated. Per-surface role gating is layered on top via
  # `live_session :on_mount` and the `require_role/1` plug.
  pipeline :admin_browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ImmoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug :require_authenticated_user
  end

  scope "/", ImmoWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:immo, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set it up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ImmoWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", ImmoWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{ImmoWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", ImmoWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{ImmoWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  ## Admin (LiveView) — §6.2

  # P1-E1.1 delivers the auth/RBAC substrate. P1-E1.3 adds the
  # per-surface routes (P1-E1.3 acceptance suite uses them to
  # assert the role×surface matrix end-to-end). The real admin
  # CRUD surfaces (catalog/CRM/billing/builds) are P1-E3 / P3-E2.

  scope "/admin", ImmoWeb do
    pipe_through [:admin_browser]

    # The admin landing — visible to any signed-in staff member.
    live_session :admin_landing,
      on_mount: [{ImmoWeb.UserAuth, :require_any_staff}] do
      live "/", AdminLive, :index
    end

    # Per-surface stub routes. P1-E1.3 mounts `ImmoWeb.SurfaceLive` at
    # a single path with a `:surface` URL param so the same LiveView
    # can render whichever surface the live_session is gated for.
    # The on_mount hook is the surface-specific gate. The URL
    # surface segment is also projected into the LiveView session so
    # handle_params/3 (Phoenix LiveView 1.1 does not surface
    # path_params to handle_params) can read it.
    for surface <- Immo.Accounts.Scope.surfaces() do
      live_session :"admin_#{surface}",
        on_mount: [{ImmoWeb.UserAuth, {:require_surface, surface}}],
        session: %{"surface" => Atom.to_string(surface)} do
        live "/surface/#{surface}", SurfaceLive, :index
      end
    end
  end

  # §6.4 / §6.3 — /api/v1 read API. The three pipelines are wired
  # here so the auth + CORS + rate-limit surface is in place from
  # P1-E5.1; the actual endpoints land in P1-E5.2 (build),
  # P1-E5.3 (render), and P1-E5.4 (public).
  #
  # Each tier gets a /__smoke route mounted on its own controller
  # so the AC (auth tiers, rotation, scope disjointness) is
  # testable end-to-end without the real endpoints being in place.
  # The smoke route names are reserved for the test suite.
  scope "/api/v1", ImmoWeb.Api, as: :api_v1 do
    pipe_through :api_build
    get "/__smoke/build", IndexController, :index
    # §6.3 build-tier list endpoints
    get "/projects", BuildController, :projects
    get "/listings", BuildController, :listings
    get "/developers", BuildController, :developers
    get "/property_types", BuildController, :property_types
    get "/meta/sitemap", BuildController, :sitemap
    get "/redirects", BuildController, :redirects
  end

  scope "/api/v1", ImmoWeb.Api, as: :api_v1 do
    pipe_through :api_render
    get "/__smoke/render", IndexController, :index

    # §6.3 — render tier single-record reads (RENDER_TOKEN,
    # §10.1 path 2). P1-E5.3.
    get "/projects/:slug", RenderController, :project
    get "/listings/:type_key/:slug", RenderController, :listing
    get "/developers/:slug", RenderController, :developer
    get "/internal/freshness", RenderController, :freshness
  end

  scope "/api/v1", ImmoWeb.Api, as: :api_v1 do
    pipe_through :api_public
    get "/__smoke/public", IndexController, :index
  end
end
