# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and follows [Semantic Versioning](https://semver.org/).

## [0.1.0+bird2.18] - 2026-08-17

### Added ✨

- Initial commit: router extension packaging, split pipeline design
- Router: install a CA trust store into the extension rootfs

### CI/CD ⚙️

- Migrate to ghcr.io/slipmesh, add license files and release CI
- Tag releases like ../bird: git release tag = published image tag

### Documentation 📚

- Document the fifth repo (talos-nftables-extension) in the split pipeline

### Fixed 🐛

- Fix first real build: drop birdc entirely, fix bird binary path, fix version regex
- Router: fetch a hash-pinned CA bundle instead of assuming one exists

### Reverts ⏪

- Router: revert the rootfs CA-bundle attempt
