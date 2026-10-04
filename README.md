# Aura Ledger

Track your buffs, your cooldowns and the things you carry, and put them exactly where you want them on screen. Built for the WoW: Forever client (Interface 16001), out of the game's own interface art.

Aura Ledger writes down every buff that ever lands on you, so you can find it again. Open the book, pick what you care about, drag it onto the screen, and that is a tracker. Group them, show them as icons or bars, build them into a cluster, and tell each one when it is allowed to appear.

**A walk-through comes with it.** The **?** at the top of the window steps you through the whole thing, eleven steps, pointing at each part as it talks about it. Three of the steps wait for you to actually do the thing. It is offered the first time you open the window, and that button brings it back whenever you want it.

## What it can follow

- **A buff on you.** The thing it was built for.
- **Your party or your whole raid.** A group can watch everyone: a row per member, with the game drawing each member's buffs, all through a fight. See below.
- **Something you can remove.** A dispel tracker lights when there is a debuff you can dispel, or one of a type (Curse, Magic, Poison, Disease), on you or on each member.
- **A debuff on you**, from the ledger. The addon draws it: exact out of a fight, carried in one.
- **A debuff on your target.** Your DoTs, curses and banes, a mage's Frostbite or Winter's Chill: the game draws it on a target you can attack, all through a fight, by its spell. The Warlock and Mage chapters list theirs, the ledger notes any it has seen on a target (filter **On targets**), and any aura tracker can be switched to it under **Watch**. The game never looks at a new target by itself, so each time you change target Aura Ledger asks it to read the new one at once; `/auraledger debug target` shows how that went.
- **A spell's cooldown.** Under **Watch** in a tracker's settings, or `/auraledger cooldown <spell>`. A school locked out by an interrupt shows too, reddened, with the time left.
- **Something you are carrying.** The **What you are carrying** chapter of the book lists everything in your bags or worn that has a use on it. Drag one out and you get its cooldown, trinkets included.
- **Your weapons.** The same chapter starts with your main hand, off hand and ranged weapon: the temporary enchant on each (oils, stones, poisons, imbues), with its time left and charges, and the time to your next swing.

Cooldowns have so far read the same in a fight as out of one on this client, so a cooldown tracker keeps counting straight through a fight. If the game ever hides one (it may in some restricted fights), the tracker carries on from what it last read and from when you cast the spell, and never claims it is ready when it cannot say.

## Before you start

Turn the game's **Cooldown Manager** on: Options, Gameplay, Advanced Options, **Enable Cooldown Manager**. Aura Ledger draws its icons and bars in the manager's look (the icon shape, its border and shadow, the bar's frame), which it copies from the manager's own displays while they are on screen. With the manager off there is nothing to copy, and every tracker is drawn with plain stand-ins; Aura Ledger says so at login. Once the manager is on, the look is picked up within a few seconds, with no reload.

## Getting started

1. `/auraledger`, or the minimap button, opens the window.
2. Find something in the book: pick a chapter from the tabs along the top, or type in the search box.
3. Double-click it to place it, or drag it onto the screen where you want it.
4. Click any tracker to open its settings.

## The book

The left side is laid out like the spellbook and borrows its art when the client provides it.

- **Ledger**: everything that has ever been on you, with how often and how recently.
- **A chapter for every class**: the buffs that class can cast, so you can track Fortitude or Mark of the Wild before anyone has cast it on you. Your own class's chapter goes on to list every spell you know that has a cooldown, read from your spellbook (Death Coil, Shadowburn, Shield Wall...), and the Racials chapter your racials with one; double-click or drag one to track its cooldown.
- **Party and raid**, right after your own class: the dispel trackers, the buffs worth watching on everyone, Soulstone Resurrection, and **Party buffs for my class**, which sets up a whole party group in one double-click.
- **Racials**: including the ones read straight out of this client's own spellbook, so a racial the written list never heard of is there anyway.
- **What you are carrying**: your weapons' enchants and swings, then everything in your bags or worn that has a use on it.
- **Items and food**: food, drink, bandages, flasks, elixirs, potions, scrolls, world buffs and trinkets, listed under the name of the buff rather than the item.
- **The game's spell list**, the last tab: every aura that comes with the addon, about 1,900, in groups (for a class its Spells, Talents, Procs and set bonuses, and Pet abilities; Racials; World buffs; items by kind, from Flasks and elixirs to Gear; Mounts), each group starting on a page of its own under its name and sorted by name (click the heading to jump to a group), picked by whose they are (your class first, all, each class, racials, items, other auras) and where they land (anywhere, buffs, debuffs on you, debuffs on your target), and under **Every other spell** every other spell your client knows by name. Right-click either button to step back.
- **Search** looks through every chapter at once, by name, spell ID or source ("naxx", "flask", "world buff"), and then through the game's own spell list: the auras of every class and race, of talents and of items, by name or by what it does ("frozen" finds Frost Nova), each marked with where it lands (a buff on you, a debuff on you, or a debuff on your target) and ready to track, and any other spell this client knows by name.
- **Add by spell name or ID** takes a name, an ID or a shift-clicked spell link, for anything not in the book. A name your character does not know is looked up in the game's spell list, so the tracker gets every spell id of that name and the game can draw it.

The game's spell list comes in two parts. The auras players cast, and the ones talents and items put up, come with the addon, with where they land and what they do. Every other spell is read from your own client in the background the first time you play with this version (and again only when the game itself changes, or the language you play it in): about a millisecond of each frame, only out of a fight, with a thin bar at the top of the screen while it goes (right-click hides the bar; the reading goes on). It takes a minute or so, and the list is kept between sessions. `/auraledger debug spells off` stops the reading, and `on` starts it again.

Rows a group drawn by the game can follow all through a fight carry a small **combat** mark: a buff with a spell id known on this client, or a dispel tracker. Every rank known is handed to the game: the ranks of the book's class buffs come with the addon, and your own come straight from your spellbook. That matters: see below.

## Your party and raid

**Track on**, at the top of a group's settings, says who the group watches: **Me and my target** (your own trackers, each on you or, where its Watch says so, on your target), **My party** (you and up to four others; in a raid, your own raid group, which is who Blood Pact and Battle Shout reach) or **Everyone in my group** (your party, or every member of a raid, ten to a block by default: **Members before wrapping** sets how many).

Each member gets a row: their name in their class colour, then a cell for each tracker, as an icon or as a bar with the time left draining (**Show as**). Growing right or left, each member is a row with the trackers side by side; growing up or down, each member is a column with them stacked. The game draws each member's buffs in those cells, so the rows stay right all through a fight, and someone joining mid-fight fills in at once. A buff's group version counts too: Prayer of Fortitude for Fortitude, Arcane Brilliance for Arcane Intellect, a Greater Blessing for its Blessing. A new buff put in such a group shows where it is missing. If the group is hidden in a fight (**In combat: Hidden**), the addon reads everyone's buffs out of one, so **Missing** shows only the members who do not have it (and a warn time brings it back as it runs low), and the list closes up: a member with nothing to show (every buff you track, and nothing an Active or a dispel tracker would show) drops out, name and all, and the rest move up; shown in a fight, the game draws a buff on everyone who has it, so there Missing behaves like Either. In a battleground or an arena nobody's auras can be read, so there too Missing behaves like Either.

A row also says what the game cannot show you:

- **Far**: out of view. The game has no auras for them until they are back.
- **Off**: offline.
- **(dead)** after the name.
- **?**: the row changed hands during a fight (someone left and the rest moved up), or its member came back into view or online during one. It is read afresh when the fight ends. (In a battleground that is when the match ends.)

Everything about these groups is built and laid out out of a fight, a little at a time, so a change made in one waits for it to end. Cooldowns, items, weapons and most debuffs follow only you, so they go into a group of their own beside one that watches your party. Tracker sounds and a tracker's own conditions are for you alone too; the group's conditions still apply. At most two groups can watch everyone in a raid, and raid rows carry the first eight trackers across them; the rest show on your party's rows, and only when you are not in a raid.

## Arranging

**Edit layout**, beside the search box, puts the window aside and lets you move things about.

- **Drag a tracker** to move that tracker. Drop it on another group to join it, or in the open for a place of its own. A tracker that is its whole group just moves the group.
- **Drag the titled plate** behind a group to move the whole group.
- **Hold an icon against a free side of another icon**, above, below or either side, and it hangs there. The edge you are aiming at lights up. The group keeps that shape: it is a **cluster**, and every icon holds its own place, gaps and all, as things come and go.
- A group you have not shaped is plain **rows**: whatever is on screen fills them in order and the rest close up (in a fight, a tracker the game draws keeps its place when its aura drops). The plate says which of the two you are looking at.
- **Lay the icons out in rows again**, in the group's settings, turns a cluster back into rows.
- Click any tracker to jump straight to its settings.

In the **Groups and trackers** list, drag a row onto a group to move it there, onto another tracker to sit beside it, or onto empty space for a group of its own. The red X removes a tracker, or deletes a group when clicked twice.

## Settings

**Per group**: name, who it watches, icons or bars, growth direction, icon size, bar width and height, icon scale on bars, spacing, icons per row, scale, opacity, time text, names on bars, whether to draw the bar border, the bar background and the icon frame, and whether to colour each aura's border by its dispel type. A group that watches your party also has member names on or off; one that watches everyone in your group also has members before wrapping. Its trackers are laid out in each member's row in order, so a shape built by hand is not used there.

**Per tracker**: what it watches (the buff, or the spell's cooldown); when it shows (Active, Missing, or Either); how long before it runs out or comes back to put it on screen again; match by name or exact spell ID; only when cast by you; a glow while it is up (in a group drawn by the game); a bar label; and a sound when it lands, when it goes, and when the tracker appears.

**Conditions**, on groups and on trackers, so a tracker can be set to appear only in a raid, only in a battleground, only on a particular class, only with a particular main talent tree or talent set, and so on. A tracker must pass its own and its group's.

**Per character**: each character has its own groups and trackers, kept by the character itself rather than by its name, so two characters who share a first name never share a setup. The ledger of what has been on you, and the window and look settings, are shared by all your characters. `/auraledger profiles` lists every character's profile; `copy <number>` brings that profile's groups to the character you are on, where they were and in the shape they had (the one copied from is left as it was), and `forget <number>` drops a profile kept from before 1.76.0. The first time a character logs in with 1.76.0, it takes over the profile it had under its name before.

## What a fight does to this

On this client an addon cannot read your auras during a fight. Nothing gets around that, so Aura Ledger hands every tracker it can to the game and draws the rest itself; each tracker's settings say which.

- **Drawn by the game**: a buff on you, a debuff on your target, or a buff on your party, followed by its spell. It is correct the whole way through a fight. Its countdown reads the way the addon's own does, turns red inside the tracker's warn time, and it can glow while the aura is up. The game fills its slot whenever the aura is there, so such a tracker is on screen the whole time the aura is up.
- **Drawn by the addon**: a cooldown, an item or a weapon, which the addon reads itself, exactly, in a fight too; and a debuff on you, or a tracker set to show only when it is **Missing** (the game can only show an aura that is there), which the addon carries from the reading taken before the fight. It still takes a buff dropping when the game names which one, and a buff you cast yourself (a finisher such as Slice and Dice for the combo points it spent), and marks anything it worked out rather than read with a `~`.

A group's **In combat**, under Only show this group when, is simply Shown or Hidden. Out of a fight a plain row closes up as auras come and go; in a fight a tracker the game draws keeps its place when its aura drops, because the game cannot have its slots moved then.

In a battleground the game hides auras for the whole match, not only in fights. A group drawn by the game is only changed when auras can be read, so in a match already under way (or after a reload in one) it keeps the Where, class and talent conditions it had until the match ends, and a change you make to it waits until then too.

## Commands

| Command | What it does |
| --- | --- |
| `/auraledger` | open or close the window |
| `/auraledger add <spell>` | start tracking a buff |
| `/auraledger cooldown <spell>` | follow a spell's cooldown instead |
| `/auraledger useitem <item>` | follow the cooldown of something you are carrying |
| `/auraledger bags` | list what you are carrying that has a use |
| `/auraledger racials` | the racials this client knows about |
| `/auraledger edit` | turn arranging on or off |
| `/auraledger import <string>` | import a tracker or group |
| `/auraledger profiles` | every character's profile, to copy groups from one or forget an old one |
| `/auraledger minimap` | show or hide the minimap button |
| `/auraledger log` | a log to copy and send with a bug report: the debug report and what the addon noted, selected and ready for Ctrl+C (`start` records step by step, `stop` ends it, `clear` empties it) |
| `/auraledger debug` | what this client let the addon read |
| `/auraledger debug cdread` | everything the game says about each cooldown tracker |
| `/auraledger debug members` | every group that watches your party, row by row |
| `/auraledger debug spells` | how far the game's spell list has been read, and what the reading cost (`again` reads it all again, `off` stops the reading, `on` starts it again) |
| `/auraledger debug target` | how your target trackers were read on each change of target (`method` picks which reads are made) |
| `/auraledger debug spellcd` | your spells with a cooldown, as the book reads them (`all` adds every spell left out, and why) |

Aura Ledger also has a page in the game's own Options, under AddOns, with a button that opens it.

## If something looks wrong

`/auraledger debug` reports what this client actually allowed: which interface templates resolved, which art drew, what the aura reads returned, and which calls were refused. That report is the useful thing to send with a bug report, because this client differs from others in ways no addon can see from the outside.

On this client the game follows a buff by spell on you and on your party and raid, a debuff by its type, and a debuff by spell on an enemy you target, but not a debuff by spell on you (bar the few it never hides). So a debuff tracker on you is drawn by the addon, while one on your target is drawn by the game.

## Credits

Spell rank data (Ranks.lua): Data from talentsforever.com (https://talentsforever.com), licensed CC BY 4.0.
