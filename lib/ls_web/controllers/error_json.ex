defmodule LSWeb.ErrorJSON do
  @moduledoc "JSON error renderer (fallback for API-style requests)."
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
