# Changelog

All notable changes to Exact Item Count are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-07-06

### Changed

- The modifier key now defaults to **Alt** on new installs — Shift doubles as the game's
  compare-items key, so a Shift-gated setting would flip on every gear comparison.
  Existing installs keep whichever key they had selected.
- Holding or releasing the modifier key now also updates **chat-link popups and compare
  tooltips** in place, not just the main tooltip.

### Fixed

- Reagents and other quality goods: the grand total now always equals the sum of the tier
  rows. Previously, an unrelated item that happened to share the name could inflate the
  total, and — right after login — a tier owned only by another character could be counted
  in the total without its row appearing. A tier whose item data hasn't loaded yet is now
  left out of both and shows up on a later hover instead.
- In the rare case where two different items share both a name and a quality tier, the
  merged row's location breakdown now adds up to the row's count.
- Hardened tooltip handling: secure tooltips are never touched, and item tooltips that
  arrive without a full item link no longer risk an error.

## [1.1.1] - 2026-06-17

### Fixed

- Under certain conditions, equipped items could be missing from the counts until you
  changed gear or reloaded. They now appear reliably.

## [1.1.0] - 2026-06-17

### Added

- Counts now include items you have **equipped** — worn gear plus profession, cooking, and
  fishing tools and accessories.
- An **Equipped items** location setting, plus an **Include in count for alts** checkbox
  to fold your other characters' worn gear into their per-character totals.

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

[1.2.0]: https://github.com/BusNumber/ExactItemCount/releases/tag/v1.2.0
[1.1.1]: https://github.com/BusNumber/ExactItemCount/releases/tag/v1.1.1
[1.1.0]: https://github.com/BusNumber/ExactItemCount/releases/tag/v1.1.0
[1.0.1]: https://github.com/BusNumber/ExactItemCount/releases/tag/v1.0.1
[1.0.0]: https://github.com/BusNumber/ExactItemCount/releases/tag/v1.0.0
