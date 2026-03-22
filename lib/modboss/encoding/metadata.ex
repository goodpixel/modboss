defmodule ModBoss.Encoding.Metadata do
  @moduledoc """
  Metadata to support encoding and decoding.

  Passed as the second argument to encode and decode functions that accept
  2-arity (e.g. `encode_foo/2`, `decode_foo/2`). Contains information about
  the mapping being encoded/decoded and any user-provided context.

  ## Fields

  * `:name` — the mapping name (e.g. `:outdoor_temp`)
  * `:type` — the object type (e.g. `:holding_register`)
  * `:address_count` — the number of addresses in the mapping
  * `:context` — user-provided context map, passed via the `:context` option
    on `ModBoss.read/4`, `ModBoss.write/4`, or `ModBoss.encode/3`.
    Defaults to `%{}`.

  For example, when encoding ASCII text, `address_count` tells you how many
  registers to pad into. See the implementation of
  `ModBoss.Encoding.encode_ascii/2` for an example.
  """

  alias ModBoss.Mapping

  @type t() :: %__MODULE__{
          name: Mapping.name(),
          type: Mapping.object_type(),
          address_count: Mapping.count(),
          context: map()
        }

  defstruct [:name, :type, :address_count, context: %{}]

  @doc false
  def from_mapping(%Mapping{} = mapping, context \\ %{}) do
    mapping
    |> Map.take([:name, :type, :address_count])
    |> Map.put(:context, context)
    |> then(&struct!(__MODULE__, &1))
  end
end
