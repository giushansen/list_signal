defmodule LS.HTTP.PeopleTest do
  @moduledoc """
  2026-10-26: freshysites.com had two staff pages in http_pages and nothing
  extracted from them; there was no Person entity. Four conservative
  sources, bounded, precision over recall.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.People

  test "a JSON-LD Person, standalone or under founder, is read with title and email" do
    html = """
    <html><head><script type="application/ld+json">
    {"@context":"https://schema.org","@type":"Organization","name":"Freshy","founder":{"@type":"Person","name":"Erin Cortazar","jobTitle":"Founder","email":"erin@freshysites.com"}}
    </script><script type="application/ld+json">
    {"@type":"Person","name":"Antonella Membreno","jobTitle":"Designer"}
    </script></head><body></body></html>
    """

    assert [
             %{name: "Erin Cortazar", title: "Founder", email: "erin@freshysites.com", source: "about"},
             %{name: "Antonella Membreno", title: "Designer", email: "", source: "about"}
           ] = People.extract(html, "about")
  end

  test "a mailto anchor whose text is a name is a person; one whose text is the address is not" do
    html = ~s(<a href="mailto:paul@heckmannanchors.com">Paul Heckmann</a> <a href="mailto:info@x.com">info@x.com</a> <a href="mailto:j@x.com">Contact Us</a>)
    assert [%{name: "Paul Heckmann", email: "paul@heckmannanchors.com"}] = People.extract(html)
  end

  test "imprint lines name the managing director" do
    html = "<p>Impressum</p><p>Busemann GmbH<br>Geschäftsführer: Jürgen Busemann<br>Registergericht Osnabrück</p><p>Directeur de la publication : Marie Dupont</p>"
    names = People.extract(html, "legal") |> Enum.map(& &1.name)
    assert "Jürgen Busemann" in names
    assert "Marie Dupont" in names
  end

  test "a team card is a name heading followed by a title line" do
    html = """
    <div class="team"><h3>Erin Cortazar</h3><p class="role">Founder &amp; CEO</p></div>
    <div class="team"><h3>Our Services</h3><p>Web design for small business</p></div>
    <div class="team"><h3>Antonella Membreno</h3><span>Lead Designer</span></div>
    <h2>Read More</h2><p>Director of nothing</p>
    """
    people = People.extract(html, "about")
    assert Enum.map(people, &{&1.name, &1.title}) == [{"Erin Cortazar", "Founder & CEO"}, {"Antonella Membreno", "Lead Designer"}]
  end

  test "the name rule refuses labels, numbers, single words and long strings" do
    assert People.name?("Erin Cortazar")
    assert People.name?("Jean-Pierre de la Fontaine")
    refute People.name?("Contact Us")
    refute People.name?("Erin")
    refute People.name?("erin cortazar")
    refute People.name?("Erin Cortazar 2024")
    refute People.name?("Free Shipping Worldwide")
    refute People.name?(String.duplicate("Ab ", 40))
    refute People.name?(nil)
  end

  test "hostile input never raises and the list is bounded and deduplicated" do
    assert People.extract(nil) == []
    assert People.extract("") == []
    assert People.extract("<script type=\"application/ld+json\">{not json</script>") == []
    firsts = ~w(Ada Alan Grace Linus Edsger Barbara Donald Ken Dennis Margaret Tim Brian)
    lasts = ~w(Lovelace Turing Hopper Torvalds Dijkstra Liskov Knuth Thompson Ritchie Hamilton Berners Kernighan)
    many = for f <- firsts, l <- lasts, into: "", do: "<h3>#{f} #{l}</h3><p>CEO</p>"
    refute People.extract(many) == []
    assert length(People.extract(many)) <= 10
    dup = "<h3>Ada Lovelace</h3><p>Founder</p><h3>Ada Lovelace</h3><p>CEO</p>"
    assert length(People.extract(dup)) == 1
  end
end
