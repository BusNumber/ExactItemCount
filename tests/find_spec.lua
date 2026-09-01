-- tests/find_spec.lua -- the /eic slash routing and the `find` chat search.
local T = ...
local test, assertTrue, assertEq = T.test, T.assertTrue, T.assertEq
local loadAddon, H = T.loadAddon, T.H

-- ---- slash routing (guards written before the find feature: /eic's panel
-- ---- behavior must survive the dispatcher gaining a msg argument)

test("slash_empty_msg_opens_panel", function()
	local _, S = loadAddon({ noPEW = true })
	_G.SlashCmdList.EXACTITEMCOUNT("")
	assertEq(S.calls.openToCategory, 1)
	assertEq(#S.chatLines, 0)
end)

test("slash_whitespace_msg_opens_panel", function()
	local _, S = loadAddon({ noPEW = true })
	_G.SlashCmdList.EXACTITEMCOUNT("   ")
	assertEq(S.calls.openToCategory, 1)
	assertEq(#S.chatLines, 0)
end)

test("slash_nil_msg_tolerated", function()
	local _, S = loadAddon({ noPEW = true })
	_G.SlashCmdList.EXACTITEMCOUNT(nil)
	assertEq(S.calls.openToCategory, 1)
end)

test("slash_before_init_no_panel_no_error", function()
	-- Before ADDON_LOADED there is no categoryID (and no settings/db); the handler
	-- must no-op rather than error.
	local _, S = loadAddon({ noAddonLoaded = true, noPEW = true })
	_G.SlashCmdList.EXACTITEMCOUNT("")
	assertEq(S.calls.openToCategory, 0)
end)

-- ---- the find search itself
--
-- Shared world (fixture names follow the helper discipline: no parens/em dashes/
-- trailing digits). "Stormhide" exists as a two-tier reagent (501 silver / 502 gold),
-- a plain cross-expansion namesake (503), and gear ("Stormhide Boots", 504);
-- "Amberleaf Bloom" (505) is a linkless commodity listing owned nowhere; Ghost is
-- hidden by default and owns/lists Stormhide too, so every base expectation doubles as
-- a hiddenChars exclusion check.
local function findWorld(S, opts)
	opts = opts or {}
	S.defineItem(501, { name = "Stormhide", reagent = 1 })
	S.defineItem(502, { name = "Stormhide", reagent = 2 })
	S.defineItem(503, { name = "Stormhide" })
	S.defineItem(504, { name = "Stormhide Boots", equipLoc = "INVTYPE_FEET" })
	S.defineItem(505, { name = "Amberleaf Bloom" })
	S.defineItem(506, { name = "Ghostcap" })
	local chars = {
		[H.OWN] = H.charStore({
			bags = H.dbItems({
				{ id = 501, count = 4, link = S.link(501, "b") },
				{ id = 504, count = 1, ilvl = 610, link = S.link(504, "g", { ilvl = 610 }) },
			}),
			bank = H.dbItems({ { id = 502, count = 2, link = S.link(502, "k") } }),
			auctions = H.dbItems({
				{ id = 502, count = 5, link = S.link(502, "a") },
				{ id = 505, count = 12 }, -- commodity listing: no link stored
			}),
		}),
		["Liara-RealmA"] = H.charStore({
			bags = H.dbItems({ { id = 501, count = 3, link = S.link(501, "L") } }),
			auctions = H.dbItems({ { id = 501, count = 2, link = S.link(501, "La") } }),
		}),
		["Nix-RealmA"] = H.charStore({
			bags = H.dbItems({ { id = 503, count = 6, link = S.link(503, "n") } }),
			bank = opts.coldSibling and H.dbItems({
				-- An undefined id: its tier can't resolve, only the bracket name can.
				{ id = 599, count = 7, link = S.link(599, "c", { name = "Stormhide" }) },
			}) or nil,
		}),
		["Ghost-RealmA"] = H.charStore({
			bags = H.dbItems({
				{ id = 501, count = 50, link = S.link(501, "G") },
				{ id = 506, count = 9, link = S.link(506, "Gc") },
			}),
			auctions = H.dbItems({ { id = 501, count = 99, link = S.link(501, "Ga") } }),
		}),
	}
	if opts.extraAlt then
		chars["Tess-RealmA"] = H.charStore({
			bags = H.dbItems({ { id = 501, count = 1, link = S.link(501, "T") } }),
		})
	end
	local settings = opts.settings or {}
	if settings.hiddenChars == nil then
		settings.hiddenChars = { ["Ghost-RealmA"] = true }
	end
	return H.db({ chars = chars, settings = settings })
end

local function boot(opts)
	return loadAddon({ noPEW = true, db = function(S) return findWorld(S, opts) end })
end

local function run(msg)
	_G.SlashCmdList.EXACTITEMCOUNT(msg)
end

local function chat(S)
	local out = {}
	for i, raw in ipairs(S.chatLines) do
		out[i] = H.stripChat(raw)
	end
	return out
end

local DASH = " \226\128\148 "
local DOT = " \194\183 "

test("find_link_query_exact_line", function()
	local _, S = boot()
	run("find " .. S.link(501, "b"))
	assertEq(chat(S), {
		"Exact Item Count" .. DASH .. "[Stormhide]: 9 (bags 4" .. DOT .. "bank 2"
			.. DOT .. "Liara 3)" .. DASH .. "on auction: 7 (yours 5" .. DOT .. "Liara 2)",
	})
	H.assertFindLine(S.chatLines[1])
end)

test("find_link_query_joins_quality_siblings", function()
	-- Whichever sibling is linked, the answer is the name-group combined total.
	local _, S = boot()
	run("find " .. S.link(502, "k"))
	assertTrue(chat(S)[1]:find("[Stormhide]: 9 (", 1, true), "gold-tier link answers 9")
end)

test("find_link_query_zero_total_still_answers", function()
	local _, S = boot()
	S.defineItem(777, { name = "Void Charm" })
	run("find " .. S.link(777, "x"))
	assertEq(chat(S), { "Exact Item Count" .. DASH .. "[Void Charm]: 0" })
end)

test("find_link_wrapped_in_color_codes_still_parses", function()
	local _, S = boot()
	run("find |cffffffff" .. S.link(501, "b") .. "|r")
	assertTrue(chat(S)[1]:find("[Stormhide]: 9 (", 1, true), "link inside color codes resolves")
	assertEq(#S.chatLines, 1)
end)

test("find_unresolvable_link_falls_back_to_name_search", function()
	local _, S = boot()
	run("find |Hitem:junk|h[Stormhide]|h") -- unregistered link: no itemID resolves
	local lines = chat(S)
	assertEq(lines[1], "Exact Item Count" .. DASH .. '3 matches for "Stormhide":')
	assertEq(#lines, 4) -- degraded to a bracket-name search, not a dead end
end)

test("find_text_substring_groups_and_namesakes", function()
	-- The one-line-per-match contract over the rich world: the tier group prints ONCE
	-- (combined, with its auction tail), the plain namesake and the gear separately;
	-- exact name matches lead, then total desc; Ghost (hidden) is in nothing.
	local _, S = boot()
	run("find stormhide")
	assertEq(chat(S), {
		"Exact Item Count" .. DASH .. '3 matches for "stormhide":',
		"  [Stormhide]: 9 (bags 4" .. DOT .. "bank 2" .. DOT .. "Liara 3)"
			.. DASH .. "on auction: 7 (yours 5" .. DOT .. "Liara 2)",
		"  [Stormhide]: 6 (Nix 6)",
		"  [Stormhide Boots]: 1 (bags 1)",
	})
	assertEq(H.assertFindOutput(S.chatLines), 3)
end)

test("find_text_case_insensitive_keyword_and_query", function()
	local _, S = boot()
	run("FIND STORMH")
	assertEq(H.assertFindOutput(S.chatLines), 3)
	assertEq(S.calls.openToCategory, 0)
end)

test("find_text_magic_chars_literal", function()
	local _, S = boot()
	run("find %s(") -- Lua pattern magic must be inert (plain substring match)
	assertEq(chat(S),
		{ "Exact Item Count" .. DASH .. 'no matches for "%s(" in your scanned items.' })
end)

test("find_cold_sibling_prints_own_plain_line", function()
	-- 599 shares the name but its tier can't resolve: the all-or-nothing rule keeps it
	-- out of the group total, it prints its own disjoint line, and its item data gets
	-- a cache-priming request (the tooltip path's self-heal, shared).
	local _, S = boot({ coldSibling = true })
	run("find stormhide")
	local lines = chat(S)
	assertEq(#lines, 5)
	assertEq(lines[2]:find("[Stormhide]: 9 (", 1, true), 3)
	assertEq(lines[3], "  [Stormhide]: 7 (Nix 7)")
	assertEq(lines[4], "  [Stormhide]: 6 (Nix 6)")
	assertEq(H.assertFindOutput(S.chatLines), 4)
	local primed = false
	for _, link in ipairs(S.calls.requestLoad) do
		if link:find("item:599", 1, true) then primed = true end
	end
	assertTrue(primed, "the rejected cold sibling's item data is requested")
end)

test("find_min_length_rejected", function()
	local _, S = boot()
	run("find a")
	assertEq(chat(S), { "Exact Item Count" .. DASH
		.. "type at least 2 characters, or shift-click an item link." })
	assertEq(S.calls.openToCategory, 0)
end)

test("find_pipe_only_query_rejected_after_sanitizing", function()
	local _, S = boot()
	run("find |cff00ff00|r") -- sanitizes to "", falls under the length floor
	assertTrue(chat(S)[1]:find("type at least", 1, true))
end)

test("find_zero_matches_message", function()
	local _, S = boot()
	run("find zzz")
	assertEq(chat(S),
		{ "Exact Item Count" .. DASH .. 'no matches for "zzz" in your scanned items.' })
end)

test("find_exact_match_first_then_total_desc_name_asc", function()
	local _, S = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(601, { name = "Beta Widget" })
		S.defineItem(602, { name = "Alpha Widget" })
		S.defineItem(603, { name = "Gamma Widget" })
		S.defineItem(604, { name = "Widget" })
		return H.db({ chars = { [H.OWN] = H.charStore({ bags = H.dbItems({
			{ id = 601, count = 2, link = S.link(601, "b") },
			{ id = 602, count = 2, link = S.link(602, "b") },
			{ id = 603, count = 5, link = S.link(603, "b") },
			{ id = 604, count = 1, link = S.link(604, "b") },
		}) }) } })
	end })
	run("find widget")
	assertEq(chat(S), {
		"Exact Item Count" .. DASH .. '4 matches for "widget":',
		"  [Widget]: 1 (bags 1)", -- exact name beats every larger stash
		"  [Gamma Widget]: 5 (bags 5)",
		"  [Alpha Widget]: 2 (bags 2)", -- count tie: name ascending
		"  [Beta Widget]: 2 (bags 2)",
	})
end)

test("find_cap_and_more_tail", function()
	local _, S = loadAddon({ noPEW = true, db = function(S)
		local stacks = {}
		for i = 1, 12 do
			local id = 610 + i
			S.defineItem(id, { name = "Bolt " .. string.char(64 + i) })
			stacks[i] = { id = id, count = i, link = S.link(id, "b") }
		end
		return H.db({ chars = { [H.OWN] = H.charStore({ bags = H.dbItems(stacks) }) } })
	end })
	run("find bolt")
	local lines = chat(S)
	assertEq(#lines, 12) -- header + 10 results + tail
	assertEq(lines[1], "Exact Item Count" .. DASH .. '12 matches for "bolt":')
	assertEq(lines[2], "  [Bolt L]: 12 (bags 12)")
	assertEq(lines[12], "  \226\128\166and 2 more" .. DASH .. "try a more specific name.")
	assertEq(H.assertFindOutput(S.chatLines), 12)
end)

test("find_tristates_ignored", function()
	-- Every source set to "never" (and the modifier key up): find still counts them
	-- all -- the display tri-states gate tooltips, not an explicit search. Identical
	-- output to the unfiltered world.
	local _, S = boot({ settings = {
		bankMode = "never", warbandMode = "never", equippedMode = "never",
		mailMode = "never", altsMode = "never", auctionsMode = "never",
		altAuctions = false,
	} })
	run("find stormhide")
	local lines = chat(S)
	assertEq(lines[2], "  [Stormhide]: 9 (bags 4" .. DOT .. "bank 2" .. DOT .. "Liara 3)"
		.. DASH .. "on auction: 7 (yours 5" .. DOT .. "Liara 2)")
	assertEq(H.assertFindOutput(S.chatLines), 3)
end)

test("find_hidden_chars_excluded_and_included", function()
	-- The one gate find honors: the Characters-page eye. Unhidden, Ghost's stacks and
	-- listings join every number and a hidden-only item becomes findable.
	local _, S = boot({ settings = { hiddenChars = {} } })
	run("find stormhide")
	assertEq(chat(S)[2], "  [Stormhide]: 59 (bags 4" .. DOT .. "bank 2"
		.. DOT .. "Ghost 50" .. DOT .. "Liara 3)"
		.. DASH .. "on auction: 106 (yours 5" .. DOT .. "Ghost 99" .. DOT .. "Liara 2)")
	assertEq(H.assertFindOutput(S.chatLines), 3)
	S.chatLines = {}
	run("find ghostcap")
	assertEq(chat(S)[2], "  [Ghostcap]: 9 (Ghost 9)")

	local _, S2 = boot() -- hidden again: gone from matches entirely
	run("find ghostcap")
	assertTrue(chat(S2)[1]:find("no matches", 1, true))
end)

test("find_auction_only_item_found_by_text", function()
	-- Owned nowhere, 100% listed, linkless: still findable (the id universe includes
	-- the auction stores), rendered as an owned 0 with a non-zero listings tail and a
	-- plain-name label (no stored link to print).
	local _, S = boot()
	run("find amberleaf")
	assertEq(chat(S), {
		"Exact Item Count" .. DASH .. '1 match for "amberleaf":',
		"  Amberleaf Bloom: 0" .. DASH .. "on auction: 12 (yours 12)",
	})
	assertEq(H.assertFindOutput(S.chatLines), 1)
end)

test("find_pipe_escapes_sanitized_in_echo", function()
	local _, S = boot()
	run("find a|b|c") -- surviving pipes are stripped wholesale before echoing
	local raw = S.chatLines[1]
	assertTrue(H.strip(raw):find('"abc"', 1, true), "echo shows the sanitized query")
	assertTrue(not H.strip(raw):find("|", 1, true), "no stray pipe survives into chat")
end)

test("find_altsdetail_always_all_in_chat", function()
	-- Settings that would collapse the tooltip suffix (top-1) must not touch chat:
	-- find names every alt.
	local _, S = boot({ extraAlt = true, settings = {
		altsDetail = "topn", altsTopN = 1, hiddenChars = {},
	} })
	run("find stormhide")
	local line = chat(S)[2]
	for _, token in ipairs({ "Ghost 50", "Liara 3", "Tess 1" }) do
		assertTrue(line:find(token, 1, true), token .. " named in the chat suffix")
	end
	assertTrue(not line:find("alts", 1, true), "no collapsed alts token in chat")
	assertEq(H.assertFindOutput(S.chatLines), 3)
end)

test("find_bare_find_prints_usage", function()
	local _, S = boot()
	run("find")
	assertEq(#S.chatLines, 1)
	assertTrue(chat(S)[1]:find("/eic find <name or item link>", 1, true))
	assertEq(S.calls.openToCategory, 0)
end)

test("find_unknown_subcommand_prints_usage", function()
	local _, S = boot()
	run("wat")
	assertTrue(chat(S)[1]:find("/eic find <name or item link>", 1, true))
	assertEq(S.calls.openToCategory, 0)
end)

test("find_nil_settings_pre_init_works", function()
	-- Before ADDON_LOADED: no db, no settings. The search must degrade to an honest
	-- no-matches answer, never an error.
	local _, S = loadAddon({ noAddonLoaded = true, noPEW = true })
	run("find xyz")
	assertTrue(chat(S)[1]:find("no matches", 1, true))
	assertEq(S.calls.openToCategory, 0)
end)
