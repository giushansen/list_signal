defmodule LS.Email.PlaceholderHostsTest do
  @moduledoc """
  2026-10-30, found by the campaign session after the first cleanup:
  contact@mysite.com (the Wix default) survived on 23,345 businesses and
  vous@exemple.fr on 4,243, because those hosts were in no list, so the
  address was never scored and never rejected. The off-domain hosts of the
  product table were then listed by count and every template host on it
  added; and the sweep of the product table now keeps only what
  classify/2 would publish, which also drops the site builders' support
  addresses (support@webador.com on 38,808 businesses) that rows compiled
  before 2026-10-26 still carried.
  """
  use ExUnit.Case, async: true

  alias LS.Clickhouse
  alias LS.HTTP.EmailClass

  test "the template hosts seen in the product table are placeholders" do
    for e <- ~w(contact@mysite.com vous@exemple.fr jean@exemple.com john@doe.com deine@email.de
                votre@email.fr je@email.nl su.email@empresa.com mymail@mailservice.com juan@ejemplo.com
                yhteydenotto@esimerkki.fi tu@correo.com hallo@beispiel.de mario@esempio.it
                kontakt@eksempel.dk jane@brand.com email@voorbeeld.nl contact@info.com janusz@037.pl) do
      assert EmailClass.classify(e, "acme.com") == :placeholder, e
    end
  end

  test "a site builder's support address is a third party and is not published" do
    assert EmailClass.classify("support@webador.com", "acme.nl") == :third_party
    assert EmailClass.classify("filler@godaddy.com", "acme.com") == :third_party
    refute :third_party in EmailClass.sellable()
  end

  test "the publishable SQL keeps own, free-mail and sister addresses and drops placeholders and third parties" do
    if match?({:ok, _}, Clickhouse.query_raw("SELECT 1")) do
      cases = [
        {"jane@acme.com", 1},
        {"info@shop.acme.com", 1},
        {"acme@gmail.com", 1},
        {"hello@acme.co", 1},
        {"contact@mysite.com", 0},
        {"support@webador.com", 0},
        {"vous@exemple.fr", 0},
        {"mail@gmail.com", 0},
        {"noreply@acme.com", 0}
      ]

      for {email, want} <- cases do
        {:ok, [[got]]} = Clickhouse.query_raw("SELECT toUInt8(#{EmailClass.publishable_sql("'#{email}'", "'acme.com'")})")
        assert to_string(got) == to_string(want), email
      end
    end
  end
end
