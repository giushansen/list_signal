defmodule LS.Verification.ZipTest do
  @moduledoc """
  2026-08-19: Erlang's `:zip` has no ZIP64 support and read only
  `N mod 65536` entries of SEC `submissions.zip` (987 k files) and of the
  Companies House monthly accounts archives — EDGAR yielded 3 057 of 11 621
  filers and Companies House staged half-months then `:bad_central_directory`.
  The reader now cuts `unzip -p`'s byte stream by `unzip -l`'s sizes.
  """
  use ExUnit.Case, async: true
  alias LS.Verification.Zip

  @listing """
  Archive:  submissions.zip
    Length      Date    Time    Name
  ---------  ---------- -----   ----
       1234  2026-08-18 05:55   CIK0000001750.json
          0  2026-08-18 05:55   dir/
    5000000  2026-08-18 05:55   CIK0000001800 with space.json
  ---------                     -------
  5719089047                     987041 files
  """

  test "parse_listing/1 keeps archive order, sizes, directories and names with spaces; ignores header/footer" do
    assert Zip.parse_listing(@listing) == [
             {"CIK0000001750.json", 1234},
             {"dir/", 0},
             {"CIK0000001800 with space.json", 5_000_000}
           ]
  end

  test "cut_by_sizes/2 reassembles entries across arbitrary chunk boundaries" do
    entries = [{"a", 3}, {"b", 0}, {"c", 5}, {"d", 2}]
    bytes = "aaaccccc" <> "dd"
    for chunk <- [1, 2, 3, 7, 100] do
      chunks = bytes |> :binary.bin_to_list() |> Enum.chunk_every(chunk) |> Enum.map(&:binary.list_to_bin/1)
      assert Zip.cut_by_sizes(chunks, entries) |> Enum.to_list() == [{"a", "aaa"}, {"b", ""}, {"c", "ccccc"}, {"d", "dd"}]
    end
  end

  @tag :tmp_dir
  test "fold_entries/3 visits every file of a real archive with exact bytes", %{tmp_dir: dir} do
    if System.find_executable("zip") && System.find_executable("unzip") do
      File.mkdir_p!(Path.join(dir, "sub"))
      File.write!(Path.join(dir, "one.json"), ~s({"cik":"1"}))
      File.write!(Path.join(dir, "sub/two.html"), String.duplicate("x", 300_000))
      File.write!(Path.join(dir, "empty.txt"), "")
      zip = Path.join(dir, "t.zip")
      {_, 0} = System.cmd("zip", ["-q", "-r", zip, "one.json", "sub", "empty.txt"], cd: dir)

      {:ok, seen} = Zip.fold_entries(zip, %{}, fn name, get, acc -> Map.put(acc, name, byte_size(get.())) end)
      assert seen == %{"one.json" => 11, "sub/two.html" => 300_000, "empty.txt" => 0}
    end
  end

  @tag :tmp_dir
  @tag timeout: 120_000
  test "backpressure: BEAM memory stays flat while a slow consumer reads a large archive", %{tmp_dir: dir} do
    if System.find_executable("zip") && System.find_executable("unzip") && System.find_executable("mkfifo") do
      # ~200 MB across 400 entries. With the old active-Port reader a slow
      # consumer let unzip pile the whole thing into the mailbox; with the
      # fifo reader unzip blocks and heap stays bounded.
      big = String.duplicate("x", 512_000)
      for i <- 1..400, do: File.write!(Path.join(dir, "e#{i}.txt"), big)
      zip = Path.join(dir, "big.zip")
      {_, 0} = System.cmd("zip", ["-q", zip | Enum.map(1..400, &"e#{&1}.txt")], cd: dir)

      before = :erlang.memory(:total)

      {:ok, {count, peak}} =
        Zip.fold_entries(zip, {0, before}, fn _name, get, {n, peak} ->
          _ = byte_size(get.())
          if rem(n, 40) == 0, do: Process.sleep(20)   # a deliberately slow consumer
          {n + 1, max(peak, :erlang.memory(:total))}
        end)

      assert count == 400
      growth_mb = (peak - before) / 1_000_000
      assert growth_mb < 80, "heap grew #{Float.round(growth_mb, 1)}MB reading a 200MB archive — backpressure is not holding"
    end
  end
end
