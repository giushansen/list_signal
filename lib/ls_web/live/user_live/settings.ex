defmodule LSWeb.UserLive.Settings do
  use LSWeb, :live_view

  on_mount {LSWeb.UserAuth, :require_sudo_mode}

  alias LS.Accounts
  alias LS.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#0a0e17] text-gray-200">
      <header class="border-b border-white/[0.07] bg-[#111B33] px-4 py-3">
        <div class="max-w-2xl mx-auto flex items-center justify-between">
          <div class="flex items-center gap-3">
            <.link navigate={~p"/app"} class="text-emerald-400 font-bold text-xl hover:text-emerald-300">LS</.link>
            <span class="text-white font-semibold">Account Settings</span>
          </div>
          <.link navigate={~p"/app"} class="text-gray-400 hover:text-white text-sm">Back to Explorer</.link>
        </div>
      </header>

      <div class="max-w-2xl mx-auto px-4 py-8 space-y-8">
        <!-- Plan & Billing -->
        <div class="bg-[#111B33] border border-white/[0.07] rounded-lg p-6">
          <h2 class="text-lg font-semibold text-white mb-4">Plan & Billing</h2>
          <div class="flex items-center gap-3 mb-4">
            <span class={"px-3 py-1 rounded text-sm font-medium #{plan_badge_class(@plan)}"}>
              <%= String.capitalize(@plan) %> Plan
            </span>
          </div>
          <div class="text-sm text-gray-400 space-y-1 mb-4">
            <p>Exports: <%= @exports_remaining %> remaining this month</p>
            <p>Results per page: <%= @per_page %></p>
          </div>
          <%= if User.subscribed?(@current_scope.user) do %>
            <form action={~p"/subscription/portal"} method="post">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <button type="submit" class="bg-[#0a0e17] border border-white/[0.07] hover:bg-white/[0.05] text-white rounded px-4 py-2 text-sm">
                Manage Subscription
              </button>
            </form>
          <% else %>
            <form action={~p"/subscription/checkout/pro/monthly"} method="post">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <button type="submit" class="w-full bg-emerald-600 hover:bg-emerald-500 text-white rounded px-4 py-2 text-sm">
                Upgrade to Pro — $49/mo
              </button>
            </form>
          <% end %>
        </div>

        <!-- Email -->
        <div class="bg-[#111B33] border border-white/[0.07] rounded-lg p-6">
          <h2 class="text-lg font-semibold text-white mb-4">Email Address</h2>
          <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
            <div class="space-y-3">
              <input type="email" name={@email_form[:email].name} value={@email_form[:email].value}
                class="w-full bg-[#0a0e17] border border-white/[0.07] rounded px-3 py-2 text-sm text-white focus:border-emerald-500 focus:outline-none"
                autocomplete="username" spellcheck="false" required />
              <%= for error <- @email_form[:email].errors do %>
                <p class="text-red-400 text-sm"><%= translate_error(error) %></p>
              <% end %>
              <button type="submit" class="bg-emerald-600 hover:bg-emerald-500 text-white rounded px-4 py-2 text-sm">
                Change Email
              </button>
            </div>
          </.form>
        </div>

        <!-- Password -->
        <div class="bg-[#111B33] border border-white/[0.07] rounded-lg p-6">
          <h2 class="text-lg font-semibold text-white mb-4">Password</h2>
          <.form
            for={@password_form}
            id="password_form"
            action={~p"/users/update-password"}
            method="post"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
          >
            <input name={@password_form[:email].name} type="hidden" value={@current_email} />
            <div class="space-y-3">
              <div>
                <label class="block text-sm text-gray-400 mb-1">New password</label>
                <input type="password" name={@password_form[:password].name}
                  class="w-full bg-[#0a0e17] border border-white/[0.07] rounded px-3 py-2 text-sm text-white focus:border-emerald-500 focus:outline-none"
                  autocomplete="new-password" spellcheck="false" required />
                <%= for error <- @password_form[:password].errors do %>
                  <p class="text-red-400 text-sm mt-1"><%= translate_error(error) %></p>
                <% end %>
              </div>
              <div>
                <label class="block text-sm text-gray-400 mb-1">Confirm password</label>
                <input type="password" name={@password_form[:password_confirmation].name}
                  class="w-full bg-[#0a0e17] border border-white/[0.07] rounded px-3 py-2 text-sm text-white focus:border-emerald-500 focus:outline-none"
                  autocomplete="new-password" spellcheck="false" />
                <%= for error <- @password_form[:password_confirmation].errors do %>
                  <p class="text-red-400 text-sm mt-1"><%= translate_error(error) %></p>
                <% end %>
              </div>
              <button type="submit" class="bg-emerald-600 hover:bg-emerald-500 text-white rounded px-4 py-2 text-sm">
                Save Password
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    plan = User.effective_plan(user)
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:plan, plan)
      |> assign(:exports_remaining, Accounts.exports_remaining(user))
      |> assign(:per_page, Accounts.results_per_page(user))
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  defp plan_badge_class("pro"), do: "bg-emerald-500/20 text-emerald-400"
  defp plan_badge_class(_), do: "bg-gray-500/20 text-gray-400"
end
