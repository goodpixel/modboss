defmodule ModBoss.Telemetry do
  @moduledoc """
  Telemetry events emitted by ModBoss.

  ModBoss emits telemetry events for reads and writes using the
  [`:telemetry`](https://hex.pm/packages/telemetry) library.

  `:telemetry` is an **optional dependency**. If it is not included in your
  application's dependencies, all telemetry calls become no-ops at compile time
  with zero runtime overhead.

  > #### Recompilation required {: .warning}
  >
  > Telemetry availability is determined at compile time. If you add or remove
  > `:telemetry` as a dependency after ModBoss has been compiled, you must
  > recompile ModBoss (e.g. `mix deps.compile modboss --force`).

  ## Per-operation events

  These events wrap the full `ModBoss.read/4` or `ModBoss.write/4` call (which
  may contain multiple batched Modbus requests). They are **not** emitted for
  validation errors (e.g. unknown mapping names or unreadable/unwritable mappings).

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:modboss, :read, :start]` | `system_time`, `monotonic_time` | `schema`, `names`, `label` |
  | `[:modboss, :read, :stop]` | `duration`, `monotonic_time`, `modbus_requests`, `objects_requested`, `addresses_read`, `gap_addresses_read`, `max_gap_size` | `schema`, `names`, `label`, `result` |
  | `[:modboss, :read, :exception]` | `duration`, `monotonic_time` | `schema`, `names`, `label`, `kind`, `reason`, `stacktrace` |
  | `[:modboss, :write, :start]` | `system_time`, `monotonic_time` | `schema`, `names`, `label` |
  | `[:modboss, :write, :stop]` | `duration`, `monotonic_time`, `modbus_requests`, `objects_requested` | `schema`, `names`, `label`, `result` |
  | `[:modboss, :write, :exception]` | `duration`, `monotonic_time` | `schema`, `names`, `label`, `kind`, `reason`, `stacktrace` |

  ## Per-callback events

  These events wrap each individual invocation of your `read_func` or `write_func`
  callback—one contiguous address range of one object type.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:modboss, :read_callback, :start]` | `system_time`, `monotonic_time` | `schema`, `names`, `label`, `object_type`, `starting_address`, `address_count` |
  | `[:modboss, :read_callback, :stop]` | `duration`, `monotonic_time`, `gap_addresses_read`, `max_gap_size` | `schema`, `names`, `label`, `object_type`, `starting_address`, `address_count`, `result` |
  | `[:modboss, :read_callback, :exception]` | `duration`, `monotonic_time` | `schema`, `names`, `label`, `object_type`, `starting_address`, `address_count`, `kind`, `reason`, `stacktrace` |
  | `[:modboss, :write_callback, :start]` | `system_time`, `monotonic_time` | `schema`, `names`, `label`, `object_type`, `starting_address`, `address_count` |
  | `[:modboss, :write_callback, :stop]` | `duration`, `monotonic_time` | `schema`, `names`, `label`, `object_type`, `starting_address`, `address_count`, `result` |
  | `[:modboss, :write_callback, :exception]` | `duration`, `monotonic_time` | `schema`, `names`, `label`, `object_type`, `starting_address`, `address_count`, `kind`, `reason`, `stacktrace` |

  ## Measurement details

  * `duration` — elapsed time in native time units. Convert with
    `System.convert_time_unit(duration, :native, :millisecond)`.
  * `modbus_requests` — number of callback invocations attempted during the operation.
  * `objects_requested` — total Modbus objects (registers/coils) covered by
    attempted callbacks.
  * `addresses_read` — total addresses attempted on the wire, including gap
    addresses (read operations only).
  * `gap_addresses_read` — gap addresses read and discarded (read events only).
  * `max_gap_size` — largest address gap bridged (read events only).

  > #### Partial failures {: .info}
  >
  > When an operation requires multiple callbacks and one fails partway through,
  > measurements reflect what was **attempted** (including the failed callback),
  > not what was planned. For example, if a read batches into 3 callbacks and
  > the 2nd fails, `modbus_requests` will be `2`, and `objects_requested` and
  > `addresses_read` will cover only the first two batches.

  ## Metadata details

  * `schema` — the schema module (e.g. `MyDevice.Schema`).
  * `names` — mapping name(s) as a list of atoms. On per-operation events, all
    requested names; on per-callback events, only the names in that batch.
  * `label` — the value of the `:telemetry_label` option passed to
    `ModBoss.read/4` or `ModBoss.write/4`. Can be any term — an atom, tuple, map, etc.
    _Only present when the `:telemetry_label` option is provided._
  * `result` — the raw result: `{:ok, value}` or `{:error, reason}` for reads;
    `:ok` or `{:error, reason}` for writes.
  * `object_type` — `:holding_register`, `:input_register`, `:coil`, or `:discrete_input`.
  * `starting_address` — the starting address for the request.
  * `address_count` — number of addresses in the request.
  """
end
