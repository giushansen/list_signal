defmodule LS.HTTP.People do
  @moduledoc """
  Named people on a page: who runs or represents the business. Pure.

  Measured 2026-10-26: `freshysites.com` had `/team/erin-cortazar` in its
  recorded pages and the crawler had visited two staff pages and kept
  nothing from them; there was no Person entity anywhere in the
  extraction. For a one-to-ten-person agency or a new store, the owner's
  name on the site is most of what a buyer wants and what an email
  pattern needs.

  Four sources, precision over recall, each bounded:

    * JSON-LD `Person` nodes, standalone or under `founder`, `employee`,
      `member`, `author`, `publisher`: name, jobTitle, email.
    * `mailto:` anchors whose visible text is a person's name.
    * Statutory imprint lines (DE/AT/CH, FR): "Geschäftsführer:",
      "Inhaber:", "Vertreten durch:", "Directeur de la publication :".
    * Team cards: a heading that is a name followed within a short
      distance by a title line (CEO, Founder, Owner, Director...).

  A name is two to four capitalised words, 5 to 60 characters, no digits,
  not a page label ("Contact Us", "Our Team"). At most #{10} people per
  page, deduplicated by name.
  """

  @max_people 10

  @jsonld_re ~r/<script[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>(.*?)<\/script>/is
  @mailto_anchor_re ~r/<a\b[^>]*href=["']mailto:([^"'?]+)[^"']*["'][^>]*>(.*?)<\/a>/is
  @tag_re ~r/<[^>]+>/
  @heading_re ~r/<h[2-5][^>]*>(.*?)<\/h[2-5]>\s*(?:<[^>]+>\s*){0,4}([^<]{2,80})/is
  @imprint_re ~r/(?:Geschäftsführer(?:in)?|Geschaeftsfuehrer|Inhaber(?:in)?|Vertreten durch|Vertretungsberechtigt(?:er|e)?|Verantwortlich(?:er)?|Directeur de la publication|Directrice de la publication|Gérant(?:e)?|Responsable de la publication|Représentant légal|Managing Director|Owner|Proprietor)[ \t]*:?[ \t]*([A-ZÀ-ÝÄÖÜ][\p{L}'’.-]+(?:[ \t]+(?:[A-ZÀ-ÝÄÖÜ][\p{L}'’.-]+|de|la|van|von|der|di|da|du|le))+)/u

  @titles ~w(ceo cto cfo coo cmo cpo cro cio founder co-founder cofounder owner co-owner president
             director managing partner principal head lead manager vp vice chief gm general
             proprietor chairman chairwoman chair gerente geschäftsführer inhaber gérant fondateur
             fondatrice directeur directrice responsable propietario fundador dueño titolare
             fondatore amministratore oprichter eigenaar directeur)

  # Lowercase name particles: "Jean-Pierre de la Fontaine", "Ludwig van Beethoven".
  @particles ~w(de la le du des del della di da van von der den ter te af av bin al el y e)

  @stop_names MapSet.new([
    "contact us", "our team", "about us", "read more", "learn more", "get in touch", "privacy policy",
    "terms of service", "cookie policy", "sign in", "log in", "shop now", "add to cart", "view all",
    "our story", "follow us", "join us", "free shipping", "new arrivals", "best sellers",
    "customer service", "meet the team", "who we are", "what we do", "why us", "case studies",
    "our work", "our services", "our mission", "our values", "our clients", "get started",
    "book now", "buy now", "subscribe now", "sign up", "our products", "latest news", "coming soon"
  ])

  # A word that makes a two-word string a label, not a person: "Email
  # Support" and "General Contact" came out of mailto anchors on
  # winabuilder.com in the first two hours (2026-10-27).
  @label_words ~w(the and for with your our free new shop sale us email mail support contact contacts
                  general sales team info enquiries enquiry inquiries office customer service services
                  press media careers jobs hello help billing admin orders order booking bookings
                  reservations marketing partnerships legal privacy accounts department desk line
                  manager management center centre dept hotline helpdesk address phone here click)

  # A heading that reads as a label rather than a person: starts with a
  # determiner or a verb a page uses on itself.
  @label_starts ~w(our the your my this these all new free best top latest more read learn get
                   shop buy book view sign log join follow meet why what who how contact about)

  @type person :: %{name: String.t(), title: String.t(), email: String.t(), source: String.t()}

  @doc "People found on one page. `source` labels the page for provenance (\"homepage\", \"about\", ...)."
  @spec extract(term(), String.t()) :: [person()]
  def extract(html, source \\ "homepage")

  def extract(html, source) when is_binary(html) and byte_size(html) > 0 do
    html = String.slice(html, 0, 400_000)

    (from_jsonld(html) ++ from_mailto(html) ++ from_imprint(html) ++ from_cards(html))
    |> Enum.map(&normalise/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.name)
    |> Enum.take(@max_people)
    |> Enum.map(&Map.put(&1, :source, source))
  rescue
    _ -> []
  end

  def extract(_, _), do: []

  @doc "True when `s` reads as a person's name under this module's rule."
  @spec name?(term()) :: boolean()
  def name?(s) when is_binary(s) do
    s = s |> String.trim() |> String.replace(~r/\s+/, " ")
    words = String.split(s, " ")

    String.length(s) in 5..60 and length(words) in 2..5 and
      not Regex.match?(~r/[0-9@\/|:;,()\[\]{}<>]/u, s) and
      Enum.all?(words, &(Regex.match?(~r/^[\p{Lu}][\p{L}'’.-]*$/u, &1) or &1 in @particles)) and
      Regex.match?(~r/^[\p{Lu}]/u, s) and
      not MapSet.member?(@stop_names, String.downcase(s)) and
      String.downcase(hd(words)) not in @label_starts and
      not Enum.any?(words, &(String.downcase(&1) in @label_words))
  end

  def name?(_), do: false

  # ── JSON-LD ───────────────────────────────────────────────────────────────

  defp from_jsonld(html) do
    @jsonld_re
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.flat_map(fn json ->
      case Jason.decode(json) do
        {:ok, data} -> persons(data, 0)
        _ -> []
      end
    end)
  rescue
    _ -> []
  end

  # Walk the graph a few levels deep; a Person is any node typed so.
  defp persons(_, depth) when depth > 4, do: []
  defp persons(list, depth) when is_list(list), do: Enum.flat_map(list, &persons(&1, depth))

  defp persons(%{} = node, depth) do
    here =
      if person_type?(node["@type"]) and is_binary(node["name"]),
        do: [%{name: node["name"], title: str(node["jobTitle"]), email: str(node["email"])}],
        else: []

    nested =
      ~w(founder founders employee employees member members author publisher @graph itemListElement contactPoint)
      |> Enum.flat_map(fn k -> persons(node[k], depth + 1) end)

    here ++ nested
  end

  defp persons(_, _), do: []

  defp person_type?("Person"), do: true
  defp person_type?(types) when is_list(types), do: "Person" in types
  defp person_type?(_), do: false

  defp str(v) when is_binary(v), do: String.trim(v)
  defp str(%{"@value" => v}) when is_binary(v), do: String.trim(v)
  defp str(_), do: ""

  # ── mailto anchors ────────────────────────────────────────────────────────

  defp from_mailto(html) do
    @mailto_anchor_re
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.flat_map(fn [email, inner] ->
      text = @tag_re |> Regex.replace(inner, "") |> LS.HTTP.Entities.decode() |> String.trim()
      if name?(text), do: [%{name: text, title: "", email: String.trim(email)}], else: []
    end)
  rescue
    _ -> []
  end

  # ── imprint ───────────────────────────────────────────────────────────────

  defp from_imprint(html) do
    text =
      html
      |> String.replace(~r/<\s*(br|\/p|\/div|\/li|\/tr|\/h[1-6]|\/td)\b[^>]*>/i, "\n")
      |> then(&Regex.replace(@tag_re, &1, " "))
      |> LS.HTTP.Entities.decode()

    @imprint_re
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&name?/1)
    |> Enum.map(&%{name: &1, title: "", email: ""})
  rescue
    _ -> []
  end

  # ── team cards ────────────────────────────────────────────────────────────

  defp from_cards(html) do
    @heading_re
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.flat_map(fn [heading, after_text] ->
      name = @tag_re |> Regex.replace(heading, "") |> LS.HTTP.Entities.decode() |> String.trim()
      title = after_text |> LS.HTTP.Entities.decode() |> String.trim() |> String.slice(0, 80)

      if name?(name) and title?(title), do: [%{name: name, title: title, email: ""}], else: []
    end)
  rescue
    _ -> []
  end

  defp title?(t) do
    words = t |> String.downcase() |> String.split(~r/[\s,&\/]+/, trim: true)
    length(words) in 1..8 and Enum.any?(words, &(&1 in @titles or String.starts_with?(&1, "co-")))
  end

  # ── normalise ─────────────────────────────────────────────────────────────

  defp normalise(%{name: name} = p) do
    name = name |> String.replace(~r/\s+/, " ") |> String.trim()

    if name?(name) do
      %{name: name, title: String.slice(p.title || "", 0, 80), email: String.downcase(String.slice(p.email || "", 0, 254))}
    end
  end

  defp normalise(_), do: nil
end
