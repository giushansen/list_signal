defmodule LS.ReleaseEnvTest do
  use ExUnit.Case, async: true

  @moduledoc """
  `rel/env.sh.eex` runs before the VM boots on every node. Security audit
  2026-09-09: Erlang distribution and epmd listened on every interface; the
  script now binds both to the WireGuard address. The script is plain sh, so
  it is run here under `sh` with a fake `ip` command.
  """

  defp run(role, ip_output) do
    dir = Path.join(System.tmp_dir!(), "ls_relenv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join(dir, "bin/ip"), "#!/bin/sh\nprintf '%s\\n' '#{ip_output}'\n")
    File.chmod!(Path.join(dir, "bin/ip"), 0o755)
    script = EEx.eval_file("rel/env.sh.eex", release: %{})

    {out, 0} =
      System.cmd("sh", ["-c", script <> "\necho \"$RELEASE_NODE|$ERL_EPMD_ADDRESS|$ELIXIR_ERL_OPTIONS\""],
        env: [
          {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
          {"RELEASE_ROOT", Path.join(dir, "rel/x")},
          {"LS_ROLE", role},
          {"ELIXIR_ERL_OPTIONS", "-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9155"}
        ]
      )

    File.rm_rf!(dir)
    out |> String.trim() |> String.split("|")
  end

  test "distribution and epmd bind to the wg0 address, keeping the existing port range" do
    [node, epmd, erl] = run("master", "5: wg0    inet 10.0.0.1/24 scope global wg0")
    assert node == "master@10.0.0.1"
    assert epmd == "10.0.0.1"
    assert erl =~ "-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9155"
    assert erl =~ "-kernel inet_dist_use_interface {10,0,0,1}"
  end

  test "a worker derives its name from the host and still binds to wg0" do
    [node, epmd, erl] = run("worker", "5: wg0    inet 10.0.0.7/24 scope global wg0")
    assert node =~ ~r/^worker_[a-zA-Z0-9]+@10\.0\.0\.7$/
    assert epmd == "10.0.0.7"
    assert erl =~ "{10,0,0,7}"
  end
end
