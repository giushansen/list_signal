defmodule LS.CTL do
  @moduledoc "Certificate Transparency Log pipeline. Poller feeds WorkQueue directly."
  alias LS.CTL.Poller
  def poller_stats, do: Poller.stats()
end
