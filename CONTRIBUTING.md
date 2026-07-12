# Contributing

Thanks for your interest! Exact Item Count is deliberately small, with a strict
data/presentation split and a handful of display invariants. Please read
[DESIGN.md](DESIGN.md) before changing behavior — it documents *why* the tooltip
renders the way it does, and most "obvious simplifications" are addressed there.

## Originality policy (hard rule)

All contributions must be **original work**, written from public API documentation —
[warcraft.wiki.gg](https://warcraft.wiki.gg), official Blizzard developer docs, or
Blizzard's own UI source for verifying that an API exists.

**Do not port code from other addons**, even when their source is visibly readable:
every addon carries its own license, and unvetted copying puts this project's GPLv3
licensing at risk. PRs that appear derived from another addon's implementation will be
declined.

## Dev setup

1. Clone the repo anywhere and symlink it into your AddOns directory:

   ```
   …/World of Warcraft/_retail_/Interface/AddOns/ExactItemCount → <your clone>
   ```

   The folder (or symlink) name must be exactly **`ExactItemCount`** — it has to match
   the `.toc` base name.
2. Enable Lua error display in-game: `/console scriptErrors 1`.
3. After editing files, `/reload` picks up the changes.

Code conventions: the three Lua files share the private addon table via the
`local addonName, ns = ...` vararg. Keep the data/presentation split — new data sources
go in `Core.lua` behind the `ns.Get*` seams; `Tooltip.lua` reads only through those
seams.

## Static checks & automated tests

WoW globals (`C_Container`, `Enum`, `TooltipDataProcessor`, …) don't exist outside the
game, but the data and display logic is still testable headless:

- `luac -p <file>` — syntax-only compile pass (or `luajit -bl <file> /dev/null`;
  LuaJIT speaks Lua 5.1, the same dialect as WoW, while modern `luac` is 5.4).
- `luacheck .` — uses the repo's `.luacheckrc` (which knows the WoW globals).
- `luajit tests/run_tests.lua` — the headless test suite (below).

CI (`.github/workflows/ci.yml`) runs all three on every push and pull request.

### The test suite (`tests/`)

The suite loads the real `Core.lua`, `Tooltip.lua` **and** `Settings.lua` against the
WoW API stubs in `tests/wow_stubs.lua` (the Settings panel builds against a faked
`Settings` API; its rendered UI is never asserted on) and drives them through the
addon's own event handlers: scans run off fixture bags, banks, and worn gear; tooltips
render through the real `TooltipDataProcessor` post-call into a fake tooltip whose
recorded lines the tests assert on. Each test boots a fresh addon world. What it locks
are the DESIGN.md invariants:

- the grand total equals the sum of the breakdown rows under **every** filter
  combination, and every location suffix sums exactly to its line's count;
- quality-sibling membership is all-or-nothing — a sibling counts toward the total only
  when its tier resolves into a row;
- a bank that can't currently be read never wipes its stored snapshot;
- the settings sanitizer round-trips: persisted `false` survives, junk values reset,
  and a DB-version rebuild carries `settings` over.

The rule of thumb: **when you add or change data-layer or display behavior, add a
test; when a claim needs the real client, add a checklist item below instead.** The
stubs can't model real panel rendering, atlas art, `RefreshData`'s actual pipeline,
item-cache timing, or taint — that's what the in-game checklist is for.

## In-game verification

The addon can only be truly verified in-game. Before submitting display or data-layer
changes, run through the checks relevant to what you touched:

### Core acceptance test — crafted gear ranks

The reason this addon exists:

- [ ] Hold the same crafted item at two ranks (e.g. an R4 and an R5 of one crafted
      piece), split across your bags and the character bank.
- [ ] Hover it: one row per item level, highest first; the hovered variant's row is
      gold (even if you own 0 of it); every row's location suffix sums exactly to that
      row's count; the rows sum exactly to the grand total.

### Equipped items

- [ ] Hover a piece of gear you're **wearing**: the grand total includes it and an
      `equipped N` token appears in the suffix, between `warband` and the alts.
- [ ] Hover an equipped **profession tool/accessory**: it's counted and gets an
      item-level row like any gear.
- [ ] Hold a crafted piece at one rank in your bags while **wearing** another rank: two
      ilvl rows, highest first; the worn rank's row carries `(equipped 1)`; rows sum to
      the total. Swap the worn piece — `PLAYER_EQUIPMENT_CHANGED` rescans, and an open
      tooltip updates on the next hover. (Confirm a **profession-tool** swap, slots
      20–30, also triggers the rescan.)

### Quality goods (reagents)

- [ ] Hover a two-tier reagent you own at both tiers: one row per tier, best first;
      every row's suffix sums to its row; rows sum exactly to the grand total.
- [ ] **Cold cache** — on a fresh login (no `/reload`), hover a reagent whose other
      tier only an alt owns: the sibling tier's row appears with the alt's count. If
      the client hasn't loaded that item's data yet, the sibling may be missing from
      **both** the total and the rows on the first hover and appear on a later
      re-hover — it must never be counted in the total without its own row.

### Persistence lifecycle

- [ ] Open and close the bank; walk away — bank counts still show on tooltips.
- [ ] `/reload` away from the bank — bank counts survive.
- [ ] Log an alt, then return — the other character's counts appear under its name
      (bags, bank, **and** worn gear combined into its per-alt number).

### Settings

- [ ] **Invariant under filtering** — disable a source (e.g. set Bank, or *Equipped
      items*, to *Never*): the total and every row must drop by exactly that source's
      amount, and rows must still sum to the total.
- [ ] **Alts' equipped checkbox** — with an alt that has worn gear scanned, toggle
      "Include in count for alts" (the indented sub-item under *Equipped items*): that
      gear folds into / out of the alt's per-alt number, total still equals the sum.
      Uncheck it, `/reload`: the unchecked (`false`) state must stick.
- [ ] **Live refresh** — set a source to "only while held", then hold/release the
      modifier *while a tooltip is open*: counts appear/vanish in place, and mashing
      the key never duplicates the section. Repeat over an open **chat-link** tooltip
      (click an item link in chat): it must update in place the same way.
- [ ] **Modifier default** — on a fresh install (no saved settings), the modifier key
      defaults to Alt; an existing SavedVariables keeps whatever modifier it stored.
- [ ] **Persistence of falsy values** — check "Hide when total is 0" and "List all
      while key is held", set Bank to *Never*, `/reload`: all three must stick. Then
      uncheck/revert and `/reload` again: the defaults must not resurrect them.
- [ ] **Characters page round-trip** — hide a character via the eye: its counts are
      gone on the next hover. Delete one: confirmation popup, then row and counts are
      gone. The current character must never show a delete button.
- [ ] **Detail-mode parenting** — set alt detail to *All*: the list-all checkbox reads
      checked and disabled, and the Top-N slider grays out. Switch back to *Top N*:
      both re-enable and the checkbox returns to its own stored value. With the
      checkbox on and detail *Top N*, holding the key over an open tooltip must name
      every alt in place.
