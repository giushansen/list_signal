defmodule LS.Verification.IXBRL do
  @moduledoc """
  Pull a handful of numeric facts out of a Companies House accounts filing —
  inline XBRL (`.html`, `<ix:nonFraction>`) or plain XBRL (`.xml`).

  Deliberately regex-based and byte-oriented (no `u` flag): the filings are
  produced by hundreds of accounting packages, some in Latin-1 mislabelled as
  UTF-8, some with megabytes of inline CSS. An HTML parser would choke on the
  worst of them; a byte regex over a few well-formed tags does not. Everything
  extracted is re-validated as a number and range-capped, and any file we do
  not understand yields `%{}` — never a guessed figure.

  What we take, by local tag name (prefix ignored — FRS 102 uses `core:`,
  older filings `uk-gaap:`):

  * turnover — `TurnoverRevenue`, `TurnoverGrossOperatingRevenue`, `Turnover`
  * employees — `AverageNumberEmployeesDuringPeriod`

  Period: the fact must sit in a duration context WITHOUT a segment (whole
  entity, not a business line); the latest `endDate` among such facts is the
  current period and only its values are returned.
  """

  @turnover_tags ~w(TurnoverRevenue TurnoverGrossOperatingRevenue Turnover)
  @employees_tags ~w(AverageNumberEmployeesDuringPeriod)
  @max_bytes 30_000_000

  @type facts :: %{optional(:turnover) => number(), optional(:employees) => non_neg_integer(), optional(:period_end) => String.t()}

  @doc "Extract `%{turnover:, employees:, period_end:}` (any subset) from a filing body."
  @spec extract(binary()) :: facts()
  def extract(body) when is_binary(body) and byte_size(body) <= @max_bytes do
    contexts = contexts(body)
    facts = inline_facts(body) ++ xml_facts(body)

    facts
    |> Enum.map(fn {tag, ctx, val} -> {tag, Map.get(contexts, ctx), val} end)
    |> Enum.filter(fn {_, c, _} -> match?({end_date, false} when is_binary(end_date), c) end)
    |> case do
      [] ->
        %{}

      fs ->
        latest = fs |> Enum.map(fn {_, {e, _}, _} -> e end) |> Enum.max()
        current = Enum.filter(fs, fn {_, {e, _}, _} -> e == latest end)
        turnover = first_value(current, @turnover_tags)
        employees = first_value(current, @employees_tags)

        %{}
        |> put_if(:turnover, turnover && turnover >= 0 && turnover < 1.0e12 && turnover)
        |> put_if(:employees, employees && employees >= 0 && employees < 10_000_000 && round(employees))
        |> Map.put(:period_end, latest)
    end
  end

  def extract(_), do: %{}

  # ── contexts: id → {end_date | nil, has_segment?} ──

  @context_re ~r/<(?:xbrli:)?context\b[^>]*\bid\s*=\s*"([^"]+)"[^>]*>(.*?)<\/(?:xbrli:)?context>/s
  @end_re ~r/<(?:xbrli:)?endDate>\s*(\d{4}-\d{2}-\d{2})\s*<\/(?:xbrli:)?endDate>/
  @segment_re ~r/<(?:xbrli:)?segment\b/

  @doc false
  def contexts(body) do
    Regex.scan(@context_re, body)
    |> Map.new(fn [_, id, inner] ->
      end_date = case Regex.run(@end_re, inner) do
        [_, d] -> d
        _ -> nil
      end
      {id, {end_date, Regex.match?(@segment_re, inner)}}
    end)
  end

  # ── inline XBRL facts ──

  @nonfraction_re ~r/<ix:nonFraction\b([^>]*)>(.*?)<\/ix:nonFraction>/s

  defp inline_facts(body) do
    Regex.scan(@nonfraction_re, body)
    |> Enum.flat_map(fn [_, attrs, inner] ->
      with tag when is_binary(tag) <- attr(attrs, "name") |> local_name(),
           true <- tag in @turnover_tags or tag in @employees_tags,
           ctx when is_binary(ctx) <- attr(attrs, "contextRef"),
           {:ok, val} <- number(inner, attrs) do
        [{tag, ctx, val}]
      else
        _ -> []
      end
    end)
  end

  # ── plain XBRL facts: <prefix:Tag contextRef="..." ...>123</prefix:Tag> ──

  @xml_re ~r/<([A-Za-z0-9_-]+):(TurnoverRevenue|TurnoverGrossOperatingRevenue|Turnover|AverageNumberEmployeesDuringPeriod)\b([^>]*)>([^<]*)<\/\1:\2>/

  defp xml_facts(body) do
    Regex.scan(@xml_re, body)
    |> Enum.flat_map(fn [_, _prefix, tag, attrs, inner] ->
      with ctx when is_binary(ctx) <- attr(attrs, "contextRef"),
           {:ok, val} <- number(inner, attrs) do
        [{tag, ctx, val}]
      else
        _ -> []
      end
    end)
  end

  # ── helpers ──

  defp attr(attrs, name) do
    case Regex.run(~r/\b#{name}\s*=\s*"([^"]*)"/, attrs) do
      [_, v] -> v
      _ -> nil
    end
  end

  defp local_name(nil), do: nil
  defp local_name(name), do: name |> String.split(":") |> List.last()

  @doc "Parse an iXBRL number: strips tags, handles `format`, `scale`, `sign` (pure)."
  def number(inner, attrs \\ "") do
    text = inner |> String.replace(~r/<[^>]*>/, "") |> String.trim()
    format = attr(attrs, "format") || ""

    cond do
      String.contains?(format, "zero") or text in ["-", "—", "–", ""] ->
        if text == "", do: :error, else: {:ok, 0}

      true ->
        cleaned =
          if String.contains?(format, "numcommadecimal"),
            do: text |> String.replace(".", "") |> String.replace(" ", "") |> String.replace(",", "."),
            else: text |> String.replace(",", "") |> String.replace(" ", "")

        cleaned = String.replace(cleaned, ~r/[^0-9.\-]/, "")

        case Float.parse(cleaned) do
          {v, ""} ->
            scale = case Integer.parse(attr(attrs, "scale") || "0") do
              {s, _} when s in -6..12 -> s
              _ -> 0
            end
            v = v * :math.pow(10, scale)
            v = if attr(attrs, "sign") == "-", do: -v, else: v
            {:ok, v}

          _ -> :error
        end
    end
  end

  defp first_value(facts, tags) do
    Enum.find_value(tags, fn tag ->
      Enum.find_value(facts, fn {t, _, v} -> if t == tag, do: v end)
    end)
  end

  defp put_if(map, _k, v) when v in [nil, false], do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)
end
