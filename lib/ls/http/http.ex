defmodule LS.HTTP do
  @moduledoc "HTTP enrichment — client + tech detection. Used by WorkerAgent."
  def stats do
    ets_size = try do :ets.info(:http_target_ip_rate_limiter, :size) rescue _ -> 0 end || 0
    ets_mem = try do :ets.info(:http_target_ip_rate_limiter, :memory) rescue _ -> 0 end || 0
    %{rate_limiter: %{tracked_ips: ets_size, memory_mb: Float.round(ets_mem * :erlang.system_info(:wordsize) / 1_048_576, 2)}}
  end
end
