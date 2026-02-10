# Instance Tracker

A lightweight addon for **World of Warcraft 3.3.5a** (Wrath of the Lich King) that tracks your instance lockouts and the **5-per-hour instance cap**.

![Version](https://img.shields.io/badge/version-1.5.0-blue)
![Interface](https://img.shields.io/badge/interface-3.3.5a-orange)
![License](https://img.shields.io/badge/license-MIT-green)

---

## Features

### Hourly Instance Cap (5/hour)
- Automatically detects when you enter a dungeon or raid
- Tracks each entry with an individual **60-minute countdown timer**
- Displays how many of your 5 slots are used and how many remain
- Shows exactly when your next slot opens up
- **Account-wide tracking** — the 5/hour limit is per account, so instance entries are shared across all your characters

### Saved Lockouts
- Displays all your current **heroic daily** and **raid weekly** lockouts
- Shows reset timers and difficulty labels (Normal/Heroic, 10N/25N/10H/25H)
- Grouped by expansion in order: **Classic → The Burning Crusade → Wrath of the Lich King**

### Instance Database
Includes a comprehensive lookup table covering every dungeon and raid across all three expansions, with multiple name variants to handle different server naming formats:

| Expansion | Dungeons | Raids |
|-----------|----------|-------|
| Classic | Ragefire Chasm, Deadmines, Shadowfang Keep, Stockade, Blackfathom Deeps, Gnomeregan, Razorfen Kraul, Scarlet Monastery, Razorfen Downs, Uldaman, Zul'Farrak, Maraudon, Sunken Temple, Blackrock Depths, Dire Maul, Stratholme, Scholomance, LBRS, UBRS | Molten Core, Onyxia's Lair, Blackwing Lair, Zul'Gurub, Ruins of Ahn'Qiraj, Temple of Ahn'Qiraj |
| TBC | Hellfire Ramparts, Blood Furnace, Shattered Halls, Slave Pens, Underbog, Steamvault, Mana-Tombs, Auchenai Crypts, Sethekk Halls, Shadow Labyrinth, Old Hillsbrad, Black Morass, Mechanar, Botanica, Arcatraz, Magisters' Terrace | Karazhan, Gruul's Lair, Magtheridon's Lair, Serpentshrine Cavern, Tempest Keep, Hyjal Summit, Black Temple, Zul'Aman, Sunwell Plateau |
| WotLK | Utgarde Keep, Utgarde Pinnacle, The Nexus, Azjol-Nerub, Old Kingdom, Drak'Tharon Keep, Violet Hold, Gundrak, Halls of Stone, Halls of Lightning, Culling of Stratholme, The Oculus, Trial of the Champion, Forge of Souls, Pit of Saron, Halls of Reflection | Naxxramas, Obsidian Sanctum, Eye of Eternity, Vault of Archavon, Ulduar, Trial of the Crusader, Icecrown Citadel, Ruby Sanctum |

### UI Controls
- **Draggable & resizable** window
- **[x] buttons** next to each hourly entry to manually remove false entries
- **Reset button** in the title bar to reset all non-saved dungeon instances (same as `/script ResetInstances()`)
- **Minimap button** — left-click to toggle the window, right-click for a quick status in chat

### Auto-Warning
When you receive the *"You have entered too many instances recently"* system message, the addon automatically opens the tracker window and prints a warning in chat.

---

## Installation

1. Check Releases: https://github.com/FUG4Z1/InstanceTracker/releases
2. Copy the `InstanceTracker` folder into your addons directory:

```
World of Warcraft/Interface/AddOns/InstanceTracker/
```

3. Make sure the folder contains both files:

```
InstanceTracker/
├── InstanceTracker.toc
└── InstanceTracker.lua
```

4. Restart WoW or type `/reload`

---

## Usage

### Slash Commands

| Command | Description |
|---------|-------------|
| `/it` | Toggle the tracker window |
| `/itracker` | Toggle the tracker window (alias) |
| `/instancetracker` | Toggle the tracker window (alias) |
| `/it status` | Print your current hourly count to chat |
| `/it reset` | Clear the hourly instance history |

### Minimap Button

| Action | Result |
|--------|--------|
| Left-click | Toggle the tracker window |
| Right-click | Print quick status to chat |
| Hover | Tooltip showing current instance count |

---

## How the 5/Hour Limit Works

In WoW 3.3.5a, you can enter a maximum of **5 unique dungeon instances per hour per account**. Each entry starts its own independent 60-minute timer. When a timer expires, that slot opens up again.

This is a soft cap — it doesn't apply to raid instances you're already saved to. The addon tracks this by detecting zone changes into instanced content and recording the timestamp.

**Example:** If you enter 5 dungeons at 2:00, 2:10, 2:20, 2:30, and 2:40, your next available slot opens at 3:00 (when the first entry expires).

---

## FAQ

**Q: Why did it count an entry when I just walked out and back in?**
A: The addon has a 60-second grace period — re-entering the same dungeon within 60 seconds won't create a duplicate. If you walked out for longer than that, it counts as a new entry. Use the **[x]** button to remove any unwanted entries.

**Q: Does it track across characters?**
A: Yes. The 5/hour limit is account-wide in 3.3.5a, and the addon uses `SavedVariables` (not per-character), so your instance history is shared across all characters on the same server.

**Q: What does the Reset button do?**
A: It calls the WoW API `ResetInstances()` which resets all your non-saved dungeon instances. This is the same as right-clicking your portrait and selecting "Reset all instances". It does **not** clear your hourly tracker entries.

**Q: An instance showed up under "Other" instead of its expansion — why?**
A: The server reported the instance name in a format the addon didn't recognize. The addon has a fuzzy matching fallback that catches most variants, but if you find one that's missing, feel free to open an issue with the exact name the server uses.

---

## License

MIT — use it, modify it, share it.
