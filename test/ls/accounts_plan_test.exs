defmodule LS.AccountsPlanTest do
  use LS.DataCase, async: true

  alias LS.Accounts
  alias LS.Accounts.User

  setup do
    {:ok, user} = Accounts.register_user(%{email: LS.AccountsFixtures.unique_user_email()})
    %{user: user}
  end

  describe "update_user_plan/2" do
    test "upgrades to pro", %{user: user} do
      assert user.plan == "free"
      {:ok, updated} = Accounts.update_user_plan(user, %{plan: "pro", stripe_subscription_id: "sub_123"})
      assert updated.plan == "pro"
      assert updated.stripe_subscription_id == "sub_123"
    end

    test "upgrades to starter", %{user: user} do
      assert user.plan == "free"
      {:ok, updated} = Accounts.update_user_plan(user, %{plan: "starter", stripe_subscription_id: "sub_456"})
      assert updated.plan == "starter"
      assert updated.stripe_subscription_id == "sub_456"
    end

    test "downgrades to free", %{user: user} do
      {:ok, user} = Accounts.update_user_plan(user, %{plan: "pro", stripe_subscription_id: "sub_123"})
      {:ok, updated} = Accounts.update_user_plan(user, %{plan: "free", stripe_subscription_id: nil})
      assert updated.plan == "free"
      assert updated.stripe_subscription_id == nil
    end

    test "rejects invalid plan", %{user: user} do
      {:error, changeset} = Accounts.update_user_plan(user, %{plan: "invalid"})
      assert %{plan: ["is invalid"]} = errors_on(changeset)
    end

    test "sets stripe_customer_id", %{user: user} do
      {:ok, updated} = Accounts.update_user_plan(user, %{stripe_customer_id: "cus_abc"})
      assert updated.stripe_customer_id == "cus_abc"
    end

    test "broadcasts plan_updated via PubSub", %{user: user} do
      Phoenix.PubSub.subscribe(LS.PubSub, "user_plan:#{user.id}")
      {:ok, _} = Accounts.update_user_plan(user, %{plan: "pro", stripe_subscription_id: "sub_pub"})

      assert_receive {:plan_updated, updated_user}
      assert updated_user.plan == "pro"
    end
  end

  describe "effective_plan/1" do
    test "returns free when no subscription", %{user: user} do
      assert User.effective_plan(user) == "free"
    end

    test "returns plan when subscribed", %{user: user} do
      {:ok, user} = Accounts.update_user_plan(user, %{plan: "pro", stripe_subscription_id: "sub_123"})
      assert User.effective_plan(user) == "pro"
    end

    test "returns starter when subscribed to starter", %{user: user} do
      {:ok, user} = Accounts.update_user_plan(user, %{plan: "starter", stripe_subscription_id: "sub_456"})
      assert User.effective_plan(user) == "starter"
    end
  end

  describe "subscribed?/1" do
    test "returns false when no subscription_id", %{user: user} do
      refute User.subscribed?(user)
    end

    test "returns true when subscription_id is set", %{user: user} do
      {:ok, user} = Accounts.update_user_plan(user, %{plan: "pro", stripe_subscription_id: "sub_123"})
      assert User.subscribed?(user)
    end
  end

  describe "export_limit/1" do
    test "returns 0 for free users", %{user: user} do
      assert Accounts.export_limit(user) == 0
    end

    test "returns 500 for starter users", %{user: user} do
      {:ok, user} = Accounts.update_user_plan(user, %{plan: "starter", stripe_subscription_id: "sub_456"})
      assert Accounts.export_limit(user) == 500
    end

    test "returns 5000 for pro users", %{user: user} do
      {:ok, user} = Accounts.update_user_plan(user, %{plan: "pro", stripe_subscription_id: "sub_123"})
      assert Accounts.export_limit(user) == 5_000
    end
  end

  describe "results_per_page/1" do
    test "returns 15 for free users", %{user: user} do
      assert Accounts.results_per_page(user) == 15
    end

    test "returns 50 for starter users", %{user: user} do
      {:ok, user} = Accounts.update_user_plan(user, %{plan: "starter", stripe_subscription_id: "sub_456"})
      assert Accounts.results_per_page(user) == 50
    end

    test "returns 100 for pro users", %{user: user} do
      {:ok, user} = Accounts.update_user_plan(user, %{plan: "pro", stripe_subscription_id: "sub_123"})
      assert Accounts.results_per_page(user) == 100
    end
  end

  describe "can_export?/1" do
    test "returns false for free users", %{user: user} do
      refute Accounts.can_export?(user)
    end

    test "returns true for starter users", %{user: user} do
      {:ok, user} = Accounts.update_user_plan(user, %{plan: "starter", stripe_subscription_id: "sub_456"})
      assert Accounts.can_export?(user)
    end

    test "returns true for pro users", %{user: user} do
      {:ok, user} = Accounts.update_user_plan(user, %{plan: "pro", stripe_subscription_id: "sub_123"})
      assert Accounts.can_export?(user)
    end
  end
end
