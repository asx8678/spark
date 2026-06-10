defmodule ImmoWeb.UserAuth do
  @moduledoc """
  Auth pipeline + LiveView on_mount hooks + admin plug.

  ## Trust path (§10.1 path 5)

  The staff trust path is phx.gen.auth with argon2 — this module owns
  the auth plug that runs on every request through the browser pipeline
  (and the admin pipeline variant) and the LiveView `on_mount` hooks
  that gate staff surfaces.

  ## Role-based predicates (§6.2)

  The four staff role predicates — `Scope.admin?/manager?/editor?/
  developer_user?/1` — are the building blocks. The matrix in
  `Scope.can_access?/2` resolves a surface group against a scope; the
  on_mount hook `{:require_surface, atom}` enforces the matrix at
  LiveView mount, and the `require_role/1` and `require_surface/1`
  plugs do the same for controller routes.

  ## 24 h session idle timeout (§13)

  The session middleware touches `last_seen_at` on every authenticated
  request, and the verify query drops sessions whose `last_seen_at` is
  older than the configured window (default 24 h). The window is
  overridable via `:immo, :session_idle_timeout_in_seconds` in config
  (compile-time).
  """

  use ImmoWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Immo.Accounts
  alias Immo.Accounts.Scope

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_immo_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  # §13 staff security checklist: 24 h admin session idle timeout.
  # Exposed as a runtime compile-time overrideable attribute so tests and
  # maintenance windows can shorten or lengthen the window without
  # touching source. Default is 24 hours.
  @session_idle_timeout_in_seconds Application.compile_env(
                                     :immo,
                                     :session_idle_timeout_in_seconds,
                                     24 * 60 * 60
                                   )

  @doc "The configured session idle timeout, in seconds. Used by `UserToken`."
  def session_idle_timeout_in_seconds, do: @session_idle_timeout_in_seconds

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      ImmoWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age,
  and will touch `last_seen_at` so the §13 24 h idle window resets on
  every authenticated request.
  """
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      # Reset the idle clock on every authenticated request. The verify
      # query drops a session whose `last_seen_at` is older than the
      # configured idle timeout (default 24 h, §13), so a session that
      # has not been touched will be invalidated on the very next request
      # after the timeout window.
      Accounts.touch_user_session_token(token)

      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) when conn.assigns.current_scope.user.id == user.id do
    conn
  end

  # This function renews the session ID and erases the whole
  # session to avoid fixation attacks. If there is any data
  # in the session you may want to preserve after log in/log out,
  # you must explicitly fetch the session data before clearing
  # and then immediately set it after clearing, for example:
  #
  #     defp renew_session(conn, _user) do
  #       delete_csrf_token()
  #       preferred_locale = get_session(conn, :preferred_locale)
  #
  #       conn
  #       |> configure_session(renew: true)
  #       |> clear_session()
  #       |> put_session(:preferred_locale, preferred_locale)
  #     end
  #
  defp renew_session(conn, _user) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      ImmoWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope to socket assigns based
      on user_token, or nil if there's no user_token or no matching user.

    * `:require_authenticated` - Redirects to login page if no logged user.

    * `:require_sudo_mode` - Requires the user to have re-authenticated in
      the last 10 minutes (sudo mode).

    * `:require_admin`, `:require_manager`, `:require_editor`,
      `:require_any_staff` - P1-E1.1 role predicates. Kept for backward
      compatibility and for surfaces that genuinely are role-only (e.g.
      the admin-only audit log viewer). New code should prefer
      `{:require_surface, :atom}` (below).

    * `{:require_surface, surface}` - P1-E1.2 surface-group gate. Resolves
      the §6.2 role-to-surface matrix in `Immo.Accounts.Scope.can_access?/2`.
      Use this for new LiveViews:

          live_session :admin_catalog,
            on_mount: [{ImmoWeb.UserAuth, {:require_surface, :catalog}}] do
            live "/catalog/projects", ProjectLive.Index, :index
          end

      The matrix is encoded exactly once in `Scope.can_access?/2`; the
      hook here just enforces it for mount.
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:require_sudo_mode, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if Accounts.sudo_mode?(socket.assigns.current_scope.user, -10) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must re-authenticate to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:require_admin, params, session, socket),
    do: on_mount_require_role(:admin, params, session, socket)

  def on_mount(:require_manager, params, session, socket),
    do: on_mount_require_role(:manager, params, session, socket)

  def on_mount(:require_editor, params, session, socket),
    do: on_mount_require_role(:editor, params, session, socket)

  def on_mount(:require_any_staff, params, session, socket),
    do: on_mount_require_role(:any_staff, params, session, socket)

  # Surface-group gate (P1-E1.2). The second element of the on_mount tuple
  # is the surface atom; the matrix resolution lives in `Scope.can_access?/2`
  # and is the single source of truth.
  def on_mount({:require_surface, surface}, _params, session, socket)
      when surface in [:catalog, :crm, :billing_read, :billing_write, :admin_only, :developer_own] do
    socket = mount_current_scope(socket, session)
    scope = socket.assigns.current_scope

    cond do
      is_nil(scope) or is_nil(scope.user) ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
         |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")}

      not Scope.can_access?(scope, surface) ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "You are not authorized to view this page.")
         |> Phoenix.LiveView.redirect(to: ~p"/")}

      true ->
        {:cont, socket}
    end
  end

  defp on_mount_require_role(required, _params, session, socket) do
    socket = mount_current_scope(socket, session)
    scope = socket.assigns.current_scope

    cond do
      is_nil(scope) or is_nil(scope.user) ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
         |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")}

      not role_authorized?(required, scope.role) ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "You are not authorized to view this page.")
         |> Phoenix.LiveView.redirect(to: ~p"/")}

      true ->
        {:cont, socket}
    end
  end

  # Hierarchy per §6.2: admin is a superset of manager, which is a superset
  # of editor. A `developer_user` is tenant-bounded and is NOT authorized
  # for any staff-only screen; their access is filtered to their own data
  # (handled by the `developer_user` flow that lands in P1-E3).
  defp role_authorized?(:admin, _role), do: true
  defp role_authorized?(:manager, role) when role in [:admin, :manager], do: true
  defp role_authorized?(:editor, role) when role in [:admin, :manager, :editor], do: true
  defp role_authorized?(:any_staff, role) when role in [:admin, :manager, :editor], do: true
  defp role_authorized?(_, _), do: false

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      {user, _} =
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end || {nil, nil}

      Scope.for_user(user)
    end)
  end

  @doc "Returns the path to redirect to after log in."
  # the user was already logged in, redirect to the admin landing.
  def signed_in_path(%Plug.Conn{assigns: %{current_scope: %Scope{user: %Accounts.User{}}}}) do
    ~p"/admin"
  end

  def signed_in_path(_), do: ~p"/"

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  @doc """
  Plug for routes that require a specific staff role (or any of a hierarchy
  of roles). Same authorization matrix as the on_mount variants. Failure
  yields a 403-flash + redirect to `/` rather than the login page, because
  the caller is authenticated — they just lack the privilege.
  """
  def require_role(required) when required in [:admin, :manager, :editor, :any_staff] do
    fn conn, _opts ->
      scope = conn.assigns[:current_scope]

      if scope && scope.user && role_authorized?(required, scope.role) do
        conn
      else
        conn
        |> put_flash(:error, "You are not authorized to view this page.")
        |> redirect(to: ~p"/")
        |> halt()
      end
    end
  end

  @doc """
  Plug for routes gated by a surface group (P1-E1.2). Resolves the §6.2
  role-to-surface matrix via `Scope.can_access?/2`. For new code, prefer
  the surface-level plug over the role-level one — the role matrix can
  change without churning every routes call site.
  """
  def require_surface(surface)
      when surface in [:catalog, :crm, :billing_read, :billing_write, :admin_only, :developer_own] do
    fn conn, _opts ->
      scope = conn.assigns[:current_scope]

      if scope && scope.user && Scope.can_access?(scope, surface) do
        conn
      else
        conn
        |> put_flash(:error, "You are not authorized to view this page.")
        |> redirect(to: ~p"/")
        |> halt()
      end
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
