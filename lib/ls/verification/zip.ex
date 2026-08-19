defmodule LS.Verification.Zip do
  @moduledoc """
  Memory-bounded readers for the bulk archives pipeline 3 ingests.

  * `stream_lines/2` — lines of ONE entry of a zip.
  * `fold_entries/3` — visit every entry of a many-small-files zip (SEC
    `submissions.zip` ≈ 1 M JSON files, Companies House monthly accounts ≈
    250 k iXBRL files), cutting the decompressed byte stream by the sizes
    `unzip -l` reports. ZIP64-safe, unlike `:zip.foldl/3`.

  ## Backpressure is the whole point (2026-08-19 OOM)

  Both readers pull `unzip`'s output through a **named pipe** read with
  `:file.read/2`, NOT through a `Port` on `unzip`'s stdout. A spawned Port is
  always active: the emulator reads the pipe as fast as `unzip` fills it and
  turns every chunk into a mailbox message, with no flow control. `unzip`
  decompresses a 2 GB Companies-House month in ~30 s but IXBRL parsing of its
  250 k filings takes minutes, so ~2 GB of decompressed bytes piled up as
  unread `{port, {:data, _}}` messages and the cgroup OOM-killed the whole
  BEAM every ~20 min — a crash loop, because the scheduler re-picked the
  never-finishing source on each restart. Reading a fifo with `:file.read/2`
  gives real backpressure: when we are slow the kernel pipe fills and `unzip`
  blocks on `write()`, so memory stays flat regardless of archive size.
  """

  @read_chunk 262_144

  @doc """
  Stream the lines of `entry` inside `zip_path` (or the only entry when
  `entry` is nil). Each element is one line without its newline.
  """
  @spec stream_lines(Path.t(), String.t() | nil) :: Enumerable.t()
  def stream_lines(zip_path, entry \\ nil) do
    args = ["-p", zip_path] ++ if(entry, do: [entry], else: [])

    byte_stream(args)
    |> Stream.transform("", fn chunk, buf ->
      {lines, rest} = split_lines(buf <> chunk)
      {lines, rest}
    end)
    |> Stream.concat(
      Stream.resource(fn -> nil end, fn
        :done -> {:halt, nil}
        _ -> {[], :done}
      end, fn _ -> :ok end)
    )
  end

  # Split a buffer into complete lines and the trailing partial line.
  defp split_lines(bin) do
    case String.split(bin, "\n") do
      [only] ->
        {[], only}

      parts ->
        {rest, [last]} = Enum.split(parts, -1)
        {Enum.map(rest, &String.trim_trailing(&1, "\r")), last}
    end
  end

  @doc """
  Fold over every entry of a zip: `fun.(name, get_binary, acc)` where
  `get_binary.()` returns that entry's bytes. Streaming and ZIP64-safe:
  `unzip -l` gives names and sizes in archive order, the decompressed stream
  delivers every entry's bytes in that same order, and we cut the stream by
  size — one entry in memory at a time.
  """
  @spec fold_entries(Path.t(), acc, (String.t(), (-> binary()), acc -> acc)) :: {:ok, acc} | {:error, term()}
        when acc: term()
  def fold_entries(zip_path, acc0, fun) do
    with {:ok, entries} <- list_entries(zip_path) do
      acc =
        byte_stream(["-p", zip_path])
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

  # ── Backpressured byte stream ──

  # Run `unzip <args>` writing to a private fifo, and stream the fifo's bytes
  # with `:file.read/2`. The kernel pipe (~64 KB) blocks `unzip` whenever the
  # consumer lags, so decompressed bytes never accumulate in the BEAM.
  defp byte_stream(args) do
    Stream.resource(
      fn -> open_fifo(args) end,
      fn %{io: io} = st ->
        case :file.read(io, @read_chunk) do
          {:ok, data} -> {[data], st}
          :eof -> {:halt, st}
          {:error, reason} -> raise "fifo read failed: #{inspect(reason)}"
        end
      end,
      &close_fifo/1
    )
  end

  defp open_fifo(args) do
    dir = Path.join(System.tmp_dir!(), "ls_verify_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    fifo = Path.join(dir, "pipe")
    {_, 0} = System.cmd("mkfifo", [fifo])

    # Producer writes the decompressed stream INTO the fifo, so this port
    # carries no stdout of its own — nothing to flood the mailbox. It blocks
    # on the fifo write when we are slow.
    sh = System.find_executable("sh") || "/bin/sh"
    cmd = "exec #{unzip_bin()} #{Enum.map_join(args, " ", &shell_quote/1)} > #{shell_quote(fifo)}"
    port = Port.open({:spawn_executable, sh}, [:binary, :exit_status, :use_stdio, {:args, ["-c", cmd]}])

    # Opening the read end rendezvous with unzip opening the write end.
    {:ok, io} = :file.open(fifo, [:read, :binary, :raw])
    %{io: io, port: port, dir: dir}
  end

  defp close_fifo(%{io: io, port: port, dir: dir}) do
    :file.close(io)
    if Port.info(port), do: Port.close(port)
    File.rm_rf(dir)
    :ok
  rescue
    _ -> :ok
  end

  defp shell_quote(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  defp unzip_bin do
    System.find_executable("unzip") || raise "unzip not installed — apt install unzip"
  end
end
