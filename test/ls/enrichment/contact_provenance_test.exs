defmodule LS.Enrichment.ContactProvenanceTest do
  use ExUnit.Case, async: true

  alias LS.Enrichment.Agent

  # ==========================================================================
  # Added 2026-08-26 with the imprint-page work.
  #
  # Imprint pages are legally required to name a contact and routinely name
  # someone ELSE'S: the agency that built the site, the host, and German
  # statutory arbitration boards. Measured on German business domains: 40.6%
  # yield an address from a second page but only 28.1% yield one on the
  # business's OWN domain — so 12.5% of them would ship as "this company's
  # email" while belonging to a third party.
  #
  # The rule is flag-not-filter: off-domain addresses stay (the agency link is
  # itself signal, and for a tiny business a freemail address is often the only
  # reachable human), but they are marked so a buyer-facing surface can exclude
  # them.
  # ==========================================================================
  describe "on_domain?/2 (imprint pages carry third-party addresses)" do
    test "an address on the business's own domain is on-domain" do
      assert Agent.on_domain?("info@acme.de", "acme.de")
    end

    test "a subdomain of the business counts as on-domain" do
      assert Agent.on_domain?("kontakt@mail.acme.de", "acme.de")
    end

    test "www on the business domain does not break the match" do
      assert Agent.on_domain?("info@acme.de", "www.acme.de")
    end

    test "the web agency's address on an imprint is NOT on-domain" do
      # The real failure: ellengrey.de's imprint lists info@egmmedien.de,
      # its agency. Attributing that to the business is simply wrong.
      refute Agent.on_domain?("info@egmmedien.de", "ellengrey.de")
    end

    test "a statutory arbitration board is NOT on-domain" do
      # Boilerplate on a large share of German imprints.
      refute Agent.on_domain?("schlichtungsstelle@s-d-r.org", "richtarsky.de")
    end

    test "a freemail address is NOT on-domain" do
      refute Agent.on_domain?("natalieleo97@gmail.com", "nattynaturalcreations.com")
    end

    test "a domain that merely ENDS WITH the business name is not a subdomain" do
      # "notacme.de" ends with "acme.de" as a string but is a different site.
      # A naive String.ends_with?/2 without the dot would call this on-domain.
      refute Agent.on_domain?("info@notacme.de", "acme.de")
    end

    test "hostile and malformed input never raises" do
      for {email, domain} <- [
            {"", "acme.de"},
            {"no-at-sign", "acme.de"},
            {"a@b@c", "acme.de"},
            {"info@acme.de", ""},
            {"INFO@ACME.DE", "Acme.De"}
          ] do
        assert is_boolean(Agent.on_domain?(email, domain))
      end

      # Case must not decide the answer.
      assert Agent.on_domain?("INFO@ACME.DE", "Acme.De")
      refute Agent.on_domain?(nil, "acme.de")
    end
  end
end
