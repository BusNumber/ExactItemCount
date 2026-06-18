# Exact Item Count — Design Notes

This document explains **why** the tooltip renders the way it does, how the code is
structured, and the WoW API landmines the implementation steps around. If you're about
to change display behavior, check here first — several "obvious simplifications" were
considered and rejected for reasons written down below.

## The core data fact

Everything in this addon rests on how quality is encoded for different item families:

- **Crafted gear**: the R1–R5 crafting qualities are the **same itemID at different item
  levels** — quality is a bonus-ID modifier that changes ilvl. A plain per-itemID count
  of "2" when you hold two R4s is ambiguous: you can't tell whether those are the R5s
  you're about to craft or a different rank. So gear variants are discriminated **by
  item level**.
- **Reagents** (gathered or crafted): each quality tier is a **distinct itemID**. Tiers
  already count separately; the work goes the other way — joining the siblings back
  together under one shared total and labeling each tier's star.

## What the tooltip shows

### Sources

Counts come from the current character's **bags** (backpack + 4 bags + reagent bag,
live), the **character bank** and **warband (account) bank** (snapshots taken while the
bank is open), the character's **equipped** items (worn gear plus profession/cooking/
fishing tools & accessories, rescanned on every equipment change), and **alts** (every
character the addon has scanned, bags + bank + equipped combined per alt). Everything
persists in the `ExactItemCountDB` SavedVariable, so bank, equipped, and alt data survive
relogs.

The DB always stays complete; the settings layer filters **display only**. That makes
every setting instantly reversible — no rescan is needed to undo a filter.

The section is appended under Blizzard's standard lines, on every item tooltip.

### The grand total

There is **one grand total** that always equals the sum of everything displayed below
it — never split "you vs alts" totals. The invariant lives in the data layer
(`ns.GetByName`'s `combined`), not in the renderer, so no rendering path can break it.

`Total items owned: N` is always shown (including `0`) as a single **left-aligned**
line with the count inline after the label. `AddDoubleLine`'s right column is avoided
deliberately: its position drifts with whatever Blizzard or addon line happens to set
the tooltip's width.

### Equippable gear

Weapons, armor, **and profession tools/accessories** always get a per-ilvl breakdown —
all gear has an item level worth showing, *including* plain dropped pieces (their ilvl
is in Blizzard's tooltip). One row per ilvl, **highest first**, reading
`<ilvl> <star>: <count> (<locations>)`:

- **ilvl leads, the rank star trails as a badge** — crest brackets mean the same crafting
  rank legitimately exists at far-apart ilvls, so rank alone doesn't even sort gear.
  The order matches the game's own name-then-quality-icon convention.
- The star stays on combat gear (recraft signal: a low-bracket R5 is maxed, an R4
  isn't) and is the label players may actually read on profession tools.
- Dropped gear on an **upgrade track** reads `<ilvl> (H 1/6): N` — the first character of
  the track name plus upgrade progress (Explorer/Adventurer/Veteran/Champion/Hero/Myth →
  E/A/V/C/H/M, unique in English). The badge is *not* a translated label: the track has no
  structured API, so the only thing the addon ever sees is Blizzard's already-localized
  track string, and the glyph is simply its first character. On a non-English client the
  letter is therefore that locale's first character, and its uniqueness across tracks is
  **not** guaranteed — a same-first-letter collision between two tracks is possible and
  accepted. The rest of the addon is English-only; this one badge is deliberately left as a
  glyph derived from Blizzard's string rather than translated or mapped to English (mapping
  back would need a per-locale name table, since the English name is never available to us).
  Tracks and crafting ranks never co-occur: crafted gear is recrafted, not upgraded.
- Trackless plain gear rows read `ilvl X: N`.

The hovered item's own rank/ilvl is always listed even if owned 0 — but only while the
grand total is above zero (you own the item at some *other* ilvl/rank); a zero total
collapses the whole section to one line, see [Zero totals](#zero-totals) below. That row
is gold with a white count, the rest dim gray. The synthetic owned-0 row has no locations, so
it carries no suffix.

### Quality goods (reagents, crafted consumables)

Each tier is a distinct itemID under one shared **name**, so the count is combined
across name-siblings into one total with **one row per tier** below:
`<star>: N (<locations>)`. The star icon alone is the row label — reagents have no
meaningful ilvl — and the colon carries the label color, because atlas markup ignores
surrounding color codes.

Tier order is **fixed best-first** (gold before silver), so the section is identical
whichever sibling is hovered; only the emphasis moves — hovered tier gold/white (shown
even at 0), the rest dim.

### Plain items

Food, recipes, lumber, sparks, treatises etc. have neither quality nor item level in
Blizzard's tooltip, so they collapse to just the total, with the location suffix
attached directly to it: `Total items owned: 5 (bags 1 · warband 3 · Liara 1)`.

Detection: non-equippable with no crafting/reagent quality (`GetQuality` returns nil).
Many of these carry a hidden internal ilvl in the API (e.g. sparks); it is never
displayed — the equip-loc gate, not the ilvl's existence, decides whether ilvl is
meaningful.

### The location suffix

The total line and each breakdown row carry a dimmed per-location split:
`645 <star>: 3 (bags 2 · bank 1 · warband 3 · equipped 1 · Liara 1)`.

- Fixed order `bags · bank · warband · equipped · alts`, with alts sorted **count
  descending**. Zero-count locations are omitted.
- Shown whenever the count is above zero, **including single-location** (`(bags 3)`) —
  a no-suffix line never needs interpreting.
- The whole `bags <n>` token renders one step brighter than the rest of the suffix, so
  "how many on me right now" is one glance and *no bright token* reads as "none on
  you". It stays below the row's primary count. Emphasis ladder: white count > dim row
  text > bags token > suffix base (hexes in `Tooltip.lua`).
- The `equipped <n>` token (the character's **own** worn gear) sits at the suffix base
  like bank/warband — only `bags` gets the brighter "on me right now" emphasis, since
  that token specifically flags loose, grab-and-use inventory; worn gear is a distinct
  category. Alts' worn gear is not a separate token: it folds into the alt's combined
  name+count, gated by the `altEquipped` checkbox (see [Settings](#settings)).
- Bare `bags`/`bank`/`equipped` always mean the character you're on. Alts are **name +
  count only** (`Liara 140`), realm stripped — same-named alts across realms merge in
  display; the DB key keeps the realm.
- **Source-major lines** (`Bags: N` per location, the way inventory addons usually
  render it) are rejected: they re-ambiguate the per-variant counts this addon exists
  to split.
- **Alt detail is Top-N by count** (`altsDetail`/`altsTopN`, default top 2): the three
  fixed tokens always show, the top N alts are named, and the remainder collapses into
  one dim `+4 alts 22` token whose count keeps every suffix summing exactly to its
  line's count. A tail of exactly one alt is named instead of collapsed (`+1 alts 3`
  saves nothing over the name and says less); the cut point is as stable as the
  count-desc sort. Alternative modes: every alt named, or a single `alts 22` total
  token.
- Bank + warband can render as one combined `banks N` token (`bankMerge`, optionally
  modifier-gated); merging only happens when **both** are present — a lone token never
  merges.

### Ordering and hover marking

Ordering is always **fixed best-first with highlight-only hover marking** — the section
never reshuffles based on which sibling or variant you hover; the gold/white emphasis
alone moves.

### Zero totals

A zero total collapses the section to just `Total items owned: 0` — no breakdown rows,
no tier split: a zero total implies every variant is zero. The "hovered variant shown
even at 0" rule applies only while the total is above zero (an unowned R5 row beside
owned R4s; a 0-gold tier beside owned silver). The `hideZero` setting (off by default)
drops the zero-total section entirely — checked **before** the spacer line so nothing
strays.

### Settings

The panel (Options → AddOns → Exact Item Count, or `/eic`; `Settings.lua`) is
account-wide, stored in `ExactItemCountDB.settings`, and **display-only by design** —
scans never change with settings.

- **Locations**: the current character's bags are **always counted** — no setting; it's
  the one source whose absence would make every tooltip lie about what's in hand. Bank /
  Warband bank / Equipped items / Other characters are each one tri-state: *Always show* /
  *Only while \[modifier\] held* / *Never*. A gated-off source is excluded from **all**
  displayed numbers (grand total, rows, suffix), so the total-equals-sum invariant
  survives any combination — the filter is applied at the data-layer iteration root, not
  in the renderer. *Equipped items* gates only the **current** character's worn gear; a
  separate **Include in count for alts** checkbox (`altEquipped`, on by default), nested
  as an indented sub-item under the *Equipped items* dropdown (via `SetParentInitializer`
  for the margin; always enabled — it governs alts, not this character's own equipped
  setting), gates whether alts' worn gear folds into their per-alt total. (A boolean, not
  a tri-state: alts have no per-source suffix tokens to modifier-gate, so the only
  meaningful choice is in/out.)
- **Compact tooltip**: modifier key (Shift default / Alt / Ctrl); the location suffix
  and the breakdown rows can each independently be *Always* or *only-while-held*; alts
  detail mode with a *List all while key is held* checkbox (`altsExpandKey`, default
  off — the label says a generic "key" because checkbox names can't self-heal; see
  gotchas) that promotes any detail mode to every-alt-named while the key is down — it
  reads as checked **and disabled** while the mode is already *All*; the Top-N slider
  is likewise disabled unless *Top N* is the selected mode; bank/warband suffix
  merging; hide-at-zero ("Hide when total is 0").
- Modifier state is read live per render **and** a `MODIFIER_STATE_CHANGED` watcher
  rebuilds a visible tooltip in place via `GameTooltip:RefreshData()`, so holding the
  key updates an open tooltip without re-hovering.
- **Characters page** (canvas subcategory): every scanned char as full `Name-Realm`
  (the one place realm-twins are distinguishable), current char marked and sorted
  first, scan-age per snapshot (`bags 2h ago · bank never`), an eye toggling the
  account-wide `hiddenChars` flag (present on the current char's row too — it controls
  visibility in *other* characters' sessions), and a delete button (confirmation
  popup; never on the current character) that drops the char's cached data via
  `ns.DeleteChar`.

## Architecture

```
### ExactItemCount.toc

Manifest. `## SavedVariables: ExactItemCountDB`. Loads Core.lua, Tooltip.lua, Settings.lua (order matters).

### Core.lua

Data layer: SavedVariables DB + container scans + events + aggregation. Owns `ns.Get`, `ns.GetByName`, `ns.GetCharKey`, `ns.DeleteChar`, plus the shared helpers `ns.IsGearEquipLoc`, `ns.ParseUpgradeTrack`.

### Tooltip.lua

Presentation: TooltipDataProcessor hook + display logic + the MODIFIER_STATE_CHANGED refresh watcher. Reads via the `ns.*` seams only.

### Settings.lua

Settings layer: defaults/sanitizing for `db.settings`, the Options panel (vertical layout + Characters canvas subcategory), `/eic`. Owns `ns.InitSettings`, `ns.GetSettings`.
```

Files share the private addon table via the `local addonName, ns = ...` vararg. **Keep
the data/presentation split**: new sources go in the data layer; `Tooltip.lua` reads
only through the `ns.Get*` seams. Start-up hand-off: Core's `ADDON_LOADED` handler
initializes the DB then calls `ns.InitSettings(db)` — safe because the event fires only
after every file's main chunk has run; `ns.GetSettings()` returns nil until then and
the tooltip layer treats nil as "default behavior".

New sources (e.g. a guild bank) plug in behind the `ns.Get`/`ns.GetByName` seams in
`Core.lua` without changing the tooltip layer — equipped items were added exactly this
way (a `ScanEquipped` snapshot store + one extra visit in `ForEachSourceStore`).

### DB schema

```
ExactItemCountDB = {
  version = 1,
  addonVersion = "<TOC version string>",                       -- write-only diagnostic, never read
  warband = { scannedAt = <epoch>, items = <items> },          -- account bank: account-level
  chars = {
    ["Name-NormalizedRealm"] = {
      bags     = { scannedAt = <epoch>, items = <items> },
      bank     = { scannedAt = <epoch>, items = <items> },
      equipped = { scannedAt = <epoch>, items = <items> },     -- currently-worn gear/tools
    },
  },
  settings = {                                                 -- account-wide display settings
    hideZero = false, altsExpandKey = false,                   -- booleans (bags: no setting)
    altEquipped = true,                                        -- count alts' worn gear too
    bankMode/warbandMode/equippedMode/altsMode = "always"|"modifier"|"never",
    modifier = "SHIFT"|"ALT"|"CTRL",
    suffixMode/rowsMode = "always"|"modifier",
    altsDetail = "topn"|"all"|"total", altsTopN = 2,           -- 1..10
    bankMerge = "separate"|"modifier"|"merged",                -- "modifier" = merged UNLESS held
    hiddenChars = { ["Name-NormalizedRealm"] = true },         -- true or absent, never false
  },
}
```

Every snapshot's `items` shares one shape:
`items[itemID] = { total = <n>, link = <hyperlink>, groups = { [ilvl] = { count = <n>,
link = <hyperlink>, track = <nil | { name, step, max }> }, ... } }` — plain data,
serializes as-is. A representative `link` is kept per group (and one at the entry
level) so crafting quality / item name can be resolved lazily at display time (keeps
the scan cheap). `track` is the upgrade track (gear only), captured once per group with
the same representative first-stack-wins semantics — a same-ilvl cross-track collision
is rare and tolerated.

**The current character's bag scan writes straight into its own `chars` entry** — the
DB is the single source of truth; an alt session reads this character exactly the way
this session reads alts. Snapshots are fresh tables swapped wholesale (nothing outside
the data layer holds a reference to one).

### Versioning policy

`DB_VERSION` is checked at `ADDON_LOADED`. Everything in the DB except `settings` is a
rebuildable cache (bags rescan at login, banks at the next bank visit, alts when next
logged in), so **"bump `DB_VERSION` and reset" is the migration strategy** — a mismatch
(including a downgrade: an older addon reading a newer DB) rebuilds the DB but
**carries `settings` over**, the one piece of real user data. Real
`version == k → transform` migration code is only warranted if a future version ever
stores non-reconstructible data beyond `settings`.

**Additive changes never bump the version** (new optional field, new setting, new
source store): readers tolerate `nil`, and `ns.InitSettings` sanitizes whatever
settings table arrives — default-fills missing keys with `== nil` checks (never falsy —
a persisted `false` must survive), resets out-of-enum/of-range/wrong-type values to
defaults, and prunes `hiddenChars` flags whose character data is gone (a hidden flag is
meaningless without the data — the same semantics as `ns.DeleteChar`). If a setting is
ever removed, its persisted key gets explicitly dropped there too.

`addonVersion` (the TOC version string, restamped every load) is a write-only
diagnostic for SavedVariables files attached to bug reports — it never drives logic.

### Seams

Aggregated views are built fresh per hover — the stores are tiny; a cache would only
buy invalidation bugs.

- `ns.Get(itemID, filter)` → `nil` (owned nowhere, or nowhere visible) or
  `{ total, link, sources, groups = { [ilvl] = { count, link, track, sources } } }`
  where every `sources` is
  `{ bags = n, bank = n, equipped = n, warband = n, alts = { [name] = n } }` with
  zero-count keys **absent** (so "non-zero only" in the suffix holds by construction).
  The `equipped` key is the **current** character's worn gear only; an alt's worn gear
  is summed into its `alts[name]` entry alongside its bags/bank. Link/track
  representatives: first non-nil in visit order — own bags > own bank > own equipped >
  warband > alts.
- `ns.GetByName(itemID, filter)` → `(name, members, combined)`: `members` is an array
  of `ns.Get` views (plus an `itemID` field) for every name-sibling itemID anywhere in
  the DB; `combined = { total, sources }` summed across them, so the grand-total
  invariant lives in the data layer.
- `filter` (optional, nil = everything):
  `{ bags/bank/equipped/warband/alts = bool, altEquipped = bool,
  hiddenChars = { [fullKey] = true } }`, applied inside `ForEachSourceStore` — the one
  place the full `Name-Realm` key is in hand. `equipped` gates the current character's
  worn gear; `altEquipped` gates whether each alt's worn gear folds into its per-alt
  number. (Callbacks only see realm-stripped display names.) `GetByName` threads it through
  **both** its passes so a sibling owned only in a filtered-out source contributes
  neither a row nor a total share. The tooltip layer builds the filter per render
  (`BuildFilter` in `Tooltip.lua`), folding live modifier state into the tri-state
  settings.
- `ns.GetSettings()` → the live settings table (nil before init ⇒ default display);
  `ns.GetCharKey()` → current char's full key (nil before PEW); `ns.DeleteChar(key)` →
  drops a char's data + hidden flag, refuses the current char and refuses everything
  while the own key is unresolved.

## WoW API implementation notes (gotchas)

Facts about the current API surface (Midnight, 12.0.x). Most of these are the reason
a given line of code looks the way it does.

- **Identify the hovered item by `data.id`, not the link.** `TooltipData` for an item
  carries both `id` (the canonical itemID actually being shown) and `hyperlink`. A
  **recipe** tooltip embeds its crafted product, so the displayed link
  (`data.hyperlink` / `TooltipUtil.GetDisplayedItem`) can resolve to that *product*
  (owned 0) instead of the recipe. Key the count off `data.id`; if the resolved link's
  itemID disagrees with `data.id`, it's the embedded item — drop the link (it's still
  needed for quality/ilvl, but only when it matches).
- **"Gear" is detected via `itemEquipLoc`** (4th return of
  `C_Item.GetItemInfoInstant`), **not** item class. Profession equipment is item class
  19 (Profession), not Weapon/Armor — keying off class would miss the addon's primary
  use case. The gate is the shared `ns.IsGearEquipLoc`, which excludes `""`,
  `INVTYPE_BAG`, and — crucially — `INVTYPE_NON_EQUIP_IGNORE`: non-equippables return
  **that** token, renamed from `INVTYPE_NON_EQUIP` in 10.2.6 (the old name is still
  denylisted defensively). Checking only the old name silently classifies *everything*
  as gear — reagents and Hearthstones grow ilvl rows.
- **Upgrade track** (Explorer/…/Myth) has **no structured public API**. It's parsed
  from tooltip lines: match `leftText` against a Lua pattern built at load from
  Blizzard's localized `ITEM_UPGRADE_TOOLTIP_FORMAT_STRING`
  (`"Upgrade Level: %s %d/%d"`) — locale-safe by construction; token order is recorded
  so positional (`%1$s`) locales map captures correctly. Owned stacks:
  `C_TooltipInfo.GetBagItem(bag, slot).lines` at scan time, fetched only once per new
  gear group. Hovered item: the hook's own `data.lines` (lines are pre-surfaced since
  10.1 — `leftText` is directly readable, no `TooltipUtil.SurfaceArgs` needed).
- **Crafting quality** comes from
  `C_TradeSkillUI.GetItemCraftedQualityByItemInfo(link)` (gear, 1–5) with
  `C_TradeSkillUI.GetItemReagentQualityByItemInfo(link)` (reagents, **1–2** in
  Midnight — cut from three tiers to two) as fallback. **Pass the full hyperlink**, not
  the bare itemID, so bonus IDs resolve the correct per-quality value.
- **Grouping a quality good's tiers** (silver/gold of the same reagent): there is **no
  API that maps quality siblings**, and each tier is a distinct itemID. They reliably
  share the same base **name** (the star is an icon overlay, not in the name string),
  so name is the join key — via `C_Item.GetItemNameByID(itemID)`, done lazily at hover
  (`ns.GetByName`) because the stores are tiny. **Cross-character wrinkle**:
  `GetItemNameByID` returns nil for itemIDs this session has never seen (alt-owned
  items on a fresh login), so the fallback join key is the bracket name embedded in the
  stored representative hyperlink (`link:match("%[(.-)%]")`), captured at scan time
  when the item was demonstrably present. (Cross-locale accounts break this link-name
  join — accepted, rare.)
- **Quality star icon** — two atlas families, keyed by source: crafted **gear** uses
  `Professions-ChatIcon-Quality-Tier{1..5}`; **reagents** use Midnight's redesigned
  two-tier set `Professions-ChatIcon-Quality-12-Tier{1,2}` (1 = silver, 2 = gold — note
  the `-12-` patch infix). Using the gear `Tier1/Tier2` for reagents renders the wrong
  (pre-Midnight) art, not a blank, so it's easy to miss. Built via
  `CreateAtlasMarkup(atlas, 16, 16)`; if an atlas name ever renders blank, that's the
  first thing to check. (The old shortcut
  `C_Texture.GetCraftingReagentQualityChatIcon` was removed in 12.0 — don't reach for
  it.)
- **Item level** per stack: `C_Item.GetCurrentItemLevel(ItemLocation)` (reuse one
  `ItemLocation` via `:SetBagAndSlot` for containers or `:SetEquipmentSlot` for worn
  items, to avoid allocations), with `C_Item.GetDetailedItemLevelInfo(link)` as fallback
  for uncached stragglers.
- **Rescan events**: bags — `PLAYER_ENTERING_WORLD` + `BAG_UPDATE_DELAYED` (already
  debounced by Blizzard — no extra throttle); bank + warband — `BANKFRAME_OPENED`,
  plus `BAG_UPDATE_DELAYED` while the bank is open (it covers the bank-tab bag IDs
  then); `BANKFRAME_CLOSED` just clears the open flag — it's **known to fire twice**,
  so the handler must stay idempotent. Equipped — `PLAYER_ENTERING_WORLD` +
  `PLAYER_EQUIPMENT_CHANGED` (fires per slot on any wear/remove/swap). `PLAYERBANKSLOTS_CHANGED`
  is **legacy** (pre-rework main-bank slots only) — don't use it. A full rebuild per
  scan is fine; the slot count is tiny. SavedVariables init happens at `ADDON_LOADED`
  (arg == addon name), the earliest the global is safe.
- **Equipped slot enumeration**: worn items are read by inventory slot ID, not from a
  container. The set is the standard gear slots
  `INVSLOT_FIRST_EQUIPPED`(1)..`INVSLOT_LAST_EQUIPPED`(19) **plus the
  profession/cooking/fishing tool & accessory slots 20..30** (the addon's primary use
  case is a crafter's equipped profession tool). Unlike purchased bank-tab bag IDs,
  inventory slot IDs are **fixed game constants**, so a static list is correct here —
  hardcoding the 20..30 range is the right call, the opposite of the bank-tab rule above;
  `GetInventoryItemID("player", slot)` returns nil for an empty or non-existent slot. Per
  slot: `GetInventoryItemID`/`GetInventoryItemLink` for id/link,
  `scanLoc:SetEquipmentSlot(slot)` + `GetCurrentItemLevel` for ilvl, and
  `C_TooltipInfo.GetInventoryItem("player", slot)` for the upgrade-track lines. Profession
  equipment reports an `itemEquipLoc` like `INVTYPE_PROFESSION_TOOL`/`_GEAR`, which
  `ns.IsGearEquipLoc` already accepts, so tools get ilvl rows for free. *(In-game check:
  confirm `PLAYER_EQUIPMENT_CHANGED` fires for the profession-tool slots 20..30; if it
  doesn't, fold `ScanEquipped` into the `BAG_UPDATE_DELAYED` branch as a fallback.)*
- **Bank tabs are only readable while the bank frame is open**, and an open frame
  doesn't guarantee both bank types are in context: the warband bank opens remotely via
  the Distance Inhibitor item, where the character bank is unreadable. **A scan must
  never wipe a snapshot it can't currently read** — the `ReadableBankTabs` guard
  (`C_Bank.CanUseBank` → `C_Bank.FetchPurchasedBankTabIDs(bankType)` non-empty → first
  tab `GetContainerNumSlots() > 0`) returns nil to mean "keep the existing snapshot".
  Away from the bank, tooltips serve the persisted snapshots.
- **Bag iteration**: bags are `Enum.BagIndex.Backpack` (0) …
  `Enum.BagIndex.ReagentBag` (5), contiguous. Bank tabs post-11.2 rework: character
  `Enum.BagIndex.CharacterBankTab_1..6` (6–11), warband `AccountBankTab_1..5` (12–16) —
  but **don't hardcode the ranges**;
  `C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Character|Account)` returns the
  purchased tabs' bag IDs. Legacy `Bank` (-1) / `Bankbag_*` / `Reagentbank` (-3)
  indices are **gone**.
- **Character DB key** is `UnitName("player") .. "-" .. GetNormalizedRealmName()`,
  resolved **lazily at first scan**: the normalized realm is reliable from
  `PLAYER_ENTERING_WORLD` on, **not** at `ADDON_LOADED`, and `BAG_UPDATE_DELAYED` can
  fire before PEW on login (scans bail on a nil key; the PEW rescan covers them). Alt
  display names strip the realm (character names can't contain `-`).
- **Midnight "Secret Values"** (`C_Secrets`, new in 12.0): restricts unit
  health/power/cooldowns/auras on tainted paths — **not** bag/container reads.
  `C_Container.GetContainerItemInfo` is `AllowedWhenUntainted`, so this addon is
  unaffected. No taint risk here (reads + `tooltip:AddLine` only).
- **Tooltip text**: everything is a single left-aligned `AddLine` per row; per-segment
  colors via inline `|cffRRGGBB…|r` escapes (atlas icon markup renders its own art and
  is unaffected by surrounding color codes). Counts go through `tostring`. Palette
  (`Tooltip.lua`): `ACCENT 99ccff` (section label), `HILITE ffd100` (hovered variant
  label), `WHITE ffffff` (counts), `DIM b3b3b3` (non-hovered rows), `SUFFIX_BAGS a6a6a6`
  (the `bags N` token), `SUFFIX 808080` (rest of the location suffix). The suffix
  separator is the UTF-8 middle dot, written `"\194\183"` so it survives encoding
  mishaps.
- **Live tooltip rebuild on modifier change**: `GameTooltip:RefreshData()` (from
  `GameTooltipDataMixin`, verified in live FrameXML — it is *not* on the wiki's
  GameTooltip page) re-runs the stored tooltip info through the full pipeline,
  re-firing `TooltipDataProcessor` post-calls with current key state; the rebuild
  **replaces** lines (no duplicate sections) and bails on `AddLine`-built tooltips
  (which never carry our section). The watcher guards cheapest-first —
  `MODIFIER_STATE_CHANGED` fires on every Shift/Alt/Ctrl press anywhere, combat
  included — and only rebuilds when the changed key maps to the configured modifier
  *and* some setting actually varies with it.
- **`Settings.RegisterAddOnSetting` (post-11.0 signature)** takes
  `(category, variable, variableKey, variableTbl, varType, name, default)` and
  reads/writes `variableTbl[variableKey]` directly — so `db.settings` **must never be
  replaced** after registration (a swap silently decouples the panel from the
  SavedVariable), and defaults must be filled *before* registering.
  `type(DEFAULTS[key])` doubles as the varType (Lua type names == `Settings.VarType`
  strings).
- **Dropdown labels that embed the modifier name** ("Only while Shift is held")
  self-heal when a dropdown *opens* (options getters re-run), but the **closed**
  control's text stays stale until then after changing the modifier key — known,
  accepted. Checkbox **names** have no self-heal path at all (registered once, re-read
  only on panel redraw), which is why the list-all checkbox says a generic "key"
  instead of embedding the modifier's name.
- **Parented / proxy settings** (the list-all checkbox, the Top-N slider):
  `initializer:SetParentInitializer(parent, predicate)` re-evaluates **enabled state**
  (predicate true ⇒ enabled) when the parent setting changes, but does **not** repaint
  a child's displayed value. The list-all checkbox is a
  `Settings.RegisterProxySetting` whose getter folds in `altsDetail == "all"` (so it
  reads checked while *All* is selected, with the user's stored choice surviving
  underneath), and a `Settings.SetOnValueChangedCallback` on `altsDetail` calls
  `expandSetting:NotifyUpdate()` to repaint the check live.
- **Characters-panel atlases**: eye `socialqueuing-icon-eye`, delete `common-icon-redx`
  — both verified in current Blizzard UI source (QuickJoin / CharacterCreate). Hidden
  state renders as desaturated + 0.4 alpha on the eye **and** grays the row's name
  (`GameFontDisable`; the green "(current)" tag dims to a muted green). The eye's
  OnClick repaints its own GameTooltip in place (shared show-tip function with
  OnEnter — a click implies the cursor is on the button); without that the tooltip
  keeps the pre-toggle text until re-hover.

## Deferred / roadmap

These plug in behind the existing seams without changing the tooltip layer:

- Settings polish: formatting / accent-color options; per-container alt detail (at most
  a config-off extra); live re-label of the closed "[modifier] held" dropdowns after a
  modifier change.
- Localization of the display strings (currently English-only; the upgrade-track
  parsing side is already locale-safe).
