defmodule LS.StripeClientBehaviour do
  @callback create_customer(map()) :: {:ok, map()} | {:error, any()}
  @callback create_checkout_session(map()) :: {:ok, any()} | {:error, any()}
  @callback create_billing_portal_session(map()) :: {:ok, any()} | {:error, any()}
end
