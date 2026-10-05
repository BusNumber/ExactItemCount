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

Code conventions: the addon's Lua files share the private addon table via the
`local addonName, ns = ...` vararg. Keep the data/presentation split — new data sources
go in `Core.lua` behind the `ns.Get*` seams; `Tooltip.lua` reads only through those
seams. Display text never goes inline: every string the addon shows is a key in
`Locales/enUS.lua`, read as `L.KEY` (DESIGN.md's Localization section has the rules).

## Static checks & automated tests

WoW globals (`C_Container`, `Enum`, `TooltipDataProcessor`, …) don't exist outside the
game, but the data and display logic is still testable headless:

- `luac -p <file>` — syntax-only compile pass (or `luajit -bl <file> /dev/null`;
  LuaJIT speaks Lua 5.1, the same dialect as WoW, while modern `luac` is 5.4).
- `luacheck .` — uses the repo's `.luacheckrc` (which knows the WoW globals).
- `luajit tests/run_tests.lua` — the headless test suite (below).

CI (`.github/workflows/ci.yml`) runs all three on every push and pull request.

### The test suite (`tests/`)

The suite loads every file the TOC lists, in TOC order — the string table, `Core.lua`,
`Tooltip.lua` **and** `Settings.lua` — against the
WoW API stubs in `tests/wow_stubs.lua` (the Settings panel builds against a faked
`Settings` API; its rendered UI is never asserted on) and drives them through the
addon's own event handlers: scans run off fixture bags, banks, and worn gear; tooltips
render through the real `TooltipDataProcessor` post-call into a fake tooltip whose
recorded lines the tests assert on. Each test boots a fresh addon world. What it locks
are the DESIGN.md invariants:

- every lead line's count equals the sum of the breakdown rows under it, under
  **every** filter combination (a section can carry several lead lines — the hovered
  item's own total, an `On auction` line, a `Crafted items` product line — each its own
  scope), and every location suffix sums exactly to its line's count;
- quality-sibling membership is all-or-nothing — a sibling counts toward the total only
  when its tier resolves into a row;
- a recipe's product sub-section renders only for recipe-class items, is gated by its
  tri-state, and never renders twice on one frame;
- auction listings never leak into any owned number — the auction scope is isolated,
  its sub-section renders only when non-zero, sold listings are excluded, and alts'
  listings join only behind the opt-in checkbox;
- mail joins the owned numbers (the inbox snapshot and in-transit send credits sum
  under one `mail` token) and never the auction scope; send credits land only under a
  recipient that normalizes to a known character key, commit on success, discard on
  failure/cancel/close, are superseded by that character's next full inbox scan, and
  expire after 31 days; a stranger's COD attachments are excluded;
- AH purchase and cancel credits land in the own character's `mailPending` only when
  a finalization event resolves a stashed intent — commodities commit the requested
  quantity on purchase-succeeded and the won-toast refines it downward (never up)
  under every signal order, with seller-side, overfill, tier-name-collision and
  back-to-back-purchase guards; buyouts qty 1 through the id-less-stash /
  commit-time-retry / toast-link-fallback chain; cancels read from the live owned
  list with sold listings skipped and commit keyed by the event's auctionID or —
  the junk commodity payload — through the owned-list-absence sweep, which never
  acts on partial result sets and never credits a still-present (or Sold) listing;
  unresolved intents die on failure, dead quotes, and AH close; the demoted slot
  still commits after Blizzard's dialog-hide cancel; from there the credits follow
  the send-credit lifecycle and never enter the auction scope;
- a bank (or owned-auctions result, or a truncated >100-message inbox) that can't
  currently be read in full never wipes its stored snapshot;
- the settings sanitizer round-trips: persisted `false` survives, junk values reset,
  and a DB-version rebuild carries `settings` over;
- the `/eic find` chat command: bare `/eic` still opens the panel; a linked item is an
  exact ask (answered even at 0) while text is a substring search over owned + listed
  items only; a quality good's name-group prints once with namesakes and cold siblings
  on their own disjoint lines; the search ignores the display tri-states but honors
  hidden characters; the `on auction` tail sums separately and appears only when
  non-zero; the length floor, result cap, sort order, and pipe-stripping of the echoed
  query all hold;
- the string table: every key the code reads is defined in `Locales/enUS.lua` and every
  key defined there is read; with a stand-in translation loaded, every tooltip line,
  chat line and options-panel string comes out translated (nothing hard-coded is left)
  and the sum invariants still hold; the language shown follows an explicit choice,
  then the client's language, then English, and `/eic locale` saves that choice for
  the next load without switching anything live; a translation file may only register
  the client language its file name says and assign existing keys, placeholders intact.

The rule of thumb: **when you add or change data-layer or display behavior, add a
test; when a claim needs the real client, add a checklist item below instead.** New
display text means a new key in `Locales/enUS.lua` — the suite fails until some test
actually displays it. The
stubs can't model real panel rendering, atlas art, `RefreshData`'s actual pipeline,
item-cache timing, or taint — that's what the in-game checklist is for.

## Adding a translation

Only English ships today, but every displayed string already comes from one table, so a
translation needs no code changes:

1. Copy `Locales/enUS.lua` to `Locales/xxXX.lua`, where `xxXX` is the client's locale
   code (`deDE`, `frFR`, `ruRU`, `zhCN`, …). In the copy, change the one line that
   registers the table so it names your language:

   ```lua
   local L = ns.NewLocale("xxXX")
   ```

   Two client codes that share a translation can be registered together:
   `ns.NewLocale("esES", "esMX")`.

2. Translate the values; never rename a key. Lines you leave out (or delete) simply
   stay English, so a partial translation is fine.
3. Keep every `%s` / `%d` placeholder. To reorder them, use the positional form
   (`%2$d … %1$s`; the numbers are the English order). Where a count needs proper
   plural forms, the game's own escape works inside a value: `%d |4match:matches;`.
4. Save as UTF-8 without a BOM, one string per line.
5. Add `Locales\xxXX.lua` to `ExactItemCount.toc`, on its own line after
   `Locales\enUS.lua` (a comment marks the spot) and before `Core.lua`. The AddOns-list
   text can be translated there too, with `## Title-xxXX:` and `## Notes-xxXX:` lines.
6. Run `luajit tests/run_tests.lua` — it picks the new file up from the TOC and checks
   that it only uses existing keys and keeps their placeholders.
7. Try it in game: restart the client (a new file is not picked up by `/reload`). On a
   client in that language it is shown automatically; on any other, `/eic locale xxXX`
   and `/reload`. `/eic locale enUS` forces English on a translated client,
   `/eic locale default` returns to the normal order (the client's language, falling
   back to English), and bare `/eic locale` lists what is available.

Not translated, on purpose: the addon's name, the `/eic` commands with their
sub-command words (`find`, `locale`) and the locale command's own answers, and the
upgrade-track badge letter, which is taken from the game's own localized text.

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

### Recipes

- [ ] Hover a **recipe in your bags** whose product you own: the recipe's own count
      first, then `Crafted items: N` with the product's normal breakdown rows; the
      product rows sum exactly to the `Crafted items` count; the section appears
      **exactly once** (the embedded product tooltip must not add a duplicate).
- [ ] Hover the **crafted product directly**: one normal section, no `Crafted items`
      line, hovered highlight intact.
- [ ] Hover a recipe in the **profession window's recipe list**: no duplicated or
      misattributed section (the tooltip there may be set to the product itself — a
      single normal product section is then the correct render).
- [ ] **Chat-linked recipe** (click a recipe link in chat): the popup's link is
      expected to be the recipe itself, so a recipe-only section (no `Crafted items`)
      is correct there — not a bug.
- [ ] Set *Crafted item on recipes* to *Only while held*: over an open recipe tooltip,
      hold/release the modifier — the `Crafted items` block appears/vanishes in place,
      never duplicated.
- [ ] With **Hide when total is 0** on, hover an unowned recipe whose product you own:
      only the `Crafted items` block shows (no `Total items owned: 0` line).
- [ ] One-time API check: `/dump C_Item.GetItemInfoInstant(<recipe itemID>)` — confirm
      classID (Recipe = 9) is the 6th return.

### Auction listings

- [ ] One-time API check, with at least one live listing up: `/dump
      C_AuctionHouse.GetOwnedAuctions()` — confirm the result shape the scan relies on
      (`itemKey.itemID` / `itemKey.itemLevel`, `quantity`, `itemLink`, `status`), the
      `Enum.AuctionStatus` values (which value is Active; that a sold-but-uncollected
      listing is distinguishable), and that `itemLink` is present/absent as expected
      for an **item** listing vs a **commodity** listing. Also `/dump
      C_AuctionHouse.HasFullOwnedAuctionResults()` exists and behaves.
- [ ] Confirm the event flow: `AUCTION_HOUSE_SHOW` → `QueryOwnedAuctions({})` is
      accepted (watch for throttling — if the query is ever swallowed, does
      `AUCTION_HOUSE_THROTTLED_SYSTEM_READY` warrant a retry?), `OWNED_AUCTIONS_UPDATED`
      fires with the results, and whether posting/cancelling a listing while the AH is
      open fires it again on its own.
- [ ] List an item, close the AH, hover a copy anywhere: `On auction: N` appears below
      the main section — no location suffix while the section covers only you — and
      the grand total is **unchanged** by listing.
- [ ] List crafted gear at two ranks: per-ilvl rows under `On auction`, highest first;
      the row matching the hovered variant is gold like the main section's (and shows
      the hovered item's upgrade-track badge if it has one), other rows dim. Hover a
      rank you have **no** listing of: no synthetic `0` row appears in the block and
      nothing in it is gold.
- [ ] Sell or cancel everything, revisit the AH: the count drops and the line
      disappears (zero listings render nothing). Confirm a **sold-but-uncollected**
      listing is already excluded, and note where an **expired** listing goes.
- [ ] *Include alts' auctions* off (the default): another character's listings never
      appear. On: they appear by name inside the sub-section — and the location suffix
      appears with them, own listings as `yours N` — still gated by *Other characters*
      and the Characters-page eye; the checked state survives `/reload`.
- [ ] The checkbox grays out while *On auction* is set to *Never* and re-enables when
      it leaves *Never*.
- [ ] Set *On auction* to *Only while held*: over an open tooltip, hold/release the
      modifier — the block appears/vanishes in place, never duplicated.
- [ ] Hover a commodity you have listed (no per-listing item link expected): its own
      tier still counts; hovering its **other** quality tier may omit the listed tier
      from the block until the cache warms — accepted, but confirm it self-heals.

### Mail

- [ ] One-time API checks at a mailbox: `/dump GetInboxNumItems()` — confirm the first
      return is the downloaded/indexable count and the second the server total (with a
      >100-mail box, confirm `totalItems > numItems` and that the client keeps
      refetching until they converge). `/dump GetInboxItem(1, 1)` — itemID and count
      correct, quality `-1` as documented (the addon must never read it). `/dump
      ATTACHMENTS_MAX_RECEIVE, ATTACHMENTS_MAX_SEND` — 16 and 12.
- [ ] Event flow: opening a mailbox fires `PLAYER_INTERACTION_MANAGER_FRAME_SHOW` with
      `Enum.PlayerInteractionType.MailInfo` (17) and closing fires the matching HIDE
      (note whether `MAIL_SHOW` also fires — either way the flag must not double-query);
      `MAIL_INBOX_UPDATE` fires once data arrives, per mail consumed during **Open
      All** (counts shrink live), and note whether it fires at all for an *empty*
      inbox (an empty snapshot may then wait for the next mail change — accepted).
- [ ] Throttle: `C_Mail.CanCheckInbox()` exists; a quick close/reopen still ends with
      a correct scan (Blizzard's own queued retry drives the update).
- [ ] Hover an item with a copy sitting in your inbox: the grand total includes it and
      a `mail N` token appears between `equipped` and the alts. Collect the mail —
      the token drops as the bags count rises, while the mailbox is still open.
- [ ] Send items to one of your **own characters**: the moment the send succeeds, the
      hovered count shows them under the recipient's name. `hooksecurefunc("SendMail")`
      fired with the recipient; note whether `GetSendMailItem` was still readable
      inside the hook (the addon works either way — the `MAIL_SEND_INFO_UPDATE`
      snapshot is the fallback; confirm that event fires on attach/detach).
- [ ] Log the recipient, open their mailbox: the in-transit credit is replaced by the
      real inbox count — **no double count** at any point (before collecting, the item
      shows as the recipient's `mail`; after, as bags).
- [ ] Cancel a send confirmation dialog if one appears (e.g. a refundable item):
      `MAIL_UNLOCK_SEND_ITEMS` fires, nothing is credited, and re-sending afterwards
      credits correctly.
- [ ] Send to a name that is **not** one of your characters: nothing is credited
      anywhere. Send to an own character on a **connected realm** (`Name-Realm` form):
      the credit lands under that character.
- [ ] COD from a stranger: the package's items are **not** counted while unpaid; pay
      (or return) and revisit the mailbox — counts settle correctly. COD between your
      own characters counts throughout.
- [ ] Mail tri-state: *Never* drops your own mail from total and suffix while alts'
      mail stays inside their per-character numbers; *Only while held* updates an open
      tooltip in place, never duplicating the section.
- [ ] Characters page: each row's age line now includes `mail`.

### Auction purchases & cancels

*Verified in-game 2026-08-19 on 12.1.0 (two rounds): purchases and cancelled listings
deliver by **mail** (never straight to bags); purchase credits work for both kinds,
quality tiers included; item-listing cancel credits work keyed; the table-form
`hooksecurefunc(C_AuctionHouse, …)` hooks fire; `AUCTION_HOUSE_PURCHASE_COMPLETED`
fires with auctionID **0** for commodity purchases;
`AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION` carries the actual purchased
quantity; and `AUCTION_CANCELED` fires with a junk payload (**1**) for
commodity-listing cancels — those now commit via the owned-list-absence sweep.
Still to verify:*

- [ ] **Commodity-cancel sweep re-test**: cancel a stackable listing — the credit
      appears under `mail` immediately, before any mailbox visit. Do it once from
      the **All Auctions** list and once from the **commodity drill-down** row (the
      two views source their auctionID differently; if the drill-down case fails,
      the hook's owned-list lookup missed — report it, the whole-list baseline diff
      is the documented next step).

- [ ] Buy a stack of materials with `/etrace` running **unfiltered** (an
      "AUCTION_HOUSE" filter hides the `COMMODITY_*` events): note whether
      `COMMODITY_PURCHASED` fires at all (the addon treats it as dead — its commit
      path is legacy), and the order of `COMMODITY_PURCHASE_SUCCEEDED` vs the
      won-toast. With a stack large enough to fill from several sellers, note whether
      the toast fires once with the total or once per fill (per-fill would make the
      downward refiner undercount — report it).
- [ ] Hover the bought item right after purchase: the count shows under `mail`
      **before any mailbox visit** and the grand total includes it; a partially
      filled buy settles on the actual amount once the toast lands. Open the mailbox
      after delivery and collect — the credit is superseded, no double count at any
      point.
- [ ] **Item buyout** with `/etrace` unfiltered: the credit appears as `mail` with
      the listing's ilvl, quantity 1. Note whether it committed straight from
      `AUCTION_HOUSE_PURCHASE_COMPLETED` (meaning `GetAuctionInfoByID` resolved in
      the `PlaceBid` hook or at commit time) or needed the
      `AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION` fallback — and record that event's
      payload: is the third arg the auctionID, and does the text embed the item
      link? Place a plain **bid** (not buyout): no credit ever appears.
- [ ] **Post-/reload dispatch order**: with the AH open, `/reload`, then buy a
      commodity — exactly ONE credit must appear (Blizzard's BuyDialog cancels on
      hide even on success; after a reload its frames see events first, and the
      demoted-slot path must still commit through SUCCEEDED).
- [ ] Walk-away paths: start a purchase and close the dialog without confirming, let a
      quote die (`COMMODITY_PRICE_UNAVAILABLE`), and close the AH mid-purchase —
      nothing is ever credited for any of them.
- [ ] Cancel a **partially sold** commodity listing: the credited quantity equals what
      actually returns by mail (note if a large stack returns as several mails).

### Chat search (`/eic find`)

- [ ] `/eic find <part of a name>` for an item you own at several places: the header,
      one line per match, counts and location suffixes correct; the printed item link
      renders **clickable and quality-colored** in the chat frame.
- [ ] **Click a printed result link**: the chat-link popup (ItemRefTooltip) opens and
      carries the addon's full tooltip section — breakdown rows included. This is the
      payoff of printing links; confirm it works for a reagent (tier rows) and a
      crafted piece (ilvl rows).
- [ ] Type `/eic find ` in the chat box, then **shift-click an item** in your bags:
      the link is inserted into the edit box; sending it answers with that exact
      item's line (a `: 0` answer for something you don't own is correct, not a bug).
- [ ] With 10+ alts owning the searched item, the every-alt-named suffix line stays
      readable in the chat frame (it wraps, but must stay legible).
- [ ] `/eic` alone still opens the options panel; `/eic wat` prints the usage line.
- [ ] Set Bank to *Never*, search an item that's mostly in the bank: find still counts
      it (deliberately different from the tooltip under the same setting) while the
      tooltip keeps excluding it.
- [ ] Search a stackable material you have **listed on the AH but own none of**: it
      appears as `: 0 — on auction: N`. (Commodity listings store no link, so a plain
      white name instead of a clickable link is expected there.)
- [ ] Hide a character on the Characters page: its counts drop out of find results
      immediately.

### String table

- [ ] After a full client restart (a newly added file is not picked up by `/reload`):
      hover an item, open the options panel and its Characters page, and run
      `/eic find <something>`. All text reads as normal English. A Lua error about
      indexing `L` or calling `NewLocale` (a nil value) means `Locale.lua` did not load
      first — check the TOC lines; ALL_CAPS key names on screen (`LEAD_TOTAL: 5`) mean
      `Locales\enUS.lua` did not load, or the code reads a key it doesn't define.
- [ ] `/eic locale` lists `enUS | default`; `/eic locale enUS`, `/eic locale default`
      and a made-up code each answer sensibly, and nothing changes on screen (only
      English is registered). With a translation file added: `/eic locale <code>` +
      `/reload` shows it everywhere, including the options panel, the Characters page
      and the delete confirmation; `/eic locale default` + `/reload` returns to the
      client's language.
- [ ] **Saved data is untouched** by a language switch: counts, characters and
      settings read the same before and after.

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
