defmodule LSWeb.UserLive.Registration do
  use LSWeb, :live_view

  alias LS.Accounts
  alias LS.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#0a0e17] flex items-center justify-center px-4">
      <div class="w-full max-w-sm">
        <div class="text-center mb-8">
          <span class="text-emerald-400 font-bold text-3xl">LS</span>
          <h1 class="text-xl font-semibold text-white mt-2">Create your account</h1>
          <p class="text-gray-400 text-sm mt-1">
            Already registered?
            <.link navigate={~p"/users/log-in"} class="text-emerald-400 hover:underline">Log in</.link>
          </p>
        </div>

        <div class="bg-[#111B33] border border-white/[0.07] rounded-lg p-6">
          <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
            <div class="space-y-4">
              <div>
                <label class="block text-sm text-gray-400 mb-1">Email</label>
                <input type="email" name={@form[:email].name} value={@form[:email].value}
                  class="w-full bg-[#0a0e17] border border-white/[0.07] rounded px-3 py-2 text-sm text-white focus:border-emerald-500 focus:outline-none"
                  autocomplete="username" spellcheck="false" required phx-mounted={Phoenix.LiveView.JS.focus()} />
                <%= for error <- @form[:email].errors do %>
                  <p class="text-red-400 text-xs mt-1"><%= translate_error(error) %></p>
                <% end %>
              </div>
              <button type="submit" class="w-full bg-emerald-600 hover:bg-emerald-500 text-white rounded px-4 py-2 text-sm font-medium transition">
                Create account
              </button>
            </div>
          </.form>
        </div>

        <p class="text-center text-xs text-gray-500 mt-4">
          Free plan included. No credit card required.
        </p>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: LSWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)
    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(:info, "Check your email for a login link.")
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, form: to_form(changeset, as: "user"))
  end
end
