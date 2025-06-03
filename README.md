# ModBoss

<img alt="ModBoss logo" width="500px" src="assets/boss.jpeg">

## Show that Bus who's Boss!

ModBoss is an Elixir library that maps Modbus registers to human-friendly names and provides
automatic encoding/decoding of values.

Instead of reading/writing modbus registers by number and cluttering your application logic up
with encoding/decoding logic, ModBoss lets you to refer to registers using human-friendly names
and allows you to consolidate your encoding/decoding logic separately from your device drivers.

Note that ModBoss doesn't handle the actual reading/writing of modbus registers—it simply assists
in providing friendlier access to register values. You'll likely be wrapping another library such
as [Modbux](https://hexdocs.pm/modbux/readme.html) for the actual reads/writes.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `modboss` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:modboss, "~> 0.1.0"}
  ]
end
```

## Usage

### Map your schema

```elixir
defmodule MyDevice.Schema do
  use ModBoss.Schema

  modbus_schema do
    holding_register 1, :outdoor_temp, as: {ModBoss.Encoding, :signed_int}
    holding_register 2..5, :model_name, as: {ModBoss.Encoding, :ascii}
    holding_register 6, :version, as: :fw_version, mode: :rw
    # Also supports: input_regster / coil / discrete_input
  end

  def encode_fw_version(value) do
    encoded_value = do_encode(value)
    {:ok, encoded_value}
  end

  def decode_fw_version(value) do
    decoded_value = some_decode_logic(value)
    {:ok, decoded_value}
  end
end
```

In this example:
* Holding register at address 1 is named `outdoor_temp` and uses a built-in `unsigned_int` decoder
  that ships with ModBoss.
* Holding registers 2 through 5 are grouped under the name `model_name` and use a built-in decode.
* Holding register 6 is named `version` and specifies `as: :fw_version`. In this case, ModBoss
  expects you to provide corresponding `encode_fw_version` and `decode_fw_version` functions—both
  of which must take the value to be translated and return an `{:ok, value}` tuple if successful
  and an `{:error, message}` tuple if the value cannot be translated.

### BYOM (Bring your own Modbus reader/writer)

You'll need to bring your own utility for actually reading and writing on the Modbus, but ModBoss
will automatically batch those reads and writes into contiguous addresses for each separate type.

```elixir
# Will be called once for each batch of contiguous registers.
# Receives :holding_register, :input_register, :coil, or :discrete_input as `register_type`.
read_func = fn register_type, starting_address, count ->
  # read modbus
end

# Will be called once for each batch of contiguous registers.
# Receives :holding_register or :coil as `register_type`.
# Receives either a single value to be written or a list of values depending on how many
# registers to be written are in this batch.
write_func = fn register_type, starting_address, value_or_values ->
  # write modbus
end
```

### Read & Write by name!

From here you can read and write by name.

Requesting a single value will return just one value:
```elixir
iex> ModBoss.read(MyDevice.Schema, read_func, :outdoor_temp)
{:ok, 72}
```

Requesting multiple values will return a map:
```elixir
iex> ModBoss.read(MyDevice.Schema, read_func, [:outdoor_temp, :model_name, :version])
{:ok, %{outdoor_temp: 72, model_name: "AI4000", version: "0.1"}}
```

Writing is always performed by providing a map:
```elixir
iex> ModBoss.write(MyDevice.Schema, write_func, %{version: "0.2"})
:ok
```
