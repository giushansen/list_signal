defmodule LS.StripeClient do
  @behaviour LS.StripeClientBehaviour

  @impl true
  def create_customer(params) do
    case Stripe.Customer.create(params) do
      {:ok, c} -> {:ok, %{id: c.id, email: c.email}}
      err -> err
    end
  end

  @impl true
  def create_checkout_session(params), do: Stripe.Checkout.Session.create(params)

  @impl true
  def create_billing_portal_session(params), do: Stripe.BillingPortal.Session.create(params)
end
