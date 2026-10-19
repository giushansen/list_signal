defmodule LS.HTTP.BusinessClassifierV7JunkTest do
  @moduledoc """
  Golden v7 (2026-10-19): 27 of 308 sampled "businesses" were not one and
  the junk detector flagged none. These are the templates it missed.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.BusinessClassifier

  defp page(title, body, extra \\ %{}) do
    Map.merge(%{http_title: title, body_text: body, http_status: 200, domain: "example.test"}, extra)
  end

  test "Newfold 'This site is under development' is a placeholder (apurposefulpaw, caliachey, bohren)" do
    assert BusinessClassifier.junk_reason(page("This site is under development", "This site is under development")) == "placeholder"
  end

  test "Hostinger default pages in English and Spanish are placeholders" do
    assert BusinessClassifier.junk_reason(page("Default page", "You Are All Set to Go! All you have to do now is upload your website files and start your journey.")) == "placeholder"
    assert BusinessClassifier.junk_reason(page("Página por defecto", "¡Ya todo está listo! Todo lo que tienes que hacer ahora es cargar los archivos de tu sitio web")) == "placeholder"
  end

  test "under-construction shells are placeholders, a builder named Under Construction Ltd is not" do
    assert BusinessClassifier.junk_reason(page("HomeUnderConstruction | Firebird Tech Forge", "Coming soon")) == "placeholder"
    assert BusinessClassifier.junk_reason(page("all-british-casino.com", "We're working on it! This site is currently under construction. Please check back soon.")) == "placeholder"
    assert BusinessClassifier.junk_reason(page("Under Construction Ltd | Builders in Leeds", "Family builders since 1987, extensions and loft conversions across Leeds, call for a free quote")) == ""
  end

  test "the Cloudflare Registrar landing page with no body is a placeholder" do
    assert BusinessClassifier.junk_reason(page("Cloudflare Registrar", "")) == "placeholder"
  end

  test "Aftermarket.com and Polish domain-sale offers are parked" do
    assert BusinessClassifier.junk_reason(page("Aftermarket.com | The domain tweetembed.com is for sale", "Buy now or make an offer")) == "parked"
    assert BusinessClassifier.junk_reason(page("Oferta sprzedaży domeny: otoaukcje.pl", "Domena na sprzedaż")) == "parked"
  end

  test "'<domain> is for sale' as the first line is parked even without the footer (teen-house.com)" do
    body = "teen-house.com is for sale. Why Self-Care is Crucial for Teens. As a teenager, life can be overwhelming."
    assert BusinessClassifier.junk_reason(page("Unlocking the Power of Self-Care for Teenagers at Home", body, %{domain: "teen-house.com"})) == "parked"
    assert BusinessClassifier.junk_reason(page("Unlocking the Power of Self-Care for Teenagers at Home", body, %{domain: "other.test"})) == ""
  end
end
