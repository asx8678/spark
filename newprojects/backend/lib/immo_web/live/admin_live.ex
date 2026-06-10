defmodule ImmoWeb.AdminLive do
  use ImmoWeb, :live_view

  alias Immo.Accounts.Scope

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:scope, scope)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@scope}>
      <.header>
        Admin
        <:subtitle>Signed in as {user_email(@scope)} — role {@scope.role}</:subtitle>
      </.header>

      <p class="mt-6 text-sm opacity-70">
        Admin surfaces (catalog CRUD, CRM, billing, build dashboard) land in
        P1-E3 / P3-E2. This landing page is the entry point protected by the
        staff RBAC pipeline.
      </p>
    </Layouts.app>
    """
  end

  defp user_email(%Scope{user: %{email: email}}) when is_binary(email), do: email
  defp user_email(_), do: "unknown"
end
