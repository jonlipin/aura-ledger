-- Aura Ledger display: the tracker groups on screen. Every group is a plain (non-secure) frame, so it
-- may show, hide and re-layout in combat. While unlocked every tracker is shown as a preview and the
-- groups can be dragged; dropping a lone tracker (or a Shift-dragged one) on another group joins it.

local ADDON, ns = ...
local Display = {}
ns.Display = Display

local QUESTION = ns.QUESTION
local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
-- Where a group is pinned. The two centre growths are pinned by an edge midpoint rather than a
-- corner, so the trackers spread evenly either side of the place you put it.
local ANCHOR = { RIGHT = "TOPLEFT", DOWN = "TOPLEFT", LEFT = "TOPRIGHT", UP = "BOTTOMLEFT",
	CENTER_H = "TOP", CENTER_V = "LEFT" }
-- Growing from the centre lays the trackers out the same way as its plain direction; only the
-- pinning differs, which is what makes the group spread rather than march off one way.
local FLOW = { CENTER_H = "RIGHT", CENTER_V = "DOWN" }
ns.GROWS = { { "RIGHT", "Right" }, { "LEFT", "Left" }, { "DOWN", "Down" }, { "UP", "Up" },
	{ "CENTER_H", "Out from the centre, sideways" }, { "CENTER_V", "Out from the centre, up and down" } }

local floor, max, min, ceil, abs = math.floor, math.max, math.min, math.ceil, math.abs

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

-- Where a region sits inside "ref", in ref's own terms: x from the left edge, y from the top edge
-- going down, so y is negative. Also reports a region held by a single point, and its own size.
-- "box" may also name the region the art hangs off (the icon), so art anchored to the icon rather
-- than to the frame around it is kept, measured against the icon's own rectangle.
local function RectOf(region, ref, rw, rh, box)
	local n = region:GetNumPoints() or 0
	if n == 0 then return end
	local w, h = region:GetSize()
	w, h = w or 0, h or 0
	local l, r, t, b
	local single
	for i = 1, n do
		local p, rel, rp, x, y = region:GetPoint(i)
		if not p then return end
		-- The rectangle this point hangs off, in the reference frame's own terms.
		local x0, y0, bw, bh = 0, 0, rw, rh
		if box and box.region and rel == box.region then
			x0, y0, bw, bh = box.l, -box.t, box.w, box.h
		elseif rel ~= nil and rel ~= ref then
			return
		elseif rel == nil and region:GetParent() ~= ref then
			return
		end
		x, y, rp = x or 0, y or 0, rp or p
		local ax = (rp:find("LEFT") and x0) or (rp:find("RIGHT") and (x0 + bw)) or (x0 + bw / 2)
		local ay = (rp:find("TOP") and y0) or (rp:find("BOTTOM") and (y0 - bh)) or (y0 - bh / 2)
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
	return l, r, t, b, single, w, h
end

-- Where a region sits relative to the box it is drawn around, as fractions of that box's height so
-- it can be redrawn at any size. "box" names a rectangle inside the reference frame: icon art is
-- measured around the icon itself, because the frame it hangs on may be a whole bar item and art
-- measured around that would be stretched when it is redrawn around a square icon. Stretched
-- regions get overhangs past each edge; small regions anchored by one point keep their size and side.
local function Geometry(region, ref, box)
	local rw, rh = ref:GetSize()
	if not rw or rw <= 0 or not rh or rh <= 0 then return end
	local l, r, t, b, single, w, h = RectOf(region, ref, rw, rh, box)
	if not l then return end
	local bl, bt, bw, bh = 0, 0, rw, rh
	if box then bl, bt, bw, bh = box.l, box.t, box.w, box.h end
	if bw <= 0 or bh <= 0 then return end
	if single and (r - l) < bw * 0.6 then
		-- The box's own anchor point, and the region's, so the offset between them carries over.
		local ax = (single.rp:find("LEFT") and bl) or (single.rp:find("RIGHT") and (bl + bw)) or (bl + bw / 2)
		local ay = (single.rp:find("TOP") and -bt) or (single.rp:find("BOTTOM") and -(bt + bh)) or -(bt + bh / 2)
		local px = (single.p:find("LEFT") and l) or (single.p:find("RIGHT") and r) or ((l + r) / 2)
		local py = (single.p:find("TOP") and t) or (single.p:find("BOTTOM") and b) or ((t + b) / 2)
		return { fixed = true, p = single.p, rp = single.rp, x = (px - ax) / bh, y = (py - ay) / bh, w = w / bh, h = h / bh }
	end
	return { l = (bl - l) / bh, r = (r - (bl + bw)) / bh, t = (t + bt) / bh, b = (-(bt + bh) - b) / bh }
end

-- The icon's own rectangle inside the frame it hangs on, for use as that box.
local function IconBox(iconTex, iconFrame)
	local rw, rh = iconFrame:GetSize()
	if not rw or rw <= 0 or not rh or rh <= 0 then return end
	local l, r, t, b = RectOf(iconTex, iconFrame, rw, rh, nil)
	if not l or (r - l) <= 0 or (t - b) <= 0 then return end
	return { l = l, t = -t, w = r - l, h = t - b, region = iconTex }
end

-- How far a stretched piece of art reaches past the icon on every side. The donor's own overhangs
-- can differ from side to side, and carried over literally they make a square icon's frame taller
-- than it is wide, so art drawn around an icon takes the average of the four.
local function EvenOverhang(geo)
	return (geo.l + geo.r + geo.t + geo.b) / 4
end

local function ApplyGeometry(tex, geo, ref, H, even)
	tex:ClearAllPoints()
	if geo.fixed then
		tex:SetSize(max(1, geo.w * H), max(1, geo.h * H))
		tex:SetPoint(geo.p, ref, geo.rp, geo.x * H, geo.y * H)
	elseif even then
		local o = EvenOverhang(geo) * H
		tex:SetPoint("TOPLEFT", ref, "TOPLEFT", -o, o)
		tex:SetPoint("BOTTOMRIGHT", ref, "BOTTOMRIGHT", o, -o)
	else
		tex:SetPoint("TOPLEFT", ref, "TOPLEFT", -geo.l * H, geo.t * H)
		tex:SetPoint("BOTTOMRIGHT", ref, "BOTTOMRIGHT", geo.r * H, -geo.b * H)
	end
end

-- Every visible texture on "frame" placed relative to "ref", except "skip".
local function Collect(frame, ref, skip, into, under, box)
	if not frame or not frame.GetRegions then return end
	for _, region in ipairs({ frame:GetRegions() }) do
		if region ~= skip and IsA(region, "Texture") then
			local d = DescribeTexture(region)
			if d and not d.hidden then
				local geo = Geometry(region, ref, box)
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

-- The donor's crop, squared off. A crop that takes more off one axis than the other leaves the
-- art inside a square icon stretched, so the tighter of the two is used on both.
local TRIM = { 0.07, 0.93, 0.07, 0.93 }

-- The crop to draw an icon with. A spell icon has a dark border baked into its outer edge, which is
-- why every frame in the game trims one, and a mask does not take it off: it rounds the corners of
-- whatever it is given, border and all. A donor that leans on a mask reports the whole picture, so
-- that answer is not worth keeping.
local function IconCrop(c)
	if not c then return TRIM end
	if c[1] <= 0.001 and c[2] >= 0.999 and c[3] <= 0.001 and c[4] >= 0.999 then return TRIM end
	return c
end

local function SquareCoords(c)
	if not c then return { 0.07, 0.93, 0.07, 0.93 } end
	local l, r, t, b = c[1] or 0, c[2] or 1, c[3] or 0, c[4] or 1
	local wspan, hspan = r - l, b - t
	if wspan <= 0 or hspan <= 0 then return { 0.07, 0.93, 0.07, 0.93 } end
	if abs(wspan - hspan) <= 0.02 then return c end
	local span = min(wspan, hspan) / 2
	local cx, cy = (l + r) / 2, (t + b) / 2
	return { cx - span, cx + span, cy - span, cy + span }
end

Display.SquareCoords = SquareCoords
Display.IconBox = IconBox

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
		if ok and ulx and urx and lly then s.iconCoords = SquareCoords({ ulx, urx, uly, lly }) end
		local box = IconBox(iconTex, iconFrame)
		Collect(iconFrame, iconFrame, iconTex, s.iconDecor, false, box)
		if iconFrame.GetChildren then
			for _, child in ipairs({ iconFrame:GetChildren() }) do Collect(child, iconFrame, nil, s.iconDecor, false, box) end
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

-- The frame this client draws round its own icons, if it has one. It is drawn by its own two
-- numbers, not the mask's: the mask is a shape that has to be grown by about a quarter before it
-- fits an icon, while this is art that sits on one with a thin border.
local clientFrame, clientFrameTried
local function ClientIconFrame()
	if ns.db and ns.db.iconBorder == "cdm" then return nil end
	if not clientFrameTried then
		clientFrameTried = true
		for _, atlas in ipairs(ns.ICON_FRAMES or {}) do
			if HasAtlas(atlas) then clientFrame = atlas break end
		end
		ns.report["icon frame"] = clientFrame or "none on this client, the Cooldown Manager's overlay is used"
	end
	return clientFrame
end

-- Draws it on "w" around "ref", at the size the mask is drawn at, and says whether it could.
local function PlaceClientFrame(w, ref, size, want)
	local atlas = (want ~= false) and ClientIconFrame()
	if not atlas then
		if w.clientFrame then w.clientFrame:Hide() end
		return false
	end
	local tex = w.clientFrame
	if not tex then
		tex = (w.over or w):CreateTexture(nil, "OVERLAY")
		w.clientFrame = tex
	end
	tex:SetAtlas(atlas)
	local over, shift = ns.FRAME_OVER, ns.FRAME_SHIFT * size
	tex:ClearAllPoints()
	tex:SetPoint("TOPLEFT", ref, "TOPLEFT", -over * size, over * size + shift)
	tex:SetPoint("BOTTOMRIGHT", ref, "BOTTOMRIGHT", over * size, -over * size + shift)
	tex:Show()
	return true
end

-- How far the picture is pulled in under its frame art, so the art laps over its edge instead of
-- meeting it exactly. Without this the square corners of the picture show past a rounded border.
local function IconInset(s, bars, size, frameOn)
	if not frameOn then return 0 end
	local art = nil
	if bars then art = s.iconDecor end
	if not art or #art == 0 then art = s.soloIconDecor end
	if not art or #art == 0 then art = s.iconDecor end
	if not art or #art == 0 then return 0 end
	local o = 0
	for _, dd in ipairs(art) do
		if dd.geo and not dd.geo.fixed then
			local v = EvenOverhang(dd.geo)
			if v > o then o = v end
		end
	end
	if o <= 0 then return 0 end
	return min(floor(size * 0.12), max(1, floor(o * size + 0.5)))
end

-- The icon art to draw: a bar's icon keeps the art from the bar donor, a lone icon prefers the
-- icon donor's, and either falls back to whichever was found.
local function IconArt(s, bars)
	if bars and s.iconDecor and #s.iconDecor > 0 then return s.iconDecor end
	if s.soloIconDecor and #s.soloIconDecor > 0 then return s.soloIconDecor end
	if s.iconDecor and #s.iconDecor > 0 then return s.iconDecor end
	return {}
end

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
			local box = IconBox(iconTex, iconFrame)
			Collect(iconFrame, iconFrame, iconTex, s.soloIconDecor, false, box)
			if iconFrame.GetChildren then
				for _, child in ipairs({ iconFrame:GetChildren() }) do Collect(child, iconFrame, nil, s.soloIconDecor, false, box) end
			end
			local ok, ulx, uly, llx, lly, urx = pcall(iconTex.GetTexCoord, iconTex)
			if ok and ulx and urx and lly then s.soloIconCoords = SquareCoords({ ulx, urx, uly, lly }) end
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
	ns.report["icon skin"] = s.iconSource and (s.iconSource .. ", " .. #s.soloIconDecor .. " art pieces, "
			.. #s.iconDecor .. " from the bar donor")
		or (#s.iconDecor > 0 and ("from the bar donor, " .. #s.iconDecor .. " art pieces"))
		or "none (default buff frame look)"
	skin = s
	return s
end
Display.BuildSkin = BuildSkin
Display.IconCrop = IconCrop
Display.EvenOverhang = EvenOverhang
Display.IconInset = IconInset

-- One line for a texture that is actually on screen: its art, the size it is drawn at, where its
-- corners are pinned, and how it is cropped.
local function TexLine(label, tex)
	if not tex then return label .. ": none" end
	local shown = (tex.IsShown and tex:IsShown()) and "shown" or "hidden"
	local art = (tex.GetAtlas and tex:GetAtlas()) or (tex.GetTexture and tex:GetTexture()) or "?"
	local w, h = 0, 0
	if tex.GetSize then w, h = tex:GetSize() end
	local crop = ""
	if tex.GetTexCoord then
		local ok, ulx, uly, llx, lly, urx, ury, lrx, lry = pcall(tex.GetTexCoord, tex)
		if ok and ulx then crop = (", crop %.2f %.2f %.2f %.2f"):format(ulx, urx or 0, uly, lly or 0) end
	end
	local pts = ""
	if tex.GetNumPoints and tex.GetPoint then
		for i = 1, (tex:GetNumPoints() or 0) do
			local p, _, rp, x, y = tex:GetPoint(i)
			if p then pts = pts .. (" [%s->%s %+.1f %+.1f]"):format(p, tostring(rp), x or 0, y or 0) end
		end
	end
	return ("%s: %s, %s, %.0fx%.0f%s%s"):format(label, tostring(art), shown, w or 0, h or 0, crop, pts)
end

-- What the icon art came out as: the donor, the box it was measured in, and each piece's reach past
-- the icon. Read by /auraledger debug icon.
function Display:IconReport(emit)
	local s = BuildSkin()
	emit("icon art from: " .. tostring(s.iconSource or s.source))
	local fi = ClientIconFrame()
	local fa = fi and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(fi)
	emit(("icon frame: %s%s, drawn out %.3f and up %.3f of the icon"):format(
		tostring(fi or ("none, falling back to " .. tostring(s.iconSource or s.source))),
		fa and (" (" .. (fa.width or 0) .. "x" .. (fa.height or 0) .. ")") or "",
		ns.FRAME_OVER, ns.FRAME_SHIFT))
	emit("icon mask: " .. tostring(ns.report["icon mask"] or "not tried yet"))
	local mi = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(ns.ICON_MASK)
	emit(("  mask art: %s, drawn out %.3f and up %.3f of the icon"):format(
		mi and ((mi.width or 0) .. "x" .. (mi.height or 0)) or "no atlas", ns.MASK_OVER, ns.MASK_SHIFT))
	emit(("crop: %s"):format(s.soloIconCoords and table.concat(s.soloIconCoords, ", ") or (s.iconCoords and table.concat(s.iconCoords, ", ") or "none")))
	for _, which in ipairs({ { "bar donor", s.iconDecor }, { "icon donor", s.soloIconDecor } }) do
		local list = which[2]
		emit(("%s: %d piece%s"):format(which[1], list and #list or 0, (list and #list == 1) and "" or "s"))
		for i, dd in ipairs(list or {}) do
			local g = dd.geo
			if not g then
				emit(("  %d: no geometry"):format(i))
			elseif g.fixed then
				emit(("  %d: %s, held at %s, %.3f x %.3f"):format(i, tostring(dd.atlas or dd.file), tostring(g.p), g.w, g.h))
			else
				emit(("  %d: %s, reaches l %.3f r %.3f t %.3f b %.3f, evened to %.3f"):format(i,
					tostring(dd.atlas or dd.file), g.l, g.r, g.t, g.b, EvenOverhang(g)))
			end
		end
	end
	for _, g in ipairs(ns.profile.groups) do
		if g.style ~= "bars" then
			emit(("group %s: icon %d, inset %d"):format(ns.GroupName(g), g.size or 40, IconInset(s, false, g.size or 40, g.iconFrame ~= false)))
		else
			emit(("group %s: bar icon %d, inset %d"):format(ns.GroupName(g), ns.BarIconSize(g), IconInset(s, true, ns.BarIconSize(g), g.iconFrame ~= false)))
		end
		-- What is on screen for the first tracker of this group, layer by layer.
		local f = self:ActiveFrame(g.uid)
		local w = f and f.widgets and f.widgets[1]
		if w then
			emit("  what is drawn on " .. ns.GroupName(g) .. ":")
			emit("    " .. TexLine("picture", w.icon))
			emit("    " .. TexLine("client frame", w.clientFrame))
			for i, tex in ipairs(w.iconArt or {}) do emit("    " .. TexLine("copied art " .. i, tex)) end
			emit("    " .. TexLine("dispel border", w.border))
			emit("    mask: " .. (w.icon and w.icon.alMask and "on" or "off"))
			if w.icon and w.icon.alMask then emit("    " .. TexLine("mask art", w.icon.alMask)) end
		end
	end
end

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
local function PlaceDecor(w, list, key, ref, H, want, even)
	local pool = w[key]
	for i, d in ipairs(list) do
		local tex = pool[i]
		if not tex then
			tex = (d.under and w.under or w.over):CreateTexture(nil, d.layer or "ARTWORK")
			pool[i] = tex
			ApplyTexture(tex, d)
		end
		ApplyGeometry(tex, d.geo, ref, H, even)
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
	local key = g.style .. ":" .. g.size .. ":" .. g.barW .. ":" .. g.barH .. ":" .. tostring(g.barIconScale or 1)
		.. ":" .. tostring(g.border ~= false) .. tostring(g.background ~= false) .. tostring(g.iconFrame ~= false)
		.. ":" .. tostring(ns.MASK_EPOCH)
	local wantBar = function(d) if d.under then return g.background ~= false else return g.border ~= false end end
	local wantIcon = function() return g.iconFrame ~= false end
	if w.configured == key then return end
	w.configured = key
	local s = skin
	w.icon:ClearAllPoints()
	w.time:ClearAllPoints()
	w.count:ClearAllPoints()
	w.name:ClearAllPoints()
	w.duration:ClearAllPoints()
	if g.style == "bars" then
		local H = g.barH
		-- The icon keeps the middle of the bar's height whatever its scale, so a large one stands
		-- proud of the bar top and bottom rather than pushing the bar down.
		local IS = ns.BarIconSize(g)
		-- Masked to the client's icon shape, the picture can fill its square: the mask takes the
		-- corners off. Only where there is no mask is it pulled in under the art instead. The mask
		-- is told the size it clips, because the icon has not been given one yet.
		local masked = ns.SetIconMask(w, w.icon, g.iconFrame ~= false, IS)
		local inset = (masked or ClientIconFrame()) and 0 or IconInset(s, true, IS, g.iconFrame ~= false)
		-- The widget is as tall as the taller of the two, and both the icon and the bar hold its
		-- middle, so scaling the icon moves neither off the other's line.
		local WH = max(H, IS)
		w:SetSize(g.barW, WH)
		w.icon:SetSize(IS - inset * 2, IS - inset * 2)
		w.icon:SetPoint("LEFT", w, "LEFT", inset, 0)
		local c = IconCrop(s.iconCoords)
		w.icon:SetTexCoord(c[1], c[2], c[3], c[4])
		w.bar:ClearAllPoints()
		w.bar:SetSize(max(8, g.barW - IS - 2), H)
		w.bar:SetPoint("LEFT", w, "LEFT", IS + 2, 0)
		w.bar:Show()
		PlaceDecor(w, s.decor, "decor", w.bar, H, wantBar)
		if PlaceClientFrame(w, w.icon, IS, g.iconFrame ~= false) then
			PlaceDecor(w, {}, "iconArt", w.icon, IS, wantIcon, true)
		else
			PlaceDecor(w, IconArt(s, true), "iconArt", w.icon, IS, wantIcon, true)
		end
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
		w.count:SetFont(FONT, max(7, floor(IS * 0.45)), "OUTLINE")
		w.count:SetPoint("BOTTOMRIGHT", w.icon, "BOTTOMRIGHT", -1, 1)
	else
		local S = g.size
		local masked = ns.SetIconMask(w, w.icon, g.iconFrame ~= false, S)
		local inset = (masked or ClientIconFrame()) and 0 or IconInset(s, false, S, g.iconFrame ~= false)
		w:SetSize(S, S)
		w.icon:SetSize(S - inset * 2, S - inset * 2)
		w.icon:SetPoint("CENTER")
		local c = IconCrop(s.soloIconCoords or s.iconCoords)
		w.icon:SetTexCoord(c[1], c[2], c[3], c[4])
		w.bar:Hide()
		PlaceDecor(w, {}, "decor", w.bar, S)
		if PlaceClientFrame(w, w.icon, S, g.iconFrame ~= false) then
			PlaceDecor(w, {}, "iconArt", w.icon, S, wantIcon, true)
		else
			PlaceDecor(w, IconArt(s, false), "iconArt", w.icon, S, wantIcon, true)
		end
		if w.edge then w.edge:Hide() end
		w.name:Hide()
		w.duration:Hide()
		w.time:Show()
		w.time:SetFont(FONT, max(8, floor(S * 0.4)), "OUTLINE")
		w.time:SetPoint("CENTER", w.icon, "CENTER", 0, 0)
		w.count:SetFont(FONT, max(7, floor(S * 0.3)), "OUTLINE")
		w.count:SetPoint("BOTTOMRIGHT", w.icon, "BOTTOMRIGHT", -1, 1)
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
	-- The ~ is the one mark for a time the addon is carrying rather than reading: either it was
	-- guessed, or it is the last clean read counting on.
	local text = g.timers ~= false and (((e.estimated or e.stale) and "~" or "") .. ns.FormatTime(rem)) or ""
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

-- Raised when the game refuses to draw a group. The check drops it if the next attempt worked.
local function AdviseGameDrawn(field, what)
	if not ns.Advise then return end
	ns.Advise("gamedrawn", ("A group set to be drawn by the game could not be built (%s). Those groups will stay empty until it is. Reloading usually puts it right."):format(what),
		function() return not tostring(ns.report[field] or ""):find("ok", 1, true) end)
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

-- The slot draws the aura and covers the cell. (A mask on the slot to blank the cell instead was
-- tried: on this client a mask still applies while its frame is hidden, so it cannot invert.)
local function InitSlotFrame(g, mode, filter, store)
	return function(button)
		if not button then return end
		local ok, err = pcall(function()
		local s = BuildSkin()
		local bars = g.style == "bars"
		local W, H = bars and g.barW or g.size, bars and g.barH or g.size
		pcall(button.SetSize, button, W, H)
		local IS = bars and ns.BarIconSize(g) or H
		local icon = button:CreateTexture(nil, "ARTWORK")
		local c = IconCrop((bars and s.iconCoords) or s.soloIconCoords or s.iconCoords)
		icon:SetTexCoord(c[1], c[2], c[3], c[4])
		local masked = g.iconFrame ~= false and ns.SetIconMask(button, icon, true, IS)
		local inset = (masked or ClientIconFrame()) and 0 or IconInset(s, bars, IS, g.iconFrame ~= false)
		local IW = IS - inset * 2
		-- The container takes the icon and anchors it to the button, which is not always square, so
		-- the picture is put back on its own square afterwards.
		local function SquareUp()
			icon:ClearAllPoints()
			icon:SetSize(IW, IW)
			if bars then icon:SetPoint("LEFT", button, "LEFT", inset, 0) else icon:SetPoint("CENTER", button, "CENTER", 0, 0) end
		end
		SquareUp()
		pcall(button.SetIcon, button, icon)
		SquareUp()
		if button.HookScript then pcall(button.HookScript, button, "OnShow", SquareUp) end
		local count = button:CreateFontString(nil, "OVERLAY")
		count:SetFont(FONT, max(7, floor(IS * (bars and 0.45 or 0.3))), "OUTLINE")
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
			bar:SetPoint("TOPLEFT", button, "TOPLEFT", IS + 2, 0)
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
			if g.iconFrame ~= false and not PlaceClientFrame(w, icon, IS, true) then
				PlaceDecor(w, IconArt(s, true), "iconArt", icon, IS, nil, true)
			end
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
			name:SetWidth(max(10, W - IS - 2 - 8 - 44))
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
				if not PlaceClientFrame(w, icon, H, true) then
					PlaceDecor(w, IconArt(s, false), "iconArt", icon, H, nil, true)
				end
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
		if not ok then
			ns.report["game-drawn trackers"] = "slot setup failed: " .. tostring(err)
			AdviseGameDrawn("game-drawn trackers", "a tracker's slot could not be dressed")
		end
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
	-- A macro condition cannot count players, so a size becomes the nearest thing it can say:
	-- some group at all, or a raid. The addon's own check is exact; this one only gates the
	-- frames the game draws.
	local groups = {}
	local minGroup = cond and cond.minGroup or 1
	if minGroup > 5 then groups[1] = "group:raid"
	elseif minGroup > 1 then groups[1] = "group"
	else groups[1] = false end
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
	if f.gate.alMacro ~= macro and not (InCombatLockdown and InCombatLockdown()) then
		if RegisterAttributeDriver then
			if UnregisterAttributeDriver and f.gate.alMacro then pcall(UnregisterAttributeDriver, f.gate, "state-visibility") end
			if pcall(RegisterAttributeDriver, f.gate, "state-visibility", macro) then f.gate.alMacro = macro end
		else
			-- No driver on this client: the gate follows the conditions from here, out of combat.
			f.gate:SetShown(ns.CondPass(g.cond))
			f.gate.alMacro = macro
		end
	end
	return f.gate
end

local function DropGate(f)
	if not f.gate then return end
	if InCombatLockdown and InCombatLockdown() then return end
	if UnregisterAttributeDriver and f.gate.alMacro then pcall(UnregisterAttributeDriver, f.gate, "state-visibility") end
	f.gate.alMacro = nil
	f.gate:Hide()
	f.gate.alDropped = true
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
	if gate.alDropped and not (InCombatLockdown and InCombatLockdown()) then gate:Show() gate.alDropped = nil end
	local ok, nc = pcall(CreateFrame, "AuraContainer", nil, gate, "CustomAuraContainerTemplate")
	if not (ok and nc) then
		ns.report["game-drawn trackers"] = "AuraContainer not available: " .. tostring(nc)
		AdviseGameDrawn("game-drawn trackers", "the game's aura display could not be created")
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
	if t.kind == "debuff" then return nil end
	local kinds = { "HELPFUL" }
	local frames = {}
	local idsKey = IdsKey(ids)
	local mode = "cover"
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
				AdviseGameDrawn("game-drawn trackers", "the game refused a tracker's slot")
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
	local cx, cy = f:GetCenter()
	local x, y
	if a == "TOPRIGHT" then x = f:GetRight() elseif a == "TOP" then x = cx else x = f:GetLeft() end
	if a == "BOTTOMLEFT" then y = f:GetBottom() elseif a == "LEFT" then y = cy else y = f:GetTop() end
	if x and y then g.x, g.y = x * s, y * s end
end

local function LayoutGroup(f, g, visible, unlocked)
	local n = #visible
	local w, h
	-- An icon scaled past the bar's height needs the room, or it is cut off by the row above.
	if g.style == "bars" then w, h = g.barW, max(g.barH, ns.BarIconSize(g)) else w, h = g.size, g.size end
	local perRow = max(1, g.perRow or 8)
	local stepX, stepY = w + g.spacing, h + g.spacing
	local grow = g.grow or "RIGHT"
	local flow = FLOW[grow] or grow
	local slots = g.gameDrawn and not unlocked

	-- Every slot starts the pass switched off; the ones with a cell are switched on below.
	-- Containers are never shown or hidden from here: the gate's driver does that.
	if f.slotC and slots then
		for unit, c in pairs(f.slotC) do
			for key in pairs(c.alSlots) do c.alWant = c.alWant or {} c.alWant[key] = false end
		end
	end
	if slots then
		local gate = EnsureGate(f, g)
		if gate.alDropped and not (InCombatLockdown and InCombatLockdown()) then gate:Show() gate.alDropped = nil end
	elseif f.gate then
		DropGate(f)
	end
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
			PaintWidget(widget, g, item.t, item.entry, unlocked, item.expiring)
		end
		local a, b = (k - 1) % perRow, floor((k - 1) / perRow)
		widget:ClearAllPoints()
		if flow == "RIGHT" then widget:SetPoint("TOPLEFT", f, "TOPLEFT", a * stepX, -b * stepY)
		elseif flow == "LEFT" then widget:SetPoint("TOPRIGHT", f, "TOPRIGHT", -a * stepX, -b * stepY)
		elseif flow == "DOWN" then widget:SetPoint("TOPLEFT", f, "TOPLEFT", b * stepX, -a * stepY)
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
	if flow == "DOWN" or flow == "UP" then p, q = q, p end
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

function Display.FrameFor(g)
	return active[g.uid]
end

-- The frame a group is drawn on, for the readout, which is written above this.
function Display:ActiveFrame(uid)
	return active[uid]
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
			local passes = groupPass and ns.CondPass(t.cond)
			local ids = TrackerIds(t)
			local slots = ids and passes and TrackerSlots(f, g, t, ids)
			if slots then
				visible[#visible + 1] = { t = t, entry = entry, expiring = false, slots = slots }
			elseif show then
				visible[#visible + 1] = { t = t, entry = entry, expiring = expiring }
			end
		elseif show then
			visible[#visible + 1] = { t = t, entry = entry, expiring = expiring }
		end
	end
	LayoutGroup(f, g, visible, unlocked)
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
			if f:IsShown() then
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
		if overWindow then
			-- Over the window, the list knows best what a drop would do.
			local label = ns.UI and ns.UI.TreeDropLabel and ns.UI:TreeDropLabel(cy, self.dragTracker)
			self.text:SetText(label or self.windowText or "|cffff6060Cancel|r")
		elseif g then self.text:SetText("|cff40ff60Add to " .. ns.GroupName(g) .. "|r")
		else self.text:SetText(self.freeText or "Place here") end
	end)
	return ghost
end

function Display:BeginGhost(icon, freeText, except, windowText, dragTracker)
	local gh = GetGhost()
	gh.icon:SetTexture(icon or QUESTION)
	gh.freeText, gh.except, gh.windowText, gh.dragTracker = freeText, except, windowText, dragTracker
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
