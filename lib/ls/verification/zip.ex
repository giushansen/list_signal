defmodule LS.Verification.Zip do
  @moduledoc """
  Memory-bounded readers for the bulk archives pipeline 3 ingests.

  * `stream_lines/2` — lines of ONE entry of a zip, streamed through `unzip -p`
    on a port. Sirene's stock file is ~9 GB unpacked and Companies House's
    company snapshot ~2.5 GB; neither may ever be a single binary on the
    master (BEAM is capped at 4 G).
  * `fold_entries/3` — visit every entry of a many-small-files zip (SEC
    `companyfacts.zip` ≈ 18 k JSON files, Companies House monthly accounts ≈
    100 k iXBRL files) one at a time via `:zip.foldl/3`, which reads each
    entry on demand.
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
  `get_binary.()` reads that entry only when called. Directories are skipped.
  """
  @spec fold_entries(Path.t(), acc, (String.t(), (-> binary()), acc -> acc)) :: {:ok, acc} | {:error, term()}
        when acc: term()
  def fold_entries(zip_path, acc0, fun) do
    :zip.foldl(
      fn name, _info, get_bin, acc ->
        name = to_string(name)
        if String.ends_with?(name, "/"), do: acc, else: fun.(name, get_bin, acc)
      end,
      acc0,
      String.to_charlist(zip_path)
    )
  end

  defp unzip_bin do
    System.find_executable("unzip") || raise "unzip not installed — apt install unzip"
  end
end
