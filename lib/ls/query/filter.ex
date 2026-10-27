defmodule LS.Query.Filter do
  @moduledoc """
  One filter of the shared grammar (`LS.Query`): its public name, the
  `LS.Explorer` key it maps to, its value type, the aliases still
  accepted, the fixed values of an enum, and the documentation every
  surface prints.
  """
  @enforce_keys [:name, :key, :type, :doc, :example]
  defstruct [:name, :key, :type, :doc, :example, aliases: [], values: nil, group: ""]

  @type t :: %__MODULE__{
          name: String.t(),
          key: atom(),
          type: :list | :text | :flag | :int | :number | :date | :enum,
          doc: String.t(),
          example: String.t(),
          aliases: [String.t()],
          values: [String.t()] | :tracked_fields | nil,
          group: String.t()
        }
end
