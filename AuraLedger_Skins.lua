-- Aura Ledger's pieces in the window styles. Styles.lua does the choosing and the drawing
-- (Blizzard, Dark, or EllesmereUI's look through its public skinning API); this file says what
-- Aura Ledger has to restyle: the ledger window with its book and tabs, the Groups and trackers
-- list, the options, the header bar, and the smaller windows (the log to copy, import and export,
-- tuning, the walk-through, the edit bar, the confirm bubble, the spell list bar).
--
-- Left alone on purpose, in every style:
--   The trackers. Their icons and bars copy the game's Cooldown Manager, measured off its live
--   frames, and in a fight most of them are the game's own slots, which no addon may touch (they
--   are forbidden objects that answer with secret values). Restyling the cells under those slots
--   would show two looks in one group, so nothing here goes near Display.lua's frames.
--   The minimap button, which belongs with the minimap (EllesmereUI's own minimap gathers it).
--   The page under Options > AddOns, which is the game's own Settings panel.
--   The sliders, which neither style has a piece for.
-- Nothing here reads an aura, a cooldown or any game state: only frames this addon built.

local ADDON, ns = ...
local Styles = ns.Styles
local UI = ns.UI
local report = ns.report or {}

local S -- the drawing calls of the style in use, once one is drawn
local pending = {} -- pieces built before that, restyled when it is
local plainBook -- whether the window is built for a drawn style: decided once, when it is built
local titleButtons = {}
local unpack = table.unpack or unpack

local function Log(text)
	if ns.LogLine then ns.LogLine("skin: " .. text) end
end

-- One piece failing must not leave the rest unstyled. Failures show in /auraledger debug, and in
-- the log that /auraledger log hands over.
local function Try(what, fn, ...)
	if not Styles.Try(what, fn, ...) then Log(what .. ": " .. tostring(report["skin error: " .. what])) end
end

-- Now, or as soon as a style is drawn. Nothing on the game's Settings page is touched.
local function Skin(what, fn, ...)
	if UI.inSettings then return end
	if Styles.S then
		S = Styles.S
		Try(what, fn, ...)
	else
		pending[#pending + 1] = { what, fn, select("#", ...), ... }
	end
end

-- The book is drawn on parchment in ink, or on a dark page in light text. A drawn style wants the
-- dark page (EllesmereUI's own spellbook dims the parchment to almost nothing), and the window can
-- only be built one way, so this is asked once, while it is built. Dark is known from the
-- settings; EllesmereUI has normally called back by then (the TOC lists its skin module as an
-- optional dependency, so it loads first). If it ever calls back later, the book keeps its
-- parchment and only the window around it changes.
function ns.SkinPlainBook()
	if plainBook == nil then
		plainBook = Styles.Applied() ~= nil or (type(ns.db) == "table" and ns.db.style == "dark")
	end
	return plainBook
end

-- ---- helpers -------------------------------------------------------------------------------

local function Fonts(...)
	for i = 1, select("#", ...) do
		local fs = select(i, ...)
		if type(fs) == "table" and fs.GetFont then S.Font(fs) end
	end
end

-- Every line of text in a frame, however deep: most of the window's text is made one line at a time.
local function FontsIn(f, depth)
	if type(f) ~= "table" or depth > 12 or not f.GetRegions then return end
	if f.IsForbidden and f:IsForbidden() then return end
	for _, r in ipairs({ f:GetRegions() }) do
		if r.IsObjectType and r:IsObjectType("FontString") then S.Font(r) end
	end
	if f.GetChildren then
		for _, child in ipairs({ f:GetChildren() }) do FontsIn(child, depth + 1) end
	end
end

local function NoBackdrop(f)
	if type(f) == "table" and f.SetBackdrop then pcall(f.SetBackdrop, f, nil) end
end

local function HasArt(b)
	local ok, tex = pcall(b.GetNormalTexture, b)
	return ok and tex ~= nil
end

local function SkinButton(b)
	if type(b) ~= "table" then return end
	S.Button(b)
	S.WhiteButtonLabel(b)
	if b.GetFontString then Fonts(b:GetFontString()) end
end

-- The art a button wears in each state. The minimize buttons get their red art put back whenever
-- the window changes size, so it is taken off again each time.
local function StateArtOff(b)
	for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture", "GetHighlightTexture" }) do
		local tex = b[getter] and b[getter](b)
		if type(tex) == "table" and tex.SetAlpha then tex:SetAlpha(0) end
	end
end

-- A title bar button: a flat block, with a glyph of its own where its art was all it had.
local function TitleButton(b, glyph)
	if type(b) ~= "table" then return end
	if not titleButtons[b] then
		titleButtons[b] = true
		S.Button(b)
		if glyph then
			local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			fs:SetPoint("CENTER", 0, 0)
			fs:SetText(glyph)
			S.Font(fs, 1, 1, 1)
			b.alGlyph = fs
		end
	end
	StateArtOff(b)
end

-- The window backdrop and border. EllesmereUI lays its border over the whole window as a frame of
-- its own, six levels up, so whatever sits on the window's edges is lifted back above it
-- afterwards. Dark draws on the window itself and adds no frame.
local function Shell(win, opts)
	local before = {}
	for _, child in ipairs({ win:GetChildren() }) do before[child] = true end
	S.Shell(win, opts)
	local added = {}
	for _, child in ipairs({ win:GetChildren() }) do
		if not before[child] then added[#added + 1] = child end
	end
	if type(win.Inset) == "table" then S.Inset(win.Inset) end
	-- The book icon in the corner: EllesmereUI's windows have no portrait.
	if type(win.PortraitContainer) == "table" then S.FadeRegions(win.PortraitContainer) end
	if type(win.CloseButton) == "table" then S.CloseButton(win.CloseButton) end
	local title = (type(win.TitleContainer) == "table" and win.TitleContainer.TitleText) or win.TitleText
	if type(title) == "table" then Fonts(title) end
	return added
end

-- Any of the frames passed may be missing (a template that brought no close button), so they are
-- counted with select rather than walked as a list.
local function RaiseOver(win, added, ...)
	local top = (win:GetFrameLevel() or 0) + 6
	for _, child in ipairs(added) do top = math.max(top, child:GetFrameLevel() or 0) end
	local seen = {}
	local function Lift(b)
		if type(b) ~= "table" or seen[b] or not b.SetFrameLevel then return end
		seen[b] = true
		if (b:GetFrameLevel() or 0) <= top then b:SetFrameLevel(top + 1) end
	end
	for i = 1, select("#", ...) do Lift((select(i, ...))) end
	-- And every button straight on the window.
	for _, child in ipairs({ win:GetChildren() }) do
		if child.IsObjectType and child:IsObjectType("Button") then Lift(child) end
	end
end

local function ScrollBarOf(scroll)
	if type(scroll) == "table" and type(scroll.ScrollBar) == "table" then S.ScrollBar(scroll.ScrollBar) end
end

-- A panel to replace the one a backdrop drew, for the floating windows built from BackdropTemplate.
local function Plate(f)
	NoBackdrop(f)
	S.Panel(f)
end

-- ---- pieces built one at a time -------------------------------------------------------------

function ns.SkinFont(fs)
	Skin("text", Fonts, fs)
end

function ns.SkinButton(b)
	Skin("button", SkinButton, b)
end

function ns.SkinCheck(cb)
	Skin("check box", function()
		S.Checkbox(cb)
		Fonts(cb.label)
	end)
end

function ns.SkinEditBox(eb)
	Skin("edit box", function() S.EditBox(eb) end)
end

-- ---- the book's page: dark under a drawn style, as the spellbook's own under EllesmereUI -----
-- On a parchment page (see SkinPlainBook) these leave the spellbook's look alone; once the page has
-- given the parchment up (DropParchment) they are run again over everything on it.

-- A tab of the book: a flat plate with the accent line under the chosen one. A style's tab keeps
-- only the region named as its icon, and draws its own selection, which the book tells it.
local function PageTab(tab)
	if UI.parchment then return end
	if ns.SetIconMask and tab.icon then ns.SetIconMask(tab, tab.icon, false) end
	tab.Icon = tab.icon
	S.Tab(tab)
	-- The spellbook's tabs stand on the parchment's rim, above the page; a flat tab stands on the
	-- dark page's own top edge, touching it.
	if tab.alX and tab.alPane then
		tab:ClearAllPoints()
		tab:SetPoint("BOTTOMLEFT", tab.alPane, "TOPLEFT", tab.alX, 0)
	end
	-- The plain book's own frames round its tabs.
	for _, piece in ipairs({ tab.bevel, tab.sel }) do
		if type(piece) == "table" and piece.SetAlpha then piece:SetAlpha(0) end
	end
	if S.SetTabSelection then S.SetTabSelection(tab, tab.alChosen and true or false) end
end

-- A spell on the book's page: square, with an edge, its ring and the spellbook's frame gone.
local function PageEntry(b)
	if UI.parchment then return end
	if ns.SetIconMask then ns.SetIconMask(b, b.icon, false) end
	for _, piece in ipairs({ b.slot, b.frameTex, b.frameShadow, b.plate }) do
		if type(piece) == "table" and piece.SetAlpha then piece:SetAlpha(0) end
	end
	S.SquareIcon(b.icon, b)
	Fonts(b.name, b.sub)
end

-- A row of the Groups and trackers list. Its icon is hidden on group rows, so it is squared
-- without a border, which would stay behind on its own.
local function PageRow(row)
	Fonts(row.text)
	if UI.parchment then return end
	if ns.SetIconMask then ns.SetIconMask(row, row.icon, false) end
	S.SquareIcon(row.icon)
	if type(row.remove) == "table" then S.CloseButton(row.remove) end
end

-- The page buttons, the Groups and Options panes, the import button.
local function PageParts()
	if UI.parchment then return end
	local book = UI.book or {}
	report["skin book"] = "dark page"
	Try("page buttons", function()
		if type(book.prev) == "table" then S.PageButton(book.prev, "<") end
		if type(book.next) == "table" then S.PageButton(book.next, ">") end
	end)
	Try("panes", function()
		local parts = UI.parts or {}
		for _, pane in ipairs({ parts.tree, parts.options }) do
			if type(pane) == "table" then S.Panel(pane, { inset = true }) end
		end
	end)
	Try("import button", function()
		local b = UI.importButton
		if type(b) ~= "table" or type(b.icon) ~= "table" then return end
		if ns.SetIconMask then ns.SetIconMask(b, b.icon, false) end
		S.SquareIcon(b.icon, b)
	end)
end

-- A style drawn after the window was built (Dark picked over Blizzard, or EllesmereUI calling back
-- late): the page gives its parchment up and everything on it is dressed as if built for the style.
local function DropParchment()
	if not UI:DropParchment() then return end
	local book = UI.book or {}
	for _, tab in pairs(book.tabs or {}) do Try("book tab", PageTab, tab) end
	for _, b in ipairs(book.buttons or {}) do Try("book entry", PageEntry, b) end
	for _, row in ipairs(UI.TreeRows and UI.TreeRows() or {}) do Try("list row", PageRow, row) end
	PageParts()
	if UI.frame then Try("window text", FontsIn, UI.frame, 0) end
	report["skin book"] = "dark page (the parchment was given up when the style was drawn)"
	if UI.RefreshHistory then UI:RefreshHistory() end
	if UI.RefreshLayout then UI:RefreshLayout() end
end

function ns.SkinBookTab(tab)
	Skin("book tab", PageTab, tab)
end

function ns.SkinTabChosen(tab, on)
	S = Styles.S or S
	if S and S.SetTabSelection and not UI.parchment then Try("book tab", S.SetTabSelection, tab, on and true or false) end
end

function ns.SkinBookButton(b)
	Skin("book entry", PageEntry, b)
end

function ns.SkinTreeRow(row)
	Skin("list row", PageRow, row)
end

function ns.SkinTitleBar()
	S = Styles.S or S
	if not S then return end
	Try("title bar buttons", function()
		local mm = UI.mmFrame
		if type(mm) == "table" then
			TitleButton(mm.MinimizeButton, "-")
			TitleButton(mm.MaximizeButton, "+")
		end
		local mini = UI.miniButton
		if type(mini) == "table" then TitleButton(mini, (titleButtons[mini] or HasArt(mini)) and "-" or nil) end
		local help = UI.helpButton
		if type(help) == "table" then
			TitleButton(help)
			if type(help.text) == "table" then S.Font(help.text, 1, 1, 1) end
		end
		local expand = UI.stripExpand
		if type(expand) == "table" then TitleButton(expand, (titleButtons[expand] or HasArt(expand)) and "+" or nil) end
	end)
end

-- ---- the windows ----------------------------------------------------------------------------

local function SkinHeaderBar()
	local strip = UI.strip
	if type(strip) ~= "table" then return end
	S.Panel(strip)
	-- Its gold edge is a backdrop on a frame of its own.
	for _, child in ipairs({ strip:GetChildren() }) do
		if child.GetObjectType and child:GetObjectType() == "Frame" then NoBackdrop(child) end
	end
	if type(UI.stripClose) == "table" then S.CloseButton(UI.stripClose) end
	Fonts(UI.stripTitle)
	FontsIn(strip, 0)
end

local function SkinMainWindow(win)
	local bottom = UI.bottomBar and UI.bottomBar.GetHeight and UI.bottomBar:GetHeight() or 0
	local added = Shell(win, { bottomBar = (bottom > 0) and bottom or true })
	local book = UI.book or {}
	local tabs = {}
	for _, tab in pairs(book.tabs or {}) do tabs[#tabs + 1] = tab end
	RaiseOver(win, added, win.CloseButton, UI.mmFrame, UI.helpButton, UI.miniButton, UI.editButton, UI.searchBox,
		UI.scaleBigger, UI.scaleSmaller, UI.grip, unpack(tabs))
	ns.SkinTitleBar()

	Try("search boxes", function()
		local search = UI.searchBox
		if type(search) == "table" then
			S.EditBox(search)
			-- The magnifier is part of the box's art; it stays.
			if type(search.searchIcon) == "table" then search.searchIcon:SetAlpha(1) end
		end
		if type(UI.addBox) == "table" then S.EditBox(UI.addBox) end
	end)
	Try("scroll bars", function()
		ScrollBarOf(UI.treeScroll)
		ScrollBarOf(UI.optionsScroll)
	end)
	Try("group menu", function()
		if type(book.groupMenu) == "table" then Plate(book.groupMenu) end
	end)
	Try("header bar", SkinHeaderBar)

	if UI.parchment then
		report["skin book"] = "parchment kept: the style was drawn after the window was built, so the pages keep the spellbook look"
	else
		PageParts()
	end
	Try("window text", FontsIn, win, 0)
end

function ns.SkinMainWindow(win)
	Skin("ledger window", SkinMainWindow, win)
end

function ns.SkinCopyWindow(f)
	Skin("log window", function()
		if not f.Inset then NoBackdrop(f) end
		RaiseOver(f, Shell(f), f.CloseButton)
		ScrollBarOf(f.scroll)
		Fonts(f.heading, f.hint)
	end)
end

function ns.SkinShareWindow(f)
	Skin("import and export window", function()
		NoBackdrop(f)
		local added = Shell(f)
		-- The box the string goes in had a dark plate drawn on the window, which the window's art
		-- went with: it gets a panel of its own, just under the box.
		if type(f.scroll) == "table" then
			local plate = CreateFrame("Frame", nil, f)
			plate:SetPoint("TOPLEFT", f.scroll, "TOPLEFT", -4, 4)
			plate:SetPoint("BOTTOMRIGHT", f.scroll, "BOTTOMRIGHT", 4, -4)
			local level = (f:GetFrameLevel() or 0) + 1
			plate:SetFrameLevel(level)
			if (f.scroll:GetFrameLevel() or 0) <= level then f.scroll:SetFrameLevel(level + 1) end
			S.Panel(plate, { inset = true })
			f.alPlate = plate
		end
		RaiseOver(f, added, f.action)
		ScrollBarOf(f.scroll)
		Fonts(f.title, f.note)
	end)
end

function ns.SkinTuner(f)
	Skin("tuning window", function()
		local added = Shell(f)
		local close = f.alClose
		if type(close) == "table" then
			if type(f.CloseButton) == "table" and close ~= f.CloseButton then
				-- The template brings a close button and the panel adds one at the same spot: one
				-- glyph is drawn, the other still closes.
				close:SetAlpha(0)
			else
				S.CloseButton(close)
			end
		end
		RaiseOver(f, added, f.CloseButton, close)
		Fonts(f.alTitle)
		FontsIn(f, 0)
	end)
end

function ns.SkinTourWindow(bubble)
	Skin("walk-through window", function()
		if not bubble.Inset then NoBackdrop(bubble) end
		local added = Shell(bubble)
		if type(bubble.closeButton) == "table" then S.CloseButton(bubble.closeButton) end
		RaiseOver(bubble, added, bubble.CloseButton, bubble.closeButton)
		Fonts(bubble.title, bubble.count, bubble.body)
	end)
end

function ns.SkinEditBar(f)
	Skin("edit bar", function()
		Plate(f)
		Fonts(f.text, f.gridSize, f.gridHint)
	end)
end

function ns.SkinBubble(f)
	Skin("confirm bubble", function()
		Plate(f)
		Fonts(f.title, f.line)
	end)
end

-- The bar on screen while the game's spell list is read: the style's own bar fill.
function ns.SkinProgressBar(bar)
	Skin("spell list bar", function()
		S.ApplyBarFill(bar)
		Fonts(bar.text)
	end)
end


-- ---- choosing the style -------------------------------------------------------------------

-- /auraledger style [auto|blizzard|dark]; on its own it steps to the next one.
function ns.StyleCommand(arg)
	arg = string.lower(arg or "")
	if arg == "auto" or arg == "automatic" then Styles.Set("auto")
	elseif arg == "blizzard" or arg == "dark" then Styles.Set(arg)
	elseif arg == "" then Styles.Cycle(1)
	else
		ns.Print("Styles: auto, blizzard, dark.")
		return
	end
	ns.Print("Window style: " .. Styles.Name(ns.db.style) .. ". " .. Styles.Note())
	if UI.SyncLook then UI:SyncLook() end
end

-- What the trackers wear in a drawn style. Display.lua builds its flat look from this: the style's
-- accent for the bars, its font, a flat bar texture. Dark is known from the settings at login,
-- before it is drawn, so the trackers are made flat from the start; EllesmereUI once it has called back.
function ns.TrackerLook()
	local style = Styles.Applied() or ((type(ns.db) == "table" and ns.db.style == "dark") and "dark" or nil)
	if not style then return nil end
	local from = (style == "eui" and Styles.S) or Styles.Dark
	local r, g, b = (from.GetAccentColor or Styles.Dark.GetAccentColor)()
	local font = from.GetFont and from.GetFont()
	return { name = Styles.Name(style), accent = { r or 1, g or 0.76, b or 0.22 }, font = font, bar = "Interface\\Buttons\\WHITE8X8" }
end

-- Everything built so far, once a style is drawn: Dark once the world is up, EllesmereUI when it
-- calls back, or at once when Dark is picked over Blizzard. A book built on parchment gives it up
-- for the dark page, and the trackers take the flat look.
local function SkinAll(skin, style)
	S = skin
	local list = pending
	pending = {}
	for _, job in ipairs(list) do Try(job[1], job[2], unpack(job, 4, 3 + job[3])) end
	if UI.parchment and UI.DropParchment then Try("book page", DropParchment) end
	if ns.Display and ns.Display.RestyleTrackers then Try("trackers", ns.Display.RestyleTrackers, ns.Display) end
	Log(tostring(style) .. " drawn")
	if UI.SyncLook then Try("look options", UI.SyncLook, UI) end
end

Styles.Setup({
	addon = ADDON,
	title = "Aura Ledger",
	db = function() return ns.db end,
	report = ns.report,
	accent = { 1, 0.76, 0.22 }, -- the gold of the ledger's headings
	skin = SkinAll,
})
