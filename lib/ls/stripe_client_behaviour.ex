defmodule LS.StripeClientBehaviour do
  @moduledoc """
  Behaviour contract for the Stripe client — lets tests swap in a mock
  (see `LS.StripeClient` for the real implementation).
  """
  @callback create_customer(map()) :: {:ok, map()} | {:error, any()}
  @callback create_checkout_session(map()) :: {:ok, any()} | {:error, any()}
  @callback create_billing_portal_session(map()) :: {:ok, any()} | {:error, any()}
end
