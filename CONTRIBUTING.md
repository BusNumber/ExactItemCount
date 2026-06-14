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

## Static checks

WoW globals (`C_Container`, `Enum`, `TooltipDataProcessor`, …) don't exist outside the
game, so only syntax-level checks are meaningful locally:

- `luac -p <file>` — syntax-only compile pass (or `luajit -bl <file> /dev/null`;
  LuaJIT speaks Lua 5.1, the same dialect as WoW, while modern `luac` is 5.4).
- `luacheck .` — uses the repo's `.luacheckrc` (which knows the WoW globals).

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

### Persistence lifecycle

- [ ] Open and close the bank; walk away — bank counts still show on tooltips.
- [ ] `/reload` away from the bank — bank counts survive.
- [ ] Log an alt, then return — the other character's counts appear under its name.

### Settings

- [ ] **Invariant under filtering** — disable a source (e.g. set Bank to *Never*): the
      total and every row must drop by exactly that source's amount, and rows must
      still sum to the total.
- [ ] **Live refresh** — set a source to "only while held", then hold/release the
      modifier *while a tooltip is open*: counts appear/vanish in place, and mashing
      the key never duplicates the section.
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
