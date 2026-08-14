# Backfill compute pass 2 (laptop): embed candidates and apply the heads.
#   argv: out_dir  (expects head_cand.tsv + rev_cand.tsv from pass 1)
# Writes class.tsv (domain \t bm \t conf) and rev.tsv (domain \t bracket \t conf).
# Class rows only at head conf >= 0.5 (68%-precision point on the golden
# holdout); revenue rows only when demoting a $100M+/$1B+ estimate to
# <= $1M-$10M at conf >= 0.5 — the measured brand-contamination fix.
[out_dir] = System.argv()

unless LS.ML.Classifier.ready?() do
  IO.puts("waiting for model...")
  Enum.find(1..150, fn _ -> Process.sleep(2_000); LS.ML.Classifier.ready?() end)
end

bm_head = LS.ML.Head.load()

rev_raw = File.read!("priv/ml/revenue_head_v1.json") |> Jason.decode!()
rev_head = %{version: rev_raw["version"], classes: rev_raw["classes"],
             coef: Nx.tensor(rev_raw["coef"], type: :f32),
             intercept: Nx.tensor(rev_raw["intercept"], type: :f32)}

run = fn cand_file, out_file, emit ->
  out = File.open!(Path.join(out_dir, out_file), [:write, :binary])
  done = :counters.new(1, [])

  Path.join(out_dir, cand_file)
  |> File.stream!(read_ahead: 1_000_000)
  |> Stream.map(&String.split(String.trim_trailing(&1, "\n"), "\t"))
  |> Stream.chunk_every(64)
  |> Stream.each(fn chunk ->
    texts = Enum.map(chunk, &List.last/1)
    embs = LS.ML.Classifier.embed_batch(texts)

    chunk
    |> Enum.zip(embs)
    |> Enum.each(fn {fields, emb} ->
      if emb, do: emit.(fields, emb, out)
    end)

    n = :counters.add(done, 1, 1)
    c = :counters.get(done, 1)
    if rem(c, 100) == 0, do: IO.puts("#{cand_file}: #{c * 64} embedded")
    n
  end)
  |> Stream.run()

  File.close(out)
end

run.("head_cand.tsv", "class.tsv", fn [d | _], emb, out ->
  case LS.ML.Head.predict(bm_head, emb) do
    {"Junk", _} -> :ok
    {class, prob} when prob >= 0.5 -> IO.binwrite(out, "#{d}\t#{class}\t#{Float.round(prob, 2)}\n")
    _ -> :ok
  end
end)

run.("rev_cand.tsv", "rev.tsv", fn [d, _est | _], emb, out ->
  {bracket, prob} = LS.ML.Head.predict(rev_head, emb)
  if prob >= 0.5 and bracket in ["<$1M", "$1M-$10M"] do
    IO.binwrite(out, "#{d}\t#{bracket}\t#{Float.round(prob, 2)}\n")
  end
end)

IO.puts("done: class.tsv + rev.tsv")
