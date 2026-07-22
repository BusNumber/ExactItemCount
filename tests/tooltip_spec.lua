-- tests/tooltip_spec.lua -- the render path, end to end: fake TooltipData in, recorded
-- AddLine text out, driven through the post-call Tooltip.lua registered at load.
local T = ...
local test, assertTrue, assertEq = T.test, T.assertTrue, T.assertEq
local loadAddon, H = T.loadAddon, T.H

local DOT = " \194\183 " -- the suffix separator (UTF-8 middle dot)

-- Plain-item world: Acorn owned bags 1 + warband 3 + alt Liara 1. Total 5.
local function plainDB(S)
	S.defineItem(301, { name = "Acorn" })
	return H.db({
		chars = {
			[H.OWN] = H.charStore({ bags = H.dbItems({ { id = 301, count = 1 } }) }),
			["Liara-RealmA"] = H.charStore({ bags = H.dbItems({ { id = 301, count = 1 } }) }),
		},
		warband = H.dbItems({ { id = 301, count = 3 } }),
	})
end

-- All five source kinds for one plain item: bags 1 + bank 2 + warband 3 + equipped 4
-- + alts Liara 5, Bram 1. Total 16.
local function suffixDB(S)
	S.defineItem(301, { name = "Acorn" })
	return H.db({
		chars = {
			[H.OWN] = H.charStore({
				bags = H.dbItems({ { id = 301, count = 1 } }),
				bank = H.dbItems({ { id = 301, count = 2 } }),
				equipped = H.dbItems({ { id = 301, count = 4 } }),
			}),
			["Liara-RealmA"] = H.charStore({ bags = H.dbItems({ { id = 301, count = 5 } }) }),
			["Bram-RealmA"] = H.charStore({ bags = H.dbItems({ { id = 301, count = 1 } }) }),
		},
		warband = H.dbItems({ { id = 301, count = 3 } }),
	})
end

-- Four alts with distinct counts, for the detail-mode shapes. Total 12.
local function altsDB(S)
	S.defineItem(301, { name = "Acorn" })
	local function one(n)
		return H.charStore({ bags = H.dbItems({ { id = 301, count = n } }) })
	end
	return H.db({ chars = {
		[H.OWN] = one(1),
		["Alva-R"] = one(5), ["Bea-R"] = one(3), ["Cal-R"] = one(2), ["Dee-R"] = one(1),
	} })
end

-- Quality world: "Rousing Fiber", silver (201) own bags 3 + warband 2, gold (202)
-- alt Liara 5. Total 10. qLink = the hovered silver link.
local qLink
local function qualityDB(S)
	S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
	S.defineItem(202, { name = "Rousing Fiber", reagent = 2 })
	qLink = S.link(201, "s")
	return H.db({
		chars = {
			[H.OWN] = H.charStore({ bags = H.dbItems({ { id = 201, count = 3, link = qLink } }) }),
			["Liara-RealmA"] = H.charStore({
				bags = H.dbItems({ { id = 202, count = 5, link = S.link(202, "g") } }),
			}),
		},
		warband = H.dbItems({ { id = 201, count = 2, link = S.link(201, "s2") } }),
	})
end

-- ---------------------------------------------------------------- routing

test("post_call_registered_for_item_data_type", function()
	local _, S = loadAddon({ noPEW = true })
	assertEq(S.itemPostCallType, _G.Enum.TooltipDataType.Item)
end)

test("plain_item_total_with_suffix", function()
	loadAddon({ noPEW = true, db = plainDB })
	local tip = H.hover({ id = 301 })
	assertEq(H.plainLines(tip), {
		" ",
		"Total items owned: 5 (bags 1" .. DOT .. "warband 3" .. DOT .. "Liara 1)",
	})
	H.assertSectionInvariant(tip)
end)

test("zero_total_renders_bare_line", function()
	loadAddon({ noPEW = true, db = plainDB })
	local tip = H.hover({ id = 999 }) -- owned nowhere
	assertEq(H.plainLines(tip), { " ", "Total items owned: 0" })
end)

test("hidezero_suppresses_section_and_spacer", function()
	local ns = loadAddon({ noPEW = true, db = plainDB })
	ns.GetSettings().hideZero = true
	assertEq(#H.hover({ id = 999 }).lines, 0) -- nothing strays, not even the spacer
	assertEq(#H.hover({ id = 301 }).lines, 2) -- owned items are unaffected
end)

test("forbidden_tooltip_untouched", function()
	loadAddon({ noPEW = true, db = plainDB })
	assertEq(#H.hover({ id = 301 }, { forbidden = true }).lines, 0)
end)

test("missing_data_or_id_bails", function()
	loadAddon({ noPEW = true, db = plainDB })
	assertEq(#H.hover(nil).lines, 0)
	assertEq(#H.hover({}).lines, 0) -- neither id nor a resolvable link
end)

test("recipe_id_link_disagreement_drops_link", function()
	local productLink
	loadAddon({ noPEW = true, db = function(S)
		S.defineItem(310, { name = "Recipe: Feast" })      -- NO classID: not recipe-class
		S.defineItem(311, { name = "Feast", reagent = 2 }) -- the embedded item
		productLink = S.link(311, "prod")
		return H.db({ chars = { [H.OWN] = H.charStore({ bags = H.dbItems({
			{ id = 310, count = 2 },
			{ id = 311, count = 7, link = S.link(311, "owned") },
		}) }) } })
	end })
	-- The tooltip data carries one id but resolves another item's link: the link must be
	-- dropped and the count keyed off the id -- otherwise the embedded item's quality
	-- would hijack the section onto the wrong item. And since the hovered item is NOT
	-- recipe-class, the mismatch must not fabricate a product sub-section either.
	local tip = H.hover({ id = 310, hyperlink = productLink })
	H.assertSectionInvariant(tip)
	assertEq(H.plainLines(tip)[2], "Total items owned: 2 (bags 2)")
	for _, raw in ipairs(H.plainLines(tip)) do
		assertTrue(raw:find("Crafted items", 1, true) == nil,
			"a non-recipe id/link mismatch never grows a product sub-section")
	end
end)

test("gear_id_without_link_tolerated", function()
	loadAddon({ noPEW = true, db = function(S)
		S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
		return H.db({ chars = { [H.OWN] = H.charStore({ bags = H.dbItems({
			{ id = 101, count = 2, ilvl = 645, link = S.link(101, "r4", { ilvl = 645, crafted = 4 }) },
		}) }) } })
	end })
	-- TooltipData's id and hyperlink are both optional: an id can arrive with no link at
	-- all. No hovered ilvl then -- the owned rows must still render without erroring
	-- (the stub hard-errors if a nil link ever reaches GetDetailedItemLevelInfo).
	local tip = H.hover({ id = 101 })
	H.assertSectionInvariant(tip)
	local plain = H.plainLines(tip)
	assertEq(plain[2], "Total items owned: 2 (bags 2)")
	assertTrue(plain[3]:find("645", 1, true) ~= nil, "the owned ilvl row still renders")
end)

test("link_only_data_derives_id_and_displayed_fallback", function()
	local l645
	local _, S = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
		l645 = S.link(101, "r4", { ilvl = 645, crafted = 4 })
		return H.db({ chars = { [H.OWN] = H.charStore({ bags = H.dbItems({
			{ id = 101, count = 2, ilvl = 645, link = l645 },
		}) }) } })
	end })
	-- No id at all: it derives from the hyperlink.
	local tip = H.hover({ hyperlink = l645 })
	assertEq(H.parseLine(tip.lines[2]), 2)
	-- An id with no hyperlink: TooltipUtil.GetDisplayedItem supplies the hovered link
	-- (and it agrees with the id, so it is kept -- the hovered row highlights).
	S.displayedLink = l645
	tip = H.hover({ id = 101 })
	assertTrue(tip.lines[3]:find("|cffffd100", 1, true) ~= nil,
		"hovered ilvl resolved via the displayed-item fallback")
end)

-- ---------------------------------------------------------------- gear path

test("gear_rows_highest_first_with_invariants", function()
	local l645
	loadAddon({ noPEW = true, db = function(S)
		S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
		l645 = S.link(101, "r4", { ilvl = 645, crafted = 4 })
		local l658 = S.link(101, "r5", { ilvl = 658, crafted = 5 })
		return H.db({ chars = { [H.OWN] = H.charStore({
			bags = H.dbItems({ { id = 101, count = 2, ilvl = 645, link = l645 } }),
			bank = H.dbItems({ { id = 101, count = 1, ilvl = 658, link = l658 } }),
		}) } })
	end })
	local tip = H.hover({ id = 101, hyperlink = l645 })
	H.assertSectionInvariant(tip)
	local plain = H.plainLines(tip)
	assertEq(#plain, 4) -- spacer, total, one row per ilvl
	-- highest first; ilvl leads, the rank star trails as a badge
	assertEq(plain[3], "  658 {Professions-ChatIcon-Quality-Tier5}: 1 (bank 1)")
	assertEq(plain[4], "  645 {Professions-ChatIcon-Quality-Tier4}: 2 (bags 2)")
	-- hovered 645: gold label + white count; the other row dim
	assertTrue(tip.lines[4]:find("|cffffd100", 1, true) ~= nil, "hovered row gold")
	assertTrue(tip.lines[4]:find("|cffffffff2|r", 1, true) ~= nil, "hovered count white")
	assertTrue(tip.lines[3]:find("|cffb3b3b3", 1, true) ~= nil, "non-hovered row dim")
end)

test("gear_hovered_unowned_rank_gets_zero_row", function()
	local l671
	loadAddon({ noPEW = true, db = function(S)
		S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
		l671 = S.link(101, "r5hi", { ilvl = 671, crafted = 5 })
		return H.db({ chars = { [H.OWN] = H.charStore({ bags = H.dbItems({
			{ id = 101, count = 2, ilvl = 645, link = S.link(101, "r4", { ilvl = 645, crafted = 4 }) },
		}) }) } })
	end })
	local tip = H.hover({ id = 101, hyperlink = l671 }) -- the rank about to be crafted
	H.assertSectionInvariant(tip)
	local plain = H.plainLines(tip)
	assertEq(plain[3], "  671 {Professions-ChatIcon-Quality-Tier5}: 0") -- synthetic: no suffix
	assertTrue(tip.lines[3]:find("|cffffd100", 1, true) ~= nil, "the zero row is the hovered one")
	assertEq(plain[4], "  645 {Professions-ChatIcon-Quality-Tier4}: 2 (bags 2)")
end)

test("gear_zero_total_collapses_to_total_line", function()
	local l645
	loadAddon({ noPEW = true, db = function(S)
		S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
		l645 = S.link(101, "r4", { ilvl = 645, crafted = 4 })
		return H.db({}) -- owned nowhere: no synthetic row either
	end })
	assertEq(H.plainLines(H.hover({ id = 101, hyperlink = l645 })), { " ", "Total items owned: 0" })
end)

test("gear_row_label_shapes", function()
	local lTrack
	loadAddon({ noPEW = true, db = function(S)
		S.defineItem(102, { name = "Dropped Helm", equipLoc = "INVTYPE_HEAD" })
		lTrack = S.link(102, "t", { ilvl = 613 })
		return H.db({ chars = { [H.OWN] = H.charStore({ bags = H.dbItems({
			{ id = 102, count = 1, ilvl = 613, link = lTrack,
				track = { name = "Hero", step = 2, max = 6 } },
			{ id = 102, count = 1, ilvl = 600, link = S.link(102, "p", { ilvl = 600 }) },
		}) }) } })
	end })
	local tip = H.hover({ id = 102, hyperlink = lTrack })
	H.assertSectionInvariant(tip)
	local plain = H.plainLines(tip)
	assertEq(plain[3], "  613 (H 2/6): 1 (bags 1)") -- upgrade track: first letter + progress
	assertEq(plain[4], "  ilvl 600: 1 (bags 1)")    -- trackless plain gear: bare-number prefix
end)

test("gear_synthetic_row_track_from_hovered_lines", function()
	local lHover
	loadAddon({ noPEW = true, db = function(S)
		S.defineItem(102, { name = "Dropped Helm", equipLoc = "INVTYPE_HEAD" })
		lHover = S.link(102, "hi", { ilvl = 626 })
		return H.db({ chars = { [H.OWN] = H.charStore({ bags = H.dbItems({
			{ id = 102, count = 1, ilvl = 613, link = S.link(102, "lo", { ilvl = 613 }),
				track = { name = "Hero", step = 2, max = 6 } },
		}) }) } })
	end })
	-- The synthetic owned-0 row has no stored group; its track comes from the hovered
	-- tooltip's own lines. "\195\137" = "É": the badge takes the first UTF-8 character
	-- whole, never a mojibake first byte.
	local tip = H.hover({ id = 102, hyperlink = lHover, lines = {
		{ leftText = "Upgrade Level: \195\137claireur 3/6" },
	} })
	H.assertSectionInvariant(tip)
	local plain = H.plainLines(tip)
	assertEq(plain[3], "  626 (\195\137 3/6): 0")
	assertEq(plain[4], "  613 (H 2/6): 1 (bags 1)")
end)

-- ---------------------------------------------------------------- quality path

test("quality_rows_best_first_with_invariants", function()
	loadAddon({ noPEW = true, db = qualityDB })
	local tip = H.hover({ id = 201, hyperlink = qLink })
	H.assertSectionInvariant(tip)
	local plain = H.plainLines(tip)
	assertEq(plain[2], "Total items owned: 10 (bags 3" .. DOT .. "warband 2" .. DOT .. "Liara 5)")
	assertEq(plain[3], "  {Professions-ChatIcon-Quality-12-Tier2}: 5 (Liara 5)") -- gold first
	assertEq(plain[4], "  {Professions-ChatIcon-Quality-12-Tier1}: 5 (bags 3" .. DOT .. "warband 2)")
	-- hovering silver: only the emphasis moves, never the order
	assertTrue(tip.lines[4]:find("|cffffd100", 1, true) ~= nil, "hovered tier gold")
	assertTrue(tip.lines[3]:find("|cffb3b3b3", 1, true) ~= nil, "other tier dim")
end)

test("quality_hovered_tier_owned_zero_row", function()
	local lGold
	loadAddon({ noPEW = true, db = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		S.defineItem(202, { name = "Rousing Fiber", reagent = 2 })
		lGold = S.link(202, "g")
		return H.db({ chars = { [H.OWN] = H.charStore({ bags = H.dbItems({
			{ id = 201, count = 3, link = S.link(201, "s") },
		}) }) } })
	end })
	local tip = H.hover({ id = 202, hyperlink = lGold }) -- hovering the unowned gold tier
	H.assertSectionInvariant(tip)
	local plain = H.plainLines(tip)
	assertEq(plain[3], "  {Professions-ChatIcon-Quality-12-Tier2}: 0") -- shown even at 0
	assertTrue(tip.lines[3]:find("|cffffd100", 1, true) ~= nil, "hovered zero row gold")
	assertEq(plain[4], "  {Professions-ChatIcon-Quality-12-Tier1}: 3 (bags 3)")
end)

test("quality_same_name_and_tier_merge_counts_and_sources", function()
	local lS
	loadAddon({ noPEW = true, db = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		S.defineItem(204, { name = "Rousing Fiber", reagent = 1 }) -- same name AND tier
		lS = S.link(201, "s")
		return H.db({ chars = { [H.OWN] = H.charStore({
			bags = H.dbItems({ { id = 201, count = 3, link = lS } }),
			bank = H.dbItems({ { id = 204, count = 2, link = S.link(204, "x") } }),
		}) } })
	end })
	local tip = H.hover({ id = 201, hyperlink = lS })
	H.assertSectionInvariant(tip) -- the merged row's suffix must still sum to its count
	local plain = H.plainLines(tip)
	assertEq(plain[2], "Total items owned: 5 (bags 3" .. DOT .. "bank 2)")
	assertEq(plain[3], "  {Professions-ChatIcon-Quality-12-Tier1}: 5 (bags 3" .. DOT .. "bank 2)")
	assertEq(#plain, 3) -- one row: counts AND sources merged
end)

test("quality_unresolvable_sibling_all_or_nothing", function()
	local lS
	loadAddon({ noPEW = true, db = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		-- 202: alt-owned, never seen this session -- no name, no quality; only its stored
		-- link (bracket name, no resolvable tier) represents it.
		local lCold = S.link(202, "cold", { name = "Rousing Fiber" })
		-- 203: an unrelated same-name item -- name resolves, but it has no quality.
		S.defineItem(203, { name = "Rousing Fiber" })
		lS = S.link(201, "s")
		return H.db({
			chars = {
				[H.OWN] = H.charStore({ bags = H.dbItems({ { id = 201, count = 3, link = lS } }) }),
				["Liara-RealmA"] = H.charStore({ bags = H.dbItems({
					{ id = 202, count = 5, link = lCold },
					{ id = 203, count = 7, link = S.link(203, "dup") },
				}) }),
			},
		})
	end })
	local tip = H.hover({ id = 201, hyperlink = lS })
	H.assertSectionInvariant(tip)
	local plain = H.plainLines(tip)
	-- Neither the cold-cache sibling nor the namesake may inflate the total: membership
	-- is all-or-nothing, so total == sum of rows under every cache state.
	assertEq(plain[2], "Total items owned: 3 (bags 3)")
	assertEq(#plain, 3)
end)

test("quality_request_load_once_per_rejected_id", function()
	local lS, lCold
	local _, S = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		lCold = S.link(202, "cold", { name = "Rousing Fiber" })
		-- 205 joins by name via GetItemNameByID but has NO stored link: already-cached
		-- item data, nothing to request.
		S.defineItem(205, { name = "Rousing Fiber" })
		lS = S.link(201, "s")
		return H.db({
			chars = {
				[H.OWN] = H.charStore({ bags = H.dbItems({ { id = 201, count = 3, link = lS } }) }),
				["Liara-RealmA"] = H.charStore({ bags = H.dbItems({
					{ id = 202, count = 5, link = lCold },
					{ id = 205, count = 1 },
				}) }),
			},
		})
	end })
	H.hover({ id = 201, hyperlink = lS })
	H.hover({ id = 201, hyperlink = lS }) -- second hover in the SAME session
	-- One cache-prime per id per session, passing the stored link (string-typed API);
	-- nothing for the linkless id.
	assertEq(S.calls.requestLoad, { lCold })
end)

test("quality_zero_total_collapse_and_hidezero", function()
	local lS
	local ns = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		lS = S.link(201, "s")
		return H.db({}) -- owned nowhere
	end })
	local tip = H.hover({ id = 201, hyperlink = lS })
	assertEq(H.plainLines(tip), { " ", "Total items owned: 0" }) -- no tier rows at zero
	ns.GetSettings().hideZero = true
	assertEq(#H.hover({ id = 201, hyperlink = lS }).lines, 0)
end)

-- ---------------------------------------------------------------- recipe product

-- Recipe world: recipe 310 (recipe-class) owned bags 1, crafting the two-tier "Feast" --
-- silver (311) own bags 4, gold (312) alt Liara 8. Product total 12. rLink = the
-- embedded product link a recipe tooltip resolves (the gold tier).
local rLink
local function recipeDB(S)
	S.defineItem(310, { name = "Recipe: Feast", classID = 9 })
	S.defineItem(311, { name = "Feast", reagent = 1 })
	S.defineItem(312, { name = "Feast", reagent = 2 })
	rLink = S.link(312, "prod")
	return H.db({
		chars = {
			[H.OWN] = H.charStore({ bags = H.dbItems({
				{ id = 310, count = 1 },
				{ id = 311, count = 4, link = S.link(311, "s") },
			}) }),
			["Liara-RealmA"] = H.charStore({ bags = H.dbItems({
				{ id = 312, count = 8, link = S.link(312, "g") },
			}) }),
		},
	})
end

test("recipe_renders_recipe_line_then_product_section", function()
	loadAddon({ noPEW = true, db = recipeDB })
	local tip = H.hover({ id = 310, hyperlink = rLink })
	H.assertSectionInvariant(tip) -- product rows sum to the product lead, per scope
	assertEq(H.plainLines(tip), {
		" ",
		"Total items owned: 1 (bags 1)",
		"Crafted items: 12 (bags 4" .. DOT .. "Liara 8)",
		"  {Professions-ChatIcon-Quality-12-Tier2}: 8 (Liara 8)",
		"  {Professions-ChatIcon-Quality-12-Tier1}: 4 (bags 4)",
	})
end)

test("recipe_product_no_hovered_variant", function()
	local pLink
	loadAddon({ noPEW = true, db = function(S)
		S.defineItem(310, { name = "Recipe: Feast", classID = 9 })
		S.defineItem(311, { name = "Feast", reagent = 1 })
		S.defineItem(312, { name = "Feast", reagent = 2 })
		pLink = S.link(312, "prod")
		-- 313: alt-owned name sibling, never seen this session -- tier unresolvable.
		local lCold = S.link(313, "cold", { name = "Feast" })
		return H.db({ chars = {
			[H.OWN] = H.charStore({ bags = H.dbItems({
				{ id = 310, count = 1 },
				{ id = 311, count = 4, link = S.link(311, "s") },
			}) }),
			["Liara-RealmA"] = H.charStore({ bags = H.dbItems({
				{ id = 313, count = 9, link = lCold },
			}) }),
		} })
	end })
	local tip = H.hover({ id = 310, hyperlink = pLink })
	H.assertSectionInvariant(tip)
	local plain = H.plainLines(tip)
	-- The embedded link is the gold tier, owned 0: nothing in the product block is under
	-- the cursor, so no synthetic 0-row and no gold emphasis anywhere. The cold-cache
	-- sibling stays all-or-nothing: it inflates neither the count nor the rows.
	assertEq(plain[3], "Crafted items: 4 (bags 4)")
	assertEq(plain[4], "  {Professions-ChatIcon-Quality-12-Tier1}: 4 (bags 4)")
	assertEq(#plain, 4)
	for _, raw in ipairs(tip.lines) do
		assertTrue(raw:find("|cffffd100", 1, true) == nil, "no gold emphasis in the section")
	end
end)

test("recipe_product_gear_breakdown", function()
	local pLink
	loadAddon({ noPEW = true, db = function(S)
		S.defineItem(320, { name = "Plans: Forged Chest", classID = 9 })
		S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
		pLink = S.link(101, "r5hi", { ilvl = 671, crafted = 5 })
		return H.db({ chars = { [H.OWN] = H.charStore({
			bags = H.dbItems({
				{ id = 320, count = 1 },
				{ id = 101, count = 2, ilvl = 645, link = S.link(101, "r4", { ilvl = 645, crafted = 4 }) },
			}),
			bank = H.dbItems({
				{ id = 101, count = 1, ilvl = 658, link = S.link(101, "r5", { ilvl = 658, crafted = 5 }) },
			}),
		}) } })
	end })
	local tip = H.hover({ id = 320, hyperlink = pLink })
	H.assertSectionInvariant(tip)
	local plain = H.plainLines(tip)
	assertEq(plain[2], "Total items owned: 1 (bags 1)")
	assertEq(plain[3], "Crafted items: 3 (bags 2" .. DOT .. "bank 1)")
	-- gear product: per-ilvl rows highest first, all dim -- and no synthetic row for the
	-- embedded link's own 671 (owned 0), because nothing in the block is hovered
	assertEq(plain[4], "  658 {Professions-ChatIcon-Quality-Tier5}: 1 (bank 1)")
	assertEq(plain[5], "  645 {Professions-ChatIcon-Quality-Tier4}: 2 (bags 2)")
	assertEq(#plain, 5)
	for _, raw in ipairs(tip.lines) do
		assertTrue(raw:find("|cffffd100", 1, true) == nil, "no gold emphasis in the product block")
	end
end)

test("product_hovered_directly_single_section", function()
	loadAddon({ noPEW = true, db = recipeDB })
	local tip = H.hover({ id = 312, hyperlink = rLink }) -- the product itself, not the recipe
	H.assertSectionInvariant(tip)
	local plain = H.plainLines(tip)
	assertEq(plain[2], "Total items owned: 12 (bags 4" .. DOT .. "Liara 8)")
	assertTrue(tip.lines[3]:find("|cffffd100", 1, true) ~= nil, "hovered tier gold as usual")
	for _, raw in ipairs(plain) do
		assertTrue(raw:find("Crafted items", 1, true) == nil, "exactly one normal section")
	end
end)

test("recipe_without_product_link_recipe_only", function()
	local _, S = loadAddon({ noPEW = true, db = recipeDB })
	-- No link at all (and no displayed-item fallback): the product is unknowable.
	assertEq(H.plainLines(H.hover({ id = 310 })), { " ", "Total items owned: 1 (bags 1)" })
	-- A link that agrees with the id (the recipe's own): likewise no product sub-section.
	local tip = H.hover({ id = 310, hyperlink = S.link(310, "self") })
	assertEq(H.plainLines(tip), { " ", "Total items owned: 1 (bags 1)" })
end)

test("recipe_product_mode_tristate", function()
	local ns, S = loadAddon({ noPEW = true, db = recipeDB })
	ns.GetSettings().recipeProductMode = "never"
	assertEq(#H.hover({ id = 310, hyperlink = rLink }).lines, 2) -- recipe line only
	ns.GetSettings().recipeProductMode = "modifier"
	assertEq(#H.hover({ id = 310, hyperlink = rLink }).lines, 2) -- key up: hidden
	S.keys.ALT = true
	local tip = H.hover({ id = 310, hyperlink = rLink })
	assertTrue(H.plainLines(tip)[3]:find("Crafted items", 1, true) ~= nil,
		"product sub-section appears while the key is held")
	H.assertSectionInvariant(tip)
end)

test("recipe_product_nil_settings_shows", function()
	-- No settings layer loaded: the product sub-section defaults to shown, matching the
	-- "always" default the sanitizer would fill.
	loadAddon({ noPEW = true, files = { "Core.lua", "Tooltip.lua" }, db = recipeDB })
	local tip = H.hover({ id = 310, hyperlink = rLink })
	assertTrue(H.plainLines(tip)[3]:find("Crafted items", 1, true) ~= nil,
		"nil settings render the product sub-section")
	H.assertSectionInvariant(tip)
end)

test("recipe_hidezero_per_subsection", function()
	local pOwned, pNone
	local ns = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(310, { name = "Recipe: Feast", classID = 9 })    -- owned 1
		S.defineItem(330, { name = "Recipe: Feast II", classID = 9 }) -- owned 0
		S.defineItem(311, { name = "Feast", reagent = 1 })            -- owned 4
		S.defineItem(206, { name = "Broth", reagent = 1 })            -- owned 0
		pOwned = S.link(311, "p1")
		pNone = S.link(206, "p2")
		return H.db({ chars = { [H.OWN] = H.charStore({ bags = H.dbItems({
			{ id = 310, count = 1 },
			{ id = 311, count = 4, link = S.link(311, "s") },
		}) }) } })
	end })
	ns.GetSettings().hideZero = true
	-- both above zero: both sub-sections render
	local plain = H.plainLines(H.hover({ id = 310, hyperlink = pOwned }))
	assertEq(plain[2], "Total items owned: 1 (bags 1)")
	assertEq(plain[3], "Crafted items: 4 (bags 4)")
	-- recipe 0, product > 0: the zero recipe line drops, the product block stays
	local tip = H.hover({ id = 330, hyperlink = pOwned })
	H.assertSectionInvariant(tip) -- a lone "Crafted items" lead satisfies the invariant
	assertEq(H.plainLines(tip), {
		" ",
		"Crafted items: 4 (bags 4)",
		"  {Professions-ChatIcon-Quality-12-Tier1}: 4 (bags 4)",
	})
	-- recipe > 0, product 0: the recipe line stays, the zero product block drops
	assertEq(H.plainLines(H.hover({ id = 310, hyperlink = pNone })),
		{ " ", "Total items owned: 1 (bags 1)" })
	-- both zero: nothing at all, not even the spacer
	assertEq(#H.hover({ id = 330, hyperlink = pNone }).lines, 0)
	-- hideZero off: both zeros render bare
	ns.GetSettings().hideZero = false
	assertEq(H.plainLines(H.hover({ id = 330, hyperlink = pNone })),
		{ " ", "Total items owned: 0", "Crafted items: 0" })
end)

test("recipe_product_mode_modifier_matters", function()
	local ns, S = loadAddon({ noPEW = true, db = recipeDB })
	S.watched.GameTooltip.shown = true
	-- everything else "always": only the product gating varies with the key
	ns.GetSettings().recipeProductMode = "modifier"
	S.pressModifier("LALT", true)
	assertEq(S.watched.GameTooltip.refreshCount, 1)
	ns.GetSettings().recipeProductMode = "always"
	S.pressModifier("LALT", false)
	assertEq(S.watched.GameTooltip.refreshCount, 1) -- nothing varies: no rebuild
end)

test("secondary_data_post_call_skipped", function()
	loadAddon({ noPEW = true, db = recipeDB })
	-- The same frame's post-call fires again with the embedded product's own data: the
	-- frame's primary data disagrees, so the render is skipped -- never a second section.
	assertEq(#H.hover({ id = 312, hyperlink = rLink }, { primary = { id = 310 } }).lines, 0)
	-- Primary data matching the processed data renders normally (fakes WITHOUT a
	-- GetTooltipData method render too -- every other test in this file proves that).
	assertTrue(#H.hover({ id = 310, hyperlink = rLink }, { primary = { id = 310 } }).lines > 0,
		"matching primary data renders")
end)

-- ---------------------------------------------------------------- suffix & settings

test("suffix_fixed_order_and_bags_brightness", function()
	loadAddon({ noPEW = true, db = suffixDB })
	local tip = H.hover({ id = 301 })
	local count, tokens = H.parseLine(tip.lines[2])
	assertEq(count, 16)
	assertEq(tokens, { "bags 1", "bank 2", "warband 3", "equipped 4", "Liara 5", "Bram 1" })
	-- the whole bags token sits one step brighter; the rest at the suffix base
	assertTrue(tip.lines[2]:find("|cffa6a6a6bags 1|r", 1, true) ~= nil, "bags token brighter")
	assertTrue(tip.lines[2]:find("|cff808080bank 2|r", 1, true) ~= nil, "bank at suffix base")
	assertTrue(tip.lines[2]:find("|cff808080equipped 4|r", 1, true) ~= nil, "equipped at suffix base")
end)

test("bank_merge_requires_both_tokens", function()
	local ns = loadAddon({ noPEW = true, db = suffixDB })
	ns.GetSettings().bankMerge = "merged"
	local count, tokens = H.parseLine(H.hover({ id = 301 }).lines[2])
	assertEq(count, 16)
	assertEq(tokens, { "bags 1", "banks 5", "equipped 4", "Liara 5", "Bram 1" })
	ns.GetSettings().bankMode = "never" -- a lone warband token never merges
	count, tokens = H.parseLine(H.hover({ id = 301 }).lines[2])
	assertEq(count, 14)
	assertEq(tokens, { "bags 1", "warband 3", "equipped 4", "Liara 5", "Bram 1" })
end)

test("bank_merge_modifier_gated", function()
	local ns, S = loadAddon({ noPEW = true, db = suffixDB })
	ns.GetSettings().bankMerge = "modifier" -- merged UNLESS the key is held
	local _, tokens = H.parseLine(H.hover({ id = 301 }).lines[2])
	assertEq(tokens[2], "banks 5")
	S.keys.ALT = true
	_, tokens = H.parseLine(H.hover({ id = 301 }).lines[2])
	assertEq(tokens[2], "bank 2")
end)

test("alts_topn_tail_collapse", function()
	loadAddon({ noPEW = true, db = altsDB })
	local tip = H.hover({ id = 301 })
	H.assertSuffixSums(tip.lines[2])
	local _, tokens = H.parseLine(tip.lines[2])
	-- top 2 by count named; the 2-alt tail collapses, its count keeping the sum exact
	assertEq(tokens, { "bags 1", "Alva 5", "Bea 3", "+2 alts 3" })
end)

test("alts_tail_of_one_named_not_collapsed", function()
	loadAddon({ noPEW = true, db = function(S)
		S.defineItem(301, { name = "Acorn" })
		local function one(n)
			return H.charStore({ bags = H.dbItems({ { id = 301, count = n } }) })
		end
		return H.db({ chars = {
			[H.OWN] = one(1), ["Alva-R"] = one(5), ["Bea-R"] = one(3), ["Cal-R"] = one(2),
		} })
	end })
	-- "+1 alts 2" saves nothing over the name and says less: everyone is named.
	local _, tokens = H.parseLine(H.hover({ id = 301 }).lines[2])
	assertEq(tokens, { "bags 1", "Alva 5", "Bea 3", "Cal 2" })
end)

test("alts_detail_modes_and_expand_key", function()
	local ns, S = loadAddon({ noPEW = true, db = altsDB })
	ns.GetSettings().altsDetail = "total"
	local _, tokens = H.parseLine(H.hover({ id = 301 }).lines[2])
	assertEq(tokens, { "bags 1", "alts 11" })
	ns.GetSettings().altsDetail = "all"
	_, tokens = H.parseLine(H.hover({ id = 301 }).lines[2])
	assertEq(tokens, { "bags 1", "Alva 5", "Bea 3", "Cal 2", "Dee 1" })
	-- the expand checkbox promotes any detail mode to "all" while the key is down
	ns.GetSettings().altsDetail = "topn"
	ns.GetSettings().altsExpandKey = true
	S.keys.ALT = true
	_, tokens = H.parseLine(H.hover({ id = 301 }).lines[2])
	assertEq(tokens, { "bags 1", "Alva 5", "Bea 3", "Cal 2", "Dee 1" })
	S.keys.ALT = false
	_, tokens = H.parseLine(H.hover({ id = 301 }).lines[2])
	assertEq(tokens, { "bags 1", "Alva 5", "Bea 3", "+2 alts 3" })
end)

test("source_modes_matrix_holds_invariants", function()
	local ns, S = loadAddon({ noPEW = true, db = suffixDB })
	local cases = {
		{ key = "bankMode", tokens = { "bank " }, n = 2 },
		{ key = "warbandMode", tokens = { "warband " }, n = 3 },
		{ key = "equippedMode", tokens = { "equipped " }, n = 4 },
		{ key = "altsMode", tokens = { "Liara ", "Bram " }, n = 6 },
	}
	local function hoverTotal()
		local tip = H.hover({ id = 301 })
		return H.assertSectionInvariant(tip), H.strip(tip.lines[2])
	end
	for _, c in ipairs(cases) do
		local s = ns.GetSettings()
		s[c.key] = "never"
		local total, line = hoverTotal()
		-- A gated-off source vanishes from the total AND the suffix alike -- the section
		-- invariant (checked inside hoverTotal) guarantees the two agree.
		assertEq(total, 16 - c.n, c.key .. " never")
		for _, tok in ipairs(c.tokens) do
			assertTrue(line:find(tok, 1, true) == nil, tok .. "token absent under " .. c.key)
		end
		s[c.key] = "modifier"
		S.keys.ALT = false
		assertEq(hoverTotal(), 16 - c.n, c.key .. " gated, key up")
		S.keys.ALT = true
		assertEq(hoverTotal(), 16, c.key .. " gated, key down")
		S.keys.ALT = false
		s[c.key] = "always"
	end
end)

test("suffix_and_rows_modifier_gated", function()
	local ns, S = loadAddon({ noPEW = true, db = qualityDB })
	ns.GetSettings().suffixMode = "modifier"
	local tip = H.hover({ id = 201, hyperlink = qLink })
	for _, raw in ipairs(tip.lines) do
		assertTrue(H.strip(raw):find("%(") == nil, "no suffix anywhere while the key is up")
	end
	S.keys.ALT = true
	tip = H.hover({ id = 201, hyperlink = qLink })
	assertTrue(H.strip(tip.lines[2]):find("%(") ~= nil, "suffix appears while held")
	S.keys.ALT = false
	ns.GetSettings().suffixMode = "always"
	ns.GetSettings().rowsMode = "modifier"
	tip = H.hover({ id = 201, hyperlink = qLink })
	assertEq(#tip.lines, 2) -- spacer + total only
	S.keys.ALT = true
	tip = H.hover({ id = 201, hyperlink = qLink })
	assertEq(#tip.lines, 4, "breakdown rows appear while held")
end)

test("nil_settings_renders_full_default_display", function()
	-- Core.lua tolerates a missing settings layer (guarded InitSettings call); the
	-- tooltip layer must then behave as "no filter, full display, default shape".
	loadAddon({ noPEW = true, files = { "Core.lua", "Tooltip.lua" }, db = suffixDB })
	local tip = H.hover({ id = 301 })
	local count, tokens = H.parseLine(tip.lines[2])
	assertEq(count, 16)
	assertEq(#tokens, 6) -- suffix on, every source visible, top-2 default in force
	H.assertSectionInvariant(tip)
end)

-- ---------------------------------------------------------------- refresh watcher

test("watcher_refreshes_visible_watched_frames", function()
	local ns, S = loadAddon({ noPEW = true, db = plainDB })
	ns.GetSettings().bankMode = "modifier" -- some setting varies with the key
	S.watched.GameTooltip.shown = true
	S.watched.ShoppingTooltip1.shown = true
	S.watched.ShoppingTooltip1.RefreshData = nil -- a frame without the mixin is left alone
	S.pressModifier("LALT", true)
	assertEq(S.watched.GameTooltip.refreshCount, 1)
	assertEq(S.watched.ItemRefTooltip.refreshCount, 0) -- hidden: skipped
	S.pressModifier("RALT", false) -- either Alt key maps to the ALT modifier
	assertEq(S.watched.GameTooltip.refreshCount, 2)
end)

test("watcher_guards_skip_pointless_rebuilds", function()
	local ns, S = loadAddon({ noPEW = true, db = plainDB })
	local s = ns.GetSettings()
	S.watched.GameTooltip.shown = true
	-- everything "always": a key flip cannot change the section
	S.pressModifier("LALT", true)
	S.pressModifier("LALT", false)
	assertEq(S.watched.GameTooltip.refreshCount, 0)
	-- a key that doesn't map to the configured modifier
	s.bankMode = "modifier"
	S.pressModifier("LSHIFT", true)
	S.pressModifier("LSHIFT", false)
	assertEq(S.watched.GameTooltip.refreshCount, 0)
	-- altsExpandKey only matters while the detail mode isn't already "all"
	s.bankMode = "always"
	s.altsExpandKey = true
	s.altsDetail = "all"
	S.pressModifier("LALT", true)
	assertEq(S.watched.GameTooltip.refreshCount, 0)
	s.altsDetail = "topn"
	S.pressModifier("LALT", false)
	assertEq(S.watched.GameTooltip.refreshCount, 1)
end)
