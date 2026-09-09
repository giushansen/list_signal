defmodule LS.ClickhouseAuthTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Security audit 2026-09-09: the app queried ClickHouse as the passwordless
  `default` superuser (FILE, URL, REMOTE, DROP with grant option). Every call
  now carries the app user's credentials, so a scoped `ls_app` user can be
  enforced server-side. This pins that no call path forgets the headers.
  """

  setup do
    saved_cfg = Application.get_env(:ls, :clickhouse)
    Application.put_env(:ls, :clickhouse, user: "ls_app", password: "s3cret")
    Application.put_env(:ls, :clickhouse_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      if saved_cfg, do: Application.put_env(:ls, :clickhouse, saved_cfg), else: Application.delete_env(:ls, :clickhouse)
      Application.delete_env(:ls, :clickhouse_req_options)
    end)

    :ok
  end

  defp expect_auth do
    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), {:seen, Plug.Conn.get_req_header(conn, "x-clickhouse-user"), Plug.Conn.get_req_header(conn, "x-clickhouse-key")})
      Req.Test.json(conn, %{"data" => [[1]]})
    end)
  end

  test "SELECTs authenticate as the configured app user" do
    expect_auth()
    assert {:ok, [[1]]} = LS.Clickhouse.query_raw("SELECT 1")
    assert_received {:seen, ["ls_app"], ["s3cret"]}
  end

  test "TabSeparated inserts authenticate too (the inserter and the enrichment writer use this path)" do
    expect_auth()
    assert :ok = LS.Clickhouse.insert_raw("INSERT INTO t (a) FORMAT TabSeparated", "1")
    assert_received {:seen, ["ls_app"], ["s3cret"]}
  end

  test "without configuration the headers name the default user, so a laptop still works" do
    Application.delete_env(:ls, :clickhouse)
    assert LS.Clickhouse.auth_headers() == [{"x-clickhouse-user", "default"}, {"x-clickhouse-key", ""}]
  end
end
