# Aura Ledger

A buff and debuff tracker for the WoW: Forever client (Interface 16001), built from Blizzard's own interface art.

Aura Ledger writes down every buff and debuff that lands on you, and everything it sees on your targets. Open the book, find the aura you care about, and drag it onto the screen the same way you drag a spell out of the spellbook. That is a tracker. Drop trackers on each other to make groups, show groups as icons or bars, and decide when each one is allowed to appear.

## The book

`/auraledger` (or the minimap button) opens the window. The left side is laid out like the spellbook, and borrows its art when the client provides it:

- **Tabs across the top** pick a chapter. The first tab is your **Ledger**: everything that has ever been on you, with how often and how recently. After it comes a tab for **every class** listing the buffs that class can cast, so you can track Fortitude or Mark of the Wild before anyone has cast it on you. **Common** holds food, drink and the usual lockout debuffs. **Items** lists the buffs from flasks, elixirs, potions, scrolls, world buffs and trinkets, under the name of the buff itself. **Dungeons and raids** lists what mobs and bosses put on you, labelled by boss.
- Each page holds twelve auras. Turn pages with the arrows or the mouse wheel.
- **Search** looks through every chapter at once, by name, spell ID or source ("naxx", "flask", "world buff").
- **Add by spell name or ID** at the top of the page takes a name, a spell ID or a shift-clicked spell link, for anything that is not in the book yet.

## The window

The minimize button beside the close button shrinks the window to the Groups and trackers list with Options beside it (the book is dropped), then to just the header bar; right-click grows it back. The header bar can be dragged anywhere and has its own expand and close buttons.

## Tracking

- **Drag** an aura off the page and drop it anywhere on the screen. Double-click places it in the middle instead.
- **Drop it on an existing tracker** and the two become a group. Groups have no size limit, and you can have as many groups and trackers as you like.
- While the window is open every tracker is shown as a preview so you can arrange things. Drag a group by any of its icons or by its title plate.
- Drag a **lone tracker onto another group** to join it.
- **Shift-drag** a tracker inside a group to reorder it, move it to another group, or pull it out into a group of its own.
- Click any tracker or group plate to edit it.
- In the **Groups and trackers** list, drag a tracker onto a group heading to move it there, onto another tracker to place it before or after it, or onto empty space for a group of its own. The red X on a row removes that tracker, or deletes that group (click it twice).

## Options

Per **group**: name, icons with numbers or bars with icons, growth direction, icon size, bar width and height, spacing, how many per row before wrapping, scale, opacity, time text, names on bars, and whether to draw the bar border, the bar background and the icon frame.

Per **tracker**: on **you** or on **your target** (a target tracker hides with no target); show when the aura is **active**, when it is **missing**, or **always** (turning red while missing); a warn window in seconds (with "missing": also shows while the aura has that long or less left, in red; with "always": the border turns red that early); match by name (any rank) or exact spell ID; buff, debuff or either; only when cast by you; a custom bar label; a Blizzard sound when the aura is applied, when it runs out, and when the tracker appears.

**Conditions**, on both groups and trackers (a tracker must pass its own and its group's):

- Never (disabled)
- Combat, resting, mounted, have a target, alive: each either way or "either"
- Group size: solo, party, raid
- Where: open world, dungeon, raid instance, battleground, arena
- Class

## The look

Trackers are drawn with art copied off the client's own frames when the game loads: a Cooldown Manager tracked-buff bar for the bars (fill, background, border, pip, fonts) and its icon overlay for icons, so they match whatever the Forever client draws. Without the Cooldown Manager the cast bar is used instead. `/auraledger debug` reports which.

## Sharing

"Export tracker" and "Export group" in the Options panel produce a string starting with `!AL1:`; copy it and paste it to a friend or into the note icon on another character's Groups and trackers heading (or `/auraledger import <string>`). Trackers arrive as their own group, groups arrive whole, both near the middle of the screen.

## Combat and hidden auras

The Forever client hides your auras from addons in combat. Not just the details: every read (by index, by instance id, by spell name, the aura frames' textures, the UNIT_AURA payload lists) fails or answers nothing while the restriction is on, and only Blizzard's own code may look. So in combat Aura Ledger cannot see an aura land on you or leave you. What it can do:

- whatever it knew going in keeps counting down on its own timer, so a buff running out mid-fight still flips its tracker on time
- your own successful casts are watched: casting a spell the ledger knows as an aura creates or refreshes an estimated aura (a buff on you, a debuff on your target) with the remembered duration, so a recast Demon Skin clears its "missing" tracker at once and a Blood Fury shows its bar
- the "when applied" and "when it runs out" sounds are handed to the game (C_UnitAuras.AddAuraSound), which plays them itself when that aura is added to you or removed from you, in combat too; only sound choices with a file behind them qualify, marked "(combat)" in the picker
- a group can have its trackers drawn by the game: each tracker gets a Blizzard aura slot filtered to its spell, shown by the game while the aura is on you (in combat too) and hidden otherwise, uncovering the addon's "missing" art underneath
- a group can be handed to the game (Contents: debuffs on me, dispellable debuffs, buffs on me, buffs I cast): Blizzard draws every aura of that kind through its AuraContainer and keeps it current in combat, with our icon art, size and place
- anything carried or estimated wears a small pocket watch and a `~` in front of its time, and everything is re-read properly the moment the restriction lifts

What the addon itself cannot do in combat, on this client: notice a buff being clicked off or dispelled, or a debuff landing. The game-drawn options above are how that is covered. When the client hides less, the addon reads more without changes.

`/auraledger debug` reports what the client actually allowed, which is the first thing to send with a bug report; `/auraledger log` keeps that output in the saved variables so it can be read from disk.

## Commands

| Command | What it does |
| --- | --- |
| `/auraledger` | open or close the window (`/aledger` works too) |
| `/auraledger add <name or ID>` | add an aura and start tracking it |
| `/auraledger import <string>` | import a tracker or group from an export string |
| `/auraledger unlock` / `lock` | move trackers without the window open |
| `/auraledger minimap` | show or hide the minimap button |
| `/auraledger combatlog` | try the combat log as an extra in-combat source (off by default: registering it is forbidden on the Forever client) |
| `/auraledger atlases` | list the art names on the client's spellbook, for bug reports |
| `/auraledger plainbook` | switch the book between parchment and a plain dark page |
| `/auraledger debug` | self report |
| `/auraledger log` / `log clear` | the addon keeps everything it prints (and everything that reaches the chat frame) in its saved variables, written on reload or logout; this shows the counts or empties them |
| `/auraledger soundtest` | plays each file-backed sound choice in turn and reports what the client said |
| `/auraledger api <name>` | prints a structure, enum or function from Blizzard's API documentation (run any `/api` first) |
| `/auraledger probe`, `frames`, `cdm`, `container` | diagnostics: what the by-spell lookups, the default aura frames, the Cooldown Manager data and an AuraContainer widget expose right now |

## Notes

- Layouts are saved per character. The ledger itself is shared by all your characters.
- The pre-built class lists use Classic spell names. If this client names a spell differently, add it by name and it works the same.
