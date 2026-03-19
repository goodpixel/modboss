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

  For descriptions of [measurements](#module-measurement-details) and
  [metadata](#module-metadata-details), see below.

  ### Read Start
      # Event
      [:modboss, :read, :start]

      # Measurements
      %{
        system_time: integer(),
        monotonic_time: integer()
      }

      # Metadata:
      %{
        schema: module(),
        names: [atom()],
        label: term()
      }

  ### Read Stop
      # Event
      [:modboss, :read, :stop]

      # Measurements
      %{
        duration: integer(),
        monotonic_time: integer(),
        modbus_requests: non_neg_integer(),
        total_attempts: pos_integer(),
        objects_requested: non_neg_integer(),
        addresses_read: non_neg_integer(),
        gap_addresses_read: non_neg_integer(),
        max_gap_size: non_neg_integer()
      }

      # Metadata
      %{
        schema: module(),
        names: [atom()],
        label: term(),
        result: term()
      }

  ### Write Start
      # Event
      [:modboss, :write, :start]

      # Measurements
      %{
        system_time: integer(),
        monotonic_time: integer()
      }

      # Metadata
      %{
        schema: module(),
        names: [atom()],
        label: term()
      }

  ### Write Stop
      # Event
      [:modboss, :write, :stop]

      # Measurements
      %{
        duration: integer(),
        monotonic_time: integer(),
        modbus_requests: non_neg_integer(),
        total_attempts: pos_integer(),
        objects_requested: non_neg_integer()
      }

      # Metadata
      %{
        schema: module(),
        names: [atom()],
        label: term(),
        result: term()
      }

  ## Per-callback events

  These events wrap each individual invocation of your `read_func` or `write_func`
  callback—one contiguous address range of one object type.

  For descriptions of [measurements](#module-measurement-details) and
  [metadata](#module-metadata-details), see below.

  ### Read Callback Start
      # Event
      [:modboss, :read_callback, :start]

      # Measurements
      %{
        system_time: integer(),
        monotonic_time: integer()
      }

      # Metadata
      %{
        schema: module(),
        names: [atom()],
        label: term(),
        object_type: atom(),
        starting_address: non_neg_integer(),
        address_count: pos_integer(),
        attempt: pos_integer(),
        max_attempts: pos_integer()
      }

  ### Read Callback Stop
      # Event
      [:modboss, :read_callback, :stop]

      # Measurements
      %{
        duration: integer(),
        monotonic_time: integer(),
        gap_addresses_read: non_neg_integer(),
        max_gap_size: non_neg_integer()
      }

      # Metadata
      %{
        schema: module(),
        names: [atom()],
        label: term(),
        object_type: atom(),
        starting_address: non_neg_integer(),
        address_count: pos_integer(),
        attempt: pos_integer(),
        max_attempts: pos_integer(),
        result: term()
      }

  ### Read Callback Exception
      # Event
      [:modboss, :read_callback, :exception]

      # Measurements
      %{
        duration: integer(),
        monotonic_time: integer()
      }

      # Metadata
      %{
        schema: module(),
        names: [atom()],
        label: term(),
        object_type: atom(),
        starting_address: non_neg_integer(),
        address_count: pos_integer(),
        attempt: pos_integer(),
        max_attempts: pos_integer(),
        kind: atom(),
        reason: term(),
        stacktrace: list()
      }

  ### Write Callback Start
      # Event
      [:modboss, :write_callback, :start]

      # Measurements
      %{
        system_time: integer(),
        monotonic_time: integer()
      }

      # Metadata
      %{
        schema: module(),
        names: [atom()],
        label: term(),
        object_type: atom(),
        starting_address: non_neg_integer(),
        address_count: pos_integer(),
        attempt: pos_integer(),
        max_attempts: pos_integer()
      }

  ### Write Callback Stop
      # Event
      [:modboss, :write_callback, :stop]

      # Measurements
      %{
        duration: integer(),
        monotonic_time: integer()
      }

      # Metadata
      %{
        schema: module(),
        names: [atom()],
        label: term(),
        object_type: atom(),
        starting_address: non_neg_integer(),
        address_count: pos_integer(),
        attempt: pos_integer(),
        max_attempts: pos_integer(),
        result: term()
      }

  ### Write Callback Exception
      # Event
      [:modboss, :write_callback, :exception]

      # Measurements
      %{
        duration: integer(),
        monotonic_time: integer()
      }

      # Metadata
      %{
        schema: module(),
        names: [atom()],
        label: term(),
        object_type: atom(),
        starting_address: non_neg_integer(),
        address_count: pos_integer(),
        attempt: pos_integer(),
        max_attempts: pos_integer(),
        kind: atom(),
        reason: term(),
        stacktrace: list()
      }

  ## Measurement details

  * `duration` — elapsed time in native time units. Convert with
    `System.convert_time_unit(duration, :native, :millisecond)`.
  * `modbus_requests` — number of batches for the operation. Each contiguous
    address range of one object type is one request. Note that this _does not_
    account for retries.
  * `total_attempts` — total number of `read_func`/`write_func` invocations,
    including retries. Equal to `modbus_requests` when no retries were needed.
    The difference of `total_attempts - modbus_requests` is the number of retries.
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
  * `attempt` — which attempted callback invocation this is, from 1 up to `max_attempts`.
  * `max_attempts` — the configured maximum number of attempts for this callback.
  """
end
