-- The game's spells, to find one by name as you type. Two sources: the index that comes with the
-- addon (SpellIndex.lua: the auras of every class and race, of talents and of items, with where they
-- land and what they do), and a
-- list of every spell this client knows by name, read from the client itself in the background and
-- kept between sessions (AuraLedgerSpells). That reading takes about a millisecond of each frame,
-- only out of a fight, with a bar on screen while it goes; it is done once, and again only when the
-- game itself changes, or the language it is played in. Spells the ledger sees are added as they come.
local _, ns = ...
local SpellDB = {}
ns.SpellDB = SpellDB

local floor, max = math.floor, math.max
local lower = string.lower
-- Of each frame, out of a fight; and a ceiling on ids asked in one frame whatever the clock says.
local BUDGET_MS = 1
local MAX_PER_STEP = 4000
-- After login, so it does not add to the loading.
local START_AFTER = 15
-- How far past the highest id known the client is asked, in case it has newer spells.
local MARGIN = 100000
-- The most ids one name hands the game, for a tracker added by name.
local IDS_CAP = 64
-- The client has no spells at all from 474742 to 1213144 (1.60.1): the reading steps over that
-- stretch, as other addons on this client do, which more than halves it.
local GAP_FROM, GAP_TO = 474800, 1213100

local stats = { asked = 0, found = 0, steps = 0, ms = 0, lastStepIds = 0 }
SpellDB.stats = stats
local startAt = math.huge

-- ------------------------------------------------------------------
-- The index that comes with the addon, read the first time it is wanted.
-- ------------------------------------------------------------------
-- The groups of the index, in the order the spell list shows them: a class's own spells, its
-- talents, its procs and set bonuses, its pets'; racials; world buffs; what items do, by kind;
-- mounts; the rest.
local GROUPS = {
	{ "s", "Spells" }, { "a", "Talents" }, { "p", "Procs and set bonuses" }, { "h", "Pet abilities" }, { "r", "Racials" },
	{ "w", "World buffs" },
	{ "f", "Flasks and elixirs" }, { "o", "Potions" }, { "e", "Food and drink" }, { "c", "Scrolls" }, { "b", "Bandages" },
	{ "x", "Explosives and devices" }, { "n", "Other consumables" }, { "k", "Trinkets" }, { "g", "Gear" },
	{ "q", "Quest and other items" }, { "m", "Mounts" }, { "z", "Other" },
}
local groupRank, groupName = {}, {}
for i, g in ipairs(GROUPS) do groupRank[g[1]], groupName[g[1]] = i, g[2] end
function SpellDB.GroupName(code) return groupName[code] or "Other" end

local index, indexByName
local function Index()
	if index then return index end
	index, indexByName = {}, {}
	for _, line in ipairs(ns.SPELL_INDEX or {}) do
		local name, ids, where, class, group, desc = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$")
		if name and name ~= "" then
			local list = {}
			for id in ids:gmatch("%d+") do list[#list + 1] = tonumber(id) end
			local e = { name = name, lower = lower(name), ids = list, where = where, class = (class ~= "" and class) or nil,
				group = groupName[group] and group or "z", desc = (desc ~= "" and desc) or nil }
			e.lowerDesc = e.desc and lower(e.desc)
			index[#index + 1] = e
			local l = indexByName[e.lower]
			if not l then l = {} indexByName[e.lower] = l end
			l[#l + 1] = e
		end
	end
	return index
end
SpellDB.Index = Index

-- ------------------------------------------------------------------
-- The list on this machine.
-- ------------------------------------------------------------------
local function DB()
	if type(AuraLedgerSpells) ~= "table" then AuraLedgerSpells = {} end
	return AuraLedgerSpells
end

-- The client, by version and build: a new one may have new spells, so the list is read again.
local function ClientKey()
	if type(GetBuildInfo) ~= "function" then return "?" end
	local ok, version, build = pcall(GetBuildInfo)
	if not ok then return "?" end
	return tostring(version) .. "." .. tostring(build)
end

-- How a spell's name is asked: by id, from the client's own spell data, any spell at all.
local GetName
local function Resolve()
	if C_Spell and type(C_Spell.GetSpellName) == "function" then
		GetName = C_Spell.GetSpellName
	elseif C_Spell and type(C_Spell.GetSpellInfo) == "function" then
		GetName = function(id) local info = C_Spell.GetSpellInfo(id) return info and info.name end
	elseif type(GetSpellInfo) == "function" then
		GetName = function(id) return (GetSpellInfo(id)) end
	end
	return GetName
end

local namesDirty = true
function SpellDB.Init()
	local db = DB()
	db.v = 1
	db.names = type(db.names) == "table" and db.names or {}
	db.learned = type(db.learned) == "table" and db.learned or {}
	-- Names are in the game's own language: another language reads everything again.
	local locale = (type(GetLocale) == "function" and GetLocale()) or "?"
	if db.locale ~= locale then
		db.names, db.learned, db.scan, db.build = {}, {}, nil, nil
		db.locale = locale
	end
	local key = ClientKey()
	if db.build ~= key then
		-- A new client: read it all again. What was read from the last one serves until this is done.
		db.build = key
		db.scan, db.next, db.done, db.found = {}, 1, false, 0
	elseif not db.done then
		db.scan = type(db.scan) == "table" and db.scan or {}
		db.next = tonumber(db.next) or 1
	end
	db.ceiling = max(tonumber(ns.SPELL_MAX_ID) or 0, tonumber(db.highest) or 0) + MARGIN
	if not Resolve() then
		db.done = true
		ns.report["spell list"] = "this client has no way to ask a spell's name by id"
	end
	startAt = (GetTime and GetTime() or 0) + START_AFTER
	namesDirty = true
end

-- Read again from the start, as for a new client; switched back on, and after an error too.
function SpellDB.Restart()
	local db = DB()
	db.build, db.off = nil, nil
	ns.spellListFailed = nil
	if SpellDB.ResetBar then SpellDB.ResetBar() end
	SpellDB.Init()
	startAt = 0
end

-- A spell the addon has seen, by name and id.
function SpellDB.Learn(name, id)
	if type(name) ~= "string" or name == "" or type(id) ~= "number" then return end
	if issecretvalue and (issecretvalue(name) or issecretvalue(id)) then return end
	local db = AuraLedgerSpells
	if type(db) ~= "table" or type(db.learned) ~= "table" then return end
	local have = db.learned[name]
	if have then
		for x in have:gmatch("%d+") do if tonumber(x) == id then return end end
	end
	db.learned[name] = have and (have .. "," .. id) or tostring(id)
	namesDirty = true
end

-- How many ids come before this one, the empty stretch left out.
local function Asked(id)
	if id > GAP_TO then return id - 1 - (GAP_TO - GAP_FROM + 1) end
	if id > GAP_FROM then return GAP_FROM - 1 end
	return id - 1
end

-- How far the reading has got: done (or switched off, or stopped), and the share of ids asked.
function SpellDB.Progress()
	local db = AuraLedgerSpells
	if type(db) ~= "table" or db.done or not db.scan or db.off or ns.spellListFailed then return true, 1 end
	local ceiling = tonumber(db.ceiling) or 1
	return false, math.min(1, max(0, Asked(tonumber(db.next) or 1) / max(1, Asked(ceiling + 1))))
end

-- ------------------------------------------------------------------
-- The bar: on screen only while the list is being read.
-- ------------------------------------------------------------------
local bar, barOff
local function Bar()
	if bar then return bar end
	bar = CreateFrame("StatusBar", nil, UIParent)
	bar:SetSize(220, 8)
	bar:SetPoint("TOP", UIParent, "TOP", 0, -96)
	bar:SetFrameStrata("LOW")
	bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	bar:SetStatusBarColor(0.35, 0.6, 1)
	bar:SetMinMaxValues(0, 1)
	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(bar)
	bg:SetColorTexture(0, 0, 0, 0.55)
	bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	bar.text:SetPoint("BOTTOM", bar, "TOP", 0, 2)
	bar:EnableMouse(true)
	bar:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText("Aura Ledger", 1, 1, 1)
		GameTooltip:AddLine("Reading the game's spell list, so that any spell can be found by name as you type. It takes a moment of each frame, only out of a fight, and is done once for each version and language of the game.", 0.9, 0.9, 0.9, true)
		GameTooltip:AddLine("Right-click to hide this bar; the reading goes on. /auraledger debug spells off stops the reading.", 0.6, 0.8, 1, true)
		GameTooltip:Show()
	end)
	bar:SetScript("OnLeave", function() GameTooltip:Hide() end)
	bar:SetScript("OnMouseUp", function(self, button)
		if button == "RightButton" then
			barOff = true
			self:Hide()
			GameTooltip:Hide()
		end
	end)
	bar:Hide()
	return bar
end

-- Asked to read it all again: the bar comes back, even if it was hidden.
function SpellDB.ResetBar() barOff = nil end

function SpellDB.UpdateBar()
	local done, share = SpellDB.Progress()
	local fight = InCombatLockdown and InCombatLockdown()
	if done or barOff or fight or (GetTime and GetTime() or 0) < startAt then
		if bar then bar:Hide() end
		return
	end
	local b = Bar()
	b:SetValue(share)
	b.text:SetText(("Aura Ledger is reading the game's spell list: %d%%"):format(floor(share * 100)))
	b:Show()
end

-- ------------------------------------------------------------------
-- The reading, a little each frame.
-- ------------------------------------------------------------------
function SpellDB.Step()
	local db = AuraLedgerSpells
	if type(db) ~= "table" or db.done or type(db.scan) ~= "table" or not GetName or db.off then
		if bar and bar:IsShown() then bar:Hide() end
		return
	end
	local now = GetTime and GetTime() or 0
	if now < startAt then return end
	if InCombatLockdown and InCombatLockdown() then
		if bar and bar:IsShown() then bar:Hide() end
		return
	end
	local clock = type(debugprofilestop) == "function" and debugprofilestop or nil
	local t0 = clock and clock()
	local id, ceiling, scan = tonumber(db.next) or 1, tonumber(db.ceiling) or 1, db.scan
	local n, found = 0, 0
	while id <= ceiling and n < MAX_PER_STEP do
		if id >= GAP_FROM and id <= GAP_TO then id = GAP_TO + 1 end
		if id > ceiling then break end
		local name = GetName(id)
		if type(name) == "string" and name ~= "" and not (issecretvalue and issecretvalue(name)) then
			local have = scan[name]
			scan[name] = have and (have .. "," .. id) or tostring(id)
			found = found + 1
			if id > (tonumber(db.highest) or 0) then db.highest = id end
			-- Newer spells than the index knows: look further.
			if id + MARGIN / 2 > ceiling then
				ceiling = id + MARGIN
				db.ceiling = ceiling
			end
		end
		id = id + 1
		n = n + 1
		if t0 and n % 50 == 0 and clock() - t0 >= BUDGET_MS then break end
	end
	db.next, db.found = id, (tonumber(db.found) or 0) + found
	stats.asked, stats.found, stats.steps, stats.lastStepIds = stats.asked + n, stats.found + found, stats.steps + 1, n
	if t0 then stats.ms = stats.ms + (clock() - t0) end
	if found > 0 then namesDirty = true end
	if id > ceiling then
		-- Read to the end: this is the list now.
		db.names, db.scan, db.done, db.finishedAt = scan, nil, true, time and time() or 0
		namesDirty = true
		ns.report["spell list"] = ("read: %d spells by name"):format(db.found or 0)
		if ns.UI and ns.UI.RefreshHistory then ns.UI:RefreshHistory() end
	end
	SpellDB.UpdateBar()
end

-- ------------------------------------------------------------------
-- Finding a spell.
-- ------------------------------------------------------------------
-- Every name on this machine not already in the index, lowercased once and kept until it changes.
local localNames, localAt = {}, -100
local function LocalNames()
	local now = GetTime and GetTime() or 0
	if not namesDirty or now - localAt < 2 then return localNames end
	Index()
	local db = AuraLedgerSpells
	local seen, list = {}, {}
	for _, t in ipairs({ type(db) == "table" and db.learned, type(db) == "table" and db.names, type(db) == "table" and db.scan }) do
		if type(t) == "table" then
			for name in pairs(t) do
				local l = lower(name)
				if not seen[name] and not indexByName[l] then
					seen[name] = true
					list[#list + 1] = { name = name, lower = l, client = true }
				end
			end
		end
	end
	localNames, localAt, namesDirty = list, now, false
	return list
end

-- Every id a name has, from both sources and what has been seen (at most IDS_CAP). Nil for none.
function SpellDB.Ids(name)
	if type(name) ~= "string" or name == "" then return nil end
	Index()
	local out, n = {}, 0
	local function add(id)
		if id and n < IDS_CAP and not out[id] then out[id] = true n = n + 1 end
	end
	for _, e in ipairs(indexByName[lower(name)] or {}) do
		for _, id in ipairs(e.ids) do add(id) end
	end
	local db = AuraLedgerSpells
	if type(db) == "table" then
		for _, t in ipairs({ db.learned, db.names, db.scan }) do
			local s = type(t) == "table" and t[name]
			if s then for x in s:gmatch("%d+") do add(tonumber(x)) end end
		end
	end
	return n > 0 and out or nil
end

-- Of the index's lines of one name, the one to show: your own class's, then another class's or a
-- racial's, then an item's; a debuff on your target before one on you, before a buff.
local WHERE_RANK = { t = 0, d = 1, o = 2, y = 3 }
local function LineRank(e, mine)
	local c = e.class
	return ((c and c == mine) and 0 or ((c and c ~= "ITEM") and 10 or 20)) + (WHERE_RANK[e.where] or 4)
end
local function Best(list, mine)
	local best, rank
	for _, e in ipairs(list or {}) do
		local r = LineRank(e, mine)
		if not best or r < rank then best, rank = e, r end
	end
	return best
end
local function Mine() return ns.PlayerClass and ns.PlayerClass() or nil end

-- A spell by its exact name, any case: its proper name, the id to show it by, every id it has, and
-- where it lands if the index says.
function SpellDB.Find(text, id)
	if type(text) ~= "string" or text == "" then return nil end
	Index()
	local l = lower(text)
	local lines, e = indexByName[l], nil
	-- A spell the character knows: the line that holds its own id.
	if id and lines then
		for _, x in ipairs(lines) do
			for _, i in ipairs(x.ids) do if i == id then e = x break end end
			if e then break end
		end
	end
	e = e or Best(lines, Mine())
	if e then return { name = e.name, id = e.ids[1], ids = SpellDB.Ids(e.name), where = e.where, class = e.class, desc = e.desc } end
	for _, r in ipairs(LocalNames()) do
		if r.lower == l then return { name = r.name, ids = SpellDB.Ids(r.name) } end
	end
	return nil
end

-- Spells whose name has the words typed in it, one line per name: the name itself first, then the
-- index's auras (names starting with the words, then holding them, then auras whose own text does, so
-- "frozen" finds Frost Nova), then names only this client knows. At most limit, and whether there were more. The same
-- search again, with nothing new learned, gives back the same answer without looking again.
local last = {}
local function byLower(a, b) return a.lower < b.lower end
function SpellDB.Search(text, limit)
	limit = limit or 40
	local q = lower(tostring(text or ""))
	if #q < 2 then return {}, false end
	local names = LocalNames()
	local mine = Mine()
	if last.q == q and last.limit == limit and last.names == names and last.mine == mine then return last.out, last.more end
	Index()
	local exact, starts, inside, effect, cstarts, cinside, seen = {}, {}, {}, {}, {}, {}, {}
	for _, e in ipairs(index) do
		if not seen[e.lower] then
			local at = e.lower:find(q, 1, true)
			if at or (e.lowerDesc and e.lowerDesc:find(q, 1, true)) then
				seen[e.lower] = true
				local best = Best(indexByName[e.lower], mine)
				if e.lower == q then exact[#exact + 1] = best
				elseif at == 1 then starts[#starts + 1] = best elseif at then inside[#inside + 1] = best else effect[#effect + 1] = best end
			end
		end
	end
	for _, r in ipairs(names) do
		local at = r.lower:find(q, 1, true)
		if at then
			if r.lower == q then exact[#exact + 1] = r elseif at == 1 then cstarts[#cstarts + 1] = r else cinside[#cinside + 1] = r end
		end
	end
	-- Each group is sorted only if any of it can still be shown.
	local out, more = {}, false
	for _, group in ipairs({ exact, starts, inside, effect, cstarts, cinside }) do
		if #group > 0 then
			if #out >= limit then
				more = true
			else
				table.sort(group, byLower)
				for _, e in ipairs(group) do
					if #out >= limit then more = true break end
					out[#out + 1] = e
				end
			end
		end
	end
	-- A name only this client knows is shown with its ids.
	for i, e in ipairs(out) do
		if not e.ids then
			local list = {}
			for id in pairs(SpellDB.Ids(e.name) or {}) do list[#list + 1] = id end
			table.sort(list)
			out[i] = { name = e.name, lower = e.lower, ids = list, fromClient = true }
		end
	end
	last.q, last.limit, last.names, last.mine, last.out, last.more = q, limit, names, mine, out, more
	return out, more
end

-- The index to browse: every line of one class (or RACIAL, ITEM, OTHER for none, ALL) that lands
-- where asked (all, buff for on you or on you and others, d, t), group by group, by name in each.
-- The index never changes, so each is worked out once.
local browsed = {}
local function byName(a, b)
	local ga, gb = groupRank[a.group] or 99, groupRank[b.group] or 99
	if ga ~= gb then return ga < gb end
	if a.lower ~= b.lower then return a.lower < b.lower end
	return (a.ids[1] or 0) < (b.ids[1] or 0)
end
function SpellDB.Browse(who, where)
	Index()
	local key = tostring(who) .. "\0" .. tostring(where)
	if browsed[key] then return browsed[key] end
	local out = {}
	for _, e in ipairs(index) do
		local c = e.class
		local okWho = who == "ALL" or (who == "OTHER" and not c) or (c ~= nil and c == who)
		local okWhere = where == "all" or (where == "buff" and (e.where == "y" or e.where == "o")) or e.where == where
		if okWho and okWhere then out[#out + 1] = e end
	end
	table.sort(out, byName)
	browsed[key] = out
	return out
end

-- Every other name this client knows, by name: as much as has been read so far.
local browsedClient = {}
function SpellDB.BrowseClient()
	local names = LocalNames()
	if browsedClient.names == names then return browsedClient.out end
	-- Rebuilt with nothing added (an id learned for a name already known): the same list, kept.
	local src = type(AuraLedgerSpells) == "table" and AuraLedgerSpells.names or nil
	if browsedClient.out and #browsedClient.out == #names and browsedClient.src == src then
		browsedClient.names = names
		return browsedClient.out
	end
	local out = {}
	for i, r in ipairs(names) do out[i] = r end
	table.sort(out, function(a, b) return a.lower < b.lower end)
	browsedClient.names, browsedClient.out, browsedClient.src = names, out, src
	return out
end

-- /auraledger debug spells: where the list is, and what the reading has cost.
function SpellDB.Report(emit, rest)
	local word = lower(rest or "")
	if word == "again" then
		SpellDB.Restart()
		emit("The game's spell list will be read again from the start, out of a fight.")
		return
	end
	if word == "off" or word == "on" then
		local db = DB()
		if word == "off" then
			db.off = true
			emit("The game's spell list is no longer read. Search still finds the auras that come with the addon, and what was read before. /auraledger debug spells on starts it again.")
		else
			db.off, ns.spellListFailed = nil, nil
			startAt = 0
			emit(db.done and "The game's spell list is read already." or "The game's spell list is read again from where it stopped, out of a fight.")
		end
		SpellDB.UpdateBar()
		return
	end
	local db = AuraLedgerSpells
	local count = function(t) local n = 0 for _ in pairs(type(t) == "table" and t or {}) do n = n + 1 end return n end
	local done, share = SpellDB.Progress()
	emit(("Index that comes with the addon: %d entries (game build %s). This client: %s, language %s."):format(#Index(), tostring(ns.SPELL_INDEX_BUILD),
		tostring(db and db.build), tostring(db and db.locale)))
	emit(("Read from this client: %s; %d names kept, %d more while reading, %d seen by the addon."):format(
		done and "done" or ("%d%% (id %d of %d)"):format(floor(share * 100), tonumber(db and db.next) or 0, tonumber(db and db.ceiling) or 0),
		count(db and db.names), count(db and db.scan), count(db and db.learned)))
	emit(("This session: %d ids asked over %d frames, %d named, %.0f ms in all (%d ids in the last frame). Asked with %s."):format(
		stats.asked, stats.steps, stats.found, stats.ms, stats.lastStepIds,
		(C_Spell and C_Spell.GetSpellName) and "C_Spell.GetSpellName" or (GetName and "a fallback" or "nothing (cannot read names here)")))
	if db and db.off then emit("Switched off: /auraledger debug spells on starts it again.") end
	if ns.spellListFailed then emit("Stopped after an error (" .. tostring(ns.report["spell list"]) .. "): /auraledger debug spells again tries again.") end
	emit("/auraledger debug spells again reads it all again; /auraledger debug spells off stops the reading.")
end
