defmodule LS.BillingTest do
  @moduledoc """
  Signup and checkout — the two paths where a failure costs revenue directly.

  Both broke in production at once (2026-08-01): free users were created
  without a Stripe customer, and checkout returned "Unable to start checkout"
  for everyone because prod had been deployed with placeholder Stripe keys.
  Nobody could pay. These tests pin the contract that would have caught it.
  """
  use LSWeb.ConnCase, async: false

  alias LS.Accounts
  alias LS.Accounts.User

  setup do
    original = Application.get_env(:ls, :stripe_client)
    on_exit(fn -> Application.put_env(:ls, :stripe_client, original) end)
    :ok
  end

  describe "register_user/1 gives every user a billing identity" do
    test "a free signup gets a Stripe customer" do
      Application.put_env(:ls, :stripe_client, LS.BillingTest.StripeOk)

      {:ok, user} = Accounts.register_user(%{email: "newfree-#{System.unique_integer([:positive])}@example.com"})

      assert user.stripe_customer_id == "cus_test_ok",
             "a free user with no Stripe customer cannot be upgraded without a second API call at the worst possible moment"

      assert User.effective_plan(user) == "free"
    end

    test "signup still succeeds when Stripe is down" do
      # An account the user can log into is worth more than a billing record.
      Application.put_env(:ls, :stripe_client, LS.BillingTest.StripeDown)

      assert {:ok, user} =
               Accounts.register_user(%{email: "stripedown-#{System.unique_integer([:positive])}@example.com"})

      assert user.stripe_customer_id in [nil, ""]
    end
  end

  describe "checkout configuration (prod ran on placeholder keys for weeks)" do
    test "every plan/period the UI offers has a price id configured" do
      # The UI offers four buttons; a missing price id makes the matching
      # button fail with a generic flash and no logged reason.
      # Skipped where Stripe is not configured at all (the test env), so
      # `mix test` stays green on a laptop; meaningful wherever it IS
      # configured, i.e. staging and prod.
      if configured?() do
        for plan <- ["starter", "pro"], period <- ["monthly", "yearly"] do
          key = String.to_atom("stripe_#{plan}_#{period}_price_id")
          price_id = Application.get_env(:ls, key)

          assert is_binary(price_id) and price_id != "",
                 "#{key} is not configured — the #{plan}/#{period} button cannot work"
        end
      end
    end

    test "configured Stripe values are real, not truncated placeholders" do
      # prod shipped sk_live_XXXXXXXX (16 chars) and price_CHANGEME (14).
      # Both look plausible in a config dump and fail every API call.
      secret = Application.get_env(:ls, :stripe_secret_key)

      if is_binary(secret) and secret != "" do
        assert String.length(secret) > 50,
               "STRIPE_SECRET_KEY looks truncated (#{String.length(secret)} chars) — real keys are ~107"
      end

      for plan <- ["starter", "pro"], period <- ["monthly", "yearly"] do
        price_id = Application.get_env(:ls, String.to_atom("stripe_#{plan}_#{period}_price_id"))

        if is_binary(price_id) and price_id != "" do
          assert String.length(price_id) >= 20,
                 "#{plan}/#{period} price id looks like a placeholder (#{price_id})"
        end
      end
    end
  end

  describe "plan entitlements" do
    test "each plan grants exactly what the pricing page promises" do
      # Pinning these stops a refactor from silently giving away Pro data or
      # quietly downgrading a paying customer.
      # Entitlement keys off stripe_subscription_id, not subscription_status:
      # the webhook clears the id on cancellation, and that is the single
      # source of truth for "is this account paying right now".
      free = %User{plan: "free", exports_used_this_month: 0}
      starter = %User{plan: "starter", stripe_subscription_id: "sub_1", exports_used_this_month: 0}
      pro = %User{plan: "pro", stripe_subscription_id: "sub_2", exports_used_this_month: 0}

      assert Accounts.export_limit(free) == 0
      assert Accounts.export_limit(starter) == 5_000
      assert Accounts.export_limit(pro) == 50_000

      refute Accounts.can_export?(free)
      assert Accounts.can_export?(starter)
      assert Accounts.can_export?(pro)

      assert Accounts.results_per_page(free) == 15
      assert Accounts.results_per_page(starter) == 50
      assert Accounts.results_per_page(pro) == 100
    end

    test "a cancelled subscription loses paid entitlements immediately" do
      # customer.subscription.deleted clears stripe_subscription_id, so the
      # plan column alone must never grant access.
      lapsed = %User{plan: "pro", stripe_subscription_id: nil, exports_used_this_month: 0}
      assert User.effective_plan(lapsed) == "free"
      refute Accounts.can_export?(lapsed)
      assert Accounts.export_limit(lapsed) == 0
    end

    test "a paying user who burned their monthly quota cannot export" do
      spent = %User{plan: "starter", stripe_subscription_id: "sub_3", exports_used_this_month: 5_000}
      assert Accounts.exports_remaining(spent) == 0
      refute Accounts.can_export?(spent)
    end
  end

  defp configured?, do: Application.get_env(:ls, :stripe_secret_key) not in [nil, ""]

  defmodule StripeOk do
    @moduledoc false
    def create_customer(_params), do: {:ok, %{id: "cus_test_ok"}}
    def create_checkout_session(_params), do: {:ok, %{url: "https://checkout.stripe.test/session"}}
    def create_billing_portal_session(_params), do: {:ok, %{url: "https://billing.stripe.test/portal"}}
  end

  defmodule StripeDown do
    @moduledoc false
    def create_customer(_params), do: {:error, :api_unreachable}
    def create_checkout_session(_params), do: {:error, :api_unreachable}
    def create_billing_portal_session(_params), do: {:error, :api_unreachable}
  end
end
