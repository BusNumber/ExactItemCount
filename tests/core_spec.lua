-- tests/core_spec.lua -- data layer: scans, events, DB lifecycle, aggregation seams.
local T = ...
local test, assertTrue, assertEq = T.test, T.assertTrue, T.assertEq
local loadAddon, H = T.loadAddon, T.H

-- ---------------------------------------------------------------- scans & events

test("scan_bags_groups_by_ilvl", function()
	loadAddon({ setup = function(S)
		S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
		S.setContainer(0, {
			{ id = 101, count = 1, ilvl = 645 },
			{ id = 101, count = 1, ilvl = 658 },
			{ id = 101, count = 2, ilvl = 645 },
		})
	end })
	local snap = _G.ExactItemCountDB.chars[H.OWN].bags
	assertEq(snap.scannedAt, 1000)
	assertEq(snap.items[101].total, 4)
	assertEq(snap.items[101].groups[645].count, 3)
	assertEq(snap.items[101].groups[658].count, 1)
end)

test("scan_first_stack_wins_representatives", function()
	local l1, l2
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
		l1 = S.link(101, "a", { ilvl = 645 })
		l2 = S.link(101, "b", { ilvl = 645 })
		S.setContainer(0, {
			{ id = 101, count = 1, ilvl = 645, link = l1, track = { name = "Hero", step = 1, max = 6 } },
			{ id = 101, count = 1, ilvl = 645, link = l2, track = { name = "Myth", step = 2, max = 6 } },
		})
	end })
	local entry = _G.ExactItemCountDB.chars[H.OWN].bags.items[101]
	assertEq(entry.link, l1)
	assertEq(entry.groups[645].link, l1)
	assertEq(entry.groups[645].track.name, "Hero") -- first stack wins; the second is never fetched
	assertEq(S.calls.bagTip, 1)
end)

test("scan_fetchtip_gated_by_gear_and_new_group", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		S.setContainer(0, {
			{ id = 101, count = 1, ilvl = 645 },
			{ id = 101, count = 1, ilvl = 645 }, -- existing group: no fetch
			{ id = 101, count = 1, ilvl = 658 }, -- new group: fetch
			{ id = 201, count = 5, ilvl = 1 },   -- not gear: never fetched
			{ id = 201, count = 5, ilvl = 2 },
		})
	end })
	assertEq(S.calls.bagTip, 2) -- one per NEW GEAR group only
end)

test("scan_track_parsed_into_group", function()
	loadAddon({ setup = function(S)
		S.defineItem(102, { name = "Dropped Helm", equipLoc = "INVTYPE_HEAD" })
		S.setContainer(0, {
			{ id = 102, count = 1, ilvl = 613, track = { name = "Hero", step = 2, max = 6 } },
		})
	end })
	local group = _G.ExactItemCountDB.chars[H.OWN].bags.items[102].groups[613]
	assertEq(group.track, { name = "Hero", step = 2, max = 6 })
end)

test("scan_ilvl_fallback_chain", function()
	loadAddon({ setup = function(S)
		S.defineItem(102, { name = "Dropped Helm", equipLoc = "INVTYPE_HEAD" })
		local l = S.link(102, "x", { ilvl = 650 })
		S.setContainer(0, {
			{ id = 102, count = 1, link = l },     -- no live ilvl: falls back to the link's
			{ id = 102, count = 1, link = false }, -- neither: lands in the ilvl-0 group
		})
	end })
	local entry = _G.ExactItemCountDB.chars[H.OWN].bags.items[102]
	assertEq(entry.groups[650].count, 1)
	assertEq(entry.groups[0].count, 1)
end)

test("scan_equipped_slots_incl_profession", function()
	loadAddon({ setup = function(S)
		S.defineItem(103, { name = "Worn Blade", equipLoc = "INVTYPE_WEAPON" })
		S.defineItem(104, { name = "Alchemist Tool", equipLoc = "INVTYPE_PROFESSION_TOOL" })
		S.setEquipped(16, { id = 103, ilvl = 620 })
		S.setEquipped(25, { id = 104, ilvl = 580 }) -- profession slots 20..30 are enumerated
	end })
	local items = _G.ExactItemCountDB.chars[H.OWN].equipped.items
	assertEq(items[103].total, 1)
	assertEq(items[103].groups[620].count, 1)
	assertEq(items[104].total, 1)
	assertEq(items[104].groups[580].count, 1)
end)

test("equipment_changed_rescans_wholesale", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(103, { name = "Worn Blade", equipLoc = "INVTYPE_WEAPON" })
		S.setEquipped(16, { id = 103, ilvl = 620 })
	end })
	S.setEquipped(16, nil)
	S.setEquipped(17, { id = 103, ilvl = 635 })
	S.fire("PLAYER_EQUIPMENT_CHANGED", 16)
	local entry = _G.ExactItemCountDB.chars[H.OWN].equipped.items[103]
	assertEq(entry.total, 1)
	assertEq(entry.groups[635].count, 1)
	assertEq(entry.groups[620], nil) -- snapshots swap wholesale; nothing lingers
end)

test("bag_update_delayed_self_heals_login_scan", function()
	-- The login PEW fires before item data exists; the model here: PEW scanned an empty
	-- world, then contents "arrive" and BAG_UPDATE_DELAYED repairs both snapshots.
	local _, S = loadAddon()
	assertEq(next(_G.ExactItemCountDB.chars[H.OWN].bags.items), nil)
	S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
	S.defineItem(103, { name = "Worn Blade", equipLoc = "INVTYPE_WEAPON" })
	S.setContainer(0, { { id = 201, count = 5 } })
	S.setEquipped(16, { id = 103, ilvl = 620 })
	S.fire("BAG_UPDATE_DELAYED")
	assertEq(_G.ExactItemCountDB.chars[H.OWN].bags.items[201].total, 5)
	assertEq(_G.ExactItemCountDB.chars[H.OWN].equipped.items[103].total, 1)
end)

test("pre_pew_scans_bail_on_nil_key", function()
	local _, S = loadAddon({ noPEW = true, setup = function(S)
		S.realm = nil -- normalized realm not yet available (login order quirk)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		S.setContainer(0, { { id = 201, count = 5 } })
	end })
	S.fire("BAG_UPDATE_DELAYED") -- must bail without a key, not error or misfile
	assertEq(next(_G.ExactItemCountDB.chars), nil)
	S.realm = "TestRealm"
	S.fire("PLAYER_ENTERING_WORLD") -- the PEW rescan covers what the bail skipped
	assertEq(_G.ExactItemCountDB.chars[H.OWN].bags.items[201].total, 5)
end)

test("pre_pew_alt_loop_skipped", function()
	local ns = loadAddon({ noPEW = true,
		setup = function(S) S.realm = nil end,
		db = function(S)
			S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
			return H.db({
				chars = { [H.OWN] = H.charStore({ bags = H.dbItems({ { id = 201, count = 5 } }) }) },
				warband = H.dbItems({ { id = 201, count = 2 } }),
			})
		end })
	-- With the own key unresolved, self and alts are indistinguishable: the character's
	-- own cached data must be skipped, not misattributed as an alt of itself.
	local agg = ns.Get(201)
	assertEq(agg.total, 2)
	assertEq(agg.sources, { warband = 2 })
end)

test("bank_scans_on_bankframe_opened", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		S.setBank(_G.Enum.BankType.Character, { 6, 7 })
		S.setBank(_G.Enum.BankType.Account, { 12 })
		S.setContainer(6, { { id = 201, count = 5 } })
		S.setContainer(7, { { id = 201, count = 1 } })
		S.setContainer(12, { { id = 201, count = 7 } })
	end })
	S.fire("BANKFRAME_OPENED")
	local char = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(char.bank.items[201].total, 6)
	assertEq(char.bank.scannedAt, 1000)
	assertEq(_G.ExactItemCountDB.warband.items[201].total, 7)
end)

test("bank_rescans_only_while_open", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		S.setBank(_G.Enum.BankType.Character, { 6 })
		S.setBank(_G.Enum.BankType.Account, { 12 })
		S.setContainer(6, { { id = 201, count = 5 } })
		S.setContainer(12, { { id = 201, count = 7 } })
	end })
	S.fire("BANKFRAME_OPENED")
	S.setContainer(6, { { id = 201, count = 9 } })
	S.fire("BAG_UPDATE_DELAYED") -- while open, the delayed event covers the tab bag IDs
	local char = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(char.bank.items[201].total, 9)
	S.fire("BANKFRAME_CLOSED")
	S.fire("BANKFRAME_CLOSED") -- known to fire twice; must stay idempotent
	S.setContainer(6, { { id = 201, count = 1 } })
	S.fire("BAG_UPDATE_DELAYED")
	assertEq(char.bank.items[201].total, 9) -- closed: the snapshot keeps its last scan
end)

test("bank_never_wipes_when_unreadable", function()
	local BT = _G.Enum.BankType
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		S.setBank(_G.Enum.BankType.Character, { 6 })
		S.setContainer(6, { { id = 201, count = 5 } })
	end })
	S.fire("BANKFRAME_OPENED")
	local char = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(char.bank.scannedAt, 1000)
	S.advance(100) -- a successful rescan from here on would restamp scannedAt to 1100

	S.bankUsable[BT.Character] = false -- bank type not usable in this context
	S.fire("BANKFRAME_OPENED")
	assertEq(char.bank.scannedAt, 1000)

	S.bankUsable[BT.Character] = true
	S.bankTabs[BT.Character] = {} -- no purchased tabs fetched
	S.fire("BANKFRAME_OPENED")
	assertEq(char.bank.scannedAt, 1000)

	S.bankTabs[BT.Character] = { 6 }
	S.setContainer(6, { { id = 201, count = 5 } }, 0) -- first tab reads 0 slots: out of context
	S.fire("BANKFRAME_OPENED")
	assertEq(char.bank.scannedAt, 1000)
	assertEq(char.bank.items[201].total, 5) -- the old snapshot's contents survive throughout
end)

test("warband_only_session_keeps_char_bank", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		S.setBank(_G.Enum.BankType.Character, { 6 })
		S.setBank(_G.Enum.BankType.Account, { 12 })
		S.setContainer(6, { { id = 201, count = 5 } })
		S.setContainer(12, { { id = 201, count = 7 } })
	end })
	S.fire("BANKFRAME_OPENED")
	S.fire("BANKFRAME_CLOSED")
	S.advance(100)
	-- Remote warband access (Distance Inhibitor): the character bank is out of reach and
	-- must keep its snapshot while the warband one refreshes.
	S.bankUsable[_G.Enum.BankType.Character] = false
	S.setContainer(12, { { id = 201, count = 8 } })
	S.fire("BANKFRAME_OPENED")
	local char = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(char.bank.scannedAt, 1000)
	assertEq(char.bank.items[201].total, 5)
	assertEq(_G.ExactItemCountDB.warband.scannedAt, 1100)
	assertEq(_G.ExactItemCountDB.warband.items[201].total, 8)
end)

-- ---------------------------------------------------------------- DB lifecycle

test("fresh_db_stamped_and_foreign_addon_ignored", function()
	local ns, S = loadAddon({ noAddonLoaded = true, noPEW = true })
	S.fire("ADDON_LOADED", "SomeOtherAddon")
	assertEq(_G.ExactItemCountDB, nil) -- not ours: untouched
	assertEq(ns.GetSettings(), nil)    -- and InitSettings hasn't run yet
	S.fire("ADDON_LOADED", "ExactItemCount")
	local db = _G.ExactItemCountDB
	assertEq(db.version, 1)
	assertTrue(type(db.chars) == "table")
	assertEq(db.addonVersion, "test") -- restamped from the TOC metadata every load
	assertTrue(ns.GetSettings() ~= nil, "InitSettings ran")
	assertTrue(ns.GetSettings() == db.settings, "GetSettings returns the live table")
end)

test("version_mismatch_rebuilds_but_carries_settings", function()
	for _, version in ipairs({ 0, 99 }) do -- upgrade and downgrade rebuild the same way
		local old = {
			version = version,
			chars = { ["Ghost-Realm"] = {} },
			settings = { hideZero = true, altEquipped = false, bankMode = "bogus" },
		}
		local ns = loadAddon({ db = old, noPEW = true })
		local db = _G.ExactItemCountDB
		assertTrue(db ~= old, "rebuilt into a fresh table")
		assertEq(db.version, 1)
		assertEq(next(db.chars), nil)                  -- caches drop; scans rebuild them
		assertTrue(db.settings == old.settings,        -- the one piece of real user data
			"settings carried over by reference")
		assertEq(ns.GetSettings().hideZero, true)      -- persisted values survive...
		assertEq(ns.GetSettings().altEquipped, false)
		assertEq(ns.GetSettings().bankMode, "always")  -- ...and junk is sanitized away
	end
end)

test("malformed_db_rebuilds", function()
	loadAddon({ db = { version = 1 }, noPEW = true }) -- right version, no chars table
	assertTrue(type(_G.ExactItemCountDB.chars) == "table")
	loadAddon({ db = { version = 99, settings = "garbage" }, noPEW = true })
	assertEq(_G.ExactItemCountDB.settings.bankMode, "always") -- non-table settings not carried
end)

-- ---------------------------------------------------------------- aggregation seams

-- The standard multi-source world for item 101 (crafted chest, R4@645 / R5@658):
-- own bags 2@645, own bank 1@645 + 1@658, own equipped 1@658, warband 4@645,
-- alt Liara bags 3@645 + equipped 1@658, alt Bram bank 2@658. Full total 15.
-- Item 401 exists only in the own bank (for the filtered-to-nothing case).
local function worldDB(S)
	S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
	local l645 = S.link(101, "r4", { ilvl = 645, crafted = 4 })
	local l658 = S.link(101, "r5", { ilvl = 658, crafted = 5 })
	S.defineItem(401, { name = "Bank Note" })
	return H.db({
		chars = {
			[H.OWN] = H.charStore({
				bags = H.dbItems({ { id = 101, count = 2, ilvl = 645, link = l645 } }),
				bank = H.dbItems({
					{ id = 101, count = 1, ilvl = 645, link = l645 },
					{ id = 101, count = 1, ilvl = 658, link = l658 },
					{ id = 401, count = 3 },
				}),
				equipped = H.dbItems({ { id = 101, count = 1, ilvl = 658, link = l658 } }),
			}),
			["Liara-RealmA"] = H.charStore({
				bags = H.dbItems({ { id = 101, count = 3, ilvl = 645, link = l645 } }),
				equipped = H.dbItems({ { id = 101, count = 1, ilvl = 658, link = l658 } }),
			}),
			["Bram-RealmA"] = H.charStore({
				bank = H.dbItems({ { id = 101, count = 2, ilvl = 658, link = l658 } }),
			}),
		},
		warband = H.dbItems({ { id = 101, count = 4, ilvl = 645, link = l645 } }),
	})
end

test("get_merges_every_source_kind", function()
	local ns = loadAddon({ noPEW = true, db = worldDB })
	local agg = ns.Get(101)
	assertEq(agg.total, 15)
	assertEq(agg.sources,
		{ bags = 2, bank = 2, equipped = 1, warband = 4, alts = { Liara = 4, Bram = 2 } })
	assertEq(agg.groups[645].count, 10)
	assertEq(agg.groups[645].sources, { bags = 2, bank = 1, warband = 4, alts = { Liara = 3 } })
	assertEq(agg.groups[658].count, 5)
	assertEq(agg.groups[658].sources, { bank = 1, equipped = 1, alts = { Liara = 1, Bram = 2 } })
	H.assertNoZeros(agg.sources)
end)

test("get_invariants_under_every_filter", function()
	local ns = loadAddon({ noPEW = true, db = worldDB })
	H.eachFilter(function(f)
		local expected = 2 + (f.bank and 2 or 0) + (f.equipped and 1 or 0) + (f.warband and 4 or 0)
			+ (f.alts and (3 + (f.altEquipped and 1 or 0) + 2) or 0)
		local agg = ns.Get(101, f)
		assertEq(agg.total, expected, "filtered total")
		assertEq(H.sumSources(agg.sources), agg.total, "sources sum to the total")
		H.assertNoZeros(agg.sources)
		local groupSum = 0
		for _, group in pairs(agg.groups) do
			groupSum = groupSum + group.count
			assertEq(H.sumSources(group.sources), group.count, "group sources sum to its count")
			H.assertNoZeros(group.sources)
		end
		assertEq(groupSum, agg.total, "groups sum to the total")
	end)
	-- Owned only in a filtered-out source: nil, not an all-zero aggregate.
	assertEq(ns.Get(401, { bags = true, bank = false, warband = true, equipped = true, alts = true }), nil)
	-- Hidden alts drop out of total and sources alike.
	local agg = ns.Get(101, { bags = true, bank = true, warband = true, equipped = true, alts = true,
		altEquipped = true, hiddenChars = { ["Liara-RealmA"] = true } })
	assertEq(agg.total, 11)
	assertEq(agg.sources.alts, { Bram = 2 })
end)

test("get_representative_precedence_follows_visit_order", function()
	local ns = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(102, { name = "Dropped Helm", equipLoc = "INVTYPE_HEAD" })
		local lBank = S.link(102, "bankrep", { ilvl = 613 })
		local lWb = S.link(102, "wbrep", { ilvl = 613 })
		return H.db({
			chars = {
				[H.OWN] = H.charStore({
					bags = H.dbItems({ { id = 102, count = 1, ilvl = 613 } }), -- no representatives
					bank = H.dbItems({ { id = 102, count = 1, ilvl = 613, link = lBank,
						track = { name = "Hero", step = 1, max = 6 } } }),
				}),
			},
			warband = H.dbItems({ { id = 102, count = 1, ilvl = 613, link = lWb,
				track = { name = "Myth", step = 5, max = 6 } } }),
		})
	end })
	local agg = ns.Get(102)
	-- Own bags visit first but carry nothing; the bank's representatives fill in and the
	-- warband's lose (first non-nil in visit order).
	assertTrue(agg.link and agg.link:find("bankrep", 1, true) ~= nil, "entry link from the bank")
	assertEq(agg.groups[613].track.name, "Hero")
end)

test("same_name_alts_across_realms_merge_in_display", function()
	local ns = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		return H.db({
			chars = {
				[H.OWN] = H.charStore({ bags = H.dbItems({ { id = 201, count = 1 } }) }),
				["Liara-RealmA"] = H.charStore({ bags = H.dbItems({ { id = 201, count = 2 } }) }),
				["Liara-RealmB"] = H.charStore({ bags = H.dbItems({ { id = 201, count = 3 } }) }),
			},
		})
	end })
	local agg = ns.Get(201)
	assertEq(agg.sources.alts, { Liara = 5 }) -- display merges; the DB keys keep the realm
end)

test("getbyname_joins_name_siblings", function()
	local ns = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		S.defineItem(202, { name = "Rousing Fiber", reagent = 2 })
		S.defineItem(301, { name = "Acorn" })
		return H.db({
			chars = {
				[H.OWN] = H.charStore({ bags = H.dbItems({
					{ id = 201, count = 3 }, { id = 301, count = 9 } }) }),
				["Liara-RealmA"] = H.charStore({ bags = H.dbItems({ { id = 202, count = 5 } }) }),
			},
			warband = H.dbItems({ { id = 201, count = 2 } }),
		})
	end })
	local name, members, combined = ns.GetByName(201)
	assertEq(name, "Rousing Fiber")
	assertEq(#members, 2) -- the unrelated Acorn never joins
	assertEq(combined.total, 10)
	assertEq(combined.sources, { bags = 3, warband = 2, alts = { Liara = 5 } })
	local sum = 0
	for _, m in ipairs(members) do sum = sum + m.total end
	assertEq(sum, combined.total, "combined equals the sum of the members")
end)

test("getbyname_linkname_fallback_cold_cache", function()
	local ns = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		-- 202 was never seen this session: GetItemNameByID returns nil, so only the
		-- bracket name inside the link stored at scan time can join it.
		local lg = S.link(202, "g", { name = "Rousing Fiber" })
		return H.db({
			chars = {
				[H.OWN] = H.charStore({ bags = H.dbItems({ { id = 201, count = 3 } }) }),
				["Liara-RealmA"] = H.charStore({ bags = H.dbItems({ { id = 202, count = 5, link = lg } }) }),
			},
		})
	end })
	local _, members, combined = ns.GetByName(201)
	assertEq(#members, 2)
	assertEq(combined.total, 8)
end)

test("getbyname_accept_is_all_or_nothing", function()
	local ns = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		S.defineItem(202, { name = "Rousing Fiber", reagent = 2 })
		return H.db({
			chars = {
				[H.OWN] = H.charStore({ bags = H.dbItems({ { id = 201, count = 3 } }) }),
				["Liara-RealmA"] = H.charStore({ bags = H.dbItems({ { id = 202, count = 5 } }) }),
			},
			warband = H.dbItems({ { id = 201, count = 2 } }),
		})
	end })
	local seen = {}
	local _, members, combined = ns.GetByName(201, nil, function(id)
		seen[id] = true
		return id ~= 202
	end)
	assertEq(#members, 1)
	assertEq(combined.total, 5) -- a rejected id contributes neither a member nor a share
	assertTrue(seen[202], "accept was consulted for the sibling")
end)

test("getbyname_filter_threads_both_passes", function()
	-- A sibling owned ONLY in a filtered-out source must contribute neither a member nor
	-- a total share, even though accept would admit it.
	local ns = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		S.defineItem(202, { name = "Rousing Fiber", reagent = 2 })
		return H.db({
			chars = { [H.OWN] = H.charStore({ bags = H.dbItems({ { id = 201, count = 3 } }) }) },
			warband = H.dbItems({ { id = 202, count = 5 } }),
		})
	end })
	local filter = { bags = true, bank = true, equipped = true, warband = false, alts = true }
	local _, members, combined = ns.GetByName(201, filter, function() return true end)
	assertEq(#members, 1)
	assertEq(combined.total, 3)
end)

test("merge_sources_sums_tags_and_alts", function()
	local ns = loadAddon({ noPEW = true })
	local dst = { bags = 1, alts = { Liara = 2 } }
	ns.MergeSources(dst, { bags = 2, bank = 3, warband = 1, equipped = 4, alts = { Liara = 1, Bram = 4 } })
	assertEq(dst, { bags = 3, bank = 3, warband = 1, equipped = 4, alts = { Liara = 3, Bram = 4 } })
	ns.MergeSources(dst, {}) -- empty source: no-op, and no zero keys appear
	assertEq(dst, { bags = 3, bank = 3, warband = 1, equipped = 4, alts = { Liara = 3, Bram = 4 } })
end)

test("delete_char_guards", function()
	local ns = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		return H.db({ chars = {
			[H.OWN] = H.charStore({ bags = H.dbItems({ { id = 201, count = 1 } }) }),
			["Liara-RealmA"] = H.charStore({ bags = H.dbItems({ { id = 201, count = 2 } }) }),
		} })
	end })
	local db = _G.ExactItemCountDB
	ns.GetSettings().hiddenChars["Liara-RealmA"] = true
	ns.DeleteChar("Liara-RealmA")
	assertEq(db.chars["Liara-RealmA"], nil)
	assertEq(ns.GetSettings().hiddenChars["Liara-RealmA"], nil) -- the flag dies with the data
	ns.DeleteChar(H.OWN) -- the current character is never deletable
	assertTrue(db.chars[H.OWN] ~= nil, "own data survives a self-delete attempt")
	ns.DeleteChar(nil) -- and nil must not error
end)

test("delete_char_refused_while_own_key_unresolved", function()
	local ns = loadAddon({ noPEW = true,
		setup = function(S) S.realm = nil end,
		db = function()
			return H.db({ chars = { ["Liara-RealmA"] = H.charStore({}) } })
		end })
	ns.DeleteChar("Liara-RealmA")
	assertTrue(_G.ExactItemCountDB.chars["Liara-RealmA"] ~= nil,
		"refused: with the own key unknown, any key could be ourselves")
end)

-- ---------------------------------------------------------------- pure helpers

test("is_gear_equip_loc_gate", function()
	local ns = loadAddon({ noPEW = true })
	for _, loc in ipairs({ "INVTYPE_HEAD", "INVTYPE_WEAPON",
		"INVTYPE_PROFESSION_TOOL", "INVTYPE_PROFESSION_GEAR" }) do
		assertTrue(ns.IsGearEquipLoc(loc), loc .. " is gear")
	end
	for _, loc in ipairs({ "", "INVTYPE_BAG", "INVTYPE_NON_EQUIP", "INVTYPE_NON_EQUIP_IGNORE" }) do
		assertTrue(not ns.IsGearEquipLoc(loc), loc .. " is not gear")
	end
	assertTrue(not ns.IsGearEquipLoc(nil), "nil is not gear")
end)

test("parse_upgrade_track_default_format", function()
	local ns = loadAddon({ noPEW = true })
	local name, step, max = ns.ParseUpgradeTrack({
		{ leftText = "Soulbound" },
		{ leftText = "Upgrade Level: Hero 2/6" },
	})
	assertEq(name, "Hero")
	assertEq(step, 2)
	assertEq(max, 6)
	assertEq(ns.ParseUpgradeTrack({ { leftText = "Upgrade Level:  2/6" } }), nil) -- empty name
	assertEq(ns.ParseUpgradeTrack({ { leftText = "Nothing here" } }), nil)
	assertEq(ns.ParseUpgradeTrack({}), nil)
	assertEq(ns.ParseUpgradeTrack(nil), nil)
end)

test("parse_upgrade_track_escapes_magic_chars", function()
	local ns = loadAddon({ noPEW = true, setup = function()
		_G.ITEM_UPGRADE_TOOLTIP_FORMAT_STRING = "(Upgrade+) %s [%d/%d]."
	end })
	local name, step, max = ns.ParseUpgradeTrack({ { leftText = "(Upgrade+) Hero [2/6]." } })
	assertEq(name, "Hero")
	assertEq(step, 2)
	assertEq(max, 6)
end)

test("parse_upgrade_track_positional_locale", function()
	local ns = loadAddon({ noPEW = true, setup = function()
		-- A positional-reordered locale shape: progress first, track name last. The
		-- recorded token order must map each capture back to its meaning.
		_G.ITEM_UPGRADE_TOOLTIP_FORMAT_STRING = "%2$d/%3$d: %1$s"
	end })
	local name, step, max = ns.ParseUpgradeTrack({ { leftText = "2/6: Hero" } })
	assertEq(name, "Hero")
	assertEq(step, 2)
	assertEq(max, 6)
end)

test("parse_upgrade_track_tolerates_missing_format", function()
	local ns = loadAddon({ setup = function(S)
		_G.ITEM_UPGRADE_TOOLTIP_FORMAT_STRING = nil
		S.defineItem(102, { name = "Dropped Helm", equipLoc = "INVTYPE_HEAD" })
		S.setContainer(0, {
			{ id = 102, count = 1, ilvl = 613, track = { name = "Hero", step = 2, max = 6 } },
		})
	end })
	assertEq(ns.ParseUpgradeTrack({ { leftText = "Upgrade Level: Hero 2/6" } }), nil)
	local group = _G.ExactItemCountDB.chars[H.OWN].bags.items[102].groups[613]
	assertEq(group.track, nil) -- the scan still succeeds, just tracklessly
end)
