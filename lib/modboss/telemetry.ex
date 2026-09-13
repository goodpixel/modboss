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
        requested_names: [atom()],
        context: map()
      }

  ### Read Stop
      # Event
      [:modboss, :read, :stop]

      # Measurements
      %{
        duration: integer(),
        monotonic_time: integer(),
        batches: non_neg_integer(),
        callback_invocations: non_neg_integer(),
        retries: non_neg_integer()
      }

      # Metadata
      %{
        schema: module(),
        requested_names: [atom()],
        context: map(),
        unsupported_names: [atom()],
        gap_ranges: [{atom(), non_neg_integer(), pos_integer()}],
        result: term()
      }

  ### Read Exception
      # Event
      [:modboss, :read, :exception]

      # Measurements
      %{
        duration: integer(),
        monotonic_time: integer()
      }

      # Metadata
      %{
        schema: module(),
        requested_names: [atom()],
        context: map(),
        kind: atom(),
        reason: term(),
        stacktrace: list()
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
        requested_names: [atom()],
        context: map()
      }

  ### Write Stop
      # Event
      [:modboss, :write, :stop]

      # Measurements
      %{
        duration: integer(),
        monotonic_time: integer(),
        batches: non_neg_integer(),
        callback_invocations: non_neg_integer(),
        retries: non_neg_integer()
      }

      # Metadata
      %{
        schema: module(),
        requested_names: [atom()],
        context: map(),
        unsupported_names: [atom()],
        result: term()
      }

  ### Write Exception
      # Event
      [:modboss, :write, :exception]

      # Measurements
      %{
        duration: integer(),
        monotonic_time: integer()
      }

      # Metadata
      %{
        schema: module(),
        requested_names: [atom()],
        context: map(),
        kind: atom(),
        reason: term(),
        stacktrace: list()
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
        context: map(),
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
        monotonic_time: integer()
      }

      # Metadata
      %{
        schema: module(),
        context: map(),
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
        context: map(),
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
        context: map(),
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
        context: map(),
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
        context: map(),
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
  * `batches` — how many batches the operation's addresses were divided into.
    This reflects the **planned batches**, not how many were actually attempted in a failure case.
  * `callback_invocations` — total number of `read_func`/`write_func`
    invocations for the operation, including retries.
  * `retries` — how many of those invocations were retries (i.e. not the
    first attempt for their batch).

  ## Metadata details

  * `schema` — the schema module (e.g. `MyDevice.Schema`).
  * `requested_names` — names of mappings requested for the ModBoss.read/write.
  * `context` — the value of the `:context` option passed to `ModBoss.read/4`
    or `ModBoss.write/4`. Defaults to `%{}` when not provided.
  * `unsupported_names` — requested mapping names whose `:if` condition did not evaluate
    to `true` for the given context. These mappings are short-circuited;
    they are neither read from nor written to via the read/write callbacks.
  * `gap_ranges` — List of `{type, starting_address, address_count}` describing every gap
    bridged as part of the operation (see the "Gaps" section of `ModBoss.read/4`).
  * `object_type` — Modbus object type for the request.
  * `starting_address` — the starting address for the request.
  * `address_count` — number of addresses in the request.
  * `attempt` — which attempted callback invocation this is, from 1 up to `max_attempts`.
  * `max_attempts` — the configured maximum number of attempts for this callback.
  * `result` — the raw `{:ok, value}`/`{:error, reason}` result for reads or
    `:ok`/`{:error, reason}` result for writes.
  """
end
