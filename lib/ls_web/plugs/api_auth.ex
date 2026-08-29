defmodule LSWeb.Plugs.ApiAuth do
  @moduledoc """
  Authentication + quota + rate limit for `/api/v1` and `/mcp`.

  Accepts `Authorization: Bearer ls_...` or `X-API-Key: ls_...` (agents and
  SDKs disagree on which; supporting both costs two header reads). Errors
  are RFC 9457 problem+json with a field-level `detail` so an AI agent can
  self-correct in one retry, which is the difference between an agent
  adopting an API and abandoning it.

  Order matters: rate limit before quota, so a hammering client burns its
  per-minute budget, not its monthly one.
  """

  import Plug.Conn
  alias LS.ApiKeys

  @docs_url "https://listsignal.com/developers"

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- bearer(conn),
         {:ok, key, user} <- ApiKeys.authenticate(token),
         plan = LS.Accounts.User.effective_plan(user),
         :ok <- check_rate(key.id, plan),
         :ok <- check_quota(key, plan) do
      conn
      |> assign(:api_key, key)
      |> assign(:api_plan, plan)
      |> assign(:api_user, user)
    else
      {:error, :missing_key} ->
        problem(conn, 401, "Missing API key",
          "Send your key as 'Authorization: Bearer ls_...' or 'X-API-Key: ls_...'. Get a free key (1,000 lookups/month) at https://listsignal.com/signup, then create it in Settings.")

      {:error, :invalid_key} ->
        problem(conn, 401, "Invalid API key",
          "The key was not recognised. Keys start with 'ls_'. Check for truncation, or create a new one in Settings at listsignal.com.")

      {:error, :revoked} ->
        problem(conn, 401, "API key revoked",
          "This key was revoked. Create a new one in Settings at listsignal.com.")

      {:error, :rate_limited, limit} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> problem(429, "Rate limit exceeded",
          "This key allows #{limit} requests per minute. Wait for the window to reset, or upgrade at https://listsignal.com/pricing.")

      {:error, :quota_exceeded, quota} ->
        problem(conn, 403, "Monthly quota exhausted",
          "This key's plan includes #{quota} calls per month; the counter resets on the 1st. Upgrade at https://listsignal.com/pricing for a larger quota.")
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, String.trim(token)}
      _ ->
        case get_req_header(conn, "x-api-key") do
          [token | _] when token != "" -> {:ok, String.trim(token)}
          _ -> {:error, :missing_key}
        end
    end
  end

  defp check_rate(key_id, plan) do
    limit = ApiKeys.rate_per_min(plan)

    case LSWeb.ApiRateLimiter.hit(key_id, limit) do
      :ok -> :ok
      :over -> {:error, :rate_limited, limit}
    end
  end

  defp check_quota(key, plan) do
    if ApiKeys.within_quota?(key, plan),
      do: :ok,
      else: {:error, :quota_exceeded, ApiKeys.monthly_quota(plan)}
  end

  @doc "RFC 9457 problem+json response. Public: the controllers reuse it."
  def problem(conn, status, title, detail) do
    conn
    |> put_resp_content_type("application/problem+json")
    |> send_resp(
      status,
      Jason.encode!(%{
        type: "#{@docs_url}#errors",
        title: title,
        status: status,
        detail: detail
      })
    )
    |> halt()
  end
end

defmodule LSWeb.ApiRateLimiter do
  @moduledoc """
  Per-key per-minute counter in ETS. An abuse guard, not billing: resets on
  a fixed minute window, local to the node (single web node today), and
  fails open if the table is missing so a limiter bug can never take the
  API down.
  """
  use GenServer

  @table :api_rate_limiter

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def hit(key_id, limit) do
    window = div(System.system_time(:second), 60)
    counter_key = {key_id, window}

    count = :ets.update_counter(@table, counter_key, {2, 1}, {counter_key, 0})
    if count <= limit, do: :ok, else: :over
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  # Old windows are garbage; sweep every 5 minutes so the table stays tiny.
  @impl true
  def handle_info(:sweep, state) do
    horizon = div(System.system_time(:second), 60) - 2
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", horizon}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, 300_000)
end
