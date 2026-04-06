defmodule LSWeb.StripeWebhookControllerTest do
  use LSWeb.ConnCase, async: true

  alias LS.Accounts
  alias LSWeb.StripeWebhookController

  setup do
    user = LS.AccountsFixtures.user_fixture()
    {:ok, user} = Accounts.update_user_plan(user, %{stripe_customer_id: "cus_test_123"})
    %{user: user}
  end

  describe "handle_event/1 — subscription.created" do
    test "upgrades user to pro", %{user: user} do
      event = subscription_event("customer.subscription.created", user.stripe_customer_id, "sub_123")
      StripeWebhookController.handle_event(event)

      updated = Accounts.get_user!(user.id)
      assert updated.plan == "pro"
      assert updated.stripe_subscription_id == "sub_123"
    end
  end

  describe "handle_event/1 — subscription.updated" do
    test "updates user plan", %{user: user} do
      event = subscription_event("customer.subscription.updated", user.stripe_customer_id, "sub_456")
      StripeWebhookController.handle_event(event)

      updated = Accounts.get_user!(user.id)
      assert updated.plan == "pro"
      assert updated.stripe_subscription_id == "sub_456"
    end
  end

  describe "handle_event/1 — subscription.resumed" do
    test "reactivates user plan", %{user: user} do
      event = subscription_event("customer.subscription.resumed", user.stripe_customer_id, "sub_789")
      StripeWebhookController.handle_event(event)

      updated = Accounts.get_user!(user.id)
      assert updated.plan == "pro"
      assert updated.stripe_subscription_id == "sub_789"
    end
  end

  describe "handle_event/1 — subscription.deleted" do
    test "downgrades to free and clears subscription", %{user: user} do
      {:ok, _} = Accounts.update_user_plan(user, %{plan: "pro", stripe_subscription_id: "sub_del"})

      event = subscription_event("customer.subscription.deleted", user.stripe_customer_id, "sub_del")
      StripeWebhookController.handle_event(event)

      updated = Accounts.get_user!(user.id)
      assert updated.plan == "free"
      assert updated.stripe_subscription_id == nil
    end
  end

  describe "handle_event/1 — subscription.paused" do
    test "downgrades to free and clears subscription", %{user: user} do
      {:ok, _} = Accounts.update_user_plan(user, %{plan: "pro", stripe_subscription_id: "sub_pause"})

      event = subscription_event("customer.subscription.paused", user.stripe_customer_id, "sub_pause")
      StripeWebhookController.handle_event(event)

      updated = Accounts.get_user!(user.id)
      assert updated.plan == "free"
      assert updated.stripe_subscription_id == nil
    end
  end

  describe "handle_event/1 — unknown customer" do
    test "handles gracefully without crashing" do
      event = subscription_event("customer.subscription.created", "cus_unknown", "sub_999")
      StripeWebhookController.handle_event(event)
    end
  end

  describe "handle_event/1 — unhandled events" do
    test "ignores unknown event types" do
      StripeWebhookController.handle_event(%{type: "invoice.paid", data: %{object: %{}}})
    end
  end

  describe "PubSub broadcast on plan change" do
    test "broadcasts plan_updated when subscription is created", %{user: user} do
      Phoenix.PubSub.subscribe(LS.PubSub, "user_plan:#{user.id}")

      event = subscription_event("customer.subscription.created", user.stripe_customer_id, "sub_pub")
      StripeWebhookController.handle_event(event)

      assert_receive {:plan_updated, updated_user}
      assert updated_user.plan == "pro"
    end

    test "broadcasts plan_updated when subscription is deleted", %{user: user} do
      {:ok, _} = Accounts.update_user_plan(user, %{plan: "pro", stripe_subscription_id: "sub_x"})

      Phoenix.PubSub.subscribe(LS.PubSub, "user_plan:#{user.id}")

      event = subscription_event("customer.subscription.deleted", user.stripe_customer_id, "sub_x")
      StripeWebhookController.handle_event(event)

      assert_receive {:plan_updated, updated_user}
      assert updated_user.plan == "free"
    end
  end

  # Helpers

  defp subscription_event(type, customer_id, subscription_id) do
    # Use a known price_id — in test, stripe_pro_monthly_price_id may be nil,
    # which maps to "free" in price_id_to_plan. Set it for the test.
    price_id = Application.get_env(:ls, :stripe_pro_monthly_price_id) || "price_pro_monthly_test"

    # Temporarily set the price ID so price_id_to_plan can match it
    Application.put_env(:ls, :stripe_pro_monthly_price_id, price_id)

    %{
      type: type,
      data: %{
        object: %{
          id: subscription_id,
          customer: customer_id,
          items: %{data: [%{price: %{id: price_id}}]}
        }
      }
    }
  end
end
