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

-- ---------------------------------------------------------------- auction scans

test("auction_scan_on_owned_update", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
	end })
	S.fire("AUCTION_HOUSE_SHOW")
	assertEq(S.calls.queryOwned, 1) -- the owned-listings query fires at open
	S.ownedAuctions = {
		{ itemKey = { itemID = 101, itemLevel = 658 }, quantity = 1, status = 0,
			itemLink = S.link(101, "r5", { ilvl = 658, crafted = 5 }) },
		-- itemKey carries no ilvl but the link does: the fallback fills it in
		{ itemKey = { itemID = 101, itemLevel = 0 }, quantity = 1, status = 0,
			itemLink = S.link(101, "r4", { ilvl = 645, crafted = 4 }) },
		-- a commodity: no hyperlink, no meaningful ilvl -- lands in the ilvl-0 group
		{ itemKey = { itemID = 201, itemLevel = 0 }, quantity = 40, status = 0 },
	}
	S.fire("OWNED_AUCTIONS_UPDATED")
	local snap = _G.ExactItemCountDB.chars[H.OWN].auctions
	assertEq(snap.scannedAt, 1000)
	assertEq(snap.items[101].total, 2)
	assertEq(snap.items[101].groups[658].count, 1)
	assertEq(snap.items[101].groups[645].count, 1)
	assertEq(snap.items[201].total, 40)
	assertEq(snap.items[201].groups[0].count, 40)
	-- listings carry no readable tooltip data: no track fetch may ever happen
	assertEq(S.calls.bagTip + S.calls.invTip, 0)
end)

test("auction_scan_sold_excluded_lenient_fields", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
	end })
	S.fire("AUCTION_HOUSE_SHOW")
	S.ownedAuctions = {
		{ itemKey = { itemID = 301 }, quantity = 2, status = 1 }, -- sold: the item is gone
		{ itemKey = { itemID = 301 }, quantity = 3 },             -- absent status: still counted
		{ itemKey = { itemID = 301 } },                           -- absent quantity: one item
		{ itemKey = {}, quantity = 9 },                           -- no itemID: skipped
		{ quantity = 9 },                                         -- no itemKey at all: skipped
	}
	S.fire("OWNED_AUCTIONS_UPDATED")
	local items = _G.ExactItemCountDB.chars[H.OWN].auctions.items
	assertEq(items[301].total, 4)
	local n = 0
	for _ in pairs(items) do n = n + 1 end
	assertEq(n, 1)
end)

test("auction_scan_only_while_open_and_close_idempotent", function()
	local _, S = loadAddon({ setup = function(S) S.defineItem(301, { name = "Acorn" }) end })
	S.ownedAuctions = { { itemKey = { itemID = 301 }, quantity = 2, status = 0 } }
	S.fire("OWNED_AUCTIONS_UPDATED") -- AH not open: a stray event must not scan
	assertEq(_G.ExactItemCountDB.chars[H.OWN].auctions, nil)
	S.fire("AUCTION_HOUSE_SHOW")
	S.fire("OWNED_AUCTIONS_UPDATED")
	local char = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(char.auctions.items[301].total, 2)
	S.fire("AUCTION_HOUSE_CLOSED")
	S.fire("AUCTION_HOUSE_CLOSED") -- a double close stays idempotent (the bank precedent)
	S.ownedAuctions = { { itemKey = { itemID = 301 }, quantity = 9, status = 0 } }
	S.fire("OWNED_AUCTIONS_UPDATED")
	assertEq(char.auctions.items[301].total, 2) -- closed: the snapshot keeps its last scan
end)

test("auction_never_wipes_nil_or_partial_but_empty_swaps", function()
	local _, S = loadAddon({ setup = function(S) S.defineItem(301, { name = "Acorn" }) end })
	S.fire("AUCTION_HOUSE_SHOW")
	S.ownedAuctions = { { itemKey = { itemID = 301 }, quantity = 2, status = 0 } }
	S.fire("OWNED_AUCTIONS_UPDATED")
	local char = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(char.auctions.scannedAt, 1000)
	S.advance(100) -- a successful rescan from here on would restamp scannedAt to 1100

	S.ownedAuctions = nil -- no result set in hand
	S.fire("OWNED_AUCTIONS_UPDATED")
	assertEq(char.auctions.scannedAt, 1000)

	S.ownedAuctions = {}
	S.fullOwnedResults = false -- partial pages must not swap in an under-count
	S.fire("OWNED_AUCTIONS_UPDATED")
	assertEq(char.auctions.scannedAt, 1000)
	assertEq(char.auctions.items[301].total, 2)

	S.fullOwnedResults = true -- a complete empty result IS real: everything sold/collected
	S.fire("OWNED_AUCTIONS_UPDATED")
	assertEq(char.auctions.scannedAt, 1100)
	assertEq(next(char.auctions.items), nil)
end)

-- ---------------------------------------------------------------- mail scans

test("mail_scan_on_inbox_update", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(102, { name = "Dropped Helm", equipLoc = "INVTYPE_HEAD" })
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		S.setInbox({
			{ sender = "Someone", attachments = {
				{ id = 102, count = 1, ilvl = 613, track = { name = "Hero", step = 2, max = 6 } },
				{ id = 201, count = 20 },
			} },
			{ sender = "Goldie", money = 500 }, -- money-only mail: gold is not an item
		})
	end })
	S.fire("MAIL_SHOW")
	assertEq(S.calls.checkInbox, 1) -- the inbox query fires on the open edge...
	assertEq(_G.ExactItemCountDB.chars[H.OWN].mail, nil) -- ...but no scan until data arrives
	S.fire("MAIL_INBOX_UPDATE")
	local snap = _G.ExactItemCountDB.chars[H.OWN].mail
	assertEq(snap.scannedAt, 1000)
	assertEq(snap.items[102].total, 1)
	assertEq(snap.items[102].groups[613].count, 1)
	assertEq(snap.items[102].groups[613].track, { name = "Hero", step = 2, max = 6 })
	assertEq(snap.items[201].total, 20)
	assertEq(snap.items[201].groups[0].count, 20) -- no ilvl in mail: link-then-0 fallback
	assertEq(S.calls.inboxTip, 1) -- track fetched once per NEW GEAR group only
end)

test("mail_checkinbox_gated_by_throttle", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
		S.canCheckInbox = false
		S.setInbox({ { sender = "X", attachments = { { id = 301, count = 3 } } } })
	end })
	S.fire("MAIL_SHOW")
	assertEq(S.calls.checkInbox, 0) -- throttled: the query is skipped, no timer of our own
	S.fire("MAIL_INBOX_UPDATE") -- Blizzard's queued retry still lands data eventually
	assertEq(_G.ExactItemCountDB.chars[H.OWN].mail.items[301].total, 3)
end)

test("mail_scan_only_while_open_and_close_idempotent", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
		S.setInbox({ { sender = "X", attachments = { { id = 301, count = 3 } } } })
	end })
	S.fire("MAIL_INBOX_UPDATE") -- mailbox not open: a stray event must not scan
	assertEq(_G.ExactItemCountDB.chars[H.OWN].mail, nil)
	S.fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 17) -- the PRIMARY open signal
	S.fire("MAIL_SHOW") -- the belt fires too: the open stays edge-triggered
	assertEq(S.calls.checkInbox, 1)
	S.fire("MAIL_INBOX_UPDATE")
	local char = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(char.mail.items[301].total, 3)
	S.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 5) -- a NON-mail interaction hide: ignored
	S.setInbox({ { sender = "X", attachments = { { id = 301, count = 9 } } } })
	S.fire("MAIL_INBOX_UPDATE") -- still open: rescans (collection shrinks counts live)
	assertEq(char.mail.items[301].total, 9)
	S.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 17)
	S.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 17) -- a double close stays idempotent
	S.setInbox({ { sender = "X", attachments = { { id = 301, count = 1 } } } })
	S.fire("MAIL_INBOX_UPDATE")
	assertEq(char.mail.items[301].total, 9) -- closed: the snapshot keeps its last scan
	S.fire("MAIL_SHOW") -- reopen, then the MAIL_CLOSED belt closes too
	S.fire("MAIL_CLOSED")
	S.fire("MAIL_INBOX_UPDATE")
	assertEq(char.mail.items[301].total, 9)
end)

test("mail_never_wipes_truncated_inbox_but_empty_swaps", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
		S.setInbox({ { sender = "X", attachments = { { id = 301, count = 3 } } } })
	end })
	S.fire("MAIL_SHOW")
	S.fire("MAIL_INBOX_UPDATE")
	local char = _G.ExactItemCountDB.chars[H.OWN]
	-- Seed a pending credit: the truncation guard must protect it too (the clear rides
	-- the snapshot swap, and only a full read supersedes the optimistic data).
	char.mailPending = { H.pending(900, { { id = 301, count = 1 } }) }
	assertEq(char.mail.scannedAt, 1000)
	S.advance(100) -- a successful rescan from here on would restamp scannedAt to 1100

	S.inboxTotal = 105 -- server total beyond the downloaded page: this scan can't see it all
	S.fire("MAIL_INBOX_UPDATE")
	assertEq(char.mail.scannedAt, 1000)
	assertEq(char.mail.items[301].total, 3)
	assertTrue(char.mailPending ~= nil, "pending credits survive a truncated scan")

	S.inboxTotal = nil
	S.setInbox({}) -- a complete EMPTY inbox is a real result: everything collected
	S.fire("MAIL_INBOX_UPDATE")
	assertEq(char.mail.scannedAt, 1100)
	assertEq(next(char.mail.items), nil)
	assertEq(char.mailPending, nil) -- and the successful swap clears the credits
end)

test("mail_nil_numitems_keeps_snapshot", function()
	-- API surprise: GetInboxNumItems returning nothing must keep the snapshot, never wipe.
	local _, S = loadAddon({
		setup = function(S)
			S.defineItem(301, { name = "Acorn" })
			_G.GetInboxNumItems = function() return nil end -- frozen into Core's local at load
		end,
		db = function(S)
			return H.db({ chars = { [H.OWN] = H.charStore({
				mail = H.dbItems({ { id = 301, count = 3 } }),
			}) } })
		end, noPEW = true })
	S.fire("MAIL_SHOW")
	S.fire("MAIL_INBOX_UPDATE")
	local char = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(char.mail.scannedAt, 900) -- the fixture snapshot, untouched
	assertEq(char.mail.items[301].total, 3)
end)

test("mail_cod_excluded_unless_known_sender", function()
	local _, S = loadAddon({
		setup = function(S)
			S.defineItem(301, { name = "Acorn" })
			S.setInbox({
				{ sender = "Stranger", cod = 500, attachments = { { id = 301, count = 10 } } },
				{ sender = "liara", cod = 500, attachments = { { id = 301, count = 3 } } },
				{ sender = "bram-Azjol-Nerub", cod = 500, attachments = { { id = 301, count = 2 } } },
				{ sender = "Stranger", attachments = { { id = 301, count = 1 } } },
			})
		end,
		db = function()
			return H.db({ chars = {
				[H.OWN] = H.charStore({}),
				["Liara-TestRealm"] = H.charStore({}),
				["Bram-AzjolNerub"] = H.charStore({}),
			} })
		end })
	S.fire("MAIL_SHOW")
	S.fire("MAIL_INBOX_UPDATE")
	-- A stranger's COD package isn't owned until paid -> skipped. A known character's
	-- COD is own goods moving between alts -> counted, whether typed bare (own realm)
	-- or in the cross-realm Name-Realm form (case- and separator-insensitive). Plain
	-- non-COD mail from anyone is a gift in hand -> counted.
	assertEq(_G.ExactItemCountDB.chars[H.OWN].mail.items[301].total, 6)
end)

test("mail_scan_nonempty_supersedes_pending", function()
	-- The supersede rides ANY successful snapshot swap, not just the empty-inbox one
	-- (locked above): a non-empty full read replaces the optimistic credits with inbox
	-- reality wholesale.
	local _, S = loadAddon({
		setup = function(S)
			S.defineItem(301, { name = "Acorn" })
			S.setInbox({ { sender = "X", attachments = { { id = 301, count = 3 } } } })
		end,
		db = function()
			return H.db({ chars = { [H.OWN] = H.charStore({
				mailPending = { H.pending(900, { { id = 301, count = 4 } }) },
			}) } })
		end, noPEW = true })
	S.fire("MAIL_SHOW")
	S.fire("MAIL_INBOX_UPDATE")
	local own = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(own.mail.items[301].total, 3)
	assertEq(own.mailPending, nil)
end)

test("mail_pending_never_merged_into_snapshot", function()
	-- Credits are optimistic DISPLAY data: they are never written into the
	-- authoritative inbox snapshot -- not while standing, and not by the supersede
	-- (which simply drops them; the inbox then reflects reality on its own).
	local _, S = loadAddon({
		setup = function(S)
			S.defineItem(301, { name = "Acorn" })
			S.defineItem(302, { name = "Birch" })
			S.setInbox({ { sender = "X", attachments = { { id = 301, count = 3 } } } })
		end,
		db = function()
			return H.db({ chars = { [H.OWN] = H.charStore({
				mail = H.dbItems({ { id = 301, count = 1 } }),
				mailPending = { H.pending(900, { { id = 302, count = 4 } }) },
			}) } })
		end, noPEW = true })
	local own = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(own.mail.items[302], nil) -- standing credit: absent from the stored snapshot
	S.fire("MAIL_SHOW")
	S.fire("MAIL_INBOX_UPDATE")
	assertEq(own.mail.items[301].total, 3)
	assertEq(own.mail.items[302], nil) -- superseded means dropped, never merged in
	assertEq(own.mailPending, nil)
end)

-- ---------------------------------------------------------------- send crediting

test("send_credit_commit_on_success", function()
	local _, S = loadAddon({ db = function(S)
		S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
		return H.db({ chars = { ["Liara-TestRealm"] = H.charStore({}) } })
	end })
	S.fire("MAIL_SHOW")
	S.setSendSlot(1, { id = 101, count = 1, ilvl = 658,
		track = { name = "Hero", step = 4, max = 6 } })
	S.fire("MAIL_SEND_INFO_UPDATE")
	S.advance(50)
	_G.SendMail("Liara", "goods", "")
	S.fire("MAIL_SEND_SUCCESS")
	local pending = _G.ExactItemCountDB.chars["Liara-TestRealm"].mailPending
	assertEq(#pending, 1)
	assertEq(pending[1].sentAt, 1050)
	assertEq(pending[1].items[101].total, 1)
	assertEq(pending[1].items[101].groups[658].count, 1)
	assertEq(pending[1].items[101].groups[658].track.name, "Hero")
	assertTrue(pending[1].items[101].groups[658].link ~= nil, "representative link stored")
	-- One gear-gated fetch per fresh slot read: the event snapshot and the hook re-read.
	assertEq(S.calls.sendTip, 2)
end)

test("send_credit_hook_reread_vs_event_snapshot", function()
	-- (a) Slots already cleared when the post-hook runs (the unverified-in-game case):
	-- the event-built snapshot is credited instead.
	local _, S = loadAddon({ db = function(S)
		S.defineItem(301, { name = "Acorn" })
		return H.db({ chars = { ["Liara-TestRealm"] = H.charStore({}) } })
	end })
	S.fire("MAIL_SHOW")
	S.setSendSlot(1, { id = 301, count = 5 })
	S.fire("MAIL_SEND_INFO_UPDATE")
	S.sendSlotsClearOnSend = true
	_G.SendMail("Liara")
	S.fire("MAIL_SEND_SUCCESS")
	assertEq(_G.ExactItemCountDB.chars["Liara-TestRealm"].mailPending[1].items[301].total, 5)

	-- (b) Slots readable inside the hook and FRESHER than the event snapshot: the
	-- re-read wins.
	local _, S2 = loadAddon({ db = function(S3)
		S3.defineItem(301, { name = "Acorn" })
		return H.db({ chars = { ["Liara-TestRealm"] = H.charStore({}) } })
	end })
	S2.fire("MAIL_SHOW")
	S2.setSendSlot(1, { id = 301, count = 5 })
	S2.fire("MAIL_SEND_INFO_UPDATE")
	S2.setSendSlot(1, { id = 301, count = 9 }) -- changed without another event
	_G.SendMail("Liara")
	S2.fire("MAIL_SEND_SUCCESS")
	assertEq(_G.ExactItemCountDB.chars["Liara-TestRealm"].mailPending[1].items[301].total, 9)
end)

test("send_credit_discard_paths", function()
	local _, S = loadAddon({ db = function(S)
		S.defineItem(301, { name = "Acorn" })
		return H.db({ chars = { ["Liara-TestRealm"] = H.charStore({}) } })
	end })
	local liara = _G.ExactItemCountDB.chars["Liara-TestRealm"]
	S.fire("MAIL_SHOW")
	S.setSendSlot(1, { id = 301, count = 5 })
	S.fire("MAIL_SEND_INFO_UPDATE")
	-- Failed send: the stash drops; a stray late SUCCESS finds nothing and no-ops (its
	-- snapshot clear is correct -- a real SUCCESS means the slots emptied).
	_G.SendMail("Liara")
	S.fire("MAIL_FAILED")
	S.fire("MAIL_SEND_SUCCESS")
	assertEq(liara.mailPending, nil)
	-- Cancelled confirmation (MAIL_UNLOCK_SEND_ITEMS -- neither SUCCESS nor FAILED ever
	-- fires): the stash drops but the slot snapshot survives, so a re-send with the
	-- slots unreadable still credits from it. (Re-attaching fires the INFO_UPDATE.)
	S.fire("MAIL_SEND_INFO_UPDATE")
	_G.SendMail("Liara")
	S.fire("MAIL_UNLOCK_SEND_ITEMS")
	S.sendSlots = {} -- hook re-read now finds nothing; only the kept snapshot can credit
	_G.SendMail("Liara")
	S.fire("MAIL_SEND_SUCCESS")
	assertEq(liara.mailPending[1].items[301].total, 5)
	-- Mailbox closed mid-flight: everything discards.
	liara.mailPending = nil
	S.fire("MAIL_SHOW")
	S.setSendSlot(1, { id = 301, count = 5 })
	S.fire("MAIL_SEND_INFO_UPDATE")
	_G.SendMail("Liara")
	S.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 17)
	S.fire("MAIL_SEND_SUCCESS")
	assertEq(liara.mailPending, nil)
end)

test("send_credit_unknown_recipient_uncredited", function()
	local _, S = loadAddon({ db = function(S)
		S.defineItem(301, { name = "Acorn" })
		return H.db({ chars = { ["Liara-TestRealm"] = H.charStore({}) } })
	end })
	S.fire("MAIL_SHOW")
	S.setSendSlot(1, { id = 301, count = 5 })
	S.fire("MAIL_SEND_INFO_UPDATE")
	_G.SendMail("Randomguy") -- not a scanned character: a gift, counted nowhere
	S.fire("MAIL_SEND_SUCCESS")
	_G.SendMail("Liara-OtherRealm") -- same name, different realm: still a stranger
	S.fire("MAIL_SEND_SUCCESS")
	for key, char in pairs(_G.ExactItemCountDB.chars) do
		assertTrue(char.mailPending == nil, "no pending credited under " .. key)
	end
	-- A plain letter (no attachments anywhere) to a known alt appends no batch either.
	S.sendSlots = {}
	S.fire("MAIL_SEND_INFO_UPDATE")
	_G.SendMail("Liara")
	S.fire("MAIL_SEND_SUCCESS")
	assertEq(_G.ExactItemCountDB.chars["Liara-TestRealm"].mailPending, nil)
end)

test("send_credit_own_key_commit", function()
	-- Mail-to-self: KnownCharKey has no self-exclusion and the commit is a plain
	-- db.chars lookup, so an own-name recipient credits the OWN key -- and the batch
	-- joins the own `mail` share, not an alt number. (The AH purchase/cancel credits
	-- ride exactly this own-key path.)
	local ns, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
	end })
	S.fire("MAIL_SHOW")
	S.setSendSlot(1, { id = 301, count = 5 })
	S.fire("MAIL_SEND_INFO_UPDATE")
	_G.SendMail("tester") -- bare own name, case-insensitive
	S.fire("MAIL_SEND_SUCCESS")
	local own = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(#own.mailPending, 1)
	assertEq(own.mailPending[1].items[301].total, 5)
	assertEq(ns.Get(301).sources, { mail = 5 })
end)

test("send_credit_recipient_normalization_positive", function()
	-- The positive twin of the unknown-recipient test: a lowercase bare name lands on
	-- the own realm's key, and a typed "Name-Realm With Spaces" normalizes the way
	-- GetNormalizedRealmName does (spaces stripped, case-insensitive).
	local _, S = loadAddon({ db = function(S)
		S.defineItem(301, { name = "Acorn" })
		return H.db({ chars = {
			["Liara-TestRealm"] = H.charStore({}),
			["Bram-AzjolNerub"] = H.charStore({}),
		} })
	end })
	S.fire("MAIL_SHOW")
	S.setSendSlot(1, { id = 301, count = 5 })
	S.fire("MAIL_SEND_INFO_UPDATE")
	_G.SendMail("liara")
	S.fire("MAIL_SEND_SUCCESS")
	assertEq(_G.ExactItemCountDB.chars["Liara-TestRealm"].mailPending[1].items[301].total, 5)
	_G.SendMail("bram-Azjol Nerub") -- the hook's slot re-read still finds the attachment
	S.fire("MAIL_SEND_SUCCESS")
	assertEq(_G.ExactItemCountDB.chars["Bram-AzjolNerub"].mailPending[1].items[301].total, 5)
end)

test("mail_pending_pruned_at_load_and_skipped_at_read", function()
	local DAY = 24 * 60 * 60
	local ns, S = loadAddon({ noPEW = true,
		setup = function(S) S.setTime(40 * DAY) end,
		db = function(S)
			S.defineItem(301, { name = "Acorn" })
			return H.db({ chars = {
				[H.OWN] = H.charStore({ bags = H.dbItems({ { id = 301, count = 1 } }) }),
				["Liara-TestRealm"] = H.charStore({ mailPending = {
					{ sentAt = 39 * DAY, items = H.dbItems({ { id = 301, count = 5 } }) }, -- 1d old
					{ sentAt = 5 * DAY, items = H.dbItems({ { id = 301, count = 9 } }) },  -- 35d old
					{ sentAt = 9 * DAY, items = H.dbItems({ { id = 301, count = 7 } }) },  -- exactly 31d: expired (strict <)
					"junk", -- hand-edited garbage must prune, not error
				} }),
				["Bram-TestRealm"] = H.charStore({ mailPending = {
					{ sentAt = 1 * DAY, items = H.dbItems({ { id = 301, count = 2 } }) },
				} }),
			} })
		end })
	local liara = _G.ExactItemCountDB.chars["Liara-TestRealm"]
	assertEq(#liara.mailPending, 1) -- the expired batches (35d and the 31d boundary) and the junk pruned at load
	assertEq(liara.mailPending[1].sentAt, 39 * DAY)
	assertEq(_G.ExactItemCountDB.chars["Bram-TestRealm"].mailPending, nil) -- emptied -> nil
	assertEq(ns.Get(301).total, 6) -- own bags 1 + Liara's fresh credit 5
	-- A batch fresh at load can cross the 31-day line mid-session: it drops out of the
	-- read without a reload.
	S.advance(31 * DAY)
	assertEq(ns.Get(301).total, 1)
	assertEq(ns.Get(301).sources.alts, nil)
end)

-- ------------------------------------------------- AH purchase/cancel crediting

test("commodity_credit_commit_on_purchased", function()
	local ns, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn", reagent = 2 })
	end })
	S.fire("AUCTION_HOUSE_SHOW")
	S.advance(50)
	_G.C_AuctionHouse.StartCommoditiesPurchase(301, 100, 77) -- Blizzard passes a 3rd arg (unitPrice)
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 100)
	S.fire("COMMODITY_PURCHASED", 301, 60) -- partial fill: the event's quantity wins
	local own = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(#own.mailPending, 1)
	assertEq(own.mailPending[1].sentAt, 1050)
	assertEq(own.mailPending[1].items[301].total, 60)
	assertEq(own.mailPending[1].items[301].groups[0].count, 60) -- commodities: the ilvl-0 group
	assertTrue(own.mailPending[1].items[301].link ~= nil, "best-effort representative link stored")
	assertEq(ns.Get(301).sources, { mail = 60 })
	-- The commit consumed the intent: a duplicate event credits nothing more, and
	-- neither do the other finalization signals landing after it.
	S.fire("COMMODITY_PURCHASED", 301, 60)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", 60)
	assertEq(#own.mailPending, 1)
	assertEq(own.mailPending[1].items[301].total, 60)
end)

test("commodity_credit_commit_on_succeeded", function()
	-- COMMODITY_PURCHASED has no consumers in Blizzard's 12.1 client and never showed
	-- in an in-game trace: COMMODITY_PURCHASE_SUCCEEDED (which Blizzard's own dialog
	-- waits on) is the working commit signal, crediting the REQUESTED quantity.
	local ns, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
	end })
	S.fire("AUCTION_HOUSE_SHOW")
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 20)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	local own = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(#own.mailPending, 1)
	assertEq(own.mailPending[1].items[301].total, 20)
	assertEq(ns.Get(301).sources, { mail = 20 })
	S.fire("COMMODITY_PURCHASE_SUCCEEDED") -- consumed: a duplicate commits nothing
	assertEq(#own.mailPending, 1)
end)

test("commodity_won_refines_before_and_after_commit", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
	end })
	local function pending() return _G.ExactItemCountDB.chars[H.OWN].mailPending end
	S.fire("AUCTION_HOUSE_SHOW")
	-- Toast BEFORE the commit: the actual fill rides the slot into the commit.
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 100)
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", 60)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	assertEq(pending()[1].items[301].total, 60)
	-- Toast AFTER the commit: the committed batch shrinks in place -- downward only,
	-- and repeats / larger / junk quantities are all no-ops.
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 100)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	assertEq(pending()[2].items[301].total, 100)
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", 80)
	assertEq(pending()[2].items[301].total, 80)
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", 80)
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", 90)
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", 0)
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", "junk")
	assertEq(pending()[2].items[301].total, 80)
	-- A toast bigger than the REQUEST while a slot is pending proves foreignness (a
	-- fill can't exceed its request): ignored, the request commits untouched.
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 10)
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", 11)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	assertEq(pending()[3].items[301].total, 10)
	-- A stray FAILED after a commit retracts nothing, and the committed reference
	-- survives it -- a late fill report can still shrink the batch.
	S.fire("COMMODITY_PURCHASE_FAILED")
	assertEq(#pending(), 3)
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", 4)
	assertEq(pending()[3].items[301].total, 4)
end)

test("commodity_signal_order_permutations", function()
	-- One purchase (request 100, actual fill 60), every arrival order of the three
	-- finalization signals: exactly one batch, and the final quantity converges on
	-- the actual fill whenever a quantity-bearing signal was seen.
	local orders = {
		{ "P", "S", "W" }, { "P", "W", "S" }, { "S", "P", "W" },
		{ "S", "W", "P" }, { "W", "S", "P" }, { "W", "P", "S" },
	}
	for _, order in ipairs(orders) do
		local _, S = loadAddon({ setup = function(S)
			S.defineItem(301, { name = "Acorn" })
		end })
		S.fire("AUCTION_HOUSE_SHOW")
		_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 100)
		for _, sig in ipairs(order) do
			if sig == "P" then
				S.fire("COMMODITY_PURCHASED", 301, 60)
			elseif sig == "S" then
				S.fire("COMMODITY_PURCHASE_SUCCEEDED")
			else
				S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", 60)
			end
		end
		local label = table.concat(order, ",")
		local pending = _G.ExactItemCountDB.chars[H.OWN].mailPending
		assertEq(#pending, 1, "one batch under order " .. label)
		assertEq(pending[1].items[301].total, 60, "actual fill under order " .. label)
	end
end)

test("commodity_back_to_back_same_item_no_phantom", function()
	-- The steal hazard the refiner design exists for: purchase A commits, purchase B
	-- of the SAME item starts, then A's won-toast straggles in. It must neither
	-- commit against B's slot (B hasn't finalized -- a phantom if B then fails) nor
	-- touch anything else.
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
	end })
	local function pending() return _G.ExactItemCountDB.chars[H.OWN].mailPending end
	S.fire("AUCTION_HOUSE_SHOW")
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 100)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	assertEq(#pending(), 1)
	-- B starts (Start wipes the committed reference; Confirm stashes B's intent).
	_G.C_AuctionHouse.StartCommoditiesPurchase(301, 50, 77)
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 50)
	-- A's straggler toast: 80 exceeds B's request -> ignored entirely.
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", 80)
	-- Branch 1: B fails -> still exactly one batch, untouched.
	S.fire("COMMODITY_PURCHASE_FAILED")
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	assertEq(#pending(), 1)
	assertEq(pending()[1].items[301].total, 100)
	-- Branch 2: a fresh B succeeds -> two correct batches.
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 50)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	assertEq(#pending(), 2)
	assertEq(pending()[2].items[301].total, 50)
end)

test("commodity_tier_name_collision_undercount_only", function()
	-- Quality tiers are distinct itemIDs sharing one display name, so the toast's
	-- name cannot distinguish them. The refiner may cross-talk between back-to-back
	-- tier purchases -- accepted because every path is downward: the counts can
	-- undercount until the inbox scan, never overcount.
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn", reagent = 1 })
		S.defineItem(302, { name = "Acorn", reagent = 2 })
	end })
	local function pending() return _G.ExactItemCountDB.chars[H.OWN].mailPending end
	S.fire("AUCTION_HOUSE_SHOW")
	-- Committed tier-2 batch; a tier-1 toast (same name, smaller qty) wrongly shrinks
	-- it -- undercount, tolerated.
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(302, 100)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", 30)
	assertEq(pending()[1].items[302].total, 30)
	-- Slot path: a pending tier-1 purchase accepts a same-name toast's quantity --
	-- the commit clamps to min(request, toast), again undercount at worst.
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 50)
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", 20)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	assertEq(pending()[2].items[301].total, 20)
	-- Nothing anywhere grew: 100 -> 30 and 50 -> 20 only ever shrank.
end)

test("commodity_won_unresolved_name_permissive_stash_skipped_adjust", function()
	-- An item the cache can't resolve (GetItemInfo nil): the slot stash stays
	-- permissive (the slot's itemID is the real gate), but the post-commit adjust
	-- requires a POSITIVE name match and is skipped.
	local _, S = loadAddon() -- itemID 999 deliberately never defined
	local function pending() return _G.ExactItemCountDB.chars[H.OWN].mailPending end
	S.fire("AUCTION_HOUSE_SHOW")
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(999, 40)
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Whatever", 25)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	assertEq(pending()[1].items[999].total, 25)
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Whatever", 10)
	assertEq(pending()[1].items[999].total, 25) -- adjust skipped: name can't confirm
end)

test("commodity_credit_demoted_slot_commits", function()
	-- Blizzard's BuyDialog hides on success and its OnHide calls
	-- CancelCommoditiesPurchase; after a mid-session /reload Blizzard's frames receive
	-- events first, so that cancel can land BEFORE the purchase event reaches this
	-- addon. The demoted intent must still commit -- exactly once.
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
	end })
	S.fire("AUCTION_HOUSE_SHOW")
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 20)
	_G.C_AuctionHouse.CancelCommoditiesPurchase() -- the dialog's hide
	_G.C_AuctionHouse.CancelCommoditiesPurchase() -- a second call must not wipe the slot
	S.fire("COMMODITY_PURCHASED", 301, 20)
	local own = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(#own.mailPending, 1)
	assertEq(own.mailPending[1].items[301].total, 20)
	-- The demoted slot must commit through SUCCEEDED too -- on 12.1 that IS the
	-- signal, and the dialog's hide (-> demote) precedes it in the /reload order.
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 8)
	_G.C_AuctionHouse.CancelCommoditiesPurchase()
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	assertEq(#own.mailPending, 2)
	assertEq(own.mailPending[2].items[301].total, 8)
	-- Starting a NEW quote flow drops whatever unresolved state preceded it.
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 5)
	_G.C_AuctionHouse.StartCommoditiesPurchase(301, 7, 77)
	S.fire("COMMODITY_PURCHASED", 301, 5)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	assertEq(#own.mailPending, 2)
end)

test("commodity_credit_guards", function()
	-- Only a finalized purchase matching a recorded intent may credit.
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
		S.defineItem(302, { name = "Birch" })
	end })
	local function pending() return _G.ExactItemCountDB.chars[H.OWN].mailPending end
	S.fire("AUCTION_HOUSE_SHOW")
	-- No intent in hand: a PURCHASED may be a buyer taking YOUR listing (whether the
	-- event fires seller-side is unverified -- the gate makes it moot), a SUCCEEDED
	-- has nothing to describe, and a won-toast with neither slot nor committed batch
	-- refines nothing.
	S.fire("COMMODITY_PURCHASED", 301, 10)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	S.fire("AUCTION_HOUSE_SHOW_COMMODITY_WON_NOTIFICATION", "Acorn", 10)
	assertEq(pending(), nil)
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 10)
	-- Wrong item, or a quantity above the request (a fill never exceeds it): not our
	-- purchase -- and the intent survives for the real resolution.
	S.fire("COMMODITY_PURCHASED", 302, 10)
	S.fire("COMMODITY_PURCHASED", 301, 11)
	assertEq(pending(), nil)
	S.fire("COMMODITY_PURCHASED", 301, 10)
	assertEq(pending()[1].items[301].total, 10)
	-- A failed purchase discards; a later event finds nothing.
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 10)
	S.fire("COMMODITY_PURCHASE_FAILED")
	S.fire("COMMODITY_PURCHASED", 301, 10)
	assertEq(#pending(), 1)
	-- A dead quote discards the demoted slot too.
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 10)
	_G.C_AuctionHouse.CancelCommoditiesPurchase()
	S.fire("COMMODITY_PRICE_UNAVAILABLE")
	S.fire("COMMODITY_PURCHASED", 301, 10)
	assertEq(#pending(), 1)
	-- AH close discards; a straggler event after close credits nothing.
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 10)
	S.fire("AUCTION_HOUSE_CLOSED")
	S.fire("COMMODITY_PURCHASED", 301, 10)
	assertEq(#pending(), 1)
	-- And with the AH closed, a stray Confirm plants no intent at all.
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 10)
	S.fire("AUCTION_HOUSE_SHOW")
	S.fire("COMMODITY_PURCHASED", 301, 10)
	assertEq(#pending(), 1)
end)

test("buyout_credit_on_purchase_completed", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
		S.defineItem(301, { name = "Acorn" })
	end })
	local gearLink = S.link(101, "listing", { ilvl = 658, crafted = 4 })
	S.auctionsByID[9001] = { itemKey = { itemID = 101, itemLevel = 658 }, itemLink = gearLink }
	S.auctionsByID[9002] = { itemKey = { itemID = 301 } } -- no itemLevel, no link: the ilvl-0 group
	S.fire("AUCTION_HOUSE_SHOW")
	_G.C_AuctionHouse.PlaceBid(9001, 500000)
	_G.C_AuctionHouse.PlaceBid(9002, 100)
	_G.C_AuctionHouse.PlaceBid(9003, 100) -- GetAuctionInfoByID nil: an id-less entry is stashed
	local own = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(own.mailPending, nil) -- a bid alone (no completion event) never credits
	S.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 9001)
	assertEq(#own.mailPending, 1)
	assertEq(own.mailPending[1].items[101].total, 1) -- item listings are single items
	assertEq(own.mailPending[1].items[101].groups[658].count, 1)
	assertEq(own.mailPending[1].items[101].groups[658].link, gearLink)
	-- A duplicate completion no-ops (the commit consumed the stash entry).
	S.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 9001)
	assertEq(#own.mailPending, 1)
	-- 9003's item is still unknown at completion time: the commit-time retry finds
	-- nothing, commits nothing, and KEEPS the entry -- until the lookup resolves (a
	-- later completion re-fire then commits) or the AH closes.
	S.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 9003)
	assertEq(#own.mailPending, 1)
	S.auctionsByID[9003] = { itemKey = { itemID = 301 } }
	S.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 9003)
	assertEq(#own.mailPending, 2)
	assertEq(own.mailPending[2].items[301].total, 1)
	-- The observed commodity-purchase variant (auctionID 0) and junk payloads are
	-- inert, and PlaceBid with a non-positive/junk auctionID stashes nothing.
	S.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 0)
	S.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", nil)
	S.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", "junk")
	_G.C_AuctionHouse.PlaceBid(0, 100)
	_G.C_AuctionHouse.PlaceBid(nil, 100)
	S.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 0)
	assertEq(#own.mailPending, 2)
	-- Close clears the unresolved 9002 stash: its late completion credits nothing.
	S.fire("AUCTION_HOUSE_CLOSED")
	S.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 9002)
	assertEq(#own.mailPending, 2)
end)

test("buyout_won_toast_fallback_commits_idless_entry", function()
	-- When GetAuctionInfoByID never resolves (its return is fully optional and
	-- Blizzard only queries it pre-popup), the buyer's "You won an auction for
	-- [link]" toast is the fallback identifier: strictly keyed by its auctionID to a
	-- stashed bid, item parsed from the embedded link, qty always 1.
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(101, { name = "Forged Chest", equipLoc = "INVTYPE_CHEST" })
	end })
	local gearLink = S.link(101, "wontoast", { ilvl = 645, crafted = 3 })
	local WON = _G.Enum.AuctionHouseNotification.AuctionWon
	local function pending() return _G.ExactItemCountDB.chars[H.OWN].mailPending end
	S.fire("AUCTION_HOUSE_SHOW")
	_G.C_AuctionHouse.PlaceBid(9001, 500000) -- GetAuctionInfoByID nil -> id-less entry
	-- Guards: wrong notification kind, nil auctionID, unstashed auctionID, and text
	-- without a complete item link all commit nothing (the last keeps the entry).
	S.fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", 4, "Sold: " .. gearLink, 9001)
	S.fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", WON, "You won " .. gearLink, nil)
	S.fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", WON, "You won " .. gearLink, 7777)
	S.fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", WON, "You won an auction for Forged Chest", 9001)
	assertEq(pending(), nil)
	-- The real toast: link parsed, credit committed, entry consumed.
	S.fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", WON, "You won an auction for " .. gearLink .. ".", 9001)
	assertEq(#pending(), 1)
	assertEq(pending()[1].items[101].total, 1)
	assertEq(pending()[1].items[101].groups[645].count, 1) -- ilvl resolved from the parsed link
	-- Either order, exactly one credit: a completion landing after the toast no-ops.
	S.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 9001)
	S.fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", WON, "You won an auction for " .. gearLink .. ".", 9001)
	assertEq(#pending(), 1)
	-- Reverse order on a fresh bid: completion (with the lookup now resolvable)
	-- commits first, the toast then finds no entry.
	S.auctionsByID[9002] = { itemKey = { itemID = 101, itemLevel = 645 }, itemLink = gearLink }
	_G.C_AuctionHouse.PlaceBid(9002, 400000)
	S.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 9002)
	S.fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", WON, "You won an auction for " .. gearLink .. ".", 9002)
	assertEq(#pending(), 2)
end)

test("cancel_credit_on_auction_canceled", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
	end })
	local link = S.link(301, "cancelme")
	S.ownedAuctions = {
		{ auctionID = 11, itemKey = { itemID = 301, itemLevel = 0 }, quantity = 40, itemLink = link },
		{ auctionID = 12, itemKey = { itemID = 301 }, quantity = 5, status = 1 }, -- Sold
	}
	S.fire("AUCTION_HOUSE_SHOW")
	assertEq(S.calls.queryOwned, 1)
	local own = _G.ExactItemCountDB.chars[H.OWN]
	-- A sold listing can't return items (gold arrives instead): nothing is recorded.
	_G.C_AuctionHouse.CancelAuction(12)
	S.fire("AUCTION_CANCELED", 12)
	assertEq(own.mailPending, nil)
	-- A cancel event with no CancelAuction call seen commits nothing.
	S.fire("AUCTION_CANCELED", 11)
	assertEq(own.mailPending, nil)
	_G.C_AuctionHouse.CancelAuction(11)
	S.fire("AUCTION_CANCELED", 11)
	assertEq(own.mailPending[1].items[301].total, 40)
	assertEq(own.mailPending[1].items[301].groups[0].link, link)
	-- The commit nudges the owned-listings rescan so the stale listing drops promptly.
	assertEq(S.calls.queryOwned, 2)
	-- The nudged refresh (listing now gone) must not double-commit through the sweep.
	local full = S.ownedAuctions
	S.ownedAuctions = { full[2] }
	S.fire("OWNED_AUCTIONS_UPDATED")
	assertEq(#own.mailPending, 1)
	-- Close clears an unresolved cancel: a straggler event credits nothing.
	S.ownedAuctions = full
	_G.C_AuctionHouse.CancelAuction(11) -- re-stash (back in the live list fixture)
	S.fire("AUCTION_HOUSE_CLOSED")
	S.fire("AUCTION_CANCELED", 11)
	assertEq(#own.mailPending, 1)
end)

test("commodity_cancel_credit_via_owned_refresh", function()
	-- The in-game reality for STACKABLE listings: AUCTION_CANCELED fires with a junk
	-- low payload (observed: 1), never the real auctionID -- the commit rides the
	-- owned-list refresh instead: a stashed cancel whose listing vanished from a
	-- COMPLETE result set has finalized.
	local ns, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn", reagent = 2 })
	end })
	local link = S.link(301, "stack")
	S.ownedAuctions = {
		{ auctionID = 11, itemKey = { itemID = 301, itemLevel = 0 }, quantity = 40, itemLink = link },
		{ auctionID = 12, itemKey = { itemID = 301 }, quantity = 5 },
	}
	S.fire("AUCTION_HOUSE_SHOW")
	S.fire("OWNED_AUCTIONS_UPDATED")
	local own = _G.ExactItemCountDB.chars[H.OWN]
	_G.C_AuctionHouse.CancelAuction(11)
	local queriesBefore = S.calls.queryOwned
	S.fire("AUCTION_CANCELED", 1) -- junk payload: no keyed commit...
	assertEq(own.mailPending, nil)
	assertEq(S.calls.queryOwned, queriesBefore + 1) -- ...but the refresh is nudged
	-- A refresh where the listing is STILL present proves nothing.
	S.fire("OWNED_AUCTIONS_UPDATED")
	assertEq(own.mailPending, nil)
	-- A partial or unreadable result set must never imply absence.
	local without11 = { { auctionID = 12, itemKey = { itemID = 301 }, quantity = 5 } }
	S.ownedAuctions = without11
	S.fullOwnedResults = false
	S.fire("OWNED_AUCTIONS_UPDATED")
	assertEq(own.mailPending, nil)
	S.ownedAuctions = nil
	S.fire("OWNED_AUCTIONS_UPDATED")
	assertEq(own.mailPending, nil)
	-- The complete refresh without the listing commits the stash -- exactly once.
	S.ownedAuctions = without11
	S.fullOwnedResults = true
	S.fire("OWNED_AUCTIONS_UPDATED")
	assertEq(#own.mailPending, 1)
	assertEq(own.mailPending[1].items[301].total, 40)
	assertEq(own.mailPending[1].items[301].groups[0].link, link)
	S.fire("OWNED_AUCTIONS_UPDATED")
	assertEq(#own.mailPending, 1)
	-- The credit is mail; the auction scope reflects the fresh snapshot only.
	assertEq(ns.Get(301).sources, { mail = 40 })
	assertEq(ns.Get(301, { auctionsOnly = true }).sources, { auctions = 5 })
end)

test("cancel_sweep_sold_listing_never_commits", function()
	-- A cancel that raced a sale: the listing stays in the owned list with status
	-- Sold (sold listings never vanish mid-session -- collection happens at a
	-- mailbox, unreachable while the AH is open). Presence, whatever the status,
	-- means no commit; the entry dies at AH close.
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
	end })
	S.ownedAuctions = {
		{ auctionID = 11, itemKey = { itemID = 301 }, quantity = 40 },
	}
	S.fire("AUCTION_HOUSE_SHOW")
	local own = _G.ExactItemCountDB.chars[H.OWN]
	_G.C_AuctionHouse.CancelAuction(11)
	S.fire("AUCTION_CANCELED", 1)
	S.ownedAuctions = {
		{ auctionID = 11, itemKey = { itemID = 301 }, quantity = 40, status = 1 },
	}
	S.fire("OWNED_AUCTIONS_UPDATED")
	assertEq(own.mailPending, nil)
	S.fire("AUCTION_HOUSE_CLOSED")
	S.ownedAuctions = {}
	S.fire("OWNED_AUCTIONS_UPDATED") -- post-close: the flag is down, nothing sweeps
	assertEq(own.mailPending, nil)
end)

test("cancel_two_in_flight_each_commits_once", function()
	local _, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
		S.defineItem(302, { name = "Birch" })
	end })
	S.ownedAuctions = {
		{ auctionID = 11, itemKey = { itemID = 301 }, quantity = 40 },
		{ auctionID = 21, itemKey = { itemID = 302 }, quantity = 7 },
	}
	S.fire("AUCTION_HOUSE_SHOW")
	local own = _G.ExactItemCountDB.chars[H.OWN]
	_G.C_AuctionHouse.CancelAuction(11)
	_G.C_AuctionHouse.CancelAuction(21)
	-- The item listing resolves keyed; the commodity one only via the sweep.
	S.fire("AUCTION_CANCELED", 21)
	assertEq(#own.mailPending, 1)
	assertEq(own.mailPending[1].items[302].total, 7)
	S.ownedAuctions = {}
	S.fire("OWNED_AUCTIONS_UPDATED")
	assertEq(#own.mailPending, 2)
	assertEq(own.mailPending[2].items[301].total, 40)
	S.fire("OWNED_AUCTIONS_UPDATED") -- idempotent
	assertEq(#own.mailPending, 2)
end)

test("ah_credit_lifecycle_and_scope", function()
	local DAY = 24 * 60 * 60
	local ns, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
	end })
	S.fire("AUCTION_HOUSE_SHOW")
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 30)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED") -- the signal that actually fires on 12.1
	S.fire("AUCTION_HOUSE_CLOSED")
	local own = _G.ExactItemCountDB.chars[H.OWN]
	assertEq(ns.Get(301).sources, { mail = 30 })
	-- The credit is mail, never "On auction": the auction scope stays empty.
	assertEq(ns.Get(301, { auctionsOnly = true }), nil)
	-- Every filter combination keeps total == sum of sources, no zeros recorded.
	H.eachFilter(function(filter)
		local agg = ns.Get(301, filter)
		if agg then
			assertEq(agg.total, H.sumSources(agg.sources))
			H.assertNoZeros(agg.sources)
		end
	end)
	-- The own next full inbox scan supersedes the credit wholesale -- the AH mail has
	-- (or hasn't) arrived, and either way the inbox is now the authority.
	S.setInbox({ { sender = "Auction House", attachments = { { id = 301, count = 30 } } } })
	S.fire("MAIL_SHOW")
	S.fire("MAIL_INBOX_UPDATE")
	assertEq(own.mailPending, nil)
	assertEq(ns.Get(301).sources, { mail = 30 }) -- the snapshot's number now, not the credit's
	S.fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 17)
	-- A credit nobody supersedes ages out of the reads at the 31-day line.
	S.fire("AUCTION_HOUSE_SHOW")
	_G.C_AuctionHouse.ConfirmCommoditiesPurchase(301, 7)
	S.fire("COMMODITY_PURCHASE_SUCCEEDED")
	S.fire("AUCTION_HOUSE_CLOSED")
	assertEq(ns.Get(301).sources, { mail = 37 })
	S.advance(31 * DAY)
	assertEq(ns.Get(301).sources, { mail = 30 })
end)

test("cancel_double_show_never_sums_and_heals", function()
	local ns, S = loadAddon({ setup = function(S)
		S.defineItem(301, { name = "Acorn" })
	end })
	local link = S.link(301, "listed")
	S.ownedAuctions = {
		{ auctionID = 11, itemKey = { itemID = 301, itemLevel = 0 }, quantity = 40, itemLink = link },
	}
	S.fire("AUCTION_HOUSE_SHOW")
	S.fire("OWNED_AUCTIONS_UPDATED") -- the listing lands in the auctions snapshot
	_G.C_AuctionHouse.CancelAuction(11)
	S.fire("AUCTION_CANCELED", 11)
	-- Until a rescan lands, the stack shows in BOTH scopes -- the documented accepted
	-- staleness -- but the scopes never sum into one number.
	assertEq(ns.Get(301).sources, { mail = 40 })
	assertEq(ns.Get(301, { auctionsOnly = true }).sources, { auctions = 40 })
	-- The nudged rescan heals the auction side; the credit stays until the mailbox.
	S.ownedAuctions = {}
	S.fire("OWNED_AUCTIONS_UPDATED")
	assertEq(ns.Get(301, { auctionsOnly = true }), nil)
	assertEq(ns.Get(301).sources, { mail = 40 })
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
-- own bags 2@645, own bank 1@645 + 1@658, own equipped 1@658, own mail 1@645 plus a
-- fresh in-transit credit 1@658 (snapshot AND pending under one "mail" tag), warband
-- 4@645, alt Liara bags 3@645 + equipped 1@658 + mail 2@645, alt Bram bank 2@658.
-- Full total 19. Item 401 exists only in the own bank (for the filtered-to-nothing
-- case). Auction stores (own 1@658, Liara 2@645) are ALSO seeded -- the normal path
-- must never visit them, so the unchanged totals asserted by the tests below double as
-- the no-leak lock; only the auctionsOnly scope sees them (and it, in turn, never sees
-- mail).
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
				auctions = H.dbItems({ { id = 101, count = 1, ilvl = 658, link = l658 } }),
				mail = H.dbItems({ { id = 101, count = 1, ilvl = 645, link = l645 } }),
				mailPending = { H.pending(900, { { id = 101, count = 1, ilvl = 658, link = l658 } }) },
			}),
			["Liara-RealmA"] = H.charStore({
				bags = H.dbItems({ { id = 101, count = 3, ilvl = 645, link = l645 } }),
				equipped = H.dbItems({ { id = 101, count = 1, ilvl = 658, link = l658 } }),
				auctions = H.dbItems({ { id = 101, count = 2, ilvl = 645, link = l645 } }),
				mail = H.dbItems({ { id = 101, count = 2, ilvl = 645, link = l645 } }),
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
	assertEq(agg.total, 19)
	assertEq(agg.sources,
		{ bags = 2, bank = 2, equipped = 1, mail = 2, warband = 4,
			alts = { Liara = 6, Bram = 2 } })
	assertEq(agg.groups[645].count, 13)
	assertEq(agg.groups[645].sources,
		{ bags = 2, bank = 1, mail = 1, warband = 4, alts = { Liara = 5 } })
	assertEq(agg.groups[658].count, 6)
	assertEq(agg.groups[658].sources,
		{ bank = 1, equipped = 1, mail = 1, alts = { Liara = 1, Bram = 2 } })
	H.assertNoZeros(agg.sources)
end)

test("get_invariants_under_every_filter", function()
	local ns = loadAddon({ noPEW = true, db = worldDB })
	H.eachFilter(function(f)
		local expected = 2 + (f.bank and 2 or 0) + (f.equipped and 1 or 0) + (f.warband and 4 or 0)
			+ (f.mail and 2 or 0) -- own inbox 1 + own pending credit 1
			-- Liara's mail rides her per-alt number UNgated by f.mail (bags 3 + mail 2
			-- + equipped behind its own checkbox), Bram's bank 2.
			+ (f.alts and (3 + 2 + (f.altEquipped and 1 or 0) + 2) or 0)
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
	assertEq(ns.Get(401, { bags = true, bank = false, warband = true, equipped = true,
		mail = true, alts = true }), nil)
	-- Hidden alts drop out of total and sources alike (mail included).
	local agg = ns.Get(101, { bags = true, bank = true, warband = true, equipped = true,
		mail = true, alts = true, altEquipped = true,
		hiddenChars = { ["Liara-RealmA"] = true } })
	assertEq(agg.total, 13)
	assertEq(agg.sources.alts, { Bram = 2 })
end)

test("get_auctions_only_scope", function()
	local ns = loadAddon({ noPEW = true, db = worldDB })
	-- Alts included: own listings under the "auctions" tag, alts folded by name. The
	-- exact sources assertions below double as the reverse no-leak lock: the world also
	-- holds mail stores, and none of their counts may surface in the auction scope.
	local agg = ns.Get(101, { auctionsOnly = true, alts = true })
	assertEq(agg.total, 3)
	assertEq(agg.sources, { auctions = 1, alts = { Liara = 2 } })
	assertEq(agg.groups[658].count, 1)
	assertEq(agg.groups[658].sources, { auctions = 1 })
	assertEq(agg.groups[645].count, 2)
	assertEq(agg.groups[645].sources, { alts = { Liara = 2 } })
	H.assertNoZeros(agg.sources)
	-- Current character only.
	agg = ns.Get(101, { auctionsOnly = true, alts = false })
	assertEq(agg.total, 1)
	assertEq(agg.sources, { auctions = 1 })
	-- Hidden alts drop out of the auction scope like any other.
	agg = ns.Get(101, { auctionsOnly = true, alts = true, hiddenChars = { ["Liara-RealmA"] = true } })
	assertEq(agg.total, 1)
	assertEq(agg.sources, { auctions = 1 })
end)

test("auctions_never_leak_into_normal_scope", function()
	local ns = loadAddon({ noPEW = true, db = worldDB })
	-- The normal path must never visit auction stores: a nil filter ("everything") and
	-- every display-filter combination all exclude the auction fixtures seeded above.
	-- (The totals themselves are locked by the two tests above; this pins the key.)
	assertEq(ns.Get(101).total, 19)
	assertEq(ns.Get(101).sources.auctions, nil)
	H.eachFilter(function(f)
		assertTrue(ns.Get(101, f).sources.auctions == nil,
			"auctions key leaked into a normal-scope view")
	end)
end)

test("getbyname_auctions_only_threads_both_passes", function()
	local ns = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(201, { name = "Rousing Fiber", reagent = 1 })
		S.defineItem(202, { name = "Rousing Fiber", reagent = 2 })
		return H.db({
			chars = {
				[H.OWN] = H.charStore({
					bags = H.dbItems({ { id = 201, count = 7 } }), -- normal scope only
					auctions = H.dbItems({ { id = 201, count = 3 } }),
				}),
				["Liara-RealmA"] = H.charStore({
					auctions = H.dbItems({ { id = 202, count = 5 } }),
				}),
			},
		})
	end })
	-- Both GetByName passes must honor the mode: the bag-owned 7 stays out of the
	-- auction scope, and the alt's sibling tier joins only when alts do.
	local _, members, combined = ns.GetByName(201, { auctionsOnly = true, alts = true })
	assertEq(#members, 2)
	assertEq(combined.total, 8)
	assertEq(combined.sources, { auctions = 3, alts = { Liara = 5 } })
	local _, members2, combined2 = ns.GetByName(201, { auctionsOnly = true, alts = false })
	assertEq(#members2, 1)
	assertEq(combined2.total, 3)
end)

test("get_representative_precedence_follows_visit_order", function()
	local ns = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(102, { name = "Dropped Helm", equipLoc = "INVTYPE_HEAD" })
		S.defineItem(103, { name = "Worn Blade", equipLoc = "INVTYPE_WEAPON" })
		local lBank = S.link(102, "bankrep", { ilvl = 613 })
		local lWb = S.link(102, "wbrep", { ilvl = 613 })
		local lEq = S.link(103, "equiprep", { ilvl = 620 })
		local lWb2 = S.link(103, "wbrep2", { ilvl = 620 })
		S.defineItem(104, { name = "Parcel Helm", equipLoc = "INVTYPE_HEAD" })
		local lMail = S.link(104, "mailrep", { ilvl = 630 })
		local lWb3 = S.link(104, "wbrep3", { ilvl = 630 })
		return H.db({
			chars = {
				[H.OWN] = H.charStore({
					bags = H.dbItems({ -- no representatives
						{ id = 102, count = 1, ilvl = 613 },
						{ id = 103, count = 1, ilvl = 620 },
					}),
					bank = H.dbItems({ { id = 102, count = 1, ilvl = 613, link = lBank,
						track = { name = "Hero", step = 1, max = 6 } } }),
					equipped = H.dbItems({ { id = 103, count = 1, ilvl = 620, link = lEq,
						track = { name = "Champion", step = 3, max = 8 } } }),
					mail = H.dbItems({
						{ id = 103, count = 1, ilvl = 620, link = S.link(103, "mailrep2", { ilvl = 620 }) },
						{ id = 104, count = 1, ilvl = 630, link = lMail,
							track = { name = "Veteran", step = 2, max = 8 } },
					}),
				}),
			},
			warband = H.dbItems({
				{ id = 102, count = 1, ilvl = 613, link = lWb,
					track = { name = "Myth", step = 5, max = 6 } },
				{ id = 103, count = 1, ilvl = 620, link = lWb2,
					track = { name = "Myth", step = 5, max = 6 } },
				{ id = 104, count = 1, ilvl = 630, link = lWb3,
					track = { name = "Myth", step = 5, max = 6 } },
			}),
		})
	end })
	local agg = ns.Get(102)
	-- Own bags visit first but carry nothing; the bank's representatives fill in and the
	-- warband's lose (first non-nil in visit order).
	assertTrue(agg.link and agg.link:find("bankrep", 1, true) ~= nil, "entry link from the bank")
	assertEq(agg.groups[613].track.name, "Hero")
	-- Deeper in the own chain: equipped still beats mail and warband (locks the full
	-- own-store order "bags > bank > equipped > mail > warband" against insertions
	-- shifting it).
	local agg2 = ns.Get(103)
	assertTrue(agg2.link and agg2.link:find("equiprep", 1, true) ~= nil,
		"entry link from equipped over mail and warband")
	assertEq(agg2.groups[620].track.name, "Champion")
	-- And mail beats warband when it is the first store carrying a representative.
	local agg3 = ns.Get(104)
	assertTrue(agg3.link and agg3.link:find("mailrep", 1, true) ~= nil,
		"entry link from mail over warband")
	assertEq(agg3.groups[630].track.name, "Veteran")
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
	local dst = { bags = 1, mail = 2, alts = { Liara = 2 } }
	ns.MergeSources(dst, { bags = 2, bank = 3, warband = 1, equipped = 4, mail = 5, auctions = 2,
		alts = { Liara = 1, Bram = 4 } })
	assertEq(dst, { bags = 3, bank = 3, warband = 1, equipped = 4, mail = 7, auctions = 2,
		alts = { Liara = 3, Bram = 4 } })
	ns.MergeSources(dst, {}) -- empty source: no-op, and no zero keys appear
	assertEq(dst, { bags = 3, bank = 3, warband = 1, equipped = 4, mail = 7, auctions = 2,
		alts = { Liara = 3, Bram = 4 } })
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

test("unknown_char_substores_are_inert", function()
	-- Additive versioning promise, data-layer side: a NEWER addon version may add source
	-- stores to a char entry without bumping DB_VERSION (the settings analog is
	-- unknown_settings_keys_ride_along) -- so this version must treat unrecognized
	-- sub-tables as inert data: never counted, never an error, never clobbered.
	local ns, S = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(301, { name = "Acorn" })
		local char = H.charStore({ bags = H.dbItems({ { id = 301, count = 1 } }) })
		char.futureStore = H.snap(H.dbItems({ { id = 301, count = 50 } }))
		char.futurePending = { { sentAt = 900, items = H.dbItems({ { id = 301, count = 9 } }) } }
		local alt = H.charStore({ bags = H.dbItems({ { id = 301, count = 2 } }) })
		alt.futureStore = H.snap(H.dbItems({ { id = 301, count = 7 } }))
		return H.db({ chars = { [H.OWN] = char, ["Liara-RealmA"] = alt } })
	end })
	local agg = ns.Get(301)
	assertEq(agg.total, 3) -- the unknown stores contribute nothing, own or alt
	assertEq(agg.sources, { bags = 1, alts = { Liara = 2 } })
	local _, _, combined = ns.GetByName(301)
	assertEq(combined.total, 3)
	-- Scans replace only their own store; unknown keys ride along untouched.
	S.fire("BAG_UPDATE_DELAYED")
	local char = _G.ExactItemCountDB.chars[H.OWN]
	assertTrue(char.futureStore ~= nil and char.futurePending ~= nil,
		"a rescan leaves unknown sub-stores in place")
	-- DeleteChar is store-agnostic: the whole entry goes, unknown keys included.
	ns.DeleteChar("Liara-RealmA")
	assertEq(_G.ExactItemCountDB.chars["Liara-RealmA"], nil)
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

-- ------------------------------------------------- chat-search seams

test("collect_itemids_matches_stores_and_respects_filter", function()
	local ns, S = loadAddon({ noPEW = true, db = function(S)
		S.defineItem(301, { name = "Acorn" })
		return H.db({
			chars = {
				[H.OWN] = H.charStore({
					bags = H.dbItems({ { id = 301, count = 1, link = S.link(301, "b") } }),
					bank = H.dbItems({ { id = 302, count = 2, link = S.link(302, "k", { name = "Bark" }) } }),
					auctions = H.dbItems({ { id = 305, count = 3, link = S.link(305, "a", { name = "Amber" }) } }),
				}),
				["Liara-RealmA"] = H.charStore({
					bags = H.dbItems({ { id = 303, count = 4, link = S.link(303, "L", { name = "Clay" }) } }),
				}),
				["Ghost-RealmA"] = H.charStore({
					bags = H.dbItems({ { id = 304, count = 5, link = S.link(304, "G", { name = "Dust" }) } }),
				}),
			},
		})
	end })
	-- nil filter = every owned store; the normal path never visits auction stores.
	local ids, repLinks = ns.CollectItemIDs(nil)
	assertEq(ids, { [301] = true, [302] = true, [303] = true, [304] = true })
	assertEq(repLinks[301], S.link(301, "b"))
	-- Per-source gating: a filtered-out store contributes no ids.
	ids = ns.CollectItemIDs({ bags = true, bank = false, alts = true, altEquipped = true })
	assertEq(ids, { [301] = true, [303] = true, [304] = true })
	-- hiddenChars drops that alt's ids entirely.
	ids = ns.CollectItemIDs({ bags = true, alts = true,
		hiddenChars = { ["Ghost-RealmA"] = true } })
	assertEq(ids, { [301] = true, [303] = true })
	-- auctionsOnly flips the visit set: ONLY auction stores, never the owned ones.
	local aIds, aLinks = ns.CollectItemIDs({ auctionsOnly = true, alts = true })
	assertEq(aIds, { [305] = true })
	assertEq(aLinks[305], S.link(305, "a", { name = "Amber" }))
end)

test("collect_itemids_safe_before_addon_loaded", function()
	local ns = loadAddon({ noAddonLoaded = true, noPEW = true })
	local ids, repLinks = ns.CollectItemIDs(nil) -- nil db: empty universe, no error
	assertEq(next(ids), nil)
	assertEq(next(repLinks), nil)
end)

test("itemname_warm_cold_and_missing", function()
	local ns, S = loadAddon({ noPEW = true })
	S.defineItem(301, { name = "Acorn" })
	assertEq(ns.ItemName(301, nil), "Acorn") -- session cache first
	local coldLink = S.link(999, "x", { name = "Mystery Cache Item" })
	assertEq(ns.ItemName(999, coldLink), "Mystery Cache Item") -- bracket-name fallback
	assertEq(ns.ItemName(998, nil), nil) -- neither resolves: no join key
end)
