# mix run --no-start export_text.exs ROWS.jsonl OUT.jsonl : {"domain","text"} with the runtime hint
[rows_path, out_path] = System.argv()
out = File.open!(out_path, [:write])
rows_path
|> File.stream!()
|> Stream.map(&String.trim/1)
|> Stream.reject(&(&1 == ""))
|> Stream.map(&Jason.decode!/1)
|> Enum.each(fn r ->
  r = Map.new(r, fn {k, v} -> {k, (if is_list(v), do: Enum.map_join(v, "|", &to_string/1), else: v)} end)
  text =
    [r["http_title"], r["http_h1"], r["http_meta_description"], r["http_body_snippet"]]
    |> Enum.map(&(&1 || ""))
    |> Enum.join(" ")
    |> LS.ML.Features.text_with_hint(r)
  IO.binwrite(out, Jason.encode!(%{domain: r["domain"], text: text, status: r["http_status"], is_junk: r["is_junk"]}) <> "\n")
end)
File.close(out)
IO.puts("ok")
