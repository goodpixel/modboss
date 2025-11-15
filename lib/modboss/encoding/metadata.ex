defmodule ModBoss.Encoding.Metadata do
  @moduledoc """
  Metadata to support encoding

  Sometimes it's essential to know how many registers you're encoding a value
  to fit into. For example, when encoding ASCII text, you might choose to pad
  unused bits with zeros. See the implementation of
  `ModBoss.Encoding.encode_ascii/2` for an example.
  """

  alias ModBoss.Mapping

  @type t() :: %__MODULE__{
          name: Mapping.name(),
          type: Mapping.type(),
          address_count: pos_integer()
        }

  defstruct [:name, :type, :address_count]

  @doc false
  def from_mapping(%Mapping{} = mapping) do
    struct!(__MODULE__, Map.take(mapping, [:name, :type, :address_count]))
  end
end
