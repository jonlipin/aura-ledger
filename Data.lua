-- Aura Ledger pre-built book: the buffs each class can put on a player, so they can be tracked
-- before they have ever been seen. Trackers made from these match by NAME (every rank has its own
-- spell ID), so the ID here is only used for the icon and the tooltip. At runtime each ID is checked
-- against the client: when the client's name for it differs, the ID is kept for the icon only.
-- "/auraledger debug" counts how many resolved.

local ADDON, ns = ...

-- { name, spellID [, kind [, note]] }   kind defaults to "buff"; note is the small print under the name
ns.BOOK = {
	WARRIOR = {
		{ "Battle Shout", 6673 }, { "Bloodrage", 2687 }, { "Berserker Rage", 18499 }, { "Shield Block", 2565 },
		{ "Shield Wall", 871 }, { "Last Stand", 12975 }, { "Retaliation", 20230 }, { "Recklessness", 1719 },
		{ "Death Wish", 12328 }, { "Sweeping Strikes", 12292 }, { "Enrage", 12880 }, { "Flurry", 12966 },
	},
	PALADIN = {
		{ "Blessing of Might", 19740 }, { "Blessing of Wisdom", 19742 }, { "Blessing of Kings", 20217 },
		{ "Blessing of Salvation", 1038 }, { "Blessing of Light", 19977 }, { "Blessing of Sanctuary", 20911 },
		{ "Blessing of Protection", 1022 }, { "Blessing of Freedom", 1044 }, { "Blessing of Sacrifice", 6940 },
		{ "Greater Blessing of Might", 25782 }, { "Greater Blessing of Wisdom", 25894 },
		{ "Greater Blessing of Kings", 25898 }, { "Greater Blessing of Salvation", 25895 },
		{ "Greater Blessing of Light", 25890 }, { "Greater Blessing of Sanctuary", 25899 },
		{ "Devotion Aura", 465 }, { "Retribution Aura", 7294 }, { "Concentration Aura", 19746 },
		{ "Sanctity Aura", 20218 }, { "Shadow Resistance Aura", 19876 }, { "Frost Resistance Aura", 19888 },
		{ "Fire Resistance Aura", 19891 },
		{ "Seal of Righteousness", 21084 }, { "Seal of the Crusader", 21082 }, { "Seal of Command", 20375 },
		{ "Seal of Justice", 20164 }, { "Seal of Light", 20165 }, { "Seal of Wisdom", 20166 },
		{ "Righteous Fury", 25780 }, { "Divine Shield", 642 }, { "Divine Protection", 498 },
		{ "Divine Favor", 20216 }, { "Holy Shield", 20925 }, { "Redoubt", 20128 },
	},
	HUNTER = {
		{ "Aspect of the Hawk", 13165 }, { "Aspect of the Monkey", 13163 }, { "Aspect of the Cheetah", 5118 },
		{ "Aspect of the Pack", 13159 }, { "Aspect of the Wild", 20043 }, { "Aspect of the Beast", 13161 },
		{ "Trueshot Aura", 19506 }, { "Rapid Fire", 3045 }, { "Quick Shots", 6150 }, { "Deterrence", 19263 },
		{ "Feign Death", 5384 },
	},
	ROGUE = {
		{ "Stealth", 1784 }, { "Slice and Dice", 5171 }, { "Sprint", 2983 }, { "Evasion", 5277 },
		{ "Vanish", 1856 }, { "Blade Flurry", 13877 }, { "Adrenaline Rush", 13750 }, { "Cold Blood", 14177 },
		{ "Ghostly Strike", 14278 }, { "Remorseless", 14143 },
	},
	PRIEST = {
		{ "Power Word: Fortitude", 1243 }, { "Prayer of Fortitude", 21562 }, { "Divine Spirit", 14752 },
		{ "Prayer of Spirit", 27681 }, { "Shadow Protection", 976 }, { "Prayer of Shadow Protection", 27683 },
		{ "Power Word: Shield", 17 }, { "Inner Fire", 588 }, { "Renew", 139 }, { "Fear Ward", 6346 },
		{ "Power Infusion", 10060 }, { "Inner Focus", 14751 }, { "Shadowform", 15473 }, { "Fade", 586 },
		{ "Levitate", 1706 }, { "Abolish Disease", 552 }, { "Touch of Weakness", 2652 }, { "Shadowguard", 18137 },
		{ "Elune's Grace", 2651 }, { "Feedback", 13896 }, { "Inspiration", 14893 }, { "Spirit Tap", 15271 },
		{ "Blessed Recovery", 27813 }, { "Spirit of Redemption", 20711 },
	},
	SHAMAN = {
		{ "Lightning Shield", 324 }, { "Ghost Wolf", 2645 }, { "Water Breathing", 131 }, { "Water Walking", 546 },
		{ "Elemental Mastery", 16166 }, { "Nature's Swiftness", 16188 }, { "Clearcasting", 16246 },
		{ "Ancestral Fortitude", 16177 }, { "Healing Way", 29203 },
		{ "Strength of Earth", 8076 }, { "Stoneskin", 8072 }, { "Grace of Air", 8836 }, { "Windwall", 15108 },
		{ "Mana Spring", 5677 }, { "Healing Stream", 5672 }, { "Mana Tide", 16191 }, { "Tranquil Air", 25909 },
		{ "Fire Resistance", 8185 }, { "Frost Resistance", 8182 }, { "Nature Resistance", 10596 },
	},
	MAGE = {
		{ "Arcane Intellect", 1459 }, { "Arcane Brilliance", 23028 }, { "Frost Armor", 168 }, { "Ice Armor", 7302 },
		{ "Mage Armor", 6117 }, { "Mana Shield", 1463 }, { "Ice Barrier", 11426 }, { "Fire Ward", 543 },
		{ "Frost Ward", 6143 }, { "Dampen Magic", 604 }, { "Amplify Magic", 1008 }, { "Ice Block", 11958 },
		{ "Evocation", 12051 }, { "Presence of Mind", 12043 }, { "Arcane Power", 12042 }, { "Combustion", 11129 },
		{ "Clearcasting", 12536 }, { "Slow Fall", 130 },
	},
	WARLOCK = {
		{ "Demon Skin", 687 }, { "Demon Armor", 706 }, { "Unending Breath", 5697 },
		-- On this client the three are ranks of one spell, Detect Invisibility.
		{ "Detect Invisibility", 2970 },
		{ "Soul Link", 19028 }, { "Fel Domination", 18708 }, { "Amplify Curse", 18288 }, { "Shadow Ward", 6229 },
		{ "Shadow Trance", 17941 }, { "Soulstone Resurrection", 20707 }, { "Sacrifice", 7812 },
		{ "Burning Wish", 18789 }, { "Fel Stamina", 18790 }, { "Touch of Shadow", 18791 }, { "Fel Energy", 18792 },
		{ "Blood Pact", 6307 }, { "Fire Shield", 2947 }, { "Paranoia", 19480 },
	},
	DRUID = {
		{ "Mark of the Wild", 1126 }, { "Gift of the Wild", 21849 }, { "Thorns", 467 }, { "Rejuvenation", 774 },
		{ "Regrowth", 8936 }, { "Omen of Clarity", 16864 }, { "Clearcasting", 16870 }, { "Nature's Grasp", 16689 },
		{ "Barkskin", 22812 }, { "Innervate", 29166 }, { "Nature's Swiftness", 17116 }, { "Abolish Poison", 2893 },
		{ "Tranquility", 740 }, { "Tiger's Fury", 5217 }, { "Dash", 1850 }, { "Prowl", 5215 },
		{ "Frenzied Regeneration", 22842 }, { "Enrage", 5229 }, { "Leader of the Pack", 24932 }, { "Moonkin Aura", 24907 },
		{ "Bear Form", 5487 }, { "Dire Bear Form", 9634 }, { "Cat Form", 768 }, { "Travel Form", 783 },
		{ "Aquatic Form", 1066 }, { "Moonkin Form", 24858 },
	},
}

-- The buffs a race gives you. Anything this client does not have is withheld when the book is
-- built, so the races that came later can sit here safely.
ns.BOOK.RACIAL = {
	{ "Blood Fury", 20572, "buff", "Orc" },
	{ "Berserking", 26297, "buff", "Troll" },
	{ "Stoneform", 20594, "buff", "Dwarf" },
	{ "Find Treasure", 2481, "buff", "Dwarf" },
	{ "Shadowmeld", 20580, "buff", "Night Elf" },
	{ "Perception", 20600, "buff", "Human" },
	{ "Will of the Forsaken", 7744, "buff", "Undead" },
	{ "Cannibalize", 20577, "buff", "Undead" },
	{ "Gift of the Naaru", 28880, "buff", "Draenei" },
}

-- Buffs from consumables, world buffs and equipment. The NAME is the buff's name, which is often
-- not the item's name (Flask of Supreme Power gives "Supreme Power"). { name, spellID or nil, kind, note }
ns.BOOK.ITEMS = {
	-- Everyday things, which used to have a chapter of their own
	{ "Well Fed", 19705, "buff", "Food" }, { "Food", 433, "buff", "Eating" },
	{ "Drink", 430, "buff", "Drinking" }, { "First Aid", 746, "buff", "Bandage" },
	{ "Essence of the Red", 23513, "buff", "BWL: Vaelastrasz" },
	{ "Flask of the Titans", 17626, nil, "Flask" }, { "Supreme Power", 17628, nil, "Flask" },
	{ "Distilled Wisdom", 17627, nil, "Flask" }, { "Chromatic Resistance", 17629, nil, "Flask" },
	{ "Petrification", 17624, nil, "Flask" },
	{ "Elixir of the Mongoose", 17538, nil, "Elixir" }, { "Elixir of the Giants", 11405, nil, "Elixir" },
	{ "Greater Agility", 11334, nil, "Elixir" }, { "Agility", 11328, nil, "Elixir or scroll" },
	{ "Elixir of Brute Force", 17537, nil, "Elixir" }, { "Greater Arcane Elixir", 17539, nil, "Elixir" },
	{ "Arcane Elixir", 11390, nil, "Elixir" }, { "Shadow Power", 11474, nil, "Elixir" },
	{ "Greater Firepower", 26276, nil, "Elixir" }, { "Fire Power", 7844, nil, "Elixir" },
	{ "Frost Power", 21920, nil, "Elixir" }, { "Health II", 3593, nil, "Elixir of Fortitude" },
	{ "Greater Armor", 11348, nil, "Elixir of Superior Defense" }, { "Elixir of the Sages", 17535, nil, "Elixir" },
	{ "Greater Intellect", 11396, nil, "Elixir" }, { "Regeneration", nil, nil, "Troll's Blood Potion" },
	{ "Mana Regeneration", 24363, nil, "Mageblood Potion" }, { "Gift of Arthas", 11371, nil, "Elixir" },
	{ "Winterfall Firewater", 17038, nil, "Consumable" }, { "Rumsey Rum Black Label", 25804, nil, "Drink" },
	{ "Juju Power", 16323, nil, "Juju" }, { "Juju Might", 16329, nil, "Juju" }, { "Juju Flurry", 16322, nil, "Juju" },
	{ "Juju Ember", 16326, nil, "Juju" }, { "Juju Chill", 16325, nil, "Juju" }, { "Juju Guile", 16327, nil, "Juju" },
	{ "Juju Escape", 16321, nil, "Juju" },
	{ "Rage of Ages", 10667, nil, "Blasted Lands" }, { "Strike of the Scorpok", 10669, nil, "Blasted Lands" },
	{ "Spirit of Boar", 10668, nil, "Blasted Lands" }, { "Infallible Mind", 10692, nil, "Blasted Lands" },
	{ "Spiritual Domination", 10693, nil, "Blasted Lands" },
	{ "Spirit of Zanza", 24382, nil, "Zanza" }, { "Swiftness of Zanza", 24383, nil, "Zanza" },
	{ "Sheen of Zanza", 24417, nil, "Zanza" },
	{ "Greater Stoneshield", 17540, nil, "Potion" }, { "Free Action", 6615, nil, "Potion" },
	{ "Invulnerability", 3169, nil, "Potion" }, { "Restoration", 11359, nil, "Potion" },
	{ "Speed", 2379, nil, "Swiftness Potion" }, { "Mighty Rage", 17528, nil, "Potion" },
	{ "Fire Protection", 17543, nil, "Potion" }, { "Frost Protection", 17544, nil, "Potion" },
	{ "Nature Protection", 17546, nil, "Potion" }, { "Shadow Protection", 17548, nil, "Potion" },
	{ "Arcane Protection", 17549, nil, "Potion" }, { "Holy Protection", 17545, nil, "Potion" },
	{ "Noggenfogger Elixir", 16595, nil, "Consumable" },
	{ "Strength", 8118, nil, "Scroll" }, { "Stamina", 8099, nil, "Scroll" }, { "Intellect", 8096, nil, "Scroll" },
	{ "Spirit", 8112, nil, "Scroll" }, { "Armor", 8091, nil, "Scroll of Protection" },
	{ "Rallying Cry of the Dragonslayer", 22888, nil, "World buff" }, { "Warchief's Blessing", 16609, nil, "World buff" },
	{ "Spirit of Zandalar", 24425, nil, "World buff" }, { "Songflower Serenade", 15366, nil, "World buff" },
	{ "Fengus' Ferocity", 22817, nil, "Dire Maul" }, { "Mol'dar's Moxie", 22818, nil, "Dire Maul" },
	{ "Slip'kik's Savvy", 22820, nil, "Dire Maul" },
	{ "Sayge's Dark Fortune of Damage", 23768, nil, "Darkmoon Faire" }, { "Sayge's Dark Fortune of Agility", 23736, nil, "Darkmoon Faire" },
	{ "Sayge's Dark Fortune of Intelligence", 23766, nil, "Darkmoon Faire" }, { "Sayge's Dark Fortune of Spirit", 23738, nil, "Darkmoon Faire" },
	{ "Sayge's Dark Fortune of Stamina", 23737, nil, "Darkmoon Faire" }, { "Sayge's Dark Fortune of Strength", 23735, nil, "Darkmoon Faire" },
	{ "Sayge's Dark Fortune of Armor", 23767, nil, "Darkmoon Faire" }, { "Sayge's Dark Fortune of Resistance", 23769, nil, "Darkmoon Faire" },
	{ "Traces of Silithyst", 29534, nil, "Silithus" },
	{ "Earthstrike", 25891, nil, "Trinket" }, { "Kiss of the Spider", 28866, nil, "Trinket" },
	{ "Slayer's Crest", 28777, nil, "Trinket" }, { "Diamond Flask", 24427, nil, "Trinket" },
	{ "Insight of the Qiraji", nil, nil, "Badge of the Swarmguard" }, { "Ephemeral Power", 23271, nil, "Trinket" },
	{ "Unstable Power", 24658, nil, "Zandalarian Hero Charm" }, { "Restless Strength", 24661, nil, "Zandalarian Hero Badge" },
	{ "Mind Quickening", 23723, nil, "Trinket" }, { "Essence of Sapphiron", 28779, nil, "Trinket" },
	{ "Jom Gabbar", 29602, nil, "Trinket" }, { "Holy Strength", 20007, nil, "Crusader enchant" },
	{ "Rocket Boots Engaged", 8892, nil, "Engineering" },
}

-- Auras that dungeon and raid mobs put on players. Debuffs unless marked. IDs are nil where I was
-- not sure of them: those show a question mark until the aura is first seen, and track fine by name.
local D = "debuff"
ns.BOOK.PVE = {
	{ "Dazed", 1604, D, "Any mob hitting your back" },
	{ "Mortal Strike", nil, D, "Many mobs and bosses" }, { "Sunder Armor", nil, D, "Many mobs" },
	{ "Curse of Tongues", nil, D, "Casters, Ossirian" }, { "Disarm", 6713, D, "Many mobs" },
	-- Molten Core
	{ "Lucifron's Curse", 19703, D, "MC: Lucifron" }, { "Impending Doom", 19702, D, "MC: Lucifron" },
	{ "Dominate Mind", 20604, D, "MC: Lucifron's adds" }, { "Panic", 19408, D, "MC: Magmadar" },
	{ "Gehennas' Curse", 19716, D, "MC: Gehennas" }, { "Rain of Fire", 19717, D, "MC: Gehennas" },
	{ "Magma Shackles", 19496, D, "MC: Garr" }, { "Living Bomb", 20475, D, "MC: Baron Geddon" },
	{ "Ignite Mana", 19659, D, "MC: Baron Geddon" }, { "Shazzrah's Curse", 19713, D, "MC: Shazzrah" },
	{ "Hand of Ragnaros", 19780, D, "MC: Sulfuron" }, { "Magma Splash", nil, D, "MC: Golemagg" },
	{ "Wrath of Ragnaros", 20566, D, "MC: Ragnaros" }, { "Elemental Fire", 20564, D, "MC: Ragnaros" },
	-- Onyxia
	{ "Bellowing Roar", 18431, D, "Onyxia, Nefarian" },
	-- Blackwing Lair
	{ "Conflagration", 23023, D, "BWL: Razorgore" }, { "Burning Adrenaline", 18173, D, "BWL: Vaelastrasz" },
	{ "Flame Buffet", 23341, D, "BWL: drakes" },
	{ "Shadow of Ebonroc", 23340, D, "BWL: Ebonroc" },
	{ "Brood Affliction: Blue", 23153, D, "BWL: Chromaggus" }, { "Brood Affliction: Black", 23154, D, "BWL: Chromaggus" },
	{ "Brood Affliction: Red", 23155, D, "BWL: Chromaggus" }, { "Brood Affliction: Bronze", 23170, D, "BWL: Chromaggus" },
	{ "Brood Affliction: Green", 23169, D, "BWL: Chromaggus" }, { "Ignite Flesh", 23315, D, "BWL: Chromaggus" },
	{ "Corrosive Acid", 23313, D, "BWL: Chromaggus" }, { "Frost Burn", 23189, D, "BWL: Chromaggus" },
	{ "Incinerate", 23308, D, "BWL: Chromaggus" }, { "Time Lapse", nil, D, "BWL: Chromaggus" },
	{ "Veil of Shadow", 22687, D, "BWL: Nefarian" }, { "Shadow Flame", 22539, D, "BWL: Nefarian" },
	-- Zul'Gurub
	{ "Holy Fire", 23860, D, "ZG: Venoxis" }, { "Threatening Gaze", 24314, D, "ZG: Mandokir" },
	{ "Enveloping Webs", 24110, D, "ZG: Mar'li" }, { "Mark of Arlokk", 24210, D, "ZG: Arlokk" },
	{ "Delusions of Jin'do", 24306, D, "ZG: Jin'do" }, { "Corrupted Blood", 24328, D, "ZG: Hakkar" },
	{ "Cause Insanity", 24327, D, "ZG: Hakkar" }, { "Blood Siphon", nil, D, "ZG: Hakkar" },
	-- Ahn'Qiraj
	{ "Mortal Wound", 25646, D, "Kurinnaxx, Fankriss, Gluth" }, { "Sand Trap", 25656, D, "AQ20: Kurinnaxx" },
	{ "Creeping Plague", 20512, D, "AQ20: Buru" }, { "Paralyze", 25725, D, "AQ20: Ayamiss" },
	{ "Enveloping Winds", 25189, D, "AQ20: Ossirian" },
	{ "True Fulfillment", 785, D, "AQ40: Skeram" }, { "Toxic Volley", 25812, D, "AQ40: Bug Trio" },
	{ "Wyvern Sting", 26180, D, "AQ40: Huhuran" }, { "Noxious Poison", 26053, D, "AQ40: Huhuran" },
	{ "Poison Bolt Volley", 25991, D, "Viscidus, Faerlina" }, { "Unbalancing Strike", 26613, D, "AQ40: Twin Emperors" },
	{ "Sand Blast", 26102, D, "AQ40: Ouro" }, { "Digestive Acid", 26476, D, "AQ40: C'Thun" },
	{ "Mind Flay", 26143, D, "AQ40: C'Thun" },
	-- Naxxramas
	{ "Locust Swarm", 28786, D, "Naxx: Anub'Rekhan" }, { "Web Wrap", 28622, D, "Naxx: Maexxna" },
	{ "Web Spray", 29484, D, "Naxx: Maexxna" }, { "Necrotic Poison", 28776, D, "Naxx: Maexxna" },
	{ "Curse of the Plaguebringer", 29213, D, "Naxx: Noth" }, { "Decrepit Fever", 29998, D, "Naxx: Heigan" },
	{ "Corrupted Mind", 29201, D, "Naxx: Loatheb" }, { "Inevitable Doom", 29204, D, "Naxx: Loatheb" },
	{ "Harvest Soul", 28679, D, "Naxx: Gothik" },
	{ "Mark of Korth'azz", 28832, D, "Naxx: Four Horsemen" }, { "Mark of Blaumeux", 28833, D, "Naxx: Four Horsemen" },
	{ "Mark of Mograine", 28834, D, "Naxx: Four Horsemen" }, { "Mark of Zeliek", 28835, D, "Naxx: Four Horsemen" },
	{ "Mutating Injection", 28169, D, "Naxx: Grobbulus" }, { "Positive Charge", 28059, D, "Naxx: Thaddius" },
	{ "Negative Charge", 28084, D, "Naxx: Thaddius" }, { "Frost Aura", 28531, D, "Naxx: Sapphiron" },
	{ "Life Drain", 28542, D, "Naxx: Sapphiron" }, { "Icebolt", 28522, D, "Naxx: Sapphiron" },
	{ "Chill", 28547, D, "Naxx: Sapphiron" }, { "Frost Blast", 27808, D, "Naxx: Kel'Thuzad" },
	{ "Detonate Mana", 27819, D, "Naxx: Kel'Thuzad" }, { "Chains of Kel'Thuzad", 28410, D, "Naxx: Kel'Thuzad" },
	-- Dungeons
	{ "Unholy Aura", 17467, D, "Stratholme: Baron Rivendare" }, { "Hand of Thaurissan", 17492, D, "BRD: Emperor" },
}

-- The Dungeons and raids chapter (mob debuffs on you) is kept in the data but not offered: on this
-- client a debuff on you cannot be tracked by spell in combat. A group with Contents "Debuffs on me"
-- shows them all instead.
-- Every rank id of the book's multi-rank buffs, by spell name. Checked against the client by
-- ns.Ranks: an id that comes back under another name is dropped.
-- The group versions with a single rank are kept here by hand (the generated table only has spells
-- with several), so a group that watches your party can count them too.
ns.RANK_IDS = ns.RANK_IDS or {
	["Detect Invisibility"] = { 132, 2970, 11743 },
	["Arcane Brilliance"] = { 23028 },
	["Prayer of Spirit"] = { 27681 },
	["Prayer of Shadow Protection"] = { 27683 },
	["Blessing of Kings"] = { 20217 },
	["Blessing of Salvation"] = { 1038 },
	["Blessing of Sanctuary"] = { 20911, 20912, 20913, 20914 },
	["Greater Blessing of Kings"] = { 25898 },
	["Greater Blessing of Salvation"] = { 25895 },
	["Greater Blessing of Light"] = { 25890 },
	["Greater Blessing of Sanctuary"] = { 25899 },
	["Soulstone Resurrection"] = { 20707, 20762, 20763, 20764, 20765 },
}

ns.BOOK_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID", "GROUP", "RACIAL", "BAGS", "ITEMS" }

-- ------------------------------------------------------------------
-- Your party and raid
-- ------------------------------------------------------------------
-- Buffs that stand in for one another: the group version of a buff is as good as the single one, so
-- a group that watches your party counts either. (A group that watches only you matches by name,
-- as it always has.)
ns.BUFF_FAMILIES = {
	{ "Power Word: Fortitude", "Prayer of Fortitude" },
	{ "Arcane Intellect", "Arcane Brilliance" },
	{ "Mark of the Wild", "Gift of the Wild" },
	{ "Divine Spirit", "Prayer of Spirit" },
	{ "Shadow Protection", "Prayer of Shadow Protection" },
	{ "Blessing of Might", "Greater Blessing of Might" },
	{ "Blessing of Wisdom", "Greater Blessing of Wisdom" },
	{ "Blessing of Kings", "Greater Blessing of Kings" },
	{ "Blessing of Salvation", "Greater Blessing of Salvation" },
	{ "Blessing of Light", "Greater Blessing of Light" },
	{ "Blessing of Sanctuary", "Greater Blessing of Sanctuary" },
}
local familyIndex
function ns.FamilyOf(name)
	if type(name) ~= "string" then return nil end
	if not familyIndex then
		familyIndex = {}
		for _, family in ipairs(ns.BUFF_FAMILIES) do
			for _, n in ipairs(family) do familyIndex[string.lower(n)] = family end
		end
	end
	return familyIndex[string.lower(name)]
end

-- What each class can remove, for the hints and the preset only: the game itself decides what
-- "something I can remove" means.
ns.DISPEL_TYPES = { Magic = true, Curse = true, Poison = true, Disease = true }
ns.DISPEL_BY_CLASS = {
	PRIEST = { "Magic", "Disease" },
	PALADIN = { "Magic", "Poison", "Disease" },
	DRUID = { "Curse", "Poison" },
	MAGE = { "Curse" },
	SHAMAN = { "Poison", "Disease" },
}
ns.DISPEL_ICON = {
	Magic = "Interface\\Icons\\Spell_Holy_DispelMagic",
	Curse = "Interface\\Icons\\Spell_Holy_RemoveCurse",
	Poison = "Interface\\Icons\\Spell_Nature_NullifyPoison",
	Disease = "Interface\\Icons\\Spell_Holy_NullifyDisease",
}
-- "Anything I can remove" wears your own class's dispel.
local CLASS_DISPEL = { PRIEST = "Magic", PALADIN = "Interface\\Icons\\Spell_Holy_Renew", DRUID = "Curse", MAGE = "Curse", SHAMAN = "Poison" }

function ns.PlayerClass()
	if ns.env and ns.env.class then return ns.env.class end
	if UnitClass then
		local ok, _, token = pcall(UnitClass, "player")
		token = ok and ns.Clean(token) or nil
		if type(token) == "string" then return token end
	end
end

function ns.DispelIcon(kind)
	if kind ~= "any" then return ns.DISPEL_ICON[kind] or ns.DISPEL_ICON.Magic end
	local own = CLASS_DISPEL[ns.PlayerClass() or ""]
	return ns.DISPEL_ICON[own or "Magic"] or own
end

-- The names a dispel tracker is given, which it keeps until you rename it.
ns.DISPEL_NAMES = { any = "Something I can remove", Magic = "Magic", Curse = "Curse", Poison = "Poison", Disease = "Disease" }

-- The buffs a class sets up on its party in one go; ifKnown ones only when you have the spell.
ns.PARTY_PRESETS = {
	PRIEST = { buffs = { { "Power Word: Fortitude" }, { "Divine Spirit", ifKnown = true }, { "Shadow Protection" } } },
	MAGE = { buffs = { { "Arcane Intellect" } } },
	DRUID = { buffs = { { "Mark of the Wild" } } },
	WARLOCK = { buffs = { { "Blood Pact" } } },
	WARRIOR = { buffs = { { "Battle Shout" } } },
	HUNTER = { buffs = { { "Trueshot Aura", ifKnown = true } } },
}

-- The buffs worth watching on everyone, with their book ids and the partner that also counts.
local GROUP_BUFFS = {
	{ "Power Word: Fortitude", 1243 }, { "Divine Spirit", 14752 }, { "Shadow Protection", 976 },
	{ "Arcane Intellect", 1459 }, { "Mark of the Wild", 1126 },
	{ "Blessing of Might", 19740 }, { "Blessing of Wisdom", 19742 }, { "Blessing of Kings", 20217 },
	{ "Blessing of Salvation", 1038 }, { "Blessing of Light", 19977 }, { "Blessing of Sanctuary", 20911 },
	{ "Blood Pact", 6307 }, { "Battle Shout", 6673 }, { "Trueshot Aura", 19506 },
}

-- The page itself. Rebuilt when your class is first known, since two of its rows depend on it.
function ns.BuildGroupPage()
	local class = ns.PlayerClass()
	local list = {}
	local function row(t)
		t.prebuilt, t.class, t.kind = true, "GROUP", t.kind or "buff"
		list[#list + 1] = t
		return t
	end
	local preset = class and ns.PARTY_PRESETS[class]
	if preset or (class and ns.DISPEL_BY_CLASS[class]) then
		row({ name = "Party buffs for my class", preset = class, resolved = true, icon = "Interface\\Icons\\Spell_Holy_PrayerOfFortitude",
			note = "Sets up a group that watches your party" })
	end
	row({ name = ns.DISPEL_NAMES.any, matchDispel = "any", units = "party", kind = "debuff", resolved = true, icon = ns.DispelIcon("any"),
		note = "On each party member: a debuff you can dispel" })
	for _, kind in ipairs({ "Curse", "Magic", "Poison", "Disease" }) do
		row({ name = ns.DISPEL_NAMES[kind], matchDispel = kind, dispel = kind, kind = "debuff", resolved = true, icon = ns.DispelIcon(kind),
			note = "On you, or on each member in a party group" })
	end
	for _, b in ipairs(GROUP_BUFFS) do
		local family = ns.FamilyOf(b[1])
		local partner
		for _, n in ipairs(family or {}) do if n ~= b[1] then partner = n end end
		row({ name = b[1], listId = b[2], units = "party", show = "missing",
			note = partner and ("On each party member, or " .. partner) or "On each party member" })
	end
	row({ name = "Soulstone Resurrection", listId = 20707, units = "party", show = "active", note = "Who has a Soulstone" })
	list.forClass = class
	return list
end

-- ------------------------------------------------------------------
-- What you are carrying
-- ------------------------------------------------------------------
-- Anything in your bags or on your back with a use on it. Only the use matters: an item with no
-- use has no cooldown to follow. Read again when the bags change, and kept to what the client will
-- actually tell us, which on a client that hides one of these calls is nothing at all.
local BAGS = { 0, 1, 2, 3, 4, 5 }
-- Trinkets first, since they are what anyone is really after, then the rest of the gear that
-- commonly carries a use.
local GEAR = { 13, 14, 1, 2, 15, 10, 11, 12, 6, 8, 16, 17 }

local function ItemSpell(id)
	if C_Item and C_Item.GetItemSpell then
		local ok, name, spellId = pcall(C_Item.GetItemSpell, id)
		if ok and (name or spellId) then return name, spellId end
	end
	if GetItemSpell then
		local ok, name, spellId = pcall(GetItemSpell, id)
		if ok and (name or spellId) then return name, spellId end
	end
end

local function ItemName(id)
	if C_Item and C_Item.GetItemNameByID then
		local ok, name = pcall(C_Item.GetItemNameByID, id)
		if ok and name then return name end
	end
	if C_Item and C_Item.GetItemInfo then
		local ok, name = pcall(C_Item.GetItemInfo, id)
		if ok and name then return name end
	end
	if GetItemInfo then
		local ok, name = pcall(GetItemInfo, id)
		if ok and name then return name end
	end
end

local function ItemIcon(id)
	if C_Item and C_Item.GetItemIconByID then
		local ok, icon = pcall(C_Item.GetItemIconByID, id)
		if ok and icon then return icon end
	end
	if GetItemIcon then
		local ok, icon = pcall(GetItemIcon, id)
		if ok and icon then return icon end
	end
end
ns.ItemName, ns.ItemIcon, ns.ItemSpell = ItemName, ItemIcon, ItemSpell

local function BagSlots(bag)
	if C_Container and C_Container.GetContainerNumSlots then
		local ok, n = pcall(C_Container.GetContainerNumSlots, bag)
		if ok and type(n) == "number" then return n end
	end
	if GetContainerNumSlots then
		local ok, n = pcall(GetContainerNumSlots, bag)
		if ok and type(n) == "number" then return n end
	end
	return 0
end

local function BagItem(bag, slot)
	if C_Container and C_Container.GetContainerItemID then
		local ok, id = pcall(C_Container.GetContainerItemID, bag, slot)
		if ok and type(id) == "number" then return id end
	end
	if GetContainerItemID then
		local ok, id = pcall(GetContainerItemID, bag, slot)
		if ok and type(id) == "number" then return id end
	end
end

ns.bagStats = { bags = 0, gear = 0, withUse = 0, unnamed = 0 }

-- The page itself: one row per item you are carrying that has a use on it.
function ns.BuildBagPage()
	local list, seen = {}, {}
	local stats = { bags = 0, gear = 0, withUse = 0, unnamed = 0 }
	local function offer(id, where)
		if not id or seen[id] then return end
		seen[id] = true
		local useName, useSpell = ItemSpell(id)
		if not (useName or useSpell) then return end
		stats.withUse = stats.withUse + 1
		local name = ItemName(id)
		if not name then stats.unnamed = stats.unnamed + 1 return end
		list[#list + 1] = {
			name = name, icon = ItemIcon(id), item = id, cd = true, kind = "buff",
			note = where, prebuilt = true, class = "BAGS", resolved = true,
			useName = useName, useSpell = useSpell,
		}
	end
	for _, bag in ipairs(BAGS) do
		local n = BagSlots(bag)
		for slot = 1, n do
			local id = BagItem(bag, slot)
			if id then stats.bags = stats.bags + 1 offer(id, "In your bags") end
		end
	end
	if GetInventoryItemID then
		for _, slot in ipairs(GEAR) do
			local ok, id = pcall(GetInventoryItemID, "player", slot)
			if ok and type(id) == "number" then stats.gear = stats.gear + 1 offer(id, "Worn") end
		end
	end
	table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
	-- Your weapons come first: their temporary enchants and their swings, which the addon reads itself.
	local weapons = {
		{ "Main-hand enchant", "enchant", 0, "Oil, stone, poison or imbue on your main hand" },
		{ "Off-hand enchant", "enchant", 1, "Oil, stone, poison or imbue on your off hand" },
		{ "Ranged enchant", "enchant", 2, "Temporary enchant on your ranged weapon" },
		{ "Main-hand swing", "swing", 0, "Time to your next main-hand swing" },
		{ "Off-hand swing", "swing", 1, "Time to your next off-hand swing" },
		{ "Ranged swing", "swing", 2, "Time to your next ranged shot or wand" },
	}
	for i = #weapons, 1, -1 do
		local w = weapons[i]
		local row = { name = w[1], kind = "buff", note = w[4], prebuilt = true, class = "BAGS", resolved = true,
			icon = ns.WeaponIcon and ns.WeaponIcon(w[3]) or nil }
		row[w[2]] = w[3]
		table.insert(list, 1, row)
	end
	ns.bagStats = stats
	return list
end

-- Turn the raw rows into objects shaped like ledger rows, once.
local built
function ns.BookPages()
	-- The party page depends on your class, which is not known the moment the addon loads.
	if built and built.GROUP and built.GROUP.forClass == nil and ns.PlayerClass() then built.GROUP = ns.BuildGroupPage() end
	if built then return built end
	built = {}
	for token, rows in pairs(ns.BOOK) do
		local list = {}
		for _, row in ipairs(rows) do
			-- Debuff rows are left out: a debuff on you cannot be followed by spell in combat.
			if (row[3] or "buff") ~= "debuff" then
				list[#list + 1] = { name = row[1], listId = row[2], kind = row[3] or "buff", note = row[4], prebuilt = true, class = token }
			end
		end
		built[token] = list
	end
	built.BAGS = ns.BuildBagPage()
	built.GROUP = ns.BuildGroupPage()
	return built
end

-- Read again when what you are carrying changes.
function ns.RefreshBagPage()
	if not built then return end
	built.BAGS = ns.BuildBagPage()
	if ns.UI and ns.UI.RefreshHistory then ns.UI:RefreshHistory() end
end

-- ------------------------------------------------------------------
-- Racials the client knows about
-- ------------------------------------------------------------------
-- The written list above cannot know about a racial this client added after it was written. Your
-- own race's are in the client's spellbook, so they are read out of it and folded into the page.
-- Only your own race's can be had this way; /auraledger racials reports what was found so the
-- written list can be finished for the rest.
ns.racialStats = { api = "none", line = "none", lines = 0, scanned = 0, found = 0, added = 0 }

local function SpellBookGeneral()
	-- Returns a list of { name, id }, and the name of the call that worked.
	-- Each entry also says whether it is a spell you have learned (itemType 1), passive, off your
	-- spec, a lower rank of one you know, and whether its line is one the book should skip (hidden,
	-- a guild line, an off-spec line). None of it is ever hidden from addons; it is cleaned anyway.
	local out = {}
	local C = ns.Clean
	if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookItemInfo then
		local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
		local okN, lines = pcall(C_SpellBook.GetNumSpellBookSkillLines)
		if okN and type(lines) == "number" then
			ns.racialStats.lines = lines
			for line = 1, lines do
				local okL, info = pcall(C_SpellBook.GetSpellBookSkillLineInfo, line)
				if okL and type(info) == "table" and info.itemIndexOffset and info.numSpellBookItems then
					local skip = C(info.shouldHide) == true or C(info.isGuild) == true or C(info.offSpecID) ~= nil
					for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
						local okI, item = pcall(C_SpellBook.GetSpellBookItemInfo, i, bank)
						if okI and type(item) == "table" and item.name and item.spellID then
							local low = false
							if C_SpellBook.IsSpellBookItemLowRank then
								local okLo, v = pcall(C_SpellBook.IsSpellBookItemLowRank, i, bank)
								low = okLo and C(v) == true
							end
							out[#out + 1] = { name = item.name, id = item.spellID, line = info.name, lineIndex = line,
								icon = C(item.iconID), itemType = C(item.itemType), passive = C(item.isPassive) == true,
								offSpec = C(item.isOffSpec) == true, low = low, lineSkip = skip }
						end
					end
				end
			end
			if #out > 0 then return out, "C_SpellBook" end
		end
	end
	if GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo and GetSpellBookItemName then
		local okN, tabs = pcall(GetNumSpellTabs)
		if okN and type(tabs) == "number" then
			ns.racialStats.lines = tabs
			for tab = 1, tabs do
				local okT, tabName, _, offset, count = pcall(GetSpellTabInfo, tab)
				if okT and type(offset) == "number" and type(count) == "number" then
					for i = offset + 1, offset + count do
						local okI, name = pcall(GetSpellBookItemName, i, "spell")
						local okT, kind, id = pcall(GetSpellBookItemInfo, i, "spell")
						if okI and name then
							out[#out + 1] = { name = name, id = okT and tonumber(id) or nil, line = tabName,
								itemType = (kind == "SPELL" and 1) or (kind == "FUTURESPELL" and 2) or nil }
						end
					end
				end
			end
			if #out > 0 then return out, "GetSpellBookItemName" end
		end
	end
	return out, "none"
end
ns.SpellBookGeneral = SpellBookGeneral

-- Everything the book already offers, by lowercased name, so a spell is not listed twice.
local function BookKnows(pages)
	local known = {}
	for _, list in pairs(pages) do
		for _, item in ipairs(list) do
			if item.name and not item.spellCd then known[item.name:lower()] = true end
		end
	end
	return known
end

-- The order of a chapter: the written rows as they are, then rows read from the client by name, the
-- cooldown rows last.
local function BookOrder(a, b)
	local ac, bc = a.spellCd and 1 or 0, b.spellCd and 1 or 0
	if ac ~= bc then return ac < bc end
	local an, bn = (a.name or ""):lower(), (b.name or ""):lower()
	if an ~= bn then return an < bn end
	return (a.listId or 0) < (b.listId or 0)
end

local function PlayerRace()
	if UnitRace then
		local okR, localized = pcall(UnitRace, "player")
		localized = okR and ns.Clean(localized) or nil
		if type(localized) == "string" then return localized end
	end
	return "Yours"
end

-- Only one line of the spellbook holds the racials: the one named after your race, or the general
-- one. Everything else is class spells. If neither name turns up, the first line is the general one
-- on every layout seen so far. Returns the line, and whether it was found by name.
local function RacialLine(spells, race)
	for _, spell in ipairs(spells) do
		if spell.line and (spell.line == race or spell.line == "General" or (GENERAL and spell.line == GENERAL)) then
			return spell.line, "named"
		end
	end
	return spells[1] and spells[1].line, "first"
end

-- Names that turn up in the same part of the spellbook as the racials but are not racials.
local NOT_RACIAL = {
	["attack"] = true, ["shoot"] = true, ["auto shot"] = true, ["throw"] = true,
	["cooking"] = true, ["first aid"] = true, ["fishing"] = true, ["riding"] = true,
	["mining"] = true, ["herbalism"] = true, ["skinning"] = true, ["smelting"] = true,
	["blacksmithing"] = true, ["leatherworking"] = true, ["alchemy"] = true, ["tailoring"] = true,
	["enchanting"] = true, ["engineering"] = true, ["jewelcrafting"] = true, ["inscription"] = true,
	["lockpicking"] = true, ["beast training"] = true, ["defense"] = true, ["dodge"] = true,
	["parry"] = true, ["block"] = true, ["language"] = true, ["apprentice riding"] = true,
}

function ns.LearnRacials()
	local pages = ns.BookPages()
	local racials = pages.RACIAL
	if not racials then return end
	local spells, api = SpellBookGeneral()
	ns.racialStats.api = api
	ns.racialStats.scanned = #spells
	local known = BookKnows(pages)
	local race = PlayerRace()
	local wanted = RacialLine(spells, race)
	ns.racialStats.line = wanted or "none"
	local found, added = 0, 0
	for _, spell in ipairs(spells) do
		local low = spell.name:lower()
		-- A racial is on that line, is not one of the handful of things that are never racials, and
		-- is not something the book already offers.
		if spell.line == wanted and spell.itemType ~= 2 and not NOT_RACIAL[low] and not low:find("language", 1, true) then
			found = found + 1
			if not known[low] then
				known[low] = true
				added = added + 1
				racials[#racials + 1] = {
					name = spell.name, listId = spell.id, id = spell.id, kind = "buff",
					note = race, prebuilt = true, class = "RACIAL", fromClient = true,
					icon = select(2, ns.SpellInfo(spell.id)),
				}
			end
		end
	end
	ns.racialStats.found, ns.racialStats.added = found, added
	table.sort(racials, BookOrder)
end

-- ------------------------------------------------------------------
-- Your spells with a cooldown
-- ------------------------------------------------------------------
-- Read from your own spellbook: every spell you have learned that has a cooldown longer than the
-- global one, as a row in your class chapter (racials in the Racials chapter) that makes a cooldown
-- tracker. This client has no documented call for a spell's cooldown length, so it is taken from the
-- first of these that knows: the base-cooldown call if the client has one, the spell's own tooltip
-- (in the client's own words for a cooldown), its charges, a length read before while tracking it,
-- and the Cooldown Manager's own list of your cooldowns (which gives no length).
local GCD = 1.5
local cdInfo, tipTries = {}, {}
-- A spell's text has arrived: one given up on for want of it is read again.
function ns.SpellTextArrived(id)
	if type(id) == "number" and cdInfo[id] == false and tipTries[id] then
		cdInfo[id], tipTries[id] = nil, nil
		return true
	end
	return false
end
function ns.ForgetSpellCooldownEvidence()
	for k in pairs(cdInfo) do cdInfo[k] = nil end
	for k in pairs(tipTries) do tipTries[k] = nil end
end

local function BaseCooldown(id)
	local fn = _G.GetSpellBaseCooldown or (C_Spell and C_Spell.GetSpellBaseCooldown)
	if type(fn) ~= "function" then return nil end
	local ok, ms = pcall(fn, id)
	ms = ok and ns.Clean(ms) or nil
	if type(ms) ~= "number" or ms <= 0 then return nil end
	return ms / 1000
end

-- The client's own wording for a cooldown on a spell's tooltip, as patterns that match a whole line.
local recastPatterns
local function RecastPatterns()
	if recastPatterns then return recastPatterns end
	recastPatterns = {}
	local defs = {
		{ "SPELL_RECAST_TIME_SEC", "%s sec cooldown", 1 }, { "SPELL_RECAST_TIME_MIN", "%s min cooldown", 60 },
		{ "SPELL_RECAST_TIME_HOURS", "%s hr cooldown", 3600 }, { "SPELL_RECAST_TIME_DAYS", "%s day cooldown", 86400 },
		{ "SPELL_RECAST_TIME_CHARGES_SEC", nil, 1 }, { "SPELL_RECAST_TIME_CHARGES_MIN", nil, 60 },
	}
	for _, d in ipairs(defs) do
		local fmt = _G[d[1]]
		if type(fmt) ~= "string" then fmt = d[2] end
		if fmt then
			local p = fmt:gsub("%%%d*%$?[%-%d%.]*[sdfg]", "\001")
			p = p:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
			p = p:gsub("\001", "([%%d%%.,]+)")
			recastPatterns[#recastPatterns + 1] = { pattern = "^%s*" .. p .. "%s*$", unit = d[3] }
		end
	end
	return recastPatterns
end
ns.ForgetRecastPatterns = function() recastPatterns = nil end

local function TooltipCooldown(id)
	local T = C_TooltipInfo
	if not (T and T.GetSpellByID) then return nil, "noapi" end
	local ok, data = pcall(T.GetSpellByID, id)
	data = ok and ns.Clean(data) or nil
	local lines = type(data) == "table" and ns.Clean(data.lines) or nil
	if type(lines) ~= "table" or #lines < 2 then
		if C_Spell and C_Spell.RequestLoadSpellData then pcall(C_Spell.RequestLoadSpellData, id) end
		return nil, "wait"
	end
	local pats = RecastPatterns()
	for i = 1, math.min(#lines, 8) do
		local line = ns.Clean(lines[i])
		if type(line) == "table" then
			for _, key in ipairs({ "rightText", "leftText" }) do
				local text = ns.Clean(line[key])
				if type(text) == "string" then
					for _, p in ipairs(pats) do
						local num = text:match(p.pattern)
						local v = num and tonumber((num:gsub(",", ".")))
						if v then return v * p.unit end
					end
				end
			end
		end
	end
	return nil, "none"
end

local function ChargesCooldown(id)
	if not (C_Spell and C_Spell.GetSpellCharges) then return nil end
	local ok, info = pcall(C_Spell.GetSpellCharges, id)
	info = ok and ns.Clean(info) or nil
	if type(info) ~= "table" then return nil end
	local most, len = ns.Clean(info.maxCharges), ns.Clean(info.cooldownDuration)
	if type(most) == "number" and most >= 1 and type(len) == "number" then return len end
end

-- The Cooldown Manager's list of your cooldowns, by spell id and by name.
local managerSet
function ns.ForgetManagerCooldowns() managerSet = nil end
local function ManagerSet()
	if managerSet then return managerSet end
	managerSet = { ids = {}, names = {} }
	local V = C_CooldownViewer
	local cats = Enum and Enum.CooldownViewerCategory
	if not (V and V.GetCooldownViewerCategorySet and V.GetCooldownViewerCooldownInfo and cats) then return managerSet end
	local function add(sid)
		sid = ns.Clean(sid)
		if type(sid) ~= "number" then return end
		managerSet.ids[sid] = true
		local n = ns.SpellInfo(sid)
		if type(n) == "string" then managerSet.names[n:lower()] = true end
	end
	for _, key in ipairs({ "Essential", "Utility", "SpecAgnosticEssential" }) do
		local cat = cats[key]
		if cat ~= nil then
			local ok, set = pcall(V.GetCooldownViewerCategorySet, cat, false)
			set = ok and ns.Clean(set) or nil
			for _, cid in ipairs(type(set) == "table" and set or {}) do
				local okI, info = pcall(V.GetCooldownViewerCooldownInfo, cid)
				info = okI and ns.Clean(info) or nil
				if type(info) == "table" then
					add(info.spellID)
					add(info.overrideSpellID)
					local linked = ns.Clean(info.linkedSpellIDs)
					for _, sid in ipairs(type(linked) == "table" and linked or {}) do add(sid) end
				end
			end
		end
	end
	return managerSet
end

-- A spell's cooldown: its length and where that came from, or nil and why not.
local function SpellCooldown(s)
	local low = s.name:lower()
	local c = cdInfo[s.id]
	if c then return c.len, c.src end
	if c == nil then
		-- The tooltip first: it states the cooldown as it is now, talents and all. The base call gives
		-- the spell's own, unchanged length, so it is asked only once the tooltip has had its say.
		local len, src
		local tip, why = TooltipCooldown(s.id)
		if tip and tip > GCD then len, src = tip, "tooltip" end
		if not len then
			local ch = ChargesCooldown(s.id)
			if ch and ch > GCD then len, src = ch, "charges" end
		end
		if not len and why == "wait" then
			tipTries[s.id] = (tipTries[s.id] or 0) + 1
			if tipTries[s.id] < 3 then return nil, "wait" end
		end
		if not len then
			local base = BaseCooldown(s.id)
			if base and base > GCD then len, src = base, "base" end
		end
		if len then
			cdInfo[s.id] = { len = len, src = src }
			return len, src
		end
		cdInfo[s.id] = false
	end
	-- Nothing said so: a length read while tracking it, or the manager listing it, still counts.
	local learned = ns.profile and ns.profile.cdLen and tonumber(ns.profile.cdLen[low])
	if learned and learned > GCD then return learned, "learned" end
	local set = ManagerSet()
	if set.ids[s.id] or set.names[low] then return nil, "manager" end
	return nil, "none"
end

-- "2 min cooldown", "1 min 30 sec cooldown", "10 sec cooldown"; plain "Cooldown" with no length.
local function CooldownWords(len)
	if not len then return "Cooldown" end
	local function num(v) if v == math.floor(v) then return tostring(math.floor(v)) end return ("%.1f"):format(v) end
	if len < 60 then return num(len) .. " sec cooldown" end
	if len < 3600 then
		local m, s = math.floor(len / 60), math.floor(len % 60 + 0.5)
		if s == 60 then m, s = m + 1, 0 end
		return m .. " min" .. (s > 0 and (" " .. s .. " sec") or "") .. " cooldown"
	end
	local h, m = math.floor(len / 3600), math.floor((len % 3600) / 60 + 0.5)
	if m == 60 then h, m = h + 1, 0 end
	return h .. " hr" .. (m > 0 and (" " .. m .. " min") or "") .. " cooldown"
end
ns.CooldownWords = CooldownWords

ns.cdBookStats = {}
local cdSig
function ns.LearnSpellCooldowns()
	local pages = ns.BookPages()
	local class = ns.PlayerClass()
	local spells, api = SpellBookGeneral()
	local st = { api = api, scanned = #spells, candidates = 0, rows = 0, class = 0, racial = 0, pending = 0, src = {},
		baseApi = type(_G.GetSpellBaseCooldown) == "function" or (C_Spell and type(C_Spell.GetSpellBaseCooldown) == "function") or false,
		tipApi = (C_TooltipInfo and C_TooltipInfo.GetSpellByID) and true or false, skipped = {} }
	ns.cdBookStats = st
	-- An early or failed read keeps what is there, as for the racials.
	if #spells == 0 then return end
	local race = PlayerRace()
	local racialLine, how = RacialLine(spells, race)
	local usable, nLines = {}, 0
	for _, s in ipairs(spells) do
		if not s.lineSkip and s.line and not usable[s.line] then usable[s.line] = true nLines = nLines + 1 end
	end
	-- A single line holds everything: nothing is taken for a racial.
	if how == "first" and nLines < 2 then racialLine = nil end
	st.racialLine = racialLine
	local keep, order = {}, {}
	for _, s in ipairs(spells) do
		local low = s.name:lower()
		local why = (s.itemType ~= nil and s.itemType ~= 1 and "not learned yet") or (s.passive and "passive")
			or (s.offSpec and "off your spec") or (s.low and "a lower rank") or (s.lineSkip and "on a hidden line")
			or ((NOT_RACIAL[low] or low:find("language", 1, true)) and "not a spell to track") or nil
		if why then
			st.skipped[#st.skipped + 1] = s.name .. ": " .. why
		else
			st.candidates = st.candidates + 1
			local token = (racialLine and s.line == racialLine) and "RACIAL" or class
			if token and pages[token] then
				local key = token .. "\0" .. low
				if not keep[key] then order[#order + 1] = key end
				-- Ranks come lowest first: the last one seen is the one to follow.
				keep[key] = { s = s, token = token }
			end
		end
	end
	local rows, sig = {}, { tostring(class) }
	for _, key in ipairs(order) do
		local e = keep[key]
		local len, src = SpellCooldown(e.s)
		st.src[src] = (st.src[src] or 0) + 1
		if src == "wait" then
			st.pending = st.pending + 1
		elseif len or src == "manager" then
			local s = e.s
			rows[#rows + 1] = {
				name = s.name, id = s.id, listId = s.id, icon = s.icon or select(2, ns.SpellInfo(s.id)),
				kind = "buff", cd = true, spellCd = true, cdLength = len, cdSource = src,
				note = (e.token == "RACIAL" and (race .. ", ") or "") .. CooldownWords(len),
				prebuilt = true, fromClient = true, class = e.token, resolved = true,
			}
			sig[#sig + 1] = e.token .. "|" .. s.name:lower() .. "|" .. tostring(s.id) .. "|" .. tostring(len)
		else
			st.skipped[#st.skipped + 1] = e.s.name .. ": no cooldown found"
		end
	end
	st.rows = #rows
	for _, r in ipairs(rows) do
		if r.class == "RACIAL" then st.racial = st.racial + 1 else st.class = st.class + 1 end
	end
	table.sort(sig)
	local sigText = table.concat(sig, ";")
	if sigText ~= cdSig then
		cdSig = sigText
		-- The rows read before go, and the new ones take their place after the written rows.
		local tokens = { "RACIAL" }
		if class then tokens[2] = class end
		for _, token in ipairs(tokens) do
			local list = pages[token]
			if list then
				for i = #list, 1, -1 do if list[i].spellCd then table.remove(list, i) end end
			end
		end
		table.sort(rows, BookOrder)
		for _, r in ipairs(rows) do
			local list = pages[r.class]
			list[#list + 1] = r
		end
		if pages.RACIAL then table.sort(pages.RACIAL, BookOrder) end
		if ns.UI and ns.UI.RefreshHistory then ns.UI:RefreshHistory() end
	end
	-- Spell text that had not loaded yet is asked for again shortly, a few times.
	if st.pending > 0 and (ns.cdRetry or 0) < 3 then
		ns.cdRetry = (ns.cdRetry or 0) + 1
		ns.QueueSpellCooldownRows(2)
	elseif st.pending == 0 then
		ns.cdRetry = 0
	end
end

-- Read again, soon and once: bursts of spellbook changes (a stance or a form change fires them too)
-- come to one read. Never in a fight.
function ns.QueueSpellCooldownRows(delay)
	if ns.cdQueued then return end
	ns.cdQueued = true
	local function go()
		ns.cdQueued = false
		if ns.WhenFree then ns.WhenFree("spell cooldown rows", function() pcall(ns.LearnSpellCooldowns) end) end
	end
	if C_Timer and C_Timer.After then C_Timer.After(delay or 0.5, go) else go() end
end

-- Look the spell up in the client. Cheap to call again; stops once it has an answer.
-- Spell data can arrive late, so a row is only withheld after the client has been asked for it
-- several times, a second apart, and still has nothing.
local WITHHOLD_AFTER = 3

function ns.ResolveBookItem(item)
	if item.resolved or not item.listId then return end
	local name, icon = ns.SpellInfo(item.listId)
	if not name and not icon then
		local now = GetTime and GetTime() or 0
		if now - (item.lastTry or -100) > 1 then
			item.lastTry = now
			item.tries = (item.tries or 0) + 1
			if C_Spell and C_Spell.RequestLoadSpellData then pcall(C_Spell.RequestLoadSpellData, item.listId) end
			if item.tries >= WITHHOLD_AFTER then item.unknown = true end
		end
		return -- not available (yet); try again next time it is drawn
	end
	item.resolved = true
	item.unknown = nil
	item.icon = icon
	if name == item.name then
		item.id = item.listId
	else
		item.clientName = name -- the ID is good for an icon at best
	end
end

-- Every row, not just the page on screen, so the withheld ones are known before anything is drawn.
function ns.ResolveAllBookItems()
	for _, list in pairs(ns.BookPages()) do
		for _, item in ipairs(list) do ns.ResolveBookItem(item) end
	end
end

function ns.BookStats()
	local total, exact, iconOnly, unknown = 0, 0, 0, 0
	for _, list in pairs(ns.BookPages()) do
		for _, item in ipairs(list) do
			-- Weapon, dispel and preset rows are not spells, and cooldown rows are counted apart.
			if item.enchant == nil and item.swing == nil and not item.matchDispel and not item.preset and not item.spellCd then
			ns.ResolveBookItem(item)
			total = total + 1
			if item.id then exact = exact + 1 elseif item.resolved then iconOnly = iconOnly + 1 else unknown = unknown + 1 end
			end
		end
	end
	return total, exact, iconOnly, unknown
end
