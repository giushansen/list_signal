defmodule LS.Verification.CSVTest do
  use ExUnit.Case, async: true
  alias LS.Verification.CSV

  test "quoted fields, doubled quotes, BOM, CRLF" do
    assert CSV.parse_line(~s(﻿"ACME, LTD",123,"He said ""hi""",x\r\n) |> String.trim_trailing("\n")) ==
             {:ok, ["ACME, LTD", "123", ~s(He said "hi"), "x"]}
    assert CSV.parse_line("a;b;c", ";") == {:ok, ["a", "b", "c"]}
    assert CSV.parse_line("") == {:ok, [""]}
    assert CSV.parse_line("a,,b") == {:ok, ["a", "", "b"]}
  end

  test "an unbalanced quote is an error, not a mis-aligned row" do
    assert CSV.parse_line(~s("ACME, LTD,123)) == :error
  end

  test "header_index/2 trims names" do
    assert CSV.header_index(" CompanyName , CompanyNumber") == {:ok, %{"CompanyName" => 0, "CompanyNumber" => 1}}
  end
end
