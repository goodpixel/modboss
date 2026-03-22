# Changelog

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
