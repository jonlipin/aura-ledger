-- Aura Ledger core: saved data, the aura reader, the history ledger, show conditions, slash commands.
--
-- This client hides aura data from addons while "addon restrictions" are active (combat, encounters,
-- some maps): values come back secret, and asking for a secret aura can be a Lua error. So every read
-- goes through pcall and Clean(), and while auras are unreadable the last known state is carried
-- forward (timers keep counting, removals still arrive by aura instance id, and the combat log is
-- used when the client delivers it). Anything carried or estimated is flagged so the display can
-- mark it. "/auraledger debug" reports what actually worked.

local ADDON, ns = ...
ns.VERSION = "1.27.0"
ns.report = {}
ns.stats = { scans = 0, partial = 0, blocked = 0, cleu = 0, cleuUsed = 0, estimated = 0, removedById = 0, casts = 0, castsUsed = 0 }
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
-- Every line that reaches the main chat frame, from anyone, colour codes stripped.
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
	local kind = h.kind or "any"
	return {
		uid = ns.NewUid(),
		name = h.name, id = h.id, icon = h.icon,
		kind = kind,
		matchId = (idOnly or h.byId) and true or false,
		show = "active",
		mine = false,
		-- A debuff can only be followed on a target on this client; start it there.
		unit = (kind == "debuff") and "target" or nil,
		cond = {},
	}
end

-- The look of a group, copied when a tracker is pulled out into a group of its own.
ns.GROUP_STYLE_KEYS = { "style", "size", "barW", "barH", "spacing", "perRow", "scale", "alpha", "timers", "names", "grow", "border", "background", "iconFrame", "watch", "live", "liveOnlyMine", "gameDrawn" }

-- What a game-drawn group can show: Blizzard's aura filters for the player.
-- What the game can fill a group with. Only the two worth having are offered: the rest repeated
-- what the default buff, debuff and target frames already show.
ns.LIVE_FILTERS = {
	{ "target:HARMFUL|PLAYER",  "My debuffs on my target" },
	{ "target:HARMFUL",         "Every debuff on my target" },
}

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

-- One unit's scan: read what can be read, carry the rest forward. Returns the new table and whether
-- anything was unreadable.
-- ------------------------------------------------------------------
-- Instance ids while secret. The aura list cannot be read, but GetUnitAuraInstanceIDs may still
-- say which instances are on the unit. That is enough for presence: a carried aura whose instance
-- is gone has ended, a spell you just cast is the newest instance that appeared, and instances
-- nobody claims are kept as unknown entries so a later cast can still bind to them.
-- ------------------------------------------------------------------
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

local shadowStats = { calls = 0, plain = 0, secret = 0, errors = 0, reads = 0, removed = 0, bound = 0, unknown = 0 }
ns.shadowStats = shadowStats

local function InstanceList(unit, filter, kind, into)
	local C = C_UnitAuras
	if not (C and C.GetUnitAuraInstanceIDs) then return false end
	shadowStats.calls = shadowStats.calls + 1
	local ok, ids = pcall(C.GetUnitAuraInstanceIDs, unit, filter)
	if not ok then shadowStats.errors = shadowStats.errors + 1 return false end
	local list = PlainList(ids)
	if not list then
		if ids ~= nil then shadowStats.secret = shadowStats.secret + 1 end
		return false
	end
	shadowStats.plain = shadowStats.plain + 1
	for _, inst in ipairs(list) do
		if type(inst) == "number" then into[#into + 1] = { inst = inst, kind = kind } end
	end
	return true
end

local function ApplyShadow(unit, fresh, shadow, now)
	local present = {}
	for _, sh in ipairs(shadow) do present[sh.inst] = sh end
	shadowStats.reads = shadowStats.reads + 1
	local claimed = {}
	-- Carried entries: still there, or gone.
	for key, e in pairs(fresh) do
		if e.inst then
			if present[e.inst] then
				claimed[e.inst] = true
				e.probed = true -- confirmed by instance; the frame icons get no say
			elseif e.stale or e.estimated then
				fresh[key] = nil
				shadowStats.removed = shadowStats.removed + 1
			end
		end
	end
	-- Your recent casts: bind each to the newest unclaimed instance of its kind.
	local synths = {}
	for _, e in pairs(fresh) do
		if e.synth and not e.inst and not e.unknown and e.createdAt and now - e.createdAt < 3 then synths[#synths + 1] = e end
	end
	table.sort(synths, function(a, b) return a.createdAt > b.createdAt end)
	for _, e in ipairs(synths) do
		local best
		for inst, sh in pairs(present) do
			if not claimed[inst] and sh.kind == e.kind and (not best or inst > best) then best = inst end
		end
		if best then
			e.inst = best
			claimed[best] = true
			shadowStats.bound = shadowStats.bound + 1
		end
	end
	-- Instances nobody knows.
	for inst, sh in pairs(present) do
		if not claimed[inst] then
			local key = "u:" .. unit .. ":" .. tostring(inst)
			if not fresh[key] then
				fresh[key] = { key = key, inst = inst, name = sh.kind == "buff" and "Unknown buff" or "Unknown debuff", icon = ns.QUESTION,
					count = 0, duration = 0, expires = 0, kind = sh.kind, unit = unit,
					synth = true, estimated = true, stale = true, probed = true, unknown = true }
				shadowStats.unknown = shadowStats.unknown + 1
			end
		end
	end
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
		-- Instance ids may still be readable: presence per instance.
		local shadow = {}
		local okB = InstanceList(unit, "HELPFUL", "buff", shadow)
		local okD = InstanceList(unit, "HARMFUL", "debuff", shadow)
		if okB and okD then ApplyShadow(unit, fresh, shadow, now) end
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

-- ------------------------------------------------------------------
-- Blizzard's AuraContainer widget: the sanctioned way to show auras while they are secret.
-- Blizzard writes icon, name and countdown into regions we hand it and shows or hides each
-- button itself. /auraledger container builds one with several group shapes and reports what
-- the container and its buttons expose, so the real API can be read off the client.
-- ------------------------------------------------------------------
local probeContainer
local probeButtons = {}
local probeGroupResults = {}

local function MethodNames(obj, pattern)
	local names = {}
	local ok = pcall(function()
		local mt = getmetatable(obj)
		local idx = mt and mt.__index
		if type(idx) == "table" then
			for k in pairs(idx) do
				if type(k) == "string" and (not pattern or k:find(pattern)) then names[#names + 1] = k end
			end
		end
	end)
	table.sort(names)
	return names, ok
end

local function InitProbeButton(groupId)
	return function(button)
		if not button then return end
		probeButtons[#probeButtons + 1] = { group = groupId, button = button }
		pcall(button.SetSize, button, 32, 32)
		local icon = button:CreateTexture(nil, "ARTWORK")
		icon:SetAllPoints(button)
		if button.SetIcon then pcall(button.SetIcon, button, icon) end
		local name = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		name:SetPoint("TOP", button, "BOTTOM", 0, -1)
		if button.SetNameText then pcall(button.SetNameText, button, name) elseif button.SetSpellName then pcall(button.SetSpellName, button, name) end
		local dur = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		dur:SetPoint("TOP", name, "BOTTOM", 0, -1)
		if button.SetDurationText then pcall(button.SetDurationText, button, dur) end
		button.alIcon, button.alName, button.alDur = icon, name, dur
	end
end

local function BuildProbeContainer()
	local ok, c = pcall(CreateFrame, "AuraContainer", "AuraLedgerProbeContainer", UIParent, "CustomAuraContainerTemplate")
	if not ok or not c then
		Print("AuraContainer: cannot create (" .. tostring(c) .. ")")
		return nil
	end
	c:SetSize(600, 200)
	c:SetPoint("TOP", UIParent, "TOP", 0, -200)
	c:SetFrameStrata("HIGH")
	local firstId
	for _, g in ipairs(ns.profile.groups) do
		for _, t in ipairs(g.trackers) do
			if t.id and not firstId then firstId = t.id end
		end
	end
	firstId = firstId or 687
	local layout = { elementWidth = 32, elementHeight = 56, elementSpacing = 4, lineSpacing = 4 }
	local shapes = {
		{ "help", "HELPFUL", { maxFrameCount = 24, initializeFrame = InitProbeButton("help"), layout = layout } },
		{ "harm", "HARMFUL", { maxFrameCount = 24, initializeFrame = InitProbeButton("harm"), layout = layout } },
		{ "mine", "HELPFUL|PLAYER", { maxFrameCount = 24, initializeFrame = InitProbeButton("mine"), layout = layout } },
		{ "spellA", "HELPFUL", { maxFrameCount = 4, initializeFrame = InitProbeButton("spellA"), layout = layout, candidateFilters = { { spellID = firstId } } } },
		{ "spellB", "HELPFUL", { maxFrameCount = 4, initializeFrame = InitProbeButton("spellB"), layout = layout, spellIDs = { firstId } } },
		{ "spellC", "HELPFUL", { maxFrameCount = 4, initializeFrame = InitProbeButton("spellC"), layout = layout, spellID = firstId } },
		{ "spellD", "HELPFUL", { maxFrameCount = 4, initializeFrame = InitProbeButton("spellD"), layout = layout, candidateFilters = { firstId } } },
	}
	for _, sh in ipairs(shapes) do
		local id, filter, settings = sh[1], sh[2], sh[3]
		local okG, err
		if c.AddAuraGroup then
			okG, err = pcall(c.AddAuraGroup, c, "al_" .. id, filter, settings)
		elseif c.AddAuraFilter then
			okG, err = pcall(c.AddAuraFilter, c, filter, settings)
		else
			okG, err = false, "no AddAuraGroup/AddAuraFilter"
		end
		probeGroupResults[#probeGroupResults + 1] = ("%s (%s): %s"):format(id, filter, okG and ("ok " .. tostring(err)) or ("error " .. tostring(err)))
	end
	if c.SetUnit then
		local okU, err = pcall(c.SetUnit, c, "player")
		probeGroupResults[#probeGroupResults + 1] = "SetUnit(player): " .. (okU and "ok" or ("error " .. tostring(err)))
	end
	c:Show()
	return c
end

function ns.ProbeContainer()
	Print("AuraContainer probe (secret: " .. YesNo(AurasSecret()) .. ", spell id used: first tracker's):")
	if not probeContainer then
		probeContainer = BuildProbeContainer()
		if not probeContainer then return end
		Print("  container methods: " .. table.concat((MethodNames(probeContainer, "Aura") ), ", "))
		Print("  container methods (Unit/Group/Filter): " .. table.concat((MethodNames(probeContainer, "Unit") ), ", ") .. " | " .. table.concat((MethodNames(probeContainer, "Group") ), ", ") .. " | " .. table.concat((MethodNames(probeContainer, "Filter") ), ", "))
		for _, line in ipairs(probeGroupResults) do Print("  group " .. line) end
	end
	local function D(v) if issecretvalue and issecretvalue(v) then return "secret" end return tostring(v) end
	local perGroup = {}
	for _, pb in ipairs(probeButtons) do
		local b = pb.button
		local okS, shown = pcall(b.IsShown, b)
		local okV, vis = pcall(b.IsVisible, b)
		local okT, tex = pcall(function() return b.alIcon and b.alIcon:GetTexture() end)
		local okN, txt = pcall(function() return b.alName and b.alName:GetText() end)
		local g = perGroup[pb.group] or { total = 0, shown = 0, lines = {} }
		perGroup[pb.group] = g
		g.total = g.total + 1
		if okS and shown == true then g.shown = g.shown + 1 end
		if #g.lines < 3 then
			g.lines[#g.lines + 1] = ("shown %s, visible %s, icon %s, name %s"):format(okS and D(shown) or "error", okV and D(vis) or "error", okT and D(tex) or "error", okN and D(txt) or "error")
		end
	end
	for id, g in pairs(perGroup) do
		Print(("  %s: %d buttons made, %d plainly shown; %s"):format(id, g.total, g.shown, table.concat(g.lines, " / ")))
	end
	if #probeButtons > 0 then
		local b = probeButtons[1].button
		Print("  button methods: " .. table.concat((MethodNames(b, "Aura") ), ", ") .. " | " .. table.concat((MethodNames(b, "Spell") ), ", ") .. " | " .. table.concat((MethodNames(b, "Set") ), ", "))
	else
		Print("  no buttons were initialised yet (nothing matched, or the groups failed)")
	end
	local children = { probeContainer:GetChildren() }
	Print(("  container children: %d, shown: %s"):format(#children, D(select(2, pcall(probeContainer.IsShown, probeContainer)))))
	-- sounds: the enum and the registration call
	local trig = Enum and Enum.UnitAuraSoundTrigger
	if trig then
		local keys = {}
		for k, v in pairs(trig) do keys[#keys + 1] = tostring(k) .. "=" .. tostring(v) end
		table.sort(keys)
		Print("  Enum.UnitAuraSoundTrigger: " .. table.concat(keys, ", "))
	else
		Print("  Enum.UnitAuraSoundTrigger: missing")
	end
	Print("  C_UnitAuras.AddAuraSound " .. YesNo(C_UnitAuras and C_UnitAuras.AddAuraSound) .. ", RemoveAuraSound " .. YesNo(C_UnitAuras and C_UnitAuras.RemoveAuraSound))
	probeContainer:Hide()
end

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
-- What the game can follow per spell in combat. The Cooldown Manager keeps its own catalogue of
-- spells it knows how to track; anything in it can be handed to the game and stays right while
-- auras are hidden, anything outside it can only be drawn by the addon between fights. The book
-- marks the difference so the choice is made with that in view.
-- ------------------------------------------------------------------
local combatCat, combatCatAt = nil, -100

function ns.CombatCatalogue(force)
	local now = GetTime and GetTime() or 0
	if combatCat and not force and now - combatCatAt < 30 then return combatCat end
	local cat = { ids = {}, names = {}, cooldownById = {}, cooldownByName = {}, count = 0 }
	local C, E = C_CooldownViewer, Enum and Enum.CooldownViewerCategory
	if C and C.GetCooldownViewerCategorySet and C.GetCooldownViewerCooldownInfo and E then
		for _, category in ipairs({ E.TrackedBuff, E.TrackedBar }) do
			if category ~= nil then
				local ok, set = pcall(C.GetCooldownViewerCategorySet, category, true)
				local list = ok and PlainList(set) or nil
				for _, cdmID in ipairs(list or {}) do
					local okI, info = pcall(C.GetCooldownViewerCooldownInfo, cdmID)
					if okI and type(info) == "table" then
						local sid = Clean(info.spellID)
						if type(sid) == "number" then
							if not cat.ids[sid] then cat.count = cat.count + 1 end
							cat.ids[sid] = true
							cat.cooldownById[sid] = cat.cooldownById[sid] or cdmID
							if C_Spell and C_Spell.GetBaseSpell then
								local okB, base = pcall(C_Spell.GetBaseSpell, sid)
								if okB and type(base) == "number" then
									cat.ids[base] = true
									cat.cooldownById[base] = cat.cooldownById[base] or cdmID
								end
							end
							local name = ns.SpellName and ns.SpellName(sid)
							if name then
								local l = strlower(name)
								cat.names[l] = true
								cat.cooldownByName[l] = cat.cooldownByName[l] or cdmID
							end
						end
					end
				end
			end
		end
	end
	combatCat, combatCatAt = cat, now
	return cat
end

-- A book row or ledger row the game could follow per spell.
function ns.CombatTrackable(h)
	if not h then return false end
	local cat = ns.CombatCatalogue()
	if cat.count == 0 then return false end
	if h.id and cat.ids[h.id] then return true end
	if h.listId and cat.ids[h.listId] then return true end
	if h.ids then for id in pairs(h.ids) do if cat.ids[id] then return true end end end
	return h.name ~= nil and cat.names[strlower(h.name)] == true
end

-- ------------------------------------------------------------------
-- Blizzard's Cooldown Manager as a drawing engine. The manager can read auras during a fight
-- because it is the game's own code, so the way to keep a tracker right in combat is to put its
-- spell into the manager's layout and use the frame the manager makes for it. The layout is a
-- CBOR table, deflated and base64 encoded, in the shape the Coolinator addon documents; the
-- fields below are its numbered keys.
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

-- The cooldown entry for a tracker, by its spell id, any rank the ledger has seen, or its name.
function ns.CDM.CooldownFor(t, cat)
	cat = cat or ns.CombatCatalogue()
	if t.id and cat.cooldownById[t.id] then return cat.cooldownById[t.id] end
	if t.name then
		local l = strlower(t.name)
		if cat.cooldownByName[l] then return cat.cooldownByName[l] end
		for _, kind in ipairs({ "buff", "debuff" }) do
			local h = ns.db.history[kind .. ":" .. l]
			if h and h.ids then
				for id in pairs(h.ids) do if cat.cooldownById[id] then return cat.cooldownById[id] end end
			end
		end
	end
end

-- What the manager should hold: the spells of every tracker whose group asked the game to draw it.
-- Bars and icons are separate rows in the manager, so the group's style decides which one.
function ns.CDM.Wanted()
	local cat = ns.CombatCatalogue()
	local icons, bars, missing, seen = {}, {}, {}, {}
	for _, g in ipairs(ns.profile.groups) do
		if g.gameDrawn and not (g.live and g.live ~= "") then
			for _, t in ipairs(g.trackers) do
				local cd = ns.CDM.CooldownFor(t, cat)
				if cd and not seen[cd] then
					seen[cd] = true
					local into = (g.style == "bars") and bars or icons
					into[#into + 1] = cd
				elseif not cd then
					missing[#missing + 1] = t.name or ("spell " .. tostring(t.id))
				end
			end
		end
	end
	return icons, bars, missing
end

-- Writes a layout of our own holding just those cooldowns. Returns true, or false and why.
function ns.CDM.Apply(icons, bars)
	if not ns.CDM.Available() then return false, "this client does not offer the layout data" end
	if InCombatLockdown and InCombatLockdown() then return false, "not during a fight" end
	local tag = CDMTag()
	local data = ns.CDM.Read() or { [1] = 5, [CDM_ACTIVE_NAMES] = {}, [CDM_LAYOUTS] = {}, [CDM_LAYOUT_IDS] = {} }
	local version = data[1]
	if version ~= 4 and version ~= 5 then
		return false, "the layout format is version " .. tostring(version) .. ", which this addon does not know"
	end
	data[CDM_ACTIVE_NAMES] = data[CDM_ACTIVE_NAMES] or {}
	data[CDM_LAYOUTS] = data[CDM_LAYOUTS] or {}
	data[CDM_LAYOUT_IDS] = data[CDM_LAYOUT_IDS] or {}

	local name = ns.CDM.LayoutName()
	local id
	for lid, lname in pairs(data[CDM_LAYOUT_IDS]) do if lname == name then id = lid end end
	if not id then
		id = 1
		while data[CDM_LAYOUT_IDS][id] do id = id + 1 end
	end

	local E = Enum.CooldownViewerCategory
	local overrides = {}
	overrides[E.TrackedBuff] = icons
	overrides[E.TrackedBar] = bars
	if E.Essential then overrides[E.Essential] = {} end
	if E.Utility then overrides[E.Utility] = {} end
	data[CDM_LAYOUTS][tag] = data[CDM_LAYOUTS][tag] or {}
	data[CDM_LAYOUTS][tag][id] = { [CDM_OVERRIDES] = overrides }
	data[CDM_LAYOUT_IDS][id] = name

	-- Whatever was in charge before is remembered once, so it can be handed back.
	if ns.db.cdmPrevious == nil then
		ns.db.cdmPrevious = { tag = tag, id = data[CDM_ACTIVE_NAMES][tag] or false }
	end
	data[CDM_ACTIVE_NAMES][tag] = id

	local okS, encoded = pcall(function()
		return C_EncodingUtil.EncodeBase64(C_EncodingUtil.CompressString(C_EncodingUtil.SerializeCBOR(data), Enum.CompressionMethod.Deflate))
	end)
	if not okS then return false, "the layout could not be packed: " .. tostring(encoded) end

	-- The manager caches the layout it decoded, so the caches go before the new one is set, and it
	-- is switched off and on around the write so it reads everything again.
	if C_CVar and C_CVar.SetCVar then pcall(C_CVar.SetCVar, "cooldownViewerEnabled", "0") end
	for holder, key in pairs({ dataSerialization = "cachedSerializedData", dataProvider = "displayData", layoutManager = "activeLayoutID" }) do
		local t = CooldownViewerSettings and CooldownViewerSettings[holder]
		if type(t) == "table" then pcall(function() t[key] = nil end) end
	end
	local okW, err = pcall(C_CooldownViewer.SetLayoutData, "1|" .. encoded)
	if C_Timer and C_Timer.After then
		C_Timer.After(0, function() if C_CVar and C_CVar.SetCVar then pcall(C_CVar.SetCVar, "cooldownViewerEnabled", "1") end end)
	end
	if not okW then return false, "the game refused the layout: " .. tostring(err) end
	ns.db.cdmLayout = name
	return true
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
	local okS, encoded = pcall(function()
		return C_EncodingUtil.EncodeBase64(C_EncodingUtil.CompressString(C_EncodingUtil.SerializeCBOR(data), Enum.CompressionMethod.Deflate))
	end)
	if not okS then return false, "the layout could not be packed" end
	if C_CVar and C_CVar.SetCVar then pcall(C_CVar.SetCVar, "cooldownViewerEnabled", "0") end
	for holder, key in pairs({ dataSerialization = "cachedSerializedData", dataProvider = "displayData", layoutManager = "activeLayoutID" }) do
		local t = CooldownViewerSettings and CooldownViewerSettings[holder]
		if type(t) == "table" then pcall(function() t[key] = nil end) end
	end
	local okW = pcall(C_CooldownViewer.SetLayoutData, "1|" .. encoded)
	if C_Timer and C_Timer.After then
		C_Timer.After(0, function() if C_CVar and C_CVar.SetCVar then pcall(C_CVar.SetCVar, "cooldownViewerEnabled", "1") end end)
	end
	ns.db.cdmPrevious, ns.db.cdmLayout = nil, nil
	return okW and true or false, okW and nil or "the game refused the layout"
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
	end
	return ids
end

function ns.SyncAuraSounds()
	local C = C_UnitAuras
	if not (C and C.AddAuraSound and C.RemoveAuraSound) or not ns.profile then return end
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
		if not wanted[key] then
			pcall(C.RemoveAuraSound, regId)
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
		HandleCast(a1, a3)
	elseif event == "PLAYER_TARGET_CHANGED" then
		if ns.Display and ns.Display.TargetChanged then ns.Display:TargetChanged() end
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
		if C_Timer and C_Timer.After then C_Timer.After(1, ns.FlushAdvice) end
	elseif event == "PLAYER_ENTERING_WORLD" then
		ns.playerGUID = UnitGUID and UnitGUID("player") or ns.playerGUID
		if C_Timer and C_Timer.After then
			C_Timer.After(2, function()
				ns.CombatCatalogue(true)
				if ns.ResolveAllBookItems then ns.ResolveAllBookItems() end
			end)
			-- The Cooldown Manager builds its frames after login, so this waits a little longer.
			C_Timer.After(5, function()
				if ns.db.cdmProbe == ns.VERSION or not ns.ProbeCDM then return end
				ns.db.cdmProbe = ns.VERSION
				ns.LogLine("=== automatic Cooldown Manager probe")
				local summary = ns.ProbeCDM(ns.LogLine)
				Print("Cooldown Manager: " .. tostring(summary) .. ". The full reading is in the log (/auraledger debug cdm2 to see it here).")
			end)
		end
		if C_Timer and C_Timer.After then C_Timer.After(1, function() if ns.SyncAuraSounds then ns.SyncAuraSounds() end end) end
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
-- Advice with the fix on it. A line of chat scrolls away and is easy to miss, so anything the
-- user has to act on is raised as a dialog with a Reload button. Each reason is raised once a
-- session, and never during a fight: it waits for the fight to end, and is dropped if the addon
-- has put itself right by then.
-- ------------------------------------------------------------------
-- The diagnostic topics, in the order the help lists them.
ns.DIAG_ORDER = { "log", "api", "gd", "cdm", "cdm2", "cdmapply", "cdmrestore", "frames", "probe", "container", "slot", "mixin", "atlases", "combatlog" }
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
	Print("  /auraledger import <string> - import a tracker or group from an export string")
	Print("  /auraledger unlock | lock - move trackers without the window open")
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
	local sh = ns.shadowStats
	Print(("  instance ids while restricted: calls %d (plain %d, secret %d, errors %d), applied %d, removed by instance %d, casts bound %d, unknown auras %d"):format(
		sh.calls, sh.plain, sh.secret, sh.errors, sh.reads, sh.removed, sh.bound, sh.unknown))
	local as = ns.auraSoundStats
	Print(("  Blizzard aura sounds: %d registered, %d failed, %d stale ones cleared at load%s (API %s)"):format(as.registered, as.failed, as.cleared, as.lastError and (", last error " .. as.lastError) or "", YesNo(C_UnitAuras and C_UnitAuras.AddAuraSound)))
	for key, id in pairs(ns.db.auraSoundIds or {}) do
		local unit, spell, trigger, file = key:match("^(.-):(%d+):(%d+):(%d+)$")
		local cname
		for _, c in ipairs(ns.SOUND_CHOICES) do if c[4] and tostring(c[4]) == file then cname = c[1] end end
		Print(("    %s spell %s (%s) on %s: %s [file %s], registration %s"):format(
			trigger == "2" and "removed" or trigger == "1" and "stacks" or "added", tostring(spell), ns.SpellName and ns.SpellName(tonumber(spell)) or "?", tostring(unit), cname or "?", tostring(file), tostring(id)))
	end
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
		Print(("  pre-built book: %d auras offered, %d resolved by ID, %d icon only (client name differs), %d withheld as unknown to this client"):format(total, exact, iconOnly, unknown))
	end
	local cat = ns.CombatCatalogue(true)
	Print(("  spells the game can follow in combat: %d in the Cooldown Manager's catalogue"):format(cat.count))
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
	elseif cmd == "cdmapply" then
		local icons, bars, missing = ns.CDM.Wanted()
		Print(("Cooldown Manager: %d spell%s for icons, %d for bars%s"):format(#icons, #icons == 1 and "" or "s", #bars,
			#missing > 0 and (", " .. #missing .. " with no entry in the manager (" .. table.concat(missing, ", ") .. ")") or ""))
		if #icons == 0 and #bars == 0 then
			Print("  Nothing to write. Set a group's 'In combat' to 'the game keeps it right' first.")
		else
			local ok, err = ns.CDM.Apply(icons, bars)
			if ok then
				Print("  Written as " .. ns.CDM.LayoutName() .. ". Run /auraledger debug cdm2 in a moment to see the frames it made.")
			else
				Print("  Not written: " .. tostring(err))
			end
		end
	elseif cmd == "cdmrestore" then
		local ok, err = ns.CDM.Restore()
		Print(ok and "The Cooldown Manager is back to what it was before." or ("Not restored: " .. tostring(err)))
	elseif cmd == "cdm2" then
		ns.ProbeCDM(Print)
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
			if g.gameDrawn or (g.live and g.live ~= "") then
				any = true
				local f = ns.Display.FrameFor and ns.Display.FrameFor(g)
				Print(("  %s: %s, macro %s"):format(ns.GroupName(g), g.gameDrawn and "trackers drawn by the game" or ("contents " .. tostring(g.live)), tostring(ns.Display.CondMacro and ns.Display.CondMacro(g.cond))))
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
							Print(("    cell %d: %s, alpha %.1f, parent %s"):format(i, w.tracker and (w.tracker.name or "?") or "-", w:GetAlpha(), w:GetParent() == f.gate and "gate" or "group"))
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
	elseif cmd == "slot" then
		Print("AuraContainer slot and filter functions, called with wrong arguments to read what they expect:")
		local ok, c = pcall(CreateFrame, "AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
		if not (ok and c) then Print("  cannot create: " .. tostring(c)) return end
		local function try(label, fn, ...)
			local okF, a, b = pcall(fn, c, ...)
			Print(("  %s -> %s"):format(label, okF and ("ok " .. tostring(a) .. " " .. tostring(b)) or ("error " .. tostring(a))))
		end
		try("AddAuraSlot()", c.AddAuraSlot)
		try("AddAuraSlot(1)", c.AddAuraSlot, 1)
		try("AddAuraSlot('s', 'HARMFUL')", c.AddAuraSlot, "s", "HARMFUL")
		try("AddAuraSlot('s2', 'HARMFUL', {})", c.AddAuraSlot, "s2", "HARMFUL", {})
		try("AddAuraSlot('s3', 'HARMFUL', {initializeFrame=f})", c.AddAuraSlot, "s3", "HARMFUL", { initializeFrame = function() end })
		try("AddAuraSlot('s4', {})", c.AddAuraSlot, "s4", {})
		try("AddAuraGroup()", c.AddAuraGroup)
		try("AddAuraGroup('g', 'HARMFUL', 5)", c.AddAuraGroup, "g", "HARMFUL", 5)
		try("AddAuraGroup('g2', 'HARMFUL', {bogus=1})", c.AddAuraGroup, "g2", "HARMFUL", { bogus = 1 })
		try("AddAuraGroup('g3', 'HARMFUL', {layout=5})", c.AddAuraGroup, "g3", "HARMFUL", { layout = 5 })
		try("AddAuraGroup('g4', 'HARMFUL', {layout={bogus=1}})", c.AddAuraGroup, "g4", "HARMFUL", { layout = { bogus = 1 } })
		try("AddAuraGroup('g5', 'BOGUS', {})", c.AddAuraGroup, "g5", "BOGUS", {})
		try("AddAuraGroup('g6', 'HARMFUL', {candidateFilters=5})", c.AddAuraGroup, "g6", "HARMFUL", { candidateFilters = 5 })
		try("AddAuraGroup('g7', 'HARMFUL', {candidateFilters={5}})", c.AddAuraGroup, "g7", "HARMFUL", { candidateFilters = { 5 } })
		try("AddAuraGroup('g8', 'HARMFUL', {candidateFilters={{}}})", c.AddAuraGroup, "g8", "HARMFUL", { candidateFilters = { {} } })
		try("AddAuraGroup('g9', 'HARMFUL', {candidateFilters={{bogus=1}}})", c.AddAuraGroup, "g9", "HARMFUL", { candidateFilters = { { bogus = 1 } } })
		try("AddAuraGroup('g10', 'HARMFUL', {sortMethod=5})", c.AddAuraGroup, "g10", "HARMFUL", { sortMethod = 5 })
		try("SetAuraGroupCandidateFilters()", c.SetAuraGroupCandidateFilters)
		try("SetAuraGroupCandidateFilters('g2')", c.SetAuraGroupCandidateFilters, "g2")
		try("SetAuraGroupCandidateFilters('g2', 5)", c.SetAuraGroupCandidateFilters, "g2", 5)
		try("SetAuraGroupCandidateFilters('g2', {5})", c.SetAuraGroupCandidateFilters, "g2", { 5 })
		try("SetAuraGroupCandidateFilters('g2', {{}})", c.SetAuraGroupCandidateFilters, "g2", { {} })
		try("SetAuraGroupCandidateFilters('g2', {{bogus=1}})", c.SetAuraGroupCandidateFilters, "g2", { { bogus = 1 } })
		try("SetAuraGroupCandidateFilters('g2', {{spellID='x'}})", c.SetAuraGroupCandidateFilters, "g2", { { spellID = "x" } })
		try("SetAuraGroupCandidateFilters('g2', {{spellID=172}})", c.SetAuraGroupCandidateFilters, "g2", { { spellID = 172 } })
		try("SetAuraGroupCandidateFilters('g2', {172})", c.SetAuraGroupCandidateFilters, "g2", { 172 })
		try("SetAuraGroupFilterString('g2', 5)", c.SetAuraGroupFilterString, "g2", 5)
		try("SetAuraGroupFilterString('g2', 'HARMFUL|BOGUS')", c.SetAuraGroupFilterString, "g2", "HARMFUL|BOGUS")
		try("SetAuraGroupSortMethod('g2', 'x')", c.SetAuraGroupSortMethod, "g2", "x")
		try("SetAuraGroupSortMethod('g2', 99)", c.SetAuraGroupSortMethod, "g2", 99)
		try("SetAuraGroupLayout('g2', 5)", c.SetAuraGroupLayout, "g2", 5)
		try("SetAuraGroupLayout('g2', {bogus=1})", c.SetAuraGroupLayout, "g2", { bogus = 1 })
		try("SetAuraProcessingPolicy('x')", c.SetAuraProcessingPolicy, "x")
		try("SetAuraProcessingPolicy(99)", c.SetAuraProcessingPolicy, 99)
		try("GetAuraProcessingPolicy()", c.GetAuraProcessingPolicy)
		try("SetFlowLayoutGrowthDirection('x')", c.SetFlowLayoutGrowthDirection, "x")
		try("SetFlowLayoutAxis('x')", c.SetFlowLayoutAxis, "x")
		try("SetFlowLayoutAnchorPoint('x')", c.SetFlowLayoutAnchorPoint, "x")
		try("GetFlowLayoutGrowthDirection()", c.GetFlowLayoutGrowthDirection)
		try("GetFlowLayoutAxis()", c.GetFlowLayoutAxis)
		try("GetFlowLayoutMaximumLineSize()", c.GetFlowLayoutMaximumLineSize)
		try("GetFlowLayoutPadding()", c.GetFlowLayoutPadding)
		try("SetAuraSlotCandidateFilters()", c.SetAuraSlotCandidateFilters)
		try("SetAuraSlotCandidateFilters('s2', 5)", c.SetAuraSlotCandidateFilters, "s2", 5)
		try("SetAuraSlotCandidateFilters('s2', {{spellID=172}})", c.SetAuraSlotCandidateFilters, "s2", { { spellID = 172 } })
		try("SetAuraSlotFilterString('s2', 5)", c.SetAuraSlotFilterString, "s2", 5)
		try("GetAuraSlotFrame('s2')", c.GetAuraSlotFrame, "s2")
		try("GetAuraGroupFrame('g2', 1)", c.GetAuraGroupFrame, "g2", 1)
		try("GetAuraGroupFrameCount('g2')", c.GetAuraGroupFrameCount, "g2")
		try("HasAuraGroup('g2')", c.HasAuraGroup, "g2")
		try("IsAuraSlotEnabled('s2')", c.IsAuraSlotEnabled, "s2")
		c:Hide()
		for _, en in ipairs({ "AuraProcessingPolicy", "AuraSortMethod", "FlowLayoutGrowthDirection", "FlowLayoutAxis", "AuraFilter", "AuraCandidateFilterType", "UnitAuraCandidateFilterType" }) do
			local e = Enum and Enum[en]
			if e then
				local keys = {}
				for k, v in pairs(e) do keys[#keys + 1] = tostring(k) .. "=" .. tostring(v) end
				table.sort(keys)
				Print("  Enum." .. en .. ": " .. table.concat(keys, ", "))
			else
				Print("  Enum." .. en .. ": missing")
			end
		end
	elseif cmd == "mixin" then
		local function funcs(t, label)
			local names = {}
			local ok = pcall(function() for k, v in pairs(t) do if type(v) == "function" then names[#names + 1] = tostring(k) end end end)
			table.sort(names)
			Print(("  %s (%d): %s"):format(label, #names, ok and table.concat(names, ", ") or "pairs refused"))
		end
		local function keys(t, label)
			local names = {}
			local ok = pcall(function() for k, v in pairs(t) do if type(v) ~= "function" then names[#names + 1] = tostring(k) .. "=" .. (type(v) == "table" and "{}" or type(v)) end end end)
			table.sort(names)
			Print(("  %s keys (%d): %s"):format(label, #names, ok and table.concat(names, ", ") or "pairs refused"))
		end
		Print("AuraContainer mixins:")
		local ok, c = pcall(CreateFrame, "AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
		if ok and c then
			funcs(c, "container functions")
			keys(c, "container")
			local got
			pcall(c.AddAuraGroup, c, "al_mixin", "HELPFUL", { maxFrameCount = 1, initializeFrame = function(b) got = b end })
			keys(c, "container after AddAuraGroup")
			if got then funcs(got, "button functions") keys(got, "button") end
			c:Hide()
		else
			Print("  cannot create: " .. tostring(c))
		end
		if EnumerateFrames then
			local n = 0
			local f = EnumerateFrames()
			while f and n < 12 do
				local okT, t = pcall(f.GetObjectType, f)
				if okT and t == "AuraContainer" then
					n = n + 1
					local okN, name = pcall(f.GetName, f)
					local okP, parent = pcall(function() return f:GetParent() and f:GetParent():GetName() end)
					Print(("  game container %d: %s (parent %s)"):format(n, okN and tostring(name) or "?", okP and tostring(parent) or "?"))
					keys(f, "   ")
				end
				f = EnumerateFrames(f)
			end
			if n == 0 then Print("  no AuraContainer frames found on screen") end
		end
	elseif cmd == "container" then
		ns.ProbeContainer()
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
