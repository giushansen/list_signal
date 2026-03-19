defmodule LS.BGP do
  @moduledoc "BGP enrichment — resolver + scorer. Used by WorkerAgent."
  alias LS.BGP.Resolver
  def stats, do: %{resolver: Resolver.stats()}
end
