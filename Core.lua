-- Aura Ledger core: saved data, the aura reader, the history ledger, show conditions, slash commands.
--
-- This client hides aura data from addons while "addon restrictions" are active (combat, encounters,
-- some maps): values come back secret, and asking for a secret aura can be a Lua error. So every read
-- goes through pcall and Clean(), and while auras are unreadable the last known state is carried
-- forward (timers keep counting, removals still arrive by aura instance id, and the combat log is
-- used when the client delivers it). Anything carried or estimated is flagged so the display can
-- mark it. "/auraledger debug" reports what actually worked.

local ADDON, ns = ...
ns.VERSION = "1.73.1"
ns.report = {}
ns.stats = { scans = 0, partial = 0, blocked = 0, cleu = 0, cleuUsed = 0, estimated = 0, removedById = 0, casts = 0, castsUsed = 0 }
-- Kept so anything still reading them finds a table rather than nothing.
ns.frameIconStats, ns.viewerStats, ns.shadowStats = {}, {}, {}
ns.auras = {}
ns.env = {}
ns.QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

local MAX_INDEX = 80
local HISTORY_CAP = 1500

local strlower, floor, max, min = string.lower, math.floor, math.max, math.min

-- Everything printed is also kept in the saved variables (AuraLedgerDB.log, newest last), so the
-- output of the diagnostic commands can be read from disk after a /reload instead of from chat.
local LOG_CAP, CHAT_CAP = 3000, 1500
local pendingLog, pendingChat = {}, {}
local function Append(db, field, pending, cap, line)
	if db then
		db[field] = db[field] or {}
		local list = db[field]
		if #pending > 0 then
			for _, l in ipairs(pending) do list[#list + 1] = l end
			for i = #pending, 1, -1 do pending[i] = nil end
		end
		list[#list + 1] = line
		if #list > cap + 200 then
			local keep = {}
			for i = #list - cap + 1, #list do keep[#keep + 1] = list[i] end
			db[field] = keep
		end
	else
		pending[#pending + 1] = line
	end
end
local function Stamp(text)
	return (date and date("%H:%M:%S") or "") .. " " .. tostring(text)
end
local function LogLine(text)
	Append(ns.db, "log", pendingLog, LOG_CAP, Stamp(text))
end
ns.LogLine = LogLine
-- Every line that reaches the main chat frame, from anyone, color codes stripped.
local function ChatLine(text)
	if type(text) ~= "string" or (issecretvalue and issecretvalue(text)) then return end
	Append(ns.db, "chat", pendingChat, CHAT_CAP, Stamp((text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""))))
end
if hooksecurefunc and DEFAULT_CHAT_FRAME then
	pcall(hooksecurefunc, DEFAULT_CHAT_FRAME, "AddMessage", function(_, text) ChatLine(text) end)
end
-- The chat window itself keeps only about 128 lines by default; long outputs scroll away.
if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.SetMaxLines then
	pcall(DEFAULT_CHAT_FRAME.SetMaxLines, DEFAULT_CHAT_FRAME, 2000)
end

local function YesNo(v) return v and "|cff40ff40yes|r" or "|cffff5050no|r" end
ns.YesNo = YesNo

local function Print(msg)
	if issecretvalue and issecretvalue(msg) then msg = "(secret value)" end
	msg = tostring(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffAura Ledger:|r " .. msg)
	LogLine((msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
end
ns.Print = Print

-- ------------------------------------------------------------------
-- Secret-value helpers
-- ------------------------------------------------------------------
local function Clean(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end
ns.Clean = Clean

local function AurasSecret()
	if C_Secrets and C_Secrets.ShouldAurasBeSecret then
		local ok, v = pcall(C_Secrets.ShouldAurasBeSecret)
		return ok and Clean(v) == true
	end
	return false
end
ns.AurasSecret = AurasSecret

local function IndexSecret(unit, i, filter)
	if C_Secrets and C_Secrets.ShouldUnitAuraIndexBeSecret then
		local ok, v = pcall(C_Secrets.ShouldUnitAuraIndexBeSecret, unit, i, filter)
		return (not ok) or Clean(v) ~= false
	end
	return false
end

local function InstanceSecret(unit, id)
	if C_Secrets and C_Secrets.ShouldUnitAuraInstanceBeSecret then
		local ok, v = pcall(C_Secrets.ShouldUnitAuraInstanceBeSecret, unit, id)
		return (not ok) or Clean(v) ~= false
	end
	return false
end

-- ------------------------------------------------------------------
-- Spell info
-- ------------------------------------------------------------------
-- name, icon, spellID for a spell id or (known) spell name; nils when the client can't resolve it.
function ns.SpellInfo(idOrName)
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, idOrName)
		if ok and type(info) == "table" and Clean(info.name) then
			return Clean(info.name), Clean(info.iconID) or Clean(info.originalIconID), Clean(info.spellID)
		end
	end
	if GetSpellInfo then
		local ok, name, _, icon, _, _, _, id = pcall(GetSpellInfo, idOrName)
		if ok and Clean(name) then return Clean(name), Clean(icon), Clean(id) end
	end
	if type(idOrName) == "number" and C_Spell and C_Spell.GetSpellTexture then
		local ok, icon = pcall(C_Spell.GetSpellTexture, idOrName)
		if ok and Clean(icon) then return nil, Clean(icon), idOrName end
	end
end

-- ------------------------------------------------------------------
-- Ranks
--
-- The game draws a slot only for the spell ids it is handed, and a combat sound is registered
-- against one id at a time, so a rank nobody has told it about is invisible to it. Every rank known
-- here is handed over: the ranks bundled in Data.lua (ns.RANK_IDS, kept only where this client
-- agrees an id carries that name), every rank in your own spellbook, and any seen on you. Ids are
-- only ever looked up one at a time; stepping through id ranges is what crashed another addon.
-- A rank the client has not loaded yet is asked for and looked up again a second later, four times.
-- ------------------------------------------------------------------
local rankIndex, rankState = nil, {}
ns.rankState = rankState
-- Forgets what was worked out, for a table that has changed.
function ns.ResetRanks()
	rankIndex = nil
	for k in pairs(rankState) do rankState[k] = nil end
end

function ns.Ranks(name)
	if type(name) ~= "string" or type(ns.RANK_IDS) ~= "table" then return nil end
	if not rankIndex then
		rankIndex = {}
		for spell, ids in pairs(ns.RANK_IDS) do rankIndex[strlower(spell)] = { spell = spell, ids = ids } end
	end
	local row = rankIndex[strlower(name)]
	if not row then return nil end
	local st = rankState[row.spell]
	if not st then
		st = { ids = {}, tries = 0, kept = 0, dropped = 0, pending = #row.ids, at = -100 }
		rankState[row.spell] = st
	end
	local now = GetTime and GetTime() or 0
	if st.pending > 0 and st.tries < 4 and now - st.at >= 1 then
		st.tries, st.at = st.tries + 1, now
		local before = st.kept
		st.kept, st.dropped, st.pending = 0, 0, 0
		local want = strlower(row.spell)
		for _, id in ipairs(row.ids) do
			local n = ns.SpellInfo(id)
			if n and strlower(n) == want then
				st.ids[id] = true
				st.kept = st.kept + 1
			elseif n then
				st.dropped = st.dropped + 1
			else
				st.pending = st.pending + 1
				if C_Spell and C_Spell.RequestLoadSpellData then pcall(C_Spell.RequestLoadSpellData, id) end
			end
		end
		-- A rank that turned up late changes what the slots and sounds were given.
		if st.tries > 1 and st.kept > before then ns.ranksChanged = true end
		if st.pending > 0 and st.tries < 4 and C_Timer and C_Timer.After then
			local spell = row.spell
			C_Timer.After(1.05, function() ns.Ranks(spell) end)
		end
	end
	if st.kept == 0 then return nil end
	return st.ids
end

-- Every rank of every spell in your spellbook, by lower-case name. The client lists each rank you
-- know, even where its own spellbook shows only the highest.
ns.bookRanks = {}
function ns.LearnBookRanks()
	if not ns.SpellBookGeneral then return end
	local ok, spells = pcall(ns.SpellBookGeneral)
	if not ok or type(spells) ~= "table" then return end
	local grew = false
	for _, s in ipairs(spells) do
		local name, id = Clean(s.name), tonumber(Clean(s.id))
		if type(name) == "string" and id then
			local l = strlower(name)
			ns.bookRanks[l] = ns.bookRanks[l] or {}
			if not ns.bookRanks[l][id] then ns.bookRanks[l][id] = true grew = true end
		end
	end
	if grew then ns.ranksChanged = true end
end

-- All the ids known for a spell by name, or nil.
function ns.RankIds(name)
	if type(name) ~= "string" then return nil end
	local out, any = {}, false
	local bundled = ns.Ranks(name)
	if bundled then for id in pairs(bundled) do out[id] = true any = true end end
	local own = ns.bookRanks[strlower(name)]
	if own then for id in pairs(own) do out[id] = true any = true end end
	return any and out or nil
end

-- ------------------------------------------------------------------
-- Saved data
-- ------------------------------------------------------------------
local function CharKey()
	local name = UnitName and UnitName("player") or "Unknown"
	local realm = GetRealmName and GetRealmName() or "Realm"
	return tostring(name) .. "-" .. tostring(realm)
end

function ns.InitDB()
	if type(AuraLedgerDB) ~= "table" then AuraLedgerDB = {} end
	local db = AuraLedgerDB
	db.version = db.version or 1
	db.history = type(db.history) == "table" and db.history or {}
	db.chars = type(db.chars) == "table" and db.chars or {}
	db.nextUid = db.nextUid or 1
	if db.minimapShown == nil then db.minimapShown = true end
	db.minimapAngle = db.minimapAngle or 200
	local key = CharKey()
	db.chars[key] = type(db.chars[key]) == "table" and db.chars[key] or {}
	local profile = db.chars[key]
	profile.groups = type(profile.groups) == "table" and profile.groups or {}
	for _, g in ipairs(profile.groups) do
		g.trackers = type(g.trackers) == "table" and g.trackers or {}
		g.cond = type(g.cond) == "table" and g.cond or {}
		g.liveOnlyMine = nil -- retired: the combat question covers this properly
		g.live = nil -- retired: a group the game filled could not honor the list put in it
		-- Trackers are buffs on you: an aura on another unit cannot be followed through a fight.
		for _, t in ipairs(g.trackers) do
			t.unit = nil
			t.kind = "buff"
		end
		g.watch = nil -- retired: the ~ in front of a carried time already says it
		-- Group size used to be three boxes; it is a number of players now.
		local function MigrateGroupSize(c)
			if type(c) ~= "table" or type(c.group) ~= "table" then return end
			local set = c.group
			c.group = nil
			if set.solo then return end -- "solo too" means any size
			if set.party then c.minGroup = 2 elseif set.raid then c.minGroup = 6 end
		end
		MigrateGroupSize(g.cond)
		for _, t in ipairs(g.trackers) do MigrateGroupSize(t.cond) end
		-- Retired conditions: resting, mounted and having a target were rarely what anyone meant.
		for _, key in ipairs({ "resting", "mounted", "target" }) do
			if g.cond then g.cond[key] = nil end
			for _, t in ipairs(g.trackers) do if t.cond then t.cond[key] = nil end end
		end
		for _, t in ipairs(g.trackers) do t.cond = type(t.cond) == "table" and t.cond or {} end
	end
	ns.db, ns.profile, ns.charKey = db, profile, key
end

function ns.NewUid()
	local id = ns.db.nextUid
	ns.db.nextUid = id + 1
	return id
end

-- Something about the layout changed: redraw everything that shows it.
function ns.Changed()
	if ns.WantSwingEvents then ns.WantSwingEvents() end
	ns.FitAllCells()
	if ns.Display and ns.Display.Rebuild then ns.Display:Rebuild() end
	if ns.UI and ns.UI.RefreshLayout then ns.UI:RefreshLayout() end
end

-- ------------------------------------------------------------------
-- The shape of an icon group
-- ------------------------------------------------------------------
-- A group of icons holds a cell for each of its trackers: c across and r down, in the group's own
-- flow space, so the same numbers mean the same thing whichever way the group grows. The icons
-- that are on screen fill the cells in order, which is why a shape that is a plain block of rows
-- behaves exactly as rows always did, and why a tracker going quiet lets the rest close up.
-- The list is always kept in reading order, r then c, and the trackers are kept in step with it,
-- so what the ledger lists top to bottom is what the shape reads left to right.

local function CellKey(c, r) return tostring(r) .. ":" .. tostring(c) end
local function CellOrder(cell) return (cell.r or 0) * 8192 + (cell.c or 0) end

-- Where the next tracker goes. A tracker joins the end of the group's list, so its cell has to join
-- the end of the shape: a cell that read earlier than one already in use would take that place and
-- push every icon after it along. In plain rows the two are the same thing, because rows are filled
-- without gaps. In a shape somebody has built, it is the first free cell after the last one in use.
function ns.NextFreeCell(g)
	local perRow = max(1, tonumber(g.perRow) or 8)
	local taken, last = {}, -1
	for _, cell in ipairs(g.cells or {}) do
		taken[CellKey(cell.c, cell.r)] = true
		local order = CellOrder(cell)
		if order > last then last = order end
	end
	local r = 0
	while r < 500 do
		for c = 0, perRow - 1 do
			if not taken[CellKey(c, r)] and CellOrder({ c = c, r = r }) > last then return c, r end
		end
		r = r + 1
	end
	return 0, 0
end

-- Which cell a tracker is standing in: the list is in reading order and the trackers fill it in
-- order, so a tracker's place in the group is its place in the shape.
function ns.CellOf(g, t)
	if not g or not g.cells then return nil end
	for i, other in ipairs(g.trackers) do if other == t then return g.cells[i], i end end
end

-- Is that cell empty? A tracker does not count as being in its own way.
function ns.CellFree(g, c, r, except)
	local skip
	if except then
		for i, other in ipairs(g.trackers) do if other == except then skip = i break end end
	end
	for i, cell in ipairs(g.cells or {}) do
		if i ~= skip and cell.c == c and cell.r == r then return false end
	end
	return true
end

-- Puts the shape back into reading order. The cells are places and nothing else, so this moves no
-- trackers: which tracker stands where is its place in the group's own list.
function ns.SortCells(g)
	local cells = g.cells
	if not cells or #cells < 2 then return end
	table.sort(cells, function(a, b) return CellOrder(a) < CellOrder(b) end)
end

-- The shape is held against its own top left corner, so that building upwards or to the left does
-- not drag the group across the screen, and a row with nothing left in it closes up.
function ns.NormalizeCells(g)
	local cells = g.cells
	if not cells or #cells == 0 then return end
	local mc, mr
	for _, cell in ipairs(cells) do
		cell.c, cell.r = tonumber(cell.c) or 0, tonumber(cell.r) or 0
		if not mc or cell.c < mc then mc = cell.c end
		if not mr or cell.r < mr then mr = cell.r end
	end
	if (mc or 0) ~= 0 or (mr or 0) ~= 0 then
		for _, cell in ipairs(cells) do cell.c, cell.r = cell.c - mc, cell.r - mr end
	end
end

-- A row left with nothing in it closes up, and the rows under it move up. A row is only ever made
-- by opening one and filling it at the same time, so an empty one is never something somebody
-- wanted. Gaps within a row are left alone: those are put there on purpose.
function ns.CloseEmptyRows(g)
	local cells = g and g.cells
	if not cells or #cells == 0 then return end
	local used = {}
	for _, cell in ipairs(cells) do used[cell.r] = true end
	local rows = {}
	for r in pairs(used) do rows[#rows + 1] = r end
	table.sort(rows)
	local rank, moved = {}, false
	for i, r in ipairs(rows) do
		rank[r] = i - 1
		if rank[r] ~= r then moved = true end
	end
	if not moved then return end
	for _, cell in ipairs(cells) do cell.r = rank[cell.r] end
end

-- One cell per tracker, no more and no less. A tracker that has just been added takes the next
-- free cell; one that has gone takes the last cell of the shape with it, which is what lets the
-- rest close up.
function ns.FitCells(g)
	if not g or g.style == "bars" then return end
	local n = #g.trackers
	local cells = g.cells
	if not cells then cells = {} g.cells = cells end
	while #cells > n do table.remove(cells) end
	while #cells < n do
		local c, r = ns.NextFreeCell(g)
		cells[#cells + 1] = { c = c, r = r }
	end
	ns.SortCells(g)
	ns.NormalizeCells(g)
	ns.CloseEmptyRows(g)
end

function ns.FitAllCells()
	if not ns.profile then return end
	for _, g in ipairs(ns.profile.groups) do ns.FitCells(g) end
end

-- A shape that is not the plain rows this group's width would give is one somebody built, which is
-- how a cluster made before the shape was remembered is recognized. Run at startup, and harmless
-- afterwards: a group laid back out in rows matches the rows again and loses the mark.
function ns.MarkShapedGroups()
	if not ns.profile then return end
	for _, g in ipairs(ns.profile.groups) do
		if g.style ~= "bars" and g.cells then
			local perRow = max(1, tonumber(g.perRow) or 8)
			local built = false
			for i, cell in ipairs(g.cells) do
				if cell.c ~= (i - 1) % perRow or cell.r ~= floor((i - 1) / perRow) then built = true break end
			end
			g.shaped = built or nil
		end
	end
end

-- Makes room at (c, r) and puts the tracker in it. "row" opens a whole line there and moves
-- everything from that line on along; "col" opens one place in that line only. The tracker's own
-- cell is taken out first, so a move within the same group does not shove itself along.
function ns.OpenCellAt(g, t, c, r, axis)
	if not g or not t or g.style == "bars" then return false end
	ns.FitCells(g)
	local _, idx = ns.CellOf(g, t)
	if not idx then return false end
	local mine = table.remove(g.cells, idx)
	table.remove(g.trackers, idx)
	if axis == "row" then
		for _, cell in ipairs(g.cells) do
			if cell.r >= r then cell.r = cell.r + 1 end
		end
	else
		for _, cell in ipairs(g.cells) do
			if cell.r == r and cell.c >= c then cell.c = cell.c + 1 end
		end
	end
	mine.c, mine.r = c, r
	g.cells[#g.cells + 1] = mine
	ns.SortCells(g)
	local pos
	for i, cell in ipairs(g.cells) do if cell == mine then pos = i break end end
	ns.NormalizeCells(g)
	if not pos then return false end
	table.insert(g.trackers, pos, t)
	g.shaped = true
	return true
end

-- Where a dragged tracker lands. Held against a free cell it takes that cell and nothing else
-- moves. Held against a seam it opens a place there. Otherwise it is an ordinary drop at a place in
-- the group's list.
function ns.DropTracker(t, to, index, c, r, axis)
	if not t or not to then return false end
	if c and to.style ~= "bars" then
		local from = ns.FindGroupOf(t)
		if from ~= to then ns.MoveTracker(t, to) else ns.FitCells(to) end
		local placed = axis and ns.OpenCellAt(to, t, c, r, axis) or ns.PlaceTrackerCell(to, t, c, r)
		if placed then
			ns.Changed()
			return true
		end
		return false
	end
	ns.MoveTracker(t, to, index)
	return false
end

-- Lays the shape out as plain rows again, the group's width wide, and forgets that it was ever
-- built by hand: rows close up when a tracker goes quiet, which is what rows have always done.
function ns.ReflowCells(g)
	if not g then return end
	g.cells, g.shaped = nil, nil
	ns.FitCells(g)
end

-- Gives one tracker a cell of its own. Its old place leaves the shape and the new one joins it, and
-- because the trackers fill the shape in order the tracker moves up or down the group's list to
-- wherever that cell ended up. A cell another icon is standing in is refused, so two icons can
-- never be asked to stand in the same place.
function ns.PlaceTrackerCell(g, t, c, r)
	if not g or not t or g.style == "bars" then return false end
	ns.FitCells(g)
	if not ns.CellFree(g, c, r, t) then return false end
	local _, idx = ns.CellOf(g, t)
	if not idx then return false end
	local cell = { c = c, r = r }
	table.remove(g.cells, idx)
	table.insert(g.cells, cell)
	ns.SortCells(g)
	local pos
	for i, other in ipairs(g.cells) do if other == cell then pos = i break end end
	ns.NormalizeCells(g)
	if not pos then return false end
	table.remove(g.trackers, idx)
	table.insert(g.trackers, pos, t)
	-- The shape was built rather than laid out, so from here on every icon keeps its own cell
	-- instead of the icons closing up into the front of the shape.
	g.shaped = true
	return true
end

-- ------------------------------------------------------------------
-- History ledger
-- ------------------------------------------------------------------
-- One row per aura name and kind (ranks share a row; every id seen is remembered in .ids).
local function HistoryKey(kind, name) return kind .. ":" .. strlower(name) end

local function PruneHistory()
	local n = 0
	for _ in pairs(ns.db.history) do n = n + 1 end
	if n <= HISTORY_CAP then return end
	local list = {}
	for key, h in pairs(ns.db.history) do
		if not h.manual then list[#list + 1] = { key = key, last = h.last or 0 } end
	end
	table.sort(list, function(a, b) return a.last < b.last end)
	for i = 1, min(#list, n - HISTORY_CAP + 50) do ns.db.history[list[i].key] = nil end
end

-- Trackers added by hand before the aura was ever seen learn its icon / id / name here.
local function TeachTrackers(e)
	local lname = strlower(e.name)
	for _, g in ipairs(ns.profile.groups) do
		for _, t in ipairs(g.trackers) do
			local byName = t.name and strlower(t.name) == lname
			local byId = t.id and e.id and t.id == e.id
			if byName or byId then
				if e.icon and (not t.icon or t.icon == ns.QUESTION) then t.icon = e.icon end
				if byName and not t.id and e.id then t.id = e.id end
				if byId and not t.name then t.name = e.name end
			end
		end
	end
end

-- Returns true when the ledger gained or changed a row worth redrawing.
function ns.RecordAura(e, quiet)
	if not e.name then return false end
	local history = ns.db.history
	local key = HistoryKey(e.kind, e.name)
	local h = history[key]
	local now = time()
	if not h then
		h = { name = e.name, kind = e.kind, first = now, count = 0, ids = {} }
		history[key] = h
		-- A hand-added placeholder for the same aura is now redundant.
		local manual = history[HistoryKey("any", e.name)]
		if manual and manual.manual then history[HistoryKey("any", e.name)] = nil end
		if e.id and history["id:" .. e.id] then history["id:" .. e.id] = nil end
		TeachTrackers(e)
		PruneHistory()
		quiet = false
	end
	if not quiet then h.count = (h.count or 0) + 1 end
	h.last = now
	h.onYou = true
	h.ids = h.ids or {}
	if e.id then h.id = e.id h.ids[e.id] = true end
	if e.icon then h.icon = e.icon end
	if e.duration and e.duration > 0 and not e.estimated then h.duration = e.duration end
	if e.dispel then h.dispel = e.dispel end
	return true
end

-- Add a ledger row by spell name, id or link. Returns the row, or nil and a message.
function ns.AddManual(text)
	text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then return nil, "Type a spell name or a spell ID first." end
	local linkId = text:match("|Hspell:(%d+)")
	local id = tonumber(linkId or text)
	local history = ns.db.history
	if id then
		id = floor(id)
		for _, h in pairs(history) do
			if h.ids and h.ids[id] then return h end
		end
		local name, icon = ns.SpellInfo(id)
		if not name and not icon then
			-- Unknown to the client right now; keep it by id and learn the rest when it is seen.
			local h = { id = id, kind = "any", manual = true, first = time(), last = time(), count = 0, ids = { [id] = true }, idOnly = true }
			history["id:" .. id] = h
			return h
		end
		if not name then
			local h = { id = id, icon = icon, kind = "any", manual = true, first = time(), last = time(), count = 0, ids = { [id] = true }, idOnly = true }
			history["id:" .. id] = h
			return h
		end
		local key = HistoryKey("any", name)
		local h = history[key] or { name = name, kind = "any", manual = true, first = time(), count = 0, ids = {} }
		h.id, h.icon, h.last, h.byId = id, icon or h.icon, time(), true
		h.ids[id] = true
		history[key] = h
		return h
	end
	for _, kind in ipairs({ "buff", "debuff", "any" }) do
		local h = history[HistoryKey(kind, text)]
		if h then return h end
	end
	local name, icon, spellId = ns.SpellInfo(text)
	if not icon and ns.BookPages then
		-- Not a spell this character knows; the pre-built book may still have its icon.
		for _, list in pairs(ns.BookPages()) do
			for _, item in ipairs(list) do
				if strlower(item.name) == strlower(text) then
					ns.ResolveBookItem(item)
					name, icon, spellId = item.name, item.icon, item.id
				end
			end
		end
	end
	local h = { name = name or text, icon = icon, id = spellId, kind = "any", manual = true, first = time(), last = time(), count = 0, ids = {} }
	if spellId then h.ids[spellId] = true end
	history[HistoryKey("any", h.name)] = h
	return h
end

function ns.ForgetHistory(h)
	for key, row in pairs(ns.db.history) do
		if row == h then ns.db.history[key] = nil return true end
	end
end

-- ------------------------------------------------------------------
-- Layout model: groups of trackers. A lone tracker is simply a group of one.
-- ------------------------------------------------------------------
function ns.NewTracker(h)
	local idOnly = h.idOnly or not h.name
	return {
		uid = ns.NewUid(),
		name = h.name, id = h.id, icon = h.icon,
		kind = "buff",
		cd = h.cd or nil,
		item = h.item or nil,
		-- A weapon slot (0 main hand, 1 off hand, 2 ranged) for a weapon-enchant or a swing tracker.
		enchant = h.enchant,
		swing = h.swing,
		matchId = (idOnly or h.byId) and true or false,
		show = "active",
		mine = false,
		cond = {},
	}
end

-- The look of a group, copied when a tracker is pulled out into a group of its own.
ns.GROUP_STYLE_KEYS = { "style", "size", "barW", "barH", "barIconScale", "spacing", "perRow", "scale", "alpha", "timers", "names", "grow", "border", "background", "iconFrame", "gameDrawn" }

-- How big the icon on a bar is: the bar's own height by default, and anything from half that to
-- twice it. Kept here so the addon's bars and the slots the game fills agree on the answer.
function ns.BarIconSize(g)
	local h = g.barH or 22
	local scale = tonumber(g.barIconScale) or 1
	if scale < 0.5 then scale = 0.5 elseif scale > 2 then scale = 2 end
	return math.max(8, math.floor(h * scale + 0.5))
end

-- What a game-drawn group can show: Blizzard's aura filters for the player.
function ns.NewGroupLike(g, x, y)
	local ng = ns.NewGroup(x or ((g.x or 500) + 30), y or ((g.y or 400) - 60))
	for _, key in ipairs(ns.GROUP_STYLE_KEYS) do ng[key] = g[key] end
	-- The look is copied; the shape is not. A new group is a row of its own.
	ng.cells = nil
	return ng
end

function ns.NewGroup(x, y)
	local g = {
		uid = ns.NewUid(),
		x = x, y = y,
		style = "icons", grow = "RIGHT",
		size = 40, barW = 190, barH = 22, spacing = 4, perRow = 8,
		scale = 1, alpha = 1,
		timers = true, names = true,
		cond = {}, trackers = {},
	}
	table.insert(ns.profile.groups, g)
	return g
end

function ns.GroupName(g)
	if g.name and g.name ~= "" then return g.name end
	local first = g.trackers[1]
	if #g.trackers == 1 and first then return first.name or ("Spell " .. tostring(first.id)) end
	return "Group " .. tostring(g.uid)
end

function ns.FindGroupOf(t)
	for gi, g in ipairs(ns.profile.groups) do
		for ti, tr in ipairs(g.trackers) do
			if tr == t then return g, ti, gi end
		end
	end
end

function ns.DeleteGroup(g)
	for i, other in ipairs(ns.profile.groups) do
		if other == g then table.remove(ns.profile.groups, i) break end
	end
	if ns.selected and (ns.selected.group == g) then ns.selected = nil end
	ns.Changed()
end

function ns.RemoveTracker(t)
	local g, ti = ns.FindGroupOf(t)
	if not g then return end
	-- Its own cell goes with it, so the icons after it keep the places they had, and a row it
	-- leaves empty closes up.
	if g.cells and g.cells[ti] then table.remove(g.cells, ti) end
	table.remove(g.trackers, ti)
	if ns.selected and ns.selected.tracker == t then ns.selected = { group = g } end
	if #g.trackers == 0 then return ns.DeleteGroup(g) end
	ns.Changed()
end

-- Move a tracker into group "to" at index (nil = end). Empty source groups disappear.
function ns.MoveTracker(t, to, index)
	local from, ti = ns.FindGroupOf(t)
	if from then
		if from.cells and from.cells[ti] then table.remove(from.cells, ti) end
		table.remove(from.trackers, ti)
		if from == to and index and index > ti then index = index - 1 end
	end
	index = index and max(1, min(index, #to.trackers + 1)) or (#to.trackers + 1)
	table.insert(to.trackers, index, t)
	if from and from ~= to and #from.trackers == 0 then
		for i, other in ipairs(ns.profile.groups) do
			if other == from then table.remove(ns.profile.groups, i) break end
		end
	end
	if ns.selected and ns.selected.tracker == t then ns.selected.group = to end
	ns.Changed()
end

-- Track a ledger row: into an existing group, or as a new group of one at x, y (UIParent units).
function ns.TrackHistory(h, group, index, x, y)
	local t = ns.NewTracker(h)
	if not group then
		if not x then
			local n = #ns.profile.groups
			x = (UIParent:GetWidth() or 1024) / 2 - 20 + (n % 6) * 12
			y = (UIParent:GetHeight() or 768) / 2 + 120 - (n % 6) * 12
		end
		group = ns.NewGroup(x, y)
	end
	index = index and max(1, min(index, #group.trackers + 1)) or (#group.trackers + 1)
	table.insert(group.trackers, index, t)
	ns.selected = { group = group, tracker = t }
	ns.Changed()
	return t, group
end

-- ------------------------------------------------------------------
-- Show conditions
-- ------------------------------------------------------------------
ns.CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
-- How a player count reads: the sizes that mean something in this game, and what to call them.
function ns.GroupSizeLabel(n)
	n = tonumber(n) or 1
	if n <= 1 then return "Any group size" end
	if n == 2 then return "2 players or more" end
	if n <= 5 then return n .. " players or more (a party)" end
	return n .. " players or more (a raid)"
end
ns.PLACES = { { "world", "Open world" }, { "dungeon", "Dungeon" }, { "raid", "Raid instance" }, { "bg", "Battleground" }, { "arena", "Arena" } }
-- Combat is asked as its own pair of questions in the options panel, because who draws a group in
-- combat belongs with whether it is shown at all. The rest are plain three-way toggles.
ns.TOGGLES = {
	{ "combat", "Combat", "In combat", "Out of combat" },
	{ "alive", "Alive", "Alive", "Dead or ghost" },
}

local function Bool(f, ...)
	if type(f) ~= "function" then return false end
	local ok, v = pcall(f, ...)
	if not ok then return false end
	v = Clean(v)
	return v and v ~= 0 and true or false
end

local function EnvSignature(e)
	return table.concat({ tostring(e.combat), tostring(e.group), tostring(e.groupSize), tostring(e.place),
		tostring(e.resting), tostring(e.mounted), tostring(e.target), tostring(e.alive),
		tostring(e.talentSet), tostring(e.mainTree) }, "|")
end

-- Your talent trees: each one's name, icon and points spent, read the way the game's talent frame
-- reads them. Kept until the next talent event: nothing here changes in a fight. Your main tree is
-- the one with the most points; with none spent, or a tie, there is no main tree and a condition
-- on it lets everything through.
ns.talentTrees = nil

-- Whether a talent condition rules this character out. A tree that is not one of yours (a group
-- shared by another class) and a talent set on a character with only one say nothing, and let
-- everything through, as does anything not read yet.
function ns.TalentConditionFails(c)
	local e = ns.env
	if not c then return false end
	if c.talentSet and e.talentSet and (tonumber(e.talentSets) or 1) > 1 and c.talentSet ~= e.talentSet then return true end
	if c.tree and e.mainTree and c.tree ~= e.mainTree then
		for _, tr in ipairs(ns.talentTrees or {}) do
			if tr.name == c.tree then return true end
		end
	end
	return false
end

function ns.ReadTalents()
	local e = ns.env
	local function Call(fn, ...)
		if type(fn) ~= "function" then return nil end
		local ok, v = pcall(fn, ...)
		return ok and Clean(v) or nil
	end
	local SI = C_SpecializationInfo
	local set = SI and Call(SI.GetActiveSpecGroup)
	e.talentSet = type(set) == "number" and set or nil
	e.talentSets = Call(GetNumSpecGroups)
	local T = C_Traits
	local configID = e.talentSet and SI and Call(SI.GetCombatConfigIDForSpecGroup, e.talentSet)
	if not configID and C_ClassTalents then configID = Call(C_ClassTalents.GetActiveConfigID) end
	local trees
	if configID and T and T.GetConfigInfo and T.GetGroupDisplayInfoByTreeID and T.GetGroupCurrencyInfo then
		local ok = pcall(function()
			local info = Clean(T.GetConfigInfo(configID))
			local treeIDs = type(info) == "table" and Clean(info.treeIDs)
			local treeID = type(treeIDs) == "table" and Clean(treeIDs[1]) or nil
			if not treeID then return end
			local displays = Clean(T.GetGroupDisplayInfoByTreeID(treeID))
			if type(displays) ~= "table" then return end
			local ids = {}
			for _, di in ipairs(displays) do
				local gid = Clean(di.groupID)
				if gid then ids[#ids + 1] = gid end
			end
			local spentBy = {}
			local currency = Clean(T.GetGroupCurrencyInfo(configID, ids))
			for _, gi in ipairs(type(currency) == "table" and currency or {}) do
				local gid = Clean(gi.traitNodeGroupID)
				local infos = Clean(gi.currencyInfos)
				local ci = type(infos) == "table" and Clean(infos[1]) or nil
				local spent = type(ci) == "table" and tonumber(Clean(ci.spent)) or nil
				if gid and spent then spentBy[gid] = spent end
			end
			trees = {}
			for _, di in ipairs(displays) do
				local gid, name = Clean(di.groupID), Clean(di.displayName)
				if gid and type(name) == "string" then
					trees[#trees + 1] = { id = gid, name = name, icon = Clean(di.icon), spent = spentBy[gid] or 0 }
				end
			end
		end)
		if not ok then trees = nil end
	end
	if trees and #trees > 0 then ns.talentTrees = trees end
	local top, best, tie = nil, 0, false
	for _, tr in ipairs(ns.talentTrees or {}) do
		if tr.spent > best then top, best, tie = tr, tr.spent, false
		elseif tr.spent == best and best > 0 then tie = true end
	end
	e.mainTree = (top and not tie) and top.name or nil
	if ns.UI and ns.UI.RefreshTalentChoices then ns.UI:RefreshTalentChoices() end
end

-- The last state the display was drawn for. Compared with the state after each update, so a change
-- written by something else in between (talents are read on their own events) still redraws.
local lastEnvSig
function ns.UpdateEnv()
	local e = ns.env
	e.combat = ns.combatFlag and true or false
	e.group = Bool(IsInRaid) and "raid" or (Bool(IsInGroup) and "party" or "solo")
	local size = 1
	if GetNumGroupMembers then
		local ok, n = pcall(GetNumGroupMembers)
		n = ok and Clean(n) or nil
		if type(n) == "number" and n > 1 then size = n end
	end
	e.groupSize = size
	local place = "world"
	if IsInInstance then
		local ok, inside, kind = pcall(IsInInstance)
		inside, kind = ok and Clean(inside), ok and Clean(kind)
		if inside and kind then
			place = (kind == "pvp" and "bg") or (kind == "arena" and "arena") or (kind == "raid" and "raid")
				or ((kind == "party" or kind == "scenario") and "dungeon") or "world"
		end
	end
	e.place = place
	e.resting = Bool(IsResting)
	e.mounted = Bool(IsMounted)
	e.target = Bool(UnitExists, "target")
	e.alive = not Bool(UnitIsDeadOrGhost, "player")
	if not e.class and UnitClass then
		local ok, _, token = pcall(UnitClass, "player")
		if ok then e.class = Clean(token) end
	end
	local sig = EnvSignature(e)
	if sig ~= lastEnvSig then
		lastEnvSig = sig
		if ns.Display and ns.Display.Refresh then ns.Display:Refresh() end
	end
end

function ns.CondPass(c)
	if not c then return true end
	if c.never then return false end
	local e = ns.env
	for _, tog in ipairs(ns.TOGGLES) do
		local want = c[tog[1]]
		if want == "yes" and not e[tog[1]] then return false end
		if want == "no" and e[tog[1]] then return false end
	end
	if c.minGroup and c.minGroup > 1 and (e.groupSize or 1) < c.minGroup then return false end
	if c.place and next(c.place) and not c.place[e.place] then return false end
	if c.class and next(c.class) and not (e.class and c.class[e.class]) then return false end
	-- Talents: unknown (not read yet, nothing spent, a tie) lets everything through.
	if ns.TalentConditionFails(c) then return false end
	return true
end

-- Short human summary, for the layout list and tooltips.
function ns.CondSummary(c)
	if not c then return "" end
	if c.never then return "never" end
	local parts = {}
	for _, tog in ipairs(ns.TOGGLES) do
		local want = c[tog[1]]
		if want == "yes" then parts[#parts + 1] = strlower(tog[3]) elseif want == "no" then parts[#parts + 1] = strlower(tog[4]) end
	end
	if c.minGroup and c.minGroup > 1 then parts[#parts + 1] = c.minGroup .. "+ players" end
	for _, spec in ipairs({ { "place", ns.PLACES } }) do
		local set = c[spec[1]]
		if set and next(set) then
			local names = {}
			for _, item in ipairs(spec[2]) do if set[item[1]] then names[#names + 1] = strlower(item[2]) end end
			parts[#parts + 1] = table.concat(names, "/")
		end
	end
	if c.class and next(c.class) then
		local names = {}
		for _, class in ipairs(ns.CLASSES) do
			if c.class[class] then names[#names + 1] = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class end
		end
		parts[#parts + 1] = table.concat(names, "/")
	end
	if c.tree then parts[#parts + 1] = "main tree " .. c.tree end
	if c.talentSet then parts[#parts + 1] = "talent set " .. c.talentSet end
	return table.concat(parts, ", ")
end

-- ------------------------------------------------------------------
-- Aura reader: your own auras and your target's, kept in separate tables with their own indexes.
-- ------------------------------------------------------------------
-- Only your own buffs: see the note on the tracker, nothing on this client can follow an aura on
-- another unit through a fight.
ns.UNITS = { "player" }
ns.targetAuras = {}
local byName, byId = { player = {}, target = {} }, { player = {}, target = {} }

local function AuraTable(unit)
	return unit == "target" and ns.targetAuras or ns.auras
end
ns.AuraTable = AuraTable

local function Reindex()
	for _, unit in ipairs(ns.UNITS) do
		local names, ids = {}, {}
		for _, e in pairs(AuraTable(unit)) do
			if e.name then
				local l = strlower(e.name)
				names[l] = names[l] or {}
				table.insert(names[l], e)
			end
			if e.id then
				ids[e.id] = ids[e.id] or {}
				table.insert(ids[e.id], e)
			end
		end
		byName[unit], byId[unit] = names, ids
	end
end

-- The live aura a tracker is about, or nil. With several matches the longest-lasting one wins.
-- A spell's cooldown, as an entry of the same shape an aura makes, so everything that draws a
-- tracker works on it unchanged. A cooldown has so far read the same in a fight as out of one, but
-- the client's own documentation says a spell's start and length can be hidden while cooldowns are
-- restricted (a boss, an arena), so nothing here is tested before it is known to be plain. Whether
-- the spell is on cooldown at all, and whether its cooldown is waiting to start, are never hidden.
-- The global cooldown is not a cooldown worth showing, so anything 1.5 seconds long or shorter is
-- treated as ready.
-- Every use starts a short cooldown that everything shares, and the client reports that one in
-- place of the real cooldown for as long as it runs. Read plainly, a spell or item on a five minute
-- cooldown therefore says "ready" for a second and a half every time anything at all is used. What
-- was last seen is kept, so while the shared one is being reported the real cooldown is answered
-- from memory. A cooldown that is genuinely over reports nothing at all rather than a short
-- something, which is how a reset is told apart from the shared one.
local GCD_MAX = 1.5
local cdSeen = {}
-- When each tracked spell was last seen ready, and when you last cast it, by lower-case name. A
-- cast since it was last ready is what tells its own cooldown from the global one when the numbers
-- are hidden.
local cdIdle = {}
ns.lastCast = {}
-- When the global cooldown last started from one of your casts: at the cast for an instant, at the
-- start of the cast for one with a cast time. Something on cooldown outside that window is a real
-- cooldown, whatever started it.
ns.lastGcdAt = nil
local GCD_WINDOW = GCD_MAX + 0.2

-- The length a spell's cooldown had when it was last read plainly, per character (talents change it).
local function RememberedLength(lname)
	local mem = ns.profile and ns.profile.cdLen
	return mem and tonumber(mem[lname]) or nil
end

-- The real cooldown behind a reading: its length and when it ends, or nothing if there is none.
-- "held" is a cooldown that has been used but has not started yet: Nature's Swiftness, Stealth and
-- the like start theirs only when the effect ends, and until then the game says it is not enabled.
local function RealCooldown(key, start, duration, enabled, allowHeld)
	local now = GetTime()
	if allowHeld and (enabled == false or enabled == 0) and start and start > 0 then
		cdSeen[key] = nil
		return nil, nil, true
	end
	if not start or not duration or start <= 0 or duration <= 0 or enabled == false or enabled == 0 then
		cdSeen[key] = nil
		return nil
	end
	if duration > GCD_MAX then
		cdSeen[key] = { expires = start + duration, duration = duration }
		return duration, start + duration
	end
	local seen = cdSeen[key]
	if seen and now < seen.expires then return seen.duration, seen.expires end
	cdSeen[key] = nil
	return nil
end
ns.RealCooldown = RealCooldown

-- What is left on an item's cooldown. Items are read by id, so a trinket that is swapped out of a
-- bag still answers, and the answer is the same in a fight as out of one.
function ns.ItemCooldownRead(id)
	local start, duration, enabled
	if C_Item and C_Item.GetItemCooldown then
		local ok, a, b, c = pcall(C_Item.GetItemCooldown, id)
		if ok then start, duration, enabled = Clean(a), Clean(b), Clean(c) end
	end
	if start == nil and C_Container and C_Container.GetItemCooldown then
		local ok, a, b, c = pcall(C_Container.GetItemCooldown, id)
		if ok then start, duration, enabled = Clean(a), Clean(b), Clean(c) end
	end
	if start == nil and GetItemCooldown then
		local ok, a, b, c = pcall(GetItemCooldown, id)
		if ok then start, duration, enabled = Clean(a), Clean(b), Clean(c) end
	end
	return start, duration, enabled
end

-- The raw reading. The start and length come back as they are, possibly hidden, and are not looked
-- at here; whether it is on cooldown and whether it is enabled are never hidden, so they are cleaned.
local function ReadSpellCooldown(key)
	local info = Clean(C_Spell.GetSpellCooldown(key))
	if type(info) ~= "table" then return false end
	return true, info.startTime, info.duration, Clean(info.isEnabled), Clean(info.isActive)
end

local function IsHidden(v) return issecretvalue ~= nil and issecretvalue(v) == true end

-- The name a spell's cooldown memory and last cast are kept under.
local function CooldownName(t, key)
	local name = t.name or (ns.SpellName and ns.SpellName(t.id or key))
	return name and strlower(name) or ("id:" .. tostring(key))
end

-- A cooldown whose start and length the game is hiding. What is still known: whether it is on
-- cooldown at all, whether it is waiting to start, what was last read plainly, and whether you have
-- cast it since it was last ready. That is enough to tell its own cooldown from the global one, and
-- a cooldown you started is carried on from the length it had last time, marked with a ~.
local function HiddenCooldown(t, key, icon, enabled, active)
	local now = GetTime()
	local base = { name = t.name, id = t.id, icon = icon, kind = "cooldown", mine = true, duration = 0, expires = 0 }
	ns.stats.secretCd = (ns.stats.secretCd or 0) + 1
	ns.stats.secretCdLast = t.name or tostring(key)
	local lname = CooldownName(t, key)
	if enabled == false then
		-- Used, and its cooldown starts when the effect ends: a carried countdown counts from then.
		ns.lastCast[lname] = now
		base.held = true
		return base
	end
	if active == false then
		cdSeen["s:" .. tostring(key)] = nil
		cdIdle[lname] = now
		base.ready = true
		return base
	end
	if active ~= true then return nil end
	local cast = ns.lastCast[lname]
	local castSinceReady = cast ~= nil and cast >= (cdIdle[lname] or 0)
	-- The last plain reading carries on, unless the spell was cast again after that cooldown began
	-- (it was reset and used again).
	local seen = cdSeen["s:" .. tostring(key)]
	if seen and now < seen.expires and not (cast and cast > seen.expires - seen.duration + GCD_MAX) then
		base.duration, base.expires, base.stale = seen.duration, seen.expires, true
		return base
	end
	local len = RememberedLength(lname)
	if castSinceReady and len and cast + len > now then
		base.duration, base.expires, base.stale = len, cast + len, true
		return base
	end
	-- Inside the global cooldown: the spell is ready unless its own cooldown may still be running,
	-- which is so when it was cast since it was last ready and its length is not known.
	local inGcd = ns.lastGcdAt ~= nil and now - ns.lastGcdAt <= GCD_WINDOW
	if inGcd and (not castSinceReady or (len and cast + len <= now)) then
		if castSinceReady then cdIdle[lname] = cast + len end
		base.ready = true
		return base
	end
	-- On cooldown outside the global one, or cast with no length known: a real cooldown, how long
	-- the game is not saying.
	base.secret = true
	return base
end

-- What is remembered about a cooldown tracker, for /auraledger debug cdread.
function ns.CooldownMemory(t)
	local key = t.id or t.name
	if not key then return nil end
	local lname = CooldownName(t, key)
	local now = GetTime()
	local seen = cdSeen["s:" .. tostring(key)]
	local function Ago(v) return v and ("%.1fs ago"):format(now - v) or "never" end
	return ("last read on cooldown %s, ready %s, cast %s, length %s"):format(
		seen and ("until %.1fs from now"):format(seen.expires - now) or "none", Ago(cdIdle[lname]), Ago(ns.lastCast[lname]),
		tostring(RememberedLength(lname)))
end

function ns.CooldownFor(t)
	if t.item then return ns.ItemCooldownFor(t) end
	local key = t.id or t.name
	if not key then return nil end
	local found, start, duration, enabled, active = false
	if C_Spell and C_Spell.GetSpellCooldown then
		local ok, f, s, dd, e, a = pcall(ReadSpellCooldown, key)
		if ok and f then found, start, duration, enabled, active = true, s, dd, e, a end
	end
	if not found and GetSpellCooldown then
		local ok, a, b, cc = pcall(GetSpellCooldown, key)
		if ok then start, duration, enabled = a, b, Clean(cc) end
	end
	local icon = t.icon
	if not icon then local _, i = ns.SpellInfo(key) icon = i end
	if IsHidden(start) or IsHidden(duration) then return HiddenCooldown(t, key, icon, enabled, active) end
	start, duration = tonumber(start), tonumber(duration)
	if not start or not duration then return nil end
	local dur, expires, held = RealCooldown("s:" .. tostring(key), start, duration, enabled, true)
	if held then
		ns.lastCast[CooldownName(t, key)] = GetTime()
		return { name = t.name, id = t.id, icon = icon, kind = "cooldown", held = true, duration = 0, expires = 0, mine = true }
	end
	if not dur then
		-- Ready. A short reading just after a cast may be the global cooldown standing in for the
		-- spell's own, so that is not taken as the moment it was last ready.
		local lname = CooldownName(t, key)
		if start == 0 or duration == 0 or GetTime() - (ns.lastCast[lname] or -100) > GCD_WINDOW then cdIdle[lname] = GetTime() end
		-- Ready: an entry with nothing left on it, so "show when ready" has something to show.
		return { name = t.name, id = t.id, icon = icon, kind = "cooldown", ready = true, duration = 0, expires = 0, mine = true }
	end
	-- Remembered by name for a fight where the numbers are hidden: its length the last time it was read.
	if dur > GCD_MAX and ns.profile then
		ns.profile.cdLen = ns.profile.cdLen or {}
		ns.profile.cdLen[CooldownName(t, key)] = dur
	end
	return { name = t.name, id = t.id, icon = icon, kind = "cooldown", duration = dur, expires = expires, mine = true }
end

-- An item's cooldown, as an entry of the shape everything that draws a tracker already understands.
function ns.ItemCooldownFor(t)
	local id = t.item
	local start, duration, enabled = ns.ItemCooldownRead(id)
	start, duration = tonumber(start), tonumber(duration)
	if not start or not duration then return nil end
	local icon = t.icon or (ns.ItemIcon and ns.ItemIcon(id))
	local name = t.name or (ns.ItemName and ns.ItemName(id))
	local dur, expires = RealCooldown("i:" .. tostring(id), start, duration, enabled)
	if not dur then
		return { name = name, item = id, icon = icon, kind = "cooldown", ready = true, duration = 0, expires = 0, mine = true }
	end
	return { name = name, item = id, icon = icon, kind = "cooldown", duration = dur, expires = expires, mine = true }
end

-- ------------------------------------------------------------------
-- Weapons: a temporary enchant (oil, stone, poison, imbue) is not an aura, so the aura reader and
-- the game's slots know nothing of it; the game's enchant list is read instead, plainly, in a fight
-- too. What was last read is kept, so a reading that comes back hidden carries on from it.
-- ------------------------------------------------------------------
local WEAPON_INV_SLOT = { [0] = 16, [1] = 17, [2] = 18 }
ns.WEAPON_INV_SLOT = WEAPON_INV_SLOT
local enchantSeen = {}

local function WeaponIcon(slot)
	if not GetInventoryItemTexture then return nil end
	local ok, tex = pcall(GetInventoryItemTexture, "player", WEAPON_INV_SLOT[slot] or 16)
	return ok and Clean(tex) or nil
end
ns.WeaponIcon = WeaponIcon

function ns.EnchantFor(t)
	local slot = tonumber(t.enchant)
	if not slot then return nil end
	local now = GetTime()
	local seen = enchantSeen[slot]
	local function Carried()
		if seen and seen.expires > now then
			return { name = t.name, icon = WeaponIcon(slot) or t.icon, kind = "buff", count = seen.count or 0,
				duration = seen.duration, expires = seen.expires, mine = true, stale = true }
		end
	end
	if not (C_Item and C_Item.GetWeaponEnchantInfo) then return nil end
	local ok, list = pcall(C_Item.GetWeaponEnchantInfo, slot)
	list = ok and Clean(list) or nil
	if type(list) ~= "table" then return Carried() end
	local readable = true
	for _, raw in pairs(list) do
		local e = Clean(raw)
		if type(e) == "table" then
			local has = Clean(e.hasEnchant)
			if has == nil then readable = false end
			if has == true then
				local left, charges, id = Clean(e.timeLeft), Clean(e.charges), Clean(e.enchantID)
				if type(left) ~= "number" then return Carried() end
				if t.enchantID == nil or t.enchantID == id then
					local secs = left / 1000
					-- The length is the time left when this enchant was first seen, and a new one
					-- (another enchant, or the same one put on again) starts it over.
					if not seen or seen.id ~= id or secs > (seen.left or 0) + 1 then
						seen = { id = id, duration = secs }
						enchantSeen[slot] = seen
					end
					seen.left, seen.expires, seen.count = secs, now + secs, type(charges) == "number" and charges or 0
					return { name = t.name, icon = WeaponIcon(slot) or t.icon, kind = "buff", count = seen.count,
						duration = seen.duration, expires = seen.expires, mine = true }
				end
			end
		end
	end
	if not readable then return Carried() end
	enchantSeen[slot] = nil
	return nil
end

-- A swing: the game says when one starts and how long it takes; nothing else is known until the next.
ns.swing = {}
function ns.SwingFor(t)
	local kind = tonumber(t.swing)
	local s = kind and ns.swing[kind]
	if not s or GetTime() >= s.expires then return nil end
	return { name = t.name, icon = WeaponIcon(kind) or t.icon, kind = "buff", count = 0,
		duration = s.duration, expires = s.expires, mine = true }
end

-- The swing event is only asked for once something wants it.
-- Also notes whether anything follows a weapon enchant, so the inventory events redraw only then.
function ns.WantSwingEvents()
	if not ns.profile or not ns.SafeRegister then return end
	local swing, enchant = false, false
	for _, g in ipairs(ns.profile.groups) do
		for _, t in ipairs(g.trackers) do
			if t.swing ~= nil then swing = true end
			if t.enchant ~= nil then enchant = true end
		end
	end
	ns.hasEnchantTrackers = enchant
	if swing then ns.SafeRegister("PLAYER_SWING") elseif ns.SafeUnregister then ns.SafeUnregister("PLAYER_SWING") end
end

function ns.Find(t)
	-- A weapon's enchant, or its swing: read from the weapon, not the aura table.
	if t.enchant ~= nil then return ns.EnchantFor(t) end
	if t.swing ~= nil then return ns.SwingFor(t) end
	-- An item is only ever its cooldown: there is no aura table to look it up in.
	if t.item then return ns.ItemCooldownFor(t) end
	-- A cooldown tracker asks the spell, not the aura table.
	if t.cd then return ns.CooldownFor(t) end
	local unit = t.unit or "player"
	local list
	if t.matchId and t.id then
		list = byId[unit][t.id]
	elseif t.name then
		list = byName[unit][strlower(t.name)]
	elseif t.id then
		list = byId[unit][t.id]
	end
	if not list then return nil end
	local best
	for _, e in ipairs(list) do
		-- "Cast by me" is unknown (nil) for an aura recognized from a frame icon; that passes.
		if (t.kind == "any" or not t.kind or e.kind == t.kind) and (not t.mine or e.mine ~= false) then
			if not best then
				best = e
			elseif best.expires > 0 and (e.expires == 0 or e.expires > best.expires) then
				best = e
			end
		end
	end
	return best
end

local function MakeEntry(a, kind, key, unit)
	local name = Clean(a.name)
	if not name then return nil end
	local source = Clean(a.sourceUnit)
	return {
		key = key,
		name = name,
		id = Clean(a.spellId),
		icon = Clean(a.icon),
		count = Clean(a.applications) or 0,
		duration = Clean(a.duration) or 0,
		expires = Clean(a.expirationTime) or 0,
		inst = Clean(a.auraInstanceID),
		kind = kind,
		unit = unit,
		mine = (source == "player" or source == "pet") or (Clean(a.isFromPlayerOrPlayerPet) == true),
		dispel = Clean(a.dispelName),
	}
end

-- Reads one filter on one unit into "out". Returns how many auras could not be read. A secret
-- index is never asked for: on this client the call fails with "cannot be accessed when secret
-- while tainted", so nothing is learned by trying.
local function ReadFilter(unit, filter, kind, out)
	local unreadable, secretRun = 0, 0
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		for i = 1, MAX_INDEX do
			if IndexSecret(unit, i, filter) then
				unreadable = unreadable + 1
				secretRun = secretRun + 1
				if secretRun > 40 then break end
			else
				local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
				if not ok then
					unreadable = unreadable + 1
					secretRun = secretRun + 1
					if secretRun > 4 then break end
				elseif not a then
					break
				else
					secretRun = 0
					local inst = Clean(a.auraInstanceID)
					local e = MakeEntry(a, kind, inst or (kind .. ":" .. i), unit)
					if e then out[e.key] = e else unreadable = unreadable + 1 end
				end
			end
		end
	elseif UnitAura then
		for i = 1, MAX_INDEX do
			local ok, name, icon, count, dispel, duration, expires, source, _, _, spellId = pcall(UnitAura, unit, i, filter)
			if not ok then unreadable = unreadable + 1 break end
			if not name then break end
			name = Clean(name)
			if name then
				local key = kind .. ":" .. tostring(Clean(spellId) or name)
				out[key] = { key = key, name = name, id = Clean(spellId), icon = Clean(icon), count = Clean(count) or 0,
					duration = Clean(duration) or 0, expires = Clean(expires) or 0, kind = kind, unit = unit,
					mine = Clean(source) == "player" or Clean(source) == "pet", dispel = Clean(dispel) }
			else
				unreadable = unreadable + 1
			end
		end
	end
	return unreadable
end

-- ------------------------------------------------------------------
-- Asking by spell. Kept for /auraledger probe only: on this client a lookup by spell name or id
-- answers nil for everything while auras are secret, so it cannot tell present from absent.
-- ------------------------------------------------------------------
local probeStats = { calls = 0, present = 0, absent = 0, unknown = 0, errors = 0 }
ns.probeStats = probeStats

local function SameAura(t, e)
	if t.id and e.id == t.id then return true end
	return t.name and e.name and strlower(e.name) == strlower(t.name)
end

-- Returns "present", data, kind | "absent" | "unknown"
local function ProbeOne(unit, t)
	local C = C_UnitAuras
	if not C then return "unknown" end
	local filters = t.kind == "buff" and { "HELPFUL" } or t.kind == "debuff" and { "HARMFUL" } or { "HELPFUL", "HARMFUL" }
	local sawAbsent = false
	for _, filter in ipairs(filters) do
		local kind = filter == "HELPFUL" and "buff" or "debuff"
		local ok, a
		if t.name and not t.matchId and C.GetAuraDataBySpellName then
			ok, a = pcall(C.GetAuraDataBySpellName, unit, t.name, filter)
		elseif unit == "player" and t.id and C.GetPlayerAuraBySpellID then
			ok, a = pcall(C.GetPlayerAuraBySpellID, t.id)
			if ok and type(a) == "table" and not (issecretvalue and issecretvalue(a)) then
				local harmful = Clean(a.isHarmful)
				if harmful ~= nil and harmful ~= (filter == "HARMFUL") then a = nil end
			end
		elseif t.name and C.GetAuraDataBySpellName then
			ok, a = pcall(C.GetAuraDataBySpellName, unit, t.name, filter)
		else
			return "unknown"
		end
		probeStats.calls = probeStats.calls + 1
		if not ok then probeStats.errors = probeStats.errors + 1 return "unknown" end
		if issecretvalue and issecretvalue(a) then return "unknown" end
		if a == nil then
			sawAbsent = true
		elseif type(a) == "table" then
			return "present", a, kind
		end
	end
	if sawAbsent then return "absent" end
	return "unknown"
end
ns.ProbeOne = ProbeOne

local firstScan = true
-- How long after entering the world the addon keeps asking for the auras you already have. The
-- client can be a few seconds behind with them, and can still be refusing reads, and neither of
-- those arrives as an event. Scans in this stretch are quiet, so a buff you had before the reload
-- does not count as freshly applied in the ledger.
local SETTLE = 12
function ns.Settle()
	ns.settleUntil = GetTime() + SETTLE
	ns.dirty = true
end

-- One unit's scan: read what can be read, carry the rest forward. Returns the new table and whether
-- anything was unreadable.
-- UNIT_AURA payload: removals and refreshes arrive by instance id even while contents are secret.
-- The lists inside the payload can themselves be secret in combat: they look like tables to
-- type() but ipairs refuses them. Returns a plain array or nil.
-- A table the client flags as secret is left alone before anything is asked of it: whatever it
-- holds would only come back secret. The second return is how many ids were secret and dropped.
local function PlainList(v)
	v = Clean(v)
	if type(v) ~= "table" then return nil end
	if issecrettable then
		local okT, secretTable = pcall(issecrettable, v)
		if okT and secretTable == true then return nil end
	end
	local dropped = 0
	local ok, out = pcall(function()
		local list = {}
		for _, id in ipairs(v) do
			local plain = Clean(id)
			if plain == nil then dropped = dropped + 1 else list[#list + 1] = plain end
		end
		return list
	end)
	if not ok then return nil end
	return out, dropped
end

local function ScanUnit(unit, old, quiet)
	local now = GetTime()
	local fresh, unreadable = {}, 0
	local stats = ns.stats
	if AurasSecret() and not (C_Secrets and C_Secrets.ShouldUnitAuraIndexBeSecret) then
		unreadable = 1
		stats.blocked = stats.blocked + 1
	else
		unreadable = ReadFilter(unit, "HELPFUL", "buff", fresh) + ReadFilter(unit, "HARMFUL", "debuff", fresh)
		if unreadable > 0 then stats.partial = stats.partial + 1 end
	end
	local historyChanged = false
	for key, e in pairs(fresh) do
		if not old[key] then
			if ns.RecordAura(e, quiet) then historyChanged = true end
		end
	end
	if unreadable > 0 then
		-- Carry forward what we knew, minus anything that has run out or has been read properly now.
		local freshIds = {}
		for _, e in pairs(fresh) do if e.id then freshIds[e.id] = true end end
		for key, e in pairs(old) do
			if not fresh[key] then
				local expired = e.expires > 0 and now > e.expires
				local superseded = e.synth and e.id and freshIds[e.id]
				if not expired and not superseded then
					e.stale = true
					fresh[key] = e
				end
			end
		end
	end
	return fresh, unreadable > 0, historyChanged
end

function ns.Scan()
	ns.dirty = false
	ns.lastScan = GetTime()
	ns.stats.scans = ns.stats.scans + 1
	local fresh, restricted, changed = ScanUnit("player", ns.auras, firstScan or ns.settleUntil ~= nil)
	ns.auras = fresh
	local historyChanged = changed
	firstScan = false
	ns.restricted = restricted
	Reindex()
	if ns.Display and ns.Display.Refresh then ns.Display:Refresh() end
	if historyChanged and ns.UI and ns.UI.RefreshHistory then ns.UI:RefreshHistory() end
end


-- Shape of the UNIT_AURA payloads seen while restricted, for the debug report.
local payloadStats = { events = 0, plainRemoved = 0, secretRemoved = 0, plainUpdated = 0, secretUpdated = 0, plainAdded = 0, secretAdded = 0, full = 0, secretIds = 0, sample = nil }
ns.payloadStats = payloadStats

local function Describe(v)
	if issecretvalue and issecretvalue(v) then return "secret" end
	if v == nil then return "nil" end
	if type(v) == "table" then
		local ok, n = pcall(function() return #v end)
		return "table" .. (ok and ("[" .. tostring(n) .. "]") or "[?]")
	end
	return type(v) .. ":" .. tostring(v)
end

local function NotePayload(unit, info)
	if not ns.restricted or unit ~= "player" then return end
	payloadStats.events = payloadStats.events + 1
	local function tally(v, plainKey, secretKey)
		if Clean(v) == nil and not (issecretvalue and issecretvalue(v)) then return end
		local list, dropped = PlainList(v)
		if list then payloadStats[plainKey] = payloadStats[plainKey] + 1 else payloadStats[secretKey] = payloadStats[secretKey] + 1 end
		if dropped and dropped > 0 then payloadStats.secretIds = payloadStats.secretIds + dropped end
	end
	tally(info.removedAuraInstanceIDs, "plainRemoved", "secretRemoved")
	tally(info.updatedAuraInstanceIDs, "plainUpdated", "secretUpdated")
	tally(info.addedAuras, "plainAdded", "secretAdded")
	if Clean(info.isFullUpdate) then payloadStats.full = payloadStats.full + 1 end
	local removed = info.removedAuraInstanceIDs
	if not payloadStats.sample or (issecretvalue and issecretvalue(removed)) or Clean(removed) ~= nil then
		local parts = {}
		local ok = pcall(function()
			for k, v in pairs(info) do parts[#parts + 1] = tostring(k) .. "=" .. Describe(v) end
		end)
		if not ok then parts = { "(payload table refuses pairs)" } end
		local added = Clean(info.addedAuras)
		if type(added) == "table" then
			local okA = pcall(function()
				local first = added[1]
				if type(first) == "table" then
					parts[#parts + 1] = "first added: name " .. Describe(first.name) .. ", spellId " .. Describe(first.spellId) .. ", icon " .. Describe(first.icon) .. ", instance " .. Describe(first.auraInstanceID)
				end
			end)
			if not okA then parts[#parts + 1] = "first added: refuses" end
		end
		payloadStats.sample = table.concat(parts, ", ")
	end
end

local function HandleAuraInfo(unit, info)
	if type(info) ~= "table" or Clean(info) == nil then return end
	NotePayload(unit, info)
	local auras = AuraTable(unit)
	local now = GetTime()
	local removed = PlainList(info.removedAuraInstanceIDs)
	if removed then
		for _, id in ipairs(removed) do
			if id and auras[id] then
				auras[id] = nil
				ns.stats.removedById = ns.stats.removedById + 1
			end
		end
	end
	local updated = PlainList(info.updatedAuraInstanceIDs)
	if updated and ns.restricted then
		for _, id in ipairs(updated) do
			local e = id and auras[id]
			if e then
				local data
				if C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID and not InstanceSecret(unit, id) then
					local ok, a = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, id)
					if ok and type(a) == "table" then data = MakeEntry(a, e.kind, id, unit) end
				end
				if data then
					auras[id] = data
				elseif e.duration > 0 then
					-- Can't see the new timer: assume a full refresh and say so.
					e.expires = now + e.duration
					e.estimated = true
					ns.stats.estimated = ns.stats.estimated + 1
				end
			end
		end
	end
end

-- ------------------------------------------------------------------
-- Your own casts are not secret. While auras are, a successful cast of a spell the ledger knows as
-- an aura creates or refreshes an estimated aura: a buff on you, a debuff on your target, with the
-- ledger's duration. That is how a buff reapplied mid-fight clears a "missing" tracker.
-- ------------------------------------------------------------------
local function SpellName(spellId)
	local name
	if C_Spell and C_Spell.GetSpellName then
		local ok, v = pcall(C_Spell.GetSpellName, spellId)
		if ok then name = Clean(v) end
	end
	if not name and C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
		if ok and type(info) == "table" then name = Clean(info.name) end
	end
	if not name and GetSpellInfo then
		local ok, v = pcall(GetSpellInfo, spellId)
		if ok then name = Clean(v) end
	end
	return name
end

local function HandleCast(unit, spellId, castGUID)
	if unit ~= "player" and unit ~= "pet" then return end
	spellId = Clean(spellId)
	if type(spellId) ~= "number" then return end
	ns.stats.casts = ns.stats.casts + 1
	if unit == "player" then
		-- A spell with a cast time started the global cooldown when the cast began.
		local guid = Clean(castGUID)
		if guid == nil or guid ~= ns.lastCastStart then ns.lastGcdAt = GetTime() end
		ns.lastCastStart = nil
	end
	do
		local cname = SpellName(spellId)
		if cname then ns.lastCast[strlower(cname)] = GetTime() end
	end
	if not (ns.restricted or AurasSecret()) then return end -- the real aura event is on its way
	local name = SpellName(spellId)
	if not name then return end
	local lname = strlower(name)
	local now = GetTime()
	local used = false
	for _, kind in ipairs({ "buff" }) do
		local h = ns.db.history[kind .. ":" .. lname]
		local unitTo = "player"
		if h then
			local auras = AuraTable(unitTo)
			local existing
			for _, e in pairs(auras) do
				if e.kind == kind and e.name and strlower(e.name) == lname then existing = e break end
			end
			local duration = h.duration or 0
			if existing then
				if duration > 0 then existing.duration, existing.expires = duration, now + duration end
				existing.estimated, existing.stale, existing.probed = true, true, true
				existing.synth, existing.inst, existing.createdAt = true, nil, now -- rebinds to the recast's instance
			else
				local key = "c:" .. unitTo .. ":" .. lname
				auras[key] = { key = key, name = h.name or name, id = spellId, icon = h.icon, count = 0, duration = duration,
					expires = duration > 0 and (now + duration) or 0, kind = kind, unit = unitTo, mine = true,
					synth = true, estimated = true, stale = true, probed = true, createdAt = now }
			end
			used = true
		end
	end
	if used then
		ns.stats.castsUsed = ns.stats.castsUsed + 1
		Reindex()
		ns.dirty = true
	end
end
ns.HandleCast = HandleCast
ns.SpellName = SpellName


-- Combat log: only consulted while auras are unreadable, to catch applications and removals on
-- you or on your target.
local AURA_EVENTS = {
	SPELL_AURA_APPLIED = "apply", SPELL_AURA_REFRESH = "apply", SPELL_AURA_APPLIED_DOSE = "dose",
	SPELL_AURA_REMOVED = "remove", SPELL_AURA_REMOVED_DOSE = "dose",
}

local function HandleCombatLog()
	if not CombatLogGetCurrentEventInfo then return end
	local ok, _, sub, _, srcGUID, _, _, _, destGUID, _, _, _, spellId, spellName, _, auraType, amount = pcall(CombatLogGetCurrentEventInfo)
	if not ok then return end
	sub = Clean(sub)
	local what = sub and AURA_EVENTS[sub]
	if not what then return end
	destGUID = Clean(destGUID)
	local unit
	if destGUID == ns.playerGUID then unit = "player"
	elseif ns.targetGUID and destGUID == ns.targetGUID then unit = "target"
	else return end
	ns.stats.cleu = ns.stats.cleu + 1
	if not (ns.restricted or AurasSecret()) then return end -- a normal scan is the better source

	spellId, spellName = Clean(spellId), Clean(spellName)
	if not spellName then return end
	if spellId == 0 then spellId = nil end
	local kind = Clean(auraType) == "DEBUFF" and "debuff" or "buff"
	local now = GetTime()
	local auras = AuraTable(unit)
	ns.stats.cleuUsed = ns.stats.cleuUsed + 1

	local matches = {}
	for key, e in pairs(auras) do
		if e.kind == kind and ((spellId and e.id == spellId) or (e.name == spellName)) then matches[#matches + 1] = key end
	end

	if what == "remove" then
		for _, key in ipairs(matches) do auras[key] = nil end
	elseif what == "dose" then
		for _, key in ipairs(matches) do auras[key].count = Clean(amount) or auras[key].count end
	else
		local h = ns.db.history[HistoryKey(kind, spellName)]
		local duration = h and h.duration or 0
		if #matches > 0 then
			for _, key in ipairs(matches) do
				local e = auras[key]
				local d = e.duration > 0 and e.duration or duration
				if d > 0 then e.duration, e.expires = d, now + d end
				e.estimated = true
			end
		else
			local _, icon = ns.SpellInfo(spellId or spellName)
			local key = "c:" .. kind .. ":" .. tostring(spellId or spellName)
			local e = {
				key = key, name = spellName, id = spellId, icon = icon or (h and h.icon), count = 0,
				duration = duration, expires = duration > 0 and (now + duration) or 0, kind = kind, unit = unit,
				mine = Clean(srcGUID) == ns.playerGUID, synth = true, estimated = true, stale = true,
			}
			auras[key] = e
			if ns.RecordAura(e, false) and ns.UI and ns.UI.RefreshHistory then ns.UI:RefreshHistory() end
		end
	end
	Reindex()
	if ns.Display and ns.Display.Refresh then ns.Display:Refresh() end
end

-- ------------------------------------------------------------------
-- What a group drawn by the game can follow all through a fight: a buff on you, by its spell id.
-- The book marks the rows it can, so the choice between the game and the addon drawing a tracker is
-- made with that in view. It can never follow a buff on an enemy (the game refuses spell filters
-- there), a debuff on you, or anything with no spell id known on this client.
-- ------------------------------------------------------------------
function ns.CombatTrackableWhy(h)
	if not h then return "noid" end
	if h.item or h.cd or h.enchant ~= nil or h.swing ~= nil then return "addon" end
	if h.kind == "debuff" then return "debuff" end
	if h.id or (h.ids and next(h.ids)) then return "yes" end
	if h.name and ns.RankIds(h.name) then return "yes" end
	if h.clientName then return "renamed" end
	return "noid"
end

function ns.CombatTrackable(h)
	return ns.CombatTrackableWhy(h) == "yes"
end

-- ------------------------------------------------------------------
-- Blizzard's Cooldown Manager, handed back. An old version wrote its own layout into the manager
-- to use it as a drawing engine, and writing it marked the manager with this addon until a
-- reload. Nothing writes it now; this only takes that layout out again for a profile that still
-- has it. The layout is a CBOR table, deflated and base64 encoded; the fields below are its
-- numbered keys.
-- ------------------------------------------------------------------
ns.CDM = {}
local CDM_ACTIVE_NAMES, CDM_LAYOUTS, CDM_LAYOUT_IDS = 2, 3, 4
local CDM_OVERRIDES = 2

local function CDMTag()
	if CooldownViewerUtil and CooldownViewerUtil.GetCurrentClassAndSpecTag then
		local ok, tag = pcall(CooldownViewerUtil.GetCurrentClassAndSpecTag)
		if ok and tag ~= nil then return tag end
	end
end

function ns.CDM.Available()
	return (C_CooldownViewer and C_CooldownViewer.GetLayoutData and C_CooldownViewer.SetLayoutData
		and C_EncodingUtil and C_EncodingUtil.SerializeCBOR and CooldownViewerSettings
		and Enum and Enum.CooldownViewerCategory and CDMTag() ~= nil) and true or false
end

function ns.CDM.LayoutName()
	return "Aura Ledger (" .. tostring(CDMTag()) .. ")"
end

function ns.CDM.Read()
	if not (C_CooldownViewer and C_CooldownViewer.GetLayoutData and C_EncodingUtil) then return nil end
	local ok, raw = pcall(C_CooldownViewer.GetLayoutData)
	if not ok or type(raw) ~= "string" then return nil end
	local body = raw:match("^%d%|(.*)$")
	if not body or body == "" then return nil end
	local okD, data = pcall(function()
		return C_EncodingUtil.DeserializeCBOR(C_EncodingUtil.DecompressString(C_EncodingUtil.DecodeBase64(body), Enum.CompressionMethod.Deflate))
	end)
	if not okD or type(data) ~= "table" then return nil end
	return data
end

-- Hands the manager back to whatever was in charge before the addon took it over.
function ns.CDM.Restore()
	if not ns.CDM.Available() then return false, "this client does not offer the layout data" end
	local prev = ns.db.cdmPrevious
	if not prev then return false, "nothing was taken over" end
	local data = ns.CDM.Read()
	if not data then return false, "the layout could not be read" end
	data[CDM_ACTIVE_NAMES] = data[CDM_ACTIVE_NAMES] or {}
	data[CDM_ACTIVE_NAMES][prev.tag] = prev.id or nil
	-- Our layout goes with it, so the manager is left exactly as it was found.
	local name = ns.CDM.LayoutName()
	for lid, lname in pairs(data[CDM_LAYOUT_IDS] or {}) do
		if lname == name then
			data[CDM_LAYOUT_IDS][lid] = nil
			if data[CDM_LAYOUTS] and data[CDM_LAYOUTS][prev.tag] then data[CDM_LAYOUTS][prev.tag][lid] = nil end
		end
	end
	local okS, encoded = pcall(function()
		return C_EncodingUtil.EncodeBase64(C_EncodingUtil.CompressString(C_EncodingUtil.SerializeCBOR(data), Enum.CompressionMethod.Deflate))
	end)
	if not okS then return false, "the layout could not be packed" end
	-- Switched off and on again around the write, and left as it was found.
	local was = "1"
	if C_CVar and C_CVar.GetCVar then
		local okG, v = pcall(C_CVar.GetCVar, "cooldownViewerEnabled")
		v = okG and Clean(v) or nil
		if v == "0" or v == "1" then was = v end
	end
	if C_CVar and C_CVar.SetCVar then pcall(C_CVar.SetCVar, "cooldownViewerEnabled", "0") end
	for holder, key in pairs({ dataSerialization = "cachedSerializedData", dataProvider = "displayData", layoutManager = "activeLayoutID" }) do
		local t = CooldownViewerSettings and CooldownViewerSettings[holder]
		if type(t) == "table" then pcall(function() t[key] = nil end) end
	end
	local okW = pcall(C_CooldownViewer.SetLayoutData, "1|" .. encoded)
	if C_Timer and C_Timer.After then
		C_Timer.After(0, function() if C_CVar and C_CVar.SetCVar then pcall(C_CVar.SetCVar, "cooldownViewerEnabled", was) end end)
	end
	ns.db.cdmPrevious, ns.db.cdmLayout = nil, nil
	return okW and true or false, (not okW) and "the game refused the layout" or nil
end

-- ------------------------------------------------------------------
-- Alert sounds: Blizzard sound kit entries, looked up by name first, numeric id as fallback. The
-- fourth field is the sound's file id where known; only a file can be handed to Blizzard for
-- playing in combat (see SyncAuraSounds), so those choices are the ones that work there.
-- Saved trackers store the index, so entries are only ever appended.
-- ------------------------------------------------------------------
ns.SOUND_CHOICES = {
	{ "Mystic chime",   "TUTORIAL_POPUP",         7355 },
	{ "Gem clink",      "PUT_DOWN_GEMS",          1221 },
	{ "Explosion",      "ALARM_CLOCK_WARNING_3",  12889, 567333 },
	{ "Whisper toast",  "UI_BNET_TOAST",          18019 },
	{ "Quest chime",    "IG_QUEST_LIST_COMPLETE", 878 },
	{ "Auction gong",   "AUCTION_WINDOW_OPEN",    5274 },
	{ "Map ping",       "MAP_PING",               3175 },
	{ "Raid warning",   "RAID_WARNING",           8959,  567397 },
	{ "Ready check",    "READY_CHECK",            8960,  567478 },
	{ "Level up",       "LEVELUP",                888,   567431 },
	{ "Alarm clock 1",  "ALARM_CLOCK_WARNING_1",  12867, 567388 },
	{ "Alarm clock 2",  "ALARM_CLOCK_WARNING_2",  12888, 567399 },
	{ "Flag taken",     "PVP_FLAG_TAKEN",         8174,  567275 },
}

-- Plays choice number n (0 or nil = silent). Returns the name and whether the client said it would play.
function ns.PlaySoundChoice(n)
	local c = ns.SOUND_CHOICES[n or 0]
	if not c then return nil, false end
	local id = (SOUNDKIT and SOUNDKIT[c[2]]) or c[3]
	local ok, willPlay = pcall(PlaySound, id, "SFX")
	ns.report["last sound"] = ("%s (kit %s) -> %s"):format(c[1], tostring(id), tostring(ok and willPlay))
	return c[1], ok and willPlay
end

-- ------------------------------------------------------------------
-- Sounds played by Blizzard. C_UnitAuras.AddAuraSound registers a sound file against a spell id
-- and a trigger (added, stacks increased, removed); the client plays it itself, in combat too,
-- where the addon cannot see the aura. Every tracker with an "applied" or "runs out" sound whose
-- choice has a file id is registered for each spell id it can stand for (all ranks the ledger
-- has seen under that name). The display engine then leaves those two sounds to Blizzard.
-- ------------------------------------------------------------------
local auraSoundRegs = {}
ns.blizzardSound = setmetatable({}, { __mode = "k" })
ns.auraSoundStats = { registered = 0, failed = 0, lastError = nil, cleared = 0 }

-- Registrations live in the game, not in Lua: a reload forgets them here but not there. Their ids
-- are kept in the saved variables and removed on the next load before registering afresh.
function ns.ClearStaleAuraSounds()
	local C = C_UnitAuras
	if not (C and C.RemoveAuraSound) or not ns.db then return end
	-- In a fight or a restricted place new ones may be refused, so the old ones keep playing until
	-- they can be replaced.
	if (InCombatLockdown and InCombatLockdown()) or AurasSecret() then ns.staleSoundsPending = true return end
	ns.staleSoundsPending = nil
	local old = ns.db.auraSoundIds
	ns.db.auraSoundIds = {}
	if type(old) ~= "table" then return end
	for _, id in pairs(old) do
		if pcall(C.RemoveAuraSound, id) then ns.auraSoundStats.cleared = ns.auraSoundStats.cleared + 1 end
	end
end

function ns.ClearAllAuraSounds()
	local C = C_UnitAuras
	if not (C and C.RemoveAuraSound) then return 0 end
	local n = 0
	for key, id in pairs(auraSoundRegs) do
		pcall(C.RemoveAuraSound, id)
		auraSoundRegs[key] = nil
		n = n + 1
	end
	ns.auraSoundStats.registered = 0
	if ns.db then ns.db.auraSoundIds = {} end
	return n
end

local function TrackerSpellIds(t)
	local ids = {}
	if t.id and (t.matchId or not t.name) then
		ids[t.id] = true
	elseif t.name then
		for _, kind in ipairs({ "buff", "debuff" }) do
			local h = ns.db.history[kind .. ":" .. strlower(t.name)]
			if h and h.ids then for id in pairs(h.ids) do ids[id] = true end end
		end
		if t.id then ids[t.id] = true end
		local ranks = ns.RankIds(t.name)
		if ranks then for id in pairs(ranks) do ids[id] = true end end
	end
	return ids
end

function ns.SyncAuraSounds()
	local C = C_UnitAuras
	if not (C and C.AddAuraSound and C.RemoveAuraSound) or not ns.profile then return end
	-- Registering with the game is refused in some restricted states, so a change made in a fight
	-- takes effect when it ends; what was registered before keeps playing meanwhile.
	if (InCombatLockdown and InCombatLockdown()) or AurasSecret() then
		ns.soundSyncPending = true
		return
	end
	ns.soundSyncPending = nil
	if ns.staleSoundsPending then ns.ClearStaleAuraSounds() end
	local trig = Enum and Enum.UnitAuraSoundTrigger or {}
	local triggers = { applied = trig.Added or 0, removed = trig.Removed or 2 }
	local wanted = {}
	for _, g in ipairs(ns.profile.groups) do
		for _, t in ipairs(g.trackers) do
			ns.blizzardSound[t] = nil
			local snd = t.snd
			if snd and (snd.applied or snd.removed) then
				local unit = t.unit or "player"
				for id in pairs(TrackerSpellIds(t)) do
					for ev, trigger in pairs(triggers) do
						local choice = ns.SOUND_CHOICES[snd[ev] or 0]
						local file = choice and choice[4]
						if file then
							local key = unit .. ":" .. id .. ":" .. trigger .. ":" .. file
							wanted[key] = { unit = unit, id = id, trigger = trigger, file = file }
							ns.blizzardSound[t] = ns.blizzardSound[t] or {}
							ns.blizzardSound[t][ev] = true
						end
					end
				end
			end
		end
	end
	for key, regId in pairs(auraSoundRegs) do
		-- Forgotten only once the game has let go of it; otherwise it is tried again next time.
		if not wanted[key] and pcall(C.RemoveAuraSound, regId) then
			auraSoundRegs[key] = nil
			if ns.db.auraSoundIds then ns.db.auraSoundIds[key] = nil end
			ns.auraSoundStats.registered = ns.auraSoundStats.registered - 1
		end
	end
	for key, w in pairs(wanted) do
		if not auraSoundRegs[key] then
			local ok, regId = pcall(C.AddAuraSound, w.trigger, { unitToken = w.unit, spellID = w.id, soundFileID = w.file, outputChannel = "Master" })
			if ok and regId then
				auraSoundRegs[key] = regId
				ns.db.auraSoundIds = ns.db.auraSoundIds or {}
				ns.db.auraSoundIds[key] = regId
				ns.auraSoundStats.registered = ns.auraSoundStats.registered + 1
			else
				ns.auraSoundStats.failed = ns.auraSoundStats.failed + 1
				ns.auraSoundStats.lastError = tostring(regId)
			end
		end
	end
end

-- ------------------------------------------------------------------
-- Events and the driver
-- ------------------------------------------------------------------
local events = CreateFrame("Frame")
local registered = {}
local function SafeRegister(event)
	local ok = pcall(events.RegisterEvent, events, event)
	registered[event] = ok
	return ok
end
-- Only these units' events are wanted, so the client is asked for nothing else.
ns.SafeRegister = SafeRegister
function ns.SafeUnregister(event)
	if not registered[event] then return end
	pcall(events.UnregisterEvent, events, event)
	registered[event] = nil
end
local function SafeRegisterUnit(event, ...)
	if events.RegisterUnitEvent then
		local ok = pcall(events.RegisterUnitEvent, events, event, ...)
		if ok then registered[event] = true return true end
	end
	return SafeRegister(event)
end

local ENV_EVENTS = {
	"GROUP_ROSTER_UPDATE", "ZONE_CHANGED_NEW_AREA", "PLAYER_UPDATE_RESTING", "PLAYER_TARGET_CHANGED",
	"PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "PLAYER_MOUNT_DISPLAY_CHANGED",
}
local isEnvEvent = {}
for _, ev in ipairs(ENV_EVENTS) do isEnvEvent[ev] = true end

local loaded = false
local function Startup()
	if loaded then return end
	loaded = true
	ns.InitDB()
	ns.ClearMaskDiagnostics()
	ns.ClearSettledLook()
	ns.FitAllCells()
	ns.MarkShapedGroups()
	if ns.LearnRacials then pcall(ns.LearnRacials) end
	ns.ApplyMaskSettings()
	ns.playerGUID = UnitGUID and UnitGUID("player")
	ns.targetGUID = UnitGUID and Clean(UnitGUID("target")) or nil
	ns.combatFlag = (InCombatLockdown and InCombatLockdown()) and true or false
	ns.ReadTalents()
	ns.UpdateEnv()
	ns.WantSwingEvents()
	ns.LearnBookRanks()
	if ns.Display and ns.Display.Init then ns.Display:Init() end
	if ns.UI and ns.UI.Init then ns.UI:Init() end
	ns.Settle()
	-- An old saved "combat log on" brought the client's blocked-action dialog back at every login.
	-- The switch now lasts one session and is never saved.
	ns.db.combatLog = nil
end

events:SetScript("OnEvent", function(_, event, a1, a2, a3)
	if event == "ADDON_LOADED" then
		if a1 == ADDON then ns.InitDB() ns.ClearStaleAuraSounds() ns.LogLine("=== Aura Ledger " .. ns.VERSION .. " loaded " .. (date and date("%Y-%m-%d %H:%M") or "")) end
		-- The player opened the spellbook: its art names can be read now.
		if a1 == "Blizzard_PlayerSpells" and loaded and ns.UI and ns.UI.ApplyBookArt then ns.UI:ApplyBookArt() end
		return
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		if a1 == ADDON then
			ns.blocked = ns.blocked or {}
			local fn = tostring(a2)
			if not ns.blocked[fn] then
				ns.blocked[fn] = 0
				-- This event is delivered while the offending call is still on the stack, so the trace
				-- names it. Kept for /auraledger debug.
				ns.blockedStack = ns.blockedStack or {}
				ns.blockedStack[fn] = debugstack and debugstack(2, 14, 0) or "no debugstack"
				Print("the client blocked a protected call made under this addon: " .. fn .. ". Please report it with /auraledger debug.")
			end
			ns.blocked[fn] = ns.blocked[fn] + 1
		end
		return
	elseif event == "PLAYER_LOGIN" then
		Startup()
		return
	end
	if not loaded then return end
	if event == "UNIT_AURA" then
		if a1 ~= "player" and a1 ~= "target" then return end
		HandleAuraInfo(a1, a2)
		Reindex()
		ns.dirty = true
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		HandleCast(a1, a3, a2)
	elseif event == "UNIT_SPELLCAST_START" then
		if a1 == "player" then
			ns.lastCastStart = Clean(a2)
			ns.lastGcdAt = GetTime()
		end
	elseif event == "PLAYER_TARGET_CHANGED" then
		ns.targetGUID = UnitGUID and Clean(UnitGUID("target")) or nil
		ns.UpdateEnv()
	elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
		HandleCombatLog()
	elseif event == "PLAYER_REGEN_DISABLED" then
		ns.combatFlag = true
		ns.UpdateEnv()
	elseif event == "PLAYER_REGEN_ENABLED" then
		ns.combatFlag = false
		ns.UpdateEnv()
		ns.dirty = true
		if ns.soundSyncPending and ns.SyncAuraSounds then ns.SyncAuraSounds() end
		if ns.Display and ns.Display.AfterCombat then ns.Display:AfterCombat() end
		if C_Timer and C_Timer.After then C_Timer.After(1, ns.FlushAdvice) end
	elseif event == "PLAYER_ENTERING_WORLD" then
		ns.playerGUID = UnitGUID and UnitGUID("player") or ns.playerGUID
		if C_Timer and C_Timer.After then
			C_Timer.After(2, function()
				ns.ReadTalents()
				ns.UpdateEnv()
				ns.LearnBookRanks()
				if ns.ResolveAllBookItems then ns.ResolveAllBookItems() end
			end)
			-- A past version took the Cooldown Manager over and tainted it by doing so. Give it back.
			C_Timer.After(6, function()
				if ns.db.cdmLayout or ns.db.cdmSig then
					ns.db.cdmSig = nil
					local ok = ns.CDM and ns.CDM.Restore()
					Print("Aura Ledger no longer uses the Cooldown Manager: borrowing its frames put this addon's mark on the game's own display, and the game then refused its own reads.")
					Print(ok and "|cffffd000The manager has been handed back. Please type /reload once now|r: giving it back is itself a write from this addon, and only a reload clears the mark it leaves."
						or "|cffff5050The manager could not be handed back.|r Choose another layout in the game's own Cooldown Manager settings, then /reload.")
				end
			end)
		end
		if C_Timer and C_Timer.After then C_Timer.After(1, function() if ns.SyncAuraSounds then ns.SyncAuraSounds() end end) end
		ns.UpdateEnv()
		ns.Settle()
	elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
		ns.dirty = true
		local rType, rState = Clean(a1), Clean(a2)
		if C_Timer and C_Timer.After then C_Timer.After(0.5, function()
			ns.dirty = true
			local cdHidden = "n/a"
			if C_Secrets and C_Secrets.ShouldCooldownsBeSecret then
				local ok, v = pcall(C_Secrets.ShouldCooldownsBeSecret)
				cdHidden = not ok and "error" or (issecretvalue and issecretvalue(v)) and "secret" or tostring(v)
			end
			ns.LogLine(("restriction %s -> %s: auras hidden %s, cooldowns hidden %s, combat %s"):format(tostring(rType), tostring(rState),
				tostring(AurasSecret()), cdHidden, tostring(InCombatLockdown and InCombatLockdown())))
			if ns.soundSyncPending and ns.SyncAuraSounds then ns.SyncAuraSounds() end
			if ns.Display and ns.Display.AfterCombat and not (InCombatLockdown and InCombatLockdown()) then ns.Display:AfterCombat() end
		end) end
	elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED" then
		-- What you are carrying has changed, so the page of it is out of date.
		if ns.RefreshBagPage then ns.RefreshBagPage() end
		if event == "PLAYER_EQUIPMENT_CHANGED" and ns.Display and ns.Display.Refresh then ns.Display:Refresh() end
	elseif event == "WEAPON_ENCHANT_CHANGED" or event == "WEAPON_SLOT_CHANGED" or event == "UNIT_INVENTORY_CHANGED" then
		if ns.hasEnchantTrackers and ns.Display and ns.Display.Refresh then ns.Display:Refresh() end
	elseif event == "PLAYER_SWING" then
		-- Recorded only: the display's tick picks a new swing up within a tenth of a second.
		local length, kind = Clean(a1), Clean(a2)
		if type(length) == "number" and length > 0 and length <= 10 and type(kind) == "number" then
			ns.swing[kind] = { duration = length, expires = GetTime() + length }
		end
	elseif event == "PLAYER_TALENT_UPDATE" or event == "TRAIT_CONFIG_UPDATED" or event == "TRAIT_CONFIG_LIST_UPDATED"
		or event == "ACTIVE_TALENT_GROUP_CHANGED" then
		ns.ReadTalents()
		ns.UpdateEnv()
	elseif event == "SPELLS_CHANGED" then
		-- A racial can arrive with a level, or late at login.
		if ns.LearnRacials then pcall(ns.LearnRacials) end
		ns.LearnBookRanks()
		ns.ReadTalents()
		ns.UpdateEnv()
	elseif isEnvEvent[event] then
		ns.UpdateEnv()
	end
end)

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
SafeRegister("ADDON_ACTION_BLOCKED")
SafeRegister("ADDON_ACTION_FORBIDDEN")
-- COMBAT_LOG_EVENT_UNFILTERED is deliberately NOT registered: on this client that registration is
-- a forbidden action (the "blocked from an action only available to the Blizzard UI" dialog at
-- login, which pcall cannot stop). The combat log handler stays for clients that allow it, behind
-- ns.db.combatLog, which is off by default.
SafeRegisterUnit("UNIT_AURA", "player")
SafeRegisterUnit("UNIT_SPELLCAST_SUCCEEDED", "player", "pet")
SafeRegisterUnit("UNIT_SPELLCAST_START", "player")
SafeRegisterUnit("UNIT_INVENTORY_CHANGED", "player")
for _, ev in ipairs({ "WEAPON_ENCHANT_CHANGED", "WEAPON_SLOT_CHANGED", "PLAYER_TALENT_UPDATE", "TRAIT_CONFIG_UPDATED",
	"TRAIT_CONFIG_LIST_UPDATED", "ACTIVE_TALENT_GROUP_CHANGED" }) do
	SafeRegister(ev)
end
for _, ev in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD",
	"ADDON_RESTRICTION_STATE_CHANGED", "BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED", "SPELLS_CHANGED" }) do
	SafeRegister(ev)
end
for _, ev in ipairs(ENV_EVENTS) do SafeRegister(ev) end

-- One driver: coalesced rescans, display timers, a slow poll for things without events.
local tickAcc, slowAcc = 0, 0
function ns.OnUpdate(elapsed)
	if not loaded then return end
	local now = GetTime()
	if ns.dirty then
		-- While restricted every scan is mostly refusals, so space them out.
		local gap = ns.restricted and 0.25 or 0.05
		if not ns.lastScan or now - ns.lastScan >= gap then ns.Scan() end
	end
	-- Drawing every frame is what makes a bar drain smoothly; working out what should be on screen
	-- is the expensive half and stays on its tenth of a second.
	if ns.Display and ns.Display.Draw then ns.Display:Draw(now) end
	tickAcc = tickAcc + elapsed
	if tickAcc >= 0.1 then
		tickAcc = 0
		if ns.Display and ns.Display.Tick then ns.Display:Tick(now) end
	end
	slowAcc = slowAcc + elapsed
	if slowAcc >= 0.5 then
		slowAcc = 0
		ns.UpdateEnv()
		-- New ranks reach the slots and the combat sounds.
		if ns.ranksChanged then
			ns.ranksChanged = nil
			if ns.SyncAuraSounds then ns.SyncAuraSounds() end
			if ns.Display and ns.Display.Refresh then ns.Display:Refresh() end
		end
		-- The auras you already had when you reloaded come with no event of any kind, so for a
		-- little while after entering the world the addon simply asks again.
		if ns.settleUntil then
			if now < ns.settleUntil then ns.dirty = true else ns.settleUntil = nil end
		end
		-- The spellbook's spell entries only exist once it has been opened; read its art then.
		if not ns.bookArtRead and PlayerSpellsFrame and PlayerSpellsFrame.IsShown and PlayerSpellsFrame:IsShown() then
			ns.bookArtRead = true
			if ns.UI and ns.UI.ApplyBookArt then C_Timer.After(0.5, function() ns.UI:ApplyBookArt() end) end
		end
		-- Carried or estimated auras have no event when they lapse.
		for _, unit in ipairs(ns.UNITS) do
			for _, e in pairs(ns.AuraTable(unit)) do
				if (e.stale or e.estimated) and e.expires > 0 and now > e.expires then ns.dirty = true break end
			end
		end
		-- While auras are secret, the default buff frames' icons are the only live word we get.
	end
end
events:SetScript("OnUpdate", function(_, elapsed) ns.OnUpdate(elapsed) end)

-- ------------------------------------------------------------------
-- Sharing: a tracker or a whole group as a paste-able string.
-- Format: "!AL1:" followed by base64 of a plain-text table literal. The reader is a small parser
-- of its own (no load()), so a pasted string can only ever become data.
-- ------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64R = {}
for i = 1, 64 do B64R[B64:sub(i, i)] = i - 1 end

local function B64Encode(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1, c2 = floor(n / 262144) % 64, floor(n / 4096) % 64
		local c3, c4 = floor(n / 64) % 64, n % 64
		out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
			.. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
	end
	return table.concat(out)
end

local function B64Decode(text)
	text = text:gsub("[^%w%+/=]", "")
	local out = {}
	for i = 1, #text, 4 do
		local c1, c2, c3, c4 = text:sub(i, i), text:sub(i + 1, i + 1), text:sub(i + 2, i + 2), text:sub(i + 3, i + 3)
		local n = (B64R[c1] or 0) * 262144 + (B64R[c2] or 0) * 4096 + (B64R[c3] or 0) * 64 + (B64R[c4] or 0)
		out[#out + 1] = string.char(floor(n / 65536) % 256)
		if c3 ~= "=" and c3 ~= "" then out[#out + 1] = string.char(floor(n / 256) % 256) end
		if c4 ~= "=" and c4 ~= "" then out[#out + 1] = string.char(n % 256) end
	end
	return table.concat(out)
end

local function Serialize(v, out)
	local tv = type(v)
	if tv == "table" then
		out[#out + 1] = "{"
		for k, val in pairs(v) do
			local tk = type(k)
			if (tk == "string" or tk == "number" or tk == "boolean") and (type(val) ~= "function") then
				out[#out + 1] = "["
				Serialize(k, out)
				out[#out + 1] = "]="
				Serialize(val, out)
				out[#out + 1] = ","
			end
		end
		out[#out + 1] = "}"
	elseif tv == "string" then
		out[#out + 1] = string.format("%q", v)
	elseif tv == "number" then
		out[#out + 1] = tostring(v)
	elseif tv == "boolean" then
		out[#out + 1] = v and "true" or "false"
	else
		out[#out + 1] = "nil"
	end
end

-- Reads back what Serialize wrote. Returns value, nextPos or nil, error.
local function Parse(s, pos)
	pos = pos or 1
	local c = s:sub(pos, pos)
	if c == "{" then
		local t = {}
		pos = pos + 1
		while true do
			c = s:sub(pos, pos)
			if c == "}" then return t, pos + 1 end
			if c ~= "[" then return nil, pos, "expected key" end
			local key, np, err = Parse(s, pos + 1)
			if err then return nil, np, err end
			if s:sub(np, np + 1) ~= "]=" then return nil, np, "expected ]=" end
			local val
			val, np, err = Parse(s, np + 2)
			if err then return nil, np, err end
			t[key] = val
			if s:sub(np, np) == "," then np = np + 1 end
			pos = np
			if pos > #s then return nil, pos, "unterminated table" end
		end
	elseif c == '"' then
		local i = pos + 1
		local buf = {}
		while i <= #s do
			local ch = s:sub(i, i)
			if ch == "\\" then
				local nx = s:sub(i + 1, i + 1)
				if nx == "n" then buf[#buf + 1] = "\n"
				elseif nx == "\n" then buf[#buf + 1] = "\n"
				elseif nx:match("%d") then
					local digits = s:match("^%d%d?%d?", i + 1)
					buf[#buf + 1] = string.char(tonumber(digits))
					i = i + #digits - 1
				else buf[#buf + 1] = nx end
				i = i + 2
			elseif ch == '"' then
				return table.concat(buf), i + 1
			else
				buf[#buf + 1] = ch
				i = i + 1
			end
		end
		return nil, i, "unterminated string"
	elseif s:sub(pos, pos + 3) == "true" then return true, pos + 4
	elseif s:sub(pos, pos + 4) == "false" then return false, pos + 5
	elseif s:sub(pos, pos + 2) == "nil" then return nil, pos + 3
	else
		local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
		if num and num ~= "" and tonumber(num) then return tonumber(num), pos + #num end
		return nil, pos, "unexpected '" .. c .. "'"
	end
end

local TRACKER_KEYS = { "name", "id", "icon", "kind", "matchId", "show", "mine", "label", "unit", "warn", "cond", "snd", "cd", "item", "glow", "enchant", "swing" }

local function CopyTracker(t)
	local c = {}
	for _, k in ipairs(TRACKER_KEYS) do
		local v = t[k]
		if type(v) == "table" then
			local cc = {}
			for kk, vv in pairs(v) do
				if type(vv) == "table" then
					local ccc = {}
					for k3, v3 in pairs(vv) do ccc[k3] = v3 end
					cc[kk] = ccc
				else cc[kk] = vv end
			end
			c[k] = cc
		elseif v ~= nil then c[k] = v end
	end
	return c
end

local function CopyGroup(g)
	local c = { trackers = {} }
	for _, k in ipairs(ns.GROUP_STYLE_KEYS) do if g[k] ~= nil then c[k] = g[k] end end
	c.name = g.name
	c.cond = {}
	for k, v in pairs(g.cond or {}) do
		if type(v) == "table" then local cc = {} for kk, vv in pairs(v) do cc[kk] = vv end c.cond[k] = cc else c.cond[k] = v end
	end
	for i, t in ipairs(g.trackers) do c.trackers[i] = CopyTracker(t) end
	return c
end

-- Returns the string for a tracker ("tracker") or a group ("group").
function ns.Export(obj, kind)
	local data = { v = 1, kind = kind, addon = "AuraLedger" }
	if kind == "group" then data.group = CopyGroup(obj) else data.tracker = CopyTracker(obj) end
	local out = {}
	Serialize(data, out)
	return "!AL1:" .. B64Encode(table.concat(out))
end

-- Imports a string. Returns the created group (a tracker comes in as a group of one) or nil, error.
function ns.Import(text)
	text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if not text:find("^!AL1:") then return nil, "That is not an Aura Ledger string (it should start with !AL1:)." end
	local raw = B64Decode(text:sub(6))
	local data, _, err = Parse(raw, 1)
	if err or type(data) ~= "table" or data.addon ~= "AuraLedger" then return nil, "That string could not be read" .. (err and (": " .. err) or ".") end
	local n = #ns.profile.groups
	local x = (UIParent:GetWidth() or 1024) / 2 - 40 + (n % 6) * 12
	local y = (UIParent:GetHeight() or 768) / 2 + 100 - (n % 6) * 12
	local function CleanTracker(src)
		if type(src) ~= "table" or (not src.name and not src.id and not tonumber(src.item)) then return nil end
		if (src.enchant ~= nil or src.swing ~= nil) and not src.name then return nil end
		local t = ns.NewTracker({ name = src.name, id = src.id, icon = src.icon, kind = src.kind or "any",
			item = tonumber(src.item), cd = (src.cd or tonumber(src.item)) and true or nil })
		t.matchId = src.matchId and true or false
		t.show = (src.show == "missing" or src.show == "always") and src.show or "active"
		t.mine = src.mine and true or false
		t.label = type(src.label) == "string" and src.label or nil
		t.unit = src.unit == "target" and "target" or nil
		t.warn = tonumber(src.warn) or nil
		t.cond = type(src.cond) == "table" and src.cond or {}
		t.snd = type(src.snd) == "table" and src.snd or nil
		t.glow = src.glow and true or nil
		local function WeaponSlot(v) v = tonumber(v) return (v == 0 or v == 1 or v == 2) and v or nil end
		t.enchant, t.swing = WeaponSlot(src.enchant), WeaponSlot(src.swing)
		return t
	end
	if data.kind == "group" and type(data.group) == "table" then
		local src = data.group
		local g = ns.NewGroup(x, y)
		for _, k in ipairs(ns.GROUP_STYLE_KEYS) do if src[k] ~= nil then g[k] = src[k] end end
		g.name = type(src.name) == "string" and src.name or nil
		g.cond = type(src.cond) == "table" and src.cond or {}
		for _, ts in ipairs(src.trackers or {}) do
			local t = CleanTracker(ts)
			if t then table.insert(g.trackers, t) end
		end
		if #g.trackers == 0 then ns.DeleteGroup(g) return nil, "That group had no trackers in it." end
		ns.selected = { group = g }
		ns.Changed()
		return g
	elseif data.kind == "tracker" and type(data.tracker) == "table" then
		local t = CleanTracker(data.tracker)
		if not t then return nil, "That tracker had no name or spell ID." end
		local g = ns.NewGroup(x, y)
		table.insert(g.trackers, t)
		ns.selected = { group = g, tracker = t }
		ns.Changed()
		return g
	end
	return nil, "That string holds neither a tracker nor a group."
end

-- ------------------------------------------------------------------
-- Advice with the fix on it. A line of chat scrolls away and is easy to miss, so anything the
-- user has to act on is raised as a dialog with a Reload button. Each reason is raised once a
-- session, and never during a fight: it waits for the fight to end, and is dropped if the addon
-- has put itself right by then.
-- ------------------------------------------------------------------
-- The diagnostic topics, in the order the help lists them.
-- Clips a texture to the rounded-square shape of the client's icon frames (the action bar's own
-- icon mask), so an icon sits inside the frame art without its square corners showing past it.
-- The shape covers about two thirds of the mask region, so the region is drawn larger than the
-- texture: sized to the texture it would show only the middle of the picture.
ns.ICON_MASK = "UI-HUD-ActionBar-IconFrame-Mask"
-- How far past the icon the mask region is drawn, and how far up, both as a share of the icon's
-- size. The shape fills about two thirds of the region, hence the first; it does not sit in the
-- middle of it on this client, hence the second. /auraledger iconmask sets them.
ns.MASK_OVER, ns.MASK_SHIFT = 0.26, 0
-- The frame the client draws round its own icons, which the mask above is cut for: the action bar
-- wears it, so do the spellbook and the buff bar. The Cooldown Manager's overlay is a different
-- shape and was what this addon used to copy. In the order they are looked for.
ns.ICON_FRAMES = { "UI-HUD-ActionBar-IconFrame", "UI-HUD-ActionBar-IconFrame-Slot", "UI-HUD-ActionBar-IconFrame-Border" }
-- The frame is not the mask and is not drawn like it: it is art with a thin border round the icon,
-- not a shape that has to be grown to fit. Its own two numbers, set by /auraledger iconborder size.
ns.FRAME_OVER, ns.FRAME_SHIFT = 0.115, 0
-- Bumped whenever the mask changes, so every widget knows to dress itself again.
ns.MASK_EPOCH = 0

-- "size" is what the icon will be, which the caller knows: read off the texture instead, it can
-- still be nothing at all, and a mask drawn to nothing sits on the icon and hides all but its
-- middle.
-- Every mask made, so a change to the numbers can be seen without a reload.
local masks = {}

local function PointMask(m, tex, size)
	local w = size or (tex.GetWidth and tex:GetWidth()) or 0
	local h = size or (tex.GetHeight and tex:GetHeight()) or 0
	if not w or w <= 0 then w = 40 end
	if not h or h <= 0 then h = 40 end
	local over, shift = ns.MASK_OVER, ns.MASK_SHIFT * h
	m:ClearAllPoints()
	m:SetPoint("TOPLEFT", tex, "TOPLEFT", -over * w, over * h + shift)
	m:SetPoint("BOTTOMRIGHT", tex, "BOTTOMRIGHT", over * w, -over * h + shift)
	m.alSize = size
end

-- Takes every mask off the icon it was clipping, for icons already on screen.
function ns.ClearAllMasks()
	local n = 0
	for tex, m in pairs(masks) do
		if tex.alMask == m then
			if tex.RemoveMaskTexture then pcall(tex.RemoveMaskTexture, tex, m) end
			pcall(m.Hide, m)
			tex.alMask = nil
			n = n + 1
		end
		masks[tex] = nil
	end
	return n
end

-- Puts every mask back where the current numbers say, for tuning them in game.
function ns.RepointMasks()
	local n = 0
	for tex, m in pairs(masks) do
		if tex.alMask == m then
			PointMask(m, tex, m.alSize)
			n = n + 1
		else
			masks[tex] = nil
		end
	end
	return n
end

local function MaskOne(frame, tex, size)
	if not tex then return end
	if tex.alMask then
		PointMask(tex.alMask, tex, size)
		return
	end
	local ok, m = pcall(frame.CreateMaskTexture, frame)
	if ok and m and pcall(m.SetAtlas, m, ns.ICON_MASK) then
		PointMask(m, tex, size)
		if tex.AddMaskTexture and pcall(tex.AddMaskTexture, tex, m) then
			tex.alMask = m
			masks[tex] = m
		else
			pcall(m.Hide, m)
		end
	end
end

function ns.MaskIcon(frame, ...)
	if ns.db and ns.db.maskOff then
		ns.report["icon mask"] = "turned off (/auraledger iconmask on)"
		return false
	end
	if not (frame.CreateMaskTexture and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(ns.ICON_MASK)) then
		ns.report["icon mask"] = "none"
		return false
	end
	for i = 1, select("#", ...) do
		MaskOne(frame, (select(i, ...)))
	end
	ns.report["icon mask"] = ns.ICON_MASK
	return true
end

-- The same, switchable, for the trackers: a group can turn its icon frame off, and a bare icon
-- should keep its own corners.
function ns.SetIconMask(frame, tex, on, size)
	if not tex then return false end
	-- Not unless it is asked for: the shape this client's mask cuts is a tab, rounded along the top
	-- and flat along the bottom, which is not what an icon should look like.
	if on and not (ns.db and ns.db.maskOn) then
		on = false
	end
	if on then
		if not (frame.CreateMaskTexture and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(ns.ICON_MASK)) then
			ns.report["icon mask"] = "none"
			return false
		end
		MaskOne(frame, tex, size)
		ns.report["icon mask"] = ns.ICON_MASK
		return tex.alMask ~= nil
	end
	if tex.alMask then
		if tex.RemoveMaskTexture then pcall(tex.RemoveMaskTexture, tex, tex.alMask) end
		pcall(tex.alMask.Hide, tex.alMask)
		masks[tex] = nil
		tex.alMask = nil
	end
	return false
end

-- The icon mask's numbers, once the saved settings are in hand.
function ns.ApplyMaskSettings()
	ns.MASK_OVER = tonumber(ns.db and ns.db.maskOver) or 0.26
	ns.MASK_SHIFT = tonumber(ns.db and ns.db.maskShift) or 0
	ns.FRAME_OVER = tonumber(ns.db and ns.db.frameOver) or 0.115
	ns.FRAME_SHIFT = tonumber(ns.db and ns.db.frameShift) or 0
end

-- 1.42.2: the mask shift and the mask being off were both diagnostics aimed at a layer that turned
-- out to be innocent, and the shift is what bent the frame out of shape. Cleared once.
-- 1.58.0: the numbers found by eye are the defaults now, so a saved setting that matches one is
-- dropped once: the tuning panel says "default", and a later change to a default is picked up.
function ns.ClearSettledLook()
	if not ns.db or ns.db.lookSettled then return end
	ns.db.lookSettled = true
	if tonumber(ns.db.fillInsetX) == 0.22 then ns.db.fillInsetX = nil end
	if tonumber(ns.db.plateTop) == 0.08 then ns.db.plateTop = nil end
	if tonumber(ns.db.plateBottom) == 0.35 then ns.db.plateBottom = nil end
end

function ns.ClearMaskDiagnostics()
	if ns.db and not ns.db.maskDiagCleared then
		ns.db.maskDiagCleared = true
		ns.db.maskShift, ns.db.maskOff = nil, nil
	end
	-- 1.43.0: the frame this client offers is the shape of a tab, so a tracker wears a clean edge
	-- unless something else was asked for after this.
	if ns.db and not ns.db.cleanEdgeDefault then
		ns.db.cleanEdgeDefault = true
		ns.db.iconBorder, ns.db.maskOff, ns.db.maskOn = nil, nil, nil
	end
end

ns.DIAG_ORDER = { "log", "api", "gd", "cdm2", "cdmrestore", "probe", "atlases", "icon", "item", "cdread" }
ns.DIAG = {}
for _, k in ipairs(ns.DIAG_ORDER) do ns.DIAG[k] = true end
ns.DIAG.soundtest, ns.DIAG.soundclear = true, true

local adviceSeen, advicePending = {}, {}

if type(StaticPopupDialogs) == "table" then
	StaticPopupDialogs["AURALEDGER_ADVICE"] = {
		text = "Aura Ledger\n\n%s",
		button1 = RELOADUI or "Reload UI",
		button2 = CLOSE or "Close",
		OnAccept = function() ReloadUI() end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}
end

-- stillWrong: called when the fight ends; the advice is dropped when it answers false.
function ns.Advise(key, text, stillWrong)
	if adviceSeen[key] then return end
	if InCombatLockdown and InCombatLockdown() then
		advicePending[key] = { text = text, check = stillWrong }
		return
	end
	adviceSeen[key] = true
	Print(text)
	if type(StaticPopupDialogs) == "table" and StaticPopup_Show then
		pcall(StaticPopup_Show, "AURALEDGER_ADVICE", text)
	end
end

function ns.FlushAdvice()
	for key, item in pairs(advicePending) do
		advicePending[key] = nil
		if not item.check or item.check() then ns.Advise(key, item.text) end
	end
end

-- ------------------------------------------------------------------
-- Slash commands
-- ------------------------------------------------------------------
local function Help()
	Print("v" .. ns.VERSION .. " commands:")
	Print("  /auraledger - open or close the window")
	Print("  /auraledger add <spell name or ID> - add an aura and start tracking it")
	Print("  /auraledger cooldown <spell name or ID> - follow a spell's cooldown instead of a buff")
	Print("  /auraledger useitem <item name> - follow the cooldown of something you are carrying")
	Print("  /auraledger bags - what you are carrying that has a use on it")
	Print("  /auraledger racials - the racials this client knows about")
	Print("  /auraledger import <string> - import a tracker or group from an export string")
	Print("  /auraledger edit - turn arranging on or off: drag trackers about and click one to change it")
	Print("  /auraledger minimap - show or hide the minimap button")
	Print("  /auraledger plainbook - switch the book between parchment and a plain dark page")
	Print("  /auraledger sound test | clear - play each sound the game can make, or remove the ones registered with it")
	Print("  /auraledger debug - what this client let the addon read (send this with a bug report)")
	Print("  /auraledger debug <topic> - a closer look: " .. table.concat(ns.DIAG_ORDER, ", "))
end

local function YesNo(v) return v and "|cff40ff40yes|r" or "|cffff5050no|r" end

-- Everything the Coolinator addon relies on to make Blizzard's Cooldown Manager draw the spells
-- you choose: the viewers' item frame pools, each item's cooldown id and shown state, and the
-- layout data APIs. "emit" is Print for the command, or the log writer for the quiet run.
function ns.ProbeCDM(emit)
	local function S(v) if issecretvalue and issecretvalue(v) then return "secret" end return tostring(v) end
	local function Has(t, k) return t and t[k] ~= nil and YesNo(true) or YesNo(false) end
	emit("Cooldown Manager, the way Coolinator uses it (secret right now: " .. YesNo(AurasSecret()) .. "):")
	emit("  C_CooldownViewer: GetLayoutData " .. Has(C_CooldownViewer, "GetLayoutData") .. ", SetLayoutData " .. Has(C_CooldownViewer, "SetLayoutData")
		.. ", GetCooldownViewerCategorySet " .. Has(C_CooldownViewer, "GetCooldownViewerCategorySet") .. ", GetCooldownViewerCooldownInfo " .. Has(C_CooldownViewer, "GetCooldownViewerCooldownInfo"))
	emit("  C_EncodingUtil: " .. YesNo(C_EncodingUtil) .. " (SerializeCBOR " .. Has(C_EncodingUtil, "SerializeCBOR") .. ", CompressString " .. Has(C_EncodingUtil, "CompressString")
		.. ", EncodeBase64 " .. Has(C_EncodingUtil, "EncodeBase64") .. "), CooldownViewerSettings " .. YesNo(CooldownViewerSettings)
		.. ", CooldownViewerUtil " .. YesNo(CooldownViewerUtil) .. ", cooldownViewerEnabled cvar " .. tostring(C_CVar and C_CVar.GetCVar and select(2, pcall(C_CVar.GetCVar, "cooldownViewerEnabled"))))
	if CooldownViewerUtil and CooldownViewerUtil.GetCurrentClassAndSpecTag then
		emit("  class/spec tag: " .. S(select(2, pcall(CooldownViewerUtil.GetCurrentClassAndSpecTag))))
	end
	if C_CooldownViewer and C_CooldownViewer.GetLayoutData then
		local ok, raw = pcall(C_CooldownViewer.GetLayoutData)
		if ok and type(raw) == "string" then
			emit(("  layout data: %d characters, starts %s"):format(#raw, raw:sub(1, 12)))
			local body = raw:match("^%d%|(.*)$")
			if body and C_EncodingUtil and C_EncodingUtil.DecodeBase64 then
				local okD, data = pcall(function()
					return C_EncodingUtil.DeserializeCBOR(C_EncodingUtil.DecompressString(C_EncodingUtil.DecodeBase64(body), Enum.CompressionMethod.Deflate))
				end)
				if okD and type(data) == "table" then
					local keys = {}
					for k, v in pairs(data) do keys[#keys + 1] = tostring(k) .. "=" .. (type(v) == "table" and "{}" or tostring(v)) end
					table.sort(keys)
					emit("    decoded, format version " .. tostring(data[1]) .. ", fields " .. table.concat(keys, ", "))
				else
					emit("    could not decode: " .. tostring(data))
				end
			end
		else
			emit("  layout data: " .. (ok and S(raw) or ("error " .. tostring(raw))))
		end
	end
	for _, vname in ipairs({ "BuffIconCooldownViewer", "BuffBarCooldownViewer", "EssentialCooldownViewer", "UtilityCooldownViewer" }) do
		local v = _G[vname]
		if not v then
			emit("  " .. vname .. ": missing")
		else
			local pool = v.itemFramePool
			local okShown, shown = pcall(v.IsShown, v)
			emit(("  %s: shown %s, itemFramePool %s, RefreshData %s, OnUnitAura %s, OnUnitTarget %s"):format(
				vname, okShown and S(shown) or "error", YesNo(pool), Has(v, "RefreshData"), Has(v, "OnUnitAura"), Has(v, "OnUnitTarget") ))
			if pool and pool.EnumerateActive then
				local n = 0
				local okE = pcall(function()
					for item in pool:EnumerateActive() do
						n = n + 1
						if n <= 8 then
							local cid = item.cooldownID
							local info = cid and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo and select(2, pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cid))
							local sid = type(info) == "table" and Clean(info.spellID) or nil
							local okS2, sh = pcall(item.IsShown, item)
							emit(("    item %d: cooldownID %s (%s), layoutIndex %s, shown %s, Icon %s, Cooldown %s, Applications %s, DebuffBorder %s"):format(
								n, S(cid), sid and (ns.SpellName and ns.SpellName(sid) or tostring(sid)) or "?", S(item.layoutIndex),
								okS2 and S(sh) or "error", Has(item, "Icon"), Has(item, "Cooldown"), Has(item, "Applications"), Has(item, "DebuffBorder")))
						end
					end
				end)
				emit(("    %d active item frames%s"):format(n, okE and "" or " (enumeration failed)"))
			end
		end
	end
	local pool = BuffIconCooldownViewer and BuffIconCooldownViewer.itemFramePool
	local items = 0
	if pool and pool.EnumerateActive then
		pcall(function() for _ in pool:EnumerateActive() do items = items + 1 end end)
	end
	local summary = ("pool %s, items %d, layout %s, encoding %s, settings %s"):format(
		pool and "yes" or "no", items,
		(C_CooldownViewer and C_CooldownViewer.SetLayoutData) and "yes" or "no",
		(C_EncodingUtil and C_EncodingUtil.SerializeCBOR) and "yes" or "no",
		CooldownViewerSettings and "yes" or "no")
	ns.report["cooldown manager"] = summary
	return summary
end

local function Debug()
	Print("v" .. ns.VERSION .. " debug for " .. tostring(ns.charKey))
	Print("  APIs: GetAuraDataByIndex " .. YesNo(C_UnitAuras and C_UnitAuras.GetAuraDataByIndex)
		.. ", ByInstanceID " .. YesNo(C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID)
		.. ", UnitAura " .. YesNo(UnitAura) .. ", issecretvalue " .. YesNo(issecretvalue))
	Print("  C_Secrets: auras " .. YesNo(C_Secrets and C_Secrets.ShouldAurasBeSecret)
		.. ", index " .. YesNo(C_Secrets and C_Secrets.ShouldUnitAuraIndexBeSecret)
		.. ", instance " .. YesNo(C_Secrets and C_Secrets.ShouldUnitAuraInstanceBeSecret)
		.. "; secret right now: " .. YesNo(AurasSecret()) .. ", last scan partial: " .. YesNo(ns.restricted))
	local bst = ns.bagStats or {}
	Print(("  bags: %d slots and %d worn pieces read, %d with a use (C_Container %s, C_Item.GetItemSpell %s, GetItemCooldown %s)"):format(
		bst.bags or 0, bst.gear or 0, bst.withUse or 0,
		YesNo(C_Container and C_Container.GetContainerItemID), YesNo(C_Item and C_Item.GetItemSpell),
		YesNo((C_Item and C_Item.GetItemCooldown) or GetItemCooldown)))
	local rst = ns.racialStats or {}
	Print(("  racials from the client: %s, %d lines, %d spells, %s line, %d added"):format(
		rst.api or "none", rst.lines or 0, rst.scanned or 0, tostring(rst.line or "none"), rst.added or 0))
	Print("  settling after entering the world: " .. (ns.settleUntil and (("%.1fs left"):format(ns.settleUntil - GetTime())) or "no, finished"))
	local s = ns.stats
	Print(("  scans %d (partial %d, blocked %d), removals by id %d, estimated refreshes %d"):format(
		s.scans, s.partial, s.blocked, s.removedById, s.estimated))
	Print(("  combat log: %s, aura events %d, used while restricted %d"):format(
		registered.COMBAT_LOG_EVENT_UNFILTERED and (ns.combatLogTried and "tried this session" or "registered") or "not registered (this client refuses it to addons)", s.cleu, s.cleuUsed))
	local function CS(fn, ...)
		if not fn then return "n/a" end
		local ok, v = pcall(fn, ...)
		if not ok then return "error" end
		if issecretvalue and issecretvalue(v) then return "secret" end
		return tostring(v)
	end
	Print(("  cooldowns: hidden right now %s; hidden readings so far %d%s"):format(
		CS(C_Secrets and C_Secrets.ShouldCooldownsBeSecret), s.secretCd or 0,
		s.secretCdLast and (", last " .. tostring(s.secretCdLast)) or ""))
	Print(("  your casts: %d seen, %d turned into auras while restricted (spell cast events %s)"):format(
		s.casts, s.castsUsed, registered.UNIT_SPELLCAST_SUCCEEDED and "registered" or "not registered"))
	local as = ns.auraSoundStats
	Print(("  Blizzard aura sounds: %d registered, %d failed, %d stale ones cleared at load%s (API %s)"):format(as.registered, as.failed, as.cleared, as.lastError and (", last error " .. as.lastError) or "", YesNo(C_UnitAuras and C_UnitAuras.AddAuraSound)))
	for key, id in pairs(ns.db.auraSoundIds or {}) do
		local unit, spell, trigger, file = key:match("^(.-):(%d+):(%d+):(%d+)$")
		local cname
		for _, c in ipairs(ns.SOUND_CHOICES) do if c[4] and tostring(c[4]) == file then cname = c[1] end end
		Print(("    %s spell %s (%s) on %s: %s [file %s], registration %s"):format(
			trigger == "2" and "removed" or trigger == "1" and "stacks" or "added", tostring(spell), ns.SpellName and ns.SpellName(tonumber(spell)) or "?", tostring(unit), cname or "?", tostring(file), tostring(id)))
	end
	local p = ns.payloadStats
	Print(("  aura events while restricted: %d; removed lists plain %d / secret %d, updated plain %d / secret %d, added plain %d / secret %d, full updates %d, secret ids dropped %d"):format(
		p.events, p.plainRemoved, p.secretRemoved, p.plainUpdated, p.secretUpdated, p.plainAdded, p.secretAdded, p.full, p.secretIds or 0))
	if p.sample then Print("    last payload: " .. p.sample) end
	local live, carried = 0, 0
	for _, e in pairs(ns.auras) do live = live + 1 if e.stale or e.estimated then carried = carried + 1 end end
	local onTarget = 0
	for _ in pairs(ns.targetAuras) do onTarget = onTarget + 1 end
	local rows = 0
	for _ in pairs(ns.db.history) do rows = rows + 1 end
	local trackers = 0
	for _, g in ipairs(ns.profile.groups) do trackers = trackers + #g.trackers end
	Print(("  auras now %d on you, %d on your target (carried or estimated %d), ledger rows %d, groups %d, trackers %d"):format(
		live, onTarget, carried, rows, #ns.profile.groups, trackers))
	local e = ns.env
	Print(("  state: combat %s, group %s, place %s, class %s, resting %s, mounted %s"):format(
		tostring(e.combat), tostring(e.group), tostring(e.place), tostring(e.class), tostring(e.resting), tostring(e.mounted)))
	do
		local trees = {}
		for _, tr in ipairs(ns.talentTrees or {}) do trees[#trees + 1] = tr.name .. " " .. tr.spent end
		Print(("  talents: set %s of %s, trees %s, main tree %s"):format(tostring(e.talentSet), tostring(e.talentSets),
			#trees > 0 and table.concat(trees, " / ") or "not read", tostring(e.mainTree)))
		local swings = {}
		for k, s in pairs(ns.swing) do swings[#swings + 1] = ("%s %.2fs"):format(tostring(k), s.duration) end
		Print(("  weapons: enchant API %s, swing event %s, last swings %s"):format(YesNo(C_Item and C_Item.GetWeaponEnchantInfo),
			registered.PLAYER_SWING and "registered" or "not asked for", #swings > 0 and table.concat(swings, ", ") or "none"))
	end
	if ns.BookStats then
		local total, exact, iconOnly, unknown = ns.BookStats()
		Print(("  pre-built book: %d auras offered, %d resolved by ID, %d icon only (client name differs), %d withheld as unknown to this client"):format(total, exact, iconOnly, unknown))
	end
	do
		local bundled, kept, dropped, pending = 0, 0, 0, 0
		for _ in pairs(ns.RANK_IDS or {}) do bundled = bundled + 1 end
		for _, st in pairs(ns.rankState) do kept, dropped, pending = kept + st.kept, dropped + st.dropped, pending + st.pending end
		local own = 0
		for _, set in pairs(ns.bookRanks) do local n = 0 for _ in pairs(set) do n = n + 1 end if n > 1 then own = own + 1 end end
		Print(("  ranks: %d spells bundled (ids checked so far: %d kept, %d dropped, %d pending), %d of your spells with more than one rank"):format(
			bundled, kept, dropped, pending, own))
	end
	Print("  spellbook frame: " .. (PlayerSpellsFrame and "loaded" or "not loaded") .. ", minimize art copied: " .. tostring(ns.db.miniArt ~= nil) .. ", dump lines: " .. tostring(ns.db.psDump and #ns.db.psDump or 0))
	if ns.blocked then
		for fn, n in pairs(ns.blocked) do
			Print(("  BLOCKED protected call: %s (x%d)"):format(fn, n))
			local stack = ns.blockedStack and ns.blockedStack[fn]
			if stack then
				for line in tostring(stack):gmatch("[^\n]+") do Print("    " .. line) end
			end
		end
	else
		Print("  blocked protected calls: none")
	end
	local keys = {}
	for k in pairs(ns.report) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do Print("  " .. k .. ": " .. tostring(ns.report[k])) end
end

SLASH_AURALEDGER1 = "/auraledger"
SLASH_AURALEDGER2 = "/aledger"
SlashCmdList.AURALEDGER = function(msg)
	if not loaded then Startup() end
	msg = tostring(msg or "")
	local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
	cmd = strlower(cmd or "")
	-- The diagnostics live behind one command; their old names still work, so older notes do too.
	if cmd == "debug" and rest ~= "" then
		local sub, tail = rest:match("^(%S+)%s*(.-)$")
		sub = strlower(sub or "")
		if ns.DIAG[sub] then
			cmd, rest = sub, tail
		else
			Print("No such topic. Try: " .. table.concat(ns.DIAG_ORDER, ", "))
			return
		end
	elseif cmd == "sound" then
		local sub, tail = rest:match("^(%S+)%s*(.-)$")
		sub = strlower(sub or "")
		if sub == "test" then cmd, rest = "soundtest", tail
		elseif sub == "clear" then cmd, rest = "soundclear", tail
		else Print("Use /auraledger sound test, or /auraledger sound clear.") return end
	end
	if cmd == "" then
		if ns.UI and ns.UI.Toggle then ns.UI:Toggle() end
	elseif cmd == "add" then
		local h, err = ns.AddManual(rest)
		if not h then Print(err) return end
		ns.TrackHistory(h)
		Print("Tracking " .. (h.name or ("spell " .. tostring(h.id))) .. ". Open /auraledger to move it or change how it shows.")
		if ns.UI and ns.UI.RefreshHistory then ns.UI:RefreshHistory() end
	elseif cmd == "useitem" or cmd == "item2" then
		if rest == "" then
			Print("|cffffd000/auraledger useitem <item name>|r follows that item's cooldown. Everything you are carrying with a use on it is also on the bags page of the book.")
			return
		end
		local want, found = strlower(rest), nil
		for _, row in ipairs(ns.BookPages().BAGS or {}) do
			if row.item and strlower(row.name or "") == want then found = row break end
		end
		if not found then
			for _, row in ipairs(ns.BookPages().BAGS or {}) do
				if row.item and strlower(row.name or ""):find(want, 1, true) then found = row break end
			end
		end
		if not found then
			Print("Nothing you are carrying is called " .. rest .. ", or it has no use on it. /auraledger bags lists what was found.")
			return
		end
		local t = ns.TrackHistory(found)
		Print("Following the cooldown of " .. found.name .. ".")
		if ns.UI and ns.UI.RefreshHistory then ns.UI:RefreshHistory() end
	elseif cmd == "bags" then
		if ns.RefreshBagPage then ns.RefreshBagPage() end
		local page = ns.BookPages().BAGS or {}
		local st = ns.bagStats or {}
		Print(("what you are carrying: %d bag slots and %d worn pieces read, %d with a use, %d of those unnamed so far"):format(
			st.bags or 0, st.gear or 0, st.withUse or 0, st.unnamed or 0))
		local items = 0
		for _, row in ipairs(page) do
			if row.item then
				items = items + 1
				Print(("  %s |cff808080(item %d, %s)|r"):format(row.name, row.item, row.note or ""))
			end
		end
		if items == 0 then
			Print("  nothing with a use was found. If that is wrong, this client may not be answering one of the bag calls; please report it.")
		end
	elseif cmd == "racials" then
		if ns.LearnRacials then pcall(ns.LearnRacials) end
		local st = ns.racialStats or {}
		Print(("racials: read through %s, %d lines, %d spells seen, the %s line used, %d were candidates, %d added to the page"):format(
			st.api or "none", st.lines or 0, st.scanned or 0, tostring(st.line or "none"), st.found or 0, st.added or 0))
		Print("If the line named above is not the one your racials are on, say so and it can be picked differently.")
		Print("Only your own race's can be read from the client. Send the list below and the rest can be written in for every race.")
		for _, row in ipairs(ns.BookPages().RACIAL or {}) do
			Print(("  %s |cff808080(%s%s)|r"):format(row.name, row.listId and ("spell " .. row.listId) or "no id",
				row.fromClient and ", from this client" or ""))
		end
	elseif cmd == "cooldown" or cmd == "cd" then
		if rest == "" then
			Print("|cffffd000/auraledger cooldown <spell name or ID>|r follows that spell's cooldown. An aura you already track can be switched over under Watch in its options.")
			return
		end
		local h, err = ns.AddManual(rest)
		if not h then Print(err) return end
		local t = ns.TrackHistory(h)
		t.cd = true
		ns.Changed()
		if ns.Display then ns.Display:Rebuild() end
		Print("Following the cooldown of " .. (h.name or ("spell " .. tostring(h.id))) .. ". A cooldown is not hidden from addons the way an aura is, so this one keeps counting in a fight.")
		if ns.UI and ns.UI.RefreshHistory then ns.UI:RefreshHistory() end
	elseif cmd == "edit" or cmd == "lock" or cmd == "unlock" then
		local on = (cmd == "unlock") or (cmd == "edit" and not ns.db.unlocked)
		if ns.UI and ns.UI.SetEditMode then
			ns.UI:SetEditMode(on)
		else
			ns.db.unlocked = on
			if ns.Display then ns.Display:Rebuild() end
		end
	elseif cmd == "minimap" then
		ns.db.minimapShown = not ns.db.minimapShown
		if ns.UI and ns.UI.UpdateMinimapButton then ns.UI:UpdateMinimapButton() end
		Print("Minimap button " .. (ns.db.minimapShown and "shown." or "hidden."))
	elseif cmd == "import" then
		local g, err = ns.Import(rest)
		if g then Print("Imported " .. ns.GroupName(g) .. ".") else Print(err) end
	elseif cmd == "combatlog" then
		-- For this session only: this client refuses the combat log to addons, and a saved switch
		-- brought the refusal dialog back at every login.
		if registered.COMBAT_LOG_EVENT_UNFILTERED then
			Print("The combat log is already being tried this session. Type /reload to stop.")
		else
			SafeRegister("COMBAT_LOG_EVENT_UNFILTERED")
			ns.combatLogTried = true
			Print("Trying the combat log for this session only. This client normally refuses it to addons with a 'blocked' dialog; /reload puts it back.")
		end
	elseif cmd == "tune" then
		if not (ns.UI and ns.UI.ShowTuner) then
			Print("The tuning panel is not there: this is " .. tostring(ns.VERSION) .. ", and it was added in 1.54.0.")
		else
			local ok, err = pcall(function() return ns.UI:ShowTuner() end)
			if not ok then
				Print("|cffff5050The tuning panel could not be opened:|r " .. tostring(err))
			else
				local f = ns.UI.TunerFrame and ns.UI:TunerFrame()
				if f and f.IsShown and f:IsShown() then
					Print("Tuning panel open. |cffffd000/auraledger tune|r again to close it, or drag it by its title.")
					if f.ClearAllPoints and f.SetPoint and rest == "here" then
						f:ClearAllPoints()
						f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
						Print("Put back in the middle of the screen.")
					end
				else
					Print("Tuning panel closed.")
				end
			end
		end
	elseif cmd == "barplate" then
		local a, b = rest:match("^(%S*)%s*(%S*)$")
		if strlower(a or "") == "even" then
			ns.db.plateTop, ns.db.plateBottom, ns.db.plateEven = nil, nil, true
		elseif strlower(a or "") == "default" then
			ns.db.plateTop, ns.db.plateBottom, ns.db.plateEven = nil, nil, nil
		else
			ns.db.plateEven = nil
			local t, bt = tonumber(a), tonumber(b)
			if t then ns.db.plateTop = t end
			if bt then ns.db.plateBottom = bt end
		end
		ns.MASK_EPOCH = (ns.MASK_EPOCH or 0) + 1
		if ns.Display then ns.Display:Rebuild() end
		Print(("Bar plate reach: %s above, %s below, as shares of the bar's height. |cffffd000/auraledger barplate <above> <below>|r, or |cffffd000even|r to share what was measured."):format(
			ns.db.plateEven and "even" or ("%.3f"):format(tonumber(ns.db.plateTop) or 0.08),
			ns.db.plateEven and "even" or ("%.3f"):format(tonumber(ns.db.plateBottom) or 0.35)))
	elseif cmd == "barfill" then
		local a, b = rest:match("^(%S*)%s*(%S*)$")
		local x, y = tonumber(a), tonumber(b)
		if x then ns.db.fillInsetX = (x ~= 0.22) and x or nil end
		if y then ns.db.fillInsetY = (y ~= 0.06) and y or nil end
		if x or y then
			ns.MASK_EPOCH = (ns.MASK_EPOCH or 0) + 1
			if ns.Display then ns.Display:Rebuild() end
		end
		Print(("Bar fill margin: %.3f sideways, %.3f up and down, each as a share of the bar's height. |cffffd000/auraledger barfill <sideways> <up and down>|r."):format(
			tonumber(ns.db.fillInsetX) or 0.22, tonumber(ns.db.fillInsetY) or 0.06))
	elseif cmd == "barart" then
		local word = strlower(rest or "")
		if word == "measured" or word == "reckoned" then
			ns.db.barArt = (word == "measured") and "measured" or nil
			ns.MASK_EPOCH = ns.MASK_EPOCH + 1
			if ns.Display then ns.Display:Rebuild() end
			Print("Bar art: " .. word .. ".")
		else
			Print("Bar art: " .. ((ns.db.barArt == "measured") and "measured" or "reckoned")
				.. ". |cffffd000reckoned|r places a bar's art in pixels off the donor's height, which is what a border wants; |cffffd000measured|r places it by where it sat against the donor's own bar, which stretches with the bar.")
		end
	elseif cmd == "shadow" then
		local n = tonumber(rest)
		if n then
			ns.db.shadowLayers = (n ~= 2) and n or nil
			ns.MASK_EPOCH = ns.MASK_EPOCH + 1
			if ns.Display then ns.Display:Rebuild() end
			Print(("Shadow: %d layer%s of the art the Cooldown Manager draws round its own icons."):format(n, n == 1 and "" or "s"))
		else
			local cur = tonumber(ns.db.shadowLayers) or 2
			Print(("Shadow: %d layer%s. |cffffd000/auraledger shadow <0-4>|r: 0 none, 1 what the manager itself draws, 2 the default."):format(cur, cur == 1 and "" or "s"))
		end
	elseif cmd == "missing" then
		local word = strlower(rest or "")
		if word == "gray" or word == "grey" or word == "red" then
			ns.db.missingStyle = (word == "red") and "red" or nil
			if ns.Display then ns.Display:Refresh() end
			Print("A missing aura is shown " .. (ns.db.missingStyle == "red" and "in red" or "in gray") .. ".")
		else
			Print("A missing aura is shown " .. (ns.db.missingStyle == "red" and "in red" or "in gray")
				.. ". |cffffd000/auraledger missing gray|r or |cffffd000red|r. An aura about to run out is red either way.")
		end
	elseif cmd == "iconborder" then
		local word = strlower(rest or "")
		local sizeA, sizeB = word:match("^size%s+(%S+)%s*(%S*)$")
		if sizeA then
			local over, shift = tonumber(sizeA), tonumber(sizeB)
			if over then ns.db.frameOver = over end
			if shift then ns.db.frameShift = shift end
			ns.ApplyMaskSettings()
			ns.MASK_EPOCH = ns.MASK_EPOCH + 1
			if ns.Display then ns.Display:Rebuild() end
			Print(("Icon border: out %.3f, up %.3f of the icon."):format(ns.FRAME_OVER, ns.FRAME_SHIFT))
			return
		end
		if word == "" then
			Print(("Icon border: %s, out %.3f, up %.3f."):format(tostring(ns.db.iconBorder or "clean"), ns.FRAME_OVER, ns.FRAME_SHIFT))
			Print("|cffffd000clean|r is a thin dark line, the way an icon is edged everywhere else. |cffffd000client|r draws this client's own frame art, |cffffd000cdm|r copies the Cooldown Manager's overlay, |cffffd000none|r draws nothing. |cffffd000size <out> <up>|r is for the client frame.")
			Print("  in hand: " .. tostring(ns.report["icon frame"] or "not tried yet"))
		elseif word == "clean" or word == "client" or word == "cdm" or word == "none" then
			ns.db.iconBorder = (word ~= "clean") and word or nil
			ns.MASK_EPOCH = ns.MASK_EPOCH + 1
			if ns.Display then ns.Display:Rebuild() end
			Print("Icon border: " .. word .. ". The window follows after a /reload.")
		else
			Print("Icon border: clean, client, cdm or none.")
		end
	elseif cmd == "iconmask" then
		local word = strlower(rest or "")
		if word == "off" or word == "on" then
			ns.db.maskOn = (word == "on") or nil
			ns.MASK_EPOCH = ns.MASK_EPOCH + 1
			local off = (not ns.db.maskOn) and ns.ClearAllMasks() or 0
			if ns.Display then ns.Display:Rebuild() end
			Print("Icon mask: " .. (ns.db.maskOn and "on" or ("off, icons keep their own corners; " .. off .. " taken off what is on screen"))
				.. ". The window follows after a /reload.")
			return
		end
		local a, b = rest:match("^(%S*)%s*(%S*)$")
		local over, shift = tonumber(a), tonumber(b)
		if over then ns.db.maskOver = over end
		if shift then ns.db.maskShift = shift end
		if over or shift then
			ns.MASK_OVER = tonumber(ns.db.maskOver) or 0.26
			ns.MASK_SHIFT = tonumber(ns.db.maskShift) or 0
			ns.MASK_EPOCH = ns.MASK_EPOCH + 1
			local n = ns.RepointMasks()
			Print(("Icon mask: out %.3f, up %.3f. %d mask%s moved; the book follows after a /reload."):format(
				ns.MASK_OVER, ns.MASK_SHIFT, n, n == 1 and "" or "s"))
		else
			Print(("Icon mask: %s, out %.3f, up %.3f."):format(ns.db.maskOn and "on" or "off (this client's mask is the shape of a tab)", ns.MASK_OVER, ns.MASK_SHIFT))
			Print("|cffffd000/auraledger iconmask <out> <up>|r, both as a share of the icon: out is how far past the icon the mask art is drawn, up moves the shape against the icon. |cffffd000/auraledger iconmask off|r leaves icons their own square corners.")
		end
	elseif cmd == "atlases" then
		if ns.UI and ns.UI.PrintAtlases then ns.UI:PrintAtlases() end
	elseif cmd == "item" then
		if ns.Display and ns.Display.ProbeItem then
			ns.LogLine("=== a cooldown manager item, top to bottom")
			ns.Display:ProbeItem(function(line) Print("  " .. line) ns.LogLine(line) end)
		end
	elseif cmd == "icon" then
		if ns.Display and ns.Display.IconReport then
			ns.LogLine("=== icon art")
			ns.Display:IconReport(function(line) Print("  " .. line) ns.LogLine(line) end)
		end
	elseif cmd == "plainbook" then
		ns.db.plainBook = not ns.db.plainBook
		Print("Book background: " .. (ns.db.plainBook and "plain" or "parchment when the client has it") .. ". Type /reload to apply.")
	elseif cmd == "cdread" then
		-- Everything the client says about each cooldown tracker, printed and never tested, and what
		-- the addon remembers about it for a fight where the numbers are hidden.
		local function S(v) if issecretvalue and issecretvalue(v) then return "secret" end return tostring(v) end
		local function Call(fn, ...)
			if not fn then return "n/a" end
			local ok, v = pcall(fn, ...)
			if not ok then return "error" end
			return S(v)
		end
		Print(("cooldowns hidden right now: %s, combat %s, auras hidden %s, last global cooldown %s"):format(
			Call(C_Secrets and C_Secrets.ShouldCooldownsBeSecret), tostring(InCombatLockdown and InCombatLockdown()), tostring(AurasSecret()),
			ns.lastGcdAt and ("%.1fs ago"):format(GetTime() - ns.lastGcdAt) or "none"))
		local any = false
		for _, g in ipairs(ns.profile.groups) do
			for _, t in ipairs(g.trackers) do
				if t.cd and not t.item then
					any = true
					local key = t.id or t.name
					Print(("%s [%s]: secrecy %s, hidden %s, cast secrecy %s"):format(tostring(t.name), tostring(key),
						Call(C_Secrets and C_Secrets.GetSpellCooldownSecrecy, key), Call(C_Secrets and C_Secrets.ShouldSpellCooldownBeSecret, key),
						Call(C_Secrets and C_Secrets.GetSpellCastSecrecy, key)))
					if C_Spell and C_Spell.GetSpellCooldown then
						local ok, info = pcall(C_Spell.GetSpellCooldown, key)
						info = ok and Clean(info) or nil
						if type(info) == "table" then
							Print(("    start %s, length %s, enabled %s, active %s, on GCD %s"):format(S(info.startTime), S(info.duration),
								S(info.isEnabled), S(info.isActive), S(info.isOnGCD)))
						else
							Print("    no reading" .. (ok and "" or " (error)"))
						end
					end
					local m = ns.CooldownMemory and ns.CooldownMemory(t)
					if m then Print("    remembered: " .. m) end
				elseif t.item then
					any = true
					local s1, d1, e1 = ns.ItemCooldownRead(t.item)
					Print(("%s [item %s]: start %s, length %s, enabled %s"):format(tostring(t.name), tostring(t.item), S(s1), S(d1), S(e1)))
				end
			end
		end
		if not any then Print("no cooldown or item trackers") end
	elseif cmd == "cdmrestore" then
		local ok, err = ns.CDM.Restore()
		Print(ok and "The Cooldown Manager is back to what it was before." or ("Not restored: " .. tostring(err)))
	elseif cmd == "cdm2" then
		ns.ProbeCDM(Print)
	elseif cmd == "log" then
		if rest == "clear" then
			if ns.db then ns.db.log = {} ns.db.chat = {} end
			Print("log cleared")
		else
			Print(("log: %d addon lines and %d chat lines kept in the saved variables (written on /reload or logout); /auraledger log clear empties both"):format(
				ns.db and ns.db.log and #ns.db.log or 0, ns.db and ns.db.chat and #ns.db.chat or 0))
		end
	elseif cmd == "api" then
		local doc = APIDocumentation
		if not doc then
			Print("Blizzard's API documentation is not loaded; run any /api command first, then this again")
		else
			local want = strlower(rest or "")
			local found = 0
			for _, t in ipairs(doc.tables or {}) do
				if strlower(t.Name or "") == want then
					found = found + 1
					Print(("%s %s (%s)"):format(t.Type or "table", t.Name, t.System and t.System.Name or "?"))
					for _, f in ipairs(t.Fields or {}) do
						Print(("  %s: %s%s%s%s"):format(f.Name, tostring(f.Type), f.Nilable and " (nilable)" or "", f.EnumValue ~= nil and (" = " .. tostring(f.EnumValue)) or "",
							f.InnerType and (" of " .. tostring(f.InnerType)) or ""))
					end
				end
			end
			for _, f in ipairs(doc.functions or {}) do
				if strlower(f.Name or "") == want or strlower((f.System and f.System.Namespace or "") .. "." .. (f.Name or "")) == want then
					found = found + 1
					Print(("function %s.%s"):format(f.System and f.System.Namespace or "?", f.Name))
					for _, a in ipairs(f.Arguments or {}) do Print(("  arg %s: %s%s%s"):format(a.Name, tostring(a.Type), a.Nilable and " (nilable)" or "", a.Default ~= nil and (" default " .. tostring(a.Default)) or "")) end
					for _, r in ipairs(f.Returns or {}) do Print(("  returns %s: %s%s"):format(r.Name, tostring(r.Type), r.Nilable and " (nilable)" or "")) end
				end
			end
			if found == 0 then Print("nothing documented under that name (try the exact name from /api search)") end
		end
	elseif cmd == "gd" then
		local function S(v) if issecretvalue and issecretvalue(v) then return "secret" end return tostring(v) end
		Print("game-drawn groups (secret: " .. YesNo(AurasSecret()) .. ", attribute drivers " .. YesNo(RegisterAttributeDriver) .. "):")
		local any = false
		for _, g in ipairs(ns.profile.groups) do
			if g.gameDrawn then
				any = true
				local f = ns.Display.FrameFor and ns.Display.FrameFor(g)
				Print(("  %s: %s, macro %s"):format(ns.GroupName(g), "drawn by the game", tostring(ns.Display.CondMacro and ns.Display.CondMacro(g.cond))))
				if f then
					Print(("    frame shown %s, gate %s (driver %s, shown %s, visible %s)"):format(tostring(f:IsShown()), f.gate and "yes" or "no",
						f.gate and tostring(f.gate.alMacro) or "-", f.gate and tostring(f.gate:IsShown()) or "-", f.gate and tostring(f.gate:IsVisible()) or "-"))
					for unit, c in pairs(f.slotC or {}) do
						local okS, shown = pcall(c.IsShown, c)
						local okV, vis = pcall(c.IsVisible, c)
						Print(("    container %s: shown %s, visible %s, driver %s, level %s"):format(unit, okS and S(shown) or "?", okV and S(vis) or "?", tostring(c.alDriven), S(select(2, pcall(c.GetFrameLevel, c)))))
						for key, fr in pairs(c.alSlots) do
							local okF, fs2 = pcall(fr.IsShown, fr)
							Print(("      slot %s: on %s, wanted %s, anchored to cell %s, shown %s"):format(key, tostring(c.alOn and c.alOn[key]), tostring(c.alWant and c.alWant[key]),
								S(fr.alAnchor), okF and S(fs2) or "error"))
						end
					end
					for i, w in ipairs(f.widgets) do
						if w:IsShown() then
							Print(("    cell %d: %s, alpha %.1f"):format(i, w.tracker and (w.tracker.name or "?") or "-", w:GetAlpha()))
						end
					end
				end
			end
		end
		if not any then Print("  none") end
		Print("  report: " .. tostring(ns.report["game-drawn trackers"]) .. " / " .. tostring(ns.report["game-drawn groups"]) .. (ns.report["timer directions"] and (" / directions " .. ns.report["timer directions"]) or ""))
	elseif cmd == "soundclear" then
		Print(("removed %d aura sound registrations from the game; they come back on the next change or reload for trackers that still have a sound set"):format(ns.ClearAllAuraSounds()))
	elseif cmd == "soundtest" then
		local i = 0
		local function step()
			i = i + 1
			local c = ns.SOUND_CHOICES[i]
			if not c then Print("sound test done") return end
			if c[4] then
				local ok, will = pcall(PlaySoundFile, c[4], "Master")
				Print(("  %d %s: file %d -> %s"):format(i, c[1], c[4], ok and tostring(will) or ("error " .. tostring(will))))
			else
				Print(("  %d %s: kit only"):format(i, c[1]))
			end
			if C_Timer and C_Timer.After then C_Timer.After(1.5, step) else step() end
		end
		Print("playing each file sound in turn (1.5 s apart); say which ones you heard:")
		step()
	elseif cmd == "probe" then
		Print("asking by spell right now (secret: " .. YesNo(AurasSecret()) .. "; APIs: BySpellName " .. YesNo(C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName)
			.. ", PlayerBySpellID " .. YesNo(C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) .. "):")
		local n = 0
		for _, g in ipairs(ns.profile.groups) do
			for _, t in ipairs(g.trackers) do
				n = n + 1
				local state, a = ns.ProbeOne(t.unit or "player", t)
				local detail = ""
				if state == "present" and type(a) == "table" then
					local function f(k) local v = a[k] if issecretvalue and issecretvalue(v) then return "secret" end return tostring(v) end
					detail = (" (name %s, duration %s, expires %s, source %s)"):format(f("name"), f("duration"), f("expirationTime"), f("sourceUnit"))
				end
				Print(("  %s on %s: %s%s"):format(t.name or tostring(t.id), t.unit or "player", state, detail))
			end
		end
		if n == 0 then Print("  no trackers") end
		do
			local C = C_UnitAuras
			local function DD(v) if issecretvalue and issecretvalue(v) then return "secret" end if type(v) == "table" then local l = PlainList(v) return l and ("plain list of " .. #l .. (#l > 0 and (" e.g. " .. tostring(l[1])) or "")) or "table (not iterable)" end return type(v) .. ":" .. tostring(v) end
			for _, filter in ipairs({ "HELPFUL", "HARMFUL", "HELPFUL|PLAYER" }) do
				local ok, ids = pcall(C.GetUnitAuraInstanceIDs, "player", filter)
				Print(("  GetUnitAuraInstanceIDs(%s): %s"):format(filter, ok and DD(ids) or ("error " .. tostring(ids))))
				local list = ok and PlainList(ids)
				local first = list and list[1]
				if first then
					local okE, has = pcall(C.DoesAuraHaveExpirationTime, "player", first)
					local okG, guid = pcall(C.GetAuraCasterGUID, "player", first)
					local okR, dur = pcall(C.GetAuraDuration, "player", first)
					local okF, filtered = pcall(C.IsAuraFilteredOutByInstanceID, "player", first, "PLAYER")
					local okI, info = pcall(C.GetAuraDataByAuraInstanceID, "player", first)
					Print(("    instance %s: hasExpiry %s, caster %s, duration object %s, filteredOut(PLAYER) %s, dataByInstance %s"):format(
						tostring(first), okE and DD(has) or "error", okG and DD(guid) or "error", okR and DD(dur) or ("error " .. tostring(dur)), okF and DD(filtered) or "error",
						okI and (type(info) == "table" and ((issecretvalue and issecretvalue(info)) and "secret" or ("table, name " .. DD(info.name) .. ", id " .. DD(info.spellId))) or DD(info)) or ("error " .. tostring(info):sub(1, 60))))
				end
			end
			if C.GetAuraSlots then
				local ok, tok, a, b = pcall(C.GetAuraSlots, "player", "HELPFUL", 40)
				Print("  GetAuraSlots(HELPFUL): " .. (ok and (DD(tok) .. ", " .. DD(a) .. ", " .. DD(b)) or ("error " .. tostring(tok))))
			end
		end
		Print("raw index reads on you, expected to fail with a taint message while secret (GetAuraDuration " .. YesNo(C_UnitAuras and C_UnitAuras.GetAuraDuration) .. "):")
		local function D(v) if issecretvalue and issecretvalue(v) then return "secret" end return tostring(v) end
		for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
			local shownLines = 0
			for i = 1, 40 do
				local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, filter)
				if ok and a == nil then break end
				if shownLines < 8 then
					if not ok then
						Print(("  %s %d: error %s"):format(filter, i, tostring(a)))
					elseif issecretvalue and issecretvalue(a) then
						Print(("  %s %d: whole table secret"):format(filter, i))
					else
						Print(("  %s %d: name %s, id %s, icon %s, instance %s, duration %s, expires %s, stacks %s, harmful %s, source %s, fromMe %s"):format(
							filter, i, D(a.name), D(a.spellId), D(a.icon), D(a.auraInstanceID), D(a.duration), D(a.expirationTime), D(a.applications), D(a.isHarmful), D(a.sourceUnit), D(a.isFromPlayerOrPlayerPet)))
					end
					shownLines = shownLines + 1
				end
				if not ok and i > 3 then break end
			end
		end
	elseif cmd == "debug" then
		Debug()
	else
		Help()
	end
end

function AuraLedger_OnAddonCompartmentClick()
	if not loaded then Startup() end
	if ns.UI and ns.UI.Toggle then ns.UI:Toggle() end
end
