-- Aura Ledger: the Life Tap panel.
--
-- A warlock turns health into mana, and the only question is ever whether the health can be
-- spared. Answering it wants two things: how much health there is, and whether more is on the way.
--
-- The first is easy. Health and mana are not aura data, so this client hands them over in combat
-- like any other. The second is not: while addon restrictions are up, every read of an aura on you
-- errors or comes back secret, the aura events carry secret tables, and the combat log is closed,
-- so no addon can ask whether a heal over time is running. There is no callback behind the sounds
-- the game plays for us either, and the slots it draws are forbidden frames we cannot read.
--
-- So this module answers it twice over, and says which answer it is giving:
--
--   read       out of combat, and anywhere else the auras are legible, the heal over time is read
--              straight off you and the time left is the real one.
--   estimated  while blind, the health itself is watched. A heal over time lands as a jump in
--              health that nothing you did accounts for, and two such jumps about three seconds
--              apart is somebody healing you. The clock is then run from the ticks. It is late by
--              up to one tick, it cannot name the spell, and a tick that arrives inside the same
--              tenth of a second as a hit is lost in the arithmetic. It is labelled with a ~.
--   drawn      "/auraledger lifetap setup" builds an ordinary game-drawn tracker group for the
--              heals themselves. The game keeps that one right in combat. This addon cannot read
--              it, but you can, and it is the version to trust when the two disagree.

local ADDON, ns = ...

local LT = {}
ns.LT = LT

local Clean, Print = ns.Clean, ns.Print
local floor, max, min = math.floor, math.max, math.min

local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

-- A run of ticks counts as one spell when they arrive this far apart. Every heal over time in this
-- game ticks every three seconds; the window is wide enough for the client's own jitter.
local MIN_PERIOD, MAX_PERIOD = 2.2, 3.9
-- How long after a tick was due before the heal is called finished.
local LAPSE_GRACE = 1.6
-- A gain bigger than this share of your maximum is a refill, not a heal: resurrection, zoning in.
local REFILL_SHARE = 0.5

-- Healing you cause yourself. Its ticks are not a healer's, so they are put aside for the window of
-- seconds given here, counted from the cast. Matched on the lowercased spell name containing the key.
local OWN_HEALS = {
	["drain life"] = 7, ["siphon life"] = 32, ["death coil"] = 4, ["health funnel"] = 12,
	["bandage"] = 10, ["healthstone"] = 3, ["healing potion"] = 3, ["rejuvenation potion"] = 3,
	["first aid"] = 10, ["consume shadows"] = 12, ["dark pact"] = 2,
}

local DEFAULTS = {
	enabled = true,
	shown = true,
	scale = 1,
	alpha = 1,
	reserve = 25,   -- per cent of maximum health to keep back after a tap
	manaAt = 50,    -- only speak up once mana is at or below this per cent
	tickPct = 2,    -- a gain smaller than this share of maximum health is not somebody's heal
	rank = nil,     -- nil: the highest rank of Life Tap this character knows
	cost = nil,     -- overrides what the client says a tap costs
	sndApplied = 0,  -- registered with the game: fires the moment a listed heal lands, in combat too
	sndLapsed = 0,   -- ditto for one running out
	sndEstimate = 0, -- played by the addon when the tick clock notices a heal the game did not name
	sndReady = 0,    -- played by the addon when the panel turns to TAP
}

local S = {
	ticks = {},
	hot = {},
	own = {},
	stats = { samples = 0, gains = 0, small = 0, mine = 0, refills = 0, heals = 0, runs = 0, awake = 0 },
}
LT.state = S

-- ------------------------------------------------------------------
-- Reading the client
-- ------------------------------------------------------------------
-- Every number here goes through pcall and Clean: this client answers some reads with a secret
-- value rather than a refusal, and a secret number poisons the arithmetic it lands in.
local function Num(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, v = pcall(fn, ...)
	if not ok then return nil end
	v = Clean(v)
	if type(v) ~= "number" then return nil end
	return v
end

local function IsWarlock()
	local ok, _, class = pcall(UnitClass, "player")
	return ok and Clean(class) == "WARLOCK"
end

local function Profile()
	if not ns.profile then return nil end
	local p = ns.profile.lifetap
	if type(p) ~= "table" then
		p = {}
		ns.profile.lifetap = p
		-- Nobody else taps their own health for mana, so the panel keeps out of the way until asked.
		p.enabled = IsWarlock()
	end
	for k, v in pairs(DEFAULTS) do
		if p[k] == nil then p[k] = v end
	end
	return p
end
LT.Profile = Profile

-- True while this client is hiding aura data from us, which is when the estimate has to stand in
-- for a reading. Out of combat the real aura wins, and the estimator is left alone: health that
-- regenerates on its own out there ticks at a size not far off a low-rank heal.
local function Blind()
	if ns.AurasSecret and ns.AurasSecret() then return true end
	return ns.restricted and true or false
end

-- ------------------------------------------------------------------
-- What a tap costs
-- ------------------------------------------------------------------
-- The ranks of Life Tap this character has, highest last.
function LT:Ranks()
	local ids = ns.Ranks("Life Tap")
	local list = {}
	for _, id in ipairs((ns.RANK_IDS and ns.RANK_IDS["Life Tap"]) or {}) do
		if not ids or ids[id] then
			local known = true
			if IsSpellKnown then
				local ok, v = pcall(IsSpellKnown, id)
				if ok then known = Clean(v) == true end
			elseif IsPlayerSpell then
				local ok, v = pcall(IsPlayerSpell, id)
				if ok then known = Clean(v) == true end
			end
			if known then list[#list + 1] = id end
		end
	end
	-- Nothing came back known: the client may not answer that question for ranks, so offer them all
	-- and let the panel show which one it settled on.
	if #list == 0 then
		for _, id in ipairs((ns.RANK_IDS and ns.RANK_IDS["Life Tap"]) or {}) do
			if not ids or ids[id] then list[#list + 1] = id end
		end
		S.rankGuess = true
	else
		S.rankGuess = false
	end
	return list
end

-- The health a single tap costs, and where the number came from.
function LT:Cost()
	local p = Profile()
	if p and tonumber(p.cost) then return tonumber(p.cost), "set by you" end
	local id = p and tonumber(p.rank)
	if not id then
		local list = self:Ranks()
		id = list[#list]
	end
	if not id then return nil, "no rank found" end
	S.rankId = id
	-- The client's own words first: the description carries the real number, talents and all.
	if C_Spell and C_Spell.GetSpellDescription then
		local ok, text = pcall(C_Spell.GetSpellDescription, id)
		text = ok and Clean(text) or nil
		if type(text) == "string" then
			local n = tonumber(text:match("(%d+)"))
			if n and n > 0 then return n, "the spell's own description" end
		end
	end
	local known = ns.LIFE_TAP_COST and ns.LIFE_TAP_COST[id]
	if known then return known, "written down for rank " .. tostring(id) end
	return nil, "unknown for spell " .. tostring(id)
end

-- ------------------------------------------------------------------
-- Heals over time: the reading
-- ------------------------------------------------------------------
-- The real aura, when this client will part with it. Returns the ledger entry and its row.
-- The probe tables are made once: this runs ten times a second.
local probes
function LT:ReadHot()
	if not ns.Find then return nil end
	if not probes then
		probes = {}
		for _, row in ipairs(ns.HOTS or {}) do
			probes[#probes + 1] = { row = row, t = { name = row.name, kind = "buff" } }
		end
	end
	local best, bestRow
	for _, probe in ipairs(probes) do
		local e = ns.Find(probe.t)
		-- An estimated entry is this addon's own guesswork coming back round; the tick clock below
		-- is the better guess and says so.
		if e and not e.estimated then
			if not best or (e.expires or 0) > (best.expires or 0) then best, bestRow = e, probe.row end
		end
	end
	return best, bestRow
end

-- ------------------------------------------------------------------
-- Heals over time: the estimate
-- ------------------------------------------------------------------
-- A cast of yours that heals you over the next few seconds. Its ticks are yours.
function LT:NoteOwnCast(spellId)
	local name = ns.SpellInfo(spellId)
	if type(name) ~= "string" then return end
	local l = name:lower()
	for key, window in pairs(OWN_HEALS) do
		if l:find(key, 1, true) then
			S.own[key] = GetTime() + window
			S.ownName = name
			return
		end
	end
end

local function OwnWindow(now)
	local open
	for key, until_ in pairs(S.own) do
		if until_ and until_ > now then open = key else S.own[key] = nil end
	end
	return open
end

-- One health reading. Everything the estimate knows comes from the gaps between calls to this.
function LT:Sample(now)
	local hp, hpMax = Num(UnitHealth, "player"), Num(UnitHealthMax, "player")
	if not hp or not hpMax or hpMax <= 0 then
		S.readable = false
		return
	end
	S.readable = true
	S.stats.samples = S.stats.samples + 1
	local lastHp, lastMax = S.hp, S.hpMax
	S.hp, S.hpMax = hp, hpMax
	S.mp = Num(UnitPower, "player", 0)
	S.mpMax = Num(UnitPowerMax, "player", 0)
	if UnitGetIncomingHeals then S.incoming = Num(UnitGetIncomingHeals, "player") end
	-- A buff that raises maximum health raises the current health with it, and that is not a heal.
	if not lastHp or lastMax ~= hpMax then return end
	local gain = hp - lastHp
	if gain <= 0 then return end
	S.stats.gains = S.stats.gains + 1
	if gain > hpMax * REFILL_SHARE then
		S.stats.refills = S.stats.refills + 1
		return
	end
	local p = Profile()
	local least = max(1, hpMax * ((p and p.tickPct) or DEFAULTS.tickPct) / 100)
	if gain < least then
		S.stats.small = S.stats.small + 1
		S.lastSmall = gain
		return
	end
	local own = OwnWindow(now)
	if own then
		S.stats.mine = S.stats.mine + 1
		S.lastMineAt, S.lastMineKey = now, own
		return
	end
	self:HealTick(now, gain)
end

-- A gain that was somebody else's doing.
function LT:HealTick(now, amount)
	S.stats.heals = S.stats.heals + 1
	S.lastHeal = { at = now, amount = amount }
	local ticks = S.ticks
	local prev = ticks[#ticks]
	ticks[#ticks + 1] = { at = now, amount = amount }
	while #ticks > 10 do table.remove(ticks, 1) end
	if not prev then return end
	local gap = now - prev.at
	if gap < MIN_PERIOD or gap > MAX_PERIOD then return end
	local hot = S.hot
	if not hot.active then
		hot.active = true
		hot.startedAt = prev.at
		hot.name, hot.duration = self:NameFor(amount)
		S.stats.runs = S.stats.runs + 1
		self:Announce()
	end
	hot.period = gap
	hot.lastTick = now
	hot.amount = amount
	hot.expires = (hot.startedAt or now) + (hot.duration or 15)
	-- A heal still ticking has by definition not finished, whatever the guessed duration said.
	if hot.expires < now + gap then hot.expires = now + gap end
end

-- What to call a run of ticks. A heal actually read off you recently is the best answer; failing
-- that the longest of the known heals, so the time shown errs towards more rather than less.
function LT:NameFor(amount)
	local seen = S.seen
	if seen and seen.at and GetTime() - seen.at < 60 then return seen.name, seen.duration end
	local longest
	for _, row in ipairs(ns.HOTS or {}) do
		if not longest or row.duration > longest.duration then longest = row end
	end
	return "a heal over time", longest and longest.duration or 15
end

-- ------------------------------------------------------------------
-- The verdict
-- ------------------------------------------------------------------
-- Returns a key, a line of reasoning, and how many taps the floor leaves room for.
--   tap     health to spare and somebody is healing you
--   ok      health to spare, nothing coming
--   wait    a tap would put you under your own floor
--   spare   mana is fine, no need to ask
--   unknown the client would not say
function LT:Verdict()
	local p = Profile()
	if not p then return "unknown", "not loaded yet", 0 end
	local hp, hpMax = S.hp, S.hpMax
	if not S.readable or not hp or not hpMax or hpMax <= 0 then
		return "unknown", "this client will not say what your health is", 0
	end
	local cost = self:Cost()
	if not cost or cost <= 0 then
		return "unknown", "no Life Tap rank found: /auraledger lifetap cost <health>", 0
	end
	local reserve = hpMax * (p.reserve or 25) / 100
	local room = floor((hp - reserve) / cost)
	if room < 0 then room = 0 end
	local manaPct = (S.mpMax and S.mpMax > 0) and (S.mp / S.mpMax * 100) or 100
	if room < 1 then
		return "wait", ("a tap costs %d and your floor is %d%%"):format(cost, p.reserve or 25), 0
	end
	if manaPct > (p.manaAt or 50) then
		return "spare", ("mana is above %d%%"):format(p.manaAt or 50), room
	end
	local kind, label = self:Incoming()
	if kind == "read" or kind == "estimated" then
		return "tap", label, room
	end
	return "ok", "nothing is healing you", room
end

-- What is known about healing arriving: a key, a line for the panel, and the seconds left when
-- there is a number worth showing. Worked out once per pass, since the verdict and the panel both
-- want the answer and reading auras is the expensive part.
function LT:Incoming()
	local now = GetTime()
	local memo = S.incomingMemo
	if memo and memo.at == now then return memo[1], memo[2], memo[3] end
	local a, b, c = self:ReadIncoming(now)
	S.incomingMemo = { a, b, c, at = now }
	return a, b, c
end

function LT:ReadIncoming(now)
	local e, row = self:ReadHot()
	if e then
		S.seen = { name = e.name, duration = row and row.duration or 15, at = now }
		local left = (e.expires or 0) > 0 and (e.expires - now) or nil
		if left and left > 0 then
			return "read", ("%s, %s left"):format(e.name, ns.FormatTime(left)), left
		end
		return "read", tostring(e.name), nil
	end
	local hot = S.hot
	if hot.active then
		local left = max(0, (hot.expires or now) - now)
		local nextIn = max(0, ((hot.lastTick or now) + (hot.period or 3)) - now)
		return "estimated", ("~ %s, about %s left, next tick %.1fs"):format(hot.name or "a heal", ns.FormatTime(left), nextIn), left
	end
	if S.incoming and S.incoming > 0 then
		return "cast", ("a heal of about %d is on its way"):format(S.incoming), nil
	end
	if Blind() then return "none", "nothing seen (auras are hidden in combat)", nil end
	return "none", "nothing on you", nil
end

-- ------------------------------------------------------------------
-- Sounds
-- ------------------------------------------------------------------
-- Registered with the game rather than played by us: these are the only alerts that survive
-- combat, because the client plays them itself without telling the addon anything.
function LT:WantedSounds(wanted, triggers)
	local p = Profile()
	S.soundIds = 0
	if not p or not p.enabled then return end
	local picks = { applied = p.sndApplied, removed = p.sndLapsed }
	for ev, choiceIndex in pairs(picks) do
		local choice = ns.SOUND_CHOICES[choiceIndex or 0]
		local file = choice and choice[4]
		local trigger = triggers[ev]
		if file and trigger then
			for _, row in ipairs(ns.HOTS or {}) do
				local ids = ns.Ranks(row.name)
				if ids then
					for id in pairs(ids) do
						local key = "player:" .. id .. ":" .. trigger .. ":" .. file
						wanted[key] = { unit = "player", id = id, trigger = trigger, file = file }
						S.soundIds = (S.soundIds or 0) + 1
					end
				end
			end
		end
	end
end

-- The cue for the estimate noticing a heal. The game already plays its own sound the instant a heal
-- it was handed an id for lands, so this one is off by default: turned on it fires a few seconds
-- later, on the second tick, and is worth having only for heals the game did not announce.
function LT:Announce()
	local p = Profile()
	if not p then return end
	if p.sndEstimate and p.sndEstimate > 0 then ns.PlaySoundChoice(p.sndEstimate) end
end

function LT:Ready()
	local p = Profile()
	if p and p.sndReady and p.sndReady > 0 then ns.PlaySoundChoice(p.sndReady) end
end

-- ------------------------------------------------------------------
-- The panel
-- ------------------------------------------------------------------
local W, BAR_W, BAR_H = 216, 200, 13

local function Bar(parent, r, g, b)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetSize(BAR_W, BAR_H)
	bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	bar:SetStatusBarColor(r, g, b)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(bar)
	bg:SetColorTexture(0, 0, 0, 0.7)
	local text = bar:CreateFontString(nil, "OVERLAY")
	text:SetFont(FONT, 10, "OUTLINE")
	text:SetPoint("CENTER", bar, "CENTER", 0, 0)
	bar.text = text
	return bar
end

function LT:Build()
	if self.frame then return self.frame end
	local ok, f = pcall(CreateFrame, "Frame", "AuraLedgerLifeTap", UIParent, "BackdropTemplate")
	if not ok or not f then f = CreateFrame("Frame", "AuraLedgerLifeTap", UIParent) end
	f:SetSize(W, 118)
	f:SetFrameStrata("MEDIUM")
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	if f.SetBackdrop then
		f:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		f:SetBackdropColor(0.05, 0.03, 0.02, 0.9)
		f:SetBackdropBorderColor(0.6, 0.5, 0.35, 1)
	end

	local title = f:CreateFontString(nil, "OVERLAY")
	title:SetFont(FONT, 11, "OUTLINE")
	title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -7)
	title:SetText("|cffffd000Life Tap|r")
	f.title = title

	local hint = f:CreateFontString(nil, "OVERLAY")
	hint:SetFont(FONT, 9, "OUTLINE")
	hint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
	hint:SetTextColor(0.7, 0.65, 0.5)
	f.hint = hint

	f.health = Bar(f, 0.75, 0.15, 0.15)
	f.health:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -22)
	f.mana = Bar(f, 0.2, 0.35, 0.85)
	f.mana:SetPoint("TOPLEFT", f.health, "BOTTOMLEFT", 0, -3)

	local verdict = f:CreateFontString(nil, "OVERLAY")
	verdict:SetFont(FONT, 18, "OUTLINE")
	verdict:SetPoint("TOPLEFT", f.mana, "BOTTOMLEFT", 0, -5)
	f.verdict = verdict

	local room = f:CreateFontString(nil, "OVERLAY")
	room:SetFont(FONT, 11, "OUTLINE")
	room:SetPoint("BOTTOMRIGHT", f.mana, "BOTTOMRIGHT", 0, -24)
	room:SetTextColor(0.85, 0.8, 0.65)
	f.room = room

	local reason = f:CreateFontString(nil, "OVERLAY")
	reason:SetFont(FONT, 10, "")
	reason:SetPoint("TOPLEFT", verdict, "BOTTOMLEFT", 0, -2)
	reason:SetWidth(BAR_W)
	reason:SetJustifyH("LEFT")
	reason:SetTextColor(0.75, 0.72, 0.62)
	f.reason = reason

	local incoming = f:CreateFontString(nil, "OVERLAY")
	incoming:SetFont(FONT, 10, "")
	incoming:SetPoint("TOPLEFT", reason, "BOTTOMLEFT", 0, -2)
	incoming:SetWidth(BAR_W)
	incoming:SetJustifyH("LEFT")
	f.incoming = incoming

	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self2) self2:StartMoving() end)
	f:SetScript("OnDragStop", function(self2)
		self2:StopMovingOrSizing()
		local p = Profile()
		if p and self2:GetLeft() then
			p.x, p.y = self2:GetLeft(), self2:GetTop()
		end
	end)
	f:SetScript("OnEnter", function(self2)
		if not ns.Display or not ns.Display:IsUnlocked() then return end
		GameTooltip:SetOwner(self2, "ANCHOR_RIGHT")
		GameTooltip:SetText("Life Tap")
		GameTooltip:AddLine("Drag to move it. /auraledger lifetap for the rest.", 1, 1, 1)
		GameTooltip:Show()
	end)
	f:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

	self.frame = f
	self:Place()
	ns.report["life tap panel"] = "ok"
	return f
end

function LT:Place()
	local f, p = self.frame, Profile()
	if not f or not p then return end
	f:ClearAllPoints()
	if p.x and p.y then
		f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p.x, p.y)
	else
		f:SetPoint("CENTER", UIParent, "CENTER", -260, -120)
	end
	f:SetScale(p.scale or 1)
	f:SetAlpha(p.alpha or 1)
end

local VERDICTS = {
	tap = { "TAP", 0.25, 1, 0.3 },
	ok = { "tap ok", 0.8, 0.85, 0.4 },
	wait = { "WAIT", 1, 0.3, 0.25 },
	spare = { "no need", 0.6, 0.6, 0.6 },
	unknown = { "?", 0.6, 0.6, 0.6 },
}

local INCOMING_COLORS = {
	read = { 0.4, 1, 0.5 },
	estimated = { 0.55, 0.9, 1 },
	cast = { 0.8, 0.8, 1 },
	none = { 0.6, 0.58, 0.5 },
}

function LT:Refresh(now)
	local p = Profile()
	local f = self.frame
	if not p or not f then return end
	if not p.enabled or not p.shown then
		f:Hide()
		return
	end
	f:Show()
	local unlocked = ns.Display and ns.Display:IsUnlocked()
	f:EnableMouse(unlocked and true or false)
	f.hint:SetText(unlocked and "drag" or "")

	local hp, hpMax = S.hp, S.hpMax
	if hp and hpMax and hpMax > 0 then
		f.health:SetValue(hp / hpMax)
		f.health.text:SetText(("%d / %d   %d%%"):format(hp, hpMax, floor(hp / hpMax * 100 + 0.5)))
	else
		f.health:SetValue(0)
		f.health.text:SetText("health unreadable")
	end
	local mp, mpMax = S.mp, S.mpMax
	if mp and mpMax and mpMax > 0 then
		f.mana:SetValue(mp / mpMax)
		f.mana.text:SetText(("%d / %d   %d%%"):format(mp, mpMax, floor(mp / mpMax * 100 + 0.5)))
	else
		f.mana:SetValue(0)
		f.mana.text:SetText("mana unreadable")
	end

	local key, reason, room = self:Verdict()
	local v = VERDICTS[key] or VERDICTS.unknown
	f.verdict:SetText(v[1])
	f.verdict:SetTextColor(v[2], v[3], v[4])
	local cost = self:Cost()
	if room and room > 0 and cost then
		f.room:SetText(("%d x %d"):format(room, cost))
	else
		f.room:SetText("")
	end
	f.reason:SetText(reason or "")
	local kind, line = self:Incoming()
	local c = INCOMING_COLORS[kind] or INCOMING_COLORS.none
	f.incoming:SetText(line or "")
	f.incoming:SetTextColor(c[1], c[2], c[3])

	if key == "tap" and S.verdict ~= "tap" then self:Ready() end
	S.verdict = key
end

-- ------------------------------------------------------------------
-- The heal tracker group the game draws
-- ------------------------------------------------------------------
-- An ordinary Aura Ledger group of heal-over-time trackers with "track in combat" turned on, so
-- the game itself draws them and they stay right in a fight. Made once, then it is yours to move
-- and restyle like any other group.
function LT:Setup()
	if InCombatLockdown and InCombatLockdown() then
		Print("The game will not let a tracker group be built in combat. Try again once the fight is over.")
		return
	end
	local p = Profile()
	if not p then return end
	local existing
	for _, g in ipairs(ns.profile.groups) do
		if g.lifetapHots then existing = g break end
	end
	if existing then
		Print("The incoming heals group is already there. Use /auraledger edit to move it.")
		return
	end
	-- Under the panel, where the eye already is.
	local x = p.x or (UIParent:GetWidth() / 2 - 260)
	local y = (p.y or (UIParent:GetHeight() / 2 - 120)) - 126
	local g = ns.NewGroup(x, y)
	g.name = "Incoming heals"
	g.lifetapHots = true
	g.style = "bars"
	g.gameDrawn = true
	g.barW, g.barH = 200, 20
	for _, row in ipairs(ns.HOTS or {}) do
		local _, icon, id = ns.SpellInfo(row.name)
		local ids = ns.Ranks(row.name)
		if not id and ids then for candidate in pairs(ids) do id = id or candidate end end
		local t = ns.NewTracker({ name = row.name, id = id, icon = icon })
		t.show = "active"
		t.mine = false
		table.insert(g.trackers, t)
	end
	p.setupDone = true
	ns.Changed()
	if ns.SyncAuraSounds then ns.SyncAuraSounds() end
	Print("Made a group called \"Incoming heals\" with " .. tostring(#g.trackers) .. " trackers, drawn by the game so it keeps working in combat. /auraledger edit to move it.")
end

-- ------------------------------------------------------------------
-- Driver
-- ------------------------------------------------------------------
local ev = CreateFrame("Frame")
LT.events = ev

function LT:OnEvent(event, a1, _, a3)
	local p = Profile()
	if not p or not p.enabled then return end
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		if a1 == "player" then self:NoteOwnCast(a3) end
	elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" or event == "UNIT_POWER_UPDATE" then
		if a1 == "player" then self:Sample(GetTime()) end
	elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
		-- Leaving a fight hands the auras back; a carried estimate would only argue with them.
		S.hot = {}
		S.ticks = {}
		self:Sample(GetTime())
	elseif event == "PLAYER_ENTERING_WORLD" then
		S.hot = {}
		S.ticks = {}
		S.hp, S.hpMax = nil, nil
		self:Sample(GetTime())
	end
end

ev:SetScript("OnEvent", function(_, event, a1, a2, a3) LT:OnEvent(event, a1, a2, a3) end)
for _, event in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_POWER_UPDATE", "UNIT_SPELLCAST_SUCCEEDED",
	"PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD" }) do
	pcall(ev.RegisterEvent, ev, event)
end

local acc = 0
function LT:Tick(elapsed)
	local p = Profile()
	if not p or not p.enabled then return end
	acc = acc + elapsed
	if acc < 0.1 then return end
	acc = 0
	local now = GetTime()
	-- Polled as well as evented: the client does not promise an event for every change, and the
	-- estimate is only as good as the sampling behind it.
	self:Sample(now)
	local hot = S.hot
	if hot.active then
		local due = (hot.lastTick or 0) + (hot.period or 3) + LAPSE_GRACE
		-- No sound here: the game plays the "ran out" one itself, off the aura rather than off a
		-- tick that merely failed to show up.
		if now > due then hot.active = false end
	end
	self:Refresh(now)
end

ev:SetScript("OnUpdate", function(_, elapsed) LT:Tick(elapsed) end)

function LT:Init()
	local p = Profile()
	if not p then return end
	if p.enabled == nil then p.enabled = IsWarlock() end
	self:Build()
	self:Sample(GetTime())
	self:Refresh(GetTime())
end

-- ------------------------------------------------------------------
-- Commands
-- ------------------------------------------------------------------
local function SoundList()
	Print("  sounds (the ones marked combat are played by the game itself, so they work in a fight):")
	Print("    0 - silent")
	for i, c in ipairs(ns.SOUND_CHOICES) do
		Print(("    %d - %s%s"):format(i, c[1], c[4] and " |cff40ff40(combat)|r" or ""))
	end
end

function LT:Usage()
	Print("Life Tap panel:")
	Print("  /auraledger lifetap - show or hide the panel")
	Print("  /auraledger lifetap setup - build the group of incoming heals the game draws in combat")
	Print("  /auraledger lifetap reserve <percent> - health to keep back after a tap (now " .. tostring((Profile() or {}).reserve) .. ")")
	Print("  /auraledger lifetap mana <percent> - only speak up below this much mana (now " .. tostring((Profile() or {}).manaAt) .. ")")
	Print("  /auraledger lifetap tick <percent> - smallest health gain counted as somebody's heal (now " .. tostring((Profile() or {}).tickPct) .. ")")
	Print("  /auraledger lifetap cost <health> - what one tap costs, if the client will not say")
	Print("  /auraledger lifetap rank <1-6> - which rank to reckon with (auto by default)")
	Print("  /auraledger lifetap sound - list the sounds; applied / lapsed / ready <n> to set one")
	Print("  /auraledger lifetap scale <0.5-2> - size of the panel")
	Print("  /auraledger lifetap reset - put the panel back in the middle")
	Print("  /auraledger debug lifetap - what it is reading and what it has worked out")
end

function LT:Command(rest)
	local p = Profile()
	if not p then Print("not loaded yet.") return end
	local sub, tail = tostring(rest or ""):match("^(%S*)%s*(.-)%s*$")
	sub = (sub or ""):lower()
	local n = tonumber(tail)
	if sub == "" then
		p.shown = not p.shown
		p.enabled = true
		self:Build()
		self:Refresh(GetTime())
		Print("Life Tap panel " .. (p.shown and "shown" or "hidden") .. ".")
	elseif sub == "help" then
		self:Usage()
	elseif sub == "on" or sub == "off" then
		p.enabled = (sub == "on")
		if p.enabled then p.shown = true end
		self:Build()
		self:Refresh(GetTime())
		if ns.SyncAuraSounds then ns.SyncAuraSounds() end
		Print("Life Tap panel turned " .. sub .. ".")
	elseif sub == "setup" then
		self:Setup()
	elseif sub == "reserve" and n then
		p.reserve = max(0, min(90, n))
		Print(("Keeping %d%% of your health back."):format(p.reserve))
	elseif sub == "mana" and n then
		p.manaAt = max(0, min(100, n))
		Print(("Speaking up below %d%% mana."):format(p.manaAt))
	elseif sub == "tick" and n then
		p.tickPct = max(0.2, min(20, n))
		Print(("A gain of %.1f%% of your health or more counts as somebody's heal."):format(p.tickPct))
	elseif sub == "cost" then
		if tail == "auto" or tail == "" then
			p.cost = nil
			local c, why = self:Cost()
			Print("Back to working the cost out: " .. tostring(c) .. " (" .. tostring(why) .. ").")
		elseif n then
			p.cost = n
			Print(("A tap costs %d health."):format(n))
		end
	elseif sub == "rank" then
		if tail == "auto" or tail == "" then
			p.rank = nil
			Print("Using the highest rank of Life Tap found.")
		elseif n then
			local ids = (ns.RANK_IDS and ns.RANK_IDS["Life Tap"]) or {}
			local id = ids[n]
			if not id then Print("Ranks 1 to " .. tostring(#ids) .. ", or auto.") return end
			p.rank = id
			local c, why = self:Cost()
			Print(("Rank %d: a tap costs %s (%s)."):format(n, tostring(c), tostring(why)))
		end
	elseif sub == "sound" then
		local which, value = tail:match("^(%S*)%s*(%S*)$")
		which = (which or ""):lower()
		local v = tonumber(value)
		local keys = { applied = "sndApplied", lapsed = "sndLapsed", estimate = "sndEstimate", ready = "sndReady" }
		if which == "" or not keys[which] or not v then
			SoundList()
			Print(("  now: applied %d, lapsed %d, estimate %d, ready %d"):format(
				p.sndApplied or 0, p.sndLapsed or 0, p.sndEstimate or 0, p.sndReady or 0))
			Print("  /auraledger lifetap sound applied|lapsed|estimate|ready <number>")
			Print("  applied and lapsed are handed to the game, so they play in combat. estimate and ready are the addon's own.")
			return
		end
		p[keys[which]] = max(0, min(#ns.SOUND_CHOICES, v))
		local choice = ns.SOUND_CHOICES[p[keys[which]]]
		if choice then ns.PlaySoundChoice(p[keys[which]]) end
		if ns.SyncAuraSounds then ns.SyncAuraSounds() end
		Print(("%s: %s%s"):format(which, choice and choice[1] or "silent",
			(choice and not choice[4]) and " |cffff9040(this one cannot be played in combat: pick one marked combat)|r" or ""))
	elseif sub == "scale" and n then
		p.scale = max(0.5, min(2, n))
		self:Place()
		Print(("Panel scale %.2f."):format(p.scale))
	elseif sub == "reset" then
		p.x, p.y = nil, nil
		p.scale, p.alpha = 1, 1
		self:Place()
		Print("Panel put back in the middle.")
	else
		self:Usage()
	end
end

function LT:Debug()
	local p = Profile() or {}
	local YesNo = ns.YesNo
	Print("Life Tap panel:")
	Print(("  on %s, shown %s, class %s"):format(YesNo(p.enabled), YesNo(p.shown), IsWarlock() and "warlock" or "not a warlock"))
	local cost, why = self:Cost()
	Print(("  a tap costs %s (%s); rank spell %s%s"):format(tostring(cost), tostring(why), tostring(S.rankId),
		S.rankGuess and ", the client would not say which ranks you know" or ""))
	Print(("  reads: health %s, mana %s, incoming heals API %s"):format(
		S.readable and (tostring(S.hp) .. "/" .. tostring(S.hpMax)) or "|cffff5050refused|r",
		(S.mp and S.mpMax) and (tostring(S.mp) .. "/" .. tostring(S.mpMax)) or "|cffff5050refused|r",
		YesNo(UnitGetIncomingHeals)))
	Print(("  auras legible right now: %s (estimating: %s)"):format(YesNo(not Blind()), YesNo(Blind())))
	local st = S.stats
	Print(("  health samples %d, gains %d -> %d too small, %d your own, %d refills, %d counted as somebody's heal, %d runs"):format(
		st.samples, st.gains, st.small, st.mine, st.refills, st.heals, st.runs))
	local hot = S.hot
	if hot.active then
		Print(("  estimate: %s, period %.2fs, last tick %.1fs ago, about %s left"):format(
			tostring(hot.name), hot.period or 0, GetTime() - (hot.lastTick or 0), ns.FormatTime(max(0, (hot.expires or 0) - GetTime()))))
	else
		Print("  estimate: nothing running")
	end
	local kind, line = self:Incoming()
	Print(("  incoming says: [%s] %s"):format(kind, line))
	for _, row in ipairs(ns.HOTS or {}) do
		local ids = ns.Ranks(row.name)
		local n = 0
		if ids then for _ in pairs(ids) do n = n + 1 end end
		local st2 = ns.rankState and ns.rankState[row.name]
		Print(("  %s: %d ranks this client knows%s"):format(row.name, n,
			st2 and (", %d dropped, %d still unknown after %d tries"):format(st2.dropped, st2.pending, st2.tries) or ""))
	end
	Print(("  sounds: applied %d, lapsed %d, estimate %d, ready %d; %s ids handed to the game"):format(
		p.sndApplied or 0, p.sndLapsed or 0, p.sndEstimate or 0, p.sndReady or 0, tostring(S.soundIds or 0)))
	local group
	for _, g in ipairs((ns.profile and ns.profile.groups) or {}) do if g.lifetapHots then group = g end end
	Print("  the game-drawn heals group: " .. (group and (tostring(#group.trackers) .. " trackers") or "not made yet, /auraledger lifetap setup"))
end
