# Changelog

All notable changes to butler are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-06-12

First public release.

### Added

- `resource verb` CLI for the BuchhaltungsButler API: **transactions**
  (list, show), **receipts** (list, show, upload, delete), **postings**
  (list, create, unconfirm; alias `bookings`), **accounts** (list), plus
  `status`, `login`, `logout`.
- `--output table|json`, client-side `--filter` (table mode),
  `--dry-run` for writes, `--clearing` net-zero assertion for split bookings.
- AWS-style profiles in `$XDG_CONFIG_HOME/butler/credentials` (mode 0600,
  written atomically), `BUTLER_*` environment variables taking precedence;
  `butler login` disables terminal echo while secrets are typed.
- Man page (`man butler`) and `docs/commands.md`, both generated from the
  single command spec in `src/spec.zig`.
- Nix flake (package, devShell, overlay).
