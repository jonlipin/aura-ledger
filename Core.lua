-- Aura Ledger core: saved data, the aura reader, the history ledger, show conditions, slash commands.
--
-- This client hides aura data from addons while "addon restrictions" are active (combat, encounters,
-- some maps): values come back secret, and asking for a secret aura can be a Lua error. So every read
-- goes through pcall and Clean(), and while auras are unreadable the last known state is carried
-- forward (timers keep counting, removals still arrive by aura instance id, and the combat log is
-- used when the client delivers it). Anything carried or estimated is flagged so the display can
-- mark it. "/auraledger debug" reports what actually worked.

local ADDON, ns = ...
ns.VERSION = "1.13.0"
ns.report = {}
ns.stats = { scans = 0, partial = 0, blocked = 0, cleu = 0, cleuUsed = 0, estimated = 0, removedById = 0, casts = 0, castsUsed = 0 }
ns.auras = {}
ns.env = {}
ns.QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

local MAX_INDEX = 80
local HISTORY_CAP = 1500

local strlower, floor, max, min = string.lower, math.floor, math.max, math.min

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffAura Ledger:|r " .. tostring(msg))
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
	if ns.Display and ns.Display.Rebuild then ns.Display:Rebuild() end
	if ns.UI and ns.UI.RefreshLayout then ns.UI:RefreshLayout() end
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
	if e.unit == "target" then h.onTarget = true else h.onYou = true end
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
		kind = h.kind or "any",
		matchId = (idOnly or h.byId) and true or false,
		show = "active",
		mine = false,
		cond = {},
	}
end

-- The look of a group, copied when a tracker is pulled out into a group of its own.
ns.GROUP_STYLE_KEYS = { "style", "size", "barW", "barH", "spacing", "perRow", "scale", "alpha", "timers", "names", "grow", "border", "background", "iconFrame", "watch" }

function ns.NewGroupLike(g, x, y)
	local ng = ns.NewGroup(x or ((g.x or 500) + 30), y or ((g.y or 400) - 60))
	for _, key in ipairs(ns.GROUP_STYLE_KEYS) do ng[key] = g[key] end
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
	table.remove(g.trackers, ti)
	if ns.selected and ns.selected.tracker == t then ns.selected = { group = g } end
	if #g.trackers == 0 then return ns.DeleteGroup(g) end
	ns.Changed()
end

-- Move a tracker into group "to" at index (nil = end). Empty source groups disappear.
function ns.MoveTracker(t, to, index)
	local from, ti = ns.FindGroupOf(t)
	if from then
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
ns.GROUPS = { { "solo", "Solo" }, { "party", "Party" }, { "raid", "Raid" } }
ns.PLACES = { { "world", "Open world" }, { "dungeon", "Dungeon" }, { "raid", "Raid instance" }, { "bg", "Battleground" }, { "arena", "Arena" } }
ns.TOGGLES = {
	{ "combat", "Combat", "In combat", "Out of combat" },
	{ "resting", "Resting", "Resting", "Not resting" },
	{ "mounted", "Mounted", "Mounted", "On foot" },
	{ "target", "Target", "Have a target", "No target" },
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
	return table.concat({ tostring(e.combat), tostring(e.group), tostring(e.place), tostring(e.resting),
		tostring(e.mounted), tostring(e.target), tostring(e.alive) }, "|")
end

function ns.UpdateEnv()
	local e = ns.env
	local before = EnvSignature(e)
	e.combat = ns.combatFlag and true or false
	e.group = Bool(IsInRaid) and "raid" or (Bool(IsInGroup) and "party" or "solo")
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
	if before ~= EnvSignature(e) and ns.Display and ns.Display.Refresh then ns.Display:Refresh() end
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
	if c.group and next(c.group) and not c.group[e.group] then return false end
	if c.place and next(c.place) and not c.place[e.place] then return false end
	if c.class and next(c.class) and not (e.class and c.class[e.class]) then return false end
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
	for _, spec in ipairs({ { "group", ns.GROUPS }, { "place", ns.PLACES } }) do
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
	return table.concat(parts, ", ")
end

-- ------------------------------------------------------------------
-- Aura reader: your own auras and your target's, kept in separate tables with their own indexes.
-- ------------------------------------------------------------------
ns.UNITS = { "player", "target" }
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
function ns.Find(t)
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
		-- "Cast by me" is unknown (nil) for an aura recognised from a frame icon; that passes.
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

-- Reads one filter on one unit into "out". Returns how many auras could not be read.
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

-- One unit's scan: read what can be read, carry the rest forward. Returns the new table and whether
-- anything was unreadable.
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
	local fresh, restricted, changed = ScanUnit("player", ns.auras, firstScan)
	ns.auras = fresh
	local historyChanged = changed
	local hasTarget = UnitExists and Clean(UnitExists("target")) and true or false
	if hasTarget then
		local tfresh, trestricted, tchanged = ScanUnit("target", ns.targetAuras, false)
		ns.targetAuras = tfresh
		restricted = restricted or trestricted
		historyChanged = historyChanged or tchanged
	else
		ns.targetAuras = {}
	end
	firstScan = false
	ns.restricted = restricted
	Reindex()
	if ns.Display and ns.Display.Refresh then ns.Display:Refresh() end
	if historyChanged and ns.UI and ns.UI.RefreshHistory then ns.UI:RefreshHistory() end
end

-- UNIT_AURA payload: removals and refreshes arrive by instance id even while contents are secret.
-- The lists inside the payload can themselves be secret in combat: they look like tables to
-- type() but ipairs refuses them. Returns a plain array or nil.
local function PlainList(v)
	v = Clean(v)
	if type(v) ~= "table" then return nil end
	local ok, out = pcall(function()
		local list = {}
		for _, id in ipairs(v) do list[#list + 1] = Clean(id) end
		return list
	end)
	return ok and out or nil
end

-- Shape of the UNIT_AURA payloads seen while restricted, for the debug report.
local payloadStats = { events = 0, plainRemoved = 0, secretRemoved = 0, plainUpdated = 0, secretUpdated = 0, plainAdded = 0, secretAdded = 0, full = 0, sample = nil }
ns.payloadStats = payloadStats

local function Describe(v)
	if v == nil then return "nil" end
	if issecretvalue and issecretvalue(v) then return "secret" end
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
		if v == nil then return end
		if PlainList(v) then payloadStats[plainKey] = payloadStats[plainKey] + 1 else payloadStats[secretKey] = payloadStats[secretKey] + 1 end
	end
	tally(info.removedAuraInstanceIDs, "plainRemoved", "secretRemoved")
	tally(info.updatedAuraInstanceIDs, "plainUpdated", "secretUpdated")
	tally(info.addedAuras, "plainAdded", "secretAdded")
	if Clean(info.isFullUpdate) then payloadStats.full = payloadStats.full + 1 end
	if not payloadStats.sample or info.removedAuraInstanceIDs ~= nil then
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
-- The default buff and debuff frames in combat. Aura data is secret then, but Blizzard's own
-- frames still draw, and their icon textures may be readable. While restricted, the icons they
-- show are compared with what we carry: a carried aura whose icon is no longer shown is dropped
-- (so "missing" trackers fire mid-fight), and an icon that appears with no aura behind it is
-- looked up in the ledger and shown as an estimated aura. The debug report says whether this works.
-- ------------------------------------------------------------------
local frameIconStats = { reads = 0, readable = false, proven = false, removed = 0, added = 0, sample = {}, drops = {}, shown = 0, unreadable = 0 }
ns.frameIconStats = frameIconStats

-- Aura data gives icons as file ids; a frame's texture may answer with the id or with a path.
-- Both are reduced to one key so they compare.
local function IconKey(v)
	v = Clean(v)
	if type(v) == "number" then return v end
	if type(v) == "string" then
		if GetFileIDFromPath then
			local ok, id = pcall(GetFileIDFromPath, v)
			if ok and type(id) == "number" and id > 0 then return id end
		end
		local n = tonumber(v)
		if n then return n end
		return strlower((v:gsub("\\", "/")))
	end
	return nil
end
ns.IconKey = IconKey

local function FrameIconRegion(b)
	return b.Icon or b.icon or (b.GetName and b:GetName() and _G[b:GetName() .. "Icon"])
end

local function CollectFrameIcons(frame, prefix, kind, into)
	local any = false
	local buttons = frame and type(frame.auraFrames) == "table" and frame.auraFrames
	if buttons then
		for _, b in pairs(buttons) do
			if type(b) == "table" and b.IsShown and b:IsShown() then
				any = true
				local tex = FrameIconRegion(b)
				local ok, raw = pcall(function() return tex and tex:GetTexture() end)
				local file = ok and IconKey(raw) or nil
				if #frameIconStats.sample < 12 then frameIconStats.sample[#frameIconStats.sample + 1] = ("%s %s->%s"):format(kind, ok and ((issecretvalue and issecretvalue(raw)) and "secret" or (type(raw) .. ":" .. tostring(raw))) or "error", tostring(file)) end
				frameIconStats.shown = frameIconStats.shown + 1
				if file then into[file] = kind else frameIconStats.unreadable = frameIconStats.unreadable + 1 end
			end
		end
	elseif prefix then
		for i = 1, 40 do
			local b = _G[prefix .. i]
			if not b then break end
			if b:IsShown() then
				any = true
				local tex = _G[prefix .. i .. "Icon"] or b.Icon
				local ok, raw = pcall(function() return tex and tex:GetTexture() end)
				local file = ok and IconKey(raw) or nil
				if #frameIconStats.sample < 12 then frameIconStats.sample[#frameIconStats.sample + 1] = ("%s %s->%s"):format(kind, ok and ((issecretvalue and issecretvalue(raw)) and "secret" or (type(raw) .. ":" .. tostring(raw))) or "error", tostring(file)) end
				frameIconStats.shown = frameIconStats.shown + 1
				if file then into[file] = kind else frameIconStats.unreadable = frameIconStats.unreadable + 1 end
			end
		end
	end
	return any
end

-- Returns true when something changed.
local function ReconcileWithFrames()
	local shown = {}
	frameIconStats.reads = frameIconStats.reads + 1
	frameIconStats.sample, frameIconStats.shown, frameIconStats.unreadable = {}, 0, 0
	CollectFrameIcons(BuffFrame, "BuffButton", "buff", shown)
	CollectFrameIcons(DebuffFrame, "DebuffButton", "debuff", shown)
	-- Only a read where every shown icon could be read says anything. Once one such read has
	-- happened, an empty frame means no auras.
	frameIconStats.readable = frameIconStats.shown > 0 and frameIconStats.unreadable == 0
	if frameIconStats.readable then frameIconStats.proven = true end
	if frameIconStats.unreadable > 0 or not frameIconStats.proven then return false end
	local changed = false
	local now = GetTime()
	local auras = ns.auras
	-- Carried auras whose icon is gone from the frames are gone.
	for key, e in pairs(auras) do
		local ik = e.icon and IconKey(e.icon)
		if (e.stale or e.estimated) and not e.probed and ik and not shown[ik] then
			auras[key] = nil
			frameIconStats.removed = frameIconStats.removed + 1
			if #frameIconStats.drops < 8 then
				local list = {}
				for f in pairs(shown) do list[#list + 1] = tostring(f) end
				frameIconStats.drops[#frameIconStats.drops + 1] = ("%s (icon %s) not among frame icons {%s}"):format(e.name or key, tostring(ik), table.concat(list, ","))
			end
			changed = true
		end
	end
	-- Icons shown with nothing behind them: your trackers, the ledger and the pre-built book know what
	-- they are (in that order, so what you track is recognised the first time it lands).
	local have = {}
	for _, e in pairs(auras) do if e.icon then have[IconKey(e.icon)] = true end end
	for file, kind in pairs(shown) do
		if not have[file] then
			local best
			for _, g in ipairs(ns.profile.groups) do
				for _, t in ipairs(g.trackers) do
					if t.icon and IconKey(t.icon) == file and t.name and (t.unit or "player") == "player" and (t.kind == kind or t.kind == "any" or not t.kind) then
						best = { name = t.name, id = t.id, duration = 0 }
						local h = ns.db.history[kind .. ":" .. strlower(t.name)]
						if h and h.duration then best.duration = h.duration end
					end
				end
			end
			if not best then
				for _, h in pairs(ns.db.history) do
					if h.icon and IconKey(h.icon) == file and h.name and (h.kind == kind or h.kind == "any") then
						if not best or (h.last or 0) > (best.last or 0) then best = h end
					end
				end
			end
			if not best and ns.BookPages then
				for _, list in pairs(ns.BookPages()) do
					for _, item in ipairs(list) do
						if item.icon and IconKey(item.icon) == file and (item.kind == kind or item.kind == "any") then best = { name = item.name, id = item.id, duration = 0 } end
					end
				end
			end
			if best then
				local duration = best.duration or 0
				local key = "f:" .. kind .. ":" .. tostring(best.id or best.name)
				auras[key] = {
					key = key, name = best.name, id = best.id, icon = file, count = 0,
					duration = duration, expires = duration > 0 and (now + duration) or 0, kind = kind, unit = "player",
					mine = nil, synth = true, estimated = true, stale = true, -- caster unknown
				}
				frameIconStats.added = frameIconStats.added + 1
				changed = true
			end
		end
	end
	return changed
end
ns.ReconcileWithFrames = ReconcileWithFrames
ns.CollectFrameIcons = CollectFrameIcons

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

local function HandleCast(unit, spellId)
	if unit ~= "player" and unit ~= "pet" then return end
	spellId = Clean(spellId)
	if type(spellId) ~= "number" then return end
	ns.stats.casts = ns.stats.casts + 1
	if not (ns.restricted or AurasSecret()) then return end -- the real aura event is on its way
	local name = SpellName(spellId)
	if not name then return end
	local lname = strlower(name)
	local now = GetTime()
	local used = false
	for _, kind in ipairs({ "buff", "debuff" }) do
		local h = ns.db.history[kind .. ":" .. lname]
		local unitTo = kind == "buff" and "player" or "target"
		if h and (unitTo == "player" or (UnitExists and Clean(UnitExists("target")))) then
			local auras = AuraTable(unitTo)
			local existing
			for _, e in pairs(auras) do
				if e.kind == kind and e.name and strlower(e.name) == lname then existing = e break end
			end
			local duration = h.duration or 0
			if existing then
				if duration > 0 then existing.duration, existing.expires = duration, now + duration end
				existing.estimated, existing.stale, existing.probed = true, true, true
			else
				local key = "c:" .. unitTo .. ":" .. lname
				auras[key] = { key = key, name = h.name or name, id = spellId, icon = h.icon, count = 0, duration = duration,
					expires = duration > 0 and (now + duration) or 0, kind = kind, unit = unitTo, mine = true,
					synth = true, estimated = true, stale = true, probed = true }
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

-- ------------------------------------------------------------------
-- The Cooldown Manager's buff viewers. Blizzard shows an item there only while that tracked buff is
-- on you, and neither the item's shown state nor its cooldown id is hidden in combat. So while auras
-- are secret, a shown item means the buff is present and a hidden item means it is gone, for every
-- buff the Cooldown Manager tracks. Anything that answers as secret or missing changes nothing.
-- ------------------------------------------------------------------
local viewerStats = { reads = 0, items = 0, plain = 0, secret = 0, present = 0, absent = 0, sample = nil }
ns.viewerStats = viewerStats
local VIEWERS = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }

local function ItemCooldownID(child)
	local cid = Clean(child.cooldownID)
	if type(cid) ~= "number" and child.GetCooldownID then
		local ok, v = pcall(child.GetCooldownID, child)
		if ok then cid = Clean(v) end
	end
	return type(cid) == "number" and cid or nil
end

-- One pass over the viewers: name (lower) -> shown or hidden. Shown wins when ranks repeat.
-- Returns the table, how many items had a plain answer, and a sample line for the report.
local function ReadViewers(collect)
	local C = C_CooldownViewer
	if not (C and C.GetCooldownViewerCooldownInfo) then return nil end
	local state, plain, secret, items = {}, 0, 0, 0
	local lines = collect and {} or nil
	for _, vname in ipairs(VIEWERS) do
		local v = _G[vname]
		if v and v.GetChildren then
			local okV, vShown = pcall(v.IsShown, v)
			if okV and Clean(vShown) then
				for _, child in ipairs({ v:GetChildren() }) do
					local cid = ItemCooldownID(child)
					if cid then
						items = items + 1
						local okI, info = pcall(C.GetCooldownViewerCooldownInfo, cid)
						local sid = okI and type(info) == "table" and not (issecretvalue and issecretvalue(info)) and Clean(info.spellID) or nil
						local name = sid and SpellName(sid) or nil
						local okS, shown = pcall(child.IsShown, child)
						local hidden = not okS or (issecretvalue and issecretvalue(shown))
						if lines then
							lines[#lines + 1] = ("%s #%s %s: shown %s, instance %s"):format(vname:gsub("CooldownViewer", ""), tostring(cid), name or "?",
								okS and ((issecretvalue and issecretvalue(shown)) and "secret" or tostring(shown)) or "error",
								okI and type(info) == "table" and ((issecretvalue and issecretvalue(info.auraInstanceID)) and "secret" or tostring(info.auraInstanceID)) or "?")
						end
						if name and not hidden then
							plain = plain + 1
							local l = strlower(name)
							if shown then state[l] = true elseif state[l] == nil then state[l] = false end
						elseif name then
							secret = secret + 1
						end
					end
				end
			end
		end
	end
	return state, plain, secret, items, lines
end
ns.ReadViewers = ReadViewers

-- Returns true when something changed.
local function ReconcileWithViewers()
	local state, plain, secret, items = ReadViewers(false)
	if not state then return false end
	viewerStats.reads = viewerStats.reads + 1
	viewerStats.items, viewerStats.plain, viewerStats.secret = items, plain, secret
	if plain == 0 then return false end
	local now = GetTime()
	local auras = ns.auras
	local changed = false
	for l, shown in pairs(state) do
		local existing
		for _, e in pairs(auras) do
			if e.kind == "buff" and e.name and strlower(e.name) == l then existing = e break end
		end
		if shown and not existing then
			local h = ns.db.history["buff:" .. l]
			if h then
				local duration = h.duration or 0
				local key = "v:player:" .. l
				auras[key] = { key = key, name = h.name or l, id = h.id, icon = h.icon, count = 0, duration = duration,
					expires = duration > 0 and (now + duration) or 0, kind = "buff", unit = "player",
					synth = true, estimated = true, stale = true, probed = true }
				viewerStats.present = viewerStats.present + 1
				changed = true
			end
		elseif not shown and existing and (existing.stale or existing.estimated) then
			auras[existing.key] = nil
			viewerStats.absent = viewerStats.absent + 1
			changed = true
		end
	end
	if changed then Reindex() end
	return changed
end
ns.ReconcileWithViewers = ReconcileWithViewers

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
-- Alert sounds: Blizzard sound kit entries, looked up by name first, numeric id as fallback.
-- ------------------------------------------------------------------
ns.SOUND_CHOICES = {
	{ "Mystic chime",   "TUTORIAL_POPUP",         7355 },
	{ "Gem clink",      "PUT_DOWN_GEMS",          1221 },
	{ "Soft bells",     "ALARM_CLOCK_WARNING_3",  12889 },
	{ "Whisper toast",  "UI_BNET_TOAST",          18019 },
	{ "Quest chime",    "IG_QUEST_LIST_COMPLETE", 878 },
	{ "Auction gong",   "AUCTION_WINDOW_OPEN",    5274 },
	{ "Map ping",       "MAP_PING",               3175 },
	{ "Raid warning",   "RAID_WARNING",           8959 },
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
-- Events and the driver
-- ------------------------------------------------------------------
local events = CreateFrame("Frame")
local registered = {}
local function SafeRegister(event)
	local ok = pcall(events.RegisterEvent, events, event)
	registered[event] = ok
	return ok
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
	ns.playerGUID = UnitGUID and UnitGUID("player")
	ns.targetGUID = UnitGUID and Clean(UnitGUID("target")) or nil
	ns.combatFlag = (InCombatLockdown and InCombatLockdown()) and true or false
	ns.UpdateEnv()
	if ns.Display and ns.Display.Init then ns.Display:Init() end
	if ns.UI and ns.UI.Init then ns.UI:Init() end
	ns.dirty = true
	if ns.db.combatLog and not registered.COMBAT_LOG_EVENT_UNFILTERED then SafeRegister("COMBAT_LOG_EVENT_UNFILTERED") end
end

events:SetScript("OnEvent", function(_, event, a1, a2, a3)
	if event == "ADDON_LOADED" then
		if a1 == ADDON then ns.InitDB() end
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
		HandleCast(a1, a3)
	elseif event == "PLAYER_TARGET_CHANGED" then
		ns.targetGUID = UnitGUID and Clean(UnitGUID("target")) or nil
		ns.targetAuras = {}
		Reindex()
		ns.dirty = true
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
	elseif event == "PLAYER_ENTERING_WORLD" then
		ns.playerGUID = UnitGUID and UnitGUID("player") or ns.playerGUID
		ns.UpdateEnv()
		ns.dirty = true
	elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
		ns.dirty = true
		if C_Timer and C_Timer.After then C_Timer.After(0.5, function() ns.dirty = true end) end
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
for _, ev in ipairs({ "UNIT_AURA", "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD",
	"ADDON_RESTRICTION_STATE_CHANGED" }) do
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
	tickAcc = tickAcc + elapsed
	if tickAcc >= 0.1 then
		tickAcc = 0
		if ns.Display and ns.Display.Tick then ns.Display:Tick(now) end
	end
	slowAcc = slowAcc + elapsed
	if slowAcc >= 0.5 then
		slowAcc = 0
		ns.UpdateEnv()
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
		if ns.restricted and ReconcileWithFrames() then ns.dirty = true end
		if ns.restricted and ReconcileWithViewers() then ns.dirty = true end
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

local TRACKER_KEYS = { "name", "id", "icon", "kind", "matchId", "show", "mine", "label", "unit", "warn", "cond", "snd" }

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
		if type(src) ~= "table" or (not src.name and not src.id) then return nil end
		local t = ns.NewTracker({ name = src.name, id = src.id, icon = src.icon, kind = src.kind or "any" })
		t.matchId = src.matchId and true or false
		t.show = (src.show == "missing" or src.show == "always") and src.show or "active"
		t.mine = src.mine and true or false
		t.label = type(src.label) == "string" and src.label or nil
		t.unit = src.unit == "target" and "target" or nil
		t.warn = tonumber(src.warn) or nil
		t.cond = type(src.cond) == "table" and src.cond or {}
		t.snd = type(src.snd) == "table" and src.snd or nil
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
-- Slash commands
-- ------------------------------------------------------------------
local function Help()
	Print("v" .. ns.VERSION .. " commands:")
	Print("  /auraledger - open or close the window")
	Print("  /auraledger add <spell name or ID> - add an aura and start tracking it")
	Print("  /auraledger import <string> - import a tracker or group from an export string")
	Print("  /auraledger unlock | lock - move trackers without the window open")
	Print("  /auraledger minimap - show or hide the minimap button")
	Print("  /auraledger atlases - list the art names on the client's spellbook (for bug reports)")
	Print("  /auraledger plainbook - switch the book between parchment and a plain dark page")
	Print("  /auraledger debug - what this client let the addon read")
end

local function YesNo(v) return v and "|cff40ff40yes|r" or "|cffff5050no|r" end

local function Debug()
	Print("v" .. ns.VERSION .. " debug for " .. tostring(ns.charKey))
	Print("  APIs: GetAuraDataByIndex " .. YesNo(C_UnitAuras and C_UnitAuras.GetAuraDataByIndex)
		.. ", ByInstanceID " .. YesNo(C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID)
		.. ", UnitAura " .. YesNo(UnitAura) .. ", issecretvalue " .. YesNo(issecretvalue))
	Print("  C_Secrets: auras " .. YesNo(C_Secrets and C_Secrets.ShouldAurasBeSecret)
		.. ", index " .. YesNo(C_Secrets and C_Secrets.ShouldUnitAuraIndexBeSecret)
		.. ", instance " .. YesNo(C_Secrets and C_Secrets.ShouldUnitAuraInstanceBeSecret)
		.. "; secret right now: " .. YesNo(AurasSecret()) .. ", last scan partial: " .. YesNo(ns.restricted))
	local s = ns.stats
	Print(("  scans %d (partial %d, blocked %d), removals by id %d, estimated refreshes %d"):format(
		s.scans, s.partial, s.blocked, s.removedById, s.estimated))
	Print(("  combat log: %s, aura events %d, used while restricted %d"):format(
		registered.COMBAT_LOG_EVENT_UNFILTERED and "registered" or "not registered (forbidden on this client; /auraledger combatlog to try)", s.cleu, s.cleuUsed))
	local fi = ns.frameIconStats
	Print(("  buff frame icons while restricted: readable %s, reads %d, carried auras dropped %d, auras recognised from icons %d"):format(
		YesNo(fi.readable), fi.reads, fi.removed, fi.added))
	Print(("    last read: %d shown, %d unreadable, trusted before: %s"):format(fi.shown, fi.unreadable, YesNo(fi.proven)))
	if #fi.sample > 0 then Print("    frame icons seen: " .. table.concat(fi.sample, "; ")) end
	Print(("  your casts: %d seen, %d turned into auras while restricted (spell cast events %s)"):format(
		s.casts, s.castsUsed, registered.UNIT_SPELLCAST_SUCCEEDED and "registered" or "not registered"))
	local vs = ns.viewerStats
	Print(("  Cooldown Manager buff viewers while restricted: reads %d, items %d (plain %d, secret %d), buffs seen present %d, seen gone %d"):format(
		vs.reads, vs.items, vs.plain, vs.secret, vs.present, vs.absent))
	local p = ns.payloadStats
	Print(("  aura events while restricted: %d; removed lists plain %d / secret %d, updated plain %d / secret %d, added plain %d / secret %d, full updates %d"):format(
		p.events, p.plainRemoved, p.secretRemoved, p.plainUpdated, p.secretUpdated, p.plainAdded, p.secretAdded, p.full))
	if p.sample then Print("    last payload: " .. p.sample) end
	for _, d in ipairs(fi.drops) do Print("    dropped: " .. d) end
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
	if ns.BookStats then
		local total, exact, iconOnly, unknown = ns.BookStats()
		Print(("  pre-built book: %d auras, %d resolved by ID, %d icon only (client name differs), %d unknown to this client"):format(total, exact, iconOnly, unknown))
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
	if cmd == "" then
		if ns.UI and ns.UI.Toggle then ns.UI:Toggle() end
	elseif cmd == "add" then
		local h, err = ns.AddManual(rest)
		if not h then Print(err) return end
		ns.TrackHistory(h)
		Print("Tracking " .. (h.name or ("spell " .. tostring(h.id))) .. ". Open /auraledger to move it or change how it shows.")
		if ns.UI and ns.UI.RefreshHistory then ns.UI:RefreshHistory() end
	elseif cmd == "lock" or cmd == "unlock" then
		ns.db.unlocked = (cmd == "unlock")
		if ns.Display then ns.Display:Rebuild() end
		if ns.UI and ns.UI.SyncToolbar then ns.UI:SyncToolbar() end
		Print(ns.db.unlocked and "Trackers unlocked: drag them where you want them." or "Trackers locked.")
	elseif cmd == "minimap" then
		ns.db.minimapShown = not ns.db.minimapShown
		if ns.UI and ns.UI.UpdateMinimapButton then ns.UI:UpdateMinimapButton() end
		Print("Minimap button " .. (ns.db.minimapShown and "shown." or "hidden."))
	elseif cmd == "import" then
		local g, err = ns.Import(rest)
		if g then Print("Imported " .. ns.GroupName(g) .. ".") else Print(err) end
	elseif cmd == "combatlog" then
		ns.db.combatLog = not ns.db.combatLog
		if ns.db.combatLog and not registered.COMBAT_LOG_EVENT_UNFILTERED then SafeRegister("COMBAT_LOG_EVENT_UNFILTERED") end
		Print("Combat log source " .. (ns.db.combatLog and "on (if the client shows the blocked dialog, turn it off again)." or "off. Type /reload to finish turning it off."))
	elseif cmd == "atlases" then
		if ns.UI and ns.UI.PrintAtlases then ns.UI:PrintAtlases() end
	elseif cmd == "plainbook" then
		ns.db.plainBook = not ns.db.plainBook
		Print("Book background: " .. (ns.db.plainBook and "plain" or "parchment when the client has it") .. ". Type /reload to apply.")
	elseif cmd == "frames" then
		local shown = {}
		ns.frameIconStats.sample, ns.frameIconStats.shown, ns.frameIconStats.unreadable = {}, 0, 0
		ns.CollectFrameIcons(BuffFrame, "BuffButton", "buff", shown)
		ns.CollectFrameIcons(DebuffFrame, "DebuffButton", "debuff", shown)
		Print("frame icons right now (secret: " .. YesNo(AurasSecret()) .. "):")
		for _, line in ipairs(ns.frameIconStats.sample) do Print("  " .. line) end
		if #ns.frameIconStats.sample == 0 then Print("  none (BuffFrame " .. YesNo(BuffFrame) .. ", auraFrames " .. YesNo(BuffFrame and BuffFrame.auraFrames) .. ", BuffButton1 " .. YesNo(_G.BuffButton1) .. ")") end
		Print("auras carried right now:")
		for _, e in pairs(ns.auras) do
			local ik = e.icon and ns.IconKey(e.icon)
			Print(("  %s icon %s -> %s"):format(e.name or "?", tostring(e.icon), shown[ik] and "on the frame" or "NOT on the frame"))
		end
	elseif cmd == "cdm" then
		local C = C_CooldownViewer
		Print("Cooldown Manager data (secret: " .. YesNo(AurasSecret()) .. "; API " .. YesNo(C) .. (C and (", available " .. YesNo(C.IsCooldownViewerAvailable and select(2, pcall(C.IsCooldownViewerAvailable)))) or "") .. "):")
		local state, plain, secret, items, lines = ns.ReadViewers(true)
		if lines then
			Print(("  viewer items: %d (plain %d, secret %d)"):format(items, plain, secret))
			for _, line in ipairs(lines) do Print("    " .. line) end
			for _, vname in ipairs({ "BuffIconCooldownViewer", "BuffBarCooldownViewer" }) do
				local v = _G[vname]
				Print(("    %s: %s"):format(vname, v and ("exists, shown " .. tostring(select(2, pcall(v.IsShown, v)))) or "missing"))
			end
		end
		local wanted = {}
		for _, g in ipairs(ns.profile.groups) do for _, t in ipairs(g.trackers) do if t.name then wanted[strlower(t.name)] = true end end end
		if C and C.GetCooldownViewerCategorySet and C.GetCooldownViewerCooldownInfo then
			local cats = (Enum and Enum.CooldownViewerCategory) or { Essential = 0, Utility = 1, TrackedBuff = 2, TrackedBar = 3 }
			local names = {}
			for k, v in pairs(cats) do if type(v) == "number" then names[v] = k end end
			for cat = 0, 3 do
				local ok, ids = pcall(C.GetCooldownViewerCategorySet, cat, true)
				local list = ok and PlainList(ids)
				Print(("  %s: %s"):format(names[cat] or tostring(cat), ok and (list and (#list .. " entries") or ("set is " .. Describe(ids))) or "error"))
				for _, id in ipairs(list or {}) do
					local ok2, info = pcall(C.GetCooldownViewerCooldownInfo, id)
					if ok2 and type(info) == "table" and not (issecretvalue and issecretvalue(info)) then
						local sid = Clean(info.spellID)
						local name = sid and ns.SpellName and ns.SpellName(sid) or "?"
						if wanted[strlower(name)] then
							Print(("    #%s spell %s %s: hasAura %s, auraInstanceID %s, selfAura %s, isKnown %s, auraSpellID %s"):format(
								tostring(id), tostring(sid), name, Describe(info.hasAura), Describe(info.auraInstanceID), Describe(info.selfAura), Describe(info.isKnown), Describe(info.auraSpellID)))
						end
					else
						Print(("    #%s: %s"):format(tostring(id), ok2 and Describe(info) or "error"))
					end
				end
			end
		end
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
