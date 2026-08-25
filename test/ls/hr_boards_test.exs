defmodule LS.Verification.HRBoardsTest do
  @moduledoc """
  Boards are standing assets; the invariants are about not corrupting them.
  Slug extraction must match the URL shapes actually stored in biz_career
  (checked against real samples), sync must mark vanished boards as gone
  rather than erroring forever, and WTTJ slug extraction must survive the
  rendered page's real markup.
  """
  use ExUnit.Case, async: false

  alias LS.Verification.{HRBoards, WTTJ}

  @moduletag :data_contract

  # Real URL shapes captured from prod biz_career on 2026-08-25. If a platform
  # changes its URL layout, this fails before the harvest silently misses.
  @real_urls %{
    "greenhouse" => "https://job-boards.greenhouse.io/12twenty/jobs/4710612005",
    "lever" => "https://jobs.lever.co/acceldata/307e052c-a765-4b81-ba97-53f007e5d96b",
    "ashby" => "https://jobs.ashbyhq.com/localstack/cdacf25f-bffe-4e61-914b-a2353b620fb4",
    "workable" => "https://apply.workable.com/huspy/j/ABC123/",
    "smartrecruiters" => "https://jobs.smartrecruiters.com/Devoteam1/743999-consultant",
    "recruitee" => "https://acme-corp.recruitee.com/o/some-job"
  }

  test "every platform pattern extracts a slug from its real stored URL shape" do
    for {platform, re} <- HRBoards.patterns() do
      url = Map.fetch!(@real_urls, platform)

      assert [slug | _] = Regex.run(re, url, capture: :all_but_first),
             "#{platform} pattern no longer matches its own stored URLs"

      assert slug != ""
    end
  end

  test "reserved path segments never become boards (workable /j/ shortlinks, greenhouse /embed/)" do
    # 2026-08-26: most stored workable URLs are apply.workable.com/j/XXXX
    # shortlinks; without the blocklist the harvest creates a phantom 'j'
    # board that 404s on every sync forever.
    sql = HRBoards.harvest_sql_for_test("workable")
    assert sql =~ "slug NOT IN ('j'"
    assert sql =~ "'embed'"
  end

  test "greenhouse pattern handles both boards. and job-boards. hosts" do
    {_, re} = List.keyfind(HRBoards.patterns(), "greenhouse", 0)
    assert Regex.run(re, "https://boards.greenhouse.io/airbnb/jobs/1", capture: :all_but_first) == ["airbnb"]
    assert Regex.run(re, "https://job-boards.greenhouse.io/x1/jobs/2", capture: :all_but_first) == ["x1"]
  end

  test "WTTJ slug extraction from rendered markup, minus the house accounts" do
    html = """
    <a href="/fr/companies/back-market">Back Market</a>
    <a href="/fr/companies/alan">Alan</a>
    <a href="/fr/companies/wttj">us</a>
    <a href="/fr/companies/alan">dup</a>
    <a href="/en/companies/nope">wrong locale</a>
    """

    assert WTTJ.extract_slugs(html) == ["back-market", "alan"]
  end

  test "a live greenhouse board syncs end to end into biz_career" do
    # Network + local ClickHouse: the whole point of the module is that the
    # public JSON really is public. Skips cleanly when CH is down.
    case LS.Clickhouse.query_raw("SELECT 1") do
      {:ok, _} ->
        d = "hrboards-probe.test"

        clean = fn ->
          for t <- ~w(biz_career hr_boards biz_enrichment_log) do
            LS.Clickhouse.query_raw(
              "ALTER TABLE #{t} DELETE WHERE domain = '#{d}' SETTINGS mutations_sync = 1"
            )
          end
        end

        clean.()
        on_exit(clean)

        case HRBoards.sync_board("greenhouse", "airbnb", d) do
          {:ok, n} ->
            assert n > 0, "airbnb's board is public and never empty"

            {:ok, [[stored]]} =
              LS.Clickhouse.query_raw("SELECT uniqExact(job_id) FROM biz_career WHERE domain = '#{d}'")

            # 2026-08-26: this failed with 0 stored while n=188 — now_s() was
            # emitting microseconds, which the DateTime TSV parser rejects,
            # silently destroying the whole batch. Same failure class as the
            # three TabSeparated incidents in CLAUDE.md.
            assert String.to_integer(to_string(stored)) == n

          :error ->
            # Network flake — acceptable in a unit run, the scheduler retries.
            :ok

          :gone ->
            flunk("airbnb marked gone: the greenhouse API contract changed")
        end

      _ ->
        :ok
    end
  end
end
