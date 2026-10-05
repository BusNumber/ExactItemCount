local addonName, ns = ...

-- Every word this file displays comes from the string table (Locales/); what stays
-- inline is the glue shared by all locales -- colors, parentheses, separators, colons.
local L = ns.L

-- Everything renders as single left-aligned AddLines: AddDoubleLine's right column sits
-- wherever the widest Blizzard line pushed the tooltip edge, so the label-to-count gap
-- would vary per item. Colors are applied per-segment with inline escape codes instead.
local ACCENT = "99ccff" -- section label; reads as this addon's contribution
local HILITE = "ffd100" -- gold: the variant matching the hovered item itself
local WHITE  = "ffffff" -- the counts being asked about
local DIM    = "b3b3b3" -- non-hovered variants
local SUFFIX      = "808080" -- location suffix base: labels, counts, separators, parens
local SUFFIX_BAGS = "a6a6a6" -- the whole "bags N" token: one step brighter than the rest
                             -- of the suffix, still below DIM so it never outshines a
                             -- row's primary count (ladder: WHITE > DIM > this > SUFFIX)

local function C(hex, text)
	return "|cff" .. hex .. text .. "|r"
end

local GetItemInfoInstant      = C_Item.GetItemInfoInstant
local GetDetailedItemLevelInfo = C_Item.GetDetailedItemLevelInfo
local RequestLoadItemDataByID = C_Item.RequestLoadItemDataByID
local GetCraftedQuality = C_TradeSkillUI.GetItemCraftedQualityByItemInfo
local GetReagentQuality = C_TradeSkillUI.GetItemReagentQualityByItemInfo

-- Item class 9 (Recipe) gates the crafted-product sub-section: only a recipe
-- legitimately embeds another item's link in its tooltip data.
local ITEM_CLASS_RECIPE = Enum.ItemClass and Enum.ItemClass.Recipe or 9

-- itemIDs whose item data has already been requested this session (see the quality-path
-- membership predicate below) -- one request per id is plenty to prime the client cache.
local requestedLoad = {}

-- Crafting quality of an item, as (tier, atlas), or nil when it has no quality.
-- The two quality systems use different icon art, so the atlas is matched to whichever
-- system produced the value: crafted equipment -> the classic 5-tier stars; reagents ->
-- Midnight's redesigned two-tier set (1 = silver, 2 = gold), which lives under a separate
-- "-12-" atlas family. `isGear` picks the priority (equipment reads crafted quality first,
-- everything else reads reagent quality first) so a reagent shows its new icon rather than
-- the old gear star. Pass the full hyperlink so bonus IDs resolve the right per-quality value.
local function GetQuality(link, isGear)
	if not link then return nil end
	if isGear then
		local crafted = GetCraftedQuality(link)
		if crafted then return crafted, "Professions-ChatIcon-Quality-Tier" .. crafted end
		local reagent = GetReagentQuality(link)
		if reagent then return reagent, "Professions-ChatIcon-Quality-12-Tier" .. reagent end
	else
		local reagent = GetReagentQuality(link)
		if reagent then return reagent, "Professions-ChatIcon-Quality-12-Tier" .. reagent end
		local crafted = GetCraftedQuality(link)
		if crafted then return crafted, "Professions-ChatIcon-Quality-Tier" .. crafted end
	end
	return nil
end

local function StarIcon(atlas)
	return CreateAtlasMarkup(atlas, 16, 16)
end

-- Body of the upgrade-track badge: "H 1/6" -- first letter of the (localized) track name
-- plus the upgrade progress. The letters are unique across tracks in English (Explorer /
-- Adventurer / Veteran / Champion / Hero / Myth -> E A V C H M); the match takes the first
-- UTF-8 character, not the first byte, so non-ASCII locales don't produce mojibake.
local function TrackText(track)
	local letter = track.name:match("^[%z\1-\127\194-\244][\128-\191]*") or track.name
	return letter .. " " .. track.step .. "/" .. track.max
end

-- Every "[modifier] held" setting resolves through these. The key is read live per
-- render, so a tooltip opened with it already down is right from its first frame; the
-- MODIFIER_STATE_CHANGED watcher (bottom of file) rebuilds a visible tooltip when the
-- key state flips mid-hover.
local function ModifierDown(mod)
	if mod == "ALT" then return IsAltKeyDown() end
	if mod == "CTRL" then return IsControlKeyDown() end
	return IsShiftKeyDown()
end

local function SourceEnabled(mode, down)
	if mode == "never" then return false end
	if mode == "modifier" then return down end
	return true
end

-- The data-layer filter for this render, plus the resolved modifier state. nil settings
-- (before Settings.lua has initialized) means no filter -- everything shows, exactly the
-- pre-settings behavior.
local function BuildFilter(s)
	if not s then return nil, false end
	local down = ModifierDown(s.modifier)
	return {
		bags = true, -- the current character's bags always count; no setting gates them
		bank = SourceEnabled(s.bankMode, down),
		equipped = SourceEnabled(s.equippedMode, down),
		warband = SourceEnabled(s.warbandMode, down),
		mail = SourceEnabled(s.mailMode, down), -- own mailbox + own in-transit credits;
		                                        -- alts' mail rides their per-alt count unconditionally
		alts = SourceEnabled(s.altsMode, down),
		altEquipped = s.altEquipped, -- whether alts' worn gear folds into their per-alt count
		hiddenChars = s.hiddenChars,
	}, down
end

-- Location breakdown for one count, pre-colored: " (bags 2 · bank 1 · warband 3 · Liara 1)".
-- Fixed order bags / bank(s) / warband / equipped / mail / alts, alts by count descending
-- (name ascending as a stable tiebreak); zero-count locations never appear (the aggregator
-- omits them), so an empty sources table -- and the synthetic owned-0 rows that have none at
-- all -- yields "". The whole "bags N" token renders one step brighter than the rest: "how
-- many on me right now" is one glance, and no bright token anywhere reads as "none on you".
-- "equipped" (the current character's worn gear) and "mail" (this character's mailbox plus
-- its uncollected in-transit sends) sit at the dim base like bank/warband -- nothing in a
-- mailbox is "in hand". Bare bags/bank/equipped/mail always mean the current character;
-- alts are name + count only, containers and mail combined.
--
-- `opts` is the per-render display shape; modifier state is already folded in by the
-- caller, so this function never reads the keyboard:
--   showSuffix  false suppresses the suffix entirely
--   mergeBanks  bank + warband collapse into one "banks N" token -- only when both are
--               present; a lone token never merges (a sum of one would just relabel it)
--   altsDetail  "topn" names the top N alts by count, the rest collapse into one
--               "+K alts M" token; "all" names every alt; "total" is one "alts M" token
--   topN        the N for "topn". A tail of exactly one alt is named instead of
--               collapsed: "+1 alts 3" saves nothing over the name and says less.
-- Whatever the shape, the suffix always sums exactly to its line's count.
local function SourceSuffix(sources, opts)
	if not sources or not opts.showSuffix then return "" end
	local parts = {}
	local function Add(hex, text)
		parts[#parts + 1] = C(hex, text)
	end
	if sources.bags then
		Add(SUFFIX_BAGS, L.SUFFIX_BAGS:format(sources.bags))
	end
	if opts.mergeBanks and sources.bank and sources.warband then
		Add(SUFFIX, L.SUFFIX_BANKS:format(sources.bank + sources.warband))
	else
		if sources.bank then
			Add(SUFFIX, L.SUFFIX_BANK:format(sources.bank))
		end
		if sources.warband then
			Add(SUFFIX, L.SUFFIX_WARBAND:format(sources.warband))
		end
	end
	if sources.equipped then
		Add(SUFFIX, L.SUFFIX_EQUIPPED:format(sources.equipped))
	end
	if sources.mail then
		Add(SUFFIX, L.SUFFIX_MAIL:format(sources.mail))
	end
	-- The current character's own auction listings. Only auction-scope aggregates carry
	-- this key (the scopes never mix -- see ForEachSourceStore), so the token appears
	-- solely inside the "On auction" sub-section, where repeating "auctions" would be
	-- redundant: the place is already in the lead, so the own token is a possessive,
	-- there to contrast with the named alts beside it. (When alts can't appear in the
	-- section, the caller suppresses its suffixes wholesale -- a constant "yours N"
	-- restating each line would carry no information.) Base suffix color -- nothing
	-- listed is "in hand", so no bags-style brightness.
	if sources.auctions then
		Add(SUFFIX, L.SUFFIX_YOURS:format(sources.auctions))
	end
	if sources.alts then
		local names = {}
		for name in pairs(sources.alts) do
			names[#names + 1] = name
		end
		table.sort(names, function(a, b)
			local na, nb = sources.alts[a], sources.alts[b]
			if na ~= nb then return na > nb end
			return a < b
		end)
		if opts.altsDetail == "total" then
			local sum = 0
			for _, name in ipairs(names) do
				sum = sum + sources.alts[name]
			end
			Add(SUFFIX, L.SUFFIX_ALTS_TOTAL:format(sum))
		else
			local named = #names
			if opts.altsDetail == "topn" and opts.topN + 1 < #names then
				named = opts.topN -- the tail is 2+ alts, worth collapsing
			end
			for i = 1, named do
				Add(SUFFIX, L.SUFFIX_ALT:format(names[i], sources.alts[names[i]]))
			end
			if named < #names then
				local count, sum = 0, 0
				for j = named + 1, #names do
					count = count + 1
					sum = sum + sources.alts[names[j]]
				end
				Add(SUFFIX, L.SUFFIX_ALTS_MORE:format(count, sum))
			end
		end
	end
	if #parts == 0 then return "" end
	-- "\194\183" is the UTF-8 middle dot; escaped so the separator survives any
	-- editor/encoding mishap.
	return C(SUFFIX, " (") .. table.concat(parts, C(SUFFIX, " \194\183 ")) .. C(SUFFIX, ")")
end

-- A sub-section's lead line: "<label>: N" plus an optional pre-colored location-suffix
-- tail. The hovered item's sub-section leads with "Total items owned"; a recipe's
-- crafted-product sub-section leads with "Crafted items".
local function AddLead(tooltip, label, n, suffix)
	tooltip:AddLine(C(ACCENT, label .. ": ") .. C(WHITE, tostring(n)) .. (suffix or ""))
end

-- Equippable gear: one row per item level, highest first. Crafting ranks share an itemID
-- and differ only by ilvl, so each owned level is its own row: the ilvl leads (the number
-- players sort gear by -- crest brackets mean the same rank exists at far-apart ilvls, so
-- rank alone doesn't even order it) and the rank star trails as a badge, mirroring the
-- game's own name-then-quality-icon order. The star stays on combat gear (it's the recraft
-- signal: a low-bracket R5 is maxed, an R4 isn't) and doubles as the rank label players
-- actually read on profession tools. The hovered item's own level is always shown -- even
-- at 0 -- so an R5 you're about to craft appears explicitly, highlighted gold. Dropped
-- gear on an upgrade track is badged "(H 1/6)" instead of the bare "ilvl" prefix; tracks
-- and crafting ranks are mutually exclusive (crafted gear is recrafted, never upgraded).
local function ShowGearBreakdown(tooltip, entry, link, hoveredTrack, opts, markOnly)
	-- `link` can legitimately be nil (TooltipData's id and hyperlink are both optional);
	-- without one there is no hovered ilvl to resolve, and the rows below handle that.
	-- `markOnly` keeps the hover marking but drops the synthetic owned-0 row (the
	-- auction block: same item under the cursor, but only actual listings may appear).
	local hoveredIlvl = link and GetDetailedItemLevelInfo(link)
	local rows, seen = {}, {}
	if entry then
		for ilvl in pairs(entry.groups) do
			rows[#rows + 1] = ilvl
			seen[ilvl] = true
		end
	end
	if hoveredIlvl and not seen[hoveredIlvl] and not markOnly then
		rows[#rows + 1] = hoveredIlvl
	end
	table.sort(rows, function(a, b) return a > b end)

	for _, ilvl in ipairs(rows) do
		local group = entry and entry.groups[ilvl]
		local count = group and group.count or 0
		local tier, atlas = GetQuality(group and group.link or link, true)

		local hovered = ilvl == hoveredIlvl
		local labelColor = hovered and HILITE or DIM
		local countColor = hovered and WHITE or DIM

		-- The hovered tooltip's track fills in when the row has no stored one: always for
		-- the synthetic owned-0 row, and as a fallback if the scan-time parse came up dry.
		local track = (group and group.track) or (hovered and hoveredTrack) or nil

		-- Plain gear has neither star nor track, so an "ilvl" prefix labels the bare
		-- number instead.
		local label
		if tier then
			label = C(labelColor, ilvl .. " ") .. StarIcon(atlas) .. C(labelColor, ":")
		elseif track then
			label = C(labelColor, ilvl .. " (" .. TrackText(track) .. "):")
		else
			label = C(labelColor, L.ROW_ILVL:format(ilvl) .. ":")
		end
		tooltip:AddLine("  " .. label .. " " .. C(countColor, tostring(count))
			.. SourceSuffix(group and group.sources, opts))
	end
end

-- Quality goods (reagents, crafted consumables): each tier is a distinct itemID under one
-- shared name, so the name siblings combine into one row per tier, "<star>: N (bags 2 ·
-- warband 8)". Tier order is fixed best-first (gold before silver), so the section renders
-- identically for every sibling -- only the gold/white emphasis moves with the hover, and
-- the hovered tier is always present (even at 0: that zero is the answer being asked for).
-- The star icon alone carries the tier -- these have no meaningful item level. Rows only:
-- the caller owns the total line (it needs the combined total before any line is added,
-- for the hide-at-zero check).
--
-- `tiers` maps every member's itemID to its resolved { tier, atlas }, filled by the
-- membership predicate the caller handed ns.GetByName -- an id without a resolvable tier
-- never became a member, so row membership equals total membership by construction and
-- no member can be silently dropped here.
local function ShowQualityBreakdown(tooltip, members, tiers, hoveredTier, hoveredAtlas, opts, markOnly)
	local rows = {}
	for _, m in ipairs(members) do
		local tier, atlas = tiers[m.itemID][1], tiers[m.itemID][2]
		local row = rows[tier]
		if not row then
			rows[tier] = { count = m.total, atlas = atlas, sources = m.sources }
		else
			-- Two itemIDs sharing name+tier shouldn't exist; merge counts AND sources so
			-- both invariants survive: rows sum to the total, every suffix sums to its
			-- row. (m.sources is this render's throwaway aggregate -- safe to fold into.)
			row.count = row.count + m.total
			ns.MergeSources(row.sources, m.sources)
		end
	end
	if hoveredTier and not rows[hoveredTier] and not markOnly then
		rows[hoveredTier] = { count = 0, atlas = hoveredAtlas } -- owned 0: no locations
	end

	local order = {}
	for tier in pairs(rows) do
		order[#order + 1] = tier
	end
	table.sort(order, function(a, b) return a > b end)

	for _, tier in ipairs(order) do
		local row = rows[tier]
		local hovered = tier == hoveredTier
		local labelColor = hovered and HILITE or DIM
		local countColor = hovered and WHITE or DIM
		-- The atlas markup renders its own art regardless of color codes, so the colon
		-- carries the label color, matching the gear rows' label convention.
		tooltip:AddLine("  " .. StarIcon(row.atlas) .. C(labelColor, ":") .. " "
			.. C(countColor, tostring(row.count)) .. SourceSuffix(row.sources, opts))
	end
end

-- One item's classified aggregate -- the shared computation behind both sub-sections a
-- tooltip can carry (the hovered item's own, and a recipe's crafted product). The caller
-- supplies whichever link legitimately belongs to the item: the hovered link, or the
-- recipe's embedded product link.
local function ComputeAggregate(itemID, link, filter)
	-- Equippable items (weapons, armour, profession tools/accessories) get a per-ilvl
	-- breakdown; the shared gate in Core.lua excludes bags and non-equippables (whose
	-- equip loc is "INVTYPE_NON_EQUIP_IGNORE", not "").
	local _, _, _, itemEquipLoc = GetItemInfoInstant(link or itemID)
	local agg = { isGear = ns.IsGearEquipLoc(itemEquipLoc) }
	if not agg.isGear then
		agg.tier, agg.atlas = GetQuality(link, false)
	end
	if agg.tier then
		-- Membership on top of the name join: a sibling counts only if its tier resolves
		-- right now, so an id whose stored link can't produce a quality (cold cache -- an
		-- alt-owned itemID this session has never seen -- or an unrelated same-name item)
		-- contributes neither a row nor a total share; the data layer applies the same
		-- all-or-nothing rule it uses for filtered-out sources. Resolved tiers are kept
		-- so the renderer works from the exact set that built the total. Rejected ids get
		-- their item data requested -- a later hover then includes them.
		local tier, atlas = agg.tier, agg.atlas
		local tiers = {}
		local function accept(id, repLink)
			if id == itemID then
				-- The item this aggregate is for; its tier already resolved from the
				-- link in hand, so it can never drop out of its own total.
				tiers[id] = { tier, atlas }
				return true
			end
			local t, a = GetQuality(repLink, false)
			if t then
				tiers[id] = { t, a }
				return true
			end
			-- Prime the client item cache so a later hover can resolve this sibling. The
			-- API's argument is string-typed (link or id), so pass the stored link; if
			-- there is none, the name join came from GetItemNameByID, meaning the item
			-- data is already cached and there is nothing to request.
			if RequestLoadItemDataByID and repLink and not requestedLoad[id] then
				requestedLoad[id] = true
				RequestLoadItemDataByID(repLink)
			end
			return false
		end
		local _, members, combined = ns.GetByName(itemID, filter, accept)
		agg.tiers, agg.members, agg.combined = tiers, members, combined
		agg.total = combined.total
	else
		agg.entry = ns.Get(itemID, filter)
		agg.total = agg.entry and agg.entry.total or 0
	end
	return agg
end

-- The lead line's location suffix. All three aggregate shapes route through here: a
-- quality good's combined sources, a gear/plain item's entry sources, or no data at all
-- (owned nowhere) -- SourceSuffix renders a missing or empty sources table as "".
local function LeadSuffix(agg, opts)
	return SourceSuffix((agg.combined or agg.entry or {}).sources, opts)
end

-- Breakdown rows for one aggregate; plain items have none. `hover` marks the hovered
-- variant ({ link, track, markOnly }): it supplies the gold/white emphasis and -- unless
-- `markOnly` -- the synthetic owned-0 row. markOnly is the auction block's shape: it
-- holds the same item that is under the cursor (so a matching row marks gold), but only
-- actual listings may appear in it, never a synthetic zero. nil hover (a recipe's
-- product sub-section) renders every row dim with no synthetic row -- nothing there is
-- "the variant under the cursor".
local function ShowBreakdownRows(tooltip, agg, hover, opts)
	if agg.isGear then
		ShowGearBreakdown(tooltip, agg.entry, hover and hover.link or nil,
			hover and hover.track or nil, opts, hover and hover.markOnly)
	elseif agg.tier then
		ShowQualityBreakdown(tooltip, agg.members, agg.tiers,
			hover and agg.tier or nil, hover and agg.atlas or nil, opts, hover and hover.markOnly)
	end
end

local function OnItemTooltip(tooltip, data)
	-- Post-calls fire for EVERY tooltip inheriting GameTooltipTemplate (comparison and
	-- chat-link popups, quest rewards, third-party frames) -- deliberately kept: counts
	-- are as useful on a linked item as on a bag hover. Secure (forbidden) tooltips are
	-- the exception; addon code must not touch them.
	if tooltip:IsForbidden() then return end
	if not data then return end

	-- One frame can be handed more than one TooltipData -- a recipe may surface its
	-- embedded product's data through the same post-call. Render only for the frame's
	-- primary data so the section can never appear twice on one frame. Ids are compared,
	-- not tables (RefreshData rebuilds the data table), and the guard fails open: a frame
	-- without the mixin method, or data without ids, renders as before.
	if data.id and tooltip.GetTooltipData then
		local primary = tooltip:GetTooltipData()
		if primary and primary.id and primary.id ~= data.id then return end
	end

	-- `data.id` is the canonical id of the item actually being shown -- trust it over the
	-- link. A recipe tooltip embeds its crafted product, so the displayed link can resolve
	-- to that product rather than the recipe; the count keys off the id regardless. A
	-- disagreeing link is never the hovered item's own: when the hovered item really is a
	-- recipe (by item class) it's the crafted product -- kept, for the product sub-section
	-- below -- and anything else is dropped outright.
	local itemID = data.id
	local link = data.hyperlink
	if not link and TooltipUtil then
		local _, displayed = TooltipUtil.GetDisplayedItem(tooltip)
		link = displayed
	end
	local linkID = link and GetItemInfoInstant(link)
	local productID, productLink
	if itemID and linkID and linkID ~= itemID then
		local _, _, _, _, _, classID = GetItemInfoInstant(itemID)
		if classID == ITEM_CLASS_RECIPE then
			productID, productLink = linkID, link
		end
		link = nil -- the recipe's own classification stays keyed off the recipe id
	elseif not itemID then
		itemID = linkID
	end
	if not itemID then return end

	-- Settings shape every aggregate below (which sources count at all) and how it
	-- renders. Both resolve the modifier key once, here -- everything downstream is
	-- keyboard-free. nil settings = defaults = the full pre-settings display.
	local s = ns.GetSettings and ns.GetSettings()
	local filter, modDown = BuildFilter(s)
	local showRows = not s or s.rowsMode == "always" or modDown
	-- The "list all while held" checkbox promotes whatever detail mode is configured to
	-- "all" for as long as the key is down (a no-op when the mode already is "all").
	local altsDetail = s and s.altsDetail or "topn"
	if s and s.altsExpandKey and modDown then
		altsDetail = "all"
	end
	local opts = {
		showSuffix = not s or s.suffixMode == "always" or modDown,
		mergeBanks = s ~= nil and (s.bankMerge == "merged"
			or (s.bankMerge == "modifier" and not modDown)),
		altsDetail = altsDetail,
		topN = s and s.altsTopN or 2,
	}

	-- Totals are needed before any line is added: hide-at-zero can drop either
	-- sub-section (settings opt-in) or the whole section, and a hidden section must not
	-- leave a stray spacer. On a recipe, the crafted product gets its own aggregate --
	-- the count a recipe hover is usually really asking for ("do I need to craft
	-- more?") -- gated by its tri-state; nil settings show it, matching the default.
	local agg = ComputeAggregate(itemID, link, filter)
	local productAgg
	if productID and (not s or SourceEnabled(s.recipeProductMode, modDown)) then
		productAgg = ComputeAggregate(productID, productLink, filter)
	end
	-- Auction listings are conditionally owned -- yours only if the listing fails -- so
	-- they never fold into "Total items owned". They render as their own sub-section,
	-- built by the same pipeline through the auctionsOnly filter mode (its lead equals
	-- the sum of its rows by the same construction). The filter is built explicitly even
	-- under nil settings: a nil filter would visit the NORMAL stores. Alts join only when
	-- the opt-in checkbox is on AND the alts tri-state passes (already modifier-folded in
	-- `filter`); the default is the current character only -- an alt's listings are the
	-- stalest data the addon holds (they change while offline and only heal when that alt
	-- next visits the AH).
	local includeAlts = (s ~= nil and s.altAuctions and filter.alts) or false
	local auctionAgg
	if not s or SourceEnabled(s.auctionsMode, modDown) then
		auctionAgg = ComputeAggregate(itemID, link, {
			auctionsOnly = true,
			alts = includeAlts,
			hiddenChars = s ~= nil and s.hiddenChars or nil,
		})
	end
	local hideZero = s and s.hideZero
	local showSelf = not (hideZero and agg.total == 0)
	local showProduct = productAgg ~= nil and not (hideZero and productAgg.total == 0)
	-- Non-zero only, stricter than hideZero by design: zero listings is the norm for
	-- nearly every item, so an ever-present "On auction: 0" would be pure noise (where a
	-- zero OWNED total is the answer being asked for).
	local showAuctions = auctionAgg ~= nil and auctionAgg.total > 0
	if not showSelf and not showProduct and not showAuctions then return end

	tooltip:AddLine(" ")

	-- The hovered variant's identity, shared by both scopes that can contain it -- the
	-- main section and the auction block -- so the gold/white marking follows the hover
	-- wherever its row appears. For gear, the hovered tooltip's own lines supply the
	-- upgrade track: the synthetic owned-0 row has no stored group to read it from, and
	-- a matching auction row (scanned tracklessly) borrows it the same way.
	local hover = { link = link }
	if agg.isGear then
		local name, step, max = ns.ParseUpgradeTrack(data.lines)
		if name then
			hover.track = { name = name, step = step, max = max }
		end
	end

	-- A zero total stands alone: every row under it would just restate the zero.
	if showSelf then
		AddLead(tooltip, L.LEAD_TOTAL, agg.total, LeadSuffix(agg, opts))
		if agg.total > 0 and showRows then
			ShowBreakdownRows(tooltip, agg, hover, opts)
		end
	end

	-- The auction sub-section, placed before the product block so the two hovered-item
	-- scopes stay adjacent. It holds the same item that is under the cursor, so the
	-- hover marking applies (markOnly: gold on a matching row, but never a synthetic
	-- 0-row -- only actual listings appear here). The location suffix renders only
	-- while alts can appear in it: restricted to the current character, every suffix
	-- would be a constant "yours N" restating its line's count -- zero information --
	-- and the lead alone names the scope's single possible location.
	if showAuctions then
		local auctionOpts = includeAlts and opts or { showSuffix = false }
		AddLead(tooltip, L.LEAD_AUCTION, auctionAgg.total, LeadSuffix(auctionAgg, auctionOpts))
		if showRows then
			ShowBreakdownRows(tooltip, auctionAgg,
				{ link = hover.link, track = hover.track, markOnly = true }, auctionOpts)
		end
	end

	-- The product sub-section: a constant "Crafted items" label (the product's name is
	-- already on screen in Blizzard's embedded product tooltip), its counts and rows
	-- rendered by the same pipeline -- but with no hovered variant: nothing in it is
	-- under the cursor, so no gold row and no synthetic owned-0 row.
	if showProduct then
		AddLead(tooltip, L.LEAD_CRAFTED, productAgg.total, LeadSuffix(productAgg, opts))
		if productAgg.total > 0 and showRows then
			ShowBreakdownRows(tooltip, productAgg, nil, opts)
		end
	end
end

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)

-- ---------------------------------------------------------------------------
-- The `/eic find <name or item link>` chat command. Chat output is presentation, so it
-- lives here with the tooltip's render helpers (SourceSuffix, ComputeAggregate, the
-- palette, the requestedLoad priming state) rather than exporting them; Settings.lua's
-- slash handler routes every non-empty message to ns.ChatCommand and keeps zero chat
-- knowledge. Output is a snapshot -- no RefreshData analogue exists for chat lines.

local FIND_MIN_QUERY = 2    -- a single character is never an intentional search; the
                            -- result cap below does the real flood-prevention work
local FIND_MAX_RESULTS = 10 -- overflow collapses into one "...and N more" tail line

local EMDASH = " \226\128\148 " -- scope separator; escaped like the suffix middle dot

-- Fixed display options for every chat suffix, never the tooltip's modifier-gated
-- ones: find IS the "which alt has it" surface, so every alt is always named and the
-- suffix always renders. topN is a defensive placeholder (the "all" branch never reads
-- it); banks stay separate -- the fuller vocabulary for an explicit ask.
local CHAT_OPTS = { showSuffix = true, mergeBanks = false, altsDetail = "all", topN = 0 }

local function Chat(text)
	DEFAULT_CHAT_FRAME:AddMessage(text)
end

local function ChatHeader(text)
	return C(ACCENT, "Exact Item Count" .. EMDASH .. text)
end

-- find searches EVERYTHING: the display tri-states exist to fight tooltip clutter, and
-- a typed command is an explicit ask -- a "Never"ed bank silently hiding the only copy
-- would turn the search into the silent-failure trust-killer this addon avoids. Only
-- hiddenChars (the Characters-page eye) applies: hiding a character is data-level
-- intent, not display gating. The auction scope gets the same treatment (alts' listings
-- included, auctionsMode/altAuctions ignored) for the same reason.
local function ChatFilters()
	local s = ns.GetSettings and ns.GetSettings()
	local hidden = s and s.hiddenChars or nil
	return {
		bags = true, bank = true, equipped = true, mail = true, warband = true,
		alts = true, altEquipped = true, hiddenChars = hidden,
	}, { auctionsOnly = true, alts = true, hiddenChars = hidden }
end

-- Reduces a raw query to plain, pipe-free text: every UI escape is stripped (a pasted
-- link that failed to resolve degrades to its bracket name), then any surviving pipe,
-- so echoing the query back can't open a color region or fake a hyperlink mid-line.
-- (C_StringUtil.StripHyperlinks, added in 12.0, is the official near-equivalent; the
-- explicit chain stays byte-deterministic and headless-testable.) A fully bracketed
-- query unwraps so a pasted "[Name]" searches "Name".
local function SanitizeQuery(text)
	text = text
		:gsub("|c%x%x%x%x%x%x%x%x", "")
		:gsub("|r", "")
		:gsub("|H.-|h", "")
		:gsub("|h", "")
		:gsub("|T.-|t", "")
		:gsub("|A.-|a", "")
		:gsub("|n", " ")
		:gsub("|", "")
	text = text:match("^%s*(.-)%s*$")
	return text:match("^%[(.*)%]$") or text
end

-- The listings scope for one result line: appended after the owned suffix, only when
-- non-zero (zero listings is the norm for nearly every item -- the tooltip's own
-- non-zero-only rule). A separate count after the em dash: the two scopes never merge
-- into one number, and a line can legitimately read ": 0" before a non-zero tail (an
-- item that is 100% listed).
local function AuctionTail(itemID, repLink, auctionFilter)
	local agg = ComputeAggregate(itemID, repLink, auctionFilter)
	if agg.total == 0 then return "" end
	return C(DIM, EMDASH .. L.CHAT_ON_AUCTION .. ": ") .. C(WHITE, tostring(agg.total))
		.. LeadSuffix(agg, CHAT_OPTS)
end

local function PrintUsage()
	Chat(ChatHeader(L.CHAT_USAGE))
end

local function RunFind(rawQuery)
	local ownedFilter, auctionFilter = ChatFilters()

	-- A pasted item link is an exact ask, so it always gets one answer line -- a 0 is
	-- the answer (the zero-total tooltip rule's chat twin); no guardrails apply. The
	-- aggregate is the hovered path's own: a quality good answers its name-group
	-- combined total, exactly like its tooltip.
	local link = rawQuery:match("|Hitem:.-|h%[.-%]|h")
	local linkID = link and GetItemInfoInstant(link)
	if linkID then
		local agg = ComputeAggregate(linkID, link, ownedFilter)
		Chat(ChatHeader("") .. link .. C(WHITE, ": " .. tostring(agg.total))
			.. LeadSuffix(agg, CHAT_OPTS) .. AuctionTail(linkID, link, auctionFilter))
		return
	end

	local q = SanitizeQuery(rawQuery)
	if #q < FIND_MIN_QUERY then
		Chat(ChatHeader(L.CHAT_TOO_SHORT:format(FIND_MIN_QUERY)))
		return
	end
	local needle = q:lower() -- ASCII-only folding: on a non-English client, names match
	                         -- case-sensitively outside A-Z (known gap, see DESIGN.md)

	-- The id universe: every owned store PLUS the auction stores -- an item that is
	-- 100% listed must still match (owned-only would answer "no matches" while a stack
	-- sits on the AH). Owned representatives win; auction-only ids may carry a nil
	-- commodity link and then resolve by cached name or not at all (the same accepted
	-- failure mode the sibling join has).
	local ids, repLinks = ns.CollectItemIDs(ownedFilter)
	local aIds, aLinks = ns.CollectItemIDs(auctionFilter)
	for id in pairs(aIds) do
		ids[id] = true
		if repLinks[id] == nil then repLinks[id] = aLinks[id] end
	end

	-- pairs() order is undefined: sort the universe so the lowest matched id seeds a
	-- quality name-group deterministically (stable output, stable tests).
	local sorted = {}
	for id in pairs(ids) do
		sorted[#sorted + 1] = id
	end
	table.sort(sorted)

	-- One line per match, where a quality good's whole name-group is ONE match: the
	-- seed's aggregate joins its siblings, which are then consumed so the group can't
	-- print twice. Consumption comes from agg.members -- the accepted set -- so an
	-- unrelated namesake or a cold-cache sibling rejected by the tier predicate stays
	-- unconsumed and prints its own disjoint line (the all-or-nothing rule keeps the
	-- totals from double-counting; the printed links disambiguate).
	local consumed, results = {}, {}
	for _, id in ipairs(sorted) do
		if not consumed[id] then
			local name = ns.ItemName(id, repLinks[id])
			if name and name:lower():find(needle, 1, true) then
				local agg = ComputeAggregate(id, repLinks[id], ownedFilter)
				if agg.tier then
					consumed[id] = true
					for _, member in ipairs(agg.members) do
						consumed[member.itemID] = true
					end
				end
				results[#results + 1] = {
					id = id, name = name, link = repLinks[id], agg = agg,
					exact = name:lower() == needle,
				}
			end
		end
	end

	local found = #results
	if found == 0 then
		Chat(ChatHeader(L.CHAT_NO_MATCHES:format(q)))
		return
	end
	table.sort(results, function(a, b)
		if a.exact ~= b.exact then return a.exact end
		if a.agg.total ~= b.agg.total then return a.agg.total > b.agg.total end
		if a.name ~= b.name then return a.name < b.name end
		return a.id < b.id -- namesakes: deterministic order
	end)

	Chat(ChatHeader((found == 1 and L.CHAT_MATCH_ONE or L.CHAT_MATCH_MANY):format(found, q)))
	for i = 1, math.min(found, FIND_MAX_RESULTS) do
		local r = results[i]
		-- A stored link renders itself (clickable, quality-colored -- never wrap it in
		-- C()); a linkless entry falls back to the plain name.
		Chat("  " .. (r.link or C(WHITE, r.name)) .. C(WHITE, ": " .. tostring(r.agg.total))
			.. LeadSuffix(r.agg, CHAT_OPTS) .. AuctionTail(r.id, repLinks[r.id], auctionFilter))
	end
	if found > FIND_MAX_RESULTS then
		Chat("  " .. C(DIM, L.CHAT_MORE:format(found - FIND_MAX_RESULTS)))
	end
end

-- `/eic locale`: which text language the addon shows -- a testing tool, there so a
-- translation can be checked on any client. Bare, it lists the registered codes; a code
-- (or "default": follow the game client again) is SAVED rather than applied live,
-- because the options panel's labels are registered once -- the choice takes effect
-- through a /reload. Its own lines are plain English on purpose, never read from the
-- string table: this command is the way back from a language you cannot read.
local function RunLocale(rest)
	local codes = ns.GetLocaleCodes()
	local choices = table.concat(codes, " | ") .. " | default"
	local s = ns.GetSettings and ns.GetSettings()
	if rest == "" or not s then
		Chat(ChatHeader("locale: " .. choices .. "  (showing " .. ns.GetLocaleCode()
			.. ", set to " .. (s and s.locale or "default") .. ")"))
		return
	end
	local want = rest:lower() -- codes are matched case-insensitively
	if want == "default" then
		s.locale = nil
		Chat(ChatHeader("locale: default (the game client's language). /reload to apply."))
		return
	end
	for _, code in ipairs(codes) do
		if code:lower() == want then
			s.locale = code
			Chat(ChatHeader("locale: " .. code .. ". /reload to apply."))
			return
		end
	end
	Chat(ChatHeader("locale: no translation '" .. SanitizeQuery(rest) .. "'. Available: " .. choices))
end

-- The slash router's seam: every non-empty /eic message lands here (Settings.lua owns
-- only the empty-message panel-open). Unknown subcommands get the usage line.
function ns.ChatCommand(msg)
	local cmd, rest = msg:match("^(%S+)%s*(.-)%s*$")
	cmd = cmd and cmd:lower()
	if cmd == "find" and rest ~= "" then
		RunFind(rest)
	elseif cmd == "locale" then
		RunLocale(rest)
	else
		PrintUsage()
	end
end

-- Live update for the "[modifier] held" settings: when the configured key flips while a
-- tooltip is up, RefreshData() re-runs the stored tooltip info through the full
-- processing pipeline -- including the post-call above, which re-reads the key state.
-- The rebuild replaces lines rather than appending, and bails for AddLine-built tooltips
-- (which never carry this section anyway). Guards run cheapest-first: this event fires on
-- every Shift/Alt/Ctrl press anywhere, combat included. It does NOT fire while an EditBox
-- has keyboard focus, so a tooltip left open while typing in chat keeps its state until
-- the key is next pressed outside a text field -- known, accepted.
local KEY_TO_MOD = {
	LSHIFT = "SHIFT", RSHIFT = "SHIFT",
	LALT = "ALT", RALT = "ALT",
	LCTRL = "CTRL", RCTRL = "CTRL",
}

-- Whether any setting actually varies with the modifier; if none does, a key flip cannot
-- change the rendered section and the rebuild is skipped.
local function ModifierMatters(s)
	return s.bankMode == "modifier" or s.warbandMode == "modifier"
		or s.equippedMode == "modifier" or s.altsMode == "modifier"
		or s.mailMode == "modifier"
		or s.suffixMode == "modifier" or s.rowsMode == "modifier"
		or s.bankMerge == "modifier" or s.recipeProductMode == "modifier"
		or s.auctionsMode == "modifier"
		or (s.altsExpandKey and s.altsDetail ~= "all")
end

-- The Blizzard item tooltips the watcher rebuilds in place: the main hover tooltip, the
-- chat-link popup, and the two comparison tooltips. The section renders on any
-- GameTooltipTemplate frame, but only these known frames are refreshed on a key flip --
-- anything else keeps the key state it rendered with when it opened. All four globals
-- exist before addons load; RefreshData (GameTooltipDataMixin, verified in live FrameXML)
-- is presence-checked per frame, so a frame without it is simply left alone.
local WATCHED_TOOLTIPS = { GameTooltip, ItemRefTooltip, ShoppingTooltip1, ShoppingTooltip2 }

local modWatcher = CreateFrame("Frame")
modWatcher:RegisterEvent("MODIFIER_STATE_CHANGED")
modWatcher:SetScript("OnEvent", function(_, _, key)
	local s = ns.GetSettings and ns.GetSettings()
	if not s or KEY_TO_MOD[key] ~= s.modifier then return end
	if not ModifierMatters(s) then return end
	for _, tip in ipairs(WATCHED_TOOLTIPS) do
		if tip:IsShown() and tip.RefreshData then
			tip:RefreshData()
		end
	end
end)
