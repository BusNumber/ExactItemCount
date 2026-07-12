-- tests/settings_spec.lua -- the InitSettings sanitizer and its panel binding.
local T = ...
local test, assertTrue, assertEq = T.test, T.assertTrue, T.assertEq
local loadAddon, H = T.loadAddon, T.H

test("defaults_fill_missing_keys", function()
	local ns = loadAddon({ noPEW = true }) -- fresh install: no saved settings at all
	assertEq(ns.GetSettings(), {
		bankMode = "always",
		warbandMode = "always",
		equippedMode = "always",
		altsMode = "always",
		altEquipped = true,
		modifier = "ALT", -- fresh installs get Alt (Shift doubles as the compare key)
		suffixMode = "always",
		rowsMode = "always",
		altsDetail = "topn",
		altsTopN = 2,
		altsExpandKey = false,
		bankMerge = "separate",
		hideZero = false,
		hiddenChars = {},
	})
end)

test("persisted_falsy_values_survive", function()
	local ns = loadAddon({ noPEW = true, db = H.db({ settings = {
		altEquipped = false, altsExpandKey = false, hideZero = true, bankMode = "never",
	} }) })
	local s = ns.GetSettings()
	assertEq(s.altEquipped, false) -- a persisted false must never be "default-filled" away
	assertEq(s.altsExpandKey, false)
	assertEq(s.hideZero, true)
	assertEq(s.bankMode, "never")
	assertEq(s.warbandMode, "always") -- missing keys still fill in around them
end)

test("existing_modifier_choice_kept", function()
	-- The Alt default only reaches fresh installs; a stored choice must survive.
	local ns = loadAddon({ noPEW = true, db = H.db({ settings = { modifier = "SHIFT" } }) })
	assertEq(ns.GetSettings().modifier, "SHIFT")
end)

test("invalid_values_reset_to_defaults", function()
	local ns = loadAddon({ noPEW = true, db = H.db({ settings = {
		bankMode = "sometimes", -- out of enum
		modifier = "META",
		altsDetail = 42,        -- wrong type
		hideZero = "yes",
		altsTopN = "3",
		bankMerge = false,
	} }) })
	local s = ns.GetSettings()
	assertEq(s.bankMode, "always")
	assertEq(s.modifier, "ALT")
	assertEq(s.altsDetail, "topn")
	assertEq(s.hideZero, false)
	assertEq(s.altsTopN, 2)
	assertEq(s.bankMerge, "separate")
end)

test("altstopn_nan_and_clamp", function()
	local cases = {
		{ 0 / 0, 2 }, -- NaN passes the type check and rides floor/min/max unchanged
		{ 0, 1 },
		{ -5, 1 },
		{ 99, 10 },
		{ 3.7, 3 },
	}
	for _, c in ipairs(cases) do
		local ns = loadAddon({ noPEW = true, db = H.db({ settings = { altsTopN = c[1] } }) })
		assertEq(ns.GetSettings().altsTopN, c[2], "altsTopN = " .. tostring(c[1]))
	end
end)

test("hidden_chars_pruned_and_reset", function()
	local ns = loadAddon({ noPEW = true, db = H.db({
		chars = { ["Liara-RealmA"] = H.charStore({}) },
		settings = { hiddenChars = { ["Liara-RealmA"] = true, ["Ghost-Realm"] = true } },
	}) })
	-- A hidden flag is meaningless without the character's data: pruned, like DeleteChar.
	assertEq(ns.GetSettings().hiddenChars, { ["Liara-RealmA"] = true })
	local ns2 = loadAddon({ noPEW = true, db = H.db({ settings = { hiddenChars = "junk" } }) })
	assertEq(ns2.GetSettings().hiddenChars, {})
end)

test("unknown_settings_keys_ride_along", function()
	-- Additive versioning: a key written by a newer addon version must survive this
	-- version's InitSettings pass untouched.
	local ns = loadAddon({ noPEW = true, db = H.db({ settings = { futureKey = "kept" } }) })
	assertEq(ns.GetSettings().futureKey, "kept")
end)

test("settings_table_identity_binding", function()
	local ns, S = loadAddon({ noPEW = true })
	local s = ns.GetSettings()
	assertTrue(s == _G.ExactItemCountDB.settings, "GetSettings returns db.settings itself")
	-- RegisterAddOnSetting reads/writes its variableTbl directly: every registration must
	-- be handed that exact table, or the panel silently decouples from the SavedVariable.
	local count = 0
	for variable, reg in pairs(S.settingsRegistry) do
		if not reg.proxy then
			count = count + 1
			assertTrue(reg.tbl == s, variable .. " bound to the live settings table")
			assertTrue(s[reg.key] ~= nil, variable .. " key exists after the default fill")
			assertEq(reg.varType, type(reg.default), variable .. " varType matches its default")
		end
	end
	assertEq(count, 12) -- every non-proxy setting registered exactly once
	assertTrue(S.settingsRegistry["ExactItemCount_altsExpandKey"].proxy,
		"the list-all checkbox registers as a proxy setting")
end)

test("slash_and_popup_registered", function()
	loadAddon({ noPEW = true })
	assertEq(_G.SLASH_EXACTITEMCOUNT1, "/eic")
	assertEq(_G.SLASH_EXACTITEMCOUNT2, "/exactitemcount")
	assertTrue(type(_G.SlashCmdList.EXACTITEMCOUNT) == "function")
	_G.SlashCmdList.EXACTITEMCOUNT("") -- must not error
	assertTrue(type(_G.StaticPopupDialogs.EXACTITEMCOUNT_DELETE_CHAR) == "table")
end)
