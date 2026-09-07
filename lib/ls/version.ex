defmodule LS.Version do
  @moduledoc """
  The git revision this build was made from, baked in at compile time.

  Every crawl row and every enrichment row carries it (`pipeline_version`,
  migration 023) so a wrong value can be traced to the code that produced
  it and a fix can be measured by comparing rows before and after the
  revision, without guessing from timestamps. Deploys build on the node
  from a fresh clone, so `git` is present at compile time; `LS_GIT_SHA`
  overrides it (container builds), and "unknown" is the honest fallback.
  """

  @sha (case System.get_env("LS_GIT_SHA") do
          s when is_binary(s) and s != "" ->
            String.slice(s, 0, 12)

          _ ->
            case System.cmd("git", ["rev-parse", "--short=12", "HEAD"], stderr_to_stdout: true) do
              {out, 0} -> String.trim(out)
              _ -> "unknown"
            end
        end)

  @doc "Short git sha of this build, or \"unknown\"."
  @spec sha() :: String.t()
  def sha, do: @sha
end
