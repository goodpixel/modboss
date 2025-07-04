# ModBoss

<img alt="ModBoss logo" width="500px" src="assets/boss.jpeg">

[![Elixir CI](https://github.com/goodpixel/modboss/actions/workflows/elixir.yml/badge.svg?branch=main)](https://github.com/goodpixel/modboss/actions/workflows/elixir.yml)

## Show that Bus who's Boss!

ModBoss is an Elixir library that maps Modbus objects to human-friendly names and provides
automatic encoding/decoding of values—making your application logic simpler and more readable,
and making testing of modbus concerns easier.

Note that ModBoss doesn't handle the actual reading/writing of modbus objects—it simply assists
in providing friendlier access to object values. You'll likely be wrapping another library such
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

### 1. Map your schema

Starting with the type of object, you'll define the addresses to include and a friendly name
for the mapping.

The `:as` option dictates how values will be translated. You can use translation functions
from another module—like those found in `ModBoss.Encoding`—or provide your own as shown here
with `as: :fw_version`.

When providing your own translation functions, ModBoss expects that you'll provide functions
corresponding to the `:as` option but with `encode_` / `decode_` prefixes added as applicable.
These functions will receive the value to be translated and should return either
`{:ok, translated_value}` or `{:error, message}`.

```elixir
defmodule MyDevice.Schema do
  use ModBoss.Schema

  modbus_schema do
    holding_register 1, :outdoor_temp, as: {ModBoss.Encoding, :signed_int}
    holding_register 2..5, :model_name, as: {ModBoss.Encoding, :ascii}
    holding_register 6, :version, as: :fw_version, mode: :rw
    # Also supports: input_register / coil / discrete_input
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
* **Holding register at address 1** is named `outdoor_temp` and uses the built-in `signed_int`
  decoder that ships with ModBoss.
* **Holding registers 2–5** are grouped under the name `model_name` and use a built-in ASCII
  decoder.
* **Holding register 6** is named `version` and uses `encode_fw_version/1` and `decode_fw_version/1`
  to translate values being written or read respectively.

### 2. Provide generic read/write functions

You'll need to provide a `read_func/3` and a `write func/3` for actually
interacting on the Modbus. In practice, these functions will likely build on a library like
[Modbux](https://hexdocs.pm/modbux/readme.html) along with state stored in a GenServer (e.g.
a `modbux_pid`, IP Address, etc.) to perform the read/write operations.

For each batch, the read_func will be provided the object type
(`:holding_register`, `:input_register`, `:coil`, or `:discrete_input`), the starting address,
and the number of addresses to read. It must return either `{:ok, result}` or `{:error, message}`.

```elixir
read_func = fn object_type, starting_address, count ->
  result = custom_read_logic(…)
  {:ok, result}
end
```

For each batch, the `write_func` will be provided the type of object (`:holding_register` or
`:coil`), the starting address for the batch to be written, and a list of values to write.
It must return either `:ok` or `{:error, message}`.

```elixir
write_func = fn object_type, starting_address, value_or_values ->
  result = custom_write_logic(…)
  {:ok, result}
end
```

### 3. Read & Write by name!

From here you can read and write by name…

#### Requesting a single value returns just one value:
```elixir
iex> ModBoss.read(MyDevice.Schema, read_func, :outdoor_temp)
{:ok, 72}
```

#### Requesting multiple values returns a map:
```elixir
iex> ModBoss.read(MyDevice.Schema, read_func, [:outdoor_temp, :model_name, :version])
{:ok, %{outdoor_temp: 72, model_name: "AI4000", version: "0.1"}}
```

#### Writing is performed via a keyword list or map:
```elixir
iex> ModBoss.write(MyDevice.Schema, write_func, version: "0.2")
:ok
```

## Benefits

Extracting your Modbus schema allows you to **isolate the encode/decode logic**
making it much **more testable**. Your primary application logic becomes **simpler and more
readable** since it references mappings by name and doesn't need to worry about encoding/decoding
of values. It also becomes fairly straightforward to set up **virtual devices** with the exact
same object mappings as your physical devices (e.g. using an Elixir Agent to hold the state of
the modbus objects in a map). And it makes for **easier troubleshooting** since you don't need to
memorize (or look up) the object mappings when you're at an `iex` prompt.
