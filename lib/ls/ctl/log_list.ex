defmodule LS.CTL.LogList do
  @moduledoc """
  Detects when the certificate-transparency landscape shifts under us.

  Our poller (`LS.CTL.Poller`) polls a HARDCODED list of 8 CT logs that must be
  hand-updated every ~6 months as shards freeze and CAs rotate lines
  (Let's Encrypt shut its RFC-6962 logs in Feb 2026; Sectigo replaced
  Mammoth/Sabre; DigiCert replaced Nessie/Yeti). Miss a change and discovery
  silently narrows.

  This module fetches Chrome's authoritative log list and, purely in `diff/2`,
  compares the **usable** logs whose temporal interval covers today against
  what we poll:

    * `new`     — usable logs Chrome lists that we do NOT poll (add them).
    * `retired` — logs we poll that are no longer usable/qualified (they will
      stop yielding certs).

  `LS.Alerts` turns a non-empty diff into an email so the owner updates
  `@log_configs` deliberately, not after noticing a traffic drop.
  """

  require Logger

  @list_url "https://www.gstatic.com/ct/log_list/v3/all_logs_list.json"
  @usable_states ~w(usable qualified readonly)

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

  @doc "Chrome's usable logs whose temporal interval covers `today` → `[%{description, url}]`."
  def fetch_usable(today \\ Date.utc_today()) do
    case LS.Verification.HTTP.get_json(@list_url, timeout: 30_000, gap_ms: 0) do
      {:ok, %{"operators" => operators}} -> {:ok, parse(operators, today)}
      {:ok, other} -> {:error, {:unexpected, inspect(other) |> String.slice(0, 120)}}
      err -> err
    end
  end

  @doc false
  def parse(operators, today) when is_list(operators) do
    for op <- operators, log <- Map.get(op, "logs", []),
        get_in(log, ["state"]) |> usable_state?(),
        covers_today?(log, today),
        url = log["url"],
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
