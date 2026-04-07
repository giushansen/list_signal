defmodule LSWeb.UserLive.Settings do
  use LSWeb, :live_view

  on_mount {LSWeb.UserAuth, :require_sudo_mode}

  alias LS.Accounts
  alias LS.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#0B0F19] text-gray-200 font-['Inter',system-ui,sans-serif]">
      <%!-- Same header as Dashboard --%>
      <header class="border-b border-white/[0.06] bg-[#0F1628]">
        <div class="max-w-[1700px] mx-auto px-5 py-3.5 flex items-center justify-between">
          <.link navigate={~p"/app"} class="flex items-center gap-3 hover:opacity-80 transition">
            <div class="flex h-8 w-8 items-center justify-center rounded-lg bg-emerald-500 text-xs font-extrabold text-white">LS</div>
            <span class="text-white font-semibold text-[15px] tracking-tight">Settings</span>
          </.link>
          <div class="flex items-center gap-4 text-sm">
            <.link navigate={~p"/app"} class="text-gray-500 hover:text-white transition text-sm">Dashboard</.link>
            <.link href={~p"/users/log-out"} method="delete" class="text-gray-500 hover:text-white transition text-sm">Log out</.link>
          </div>
        </div>
      </header>

      <div class="max-w-3xl mx-auto px-5 py-8 space-y-8">
        <%!-- Plan & Billing — comparison table --%>
        <div class="bg-[#0F1628] border border-white/[0.06] rounded-xl p-6">
          <h2 class="text-lg font-semibold text-white mb-2">Plan & Billing</h2>
          <p class="text-sm text-gray-500 mb-6">You are currently on the <span class={"font-semibold #{if @plan == "pro", do: "text-emerald-400", else: "text-amber-400"}"}><%= String.capitalize(@plan) %></span> plan.</p>

          <div class="grid grid-cols-2 gap-4 mb-6">
            <%!-- Free column --%>
            <div class={"rounded-xl border p-5 #{if @plan != "pro", do: "border-amber-500/30 bg-amber-500/[0.03] ring-1 ring-amber-500/20", else: "border-white/[0.06] bg-[#0B1020]"}"}>
              <div class="flex items-center justify-between mb-3">
                <h3 class="text-sm font-bold text-white">Free</h3>
                <%= if @plan != "pro" do %>
                  <span class="px-2 py-0.5 rounded-full text-[10px] font-bold uppercase bg-amber-500/15 text-amber-400">Current</span>
                <% end %>
              </div>
              <p class="text-2xl font-bold text-white mb-4">$0<span class="text-sm text-gray-500 font-normal">/mo</span></p>
              <ul class="text-sm text-gray-400 space-y-2.5">
                <li class="flex items-center gap-2"><span class="text-gray-600">&#10003;</span> 100 CSV exports/mo</li>
                <li class="flex items-center gap-2"><span class="text-gray-600">&#10003;</span> 25 results per page</li>
                <li class="flex items-center gap-2"><span class="text-gray-600">&#10003;</span> 10 requests/min</li>
                <li class="flex items-center gap-2"><span class="text-gray-600">&#10003;</span> Basic data access</li>
              </ul>
            </div>

            <%!-- Pro column --%>
            <div class={"rounded-xl border p-5 #{if @plan == "pro", do: "border-emerald-500/30 bg-emerald-500/[0.03] ring-1 ring-emerald-500/20", else: "border-white/[0.06] bg-[#0B1020]"}"}>
              <div class="flex items-center justify-between mb-3">
                <h3 class="text-sm font-bold text-emerald-400">Pro</h3>
                <%= if @plan == "pro" do %>
                  <span class="px-2 py-0.5 rounded-full text-[10px] font-bold uppercase bg-emerald-500/15 text-emerald-400">Current</span>
                <% end %>
              </div>
              <p class="text-2xl font-bold text-white mb-4">$49<span class="text-sm text-gray-500 font-normal">/mo</span></p>
              <ul class="text-sm text-gray-300 space-y-2.5">
                <li class="flex items-center gap-2"><span class="text-emerald-500">&#10003;</span> <strong>5,000</strong> CSV exports/mo</li>
                <li class="flex items-center gap-2"><span class="text-emerald-500">&#10003;</span> <strong>100</strong> results per page</li>
                <li class="flex items-center gap-2"><span class="text-emerald-500">&#10003;</span> <strong>60</strong> requests/min</li>
                <li class="flex items-center gap-2"><span class="text-emerald-500">&#10003;</span> Full data access</li>
              </ul>
            </div>
          </div>

          <%!-- Usage stats --%>
          <div class="bg-[#0B1020] rounded-lg p-4 mb-5">
            <h4 class="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-3">Your Usage This Month</h4>
            <div class="grid grid-cols-2 gap-4 text-sm">
              <div>
                <span class="text-gray-500">Exports remaining</span>
                <p class="text-white font-semibold"><%= @exports_remaining %> <span class="text-gray-600 font-normal">/ <%= @export_limit %></span></p>
              </div>
              <div>
                <span class="text-gray-500">Results per page</span>
                <p class="text-white font-semibold"><%= @per_page %></p>
              </div>
              <div>
                <span class="text-gray-500">Rate limit</span>
                <p class="text-white font-semibold"><%= @rate_limit %> <span class="text-gray-600 font-normal">req/min</span></p>
              </div>
            </div>
          </div>

          <%= if User.subscribed?(@current_scope.user) do %>
            <form action={~p"/subscription/portal"} method="post">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <button type="submit" class="bg-[#0B1020] border border-white/[0.06] hover:bg-white/[0.05] text-white rounded-lg px-4 py-2.5 text-sm font-medium transition">
                Manage Subscription
              </button>
            </form>
          <% else %>
            <form action={~p"/subscription/checkout/pro/monthly"} method="post">
              <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
              <button type="submit" class="w-full bg-emerald-600 hover:bg-emerald-500 text-white rounded-lg px-4 py-2.5 text-sm font-semibold shadow-lg shadow-emerald-500/20 transition">
                Upgrade to Pro — $49/mo
              </button>
            </form>
          <% end %>
        </div>

        <%!-- Email --%>
        <div class="bg-[#0F1628] border border-white/[0.06] rounded-xl p-6">
          <h2 class="text-lg font-semibold text-white mb-4">Email Address</h2>
          <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
            <div class="space-y-3">
              <input type="email" name={@email_form[:email].name} value={@email_form[:email].value}
                class="w-full bg-[#0B1020] border border-white/[0.06] rounded-lg px-3 py-2.5 text-sm text-white focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/20 focus:outline-none transition"
                autocomplete="username" spellcheck="false" required />
              <%= for error <- @email_form[:email].errors do %>
                <p class="text-red-400 text-sm"><%= translate_error(error) %></p>
              <% end %>
              <button type="submit" class="bg-emerald-600 hover:bg-emerald-500 text-white rounded-lg px-4 py-2.5 text-sm font-semibold transition">
                Change Email
              </button>
            </div>
          </.form>
        </div>

        <%!-- Password --%>
        <div class="bg-[#0F1628] border border-white/[0.06] rounded-xl p-6">
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
                  class="w-full bg-[#0B1020] border border-white/[0.06] rounded-lg px-3 py-2.5 text-sm text-white focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/20 focus:outline-none transition"
                  autocomplete="new-password" spellcheck="false" required />
                <%= for error <- @password_form[:password].errors do %>
                  <p class="text-red-400 text-sm mt-1"><%= translate_error(error) %></p>
                <% end %>
              </div>
              <div>
                <label class="block text-sm text-gray-400 mb-1">Confirm password</label>
                <input type="password" name={@password_form[:password_confirmation].name}
                  class="w-full bg-[#0B1020] border border-white/[0.06] rounded-lg px-3 py-2.5 text-sm text-white focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/20 focus:outline-none transition"
                  autocomplete="new-password" spellcheck="false" />
                <%= for error <- @password_form[:password_confirmation].errors do %>
                  <p class="text-red-400 text-sm mt-1"><%= translate_error(error) %></p>
                <% end %>
              </div>
              <button type="submit" class="bg-emerald-600 hover:bg-emerald-500 text-white rounded-lg px-4 py-2.5 text-sm font-semibold transition">
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

    rate_limit = if plan == "pro", do: 60, else: 10

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:plan, plan)
      |> assign(:exports_remaining, Accounts.exports_remaining(user))
      |> assign(:export_limit, Accounts.export_limit(user))
      |> assign(:per_page, Accounts.results_per_page(user))
      |> assign(:rate_limit, rate_limit)
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

end
