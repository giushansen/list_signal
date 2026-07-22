defmodule LS.DNS.SPF do
  @moduledoc """
  Parse an SPF record into a display tier (RFC 7208).

  Takes the pipe-joined `dns_txt` column, finds the `v=spf1` record and grades it.

  A record authorises senders through *mechanisms* (`include:`, `a`, `mx`,
  `ip4:`, `ip6:`, `exists:`, `ptr`) and ends with an `all` mechanism whose
  qualifier states the policy for everyone else: `-all` fail, `~all` softfail,
  `?all` neutral, `+all` pass (i.e. no protection at all).

  Alternatively a record may hand the whole policy to another domain with the
  `redirect=` modifier — this is what facebook.com does:

      v=spf1 redirect=_spf.facebook.com

  Counting only `include:` and `all`, as the first version did, graded that
  record "Weak — no qualifier" even though it is a perfectly standard,
  fully-enforced setup.
  """

  @type tier :: :gold | :silver | :bronze
  @type t :: %{tier: tier, emoji: String.t(), summary: String.t()}

  # Mechanisms that authorise senders, per RFC 7208 §5. Matched against a single
  # whitespace-separated term with its qualifier already stripped.
  @mechanism_re ~r/^(include:|exists:|ip4:|ip6:|ptr|a$|a[:\/]|mx$|mx[:\/])/i

  @doc "Parse the SPF record out of a pipe-joined TXT bundle. Returns nil when there is none."
  @spec parse(String.t() | nil) :: t | nil
  def parse(nil), do: nil
  def parse(""), do: nil

  def parse(txt) when is_binary(txt) do
    txt
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&String.starts_with?(&1, "v=spf1"))
    |> grade()
  end

  def parse(_), do: nil

  defp grade(nil), do: nil

  defp grade(record) do
    terms = terms(record)

    mechanisms = Enum.count(terms, &mechanism?/1)
    redirect = Enum.find_value(terms, &redirect_target/1)
    policy = Enum.find_value(terms, &all_policy/1)

    describe(mechanisms, redirect, policy)
  end

  # Term-by-term rather than one big regex: SPF terms are whitespace separated,
  # and a regex that anchors on the preceding space swallows the separator and
  # undercounts adjacent mechanisms.
  defp terms(record) do
    case record |> String.split(~r/\s+/, trim: true) |> Enum.drop(1) do
      [] -> record |> respace() |> String.split(~r/\s+/, trim: true) |> Enum.drop(1)
      terms -> terms
    end
  end

  # A TXT record over 255 bytes is transmitted as several strings that must be
  # concatenated; some resolvers join them with no separator, so we see records
  # like "v=spf1include:spf.mail.qq.com~all". Put the boundaries back before the
  # unambiguous prefixes so those still grade correctly.
  defp respace(record) do
    record
    |> String.replace(~r/([+\-~?]?(?:include:|exists:|redirect=|ip4:|ip6:))/i, " \\1")
    |> String.replace(~r/([+\-~?]?all)$/i, " \\1")
  end

  defp mechanism?(term), do: Regex.match?(@mechanism_re, strip_qualifier(term))

  defp redirect_target(term) do
    case String.split(term, "=", parts: 2) do
      [modifier, target] -> if String.downcase(modifier) == "redirect", do: target
      _ -> nil
    end
  end

  defp all_policy(term) do
    {qualifier, rest} = String.split_at(term, 1)

    cond do
      String.downcase(term) == "all" -> :pass_all
      String.downcase(rest) != "all" -> nil
      qualifier == "-" -> :fail
      qualifier == "~" -> :softfail
      qualifier == "?" -> :neutral
      qualifier == "+" -> :pass_all
      true -> nil
    end
  end

  defp strip_qualifier(<<q::binary-1, rest::binary>>) when q in ["+", "-", "~", "?"], do: rest
  defp strip_qualifier(term), do: term

  # `+all` authorises the entire internet — the one genuinely bad configuration.
  defp describe(_mechanisms, _redirect, :pass_all),
    do: badge(:bronze, "⚠", "Ineffective — +all authorises every sender")

  # A redirect= hands the policy to another domain; the enforcement lives there.
  defp describe(0, target, _policy) when is_binary(target) do
    badge(:silver, "✓", "Delegated — policy redirected to #{target}")
  end

  defp describe(mechanisms, target, _policy) when is_binary(target) do
    badge(:gold, "⭐", "Strong — #{mechanisms} #{plural(mechanisms)} + redirect to #{target}")
  end

  defp describe(mechanisms, nil, :fail) when mechanisms >= 3,
    do: badge(:gold, "🏆", "Advanced — #{mechanisms} mechanisms, strict (-all)")

  defp describe(mechanisms, nil, policy) when mechanisms >= 2 and policy in [:fail, :softfail],
    do: badge(:gold, "⭐", "Strong — #{mechanisms} mechanisms, #{strictness(policy)}")

  defp describe(mechanisms, nil, policy) when mechanisms >= 1 and policy in [:fail, :softfail],
    do: badge(:silver, "✓", "Standard — #{mechanisms} #{plural(mechanisms)}, #{strictness(policy)}")

  # No senders authorised at all, but a hard policy: a valid "this domain never
  # sends mail" record.
  defp describe(0, nil, :fail),
    do: badge(:silver, "✓", "No-mail domain — nothing authorised, strict (-all)")

  defp describe(0, nil, :softfail),
    do: badge(:bronze, "⚠", "No-mail domain — nothing authorised, soft (~all)")

  defp describe(mechanisms, nil, :neutral),
    do: badge(:bronze, "⚠", "Neutral — #{mechanisms} #{plural(mechanisms)}, ?all enforces nothing")

  # No `all`, no `redirect`: receivers default to neutral, so the record protects
  # nothing. This is the only case that really deserved the old "weak" label.
  defp describe(mechanisms, nil, nil),
    do: badge(:bronze, "⚠", "Incomplete — #{mechanisms} #{plural(mechanisms)}, no all mechanism")

  defp strictness(:fail), do: "strict (-all)"
  defp strictness(:softfail), do: "soft (~all)"

  defp plural(1), do: "mechanism"
  defp plural(_), do: "mechanisms"

  defp badge(tier, emoji, summary), do: %{tier: tier, emoji: emoji, summary: summary}
end
