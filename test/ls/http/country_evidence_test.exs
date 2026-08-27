defmodule LS.HTTP.CountryEvidenceTest do
  use ExUnit.Case, async: true

  alias LS.HTTP.CountryEvidence, as: CE

  # ==========================================================================
  # Added 2026-08-27. Country attribution had four signals and the two weakest
  # were deciding customer-visible answers:
  #
  #   intellatriage.com  Nashville nurse triage, labelled FR from a bad `fr`
  #                      language detection on an English page
  #   eapc-us.com        labelled FR because it sits on OVH
  #   geteino.com        same
  #   knowunity.fr       labelled FR; a Berlin company carrying German VAT
  #                      DE326705352 and a +49 number on its own site
  #
  # Measured on 566 live generic-TLD sites: the whole rule was 61.0% correct
  # on the rows it labelled. Page evidence cross-validated at 85.7%, against
  # 73.7% for language and 57.1% for BGP.
  # ==========================================================================
  describe "registration numbers carry their own country" do
    test "a German VAT number settles a French-looking site" do
      # The knowunity.fr case exactly: .fr domain, French content, German company.
      assert CE.detect(~s(<p>USt-IdNr: DE326705352</p>)) == {"DE", :registration}
    end

    test "French SIREN and VAT are recognised" do
      assert {"FR", :registration} = CE.detect("<p>SIREN : 552 100 554</p>")
      assert {"FR", :registration} = CE.detect("<p>TVA FR03552100554</p>")
    end

    test "other European registries are recognised" do
      assert {"GB", :registration} = CE.detect("<p>Company number 09876543</p>")
      assert {"IT", :registration} = CE.detect("<p>P.IVA 12345678901</p>")
      assert {"NL", :registration} = CE.detect("<p>KvK 12345678</p>")
      assert {"CH", :registration} = CE.detect("<p>CHE-123.456.789</p>")
      assert {"ES", :registration} = CE.detect("<p>CIF B12345678</p>")
    end

    test "registration outranks every weaker signal on the same page" do
      html = ~s(<html lang="fr"><a href="tel:+33123456789">x</a><p>HRB 92345</p></html>)
      assert {"DE", :registration} = CE.detect(html)
    end
  end

  describe "schema.org addressCountry" do
    test "a declared country code is read" do
      assert {"US", :schema} = CE.detect(~s({"addressCountry":"US"}))
    end

    test "a declared country name is read" do
      assert {"DE", :schema} = CE.detect(~s({"addressCountry":"Germany"}))
      assert {"GB", :schema} = CE.detect(~s({"addressCountry":"United Kingdom"}))
    end

    test "a nested Country object is read" do
      assert {"FR", :schema} = CE.detect(~s({"addressCountry":{"@type":"Country","name":"France"}}))
    end

    test "an unrecognised country value yields nothing rather than a guess" do
      assert CE.detect(~s({"addressCountry":"Wakanda"})) == {"", :none}
    end
  end

  describe "phone prefixes" do
    test "a tel: href resolves its country" do
      assert {"FR", :phone} = CE.detect(~s(<a href="tel:+33 1 23 45 67 89">Call</a>))
      assert {"DE", :phone} = CE.detect(~s(<a href="tel:+49 30 12345678">Call</a>))
    end

    test "longer prefixes win over shorter ones" do
      # +351 is Portugal and must not be read as +35.
      assert {"PT", :phone} = CE.detect(~s(<a href="tel:+351212345678">x</a>))
      assert {"IL", :phone} = CE.detect(~s(<a href="tel:+972212345678">x</a>))
    end

    test "a bare +1 in prose is NOT treated as a phone number" do
      # A page of prices produces plenty of these. Only declared numbers count.
      assert CE.detect("<p>Save +1 hour a day, from $49</p>") == {"", :none}
    end
  end

  describe "it refuses to guess" do
    test "a page stating no country yields nothing" do
      assert CE.detect("<html><body><h1>Welcome</h1></body></html>") == {"", :none}
    end

    test "language and hosting are deliberately not evidence here" do
      # Both are CountryInferrer's job, and both are weaker. This module must
      # not quietly re-introduce them.
      assert CE.detect(~s(<html lang="fr"><p>Bonjour</p></html>)) == {"", :none}
    end
  end

  describe "hostile input" do
    test "empty, nil and binary junk never raise" do
      assert CE.detect("") == {"", :none}
      assert CE.detect(nil) == {"", :none}
      assert {_, _} = CE.detect(<<0, 1, 2, 255, 254>>)
    end

    test "output is always empty or exactly two uppercase letters" do
      for html <- ["", "<p>x</p>", ~s({"addressCountry":"France"}), "<p>DE123456789</p>",
                   ~s(<a href="tel:+33123456789">x</a>), String.duplicate("+1 ", 5_000)] do
        {code, src} = CE.detect(html)
        assert code == "" or (byte_size(code) == 2 and code == String.upcase(code))
        assert src in CE.sources()
      end
    end

    test "a very large page does not hang" do
      big = String.duplicate("<div>filler</div>", 60_000) <> ~s(<p>SIREN 552100554</p>)
      assert {_, _} = CE.detect(big)
    end
  end
end
