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
	M.displayedLink = nil     -- TooltipUtil.GetDisplayedItem fallback result
	M.calls = { bagTip = 0, invTip = 0, requestLoad = {} }
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

-- def: { name=, equipLoc= (default "INVTYPE_NON_EQUIP_IGNORE"), ilvl=, crafted=, reagent= }
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
		TooltipDataType = { Item = 17 },
	}
	_G.INVSLOT_FIRST_EQUIPPED = 1
	_G.INVSLOT_LAST_EQUIPPED = 19
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
			-- (itemID, itemType, itemSubType, itemEquipLoc, ...)
			return id, nil, nil, (item and item.equipLoc) or "INVTYPE_NON_EQUIP_IGNORE"
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
	}, widgetMeta)
	_G.CreateSettingsListSectionHeaderInitializer = function(text) return { header = text } end
	_G.MinimalSliderWithSteppersMixin = { Label = { Right = 4 } }
	_G.StaticPopupDialogs = {}
	_G.SlashCmdList = {}
	_G.StaticPopup_Show = function() end
	_G.GameTooltip_Hide = function() end
	_G.DELETE = "Delete"
	_G.CANCEL = "Cancel"

	_G.ExactItemCountDB = nil
end

return M
