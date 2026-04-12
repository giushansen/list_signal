defmodule LSWeb.SubscriptionController do
  use LSWeb, :controller

  alias LS.Accounts

  def create_checkout_session(conn, %{"plan" => plan, "period" => period})
      when plan in ["starter", "pro"] and period in ["monthly", "yearly"] do
    user = conn.assigns.current_scope.user

    with {:ok, user} <- ensure_stripe_customer(user),
         price_id when not is_nil(price_id) <- get_price_id(plan, period),
         {:ok, session} <- stripe_client().create_checkout_session(%{
           customer: user.stripe_customer_id,
           payment_method_types: ["card"],
           line_items: [%{price: price_id, quantity: 1}],
           mode: "subscription",
           success_url: url(~p"/dashboard") <> "?checkout=success",
           cancel_url: url(~p"/dashboard") <> "?checkout=cancelled",
           client_reference_id: user.id
         }) do
      redirect(conn, external: session.url)
    else
      _ ->
        conn
        |> put_flash(:error, "Unable to start checkout. Please try again.")
        |> redirect(to: ~p"/dashboard")
    end
  end

  def create_billing_portal_session(conn, _params) do
    user = conn.assigns.current_scope.user

    with {:ok, user} <- ensure_stripe_customer(user),
         {:ok, session} <- stripe_client().create_billing_portal_session(%{
           customer: user.stripe_customer_id,
           return_url: url(~p"/users/settings")
         }) do
      redirect(conn, external: session.url)
    else
      _ ->
        conn
        |> put_flash(:error, "Unable to open billing portal. Please try again.")
        |> redirect(to: ~p"/users/settings")
    end
  end

  defp ensure_stripe_customer(%{stripe_customer_id: sid} = user) when is_binary(sid) and sid != "" do
    {:ok, user}
  end

  defp ensure_stripe_customer(user) do
    case stripe_client().create_customer(%{email: user.email, metadata: %{user_id: user.id}}) do
      {:ok, customer} ->
        Accounts.update_user_plan(user, %{stripe_customer_id: customer.id})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_price_id(plan, period) do
    Application.get_env(:ls, String.to_atom("stripe_#{plan}_#{period}_price_id"))
  end

  defp stripe_client, do: Application.get_env(:ls, :stripe_client)
end
