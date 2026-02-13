# Changelog

All notable changes to Fugazi Instance Tracker are listed here.

---

## [1.7.2] — 2026-02-13

**1.7.2 turns the addon into a full loot manager.** On-the-fly blacklisting, auto-deleting, and inventory sorting from the GPH and Ledger windows — no setup in multiple menus. One flow: instance cap, run history, gold-per-hour, and full loot control.

### What’s different from 1.7.1

#### GPH is now a full loot manager
- **Sort your loot** by rarity, vendor price, or item level — one click in the GPH title bar. No addon config.
- **Protection (blacklist):** Mark items with (*) so they’re never vendored or mass-deleted. Rarity bar toggles protect *all* items of that quality (grey, green, blue, etc.) until you turn it off. Other addons (e.g. EbonholdStuff) may ignore this addon’s blacklist — not compatible for vendoring; use one or the other.
- **Auto-destroy list:** Shift+double-click the **[x]** on any GPH row to add that item to the destroy list. Those items are then auto-deleted when the list runs. One-click Disenchant/Prospect button for the next destroyable item. No menus — mark and go.
- **Delete on the fly:** Double-click **[x]** on a row to delete that item (or stack). Double-click a rarity header to delete *all* items of that quality in one go (respects blacklist).
- **Right-click** items in the GPH list to use or equip (game allows or blocks by context).
- **Bag key** can open GPH instead of default bags (optional). **/gph** on your bag key for one-key access.

#### Ledger and item detail
- **“Click to view items”** on a run opens the item detail window **docked to the right of the Ledger (or GPH)** so run list and item list sit side by side.
- **Item detail stays docked** when you expand it — no more jumping back.
- **Search** in the item detail window (instance name, item name, or rarity) to filter what you see.

#### Auto-vendor and auto-summon at Goblin Merchant
- **Auto-vendor** at the Goblin Merchant respects (*) and rarity blacklist; epics never auto-sold. **Auto-summon** Greedy Scavenger after selling (1.5s delay) when AutoSummon is on. Greedy’s chat spam is muted.
- **Autopet button** in GPH title bar: LMB = toggle AutoSummon after vendor, RMB = summon Greedy (or dismiss and resummon). Hidden if you don’t have the Greedy scavenger pet; magnify, bag, and disenchant buttons shift left.

#### Smoother and more reliable
- **Icons** in the item viewer and GPH list stay correct or use a grey fallback (no more red “?” after vendoring/deleting).
- **Tooltips** improved and wording simplified (e.g. Stats = “View Ledger”).
- **README** reordered to lead with GPH and full loot manager; terminology aligned to “blacklist” for protection; **disclaimer** added (use at your own risk; not responsible for lost items/gold/data).

### Summary vs 1.7.1

| 1.7.1 | 1.7.2 |
|-------|--------|
| Instance cap + run ledger + basic GPH session | Same, plus **full loot management**: sort, blacklist (per-item and rarity), destroy list, one-click DE/Prospect, mass-delete by rarity |
| Item detail could open but didn’t always dock | Item detail **docks to Ledger or GPH** and **stays docked** |
| No autopet layout for players without Greedy | **Autopet button hidden** when you don’t have Greedy; other title bar buttons shift left |
| No README disclaimer | **Disclaimer** (use at your own risk) |

---

## [1.7.1] — 2026-02-11

(Previous release; see [GitHub Releases](https://github.com/FUG4Z1/FugaziInstanceTracker/releases) for earlier history.)

---

[1.7.2]: https://github.com/FUG4Z1/FugaziInstanceTracker/compare/v1.7.1...v1.7.2
[1.7.1]: https://github.com/FUG4Z1/FugaziInstanceTracker/releases/tag/v1.7.1
