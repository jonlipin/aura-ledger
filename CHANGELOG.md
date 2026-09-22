# Changelog

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
