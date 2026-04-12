defmodule LSWeb.StripeWebhookController do
  use LSWeb, :controller
  require Logger

  alias LS.Accounts

  def handle_webhook(conn, _params) do
    secret = Application.get_env(:ls, :stripe_webhook_secret)
    raw_body = conn.assigns[:raw_body] || ""
    signature = Plug.Conn.get_req_header(conn, "stripe-signature") |> List.first("")

    case Stripe.Webhook.construct_event(raw_body, signature, secret) do
      {:ok, event} ->
        handle_event(event)
        json(conn, %{ok: true})

      {:error, reason} ->
        Logger.warning("Stripe webhook verification failed: #{inspect(reason)}")
        conn |> put_status(400) |> json(%{error: "invalid signature"})
    end
  end

  @doc false
  def handle_event(%{type: type, data: %{object: subscription}})
      when type in [
             "customer.subscription.created",
             "customer.subscription.updated",
             "customer.subscription.resumed"
           ] do
    customer_id = subscription.customer

    price_id =
      case subscription do
        %{items: %{data: [%{price: %{id: id}} | _]}} -> id
        _ -> ""
      end

    plan = price_id_to_plan(price_id)

    case Accounts.get_user_by_stripe_customer_id(customer_id) do
      nil ->
        Logger.warning("Stripe webhook: no user for customer #{customer_id}")

      user ->
        case Accounts.update_user_plan(user, %{
               plan: plan,
               stripe_subscription_id: subscription.id
             }) do
          {:ok, updated} ->
            Logger.info("[StripeWebhook] #{type}: user #{updated.id} → plan=#{updated.plan}")

          {:error, changeset} ->
            Logger.error("[StripeWebhook] Failed to update user #{user.id}: #{inspect(changeset.errors)}")
        end
    end
  end

  @doc false
  def handle_event(%{type: type, data: %{object: subscription}})
      when type in [
             "customer.subscription.deleted",
             "customer.subscription.paused"
           ] do
    customer_id = subscription.customer

    case Accounts.get_user_by_stripe_customer_id(customer_id) do
      nil ->
        Logger.warning("[StripeWebhook] #{type}: no user for customer #{customer_id}")

      user ->
        case Accounts.update_user_plan(user, %{
               plan: "free",
               stripe_subscription_id: nil
             }) do
          {:ok, updated} ->
            Logger.info("[StripeWebhook] #{type}: cleared subscription for user #{updated.id}")

          {:error, changeset} ->
            Logger.error("[StripeWebhook] Failed to clear subscription for user #{user.id}: #{inspect(changeset.errors)}")
        end
    end
  end

  @doc false
  def handle_event(%{type: type}) do
    Logger.debug("[StripeWebhook] Ignored event: #{type}")
  end

  defp price_id_to_plan(price_id) do
    plan_map = %{
      Application.get_env(:ls, :stripe_pro_monthly_price_id) => "pro",
      Application.get_env(:ls, :stripe_pro_yearly_price_id) => "pro",
      Application.get_env(:ls, :stripe_starter_monthly_price_id) => "starter",
      Application.get_env(:ls, :stripe_starter_yearly_price_id) => "starter"
    }

    Map.get(plan_map, price_id, "free")
  end
end
