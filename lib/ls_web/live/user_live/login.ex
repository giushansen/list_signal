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
  def mount(params, _session, socket) do
    # A signed-in visitor has nothing to do here, so send them to the
    # dashboard, which is where the log-out link lives (2026-09-15, owner's
    # call). Landing on a login page while already logged in is a dead end:
    # the owner's browser held a customer's session and the page offered no
    # way out of it, which is what "I can't log in as another user" turned
    # out to mean. Log out from the dashboard, then this page works normally.
    #
    # The one reason to show the form to someone signed in is `:require_sudo_mode`
    # bouncing them here to re-authenticate, and it says so with ?reauth=1.
    if socket.assigns[:current_scope] && params["reauth"] not in ["1", "true"] do
      {:ok, Phoenix.LiveView.redirect(socket, to: ~p"/dashboard")}
    else
      mount_form(socket)
    end
  end

  defp mount_form(socket) do
    # Prefill ONLY from the flash, which carries back the address someone just
    # typed after a wrong password. Never from the session.
    #
    # It used to fall back to `current_scope.user.email`, which pinned the
    # field: the value is server-rendered, so every LiveView patch — a
    # reconnect, a flash change, any re-render — put the signed-in user's
    # address back and threw away what was being typed. Removing `readonly`
    # on 2026-09-15 made the field editable but not typeable, and the owner,
    # whose browser held a customer's session, could not replace that
    # customer's address no matter how many times the page was reloaded.
    # Whose session it is belongs in the sentence above the form, not welded
    # into the input.
    email = Phoenix.Flash.get(socket.assigns.flash, :email)
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
