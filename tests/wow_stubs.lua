-- tests/wow_stubs.lua -- WoW API stubs for the LuaJIT test harness.
-- Covers everything Core.lua, Tooltip.lua AND Settings.lua touch at load and during the
-- tested flows -- unlike a typical addon harness, all three files load here (the Settings
-- panel builds against the fake `Settings` API below; its rendered UI is never asserted
-- on -- panel behavior stays on the in-game checklist).
--
-- Usage: local stubs = dofile("tests/wow_stubs.lua"); stubs.install(); ...
-- install() resets every knob, so each test starts from a clean world.
--
-- Stubs are deliberately strict where the real API has a documented contract the addon
-- relies on: the quality lookups and RequestLoadItemDataByID error on non-string
-- arguments, and GetDetailedItemLevelInfo errors on nil -- so a regression that removes
-- one of the production guards fails a test instead of passing silently.

local M = {}

-- ---------------------------------------------------------------------------
-- Magic widgets: frame/font-string/initializer surrogates whose unknown methods
-- resolve to a memoized no-op returning another magic widget. This absorbs the
-- whole Settings-panel build (SetPoint, CreateFontString, SetParentInitializer,
-- GetID, ...) without hand-writing dozens of stubs. Methods that must capture
-- state (RegisterEvent/SetScript for the event bus) are set explicitly on the
-- instance and therefore shadow the metatable.
local widgetMeta
local function Widget(t)
	return setmetatable(t or {}, widgetMeta)
end
widgetMeta = {
	__index = function(t, k)
		local fn = function() return Widget() end
		rawset(t, k, fn)
		return fn
	end,
}

-- Mutable knobs. Reset by install().
local function resetState()
	M.now = 1000              -- _G.time() clock
	M.charName = "Tester"
	M.realm = "TestRealm"     -- nil models pre-PLAYER_ENTERING_WORLD (charKey unresolvable)
	M.metadata = { Version = "test" }
	M.keys = { ALT = false, SHIFT = false, CTRL = false }
	M.frames = {}             -- every mock frame CreateFrame returned (the event bus)
	M.items = {}              -- [itemID] = { name, equipLoc, ilvl, crafted, reagent }
	M.links = {}              -- [link string] = { itemID, ilvl, crafted, reagent }
	M.containers = {}         -- [bagID] = { stacks = { [slot] = stack }, numSlots = n }
	M.equipped = {}           -- [invSlot] = stack
	M.bankTabs = {}           -- [Enum.BankType.*] = { bagID, ... } | nil (none purchased)
	M.bankUsable = {}         -- [Enum.BankType.*] = bool (C_Bank.CanUseBank)
	M.ownedAuctions = nil     -- GetOwnedAuctions result; nil = no result set in hand
	M.fullOwnedResults = true -- HasFullOwnedAuctionResults (false = partial pages)
	M.auctionsByID = {}       -- [auctionID] = AuctionInfo for GetAuctionInfoByID
	M.inbox = {}              -- messages: { sender=, cod=, money=, attachments={stack,...} }
	M.inboxTotal = nil        -- GetInboxNumItems 2nd return (server total); nil = #M.inbox
	M.canCheckInbox = true    -- C_Mail.CanCheckInbox (false = server throttle)
	M.sendSlots = {}          -- [slot] = stack, the outgoing attachment slots
	M.sendSlotsClearOnSend = false -- true: SendMail empties the slots BEFORE hooks run,
	                          -- modeling "slots unreadable inside a post-hook"
	M.displayedLink = nil     -- TooltipUtil.GetDisplayedItem fallback result
	M.calls = { bagTip = 0, invTip = 0, inboxTip = 0, sendTip = 0,
		queryOwned = 0, checkInbox = 0, requestLoad = {}, openToCategory = 0 }
	M.chatLines = {}          -- DEFAULT_CHAT_FRAME:AddMessage captures (chat output)
	M.settingsRegistry = {}   -- [variable] = capture from Settings.Register*Setting
	M.valueChangedCallbacks = {}
	M.itemPostCall = nil      -- the tooltip post-call Tooltip.lua registered (test entry point)
	M.itemPostCallType = nil
	M.watched = {}            -- the four watched-tooltip fakes (GameTooltip & co)
end

function M.setTime(t) M.now = t end
function M.advance(dt) M.now = M.now + dt end

-- ---------------------------------------------------------------------------
-- Item/link model. Quality and ilvl resolve link-first then fall back to the
-- itemID's values (bonus IDs live on the link in the real API; per-rank crafted
-- gear needs per-link values, reagents are fine with per-id ones). A link built
-- with no def and an id that was never defineItem()d models the cold cache: the
-- bracket name still parses (LinkName fallback) but name/quality lookups fail.

-- def: { name=, equipLoc= (default "INVTYPE_NON_EQUIP_IGNORE"), ilvl=, crafted=,
--        reagent=, classID= }
function M.defineItem(id, def)
	M.items[id] = def or {}
	return id
end

-- Builds and registers a hyperlink for `id`; distinct tags give one id distinct link
-- strings (one per crafting rank/ilvl). def overrides the link-level values, incl. the
-- bracket name for ids deliberately left un-defineItem()d (cold-cache fixtures).
function M.link(id, tag, def)
	local item = M.items[id]
	local name = (def and def.name) or (item and item.name) or ("Item" .. tostring(id))
	local link = "|Hitem:" .. id .. ":" .. (tag or "") .. "|h[" .. name .. "]|h"
	M.links[link] = {
		itemID = id,
		ilvl = def and def.ilvl,
		crafted = def and def.crafted,
		reagent = def and def.reagent,
	}
	return link
end

local function itemFor(idOrLink)
	if type(idOrLink) == "number" then
		return idOrLink, M.items[idOrLink]
	end
	if type(idOrLink) ~= "string" then return nil end
	local ld = M.links[idOrLink]
	local id = ld and ld.itemID or tonumber(idOrLink:match("item:(%d+)"))
	return id, id and M.items[id] or nil
end

local function linkField(link, field)
	local ld = M.links[link]
	if ld and ld[field] ~= nil then return ld[field] end
	local _, item = itemFor(link)
	return item and item[field] or nil
end

-- ---------------------------------------------------------------------------
-- Inventory model feeding the scans.

-- stack = { id=, count=, link= (auto-built if omitted; false = no hyperlink), ilvl=,
--           track = {name=,step=,max=} | tipLines = TooltipDataLine[] }
-- Call defineItem for the ids first: the auto-built link embeds the item's name.
function M.setContainer(bagID, stacks, numSlots)
	stacks = stacks or {}
	for slot, s in ipairs(stacks) do
		if s.link == nil then
			s.link = M.link(s.id, "b" .. bagID .. "s" .. slot)
		end
	end
	M.containers[bagID] = { stacks = stacks, numSlots = numSlots or #stacks }
end

function M.setEquipped(slot, stack)
	if stack and stack.link == nil then
		stack.link = M.link(stack.id, "e" .. slot)
	end
	M.equipped[slot] = stack
end

-- Registers a bank type's purchased tab bag IDs and marks it usable; tab contents are
-- set with M.setContainer(tabBagID, ...). Flip M.bankUsable[bankType] for the
-- CanUseBank never-wipe case.
function M.setBank(bankType, tabIDs)
	M.bankTabs[bankType] = tabIDs
	M.bankUsable[bankType] = true
end

-- Replaces the inbox with `messages` ({ sender=, cod=, money=, attachments = { stack,
-- ... } }), auto-building attachment links like setContainer does. Mail has no
-- ItemLocation, so a stack's ilvl only reaches the scan through its link -- the
-- auto-link embeds it.
function M.setInbox(messages)
	messages = messages or {}
	for i, msg in ipairs(messages) do
		for j, a in ipairs(msg.attachments or {}) do
			if a.link == nil then
				a.link = M.link(a.id, "m" .. i .. "a" .. j, a.ilvl and { ilvl = a.ilvl } or nil)
			end
		end
	end
	M.inbox = messages
end

-- One outgoing attachment slot; auto-links like setEquipped (ilvl embedded, see setInbox).
function M.setSendSlot(slot, stack)
	if stack and stack.link == nil then
		stack.link = M.link(stack.id, "send" .. slot, stack.ilvl and { ilvl = stack.ilvl } or nil)
	end
	M.sendSlots[slot] = stack
end

-- The stack's TooltipData lines: explicit tipLines win; a `track` synthesizes the
-- English-format upgrade line (locale-shape tests pass raw tipLines instead). A leading
-- filler line makes sure ParseUpgradeTrack actually iterates.
local function tipLinesFor(stack)
	if stack.tipLines then return stack.tipLines end
	if stack.track then
		local t = stack.track
		return {
			{ leftText = "Soulbound" },
			{ leftText = ("Upgrade Level: %s %d/%d"):format(t.name, t.step, t.max) },
		}
	end
	return {}
end

-- ---------------------------------------------------------------------------
-- Event bus: fire an event into every mock frame registered for it.
function M.fire(event, ...)
	for _, f in ipairs(M.frames) do
		if f.events[event] and f.scripts.OnEvent then
			f.scripts.OnEvent(f, event, ...)
		end
	end
end

-- Sets the modifier state AND fires MODIFIER_STATE_CHANGED the way the client does
-- (key name like "LALT", down as 1/0) -- for the tooltip-refresh watcher tests.
local KEY_TO_MOD = {
	LSHIFT = "SHIFT", RSHIFT = "SHIFT",
	LALT = "ALT", RALT = "ALT",
	LCTRL = "CTRL", RCTRL = "CTRL",
}
function M.pressModifier(key, down)
	local mod = KEY_TO_MOD[key]
	if mod then M.keys[mod] = down and true or false end
	M.fire("MODIFIER_STATE_CHANGED", key, down and 1 or 0)
end

-- ---------------------------------------------------------------------------

function M.install()
	resetState()

	_G.time = function() return M.now end
	_G.UnitName = function() return M.charName end
	_G.GetNormalizedRealmName = function() return M.realm end

	_G.IsAltKeyDown = function() return M.keys.ALT end
	_G.IsShiftKeyDown = function() return M.keys.SHIFT end
	_G.IsControlKeyDown = function() return M.keys.CTRL end

	_G.Enum = {
		BagIndex = { Backpack = 0, ReagentBag = 5 },
		BankType = { Character = 0, Account = 2 },
		ItemClass = { Recipe = 9 },
		TooltipDataType = { Item = 17 },
		AuctionStatus = { Active = 0, Sold = 1 },
		AuctionHouseNotification = { -- live 12.1 values (AuctionHouseEnumsDocumentation)
			BidPlaced = 0, AuctionRemoved = 1, AuctionWon = 2,
			AuctionOutbid = 3, AuctionSold = 4, AuctionExpired = 5,
		},
		PlayerInteractionType = { MailInfo = 17 }, -- the live client's value
	}
	_G.INVSLOT_FIRST_EQUIPPED = 1
	_G.INVSLOT_LAST_EQUIPPED = 19
	_G.ATTACHMENTS_MAX_RECEIVE = 16 -- Blizzard-Lua globals, mirrored with live values
	_G.ATTACHMENTS_MAX_SEND = 12
	-- Consumed once at Core.lua load into trackPattern; locale-shape tests override this
	-- in loadAddon's setup hook, BEFORE the files load.
	_G.ITEM_UPGRADE_TOOLTIP_FORMAT_STRING = "Upgrade Level: %s %d/%d"

	-- Mock frame: captures RegisterEvent + SetScript so M.fire can drive OnEvent; every
	-- other method (the Settings panel's frame building) falls through to magic widgets.
	_G.CreateFrame = function()
		local f = Widget({ events = {}, scripts = {} })
		f.RegisterEvent = function(self, e) self.events[e] = true end
		f.UnregisterEvent = function(self, e) self.events[e] = nil end
		f.SetScript = function(self, k, fn) self.scripts[k] = fn end
		M.frames[#M.frames + 1] = f
		return f
	end

	_G.C_Container = {
		GetContainerNumSlots = function(bagID)
			local c = M.containers[bagID]
			return c and c.numSlots or 0 -- the real API returns 0, never nil
		end,
		GetContainerItemInfo = function(bagID, slot)
			local c = M.containers[bagID]
			local s = c and c.stacks[slot]
			if not s then return nil end
			return {
				itemID = s.id,
				stackCount = s.count,
				hyperlink = s.link ~= false and s.link or nil,
			}
		end,
	}

	-- One reused location object, exactly like production's scanLoc: each Set* fully
	-- replaces the target, so stale bag state can never leak into an equipped read.
	_G.ItemLocation = {
		CreateEmpty = function()
			return {
				SetBagAndSlot = function(self, bag, slot)
					self.kind, self.bag, self.slot = "bag", bag, slot
				end,
				SetEquipmentSlot = function(self, slot)
					self.kind, self.bag, self.slot = "equip", nil, slot
				end,
			}
		end,
	}

	local function stackAt(loc)
		if loc.kind == "bag" then
			local c = M.containers[loc.bag]
			return c and c.stacks[loc.slot]
		elseif loc.kind == "equip" then
			return M.equipped[loc.slot]
		end
	end

	_G.C_Item = {
		GetItemInfoInstant = function(idOrLink)
			local id, item = itemFor(idOrLink)
			if not id then return nil end
			-- (itemID, itemType, itemSubType, itemEquipLoc, icon, classID, subclassID)
			return id, nil, nil, (item and item.equipLoc) or "INVTYPE_NON_EQUIP_IGNORE",
				nil, item and item.classID or nil
		end,
		GetCurrentItemLevel = function(loc)
			local s = stackAt(loc)
			return s and s.ilvl or nil
		end,
		GetDetailedItemLevelInfo = function(link)
			if type(link) ~= "string" then
				error("GetDetailedItemLevelInfo: string expected, got " .. type(link), 2)
			end
			return linkField(link, "ilvl")
		end,
		GetItemNameByID = function(id)
			local item = M.items[id]
			return item and item.name or nil -- nil = never seen this session (cold cache)
		end,
		GetItemInfo = function(idOrLink)
			-- (itemName, itemLink, ...) -- only the first two are consumed. A
			-- defineItem()d id models the warm cache; an unknown one returns nothing,
			-- like the live API before the item's data has loaded.
			local id, item = itemFor(idOrLink)
			if not (id and item) then return nil end
			return item.name, M.link(id, "info")
		end,
		RequestLoadItemDataByID = function(arg)
			if type(arg) ~= "string" then
				error("RequestLoadItemDataByID: string expected, got " .. type(arg), 2)
			end
			M.calls.requestLoad[#M.calls.requestLoad + 1] = arg
		end,
	}

	local function quality(link, field, api)
		if type(link) ~= "string" then
			error(api .. ": string expected, got " .. type(link), 3)
		end
		return linkField(link, field)
	end
	_G.C_TradeSkillUI = {
		GetItemCraftedQualityByItemInfo = function(link)
			return quality(link, "crafted", "GetItemCraftedQualityByItemInfo")
		end,
		GetItemReagentQualityByItemInfo = function(link)
			return quality(link, "reagent", "GetItemReagentQualityByItemInfo")
		end,
	}

	_G.C_TooltipInfo = {
		GetBagItem = function(bagID, slot)
			M.calls.bagTip = M.calls.bagTip + 1
			local c = M.containers[bagID]
			local s = c and c.stacks[slot]
			return s and { lines = tipLinesFor(s) } or nil
		end,
		GetInventoryItem = function(_, slot)
			M.calls.invTip = M.calls.invTip + 1
			local s = M.equipped[slot]
			return s and { lines = tipLinesFor(s) } or nil
		end,
		GetInboxItem = function(i, j)
			M.calls.inboxTip = M.calls.inboxTip + 1
			local msg = M.inbox[i]
			local a = msg and msg.attachments and msg.attachments[j]
			return a and { lines = tipLinesFor(a) } or nil
		end,
		GetSendMailItem = function(slot)
			M.calls.sendTip = M.calls.sendTip + 1
			local s = M.sendSlots[slot]
			return s and { lines = tipLinesFor(s) } or nil
		end,
	}

	_G.GetInventoryItemID = function(_, slot)
		local s = M.equipped[slot]
		return s and s.id or nil
	end
	_G.GetInventoryItemLink = function(_, slot)
		local s = M.equipped[slot]
		return (s and s.link ~= false) and s.link or nil
	end

	_G.C_Bank = {
		CanUseBank = function(bankType) return M.bankUsable[bankType] or false end,
		FetchPurchasedBankTabIDs = function(bankType) return M.bankTabs[bankType] end,
	}

	-- Owned-auction fixtures use the wiki's OwnedAuctionInfo shape directly:
	-- { itemKey = { itemID, itemLevel }, quantity, itemLink, status } -- so the tests
	-- encode the exact field mapping ScanAuctions relies on.
	_G.C_AuctionHouse = {
		QueryOwnedAuctions = function() M.calls.queryOwned = M.calls.queryOwned + 1 end,
		GetOwnedAuctions = function() return M.ownedAuctions end,
		HasFullOwnedAuctionResults = function() return M.fullOwnedResults end,
		-- AuctionInfo for one browsable listing ({ itemKey, itemLink } -- no quantity
		-- field in the live struct); fixtures fill M.auctionsByID.
		GetAuctionInfoByID = function(id) return M.auctionsByID[id] end,
		-- Purchase/cancel entry points exist only so the production hooksecurefunc
		-- post-hooks have something to wrap; tests drive a flow by calling them the way
		-- Blizzard's UI would, then firing the finalization events.
		StartCommoditiesPurchase = function() end,
		ConfirmCommoditiesPurchase = function() end,
		CancelCommoditiesPurchase = function() end,
		PlaceBid = function() end,
		CancelAuction = function() end,
	}

	-- Mail. The stubs encode the exact return shapes the scan relies on -- notably
	-- GetInboxNumItems' (downloaded, serverTotal) pair and GetInboxItem's quality
	-- return hardcoded to -1 (the documented live bug): any production code that ever
	-- READS the quality gets a nonsense value and fails a test.
	_G.CheckInbox = function() M.calls.checkInbox = M.calls.checkInbox + 1 end
	_G.C_Mail = {
		CanCheckInbox = function() return M.canCheckInbox, M.canCheckInbox and 0 or 30 end,
	}
	_G.GetInboxNumItems = function()
		return #M.inbox, M.inboxTotal or #M.inbox
	end
	_G.GetInboxHeaderInfo = function(i)
		local msg = M.inbox[i]
		if not msg then return nil end
		local n = msg.attachments and #msg.attachments or 0
		-- (packageIcon, stationeryIcon, sender, subject, money, CODAmount, daysLeft,
		--  itemCount-or-nil, wasRead, wasReturned, textCreated, canReply, isGM)
		return nil, nil, msg.sender, msg.subject or "", msg.money or 0, msg.cod or 0,
			msg.daysLeft or 30, n > 0 and n or nil
	end
	_G.GetInboxItem = function(i, j)
		local msg = M.inbox[i]
		local a = msg and msg.attachments and msg.attachments[j]
		if not a then return nil end
		local item = M.items[a.id]
		-- (name, itemID, texture, count, quality, canUse) -- quality is ALWAYS -1
		return (item and item.name) or ("Item" .. tostring(a.id)), a.id, nil, a.count, -1, 1
	end
	_G.GetInboxItemLink = function(i, j)
		local msg = M.inbox[i]
		local a = msg and msg.attachments and msg.attachments[j]
		return (a and a.link ~= false) and a.link or nil
	end
	_G.GetSendMailItem = function(slot)
		local s = M.sendSlots[slot]
		if not s then return nil end
		local item = M.items[s.id]
		-- (name, itemID, texture, count, quality) -- no canUse, same bugged quality
		return (item and item.name) or ("Item" .. tostring(s.id)), s.id, nil, s.count, -1
	end
	_G.GetSendMailItemLink = function(slot)
		local s = M.sendSlots[slot]
		return (s and s.link ~= false) and s.link or nil
	end
	_G.SendMail = function()
		-- The live client's behavior here is the design's open question; the knob models
		-- the hostile answer (slots already cleared when post-hooks run).
		if M.sendSlotsClearOnSend then M.sendSlots = {} end
	end
	-- Both live signatures: hooksecurefunc(name, fn) wraps _G[name],
	-- hooksecurefunc(tbl, name, fn) wraps tbl[name] (the C_AuctionHouse hooks).
	_G.hooksecurefunc = function(a, b, c)
		local tbl, name, fn
		if type(a) == "table" then
			tbl, name, fn = a, b, c
		else
			tbl, name, fn = _G, a, b
		end
		local orig = tbl[name]
		tbl[name] = function(...)
			orig(...)
			fn(...)
		end
	end

	_G.C_AddOns = {
		GetAddOnMetadata = function(_, field) return M.metadata[field] end,
	}

	-- Deterministic atlas markup so tier icons are assertable as readable substrings.
	_G.CreateAtlasMarkup = function(atlas) return "{" .. atlas .. "}" end

	_G.TooltipDataProcessor = {
		AddTooltipPostCall = function(dataType, fn)
			M.itemPostCallType = dataType
			M.itemPostCall = fn
		end,
	}
	_G.TooltipUtil = {
		GetDisplayedItem = function() return nil, M.displayedLink end,
	}

	-- The four frames Tooltip.lua freezes into WATCHED_TOOLTIPS at load. Deliberately
	-- plain tables, not magic widgets: RefreshData must be nil-able so a test can model
	-- a frame without the mixin (a magic __index would silently resurrect it).
	for _, name in ipairs({ "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2" }) do
		local t = { shown = false, refreshCount = 0 }
		t.IsShown = function(self) return self.shown end
		t.RefreshData = function(self) self.refreshCount = self.refreshCount + 1 end
		M.watched[name] = t
		_G[name] = t
	end

	-- Settings API: explicit stubs where the shape matters (multi-returns, captures the
	-- tests assert on), magic widgets for the rest of the panel build.
	_G.Settings = setmetatable({
		VarType = { Boolean = "boolean" },
		RegisterVerticalLayoutCategory = function()
			return Widget(), Widget() -- category, layout (magic __index can't multi-return)
		end,
		RegisterAddOnSetting = function(_, variable, key, tbl, varType, _, default)
			M.settingsRegistry[variable] = { key = key, tbl = tbl, varType = varType, default = default }
			return Widget()
		end,
		RegisterProxySetting = function(_, variable, varType, _, default, getter, setter)
			M.settingsRegistry[variable] =
				{ proxy = true, varType = varType, default = default, getter = getter, setter = setter }
			return Widget()
		end,
		SetOnValueChangedCallback = function(variable, cb)
			M.valueChangedCallbacks[variable] = cb
		end,
		-- Explicit so tests can assert the slash handler opened the panel: the magic
		-- __index would otherwise absorb this into an unrecordable no-op.
		OpenToCategory = function()
			M.calls.openToCategory = M.calls.openToCategory + 1
		end,
	}, widgetMeta)
	_G.CreateSettingsListSectionHeaderInitializer = function(text) return { header = text } end
	_G.MinimalSliderWithSteppersMixin = { Label = { Right = 4 } }
	_G.StaticPopupDialogs = {}
	_G.SlashCmdList = {}
	-- Chat sink: text only (the live signature's trailing r,g,b args are unused).
	_G.DEFAULT_CHAT_FRAME = {
		AddMessage = function(_, text) M.chatLines[#M.chatLines + 1] = text end,
	}
	_G.StaticPopup_Show = function() end
	_G.GameTooltip_Hide = function() end
	_G.DELETE = "Delete"
	_G.CANCEL = "Cancel"

	_G.ExactItemCountDB = nil
end

return M
