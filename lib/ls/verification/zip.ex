defmodule LS.Verification.Zip do
  @moduledoc """
  Memory-bounded readers for the bulk archives pipeline 3 ingests.

  * `stream_lines/2` — lines of ONE entry of a zip, streamed through `unzip -p`
    on a port. Sirene's stock file is ~9 GB unpacked and Companies House's
    company snapshot ~2.5 GB; neither may ever be a single binary on the
    master (BEAM is capped at 4 G).
  * `fold_entries/3` — visit every entry of a many-small-files zip (SEC
    `submissions.zip` ≈ 1 M JSON files, Companies House monthly accounts ≈
    100 k iXBRL files) one at a time, cutting `unzip -p`'s byte stream by the
    sizes `unzip -l` reports. ZIP64-safe, unlike `:zip.foldl/3`.
  """

  @doc """
  Stream the lines of `entry` inside `zip_path` (or of the only entry when
  `entry` is nil). Each element is one line without its newline.
  """
  @spec stream_lines(Path.t(), String.t() | nil) :: Enumerable.t()
  def stream_lines(zip_path, entry \\ nil) do
    args = ["-p", zip_path] ++ if(entry, do: [entry], else: [])

    Stream.resource(
      fn ->
        port =
          Port.open({:spawn_executable, unzip_bin()}, [
            :binary, :exit_status, :stream, :use_stdio, {:args, args}
          ])

        {port, ""}
      end,
      fn
        {nil, _} = acc ->
          {:halt, acc}

        {port, buf} ->
          receive do
            {^port, {:data, data}} ->
              {lines, rest} = split_lines(buf <> data)
              {lines, {port, rest}}

            {^port, {:exit_status, 0}} ->
              {if(buf == "", do: [], else: [buf]), {nil, ""}}

            {^port, {:exit_status, code}} ->
              raise "unzip #{zip_path} exited #{code}"
          end
      end,
      fn
        {nil, _} -> :ok
        {port, _} -> Port.close(port)
      end
    )
  end

  # Split a buffer into complete lines and the trailing partial line.
  defp split_lines(bin) do
    case String.split(bin, "\n") do
      [only] -> {[], only}
      parts -> {rest, [last]} = Enum.split(parts, -1)
               {Enum.map(rest, &String.trim_trailing(&1, "\r")), last}
    end
  end

  @doc """
  Fold over every entry of a zip: `fun.(name, get_binary, acc)` where
  `get_binary.()` returns that entry's bytes. Streaming and ZIP64-safe:
  `unzip -l` gives names and sizes in archive order, `unzip -p` streams every
  entry's bytes in that same order, and we cut the byte stream by size — one
  entry in memory at a time.

  Why not `:zip.foldl/3`: Erlang's zip reader has no ZIP64 support and
  silently reads only `N mod 65536` entries of a big archive. On 2026-08-19
  that made SEC `submissions.zip` (987 k entries) yield 3 057 of 11 621
  filers and Companies House's monthly accounts (~100 k files) stage about
  half a month, then `:bad_central_directory`. Regression test in
  `LS.Verification.ZipTest`.
  """
  @spec fold_entries(Path.t(), acc, (String.t(), (-> binary()), acc -> acc)) :: {:ok, acc} | {:error, term()}
        when acc: term()
  def fold_entries(zip_path, acc0, fun) do
    with {:ok, entries} <- list_entries(zip_path) do
      acc =
        zip_path
        |> byte_stream()
        |> cut_by_sizes(entries)
        |> Enum.reduce(acc0, fn {name, bin}, acc ->
          if String.ends_with?(name, "/"), do: acc, else: fun.(name, fn -> bin end, acc)
        end)

      {:ok, acc}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "`[{name, size}]` in archive order, from `unzip -l` (pure parser in `parse_listing/1`)."
  def list_entries(zip_path) do
    case System.cmd(unzip_bin(), ["-l", zip_path], stderr_to_stdout: true) do
      {out, 0} -> {:ok, parse_listing(out)}
      {out, code} -> {:error, {:unzip_list, code, String.slice(out, 0, 200)}}
    end
  end

  @doc false
  def parse_listing(out) do
    out
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      # Info-ZIP prints the date as YYYY-MM-DD (Linux) or MM-DD-YYYY (macOS).
      case Regex.run(~r/^\s*(\d+)\s+[\d-]{10}\s+\d{2}:\d{2}\s+(.+)$/, line) do
        [_, size, name] -> [{name, String.to_integer(size)}]
        _ -> []
      end
    end)
  end

  # Raw bytes of every entry, concatenated in archive order.
  defp byte_stream(zip_path) do
    Stream.resource(
      fn -> Port.open({:spawn_executable, unzip_bin()}, [:binary, :exit_status, :stream, :use_stdio, {:args, ["-p", zip_path]}]) end,
      fn
        nil -> {:halt, nil}
        port ->
          receive do
            {^port, {:data, data}} -> {[data], port}
            {^port, {:exit_status, 0}} -> {[], nil}
            {^port, {:exit_status, code}} -> raise "unzip -p #{zip_path} exited #{code}"
          end
      end,
      fn
        nil -> :ok
        port -> Port.close(port)
      end
    )
  end

  @doc false
  # Cut a stream of binary chunks into `{name, bytes}` per entry size (pure over the stream).
  def cut_by_sizes(chunks, entries) do
    Stream.transform(chunks, {entries, ""}, fn chunk, {todo, buf} ->
      take(todo, buf <> chunk, [])
    end)
  end

  # Emit every entry fully contained in the buffer; keep the rest.
  defp take([], _buf, out), do: {Enum.reverse(out), {[], ""}}

  defp take([{name, size} | rest] = todo, buf, out) do
    if byte_size(buf) >= size do
      <<bin::binary-size(size), tail::binary>> = buf
      take(rest, tail, [{name, bin} | out])
    else
      {Enum.reverse(out), {todo, buf}}
    end
  end

  defp unzip_bin do
    System.find_executable("unzip") || raise "unzip not installed — apt install unzip"
  end
end
