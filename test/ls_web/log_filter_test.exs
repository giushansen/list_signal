defmodule LSWeb.LogFilterTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Request logs are kept for weeks in journald and read by anyone with a shell
  on the master. Security audit 2026-09-09: only "password" was masked, so an
  API key sent as a query parameter landed in the log in clear text.
  """

  test "credentials in request parameters are masked before logging" do
    filtered =
      Phoenix.Logger.filter_values(
        %{"api_key" => "ls_live_abc", "key" => "k", "token" => "t", "secret" => "s", "email" => "a@b.c"},
        Application.get_env(:phoenix, :filter_parameters)
      )

    assert filtered["api_key"] == "[FILTERED]"
    assert filtered["key"] == "[FILTERED]"
    assert filtered["token"] == "[FILTERED]"
    assert filtered["secret"] == "[FILTERED]"
    assert filtered["email"] == "a@b.c", "ordinary fields still log, or debugging goes blind"
  end
end
