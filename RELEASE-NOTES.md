## 1.74.0

- New: groups that watch your party or your whole raid. **Track on**, at the top of a group's settings, is now Me, My party, or Everyone in my group. Each member gets a row: their name in their class colour, then a cell for each tracker, and the game draws each member's buffs in them, so the rows stay right all through a fight. My party is you and up to four others; in a raid that is your own raid group, which is who Blood Pact and Battle Shout reach. Everyone is your party, or in a raid every member, ten to a column (**Members per column** changes that).
- New: a row says when the game cannot show that member: **Far** when they are out of view, **Off** when offline, "(dead)" on the name. A **?** means the row changed hands during a fight (someone left and the rest moved up), or its member came back into view or online during one; it is read afresh when the fight ends. Hover a name for what the game can see of them.
- New: in a group that watches your party, a buff's group version counts too: Prayer of Fortitude for Power Word: Fortitude, Arcane Brilliance for Arcane Intellect, Gift of the Wild, Prayer of Spirit, Prayer of Shadow Protection, and every Greater Blessing for its Blessing. A new buff added to such a group shows where it is missing.
- New: dispel trackers. **Something I can remove** lights when there is a debuff you can dispel, and **Curse**, **Magic**, **Poison** and **Disease** light for that type whether you can remove it or not. The game draws the debuff itself, in its own icon with its countdown and a border in its type's colour, all through a fight. In a group that watches you they say "I have a Curse"; in one that watches your party, a column lights for each member who has one. They glow while lit.
- New: a **Party and raid** chapter in the book, right after your own class, with the dispel trackers, the buffs worth watching on everyone, Soulstone Resurrection (who has one), and **Party buffs for my class**: one double-click sets up a group that watches your party with the buffs your class gives and, if your class can dispel, something to remove.
- New: debuff trackers on you, from the ledger. The addon draws them (exact out of a fight, carried in one), their combat sounds are handed to the game, and the few debuffs the game never hides are drawn by the game in a group it draws.
- New: school lockouts. A cooldown tracker whose spell's school is locked out by an interrupt shows it, drained and reddened, with the time left in its tooltip.
- New: **Colour the border by dispel type**, a group option that rings each aura in its type's colour. Most buffs are Magic. In a group drawn by the game, the game draws the ring, in combat too.
- New: the ranks of the class buffs in the book are bundled with the addon (from talentsforever.com), so a group drawn by the game follows every rank of a buff, even one never seen on you. Each is checked against this client and dropped if it names something else.
- New: `/auraledger debug members` reports every group that watches your party, row by row. `/auraledger debug members probe`, run in a fight, checks whether a member's row could be read afresh during a fight rather than after it.
- Fixed: trackers drawn by the game no longer go blank while the game's Edit Mode is open.
- Fixed: nothing the game draws is built, changed or moved while the game is hiding auras outside a fight (a battleground, for one), which could make the game refuse the addon. In a battleground a group drawn by the game therefore keeps the conditions it had until the match ends.
- Fixed: in a group drawn by the game, a tracker the addon draws (a cooldown, say) appearing or going during a fight knocked the game's icons out of line with their places, since the game will not have them moved then. The order is now held until the fight ends: a tracker that goes quiet leaves its place empty, and one that appears goes on the end.
- Fixed: a group drawn by the game that was switched to be drawn by the addon during a fight no longer hides the game's frames with it; it fades out until they can be put away.
- Fixed: a damaged or unusual import string can no longer break the import; anything in it the addon does not know is dropped.
- Saved data is now changed in numbered steps, each run once, so a later version can add to a tracker without an older step undoing it. An addon that is older than your saved data leaves it alone and says so in `/auraledger debug`.

## 1.73.1

- "Glow while it is up" is now offered on every tracker, not only on buffs in a group drawn by the game. On the trackers the addon draws, the addon plays the same action bar proc glow itself, going by what the tracker shows (in a fight, the reading it is carrying); on buffs the game draws, the game still plays it, in combat too.
- Cooldown trackers get "Glow while it is ready", offered when the tracker is set to show Ready or Either, since with Running it is only on screen while not ready.

## 1.73.0

- New: weapon enchant trackers for your main hand, off hand and ranged weapon. Oils, stones, poisons and imbues show with their time left and charges, read by the addon itself, in a fight too. They are at the top of the book's Bags page.
- New: swing timer trackers for your main hand, off hand and ranged weapon (a wand counts), showing the time to your next swing from the game's own swing event. Also on the Bags page. The game has a swing timer of its own too, under Edit Mode.
- New: talent conditions, for groups and trackers alike. "Main talent tree" is the tree you have spent the most points in (until talents are read, or with none spent or a tie, it lets everything through), and "Talent set" picks set 1 or 2 when you have dual talents. Both work for groups drawn by the game too, and a group shared from a character of another class or with one talent set is not ruled out by them.
- New: trackers drawn by the game show their countdown the way the addon's own trackers do: tenths of a second under 10 seconds, whole seconds up to a minute, then minutes and hours.
- New: "Show it again before it runs out" now works on trackers drawn by the game. The game decides when those are on screen, so instead of coming back early, the countdown turns red that long before the aura runs out, in combat too. It needs the group's timers on, and takes effect a moment after you stop changing it.
- New: "Glow while it is up" for trackers drawn by the game: the game plays the action bar's proc glow on the tracker for as long as the aura is up, in combat too.
- New: a cooldown tracker for Nature's Swiftness, Presence of Mind, Stealth and the like reads as used while the effect is up, instead of Ready. Their cooldown only starts when the effect ends.
- New: every rank of your own spells is handed to groups drawn by the game and to combat sounds, straight from your spellbook, so a rank the ledger has not seen on you yet is still followed in a fight.
- Changed: the book's "combat" mark now says what a group drawn by the game can follow all through a fight: a buff on you with a spell id known on this client. It no longer depends on the game's Cooldown Manager being switched on.
- Fixed: a spell cooldown the game hides during a fight (the client can do this in some restricted fights) no longer shows as Ready. It carries on from the last reading, or from when you cast it, or shows as on cooldown with the time unknown.
- Fixed: a cooldown tracker for a spell the character cannot cast right now (a pet ability with another pet out, for example) no longer shows as Ready.
- Fixed: exported cooldown and item trackers came back as buff trackers when imported.
- Fixed: a combat sound picked during a fight is registered with the game when the fight ends, since the game can refuse it during one. The sound registered before keeps playing meanwhile.
- Fixed: several places could test a value the game hides during a fight, which the client punishes by blocking the addon for the rest of the session: reading the Cooldown Manager's art, the cooldown readers and parts of /auraledger debug. They all check first now, and the Cooldown Manager's art is only read out of combat.
- Fixed: deleting or merging a group drawn by the game during a fight left it half removed. It now goes when the fight ends.
- Fixed: a tracker drawn by the game with a warn time set made its whole group redraw ten times a second.
- Fixed: trying /auraledger combatlog once kept it on across logins, and this client answers the combat log with a "blocked" dialog. It now lasts one session only.
- Fixed: the book listed Detect Lesser Invisibility, Detect Invisibility and Detect Greater Invisibility separately, but this client has them as ranks of one spell. It is one row now, and all three ranks are followed.
- Removed: the dispel border on trackers drawn by the game. The game never shows it on buffs, so it never appeared.
- Removed: /auraledger debug cdmapply, a diagnostic that wrote the Cooldown Manager's layout. A profile that still carries that layout is handed back as before, and the manager is now left switched on or off as it was.
- /auraledger debug now also reports cooldown secrecy, talents, weapons and ranks, and /auraledger debug cdread prints everything the game says about each cooldown tracker.
