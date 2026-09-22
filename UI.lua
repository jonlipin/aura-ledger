-- Aura Ledger window, built from the client's own frame templates and art. Three panes:
--   Book     spellbook style: a ledger of every buff / debuff seen, plus a chapter per class of
--            castable buffs; drag an aura off the page onto the screen to track it
--   Layout   the groups and trackers that exist
--   Options  settings and show conditions for whatever is selected
-- Every template goes through pcall with a fallback; "/auraledger debug" lists what resolved.

local ADDON, ns = ...
local UI = {}
ns.UI = UI

local FRAME_W, FRAME_H = 1360, 720
local ICON = "Interface\\Icons\\INV_Misc_Book_09"
-- The book starts to the right of the portrait, under the first tab, and spans all the tabs.
-- The page sits against the left edge; its content is indented to line up with the first tab,
-- which starts to the right of the portrait, as in the spellbook.
-- The maximized spellbook: two pages edge to edge. The book is the left page; Groups and Options
-- share the right page. LIP is how far below the inset top the paper lip sits (the page atlas
-- starts under the title bar and its own shaded rim forms the band that holds the tabs).
local BOOK_X, BOOK_W, TREE_W = 4, 700, 260
local LIP, RIM = 19, 61
local INDENT = 60
local RIGHT_W = FRAME_W - BOOK_W - 44
local TREE_ROW = 24

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local strlower = string.lower

-- ------------------------------------------------------------------
-- Template helpers
-- ------------------------------------------------------------------
local function TryCreateFrame(ftype, name, parent, candidates)
	for _, c in ipairs(candidates) do
		local tmpl, check = c[1], c[2]
		local ok, f = pcall(CreateFrame, ftype, name, parent, tmpl)
		if ok and f and (not check or check(f)) then
			ns.report["template " .. tmpl] = "ok"
			return f, tmpl
		end
		ns.report["template " .. tmpl] = "missing"
		if ok and f then f:Hide() end
	end
	return CreateFrame(ftype, name, parent), nil
end

-- Clips a texture to the rounded-square shape of the client's icon frames (the action bar's own
-- icon mask), so icons sit inside the art without black corners. Returns whether it could.
local ICON_MASK = "UI-HUD-ActionBar-IconFrame-Mask"
local function MaskIcon(frame, ...)
	if not (frame.CreateMaskTexture and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(ICON_MASK)) then
		ns.report["icon mask"] = "none"
		return false
	end
	for i = 1, select("#", ...) do
		local tex = select(i, ...)
		local m = frame:CreateMaskTexture()
		m:SetAtlas(ICON_MASK)
		-- The shape covers about two thirds of the mask region, so the region is drawn larger.
		m:SetPoint("TOPLEFT", tex, "TOPLEFT", -0.26 * (tex:GetWidth() or 40), 0.26 * (tex:GetHeight() or 40))
		m:SetPoint("BOTTOMRIGHT", tex, "BOTTOMRIGHT", 0.26 * (tex:GetWidth() or 40), -0.26 * (tex:GetHeight() or 40))
		tex:AddMaskTexture(m)
	end
	ns.report["icon mask"] = ICON_MASK
	return true
end

-- On parchment everything is written in ink: dark text, no shadow. PARCHMENT is set once the art is known.
local PARCHMENT = false
local INK = { text = { 0.18, 0.11, 0.06 }, head = { 0.18, 0.11, 0.06 }, dim = { 0.36, 0.26, 0.16 } }
local function Ink(fs, kind)
	if not PARCHMENT or not fs then return fs end
	local c = INK[kind or "text"]
	fs:SetTextColor(c[1], c[2], c[3])
	fs:SetShadowColor(0, 0, 0, 0)
	return fs
end
-- Colour codes for text built from strings.
local function InkCodes()
	if PARCHMENT then return "|cff2e1c0f", "|cff5c4328", "|cff7a6a56" end -- group, dim, off
	return "|cffffd100", "|cff909090", "|cff808080"
end

local function HasAtlas(atlas)
	return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) ~= nil
end

local function SetRowHighlight(tex)
	for _, atlas in ipairs({ "auctionhouse-ui-row-highlight", "search-highlight" }) do
		if HasAtlas(atlas) then tex:SetAtlas(atlas) return end
	end
	tex:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
	tex:SetBlendMode("ADD")
end

local function TextTooltip(owner, title, ...)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:SetText(title, 1, 1, 1)
	for i = 1, select("#", ...) do
		local line = select(i, ...)
		if line then GameTooltip:AddLine(line, nil, nil, nil, true) end
	end
	GameTooltip:Show()
end

local function Ago(t)
	if not t or t == 0 then return "never" end
	local d = max(0, time() - t)
	if d < 60 then return "just now" end
	if d < 3600 then return floor(d / 60) .. "m ago" end
	if d < 86400 then return floor(d / 3600) .. "h ago" end
	return floor(d / 86400) .. "d ago"
end

local KIND_COLOR = { buff = "|cff7fd4ff", debuff = "|cffff7a7a", any = "|cffffffff" }
local KIND_WORD = { buff = "Buff", debuff = "Debuff", any = "Added by hand" }

local function MakeButton(parent, text, width)
	local b = TryCreateFrame("Button", nil, parent, { { "UIPanelButtonTemplate" } })
	b:SetSize(width or 100, 22)
	b:SetText(text)
	return b
end

-- A virtual list: a handful of pooled rows moved around inside a tall scroll child.
local function CreateList(name, parent, rowHeight, createRow, updateRow)
	local ok, scroll = pcall(CreateFrame, "ScrollFrame", name, parent, "AuraLedgerScrollFrameTemplate")
	if not (ok and scroll) then
		scroll = CreateFrame("ScrollFrame", name, parent)
		scroll:EnableMouseWheel(true)
		scroll:SetScript("OnMouseWheel", function(self, delta)
			local range = self:GetVerticalScrollRange() or 0
			self:SetVerticalScroll(max(0, min(range, (self:GetVerticalScroll() or 0) - delta * rowHeight * 3)))
		end)
	end
	ns.report["scroll " .. name] = scroll.ScrollBar and "ScrollFrameTemplate" or "bare"
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(1, 1)
	scroll:SetScrollChild(child)
	local list = { scroll = scroll, child = child, rows = {}, data = {} }

	function list:Update()
		local width = scroll:GetWidth() or 0
		if width > 0 then child:SetWidth(width) end
		local offset = scroll:GetVerticalScroll() or 0
		local first = floor(offset / rowHeight) + 1
		local count = ceil((scroll:GetHeight() or 0) / rowHeight) + 1
		for i = 1, count do
			local row = self.rows[i]
			if not row then
				row = createRow(child)
				row:SetHeight(rowHeight)
				self.rows[i] = row
			end
			local index = first + i - 1
			local item = self.data[index]
			if item then
				row:ClearAllPoints()
				row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(index - 1) * rowHeight)
				row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -(index - 1) * rowHeight)
				updateRow(row, item, index)
				row:Show()
			else
				row:Hide()
			end
		end
		for i = count + 1, #self.rows do self.rows[i]:Hide() end
	end

	function list:SetData(data)
		self.data = data
		child:SetHeight(max(1, #data * rowHeight))
		local range = max(0, #data * rowHeight - (scroll:GetHeight() or 0))
		if (scroll:GetVerticalScroll() or 0) > range then scroll:SetVerticalScroll(range) end
		self:Update()
	end

	scroll:HookScript("OnVerticalScroll", function() list:Update() end)
	scroll:HookScript("OnSizeChanged", function() list:Update() end)
	return list
end

-- ------------------------------------------------------------------
-- Option widgets (a running y cursor down a panel; each widget registers a sync function)
-- ------------------------------------------------------------------
local SLIDER_TEMPLATES = { "MinimalSliderTemplate", "UISliderTemplate", "OptionsSliderTemplate" }

local function CreateSlider(parent)
	for _, tmpl in ipairs(SLIDER_TEMPLATES) do
		local ok, sl = pcall(CreateFrame, "Slider", nil, parent, tmpl)
		if ok and sl and sl.SetMinMaxValues then
			ns.report["slider"] = tmpl
			for _, key in ipairs({ "Low", "High", "Text" }) do
				if type(sl[key]) == "table" and sl[key].SetText then sl[key]:SetText("") end
			end
			return sl
		end
	end
	ns.report["slider"] = "bare"
	local sl = CreateFrame("Slider", nil, parent)
	sl:SetOrientation("HORIZONTAL")
	local bar = sl:CreateTexture(nil, "BACKGROUND")
	bar:SetPoint("LEFT")
	bar:SetPoint("RIGHT")
	bar:SetHeight(6)
	bar:SetColorTexture(0, 0, 0, 0.6)
	sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	return sl
end

local function CreateCheck(parent)
	local cb
	for _, tmpl in ipairs({ "UICheckButtonTemplate", "ChatConfigCheckButtonTemplate" }) do
		local ok, made = pcall(CreateFrame, "CheckButton", nil, parent, tmpl)
		if ok and made then cb = made break end
	end
	if not cb then
		cb = CreateFrame("CheckButton", nil, parent)
		cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
		cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
	end
	cb:SetSize(22, 22)
	-- Own label: the templates disagree about where theirs lives.
	cb.label = Ink(parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
	cb.label:SetPoint("LEFT", cb, "RIGHT", 1, 0)
	return cb
end

local Builder = {}
Builder.__index = Builder

local function NewBuilder(panel, width)
	return setmetatable({ panel = panel, y = -4, width = width, syncers = {} }, Builder)
end

function Builder:Sync()
	for _, fn in ipairs(self.syncers) do fn() end
end

function Builder:Header(text)
	self.y = self.y - 8
	local fs = Ink(self.panel:CreateFontString(nil, "OVERLAY", "GameFontNormal"), "head")
	fs:SetPoint("TOPLEFT", 6, self.y)
	fs:SetText(text)
	local line = self.panel:CreateTexture(nil, "ARTWORK")
	if PARCHMENT then line:SetColorTexture(0.35, 0.2, 0.05, 0.5) else line:SetColorTexture(1, 0.82, 0, 0.35) end
	line:SetHeight(1)
	line:SetPoint("TOPLEFT", 6, self.y - 15)
	line:SetPoint("TOPRIGHT", -6, self.y - 15)
	self.y = self.y - 22
	return fs
end

function Builder:Note(text)
	local fs = Ink(self.panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), "dim")
	fs:SetPoint("TOPLEFT", 8, self.y)
	fs:SetPoint("TOPRIGHT", -8, self.y)
	fs:SetJustifyH("LEFT")
	fs:SetWidth(self.width - 16)
	fs:SetText(text)
	-- The measured height is not trustworthy before the panel has laid out, so the line count is
	-- also estimated from the text length (about 5.5px a character at this font size).
	local lines = ceil(#text * 5.5 / max(100, self.width - 16))
	self.y = self.y - max(14, (fs:GetStringHeight() or 0) + 4, lines * 13 + 4)
	return fs
end

function Builder:Slider(label, opts)
	local panel, y = self.panel, self.y
	local fs = Ink(panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
	fs:SetPoint("TOPLEFT", 8, y)
	fs:SetText(label)
	local value = Ink(panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"), "head")
	value:SetPoint("TOPRIGHT", -10, y)
	local sl = CreateSlider(panel)
	sl:SetPoint("TOPLEFT", 10, y - 14)
	sl:SetPoint("TOPRIGHT", -10, y - 14)
	sl:SetHeight(16)
	sl:SetMinMaxValues(opts.min, opts.max)
	sl:SetValueStep(opts.step)
	if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
	local syncing = false
	local function ShowValue(v) value:SetText(opts.format and opts.format(v) or tostring(v)) end
	sl:SetScript("OnValueChanged", function(_, v)
		if syncing then return end
		v = floor(v / opts.step + 0.5) * opts.step
		v = max(opts.min, min(opts.max, v))
		local current = opts.get()
		if current ~= nil and v ~= current then opts.set(v) end
		ShowValue(v)
	end)
	sl:EnableMouseWheel(true)
	sl:SetScript("OnMouseWheel", function(self, delta)
		local current = opts.get()
		if current then self:SetValue(max(opts.min, min(opts.max, current + delta * opts.step))) end
	end)
	self.syncers[#self.syncers + 1] = function()
		local current = opts.get()
		if current == nil then return end
		syncing = true
		sl:SetValue(current)
		syncing = false
		ShowValue(current)
	end
	self.y = y - 38
	return sl
end

function Builder:Check(label, get, set, tip)
	local cb = CreateCheck(self.panel)
	cb:SetPoint("TOPLEFT", 6, self.y)
	cb.label:SetText(label)
	cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	if tip then
		cb:SetScript("OnEnter", function(self) TextTooltip(self, label, tip) end)
		cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	self.syncers[#self.syncers + 1] = function() cb:SetChecked(get() and true or false) end
	self.y = self.y - 24
	return cb
end

-- A row of small checkboxes laid out in columns. items = { { key, label, colorHex? }, ... }
function Builder:CheckGrid(items, cols, get, set)
	local colW = floor((self.width - 12) / cols)
	for i, item in ipairs(items) do
		local cb = CreateCheck(self.panel)
		local col, row = (i - 1) % cols, floor((i - 1) / cols)
		cb:SetPoint("TOPLEFT", 6 + col * colW, self.y - row * 22)
		cb.label:SetText((item[3] and ("|c" .. item[3]) or "") .. item[2] .. (item[3] and "|r" or ""))
		cb.label:SetWidth(colW - 26)
		cb.label:SetJustifyH("LEFT")
		cb.label:SetWordWrap(false)
		cb:SetScript("OnClick", function(self) set(item[1], self:GetChecked() and true or false) end)
		self.syncers[#self.syncers + 1] = function() cb:SetChecked(get(item[1]) and true or false) end
	end
	self.y = self.y - ceil(#items / cols) * 22 - 4
end

-- A labelled button that steps through choices. choices = { { value, text }, ... }
function Builder:Cycle(label, choices, get, set, tip, buttonWidth)
	local panel, y = self.panel, self.y
	local fs = Ink(panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
	fs:SetPoint("TOPLEFT", 8, y - 5)
	fs:SetText(label)
	local narrow = self.width < 320
	local b = MakeButton(panel, "", narrow and (self.width - 18) or (buttonWidth or 190))
	if narrow then
		fs:ClearAllPoints()
		fs:SetPoint("TOPLEFT", 8, y - 2)
		b:SetPoint("TOPLEFT", 8, y - 16)
	else
		b:SetPoint("TOPRIGHT", -8, y)
	end
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	local function IndexOf(v)
		for i, c in ipairs(choices) do if c[1] == v then return i end end
		return 1
	end
	local function Sync() b:SetText(choices[IndexOf(get())][2]) end
	b:SetScript("OnClick", function(_, button)
		local i = IndexOf(get()) + (button == "RightButton" and -1 or 1)
		if i > #choices then i = 1 elseif i < 1 then i = #choices end
		set(choices[i][1])
		Sync()
	end)
	if tip then
		b:SetScript("OnEnter", function(self) TextTooltip(self, label, tip, "|cffaaaaaaClick for the next choice, right-click for the previous.|r") end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	self.syncers[#self.syncers + 1] = Sync
	self.y = y - (narrow and 42 or 26)
	return b
end

function Builder:Edit(label, get, set, numeric)
	local panel, y = self.panel, self.y
	local fs = Ink(panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
	fs:SetPoint("TOPLEFT", 8, y - 5)
	fs:SetText(label)
	local narrow = self.width < 320
	local eb = TryCreateFrame("EditBox", nil, panel, { { "InputBoxTemplate" } })
	if narrow then
		fs:ClearAllPoints()
		fs:SetPoint("TOPLEFT", 8, y - 2)
		eb:SetSize(self.width - 26, 20)
		eb:SetPoint("TOPLEFT", 14, y - 16)
	else
		eb:SetSize(184, 20)
		eb:SetPoint("TOPRIGHT", -10, y)
	end
	eb:SetAutoFocus(false)
	if eb.SetFontObject then eb:SetFontObject("GameFontHighlightSmall") end
	eb:SetScript("OnTextChanged", function(self, userInput)
		if userInput then set(self:GetText()) end
	end)
	eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	self.syncers[#self.syncers + 1] = function()
		if not eb:HasFocus() then eb:SetText(get() or "") end
	end
	self.y = y - (narrow and 42 or 26)
	return eb
end

-- A destructive button that has to be clicked twice.
function Builder:ConfirmButton(text, width, onConfirm)
	local b = MakeButton(self.panel, text, width)
	local armed = 0
	b:SetScript("OnClick", function(self)
		if GetTime() - armed < 3 then
			armed = 0
			self:SetText(text)
			onConfirm()
		else
			armed = GetTime()
			self:SetText("Click again to confirm")
		end
	end)
	b:SetScript("OnHide", function(self) armed = 0 self:SetText(text) end)
	return b
end

-- The "show when" block. getCond returns the cond table being edited.
function Builder:Conditions(getCond, onChange)
	local function Cond() return getCond() or {} end
	self:Check("Never show (disabled)", function() return Cond().never end,
		function(v) Cond().never = v or nil onChange() end,
		"Switches this off without deleting it.")
	for _, tog in ipairs(ns.TOGGLES) do
		local key = tog[1]
		self:Cycle(tog[2], { { "any", "Either" }, { "yes", tog[3] }, { "no", tog[4] } },
			function() return Cond()[key] or "any" end,
			function(v) Cond()[key] = (v ~= "any") and v or nil onChange() end, nil, 150)
	end
	local function SetGetters(field)
		return function(k) local set = Cond()[field] return set and set[k] end,
			function(k, v)
				local c = Cond()
				c[field] = c[field] or {}
				c[field][k] = v or nil
				if not next(c[field]) then c[field] = nil end
				onChange()
			end
	end
	self.y = self.y - 2
	self:Note("Group size (none ticked = any):")
	self:CheckGrid(ns.GROUPS, 3, SetGetters("group"))
	self:Note("Where (none ticked = anywhere):")
	self:CheckGrid(ns.PLACES, 2, SetGetters("place"))
	self:Note("Class (none ticked = any class):")
	local classes = {}
	for _, class in ipairs(ns.CLASSES) do
		local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
		local hex = color and color.colorStr or nil
		classes[#classes + 1] = { class, (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class, hex }
	end
	self:CheckGrid(classes, 3, SetGetters("class"))
end

-- ------------------------------------------------------------------
-- Window
-- ------------------------------------------------------------------
local frame, body
local treeList
local groupBuilder, trackerBuilder, groupPanel, trackerPanel, emptyText, optionsScroll, optionsChild
local searchBox, unlockCheck
local histFilter, histSort = "all", "recent"
local trackerTitle = {}

local function SelectedGroup() return ns.selected and ns.selected.group end
local function SelectedTracker() return ns.selected and ns.selected.tracker end

local function GroupChanged()
	local g = SelectedGroup()
	if g then ns.Display:ApplyGroup(g) end
	UI:RefreshTree()
end

local function TrackerChanged()
	ns.Display:Refresh()
	UI:RefreshTree()
end

local function Pane(parent, title, left, right, top, height)
	local p = CreateFrame("Frame", nil, parent)
	p:SetPoint("TOP", parent, "TOP", 0, -4 - (top or 0))
	if height then p:SetHeight(height) else p:SetPoint("BOTTOM", parent, "BOTTOM", 0, 4) end
	if left then p:SetPoint("LEFT", parent, "LEFT", left, 0) end
	if right then p:SetPoint("RIGHT", parent, "LEFT", right, 0) else p:SetPoint("RIGHT", parent, "RIGHT", -4, 0) end
	if PARCHMENT then
		p.title = Ink(p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), "head")
		p.title:SetPoint("TOPLEFT", 10, -2)
		p.title:SetText(title)
		if STANDARD_TEXT_FONT then p.title:SetFont(STANDARD_TEXT_FONT, 20, "") end
		if HasAtlas("spellbook-list-backplate") then
			local plate = p:CreateTexture(nil, "BACKGROUND", nil, 1)
			plate:SetAtlas("spellbook-list-backplate")
			plate:SetSize(360, 92)
			plate:SetAlpha(0.65)
			plate:SetPoint("TOPLEFT", p.title, "TOPLEFT", -52, 32)
		end
		local div = p:CreateTexture(nil, "ARTWORK")
		div:SetPoint("TOPLEFT", 4, -22)
		div:SetPoint("TOPRIGHT", -4, -22)
		if HasAtlas("spellbook-divider") then div:SetAtlas("spellbook-divider") div:SetHeight(11)
		else div:SetHeight(1) div:SetColorTexture(0.35, 0.2, 0.05, 0.5) end
		p.titleHeight = 34
		return p
	end
	local bg = p:CreateTexture(nil, "BACKGROUND", nil, 1)
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.42)
	local strip = p:CreateTexture(nil, "BACKGROUND", nil, 2)
	strip:SetPoint("TOPLEFT")
	strip:SetPoint("TOPRIGHT")
	strip:SetHeight(20)
	strip:SetColorTexture(0.12, 0.09, 0.03, 0.9)
	p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	p.title:SetPoint("TOPLEFT", 8, -4)
	p.title:SetText(title)
	p.titleHeight = 24
	return p
end

-- ---- The book: works like the spellbook ------------------------------
-- Side tabs pick a chapter (your ledger, one per class, common auras), each page holds twelve
-- auras as spell buttons, arrows or the mouse wheel turn pages, and any aura can be dragged off
-- the page onto the screen the way a spell is dragged onto an action bar.
local PER_PAGE = 12
local book = { tab = "HISTORY", page = 1, pages = 1, buttons = {}, tabs = {}, items = {} }

-- nil when the client can't say; callers pass what to assume then.
local function FileExists(path, assume)
	if GetFileIDFromPath then
		local ok, id = pcall(GetFileIDFromPath, path)
		if ok then return id ~= nil and id ~= 0 end
	end
	return assume
end

local function ClassLabel(token)
	if token == "ITEMS" then return "Items and food" end
	if token == "HISTORY" then return "Ledger" end
	if token == "COMMON" then return "Common" end
	if token == "ITEMS" then return "Items" end
	if token == "PVE" then return "Dungeons and raids" end
	return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or (token:sub(1, 1) .. token:sub(2):lower())
end

local function TrackedNames()
	local set = {}
	for _, g in ipairs(ns.profile.groups) do
		for _, t in ipairs(g.trackers) do
			if t.name then set[strlower(t.name)] = true end
		end
	end
	return set
end

local function BookTooltip(b)
	local h = b.item
	if not h then return end
	GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
	local shown = false
	if h.id and GameTooltip.SetSpellByID then
		shown = pcall(GameTooltip.SetSpellByID, GameTooltip, h.id) and GameTooltip:NumLines() > 0
	end
	if not shown then GameTooltip:SetText(h.name or ("Spell " .. tostring(h.id)), 1, 1, 1) end
	GameTooltip:AddLine(" ")
	if h.prebuilt then
		GameTooltip:AddLine((h.note or ClassLabel(h.class)) .. (h.kind == "debuff" and ": debuff" or ": buff") .. ", tracked by name (any rank)", 0.6, 0.8, 1, true)
	else
		GameTooltip:AddLine(KIND_WORD[h.kind] or "", 0.6, 0.8, 1)
		if h.ids and next(h.ids) then
			local ids = {}
			for id in pairs(h.ids) do ids[#ids + 1] = id end
			table.sort(ids)
			GameTooltip:AddLine("Spell IDs seen: " .. table.concat(ids, ", "), 0.8, 0.8, 0.8, true)
		end
		if (h.count or 0) > 0 then
			GameTooltip:AddLine(("Seen %d time%s, last %s"):format(h.count, h.count == 1 and "" or "s", Ago(h.last)), 0.8, 0.8, 0.8)
		end
		if h.duration and h.duration > 0 then GameTooltip:AddLine("Lasts " .. ns.FormatTime(h.duration), 0.8, 0.8, 0.8) end
	end
	GameTooltip:AddLine(" ")
	if ns.CombatTrackable and ns.CombatTrackable(h) then
		GameTooltip:AddLine("Marked combat: the game can follow this one by spell, so a group set to track in combat keeps it right during a fight.", 0.45, 0.75, 1, true)
	else
		GameTooltip:AddLine("Not marked combat: the game cannot follow this one by spell, so the addon draws it and it updates between fights.", 0.8, 0.7, 0.5, true)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Drag onto the screen: track it", 0.4, 1, 0.5)
	GameTooltip:AddLine("Drop on an existing tracker: group them", 0.4, 1, 0.5)
	GameTooltip:AddLine("Double-click: track it in the middle of the screen", 0.7, 0.7, 0.7)
	if not h.prebuilt then GameTooltip:AddLine("Shift-right-click: forget this entry", 0.7, 0.7, 0.7) end
	GameTooltip:Show()
end

local function CreateBookButton(parent, onParchment, art)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(300, 60)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")

	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetSize(40, 40)
	b.icon:SetPoint("TOPLEFT", 12, -10)
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	MaskIcon(b, b.icon)
	-- The classic spellbook draws its 64px ring 3px outside a 37px icon; same proportions here.
	b.slot = b:CreateTexture(nil, "BACKGROUND", nil, 3)
	if FileExists("Interface\\Spellbook\\UI-Spellbook-SpellBackground", false) then
		b.slot:SetTexture("Interface\\Spellbook\\UI-Spellbook-SpellBackground")
		b.slot:SetSize(69, 69)
		b.slot:SetPoint("TOPLEFT", b.icon, "TOPLEFT", -3.2, 3.2)
		ns.report["book slot art"] = "UI-Spellbook-SpellBackground"
	else
		b.slot:SetTexture("Interface\\Buttons\\UI-EmptySlot")
		b.slot:SetSize(72, 72)
		b.slot:SetPoint("CENTER", b.icon, "CENTER", 0, 0)
		ns.report["book slot art"] = "UI-EmptySlot"
	end
	b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	if STANDARD_TEXT_FONT then b.name:SetFont(STANDARD_TEXT_FONT, 16, "") end
	b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 12, 1)
	b.name:SetWidth(236)
	b.name:SetJustifyH("LEFT")
	b.name:SetJustifyV("TOP")
	if b.name.SetMaxLines then b.name:SetMaxLines(2) end
	b.sub = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	if STANDARD_TEXT_FONT then b.sub:SetFont(STANDARD_TEXT_FONT, 12, "") end
	b.sub:SetPoint("BOTTOMLEFT", b.icon, "BOTTOMRIGHT", 12, -1)
	b.sub:SetWidth(236)
	b.sub:SetJustifyH("LEFT")
	b.sub:SetWordWrap(false)
	b.onParchment = onParchment
	-- The spellbook's own hover glow on the icon.
	-- Hover and dispel colour both light up the frame art itself: an additive copy of the very same
	-- frame atlas, at the same anchor, so it can never sit off the frame.
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	if art and art.iconFrame then
		hl:SetAtlas(art.iconFrame)
		hl:SetSize(51, 48)
		hl:SetPoint("CENTER", b.icon, "CENTER", -3, -2)
		hl:SetBlendMode("ADD")
		hl:SetVertexColor(1, 0.85, 0.45, 0.35)
		-- The spellbook lights a backplate behind the whole entry on hover.
		if art.backplate then
			-- Under everything (the HIGHLIGHT layer would draw over the text), faint at rest as in the
			-- spellbook, full on hover.
			local plate = b:CreateTexture(nil, "BACKGROUND", nil, 1)
			plate:SetAtlas(art.backplate)
			plate:SetPoint("TOPLEFT", b, "TOPLEFT", -6, 2)
			plate:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -8, -2)
			plate:SetAlpha(0.25)
			b.plate = plate
		end
	else
		hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
		hl:SetBlendMode("ADD")
		hl:SetAllPoints(b.icon)
	end
	b.typeBorder = b:CreateTexture(nil, "OVERLAY", nil, 1)
	if art and art.iconFrame then
		b.typeBorder:SetAtlas(art.iconFrame)
		b.typeBorder:SetSize(51, 48)
		b.typeBorder:SetPoint("CENTER", b.icon, "CENTER", -3, -2)
		b.typeBorder:SetBlendMode("ADD")
	else
		b.typeBorder:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
		b.typeBorder:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
		b.typeBorder:SetPoint("TOPLEFT", b.icon, "TOPLEFT", -1, 1)
		b.typeBorder:SetPoint("BOTTOMRIGHT", b.icon, "BOTTOMRIGHT", 1, -1)
	end
	b.typeBorder:Hide()

	b:SetScript("OnEnter", function(self) if self.plate then self.plate:SetAlpha(1) end BookTooltip(self) end)
	b:SetScript("OnLeave", function(self) if self.plate then self.plate:SetAlpha(0.25) end GameTooltip:Hide() end)
	b:SetScript("OnDragStart", function(self)
		if not self.item then return end
		self.dragItem = self.item
		GameTooltip:Hide()
		ns.Display:BeginGhost(self.item.icon, "Track here", nil, "|cffff6060Drop on the screen, or on the Groups and trackers list|r")
	end)
	b:SetScript("OnDragStop", function(self)
		local h = self.dragItem
		self.dragItem = nil
		if not h then return end
		-- The list is checked before the ghost goes away, while the cursor is still over the row.
		local _, cursorY = ns.Display.CursorUI()
		local listGroup, listIndex, kind = UI:TreeDropAt(cursorY)
		local cancelled, cx, cy, target, index = ns.Display:EndGhost()
		if kind then
			ns.TrackHistory(h, listGroup, listIndex)
		elseif cancelled then
			return
		else
			ns.TrackHistory(h, target, index, cx - 20, cy + 20)
		end
		UI:ShowSelection()
		UI:RefreshHistory()
	end)
	b:SetScript("OnDoubleClick", function(self)
		if not self.item then return end
		ns.TrackHistory(self.item)
		UI:ShowSelection()
		UI:RefreshHistory()
	end)
	b:SetScript("OnClick", function(self, button)
		local h = self.item
		if button == "RightButton" and IsShiftKeyDown() and h and not h.prebuilt then
			ns.ForgetHistory(h)
			UI:RefreshHistory()
		end
	end)
	return b
end

local function UpdateBookButton(b, h, tracked)
	b.item = h
	if not h then b:Hide() return end
	if h.prebuilt then ns.ResolveBookItem(h) end
	b.icon:SetTexture(h.icon or ns.QUESTION)
	if h.kind == "debuff" then
		local c = ns.DISPEL_COLORS[h.dispel or "none"] or ns.DISPEL_COLORS.none
		b.typeBorder:SetVertexColor(c[1], c[2], c[3])
		b.typeBorder:Show()
	else
		b.typeBorder:Hide()
	end
	local name = h.name or ("Spell " .. tostring(h.id))
	local isTracked = h.name and tracked[strlower(h.name)]
	if b.onParchment then
		b.name:SetTextColor(0.18, 0.11, 0.06)
		b.name:SetShadowColor(0, 0, 0, 0)
		b.sub:SetTextColor(0.18, 0.11, 0.06)
		b.sub:SetShadowColor(0, 0, 0, 0)
		b.name:SetText(name)
	else
		b.name:SetText((KIND_COLOR[h.kind] or "") .. name .. "|r")
	end
	local sub
	if h.prebuilt then
		sub = h.note or (h.kind == "debuff" and "Debuff" or "Buff")
	elseif (h.count or 0) > 0 then
		local where = (h.onTarget and not h.onYou) and " on targets" or (h.onTarget and " on you and targets" or "")
		sub = "Seen " .. h.count .. "x" .. where .. ", " .. Ago(h.last)
	else
		sub = "Added by hand"
	end
	if isTracked then sub = sub .. (b.onParchment and "  |cff0a5a0atracked|r" or "  |cff40ff60tracked|r") end
	if ns.CombatTrackable and ns.CombatTrackable(h) then
		sub = sub .. (b.onParchment and "  |cff1a3f7acombat|r" or "  |cff6cc0ffcombat|r")
	end
	b.sub:SetText(sub)
	b:Show()
end

local function BookItems()
	local query = strlower(searchBox and searchBox:GetText() or "")
	local list = {}
	if query ~= "" then
		local have = {}
		for _, h in pairs(ns.db.history) do
			local hay = strlower(h.name or "") .. " " .. tostring(h.id or "")
			if hay:find(query, 1, true) and not (h.kind == "debuff" and not h.onTarget) then
				list[#list + 1] = h
				if h.name then have[strlower(h.name)] = true end
			end
		end
		for _, token in ipairs(ns.BOOK_ORDER) do
			for _, item in ipairs(ns.BookPages()[token] or {}) do
				local l = strlower(item.name)
				if not have[l] and not item.unknown and (l .. " " .. tostring(item.listId or "") .. " " .. strlower(item.note or "")):find(query, 1, true) then
					have[l] = true
					list[#list + 1] = item
				end
			end
		end
		table.sort(list, function(a, b) return strlower(a.name or "") < strlower(b.name or "") end)
		return list, "Search results"
	end
	if book.tab ~= "HISTORY" then
		local titles = { ITEMS = "Items and food" }
		local page = {}
		for _, item in ipairs(ns.BookPages()[book.tab] or {}) do
			if not item.unknown then page[#page + 1] = item end
		end
		return page, titles[book.tab] or ClassLabel(book.tab)
	end
	for _, h in pairs(ns.db.history) do
		local keep
		if histFilter == "you" then keep = h.onYou or (not h.onTarget)
		elseif histFilter == "target" then keep = h.onTarget
		else keep = histFilter == "all" or h.kind == histFilter or h.kind == "any" end
		-- A debuff only ever seen on you cannot be tracked by spell on this client; it is not offered.
		if keep and h.kind == "debuff" and not h.onTarget then keep = false end
		if keep then list[#list + 1] = h end
	end
	if histSort == "name" then
		table.sort(list, function(a, b) return strlower(a.name or "") < strlower(b.name or "") end)
	elseif histSort == "count" then
		table.sort(list, function(a, b)
			if (a.count or 0) ~= (b.count or 0) then return (a.count or 0) > (b.count or 0) end
			return strlower(a.name or "") < strlower(b.name or "")
		end)
	else
		table.sort(list, function(a, b)
			if (a.last or 0) ~= (b.last or 0) then return (a.last or 0) > (b.last or 0) end
			return strlower(a.name or "") < strlower(b.name or "")
		end)
	end
	return list, "Ledger"
end

-- Named RefreshHistory because the core calls it whenever the ledger gains a row.
function UI:RefreshHistory()
	if not frame or not frame:IsShown() or not book.pane then return end
	if ns.ResolveAllBookItems then ns.ResolveAllBookItems() end
	local items, title = BookItems()
	book.items = items
	book.pages = max(1, ceil(#items / PER_PAGE))
	book.page = max(1, min(book.page, book.pages))
	book.header:SetText(title)
	local tracked = TrackedNames()
	local first = (book.page - 1) * PER_PAGE
	for i = 1, PER_PAGE do UpdateBookButton(book.buttons[i], items[first + i], tracked) end
	book.pageText:SetText(("Page %d of %d"):format(book.page, book.pages))
	book.prev:SetEnabled(book.page > 1)
	book.next:SetEnabled(book.page < book.pages)
	local searching = (searchBox:GetText() or "") ~= ""
	local onHistory = book.tab == "HISTORY" and not searching
	book.filterButton:SetShown(onHistory)
	book.sortButton:SetShown(onHistory)
	for token, tab in pairs(book.tabs) do tab:SetChosen(token == book.tab and not searching) end
	book.empty:SetShown(#items == 0)
	if #items == 0 then
		book.empty:SetText(searching and "Nothing matches that." or
			"Nothing here yet.\n\nEvery buff and debuff you get is written down here as it happens. The tabs along the top already list the buffs each class can cast.")
	end
end

function UI:TurnPage(delta)
	local page = max(1, min(book.pages, book.page + delta))
	if page == book.page then return end
	book.page = page
	if PlaySound and SOUNDKIT and SOUNDKIT.IG_ABILITY_PAGE_TURN then pcall(PlaySound, SOUNDKIT.IG_ABILITY_PAGE_TURN) end
	self:RefreshHistory()
end

local function PageArrow(parent, which)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(32, 32)
	local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. which .. "Page-"
	b:SetNormalTexture(base .. "Up")
	b:SetPushedTexture(base .. "Down")
	b:SetDisabledTexture(base .. "Disabled")
	b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	return b
end

-- The Forever spellbook (Blizzard_PlayerSpells) draws its page, divider and icon frames from atlases.
-- When it is loaded, the names are read off its frames so the book can wear the same art (they are
-- printed by "/auraledger atlases"). It is NEVER loaded from here: loading a Blizzard addon from
-- addon code taints it, and the client then blocks its own protected calls at login. Until the
-- player opens the spellbook, names seen on this client before are used instead.
local bookArt
-- The exact art names, read off the Forever spellbook (SavedVariables dump, 2026-09-21). The single
-- wide page the book shows is spellbook-Page-Right-C60 stretched across (Blizzard's BookBGHalved).
local KNOWN_ART = {
	page = "spellbook-Page-Right-C60",
	pageLeft = "spellbook-Page-Left-C60",
	pageRight = "spellbook-Page-Right-C60",
	divider = "spellbook-divider",
	iconFrame = "spellbook-item-iconframe",            -- 51x48, the square frame with the ribbon
	iconShadow = "spellbook-item-iconframe-shadow",    -- 54x51
	iconHover = "spellbook-item-iconframe-hover",      -- 40x40
	backplate = "spellbook-item-backplate",            -- 255x64, 25% behind an entry, full on hover
	listPlate = "spellbook-list-backplate",            -- 415x106, 65% behind a heading
	circleFrame = "talents-node-circle-gray",          -- 40x40, what passives wear
	tab = "spellbook-Tab-Frame-C60",                   -- 43x37
	tabActive = "spellbook-Tab-Frame-Glow-C60",
	tabActiveGlow = "spellbook-Tab-Frame-glow-gradient-C60",
}

local function SpellBookArt()
	if bookArt ~= nil then return bookArt or nil end
	bookArt = false
	if ns.db.plainBook then return end
	local art = {}
	for key, atlas in pairs(KNOWN_ART) do
		if HasAtlas(atlas) then art[key] = atlas end
	end
	if not art.page then return end
	bookArt = art
	return art
end
UI.SpellBookArt = SpellBookArt

-- Still dumps every atlas on the spellbook frame (when it has been opened), for checking the names.
function UI:PrintAtlases()
	local root = (PlayerSpellsFrame and PlayerSpellsFrame.SpellBookFrame) or SpellBookFrame
	if not root or not root.GetRegions then ns.Print("The spellbook is not loaded yet: open it once (P), then run this again.") return end
	local found = {}
	local function KeyOf(parent, child)
		for k, v in pairs(parent) do
			if v == child and type(k) == "string" then return k end
		end
	end
	local function Walk(f, path, depth)
		if depth > 7 or not f.GetRegions then return end
		for _, r in ipairs({ f:GetRegions() }) do
			if r.GetObjectType and r:GetObjectType() == "Texture" then
				local ok, atlas = pcall(r.GetAtlas, r)
				if ok and atlas and atlas ~= "" then
					local w, h = r:GetSize()
					found[#found + 1] = { atlas, path .. "." .. (KeyOf(f, r) or "?"), floor(w or 0), floor(h or 0) }
				end
			end
		end
		if f.GetChildren then
			for _, c in ipairs({ f:GetChildren() }) do Walk(c, path .. "." .. (KeyOf(f, c) or "?"), depth + 1) end
		end
	end
	Walk(root, "SpellBookFrame", 0)
	ns.db.spellbookAtlases = found
	ns.Print(#found .. " atlases on the spellbook frame (also saved with the settings):")
	for _, e in ipairs(found) do ns.Print(("  %s  %s  %dx%d"):format(e[1], e[2], e[3], e[4])) end
	local art = SpellBookArt()
	if art then
		local have = {}
		for key in pairs(art) do have[#have + 1] = key end
		table.sort(have)
		ns.Print("Known art present on this client: " .. table.concat(have, ", "))
	end
end

-- Tabs across the top like the Forever spellbook: Blizzard's own tab frame, its glow when chosen,
-- the icon in the frame's window, and their feet on the page edge.
local TAB_W, TAB_H, TAB_GAP = 43, 37, 2
local function CreateBookTab(holder, pane, token, index)
	local tab = CreateFrame("CheckButton", nil, holder)
	tab:SetSize(TAB_W, TAB_H)
	-- Above everything: the inset's own background would otherwise cover their feet and take clicks.
	tab:SetPoint("BOTTOMLEFT", pane, "TOPLEFT", 2 + INDENT + (index - 1) * (TAB_W + TAB_GAP), 10)
	tab:SetFrameLevel(pane:GetFrameLevel() - 1)
	local art = SpellBookArt()
	local back = tab:CreateTexture(nil, "BACKGROUND")
	back:SetPoint("TOPLEFT", 4, -3)
	back:SetPoint("BOTTOMRIGHT", -4, 0)
	back:SetColorTexture(0.02, 0.02, 0.02, 1)
	local icon = tab:CreateTexture(nil, "ARTWORK")
	-- Square, running to the bottom of the tab, as the spellbook's; the frame art draws over its edges.
	icon:SetPoint("TOP", 0, -4)
	icon:SetSize(TAB_W - 10, TAB_W - 10)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	MaskIcon(tab, icon, back)
	if token == "HISTORY" then
		icon:SetTexture(ICON)
	elseif token == "COMMON" then
		icon:SetTexture("Interface\\Icons\\INV_Misc_Food_15")
	elseif token == "ITEMS" then
		icon:SetTexture("Interface\\Icons\\INV_Potion_54")
	elseif token == "PVE" then
		icon:SetTexture("Interface\\Icons\\INV_Misc_Head_Dragon_01")
	elseif CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[token] then
		icon:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
		local c = CLASS_ICON_TCOORDS[token]
		icon:SetTexCoord(c[1], c[2], c[3], c[4])
	else
		icon:SetTexture("Interface\\Icons\\ClassIcon_" .. token:sub(1, 1) .. token:sub(2):lower())
	end
	tab.icon = icon
	if art and art.tab then
		tab.frameTex = tab:CreateTexture(nil, "OVERLAY")
		tab.frameTex:SetAllPoints()
		tab.frameTex:SetAtlas(art.tab)
		if art.tabActiveGlow then
			tab.glow = tab:CreateTexture(nil, "OVERLAY", nil, -1)
			tab.glow:SetPoint("TOPLEFT", 0, 1)
			tab.glow:SetPoint("BOTTOMRIGHT", 0, 0)
			tab.glow:SetAtlas(art.tabActiveGlow)
			tab.glow:Hide()
		end
		ns.report["book tab art"] = "spellbook atlas " .. art.tab
	else
		-- Plain fallback: dark bevel, gold frame when chosen.
		local okb, bevel = pcall(CreateFrame, "Frame", nil, tab, "BackdropTemplate")
		if okb and bevel and bevel.SetBackdrop then
			bevel:SetAllPoints()
			bevel:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 8 })
			bevel:SetBackdropBorderColor(0.45, 0.4, 0.33)
			bevel:EnableMouse(false)
			tab.bevel = bevel
		end
		local ok, sel = pcall(CreateFrame, "Frame", nil, tab, "BackdropTemplate")
		if ok and sel and sel.SetBackdrop then
			sel:SetAllPoints()
			sel:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 9 })
			sel:SetBackdropBorderColor(1, 0.85, 0.1)
			sel:SetFrameLevel(tab:GetFrameLevel() + 2)
			sel:EnableMouse(false)
			tab.sel = sel
		end
		ns.report["book tab art"] = "plain"
	end
	tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	local glowTex = tab:GetHighlightTexture()
	if glowTex then glowTex:ClearAllPoints() glowTex:SetAllPoints(icon) end
	tab.SetChosen = function(self, on)
		if self.frameTex then self.frameTex:SetAtlas((on and art.tabActive) or art.tab) end
		if self.glow then self.glow:SetShown(on) end
		if self.sel then self.sel:SetShown(on) end
		if self.bevel then self.bevel:SetShown(not on) end
		self.icon:SetAlpha(on and 1 or 0.85)
	end
	tab:SetChosen(false)
	tab:SetScript("OnClick", function(self)
		self:SetChecked(false)
		book.tab, book.page = token, 1
		if searchBox then searchBox:SetText("") searchBox:ClearFocus() end
		if PlaySound and SOUNDKIT and SOUNDKIT.IG_ABILITY_PAGE_TURN then pcall(PlaySound, SOUNDKIT.IG_ABILITY_PAGE_TURN) end
		UI:RefreshHistory()
	end)
	tab:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if token == "HISTORY" then
			GameTooltip:SetText("Ledger", 1, 1, 1)
			GameTooltip:AddLine("Every buff and debuff that has been on you.", nil, nil, nil, true)
		elseif token == "COMMON" then
			GameTooltip:SetText("Common", 1, 1, 1)
			GameTooltip:AddLine("Food, drink and the usual lockout debuffs.", nil, nil, nil, true)
		elseif token == "ITEMS" then
			GameTooltip:SetText("Items", 1, 1, 1)
			GameTooltip:AddLine("Flasks, elixirs, potions, scrolls, world buffs and trinket effects.", nil, nil, nil, true)
		elseif token == "PVE" then
			GameTooltip:SetText("Dungeons and raids", 1, 1, 1)
			GameTooltip:AddLine("Buffs and debuffs that mobs and bosses put on you, with where they come from.", nil, nil, nil, true)
		else
			GameTooltip:SetText(ClassLabel(token), 1, 1, 1)
			GameTooltip:AddLine("Buffs this class can cast.", nil, nil, nil, true)
		end
		GameTooltip:Show()
	end)
	tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return tab
end

-- ---- Layout tree ---------------------------------------------------
local SHOW_TAG = { active = "active", missing = "missing", always = "always" }

local function CreateTreeRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row.sel = row:CreateTexture(nil, "BACKGROUND")
	row.sel:SetAllPoints()
	if PARCHMENT then row.sel:SetColorTexture(0.45, 0.25, 0.05, 0.22) else row.sel:SetColorTexture(1, 0.82, 0, 0.18) end
	row.sel:Hide()
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(18, 18)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	-- The spellbook's icon frame over the icon, scaled to the row, and its rounded mask.
	local art = SpellBookArt()
	if art and art.iconFrame then
		row.frame = row:CreateTexture(nil, "OVERLAY")
		row.frame:SetAtlas(art.iconFrame)
		row.frame:SetSize(23, 22)
		row.frame:SetPoint("CENTER", row.icon, "CENTER", -1.4, -0.9)
		MaskIcon(row, row.icon)
	end
	row.text = Ink(row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
	-- Remove: a small red X on tracker rows. First click arms it (a small bubble above the X asks),
	-- second click within three seconds removes.
	local x = CreateFrame("Button", nil, row)
	x:SetSize(16, 16)
	x:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	if HasAtlas("RedButton-Exit") and x.SetNormalAtlas then
		x:SetNormalAtlas("RedButton-Exit")
		if HasAtlas("RedButton-exit-pressed") then x:SetPushedAtlas("RedButton-exit-pressed") end
		if HasAtlas("RedButton-Highlight") then x:SetHighlightAtlas("RedButton-Highlight") end
	else
		x:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
		x:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	end
	x:SetFrameLevel(row:GetFrameLevel() + 2)
	x:Hide()
	-- On a tracker row it removes the tracker; on a group row it deletes the group and everything in it.
	x:SetScript("OnClick", function(self)
		local item = row.item
		if not item then return end
		local subject = item.t or item.g
		if row.armed and GetTime() - row.armed < 3 and row.armedFor == subject then
			row.armed = nil
			UI:HideConfirmBubble()
			if item.t then ns.RemoveTracker(item.t) else ns.DeleteGroup(item.g) end
		else
			row.armed, row.armedFor = GetTime(), subject
			local what = item.t and ("Remove " .. (item.t.name or "this tracker") .. "?")
				or ("Delete group " .. ns.GroupName(item.g) .. " and its " .. #item.g.trackers .. " tracker" .. (#item.g.trackers == 1 and "" or "s") .. "?")
			UI:ShowConfirmBubble(self, what, "Click the X again")
			C_Timer.After(3.2, function()
				if row.armed and GetTime() - row.armed >= 3 then row.armed = nil UI:HideConfirmBubble(self) end
			end)
		end
	end)
	x:SetScript("OnEnter", function(self)
		if row.plated then row.hl:SetAlpha(1) else row.hl:Show() end
		if row.item and row.item.t then
			TextTooltip(self, "Remove this tracker", "Click twice to remove it. The group is removed too if it was the last tracker in it.")
		else
			TextTooltip(self, "Delete this group", "Click twice to delete the group and every tracker in it.")
		end
	end)
	x:SetScript("OnLeave", function() if row.plated then row.hl:SetAlpha(0.3) else row.hl:Hide() end GameTooltip:Hide() end)
	row.remove = x
	row.text:SetJustifyH("LEFT")
	row.text:SetWordWrap(false)
	-- Kept under the text: a HIGHLIGHT-layer texture would draw over it and blank the row.
	local hl = row:CreateTexture(nil, "BACKGROUND", nil, 2)
	hl:SetAllPoints()
	if PARCHMENT and HasAtlas("spellbook-item-backplate") then
		hl:SetAtlas("spellbook-item-backplate")
		hl:SetAlpha(0.3)
		row.plated = true
	else
		SetRowHighlight(hl)
		hl:Hide()
	end
	row.hl = hl
	row:SetScript("OnClick", function(self)
		local item = self.item
		if not item then return end
		ns.selected = { group = item.g, tracker = item.t }
		UI:ShowSelection()
	end)
	row:SetScript("OnEnter", function(self)
		if self.plated then self.hl:SetAlpha(1) else self.hl:Show() end
		local item = self.item
		if not item then return end
		local cond = ns.CondSummary(item.t and item.t.cond or item.g.cond)
		TextTooltip(self, item.t and (item.t.name or ("Spell " .. tostring(item.t.id))) or ns.GroupName(item.g),
			item.t and ("Shows when " .. (SHOW_TAG[item.t.show] or "active")) or (#item.g.trackers .. " tracker" .. (#item.g.trackers == 1 and "" or "s")),
			cond ~= "" and ("Only: " .. cond) or nil,
			item.t and "|cffaaaaaaDrag: onto a group or tracker to move it, onto empty space for a group of its own, or out onto the screen.|r" or nil)
	end)
	row:SetScript("OnLeave", function(self) if self.plated then self.hl:SetAlpha(0.3) else self.hl:Hide() end GameTooltip:Hide() end)
	-- Trackers can be dragged: onto a group heading (join it), onto a tracker (before or after it),
	-- onto empty list space (a group of its own), or out of the window (onto the screen).
	row:RegisterForDrag("LeftButton")
	row:SetScript("OnDragStart", function(self)
		local item = self.item
		if not item or not item.t then return end
		self.dragging = item
		GameTooltip:Hide()
		ns.Display:BeginGhost(item.t.icon, "New group here", nil, "|cff40ff60Drop on a group or tracker, or on empty space for a new group|r", item.t)
	end)
	row:SetScript("OnDragStop", function(self)
		local item = self.dragging
		self.dragging = nil
		if not item then return end
		local t = item.t
		local from = ns.FindGroupOf(t)
		if not from then ns.Display:EndGhost() return end
		local _, cursorY = ns.Display.CursorUI()
		local listGroup, listIndex, kind, overT = UI:TreeDropAt(cursorY)
		local cancelled, cx, cy, screenGroup, index = ns.Display:EndGhost()
		if kind == "before" or kind == "after" then
			if overT ~= t then ns.MoveTracker(t, listGroup, listIndex) end
		elseif kind == "group" then
			if listGroup ~= from or #from.trackers > 1 then ns.MoveTracker(t, listGroup) end
		elseif kind == "new" or cancelled then
			if #from.trackers > 1 then ns.MoveTracker(t, ns.NewGroupLike(from)) end
		elseif screenGroup then
			ns.MoveTracker(t, screenGroup, index)
		else
			if #from.trackers > 1 then ns.MoveTracker(t, ns.NewGroupLike(from, cx - 18, cy + 18))
			else from.x, from.y = cx - 18, cy + 18 ns.Display:Rebuild() end
		end
		ns.selected = { group = ns.FindGroupOf(t), tracker = t }
		UI:ShowSelection()
	end)
	return row
end

-- Where a drop into the Groups and trackers list would land. Returns the group, the position in
-- it, what kind of drop it is ("group", "before", "after", "new") and the tracker under the
-- cursor. Nil when the cursor is not over the list at all.
function UI:TreeDropAt(cy)
	if not (frame and frame:IsShown() and treeList and treeList.scroll) then return nil end
	if not treeList.scroll:IsShown() then return nil end
	for _, r in ipairs(treeList.rows) do
		if r:IsShown() and r.item and r:IsMouseOver() then
			if r.item.t then
				local g = r.item.g
				local at = 1
				for i, other in ipairs(g.trackers) do if other == r.item.t then at = i break end end
				local _, rowCy = r:GetCenter()
				local s = r:GetEffectiveScale() / UIParent:GetEffectiveScale()
				local after = rowCy and cy and cy < rowCy * s
				return g, after and (at + 1) or at, after and "after" or "before", r.item.t
			end
			return r.item.g, nil, "group"
		end
	end
	if treeList.scroll:IsMouseOver() then return nil, nil, "new" end
	return nil
end

-- What the drag label should say while the cursor is over the window.
function UI:TreeDropLabel(cy, dragT)
	local g, _, kind, overT = UI:TreeDropAt(cy)
	if kind == "group" then
		return "|cff40ff60Add to " .. ns.GroupName(g) .. "|r"
	elseif kind == "before" or kind == "after" then
		if overT == dragT then return "|cffaaaaaaLeave it where it is|r" end
		local name = overT and (overT.label or overT.name) or "that tracker"
		return "|cff40ff60" .. (kind == "after" and "After " or "Before ") .. name .. "|r"
	elseif kind == "new" then
		return "|cff40ff60Drop here for a new group|r"
	end
	return nil
end

local function UpdateTreeRow(row, item)
	row.item = item
	row.icon:ClearAllPoints()
	row.text:ClearAllPoints()
	if item.t then
		local t = item.t
		row.icon:SetPoint("LEFT", 20, 0)
		row.icon:SetTexture(t.icon or ns.QUESTION)
		row.icon:Show()
		if row.frame then row.frame:Show() end
		row.text:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
		row.text:SetPoint("RIGHT", -24, 0)
		local off = t.cond and t.cond.never
		local _, dimC, offC = InkCodes()
		row.text:SetText((off and offC or "") .. (t.name or ("Spell " .. tostring(t.id)))
			.. "  " .. dimC .. (off and "off" or (SHOW_TAG[t.show] or "active")) .. (t.unit == "target" and ", target" or "") .. "|r")
		row.remove:Show()
		row.sel:SetShown(SelectedTracker() == t)
	else
		local g = item.g
		row.icon:Hide()
		if row.frame then row.frame:Hide() end
		row.remove:Show()
		row.text:SetPoint("LEFT", 6, 0)
		row.text:SetPoint("RIGHT", -24, 0)
		local off = g.cond and g.cond.never
		local groupC, dimC, offC = InkCodes()
		row.text:SetText((off and offC or groupC) .. ns.GroupName(g) .. "|r  " .. dimC
			.. (off and "off" or ((g.live and g.live ~= "") and "game-drawn" or (g.style == "bars" and "bars" or "icons"))) .. "|r")
		row.sel:SetShown(SelectedGroup() == g and not SelectedTracker())
	end
end

function UI:RefreshTree()
	if UI.HideConfirmBubble then UI:HideConfirmBubble() end
	if not frame or not frame:IsShown() then return end
	local data = {}
	for _, g in ipairs(ns.profile.groups) do
		data[#data + 1] = { g = g }
		for _, t in ipairs(g.trackers) do data[#data + 1] = { g = g, t = t } end
	end
	treeList:SetData(data)
	if UI.treeEmpty then UI.treeEmpty:SetShown(#data == 0) end
end

-- ---- Options pane --------------------------------------------------
local function SyncOptions()
	local g, t = SelectedGroup(), SelectedTracker()
	-- A selection can outlive its group (deleted, merged away).
	if g then
		local alive = false
		for _, other in ipairs(ns.profile.groups) do if other == g then alive = true break end end
		if not alive then ns.selected, g, t = nil, nil, nil end
	end
	groupPanel:SetShown(g ~= nil and t == nil)
	trackerPanel:SetShown(t ~= nil)
	emptyText:SetShown(g == nil)
	if t then
		trackerTitle.icon:SetTexture(t.icon or ns.QUESTION)
		trackerTitle.name:SetText(t.name or ("Spell " .. tostring(t.id)))
		local _, dimC = InkCodes()
		trackerTitle.sub:SetText((t.id and ("Spell ID " .. t.id) or "No spell ID known yet") .. "  " .. dimC .. "in " .. ns.GroupName(g) .. "|r")
		trackerBuilder:Sync()
		optionsChild:SetHeight(trackerPanel.height)
	elseif g then
		groupBuilder:Sync()
		optionsChild:SetHeight(groupPanel.height)
	else
		optionsChild:SetHeight(200)
	end
end

function UI:RefreshLayout()
	if not frame or not frame:IsShown() then return end
	self:RefreshTree()
	SyncOptions()
end

function UI:ShowSelection(open)
	if open and frame and not frame:IsShown() then frame:Show() end
	if not frame or not frame:IsShown() then return end
	self:RefreshTree()
	SyncOptions()
	if optionsScroll then optionsScroll:SetVerticalScroll(0) end
	ns.Display:Refresh()
end

local function BuildGroupPanel(width)
	groupPanel = CreateFrame("Frame", nil, optionsChild)
	groupPanel:SetPoint("TOPLEFT")
	groupPanel:SetWidth(width)
	local b = NewBuilder(groupPanel, width)
	groupBuilder = b
	local function G() return SelectedGroup() end
	local function Num(key, fallback) return function() local g = G() return g and (g[key] or fallback) end end
	local function SetNum(key) return function(v) local g = G() if g then g[key] = v GroupChanged() end end end

	local exportG = MakeButton(groupPanel, "Export", 76)
	exportG:SetPoint("TOPRIGHT", -8, b.y - 6)
	exportG:SetScript("OnClick", function()
		local g = G()
		if g then UI:ShowExport(ns.Export(g, "group"), "group " .. ns.GroupName(g)) end
	end)
	exportG:SetScript("OnEnter", function(self) TextTooltip(self, "Export this group", "Gives you a string holding the whole group (its look, conditions and every tracker) to paste elsewhere.") end)
	exportG:SetScript("OnLeave", function() GameTooltip:Hide() end)
	b:Header("Group")
	b:Note("On this client the addon cannot see auras in combat. Addon-drawn trackers update between fights; 'Track in combat' hands the drawing to the game.")
	b:Edit("Name", function() local g = G() return g and g.name or "" end,
		function(text) local g = G() if g then g.name = (text ~= "" and text) or nil GroupChanged() end end)
	b:Cycle("Show as", { { "icons", "Icons with numbers" }, { "bars", "Bars with icons" } },
		function() local g = G() return g and g.style or "icons" end,
		function(v) local g = G() if g then g.style = v if v == "bars" and (g.grow == "RIGHT" or g.grow == "LEFT") then ns.Display:SetGrow(g, "DOWN") end GroupChanged() b:Sync() end end,
		"Icons show the time left as a number on the icon. Bars show an icon, the name and a draining bar.")
	local liveChoices = { { "", "My trackers" } }
	for _, lf in ipairs(ns.LIVE_FILTERS) do liveChoices[#liveChoices + 1] = { lf[1], lf[2] .. " (drawn by the game)" } end
	b:Cycle("Contents", liveChoices,
		function() local g = G() return g and g.live or "" end,
		function(v) local g = G() if g then g.live = (v ~= "" and v) or nil GroupChanged() b:Sync() end end,
		"My trackers: the trackers in this group, drawn by the addon. The other choices hand the group to the game, which draws every aura of that kind on you or on your target and keeps it current in combat, where the addon cannot see auras. Icon size, spacing, icon frame and position are yours; icons, timers and stacks are the game's. Bars, names and per-tracker settings do not apply. Trackers kept in such a group still play their sounds.")
	b:Check("Track in combat (drawn by the game)", function() local g = G() return g and g.gameDrawn or false end,
		function(v) local g = G() if g then g.gameDrawn = v or nil GroupChanged() end end,
		"Off: the addon draws the trackers, and on this client they only update out of combat. On: the game draws each tracker and keeps it right in combat, but it always shows the aura while it is active ('It is missing' behaves like 'Always'), every tracker keeps its cell, and the warn window does not apply. Works for buffs on you and for debuffs on your target; a debuff on you cannot be drawn by spell (use Contents: Debuffs on me), and a target's auras are only re-read in combat when they change.")
	b:Check("Only this group's trackers", function() local g = G() return g and g.liveOnlyMine or false end,
		function(v) local g = G() if g then g.liveOnlyMine = v or nil GroupChanged() end end,
		"For a category group: show only the spells this group's trackers name.")
	b:Cycle("Grow towards", ns.GROWS,
		function() local g = G() return g and g.grow or "RIGHT" end,
		function(v) local g = G() if g then ns.Display:SetGrow(g, v) end end,
		"The direction new trackers are added in. The opposite corner stays where you put it.")
	b:Slider("Icon size", { min = 16, max = 96, step = 1, get = Num("size", 40), set = SetNum("size") })
	b:Slider("Bar width", { min = 80, max = 400, step = 5, get = Num("barW", 190), set = SetNum("barW") })
	b:Slider("Bar height", { min = 12, max = 48, step = 1, get = Num("barH", 22), set = SetNum("barH") })
	b:Slider("Spacing", { min = 0, max = 30, step = 1, get = Num("spacing", 4), set = SetNum("spacing") })
	b:Slider("Trackers per row before wrapping", { min = 1, max = 40, step = 1, get = Num("perRow", 8), set = SetNum("perRow") })
	b:Slider("Scale", { min = 0.5, max = 2.5, step = 0.05, get = Num("scale", 1), set = SetNum("scale"),
		format = function(v) return ("%d%%"):format(floor(v * 100 + 0.5)) end })
	b:Slider("Opacity", { min = 0.1, max = 1, step = 0.05, get = Num("alpha", 1), set = SetNum("alpha"),
		format = function(v) return ("%d%%"):format(floor(v * 100 + 0.5)) end })
	b:Check("Show time left", function() local g = G() return g and g.timers ~= false end,
		function(v) local g = G() if g then g.timers = v GroupChanged() end end)
	b:Check("Show names on bars", function() local g = G() return g and g.names ~= false end,
		function(v) local g = G() if g then g.names = v GroupChanged() end end)
	b:Check("Bar border", function() local g = G() return g and g.border ~= false end,
		function(v) local g = G() if g then g.border = v GroupChanged() end end,
		"The frame drawn around each bar. Untick for bare bars.")
	b:Check("Bar background", function() local g = G() return g and g.background ~= false end,
		function(v) local g = G() if g then g.background = v GroupChanged() end end,
		"The dark plate behind the fill. Untick to see through the empty part of a bar.")
	b:Check("Pocket watch on carried timers", function() local g = G() return g and g.watch ~= false end,
		function(v) local g = G() if g then g.watch = v GroupChanged() end end,
		"In combat the client hides aura details from addons, so timers are carried on from the last clean read. The small watch marks those. Untick to hide it.")
	b:Check("Icon frame", function() local g = G() return g and g.iconFrame ~= false end,
		function(v) local g = G() if g then g.iconFrame = v GroupChanged() end end,
		"The decorative frame around each icon, when the client has one.")

	b:Header("Show this group when")
	b:Conditions(function() local g = G() return g and g.cond end, TrackerChanged)

	b.y = b.y - 8
	b:Note("To delete this group, click the X on its row in the Groups and trackers list twice.")
	groupPanel.height = -b.y
	groupPanel:SetHeight(groupPanel.height)
end

local function BuildTrackerPanel(width)
	trackerPanel = CreateFrame("Frame", nil, optionsChild)
	trackerPanel:SetPoint("TOPLEFT")
	trackerPanel:SetWidth(width)
	local b = NewBuilder(trackerPanel, width)
	trackerBuilder = b
	local function T() return SelectedTracker() end

	do
		-- The same faint backplate the book entries wear, behind the icon and name.
		local art = SpellBookArt()
		if art and art.backplate then
			local plate = trackerPanel:CreateTexture(nil, "BACKGROUND", nil, 1)
			plate:SetAtlas(art.backplate)
			plate:SetPoint("TOPLEFT", trackerPanel, "TOPLEFT", 2, -2)
			plate:SetPoint("BOTTOMRIGHT", trackerPanel, "TOPRIGHT", -8, -50)
			plate:SetAlpha(0.35)
		end
	end
	trackerTitle.icon = trackerPanel:CreateTexture(nil, "ARTWORK")
	trackerTitle.icon:SetSize(36, 36)
	trackerTitle.icon:SetPoint("TOPLEFT", 12, -10)
	trackerTitle.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	-- The spellbook's icon frame and mask, as in the book.
	do
		local art = SpellBookArt()
		if art and art.iconFrame then
			local fr = trackerPanel:CreateTexture(nil, "OVERLAY")
			fr:SetAtlas(art.iconFrame)
			fr:SetSize(46, 43)
			fr:SetPoint("CENTER", trackerTitle.icon, "CENTER", -2.7, -1.8)
			MaskIcon(trackerPanel, trackerTitle.icon)
		end
	end
	trackerTitle.name = Ink(trackerPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"), "head")
	trackerTitle.name:SetPoint("TOPLEFT", trackerTitle.icon, "TOPRIGHT", 8, -1)
	trackerTitle.name:SetPoint("RIGHT", -6, 0)
	trackerTitle.name:SetJustifyH("LEFT")
	trackerTitle.name:SetWordWrap(false)
	trackerTitle.sub = Ink(trackerPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
	trackerTitle.sub:SetPoint("BOTTOMLEFT", trackerTitle.icon, "BOTTOMRIGHT", 8, 1)
	b.y = -46

	local exportT = MakeButton(trackerPanel, "Export", 76)
	exportT:SetPoint("TOPRIGHT", -8, b.y - 6)
	exportT:SetScript("OnClick", function()
		local t = T()
		if t then UI:ShowExport(ns.Export(t, "tracker"), "tracker " .. (t.name or ("spell " .. tostring(t.id)))) end
	end)
	exportT:SetScript("OnEnter", function(self) TextTooltip(self, "Export this tracker", "Gives you a string holding this tracker (its settings, conditions and sounds) to paste elsewhere.") end)
	exportT:SetScript("OnLeave", function() GameTooltip:Hide() end)
	b:Header("Tracker")
	b:Cycle("Show when", { { "active", "It is active" }, { "missing", "It is missing" }, { "always", "Always (red when missing)" } },
		function() local t = T() return t and t.show or "active" end,
		function(v) local t = T() if t then t.show = v TrackerChanged() end end,
		"Active: shows while you have it. Missing: shows only while you do not. Always: shows both ways and turns red while missing. In a group with 'Track in combat', Missing behaves like Always.")
	b:Slider("Warn before it runs out (seconds, 0 = off)", { min = 0, max = 300, step = 1,
		get = function() local t = T() return t and (t.warn or 0) end,
		set = function(v) local t = T() if t then t.warn = (v > 0) and v or nil TrackerChanged() end end,
		format = function(v) return v == 0 and "off" or (v .. "s") end })
	b:Note("With Missing: also shows while the aura has this long or less left, with a red border. With Always: the border turns red that early.")
	b:Cycle("Match by", { { false, "Name (any rank)" }, { true, "Exact spell ID" } },
		function() local t = T() return t and t.matchId and true or false end,
		function(v)
			local t = T()
			if not t then return end
			if v and not t.id then ns.Print("No spell ID is known for this one yet. It is learned the first time the aura is seen.") return end
			if not v and not t.name then ns.Print("No name is known for this spell ID yet. It is learned the first time the aura is seen.") return end
			t.matchId = v
			TrackerChanged()
		end,
		"Each rank of a spell has its own ID, so matching by name is usually what you want.")
	b:Cycle("On", { { "player", "Me" }, { "target", "My target" } },
		function() local t = T() return t and t.unit or "player" end,
		function(v) local t = T() if t then t.unit = (v ~= "player") and v or nil TrackerChanged() end end,
		"Me: the aura on you. My target: the aura on whatever you have targeted, such as your curse on a mob or a buff it cast on itself. A target tracker hides when you have no target. In combat, after you switch targets, the new target's auras are only re-read when they change; out of combat they are re-read at once.")
	b:Cycle("Type", { { "any", "Buff or debuff" }, { "buff", "Buff only" }, { "debuff", "Debuff only" } },
		function() local t = T() return t and t.kind or "any" end,
		function(v)
			local t = T()
			if not t then return end
			t.kind = v
			if v == "debuff" and (t.unit or "player") == "player" then
				t.unit = "target"
				ns.Print("A debuff can only be followed on a target on this client; this tracker now watches your target.")
			end
			TrackerChanged()
			b:Sync()
		end,
		"On this client a debuff on you cannot be followed by spell; debuff trackers watch your target. For every debuff on you, use a group with Contents: Debuffs on me.")
	local limitNote = b:Note("Debuff trackers watch your target: a debuff on you cannot be followed by spell on this client. For every debuff on you use a group with Contents: Debuffs on me.")
	b.syncers[#b.syncers + 1] = function()
		local t = T()
		local shown = t and (t.kind == "debuff" or ((t.unit or "player") == "player" and t.kind ~= "buff"))
		limitNote:SetShown(shown and true or false)
		if t and t.kind == "buff" then
			limitNote:SetText("")
		elseif t and (t.unit or "player") == "player" and t.kind ~= "debuff" then
			limitNote:SetText("Set to 'Buff or debuff' on you: only the buff side can be followed in combat. Set the type to Buff only, or watch your target for a debuff.")
		else
			limitNote:SetText("Debuff trackers watch your target: a debuff on you cannot be followed by spell on this client. For every debuff on you use a group with Contents: Debuffs on me.")
		end
	end
	b:Check("Only when it was cast by me", function() local t = T() return t and t.mine end,
		function(v) local t = T() if t then t.mine = v TrackerChanged() end end,
		"Ignores the same aura when it comes from someone else.")
	b:Edit("Bar label (optional)", function() local t = T() return t and t.label or "" end,
		function(text) local t = T() if t then t.label = (text ~= "" and text) or nil TrackerChanged() end end)

	b:Header("Sounds")
	local soundChoices = { { 0, "None" } }
	local combatSounds = C_UnitAuras and C_UnitAuras.AddAuraSound
	for i, c in ipairs(ns.SOUND_CHOICES) do soundChoices[#soundChoices + 1] = { i, c[1] .. ((combatSounds and c[4]) and " (combat)" or "") } end
	local function SoundCycle(label, key, tip)
		b:Cycle(label, soundChoices,
			function() local t = T() return t and t.snd and t.snd[key] or 0 end,
			function(v)
				local t = T()
				if not t then return end
				t.snd = t.snd or {}
				t.snd[key] = (v > 0) and v or nil
				if not next(t.snd) then t.snd = nil end
				if ns.SyncAuraSounds then ns.SyncAuraSounds() end
				if v > 0 then
					local name, played = ns.PlaySoundChoice(v)
					if not played then ns.Print(name .. " is not available on this client (or sound effects are muted); try the next one.") end
				end
			end, tip .. " Picking one plays it.", 150)
	end
	b:Note("Choices marked (combat) are played by the game itself, so they also fire while the aura is hidden in combat.")
	SoundCycle("When applied", "applied", "Plays when the aura lands.")
	SoundCycle("When it runs out", "removed", "Plays when the aura wears off or is removed.")
	SoundCycle("When the tracker appears", "shown", "Plays when this tracker comes on screen, for whatever reason: the aura landing, going missing, or entering its warn window.")

	b:Header("Show this tracker when")
	b:Note("These add to the group's own conditions.")
	b:Conditions(function() local t = T() return t and t.cond end, TrackerChanged)

	b.y = b.y - 8
	b:Note("To move this tracker to another group, or out into a group of its own, drag it in the Groups and trackers list. To remove it, click the X on its row there twice.")
	trackerPanel.height = -b.y
	trackerPanel:SetHeight(trackerPanel.height)
end

-- ---- Build -----------------------------------------------------------
local function Build()
	PARCHMENT = not ns.db.plainBook and SpellBookArt() ~= nil
	local frameTemplate
	frame, frameTemplate = TryCreateFrame("Frame", "AuraLedgerFrame", UIParent, {
		{ "ButtonFrameTemplate", function(f) return f.Inset ~= nil end },
		{ "BasicFrameTemplateWithInset", function(f) return f.Inset ~= nil end },
		{ "BackdropTemplate" },
	})
	UI.frame = frame
	frame:SetSize(FRAME_W, FRAME_H)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("HIGH")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:SetClampedToScreen(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		if self.SetUserPlaced then self:SetUserPlaced(false) end
		local s = self:GetEffectiveScale() / UIParent:GetEffectiveScale()
		ns.db.window = { x = self:GetLeft() * s, y = self:GetTop() * s }
	end)
	frame:Hide()
	tinsert(UISpecialFrames, "AuraLedgerFrame")

	if frame.SetTitle then frame:SetTitle("Aura Ledger")
	elseif frame.TitleText then frame.TitleText:SetText("Aura Ledger")
	elseif frame.TitleContainer and frame.TitleContainer.TitleText then frame.TitleContainer.TitleText:SetText("Aura Ledger")
	else
		local t = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		t:SetPoint("TOP", 0, -12)
		t:SetText("Aura Ledger")
	end
	if frame.SetPortraitToAsset then frame:SetPortraitToAsset(ICON)
	elseif frame.portrait and SetPortraitToTexture then SetPortraitToTexture(frame.portrait, ICON)
	elseif frame.PortraitContainer and frame.PortraitContainer.portrait then frame.PortraitContainer.portrait:SetTexture(ICON) end

	if not frameTemplate or frameTemplate == "BackdropTemplate" then
		if frame.SetBackdrop then
			frame:SetBackdrop({
				bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
				edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
				tile = true, tileSize = 32, edgeSize = 32,
				insets = { left = 11, right = 12, top = 12, bottom = 11 },
			})
		end
		local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -4, -4)
	end

	local hasBand = frameTemplate == "ButtonFrameTemplate"
	body = CreateFrame("Frame", nil, frame)
	if frame.Inset then
		body:SetPoint("TOPLEFT", frame.Inset, "TOPLEFT", 0, hasBand and 0 or -30)
		body:SetPoint("BOTTOMRIGHT", frame.Inset, "BOTTOMRIGHT", 0, hasBand and 0 or 24)
	else
		body:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -64)
		body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 36)
	end

	-- ---- Add by name or ID: a row at the top of the page (built after the book pane exists) ----
	local addLabel, addBox, addButton
	local function AddFromBox()
		local h, err = ns.AddManual(addBox:GetText())
		if not h then ns.Print(err) return end
		addBox:SetText("")
		addBox:ClearFocus()
		ns.TrackHistory(h)
		UI:RefreshHistory()
		UI:ShowSelection()
		if not h.name then
			ns.Print("Spell " .. tostring(h.id) .. " is tracked by ID. Its name and icon fill in the first time it is seen.")
		elseif not h.icon then
			ns.Print("\"" .. h.name .. "\" is tracked by name. Its icon fills in the first time it is seen.")
		end
	end

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 9)
	hint:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 9)
	hint:SetJustifyH("LEFT")
	hint:SetText("Drag an aura out of the book onto the screen to track it, or into the Groups and trackers list: onto a group to join it, onto a tracker to sit beside it, onto empty space for a group of its own. Drop one tracker on another to group them. Drag a row in the list to move it about.")

	-- ---- Book pane (laid out like the Forever spellbook) ----
	local left = CreateFrame("Frame", nil, body)
	left:SetPoint("TOPLEFT", body, "TOPLEFT", BOOK_X, -LIP)
	left:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", BOOK_X, 0)
	left:SetWidth(BOOK_W)
	left:SetFrameLevel((frame.Inset and frame.Inset:GetFrameLevel() or frame:GetFrameLevel()) + 3)
	book.pane = left
	-- The page atlas is opaque for ~45px above its visible edge. It is drawn on a clipped child
	-- frame and pulled up, so the edge meets the tabs and the padding is cut off.
	-- The page atlas carries its own shaded rim above the paper lip: in the spellbook that rim IS the
	-- dark band under the title bar. So the page starts right under the title bar, uncut, and the
	-- tabs sit on the rim with their feet on the lip.
	local pageHolder = CreateFrame("Frame", nil, frame)
	pageHolder:SetPoint("TOPLEFT", body, "TOPLEFT", -8, RIM - LIP)
	pageHolder:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 8, 0)
	pageHolder:SetFrameLevel((frame.Inset and frame.Inset:GetFrameLevel() or frame:GetFrameLevel()) + 1)
	pageHolder:EnableMouse(false)
	book.pageHolder = pageHolder
	book.pageA = pageHolder:CreateTexture(nil, "BACKGROUND", nil, 2)
	book.pageB = pageHolder:CreateTexture(nil, "BACKGROUND", nil, 2)
	book.pageA:Hide()
	book.pageB:Hide()
	local hasParchment = not ns.db.plainBook and FileExists("Interface\\Spellbook\\Spellbook-Page-1", false)
	if hasParchment then
		-- The classic page is nearly square, as this pane is, so it keeps its proportions.
		book.parchment = left:CreateTexture(nil, "BACKGROUND", nil, 2)
		book.parchment:SetPoint("TOPLEFT", 0, 0)
		book.parchment:SetPoint("BOTTOMRIGHT")
		book.parchment:SetTexture("Interface\\Spellbook\\Spellbook-Page-1")
		book.parchment:SetTexCoord(0.04, 0.96, 0.03, 0.9)
	end
	local dark = left:CreateTexture(nil, "BACKGROUND", nil, 1)
	dark:SetPoint("TOPLEFT", 0, 0)
	dark:SetPoint("BOTTOMRIGHT")
	dark:SetColorTexture(0, 0, 0, 0.42)
	book.dark = dark
	local art = SpellBookArt()
	local onParchment = (art ~= nil) or hasParchment
	if not art then
		ns.report["book page art"] = hasParchment and "Spellbook-Page-1 parchment" or "dark pane"
		if hasParchment then dark:Hide() end
	end
	book.onParchment = onParchment
	local ink = onParchment and { 0.22, 0.1, 0 } or { 1, 0.82, 0 }

	-- Tabs along the top: the ledger, your own class first, then the rest.
	local order = { "HISTORY" }
	local mine = ns.env.class
	if mine and ns.BOOK[mine] then order[#order + 1] = mine end
	for _, token in ipairs(ns.BOOK_ORDER) do
		if token ~= mine then order[#order + 1] = token end
	end
	for index, token in ipairs(order) do book.tabs[token] = CreateBookTab(frame, left, token, index) end

	searchBox = TryCreateFrame("EditBox", "AuraLedgerSearchBox", frame, {
		{ "SearchBoxTemplate", function(f) return f.Instructions ~= nil or f.searchIcon ~= nil end },
		{ "InputBoxTemplate" },
	})
	searchBox:SetSize(220, 20)
	searchBox:SetPoint("BOTTOMRIGHT", body, "TOPRIGHT", -12, 6)
	-- Above the page rim, which reaches up into the band and would otherwise cover the box art.
	searchBox:SetFrameLevel(left:GetFrameLevel() + 1)
	searchBox:SetAutoFocus(false)
	searchBox:HookScript("OnTextChanged", function() book.page = 1 UI:RefreshHistory() end)
	searchBox:HookScript("OnEscapePressed", function(self) self:ClearFocus() end)

	addLabel = left:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	addLabel:SetPoint("TOPLEFT", 26 + INDENT, -22)
	addLabel:SetTextColor(ink[1], ink[2], ink[3])
	addLabel:SetShadowColor(0, 0, 0, onParchment and 0 or 1)
	addLabel:SetText("Add by spell name or ID:")
	addBox = TryCreateFrame("EditBox", "AuraLedgerAddBox", left, { { "InputBoxTemplate" } })
	addBox:SetSize(220, 20)
	addBox:SetPoint("LEFT", addLabel, "RIGHT", 14, 0)
	addBox:SetAutoFocus(false)
	addButton = MakeButton(left, "Add", 60)
	addButton:SetPoint("LEFT", addBox, "RIGHT", 6, 0)
	addButton:SetScript("OnClick", AddFromBox)
	addBox:SetScript("OnEnterPressed", AddFromBox)
	addBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	addButton:SetScript("OnEnter", function(self)
		TextTooltip(self, "Add an aura", "Type a buff or debuff name, a spell ID, or shift-click a spell link into the box. It is added to the ledger and a tracker is placed in the middle of the screen.")
	end)
	addButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Chapter header with the page divider under it.
	book.header = left:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	book.header:SetPoint("TOPLEFT", 26 + INDENT, -62)
	book.header:SetTextColor(ink[1], ink[2], ink[3])
	-- The spellbook's heading: larger, dark ink with a light emboss around it.
	local hf, hs, hflags = book.header:GetFont()
	if hf then book.header:SetFont(STANDARD_TEXT_FONT or hf, 24, "") end
	if onParchment then
		-- Exactly what the spellbook does behind a heading: its list backplate at 65%, no text shadow.
		book.header:SetShadowColor(0, 0, 0, 0)
		if art and art.listPlate then
			local plate = left:CreateTexture(nil, "ARTWORK", nil, -1)
			plate:SetAtlas(art.listPlate)
			plate:SetSize(415, 106)
			plate:SetAlpha(0.65)
			plate:SetPoint("TOPLEFT", book.header, "TOPLEFT", -78, 37)
			book.headerPlate = plate
		end
	else
		book.header:SetShadowColor(0, 0, 0, 1)
	end
	local divider = left:CreateTexture(nil, "ARTWORK")
	divider:SetPoint("TOPLEFT", INDENT + 2, -106)
	divider:SetPoint("TOPRIGHT", -24, -106)
	book.divider = divider
	if FileExists("Interface\\QuestFrame\\UI-HorizontalBreak", false) then
		divider:SetTexture("Interface\\QuestFrame\\UI-HorizontalBreak")
		divider:SetHeight(20)
		divider:SetTexCoord(0, 1, 0, 0.6)
	else
		divider:SetHeight(1)
		divider:SetColorTexture(ink[1], ink[2], ink[3], 0.5)
	end

	local FILTERS = { { "all", "All" }, { "buff", "Buffs" }, { "debuff", "Debuffs" }, { "you", "On you" }, { "target", "On targets" } }
	local SORTS = { { "recent", "Newest first" }, { "name", "By name" }, { "count", "Most seen" } }
	local function CycleButton(choices, get, set, width)
		local b = MakeButton(left, "", width)
		local function Index() for i, c in ipairs(choices) do if c[1] == get() then return i end end return 1 end
		b:SetText(choices[Index()][2])
		b:SetScript("OnClick", function(self)
			local i = Index() % #choices + 1
			set(choices[i][1])
			self:SetText(choices[i][2])
			book.page = 1
			UI:RefreshHistory()
		end)
		return b
	end
	book.sortButton = CycleButton(SORTS, function() return histSort end, function(v) histSort = v end, 108)
	book.sortButton:SetPoint("TOPRIGHT", -20, -64)
	book.filterButton = CycleButton(FILTERS, function() return histFilter end, function(v) histFilter = v end, 78)
	book.filterButton:SetPoint("RIGHT", book.sortButton, "LEFT", -4, 0)

	-- Twelve spell buttons, two columns of six, like a spellbook page.
	local colW = floor((BOOK_W - 44 - INDENT) / 2)
	for i = 1, PER_PAGE do
		local b = CreateBookButton(left, onParchment, art)
		local col, row = (i - 1) % 2, floor((i - 1) / 2)
		b:SetPoint("TOPLEFT", 22 + INDENT + col * colW, -122 - row * 64)
		b:Hide()
		book.buttons[i] = b
	end
	-- Dresses the book in the spellbook's atlases. Runs now, and again when Blizzard loads the
	-- spellbook later (opening it), which is when the exact divider and icon frame names appear.
	function UI:ApplyBookArt()
		if UI.CopySpellbookMiniArt then UI:CopySpellbookMiniArt() end
		-- The page's headers and entries only exist once the book has been opened: record them then.
		if UI.DumpPlayerSpells then pcall(UI.DumpPlayerSpells) end
		bookArt = nil
		local a = SpellBookArt()
		if not a then return false end
		if book.parchment then book.parchment:Hide() end
		book.dark:Hide()
		book.pageA:ClearAllPoints()
		book.pageB:ClearAllPoints()
		if a.pageLeft and a.pageRight then
			-- Left page under the book, right page under Groups and Options, spine between them.
			book.pageA:SetPoint("TOPLEFT", pageHolder, "TOPLEFT", 0, 0)
			book.pageA:SetPoint("BOTTOMRIGHT", pageHolder, "BOTTOMLEFT", BOOK_X + BOOK_W + 8, 0)
			book.pageA:SetAtlas(a.pageLeft)
			book.pageA:Show()
			book.pageB:SetPoint("TOPLEFT", pageHolder, "TOPLEFT", BOOK_X + BOOK_W + 8, 0)
			book.pageB:SetPoint("BOTTOMRIGHT", pageHolder, "BOTTOMRIGHT", 0, 0)
			book.pageB:SetAtlas(a.pageRight)
			book.pageB:Show()
			book.twoPages = true
		elseif a.page then
			book.pageA:SetAllPoints(pageHolder)
			book.pageA:SetAtlas(a.page)
			book.pageA:Show()
			book.pageB:Hide()
		end
		if a.divider then
			book.divider:SetAtlas(a.divider)
			local info = C_Texture.GetAtlasInfo(a.divider)
			book.divider:SetHeight(info and info.height or 12)
			book.divider:SetTexCoord(0, 1, 0, 1)
		end
		if a.iconFrame then
			-- The spellbook's square frame (51x48) sits a little left and low of the icon: its ribbon.
			for _, b in ipairs(book.buttons) do
				b.slot:Hide()
				if not b.frameTex then
					b.frameShadow = b:CreateTexture(nil, "BORDER", nil, -1)
					b.frameShadow:SetPoint("CENTER", b.icon, "CENTER", -3, -3)
					b.frameTex = b:CreateTexture(nil, "OVERLAY", nil, -1)
					b.frameTex:SetPoint("CENTER", b.icon, "CENTER", -3, -2)
				end
				b.frameTex:SetAtlas(a.iconFrame)
				b.frameTex:SetSize(51, 48)
				b.frameTex:Show()
				if a.iconShadow then
					b.frameShadow:SetAtlas(a.iconShadow)
					b.frameShadow:SetSize(54, 51)
					b.frameShadow:Show()
				end
			end
			ns.report["book slot art"] = "spellbook atlas " .. a.iconFrame
		end
		for _, b in ipairs(book.buttons) do b.onParchment = true end
		book.onParchment = true
		for _, fs in ipairs({ book.header, book.pageText, book.empty }) do
			if fs then fs:SetTextColor(0.22, 0.1, 0) fs:SetShadowColor(0, 0, 0, 0) end
		end
		ns.report["book page art"] = "spellbook atlas " .. tostring(a.page)
		UI:RefreshHistory()
		return true
	end

	book.empty = left:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	book.empty:SetPoint("TOP", INDENT / 2, -190)
	book.empty:SetWidth(BOOK_W - 120)
	book.empty:SetTextColor(ink[1], ink[2], ink[3])
	book.empty:SetShadowColor(0, 0, 0, onParchment and 0 or 1)

	book.next = PageArrow(left, "Next")
	book.next:SetPoint("BOTTOMRIGHT", -22, 14)
	book.next:SetScript("OnClick", function() UI:TurnPage(1) end)
	book.prev = PageArrow(left, "Prev")
	book.prev:SetPoint("RIGHT", book.next, "LEFT", -6, 0)
	book.prev:SetScript("OnClick", function() UI:TurnPage(-1) end)
	book.pageText = left:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	book.pageText:SetPoint("RIGHT", book.prev, "LEFT", -10, 0)
	book.pageText:SetTextColor(ink[1], ink[2], ink[3])
	book.pageText:SetShadowColor(0, 0, 0, onParchment and 0 or 1)
	left:EnableMouseWheel(true)
	left:SetScript("OnMouseWheel", function(_, delta) UI:TurnPage(-delta) end)
	UI:ApplyBookArt()

	-- ---- Layout pane ----
	local mid = Pane(body, "Groups and trackers", BOOK_X + 24 + BOOK_W, BOOK_X + 24 + BOOK_W + TREE_W, LIP + 10)
	-- Import: a small note icon on the heading, in the spellbook's icon frame.
	local importBtn = CreateFrame("Button", nil, mid)
	importBtn:SetSize(20, 20)
	importBtn:SetPoint("TOPRIGHT", mid, "TOPRIGHT", -30, -4)
	importBtn.icon = importBtn:CreateTexture(nil, "ARTWORK")
	importBtn.icon:SetAllPoints()
	importBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
	importBtn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	MaskIcon(importBtn, importBtn.icon)
	do
		local art = SpellBookArt()
		if art and art.iconFrame then
			local fr = importBtn:CreateTexture(nil, "OVERLAY")
			fr:SetAtlas(art.iconFrame)
			fr:SetSize(26, 24)
			fr:SetPoint("CENTER", importBtn.icon, "CENTER", -1.5, -1)
		end
	end
	importBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	importBtn:SetScript("OnClick", function() UI:ShowImport() end)
	importBtn:SetScript("OnEnter", function(self) TextTooltip(self, "Import", "Paste a tracker or group string from someone else, or from another character.") end)
	importBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	treeList = CreateList("AuraLedgerTreeScroll", mid, TREE_ROW, CreateTreeRow, UpdateTreeRow)
	treeList.scroll:SetPoint("TOPLEFT", 4, -(mid.titleHeight or 24))
	treeList.scroll:SetPoint("BOTTOMRIGHT", -24, 4)
	UI.treeEmpty = Ink(mid:CreateFontString(nil, "OVERLAY", "GameFontDisable"), "dim")
	UI.treeEmpty:SetPoint("TOP", 0, -60)
	UI.treeEmpty:SetWidth(TREE_W - 40)
	UI.treeEmpty:SetText("No trackers yet. Drag something out of the book and drop it where you want it.")

	-- ---- Options pane ----
	local right = Pane(body, "Options", BOOK_X + 28 + BOOK_W + TREE_W, nil, LIP + 10)
	local ok, scroll = pcall(CreateFrame, "ScrollFrame", "AuraLedgerOptionsScroll", right, "AuraLedgerScrollFrameTemplate")
	if not (ok and scroll) then
		scroll = CreateFrame("ScrollFrame", "AuraLedgerOptionsScroll", right)
		scroll:EnableMouseWheel(true)
		scroll:SetScript("OnMouseWheel", function(self, delta)
			local range = self:GetVerticalScrollRange() or 0
			self:SetVerticalScroll(max(0, min(range, (self:GetVerticalScroll() or 0) - delta * 40)))
		end)
	end
	optionsScroll = scroll
	scroll:SetPoint("TOPLEFT", 4, -(right.titleHeight or 24))
	scroll:SetPoint("BOTTOMRIGHT", -24, 4)
	optionsChild = CreateFrame("Frame", nil, scroll)
	local optionsWidth = FRAME_W - (BOOK_X + 28 + BOOK_W + TREE_W) - 44 - 50
	optionsChild:SetSize(optionsWidth, 200)
	scroll:SetScrollChild(optionsChild)
	emptyText = Ink(optionsChild:CreateFontString(nil, "OVERLAY", "GameFontDisable"), "dim")
	emptyText:SetPoint("TOP", 0, -60)
	emptyText:SetWidth(optionsWidth - 40)
	emptyText:SetText("Pick a group or a tracker in the middle list, or click one on the screen.")
	BuildGroupPanel(optionsWidth)
	BuildTrackerPanel(optionsWidth)

	-- ---- Minimize: full -> groups and trackers only -> header bar only ----
	UI.parts = { book = left, options = right, tree = mid, toolbar = { searchBox, hint } }
	for _, tab in pairs(book.tabs) do UI.parts.toolbar[#UI.parts.toolbar + 1] = tab end
	local MiniButton, StepMode
	function UI.UseFallbackMini()
		if UI.miniButton then return end
		if UI.mmFrame then UI.mmFrame:Hide() end
		local mini = MiniButton(frame, false)
		mini:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -2)
		local above = frame.CloseButton or frame
		mini:SetFrameStrata(above:GetFrameStrata())
		mini:SetFrameLevel((above:GetFrameLevel() or frame:GetFrameLevel()) + 1)
		mini:SetScript("OnClick", function(_, button) StepMode(button == "RightButton" and -1 or 1) end)
		mini:SetScript("OnEnter", function(self)
			TextTooltip(self, "Minimize", "Click: shrink to the next size (groups and trackers only, then the header bar only).", "Right-click: grow again.")
		end)
		mini:SetScript("OnLeave", function() GameTooltip:Hide() end)
		UI.miniButton = mini
		ns.report["minimize button art"] = (ns.report["minimize button art"] or "?") .. " -> fallback button"
	end
	MiniButton = function(parent, expand)
		local b = CreateFrame("Button", nil, parent)
		b:SetSize(22, 22)
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		-- The client's red condense / expand buttons (the classic UI-Panel-HideButton file exists here but
		-- draws nothing), else a framed text button that cannot go invisible.
		local atlas = expand and "RedButton-Expand" or "RedButton-Condense"
		if HasAtlas(atlas) and b.SetNormalAtlas then
			b:SetNormalAtlas(atlas)
			if HasAtlas(atlas .. "-Pressed") then b:SetPushedAtlas(atlas .. "-Pressed") end
			if HasAtlas("RedButton-Highlight") then b:SetHighlightAtlas("RedButton-Highlight") end
			ns.report["minimize button art"] = atlas
		else
			local okb, box = pcall(CreateFrame, "Frame", nil, b, "BackdropTemplate")
			if okb and box and box.SetBackdrop then
				box:SetAllPoints()
				box:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 8, edgeSize = 8, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
				box:SetBackdropBorderColor(1, 0.82, 0)
			end
			local t = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
			t:SetPoint("CENTER", 0, expand and 0 or 2)
			t:SetText(expand and "+" or "-")
			b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
			ns.report["minimize button art"] = "framed text"
		end
		return b
	end
	local MODES = { "full", "compact", "collapsed" }
	local MODE_NAMES = { full = "Full window", compact = "Groups and trackers only", collapsed = "Header bar only" }
	local function ModeIndex(m) for i, v in ipairs(MODES) do if v == m then return i end end return 1 end

	-- The header-only state: a small bar built from scalable pieces (the window's own rock background
	-- inside a gold border), the title centred left of its two buttons, the buttons inside the bar.
	local strip = CreateFrame("Frame", "AuraLedgerHeaderBar", UIParent)
	strip:SetSize(320, 34)
	strip:SetFrameStrata("HIGH")
	strip:SetMovable(true)
	strip:EnableMouse(true)
	strip:SetClampedToScreen(true)
	strip:RegisterForDrag("LeftButton")
	strip:SetScript("OnDragStart", function(self) self:StartMoving() end)
	strip:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() if self.SetUserPlaced then self:SetUserPlaced(false) end end)
	strip:Hide()
	tinsert(UISpecialFrames, "AuraLedgerHeaderBar")
	do
		local rock = strip:CreateTexture(nil, "BACKGROUND")
		rock:SetPoint("TOPLEFT", 3, -3)
		rock:SetPoint("BOTTOMRIGHT", -3, 3)
		local srcBg = frame.Bg
		local okA, bgAtlas = pcall(function() return srcBg and srcBg:GetAtlas() end)
		if okA and bgAtlas and bgAtlas ~= "" then rock:SetAtlas(bgAtlas)
		elseif srcBg and srcBg:GetTexture() then rock:SetTexture(srcBg:GetTexture()) rock:SetHorizTile(true) rock:SetVertTile(true)
		else rock:SetColorTexture(0.12, 0.11, 0.1, 1) end
		local streaks = strip:CreateTexture(nil, "BORDER")
		streaks:SetAllPoints(rock)
		if HasAtlas("_UI-Frame-TopTileStreaks") then streaks:SetAtlas("_UI-Frame-TopTileStreaks") streaks:SetHorizTile(true) else streaks:Hide() end
		local ok = pcall(function()
			local bd = CreateFrame("Frame", nil, strip, "BackdropTemplate")
			bd:SetAllPoints()
			bd:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
			bd:SetBackdropBorderColor(0.85, 0.65, 0.25)
			bd:EnableMouse(false)
		end)
		ns.report["header bar art"] = ok and "rock + gold border" or "rock"
	end
	local stripTitle = strip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	stripTitle:SetPoint("LEFT", 14, 0)
	stripTitle:SetPoint("RIGHT", strip, "RIGHT", -66, 0)
	stripTitle:SetJustifyH("CENTER")
	stripTitle:SetText("Aura Ledger")
	UI.strip = strip

	local function PlaceStripAtFrame()
		local s = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
		local l, r, t = frame:GetLeft(), frame:GetRight(), frame:GetTop()
		if not (l and r and t) then return end
		strip:ClearAllPoints()
		strip:SetPoint("TOP", UIParent, "BOTTOMLEFT", (l + r) / 2 * s, t * s)
	end
	local function PlaceFrameAtStrip()
		local s = strip:GetEffectiveScale() / UIParent:GetEffectiveScale()
		local l, r, t = strip:GetLeft(), strip:GetRight(), strip:GetTop()
		if not (l and r and t) then return end
		frame:ClearAllPoints()
		frame:SetPoint("TOP", UIParent, "BOTTOMLEFT", (l + r) / 2 * s, t * s)
		local fs = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
		if frame:GetLeft() then ns.db.window = { x = frame:GetLeft() * fs, y = frame:GetTop() * fs } end
	end

	function UI:SetMode(mode)
		if not MODE_NAMES[mode] then mode = "full" end
		ns.db.windowMode = mode
		if mode ~= "collapsed" then ns.db.openMode = mode end
		local p = UI.parts
		if mode == "collapsed" then
			if frame:IsShown() then PlaceStripAtFrame() end
			UI.switching = true
			frame:Hide()
			UI.switching = false
			strip:Show()
			return
		end
		-- Compact keeps Groups and Options at full height and drops only the book.
		local compact = mode == "compact"
		p.book:SetShown(not compact)
		for _, w in ipairs(p.toolbar) do w:SetShown(not compact) end
		-- Compact keeps the right page only: it slides over to cover the smaller window.
		if book.twoPages then
			book.pageA:SetShown(not compact)
			book.pageB:ClearAllPoints()
			book.pageB:SetPoint("TOPLEFT", book.pageHolder, "TOPLEFT", compact and 0 or (BOOK_X + BOOK_W + 8), 0)
			book.pageB:SetPoint("BOTTOMRIGHT", book.pageHolder, "BOTTOMRIGHT", 0, 0)
		end
		local bookSpan = compact and 0 or (BOOK_X + BOOK_W + 20)
		p.tree:ClearAllPoints()
		p.tree:SetPoint("TOP", body, "TOP", 0, -LIP - 14)
		p.tree:SetPoint("BOTTOM", body, "BOTTOM", 0, 4)
		p.tree:SetPoint("LEFT", body, "LEFT", bookSpan + 4 + (compact and 20 or 0), 0)
		p.tree:SetPoint("RIGHT", body, "LEFT", bookSpan + 4 + (compact and 20 or 0) + TREE_W, 0)
		p.options:ClearAllPoints()
		p.options:SetPoint("TOP", body, "TOP", 0, -LIP - 14)
		p.options:SetPoint("BOTTOM", body, "BOTTOM", 0, 4)
		p.options:SetPoint("LEFT", body, "LEFT", bookSpan + 8 + (compact and 20 or 0) + TREE_W, 0)
		p.options:SetPoint("RIGHT", body, "RIGHT", -4, 0)
		frame:SetSize(FRAME_W - (BOOK_X + BOOK_W), FRAME_H)
		if not compact then frame:SetSize(FRAME_W, FRAME_H) end
		if strip:IsShown() then
			PlaceFrameAtStrip()
			strip:Hide()
		end
		if UI.mmFrame then
			local mm = UI.mmFrame
			local above = frame.CloseButton or frame
			mm:SetFrameStrata(above:GetFrameStrata())
			mm:SetFrameLevel((above:GetFrameLevel() or frame:GetFrameLevel()) + 1)
			mm:SetAlpha(1)
			mm:Show()
			mm.MinimizeButton:SetShown(not compact)
			mm.MaximizeButton:SetShown(compact)
			local saved = ns.db.miniArt
			if saved then
				for which, btn in pairs({ minimize = mm.MinimizeButton, maximize = mm.MaximizeButton }) do
					for kind, name in pairs(saved[which] or {}) do
						if type(name) == "string" and btn["Set" .. kind .. "Atlas"] then pcall(btn["Set" .. kind .. "Atlas"], btn, name) end
					end
					btn:SetAlpha(1)
				end
			end
			local shownBtn = compact and mm.MaximizeButton or mm.MinimizeButton
			local nt = shownBtn:GetNormalTexture()
			local okA, atlas = pcall(function() return nt and nt:GetAtlas() end)
			ns.report["minimize button state"] = ("mode %s, widget shown %s level %d strata %s, close level %d, button %s visible %s size %dx%d, art %s"):format(
				mode, tostring(mm:IsVisible()), mm:GetFrameLevel(), tostring(mm:GetFrameStrata()), above:GetFrameLevel() or -1,
				compact and "maximize" or "minimize", tostring(shownBtn:IsVisible()), shownBtn:GetWidth() or 0, shownBtn:GetHeight() or 0, tostring(okA and atlas))
		end
		if not frame:IsShown() then frame:Show() end
		UI:RefreshHistory()
		UI:RefreshLayout()
	end

	StepMode = function(delta)
		local i = ModeIndex(ns.db.windowMode or "full") + delta
		if i > #MODES then i = 1 elseif i < 1 then i = #MODES end
		UI:SetMode(MODES[i])
	end
	-- The spellbook's own maximize / minimize widget when the client has it: the red arrow buttons.
	-- Built in its own guarded step: an error here must not stop the rest of the window being built.
	local okSection, errSection = pcall(function()
	local okm, mm = pcall(CreateFrame, "Frame", nil, frame, "MaximizeMinimizeButtonFrameTemplate")
	if okm and mm and mm.MinimizeButton and mm.MaximizeButton then
		-- Sized to its button and hung off the close button, so the two line up as the spellbook's do.
		if frame.CloseButton then mm:SetPoint("RIGHT", frame.CloseButton, "LEFT", 1, 0)
		else mm:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -2) end
		-- The title bar art (NineSlice) sits at a very high level on this template and would draw over
		-- the widget; the close button lives above it, so the widget goes one level above the close button.
		local above = frame.CloseButton or frame
		mm:SetFrameStrata(above:GetFrameStrata())
		mm:SetFrameLevel((above:GetFrameLevel() or frame:GetFrameLevel()) + 1)
		ns.report["minimize button level"] = ("widget %d, close button %d, frame %d"):format(mm:GetFrameLevel(), above:GetFrameLevel() or -1, frame:GetFrameLevel())
		mm:Show()
		-- Its own click handlers swap the two buttons; ours change the window on top of that.
		local function Wire(btn, mode)
			btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			btn:HookScript("OnClick", function(_, button)
				UI:SetMode(button == "RightButton" and "collapsed" or mode)
			end)
			btn:HookScript("OnEnter", function(self)
				TextTooltip(self, mode == "compact" and "Minimize" or "Maximize",
					mode == "compact" and "Click: groups and trackers only." or "Click: the full window.",
					"Right-click: just the header bar.")
			end)
			btn:HookScript("OnLeave", function() GameTooltip:Hide() end)
		end
		Wire(mm.MinimizeButton, "compact")
		Wire(mm.MaximizeButton, "full")
		mm:SetSize(23, 24)
		for _, btn in ipairs({ mm.MinimizeButton, mm.MaximizeButton }) do
			btn:ClearAllPoints()
			btn:SetPoint("CENTER", mm, "CENTER", 0, 0)
			-- The template sizes its buttons by their edge anchors; with a single anchor they need a size.
			btn:SetSize(23, 24)
		end
		UI.mmFrame = mm
		-- The template's own atlases draw nothing on this client, but the spellbook's copy of the same
		-- widget has art: borrow its textures (once the spellbook has been opened), and remember them.
		local function CopyButtonArt(src, dst)
			local names = {}
			for _, kind in ipairs({ "Normal", "Pushed", "Highlight", "Disabled" }) do
				local st = src["Get" .. kind .. "Texture"](src)
				if st then
					local ok, atlas = pcall(st.GetAtlas, st)
					local file = not (ok and atlas and atlas ~= "") and st:GetTexture() or nil
					if (ok and atlas and atlas ~= "") or file then
						dst["Set" .. kind .. "Texture"](dst, "")
						local dt = dst["Get" .. kind .. "Texture"](dst)
						if dt then
							if atlas and atlas ~= "" then dt:SetAtlas(atlas) else dt:SetTexture(file) end
							local ulx, uly, llx, lly, urx = st:GetTexCoord()
							if ulx and urx and lly then dt:SetTexCoord(ulx, urx, uly, lly) end
							dt:SetAllPoints(dst)
							if st.GetBlendMode and dt.SetBlendMode then dt:SetBlendMode(st:GetBlendMode()) end
							names[kind] = atlas ~= "" and atlas or file
						end
					end
				end
			end
			return names
		end
		local function FindSpellbookMini()
			local root = PlayerSpellsFrame
			if not root or not root.GetChildren then return end
			local function Look(f, depth)
				if depth > 4 or not f.GetChildren then return end
				if f.MinimizeButton and f.MaximizeButton and f ~= mm then return f end
				for _, c in ipairs({ f:GetChildren() }) do
					local hit = Look(c, depth + 1)
					if hit then return hit end
				end
			end
			return Look(root, 0)
		end
		-- A record of the spellbook frame's top levels (keys, textures, atlases), saved with the
		-- settings so the button's real make-up can be read from the file.
		local function DumpPlayerSpells()
			local root = PlayerSpellsFrame
			if not root then ns.db.psDump = { "PlayerSpellsFrame absent" } return end
			local out = {}
			local function KeyOf(parent, child)
				for k, v in pairs(parent) do
					if v == child and type(k) == "string" then return k end
				end
			end
			local function Walk(f, path, depth)
				if depth > 6 then return end
				if f.GetRegions then
					for _, r in ipairs({ f:GetRegions() }) do
						local kind = r.GetObjectType and r:GetObjectType() or "?"
						local what = ""
						if kind == "Texture" or kind == "MaskTexture" then
							local ok, atlas = pcall(r.GetAtlas, r)
							if ok and atlas and atlas ~= "" then what = "atlas " .. atlas else what = "file " .. tostring(r:GetTexture()) end
							local okb, blend = pcall(r.GetBlendMode, r)
							local okv, vr, vg, vb, va = pcall(r.GetVertexColor, r)
							local w, h = r:GetSize()
							what = what .. (" blend %s rgba %.2f %.2f %.2f %.2f alpha %.2f size %dx%d shown %s"):format(
								tostring(okb and blend), okv and vr or 1, okv and vg or 1, okv and vb or 1, okv and va or 1, r:GetAlpha() or 1, w or 0, h or 0, tostring(r:IsShown()))
						elseif kind == "FontString" then
							local okf, font, size, flags = pcall(r.GetFont, r)
							local okc, cr, cg, cb = pcall(r.GetTextColor, r)
							local oks, sr, sg, sb, sa = pcall(r.GetShadowColor, r)
							local oko, ox, oy = pcall(r.GetShadowOffset, r)
							what = ("font %s %s '%s' rgb %.2f %.2f %.2f shadow %.2f %.2f %.2f %.2f off %s,%s text '%s'"):format(
								tostring(okf and font), tostring(okf and size), tostring(okf and flags or ""), okc and cr or 0, okc and cg or 0, okc and cb or 0,
								oks and sr or 0, oks and sg or 0, oks and sb or 0, oks and sa or 0, tostring(oko and ox), tostring(oko and oy), tostring(r:GetText() or ""):sub(1, 30))
						end
						out[#out + 1] = path .. "." .. (KeyOf(f, r) or "?") .. " [" .. kind .. "] " .. what
					end
				end
				if f.GetChildren then
					for _, c in ipairs({ f:GetChildren() }) do
						local key = KeyOf(f, c) or (c.GetName and c:GetName()) or "?"
						local ckind = c.GetObjectType and c:GetObjectType() or "?"
						local extra = ""
						if ckind == "Button" then
							local nt = c:GetNormalTexture()
							if nt then
								local ok, atlas = pcall(nt.GetAtlas, nt)
								extra = " normal=" .. ((ok and atlas and atlas ~= "") and ("atlas " .. atlas) or ("file " .. tostring(nt:GetTexture())))
								local w, h = c:GetSize()
								extra = extra .. (" size %dx%d"):format(w or 0, h or 0)
							end
						end
						out[#out + 1] = path .. "." .. key .. " [" .. ckind .. "]" .. extra
						-- The spellbook page (its headers and items) is walked; the talent tree is not.
						if key ~= "TalentsFrame" then Walk(c, path .. "." .. key, depth + 1) end
					end
				end
			end
			Walk(root, "PlayerSpellsFrame", 0)
			ns.db.psDump = out
		end
		UI.DumpPlayerSpells = DumpPlayerSpells
		function UI:CopySpellbookMiniArt()
			if UI.miniArtCopied then return true end
			pcall(DumpPlayerSpells)
			local src = FindSpellbookMini()
			if not src then return false end
			local a = CopyButtonArt(src.MinimizeButton, mm.MinimizeButton)
			local b = CopyButtonArt(src.MaximizeButton, mm.MaximizeButton)
			if UI.stripExpand then CopyButtonArt(src.MaximizeButton, UI.stripExpand) end
			ns.db.miniArt = { minimize = a, maximize = b }
			UI.miniArtCopied = true
			ns.report["minimize button art"] = "copied from the spellbook: " .. tostring(a.Normal) .. " / " .. tostring(b.Normal)
			return true
		end
		-- Names saved on an earlier session apply straight away.
		local saved = ns.db.miniArt
		if saved and saved.minimize and saved.minimize.Normal then
			for kind, name in pairs(saved.minimize) do
				if type(name) == "string" and mm.MinimizeButton["Set" .. kind .. "Atlas"] then pcall(mm.MinimizeButton["Set" .. kind .. "Atlas"], mm.MinimizeButton, name) end
			end
			for kind, name in pairs(saved.maximize or {}) do
				if type(name) == "string" and mm.MaximizeButton["Set" .. kind .. "Atlas"] then pcall(mm.MaximizeButton["Set" .. kind .. "Atlas"], mm.MaximizeButton, name) end
			end
			ns.report["minimize button art"] = "saved spellbook names: " .. tostring(saved.minimize.Normal)
		end
		UI:CopySpellbookMiniArt()
		ns.report["minimize button art"] = "MaximizeMinimizeButtonFrameTemplate"
		-- If the widget does not actually draw on this client, fall back to a button that does.
		C_Timer.After(1, function()
			local btn = mm.MinimizeButton:IsShown() and mm.MinimizeButton or mm.MaximizeButton
			local w = btn:GetWidth() or 0
			local visible = mm:IsVisible() and btn:IsVisible() and w > 4
			ns.report["minimize button state"] = ("shown %s, button visible %s, width %d"):format(tostring(mm:IsVisible()), tostring(btn:IsVisible()), w)
			if not visible and frame:IsShown() and w <= 4 then UI.UseFallbackMini() end
		end)
	else
		local mini = MiniButton(frame, false)
		if frame.CloseButton then mini:SetPoint("RIGHT", frame.CloseButton, "LEFT", -1, 0)
		else mini:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -4) end
		mini:SetScript("OnClick", function(_, button) StepMode(button == "RightButton" and -1 or 1) end)
		mini:SetScript("OnEnter", function(self)
			TextTooltip(self, "Minimize", "Click: shrink to the next size (groups and trackers only, then the header bar only).", "Right-click: grow again.",
				"|cffaaaaaaNow: " .. MODE_NAMES[ns.db.windowMode or "full"] .. "|r")
		end)
		mini:SetScript("OnLeave", function() GameTooltip:Hide() end)
		UI.miniButton = mini
	end
	end)
	if not okSection then
		ns.report["minimize button art"] = "FAILED: " .. tostring(errSection)
		pcall(UI.UseFallbackMini)
	end

	local expand = MiniButton(strip, true)
	UI.stripExpand = expand
	expand:SetSize(23, 24)
	expand:SetPoint("RIGHT", strip, "RIGHT", -33, 0)
	-- The same red arrow art as the main window, when the client has it.
	if HasAtlas("RedButton-Expand") and expand.SetNormalAtlas then
		expand:SetNormalAtlas("RedButton-Expand")
		if HasAtlas("RedButton-Expand-Pressed") then expand:SetPushedAtlas("RedButton-Expand-Pressed") end
		if HasAtlas("RedButton-Highlight") then expand:SetHighlightAtlas("RedButton-Highlight") end
	end
	expand:SetScript("OnClick", function(_, button) UI:SetMode(button == "RightButton" and "compact" or "full") end)
	expand:SetScript("OnEnter", function(self) TextTooltip(self, "Expand", "Click: the full window.", "Right-click: groups and trackers only.") end)
	expand:SetScript("OnLeave", function() GameTooltip:Hide() end)
	local stripClose
	if HasAtlas("RedButton-Exit") then
		stripClose = CreateFrame("Button", nil, strip)
		stripClose:SetNormalAtlas("RedButton-Exit")
		if HasAtlas("RedButton-exit-pressed") then stripClose:SetPushedAtlas("RedButton-exit-pressed") end
		if HasAtlas("RedButton-Highlight") then stripClose:SetHighlightAtlas("RedButton-Highlight") end
	else
		stripClose = CreateFrame("Button", nil, strip, "UIPanelCloseButton")
	end
	stripClose:SetSize(23, 24)
	stripClose:SetPoint("RIGHT", strip, "RIGHT", -8, 0)
	stripClose:SetScript("OnClick", function() strip:Hide() end)

	frame:SetScript("OnShow", function()
		if ns.db.window and ns.db.window.x then
			frame:ClearAllPoints()
			frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ns.db.window.x, ns.db.window.y)
		end
		UI:SyncToolbar()
		local mode = ns.db.openMode or "full"
		if ns.db.windowMode ~= mode then UI:SetMode(mode) end
		ns.Display:Rebuild()
		UI:RefreshHistory()
		UI:RefreshLayout()
	end)
	frame:SetScript("OnHide", function()
		GameTooltip:Hide()
		ns.Display:Rebuild()
	end)
	-- The ledger's "5m ago" text ages while the window sits open.
	local acc = 0
	frame:SetScript("OnUpdate", function(_, elapsed)
		acc = acc + elapsed
		if acc > 20 then acc = 0 UI:RefreshHistory() end
	end)
end

function UI:SyncToolbar()
end

-- ------------------------------------------------------------------
-- Share window: shows an export string to copy, or takes a pasted one to import.
-- ------------------------------------------------------------------
local share
local function GetShare()
	if share then return share end
	local ok, f = pcall(CreateFrame, "Frame", "AuraLedgerShareFrame", UIParent, "BackdropTemplate")
	if not ok or not f then f = CreateFrame("Frame", "AuraLedgerShareFrame", UIParent) end
	share = f
	f:SetSize(440, 200)
	f:SetFrameStrata("DIALOG")
	f:SetPoint("CENTER")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	if f.SetBackdrop then
		f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } })
	end
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("TOP", 0, -16)
	f.note = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.note:SetPoint("TOP", f.title, "BOTTOM", 0, -4)
	f.note:SetWidth(400)
	local okS, scroll = pcall(CreateFrame, "ScrollFrame", "AuraLedgerShareScroll", f, "AuraLedgerScrollFrameTemplate")
	if not (okS and scroll) then scroll = CreateFrame("ScrollFrame", "AuraLedgerShareScroll", f) end
	scroll:SetPoint("TOPLEFT", 20, -54)
	scroll:SetPoint("BOTTOMRIGHT", -40, 48)
	local boxBg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	boxBg:SetPoint("TOPLEFT", scroll, "TOPLEFT", -4, 4)
	boxBg:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 4, -4)
	boxBg:SetColorTexture(0, 0, 0, 0.5)
	local box = CreateFrame("EditBox", "AuraLedgerShareBox", scroll)
	box:SetMultiLine(true)
	box:SetAutoFocus(false)
	box:SetFontObject("GameFontHighlightSmall")
	box:SetWidth(360)
	box:SetScript("OnEscapePressed", function() f:Hide() end)
	box:SetScript("OnTextChanged", function(self) scroll:UpdateScrollChildRect() end)
	scroll:SetScrollChild(box)
	scroll:EnableMouse(true)
	scroll:SetScript("OnMouseDown", function() box:SetFocus() end)
	f.box = box
	f.action = MakeButton(f, "Import", 100)
	f.action:SetPoint("BOTTOMRIGHT", -20, 16)
	f.action:SetScript("OnClick", function()
		if f.mode ~= "import" then f:Hide() return end
		local g, err = ns.Import(box:GetText())
		if not g then ns.Print(err) f.note:SetText("|cffff5050" .. tostring(err) .. "|r") return end
		f:Hide()
		UI:ShowSelection(true)
		ns.Print("Imported " .. ns.GroupName(g) .. " (" .. #g.trackers .. " tracker" .. (#g.trackers == 1 and "" or "s") .. "). It is placed near the middle of the screen; drag it where you want it.")
	end)
	local close = MakeButton(f, "Close", 80)
	close:SetPoint("RIGHT", f.action, "LEFT", -6, 0)
	close:SetScript("OnClick", function() f:Hide() end)
	tinsert(UISpecialFrames, "AuraLedgerShareFrame")
	return f
end

function UI:ShowExport(text, what)
	local f = GetShare()
	f.mode = "export"
	f.title:SetText("Export " .. what)
	f.note:SetText("Press Ctrl-C to copy the string below, then paste it anywhere (chat, a text file, another character).")
	f.action:SetText("Done")
	f.box:SetText(text)
	f:Show()
	f.box:SetFocus()
	f.box:HighlightText()
end

function UI:ShowImport()
	local f = GetShare()
	f.mode = "import"
	f.title:SetText("Import a tracker or group")
	f.note:SetText("Paste an Aura Ledger string (it starts with !AL1:) into the box and click Import.")
	f.action:SetText("Import")
	f.box:SetText("")
	f:Show()
	f.box:SetFocus()
end

-- A small text bubble above a button, used for the two-click remove.
local bubble
function UI:ShowConfirmBubble(anchor, title, line)
	if not bubble then
		local ok, f = pcall(CreateFrame, "Frame", "AuraLedgerConfirmBubble", UIParent, "BackdropTemplate")
		if not ok or not f then f = CreateFrame("Frame", "AuraLedgerConfirmBubble", UIParent) end
		bubble = f
		f:SetFrameStrata("TOOLTIP")
		f:SetSize(150, 36)
		if f.SetBackdrop then
			f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
			f:SetBackdropColor(0.05, 0.03, 0.02, 0.95)
		end
		f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		f.title:SetPoint("TOP", 0, -6)
		f.title:SetTextColor(1, 0.35, 0.35)
		f.line = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		f.line:SetPoint("TOP", f.title, "BOTTOM", 0, -2)
		f:Hide()
	end
	bubble.title:SetText(title)
	bubble.line:SetText(line)
	bubble:SetWidth(math.max(120, math.max(bubble.title:GetStringWidth() or 0, bubble.line:GetStringWidth() or 0) + 24))
	bubble:ClearAllPoints()
	bubble:SetPoint("BOTTOM", anchor, "TOP", 0, 4)
	bubble.owner = anchor
	bubble:Show()
end

function UI:HideConfirmBubble(anchor)
	if bubble and (not anchor or bubble.owner == anchor) then bubble:Hide() end
end

function UI:Toggle()
	if not frame then return end
	if UI.strip and UI.strip:IsShown() then UI.strip:Hide() return end
	if frame:IsShown() then frame:Hide() else UI:SetMode(ns.db.openMode or "full") end
end

-- ------------------------------------------------------------------
-- Minimap button: left-click window, right-click lock / unlock, drag around the rim.
-- ------------------------------------------------------------------
local mmButton
local function PlaceMinimapButton()
	if not mmButton then return end
	local angle = math.rad(ns.db.minimapAngle or 200)
	local radius = (Minimap:GetWidth() or 140) / 2 + 6
	mmButton:ClearAllPoints()
	mmButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

function UI:UpdateMinimapButton()
	if not Minimap then return end
	if not mmButton then
		if not ns.db.minimapShown then return end
		mmButton = CreateFrame("Button", "AuraLedgerMinimapButton", Minimap)
		mmButton:SetSize(31, 31)
		mmButton:SetFrameStrata("MEDIUM")
		mmButton:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 8)
		mmButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		mmButton:RegisterForDrag("LeftButton")
		mmButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
		local bg = mmButton:CreateTexture(nil, "BACKGROUND")
		bg:SetSize(20, 20)
		bg:SetPoint("TOPLEFT", 7, -5)
		bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
		local icon = mmButton:CreateTexture(nil, "ARTWORK")
		icon:SetSize(18, 18)
		icon:SetPoint("TOPLEFT", 7, -6)
		icon:SetTexture(ICON)
		icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		local border = mmButton:CreateTexture(nil, "OVERLAY")
		border:SetSize(53, 53)
		border:SetPoint("TOPLEFT")
		border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
		mmButton:SetScript("OnClick", function(_, button)
			if button == "RightButton" then
				ns.db.unlocked = not ns.db.unlocked
				ns.Display:Rebuild()
				UI:SyncToolbar()
				ns.Print(ns.db.unlocked and "Trackers unlocked: drag them where you want them." or "Trackers locked.")
			else
				UI:Toggle()
			end
		end)
		mmButton:SetScript("OnDragStart", function(self)
			self:SetScript("OnUpdate", function()
				local mx, my = Minimap:GetCenter()
				local scale = Minimap:GetEffectiveScale()
				local cx, cy = GetCursorPosition()
				if not (mx and my and cx and cy) then return end
				local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
				ns.db.minimapAngle = math.deg(atan2(cy / scale - my, cx / scale - mx)) % 360
				PlaceMinimapButton()
			end)
		end)
		mmButton:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
		mmButton:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:SetText("Aura Ledger", 1, 1, 1)
			GameTooltip:AddLine("Left-click: open the ledger", 0.7, 0.7, 0.7)
			GameTooltip:AddLine("Right-click: lock or unlock trackers", 0.7, 0.7, 0.7)
			GameTooltip:AddLine("Drag: move around the minimap", 0.7, 0.7, 0.7)
			GameTooltip:Show()
		end)
		mmButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	mmButton:SetShown(ns.db.minimapShown)
	PlaceMinimapButton()
end

function UI:Init()
	if frame then return end
	local ok, err = pcall(Build)
	if not ok then
		ns.report["window"] = "FAILED: " .. tostring(err)
		ns.Print("The window could not be built: " .. tostring(err))
	else
		ns.report["window"] = "ok"
	end
	self:UpdateMinimapButton()
end
