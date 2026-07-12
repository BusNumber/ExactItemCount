-- tests/run_tests.lua -- headless test suite for Exact Item Count.
--
-- Loads the REAL Core.lua / Tooltip.lua / Settings.lua against tests/wow_stubs.lua and
-- asserts the DESIGN.md invariants: the grand total equals the sum of the rows under
-- every filter combination, every location suffix sums to its line's count, the settings
-- sanitizer round-trips, bank snapshots are never wiped unreadable, and quality-sibling
-- membership is all-or-nothing. Each test loads a fresh addon world via loadAddon().
--
-- Usage: luajit tests/run_tests.lua
-- Anything the stubs cannot model (real panel rendering, atlas art, RefreshData's actual
-- pipeline, item-cache timing, taint) belongs on CONTRIBUTING.md's in-game checklist.

local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
local root = here .. ".." .. (here:find("\\") and "\\" or "/")
local stubs = dofile(here .. "wow_stubs.lua")

-- ---------------------------------------------------------------- framework

local tests = {}
local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

-- Compact value rendering for failure messages (sorted keys for determinism).
local function repr(v, depth)
	depth = depth or 0
	if type(v) == "string" then return string.format("%q", v) end
	if type(v) ~= "table" then return tostring(v) end
	if depth > 3 then return "{...}" end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = tostring(k) .. "=" .. repr(v[k], depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function fail(msg)
	error(msg, 3) -- blame the assertion's caller
end

local function assertTrue(cond, msg)
	if not cond then fail(msg or "expected a true value") end
end

local function deepEqual(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function assertEq(got, want, msg)
	local equal
	if type(got) == "table" and type(want) == "table" then
		equal = deepEqual(got, want)
	else
		equal = got == want
	end
	if not equal then
		fail((msg and msg .. ": " or "") .. "expected " .. repr(want) .. ", got " .. repr(got))
	end
end

-- ---------------------------------------------------------------- addon loading

local ADDON_FILES = { "Core.lua", "Tooltip.lua", "Settings.lua" } -- TOC order

-- Boots a fresh addon world:
--   opts.setup(stubs)   runs after install() and BEFORE the files load -- the place for
--                       ITEM_UPGRADE_TOOLTIP_FORMAT_STRING overrides (frozen into Core's
--                       trackPattern at load), world seeding, M.realm = nil, ...
--   opts.db             the SavedVariables value; a function receives stubs and returns
--                       it (so fixtures can build links in the fresh world). Fixture-
--                       driven tests must also pass noPEW = true: the PLAYER_ENTERING_
--                       WORLD scans would overwrite the seeded own-character snapshots
--                       with the (empty) world model.
--   opts.files          override the loaded files (e.g. drop Settings.lua to exercise
--                       the nil-settings default display).
--   opts.noAddonLoaded / opts.noPEW   skip the default lifecycle events.
local function loadAddon(opts)
	opts = opts or {}
	stubs.install()
	if opts.setup then opts.setup(stubs) end
	local db = opts.db
	if type(db) == "function" then db = db(stubs) end
	_G.ExactItemCountDB = db
	local ns = {}
	for _, file in ipairs(opts.files or ADDON_FILES) do
		assert(loadfile(root .. file))("ExactItemCount", ns)
	end
	if not opts.noAddonLoaded then stubs.fire("ADDON_LOADED", "ExactItemCount") end
	if not opts.noPEW then stubs.fire("PLAYER_ENTERING_WORLD") end
	return ns, stubs
end

-- ---------------------------------------------------------------- shared helpers

local H = {}

H.OWN = "Tester-TestRealm" -- the stub identity's DB key

local MID = " \194\183 " -- the UTF-8 middle-dot separator production emits

-- Strips inline color escapes; the atlas markup stub is already plain text.
function H.strip(s)
	return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- Runs the captured tooltip post-call against a fake tooltip that records AddLine
-- calls; returns the fake (lines in tip.lines).
function H.hover(data, opts)
	assertTrue(stubs.itemPostCall, "no tooltip post-call registered -- was Tooltip.lua loaded?")
	local tip = { lines = {}, forbidden = opts and opts.forbidden or false }
	tip.IsForbidden = function(self) return self.forbidden end
	tip.AddLine = function(self, text) self.lines[#self.lines + 1] = text end
	stubs.itemPostCall(tip, data)
	return tip
end

function H.plainLines(tip)
	local out = {}
	for i, raw in ipairs(tip.lines) do
		out[i] = H.strip(raw)
	end
	return out
end

-- Splits one rendered line into (count, suffix tokens, body). The suffix is the trailing
-- parenthesized group; suffix tokens never contain parens, so greedy body matching keeps
-- a track badge like "(H 2/6)" (always followed by the count) out of the suffix. The
-- count is the body's trailing number.
function H.parseLine(raw)
	local s = H.strip(raw)
	local body, suffix = s:match("^(.*)%s%(([^()]*)%)$")
	body = body or s
	local count = tonumber(body:match("(%d+)$"))
	local tokens
	if suffix then
		tokens = {}
		for tok in (suffix .. MID):gmatch("(.-)" .. MID) do
			tokens[#tokens + 1] = tok
		end
	end
	return count, tokens, body
end

-- Every suffix must sum exactly to its line's count -- each token ("bags 2", "banks 7",
-- "Liara 140", "+2 alts 22") contributes its trailing number. Lines without a suffix
-- pass vacuously.
function H.assertSuffixSums(raw)
	local count, tokens = H.parseLine(raw)
	if not tokens then return end
	assertTrue(count, "suffixed line with no count: " .. H.strip(raw))
	local sum = 0
	for _, tok in ipairs(tokens) do
		local n = tonumber(tok:match("(%d+)$"))
		assertTrue(n, "suffix token without a count: " .. tok)
		sum = sum + n
	end
	if sum ~= count then
		fail("suffix sums to " .. sum .. ", line count is " .. count .. ": " .. H.strip(raw))
	end
end

-- The section-wide invariant: the grand total equals the sum of the breakdown rows
-- (when rows rendered), and every suffixed line sums. Returns the total.
function H.assertSectionInvariant(tip)
	local totalLine, rowSum
	for _, raw in ipairs(tip.lines) do
		local s = H.strip(raw)
		if s:find("^Total items owned:") then
			totalLine = raw
		elseif s:find("^  ") then -- breakdown rows are indented two spaces
			local count = H.parseLine(raw)
			assertTrue(count, "row with no count: " .. s)
			rowSum = (rowSum or 0) + count
		end
		H.assertSuffixSums(raw)
	end
	assertTrue(totalLine, "no total line rendered")
	local total = H.parseLine(totalLine)
	if rowSum then
		assertEq(rowSum, total, "rows must sum to the grand total")
	end
	return total
end

-- DB-shape fixture builders (see the schema comment atop Core.lua).
function H.dbItems(stacks)
	local items = {}
	for _, s in ipairs(stacks) do
		local entry = items[s.id]
		if not entry then
			entry = { total = 0, groups = {} }
			items[s.id] = entry
		end
		entry.total = entry.total + s.count
		if entry.link == nil then entry.link = s.link end
		local ilvl = s.ilvl or 0
		local group = entry.groups[ilvl]
		if not group then
			group = { count = 0, link = s.link, track = s.track }
			entry.groups[ilvl] = group
		end
		group.count = group.count + s.count
	end
	return items
end

function H.snap(items)
	return { scannedAt = 900, items = items }
end

function H.charStore(t)
	return {
		bags = t.bags and H.snap(t.bags) or nil,
		bank = t.bank and H.snap(t.bank) or nil,
		equipped = t.equipped and H.snap(t.equipped) or nil,
	}
end

-- t = { chars = { [key] = charStore }, warband = items, settings = table }
function H.db(t)
	return {
		version = 1,
		chars = t.chars or {},
		warband = t.warband and H.snap(t.warband) or nil,
		settings = t.settings,
	}
end

-- Iterates the 32 display-filter combinations (bags is always true -- no setting).
function H.eachFilter(fn)
	local bools = { true, false }
	for _, bank in ipairs(bools) do
		for _, warband in ipairs(bools) do
			for _, equipped in ipairs(bools) do
				for _, alts in ipairs(bools) do
					for _, altEquipped in ipairs(bools) do
						fn({
							bags = true,
							bank = bank,
							warband = warband,
							equipped = equipped,
							alts = alts,
							altEquipped = altEquipped,
						})
					end
				end
			end
		end
	end
end

-- Sum of a ns.Get sources table (own tags + all alts).
function H.sumSources(sources)
	local sum = 0
	for k, v in pairs(sources) do
		if k == "alts" then
			for _, n in pairs(v) do sum = sum + n end
		else
			sum = sum + v
		end
	end
	return sum
end

-- Zero counts must never be recorded anywhere in a sources table.
function H.assertNoZeros(sources)
	for k, v in pairs(sources) do
		if k == "alts" then
			for name, n in pairs(v) do
				assertTrue(n ~= 0, "zero alt count recorded for " .. name)
			end
		else
			assertTrue(v ~= 0, "zero count recorded for " .. k)
		end
	end
end

-- ---------------------------------------------------------------- specs + runner

local T = {
	test = test,
	assertTrue = assertTrue,
	assertEq = assertEq,
	fail = fail,
	deepEqual = deepEqual,
	loadAddon = loadAddon,
	stubs = stubs,
	H = H,
}

for _, spec in ipairs({ "core_spec.lua", "settings_spec.lua", "tooltip_spec.lua" }) do
	assert(loadfile(here .. spec))(T)
end

local passed, failed = 0, 0
for _, t in ipairs(tests) do
	local ok, err = xpcall(t.fn, debug.traceback)
	if ok then
		passed = passed + 1
		print("PASS " .. t.name)
	else
		failed = failed + 1
		print("FAIL " .. t.name .. "\n" .. tostring(err))
	end
end
print(("-- %d/%d passed"):format(passed, passed + failed))
if failed > 0 then os.exit(1) end
