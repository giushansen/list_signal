defmodule LS.Email.FunctionWordsArtifactsTest do
  @moduledoc """
  2026-10-30, from the campaign session's real sends (27 hard bounces, 1,753
  deliveries): function-word mailboxes were scored as a person's mailbox
  (comercial@ on 30,115 rows, post@ 23,443, atendimento@ 17,434,
  reception@ 8,179, reservas@ 6,539, about 150 K in all), so a named-only
  campaign mailed them and they bounce heavily. And role words cut on
  extraction survived as addresses rated deliverable (nfo@ on 3,374 rows,
  contat@ for contact@).
  """
  use ExUnit.Case, async: true

  alias LS.Clickhouse
  alias LS.Email.Score
  alias LS.HTTP.EmailClass

  test "function words on the business's own domain are role mailboxes, not people" do
    for l <- ~w(comercial post atendimento reception reservas admissions operations employment
                vacancy personnel build canada secretaria sekretariat redaktion frontdesk quotes) do
      assert EmailClass.classify("#{l}@acme.com", "acme.com") == :role, l
    end
  end

  test "people stay people" do
    for e <- ~w(phillip@acme.com maria.lopez@acme.com mariana@acme.com ales@acme.com jsmithson@acme.com) do
      assert EmailClass.classify(e, "acme.com") == :named, e
    end
  end

  test "a role word cut on extraction is an artifact on any host and is not sellable" do
    for e <- ~w(nfo@drei-nm.com contat@aissestudio.com ontact@acme.com upport@acme.com ello@gmail.com dmin@acme.com) do
      assert EmailClass.classify(e, "acme.com") == :artifact, e
    end

    refute :artifact in EmailClass.sellable()
    assert %{score: 0, verdict: "rejected", evidence: ["a cut-off address, not a mailbox"]} =
             Score.score(%{email: "nfo@acme.com", domain: "acme.com", mx: true})
  end

  test "real mailboxes that look cut stay: suport@ is Romanian, helo@ is chosen on purpose" do
    assert EmailClass.classify("suport@acme.ro", "acme.ro") == :role
    assert EmailClass.classify("helo@acme.com", "acme.com") == :role
  end

  test "the SQL twin rejects the artifacts and the role regex knows the function words" do
    if match?({:ok, _}, Clickhouse.query_raw("SELECT 1")) do
      {:ok, [[why]]} = Clickhouse.query_raw("SELECT #{EmailClass.rejected_reason_sql("'nfo@acme.com'", "'acme.com'")}")
      assert why == "a cut-off address, not a mailbox"
      {:ok, [[ok]]} = Clickhouse.query_raw("SELECT #{EmailClass.rejected_reason_sql("'jane@acme.com'", "'acme.com'")}")
      assert ok == ""
      {:ok, [[role]]} = Clickhouse.query_raw("SELECT toUInt8(match('comercial@acme.com', #{EmailClass.role_regex_sql()}))")
      assert to_string(role) == "1"
    end
  end
end
