<p align="center">
  $$     {\color{#006D77}{\Huge \textbf{\textsf{ FugaziBAGS and FugaziInstanceTracker}}}}     $$
</p>

Two optional addons for **World of Warcraft 3.3.5a** (WotLK) that work independantly or together. They add a single inventory window, a custom bank, Dungeon and Loot Tracking and shared skins. You can use one, both, or neither; they work independently or together.

![Version](https://img.shields.io/badge/version-1.7.4-blue)
![Interface](https://img.shields.io/badge/interface-3.3.5a-orange)
![License](https://img.shields.io/badge/license-MIT-green)



## What It Does

### 1. Full Loot Manager + Gold-Per-Hour (GPH) Tracker

Replaces your bag key with a **single inventory window**. Adds a matching **custom bank window**. Includes **skins** (Original, ElvUI Ebonhold, ElvUI) for both the inventory/bank and InstanceTracker.

- Start/stop GPH sessions from anywhere
- Tracks gold earned and **every item** picked up
- Full loot manager inside the Inventory and Bank: sort, filter, protect, delete, and auto-vendor — all without leaving your frame.
---

You do **NOT** need the old `FugaziInstanceTracker` folder — it is redundant.


-----
![bagsandbank](https://github.com/user-attachments/assets/484dc9df-93ec-4e1c-a6c5-cb43a19fabf3)
![InstanceTracker](https://github.com/user-attachments/assets/35fcaa9c-52a5-4cf6-9061-90086fe282f5)


<p align="center">
  <img src="https://github.com/user-attachments/assets/7d1102cf-d851-4429-a3f0-faffd57e93cd" alt="filter">
</p>

<p align="center">
  $$    {\color{#006D77}{\Large \text{You do NOT need the old FugaziInstanceTracker folder — it is redundant.}}}    $$
</p>

---

## <h6>2. Hourly Instance Cap Tracking</h6>
- Tracks how many instances you've entered in the current **rolling hour** (the classic 5-per-hour soft cap).
- Shows remaining runs and countdown until your next slot is available.
- Automatically records every dungeon or raid entry — no manual input.
- **[x]** next to recent entries lets you remove mistakes (e.g. re-zone counted twice).
---------------------------------------------------------------------
### <h6>3. Saved Lockouts Overview</h6>
- Lists all saved instances with reset timers.
- Organized by expansion (Classic, TBC, WotLK) with color-coded labels.
- Collapsible so the window stays compact when you only care about the hourly cap.
---------------------------------------------------------------------
#### <h6>4. Automatic Instance Run Ledger (Stats Window)</h6>
- Records **duration**, **gold earned**, and **items looted** for every completed dungeon/raid run.
- Keeps a permanent history of past runs.
- **“Click to view items”** opens the item detail window with search and collapse.
- Clear button to wipe run history (with confirmation).
---------------------------------------------------------------------
###### <h6>5. Sessions and list</h6>
- Start/Stop session to track gold and loot for that period.
- Live item list shows everything in your bags from the session, sortable by **rarity**, **vendor price**, or **item level** (one click in the title bar).
- **Rarity bar** (grey, white, green, blue, etc.): **left-click** to filter the list to that quality only; **right-click** to clear filter. **Double-left-click** a rarity to delete all items of that quality in one go (respects protected items).
- **Search** in Inventory and Bank to filter the list by item or text.
---------------------------------------------------------------------
###### <h6>6. Item protection (Blacklisting)</h6>
- **Per-item:** **Ctrl+left-click** any row to mark it **(*)**. Protected items are never auto-sold and never mass-deleted (e.g. double-click rarity). You can unprotect with Ctrl+click again.
- **By rarity:** **Ctrl+left-click** a rarity in the bar to protect *all* items of that quality (e.g. all greens). Toggle off the same way. Per-item marks are separate and stay until you clear them.
- **Previously worn:** Items that leave your equipment slots are auto-marked (soul icon) so you don’t accidentally vendor or delete something you just unequipped. This set is separate from the manual (*) and rarity whitelist.
- Other addons may ignore this addons Blacklist.
---------------------------------------------------------------------
###### <h6>7. Delete and auto-destroy</h6>
- **Double-click [x]** on a row: delete that item (or stack) from your bags (with confirmation for large stacks or previously worn).
- **Double-click a rarity header:** delete *all* items of that quality (respects (*) and rarity whitelist).
- **Shift+double-click [x]:** add that item to the **auto-destroy list**. From then on, those items are automatically deleted from your bags when the destroy list runs (no need to click each time).
- **One-click Disenchant / Prospect:** the DE/Prospect button in the GPH title bar casts on the next valid item (green+ for DE, prospectable for Prospect). Choose preference in the tooltip/settings. Great for bulk cleanup.
- **Copy Profiles** Can Copy AutoDelete profiles to other Characters.
---------------------------------------------------------------------
##### <h6>8. Use and move items</h6>
- **Double Right-click** a row to **use or equip** (Previously 1 Click but Tainted Path Issues). Select a row with right-click, then second right-click on the overlay also uses/equips.
- **left-click:** pick up the item onto the cursor (bag or equipped).
- **Shift+right-click:** put the item link into chat.
---------------------------------------------------------------------
#### <h6>9. Auto-Vendor and Auto-Summon Pet at Goblin Merchant</h6>
- When you open the **Goblin Merchant** vendor window, the addon **auto-sells** all vendorable items in your bags that are **not** protected (no (*), not on the rarity Blacklist, not previously worn). **Epics (purple) are never auto-sold.** Selling respects the same protection rules as the GPH list.
- **After selling**, if **AutoSummon** is on, the addon automatically **summons the Greedy Scavenger** pet after a short delay (1.5s) so you can keep farming without opening the pet panel.
- **Greedy’s SPAM MESSAGES** are muted so they don’t annoy the living Hell out of you!
- **Autopet button** (pet icon in the GPH title bar): **LMB** = toggle AutoSummon after vendor on/off. **RMB** = summon Greedy now (or dismiss and resummon if already out — useful when the pet lags behind). **/fit vp** shows the current AutoSummon state.
---------------------------------------------------------------------
### <h6>10. Bank</h6>
- Open the bank at a banker as usual (right-click, etc.). The addon shows a **custom bank window** that matches the inventory (same layout and skin).
- **Sort**, **rarity bar**, **purchase bag slot**, **toggle bag bar** — same style as the inventory.
- **Ctrl+RMB** on a rarity bar: move all items of that rarity from bags to bank (or bank to bags when in bank). Only runs when the bank window is open.
- **Consolidation Button** Shuffles items through the Bags.
---------------------------------------------------------------------- 
## <h6>11. Installation</h6>
- **__FugaziBAGS only:** Copy the `__FugaziBAGS` folder into `World of Warcraft/Interface/AddOns/`. You get the inventory window (B key), bank, and skins.
- **__FugaziInstanceTracker only:** Copy the `__FugaziInstanceTracker` folder into AddOns. You get the full instance tracker. No other addon required.
- **Both:** Copy both folders for inventory + bank + tracker with shared skin.

## <h6>12. Compatibility</h6>
FugaziBAGS loads after ElvUI by default (folder name `__`). If you need a strict order, you can add `## Dependencies: ElvUI` in the TOC.
Other bag addons: If __FugaziBAGS is enabled, the bag key opens the Fugazi inventory. Disable __FugaziBAGS if you want another bag addon to control the bag key.
Auto-vendor: Fugazi’s auto-vendor at the **Goblin Merchant** respects Fugazi’s protection list. Other vendor addons (e.g. EbonholdStuff) do not use that list; use one or the other when vendoring if you care about protected items.

---------------------------------------------------------------------
<h6>13. Summary</h6>
- **__FugaziBAGS:** Standalone. One inventory window (B key) + one bank window + four skins.
- **__FugaziInstanceTracker:** Standalone. Full instance tracker (cap, ledger, GPH, items). Shares skin with __FugaziBAGS when both are installed.
- No “core” addon. The old FugaziInstanceTracker folder is redundant — use these two addons instead.
---------------------------------------------------------------------

**Folder layout:**
```
Interface/AddOns/
  __FugaziBAGS/             ← bags + bank + skins (optional)
  __FugaziInstanceTracker/  ← instance tracker (optional)
```

---
<h6>How the 5 Hour Limit Works</h6>

WOW’s soft cap allows **5 dungeon entries per rolling hour per account**. Each entry has its own 60-minute timer; when one expires, a slot opens again. The addon records entries on zone change into instanced content. Re-entering the same instance within ~60 seconds is ignored to avoid double-counting.

**Example:** Entries at 2:00, 2:10, 2:20, 2:30, 2:40 → next slot opens at 3:00.

---

## FAQ

**Q: How do I install or update?**    
A: Get the latest from Releases (zip). Extract **__FugaziBAGS** and/or **__FugaziInstanceTracker** into **World of Warcraft/Interface/AddOns/** (one or both folders). Restart WoW.

**Q: Do I need the old FugaziInstanceTracker addon?**  
A: No. __FugaziBAGS and __FugaziInstanceTracker are standalone. The old FugaziInstanceTracker folder is redundant — you can remove it.

**Q: It counted an entry when I zoned out and back in — why?**  
A: Re-entering the same instance after more than ~60 seconds counts as a new entry. Use the **[x]** next to that entry to remove it.

**Q: Is data shared across characters?**  
A: Yes for tracker data: hourly history, lockouts, run ledger, and GPH sessions are account-wide. Protection (*) and rarity whitelist are per character. __FugaziBAGS destroy list and protection are per character; skin/positions are account-wide.

**Q: An instance appears under “Other” instead of its expansion?**  
A: Server name variant isn’t in the database. You can open an issue with the exact name to have it added.

**Q: Can I move the minimap button?**  
A: Yes — drag it with the left mouse button.

**Q: Can I use Fugazi with EbonholdStuff or another auto-vendor addon?**  
A: Fugazi’s auto-vendor (at the **Goblin Merchant** only) respects its own (*) protected items. Other addons (e.g. EbonholdStuff) don’t use Fugazi’s protection list, so they **will** sell protected items. Use other vendoring AddOns at your own Risk, or use only Fugazi at the Goblin Merchant if you want (*) and rarity-protected items to stay unsold.

---------------------------------------------------------------------
## Technical disclaimer (inventory / bags)

**This addon doesn’t replace your inventory — it’s a different “remote” for the same TV.** The game’s real bags and bank slots stay where they are; we can’t rip them out. __FugaziBAGS is a layer on top: when you press B, we show *our* window and talk to the game’s inventory through the only doors Blizzard gives addons (their APIs). So you get a new interface and workflow, but the actual items and slots are still the ones the game manages. Think of it like a fancy universal remote: it controls the same device, it doesn’t become the device.

**Why it’s built this way:** Addons can’t replace core UI from the inside. We can only draw our own windows and send “move this,” “open that” requests. So what looks like “replacing” the bags is really “sitting on top and remote-controlling them.”

**Consolidate bank button:** The addon can’t literally “see” your real bank slot layout the way the default UI does — we work with the same data, but we don’t get a live picture of how items are arranged in the real bank frames. So the **Consolidate** button exists to clean up the actual bank slots in the background (stack, compact). That way the real bank and what you see in our window stay in sync and tidy. Use it when things look scattered or after dumping a lot of stuff into the bank.

**Bugs that can happen (Blizzard’s rules, not design choices):**



---------------------------------------------------------------------



**What you might see / Why it happens (in plain terms)**

**“Action blocked” or bags/sort failing only in combat:** 
The game turns off or restricts many inventory actions in combat. We can only do what BlizzardAPI allows at that moment — like the remote only working when the TV is on.

**Bag key (B) does nothing in combat, or “Interface action failed:”** 
The game marks certain buttons and keybinds as “secure”: they must not run addon code in the same step, or the whole action is cancelled (tainted path). We avoid stepping into that path, but any addon that takes over and does bag things, the bag key can still run into this.

**One-off glitches; need to reopen or reload:** 
Sometimes the game’s inventory APIs aren’t ready yet or behave differently around login/load. Our window might be out of step for a moment.

If you hit combat-only failures or “Interface action failed,” that’s the kind of thing to expect from this setup; reporting with exact steps (when, what you clicked, in/out of combat) helps}



## Disclaimer

This addon is provided **as-is**. Use it at your own risk. I am not responsible for any lost items, gold, or data resulting from its use (including but not limited to auto-vendor, auto-delete, mass delete, or protection behaviour). Always double-check your settings, AddOns and protected lists; when in doubt, vendor or destroy manually.

---

## Why Use It?


Lightweight and built by a farmer, for farmers. Instance cap and run ledger are automatic; the Inventory window gives you a single place for gold tracking, item filtering, whitelisting, mass delete, auto-destroy, one-click DE/Prospect, and auto-vendor + auto-summon pet at the Goblin Merchant. No bloat.


Happy farming!  
— **Fugazi**

---

---

## License

MIT — use it, modify it, share it.
