defmodule LSWeb.StripeWebhookController do
  @moduledoc """
  Stripe webhook endpoint: verifies signatures (see `LSWeb.RawBodyReader`)
  and applies subscription lifecycle events to `LS.Accounts`.
  """
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

            # The billing side of the same evidence trail: when the plan
            # changed, and on whose authority.
            LS.Audit.record("stripe_#{type}", %{
              user_id: updated.id,
              email: updated.email,
              metadata: %{plan: updated.plan, subscription_status: updated.subscription_status}
            })

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
  def handle_event(%{type: "invoice.paid", data: %{object: invoice}}) do
    customer_id = Map.get(invoice, :customer)

    case is_binary(customer_id) && Accounts.get_user_by_stripe_customer_id(customer_id) do
      false ->
        Logger.warning("[StripeWebhook] invoice.paid: missing customer id, ignoring")

      nil ->
        Logger.warning("[StripeWebhook] invoice.paid: no user for customer #{customer_id}")

      user ->
        # Idempotent: re-affirm the subscription is active and extend the paid-through
        # date. Safe if the event is redelivered (same values reapplied).
        attrs =
          %{subscription_status: "active"}
          |> maybe_put(:current_period_end, invoice_period_end(invoice))
          |> maybe_put(:stripe_subscription_id, invoice_subscription_id(invoice))

        case Accounts.update_user_plan(user, attrs) do
          {:ok, updated} ->
            Logger.info("[StripeWebhook] invoice.paid: user #{updated.id} active (plan=#{updated.plan})")

          {:error, changeset} ->
            Logger.error("[StripeWebhook] invoice.paid: failed for user #{user.id}: #{inspect(changeset.errors)}")
        end
    end
  end

  @doc false
  def handle_event(%{type: "invoice.payment_failed", data: %{object: invoice}}) do
    customer_id = Map.get(invoice, :customer)

    case is_binary(customer_id) && Accounts.get_user_by_stripe_customer_id(customer_id) do
      false ->
        Logger.warning("[StripeWebhook] invoice.payment_failed: missing customer id, ignoring")

      nil ->
        Logger.warning("[StripeWebhook] invoice.payment_failed: no user for customer #{customer_id}")

      user ->
        # Don't revoke immediately — Stripe retries. Mark past_due and let
        # effective_plan/1 decide; the subscription id stays set so access
        # continues during the retry/grace window.
        case Accounts.update_user_plan(user, %{subscription_status: "past_due"}) do
          {:ok, updated} ->
            Logger.warning("[StripeWebhook] invoice.payment_failed: user #{updated.id} marked past_due")

          {:error, changeset} ->
            Logger.error("[StripeWebhook] invoice.payment_failed: failed for user #{user.id}: #{inspect(changeset.errors)}")
        end
    end
  end

  @doc false
  def handle_event(%{type: type}) do
    Logger.debug("[StripeWebhook] Ignored event: #{type}")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp invoice_subscription_id(invoice) do
    case Map.get(invoice, :subscription) do
      sid when is_binary(sid) and sid != "" -> sid
      _ -> nil
    end
  end

  # Pull the subscription period end (Unix ts) from the invoice line items,
  # falling back to the invoice period_end, and return a truncated DateTime.
  defp invoice_period_end(invoice) do
    ts =
      case invoice do
        %{lines: %{data: [_ | _] = lines}} ->
          case List.last(lines) do
            %{period: %{end: e}} when is_integer(e) -> e
            _ -> Map.get(invoice, :period_end)
          end

        _ ->
          Map.get(invoice, :period_end)
      end

    case ts do
      e when is_integer(e) and e > 0 ->
        case DateTime.from_unix(e) do
          {:ok, dt} -> DateTime.truncate(dt, :second)
          _ -> nil
        end

      _ ->
        nil
    end
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
