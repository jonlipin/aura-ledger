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
		{ "Detect Lesser Invisibility", 132 }, { "Detect Invisibility", 2970 }, { "Detect Greater Invisibility", 11743 },
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
ns.BOOK_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID", "RACIAL", "ITEMS" }

-- Turn the raw rows into objects shaped like ledger rows, once.
local built
function ns.BookPages()
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
	return built
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
			ns.ResolveBookItem(item)
			total = total + 1
			if item.id then exact = exact + 1 elseif item.resolved then iconOnly = iconOnly + 1 else unknown = unknown + 1 end
		end
	end
	return total, exact, iconOnly, unknown
end
