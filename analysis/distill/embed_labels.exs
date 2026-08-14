# Compute MiniLM embeddings for teacher-labeled domains + golden eval rows.
# Usage: mix run embed_labels.exs LABELS.jsonl ROWS.json OUT.jsonl
# Each output line: {"domain": ..., "embedding": [384 floats]}
[labels_path, rows_path, out_path] = System.argv()

# text must mirror the production ml_text construction (title h1 meta body)
rows =
  rows_path
  |> File.read!()
  |> Jason.decode!()
  |> Map.new(fn r -> {r["domain"], r} end)

domains =
  labels_path
  |> File.stream!()
  |> Stream.map(&Jason.decode!/1)
  |> Enum.map(& &1["domain"])
  |> Enum.uniq()
  |> Enum.filter(&Map.has_key?(rows, &1))

IO.puts("embedding #{length(domains)} domains...")

unless LS.ML.Classifier.ready?() do
  IO.puts("waiting for model load...")
  Enum.find(1..120, fn _ -> Process.sleep(2_000); LS.ML.Classifier.ready?() end)
end

texts =
  Enum.map(domains, fn d ->
    r = rows[d]
    [r["http_title"], r["http_h1"], r["http_meta_description"], r["http_body_snippet"]]
    |> Enum.map(&(&1 || ""))
    |> Enum.join(" ")
    |> String.trim()
  end)

out = File.open!(out_path, [:write])

domains
|> Enum.zip(texts)
|> Enum.chunk_every(64)
|> Enum.with_index()
|> Enum.each(fn {chunk, i} ->
  embs = LS.ML.Classifier.embed_batch(Enum.map(chunk, fn {_, t} -> t end))

  chunk
  |> Enum.zip(embs)
  |> Enum.each(fn {{d, _}, emb} ->
    if emb, do: IO.write(out, Jason.encode!(%{domain: d, embedding: emb}) <> "\n")
  end)

  IO.puts("chunk #{i} done")
end)

File.close(out)
IO.puts("wrote #{out_path}")
