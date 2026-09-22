-- Aura Ledger display: the tracker groups on screen. Every group is a plain (non-secure) frame, so it
-- may show, hide and re-layout in combat. While unlocked every tracker is shown as a preview and the
-- groups can be dragged; dropping a lone tracker (or a Shift-dragged one) on another group joins it.

local ADDON, ns = ...
local Display = {}
ns.Display = Display

local QUESTION = ns.QUESTION
local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local ANCHOR = { RIGHT = "TOPLEFT", DOWN = "TOPLEFT", LEFT = "TOPRIGHT", UP = "BOTTOMLEFT" }
ns.GROWS = { { "RIGHT", "Right" }, { "LEFT", "Left" }, { "DOWN", "Down" }, { "UP", "Up" } }

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil

local active = {}   -- group uid -> frame
local pool = {}     -- released group frames
local ready = false

-- ------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------
function Display:IsUnlocked()
	if not ns.db then return false end
	if ns.db.unlocked then return true end
	local win = ns.UI and ns.UI.frame
	return win and win:IsShown() and true or false
end

local function CursorUI()
	local cx, cy = GetCursorPosition()
	local s = UIParent:GetEffectiveScale() or 1
	if s == 0 then s = 1 end
	return (cx or 0) / s, (cy or 0) / s
end
Display.CursorUI = CursorUI

function ns.FormatTime(sec)
	if sec >= 3600 then return ("%dh"):format(floor(sec / 3600 + 0.5)) end
	if sec >= 60 then return ("%dm"):format(floor(sec / 60 + 0.5)) end
	if sec >= 10 then return ("%d"):format(floor(sec + 0.5)) end
	return ("%.1f"):format(sec)
end

local DISPEL_COLORS = {
	Magic = { 0.2, 0.6, 1 }, Curse = { 0.6, 0, 1 }, Disease = { 0.6, 0.4, 0 }, Poison = { 0, 0.6, 0 },
	none = { 0.8, 0, 0 },
}
ns.DISPEL_COLORS = DISPEL_COLORS

-- Skin: the look of the trackers is copied off the client's own frames at runtime, so it is the
-- real Forever art rather than a guess at it. In order: a Cooldown Manager tracked-buff bar (a live
-- one, or one built from Blizzard's template), then the cast bar, then named atlases, then the
-- classic cast bar files, then a plain bar with the tooltip border. "/auraledger debug" says which.
-- ------------------------------------------------------------------
local function HasAtlas(atlas)
	return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) ~= nil
end

local function FileExists(path)
	if not GetFileIDFromPath then return false end
	local ok, id = pcall(GetFileIDFromPath, path)
	return ok and id ~= nil and id ~= 0
end

local function IsA(obj, kind)
	return obj and obj.GetObjectType and obj:GetObjectType() == kind
end

-- What a texture is drawn with: atlas or file, coords, blend, tint, layer.
local function DescribeTexture(tex)
	local d = {}
	local ok, atlas = pcall(tex.GetAtlas, tex)
	if ok and atlas and atlas ~= "" then
		d.atlas = atlas
	else
		local okt, file = pcall(tex.GetTexture, tex)
		if not okt or file == nil or file == "" then return nil end
		d.file = file
		local okc, ulx, uly, llx, lly, urx = pcall(tex.GetTexCoord, tex)
		if okc and ulx and urx and lly then d.coords = { ulx, urx, uly, lly } end
	end
	local okb, blend = pcall(tex.GetBlendMode, tex)
	if okb and blend then d.blend = blend end
	local okv, r, g, b, a = pcall(tex.GetVertexColor, tex)
	if okv and r then d.color = { r, g, b, a or 1 } end
	local okl, layer, sub = pcall(tex.GetDrawLayer, tex)
	if okl and layer then d.layer, d.sub = layer, sub or 0 end
	local oka, alpha = pcall(tex.GetAlpha, tex)
	if oka and alpha then d.alpha = alpha end
	if tex.IsShown and not tex:IsShown() then d.hidden = true end
	return d
end

local function ApplyTexture(tex, d)
	if d.atlas then
		tex:SetAtlas(d.atlas)
	else
		tex:SetTexture(d.file)
		if d.coords then tex:SetTexCoord(d.coords[1], d.coords[2], d.coords[3], d.coords[4]) end
	end
	if d.blend then tex:SetBlendMode(d.blend) end
	if d.color then tex:SetVertexColor(d.color[1], d.color[2], d.color[3], d.color[4]) end
	if d.alpha then tex:SetAlpha(d.alpha) end
	if d.layer and tex.SetDrawLayer then tex:SetDrawLayer(d.layer, d.sub or 0) end
end

-- Where a region sits relative to the frame it is anchored to, as fractions of that frame's height
-- so it can be redrawn at any size. Stretched regions get overhangs past each edge; small regions
-- anchored by one point keep their size and side.
local function Geometry(region, ref)
	local rw, rh = ref:GetSize()
	if not rw or rw <= 0 or not rh or rh <= 0 then return end
	local n = region:GetNumPoints() or 0
	if n == 0 then return end
	local w, h = region:GetSize()
	w, h = w or 0, h or 0
	local l, r, t, b
	local single
	for i = 1, n do
		local p, rel, rp, x, y = region:GetPoint(i)
		if not p then return end
		if rel ~= nil and rel ~= ref then return end
		if rel == nil and region:GetParent() ~= ref then return end
		x, y, rp = x or 0, y or 0, rp or p
		local ax = (rp:find("LEFT") and 0) or (rp:find("RIGHT") and rw) or rw / 2
		local ay = (rp:find("TOP") and 0) or (rp:find("BOTTOM") and -rh) or -rh / 2
		ax, ay = ax + x, ay + y
		if n == 1 then single = { p = p, rp = rp, x = x, y = y } end
		if p:find("LEFT") then l = ax elseif p:find("RIGHT") then r = ax elseif w > 0 then l, r = ax - w / 2, ax + w / 2 end
		if p:find("TOP") then t = ay elseif p:find("BOTTOM") then b = ay elseif h > 0 then t, b = ay + h / 2, ay - h / 2 end
	end
	if l and not r and w > 0 then r = l + w end
	if r and not l and w > 0 then l = r - w end
	if t and not b and h > 0 then b = t - h end
	if b and not t and h > 0 then t = b + h end
	if not (l and r and t and b) then return end
	if single and (r - l) < rw * 0.6 then
		return { fixed = true, p = single.p, rp = single.rp, x = single.x / rh, y = single.y / rh, w = w / rh, h = h / rh }
	end
	return { l = -l / rh, r = (r - rw) / rh, t = t / rh, b = -(b + rh) / rh }
end

local function ApplyGeometry(tex, geo, ref, H)
	tex:ClearAllPoints()
	if geo.fixed then
		tex:SetSize(max(1, geo.w * H), max(1, geo.h * H))
		tex:SetPoint(geo.p, ref, geo.rp, geo.x * H, geo.y * H)
	else
		tex:SetPoint("TOPLEFT", ref, "TOPLEFT", -geo.l * H, geo.t * H)
		tex:SetPoint("BOTTOMRIGHT", ref, "BOTTOMRIGHT", geo.r * H, -geo.b * H)
	end
end

-- Every visible texture on "frame" placed relative to "ref", except "skip".
local function Collect(frame, ref, skip, into, under)
	if not frame or not frame.GetRegions then return end
	for _, region in ipairs({ frame:GetRegions() }) do
		if region ~= skip and IsA(region, "Texture") then
			local d = DescribeTexture(region)
			if d and not d.hidden then
				local geo = Geometry(region, ref)
				if geo then
					d.geo = geo
					d.under = under or d.layer == "BACKGROUND" or d.layer == "BORDER"
					into[#into + 1] = d
				end
			end
		end
	end
end

local function DescribeFont(fs, ref)
	if not IsA(fs, "FontString") then return end
	local ok, file, size, flags = pcall(fs.GetFont, fs)
	if not ok or not file or not size or size <= 0 then return end
	local _, rh = ref:GetSize()
	if not rh or rh <= 0 then return end
	local d = { file = file, size = size / rh, flags = flags }
	local okc, r, g, b = pcall(fs.GetTextColor, fs)
	if okc and r then d.color = { r, g, b } end
	if (fs:GetNumPoints() or 0) >= 1 then
		local p, rel, rp, x, y = fs:GetPoint(1)
		if p and (rel == nil or rel == ref) then d.p, d.rp, d.x, d.y = p, rp or p, (x or 0) / rh, (y or 0) / rh end
	end
	return d
end

local function FindStatusBar(frame, depth)
	if not frame or depth > 4 then return end
	if IsA(frame, "StatusBar") then return frame end
	if frame.GetChildren then
		for _, child in ipairs({ frame:GetChildren() }) do
			local sb = FindStatusBar(child, depth + 1)
			if sb then return sb end
		end
	end
end

-- The icon texture and the frame its overlay art hangs on.
local function FindIcon(frame)
	local ic = frame and frame.Icon
	if IsA(ic, "Texture") then return ic, frame end
	if ic then
		if IsA(ic.Icon, "Texture") then return ic.Icon, ic end
		if ic.GetRegions then
			for _, r in ipairs({ ic:GetRegions() }) do if IsA(r, "Texture") then return r, ic end end
		end
	end
end

local function FindStrings(bar)
	local name, dur = bar.Name, bar.Duration or bar.Timer
	if not (IsA(name, "FontString") and IsA(dur, "FontString")) then
		for _, r in ipairs({ bar:GetRegions() }) do
			if IsA(r, "FontString") then
				local p = r:GetPoint(1)
				if p and p:find("LEFT") and not IsA(name, "FontString") then name = r
				elseif p and p:find("RIGHT") and not IsA(dur, "FontString") then dur = r end
			end
		end
	end
	return name, dur
end

local function SkinFromDonor(root, sourceName)
	local bar = FindStatusBar(root, 0)
	if not bar then return end
	local fillTex = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
	local fill = fillTex and DescribeTexture(fillTex)
	if not fill then return end
	local _, rh = bar:GetSize()
	if not rh or rh <= 0 then return end
	fill.color, fill.layer = nil, nil
	local s = { source = sourceName, fill = fill, decor = {}, iconDecor = {} }
	if root ~= bar then Collect(root, bar, nil, s.decor, true) end
	local mid = bar:GetParent()
	if mid and mid ~= root and mid ~= UIParent then Collect(mid, bar, nil, s.decor, true) end
	Collect(bar, bar, fillTex, s.decor, false)
	local nameFS, durFS = FindStrings(bar)
	s.nameFont, s.durFont = DescribeFont(nameFS, bar), DescribeFont(durFS, bar)
	local iconTex, iconFrame = FindIcon(root)
	if iconTex and iconFrame then
		local ok, ulx, uly, llx, lly, urx = pcall(iconTex.GetTexCoord, iconTex)
		if ok and ulx and urx and lly then s.iconCoords = { ulx, urx, uly, lly } end
		Collect(iconFrame, iconFrame, iconTex, s.iconDecor, false)
		if iconFrame.GetChildren then
			for _, child in ipairs({ iconFrame:GetChildren() }) do Collect(child, iconFrame, nil, s.iconDecor, false) end
		end
	end
	return s
end

-- A Cooldown Manager item to copy from: a live one from the viewer, else one made from the template.
-- Only LIVE frames are read. Building a frame from one of Blizzard's internal templates runs its
-- setup code under this addon's taint, which this client answers with "blocked from an action only
-- available to the Blizzard UI".
local function ViewerDonor(viewer)
	if not viewer or not viewer.GetChildren then return end
	for _, child in ipairs({ viewer:GetChildren() }) do
		if FindStatusBar(child, 0) or FindIcon(child) then return child end
	end
end

local skin
local function BuildSkin()
	if skin then return skin end
	local s
	local donor = ViewerDonor(BuffBarCooldownViewer)
	if donor then s = SkinFromDonor(donor, "Cooldown Manager bar (live)") end
	if not s then
		local cb = PlayerCastingBarFrame or CastingBarFrame
		if cb then s = SkinFromDonor(cb, "cast bar (" .. (cb:GetName() or "?") .. ")") end
	end
	if not s and HasAtlas("ui-castingbar-frame") and HasAtlas("ui-castingbar-filling-standard") then
		s = { source = "cast bar atlases", fill = { atlas = "ui-castingbar-filling-standard" }, decor = {}, iconDecor = {} }
		if HasAtlas("ui-castingbar-background") then
			s.decor[1] = { atlas = "ui-castingbar-background", under = true, geo = { l = 0.1, r = 0.1, t = 0.1, b = 0.1 } }
		end
		s.decor[#s.decor + 1] = { atlas = "ui-castingbar-frame", geo = { l = 0.5, r = 0.5, t = 0.6, b = 0.6 } }
	end
	if not s and FileExists("Interface\\CastingBar\\UI-CastingBar-Border") then
		s = { source = "classic cast bar files", fill = { file = BAR_TEXTURE, coords = { 0, 1, 0, 1 } }, decor = {}, iconDecor = {}, tint = true }
		s.decor[1] = { file = "Interface\\CastingBar\\UI-CastingBar-Border", geo = { l = 30.5 / 13, r = 30.5 / 13, t = 28 / 13, b = 23 / 13 } }
	end
	if not s then
		s = { source = "plain (tooltip border)", fill = { file = BAR_TEXTURE, coords = { 0, 1, 0, 1 } }, decor = {}, iconDecor = {}, tint = true, backdrop = true }
	end
	-- Icon art: the Cooldown Manager's icon items have their own overlay; borrow it for icon style.
	local iconDonor = ViewerDonor(EssentialCooldownViewer) or ViewerDonor(UtilityCooldownViewer) or ViewerDonor(BuffIconCooldownViewer)
	if iconDonor then
		local iconTex, iconFrame = FindIcon(iconDonor)
		if iconTex and iconFrame then
			s.soloIconDecor = {}
			Collect(iconFrame, iconFrame, iconTex, s.soloIconDecor, false)
			if iconFrame.GetChildren then
				for _, child in ipairs({ iconFrame:GetChildren() }) do Collect(child, iconFrame, nil, s.soloIconDecor, false) end
			end
			local ok, ulx, uly, llx, lly, urx = pcall(iconTex.GetTexCoord, iconTex)
			if ok and ulx and urx and lly then s.soloIconCoords = { ulx, urx, uly, lly } end
			s.iconSource = "Cooldown Manager icon"
		end
	end
	-- Resolve the fill to a file + coords so it can be cropped as it drains.
	if s.fill.atlas then
		s.fillAtlas = s.fill.atlas
		local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(s.fill.atlas)
		if info and info.file then
			s.fill = { file = info.file, coords = { info.leftTexCoord or 0, info.rightTexCoord or 1, info.topTexCoord or 0, info.bottomTexCoord or 1 }, blend = s.fill.blend }
		else
			s.fill.stretch = true
		end
	elseif not s.fill.coords then
		s.fill.coords = { 0, 1, 0, 1 }
	end
	-- Tinting: a file fill from the old art needs colour; copied art is already coloured.
	if s.tint == nil then s.tint = false end
	ns.report["bar skin"] = s.source .. (", " .. #s.decor .. " art pieces")
	ns.report["icon skin"] = s.iconSource and (s.iconSource .. ", " .. #s.soloIconDecor .. " art pieces") or (#s.iconDecor > 0 and ("from the bar donor, " .. #s.iconDecor .. " art pieces") or "none (default buff frame look)")
	skin = s
	return s
end
Display.BuildSkin = BuildSkin

-- ------------------------------------------------------------------
-- Tracker widgets
-- ------------------------------------------------------------------
local function WidgetTooltip(w)
	local t = w.tracker
	if not t then return end
	GameTooltip:SetOwner(w, "ANCHOR_RIGHT")
	local shown = false
	if t.id and GameTooltip.SetSpellByID then
		shown = pcall(GameTooltip.SetSpellByID, GameTooltip, t.id) and GameTooltip:NumLines() > 0
	end
	if not shown then GameTooltip:SetText(t.name or ("Spell " .. tostring(t.id)), 1, 1, 1) end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Drag: move the group", 0.7, 0.7, 0.7)
	GameTooltip:AddLine("Drag onto another tracker: group them", 0.7, 0.7, 0.7)
	GameTooltip:AddLine("Shift-drag: pull this one out, reorder, or move it to another group", 0.7, 0.7, 0.7)
	GameTooltip:AddLine("Click: options", 0.7, 0.7, 0.7)
	GameTooltip:Show()
end

-- Draws a list of copied art pieces on the under / over frames, relative to ref at height H.
-- want(d) says whether a piece is wanted; pieces "under" the fill are background, the rest border.
local function PlaceDecor(w, list, key, ref, H, want)
	local pool = w[key]
	for i, d in ipairs(list) do
		local tex = pool[i]
		if not tex then
			tex = (d.under and w.under or w.over):CreateTexture(nil, d.layer or "ARTWORK")
			pool[i] = tex
			ApplyTexture(tex, d)
		end
		ApplyGeometry(tex, d.geo, ref, H)
		tex:SetShown(not want or want(d))
	end
	for i = #list + 1, #pool do pool[i]:Hide() end
end

local function ApplyFont(fs, d, H, fallbackPx)
	if d then
		fs:SetFont(d.file, max(7, floor(d.size * H + 0.5)), d.flags or "")
		if d.color then fs:SetTextColor(d.color[1], d.color[2], d.color[3]) end
	else
		fs:SetFont(FONT, fallbackPx, "OUTLINE")
	end
end

local function SetFill(w, frac)
	local s = skin
	frac = max(0, min(1, frac or 0))
	local width = (w.bar:GetWidth() or 0) * frac
	w.fill:SetWidth(max(0.01, width))
	if s.fill.coords and not s.fill.stretch then
		local c = s.fill.coords
		w.fill:SetTexCoord(c[1], c[1] + (c[2] - c[1]) * frac, c[3], c[4])
	end
	w.fill:SetShown(frac > 0)
	w.fillFrac = frac
end

local function CreateWidget(parent)
	local s = BuildSkin()
	local w = CreateFrame("Button", nil, parent)
	w:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	w:RegisterForDrag("LeftButton")
	w.decor, w.iconArt = {}, {}

	-- Art copied from the donor goes on these: "under" sits below the fill and icon, "over" above.
	w.under = CreateFrame("Frame", nil, w)
	w.under:SetAllPoints()
	w.under:SetFrameLevel(max(0, w:GetFrameLevel() - 1))
	w.under:EnableMouse(false)

	w.icon = w:CreateTexture(nil, "ARTWORK")
	w.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	-- The default buff frame's debuff border, tinted by dispel type (or red for "missing").
	w.border = w:CreateTexture(nil, "OVERLAY")
	w.border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
	w.border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
	w.border:SetPoint("TOPLEFT", w.icon, "TOPLEFT", -1, 1)
	w.border:SetPoint("BOTTOMRIGHT", w.icon, "BOTTOMRIGHT", 1, -1)
	w.border:Hide()

	local ok, cd = pcall(CreateFrame, "Cooldown", nil, w, "CooldownFrameTemplate")
	if ok and cd then
		ns.report["cooldown swipe"] = "CooldownFrameTemplate"
		cd:SetAllPoints(w.icon)
		if cd.SetReverse then cd:SetReverse(true) end
		if cd.SetDrawEdge then cd:SetDrawEdge(false) end
		if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
		cd.noCooldownCount = true
		if cd.EnableMouse then cd:EnableMouse(false) end
		w.cd = cd
	else
		ns.report["cooldown swipe"] = "missing"
	end

	-- The bar: a plain frame holding the fill texture (cropped as it drains, like the donor's).
	local bar = CreateFrame("Frame", nil, w)
	bar:SetFrameLevel(w:GetFrameLevel() + 1)
	bar:EnableMouse(false)
	bar.bg = bar:CreateTexture(nil, "BACKGROUND")
	bar.bg:SetAllPoints()
	bar.bg:SetColorTexture(0, 0, 0, (#s.decor > 0) and 0.25 or 0.55)
	w.fill = bar:CreateTexture(nil, "ARTWORK")
	w.fill:SetPoint("TOPLEFT")
	w.fill:SetPoint("BOTTOMLEFT")
	if s.fill.stretch then
		w.fill:SetAtlas(s.fill.atlas)
	else
		w.fill:SetTexture(s.fill.file)
	end
	if s.fill.blend then w.fill:SetBlendMode(s.fill.blend) end
	bar.spark = bar:CreateTexture(nil, "OVERLAY")
	bar.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
	bar.spark:SetBlendMode("ADD")
	bar.spark:SetWidth(16)
	bar.spark:Hide()
	bar:Hide()
	w.bar = bar

	w.over = CreateFrame("Frame", nil, w)
	w.over:SetAllPoints()
	w.over:SetFrameLevel(w:GetFrameLevel() + 3)
	w.over:EnableMouse(false)
	if s.backdrop then
		local okb, edge = pcall(CreateFrame, "Frame", nil, w.over, "BackdropTemplate")
		if okb and edge and edge.SetBackdrop then w.edge = edge end
	end

	-- Text sits above everything.
	local overlay = CreateFrame("Frame", nil, w)
	overlay:SetAllPoints(w)
	overlay:SetFrameLevel(w:GetFrameLevel() + 5)
	overlay:EnableMouse(false)
	w.overlay = overlay
	w.time = overlay:CreateFontString(nil, "OVERLAY")
	w.time:SetFont(FONT, 14, "OUTLINE")
	w.time:SetTextColor(1, 0.95, 0.6)
	w.count = overlay:CreateFontString(nil, "OVERLAY")
	w.count:SetFont(FONT, 11, "OUTLINE")
	w.name = overlay:CreateFontString(nil, "OVERLAY")
	w.name:SetFont(FONT, 11, "OUTLINE")
	w.name:SetJustifyH("LEFT")
	w.name:SetWordWrap(false)
	w.duration = overlay:CreateFontString(nil, "OVERLAY")
	w.duration:SetFont(FONT, 11, "OUTLINE")
	w.duration:SetJustifyH("RIGHT")
	-- Shown while the state is carried or estimated because the client is hiding auras.
	w.stale = overlay:CreateTexture(nil, "OVERLAY")
	w.stale:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
	w.stale:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	w.stale:Hide()

	-- The action-button hover glow, on the icon only so a whole bar is not washed out.
	w:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	local glow = w:GetHighlightTexture()
	if glow then glow:ClearAllPoints() glow:SetAllPoints(w.icon) end
	w:SetScript("OnEnter", WidgetTooltip)
	w:SetScript("OnLeave", function() GameTooltip:Hide() end)
	w:SetScript("OnClick", function(self)
		if not self.tracker then return end
		ns.selected = { group = self.group, tracker = self.tracker }
		if ns.UI and ns.UI.ShowSelection then ns.UI:ShowSelection(true) end
	end)
	w:SetScript("OnDragStart", function(self) Display:WidgetDragStart(self) end)
	w:SetScript("OnDragStop", function(self) Display:WidgetDragStop(self) end)
	return w
end

local function ConfigureWidget(w, g)
	local key = g.style .. ":" .. g.size .. ":" .. g.barW .. ":" .. g.barH .. ":" .. tostring(g.border ~= false) .. tostring(g.background ~= false) .. tostring(g.iconFrame ~= false)
	local wantBar = function(d) if d.under then return g.background ~= false else return g.border ~= false end end
	local wantIcon = function() return g.iconFrame ~= false end
	if w.configured == key then return end
	w.configured = key
	local s = skin
	w.icon:ClearAllPoints()
	w.time:ClearAllPoints()
	w.count:ClearAllPoints()
	w.stale:ClearAllPoints()
	w.name:ClearAllPoints()
	w.duration:ClearAllPoints()
	if g.style == "bars" then
		local H = g.barH
		w:SetSize(g.barW, H)
		w.icon:SetPoint("TOPLEFT")
		w.icon:SetSize(H, H)
		local c = s.iconCoords or { 0.07, 0.93, 0.07, 0.93 }
		w.icon:SetTexCoord(c[1], c[2], c[3], c[4])
		w.bar:ClearAllPoints()
		w.bar:SetPoint("TOPLEFT", w.icon, "TOPRIGHT", 2, 0)
		w.bar:SetPoint("BOTTOMRIGHT")
		w.bar:Show()
		PlaceDecor(w, s.decor, "decor", w.bar, H, wantBar)
		PlaceDecor(w, s.iconDecor, "iconArt", w.icon, H, wantIcon)
		w.bar.bg:SetAlpha(g.background ~= false and 1 or 0)
		if w.edge then
			local edgeSize = max(8, min(16, floor(H * 0.6)))
			w.edge:ClearAllPoints()
			w.edge:SetPoint("TOPLEFT", w.bar, "TOPLEFT", -2, 2)
			w.edge:SetPoint("BOTTOMRIGHT", w.bar, "BOTTOMRIGHT", 2, -2)
			w.edge:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = edgeSize })
			w.edge:SetBackdropBorderColor(0.9, 0.8, 0.5)
			w.edge:SetShown(g.border ~= false)
		end
		w.bar.spark:SetHeight(H * 1.8)
		local px = max(8, min(14, floor(H * 0.52)))
		ApplyFont(w.name, s.nameFont, H, px)
		ApplyFont(w.duration, s.durFont, H, px)
		-- Text sits on the vertical middle; only the donor's horizontal inset is kept (its anchors
		-- are relative to a frame taller than its visible fill, so its y offsets do not carry over).
		local dx = (s.durFont and s.durFont.p and s.durFont.p:find("RIGHT") and s.durFont.x * H) or -4
		w.duration:SetPoint("RIGHT", w.bar, "RIGHT", min(-2, dx), 0)
		local nx = (s.nameFont and s.nameFont.p and s.nameFont.p:find("LEFT") and s.nameFont.x * H) or 4
		w.name:SetPoint("LEFT", w.bar, "LEFT", max(2, nx), 0)
		w.name:SetPoint("RIGHT", w.duration, "LEFT", -4, 0)
		w.name:Show()
		w.duration:Show()
		w.time:Hide()
		w.count:SetFont(FONT, max(7, floor(H * 0.45)), "OUTLINE")
		w.count:SetPoint("BOTTOMRIGHT", w.icon, "BOTTOMRIGHT", -1, 1)
		w.stale:SetSize(max(7, H * 0.34), max(7, H * 0.34))
		w.stale:SetPoint("BOTTOMLEFT", w.icon, "BOTTOMLEFT", 1, 1)
	else
		local S = g.size
		w:SetSize(S, S)
		w.icon:SetAllPoints(w)
		local c = s.soloIconCoords or s.iconCoords or { 0.07, 0.93, 0.07, 0.93 }
		w.icon:SetTexCoord(c[1], c[2], c[3], c[4])
		w.bar:Hide()
		PlaceDecor(w, {}, "decor", w.bar, S)
		PlaceDecor(w, s.soloIconDecor or s.iconDecor, "iconArt", w.icon, S, wantIcon)
		if w.edge then w.edge:Hide() end
		w.name:Hide()
		w.duration:Hide()
		w.time:Show()
		w.time:SetFont(FONT, max(8, floor(S * 0.4)), "OUTLINE")
		w.time:SetPoint("CENTER", w.icon, "CENTER", 0, 0)
		w.count:SetFont(FONT, max(7, floor(S * 0.3)), "OUTLINE")
		w.count:SetPoint("BOTTOMRIGHT", w.icon, "BOTTOMRIGHT", -1, 1)
		w.stale:SetSize(max(7, S * 0.26), max(7, S * 0.26))
		w.stale:SetPoint("BOTTOMLEFT", w.icon, "BOTTOMLEFT", 1, 1)
	end
end

local function TintFill(w, kind, missing)
	if missing then
		w.fill:SetVertexColor(0.55, 0.2, 0.2)
	elseif skin.tint then
		if kind == "debuff" then w.fill:SetVertexColor(0.85, 0.22, 0.2) else w.fill:SetVertexColor(0.25, 0.6, 1) end
	elseif kind == "debuff" then
		w.fill:SetVertexColor(1, 0.45, 0.45)
	else
		w.fill:SetVertexColor(1, 1, 1)
	end
end

local function PaintWidget(w, g, t, entry, preview, expiring)
	w.tracker, w.group, w.entry, w.expiring = t, g, entry, expiring
	ConfigureWidget(w, g)
	w.icon:SetTexture((entry and entry.icon) or t.icon or QUESTION)
	local isActive = entry ~= nil
	local flagMissing = (not isActive) and (t.show ~= "active")
	if w.icon.SetDesaturated then w.icon:SetDesaturated(not isActive) end
	if isActive then
		w.icon:SetVertexColor(1, 1, 1)
		w.icon:SetAlpha(1)
	elseif flagMissing then
		w.icon:SetVertexColor(1, 0.35, 0.35)
		w.icon:SetAlpha(1)
	else
		w.icon:SetVertexColor(0.7, 0.7, 0.7)
		w.icon:SetAlpha(preview and 0.75 or 1)
	end

	if expiring then
		w.border:SetVertexColor(1, 0.1, 0.1)
		w.border:Show()
	elseif isActive and entry.kind == "debuff" then
		local c = DISPEL_COLORS[entry.dispel or "none"] or DISPEL_COLORS.none
		w.border:SetVertexColor(c[1], c[2], c[3])
		w.border:Show()
	elseif flagMissing then
		w.border:SetVertexColor(1, 0.1, 0.1)
		w.border:Show()
	else
		w.border:Hide()
	end

	local timed = isActive and entry.duration > 0 and entry.expires > 0
	if w.cd then
		if timed and g.style ~= "bars" then
			w.cd:SetCooldown(entry.expires - entry.duration, entry.duration)
			w.cd:Show()
		else
			if w.cd.Clear then w.cd:Clear() end
			w.cd:Hide()
		end
	end
	w.count:SetText((isActive and entry.count and entry.count > 1) and entry.count or "")
	w.stale:SetShown(g.watch ~= false and isActive and (entry.stale or entry.estimated) and true or false)

	if g.style == "bars" then
		if w.edge then
			if flagMissing then w.edge:SetBackdropBorderColor(1, 0.25, 0.25) else w.edge:SetBackdropBorderColor(0.9, 0.8, 0.5) end
		end
		local label = (t.label and t.label ~= "" and t.label) or (entry and entry.name) or t.name or ("Spell " .. tostring(t.id))
		w.name:SetText(g.names ~= false and label or "")
		if isActive then
			TintFill(w, entry.kind, false)
			if not timed then
				SetFill(w, 1)
				w.duration:SetText("")
				w.bar.spark:Hide()
			end
		else
			TintFill(w, nil, true)
			SetFill(w, flagMissing and 1 or 0)
			w.duration:SetText(flagMissing and "Missing" or "")
			w.bar.spark:Hide()
		end
	elseif not timed then
		w.time:SetText("")
	end
	w.timed = timed
end

local function TickWidget(w, g, now)
	if not w.timed or not w.entry then return end
	local e = w.entry
	local rem = max(0, e.expires - now)
	local text = g.timers ~= false and ((e.estimated and "~" or "") .. ns.FormatTime(rem)) or ""
	if g.style == "bars" then
		local frac = e.duration > 0 and min(1, rem / e.duration) or 1
		SetFill(w, frac)
		w.duration:SetText(text)
		local width = w.bar:GetWidth() or 0
		if frac > 0 and frac < 1 and width > 0 and #skin.decor == 0 then
			w.bar.spark:ClearAllPoints()
			w.bar.spark:SetPoint("CENTER", w.bar, "LEFT", width * frac, 0)
			w.bar.spark:Show()
		else
			w.bar.spark:Hide()
		end
	else
		w.time:SetText(text)
	end
end

-- ------------------------------------------------------------------
-- ------------------------------------------------------------------
-- Group frames
-- ------------------------------------------------------------------
-- ------------------------------------------------------------------
-- Groups drawn by the game. Blizzard's AuraContainer shows the auras matching a filter and keeps
-- them current in combat, where the addon itself cannot see them. It hands each button the
-- icon, countdown and stack count; we give it the size, spacing, art and place. The buttons are
-- forbidden frames: nothing is read back from them and no scripts are set on them.
-- ------------------------------------------------------------------
local liveMethodsLogged = false

local function LiveKey(g)
	local ids = ""
	if g.liveOnlyMine then for _, t in ipairs(g.trackers) do ids = ids .. tostring(t.id or t.name) .. "," end end
	return (g.live or "") .. ":" .. g.size .. ":" .. g.spacing .. ":" .. (g.perRow or 8) .. ":" .. tostring(g.iconFrame ~= false) .. ":" .. ids
end

local function InitLiveButton(g)
	return function(button)
		if not button then return end
		local s = BuildSkin()
		local S = g.size
		pcall(button.SetSize, button, S, S)
		local icon = button:CreateTexture(nil, "ARTWORK")
		icon:SetAllPoints(button)
		local c = s.soloIconCoords or s.iconCoords or { 0.07, 0.93, 0.07, 0.93 }
		icon:SetTexCoord(c[1], c[2], c[3], c[4])
		pcall(button.SetIcon, button, icon)
		local time = button:CreateFontString(nil, "OVERLAY")
		time:SetFont(FONT, max(8, floor(S * 0.4)), "OUTLINE")
		time:SetPoint("CENTER", button, "CENTER", 0, 0)
		if g.timers ~= false then pcall(button.SetDurationText, button, time) end
		local count = button:CreateFontString(nil, "OVERLAY")
		count:SetFont(FONT, max(7, floor(S * 0.3)), "OUTLINE")
		count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
		pcall(button.SetApplicationCount, button, count)
		-- The game's own swipe over the icon, and a dispel-type coloured border like the debuff frame's.
		local okC, cd = pcall(CreateFrame, "Cooldown", nil, button, "CooldownFrameTemplate")
		if okC and cd then
			cd:SetAllPoints(icon)
			if cd.SetReverse then cd:SetReverse(true) end
			if cd.SetDrawEdge then cd:SetDrawEdge(false) end
			if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
			cd.noCooldownCount = true
			pcall(button.SetDurationCooldown, button, cd)
		end
		local border = button:CreateTexture(nil, "OVERLAY")
		border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
		border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
		border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
		border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
		pcall(button.AddDispelTypeTexture, button, border)
		pcall(button.SetHideTooltipInCombat, button, false)
		if g.iconFrame ~= false then
			local w = { under = button, over = button, decor = {}, iconArt = {} }
			PlaceDecor(w, s.soloIconDecor or s.iconDecor, "iconArt", icon, S)
		end
		pcall(button.SetMouseMotionEnabled, button, true)
		pcall(button.SetTooltipAnchor, button, "ANCHOR_RIGHT")
		if not liveMethodsLogged and ns.LogLine then
			liveMethodsLogged = true
			local names = {}
			pcall(function()
				local idx = getmetatable(button) and getmetatable(button).__index
				if type(idx) == "table" then
					for k in pairs(idx) do
						if type(k) == "string" and k:find("Icon") or k:find("Duration") or k:find("Count") or k:find("Dispel") or k:find("Caster") or k:find("Tooltip") or k:find("Name") or k:find("Bar") or k:find("Aura") then names[#names + 1] = k end
					end
				end
			end)
			table.sort(names)
			ns.LogLine("game-drawn button methods: " .. table.concat(names, ", "))
		end
	end
end

-- Builds (or rebuilds) the container for a live group. Not possible in combat: returns nil then
-- and is tried again on the next refresh.
local function EnsureLive(f, g)
	local key = LiveKey(g)
	if f.live and f.liveKey == key then return f.live end
	if InCombatLockdown and InCombatLockdown() then return f.live end
	if f.live then
		f.live:Hide()
		f.live:ClearAllPoints()
		f.live = nil
	end
	local ok, c = pcall(CreateFrame, "AuraContainer", nil, f, "CustomAuraContainerTemplate")
	if not (ok and c) then
		ns.report["game-drawn groups"] = "AuraContainer not available: " .. tostring(c)
		return nil
	end
	local S, sp, perRow = g.size, g.spacing, max(1, g.perRow or 8)
	c:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
	c:SetSize(perRow * (S + sp) - sp, 3 * (S + sp) - sp)
	c:SetFrameLevel(f:GetFrameLevel() + 1)
	local settings = {
		maxFrameCount = perRow * 3,
		initializeFrame = InitLiveButton(g),
		layout = { elementWidth = S, elementHeight = S, elementSpacing = sp, lineSpacing = sp, maxElementsPerLine = perRow, elementsPerLine = perRow },
	}
	-- Limiting to the group's trackers: the ids go in under every name the game might read.
	-- Whichever it honours narrows the group; the others are ignored.
	if g.liveOnlyMine then
		local ids, names = {}, {}
		for _, t in ipairs(g.trackers) do
			if t.id then ids[#ids + 1] = t.id end
			if t.name then
				names[#names + 1] = t.name
				for _, kind in ipairs({ "buff", "debuff" }) do
					local h = ns.db.history[kind .. ":" .. string.lower(t.name)]
					if h and h.ids then for id in pairs(h.ids) do ids[#ids + 1] = id end end
				end
			end
		end
		f.liveIds, f.liveNames = ids, names
	end
	local okG, err
	if c.AddAuraGroup then
		okG, err = pcall(c.AddAuraGroup, c, "al_" .. tostring(g.uid), g.live, settings)
	elseif c.AddAuraFilter then
		okG, err = pcall(c.AddAuraFilter, c, g.live, settings)
	else
		okG, err = false, "no AddAuraGroup"
	end
	if not okG then
		ns.report["game-drawn groups"] = "aura group refused: " .. tostring(err)
		c:Hide()
		return nil
	end
	if c.SetUnit then pcall(c.SetUnit, c, "player") end
	-- Limiting to the group's trackers: the candidate-filter shapes are tried in turn through the
	-- container's own setter; every answer is logged so the accepted shape can be read off.
	if g.liveOnlyMine and c.SetAuraGroupCandidateFilters and f.liveIds then
		local ids, names, gid = f.liveIds, f.liveNames, "al_" .. tostring(g.uid)
		local map = {}
		for _, id in ipairs(ids) do map[id] = true end
		local okF, err = pcall(c.SetAuraGroupCandidateFilters, c, gid, { includeSpellIDs = map })
		if ns.LogLine then ns.LogLine("candidate filters includeSpellIDs map: " .. (okF and "accepted" or ("error " .. tostring(err)))) end
	end
	c:Show()
	f.live, f.liveKey = c, key
	ns.report["game-drawn groups"] = "AuraContainer ok (" .. g.live .. ")"
	return c
end

local function LayoutLive(f, g, unlocked)
	local S, sp, perRow = g.size, g.spacing, max(1, g.perRow or 8)
	for _, widget in ipairs(f.widgets) do
		widget:Hide()
		widget.tracker, widget.entry, widget.timed = nil, nil, false
	end
	local c = EnsureLive(f, g)
	f:SetSize(perRow * (S + sp) - sp, S)
	f:SetAlpha(g.alpha or 1)
	f.chrome:SetShown(unlocked)
	if unlocked then
		f.chrome.label:SetText(ns.GroupName(g) .. " (drawn by the game)")
		local sel = ns.selected and ns.selected.group == g
		if f.chrome.SetBackdropBorderColor then
			if sel then f.chrome:SetBackdropBorderColor(0.3, 1, 0.4, 1) else f.chrome:SetBackdropBorderColor(1, 0.82, 0, 0.9) end
		end
	end
	local pass = unlocked or ns.CondPass(g.cond)
	if c then c:SetShown(pass) end
	f:SetShown(pass and (c ~= nil or unlocked))
end

-- ------------------------------------------------------------------
-- Trackers drawn by the game. An aura slot is one game-owned frame that shows a single aura
-- matching its filter and spell map, current in combat. One slot per tracker (two for "buff or
-- debuff") is anchored over the tracker's cell, drawn above the addon's own widget: while the
-- aura is on the unit the game shows the slot and covers the cell, when it is not the slot hides
-- and the cell shows the addon's "missing" art (or nothing, for "show when active").
-- ------------------------------------------------------------------
local function TrackerIds(t)
	local map, any = {}, false
	if t.id then map[t.id] = true any = true end
	if t.name and not t.matchId then
		for _, kind in ipairs({ "buff", "debuff" }) do
			local h = ns.db.history[kind .. ":" .. string.lower(t.name)]
			if h and h.ids then for id in pairs(h.ids) do map[id] = true any = true end end
		end
	end
	return any and map or nil
end

local function IdsKey(map)
	local l = {}
	for id in pairs(map) do l[#l + 1] = id end
	table.sort(l)
	return table.concat(l, ",")
end

local function SlotKey(g)
	return g.style .. ":" .. g.size .. ":" .. g.barW .. ":" .. g.barH .. ":" .. tostring(g.iconFrame ~= false) .. tostring(g.border ~= false)
		.. tostring(g.background ~= false) .. tostring(g.timers ~= false) .. tostring(g.names ~= false)
end

local BLANK = "Interface\\AddOns\\AuraLedger\\blank"

-- The game's timer direction enum: the value that makes a bar drain.
local function DrainDirection()
	local e = Enum and Enum.StatusBarTimerDirection
	if type(e) ~= "table" then return nil end
	local pick
	for k, v in pairs(e) do
		local l = string.lower(tostring(k))
		if l:find("remain") or l:find("desc") or l:find("down") or l:find("reverse") or l:find("drain") then pick = v end
	end
	if pick == nil then
		local keys = {}
		for k, v in pairs(e) do keys[#keys + 1] = tostring(k) .. "=" .. tostring(v) end
		table.sort(keys)
		ns.report["timer directions"] = table.concat(keys, ", ")
		for _, v in pairs(e) do if v ~= 0 then pick = v end end
	end
	return pick
end

-- "cover": the slot draws the aura and covers the cell (show when active / always).
-- "mask": the slot is invisible and carries a transparent mask; the addon's missing art gets that
--         mask, so it is blanked while the slot is shown and returns when the slot hides.
local function InitSlotFrame(g, mode, filter, store)
	return function(button)
		if not button then return end
		local ok, err = pcall(function()
		local s = BuildSkin()
		local bars = g.style == "bars"
		local W, H = bars and g.barW or g.size, bars and g.barH or g.size
		pcall(button.SetSize, button, W, H)
		if mode == "mask" then
			-- A 1x1 opaque mask sitting just outside the cell; with the clamp-to-black wrap everything
			-- outside it is treated as transparent, so a masked cell is blanked without needing a file.
			local mask = button:CreateMaskTexture()
			mask:SetTexture("Interface\\Buttons\\WHITE8X8", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
			mask:SetSize(1, 1)
			mask:SetPoint("BOTTOMRIGHT", button, "TOPLEFT", -4, 4)
			store.mask = mask
			return
		end
		local icon = button:CreateTexture(nil, "ARTWORK")
		local c = (bars and s.iconCoords) or s.soloIconCoords or s.iconCoords or { 0.07, 0.93, 0.07, 0.93 }
		icon:SetTexCoord(c[1], c[2], c[3], c[4])
		if bars then
			icon:SetPoint("TOPLEFT")
			icon:SetSize(H, H)
		else
			icon:SetAllPoints(button)
		end
		pcall(button.SetIcon, button, icon)
		local count = button:CreateFontString(nil, "OVERLAY")
		count:SetFont(FONT, max(7, floor(H * (bars and 0.45 or 0.3))), "OUTLINE")
		count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)
		pcall(button.SetApplicationCount, button, count)
		local border = button:CreateTexture(nil, "OVERLAY")
		border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
		border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
		border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
		border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
		pcall(button.AddDispelTypeTexture, button, border)
		if bars then
			local bar = CreateFrame("StatusBar", nil, button)
			bar:SetPoint("TOPLEFT", icon, "TOPRIGHT", 2, 0)
			bar:SetPoint("BOTTOMRIGHT")
			bar:SetFrameLevel(button:GetFrameLevel() + 1)
			-- The fill is a strip inside a sheet: the bar's texture needs the atlas (or the crop), not the sheet.
			bar:SetStatusBarTexture(s.fill.file or BAR_TEXTURE)
			local fillTex = bar:GetStatusBarTexture()
			if fillTex then
				if s.fillAtlas then
					fillTex:SetAtlas(s.fillAtlas)
				elseif s.fill.coords then
					local c2 = s.fill.coords
					fillTex:SetTexCoord(c2[1], c2[2], c2[3], c2[4])
				end
				if s.fill.blend then fillTex:SetBlendMode(s.fill.blend) end
			end
			-- The same tints the addon's own bars use, so the text stays readable on the light fill.
			if filter == "HARMFUL" then bar:SetStatusBarColor(0.85, 0.22, 0.2) else bar:SetStatusBarColor(0.25, 0.6, 1) end
			local bg = bar:CreateTexture(nil, "BACKGROUND")
			bg:SetAllPoints()
			bg:SetColorTexture(0, 0, 0, g.background ~= false and 0.55 or 0)
			local dir = DrainDirection()
			if not pcall(button.SetDurationBar, button, bar, dir ~= nil and { direction = dir } or nil) then pcall(button.SetDurationBar, button, bar) end
			local w = { under = button, over = button, decor = {}, iconArt = {} }
			PlaceDecor(w, s.decor, "decor", bar, H, function(dd) if dd.under then return g.background ~= false else return g.border ~= false end end)
			if g.iconFrame ~= false then PlaceDecor(w, s.iconDecor, "iconArt", icon, H) end
			local px = max(8, min(14, floor(H * 0.52)))
			local textHolder = CreateFrame("Frame", nil, button)
			textHolder:SetAllPoints(bar)
			textHolder:SetFrameLevel(bar:GetFrameLevel() + 2)
			local dur = textHolder:CreateFontString(nil, "OVERLAY")
			ApplyFont(dur, s.durFont, H, px)
			dur:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
			dur:SetJustifyH("RIGHT")
			dur:SetWordWrap(false)
			if g.timers ~= false then pcall(button.SetDurationText, button, dur) end
			local name = textHolder:CreateFontString(nil, "OVERLAY")
			ApplyFont(name, s.nameFont, H, px)
			name:SetPoint("LEFT", bar, "LEFT", 4, 0)
			name:SetWidth(max(10, W - H - 2 - 8 - 44))
			name:SetJustifyH("LEFT")
			name:SetWordWrap(false)
			if g.names ~= false then pcall(button.SetSpellName, button, name) end
		else
			local time = button:CreateFontString(nil, "OVERLAY")
			time:SetFont(FONT, max(8, floor(H * 0.4)), "OUTLINE")
			time:SetPoint("CENTER", icon, "CENTER", 0, 0)
			if g.timers ~= false then pcall(button.SetDurationText, button, time) end
			local okC, cd = pcall(CreateFrame, "Cooldown", nil, button, "CooldownFrameTemplate")
			if okC and cd then
				cd:SetAllPoints(icon)
				if cd.SetReverse then cd:SetReverse(true) end
				if cd.SetDrawEdge then cd:SetDrawEdge(false) end
				if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
				cd.noCooldownCount = true
				pcall(button.SetDurationCooldown, button, cd)
			end
			if g.iconFrame ~= false then
				local w = { under = button, over = button, decor = {}, iconArt = {} }
				PlaceDecor(w, s.soloIconDecor or s.iconDecor, "iconArt", icon, H)
			end
		end
		pcall(button.SetMouseMotionEnabled, button, true)
		pcall(button.SetTooltipAnchorPoint, button, "ANCHOR_RIGHT")
		pcall(button.SetHideTooltipInCombat, button, false)
		-- Opaque backing, created last so a failed setup never leaves a bare black box.
		local back = button:CreateTexture(nil, "BACKGROUND", nil, -8)
		back:SetAllPoints(button)
		back:SetColorTexture(0, 0, 0, 1)
		end)
		if not ok then ns.report["game-drawn trackers"] = "slot setup failed: " .. tostring(err) end
	end
end

-- ------------------------------------------------------------------
-- Visibility of game-drawn groups is left to the game: showing or hiding a container from addon
-- code makes the game re-read the auras under this addon's taint, which fails in combat. So the
-- group's conditions are turned into a macro condition and a secure attribute driver shows or
-- hides a gate frame; the containers and the cells live under the gate.
-- ------------------------------------------------------------------
local function CondMacro(cond)
	if cond and cond.never then return nil end
	if cond and cond.class and next(cond.class) and not (ns.env.class and cond.class[ns.env.class]) then return nil end
	if cond and cond.place and next(cond.place) and not cond.place[ns.env.place] then return nil end
	local common = {}
	local target = cond and cond.target
	if target == "yes" then common[#common + 1] = "@target,exists" elseif target == "no" then common[#common + 1] = "@target,noexists" end
	local c = cond and cond.combat
	if c == "yes" then common[#common + 1] = "combat" elseif c == "no" then common[#common + 1] = "nocombat" end
	local r = cond and cond.resting
	if r == "yes" then common[#common + 1] = "resting" elseif r == "no" then common[#common + 1] = "noresting" end
	local m = cond and cond.mounted
	if m == "yes" then common[#common + 1] = "mounted" elseif m == "no" then common[#common + 1] = "nomounted" end
	local a = cond and cond.alive
	if not target and a == "yes" then common[#common + 1] = "nodead" elseif not target and a == "no" then common[#common + 1] = "dead" end
	local groups = {}
	if cond and cond.group and next(cond.group) then
		if cond.group.solo then groups[#groups + 1] = "nogroup" end
		if cond.group.party then groups[#groups + 1] = "group:party,nogroup:raid" end
		if cond.group.raid then groups[#groups + 1] = "group:raid" end
	end
	if #groups == 0 then groups[1] = false end
	local brackets = {}
	for _, gp in ipairs(groups) do
		local parts = {}
		for _, p in ipairs(common) do parts[#parts + 1] = p end
		if gp then parts[#parts + 1] = gp end
		brackets[#brackets + 1] = "[" .. table.concat(parts, ",") .. "]"
	end
	return table.concat(brackets, "") .. " show; hide"
end
Display.CondMacro = CondMacro

local function EnsureGate(f, g)
	if not f.gate then
		f.gate = CreateFrame("Frame", nil, f)
		f.gate:SetAllPoints(f)
	end
	local macro = CondMacro(g.cond)
	if macro == nil then macro = "hide" end
	if f.gate.alMacro ~= macro and RegisterAttributeDriver and not (InCombatLockdown and InCombatLockdown()) then
		if UnregisterAttributeDriver and f.gate.alMacro then pcall(UnregisterAttributeDriver, f.gate, "state-visibility") end
		if pcall(RegisterAttributeDriver, f.gate, "state-visibility", macro) then f.gate.alMacro = macro end
	end
	return f.gate
end

local function DropGate(f)
	if not f.gate then return end
	if InCombatLockdown and InCombatLockdown() then return end
	if UnregisterAttributeDriver and f.gate.alMacro then pcall(UnregisterAttributeDriver, f.gate, "state-visibility") end
	f.gate.alMacro = nil
	f.gate:Hide()
end

-- The container for one unit of a group; rebuilt when the look changes. Nil in combat when it
-- would have to be rebuilt.
local function SlotContainer(f, g, unit)
	f.slotC = f.slotC or {}
	local key = SlotKey(g)
	local c = f.slotC[unit]
	if c and c.alKey == key then return c end
	if InCombatLockdown and InCombatLockdown() then return c end
	if c then
		if UnregisterAttributeDriver and c.alDriven then pcall(UnregisterAttributeDriver, c, "state-visibility") end
		c:Hide() c:ClearAllPoints() f.slotC[unit] = nil
	end
	local gate = EnsureGate(f, g)
	local ok, nc = pcall(CreateFrame, "AuraContainer", nil, gate, "CustomAuraContainerTemplate")
	if not (ok and nc) then
		ns.report["game-drawn trackers"] = "AuraContainer not available: " .. tostring(nc)
		return nil
	end
	nc:SetAllPoints(f)
	nc:SetFrameLevel(gate:GetFrameLevel() + 3)
	if nc.SetUnit then pcall(nc.SetUnit, nc, unit) end
	nc.alKey, nc.alSlots, nc.alIds, nc.alStore = key, {}, {}, {}
	if unit ~= "player" and RegisterAttributeDriver then
		-- Shown and hidden by the game as the target comes and goes, which is also what makes it
		-- re-read the new target's auras.
		if pcall(RegisterAttributeDriver, nc, "state-visibility", "[@" .. unit .. ",exists] show; hide") then nc.alDriven = true end
	end
	if not nc.alDriven then nc:Show() end
	f.slotC[unit] = nc
	ns.report["game-drawn trackers"] = "AuraContainer ok"
	return nc
end

-- Makes sure the slots for one tracker exist and carry its spell map. Returns the slot frames.
local function TrackerSlots(f, g, t, ids)
	local unit = t.unit or "player"
	local c = SlotContainer(f, g, unit)
	if not c then return nil end
	-- The game only matches spell ids for helpful auras on friendly units and harmful ones on
	-- enemies, so a debuff on you cannot have a slot; the addon draws that tracker as before.
	local kinds
	if unit == "player" then
		if t.kind == "debuff" then return nil end
		kinds = { "HELPFUL" }
	else
		kinds = (t.kind == "buff" and { "HELPFUL" }) or (t.kind == "debuff" and { "HARMFUL" }) or { "HELPFUL", "HARMFUL" }
	end
	local frames = {}
	local idsKey = IdsKey(ids)
	local mode = (t.show == "missing" and not (ns.db and ns.db.noMask)) and "mask" or "cover"
	for _, filter in ipairs(kinds) do
		local key = tostring(t.uid) .. ":" .. filter .. ":" .. mode
		local filters = { includeSpellIDs = ids }
		if t.mine then filters.isFromPlayerOrPlayerPet = true end
		local frame = c.alSlots[key]
		if not frame then
			if InCombatLockdown and InCombatLockdown() then return nil end
			local store = {}
			local ok, fr = pcall(c.AddAuraSlot, c, key, filter, { initializeFrame = InitSlotFrame(g, mode, filter, store), candidateFilters = filters })
			if not ok then
				ns.report["game-drawn trackers"] = "AddAuraSlot: " .. tostring(fr)
				return nil
			end
			frame = fr
			c.alSlots[key] = frame
			c.alStore[key] = store
			c.alIds[key] = idsKey .. tostring(t.mine)
		elseif c.alIds[key] ~= idsKey .. tostring(t.mine) and not (InCombatLockdown and InCombatLockdown()) then
			pcall(c.SetAuraSlotCandidateFilters, c, key, filters)
			c.alIds[key] = idsKey .. tostring(t.mine)
		end
		frames[#frames + 1] = { key = key, frame = frame, c = c, mask = c.alStore[key] and c.alStore[key].mask, mode = mode }
	end
	return frames
end

local function CreateGroupFrame()
	local f = CreateFrame("Frame", nil, UIParent)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:SetFrameStrata("MEDIUM")
	f.widgets = {}

	-- Edit-mode chrome: a titled plate behind the trackers that doubles as the drag handle.
	local ok, chrome = pcall(CreateFrame, "Button", nil, f, "BackdropTemplate")
	if not (ok and chrome) then chrome = CreateFrame("Button", nil, f) end
	chrome:SetPoint("TOPLEFT", -6, 20)
	chrome:SetPoint("BOTTOMRIGHT", 6, -6)
	chrome:SetFrameLevel(max(0, f:GetFrameLevel() - 1))
	if chrome.SetBackdrop then
		chrome:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		chrome:SetBackdropColor(0.04, 0.06, 0.12, 0.8)
		chrome:SetBackdropBorderColor(1, 0.82, 0, 0.9)
	else
		local bg = chrome:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.04, 0.06, 0.12, 0.8)
	end
	chrome.label = chrome:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	chrome.label:SetPoint("TOPLEFT", 7, -5)
	chrome.label:SetPoint("TOPRIGHT", -7, -5)
	chrome.label:SetJustifyH("LEFT")
	chrome.label:SetWordWrap(false)
	chrome.hl = chrome:CreateTexture(nil, "ARTWORK")
	chrome.hl:SetPoint("TOPLEFT", 3, -3)
	chrome.hl:SetPoint("BOTTOMRIGHT", -3, 3)
	chrome.hl:SetColorTexture(0.2, 1, 0.3, 0.3)
	chrome.hl:Hide()
	chrome:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	chrome:RegisterForDrag("LeftButton")
	chrome:SetScript("OnDragStart", function() Display:GroupDragStart(f) end)
	chrome:SetScript("OnDragStop", function() Display:GroupDragStop(f) end)
	chrome:SetScript("OnClick", function()
		if not f.group then return end
		ns.selected = { group = f.group }
		if ns.UI and ns.UI.ShowSelection then ns.UI:ShowSelection(true) end
	end)
	chrome:Hide()
	f.chrome = chrome
	return f
end

local function ApplyPosition(f, g)
	local s = g.scale or 1
	f:SetScale(s)
	f:ClearAllPoints()
	f:SetPoint(ANCHOR[g.grow] or "TOPLEFT", UIParent, "BOTTOMLEFT", (g.x or 500) / s, (g.y or 400) / s)
end

-- Position is kept in UIParent units at the corner the group grows from, so it stays put when
-- trackers come and go and when the scale changes.
local function SavePosition(f, g)
	local s = f:GetScale() or 1
	local a = ANCHOR[g.grow] or "TOPLEFT"
	local x = (a == "TOPRIGHT") and f:GetRight() or f:GetLeft()
	local y = (a == "BOTTOMLEFT") and f:GetBottom() or f:GetTop()
	if x and y then g.x, g.y = x * s, y * s end
end

local function WidgetTextures(w)
	local list = { w.icon, w.border, w.fill, w.bar.bg, w.bar.spark, w.stale }
	for _, t in ipairs(w.decor) do list[#list + 1] = t end
	for _, t in ipairs(w.iconArt) do list[#list + 1] = t end
	return list
end

local function LayoutGroup(f, g, visible, unlocked)
	local n = #visible
	local w, h
	if g.style == "bars" then w, h = g.barW, g.barH else w, h = g.size, g.size end
	local perRow = max(1, g.perRow or 8)
	local stepX, stepY = w + g.spacing, h + g.spacing
	local grow = g.grow or "RIGHT"
	local slots = g.gameDrawn and not unlocked

	-- Every slot starts the pass switched off; the ones with a cell are switched on below.
	-- Containers are never shown or hidden from here: the gate's driver does that.
	if f.slotC and slots then
		for unit, c in pairs(f.slotC) do
			for key in pairs(c.alSlots) do c.alWant = c.alWant or {} c.alWant[key] = false end
		end
	end
	if slots then EnsureGate(f, g) elseif f.gate then DropGate(f) end
	local cellParent = slots and f.gate or f

	for k = 1, n do
		local widget = f.widgets[k]
		if not widget then
			widget = CreateWidget(f)
			f.widgets[k] = widget
		end
		local item = visible[k]
		widget:SetAlpha(1)
		if widget:GetParent() ~= cellParent then widget:SetParent(cellParent) end
		if slots and item.slots then
			-- The addon draws only the missing state under a game-drawn slot; the game covers it
			-- while the aura is present. "Show when active" leaves the cell empty underneath.
			PaintWidget(widget, g, item.t, nil, false, false)
			if item.t.show == "active" then widget:SetAlpha(0) end
			-- A "mask" slot blanks the missing art while the game shows it.
			local mask
			for _, sl in ipairs(item.slots) do if sl.mode == "mask" and sl.mask then mask = sl.mask end end
			if mask and item.t.show == "missing" and g.style == "bars" then
				widget.name:SetText("")
				widget.duration:SetText("")
			end
			if widget.alMask ~= mask then
				for _, tex in ipairs(WidgetTextures(widget)) do
					if widget.alMask then pcall(tex.RemoveMaskTexture, tex, widget.alMask) end
					if mask then pcall(tex.AddMaskTexture, tex, mask) end
				end
				widget.alMask = mask
			end
			for _, sl in ipairs(item.slots) do
				sl.c.alWant[sl.key] = true
				if not (InCombatLockdown and InCombatLockdown()) or sl.frame.alAnchor ~= k then
					local ok = pcall(function()
						sl.frame:ClearAllPoints()
						sl.frame:SetPoint("TOPLEFT", widget, "TOPLEFT", 0, 0)
						sl.frame:SetPoint("BOTTOMRIGHT", widget, "BOTTOMRIGHT", 0, 0)
					end)
					if ok then sl.frame.alAnchor = k end
				end
			end
		else
			if widget.alMask then
				for _, tex in ipairs(WidgetTextures(widget)) do pcall(tex.RemoveMaskTexture, tex, widget.alMask) end
				widget.alMask = nil
			end
			PaintWidget(widget, g, item.t, item.entry, unlocked, item.expiring)
		end
		local a, b = (k - 1) % perRow, floor((k - 1) / perRow)
		widget:ClearAllPoints()
		if grow == "RIGHT" then widget:SetPoint("TOPLEFT", f, "TOPLEFT", a * stepX, -b * stepY)
		elseif grow == "LEFT" then widget:SetPoint("TOPRIGHT", f, "TOPRIGHT", -a * stepX, -b * stepY)
		elseif grow == "DOWN" then widget:SetPoint("TOPLEFT", f, "TOPLEFT", b * stepX, -a * stepY)
		else widget:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", b * stepX, a * stepY) end
		widget:EnableMouse(unlocked)
		widget:Show()
	end
	for k = n + 1, #f.widgets do
		local widget = f.widgets[k]
		widget:Hide()
		widget.tracker, widget.entry, widget.timed = nil, nil, false
	end

	if f.slotC and slots and not (InCombatLockdown and InCombatLockdown()) then
		for unit, c in pairs(f.slotC) do
			for key, want in pairs(c.alWant or {}) do
				if c.alOn == nil then c.alOn = {} end
				if c.alOn[key] ~= want then
					if pcall(c.SetAuraSlotEnabled, c, key, want) then c.alOn[key] = want end
				end
			end
		end
	end

	local p, q = min(n, perRow), ceil(n / perRow)
	if grow == "DOWN" or grow == "UP" then p, q = q, p end
	f:SetSize(max(1, p * stepX - g.spacing), max(1, q * stepY - g.spacing))
	f:SetAlpha(g.alpha or 1)

	f.chrome:SetShown(unlocked)
	if unlocked then
		f.chrome.label:SetText(ns.GroupName(g))
		local sel = ns.selected and ns.selected.group == g
		if f.chrome.SetBackdropBorderColor then
			if sel then f.chrome:SetBackdropBorderColor(0.3, 1, 0.4, 1) else f.chrome:SetBackdropBorderColor(1, 0.82, 0, 0.9) end
		end
	end
	if slots then f:Show() else f:SetShown(n > 0) end
end

-- Is the aura inside the tracker's "warn before it runs out" window?
local function Expiring(t, entry, now)
	local warn = t.warn or 0
	if warn <= 0 or not entry or entry.expires <= 0 then return false end
	return (entry.expires - now) <= warn
end
Display.Expiring = Expiring

-- Whether a tracker shows right now, and whether it is showing because the aura is about to run out.
local function Wants(t, entry, now, unlocked, groupPass)
	if unlocked then return true, false end
	if not groupPass or not ns.CondPass(t.cond) then return false, false end
	if t.unit == "target" and not ns.env.target then return false, false end
	local expiring = Expiring(t, entry, now)
	if t.show == "missing" then return entry == nil or expiring, expiring
	elseif t.show == "always" then return true, expiring
	else return entry ~= nil, false end
end

-- What each tracker looked like last time, so sounds play only on a change (never on the first look).
local trackState = setmetatable({}, { __mode = "k" })

local function Sounds(t, entry, show, unlocked, groupPass)
	local st = trackState[t]
	local active = entry ~= nil
	local shown = show and not unlocked
	if st then
		local snd = t.snd
		-- A tracker that is switched off, or whose group is, stays quiet.
		if snd and groupPass and ns.CondPass(t.cond) then
			-- Blizzard plays these two itself when the tracker is registered with it (in combat too).
			local bz = ns.blizzardSound and ns.blizzardSound[t]
			if active and not st.active and not (bz and bz.applied) then ns.PlaySoundChoice(snd.applied) end
			if not active and st.active and not (bz and bz.removed) then ns.PlaySoundChoice(snd.removed) end
			if not unlocked and shown and not st.shown then ns.PlaySoundChoice(snd.shown) end
		end
	else
		st = {}
		trackState[t] = st
	end
	st.active = active
	if not unlocked then st.shown = shown end
end

function Display:RefreshGroup(g)
	local f = active[g.uid]
	if not f then return end
	local unlocked = self:IsUnlocked()
	local groupPass = unlocked or ns.CondPass(g.cond)
	local now = GetTime()
	local visible = {}
	for _, t in ipairs(g.trackers) do
		local entry = ns.Find(t)
		local show, expiring = Wants(t, entry, now, unlocked, groupPass)
		Sounds(t, entry, show, unlocked, unlocked and ns.CondPass(g.cond) or groupPass)
		if g.gameDrawn and not unlocked then
			local ids = TrackerIds(t)
			local slots = ids and groupPass and ns.CondPass(t.cond) and TrackerSlots(f, g, t, ids)
			if slots then
				visible[#visible + 1] = { t = t, entry = entry, expiring = false, slots = slots }
			elseif show then
				visible[#visible + 1] = { t = t, entry = entry, expiring = expiring }
			end
		elseif show then
			visible[#visible + 1] = { t = t, entry = entry, expiring = expiring }
		end
	end
	if g.live and g.live ~= "" then
		LayoutLive(f, g, unlocked)
	else
		if f.live then f.live:Hide() end
		LayoutGroup(f, g, visible, unlocked)
	end
end

function Display:Refresh()
	if not ready then return end
	for _, g in ipairs(ns.profile.groups) do self:RefreshGroup(g) end
	self:Tick(GetTime())
end

function Display:Tick(now)
	if not ready then return end
	local unlocked = self:IsUnlocked()
	for _, f in pairs(active) do
		local g = f.group
		if g then
			-- A warn window opens with no event, so trackers that have one are re-checked each tick.
			if not unlocked then
				local groupPass = ns.CondPass(g.cond)
				for _, t in ipairs(g.trackers) do
					if (t.warn or 0) > 0 then
						local want, expiring = Wants(t, ns.Find(t), now, false, groupPass)
						local shown, wasExpiring = false, false
						for _, w in ipairs(f.widgets) do
							if w:IsShown() and w.tracker == t then shown, wasExpiring = true, w.expiring or false break end
						end
						if want ~= shown or expiring ~= wasExpiring then self:RefreshGroup(g) break end
					end
				end
			end
			if f:IsShown() and not (g.live and g.live ~= "") then
				for _, w in ipairs(f.widgets) do
					if w:IsShown() then TickWidget(w, g, now) end
				end
			end
		end
	end
end

-- Match frames to the saved groups, then redraw.
function Display:Rebuild()
	if ns.SyncAuraSounds then ns.SyncAuraSounds() end
	if not ready then return end
	local wanted = {}
	for _, g in ipairs(ns.profile.groups) do wanted[g.uid] = g end
	for uid, f in pairs(active) do
		if not wanted[uid] then
			f:Hide()
			f.group = nil
			if f.live then f.live:Hide() f.live = nil f.liveKey = nil end
			if f.slotC then
				for _, c in pairs(f.slotC) do
					if UnregisterAttributeDriver and c.alDriven then pcall(UnregisterAttributeDriver, c, "state-visibility") end
					c:Hide()
				end
				f.slotC = nil
			end
			DropGate(f)
			f.chrome.hl:Hide()
			active[uid] = nil
			pool[#pool + 1] = f
		end
	end
	for uid, g in pairs(wanted) do
		local f = active[uid]
		if not f then
			f = table.remove(pool) or CreateGroupFrame()
			active[uid] = f
		end
		f.group = g
		if not f.moving then ApplyPosition(f, g) end
	end
	self:Refresh()
end

function Display:Init()
	ready = true
	self:Rebuild()
end

-- Changing the growth direction moves the anchor corner; keep the group where it is.
function Display:SetGrow(g, grow)
	local f = active[g.uid]
	g.grow = grow
	if f and f:IsShown() and f:GetLeft() then SavePosition(f, g) end
	if f then ApplyPosition(f, g) end
	self:RefreshGroup(g)
end

function Display:ApplyGroup(g)
	local f = active[g.uid]
	if f then ApplyPosition(f, g) end
	self:RefreshGroup(g)
end

-- ------------------------------------------------------------------
-- Drop targets
-- ------------------------------------------------------------------
-- The group under the cursor (UIParent units), ignoring "except".
function Display:GroupAt(cx, cy, except)
	for _, f in pairs(active) do
		local g = f.group
		if g and g ~= except and f:IsShown() and f:GetLeft() then
			local s = f:GetScale() or 1
			local l, r, b, t = f:GetLeft() * s - 8, f:GetRight() * s + 8, f:GetBottom() * s - 8, f:GetTop() * s + 22
			if cx >= l and cx <= r and cy >= b and cy <= t then return g, f end
		end
	end
end

-- Where in the group's order a drop at the cursor belongs.
function Display:InsertIndex(f, g, cx, cy)
	local s = f:GetScale() or 1
	local best, bestDist
	for k, w in ipairs(f.widgets) do
		if w:IsShown() and w.tracker then
			local wx, wy = w:GetCenter()
			if wx then
				wx, wy = wx * s, wy * s
				local d = (wx - cx) ^ 2 + (wy - cy) ^ 2
				if not bestDist or d < bestDist then best, bestDist = { k = k, x = wx, y = wy, t = w.tracker }, d end
			end
		end
	end
	if not best then return #g.trackers + 1 end
	local index = best.k
	for i, t in ipairs(g.trackers) do if t == best.t then index = i break end end
	local grow = g.grow or "RIGHT"
	local after = (grow == "RIGHT" and cx > best.x) or (grow == "LEFT" and cx < best.x)
		or (grow == "DOWN" and cy < best.y) or (grow == "UP" and cy > best.y)
	return after and index + 1 or index
end

local highlighted
local function Highlight(f)
	if highlighted == f then return end
	if highlighted then highlighted.chrome.hl:Hide() end
	highlighted = f
	if f then f.chrome.hl:Show() end
end

-- ------------------------------------------------------------------
-- The drag ghost: an icon on the cursor, used for ledger rows and Shift-dragged trackers.
-- ------------------------------------------------------------------
local ghost
local function GetGhost()
	if ghost then return ghost end
	ghost = CreateFrame("Frame", nil, UIParent)
	ghost:SetSize(38, 38)
	ghost:SetFrameStrata("TOOLTIP")
	ghost.icon = ghost:CreateTexture(nil, "ARTWORK")
	ghost.icon:SetAllPoints()
	ghost.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	ghost.icon:SetAlpha(0.85)
	ghost.text = ghost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ghost.text:SetPoint("TOP", ghost, "BOTTOM", 0, -2)
	ghost:Hide()
	ghost:SetScript("OnUpdate", function(self)
		local cx, cy = CursorUI()
		self:ClearAllPoints()
		self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)
		local overWindow = ns.UI and ns.UI.frame and ns.UI.frame:IsShown() and ns.UI.frame:IsMouseOver()
		local g, f
		if not overWindow then g, f = Display:GroupAt(cx, cy, self.except) end
		Highlight(f)
		if overWindow then self.text:SetText(self.windowText or "|cffff6060Cancel|r")
		elseif g then self.text:SetText("|cff40ff60Add to " .. ns.GroupName(g) .. "|r")
		else self.text:SetText(self.freeText or "Place here") end
	end)
	return ghost
end

function Display:BeginGhost(icon, freeText, except, windowText)
	local gh = GetGhost()
	gh.icon:SetTexture(icon or QUESTION)
	gh.freeText, gh.except, gh.windowText = freeText, except, windowText
	gh:Show()
end

-- Ends the drag. Returns cancelled, cursorX, cursorY, targetGroup, insertIndex.
function Display:EndGhost()
	local gh = GetGhost()
	gh:Hide()
	Highlight(nil)
	local cx, cy = CursorUI()
	if ns.UI and ns.UI.frame and ns.UI.frame:IsShown() and ns.UI.frame:IsMouseOver() then return true, cx, cy end
	local g, f = self:GroupAt(cx, cy, gh.except)
	if g then return false, cx, cy, g, self:InsertIndex(f, g, cx, cy) end
	return false, cx, cy
end

-- ------------------------------------------------------------------
-- Dragging groups and trackers
-- ------------------------------------------------------------------
function Display:GroupDragStart(f)
	local g = f.group
	if not g or not self:IsUnlocked() then return end
	f.moving = true
	f:StartMoving()
	if #g.trackers == 1 then
		-- A lone tracker can be dropped onto another group to join it.
		f:SetScript("OnUpdate", function()
			local cx, cy = CursorUI()
			local _, target = Display:GroupAt(cx, cy, g)
			Highlight(target)
		end)
	end
end

function Display:GroupDragStop(f)
	local g = f.group
	if not f.moving then return end
	f.moving = false
	f:StopMovingOrSizing()
	f:SetScript("OnUpdate", nil)
	if f.SetUserPlaced then f:SetUserPlaced(false) end
	Highlight(nil)
	if not g then return end
	if #g.trackers == 1 then
		local cx, cy = CursorUI()
		local target, tf = self:GroupAt(cx, cy, g)
		if target then
			ns.MoveTracker(g.trackers[1], target, self:InsertIndex(tf, target, cx, cy))
			return
		end
	end
	SavePosition(f, g)
	ApplyPosition(f, g)
end

function Display:WidgetDragStart(w)
	local g, t = w.group, w.tracker
	if not g or not t or not self:IsUnlocked() then return end
	local f = active[g.uid]
	if IsShiftKeyDown and IsShiftKeyDown() and #g.trackers > 1 then
		w.pulling = true
		self:BeginGhost(t.icon, "New group here")
	elseif f then
		w.movingGroup = f
		self:GroupDragStart(f)
	end
end

function Display:WidgetDragStop(w)
	if w.movingGroup then
		local f = w.movingGroup
		w.movingGroup = nil
		self:GroupDragStop(f)
		return
	end
	if not w.pulling then return end
	w.pulling = false
	local g, t = w.group, w.tracker
	local cancelled, cx, cy, target, index = self:EndGhost()
	if cancelled or not g or not t then return end
	if target then
		ns.MoveTracker(t, target, index)
	else
		-- Out on its own: a new group that keeps the look of the one it came from.
		local ng = ns.NewGroupLike(g, cx - 18, cy + 18)
		ns.MoveTracker(t, ng)
	end
end
