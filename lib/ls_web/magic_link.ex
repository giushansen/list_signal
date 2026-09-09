defmodule LSWeb.MagicLink do
  @moduledoc """
  Whether a magic-link email may be sent to `email` right now.

  Five per address per hour covers a person who mistypes or loses the mail;
  300 per hour fleet-wide bounds what a scripted attacker can make Mailgun
  send regardless of how many addresses they try. Both windows are
  `LS.Throttle` fixed windows. Pure apart from the counter, so both forms
  share one rule and one test.
  """

  @per_address 5
  @per_hour_total 300
  @window_s 3_600

  @spec allowed?(term()) :: boolean()
  def allowed?(email) when is_binary(email) do
    key = email |> String.trim() |> String.downcase()

    LS.Throttle.allow?(:magic_link, key, @per_address, @window_s) and
      LS.Throttle.allow?(:magic_link_total, :all, @per_hour_total, @window_s)
  end

  def allowed?(_), do: false

  @doc false
  def limits, do: %{per_address: @per_address, per_hour_total: @per_hour_total, window_s: @window_s}
end
