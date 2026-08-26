# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Documentation 📚

- Address the reader who cloned one repository, not five
- State the facts, drop how they were found
- Describe the predecessor without linking to it
- State the facts, drop how they were found
- Stop telling the reader to run a target that does not exist
- Scope the QEMU note to local builds

### Miscellaneous 🧹

- Add the standard markdownlint config, fix what it found

## [0.1.2+bird2.18] - 2026-08-19

### CI/CD ⚙️

- Pin amd64 matrix runner to ubuntu-24.04, not the floating ubuntu-latest alias

## [0.1.1+bird2.18] - 2026-08-19

### CI/CD ⚙️

- Build arm64 on a native runner instead of QEMU-emulated amd64

### Miscellaneous 🧹

- Retag for Talos 1.13.9 (no BIRD change)

## [0.1.0+bird2.18] - 2026-08-17

### Added ✨

- Initial commit: router extension packaging, split pipeline design
- Router: install a CA trust store into the extension rootfs

### CI/CD ⚙️

- Migrate to ghcr.io/slipmesh, add license files and release CI
- Tag releases like the bird repo: git release tag = published image tag

### Documentation 📚

- Document the fifth repo (talos-nftables-extension) in the split pipeline

### Fixed 🐛

- Fix first real build: drop birdc entirely, fix bird binary path, fix version regex
- Router: fetch a hash-pinned CA bundle instead of assuming one exists

### Reverts ⏪

- Router: revert the rootfs CA-bundle attempt
