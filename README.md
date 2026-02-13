# Fugazi Instance Tracker

A clean, reliable instance and gold farming tracker for **World of Warcraft 3.3.5a** (Wrath of the Lich King). Tracks the 5-per-hour instance cap, saved lockouts, automatic run history, and a full **Gold-Per-Hour (GPH)** loot manager with item filtering, whitelisting, auto-vendor, auto-delete, and auto-summon pet after vendor.

![Version](https://img.shields.io/badge/version-1.7.2-blue)
![Interface](https://img.shields.io/badge/interface-3.3.5a-orange)
![License](https://img.shields.io/badge/license-MIT-green)

<a href="https://www.buymeacoffee.com/FUG4Z1" target="_blank">
  <img align="right" src="https://cdn.buymeacoffee.com/buttons/default-orange.png" alt="Buy Me A Coffee" height="41" width="174">
</a>

---

## What It Does

# 1. FULL LOOT MANAGER!!! - Gold-Per-Hour (GPH) Manual Tracker
Start and stop GPH sessions anywhere. Tracks gold and every item picked up. The GPH window is also a **full loot manager**: sort, filter, protect, delete, and auto-vendor without leaving the flow.

![filter](https://github.com/user-attachments/assets/7d1102cf-d851-4429-a3f0-faffd57e93cd)


## 2. Hourly Instance Cap Tracking
- Tracks how many instances you've entered in the current **rolling hour** (the classic 5-per-hour soft cap).
- Shows remaining runs and countdown until your next slot is available.
- Automatically records every dungeon or raid entry — no manual input.
- **[x]** next to recent entries lets you remove mistakes (e.g. re-zone counted twice).

### 3. Saved Lockouts Overview
- Lists all saved instances with reset timers.
- Organized by expansion (Classic, TBC, WotLK) with color-coded labels.
- Collapsible so the window stays compact when you only care about the hourly cap.

#### 4. Automatic Instance Run Ledger (Stats Window)
- Records **duration**, **gold earned**, and **items looted** for every completed dungeon/raid run.
- Keeps a permanent history of past runs.
- **“Click to view items”** opens the item detail window with search and collapse.
- Clear button to wipe run history (with confirmation).

##### 5. Sessions and list
- Start/Stop session to track gold and loot for that period.
- Live item list shows everything in your bags from the session, sortable by **rarity**, **vendor price**, or **item level** (one click in the title bar).
- **Rarity bar** (grey, white, green, blue, etc.): **left-click** to filter the list to that quality only; **right-click** to clear filter. **Double-left-click** a rarity to delete all items of that quality in one go (respects protected items).
- **Search** in GPH to filter the list by item or text.

###### 6. Item protection (Blacklisting)
- **Per-item:** **Ctrl+left-click** any row to mark it **(*)**. Protected items are never auto-sold and never mass-deleted (e.g. double-click rarity). You can unprotect with Ctrl+click again.
- **By rarity:** **Ctrl+left-click** a rarity in the bar to protect *all* items of that quality (e.g. all greens). Toggle off the same way. Per-item marks are separate and stay until you clear them.
- **Previously worn:** Items that leave your equipment slots are auto-marked (soul icon) so you don’t accidentally vendor or delete something you just unequipped. This set is separate from the manual (*) and rarity whitelist.
- Other addons may ignore this addons Blacklist.

####### 7. Delete and auto-destroy
- **Double-click [x]** on a row: delete that item (or stack) from your bags (with confirmation for large stacks or previously worn).
- **Double-click a rarity header:** delete *all* items of that quality (respects (*) and rarity whitelist).
- **Shift+double-click [x]:** add that item to the **auto-destroy list**. From then on, those items are automatically deleted from your bags when the destroy list runs (no need to click each time).
- **One-click Disenchant / Prospect:** the DE/Prospect button in the GPH title bar casts on the next valid item (green+ for DE, prospectable for Prospect). Choose preference in the tooltip/settings. Great for bulk cleanup.

######## 8. Use and move items
- **Right-click** a row to **use or equip** (game allows or blocks by context). Select a row with left-click, then second right-click on the overlay also uses/equips.
- **Shift+left-click:** pick up the item onto the cursor (bag or equipped).
- **Shift+right-click:** put the item link into chat.

######### 9. Auto-Vendor and Auto-Summon Pet at Goblin Merchant
- When you open the **Goblin Merchant** vendor window, the addon **auto-sells** all vendorable items in your bags that are **not** protected (no (*), not on the rarity Blacklist, not previously worn). **Epics (purple) are never auto-sold.** Selling respects the same protection rules as the GPH list.
- **After selling**, if **AutoSummon** is on, the addon automatically **summons the Greedy Scavenger** pet after a short delay (1.5s) so you can keep farming without opening the pet panel.
- **Greedy’s SPAM MESSAGES** are muted so they don’t annoy the living Hell out of you!
- **Autopet button** (pet icon in the GPH title bar): **LMB** = toggle AutoSummon after vendor on/off. **RMB** = summon Greedy now (or dismiss and resummon if already out — useful when the pet lags behind). **/fit vp** shows the current AutoSummon state.

########## 10. Optional: Bag Key Opens GPH
- With **“Inv”** on (toggle in GPH title bar or via the bag icon tooltip), your **bag key** opens the GPH window instead of the default bags (like Bagnon/OneBag). At a vendor or NPC dialog, the bag key won’t close GPH or open bags — so you don’t lose the vendor window. **/gph** to your bag key for one-key access.

########### 11. Interface and Commands
- Movable main window; **minimap button** (drag to move): left-click = toggle main window, Ctrl+click = reset instances, right-click = status in chat.
- **Slash commands:**  
  **/fit** or **/fugazi** — toggle main window  
  **/gph** — toggle GPH window (same as /fit gph)  
  **/fit help** — full command list  
  **/fit mute** — silence addon chat messages  
  **/fit reset** — clear hourly instance history  
  **/fit status** — instances used this hour in chat  
  **/fit stats** — toggle Stats/Ledger window  
  **/fit gph** or **/fit inv** — toggle GPH window  
  **/fit vp** — show AutoSummon (Summon Greedy after vendor) state  
- Item detail window (from Ledger “Click to view items”) docks to Ledger or GPH and supports search and collapse.

---

## How the 5/Hour Limit Works

Blizzard’s soft cap allows **5 dungeon entries per rolling hour per account**. Each entry has its own 60-minute timer; when one expires, a slot opens again. The addon records entries on zone change into instanced content. Re-entering the same instance within ~60 seconds is ignored to avoid double-counting.

**Example:** Entries at 2:00, 2:10, 2:20, 2:30, 2:40 → next slot opens at 3:00.

---

## FAQ

**Q: How do I install or update?**  
A: Get the latest from Releases (zip). Extract the **FugaziInstanceTracker** folder into **World of Warcraft/Interface/AddOns/**. Restart WoW.

**Q: It counted an entry when I zoned out and back in — why?**  
A: Re-entering the same instance after more than ~60 seconds counts as a new entry. Use the **[x]** next to that entry to remove it.

**Q: Is data shared across characters?**  
A: Yes. Hourly history, lockouts, run ledger, and GPH sessions are account-wide (SavedVariables). Protection (*) and rarity whitelist are per character.

**Q: An instance appears under “Other” instead of its expansion?**  
A: Server name variant isn’t in the database. You can open an issue with the exact name to have it added.

**Q: Can I move the minimap button?**  
A: Yes — drag it with the left mouse button.

**Q: Can I use Fugazi with EbonholdStuff or another auto-vendor addon?**  
A: Fugazi’s own auto-vendor (at the **Goblin Merchant** only) respects (*) protected items. Other addons (e.g. EbonholdStuff) don’t use Fugazi’s protection list, so they **will** sell your protected items. For that reason they’re not compatible for vendoring — use one or the other when selling, or use only Fugazi at the Goblin Merchant if you want your (*) and rarity-protected items to stay unsold.

---

## Disclaimer

This addon is provided **as-is**. Use it at your own risk. I am not responsible for any lost items, gold, or data resulting from its use (including but not limited to auto-vendor, auto-delete, mass delete, or protection behaviour). Always double-check your settings, AddOns and protected lists; when in doubt, vendor or destroy manually.

---

## Why Use It?

Lightweight and built by a farmer, for farmers. Instance cap and run ledger are automatic; the GPH window gives you a single place for gold tracking, item filtering, whitelisting, mass delete, auto-destroy, one-click DE/Prospect, and auto-vendor + auto-summon pet at the Goblin Merchant. No bloat.


Happy farming!  
— **Fugazi**

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history. **v1.7.2**: Full loot manager in GPH (sort, protect, destroy list, mass delete, DE/Prospect), docking and UI polish, auto-summon and vendor behavior.

---

## License

MIT — use it, modify it, share it.
