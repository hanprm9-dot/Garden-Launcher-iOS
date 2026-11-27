using System;
using System.Collections.Generic;
using System.Reflection;
using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using Microsoft.Xna.Framework.Input.Touch;
using StardewValley;
using StardewValley.Inventories;
using StardewValley.ItemTypeDefinitions;
using StardewValley.Menus;

namespace SDVMobileControls
{
    /// <summary>
    /// Authentic Stardew Mobile Texture UI for Shopping, Crafting (Cooking & Workbench),
    /// Dresser 1-Tap, Chest 1-Tap Transfer, Long-Press Split Stack, and 1-Finger Drag-and-Drop
    /// with ZERO stuck mouse cursor. Zero hardcoded resolutions.
    /// </summary>
    internal sealed class MobileInventoryShopHelper
    {
        private static readonly Rectangle MobileBoxSrc = new Rectangle(0, 256, 60, 60);
        private static readonly MethodInfo ShopTryPurchaseMethod =
            typeof(ShopMenu).GetMethod("tryToPurchaseItem", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        private static readonly FieldInfo ShopIsStorageField =
            typeof(ShopMenu).GetField("_isStorageShop", BindingFlags.Instance | BindingFlags.NonPublic);
        private static readonly FieldInfo ShopSellPctField =
            typeof(ShopMenu).GetField("sellPercentage", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        private static readonly FieldInfo ShopScrollRunnerField =
            typeof(ShopMenu).GetField("scrollBarRunner", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        private static readonly MethodInfo ShopSetScrollBarMethod =
            typeof(ShopMenu).GetMethod("setScrollBarToCurrentIndex", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        private static readonly MethodInfo CraftClickRecipeMethod =
            typeof(CraftingPage).GetMethod("clickCraftingRecipe", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);

        internal enum ChestTapMode { FullStack = 0, SingleOne = 1, HalfStack = 2 }

        private enum PopupKind { None = 0, ShopBuy = 1, ShopSell = 2, ChestSplit = 3, BagSplit = 4, Craft = 5 }

        public ChestTapMode TapMode { get; set; } = ChestTapMode.FullStack;

        public void ToggleTapMode(ChestTapMode mode)
        {
            TapMode = (TapMode == mode) ? ChestTapMode.FullStack : mode;
        }

        // Active Popup state
        private PopupKind _popupKind = PopupKind.None;
        private IClickableMenu _popupOwnerMenu;
        private ISalable _popupSaleItem;
        private Item _popupItem;
        private CraftingPage _popupCraftPage;
        private ClickableTextureComponent _popupCraftBtn;
        private CraftingRecipe _popupCraftRecipe;
        private InventoryMenu _popupSrcInv;
        private InventoryMenu _popupDstInv;
        private int _popupSrcSlot = -1;
        private Point _popupUiClickPt;
        private int _popupQty = 1;
        private int _popupMinQty = 1;
        private int _popupMaxQty = 1;
        private int _popupUnitPrice;
        private int _popupCurrency;
        private int _popupStock = ShopMenu.infiniteStock;
        private string _popupTradeItemId;
        private int _popupTradeCount;
        private int _popupBundlePerPurchase = 1;
        private bool _popupCanAfford = true;
        private IList<Item> _cachedCraftExtraItems;
        private string _wrapCacheText;
        private int _wrapCacheMaxW;
        private float _wrapCacheScale;
        private readonly List<string> _wrapCacheLines = new List<string>(8);

        // Popup interactive rects (viewport pixel space)
        private Rectangle _popPanel;
        private Rectangle _popCloseX;
        private Rectangle _popSliderTrack;
        private int _popKnobW = 44;
        private Rectangle _popBtnM10;
        private Rectangle _popBtnM1;
        private Rectangle _popBtnP1;
        private Rectangle _popBtnP10;
        private Rectangle _popBtnMax;
        private Rectangle _popBtnConfirm;
        private Rectangle _popBtnCancel;
        private int _popSliderTouchId = -1;
        private int _popConsumeTouchId = -1;
        private int _popHoldTouchId = -1;
        private int _popHoldDelta;
        private double _popHoldStartSec;
        private double _popHoldLastStepSec;
        private double _popSliderLastTickSec;

        // Touch Drag-and-Drop & Short-Tap / Long-Press / Smooth Shop Scroll state
        private int _touchId = -1;
        private Vector2 _touchStartVp;
        private Vector2 _touchCurVp;
        private double _touchStartSec;
        private bool _isDragging;
        private bool _isShopScrolling;
        private bool _isShopThumbDragging;
        private bool _shopSwipeInCatalog;
        private float _shopScrollLastY;
        private float _shopScrollAccum;
        private float _shopScrollVel;
        private float _shopCachedRowPitch = 96f;
        private double _shopScrollLastSfxSec;
        private IClickableMenu _trackedMenu;

        // Dragged & Tap-Selected slot info (NEVER uses Game1.player.CursorSlotItem!)
        private InventoryMenu _dragSrcInv;
        private int _dragSrcSlot = -1;
        private Item _dragItem;
        private int _tappedShopBtnIdx = -1;
        private int _selectedBagSlot = -1;
        private InventoryMenu _selectedBagInv;

        // Cached drag hover target (recomputed only when finger moves >= 2px, avoiding 60Hz full-slot scans!)
        private Vector2 _dragHoverCachedVp;
        private bool _dragHoverCacheValid;
        private bool _dragHoverIsTrash;
        private Rectangle _dragHoverTrashUi;
        private Rectangle _dragHoverSlotUi;
        private Rectangle _dragHoverAreaUi;

        // Cached fixed item tooltip banner text (eliminates 60Hz getDescription/Replace/interpolation GC churn!)
        private Item _tipCachedItem;
        private int _tipCachedStack = -1;
        private string _tipCachedTitle;
        private string _tipCachedStats;
        private string _tipCachedDesc;

        public bool IsPopupOpen => _popupKind != PopupKind.None;
        public bool IsDraggingItem => _isDragging && _dragItem != null;
        public bool HasSelectedSlot => _selectedBagSlot >= 0;

        public void Reset()
        {
            ClosePopup();
            ResetTouch();
            ClearSelection();
            _dragHoverCacheValid = false;
            _shopScrollVel = 0f;
            TapMode = ChestTapMode.FullStack;
        }

        private void ClearSelection()
        {
            _selectedBagSlot = -1;
            _selectedBagInv = null;
            _tipCachedItem = null;
            _tipCachedStack = -1;
        }

        private void ClosePopup()
        {
            _popupKind = PopupKind.None;
            _popupOwnerMenu = null;
            _popupSaleItem = null;
            _popupItem = null;
            _popupCraftPage = null;
            _popupCraftBtn = null;
            _popupCraftRecipe = null;
            _popupSrcInv = null;
            _popupDstInv = null;
            _popupSrcSlot = -1;
            _popupStock = ShopMenu.infiniteStock;
            _popupBundlePerPurchase = 1;
            _cachedCraftExtraItems = null;
            _popSliderTouchId = -1;
            _popHoldTouchId = -1;
            _popHoldDelta = 0;
        }

        private static bool IsSpecialWalletTradeCurrency(string tradeId)
        {
            if (string.IsNullOrEmpty(tradeId)) return false;
            return string.Equals(tradeId, "(O)858", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(tradeId, "858", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(tradeId, "(O)73", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(tradeId, "73", StringComparison.OrdinalIgnoreCase);
        }

        private static int GetPlayerTradeItemCount(Farmer who, string tradeId)
        {
            if (who == null || string.IsNullOrEmpty(tradeId))
                return 0;
            if (string.Equals(tradeId, "(O)858", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(tradeId, "858", StringComparison.OrdinalIgnoreCase))
            {
                return Math.Max(0, who.QiGems);
            }
            if (string.Equals(tradeId, "(O)73", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(tradeId, "73", StringComparison.OrdinalIgnoreCase))
            {
                return Math.Max(0, Game1.netWorldState?.Value?.GoldenWalnuts ?? 0);
            }
            return who.Items?.CountId(tradeId) ?? 0;
        }

        private static bool IsStorageShop(ShopMenu shop)
        {
            if (shop == null) return false;
            try
            {
                if (ShopIsStorageField != null && ShopIsStorageField.GetValue(shop) is bool b && b)
                    return true;
            }
            catch { }
            return false;
        }

        public bool OpenCraftingPopup(IClickableMenu ownerMenu, CraftingPage cp, ClickableTextureComponent recipeBtn, CraftingRecipe recipe, int consumeTouchId)
        {
            if (ownerMenu == null || cp == null || recipeBtn == null || recipe == null)
                return false;

            Item preview = null;
            try { preview = recipe.createItem(); } catch { }

            int craftable = 0;
            IList<Item> matItems = GetContainerItemsList(cp._materialContainers);
            _cachedCraftExtraItems = matItems;
            try { craftable = recipe.getCraftableCount(matItems); } catch { craftable = 0; }
            if (craftable <= 0)
            {
                try
                {
                    if (recipe.doesFarmerHaveIngredientsInInventory(matItems))
                        craftable = 1;
                }
                catch { }
            }

            _popupKind = PopupKind.Craft;
            _popupOwnerMenu = ownerMenu;
            _popupCraftPage = cp;
            _popupCraftBtn = recipeBtn;
            _popupCraftRecipe = recipe;
            _popupItem = preview;
            _popupSaleItem = preview;
            _popupMinQty = 1;
            _popupMaxQty = Math.Clamp(Math.Max(1, craftable), 1, 999);
            _popupQty = 1;
            _popupUnitPrice = 0;
            _popupTradeItemId = null;
            _popupTradeCount = 0;
            _popupCanAfford = craftable >= 1;
            _popConsumeTouchId = consumeTouchId;
            try { Game1.playSound("smallSelect"); } catch { }
            return true;
        }

        private static int CountMatchingCraftIngredients(string rawId, IList<Item> extraItems)
        {
            if (string.IsNullOrEmpty(rawId)) return 0;
            int total = 0;
            try
            {
                var pItems = Game1.player?.Items;
                if (pItems != null)
                {
                    for (int i = 0; i < pItems.Count; i++)
                    {
                        Item it = pItems[i];
                        if (it != null && CraftingRecipe.ItemMatchesForCrafting(it, rawId))
                            total += it.Stack;
                    }
                }
                if (extraItems != null)
                {
                    for (int i = 0; i < extraItems.Count; i++)
                    {
                        Item it = extraItems[i];
                        if (it != null && CraftingRecipe.ItemMatchesForCrafting(it, rawId))
                            total += it.Stack;
                    }
                }
            }
            catch { }
            return total;
        }

        private static IList<Item> GetContainerItemsList(List<IInventory> containers)
        {
            if (containers == null || containers.Count == 0)
                return null;
            var all = new List<Item>();
            for (int i = 0; i < containers.Count; i++)
            {
                var inv = containers[i];
                if (inv == null) continue;
                for (int j = 0; j < inv.Count; j++)
                {
                    if (inv[j] != null) all.Add(inv[j]);
                }
            }
            return all;
        }

        private void ResetTouch()
        {
            _touchId = -1;
            _isDragging = false;
            _isShopScrolling = false;
            _isShopThumbDragging = false;
            _shopSwipeInCatalog = false;
            _dragSrcInv = null;
            _dragSrcSlot = -1;
            _dragItem = null;
            _tappedShopBtnIdx = -1;
        }

        private static bool TryFindTouchById(TouchCollection touches, int id, out TouchLocation found)
        {
            for (int i = 0; i < touches.Count; i++)
            {
                if (touches[i].Id == id)
                {
                    found = touches[i];
                    return true;
                }
            }
            found = default;
            return false;
        }

        private static bool TryPickPrimaryTouch(TouchCollection touches, int trackedId, out TouchLocation chosen)
        {
            if (trackedId >= 0)
                return TryFindTouchById(touches, trackedId, out chosen);

            for (int i = 0; i < touches.Count; i++)
            {
                if (touches[i].State == TouchLocationState.Pressed)
                {
                    chosen = touches[i];
                    return true;
                }
            }
            chosen = default;
            return false;
        }

        public bool Update(
            IClickableMenu activeMenu,
            TouchCollection touches,
            Func<Vector2, Vector2> rawToVp,
            Func<Vector2, Point> vpToUi,
            Func<Point, Vector2> uiToVp,
            int vpW, int vpH,
            double nowSec)
        {
            if (activeMenu == null || (IsPopupOpen && activeMenu != _popupOwnerMenu) ||
                (_popupKind == PopupKind.Craft && activeMenu is GameMenu gmCraft && !ReferenceEquals(gmCraft.GetCurrentPage(), _popupCraftPage)))
            {
                Reset();
                return false;
            }

            if (activeMenu != _trackedMenu)
            {
                _trackedMenu = activeMenu;
                ResetTouch();
                ClearSelection();
                _shopScrollVel = 0f;
                TapMode = ChestTapMode.FullStack;
            }

            // Consume lingering touch release after popup dismiss/confirm
            if (_popConsumeTouchId >= 0)
            {
                bool stillDown = false;
                for (int i = 0; i < touches.Count; i++)
                {
                    if (touches[i].Id == _popConsumeTouchId &&
                        (touches[i].State == TouchLocationState.Pressed || touches[i].State == TouchLocationState.Moved))
                    {
                        stillDown = true;
                        break;
                    }
                }
                if (stillDown) return true;
                _popConsumeTouchId = -1;
            }

            // 1. Active Mobile Pixel Popup owns all touches cleanly
            if (IsPopupOpen)
            {
                ComputePopupLayout(vpW, vpH);
                UpdatePopupTouches(touches, rawToVp, nowSec);
                return true;
            }

            ShopMenu shop = activeMenu as ShopMenu;
            ItemGrabMenu grab = activeMenu as ItemGrabMenu;
            InventoryPage invPage = (activeMenu as GameMenu)?.GetCurrentPage() as InventoryPage;
            CraftingPage craftPage = (activeMenu as CraftingPage) ?? ((activeMenu as GameMenu)?.GetCurrentPage() as CraftingPage);

            // Prevent stuck invisible heldItem on CraftingPage cursor in Mobile touch mode
            if (craftPage != null && craftPage.heldItem != null && Game1.player != null)
            {
                RescueHeldItemToPlayer(craftPage.heldItem);
                craftPage.heldItem = null;
            }

            if (shop == null && grab == null && invPage == null)
            {
                ResetTouch();
                ClearSelection();
                _shopScrollVel = 0f;
                return false;
            }

            // Smooth iOS-style momentum scrolling for Shop catalog when no finger is dragging
            if (shop != null && _touchId < 0 && Math.Abs(_shopScrollVel) > 0.5f)
            {
                UpdateShopMomentum(shop, uiToVp, vpH);
            }

            if (touches.Count == 0)
            {
                ResetTouch();
                return false;
            }

            // Track active touch ID cleanly across multi-touch so stray palm brushes NEVER drop drags or scrolls!
            if (!TryPickPrimaryTouch(touches, _touchId, out TouchLocation tl))
            {
                if (_touchId >= 0)
                    ResetTouch();
                return false;
            }

            Vector2 vp = rawToVp(tl.Position);
            Point uiPt = vpToUi(vp);

            if (shop != null)
                return UpdateShopTouch(shop, tl, vp, uiPt, uiToVp, vpH, nowSec);

            if (grab != null)
                return UpdateInventoryTouch(grab, grab.inventory, grab.ItemsToGrabMenu, grab.trashCan, null, isChestMenu: true, tl, vp, uiPt, vpH, nowSec);

            if (invPage != null)
                return UpdateInventoryTouch(invPage, invPage.inventory, null, invPage.trashCan, invPage.equipmentIcons, isChestMenu: false, tl, vp, uiPt, vpH, nowSec);

            return false;
        }

        // =========================================================================
        // A. MOBILE SHOPPING (Silky Scrollbar + Momentum Swipe + Precision Slider!)
        // =========================================================================
        private static bool TryGetShopScrollTrackUi(ShopMenu shop, out Rectangle trackUi, out int maxIdx)
        {
            trackUi = Rectangle.Empty;
            maxIdx = 0;
            if (shop == null || shop.forSale == null || shop.forSaleButtons == null)
                return false;

            int visible = Math.Max(1, shop.forSaleButtons.Count);
            maxIdx = Math.Max(0, shop.forSale.Count - visible);
            if (maxIdx <= 0)
                return false;

            try
            {
                if (ShopScrollRunnerField != null && ShopScrollRunnerField.GetValue(shop) is Rectangle runner && runner.Height > 8)
                {
                    trackUi = runner;
                }
            }
            catch { }

            if (trackUi.IsEmpty && shop.upArrow != null && shop.downArrow != null)
            {
                int top = shop.upArrow.bounds.Bottom + 4;
                int bot = shop.downArrow.bounds.Top - 4;
                if (bot > top + 8)
                    trackUi = new Rectangle(shop.upArrow.bounds.X, top, Math.Max(24, shop.upArrow.bounds.Width), bot - top);
            }

            if (shop.scrollBar != null && shop.scrollBar.bounds.Width > 0 && shop.scrollBar.bounds.Height > 0)
            {
                trackUi = trackUi.IsEmpty ? shop.scrollBar.bounds : Rectangle.Union(trackUi, shop.scrollBar.bounds);
            }

            return !trackUi.IsEmpty && trackUi.Height > 8;
        }

        private static bool IsOnShopChromeButton(ShopMenu shop, Point uiPt)
        {
            if (shop == null) return false;
            if (shop.upArrow != null && shop.upArrow.containsPoint(uiPt.X, uiPt.Y)) return true;
            if (shop.downArrow != null && shop.downArrow.containsPoint(uiPt.X, uiPt.Y)) return true;
            if (shop.upperRightCloseButton != null && shop.upperRightCloseButton.containsPoint(uiPt.X, uiPt.Y)) return true;
            if (shop.tabButtons != null)
            {
                for (int i = 0; i < shop.tabButtons.Count; i++)
                {
                    if (shop.tabButtons[i] != null && shop.tabButtons[i].containsPoint(uiPt.X, uiPt.Y))
                        return true;
                }
            }
            return false;
        }

        private static float ComputeShopRowPitchVp(ShopMenu shop, Func<Point, Vector2> uiToVp, int vpH)
        {
            if (shop?.forSaleButtons != null && shop.forSaleButtons.Count > 0 && uiToVp != null)
            {
                Rectangle b0 = shop.forSaleButtons[0].bounds;
                if (shop.forSaleButtons.Count >= 2)
                {
                    int dyUi = shop.forSaleButtons[1].bounds.Y - b0.Y;
                    if (dyUi > 16)
                    {
                        Vector2 p0 = uiToVp(new Point(b0.X, b0.Y));
                        Vector2 p1 = uiToVp(new Point(b0.X, b0.Y + dyUi));
                        float pitch = Math.Abs(p1.Y - p0.Y);
                        if (pitch >= 24f)
                            return Math.Clamp(pitch, 38f, vpH * 0.28f);
                    }
                }
                if (b0.Height > 16)
                {
                    Vector2 p0 = uiToVp(new Point(b0.X, b0.Y));
                    Vector2 p1 = uiToVp(new Point(b0.X, b0.Bottom));
                    float pitch = Math.Abs(p1.Y - p0.Y);
                    if (pitch >= 24f)
                        return Math.Clamp(pitch, 38f, vpH * 0.28f);
                }
            }
            return Math.Max(48f, vpH * 0.115f);
        }

        private void ApplyShopScrollFromThumbY(ShopMenu shop, int uiY, Rectangle trackUi, int maxIdx, double nowSec)
        {
            if (shop == null || maxIdx <= 0 || trackUi.Height <= 4) return;
            int thumbH = (shop.scrollBar != null && shop.scrollBar.bounds.Height > 0) ? shop.scrollBar.bounds.Height : 40;
            float minY = trackUi.Top + thumbH * 0.5f;
            float maxY = trackUi.Bottom - thumbH * 0.5f;
            float frac = Math.Clamp((uiY - minY) / Math.Max(1f, maxY - minY), 0f, 1f);
            int targetIdx = Math.Clamp((int)Math.Round(frac * maxIdx), 0, maxIdx);

            if (targetIdx != shop.currentItemIndex)
            {
                shop.currentItemIndex = targetIdx;
                try { ShopSetScrollBarMethod?.Invoke(shop, null); } catch { }
                if ((nowSec - _shopScrollLastSfxSec) >= 0.055)
                {
                    _shopScrollLastSfxSec = nowSec;
                    try { Game1.playSound("shiny4"); } catch { }
                }
            }
        }

        private void ConsumeShopScrollAccum(ShopMenu shop, float rowPitch)
        {
            if (shop == null || shop.forSale == null || shop.forSaleButtons == null)
                return;
            int maxIdx = Math.Max(0, shop.forSale.Count - Math.Max(1, shop.forSaleButtons.Count));
            if (maxIdx <= 0)
            {
                _shopScrollAccum = 0f;
                _shopScrollVel = 0f;
                return;
            }

            float step = Math.Max(34f, rowPitch * 0.88f);
            int safety = 0;
            while (Math.Abs(_shopScrollAccum) >= step && safety++ < 12)
            {
                int wheel = _shopScrollAccum > 0 ? 120 : -120;
                int before = shop.currentItemIndex;
                _shopScrollAccum -= Math.Sign(_shopScrollAccum) * step;
                try { shop.receiveScrollWheelAction(wheel); } catch { }
                if (shop.currentItemIndex == before)
                {
                    _shopScrollAccum = 0f;
                    _shopScrollVel = 0f;
                    break;
                }
            }
        }

        private void UpdateShopMomentum(ShopMenu shop, Func<Point, Vector2> uiToVp, int vpH)
        {
            if (shop == null || _isShopScrolling || _isShopThumbDragging)
            {
                _shopScrollVel = 0f;
                return;
            }
            float rowPitch = _shopCachedRowPitch > 24f ? _shopCachedRowPitch : ComputeShopRowPitchVp(shop, uiToVp, vpH);
            _shopScrollAccum += _shopScrollVel;
            ConsumeShopScrollAccum(shop, rowPitch);
            _shopScrollVel *= 0.88f;
            if (Math.Abs(_shopScrollVel) < 0.5f)
            {
                _shopScrollVel = 0f;
                _shopScrollAccum = 0f;
            }
        }

        private bool UpdateShopTouch(ShopMenu shop, TouchLocation tl, Vector2 vp, Point uiPt, Func<Point, Vector2> uiToVp, int vpH, double nowSec)
        {
            if (tl.State == TouchLocationState.Pressed)
            {
                ResetTouch();
                _shopScrollVel = 0f;

                // 1. Direct 1:1 touch-friendly Scrollbar Drag (expanded +/-30 UI px horizontal hit zone!)
                if (TryGetShopScrollTrackUi(shop, out Rectangle trackUi, out int maxIdx))
                {
                    Rectangle expandedTrack = new Rectangle(trackUi.X - 30, trackUi.Y - 14, trackUi.Width + 60, trackUi.Height + 28);
                    if (expandedTrack.Contains(uiPt) && !IsOnShopChromeButton(shop, uiPt))
                    {
                        _touchId = tl.Id;
                        _touchStartVp = vp;
                        _touchCurVp = vp;
                        _isShopThumbDragging = true;
                        ApplyShopScrollFromThumbY(shop, uiPt.Y, trackUi, maxIdx, nowSec);
                        return true;
                    }
                }

                // 2. Catalog item tap OR smooth swipe anywhere across catalog rows (including row gaps!)
                if (shop.forSaleButtons != null && shop.forSaleButtons.Count > 0 && !IsOnShopChromeButton(shop, uiPt))
                {
                    int hitBtn = -1;
                    Rectangle catalogBounds = Rectangle.Empty;
                    for (int i = 0; i < shop.forSaleButtons.Count; i++)
                    {
                        Rectangle b = shop.forSaleButtons[i].bounds;
                        if (b.Width <= 0 || b.Height <= 0) continue;
                        catalogBounds = catalogBounds.IsEmpty ? b : Rectangle.Union(catalogBounds, b);
                        if (hitBtn < 0 && b.Contains(uiPt))
                        {
                            int saleIdx = shop.currentItemIndex + i;
                            if (saleIdx >= 0 && saleIdx < shop.forSale.Count)
                                hitBtn = i;
                        }
                    }

                    bool inCatalogArea = hitBtn >= 0 || (!catalogBounds.IsEmpty &&
                        new Rectangle(catalogBounds.X - 8, catalogBounds.Y - 6, catalogBounds.Width + 16, catalogBounds.Height + 12).Contains(uiPt));

                    if (inCatalogArea)
                    {
                        _touchId = tl.Id;
                        _touchStartVp = vp;
                        _touchCurVp = vp;
                        _tappedShopBtnIdx = hitBtn;
                        _shopSwipeInCatalog = true;
                        _shopScrollLastY = vp.Y;
                        _shopScrollAccum = 0f;
                        _shopCachedRowPitch = ComputeShopRowPitchVp(shop, uiToVp, vpH);
                        return true;
                    }
                }

                // 3. Backpack item tap to sell (or store in Dresser)
                if (!shop.readOnly && shop.inventory != null)
                {
                    int slot = FindSlotAt(shop.inventory, uiPt);
                    if (slot >= 0)
                    {
                        Item it = GetItemAt(shop.inventory, slot);
                        if (it != null && shop.highlightItemToSell(it))
                        {
                            _touchId = tl.Id;
                            _touchStartVp = vp;
                            _touchCurVp = vp;
                            _dragSrcInv = shop.inventory;
                            _dragSrcSlot = slot;
                            _dragItem = it;
                            return true;
                        }
                    }
                }

                return false;
            }

            if (tl.Id != _touchId)
                return false;

            if (tl.State == TouchLocationState.Moved)
            {
                _touchCurVp = vp;

                if (_isShopThumbDragging)
                {
                    if (TryGetShopScrollTrackUi(shop, out Rectangle trackUi, out int maxIdx))
                        ApplyShopScrollFromThumbY(shop, uiPt.Y, trackUi, maxIdx, nowSec);
                    return true;
                }

                if (_shopSwipeInCatalog)
                {
                    float dy = vp.Y - _shopScrollLastY;
                    _shopScrollLastY = vp.Y;
                    float totalDy = Math.Abs(vp.Y - _touchStartVp.Y);
                    float dragThresh = Math.Max(16f, vpH * 0.018f);

                    if (!_isShopScrolling && totalDy >= dragThresh)
                    {
                        _isShopScrolling = true;
                        _shopScrollAccum = vp.Y - _touchStartVp.Y;
                        _shopScrollVel = dy;
                        ConsumeShopScrollAccum(shop, _shopCachedRowPitch);
                    }
                    else if (_isShopScrolling)
                    {
                        _shopScrollAccum += dy;
                        if (Math.Abs(dy) >= 0.4f)
                            _shopScrollVel = _shopScrollVel * 0.42f + dy * 0.58f;
                        else
                            _shopScrollVel *= 0.80f;
                        ConsumeShopScrollAccum(shop, _shopCachedRowPitch);
                    }
                }
                return true;
            }

            if (tl.State == TouchLocationState.Released || tl.State == TouchLocationState.Invalid)
            {
                bool wasScrolling = _isShopScrolling || _isShopThumbDragging;
                bool keepMomentum = _isShopScrolling && !_isShopThumbDragging;
                float releaseVel = keepMomentum ? Math.Clamp(_shopScrollVel, -vpH * 0.14f, vpH * 0.14f) : 0f;
                int btnIdx = _tappedShopBtnIdx;
                InventoryMenu sellInv = _dragSrcInv;
                int sellSlot = _dragSrcSlot;
                Item sellItem = _dragItem;
                ResetTouch();
                _shopScrollVel = Math.Abs(releaseVel) >= 2.2f ? releaseVel : 0f;

                if (!wasScrolling)
                {
                    if (btnIdx >= 0 && shop.forSaleButtons != null && btnIdx < shop.forSaleButtons.Count)
                    {
                        int saleIdx = shop.currentItemIndex + btnIdx;
                        if (saleIdx >= 0 && saleIdx < shop.forSale.Count)
                        {
                            ISalable sale = shop.forSale[saleIdx];
                            Point uiCenter = shop.forSaleButtons[btnIdx].bounds.Center;
                            if (IsStorageShop(shop))
                            {
                                // 1-Tap Dresser withdraw directly into Backpack (zero "Mua 0g" popup!)
                                DirectBuyOneIntoBackpack(shop, sale, uiCenter);
                                return true;
                            }
                            OpenShopBuyPopup(shop, sale, uiCenter);
                            return true;
                        }
                    }
                    else if (sellInv != null && sellSlot >= 0 && sellItem != null)
                    {
                        Point uiCenter = sellInv.inventory[sellSlot].bounds.Center;
                        if (IsStorageShop(shop))
                        {
                            // 1-Tap Dresser store directly from Backpack (zero "Bán 0g" popup!)
                            try { shop.receiveLeftClick(uiCenter.X, uiCenter.Y, true); } catch { }
                            return true;
                        }
                        OpenShopSellPopup(shop, sellInv, sellSlot, sellItem, uiCenter);
                        return true;
                    }
                }
                return true;
            }

            return true;
        }

        private static void RescueHeldItemToPlayer(Item item)
        {
            if (item == null || Game1.player == null) return;
            Item rem = null;
            try { rem = Game1.player.addItemToInventory(item); } catch { rem = item; }
            if (rem != null)
            {
                try { Game1.createItemDebris(rem, Game1.player.getStandingPosition(), Game1.player.FacingDirection); } catch { }
            }
        }

        private static void DirectBuyOneIntoBackpack(ShopMenu shop, ISalable sale, Point uiCenter)
        {
            if (shop == null || sale == null) return;
            if (shop.heldItem is Item prevHeld)
            {
                RescueHeldItemToPlayer(prevHeld);
                shop.heldItem = null;
            }

            if (!sale.IsRecipe && sale is Item checkItem && !Game1.player.couldInventoryAcceptThisItem(checkItem.getOne()))
            {
                try { Game1.playSound("cancel"); } catch { }
                return;
            }

            bool soldOut = false;
            try
            {
                if (ShopTryPurchaseMethod != null)
                    soldOut = (bool)ShopTryPurchaseMethod.Invoke(shop, new object[] { sale, null, 1, uiCenter.X, uiCenter.Y });
            }
            catch { soldOut = false; }

            if (soldOut)
            {
                try
                {
                    shop.itemPriceAndStock?.Remove(sale);
                    shop.forSale?.Remove(sale);
                }
                catch { }
            }
            if (shop.heldItem is Item bought)
            {
                RescueHeldItemToPlayer(bought);
                shop.heldItem = null;
            }
            else
            {
                shop.heldItem = null;
            }
        }

        private void OpenShopBuyPopup(ShopMenu shop, ISalable sale, Point uiCenter)
        {
            if (sale == null) return;

            int price = 0;
            int stock = ShopMenu.infiniteStock;
            string tradeId = null;
            int tradeCount = 0;

            if (shop.itemPriceAndStock != null && shop.itemPriceAndStock.TryGetValue(sale, out ItemStockInformation info))
            {
                price = info.Price;
                stock = info.Stock;
                tradeId = info.TradeItem;
                tradeCount = info.TradeItemCount ?? 5;
            }

            int maxByMoney = (price > 0)
                ? ShopMenu.getPlayerCurrencyAmount(Game1.player, shop.currency) / price
                : 999;

            int maxByTrade = (!string.IsNullOrEmpty(tradeId) && tradeCount > 0)
                ? GetPlayerTradeItemCount(Game1.player, tradeId) / tradeCount
                : 999;

            int bundleStack = Math.Max(1, sale.Stack);
            int maxByStock = (stock == ShopMenu.infiniteStock) ? 999 : Math.Max(0, stock);
            int rawMaxStack = (sale.IsRecipe || sale.maximumStackSize() <= 1) ? 1 : sale.maximumStackSize();
            int maxStack = Math.Max(1, rawMaxStack / bundleStack);
            int affordable = Math.Min(maxByMoney, maxByTrade);
            int maxBuy = Math.Min(Math.Min(maxByStock, maxStack), Math.Max(1, affordable));
            maxBuy = Math.Clamp(maxBuy, 1, 999);

            _popupKind = PopupKind.ShopBuy;
            _popupOwnerMenu = shop;
            _popupSaleItem = sale;
            _popupItem = sale as Item;
            _popupUiClickPt = uiCenter;
            _popupMinQty = 1;
            _popupMaxQty = maxBuy;
            _popupQty = 1;
            _popupUnitPrice = price;
            _popupCurrency = shop.currency;
            _popupStock = stock;
            _popupTradeItemId = tradeId;
            _popupTradeCount = tradeCount;
            _popupBundlePerPurchase = bundleStack;
            _popupCanAfford = (affordable >= 1 && maxByStock >= 1);

            try { Game1.playSound("smallSelect"); } catch { }
        }

        private void OpenShopSellPopup(ShopMenu shop, InventoryMenu inv, int slot, Item item, Point uiCenter)
        {
            int unitPrice = 0;
            try
            {
                float rawSell = Utility.getSellToStorePriceOfItem(item, countStack: false);
                if (shop != null && ShopSellPctField?.GetValue(shop) is float sp && Math.Abs(sp - 1f) > 0.001f)
                    rawSell *= sp;
                unitPrice = (int)rawSell;
            }
            catch { }
            if (unitPrice < 0) unitPrice = 0;

            _popupKind = PopupKind.ShopSell;
            _popupOwnerMenu = shop;
            _popupItem = item;
            _popupSaleItem = item;
            _popupSrcInv = inv;
            _popupSrcSlot = slot;
            _popupUiClickPt = uiCenter;
            _popupMinQty = 1;
            _popupMaxQty = Math.Max(1, item.Stack);
            _popupQty = Math.Max(1, item.Stack);
            _popupUnitPrice = unitPrice;
            _popupCurrency = shop.currency;
            _popupCanAfford = true;

            try { Game1.playSound("smallSelect"); } catch { }
        }

        private void ExecutePopupConfirm()
        {
            if (_popupKind == PopupKind.ShopBuy && _popupOwnerMenu is ShopMenu shop && _popupSaleItem != null)
            {
                if (!_popupCanAfford)
                {
                    try { Game1.playSound("cancel"); } catch { }
                    return;
                }

                // Clear any previous held cursor item cleanly into Backpack (or drop safely if full — never delete!)
                if (shop.heldItem is Item prevHeld)
                {
                    RescueHeldItemToPlayer(prevHeld);
                    shop.heldItem = null;
                }

                // Do NOT block Clint's Tool Upgrades / special action purchases (which remove the old tool or trigger instant services!) when Backpack is full
                bool isUpgradeOrService = _popupSaleItem.IsRecipe
                    || _popupSaleItem is Tool
                    || shop.onPurchase != null
                    || (!string.IsNullOrEmpty(shop.ShopId) && shop.ShopId.IndexOf("Upgrade", StringComparison.OrdinalIgnoreCase) >= 0);

                if (!isUpgradeOrService && _popupSaleItem is Item checkItem)
                {
                    Item probe = checkItem.getOne();
                    probe.Stack = _popupQty * Math.Max(1, _popupBundlePerPurchase);
                    bool freesTradeSlot = !string.IsNullOrEmpty(_popupTradeItemId) && _popupTradeCount > 0 &&
                                          !IsSpecialWalletTradeCurrency(_popupTradeItemId) &&
                                          Game1.player.Items.CountId(_popupTradeItemId) == _popupQty * _popupTradeCount;
                    if (!freesTradeSlot && !Game1.player.couldInventoryAcceptThisItem(probe))
                    {
                        try { Game1.playSound("cancel"); } catch { }
                        ClosePopup();
                        return;
                    }
                }

                // NOTE: ShopMenu.tryToPurchaseItem returns `bool soldOut` (true ONLY when stock reached 0!),
                // NOT `bool purchased`! On normal infinite-stock purchases (e.g. seeds) it sets shop.heldItem
                // and returns false!
                bool soldOut = false;
                try
                {
                    if (ShopTryPurchaseMethod != null)
                    {
                        soldOut = (bool)ShopTryPurchaseMethod.Invoke(shop, new object[] { _popupSaleItem, null, _popupQty, _popupUiClickPt.X, _popupUiClickPt.Y });
                    }
                }
                catch { soldOut = false; }

                if (soldOut)
                {
                    try
                    {
                        shop.itemPriceAndStock?.Remove(_popupSaleItem);
                        shop.forSale?.Remove(_popupSaleItem);
                    }
                    catch { }
                }

                // ALWAYS move purchased item from shop.heldItem STRAIGHT into Backpack (NEVER leave stuck on cursor!)
                if (shop.heldItem is Item bought)
                {
                    Item leftover = Game1.player.addItemToInventory(bought);
                    if (leftover != null && Game1.player != null)
                    {
                        try { Game1.createItemDebris(leftover, Game1.player.getStandingPosition(), Game1.player.FacingDirection); } catch { }
                    }
                    shop.heldItem = null;
                }
                else
                {
                    shop.heldItem = null;
                }
            }
            else if (_popupKind == PopupKind.Craft && _popupCraftPage != null && _popupCraftBtn != null && _popupCraftRecipe != null)
            {
                if (!_popupCanAfford)
                {
                    try { Game1.playSound("cancel"); } catch { }
                    return;
                }

                // Clear any leftover heldItem first (never let full backpack block crafting or vaporize heldItem!)
                if (_popupCraftPage.heldItem != null && Game1.player != null)
                {
                    RescueHeldItemToPlayer(_popupCraftPage.heldItem);
                    _popupCraftPage.heldItem = null;
                }

                int craftedAny = 0;
                for (int c = 0; c < _popupQty; c++)
                {
                    int avail = 0;
                    try { avail = _popupCraftRecipe.getCraftableCount(GetContainerItemsList(_popupCraftPage._materialContainers)); } catch { avail = 0; }
                    if (avail <= 0)
                        break;

                    // Verify Backpack can accept crafted item before consuming materials
                    try
                    {
                        Item testOut = _popupCraftRecipe.createItem();
                        if (testOut != null && Game1.player != null && !Game1.player.couldInventoryAcceptThisItem(testOut))
                        {
                            if (craftedAny == 0)
                                try { Game1.playSound("cancel"); } catch { }
                            break;
                        }
                    }
                    catch { }

                    try
                    {
                        if (CraftClickRecipeMethod != null)
                            CraftClickRecipeMethod.Invoke(_popupCraftPage, new object[] { _popupCraftBtn, c == 0 });
                    }
                    catch { break; }

                    if (_popupCraftPage.heldItem != null && Game1.player != null)
                    {
                        Item rem = Game1.player.addItemToInventory(_popupCraftPage.heldItem);
                        _popupCraftPage.heldItem = rem;
                        if (rem != null)
                            break;
                    }
                    craftedAny++;
                }
            }
            else if (_popupKind == PopupKind.ShopSell && _popupOwnerMenu is ShopMenu sellShop && _popupSrcInv != null && _popupSrcSlot >= 0)
            {
                if (sellShop.heldItem is Item prevSellHeld && Game1.player != null)
                {
                    Item rem = Game1.player.addItemToInventory(prevSellHeld);
                    if (rem != null)
                        try { Game1.createItemDebris(rem, Game1.player.getStandingPosition(), Game1.player.FacingDirection); } catch { }
                    sellShop.heldItem = null;
                }
                Item cur = GetItemAt(_popupSrcInv, _popupSrcSlot);
                if (cur != null && _popupQty > 0 && sellShop.highlightItemToSell(cur))
                {
                    int sellQty = Math.Min(_popupQty, cur.Stack);
                    if (sellQty >= cur.Stack)
                    {
                        try { sellShop.receiveLeftClick(_popupUiClickPt.X, _popupUiClickPt.Y, true); } catch { }
                    }
                    else
                    {
                        int remain = cur.Stack - sellQty;
                        Item partial = cur.getOne();
                        partial.Stack = sellQty;
                        SetItemAt(_popupSrcInv, _popupSrcSlot, partial);
                        try { sellShop.receiveLeftClick(_popupUiClickPt.X, _popupUiClickPt.Y, true); } catch { }
                        Item after = GetItemAt(_popupSrcInv, _popupSrcSlot);
                        if (after == null)
                        {
                            cur.Stack = remain;
                            SetItemAt(_popupSrcInv, _popupSrcSlot, cur);
                        }
                        else
                        {
                            SetItemAt(_popupSrcInv, _popupSrcSlot, cur);
                        }
                    }
                }
            }
            else if (_popupKind == PopupKind.ChestSplit && _popupOwnerMenu is ItemGrabMenu grab && _popupSrcInv != null && _popupSrcSlot >= 0)
            {
                Item cur = GetItemAt(_popupSrcInv, _popupSrcSlot);
                if (cur != null && _popupQty > 0)
                {
                    int moveQty = Math.Min(_popupQty, cur.Stack);
                    TransferQuantityBetweenInventories(grab, _popupSrcInv, _popupSrcSlot, _popupDstInv, moveQty);
                }
            }
            else if (_popupKind == PopupKind.BagSplit && _popupSrcInv != null && _popupSrcSlot >= 0)
            {
                Item cur = GetItemAt(_popupSrcInv, _popupSrcSlot);
                if (cur != null && cur.Stack > 1 && _popupQty > 0 && _popupQty < cur.Stack)
                {
                    int emptySlot = FindFirstEmptySlot(_popupSrcInv);
                    if (emptySlot >= 0)
                    {
                        Item split = cur.getOne();
                        split.Stack = _popupQty;
                        cur.Stack -= _popupQty;
                        SetItemAt(_popupSrcInv, emptySlot, split);
                        try { Game1.playSound("dwop"); } catch { }
                    }
                    else
                    {
                        try { Game1.playSound("cancel"); } catch { }
                    }
                }
            }

            ClosePopup();
        }

        // =========================================================================
        // B. MOBILE ITEM MOVEMENT (Zero Mouse Cursor Bug!)
        // =========================================================================
        private bool UpdateInventoryTouch(
            IClickableMenu ownerMenu,
            InventoryMenu playerInv,
            InventoryMenu chestInv,
            ClickableTextureComponent trashCan,
            List<ClickableComponent> equipIcons,
            bool isChestMenu,
            TouchLocation tl,
            Vector2 vp,
            Point uiPt,
            int vpH,
            double nowSec)
        {
            if (tl.State == TouchLocationState.Pressed)
            {
                ResetTouch();

                // If user has a Tap-Selected slot in Backpack and taps DROP button below Trash Can -> drop onto ground (great for Co-op!)
                if (!isChestMenu && _selectedBagSlot >= 0 && _selectedBagInv != null && trashCan != null)
                {
                    Rectangle dropUi = ComputeDropBtnUiRect(trashCan);
                    if (dropUi.Contains(uiPt))
                    {
                        Item selItem = GetItemAt(_selectedBagInv, _selectedBagSlot);
                        if (selItem != null && selItem.canBeDropped() && Game1.player != null)
                        {
                            SetItemAt(_selectedBagInv, _selectedBagSlot, null);
                            try { Game1.createItemDebris(selItem, Game1.player.getStandingPosition(), Game1.player.FacingDirection); } catch { }
                            try { Game1.playSound("throwDownITem"); } catch { }
                        }
                        else
                        {
                            try { Game1.playSound("cancel"); } catch { }
                        }
                        ClearSelection();
                        _popConsumeTouchId = tl.Id;
                        return true;
                    }
                }

                // If user has a Tap-Selected slot in Backpack and taps Trash Can -> trash cleanly!
                if (!isChestMenu && _selectedBagSlot >= 0 && _selectedBagInv != null &&
                    trashCan != null && trashCan.containsPoint(uiPt.X, uiPt.Y))
                {
                    Item selItem = GetItemAt(_selectedBagInv, _selectedBagSlot);
                    if (selItem != null && selItem.canBeTrashed())
                    {
                        SetItemAt(_selectedBagInv, _selectedBagSlot, null);
                        try { Utility.trashItem(selItem); } catch { }
                    }
                    ClearSelection();
                    _popConsumeTouchId = tl.Id;
                    return true;
                }

                // If user taps an Equipment slot (Ring / Boots / Hat / Shirt / Pants / Trinket):
                // - With a Backpack item selected -> equip it cleanly!
                // - With NO Backpack item selected -> unequip straight into Backpack (NEVER leaves item stuck on CursorSlotItem!)
                if (!isChestMenu && equipIcons != null && ownerMenu is InventoryPage ipEq)
                {
                    for (int i = 0; i < equipIcons.Count; i++)
                    {
                        if (equipIcons[i].containsPoint(uiPt.X, uiPt.Y))
                        {
                            if (_selectedBagSlot >= 0 && _selectedBagInv != null)
                            {
                                Item selItem = GetItemAt(_selectedBagInv, _selectedBagSlot);
                                if (selItem != null)
                                    TryEquipItem(ipEq, _selectedBagInv, _selectedBagSlot, selItem, uiPt);
                                ClearSelection();
                            }
                            else
                            {
                                TryUnequipToBackpack(ipEq, uiPt);
                            }
                            _popConsumeTouchId = tl.Id;
                            return true;
                        }
                    }
                }

                InventoryMenu hitInv = null;
                int hitSlot = -1;

                if (chestInv != null)
                {
                    int s = FindSlotAt(chestInv, uiPt, allowStrandedOccupied: true);
                    if (s >= 0) { hitInv = chestInv; hitSlot = s; }
                }
                if (hitInv == null && playerInv != null)
                {
                    int s = FindSlotAt(playerInv, uiPt, allowStrandedOccupied: true);
                    if (s >= 0) { hitInv = playerInv; hitSlot = s; }
                }

                if (hitInv != null && hitSlot >= 0)
                {
                    Item it = GetItemAt(hitInv, hitSlot);

                    // If tapping an EMPTY slot while another Backpack slot is selected -> instant move (ONLY into unlocked slots!)
                    if (it == null && !isChestMenu && _selectedBagSlot >= 0 && _selectedBagInv != null)
                    {
                        if (!IsSlotUnlocked(hitInv, hitSlot))
                        {
                            try { Game1.playSound("cancel"); } catch { }
                            ClearSelection();
                            _popConsumeTouchId = tl.Id;
                            return true;
                        }
                        MoveOrSwapSlots(null, _selectedBagInv, _selectedBagSlot, hitInv, hitSlot);
                        ClearSelection();
                        _popConsumeTouchId = tl.Id;
                        return true;
                    }

                    // Intercept ANY occupied slot cleanly (never sticks to mouse cursor!)
                    if (it != null && Game1.player.CursorSlotItem == null)
                    {
                        _touchId = tl.Id;
                        _touchStartVp = vp;
                        _touchCurVp = vp;
                        _touchStartSec = nowSec;
                        _dragSrcInv = hitInv;
                        _dragSrcSlot = hitSlot;
                        _dragItem = it;
                        _isDragging = false;
                        return true;
                    }
                }

                // If player tapped a LOCKED backpack row while holding a selection -> play cancel & clear selection!
                if (!isChestMenu && _selectedBagSlot >= 0 && playerInv != null && IsPointInLockedBackpackSlot(playerInv, uiPt))
                {
                    try { Game1.playSound("cancel"); } catch { }
                    ClearSelection();
                    _popConsumeTouchId = tl.Id;
                    return true;
                }

                // Tapped outside slots (e.g. tab bar, organize, close X) -> clear highlight & let native UI click work
                ClearSelection();
                return false;
            }

            if (tl.Id != _touchId || _dragSrcInv == null || _dragSrcSlot < 0)
                return false;

            if (tl.State == TouchLocationState.Moved)
            {
                _touchCurVp = vp;
                float dist = Vector2.Distance(vp, _touchStartVp);
                // Snappy Backpack drag threshold (~7-9pt on iPhone) for instant item lift;
                // Chest keeps a safer threshold (~12-15pt) so rapid 1-tap chest transfers never misfire as drags!
                float dragThresh = isChestMenu
                    ? Math.Max(24f, vpH * 0.025f)
                    : Math.Max(14f, vpH * 0.014f);

                if (!_isDragging)
                {
                    if (dist >= dragThresh)
                    {
                        _isDragging = true;
                        ClearSelection();
                        try { Game1.playSound("smallSelect"); } catch { }
                    }
                    else if ((nowSec - _touchStartSec) >= 0.36)
                    {
                        if (_dragItem != null && _dragItem.Stack > 1)
                        {
                            // Long-Press on stack > 1 -> Mobile Pixel Split Quantity Slider!
                            InventoryMenu srcInv = _dragSrcInv;
                            int srcSlot = _dragSrcSlot;
                            Item item = _dragItem;
                            InventoryMenu dstInv = isChestMenu ? ((srcInv == playerInv) ? chestInv : playerInv) : null;
                            _popConsumeTouchId = tl.Id;
                            ResetTouch();
                            ClearSelection();
                            OpenSplitPopup(ownerMenu, srcInv, srcSlot, dstInv, item, isChestMenu);
                            return true;
                        }
                        else if (_dragItem is Tool attTool && HasAnyAttachment(attTool))
                        {
                            // Stationary Long-Press (>=0.36s, dist < dragThresh) on FishingRod/Slingshot with attached Bait/Tackle/Ammo
                            // pops 1 attachment cleanly into Backpack (including 1.6 Advanced Iridium Rod's 2nd Tackle slot!).
                            // Moving finger >= dragThresh still drags the tool normally!
                            if (TryDetachOneAttachment(attTool))
                            {
                                try { Game1.playSound("dwop"); } catch { }
                            }
                            else
                            {
                                try { Game1.playSound("cancel"); } catch { }
                            }
                            _popConsumeTouchId = tl.Id;
                            ResetTouch();
                            ClearSelection();
                            return true;
                        }
                        else if (_dragItem != null)
                        {
                            // Long-Press on single item (Stack == 1) -> smoothly lift under finger for Drag-and-Drop (NEVER transfer to mouse cursor!)
                            _isDragging = true;
                            ClearSelection();
                            try { Game1.playSound("smallSelect"); } catch { }
                        }
                    }
                }
                return true;
            }

            if (tl.State == TouchLocationState.Released || tl.State == TouchLocationState.Invalid)
            {
                bool wasDragging = _isDragging;
                double heldSec = nowSec - _touchStartSec;
                InventoryMenu srcInv = _dragSrcInv;
                int srcSlot = _dragSrcSlot;
                Item item = _dragItem;
                ResetTouch();

                if (item == null || srcInv == null || srcSlot < 0)
                    return true;

                if (wasDragging)
                {
                    if (trashCan != null && trashCan.containsPoint(uiPt.X, uiPt.Y) && item.canBeTrashed())
                    {
                        SetItemAt(srcInv, srcSlot, null);
                        try { Utility.trashItem(item); } catch { }
                        return true;
                    }

                    InventoryMenu dstInv = null;
                    int dstSlot = -1;
                    if (chestInv != null)
                    {
                        int s = FindSlotAt(chestInv, uiPt);
                        if (s >= 0) { dstInv = chestInv; dstSlot = s; }
                    }
                    if (dstInv == null && playerInv != null)
                    {
                        int s = FindSlotAt(playerInv, uiPt);
                        if (s >= 0) { dstInv = playerInv; dstSlot = s; }
                    }

                    if (dstInv != null && dstSlot >= 0)
                    {
                        if (dstInv == srcInv && dstSlot == srcSlot)
                        {
                            // Fast thumb wobble on a Chest slot -> recover cleanly as a 1-tap transfer!
                            if (isChestMenu && ownerMenu is ItemGrabMenu grabRecover && heldSec < 0.28)
                            {
                                ExecuteChestTapTransfer(grabRecover, playerInv, chestInv, srcInv, srcSlot, item);
                            }
                            return true;
                        }
                        if (!IsSlotUnlocked(dstInv, dstSlot))
                        {
                            try { Game1.playSound("cancel"); } catch { }
                            return true;
                        }
                        if (ownerMenu is ItemGrabMenu grabDrop && srcInv == playerInv && dstInv == chestInv && !CanDepositIntoGrabMenu(grabDrop))
                        {
                            try { Game1.playSound("cancel"); } catch { }
                            return true;
                        }
                        MoveOrSwapSlots(ownerMenu as ItemGrabMenu, srcInv, srcSlot, dstInv, dstSlot);
                        return true;
                    }

                    // Generous Chest/Backpack Drop-Zone Forgiveness:
                    // Dropping anywhere inside the opposite inventory panel (even on slot gaps or borders!) transfers cleanly!
                    if (isChestMenu && ownerMenu is ItemGrabMenu grabArea)
                    {
                        if (srcInv == playerInv && chestInv != null && IsPointInInventoryPanel(chestInv, uiPt, 26))
                        {
                            if (!CanDepositIntoGrabMenu(grabArea))
                            {
                                try { Game1.playSound("cancel"); } catch { }
                                return true;
                            }
                            TransferQuantityBetweenInventories(grabArea, srcInv, srcSlot, chestInv, Math.Max(1, item.Stack));
                            return true;
                        }
                        if (srcInv == chestInv && playerInv != null && IsPointInInventoryPanel(playerInv, uiPt, 26))
                        {
                            TransferQuantityBetweenInventories(grabArea, srcInv, srcSlot, playerInv, Math.Max(1, item.Stack));
                            return true;
                        }
                    }

                    if (playerInv != null && IsPointInLockedBackpackSlot(playerInv, uiPt))
                    {
                        try { Game1.playSound("cancel"); } catch { }
                        return true;
                    }

                    if (equipIcons != null && ownerMenu is InventoryPage ip)
                    {
                        for (int i = 0; i < equipIcons.Count; i++)
                        {
                            if (equipIcons[i].containsPoint(uiPt.X, uiPt.Y))
                            {
                                TryEquipItem(ip, srcInv, srcSlot, item, uiPt);
                                return true;
                            }
                        }
                    }

                    // Released outside any slot -> smoothly cancel drag back to original slot (never sticks to mouse or drops!)
                    return true;
                }
                else
                {
                    // SHORT TAP!
                    if (isChestMenu && ownerMenu is ItemGrabMenu grab)
                    {
                        ExecuteChestTapTransfer(grab, playerInv, chestInv, srcInv, srcSlot, item);
                        return true;
                    }
                    else if (ownerMenu is InventoryPage ip)
                    {
                        // Mobile Backpack Tap-Split when X1 or 1/2 mode is active (zero stuck mouse cursor!)
                        if (TapMode != ChestTapMode.FullStack && item.Stack > 1)
                        {
                            int splitQty = TapMode == ChestTapMode.SingleOne ? 1 : Math.Max(1, item.Stack / 2);
                            splitQty = Math.Clamp(splitQty, 1, item.Stack - 1);
                            int emptySlot = FindFirstEmptySlot(srcInv);
                            if (emptySlot >= 0)
                            {
                                Item split = item.getOne();
                                split.Stack = splitQty;
                                item.Stack -= splitQty;
                                SetItemAt(srcInv, emptySlot, split);
                                ClearSelection();
                                try { Game1.playSound("dwop"); } catch { }
                            }
                            else
                            {
                                try { Game1.playSound("cancel"); } catch { }
                            }
                            return true;
                        }

                        // Mobile Backpack Tap-Select / Tap-Swap (NEVER puts item on mouse cursor!)
                        if (_selectedBagSlot < 0)
                        {
                            _selectedBagSlot = srcSlot;
                            _selectedBagInv = srcInv;
                            try { ip.performHoverAction(uiPt.X, uiPt.Y); } catch { }
                            try { Game1.playSound("smallSelect"); } catch { }
                        }
                        else if (_selectedBagSlot == srcSlot && _selectedBagInv == srcInv)
                        {
                            ClearSelection();
                        }
                        else
                        {
                            MoveOrSwapSlots(null, _selectedBagInv, _selectedBagSlot, srcInv, srcSlot);
                            ClearSelection();
                        }
                        return true;
                    }
                }
            }

            return true;
        }

        private static Rectangle ComputeDropBtnUiRect(ClickableTextureComponent trashCan)
        {
            if (trashCan == null) return Rectangle.Empty;
            int w = Math.Max(trashCan.bounds.Width + 28, 92);
            int h = 44;
            int x = trashCan.bounds.Center.X - w / 2;
            int y = trashCan.bounds.Bottom + 10;
            if (Game1.uiViewport.Height > 0 && y + h > Game1.uiViewport.Height - 12)
                y = Math.Max(8, trashCan.bounds.Y - h - 10);
            return new Rectangle(x, y, w, h);
        }

        private static bool HasAnyAttachment(Tool tool)
        {
            if (tool == null || tool.attachments == null || tool.AttachmentSlotsCount <= 0)
                return false;
            for (int i = 0; i < tool.attachments.Length; i++)
            {
                if (tool.attachments[i] != null)
                    return true;
            }
            return false;
        }

        private static bool TryDetachOneAttachment(Tool tool)
        {
            if (tool == null || Game1.player == null || !HasAnyAttachment(tool))
                return false;
            StardewValley.Object firstAtt = null;
            int foundIdx = -1;
            for (int i = 0; i < tool.attachments.Length; i++)
            {
                if (tool.attachments[i] != null) { firstAtt = tool.attachments[i]; foundIdx = i; break; }
            }
            if (firstAtt == null || !Game1.player.couldInventoryAcceptThisItem(firstAtt))
                return false;

            StardewValley.Object popped = null;
            try { popped = tool.attach(null); } catch { popped = null; }
            if (popped == null && foundIdx >= 0 && tool.attachments[foundIdx] != null)
            {
                // Fallback for 1.6 Advanced Iridium Rod 2nd Tackle slot (attachments[2]) if vanilla attach(null) skipped it!
                popped = tool.attachments[foundIdx];
                tool.attachments[foundIdx] = null;
            }
            if (popped != null)
            {
                Item rem = Game1.player.addItemToInventory(popped);
                if (rem is StardewValley.Object remObj)
                {
                    StardewValley.Object leftover = tool.attach(remObj);
                    if (leftover != null)
                        RescueHeldItemToPlayer(leftover);
                }
                return true;
            }
            return false;
        }

        private static void TryEquipItem(InventoryPage ip, InventoryMenu srcInv, int srcSlot, Item item, Point uiPt)
        {
            if (Game1.player == null) return;
            if (Game1.player.CursorSlotItem != null)
            {
                RescueHeldItemToPlayer(Game1.player.CursorSlotItem);
                Game1.player.CursorSlotItem = null;
            }
            SetItemAt(srcInv, srcSlot, null);
            try { item?.onDetachedFromParent(); } catch { }
            Game1.player.CursorSlotItem = item;
            try { ip.receiveLeftClick(uiPt.X, uiPt.Y, true); } catch { }
            if (Game1.player.CursorSlotItem != null)
            {
                Item back = Game1.player.CursorSlotItem;
                Game1.player.CursorSlotItem = null;
                if (GetItemAt(srcInv, srcSlot) == null)
                    SetItemAt(srcInv, srcSlot, back);
                else
                    RescueHeldItemToPlayer(back);
            }
        }

        private static void TryUnequipToBackpack(InventoryPage ip, Point uiPt)
        {
            if (ip == null || Game1.player == null) return;
            if (Game1.player.CursorSlotItem != null)
            {
                RescueHeldItemToPlayer(Game1.player.CursorSlotItem);
                Game1.player.CursorSlotItem = null;
            }
            try { ip.receiveLeftClick(uiPt.X, uiPt.Y, true); } catch { }
            Item lifted = Game1.player.CursorSlotItem;
            if (lifted == null) return;

            Game1.player.CursorSlotItem = null;
            Item rem = null;
            try { rem = Game1.player.addItemToInventory(lifted); } catch { rem = lifted; }
            if (rem != null)
            {
                // Backpack is completely full -> re-equip back into slot; if re-equip fails, drop safely via createItemDebris!
                Game1.player.CursorSlotItem = rem;
                try { ip.receiveLeftClick(uiPt.X, uiPt.Y, true); } catch { }
                if (Game1.player.CursorSlotItem != null)
                {
                    RescueHeldItemToPlayer(Game1.player.CursorSlotItem);
                    Game1.player.CursorSlotItem = null;
                }
                try { Game1.playSound("cancel"); } catch { }
            }
            else
            {
                try { Game1.playSound("dwop"); } catch { }
            }
        }

        private void OpenSplitPopup(IClickableMenu owner, InventoryMenu srcInv, int srcSlot, InventoryMenu dstInv, Item item, bool isChest)
        {
            int curStack = Math.Max(1, item?.Stack ?? 1);
            _popupKind = isChest ? PopupKind.ChestSplit : PopupKind.BagSplit;
            _popupOwnerMenu = owner;
            _popupItem = item;
            _popupSaleItem = item;
            _popupSrcInv = srcInv;
            _popupSrcSlot = srcSlot;
            _popupDstInv = dstInv;
            _popupMinQty = 1;
            _popupMaxQty = isChest ? curStack : Math.Max(1, curStack - 1);
            _popupQty = Math.Clamp(curStack / 2, _popupMinQty, _popupMaxQty);
            _popupUnitPrice = 0;
            _popupCanAfford = true;
            try { Game1.playSound("smallSelect"); } catch { }
        }

        private static bool CanDepositIntoGrabMenu(ItemGrabMenu grab)
        {
            // Matches vanilla ItemGrabMenu.receiveLeftClick (IL_049a..IL_04a8):
            // Normal Chests, Fridges, Junimo Chests, Enrichers, Mills, Special Order DropBoxes all have reverseGrab==false
            // and behaviorFunction != null; ONLY read-only reward chests (Fishing Treasure / Mine Reward) have behaviorFunction == null!
            return grab != null && (grab.reverseGrab || grab.shippingBin || grab.behaviorFunction != null);
        }

        private void MoveOrSwapSlots(ItemGrabMenu grab, InventoryMenu srcInv, int srcSlot, InventoryMenu dstInv, int dstSlot)
        {
            if (srcInv == null || dstInv == null || srcSlot < 0 || dstSlot < 0)
                return;

            // Strictly block placing ANY item into locked backpack rows (before buying Large/Deluxe Pack from Pierre!)
            if (!IsSlotUnlocked(dstInv, dstSlot))
            {
                try { Game1.playSound("cancel"); } catch { }
                return;
            }

            bool srcLockedStranded = !IsSlotUnlocked(srcInv, srcSlot);
            Item srcItem = GetItemAt(srcInv, srcSlot);
            if (srcItem == null) return;
            if (srcItem.Stack <= 0) srcItem.Stack = 1;

            if (grab != null && grab.shippingBin && dstInv == grab.ItemsToGrabMenu && srcInv == grab.inventory)
            {
                TransferQuantityBetweenInventories(grab, srcInv, srcSlot, dstInv, Math.Max(1, srcItem.Stack));
                return;
            }

            // Enforce source inventory filter when depositing from backpack into filtered containers (Enricher / Special Order)
            if (grab != null && srcInv == grab.inventory && dstInv == grab.ItemsToGrabMenu &&
                srcInv.highlightMethod != null && !srcInv.highlightMethod(srcItem))
            {
                try { Game1.playSound("cancel"); } catch { }
                return;
            }

            if (dstInv.highlightMethod != null && !dstInv.highlightMethod(srcItem))
            {
                try { Game1.playSound("cancel"); } catch { }
                return;
            }

            Item dstItem = GetItemAt(dstInv, dstSlot);
            if (dstItem == null)
            {
                // Detach from source FIRST so NetFields.Parent stays bound to dstInv!
                SetItemAt(srcInv, srcSlot, null);
                try { srcItem.onDetachedFromParent(); } catch { }
                SetItemAt(dstInv, dstSlot, srcItem);
                try { Game1.playSound("stoneStep"); } catch { }
            }
            else if (dstItem is Tool dstTool && dstTool.AttachmentSlotsCount > 0 && srcItem is StardewValley.Object srcObj && dstTool.canThisBeAttached(srcObj))
            {
                // Direct Mobile Attach: drag/tap Bait or Tackle onto FishingRod, or Ammo onto Slingshot!
                StardewValley.Object swapped = dstTool.attach(srcObj);
                if (srcLockedStranded && swapped != null)
                {
                    Item rem = Game1.player?.addItemToInventory(swapped);
                    SetItemAt(srcInv, srcSlot, null);
                    if (rem != null && Game1.player != null)
                        try { Game1.createItemDebris(rem, Game1.player.getStandingPosition(), Game1.player.FacingDirection); } catch { }
                }
                else
                {
                    SetItemAt(srcInv, srcSlot, swapped);
                }
                try { Game1.playSound("button1"); } catch { }
            }
            else if (srcItem is Tool srcTool && srcTool.AttachmentSlotsCount > 0 && dstItem is StardewValley.Object dstObj && srcTool.canThisBeAttached(dstObj))
            {
                if (srcLockedStranded)
                {
                    try { Game1.playSound("cancel"); } catch { }
                    return;
                }
                // Reverse direction (drag/tap Rod onto Bait or Slingshot onto Ammo) also attaches cleanly!
                StardewValley.Object swapped = srcTool.attach(dstObj);
                SetItemAt(dstInv, dstSlot, swapped);
                try { Game1.playSound("button1"); } catch { }
            }
            else if (dstItem.canStackWith(srcItem))
            {
                int rem = dstItem.addToStack(srcItem);
                if (rem <= 0) SetItemAt(srcInv, srcSlot, null);
                else srcItem.Stack = rem;
                try { Game1.playSound("stoneStep"); } catch { }
            }
            else
            {
                // Never swap another item BACK into a locked backpack slot!
                if (srcLockedStranded || (srcInv.highlightMethod != null && !srcInv.highlightMethod(dstItem)))
                {
                    try { Game1.playSound("cancel"); } catch { }
                    return;
                }
                if (dstItem.Stack <= 0) dstItem.Stack = 1;
                SetItemAt(srcInv, srcSlot, null);
                SetItemAt(dstInv, dstSlot, null);
                try { srcItem.onDetachedFromParent(); } catch { }
                try { dstItem.onDetachedFromParent(); } catch { }
                SetItemAt(dstInv, dstSlot, srcItem);
                SetItemAt(srcInv, srcSlot, dstItem);
                try { Game1.playSound("stoneStep"); } catch { }
            }
        }

        private void ExecuteChestTapTransfer(ItemGrabMenu grab, InventoryMenu playerInv, InventoryMenu chestInv, InventoryMenu srcInv, int srcSlot, Item item)
        {
            if (grab == null || srcInv == null || item == null)
                return;
            if (item.Stack <= 0)
                item.Stack = 1;
            if (srcInv == playerInv && !CanDepositIntoGrabMenu(grab))
            {
                // Read-only Fishing Treasure Chest / Mine Reward Chest: never push player items into treasure chest!
                try { Game1.playSound("cancel"); } catch { }
                return;
            }
            InventoryMenu dstInv = (srcInv == playerInv) ? chestInv : playerInv;
            int stackNow = Math.Max(1, item.Stack);
            int qty = TapMode == ChestTapMode.SingleOne
                ? 1
                : (TapMode == ChestTapMode.HalfStack ? Math.Max(1, (stackNow + 1) / 2) : stackNow);
            TransferQuantityBetweenInventories(grab, srcInv, srcSlot, dstInv, qty);
        }

        private static bool IsPointInInventoryPanel(InventoryMenu inv, Point uiPt, int pad)
        {
            if (inv?.inventory == null || inv.inventory.Count == 0)
                return false;
            Rectangle bounds = Rectangle.Empty;
            int count = IsPlayerBackpack(inv) ? GetUnlockedCapacity(inv) : Math.Min(inv.capacity, inv.inventory.Count);
            for (int i = 0; i < count; i++)
            {
                var cc = inv.inventory[i];
                if (cc == null || cc.bounds.Width <= 0 || cc.bounds.Height <= 0) continue;
                bounds = bounds.IsEmpty ? cc.bounds : Rectangle.Union(bounds, cc.bounds);
            }
            if (bounds.IsEmpty)
                return false;
            return new Rectangle(bounds.X - pad, bounds.Y - pad, bounds.Width + pad * 2, bounds.Height + pad * 2).Contains(uiPt);
        }

        private static bool IsSpecialRewardGrabItem(Item item)
        {
            if (item == null) return false;
            if (item.IsRecipe) return true;
            string qid = item.QualifiedItemId;
            return qid == "(O)326" || qid == "(O)434"; // Dwarvish Translation Guide / Stardrop
        }

        private static void SpawnTransferVisual(ItemGrabMenu grab, InventoryMenu srcInv, int srcSlot, InventoryMenu dstInv, int dstSlot, Item movedPreview)
        {
            try
            {
                if (grab?._transferredItemSprites != null && movedPreview != null &&
                    srcInv?.inventory != null && srcSlot >= 0 && srcSlot < srcInv.inventory.Count)
                {
                    Rectangle r = srcInv.inventory[srcSlot].bounds;
                    grab._transferredItemSprites.Add(new ItemGrabMenu.TransferredItemSprite(movedPreview.getOne(), r.X, r.Y));
                }
                if (dstInv != null && dstSlot >= 0)
                    dstInv.ShakeItem(dstSlot);
            }
            catch { }
        }

        private void TransferQuantityBetweenInventories(ItemGrabMenu grab, InventoryMenu srcInv, int srcSlot, InventoryMenu dstInv, int qty)
        {
            Item srcItem = GetItemAt(srcInv, srcSlot);
            if (srcItem == null) return;
            // Tools (Pickaxe, Axe, Hoe, WateringCan, Scythe, FishingRod) frequently carry Stack == 0 in Stardew Valley
            // (matching vanilla Chest.grabItemFromInventory's `if (item.Stack == 0) item.Stack = 1;`).
            if (srcItem.Stack <= 0)
                srcItem.Stack = 1;
            if (qty <= 0) return;

            bool fromPlayerToChest = (grab != null && srcInv == grab.inventory);

            // Always enforce source inventory highlight filter (prevents shipping tools/unshippable items & honors Special Order dropboxes!)
            if (fromPlayerToChest && srcInv.highlightMethod != null && !srcInv.highlightMethod(srcItem))
            {
                try { Game1.playSound("cancel"); } catch { }
                return;
            }

            // Special reward items (Recipes, Stardrop, Dwarvish Guide) in reward chests MUST go through native ItemGrabMenu.receiveLeftClick!
            if (!fromPlayerToChest && grab != null && IsSpecialRewardGrabItem(srcItem) &&
                srcInv.inventory != null && srcSlot >= 0 && srcSlot < srcInv.inventory.Count)
            {
                Point c = srcInv.inventory[srcSlot].bounds.Center;
                try { grab.receiveLeftClick(c.X, c.Y, true); } catch { }
                if (grab.heldItem != null && Game1.player != null)
                {
                    Item rem = Game1.player.addItemToInventory(grab.heldItem);
                    grab.heldItem = rem;
                }
                return;
            }

            int curStack = Math.Max(1, srcItem.Stack);

            if (fromPlayerToChest && grab != null && (grab.shippingBin || !grab.showReceivingMenu) && grab.behaviorFunction != null)
            {
                int count = Math.Min(qty, curStack);
                Item toSend = (count >= curStack) ? srcItem : srcItem.getOne();
                toSend.Stack = count;
                if (count >= curStack) SetItemAt(srcInv, srcSlot, null);
                else srcItem.Stack = curStack - count;

                try { grab.behaviorFunction(toSend, Game1.player); } catch { }
                SpawnTransferVisual(grab, srcInv, srcSlot, null, -1, toSend);
                try { Game1.playSound(grab.shippingBin ? "Ship" : "dwop"); } catch { }
                return;
            }

            if (dstInv == null) return;

            if (dstInv.highlightMethod != null && !dstInv.highlightMethod(srcItem))
            {
                try { Game1.playSound("cancel"); } catch { }
                return;
            }

            int toMove = Math.Min(qty, curStack);
            bool detachedFullStack = false;
            Item moving;
            if (toMove >= curStack)
            {
                // Detach from srcInv BEFORE inserting into dstInv so Netcode never logs "Changing net field parent" + StackTrace on 0% JIT!
                SetItemAt(srcInv, srcSlot, null);
                try { srcItem.onDetachedFromParent(); } catch { }
                moving = srcItem;
                detachedFullStack = true;
            }
            else
            {
                moving = srcItem.getOne();
            }
            moving.Stack = toMove;

            int leftover = AddItemToInventoryMenu(dstInv, moving, out int dstSlotIdx);
            int actuallyMoved = toMove - leftover;

            if (actuallyMoved > 0)
            {
                int originalStack = curStack;
                if (detachedFullStack)
                {
                    if (leftover > 0)
                    {
                        Item remCopy = moving.getOne();
                        remCopy.Stack = leftover;
                        SetItemAt(srcInv, srcSlot, remCopy);
                    }
                }
                else
                {
                    if (actuallyMoved >= originalStack) SetItemAt(srcInv, srcSlot, null);
                    else srcItem.Stack = originalStack - actuallyMoved;
                }

                // Only invoke non-Chest behaviorOnItemGrab (Fishing Treasure / Mine Reward / Quest Reward / Mod callbacks).
                // NEVER call Chest.grabItemFromChest here — it calls clearNulls() + Chest.ShowMenu() which destroys/recreates the menu & shifts every slot!
                if (!fromPlayerToChest && grab?.behaviorOnItemGrab != null && actuallyMoved >= originalStack)
                {
                    bool isVanillaChestGrab = grab.behaviorOnItemGrab.Method?.DeclaringType == typeof(StardewValley.Objects.Chest);
                    if (!isVanillaChestGrab)
                    {
                        try { grab.behaviorOnItemGrab(moving, Game1.player); } catch { }
                    }
                }

                SpawnTransferVisual(grab, srcInv, srcSlot, dstInv, dstSlotIdx, moving);
                try { Game1.playSound("dwop"); } catch { }
            }
            else
            {
                try { Game1.playSound("cancel"); } catch { }
            }
        }

        private static int AddItemToInventoryMenu(InventoryMenu inv, Item item, out int placedSlot)
        {
            placedSlot = -1;
            if (inv == null || item == null) return item?.Stack ?? 0;

            if (IsPlayerBackpack(inv))
            {
                int capP = GetUnlockedCapacity(inv);
                // Find target slot for shake animation before/after adding
                int hintSlot = -1;
                if (Game1.player?.Items != null)
                {
                    int cnt = Math.Min(capP, Game1.player.Items.Count);
                    for (int i = 0; i < cnt; i++)
                    {
                        Item ex = Game1.player.Items[i];
                        if (ex != null && ex.canStackWith(item) && ex.Stack < ex.maximumStackSize())
                        {
                            hintSlot = i;
                            break;
                        }
                    }
                    if (hintSlot < 0)
                    {
                        for (int i = 0; i < cnt; i++)
                        {
                            if (Game1.player.Items[i] == null) { hintSlot = i; break; }
                        }
                    }
                }
                Item rem = Game1.player.addItemToInventory(item);
                placedSlot = hintSlot;
                return rem != null ? rem.Stack : 0;
            }

            int cap = Math.Min(inv.capacity, inv.inventory != null ? inv.inventory.Count : inv.capacity);
            int curCount = inv.actualInventory.Count;
            int scanMax = Math.Min(cap, curCount);

            // 1. Stack onto existing matching stacks first (identical to Stardew Mobile & FillOutStacks!)
            for (int i = 0; i < scanMax; i++)
            {
                Item ex = inv.actualInventory[i];
                if (ex != null && ex.canStackWith(item))
                {
                    int before = item.Stack;
                    int rem = ex.addToStack(item);
                    item.Stack = rem;
                    if (rem < before && placedSlot < 0)
                        placedSlot = i;
                    if (rem <= 0)
                        return 0;
                }
            }

            // 2. Fill first existing null hole inside actualInventory
            for (int i = 0; i < scanMax; i++)
            {
                if (inv.actualInventory[i] == null)
                {
                    try { item.onDetachedFromParent(); } catch { }
                    inv.actualInventory[i] = item;
                    placedSlot = i;
                    return 0;
                }
            }

            // 3. Append cleanly if chest still has capacity (avoids padding 70 empty nulls!)
            if (curCount < cap)
            {
                try { item.onDetachedFromParent(); } catch { }
                inv.actualInventory.Add(item);
                placedSlot = curCount;
                return 0;
            }

            return item.Stack;
        }

        private static bool IsPlayerBackpack(InventoryMenu inv)
        {
            if (inv == null) return false;
            if (inv.playerInventory) return true;
            return Game1.player != null && ReferenceEquals(inv.actualInventory, Game1.player.Items);
        }

        private static int GetUnlockedCapacity(InventoryMenu inv)
        {
            if (inv == null) return 0;
            int cap = inv.capacity;
            if (inv.inventory != null)
                cap = Math.Min(cap, inv.inventory.Count);
            if (IsPlayerBackpack(inv) && Game1.player != null)
                cap = Math.Min(cap, Math.Max(12, Game1.player.MaxItems));
            return Math.Max(0, cap);
        }

        private static bool IsSlotUnlocked(InventoryMenu inv, int slot)
        {
            return inv != null && slot >= 0 && slot < GetUnlockedCapacity(inv);
        }

        private static bool IsPointInLockedBackpackSlot(InventoryMenu inv, Point uiPt)
        {
            if (inv?.inventory == null || !IsPlayerBackpack(inv)) return false;
            int unlocked = GetUnlockedCapacity(inv);
            int total = Math.Min(inv.capacity, inv.inventory.Count);
            for (int i = unlocked; i < total; i++)
            {
                if (inv.inventory[i] != null && inv.inventory[i].containsPoint(uiPt.X, uiPt.Y))
                    return true;
            }
            return false;
        }

        private static int FindSlotAt(InventoryMenu inv, Point uiPt, bool allowStrandedOccupied = false)
        {
            if (inv?.inventory == null) return -1;
            int unlocked = GetUnlockedCapacity(inv);
            for (int i = 0; i < unlocked; i++)
            {
                if (inv.inventory[i] != null && inv.inventory[i].containsPoint(uiPt.X, uiPt.Y))
                    return i;
            }
            // If an item was previously placed in a locked row before this fix, allow lifting it OUT (never placing IN!)
            if (allowStrandedOccupied && inv.actualInventory != null)
            {
                int total = Math.Min(inv.capacity, Math.Min(inv.inventory.Count, inv.actualInventory.Count));
                for (int i = unlocked; i < total; i++)
                {
                    if (inv.actualInventory[i] != null && inv.inventory[i] != null && inv.inventory[i].containsPoint(uiPt.X, uiPt.Y))
                        return i;
                }
            }
            return -1;
        }

        private static int FindFirstEmptySlot(InventoryMenu inv)
        {
            if (inv?.actualInventory == null) return -1;
            int cap = GetUnlockedCapacity(inv);
            EnsureInventoryListSize(inv, cap);
            for (int i = 0; i < cap; i++)
            {
                if (inv.actualInventory[i] == null) return i;
            }
            return -1;
        }

        private static Item GetItemAt(InventoryMenu inv, int slot)
        {
            if (inv?.actualInventory == null || slot < 0 || slot >= inv.actualInventory.Count)
                return null;
            return inv.actualInventory[slot];
        }

        private static void SetItemAt(InventoryMenu inv, int slot, Item item)
        {
            if (inv?.actualInventory == null || slot < 0) return;
            if (item != null && !IsSlotUnlocked(inv, slot))
                return;
            if (slot >= inv.actualInventory.Count)
            {
                if (item == null) return;
                EnsureInventoryListSize(inv, Math.Min(slot + 1, GetUnlockedCapacity(inv)));
                if (slot >= inv.actualInventory.Count) return;
            }
            inv.actualInventory[slot] = item;
        }

        private static void EnsureInventoryListSize(InventoryMenu inv, int needed)
        {
            int maxAllowed = IsPlayerBackpack(inv) ? GetUnlockedCapacity(inv) : needed;
            int target = Math.Min(needed, maxAllowed);
            while (inv.actualInventory.Count < target)
                inv.actualInventory.Add(null);
        }

        // =========================================================================
        // POPUP TOUCH & LAYOUT
        // =========================================================================
        private void UpdatePopupTouches(TouchCollection touches, Func<Vector2, Vector2> rawToVp, double nowSec)
        {
            if (touches.Count == 0)
            {
                _popSliderTouchId = -1;
                _popHoldTouchId = -1;
                _popHoldDelta = 0;
                return;
            }

            // 1. Track active slider finger across ALL touches (immune to stray palm/2nd finger!)
            if (_popSliderTouchId >= 0)
            {
                if (TryFindTouchById(touches, _popSliderTouchId, out TouchLocation stl))
                {
                    if (stl.State == TouchLocationState.Pressed || stl.State == TouchLocationState.Moved)
                    {
                        SetQtyFromSliderX(rawToVp(stl.Position).X, nowSec);
                        return;
                    }
                }
                _popSliderTouchId = -1;
                return;
            }

            // 2. Track active hold-to-repeat +/- stepper finger across ALL touches
            if (_popHoldTouchId >= 0 && _popHoldDelta != 0)
            {
                if (TryFindTouchById(touches, _popHoldTouchId, out TouchLocation htl))
                {
                    if (htl.State == TouchLocationState.Pressed || htl.State == TouchLocationState.Moved)
                    {
                        Vector2 hvp = rawToVp(htl.Position);
                        Point hpt = new Point((int)hvp.X, (int)hvp.Y);
                        Rectangle holdR = _popHoldDelta == -10 ? _popBtnM10 :
                                          _popHoldDelta == -1  ? _popBtnM1  :
                                          _popHoldDelta == 1   ? _popBtnP1  : _popBtnP10;
                        Rectangle forgivenR = new Rectangle(holdR.X - 16, holdR.Y - 16, holdR.Width + 32, holdR.Height + 32);
                        if (forgivenR.Contains(hpt) && _popupMaxQty > _popupMinQty)
                        {
                            double held = nowSec - _popHoldStartSec;
                            double interval = held >= 1.15 ? 0.045 : 0.105;
                            if (held >= 0.30 && (nowSec - _popHoldLastStepSec) >= interval)
                            {
                                _popHoldLastStepSec = nowSec;
                                int next = Math.Clamp(_popupQty + _popHoldDelta, _popupMinQty, _popupMaxQty);
                                if (next != _popupQty)
                                {
                                    _popupQty = next;
                                    TryClickSound();
                                }
                            }
                        }
                        return;
                    }
                }
                _popHoldTouchId = -1;
                _popHoldDelta = 0;
                return;
            }

            // 3. Process new Pressed touch cleanly
            if (!TryPickPrimaryTouch(touches, -1, out TouchLocation tl))
                return;

            Vector2 vp = rawToVp(tl.Position);
            Point pt = new Point((int)vp.X, (int)vp.Y);

            var sliderHit = new Rectangle(_popSliderTrack.X - 28, _popSliderTrack.Y - 34, _popSliderTrack.Width + 56, _popSliderTrack.Height + 68);
            if (_popupMaxQty > _popupMinQty && sliderHit.Contains(pt))
            {
                _popSliderTouchId = tl.Id;
                SetQtyFromSliderX(vp.X, nowSec);
                return;
            }

            if (_popupMaxQty > _popupMinQty)
            {
                int stepDelta = 0;
                if (_popBtnM10.Contains(pt)) stepDelta = -10;
                else if (_popBtnM1.Contains(pt)) stepDelta = -1;
                else if (_popBtnP1.Contains(pt)) stepDelta = 1;
                else if (_popBtnP10.Contains(pt)) stepDelta = 10;

                if (stepDelta != 0)
                {
                    _popupQty = Math.Clamp(_popupQty + stepDelta, _popupMinQty, _popupMaxQty);
                    _popHoldTouchId = tl.Id;
                    _popHoldDelta = stepDelta;
                    _popHoldStartSec = nowSec;
                    _popHoldLastStepSec = nowSec;
                    TryClickSound();
                    return;
                }
                if (_popBtnMax.Contains(pt))
                {
                    _popupQty = (_popupKind == PopupKind.BagSplit) ? Math.Clamp((_popupMaxQty + 1) / 2, _popupMinQty, _popupMaxQty) : _popupMaxQty;
                    TryClickSound();
                    return;
                }
            }

            if (_popBtnConfirm.Contains(pt))
            {
                _popConsumeTouchId = tl.Id;
                ExecutePopupConfirm();
                return;
            }

            if (_popBtnCancel.Contains(pt) || _popCloseX.Contains(pt) || !_popPanel.Contains(pt))
            {
                _popConsumeTouchId = tl.Id;
                ClosePopup();
                try { Game1.playSound("cancel"); } catch { }
            }
        }

        private float GetSliderExponent()
        {
            int span = _popupMaxQty - _popupMinQty;
            if (span > 200) return 1.70f;
            if (span > 80)  return 1.45f;
            return 1.0f;
        }

        private float QtyToSliderFrac(int qty)
        {
            int span = Math.Max(1, _popupMaxQty - _popupMinQty);
            float norm = Math.Clamp((float)(qty - _popupMinQty) / span, 0f, 1f);
            float exp = GetSliderExponent();
            return exp > 1.01f ? MathF.Pow(norm, 1f / exp) : norm;
        }

        private int SliderFracToQty(float frac)
        {
            frac = Math.Clamp(frac, 0f, 1f);
            int span = Math.Max(0, _popupMaxQty - _popupMinQty);
            if (span <= 0) return _popupMinQty;
            float exp = GetSliderExponent();
            float norm = exp > 1.01f ? MathF.Pow(frac, exp) : frac;
            return Math.Clamp(_popupMinQty + (int)Math.Round(norm * span), _popupMinQty, _popupMaxQty);
        }

        private void SetQtyFromSliderX(float vpX, double nowSec)
        {
            if (_popSliderTrack.Width <= 4 || _popupMaxQty <= _popupMinQty) return;
            float minX = _popSliderTrack.X + _popKnobW * 0.5f;
            float maxX = _popSliderTrack.Right - _popKnobW * 0.5f;
            float frac = Math.Clamp((vpX - minX) / Math.Max(1f, maxX - minX), 0f, 1f);
            int next = SliderFracToQty(frac);
            if (next != _popupQty)
            {
                _popupQty = next;
                if ((nowSec - _popSliderLastTickSec) >= 0.065)
                {
                    _popSliderLastTickSec = nowSec;
                    TryClickSound();
                }
            }
        }

        private static void TryClickSound()
        {
            try { Game1.playSound("smallSelect"); } catch { }
        }

        private void ComputePopupLayout(int vpW, int vpH)
        {
            bool isCraft = _popupKind == PopupKind.Craft;
            bool isShop = _popupKind == PopupKind.ShopBuy || _popupKind == PopupKind.ShopSell;
            bool hasSlider = _popupMaxQty > _popupMinQty;

            float wFrac = isCraft ? 0.58f : (isShop ? 0.54f : 0.48f);
            float hFrac = isCraft
                ? (hasSlider ? 0.78f : 0.62f)
                : (isShop ? (hasSlider ? 0.68f : 0.48f) : (hasSlider ? 0.58f : 0.40f));

            int pw = (int)Math.Clamp(vpW * wFrac, 380f, vpW * 0.90f);
            int ph = (int)Math.Clamp(vpH * hFrac, 260f, vpH * 0.90f);
            int px = (vpW - pw) / 2;
            int py = (vpH - ph) / 2;
            _popPanel = new Rectangle(px, py, pw, ph);

            int closeSz = Math.Max(36, Math.Min(56, vpH / 16));
            _popCloseX = new Rectangle(_popPanel.Right - closeSz / 2 - 4, _popPanel.Y - closeSz / 3 + 4, closeSz, closeSz);

            int pad = Math.Max(28, pw / 19);
            int actH = Math.Max(48, Math.Min(74, ph / 7));
            int actY = py + ph - pad - actH;
            int qGap = Math.Max(8, pw / 60);
            int cancelW = (int)((pw - pad * 2 - qGap) * 0.32f);
            int confirmW = (pw - pad * 2 - qGap) - cancelW;
            _popBtnCancel  = new Rectangle(px + pad, actY, cancelW, actH);
            _popBtnConfirm = new Rectangle(px + pad + cancelW + qGap, actY, confirmW, actH);

            int qH = Math.Max(40, Math.Min(60, ph / 9));
            int qY = actY - Math.Max(14, ph / 32) - qH;
            int qW = (pw - pad * 2 - qGap * 4) / 5;
            _popBtnM10 = new Rectangle(px + pad, qY, qW, qH);
            _popBtnM1  = new Rectangle(px + pad + (qW + qGap) * 1, qY, qW, qH);
            _popBtnP1  = new Rectangle(px + pad + (qW + qGap) * 2, qY, qW, qH);
            _popBtnP10 = new Rectangle(px + pad + (qW + qGap) * 3, qY, qW, qH);
            _popBtnMax = new Rectangle(px + pad + (qW + qGap) * 4, qY, qW, qH);

            int trackH = Math.Max(24, Math.Min(38, ph / 18));
            int sliderY = qY - Math.Max(14, ph / 34) - trackH;
            _popSliderTrack = new Rectangle(px + pad, sliderY, pw - pad * 2, trackH);
            _popKnobW = Math.Max(42, (int)(_popSliderTrack.Height * 1.75f));
        }

        // =========================================================================
        // STARDEW VALLEY NATIVE PIXEL ART RENDERING
        // =========================================================================
        public void Draw(
            SpriteBatch sb,
            Texture2D pixel,
            Texture2D circle,
            PadBridge bridge,
            IClickableMenu activeMenu,
            Func<Point, Vector2> uiToVp,
            Func<Vector2, Point> vpToUi,
            int vpW, int vpH,
            bool showFixedTooltip = true)
        {
            if (sb == null || pixel == null) return;

            // 0. Draw golden pixel highlight on Tap-Selected Backpack slot + DROP button + Fixed Non-Obstructive Item Tooltip
            if (_selectedBagSlot >= 0 && _selectedBagInv != null && activeMenu is GameMenu gm && gm.GetCurrentPage() is InventoryPage invP)
            {
                if (_selectedBagInv.inventory != null && _selectedBagSlot < _selectedBagInv.inventory.Count)
                {
                    Rectangle selVp = UiRectToVp(_selectedBagInv.inventory[_selectedBagSlot].bounds, uiToVp);
                    sb.Draw(pixel, selVp, new Color(255, 215, 70) * 0.22f);
                    DrawBorder(sb, pixel, selVp, Math.Max(3, vpH / 260), new Color(255, 200, 40));

                    Item selItem = GetItemAt(_selectedBagInv, _selectedBagSlot);
                    if (selItem != null)
                    {
                        if (selItem.canBeDropped() && invP.trashCan != null)
                        {
                            Rectangle dropVp = UiRectToVp(ComputeDropBtnUiRect(invP.trashCan), uiToVp);
                            PixelUi.DrawPixelPill(sb, pixel, bridge, dropVp, "DROP", PixelRole.Tool, false, vpH, Math.Max(1, vpH / 300), 0.94f);
                        }
                        if (showFixedTooltip && !IsPopupOpen && !IsDraggingItem)
                        {
                            DrawFixedItemTooltipBanner(sb, pixel, selItem, vpW, vpH);
                        }
                    }
                }
            }

            // 1. Draw Drag-and-Drop item smoothly under finger + hovered target slot highlight (hover cached per >=2px move!)
            if (IsDraggingItem && activeMenu != null)
            {
                if (!_dragHoverCacheValid || Vector2.DistanceSquared(_touchCurVp, _dragHoverCachedVp) >= 4f)
                {
                    _dragHoverCachedVp = _touchCurVp;
                    _dragHoverCacheValid = true;
                    _dragHoverIsTrash = false;
                    _dragHoverTrashUi = Rectangle.Empty;
                    _dragHoverSlotUi = Rectangle.Empty;
                    _dragHoverAreaUi = Rectangle.Empty;

                    Point uiHover = vpToUi(_touchCurVp);
                    ItemGrabMenu grab = activeMenu as ItemGrabMenu;
                    InventoryPage invPage = (activeMenu as GameMenu)?.GetCurrentPage() as InventoryPage;

                    ClickableTextureComponent trash = grab?.trashCan ?? invPage?.trashCan;
                    if (trash != null && trash.containsPoint(uiHover.X, uiHover.Y))
                    {
                        _dragHoverIsTrash = true;
                        _dragHoverTrashUi = trash.bounds;
                    }
                    else
                    {
                        _dragHoverSlotUi = FindHoveredSlotRect(grab?.ItemsToGrabMenu, grab?.inventory ?? invPage?.inventory, uiHover);
                        if (_dragHoverSlotUi.IsEmpty && grab != null)
                        {
                            InventoryMenu targetDropInv = null;
                            if (_dragSrcInv == grab.inventory && (grab.reverseGrab || grab.shippingBin) && grab.ItemsToGrabMenu != null && IsPointInInventoryPanel(grab.ItemsToGrabMenu, uiHover, 26))
                                targetDropInv = grab.ItemsToGrabMenu;
                            else if (_dragSrcInv == grab.ItemsToGrabMenu && grab.inventory != null && IsPointInInventoryPanel(grab.inventory, uiHover, 26))
                                targetDropInv = grab.inventory;

                            if (targetDropInv != null && TryGetInventoryPanelRect(targetDropInv, out Rectangle areaUi))
                                _dragHoverAreaUi = areaUi;
                        }
                    }
                }

                if (_dragHoverIsTrash && !_dragHoverTrashUi.IsEmpty)
                {
                    Rectangle trVp = UiRectToVp(_dragHoverTrashUi, uiToVp);
                    sb.Draw(pixel, trVp, new Color(220, 50, 40) * 0.32f);
                    DrawBorder(sb, pixel, trVp, Math.Max(3, vpH / 260), new Color(255, 80, 65));
                }
                else if (!_dragHoverSlotUi.IsEmpty)
                {
                    Rectangle hvVp = UiRectToVp(_dragHoverSlotUi, uiToVp);
                    sb.Draw(pixel, hvVp, new Color(90, 215, 90) * 0.24f);
                    DrawBorder(sb, pixel, hvVp, Math.Max(3, vpH / 260), new Color(90, 225, 90));
                }
                else if (!_dragHoverAreaUi.IsEmpty)
                {
                    Rectangle areaVp = UiRectToVp(_dragHoverAreaUi, uiToVp);
                    sb.Draw(pixel, areaVp, new Color(90, 215, 90) * 0.12f);
                    DrawBorder(sb, pixel, areaVp, Math.Max(3, vpH / 240), new Color(110, 235, 110));
                }

                // Draw Stardew pixel slot box + item icon right under finger (zero SpriteBatch End/Begin GPU flush!)
                float iconScale = Math.Clamp(Math.Min(vpW, vpH) / 720f, 1.0f, 2.2f);
                int slotSize = (int)(68f * iconScale);
                var floatBox = new Rectangle((int)(_touchCurVp.X - slotSize * 0.5f), (int)(_touchCurVp.Y - slotSize * 0.5f), slotSize, slotSize);
                try
                {
                    sb.Draw(Game1.menuTexture, floatBox, Game1.getSourceRectForStandardTileSheet(Game1.menuTexture, 10), Color.White * 0.92f);
                }
                catch { }
                DrawItemCenteredInSlot(sb, _dragItem, floatBox, StackDrawType.Draw, 1f);
            }
            else
            {
                _dragHoverCacheValid = false;
            }

            // 2. Draw authentic Stardew Valley native themed Buy / Sell / Craft / Split Popup!
            if (IsPopupOpen)
            {
                ComputePopupLayout(vpW, vpH);
                DrawStardewPixelPopup(sb, pixel, vpW, vpH);
            }
        }

        private static void DrawItemCenteredInSlot(SpriteBatch sb, ISalable salable, Rectangle slotBox, StackDrawType stackDraw, float alpha)
        {
            if (sb == null || salable == null || slotBox.Width <= 0 || slotBox.Height <= 0)
                return;

            // Zero-flush direct SpriteBatch draw: Item.drawInMenu centers its sprite at location + (32, 32)!
            // Eliminates 3x SpriteBatch.End()/Begin() GPU flushes per frame during Backpack/Chest drag-and-drop!
            Vector2 iconPos = new Vector2(slotBox.Center.X - 32f, slotBox.Center.Y - 32f);
            float scale = Math.Clamp((slotBox.Width * 0.86f) / 64f, 0.45f, 2.2f);
            try { salable.drawInMenu(sb, iconPos, scale, alpha, 0.90f, stackDraw, Color.White, drawShadow: true); } catch { }
        }

        private void DrawStardewPixelPopup(SpriteBatch sb, Texture2D pixel, int vpW, int vpH)
        {
            // Warm dark vignette behind native Stardew dialog box
            sb.Draw(pixel, new Rectangle(0, 0, vpW, vpH), Color.Black * 0.54f);

            // Read live ShopMenu VisualTheme when in a shop so modded UI themes (Cat Valley UI, custom shop themes) skin the popup 100% natively!
            ShopMenu.ShopCachedTheme shopTheme = (_popupKind == PopupKind.ShopBuy || _popupKind == PopupKind.ShopSell)
                ? (_popupOwnerMenu as ShopMenu)?.VisualTheme
                : null;
            Color primaryInk = shopTheme?.ItemRowTextColor ?? Game1.textColor;
            Color subInk = new Color(
                Math.Min(255, primaryInk.R + 18),
                Math.Min(255, primaryInk.G + 14),
                Math.Min(255, primaryInk.B + 10));

            // 1. Native Stardew 9-slice window box (Shop VisualTheme -> Game1.menuTexture)
            bool drewBox = false;
            try
            {
                Texture2D winTex = shopTheme?.WindowBorderTexture ?? Game1.menuTexture;
                Rectangle winSrc = (shopTheme?.WindowBorderTexture != null && shopTheme.WindowBorderSourceRect.Width > 0)
                    ? shopTheme.WindowBorderSourceRect
                    : MobileBoxSrc;
                if (winTex != null)
                {
                    IClickableMenu.drawTextureBox(sb, winTex, winSrc,
                        _popPanel.X, _popPanel.Y, _popPanel.Width, _popPanel.Height, Color.White, 1f, drawShadow: true);
                    drewBox = true;
                }
            }
            catch { }
            if (!drewBox)
            {
                PixelUi.DrawNativeDialogBox(sb, pixel, _popPanel, 1f, drawShadow: true);
            }

            // 2. Native Stardew close 'X' button on top-right corner!
            PixelUi.DrawNativeCloseX(sb, _popCloseX, 1f);

            int pad = Math.Max(28, _popPanel.Width / 19);
            float fontScale = Math.Clamp(vpH / 790f, 0.78f, 1.65f);
            float iconScale = Math.Clamp(vpH / 820f, 0.90f, 1.65f);
            int slotPx = (int)(68f * iconScale);

            // 3. Native Stardew item slot frame (Shop VisualTheme icon bg -> Game1.menuTexture tile 10) + dead-centered item sprite
            var slotBox = new Rectangle(_popPanel.X + pad, _popPanel.Y + pad, slotPx, slotPx);
            try
            {
                if (shopTheme?.ItemIconBackgroundTexture != null && shopTheme.ItemIconBackgroundSourceRect.Width > 0)
                    sb.Draw(shopTheme.ItemIconBackgroundTexture, slotBox, shopTheme.ItemIconBackgroundSourceRect, Color.White);
                else if (Game1.menuTexture != null)
                    sb.Draw(Game1.menuTexture, slotBox, Game1.getSourceRectForStandardTileSheet(Game1.menuTexture, 10), Color.White);
            }
            catch { }

            if (_popupSaleItem != null)
            {
                DrawItemCenteredInSlot(sb, _popupSaleItem, slotBox, StackDrawType.Hide, 1f);
            }

            // Header title & subtitle using live theme / Game1.textColor
            float textX = slotBox.Right + Math.Max(14, pad / 2);
            float textY = _popPanel.Y + pad;

            string title = _popupKind == PopupKind.Craft && _popupCraftRecipe != null
                ? (_popupCraftRecipe.DisplayName ?? _popupCraftRecipe.name)
                : (_popupSaleItem?.DisplayName ?? _popupItem?.DisplayName ?? "Vật phẩm");
            if (_popupKind == PopupKind.Craft && _popupCraftRecipe != null && _popupCraftRecipe.numberProducedPerCraft > 1)
                title += $" (×{_popupCraftRecipe.numberProducedPerCraft})";

            DrawStardewText(sb, title, new Vector2(textX, textY), primaryInk, fontScale * 1.06f);
            float lineH = Math.Max(26f, vpH / 27f);
            float curY = textY + lineH * 1.08f;

            if (_popupKind == PopupKind.ShopBuy)
            {
                bool hasTradeCost = !string.IsNullOrEmpty(_popupTradeItemId) && _popupTradeCount > 0;
                bool hasMoneyCost = _popupUnitPrice > 0;
                if (hasMoneyCost || !hasTradeCost)
                {
                    string unitTag = _popupCurrency == 1 ? "★" : (_popupCurrency == 2 ? "QC" : (_popupCurrency == 4 ? "Qi" : "g"));
                    string priceSub = _popupUnitPrice <= 0
                        ? $"Miễn phí · SL: {_popupQty * Math.Max(1, _popupBundlePerPurchase)}"
                        : $"Giá: {_popupUnitPrice:N0}{unitTag} × {_popupQty} = {(_popupUnitPrice * (long)_popupQty):N0}{unitTag}";
                    if (_popupStock != ShopMenu.infiniteStock && _popupStock > 0)
                        priceSub += $"  (Còn {_popupStock})";
                    DrawStardewText(sb, priceSub, new Vector2(textX, curY), subInk, fontScale * 0.88f);
                    curY += lineH;

                    if (hasMoneyCost && !hasTradeCost)
                    {
                        int have = ShopMenu.getPlayerCurrencyAmount(Game1.player, _popupCurrency);
                        int coinSz = Math.Max(18, (int)(22f * fontScale));
                        Rectangle coinSrc = _popupCurrency == 1
                            ? new Rectangle(338, 400, 8, 8)
                            : new Rectangle(193, 373, 9, 10);
                        try { sb.Draw(Game1.mouseCursors, new Rectangle((int)textX, (int)curY + 2, coinSz, coinSz), coinSrc, Color.White); } catch { }
                        Color haveCol = _popupCanAfford ? new Color(36, 118, 42) : new Color(180, 32, 24);
                        DrawStardewText(sb, $"Hiện có: {have:N0}{unitTag}", new Vector2(textX + coinSz + 8, curY), haveCol, fontScale * 0.84f);
                        curY += lineH;
                    }
                }
                if (hasTradeCost)
                {
                    int trSz = Math.Max(22, (int)(26f * fontScale));
                    string trName = "vật phẩm";
                    try
                    {
                        var td = ItemRegistry.GetDataOrErrorItem(_popupTradeItemId);
                        if (td != null)
                        {
                            trName = td.DisplayName ?? trName;
                            sb.Draw(td.GetTexture(), new Rectangle((int)textX, (int)curY - 2, trSz, trSz), td.GetSourceRect(), Color.White);
                        }
                    }
                    catch { }
                    int haveTrade = GetPlayerTradeItemCount(Game1.player, _popupTradeItemId);
                    int needTrade = _popupTradeCount * _popupQty;
                    Color trCol = haveTrade >= needTrade ? new Color(36, 118, 42) : new Color(180, 32, 24);
                    string stockSuffix = (!hasMoneyCost && _popupStock != ShopMenu.infiniteStock && _popupStock > 0) ? $"  (Còn {_popupStock})" : "";
                    DrawStardewText(sb, $"{trName}: {haveTrade}/{needTrade}{stockSuffix}", new Vector2(textX + trSz + 8, curY), trCol, fontScale * 0.86f);
                    curY += lineH;
                }
            }
            else if (_popupKind == PopupKind.ShopSell)
            {
                DrawStardewText(sb, $"Bán: {_popupQty}/{_popupMaxQty} · Thu: {(_popupUnitPrice * (long)_popupQty):N0}g", new Vector2(textX, curY), subInk, fontScale * 0.88f);
                curY += lineH;
            }
            else if (_popupKind == PopupKind.Craft && _popupCraftRecipe != null)
            {
                string craftMeta = _popupCraftRecipe.isCookingRecipe
                    ? $"Đã nấu: {_popupCraftRecipe.timesCrafted} lần · Có thể nấu: {(_popupCanAfford ? _popupMaxQty : 0)}"
                    : $"Đã chế: {_popupCraftRecipe.timesCrafted} lần · Có thể chế: {(_popupCanAfford ? _popupMaxQty : 0)}";
                Color metaCol = _popupCanAfford ? new Color(36, 118, 42) : new Color(176, 36, 26);
                DrawStardewText(sb, craftMeta, new Vector2(textX, curY), metaCol, fontScale * 0.84f);
                curY += lineH;
            }
            else
            {
                DrawStardewText(sb, $"Số lượng: {_popupQty} / {_popupMaxQty}", new Vector2(textX, curY), subInk, fontScale * 0.88f);
                curY += lineH;
            }

            // Energy / Health icons for edible items (authentic Stardew icons!)
            if (_popupItem is StardewValley.Object edObj && edObj.Edibility > 0)
            {
                int en = edObj.staminaRecoveredOnConsumption();
                int hp = edObj.healthRecoveredOnConsumption();
                int statSz = Math.Max(18, (int)(22f * fontScale));
                float sx = textX;
                try { sb.Draw(Game1.mouseCursors, new Rectangle((int)sx, (int)curY + 2, statSz, statSz), new Rectangle(0, 428, 10, 10), Color.White); } catch { }
                string enTxt = $"+{en}";
                DrawStardewText(sb, enTxt, new Vector2(sx + statSz + 5, curY), new Color(34, 122, 44), fontScale * 0.82f);
                sx += statSz + 5 + MeasureWidth(enTxt, fontScale * 0.82f) + 18f;
                try { sb.Draw(Game1.mouseCursors, new Rectangle((int)sx, (int)curY + 2, statSz, statSz), new Rectangle(0, 438, 10, 10), Color.White); } catch { }
                DrawStardewText(sb, $"+{hp}", new Vector2(sx + statSz + 5, curY), new Color(180, 42, 34), fontScale * 0.82f);
                curY += lineH;
            }

            // Subtle divider matching live theme ink
            int bodyTop = Math.Max(slotBox.Bottom + Math.Max(10, pad / 3), (int)curY + 4);
            int bodyBot = (_popupMaxQty > _popupMinQty ? _popSliderTrack.Y : _popBtnConfirm.Y) - Math.Max(12, pad / 3);
            sb.Draw(pixel, new Rectangle(_popPanel.X + pad, bodyTop, _popPanel.Width - pad * 2, Math.Max(2, vpH / 420)), primaryInk * 0.28f);
            bodyTop += Math.Max(8, pad / 4);

            // Body area: Ingredient list for Crafting OR Description for Shop
            if (_popupKind == PopupKind.Craft && _popupCraftRecipe != null && bodyBot > bodyTop + 28)
            {
                DrawCraftingIngredientsArea(sb, pixel, _popupCraftPage, _popupCraftRecipe, _popPanel.X + pad, bodyTop, _popPanel.Width - pad * 2, bodyBot - bodyTop, fontScale);
            }
            else if ((_popupKind == PopupKind.ShopBuy || _popupKind == PopupKind.ShopSell) && bodyBot > bodyTop + 22)
            {
                string desc = "";
                try { desc = (_popupSaleItem?.getDescription() ?? _popupItem?.getDescription() ?? "").Replace("\r", " ").Replace("\n", " ").Trim(); } catch { }
                if (!string.IsNullOrEmpty(desc))
                {
                    DrawWrappedStardewText(sb, desc, _popPanel.X + pad, bodyTop, _popPanel.Width - pad * 2, bodyBot - bodyTop, subInk, fontScale * 0.80f);
                }
            }

            // Native Stardew Slider Track + Knob + Step Buttons (honors Shop VisualTheme & Game1.mouseCursors!)
            if (_popupMaxQty > _popupMinQty)
            {
                try
                {
                    Texture2D trTex = shopTheme?.ScrollBarBackTexture ?? Game1.mouseCursors;
                    Rectangle trSrc = (shopTheme?.ScrollBarBackTexture != null && shopTheme.ScrollBarBackSourceRect.Width > 0)
                        ? shopTheme.ScrollBarBackSourceRect
                        : new Rectangle(403, 383, 6, 6);
                    IClickableMenu.drawTextureBox(sb, trTex, trSrc,
                        _popSliderTrack.X, _popSliderTrack.Y, _popSliderTrack.Width, _popSliderTrack.Height, Color.White, 4f, drawShadow: false);
                }
                catch
                {
                    sb.Draw(pixel, _popSliderTrack, primaryInk * 0.25f);
                }

                float frac = QtyToSliderFrac(_popupQty);
                int knobW = _popKnobW;
                int knobH = Math.Max(30, (int)(_popSliderTrack.Height * 1.24f));
                int usableW = Math.Max(1, _popSliderTrack.Width - knobW);
                int kx = _popSliderTrack.X + (int)Math.Round(usableW * frac);
                int ky = _popSliderTrack.Center.Y - knobH / 2;

                int fillEnd = kx + knobW / 2;
                if (fillEnd > _popSliderTrack.X + 4)
                    sb.Draw(pixel, new Rectangle(_popSliderTrack.X + 4, _popSliderTrack.Y + 4, Math.Max(0, fillEnd - (_popSliderTrack.X + 4)), Math.Max(4, _popSliderTrack.Height - 8)), primaryInk * 0.24f);

                try
                {
                    Texture2D kbTex = shopTheme?.ScrollBarFrontTexture ?? Game1.mouseCursors;
                    Rectangle kbSrc = (shopTheme?.ScrollBarFrontTexture != null && shopTheme.ScrollBarFrontSourceRect.Width > 0)
                        ? shopTheme.ScrollBarFrontSourceRect
                        : new Rectangle(420, 441, 10, 6);
                    sb.Draw(kbTex, new Rectangle(kx, ky, knobW, knobH), kbSrc, Color.White);
                }
                catch
                {
                    sb.Draw(pixel, new Rectangle(kx, ky, knobW, knobH), primaryInk * 0.70f);
                }

                // Live floating quantity callout right above knob while dragging so finger NEVER covers the number!
                if (_popSliderTouchId >= 0)
                {
                    string qTxt = $"×{_popupQty}";
                    float qScale = fontScale * 0.92f;
                    int bubW = Math.Max(68, (int)MeasureWidth(qTxt, qScale) + 24);
                    int bubH = Math.Max(34, (int)(36f * qScale));
                    int bx = Math.Clamp(kx + knobW / 2 - bubW / 2, _popPanel.X + 12, _popPanel.Right - bubW - 12);
                    int by = Math.Max(_popPanel.Y + 8, ky - bubH - 10);
                    var bubR = new Rectangle(bx, by, bubW, bubH);
                    PixelUi.DrawNativeSubBox(sb, pixel, bubR, new Color(255, 248, 224), 0.98f);
                    float tx = bubR.X + (bubR.Width - MeasureWidth(qTxt, qScale)) * 0.5f;
                    float ty = bubR.Y + Math.Max(3f, (bubR.Height - 26f * qScale) * 0.45f);
                    DrawStardewText(sb, qTxt, new Vector2(tx, ty), primaryInk, qScale);
                }

                DrawStardewPixelButton(sb, _popBtnM10, "-10", Color.White, fontScale * 0.88f);
                DrawStardewPixelButton(sb, _popBtnM1,  "-1",  Color.White, fontScale * 0.88f);
                DrawStardewPixelButton(sb, _popBtnP1,  "+1",  Color.White, fontScale * 0.88f);
                DrawStardewPixelButton(sb, _popBtnP10, "+10", Color.White, fontScale * 0.88f);
                string maxLbl = _popupKind == PopupKind.BagSplit ? "1/2" : "MAX";
                DrawStardewPixelButton(sb, _popBtnMax, maxLbl, Color.White, fontScale * 0.88f);
            }

            // Bottom native Stardew Buttons (clean Color.White / ultra-light tint so Cat Valley & custom UI themes look 100% native!)
            DrawStardewPixelButton(sb, _popBtnCancel, "Hủy", new Color(255, 238, 235), fontScale * 0.96f);

            string confirmLbl;
            Color confirmTint;
            if (_popupKind == PopupKind.ShopBuy)
            {
                int totalUnits = _popupQty * Math.Max(1, _popupBundlePerPurchase);
                if (!_popupCanAfford) { confirmLbl = "Không đủ điều kiện"; confirmTint = new Color(245, 210, 208); }
                else { confirmLbl = $"Mua ×{totalUnits}"; confirmTint = new Color(235, 255, 232); }
            }
            else if (_popupKind == PopupKind.ShopSell)
            {
                confirmLbl = $"Bán ×{_popupQty}";
                confirmTint = new Color(255, 248, 224);
            }
            else if (_popupKind == PopupKind.Craft)
            {
                bool cook = _popupCraftRecipe != null && _popupCraftRecipe.isCookingRecipe;
                if (!_popupCanAfford) { confirmLbl = "Thiếu nguyên liệu"; confirmTint = new Color(245, 210, 208); }
                else { confirmLbl = cook ? $"Nấu ×{_popupQty}" : $"Chế tạo ×{_popupQty}"; confirmTint = new Color(235, 255, 232); }
            }
            else if (_popupKind == PopupKind.ChestSplit)
            {
                confirmLbl = $"Chuyển ×{_popupQty}";
                confirmTint = new Color(232, 246, 255);
            }
            else
            {
                confirmLbl = $"Tách ×{_popupQty}";
                confirmTint = new Color(232, 246, 255);
            }
            DrawStardewPixelButton(sb, _popBtnConfirm, confirmLbl, confirmTint, fontScale * 0.98f);
        }

        private void DrawCraftingIngredientsArea(SpriteBatch sb, Texture2D pixel, CraftingPage cp, CraftingRecipe recipe, int x, int y, int w, int h, float fontScale)
        {
            if (recipe == null || recipe.recipeList == null) return;
            float descH = 0f;
            string desc = "";
            try { desc = (recipe.description ?? "").Replace("\r", " ").Replace("\n", " ").Trim(); } catch { }
            if (!string.IsNullOrEmpty(desc) && h > 95)
            {
                int maxDescH = Math.Min((int)(h * 0.36f), Math.Max(34, (int)(54f * fontScale)));
                descH = DrawWrappedStardewText(sb, desc, x, y, w, maxDescH, Game1.textColor * 0.90f, fontScale * 0.76f) + 6f;
            }

            int ingTop = y + (int)descH;
            int ingAvailH = Math.Max(28, (y + h) - ingTop);
            int count = recipe.recipeList.Count;
            if (count <= 0) return;

            int cols = count >= 3 && w >= 420 ? 2 : 1;
            int rows = (count + cols - 1) / cols;
            int cellH = Math.Clamp(ingAvailH / Math.Max(1, rows), 28, Math.Max(36, (int)(44f * fontScale)));
            int cellW = cols == 2 ? (w - 14) / 2 : w;
            int iconSz = Math.Clamp((int)(cellH * 0.76f), 20, 34);

            IList<Item> extraItems = _cachedCraftExtraItems ?? GetContainerItemsList(cp?._materialContainers);
            int idx = 0;
            foreach (var kv in recipe.recipeList)
            {
                int r = idx / cols;
                int c = idx % cols;
                idx++;
                int cy = ingTop + r * cellH;
                if (cy + iconSz > y + h + 6) break;
                int cx = x + c * (cellW + 14);

                string rawId = kv.Key;
                int need = kv.Value * Math.Max(1, _popupQty);
                int have = CountMatchingCraftIngredients(rawId, extraItems);

                // Native Stardew sub-box behind each ingredient row (automatically themed by Cat Valley UI & UI mods!)
                PixelUi.DrawNativeSubBox(sb, pixel, new Rectangle(cx, cy + 1, cellW, cellH - 3), Color.White, 0.88f);

                string spriteId = rawId;
                try { spriteId = recipe.getSpriteIndexFromRawIndex(rawId); } catch { }
                string fallbackDisplayName = null;
                try
                {
                    var pdata = ItemRegistry.GetDataOrErrorItem(spriteId);
                    if (pdata != null)
                    {
                        fallbackDisplayName = pdata.DisplayName;
                        sb.Draw(pdata.GetTexture(), new Rectangle(cx + 8, cy + (cellH - iconSz) / 2, iconSz, iconSz), pdata.GetSourceRect(), Color.White);
                    }
                }
                catch { }

                string ingName = null;
                try { ingName = recipe.getNameFromIndex(rawId); } catch { }
                if (string.IsNullOrEmpty(ingName) || string.Equals(ingName, rawId, StringComparison.Ordinal))
                    ingName = !string.IsNullOrEmpty(fallbackDisplayName) ? fallbackDisplayName : rawId;
                if (ingName.Length > (cols == 2 ? 15 : 26))
                    ingName = ingName.Substring(0, cols == 2 ? 14 : 25) + ".";

                bool enough = have >= need;
                Color cCol = enough ? new Color(34, 118, 42) : new Color(186, 34, 24);
                string countStr = $"{have}/{need}";
                float cScale = fontScale * 0.78f;
                float textTop = cy + Math.Max(2f, (cellH - 22f * cScale) * 0.45f);
                DrawStardewText(sb, ingName, new Vector2(cx + iconSz + 14, textTop), Game1.textColor, cScale);
                float cntW = MeasureWidth(countStr, cScale);
                DrawStardewText(sb, countStr, new Vector2(cx + cellW - cntW - 10, textTop), cCol, cScale);
            }
        }

        private static float MeasureWidth(string text, float scale)
        {
            if (string.IsNullOrEmpty(text) || Game1.smallFont == null) return 0f;
            try { return Game1.smallFont.MeasureString(text).X * scale; } catch { return text.Length * 12f * scale; }
        }

        private float DrawWrappedStardewText(SpriteBatch sb, string text, int x, int y, int maxW, int maxH, Color color, float scale)
        {
            if (string.IsNullOrEmpty(text) || Game1.smallFont == null || maxH <= 10) return 0f;
            if (!string.Equals(_wrapCacheText, text, StringComparison.Ordinal) ||
                _wrapCacheMaxW != maxW ||
                Math.Abs(_wrapCacheScale - scale) > 0.002f)
            {
                _wrapCacheText = text;
                _wrapCacheMaxW = maxW;
                _wrapCacheScale = scale;
                _wrapCacheLines.Clear();
                string[] words = text.Split(' ');
                string line = "";
                for (int i = 0; i < words.Length; i++)
                {
                    string cand = string.IsNullOrEmpty(line) ? words[i] : (line + " " + words[i]);
                    if (MeasureWidth(cand, scale) > maxW && !string.IsNullOrEmpty(line))
                    {
                        _wrapCacheLines.Add(line);
                        line = words[i];
                    }
                    else
                    {
                        line = cand;
                    }
                }
                if (!string.IsNullOrEmpty(line))
                    _wrapCacheLines.Add(line);
            }

            float curY = y;
            float lh = Math.Max(18f, 26f * scale);
            for (int i = 0; i < _wrapCacheLines.Count; i++)
            {
                if (curY + lh * 0.6f > y + maxH)
                    break;
                DrawStardewText(sb, _wrapCacheLines[i], new Vector2(x, curY), color, scale);
                curY += lh;
                if (curY + lh > y + maxH && i + 1 < _wrapCacheLines.Count)
                    break;
            }
            return curY - y;
        }

        private static void DrawStardewPixelButton(SpriteBatch sb, Rectangle r, string text, Color tint, float scale)
        {
            try
            {
                IClickableMenu.drawTextureBox(sb, Game1.mouseCursors, new Rectangle(432, 439, 9, 9),
                    r.X, r.Y, r.Width, r.Height, tint, 4f, drawShadow: true);
            }
            catch { }

            if (string.IsNullOrEmpty(text) || Game1.smallFont == null)
                return;
            try
            {
                Vector2 sz = Game1.smallFont.MeasureString(text) * scale;
                Vector2 pos = new Vector2(r.X + (r.Width - sz.X) * 0.5f, r.Y + (r.Height - sz.Y) * 0.5f + 2f);
                Utility.drawTextWithShadow(sb, text, Game1.smallFont, pos, Game1.textColor, scale);
            }
            catch { }
        }

        private void DrawFixedItemTooltipBanner(SpriteBatch sb, Texture2D pixel, Item item, int vpW, int vpH)
        {
            if (item == null || Game1.smallFont == null) return;
            try
            {
                int px = PixelUi.Step(vpH);
                float fScale = Math.Clamp(vpH / 980f, 0.70f, 1.25f);
                if (!ReferenceEquals(_tipCachedItem, item) || _tipCachedStack != item.Stack)
                {
                    _tipCachedItem = item;
                    _tipCachedStack = item.Stack;
                    _tipCachedTitle = item.DisplayName ?? item.Name ?? "";
                    string stats = "";
                    if (item is StardewValley.Object obj)
                    {
                        if (obj.Edibility > 0)
                        {
                            int energy = obj.staminaRecoveredOnConsumption();
                            int health = obj.healthRecoveredOnConsumption();
                            stats = $"+{energy} NL  +{health} Mau";
                        }
                        int sell = 0;
                        try { sell = obj.sellToStorePrice(); } catch { }
                        if (sell > 0)
                            stats = string.IsNullOrEmpty(stats) ? $"{sell:N0}g" : $"{stats}  ·  {sell:N0}g";
                    }
                    _tipCachedStats = stats;
                    string desc = "";
                    try { desc = (item.getDescription() ?? "").Replace("\r", " ").Replace("\n", " ").Trim(); } catch { }
                    if (desc.Length > 68) desc = desc.Substring(0, 65) + "...";
                    _tipCachedDesc = desc;
                }
                string title = _tipCachedTitle ?? "";
                string statsOut = _tipCachedStats ?? "";
                string descOut = _tipCachedDesc ?? "";

                int bw = Math.Clamp((int)(vpW * 0.44f), 280, Math.Min(600, vpW - 40));
                int lineH = Math.Max(18, (int)(26f * fScale));
                int lines = 1 + (string.IsNullOrEmpty(statsOut) ? 0 : 1) + (string.IsNullOrEmpty(descOut) ? 0 : 1);
                int bh = lines * lineH + px * 8;
                // Center along the bottom edge so it NEVER covers the top-right Close 'X' button, Context Bar, or DROP/Trash Can!
                int bx = (vpW - bw) / 2;
                int by = vpH - bh - Math.Max(12, vpH / 42);
                var box = new Rectangle(bx, by, bw, bh);

                PixelUi.DrawParchmentBox(sb, pixel, box, px, 0.94f);
                float tx = box.X + px * 4;
                float ty = box.Y + px * 3;
                DrawStardewText(sb, title, new Vector2(tx, ty), Game1.textColor, fScale * 0.96f);
                ty += lineH;
                if (!string.IsNullOrEmpty(statsOut))
                {
                    DrawStardewText(sb, statsOut, new Vector2(tx, ty), new Color(36, 118, 42), fScale * 0.84f);
                    ty += lineH;
                }
                if (!string.IsNullOrEmpty(descOut))
                {
                    DrawStardewText(sb, descOut, new Vector2(tx, ty), Game1.textColor * 0.88f, fScale * 0.78f);
                }
            }
            catch { }
        }

        private static void DrawStardewText(SpriteBatch sb, string text, Vector2 pos, Color color, float scale)
        {
            if (string.IsNullOrEmpty(text) || Game1.smallFont == null) return;
            try
            {
                Utility.drawTextWithShadow(sb, text, Game1.smallFont, pos, color, scale);
            }
            catch { }
        }

        private static bool TryGetInventoryPanelRect(InventoryMenu inv, out Rectangle bounds)
        {
            bounds = Rectangle.Empty;
            if (inv?.inventory == null || inv.inventory.Count == 0)
                return false;
            int count = IsPlayerBackpack(inv) ? GetUnlockedCapacity(inv) : Math.Min(inv.capacity, inv.inventory.Count);
            for (int i = 0; i < count; i++)
            {
                var cc = inv.inventory[i];
                if (cc == null || cc.bounds.Width <= 0 || cc.bounds.Height <= 0) continue;
                bounds = bounds.IsEmpty ? cc.bounds : Rectangle.Union(bounds, cc.bounds);
            }
            return !bounds.IsEmpty;
        }

        private static Rectangle FindHoveredSlotRect(InventoryMenu a, InventoryMenu b, Point uiPt)
        {
            if (a != null)
            {
                int s = FindSlotAt(a, uiPt);
                if (s >= 0) return a.inventory[s].bounds;
            }
            if (b != null)
            {
                int s = FindSlotAt(b, uiPt);
                if (s >= 0) return b.inventory[s].bounds;
            }
            return Rectangle.Empty;
        }

        private static Rectangle UiRectToVp(Rectangle uiRect, Func<Point, Vector2> uiToVp)
        {
            Vector2 tl = uiToVp(new Point(uiRect.X, uiRect.Y));
            Vector2 br = uiToVp(new Point(uiRect.Right, uiRect.Bottom));
            return new Rectangle((int)tl.X, (int)tl.Y, Math.Max(4, (int)(br.X - tl.X)), Math.Max(4, (int)(br.Y - tl.Y)));
        }

        private static void DrawBorder(SpriteBatch sb, Texture2D pixel, Rectangle r, int t, Color c)
        {
            sb.Draw(pixel, new Rectangle(r.X, r.Y, r.Width, t), c);
            sb.Draw(pixel, new Rectangle(r.X, r.Bottom - t, r.Width, t), c);
            sb.Draw(pixel, new Rectangle(r.X, r.Y, t, r.Height), c);
            sb.Draw(pixel, new Rectangle(r.Right - t, r.Y, t, r.Height), c);
        }
    }
}
