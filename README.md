# Instance Tracker

A lightweight addon for **World of Warcraft 3.3.5a** (Wrath of the Lich King) that tracks your instance lockouts and the **5-per-hour instance cap**.

![Version](https://img.shields.io/badge/version-1.7.0-blue)
![Interface](https://img.shields.io/badge/interface-3.3.5a-orange)
![License](https://img.shields.io/badge/license-MIT-green)

---

# Fugazi Instance Tracker

A clean, reliable instance and gold farming tracker for World of Warcraft 3.3.5a (Wrath of the Lich King private servers).

Whether you're pushing the 5-per-hour dungeon limit or farming gold in the open world, this addon gives you clear hourly cap tracking, saved lockouts, automatic run history, and a powerful manual Gold-Per-Hour tracker that works anywhere.




<img width="980" height="1300" alt="FUGAZI" src="https://github.com/user-attachments/assets/847af39f-0aa2-47c1-8e34-e2989af253cb" />




## What It Does

### 1. Hourly Instance Cap Tracking
- Tracks how many instances you've entered in the current rolling hour (the classic 5-per-hour soft cap).
- Shows remaining runs and a precise countdown until your next slot becomes available.
- Automatically records every dungeon or raid entry — no manual input needed.

### 2. Saved Lockouts Overview
- Lists all your saved instances with reset timers.
- Organizes them by expansion (Classic, TBC, WotLK) with color-coded labels.
- Collapsible section to keep the window compact when you only care about the hourly cap.

### 3. Automatic Instance Run Ledger (Stats Window)
- Automatically records key details for every completed dungeon/raid run (duration, gold earned, items looted).
- Keeps a permanent history of past runs for easy review.
- Toggle the dedicated Stats/Ledger window to browse your run history.

### 4. Gold-Per-Hour (GPH) Manual Tracker — Perfect for Open-World Farmers
- Start and stop your own GPH sessions anywhere — dungeons, world farming, or anything else.
- Tracks gold earned and every item picked up during the session.
- Live-updated inventory list shows exactly what you've gained, sortable by rarity or vendor price.
- Interactive loot management:
  - Double-click x on any item row to delete it from your bags.
  - Double-click rarity headers (grey, white, green, etc.) to mass-delete all items of that quality.
  - Right-click items to use or equip them when out of combat.
- Ideal for raw gold farmers who want precise hourly earnings and fast, intuitive bag cleanup.

### 5. User-Friendly Interface
- Movable main window with a draggable minimap button.
- Separate togglable Stats/Ledger and GPH windows that can dock beside the main one.
- Full slash command support:
  - `/fit` — toggle main window
  - `/fit help` — full command list
  - `/fit mute` — silence chat messages
  - `/fit reset` — clear hourly history
  - `/fit status` — quick chat summary
  - `/fit stats` — open Stats/Ledger
  - `/fit gph` — open GPH tracker
- Minimap button: left-click toggles main window, Ctrl+click resets instances, right-click shows status.


---


## How the 5/Hour Limit Works

Blizzard's soft cap allows **5 dungeon entries per rolling hour per account**. Each entry has its own 60-minute timer. When one expires, a slot opens again.

The addon records entries on zone change into instanced content. Re-entering the same instance within ~60 seconds is ignored to prevent duplicates.

**Example:** Entries at 2:00, 2:10, 2:20, 2:30, 2:40 → next slot opens at 3:00.


---


## FAQ

**Q: How do I install or update the addon?
A: Grab the latest version from Releases (right sidebar → latest release → zip file). Extract the FugaziInstanceTracker folder straight into your World of Warcraft/Interface/AddOns/ directory. Restart WoW and you're good.

**Q: It counted an entry when I just zoned out and back in — why?**  
A: Re-entering the same instance after more than ~60 seconds counts as new. Use the **[x]** button next to recent entries to remove mistakes.

**Q: Is data shared across characters?**  
A: Yes — everything (hourly history, lockouts, run ledger, GPH sessions) is account-wide via SavedVariables.

**Q: An instance appears under "Other" instead of its expansion?**  
A: Rare server name variant not in the database. Open an issue with the exact name and I'll add it.

**Q: Can I move the minimap button?**  
A: Yes — drag with left mouse button.

## Why Use It?
Lightweight and built by a farmer for farmers. Dungeon runs are tracked automatically with a full ledger, while the GPH tool gives open-world farmers the same precision and interactivity — including sortable loot and one-click cleanup that makes managing junk faster than ever.

No bloat, just the tools you actually use every session.





Happy farming!
— Fugazi

---

## License

MIT — use it, modify it, share it.
