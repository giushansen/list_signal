# Backfill compute pass 1 (laptop): junk via THE production junk_reason/1 +
# candidate selection for the head/revenue passes. Single-threaded on purpose:
# junk_reason is microseconds/row and simple survives 20M rows.
[biz_path, text_path, out_dir] = System.argv()

defmodule BF do
  def scrub(text) do
    case :unicode.characters_to_binary(text, :utf8, :utf8) do
      bin when is_binary(bin) -> bin
      {:error, good, _} -> good
      {:incomplete, good, _} -> good
    end
  end

  def parse_f(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end
end

head_cap = String.to_integer(System.get_env("HEAD_CAP") || "150000")
rev_cap = String.to_integer(System.get_env("REV_CAP") || "50000")

IO.puts("loading businesses state...")
ets = :ets.new(:biz, [:set, :public])

File.stream!(biz_path, read_ahead: 1_000_000)
|> Stream.each(fn line ->
  case String.split(String.trim_trailing(line, "\n"), "\t") do
    [d, bm, conf, rev, junk] -> :ets.insert(ets, {d, bm, BF.parse_f(conf), rev, junk})
    _ -> :ok
  end
end)
|> Stream.run()

IO.puts("businesses rows in ets: #{:ets.info(ets, :size)}")

File.mkdir_p!(out_dir)
junk_out = File.open!(Path.join(out_dir, "junk.tsv"), [:write, :binary])
head_cand = File.open!(Path.join(out_dir, "head_cand.tsv"), [:write, :binary])
rev_cand = File.open!(Path.join(out_dir, "rev_cand.tsv"), [:write, :binary])
counters = :counters.new(4, [])

File.stream!(text_path, read_ahead: 1_000_000)
|> Stream.each(fn line ->
 try do
  :counters.add(counters, 4, 1)
  seen = :counters.get(counters, 4)
  if rem(seen, 2_000_000) == 0, do: IO.puts("scanned #{seen} rows")

  with {:ok, r} <- Jason.decode(line),
       [{d, bm, conf, est_rev, junk}] <- :ets.lookup(ets, r["domain"]) do
    title = r["http_title"] || ""
    h1 = r["http_h1"] || ""
    meta = r["http_meta_description"] || ""
    body = r["http_body_snippet"] || ""

    signals = %{http_title: title, h1: h1, http_meta_description: meta,
                body_text: body, http_status: r["http_status"],
                http_tech: "", http_apps: "", http_pages: "",
                http_schema_type: "", http_og_type: "", ctl_tld: "",
                dns_txt: "", nav_links: ""}

    new_junk = LS.HTTP.BusinessClassifier.junk_reason(signals)
    text = [title, h1, meta, body] |> Enum.join(" ") |> String.trim() |> BF.scrub()

    if junk == "" and new_junk != "" do
      :counters.add(counters, 1, 1)
      IO.binwrite(junk_out, "#{d}\t#{new_junk}\n")
    end

    if (bm == "" or conf < 0.55) and byte_size(text) > 20 and
         :counters.get(counters, 2) < head_cap do
      :counters.add(counters, 2, 1)
      IO.binwrite(head_cand, "#{d}\t#{String.replace(text, ~r/[\t\r\n]/, " ")}\n")
    end

    if est_rev in ["$100M-$1B", "$1B+"] and byte_size(text) > 20 and
         :counters.get(counters, 3) < rev_cap do
      :counters.add(counters, 3, 1)
      IO.binwrite(rev_cand, "#{d}\t#{est_rev}\t#{String.replace(text, ~r/[\t\r\n]/, " ")}\n")
    end
  else
    _ -> :ok
  end
 rescue
  e ->
    if :counters.get(counters, 4) < 5, do: IO.puts("ROW ERROR: #{Exception.message(e)}")
    :ok
 end
end)
|> Stream.run()

Enum.each([junk_out, head_cand, rev_cand], &File.close/1)
IO.puts("scanned: #{:counters.get(counters, 4)}")
IO.puts("junk flagged: #{:counters.get(counters, 1)}")
IO.puts("head candidates: #{:counters.get(counters, 2)}  rev candidates: #{:counters.get(counters, 3)}")
