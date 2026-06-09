defmodule LSWeb.AdminAuth do
  @moduledoc """
  Authorization for the internal admin/monitoring panel.

  Access is restricted to the emails configured in `:ls, :admin_emails`
  (populated from the `LS_ADMIN_EMAILS` env var in `config/runtime.exs`).
  An empty allowlist denies everyone.
  """
  use LSWeb, :verified_routes

  import Plug.Conn, only: [halt: 1]
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  alias LS.Accounts.User

  @doc """
  LiveView `on_mount` hook for admin `live_session`s. Lets admins through,
  redirects everyone else to `/` with an error flash. Assumes a prior hook
  (e.g. `UserAuth.:require_authenticated`) has already assigned `current_scope`.
  """
  def on_mount(:require_admin, _params, _session, socket) do
    if admin?(current_user(socket.assigns[:current_scope])) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You are not authorized to view that page.")
        |> Phoenix.LiveView.redirect(to: ~p"/")

      {:halt, socket}
    end
  end

  @doc "Plug for controller-based admin routes — same allowlist as the LiveView hook."
  def require_admin(conn, _opts) do
    if admin?(current_user(conn.assigns[:current_scope])) do
      conn
    else
      conn
      |> put_flash(:error, "You are not authorized to view that page.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  @doc "True if the user's email is in the configured admin allowlist."
  def admin?(%User{email: email}) when is_binary(email) do
    String.downcase(email) in Application.get_env(:ls, :admin_emails, [])
  end

  def admin?(_), do: false

  defp current_user(%{user: user}), do: user
  defp current_user(_), do: nil
end
