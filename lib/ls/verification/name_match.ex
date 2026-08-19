defmodule LS.Verification.NameMatch do
  @moduledoc """
  Normalise a legal company name into the key used by the `name_country`
  match tier.

  `"Acme Widgets Ltd."` → `"acmewidgets"`, `"SARL Les Éditions Dupont"` →
  `"leseditionsdupont"`. The key is compared to the first label of our
  registrable domains (`LS.Verification.Domain.label_key/1`), so it must be
  alphanumeric only. Legal-form words are stripped from both ends because
  registries print them and domains do not; nothing else is stripped —
  "Group", "Holdings", "Services" stay because domains keep them
  (`acmegroup.com`).

  Short keys are refused (`usable?/1`): `"abc"` would match `abc.co.uk` and
  be wrong far more often than right; the tier is precision-first.
  """

  @min_len 6

  # Legal forms, lower-case, as tokens. Kept small and obvious on purpose:
  # every entry is one that appears at the end (or start) of registry names.
  # "and"/"cie" are here only so "GmbH & Co. KG" / "et Cie" peel off layer by
  # layer from the END; they are never stripped from the front.
  @legal_forms ~w(
    ltd limited plc llp llc lp inc incorporated corp corporation co company
    gmbh ag kg ug ohg mbh ev
    sarl sas sasu sa snc sci eurl scop scp sem selarl
    bv nv vof cv
    oy oyj ab as asa aps hf ehf
    spa srl srls sapa scarl snc ss
    sl slu sll sc scoop
    pty pte kk yk gk llc bhd sdn
    unipessoal lda ltda eireli
    limitada anonyme anonima
    and et cie
  )
  @legal_set MapSet.new(@legal_forms)

  @doc "Alphanumeric key of a legal name; `\"\"` for anything unusable."
  @spec key(term()) :: String.t()
  def key(name) when is_binary(name) do
    name
    |> String.slice(0, 500)
    |> String.downcase()
    |> strip_accents()
    |> String.replace("&", " and ")
    # "S.A.", "B.V.", "L.L.C." → "sa", "bv", "llc" so they read as one form token
    |> String.replace(~r/\b((?:[a-z]\.){2,})/, fn dotted -> String.replace(dotted, ".", "") <> " " end)
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.split(" ", trim: true)
    |> strip_legal_forms()
    |> Enum.join()
  end

  def key(_), do: ""

  @doc "Whether a key is specific enough to link on."
  @spec usable?(String.t()) :: boolean()
  def usable?(key) when is_binary(key), do: String.length(key) >= @min_len
  def usable?(_), do: false

  defp strip_accents(s) do
    s
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/[øØ]/u, "o")
    |> String.replace(~r/[æÆ]/u, "ae")
    |> String.replace(~r/[œŒ]/u, "oe")
    |> String.replace(~r/[ßẞ]/u, "ss")
    |> String.replace(~r/[łŁ]/u, "l")
    |> String.replace(~r/[đĐ]/u, "d")
  end

  # Forms that registries print BEFORE the name (French/Spanish/Italian
  # style: "SARL Dupont", "SA Nestlé"). English forms never lead —
  # "Company Store Ltd" is the Company Store, so only these may be dropped
  # from the front.
  @leading_forms MapSet.new(~w(the sarl sas sasu sa snc sci eurl scop selarl scp sem sl slu sll srl spa))

  # Drop legal-form tokens from the ends only ("Co" inside "Coca Cola Co" is
  # a suffix; inside "Co-operative Bank" it is part of the name and stays).
  defp strip_legal_forms(tokens) do
    tokens
    |> Enum.drop_while(&(&1 in @leading_forms))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 in @legal_set))
    |> Enum.reverse()
  end
end
