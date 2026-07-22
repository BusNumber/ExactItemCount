local addonName, ns = ...

-- Settings layer: the Options -> AddOns panel plus the seams the other layers read.
-- Every setting is display-only -- scans and the cached DB never change shape with them,
-- so the data stays complete and any choice is instantly reversible. Values are
-- account-wide, in ExactItemCountDB.settings (additive to the schema: DB_VERSION stays 1,
-- missing keys are default-filled at load).

-- Defaults double as the type source for Settings.RegisterAddOnSetting -- Lua type()
-- returns exactly the Settings.VarType strings. Tri-state semantics everywhere:
-- "always" / "modifier" (only while the configured key is held) / "never".
-- The current character's bags have no setting: they are always counted -- the one
-- source whose absence would make every tooltip lie about what's in hand.
local DEFAULTS = {
	bankMode    = "always",    -- "always" | "modifier" | "never"
	warbandMode = "always",
	equippedMode = "always",   -- the current character's worn gear/profession tools
	altsMode    = "always",
	altEquipped = true,        -- count other characters' worn gear too (folds into their total)
	auctionsMode = "always",   -- the "On auction" sub-section (never part of the owned total)
	altAuctions = false,       -- include other characters' listings in it. Off by default:
	                           -- an alt's listings are the stalest data the addon holds
	                           -- (they sell while offline and only heal when that alt next
	                           -- visits the AH), so showing them is an informed opt-in.
	modifier    = "ALT",       -- "SHIFT" | "ALT" | "CTRL". Alt, not Shift: Shift doubles as
	                           -- the game's item-compare key, so a Shift-gated source would
	                           -- flip every time gear is compared. Only fresh installs get
	                           -- this -- defaults fill missing keys, a stored choice stays.
	suffixMode  = "always",    -- "always" | "modifier": the per-location suffix
	rowsMode    = "always",    -- "always" | "modifier": the quality/ilvl breakdown rows
	recipeProductMode = "always", -- "always" | "modifier" | "never": on recipe tooltips,
	                           -- the "Crafted items" sub-section counting the product
	altsDetail  = "topn",      -- "topn" | "all" | "total"
	altsTopN    = 2,           -- alts named before the rest collapse (used by "topn")
	altsExpandKey = false,     -- modifier held: list every alt, whatever altsDetail says
	bankMerge   = "separate",  -- "separate" | "modifier" (merged unless held) | "merged"
	hideZero    = false,       -- drop the whole section when the total is 0
}

-- Allowed values per enum setting; anything else in a hand-edited SavedVariables file
-- degrades to the default instead of surprising the display code.
local TRI_STATE = { always = true, modifier = true, never = true }
local ENUMS = {
	bankMode    = TRI_STATE,
	warbandMode = TRI_STATE,
	equippedMode = TRI_STATE,
	altsMode    = TRI_STATE,
	auctionsMode = TRI_STATE,
	modifier    = { SHIFT = true, ALT = true, CTRL = true },
	suffixMode  = { always = true, modifier = true },
	rowsMode    = { always = true, modifier = true },
	recipeProductMode = TRI_STATE,
	altsDetail  = { topn = true, all = true, total = true },
	bankMerge   = { separate = true, modifier = true, merged = true },
}

local db, settings, categoryID
local RebuildList -- characters-panel refresh; the delete popup needs it before it exists

-- The display layer reads every setting through this. nil until InitSettings has run;
-- callers fall back to the pre-settings default behavior on nil.
function ns.GetSettings()
	return settings
end

local MOD_LABELS = { SHIFT = "Shift", ALT = "Alt", CTRL = "Ctrl" }

local function ModLabel()
	return MOD_LABELS[settings.modifier] or "Shift"
end

-- Dropdown option getters run again every time a dropdown opens, so the "[modifier]"
-- wordings below self-heal after the key is changed. The CLOSED control's label keeps the
-- old key name until its dropdown is next opened -- known, accepted staleness.
local function TriStateOptions()
	local c = Settings.CreateControlTextContainer()
	c:Add("always", "Always show")
	c:Add("modifier", ("Only while %s is held"):format(ModLabel()))
	c:Add("never", "Never")
	return c:GetData()
end

local function TwoStateOptions()
	local c = Settings.CreateControlTextContainer()
	c:Add("always", "Always show")
	c:Add("modifier", ("Only while %s is held"):format(ModLabel()))
	return c:GetData()
end

local function ModifierOptions()
	local c = Settings.CreateControlTextContainer()
	c:Add("SHIFT", "Shift")
	c:Add("ALT", "Alt")
	c:Add("CTRL", "Ctrl")
	return c:GetData()
end

local function AltsDetailOptions()
	local c = Settings.CreateControlTextContainer()
	c:Add("topn", "Top N by count, merge the rest")
	c:Add("all", "All characters separately")
	c:Add("total", "Only the total across characters")
	return c:GetData()
end

local function BankMergeOptions()
	local c = Settings.CreateControlTextContainer()
	c:Add("separate", "Always separately")
	c:Add("modifier", ("Merged unless %s is held"):format(ModLabel()))
	c:Add("merged", "Always merged")
	return c:GetData()
end

-- "2h ago" / "5d ago" -- coarse m/h/d staleness is enough to judge a hide or a delete.
local function Ago(ts)
	if not ts then return "never" end
	local d = time() - ts
	if d < 60 then return "just now" end
	if d < 3600 then return math.floor(d / 60) .. "m ago" end
	if d < 86400 then return math.floor(d / 3600) .. "h ago" end
	return math.floor(d / 86400) .. "d ago"
end

StaticPopupDialogs["EXACTITEMCOUNT_DELETE_CHAR"] = {
	text = "Delete stored item counts for %s?",
	button1 = DELETE,
	button2 = CANCEL,
	OnAccept = function(dialog, data)
		ns.DeleteChar(data)
		if RebuildList then RebuildList() end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

-- The Characters page: one row per scanned character -- full Name-Realm key (the tooltip
-- merges same-named alts across realms; this list must not), scan age, an eye toggling
-- the account-wide hidden flag, and a delete button (never on the current character).
-- The list rebuilds wholesale on show and after every toggle/delete; the roster is tiny
-- and static while the panel is up, so no scroll-virtualization machinery.
local ROW_HEIGHT = 26

local function BuildCharactersPanel(category)
	local frame = CreateFrame("Frame")
	frame:Hide()

	local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 10, -10)
	title:SetText("Characters")

	local hint = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	hint:SetJustifyH("LEFT")
	hint:SetText("The eye hides a character's items from the counts your other characters"
		.. " see. A character always counts its own bags and bank, and its data stays"
		.. " cached. Deleting removes the stored data; a deleted character is scanned"
		.. " again the next time it logs in with this addon.")
	frame:SetScript("OnSizeChanged", function(_, width)
		hint:SetWidth(width - 20)
	end)

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
	scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 10)

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)
	scroll:SetScript("OnSizeChanged", function(_, width)
		content:SetWidth(width)
	end)

	local rows = {}

	local function AcquireRow(i)
		local row = rows[i]
		if row then return row end
		row = CreateFrame("Frame", nil, content)
		rows[i] = row
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
		row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

		row.del = CreateFrame("Button", nil, row)
		row.del:SetSize(16, 16)
		row.del:SetPoint("RIGHT", row, "RIGHT", -8, 0)
		row.del:SetNormalAtlas("common-icon-redx")
		row.del:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
		row.del:GetHighlightTexture():SetBlendMode("ADD")
		row.del:SetScript("OnClick", function()
			StaticPopup_Show("EXACTITEMCOUNT_DELETE_CHAR", row.key, nil, row.key)
		end)
		row.del:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Delete this character's cached data")
			GameTooltip:Show()
		end)
		row.del:SetScript("OnLeave", GameTooltip_Hide)

		row.eye = CreateFrame("Button", nil, row)
		row.eye:SetSize(20, 20)
		row.eye:SetPoint("RIGHT", row, "RIGHT", -34, 0)
		row.eye:SetNormalAtlas("socialqueuing-icon-eye")
		row.eye:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
		row.eye:GetHighlightTexture():SetBlendMode("ADD")
		-- The eye lives on the current character's row too: the flag is account-wide, so
		-- it controls whether THIS character shows up in your other characters' tooltips
		-- (its own session reads its bags/bank through the bags/bank sources, not as an alt).
		-- Shared between OnEnter and OnClick: a click happens with the cursor on the
		-- button, so the open tooltip repaints to the new state instead of waiting for
		-- the next hover.
		local function ShowEyeTip()
			GameTooltip:SetOwner(row.eye, "ANCHOR_RIGHT")
			if settings.hiddenChars[row.key] then
				GameTooltip:SetText("Hidden from other characters")
				GameTooltip:AddLine("This character's items are excluded from the counts"
					.. " your other characters see. Click to include them again.", 1, 1, 1, true)
			else
				GameTooltip:SetText("Shown on other characters")
				GameTooltip:AddLine("This character's items count in the tooltips your other"
					.. " characters see. (A character always counts its own bags and bank.)"
					.. " Click to hide.", 1, 1, 1, true)
			end
			GameTooltip:Show()
		end
		row.eye:SetScript("OnClick", function()
			if settings.hiddenChars[row.key] then
				settings.hiddenChars[row.key] = nil
			else
				settings.hiddenChars[row.key] = true
			end
			RebuildList()
			ShowEyeTip()
		end)
		row.eye:SetScript("OnEnter", ShowEyeTip)
		row.eye:SetScript("OnLeave", GameTooltip_Hide)

		row.age = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		row.age:SetPoint("RIGHT", row.eye, "LEFT", -10, 0)
		row.age:SetJustifyH("RIGHT")

		row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		row.name:SetPoint("LEFT", 4, 0)
		row.name:SetPoint("RIGHT", row.age, "LEFT", -8, 0) -- truncate before overlapping
		row.name:SetJustifyH("LEFT")

		return row
	end

	RebuildList = function()
		local me = ns.GetCharKey()
		local keys = {}
		for key in pairs(db.chars) do
			keys[#keys + 1] = key
		end
		table.sort(keys, function(a, b)
			if (a == me) ~= (b == me) then return a == me end -- current character first
			return a < b
		end)

		for i, key in ipairs(keys) do
			local row = AcquireRow(i)
			local char = db.chars[key]
			row.key = key
			local hidden = settings.hiddenChars[key] and true or false
			-- A hidden character's name grays out (and the "(current)" tag dims with it),
			-- so the disabled rows read at a glance, not only from the eye's tint.
			row.name:SetFontObject(hidden and "GameFontDisable" or "GameFontHighlight")
			row.name:SetText(key .. (key == me
				and (hidden and " |cff4e7a4e(current)|r" or " |cff00ff00(current)|r") or ""))
			row.age:SetText("bags " .. Ago(char.bags and char.bags.scannedAt)
				.. " \194\183 bank " .. Ago(char.bank and char.bank.scannedAt)
				.. " \194\183 auctions " .. Ago(char.auctions and char.auctions.scannedAt))
			row.eye:GetNormalTexture():SetDesaturated(hidden)
			row.eye:SetAlpha(hidden and 0.4 or 1)
			-- No delete for the current character; with the own key unresolved (panel open
			-- before PLAYER_ENTERING_WORLD), offer none rather than risk self-deletion.
			row.del:SetShown(me ~= nil and key ~= me)
			row:Show()
		end
		for i = #keys + 1, #rows do
			rows[i]:Hide()
		end
		content:SetHeight(math.max(#keys * ROW_HEIGHT, 1))
	end

	frame:SetScript("OnShow", RebuildList)

	-- The parent's RegisterAddOnCategory covers the subcategory; the settings panel
	-- anchors and sizes the canvas frame itself.
	Settings.RegisterCanvasLayoutSubcategory(category, frame, "Characters")
end

local function RegisterPanel()
	local category, layout = Settings.RegisterVerticalLayoutCategory("Exact Item Count")
	categoryID = category:GetID()

	-- Binds settings[key] to a panel control. RegisterAddOnSetting reads and writes that
	-- exact table, so `settings` (== db.settings) must never be replaced after this.
	local function Register(key, name)
		return Settings.RegisterAddOnSetting(category, addonName .. "_" .. key, key,
			settings, type(DEFAULTS[key]), name, DEFAULTS[key])
	end

	-- No Bags entry: the current character's bags are always counted.
	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Locations"))
	Settings.CreateDropdown(category, Register("bankMode", "Bank"), TriStateOptions,
		"Items in this character's bank (snapshot taken while the bank is open).")
	Settings.CreateDropdown(category, Register("warbandMode", "Warband bank"), TriStateOptions,
		"Items in the account-wide warband bank (snapshot taken while the bank is open).")
	local equippedInit = Settings.CreateDropdown(category, Register("equippedMode", "Equipped items"),
		TriStateOptions,
		"Items currently equipped on this character (gear plus profession tools and accessories).")
	local altEquippedInit = Settings.CreateCheckbox(category, Register("altEquipped", "Include in count for alts"),
		"Also count gear worn by your other characters, folded into each one's total."
			.. " Uncheck to count only their bags and bank.")
	-- Nest under the Equipped dropdown purely for the sub-item margin. The predicate gates
	-- enabled state; this option governs alts (not this character's own equipped tri-state),
	-- so it stays enabled regardless -- hence a constant true.
	altEquippedInit:SetParentInitializer(equippedInit, function() return true end)
	Settings.CreateDropdown(category, Register("altsMode", "Other characters"), TriStateOptions,
		"Items on every other scanned character, bags and bank combined."
			.. " Manage individual characters on the Characters page.")
	local auctionsInit = Settings.CreateDropdown(category, Register("auctionsMode", "On auction"),
		TriStateOptions,
		"Items you have listed on the auction house (snapshot taken while the auction"
			.. " house is open), shown as their own \"On auction\" line. Listings are"
			.. " never added to the owned total.")
	local altAuctionsInit = Settings.CreateCheckbox(category,
		Register("altAuctions", "Include alts' auctions"),
		"Also show items your other characters have listed, by name. Their listings are"
			.. " a snapshot from each character's last auction house visit, so they can"
			.. " be stale. Follows the Other characters setting above.")
	-- Nested under the On auction dropdown for the sub-item margin; unlike the equipped
	-- checkbox above (which governs a different scope than its parent), this one is a
	-- strict sub-gate -- with the sub-section on Never it can change nothing -- so the
	-- predicate grays it out then, the way the Top-N slider follows its detail mode.
	altAuctionsInit:SetParentInitializer(auctionsInit, function()
		return settings.auctionsMode ~= "never"
	end)

	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Compact tooltip"))
	Settings.CreateDropdown(category, Register("modifier", "Modifier key"), ModifierOptions,
		"The key the \"only while held\" options wait for. Note that Shift is also the"
			.. " game's compare-items key, so it flips while comparing gear.")
	Settings.CreateDropdown(category, Register("suffixMode", "Location suffix"), TwoStateOptions,
		"The dimmed per-location split after each count, like (bags 2 \194\183 bank 1).")
	Settings.CreateDropdown(category, Register("rowsMode", "Quality & item level rows"), TwoStateOptions,
		"The per-rank and per-item-level breakdown rows under the total.")
	Settings.CreateDropdown(category, Register("recipeProductMode", "Crafted item on recipes"),
		TriStateOptions,
		"For recipes, also show the count of the crafted items the recipe is for.")
	local altsDetailInit = Settings.CreateDropdown(category,
		Register("altsDetail", "Other characters detail"), AltsDetailOptions,
		"How other characters appear in the location suffix.")
	do
		-- A proxy rather than a plain binding: with "All characters separately" selected
		-- the box must read as checked (and sit disabled, via the parent predicate below)
		-- while the user's own choice survives underneath for the other modes. The parent
		-- link only re-evaluates enabled state when altsDetail changes; NotifyUpdate is
		-- what repaints the displayed check. The name says "key", not the key's name:
		-- checkbox labels are registered once and can't self-heal the way the dropdowns'
		-- option getters do, so a baked-in "Shift" would go stale on a modifier change.
		local expandSetting = Settings.RegisterProxySetting(category,
			addonName .. "_altsExpandKey", Settings.VarType.Boolean,
			"List all while key is held",
			DEFAULTS.altsExpandKey,
			function() return settings.altsDetail == "all" or settings.altsExpandKey end,
			function(value) settings.altsExpandKey = value end)
		local expandInit = Settings.CreateCheckbox(category, expandSetting,
			"While the modifier key (set above) is held, every character is listed"
				.. " separately in the suffix, whatever the detail mode above.")
		expandInit:SetParentInitializer(altsDetailInit,
			function() return settings.altsDetail ~= "all" end)
		Settings.SetOnValueChangedCallback(addonName .. "_altsDetail", function()
			expandSetting:NotifyUpdate()
		end)

		local sliderOptions = Settings.CreateSliderOptions(1, 10, 1)
		sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
		local sliderInit = Settings.CreateSlider(category,
			Register("altsTopN", "Named characters (top N)"),
			sliderOptions, "With \"Top N by count\" above: how many characters are named"
				.. " before the rest merge into one \"+K alts\" entry.")
		sliderInit:SetParentInitializer(altsDetailInit,
			function() return settings.altsDetail == "topn" end)
	end
	Settings.CreateDropdown(category, Register("bankMerge", "Bank & warband in the suffix"), BankMergeOptions,
		"Show bank and warband bank as separate suffix entries, or as one combined"
			.. " \"banks\" entry.")
	Settings.CreateCheckbox(category, Register("hideZero", "Hide when total is 0"),
		"Skip the tooltip section entirely for items you own none of.")

	-- Footer: support link and version. The URL lives only in the TOC's X-Donate field
	-- (no field, no line); shown scheme-stripped as plain text -- the game can't open a
	-- browser, and the address is short enough to retype.
	local donate = C_AddOns.GetAddOnMetadata(addonName, "X-Donate")
	if donate then
		layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(
			"Enjoying the addon? Buy me a coffee: " .. donate:gsub("^https?://", "")))
	end
	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(
		"Version " .. (C_AddOns.GetAddOnMetadata(addonName, "Version") or "?")))

	BuildCharactersPanel(category)
	Settings.RegisterAddOnCategory(category)
end

-- Called by Core.lua once the SavedVariable exists (its ADDON_LOADED handler). Fills
-- defaults -- `== nil` checks, never falsy: a persisted `false` must survive -- and
-- discards values an old version or a hand-edit left invalid, then builds the panel.
function ns.InitSettings(database)
	db = database
	local s = database.settings
	if type(s) ~= "table" then
		s = {}
		database.settings = s
	end
	for key, default in pairs(DEFAULTS) do
		local v = s[key]
		if v == nil or type(v) ~= type(default) or (ENUMS[key] and not ENUMS[key][v]) then
			s[key] = default
		end
	end
	-- NaN passes the type check above and would ride through floor/min/max unchanged.
	if s.altsTopN ~= s.altsTopN then s.altsTopN = DEFAULTS.altsTopN end
	s.altsTopN = math.max(1, math.min(10, math.floor(s.altsTopN)))
	if type(s.hiddenChars) ~= "table" then
		s.hiddenChars = {}
	end
	for key in pairs(s.hiddenChars) do
		if not database.chars[key] then
			s.hiddenChars[key] = nil -- the character it hid is gone
		end
	end
	settings = s
	RegisterPanel()
end

SLASH_EXACTITEMCOUNT1 = "/eic"
SLASH_EXACTITEMCOUNT2 = "/exactitemcount"
SlashCmdList.EXACTITEMCOUNT = function()
	if categoryID then
		Settings.OpenToCategory(categoryID)
	end
end
