local addonName, ns = ...

-- Persistent count store (SavedVariables). Every source snapshot shares one shape:
--   items[itemID] = {
--     total  = <number>,                                   -- sum across every item-level group
--     link   = <representative hyperlink>,                 -- any stack of this item (for name/quality lookups)
--     groups = { [ilvl] = { count = <number>, link = <representative hyperlink>,
--                           track = <nil | { name, step, max }> },                -- upgrade track, gear only
--                ... },
--   }
-- Grouping by item level is what separates crafting ranks: for crafted gear the
-- R1-R5 qualities share one itemID and differ only by ilvl (via bonus IDs).
--
--   ExactItemCountDB = {
--     version = DB_VERSION,
--     addonVersion = <TOC version string>,                         -- write-only diagnostic, never read
--     warband = { scannedAt = <epoch>, items = <items> },          -- account bank: account-level
--     chars = {
--       ["Name-NormalizedRealm"] = {
--         bags     = { scannedAt = <epoch>, items = <items> },
--         bank     = { scannedAt = <epoch>, items = <items> },
--         equipped = { scannedAt = <epoch>, items = <items> },     -- currently-worn gear/tools
--         auctions = { scannedAt = <epoch>, items = <items> },     -- active AH listings
--         mail     = { scannedAt = <epoch>, items = <items> },     -- inbox snapshot (taken at the mailbox)
--         mailPending = { { sentAt = <epoch>, items = <items> }, ... },
--                               -- optimistic in-transit credits: appended by the SENDING
--                               -- character's session on a successful send to this
--                               -- character, cleared whole by this character's own next
--                               -- full inbox scan, pruned after 31 days (mail auto-
--                               -- returns at 30, so the game guarantees it has moved)
--       },
--     },
--     settings = { ... },   -- account-wide display settings; owned by Settings.lua
--                           -- (schema + defaults there). Additive: DB_VERSION stays 1,
--                           -- missing keys are default-filled at load.
--   }
--
-- The current character's bag scan writes straight into its own chars entry -- the DB is
-- the single source of truth, and an alt session reads this character the same way this
-- session reads alts. `scannedAt` surfaces as the scan-age column of the settings layer's
-- Characters panel.
local DB_VERSION = 1
local db       -- ExactItemCountDB, set at ADDON_LOADED
local charKey  -- "Name-NormalizedRealm"; resolved lazily (realm is unreliable before PLAYER_ENTERING_WORLD)
local bankOpen = false
local ahOpen = false
local mailOpen = false
local sendSnapshot -- outgoing attachment slots as an items table, rebuilt on MAIL_SEND_INFO_UPDATE
local pendingSend  -- { recipientKey, items } stashed by the SendMail hook until the send resolves
-- AH purchase/cancel intents (see the hook block at the end of the file). None persist:
-- an intent the finalization event never resolves dies with the AH visit.
local commodityIntent    -- { itemID, quantity, wonQty? } stashed by the ConfirmCommoditiesPurchase
                         -- hook; wonQty is the actual fill when the won-toast landed pre-commit
local commodityCancelled -- the demoted intent (Blizzard's BuyDialog cancels on hide, success included)
local commodityCommitted -- { itemID, quantity, link, batch } -- the last committed commodity
                         -- credit, kept so a late actual-fill report can shrink it (never grow)
local pendingBuyouts = {} -- [auctionID] = { id?, link?, ilvl? } stashed by the PlaceBid hook
                          -- (fields optional: an empty entry means "bid in flight, item unknown")
local pendingCancels = {} -- [auctionID] = { id, link, ilvl, qty } stashed by the CancelAuction hook

-- Bag range for the player's inventory: backpack (0), the four carried bags (1-4)
-- and the reagent bag (5). These Enum values are contiguous, so a numeric loop works.
local BAG_IDS = {}
for bagID = Enum.BagIndex.Backpack, Enum.BagIndex.ReagentBag do
	BAG_IDS[#BAG_IDS + 1] = bagID
end

-- Equipped inventory slots: the standard gear slots (INVSLOT_FIRST_EQUIPPED..LAST, 1-19)
-- plus the profession/cooking/fishing tool & accessory slots (20-30). Unlike purchased
-- bank-tab bag IDs (which must be fetched live -- see ReadableBankTabs), inventory slot
-- IDs are fixed game constants, so a static list is correct; GetInventoryItemID simply
-- returns nil for an empty or non-existent slot.
local EQUIPPED_SLOTS = {}
for slot = INVSLOT_FIRST_EQUIPPED, INVSLOT_LAST_EQUIPPED do
	EQUIPPED_SLOTS[#EQUIPPED_SLOTS + 1] = slot
end
for slot = 20, 30 do
	EQUIPPED_SLOTS[#EQUIPPED_SLOTS + 1] = slot
end

-- Hot-path locals.
local GetContainerNumSlots    = C_Container.GetContainerNumSlots
local GetContainerItemInfo    = C_Container.GetContainerItemInfo
local GetCurrentItemLevel     = C_Item.GetCurrentItemLevel
local GetDetailedItemLevelInfo = C_Item.GetDetailedItemLevelInfo
local GetItemInfoInstant      = C_Item.GetItemInfoInstant
local GetItemNameByID         = C_Item.GetItemNameByID
local GetItemInfo             = C_Item.GetItemInfo -- (name, link, ...); nil until the item's data loads
local GetBagItemTooltip       = C_TooltipInfo and C_TooltipInfo.GetBagItem
local GetInventoryItemTooltip = C_TooltipInfo and C_TooltipInfo.GetInventoryItem
local GetInventoryItemID      = GetInventoryItemID    -- global; (unit, slot) -> itemID|nil
local GetInventoryItemLink    = GetInventoryItemLink  -- global; (unit, slot) -> hyperlink|nil
local QueryOwnedAuctions      = C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions
local GetOwnedAuctions        = C_AuctionHouse and C_AuctionHouse.GetOwnedAuctions
local HasFullOwnedAuctionResults = C_AuctionHouse and C_AuctionHouse.HasFullOwnedAuctionResults
local GetAuctionInfoByID      = C_AuctionHouse and C_AuctionHouse.GetAuctionInfoByID
local CheckInbox              = CheckInbox            -- globals; the mail API was never C_-namespaced
local GetInboxNumItems        = GetInboxNumItems
local GetInboxHeaderInfo      = GetInboxHeaderInfo
local GetInboxItem            = GetInboxItem
local GetInboxItemLink        = GetInboxItemLink
local GetSendMailItem         = GetSendMailItem
local GetSendMailItemLink     = GetSendMailItemLink
local CanCheckInbox           = C_Mail and C_Mail.CanCheckInbox
local GetInboxItemTooltip     = C_TooltipInfo and C_TooltipInfo.GetInboxItem
local GetSendMailItemTooltip  = C_TooltipInfo and C_TooltipInfo.GetSendMailItem

-- Non-active listings (sold, awaiting collection) are excluded from the auction scan:
-- the item is gone, its proceeds arrive as gold via mail. An absent status field must
-- never drop a listing, so the comparison is against the Active value, not "truthy".
local AUCTION_STATUS_ACTIVE = Enum.AuctionStatus and Enum.AuctionStatus.Active or 0

-- The "you won an item auction" value of AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION's
-- first payload arg (buyer's chat toast). Numeric fallback mirrors AUCTION_STATUS_ACTIVE.
local AUCTION_NOTIFY_WON = Enum.AuctionHouseNotification and Enum.AuctionHouseNotification.AuctionWon or 2

-- Mailbox open/close is driven by the interaction manager (Blizzard's own MailFrame
-- registers neither MAIL_SHOW nor the dead-since-10.0 MAIL_CLOSED); both legacy events
-- stay registered as defensive belts. The numeric fallback mirrors AUCTION_STATUS_ACTIVE.
local INTERACTION_MAILBOX = Enum.PlayerInteractionType and Enum.PlayerInteractionType.MailInfo or 17

-- Attachment-slot bounds. These are Lua globals defined in Blizzard_MailFrame (not C
-- constants), so the fallbacks are load-order insurance, not paranoia.
local MAX_MAIL_RECEIVE = ATTACHMENTS_MAX_RECEIVE or 16
local MAX_MAIL_SEND    = ATTACHMENTS_MAX_SEND or 12

-- Optimistic send credits older than this describe mail the game guarantees has moved
-- (auto-return happens at 30 days); a day of slack avoids clock-skew edge cases.
local MAIL_PENDING_SECONDS = 31 * 24 * 60 * 60

-- Equip locations that do NOT count as gear. Non-equippable items return
-- "INVTYPE_NON_EQUIP_IGNORE" from GetItemInfoInstant -- the token was renamed from
-- "INVTYPE_NON_EQUIP" in 10.2.6; the old name is kept defensively. Shared with the
-- tooltip layer so both route by the same definition of "gear".
local NON_GEAR_EQUIP_LOCS = {
	[""] = true,
	INVTYPE_BAG = true,
	INVTYPE_NON_EQUIP = true,
	INVTYPE_NON_EQUIP_IGNORE = true,
}

function ns.IsGearEquipLoc(equipLoc)
	return equipLoc ~= nil and not NON_GEAR_EQUIP_LOCS[equipLoc]
end

-- Upgrade-track tooltip line ("Upgrade Level: Hero 1/6"). There is no structured API for
-- an item's upgrade track, so the line is matched against a pattern built from Blizzard's
-- own localized format string ("Upgrade Level: %s %d/%d") -- locale-safe by construction.
-- Token order is recorded while building because some locales reorder format arguments
-- (positional %1$s forms), so each capture is mapped back to its meaning.
local trackPattern, trackTokens
do
	local fmt = ITEM_UPGRADE_TOOLTIP_FORMAT_STRING
	if fmt then
		trackTokens = {}
		local p = fmt:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
		p = p:gsub("%%%%%d*%%?%$?([sd])", function(token)
			trackTokens[#trackTokens + 1] = token
			return token == "s" and "(.-)" or "(%d+)"
		end)
		trackPattern = "^" .. p .. "$"
	end
end

-- Scan a TooltipDataLine[] for the upgrade-track line; returns (name, step, max) or nil.
-- Used at scan time for owned stacks and by the tooltip layer for the hovered item.
function ns.ParseUpgradeTrack(lines)
	if not (trackPattern and lines) then return nil end
	for _, line in ipairs(lines) do
		local text = line.leftText
		if text then
			local caps = { text:match(trackPattern) }
			if caps[1] then
				local name, step, max
				for i, token in ipairs(trackTokens) do
					if token == "s" then
						name = caps[i]
					elseif not step then
						step = tonumber(caps[i])
					else
						max = tonumber(caps[i])
					end
				end
				if name and name ~= "" and step and max then
					return name, step, max
				end
			end
		end
	end
	return nil
end

-- Reused across slots so the scan allocates no per-slot ItemLocation tables.
local scanLoc = ItemLocation:CreateEmpty()

-- Records one stack into the items snapshot: `qty` of item `id` at effective item level
-- `ilvl`, with representative hyperlink `link`. Creates the per-item entry and per-ilvl
-- group on first sight. `fetchTip` is an optional thunk returning the stack's
-- TooltipData; it is called at most once per *new gear group* (first stack wins) to
-- parse the upgrade track, which bounds the tooltip-fetch cost to the handful of gear
-- stacks scanned. Shared by every scan path so the grouping/track logic lives in one
-- place.
local function RecordStack(items, id, qty, link, ilvl, fetchTip)
	local entry = items[id]
	if not entry then
		entry = { total = 0, groups = {} }
		items[id] = entry
	end
	entry.total = entry.total + qty
	entry.link = entry.link or link

	local group = entry.groups[ilvl]
	if not group then
		group = { count = 0, link = link }
		entry.groups[ilvl] = group

		-- Upgrade track, gear only, representative like `link` (first stack seen wins;
		-- a same-ilvl cross-track collision is rare and tolerated).
		local _, _, _, equipLoc = GetItemInfoInstant(id)
		if fetchTip and ns.IsGearEquipLoc(equipLoc) then
			local tip = fetchTip()
			local name, step, max = ns.ParseUpgradeTrack(tip and tip.lines)
			if name then
				group.track = { name = name, step = step, max = max }
			end
		end
	end
	group.count = group.count + qty
end

-- Full scan of a set of containers into a fresh items table. Cheap (a few hundred slots
-- at most) and only runs on login / after a batch of bag changes / at the bank, so a
-- wholesale rebuild is plenty fast. Returning a new table lets callers swap snapshots
-- atomically -- nothing outside the data layer holds a reference to a source store.
local function ScanContainers(bagIDs)
	local items = {}
	for _, bagID in ipairs(bagIDs) do
		for slot = 1, GetContainerNumSlots(bagID) do
			local info = GetContainerItemInfo(bagID, slot)
			if info and info.itemID then
				-- Effective item level for this exact stack. ItemLocation is the
				-- reliable source for owned items; fall back to parsing the link.
				scanLoc:SetBagAndSlot(bagID, slot)
				local ilvl = GetCurrentItemLevel(scanLoc)
				if not ilvl and info.hyperlink then
					ilvl = GetDetailedItemLevelInfo(info.hyperlink)
				end
				RecordStack(items, info.itemID, info.stackCount or 1, info.hyperlink, ilvl or 0,
					GetBagItemTooltip and function() return GetBagItemTooltip(bagID, slot) end)
			end
		end
	end
	return items
end

-- The current character's "Name-NormalizedRealm" key, resolved lazily: the normalized
-- realm is only reliable from PLAYER_ENTERING_WORLD on -- BAG_UPDATE_DELAYED can fire
-- before that on login, so callers bail on nil and the PEW rescan covers them.
local function ResolveCharKey()
	if not charKey then
		local name = UnitName("player")
		local realm = GetNormalizedRealmName()
		if name and realm then
			charKey = name .. "-" .. realm
		end
	end
	return charKey
end

-- Settings-layer seam: marks the current character in the Characters panel and guards it
-- against deletion. nil before the realm is known.
function ns.GetCharKey()
	return ResolveCharKey()
end

-- The current character's DB slot, created on first use.
local function EnsureChar()
	if not db then return nil end
	local key = ResolveCharKey()
	if not key then return nil end
	local char = db.chars[key]
	if not char then
		char = {}
		db.chars[key] = char
	end
	return char
end

-- Resolves a player-typed or API-supplied character name ("liara", "Liara-RealmA",
-- "Liara-Realm A") to the exact db.chars key it denotes, or nil for a stranger. No realm
-- means the own realm; a typed realm is normalized the way GetNormalizedRealmName is
-- (spaces/hyphens/apostrophes stripped); the match is case-insensitive. Character names
-- cannot contain "-", so the split at the first hyphen is exact. Only ever RETURNS
-- existing keys -- the send-crediting path relies on that (it never creates entries).
-- The pairs() sweep is one pass over a tiny roster, once per send / COD header.
local function KnownCharKey(who)
	if not (db and type(who) == "string" and who ~= "") then return nil end
	local name, realm = who:match("^([^-]+)%-(.+)$")
	if name then
		realm = realm:gsub("[%s%-']", "")
	else
		name = who
		realm = GetNormalizedRealmName()
		if not realm then return nil end
	end
	local target = (name .. "-" .. realm):lower()
	for key in pairs(db.chars) do
		if key:lower() == target then return key end
	end
	return nil
end

local function ScanBags()
	local char = EnsureChar()
	if not char then return end
	char.bags = { scannedAt = time(), items = ScanContainers(BAG_IDS) }
end

-- Bank tabs (post-11.2 rework: the character bank is tab-based like the warband bank)
-- are only readable while the bank frame is open, and an open frame doesn't guarantee
-- both bank types are in context -- a remote warband-only session (Distance Inhibitor)
-- must not wipe the character-bank snapshot it cannot read. Returns the purchased tabs'
-- bag IDs only when their contents are actually readable right now; nil means "keep
-- whatever snapshot you have".
local function ReadableBankTabs(bankType)
	if C_Bank.CanUseBank and not C_Bank.CanUseBank(bankType) then return nil end
	local tabs = C_Bank.FetchPurchasedBankTabIDs(bankType)
	if not tabs or #tabs == 0 then return nil end
	-- A purchased tab is never 0-slot; reading 0 means the tab is out of context.
	if GetContainerNumSlots(tabs[1]) == 0 then return nil end
	return tabs
end

local function ScanBank()
	local char = EnsureChar()
	if not char then return end
	local tabs = ReadableBankTabs(Enum.BankType.Character)
	if not tabs then return end
	char.bank = { scannedAt = time(), items = ScanContainers(tabs) }
end

local function ScanWarband()
	if not db then return end
	local tabs = ReadableBankTabs(Enum.BankType.Account)
	if not tabs then return end
	db.warband = { scannedAt = time(), items = ScanContainers(tabs) }
end

-- Currently-worn items (gear plus profession/cooking/fishing tools & accessories) into a
-- fresh snapshot. Each slot holds a single item, so qty is always 1. Reuses scanLoc via
-- SetEquipmentSlot for the item-level read; the link/id come from the global inventory
-- accessors. Always readable for the current character, so (unlike the bank scans) there
-- is no "keep the old snapshot" guard.
local function ScanEquipped()
	local char = EnsureChar()
	if not char then return end
	local items = {}
	for _, slot in ipairs(EQUIPPED_SLOTS) do
		local id = GetInventoryItemID("player", slot)
		if id then
			local link = GetInventoryItemLink("player", slot)
			scanLoc:SetEquipmentSlot(slot)
			local ilvl = GetCurrentItemLevel(scanLoc)
			if not ilvl and link then
				ilvl = GetDetailedItemLevelInfo(link)
			end
			RecordStack(items, id, 1, link, ilvl or 0,
				GetInventoryItemTooltip and function() return GetInventoryItemTooltip("player", slot) end)
		end
	end
	char.equipped = { scannedAt = time(), items = items }
end

-- The character's active auction listings. Readable only while the AH is open, so the
-- scan follows the bank's never-wipe philosophy: the snapshot swaps only when a real,
-- complete owned-auctions result set is in hand -- a nil list (nothing fetched yet) or a
-- partial page keeps the stored snapshot, while a genuinely empty list is a real result
-- (everything sold/cancelled/collected) and legitimately swaps in an empty snapshot.
-- Listings carry no ItemLocation and no readable tooltip data, so ilvl comes from the
-- itemKey (0 for commodities) with the link as fallback, and the upgrade track is left
-- unrecorded (nil fetchTip) -- a listed stack renders the trackless "ilvl X:" row form.
local function ScanAuctions()
	local char = EnsureChar()
	if not char then return end
	local list = GetOwnedAuctions and GetOwnedAuctions()
	if not list then return end
	if HasFullOwnedAuctionResults and not HasFullOwnedAuctionResults() then return end
	local items = {}
	for _, auction in ipairs(list) do
		local id = auction.itemKey and auction.itemKey.itemID
		if id and (auction.status == nil or auction.status == AUCTION_STATUS_ACTIVE) then
			local link = auction.itemLink
			local ilvl = auction.itemKey.itemLevel
			if not (ilvl and ilvl > 0) and link then
				ilvl = GetDetailedItemLevelInfo(link)
			end
			RecordStack(items, id, auction.quantity or 1, link, ilvl or 0, nil)
		end
	end
	char.auctions = { scannedAt = time(), items = items }
end

-- The inbox downloads to the client in pages: GetInboxNumItems() returns (numItems,
-- totalItems) where numItems is what is downloaded and indexable (1..numItems) and
-- totalItems is the server-side total -- the client shows at most 100 messages, and
-- past that only removing mail surfaces the rest. totalItems > numItems therefore means
-- "this scan cannot see everything": keep the stored snapshot (nil, the ReadableBankTabs
-- convention). No refetch loop here -- Blizzard's own InboxFrame re-issues CheckInbox()
-- until the two converge, firing MAIL_INBOX_UPDATE each round, which rescans. A complete
-- EMPTY inbox is a real result: 0 legitimately swaps in an empty snapshot.
local function ReadableInboxCount()
	if not GetInboxNumItems then return nil end
	local numItems, totalItems = GetInboxNumItems()
	if not numItems then return nil end
	if totalItems and totalItems > numItems then return nil end
	return numItems
end

-- A pending send-credit batch that is still plausibly in a mailbox somewhere. Checked at
-- read time as well as at the load-time prune, so a batch that crosses the 31-day line
-- mid-session drops out of the counts without a reload. Shape-checks defend against
-- hand-edited SavedVariables (the batches are the one array-of-tables in the schema).
local function FreshPending(batch, now)
	return type(batch) == "table"
		and type(batch.sentAt) == "number" and (now - batch.sentAt) < MAIL_PENDING_SECONDS
		and type(batch.items) == "table"
end

-- Appends one optimistic in-transit credit batch to a character's mailPending -- the
-- shared commit for every credit writer (mail sends, and the AH purchase/cancel credits
-- below). A nil char or an empty items table appends nothing: crediting degrades to
-- "not recorded", never to a zero-item batch or a resurrected character entry. Returns
-- the appended batch (nil when nothing was appended) so the commodity commit can keep a
-- reference for the downward quantity adjust.
local function CommitPendingBatch(char, items)
	if not (char and items and next(items)) then return nil end
	local pending = char.mailPending
	if not pending then
		pending = {}
		char.mailPending = pending
	end
	local batch = { sentAt = time(), items = items }
	pending[#pending + 1] = batch
	return batch
end

-- One-stack items table for an AH purchase/cancel credit, built fresh per commit (a
-- table shared between batches would alias). Listings carry no readable tooltip data,
-- so no upgrade track (nil fetchTip); ilvl mirrors ScanAuctions -- the itemKey value
-- when positive, the link as fallback, 0 for commodities.
local function CreditItems(id, qty, link, ilvl)
	if not (ilvl and ilvl > 0) and link then
		ilvl = GetDetailedItemLevelInfo(link)
	end
	local items = {}
	RecordStack(items, id, qty, link, ilvl or 0, nil)
	return items
end

-- The one commodity commit point: appends the credit, remembers the batch for the
-- downward adjust, and consumes both intent slots -- whichever finalization signal
-- lands first commits, the rest then find no slot and no-op. The representative link
-- is best-effort from the item cache (the item was just on screen at the AH); nil is
-- tolerated everywhere, like a linkless commodity listing.
local function CommitCommodity(itemID, qty)
	local link = GetItemInfo and select(2, GetItemInfo(itemID)) or nil
	local batch = CommitPendingBatch(EnsureChar(), CreditItems(itemID, qty, link, 0))
	commodityCommitted = batch
		and { itemID = itemID, quantity = qty, link = link, batch = batch }
		or nil
	commodityIntent, commodityCancelled = nil, nil
end

-- Commits every stashed cancel whose listing is GONE from a complete owned-listings
-- result set. This is the commodity-cancel commit path: AUCTION_CANCELED's payload is
-- only trustworthy for item listings -- a commodity-listing cancel fires it with a
-- junk low value (observed in-game: 1), so the fallback keys on the one fact the
-- refresh proves, the listing's absence. Absence from a COMPLETE list means
-- returned-by-mail: a sold listing never vanishes mid-session (its status flips to
-- Sold until the proceeds are collected -- at a mailbox, which can't happen while the
-- AH is open), and the only other exit, expiry, mails the items back too. A refused
-- cancel leaves its listing present, so its entry commits nothing and dies at AH
-- close. The ScanAuctions never-wipe guards apply verbatim: a nil or partial result
-- set proves nothing and commits nothing.
local function SweepPendingCancels()
	if not next(pendingCancels) then return end
	local list = GetOwnedAuctions and GetOwnedAuctions()
	if not list then return end
	if HasFullOwnedAuctionResults and not HasFullOwnedAuctionResults() then return end
	local present = {}
	for _, auction in ipairs(list) do
		if auction.auctionID then
			present[auction.auctionID] = true -- any status: Sold stays present, must not commit
		end
	end
	for auctionID, e in pairs(pendingCancels) do
		if not present[auctionID] then
			pendingCancels[auctionID] = nil
			CommitPendingBatch(EnsureChar(), CreditItems(e.id, e.qty, e.link, e.ilvl))
		end
	end
end

-- The character's mailbox. Readable only while the mailbox is open and only as far as
-- the inbox has downloaded (see ReadableInboxCount); scans are wholesale, never
-- incremental -- mail can vanish without any "taken" event (a recipient can delete a
-- mail with attachments, returns/refusals move items silently), so reconciliation beats
-- bookkeeping. A COD package from a stranger is NOT owned until paid for, so its
-- attachments are skipped -- unless the sender is one of this account's scanned
-- characters (own goods moving between alts stay owned throughout). Attached money is
-- ignored: gold is not an item. The per-attachment quality return of GetInboxItem is a
-- long-documented bug (-1) and is never read; C_TooltipInfo.GetInboxItem supplies
-- upgrade-track lines through the standard gear-gated fetch. A successful swap also
-- clears this character's own mailPending: the inbox now reflects reality (uncollected
-- sends are IN it, collected ones are in bags), so the optimistic credits are done.
local function ScanMail()
	local char = EnsureChar()
	if not char then return end
	local n = ReadableInboxCount()
	if not n then return end
	local items = {}
	for i = 1, n do
		-- (packageIcon, stationeryIcon, sender, subject, money, CODAmount, daysLeft, itemCount)
		local _, _, sender, _, _, cod, _, itemCount = GetInboxHeaderInfo(i)
		local counted = not (cod and cod > 0) or KnownCharKey(sender) ~= nil
		if counted and itemCount then -- itemCount is nil for item-less mail: skip the slot loop
			for j = 1, MAX_MAIL_RECEIVE do
				-- (name, itemID, texture, count, quality, canUse) -- quality is bugged (-1)
				local _, id, _, qty = GetInboxItem(i, j)
				local link = GetInboxItemLink and GetInboxItemLink(i, j) or nil
				if not id and link then
					id = GetItemInfoInstant(link)
				end
				if id then
					local ilvl = link and GetDetailedItemLevelInfo(link) or 0
					RecordStack(items, id, qty or 1, link, ilvl or 0,
						GetInboxItemTooltip and function() return GetInboxItemTooltip(i, j) end)
				end
			end
		end
	end
	char.mail = { scannedAt = time(), items = items }
	char.mailPending = nil
end

-- The outgoing attachment slots as an items table, or nil when every slot is empty (or
-- the API is absent) -- so callers can tell "nothing readable" from "a plain letter".
-- There is no count API for send attachments: the loop covers every slot and skips nils,
-- the way Blizzard's own send code iterates.
local function ScanSendSlots()
	if not GetSendMailItem then return nil end
	local items, any = {}, false
	for j = 1, MAX_MAIL_SEND do
		-- (name, itemID, texture, count, quality) -- same bugged quality, never read
		local _, id, _, qty = GetSendMailItem(j)
		local link = GetSendMailItemLink and GetSendMailItemLink(j) or nil
		if not id and link then
			id = GetItemInfoInstant(link)
		end
		if id then
			any = true
			local ilvl = link and GetDetailedItemLevelInfo(link) or 0
			RecordStack(items, id, qty or 1, link, ilvl or 0,
				GetSendMailItemTooltip and function() return GetSendMailItemTooltip(j) end)
		end
	end
	return any and items or nil
end

-- Visits every source store as fn(items, tag, altName) -- tag is
-- "bags"/"bank"/"equipped"/"mail"/"warband" for the current character (altName nil),
-- alts get altName (tag nil) with bags, bank, equipped and mail all visited so they
-- combine into one per-alt number. The "mail" tag is emitted for the inbox snapshot AND
-- for each fresh mailPending batch (AddSource accumulates multiple visits under one
-- tag), so the token/fold always shows their sum. Visit order doubles as representative
-- precedence (first non-nil link/track wins downstream): own bags, own bank, own
-- equipped, own mail (+pending), warband, then alts sorted by key for determinism.
--
-- `filter` is the display layer's source selection (nil = visit everything):
--   { bags = bool, bank = bool, equipped = bool, mail = bool, warband = bool,
--     alts = bool, altEquipped = bool,
--     hiddenChars = { ["Name-NormalizedRealm"] = true } }
-- `equipped` gates only the current character's worn gear; `altEquipped` gates whether
-- alts' worn gear folds into their per-alt number. `mail` likewise gates only the
-- current character's mailbox: alts' mail rides their per-alt number unconditionally
-- (like their bags and bank -- it is ordinary countable inventory, unlike worn gear, so
-- there is no altMail switch). Falsy flags skip that store wholesale; hiddenChars skips
-- individual alts and must be checked here -- the callback only ever sees the
-- realm-stripped display name, never the full key. Filtering at the iteration root is
-- what keeps "the total equals the sum of everything displayed" true by construction in
-- every aggregate built on top.
--
-- `filter.auctionsOnly` flips the visit set to the auction scope: ONLY auction stores --
-- the own character's char.auctions as tag "auctions", each alt's folded into its
-- altName -- with `alts` and `hiddenChars` still applying and the per-source flags
-- (bags/bank/...) never consulted (they have no meaning there). The normal path never
-- visits auction stores at all: listings are conditionally owned (yours only if the
-- listing fails), so they must not leak into any "Total items owned" aggregate -- the
-- tooltip layer renders them as their own "On auction" sub-section instead, built from
-- the same aggregates through this mode. Mail is the opposite call: mailbox contents
-- ARE unconditionally owned (only your own collecting moves them; even the 30-day
-- auto-return keeps them in the family), so mail sits in the normal visit set and the
-- auction scope never touches it.
local function ForEachSourceStore(fn, filter)
	if not db then return end
	local auctionsOnly = filter ~= nil and filter.auctionsOnly
	local me = ResolveCharKey()
	local char = me and db.chars[me]
	if char then
		if auctionsOnly then
			if char.auctions then fn(char.auctions.items, "auctions") end
		else
			if (not filter or filter.bags) and char.bags then fn(char.bags.items, "bags") end
			if (not filter or filter.bank) and char.bank then fn(char.bank.items, "bank") end
			if (not filter or filter.equipped) and char.equipped then fn(char.equipped.items, "equipped") end
			if not filter or filter.mail then
				if char.mail then fn(char.mail.items, "mail") end
				if char.mailPending then
					local now = time()
					for _, batch in ipairs(char.mailPending) do
						if FreshPending(batch, now) then fn(batch.items, "mail") end
					end
				end
			end
		end
	end
	-- The warband bank cannot hold listings, so the auction scope skips it.
	if not auctionsOnly and (not filter or filter.warband) and db.warband then
		fn(db.warband.items, "warband")
	end

	-- While the own key is still unresolved (pre-PLAYER_ENTERING_WORLD), self and alts are
	-- indistinguishable: skip the alt loop rather than misattribute the current character's
	-- own cached data as an alt of itself. Warband data above is unaffected.
	if not me then return end
	if filter and not filter.alts then return end
	local hidden = filter and filter.hiddenChars
	local altKeys
	for key in pairs(db.chars) do
		if key ~= me and not (hidden and hidden[key]) then
			altKeys = altKeys or {}
			altKeys[#altKeys + 1] = key
		end
	end
	if altKeys then
		table.sort(altKeys)
		for _, key in ipairs(altKeys) do
			-- Display name only; character names cannot contain "-", so the first
			-- segment is exact. (Same-named alts on two realms merge -- accepted;
			-- the key keeps the realm, so disambiguation can come later.)
			local altName = key:match("^[^-]+") or key
			local alt = db.chars[key]
			if auctionsOnly then
				if alt.auctions then fn(alt.auctions.items, nil, altName) end
			else
				if alt.bags then fn(alt.bags.items, nil, altName) end
				if alt.bank then fn(alt.bank.items, nil, altName) end
				-- Worn gear folds into the alt's combined per-alt number alongside bags/bank,
				-- gated by the altEquipped checkbox rather than the own-equipped tri-state.
				if (not filter or filter.altEquipped) and alt.equipped then
					fn(alt.equipped.items, nil, altName)
				end
				-- Mail (snapshot + fresh in-transit credits) folds in unconditionally, like
				-- bags/bank -- the own-mail tri-state gates the current character only.
				if alt.mail then fn(alt.mail.items, nil, altName) end
				if alt.mailPending then
					local now = time()
					for _, batch in ipairs(alt.mailPending) do
						if FreshPending(batch, now) then fn(batch.items, nil, altName) end
					end
				end
			end
		end
	end
end

-- Zero counts are never recorded, so "only non-zero locations appear" holds by
-- construction everywhere a sources table is consumed.
local function AddSource(sources, tag, altName, n)
	if n == 0 then return end
	if altName then
		local alts = sources.alts
		if not alts then
			alts = {}
			sources.alts = alts
		end
		alts[altName] = (alts[altName] or 0) + n
	else
		sources[tag] = (sources[tag] or 0) + n
	end
end

local function MergeSources(dst, src)
	if src.bags then dst.bags = (dst.bags or 0) + src.bags end
	if src.bank then dst.bank = (dst.bank or 0) + src.bank end
	if src.equipped then dst.equipped = (dst.equipped or 0) + src.equipped end
	if src.warband then dst.warband = (dst.warband or 0) + src.warband end
	if src.mail then dst.mail = (dst.mail or 0) + src.mail end
	if src.auctions then dst.auctions = (dst.auctions or 0) + src.auctions end
	if src.alts then
		local alts = dst.alts
		if not alts then
			alts = {}
			dst.alts = alts
		end
		for name, n in pairs(src.alts) do
			alts[name] = (alts[name] or 0) + n
		end
	end
end

-- Exported for the tooltip layer: the rare same-name+same-tier member collision merges
-- into one row, and the row's sources must merge the same way its counts do -- otherwise
-- the location suffix would stop summing to the row's count.
ns.MergeSources = MergeSources

-- Display layer reads counts through this seam: nil when nothing anywhere owns the item,
-- else a merged view across every source, built fresh per call (a handful of hash lookups
-- over tiny stores -- caching would only buy invalidation bugs):
--   {
--     total, link,                                          -- link/track: first non-nil in visit order
--     sources = { bags = n, bank = n, equipped = n, mail = n, warband = n,
--                 alts = { [name] = n } },                                    -- zero keys absent
--     groups  = { [ilvl] = { count, link, track, sources = <same shape> } },
--   }
-- An auctionsOnly filter yields the auction scope instead: `sources.auctions` (the own
-- character's listings) plus `alts` -- the two scopes' keys never mix in one view.
-- `filter` (optional) narrows the view to selected sources -- see ForEachSourceStore.
function ns.Get(itemID, filter)
	local agg
	ForEachSourceStore(function(items, tag, altName)
		local entry = items and items[itemID]
		if not entry then return end
		if not agg then
			agg = { total = 0, sources = {}, groups = {} }
		end
		agg.total = agg.total + entry.total
		agg.link = agg.link or entry.link
		AddSource(agg.sources, tag, altName, entry.total)
		for ilvl, group in pairs(entry.groups) do
			local aggGroup = agg.groups[ilvl]
			if not aggGroup then
				aggGroup = { count = 0, sources = {} }
				agg.groups[ilvl] = aggGroup
			end
			aggGroup.count = aggGroup.count + group.count
			aggGroup.link = aggGroup.link or group.link
			aggGroup.track = aggGroup.track or group.track
			AddSource(aggGroup.sources, tag, altName, group.count)
		end
	end, filter)
	return agg
end

-- The bracket name a hyperlink carries ("|h[Name]|h"), embedded at scan time when the
-- item was demonstrably present -- the cold-cache fallback for alt-owned items whose
-- itemID this session has never seen (GetItemNameByID returns nil for those).
local function LinkName(link)
	return link and link:match("%[(.-)%]")
end

-- The id universe: every distinct itemID in the visited stores, plus a representative
-- link per id (first non-nil in visit order; nil when no stored stack carried one --
-- linkless commodity listings). GetByName's first pass, shared with the chat search's
-- enumeration -- one body, two callers, so the visit set can never drift (the same rule
-- that keeps auctionsOnly inside ForEachSourceStore instead of a second iterator).
-- `filter` is the ForEachSourceStore filter, including auctionsOnly.
local function CollectIDs(filter)
	local ids, repLinks = {}, {}
	ForEachSourceStore(function(items)
		for id, entry in pairs(items) do
			ids[id] = true
			repLinks[id] = repLinks[id] or entry.link
		end
	end, filter)
	return ids, repLinks
end
ns.CollectItemIDs = CollectIDs

-- The one name-resolution rule (the quality-sibling join key and the chat search both
-- use it): the session's item cache first, the stored link's bracket name as the
-- cold-cache fallback. nil when neither resolves -- such an id can't join any name
-- match, the accepted failure mode documented in DESIGN.
function ns.ItemName(id, repLink)
	return GetItemNameByID(id) or LinkName(repLink)
end

-- Every owned stack that shares this item's base name -- i.e. its quality siblings.
-- Quality reagents are distinct itemIDs at the same name (the star is an icon overlay,
-- not part of the name), and there is no API to map siblings, so name is the join key.
-- Lazy at hover time: the stores are tiny, so this avoids a parallel index. Returns
-- (name, members, combined) -- members is an array of ns.Get views (plus an itemID
-- field), combined = { total, sources } summed across them, so "the grand total equals
-- the sum of everything displayed" lives here, not in the renderer.
-- `filter` (see ForEachSourceStore) applies to BOTH passes: a sibling owned only in a
-- filtered-out source must contribute neither a row nor a share of the combined total.
-- `accept(id, repLink)` (optional) is the caller's membership criterion on top of the
-- name match -- a rejected id contributes neither a member nor a share of the combined
-- total, the same all-or-nothing rule the filter follows. The tooltip layer passes "its
-- quality tier resolves right now", which keeps a same-name item that isn't actually a
-- quality sibling (duplicate item names exist across expansions) from inflating the
-- total, and keeps the total equal to the sum of the rows under every cache state.
function ns.GetByName(itemID, filter, accept)
	local ids, repLinks = CollectIDs(filter)

	local name = ns.ItemName(itemID, repLinks[itemID])
	local members, combined = {}, { total = 0, sources = {} }
	if name then
		for id in pairs(ids) do
			if ns.ItemName(id, repLinks[id]) == name
				and (not accept or accept(id, repLinks[id])) then
				local agg = ns.Get(id, filter)
				if agg then
					agg.itemID = id
					members[#members + 1] = agg
					combined.total = combined.total + agg.total
					MergeSources(combined.sources, agg.sources)
				end
			end
		end
	end
	return name, members, combined
end

-- Settings-layer seam: drops a scanned character's stored data (and its hidden flag --
-- the flag is meaningless without the data). The data layer owns every DB mutation, so
-- the panel calls this instead of reaching into db.chars. The current character is never
-- deletable -- the next scan would just rebuild it -- and an unresolved own key refuses
-- all deletes rather than risk dropping ourselves.
function ns.DeleteChar(key)
	if not (db and key) then return end
	local me = ResolveCharKey()
	if not me or key == me then return end
	db.chars[key] = nil
	local s = db.settings
	if s and s.hiddenChars then
		s.hiddenChars[key] = nil
	end
end

-- Bags rescan on login and whenever bag contents settle (BAG_UPDATE_DELAYED already
-- coalesces a burst of BAG_UPDATE events into one). Bank and warband snapshots refresh
-- while the bank frame is open -- BAG_UPDATE_DELAYED covers the bank-tab bag IDs then
-- too. BANKFRAME_CLOSED is known to fire twice; clearing a flag is idempotent, so the
-- quirk is harmless. PLAYERBANKSLOTS_CHANGED is legacy (pre-rework slots) -- unused.
-- Equipped gear rescans on PLAYER_ENTERING_WORLD, BAG_UPDATE_DELAYED, and
-- PLAYER_EQUIPMENT_CHANGED (which fires per slot as items are worn/removed/swapped). The
-- BAG_UPDATE_DELAYED scan is the post-login self-heal: the login PEW fires before the
-- client has the character's item data (so its scan reads nothing), and
-- PLAYER_EQUIPMENT_CHANGED does NOT fire on login (gear isn't "changing", it's just
-- present) -- so without piggybacking on the same delayed event that fixes bags, equipped
-- would stay empty until the first manual gear swap. The scan is a cheap ~30-slot sweep,
-- so a full rebuild per change is fine.
-- Auctions follow the bank's open-flag pattern: the owned-listings query is fired when
-- the AH opens, and OWNED_AUCTIONS_UPDATED rescans only while the flag is up -- a stray
-- post-close event must not scan stale API state. The close handler clears the flag
-- (idempotent like BANKFRAME_CLOSED) plus the purchase/cancel intent stashes below it.
-- The COMMODITY_* / AUCTION_HOUSE_PURCHASE_COMPLETED / AUCTION_CANCELED branches are
-- the finalization side of the AH crediting hooks at the end of this file: each commits
-- an in-transit mail credit only when its event resolves a stashed intent.
-- Mail mirrors the auction shape with the interaction manager as the primary open/close
-- signal (arg == MailInfo, exact match -- bank/merchant hides must not cross-talk;
-- MAIL_SHOW/MAIL_CLOSED stay registered as belts). Opening asks the server for the inbox
-- (throttle-gated -- Blizzard's own frame queues its own retry, so no timer here) and
-- never scans directly: GetInboxNumItems can legitimately read (0, 0) before data
-- arrives, and an immediate scan would swap in a false empty. MAIL_INBOX_UPDATE is the
-- scan trigger (it also fires per mail consumed during Open All, so counts shrink live
-- while looting). MAIL_SEND_INFO_UPDATE keeps the outgoing-slots snapshot current for
-- the send-crediting hook below.
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("BANKFRAME_OPENED")
frame:RegisterEvent("BANKFRAME_CLOSED")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("OWNED_AUCTIONS_UPDATED")
frame:RegisterEvent("COMMODITY_PURCHASED")
frame:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
frame:RegisterEvent("COMMODITY_PURCHASE_FAILED")
frame:RegisterEvent("COMMODITY_PRICE_UNAVAILABLE")
frame:RegisterEvent("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION")
frame:RegisterEvent("AUCTION_HOUSE_PURCHASE_COMPLETED")
frame:RegisterEvent("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION")
frame:RegisterEvent("AUCTION_CANCELED")
frame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
frame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
frame:RegisterEvent("MAIL_SHOW")
frame:RegisterEvent("MAIL_CLOSED")
frame:RegisterEvent("MAIL_INBOX_UPDATE")
frame:RegisterEvent("MAIL_SEND_INFO_UPDATE")
frame:RegisterEvent("MAIL_SEND_SUCCESS")
frame:RegisterEvent("MAIL_FAILED")
frame:RegisterEvent("MAIL_UNLOCK_SEND_ITEMS")
frame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)
	if event == "ADDON_LOADED" then
		if arg1 ~= addonName then return end
		if not (ExactItemCountDB and ExactItemCountDB.version == DB_VERSION and ExactItemCountDB.chars) then
			-- Version mismatch (or first run): rebuild rather than migrate. Everything
			-- dropped is a cache the scans reconstruct; settings are the one piece of real
			-- user data, and InitSettings sanitizes any shape they arrive in, so carry them.
			local old = ExactItemCountDB
			ExactItemCountDB = { version = DB_VERSION, chars = {} }
			if old and type(old.settings) == "table" then
				ExactItemCountDB.settings = old.settings
			end
		end
		db = ExactItemCountDB
		-- Prune expired send credits account-wide (no char key needed, so it can't wait
		-- for PEW): a batch past the 31-day line describes mail the game guarantees has
		-- moved -- collected, or auto-returned to the sender's inbox where the next scan
		-- picks it up. This is the only healer a credit has when its recipient never
		-- opens a mailbox with this addon (played on another PC, or abandoned).
		do
			local now = time()
			for _, char in pairs(db.chars) do
				local pending = char.mailPending
				if type(pending) == "table" then
					for i = #pending, 1, -1 do
						if not FreshPending(pending[i], now) then
							table.remove(pending, i)
						end
					end
					if #pending == 0 then char.mailPending = nil end
				else
					char.mailPending = nil
				end
			end
		end
		-- Write-only diagnostic: which addon version last wrote this DB (for bug reports).
		db.addonVersion = C_AddOns.GetAddOnMetadata(addonName, "Version")
		-- Settings.lua's main chunk has already run (ADDON_LOADED fires after every file
		-- loads), so hand it the DB: it default-fills db.settings and registers the panel.
		if ns.InitSettings then ns.InitSettings(db) end
		self:UnregisterEvent("ADDON_LOADED")
	elseif event == "PLAYER_ENTERING_WORLD" then
		ScanBags()
		ScanEquipped()
	elseif event == "BAG_UPDATE_DELAYED" then
		ScanBags()
		ScanEquipped()
		if bankOpen then
			ScanBank()
			ScanWarband()
		end
	elseif event == "BANKFRAME_OPENED" then
		bankOpen = true
		ScanBank()
		ScanWarband()
	elseif event == "BANKFRAME_CLOSED" then
		bankOpen = false
	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		ScanEquipped()
	elseif event == "AUCTION_HOUSE_SHOW" then
		ahOpen = true
		if QueryOwnedAuctions then QueryOwnedAuctions({}) end
	elseif event == "OWNED_AUCTIONS_UPDATED" then
		if ahOpen then
			ScanAuctions()
			SweepPendingCancels()
		end
	elseif event == "AUCTION_HOUSE_CLOSED" then
		ahOpen = false
		-- Unresolved purchase/cancel intents die with the AH visit: a finalization
		-- event straggling in after close finds nothing and credits nothing -- the
		-- send-credit close-discard discipline (undercount at worst, heals at the
		-- mailbox), never a credit for a transaction whose outcome was never seen.
		commodityIntent, commodityCancelled, commodityCommitted = nil, nil, nil
		pendingBuyouts, pendingCancels = {}, {}
	elseif event == "COMMODITY_PURCHASED" then
		-- (itemID, quantity) -- on paper the best commodity signal (the actual fill),
		-- but it has ZERO consumers in Blizzard's 12.1 client and never showed in an
		-- in-game trace: treated as likely dead, kept as a legacy commit in case it
		-- fires on some path. Intent-gated: with no matching Confirm stash this may be
		-- a buyer taking YOUR listing, and a quantity above the request cannot be our
		-- purchase; both leave the stash for the real resolution (SUCCEEDED below).
		local slot = commodityIntent or commodityCancelled
		if slot and slot.itemID == arg1
			and type(arg2) == "number" and arg2 > 0 and arg2 <= slot.quantity then
			CommitCommodity(arg1, arg2)
		end
	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
		-- Payload-free, but verifiably alive (Blizzard's BuyDialog hides on exactly
		-- it) -- the working commit signal on 12.1. The quantity is the request,
		-- refined to the actual fill when the won-toast landed first (wonQty); a
		-- toast landing after the commit still shrinks the batch below. The demoted
		-- slot MUST be accepted here: the dialog's own SUCCEEDED handler hides it,
		-- whose OnHide cancel may demote the intent before this handler runs.
		local slot = commodityIntent or commodityCancelled
		if slot then
			local qty = slot.quantity
			if slot.wonQty and slot.wonQty < qty then qty = slot.wonQty end
			CommitCommodity(slot.itemID, qty)
		end
	elseif event == "AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION" then
		-- (commodityName, commodityQuantity) -- the buyer's "You won X" chat toast,
		-- carrying the ACTUAL fill. Refiner only, NEVER a committer: a name+quantity
		-- payload cannot be attributed safely enough to commit (a straggling toast
		-- from purchase A must not credit a pending same-item purchase B -- see
		-- DESIGN). Pre-commit it annotates the slot; post-commit it shrinks the
		-- committed batch, downward only and only on a positively resolved name.
		local qty = arg2
		if type(qty) == "number" and qty > 0 then
			local slot = commodityIntent or commodityCancelled
			if slot and qty <= slot.quantity then
				-- A resolved name mismatch proves the toast is not this purchase; an
				-- unresolved name stays permissive (the slot's itemID is the real gate,
				-- and quality tiers share names anyway -- accepted, undercount-only).
				local name = GetItemInfo and GetItemInfo(slot.itemID) or nil
				if not (name and arg1 and name ~= arg1) then
					slot.wonQty = qty
				end
			elseif not slot and commodityCommitted and qty < commodityCommitted.quantity then
				local c = commodityCommitted
				local name = GetItemInfo and GetItemInfo(c.itemID) or nil
				if name and arg1 and name == arg1 then
					c.batch.items = CreditItems(c.itemID, qty, c.link, 0)
					c.quantity = qty
				end
			end
		end
	elseif event == "COMMODITY_PURCHASE_FAILED" or event == "COMMODITY_PRICE_UNAVAILABLE" then
		-- The purchase in flight died (server refusal, or the quote vanished before
		-- confirmation): nothing was finalized, so the live intent and the demoted one
		-- are both stale now. The committed reference survives -- a committed batch is
		-- never retracted, and a late fill report may still need to shrink it.
		commodityIntent, commodityCancelled = nil, nil
	elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
		-- (auctionID) -- Blizzard's own buyout finalization signal; a plain bid fires
		-- BID_ADDED instead, so it can never commit. Observed in-game: it also fires
		-- with auctionID 0 for COMMODITY purchases (undocumented), so non-positive ids
		-- are ignored outright. The stashed entry may still lack item data
		-- (GetAuctionInfoByID's whole return is optional): retry the lookup here, and
		-- if it still won't resolve keep the entry for the won-toast fallback below.
		if type(arg1) == "number" and arg1 > 0 then
			local e = pendingBuyouts[arg1]
			if e then
				if not e.id then
					local info = GetAuctionInfoByID and GetAuctionInfoByID(arg1)
					local key = info and info.itemKey
					if key and key.itemID then
						e.id, e.link, e.ilvl = key.itemID, info.itemLink, key.itemLevel
					end
				end
				if e.id then
					pendingBuyouts[arg1] = nil
					-- AuctionInfo has no quantity field: non-commodity listings are
					-- single items (stackables are commodities since the 8.3 AH), so 1.
					CommitPendingBatch(EnsureChar(), CreditItems(e.id, 1, e.link, e.ilvl))
				end
			end
		end
	elseif event == "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION" then
		-- (notification, text, auctionID?) -- the buyer's "You won an auction for X"
		-- chat toast, the fallback identifier for a buyout whose item never resolved
		-- through GetAuctionInfoByID (its text embeds the item link). Strictly keyed:
		-- only a bid this session stashed may commit, a nil auctionID attributes to
		-- nothing, and text without a complete item link is a no-op -- the entry then
		-- dies at AH close (fails closed into "not recorded").
		if arg1 == AUCTION_NOTIFY_WON and type(arg3) == "number" and arg3 > 0 then
			local e = pendingBuyouts[arg3]
			if e then
				if not e.id and type(arg2) == "string" then
					local link = arg2:match("|Hitem:.-|h%[.-%]|h")
					if link then
						e.id, e.link = GetItemInfoInstant(link), link
					end
				end
				if e.id then
					pendingBuyouts[arg3] = nil
					CommitPendingBatch(EnsureChar(), CreditItems(e.id, 1, e.link, e.ilvl))
				end
			end
		end
	elseif event == "AUCTION_CANCELED" then
		-- (auctionID) -- the async completion of CancelAuction; the cancelled stack
		-- returns by mail. The payload is only trustworthy for ITEM listings: a
		-- commodity-listing cancel fires this with a junk low value (observed: 1),
		-- so an unmatched payload leaves the stash for the owned-list sweep. Either
		-- way the owned-listings requery is nudged: it hands the sweep its complete
		-- result set and drops the cancelled listing from the "On auction" scope;
		-- until it lands, the brief mail+auction double-show is the documented
		-- accepted staleness (the two scopes never sum into one number).
		local e = pendingCancels[arg1]
		if e then
			pendingCancels[arg1] = nil
			CommitPendingBatch(EnsureChar(), CreditItems(e.id, e.qty, e.link, e.ilvl))
		end
		if (e or next(pendingCancels)) and ahOpen and QueryOwnedAuctions then
			QueryOwnedAuctions({})
		end
	elseif event == "MAIL_SHOW"
		or (event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" and arg1 == INTERACTION_MAILBOX) then
		-- Both signals may fire for one mailbox: query only on the closed->open edge.
		if not mailOpen then
			mailOpen = true
			if CheckInbox and (not CanCheckInbox or CanCheckInbox()) then
				CheckInbox()
			end
		end
	elseif event == "MAIL_INBOX_UPDATE" then
		if mailOpen then ScanMail() end
	elseif event == "MAIL_SEND_INFO_UPDATE" then
		if mailOpen then sendSnapshot = ScanSendSlots() end
	elseif event == "MAIL_SEND_SUCCESS" then
		-- Commit the stashed send into the recipient's pending credits. KnownCharKey only
		-- returns keys already in db.chars, so the entry exists; the nil-char guard inside
		-- CommitPendingBatch covers a mid-session DeleteChar race, and an empty stash (a
		-- plain letter, or nothing readable) appends no batch.
		if pendingSend and db then
			CommitPendingBatch(db.chars[pendingSend.recipientKey], pendingSend.items)
		end
		pendingSend, sendSnapshot = nil, nil
	elseif event == "MAIL_FAILED" or event == "MAIL_UNLOCK_SEND_ITEMS" then
		-- Failed send, or a cancelled confirmation dialog (the third outcome: neither
		-- SUCCESS nor FAILED ever fires). The items are back in the slots, so the running
		-- snapshot stays -- a re-send without another MAIL_SEND_INFO_UPDATE must still
		-- find them; only the per-call stash is discarded.
		pendingSend = nil
	elseif event == "MAIL_CLOSED"
		or (event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" and arg1 == INTERACTION_MAILBOX) then
		mailOpen = false -- idempotent, like BANKFRAME_CLOSED
		pendingSend, sendSnapshot = nil, nil
	end
end)

-- Send-crediting: SendMail(recipient, ...) is the one moment the recipient name is in
-- hand, so a post-hook stashes { recipient's char key, the outgoing attachments }. The
-- call is async -- the stash commits on MAIL_SEND_SUCCESS and is discarded on failure,
-- cancel, or mailbox close (branches above). Whether the attachment slots are still
-- readable inside the hook is unverified in-game, so the running sendSnapshot (rebuilt
-- on MAIL_SEND_INFO_UPDATE) is the fallback; a readable re-read here is fresher and
-- wins. A recipient that doesn't normalize to a scanned character key credits nothing:
-- mail to anyone else is a gift leaving ownership, correctly counted nowhere. The
-- type() guard keeps a future rename from erroring at load -- the send-crediting half
-- then silently disables while the inbox half keeps working.
if hooksecurefunc and type(SendMail) == "function" then
	hooksecurefunc("SendMail", function(recipient)
		local key = KnownCharKey(recipient)
		pendingSend = key
			and { recipientKey = key, items = ScanSendSlots() or sendSnapshot }
			or nil
	end)
end

-- AH purchase/cancel crediting: bought and cancelled goods travel by mail, so each
-- finalized transaction appends an in-transit credit to the OWN character's mailPending
-- (the send-credit lifecycle verbatim: superseded by the next full inbox scan, 31-day
-- prune). The hooks below only record intent -- commits ride the finalization events in
-- the handler above, so a transaction that never resolves credits nothing. Stash writes
-- are gated on ahOpen (the OWNED_AUCTIONS_UPDATED discipline: a stray call with the AH
-- closed must not plant a lingering intent); the per-function type() guards are the
-- SendMail rename insurance -- a renamed API silently disables its credit path only.
if hooksecurefunc and C_AuctionHouse then
	if type(C_AuctionHouse.ConfirmCommoditiesPurchase) == "function" then
		-- (itemID, quantity) -- the moment the player commits to the quoted purchase.
		hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, quantity)
			if not ahOpen then return end
			if type(itemID) == "number" and type(quantity) == "number" and quantity > 0 then
				commodityIntent = { itemID = itemID, quantity = quantity }
				commodityCancelled, commodityCommitted = nil, nil
			end
		end)
	end
	if type(C_AuctionHouse.StartCommoditiesPurchase) == "function" then
		-- A new quote flow: whatever purchase state preceded it is not this purchase.
		hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", function()
			commodityIntent, commodityCancelled, commodityCommitted = nil, nil, nil
		end)
	end
	if type(C_AuctionHouse.CancelCommoditiesPurchase) == "function" then
		-- Demote, don't discard: Blizzard's BuyDialog cancels on hide INCLUDING the
		-- success path, and after a mid-session /reload its frames receive events
		-- before this addon's -- a plain discard would then always run ahead of the
		-- commit and no commodity credit could ever land. The demoted slot still
		-- commits on COMMODITY_PURCHASED; the guard keeps a second Cancel call (there
		-- is one per dialog hide) from wiping it.
		hooksecurefunc(C_AuctionHouse, "CancelCommoditiesPurchase", function()
			if commodityIntent then
				commodityCancelled, commodityIntent = commodityIntent, nil
			end
		end)
	end
	if type(C_AuctionHouse.PlaceBid) == "function" then
		-- (auctionID, bidAmount) -- covers bids AND buyouts (a buyout is a bid at the
		-- buyout price); which one this was is undecidable here, so the stash is only
		-- ever consumed by a finalization event naming this auctionID -- events only
		-- buyouts fire. The entry is stashed even when GetAuctionInfoByID resolves
		-- nothing (its whole return is optional, and Blizzard itself only queries it
		-- BEFORE the confirm popup): an id-less entry marks "bid in flight" and gets
		-- its item filled in at commit time or from the won-toast fallback.
		hooksecurefunc(C_AuctionHouse, "PlaceBid", function(auctionID)
			if not ahOpen or type(auctionID) ~= "number" or auctionID <= 0 then return end
			local info = GetAuctionInfoByID and GetAuctionInfoByID(auctionID)
			local key = info and info.itemKey
			pendingBuyouts[auctionID] = {
				id = key and key.itemID or nil,
				link = info and info.itemLink or nil,
				ilvl = key and key.itemLevel or nil,
			}
		end)
	end
	if type(C_AuctionHouse.CancelAuction) == "function" then
		-- (ownedAuctionID). The stored auctions snapshot is aggregated per itemID+ilvl
		-- and keeps no auctionIDs, so the listing's stack is read from the live owned
		-- list while it still exists; a non-Active listing returns gold, not items,
		-- and an unreadable list degrades to "not recorded", never to a wrong count.
		hooksecurefunc(C_AuctionHouse, "CancelAuction", function(auctionID)
			if not ahOpen or auctionID == nil then return end
			local list = GetOwnedAuctions and GetOwnedAuctions()
			if not list then return end
			for _, auction in ipairs(list) do
				if auction.auctionID == auctionID then
					local id = auction.itemKey and auction.itemKey.itemID
					if id and (auction.status == nil or auction.status == AUCTION_STATUS_ACTIVE) then
						pendingCancels[auctionID] = {
							id = id, link = auction.itemLink,
							ilvl = auction.itemKey.itemLevel,
							qty = auction.quantity or 1,
						}
					end
					return
				end
			end
		end)
	end
end
