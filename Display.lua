-- Aura Ledger display: the tracker groups on screen. Every group is a plain (non-secure) frame, so it
-- may show, hide and re-layout in combat. While unlocked every tracker is shown as a preview and the
-- groups can be dragged; dropping a lone tracker (or a Shift-dragged one) on another group joins it.

local ADDON, ns = ...
local Display = {}
ns.Display = Display

local QUESTION = ns.QUESTION
local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
-- Where a group is pinned. The two center growths are pinned by an edge midpoint rather than a
-- corner, so the trackers spread evenly either side of the place you put it.
local ANCHOR = { RIGHT = "TOPLEFT", DOWN = "TOPLEFT", LEFT = "TOPRIGHT", UP = "BOTTOMLEFT",
	CENTER_H = "TOP", CENTER_V = "LEFT" }
-- Growing from the center lays the trackers out the same way as its plain direction; only the
-- pinning differs, which is what makes the group spread rather than march off one way.
local FLOW = { CENTER_H = "RIGHT", CENTER_V = "DOWN" }
-- A cell's c and r are the group's own axes; these say which way each one points on screen, so a
-- side the cursor is held against can be turned into a cell whichever way the group grows.
-- In pixels: pa along the flow, pb across it.
local function PointAtCellPx(obj, f, flow, pa, pb)
	obj:ClearAllPoints()
	if flow == "RIGHT" then obj:SetPoint("TOPLEFT", f, "TOPLEFT", pa, -pb)
	elseif flow == "LEFT" then obj:SetPoint("TOPRIGHT", f, "TOPRIGHT", -pa, -pb)
	elseif flow == "DOWN" then obj:SetPoint("TOPLEFT", f, "TOPLEFT", pb, -pa)
	else obj:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", pb, pa) end
end
local function PointAtCell(obj, f, flow, a, b, stepX, stepY)
	if flow == "RIGHT" or flow == "LEFT" then PointAtCellPx(obj, f, flow, a * stepX, b * stepY)
	else PointAtCellPx(obj, f, flow, a * stepY, b * stepX) end
end
Display.PointAtCell = PointAtCell

local AXIS = {
	RIGHT = { c = { 1, 0 }, r = { 0, -1 } },
	LEFT = { c = { -1, 0 }, r = { 0, -1 } },
	DOWN = { c = { 0, -1 }, r = { 1, 0 } },
	UP = { c = { 0, 1 }, r = { 1, 0 } },
}
ns.GROWS = { { "RIGHT", "Right" }, { "LEFT", "Left" }, { "DOWN", "Down" }, { "UP", "Up" },
	{ "CENTER_H", "Center, sideways" }, { "CENTER_V", "Center, up and down" } }

local floor, max, min, ceil, abs = math.floor, math.max, math.min, math.ceil, math.abs

local active = {}   -- group uid -> frame
local pool = {}     -- released group frames
local ready = false

-- ------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------
-- (the grid is shown and hidden from Display:SyncGrid, called when arranging starts or stops)

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

-- The same rules, for the game to apply to a countdown it draws itself: the game's own format says
-- "45s" and keeps seconds up to 90, where the addon says "45" and turns to minutes at 60. Each rule
-- rounds first and then divides, which is what ns.FormatTime does. Made once and never changed.
local slotTimeFormatter, slotTimeFormatterTried
local function SlotTimeFormatter()
	if slotTimeFormatterTried then return slotTimeFormatter end
	slotTimeFormatterTried = true
	if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter) then return nil end
	local rounding = Enum and Enum.NumericRuleFormatRounding
	local nearest = rounding and rounding.Nearest or 0
	local ok, made = pcall(function()
		local f = C_StringUtil.CreateNumericRuleFormatter()
		f:SetBreakpoints({
			{ threshold = 0, rounding = nearest, format = "%.1f" },
			{ threshold = 10, step = 1, rounding = nearest, format = "%d" },
			{ threshold = 60, step = 60, rounding = nearest, format = "%dm", components = { { div = 60, rounding = nearest } } },
			{ threshold = 3600, step = 3600, rounding = nearest, format = "%dh", components = { { div = 3600, rounding = nearest } } },
		})
		return f
	end)
	if ok then slotTimeFormatter = made else ns.report["slot time text"] = "the game refused the format: " .. tostring(made) end
	return slotTimeFormatter
end

-- A colour for the countdown that the game picks from the time left: the text's own colour, and red
-- once less than the warn time is left. One per warn time and colour, shared, and never changed
-- once handed over.
local warnCurves = {}
local function SlotWarnCurve(warn, r, g, b)
	local key = warn .. ":" .. r .. ":" .. g .. ":" .. b
	if warnCurves[key] ~= nil then return warnCurves[key] or nil end
	local ok, curve = false, "no curves on this client"
	if C_CurveUtil and C_CurveUtil.CreateColorCurve and Enum and Enum.LuaCurveType and CreateColor then
		ok, curve = pcall(function()
			local cv = C_CurveUtil.CreateColorCurve()
			cv:SetType(Enum.LuaCurveType.Step)
			cv:AddPoint(0, CreateColor(1, 0.1, 0.1, 1))
			cv:AddPoint(warn, CreateColor(r, g, b, 1))
			return cv
		end)
	end
	warnCurves[key] = ok and curve or false
	if not ok then ns.report["slot warn colour"] = "not available: " .. tostring(curve) end
	return ok and curve or nil
end

-- Hands a slot its countdown text: our format, and the warning colour when there is a warn time.
-- A client that refuses an option still gets the rest, and at worst the game's own text.
local function BindSlotTime(button, fs, warn, r, g, b)
	local fmt = SlotTimeFormatter()
	local prop = Enum and Enum.DurationTextBindingProperty and Enum.DurationTextBindingProperty.RemainingDuration
	local curve = (warn and warn > 0 and prop ~= nil) and SlotWarnCurve(warn, r, g, b) or nil
	local opts = {}
	if fmt then opts.textFormatter = fmt end
	if curve then opts.textColor = { curve = curve, property = prop } end
	if next(opts) and pcall(button.SetDurationText, button, fs, opts) then
		ns.report["slot time text"] = "the addon's format" .. (curve and ", with the warning colour" or "")
		return
	end
	if curve and fmt and pcall(button.SetDurationText, button, fs, { textFormatter = fmt }) then
		ns.report["slot time text"] = "the addon's format; the game refused the warning colour"
		return
	end
	if curve and fmt and pcall(button.SetDurationText, button, fs, { textColor = opts.textColor }) then
		ns.report["slot time text"] = "the game's own format, with the warning colour; the game refused the addon's format"
		return
	end
	pcall(button.SetDurationText, button, fs)
	ns.report["slot time text"] = "the game's own format"
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

-- True when none of the values is hidden. A hidden value cannot even be tested, so every reading
-- of the game's frames goes through this before anything is done with it.
local function Plain(...)
	if not issecretvalue then return true end
	for i = 1, select("#", ...) do
		if issecretvalue((select(i, ...))) then return false end
	end
	return true
end

-- The Cooldown Manager's frames follow your auras, so while the game is hiding auras (and in a
-- fight) their sizes, places and colours can come back hidden. They are only measured outside that.
local function ManagerUnsafe()
	if InCombatLockdown and InCombatLockdown() then return true end
	return (ns.AurasSecret and ns.AurasSecret()) and true or false
end
Display.ManagerUnsafe = ManagerUnsafe

-- What a texture is drawn with: atlas or file, coords, blend, tint, layer.
local function DescribeTexture(tex)
	local d = {}
	local ok, atlas = pcall(tex.GetAtlas, tex)
	if ok and not Plain(atlas) then return nil end
	if ok and atlas and atlas ~= "" then
		d.atlas = atlas
	else
		local okt, file = pcall(tex.GetTexture, tex)
		if not okt or not Plain(file) or file == nil or file == "" then return nil end
		d.file = file
		local okc, ulx, uly, llx, lly, urx = pcall(tex.GetTexCoord, tex)
		if okc and Plain(ulx, uly, lly, urx) and ulx and urx and lly then d.coords = { ulx, urx, uly, lly } end
	end
	local okb, blend = pcall(tex.GetBlendMode, tex)
	if okb and Plain(blend) and blend then d.blend = blend end
	local okv, r, g, b, a = pcall(tex.GetVertexColor, tex)
	if okv and Plain(r, g, b, a) and r then d.color = { r, g, b, a or 1 } end
	local okl, layer, sub = pcall(tex.GetDrawLayer, tex)
	if okl and Plain(layer, sub) and layer then d.layer, d.sub = layer, sub or 0 end
	local oka, alpha = pcall(tex.GetAlpha, tex)
	if oka and Plain(alpha) and alpha then d.alpha = alpha end
	if tex.IsShown then
		local okS, shown = pcall(tex.IsShown, tex)
		if okS and Plain(shown) and not shown then d.hidden = true end
	end
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
	local okN, n = pcall(region.GetNumPoints, region)
	if not okN or not Plain(n) then return end
	n = n or 0
	if n == 0 then return end
	local okS, w, h = pcall(region.GetSize, region)
	if not okS or not Plain(w, h) then return end
	w, h = w or 0, h or 0
	local l, r, t, b
	local single
	for i = 1, n do
		local okP, p, rel, rp, x, y = pcall(region.GetPoint, region, i)
		if not okP or not Plain(p, rel, rp, x, y) then return end
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
	local okS, rw, rh = pcall(ref.GetSize, ref)
	if not okS or not Plain(rw, rh) then return end
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
	local okS, rw, rh = pcall(iconFrame.GetSize, iconFrame)
	if not okS or not Plain(rw, rh) then return end
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
	if not ok or not Plain(file, size, flags) or not file or not size or size <= 0 then return end
	local okR, _, rh = pcall(ref.GetSize, ref)
	if not okR or not Plain(rh) or not rh or rh <= 0 then return end
	local d = { file = file, size = size / rh, flags = flags }
	local okc, r, g, b = pcall(fs.GetTextColor, fs)
	if okc and Plain(r, g, b) and r then d.color = { r, g, b } end
	local okN, n = pcall(fs.GetNumPoints, fs)
	if okN and Plain(n) and (n or 0) >= 1 then
		local okP, p, rel, rp, x, y = pcall(fs.GetPoint, fs, 1)
		if okP and Plain(p, rel, rp, x, y) and p and (rel == nil or rel == ref) then d.p, d.rp, d.x, d.y = p, rp or p, (x or 0) / rh, (y or 0) / rh end
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

-- Whether the manager's shape was read, which decides how a tracker is drawn: with it, the picture
-- is kept whole so its own baked border can be rounded off, and the state color is a ring of that
-- shape rather than a frame over the top. Set when the skin is built, below.
local shapeInHand = false
local function HaveShape() return shapeInHand end

-- The crop to draw an icon with. A spell icon has a dark border baked into its outer edge, which is
-- why every frame in the game trims one, and a mask does not take it off: it rounds the corners of
-- whatever it is given, border and all. A donor that leans on a mask reports the whole picture, so
-- that answer is not worth keeping.
local function IconCrop(c)
	-- A spell icon's baked border is trimmed off, as the game trims it when it fills a slot itself.
	-- Keeping it made a tracker the addon drew look wider than the same one drawn by the game.
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

-- Where a live region sits against another, as fractions of that one's own width and height.
-- Positive reaches outwards. Read off the screen, so how either is anchored does not matter.
local function RelRect(region, ref)
	local ok, l1, r1, t1, b1 = pcall(function() return region:GetLeft(), region:GetRight(), region:GetTop(), region:GetBottom() end)
	local ok2, l2, r2, t2, b2 = pcall(function() return ref:GetLeft(), ref:GetRight(), ref:GetTop(), ref:GetBottom() end)
	if not (ok and ok2) or not Plain(l1, r1, t1, b1, l2, r2, t2, b2) then return end
	if not (l1 and r1 and t1 and b1 and l2 and r2 and t2 and b2) then return end
	local w, h = r2 - l2, t2 - b2
	if w <= 0 or h <= 0 then return end
	return { l = (l2 - l1) / w, r = (r1 - r2) / w, t = (t1 - t2) / h, b = (b2 - b1) / h }
end

-- The art a live texture wears, atlas or file, with its crop.
local function ArtOf(tex)
	local d = {}
	local okA, atlas = pcall(tex.GetAtlas, tex)
	if okA and not Plain(atlas) then return end
	if okA and atlas then
		d.atlas = atlas
	else
		local okF, file = pcall(tex.GetTexture, tex)
		if not okF or not Plain(file) or not file then return end
		d.file = file
		local okC, ulx, uly, llx, lly, urx = pcall(tex.GetTexCoord, tex)
		if okC and Plain(ulx, uly, lly, urx) and ulx and urx and lly then d.coords = { ulx, urx, uly, lly } end
	end
	return d
end

-- What the Cooldown Manager does to its own icon: the masks it clips it with, and the border art it
-- draws round it. Both measured against that icon, so they can be put on a tracker at any size.
local function ShapeFromDonor(item)
	if not item then return end
	local iconTex, iconFrame = FindIcon(item)
	if not IsA(iconTex, "Texture") then return end
	local shape = { masks = {} }
	local okN, n = pcall(function() return iconTex:GetNumMaskTextures() end)
	if okN and n then
		for i = 1, n do
			local okM, m = pcall(function() return iconTex:GetMaskTexture(i) end)
			if okM and m then
				local art = ArtOf(m)
				local rect = RelRect(m, iconTex)
				if art and rect then shape.masks[#shape.masks + 1] = { art = art, rect = rect } end
			end
		end
	end
	-- The border may hang on the item or on the frame the icon itself sits on.
	local holders = { item }
	if iconFrame and iconFrame ~= item then holders[2] = iconFrame end
	for _, key in ipairs({ "DebuffBorder", "Border", "IconBorder", "Overlay" }) do
	  for _, holder in ipairs(holders) do
		local region = holder[key]
		if IsA(region, "Texture") then
			local art, rect = ArtOf(region), RelRect(region, iconTex)
			if art and rect then shape.border = { art = art, rect = rect, key = key, region = region } break end
		elseif region and region.GetRegions then
			for _, r in ipairs({ region:GetRegions() }) do
				if IsA(r, "Texture") then
					local art, rect = ArtOf(r), RelRect(r, iconTex)
					if art and rect then shape.border = { art = art, rect = rect, key = key } break end
				end
			end
		end
		if shape.border then break end
	  end
	  if shape.border then break end
	end
	-- Everything else the item draws, kept with the layer it is drawn in: the art below the picture
	-- is what gives the manager's icons their shadow.
	shape.under, shape.over = {}, {}
	local seen = { [iconTex] = true }
	if shape.border then seen[shape.border.region] = true end
	for _, holder in ipairs(holders) do
		if holder.GetRegions then
			for _, r in ipairs({ holder:GetRegions() }) do
				if IsA(r, "Texture") and not seen[r] then
					seen[r] = true
					local okS, hidden = pcall(function() return not r:IsShown() end)
					local layer = (r.GetDrawLayer and r:GetDrawLayer()) or "ARTWORK"
					local art, rect = ArtOf(r), RelRect(r, iconTex)
					if art and rect and not (okS and hidden) then
						local into = (layer == "BACKGROUND" or layer == "BORDER") and shape.under or shape.over
						into[#into + 1] = { art = art, rect = rect, layer = layer }
					end
				end
			end
		end
	end
	if #shape.masks == 0 and not shape.border and #shape.under == 0 and #shape.over == 0 then return end
	return shape
end

-- The art round the manager's own bar, measured against that bar rather than reckoned from its
-- anchors. Everything but the fill, which is drawn as the bar's own texture.
local function BarShapeFromDonor(root, bar, fillTex)
	if not bar then return end
	local dw, dh = bar:GetWidth(), bar:GetHeight()
	dw, dh = dw or 0, dh or 0
	local aspect = (dh > 0) and (dw / dh) or 1
	local pieces, pip = {}, nil
	local seen = { [fillTex] = true }
	local holders = { bar }
	local mid = bar.GetParent and bar:GetParent()
	if mid and mid ~= UIParent then holders[#holders + 1] = mid end
	if root and root ~= bar and root ~= mid then holders[#holders + 1] = root end
	for _, holder in ipairs(holders) do
		if holder and holder.GetRegions then
			local okR, regions = pcall(function() return { holder:GetRegions() } end)
			for _, r in ipairs(okR and regions or {}) do
				if IsA(r, "Texture") and not seen[r] then
					seen[r] = true
					local okS, hidden = pcall(function() return not r:IsShown() end)
					if not (okS and hidden) then
						local art, rect = ArtOf(r), RelRect(r, bar)
						local layer, sub = "ARTWORK", 0
						if r.GetDrawLayer then local okL, l, sl = pcall(r.GetDrawLayer, r) if okL and l then layer, sub = l, sl or 0 end end
						-- The pip is the mark the manager slides along its own fill, so it is kept
						-- aside and drawn on the fill's leading edge rather than laid on the bar.
						local name = tostring(art and (art.atlas or art.file) or ""):lower()
						if art and rect and name:find("pip") then
							local w1, h1 = 0, 0
							if r.GetSize then w1, h1 = r:GetSize() end
							pip = { art = art, w = (w1 or 0) / (dh > 0 and dh or 1), h = (h1 or 0) / (dh > 0 and dh or 1) }
						elseif art and rect then
							pieces[#pieces + 1] = { art = art, rect = rect, layer = layer, sub = sub, aspect = aspect }
						end
					end
				end
			end
		end
	end
	if #pieces == 0 and not pip then return end
	return pieces, pip
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
	local s = { source = sourceName, fill = fill, decor = {}, iconDecor = {}, donorRoot = root }
	if root ~= bar then Collect(root, bar, nil, s.decor, true) end
	local mid = bar:GetParent()
	if mid and mid ~= root and mid ~= UIParent then Collect(mid, bar, nil, s.decor, true) end
	Collect(bar, bar, fillTex, s.decor, false)
	s.barShape, s.barPip = BarShapeFromDonor(root, bar, fillTex)
	-- The fill art is a pale strip and the manager colors it: without that color a bar is white
	-- where the manager's is orange.
	local okC, cr, cg, cb = pcall(function() return bar:GetStatusBarColor() end)
	if okC and cr and (cr < 0.99 or cg < 0.99 or cb < 0.99) then s.fillColor = { cr, cg, cb } end
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
	if ManagerUnsafe() then return end
	local okC, kids = pcall(function() return { viewer:GetChildren() } end)
	if not okC then return end
	local fallback
	for _, child in ipairs(kids) do
		if FindStatusBar(child, 0) or FindIcon(child) then
			-- A hidden item has no place on screen, and its art cannot be measured. Most of a
			-- display's pool is hidden, so the one that is showing is the one worth reading.
			local okS, shown = pcall(function() return child:IsShown() end)
			if okS and Plain(shown) and shown then return child end
			fallback = fallback or child
		end
	end
	return fallback
end

Display.ViewerDonorForTest = function(v) return ViewerDonor(v) end

local skin

-- How an icon is edged. "clean" is a thin dark line drawn by the addon, which is what an icon wears
-- everywhere else in the game; the client's own frame atlas and the Cooldown Manager's overlay are
-- both, on this client, the shape of a tab, rounded along the top and flat along the bottom.
local function BorderMode()
	local m = ns.db and ns.db.iconBorder
	if m == "client" or m == "cdm" or m == "none" then return m end
	return "clean"
end

-- The frame this client draws round its own icons, if it has one. It is drawn by its own two
-- numbers, not the mask's: the mask is a shape that has to be grown by about a quarter before it
-- fits an icon, while this is art that sits on one with a thin border.
local clientFrame, clientFrameTried
local function ClientIconFrame()
	if BorderMode() ~= "client" then return nil end
	if not clientFrameTried then
		clientFrameTried = true
		for _, atlas in ipairs(ns.ICON_FRAMES or {}) do
			if HasAtlas(atlas) then clientFrame = atlas break end
		end
		ns.report["icon frame"] = clientFrame or "none on this client, the Cooldown Manager's overlay is used"
	end
	return clientFrame
end

-- A thin dark line round the icon, the way the game edges an icon that has no frame of its own.
-- The edge is four thin bars laid along the inside of the picture, not a block behind it: a block
-- shows only where it sticks out, and anything sticking out reaches into the gap between one cell
-- and the next, and is not covered by the game's icon on a cell the game fills.
-- Places a region by a rectangle measured off the donor: outwards is positive, and both axes scale
-- with the icon, which is square, so the shape keeps its proportions.
local function ApplyRectWH(tex, ref, rect, w, h)
	tex:ClearAllPoints()
	tex:SetPoint("TOPLEFT", ref, "TOPLEFT", -rect.l * w, rect.t * h)
	tex:SetPoint("BOTTOMRIGHT", ref, "BOTTOMRIGHT", rect.r * w, -rect.b * h)
end

-- The art round a bar, on the bar. Returns whether there was any.
local function PlaceBarShape(w, ref, width, height, want)
	local s = skin
	-- The measurement is right for art that stretches with the bar and wrong for a frame round it,
	-- and what a bar copies is a frame: the old placement, which reckons everything in pixels off
	-- the donor's height, is what fits. Kept for comparison, not for the asking.
	local pieces = (not (ns.db and ns.db.barArt == "reckoned")) and (s and s.barShape) or nil
	local pool = w.barShape or {}
	w.barShape = pool
	if not pieces or not want then
		for _, tex in ipairs(pool) do tex:Hide() tex.alWanted = false end
		return false
	end
	for i, def in ipairs(pieces) do
		local tex = pool[i]
		if not tex then
			local under = def.layer == "BACKGROUND" or def.layer == "BORDER"
			tex = (under and (w.under or w) or (w.over or w)):CreateTexture(nil, def.layer, nil, def.sub)
			if def.art.atlas then tex:SetAtlas(def.art.atlas)
			else
				tex:SetTexture(def.art.file)
				if def.art.coords then tex:SetTexCoord(def.art.coords[1], def.art.coords[2], def.art.coords[3], def.art.coords[4]) end
			end
			pool[i] = tex
		end
		-- The piece drawn behind is the plate the manager's bars wear, gold frame and all, sized for
		-- the manager's own item: it is laid on the bar rather than given the reach it was measured
		-- with. Sideways, any other reach is so many pixels of the bar's height, because a frame
		-- that grows with the bar's width is a fat inset on a long bar and a hairline on a short one.
		-- Sideways the plate is laid on the bar, because it is sized for the manager's whole item.
		-- Up and down it keeps the height it was measured with, or the frame drawn on it is
		-- squashed, but that height is shared evenly above and below: on the manager's items the
		-- plate covers the padding under its bar, so carried over as measured it sits low.
		local rect = def.rect
		if def.layer == "BACKGROUND" then
			-- The plate is laid on the bar and then reaches out by whatever it is told on each of
			-- the four sides: where the frame sits inside this art cannot be read from outside, so
			-- the reach is set by eye. Up and down it shares out what was measured until it is.
			-- Where the frame sits inside this art cannot be read from outside; these are where it
			-- was found to sit by eye, against the manager's own bars. The measured reach, shared
			-- evenly, is what "even" falls back to.
			local half = ((rect.t or 0) + (rect.b or 0)) / 2
			local t = tonumber(ns.db and ns.db.plateTop) or 0.08
			local b = tonumber(ns.db and ns.db.plateBottom) or 0.35
			if ns.db and ns.db.plateEven then t, b = half, half end
			-- Sideways is scaled by the donor bar's shape when it is drawn, so these are divided by
			-- it here: on the panel they mean shares of the bar's height, as every other number does.
			local across = (def.aspect or 1)
			if across <= 0 then across = 1 end
			local l = (tonumber(ns.db and ns.db.plateLeft) or 0) / across
			local r = (tonumber(ns.db and ns.db.plateRight) or 0) / across
			rect = { l = l, r = r, t = t or half, b = b or half }
		end
		ApplyRectWH(tex, ref, rect, (def.aspect or 1) * height, height)
		tex:Show()
		tex.alWanted = true
	end
	for i = #pieces + 1, #pool do pool[i]:Hide() pool[i].alWanted = false end
	return true
end

local function ApplyRect(tex, ref, rect, size)
	tex:ClearAllPoints()
	tex:SetPoint("TOPLEFT", ref, "TOPLEFT", -rect.l * size, rect.t * size)
	tex:SetPoint("BOTTOMRIGHT", ref, "BOTTOMRIGHT", rect.r * size, -rect.b * size)
end

-- The manager's own mask, on our icon. Returns whether it could.
local function ShapeMask(w, icon, size, want, key)
	key = key or "shapeMasks"
	local s = skin
	local shape = s and s.shape
	if not want or not shape or #shape.masks == 0 or not icon.AddMaskTexture then
		for _, m in ipairs(w[key] or {}) do
			if icon.RemoveMaskTexture then pcall(icon.RemoveMaskTexture, icon, m) end
			pcall(m.Hide, m)
		end
		w[key] = nil
		return false
	end
	-- Masks belong to the texture they were added to; a different one needs its own.
	if w[key] and w[key .. "On"] ~= icon then
		for _, m in ipairs(w[key]) do pcall(m.Hide, m) end
		w[key] = nil
	end
	if not w[key] then
		w[key] = {}
		w[key .. "On"] = icon
		for i, def in ipairs(shape.masks) do
			local ok, m = pcall(function() return (w.over or w):CreateMaskTexture() end)
			if ok and m then
				if def.art.atlas then pcall(m.SetAtlas, m, def.art.atlas)
				else pcall(m.SetTexture, m, def.art.file) end
				if pcall(icon.AddMaskTexture, icon, m) then w[key][#w[key] + 1] = m
				else pcall(m.Hide, m) end
			end
		end
	end
	for i, m in ipairs(w[key]) do
		local def = shape.masks[i]
		if def then ApplyRect(m, icon, def.rect, size) end
	end
	return #w[key] > 0
end

-- The manager's border art, which carries the state color: white while the aura is there, red
-- while it is missing or nearly gone, the dispel color on a debuff.
local function ShapeBorder(w, icon, size, want, r, g, b)
	local s = skin
	local def = s and s.shape and s.shape.border
	if not want or not def then
		if w.shapeBorder then w.shapeBorder:Hide() end
		return false
	end
	local tex = w.shapeBorder
	if not tex then
		tex = (w.over or w):CreateTexture(nil, "OVERLAY", nil, 5)
		if def.art.atlas then tex:SetAtlas(def.art.atlas)
		else
			tex:SetTexture(def.art.file)
			if def.art.coords then tex:SetTexCoord(def.art.coords[1], def.art.coords[2], def.art.coords[3], def.art.coords[4]) end
		end
		w.shapeBorder = tex
	end
	ApplyRect(tex, icon, def.rect, size)
	tex:SetVertexColor(r or 1, g or 1, b or 1)
	tex:Show()
	return true
end

-- A ring of color in the manager's own shape, behind the picture and a little larger, so what
-- shows is a rounded edge rather than a square frame laid over the icon.
-- "icon" is what the ring is laid on: the cell, so it fills the room the picture was pulled off.
local function ShapeRing(w, icon, size, want, r, g, b)
	local s = skin
	local def = HaveShape() and s.shape.masks[1]
	if not want or not def then
		if w.shapeRing then w.shapeRing:Hide() end
		return false
	end
	local tex = w.shapeRing
	if not tex then
		tex = (w.under or w):CreateTexture(nil, "BACKGROUND", nil, -5)
		w.shapeRing = tex
		local ok, m = pcall(function() return (w.under or w):CreateMaskTexture() end)
		if ok and m then
			if def.art.atlas then pcall(m.SetAtlas, m, def.art.atlas) else pcall(m.SetTexture, m, def.art.file) end
			m:SetAllPoints(tex)
			if not (tex.AddMaskTexture and pcall(tex.AddMaskTexture, tex, m)) then pcall(m.Hide, m) end
		end
	end
	tex:SetColorTexture(r or 1, g or 0.2, b or 0.2, 1)
	tex:ClearAllPoints()
	-- Flush with the picture. Anything past it reaches into the next cell, and past a cell under a
	-- game-drawn slot it is not covered by the game's icon and shows round the outside of it.
	tex:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, 0)
	tex:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, 0)
	tex:Show()
	return true
end

-- A cooldown draws with textures of its own on a frame laid over the picture. They are made when
-- the cooldown first runs, so this is asked again whenever one is set going.
local cdKeys, cdNext = setmetatable({}, { __mode = "k" }), 0
local function ShapeCooldown(w, cd, size, want)
	if not cd or not cd.GetRegions then return false end
	local ok, regions = pcall(function() return { cd:GetRegions() } end)
	if not ok then return false end
	-- One set of keys per cooldown: a frame can carry more than one.
	local tag = cdKeys[cd]
	if not tag then
		cdNext = cdNext + 1
		tag = "cdMasks" .. cdNext .. "_"
		cdKeys[cd] = tag
	end
	local n = 0
	for _, r in ipairs(regions) do
		if IsA(r, "Texture") then
			n = n + 1
			ShapeMask(w, r, size, want, tag .. n)
		end
	end
	-- A cooldown draws its swipe itself and need not hand out a texture for it. Where it does not,
	-- there is nothing to round off, and a square swipe over a rounded icon is worse than none.
	if n == 0 and want and HaveShape() then
		if cd.SetDrawSwipe then pcall(cd.SetDrawSwipe, cd, false) end
		if cd.SetDrawEdge then pcall(cd.SetDrawEdge, cd, false) end
		if cd.SetDrawBling then pcall(cd.SetDrawBling, cd, false) end
		ns.report["cooldown swipe"] = "off: this client's cooldowns hand out no texture to mask"
	end
	return n > 0
end

-- The art the manager draws round its own icon, below the picture and above it, which is what
-- gives its icons their shadow. Placed by the rectangles measured off that icon.
-- How deep the shadow is: how many times the manager's own art is laid on. One is what the manager
-- draws; the default is two, which is what a tracker the game drew used to end up with by accident
-- and what the shadow is supposed to look like. "already" is how many are on there before the addon
-- draws any, which is one on a slot the game fills, since it draws its own.
local function ShadowLayers(already)
	local want = tonumber(ns.db and ns.db.shadowLayers)
	if want == nil then want = 2 end
	if want < 0 then want = 0 elseif want > 4 then want = 4 end
	return max(0, want - (already or 0))
end

local function ShapeArt(w, icon, size, want, already)
	local s = skin
	local shape = s and s.shape
	local layers = ShadowLayers(already)
	local lists = { { shape and shape.under, "under" }, { shape and shape.over, "over" } }
	local drew = false
	for _, pair in ipairs(lists) do
		local base, where = pair[1] or {}, pair[2]
		-- The art, laid on as many times as the shadow is deep.
		local list = {}
		for _ = 1, layers do
			for _, def in ipairs(base) do list[#list + 1] = def end
		end
		local pool = w["shapeArt_" .. where] or {}
		w["shapeArt_" .. where] = pool
		for i, def in ipairs(want and list or {}) do
			local tex = pool[i]
			if not tex then
				tex = (where == "under" and (w.under or w) or (w.over or w)):CreateTexture(nil, def.layer or "ARTWORK",
					nil, where == "under" and -4 or 4)
				if def.art.atlas then tex:SetAtlas(def.art.atlas)
				else
					tex:SetTexture(def.art.file)
					if def.art.coords then tex:SetTexCoord(def.art.coords[1], def.art.coords[2], def.art.coords[3], def.art.coords[4]) end
				end
				pool[i] = tex
			end
			ApplyRect(tex, icon, def.rect, size)
			tex:Show()
			drew = true
		end
		for i = (want and #list or 0) + 1, #pool do pool[i]:Hide() end
	end
	return drew
end

-- A drop shadow: the icon's own shape in black, behind the picture, a little larger and a little
-- lower. Drawn only where the manager handed none over, and masked so it is the icon's shape
-- rather than a square behind a rounded corner.
-- The client's own soft shadows, best first. A flat shape is a silhouette, not a shadow, so one of
-- these is wanted; without any, none is drawn at all.
-- When the manager's art could not be copied: its own icon overlay, at the reach measured off its
-- icons (shares of the picture's size). What lies past the picture is the shadow. Nothing else is
-- tried: art named in hope has the wrong shape here (the spellbook's item shadow, used once, is the
-- outline of a spellbook entry, not an icon's shadow).
local SHADOW_ART = { atlas = "UI-HUD-CoolDownManager-IconOverlay", l = 0.200, r = 0.200, t = 0.175, b = 0.175 }
local shadowAtlas, shadowTried
local function ShadowArt()
	if not shadowTried then
		shadowTried = true
		if HasAtlas(SHADOW_ART.atlas) then shadowAtlas = SHADOW_ART.atlas end
		ns.report["icon shadow"] = shadowAtlas or "the manager's icon overlay is not present"
	end
	return shadowAtlas
end

local function ShapeShadow(w, icon, size, want)
	local s = skin
	-- Anything copied off the manager counts: on this client the shadow is its icon overlay, which
	-- is drawn over the picture rather than under it.
	local have = s and s.shape and (#(s.shape.under or {}) > 0 or #(s.shape.over or {}) > 0)
	local atlas = ShadowArt()
	local on = want and not have and atlas ~= nil
	local tex = w.shapeShadow
	if not on then
		if tex then tex:Hide() end
		return false
	end
	if not tex then
		tex = (w.under or w):CreateTexture(nil, "BACKGROUND", nil, -3)
		tex:SetAtlas(atlas)
		w.shapeShadow = tex
	end
	-- Soft art spreads past what it shadows, which is where the softness lives, so it is drawn
	-- larger than the picture rather than masked to the picture's own shape.
	tex:ClearAllPoints()
	tex:SetPoint("TOPLEFT", icon, "TOPLEFT", -size * SHADOW_ART.l, size * SHADOW_ART.t)
	tex:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", size * SHADOW_ART.r, -size * SHADOW_ART.b)
	tex:Show()
	return true
end

-- Every cooldown on a frame: the one the addon gave it and any the game runs itself.
local function ShapeCooldownsOn(w, frame, size, want)
	if not frame then return end
	ShapeCooldown(w, frame.alCd, size, want)
	-- The frame may be the game's own, which refuses to be walked; that is not an error worth making.
	local ok, kids = pcall(function() return { frame:GetChildren() } end)
	if not ok then return end
	for _, kid in ipairs(kids) do
		local okT, kind = pcall(function() return kid:GetObjectType() end)
		if okT and kind == "Cooldown" and kid ~= frame.alCd then
			ShapeCooldown(w, kid, size, want)
		end
	end
end

-- Just the color, for a border already in place.
local function ShapeBorderColor(w, r, g, b)
	local tex = w.shapeBorder
	if not tex or tex:IsShown() == false then return false end
	tex:SetVertexColor(r or 1, g or 1, b or 1)
	return true
end

local function EdgeBars(w)
	if not w.edgeBars then
		local owner = w.over or w
		w.edgeBars = {}
		for i = 1, 4 do
			w.edgeBars[i] = owner:CreateTexture(nil, "OVERLAY", nil, 6)
		end
		w.cleanEdge = w.edgeBars[1]
	end
	return w.edgeBars
end

local function LayEdge(w, r, g, b, a, thicker)
	local bars = w.edgeBars
	local lead = bars and bars[1]
	if not lead or not lead.alRef then return false end
	local ref = lead.alRef
	local px = max(1, lead.alPx or 1)
	if thicker then px = px + max(1, floor(px * 0.5)) end
	-- Always inside the picture. Outside, the bars reach into the gap between one cell and the
	-- next, so cells look joined up, and a cell under a slot the game fills cannot reach out at all.
	local out = 0
	local top, bottom, left, right = bars[1], bars[2], bars[3], bars[4]
	top:ClearAllPoints()
	top:SetPoint("TOPLEFT", ref, "TOPLEFT", -out, out)
	top:SetPoint("TOPRIGHT", ref, "TOPRIGHT", out, out)
	top:SetHeight(px)
	bottom:ClearAllPoints()
	bottom:SetPoint("BOTTOMLEFT", ref, "BOTTOMLEFT", -out, -out)
	bottom:SetPoint("BOTTOMRIGHT", ref, "BOTTOMRIGHT", out, -out)
	bottom:SetHeight(px)
	left:ClearAllPoints()
	left:SetPoint("TOPLEFT", ref, "TOPLEFT", -out, out)
	left:SetPoint("BOTTOMLEFT", ref, "BOTTOMLEFT", -out, -out)
	left:SetWidth(px)
	right:ClearAllPoints()
	right:SetPoint("TOPRIGHT", ref, "TOPRIGHT", out, out)
	right:SetPoint("BOTTOMRIGHT", ref, "BOTTOMRIGHT", out, -out)
	right:SetWidth(px)
	for _, tex in ipairs(bars) do
		tex:SetColorTexture(r, g, b, a)
		tex:Show()
	end
	return true
end

local function PlaceCleanEdge(w, ref, size, want, inward)
	-- The manager's shape does the edging where it was read: its mask rounds the picture's own
	-- border off, and square bars over that is what put a sharp red frame round a rounded icon.
	local shaped = (want ~= false) and BorderMode() == "clean" and HaveShape()
	local on = (want ~= false) and BorderMode() == "clean" and not shaped
	if not on then
		for _, tex in ipairs(w.edgeBars or {}) do tex:Hide() end
		return false
	end
	local bars = EdgeBars(w)
	bars[1].alPx = max(1, floor(size / 24 + 0.5))
	bars[1].alRef = ref
	bars[1].alInward = inward or nil
	return LayEdge(w, 0, 0, 0, 0.9, false)
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
	local withoutManager = ManagerUnsafe()
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
	s.withoutManager = withoutManager or nil
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
	do
		-- Every display, best answer wins: a border is what is wanted most, then a mask. On this
		-- client the tracked-buff items carry a DebuffBorder and the essential ones do not.
		local tried = {}
		for _, v in ipairs({ { "tracked buffs", BuffIconCooldownViewer }, { "essential", EssentialCooldownViewer },
			{ "utility", UtilityCooldownViewer }, { "tracked bars", BuffBarCooldownViewer } }) do
			local donor = v[2] and ViewerDonor(v[2])
			local shape = donor and ShapeFromDonor(donor)
			if shape then
				tried[#tried + 1] = v[1] .. " (" .. #shape.masks .. " mask" .. (#shape.masks == 1 and "" or "s")
					.. ", " .. (shape.border and "border" or "no border") .. ")"
				if shape.border and (not s.shape or not s.shape.border) then
					s.shape = shape
					s.shapeFrom = v[1]
				elseif not s.shape then
					s.shape = shape
					s.shapeFrom = v[1]
				end
			else
				tried[#tried + 1] = v[1] .. " (nothing)"
			end
		end
		if not s.shape and s.donorRoot then
			s.shape = ShapeFromDonor(s.donorRoot)
			if s.shape then s.shapeFrom = "the bar this skin came from" end
		end
		shapeInHand = (s.shape and #s.shape.masks > 0) and true or false
		ns.report["icon shape tried"] = table.concat(tried, ", ")
		do
			ns.report["icon shape"] = s.shape
				and ((#s.shape.masks .. " mask" .. (#s.shape.masks == 1 and "" or "s"))
					.. ", border " .. (s.shape.border and (s.shape.border.art.atlas or tostring(s.shape.border.art.file)) or "none")
					.. ", " .. #(s.shape.under or {}) .. " under and " .. #(s.shape.over or {}) .. " over")
				or "not readable on this client"
			if s.shape then ns.report["icon shape"] = ns.report["icon shape"] .. ", from " .. tostring(s.shapeFrom) end
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
	-- Tinting: a file fill from the old art needs color; copied art is already colored.
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
Display.HaveShape = function() return HaveShape() end
Display.IconCrop = IconCrop
Display.BorderMode = BorderMode
Display.EvenOverhang = EvenOverhang
Display.IconInset = IconInset

-- One line for a string on screen: what it says, how wide it is allowed to be, and where it is
-- pinned. Two strings landing on each other shows up here and nowhere else.
local function TextLine(label, fs)
	if not fs then return label .. ": none" end
	local shown = "hidden"
	if fs.IsShown then
		local okS, v = pcall(fs.IsShown, fs)
		if okS and not Plain(v) then shown = "(hidden value)" elseif okS and v then shown = "shown" end
	end
	local text = ""
	if fs.GetText then
		local okT, v = pcall(fs.GetText, fs)
		if okT and not Plain(v) then text = "(hidden value)" elseif okT and v then text = v end
	end
	local w, h = 0, 0
	if fs.GetSize then
		local okZ, a, b = pcall(fs.GetSize, fs)
		if okZ and Plain(a, b) then w, h = a or 0, b or 0 end
	end
	local strw = 0
	if fs.GetStringWidth then
		local okW, v = pcall(fs.GetStringWidth, fs)
		if okW and Plain(v) then strw = v or 0 end
	end
	local pts = ""
	if fs.GetNumPoints and fs.GetPoint then
		for i = 1, (fs:GetNumPoints() or 0) do
			local p, rel, rp, x, y = fs:GetPoint(i)
			if p then pts = pts .. (" [%s->%s %+.1f %+.1f]"):format(p, tostring(rp), x or 0, y or 0) end
		end
	end
	return ("%s: %q, %s, box %.0fx%.0f, text wants %.0f%s"):format(label, tostring(text), shown, w or 0, h or 0, strw, pts)
end

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

-- Every frame and texture on one of the manager's items, with what it wears and where it sits
-- against the icon. This is how the shadow, or anything else that is wanted, gets named.
function Display:ProbeItem(emit)
	if ManagerUnsafe() then
		emit("not now: in a fight, or while the game is hiding auras, the manager's items can answer with hidden values")
		return
	end
	local donor
	for _, v in ipairs({ { "tracked buffs", BuffIconCooldownViewer }, { "essential", EssentialCooldownViewer },
		{ "utility", UtilityCooldownViewer }, { "tracked bars", BuffBarCooldownViewer } }) do
		local item = v[2] and ViewerDonor(v[2])
		if item then donor = { name = v[1], item = item } break end
	end
	if not donor then emit("no item of the manager's to look at") return end
	local iconTex = FindIcon(donor.item)
	emit("walking a " .. donor.name .. " item" .. (iconTex and "" or " (no icon found on it)"))
	local function walk(frame, depth, label)
		if depth > 3 or not frame then return end
		local pad = string.rep("  ", depth + 1)
		if frame.GetRegions then
			local okR, regions = pcall(function() return { frame:GetRegions() } end)
			for _, r in ipairs(okR and regions or {}) do
				if IsA(r, "Texture") then
					local art = ArtOf(r) or {}
					local layer, sub = "?", 0
					if r.GetDrawLayer then local okL, l, sl = pcall(r.GetDrawLayer, r) if okL then layer, sub = l, sl or 0 end end
					local shown = (r.IsShown and r:IsShown()) and "shown" or "hidden"
					local alpha = (r.GetAlpha and r:GetAlpha()) or 1
					local rect = iconTex and RelRect(r, iconTex)
					emit(("%s%s: %s, %s %s, %s, alpha %.2f%s"):format(pad, label, tostring(art.atlas or art.file or "?"),
						tostring(layer), tostring(sub), shown, alpha,
						rect and (", reaches l %.3f r %.3f t %.3f b %.3f"):format(rect.l, rect.r, rect.t, rect.b) or ""))
				end
			end
		end
		if frame.GetChildren then
			local okC, kids = pcall(function() return { frame:GetChildren() } end)
			for i, kid in ipairs(okC and kids or {}) do
				local kind = (kid.GetObjectType and kid:GetObjectType()) or "?"
				emit(("%schild %d: %s"):format(pad, i, tostring(kind)))
				walk(kid, depth + 1, "texture")
			end
		end
	end
	walk(donor.item, 0, "texture")
	local parent = donor.item.GetParent and donor.item:GetParent()
	if parent then
		emit("its display, one level up:")
		walk(parent, 0, "texture")
	end
end

-- What the icon art came out as: the donor, the box it was measured in, and each piece's reach past
-- the icon. Read by /auraledger debug icon.
function Display:IconReport(emit)
	local s = BuildSkin()
	do
		local hh = 20
		local t = (not (ns.db and ns.db.plateEven)) and (tonumber(ns.db and ns.db.plateTop) or 0.08) or nil
		local b = (not (ns.db and ns.db.plateEven)) and (tonumber(ns.db and ns.db.plateBottom) or 0.35) or nil
		emit(("bar plate reach: %s above, %s below, %.3f left, %.3f right (shares of the bar's height)"):format(
			t and ("%.3f"):format(t) or "even", b and ("%.3f"):format(b) or "even",
			tonumber(ns.db and ns.db.plateLeft) or 0, tonumber(ns.db and ns.db.plateRight) or 0))
	end
	if Display.BarOffset then
		local x, y = Display.BarOffset(20)
		emit(("bar sits at height 20: %d sideways, %d up (/auraledger tune)"):format(x, y))
	end
	if Display.BarInset then
		local x, y = Display.BarInset(20)
		emit(("bar fill margin at height 20: %d sideways, %d up and down (/auraledger barfill <x> <y>)"):format(x, y))
	end
	emit("bar fill color: " .. (s.fillColor and ("%.2f %.2f %.2f"):format(s.fillColor[1], s.fillColor[2], s.fillColor[3]) or "as the art came"))
	emit("bar skin from: " .. tostring(s.source) .. (s.backdrop and " (no art: a plain border is drawn instead)" or ""))
	for i, def in ipairs(s.barShape or {}) do
		emit(("  bar art %d: %s (%s %d), reaches l %.3f r %.3f t %.3f b %.3f of the donor's bar"):format(i,
			tostring(def.art.atlas or def.art.file), tostring(def.layer), def.sub or 0,
			def.rect.l, def.rect.r, def.rect.t, def.rect.b))
	end
	emit("icon art from: " .. tostring(s.iconSource or s.source))
	emit("icon edge: " .. BorderMode())
	emit(("shadow depth: %d layer%s of the manager's own art (/auraledger shadow <0-4>)"):format(ShadowLayers(0), ShadowLayers(0) == 1 and "" or "s"))
	emit("shadow: " .. ((skin and skin.shape and (#(skin.shape.under or {}) > 0 or #(skin.shape.over or {}) > 0)) and "copied from the manager"
		or (ShadowArt() and ("drawn by the addon with " .. tostring(ShadowArt())) or "none: " .. tostring(ns.report["icon shadow"]))))
	emit("icon shape from the manager: " .. tostring(ns.report["icon shape"] or "not looked for yet"))
	emit("  displays tried: " .. tostring(ns.report["icon shape tried"] or "none"))
	local sh = skin and skin.shape
	for i, m in ipairs((sh and sh.masks) or {}) do
		emit(("  mask %d: %s, reaches l %.3f r %.3f t %.3f b %.3f"):format(i, tostring(m.art.atlas or m.art.file), m.rect.l, m.rect.r, m.rect.t, m.rect.b))
	end
	for _, where in ipairs({ "under", "over" }) do
		for i, a in ipairs((sh and sh[where]) or {}) do
			emit(("  %s %d: %s (%s), reaches l %.3f r %.3f t %.3f b %.3f"):format(where, i,
				tostring(a.art.atlas or a.art.file), tostring(a.layer), a.rect.l, a.rect.r, a.rect.t, a.rect.b))
		end
	end
	if sh and sh.border then
		emit(("  border: %s from %s, reaches l %.3f r %.3f t %.3f b %.3f"):format(
			tostring(sh.border.art.atlas or sh.border.art.file), tostring(sh.border.key),
			sh.border.rect.l, sh.border.rect.r, sh.border.rect.t, sh.border.rect.b))
	end
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
			for _, where in ipairs({ "under", "over" }) do
				local pool = w["shapeArt_" .. where] or {}
				emit(("    copied %s: %d piece%s"):format(where, #pool, #pool == 1 and "" or "s"))
				for i, tex in ipairs(pool) do emit("      " .. TexLine(where .. " " .. i, tex)) end
			end
			emit("    " .. TexLine("the addon's own shadow", w.shapeShadow))
			emit("    " .. TexLine("state ring", w.shapeRing))
			if g.style == "bars" then
				emit("    bar: " .. (w.bar and ((w.bar:IsShown() and "shown" or "hidden") .. (", %.0fx%.0f"):format(w.bar:GetWidth() or 0, w.bar:GetHeight() or 0)) or "none"))
				emit("      " .. TexLine("fill", w.fill))
				emit("      " .. TexLine("background", w.bar and w.bar.bg))
				emit("      " .. TexLine("pip", w.bar and w.bar.spark))
				emit("      fallback border frame: " .. (w.edge and ((w.edge:IsShown() and "shown" or "hidden") .. " (the skin had no art of its own)") or "none"))
				emit("      " .. TextLine("name", w.name))
				emit("      " .. TextLine("time", w.duration))
				emit("      frame: " .. ((Display.HaveBarFrame and Display.HaveBarFrame()) and "copied from the client"
					or ("drawn by the addon, " .. #(w.barFrame or {}) .. " lines")))
				-- And the slot's own bar, which the game draws over this cell.
				local f2 = Display.ActiveFrame and Display:ActiveFrame(g.uid)
				local sc = f2 and f2.slotC and f2.slotC.player
				local anySlot
				for _, fr in pairs((sc and sc.alSlots) or {}) do
					if fr and fr.alBar then anySlot = fr break end
				end
				if anySlot then
					emit("      (the game draws these while the window is shut; with it open the addon does)")
					local sb = anySlot.alBar
					-- Anything the game answers here can be a secret value, and a secret cannot even
					-- be tested, so every reading is taken through a guard and printed as a number
					-- or not at all.
					local function Num(get)
						local ok, v = pcall(get)
						if ok and Plain(v) and type(v) == "number" then return ("%.0f"):format(v) end
						return "?"
					end
					emit(("      the game's own bar: %s wide, %s tall"):format(
						Num(function() return sb:GetWidth() end), Num(function() return sb:GetHeight() end)))
					local pts = ""
					local okP, n = pcall(function() return sb:GetNumPoints() end)
					for i = 1, (okP and type(n) == "number" and n or 0) do
						local okPt, p, _, rp, x, y = pcall(function() return sb:GetPoint(i) end)
						if okPt and type(p) == "string" then
							pts = pts .. (" [%s->%s %s %s]"):format(p, tostring(rp),
								type(x) == "number" and ("%+.1f"):format(x) or "?",
								type(y) == "number" and ("%+.1f"):format(y) or "?")
						end
					end
					emit("        pinned" .. (pts ~= "" and pts or ": the game will not say"))
					local okIcon, iconLine = pcall(TexLine, "its icon", anySlot.alIcon)
					emit("        " .. (okIcon and iconLine or "its icon: the game will not say"))
					local pool = anySlot.alBarArt and (anySlot.alBarArt.barShape or anySlot.alBarArt.decor) or {}
					emit(("        its plate: %d piece%s"):format(#pool, #pool == 1 and "" or "s"))
					for i, tex in ipairs(pool) do
						local okT, line = pcall(TexLine, "piece " .. i, tex)
						emit("          " .. (okT and line or ("piece " .. i .. ": the game will not say")))
					end
				else
					emit("      the game's own bar: none on screen")
				end
				local shaped = w.barShape or {}
				emit(("      bar art measured off the donor's bar: %d piece%s"):format(#shaped, #shaped == 1 and "" or "s"))
				for i, tex in ipairs(shaped) do emit("        " .. TexLine("piece " .. i, tex)) end
				local pool = w.decor or {}
				emit(("      bar art by the old reckoning: %d piece%s"):format(#pool, #pool == 1 and "" or "s"))
				for i, tex in ipairs(pool) do emit("        " .. TexLine("piece " .. i, tex)) end
			end
			emit("    shape masks on the picture: " .. tostring(w.shapeMasks and #w.shapeMasks or 0))
			emit("    " .. TexLine("dispel border", w.border))
			emit("    mask: " .. (w.icon and w.icon.alMask and "on" or "off"))
			if w.icon and w.icon.alMask then emit("    " .. TexLine("mask art", w.icon.alMask)) end
		end
	end
end

-- ------------------------------------------------------------------
-- Tracker widgets
-- ------------------------------------------------------------------
-- Icons marked with shift-click, to be moved as one. Held by tracker, and only while arranging.
local marked = {}
function Display:ForgetMarks() marked = {} end

function Display:IsMarked(t) return t ~= nil and marked[t] == true end

function Display:ToggleMark(t)
	if not t then return end
	if marked[t] then marked[t] = nil else marked[t] = true end
	self:Rebuild()
end

function Display:ClearMarks()
	if not next(marked) then return end
	marked = {}
	self:Rebuild()
end

-- The marked ones, in the order their group lists them, so they land in a predictable order.
function Display:MarkedList(g)
	local out = {}
	if not ns.profile then return out end
	for _, group in ipairs(ns.profile.groups) do
		if not g or group == g then
			for _, t in ipairs(group.trackers) do
				if marked[t] then out[#out + 1] = t end
			end
		end
	end
	return out
end

function Display:MarkedCount() return #self:MarkedList() end

local function WidgetTooltip(w)
	local t = w.tracker
	if not t then return end
	-- Something is on the cursor: its own label says what the drop would do, and a tooltip here
	-- would cover the icons being aimed at.
	if Display.Dragging and Display:Dragging() then return end
	GameTooltip:SetOwner(w, "ANCHOR_RIGHT")
	local shown = false
	if t.enchant ~= nil or t.swing ~= nil then
		local slot = ns.WEAPON_INV_SLOT and ns.WEAPON_INV_SLOT[t.enchant or t.swing]
		if slot and GameTooltip.SetInventoryItem then
			shown = pcall(GameTooltip.SetInventoryItem, GameTooltip, "player", slot) and GameTooltip:NumLines() > 0
		end
		if not shown then GameTooltip:SetText(t.name or "Weapon", 1, 1, 1) shown = true end
		GameTooltip:AddLine(t.enchant ~= nil and "Its temporary enchant, read by the addon, in a fight too."
			or "Your next swing, from the game's swing event. The game has a swing timer of its own too, under Edit Mode.", 0.6, 0.8, 1, true)
	end
	if not shown and t.item and GameTooltip.SetItemByID then
		shown = pcall(GameTooltip.SetItemByID, GameTooltip, t.item) and GameTooltip:NumLines() > 0
	end
	if not shown and t.id and GameTooltip.SetSpellByID then
		shown = pcall(GameTooltip.SetSpellByID, GameTooltip, t.id) and GameTooltip:NumLines() > 0
	end
	if not shown then GameTooltip:SetText(t.name or ("Spell " .. tostring(t.id)), 1, 1, 1) end
	-- What the tracker is saying, which is the whole point of hovering one that is missing: the
	-- picture alone does not tell you whether it is the aura or its absence being shown.
	local entry = w.entry
	local cooldown = t.cd or t.item
	local left = entry and entry.expires and entry.expires > 0 and (entry.expires - GetTime()) or nil
	if cooldown then
		if entry and entry.lockout then
			GameTooltip:AddLine((left and left > 0) and ("Locked out, %s left"):format(ns.FormatTime(left)) or "Locked out", 1, 0.4, 0.4)
		elseif entry and entry.held then
			GameTooltip:AddLine("Used; its cooldown starts when the effect ends", 1, 0.7, 0.3)
		elseif entry and entry.secret then
			GameTooltip:AddLine("On cooldown; the game is not saying how long right now", 1, 0.7, 0.3)
		elseif entry and left and left > 0 then
			GameTooltip:AddLine(("On cooldown, %s%s left"):format(entry.stale and "about " or "", ns.FormatTime(left or 0)), 1, 0.7, 0.3)
		elseif entry and not entry.ready then
			GameTooltip:AddLine("On cooldown", 1, 0.7, 0.3)
		elseif entry then
			GameTooltip:AddLine("Ready", 0.4, 1, 0.4)
		else
			GameTooltip:AddLine("This client will not say what its cooldown is", 1, 0.4, 0.4)
		end
	elseif t.enchant ~= nil or t.swing ~= nil then
		if entry and left and left > 0 then
			GameTooltip:AddLine(("%s left"):format(ns.FormatTime(left)), 0.4, 1, 0.4)
		elseif entry then
			GameTooltip:AddLine("On", 0.4, 1, 0.4)
		else
			GameTooltip:AddLine(t.enchant ~= nil and "No temporary enchant" or "No swing under way", 1, 0.4, 0.4)
		end
	elseif entry then
		if left and left > 0 then
			GameTooltip:AddLine(("On you, %s left"):format(ns.FormatTime(left)), 0.4, 1, 0.4)
		else
			GameTooltip:AddLine("On you", 0.4, 1, 0.4)
		end
		if entry.estimated or entry.stale then GameTooltip:AddLine("Carried or guessed: the client hides auras during a fight", 0.7, 0.7, 0.7) end
	elseif w.group and w.group.gameDrawn and not Display:IsUnlocked() then
		GameTooltip:AddLine("Not on you, or the game is not showing it", 1, 0.4, 0.4)
	else
		GameTooltip:AddLine("Not on you", 1, 0.4, 0.4)
	end
	if Display:IsUnlocked() then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Drag: move this tracker", 0.7, 0.7, 0.7)
		GameTooltip:AddLine("Drop it on another group to join it, or in the open for a place of its own", 0.7, 0.7, 0.7)
		if (w.group and w.group.style or "icons") ~= "bars" then
			GameTooltip:AddLine("Hold it against a free side of another icon to hang it there", 0.7, 0.7, 0.7)
		end
		GameTooltip:AddLine("Drag the titled plate behind the group to move the whole group", 0.7, 0.7, 0.7)
		if Display.IsMarked and Display:IsMarked(t) then
			GameTooltip:AddLine("Shift-click: let this one go again. Dragging any marked one moves them all", 0.45, 0.8, 1)
		else
			GameTooltip:AddLine("Shift-click: mark it, to move several together", 0.7, 0.7, 0.7)
		end
		GameTooltip:AddLine("Click: options", 0.7, 0.7, 0.7)
	end
	GameTooltip:Show()
end

-- A frame round a bar, drawn as four thin lines, for a client that hands none over. "w" carries the
-- pool so a bar the addon draws and a bar the game draws each keep their own.
local function PlaceBarFrame(w, ref, height, want)
	local pool = w.barFrame or {}
	w.barFrame = pool
	if not want then
		for _, tex in ipairs(pool) do tex:Hide() tex.alWanted = false end
		return false
	end
	local px = max(1, floor(height / 14 + 0.5))
	for i = 1, 4 do
		local tex = pool[i]
		if not tex then
			tex = (w.over or w):CreateTexture(nil, "OVERLAY", nil, 6)
			pool[i] = tex
		end
		-- A light line, not a dark one: a bar's own plate is black, and a dark frame on it is
		-- nothing at all. Drawn just outside the bar, so it reads against the plate and the world.
		tex:SetColorTexture(0.62, 0.56, 0.44, 0.95)
		tex:ClearAllPoints()
		if i == 1 then
			tex:SetPoint("BOTTOMLEFT", ref, "TOPLEFT", -px, 0)
			tex:SetPoint("BOTTOMRIGHT", ref, "TOPRIGHT", px, 0)
			tex:SetHeight(px)
		elseif i == 2 then
			tex:SetPoint("TOPLEFT", ref, "BOTTOMLEFT", -px, 0)
			tex:SetPoint("TOPRIGHT", ref, "BOTTOMRIGHT", px, 0)
			tex:SetHeight(px)
		elseif i == 3 then
			tex:SetPoint("TOPRIGHT", ref, "TOPLEFT", 0, px)
			tex:SetPoint("BOTTOMRIGHT", ref, "BOTTOMLEFT", 0, -px)
			tex:SetWidth(px)
		else
			tex:SetPoint("TOPLEFT", ref, "TOPRIGHT", 0, px)
			tex:SetPoint("BOTTOMLEFT", ref, "BOTTOMRIGHT", 0, -px)
			tex:SetWidth(px)
		end
		tex:Show()
		tex.alWanted = true
	end
	return true
end

-- The manager's spark, sitting on the leading edge of whatever is drawn as the fill. "edge" is the
-- region whose right-hand side the fill reaches: the addon's own fill texture, or the status bar
-- texture the game fills for a slot.
local function PlaceBarPip(w, edge, height, want)
	local s = skin
	local def = s and s.barPip
	local tex = w.barPip
	if not want or not def or not edge then
		if tex then tex:Hide() end
		return false
	end
	if not tex then
		tex = (w.over or w):CreateTexture(nil, "OVERLAY", nil, 7)
		if def.art.atlas then tex:SetAtlas(def.art.atlas)
		else
			tex:SetTexture(def.art.file)
			if def.art.coords then tex:SetTexCoord(def.art.coords[1], def.art.coords[2], def.art.coords[3], def.art.coords[4]) end
		end
		w.barPip = tex
	end
	tex:SetSize(max(2, (def.w or 0.2) * height), max(2, (def.h or 1.4) * height))
	tex:ClearAllPoints()
	tex:SetPoint("CENTER", edge, "RIGHT", 0, 0)
	tex:Show()
	return true
end

-- Whether the client gave a bar any frame of its own to wear.
local function HaveBarFrame()
	local s = skin
	if not (ns.db and ns.db.barArt == "reckoned") then
		-- Any of it: on this client the one piece is the plate, and that plate is the frame.
		return #((s and s.barShape) or {}) > 0
	end
	for _, dd in ipairs((s and s.decor) or {}) do
		if dd.layer ~= "BACKGROUND" and not tostring(dd.atlas or dd.file or ""):lower():find("pip") then return true end
	end
	return false
end

-- The manager's bar items are hidden until it has something to track, and a hidden bar has nothing
-- to read: a skin taken at login has no bar frame in it. This looks again, now and then, and takes
-- the frame the moment the manager is drawing a bar of its own.
-- The manager's art is read when the skin is first made, and read again now and then while part of
-- it is missing: the bar frame (the manager only draws a bar while it is tracking something), or the
-- icon shape (a reading taken while it had no icons on show has none). A new reading never costs the
-- skin anything it had: the icon part and the bar part are each kept from whichever reading has them.
-- (A reading that came back with less used to replace the skin whole, and every icon made after it
-- lost its shape, its border and its shadow.)
local ICON_PART = { "shape", "shapeFrom", "soloIconDecor", "soloIconCoords", "iconSource" }
local ICON_REPORT = { "icon shape", "icon shape tried", "icon skin" }
local lastSkinTry, skinTries = 0, 0
-- The manager has just been switched on: look at once, rather than at the next try.
function Display.SkinRetryNow()
	lastSkinTry, skinTries = 0, 0
end
function Display:TrySkinAgain(wantBar)
	if ManagerUnsafe() then return false end
	local hadBar, hadShape = HaveBarFrame(), shapeInHand
	if (hadBar or not wantBar) and hadShape then return false end
	local now = GetTime and GetTime() or 0
	-- Every few seconds at first; after a couple of minutes without luck, now and then.
	if now - lastSkinTry < ((skinTries < 24) and 5 or 30) then return false end
	lastSkinTry = now
	skinTries = skinTries + 1
	local had = skin
	local said = {}
	for _, k in ipairs(ICON_REPORT) do said[k] = ns.report[k] end
	said["bar skin"] = ns.report["bar skin"]
	skin = nil
	local ok = pcall(BuildSkin)
	if not ok or not skin or not had then
		if not skin then skin, shapeInHand = had, hadShape end
		return false
	end
	local fresh = skin
	local gotBar = wantBar and HaveBarFrame() and not hadBar
	local gotShape = shapeInHand and not hadShape
	if not gotBar and not gotShape then
		skin, shapeInHand = had, hadShape
		for k, v in pairs(said) do ns.report[k] = v end
		return false
	end
	-- Start from whichever reading has the bar frame, and give it the icon part of whichever has the shape.
	local base = (HaveBarFrame() or not hadBar) and fresh or had
	local icons = gotShape and fresh or had
	if base ~= icons then
		for _, k in ipairs(ICON_PART) do base[k] = icons[k] end
	end
	if icons == had then for _, k in ipairs(ICON_REPORT) do ns.report[k] = said[k] end end
	skin = base
	shapeInHand = (base.shape and #(base.shape.masks or {}) > 0) and true or false
	skinTries = 0
	ns.report["bar skin"] = tostring(skin.source) .. " (read again: the manager had " .. (gotBar and "a bar" or "icons") .. " to show)"
	ns.MASK_EPOCH = (ns.MASK_EPOCH or 0) + 1
	return true
end
-- For the harness: the next try waits its full interval, as it does just after one.
function Display.HoldSkinRetryForTest()
	lastSkinTry = GetTime and GetTime() or 0
end
-- For the harness: a skin that has lost its icon shape, as one read at the wrong moment has.
function Display.ForgetIconShapeForTest()
	if skin then skin.shape = nil end
	shapeInHand = false
end

-- How far the bar is moved from where it would otherwise sit: sideways, and up. Shares of its
-- height, as the margins are.
local function BarOffset(height)
	local ox = tonumber(ns.db and ns.db.barOffsetX) or 0
	local oy = tonumber(ns.db and ns.db.barOffsetY) or 0
	return floor(height * ox + 0.5), floor(height * oy + 0.5)
end

-- The margin between what a bar draws and the frame round it, sideways and up and down, each as a
-- share of the bar's height. They are not the same number: the frame on the manager's plate is
-- thicker at the ends than along the top and bottom. /auraledger barfill sets them.
local function BarInset(height)
	if not HaveBarFrame() then return 0, 0 end
	local fx = tonumber(ns.db and ns.db.fillInsetX) or 0.22
	local fy = tonumber(ns.db and ns.db.fillInsetY) or 0.06
	return max(0, floor(height * fx + 0.5)), max(0, floor(height * fy + 0.5))
end

Display.BarInset = function(h) return BarInset(h) end
Display.BarOffset = function(h) return BarOffset(h) end
Display.HaveBarFrame = function() return HaveBarFrame() end

-- What a bar keeps of the manager's art: its frame, and not its backing, which is sized for the
-- manager's own item and cannot fit a bar with its own icon beside it, nor its pip, which is the
-- mark it slides along a fill the addon draws itself.
local function BarPieceWanted(dd, border)
	local name = tostring(dd.atlas or dd.file or ""):lower()
	if name:find("pip") then return false end
	return border
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
		local on = (not want or want(d)) and true or false
		tex:SetShown(on)
		tex.alWanted = on
	end
	for i = #list + 1, #pool do pool[i]:Hide() pool[i].alWanted = false end
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
	local inner = (w.bar:GetWidth() or 0) - 2 * ((w.fillInset or 0))
	local width = max(0, inner) * frac
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

	-- The ring is laid on this, which is the cell's own square: the picture is pulled in off it, so
	-- what shows round the picture is the ring, in the shape the mask gives it.
	w.ringHolder = w:CreateTexture(nil, "BACKGROUND", nil, -7)
	w.ringHolder:SetAllPoints(w)
	w.ringHolder:SetColorTexture(0, 0, 0, 0)

	w.alBaseLevel = w:GetFrameLevel()

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
		-- Shift-click gathers icons up to be moved together; a plain click puts them all down.
		if IsShiftKeyDown and IsShiftKeyDown() and Display:IsUnlocked() then
			Display:ToggleMark(self.tracker)
			return
		end
		Display:ClearMarks()
		ns.selected = { group = self.group, tracker = self.tracker }
		if ns.UI and ns.UI.ShowSelection then ns.UI:ShowSelection(true) end
	end)
	w:SetScript("OnDragStart", function(self) Display:WidgetDragStart(self) end)
	w:SetScript("OnDragStop", function(self) Display:WidgetDragStop(self) end)
	return w
end

local function ConfigureWidget(w, g)
	local key = tostring(w.underSlot) .. ":" .. g.style .. ":" .. g.size .. ":" .. g.barW .. ":" .. g.barH .. ":" .. tostring(g.barIconScale or 1)
		.. ":" .. tostring(g.border ~= false) .. tostring(g.background ~= false) .. tostring(g.iconFrame ~= false)
		.. ":" .. tostring(ns.MASK_EPOCH)
	local wantBar = function(d) if d.under then return g.background ~= false else return g.border ~= false end end
	local wantIcon = function() return g.iconFrame ~= false end
	if w.configured == key then return end
	w.configured = key
	w.iconPx = nil
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
		local inset = (masked or BorderMode() ~= "cdm") and 0 or IconInset(s, true, IS, g.iconFrame ~= false)
		w.ringPx = (HaveShape() and g.iconFrame ~= false) and max(1, floor(IS / 20 + 0.5)) or 0
		w.cellSize, w.cellBars = IS, true
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
		local ox, oy = BarOffset(H)
		w.bar:SetPoint("LEFT", w, "LEFT", IS + 2 + ox, oy)
		-- Inside the plate's frame: the plate is laid on the bar, so anything drawn to the bar's own
		-- width runs out over the frame the plate draws.
		local inx, iny = BarInset(H)
		w.fillInset, w.fillInsetY = inx, iny
		w.fill:ClearAllPoints()
		w.fill:SetPoint("TOPLEFT", w.bar, "TOPLEFT", inx, -iny)
		w.fill:SetPoint("BOTTOMLEFT", w.bar, "BOTTOMLEFT", inx, iny)
		if w.bar.bg then
			w.bar.bg:ClearAllPoints()
			w.bar.bg:SetPoint("TOPLEFT", w.bar, "TOPLEFT", inx, -iny)
			w.bar.bg:SetPoint("BOTTOMRIGHT", w.bar, "BOTTOMRIGHT", -inx, iny)
		end
		w.bar:Show()
		if PlaceBarShape(w, w.bar, max(8, g.barW - IS - 2), H, g.border ~= false or (not w.underSlot and g.background ~= false)) then
			PlaceDecor(w, {}, "decor", w.bar, H, wantBar)
		else
			PlaceDecor(w, s.decor, "decor", w.bar, H, function(dd) return BarPieceWanted(dd, g.border ~= false) end)
		end
		PlaceBarFrame(w, w.bar, H, g.border ~= false and not HaveBarFrame())
		PlaceBarPip(w, w.fill, H, g.border ~= false)
		-- Both are asked every time: the one that is not wanted takes itself off screen.
		-- Round the icon: the cell's own square here is the icon and the bar together, and a ring
		-- laid on that is a plate behind the whole row.
		w.ringRef = nil
		ShapeMask(w, w.icon, IS, g.iconFrame ~= false)
		ShapeArt(w, w.icon, IS, g.iconFrame ~= false, w.underSlot and 1 or 0)
		ShapeShadow(w, w.icon, IS, g.iconFrame ~= false and ShadowLayers(w.underSlot and 1 or 0) > 0)
		ShapeCooldown(w, w.cd, IS, g.iconFrame ~= false)
		local shaped = ShapeBorder(w, w.icon, IS, g.iconFrame ~= false) or (HaveShape() and g.iconFrame ~= false)
		local edged = PlaceCleanEdge(w, w.icon, IS, g.iconFrame ~= false)
		local framed = PlaceClientFrame(w, w.icon, IS, g.iconFrame ~= false)
		edged = edged or shaped
		if edged or framed then
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
		local inset = (masked or BorderMode() ~= "cdm") and 0 or IconInset(s, false, S, g.iconFrame ~= false)
		-- Room for the ring, kept until there is a ring to show: see SizeIconForRing.
		w.ringPx = (HaveShape() and g.iconFrame ~= false) and max(1, floor(S / 20 + 0.5)) or 0
		w.cellSize, w.cellBars = S, false
		w:SetSize(S, S)
		w.icon:SetSize(S - inset * 2, S - inset * 2)
		w.icon:SetPoint("CENTER")
		local c = IconCrop(s.soloIconCoords or s.iconCoords)
		w.icon:SetTexCoord(c[1], c[2], c[3], c[4])
		-- Everything a bar draws goes off with it: its art, whichever frame it wore, and the spark.
		w.bar:Hide()
		PlaceBarShape(w, w.bar, S, S, false)
		PlaceBarFrame(w, w.bar, S, false)
		PlaceBarPip(w, nil, S, false)
		PlaceDecor(w, {}, "decor", w.bar, S)
		w.ringRef = w.ringHolder
		ShapeMask(w, w.icon, S, g.iconFrame ~= false)
		-- Under a slot the game draws one layer of its own, which counts towards the depth.
		ShapeArt(w, w.icon, S, g.iconFrame ~= false, w.underSlot and 1 or 0)
		-- Under a slot the game's own overlay counts as one layer of the shadow's depth.
		ShapeShadow(w, w.icon, S, g.iconFrame ~= false and ShadowLayers(w.underSlot and 1 or 0) > 0)
		ShapeCooldown(w, w.cd, S, g.iconFrame ~= false)
		local shaped = ShapeBorder(w, w.icon, S, g.iconFrame ~= false) or (HaveShape() and g.iconFrame ~= false)
		local edged = PlaceCleanEdge(w, w.icon, S, g.iconFrame ~= false, w.underSlot)
		local framed = PlaceClientFrame(w, w.icon, S, g.iconFrame ~= false)
		edged = edged or shaped
		if edged or framed then
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

-- The edge round an icon says what the old debuff border used to: red while an aura is missing or
-- nearly gone, the dispel color on a debuff, and a plain dark line otherwise. A thicker line is
-- drawn for the colored states so they read at a glance.
local function TintEdge(w, r, g, b, strong)
	local tex = w.cleanEdge
	if not tex or tex:IsShown() == false then return false end
	return LayEdge(w, r, g, b, strong and 1 or 0.9, strong)
end

local function TintFill(w, kind, missing)
	if missing then
		w.fill:SetVertexColor(0.55, 0.2, 0.2)
	elseif skin.tint then
		if kind == "debuff" then w.fill:SetVertexColor(0.85, 0.22, 0.2) else w.fill:SetVertexColor(0.25, 0.6, 1) end
	elseif kind == "debuff" then
		w.fill:SetVertexColor(1, 0.45, 0.45)
	elseif skin.fillColor then
		w.fill:SetVertexColor(skin.fillColor[1], skin.fillColor[2], skin.fillColor[3])
	else
		w.fill:SetVertexColor(1, 1, 1)
	end
end

-- The picture fills its cell, and gives up the ring's width all round only while a ring is shown.
local function SizeIconForRing(w, ringOn)
	local cell = w.cellSize
	if not cell or not w.ringPx then return end
	local px = ringOn and w.ringPx or 0
	if w.iconPx == px then return end
	w.iconPx = px
	w.icon:SetSize(max(1, cell - px * 2), max(1, cell - px * 2))
	w.icon:ClearAllPoints()
	if w.cellBars then w.icon:SetPoint("LEFT", w, "LEFT", px, 0) else w.icon:SetPoint("CENTER") end
end

-- A cell under a slot wears the frame only while the game is not drawing one, or the two sit on top
-- of each other and read as one heavy frame. The addon cannot see the game's slot, but it knows
-- whether it believes the aura is there, which is the same answer everywhere it matters.
local function BarArtShown(w, on)
	for _, pool in ipairs({ w.barShape, w.decor, w.barFrame }) do
		for _, tex in ipairs(pool or {}) do
			if on then
				if tex.alWanted ~= false then tex:Show() end
			else
				tex:Hide()
			end
		end
	end
end

-- The action bar's proc glow on a tracker the addon draws: Blizzard's own loop, a clear texture lit
-- by a one-frame step and then the flipbook, played while the tracker says it is up. It sits between
-- the art and the text, so the time and the stack count stay on top.
local function WidgetGlow(w, g, want)
	if not want then
		if w.glowOn then
			w.glowOn = false
			if w.glowAnim then pcall(w.glowAnim.Stop, w.glowAnim) end
			if w.glowHolder then w.glowHolder:Hide() end
		end
		return
	end
	if not w.glowHolder then
		local ok, holder, tex, ag = pcall(function()
			local hf = CreateFrame("Frame", nil, w)
			hf:SetAllPoints(w)
			hf:EnableMouse(false)
			local tx = hf:CreateTexture(nil, "OVERLAY")
			tx:SetAtlas("UI-HUD-ActionBar-Proc-Loop-Flipbook")
			tx:SetAlpha(0)
			local group = tx:CreateAnimationGroup()
			group:SetLooping("REPEAT")
			local lit = group:CreateAnimation("Alpha")
			lit:SetFromAlpha(1) lit:SetToAlpha(1) lit:SetDuration(0.001) lit:SetOrder(1)
			local flip = group:CreateAnimation("FlipBook")
			flip:SetDuration(1) flip:SetOrder(2)
			flip:SetFlipBookRows(6) flip:SetFlipBookColumns(5) flip:SetFlipBookFrames(30)
			flip:SetFlipBookFrameWidth(0) flip:SetFlipBookFrameHeight(0)
			return hf, tx, group
		end)
		if not ok then
			ns.report["tracker glow"] = "could not be made: " .. tostring(holder)
			return
		end
		w.glowHolder, w.glowTex, w.glowAnim = holder, tex, ag
		holder:SetScript("OnShow", function() if w.glowOn then pcall(ag.Play, ag) end end)
		holder:SetScript("OnHide", function() pcall(ag.Stop, ag) end)
	end
	local size = (g.style == "bars") and ns.BarIconSize(g) or (w.cellSize or g.size or 40)
	w.glowHolder:SetFrameLevel((w.alLevel or w.alBaseLevel or 1) + 4)
	w.glowTex:ClearAllPoints()
	w.glowTex:SetPoint("CENTER", w.icon, "CENTER", 0, 0)
	w.glowTex:SetSize(size * 1.4, size * 1.4)
	w.glowHolder:Show()
	local okP, playing = pcall(w.glowAnim.IsPlaying, w.glowAnim)
	if not w.glowOn or not (okP and playing) then
		w.glowOn = true
		pcall(w.glowAnim.Play, w.glowAnim)
	end
end

local function PaintWidget(w, g, t, entry, preview, expiring)
	w.tracker, w.group, w.entry, w.expiring = t, g, entry, expiring
	ConfigureWidget(w, g)
	w.icon:SetTexture((entry and entry.icon) or t.icon or QUESTION)
	local isActive = entry ~= nil
	-- A spell on cooldown is there but not ready, which is what the drained look says.
	local onCooldown = entry ~= nil and entry.kind == "cooldown" and not entry.ready
	local flagMissing = (not isActive) and (t.show ~= "active")
	if w.icon.SetDesaturated then w.icon:SetDesaturated(not isActive or onCooldown) end
	local redMissing = ns.db and ns.db.missingStyle == "red"
	if onCooldown and entry.lockout then
		-- Locked out: drained and reddened, as the spell cannot be cast whatever its cooldown says.
		w.icon:SetVertexColor(1, 0.45, 0.45)
		w.icon:SetAlpha(1)
	elseif onCooldown then
		w.icon:SetVertexColor(0.85, 0.85, 0.85)
		w.icon:SetAlpha(1)
	elseif isActive then
		w.icon:SetVertexColor(1, 1, 1)
		w.icon:SetAlpha(1)
	elseif flagMissing then
		-- Drained of color and dimmed a little: an aura you have not got, said quietly.
		if redMissing then w.icon:SetVertexColor(1, 0.35, 0.35) else w.icon:SetVertexColor(0.75, 0.75, 0.75) end
		w.icon:SetAlpha(1)
	else
		w.icon:SetVertexColor(0.7, 0.7, 0.7)
		w.icon:SetAlpha(preview and 0.75 or 1)
	end

	local br, bg, bb, strong
	if expiring then
		br, bg, bb, strong = 1, 0.1, 0.1, true
	elseif isActive and entry.kind == "debuff" then
		local c = DISPEL_COLORS[entry.dispel or "none"] or DISPEL_COLORS.none
		br, bg, bb, strong = c[1], c[2], c[3], true
	elseif isActive and g.dispelColors and entry.dispel and DISPEL_COLORS[entry.dispel] then
		local c = DISPEL_COLORS[entry.dispel]
		br, bg, bb, strong = c[1], c[2], c[3], true
	elseif flagMissing and redMissing then
		br, bg, bb, strong = 1, 0.1, 0.1, true
	elseif flagMissing then
		-- A dark ring, so the tracker still has an outline without shouting.
		br, bg, bb, strong = 0.1, 0.1, 0.1, false
	end
	if HaveShape() and not w.shapeBorder then
		local ringOn = br ~= nil and (w.group == nil or w.group.iconFrame ~= false)
		SizeIconForRing(w, ringOn)
		ShapeRing(w, w.ringRef or w.icon, w.cellSize or 40, ringOn, br, bg, bb)
		w.border:Hide()
	elseif ShapeBorderColor(w, br or 1, bg or 1, bb or 1) then
		w.border:Hide()
	elseif TintEdge(w, br or 0, bg or 0, bb or 0, strong) then
		-- The edge said it; the old debuff sheet is not wanted on top of it.
		w.border:Hide()
	elseif br then
		w.border:SetVertexColor(br, bg, bb)
		w.border:Show()
	else
		w.border:Hide()
	end

	local timed = isActive and entry.duration > 0 and entry.expires > 0
	if w.cd then
		if timed and g.style ~= "bars" then
			w.cd:SetCooldown(entry.expires - entry.duration, entry.duration)
			ShapeCooldown(w, w.cd, w.cellSize or g.size or 40, g.iconFrame ~= false)
			w.cd:Show()
		else
			if w.cd.Clear then w.cd:Clear() end
			w.cd:Hide()
		end
	end
	w.count:SetText((isActive and entry.count and entry.count > 1) and entry.count or "")

	if g.style == "bars" then
		if w.edge then
			if flagMissing and redMissing then w.edge:SetBackdropBorderColor(1, 0.25, 0.25)
			elseif flagMissing then w.edge:SetBackdropBorderColor(0.5, 0.5, 0.5)
			else w.edge:SetBackdropBorderColor(0.9, 0.8, 0.5) end
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
			if w.underSlot then BarArtShown(w, not w.auraKnown) end
			if w.barPip then w.barPip:Hide() end
			w.duration:SetText(flagMissing and "Missing" or "")
			w.bar.spark:Hide()
		end
	elseif not timed then
		w.time:SetText("")
	end
	w.timed = timed
	-- Up: the aura (or enchant, or swing) is there; for a cooldown, the spell or item is ready. A cell
	-- under a game slot is painted as missing and leaves the glow to the game.
	local up = false
	if t.glow and not w.underSlot and entry ~= nil then
		if t.cd then up = entry.ready == true else up = true end
	end
	WidgetGlow(w, g, up)
end

local function TickWidget(w, g, now)
	if not w.timed or not w.entry then return end
	local e = w.entry
	local rem = max(0, e.expires - now)
	-- The ~ is the one mark for a time the addon is carrying rather than reading: either it was
	-- guessed, or it is the last clean read counting on.
	local text = g.timers ~= false and (((e.estimated or e.stale) and "~" or "") .. ns.FormatTime(rem)) or ""
	local sameText = (w.shownText == text)
	w.shownText = text
	if g.style == "bars" then
		if w.underSlot then BarArtShown(w, not w.auraKnown) end
		local frac = e.duration > 0 and min(1, rem / e.duration) or 1
		SetFill(w, frac)
		-- The manager's spark marks where a draining bar has got to. A full bar has nowhere to put
		-- it, and a missing tracker draws a full bar, which is what put one at the end.
		if w.barPip then w.barPip:SetShown(frac > 0 and frac < 1) end
		if not sameText then w.duration:SetText(text) end
		local width = w.bar:GetWidth() or 0
		if frac > 0 and frac < 1 and width > 0 and #skin.decor == 0 then
			w.bar.spark:ClearAllPoints()
			w.bar.spark:SetPoint("CENTER", w.bar, "LEFT", width * frac, 0)
			w.bar.spark:Show()
		else
			w.bar.spark:Hide()
		end
	else
		if not sameText then w.time:SetText(text) end
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
-- Every id known for a spell by name: the ledger's, the bundled ranks and your own spellbook's.
local function KnownIds(name, map)
	local any = false
	for _, kind in ipairs({ "buff", "debuff" }) do
		local h = ns.db.history[kind .. ":" .. string.lower(name)]
		if h and h.ids then for id in pairs(h.ids) do map[id] = true any = true end end
	end
	local ranks = ns.RankIds and ns.RankIds(name)
	if ranks then for id in pairs(ranks) do map[id] = true any = true end end
	-- Nothing else knows it: the game's own spell list, every id of that name.
	if not any and ns.SpellDB and ns.SpellDB.Ids then
		local listed = ns.SpellDB.Ids(name)
		if listed then for id in pairs(listed) do map[id] = true any = true end end
	end
	return any
end

-- The ids a tracker's slot follows. With family, a buff's group version counts too (Prayer of
-- Fortitude for Power Word: Fortitude): asked for by groups that watch your party. Nil when there
-- are none, so no slot is ever given an empty map, which the game would read as "match nothing".
local function TrackerIds(t, family)
	local map, any = {}, false
	if t.id then map[t.id] = true any = true end
	if t.name and not t.matchId then
		local names = family and ns.FamilyOf and ns.FamilyOf(t.name) or { t.name }
		for _, n in ipairs(names) do
			if KnownIds(n, map) then any = true end
		end
	end
	return any and map or nil
end
Display.TrackerIds = TrackerIds

local function IdsKey(map)
	local l = {}
	for id in pairs(map) do l[#l + 1] = id end
	table.sort(l)
	return table.concat(l, ",")
end

-- A debuff can be handed to the game only when every id the tracker follows is one the game never
-- hides: for anything else the game refuses to filter a debuff by spell, and the slot would show
-- nothing. Asked out of combat, when slots are made.
local function AllNeverSecret(ids)
	local S = C_Secrets
	if not (S and S.GetSpellAuraSecrecy) then return false end
	local never = Enum and Enum.SecrecyLevel and Enum.SecrecyLevel.NeverSecret or 0
	local any = false
	for id in pairs(ids or {}) do
		local ok, level = pcall(S.GetSpellAuraSecrecy, id)
		level = ok and ns.Clean(level) or nil
		if level ~= never then return false end
		any = true
	end
	return any
end
Display.AllNeverSecret = AllNeverSecret

-- What a tracker's slot is: the game's filter, the candidate filters, and a key that changes when
-- they do. Nil for anything the game cannot follow (a cooldown, an item, a weapon, a debuff it
-- hides, a spell with no id known). A dispel tracker never carries a spell map: on a unit the game
-- will not filter by spell, a map (even an empty one) matches nothing.
local function SlotSpec(t, g)
	if not t or t.cd or t.item or t.enchant ~= nil or t.swing ~= nil then return nil end
	-- The game can only show an aura that is there. A tracker for when it is not is the addon's to
	-- draw, except on your party's rows, which have their own way with Missing.
	-- (On your target the addon cannot read anything in a fight, so there the game keeps the slot
	-- over a cell painted as missing.)
	if t.show == "missing" and not t.dispel and t.unit ~= "target" and not (g and ns.GroupUnits(g)) then return nil end
	-- Nor what a slot cannot do: an aura whose landing is not known (a slot has one filter, buffs or
	-- debuffs), a warn time with no countdown to turn red, or an In combat condition of its own (a
	-- slot cannot be switched in a fight). The addon draws those.
	if not t.dispel and t.unit ~= "target" and not (g and ns.GroupUnits(g)) then
		if t.kind == "any" then return nil end
		if (t.warn or 0) > 0 and g and g.timers == false then return nil end
		if type(t.cond) == "table" and t.cond.combat then return nil end
	end
	if t.dispel == "any" then
		-- RAID on harmful auras is the game's own "a debuff you can remove".
		return { filter = "HARMFUL|RAID", key = "dispel:any" }
	elseif t.dispel then
		if not (ns.DISPEL_TYPES and ns.DISPEL_TYPES[t.dispel]) then return nil end
		return { filter = "HARMFUL", filters = { includeDispelTypes = { [t.dispel] = true } }, key = "dispel:" .. t.dispel }
	end
	-- A debuff on your target: on a unit you can attack the game takes a spell filter on harmful
	-- auras (only on one you can help does it refuse), so it follows the debuff there in a fight too.
	-- Yours alone is the game's PLAYER filter: cast by you or your pet. (isFromPlayerOrPlayerPet is
	-- true for any player's aura, so another warlock's Corruption would pass it.)
	if t.unit == "target" then
		local tids = TrackerIds(t, false)
		if not tids then return nil end
		return { filter = t.mine and "HARMFUL|PLAYER" or "HARMFUL", filters = { includeSpellIDs = tids },
			key = "target:" .. IdsKey(tids) .. ":" .. tostring(t.mine and true or false) }
	end
	local ids = TrackerIds(t, ns.GroupUnits(g) ~= nil)
	if not ids then return nil end
	local filters = { includeSpellIDs = ids, isFromPlayerOrPlayerPet = t.mine and true or nil }
	local key = IdsKey(ids) .. ":" .. tostring(t.mine and true or false)
	if t.kind == "debuff" then
		if not AllNeverSecret(ids) then return nil end
		return { filter = "HARMFUL", filters = filters, key = key }
	end
	return { filter = "HELPFUL", filters = filters, key = key }
end
Display.SlotSpec = SlotSpec

-- Whether a tracker can go in a group that watches your party: an aura the game follows. A cooldown,
-- an item or a weapon is yours alone, and so is a debuff the game hides.
function Display.MemberCanHold(t)
	if not t or t.cd or t.item or t.enchant ~= nil or t.swing ~= nil then return false end
	if t.unit == "target" then return false end
	if t.dispel then return true end
	if t.kind == "debuff" then
		local ids = TrackerIds(t, true)
		return ids ~= nil and AllNeverSecret(ids)
	end
	return true
end

-- What a slot is built from. A container whose key has changed is thrown away and made again, which
-- is the only way the game allows a slot's insides to change: the frames themselves are its own, and
-- the addon is refused if it so much as resizes one.
local function SlotKey(g)
	return g.style .. ":" .. g.size .. ":" .. g.barW .. ":" .. g.barH .. ":" .. tostring(g.barIconScale or 1)
		.. ":" .. tostring(g.iconFrame ~= false) .. tostring(g.border ~= false)
		.. tostring(g.background ~= false) .. tostring(g.timers ~= false) .. tostring(g.names ~= false) .. tostring(g.dispelColors == true)
		-- and the look itself: the art read off the client, the plate's reach, the fill's margins.
		.. ":" .. tostring(ns.MASK_EPOCH or 0) .. ":" .. tostring(ns.db and ns.db.plateTop) .. "," .. tostring(ns.db and ns.db.plateBottom)
		.. "," .. tostring(ns.db and ns.db.plateEven)
		.. ":" .. tostring(ns.db and ns.db.fillInsetX) .. "," .. tostring(ns.db and ns.db.fillInsetY)
		.. ":" .. tostring(ns.db and ns.db.barOffsetX) .. "," .. tostring(ns.db and ns.db.barOffsetY)
		.. ":" .. tostring(ns.db and ns.db.plateLeft) .. "," .. tostring(ns.db and ns.db.plateRight)
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
local function InitSlotFrame(g, mode, filter, store, opts)
	opts = opts or {}
	return function(button)
		if not button then return end
		local ok, err = pcall(function()
		local s = BuildSkin()
		local w = { under = button, over = button, decor = {}, iconArt = {} }
		local bars = g.style == "bars"
		local W, H = bars and g.barW or g.size, bars and g.barH or g.size
		pcall(button.SetSize, button, W, H)
		local IS = bars and ns.BarIconSize(g) or H
		local icon = button:CreateTexture(nil, "ARTWORK")
		local c = IconCrop((bars and s.iconCoords) or s.soloIconCoords or s.iconCoords)
		icon:SetTexCoord(c[1], c[2], c[3], c[4])
		local masked = g.iconFrame ~= false and ns.SetIconMask(button, icon, true, IS)
		local inset = (masked or BorderMode() ~= "cdm") and 0 or IconInset(s, bars, IS, g.iconFrame ~= false)
		-- The same mask as the cell underneath, but the cell's full size: the ring that carries the
		-- missing color is a band round the outside of a cell, and an icon pulled in off that band
		-- leaves it on show while the game is drawing the aura.
		local IW = IS - inset * 2
		-- The container takes the icon and anchors it to the button, which is not always square, so
		-- the picture is put back on its own square afterwards.
		local function SquareUp()
			icon:ClearAllPoints()
			icon:SetSize(IW, IW)
			if bars then icon:SetPoint("LEFT", button, "LEFT", inset, 0) else icon:SetPoint("CENTER", button, "CENTER", 0, 0) end
		end
		SquareUp()
		ShapeMask(w, icon, IW, g.iconFrame ~= false)
		-- The cell underneath draws the shadow for this tracker; a second set here would sit exactly
		-- on top of it and come out twice as deep.
		ShapeArt(w, icon, IW, false)
		-- Nor its own stand-in shadow: the game draws its overlay on its slots itself.
		ShapeShadow(w, icon, IW, false)
		button.alIcon = icon
		pcall(button.SetIcon, button, icon)
		SquareUp()
		if button.HookScript then pcall(button.HookScript, button, "OnShow", function() pcall(SquareUp) end) end
		-- The action bar's proc glow, played by the game for as long as the aura is up, in combat too.
		-- It is Blizzard's own loop: a texture left clear, lit by a one-frame step, then the flipbook.
		-- It lives inside the slot, as the game requires, and nothing about it is read back.
		if opts.glow then
			local okG, why = pcall(function()
				local holder = CreateFrame("Frame", nil, button)
				holder:SetAllPoints(icon)
				holder:SetFrameLevel(button:GetFrameLevel() + 8)
				local glow = holder:CreateTexture(nil, "OVERLAY")
				glow:SetAtlas("UI-HUD-ActionBar-Proc-Loop-Flipbook")
				glow:SetPoint("CENTER", icon, "CENTER", 0, 0)
				glow:SetSize(IW * 1.4, IW * 1.4)
				glow:SetAlpha(0)
				local ag = glow:CreateAnimationGroup()
				ag:SetLooping("REPEAT")
				local lit = ag:CreateAnimation("Alpha")
				lit:SetFromAlpha(1) lit:SetToAlpha(1) lit:SetDuration(0.001) lit:SetOrder(1)
				local flip = ag:CreateAnimation("FlipBook")
				flip:SetDuration(1) flip:SetOrder(2)
				flip:SetFlipBookRows(6) flip:SetFlipBookColumns(5) flip:SetFlipBookFrames(30)
				flip:SetFlipBookFrameWidth(0) flip:SetFlipBookFrameHeight(0)
				button:AddAuraShownAnimation(ag)
			end)
			ns.report["slot glow"] = okG and "played by the game" or ("refused: " .. tostring(why))
		end
		local count = button:CreateFontString(nil, "OVERLAY")
		count:SetFont(FONT, max(7, floor(IS * (bars and 0.45 or 0.3))), "OUTLINE")
		count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)
		pcall(button.SetApplicationCount, button, count)
		-- The border by dispel type, when the group asks for it, and always on a dispel tracker. The
		-- game hides it on buffs unless told to show it there, which the old border never was, so it
		-- never showed. The game draws its own border in the type's colour and nothing about it is
		-- read back.
		if g.dispelColors or opts.dispelRing then
			local okB, why = pcall(function()
				local ring = button:CreateTexture(nil, "OVERLAY", nil, 7)
				ring:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
				ring:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
				local styles = Enum and Enum.CustomAuraButtonDispelTypeTextureStyle
				button:AddDispelTypeTexture(ring, { showWhenHelpful = g.dispelColors and true or false, showWhenHarmful = true,
					style = styles and styles.Border or nil })
			end)
			ns.report["slot dispel border"] = okB and "drawn by the game" or ("refused: " .. tostring(why))
		end
		if bars then
			local bar = CreateFrame("StatusBar", nil, button)
			-- The group's own bar height, held in the middle of the cell: a cell is as tall as the
			-- taller of the bar and the icon, and stretching to it makes this bar the odd one out.
			local inx, iny = BarInset(H)
			-- The frame goes round the bar's outer size; the status bar sits inside it, because the
			-- fill here is the status bar itself rather than a texture within it.
			local outer = CreateFrame("Frame", nil, button)
			outer:SetSize(max(8, W - IS - 2), H)
			outer:EnableMouse(false)
			button.alOuter = outer
			bar:SetSize(max(8, W - IS - 2 - inx * 2), max(4, H - iny * 2))
			local ox, oy = BarOffset(H)
			outer:SetPoint("LEFT", button, "LEFT", IS + 2 + ox, oy)
			bar:SetPoint("LEFT", button, "LEFT", IS + 2 + inx + ox, oy)
			button.alBar = bar
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
			-- As the addon tints its own: art copied from the client keeps the color it came with,
			-- and only a stand-in fill is tinted, or the two look nothing like each other.
			if s.tint then
				if filter:find("HARMFUL", 1, true) then bar:SetStatusBarColor(0.85, 0.22, 0.2) else bar:SetStatusBarColor(0.25, 0.6, 1) end
			elseif s.fillColor then
				bar:SetStatusBarColor(s.fillColor[1], s.fillColor[2], s.fillColor[3])
			else
				bar:SetStatusBarColor(1, 1, 1)
			end
			local bg = bar:CreateTexture(nil, "BACKGROUND", nil, -8)
			bg:SetAllPoints(bar)
			-- Opaque: the cell under this slot is painted as missing, text and all, and a translucent
			-- backing lets "Missing" read through the name and the time the game is drawing.
			bg:SetColorTexture(0, 0, 0, 1)
			local dir = DrainDirection()
			if not pcall(button.SetDurationBar, button, bar, dir ~= nil and { direction = dir } or nil) then pcall(button.SetDurationBar, button, bar) end
			-- The art belongs with the bar: anything behind goes on the bar itself, above the cover
			-- that hides the cell, and anything in front on a frame above the fill.
			local artHolder = CreateFrame("Frame", nil, button)
			artHolder:SetAllPoints(bar)
			artHolder:SetFrameLevel(bar:GetFrameLevel() + 3)
			artHolder:EnableMouse(false)
			local barW = { under = bar, over = artHolder, decor = {}, iconArt = {} }
			button.alBarArt = barW
			-- This slot wears the frame while the game is drawing the aura. The cell underneath wears
			-- one too, for when it is not, and gives it up while the aura is there: see BarArtShown.
			-- A member's cell cannot know when the aura is there, so it keeps its frame, and the slot
			-- over it goes without.
			if not opts.noFrame then
				if not PlaceBarShape(barW, outer, max(8, W - IS - 2), H, g.border ~= false) then
					PlaceDecor(barW, s.decor, "decor", outer, H, function(dd) return BarPieceWanted(dd, g.border ~= false) end)
				end
				PlaceBarFrame(barW, outer, H, g.border ~= false and not HaveBarFrame())
			end
			PlaceBarPip(barW, bar:GetStatusBarTexture(), H, g.border ~= false)
			if g.iconFrame ~= false then
				local e1 = PlaceCleanEdge(w, icon, IS, true)
				local e2 = PlaceClientFrame(w, icon, IS, true)
				if not e1 and not e2 then PlaceDecor(w, IconArt(s, true), "iconArt", icon, IS, nil, true) end
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
			if g.timers ~= false then
				local col = s.durFont and s.durFont.color
				BindSlotTime(button, dur, opts.warn, col and col[1] or 1, col and col[2] or 1, col and col[3] or 1)
			end
			local name = textHolder:CreateFontString(nil, "OVERLAY")
			ApplyFont(name, s.nameFont, H, px)
			name:SetPoint("LEFT", bar, "LEFT", 4, 0)
			name:SetWidth(max(10, W - IS - 2 - 8 - 44))
			name:SetJustifyH("LEFT")
			name:SetWordWrap(false)
			if g.names ~= false then
				if opts.label then name:SetText(opts.label) else pcall(button.SetSpellName, button, name) end
			end
		else
			local time = button:CreateFontString(nil, "OVERLAY")
			time:SetFont(FONT, max(8, floor(H * 0.4)), "OUTLINE")
			time:SetPoint("CENTER", icon, "CENTER", 0, 0)
			if g.timers ~= false then BindSlotTime(button, time, opts.warn, 1, 1, 1) end
			local okC, cd = pcall(CreateFrame, "Cooldown", nil, button, "CooldownFrameTemplate")
			if okC and cd then
				cd:SetAllPoints(icon)
				if cd.SetReverse then cd:SetReverse(true) end
				if cd.SetDrawEdge then cd:SetDrawEdge(false) end
				if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
				cd.noCooldownCount = true
				pcall(button.SetDurationCooldown, button, cd)
				button.alCd, button.alW, button.alCdSize = cd, w, IW
				ShapeCooldown(w, cd, IW, g.iconFrame ~= false)
				if cd.HookScript then pcall(cd.HookScript, cd, "OnShow", function() pcall(ShapeCooldown, w, cd, IW, g.iconFrame ~= false) end) end
			end
			if g.iconFrame ~= false then
				local e1 = PlaceCleanEdge(w, icon, H, true)
				local e2 = PlaceClientFrame(w, icon, H, true)
				if not e1 and not e2 then PlaceDecor(w, IconArt(s, false), "iconArt", icon, H, nil, true) end
			end
		end
		pcall(button.SetMouseMotionEnabled, button, true)
		pcall(button.SetTooltipAnchorPoint, button, "ANCHOR_RIGHT")
		pcall(button.SetHideTooltipInCombat, button, false)
		-- Opaque backing, created last so a failed setup never leaves a bare black box. It sits
		-- behind the icon and takes the icon's shape, or it is the square that shows round it.
		local back = button:CreateTexture(nil, "BACKGROUND", nil, -8)
		back:SetAllPoints(icon)
		back:SetColorTexture(0, 0, 0, 1)
		ShapeMask(w, back, IW, g.iconFrame ~= false, "backMasks")
		button.alBack = back
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
	-- Talents do not change in a fight, so these are settled when the macro is built, out of one.
	if ns.TalentConditionFails(cond) then return nil end
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
	if f.gate.alMacro ~= macro and not ManagerUnsafe() then
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
	if ManagerUnsafe() then return end
	if UnregisterAttributeDriver and f.gate.alMacro then pcall(UnregisterAttributeDriver, f.gate, "state-visibility") end
	f.gate.alMacro = nil
	f.gate:Hide()
	f.gate.alDropped = true
end

-- A container's own driver, taken off. c.alMacro is the driver it has: "" for none (shown by the
-- addon), "parked" for one put away.
local function DriverOff(c)
	if UnregisterAttributeDriver and c.alMacro and c.alMacro ~= "" and c.alMacro ~= "parked" then
		pcall(UnregisterAttributeDriver, c, "state-visibility")
	end
end

-- The container for one unit of a group. A group that watches only you rebuilds it when the look
-- changes; one that watches members keeps it and puts the look in its slots instead, so a new look
-- does not throw away a container per member. A driver, when given, is the game's to run: it shows
-- and hides the container as the unit comes and goes, which is also what makes it read the unit
-- afresh. Nothing is made or changed in a fight or while auras are hidden; the one there is returned.
local function SlotContainer(f, g, unit, driver, member)
	f.slotC = f.slotC or {}
	local key = member and "member" or SlotKey(g)
	local slot = member and ("m:" .. unit) or unit
	local c = f.slotC[slot]
	if ManagerUnsafe() then return c end
	if c and c.alKey == key then
		local want = driver or ""
		if c.alMacro ~= want then
			DriverOff(c)
			if driver and RegisterAttributeDriver and pcall(RegisterAttributeDriver, c, "state-visibility", driver) then
				c.alMacro = driver
			else
				c:Show()
				c.alMacro = ""
			end
		end
		return c
	end
	if c then
		DriverOff(c)
		c:Hide() c:ClearAllPoints() f.slotC[slot] = nil
	end
	local gate = EnsureGate(f, g)
	if gate.alDropped then gate:Show() gate.alDropped = nil end
	local ok, nc = pcall(CreateFrame, "AuraContainer", nil, gate, "CustomAuraContainerTemplate")
	if not (ok and nc) then
		ns.report["game-drawn trackers"] = "AuraContainer not available: " .. tostring(nc)
		AdviseGameDrawn("game-drawn trackers", "the game's aura display could not be created")
		return nil
	end
	-- While the game's Edit Mode is open it would fill this with placeholder auras, which match none
	-- of our spells, so every tracker would read as missing until it closed.
	if nc.SetEditModePreviewEnabled then
		local okE = pcall(nc.SetEditModePreviewEnabled, nc, false)
		-- Read back: a call that went through is not the same as the game having honoured it.
		local okR, on = pcall(function() return nc:IsEditModePreviewEnabled() end)
		on = okR and ns.Clean(on)
		if not okE then ns.report["edit mode preview"] = "the game refused to turn it off"
		elseif on == false then ns.report["edit mode preview"] = "off"
		elseif on == true then ns.report["edit mode preview"] = "asked off, but the game kept it on"
		else ns.report["edit mode preview"] = "asked off, not confirmed" end
	end
	nc:SetAllPoints(f)
	nc:SetFrameLevel(gate:GetFrameLevel() + 3)
	if nc.SetUnit then pcall(nc.SetUnit, nc, unit) end
	nc.alKey, nc.alSlots, nc.alSpec, nc.alStore, nc.alMacro, nc.alUnit = key, {}, {}, {}, "", unit
	if driver and RegisterAttributeDriver and pcall(RegisterAttributeDriver, nc, "state-visibility", driver) then nc.alMacro = driver end
	if nc.alMacro == "" then nc:Show() end
	f.slotC[slot] = nc
	Display.containersMade = (Display.containersMade or 0) + 1
	ns.report["game-drawn trackers"] = "AuraContainer ok"
	return nc
end

-- Containers a group no longer wants are put away rather than thrown away (the game has no way to
-- free one), and taken out again if wanted back. Out of combat and while auras can be read only.
local function ParkContainers(f, keep)
	if not f.slotC or ManagerUnsafe() then return end
	for unit, c in pairs(f.slotC) do
		if not keep[unit] and c.alMacro ~= "parked" then
			DriverOff(c)
			pcall(c.Hide, c)
			c.alMacro = "parked"
		end
	end
end

-- What a tracker's slot is built with beyond its look: the warn time its countdown turns red at,
-- and the glow. A slot cannot be changed once built, so a new value means a new slot. The values
-- are taken when the slot is looked up out of combat, which is also when a new one can be made; in
-- a fight the slot already made is kept. (Slots are never made while the options window is open,
-- so moving the slider does not leave one behind at every step.)
local slotOpts = setmetatable({}, { __mode = "k" })
local function AppliedSlotOpts(g, t)
	local o = slotOpts[t]
	if not o then o = {} slotOpts[t] = o end
	if o.warn == nil or not ManagerUnsafe() then
		o.warn = (g.timers ~= false and (t.warn or 0) > 0) and floor(t.warn) or 0
		o.glow = t.glow and true or false
		o.label = (g.style == "bars" and type(t.label) == "string" and t.label ~= "") and t.label or nil
	end
	return o
end

-- Whether a tracker is drawn by the game (a slot) rather than by the addon, for the options panel.
function Display.TrackerGetsSlot(t)
	local g = t and ns.FindGroupOf(t)
	if not (g and ns.IsGameDrawn(g)) then return false end
	return SlotSpec(t, g) ~= nil
end

-- A slot's name in its container: the tracker, the filter, and what it was built with. A slot cannot
-- be changed once made, so anything it was built with is part of its name.
local function SlotName(t, filter, o, suffix)
	return tostring(t.uid) .. ":" .. filter .. ":cover" .. (o.warn > 0 and (":w" .. o.warn) or "") .. (o.glow and ":g" or "")
		.. (o.label and (":l" .. o.label) or "") .. (suffix or "")
end

-- Past this many slots made in a session (they cannot be freed), a reload is suggested.
local SLOT_ADVICE = 800

-- One slot in a container: made if it can be made now, and kept carrying the tracker's current
-- filters. Nil when it is not there and cannot be made now.
local function EnsureSlot(c, key, spec, look, o, t, noFrame)
	local frame = c.alSlots[key]
	if not frame then
		if ManagerUnsafe() then return nil end
		local store = {}
		local ok, fr = pcall(c.AddAuraSlot, c, key, spec.filter, { initializeFrame = InitSlotFrame(look, "cover", spec.filter, store,
			{ warn = o.warn, glow = o.glow, dispelRing = t.dispel ~= nil, noFrame = noFrame, label = o.label }), candidateFilters = spec.filters })
		if not ok or not fr then
			ns.report["game-drawn trackers"] = "AddAuraSlot: " .. tostring(fr)
			AdviseGameDrawn("game-drawn trackers", "the game refused a tracker's slot")
			return nil
		end
		frame = fr
		c.alSlots[key], c.alStore[key], c.alSpec[key] = frame, store, spec.key
		Display.slotsMade = (Display.slotsMade or 0) + 1
		ns.report["slots made"] = ("%d slots in %d containers this session"):format(Display.slotsMade, Display.containersMade or 0)
		if Display.slotsMade == SLOT_ADVICE and ns.Advise then
			ns.Advise("slots", "Aura Ledger has asked the game for a great many tracker slots this session, and the game cannot take them back. Reloading clears them out.",
				function() return true end)
		end
	elseif c.alSpec[key] ~= spec.key and not ManagerUnsafe() then
		if pcall(c.SetAuraSlotCandidateFilters, c, key, spec.filters) then c.alSpec[key] = spec.key end
	end
	return frame
end

-- The slot for one tracker in a group that watches only you. A debuff on your target goes in a
-- container of its own, which the game shows only while you have a target you can attack; its
-- showing again is also when it reads the target afresh. Returns the slot frames.
Display.TARGET_DRIVER = "[@target,harm,nodead] show; hide"
local function TrackerSlots(f, g, t, spec)
	local onTarget = t.unit == "target"
	local c = SlotContainer(f, g, onTarget and "target" or "player", onTarget and Display.TARGET_DRIVER or nil)
	if not c then return nil end
	local o = AppliedSlotOpts(g, t)
	local key = SlotName(t, spec.filter, o)
	local frame = EnsureSlot(c, key, spec, g, o, t)
	if not frame then return nil end
	return { { key = key, frame = frame, c = c, mask = c.alStore[key] and c.alStore[key].mask, mode = "cover" } }
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

-- A cell is five frames deep: the backing one below it, the bar just above, the art three above and
-- the text five. Moving the cell alone would leave the others where they were, so they all move.
local function SetCellLevel(w, base)
	base = max(1, base or w.alBaseLevel or 1)
	if w.alLevel == base then return end
	w.alLevel = base
	w:SetFrameLevel(base)
	if w.under then w.under:SetFrameLevel(max(0, base - 1)) end
	if w.bar then w.bar:SetFrameLevel(base + 1) end
	if w.over then w.over:SetFrameLevel(base + 3) end
	if w.overlay then w.overlay:SetFrameLevel(base + 5) end
end

-- ------------------------------------------------------------------
-- Groups that watch your party or raid. Each member has a container of the game's own, shown and
-- hidden by the game through a driver under the group's gate, holding one slot per tracker, each
-- anchored once over a cell of the addon's own for that member and tracker. All of it is made and
-- laid out out of a fight, a little each frame; in a fight the addon only shows and hides its own
-- frames (a row, its name, its veil) and repaints them.
-- ------------------------------------------------------------------
-- The section is a block of its own, so its helpers go out of scope at its end: a Lua chunk may hold
-- no more than 200 locals at once. What the rest of the file needs from it is declared here.
local ReleaseMembers
do
ns.RAID_TRACKER_CAP = 8   -- trackers across every group that watches a whole raid
ns.RAID_GROUP_CAP = 2     -- groups that watch a whole raid
-- Whether a member's slots fill again when they come back into view during a fight. Until that is
-- seen in game, such a row says "?" until the fight ends, when it is read afresh.
ns.MEMBER_REFILL = false
local PARTY_TOKENS = { "player", "party1", "party2", "party3", "party4" }
local RAID_TOKENS = {}
for i = 1, 40 do RAID_TOKENS[i] = "raid" .. i end
local TOKEN_INDEX = {}
for i, token in ipairs(PARTY_TOKENS) do TOKEN_INDEX[token] = i - 1 end
for i, token in ipairs(RAID_TOKENS) do TOKEN_INDEX[token] = i - 1 end
local PUMP_MS = 4
Display.memberJobs = {}
local jobIndex = {}

-- A question about a member, asked safely: nil when the call fails or the answer is hidden. A hidden
-- answer is only ever recognised, never tested.
local function Ask(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, v = pcall(fn, ...)
	if not ok then return nil end
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end
local function AskClass(unit)
	if type(UnitClass) ~= "function" then return nil end
	local ok, _, token = pcall(UnitClass, unit)
	if not ok or (issecretvalue and issecretvalue(token)) then return nil end
	return type(token) == "string" and token or nil
end
Display.Ask = Ask

-- Members are drawn as the group is: icons, or bars. (A shape built by hand is not used for them:
-- each member's row is laid out in order.)
local function MemberLook(g)
	return g
end
-- What a member's slot is built with. A change means new slots in the same containers. Icons need
-- only a few things; a bar is built with everything the group's own slots are, its art and the
-- plate's reach included.
local PLATE_KEYS = { "plateTop", "plateBottom", "plateEven", "fillInsetX", "fillInsetY", "barOffsetX", "barOffsetY", "plateLeft", "plateRight" }
local function MemberLookKey(g)
	if g.style == "bars" then
		local parts = { "mb", tostring(g.barW), tostring(g.barH), tostring(g.barIconScale or 1), tostring(g.iconFrame ~= false),
			tostring(g.border ~= false), tostring(g.timers ~= false), tostring(g.names ~= false), tostring(g.dispelColors == true),
			tostring(ns.MASK_EPOCH or 0) }
		for _, k in ipairs(PLATE_KEYS) do parts[#parts + 1] = tostring(ns.db and ns.db[k]) end
		return table.concat(parts, ":")
	end
	return "m" .. tostring(g.size or 40) .. (g.iconFrame ~= false and "f" or "") .. (g.timers ~= false and "t" or "")
		.. (g.dispelColors and "d" or "") .. "e" .. tostring(ns.MASK_EPOCH or 0)
end
-- Everything that changes what a member group has to build or lay out.
local function MemberSig(g)
	local parts = { MemberLookKey(g), tostring(g.units), tostring(g.memberNames), tostring(g.perColumn), tostring(g.grow),
		tostring(g.spacing), tostring(g.alpha), tostring(g.cond and g.cond.never), tostring(g.style), tostring(g.background ~= false) }
	for _, t in ipairs(g.trackers) do
		parts[#parts + 1] = table.concat({ tostring(t.uid), tostring(t.show), tostring(t.dispel), tostring(t.mine), tostring(t.matchId),
			tostring(t.name), tostring(t.id), tostring(t.glow), tostring(t.warn), tostring(t.cond and t.cond.never), tostring(t.kind),
			tostring(t.icon), tostring(t.cd), tostring(t.item), tostring(t.enchant), tostring(t.swing), tostring(t.label) }, "|")
	end
	return table.concat(parts, ";")
end

-- Which groups that watch a whole raid get the raid set, and which of their trackers, counted in
-- the order the groups are kept. Past either cap a tracker is on your party's rows only.
local function RaidAllowance()
	local out, groups, trackers = {}, 0, 0
	for _, g in ipairs(ns.profile.groups) do
		-- A group that is switched off takes nothing from the others.
		if ns.GroupUnits(g) == "raid" and not (g.cond and g.cond.never) then
			groups = groups + 1
			local allowed = {}
			if groups <= ns.RAID_GROUP_CAP then
				for _, t in ipairs(g.trackers) do
					if Display.MemberCanHold(t) and not (t.cond and t.cond.never) and SlotSpec(t, g) then
						trackers = trackers + 1
						if trackers <= ns.RAID_TRACKER_CAP then allowed[t] = true end
					end
				end
			end
			out[g] = allowed
		end
	end
	return out, trackers
end
Display.RaidAllowance = RaidAllowance

-- Whether a member's auras can say a tracker has nothing to show on them, so that it is taken off:
-- a buff set to show when it is missing, while they have it; a tracker the game draws only while its
-- aura is there (Active, or one for something you can remove), while there is none.
local function Takes(item)
	local t, spec = item.t, item.spec
	if not spec then return false end
	if t.dispel then return true end
	if t.show == "missing" then return spec.filter == "HELPFUL" end
	return t.show == "active" and spec.filters ~= nil and spec.filters.includeSpellIDs ~= nil
end

-- What a member group shows: its trackers in order, each with its slot's spec (nil for one the game
-- cannot follow here, which keeps its place with a question mark), and those the raid set carries.
-- A tracker's own conditions do not apply to members, bar switching it off: a condition read out
-- of a fight would stand for the whole of the next one.
local function MemberPlan(g)
	local units = ns.GroupUnits(g)
	local plan = { units = units, trackers = {}, raidTrackers = {}, byUid = {}, capped = false }
	local allowed = (units == "raid") and ((RaidAllowance())[g] or {}) or nil
	-- A group that is switched off builds nothing.
	if g.cond and g.cond.never then return plan end
	for _, t in ipairs(g.trackers) do
		if Display.MemberCanHold(t) and not (t.cond and t.cond.never) then
			local item = { t = t, spec = SlotSpec(t, g) }
			plan.trackers[#plan.trackers + 1] = item
			plan.byUid[t.uid] = item
			if allowed then
				if allowed[t] then plan.raidTrackers[#plan.raidTrackers + 1] = item
				elseif item.spec then plan.capped = true end
			end
		end
	end
	plan.raid = units == "raid" and #plan.raidTrackers > 0
	-- Whether any tracker here can be taken off a member, and which of their auras are read to say so.
	plan.filters = {}
	for _, item in ipairs(plan.trackers) do
		if Takes(item) then
			plan.takes = true
			plan.filters[item.spec.filter] = (item.spec.filter == "HELPFUL") and "buff" or "debuff"
		end
	end
	return plan
end

-- Each member's container is shown by the game while that member is there. In a group that watches
-- a whole raid, your party's rows give way to the raid's in a raid.
local function MemberDriver(plan, token)
	if token == "player" then return plan.raid and "[group:raid] hide; show" or nil end
	if token:find("^party") then return (plan.raid and "[group:raid] hide; " or "") .. "[@" .. token .. ",exists] show; hide" end
	return "[@" .. token .. ",exists] show; hide"
end
Display.MemberDriver = MemberDriver

local function PlanTokens(plan)
	local list = {}
	for _, token in ipairs(PARTY_TOKENS) do list[#list + 1] = { token = token, set = "party" } end
	if plan.raid then
		for _, token in ipairs(RAID_TOKENS) do list[#list + 1] = { token = token, set = "raid" } end
	end
	return list
end

-- The shape of a member group, in its own flow: a row per member (a column, growing up or down),
-- its name first, then a cell per tracker; raid rows wrap into a new block every perCol rows. A cell
-- is an icon, or a bar: as wide as the group's bars, and as tall as the taller of bar and icon.
local function MemberGeom(g, plan, set)
	local sp = g.spacing or 4
	local cw, ch
	if g.style == "bars" then
		cw, ch = g.barW or 190, max(g.barH or 22, ns.BarIconSize(g))
	else
		cw, ch = g.size or 40, g.size or 40
	end
	local grow = g.grow or "RIGHT"
	local flow = FLOW[grow] or grow
	local horiz = flow == "RIGHT" or flow == "LEFT"
	-- A cell's length along the flow, and its breadth across it.
	local along, across = cw, ch
	if not horiz then along, across = ch, cw end
	local step = along + sp
	local names = g.memberNames ~= false
	local L = names and (horiz and 68 or 14) or 0
	local P = (names and not horiz) and max(across + sp, 44) or (across + sp)
	local list = (set == "raid") and plan.raidTrackers or plan.trackers
	return { along = along, across = across, sp = sp, step = step, flow = flow, horiz = horiz, names = names, L = L, P = P,
		T = #list, list = list, blockLen = L + #list * step + floor(min(step, 44) / 2), perCol = (set == "raid") and (g.perColumn or 10) or 5 }
end

local function HideRow(row)
	row.hit:Hide()
	row.veil:Hide()
	for _, cell in pairs(row.cells) do cell:Hide() end
	row.shown = false
end

local STATE_SENTENCE = {
	ok = "The game is drawing this member's trackers, in a fight too.",
	wait = "Being set up, a little at a time, out of a fight.",
	off = "Offline.",
	dead = "Dead.",
	far = "Out of view: the game has no auras to show for them until they are back.",
	stale = "Changed hands during this fight, or came back into view or online. The row is read afresh when the fight ends (in a battleground, when the match ends).",
	absent = "Nobody here yet. When someone joins, their row fills in, in a fight too.",
}
local VEIL_WORD = { wait = "...", off = "Off", far = "Far", stale = "?" }

local function RowTooltip(owner, row)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:SetText(row.name or row.fallback or row.token, 1, 1, 1)
	local cls = row.class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[row.class]
	if cls then GameTooltip:AddLine(cls, 0.8, 0.8, 0.8) end
	GameTooltip:AddLine(STATE_SENTENCE[row.state or "ok"] or "", 0.6, 0.8, 1, true)
	GameTooltip:Show()
end

-- A member's row: its name, a veil over its cells saying why the game cannot show them, and the
-- cells. All of it on the gate, so it goes when the group's conditions hide it.
local function MemberRow(f, token, set)
	local m = f.members
	local row = m.rows[token]
	if row then return row end
	row = { token = token, set = set, index = TOKEN_INDEX[token] or 0, cells = {} }
	local hit = CreateFrame("Frame", nil, f.gate)
	-- Motion only: the name gives a tooltip, and clicks go past it to the world.
	hit:EnableMouse(false)
	if hit.SetMouseMotionEnabled then pcall(hit.SetMouseMotionEnabled, hit, true) end
	hit:SetScript("OnEnter", function(self) RowTooltip(self, row) end)
	hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
	local label = hit:CreateFontString(nil, "OVERLAY")
	label:SetFont(FONT, 11, "OUTLINE")
	label:SetAllPoints(hit)
	label:SetWordWrap(false)
	local veil = CreateFrame("Frame", nil, f.gate)
	veil:EnableMouse(false)
	local shade = veil:CreateTexture(nil, "BACKGROUND")
	shade:SetAllPoints(veil)
	shade:SetColorTexture(0, 0, 0, 0.6)
	veil.word = veil:CreateFontString(nil, "OVERLAY")
	veil.word:SetPoint("CENTER", veil, "CENTER", 0, 0)
	row.hit, row.label, row.veil = hit, label, veil
	if token == "player" then row.fallback = "You"
	elseif token:find("^party") then row.fallback = "Party " .. token:sub(6)
	else row.fallback = "Raid " .. token:sub(5) end
	HideRow(row)
	m.rows[token] = row
	return row
end

local function MemberCell(f, row, t)
	local cell = row.cells[t.uid]
	if cell then return cell end
	cell = CreateWidget(f.gate)
	cell:EnableMouse(false)
	if cell.SetMouseMotionEnabled then pcall(cell.SetMouseMotionEnabled, cell, false) end
	cell.underSlot = true
	cell:Hide()
	row.cells[t.uid] = cell
	return cell
end

-- The missing look under each slot; nothing under one shown only while active, or a dispel
-- tracker; a question mark where the game cannot follow the tracker here.
local function PaintCell(cell, g, item)
	cell.underSlot = true
	PaintWidget(cell, MemberLook(g), item.t, nil, false, false)
	if not item.spec then
		cell.icon:SetTexture(QUESTION)
		if g.style == "bars" then
			SetFill(cell, 0)
			TintFill(cell, nil, false)
			if cell.duration then cell.duration:SetText("") end
		end
		cell:SetAlpha(0.5)
	elseif item.t.show == "active" or item.t.dispel then
		cell:SetAlpha(0)
	else
		cell:SetAlpha(1)
	end
end

-- Where a row's name, veil and cells go. Out of a fight only.
local function PlaceRow(f, g, row, geo)
	row.packed = nil
	local q, r = floor(row.index / geo.perCol), row.index % geo.perCol
	local base = q * geo.blockLen
	PointAtCellPx(row.hit, f, geo.flow, base, r * geo.P)
	if geo.horiz then row.hit:SetSize(max(1, geo.L - 4), geo.across) else row.hit:SetSize(max(1, geo.P - 2), 12) end
	row.label:SetJustifyH(geo.flow == "LEFT" and "RIGHT" or "LEFT")
	local span = max(1, geo.T * geo.step - geo.sp)
	PointAtCellPx(row.veil, f, geo.flow, base + geo.L, r * geo.P)
	if geo.horiz then row.veil:SetSize(span, geo.across) else row.veil:SetSize(geo.across, span) end
	row.veil.word:SetFont(FONT, max(8, floor(min(geo.along, geo.across) * 0.45)), "OUTLINE")
	local planned = {}
	for k, item in ipairs(geo.list) do
		local cell = MemberCell(f, row, item.t)
		planned[item.t.uid] = true
		PaintCell(cell, g, item)
		PointAtCellPx(cell, f, geo.flow, base + geo.L + (k - 1) * geo.step, r * geo.P)
	end
	for uid, cell in pairs(row.cells) do
		cell.alInPlan = planned[uid] or false
		if not cell.alInPlan then
			cell:Hide()
			cell.alSuppressed = nil
		end
	end
end

-- A slot goes over its cell once; cells only move out of a fight, and it follows them.
local function AnchorSlot(frame, cell)
	if frame.alCell == cell or ManagerUnsafe() then return end
	local ok = pcall(function()
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", cell, "TOPLEFT", 0, 0)
		frame:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", 0, 0)
	end)
	if ok then frame.alCell = cell end
end

-- The cell sits under the game's slot and the veil over it, glow and all.
local function LevelRow(f, row, cell, frame)
	local okL, lvl = pcall(function() return frame:GetFrameLevel() end)
	lvl = okL and ns.Clean(lvl) or nil
	local okG, glvl = pcall(function() return f.gate:GetFrameLevel() end)
	glvl = okG and ns.Clean(glvl) or nil
	if type(lvl) == "number" then SetCellLevel(cell, lvl - 6)
	elseif type(glvl) == "number" then SetCellLevel(cell, glvl - 3) end
	local veilLevel = max(type(glvl) == "number" and (glvl + 20) or 0, type(lvl) == "number" and (lvl + 10) or 0)
	if veilLevel > 0 and (row.veilLevel or 0) < veilLevel then
		row.veil:SetFrameLevel(veilLevel)
		row.veilLevel = veilLevel
	end
end

-- ---- Reading members, for a group hidden in a fight ----
-- Out of a fight nothing about anyone's auras is hidden, so a group that is only on screen then can
-- read its members itself, and a tracker set to show when missing can mean it: taken off the
-- members who have the aura (its slot switched off, its cell hidden) until the aura is gone or
-- inside the tracker's warn time. In a fight such a group is hidden, so nothing has to change then.
-- A battleground or an arena keeps everyone's auras hidden for the whole match, out of fights too:
-- nothing can be read there, so nothing is taken off anyone there.
local function ReadsMembers(g)
	if not (ns.GroupUnits(g) ~= nil and g.cond ~= nil and g.cond.combat == "no" and not g.cond.never) then return false end
	local place = ns.env and ns.env.place
	return place ~= "bg" and place ~= "arena"
end
Display.ReadsMembers = ReadsMembers
-- Each member's aura changes, counted: every group that reads them reads again once per change.
local auraGen = {}
local auraWatch
-- A member's auras changed: read again at the next look.
function Display.MemberAuraChanged(unit)
	if type(unit) == "string" then auraGen[unit] = (auraGen[unit] or 0) + 1 end
end
local function WatchMemberAuras(on)
	if on and not auraWatch then
		auraWatch = CreateFrame("Frame")
		auraWatch:SetScript("OnEvent", function(_, _, unit)
			if not (issecretvalue and issecretvalue(unit)) then Display.MemberAuraChanged(unit) end
		end)
	end
	if not auraWatch then return end
	if on and not auraWatch.alOn then
		if pcall(auraWatch.RegisterEvent, auraWatch, "UNIT_AURA") then auraWatch.alOn = true end
	elseif not on and auraWatch.alOn then
		pcall(auraWatch.UnregisterEvent, auraWatch, "UNIT_AURA")
		auraWatch.alOn = nil
	end
end

-- The aura a tracker follows on a member, from what was read: by the spell ids its slot is given.
local function MatchAura(entries, t, spec)
	local ids = spec and spec.filters and spec.filters.includeSpellIDs
	if not (entries and ids) then return nil end
	local best
	for _, e in pairs(entries) do
		if e.id and ids[e.id] and (not t.mine or e.mine) then
			if not best or (best.expires > 0 and (e.expires == 0 or e.expires > best.expires)) then best = e end
		end
	end
	return best
end

-- Whether a tracker is taken off a member now. A Missing buff: they have it, and it is not about to
-- go. An Active one: they do not have it. One for something you can remove: they have nothing of
-- the kind (any debuff the game would show for it, or one of its type). Not while unread.
local function Suppressed(row, item, now)
	if not Takes(item) then return false end
	local entries = row.read and row.read[item.spec.filter]
	if not entries then return false end
	local t = item.t
	if t.dispel then
		local types = item.spec.filters and item.spec.filters.includeDispelTypes
		for _, e in pairs(entries) do
			if not types or (e.dispel and types[e.dispel]) then return false end
		end
		return true
	end
	local e = MatchAura(entries, t, item.spec)
	if e and e.expires > 0 and e.expires <= now then e = nil end
	if t.show ~= "missing" then return e == nil end
	if not e then return false end
	local warn = tonumber(t.warn) or 0
	if warn > 0 and e.expires > 0 and e.expires - now <= warn then return false end
	return true
end

-- Whether a member's bar slot leaves its frame to the cell: the cell is on show under it (the
-- tracker shows when missing too).
local function SlotNoFrame(g, item)
	return g.style == "bars" and item.t.show ~= "active" and not item.t.dispel
end
local function MemberSlotKey(g, item, o)
	return SlotName(item.t, item.spec.filter, o, ":" .. MemberLookKey(g) .. (SlotNoFrame(g, item) and ":nf" or ""))
end

local function QueueJob(f, g, token, uid)
	local k = tostring(g.uid) .. ":" .. token .. ":" .. tostring(uid or "c")
	if jobIndex[k] then return end
	jobIndex[k] = true
	local m = f.members
	if m then
		m.pending = m.pending or {}
		m.pending[token] = (m.pending[token] or 0) + 1
	end
	local jobs = Display.memberJobs
	jobs[#jobs + 1] = { f = f, g = g, token = token, uid = uid, k = k, m = m }
end
local function Pending(m, token) return m and m.pending and (m.pending[token] or 0) or 0 end

-- One step of building: a member's container and row, or one slot in it.
local function RunJob(job)
	local f, g, token = job.f, job.g, job.token
	local m = f.members
	if f.group ~= g or not (m and m.plan) or not f.gate then return end
	local plan = m.plan
	local set = token:find("^raid") and "raid" or "party"
	if set == "raid" and not plan.raid then return end
	local geo = MemberGeom(g, plan, set)
	local row = MemberRow(f, token, set)
	row.inPlan = true
	if not job.uid then
		local c = SlotContainer(f, g, token, MemberDriver(plan, token), true)
		if not c then return end
		PlaceRow(f, g, row, geo)
		if Pending(m, token) == 0 then
			row.guid = Ask(UnitGUID, token)
			row.built = true
		end
		return
	end
	local item = plan.byUid[job.uid]
	if not (item and item.spec) then return end
	local inSet = false
	for _, it in ipairs(geo.list) do if it == item then inSet = true end end
	if not inSet then return end
	local c = f.slotC and f.slotC["m:" .. token]
	if not c then return end
	local o = AppliedSlotOpts(g, item.t)
	local key = MemberSlotKey(g, item, o)
	local frame = EnsureSlot(c, key, item.spec, MemberLook(g), o, item.t, SlotNoFrame(g, item))
	if not frame then return end
	c.alOn = c.alOn or {}
	c.alOn[key] = true
	-- Made for a member it is taken off: the game makes it switched on, so it goes off at once.
	if c.alSuppress and c.alSuppress[key] and pcall(c.SetAuraSlotEnabled, c, key, false) then c.alOn[key] = false end
	local cell = MemberCell(f, row, item.t)
	AnchorSlot(frame, cell)
	LevelRow(f, row, cell, frame)
	-- The last step for this member: the row is ready, and whoever is in it now is what the game read.
	if not row.built and Pending(m, token) == 0 then
		row.guid = Ask(UnitGUID, token)
		row.built = true
	end
end

-- A row the game has to read afresh: after a fight in which its member changed, or came back into
-- view. Never in a fight, and never a show or a hide: setting the unit again is what makes it read.
function Display.BounceMembers()
	if ManagerUnsafe() then
		ns.WhenFree("members:bounce", Display.BounceMembers)
		return
	end
	for _, f in pairs(active) do
		local m = f.members
		if m then
			for token, row in pairs(m.rows) do
				if row.needsBounce then
					local c = f.slotC and f.slotC["m:" .. token]
					if c and row.built then
						pcall(c.SetUnit, c, "none")
						pcall(c.SetUnit, c, token)
					end
					row.guid = Ask(UnitGUID, token)
					row.stale, row.needsBounce = nil, nil
				end
			end
		end
	end
end

-- The state of a member, first match wins; anything that cannot be told counts as fine.
local function RowState(row, unlocked)
	if not row.built and not unlocked then return "wait" end
	local token = row.token
	if Ask(UnitIsConnected, token) == false then return "off" end
	if Ask(UnitIsDeadOrGhost, token) == true and Ask(UnitIsFeignDeath, token) ~= true then return "dead" end
	if Ask(UnitIsVisible, token) == false then return "far" end
	if row.stale then return "stale" end
	return "ok"
end

local function ShowRow(row, g, state, placeholder)
	row.state = state
	row.shown = true
	row.hit:SetShown(g.memberNames ~= false)
	for _, cell in pairs(row.cells) do cell:SetShown(cell.alInPlan == true and not cell.alSuppressed) end
	if not placeholder then
		local name = Ask(UnitName, row.token)
		if type(name) == "string" and name ~= "" and name ~= (type(UNKNOWNOBJECT) == "string" and UNKNOWNOBJECT or "Unknown") then row.name = name end
		local class = AskClass(row.token)
		if class then row.class = class end
	end
	local text = (not placeholder and row.name) or row.fallback
	local color = (state == "ok" and not placeholder and row.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[row.class]) or nil
	local shown = (color and color.colorStr) and ("|c" .. color.colorStr .. text .. "|r") or ("|cff8c8c8c" .. text .. "|r")
	if state == "dead" then shown = shown .. " |cff8c8c8c(dead)|r" end
	if row.labelText ~= shown then
		row.label:SetText(shown)
		row.labelText = shown
	end
	local word = (not placeholder) and VEIL_WORD[state] or nil
	if word then
		row.veil.word:SetText(word)
		row.veil:Show()
	else
		row.veil:Hide()
	end
	if row.collapsed then
		row.hit:Hide()
		row.veil:Hide()
		for _, cell in pairs(row.cells) do cell:Hide() end
	end
end

-- A row's name, veil and cells put at a place in the list: the given trackers side by side from the
-- start of the row. Moves only the addon's own frames; the game's slots are anchored to the cells and
-- follow them.
local function PositionRow(f, row, geo, at, items)
	local q, r = floor(at / geo.perCol), at % geo.perCol
	local base = q * geo.blockLen
	PointAtCellPx(row.hit, f, geo.flow, base, r * geo.P)
	PointAtCellPx(row.veil, f, geo.flow, base + geo.L, r * geo.P)
	local span = max(1, #items * geo.step - geo.sp)
	if geo.horiz then row.veil:SetSize(span, geo.across) else row.veil:SetSize(geo.across, span) end
	for k, item in ipairs(items) do
		local cell = row.cells[item.t.uid]
		if cell then PointAtCellPx(cell, f, geo.flow, base + geo.L + (k - 1) * geo.step, r * geo.P) end
	end
end

-- A row back in its own place with all its trackers, and on show again if it was closed up.
local function HomeRow(f, g, row, geo)
	if row.collapsed then
		row.collapsed = nil
		if row.shown then ShowRow(row, g, row.state, row.state == "absent") end
	end
	if row.packed then
		row.packed = nil
		PositionRow(f, row, geo, row.index, geo.list)
	end
end

-- The list closes up round what was taken off: a row with nothing left goes, name and all, the rows
-- after it move up, and in each row the trackers still shown sit side by side. With nothing taken
-- off, every row goes home. Out of a fight only, like everything that moves the cells.
local function PackRows(f, g, m, anyTaken)
	local geos = { party = MemberGeom(g, m.plan, "party"), raid = MemberGeom(g, m.plan, "raid") }
	local rows = {}
	for _, row in pairs(m.rows) do
		if anyTaken and row.inPlan and row.shown and row.set == m.set then rows[#rows + 1] = row
		else HomeRow(f, g, row, geos[row.set]) end
	end
	table.sort(rows, function(a, b) return a.index < b.index end)
	local at = 0
	for _, row in ipairs(rows) do
		local geo = geos[row.set]
		local items = {}
		for _, item in ipairs(geo.list) do
			local cell = row.cells[item.t.uid]
			if not (cell and cell.alSuppressed) then items[#items + 1] = item end
		end
		if #items == 0 and #geo.list > 0 then
			row.collapsed = true
			row.hit:Hide()
			row.veil:Hide()
			for _, cell in pairs(row.cells) do cell:Hide() end
		else
			if row.collapsed then
				row.collapsed = nil
				ShowRow(row, g, row.state, false)
			end
			if at ~= row.index or #items < #geo.list then
				row.packed = (at ~= row.index) and "moved" or "cells"
				PositionRow(f, row, geo, at, items)
			elseif row.packed then
				row.packed = nil
				PositionRow(f, row, geo, row.index, geo.list)
			end
			at = at + 1
		end
	end
	m.compacted = anyTaken or nil
end

-- The group's size: every row of the set on show, so the anchor corner never moves. Out of a fight
-- only (in one, a new size would move the game's slots with the cells).
local function Extent(g, plan, set)
	local geo = MemberGeom(g, plan, set)
	local rowsCount = (set == "raid") and 40 or 5
	local cols = ceil(rowsCount / geo.perCol)
	local along = (cols - 1) * geo.blockLen + geo.L + max(1, geo.T * geo.step - geo.sp)
	local across = (min(rowsCount, geo.perCol) - 1) * geo.P + geo.across
	if geo.horiz then return max(1, along), max(1, across) end
	return max(1, across), max(1, along)
end
local function SizeMembers(f, g, plan, set, both)
	if ManagerUnsafe() then return end
	local w, h = Extent(g, plan, set)
	if both then
		local w2, h2 = Extent(g, plan, "party")
		w, h = max(w, w2), max(h, h2)
	end
	f:SetSize(w, h)
	f.members.sizedFor = both and "both" or set
end

-- A row the game is not showing (the group's conditions hide it, or it belongs to the other set):
-- when it shows again the game reads it afresh, so what the addon remembers of it is let go.
local function Unseen(row)
	HideRow(row)
	row.wasAbsent = true
	row.state = "absent"
end

-- Which rows are on screen and what they say. Cheap, and safe at any time: it only shows and hides
-- the addon's own frames. Returns true when a row wants reading afresh now.
local function PaintStates(f, g)
	local m = f.members
	if not (m and m.plan) then return end
	local unlocked = Display:IsUnlocked()
	local unsafe = ManagerUnsafe()
	local set = "party"
	if m.plan.raid then
		local inRaid = Ask(IsInRaid)
		if inRaid == true then set = "raid" elseif inRaid == nil then set = m.set or "party" end
	end
	if m.set ~= set then
		m.set = set
		-- Joining or leaving a raid swaps the rows on show; the group is sized for the new ones when it can be.
		if m.sizedFor and m.sizedFor ~= set and not unlocked then
			if unsafe then m.dirty = true else SizeMembers(f, g, m.plan, set) end
		end
	end
	local bounce = false
	for token, row in pairs(m.rows) do
		if not row.inPlan or row.set ~= set then
			Unseen(row)
		else
			local exists = (token == "player") or Ask(UnitExists, token)
			if exists == nil then exists = row.shown end
			if exists then
				local guid = Ask(UnitGUID, token)
				if row.wasAbsent then
					-- Just joined: the game's own show of its container has read them afresh.
					row.wasAbsent = nil
					row.stale = nil
					if row.built and guid then row.guid = guid end
				elseif guid and row.guid and guid ~= row.guid then
					-- Someone else holds this place now, and the container still shows who was there.
					row.needsBounce = true
					if unsafe then row.stale = true else bounce = true end
				elseif guid and row.built and not row.guid then
					row.guid = guid
				end
				local state = RowState(row, unlocked)
				if (row.state == "far" or row.state == "off") and state == "ok" then
					row.needsBounce = true
					if not unsafe then bounce = true
					elseif not ns.MEMBER_REFILL then row.stale = true state = "stale" end
				end
				ShowRow(row, g, state, false)
			elseif unlocked and set == "party" and row.built then
				-- While arranging, an empty place in the party shows where it would be.
				row.wasAbsent = true
				ShowRow(row, g, "absent", true)
			else
				row.wasAbsent = true
				row.state = "absent"
				HideRow(row)
			end
		end
	end
	if bounce then Display.BounceMembers() end
end

-- Reads the members of a group hidden in a fight and takes its Missing trackers off those who have
-- the aura. Out of a fight and while auras can be read only; in one, what was decided stands (the
-- group is hidden then anyway). While the options window is open everything is shown. A member is
-- read again when their auras change, when someone else is in their place, and now and then anyway.
local function ApplyPresence(f, g)
	local m = f.members
	if not (m and m.plan) or ManagerUnsafe() then return end
	local reads = ReadsMembers(g) and m.plan.takes and not Display:IsUnlocked()
	if not reads and not m.anyTaken and not m.compacted then return end
	local now = GetTime()
	-- Each tracker's slot name, once: it is the same in every member's container.
	local keys = {}
	for _, item in ipairs(m.plan.trackers) do
		if item.spec then keys[item] = MemberSlotKey(g, item, AppliedSlotOpts(g, item.t)) end
	end
	local anyTaken = false
	for token, row in pairs(m.rows) do
		if row.inPlan then
			if reads and row.shown and row.set == m.set and Ask(UnitIsVisible, token) ~= false then
				local guid = Ask(UnitGUID, token)
				-- Read again when their auras change, someone else is in their place, the trackers (and so
				-- what has to be read) change, and now and then anyway.
				if row.auraGen ~= (auraGen[token] or 0) or row.auraGuid ~= guid or row.readPlan ~= m.plan or not row.auraAt or now - row.auraAt > 10 then
					row.read, row.readPlan = {}, m.plan
					for filter, kind in pairs(m.plan.filters or {}) do
						local out = {}
						local bad = ns.ReadAuras and ns.ReadAuras(token, filter, kind, out)
						row.read[filter] = (bad == 0) and out or nil
					end
					row.auraAt, row.auraGen, row.auraGuid = now, auraGen[token] or 0, guid
				end
			else
				row.read, row.auraAt = nil, nil
			end
			local c = f.slotC and f.slotC["m:" .. token]
			local list = (row.set == "raid") and m.plan.raidTrackers or m.plan.trackers
			for _, item in ipairs(list) do
				local off = reads and Suppressed(row, item, now) or false
				if off then anyTaken = true end
				local cell = row.cells[item.t.uid]
				if cell and (cell.alSuppressed or false) ~= off then
					cell.alSuppressed = off
					cell:SetShown(row.shown and cell.alInPlan == true and not off)
				end
				local key = keys[item]
				if c and key then
					c.alSuppress = c.alSuppress or {}
					c.alSuppress[key] = off or nil
					c.alOn = c.alOn or {}
					-- Off at once, even while the member's slots are still being built; back on only
					-- once the build pass has said the slot is wanted.
					if c.alSlots[key] and (off or (c.alWanted and c.alWanted[key])) then
						local on = not off
						if c.alOn[key] ~= on and pcall(c.SetAuraSlotEnabled, c, key, on) then c.alOn[key] = on end
					end
				end
			end
		end
	end
	m.anyTaken = anyTaken
	if anyTaken or m.compacted then PackRows(f, g, m, anyTaken) end
end
Display.ApplyPresence = ApplyPresence

-- Everything taken off members is put back: slots on, cells shown. Before a loading screen, since in
-- a battleground on the other side nothing can be changed until the match ends.
function Display.DropPresence()
	if ManagerUnsafe() then return end
	for _, f in pairs(active) do
		local m = f.members
		if m and (m.anyTaken or m.compacted) then
			for token, row in pairs(m.rows) do
				row.read, row.auraAt = nil, nil
				for _, cell in pairs(row.cells) do
					if cell.alSuppressed then
						cell.alSuppressed = false
						cell:SetShown(row.shown and cell.alInPlan == true)
					end
				end
				local c = f.slotC and f.slotC["m:" .. token]
				if c and c.alSuppress then
					for key in pairs(c.alSuppress) do
						if c.alSlots[key] and c.alWanted and c.alWanted[key] and c.alOn and c.alOn[key] ~= true then
							if pcall(c.SetAuraSlotEnabled, c, key, true) then c.alOn[key] = true end
						end
					end
					c.alSuppress = {}
				end
			end
			m.anyTaken = false
			if m.plan and f.group then PackRows(f, f.group, m, false) end
			m.compacted = nil
		end
	end
end

-- Gives up a group's member rows: the frame is going to another group, or back to watching you.
function ReleaseMembers(f)
	local m = f.members
	if not m then return end
	for _, row in pairs(m.rows) do
		HideRow(row)
		row.collapsed, row.packed = nil, nil
		for _, cell in pairs(row.cells) do cell.alSuppressed = nil end
	end
	-- What was taken off members goes with the rows: the next pass switches slots on by what it wants.
	for slot, c in pairs(f.slotC or {}) do
		if slot:sub(1, 2) == "m:" then c.alSuppress = nil end
	end
	f.members = nil
end
Display.ReleaseMembers = ReleaseMembers

-- The member pass: what the group should hold, laid out, with anything missing queued to be built.
-- Out of a fight and while auras can be read only; otherwise the rows are only repainted.
function Display:RefreshMembers(g)
	local f = active[g.uid]
	if not f then return end
	f.members = f.members or { rows = {}, dirty = true }
	local m = f.members
	local unsafe = ManagerUnsafe()
	local unlocked = self:IsUnlocked()
	-- A member group draws no cells of the ordinary kind.
	for _, w in ipairs(f.widgets) do
		if w.tracker or w:IsShown() then
			w:Hide()
			WidgetGlow(w, g, false)
			w.tracker, w.entry, w.timed = nil, nil, false
		end
	end
	f:SetAlpha(g.alpha or 1)
	f:Show()
	if not unsafe then
		-- The gate's conditions can change without the group changing (a zone, a talent swap).
		local gate = EnsureGate(f, g)
		if gate.alDropped then gate:Show() gate.alDropped = nil end
	end
	if not unsafe and Display.TrySkinAgain and Display:TrySkinAgain(g.style == "bars") then
		Display:Rebuild()
		return
	end
	local sig = MemberSig(g)
	if m.sig ~= sig then m.dirty = true end
	local passed = false
	if not unsafe and f.gate and m.dirty then
		passed = true
		Display.memberPasses = (Display.memberPasses or 0) + 1
		m.dirty = false
		m.sig = sig
		local plan = MemberPlan(g)
		m.plan = plan
		local lookKey = MemberLookKey(g)
		if m.lookKey ~= lookKey then
			if m.lookKey then Display.lookChangedAt = GetTime() end
			m.lookKey = lookKey
		end
		-- A slider being moved (size, warn time) changes what is built at every step: wait for it to stop.
		if unlocked then Display.lookChangedAt = GetTime() end
		local tokens = PlanTokens(plan)
		local keep = {}
		for _, e in ipairs(tokens) do keep["m:" .. e.token] = true end
		ParkContainers(f, keep)
		for token, row in pairs(m.rows) do if not keep["m:" .. token] then row.inPlan = false HideRow(row) end end
		local geos = { party = MemberGeom(g, plan, "party"), raid = MemberGeom(g, plan, "raid") }
		local look = MemberLook(g)
		for _, e in ipairs(tokens) do
			local geo = geos[e.set]
			local c = f.slotC and f.slotC["m:" .. e.token]
			local row = m.rows[e.token]
			if not row and (e.set == "party" or c) then row = MemberRow(f, e.token, e.set) end
			-- A container kept from before (the rows were given up, the containers cannot be) is built,
			-- once nothing more is waiting to be made for it.
			if row and c and c.alKey == "member" and Pending(m, e.token) == 0 then row.built = true end
			if row then
				row.inPlan = true
				PlaceRow(f, g, row, geo)
			end
			if c and c.alKey == "member" then
				SlotContainer(f, g, e.token, MemberDriver(plan, e.token), true)
				local wanted = {}
				for _, item in ipairs(geo.list) do
					if item.spec then
						local o = AppliedSlotOpts(g, item.t)
						local key = MemberSlotKey(g, item, o)
						wanted[key] = true
						local frame = c.alSlots[key]
						if frame then
							EnsureSlot(c, key, item.spec, look, o, item.t, SlotNoFrame(g, item))
							local cell = row and row.cells[item.t.uid]
							if cell then
								AnchorSlot(frame, cell)
								LevelRow(f, row, cell, frame)
							end
						else
							QueueJob(f, g, e.token, item.t.uid)
							-- The slot it replaces (an old look, an old warn time) stays on until it is made,
							-- so a fight starting in between still has the game drawing this tracker.
							local prefix = tostring(item.t.uid) .. ":"
							for key in pairs(c.alSlots) do
								if key:sub(1, #prefix) == prefix and c.alOn and c.alOn[key] then wanted[key] = true end
							end
						end
					end
				end
				-- Slots for trackers no longer here, or built with an old look, are switched off; the
				-- rest on. Whether the member is there does not matter: a slot that is on fills the
				-- moment someone joins, in a fight too.
				c.alOn = c.alOn or {}
				c.alWanted = wanted
				for key in pairs(c.alSlots) do
					local on = (wanted[key] and not (c.alSuppress and c.alSuppress[key])) and true or false
					if c.alOn[key] ~= on and pcall(c.SetAuraSlotEnabled, c, key, on) then c.alOn[key] = on end
				end
			else
				QueueJob(f, g, e.token, nil)
				for _, item in ipairs(geo.list) do
					if item.spec then QueueJob(f, g, e.token, item.t.uid) end
				end
			end
		end
		local centred = g.grow == "CENTER_H" or g.grow == "CENTER_V"
		local both = unlocked and plan.raid and not centred
		SizeMembers(f, g, plan, (plan.raid and (both or m.set == "raid")) and "raid" or "party", both)
	end
	f.chrome:SetShown(unlocked)
	if unlocked then
		local scope = (ns.GroupUnits(g) == "raid") and "everyone" or "my party"
		local hidden = f.gate and not f.gate:IsShown()
		f.chrome.label:SetText(ns.GroupName(g) .. "  |cff8fd4ff" .. scope .. "|r" .. (hidden and "  |cff9a9a9ahidden now|r" or ""))
		local sel = ns.selected and ns.selected.group == g
		if f.chrome.SetBackdropBorderColor then
			if sel then f.chrome:SetBackdropBorderColor(0.3, 1, 0.4, 1) else f.chrome:SetBackdropBorderColor(1, 0.82, 0, 0.9) end
		end
	end
	-- Between passes the twice-a-second poll keeps the rows up to date; every scan of your own auras
	-- comes through here, and none of them is news about your party.
	if passed then
		PaintStates(f, g)
		ApplyPresence(f, g)
	end
end

-- Builds what the member passes queued, a few milliseconds a frame, out of a fight only. While the
-- options window is open it waits until the look has stopped changing, so that moving a slider
-- does not leave a set of slots behind at every step.
function Display:PumpMembers()
	if self.rosterDirty then
		self.rosterDirty = nil
		self:PollMembers()
	end
	local jobs = self.memberJobs
	if #jobs == 0 or ManagerUnsafe() then return end
	if self:IsUnlocked() and GetTime() - (self.lookChangedAt or -100) < 1 then return end
	local start = type(debugprofilestop) == "function" and debugprofilestop() or nil
	local n = 0
	while #jobs > 0 do
		local job = table.remove(jobs, 1)
		jobIndex[job.k] = nil
		if job.m and job.m.pending and job.m.pending[job.token] then job.m.pending[job.token] = max(0, job.m.pending[job.token] - 1) end
		local ok, err = pcall(RunJob, job)
		if not ok then ns.report["members"] = "a build step failed: " .. tostring(err) end
		n = n + 1
		if ManagerUnsafe() then break end
		if start then
			if debugprofilestop() - start >= PUMP_MS then break end
		elseif n >= 2 then
			break
		end
	end
	if #jobs == 0 then
		-- Built: one more pass switches the new slots on and settles the rows.
		for _, f in pairs(active) do
			if f.members and f.group then
				f.members.dirty = true
				self:RefreshMembers(f.group)
			end
		end
	end
end

-- The roster and each member's state, twice a second: only rows of groups on screen, and only
-- what changed is repainted.
function Display:PollMembers()
	if not ready then return end
	local watch = false
	for _, f in pairs(active) do
		local g = f.group
		if g and ReadsMembers(g) and f.members and f.members.plan and f.members.plan.takes then watch = true end
		if g and f.members and ns.GroupUnits(g) and f.gate then
			if f.gate:IsShown() then
				PaintStates(f, g)
				ApplyPresence(f, g)
			else
				-- Hidden by its conditions: its containers are hidden too, and are read afresh when shown.
				for _, row in pairs(f.members.rows) do Unseen(row) end
			end
		end
	end
	-- Members' aura changes are listened for only while a group reads them.
	WatchMemberAuras(watch)
end

function Display:RosterChanged()
	self.rosterDirty = true
end

-- Whether some of a raid group's trackers are past the raid cap, for its panel.
function Display.RaidCapped(g)
	if ns.GroupUnits(g) ~= "raid" then return false end
	local allowance = RaidAllowance()
	local allowed = allowance[g] or {}
	for _, t in ipairs(g.trackers) do
		if Display.MemberCanHold(t) and not (t.cond and t.cond.never) and SlotSpec(t, g) and not allowed[t] then return true end
	end
	return false
end

-- /auraledger debug members: every group that watches your party, row by row, and what has been
-- asked of the game this session. "probe" sets a member's container to its unit again, which is
-- what the addon waits for the end of a fight to do; run in a fight, it shows whether that waiting
-- is needed at all.
function Display:MembersReport(emit, rest)
	local S = function(v) if issecretvalue and issecretvalue(v) then return "hidden" end return tostring(v) end
	if string.lower(rest or "") == "probe" then
		for _, f in pairs(active) do
			local m = f.members
			for token, row in pairs(m and m.rows or {}) do
				local c = f.slotC and f.slotC["m:" .. token]
				if c and token ~= "player" and row.shown and row.built then
					local blocked = 0
					for _, n in pairs(ns.blocked or {}) do blocked = blocked + n end
					local ok1, e1 = pcall(c.SetUnit, c, "none")
					local ok2, e2 = pcall(c.SetUnit, c, token)
					local after = 0
					for _, n in pairs(ns.blocked or {}) do after = after + n end
					emit(("probe on %s (%s), in a fight %s: first %s, second %s, blocked calls %d"):format(token, tostring(row.name or "?"),
						tostring(InCombatLockdown and InCombatLockdown() or false), ok1 and "ok" or ("error " .. tostring(e1)),
						ok2 and "ok" or ("error " .. tostring(e2)), after - blocked))
					emit("Now look at their row: if it still shows their buffs, rows can be read afresh in a fight.")
					return
				end
			end
		end
		emit("probe: needs a group that watches your party, with a party member on screen.")
		return
	end
	local any = false
	for _, f in pairs(active) do
		local g, m = f.group, f.members
		if g and ns.GroupUnits(g) then
			any = true
			local plan = m and m.plan
			emit(("%s: watches %s, showing %s rows, %d trackers (%d on raid rows)%s, gate %s"):format(ns.GroupName(g), ns.GroupUnits(g),
				tostring(m and m.set or "-"), plan and #plan.trackers or 0, plan and #plan.raidTrackers or 0, plan and plan.capped and ", past the raid cap" or "",
				f.gate and tostring(f.gate.alMacro) or "none"))
			local tokens = {}
			for token in pairs(m and m.rows or {}) do tokens[#tokens + 1] = token end
			table.sort(tokens, function(a, b) return (TOKEN_INDEX[a] or 0) + (a:find("^raid") and 100 or 0) < (TOKEN_INDEX[b] or 0) + (b:find("^raid") and 100 or 0) end)
			for _, token in ipairs(tokens) do
				local row = m.rows[token]
				local c = f.slotC and f.slotC["m:" .. token]
				local n, on = 0, 0
				for key in pairs(c and c.alSlots or {}) do
					n = n + 1
					if c.alOn and c.alOn[key] then on = on + 1 end
				end
				if row.inPlan then
					emit(("  %s %s: %s%s%s%s, container %s, slots %d (%d on)"):format(token, tostring(row.name or row.fallback), tostring(row.state or "-"),
						(row.guid and "" or ", not yet read") .. (row.collapsed and ", closed up (nothing to show)" or row.packed == "moved" and ", moved up" or row.packed and ", trackers closed up" or ""),
						row.stale and ", marked" or "", row.needsBounce and ", to be read afresh" or "",
						c and S(c.alMacro) or "none", n, on))
				end
			end
		end
	end
	if not any then emit("No group watches your party.") end
	emit(("Build steps waiting: %d. Made this session: %d containers, %d slots. Rows refill in a fight when back in view: %s.")
		:format(#self.memberJobs, self.containersMade or 0, self.slotsMade or 0, tostring(ns.MEMBER_REFILL)))
	local _, raidTrackers = RaidAllowance()
	emit(("Raid rows: %d of %d trackers used."):format(raidTrackers, ns.RAID_TRACKER_CAP))
	emit("Edit Mode placeholders: " .. tostring(ns.report["edit mode preview"] or "not asked yet"))
	for _, family in ipairs(ns.BUFF_FAMILIES or {}) do
		local parts = {}
		for _, name in ipairs(family) do
			ns.Ranks(name)
			local st = ns.rankState[name]
			local own = ns.bookRanks[string.lower(name)]
			local mine = 0
			for _ in pairs(own or {}) do mine = mine + 1 end
			parts[#parts + 1] = ("%s %d kept, %d dropped, %d waiting, %d from your spellbook"):format(name, st and st.kept or 0, st and st.dropped or 0,
				st and st.pending or 0, mine)
		end
		emit("  " .. table.concat(parts, "; "))
	end
end

-- Something every member group has to take in (new ranks, the end of a fight).
function Display:MembersDirty()
	for _, f in pairs(active) do if f.members then f.members.dirty = true end end
end

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
	-- A group the game draws nothing in (only cooldowns, items, weapons, or a fight joined before its
	-- slots could be made) is laid out and shown as the addon's.
	if slots and not (f.slotC and next(f.slotC)) then
		slots = false
		for _, it in ipairs(visible) do if it.slots then slots = true break end end
	end

	-- A group that watched your party until now puts its members' rows and containers away.
	if f.members then ReleaseMembers(f) end
	if f.slotC then ParkContainers(f, f.keepUnits or { player = true }) end
	-- Every slot starts the pass switched off; the ones with a cell are switched on below.
	-- Containers are never shown or hidden from here: the gate's driver does that.
	if f.slotC and slots then
		for unit, c in pairs(f.slotC) do
			for key in pairs(c.alSlots) do c.alWant = c.alWant or {} c.alWant[key] = false end
		end
	end
	if slots then
		local gate = EnsureGate(f, g)
		if gate.alDropped and not ManagerUnsafe() then gate:Show() gate.alDropped = nil end
	elseif f.gate then
		DropGate(f)
	end
	local cellParent = slots and f.gate or f

	-- Where each icon stands. Bars are a straight list and have no shape; icons take theirs from
	-- the group, held against whichever corner of it is actually used, so that a shape built
	-- upwards or leftwards does not drag the group across the screen when part of it goes quiet.
	-- A shape that was built by hand holds every icon in the cell it was given, so the outline
	-- stays put and a tracker that is not on screen simply leaves its gap. A shape that is still
	-- plain rows is filled in order by whatever is on screen, which is what rows have always done.
	local shaped = (g.style ~= "bars") and g.shaped and g.cells and true or false
	local cellA, cellB, rawA, rawB = {}, {}, {}, {}
	local minA, minB, maxA, maxB
	local function span(a, b)
		if not minA or a < minA then minA = a end
		if not minB or b < minB then minB = b end
		if not maxA or a > maxA then maxA = a end
		if not maxB or b > maxB then maxB = b end
	end
	if shaped then
		-- The whole shape sets the group's size, not only the part of it that is on screen.
		for _, cell in ipairs(g.cells) do span(tonumber(cell.c) or 0, tonumber(cell.r) or 0) end
	end
	for k = 1, n do
		local a, b
		if g.style ~= "bars" then
			local cell
			if shaped then
				for i, t in ipairs(g.trackers) do
					if t == visible[k].t then cell = g.cells[i] break end
				end
			else
				cell = g.cells and g.cells[k]
			end
			if cell then a, b = tonumber(cell.c), tonumber(cell.r) end
		end
		if not a or not b then a, b = (k - 1) % perRow, floor((k - 1) / perRow) end
		rawA[k], rawB[k] = a, b
		if not shaped then span(a, b) end
	end
	for k = 1, n do cellA[k], cellB[k] = rawA[k] - (minA or 0), rawB[k] - (minB or 0) end
	-- Kept so that a drop can work out where a cell would land without laying the group out again.
	f.cellMinA, f.cellMinB, f.cellStepX, f.cellStepY = minA or 0, minB or 0, stepX, stepY
	f.cellFlow = flow

	for k = 1, n do
		local widget = f.widgets[k]
		if not widget then
			widget = CreateWidget(f)
			f.widgets[k] = widget
		end
		local item = visible[k]
		if item.placeholder then
			-- Held open in a fight: see HeldOrder.
			widget:Hide()
			WidgetGlow(widget, g, false)
			widget.tracker, widget.entry, widget.timed, widget.underSlot = nil, nil, false, nil
			widget.cellC, widget.cellR = rawA[k], rawB[k]
		else
			widget.underSlot = (slots and item.slots) and true or nil
			-- The cell under a slot is painted with no aura, so that it shows the missing look when the
			-- game stops drawing. What the group actually knows is kept here, for the frame.
			widget.auraKnown = (item.entry ~= nil) or nil
			widget:SetAlpha(1)
			if widget:GetParent() ~= cellParent then widget:SetParent(cellParent) end
			if slots and item.slots then
				-- The addon draws only the missing state under a game-drawn slot; the game covers it
				-- while the aura is present. "Show when active" leaves the cell empty underneath.
				PaintWidget(widget, g, item.t, nil, false, false)
				if item.t.show == "active" then widget:SetAlpha(0) end
				-- On your target, with none you can attack, there is nothing to be missing from: the cell
				-- keeps its place for the slot, which stays switched on for the next target.
				if item.t.unit == "target" and not (ns.env and ns.env.targetFoe) then widget:SetAlpha(0) end
				for _, sl in ipairs(item.slots) do
					sl.c.alWant[sl.key] = true
					if not ManagerUnsafe() then
						local ok = pcall(function()
							sl.frame:ClearAllPoints()
							sl.frame:SetPoint("TOPLEFT", widget, "TOPLEFT", 0, 0)
							sl.frame:SetPoint("BOTTOMRIGHT", widget, "BOTTOMRIGHT", 0, 0)
						end)
						if ok then sl.frame.alAnchor = k end
					end
					-- The game's icon has to cover the cell underneath, edge and all. The button is the
					-- game's own and may refuse to be read at all, so nothing is asked of it unguarded.
					local okL, lvl = pcall(function() return sl.frame:GetFrameLevel() end)
					lvl = okL and ns.Clean(lvl) or nil
					if type(lvl) == "number" then
						SetCellLevel(widget, lvl - 6)
					else
						-- In combat the game refuses to say where its own frame sits. The gate the slots
						-- hang on is the addon's own and always answers, and a slot is three levels above
						-- it, so the cell goes far enough below the gate that all of it stays under.
						local okG, glvl = pcall(function() return (f.gate or f):GetFrameLevel() end)
						if okG and type(glvl) == "number" then SetCellLevel(widget, glvl - 3) end
					end
					-- A cooldown makes its textures the first time it runs, and the game runs these, so
					-- the mask is asked for again here rather than only when the slot was built.
					if sl.frame.alW then
						ShapeCooldownsOn(sl.frame.alW, sl.frame, sl.frame.alCdSize or g.size or 40, g.iconFrame ~= false)
					end
				end
			else
				SetCellLevel(widget, widget.alBaseLevel)
				PaintWidget(widget, g, item.t, item.entry, unlocked, item.expiring)
			end
			widget.cellC, widget.cellR = rawA[k], rawB[k]
			PointAtCell(widget, f, flow, cellA[k], cellB[k], stepX, stepY)
			-- Marked to be moved with the others: a ring in a color nothing else here uses.
			if unlocked and Display:IsMarked(item.t) then
				if not widget.markRing then
					widget.markRing = {}
					for i = 1, 4 do
						local line = widget:CreateTexture(nil, "OVERLAY")
						line:SetColorTexture(0.4, 0.85, 1, 0.95)
						widget.markRing[i] = line
					end
					local mt, mb, ml, mr = widget.markRing[1], widget.markRing[2], widget.markRing[3], widget.markRing[4]
					mt:SetPoint("TOPLEFT", -2, 2) mt:SetPoint("TOPRIGHT", 2, 2) mt:SetHeight(2)
					mb:SetPoint("BOTTOMLEFT", -2, -2) mb:SetPoint("BOTTOMRIGHT", 2, -2) mb:SetHeight(2)
					ml:SetPoint("TOPLEFT", -2, 2) ml:SetPoint("BOTTOMLEFT", -2, -2) ml:SetWidth(2)
					mr:SetPoint("TOPRIGHT", 2, 2) mr:SetPoint("BOTTOMRIGHT", 2, -2) mr:SetWidth(2)
				end
				for _, line in ipairs(widget.markRing) do line:Show() end
			elseif widget.markRing then
				for _, line in ipairs(widget.markRing) do line:Hide() end
			end
			widget:EnableMouse(unlocked)
			-- Motion without clicks: a tooltip on hover during play, with clicks still going past to
			-- whatever is behind, which is where they belong while the window is shut. A cell under a
			-- slot leaves the mouse alone: the game's own slot is over it and gives the aura's tooltip,
			-- and both answering would give two tooltips at once.
			if widget.SetMouseMotionEnabled then pcall(widget.SetMouseMotionEnabled, widget, not widget.underSlot) end
			widget:Show()
		end
	end
	for k = n + 1, #f.widgets do
		local widget = f.widgets[k]
		widget:Hide()
		WidgetGlow(widget, g, false)
		widget.tracker, widget.entry, widget.timed = nil, nil, false
	end

	if f.slotC and slots and not ManagerUnsafe() then
		for unit, c in pairs(f.slotC) do
			for key, want in pairs(c.alWant or {}) do
				if c.alOn == nil then c.alOn = {} end
				if c.alOn[key] ~= want then
					if pcall(c.SetAuraSlotEnabled, c, key, want) then c.alOn[key] = want end
				end
			end
		end
	end

	local p, q = 1, 1
	if n > 0 then p, q = (maxA - minA) + 1, (maxB - minB) + 1 end
	if flow == "DOWN" or flow == "UP" then p, q = q, p end
	f:SetSize(max(1, p * stepX - g.spacing), max(1, q * stepY - g.spacing))
	f:SetAlpha(g.alpha or 1)

	f.chrome:SetShown(unlocked)
	if unlocked then
		-- While arranging, the plate says whether this group holds a shape you built or lays its
		-- icons out in rows, since the two behave differently when a tracker goes quiet.
		local shape = ""
		if g.style ~= "bars" then
			shape = g.shaped and "  |cff8fd4ffcluster|r" or "  |cff9a9a9arows|r"
		end
		f.chrome.label:SetText(ns.GroupName(g) .. shape)
		local sel = ns.selected and ns.selected.group == g
		if f.chrome.SetBackdropBorderColor then
			if sel then f.chrome:SetBackdropBorderColor(0.3, 1, 0.4, 1) else f.chrome:SetBackdropBorderColor(1, 0.82, 0, 0.9) end
		end
	end
	-- Containers that could not be put away yet (the gate stays while auras are hidden) must not be
	-- hidden with the group: that is a hide of the game's frames. Faded instead, until they can be.
	local live = not slots and f.gate and not f.gate.alDropped and f.slotC and next(f.slotC) ~= nil
	if slots then
		f:Show()
	elseif live then
		f:Show()
		f:SetAlpha(n > 0 and (g.alpha or 1) or 0)
	else
		f:SetShown(n > 0)
	end
end

-- Is the aura inside the tracker's "warn before it runs out" window?
local function Expiring(t, entry, now)
	local warn = t.warn or 0
	if warn <= 0 or not entry or entry.expires <= 0 then return false end
	return (entry.expires - now) <= warn
end
Display.Expiring = Expiring

-- Which state a cooldown or weapon entry is in, for noticing a change that moves no time.
local function EntryState(e)
	if e == nil then return 0 end
	if e.lockout then return 5 end
	if e.held then return 1 end
	if e.secret then return 2 end
	if e.ready then return 3 end
	return 4
end

-- Whether a tracker shows right now, and whether it is showing because the aura is about to run out.
local function Wants(t, entry, now, unlocked, groupPass)
	if unlocked then return true, false end
	-- Only the game can draw a dispel tracker: in a group the addon draws it never shows.
	if t.dispel then return false, false end
	if not groupPass or not ns.CondPass(t.cond) then return false, false end
	-- A spell is always there, so for a cooldown tracker it is the cooldown that is on or off:
	-- "active" means on cooldown, "missing" means ready to cast.
	if t.cd then
		-- No reading at all (a spell the character cannot cast right now, or a cooldown the game is
		-- hiding with nothing to go on) is not "ready": it is unknown, and only "either" shows it.
		if entry == nil then return t.show == "always", false end
		local onCd = not entry.ready
		-- The warn window works the same way round as it does for an aura: it brings the tracker
		-- back before the thing you are waiting for happens, which for a cooldown is being ready.
		local nearly = onCd and Expiring(t, entry, now) or false
		if t.show == "missing" then return (not onCd) or nearly, nearly
		elseif t.show == "always" then return true, nearly
		else return onCd, nearly end
	end
	if t.unit == "target" and not ns.env.targetFoe then return false, false end
	local expiring = Expiring(t, entry, now)
	if t.show == "missing" then return entry == nil or expiring, expiring
	elseif t.show == "always" then return true, expiring
	-- Already on screen, so the warning it can give is the red border rather than appearing.
	else return entry ~= nil, expiring end
end

-- What each tracker looked like last time, so sounds play only on a change (never on the first look).
local trackState = setmetatable({}, { __mode = "k" })

local function Sounds(t, entry, show, unlocked, groupPass)
	local st = trackState[t]
	local active = entry ~= nil
	local shown = show and not unlocked
	if st then
		-- A tracker on your target plays none: switching between targets would set them all off.
		local snd = (t.unit ~= "target") and t.snd or nil
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

-- In a game-drawn group, while auras are hidden the order laid out last is held: a tracker the addon
-- draws that goes quiet keeps its place empty, and one that appears goes on the end, so no slot has
-- to move (the game refuses to have its slots moved then).
local function HeldOrder(f, visible)
	local byT = {}
	for _, it in ipairs(visible) do byT[it.t] = it end
	local out, used = {}, {}
	for _, t in ipairs(f.safeOrder) do
		local it = byT[t]
		if it then out[#out + 1] = it used[t] = true else out[#out + 1] = { t = t, placeholder = true } end
	end
	for _, it in ipairs(visible) do if not used[it.t] then out[#out + 1] = it end end
	return out
end

function Display:RefreshGroup(g)
	-- A group that watches your party has its own pass; its look is always icons.
	if ns.GroupUnits(g) then return self:RefreshMembers(g) end
	if Display.TrySkinAgain and Display:TrySkinAgain(g.style == "bars") then
		Display:Rebuild()
		return
	end
	local f = active[g.uid]
	if not f then return end
	local unlocked = self:IsUnlocked()
	local groupPass = unlocked or ns.CondPass(g.cond)
	-- A group the game draws is shown and hidden in a fight by its gate, so its slots are made ready out
	-- of one even while In combat keeps it off screen there: they cannot be made once the fight starts.
	local slotPass = groupPass
	if not slotPass and g.gameDrawn and type(g.cond) == "table" and g.cond.combat == "yes" then
		local c = {}
		for k, v in pairs(g.cond) do c[k] = v end
		c.combat = nil
		slotPass = ns.CondPass(c)
	end
	local now = GetTime()
	local visible = {}
	-- The containers this group keeps out: yours, and your target's while it has a tracker on it.
	f.keepUnits = { player = true }
	for _, t in ipairs(g.trackers) do
		if t.unit == "target" then f.keepUnits.target = true end
		local entry = ns.Find(t)
		local show, expiring = Wants(t, entry, now, unlocked, groupPass)
		-- Without a slot a debuff on your target is read by the addon, which cannot read it in a fight.
		if t.unit == "target" and not unlocked and ns.AurasSecret() then show = false end
		local slots
		if g.gameDrawn and not unlocked then
			local passes = slotPass and ns.CondPass(t.cond)
			local spec = passes and SlotSpec(t, g)
			slots = spec and TrackerSlots(f, g, t, spec)
		end
		-- A slot tracker's warning is the colour of its countdown; it is never brought on screen early,
		-- so its "shown" sound does not come early either.
		local soundShow = show
		if slots and expiring and t.show == "missing" then soundShow = (entry == nil) end
		Sounds(t, entry, soundShow, unlocked, unlocked and ns.CondPass(g.cond) or groupPass)
		if g.gameDrawn and not unlocked then
			if slots then
				visible[#visible + 1] = { t = t, entry = entry, expiring = false, slots = slots }
			elseif show then
				visible[#visible + 1] = { t = t, entry = entry, expiring = expiring }
			end
		elseif show then
			visible[#visible + 1] = { t = t, entry = entry, expiring = expiring }
		end
	end
	if g.gameDrawn and not unlocked then
		if not ManagerUnsafe() then
			-- Out of a fight a plain row or a bar list closes up: a tracker the game draws whose aura is
			-- not there goes to the end, its slot still on for the game to fill in a fight.
			if not (g.shaped and g.style ~= "bars") then
				local up, gaps = {}, {}
				for _, it in ipairs(visible) do
					if it.slots and it.t.show == "active" and it.entry == nil then gaps[#gaps + 1] = it else up[#up + 1] = it end
				end
				for _, it in ipairs(gaps) do up[#up + 1] = it end
				visible = up
			end
			-- The order is held through a fight only where the game draws something to hold it for.
			f.safeOrder = nil
			for _, it in ipairs(visible) do if it.slots then f.safeOrder = {} break end end
			if f.safeOrder then for i, it in ipairs(visible) do f.safeOrder[i] = it.t end end
		elseif f.safeOrder then
			visible = HeldOrder(f, visible)
		end
	else
		f.safeOrder = nil
	end
	LayoutGroup(f, g, visible, unlocked)
end

function Display:Refresh()
	if not ready then return end
	for _, g in ipairs(ns.profile.groups) do self:RefreshGroup(g) end
	self:Tick(GetTime())
end

-- Just the drawing: the fill, the spark and the time on whatever is already on screen. Cheap
-- enough to run every frame, which is what makes a draining bar move smoothly rather than in
-- tenth-of-a-second steps.
function Display:Draw(now)
	if not ready then return end
	for _, f in pairs(active) do
		if f.group and f:IsShown() then
			for _, w in ipairs(f.widgets) do
				if w:IsShown() then TickWidget(w, f.group, now) end
			end
		end
	end
end

-- Deciding what should be on screen, which is the part worth doing only now and then.
function Display:Tick(now)
	if not ready then return end
	local unlocked = self:IsUnlocked()
	for _, f in pairs(active) do
		local g = f.group
		-- A group that watches your party has no timers of the addon's own: the game draws them all.
		if g and not ns.GroupUnits(g) then
			-- A warn window opens with no event, and so does a cooldown starting or coming back, so
			-- trackers that watch either are re-checked each tick.
			if not unlocked then
				local groupPass = ns.CondPass(g.cond)
				for _, t in ipairs(g.trackers) do
					local slotted = false
					if not t.cd then
						for _, w in ipairs(f.widgets) do if w.tracker == t and w.underSlot then slotted = true break end end
					end
					if ((t.warn or 0) > 0 or t.cd or t.enchant ~= nil or t.swing ~= nil) and not slotted then
						local entry = ns.Find(t)
						local want, expiring = Wants(t, entry, now, false, groupPass)
						local shown, wasExpiring, was = false, false, nil
						for _, w in ipairs(f.widgets) do
							if w:IsShown() and w.tracker == t then shown, wasExpiring, was = true, w.expiring or false, w.entry break end
						end
						-- A tracker that is on screen either way only changes by its time changing.
						local restarted = false
						if (t.cd or t.enchant ~= nil or t.swing ~= nil) and shown then
							restarted = abs((was and was.expires or -1) - (entry and entry.expires or -1)) > 0.25
								or EntryState(was) ~= EntryState(entry)
						end
						if want ~= shown or expiring ~= wasExpiring or restarted then self:RefreshGroup(g) break end
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
	-- Every way arranging ends (Done, the minimap, the slash command, the window closing) comes
	-- through here, before a group still being held can be hidden.
	if not self:IsUnlocked() and self.EndGroupDrags then self:EndGroupDrags() end
	local wanted = {}
	for _, g in ipairs(ns.profile.groups) do wanted[g.uid] = g end
	for uid, f in pairs(active) do
		if not wanted[uid] and f.slotC and next(f.slotC) and ManagerUnsafe() then
			-- The game's containers inside it may not be hidden from here in a fight: it goes after it.
			active[uid] = nil
			Display.dropAfterCombat = Display.dropAfterCombat or {}
			Display.dropAfterCombat[f] = true
			-- Out of sight until then; alpha is not a show or a hide, so the game's containers are left alone.
			f:SetAlpha(0)
		elseif not wanted[uid] then
			f:Hide()
			-- A group taken away mid-drag must not carry the drag into the group this frame is used
			-- for next.
			if f.moving then
				f.moving, f.dragFrom, f.dragL, f.dragT = false, nil, nil, nil
				f:SetScript("OnUpdate", nil)
				if Display.ShowGuides then Display.ShowGuides(nil, nil) end
			end
			f.group = nil
			ReleaseMembers(f)
			if f.slotC then
				for _, c in pairs(f.slotC) do
					DriverOff(c)
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
		if f.members then f.members.dirty = true end
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
	local function hit(f, pad, padTop)
		local s = f:GetScale() or 1
		local l, r = f:GetLeft() * s - pad, f:GetRight() * s + pad
		local b, t = f:GetBottom() * s - pad, f:GetTop() * s + padTop
		return cx >= l and cx <= r and cy >= b and cy <= t
	end
	for _, f in pairs(active) do
		local g = f.group
		if g and g ~= except and f:IsShown() and f:GetLeft() and hit(f, 8, 22) then return g, f end
	end
	-- An icon held against the outside of a group is being offered to that group, so a group of
	-- icons reaches about one cell further out than its own edge.
	for _, f in pairs(active) do
		local g = f.group
		if g and g ~= except and g.style ~= "bars" and f:IsShown() and f:GetLeft() then
			local pad = ((g.size or 40) + (g.spacing or 4)) * 0.8
			if hit(f, pad, max(22, pad)) then return g, f end
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

-- The cell a dragged icon is being held against: the nearest icon in the group, and the free side
-- of it the cursor is on. Returns nothing for a group of bars, for a side that is already taken,
-- and when the cursor is sitting squarely on an icon rather than against one of its sides.
function Display:DropCell(f, g, cx, cy, dragged)
	if not f or not g or g.style == "bars" or ns.GroupUnits(g) then return end
	-- A group saved by an older version has no shape until something changes it.
	if ns.FitCells then ns.FitCells(g) end
	local axis = AXIS[FLOW[g.grow or "RIGHT"] or g.grow or "RIGHT"]
	if not axis then return end
	local s = f:GetScale() or 1
	local best, bestDist, bestW
	for _, w in ipairs(f.widgets) do
		if w:IsShown() and w.tracker and w.cellC then
			local wx, wy = w:GetCenter()
			if wx then
				wx, wy = wx * s, wy * s
				local dist = (wx - cx) ^ 2 + (wy - cy) ^ 2
				if not bestDist or dist < bestDist then best, bestDist, bestW = { x = wx, y = wy }, dist, w end
			end
		end
	end
	if not best then return end
	local ox, oy = cx - best.x, cy - best.y
	-- Squarely on an icon is not held against a side of it; that is an ordinary drop. The middle
	-- third is what counts as squarely: half the icon would swallow the seam between two that are
	-- touching, which is exactly where somebody aims to slot one in between them.
	local reach = max(4, ((g.size or 40) * s) * 0.3)
	if abs(ox) < reach and abs(oy) < reach then return end
	local sx, sy = 0, 0
	if abs(ox) > abs(oy) then sx = (ox > 0) and 1 or -1 else sy = (oy > 0) and 1 or -1 end
	local dc = sx * axis.c[1] + sy * axis.c[2]
	local dr = sx * axis.r[1] + sy * axis.r[2]
	local c, r = bestW.cellC + dc, bestW.cellR + dr
	-- A side with an icon already on it is a seam, and a seam is a place to open. The place that
	-- opens is the one on the far side of the seam: below the icon it is the next line down, above
	-- it, the icon's own line, which everything from there on then moves out of.
	if not ns.CellFree(g, c, r, dragged) then
		local ic = (dc < 0) and bestW.cellC or c
		local ir = (dr < 0) and bestW.cellR or r
		return ic, ir, bestW, sx, sy, (dr ~= 0) and "row" or "col"
	end
	return c, r, bestW, sx, sy
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
-- The mark that says where a dragged icon would settle: a bright spark laid along the edge it is
-- being held against, the way the cast bar wears one. It is put against the icon itself rather
-- than the empty cell, because the edge is what the drop is really about.
-- ------------------------------------------------------------------
-- The alignment grid, and lining things up while arranging
-- ------------------------------------------------------------------
-- Everything here is in UIParent units: a frame's own position is multiplied by how much bigger it
-- is drawn than UIParent, so a group at 150% scale lines up by where it actually is on screen.
local GRID_SIZES = { 8, 12, 16, 20, 24, 32, 40, 48, 64, 80, 96, 128 }
local GRID_MAJOR = 4          -- every fourth line is drawn stronger, to count distance by
local ALIGN_DIST = 6          -- how close an edge or middle has to come to line up with another
local GRID_COLORS = {
	center = { 1, 0.35, 0.2, 0.9 },     -- the cross through the middle of the screen
	major = { 1, 0.82, 0, 0.45 },       -- every fourth line
	minor = { 1, 1, 1, 0.12 },          -- the rest
}

local function UIScaleOf(obj)
	local ue = UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or 1
	if not ue or ue == 0 then ue = 1 end
	local oe = obj.GetEffectiveScale and obj:GetEffectiveScale() or 1
	return (oe or 1) / ue
end

-- Where something is, as left, right, top and bottom in UIParent units.
local function BoxOf(obj)
	if not obj or not obj.GetLeft then return nil end
	local l, r, t, b = obj:GetLeft(), obj:GetRight(), obj:GetTop(), obj:GetBottom()
	if not (l and r and t and b) then return nil end
	local k = UIScaleOf(obj)
	return { l = l * k, r = r * k, t = t * k, b = b * k }
end
Display.BoxOf = BoxOf

function Display:GridSize()
	local want = tonumber(ns.db and ns.db.gridSize) or 32
	for _, s in ipairs(GRID_SIZES) do if s == want then return s end end
	return 32
end

-- One step bigger or smaller, along the sizes offered.
function Display:StepGridSize(dir)
	local now = self:GridSize()
	local at = 1
	for i, s in ipairs(GRID_SIZES) do if s == now then at = i end end
	at = max(1, min(#GRID_SIZES, at + dir))
	ns.db.gridSize = GRID_SIZES[at]
	self:SyncGrid()
	return ns.db.gridSize
end

-- Snapping, and lining up with other trackers, happen only while the grid is up in edit mode, and
-- never while Alt is held.
function Display:SnapActive()
	if not (ns.db and ns.db.unlocked and ns.db.gridOn) then return false end
	if IsAltKeyDown and IsAltKeyDown() then return false end
	return true
end

local gridFrame
local function GetGrid()
	if gridFrame then return gridFrame end
	local gf = CreateFrame("Frame", "AuraLedgerGrid", UIParent)
	gf:SetAllPoints(UIParent)
	gf:SetFrameStrata("BACKGROUND")
	gf:EnableMouse(false)
	gf.lines = {}
	gf:Hide()
	-- A different screen size moves the middle, so the lines are laid out again.
	gf:SetScript("OnSizeChanged", function(self) if self:IsShown() then Display:DrawGrid() end end)
	gridFrame = gf
	return gf
end

function Display:DrawGrid()
	local gf = GetGrid()
	local W, H = UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
	if W <= 0 or H <= 0 then return end
	local size = self:GridSize()
	local cx, cy = W / 2, H / 2
	local used = 0
	local function Line(vertical, pos, kind)
		used = used + 1
		local tex = gf.lines[used]
		if not tex then
			tex = gf:CreateTexture(nil, "BACKGROUND")
			gf.lines[used] = tex
		end
		local c = GRID_COLORS[kind]
		tex:SetColorTexture(c[1], c[2], c[3], c[4])
		tex:ClearAllPoints()
		local thick = (kind == "center") and 2 or 1
		if vertical then
			tex:SetPoint("BOTTOM", gf, "BOTTOMLEFT", pos, 0)
			tex:SetSize(thick, H)
		else
			tex:SetPoint("LEFT", gf, "BOTTOMLEFT", 0, pos)
			tex:SetSize(W, thick)
		end
		tex.kind, tex.vertical, tex.pos = kind, vertical, pos
		tex:Show()
	end
	-- Measured out from the middle, so the centre cross always falls on a line.
	local nx, ny = floor(cx / size), floor(cy / size)
	for i = -nx, nx do
		Line(true, cx + i * size, (i == 0) and "center" or ((i % GRID_MAJOR == 0) and "major" or "minor"))
	end
	for i = -ny, ny do
		Line(false, cy + i * size, (i == 0) and "center" or ((i % GRID_MAJOR == 0) and "major" or "minor"))
	end
	for i = used + 1, #gf.lines do gf.lines[i]:Hide() end
	gf.used = used
end

-- The lines drawn while something lines up with something else, right across the screen.
local guides
local function ShowGuides(gx, gy)
	if not gx and not gy then
		if guides then guides:Hide() end
		return
	end
	if not guides then
		guides = CreateFrame("Frame", nil, UIParent)
		guides:SetAllPoints(UIParent)
		guides:SetFrameStrata("TOOLTIP")
		guides:EnableMouse(false)
		guides.v = guides:CreateTexture(nil, "OVERLAY")
		guides.h = guides:CreateTexture(nil, "OVERLAY")
		guides.v:SetColorTexture(1, 0.35, 1, 0.9)
		guides.h:SetColorTexture(1, 0.35, 1, 0.9)
	end
	local W, H = UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
	if gx then
		guides.v:ClearAllPoints()
		guides.v:SetPoint("BOTTOM", guides, "BOTTOMLEFT", gx, 0)
		guides.v:SetSize(1, H)
		guides.v:Show()
	else
		guides.v:Hide()
	end
	if gy then
		guides.h:ClearAllPoints()
		guides.h:SetPoint("LEFT", guides, "BOTTOMLEFT", 0, gy)
		guides.h:SetSize(W, 1)
		guides.h:Show()
	else
		guides.h:Hide()
	end
	guides.gx, guides.gy = gx, gy
	guides:Show()
end
Display.ShowGuides = ShowGuides
function Display:Guides() return guides end

function Display:SyncGrid()
	local on = ns.db and ns.db.unlocked and ns.db.gridOn
	local gf = GetGrid()
	if on then
		self:DrawGrid()
		gf:Show()
	else
		gf:Hide()
		ShowGuides(nil, nil)
	end
end
function Display:GridFrame() return gridFrame end

-- How close a box's middle has to come to the middle of the screen to be put there: half a grid
-- step, so the lines either side of the centre keep their own share, and never more than this.
local CENTRE_MAX = 12
-- How far apart the other way a tracker inside a group can be and still offer its middle to line up
-- with. A group's outline counts from anywhere; the trackers inside groups far away would only be a
-- dense row of magnets.
local NEAR_DIST = 160

-- What there is to line up with, in the order the groups are listed, so that a tie always breaks the
-- same way: every other group's outline, marked whole, and every tracker in it. What is being dragged
-- is left out, so it never lines up with itself.
function Display:AlignTargets(ignoreGroup, ignoreWidget)
	local out = {}
	if not ns.profile then return out end
	for _, g in ipairs(ns.profile.groups) do
		local f = active[g.uid]
		if f and g ~= ignoreGroup and f:IsShown() then
			local fb = BoxOf(f)
			if fb then
				fb.whole = true
				out[#out + 1] = fb
			end
			for _, w in ipairs(f.widgets or {}) do
				if w ~= ignoreWidget and w:IsShown() and w.tracker then
					local wb = BoxOf(w)
					if wb then out[#out + 1] = wb end
				end
			end
		end
	end
	return out
end

local function NearestLine(v, origin, size)
	return origin + floor((v - origin) / size + 0.5) * size
end

-- How far apart two spans are, or 0 when they overlap.
local function SpanGap(lo1, hi1, lo2, hi2)
	if lo2 > hi1 then return lo2 - hi1 end
	if lo1 > hi2 then return lo1 - hi2 end
	return 0
end

-- Everything a box could line up with one way across the screen: one of its points and a line, like
-- with like, an edge with an edge and the middle with a middle. a and z are its edges this way, lo
-- and hi its extent the other way, and ka, kz, klo, khi name the same sides on a target. The
-- middle of the screen is offered to the edges here; the middle has a rule of its own.
local function Pairs(a, z, lo, hi, targets, ka, kz, klo, khi, c)
	local m = (a + z) / 2
	local out = {}
	local function Add(p, line, gap, kind, centred)
		out[#out + 1] = { d = line - p, line = line, gap = gap, kind = kind, centred = centred }
	end
	Add(a, c, -1, "centre")
	Add(z, c, -1, "centre")
	for _, tb in ipairs(targets) do
		local gap = SpanGap(lo, hi, tb[klo], tb[khi])
		local ta, tz = tb[ka], tb[kz]
		local tm = (ta + tz) / 2
		if tb.whole then
			local centred = abs(tm - c) < 0.01
			Add(a, ta, gap, "edge", centred)
			Add(a, tz, gap, "edge", centred)
			Add(m, tm, gap, "middle", centred)
			Add(z, ta, gap, "edge", centred)
			Add(z, tz, gap, "edge", centred)
		elseif gap <= NEAR_DIST then
			Add(m, tm, gap, "middle", false)
		end
	end
	return out, m
end

-- One way across the screen. Returns the nudge and where the guide goes, either of them nil for none.
-- reach is how close the middle has to come to the centre c, edgeReach how close an edge has to come
-- to it, and size the grid step, or nil with Snap to grid off.
local function SnapAxis(a, z, lo, hi, targets, ka, kz, klo, khi, c, reach, edgeReach, size)
	local pairs_, m = Pairs(a, z, lo, hi, targets, ka, kz, klo, khi, c)
	-- A line that is not the centre but sits within CENTRE_MAX of it is left out, at every grid size:
	-- all it could do is put a guide a few units beside the red one, which is what looked broken. The
	-- edges of a neighbour that is itself centred are kept, since they are where that neighbour is.
	local function Allowed(pr)
		if pr.kind == "centre" or pr.centred then return true end
		local off = abs(pr.line - c)
		return off < 0.01 or off > CENTRE_MAX
	end
	local toCentre = c - m
	-- Where something that belongs to the centre goes: its middle on the centre, or an edge of a
	-- centred neighbour, whichever is the nearer landing, as long as the middle stays within reach.
	-- Choosing the nearest of the two, rather than letting one win within some distance, is what
	-- keeps it from going backwards as the cursor goes forwards.
	local function Centre()
		local best, at = toCentre, c
		for _, pr in ipairs(pairs_) do
			if pr.centred and pr.kind == "edge" and abs(m + pr.d - c) <= reach and abs(pr.d) < abs(best) then
				best, at = pr.d, pr.line
			end
		end
		return best, at
	end
	-- Whether a nudge would leave the middle within reach of the centre, without being on it.
	local function NearCentre(nudge)
		local off = abs(m + nudge - c)
		return off > 0.01 and off <= reach
	end

	-- 1. The middle near the middle of the screen goes there, ahead of everything else.
	if abs(toCentre) <= reach then return Centre() end

	-- 2. Lining up, the nearest first. On a tie the middle of the screen, then whatever sits nearer
	--    the other way, then whichever was found first. Lining up that would leave the middle within
	--    reach of the centre goes to the centre instead, unless it is lining up with a centred
	--    neighbour, which is how a bar is topped off level with one.
	local near, nearAt, nearPr
	for _, pr in ipairs(pairs_) do
		local limit = (pr.kind == "centre") and edgeReach or ALIGN_DIST
		if Allowed(pr) and abs(pr.d) <= limit then
			local better = (near == nil) or abs(pr.d) < abs(near)
			if not better and abs(pr.d) == abs(near) and nearPr.kind ~= "centre"
				and (pr.kind == "centre" or pr.gap < nearPr.gap) then
				better = true
			end
			if better then near, nearAt, nearPr = pr.d, pr.line, pr end
		end
	end
	if near then
		if not nearPr.centred and NearCentre(near) then return Centre() end
		return near, nearAt
	end
	if not size then return nil end

	-- 3. The grid: the nearest line, by whichever of the edges or the middle is closest to one.
	local grid
	for _, p in ipairs({ a, m, z }) do
		local dd = NearestLine(p, c, size) - p
		if not grid or abs(dd) < abs(grid) then grid = dd end
	end
	-- It never carries the box across a line it could line up with, or a box would jump backwards as
	-- the cursor moved forwards: it stops at the first such line on the way instead.
	local guide, stopPr
	if grid ~= 0 then
		for _, pr in ipairs(pairs_) do
			if Allowed(pr) and pr.d ~= 0 and (pr.d > 0) == (grid > 0) and abs(pr.d) < abs(grid) then
				grid, guide, stopPr = pr.d, pr.line, pr
			end
		end
	end
	-- A landing, stopped or not, that leaves the middle within reach of the centre goes to the centre;
	-- only a stop at a centred neighbour keeps its place.
	if not (stopPr and stopPr.centred) and NearCentre(grid) then return Centre() end
	local after = m + grid - c
	-- A landing on the centre line says so, as lining up does.
	if not guide and (abs(a + grid - c) < 0.01 or abs(after) < 0.01 or abs(z + grid - c) < 0.01) then guide = c end
	return grid, guide
end

-- How far to nudge a box so it lines up, each way on its own, and where the guide lines go. The
-- middle of the screen and lining up with other trackers still happen with Snap to grid off, since
-- neither is a grid step; only Alt, or the grid being down, turns everything off.
function Display:SnapBox(box, ignoreGroup, ignoreWidget)
	if not self:SnapActive() or not box then return 0, 0 end
	local W, H = UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
	local step = self:GridSize()
	local reach = min(CENTRE_MAX, step / 2)
	local edgeReach = min(ALIGN_DIST, step / 2)
	local size = (ns.db.gridSnap ~= false) and step or nil
	local targets = self:AlignTargets(ignoreGroup, ignoreWidget)
	local dx, gx = SnapAxis(box.l, box.r, box.b, box.t, targets, "l", "r", "b", "t", W / 2, reach, edgeReach, size)
	local dy, gy = SnapAxis(box.t, box.b, box.l, box.r, targets, "t", "b", "l", "r", H / 2, reach, edgeReach, size)
	return dx or 0, dy or 0, gx, gy
end

-- Puts a group with its top left corner at a spot, whichever corner the group actually grows from.
function Display:PlaceGroupTopLeft(g, l, t)
	if not g or not l or not t then return end
	local f = active[g.uid]
	local k = f and UIScaleOf(f) or (g.scale or 1)
	local w = f and (f:GetWidth() or 0) * k or 0
	local h = f and (f:GetHeight() or 0) * k or 0
	local a = ANCHOR[g.grow] or "TOPLEFT"
	g.x = (a == "TOPRIGHT") and (l + w) or ((a == "TOP") and (l + w / 2) or l)
	g.y = (a == "BOTTOMLEFT") and (t - h) or ((a == "LEFT") and (t - h / 2) or t)
	if f then ApplyPosition(f, g) end
end

-- The outline of where a tracker dropped in the open would land.
local landMark
local function ShowLanding(l, t, w, h)
	if not l then
		if landMark then landMark:Hide() end
		return
	end
	if not landMark then
		landMark = CreateFrame("Frame", nil, UIParent)
		landMark:SetFrameStrata("TOOLTIP")
		landMark:EnableMouse(false)
		landMark.edges = {}
		for i = 1, 4 do
			local e = landMark:CreateTexture(nil, "OVERLAY")
			e:SetColorTexture(0.35, 1, 0.5, 0.9)
			landMark.edges[i] = e
		end
		local et, eb, el, er = landMark.edges[1], landMark.edges[2], landMark.edges[3], landMark.edges[4]
		et:SetPoint("TOPLEFT") et:SetPoint("TOPRIGHT") et:SetHeight(1)
		eb:SetPoint("BOTTOMLEFT") eb:SetPoint("BOTTOMRIGHT") eb:SetHeight(1)
		el:SetPoint("TOPLEFT") el:SetPoint("BOTTOMLEFT") el:SetWidth(1)
		er:SetPoint("TOPRIGHT") er:SetPoint("BOTTOMRIGHT") er:SetWidth(1)
	end
	landMark:ClearAllPoints()
	landMark:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
	landMark:SetSize(w, h)
	landMark:Show()
end

-- Where a tracker dropped in the open would land, lined up, or nothing if there is no lining up
-- to be done. It is centred on the cursor before it is lined up.
function Display:GhostLanding(cx, cy)
	if not self:SnapActive() then return nil end
	local gh = self.GetGhostFrame and self:GetGhostFrame()
	local w, h = (gh and gh.boxW) or 40, (gh and gh.boxH) or 40
	local l, t = cx - w / 2, cy + h / 2
	if gh and gh.offX then l, t = cx - gh.offX, cy + gh.offY end
	local dx, dy, gx, gy = self:SnapBox({ l = l, r = l + w, t = t, b = t - h }, gh and gh.ignoreGroup, gh and gh.ignoreWidget)
	return l + dx, t + dy, w, h, gx, gy
end

local dropMark
local function GetDropMark()
	if dropMark then return dropMark end
	local mark = CreateFrame("Frame", nil, UIParent)
	mark:SetFrameStrata("HIGH")
	local spark = mark:CreateTexture(nil, "OVERLAY")
	spark:SetAllPoints()
	spark:SetBlendMode("ADD")
	-- The cast bar's own spark if this client draws it, the manager's bar pip if not, and a plain
	-- bright line as a last resort. No art on this client can be taken on trust.
	local art = "plain line"
	if HasAtlas("UI-HUD-CoolDownManager-Bar-Pip") and spark.SetAtlas then
		spark:SetAtlas("UI-HUD-CoolDownManager-Bar-Pip")
		art = "cooldown manager pip"
	else
		spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
		if spark:GetTexture() then art = "casting bar spark" else spark:SetColorTexture(1, 0.95, 0.4, 0.9) end
	end
	spark:SetVertexColor(1, 0.95, 0.45)
	ns.report["drop mark art"] = art
	mark.spark = spark
	mark:Hide()
	dropMark = mark
	return mark
end

local function ShowDropMark(f, g, against, sx, sy, between)
	if not f or not against then
		if dropMark then dropMark:Hide() end
		return
	end
	local mark = GetDropMark()
	mark:SetParent(f)
	mark:SetFrameStrata("HIGH")
	local size = g.size or 40
	-- As long as the edge it marks, and thin across it. It is never turned: a texture turned inside
	-- its own bounds is drawn in the turned shape and then clipped to the box, which left a sliver
	-- down the middle of a wide one rather than a line along the edge.
	local thick = max(6, size * 0.22)
	local along = size + 2
	mark:ClearAllPoints()
	if sx ~= 0 then
		mark:SetSize(thick, along)
		mark:SetPoint("CENTER", against, sx > 0 and "RIGHT" or "LEFT", 0, 0)
	else
		mark:SetSize(along, thick)
		mark:SetPoint("CENTER", against, sy > 0 and "TOP" or "BOTTOM", 0, 0)
	end
	-- Slotting in between reads differently from hanging one on a free side.
	mark.spark:SetVertexColor(1, 0.95, 0.45)
	mark.spark:SetAlpha(between and 1 or 0.9)
	mark:Show()
end
Display.ShowDropMark = ShowDropMark

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
		local cellC, cellR, against, sx, sy, axis
		if g and not overWindow then cellC, cellR, against, sx, sy, axis = Display:DropCell(f, g, cx, cy, self.dragTracker) end
		ShowDropMark(cellC and f or nil, g, against, sx or 0, sy or 0, axis)
		-- Over empty space while the grid is up: where it would land, lined up, and what with.
		if not g and not overWindow then
			local l, t, w, h, gx, gy = Display:GhostLanding(cx, cy)
			ShowLanding(l, t, w, h)
			ShowGuides(gx, gy)
		else
			ShowLanding(nil)
			ShowGuides(nil, nil)
		end
		if overWindow then
			-- Over the window, the list knows best what a drop would do.
			local label = ns.UI and ns.UI.TreeDropLabel and ns.UI:TreeDropLabel(cy, self.dragTracker)
			self.text:SetText(label or self.windowText or "|cffff6060Cancel|r")
		elseif cellC then
			local name = against and against.tracker and (against.tracker.name or ("spell " .. tostring(against.tracker.id)))
			if axis == "row" then
				self.text:SetText("|cff40ff60Open a new row here|r")
			elseif axis == "col" then
				self.text:SetText("|cff40ff60Make room beside " .. (name or ns.GroupName(g)) .. "|r")
			else
				self.text:SetText("|cff40ff60Attach to " .. (name or ns.GroupName(g)) .. "|r")
			end
		elseif g then self.text:SetText("|cff40ff60Add to " .. ns.GroupName(g) .. "|r")
		else self.text:SetText(self.freeText or "Place here") end
	end)
	return ghost
end

-- Is something on the cursor? Anything that would draw over the screen asks first.
function Display:Dragging()
	if ghost ~= nil and ghost:IsShown() then return true end
	-- A group moved by its plate is being dragged just as much as a tracker on the cursor is.
	for _, f in pairs(active) do
		if f.moving and f:IsShown() then return true end
	end
	return false
end

function Display:GetGhostFrame() return GetGhost() end

-- The widget on screen for a tracker, and its group, if it is showing.
function Display:WidgetFor(t)
	local g = t and ns.FindGroupOf(t)
	local f = g and active[g.uid]
	if not f then return nil end
	for _, w in ipairs(f.widgets or {}) do
		if w.tracker == t and w:IsShown() then return w, g end
	end
	return nil
end

-- What is being dragged, so a landing can be the right size and it does not line up with itself.
function Display:SetGhostSource(w, g, whole)
	local gh = GetGhost()
	local box = BoxOf(w)
	if box then gh.boxW, gh.boxH = box.r - box.l, box.t - box.b end
	gh.ignoreWidget = w
	gh.ignoreGroup = (g and (whole or #g.trackers == 1)) and g or nil
	-- The whole group on the cursor: the group is what lands, so the landing is its own outline, held
	-- where it sits around the tracker being dragged, and it does not line up with where it was.
	gh.offX, gh.offY = nil, nil
	local f = whole and g and active[g.uid]
	local fb = f and BoxOf(f)
	if box and fb then
		gh.boxW, gh.boxH = fb.r - fb.l, fb.t - fb.b
		gh.offX, gh.offY = (box.l + box.r) / 2 - fb.l, fb.t - (box.t + box.b) / 2
	end
end

function Display:BeginGhost(icon, freeText, except, windowText, dragTracker)
	local gh = GetGhost()
	gh.boxW, gh.boxH, gh.ignoreWidget, gh.ignoreGroup, gh.offX, gh.offY = nil, nil, nil, nil, nil, nil
	-- Whatever was being hovered when the drag started goes away with it.
	GameTooltip:Hide()
	gh.icon:SetTexture(icon or QUESTION)
	gh.freeText, gh.except, gh.windowText, gh.dragTracker = freeText, except, windowText, dragTracker
	gh:Show()
end

-- Ends the drag. Returns cancelled, cursorX, cursorY, targetGroup, insertIndex, cellC, cellR, axis,
-- and, for a drop in the open while the grid is up, the top left corner it should land at.
function Display:EndGhost()
	local gh = GetGhost()
	gh:Hide()
	ShowDropMark(nil)
	ShowLanding(nil)
	ShowGuides(nil, nil)
	Highlight(nil)
	local cx, cy = CursorUI()
	if ns.UI and ns.UI.frame and ns.UI.frame:IsShown() and ns.UI.frame:IsMouseOver() then return true, cx, cy end
	local g, f = self:GroupAt(cx, cy, gh.except)
	if g then
		local c, r, _, _, _, axis = self:DropCell(f, g, cx, cy, gh.dragTracker)
		return false, cx, cy, g, self:InsertIndex(f, g, cx, cy), c, r, axis
	end
	local landL, landT = self:GhostLanding(cx, cy)
	return false, cx, cy, nil, nil, nil, nil, nil, landL, landT
end

-- ------------------------------------------------------------------
-- Dragging groups and trackers
-- ------------------------------------------------------------------
-- A group is moved by hand rather than by the client's StartMoving, which gives no chance to
-- correct the position while it is dragged, and correcting it is what lining up is.
function Display:GroupDragStart(f)
	local g = f.group
	if not g or not self:IsUnlocked() then return end
	-- The game's containers ride on it, and are not moved in a fight.
	if ns.GroupUnits(g) and ManagerUnsafe() then
		ns.Print("A group that watches your party can be moved " .. ns.WhenFreeWords() .. ".")
		return
	end
	f.moving = true
	-- Whatever was being hovered when the drag started goes away with it.
	GameTooltip:Hide()
	local cx, cy = CursorUI()
	local box = BoxOf(f)
	f.dragFrom = { cx = cx, cy = cy, l = box and box.l or cx, t = box and box.t or cy }
	f.dragL, f.dragT = nil, nil
	f:SetScript("OnUpdate", function() Display:GroupDragUpdate(f) end)
end

function Display:GroupDragUpdate(f)
	local g, from = f.group, f.dragFrom
	if not g or not from then return end
	-- Arranging ended under the drag: let it go where it is. It is not a drop, so a lone tracker is
	-- not put into whatever group happens to be under the cursor.
	if not self:IsUnlocked() then self:EndGroupDrags() return end
	local cx, cy = CursorUI()
	local k = UIScaleOf(f)
	local w, h = (f:GetWidth() or 0) * k, (f:GetHeight() or 0) * k
	local l = from.l + (cx - from.cx)
	local t = from.t + (cy - from.cy)
	local dx, dy, gx, gy = self:SnapBox({ l = l, r = l + w, t = t, b = t - h }, g)
	l, t = l + dx, t + dy
	f:ClearAllPoints()
	f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l / k, t / k)
	f.dragL, f.dragT = l, t
	ShowGuides(gx, gy)
	if #g.trackers == 1 then
		-- A lone tracker can be dropped onto another group to join it.
		local _, target = self:GroupAt(cx, cy, g)
		Highlight(target)
	end
end

function Display:GroupDragStop(f)
	local g = f.group
	if not f.moving then return end
	f.moving = false
	f:SetScript("OnUpdate", nil)
	if f.SetUserPlaced then f:SetUserPlaced(false) end
	Highlight(nil)
	ShowGuides(nil, nil)
	local l, t = f.dragL, f.dragT
	f.dragFrom, f.dragL, f.dragT = nil, nil, nil
	if not g then return end
	if #g.trackers == 1 then
		local cx, cy = CursorUI()
		local target, tf = self:GroupAt(cx, cy, g)
		if target then
			ns.MoveTracker(g.trackers[1], target, self:InsertIndex(tf, target, cx, cy))
			return
		end
	end
	if l then
		self:PlaceGroupTopLeft(g, l, t)
	else
		SavePosition(f, g)
		ApplyPosition(f, g)
	end
end

-- Arranging is over while a plate is still held. A group hidden by that gets no OnUpdate and its
-- plate no OnDragStop, so nothing else would ever end the drag: it is let go here, where the group
-- was last put, and never dropped into another group, since the drop was never made.
function Display:EndGroupDrags()
	local ended = false
	for _, f in pairs(active) do
		if f.moving then
			local g, l, t = f.group, f.dragL, f.dragT
			f.moving, f.dragFrom, f.dragL, f.dragT = false, nil, nil, nil
			f:SetScript("OnUpdate", nil)
			if g and l then self:PlaceGroupTopLeft(g, l, t) end
			ended = true
		end
	end
	if ended then
		Highlight(nil)
		ShowGuides(nil, nil)
	end
end

-- Things that had to wait for a fight to end: a skin made without the manager is made again, and a
-- group removed in the fight gives up its containers.
-- ------------------------------------------------------------------
-- Your target. The game never reads one of its aura displays again when your target changes: its
-- own code leaves that to the display's owner ("e.g. target changes"), and its own target frame does
-- it on every change. Each of a display's own calls runs in the game's secure code, so the addon can
-- make them in a fight too. Three things are done on every change of target, and each can be
-- switched off to find out which one this client needs (/auraledger debug target method):
--   read: UpdateAllAuras, which is all the game's own target frame does;
--   bounce: pointing the display at nothing and back, which also renews what it listens for;
--   re-arm: a display marks itself unread and arms one read, but only on the change from read to
--   unread, so one left unread by a read that failed half way would never read again. Its update
--   mode says so (off while still unread), and setting the mode arms it once more.
-- ------------------------------------------------------------------
do
	local stats = { changes = 0, inFight = 0, reads = 0, readFailed = 0, bounces = 0, bounceFailed = 0, rearmed = 0, rearmFailed = 0, blocked = 0 }
	local log = {}
	Display.targetStats = stats
	local METHODS = { all = true, read = true, bounce = true, rearm = true, none = true }
	local function Method()
		local m = ns.db and ns.db.targetRefresh
		return METHODS[m or ""] and m or "all"
	end
	local function BlockedCount()
		local n = 0
		for _, k in pairs(ns.blocked or {}) do n = n + k end
		return n
	end
	local function ReadAgain(c, why)
		local method = Method()
		local rec = { at = GetTime(), why = why, fight = (InCombatLockdown and InCombatLockdown()) and true or false, secret = ns.AurasSecret() }
		local before = BlockedCount()
		if method == "all" or method == "read" then
			rec.read = pcall(c.UpdateAllAuras, c)
			if rec.read then stats.reads = stats.reads + 1 else stats.readFailed = stats.readFailed + 1 end
		end
		if method == "all" or method == "bounce" then
			rec.bounce = pcall(c.SetUnit, c, "none") and pcall(c.SetUnit, c, "target") or false
			if rec.bounce then stats.bounces = stats.bounces + 1 else stats.bounceFailed = stats.bounceFailed + 1 end
		end
		if (method == "all" or method == "rearm") and c.GetOnUpdateMode then
			local modes = Enum and Enum.OnUpdateMode
			local off, once = modes and modes.Disabled or 0, modes and modes.RunWhenVisibleOnce or 2
			local ok, mode = pcall(c.GetOnUpdateMode, c)
			mode = ok and ns.Clean(mode) or nil
			rec.mode = mode
			if mode == off and c.SetOnUpdateMode then
				rec.rearm = pcall(c.SetOnUpdateMode, c, once)
				if rec.rearm then stats.rearmed = stats.rearmed + 1 else stats.rearmFailed = stats.rearmFailed + 1 end
			end
		end
		rec.blocked = BlockedCount() - before
		stats.blocked = stats.blocked + rec.blocked
		table.insert(log, 1, rec)
		if #log > 20 then table.remove(log) end
	end
	local function Each(why)
		local n = 0
		for _, f in pairs(active) do
			local c = f.slotC and f.slotC.target
			if c and c.alMacro ~= "parked" then
				ReadAgain(c, why)
				n = n + 1
			end
		end
		return n
	end
	function Display:TargetChanged()
		stats.changes = stats.changes + 1
		if InCombatLockdown and InCombatLockdown() then stats.inFight = stats.inFight + 1 end
		Each("new target")
	end
	-- After a fight every display of your target is read again: what happened in it is not trusted.
	function Display.RefreshTargets(why) return Each(why or "asked") end

	-- /auraledger debug target: how the reads on a change of target went, and which of them to make.
	function Display:TargetReport(emit, rest)
		local verb, arg = string.lower(rest or ""):match("^(%S*)%s*(%S*)")
		if verb == "method" then
			if METHODS[arg] then
				ns.db.targetRefresh = (arg ~= "all") and arg or nil
				emit("On a change of target the addon now does: " .. (arg == "all" and "the read, the bounce and the re-arm" or arg) .. ". Back to all three: /auraledger debug target method all")
			else
				emit("Methods: all (the default: read, bounce and re-arm), read, bounce, rearm, none. For example /auraledger debug target method read")
			end
			return
		end
		local function S(v) if issecretvalue and issecretvalue(v) then return "hidden" end return tostring(v) end
		emit(("Method on a change of target: %s. Target now: %s, one you can attack: %s, auras hidden: %s."):format(Method(),
			tostring(ns.env and ns.env.target), tostring(ns.env and ns.env.targetFoe), tostring(ns.AurasSecret())))
		local any = false
		for _, f in pairs(active) do
			local c = f.slotC and f.slotC.target
			if c and f.group then
				any = true
				local slots, on = 0, 0
				for key in pairs(c.alSlots or {}) do
					slots = slots + 1
					if c.alOn and c.alOn[key] then on = on + 1 end
				end
				local okV, vis = pcall(c.IsVisible, c)
				local okM, mode = pcall(function() return c:GetOnUpdateMode() end)
				emit(("%s: display %s, shown %s, update mode %s, slots %d (%d on)"):format(ns.GroupName(f.group),
					c.alMacro == "parked" and "put away" or "in use", okV and S(vis) or "?", okM and S(mode) or "?", slots, on))
			end
		end
		if not any then emit("No group has a tracker on your target with a slot the game draws.") end
		emit(("Changes of target %d (%d in a fight). Reads %d (%d failed), bounces %d (%d failed), re-armed %d (%d failed), calls the game blocked %d.")
			:format(stats.changes, stats.inFight, stats.reads, stats.readFailed, stats.bounces, stats.bounceFailed, stats.rearmed, stats.rearmFailed, stats.blocked))
		for i, r in ipairs(log) do
			if i > 10 then break end
			emit(("  %.1fs ago, %s%s: read %s, bounce %s, update mode %s%s%s"):format(GetTime() - r.at, r.why, r.fight and " in a fight" or "",
				r.read == nil and "-" or tostring(r.read), r.bounce == nil and "-" or tostring(r.bounce), tostring(r.mode),
				r.rearm ~= nil and (", re-armed " .. tostring(r.rearm)) or "", (r.blocked or 0) > 0 and (", blocked " .. r.blocked) or ""))
		end
		emit("To test: put a debuff you track on one enemy, then in the fight switch to another without it and back. The tracker should follow each switch.")
	end
end

function Display:AfterCombat()
	-- Your target is read again, whatever happened to it in the fight.
	if Display.RefreshTargets then Display.RefreshTargets("fight ended") end
	if skin and skin.withoutManager and not ManagerUnsafe() then
		skin = nil
		if pcall(BuildSkin) and skin then ns.MASK_EPOCH = (ns.MASK_EPOCH or 0) + 1 end
		self:Rebuild()
	end
	-- A battleground keeps auras hidden after the fight: the containers wait until they are not.
	-- Rows that changed hands in the fight are read afresh, and what waited is laid out.
	self:MembersDirty()
	Display.BounceMembers()
	if self.dropAfterCombat and not ManagerUnsafe() then
		for f in pairs(self.dropAfterCombat) do
			f:Hide()
			f.group = nil
			ReleaseMembers(f)
			for _, c in pairs(f.slotC or {}) do
				DriverOff(c)
				c:Hide()
			end
			f.slotC = nil
			DropGate(f)
			f.chrome.hl:Hide()
			pool[#pool + 1] = f
		end
		self.dropAfterCombat = nil
	end
end

-- Dragging a tracker moves that tracker, wherever it came from. The group itself is moved by the
-- titled plate edit mode draws behind it, which is what that plate is for.
-- Several at once. The one actually dragged lands where it was aimed, and the rest keep their
-- places relative to where it came from. A place already taken when they arrive is given up rather
-- than fought over: that tracker goes on the end of the shape instead.
function Display:DropMarked(list, anchor, from, target, index, cellC, cellR, axis, cx, cy, landL, landT)
	local offsets = {}
	local base = ns.CellOf and ns.CellOf(from, anchor)
	if base then
		for _, t in ipairs(list) do
			if t ~= anchor then
				local cell = ns.CellOf(from, t)
				if cell then offsets[t] = { c = cell.c - base.c, r = cell.r - base.r } end
			end
		end
	end

	local to = target
	if not to then
		if #from.trackers == #list and #self:MarkedList(from) == #list then
			-- The whole group is moving: it is simpler and kinder to move the group itself.
			local gh = self:GetGhostFrame()
			if landL then
				self:PlaceGroupTopLeft(from, landL, landT)
			elseif gh and gh.offX then
				self:PlaceGroupTopLeft(from, cx - gh.offX, cy + gh.offY)
			else
				from.x, from.y = cx - 18, cy + 18
				local f = active[from.uid]
				if f then ApplyPosition(f, from) end
			end
			ns.Changed()
			self:ClearMarks()
			return
		end
		to = ns.NewGroupLike(from, cx - 18, cy + 18)
		to.placeAt = landL and { landL, landT } or nil
	end

	ns.DropTracker(anchor, to, index, cellC, cellR, axis)
	local landed = ns.CellOf and ns.CellOf(to, anchor)
	for _, t in ipairs(list) do
		if t ~= anchor then
			ns.MoveTracker(t, to)
			local off = offsets[t]
			if landed and off and to.style ~= "bars" then
				ns.PlaceTrackerCell(to, t, landed.c + off.c, landed.r + off.r)
			end
		end
	end
	ns.Changed()
	-- A new group set down in the open while the grid is up lands where the grid put it, now that
	-- it has been laid out and its size is known.
	if to.placeAt then
		self:PlaceGroupTopLeft(to, to.placeAt[1], to.placeAt[2])
		to.placeAt = nil
	end
	self:ClearMarks()
end

function Display:WidgetDragStart(w)
	local g, t = w.group, w.tracker
	if not g or not t or not self:IsUnlocked() then return end
	w.pulling = true
	-- A marked icon brings the rest of the marked ones with it, keeping their places relative to it.
	w.carrying = nil
	if self:IsMarked(t) then
		local list = self:MarkedList()
		if #list > 1 then w.carrying = list end
	end
	local text = (#g.trackers > 1) and "Drop it in the open for a place of its own" or "Drop it where you want it"
	if w.carrying then text = ("Moving %d together"):format(#w.carrying) end
	self:BeginGhost(t.icon, text, nil, nil, t)
	-- Every tracker of the group marked and on the cursor: it is the group that is being moved.
	local whole = w.carrying and #w.carrying == #g.trackers and #self:MarkedList(g) == #g.trackers
	self:SetGhostSource(w, g, whole)
end

function Display:WidgetDragStop(w)
	if not w.pulling then return end
	w.pulling = false
	local g, t = w.group, w.tracker
	local cancelled, cx, cy, target, index, cellC, cellR, axis, landL, landT = self:EndGhost()
	local carrying = w.carrying
	w.carrying = nil
	if cancelled or not g or not t then return end
	if carrying then
		self:DropMarked(carrying, t, g, target, index, cellC, cellR, axis, cx, cy, landL, landT)
		return
	end
	if target then
		ns.DropTracker(t, target, index, cellC, cellR, axis)
	elseif #g.trackers == 1 then
		-- A tracker on its own is its whole group, so dropping it somewhere just puts the group
		-- there: making a second group to hold it and throwing the first away moves nothing.
		if landL then
			self:PlaceGroupTopLeft(g, landL, landT)
		else
			g.x, g.y = cx - 18, cy + 18
			local f = active[g.uid]
			if f then ApplyPosition(f, g) end
		end
		ns.Changed()
	else
		-- Out on its own: a new group that keeps the look of the one it came from.
		local ng = ns.NewGroupLike(g, cx - 18, cy + 18)
		ns.MoveTracker(t, ng)
		if landL then self:PlaceGroupTopLeft(ng, landL, landT) end
	end
end
