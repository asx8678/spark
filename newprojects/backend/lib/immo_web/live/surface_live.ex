defmodule ImmoWeb.SurfaceLive do
  @moduledoc """
  Generic admin surface landing page used by the P1-E1.3 role-matrix
  acceptance suite.

  The real catalog/CRM/billing/admin/developer-own LiveViews land in
  P1-E3. This stub exists today so the role × surface integration
  tests have a real, mounted route per surface to assert against —
  without waiting for P1-E3 to ship its first CRUD surface.

  Each surface is mounted under its own URL prefix with a `live_session`
  whose `on_mount` hook is `{:require_surface, atom}` for that
  surface. The mount renders a small banner that names the surface
  and the resolved scope, so a test can `assert render =~ "catalog"`
  to confirm the hook actually let the request through. Denied roles
  are halted with a redirect to `/` by the on_mount hook before
  `mount/3` ever runs; the test asserts on the redirect.

  ## Why `handle_params/3` not `mount/3`

  Phoenix LiveView passes URL path params via `handle_params/3`, not
  `mount/3` — `mount/3` receives session params only. We read the
  `:surface` URL segment in `handle_params/3` and store it in
  `socket.assigns.surface`.

  ## Lifecycle

  This module is P1-E1.3 scaffolding. When P1-E3 lands the real
  `Catalog.Projects.Index` etc., each is mounted on its own path
  with the same `{:require_surface, atom}` hook — and this stub
  comes out. The integration test suite (`ImmoWeb.SurfaceRoleTest`)
  is the asset that survives: it asserts against whatever LiveView
  is mounted at `/admin/<surface>`, and is rewritten to point at
  the P1-E3 real routes when they land.
  """

  use ImmoWeb, :live_view

  alias Immo.Accounts.Scope

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    # The surface comes from the `live_session` session map (set in
    # the router's `session: %{"surface" => ...}`). This avoids
    # relying on path_params, which Phoenix LiveView 1.1 does not
    # surface to mount/3 or handle_params/3 by default.
    surface = session |> Map.get("surface", "") |> parse_surface!()

    {:ok,
     socket
     |> assign(:page_title, "Surface: #{surface}")
     |> assign(:scope, socket.assigns.current_scope)
     |> assign(:surface, surface)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@scope}>
      <.header>
        Surface: {@surface}
        <:subtitle>
          Role: {role(@scope)} — Tenant: {tenant(@scope)}
        </:subtitle>
      </.header>
    </Layouts.app>
    """
  end

  defp parse_surface!(surface)
       when surface in ~w(catalog crm billing_read billing_write admin_only developer_own),
       do: String.to_existing_atom(surface)

  defp parse_surface!(other), do: raise(ArgumentError, "unknown surface: #{inspect(other)}")

  defp role(%Scope{role: role}) when is_atom(role), do: role
  defp role(_), do: :anonymous

  defp tenant(%Scope{developer_id: id}) when is_binary(id), do: id
  defp tenant(_), do: "-"
end
