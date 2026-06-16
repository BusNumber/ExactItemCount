# Changelog

All notable changes to Exact Item Count are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-06-16

Compatibility release for **Midnight, patch 12.0.7** (retail).

### Changed

- Updated the supported game version to patch 12.0.7.

## [1.0.0] - 2026-06-13

Initial public release. For **Midnight, patch 12.0.5** (retail).

### Added

- Tooltip section showing how many of an item you own, split by **item level** and
  **crafting-quality rank** — so crafted R1–R5 gear (the same item at different item
  levels) is never ambiguous.
- Counts from your **bags** (live), **character bank** and **warband bank** (snapshot taken
  while a bank is open), and **all other scanned characters** (account-wide). Everything
  persists between sessions, so bank and alt counts show up anywhere — even at the mailbox.
- Per-count **location breakdown** (`bags · bank · warband · alts`), with the long tail of
  alts collapsing into a single `+N alts` entry.
- **Upgrade-track badge** (e.g. `H 2/6`) for dropped gear, and **combined per-tier rows**
  for reagents and other quality goods.
- **Options panel** (`/eic`): show each source always / only while a modifier key is held /
  never; compact-tooltip modes; alt-detail modes; bank + warband merge; hide-when-zero.
- **Characters page**: per-character hide and delete, with a scan-age indicator.
- **Live tooltip refresh** — holding or releasing the modifier key over an open tooltip
  updates the counts in place.

[1.0.1]: https://github.com/BusNumber/ExactItemCount/releases/tag/v1.0.1
[1.0.0]: https://github.com/BusNumber/ExactItemCount/releases/tag/v1.0.0
