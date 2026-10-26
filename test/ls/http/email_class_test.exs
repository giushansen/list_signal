defmodule LS.HTTP.EmailClassTest do
  @moduledoc """
  2026-10-26, measured on live rows: form placeholders scraped as
  mailboxes, third-party addresses mixed in unlabeled, sister domains
  indistinguishable from leaks, and not one named address on twelve ICP
  businesses. Every address is classified at write time; only the
  sellable kinds reach http_emails.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.EmailClass

  test "the placeholders seen in the change feed are dropped" do
    for e <- ~w(name@company.com name@email.com john@mydomain.com your.email@yourfacility.org
                name@institution.com jane.doe@example.com email@domain.com yourname@yourdomain.com
                xxx@xxx.com enter.email@acme.com firstname.lastname@acme.com) do
      assert EmailClass.classify(e, "acme.com") == :placeholder, e
    end
  end

  test "a person's mailbox and a role mailbox on the domain are told apart" do
    assert EmailClass.classify("phillip@usfundsource.com", "usfundsource.com") == :named
    assert EmailClass.classify("Paul@HeckmannAnchors.com", "heckmannanchors.com") == :named
    assert EmailClass.classify("jamie@heckmannanchors.com", "www.heckmannanchors.com") == :named
    assert EmailClass.classify("hello@incrementors.com", "incrementors.com") == :role
    assert EmailClass.classify("info@onbudgetservices.com", "onbudgetservices.com") == :role
    assert EmailClass.classify("team@glacial.com", "glacial.com") == :role
    assert EmailClass.classify("office@slocumstudio.com", "slocumstudio.com") == :role
    assert EmailClass.classify("discover@freshysites.com", "freshysites.com") == :role
    assert EmailClass.classify("sales-eu@acme.co.uk", "acme.co.uk") == :role
    assert EmailClass.classify("support+billing@acme.com", "acme.com") == :role
  end

  test "a free-mail address is the owner and is kept; a third party is not sold" do
    assert EmailClass.classify("coveredbliss@gmail.com", "coveredbliss.com") == :free_mail
    assert EmailClass.classify("owner@outlook.fr", "boutique.fr") == :free_mail
    assert EmailClass.classify("press@gymshark.com", "becauseweponder.us") == :third_party
    assert EmailClass.classify("support@blockdaemon.com", "startblockdaemon.com") == :third_party
    assert EmailClass.classify("privacy@invesp.com", "invespcro.com") == :third_party
  end

  test "a sister domain is the same organisation" do
    assert EmailClass.classify("hello@acme.co", "acme.com") == :sister
    assert EmailClass.classify("info@acme.co.uk", "acme.com") == :sister
    assert EmailClass.classify("jane@acme.de", "shop.acme.com") == :sister
    refute EmailClass.classify("jane@acmeconsulting.com", "acme.com") == :sister
  end

  test "sellable_emails keeps the sellable kinds in order and drops the rest, hostile input included" do
    emails = ["Hello@Acme.com", "name@company.com", "press@gymshark.com", "owner@gmail.com", "jane@acme.co", "", nil, 42, "not-an-email"]
    assert EmailClass.sellable_emails(emails, "acme.com") == ["hello@acme.com", "owner@gmail.com", "jane@acme.co"]
    assert EmailClass.sellable_emails([], "acme.com") == []
    assert EmailClass.sellable_emails(nil, "acme.com") == []
    assert EmailClass.classify(nil, "acme.com") == :placeholder
    assert EmailClass.classify("@", "acme.com") == :placeholder
  end

  test "the naming pattern is read from the named addresses, roles excluded" do
    assert EmailClass.email_pattern(["phillip@x.com", "joseph@x.com", "michael@x.com", "ashley@x.com", "info@x.com"]) == {"{first}", 4}
    assert EmailClass.email_pattern(["jane.doe@x.com", "john.smith@x.com", "hello@x.com"]) == {"{first}.{last}", 2}
    assert EmailClass.email_pattern(["jsmithson@x.com", "rwilliamson@x.com"]) == {"{first}{last}", 2}
    assert EmailClass.email_pattern(["info@x.com", "sales@x.com"]) == nil
    assert EmailClass.email_pattern([]) == nil
    assert EmailClass.email_pattern(nil) == nil
  end

  test "the SQL form of the rule names the free-mail list and the on-domain and sister tests" do
    sql = EmailClass.sellable_sql()
    assert sql =~ "on_domain = 1"
    assert sql =~ "'gmail.com'"
    assert sql =~ "splitByChar('.', splitByChar('@', email)[2])[1] = splitByChar('.', domain)[1]"
    refute sql =~ "\n"
  end
end
