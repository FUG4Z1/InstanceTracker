--[[
  Fugazi Vendor Protect — we do NOT hook UseContainerItem.

  Hooking UseContainerItem taints the secure path and causes "forbidden function"
  errors (hearthstone, macros, etc.) until /reload. So we never hook.

  Without hooking, we cannot block another addon's auto-sell from this addon.
  Protection would require the auto-sell addon to call FugaziInstanceTracker_IsItemProtected(itemId)
  and skip those items when building its queue (we do not modify other addons).

  This file only exposes the API; the shield indicator in GPH stays grey.
]]

if not _G.FugaziInstanceTracker_IsItemProtected then return end

-- Never hook; no taint. Indicator stays inactive.
_G.FugaziVendorProtectHookActive = false

-- No-op for compatibility (main addon may call these).
function _G.FugaziVendorProtectUnhookNow() end
function _G.FugaziVendorProtectSetEnabled(_) end
