# ModBoss

<img alt="ModBoss logo" width="500px" src="assets/boss.jpeg">

**Show that Bus who's Boss!**

ModBoss provides modbus schema mapping and translation in Elixir.

Instead of reading/writing modbus registers by number and scattering the translation logic around
your code base, Modboss lets you to refer to registers by human-friendly names and allows you
to consolidate your encoding/decoding logic separately from your device drivers, if desired.

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
