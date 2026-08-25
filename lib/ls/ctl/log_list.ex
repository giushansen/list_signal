defmodule LS.CTL.LogList do
  @moduledoc """
  Detects when the certificate-transparency landscape shifts under us.

  Since 2026-08-25 the poller reconciles its own sources from Chrome's list
  every 6 hours (`LS.CTL.Sources`), so this module is the BACKSTOP, not the
  primary mechanism: if `diff_current/0` is persistently non-empty, the
  reconcile loop itself is broken (fetch failing, apply crashing) — which is
  exactly the failure that must never go unnoticed, because it silently
  narrows discovery, the product's most upstream data.

  `diff/2` stays pure: `new` = ingestible logs Chrome lists that we do not
  poll; `retired` = logs we poll that Chrome no longer lists as ingestible.
  Both publication protocols are compared — RFC-6962 logs by submission URL,
  tiled logs by monitoring URL, matching how the poller addresses each.
  `LS.Alerts` turns a non-empty diff into an email.
  """

  require Logger

  @list_url "https://www.gstatic.com/ct/log_list/v3/all_logs_list.json"
  @usable_states ~w(usable qualified)

  @doc "Fetch Chrome's list and diff against the live poller configs. `%{new, retired}` (empty on fetch failure — never invents a change)."
  def diff_current do
    with {:ok, usable} <- fetch_usable() do
      diff(LS.CTL.Poller.configs(), usable)
    else
      _ -> %{new: [], retired: []}
    end
  end

  @doc """
  Pure diff. `configs` is our poller list (`%{name, url, ...}`); `usable` is a
  list of `%{description, url}` from Chrome. Matching is by normalized host+path
  of the URL, so trailing slashes and scheme differences don't create noise.
  """
  @spec diff([map()], [map()]) :: %{new: [String.t()], retired: [String.t()]}
  def diff(configs, usable) do
    ours = MapSet.new(configs, &key(&1.url))
    theirs = MapSet.new(usable, &key(&1.url))

    new =
      usable
      |> Enum.reject(&MapSet.member?(ours, key(&1.url)))
      |> Enum.map(& &1.description)
      |> Enum.sort()

    retired =
      configs
      |> Enum.reject(&MapSet.member?(theirs, key(&1.url)))
      |> Enum.map(& &1.name)
      |> Enum.sort()

    %{new: new, retired: retired}
  end

  @doc "Chrome's ingestible logs (both protocols) covering `today` → `[%{description, url}]`. Tiled logs are keyed by monitoring URL, like the poller."
  def fetch_usable(today \\ Date.utc_today()) do
    case LS.Verification.HTTP.get_json(@list_url, timeout: 30_000, gap_ms: 0) do
      {:ok, %{"operators" => operators}} -> {:ok, parse(operators, today)}
      {:ok, other} -> {:error, {:unexpected, inspect(other) |> String.slice(0, 120)}}
      err -> err
    end
  end

  @doc false
  def parse(operators, today) when is_list(operators) do
    for op <- operators,
        {kind, url_field} <- [{"logs", "url"}, {"tiled_logs", "monitoring_url"}],
        log <- List.wrap(op[kind]),
        is_map(log),
        get_in(log, ["state"]) |> usable_state?(),
        covers_today?(log, today),
        url = log[url_field],
        is_binary(url) do
      %{description: log["description"] || url, url: url}
    end
  end

  def parse(_, _), do: []

  defp usable_state?(state) when is_map(state), do: Map.keys(state) |> Enum.any?(&(&1 in @usable_states))
  defp usable_state?(_), do: false

  # A log only mints SCTs for certs expiring inside its temporal_interval; one
  # whose window has passed is effectively dead to us even if still "usable".
  defp covers_today?(log, today) do
    case get_in(log, ["temporal_interval"]) do
      %{"start_inclusive" => s, "end_exclusive" => e} ->
        with {:ok, sd, _} <- DateTime.from_iso8601(s), {:ok, ed, _} <- DateTime.from_iso8601(e) do
          Date.compare(today, DateTime.to_date(sd)) != :lt and Date.compare(today, DateTime.to_date(ed)) == :lt
        else
          _ -> true
        end

      _ -> true
    end
  end

  # Normalize a log URL to host + base path, stripping the RFC-6962 `/ct/v1`
  # API suffix our poller appends but Chrome's base URL omits, plus any
  # trailing slash — so the same log matches from either source.
  defp key(url) when is_binary(url) do
    u = URI.parse(if String.contains?(url, "://"), do: url, else: "https://" <> url)
    path =
      (u.path || "")
      |> String.trim_trailing("/")
      |> String.replace_suffix("/ct/v1", "")
      |> String.trim_trailing("/")

    "#{u.host}#{path}"
  end

  defp key(_), do: ""
end
