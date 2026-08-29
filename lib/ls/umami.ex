defmodule LS.Umami do
  @moduledoc """
  Server-side Umami events, fire-and-forget.

  The browser tag covers page views; this covers things a browser never
  sees (API calls, MCP tool calls). Sends to the same Umami site via its
  `/api/send` collect endpoint. Disabled automatically when no website_id
  is configured (dev/test) and swallows every failure: analytics must never
  cost a request a millisecond or an error.
  """

  require Logger

  def track_async(event, data \\ %{}) do
    cfg = Application.get_env(:ls, :umami, [])
    website_id = cfg[:website_id]

    if website_id do
      Task.Supervisor.start_child(LS.TaskSupervisor, fn -> send_event(website_id, cfg, event, data) end)
    end

    :ok
  end

  defp send_event(website_id, cfg, event, data) do
    host = cfg[:src] |> to_string() |> URI.parse() |> Map.get(:host)

    Req.post("https://#{host}/api/send",
      json: %{
        type: "event",
        payload: %{
          website: website_id,
          name: event,
          url: "/api",
          hostname: "listsignal.com",
          data: data
        }
      },
      headers: [{"user-agent", "ListSignal-Server/1.0"}],
      receive_timeout: 5_000,
      retry: false,
      finch: LS.Finch.Bulk
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
