local addonName, ns = ...

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
		alts = SourceEnabled(s.altsMode, down),
		altEquipped = s.altEquipped, -- whether alts' worn gear folds into their per-alt count
		hiddenChars = s.hiddenChars,
	}, down
end

-- Location breakdown for one count, pre-colored: " (bags 2 · bank 1 · warband 3 · Liara 1)".
-- Fixed order bags / bank(s) / warband / equipped / alts, alts by count descending (name
-- ascending as a stable tiebreak); zero-count locations never appear (the aggregator omits
-- them), so an empty sources table -- and the synthetic owned-0 rows that have none at all
-- -- yields "". The whole "bags N" token renders one step brighter than the rest: "how many
-- on me right now" is one glance, and no bright token anywhere reads as "none on you".
-- "equipped" (the current character's worn gear) sits at the dim base like bank/warband.
-- Bare bags/bank/equipped always mean the current character; alts are name + count only,
-- containers combined.
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
		Add(SUFFIX_BAGS, "bags " .. tostring(sources.bags))
	end
	if opts.mergeBanks and sources.bank and sources.warband then
		Add(SUFFIX, "banks " .. tostring(sources.bank + sources.warband))
	else
		if sources.bank then
			Add(SUFFIX, "bank " .. tostring(sources.bank))
		end
		if sources.warband then
			Add(SUFFIX, "warband " .. tostring(sources.warband))
		end
	end
	if sources.equipped then
		Add(SUFFIX, "equipped " .. tostring(sources.equipped))
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
			Add(SUFFIX, "alts " .. tostring(sum))
		else
			local named = #names
			if opts.altsDetail == "topn" and opts.topN + 1 < #names then
				named = opts.topN -- the tail is 2+ alts, worth collapsing
			end
			for i = 1, named do
				Add(SUFFIX, names[i] .. " " .. tostring(sources.alts[names[i]]))
			end
			if named < #names then
				local count, sum = 0, 0
				for j = named + 1, #names do
					count = count + 1
					sum = sum + sources.alts[names[j]]
				end
				Add(SUFFIX, "+" .. tostring(count) .. " alts " .. tostring(sum))
			end
		end
	end
	if #parts == 0 then return "" end
	-- "\194\183" is the UTF-8 middle dot; escaped so the separator survives any
	-- editor/encoding mishap.
	return C(SUFFIX, " (") .. table.concat(parts, C(SUFFIX, " \194\183 ")) .. C(SUFFIX, ")")
end

-- The section's lead line. `suffix` is an optional pre-colored tail -- the location
-- breakdown of the total, present whenever the total is above zero.
local function AddTotal(tooltip, n, suffix)
	tooltip:AddLine(C(ACCENT, "Total items owned: ") .. C(WHITE, tostring(n)) .. (suffix or ""))
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
local function ShowGearBreakdown(tooltip, entry, link, hoveredTrack, opts)
	-- `link` can legitimately be nil (TooltipData's id and hyperlink are both optional);
	-- without one there is no hovered ilvl to resolve, and the rows below handle that.
	local hoveredIlvl = link and GetDetailedItemLevelInfo(link)
	local rows, seen = {}, {}
	if entry then
		for ilvl in pairs(entry.groups) do
			rows[#rows + 1] = ilvl
			seen[ilvl] = true
		end
	end
	if hoveredIlvl and not seen[hoveredIlvl] then
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
			label = C(labelColor, "ilvl " .. ilvl .. ":")
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
local function ShowQualityBreakdown(tooltip, members, tiers, hoveredTier, hoveredAtlas, opts)
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
	if hoveredTier and not rows[hoveredTier] then
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

local function OnItemTooltip(tooltip, data)
	-- Post-calls fire for EVERY tooltip inheriting GameTooltipTemplate (comparison and
	-- chat-link popups, quest rewards, third-party frames) -- deliberately kept: counts
	-- are as useful on a linked item as on a bag hover. Secure (forbidden) tooltips are
	-- the exception; addon code must not touch them.
	if tooltip:IsForbidden() then return end
	if not data then return end

	-- `data.id` is the canonical id of the item actually being shown -- trust it over the
	-- link. A recipe tooltip embeds its crafted product, so the displayed link can resolve
	-- to that product (which you own 0 of) rather than the recipe; if the link disagrees
	-- with data.id it isn't ours, so drop it (the count keys off the id regardless).
	local itemID = data.id
	local link = data.hyperlink
	if not link and TooltipUtil then
		local _, displayed = TooltipUtil.GetDisplayedItem(tooltip)
		link = displayed
	end
	local linkID = link and GetItemInfoInstant(link)
	if itemID and linkID and linkID ~= itemID then
		link = nil
	elseif not itemID then
		itemID = linkID
	end
	if not itemID then return end

	local _, _, _, itemEquipLoc = GetItemInfoInstant(link or itemID)

	-- Equippable items (weapons, armour, profession tools/accessories) get a per-ilvl
	-- breakdown; the shared gate in Core.lua excludes bags and non-equippables (whose
	-- equip loc is "INVTYPE_NON_EQUIP_IGNORE", not "").
	local isGear = ns.IsGearEquipLoc(itemEquipLoc)

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

	-- The total is needed before any line is added: a zero total can drop the whole
	-- section (settings opt-in), and a hidden section must not leave a stray spacer.
	local entry, members, combined, tiers
	local tier, atlas
	if not isGear then
		tier, atlas = GetQuality(link, false)
	end
	local total
	if tier then
		-- Membership on top of the name join: a sibling counts only if its tier resolves
		-- right now, so an id whose stored link can't produce a quality (cold cache -- an
		-- alt-owned itemID this session has never seen -- or an unrelated same-name item)
		-- contributes neither a row nor a total share; the data layer applies the same
		-- all-or-nothing rule it uses for filtered-out sources. Resolved tiers are kept
		-- so the renderer works from the exact set that built the total. Rejected ids get
		-- their item data requested -- a later hover then includes them.
		tiers = {}
		local function accept(id, repLink)
			if id == itemID then
				-- The hovered item opened this section; its tier already resolved from
				-- the hovered link, so it can never drop out of its own total.
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
		_, members, combined = ns.GetByName(itemID, filter, accept)
		total = combined.total
	else
		entry = ns.Get(itemID, filter)
		total = entry and entry.total or 0
	end
	if total == 0 and s and s.hideZero then return end

	tooltip:AddLine(" ")

	if isGear then
		-- All equippable gear has an item level worth showing (it's in Blizzard's tooltip
		-- even for plain dropped pieces), so owned gear gets the per-ilvl breakdown. A zero
		-- total stands alone: every row under it would just restate the zero. The hovered
		-- tooltip's own lines supply the upgrade track for the synthetic owned-0 row, which
		-- has no stored group to read it from.
		AddTotal(tooltip, total, entry and SourceSuffix(entry.sources, opts) or nil)
		if total > 0 and showRows then
			local hoveredTrack
			local name, step, max = ns.ParseUpgradeTrack(data.lines)
			if name then
				hoveredTrack = { name = name, step = step, max = max }
			end
			ShowGearBreakdown(tooltip, entry, link, hoveredTrack, opts)
		end
	elseif tier then
		-- Quality good: tiers combined across name siblings, one row per tier.
		AddTotal(tooltip, total, total > 0 and SourceSuffix(combined.sources, opts) or nil)
		if total > 0 and showRows then
			ShowQualityBreakdown(tooltip, members, tiers, tier, atlas, opts)
		end
	else
		-- Plain item (no quality, no variable level): just the total.
		AddTotal(tooltip, total, entry and SourceSuffix(entry.sources, opts) or nil)
	end
end

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)

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
		or s.suffixMode == "modifier" or s.rowsMode == "modifier"
		or s.bankMerge == "modifier"
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
