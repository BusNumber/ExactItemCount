-- tests/locale_spec.lua -- the string table (Locale.lua + Locales/) and the promise it
-- makes: every word the addon displays is read from ns.L, so a translation is one more
-- file, and which language is shown follows one rule (an explicit choice, then the game
-- client's language, then English).
--
-- Nothing here pins English wording (the other specs assert the rendered text; the
-- panel's wording is deliberately unasserted). These are structural checks: the keys
-- the code reads are the keys the base locale defines, a translated table reaches every
-- display surface with the invariants intact, the language choice resolves and persists
-- as designed, and a translation file is well-formed.
local T = ...
local test, assertTrue, assertEq = T.test, T.assertTrue, T.assertEq
local loadAddon, H, stubs = T.loadAddon, T.H, T.stubs

local MECHANISM = "Locale.lua"
local BASE_LOCALE = "Locales/enUS.lua"
local DOT = " \194\183 "
local DASH = " \226\128\148 "

-- The one name that is deliberately the same in every language.
local BRAND = "Exact Item Count"

-- The client languages a translation file may register (GetLocale() values).
local CLIENT_CODES = {
	enUS = true, deDE = true, esES = true, esMX = true, frFR = true, itIT = true,
	koKR = true, ptBR = true, ruRU = true, zhCN = true, zhTW = true,
}

local function readFile(path)
	local f = assert(io.open(T.root .. path, "rb"))
	local src = f:read("*a")
	f:close()
	return src
end

-- Source text with its "--" line comments blanked out (string contents are left
-- alone), so a key that is only mentioned in a comment doesn't count as read.
local function stripComments(src)
	local out = {}
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		local quote, i, cut = nil, 1, nil
		while i <= #line do
			local c = line:sub(i, i)
			if quote then
				if c == "\\" then
					i = i + 1
				elseif c == quote then
					quote = nil
				end
			elseif c == '"' or c == "'" then
				quote = c
			elseif c == "-" and line:sub(i + 1, i + 1) == "-" then
				cut = i
				break
			end
			i = i + 1
		end
		out[#out + 1] = cut and line:sub(1, cut - 1) or line
	end
	return table.concat(out, "\n")
end

local function copy(t)
	local out = {}
	for key, value in pairs(t) do out[key] = value end
	return out
end

local function sortedKeys(t)
	local keys = {}
	for key in pairs(t) do keys[#keys + 1] = key end
	table.sort(keys)
	return keys
end

-- A value's placeholders as { [argument index] = "s" | "d" }: plain %s / %d number
-- themselves left to right, the game's positional form (%2$d) names its own index.
-- Anything else following a % (the %% literal aside) comes back as a second result --
-- it would either break string.format or silently eat an argument.
local function placeholders(value)
	local sig, nextIndex, bad = {}, 1, nil
	for spec in value:gsub("%%%%", ""):gmatch("%%[^%a]*%a?") do
		local index, conv = spec:match("^%%(%d+)%$([sd])$")
		if not index then
			conv = spec:match("^%%([sd])$")
			index = nextIndex
			nextIndex = nextIndex + 1
		end
		if conv then
			sig[tonumber(index)] = conv
		else
			bad = bad or spec
		end
	end
	return sig, bad
end

-- What is wrong with a translation `overlay` (the keys a Locales/xxXX.lua assigned)
-- measured against the base table: a sorted list of problems, empty when it is fine.
local function checkTranslation(base, overlay)
	local problems = {}
	for _, key in ipairs(sortedKeys(overlay)) do
		local value = overlay[key]
		if base[key] == nil then
			problems[#problems + 1] = key .. ": not a key of the base locale"
		elseif type(value) ~= "string" or value == "" then
			problems[#problems + 1] = key .. ": must be a non-empty string"
		else
			local got, bad = placeholders(value)
			if bad then
				problems[#problems + 1] = key .. ": unsupported placeholder '" .. bad .. "'"
			elseif not T.deepEqual(got, (placeholders(base[key]))) then
				problems[#problems + 1] = key .. ": placeholders differ from the base locale"
			end
		end
	end
	return problems
end

-- The stand-in translation: every ASCII letter becomes "#", placeholders survive in
-- place. Any letter that still shows up on screen afterwards did not come from the
-- string table.
local function pseudo(value)
	local parts, pos = {}, 1
	while true do
		local s, e = value:find("%%[sd]", pos)
		parts[#parts + 1] = (value:sub(pos, (s or 0) - 1):gsub("%a", "#"))
		if not s then break end
		parts[#parts + 1] = value:sub(s, e)
		pos = e + 1
	end
	return table.concat(parts)
end

-- A loadAddon opts.locale hook that registers the stand-in under `code`, exactly where
-- a real Locales/<code>.lua would load. P receives the translated strings; `used`
-- (optional) records every key the addon ever reads from this translation.
local function standInLocale(code, P, used)
	return function(ns)
		for key, value in pairs(ns.locales.enUS) do P[key] = pseudo(value) end
		setmetatable(ns.NewLocale(code), { __index = function(_, key)
			if used then used[key] = true end
			return P[key]
		end })
	end
end

local function assertNoEnglish(text, where)
	local s = H.stripChat(text):gsub("{.-}", ""):gsub(BRAND, "") -- colors, links, atlas art
	local leak = s:match("%a[%a ']*")
	if leak then
		T.fail(where .. ": \"" .. leak .. "\" is displayed without going through the string table")
	end
end

-- One /eic message; returns the lines it printed, colors and link scaffolding stripped.
local function slash(S, msg)
	local from = #S.chatLines
	_G.SlashCmdList.EXACTITEMCOUNT(msg)
	local out = {}
	for i = from + 1, #S.chatLines do out[#out + 1] = H.stripChat(S.chatLines[i]) end
	return out
end

-- ---------------------------------------------------------------- the base table

test("locale_files_load_first", function()
	-- Every other file reads ns.L, and an explicit locale choice is applied on top of
	-- whatever registered -- both need the mechanism, then the locale files, up front.
	local files = T.addonFiles
	assertEq(files[1], MECHANISM, "the mechanism loads first")
	assertEq(files[2], BASE_LOCALE, "then the base locale")
	local i = 3
	while files[i] and files[i]:find("^Locales/") do i = i + 1 end
	for j = i, #files do
		assertTrue(not files[j]:find("^Locales/"),
			files[j] .. " must load with the other locale files, before Core.lua")
	end
end)

test("locale_keys_defined_and_used", function()
	local ns = loadAddon({ noPEW = true })
	local base = ns.locales.enUS
	local referenced = {}
	for _, file in ipairs(T.addonFiles) do
		if not file:find("^Locales/") then
			local src = stripComments(readFile(file))
			for key in src:gmatch("%f[%w_]L%.([%u][%u%d_]*)") do
				referenced[key] = file
			end
			-- A computed lookup would hide its key from this scan.
			assertTrue(not src:find("%f[%w_]L%["), file .. " must read the string table as L.KEY")
		end
	end
	for _, key in ipairs(sortedKeys(referenced)) do
		assertTrue(base[key] ~= nil,
			referenced[key] .. " reads L." .. key .. ", which " .. BASE_LOCALE .. " never defines")
	end
	for _, key in ipairs(sortedKeys(base)) do
		assertTrue(referenced[key], BASE_LOCALE .. " defines " .. key .. ", which no file reads")
	end
	-- Display strings are presentation: the data layer never touches the table.
	assertTrue(not stripComments(readFile("Core.lua")):find("ns%.L%f[^%w_]"),
		"Core.lua must not use ns.L")
end)

test("locale_base_values_wellformed", function()
	local ns = loadAddon({ noPEW = true })
	local count = 0
	for key, value in pairs(ns.locales.enUS) do
		count = count + 1
		assertTrue(type(key) == "string" and key:find("^[%u][%u%d_]*$") ~= nil,
			"key is not UPPER_SNAKE: " .. tostring(key))
		assertTrue(type(value) == "string" and value ~= "", key .. " must be a non-empty string")
		local _, bad = placeholders(value)
		assertTrue(not bad, key .. " has an unsupported placeholder")
		-- The base locale is the one that runs headless, and stock Lua's string.format
		-- has no positional arguments -- those are for translations, in the game client.
		assertTrue(not value:find("%%%d+%$"), key .. ": the base locale uses plain %s / %d only")
	end
	assertTrue(count > 0, "the base locale defines no strings")
end)

test("locale_missing_key_reads_back_as_its_name", function()
	local ns = loadAddon({ noPEW = true })
	-- A typo'd key must render as visible text, never throw inside a tooltip post-call...
	assertEq(ns.L.NO_SUCH_KEY, "NO_SUCH_KEY")
	assertEq(ns.L.NO_SUCH_KEY:format(3), "NO_SUCH_KEY")
	-- ...and the fallback never writes the miss into any table.
	assertEq(rawget(ns.L, "NO_SUCH_KEY"), nil)
	assertEq(ns.locales.enUS.NO_SUCH_KEY, nil)
end)

-- ---------------------------------------------------------------- which language shows

-- A one-item world to watch a tooltip follow the language: Acorn, bags 2.
local function acornDB(S)
	S.defineItem(301, { name = "Acorn" })
	return H.db({ chars = { [H.OWN] = H.charStore({
		bags = H.dbItems({ { id = 301, count = 2, link = S.link(301, "a") } }),
	}) } })
end

test("locale_priority_explicit_then_client_then_english", function()
	-- Priority 3: no translation for this client's language -> English.
	local ns = loadAddon({ noPEW = true, db = acornDB, setup = function(S) S.locale = "xxXX" end })
	local function lead()
		return H.plainLines(H.hover({ id = 301 }))[2]
	end
	assertEq(ns.GetLocaleCode(), "enUS")
	assertEq(lead(), "Total items owned: 2 (bags 2)")

	-- Priority 2: the client's language, as soon as a translation for it registers. A
	-- key it leaves out stays English, one string at a time.
	local mine = ns.NewLocale("xxXX")
	mine.LEAD_TOTAL = "Gesamt"
	assertEq(ns.GetLocaleCode(), "xxXX")
	assertEq(lead(), "Gesamt: 2 (bags 2)", "the tooltip reads the table at render time")
	mine.SUFFIX_BAGS = "Taschen %d"
	assertEq(lead(), "Gesamt: 2 (Taschen 2)")
	assertEq(ns.L.LEAD_AUCTION, "On auction", "a key the translation leaves out stays English")

	-- Another language's translation is inert on this client...
	local other = ns.NewLocale("yyYY")
	other.LEAD_TOTAL = "Total"
	assertEq(ns.L.LEAD_TOTAL, "Gesamt")

	-- ...until it is chosen explicitly. Priority 1 beats the client's language.
	assertTrue(ns.SetLocale("yyYY"))
	assertEq(ns.GetLocaleCode(), "yyYY")
	assertEq(lead(), "Total: 2 (bags 2)")
	assertTrue(ns.SetLocale("enUS"), "English can be chosen explicitly on a translated client")
	assertEq(lead(), "Total items owned: 2 (bags 2)")
	assertEq(ns.SetLocale("zzZZ"), false, "an unregistered code is refused")
	assertEq(ns.GetLocaleCode(), "enUS", "... and changes nothing")

	-- Clearing the choice returns to the client's language.
	assertTrue(ns.SetLocale(nil))
	assertEq(ns.GetLocaleCode(), "xxXX")
	-- Every registered code is listed, sorted (whatever real translations ship besides).
	local codes = ns.GetLocaleCodes()
	local listed = {}
	for i, code in ipairs(codes) do
		listed[code] = true
		assertTrue(i == 1 or codes[i - 1] < code, "codes are sorted")
	end
	assertTrue(listed.enUS and listed.xxXX and listed.yyYY, "enUS and both stand-ins are listed")
end)

test("locale_codes_can_share_a_translation", function()
	local ns = loadAddon({ noPEW = true })
	local shared = ns.NewLocale("xxXX", "yyYY")
	shared.LEAD_TOTAL = "Total"
	assertTrue(ns.locales.xxXX == ns.locales.yyYY, "one table serves both client codes")
	assertTrue(ns.SetLocale("yyYY"))
	assertEq(ns.L.LEAD_TOTAL, "Total")
end)

test("locale_listeners_follow_the_active_locale", function()
	-- ns.OnLocale keeps a string handed to the game at file load (the delete prompt) in
	-- step with an explicit choice applied later.
	local ns = loadAddon({ noPEW = true })
	local seen = {}
	ns.OnLocale(function() seen[#seen + 1] = ns.L.LEAD_TOTAL end)
	assertEq(seen, { "Total items owned" }, "runs once right away")
	local other = ns.NewLocale("xxXX")
	other.LEAD_TOTAL = "Gesamt"
	other.POPUP_DELETE_CHAR = "L\195\182schen: %s?"
	assertEq(#seen, 1, "another client's translation registering changes nothing")
	ns.SetLocale("xxXX")
	assertEq(seen[2], "Gesamt", "runs again when the active locale changes")
	assertEq(_G.StaticPopupDialogs.EXACTITEMCOUNT_DELETE_CHAR.text, "L\195\182schen: %s?",
		"the delete prompt follows the language")
	ns.SetLocale("xxXX")
	assertEq(#seen, 2, "... and not when it stays the same")
	ns.SetLocale(nil)
	assertEq(seen[3], "Total items owned")
end)

test("locale_saved_choice_stale_or_garbage_is_dropped", function()
	local ns = loadAddon({ noPEW = true, db = H.db({ settings = { locale = "zzZZ" } }) })
	assertEq(ns.GetLocaleCode(), "enUS", "an unregistered code falls back to the client, then English")
	assertEq(ns.GetSettings().locale, nil, "... and is cleared")
	assertEq(ns.L.LEAD_TOTAL, "Total items owned")
	for _, junk in ipairs({ 42, true, "" }) do
		local ns2 = loadAddon({ noPEW = true, db = H.db({ settings = { locale = junk } }) })
		assertEq(ns2.GetSettings().locale, nil, "junk is cleared: " .. tostring(junk))
		assertEq(ns2.GetLocaleCode(), "enUS")
	end
	local ns3 = loadAddon({ noPEW = true })
	assertEq(ns3.GetSettings().locale, nil, "nothing is stored unless a choice is made")
end)

test("locale_slash_command", function()
	local P = {}
	local ns, S = loadAddon({ noPEW = true, locale = standInLocale("xxXX", P) })
	local s = ns.GetSettings()
	-- Every registered code, then "default" (built from the registry, so the test holds
	-- whichever real translations ship).
	local choices = table.concat(ns.GetLocaleCodes(), " | ") .. " | default"
	assertTrue(choices:find("enUS", 1, true) and choices:find("xxXX", 1, true), choices)

	-- Bare: lists what is registered, what is showing, and what is set.
	assertEq(slash(S, "locale"),
		{ BRAND .. DASH .. "locale: " .. choices .. "  (showing enUS, set to default)" })

	-- A code (any letter case) is saved, NOT applied: the panel's labels are registered
	-- once, so the switch happens through a /reload.
	assertEq(slash(S, "LOCALE XXxx"), { BRAND .. DASH .. "locale: xxXX. /reload to apply." })
	assertEq(s.locale, "xxXX")
	assertEq(ns.GetLocaleCode(), "enUS", "nothing switches until the reload")
	assertEq(slash(S, "locale"),
		{ BRAND .. DASH .. "locale: " .. choices .. "  (showing enUS, set to xxXX)" })

	-- An unknown code is refused and leaves the saved choice alone; whatever was typed
	-- is echoed pipe-free, like a find query.
	assertEq(slash(S, "locale zzZZ"),
		{ BRAND .. DASH .. "locale: no translation 'zzZZ'. Available: " .. choices })
	slash(S, "locale |cffff0000zz|r|Hitem:1|h")
	assertEq(S.chatLines[#S.chatLines]:match("'(.-)'"), "zz", "no escape survives the echo")
	assertEq(s.locale, "xxXX")

	-- The next session: the saved choice wins over the (English) client.
	local saved = _G.ExactItemCountDB
	local P2 = {}
	local ns2, S2 = loadAddon({ noPEW = true, db = saved, locale = standInLocale("xxXX", P2) })
	assertEq(S2.locale, "enUS")
	assertEq(ns2.GetLocaleCode(), "xxXX")
	assertEq(ns2.L.LEAD_TOTAL, P2.LEAD_TOTAL)
	-- The command's own answers stay English whatever is showing: it is the way back.
	assertEq(slash(S2, "locale"),
		{ BRAND .. DASH .. "locale: " .. choices .. "  (showing xxXX, set to xxXX)" })
	-- English can be forced the same way...
	assertEq(slash(S2, "locale enus"), { BRAND .. DASH .. "locale: enUS. /reload to apply." })
	assertEq(ns2.GetSettings().locale, "enUS")
	-- ...and "default" clears the choice: back to the client's language, then English.
	assertEq(slash(S2, "locale default"),
		{ BRAND .. DASH .. "locale: default (the game client's language). /reload to apply." })
	assertEq(ns2.GetSettings().locale, nil)
	assertEq(ns2.GetLocaleCode(), "xxXX", "still showing the old choice until the reload")

	local ns3 = loadAddon({ noPEW = true, db = saved, locale = standInLocale("xxXX", {}) })
	assertEq(ns3.GetLocaleCode(), "enUS", "after the reload: the client's language")

	-- It never opens the panel, and the other sub-commands are untouched.
	assertEq(S.calls.openToCategory + S2.calls.openToCategory, 0)
	assertTrue(slash(S, "find")[1]:find("/eic find <name or item link>", 1, true), "usage still prints")
end)

test("locale_slash_command_before_settings_exist", function()
	-- No ADDON_LOADED yet: nothing can be saved, so every form just lists.
	local ns, S = loadAddon({ noAddonLoaded = true, noPEW = true })
	local want = { BRAND .. DASH .. "locale: " .. table.concat(ns.GetLocaleCodes(), " | ")
		.. " | default  (showing enUS, set to default)" }
	assertEq(slash(S, "locale"), want)
	assertEq(slash(S, "locale enUS"), want)
end)

-- ---------------------------------------------------------------- a translated client

-- A world whose DATA is letter-free -- item names, character names, the realm, even the
-- upgrade track are digits -- so the only letters a render could contain are the
-- addon's own. Own character 11-22: crafted chest 101 spread over every location (bags
-- 1 + bank 2 + equipped 1 + mail 1, warband 1, four alts 3/2/1/1 = 13, plus listings:
-- own 1, alt 2), track gear 102, plain gear 103, a two-tier reagent 201/202, plain item
-- 301, recipe 310 for product 311, and twelve "40xx" items to overflow a search. The
-- saved settings carry an explicit language choice: xxXX, on an English client.
local NOW = 1000000
local links

local function pseudoWorld(S)
	links = {}
	S.defineItem(101, { name = "1001", equipLoc = "INVTYPE_CHEST" })
	links.r5 = S.link(101, "r5", { ilvl = 658, crafted = 5 })
	links.r4 = S.link(101, "r4", { ilvl = 645, crafted = 4 })
	links.r3 = S.link(101, "r3", { ilvl = 630, crafted = 3 }) -- owned nowhere
	S.defineItem(102, { name = "1002", equipLoc = "INVTYPE_HEAD" })
	links.track = S.link(102, "t", { ilvl = 610 })
	S.defineItem(103, { name = "1003", equipLoc = "INVTYPE_FEET" })
	links.plainGear = S.link(103, "p", { ilvl = 500 })
	S.defineItem(201, { name = "2001", reagent = 1 })
	S.defineItem(202, { name = "2001", reagent = 2 })
	links.silver, links.gold = S.link(201, "s"), S.link(202, "g")
	S.defineItem(301, { name = "3001" })
	links.plain = S.link(301, "a")
	S.defineItem(310, { name = "3100", classID = 9 })
	S.defineItem(311, { name = "3110" })
	links.product = S.link(311, "p")

	local bags = {
		{ id = 101, count = 1, ilvl = 658, link = links.r5 },
		{ id = 102, count = 1, ilvl = 610, link = links.track,
			track = { name = "5", step = 2, max = 6 } },
		{ id = 103, count = 1, ilvl = 500, link = links.plainGear },
		{ id = 201, count = 4, link = links.silver },
		{ id = 301, count = 1, link = links.plain },
		{ id = 310, count = 1, link = S.link(310, "r") },
		{ id = 311, count = 2, link = links.product },
	}
	for i = 1, 12 do
		local id = 400 + i
		S.defineItem(id, { name = ("40%02d"):format(i) })
		bags[#bags + 1] = { id = id, count = 1, link = S.link(id, "x") }
	end

	local r4 = function(count) return { id = 101, count = count, ilvl = 645, link = links.r4 } end
	local own = H.charStore({
		bags = H.dbItems(bags),
		bank = H.dbItems({ r4(2) }),
		equipped = H.dbItems({ { id = 101, count = 1, ilvl = 658, link = links.r5 } }),
		mail = H.dbItems({ r4(1) }),
		auctions = H.dbItems({ { id = 101, count = 1, ilvl = 658, link = links.r5 } }),
	})
	-- One snapshot per scan-age wording: seconds, minutes, hours; the auctions snapshot
	-- keeps the fixture default (days old) and the alts below have never seen a bank.
	own.bags.scannedAt = NOW - 30
	own.bank.scannedAt = NOW - 600
	own.mail.scannedAt = NOW - 7200

	return H.db({
		chars = {
			["11-22"] = own,
			["33-22"] = H.charStore({ bags = H.dbItems({ r4(3) }), auctions = H.dbItems({ r4(2) }) }),
			["44-22"] = H.charStore({ bags = H.dbItems({ r4(2) }) }),
			["55-22"] = H.charStore({ bags = H.dbItems({ r4(1) }) }),
			["66-22"] = H.charStore({ bags = H.dbItems({ r4(1) }) }),
		},
		warband = H.dbItems({ r4(1), { id = 202, count = 8, link = links.gold } }),
		settings = { altAuctions = true, locale = "xxXX" },
	})
end

test("locale_translation_reaches_every_displayed_string", function()
	-- The stand-in registers exactly where a Locales/xxXX.lua would, and is shown because
	-- the saved settings choose it -- on an English client, so this is priority 1 at work,
	-- applied before the options panel is built.
	local P, used = {}, {}
	local ns, S = loadAddon({
		noPEW = true,
		setup = function(s)
			s.charName, s.realm = "11", "22"
			s.setTime(NOW)
			s.metadata = { Version = "9.9.9", ["X-Donate"] = "https://1.2/3" }
		end,
		db = pseudoWorld,
		locale = standInLocale("xxXX", P, used),
	})
	local s = ns.GetSettings()
	assertEq(S.locale, "enUS")
	assertEq(ns.GetLocaleCode(), "xxXX", "the saved choice wins over the client's language")
	assertEq(s.locale, "xxXX", "the choice stays until changed")

	-- ---- tooltips: every line translated, every invariant intact
	local function hover(data, where)
		local tip = H.hover(data)
		assertTrue(#tip.lines > 1, where .. ": no section rendered")
		for _, raw in ipairs(tip.lines) do assertNoEnglish(raw, where) end
		H.assertSectionInvariant(tip)
		return H.plainLines(tip)
	end

	local chest = { id = 101, hyperlink = links.r3 }
	local lines = hover(chest, "crafted gear")
	-- The whole pipeline under the foreign vocabulary, word for word: translated lead,
	-- every own-location token, the two named alts and the collapsed tail.
	assertEq(lines[2], P.LEAD_TOTAL .. ": 13 (" .. table.concat({
		P.SUFFIX_BAGS:format(1), P.SUFFIX_BANK:format(2), P.SUFFIX_WARBAND:format(1),
		P.SUFFIX_EQUIPPED:format(1), P.SUFFIX_MAIL:format(1),
		P.SUFFIX_ALT:format("33", 3), P.SUFFIX_ALT:format("44", 2),
		P.SUFFIX_ALTS_MORE:format(2, 2),
	}, DOT) .. ")")
	assertEq(lines[#lines - 2], P.LEAD_AUCTION .. ": 3 (" .. P.SUFFIX_YOURS:format(1) .. DOT
		.. P.SUFFIX_ALT:format("33", 2) .. ")")

	s.bankMerge = "merged"
	assertTrue(hover(chest, "merged banks")[2]:find(P.SUFFIX_BANKS:format(3), 1, true),
		"the merged-banks token is translated")
	s.bankMerge = "separate"
	s.altsDetail = "total"
	assertTrue(hover(chest, "alts total")[2]:find(P.SUFFIX_ALTS_TOTAL:format(7), 1, true),
		"the alts-total token is translated")
	s.altsDetail = "topn"

	hover({ id = 102, hyperlink = links.track }, "track gear")
	assertEq(hover({ id = 103, hyperlink = links.plainGear }, "plain gear")[3],
		"  " .. P.ROW_ILVL:format(500) .. ": 1 (" .. P.SUFFIX_BAGS:format(1) .. ")")
	hover({ id = 201, hyperlink = links.silver }, "quality good")
	hover({ id = 301, hyperlink = links.plain }, "plain item")
	local recipe = hover({ id = 310, hyperlink = links.product }, "recipe")
	assertEq(recipe[3], P.LEAD_CRAFTED .. ": 2 (" .. P.SUFFIX_BAGS:format(2) .. ")")

	-- ---- /eic find: usage, both guardrails, one match, the overflow tail, an exact ask
	local function say(msg)
		local from = #S.chatLines
		local out = slash(S, msg)
		assertTrue(#out > 0, "/eic " .. msg .. " printed nothing")
		for i = from + 1, #S.chatLines do
			assertNoEnglish(S.chatLines[i], "/eic " .. msg)
			H.assertFindLine(S.chatLines[i])
		end
		return out
	end
	say("find")
	say("find 9")
	say("find 99")
	say("find 3001")
	assertEq(#say("find 40"), 12, "twelve matches print a header, ten lines and the tail")
	assertEq(say("find " .. links.r4)[1], BRAND .. DASH .. "[1001]: 13 ("
		.. table.concat({
			P.SUFFIX_BAGS:format(1), P.SUFFIX_BANK:format(2), P.SUFFIX_WARBAND:format(1),
			P.SUFFIX_EQUIPPED:format(1), P.SUFFIX_MAIL:format(1),
			P.SUFFIX_ALT:format("33", 3), P.SUFFIX_ALT:format("44", 2),
			P.SUFFIX_ALT:format("55", 1), P.SUFFIX_ALT:format("66", 1),
		}, DOT) .. ")" .. DASH .. P.CHAT_ON_AUCTION .. ": 3 (" .. P.SUFFIX_YOURS:format(1)
		.. DOT .. P.SUFFIX_ALT:format("33", 2) .. ")")

	-- ---- the options panel and Characters page: open every dropdown under every
	-- modifier, show the page, hover and click every button (each eye toggles, each
	-- delete raises its prompt), then hover and repaint once more in the new state.
	for _, mod in ipairs({ "SHIFT", "ALT", "CTRL" }) do
		s.modifier = mod
		for _, getter in ipairs(S.optionGetters) do getter() end
	end
	local function fireAll(script)
		local frames = {}
		for i, f in ipairs(S.frames) do frames[i] = f end -- handlers create more frames
		for _, f in ipairs(frames) do
			if f.scripts[script] then f.scripts[script](f) end
		end
	end
	fireAll("OnShow")
	fireAll("OnEnter")
	fireAll("OnClick")
	fireAll("OnEnter")
	fireAll("OnShow")
	assertTrue(#S.ui > 100, "the panel battery captured the panel's strings")
	for _, text in ipairs(S.ui) do assertNoEnglish(text, "options panel") end
	-- The one string handed to the game at file load, before the choice applied.
	assertEq(_G.StaticPopupDialogs.EXACTITEMCOUNT_DELETE_CHAR.text, P.POPUP_DELETE_CHAR)

	-- ---- and the three batteries together touched the whole table: a key they never
	-- read is a string this test cannot vouch for.
	for _, key in ipairs(sortedKeys(P)) do
		assertTrue(used[key], key .. " was never read: extend this test to display it")
	end
end)

-- ---------------------------------------------------------------- translation files

test("locale_translation_check_catches_mistakes", function()
	local base = { BAGS = "bags %d", ALT = "%s %d", PLAIN = "plain", FOUND = '%d matches for "%s":' }
	-- Reworded, reordered through the positional form, and using the game's plural
	-- escape: all fine.
	assertEq(checkTranslation(base, {
		BAGS = "%d Taschen",
		ALT = "%2$d \195\151 %1$s",
		PLAIN = "schlicht",
		FOUND = '%d |4Treffer:Treffer; f\195\188r "%s":',
	}), {})
	assertEq(checkTranslation(base, { BAGZ = "Taschen %d" }), { "BAGZ: not a key of the base locale" })
	assertEq(#checkTranslation(base, { BAGS = "Taschen" }), 1, "a dropped placeholder")
	assertEq(#checkTranslation(base, { BAGS = "Taschen %s" }), 1, "a placeholder of the wrong kind")
	assertEq(#checkTranslation(base, { ALT = "%1$s %1$s" }), 1, "an argument used twice, one lost")
	assertEq(#checkTranslation(base, { PLAIN = "100% schlicht" }), 1, "a stray percent sign")
	assertEq(#checkTranslation(base, { PLAIN = "" }), 1, "an empty value")
	assertEq(#checkTranslation(base, { PLAIN = true }), 1, "a non-string value")
end)

test("locale_translation_files_valid", function()
	-- Every Locales/xxXX.lua the TOC lists besides the base: it registers the client
	-- language its file name promises and assigns only base keys, placeholders intact.
	-- (No translation ships yet, so today this loop has nothing to visit -- the first one
	-- added to the TOC is checked from then on.)
	for _, file in ipairs(T.addonFiles) do
		local code = file:match("^Locales/(%w+)%.lua$")
		if code and file ~= BASE_LOCALE then
			assertTrue(CLIENT_CODES[code], file .. ": '" .. code .. "' is not a client language code")
			stubs.install()
			local ns = {}
			assert(loadfile(T.root .. MECHANISM))("ExactItemCount", ns)
			assert(loadfile(T.root .. BASE_LOCALE))("ExactItemCount", ns)
			local base = copy(ns.locales.enUS)
			assert(loadfile(T.root .. file))("ExactItemCount", ns)
			local overlay = ns.locales[code]
			assertTrue(type(overlay) == "table" and next(overlay) ~= nil,
				file .. " must register '" .. code .. "' and translate something")
			assertTrue(overlay ~= ns.locales.enUS and T.deepEqual(ns.locales.enUS, base),
				file .. " must not write into the base locale")
			for registered in pairs(ns.locales) do
				assertTrue(CLIENT_CODES[registered],
					file .. " registers '" .. tostring(registered) .. "', which is not a client language code")
			end
			assertEq(checkTranslation(base, overlay), {}, file)
		end
	end
end)
