defmodule LS.Verification.CSV do
  @moduledoc """
  A one-line RFC 4180 field splitter for the registry CSVs (Companies House
  `,`-separated, Sirene `,`, INPI `;`). Handles quoted fields, doubled quotes
  and a UTF-8 BOM; a line with an unbalanced quote returns `:error` and is
  skipped by callers (embedded newlines do not occur in these files, and if
  one ever did we would rather drop that row than mis-align every column).
  """

  @doc "Split one CSV line into fields; `:error` on an unbalanced quote."
  @spec parse_line(binary(), String.t()) :: {:ok, [String.t()]} | :error
  def parse_line(line, sep \\ ",") when is_binary(line) and byte_size(sep) == 1 do
    line = line |> strip_bom() |> String.trim_trailing("\r")
    do_parse(line, sep, "", [], false)
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(s), do: s

  # in_quotes=false
  defp do_parse(<<>>, _sep, cur, acc, false), do: {:ok, Enum.reverse([cur | acc])}
  defp do_parse(<<?", rest::binary>>, sep, "", acc, false), do: do_parse(rest, sep, "", acc, true)
  defp do_parse(<<c, rest::binary>>, sep, cur, acc, false) when <<c>> == sep, do: do_parse(rest, sep, "", [cur | acc], false)
  defp do_parse(<<c, rest::binary>>, sep, cur, acc, false), do: do_parse(rest, sep, <<cur::binary, c>>, acc, false)
  # in_quotes=true
  defp do_parse(<<>>, _sep, _cur, _acc, true), do: :error
  defp do_parse(<<?", ?", rest::binary>>, sep, cur, acc, true), do: do_parse(rest, sep, <<cur::binary, ?">>, acc, true)
  defp do_parse(<<?", rest::binary>>, sep, cur, acc, true), do: do_parse(rest, sep, cur, acc, false)
  defp do_parse(<<c, rest::binary>>, sep, cur, acc, true), do: do_parse(rest, sep, <<cur::binary, c>>, acc, true)

  @doc "Header line → `%{\"ColumnName\" => index}` with names trimmed."
  def header_index(line, sep \\ ",") do
    case parse_line(line, sep) do
      {:ok, cols} -> {:ok, cols |> Enum.map(&String.trim/1) |> Enum.with_index() |> Map.new()}
      :error -> :error
    end
  end
end
