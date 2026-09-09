defmodule LSWeb.JsonLD do
  @moduledoc """
  Makes an encoded JSON-LD document safe to inline in a `<script>` block.

  The block is rendered with `raw/1` because it must not be HTML-escaped,
  so a business name containing `</script>` would end the block and start
  markup (security audit 2026-09-09). JSON never carries `<` outside a
  string, so replacing every `<` with its `\\u003c` escape keeps the
  document identical to a parser and inert to the HTML tokenizer.
  """

  @spec safe(String.t() | nil) :: String.t()
  def safe(nil), do: ""
  def safe(json) when is_binary(json), do: String.replace(json, "<", "\\u003c")
end
