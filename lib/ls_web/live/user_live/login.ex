defmodule LSWeb.UserLive.Login do
  @moduledoc """
  Magic-link login LiveView (phx.gen.auth).

  The email field is always editable. The generator made it read-only
  whenever a session already existed, with a one-line "re-authenticate"
  hint, so an owner whose browser still held a session could not switch
  accounts from this page and read it as a broken login (2026-09-15). A
  signed-in visitor is now told who they are and given the dashboard and
  a log-out link; the session controller logs in whichever account the
  submitted credentials belong to, so an editable field is safe.
  """
  use LSWeb, :live_view

  alias LS.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#0a0e17] flex items-center justify-center px-4">
      <div class="w-full max-w-sm">
        <div class="text-center mb-8">
          <.logo_lockup />
          <h1 class="text-xl font-semibold text-white mt-2">Log in</h1>
          <p class="text-gray-400 text-sm mt-1">
            <%= if @current_scope do %>
              You are signed in as <span class="text-white">{@current_scope.user.email}</span>.
              Re-authenticate below,
              <.link navigate={~p"/dashboard"} class="text-emerald-400 hover:underline">go to the dashboard</.link>,
              or
              <.link href={~p"/users/log-out"} method="delete" class="text-emerald-400 hover:underline">log out</.link>
              to use another account.
            <% else %>
              Don't have an account?
              <.link navigate={~p"/users/register"} data-umami-event="signup_cta" data-umami-event-source="login_page" class="text-emerald-400 hover:underline">Sign up</.link>
            <% end %>
          </p>
        </div>

        <div :if={local_mail_adapter?()} class="bg-blue-900/30 border border-blue-500/30 rounded p-3 mb-4 text-sm text-blue-300">
          Local mail adapter active.
          <a href="/dev/mailbox" class="underline">View mailbox</a>
        </div>

        <div class="bg-[#111B33] border border-white/[0.07] rounded-lg p-6 space-y-4">
          <!-- Magic link form -->
          <.form
            :let={f}
            for={@form}
            id="login_form_magic"
            action={~p"/users/log-in"}
            phx-submit="submit_magic"
          >
            <div class="space-y-3">
              <div>
                <label class="block text-sm text-gray-400 mb-1">Email</label>
                <input type="email" name={f[:email].name} value={f[:email].value}
                  class="w-full bg-[#0a0e17] border border-white/[0.07] rounded px-3 py-2 text-sm text-white focus:border-emerald-500 focus:outline-none"
                  autocomplete="username" spellcheck="false" required phx-mounted={Phoenix.LiveView.JS.focus()} />
              </div>
              <button type="submit" class="w-full bg-emerald-600 hover:bg-emerald-500 text-white rounded px-4 py-2 text-sm font-medium transition">
                Send login link
              </button>
            </div>
          </.form>

          <div class="flex items-center gap-3 text-xs text-gray-500">
            <div class="flex-1 border-t border-white/[0.07]"></div>
            <span>or use password</span>
            <div class="flex-1 border-t border-white/[0.07]"></div>
          </div>

          <!-- Password form -->
          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
          >
            <div class="space-y-3">
              <input type="email" name={f[:email].name} value={f[:email].value}
                class="w-full bg-[#0a0e17] border border-white/[0.07] rounded px-3 py-2 text-sm text-white focus:border-emerald-500 focus:outline-none"
                autocomplete="username" spellcheck="false" required />
              <input type="password" name={f[:password].name}
                class="w-full bg-[#0a0e17] border border-white/[0.07] rounded px-3 py-2 text-sm text-white focus:border-emerald-500 focus:outline-none"
                autocomplete="current-password" spellcheck="false" placeholder="Password" />
              <button type="submit" name={f[:remember_me].name} value="true"
                class="w-full bg-[#0a0e17] border border-white/[0.07] hover:bg-white/[0.05] text-white rounded px-4 py-2 text-sm transition">
                Log in with password
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    # Same flash whether the address exists, is throttled, or got a link:
    # the form must not reveal who has an account. Security audit 2026-09-09:
    # unlimited sends let anyone run up the Mailgun bill; see LS.Throttle.
    with user when not is_nil(user) <- Accounts.get_user_by_email(email),
         true <- LSWeb.MagicLink.allowed?(email) do
      Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))
    end

    {:noreply,
     socket
     |> put_flash(:info, "If your email is in our system, you will receive a login link shortly.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:ls, LS.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
