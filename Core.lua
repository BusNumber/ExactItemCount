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
local GetBagItemTooltip       = C_TooltipInfo and C_TooltipInfo.GetBagItem
local GetInventoryItemTooltip = C_TooltipInfo and C_TooltipInfo.GetInventoryItem
local GetInventoryItemID      = GetInventoryItemID    -- global; (unit, slot) -> itemID|nil
local GetInventoryItemLink    = GetInventoryItemLink  -- global; (unit, slot) -> hyperlink|nil

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

-- Visits every source store as fn(items, tag, altName) -- tag is
-- "bags"/"bank"/"equipped"/"warband" for the current character (altName nil), alts get
-- altName (tag nil) with bags, bank and equipped all visited so they combine into one
-- per-alt number. Visit order doubles as representative precedence (first non-nil
-- link/track wins downstream): own bags, own bank, own equipped, warband, then alts
-- sorted by key for determinism.
--
-- `filter` is the display layer's source selection (nil = visit everything):
--   { bags = bool, bank = bool, equipped = bool, warband = bool, alts = bool,
--     altEquipped = bool, hiddenChars = { ["Name-NormalizedRealm"] = true } }
-- `equipped` gates only the current character's worn gear; `altEquipped` gates whether
-- alts' worn gear folds into their per-alt number. Falsy flags skip that store wholesale;
-- hiddenChars skips individual alts and must be checked here -- the callback only ever
-- sees the realm-stripped display name, never the full key. Filtering at the iteration
-- root is what keeps "the total equals the sum of everything displayed" true by
-- construction in every aggregate built on top.
local function ForEachSourceStore(fn, filter)
	if not db then return end
	local me = charKey and db.chars[charKey]
	if me then
		if (not filter or filter.bags) and me.bags then fn(me.bags.items, "bags") end
		if (not filter or filter.bank) and me.bank then fn(me.bank.items, "bank") end
		if (not filter or filter.equipped) and me.equipped then fn(me.equipped.items, "equipped") end
	end
	if (not filter or filter.warband) and db.warband then fn(db.warband.items, "warband") end

	if filter and not filter.alts then return end
	local hidden = filter and filter.hiddenChars
	local altKeys
	for key in pairs(db.chars) do
		if key ~= charKey and not (hidden and hidden[key]) then
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
			local char = db.chars[key]
			if char.bags then fn(char.bags.items, nil, altName) end
			if char.bank then fn(char.bank.items, nil, altName) end
			-- Worn gear folds into the alt's combined per-alt number alongside bags/bank,
			-- gated by the altEquipped checkbox rather than the own-equipped tri-state.
			if (not filter or filter.altEquipped) and char.equipped then
				fn(char.equipped.items, nil, altName)
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

-- Display layer reads counts through this seam: nil when nothing anywhere owns the item,
-- else a merged view across every source, built fresh per call (a handful of hash lookups
-- over tiny stores -- caching would only buy invalidation bugs):
--   {
--     total, link,                                          -- link/track: first non-nil in visit order
--     sources = { bags = n, bank = n, warband = n, alts = { [name] = n } },   -- zero keys absent
--     groups  = { [ilvl] = { count, link, track, sources = <same shape> } },
--   }
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

-- Every owned stack that shares this item's base name -- i.e. its quality siblings.
-- Quality reagents are distinct itemIDs at the same name (the star is an icon overlay,
-- not part of the name), and there is no API to map siblings, so name is the join key.
-- Lazy at hover time: the stores are tiny, so this avoids a parallel index. Returns
-- (name, members, combined) -- members is an array of ns.Get views (plus an itemID
-- field), combined = { total, sources } summed across them, so "the grand total equals
-- the sum of everything displayed" lives here, not in the renderer.
-- `filter` (see ForEachSourceStore) applies to BOTH passes: a sibling owned only in a
-- filtered-out source must contribute neither a row nor a share of the combined total.
function ns.GetByName(itemID, filter)
	local ids, repLinks = {}, {}
	ForEachSourceStore(function(items)
		for id, entry in pairs(items) do
			ids[id] = true
			repLinks[id] = repLinks[id] or entry.link
		end
	end, filter)

	local name = GetItemNameByID(itemID) or LinkName(repLinks[itemID])
	local members, combined = {}, { total = 0, sources = {} }
	if name then
		for id in pairs(ids) do
			if (GetItemNameByID(id) or LinkName(repLinks[id])) == name then
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
-- Equipped gear rescans on login and on PLAYER_EQUIPMENT_CHANGED (which fires per slot as
-- items are worn/removed/swapped); the scan is a cheap ~30-slot sweep, so a full rebuild
-- per change is fine.
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("BANKFRAME_OPENED")
frame:RegisterEvent("BANKFRAME_CLOSED")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:SetScript("OnEvent", function(self, event, arg1)
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
	end
end)
