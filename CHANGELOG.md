# Changelog

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
