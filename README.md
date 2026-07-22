# Exact Item Count

A lightweight World of Warcraft addon that tells you **how many of an item you own — broken down by item level and crafting quality** — right in the item tooltip.

> Currently, for **Midnight, patch 12.0.7** (retail) only.

## Why

Most "how many do I have?" addons count purely by item. But crafted profession gear's R1–R5 ranks are all the **same item at different item levels**, so a plain count of "2" can't tell you whether those are the **R5** you're about to craft or a different rank sitting in your bags.

Exact Item Count splits the count by item level and labels each with its crafting-quality rank, so you can tell at a glance.

## What it shows

When you hover an item, a section is added under the normal tooltip. Every count carries a dimmed where-is-it breakdown — your bags, your bank, the warband bank, the gear you have equipped, and each of your other characters by name. (`★n` below stands in for the in-game quality icon.)

**Crafted / equippable gear** — total, plus a row per item level (highest first) with its crafting-quality icon. Worn gear and profession tools/accessories count too, shown with an `equipped` tag. The variant you're hovering is always listed, even if you own none of it:

```
Total items owned: 3 (bags 2 · equipped 1)
  681 ★5: 0
  668 ★4: 3 (bags 2 · equipped 1)
```

Dropped gear shows its upgrade track instead — the track's first letter plus progress, e.g. Hero 2/6:

```
Total items owned: 2 (bags 1 · Liara 1)
  658 (H 2/6): 1 (bags 1)
  645 (V 4/8): 1 (Liara 1)
```

**Reagents and other quality goods** — the silver and gold tiers are technically different items, but they're counted together under one total, one row per tier (best first):

```
Total items owned: 130 (bags 40 · warband 60 · Liara 30)
  ★2: 90 (warband 60 · Liara 30)
  ★1: 40 (bags 40)
```

**Recipes** — the recipe's own count, plus the count of the **item it crafts** (that's
usually the number you're actually after — "do I need to craft more of these?"), with
its full breakdown:

```
Total items owned: 1 (bags 1)
Crafted items: 12 (bags 4 · Liara 8)
  ★2: 8 (Liara 8)
  ★1: 4 (bags 4)
```

**Everything else** — just the total:

```
Total items owned: 5 (bags 1 · warband 3 · Liara 1)
```

If you own none anywhere, the section collapses to `Total items owned: 0`. And if you have a small army of alts, the long tail of names collapses into a single `+4 alts 22`.

## Installation

**Manual:**

1. Download/clone this addon.
2. Copy the folder into your AddOns directory so it sits at:
  - **Windows:** `World of Warcraft\_retail_\Interface\AddOns\ExactItemCount\`
  - **macOS:** `World of Warcraft/_retail_/Interface/AddOns/ExactItemCount/`
3. The folder name must be **`ExactItemCount`** (it has to match `ExactItemCount.toc`).
4. Restart WoW, or `/reload` if it's running. Make sure **Exact Item Count** is enabled in the AddOns list on the character-select screen.

That's it. Options live under **Options → AddOns → Exact Item Count** (or `/eic`): toggle each location — bank, warband bank, equipped items, other characters (always / only while a modifier key is held / never), plus a checkbox for whether to count your alts' equipped gear; compact-tooltip modes, including whether recipe tooltips count the crafted item (always / only while the key is held / never); and a list of your scanned characters with per-character hide and delete.

## Scope (current version)

- ✅ Bags (live), character bank and warband bank (updated whenever you visit a bank)
- ✅ Equipped items — worn gear plus profession tools and accessories (updated as you change gear)
- ✅ All of your characters — anything scanned while playing an alt shows up account-wide
- ✅ Per-item-level breakdown with crafting-quality rank and upgrade-track progress
- ✅ Recipes: the crafted item is counted too, with its own breakdown
- ✅ Where-it-is breakdown on every count
- ✅ Settings (display-only filtering — what's counted on screen, never what's cached)
- ⬜ Amount of gold *(planned)*

## Performance & safety

Light by design: it reads your bags only when their contents change, rereads your equipped gear when you swap a piece, snapshots your bank and warband bank while the bank window is open, and adds a few lines to tooltips. Snapshots are remembered between sessions (saved in the `ExactItemCountDB` saved variable), which is how bank and alt counts stay available anywhere — even at the mailbox on another character. It performs **read-only** operations and does nothing that could taint Blizzard's secure code.

## Contributing

Bug reports and PRs are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) for the
dev setup and the in-game test checklist, and [DESIGN.md](DESIGN.md) for why the
tooltip renders the way it does. One hard rule: all code must be original work —
nothing ported from other addons, whatever their license.

## Support

Exact Item Count is free and always will be. If it spares you some bag math, you can
[buy me a coffee](https://buymeacoffee.com/busnumber). ☕

## License

Copyright © 2026 BusNumber.

Licensed under the [GNU General Public License v3.0](LICENSE).

---

World of Warcraft and Blizzard Entertainment are trademarks or registered trademarks of
Blizzard Entertainment, Inc. This addon is unofficial and is not affiliated with or
endorsed by Blizzard Entertainment.
