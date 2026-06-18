-- Luacheck config for Exact Item Count (WoW retail addon).
-- WoW's interpreter is Lua 5.1-based; only globals listed below are legal —
-- anything else flagged as "undefined" is a typo'd API name or a leaked local.
std = "lua51"

-- Handler signatures (OnEvent, OnClick, dialog callbacks) carry args we don't always use.
unused_args = false

-- `local addonName, ns = ...` is the standard addon-vararg idiom in every file,
-- even where only `ns` is used.
ignore = { "211/addonName" }

-- Globals this addon owns or appends to.
globals = {
	"ExactItemCountDB",       -- SavedVariable (## SavedVariables in the TOC)
	"SLASH_EXACTITEMCOUNT1",
	"SLASH_EXACTITEMCOUNT2",
	"SlashCmdList",           -- field added, never replaced
	"StaticPopupDialogs",     -- field added, never replaced
}

-- WoW API surface in use (read-only).
read_globals = {
	-- C_ namespaces
	"C_AddOns",
	"C_Bank",
	"C_Container",
	"C_Item",
	"C_TooltipInfo",
	"C_TradeSkillUI",

	-- frames, mixins, UI utilities
	"CreateAtlasMarkup",
	"CreateFrame",
	"CreateSettingsListSectionHeaderInitializer",
	"Enum",
	"GameTooltip",
	"GameTooltip_Hide",
	"ItemLocation",
	"MinimalSliderWithSteppersMixin",
	"Settings",
	"StaticPopup_Show",
	"TooltipDataProcessor",
	"TooltipUtil",

	-- key state
	"IsAltKeyDown",
	"IsControlKeyDown",
	"IsShiftKeyDown",

	-- character / realm
	"GetNormalizedRealmName",
	"UnitName",

	-- equipped inventory (legacy globals, still current)
	"GetInventoryItemID",
	"GetInventoryItemLink",

	-- Blizzard global strings and misc
	"CANCEL",
	"DELETE",
	"INVSLOT_FIRST_EQUIPPED",
	"INVSLOT_LAST_EQUIPPED",
	"ITEM_UPGRADE_TOOLTIP_FORMAT_STRING",
	"time",                   -- WoW's global time(), not os.time
}
