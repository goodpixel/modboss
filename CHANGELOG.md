# Changelog

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.3.0]

### Changed

- Rename the `names` telemetry metadata to `requested_names` on
  `[:modboss, :read]`/`[:modboss, :write]` events.
- Rename the `total_attempts` telemetry measurement to `callback_invocations`
  on `[:modboss, :read]`/`[:modboss, :write]` events.
- `batches` telemetry now counts the total number of batches the
  operation's addresses were divided into (i.e. the planned batches)
  rather than how many were actually attempted before a partial failure.

### Added

- Add the `:if` schema option, allowing mappings to be conditionally supported at runtime
  based on context. Unsupported mappings are short-circuited; they are neither read nor written
  during `ModBoss.read/4` or `ModBoss.write/4`, and they are dropped from `ModBoss.encode/3`.
- Add `unsupported_names` telemetry metadata to `[:modboss, :read, :stop]` /
  `[:modboss, :write, :stop]` events—which includes names of mappings excluded because
  their `:if` condition didn't evaluate to `true` for the provided context.
- Add `gap_ranges` telemetry metadata to `[:modboss, :read, :stop]` events. This is a list of
  `{type, starting_address, address_count}` tuples describing every gap bridged during the read
  to reduce the overall number of batches required.
- Add a `retries` measurement to `[:modboss, :read, :stop]`/`[:modboss, :write, :stop]`
  events; indicates the number of `read_func`/`write_func` invocations that were not the
  first attempt for their batch (because the first attempt failed).

### Removed

- Drop `names` telemetry on `:read_callback`/`:write_callback` events. These callbacks are
  less focused on mappings and more about addresses.
- Drop the `objects_requested` and `addresses_read` measurements from
  `[:modboss, :read]`/`[:modboss, :write]` events (per-callback events still report
  `object_type`, `starting_address`, and `address_count` for each batch actually attempted).
- Drop the `gap_addresses_read`/`largest_gap` measurements from
  `[:modboss, :read, :stop]`/`[:modboss, :read_callback, :stop]` events in favor of the new
  `gap_ranges` on telemetry on `[:modboss, :read, :stop]`.

### Fixed

- Allow modbus address reuse across object types. This was previously unblocked at the Schema
  level, but retrieved values weren't properly labeled according to their type, so values for a
  particular address from one object type were incorrectly associated with that address for
  a different object type.
- `ModBoss.write/4` now emits `:start` (and `:exception`, or `:start` +
  `:stop` with an error result) telemetry for failure paths that previously
  emitted no telemetry at all—an invalid `:if` callback return value, or an
  encoding failure during write. Planning and encoding now happen inside the
  telemetry span rather than before it.

See `ModBoss.Telemetry` for the full, current event/measurement/metadata
contract.

## [v0.2.0]

### Added

- Add BEAM telemetry support via optional `:telemetry` dependency.
- Enable improved read batching via `:max_gap` option at runtime.
- Add compile time `gap_safe: false` option to flag mappings as ineligible for gap reads.
- Add `:max_attempts` option to automatically retry failed read/write callbacks.
- Support optional 2-arity encode/decode functions which receive
  `%ModBoss.Encoding.Metadata{}` struct as the second argument.
- Add `:context` option to `ModBoss.read/4`, `ModBoss.encode/3`, and `ModBoss.write/4`
  for passing arbitrary contextual info to encode/decode functions and telemetry metadata.
- Add `debug: true` option to `ModBoss.read/4` which returns detailed mapping info
  alongside values.

### Changed

- Rename `modbus_schema` macro to `schema`.
- Swap the order of the 2nd and 3rd arguments to `ModBoss.read/4` and `ModBoss.write/4` to
  better align with Elixir conventions and improve readability of pipelines.

### Fixed

- Return an error tuple when a decode function returns an error (previously would crash
  with a match error).
- Skip decoding of Mapping when `decode: false` is passed to `ModBoss.read/4`. Previously, this
  opt caused us to return the encoded version, but we would still decode under the hood.
  This meant if there was a bug in the decoding logic, `ModBoss.read/4` would fail even if
  `decode: false` had been passed. This fix improves debuggability.

## [v0.1.1]

### Added

- Add `ModBoss.encode/2` for encoding mappings to objects without actually writing via Modbus.

### Changed

- Don't allow `:all` as an object name in a schema; reserve it as a special keyword for requesting
  all readable registers.

### Removed

- Remove undocumented `ModBoss.read_all/2`. In practice, it seems simpler to use a reserved `:all`
  keyword to read all objects configured as readable.

### Fixed

- Allow address reuse across object types per the Modbus spec.

## [v0.1.0]

### Initial Release
