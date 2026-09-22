# Changelog

## 1.18.0

- Trackers drawn by the game. Blizzard's AuraContainer has aura slots: one game-owned frame that shows a single aura matching a spell list, current in combat. A group's new "Trackers drawn by the game" option gives every tracker such a slot (filtered to every rank the ledger knows for it, and to your own casts when "only when cast by me" is on), anchored over the tracker's cell and drawn above the addon's own art. While the aura is on you the game shows the slot; when it is gone the game hides it and the cell shows the addon's "missing" art (or nothing, for "show when active"). So both active and missing trackers stay right in combat, with the game's icon, countdown, swipe, stack count and dispel border, in our bar or icon art. Every tracker keeps its cell, the warn window does not apply, and a tracker the ledger has no spell ID for is drawn by the addon as before. Slots are built out of combat.
- "Only this group's trackers" on a game-drawn category group now uses the real filter (includeSpellIDs) and works.

## 1.17.2

- Game-drawn groups now use the game's real button functions: stack counts (SetApplicationCount), the game's own swipe over the icon (SetDurationCooldown), a dispel-type coloured border (AddDispelTypeTexture), and tooltips stay on in combat.
- "Only this group's trackers" now goes through the container's own SetAuraGroupCandidateFilters, trying the possible shapes in turn and logging each answer.
- /auraledger slot calls the container's slot, filter, sort and layout functions with wrong arguments and prints their error messages, to read what they expect.

## 1.17.1

- Game-drawn groups gain an experimental "Only this group's trackers" switch that asks the game to limit the group to the spells its trackers name. Whether the game honours it is not yet known.
- /auraledger mixin lists the AuraContainer's and its buttons' Lua functions and the keys of every aura container the game itself has on screen, to find the real spell filter if there is one.

## 1.17.0

- Groups drawn by the game. A group's new "Contents" option can hand it to the game: "Debuffs on me", "Debuffs on me I could dispel", "Buffs on me" or "Buffs on me that I cast". The game then draws every aura of that kind on you through its AuraContainer and keeps it current in combat, where the addon cannot see auras; this is how GODMODE_GTFO shows debuffs mid-fight. Icon size, spacing, icons per row, icon frame art, opacity, scale, conditions and position stay yours; the icons, countdowns and stack counts are the game's. Bars, names and per-tracker settings do not apply to such a group. Trackers kept in it still play their sounds. The container is built out of combat; a group switched over during a fight fills in when the fight ends.

## 1.16.0

- Tracker sounds in combat. The "When applied" and "When it runs out" sounds are now registered with the game itself (C_UnitAuras.AddAuraSound), which plays them when that spell's aura is added to you or removed from you, including in combat where the addon cannot see the aura. This covers every rank the ledger has seen under the tracker's name. Sound choices that can be handed to the game are marked "(combat)" in the picker: Soft bells, Raid warning, and the new Ready check, Level up, Alarm clock 1 and 2, Flag taken. The other choices still play out of combat only.
- /auraledger soundtest plays each file sound in turn and reports what the client said, so unavailable files can be spotted. /auraledger debug shows how many aura sounds are registered.
- The probe container from /auraledger container now hides itself after reporting.

## 1.15.2

- Fixed: /auraledger container failed before printing anything (a helper was defined further down the file).
- New: /auraledger api <name> prints the fields of a documented structure, the values of an enum, or the arguments and returns of a function, from Blizzard's own API documentation (run any /api command first so it is loaded).

## 1.15.1

- Longer logs. The chat window now keeps 2000 lines instead of the default 128, every message that reaches the main chat frame (including Blizzard's /api output) is mirrored into the saved variables (1500 lines), and the addon's own log keeps 3000 lines. Both are written on /reload or logout; /auraledger log shows the counts, /auraledger log clear empties them.

## 1.15.0

- While auras are secret, the addon now asks C_UnitAuras.GetUnitAuraInstanceIDs for the instance ids on you. When that list is readable, presence per instance is known in combat: a carried buff whose instance disappears is dropped at once (clicked off, dispelled, or run out), a spell you cast binds to the instance that appears, and instances nothing claims are kept as "Unknown buff" / "Unknown debuff" entries. When the list is hidden, nothing changes.
- /auraledger probe reports the instance id list and the per-instance helpers (expiry, caster, duration object, filter test) with each answer marked plain or secret; /auraledger debug has an "instance ids while restricted" line.

## 1.14.1

- The secret index reads from 1.14.0 are removed: on this client they fail with "Auras cannot be accessed when secret while tainted", so they learned nothing and only raised errors.
- New: /auraledger container builds one of Blizzard's AuraContainer widgets (the way GODMODE_GTFO shows auras in combat) with several group shapes and prints what the container and its buttons expose, in or out of combat.

## 1.14.0

- The aura reader now asks the client for every aura index even while it is marked secret, the way GODMODE_GTFO does on this client. The answer is a table whose fields are hidden, but the table itself and its aura instance id are not, so in combat the addon can see which aura instances are on you. A carried buff whose instance disappears is dropped at once (clicking it off, a dispel, or it running out), a spell you cast binds to the instance that appears, and instances nothing claims are kept as "Unknown buff" / "Unknown debuff" entries.
- /auraledger probe now prints the raw index reads with each field marked plain or secret, and /auraledger debug has a "secret index reads" line.

## 1.13.0

- In combat, Blizzard's Cooldown Manager buff viewers are now read as the present/absent signal. The Cooldown Manager shows an item only while that tracked buff is on you, and neither the item's shown state nor the spell behind it is hidden in combat. A shown item keeps or creates the aura (timer from the ledger), a hidden item drops it, so clicking a buff off or having it dispelled mid-fight now reaches your trackers, for every buff the Cooldown Manager tracks (Demon Skin, Demon Armor, Shadow Ward and the rest of its list). An item that answers as hidden data changes nothing.
- /auraledger cdm now lists the viewer items with their shown state first, and only prints cooldowns that match one of your trackers. /auraledger debug has a Cooldown Manager line.

## 1.12.2

- Diagnostics only. /auraledger debug now describes the aura events received in combat (whether the removed, updated and added lists arrive plain or hidden, and what the last payload looked like), and /auraledger cdm prints what the Cooldown Manager's data reports for each of its spells (hasAura and the aura instance), in or out of combat.

## 1.12.1

- Fixed: the by-spell question added in 1.12.0 answers "nothing" for every aura while the client hides them, so it was dropping buffs that were still up. It is no longer used to decide anything; /auraledger probe still shows what the client answers.
- Your own casts are not hidden in combat. A successful cast of a spell the ledger knows as an aura now creates or refreshes an estimated aura: a buff on you, or a debuff on your target, with the ledger's duration and the pocket watch mark. Reapplying a buff mid-fight clears its "missing" tracker, and a cast like Blood Fury shows its bar for the remembered duration.
- What still cannot be seen in combat: auras put on you by others (a mob's debuff landing, a party member's buff). Those update when combat ends.

## 1.12.0

- In combat, each tracker is now asked about directly by spell (C_UnitAuras.GetAuraDataBySpellName, or GetPlayerAuraBySpellID when matching by id). When the client answers "nothing" the aura is treated as gone; when it answers with an aura (even one whose fields are hidden) the aura is treated as present, with the timer taken from the ledger when the real one is hidden. This runs on every scan while the aura list is unreadable.
- Fixed: the buff frame's icons turn hidden once Blizzard's frame refreshes in combat, and that was being read as "no buffs at all", dropping every carried buff and never picking up a new one. A frame read now only counts when every shown icon could be read.
- New: /auraledger probe shows how the client answers the by-spell question for each tracker right now, in or out of combat. /auraledger debug reports the by-spell counts and the last frame read.

## 1.11.3

- Fixed: icons read from the default buff frame are now compared by file id even when the frame answers with a texture path, so carried buffs are no longer dropped in combat just because the two were written differently.
- New: /auraledger frames prints what the buff and debuff frames are showing right now next to what the addon is carrying, in or out of combat, and /auraledger debug lists the last icons read and why each carried aura was dropped.

## 1.11.2

- Fixed: a tracker with "Only when it was cast by me" kept showing the aura as missing after it was reapplied in combat. An aura recognised from the buff frame's icon has no caster information, and that was being read as "cast by someone else"; it now counts as yours until the real data is readable again.
- Fixed: the last buff or debuff on you running out in combat was not noticed, because an empty buff frame was treated as unreadable. Once the frames have been read successfully, empty means empty.

## 1.11.1

- In combat, an icon appearing on the buff or debuff frame is matched against your trackers first, then the ledger, then the pre-built book, so a tracked debuff is recognised the first time it ever lands on you.

## 1.11.0

- Missing buffs now update in combat. While the client hides aura data, the addon watches the icons the default buff and debuff frames are showing: a carried buff whose icon disappears from them is dropped at once (so "missing" trackers fire mid-fight), and an icon that appears is matched against the ledger and shown as an estimated aura. /auraledger debug reports whether the frame icons are readable on this client and how often this has fired.

## 1.10.3

- Heading backplates lowered 7px (half way back).

## 1.10.2

- Heading backplates raised 14px.

## 1.10.1

- The heading backplate is positioned as in the spellbook: starting out toward the page margin and above the text, so the heading sits in its upper half and the divider crosses its lower half.

## 1.10.0

- The heading highlight is now exactly what the spellbook does: its list backplate at 65% behind the heading, the heading in FRIZQT 24 in the spellbook's ink colour with no shadow, and the divider under it. Groups and trackers and Options headings get the same.
- Book entries use the spellbook's exact text (names at 16, small print at 12, the same ink) and its 25% backplate at rest.

## 1.9.12

- The spellbook record is taken when the book is seen open (its page contents exist only then), not just at login.

## 1.9.11

- The chapter heading's highlight is a soft light bar behind the word, as in the spellbook, instead of a glow around the letters.
- The spellbook record in the saved settings now covers the page itself (headers and entries), with file textures and font settings, so the heading effect can be read exactly.

## 1.9.10

- Tab spacing set to 2px.

## 1.9.9

- Tab spacing tightened by another 2px.

## 1.9.8

- Tabs sit closer together, at the spellbook's spacing.

## 1.9.7

- Tab icons are square and fill the tab's height, as in the spellbook, instead of being cropped short.

## 1.9.6

- Tabs a little higher, on the page edge; the search box art shows again (the page rim had been drawn over it).

## 1.9.5

- The chapter tabs sit on top of the page edge, as in the spellbook, instead of dipping into it.

## 1.9.4

- The band above the page is back to the spellbook's height: the page rim no longer overlaps the window's own band (which showed as a second dark texture near the top).

## 1.9.3

- The Export buttons sit on the "Group" and "Tracker" header lines of the Options panel, at the right, instead of at the bottom.

## 1.9.2

- The Import button on the Groups and trackers heading is a small note icon instead of a text button.

## 1.9.1

- Group rows in the Groups and trackers list have the red X too: click it twice to delete the group and everything in it. The Delete group button is gone from the Options panel.

## 1.9.0

- Export and import. "Export tracker" and "Export group" in the Options panel give you a string (it starts with !AL1:) to copy; "Import" on the Groups and trackers pane takes a pasted one. An imported tracker arrives as its own group and an imported group arrives whole, both near the middle of the screen, ready to drag into place. Everything travels: look, conditions, sounds, warn window. "/auraledger import <string>" works too.

## 1.8.2

- The remove confirmation is a small bubble above the X ("Remove <name>? Click the X again") instead of text on the row.

## 1.8.1

- Each tracker row in the Groups and trackers list has a small red X: click it once to arm (the row asks), again within three seconds to remove the tracker. The Remove button is gone from the Options panel.
- The Options header (icon and name) wears the same faint backplate as the book entries.

## 1.8.0

- Trackers can be dragged within the Groups and trackers list: drop one on a group heading to add it to that group, on another tracker to place it before or after it (in the same group or another), or on empty space in the list to give it a group of its own. Dragging out of the window still drops it onto the screen, joining an on-screen group or starting a new one there.
- The "Move to its own group" button is gone; that is a drag now. "Remove tracker" stays.

## 1.7.3

- The entry backplate no longer draws over the text on hover; it sits beneath the entry, shows faintly at rest (as the spellbook's does) and brightens on hover, in both the book and the Groups list.

## 1.7.2

- The tracker icon at the top of the Options panel wears the spellbook icon frame and mask, and its group tag is in ink.

## 1.7.1

- Right page: darker ink for better contrast, headings moved clear of the page rim, hover uses the spellbook backplate and the selected row a soft brown band instead of the blue auction-house highlight, and the tracker icons in the list wear the spellbook icon frame with the rounded mask.

## 1.7.0

- The window is now the spellbook's maximized two-page view: the book on the left page, Groups and trackers and Options on the right page, edge to edge like the spellbook. The page art starts under the title bar so its own shaded rim forms the band holding the tabs, with the paper lip at the tabs' feet (this is how the spellbook does it; the earlier band tricks are gone).
- Groups and Options are restyled for parchment: ink-coloured headings with the spellbook divider, dark text in the list and option panels, no dark panes.
- Minimizing keeps the right page only, with Groups and Options on it.

## 1.6.27

- The band above the page is now the page's own shaded rim, exactly as in the spellbook: the page atlas starts under the title bar, uncut, so the paper's real top edge shows with the tabs' feet on it. The seam and the fill are gone.
- The page extends 8px further left, closing the gap beside it.

## 1.6.26

- The header-bar-only state is rebuilt from scalable pieces: the window's rock background in a gold border, the title centred, and both buttons inside the bar. No more stretched plaque.

## 1.6.25

- The grey band above the page is now genuinely taller: the strip beneath the window's fixed band is dressed in the same rock-and-streaks art, and the total height matches the spellbook's (it had grown too far).
- The chapter heading's highlight is a soft glow behind the text, like the spellbook's, instead of a hard outline.

## 1.6.24

- The header-bar-only state is wider, with the title and both buttons inside the plaque, and its expand and close buttons are the same 23x24 red arrow and X as the main window.

## 1.6.23

- Fixed the page parchment showing behind Groups and Options after minimizing; they have their dark backgrounds again.

## 1.6.22

- Hovering a book entry lights the spellbook's backplate behind the whole entry, as in the spellbook; the frame glow is now subtle.

## 1.6.21

- The band above the page is 13px taller, matching the spellbook.

## 1.6.20

- The chapter heading now shows the spellbook's light glow (the glow layers were never given the heading text).

## 1.6.19

- The band above the page is 4px taller.

## 1.6.18

- Fixed the shrink button being invisible since 1.6.12: re-anchoring its buttons had removed the anchors that gave them their size, leaving them at 0x0. They are 23x24 again.

## 1.6.17

- The band above the page is 5px taller, matching the spellbook; tabs, page edge and search box move down together.

## 1.6.16

- The page edge now sits over the tabs' feet as in the spellbook; the grey strip between them is gone.

## 1.6.15

- The shrink button re-asserts itself on every window change (shown, above the close button, right arrow, its art), and /auraledger debug reports its full state.

## 1.6.14

- The band above the page matches the spellbook's: the tabs sit a little lower and the page a little higher, with the page edge over the tabs' feet, and no dark strip between them.

## 1.6.13

- Minimizing now keeps both Groups and trackers and Options open at the full window height; only the book is dropped.

## 1.6.12

- The shrink button lines up with the close button, side by side as in the spellbook.

## 1.6.11

- The shrink button is visible: the window's title bar art is drawn at a very high level on this template and was covering the widget (which is why clicking the spot still worked). It now sits one level above the close button, as Blizzard's own does.

## 1.6.10

- Diagnostics for the shrink button art: the addon records the make-up of the spellbook frame (its buttons and their textures) in its saved settings, and /auraledger debug reports whether the spellbook is loaded and whether the button art was copied.

## 1.6.9

- Book and tab icons are full size again inside their frames: the rounded mask covers only the middle of its region, so it is now scaled to meet the icon's edges.
- The shrink button now borrows its art from the spellbook's own minimize widget (once the spellbook has been opened), since the template's stock atlases draw nothing on this client. The names are saved, so the art is there from the next login on.

## 1.6.8

- The hover highlight and the dispel-type colouring in the book now light up the icon frame art itself (an additive copy of the same frame, on the same anchor) instead of a separate glow that sat off the frame.

## 1.6.7

- Tab icons and ledger icons are back at full size and are now masked to the rounded shape of the client's icon frames (the action bar's own icon mask), so no black corners show and the frame art meets the icon cleanly. /auraledger debug reports the mask used.

## 1.6.6

- Fixed the chapter tabs being cut off and unclickable: the window inset background was drawn over their lower half and took their clicks. The tabs now sit above everything with their feet on the page edge.

## 1.6.5

- Book polish against the spellbook: the divider under the heading starts further left and sits lower with more room under the heading; the heading has the spellbook's light glow; the tabs and search box sit up against the title bar with the search centred in the band; the page runs to the bottom of the window.
- Tab icons and ledger icons are cropped to sit inside the rounded art windows, with no black corners poking out.

## 1.6.4

- The page art sits against the left edge of the window again; the content on it (add row, heading, divider, entries) is indented so it lines up with the first tab, exactly as in the spellbook.

## 1.6.3

- Debuffs in the book now light up the spellbook frame itself in their dispel colour (magic blue, curse purple, disease brown, poison green, other red), the way the spellbook lights a frame, instead of drawing a square border over the art.
- The minimize widget is built in its own guarded step so nothing can stop it being created; any failure is shown by /auraledger debug.

## 1.6.2

- The chapter tabs start to the right of the window portrait, as in the spellbook, and the book sits directly under them: its left edge lines up with the first tab and it spans the width of all of them. The window is 1360 wide.
- Fixed the page art covering the "Add by spell name or ID" row and the heading (the page now draws beneath the pane's text again).

## 1.6.1

- The spell icon frames in the book are drawn at the size Blizzard draws them (51x48); the atlas's own pixel size had made them huge.
- The page now meets the tabs with no dark strip above it, and the page edge sits over the tabs' feet as in the real spellbook (the page's opaque padding is clipped off).
- The search box is level with the tabs.
- If Blizzard's minimize widget does not draw on the client, a plain framed button takes its place a second after the window is built, and /auraledger debug reports the widget's state.

## 1.6.0

- The book now uses the Forever spellbook's own art by name, read from the client: the wide page, the ornate divider, the square icon frame with its ribbon (and its shadow and hover glow) around every entry, and the tab frame with its glow on the chosen tab. No more guessing.
- Book entry icons are the spellbook's 40px.
- Debuffs in the book wear a border coloured by their dispel type (magic blue, curse purple, disease brown, poison green, other red), the same as on the on-screen trackers.
- The window's header band holds the chapter tabs on the left and the search box on the right, like the spellbook; the old band inside the book pane is gone and the page starts right under the tabs.
- "Add by spell name or ID" moved to the top of the page, above the chapter heading, which is larger with the spellbook's light emboss.
- The "Keep trackers unlocked after closing" checkbox is gone: minimize the window to the Groups and trackers list instead; trackers stay draggable while it is open. "/auraledger unlock" still works.
- The minimize widget is pinned to the window's top-right corner beside the close button.

## 1.5.7

- Fixed the chapter tabs disappearing and the book icons losing their ring after the spellbook had been opened. The page art is opaque above its visible edge, so tabs tucked beneath it were hidden; they now rest on top of the page edge. Guessed icon-frame and tab art from the spellbook is no longer applied until its names are confirmed (the page and the divider are).
- The minimize button is now Blizzard's own maximize/minimize widget, the same red arrows the spellbook has. Left-click shrinks to the Groups and trackers list (and grows back); right-click on it collapses to the header bar.
- Book entry icons are the spellbook's size (36px) with the ring scaled to match.

## 1.5.6

- The chapter tabs are now shaped like the spellbook's: a tall dark bevelled square around each icon, a wider gap between them, a yellow frame on the chosen one, and their feet tucked behind the top edge of the page.
- When the spellbook is loaded, its own tab art (normal and chosen) is picked up and used instead.
- The spellbook's art is now re-read the first time the spellbook is seen open, since its spell entries only exist after it has been opened. Every art name found is saved with the addon's settings.
- Book entry icons are larger, matching the spellbook's.

## 1.5.5

- The page now tucks in right under the chapter tabs, as in the Forever spellbook; the empty strip between them is gone. The tabs are slightly smaller so they clear the search box.
- The minimize button is visible now. It uses the client's red condense and expand buttons when it has them, otherwise a framed "-" button; the classic hide-button art exists on this client but draws nothing.
- Groups and trackers and Options are two tall columns side by side instead of stacked. The window is 1300 by 720, and option rows put their label above the control where the column is narrow.

## 1.5.4

- The chapter tabs now sit in a band above the page, like the Forever spellbook: larger, in full colour, each in a dark bevelled square, with a gold frame on the chosen one.
- The spellbook's own spell icon frame, when its art can be read, is drawn at its native size around each book entry.

## 1.5.3

- Found it. The "blocked from an action only available to the Blizzard UI" dialog at login came from registering COMBAT_LOG_EVENT_UNFILTERED: on the Forever client that registration is itself a forbidden action, and no error handling can hide the dialog. The addon no longer registers the combat log. It was only a secondary source for changes during combat; carried timers and removals by aura instance still work. "/auraledger combatlog" turns it on for clients that allow it.
- The ring around each spell icon in the book now sits on the icon; it was offset up and to the left.
- Fixed the notes in the Options pane running into the row below them.

## 1.5.2

- The "blocked from an action only available to the Blizzard UI" dialog was still appearing at login (as UNKNOWN()). The addon no longer builds any frame from Blizzard's internal Cooldown Manager templates; it only reads live frames for its art.
- When a block does happen, /auraledger debug now prints the stack trace captured at that moment, naming the exact call.

## 1.5.1

- Fixed the "AuraLedger has been blocked from an action only available to the Blizzard UI" dialog at login and reload. Since 1.3.0 the addon loaded Blizzard's spellbook itself to read its art names; loading a Blizzard addon from addon code taints it, and the client then blocks the spellbook's own protected calls. The addon no longer loads anything. It uses the page art name already seen on this client, and reads the rest the moment you open your spellbook.
- Fixed the pale band across the first row of the book: the spellbook's header background had been picked as the divider. Only a thin "divider" atlas is used now.
- Any blocked protected call is now recorded and shown by /auraledger debug, with the function name.

## 1.5.0

- Trackers can watch **your target** as well as you: a new "On" setting per tracker (Me or My target). A target tracker follows whatever you have targeted, so it can show your curse on a mob, or a buff the mob cast on itself, and it hides when you have no target. The ledger now records auras seen on targets too, and the ledger filter gained "On you" and "On targets".
- **Sound alerts** per tracker: a Blizzard sound when the aura is applied, when it runs out, and when the tracker appears on screen (for any reason, including its warn window). Same picker as ShardGrid: eight sounds, picking one plays it.
- Bar text is now vertically centred. The Cooldown Manager's own text offsets were being copied and sat too high.
- The pocket watch that marks a carried timer (a timer counted on from the last clean read because the client hid auras in combat) is smaller, sits in the bottom-left of the icon, and can be turned off per group.
- Fixed a combat error: the client can hand over the UNIT_AURA payload lists as secret tables, which crashed the removal handler ("bad argument #1 to ipairs"). They are now checked before use.
- The spell icon frame borrowed from the spellbook now prefers the spell list's frame over the rotation helper's.

## 1.4.0

- A minimize button next to the close button. Click it to shrink the window to just the Groups and trackers list, click again for just the header bar (a small title plaque you can drag anywhere). Right-click grows it back a step. The header bar has its own expand and close buttons, and the window reopens the way you last had it.
- New tracker option **Warn before it runs out**, in seconds. With "show when missing" it also shows the tracker while the aura has that long or less left, with a red border and the countdown, then keeps showing once the aura is gone. With "always" it turns the border red that early. 0 switches it off.

## 1.3.1

- Three new group options: **Bar border**, **Bar background** and **Icon frame**. Untick them to hide the frame around bars, the dark plate behind the fill, or the decorative frame around icons, for bare bars and icons.
- Fixed: hovering a row in the Groups and trackers list blanked it out (the highlight was drawn over the text). The hover glow on an on-screen tracker now covers only its icon instead of washing out the whole bar.

## 1.3.0

- The book is now laid out like the Forever spellbook: a wide page with the chapter tabs in a row across its top (the chosen one framed in gold), the chapter name as a large heading with a divider under it, two columns of larger spell entries, and the page arrows in the bottom corner. Groups and Options sit stacked on the right. The window is 1120 by 720.
- The parchment is no longer stretched: the page is close to square now, so the art keeps its proportions.
- Aura Ledger loads Blizzard's own spellbook and reads the names of the art it uses (page, divider, icon frame). When found, the book is drawn with the same atlases; otherwise it uses the classic parchment.
- New `/auraledger atlases` prints every art name found on the client's spellbook, for checking that the right ones were picked.

## 1.2.0

- Trackers now wear the client's own art. When the game loads, Aura Ledger takes a Cooldown Manager tracked-buff bar (a live one, or one built from Blizzard's template) and copies its fill, background, border, end pip, icon overlay and fonts, with their proportions, onto every bar tracker. Icon trackers borrow the Cooldown Manager's icon overlay the same way. Whatever the Forever client draws, the trackers match it, at any size.
- If the Cooldown Manager is not there, the same is done with the cast bar; failing that the cast bar atlases, then the classic cast bar files, then a plain bar with the tooltip border. "/auraledger debug" reports which one was used and how many art pieces were copied.
- The bar fill is now cropped as it drains, the way Blizzard's bars do, instead of being squashed.
- Debuff bars are tinted red over the copied art; a "missing" bar is dark red with a red icon border.

## 1.1.1

- Bars now wear Blizzard's own metal border (the tooltip and classic panel edge), with the fill inset inside it and a dark plate behind, so they match the rest of the interface instead of looking like a plain addon bar. The border turns red while a "missing" tracker is missing.

## 1.1.0

- New **Items** chapter in the book: 89 buffs from flasks, elixirs, potions, scrolls, Juju, Zanza, world buffs, Darkmoon Faire fortunes and trinket effects. They are listed under the name of the buff you actually get (Flask of Supreme Power gives "Supreme Power"), with the item named underneath.
- New **Dungeons and raids** chapter: 82 buffs and debuffs that mobs and bosses put on you, from Molten Core to Naxxramas plus a few dungeon bosses, each labelled with where it comes from.
- The small print under each aura now says where it comes from, and search looks through that too, so typing "naxx", "chromaggus", "flask" or "world buff" finds the lot.
- The window is a little taller to fit the two new side tabs, and the spell buttons have more room.
- The book now holds 354 pre-built auras.

## 1.0.0

First release.

- A ledger of every buff and debuff that has been on you, with spell IDs, how often and how recently it was seen, and how long it lasts.
- A spellbook style book to pick from: side tabs for your ledger, one chapter per class with the buffs that class can cast (183 auras pre-built), and a Common chapter. Twelve auras per page, page arrows, mouse wheel, and a search across every chapter.
- Drag any aura off the page onto the screen to track it. Double-click to place it in the middle.
- Add auras by spell name, spell ID or spell link.
- Drop trackers on each other to group them. Shift-drag to reorder, move between groups or split one out. No limit on groups or trackers.
- Groups show as icons with numbers or as bars with icons, with size, spacing, wrapping, growth direction, scale and opacity options.
- Each tracker shows when its aura is active, when it is missing, or always.
- Show conditions on groups and on trackers: never, combat, resting, mounted, target, alive, solo / party / raid, open world / dungeon / raid / battleground / arena, and class.
- Keeps working while the client hides auras in combat: carried timers, removals by aura instance, combat log pickup, with carried or estimated states clearly marked.
- Minimap button, addon compartment entry, `/auraledger debug` self report.
