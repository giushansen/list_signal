defmodule LS.HTTP.PageBlocks do
  @moduledoc """
  Splits a page into what the product keeps of it: head facts, the header
  and navigation, the body as ordered blocks, the footer as ordered blocks,
  the raw JSON-LD, and the scalars a buyer filters on (data model v2,
  2026-10-01).

  Why blocks and not the first 500 characters: the 500-character snippet the
  pipeline stored until now is, on a median page, the navigation menu and a
  cookie banner ("Skip to content Home Shop Blog About Contact Log in
  Cart"). It caught an email on 7% of homepages, a phone on 10%, a postal
  address on 3%, while the footer alone carries them on 23%, 13% and 10%.
  Measured on 394 production homepages, 2026-09-26.

  A block is `{tag, text}` for h1..h6, p, li, td, dt, dd, blockquote and
  figcaption, in document order, whitespace collapsed, consecutive
  duplicates dropped. The region is decided by the enclosing element:
  header/nav/role=banner is the header, footer/role=contentinfo/class
  footer is the footer, everything else is the body. Hidden nodes
  (hidden, aria-hidden, dialog, drawer, cart, cookie banners), scripts,
  styles, templates and SVG never emit text: the first sample row's body
  opened with "Your cart is empty" from a hidden cart drawer.

  Caps, from the same sample (p99 was 273 body blocks and 11.8 KB): 60
  header blocks at 200 bytes, 120 body blocks at 400 bytes, 60 footer blocks
  at 400 bytes, JSON-LD at 16 KB. Everything here is a pure function over a
  binary; hostile input returns empty parts, never raises.
  """

  @block_tags ~w(h1 h2 h3 h4 h5 h6 p li td th dt dd blockquote figcaption summary)
  @skip_tags ~w(script style noscript template svg iframe select option textarea)
  @void_tags ~w(area base br col embed hr img input link meta param source track wbr)
  @header_tags ~w(header nav)
  @footer_tags ~w(footer)

  @caps %{header: {60, 200}, body: {120, 400}, footer: {60, 400}}
  @jsonld_cap 16_000
  @max_input 3_000_000

  @hidden_re ~r/(?:^|\s)hidden(?:\s|=|$)|aria-hidden=["']?true|role=["']?dialog|class=["'][^"']*\b(?:drawer|cart-drawer|modal|cookie-banner|cookie-consent|cookie-notice|offcanvas|visually-hidden|sr-only)\b/i
  @tag_re ~r/<\/?([a-zA-Z][a-zA-Z0-9]*)([^>]*)>/
  @comment_re ~r/<!--.*?-->/s
  @ws_re ~r/\s+/
  @social_re ~r/https?:\/\/(?:www\.)?(?:facebook\.com|instagram\.com|linkedin\.com|twitter\.com|x\.com|youtube\.com|tiktok\.com|pinterest\.com|threads\.net|github\.com)\/[A-Za-z0-9_.\/-]{2,80}/i
  @phone_re ~r/(?:\+\d{1,3}[\s.-]?)?\(?\d{2,4}\)?[\s.-]\d{2,4}[\s.-]\d{2,4}(?:[\s.-]\d{2,4})?/
  @company_id_re ~r/\b(?:VAT|TVA|P\.?IVA|USt-?IdNr|UID|BTW|NIF|CIF|SIREN|SIRET|RCS|Company\s+No\.?|Company\s+Number|Reg(?:istration)?\.?\s+No\.?|KvK|CVR|Org\.?\s*nr|ABN|ACN|EIN)\s*[:.]?\s*([A-Z]{0,2}[\s-]?[0-9][0-9A-Z\s.-]{6,18}[0-9A-Z])/i
  @address_re ~r/\b\d{1,5}\s+[A-Z][A-Za-z'.-]+(?:\s+[A-Z][A-Za-z'.-]+){0,3}\s+(?:Street|St\.?|Avenue|Ave\.?|Road|Rd\.?|Boulevard|Blvd\.?|Lane|Ln\.?|Drive|Dr\.?|Way|Suite|Ste\.?|Place|Court|Rue|Strasse|Straße|Platz|Via|Calle)\b[^|\n]{0,80}/

  @type block :: {String.t(), String.t()}
  @type t :: %{
          header: [block()],
          body: [block()],
          footer: [block()],
          jsonld: String.t(),
          social_links: [String.t()],
          phone: String.t(),
          address: String.t(),
          company_id: String.t(),
          nav_links: [String.t()]
        }

  @doc "Split a page. Never raises; a non-binary or empty body returns empty parts."
  @spec extract(term()) :: t()
  def extract(html) when is_binary(html) and byte_size(html) > 0 and byte_size(html) <= @max_input do
    html = Regex.replace(@comment_re, html, " ")
    {blocks, links, jsonld} = walk(html)

    header = Enum.reverse(blocks.header) |> cap(:header)
    body = Enum.reverse(blocks.body) |> cap(:body)
    footer = Enum.reverse(blocks.footer) |> cap(:footer)
    footer_text = Enum.map_join(footer, " ", &elem(&1, 1))
    all_links = Enum.reverse(links)
    jsonld = jsonld |> Enum.reverse() |> Enum.join("\n") |> String.slice(0, @jsonld_cap)

    %{
      header: header,
      body: body,
      footer: footer,
      jsonld: jsonld,
      social_links: social_links(all_links, jsonld),
      phone: phone(footer_text, jsonld),
      address: address(footer_text, jsonld),
      company_id: company_id(footer_text),
      nav_links: nav_links(blocks.nav_texts)
    }
  rescue
    _ -> empty()
  end

  def extract(_), do: empty()

  @doc "The row fields the worker writes for one page, as `LS.Cluster.Inserter` expects them."
  @spec page_row(t(), String.t(), String.t()) :: map()
  def page_row(parts, page_kind, fetched_at) do
    %{
      page_kind: page_kind,
      http_fetched_at: fetched_at,
      http_header_tags: Enum.map(parts.header, &elem(&1, 0)),
      http_header_texts: Enum.map(parts.header, &elem(&1, 1)),
      http_body_tags: Enum.map(parts.body, &elem(&1, 0)),
      http_body_texts: Enum.map(parts.body, &elem(&1, 1)),
      http_footer_tags: Enum.map(parts.footer, &elem(&1, 0)),
      http_footer_texts: Enum.map(parts.footer, &elem(&1, 1)),
      http_jsonld: parts.jsonld
    }
  end

  defp empty,
    do: %{header: [], body: [], footer: [], jsonld: "", social_links: [], phone: "", address: "", company_id: "", nav_links: []}

  # ── the walk ─────────────────────────────────────────────────────────────
  #
  # A single pass over the tag stream with a small stack: no DOM, no parser
  # dependency. The stack carries, per open element, its tag and whether it
  # opened a region or a hidden subtree; text between tags goes to the
  # current block when one is open and not hidden.

  defp walk(html) do
    state = %{
      stack: [],
      region: [],
      hidden: 0,
      skip: 0,
      cur: nil,
      blocks: %{header: [], body: [], footer: [], nav_texts: []},
      links: [],
      jsonld: [],
      in_jsonld: false,
      in_a: nil
    }

    state = scan(html, 0, state)
    {state.blocks, state.links, state.jsonld}
  end

  defp scan(html, pos, state) do
    case Regex.run(@tag_re, html, offset: pos, return: :index) do
      nil ->
        text(state, binary_part(html, pos, byte_size(html) - pos))

      [{tstart, tlen}, {nstart, nlen}, {astart, alen}] ->
        state = text(state, binary_part(html, pos, tstart - pos))
        tag = html |> binary_part(nstart, nlen) |> String.downcase()
        attrs = binary_part(html, astart, alen)
        closing? = binary_part(html, tstart, 2) == "</"
        self_closing? = String.ends_with?(attrs, "/")

        state =
          cond do
            closing? -> close(state, tag)
            tag in @void_tags or self_closing? -> void(state, tag, attrs)
            true -> open(state, tag, attrs)
          end

        scan(html, tstart + tlen, state)
    end
  end

  defp open(state, tag, attrs) do
    cond do
      tag in @skip_tags ->
        if tag == "script" and attrs =~ ~r/application\/ld\+json/i do
          %{state | stack: [{tag, :jsonld} | state.stack], in_jsonld: true}
        else
          %{state | stack: [{tag, :skip} | state.stack], skip: state.skip + 1}
        end

      true ->
        {region, hidden?} = classify(tag, attrs)

        state =
          if tag == "a" do
            href = attr(attrs, "href")
            %{state | links: [href | state.links], in_a: {state_region(state), []}}
          else
            state
          end

        kind =
          cond do
            hidden? -> :hidden
            region -> {:region, region}
            true -> :plain
          end

        state = %{state | stack: [{tag, kind} | state.stack]}
        state = if hidden?, do: %{state | hidden: state.hidden + 1}, else: state
        state = if region, do: %{state | region: [region | state.region]}, else: state

        if tag in @block_tags and state.skip == 0 and state.hidden == 0 and state.cur == nil do
          %{state | cur: {state_region(state), tag, []}}
        else
          state
        end
    end
  end

  defp void(state, _tag, _attrs), do: state

  defp close(state, tag) do
    case pop(state.stack, tag, []) do
      nil ->
        state

      {popped, rest} ->
        state = Enum.reduce(popped, %{state | stack: rest}, &unwind/2)
        state = if tag == "a", do: finish_link(state), else: state
        if state.cur != nil and elem(state.cur, 1) == tag, do: flush(state), else: state
    end
  end

  defp pop([], _tag, _acc), do: nil
  defp pop([{tag, _} = top | rest], tag, acc), do: {Enum.reverse([top | acc]), rest}
  defp pop([top | rest], tag, acc), do: pop(rest, tag, [top | acc])

  defp unwind({_tag, :skip}, state), do: %{state | skip: max(state.skip - 1, 0)}
  defp unwind({_tag, :jsonld}, state), do: %{state | in_jsonld: false}
  defp unwind({_tag, :hidden}, state), do: %{state | hidden: max(state.hidden - 1, 0)}
  defp unwind({_tag, {:region, r}}, state), do: %{state | region: List.delete(state.region, r)}

  defp unwind({tag, :plain}, state) do
    if state.cur != nil and elem(state.cur, 1) == tag, do: flush(state), else: state
  end

  defp text(state, ""), do: state

  defp text(%{in_jsonld: true} = state, t), do: %{state | jsonld: prepend_jsonld(state.jsonld, t)}

  defp text(%{skip: s} = state, _t) when s > 0, do: state

  defp text(state, t) do
    state =
      case state.cur do
        {region, tag, parts} -> %{state | cur: {region, tag, [t | parts]}}
        nil -> state
      end

    case state.in_a do
      {region, parts} when region == :header -> %{state | in_a: {region, [t | parts]}}
      _ -> state
    end
  end

  defp prepend_jsonld([h | t], chunk), do: [h <> chunk | t]
  defp prepend_jsonld([], chunk), do: [chunk]

  defp finish_link(%{in_a: {:header, parts}} = state) do
    t = parts |> Enum.reverse() |> Enum.join() |> clean()
    texts = if t != "" and byte_size(t) <= 60, do: [t | state.blocks.nav_texts], else: state.blocks.nav_texts
    %{state | in_a: nil, blocks: %{state.blocks | nav_texts: texts}}
  end

  defp finish_link(state), do: %{state | in_a: nil}

  defp flush(%{cur: {region, tag, parts}} = state) do
    t = parts |> Enum.reverse() |> Enum.join() |> clean()
    list = Map.fetch!(state.blocks, region)

    list =
      cond do
        byte_size(t) < 3 -> list
        match?([{_, ^t} | _], list) -> list
        true -> [{tag, t} | list]
      end

    %{state | cur: nil, blocks: Map.put(state.blocks, region, list)}
  end

  defp flush(state), do: state

  # Which region an element opens, and whether it hides its subtree.
  defp classify(tag, attrs) do
    role = attr(attrs, "role")
    cls = " " <> String.downcase(attr(attrs, "class")) <> " "
    id = String.downcase(attr(attrs, "id"))

    region =
      cond do
        tag in @footer_tags or role == "contentinfo" or id == "footer" or
            (tag in ~w(div section) and (String.contains?(cls, " footer ") or String.contains?(cls, "site-footer"))) ->
          :footer

        tag in @header_tags or role in ~w(banner navigation) or id == "header" or
            (tag == "div" and (String.contains?(cls, "site-header") or String.contains?(cls, " header "))) ->
          :header

        true ->
          nil
      end

    hidden? = Regex.match?(@hidden_re, attrs) or tag == "dialog"
    {region, hidden?}
  end

  defp state_region(%{region: [r | _]}), do: r
  defp state_region(_), do: :body

  defp attr(attrs, name) do
    case Regex.run(~r/\b#{name}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i, attrs) do
      [_, v] -> v
      [_, "", v] -> v
      [_, "", "", v] -> v
      _ -> ""
    end
  end

  defp clean(t) do
    t
    |> decode_entities()
    |> String.replace(@ws_re, " ")
    |> String.trim()
  end

  defp decode_entities(t) do
    t
    |> String.replace("&amp;", "&")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&#160;", " ")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  defp cap(blocks, region) do
    {n, bytes} = Map.fetch!(@caps, region)

    blocks
    |> Enum.take(n)
    |> Enum.map(fn {tag, t} -> {tag, truncate(t, bytes)} end)
  end

  defp truncate(t, bytes) when byte_size(t) <= bytes, do: t

  defp truncate(t, bytes) do
    # Cut on a character boundary: a UTF-8 sequence split in two is invalid
    # text and the inserter would strip it.
    t |> String.slice(0, bytes) |> trim_to_bytes(bytes)
  end

  defp trim_to_bytes(t, bytes) when byte_size(t) <= bytes, do: t
  defp trim_to_bytes(t, bytes), do: trim_to_bytes(String.slice(t, 0, String.length(t) - 1), bytes)

  # ── the scalars ──────────────────────────────────────────────────────────

  defp social_links(links, jsonld) do
    from_links = Enum.filter(links, &Regex.match?(@social_re, &1))
    from_jsonld = Regex.scan(@social_re, jsonld) |> List.flatten()

    (from_links ++ from_jsonld)
    |> Enum.map(&String.trim_trailing(&1, "/"))
    |> Enum.reject(&(&1 =~ ~r/\/(?:sharer|share|intent|plugins|dialog)\b/i))
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp phone(footer_text, jsonld) do
    case Regex.run(~r/"telephone"\s*:\s*"([^"]{6,30})"/, jsonld) do
      [_, p] ->
        String.trim(p)

      nil ->
        case Regex.run(@phone_re, footer_text) do
          [p | _] -> p |> String.trim() |> then(&if(String.length(&1) in 8..24, do: &1, else: ""))
          nil -> ""
        end
    end
  end

  defp address(footer_text, jsonld) do
    case Regex.run(~r/"streetAddress"\s*:\s*"([^"]{4,120})"/, jsonld) do
      [_, street] ->
        locality = Regex.run(~r/"addressLocality"\s*:\s*"([^"]{2,60})"/, jsonld)
        postal = Regex.run(~r/"postalCode"\s*:\s*"([^"]{2,12})"/, jsonld)
        country = Regex.run(~r/"addressCountry"\s*:\s*"([^"]{2,40})"/, jsonld)

        [street, postal && Enum.at(postal, 1), locality && Enum.at(locality, 1), country && Enum.at(country, 1)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(", ")
        |> String.slice(0, 200)

      nil ->
        case Regex.run(@address_re, footer_text) do
          [a | _] -> a |> String.trim() |> String.slice(0, 200)
          nil -> ""
        end
    end
  end

  defp company_id(footer_text) do
    case Regex.run(@company_id_re, footer_text) do
      [_, id] -> id |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 40)
      nil -> ""
    end
  end

  defp nav_links(texts), do: texts |> Enum.reverse() |> Enum.uniq() |> Enum.take(60)
end
