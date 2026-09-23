# Changelog

## 1.50.0

- Bars have a frame again, drawn by the addon. The readout says this client's Cooldown Manager gives exactly one piece of art for a bar, its background, and no border: its bar items are never shown, so there is nothing to read off them. Rather than leave bars bare, the addon draws the frame itself, four thin lines round the bar, as it does round an icon on a client with no art to copy. Where a client does hand a border over, that one is used and this is not drawn. The Bar border tick still turns it off.

## 1.49.10

- Bars have their border back. Dropping the manager's backing in 1.49.8 went by the flag the collector sets for anything drawn behind the fill, and that covers the border frame as well as the backing, so the bars lost their frame along with the plate. Only what is drawn in the background layer is dropped now, and the pip with it, as on the other placement.

## 1.49.9

- A missing tracker on a bar no longer has a grey plate behind the whole row. The ring that carries a tracker's state is laid on the cell's own square, which for a group shown as icons is the picture and for one shown as bars is the icon and the bar together. On a bar it goes round the icon, as it does on an icon.

## 1.49.8

- A bar's border fits it again. The measurement added in 1.49.0 was aimed at the backing, which hung lopsided off the bar; carried over to the border it put the frame inside the bar rather than round it. Bar art goes back to the older placement, which reckons a piece's reach in pixels off the donor's height and is what a frame wants.
- The manager's backing is not copied onto a bar at all. It is sized for the manager's own item, icon and padding included, so on a bar with its own icon beside it there is nothing it can fit. The bar's own black plate is the backing, and that fits by construction.
- /auraledger barart measured switches back to the other placement for comparison.

## 1.49.7

- A bar's border fits the bar. Each piece of copied art is measured in fractions of the manager's own bar, which is right for something that stretches with the bar and wrong for a frame round it: a border measured as a fraction of a short donor bar came out as a wide inset on a long one, which is why it sat inside the bar instead of round it. A piece's reach is carried over as pixels against the bar's height now, the way the icons' art is, so a border is the same thickness whatever width the bar is set to.

## 1.49.6

- A bar the game draws looks like one the addon draws. Opening the window hands every tracker back to the addon, which is why the difference showed there. Two things caused it: the cover that hides the cell underneath a game-drawn bar was burying the art copied from the manager, because that art hung on the button while the cover sits on the bar above it, so the game's bars had no border; and the game's bars were tinted blue whatever the skin, while the addon leaves art copied from the client its own colour and tints only a stand-in fill.

## 1.49.5

- A bar the game draws is the height the group asks for. It was pinned to the top and bottom of its cell, and a cell is as tall as the taller of the bar and the icon, so in any group whose icon stands proud of its bar the game's bar was stretched to the icon's height while the addon's kept the bar's own: one bar taller than the rest. The slot's bar keeps the group's bar height and holds the middle of its cell, as the addon's has since 1.42.3.

## 1.49.4

- The dark plate hanging out behind a bar is gone. The manager's backing is measured faithfully, and on its own items that backing reaches well past the bar, because it covers their icon and the padding around it too. Carried onto a bar that has its own icon beside it, that reach is a plate sticking out to the right and below. A piece drawn behind everything is laid exactly on the bar now; the border, and anything else, keeps the reach it was measured with.

## 1.49.3

- A bar the game draws covers the cell it sits on. That cell is painted as missing on purpose, text and all, so that it shows through the moment the aura goes, and the bar drawn over it was translucent: "Missing" read straight through the name and the time. Its backing is opaque where it covers a cell.
- The manager's pip is no longer copied onto a bar. It is the bright mark the manager slides along its own fill, and the addon draws its own fill, so copied as a fixed piece it sat at the end of the bar as a gold bookmark.

## 1.49.2

- A group shown as icons no longer has empty bars beside it. The art measured off the manager's bar in 1.49.0 is drawn from a pool of its own, and the icons branch, which hides the bar and clears the old pool, knew nothing about the new one: the art stayed on screen with nothing in it. It is taken off with the bar now.

## 1.49.1

- /auraledger debug icon says what a bar's text is doing: what the name and the time actually say, how wide each is allowed to be, how wide it wants to be, and where each is pinned. Two strings landing on each other cannot be seen in the art lines. It also lists what each piece of bar art was measured as against the manager's own bar, so a piece that reaches somewhere odd can be told from one that is drawn wrongly.

## 1.49.0

- The art round a bar is measured the way the art round an icon is. It was still placed by the old reckoning, which reads a piece's anchors and scales everything by the donor bar's height: that is how a background came out eight pixels taller than the bar it sits on and hanging six below it, which is the look of a buff group shown as bars. Each piece is now measured where it sits against the manager's own bar, in fractions of that bar's width and height, and drawn on ours at whatever size ours is. The old reckoning stays for a client that gives no bar to measure.

## 1.48.2

- /auraledger debug icon covers a bar as well as an icon: which donor the bar skin came from, whether a plain border is standing in for art the skin never found, and, for each group shown as bars, the bar's own size with its fill, background, pip and every piece of copied art, each with where its corners are pinned.

## 1.48.1

- A tracker the game draws has one shadow rather than two. The cell underneath a slot draws the shadow, and the icon handed to the slot was drawing another; both reach the same distance past the picture, so in that ring the two stacked and came out twice as deep. The slot leaves the shadow to the cell, and the cell counts the layer the game draws itself towards the depth.

## 1.48.0

- Every tracker has the same shadow. The art the Cooldown Manager lays over its own icons is what gives them their shadow, and a tracker the game drew was getting it twice, its own and the addon's copy on top, while a tracker the addon drew got it once: that is the deep shadow on one and the thin line on the others. How many layers are laid on is one number now, the same however a tracker is drawn, and a slot's own layer counts towards it.
- /auraledger shadow <0-4> sets it: 0 for none, 1 for exactly what the manager draws, 2 (the default) for the deeper one.

## 1.47.5

- /auraledger debug icon lists the art copied from the manager as it is actually drawn on a tracker, above and below the picture, with its size and where its corners are pinned, plus the addon's own shadow. A piece that is collected but never appears can now be told apart from one that was never collected.

## 1.47.4

- The addon's stand-in shadow steps aside for the manager's own. On this client the shadow is UI-HUD-CoolDownManager-IconOverlay, which the manager draws over its icon rather than under it, and the stand-in only gave way to art copied from below the picture: both were being drawn, one on top of the other. Anything copied off the manager now counts.

## 1.47.3

- Fixed an error that repeated while a game-drawn group was on screen: "calling '?' on bad self (Attempt to access forbidden object from code tainted by an AddOn)". The buttons an aura container hands out belong to the game, and reading a frame level off one from addon code is refused. It was being read on every refresh, to put a cell below its slot. It is asked for safely now, and the cell keeps the level it had when the game will not say.

## 1.47.2

- The shadow is soft. The one added in 1.47.1 was a flat black copy of the icon's shape, which is a silhouette rather than a shadow. It now uses whichever of the client's own soft shadow atlases it has, drawn larger than the picture, since the softness of such art lives in the part that spreads past what it shadows. Where the client has no such art, none is drawn.
- /auraledger debug item walks one of the manager's items from top to bottom, every frame and every texture, with the art each wears, its layer, whether it is shown, and where it sits against the icon. Whatever draws the shadow under the game's own icons can be named from that rather than guessed at.

## 1.47.1

- Trackers have a drop shadow even though the manager hands none over. Whatever draws the shadow under the game's own icons is not on the items the addon can read, so copying it came back empty; instead the addon draws one, a dark copy of the icon's own shape sat behind the picture and a little larger and lower, masked so it is that shape rather than a square behind a rounded corner. Where a client does hand a shadow over, that one is used and this is not drawn. /auraledger debug icon says which.

## 1.47.0

- Trackers get the shadow the game's own icons have. The manager's items carry art below and above their picture as well as the mask, and the art below is what gives them their slight drop shadow. It is measured where it sits against that icon, the same way the mask and the border already are, and drawn on a tracker at whatever size the tracker is. /auraledger debug icon lists each piece, which layer it belongs to and how far it reaches.

## 1.46.6

- The square corner over a rounded icon is gone. A cooldown draws its swipe itself and need not hand out a texture for it, and on this client it does not, so there was never anything for a mask to hold: every attempt at masking that swipe was masking nothing. Where a cooldown gives up no texture, its swipe is turned off instead, which leaves the time in numbers and the icon its own shape. On a client whose cooldowns do hand one out, the swipe stays and is masked. /auraledger debug says which.

## 1.46.5

- Every cooldown on a tracker the game draws is masked, not only the one the addon handed it. The container can run a cooldown of its own, whose textures the addon never saw, and that is the square corner still poking out of a rounded icon. Each cooldown on a slot is found and masked, and each keeps its own set of masks so two on one frame do not tread on each other.

## 1.46.4

- The swipe on a tracker the game draws is masked once it exists. A cooldown makes its textures the first time it runs, and the game runs the ones in its own slots, so masking them while the slot was being built masked nothing: there was nothing there yet. The mask is asked for again each time the group is laid out, by which point the game has the cooldown going.

## 1.46.3

- The cooldown swipe keeps inside the icon. The swipe is drawn with textures on a frame of its own laid over the picture, and none of them were masked, so its square corners sat outside a rounded icon. They take the same mask the picture does, on the addon's own cells and on the slots the game fills, and again whenever a cooldown is set going, since those textures are only made when one first runs.

## 1.46.2

- A tracker the game draws is framed like the ones the addon draws. Since 1.45.0 a picture was kept whole wherever the manager's mask was in hand, on the reading that the dark line round the manager's icons is the picture's own baked border. The game trims that border off when it fills a slot, so the game's icon looked zoomed in beside the addon's. Every picture is trimmed now, the way the game trims one.

## 1.46.1

- A group keeps its shape when the window opens. The ring that carries a tracker's state is a band round the outside of its cell, and the picture was being pulled in off that band whatever the tracker was doing: with the window open the addon draws every cell, so every picture sat smaller than the same tracker drawn by the game, and the group appeared to change. A picture fills its cell now and gives up the band only while a ring is actually being shown.

## 1.46.0

- A missing aura is grey rather than red. The picture is already drained of colour the moment an aura goes; painting it red on top of that and ringing it in red reads as a warning when nothing is wrong, since it is only a buff you have not got. It is now drained and dimmed a little, with a dark ring rather than a red one. Red is kept for the thing worth warning about: an aura inside its warn window, about to run out.
- /auraledger missing red puts the old colouring back, and /auraledger missing grey returns.

## 1.45.4

- A tracker the game is drawing is no longer red while its aura is up. The ring that carries the missing colour is a band round the outside of a cell, with the picture pulled in off it so the band shows; the icon handed to a game-drawn slot was being pulled in by the same amount, so the band stayed on show underneath it. The slot's icon wears the same mask but keeps the cell's full size, so it covers the band while the game is drawing the aura and uncovers it the moment the aura goes.

## 1.45.3

- The square behind a tracker the game draws is gone. Each slot carries an opaque black backing so that a setup which fails part way never leaves a bare box on screen, and that backing covered the whole slot while the icon on top of it had been pulled in and rounded off. It follows the icon now and wears the same mask, so the slot is the shape of its icon and nothing square shows round it.

## 1.45.2

- The icon in a slot the game fills matches the cell underneath it. It was being left at full size with square corners while the cell was pulled in and rounded off, so it stood proud of its cell and the cell's corners showed round the outside of it. The slot's icon is pulled in by the same amount and wears the same mask, so a tracker the game draws is the same size and shape as one the addon draws.

## 1.45.1

- A tracker whose aura is up no longer wears the missing colour. The ring that carries that colour was drawn a little outside the picture, so on a cell sitting under a game-drawn slot it reached past the cell, where the game's icon does not cover it, and showed as a red outline round an aura that was there. The ring is laid on the cell's own square now and the picture is pulled in off it, so the ring shows where the picture is not and never reaches past the cell.
- /auraledger debug icon reports the state ring and how many of the manager's masks are actually on a tracker's picture.

## 1.45.0

- Trackers look like the Cooldown Manager's icons, because they are made the same way. The readout settled how that is: one mask, UI-HUD-CoolDownManager-Mask, sized exactly to the icon, and no border art at all. The thin dark line round the manager's icons is the spell icon's own baked border with its corners rounded off by that mask, which is why copying border art never found any and why trimming the picture threw away the very thing that makes the look.
- So a tracker keeps the whole picture, wears the same mask, and drops the plain dark edge that stood in for this. The missing and warning colours are a ring of the same rounded shape behind the picture rather than a square frame over it. A client whose manager cannot be read still gets the plain edge and the trimmed picture.

## 1.44.1

- The icon shape is looked for on every one of the Cooldown Manager's displays, not just the first one with an icon in it. The addon read the essential cooldowns, whose items carry no border on this client, and so found nothing to copy and changed nothing. Each display is tried now, the fullest answer is kept, and /auraledger debug icon lists what each one offered.

## 1.44.0

- Trackers wear the Cooldown Manager's own icon shape. Rather than name an atlas and hope, the addon measures what the manager does to its own icon: the masks it clips it with and the border art it draws round it are live regions, so where they sit against that icon is read off the screen and put on a tracker at any size. The missing and warning colours go onto that same border, so a tracker is the manager's shape in every state instead of gaining a square red frame. Where the manager cannot be read, the thin dark edge from 1.43.0 is still drawn.
- /auraledger debug icon reports the shape: each mask copied, the border art, and how far each reaches past the icon.

## 1.43.5

- Trackers have tooltips while you play, not only while the window is open. Hovering one names the aura and says whether it is on you and how long is left, or that it is not; a tracker the game is drawing says so as well, since the addon cannot tell the difference between an aura that has gone and one the game has not drawn. Hovering takes no clicks, so everything behind a tracker still works.
- A tracker the game draws no longer wears the missing colour while its aura is there. The cell underneath a game-drawn slot is painted in the missing state on purpose, so the game's icon covers it while the aura is up and it shows through the moment the aura goes. The edge, though, is drawn on a frame above the cell, so it landed on top of the game's icon: a red border round an aura that was present. A cell now sits below the slot's own frame while it is under one, edge and all, and goes back to its own level when it is not.

## 1.43.4

- A group is spaced the same whether the addon or the game is drawing its cells. The edge round an icon was drawn just outside the picture, which reached into the gap between one cell and the next and made a row look joined up, while a cell under a game-drawn slot had to keep its edge inside and so kept its gap. The bars lie along the inside of the picture now, in both cases, so a cell is exactly its own size and the gap between cells is the spacing that was asked for.

## 1.43.3

- A group keeps its shape whether the window is open or not. The edge round an icon was a block drawn behind the picture, which can only be seen where it sticks out past it, so a cell sitting under a game-drawn slot had to pull its picture in to show one: that is the gap that appeared when the window was closed and the game took the cells over. The edge is four thin bars drawn over the picture now, so a cell under a slot keeps its picture whole and only the edge moves inside the cell.

## 1.43.2

- A tracker the game draws no longer shows the addon's edge round the outside of it. The addon paints its own widget under a game-drawn slot so the missing state can show through, and the slot is anchored flush to that widget, while the edge is drawn just outside the picture: the part that stuck out was not covered by the game's icon. A widget under a slot now keeps its edge at the cell's own bounds and pulls its picture in behind it, so the game's icon covers the lot while the aura is there, and the red shows only when it is not.

## 1.43.1

- The red border on a missing tracker was the wrong shape, and it was the one on every screenshot. It came from the old debuff border sheet, whose art on this client is rounded along the top and flat along the bottom, and it is drawn whenever a tracker is missing, expiring or showing a debuff, which covered the icon's own edge entirely. The clean edge is tinted instead: the same line that edges an icon turns red while an aura is missing or nearly gone, or the dispel colour on a debuff, and thickens a little so it still reads at a glance. The old sheet is only used where there is no clean edge to colour.

## 1.43.0

- Icons are clean. Both the frame atlas this client offers and the mask cut to go with it are the shape of a tab, rounded along the top and flat along the bottom, which is why drawing them evenly never made them look right: that is what the art is. A tracker now wears a trimmed spell icon with a thin dark line round it, the way an icon is edged everywhere else in the game, and is not masked unless asked.
- /auraledger iconborder takes clean, client, cdm or none: the thin dark line, this client's own frame art, the Cooldown Manager's overlay, or nothing. /auraledger iconmask on puts the client's mask back if it is wanted.

## 1.42.3

- Spell icons are trimmed again everywhere. A spell icon has a dark border baked into its outer edge, which is why every frame in the game cuts one off, and 1.42.0 kept the whole picture wherever the addon was masking: a mask rounds the corners of what it is given, border and all, so that border was on show underneath the addon's own frame.
- An icon scaled up on a bar has room to be scaled. The row stayed the bar's height however large the icon was, so the icon was cut off and no longer lined up with its bar. A row is now as tall as the taller of the two, and the bar keeps its own height in the middle of it, so the two stay on each other's line at any scale.

## 1.42.1

- /auraledger debug icon lists what is actually drawn on a tracker: the picture, the client's frame, any copied art, the dispel border and the mask, each with the art it wears, the size it is drawn at, how it is cropped and where its corners are pinned. Which layer shapes an icon has been inferred from screenshots several times over; this reads it off the frame instead.

## 1.42.0

- Icons wear the frame this client draws round its own. The art was being copied off the Cooldown Manager, and that display's overlay is a different shape from the frame the spellbook, the buff bar and the action bar all wear, which is why a tracker came out rounded at the top and square at the bottom. The action bar's icon frame is drawn instead, at the same size and place as the mask it is cut for, and the Cooldown Manager's overlay is kept only for a client that has no such frame. /auraledger iconborder switches between the two, or draws none at all.
- Icons are trimmed again. The Cooldown Manager leans on a mask rather than a crop, so the crop copied from it was the whole picture, and every icon was drawn with its own baked border as well as ours. Where the addon is masking, the whole picture is right; where it is not, the icon is trimmed as the game trims an unmasked one.

## 1.41.6

- Turning the icon mask off now does something. A tracker only dresses itself again when the look it was dressed for changes, and the mask was not counted as part of that look, so the switch was thrown and nothing was redrawn. It counts now, and turning the mask off also takes the masks off the icons already on screen instead of waiting for them to be drawn again.

## 1.41.5

- The icon mask can be nudged: /auraledger iconmask <out> <up>. The rounded shape does not sit in the middle of its own art on this client, so drawn centred on an icon it comes out rounded at the top and square at the bottom, where the game's own spellbook is rounded all round. The two numbers are how far past the icon the mask is drawn and how far up the shape is moved against it, both as a share of the icon's size. Trackers change as you type; the book follows after a reload. /auraledger debug icon reports the mask art's size and both numbers.

## 1.41.4

- The icon the addon draws is whole again. The mask was built before the icon had been given a size, and a mask drawn to nothing sits exactly on the icon and hides everything but its middle, which is why the picture looked shrunk inside its border. The mask is now told the size it is there to clip.
- The icon on a slot the game fills keeps its square. The container takes the icon and anchors it to its button, which is not always square, and the picture was being stretched to match; it is put back on its own square afterwards and again whenever the slot is shown.

## 1.41.3

- The trackers' icons are masked the way the window's tabs have been all along. The window has had a working icon mask since the book was built: the rounded shape fills about two thirds of that atlas region, so the mask has to be drawn a quarter larger than the icon it clips. The attempt in 1.39.3 sized it to the icon and so showed only the middle of the picture. That helper now lives in one place and both the window and the trackers use it, so the corners come off the same way in both.
- With a mask in place the picture fills its square again, and the inset added in 1.41.2 only applies where the client has no mask to give.

## 1.41.2

- An icon the addon draws comes out square. The art copied from the donor can sit unevenly around the donor's own icon, and carried over side by side those uneven overhangs made the frame taller than it was wide. Art drawn around an icon now reaches the same distance on all four sides.
- The picture no longer shows past its border. It is inset under the frame art by as much as the art reaches out, up to a limit, so the art laps over the edge of the picture instead of meeting it exactly and letting the square corners show past a rounded border. Turning the icon frame off removes the inset with it.
- /auraledger debug icon reads out what was actually copied: the donor, the crop, and how far each piece of art reaches past the icon, along with the inset each group ends up with.

## 1.41.1

- The hint along the bottom of the window fits on its line. It was long enough to wrap onto a second line the bar has no room for, so the end of it was cut off. It now says the one thing worth saying, and is held to a single line.

## 1.41.0

- Bars have an icon scale, from half the bar's height to twice it. The icon keeps the middle of the bar's height, so a large one stands proud of the bar rather than pushing it down, and the bar, the frame art and the stack count all follow the size. It applies to the bars the addon draws and to the ones the game fills alike, and travels with a group when a tracker is pulled out of it.

## 1.40.0

- The icon mask added in 1.39.3 is gone. On this client that atlas is not the rounded square it is elsewhere, and it cut the picture down to a strip.
- Icon art is taken from any donor again. Refusing it from a donor whose frame is not square, in 1.39.2, left icons with no border at all.
- The stretching those two were aimed at is fixed at its source. Art was measured around whatever frame the donor's icon hangs on, which on a bar is the whole wide item, and then redrawn around a square icon. It is now measured around the icon itself, so it arrives the shape it started, and a bar's icon keeps the bar donor's art while a lone icon prefers the icon donor's.

## 1.39.3

- The icon no longer shows past its border. The frame art copied from the Cooldown Manager has rounded corners and the icon under it was a plain square, so the corners of the picture sat outside the border. Icons are now masked with the same atlas Blizzard masks its own with, on the addon's icons and bars and on the slots the game fills. Turning the icon frame off removes the mask as well, so a bare icon keeps its square corners.

## 1.39.2

- Icons are square again. The art around an icon was measured against whatever frame the donor's icon hangs on, and on a bar donor that is the whole bar item, which is wide: redrawing it around a square icon stretched it. Art is now only taken from a donor whose own frame is square, the donor's crop is squared off if it takes more off one side than the other, and an icon keeps its own square size rather than filling a frame the game may have resized. /auraledger debug says where the icon art came from, and says so when a donor was turned down for this.

## 1.39.1

- Handing the Cooldown Manager back is itself a write from this addon, so it now says plainly that one reload is needed afterwards to clear the mark that write leaves. After that reload nothing in the addon touches the manager again.
- The automatic Cooldown Manager probe no longer runs at login. It walked the game's own frame pool to answer a question that has now been answered. /auraledger debug cdm2 still runs it on request.

## 1.39.0

- Stopped borrowing Blizzard's Cooldown Manager frames, and handed the manager back. Putting the game's own frames inside this addon's groups marked them with the addon, and the game then refused its own reads: the manager was throwing "Auras cannot be accessed when secret while tainted by 'AuraLedger'" from its own event handlers, and later could not touch its own tables at all. That breaks a part of the game's interface that has nothing to do with this addon, which no feature is worth. The borrowing, the layout writing and the hooks into the manager are gone; if a previous version took the manager over, it is given back shortly after you log in.
- Groups set to be drawn by the game use the aura slots again: those are the addon's own frames, filled by the game through the interface meant for it, so the game keeps them right in a fight and nothing of Blizzard's is touched. The cost is that "show it when missing" behaves like "always" in such a group, as it did before.

## 1.38.0

- Groups can grow out from the centre: "Out from the centre, sideways" spreads the trackers evenly left and right of where you put the group, and "Out from the centre, up and down" spreads them above and below. The group stays pinned to that point as trackers come and go, so a centred row stays centred. Switching a centred row to bars turns it into a centred column, since bars are too wide to march sideways.
- The first row of spells in the book sits further below the divider under the heading, which was crowding it.

## 1.37.0

- A Racials chapter in the book, between the classes and Items and food: Blood Fury, Berserking, Stoneform, Find Treasure, Shadowmeld, Perception, Will of the Forsaken, Cannibalize and Gift of the Naaru, each labelled with the race it belongs to. Racials this client does not have are withheld like any other row, so only the ones that exist are listed.

## 1.36.0

- The edit button now sits beside the search box at the top of the window and is called "Edit layout". Clicking it puts the window out of the way, since it covers the very things you are arranging, and clicking Done brings it back. If editing was turned on with the window already closed, Done leaves it closed.

## 1.34.1

- /auraledger debug gd now says, for each tracker in a group the game draws, whether it borrowed a Cooldown Manager frame, which cooldown that frame is for, and whether the game is currently showing it.

## 1.34.0

- The groups the game filled are gone, and with them the Contents question. A group whose contents the game chose could not honour the list you put in it, which is the one thing this addon is for: you would drag auras into a group and watch it show something else. Every group is now the trackers you put there, and the only question left about a group is who draws them, which lives with the combat condition. Any group that was set to one of the filled kinds becomes an ordinary group of its own trackers.

## 1.33.1

- Fixed: a group the game fills was only one row tall while the game was allowed to fill three, so a target carrying several debuffs spilled outside the group. The group is now as tall as the game may fill it, which is also what the edit mode plate covers.

## 1.33.0

- An edit mode you can see you are in. "Edit trackers" at the top of the window, or /auraledger edit, turns arranging on: trackers become draggable wherever they are on the screen and clicking one opens its settings, exactly as before, but now a bar across the top says so and carries a Done button. It stays on when the window is closed, so things can be placed while playing, and the button reads "Done editing" while it is on. /auraledger lock and unlock still work.
- The group size slider no longer has its label and its value running into each other: the label is simply "Group size".

## 1.32.0

- A grip in the bottom right corner sizes the window. The window is a book and its art is drawn at fixed sizes, so the grip sizes the whole thing in proportion rather than stretching the page; double-click the grip to put it back. The size is remembered.
- Fixed: the parchment on the right of the window flashed each time it opened. Opening it from a selection skipped the step that anchors the page art, so the previous layout was drawn for a frame before being put right.
- The class names in the condition list are legible on the parchment. Class colours are chosen to sit on a dark bar, and the pale ones disappeared against the page, so they are darkened until they read.

## 1.31.0

- Removed the in-combat guesswork that the Cooldown Manager route made pointless. Four ways in were tried before it and each was refused by the client: polling the default buff frames' icons, which turn hidden the moment the frame refreshes; asking for aura instance ids, which is refused while an addon is involved; asking by spell, which answers nothing; and reading the Cooldown Manager through its children, whose item frames actually live in a frame pool. All four had been proven inert in game, so they were only costing reading. The debug report and the diagnostic commands lose the lines that went with them.

## 1.30.0

- Trackers in a group the game draws now borrow the Cooldown Manager's own frame for that spell. The manager reads auras during a fight because it is the game's code, so the frame stays right, and whether the manager is showing it is the present or absent signal the client will not give an addon any other way. That means "show it when missing" works in combat again for any spell the manager knows.
- The manager's layout is kept in step with your trackers by itself, out of combat, and is handed back when no group asks for it any more. Frames the addon did not ask for are parked out of sight, so the Cooldown Manager no longer draws rows of its own while the addon is using it.
- A tracker the manager has no entry for, such as a spell your character has not learned, falls back to the addon's own drawing as before.

## 1.29.1

- Fixed the spell to cooldown lookup. The Cooldown Manager files every rank of a spell separately and only builds a frame for one the character actually knows, so the addon was asking it to draw Demon Skin rank 1, which this character does not know, and the manager quietly drew nothing. A cooldown the character knows now always wins, a cooldown that stands for another spell is read under that spell, and ranks collapse to the base spell. /auraledger debug cdmapply says for each tracker whether the entry it found is one the character knows.

## 1.29.0

- The Cooldown Manager layout is written the way the manager reads it. Its category lists are the whole tracked set in display order, not a filter, so writing a single spell did not pick that spell out, it only reordered things and the manager carried on showing its own. The layout now keeps every cooldown the manager tracks and moves the ones a bar group wants into the bar row. Picking out the frames that belong to your trackers is the addon's job, by cooldown id, and that is the next piece.

## 1.28.1

- /auraledger debug cdmapply now reads the layout back after writing it and reports what the game actually stored: the category enum values, which category each cooldown it was given belongs to, and the contents of our layout as the file holds it.

## 1.28.0

- Group size is a number of players now, not three tick boxes. One slider, "Only with this many players": 1 is any group size, 2 upwards needs that many people, 5 reads as a party and 10 upwards as a raid. Existing conditions are carried over: "party" becomes 2 or more, "raid" becomes 6 or more, and anything that included "solo" becomes any size, since it already allowed every case.
- A group the game draws is gated by a macro condition, which cannot count players, so it uses the nearest thing it can say: any group for a size of 2 to 5, a raid above that. The addon's own check is exact.

## 1.27.1

- The little pocket watch on carried timers is gone, along with its option. The ~ in front of a time now marks every carried time, not just a guessed one, so there is one mark for it instead of two and a tick box.

## 1.27.0

- Groundwork for having Blizzard's Cooldown Manager draw the trackers that must stay right in a fight. The manager can read auras in combat because it is the game's own code, so the addon can put a tracker's spell into the manager's layout and use the frame the manager makes for it. This release writes that layout: /auraledger debug cdmapply builds one named "Aura Ledger (spec)" holding the spells of every tracker whose group asked the game to draw it, icons and bars in their own rows, and says which trackers the manager has no entry for. /auraledger debug cdmrestore hands the manager back to whatever was in charge before.
- Borrowing the frames into the addon's groups comes next; until then the manager draws them itself.

## 1.26.1

- The Cooldown Manager probe now runs itself once a few seconds after login and writes the full reading to the log, with a one-line summary in chat. It reports whether this client exposes the pieces an addon needs to make the game's own Cooldown Manager draw the spells you choose: the viewers' item frame pools, each item's cooldown id and shown state, and the layout data APIs. /auraledger debug cdm2 still prints it on demand.

## 1.26.0

- Contents offers only what is worth having: the trackers you put there, your debuffs on your target, or every debuff on your target. The other five repeated what the default buff, debuff and target frames already show, so they are gone.
- The two combat questions are now one place. "Keep these right in combat" has moved into the conditions as "In combat: shown, the addon draws it / shown, the game keeps it right / hidden", with "Out of combat: shown / hidden" beside it. A group the game fills does not offer the middle choice, since the game always draws those.
- The resting, mounted and "have a target" conditions are gone, and any that were set are cleared. Combat, alive, group size, where and class remain.

## 1.25.0

- The group options ask two plain questions instead of one muddled one. "Contents" says what is in the group: the trackers you put there, or one of the kinds of aura the game fills a group with. "Keep these right in combat" says who draws your trackers, and only appears for a group of your own trackers, since a group the game fills is always drawn by the game. A line under Contents says in plain words what the current pair means.
- Nothing is called "show" in two senses any more. The condition headings are now "Only show this group when" and "Only show this tracker when", and a tracker's own rule reads "Show the aura when it is: Active / Missing / Either".
- The Contents choices are worded plainly and ordered by how often they are wanted, with "My debuffs on my target" first.

## 1.24.2

- Fixed: re-stacking the options rows ran them over the tracker name and icon at the top of the panel. The rows now start where the panel left off, below the title block.

## 1.24.1

- Options that do not apply are now hidden rather than greyed out, and the rows below them close the gap. A group showing icons no longer lists bar width, bar height, bar border, bar background or names on bars; a group showing bars no longer lists the icon size; a group the game fills no longer lists "Show as"; and the pocket watch and the warn window only appear where the addon does the drawing. The panel resizes itself as the choices change.

## 1.24.0

- Fixed: rolling the mouse wheel over a slider in the Options panel dragged the slider and changed the setting. The wheel now scrolls the panel wherever the cursor is.
- The group options ask one question instead of three. "Contents", "Track in combat" and "Only this group's trackers" are now a single "Shows" choice: my trackers between fights, my trackers kept right in combat, or one of the kinds of aura the game fills a group with. The combinations that meant nothing are gone, and "Only this group's trackers" retires with them, since "my trackers, kept right in combat" is that, done properly.
- Options that do not apply to the current choice are greyed out rather than left looking available, and hovering one says why: bar settings in a group showing icons, the icon size in a group showing bars, "Show as" in a group the game fills, the pocket watch and the warn window where the game does the drawing.

## 1.23.0

- An aura can now be dragged out of the book straight into the Groups and trackers list: onto a group to join it, onto a tracker to sit before or after it, or onto empty space in the list for a group of its own. Dropping it on the screen still works as before.
- While dragging, the label under the cursor says exactly what the drop will do ("Add to Warlock Buffs", "Before Demon Skin", "Drop here for a new group"), for auras from the book and for rows dragged about inside the list. Dragging a row back onto itself says so rather than pretending something will happen.
- The note along the bottom of the window describes both ways of placing an aura.

## 1.22.0

- The book marks what the game can follow. Any aura the Cooldown Manager knows how to track carries a small "combat" mark in the book and the ledger, and its tooltip says what that means: a group set to track in combat keeps those right during a fight, while everything else is drawn by the addon and updates between fights. The mark is on the row, so the choice is made with that in view instead of discovered afterwards.
- Rows this client does not have are no longer offered. Every row is looked up when the window opens and shortly after login; a spell the client still cannot name or draw after three attempts, a second apart, is withheld from the book and from search. Spell data that arrives late brings its row straight back. /auraledger debug reports how many are withheld.
- Common has folded into Items, now "Items and food": five rows did not earn a tab of their own. Well Fed, Food, Drink, First Aid and Essence of the Red sit at the top of that chapter.

## 1.21.0

- One short command list. The diagnostics now live behind /auraledger debug <topic> (log, api, gd, cdm, cdm2, frames, probe, container, slot, mixin, atlases, combatlog), and the sound commands are /auraledger sound test and /auraledger sound clear. Every old command name still works, so nothing written down stops working. /auraledger on its own still opens the window, and /auraledger help lists the lot.
- When a group set to be drawn by the game cannot be built, the addon now says so in a dialog with a Reload button rather than a line of chat that scrolls away. It is raised once a session, never during a fight, and is dropped if the addon has put itself right by the time the fight ends.

## 1.20.1

- New: /auraledger cdm2 reports the Cooldown Manager the way the Coolinator addon uses it: the viewers' item frame pools, each item's cooldown ID, layout index and shown state, the display widgets it carries, and whether the layout data APIs exist on this client. If they do, a tracker can be pushed into Blizzard's own Cooldown Manager and its frame borrowed, which the game keeps live in combat.

## 1.20.0

- The addon now offers only what the Forever client allows, and says so where it matters.
- Debuffs on you cannot be followed by spell in combat, so debuff rows are gone from the book (the Dungeons and raids chapter is no longer offered, the lockout debuffs are gone from Common) and from the ledger unless the debuff was seen on a target. New debuff trackers watch your target from the start, and setting a tracker's type to Debuff moves it to your target with a message. A group with Contents "Debuffs on me" remains the way to see every debuff on you in combat.
- "Trackers drawn by the game" is now "Track in combat (drawn by the game)". Off: the addon draws the trackers and they update between fights. On: the game draws them and keeps them right in combat, but always shows the aura while it is active ("It is missing" behaves like "Always"). The group panel and the tracker options carry short notes about this.
- Target trackers: out of combat the new target's auras are re-read the moment you switch; in combat the game only re-reads them when they change. The "On" option says so.

## 1.19.0

- The mask trick behind game-drawn "show when missing" trackers is gone: on this client a mask still applies while its frame is hidden, so it blanked the missing icon for good. In a game-drawn group, "It is missing" now behaves like "Always": the game's icon while the aura is up, the red missing icon the moment it is gone, in combat too. The option text says so. /auraledger nomask is removed.
- Category groups can be on your target: Contents gains "My debuffs on my target", "All debuffs on my target" and "Buffs on my target", drawn by the game and shown while a target exists.
- Category containers are no longer shown or hidden from addon code in combat.

## 1.18.6

- Fixed: /auraledger gd raised an error when a game-owned slot answered with a hidden value; hidden values are now printed as "secret", and the chat mirror skips any hidden line.

## 1.18.5

- The file sound labelled "Soft bells" is an explosion; it is now called Explosion. Trackers using it keep it.
- Fixed: a game-drawn group whose "drawn by the game" was switched off and on again stayed hidden.
- Without attribute drivers on the client, a game-drawn group's gate now follows its conditions out of combat instead of staying hidden.
- /auraledger gd prints every game-drawn group's gate, driver macro, containers, slots and cells.

## 1.18.4

- The mask behind game-drawn "show when missing" trackers no longer depends on a texture file: it is a one-pixel opaque mask placed just outside the cell with clamp-to-black wrapping, which blanks the cell the same way. If the missing icon still never appears, the client applies masks on hidden frames too; /auraledger nomask then restores the covering behaviour.

## 1.18.3

- Game-drawn "show when missing" trackers no longer show the aura while it is active. The game's slot is now invisible and carries a transparent mask over the tracker's missing art: while the game shows the slot (aura present) the art is blanked, and when the game hides it (aura gone) the missing icon or bar appears. "Show when active" and "always" keep drawing the aura. On game-drawn bars set to "missing", the name and "Missing" text are left blank (text cannot be masked). /auraledger nomask switches back to covering the cell with the aura, should the mask misbehave on this client.
- Game-drawn groups are shown and hidden by the game through a secure driver built from the group's conditions (combat, resting, mounted, target, alive, group size; class and place are checked when the driver is built). Showing or hiding a container from addon code makes the game re-read auras under the addon's taint, which fails in combat and is why the DoT bars did not clear on a target switch. Target containers now have their own driver, so they are cleared when the target is lost and rebuilt for the next one; switching straight between two living targets still keeps the old bars until the new target's auras change.
- Game-drawn bars: the fill is tinted blue for buffs and red for debuffs so the text is readable, the bar drains instead of filling (the game's timer direction), and the name and timer are pinned to the bar.
- The slot's black backing is created last, so a slot whose setup failed no longer leaves a black box.

## 1.18.2

- Fixed: an error at load (Display.lua:888, skin was nil) when a group drawn by the game existed before any addon-drawn tracker had been built.
- Fixed: a tracker sound registered with the game could keep playing after its choice was changed or removed, because the game's registrations outlive a reload while the addon's record of them did not. Registration ids are now kept in the saved variables and cleared on load. /auraledger soundclear removes every registration on the spot, and /auraledger debug lists what is registered (spell, trigger, sound).

## 1.18.1

- Fixed: game-drawn bars were black with a thin line; the bar's fill was given the whole texture sheet instead of the Cooldown Manager's fill strip.
- Debuffs on you cannot be drawn per spell: the game only matches spell IDs for buffs on friendly units and debuffs on enemies (a rule in Blizzard's container code). Such trackers in a game-drawn group are drawn by the addon as before; "Contents: Debuffs on me" remains the way to see every debuff on you in combat. Debuff trackers set to "On: My target" do get game-drawn slots, so your own DoTs on the target can be followed in combat.
- Target containers are refreshed when the target changes.

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
