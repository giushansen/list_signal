defmodule LSWeb.McpChangesToolTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-10-17: the MCP server offered company lookup, search and stats, and
  no way to ask what changed, which is what the product sells. The API has
  had it since v1 (/api/v1/changes); the tool mirrors its filters.
  """

  test "the changes tool is listed with the API's filters and the same name family" do
    tool = Enum.find(LSWeb.McpController.tools(), &(&1.name == "listsignal_changes"))
    assert tool, "listsignal_changes missing from tools/list"
    props = tool.inputSchema.properties |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    assert props == Enum.sort(LS.ApiData.changes_filters())
    assert tool.description =~ "hiring"
  end

  test "every tool name is unique and the unknown-tool message names them all" do
    names = Enum.map(LSWeb.McpController.tools(), & &1.name)
    assert names == Enum.uniq(names)
    src = File.read!("lib/ls_web/controllers/mcp_controller.ex")
    for n <- names, do: assert(src =~ "Available: " <> Enum.join(names, ", ") or src =~ n)
  end
end
