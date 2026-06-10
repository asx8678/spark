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
end
