defmodule LS.DNS do
  @moduledoc "DNS enrichment — resolver + scorer. Used by WorkerAgent."
  alias LS.DNS.Resolver
  def stats, do: %{dns: Resolver.stats()}
end
