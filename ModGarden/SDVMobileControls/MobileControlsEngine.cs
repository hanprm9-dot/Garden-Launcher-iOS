using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using Microsoft.Xna.Framework.Input;
using Microsoft.Xna.Framework.Input.Touch;
using StardewModdingAPI;
using StardewValley;
using StardewValley.Locations;
using StardewValley.Menus;
using StardewValley.Objects;
using StardewValley.Tools;

namespace SDVMobileControls
{
    internal sealed class MobileControlsEngine
    {
        private readonly MobileConfig _cfg;
        private readonly IMonitor _monitor;
        private readonly MobileSaveSlotManager _saveSlots;
        private readonly MobileInventoryShopHelper _invShop = new MobileInventoryShopHelper();
        private readonly MobileMinigamePad _minigamePad = new MobileMinigamePad();
        private readonly VerticalToolbar _verticalToolbar = new VerticalToolbar();
        private PadBridge _bridge;
        private bool _loggedFirstIntercept;

        // Cached delegate instances (eliminates 5+ heap allocations per frame in Menu/Gameplay!)
        private readonly Func<Vector2, Vector2> _fnRawToVp;
        private readonly Func<Vector2, Point> _fnVpToUi;
        private readonly Func<Point, Vector2> _fnUiToVp;

        // Menu pad neutralization guard (avoids 60Hz ForwardInputToGame reflection storm while dragging in Backpack!)
        private bool _menuPadNeutralized;

        // Dirty-checked ComputeLayout() cache (avoids running 290-line layout math 120x/sec!)
        private bool _layoutValid;
        private int _layoutVpW;
        private int _layoutVpH;
        private int _layoutCfgRev;
        private MobileControlMode _layoutEffMode;
        private bool _layoutCollapsed;
        private bool _layoutIsMp;
        private int _layoutMaxItems;
        private int _layoutUiW;
        private int _layoutUiH;
        private int _layoutTbTopY;
        private Toolbar _cachedHudToolbar;

        // Cached hold-to-tool intent per touch press (avoids per-frame world scan during 0.14-0.28s hold windup!)
        private bool _tapPressIntentComputed;
        private Vector2 _tapPressStartWorld;
        private Point _tapPressStartTile;
        private TileIntent _tapPressHoldIntent;

        // Movement stick smoother + 8-way Schmitt-trigger hysteresis around TouchVirtualPad's 0.25f cutoff
        private Vector2 _smoothedStick;
        private int _hystAxisX;
        private int _hystAxisY;

        // Textures (created lazily on GPU thread)
        private Texture2D _pixel;
        private Texture2D _circle;
        private Texture2D _ring;

        // Dynamic viewport dimensions (NEVER hardcoded to any device resolution!)
        private int _vpW;
        private int _vpH;
        private int _rawW;
        private int _rawH;

        // Gameplay Utility Bar
        private Rectangle _btnBagRect;
        private Rectangle _btnMapRect;
        private Rectangle _btnQuestRect;
        private Rectangle _btnSaveRect;
        private Rectangle _btnKeyRect;
        private Rectangle _btnEmoteRect;
        private Rectangle _btnCtlModeRect;
        private Rectangle _btnEditRect;
        private Rectangle _btnCollapseRect;
        private Rectangle _topBarGroupRect;
        private bool _topBarCollapsed;

        // Stardew-Pixel Multi-Slot Save Menu Modal (replaces legacy MODS drawer — zero old SDViOS controls!)
        private bool _saveMenuOpen;
        private int _saveSelectedIdx;
        private int _saveScrollIdx;
        private int _saveSwipeTouchId = -1;
        private float _saveSwipeStartY;
        private float _saveSwipeLastY;
        private float _saveSwipeAccumY;
        private bool _saveSwipeMoved;
        private Rectangle _savePanelRect;
        private Rectangle _saveCloseRect;
        private Rectangle _saveListRect;
        private Rectangle _saveNewBtnRect;
        private Rectangle _saveLoadBtnRect;
        private Rectangle _saveDelBtnRect;
        private Rectangle _saveUpBtnRect;
        private Rectangle _saveDnBtnRect;
        private string _saveToastText;
        private double _saveToastUntil;
        private double _ramWarningUntil;
        private bool _ramCritical;

        // Context Menu Helper Bar (only in Inventory/Chest/Shop/TextInput, plus ESC-only on QuestLog!)
        private Rectangle _ctxX1Rect;
        private Rectangle _ctxHalfRect;
        private Rectangle _ctxXferRect;
        private Rectangle _ctxKeyRect;
        private Rectangle _ctxEscRect;
        private Rectangle _ctxQuestEscRect;
        private int _ctxTouchId = -1;

        // Invisible Mode rects (Left Joystick Zone + 2 Right Vertical Rectangular Bars)
        private Rectangle _invJoyRect;
        private Rectangle _invToolRect;
        private Rectangle _invActRect;

        // Visible 2-Button Mode geometry (Joystick circle + 2 circular buttons)
        private Vector2 _visJoyCenter;
        private float _visJoyRadius = 100f;
        private Rectangle _visToolRect;
        private Rectangle _visActRect;

        // Custom PC Key Buttons runtime tracking (up to 16 simultaneous custom PC buttons)
        private readonly Dictionary<int, int> _customBtnTouchIds = new Dictionary<int, int>(16); // btnId -> touchId
        private readonly Dictionary<int, int> _customBtnPulseFrames = new Dictionary<int, int>(16); // btnId -> remaining pulse frames
        private readonly Dictionary<int, double> _customBtnLastPressSec = new Dictionary<int, double>(16); // btnId -> last press timestamp
        private readonly HashSet<int> _customBtnsHeldNow = new HashSet<int>();

        // Active joystick runtime state (normalized 0..1 coordinates guarantee zero drift between Update & Draw viewports!)
        private int _joyTouchId = -1;
        private Vector2 _joyOrigin;
        private Vector2 _joyKnob;
        private Vector2 _joyOriginNorm;
        private Vector2 _joyKnobNorm;
        private Vector2 _joyTouchStart;
        private double _joyTouchStartTime;
        private bool _joyActivated;
        private float _activeJoyRadius = 100f;

        // Right-side 2 action buttons runtime state (UseTool = X, Interact = A)
        private int _toolTouchId = -1;
        private int _interactTouchId = -1;
        private bool _toolPressed;
        private bool _interactPressed;
        private bool _prevInteractPressed;
        private bool _suppressActUntilRelease;
        private float _toolRippleAlpha;
        private float _interactRippleAlpha;

        // Pinch-to-Zoom state
        private bool _pinching;
        private float _pinchStartDist;
        private float _pinchStartZoom;
        private int _pinchIdA = -1;
        private int _pinchIdB = -1;

        // Tap-to-Move / Hold-to-Walk state
        private int _tapTouchId = -1;
        private Vector2 _tapStartScreen;
        private Vector2 _tapCurScreen;
        private double _tapStartTime;
        private bool _holdWalking;
        private bool _tapChargingTool;
        private bool _tapHoldSwinging;
        private Point _tapHoldTile;
        private int _tapHoldCooldown;
        private List<Point> _path;
        private int _pathIdx;
        private Point _targetTile;
        private bool _hasTargetTile;
        private TileIntent _pendingIntent;
        private bool _hasPendingWarp;
        private Point _pendingWarpTile;
        private int _warpPushFrames;
        private Vector2 _lastPlayerPos;
        private int _stuckFrames;
        private int _actionPulseXFrames;
        private int _actionPulseAFrames;
        private int _warpPushStartHudCount;
        private object _lastPadObj;
        private string _lastLocationName;
        private MobileControlMode _lastModeSeen = MobileControlMode.VirtualGamepad;
        private bool _wasInMenu;
        private Vector2 _unstickLastPos;
        private int _unstickStillTicks;

        // Slingshot touch drag-to-aim state
        private int _slingshotTouchId = -1;
        private int _slingshotReleaseHoldFrames;
        private Vector2 _slingshotRawPos;
        private Vector2 _slingshotVpPos;
        private Vector2 _slingshotNorm;
        private int _pendingWeaponSpecTicks;
        private readonly HashSet<Keys> _scratchExtraCheckSet = new HashSet<Keys>();

        // Auto-attack state (default OFF)
        private int _autoAttackCooldown;

        // Menu 1-finger tap / drag / swipe scroll / camera pan state (single TouchPanel.GetState() per frame!)
        private int _menuTapTouchId = -1;
        private Vector2 _menuTapStartVp;
        private Vector2 _menuTapLastVp;
        private float _menuTapLastY;
        private float _menuTapAccumY;
        private bool _menuTapDragged;
        private bool _menuTapImmediateDrag;
        private bool _menuTapCameraPan;
        private double _menuTapStartSec;
        private bool _menuTapRightClicked;
        private int _holdSweepCooldown;
        private int _lastAppliedSafeRightPad = -999;
        private int _worldReadyTicks;
        private int _unstickHoldTicks;

        // Hide GUI mode (1-tap HIDE -> clean full-screen photo mode hiding HUD & buttons; double-tap -> restore!)
        private bool _guiHidden;
        private bool _preHideDisplayHud = true;
        private Rectangle _btnHideGuiRect;
        private Rectangle _btnChatRect;
        private Rectangle _btnSkipEventRect;
        private double _lastHideTapSec = -10.0;
        private Vector2 _lastHideTapVp;
        private int _hideTapTouchId = -1;
        private Vector2 _hideTapStartVp;

        // Smooth throttled Pinch-to-Zoom (avoids 50x Window_ClientSizeChanged spam!)
        private double _lastPinchApplySec;
        private float _pendingPinchZoom;
        private bool _pinchDirtySave;

        // Universal 3rd-Party Mod Menu Simulated Mouse State Machine (GMCM, SpaceCore, CJB, LookupAnything, StardewUI, etc.)
        private enum ModTouchState { None = 0, Pending = 1, MouseDrag = 2, SwipeScroll = 3, RightClicked = 4 }
        private ModTouchState _modTouchState = ModTouchState.None;
        private Point? _simMousePulsePos;
        private int _simMouseLeftPulseFrames;
        private int _simMouseRightPulseFrames;
        private Point? _lastMenuMouseRaw;

        // Safe 2-Tap Preview on Robin/Wizard CarpenterMenu (shows green/red grid before confirming!)
        private CarpenterMenu _carpenterPreviewMenu;
        private Vector2 _carpenterPreviewVp;
        private bool _hasCarpenterPreview;

        // Tap-to-Move Fishing Cast Sideways Bend (steer bobber left/right into fish bubbles!)
        private int _fishBendTouchId = -1;
        private Vector2 _fishBendStartVp;
        private float _fishBendX;

        // Community Center bundle & safe 2-tap Dialogue state
        private static readonly System.Reflection.FieldInfo RenovateFreezeField =
            typeof(RenovateMenu).GetField("freeze", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
        private static readonly System.Reflection.FieldInfo ShopScrollRunnerField =
            typeof(ShopMenu).GetField("scrollBarRunner", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
        private static readonly System.Reflection.FieldInfo LoadGameScrollRunnerField =
            typeof(LoadGameMenu).GetField("scrollBarRunner", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
        private int _menuDragClampX = -1;
        private JunimoNoteMenu _junimoHoverMenu;
        private ClickableComponent _junimoHoveredSlot;
        private DialogueBox _dlgHoverMenu;
        private int _dlgHoveredIdx = -1;
        private int _weatherTickCounter;

        // Auto iOS keyboard on TextBox focus + Native iOS 14-27 UIWindowScene Keyboard Alert bridge
        private IKeyboardSubscriber _lastKbSubscriber;
        private double _lastAutoKbSec;
        private IKeyboardSubscriber _nativeKbTarget;
        private bool _nativeKbActive;
        private int _titleClickPulseFrames;
        private Point? _titleClickRawPos;
        private int _gameMenuModClickPulseFrames;
        private Point? _gameMenuModClickRawPos;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int NativeKbShowDelegate(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string title,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string initial);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int NativeKbPollDelegate(byte[] outUtf8, int outCap);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int NativeKbIsActiveDelegate();

        [DllImport("/usr/lib/libSystem.dylib", EntryPoint = "dlsym")]
        private static extern IntPtr MobileDarwinDlsym(IntPtr handle, [MarshalAs(UnmanagedType.LPStr)] string symbol);

        private static bool _nativeKbResolved;
        private static NativeKbShowDelegate _nativeKbShow;
        private static NativeKbPollDelegate _nativeKbPoll;
        private static NativeKbIsActiveDelegate _nativeKbIsActive;
        private static readonly byte[] _nativeKbBuf = new byte[1024];

        private static readonly FieldInfo CcNameBoxField =
            typeof(CharacterCustomization).GetField("nameBox", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        private static readonly FieldInfo CcFarmBoxField =
            typeof(CharacterCustomization).GetField("farmnameBox", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        private static readonly FieldInfo CcFavBoxField =
            typeof(CharacterCustomization).GetField("favThingBox", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        private static readonly FieldInfo TextBoxOnEnterField =
            typeof(TextBox).GetField("OnEnterPressed", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        private static readonly FieldInfo InputCurrentMouseStateField =
            typeof(InputState).GetField("_currentMouseState", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        private static FieldInfo _sInputMouseStateField;
        private static bool _sInputMouseStateResolved;
        private static readonly FieldInfo LevelUpProfessionsField =
            typeof(LevelUpMenu).GetField("professionsToChoose", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        private static readonly FieldInfo SkillsHoverTextField =
            typeof(SkillsPage).GetField("hoverText", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        private static FieldInfo _hostVkmActiveField;
        private static bool _hostVkmResolved;

        // Toolbar tap/swipe + ROW quick-switch + Furniture ROT + Weapon SPEC button
        private int _toolbarTouchId = -1;
        private Vector2 _toolbarStartVp;
        private int _toolbarTappedSlot = -1;
        private bool _toolbarSwiped;
        private Rectangle _btnToolbarRowRect;
        private Rectangle _btnRotateRect;
        private Rectangle _btnSpecRect;

        // Auto-Repeat 1-tap chop/mine + Optional restore previous slot after Auto-Tool
        private bool _repeatActive;
        private Point _repeatTile;
        private int _repeatCooldown;
        private int _repeatSwings;
        private int _repeatStartHudCount;
        private float _repeatLastHealth;
        private int _repeatNoProgressSwings;
        private bool _repeatObservedSwing;
        private int _autoToolPrevSlot = -1;
        private int _autoToolRestoreTimer;

        // Auto-Combat Mode (Mines/Volcano) + Bluetooth GamePad auto-hide + Haptic + SafeArea + 30fps saver + UI Scale restore
        private bool _inCombatAutoSwitched;
        private string _combatManualOverrideLoc;
        private bool _gamepadHideHud;
        private int _gamepadPollCounter;
        private GamePadState _lastPhysicalGamePadState;
        private bool _hasPhysicalGamePadState;
        private static readonly System.Reflection.MethodInfo GamePadPlatformGetStateMethod =
            typeof(GamePad).GetMethod("PlatformGetState",
                System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public,
                null,
                new[] { typeof(int), typeof(GamePadDeadZone), typeof(GamePadDeadZone) },
                null);
        private static readonly object[] GamePadPlatformArgs =
            new object[] { 0, GamePadDeadZone.IndependentAxes, GamePadDeadZone.IndependentAxes };
        private bool _appliedUiScaleOverride;
        private float _origDesiredUiScale = 1.0f;
        private bool _wasFishNibbling;
        private int _safeLeftPx;
        private int _safeRightPx;
        private int _saverFrameCounter;
        private bool _wasNativeGardenOpen;

        // Safe periodic AutoSave state (default OFF, skips combat/mines/moving)
        private double _lastAutoSaveSec = -1;
        private double _idleSinceSec = -1;
        private int _lastAutoSaveTimeOfDay = -1;
        private string _lastAutoSaveLoc;

        // ---- Dedicated Mobile Edit Layout Mode + In-Game PC Key Picker ----
        private enum EditTarget { None = 0, Joy = 1, Tool = 2, Act = 3, TopBar = 4, CustomKey = 5, Toolbar = 6 }
        private bool _editMode;
        private EditTarget _editSelected = EditTarget.None;
        private int _editSelectedCustomId = -1;
        private EditTarget _editDragTarget = EditTarget.None;
        private int _editDragCustomId = -1;
        private bool _editResizing;
        private int _editTouchId = -1;
        private Vector2 _editDragLastVp;

        private Rectangle _editToolbarRect;
        private Rectangle _editAddKeyBtnRect;
        private Rectangle _editDelKeyBtnRect;
        private Rectangle _editResetBtnRect;
        private Rectangle _editCancelBtnRect;
        private Rectangle _editSaveBtnRect;

        // Built-in PC Key Picker Modal inside Edit Layout
        private bool _keyPickerOpen;
        private Rectangle _pickerPanelRect;
        private Rectangle _pickerCloseRect;

        private readonly struct KeyChoice
        {
            public readonly string Label;
            public readonly Keys Key;
            public KeyChoice(string label, Keys key) { Label = label; Key = key; }
        }

        private static readonly KeyChoice[] PcKeyCatalog = new[]
        {
            // Popular mod & gameplay keys first
            new KeyChoice("P", Keys.P),
            new KeyChoice("I", Keys.I),
            new KeyChoice("F1", Keys.F1),
            new KeyChoice("TAB", Keys.Tab),
            new KeyChoice("SHFT", Keys.LeftShift),
            new KeyChoice("CTRL", Keys.LeftControl),
            new KeyChoice("ALT", Keys.LeftAlt),
            new KeyChoice("SPC", Keys.Space),
            new KeyChoice("ENT", Keys.Enter),
            new KeyChoice("ESC", Keys.Escape),
            new KeyChoice("T", Keys.T),
            new KeyChoice("Y", Keys.Y),
            // Function row
            new KeyChoice("F2", Keys.F2), new KeyChoice("F3", Keys.F3), new KeyChoice("F4", Keys.F4),
            new KeyChoice("F5", Keys.F5), new KeyChoice("F6", Keys.F6), new KeyChoice("F7", Keys.F7),
            new KeyChoice("F8", Keys.F8), new KeyChoice("F9", Keys.F9), new KeyChoice("F10", Keys.F10),
            new KeyChoice("F11", Keys.F11), new KeyChoice("F12", Keys.F12), new KeyChoice("BCK", Keys.Back),
            // Letters (remaining A-Z)
            new KeyChoice("A", Keys.A), new KeyChoice("B", Keys.B), new KeyChoice("C", Keys.C),
            new KeyChoice("D", Keys.D), new KeyChoice("E", Keys.E), new KeyChoice("F", Keys.F),
            new KeyChoice("G", Keys.G), new KeyChoice("H", Keys.H), new KeyChoice("J", Keys.J),
            new KeyChoice("K", Keys.K), new KeyChoice("L", Keys.L), new KeyChoice("M", Keys.M),
            new KeyChoice("N", Keys.N), new KeyChoice("O", Keys.O), new KeyChoice("Q", Keys.Q),
            new KeyChoice("R", Keys.R), new KeyChoice("S", Keys.S), new KeyChoice("U", Keys.U),
            new KeyChoice("V", Keys.V), new KeyChoice("W", Keys.W), new KeyChoice("X", Keys.X),
            new KeyChoice("Z", Keys.Z),
            // Numbers & symbols
            new KeyChoice("1", Keys.D1), new KeyChoice("2", Keys.D2), new KeyChoice("3", Keys.D3),
            new KeyChoice("4", Keys.D4), new KeyChoice("5", Keys.D5), new KeyChoice("6", Keys.D6),
            new KeyChoice("7", Keys.D7), new KeyChoice("8", Keys.D8), new KeyChoice("9", Keys.D9),
            new KeyChoice("0", Keys.D0), new KeyChoice("-", Keys.OemMinus), new KeyChoice("+", Keys.OemPlus),
            new KeyChoice("[", Keys.OemOpenBrackets), new KeyChoice("]", Keys.OemCloseBrackets),
            new KeyChoice("~", Keys.OemTilde), new KeyChoice("UP", Keys.Up),
            new KeyChoice("DN", Keys.Down), new KeyChoice("LT", Keys.Left), new KeyChoice("RT", Keys.Right),
        };

        public MobileControlsEngine(MobileConfig cfg, IMonitor monitor, string modDir)
        {
            _cfg = cfg;
            _monitor = monitor;
            _saveSlots = new MobileSaveSlotManager(modDir, monitor);
            _fnRawToVp = MapRawToViewport;
            _fnVpToUi = ViewportToUi;
            _fnUiToVp = UiToViewport;
        }

        public void OnReturnedToTitle()
        {
            if (_editMode) ExitEditLayoutMode();
            if (_saveMenuOpen) CloseSaveMenu(flushExternal: false);
            SetGuiHidden(false);
            ResetGameplayState();
            ResetMenuTapState();
            ClearCustomButtonTouches();
            _invShop.Reset();
            _minigamePad.Reset();
            _verticalToolbar.ClearCachedToolbar();
            _cachedHudToolbar = null;
            _layoutValid = false;
            _menuPadNeutralized = false;
            _inCombatAutoSwitched = false;
            _combatManualOverrideLoc = null;
            _gamepadHideHud = false;
            _hasPhysicalGamePadState = false;
            _lastLocationName = null;
            _lastAutoSaveSec = -1;
            _idleSinceSec = -1;
            _lastAutoSaveTimeOfDay = -1;
            _lastAutoSaveLoc = null;
            _worldReadyTicks = 0;
            _lastMenuMouseRaw = null;
            _carpenterPreviewMenu = null;
            _hasCarpenterPreview = false;
            _junimoHoverMenu = null;
            _junimoHoveredSlot = null;
            _dlgHoverMenu = null;
            _dlgHoveredIdx = -1;
        }

        public void OnGameSaved()
        {
            if (_saveSlots.FinalizePendingSnapshot(out string summary))
            {
                ShowSaveToast("DA LUU: " + summary, Environment.TickCount64 / 1000.0);
            }
        }

        public void ShowSaveToast(string text, double nowSec)
        {
            _saveToastText = text;
            _saveToastUntil = nowSec + 3.0;
        }

        public MobileControlMode CurrentMode => EffectiveMode;
        public bool IsPureGamepadMode => _cfg.PureGamepadMode;
        public bool IsMobileModeActive => !_cfg.PureGamepadMode;

        public static bool IsPlayableEventActive()
        {
            if (!Game1.eventUp)
                return false;
            try
            {
                var ev = Game1.CurrentEvent;
                return ev != null && ev.playerControlSequence;
            }
            catch
            {
                return false;
            }
        }

        public static bool IsBlockingCutsceneActive() => Game1.eventUp && !IsPlayableEventActive();

        public static bool CanUseToolInCurrentState()
        {
            if (!Game1.eventUp)
                return true;
            try
            {
                var ev = Game1.CurrentEvent;
                return ev != null && ev.canPlayerUseTool();
            }
            catch
            {
                return false;
            }
        }

        private MobileControlMode EffectiveMode =>
            (_inCombatAutoSwitched && _cfg.AutoCombatMode && _cfg.Mode == MobileControlMode.TapToMove)
                ? MobileControlMode.InvisibleJoystick2Btn
                : _cfg.Mode;

        private bool IsInvisibleBarMode =>
            EffectiveMode == MobileControlMode.InvisibleJoystick2Btn ||
            EffectiveMode == MobileControlMode.TapAndJoystick;

        private void SetGuiHidden(bool hide)
        {
            if (_guiHidden == hide)
                return;
            if (hide)
            {
                _preHideDisplayHud = Game1.displayHUD;
                _guiHidden = true;
                Game1.displayHUD = false;
            }
            else
            {
                _guiHidden = false;
                Game1.displayHUD = _preHideDisplayHud;
            }
        }

        private PadBridge EnsureBridge(object pad)
        {
            if (_bridge == null && pad != null)
                _bridge = new PadBridge(pad.GetType());
            return _bridge;
        }

        private static bool IsContinuousHoldKey(int keyCode)
        {
            // Modifiers (Left/Right Shift, Ctrl, Alt), Arrow keys (Left/Up/Right/Down), Space
            return (keyCode >= 160 && keyCode <= 165) ||
                   (keyCode >= 37 && keyCode <= 40) ||
                   keyCode == 32;
        }

        public void PopulateExtraKeys(HashSet<Keys> targetSet)
        {
            if (targetSet == null || !IsMobileModeActive || _editMode)
                return;

            if (Game1.currentMinigame != null)
            {
                _minigamePad.PopulateKeys(targetSet);
                return;
            }

            for (int i = 0; i < _cfg.CustomKeys.Count; i++)
            {
                var btn = _cfg.CustomKeys[i];
                if (btn.KeyCode <= 0) continue;
                bool held = _customBtnsHeldNow.Contains(btn.Id);
                bool pulsing = _customBtnPulseFrames.TryGetValue(btn.Id, out int rem) && rem > 0;
                bool active = IsContinuousHoldKey(btn.KeyCode) ? (held || pulsing) : pulsing;
                if (active)
                {
                    targetSet.Add((Keys)btn.KeyCode);
                }
            }
        }

        public void PopulateExtraKeysList(List<Keys> targetList)
        {
            if (targetList == null || !IsMobileModeActive || _editMode)
                return;

            if (Game1.currentMinigame != null)
            {
                _minigamePad.PopulateKeysList(targetList);
                return;
            }

            for (int i = 0; i < _cfg.CustomKeys.Count; i++)
            {
                var btn = _cfg.CustomKeys[i];
                if (btn.KeyCode <= 0) continue;
                bool held = _customBtnsHeldNow.Contains(btn.Id);
                bool pulsing = _customBtnPulseFrames.TryGetValue(btn.Id, out int rem) && rem > 0;
                bool active = IsContinuousHoldKey(btn.KeyCode) ? (held || pulsing) : pulsing;
                if (active)
                {
                    Keys k = (Keys)btn.KeyCode;
                    if (!targetList.Contains(k))
                        targetList.Add(k);
                }
            }
        }

        public bool HasActiveExtraKeys()
        {
            if (!IsMobileModeActive || _editMode)
                return false;

            if (Game1.currentMinigame != null)
            {
                _scratchExtraCheckSet.Clear();
                _minigamePad.PopulateKeys(_scratchExtraCheckSet);
                return _scratchExtraCheckSet.Count > 0;
            }

            for (int i = 0; i < _cfg.CustomKeys.Count; i++)
            {
                var btn = _cfg.CustomKeys[i];
                if (btn.KeyCode <= 0) continue;
                bool held = _customBtnsHeldNow.Contains(btn.Id);
                bool pulsing = _customBtnPulseFrames.TryGetValue(btn.Id, out int rem) && rem > 0;
                if (IsContinuousHoldKey(btn.KeyCode) ? (held || pulsing) : pulsing)
                    return true;
            }
            return false;
        }

        public bool ShouldSuppressOriginalDraw(object pad)
        {
            if (!IsMobileModeActive || pad == null)
                return false;
            var br = EnsureBridge(pad);
            if (br == null)
                return false;
            // Never let legacy HotkeyDrawer resurface the old SDViOS gamepad!
            br.CloseHotkeyDrawer(pad);
            if (br.IsFullScreenModalOpen(pad) || br.IsQuickSaveReloading())
                return false;
            return true;
        }

        public bool ShouldInterceptGameplay(object pad)
        {
            if (pad == null)
                return false;

            if (Context.IsWorldReady && _cfg.TryConsumeRamAlertFlag(out string ramAlert))
            {
                double nowSec = Environment.TickCount64 / 1000.0;
                bool isCrit = ramAlert.StartsWith("CRIT|", StringComparison.Ordinal);
                if (isCrit || ramAlert.StartsWith("WARN|", StringComparison.Ordinal))
                    ramAlert = ramAlert.Substring(5);
                _ramCritical = isCrit;
                _ramWarningUntil = nowSec + (isCrit ? 11.0 : 7.5);
                _saveToastText = ramAlert;
                _saveToastUntil = nowSec + (isCrit ? 9.5 : 6.5);
                _topBarCollapsed = false;
                try { ModEntry.RamOptimizer?.RunAggressivePrune(isCrit ? "RamAlert90" : "RamAlert85"); } catch { }
                try { Game1.addHUDMessage(new HUDMessage(ramAlert, HUDMessage.error_type)); } catch { }
                try { Game1.playSound(isCrit ? "cancel" : "warn"); } catch { try { Game1.playSound("crafting"); } catch { } }
            }

            PollPendingEditLayoutFlag();

            if (!IsMobileModeActive)
                return false;
            if (!Context.IsWorldReady || Game1.player == null || Game1.currentLocation == null)
                return false;
            if (Game1.activeClickableMenu != null || IsBlockingCutsceneActive() || Game1.dialogueUp || Game1.paused)
                return false;
            if (Game1.currentMinigame != null && MobileMinigamePad.DetectCurrentArcadeMinigame() == MobileMinigamePad.ArcadeKind.None)
                return false;
            var br = EnsureBridge(pad);
            if (br == null)
                return false;
            br.CloseHotkeyDrawer(pad);
            if (br.IsFullScreenModalOpen(pad) || br.IsQuickSaveReloading())
                return false;
            return true;
        }

        public static int CountActiveTouches(TouchCollection touches)
        {
            int cnt = 0;
            for (int i = 0; i < touches.Count; i++)
            {
                var st = touches[i].State;
                if (st == TouchLocationState.Pressed || st == TouchLocationState.Moved)
                    cnt++;
            }
            return cnt;
        }

        public void PollPendingEditLayoutFlag()
        {
            if (Context.IsWorldReady && Game1.activeClickableMenu == null && _cfg.ConsumeEditLayoutFlag())
            {
                if (_cfg.Mode == MobileControlMode.VirtualGamepad)
                {
                    _cfg.Mode = MobileControlMode.InvisibleJoystick2Btn;
                    _cfg.Save();
                }
                if (_saveMenuOpen)
                    CloseSaveMenu(flushExternal: false);
                EnterEditLayoutMode();
            }
        }

        public bool IsLegacyFullScreenModalOpen(object pad)
        {
            object target = pad ?? _lastPadObj;
            return target != null && (EnsureBridge(target)?.IsFullScreenModalOpen(target) ?? false);
        }

        public bool IsQuickSaveReloading(object pad)
        {
            object target = pad ?? _lastPadObj;
            return target != null && (EnsureBridge(target)?.IsQuickSaveReloading() ?? false);
        }

        public bool IsUiOverlayBlockingExternalInput(object pad)
        {
            return _editMode || _saveMenuOpen || IsLegacyFullScreenModalOpen(pad);
        }

        public void ResetVirtualPadForExternal(object pad)
        {
            if (pad != null)
                EnsureBridge(pad)?.ResetVirtualPad(pad);
        }

        public bool ShouldAutoHideLegacyVirtualGamepad(object pad)
        {
            return _cfg.AutoHideOnGamepad &&
                   ModEntry.ExternalInput != null &&
                   ModEntry.ExternalInput.IsExternalDeviceActive &&
                   !ModEntry.ExternalInput.IsSuppressed &&
                   !IsLegacyFullScreenModalOpen(pad);
        }

        private void EnterEditLayoutMode()
        {
            _gamepadHideHud = false;
            ResetGameplayState();
            _editMode = true;
            _keyPickerOpen = false;
            _editSelected = EditTarget.Tool;
            _editSelectedCustomId = -1;
            _editDragTarget = EditTarget.None;
            _editDragCustomId = -1;
            _editResizing = false;
            _editTouchId = -1;
            ModEntry.ExternalInput?.SetManagedSuppressed(true);
            ModEntry.ExternalInput?.FlushFarmerMovementAndState(restoreAutoRun: false);
        }

        private void ExitEditLayoutMode()
        {
            bool wasEdit = _editMode;
            _editMode = false;
            _keyPickerOpen = false;
            _editDragTarget = EditTarget.None;
            _editDragCustomId = -1;
            _editResizing = false;
            _editTouchId = -1;
            ResetGameplayState();
            if (wasEdit)
            {
                ModEntry.ExternalInput?.SetManagedSuppressed(IsUiOverlayBlockingExternalInput(_lastPadObj));
                ModEntry.ExternalInput?.FlushFarmerMovementAndState(restoreAutoRun: true);
            }
        }

        public void TrackPadReference(object pad)
        {
            if (pad != null)
            {
                _lastPadObj = pad;
                EnsureBridge(pad);
            }
        }

        public bool IsMobileModeForBobberPhysics => IsMobileModeActive;

        /// <summary>
        /// When the Mobile Vertical Toolbar is enabled, computes pixel-exact coordinates inside the active
        /// HUDMessage draw viewport (tsarea) using normalized 0..1 screen fractions so item-pickup popups
        /// ALWAYS clear the Vertical Toolbar (left or right, 1-3 cols), Top Utility Bar, and Joystick
        /// regardless of ZoomLevel, UIScale, or BackBuffer vs uiScreen!
        /// </summary>
        public bool TryGetHudMessageRelocation(Rectangle tsarea, out float targetX, out float topStartY, out float maxRightX)
        {
            targetX = 0f;
            topStartY = 0f;
            maxRightX = tsarea.Right - 16f;
            if (!IsMobileModeActive || !_cfg.VerticalToolbar || _guiHidden || _gamepadHideHud)
                return false;
            if (!Context.IsWorldReady || Game1.activeClickableMenu != null)
                return false;

            try
            {
                if (tsarea.Width < 320 || tsarea.Height < 200 || _vpW < 100 || _vpH < 100)
                    return false;

                // Top clearance in normalized screen fraction: sit cleanly below Top Utility Bar when Top Bar is near the top
                bool topBarAtTop = _cfg.ShowTopUtility && !_btnBagRect.IsEmpty && _btnBagRect.Top < _vpH * 0.28f;
                float topFrac = topBarAtTop
                    ? Math.Max((_btnBagRect.Bottom + 10f) / _vpH, 0.105f)
                    : Math.Max(14f / _vpH, 0.032f);
                topFrac = Math.Clamp(topFrac, 0.025f, 0.24f);
                topStartY = tsarea.Top + topFrac * tsarea.Height;

                // Horizontal clearance in normalized screen fraction: clear Vertical Toolbar (left or right) & Notch SafeArea
                Rectangle vtBounds = _verticalToolbar.Bounds;
                float leftFrac;
                float rightLimitFrac = 0.985f;
                if (_cfg.ToolbarSide == 0 && !vtBounds.IsEmpty)
                {
                    leftFrac = (vtBounds.Right + 14f) / _vpW;
                }
                else
                {
                    leftFrac = Math.Max(_safeLeftPx + 14f, 16f) / _vpW;
                    if (_cfg.ToolbarSide == 1 && !vtBounds.IsEmpty)
                        rightLimitFrac = Math.Clamp((vtBounds.Left - 14f) / _vpW, 0.45f, 0.985f);
                }

                leftFrac = Math.Clamp(leftFrac, 0.015f, 0.45f);
                targetX = tsarea.Left + leftFrac * tsarea.Width;
                maxRightX = tsarea.Left + rightLimitFrac * tsarea.Width;
                return true;
            }
            catch
            {
                return false;
            }
        }

        /// <summary>
        /// Computes safe top-left coordinates for MineShaft / Skull Cavern / VolcanoDungeon floor numbers
        /// shifted cleanly downward &amp; inward out of iPhone rounded corners (and clear of top utility bar / left vertical toolbar).
        /// </summary>
        public bool TryGetMineFloorSafePosition(Rectangle tsarea, out int targetX, out int targetY)
        {
            targetX = tsarea.Left + 24;
            targetY = tsarea.Top + 64;
            try
            {
                if (tsarea.Width < 320 || tsarea.Height < 200)
                    return false;
                RefreshViewport();
                int vw = Math.Max(320, _vpW);
                int vh = Math.Max(200, _vpH);

                // Safe top margin: push cleanly below iPhone top-left rounded corner (~9.5% of height, min 58px)
                float topFrac = Math.Max(0.095f, 58f / vh);
                bool touchHudVisible = IsMobileModeActive && !_guiHidden && !_gamepadHideHud;
                if (touchHudVisible && _cfg.ShowTopUtility && !_btnBagRect.IsEmpty && _btnBagRect.Top < vh * 0.28f)
                {
                    float belowTopBar = (_btnBagRect.Bottom + 10f) / vh;
                    if (belowTopBar > topFrac)
                        topFrac = belowTopBar;
                }
                topFrac = Math.Clamp(topFrac, 0.085f, 0.24f);

                // Safe left margin: clear iPhone notch/Dynamic Island + rounded corner + left Vertical Toolbar if active
                float leftFrac = Math.Max((_safeLeftPx + 22f) / vw, 0.032f);
                if (touchHudVisible && _cfg.VerticalToolbar && _cfg.ToolbarSide == 0 && !_verticalToolbar.Bounds.IsEmpty)
                {
                    float rightOfTb = (_verticalToolbar.Bounds.Right + 14f) / vw;
                    if (rightOfTb > leftFrac)
                        leftFrac = rightOfTb;
                }
                leftFrac = Math.Clamp(leftFrac, 0.025f, 0.35f);

                targetX = tsarea.Left + (int)Math.Round(leftFrac * tsarea.Width);
                targetY = tsarea.Top + (int)Math.Round(topFrac * tsarea.Height);
                return true;
            }
            catch
            {
                return false;
            }
        }

        public bool IsFishingCastButtonHeld()
        {
            if (!Context.IsWorldReady || Game1.player == null ||
                Game1.activeClickableMenu != null || !CanUseToolInCurrentState() || Game1.dialogueUp || Game1.paused ||
                Game1.currentMinigame != null || _editMode || _saveMenuOpen || _guiHidden)
                return false;

            var ext = ModEntry.ExternalInput;
            if (ext != null && ext.IsExternalDeviceActive)
            {
                if (ext.IsPhysicalGamepadActive && ext.CurrentGamePadState.Buttons.X == ButtonState.Pressed)
                    return true;
                if (ext.IsExternalMouseActive && ext.CurrentMouseState.LeftButton == ButtonState.Pressed)
                    return true;
                if (ext.HasPhysicalKeysPressed)
                {
                    var pk = ext.PhysicalKeys;
                    for (int i = 0; i < pk.Count; i++)
                    {
                        if (pk[i] == Keys.C || pk[i] == Keys.Space)
                            return true;
                    }
                }
            }

            if (IsMobileModeActive)
            {
                if (_toolPressed || _tapChargingTool)
                    return true;
                if (_gamepadHideHud && _hasPhysicalGamePadState && _lastPhysicalGamePadState.Buttons.X == ButtonState.Pressed)
                    return true;
                return false;
            }

            // VirtualGamepad mode (handled directly by SDViOSTouchControls.TouchVirtualPad)
            if (_lastPadObj != null)
            {
                var br = EnsureBridge(_lastPadObj);
                if (br != null && br.GetButtonX(_lastPadObj))
                    return true;
            }
            return false;
        }

        public void ResetGameplayState()
        {
            _joyTouchId = -1;
            _joyActivated = false;
            _toolTouchId = -1;
            _interactTouchId = -1;
            _toolPressed = false;
            _interactPressed = false;
            _prevInteractPressed = false;
            _suppressActUntilRelease = false;
            _actionPulseXFrames = 0;
            _actionPulseAFrames = 0;
            _holdSweepCooldown = 0;
            _warpPushStartHudCount = 0;
            _pinching = false;
            _pinchIdA = -1;
            _pinchIdB = -1;
            _tapTouchId = -1;
            _holdWalking = false;
            _tapChargingTool = false;
            _tapHoldSwinging = false;
            _tapHoldCooldown = 0;
            _tapPressIntentComputed = false;
            _smoothedStick = Vector2.Zero;
            _hystAxisX = 0;
            _hystAxisY = 0;
            _slingshotTouchId = -1;
            _toolbarTouchId = -1;
            _toolbarTappedSlot = -1;
            _toolbarSwiped = false;
            _verticalToolbar.ResetTouch();
            _repeatActive = false;
            _repeatCooldown = 0;
            _repeatSwings = 0;
            _repeatNoProgressSwings = 0;
            _repeatObservedSwing = false;
            _repeatLastHealth = -1f;
            _unstickHoldTicks = 0;
            _unstickStillTicks = 0;
            _fishBendTouchId = -1;
            _fishBendX = 0f;
            _hideTapTouchId = -1;
            _minigamePad.Reset();
            ClearPath();
        }

        private static IClickableMenu GetTopmostMenu(IClickableMenu root)
        {
            IClickableMenu cur = root;
            if (cur is TitleMenu && TitleMenu.subMenu != null)
                cur = TitleMenu.subMenu;
            int guard = 0;
            while (cur != null && guard++ < 8)
            {
                IClickableMenu child = null;
                try { child = cur.GetChildMenu(); } catch { }
                if (child == null) break;
                cur = child;
            }
            return cur;
        }

        private static bool IsThirdPartyModMenu(IClickableMenu menu)
        {
            if (menu == null) return false;
            try { return menu.GetType().Assembly != typeof(Game1).Assembly; } catch { return false; }
        }

        public static bool IsSkippableCutsceneActive()
        {
            if (!Game1.eventUp) return false;
            if (Game1.activeClickableMenu != null && !(Game1.activeClickableMenu is DialogueBox))
                return false;
            try
            {
                var ev = Game1.CurrentEvent;
                return ev != null && ev.skippable && !ev.skipped && !ev.isFestival;
            }
            catch { return false; }
        }

        private static void ExecuteCutsceneSkip()
        {
            try
            {
                var ev = Game1.CurrentEvent;
                if (ev != null && ev.skippable && !ev.skipped)
                {
                    ev.skipped = true;
                    ev.skipEvent();
                    Game1.freezeControls = false;
                }
            }
            catch { }
            try { Game1.playSound("bigDeSelect"); } catch { }
        }

        public bool TryHandleSkipCutsceneTap(object pad, TouchCollection touches)
        {
            if (!IsSkippableCutsceneActive() || touches.Count == 0 || !RefreshViewport())
                return false;
            ComputeLayout();
            for (int i = 0; i < touches.Count; i++)
            {
                TouchLocation tl = touches[i];
                if (tl.State == TouchLocationState.Pressed)
                {
                    Vector2 vp = MapRawToViewport(tl.Position);
                    if (_btnSkipEventRect.Contains((int)vp.X, (int)vp.Y))
                    {
                        ExecuteCutsceneSkip();
                        _ctxTouchId = tl.Id;
                        ResetMenuTapState();
                        ApplyToPad(pad, Vector2.Zero, false, false, false);
                        return true;
                    }
                }
            }
            return false;
        }

        public void DrawSkipCutsceneButtonOnly(object pad, SpriteBatch sb)
        {
            if (sb == null || sb.GraphicsDevice == null || !IsSkippableCutsceneActive())
                return;
            EnsureTextures(sb.GraphicsDevice);
            if (!RefreshViewport()) return;
            ComputeLayout();
            // Draw Stardew's native Skip Cutscene sprite from Game1.mouseCursors (205, 406, 22, 15)
            // so UI theme packs like Cat Valley UI / Overgrown Flowery Interface render their EXACT native Skip button!
            Texture2D cursors = Game1.mouseCursors;
            if (cursors != null && !cursors.IsDisposed)
            {
                Rectangle src = new Rectangle(205, 406, 22, 15);
                Rectangle shadow = new Rectangle(_btnSkipEventRect.X + 3, _btnSkipEventRect.Y + 3, _btnSkipEventRect.Width, _btnSkipEventRect.Height);
                sb.Draw(cursors, shadow, src, Color.Black * 0.32f);
                sb.Draw(cursors, _btnSkipEventRect, src, Color.White);
                return;
            }
            PixelUi.GlobalOpacity = Math.Max(_cfg.PixelOpacity, 0.85f);
            PixelUi.DrawPixelPill(sb, _pixel, EnsureBridge(pad), _btnSkipEventRect, "SKIP", PixelRole.Special, false, _vpH, -1, 0.96f);
        }

        public void PollPureGamepadKeyboardOnly(object pad, GameTime gameTime)
        {
            var br = EnsureBridge(pad);
            br?.CloseHotkeyDrawer(pad);
            IClickableMenu rawMenu = Game1.activeClickableMenu;
            if (rawMenu == null)
            {
                if (_nativeKbActive)
                    PollNativeKeyboardResult(pad, br);
                _lastKbSubscriber = null;
                return;
            }
            if (PollNativeKeyboardResult(pad, br))
                return;

            double nowSec = gameTime != null ? gameTime.TotalGameTime.TotalSeconds : Environment.TickCount64 / 1000.0;
            IClickableMenu topMenu = GetTopmostMenu(rawMenu);
            if (topMenu is CharacterCustomization cc && RefreshViewport())
            {
                TouchCollection touches = TouchPanel.GetState();
                for (int i = 0; i < touches.Count; i++)
                {
                    if (touches[i].State == TouchLocationState.Pressed)
                    {
                        Point ui = ViewportToUi(MapRawToViewport(touches[i].Position));
                        if (TryTapCharacterCustomizationTextBox(pad, br, cc, ui))
                            return;
                    }
                }
            }
            PollAutoKeyboard(pad, br, nowSec, topMenu);
        }

        private void ClearCustomButtonTouches()
        {
            _customBtnTouchIds.Clear();
            _customBtnsHeldNow.Clear();
        }

        private void TickCustomButtonPulses()
        {
            if (_customBtnPulseFrames.Count == 0)
                return;
            // Decrement remaining pulse frames cleanly without allocating per frame
            for (int i = 0; i < _cfg.CustomKeys.Count; i++)
            {
                int id = _cfg.CustomKeys[i].Id;
                if (_customBtnPulseFrames.TryGetValue(id, out int rem) && rem > 0)
                    _customBtnPulseFrames[id] = rem - 1;
            }
        }

        private void ClearPath()
        {
            _path = null;
            _pathIdx = 0;
            _hasTargetTile = false;
            _pendingIntent = default;
            _hasPendingWarp = false;
            _warpPushFrames = 0;
            _stuckFrames = 0;
            _repeatActive = false;
            _repeatCooldown = 0;
            _repeatSwings = 0;
            _repeatNoProgressSwings = 0;
            _repeatObservedSwing = false;
            _repeatLastHealth = -1f;
        }

        private bool IsInventoryContextMenu(IClickableMenu topMenu)
        {
            if (topMenu == null || IsThirdPartyModMenu(topMenu))
                return false;
            return topMenu is GameMenu || topMenu is ItemGrabMenu || topMenu is ShopMenu || topMenu is JunimoNoteMenu;
        }

        private bool IsTextInputMenu(IClickableMenu topMenu)
        {
            if (topMenu is NamingMenu || topMenu is TitleTextInputMenu || topMenu is CharacterCustomization)
                return true;
            if (Game1.keyboardDispatcher != null && Game1.keyboardDispatcher.Subscriber != null)
                return true;
            return false;
        }

        private static bool EnsureNativeKbResolved()
        {
            if (!_nativeKbResolved)
            {
                _nativeKbResolved = true;
                try
                {
                    IntPtr pShow = MobileDarwinDlsym(new IntPtr(-2), "sdv_kb_show");
                    IntPtr pPoll = MobileDarwinDlsym(new IntPtr(-2), "sdv_kb_poll");
                    IntPtr pAct = MobileDarwinDlsym(new IntPtr(-2), "sdv_kb_is_active");
                    if (pShow != IntPtr.Zero && pPoll != IntPtr.Zero)
                    {
                        _nativeKbShow = Marshal.GetDelegateForFunctionPointer<NativeKbShowDelegate>(pShow);
                        _nativeKbPoll = Marshal.GetDelegateForFunctionPointer<NativeKbPollDelegate>(pPoll);
                        if (pAct != IntPtr.Zero)
                            _nativeKbIsActive = Marshal.GetDelegateForFunctionPointer<NativeKbIsActiveDelegate>(pAct);
                    }
                }
                catch { }
            }
            return _nativeKbShow != null && _nativeKbPoll != null;
        }

        private static void SetHostVkmActiveFlag(bool paused)
        {
            try
            {
                if (!_hostVkmResolved)
                {
                    _hostVkmResolved = true;
                    foreach (Assembly asm in AppDomain.CurrentDomain.GetAssemblies())
                    {
                        if (asm.GetName().Name == "SDViOS")
                        {
                            Type t = asm.GetType("SDViOS.Input.VirtualKeyboardManager", false);
                            _hostVkmActiveField = t?.GetField("_isKeyboardActive", BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public);
                            break;
                        }
                    }
                }
                _hostVkmActiveField?.SetValue(null, paused);
            }
            catch { }
        }

        private static string GuessKeyboardPromptTitle(IKeyboardSubscriber sub, IClickableMenu topMenu)
        {
            if (sub is TextBox tb)
            {
                if (topMenu is CharacterCustomization cc)
                {
                    try
                    {
                        if (ReferenceEquals(tb, CcNameBoxField?.GetValue(cc))) return "Tên nhân vật";
                        if (ReferenceEquals(tb, CcFarmBoxField?.GetValue(cc))) return "Tên nông trại";
                        if (ReferenceEquals(tb, CcFavBoxField?.GetValue(cc))) return "Điều bạn yêu thích";
                    }
                    catch { }
                }
                if (!string.IsNullOrWhiteSpace(tb.TitleText))
                    return tb.TitleText;
            }
            if (topMenu is NamingMenu) return "Nhập tên";
            return "Nhập chữ";
        }

        private void TriggerKeyboardSmart(object pad, PadBridge br, IKeyboardSubscriber explicitSub = null, IClickableMenu topMenu = null)
        {
            IKeyboardSubscriber target = explicitSub ?? Game1.keyboardDispatcher?.Subscriber;

            // On CharacterCustomization, if user tapped the manual KEY pill before tapping a field, pick first empty box (or nameBox)!
            if (target == null && topMenu is CharacterCustomization cc)
            {
                try
                {
                    var nb = CcNameBoxField?.GetValue(cc) as TextBox;
                    var fb = CcFarmBoxField?.GetValue(cc) as TextBox;
                    var vb = CcFavBoxField?.GetValue(cc) as TextBox;
                    if (nb != null && string.IsNullOrWhiteSpace(nb.Text)) target = nb;
                    else if (fb != null && string.IsNullOrWhiteSpace(fb.Text)) target = fb;
                    else if (vb != null && string.IsNullOrWhiteSpace(vb.Text)) target = vb;
                    else target = nb ?? fb ?? vb;
                    if (target is TextBox chosen)
                    {
                        if (nb != null) nb.Selected = ReferenceEquals(nb, chosen);
                        if (fb != null) fb.Selected = ReferenceEquals(fb, chosen);
                        if (vb != null) vb.Selected = ReferenceEquals(vb, chosen);
                        if (Game1.keyboardDispatcher != null) Game1.keyboardDispatcher.Subscriber = chosen;
                    }
                }
                catch { }
            }

            if (EnsureNativeKbResolved())
            {
                string title = GuessKeyboardPromptTitle(target, topMenu);
                string initial = "";
                if (target is TextBox tb)
                {
                    initial = tb.Text ?? "";
                }
                else if (target != null)
                {
                    try
                    {
                        var tp = target.GetType().GetProperty("Text", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                        initial = (tp?.GetValue(target) as string) ?? "";
                    }
                    catch { }
                }

                // Prevent legacy VirtualKeyboardManager from racing or wedging _isKeyboardActive on iOS 26/27!
                SetHostVkmActiveFlag(true);
                int ok = 0;
                try { ok = _nativeKbShow(title, initial); } catch { ok = 0; }
                if (ok != 0)
                {
                    _nativeKbTarget = target;
                    _nativeKbActive = true;
                    _lastKbSubscriber = target;
                    return;
                }
                SetHostVkmActiveFlag(false);
            }

            br?.TriggerVirtualKeyboard(pad);
        }

        private bool PollNativeKeyboardResult(object pad, PadBridge br)
        {
            if (!_nativeKbActive && !(_nativeKbIsActive != null && _nativeKbIsActive() != 0))
                return false;
            if (!EnsureNativeKbResolved())
            {
                _nativeKbActive = false;
                return false;
            }

            int st = 0;
            try { st = _nativeKbPoll(_nativeKbBuf, _nativeKbBuf.Length); } catch { st = 0; }

            if (st == 1)
            {
                _nativeKbActive = true;
                SetHostVkmActiveFlag(true);
                return true; // Native iOS keyboard alert is currently open
            }

            _nativeKbActive = false;
            SetHostVkmActiveFlag(false);
            IKeyboardSubscriber target = _nativeKbTarget ?? Game1.keyboardDispatcher?.Subscriber;
            _nativeKbTarget = null;

            if (st == 2)
            {
                int len = 0;
                while (len < _nativeKbBuf.Length && _nativeKbBuf[len] != 0) len++;
                string text = len > 0 ? Encoding.UTF8.GetString(_nativeKbBuf, 0, len) : string.Empty;
                ApplyNativeKeyboardText(target, text);
            }
            else if (st == 3)
            {
                try
                {
                    if (target != null) target.Selected = false;
                    if (Game1.keyboardDispatcher != null && ReferenceEquals(Game1.keyboardDispatcher.Subscriber, target))
                        Game1.keyboardDispatcher.Subscriber = null;
                }
                catch { }
            }
            _lastAutoKbSec = Environment.TickCount64 / 1000.0;
            br?.ResetVirtualPad(pad);
            return false;
        }

        private static void ApplyNativeKeyboardText(IKeyboardSubscriber target, string text)
        {
            try
            {
                if (target is TextBox tb)
                {
                    tb.Text = text ?? string.Empty;
                    tb.Selected = false;
                    if (Game1.keyboardDispatcher != null && ReferenceEquals(Game1.keyboardDispatcher.Subscriber, tb))
                        Game1.keyboardDispatcher.Subscriber = null;
                    try
                    {
                        if (TextBoxOnEnterField?.GetValue(tb) is Delegate del)
                            del.DynamicInvoke(tb);
                    }
                    catch { }
                    return;
                }
                if (target != null)
                {
                    var tp = target.GetType().GetProperty("Text", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                    if (tp != null && tp.CanWrite)
                    {
                        tp.SetValue(target, text ?? string.Empty);
                    }
                    else if (!string.IsNullOrEmpty(text))
                    {
                        target.RecieveTextInput(text);
                    }
                    target.Selected = false;
                    if (Game1.keyboardDispatcher != null && ReferenceEquals(Game1.keyboardDispatcher.Subscriber, target))
                        Game1.keyboardDispatcher.Subscriber = null;
                    try
                    {
                        var ef = target.GetType().GetField("OnEnterPressed", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
                        if (ef?.GetValue(target) is Delegate del)
                            del.DynamicInvoke(target);
                    }
                    catch { }
                }
            }
            catch { }
        }

        private bool TryTapCharacterCustomizationTextBox(object pad, PadBridge br, CharacterCustomization cc, Point uiPt)
        {
            if (cc == null) return false;
            try
            {
                var nb = CcNameBoxField?.GetValue(cc) as TextBox;
                var fb = CcFarmBoxField?.GetValue(cc) as TextBox;
                var vb = CcFavBoxField?.GetValue(cc) as TextBox;
                TextBox[] boxes = new[] { nb, fb, vb };
                ClickableComponent[] ccs = new[] { cc.nameBoxCC, cc.farmnameBoxCC, cc.favThingBoxCC };

                for (int i = 0; i < boxes.Length; i++)
                {
                    TextBox box = boxes[i];
                    if (box == null) continue;
                    Rectangle r = new Rectangle(box.X - 10, box.Y - 10, box.Width + 20, box.Height + 20);
                    bool hit = r.Contains(uiPt);
                    if (!hit && ccs[i] != null)
                    {
                        Rectangle cr = ccs[i].bounds;
                        hit = new Rectangle(cr.X - 10, cr.Y - 10, cr.Width + 20, cr.Height + 20).Contains(uiPt);
                    }
                    if (!hit) continue;

                    for (int j = 0; j < boxes.Length; j++)
                        if (boxes[j] != null) boxes[j].Selected = (j == i);
                    if (Game1.keyboardDispatcher != null)
                        Game1.keyboardDispatcher.Subscriber = box;
                    try { Game1.playSound("smallSelect"); } catch { }
                    TriggerKeyboardSmart(pad, br, box, cc);
                    return true;
                }
            }
            catch { }
            return false;
        }

        private bool AllowCustomKeysInCurrentMenu()
        {
            var m = Game1.activeClickableMenu;
            if (m == null) return false;
            if (m is BobberBar || m is TitleMenu)
                return false;
            return Context.IsWorldReady;
        }

        private void ResetMenuTapState()
        {
            _menuTapTouchId = -1;
            _menuTapAccumY = 0f;
            _menuTapDragged = false;
            _menuTapImmediateDrag = false;
            _menuTapCameraPan = false;
            _menuTapRightClicked = false;
            _menuDragClampX = -1;
            _modTouchState = ModTouchState.None;
        }

        private void PollAutoKeyboard(object pad, PadBridge br, double nowSec, IClickableMenu topMenu = null)
        {
            if (PollNativeKeyboardResult(pad, br))
                return;
            if (!_cfg.AutoKeyboard)
                return;
            IKeyboardSubscriber cur = Game1.keyboardDispatcher?.Subscriber;
            if (cur == null)
            {
                _lastKbSubscriber = null;
                return;
            }
            if (!ReferenceEquals(cur, _lastKbSubscriber))
            {
                _lastKbSubscriber = cur;
                // On CharacterCustomization or AnimalQueryMenu in touch mode, wait for explicit tap on the TextBox (or KEY/Rename button);
                // Vanilla AnimalQueryMenu constructor sets Subscriber = textBox (with Selected = false), which otherwise pops up rename KB on every cow/chicken inspect!
                if (topMenu is CharacterCustomization ccMenu)
                {
                    bool gpSnappedBox = ModEntry.ExternalInput != null && ModEntry.ExternalInput.IsPhysicalGamepadActive &&
                        ccMenu.currentlySnappedComponent != null &&
                        (ccMenu.currentlySnappedComponent == ccMenu.nameBoxCC ||
                         ccMenu.currentlySnappedComponent == ccMenu.farmnameBoxCC ||
                         ccMenu.currentlySnappedComponent == ccMenu.favThingBoxCC);
                    if (!gpSnappedBox)
                        return;
                }
                else if (topMenu is AnimalQueryMenu)
                {
                    bool gpActive = ModEntry.ExternalInput != null && ModEntry.ExternalInput.IsPhysicalGamepadActive;
                    if (!gpActive && !(cur is TextBox aqmTb && aqmTb.Selected))
                        return;
                }
                if ((nowSec - _lastAutoKbSec) >= 0.45)
                {
                    _lastAutoKbSec = nowSec;
                    TriggerKeyboardSmart(pad, br, cur, topMenu);
                }
            }
        }

        private static bool IsCameraPanMenu(IClickableMenu menu, Point uiPt)
        {
            if (menu is CarpenterMenu cm && cm.onFarm && !cm.freeze)
            {
                if (cm.cancelButton != null && cm.cancelButton.containsPoint(uiPt.X, uiPt.Y)) return false;
                if (cm.okButton != null && cm.okButton.containsPoint(uiPt.X, uiPt.Y)) return false;
                return true;
            }
            if (menu is PurchaseAnimalsMenu pam && pam.onFarm && !pam.freeze && !pam.namingAnimal)
            {
                if (pam.okButton != null && pam.okButton.containsPoint(uiPt.X, uiPt.Y)) return false;
                return true;
            }
            if (menu is AnimalQueryMenu aqm && aqm.movingAnimal)
            {
                if (aqm.okButton != null && aqm.okButton.containsPoint(uiPt.X, uiPt.Y)) return false;
                return true;
            }
            if (menu is RenovateMenu rm)
            {
                bool rmFrozen = false;
                try { if (RenovateFreezeField != null && RenovateFreezeField.GetValue(rm) is bool b) rmFrozen = b; } catch { }
                if (!rmFrozen)
                {
                    if (rm.okButton != null && rm.okButton.containsPoint(uiPt.X, uiPt.Y)) return false;
                    return true;
                }
            }
            if (menu is MuseumMenu mm && !mm.fadeIntoBlack)
            {
                if (mm.okButton != null && mm.okButton.containsPoint(uiPt.X, uiPt.Y)) return false;
                if (mm.inventory != null && mm.inventory.isWithinBounds(uiPt.X, uiPt.Y)) return false;
                return true;
            }
            return false;
        }

        private static CraftingPage GetActiveCraftingPage(IClickableMenu menu)
        {
            if (menu is CraftingPage cp)
                return cp;
            if (menu is GameMenu gm)
            {
                try { return gm.GetCurrentPage() as CraftingPage; } catch { }
            }
            return null;
        }

        private static ClickableTextureComponent FindCraftingRecipeAt(CraftingPage cp, Point uiPt, out CraftingRecipe recipe)
        {
            recipe = null;
            if (cp == null || cp.pagesOfCraftingRecipes == null)
                return null;
            int idx = cp.currentCraftingPage;
            if (idx < 0 || idx >= cp.pagesOfCraftingRecipes.Count)
                return null;
            var page = cp.pagesOfCraftingRecipes[idx];
            if (page == null) return null;
            foreach (var kv in page)
            {
                if (kv.Key != null && kv.Key.containsPoint(uiPt.X, uiPt.Y))
                {
                    recipe = kv.Value;
                    return kv.Key;
                }
            }
            return null;
        }

        private static Furniture GetHeldRotatableFurniture()
        {
            if (Game1.player?.ActiveObject is Furniture f && f.rotations != null && f.rotations.Value > 1)
                return f;
            return null;
        }

        private static bool LocationHasAnyMonster(GameLocation loc)
        {
            if (loc?.characters == null) return false;
            for (int i = 0; i < loc.characters.Count; i++)
            {
                if (loc.characters[i] is StardewValley.Monsters.Monster)
                    return true;
            }
            return false;
        }

        private MeleeWeapon GetHeldSpecialWeapon()
        {
            if (!_cfg.ShowSpecButton || Game1.player?.CurrentTool is not MeleeWeapon mw || mw.isScythe())
                return null;

            var loc = Game1.currentLocation;
            bool combatCtx = (EffectiveMode == MobileControlMode.TapToMove || EffectiveMode == MobileControlMode.TapAndJoystick) ||
                             loc is MineShaft ||
                             loc is VolcanoDungeon ||
                             loc is SlimeHutch ||
                             loc is Woods ||
                             loc is BugLand ||
                             LocationHasAnyMonster(loc);
            return combatCtx ? mw : null;
        }

        private static bool IsWeaponSpecialOnCooldown(MeleeWeapon mw)
        {
            if (mw == null) return true;
            if (mw.isOnSpecial) return true;
            if (mw.type.Value == MeleeWeapon.dagger) return MeleeWeapon.daggerCooldown > 0;
            if (mw.type.Value == MeleeWeapon.club) return MeleeWeapon.clubCooldown > 0;
            return MeleeWeapon.defenseCooldown > 0;
        }

        public void OnUpdateTickedGlobal()
        {
            _cfg.PollReload();
            ApplyLiveUiScaleAndWeather();

            if (Context.IsWorldReady)
            {
                if (_worldReadyTicks < 300) _worldReadyTicks++;
            }
            else
            {
                _worldReadyTicks = 0;
            }

            // 1. Auto-Pause when user pulls Notification/Control Center or switches app (singleplayer only, skips first 3s after world load!)
            // ALWAYS consume the flag even when disabled so turning AutoPause back ON later never triggers a stale pause!
            bool hasPauseFlag = _cfg.ConsumePauseFlag();
            if (_cfg.AutoPauseOnBackground && hasPauseFlag)
            {
                if (_worldReadyTicks >= 180 && Context.IsWorldReady && !Context.IsMultiplayer &&
                    Game1.activeClickableMenu == null && !Game1.paused && !Game1.eventUp &&
                    Game1.currentMinigame == null && !_editMode && !_saveMenuOpen)
                {
                    try { Game1.activeClickableMenu = new GameMenu(false); } catch { }
                }
            }

            // 2. Optional light iOS Haptic tap on fish bite edge (FishingRod.isNibbling false -> true)
            bool nibblingNow = Context.IsWorldReady && Game1.player?.CurrentTool is FishingRod fr && fr.isNibbling;
            if (nibblingNow && !_wasFishNibbling && _cfg.FishingHaptic)
                _cfg.TriggerFishBiteHaptic();
            _wasFishNibbling = nibblingNow;

            // 3. Vertical Scrollable Toolbar visibility sync & HIDE GUI cleanup on Menu / Cutscene / Return to Title!
            if (Context.IsWorldReady)
            {
                if (_guiHidden && (Game1.activeClickableMenu != null || IsBlockingCutsceneActive() || Game1.currentMinigame != null))
                    SetGuiHidden(false);
                _verticalToolbar.SyncHorizontalToolbarVisibility(IsMobileModeActive && ((_cfg.VerticalToolbar && (!_gamepadHideHud || _editMode)) || _guiHidden));
            }
            else
            {
                SetGuiHidden(false);
                _inCombatAutoSwitched = false;
                _combatManualOverrideLoc = null;
                _gamepadHideHud = false;
                _hasPhysicalGamePadState = false;
                _verticalToolbar.ClearCachedToolbar();
            }

            // 4. Safe Area Notch/Dynamic Island padding for DayTimeMoneyBox (live bidirectional!)
            ApplySafeAreaToDayTimeMoneyBox();

            // 4b. Sync In-Game Menu FPS preference (60 FPS default vs 30 FPS battery saver) + Native Mod Garden 60/120 FPS pause bridge
            _bridge?.SyncMenuFrameThrottling(_cfg.MenuFps30);
            ModEntry.SyncNativeMultiplayerFlag(Context.IsMultiplayer);
            bool nativeGardenOpen = ModEntry.IsNativeGardenOpen();
            if (nativeGardenOpen)
            {
                // In Multiplayer Co-op the CADisplayLink keeps ticking for network sync; suppress hidden OpenGL draw behind Mod Garden!
                try { GameRunner.instance?.SuppressDraw(); } catch { }
                _wasNativeGardenOpen = true;
                return;
            }
            if (_wasNativeGardenOpen)
            {
                _wasNativeGardenOpen = false;
                try { GameRunner.instance?.ResetElapsedTime(); } catch { }
            }

            // 5. Optional Battery Saver FPS render cap (1 = 30 FPS [draw 1/2], 2 = 45 FPS [draw 3/4]; preserves 100% 60Hz logic speed; auto-suspends for Fishing/minigames/fades!)
            bool fishingCastAnim = Context.IsWorldReady && Game1.player?.CurrentTool is FishingRod frCast && (frCast.isTimingCast || frCast.isCasting);
            bool menuAlreadyAt30 = _cfg.MenuFps30 && Game1.activeClickableMenu != null && !(Game1.activeClickableMenu is BobberBar);
            int ecoMode = _cfg.BatterySaverFpsMode;
            if (ecoMode > 0 &&
                !menuAlreadyAt30 &&
                !_editMode && !_saveMenuOpen &&
                !fishingCastAnim &&
                Game1.currentMinigame == null &&
                !(Game1.activeClickableMenu is BobberBar) &&
                !Game1.fadeToBlack)
            {
                _saverFrameCounter++;
                bool skipDraw = (ecoMode == 1)
                    ? ((_saverFrameCounter & 1) == 1)
                    : ((_saverFrameCounter & 3) == 0); // 45 FPS: skip 1 of every 4 render frames (draws 3/4 = 45 FPS)
                if (skipDraw)
                {
                    try { GameRunner.instance?.SuppressDraw(); } catch { }
                }
            }
            else
            {
                _saverFrameCounter = 0;
            }
        }

        private void ApplySafeAreaToDayTimeMoneyBox()
        {
            if (!Context.IsWorldReady || Game1.dayTimeMoneyBox == null || _vpW <= 0)
                return;
            int rightPadVp = ComputeSafeRightPx();
            if (IsMobileModeActive && _cfg.VerticalToolbar && _cfg.ToolbarSide == 1 && !_guiHidden && _verticalToolbar.Bounds.Width > 0)
            {
                int tbRightNeed = (_vpW - _verticalToolbar.Bounds.Left) + 10;
                if (tbRightNeed > rightPadVp) rightPadVp = tbRightNeed;
            }
            if (rightPadVp == 0 && _lastAppliedSafeRightPad == 0)
                return;
            try
            {
                int uiW = Game1.uiViewport.Width;
                if (uiW <= 0) return;
                float padUi = rightPadVp * (uiW / (float)_vpW);
                float targetX = Math.Max(0f, uiW - 300f - padUi);
                if (rightPadVp != _lastAppliedSafeRightPad || Game1.dayTimeMoneyBox.position.X > targetX)
                {
                    Game1.dayTimeMoneyBox.position.X = targetX;
                    _lastAppliedSafeRightPad = rightPadVp;
                }
            }
            catch { }
        }

        private int ComputeSafeLeftPx()
        {
            if (_cfg.SafePaddingPx >= 0) return _cfg.SafePaddingPx;
            return (int)Math.Round(_cfg.NativeSafeLeftFrac * _vpW);
        }

        private int ComputeSafeRightPx()
        {
            if (_cfg.SafePaddingPx >= 0) return _cfg.SafePaddingPx;
            return (int)Math.Round(_cfg.NativeSafeRightFrac * _vpW);
        }

        private void CycleControlMode(double nowSec)
        {
            MobileControlMode cur = EffectiveMode;
            MobileControlMode next = cur switch
            {
                MobileControlMode.InvisibleJoystick2Btn => MobileControlMode.VisibleJoystick2Btn,
                MobileControlMode.VisibleJoystick2Btn => MobileControlMode.TapToMove,
                MobileControlMode.TapToMove => MobileControlMode.TapAndJoystick,
                _ => MobileControlMode.InvisibleJoystick2Btn
            };
            _cfg.Mode = next;
            _inCombatAutoSwitched = false;
            _combatManualOverrideLoc = Game1.currentLocation?.NameOrUniqueName;
            _cfg.Save();
            string name = next switch
            {
                MobileControlMode.InvisibleJoystick2Btn => "VO HINH",
                MobileControlMode.VisibleJoystick2Btn => "2 NUT",
                MobileControlMode.TapToMove => "CHAM DI",
                _ => "KET HOP"
            };
            ShowSaveToast("DIEU KHIEN: " + name, nowSec);
            try { Game1.playSound("smallSelect"); } catch { }
        }

        private void UpdateAutoCombatMode(double nowSec)
        {
            if (!_cfg.AutoCombatMode)
            {
                if (_inCombatAutoSwitched)
                {
                    _inCombatAutoSwitched = false;
                    ShowSaveToast("CHE DO CU", nowSec);
                }
                _combatManualOverrideLoc = null;
                return;
            }
            string curLoc = Game1.currentLocation?.NameOrUniqueName;
            bool isDungeon = Game1.currentLocation is MineShaft || Game1.currentLocation is VolcanoDungeon;
            if (!isDungeon)
            {
                _combatManualOverrideLoc = null;
                if (_inCombatAutoSwitched)
                {
                    _inCombatAutoSwitched = false;
                    ShowSaveToast("RA NGOAI: CHE DO CU", nowSec);
                }
                return;
            }

            // Inside MineShaft / VolcanoDungeon: keep runtime Joystick override active (immune to _cfg.Reload()!)
            if (!_inCombatAutoSwitched && _cfg.Mode == MobileControlMode.TapToMove &&
                !string.Equals(_combatManualOverrideLoc, curLoc, StringComparison.Ordinal))
            {
                _inCombatAutoSwitched = true;
                ShowSaveToast("VAO MO: TU DONG JOYSTICK", nowSec);
            }
        }

        private bool TryReadPhysicalGamePad(out GamePadState gs)
        {
            gs = default;
            if (GamePadPlatformGetStateMethod == null)
                return false;
            try
            {
                object res = GamePadPlatformGetStateMethod.Invoke(null, GamePadPlatformArgs);
                if (res is GamePadState state && state.IsConnected)
                {
                    gs = state;
                    return true;
                }
            }
            catch { }
            return false;
        }

        public void OnExternalInputModeChanged(ExternalInputMode mode)
        {
            double nowSec = Environment.TickCount64 / 1000.0;
            if (mode == ExternalInputMode.Gamepad)
            {
                ResetGameplayState();
                _gamepadHideHud = _cfg.AutoHideOnGamepad && !_editMode && !_saveMenuOpen;
                ShowSaveToast("TAY CAM NGOAI (FULL)", nowSec);
            }
            else if (mode == ExternalInputMode.KeyboardMouse)
            {
                ResetGameplayState();
                _gamepadHideHud = _cfg.AutoHideOnGamepad && !_editMode && !_saveMenuOpen;
                ShowSaveToast("BAN PHIM / CHUOT NGOAI", nowSec);
            }
            else
            {
                _gamepadHideHud = false;
            }
        }

        private void PollGamepadAutoHide(int touchCount)
        {
            var ext = ModEntry.ExternalInput;
            if (ext != null)
            {
                ext.PollFrame(touchCount);
                _hasPhysicalGamePadState = ext.IsPhysicalGamepadActive;
                if (_hasPhysicalGamePadState)
                    _lastPhysicalGamePadState = ext.CurrentGamePadState;
                _gamepadHideHud = _cfg.AutoHideOnGamepad && ext.IsExternalDeviceActive && touchCount == 0 && !_editMode && !_saveMenuOpen;
                return;
            }

            if (!_cfg.AutoHideOnGamepad)
            {
                _gamepadHideHud = false;
                _hasPhysicalGamePadState = false;
                return;
            }
            if (touchCount > 0)
            {
                _gamepadHideHud = false;
                _hasPhysicalGamePadState = false;
                return;
            }
            // Poll every frame while physical controller is actively driving gameplay; every 10 frames while idle
            if (!_gamepadHideHud && ++_gamepadPollCounter < 10)
                return;
            _gamepadPollCounter = 0;

            if (!TryReadPhysicalGamePad(out GamePadState gs))
            {
                _gamepadHideHud = false;
                _hasPhysicalGamePadState = false;
                return;
            }

            _lastPhysicalGamePadState = gs;
            _hasPhysicalGamePadState = true;
            bool used =
                gs.ThumbSticks.Left.LengthSquared() > 0.08f ||
                gs.ThumbSticks.Right.LengthSquared() > 0.08f ||
                gs.Triggers.Left > 0.2f || gs.Triggers.Right > 0.2f ||
                gs.Buttons.A == ButtonState.Pressed || gs.Buttons.B == ButtonState.Pressed ||
                gs.Buttons.X == ButtonState.Pressed || gs.Buttons.Y == ButtonState.Pressed ||
                gs.Buttons.LeftShoulder == ButtonState.Pressed || gs.Buttons.RightShoulder == ButtonState.Pressed ||
                gs.Buttons.Start == ButtonState.Pressed ||
                gs.DPad.Up == ButtonState.Pressed || gs.DPad.Down == ButtonState.Pressed ||
                gs.DPad.Left == ButtonState.Pressed || gs.DPad.Right == ButtonState.Pressed;
            if (used)
                _gamepadHideHud = true;
        }

        private static bool IsEscOnlyMenu(IClickableMenu menu)
        {
            if (menu == null) return false;
            if (menu is DialogueBox || menu is LetterViewerMenu || menu is BobberBar || menu is TitleMenu || menu is EmoteMenu)
                return false;
            // Never show ESC during end-of-day saving/shipping, multiplayer ready checks, or compulsory naming dialogs
            if (menu is SaveGameMenu || menu is ShippingMenu || menu is ReadyCheckDialog || menu is NamingMenu)
                return false;
            // Never show ESC over a Level 5/10 profession chooser (prevents accidentally skipping professions!)
            if (menu is LevelUpMenu lum && lum.isProfessionChooser)
                return false;
            // Show top-left ESC pill on ALL PC/Mod menus (GMCM, CJB, Lookup Anything, Forge, Tailoring, Museum, Carpenter, QuestLog, etc.)!
            return true;
        }

        private void ApplyLiveUiScaleAndWeather()
        {
            if (Game1.options != null)
            {
                if (_cfg.UiScaleOverride >= 0.75f)
                {
                    if (!_appliedUiScaleOverride)
                    {
                        _origDesiredUiScale = Game1.options.desiredUIScale > 0.1f ? Game1.options.desiredUIScale : 1.0f;
                        _appliedUiScaleOverride = true;
                    }
                    if (Math.Abs(Game1.options.desiredUIScale - _cfg.UiScaleOverride) > 0.01f)
                        Game1.options.desiredUIScale = _cfg.UiScaleOverride;
                }
                else if (_appliedUiScaleOverride)
                {
                    _appliedUiScaleOverride = false;
                    if (Math.Abs(Game1.options.desiredUIScale - _origDesiredUiScale) > 0.01f)
                        Game1.options.desiredUIScale = _origDesiredUiScale;
                }
                if (IsMobileModeActive && Game1.options.alwaysShowToolHitLocation != _cfg.ShowToolHitLocation)
                    Game1.options.alwaysShowToolHitLocation = _cfg.ShowToolHitLocation;
            }

            if (_cfg.ReduceWeather && ++_weatherTickCounter >= 30)
            {
                _weatherTickCounter = 0;
                try
                {
                    var dw = Game1.debrisWeather;
                    if (dw != null && dw.Count > 24)
                        dw.RemoveRange(24, dw.Count - 24);
                }
                catch { }
            }
        }

        private static FieldInfo _syncInputCurMouseField;
        private static FieldInfo _syncSInputMouseField;
        private static bool _syncMouseFieldsResolved;

        private void SyncVanillaMouse(Vector2 vp, bool leftDown = false)
        {
            Point rawPt = ViewportToRaw(vp);
            int mx = rawPt.X;
            int my = rawPt.Y;
            try { Game1.setMousePositionRaw(mx, my); } catch { }
            try
            {
                var prev = Game1.oldMouseState;
                var nextMs = new MouseState(
                    mx, my, prev.ScrollWheelValue,
                    leftDown ? ButtonState.Pressed : ButtonState.Released,
                    prev.MiddleButton, prev.RightButton, prev.XButton1, prev.XButton2);
                Game1.oldMouseState = nextMs;
                Game1.lastCursorMotionWasMouse = true;
                if (Game1.input != null)
                {
                    if (!_syncMouseFieldsResolved)
                    {
                        _syncMouseFieldsResolved = true;
                        const BindingFlags bf = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
                        _syncInputCurMouseField = typeof(InputState).GetField("_currentMouseState", bf);
                        _syncSInputMouseField = Game1.input.GetType().GetField("<MouseState>k__BackingField", bf);
                    }
                    _syncInputCurMouseField?.SetValue(Game1.input, nextMs);
                    _syncSInputMouseField?.SetValue(Game1.input, nextMs);
                }
            }
            catch { }
        }

        private static bool TryReturnHeldItemToInventoryMenu(MenuWithInventory mwi, Point fallbackUi)
        {
            if (mwi == null || mwi.heldItem == null)
                return true;
            try
            {
                if (Game1.player != null && Game1.player.addItemToInventoryBool(mwi.heldItem))
                {
                    mwi.heldItem = null;
                    return true;
                }
                if (fallbackUi.X > 0 || fallbackUi.Y > 0)
                    mwi.receiveLeftClick(fallbackUi.X, fallbackUi.Y, false);
                if (mwi.heldItem != null && Game1.player != null)
                {
                    Game1.createItemDebris(mwi.heldItem, Game1.player.getStandingPosition(), Game1.player.FacingDirection, Game1.currentLocation);
                    mwi.heldItem = null;
                }
            }
            catch { }
            return mwi.heldItem == null;
        }

        private static bool TryAutoPlaceCraftStation(IClickableMenu activeMenu, Point ui)
        {
            if (activeMenu is ForgeMenu fm)
            {
                if (fm.IsBusy())
                    return true;
                if (fm.heldItem == null &&
                    ((fm.leftIngredientSpot != null && fm.leftIngredientSpot.item != null && fm.leftIngredientSpot.containsPoint(ui.X, ui.Y)) ||
                     (fm.rightIngredientSpot != null && fm.rightIngredientSpot.item != null && fm.rightIngredientSpot.containsPoint(ui.X, ui.Y)) ||
                     (fm.craftResultDisplay != null && fm.craftResultDisplay.item != null && fm.craftResultDisplay.containsPoint(ui.X, ui.Y))))
                {
                    try
                    {
                        fm.receiveLeftClick(ui.X, ui.Y, true);
                        TryReturnHeldItemToInventoryMenu(fm, Point.Zero);
                        return true;
                    }
                    catch { }
                }
                if (fm.inventory != null && fm.inventory.isWithinBounds(ui.X, ui.Y) && fm.heldItem == null)
                {
                    try
                    {
                        fm.receiveLeftClick(ui.X, ui.Y, true);
                        if (fm.heldItem != null)
                        {
                            if (fm.leftIngredientSpot != null && fm.leftIngredientSpot.item == null)
                                fm.receiveLeftClick(fm.leftIngredientSpot.bounds.Center.X, fm.leftIngredientSpot.bounds.Center.Y, true);
                            if (fm.heldItem != null && fm.rightIngredientSpot != null && fm.rightIngredientSpot.item == null)
                                fm.receiveLeftClick(fm.rightIngredientSpot.bounds.Center.X, fm.rightIngredientSpot.bounds.Center.Y, true);
                            if (fm.heldItem != null)
                                TryReturnHeldItemToInventoryMenu(fm, ui);
                        }
                        return true;
                    }
                    catch { }
                }
            }
            if (activeMenu is TailoringMenu tm)
            {
                if (tm.IsBusy())
                    return true;
                if (tm.heldItem == null &&
                    ((tm.leftIngredientSpot != null && tm.leftIngredientSpot.item != null && tm.leftIngredientSpot.containsPoint(ui.X, ui.Y)) ||
                     (tm.rightIngredientSpot != null && tm.rightIngredientSpot.item != null && tm.rightIngredientSpot.containsPoint(ui.X, ui.Y)) ||
                     (tm.craftResultDisplay != null && tm.craftResultDisplay.item != null && tm.craftResultDisplay.containsPoint(ui.X, ui.Y))))
                {
                    try
                    {
                        tm.receiveLeftClick(ui.X, ui.Y, true);
                        TryReturnHeldItemToInventoryMenu(tm, Point.Zero);
                        return true;
                    }
                    catch { }
                }
                if (tm.inventory != null && tm.inventory.isWithinBounds(ui.X, ui.Y) && tm.heldItem == null)
                {
                    try
                    {
                        tm.receiveLeftClick(ui.X, ui.Y, true);
                        if (tm.heldItem != null)
                        {
                            if (tm.leftIngredientSpot != null && tm.leftIngredientSpot.item == null)
                                tm.receiveLeftClick(tm.leftIngredientSpot.bounds.Center.X, tm.leftIngredientSpot.bounds.Center.Y, true);
                            if (tm.heldItem != null && tm.rightIngredientSpot != null && tm.rightIngredientSpot.item == null)
                                tm.receiveLeftClick(tm.rightIngredientSpot.bounds.Center.X, tm.rightIngredientSpot.bounds.Center.Y, true);
                            if (tm.heldItem != null)
                                TryReturnHeldItemToInventoryMenu(tm, ui);
                        }
                        return true;
                    }
                    catch { }
                }
            }
            if (activeMenu is GeodeMenu gm && gm.inventory != null && gm.inventory.isWithinBounds(ui.X, ui.Y) && gm.heldItem == null && !gm.waitingForServerResponse && gm.geodeAnimationTimer <= 0)
            {
                try
                {
                    gm.receiveLeftClick(ui.X, ui.Y, true);
                    if (gm.heldItem != null && gm.geodeSpot != null)
                    {
                        gm.receiveLeftClick(gm.geodeSpot.bounds.Center.X, gm.geodeSpot.bounds.Center.Y, true);
                        if (gm.heldItem != null)
                            gm.receiveLeftClick(ui.X, ui.Y, true); // Return cleanly if bag full / <25g
                    }
                    return true;
                }
                catch { }
            }
            if (activeMenu is DyeMenu dm && dm.inventory != null && dm.inventory.isWithinBounds(ui.X, ui.Y) && dm.heldItem == null && !dm.IsBusy())
            {
                try
                {
                    dm.receiveLeftClick(ui.X, ui.Y, true);
                    if (dm.heldItem != null)
                    {
                        int potIdx = dm.GetPotIndex(dm.heldItem);
                        if (potIdx >= 0 && dm.dyePots != null && potIdx < dm.dyePots.Count)
                        {
                            var pot = dm.dyePots[potIdx];
                            dm.receiveLeftClick(pot.bounds.Center.X, pot.bounds.Center.Y, true);
                        }
                        if (dm.heldItem != null)
                            dm.receiveLeftClick(ui.X, ui.Y, true);
                    }
                    return true;
                }
                catch { }
            }
            if (activeMenu is StorageContainer sc && sc.heldItem == null)
            {
                bool inInv = sc.inventory != null && sc.inventory.isWithinBounds(ui.X, ui.Y);
                bool inGrab = sc.ItemsToGrabMenu != null && sc.ItemsToGrabMenu.isWithinBounds(ui.X, ui.Y);
                if (inInv || inGrab)
                {
                    try
                    {
                        InventoryMenu destMenu = inInv ? sc.ItemsToGrabMenu : sc.inventory;
                        // In Fair Grange Display (9 slots), pick up 1 item from backpack so stacks aren't dumped into 1 slot
                        if (inInv && destMenu != null && destMenu.capacity == 9)
                        {
                            sc.receiveRightClick(ui.X, ui.Y, true);
                            if (sc.heldItem == null)
                                sc.receiveLeftClick(ui.X, ui.Y, true);
                        }
                        else
                        {
                            sc.receiveLeftClick(ui.X, ui.Y, true);
                        }

                        if (sc.heldItem != null && destMenu?.inventory != null && destMenu.actualInventory != null)
                        {
                            int lim = Math.Min(destMenu.inventory.Count, destMenu.capacity);
                            // 1. Stack onto matching partial slot first (when transferring back to backpack or non-Grange container)
                            if (!(inInv && destMenu.capacity == 9))
                            {
                                for (int s = 0; s < lim && sc.heldItem != null; s++)
                                {
                                    Item ex = s < destMenu.actualInventory.Count ? destMenu.actualInventory[s] : null;
                                    if (ex != null && ex.canStackWith(sc.heldItem) && ex.Stack < ex.maximumStackSize())
                                    {
                                        Point c = destMenu.inventory[s].bounds.Center;
                                        sc.receiveLeftClick(c.X, c.Y, true);
                                    }
                                }
                            }
                            // 2. Place into first open slot in opposite InventoryMenu (fires StorageContainer.itemChangeBehavior!)
                            for (int s = 0; s < lim && sc.heldItem != null; s++)
                            {
                                Item ex = s < destMenu.actualInventory.Count ? destMenu.actualInventory[s] : null;
                                if (ex == null)
                                {
                                    Point c = destMenu.inventory[s].bounds.Center;
                                    sc.receiveLeftClick(c.X, c.Y, true);
                                    break;
                                }
                            }
                        }

                        // Return safely to source slot if target container is full or rejected item
                        if (sc.heldItem != null)
                            sc.receiveLeftClick(ui.X, ui.Y, false);
                    }
                    catch { }
                    return true;
                }
            }
            if (activeMenu is FieldOfficeMenu fom && fom.inventory != null && fom.inventory.isWithinBounds(ui.X, ui.Y) && fom.heldItem == null)
            {
                try
                {
                    fom.receiveLeftClick(ui.X, ui.Y, true);
                    if (fom.heldItem != null)
                        fom.receiveLeftClick(ui.X, ui.Y, true); // Never stick non-fossil items on cursor
                    return true;
                }
                catch { }
            }
            return false;
        }

        private static void TryAutoDepositJunimoItem(JunimoNoteMenu jnm, Point ui)
        {
            if (jnm == null || jnm.fromGameMenu) return;
            var prevKb = Game1.oldKBState;
            try
            {
                jnm.performHoverAction(ui.X, ui.Y);
                // Native Shift+Click deposits directly into ONE matching bundle slot in 1.6!
                Game1.oldKBState = new KeyboardState(Keys.LeftShift);
                jnm.receiveLeftClick(ui.X, ui.Y, true);
                Game1.oldKBState = prevKb;

                // Fallback: if still held on cursor, explicitly click AT MOST ONE empty ingredientSlot
                if (jnm.heldItem != null && jnm.ingredientSlots != null)
                {
                    for (int i = 0; i < jnm.ingredientSlots.Count && jnm.heldItem != null; i++)
                    {
                        var slot = jnm.ingredientSlots[i];
                        if (slot != null && slot.item == null)
                        {
                            jnm.receiveLeftClick(slot.bounds.Center.X, slot.bounds.Center.Y, true);
                            if (slot.item != null)
                                break; // Stop after filling 1 slot so duplicate bundle slots (e.g. 2x 99 Wood) aren't consumed in 1 tap!
                        }
                    }
                }
                // Return any remaining heldItem cleanly to player inventory (zero stuck cursor!)
                if (jnm.heldItem != null)
                {
                    if (Game1.player != null && Game1.player.addItemToInventoryBool(jnm.heldItem))
                        jnm.heldItem = null;
                    else
                        jnm.receiveLeftClick(ui.X, ui.Y, false);
                    if (jnm.heldItem != null && Game1.player != null)
                    {
                        Game1.createItemDebris(jnm.heldItem, Game1.player.getStandingPosition(), Game1.player.FacingDirection, Game1.currentLocation);
                        jnm.heldItem = null;
                    }
                }
                jnm.releaseLeftClick(ui.X, ui.Y);
            }
            catch { }
            finally { Game1.oldKBState = prevKb; }
        }

        private static ClickableComponent FindJunimoBundleSlotAt(JunimoNoteMenu jnm, Point ui)
        {
            if (jnm == null || jnm.fromGameMenu || !jnm.specificBundlePage || jnm.inventory?.inventory == null)
                return null;
            for (int i = 0; i < jnm.inventory.inventory.Count; i++)
            {
                var cc = jnm.inventory.inventory[i];
                if (cc != null && cc.containsPoint(ui.X, ui.Y))
                {
                    Item it = (i < jnm.inventory.actualInventory.Count) ? jnm.inventory.actualInventory[i] : null;
                    if (it != null && jnm.HighlightObjects(it))
                        return cc;
                }
            }
            return null;
        }

        private bool TryDirectPetAnimalOrPet(GameLocation loc, Farmer who, Vector2? tapWorldPos, bool onlyIfNoBlockingObject)
        {
            if (loc == null || who == null || !who.CanMove || who.isRidingHorse() ||
                Game1.activeClickableMenu != null || Game1.dialogueUp || Game1.eventUp || Game1.fadeToBlack)
                return false;

            // Never steal Hay placement on a Barn/Coop trough or Hat/ButterflyPowder on Pets
            string activeQid = who.ActiveObject?.QualifiedItemId;
            if (onlyIfNoBlockingObject)
            {
                try
                {
                    Vector2 grabTile = who.GetGrabTile();
                    if (loc.objects != null && loc.objects.TryGetValue(grabTile, out StardewValley.Object gObj) && gObj != null &&
                        (gObj is Chest || gObj.bigCraftable.Value || gObj.readyForHarvest.Value))
                        return false;
                    if (activeQid == "(O)178" && loc is AnimalHouse &&
                        loc.doesTileHaveProperty((int)grabTile.X, (int)grabTile.Y, "Trough", "Back") != null)
                        return false;
                    if (loc.doesTileHaveProperty((int)grabTile.X, (int)grabTile.Y, "Action", "Buildings") != null)
                        return false;
                    Point gp = new Point((int)grabTile.X, (int)grabTile.Y);
                    if (loc.doors != null && loc.doors.ContainsKey(gp))
                        return false;
                    if (loc.characters != null)
                    {
                        Rectangle grabRect = new Rectangle(gp.X * 64, gp.Y * 64, 64, 64);
                        foreach (NPC n in loc.characters)
                        {
                            if (n != null && !(n is StardewValley.Characters.Pet) && n.IsVillager && n.GetBoundingBox().Intersects(grabRect))
                                return false;
                        }
                    }
                }
                catch { }
            }

            Vector2 playerCenter = who.GetBoundingBox().Center.ToVector2();

            // 1. Check unpetted FarmAnimals (supports large 2x2 barn animals, diagonal reach, animals standing on eggs/truffles/hay,
            //    and clears stale non-heart emotes like Zzz so the heart emote ALWAYS renders cleanly!)
            try
            {
                if (loc.Animals != null && loc.Animals.Length > 0)
                {
                    FarmAnimal bestAnimal = null;
                    float bestScore = float.MaxValue;
                    Vector2 grabCenter = who.GetGrabTile() * 64f + new Vector2(32f, 32f);

                    foreach (FarmAnimal animal in loc.Animals.Values)
                    {
                        if (animal == null || animal.wasPet.Value)
                            continue;
                        if (Game1.timeOfDay >= 1900 && !animal.isMoving())
                            continue;

                        Rectangle bb = animal.GetBoundingBox();
                        Vector2 ac = bb.Center.ToVector2();
                        float distToPlayer = Vector2.Distance(playerCenter, ac);
                        if (distToPlayer > (tapWorldPos.HasValue ? 132f : 112f))
                            continue;

                        if (tapWorldPos.HasValue)
                        {
                            Rectangle petBox = animal.GetCursorPetBoundingBox();
                            petBox.Inflate(20, 20);
                            bool hitBox = bb.Contains((int)tapWorldPos.Value.X, (int)tapWorldPos.Value.Y) ||
                                          petBox.Contains((int)tapWorldPos.Value.X, (int)tapWorldPos.Value.Y);
                            float tapDist = Vector2.Distance(ac, tapWorldPos.Value);
                            if (!hitBox && tapDist > 88f)
                                continue;
                            float score = hitBox ? tapDist * 0.25f : tapDist;
                            if (score < bestScore) { bestScore = score; bestAnimal = animal; }
                        }
                        else
                        {
                            float grabDist = Vector2.Distance(ac, grabCenter);
                            if (grabDist > 88f && distToPlayer > 84f)
                                continue;
                            if (grabDist < bestScore) { bestScore = grabDist; bestAnimal = animal; }
                        }
                    }

                    if (bestAnimal != null)
                    {
                        // Clear any non-heart ambient emote (e.g. Zzz) that would silently block Character.doEmote(20)
                        if (bestAnimal.IsEmoting && bestAnimal.CurrentEmote != 20)
                            bestAnimal.IsEmoting = false;
                        bestAnimal.pet(who, false);
                        return true;
                    }
                }
            }
            catch { }

            // 2. Check unpetted Dog / Cat Pet (StardewValley.Characters.Pet)
            try
            {
                if (loc.characters != null && !(who.CurrentItem is Hat) && activeQid != "(O)ButterflyPowder")
                {
                    int today = Game1.Date != null ? Game1.Date.TotalDays : -1;
                    long uid = who.UniqueMultiplayerID;
                    Vector2 grabCenter = who.GetGrabTile() * 64f + new Vector2(32f, 32f);
                    StardewValley.Characters.Pet bestPet = null;
                    float bestScore = float.MaxValue;

                    foreach (NPC npc in loc.characters)
                    {
                        if (!(npc is StardewValley.Characters.Pet pet))
                            continue;
                        if (today >= 0 && pet.lastPetDay != null && pet.lastPetDay.TryGetValue(uid, out int lastDay) && lastDay == today)
                            continue;

                        Rectangle bb = pet.GetBoundingBox();
                        Vector2 pc = bb.Center.ToVector2();
                        float distToPlayer = Vector2.Distance(playerCenter, pc);
                        if (distToPlayer > (tapWorldPos.HasValue ? 128f : 104f))
                            continue;

                        if (tapWorldPos.HasValue)
                        {
                            Rectangle pSprite = new Rectangle(bb.X - 18, bb.Y - 48, bb.Width + 36, bb.Height + 60);
                            bool hitBox = pSprite.Contains((int)tapWorldPos.Value.X, (int)tapWorldPos.Value.Y);
                            float tapDist = Vector2.Distance(pc, tapWorldPos.Value);
                            if (!hitBox && tapDist > 80f)
                                continue;
                            float score = hitBox ? tapDist * 0.25f : tapDist;
                            if (score < bestScore) { bestScore = score; bestPet = pet; }
                        }
                        else
                        {
                            float grabDist = Vector2.Distance(pc, grabCenter);
                            if (grabDist > 84f && distToPlayer > 78f)
                                continue;
                            if (grabDist < bestScore) { bestScore = grabDist; bestPet = pet; }
                        }
                    }

                    if (bestPet != null)
                    {
                        if (bestPet.IsEmoting && bestPet.CurrentEmote != 20)
                            bestPet.IsEmoting = false;
                        who.faceGeneralDirection(bestPet.Position);
                        if (bestPet.checkAction(who, loc))
                            return true;
                    }
                }
            }
            catch { }

            return false;
        }

        private bool TryDirectAdjacentTileTap(Vector2 vp)
        {
            Farmer who = Game1.player;
            GameLocation loc = Game1.currentLocation;
            if (who == null || loc == null) return false;

            Vector2 worldPos = ViewportToWorld(vp);
            // Allow tapping directly on any nearby unpetted FarmAnimal / Pet (even upper body of 2x2 Cows/Pigs!)
            if (TryDirectPetAnimalOrPet(loc, who, worldPos, onlyIfNoBlockingObject: false))
                return true;

            Point tappedTile = new Point((int)Math.Floor(worldPos.X / 64f), (int)Math.Floor(worldPos.Y / 64f));
            Point playerTile = who.TilePoint;
            int cheb = Math.Max(Math.Abs(playerTile.X - tappedTile.X), Math.Abs(playerTile.Y - tappedTile.Y));
            if (cheb > 1) return false;

            TileIntent intent = AutoToolAndCombat.InspectTile(loc, tappedTile, who, _cfg.AutoTool);
            if (intent.Kind != TileActionKind.None)
            {
                Point actionTile = intent.HasResolvedTile ? intent.ResolvedTile : tappedTile;
                TriggerTileIntent(who, actionTile, intent);
                return true;
            }

            // Empty adjacent/diagonal tile: face exact tile and trigger Interact/Place or UseTool!
            Vector2 targetCenter = new Vector2(tappedTile.X * 64f + 32f, tappedTile.Y * 64f + 32f);
            who.faceGeneralDirection(targetCenter);
            if (who.ActiveObject != null)
                _actionPulseAFrames = 2;
            else
                _actionPulseXFrames = 2;
            return true;
        }

        private static bool IsPointNearScrollTrack(Rectangle track, ClickableComponent thumb, Point uiPt, out int centerX)
        {
            centerX = -1;
            Rectangle r = track;
            if (thumb != null && thumb.bounds.Width > 0 && thumb.bounds.Height > 0)
                r = r.IsEmpty ? thumb.bounds : Rectangle.Union(r, thumb.bounds);
            if (r.IsEmpty || r.Height <= 4)
                return false;
            Rectangle hit = new Rectangle(r.X - 28, r.Y - 12, r.Width + 56, r.Height + 24);
            if (hit.Contains(uiPt))
            {
                centerX = r.Center.X;
                return true;
            }
            return false;
        }

        private static bool IsTouchOnOptionsSliderOrBar(List<ClickableComponent> slots, List<OptionsElement> opts, int curIdx, int menuTopY, int menuRightX, Point uiPt)
        {
            // Right-edge scrollbar drag strip (skip top close-X area!)
            if (uiPt.X >= menuRightX - 76 && uiPt.Y >= menuTopY + 64)
                return true;
            if (slots == null || opts == null) return false;
            for (int i = 0; i < slots.Count; i++)
            {
                if (slots[i] != null && slots[i].containsPoint(uiPt.X, uiPt.Y))
                {
                    int oi = curIdx + i;
                    if (oi >= 0 && oi < opts.Count && opts[oi] is OptionsSlider)
                        return true;
                    break;
                }
            }
            return false;
        }

        private static bool IsImmediateDragMenu(IClickableMenu menu, Point uiPt, out int clampDragX)
        {
            clampDragX = -1;
            if (menu is StrengthGame)
                return true;
            if (menu is GameMenu gm)
            {
                try
                {
                    IClickableMenu page = gm.GetCurrentPage();
                    if (page is OptionsPage op)
                        return IsTouchOnOptionsSliderOrBar(op.optionSlots, op.options, op.currentItemIndex, op.yPositionOnScreen, op.xPositionOnScreen + op.width, uiPt);
                    if (page is SocialPage sp)
                        return IsPointNearScrollTrack(sp.scrollBarRunner, sp.scrollBar, uiPt, out clampDragX);
                    if (page is AnimalPage ap)
                        return IsPointNearScrollTrack(ap.scrollBarRunner, ap.scrollBar, uiPt, out clampDragX);
                }
                catch { }
            }
            if (menu is AdvancedGameOptions ago)
            {
                try
                {
                    return IsTouchOnOptionsSliderOrBar(ago.optionSlots, ago.options, ago.currentItemIndex, ago.yPositionOnScreen, ago.xPositionOnScreen + ago.width, uiPt);
                }
                catch { }
            }
            if (menu is CharacterCustomization cc)
            {
                try
                {
                    if ((cc.hairColorPicker != null && cc.hairColorPicker.containsPoint(uiPt.X, uiPt.Y)) ||
                        (cc.eyeColorPicker != null && cc.eyeColorPicker.containsPoint(uiPt.X, uiPt.Y)) ||
                        (cc.pantsColorPicker != null && cc.pantsColorPicker.containsPoint(uiPt.X, uiPt.Y)))
                        return true;
                }
                catch { }
            }
            if (menu is BuildingPaintMenu bpm)
            {
                try
                {
                    if (bpm.activeSlider != null) return true;
                    if (bpm.colorSliderPanel != null && bpm.colorSliderPanel.rectangle.Contains(uiPt))
                        return true;
                }
                catch { }
            }
            if (menu is ShopMenu sm)
            {
                try
                {
                    Rectangle runner = (ShopScrollRunnerField?.GetValue(sm) is Rectangle r) ? r : Rectangle.Empty;
                    return IsPointNearScrollTrack(runner, sm.scrollBar, uiPt, out clampDragX);
                }
                catch { }
            }
            if (menu is LoadGameMenu lgm)
            {
                try
                {
                    Rectangle runner = (LoadGameScrollRunnerField?.GetValue(lgm) is Rectangle r) ? r : Rectangle.Empty;
                    return IsPointNearScrollTrack(runner, lgm.scrollBar, uiPt, out clampDragX);
                }
                catch { }
            }
            if (menu is QuestLog ql)
            {
                try
                {
                    return IsPointNearScrollTrack(ql.scrollBarBounds, ql.scrollBar, uiPt, out clampDragX);
                }
                catch { }
            }
            return false;
        }

        public bool UpdateInMenu(object pad, GameTime gameTime)
        {
            if (_editMode)
                ExitEditLayoutMode();
            _keyPickerOpen = false;
            if (_saveMenuOpen)
                CloseSaveMenu(flushExternal: true);
            _wasInMenu = true;
            ResetGameplayState();
            TickCustomButtonPulses();

            if (!IsMobileModeActive)
            {
                ResetMenuTapState();
                ClearCustomButtonTouches();
                _invShop.Reset();
                _lastMenuMouseRaw = null;
                _simMouseLeftPulseFrames = 0;
                _simMouseRightPulseFrames = 0;
                _gameMenuModClickPulseFrames = 0;
                _gameMenuModClickRawPos = null;
                return false;
            }

            var br = EnsureBridge(pad);
            br?.CloseHotkeyDrawer(pad);
            if (br != null && (br.IsFullScreenModalOpen(pad) || br.IsQuickSaveReloading()))
            {
                ResetMenuTapState();
                return false;
            }

            IClickableMenu rawMenu = Game1.activeClickableMenu;

            // Optional crisp SKIP pixel button during skippable PC cutscenes (Game1.eventUp && activeClickableMenu == null)
            if (rawMenu == null)
            {
                ResetMenuTapState();
                _ctxTouchId = -1;
                _invShop.Reset();
                _lastMenuMouseRaw = null;
                _hasCarpenterPreview = false;
                _gameMenuModClickPulseFrames = 0;
                _gameMenuModClickRawPos = null;

                if (IsSkippableCutsceneActive() && RefreshViewport())
                {
                    ComputeLayout();
                    TouchCollection evTouches = TouchPanel.GetState();
                    int activeEvTouches = CountActiveTouches(evTouches);
                    PollGamepadAutoHide(activeEvTouches);
                    if (ModEntry.ExternalInput != null && ModEntry.ExternalInput.IsExternalDeviceActive && activeEvTouches == 0)
                    {
                        br?.ResetVirtualPad(pad);
                        return true;
                    }
                    Point? evMouse = null;
                    bool evLeft = false;
                    for (int i = 0; i < evTouches.Count; i++)
                    {
                        TouchLocation tl = evTouches[i];
                        Vector2 vp = MapRawToViewport(tl.Position);
                        Point pt = new Point((int)vp.X, (int)vp.Y);
                        if (tl.State == TouchLocationState.Pressed && _btnSkipEventRect.Contains(pt))
                        {
                            ExecuteCutsceneSkip();
                            _ctxTouchId = tl.Id;
                            ApplyToPad(pad, Vector2.Zero, false, false, false);
                            return true;
                        }
                        if (tl.State == TouchLocationState.Pressed || tl.State == TouchLocationState.Moved)
                        {
                            evMouse = ViewportToRaw(vp);
                            evLeft = true;
                        }
                    }
                    EnsureBridge(pad)?.ApplyInputWithMouse(pad, Vector2.Zero, false, false, false, evMouse, evLeft, false, _rawW, _rawH);
                    return true;
                }
                return false;
            }

            // Handle BobberBar (Fishing Minigame) directly with 0ms instant press & 0ms instant release!
            // Bypassing SDViOSTouchControls.HandleBackgroundTouch eliminates its 2-frame sticky
            // `_pointClickHoldFrames` release delay that made the fishing bar feel slippery and overshoot!
            if (rawMenu is BobberBar)
            {
                ResetMenuTapState();
                _invShop.Reset();
                _lastMenuMouseRaw = null;
                _hasCarpenterPreview = false;

                if (!RefreshViewport())
                    return false;

                TouchCollection fishTouches = TouchPanel.GetState();
                int activeFishTouches = CountActiveTouches(fishTouches);
                PollGamepadAutoHide(activeFishTouches);
                if (ModEntry.ExternalInput != null && ModEntry.ExternalInput.IsExternalDeviceActive && activeFishTouches == 0)
                {
                    br?.ResetVirtualPad(pad);
                    return true;
                }
                bool fingerDown = false;
                Point touchPos = new Point(Math.Max(1, _rawW / 2), Math.Max(1, _rawH / 2));
                for (int i = 0; i < fishTouches.Count; i++)
                {
                    TouchLocation ftl = fishTouches[i];
                    if (ftl.State == TouchLocationState.Pressed || ftl.State == TouchLocationState.Moved)
                    {
                        fingerDown = true;
                        touchPos = new Point((int)ftl.Position.X, (int)ftl.Position.Y);
                        break;
                    }
                }
                // Also support physical Bluetooth controller X/A button during BobberBar
                if (!fingerDown && _hasPhysicalGamePadState &&
                    (_lastPhysicalGamePadState.Buttons.X == ButtonState.Pressed || _lastPhysicalGamePadState.Buttons.A == ButtonState.Pressed))
                {
                    fingerDown = true;
                }

                // Drive BOTH MouseState.LeftButton AND ButtonX with zero trailing hold frames!
                EnsureBridge(pad)?.ApplyInputWithMouse(
                    pad,
                    Vector2.Zero,
                    btnX: fingerDown,
                    btnA: false,
                    btnMenu: false,
                    mousePos: touchPos,
                    mouseLeftDown: fingerDown,
                    mouseRightDown: false,
                    rawW: _rawW,
                    rawH: _rawH);
                Game1.lastCursorMotionWasMouse = false;
                return true;
            }

            // Handle TitleMenu cleanly WITHOUT falling back to legacy TouchVirtualPad (whose invisible bottom-left
            // joystick deadzone swallowed the GMCM gear button on iPad & iPhone, and hid CharacterCustomization keyboard!).
            IClickableMenu topMenu = GetTopmostMenu(rawMenu);
            bool isThirdParty = IsThirdPartyModMenu(topMenu);
            bool isRootTitleScreen = (rawMenu is TitleMenu && TitleMenu.subMenu == null);

            if (!RefreshViewport())
                return false;
            ComputeLayout();

            bool showInvCtx = IsInventoryContextMenu(topMenu);
            bool showKeyOnly = !isRootTitleScreen && !showInvCtx && IsTextInputMenu(topMenu);
            bool showEscOnly = !isRootTitleScreen && !showInvCtx && !showKeyOnly && IsEscOnlyMenu(topMenu);
            bool allowCustomKeys = AllowCustomKeysInCurrentMenu() && !isThirdParty && _cfg.CustomKeys.Count > 0;

            // Single TouchPanel.GetState() read per frame — from here on, ALWAYS return true!
            TouchCollection touches = TouchPanel.GetState();
            int activeMenuTouches = CountActiveTouches(touches);
            // Allow 1-tap SKIP cutscene even while a DialogueBox is on screen (and even while using a gamepad!)
            if (activeMenuTouches > 0 && IsSkippableCutsceneActive())
            {
                for (int i = 0; i < touches.Count; i++)
                {
                    TouchLocation tl = touches[i];
                    if (tl.State == TouchLocationState.Pressed)
                    {
                        Vector2 vp = MapRawToViewport(tl.Position);
                        if (_btnSkipEventRect.Contains((int)vp.X, (int)vp.Y))
                        {
                            ExecuteCutsceneSkip();
                            _ctxTouchId = tl.Id;
                            ResetMenuTapState();
                            _invShop.Reset();
                            ApplyToPad(pad, Vector2.Zero, false, false, false);
                            return true;
                        }
                    }
                }
            }
            PollGamepadAutoHide(activeMenuTouches);
            double nowSec = gameTime != null ? gameTime.TotalGameTime.TotalSeconds : Environment.TickCount64 / 1000.0;
            if (PollNativeKeyboardResult(pad, br))
            {
                // Keep game mouse neutral while native iOS 14-27 keyboard alert is presented
                ApplyToPad(pad, Vector2.Zero, false, false, false);
                return true;
            }
            PollAutoKeyboard(pad, br, nowSec, topMenu);
            if (ModEntry.ExternalInput != null && ModEntry.ExternalInput.IsExternalDeviceActive && activeMenuTouches == 0)
            {
                ResetMenuTapState();
                _invShop.Reset();
                _lastMenuMouseRaw = null;
                _hasCarpenterPreview = false;
                br?.ResetVirtualPad(pad);
                return true;
            }

            // Root Title Screen (NEW / LOAD / CO-OP / EXIT / Bottom-Left GMCM Gear Button / Sound / Language):
            // 100% zero-deadzone touch-to-mouse so GMCM's SMAPI ButtonPressed(MouseLeft) fires on the very first tap!
            if (isRootTitleScreen)
            {
                _invShop.Reset();
                UpdateTitleScreenTouches(pad, touches, nowSec);
                return true;
            }

            // Dedicated LevelUpMenu handler (#GL-LTQ82M):
            // Vanilla LevelUpMenu.receiveLeftClick(x, y, playSound) is completely empty (`ret`)!
            // Both OK button dismissal and Level 5/10 profession cards are handled inside LevelUpMenu.update(GameTime)
            // via live mouse state — handle them directly here so OK and Profession choices ALWAYS respond in 1 tap!
            if (topMenu is LevelUpMenu lumTop && (!showEscOnly || !IsTapInsideEscPill(touches)))
            {
                _invShop.Reset();
                UpdateLevelUpMenuTouches(pad, lumTop, touches, nowSec);
                return true;
            }

            if (!ReferenceEquals(_junimoHoverMenu, topMenu as JunimoNoteMenu))
            {
                _junimoHoverMenu = null;
                _junimoHoveredSlot = null;
            }
            if (!ReferenceEquals(_dlgHoverMenu, topMenu as DialogueBox))
            {
                _dlgHoverMenu = null;
                _dlgHoveredIdx = -1;
            }
            if (!ReferenceEquals(_carpenterPreviewMenu, topMenu as CarpenterMenu) || (topMenu is CarpenterMenu cmChk && (!cmChk.onFarm || cmChk.freeze)))
            {
                _carpenterPreviewMenu = null;
                _hasCarpenterPreview = false;
            }

            // Always consume lingering tap release from BAG/MAP/QST/Emote or HUD Quest button FIRST!
            if (_ctxTouchId >= 0)
            {
                bool sawLingeringTap = false;
                for (int i = 0; i < touches.Count; i++)
                {
                    if (touches[i].Id == _ctxTouchId)
                    {
                        if (touches[i].State == TouchLocationState.Pressed || touches[i].State == TouchLocationState.Moved)
                            sawLingeringTap = true;
                        break;
                    }
                }
                if (sawLingeringTap)
                {
                    ApplyToPad(pad, Vector2.Zero, false, false, false);
                    return true;
                }
                _ctxTouchId = -1;
            }

            // Native EmoteMenu radial wheel: AFTER lingering tap filter, and uses UI coordinates (ViewportToUi -> ModifyCoordinateFromUIScale)!
            if (topMenu is EmoteMenu em)
            {
                em.gamepadMode = false;
                for (int i = 0; i < touches.Count; i++)
                {
                    TouchLocation tl = touches[i];
                    Vector2 vp = MapRawToViewport(tl.Position);
                    Point ui = ViewportToUi(vp);
                    SyncVanillaMouse(vp);
                    if (tl.State == TouchLocationState.Pressed || tl.State == TouchLocationState.Moved)
                    {
                        try { em.performHoverAction(ui.X, ui.Y); } catch { }
                    }
                    else if (tl.State == TouchLocationState.Released)
                    {
                        try { em.performHoverAction(ui.X, ui.Y); } catch { }
                        try { em.receiveLeftClick(ui.X, ui.Y, true); } catch { }
                    }
                }
                ApplyToPad(pad, Vector2.Zero, false, false, false);
                return true;
            }

            // If Mobile Buy/Sell/Split/Crafting Popup is open OR dragging an item, give it top priority!
            if (_invShop.IsPopupOpen || (_cfg.MobileShopAndDrag && _invShop.IsDraggingItem))
            {
                if (_invShop.Update(topMenu, touches, _fnRawToVp, _fnVpToUi, _fnUiToVp, _vpW, _vpH, nowSec))
                {
                    ResetMenuTapState();
                    NeutralizeMenuPad(pad);
                    return true;
                }
            }

            // Handle Custom PC Key Buttons in Inventory / Vanilla Menus
            if (allowCustomKeys)
            {
                bool customConsumed = ProcessCustomKeyTouches(pad, br, touches, nowSec);
                if (customConsumed)
                {
                    ResetMenuTapState();
                    ApplyToPad(pad, Vector2.Zero, false, false, false);
                    return true;
                }
            }
            else
            {
                ClearCustomButtonTouches();
            }

            // 1. Handle taps on Context Helper Bar (Inventory X1/1/2/XFER/KEY/ESC, TextInput KEY, Mod/Other ESC-only)
            if ((showInvCtx || showKeyOnly || showEscOnly) && touches.Count > 0)
            {
                bool sawCtx = false;
                for (int i = 0; i < touches.Count; i++)
                {
                    TouchLocation tl = touches[i];
                    Vector2 vp = MapRawToViewport(tl.Position);
                    Point pt = new Point((int)vp.X, (int)vp.Y);
                    bool active = tl.State == TouchLocationState.Pressed || tl.State == TouchLocationState.Moved;

                    if (tl.Id == _ctxTouchId)
                    {
                        if (active) sawCtx = true;
                        continue;
                    }

                    if (tl.State == TouchLocationState.Pressed)
                    {
                        if (showInvCtx)
                        {
                            if (_cfg.MobileShopAndDrag)
                            {
                                GetMobileInvCtxRects(topMenu, out Rectangle rX1, out Rectangle rHalf, out Rectangle rGop, out Rectangle rXep, out Rectangle rKey, out Rectangle rEsc);
                                if (!rX1.IsEmpty && rX1.Contains(pt)) { _invShop.ToggleTapMode(MobileInventoryShopHelper.ChestTapMode.SingleOne); _ctxTouchId = tl.Id; sawCtx = true; try { Game1.playSound("smallSelect"); } catch { } continue; }
                                if (!rHalf.IsEmpty && rHalf.Contains(pt)) { _invShop.ToggleTapMode(MobileInventoryShopHelper.ChestTapMode.HalfStack); _ctxTouchId = tl.Id; sawCtx = true; try { Game1.playSound("smallSelect"); } catch { } continue; }
                                if (!rGop.IsEmpty && rGop.Contains(pt) && topMenu is ItemGrabMenu grabGop)
                                {
                                    try { grabGop.FillOutStacks(); Game1.playSound("Ship"); } catch { }
                                    _ctxTouchId = tl.Id; sawCtx = true; continue;
                                }
                                if (!rXep.IsEmpty && rXep.Contains(pt) && topMenu is ItemGrabMenu grabXep && grabXep.ItemsToGrabMenu?.actualInventory != null)
                                {
                                    try { ItemGrabMenu.organizeItemsInList(grabXep.ItemsToGrabMenu.actualInventory); Game1.playSound("Ship"); } catch { }
                                    _ctxTouchId = tl.Id; sawCtx = true; continue;
                                }
                                if (!rKey.IsEmpty && rKey.Contains(pt)) { TriggerKeyboardSmart(pad, br, null, topMenu); _ctxTouchId = tl.Id; sawCtx = true; continue; }
                                if (!rEsc.IsEmpty && rEsc.Contains(pt)) { _invShop.Reset(); CloseTopmostMenu(rawMenu, topMenu); _ctxTouchId = tl.Id; sawCtx = true; continue; }
                            }
                            else
                            {
                                if (_ctxX1Rect.Contains(pt)) { br?.ToggleSingleItemMode(pad); _ctxTouchId = tl.Id; sawCtx = true; try { Game1.playSound("smallSelect"); } catch { } continue; }
                                if (_ctxHalfRect.Contains(pt)) { br?.ToggleHalfStackMode(pad); _ctxTouchId = tl.Id; sawCtx = true; try { Game1.playSound("smallSelect"); } catch { } continue; }
                                if (_ctxXferRect.Contains(pt)) { br?.ToggleQuickTransferMode(pad); _ctxTouchId = tl.Id; sawCtx = true; try { Game1.playSound("smallSelect"); } catch { } continue; }
                                if (_ctxKeyRect.Contains(pt)) { TriggerKeyboardSmart(pad, br, null, topMenu); _ctxTouchId = tl.Id; sawCtx = true; continue; }
                                if (_ctxEscRect.Contains(pt)) { _invShop.Reset(); CloseTopmostMenu(rawMenu, topMenu); _ctxTouchId = tl.Id; sawCtx = true; continue; }
                            }
                        }
                        else if (showKeyOnly)
                        {
                            if (_ctxX1Rect.Contains(pt))
                            {
                                TriggerKeyboardSmart(pad, br, null, topMenu);
                                _ctxTouchId = tl.Id;
                                sawCtx = true;
                                continue;
                            }
                            if (_ctxHalfRect.Contains(pt) && topMenu.readyToClose())
                            {
                                CloseTopmostMenu(rawMenu, topMenu);
                                _ctxTouchId = tl.Id;
                                sawCtx = true;
                                continue;
                            }
                        }
                        else if (showEscOnly && _ctxQuestEscRect.Contains(pt))
                        {
                            CloseTopmostMenu(rawMenu, topMenu);
                            _ctxTouchId = tl.Id;
                            sawCtx = true;
                            continue;
                        }
                    }
                }
                if (!sawCtx) _ctxTouchId = -1;
                if (sawCtx)
                {
                    ResetMenuTapState();
                    _simMouseLeftPulseFrames = 0;
                    _simMouseRightPulseFrames = 0;
                    ApplyToPad(pad, Vector2.Zero, false, false, false);
                    return true;
                }
            }

            // 1b. UNIVERSAL 3RD-PARTY MOD MENU ENGINE (GenericModConfigMenu, SpaceCore, CJB, Lookup Anything, Chests Anywhere, BetterGameMenu, StardewUI, etc.)
            // Drives ALL mod menus via TRUE Simulated Mouse (Mouse.GetState / InputState / SMAPI ButtonPressed) + Horizontal Slider Drag + Vertical Swipe Scroll + Long-Press Right-Click!
            if (isThirdParty)
            {
                _menuPadNeutralized = false;
                _invShop.Reset();
                UpdateThirdPartyModMenu(pad, topMenu, touches, nowSec);
                return true;
            }
            if (topMenu is GameMenu gmSub && IsThirdPartyGameMenuPageTap(gmSub, touches))
            {
                _menuPadNeutralized = false;
                _invShop.Reset();
                UpdateThirdPartyModMenu(pad, topMenu, touches, nowSec);
                return true;
            }

            // 2. Mobile-style Shop (Buy/Sell/Dresser) & Inventory/Chest Drag-and-Drop / Tap-to-Transfer / Long-Press Split
            // NEVER let legacy PC split flags kill MobileShopAndDrag when Mobile mode is enabled!
            if (_cfg.MobileShopAndDrag)
            {
                if (_invShop.Update(topMenu, touches, _fnRawToVp, _fnVpToUi, _fnUiToVp, _vpW, _vpH, nowSec))
                {
                    ResetMenuTapState();
                    NeutralizeMenuPad(pad);
                    return true;
                }
            }
            else if (!_invShop.IsPopupOpen)
            {
                _invShop.Reset();
            }

            _menuPadNeutralized = false;
            // 3. Universal Direct Vanilla Menu Touch Handler with Global Mouse Sync!
            if (touches.Count == 0)
            {
                ResetMenuTapState();
                if (_gameMenuModClickPulseFrames > 0)
                {
                    _gameMenuModClickPulseFrames--;
                    Point? pulsePos = _gameMenuModClickRawPos ?? _lastMenuMouseRaw;
                    if (pulsePos.HasValue)
                    {
                        try { Game1.lastCursorMotionWasMouse = true; } catch { }
                    }
                    EnsureBridge(pad)?.ApplyInputWithMouse(pad, Vector2.Zero, false, false, false, pulsePos, true, false, _rawW, _rawH);
                    return true;
                }
                // Keep simulated mouse position at last tapped point in RAW BackBuffer pixels (LeftDown=false) so Carpenter/Museum/Tooltips stay aligned!
                // Clamp away from screen borders when idle in CarpenterMenu/MuseumMenu so vanilla edge-scroll (<64px / >=-128px) never pans uncontrollably!
                Point? idlePos = _lastMenuMouseRaw;
                if ((topMenu is CarpenterMenu cmIdle && cmIdle.onFarm) || topMenu is MuseumMenu)
                {
                    int safeMarginX = Math.Min(192, Math.Max(64, _rawW / 5));
                    int safeMarginY = Math.Min(160, Math.Max(64, _rawH / 5));
                    int baseX = idlePos?.X ?? (_rawW / 2);
                    int baseY = idlePos?.Y ?? (_rawH / 2);
                    Point safePt = new Point(
                        Math.Clamp(baseX, safeMarginX, Math.Max(safeMarginX, _rawW - safeMarginX)),
                        Math.Clamp(baseY, safeMarginY, Math.Max(safeMarginY, _rawH - safeMarginY)));
                    idlePos = safePt;
                    _lastMenuMouseRaw = safePt;
                    try
                    {
                        var prev = Game1.oldMouseState;
                        Game1.oldMouseState = new MouseState(safePt.X, safePt.Y, prev.ScrollWheelValue, ButtonState.Released, prev.MiddleButton, prev.RightButton, prev.XButton1, prev.XButton2);
                    }
                    catch { }
                }
                EnsureBridge(pad)?.ApplyInputWithMouse(pad, Vector2.Zero, false, false, false, idlePos, false, false, _rawW, _rawH);
                return true;
            }

            for (int i = 0; i < touches.Count; i++)
            {
                TouchLocation tl = touches[i];
                Vector2 vp = MapRawToViewport(tl.Position);
                Point ui = ViewportToUi(vp);
                _lastMenuMouseRaw = ViewportToRaw(vp);

                if (tl.State == TouchLocationState.Pressed && _menuTapTouchId < 0)
                {
                    _menuTapTouchId = tl.Id;
                    _menuTapStartVp = vp;
                    _menuTapLastVp = vp;
                    _menuTapLastY = vp.Y;
                    _menuTapAccumY = 0f;
                    _menuTapDragged = false;
                    _menuTapRightClicked = false;
                    _menuTapStartSec = nowSec;
                    _menuTapImmediateDrag = IsImmediateDragMenu(topMenu, ui, out _menuDragClampX);
                    _menuTapCameraPan = !_menuTapImmediateDrag && IsCameraPanMenu(topMenu, ui);

                    int dragUiX = (_menuTapImmediateDrag && _menuDragClampX >= 0) ? _menuDragClampX : ui.X;
                    SyncVanillaMouse(vp, _menuTapImmediateDrag);
                    try { topMenu.performHoverAction(dragUiX, ui.Y); } catch { }
                    if (!_menuTapImmediateDrag)
                        ApplySkillsPageHoverAssist(topMenu, ui);
                    if (_menuTapImmediateDrag)
                    {
                        try { topMenu.receiveLeftClick(dragUiX, ui.Y, true); } catch { }
                    }
                }
                else if (tl.State == TouchLocationState.Moved && tl.Id == _menuTapTouchId)
                {
                    if (_menuTapRightClicked)
                        continue;

                    if (_menuTapImmediateDrag)
                    {
                        int dragUiX = _menuDragClampX >= 0 ? _menuDragClampX : ui.X;
                        SyncVanillaMouse(vp, true);
                        try { topMenu.leftClickHeld(dragUiX, ui.Y); } catch { }
                    }
                    else if (_menuTapCameraPan)
                    {
                        Vector2 delta = vp - _menuTapLastVp;
                        _menuTapLastVp = vp;
                        if (!_menuTapDragged && Vector2.Distance(vp, _menuTapStartVp) >= 16f)
                        {
                            _menuTapDragged = true;
                            _hasCarpenterPreview = false;
                        }
                        if (_menuTapDragged)
                        {
                            int panX = (int)Math.Round(-delta.X * Game1.viewport.Width / Math.Max(1f, _vpW));
                            int panY = (int)Math.Round(-delta.Y * Game1.viewport.Height / Math.Max(1f, _vpH));
                            if (panX != 0 || panY != 0)
                            {
                                try { Game1.panScreen(panX, panY); } catch { }
                            }
                            SyncVanillaMouse(vp, false);
                            try { topMenu.performHoverAction(ui.X, ui.Y); } catch { }
                        }
                    }
                    else
                    {
                        float dy = vp.Y - _menuTapLastY;
                        _menuTapLastY = vp.Y;
                        float totalDist = Vector2.Distance(vp, _menuTapStartVp);
                        float totalDy = Math.Abs(vp.Y - _menuTapStartVp.Y);
                        float dragThresh = Math.Max(22f, _vpH * 0.026f);
                        if (!_menuTapDragged && totalDy >= dragThresh)
                        {
                            _menuTapDragged = true;
                            _menuTapAccumY = vp.Y - _menuTapStartVp.Y;
                        }
                        else if (_menuTapDragged)
                        {
                            _menuTapAccumY += dy;
                        }
                        if (_menuTapDragged)
                        {
                            float step = Math.Max(28f, _vpH * 0.052f);
                            while (Math.Abs(_menuTapAccumY) >= step)
                            {
                                int wheel = _menuTapAccumY > 0 ? 120 : -120;
                                _menuTapAccumY -= Math.Sign(_menuTapAccumY) * step;
                                try { topMenu.receiveScrollWheelAction(wheel); } catch { }
                            }
                        }
                        else if (totalDist < 16f && (nowSec - _menuTapStartSec) >= 0.45 && CanLongPressRightClick(topMenu))
                        {
                            _menuTapRightClicked = true;
                            SyncVanillaMouse(vp, false);
                            try { topMenu.performHoverAction(ui.X, ui.Y); } catch { }
                            try { topMenu.receiveRightClick(ui.X, ui.Y, true); } catch { }
                            try { Game1.playSound("smallSelect"); } catch { }
                        }
                        else
                        {
                            SyncVanillaMouse(vp, false);
                            try { topMenu.performHoverAction(ui.X, ui.Y); } catch { }
                            ApplySkillsPageHoverAssist(topMenu, ui);
                        }
                    }
                }
                else if ((tl.State == TouchLocationState.Released || tl.State == TouchLocationState.Invalid) && tl.Id == _menuTapTouchId)
                {
                    SyncVanillaMouse(vp, false);
                    if (_menuTapRightClicked)
                    {
                        ResetMenuTapState();
                        continue;
                    }
                    if (_menuTapImmediateDrag)
                    {
                        int dragUiX = _menuDragClampX >= 0 ? _menuDragClampX : ui.X;
                        try { topMenu.releaseLeftClick(dragUiX, ui.Y); } catch { }
                    }
                    else if (!_menuTapDragged)
                    {
                        CraftingPage cp = _cfg.SafeCrafting ? GetActiveCraftingPage(topMenu) : null;
                        CraftingRecipe hitCraftRecipe = null;
                        ClickableTextureComponent hitRecipe = cp != null ? FindCraftingRecipeAt(cp, ui, out hitCraftRecipe) : null;
                        JunimoNoteMenu jnm = topMenu as JunimoNoteMenu;
                        ClickableComponent hitJunimo = jnm != null ? FindJunimoBundleSlotAt(jnm, ui) : null;

                        if (cp != null && hitRecipe != null && hitCraftRecipe != null)
                        {
                            // FIXED: 1st tap NEVER crafts immediately — opens Authentic Stardew Mobile Crafting Sheet with ingredients & quantity slider!
                            _invShop.OpenCraftingPopup(topMenu, cp, hitRecipe, hitCraftRecipe, tl.Id);
                        }
                        else if (jnm != null && hitJunimo != null)
                        {
                            if (_cfg.SafeCrafting && (!ReferenceEquals(hitJunimo, _junimoHoveredSlot) || !ReferenceEquals(jnm, _junimoHoverMenu)))
                            {
                                // 1st tap on Community Center bundle item: preview before depositing!
                                _junimoHoverMenu = jnm;
                                _junimoHoveredSlot = hitJunimo;
                                try { jnm.performHoverAction(ui.X, ui.Y); } catch { }
                                try { Game1.playSound("smallSelect"); } catch { }
                            }
                            else
                            {
                                // FIXED: REAL 1-tap auto-deposit straight into matching Community Center bundle slot (zero stuck heldItem!)
                                _junimoHoverMenu = null;
                                _junimoHoveredSlot = null;
                                TryAutoDepositJunimoItem(jnm, ui);
                            }
                        }
                        else if (topMenu is CarpenterMenu cmFarm && cmFarm.onFarm && !cmFarm.freeze && _menuTapCameraPan &&
                                 (cmFarm.Action == CarpenterMenu.CarpentryAction.None ||
                                  cmFarm.Action == CarpenterMenu.CarpentryAction.Demolish ||
                                  (cmFarm.Action == CarpenterMenu.CarpentryAction.Move && cmFarm.buildingToMove != null)))
                        {
                            // Safe 2-Tap Preview on Robin/Wizard building placement, move-destination & demolish:
                            // (Picking up a building to Move, Upgrade, or Paint executes immediately on 1st tap!)
                            // 1st tap shows exact Green/Red blueprint at finger; 2nd tap nearby confirms!
                            if (!_hasCarpenterPreview || !ReferenceEquals(_carpenterPreviewMenu, cmFarm) || Vector2.Distance(vp, _carpenterPreviewVp) > 108f)
                            {
                                _carpenterPreviewMenu = cmFarm;
                                _carpenterPreviewVp = vp;
                                _hasCarpenterPreview = true;
                                try { cmFarm.performHoverAction(ui.X, ui.Y); } catch { }
                                try { Game1.playSound("smallSelect"); } catch { }
                            }
                            else
                            {
                                _hasCarpenterPreview = false;
                                try { cmFarm.performHoverAction(ui.X, ui.Y); } catch { }
                                try { cmFarm.receiveLeftClick(ui.X, ui.Y, true); } catch { }
                                try { cmFarm.releaseLeftClick(ui.X, ui.Y); } catch { }
                            }
                        }
                        else if (TryAutoPlaceCraftStation(topMenu, ui))
                        {
                            _junimoHoverMenu = null;
                            _junimoHoveredSlot = null;
                        }
                        else if (topMenu is ItemGrabMenu grabBtn && TryClickExpandedChestSideButton(grabBtn, ui))
                        {
                            // Expanded touch target for Chest side buttons (Fill Stacks, Organize, Color Picker, Junimo, Last Shipped)!
                        }
                        else if (topMenu is MineElevatorMenu mem && mem.elevators != null && TryClickExpandedElevator(mem, ui))
                        {
                            // Expanded touch target for Mine Elevator floor buttons!
                        }
                        else if (topMenu is CharacterCustomization ccTap && TryTapCharacterCustomizationTextBox(pad, br, ccTap, ui))
                        {
                            // Direct tap on Name / Farm Name / Favorite Thing box -> select & open native iOS 14-27 keyboard immediately!
                        }
                        else if (_cfg.SafeDialogueAndTooltip && topMenu is DialogueBox db && db.isQuestion && !db.transitioning && db.safetyTimer <= 0 && db.responseCC != null && db.responseCC.Count > 0 && TrySafeDialogueResponseTap(db, ui))
                        {
                            // 1st tap highlights choice, 2nd tap confirms cleanly (prevents Heart Event mis-taps!)
                        }
                        else if (TryRescueUnchosenSkillProfessionTap(topMenu, ui))
                        {
                            // 1-tap recovery on SkillsPage when a Level 5/10 profession bar has name == "-1" (#GL-LTQ82M)!
                        }
                        else if (topMenu is GameMenu gmModTap && ShouldRouteGameMenuTapToSmapiMouse(gmModTap, ui))
                        {
                            // Route non-vanilla GameMenu taps (e.g. UI Info Suite 2 Calendar & Help Wanted Quest icons
                            // inside InventoryPage or beside GameMenu!) through a true 2-frame Simulated MouseLeft click
                            // so SMAPI Events.Input.ButtonPressed(SButton.MouseLeft) fires cleanly just like PC!
                            _junimoHoverMenu = null;
                            _junimoHoveredSlot = null;
                            _dlgHoverMenu = null;
                            _dlgHoveredIdx = -1;
                            _hasCarpenterPreview = false;
                            Point clickRaw = ViewportToRaw(vp);
                            _lastMenuMouseRaw = clickRaw;
                            _gameMenuModClickRawPos = clickRaw;
                            _gameMenuModClickPulseFrames = 1;
                            try { Game1.lastCursorMotionWasMouse = true; } catch { }
                            try { topMenu.performHoverAction(ui.X, ui.Y); } catch { }
                            ResetMenuTapState();
                            EnsureBridge(pad)?.ApplyInputWithMouse(pad, Vector2.Zero, false, false, false, clickRaw, true, false, _rawW, _rawH);
                            return true;
                        }
                        else
                        {
                            _junimoHoverMenu = null;
                            _junimoHoveredSlot = null;
                            _dlgHoverMenu = null;
                            _dlgHoveredIdx = -1;
                            _hasCarpenterPreview = false;
                            try { topMenu.performHoverAction(ui.X, ui.Y); } catch { }
                            try { topMenu.receiveLeftClick(ui.X, ui.Y, true); } catch { }
                            try { topMenu.releaseLeftClick(ui.X, ui.Y); } catch { }
                            ApplySkillsPageHoverAssist(topMenu, ui);
                        }
                    }
                    ResetMenuTapState();
                }
            }

            // Keep SimulatedMousePosition synced in RAW BackBuffer pixels (LeftDown=false so Game1.updateActiveMenu doesn't double-click vanilla menus!)
            EnsureBridge(pad)?.ApplyInputWithMouse(pad, Vector2.Zero, false, false, false, _lastMenuMouseRaw, false, false, _rawW, _rawH);
            return true;
        }

        /// <summary>
        /// Zero-deadzone touch-to-mouse dispatcher for Stardew Valley's root TitleMenu screen.
        /// Fires a crisp 2-frame TRUE Simulated Mouse Left-Click at exact raw BackBuffer coordinates
        /// so BOTH vanilla TitleMenu buttons (NEW / LOAD / CO-OP / EXIT / Sound / Language) AND
        /// SMAPI mods using ButtonPressed(SButton.MouseLeft) (like Generic Mod Config Menu's bottom-left gear!) work 100%.
        /// </summary>
        private void UpdateTitleScreenTouches(object pad, TouchCollection touches, double nowSec)
        {
            Point? outPos = _titleClickRawPos ?? _lastMenuMouseRaw;
            bool outLeft = false;

            if (_titleClickPulseFrames > 0)
            {
                _titleClickPulseFrames--;
                outLeft = true;
            }

            bool sawTracked = false;
            for (int i = 0; i < touches.Count; i++)
            {
                TouchLocation tl = touches[i];
                Vector2 vp = MapRawToViewport(tl.Position);
                Point rawPt = ViewportToRaw(vp);

                if (tl.State == TouchLocationState.Pressed && _menuTapTouchId < 0)
                {
                    _menuTapTouchId = tl.Id;
                    _menuTapStartVp = vp;
                    _menuTapStartSec = nowSec;
                    _lastMenuMouseRaw = rawPt;
                    _titleClickRawPos = rawPt;
                    outPos = rawPt;
                    sawTracked = true;
                }
                else if (tl.State == TouchLocationState.Moved && tl.Id == _menuTapTouchId)
                {
                    _lastMenuMouseRaw = rawPt;
                    outPos = rawPt;
                    sawTracked = true;
                }
                else if ((tl.State == TouchLocationState.Released || tl.State == TouchLocationState.Invalid) && tl.Id == _menuTapTouchId)
                {
                    sawTracked = true;
                    Point clickRaw = ViewportToRaw(_menuTapStartVp);
                    _lastMenuMouseRaw = clickRaw;
                    _titleClickRawPos = clickRaw;
                    _titleClickPulseFrames = 1; // Frame 0 (this frame) + Frame 1 -> guarantees Released->Pressed edge for SMAPI & TitleMenu!
                    outPos = clickRaw;
                    outLeft = true;
                    ResetMenuTapState();
                }
            }

            if (!sawTracked && _menuTapTouchId >= 0)
            {
                // Fast tap where iOS dropped Released between frames
                if ((nowSec - _menuTapStartSec) < 0.40)
                {
                    Point clickRaw = ViewportToRaw(_menuTapStartVp);
                    _lastMenuMouseRaw = clickRaw;
                    _titleClickRawPos = clickRaw;
                    _titleClickPulseFrames = 1;
                    outPos = clickRaw;
                    outLeft = true;
                }
                ResetMenuTapState();
            }

            if (outPos.HasValue)
            {
                try { Game1.lastCursorMotionWasMouse = true; } catch { }
            }
            EnsureBridge(pad)?.ApplyInputWithMouse(pad, Vector2.Zero, false, false, false, outPos, outLeft, false, _rawW, _rawH);
        }

        private bool IsTapInsideEscPill(TouchCollection touches)
        {
            for (int i = 0; i < touches.Count; i++)
            {
                Vector2 vp = MapRawToViewport(touches[i].Position);
                if (_ctxQuestEscRect.Contains((int)vp.X, (int)vp.Y))
                    return true;
            }
            return false;
        }

        private static bool ShouldRouteGameMenuTapToSmapiMouse(GameMenu gm, Point ui)
        {
            if (gm == null)
                return false;
            try
            {
                if (gm.upperRightCloseButton != null && gm.upperRightCloseButton.containsPoint(ui.X, ui.Y))
                    return false;
                if (gm.tabs != null)
                {
                    for (int i = 0; i < gm.tabs.Count; i++)
                    {
                        var t = gm.tabs[i];
                        if (t != null && t.containsPoint(ui.X, ui.Y))
                            return false;
                    }
                }
                IClickableMenu curPage = gm.GetCurrentPage();
                if (curPage is InventoryPage)
                {
                    // Any tap inside InventoryPage that is NOT a vanilla slot/equipment/organize/trash/junimo button
                    // (e.g. UI Info Suite 2 Calendar & Help Wanted Quest buttons!) fires real SMAPI MouseLeft!
                    return !ExternalInputBridge.IsPointOnVanillaInventoryControl(gm, ui);
                }
                // On other GameMenu tabs, route taps OUTSIDE the main menu frame (sidebars/overlays added by mods)
                if (ui.X < gm.xPositionOnScreen || ui.X > gm.xPositionOnScreen + gm.width ||
                    ui.Y < gm.yPositionOnScreen || ui.Y > gm.yPositionOnScreen + gm.height)
                {
                    return true;
                }
            }
            catch { }
            return false;
        }

        private bool IsThirdPartyGameMenuPageTap(GameMenu gm, TouchCollection touches)
        {
            IClickableMenu curPage = null;
            try { curPage = gm?.GetCurrentPage(); } catch { }
            if (!IsThirdPartyModMenu(curPage))
                return false;
            if (_modTouchState != ModTouchState.None || _simMouseLeftPulseFrames > 0 || _simMouseRightPulseFrames > 0)
                return true;
            for (int i = 0; i < touches.Count; i++)
            {
                Point ui = ViewportToUi(MapRawToViewport(touches[i].Position));
                // Keep top tab strip & upper-right close button on vanilla GameMenu; route page interior to 3rd-party mouse bridge!
                if (ui.Y >= gm.yPositionOnScreen + 64 &&
                    (gm.upperRightCloseButton == null || !gm.upperRightCloseButton.containsPoint(ui.X, ui.Y)))
                {
                    return true;
                }
            }
            return false;
        }

        /// <summary>
        /// Dedicated touch handler for Stardew Valley's LevelUpMenu (#GL-LTQ82M):
        /// Vanilla LevelUpMenu.receiveLeftClick(x, y, playSound) is an empty method (`ret`);
        /// OK button clicks and Level 5/10 left/right profession card clicks are only processed inside
        /// LevelUpMenu.update(GameTime) via mouse button state transitions.
        /// </summary>
        private void UpdateLevelUpMenuTouches(object pad, LevelUpMenu lum, TouchCollection touches, double nowSec)
        {
            if (lum == null)
                return;

            // Modded LevelUpMenu subclasses (e.g. SpaceCore): drive via real 2-frame simulated mouse click!
            if (lum.GetType() != typeof(LevelUpMenu))
            {
                UpdateTitleScreenTouches(pad, touches, nowSec);
                return;
            }

            bool sawTracked = false;
            for (int i = 0; i < touches.Count; i++)
            {
                TouchLocation tl = touches[i];
                Vector2 vp = MapRawToViewport(tl.Position);
                Point ui = ViewportToUi(vp);
                Point rawPt = ViewportToRaw(vp);

                if (tl.State == TouchLocationState.Pressed && _menuTapTouchId < 0)
                {
                    _menuTapTouchId = tl.Id;
                    _menuTapStartVp = vp;
                    _menuTapStartSec = nowSec;
                    _menuTapDragged = false;
                    _lastMenuMouseRaw = rawPt;
                    SyncVanillaMouse(vp, false);
                    try { lum.performHoverAction(ui.X, ui.Y); } catch { }
                    sawTracked = true;
                }
                else if (tl.State == TouchLocationState.Moved && tl.Id == _menuTapTouchId)
                {
                    _lastMenuMouseRaw = rawPt;
                    if (Vector2.Distance(vp, _menuTapStartVp) >= Math.Max(28f, _vpH * 0.04f))
                        _menuTapDragged = true;
                    SyncVanillaMouse(vp, false);
                    try { lum.performHoverAction(ui.X, ui.Y); } catch { }
                    sawTracked = true;
                }
                else if ((tl.State == TouchLocationState.Released || tl.State == TouchLocationState.Invalid) && tl.Id == _menuTapTouchId)
                {
                    sawTracked = true;
                    _lastMenuMouseRaw = rawPt;
                    SyncVanillaMouse(vp, false);
                    if (!_menuTapDragged)
                        ExecuteLevelUpMenuTap(lum, ui);
                    ResetMenuTapState();
                }
            }

            if (!sawTracked && _menuTapTouchId >= 0)
            {
                if (!_menuTapDragged && (nowSec - _menuTapStartSec) < 0.40)
                {
                    Point tapUi = ViewportToUi(_menuTapStartVp);
                    _lastMenuMouseRaw = ViewportToRaw(_menuTapStartVp);
                    SyncVanillaMouse(_menuTapStartVp, false);
                    ExecuteLevelUpMenuTap(lum, tapUi);
                }
                ResetMenuTapState();
            }

            EnsureBridge(pad)?.ApplyInputWithMouse(pad, Vector2.Zero, false, false, false, _lastMenuMouseRaw, false, false, _rawW, _rawH);
        }

        private static void ExecuteLevelUpMenuTap(LevelUpMenu lum, Point ui)
        {
            if (lum == null || !lum.isActive || !lum.CanReceiveInput() || !lum.readyToClose())
                return;

            try { lum.performHoverAction(ui.X, ui.Y); } catch { }

            if (lum.isProfessionChooser)
            {
                var profs = LevelUpProfessionsField?.GetValue(lum) as List<int>;
                if (profs == null || profs.Count < 2)
                    return;

                int midX = lum.xPositionOnScreen + lum.width / 2;
                bool inCardBand = ui.Y >= lum.yPositionOnScreen + 160 && ui.Y <= lum.yPositionOnScreen + lum.height + 24;
                int pickedIdx = -1;

                if ((lum.leftProfession != null && lum.leftProfession.containsPoint(ui.X, ui.Y)) ||
                    (inCardBand && ui.X >= lum.xPositionOnScreen - 16 && ui.X < midX))
                {
                    pickedIdx = 0;
                }
                else if ((lum.rightProfession != null && lum.rightProfession.containsPoint(ui.X, ui.Y)) ||
                         (inCardBand && ui.X >= midX && ui.X <= lum.xPositionOnScreen + lum.width + 16))
                {
                    pickedIdx = 1;
                }

                if (pickedIdx == 0 || pickedIdx == 1)
                {
                    int chosen = profs[pickedIdx];
                    try
                    {
                        if (Game1.player != null && !Game1.player.professions.Contains(chosen))
                            Game1.player.professions.Add(chosen);
                        lum.getImmediateProfessionPerk(chosen);
                        lum.isActive = false;
                        lum.informationUp = false;
                        lum.isProfessionChooser = false;
                        lum.RemoveLevelFromLevelList();
                        Game1.playSound("shiny4");
                    }
                    catch { }
                }
                return;
            }

            if (lum.informationUp && lum.okButton != null)
            {
                Rectangle b = lum.okButton.bounds;
                Rectangle hitRect = new Rectangle(b.X - 32, b.Y - 32, b.Width + 64, b.Height + 64);
                if (hitRect.Contains(ui))
                {
                    try { lum.okButtonClicked(); } catch { }
                }
            }
        }

        /// <summary>
        /// Expands SkillsPage hover detection across the entire horizontal skill row (icon, name, yellow pips,
        /// and level number) and anchors _lastMenuMouseRaw onto the row's skillArea so the skill tooltip stays
        /// visible after lifting the finger on mobile!
        /// </summary>
        private void ApplySkillsPageHoverAssist(IClickableMenu topMenu, Point ui)
        {
            if (!(topMenu is GameMenu gm))
                return;
            SkillsPage sp = null;
            try { sp = gm.GetCurrentPage() as SkillsPage; } catch { }
            if (sp == null || sp.skillAreas == null)
                return;

            try
            {
                string curHover = SkillsHoverTextField?.GetValue(sp) as string;
                if (!string.IsNullOrEmpty(curHover))
                    return;

                if (ui.X < sp.xPositionOnScreen + 24 || ui.X > sp.xPositionOnScreen + sp.width - 24)
                    return;

                for (int i = 0; i < sp.skillAreas.Count; i++)
                {
                    ClickableTextureComponent area = sp.skillAreas[i];
                    if (area == null) continue;
                    if (ui.Y >= area.bounds.Y - 8 && ui.Y <= area.bounds.Bottom + 8)
                    {
                        Point c = area.bounds.Center;
                        sp.performHoverAction(c.X, c.Y);
                        Vector2 snapVp = UiToViewport(c);
                        _lastMenuMouseRaw = ViewportToRaw(snapVp);
                        SyncVanillaMouse(snapVp, false);
                        return;
                    }
                }
            }
            catch { }
        }

        /// <summary>
        /// 1-tap rescue on SkillsPage (#GL-LTQ82M): if a player previously missed choosing a Level 5 or 10
        /// profession (shown as an unchosen skillBar with name == "-1"), tapping that bar opens LevelUpMenu
        /// immediately so they can pick their profession right away without waiting for bedtime!
        /// </summary>
        private static bool TryRescueUnchosenSkillProfessionTap(IClickableMenu topMenu, Point ui)
        {
            if (!(topMenu is GameMenu gm))
                return false;
            SkillsPage sp = null;
            try { sp = gm.GetCurrentPage() as SkillsPage; } catch { }
            if (sp?.skillBars == null)
                return false;

            for (int i = 0; i < sp.skillBars.Count; i++)
            {
                ClickableTextureComponent bar = sp.skillBars[i];
                if (bar == null || bar.name != "-1")
                    continue;
                Rectangle padded = new Rectangle(bar.bounds.X - 8, bar.bounds.Y - 8, bar.bounds.Width + 16, bar.bounds.Height + 16);
                if (!padded.Contains(ui))
                    continue;

                int row = bar.myID % 100;
                int targetLevel = bar.myID >= 200 ? 10 : 5;
                // SkillsPage row layout -> Farmer skill index: 0=Farming(0), 1=Mining(3), 2=Foraging(2), 3=Fishing(1), 4=Combat(4), 5=Luck(5)
                int skillIdx = row == 0 ? 0 : (row == 1 ? 3 : (row == 2 ? 2 : (row == 3 ? 1 : (row == 4 ? 4 : 5))));
                if (targetLevel == 10 && Game1.player != null && LevelUpMenu.getProfessionTitleFromNumber(0) != null)
                {
                    // Ensure prerequisite Level 5 profession exists before opening Level 10 chooser
                    int lv5 = sp.skillBars.Exists(b => b != null && b.myID == 100 + row && b.name == "-1") ? 5 : 10;
                    targetLevel = lv5;
                }
                try
                {
                    Game1.playSound("bigSelect");
                    Game1.activeClickableMenu = new LevelUpMenu(skillIdx, targetLevel);
                    return true;
                }
                catch { }
            }
            return false;
        }

        private static void CloseTopmostMenu(IClickableMenu rawMenu, IClickableMenu topMenu)
        {
            if (topMenu == null || topMenu is SaveGameMenu || topMenu is ShippingMenu || topMenu is ReadyCheckDialog)
                return;

            if (topMenu is LevelUpMenu lumEsc)
            {
                if (lumEsc.isProfessionChooser)
                {
                    try { Game1.playSound("cancel"); } catch { }
                    return;
                }
                if (lumEsc.readyToClose() && lumEsc.CanReceiveInput())
                {
                    try { lumEsc.okButtonClicked(); } catch { }
                    return;
                }
            }
            if ((topMenu is ForgeMenu fmBusy && fmBusy.IsBusy()) ||
                (topMenu is TailoringMenu tmBusy && tmBusy.IsBusy()) ||
                (topMenu is DyeMenu dmBusy && dmBusy.IsBusy()) ||
                (topMenu is GeodeMenu gmBusy && (gmBusy.waitingForServerResponse || gmBusy.geodeAnimationTimer > 0)))
            {
                try { Game1.playSound("cancel"); } catch { }
                return;
            }

            try
            {
                // Rescue any item held on cursor before closing MenuWithInventory (Forge, Tailoring, Chest, Shop, etc.)
                if (topMenu is MenuWithInventory mwi && mwi.heldItem != null)
                    TryReturnHeldItemToInventoryMenu(mwi, Point.Zero);

                if (topMenu != null && !ReferenceEquals(topMenu, rawMenu))
                {
                    topMenu.receiveKeyPress(Keys.Escape);
                    if (ReferenceEquals(GetTopmostMenu(Game1.activeClickableMenu), topMenu) && topMenu.readyToClose())
                        topMenu.exitThisMenu(true);
                    return;
                }

                // Route ALL top-level vanilla & mod menus through receiveKeyPress(Keys.Escape) + exitThisMenu()
                // so cleanupBeforeExit() ALWAYS runs (returns ForgeMenu/TailoringMenu/MuseumMenu items, restores
                // CarpenterMenu/PurchaseAnimalsMenu/AnimalQueryMenu farm camera & HUD, triggers JunimoNoteMenu
                // bundle completion cutscene, and clears FishingRod.showingTreasure)!
                topMenu.receiveKeyPress(Keys.Escape);
                if (ReferenceEquals(Game1.activeClickableMenu, topMenu))
                {
                    if (topMenu.readyToClose())
                    {
                        topMenu.exitThisMenu(true);
                        if (ReferenceEquals(Game1.activeClickableMenu, topMenu))
                        {
                            try { topMenu.emergencyShutDown(); } catch { }
                            Game1.exitActiveMenu();
                        }
                    }
                    else
                    {
                        try { Game1.playSound("cancel"); } catch { }
                    }
                }
            }
            catch
            {
                try
                {
                    if (topMenu != null && topMenu.readyToClose())
                    {
                        try { topMenu.emergencyShutDown(); } catch { }
                        Game1.exitActiveMenu();
                    }
                }
                catch { }
            }
        }

        /// <summary>
        /// Universal touch-to-mouse bridge for ALL 3rd-party SMAPI Mod UIs (GenericModConfigMenu / SpaceShared.UI,
        /// SpaceCore, CJB Cheats/ItemSpawner, Lookup Anything, Chests Anywhere, Better Game Menu, StardewUI, etc.).
        /// Drives TouchVirtualPad.SimulatedMousePosition in EXACT RAW BackBuffer pixels (matching Game1.getMouseX = X / uiScale)
        /// and distinguishes Tap (1-frame MouseLeft pulse), Horizontal Slider/Scrollbar Drag (held MouseLeft),
        /// Vertical Swipe Scroll (receiveScrollWheelAction + SpaceShared.UI.Dropdown scroll), and Long-Press Right-Click!
        /// </summary>
        private void UpdateThirdPartyModMenu(object pad, IClickableMenu modMenu, TouchCollection touches, double nowSec)
        {
            Point? outPos = _lastMenuMouseRaw;
            bool outLeft = false;
            bool outRight = false;

            // 1. Drain any queued 1-frame tap click pulse cleanly
            if (_simMouseLeftPulseFrames > 0)
            {
                _simMouseLeftPulseFrames--;
                outPos = _simMousePulsePos ?? _lastMenuMouseRaw;
                outLeft = true;
            }
            else if (_simMouseRightPulseFrames > 0)
            {
                _simMouseRightPulseFrames--;
                outPos = _simMousePulsePos ?? _lastMenuMouseRaw;
                outRight = true;
            }

            bool sawTracked = false;
            for (int i = 0; i < touches.Count; i++)
            {
                TouchLocation tl = touches[i];
                Vector2 vp = MapRawToViewport(tl.Position);
                Point rawPt = ViewportToRaw(vp);

                if (tl.State == TouchLocationState.Pressed && _menuTapTouchId < 0)
                {
                    _menuTapTouchId = tl.Id;
                    _menuTapStartVp = vp;
                    _menuTapLastVp = vp;
                    _menuTapLastY = vp.Y;
                    _menuTapAccumY = 0f;
                    _menuTapStartSec = nowSec;
                    _modTouchState = ModTouchState.Pending;
                    _lastMenuMouseRaw = rawPt;
                    outPos = rawPt;
                    sawTracked = true;
                }
                else if (tl.State == TouchLocationState.Moved && tl.Id == _menuTapTouchId)
                {
                    sawTracked = true;
                    _lastMenuMouseRaw = rawPt;
                    float dxTotal = Math.Abs(vp.X - _menuTapStartVp.X);
                    float dyTotal = Math.Abs(vp.Y - _menuTapStartVp.Y);
                    float distTotal = Vector2.Distance(vp, _menuTapStartVp);
                    float dy = vp.Y - _menuTapLastY;
                    _menuTapLastY = vp.Y;

                    if (_modTouchState == ModTouchState.Pending)
                    {
                        bool onRightScrollbar = _menuTapStartVp.X >= _vpW * 0.80f && dyTotal >= 10f;
                        bool isHorizSlider = dxTotal >= 12f && dxTotal > dyTotal * 1.15f;
                        if (isHorizSlider || onRightScrollbar)
                        {
                            // Grab slider/scrollbar at exact start point first!
                            _modTouchState = ModTouchState.MouseDrag;
                            Point startRaw = ViewportToRaw(_menuTapStartVp);
                            outPos = startRaw;
                            outLeft = true;
                        }
                        else if (dyTotal >= 22f && dyTotal >= dxTotal)
                        {
                            _modTouchState = ModTouchState.SwipeScroll;
                            _menuTapAccumY = vp.Y - _menuTapStartVp.Y;
                            outPos = rawPt;
                            outLeft = false;
                        }
                        else if (distTotal < 16f && (nowSec - _menuTapStartSec) >= 0.45)
                        {
                            _modTouchState = ModTouchState.RightClicked;
                            outPos = rawPt;
                            outRight = true;
                            try { Game1.playSound("smallSelect"); } catch { }
                        }
                        else
                        {
                            outPos = rawPt;
                            outLeft = false;
                        }
                    }
                    else if (_modTouchState == ModTouchState.MouseDrag)
                    {
                        outPos = rawPt;
                        outLeft = true;
                    }
                    else if (_modTouchState == ModTouchState.SwipeScroll)
                    {
                        _menuTapAccumY += dy;
                        float step = Math.Max(22f, _vpH * 0.036f);
                        while (Math.Abs(_menuTapAccumY) >= step)
                        {
                            int wheel = _menuTapAccumY > 0 ? 120 : -120;
                            _menuTapAccumY -= Math.Sign(_menuTapAccumY) * step;
                            if (!TryScrollActiveModDropdown(modMenu, wheel))
                            {
                                try { modMenu.receiveScrollWheelAction(wheel); } catch { }
                            }
                        }
                        outPos = rawPt;
                        outLeft = false;
                    }
                }
                else if ((tl.State == TouchLocationState.Released || tl.State == TouchLocationState.Invalid) && tl.Id == _menuTapTouchId)
                {
                    sawTracked = true;
                    if (_modTouchState == ModTouchState.Pending)
                    {
                        // Clean Tap -> 1-frame TRUE MouseLeft press at start point in RAW BackBuffer pixels!
                        // Triggers SpaceShared.UI.Element.Clicked (GMCM/SpaceCore), Game1.updateActiveMenu -> receiveLeftClick, AND SMAPI ButtonPressed!
                        Point clickRaw = ViewportToRaw(_menuTapStartVp);
                        _lastMenuMouseRaw = clickRaw;
                        _simMousePulsePos = clickRaw;
                        _simMouseLeftPulseFrames = 0; // Apply THIS frame directly!
                        outPos = clickRaw;
                        outLeft = true;
                    }
                    else
                    {
                        outPos = rawPt;
                        outLeft = false;
                    }
                    ResetMenuTapState();
                }
            }

            if (!sawTracked && _menuTapTouchId >= 0)
            {
                // Handle ultra-fast tap on 30 FPS mode where iOS drops the Released state between frames
                if (_modTouchState == ModTouchState.Pending && (nowSec - _menuTapStartSec) < 0.35)
                {
                    Point clickRaw = ViewportToRaw(_menuTapStartVp);
                    _lastMenuMouseRaw = clickRaw;
                    outPos = clickRaw;
                    outLeft = true;
                }
                ResetMenuTapState();
            }

            if (outPos.HasValue)
            {
                // Inform Stardew & SMAPI mods that cursor is mouse-driven (so GMCM/SpaceCore/LookupAnything never snap back to gamepad!)
                try { Game1.lastCursorMotionWasMouse = true; } catch { }
            }
            EnsureBridge(pad)?.ApplyInputWithMouse(pad, Vector2.Zero, false, false, false, outPos, outLeft, outRight, _rawW, _rawH);
        }

        private static bool TryScrollActiveModDropdown(IClickableMenu modMenu, int wheel)
        {
            if (modMenu == null) return false;
            try
            {
                var ddType = modMenu.GetType().Assembly.GetType("SpaceShared.UI.Dropdown", false);
                if (ddType == null) return false;
                const System.Reflection.BindingFlags stat = System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic;
                object active = ddType.GetField("ActiveDropdown", stat)?.GetValue(null)
                             ?? ddType.GetProperty("ActiveDropdown", stat)?.GetValue(null);
                if (active == null) return false;
                var m = ddType.GetMethod("ReceiveScrollWheelAction", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic);
                if (m != null)
                {
                    m.Invoke(active, new object[] { wheel });
                    return true;
                }
            }
            catch { }
            return false;
        }

        private static bool CanLongPressRightClick(IClickableMenu menu)
        {
            if (menu == null) return false;
            if (menu is DialogueBox || menu is LetterViewerMenu || menu is BobberBar || menu is TitleMenu || menu is EmoteMenu || menu is MineElevatorMenu)
                return false;
            if (menu is GameMenu gm)
            {
                try { if (gm.GetCurrentPage() is OptionsPage) return false; } catch { }
            }
            return true;
        }

        private void GetMobileInvCtxRects(
            IClickableMenu topMenu,
            out Rectangle rX1,
            out Rectangle rHalf,
            out Rectangle rGop,
            out Rectangle rXep,
            out Rectangle rKey,
            out Rectangle rEsc)
        {
            rX1 = rHalf = rGop = rXep = rKey = rEsc = Rectangle.Empty;
            int x = _ctxX1Rect.X;
            int y = _ctxX1Rect.Y;
            int w = _ctxX1Rect.Width;
            int h = _ctxX1Rect.Height;
            int wWide = _ctxXferRect.Width;
            int gap = Math.Max(4, _ctxHalfRect.X - _ctxX1Rect.Right);

            if (topMenu is ItemGrabMenu grab)
            {
                bool hasQuickStack = grab.fillStacksButton != null && grab.reverseGrab && !grab.shippingBin;
                bool hasOrganize = grab.organizeButton != null && grab.ItemsToGrabMenu?.actualInventory != null;
                rX1 = new Rectangle(x, y, w, h); x += w + gap;
                rHalf = new Rectangle(x, y, w, h); x += w + gap;
                if (hasQuickStack) { rGop = new Rectangle(x, y, wWide, h); x += wWide + gap; }
                if (hasOrganize) { rXep = new Rectangle(x, y, w, h); x += w + gap; }
                rEsc = new Rectangle(x, y, w, h);
                return;
            }
            if (topMenu is GameMenu gm && gm.GetCurrentPage() is InventoryPage)
            {
                rX1 = new Rectangle(x, y, w, h); x += w + gap;
                rHalf = new Rectangle(x, y, w, h); x += w + gap;
                rKey = new Rectangle(x, y, w, h); x += w + gap;
                rEsc = new Rectangle(x, y, w, h);
                return;
            }
            rEsc = new Rectangle(x, y, w, h);
        }

        private static bool TryClickExpandedChestSideButton(ItemGrabMenu grab, Point ui)
        {
            if (grab == null) return false;
            // Never steal taps meant for open Chest Color Picker swatches!
            if (grab.chestColorPicker != null && grab.chestColorPicker.visible && grab.chestColorPicker.isWithinBounds(ui.X, ui.Y))
                return false;

            const int pad = 14;
            ClickableComponent[] btns =
            {
                grab.fillStacksButton,
                grab.organizeButton,
                grab.colorPickerToggleButton,
                grab.specialButton,
                grab.junimoNoteIcon,
                grab.shippingBin ? grab.lastShippedHolder : null
            };
            ClickableComponent best = null;
            float bestDistSq = float.MaxValue;
            for (int i = 0; i < btns.Length; i++)
            {
                var cc = btns[i];
                if (cc == null || !cc.visible || cc.bounds.Width <= 0 || cc.bounds.Height <= 0) continue;
                var expanded = new Rectangle(cc.bounds.X - pad, cc.bounds.Y - pad, cc.bounds.Width + pad * 2, cc.bounds.Height + pad * 2);
                if (expanded.Contains(ui))
                {
                    float dx = cc.bounds.Center.X - ui.X;
                    float dy = cc.bounds.Center.Y - ui.Y;
                    float dSq = dx * dx + dy * dy;
                    if (dSq < bestDistSq)
                    {
                        bestDistSq = dSq;
                        best = cc;
                    }
                }
            }
            if (best == null) return false;
            try { grab.performHoverAction(best.bounds.Center.X, best.bounds.Center.Y); } catch { }
            try { grab.receiveLeftClick(best.bounds.Center.X, best.bounds.Center.Y, true); } catch { }
            try { grab.releaseLeftClick(best.bounds.Center.X, best.bounds.Center.Y); } catch { }
            return true;
        }

        private static bool TryClickExpandedElevator(MineElevatorMenu mem, Point ui)
        {
            ClickableComponent best = null;
            float bestDistSq = float.MaxValue;
            const int pad = 16;
            for (int i = 0; i < mem.elevators.Count; i++)
            {
                var cc = mem.elevators[i];
                if (cc == null) continue;
                var expanded = new Rectangle(cc.bounds.X - pad, cc.bounds.Y - pad, cc.bounds.Width + pad * 2, cc.bounds.Height + pad * 2);
                if (expanded.Contains(ui))
                {
                    float dx = cc.bounds.Center.X - ui.X;
                    float dy = cc.bounds.Center.Y - ui.Y;
                    float dSq = dx * dx + dy * dy;
                    if (dSq < bestDistSq)
                    {
                        bestDistSq = dSq;
                        best = cc;
                    }
                }
            }
            if (best == null) return false;
            try { mem.performHoverAction(best.bounds.Center.X, best.bounds.Center.Y); } catch { }
            try { mem.receiveLeftClick(best.bounds.Center.X, best.bounds.Center.Y, true); } catch { }
            return true;
        }

        private bool TrySafeDialogueResponseTap(DialogueBox db, Point ui)
        {
            try
            {
                string curStr = db.getCurrentString();
                if (!string.IsNullOrEmpty(curStr) && db.characterIndexInDialogue < curStr.Length - 1)
                {
                    // Question text is still typing out: let 1st tap fast-forward text without selecting any response!
                    db.receiveLeftClick(ui.X, ui.Y, true);
                    return true;
                }
            }
            catch { }

            int hitIdx = -1;
            for (int i = 0; i < db.responseCC.Count; i++)
            {
                var cc = db.responseCC[i];
                if (cc != null && cc.bounds.Contains(ui))
                {
                    hitIdx = i;
                    break;
                }
            }
            if (hitIdx < 0)
            {
                // Swallow stray taps outside response rows so DialogueBox.receiveLeftClick NEVER auto-confirms choice #0!
                _dlgHoverMenu = null;
                _dlgHoveredIdx = -1;
                db.selectedResponse = -1;
                return true;
            }

            if (!ReferenceEquals(_dlgHoverMenu, db) || _dlgHoveredIdx != hitIdx)
            {
                _dlgHoverMenu = db;
                _dlgHoveredIdx = hitIdx;
                db.selectedResponse = hitIdx;
                try { db.performHoverAction(ui.X, ui.Y); } catch { }
                try { Game1.playSound("smallSelect"); } catch { }
                return true;
            }

            // 2nd tap on the same highlighted response -> confirm!
            _dlgHoverMenu = null;
            _dlgHoveredIdx = -1;
            db.selectedResponse = hitIdx;
            try { db.performHoverAction(ui.X, ui.Y); } catch { }
            try { db.receiveLeftClick(ui.X, ui.Y, true); } catch { }
            try { db.releaseLeftClick(ui.X, ui.Y); } catch { }
            return true;
        }

        private bool ProcessCustomKeyTouches(object pad, PadBridge br, TouchCollection touches, double nowSec)
        {
            _customBtnsHeldNow.Clear();
            bool anyCustomTouched = false;

            // Keep existing active custom-button touches
            for (int i = 0; i < touches.Count; i++)
            {
                TouchLocation tl = touches[i];
                bool active = tl.State == TouchLocationState.Pressed || tl.State == TouchLocationState.Moved;
                Vector2 vp = MapRawToViewport(tl.Position);
                Point pt = new Point((int)vp.X, (int)vp.Y);

                // Check if this touch already owns a custom button
                int ownedBtnId = -1;
                foreach (var kv in _customBtnTouchIds)
                {
                    if (kv.Value == tl.Id) { ownedBtnId = kv.Key; break; }
                }

                if (ownedBtnId >= 0)
                {
                    if (active)
                    {
                        _customBtnsHeldNow.Add(ownedBtnId);
                        anyCustomTouched = true;
                    }
                    else
                    {
                        _customBtnTouchIds.Remove(ownedBtnId);
                    }
                    continue;
                }

                if (tl.State == TouchLocationState.Pressed)
                {
                    for (int k = _cfg.CustomKeys.Count - 1; k >= 0; k--)
                    {
                        var btn = _cfg.CustomKeys[k];
                        Rectangle r = GetCustomKeyRect(btn);
                        if (r.Contains(pt))
                        {
                            _customBtnTouchIds[btn.Id] = tl.Id;
                            _customBtnsHeldNow.Add(btn.Id);
                            if (!_customBtnLastPressSec.TryGetValue(btn.Id, out double lastSec) || (nowSec - lastSec) >= 0.16)
                            {
                                _customBtnLastPressSec[btn.Id] = nowSec;
                                _customBtnPulseFrames[btn.Id] = 2; // Clean 2-tick rising-edge pulse for SMAPI + Game1 without menu double-toggling!
                                OnCustomKeyActivated(pad, br, btn);
                            }
                            anyCustomTouched = true;
                            break;
                        }
                    }
                }
            }

            // Prune stale IDs if fingers vanished
            if (_customBtnTouchIds.Count > 0 && touches.Count == 0)
                _customBtnTouchIds.Clear();

            return anyCustomTouched;
        }

        private void OnCustomKeyActivated(object pad, PadBridge br, CustomKeyButton btn)
        {
            if (btn == null || btn.KeyCode <= 0)
                return;

            if (Game1.activeClickableMenu == null)
            {
                // Tell SDViOSTouchControls that any menu opened by this key press (e.g. ESC, E, M, P, I, F6, F7) was requested by the player!
                br?.SetPlayerRequestedMenuOpen(pad, true);
            }
            else if (btn.KeyCode == (int)Keys.Escape)
            {
                br?.SetPlayerRequestedMenuOpen(pad, false);
            }
        }

        private bool IsTouchOwnedByCustomButton(int touchId)
        {
            foreach (var kv in _customBtnTouchIds)
                if (kv.Value == touchId) return true;
            return false;
        }

        public void DrawMenuContextOverlay(object pad, SpriteBatch sb)
        {
            if (sb == null || sb.GraphicsDevice == null)
                return;

            // ALWAYS draw the crisp safe-area SKIP pill during skippable cutscenes — BOTH with Touch AND with
            // an external Gamepad (where vanilla Stardew hides its Skip button due to SnappyMenus!) AND even
            // while a DialogueBox is open!
            if (IsSkippableCutsceneActive())
            {
                DrawSkipCutsceneButtonOnly(pad, sb);
            }

            if (_gamepadHideHud)
                return;

            IClickableMenu rawMenu = Game1.activeClickableMenu;
            if (rawMenu == null)
                return;

            IClickableMenu topMenu = GetTopmostMenu(rawMenu);
            bool isThirdParty = IsThirdPartyModMenu(topMenu);
            if (rawMenu is BobberBar || (rawMenu is TitleMenu && TitleMenu.subMenu == null))
                return;

            bool showInvCtx = IsInventoryContextMenu(topMenu);
            bool showKeyOnly = !showInvCtx && IsTextInputMenu(topMenu);
            bool showEscOnly = !showInvCtx && !showKeyOnly && IsEscOnlyMenu(topMenu);
            bool allowCustomKeys = AllowCustomKeysInCurrentMenu() && !isThirdParty && _cfg.CustomKeys.Count > 0;
            bool showInvShop = _invShop.IsPopupOpen || (_cfg.MobileShopAndDrag && (_invShop.IsDraggingItem || _invShop.HasSelectedSlot));
            bool showJunimoHint = _cfg.SafeCrafting && _junimoHoveredSlot != null && ReferenceEquals(_junimoHoverMenu, topMenu as JunimoNoteMenu);
            bool showDlgHint = _cfg.SafeDialogueAndTooltip && _dlgHoveredIdx >= 0 && ReferenceEquals(_dlgHoverMenu, topMenu as DialogueBox) && _dlgHoverMenu.responseCC != null && _dlgHoveredIdx < _dlgHoverMenu.responseCC.Count;
            bool showCarpHint = _hasCarpenterPreview && ReferenceEquals(_carpenterPreviewMenu, topMenu as CarpenterMenu);
            if (!showInvCtx && !showKeyOnly && !showEscOnly && !allowCustomKeys && !showInvShop && !showJunimoHint && !showDlgHint && !showCarpHint)
                return;

            EnsureTextures(sb.GraphicsDevice);
            if (!RefreshViewport()) return;
            ComputeLayout();
            PixelUi.GlobalOpacity = _cfg.PixelOpacity;
            var br = EnsureBridge(pad);

            if (showInvCtx)
            {
                if (_cfg.MobileShopAndDrag)
                {
                    GetMobileInvCtxRects(topMenu, out Rectangle rX1, out Rectangle rHalf, out Rectangle rGop, out Rectangle rXep, out Rectangle rKey, out Rectangle rEsc);
                    if (!rX1.IsEmpty)
                        DrawMinimalPill(sb, rX1, "X1", _invShop.TapMode == MobileInventoryShopHelper.ChestTapMode.SingleOne);
                    if (!rHalf.IsEmpty)
                        DrawMinimalPill(sb, rHalf, "1/2", _invShop.TapMode == MobileInventoryShopHelper.ChestTapMode.HalfStack);
                    if (!rGop.IsEmpty)
                        PixelUi.DrawPixelPill(sb, _pixel, br, rGop, "GOP", PixelRole.Action, false, _vpH);
                    if (!rXep.IsEmpty)
                        PixelUi.DrawPixelPill(sb, _pixel, br, rXep, "XEP", PixelRole.Tool, false, _vpH);
                    if (!rKey.IsEmpty)
                        DrawMinimalPill(sb, rKey, "KEY", false);
                    if (!rEsc.IsEmpty)
                        PixelUi.DrawPixelPill(sb, _pixel, br, rEsc, "ESC", PixelRole.Special, false, _vpH);
                }
                else
                {
                    DrawMinimalPill(sb, _ctxX1Rect, "X1", br != null && br.GetSingleItemMode(pad));
                    DrawMinimalPill(sb, _ctxHalfRect, "1/2", br != null && br.GetHalfStackMode(pad));
                    DrawMinimalPill(sb, _ctxXferRect, "XFER", br != null && br.GetQuickTransferMode(pad));
                    DrawMinimalPill(sb, _ctxKeyRect, "KEY", false);
                    PixelUi.DrawPixelPill(sb, _pixel, br, _ctxEscRect, "ESC", PixelRole.Special, false, _vpH);
                }
            }
            else if (showKeyOnly)
            {
                DrawMinimalPill(sb, _ctxX1Rect, "KEY", false);
                if (topMenu.readyToClose())
                    PixelUi.DrawPixelPill(sb, _pixel, br, _ctxHalfRect, "ESC", PixelRole.Special, false, _vpH);
            }
            else if (showEscOnly)
            {
                PixelUi.DrawPixelPill(sb, _pixel, br, _ctxQuestEscRect, "ESC", PixelRole.Special, false, _vpH);
            }

            if (showJunimoHint || showDlgHint || showCarpHint)
            {
                if (showJunimoHint || showDlgHint)
                {
                    Rectangle rb = showJunimoHint ? _junimoHoveredSlot.bounds : _dlgHoverMenu.responseCC[_dlgHoveredIdx].bounds;
                    Vector2 tl = UiToViewport(new Point(rb.X, rb.Y));
                    Vector2 brPt = UiToViewport(new Point(rb.Right, rb.Bottom));
                    var vr = new Rectangle((int)tl.X, (int)tl.Y, Math.Max(16, (int)(brPt.X - tl.X)), Math.Max(16, (int)(brPt.Y - tl.Y)));
                    PixelUi.DrawPixelTileTarget(sb, _pixel, vr, new Color(248, 206, 86), 0.12f);
                }

                string hTxt = showJunimoHint
                    ? "CHAM LAN NUA DE BO VAO GOI"
                    : (showDlgHint ? "CHAM LAN NUA DE CHON CAU TRA LOI" : "CHAM LAN NUA DE XAC NHAN VI TRI");
                int px = PixelUi.Step(_vpH);
                int bw = Math.Clamp((int)(_vpW * 0.42f), 260, _vpW - 40);
                int bh = Math.Max(32, (int)(_vpH * 0.058f));
                var hintR = new Rectangle((_vpW - bw) / 2, _vpH - bh - Math.Max(14, _vpH / 34), bw, bh);
                PixelUi.DrawParchmentBox(sb, _pixel, hintR, px, 0.94f);
                br?.DrawCenteredString(sb, _pixel, hTxt, hintR, new Color(74, 37, 17), Math.Max(1, _vpH / 320));
            }

            if (allowCustomKeys)
                DrawCustomKeyButtons(sb);

            if (showInvShop)
                _invShop.Draw(sb, _pixel, _circle, br, topMenu, _fnUiToVp, _fnVpToUi, _vpW, _vpH, _cfg.SafeDialogueAndTooltip);
        }

        public void UpdateGameplay(object pad, GameTime gameTime)
        {
            _menuPadNeutralized = false;
            _invShop.Reset();
            if (_wasInMenu || EffectiveMode != _lastModeSeen)
            {
                _wasInMenu = false;
                _lastModeSeen = EffectiveMode;
                ResetGameplayState();
            }
            var br = EnsureBridge(pad);
            if (!_loggedFirstIntercept)
            {
                _loggedFirstIntercept = true;
                _monitor?.Log($"[MobileControls] LIVE INTERCEPT ACTIVE on {pad.GetType().Assembly.GetName().Name} (Mode={_cfg.Mode}, CustomKeys={_cfg.CustomKeys.Count})", LogLevel.Info);
            }

            br?.SyncMenuBarConfig(pad);

            if (!RefreshViewport())
                return;
            ComputeLayout();

            // ---- Dedicated Auto Arcade Pad for PC Minigames (Prairie King, Junimo Kart, Crane Game, Fair Slingshot/Fishing, Pirate Darts) ----
            var arcadeKind = MobileMinigamePad.DetectCurrentArcadeMinigame();
            if (arcadeKind != MobileMinigamePad.ArcadeKind.None)
            {
                ClearCustomButtonTouches();
                ResetGameplayState();
                TouchCollection mgTouches = TouchPanel.GetState();
                int activeMgTouches = CountActiveTouches(mgTouches);
                PollGamepadAutoHide(activeMgTouches);
                if (ModEntry.ExternalInput != null && ModEntry.ExternalInput.IsExternalDeviceActive && activeMgTouches == 0)
                {
                    _minigamePad.Reset();
                    br?.ResetVirtualPad(pad);
                    return;
                }
                Vector2 mgStick = _minigamePad.Update(arcadeKind, mgTouches, _fnRawToVp, _vpW, _vpH);
                Point? mgMouseRaw = null;
                if (_minigamePad.MousePos.HasValue)
                    mgMouseRaw = ViewportToRaw(new Vector2(_minigamePad.MousePos.Value.X, _minigamePad.MousePos.Value.Y));
                else if (_minigamePad.MouseLeftDown)
                    mgMouseRaw = new Point(_rawW / 2, _rawH / 2);
                EnsureBridge(pad)?.ApplyInputWithMouse(pad, mgStick, false, false, false, mgMouseRaw, _minigamePad.MouseLeftDown, false, _rawW, _rawH);
                return;
            }
            _minigamePad.Reset();

            // ---- Dedicated Interactive Edit Layout Mode ----
            if (_editMode)
            {
                ClearCustomButtonTouches();
                UpdateEditLayoutTouches(TouchPanel.GetState());
                ApplyToPad(pad, Vector2.Zero, false, false, false);
                return;
            }

            // ---- Dedicated Stardew-Pixel Multi-Slot Save Menu Modal ----
            if (_saveMenuOpen)
            {
                ClearCustomButtonTouches();
                ResetGameplayState();
                double smNow = gameTime != null ? gameTime.TotalGameTime.TotalSeconds : Environment.TickCount64 / 1000.0;
                UpdateSaveMenuTouches(pad, br, TouchPanel.GetState(), smNow);
                ApplyToPad(pad, Vector2.Zero, false, false, false);
                return;
            }

            TickCustomButtonPulses();
            if (_cfg.VerticalToolbar)
                _verticalToolbar.UpdateInertia();

            string curLocName = Game1.currentLocation?.NameOrUniqueName;
            double nowSec = gameTime != null ? gameTime.TotalGameTime.TotalSeconds : Environment.TickCount64 / 1000.0;
            if (curLocName != _lastLocationName)
            {
                _lastLocationName = curLocName;
                ClearPath();
            }
            UpdateAutoCombatMode(nowSec);

            if (_toolRippleAlpha > 0f) _toolRippleAlpha = Math.Max(0f, _toolRippleAlpha - 0.12f);
            if (_interactRippleAlpha > 0f) _interactRippleAlpha = Math.Max(0f, _interactRippleAlpha - 0.12f);

            if (PollNativeKeyboardResult(pad, br))
            {
                ApplyToPad(pad, Vector2.Zero, false, false, false);
                return;
            }
            PollAutoKeyboard(pad, br, nowSec, null);
            TouchCollection touches = TouchPanel.GetState();
            int activeTouches = CountActiveTouches(touches);
            PollGamepadAutoHide(activeTouches);

            // Physical External Peripheral active (Full Gamepad / Keyboard / Mouse) with no direct screen touch:
            // yield completely to Harmony ExternalInputBridge so Stardew & SMAPI receive 100% real controller/keyboard/mouse state!
            if (ModEntry.ExternalInput != null && ModEntry.ExternalInput.IsExternalDeviceActive && activeTouches == 0 && !_guiHidden)
            {
                br?.ResetVirtualPad(pad);
                return;
            }

            // Legacy fallback when native ExternalInputBridge is unavailable
            if (_gamepadHideHud && _hasPhysicalGamePadState && touches.Count == 0 && !_guiHidden)
            {
                var gs = _lastPhysicalGamePadState;
                // Convert MonoGame cartesian Y (+up/-down) into TouchVirtualPad screen Y (-up/+down)
                Vector2 gpStick = new Vector2(gs.ThumbSticks.Left.X, -gs.ThumbSticks.Left.Y);
                if (gs.DPad.Left == ButtonState.Pressed) gpStick.X = -1f;
                else if (gs.DPad.Right == ButtonState.Pressed) gpStick.X = 1f;
                if (gs.DPad.Up == ButtonState.Pressed) gpStick.Y = -1f;
                else if (gs.DPad.Down == ButtonState.Pressed) gpStick.Y = 1f;
                if (gpStick.LengthSquared() > 1f) gpStick.Normalize();

                br?.ApplyPhysicalGamePad(
                    pad,
                    gpStick,
                    btnX: gs.Buttons.X == ButtonState.Pressed,
                    btnA: gs.Buttons.A == ButtonState.Pressed,
                    btnB: gs.Buttons.B == ButtonState.Pressed,
                    btnY: gs.Buttons.Y == ButtonState.Pressed,
                    btnLT: gs.Buttons.LeftShoulder == ButtonState.Pressed || gs.Triggers.Left > 0.35f,
                    btnRT: gs.Buttons.RightShoulder == ButtonState.Pressed || gs.Triggers.Right > 0.35f,
                    btnMenu: gs.Buttons.Start == ButtonState.Pressed);
                return;
            }

            // ---- Clean Hide GUI Mode: ALL touch buttons & HUD hidden; Double-Tap anywhere restores GUI! ----
            if (_guiHidden)
            {
                ClearCustomButtonTouches();
                if (_cfg.PinchZoom && HandlePinchZoom(touches, nowSec))
                {
                    _hideTapTouchId = -1;
                    ApplyToPad(pad, Vector2.Zero, false, false, false);
                    return;
                }
                if (touches.Count == 1)
                {
                    TouchLocation htl = touches[0];
                    Vector2 hvp = MapRawToViewport(htl.Position);
                    if (htl.State == TouchLocationState.Pressed)
                    {
                        _hideTapTouchId = htl.Id;
                        _hideTapStartVp = hvp;
                    }
                    else if ((htl.State == TouchLocationState.Released || htl.State == TouchLocationState.Invalid) && htl.Id == _hideTapTouchId)
                    {
                        _hideTapTouchId = -1;
                        if (Vector2.Distance(hvp, _hideTapStartVp) < 36f)
                        {
                            if ((nowSec - _lastHideTapSec) <= 0.38 && Vector2.Distance(hvp, _lastHideTapVp) <= 130f)
                            {
                                SetGuiHidden(false);
                                _lastHideTapSec = -10.0;
                                try { Game1.playSound("smallSelect"); } catch { }
                                ShowSaveToast("DA HIEN LAI GUI", nowSec);
                            }
                            else
                            {
                                _lastHideTapSec = nowSec;
                                _lastHideTapVp = hvp;
                            }
                        }
                    }
                }
                else if (touches.Count > 1)
                {
                    // Multi-touch (e.g. 3-finger double tap for Mod Garden) cancels single-tap restore timer
                    _hideTapTouchId = -1;
                    _lastHideTapSec = -10.0;
                }
                if (ModEntry.ExternalInput != null && ModEntry.ExternalInput.IsExternalDeviceActive && activeTouches == 0)
                {
                    // Do NOT call ApplyToPad/ForwardInputToGame while external gamepad is driving in HIDE GUI mode,
                    // otherwise TouchVirtualPad calls Game1.player.Halt() every frame and breaks running animation!
                    br?.ResetVirtualPad(pad);
                    return;
                }
                ApplyToPad(pad, Vector2.Zero, false, false, false);
                return;
            }

            // --- 0. Process User Custom PC Key Buttons FIRST (never steal gameplay buttons!) ---
            if (_cfg.CustomKeys.Count > 0)
                ProcessCustomKeyTouches(pad, br, touches, nowSec);
            else
                ClearCustomButtonTouches();

            MobileControlMode effMode = EffectiveMode;
            bool useJoy = effMode == MobileControlMode.InvisibleJoystick2Btn ||
                          effMode == MobileControlMode.VisibleJoystick2Btn ||
                          effMode == MobileControlMode.TapAndJoystick;
            bool use2Btn = useJoy;
            bool useTap = effMode == MobileControlMode.TapToMove ||
                          effMode == MobileControlMode.TapAndJoystick;
            bool isHybrid = effMode == MobileControlMode.TapAndJoystick;

            // --- 1. Handle 2-Finger Pinch-to-Zoom ---
            if (_cfg.PinchZoom && HandlePinchZoom(touches, nowSec))
            {
                _joyTouchId = -1;
                _joyActivated = false;
                _tapTouchId = -1;
                _holdWalking = false;
                _tapChargingTool = false;
                _tapHoldSwinging = false;
                _tapHoldCooldown = 0;
                _toolTouchId = -1;
                _interactTouchId = -1;
                _toolPressed = false;
                _interactPressed = false;
                _slingshotTouchId = -1;
                _toolbarTouchId = -1;
                _fishBendTouchId = -1;
                _fishBendX = 0f;
                _verticalToolbar.ResetTouch();
                ApplyToPad(pad, Vector2.Zero, false, false, false);
                return;
            }

            bool sawJoy = false;
            bool sawTool = false;
            bool sawInteract = false;
            bool sawTap = false;
            bool sawToolbar = false;
            bool sawSlingshot = false;
            Vector2 stickVec = Vector2.Zero;
            Furniture heldFurn = GetHeldRotatableFurniture();
            MeleeWeapon heldSpecWeapon = GetHeldSpecialWeapon();
            bool holdingSlingshot = Game1.player?.CurrentTool is Slingshot;
            if (!holdingSlingshot) _slingshotTouchId = -1;
            bool sawVertTb = false;

            for (int i = 0; i < touches.Count; i++)
            {
                TouchLocation tl = touches[i];
                if (IsTouchOwnedByCustomButton(tl.Id))
                    continue;

                Vector2 vp = MapRawToViewport(tl.Position);
                Point vpPt = new Point((int)vp.X, (int)vp.Y);
                bool active = tl.State == TouchLocationState.Pressed || tl.State == TouchLocationState.Moved;

                // Top utility bar (BAG / MAP / QST / SAVE / KEY / EDIT / collapse)
                if (_cfg.ShowTopUtility && tl.State == TouchLocationState.Pressed)
                {
                    if (_btnBagRect.Contains(vpPt))
                    {
                        br?.SetPlayerRequestedMenuOpen(pad, true);
                        _ctxTouchId = tl.Id;
                        if (Game1.activeClickableMenu == null)
                        {
                            try { Game1.activeClickableMenu = new GameMenu(false); } catch { }
                        }
                        ClearPath();
                        ApplyToPad(pad, Vector2.Zero, false, false, false);
                        return;
                    }
                    if (_btnCollapseRect.Contains(vpPt))
                    {
                        _topBarCollapsed = !_topBarCollapsed;
                        ComputeLayout();
                        try { Game1.playSound("smallSelect"); } catch { }
                        continue;
                    }
                    if (!_topBarCollapsed)
                    {
                        if (_btnMapRect.Contains(vpPt))
                        {
                            br?.SetPlayerRequestedMenuOpen(pad, true);
                            _ctxTouchId = tl.Id;
                            if (Game1.activeClickableMenu == null)
                            {
                                try { Game1.activeClickableMenu = new GameMenu(GameMenu.mapTab, -1, false); } catch { }
                            }
                            ClearPath();
                            ApplyToPad(pad, Vector2.Zero, false, false, false);
                            return;
                        }
                        if (_btnQuestRect.Contains(vpPt))
                        {
                            br?.SetPlayerRequestedMenuOpen(pad, true);
                            _ctxTouchId = tl.Id;
                            if (Game1.activeClickableMenu == null)
                            {
                                try { Game1.activeClickableMenu = new QuestLog(); } catch { }
                            }
                            ClearPath();
                            ApplyToPad(pad, Vector2.Zero, false, false, false);
                            return;
                        }
                        if (_btnSaveRect.Contains(vpPt))
                        {
                            if (Game1.eventUp)
                            {
                                ShowSaveToast("KHONG THE LUU TRONG SU KIEN / LE HOI", nowSec);
                                try { Game1.playSound("cancel"); } catch { }
                            }
                            else
                            {
                                OpenSaveMenu();
                            }
                            ClearPath();
                            ApplyToPad(pad, Vector2.Zero, false, false, false);
                            return;
                        }
                        if (_btnKeyRect.Contains(vpPt))
                        {
                            TriggerKeyboardSmart(pad, br, null, null);
                            continue;
                        }
                        if (!_btnEmoteRect.IsEmpty && _btnEmoteRect.Contains(vpPt))
                        {
                            br?.SetPlayerRequestedMenuOpen(pad, true);
                            _ctxTouchId = tl.Id;
                            if (Game1.activeClickableMenu == null && Game1.player != null && Game1.player.CanEmote())
                            {
                                try
                                {
                                    var em = new EmoteMenu();
                                    em.gamepadMode = false;
                                    Game1.activeClickableMenu = em;
                                }
                                catch { }
                            }
                            ClearPath();
                            ApplyToPad(pad, Vector2.Zero, false, false, false);
                            return;
                        }
                        if (!_btnCtlModeRect.IsEmpty && _btnCtlModeRect.Contains(vpPt))
                        {
                            CycleControlMode(nowSec);
                            continue;
                        }
                        if (!_btnChatRect.IsEmpty && _btnChatRect.Contains(vpPt))
                        {
                            try
                            {
                                Game1.chatBox?.activate();
                                TriggerKeyboardSmart(pad, br, Game1.keyboardDispatcher?.Subscriber, null);
                            }
                            catch { }
                            ClearPath();
                            ApplyToPad(pad, Vector2.Zero, false, false, false);
                            return;
                        }
                        if (!_btnHideGuiRect.IsEmpty && _btnHideGuiRect.Contains(vpPt))
                        {
                            SetGuiHidden(true);
                            _lastHideTapSec = -10.0;
                            _hideTapTouchId = -1;
                            ResetGameplayState();
                            try { Game1.playSound("bigDeSelect"); } catch { }
                            ShowSaveToast("DA AN GUI - CHAM 2 LAN DE HIEN LAI", nowSec);
                            ApplyToPad(pad, Vector2.Zero, false, false, false);
                            return;
                        }
                        if (_btnEditRect.Contains(vpPt))
                        {
                            EnterEditLayoutMode();
                            try { Game1.playSound("smallSelect"); } catch { }
                            ApplyToPad(pad, Vector2.Zero, false, false, false);
                            return;
                        }
                    }
                }

                // Optional Mobile Vertical Scrollable 36-Slot Toolbar (left edge)
                if (_cfg.VerticalToolbar && _verticalToolbar.HandleTouch(tl, vp, out bool vSel))
                {
                    sawVertTb = true;
                    if (vSel)
                    {
                        _autoToolPrevSlot = -1;
                        _autoToolRestoreTimer = 0;
                        _repeatActive = false;
                    }
                    continue;
                }

                // Auto-context Weapon Special Move Button (SPEC: Parry / Slam / Flurry)
                if (heldSpecWeapon != null && tl.State == TouchLocationState.Pressed && _btnSpecRect.Contains(vpPt))
                {
                    if (!IsWeaponSpecialOnCooldown(heldSpecWeapon) && Game1.player != null)
                    {
                        if (!Game1.player.UsingTool)
                        {
                            _pendingWeaponSpecTicks = 0;
                            try { heldSpecWeapon.animateSpecialMove(Game1.player); } catch { }
                            ClearPath();
                        }
                        else
                        {
                            // Queue special move to fire on the very first frame current swing finishes!
                            _pendingWeaponSpecTicks = 22;
                            ClearPath();
                        }
                    }
                    _toolbarTouchId = tl.Id;
                    _toolbarTappedSlot = -1;
                    _toolbarSwiped = true;
                    sawToolbar = true;
                    continue;
                }

                // Auto-context Furniture Rotate Button (ROT)
                if (heldFurn != null && tl.State == TouchLocationState.Pressed && _btnRotateRect.Contains(vpPt))
                {
                    try { heldFurn.rotate(); } catch { }
                    try { Game1.playSound("smallSelect"); } catch { }
                    _toolbarTouchId = tl.Id;
                    _toolbarTappedSlot = -1;
                    _toolbarSwiped = true;
                    sawToolbar = true;
                    continue;
                }

                // Compact ROW quick-switch pill beside Toolbar (when MaxItems > 12)
                if (!_btnToolbarRowRect.IsEmpty && tl.State == TouchLocationState.Pressed && _btnToolbarRowRect.Contains(vpPt))
                {
                    try { Game1.player?.shiftToolbar(true); } catch { }
                    try { Game1.playSound("shwip"); } catch { }
                    _toolbarTouchId = tl.Id;
                    _toolbarTappedSlot = -1;
                    _toolbarSwiped = true;
                    sawToolbar = true;
                    continue;
                }

                // Direct Toolbar tap & horizontal swipe (swipe left/right across Toolbar shifts rows!) + Quest Journal tap
                if (tl.Id == _toolbarTouchId)
                {
                    if (active)
                    {
                        sawToolbar = true;
                        if (!_toolbarSwiped && _toolbarTappedSlot >= 0 && Game1.player != null && Game1.player.MaxItems > 12)
                        {
                            float dx = vp.X - _toolbarStartVp.X;
                            if (Math.Abs(dx) >= 36f)
                            {
                                _toolbarSwiped = true;
                                try { Game1.player.shiftToolbar(dx < 0f); } catch { }
                                try { Game1.playSound("shwip"); } catch { }
                            }
                        }
                    }
                    else
                    {
                        if (!_toolbarSwiped && _toolbarTappedSlot >= 0 && Game1.player != null)
                        {
                            Game1.player.CurrentToolIndex = _toolbarTappedSlot;
                            _autoToolPrevSlot = -1;
                            _autoToolRestoreTimer = 0;
                            try { Game1.playSound("stoneStep"); } catch { }
                        }
                        _toolbarTouchId = -1;
                        _toolbarTappedSlot = -1;
                        _toolbarSwiped = false;
                    }
                    continue;
                }
                if (tl.State == TouchLocationState.Pressed && TryHandleHudTap(vp, out bool openedMenu, out int tappedSlot))
                {
                    if (openedMenu)
                    {
                        _ctxTouchId = tl.Id;
                        ClearPath();
                        ApplyToPad(pad, Vector2.Zero, false, false, false);
                        return;
                    }
                    _toolbarTouchId = tl.Id;
                    _toolbarStartVp = vp;
                    _toolbarTappedSlot = tappedSlot;
                    _toolbarSwiped = false;
                    sawToolbar = true;
                    continue;
                }

                // Existing active Slingshot touch drag-to-aim finger
                if (holdingSlingshot && tl.Id == _slingshotTouchId)
                {
                    if (active)
                    {
                        sawSlingshot = true;
                        _slingshotRawPos = tl.Position;
                        _slingshotVpPos = vp;
                        _slingshotNorm = new Vector2(vp.X / Math.Max(1f, _vpW), vp.Y / Math.Max(1f, _vpH));
                    }
                    else
                    {
                        _slingshotTouchId = -1;
                        _slingshotReleaseHoldFrames = 2;
                    }
                    continue;
                }

                // Existing active right buttons
                if (use2Btn && tl.Id == _toolTouchId)
                {
                    if (active)
                    {
                        sawTool = true;
                        if (_cfg.ShowTouchHint) _toolRippleAlpha = 1f;
                    }
                    continue;
                }
                if (use2Btn && tl.Id == _interactTouchId)
                {
                    if (active)
                    {
                        sawInteract = true;
                        if (_cfg.ShowTouchHint) _interactRippleAlpha = 1f;
                    }
                    continue;
                }

                // Existing active joystick finger
                if (useJoy && tl.Id == _joyTouchId)
                {
                    if (active)
                    {
                        sawJoy = true;
                        float moved = Vector2.Distance(vp, _joyTouchStart);
                        if (!_joyActivated && (!isHybrid || moved >= 16f || (nowSec - _joyTouchStartTime) >= 0.16))
                        {
                            _joyActivated = true;
                            ClearPath();
                        }
                        if (_joyActivated)
                            stickVec = ComputeStick(vp);
                    }
                    else if (isHybrid && !_joyActivated)
                    {
                        HandleWorldTap(vp);
                    }
                    continue;
                }

                // Existing active tap-to-move / hold-to-walk / mobile hold-to-mine-chop-dig / long-press charge-tool finger
                if (useTap && tl.Id == _tapTouchId)
                {
                    if (active)
                    {
                        sawTap = true;
                        _tapCurScreen = vp;
                        float moved = Vector2.Distance(vp, _tapStartScreen);
                        float chargeWobble = Math.Max(56f, _vpH * 0.060f);
                        float tapWobble = Math.Max(38f, _vpH * 0.042f);
                        if (!_tapChargingTool && !_holdWalking && !_tapHoldSwinging)
                        {
                            double heldSec = nowSec - _tapStartTime;
                            bool canChargeNow = CanChargeCurrentTool();
                            bool isFishingRod = Game1.player?.CurrentTool is FishingRod;

                            if (isFishingRod)
                            {
                                if (canChargeNow && moved < chargeWobble && heldSec >= 0.16)
                                {
                                    _tapChargingTool = true;
                                    ClearPath();
                                    if (Game1.player != null)
                                        Game1.player.faceGeneralDirection(ViewportToWorld(_tapStartScreen));
                                }
                                else if (moved >= chargeWobble)
                                {
                                    _holdWalking = true;
                                    ClearPath();
                                }
                            }
                            else
                            {
                                // Check if finger is holding on a mineable/choppable/diggable target (cached once per touch press!)
                                if (!_tapPressIntentComputed)
                                {
                                    _tapPressStartWorld = ViewportToWorld(_tapStartScreen);
                                    _tapPressStartTile = new Point((int)Math.Floor(_tapPressStartWorld.X / 64f), (int)Math.Floor(_tapPressStartWorld.Y / 64f));
                                    _tapPressHoldIntent = AutoToolAndCombat.InspectHoldToolTarget(Game1.currentLocation, _tapPressStartTile, Game1.player, _cfg.AutoTool);
                                    _tapPressIntentComputed = true;
                                }
                                Vector2 startWorld = _tapPressStartWorld;
                                Point startTile = _tapPressStartTile;
                                TileIntent holdIntent = _tapPressHoldIntent;
                                bool isHoldToolTarget = holdIntent.Kind == TileActionKind.UseTool;

                                // Keep 3x1 / 5x1 / 3x3 / 6x3 / 5x5 charge hold for upgraded Hoe (dirt) or upgraded WateringCan (crops/ground)
                                int curIdx = Game1.player != null ? Game1.player.CurrentToolIndex : -1;
                                bool usesHeldTool = holdIntent.PreferredToolSlot < 0 || holdIntent.PreferredToolSlot == curIdx;
                                bool preferChargeUpgraded = canChargeNow && usesHeldTool &&
                                    ((Game1.player?.CurrentTool is Hoe && !holdIntent.Repeatable) ||
                                     (Game1.player?.CurrentTool is WateringCan));

                                if (preferChargeUpgraded && moved < chargeWobble && heldSec >= 0.18)
                                {
                                    _tapChargingTool = true;
                                    ClearPath();
                                    if (Game1.player != null)
                                        Game1.player.faceGeneralDirection(startWorld);
                                }
                                else if (isHoldToolTarget && !preferChargeUpgraded && moved < chargeWobble && heldSec >= 0.14)
                                {
                                    _tapHoldSwinging = true;
                                    _tapHoldTile = holdIntent.HasResolvedTile ? holdIntent.ResolvedTile : startTile;
                                    _tapHoldCooldown = 0;
                                    ClearPath();
                                }
                                else if (canChargeNow && !isHoldToolTarget && moved < chargeWobble && heldSec >= 0.20)
                                {
                                    _tapChargingTool = true;
                                    ClearPath();
                                    if (Game1.player != null)
                                        Game1.player.faceGeneralDirection(startWorld);
                                }
                                else if (moved >= ((isHoldToolTarget || preferChargeUpgraded) ? chargeWobble : tapWobble) || (!isHoldToolTarget && !canChargeNow && heldSec >= 0.28))
                                {
                                    _holdWalking = true;
                                    ClearPath();
                                }
                            }
                        }
                    }
                    else
                    {
                        if (!_holdWalking && !_tapChargingTool && !_tapHoldSwinging)
                            HandleWorldTap(vp);
                        if (_tapHoldSwinging)
                            ClearPath();
                        _holdWalking = false;
                        _tapChargingTool = false;
                        _tapHoldSwinging = false;
                        _tapHoldCooldown = 0;
                        _tapTouchId = -1;
                    }
                    continue;
                }

                // Tap-to-Move Fishing Cast Sideways Bend (drag left/right while bobber is flying to steer into bubbles!)
                if (useTap && tl.Id == _fishBendTouchId)
                {
                    if (active && Game1.player?.CurrentTool is FishingRod bendRod && (bendRod.isCasting || bendRod.castedButBobberStillInAir))
                    {
                        float dx = vp.X - _fishBendStartVp.X;
                        _fishBendX = Math.Abs(dx) >= 18f ? Math.Sign(dx) : 0f;
                    }
                    else
                    {
                        _fishBendTouchId = -1;
                        _fishBendX = 0f;
                    }
                    continue;
                }

                // New touch pressed
                if (tl.State == TouchLocationState.Pressed)
                {
                    // Tap-to-Move: steer flying fishing bobber sideways into fish bubbles!
                    if (useTap && Game1.player?.CurrentTool is FishingRod castRod && (castRod.isCasting || castRod.castedButBobberStillInAir))
                    {
                        _fishBendTouchId = tl.Id;
                        _fishBendStartVp = vp;
                        _fishBendX = 0f;
                        continue;
                    }

                    // 0ms instant Fishing Hook/Reel when bobber is in water in Tap-to-Move / Hybrid mode!
                    if (useTap && Game1.player?.CurrentTool is FishingRod curRod && (curRod.isFishing || curRod.isNibbling))
                    {
                        ClearPath();
                        _actionPulseXFrames = 3;
                        _toolbarTouchId = tl.Id;
                        _toolbarTappedSlot = -1;
                        _toolbarSwiped = true;
                        sawToolbar = true;
                        continue;
                    }

                    // Direct Touch Drag-to-Aim when holding a Slingshot (outside Joystick zone — respects Left-Handed flip!
                    // In pure Tap-to-Move mode without joystick, only capture drag near the farmer's body so tapping ground/ladders/doors walks normally!)
                    bool joyHalf = _cfg.LeftHandedMobile ? (vp.X > _vpW * 0.56f) : (vp.X < _vpW * 0.44f);
                    bool inJoyZoneCheck = useJoy && (IsInvisibleBarMode
                        ? _invJoyRect.Contains(vpPt)
                        : (Vector2.Distance(vp, _visJoyCenter) <= _visJoyRadius * 2.0f || (joyHalf && vp.Y >= _vpH * 0.35f)));
                    bool allowSlingPress = useJoy ||
                        (Game1.player != null && Vector2.Distance(vp, WorldToViewport(Game1.player.getStandingPosition() - new Vector2(0f, 32f))) <= Math.Max(104f, _vpH * 0.17f));

                    if (holdingSlingshot && _slingshotTouchId < 0 && !inJoyZoneCheck && allowSlingPress)
                    {
                        _slingshotTouchId = tl.Id;
                        _slingshotReleaseHoldFrames = 0;
                        _slingshotRawPos = tl.Position;
                        _slingshotVpPos = vp;
                        _slingshotNorm = new Vector2(vp.X / Math.Max(1f, _vpW), vp.Y / Math.Max(1f, _vpH));
                        sawSlingshot = true;
                        ClearPath();
                        continue;
                    }

                    if (use2Btn)
                    {
                        bool inTool = HitTestToolZone(vp, vpPt);
                        bool inInteract = HitTestActZone(vp, vpPt);

                        if (inTool && inInteract)
                        {
                            Rectangle tr = IsInvisibleBarMode ? _invToolRect : _visToolRect;
                            Rectangle ar = IsInvisibleBarMode ? _invActRect : _visActRect;
                            float dTool = Vector2.DistanceSquared(vp, tr.Center.ToVector2());
                            float dInt = Vector2.DistanceSquared(vp, ar.Center.ToVector2());
                            inTool = dTool <= dInt;
                            inInteract = !inTool;
                        }

                        if (inTool && _toolTouchId < 0)
                        {
                            _toolTouchId = tl.Id;
                            sawTool = true;
                            if (_cfg.ShowTouchHint) _toolRippleAlpha = 1f;
                            ClearPath();
                            continue;
                        }
                        if (inInteract && _interactTouchId < 0)
                        {
                            _interactTouchId = tl.Id;
                            sawInteract = true;
                            if (_cfg.ShowTouchHint) _interactRippleAlpha = 1f;
                            ClearPath();
                            continue;
                        }
                    }

                    if (useJoy && _joyTouchId < 0 && inJoyZoneCheck)
                    {
                        _joyTouchId = tl.Id;
                        _joyTouchStart = vp;
                        _joyTouchStartTime = nowSec;
                        if (!IsInvisibleBarMode)
                        {
                            // Visible 2-Button Pixel mode: ALWAYS stay firmly anchored at _visJoyCenter (never jump to bottom edge!)
                            _joyOrigin = _visJoyCenter;
                        }
                        else
                        {
                            // Floating invisible joystick: clamp cleanly inside screen edges so ring never clips off bottom/sides
                            float jr = _activeJoyRadius;
                            float cx = Math.Clamp(vp.X, jr + 10f, Math.Max(jr + 10f, _vpW - jr - 10f));
                            float cy = Math.Clamp(vp.Y, jr + 10f, Math.Max(jr + 10f, _vpH - jr - 10f));
                            _joyOrigin = new Vector2(cx, cy);
                        }
                        _joyOriginNorm = new Vector2(_joyOrigin.X / Math.Max(1f, _vpW), _joyOrigin.Y / Math.Max(1f, _vpH));
                        _joyKnob = _joyOrigin;
                        _joyKnobNorm = _joyOriginNorm;
                        _joyActivated = !isHybrid;
                        if (_joyActivated)
                        {
                            ClearPath();
                            stickVec = ComputeStick(vp);
                        }
                        sawJoy = true;
                        continue;
                    }

                    if (useTap && _tapTouchId < 0)
                    {
                        _tapTouchId = tl.Id;
                        _tapStartScreen = vp;
                        _tapCurScreen = vp;
                        _tapStartTime = nowSec;
                        _holdWalking = false;
                        _tapChargingTool = false;
                        _tapHoldSwinging = false;
                        _tapHoldCooldown = 0;
                        _tapPressIntentComputed = false;
                        sawTap = true;

                        // Tap-to-Move Instant Fishing Rod Charge:
                        // When holding a FishingRod near water and pressing on water, begin charging IMMEDIATELY
                        // (0ms delay, wobble-proof) and hold ButtonX continuously until finger is lifted!
                        if (CanChargeCurrentTool() && Game1.player?.CurrentTool is FishingRod pressRod &&
                            !pressRod.isCasting && !pressRod.castedButBobberStillInAir &&
                            Game1.currentLocation != null && !Game1.player.UsingTool)
                        {
                            Vector2 wPos = ViewportToWorld(vp);
                            Point tapT = new Point((int)Math.Floor(wPos.X / 64f), (int)Math.Floor(wPos.Y / 64f));
                            if (IsWaterInFishingCastReach(Game1.currentLocation, Game1.player.TilePoint, tapT))
                            {
                                _tapChargingTool = true;
                                ClearPath();
                                Game1.player.faceGeneralDirection(wPos);
                            }
                        }
                        continue;
                    }

                    // In Invisible / 2-Button mode: tapping an adjacent/diagonal tile right next to the player
                    // outside Joystick & USE/ACT zones lets you interact with diagonal chests/machines/wall decor!
                    if (!useTap && TryDirectAdjacentTileTap(vp))
                    {
                        continue;
                    }
                }
            }

            if (!sawToolbar) { _toolbarTouchId = -1; _toolbarTappedSlot = -1; _toolbarSwiped = false; }
            if (!sawVertTb) _verticalToolbar.ResetTouch();
            if (!sawJoy) { _joyTouchId = -1; _joyActivated = false; }
            if (!sawTool) _toolTouchId = -1;
            if (!sawInteract) _interactTouchId = -1;
            if (!sawTap) { _tapTouchId = -1; _holdWalking = false; _tapChargingTool = false; _tapHoldSwinging = false; _tapHoldCooldown = 0; _tapPressIntentComputed = false; }
            if (!sawSlingshot) _slingshotTouchId = -1;

            _toolPressed = sawTool || _tapChargingTool;
            _interactPressed = sawInteract;

            // Lock movement strictly to zero while charging a tool (prevents wobble cancelling FishingRod cast!)
            if (_tapChargingTool)
                stickVec = Vector2.Zero;

            // --- 1b. Stardew Mobile-style Hold-to-Mine / Hold-to-Chop / Hold-to-Dig ---
            // While holding finger on any rock/ore/boulder/stump/tree/twig/weed/barrel/monster/artifact/diggable tile:
            // smoothly walk up (if >1 tile away) and continuously swing until broken or finger is lifted!
            if (_tapHoldSwinging && !_tapChargingTool && Game1.player != null && Game1.currentLocation != null)
            {
                Farmer hw = Game1.player;
                GameLocation hloc = Game1.currentLocation;

                // Allow dragging finger from one rock/tree/dirt tile to the next while holding (just like Stardew Mobile!)
                Vector2 curWorld = ViewportToWorld(_tapCurScreen);
                Point curTile = new Point((int)Math.Floor(curWorld.X / 64f), (int)Math.Floor(curWorld.Y / 64f));
                if (curTile != _tapHoldTile)
                {
                    TileIntent dragIntent = AutoToolAndCombat.InspectHoldToolTarget(hloc, curTile, hw, _cfg.AutoTool);
                    if (dragIntent.Kind == TileActionKind.UseTool)
                    {
                        _tapHoldTile = dragIntent.HasResolvedTile ? dragIntent.ResolvedTile : curTile;
                        ClearPath();
                    }
                }

                TileIntent curHoldIntent = AutoToolAndCombat.InspectHoldToolTarget(hloc, _tapHoldTile, hw, _cfg.AutoTool);
                if (curHoldIntent.Kind == TileActionKind.UseTool)
                {
                    Point holdTarget = curHoldIntent.HasResolvedTile ? curHoldIntent.ResolvedTile : _tapHoldTile;
                    int hdx = Math.Abs(hw.TilePoint.X - holdTarget.X);
                    int hdy = Math.Abs(hw.TilePoint.Y - holdTarget.Y);
                    int hCheb = Math.Max(hdx, hdy);
                    bool inHoldReach = (hCheb == 1) || (hCheb == 0 && (hw.CurrentTool is WateringCan || hw.CurrentTool is MeleeWeapon));

                    if (inHoldReach)
                    {
                        ClearPath();
                        stickVec = Vector2.Zero;
                        if (curHoldIntent.PreferredToolSlot >= 0 && curHoldIntent.PreferredToolSlot < hw.Items.Count)
                        {
                            if (_cfg.RestoreToolAfterAuto && hw.CurrentToolIndex != curHoldIntent.PreferredToolSlot && _autoToolPrevSlot < 0)
                            {
                                _autoToolPrevSlot = hw.CurrentToolIndex;
                                _autoToolRestoreTimer = 36;
                            }
                            hw.CurrentToolIndex = curHoldIntent.PreferredToolSlot;
                        }
                        if (!hw.UsingTool)
                        {
                            if (_tapHoldCooldown > 0)
                                _tapHoldCooldown--;
                            else if (hw.Stamina > 2f || hw.CurrentTool is MeleeWeapon)
                            {
                                if (FireTargetedToolSwing(hw, holdTarget))
                                    _tapHoldCooldown = 3;
                            }
                        }
                    }
                    else
                    {
                        // Walk smoothly up to the held rock/tree/dirt tile, then automatically start swinging on arrival!
                        if (_path == null || !_hasTargetTile || _targetTile != holdTarget)
                        {
                            List<Point> approach = PathFinder.FindPath(hloc, hw.TilePoint, holdTarget, hw, stopAdjacent: true, preferCardinal: curHoldIntent.PreferCardinal);
                            if (approach != null && approach.Count > 0)
                            {
                                ClearPath();
                                _path = approach;
                                _pathIdx = 0;
                                _targetTile = holdTarget;
                                _hasTargetTile = true;
                                _pendingIntent = new TileIntent { Kind = TileActionKind.None, PreferredToolSlot = -1 };
                                _lastPlayerPos = hw.Position;
                                _stuckFrames = 0;
                            }
                        }
                    }
                }
            }

            // --- 2. Hold-to-Walk (+ Smooth Auto-Harvest/Machine Sweep in Tap-to-Move!) ---
            if (_holdWalking && !_tapChargingTool && stickVec == Vector2.Zero && Game1.player != null)
            {
                Vector2 playerScreen = WorldToViewport(Game1.player.GetBoundingBox().Center.ToVector2());
                Vector2 diff = _tapCurScreen - playerScreen;
                if (diff.Length() > 26f)
                {
                    diff.Normalize();
                    stickVec = diff;
                    TryHoldWalkAutoHarvest(Game1.player, Game1.currentLocation);
                }
            }

            // --- 2b. Apply Tap-to-Move Fishing Cast Sideways Bend while bobber is in flight ---
            if (_fishBendTouchId >= 0)
            {
                if (Game1.player?.CurrentTool is FishingRod frFly && (frFly.isCasting || frFly.castedButBobberStillInAir))
                {
                    if (Math.Abs(_fishBendX) > 0.1f)
                        stickVec = new Vector2(_fishBendX, 0f);
                }
                else
                {
                    _fishBendTouchId = -1;
                    _fishBendX = 0f;
                }
            }

            // --- 3. A* Tap-to-Move Path Follower + Door/Warp Exit Push ---
            if (Game1.fadeToBlack || Game1.dialogueUp || Game1.activeClickableMenu != null || IsBlockingCutsceneActive())
            {
                _warpPushFrames = 0;
                _actionPulseAFrames = 0;
                _actionPulseXFrames = 0;
            }
            if (_warpPushFrames > 0 && Game1.hudMessages != null && Game1.hudMessages.Count > _warpPushStartHudCount)
                _warpPushFrames = 0;

            if (stickVec == Vector2.Zero && !_toolPressed && !_interactPressed && !sawSlingshot)
            {
                if (_path != null)
                {
                    stickVec = StepPathFollower();
                }
                else if (_warpPushFrames > 0 && Game1.player != null && !Game1.fadeToBlack)
                {
                    _warpPushFrames--;
                    Vector2 warpCenter = new Vector2(_pendingWarpTile.X * 64f + 32f, _pendingWarpTile.Y * 64f + 32f);
                    Vector2 playerCenter = Game1.player.GetBoundingBox().Center.ToVector2();
                    Vector2 diff = warpCenter - playerCenter;
                    if (diff.LengthSquared() > 4f)
                    {
                        diff.Normalize();
                        stickVec = diff;
                    }
                    else
                    {
                        // Nudge straight toward map edge if player is already centered on the warp tile
                        int mapH = Game1.currentLocation?.Map?.Layers?[0]?.LayerHeight ?? 0;
                        int mapW = Game1.currentLocation?.Map?.Layers?[0]?.LayerWidth ?? 0;
                        if (mapH > 0 && _pendingWarpTile.Y >= mapH - 2) stickVec = new Vector2(0f, 1f);
                        else if (_pendingWarpTile.Y <= 1) stickVec = new Vector2(0f, -1f);
                        else if (mapW > 0 && _pendingWarpTile.X >= mapW - 2) stickVec = new Vector2(1f, 0f);
                        else if (_pendingWarpTile.X <= 1) stickVec = new Vector2(-1f, 0f);
                    }
                }
            }

            // --- 4. Action Pulses + Direct Animal/Pet Petting Assist + Auto-Repeat 1-tap chop/mine until broken ---
            bool freshActPress = _interactPressed && !_prevInteractPressed;
            _prevInteractPressed = _interactPressed;
            if (!_interactPressed)
                _suppressActUntilRelease = false;
            if (freshActPress && Game1.currentLocation != null && Game1.player != null &&
                TryDirectPetAnimalOrPet(Game1.currentLocation, Game1.player, null, onlyIfNoBlockingObject: true))
            {
                // Suppress raw ButtonA until release so petting an animal NEVER double-opens AnimalQueryMenu on the same tap!
                _suppressActUntilRelease = true;
            }

            bool fireX = _toolPressed || sawSlingshot;
            bool fireA = _interactPressed && !_suppressActUntilRelease;
            if (_actionPulseXFrames > 0) { _actionPulseXFrames--; fireX = true; }
            if (_actionPulseAFrames > 0) { _actionPulseAFrames--; fireA = true; }

            if (_repeatActive)
            {
                Farmer rw = Game1.player;
                GameLocation rloc = Game1.currentLocation;
                int errHudNow = CountErrorHudMessages();
                if (!_cfg.AutoRepeat ||
                    rw == null ||
                    rloc == null ||
                    rw.isRidingHorse() ||
                    !rw.CanMove ||
                    Game1.activeClickableMenu != null ||
                    Game1.dialogueUp ||
                    !CanUseToolInCurrentState() ||
                    Game1.fadeToBlack ||
                    stickVec.LengthSquared() > 0.04f ||
                    _toolPressed ||
                    _interactPressed ||
                    _tapHoldSwinging ||
                    sawSlingshot ||
                    rw.Stamina <= 4f ||
                    _repeatSwings >= 24 ||
                    errHudNow > _repeatStartHudCount)
                {
                    _repeatActive = false;
                }
                else if (rw.UsingTool)
                {
                    _repeatObservedSwing = true;
                }
                else
                {
                    if (_repeatCooldown > 0)
                    {
                        _repeatCooldown--;
                    }
                    else
                    {
                        int rdx = Math.Abs(rw.TilePoint.X - _repeatTile.X);
                        int rdy = Math.Abs(rw.TilePoint.Y - _repeatTile.Y);
                        int cheb = Math.Max(rdx, rdy);
                        bool inReach = (cheb == 1);
                        if (inReach)
                        {
                            // Zero-progress detector: if 2 completed swings failed to reduce target health, stop immediately!
                            if (_repeatObservedSwing)
                            {
                                float curHp = AutoToolAndCombat.GetTargetHealth(rloc, _repeatTile);
                                if (curHp > 0f && _repeatLastHealth > 0f && curHp >= _repeatLastHealth - 0.001f)
                                {
                                    if (++_repeatNoProgressSwings >= 2)
                                    {
                                        _repeatActive = false;
                                    }
                                }
                                else
                                {
                                    _repeatNoProgressSwings = 0;
                                    _repeatLastHealth = curHp;
                                }
                                _repeatObservedSwing = false;
                            }

                            if (_repeatActive)
                            {
                                TileIntent nextIntent = AutoToolAndCombat.InspectTile(rloc, _repeatTile, rw, _cfg.AutoTool);
                                if (nextIntent.Repeatable && nextIntent.Kind == TileActionKind.UseTool)
                                {
                                    if (nextIntent.PreferredToolSlot >= 0 && nextIntent.PreferredToolSlot < rw.Items.Count)
                                        rw.CurrentToolIndex = nextIntent.PreferredToolSlot;
                                    if (FireTargetedToolSwing(rw, _repeatTile))
                                    {
                                        _repeatSwings++;
                                        _repeatCooldown = 4;
                                    }
                                    else
                                    {
                                        FaceTargetTile(rw, _repeatTile);
                                        _actionPulseXFrames = 2;
                                        fireX = true;
                                        _repeatSwings++;
                                        _repeatCooldown = 6;
                                    }
                                }
                                else
                                {
                                    _repeatActive = false;
                                }
                            }
                        }
                        else
                        {
                            _repeatActive = false;
                        }
                    }
                }
            }

            // --- 4b. Optional restore previous item slot after Auto-Tool finishes ---
            if (_autoToolPrevSlot >= 0)
            {
                Farmer fw = Game1.player;
                if (!_cfg.RestoreToolAfterAuto || fw == null)
                {
                    _autoToolPrevSlot = -1;
                    _autoToolRestoreTimer = 0;
                }
                else if (fw.UsingTool || _repeatActive || fireX || fireA)
                {
                    _autoToolRestoreTimer = 30;
                }
                else if (_autoToolRestoreTimer > 0)
                {
                    if (--_autoToolRestoreTimer == 0)
                    {
                        if (_autoToolPrevSlot >= 0 && _autoToolPrevSlot < fw.Items.Count)
                            fw.CurrentToolIndex = _autoToolPrevSlot;
                        _autoToolPrevSlot = -1;
                    }
                }
            }

            // --- 5. Queued Weapon Special Move & Optional Auto-Attack (DEFAULT OFF) ---
            if (_pendingWeaponSpecTicks > 0)
            {
                _pendingWeaponSpecTicks--;
                MeleeWeapon qSpec = GetHeldSpecialWeapon();
                if (qSpec == null || IsWeaponSpecialOnCooldown(qSpec) || Game1.player == null)
                {
                    _pendingWeaponSpecTicks = 0;
                }
                else if (!Game1.player.UsingTool)
                {
                    _pendingWeaponSpecTicks = 0;
                    try { qSpec.animateSpecialMove(Game1.player); } catch { }
                    ClearPath();
                }
            }
            else if (_cfg.AutoAttack && !fireX && !fireA && !sawSlingshot)
            {
                bool movingAway = stickVec.LengthSquared() > 0.25f;
                if (AutoToolAndCombat.TryAutoAttack(Game1.currentLocation, Game1.player, movingAway, ref _autoAttackCooldown))
                {
                    _actionPulseXFrames = 2;
                    fireX = true;
                    ClearPath();
                }
            }

            // --- 6. Optional Safe Periodic Auto-Save (DEFAULT OFF, skips Mines/Volcano/Combat/Moving) ---
            TryPeriodicAutoSave(br, stickVec, fireX || fireA || sawSlingshot, nowSec);

            // --- 7. Tiered Auto-Unstick Watchdog (rescues ALL Stardew freeze locks WITHOUT ever cancelling normal tool swings,
            //        eating animations, or active FishingRod casts!) ---
            if (stickVec.LengthSquared() > 0.08f &&
                !_toolPressed && !_interactPressed && !sawSlingshot &&
                Game1.player != null &&
                Game1.activeClickableMenu == null &&
                !IsBlockingCutsceneActive() && !Game1.dialogueUp && !Game1.fadeToBlack &&
                Game1.currentMinigame == null)
            {
                Farmer uWho = Game1.player;
                FishingRod uFr = uWho.CurrentTool as FishingRod;
                bool activeFishingState = uFr != null &&
                    (uFr.isCasting || uFr.castedButBobberStillInAir || uFr.isFishing || uFr.isNibbling ||
                     uFr.isReeling || uFr.pullingOutOfWater || uFr.fishCaught || uFr.showingTreasure);
                bool stuckTimingCast = uFr != null && uFr.isTimingCast;
                bool strayKbSub = Game1.keyboardDispatcher != null && Game1.keyboardDispatcher.Subscriber != null &&
                                  (Game1.chatBox == null || !Game1.chatBox.isActive());

                int unstickThreshold = 0;
                if (activeFishingState)
                {
                    // Never interrupt an active cast/fishing animation
                    unstickThreshold = 0;
                }
                else if (stuckTimingCast)
                {
                    // Safety net ONLY if isTimingCast stays stuck with !_toolPressed for > 2.5s
                    unstickThreshold = 150;
                }
                else if (uWho.isEating)
                {
                    // Allow full ~1.5s eating animation to finish healing HP/energy before rescuing
                    unstickThreshold = 135;
                }
                else if (uWho.UsingTool)
                {
                    // Allow full ~0.55s Axe/Pickaxe/Hoe/Weapon swing to land before treating as stuck
                    unstickThreshold = 55;
                }
                else if (uWho.mount != null && (uWho.mount.dismounting.Value || uWho.mount.mounting.Value))
                {
                    // Never interrupt active Horse mount/dismount hop animation
                    unstickThreshold = 0;
                }
                else if (uWho.freezePause > 0)
                {
                    // Allow full ~1.5s Warp Totem / Return Scepter / Obelisk animation to complete before safety rescue
                    unstickThreshold = 150;
                }
                else if (!uWho.CanMove ||
                         Game1.freezeControls ||
                         (uWho.FarmerSprite != null && uWho.FarmerSprite.PauseForSingleAnimation) ||
                         uWho.usingSlingshot ||
                         uWho.controller != null ||
                         strayKbSub)
                {
                    // Pure freeze lock (not swinging/eating/fishing/warping): rescue fast at 20 ticks (~0.33s),
                    // well before StepPathFollower's 36-tick path abort so Tap-to-Move ALSO recovers!
                    unstickThreshold = 20;
                }

                if (unstickThreshold > 0)
                {
                    if (++_unstickHoldTicks >= unstickThreshold)
                    {
                        _unstickHoldTicks = 0;
                        _unstickStillTicks = 0;
                        try
                        {
                            if (uWho.IsSitting()) uWho.StopSitting(animate: false);
                            uWho.completelyStopAnimatingOrDoingAction();
                            uWho.forceCanMove();
                            uWho.controller = null;
                            if (uFr != null && !activeFishingState)
                            {
                                uFr.isTimingCast = false;
                                uFr.isCasting = false;
                                uFr.pullingOutOfWater = false;
                            }
                            if (strayKbSub)
                                Game1.keyboardDispatcher.Subscriber = null;
                        }
                        catch { }
                    }
                }
                else
                {
                    _unstickHoldTicks = 0;
                    // Secondary watchdog: if farmer is pushing joystick/path for 36 ticks without moving even 1px
                    // while sitting/emoting, release sitting/emote cleanly!
                    if (Vector2.DistanceSquared(uWho.Position, _unstickLastPos) < 1.5f)
                    {
                        if (++_unstickStillTicks >= 36 && !activeFishingState && !uWho.isEating && !uWho.UsingTool)
                        {
                            _unstickStillTicks = 0;
                            if (uWho.IsSitting() || uWho.IsEmoting)
                            {
                                try
                                {
                                    if (uWho.IsSitting()) uWho.StopSitting(animate: false);
                                    uWho.IsEmoting = false;
                                    uWho.forceCanMove();
                                }
                                catch { }
                            }
                        }
                    }
                    else
                    {
                        _unstickLastPos = uWho.Position;
                        _unstickStillTicks = 0;
                    }
                }
            }
            else
            {
                _unstickHoldTicks = 0;
                _unstickStillTicks = 0;
                if (Game1.player != null)
                    _unstickLastPos = Game1.player.Position;
            }

            // Direct Mobile FishingRod Cast-Charge Initiation (exact same clean path as FishingRod.tickUpdate recast!):
            // Calling Farmer.BeginUsingTool() directly when holding USE with an idle FishingRod avoids
            // Game1.pressUseToolButton() / TouchDelegatingModHooks double-fire & stale cursor facing, so
            // isTimingCast starts on Frame 1 with continuous power charging until finger is lifted!
            if ((_toolPressed || _tapChargingTool) &&
                !sawSlingshot &&
                Game1.player != null &&
                Game1.player.CurrentTool is FishingRod idleRod &&
                !Game1.player.UsingTool &&
                Game1.player.CanMove &&
                !Game1.player.isEating &&
                !Game1.player.isRidingHorse() &&
                !Game1.player.IsSitting() &&
                !idleRod.isTimingCast &&
                !idleRod.isCasting &&
                !idleRod.castedButBobberStillInAir &&
                !idleRod.isFishing &&
                !idleRod.isNibbling &&
                !idleRod.isReeling &&
                !idleRod.pullingOutOfWater &&
                !idleRod.fishCaught &&
                !idleRod.showingTreasure &&
                Game1.activeClickableMenu == null &&
                !Game1.dialogueUp &&
                CanUseToolInCurrentState() &&
                !Game1.fadeToBlack)
            {
                try
                {
                    Game1.player.Halt();
                    Game1.player.BeginUsingTool();
                }
                catch { }
            }

            if (sawSlingshot)
            {
                Point aimRaw = new Point((int)_slingshotRawPos.X, (int)_slingshotRawPos.Y);
                try { Game1.lastCursorMotionWasMouse = true; } catch { }
                EnsureBridge(pad)?.ApplyInputWithMouse(pad, StabilizeMoveStick(stickVec), true, false, false, aimRaw, true, false, _rawW, _rawH);
            }
            else if (_slingshotReleaseHoldFrames > 0)
            {
                // Preserve exact release aim coordinates with LeftButton=Released for 2 frames so Slingshot.PerformFire() -> updateAimPos() never aims at (0, 0)!
                _slingshotReleaseHoldFrames--;
                Point aimRaw = new Point((int)_slingshotRawPos.X, (int)_slingshotRawPos.Y);
                try { Game1.lastCursorMotionWasMouse = true; } catch { }
                EnsureBridge(pad)?.ApplyInputWithMouse(pad, StabilizeMoveStick(stickVec), false, false, false, aimRaw, false, false, _rawW, _rawH);
            }
            else if ((_toolPressed || _tapChargingTool) && Game1.player?.CurrentTool is FishingRod timingRod && timingRod.isTimingCast)
            {
                // Keep BOTH ButtonX (Keys.C / useToolButton) AND MouseState.LeftButton == Pressed continuously
                // from Frame 1 while charging cast power so FishingRod.tickUpdate never prematurely casts!
                _smoothedStick = Vector2.Zero;
                _hystAxisX = 0;
                _hystAxisY = 0;
                Point holdPos = new Point(Math.Max(1, _rawW / 2), Math.Max(1, _rawH / 2));
                EnsureBridge(pad)?.ApplyInputWithMouse(pad, Vector2.Zero, true, false, false, holdPos, true, false, _rawW, _rawH);
                Game1.lastCursorMotionWasMouse = false;
            }
            else
            {
                if (fireX)
                    Game1.lastCursorMotionWasMouse = false;
                ApplyToPad(pad, StabilizeMoveStick(stickVec), fireX, fireA, false);
            }
        }

        private static bool CanChargeCurrentTool()
        {
            var tool = Game1.player?.CurrentTool;
            if (tool is FishingRod fr)
                return !fr.isFishing && !fr.isReeling && !fr.isNibbling;
            return (tool is Hoe || tool is WateringCan) && tool.UpgradeLevel >= 1;
        }

        private void TryHoldWalkAutoHarvest(Farmer who, GameLocation loc)
        {
            if (!_cfg.AutoTool || who == null || loc == null || who.UsingTool || who.isRidingHorse())
                return;
            if (_holdSweepCooldown > 0)
            {
                _holdSweepCooldown--;
                return;
            }
            Point pt = who.TilePoint;
            int fx = who.FacingDirection == 1 ? 1 : (who.FacingDirection == 3 ? -1 : 0);
            int fy = who.FacingDirection == 2 ? 1 : (who.FacingDirection == 0 ? -1 : 0);
            Point front = new Point(pt.X + fx, pt.Y + fy);
            Vector2 tv = new Vector2(front.X, front.Y);

            bool ready = false;
            if (loc.objects != null && loc.objects.TryGetValue(tv, out StardewValley.Object obj) && obj != null)
            {
                if (obj.readyForHarvest.Value || obj.IsSpawnedObject)
                    ready = true;
            }
            else if (loc.terrainFeatures != null && loc.terrainFeatures.TryGetValue(tv, out StardewValley.TerrainFeatures.TerrainFeature tf) && tf is StardewValley.TerrainFeatures.HoeDirt hd)
            {
                if (hd.crop != null && hd.readyForHarvest() && hd.crop.GetHarvestMethod() != StardewValley.GameData.Crops.HarvestMethod.Scythe)
                    ready = true;
            }

            if (ready)
            {
                _actionPulseAFrames = 1;
                _holdSweepCooldown = 8;
            }
        }

        private void TryPeriodicAutoSave(PadBridge br, Vector2 stickVec, bool anyAction, double nowSec)
        {
            if (_cfg.AutoSaveMinutes <= 0 || br == null || Game1.player == null || Game1.currentLocation == null || Game1.eventUp || Game1.dialogueUp ||
                (Game1.IsMultiplayer && !Game1.IsMasterGame))
                return;

            // Initialize timer on first gameplay tick so it doesn't save immediately on load
            if (_lastAutoSaveSec < 0)
            {
                _lastAutoSaveSec = nowSec;
                _lastAutoSaveTimeOfDay = Game1.timeOfDay;
                _lastAutoSaveLoc = Game1.currentLocation.NameOrUniqueName;
                return;
            }

            // Never interrupt combat, mines, volcano, tool swing, fishing, or movement!
            bool busy = stickVec.LengthSquared() > 0.01f || anyAction ||
                        Game1.player.UsingTool || Game1.player.isMoving() ||
                        (Game1.player.CurrentTool is FishingRod fr && (fr.isFishing || fr.isCasting || fr.isReeling)) ||
                        Game1.currentLocation is MineShaft || Game1.currentLocation is VolcanoDungeon ||
                        br.IsMiddaySaving() || br.IsQuickSaveReloading();

            if (busy)
            {
                _idleSinceSec = -1;
                return;
            }

            if (_idleSinceSec < 0)
                _idleSinceSec = nowSec;

            // Wait until player stands still >= 1.0s in a safe area AND interval elapsed AND game progressed
            double intervalSec = _cfg.AutoSaveMinutes * 60.0;
            if ((nowSec - _lastAutoSaveSec) < intervalSec || (nowSec - _idleSinceSec) < 1.0)
                return;

            string curLoc = Game1.currentLocation.NameOrUniqueName;
            if (Game1.timeOfDay == _lastAutoSaveTimeOfDay && string.Equals(curLoc, _lastAutoSaveLoc, StringComparison.Ordinal))
                return;

            _lastAutoSaveSec = nowSec;
            _lastAutoSaveTimeOfDay = Game1.timeOfDay;
            _lastAutoSaveLoc = curLoc;
            _idleSinceSec = -1;

            _saveSlots.BeginPendingSnapshot(br, isAutoSave: true);
            if (br.TryQuickSave(out _))
            {
                ShowSaveToast("AUTO-SAVE...", nowSec);
            }
            else
            {
                _saveSlots.CancelPendingSnapshot();
            }
        }

        // =========================================================================
        // DEDICATED EDIT LAYOUT MODE + IN-GAME PC KEY PICKER
        // =========================================================================
        private void UpdateEditLayoutTouches(TouchCollection touches)
        {
            if (touches.Count == 0)
            {
                _editTouchId = -1;
                _editDragTarget = EditTarget.None;
                _editDragCustomId = -1;
                _editResizing = false;
                return;
            }

            // If PC Key Picker modal is open inside Edit Layout, handle taps on key tiles
            if (_keyPickerOpen)
            {
                for (int i = 0; i < touches.Count; i++)
                {
                    TouchLocation tl = touches[i];
                    if (tl.State != TouchLocationState.Pressed) continue;
                    Vector2 vp = MapRawToViewport(tl.Position);
                    Point pt = new Point((int)vp.X, (int)vp.Y);

                    if (_pickerCloseRect.Contains(pt) || !_pickerPanelRect.Contains(pt))
                    {
                        _keyPickerOpen = false;
                        _editTouchId = tl.Id;
                        _editDragTarget = EditTarget.None;
                        try { Game1.playSound("cancel"); } catch { }
                        return;
                    }

                    for (int k = 0; k < PcKeyCatalog.Length; k++)
                    {
                        Rectangle cell = GetKeyPickerCellRect(k);
                        if (cell.Contains(pt))
                        {
                            var kc = PcKeyCatalog[k];
                            var added = _cfg.AddCustomKey(kc.Label, (int)kc.Key);
                            if (added != null)
                            {
                                _editSelected = EditTarget.CustomKey;
                                _editSelectedCustomId = added.Id;
                                ComputeLayout();
                                try { Game1.playSound("coin"); } catch { }
                            }
                            _keyPickerOpen = false;
                            _editTouchId = tl.Id;
                            _editDragTarget = EditTarget.None;
                            return;
                        }
                    }
                }
                return;
            }

            for (int i = 0; i < touches.Count; i++)
            {
                TouchLocation tl = touches[i];
                Vector2 vp = MapRawToViewport(tl.Position);
                Point pt = new Point((int)vp.X, (int)vp.Y);

                if (tl.State == TouchLocationState.Pressed && _editTouchId < 0)
                {
                    // Top center Edit Layout toolbar buttons (+PHIM / XOA / RESET / HUY / LUU)
                    if (_editAddKeyBtnRect.Contains(pt))
                    {
                        _keyPickerOpen = true;
                        _editTouchId = tl.Id;
                        _editDragTarget = EditTarget.None;
                        try { Game1.playSound("smallSelect"); } catch { }
                        return;
                    }
                    if (_editDelKeyBtnRect.Contains(pt))
                    {
                        if (_editSelected == EditTarget.CustomKey && _editSelectedCustomId > 0)
                        {
                            _cfg.RemoveCustomKey(_editSelectedCustomId);
                            _editSelected = EditTarget.None;
                            _editSelectedCustomId = -1;
                            try { Game1.playSound("trashcan"); } catch { }
                        }
                        return;
                    }
                    if (_editResetBtnRect.Contains(pt))
                    {
                        _cfg.ResetLayoutDefaults();
                        _cfg.Save();
                        ComputeLayout();
                        try { Game1.playSound("smallSelect"); } catch { }
                        return;
                    }
                    if (_editCancelBtnRect.Contains(pt))
                    {
                        _cfg.Reload(force: true);
                        ExitEditLayoutMode();
                        try { Game1.playSound("cancel"); } catch { }
                        return;
                    }
                    if (_editSaveBtnRect.Contains(pt))
                    {
                        _cfg.Save();
                        ExitEditLayoutMode();
                        try { Game1.playSound("coin"); } catch { }
                        return;
                    }

                    // 1. Hit-test Custom PC Key buttons FIRST (resize handle then body)
                    EditTarget hit = EditTarget.None;
                    int hitCustomId = -1;
                    bool resize = false;

                    for (int k = _cfg.CustomKeys.Count - 1; k >= 0; k--)
                    {
                        var cb = _cfg.CustomKeys[k];
                        Rectangle cr = GetCustomKeyRect(cb);
                        if (HitResizeHandle(cr, vp))
                        {
                            hit = EditTarget.CustomKey;
                            hitCustomId = cb.Id;
                            resize = true;
                            break;
                        }
                        if (cr.Contains(pt))
                        {
                            hit = EditTarget.CustomKey;
                            hitCustomId = cb.Id;
                            break;
                        }
                    }

                    // 2. Hit-test Vertical Toolbar (if enabled: inner corner handle resizes ToolbarSize, body drags side Left<->Right & Y!)
                    if (hit == EditTarget.None && _cfg.VerticalToolbar && _verticalToolbar.Bounds.Width > 0)
                    {
                        Rectangle tbR = _verticalToolbar.Bounds;
                        if (HitToolbarResizeHandle(tbR, _cfg.ToolbarSide, vp))
                        {
                            hit = EditTarget.Toolbar;
                            resize = true;
                        }
                        else if (tbR.Contains(pt))
                        {
                            hit = EditTarget.Toolbar;
                        }
                    }

                    // 3. Hit-test standard Mobile controls
                    if (hit == EditTarget.None && _cfg.Mode != MobileControlMode.TapToMove)
                    {
                        Rectangle rTool = GetEditRect(EditTarget.Tool);
                        Rectangle rAct = GetEditRect(EditTarget.Act);
                        Rectangle rJoy = GetEditRect(EditTarget.Joy);

                        if (HitResizeHandle(rTool, vp)) { hit = EditTarget.Tool; resize = true; }
                        else if (HitResizeHandle(rAct, vp)) { hit = EditTarget.Act; resize = true; }
                        else if (HitResizeHandle(rJoy, vp)) { hit = EditTarget.Joy; resize = true; }
                        else if (rTool.Contains(pt)) { hit = EditTarget.Tool; }
                        else if (rAct.Contains(pt)) { hit = EditTarget.Act; }
                        else if (rJoy.Contains(pt)) { hit = EditTarget.Joy; }
                    }

                    if (hit == EditTarget.None && _cfg.ShowTopUtility && _topBarGroupRect.Contains(pt))
                        hit = EditTarget.TopBar;

                    if (hit != EditTarget.None)
                    {
                        _editTouchId = tl.Id;
                        _editDragTarget = hit;
                        _editDragCustomId = hitCustomId;
                        _editSelected = hit;
                        _editSelectedCustomId = hitCustomId;
                        _editResizing = resize;
                        _editDragLastVp = vp;
                    }
                }
                else if (tl.State == TouchLocationState.Moved && tl.Id == _editTouchId && _editDragTarget != EditTarget.None)
                {
                    Vector2 d = vp - _editDragLastVp;
                    _editDragLastVp = vp;
                    ApplyEditDelta(_editDragTarget, _editDragCustomId, _editResizing, d, vp);
                    ComputeLayout();
                }
                else if ((tl.State == TouchLocationState.Released || tl.State == TouchLocationState.Invalid) && tl.Id == _editTouchId)
                {
                    if (_editDragTarget != EditTarget.None)
                        _cfg.Save();
                    _editTouchId = -1;
                    _editDragTarget = EditTarget.None;
                    _editDragCustomId = -1;
                    _editResizing = false;
                }
            }
        }

        private Rectangle GetEditRect(EditTarget t)
        {
            switch (t)
            {
                case EditTarget.Joy:
                    if (IsInvisibleBarMode) return _invJoyRect;
                    int jd = (int)(_visJoyRadius * 2f);
                    return new Rectangle((int)(_visJoyCenter.X - _visJoyRadius), (int)(_visJoyCenter.Y - _visJoyRadius), jd, jd);
                case EditTarget.Tool:
                    return IsInvisibleBarMode ? _invToolRect : _visToolRect;
                case EditTarget.Act:
                    return IsInvisibleBarMode ? _invActRect : _visActRect;
                case EditTarget.TopBar:
                    return _topBarGroupRect;
                case EditTarget.Toolbar:
                    return _verticalToolbar.Bounds;
                default:
                    return Rectangle.Empty;
            }
        }

        private Rectangle GetCustomKeyRect(CustomKeyButton b)
        {
            int x = (int)Math.Round(b.X * _vpW);
            int y = (int)Math.Round(b.Y * _vpH);
            int w = Math.Max(36, (int)Math.Round(b.W * _vpW));
            int h = Math.Max(36, (int)Math.Round(b.H * _vpH));
            return new Rectangle(x, y, w, h);
        }

        private bool HitResizeHandle(Rectangle r, Vector2 vp)
        {
            if (r.IsEmpty) return false;
            float grip = Math.Max(38f, Math.Min(_vpW, _vpH) * 0.048f);
            return Math.Abs(vp.X - r.Right) <= grip && Math.Abs(vp.Y - r.Bottom) <= grip;
        }

        private bool HitToolbarResizeHandle(Rectangle r, int side, Vector2 vp)
        {
            if (r.IsEmpty) return false;
            float grip = Math.Max(42f, Math.Min(_vpW, _vpH) * 0.055f);
            float hx = side == 1 ? r.Left : r.Right;
            float hy = r.Bottom;
            return Math.Abs(vp.X - hx) <= grip && Math.Abs(vp.Y - hy) <= grip;
        }

        private void ApplyEditDelta(EditTarget target, int customId, bool resize, Vector2 deltaPx, Vector2 curVp)
        {
            float dx = deltaPx.X / Math.Max(1f, _vpW);
            float dy = deltaPx.Y / Math.Max(1f, _vpH);
            float unit = Math.Max(1f, Math.Min(_vpW, _vpH));

            if (target == EditTarget.Toolbar)
            {
                if (resize)
                {
                    float signedDx = (_cfg.ToolbarSide == 1 ? -deltaPx.X : deltaPx.X);
                    float dScale = (signedDx + deltaPx.Y * 0.35f) / Math.Max(120f, unit * 0.28f);
                    _cfg.ToolbarSize = Math.Clamp(_cfg.ToolbarSize + dScale, 0.55f, 1.50f);
                }
                else
                {
                    // Drag horizontally past center flips Left <-> Right edge cleanly; drag vertically repositions Y!
                    if (curVp.X > _vpW * 0.62f) _cfg.ToolbarSide = 1;
                    else if (curVp.X < _vpW * 0.38f) _cfg.ToolbarSide = 0;
                    _cfg.ToolbarY = Math.Clamp(_cfg.ToolbarY + dy * 1.35f, 0.0f, 1.0f);
                }
                return;
            }

            if (target == EditTarget.CustomKey)
            {
                for (int i = 0; i < _cfg.CustomKeys.Count; i++)
                {
                    var b = _cfg.CustomKeys[i];
                    if (b.Id != customId) continue;
                    if (resize)
                    {
                        b.W = Math.Clamp(b.W + dx, 0.035f, Math.Min(0.35f, 0.99f - b.X));
                        b.H = Math.Clamp(b.H + dy, 0.050f, Math.Min(0.45f, 0.99f - b.Y));
                    }
                    else
                    {
                        b.X = Math.Clamp(b.X + dx, 0.005f, 0.995f - b.W);
                        b.Y = Math.Clamp(b.Y + dy, 0.005f, 0.995f - b.H);
                    }
                    break;
                }
                return;
            }

            if (target == EditTarget.TopBar)
            {
                _cfg.TopBarX = Math.Clamp(_cfg.TopBarX + dx, 0.01f, 0.85f);
                _cfg.TopBarY = Math.Clamp(_cfg.TopBarY + dy, 0.005f, 0.90f);
                return;
            }

            bool mirrorX = _cfg.LeftHandedMobile;
            float moveDx = mirrorX ? -dx : dx;

            if (IsInvisibleBarMode)
            {
                bool swap = _cfg.SwapRightButtons;
                EditTarget logical = target;
                if (swap && target == EditTarget.Tool) logical = EditTarget.Act;
                else if (swap && target == EditTarget.Act) logical = EditTarget.Tool;

                if (logical == EditTarget.Joy)
                {
                    if (resize)
                    {
                        float oldW = _cfg.InvJoyW;
                        float maxW = mirrorX ? Math.Min(0.75f, _cfg.InvJoyX + _cfg.InvJoyW) : Math.Min(0.75f, 0.99f - _cfg.InvJoyX);
                        _cfg.InvJoyW = Math.Clamp(oldW + dx, 0.14f, maxW);
                        if (mirrorX) _cfg.InvJoyX = Math.Clamp(_cfg.InvJoyX - (_cfg.InvJoyW - oldW), 0.0f, 0.99f - _cfg.InvJoyW);
                        _cfg.InvJoyH = Math.Clamp(_cfg.InvJoyH + dy, 0.20f, Math.Min(0.95f, 0.99f - _cfg.InvJoyY));
                    }
                    else
                    {
                        _cfg.InvJoyX = Math.Clamp(_cfg.InvJoyX + moveDx, 0.0f, 0.99f - _cfg.InvJoyW);
                        _cfg.InvJoyY = Math.Clamp(_cfg.InvJoyY + dy, 0.0f, 0.99f - _cfg.InvJoyH);
                    }
                }
                else if (logical == EditTarget.Tool)
                {
                    if (resize)
                    {
                        float oldW = _cfg.InvToolW;
                        float maxW = mirrorX ? Math.Min(0.45f, _cfg.InvToolX + _cfg.InvToolW) : Math.Min(0.45f, 0.99f - _cfg.InvToolX);
                        _cfg.InvToolW = Math.Clamp(oldW + dx, 0.06f, maxW);
                        if (mirrorX) _cfg.InvToolX = Math.Clamp(_cfg.InvToolX - (_cfg.InvToolW - oldW), 0.01f, 0.99f - _cfg.InvToolW);
                        _cfg.InvToolH = Math.Clamp(_cfg.InvToolH + dy, 0.14f, Math.Min(0.95f, 0.99f - _cfg.InvToolY));
                    }
                    else
                    {
                        _cfg.InvToolX = Math.Clamp(_cfg.InvToolX + moveDx, 0.01f, 0.99f - _cfg.InvToolW);
                        _cfg.InvToolY = Math.Clamp(_cfg.InvToolY + dy, 0.01f, 0.99f - _cfg.InvToolH);
                    }
                }
                else if (logical == EditTarget.Act)
                {
                    if (resize)
                    {
                        float oldW = _cfg.InvActW;
                        float maxW = mirrorX ? Math.Min(0.45f, _cfg.InvActX + _cfg.InvActW) : Math.Min(0.45f, 0.99f - _cfg.InvActX);
                        _cfg.InvActW = Math.Clamp(oldW + dx, 0.06f, maxW);
                        if (mirrorX) _cfg.InvActX = Math.Clamp(_cfg.InvActX - (_cfg.InvActW - oldW), 0.01f, 0.99f - _cfg.InvActW);
                        _cfg.InvActH = Math.Clamp(_cfg.InvActH + dy, 0.14f, Math.Min(0.95f, 0.99f - _cfg.InvActY));
                    }
                    else
                    {
                        _cfg.InvActX = Math.Clamp(_cfg.InvActX + moveDx, 0.01f, 0.99f - _cfg.InvActW);
                        _cfg.InvActY = Math.Clamp(_cfg.InvActY + dy, 0.01f, 0.99f - _cfg.InvActH);
                    }
                }
            }
            else
            {
                float dr = (deltaPx.X + deltaPx.Y) * 0.35f / unit;
                bool swap = _cfg.SwapRightButtons;
                EditTarget logical = target;
                if (swap && target == EditTarget.Tool) logical = EditTarget.Act;
                else if (swap && target == EditTarget.Act) logical = EditTarget.Tool;

                if (logical == EditTarget.Joy)
                {
                    if (resize) _cfg.VisJoyR = Math.Clamp(_cfg.VisJoyR + dr, 0.07f, 0.22f);
                    else { _cfg.VisJoyX = Math.Clamp(_cfg.VisJoyX + moveDx, 0.06f, 0.94f); _cfg.VisJoyY = Math.Clamp(_cfg.VisJoyY + dy, 0.10f, 0.92f); }
                }
                else if (logical == EditTarget.Tool)
                {
                    if (resize) _cfg.VisToolR = Math.Clamp(_cfg.VisToolR + dr, 0.045f, 0.16f);
                    else { _cfg.VisToolX = Math.Clamp(_cfg.VisToolX + moveDx, 0.06f, 0.94f); _cfg.VisToolY = Math.Clamp(_cfg.VisToolY + dy, 0.10f, 0.92f); }
                }
                else if (logical == EditTarget.Act)
                {
                    if (resize) _cfg.VisActR = Math.Clamp(_cfg.VisActR + dr, 0.045f, 0.16f);
                    else { _cfg.VisActX = Math.Clamp(_cfg.VisActX + moveDx, 0.06f, 0.94f); _cfg.VisActY = Math.Clamp(_cfg.VisActY + dy, 0.10f, 0.92f); }
                }
            }
        }

        private void ApplyToPad(object pad, Vector2 stick, bool btnX, bool btnA, bool btnMenu)
        {
            EnsureBridge(pad)?.ApplyInput(pad, stick, btnX, btnA, btnMenu);
        }

        private void NeutralizeMenuPad(object pad)
        {
            if (_menuPadNeutralized && !HasActiveExtraKeys())
                return;
            ApplyToPad(pad, Vector2.Zero, false, false, false);
            _menuPadNeutralized = !HasActiveExtraKeys();
        }

        /// <summary>
        /// Eliminates 8-way digital axis chatter around TouchVirtualPad's hard ±0.25f WASD/DPad cutoff
        /// while preserving 0ms stop latency and 0ms sharp-reversal response.
        /// </summary>
        private Vector2 StabilizeMoveStick(Vector2 rawStick)
        {
            if (rawStick.LengthSquared() < 0.001f)
            {
                _smoothedStick = Vector2.Zero;
                _hystAxisX = 0;
                _hystAxisY = 0;
                return Vector2.Zero;
            }

            // Instant snap on start or sharp >90-degree direction reversal (0ms turn latency)
            if (_smoothedStick.LengthSquared() < 0.001f || Vector2.Dot(rawStick, _smoothedStick) < 0f)
                _smoothedStick = rawStick;
            else
                _smoothedStick = _smoothedStick * 0.28f + rawStick * 0.72f;

            float x = _smoothedStick.X;
            float y = _smoothedStick.Y;
            float ax = Math.Abs(x);
            float ay = Math.Abs(y);

            // Schmitt-trigger hysteresis around 0.25f: enter at >=0.28f, hold until <=0.18f
            if (_hystAxisX == 0)
            {
                if (ax >= 0.28f) _hystAxisX = x > 0f ? 1 : -1;
            }
            else
            {
                if (ax <= 0.18f || Math.Sign(x) != _hystAxisX)
                    _hystAxisX = ax >= 0.28f ? (x > 0f ? 1 : -1) : 0;
            }

            if (_hystAxisY == 0)
            {
                if (ay >= 0.28f) _hystAxisY = y > 0f ? 1 : -1;
            }
            else
            {
                if (ay <= 0.18f || Math.Sign(y) != _hystAxisY)
                    _hystAxisY = ay >= 0.28f ? (y > 0f ? 1 : -1) : 0;
            }

            // Never stall when player is actively pushing slightly below 0.28 on both axes
            if (_hystAxisX == 0 && _hystAxisY == 0)
            {
                if (ax >= ay) _hystAxisX = x >= 0f ? 1 : -1;
                else _hystAxisY = y >= 0f ? 1 : -1;
            }

            float outX = _hystAxisX != 0
                ? _hystAxisX * Math.Max(ax, 0.32f)
                : Math.Clamp(x, -0.18f, 0.18f);
            float outY = _hystAxisY != 0
                ? _hystAxisY * Math.Max(ay, 0.32f)
                : Math.Clamp(y, -0.18f, 0.18f);

            return new Vector2(outX, outY);
        }

        private bool HitTestToolZone(Vector2 vp, Point vpPt)
        {
            if (IsInvisibleBarMode)
                return _invToolRect.Contains(vpPt);
            float rad = _visToolRect.Width * 0.56f;
            return Vector2.DistanceSquared(vp, _visToolRect.Center.ToVector2()) <= rad * rad;
        }

        private bool HitTestActZone(Vector2 vp, Point vpPt)
        {
            if (IsInvisibleBarMode)
                return _invActRect.Contains(vpPt);
            float rad = _visActRect.Width * 0.56f;
            return Vector2.DistanceSquared(vp, _visActRect.Center.ToVector2()) <= rad * rad;
        }

        private Vector2 ComputeStick(Vector2 curVp)
        {
            if (!IsInvisibleBarMode)
            {
                _joyOrigin = _visJoyCenter;
                _joyOriginNorm = new Vector2(_joyOrigin.X / Math.Max(1f, _vpW), _joyOrigin.Y / Math.Max(1f, _vpH));
            }
            else
            {
                _joyOrigin = new Vector2(_joyOriginNorm.X * _vpW, _joyOriginNorm.Y * _vpH);
            }
            Vector2 delta = curVp - _joyOrigin;
            float dist = delta.Length();
            float dz = Math.Clamp(_cfg.JoyDeadzone, 0.05f, 0.25f);
            if (dist < _activeJoyRadius * dz)
            {
                _joyKnob = curVp;
                _joyKnobNorm = new Vector2(_joyKnob.X / Math.Max(1f, _vpW), _joyKnob.Y / Math.Max(1f, _vpH));
                return Vector2.Zero;
            }
            Vector2 dir = delta / Math.Max(0.0001f, dist);
            if (dist > _activeJoyRadius)
            {
                _joyKnob = _joyOrigin + dir * _activeJoyRadius;
                _joyKnobNorm = new Vector2(_joyKnob.X / Math.Max(1f, _vpW), _joyKnob.Y / Math.Max(1f, _vpH));
                return dir;
            }
            _joyKnob = curVp;
            _joyKnobNorm = new Vector2(_joyKnob.X / Math.Max(1f, _vpW), _joyKnob.Y / Math.Max(1f, _vpH));
            // Remap [dz .. 1.0] -> [0.42 .. 1.0] so even a gentle 45-degree diagonal pull (0.42 * 0.707 = 0.297 > 0.25)
            // ALWAYS clears SDViOSTouchControls' 0.25 DPad threshold on both axes without standing still!
            float t = Math.Clamp((dist / _activeJoyRadius - dz) / Math.Max(0.01f, 1.0f - dz), 0f, 1f);
            float mag = 0.42f + t * 0.58f;
            return dir * mag;
        }

        private bool HandlePinchZoom(TouchCollection touches, double nowSec)
        {
            int idA = -1, idB = -1;
            Vector2 posA = Vector2.Zero, posB = Vector2.Zero;
            int activeCount = 0;

            for (int i = 0; i < touches.Count; i++)
            {
                var tl = touches[i];
                if (tl.State != TouchLocationState.Pressed && tl.State != TouchLocationState.Moved)
                    continue;
                if (tl.Id == _toolTouchId || tl.Id == _interactTouchId || IsTouchOwnedByCustomButton(tl.Id))
                    return false;

                Vector2 vp = MapRawToViewport(tl.Position);
                if (activeCount == 0) { idA = tl.Id; posA = vp; activeCount = 1; }
                else if (activeCount == 1) { idB = tl.Id; posB = vp; activeCount = 2; }
                else { activeCount++; }
            }

            if (activeCount != 2)
            {
                if (_pinchDirtySave && _pendingPinchZoom >= 0.70f)
                {
                    _pinchDirtySave = false;
                    if (Game1.options != null)
                        Game1.options.desiredBaseZoomLevel = _pendingPinchZoom;
                    _bridge?.SetTargetZoomLevel(_pendingPinchZoom);
                }
                _pinching = false;
                _pinchIdA = -1;
                _pinchIdB = -1;
                return false;
            }

            if (_joyTouchId >= 0 && _joyActivated && EffectiveMode != MobileControlMode.TapToMove)
            {
                Vector2 other = (idA == _joyTouchId) ? posB : posA;
                Point opt = new Point((int)other.X, (int)other.Y);
                if (HitTestToolZone(other, opt) || HitTestActZone(other, opt))
                    return false;
            }

            float dist = Vector2.Distance(posA, posB);
            if (!_pinching || _pinchIdA != idA || _pinchIdB != idB)
            {
                if (dist < 40f)
                    return false;
                _pinching = true;
                _pinchIdA = idA;
                _pinchIdB = idB;
                _pinchStartDist = dist;
                _pinchStartZoom = Game1.options != null ? Game1.options.desiredBaseZoomLevel : 1.0f;
                _pendingPinchZoom = _pinchStartZoom;
                _pinchDirtySave = false;
                _lastPinchApplySec = nowSec;
                return true;
            }

            if (_pinchStartDist > 20f && Game1.options != null)
            {
                float ratio = dist / _pinchStartDist;
                // Quantize to smooth 0.05 steps & throttle updates to ~16Hz to avoid 50x Window_ClientSizeChanged spam!
                float newZoom = Math.Clamp(_pinchStartZoom * ratio, 0.75f, 2.0f);
                newZoom = (float)Math.Round(newZoom * 20f) / 20f;
                _pendingPinchZoom = newZoom;
                if (Math.Abs(newZoom - Game1.options.desiredBaseZoomLevel) >= 0.045f && (nowSec - _lastPinchApplySec) >= 0.06)
                {
                    _lastPinchApplySec = nowSec;
                    Game1.options.desiredBaseZoomLevel = newZoom;
                    _pinchDirtySave = true;
                }
            }
            return true;
        }

        private bool TryHandleHudTap(Vector2 vp, out bool openedMenu, out int tappedToolbarSlot)
        {
            openedMenu = false;
            tappedToolbarSlot = -1;
            if (Game1.onScreenMenus == null || Game1.player == null)
                return false;

            Point uiPt = ViewportToUi(vp);

            foreach (IClickableMenu menu in Game1.onScreenMenus)
            {
                if (menu is Toolbar tb && tb.buttons != null)
                {
                    for (int i = 0; i < tb.buttons.Count && i < 12; i++)
                    {
                        ClickableComponent btn = tb.buttons[i];
                        if (btn != null && btn.bounds.Contains(uiPt))
                        {
                            tappedToolbarSlot = i;
                            return true;
                        }
                    }
                }
                else if (menu is DayTimeMoneyBox dt)
                {
                    if (dt.questButton != null && dt.questButton.bounds.Contains(uiPt))
                    {
                        try { dt.receiveLeftClick(uiPt.X, uiPt.Y, true); } catch { }
                        openedMenu = (Game1.activeClickableMenu != null);
                        return true;
                    }
                }
            }

            return false;
        }

        private bool TryGetToolbarViewportBounds(out Rectangle tbVpRect)
        {
            tbVpRect = Rectangle.Empty;
            if (Game1.onScreenMenus == null) return false;
            foreach (IClickableMenu menu in Game1.onScreenMenus)
            {
                if (menu is Toolbar tb && tb.buttons != null && tb.buttons.Count >= 12)
                {
                    Rectangle first = tb.buttons[0].bounds;
                    Rectangle last = tb.buttons[11].bounds;
                    if (first.Width <= 0 || last.Width <= 0) return false;
                    Vector2 tl = UiToViewport(new Point(first.X, first.Y));
                    Vector2 br = UiToViewport(new Point(last.Right, last.Bottom));
                    tbVpRect = new Rectangle((int)tl.X, (int)tl.Y, Math.Max(1, (int)(br.X - tl.X)), Math.Max(1, (int)(br.Y - tl.Y)));
                    return true;
                }
            }
            return false;
        }

        private void HandleWorldTap(Vector2 vp)
        {
            Farmer who = Game1.player;
            GameLocation loc = Game1.currentLocation;
            if (who == null || loc == null)
                return;

            // Instant Hook / Reel when fishing in Tap-to-Move or Hybrid mode (tap anywhere on screen!)
            if (who.CurrentTool is FishingRod fr && (fr.isFishing || fr.isNibbling))
            {
                ClearPath();
                _actionPulseXFrames = 3;
                return;
            }

            Vector2 worldPos = ViewportToWorld(vp);
            Point tappedTile = new Point((int)Math.Floor(worldPos.X / 64f), (int)Math.Floor(worldPos.Y / 64f));
            Point playerTile = who.TilePoint;
            int cheb = Math.Max(Math.Abs(playerTile.X - tappedTile.X), Math.Abs(playerTile.Y - tappedTile.Y));

            TileIntent intent = AutoToolAndCombat.InspectTile(loc, tappedTile, who, _cfg.AutoTool);

            // Tap directly on farmer (cheb == 0):
            // - If currently auto-chopping/mining or A* walking -> cleanly stop (never accidentally eat food!)
            // - If riding horse -> dismount cleanly
            // - If an actionable target sits right under our feet (crop/soil/forage/monster/ladder/bed) -> handle that first!
            // - Otherwise if holding usable item (Food, Coffee, Bomb, Staircase, Totem) -> eat/use!
            if (cheb == 0)
            {
                if (_repeatActive || (_path != null && _path.Count > 0))
                {
                    ClearPath();
                    return;
                }
                if (who.isRidingHorse())
                {
                    ClearPath();
                    _actionPulseAFrames = 1;
                    return;
                }
                if ((intent.Kind == TileActionKind.None || !intent.AllowSameTile) && IsSelfUsableObject(who.ActiveObject))
                {
                    ClearPath();
                    _actionPulseAFrames = 1;
                    return;
                }
            }

            // Check interior/exterior loc.doors (e.g. villager bedroom doors) if not already an Action tile
            if (intent.Kind == TileActionKind.None)
            {
                try
                {
                    if (loc.doors != null && loc.doors.ContainsKey(tappedTile))
                    {
                        intent.Kind = TileActionKind.Interact;
                        intent.StopAdjacent = true;
                        intent.PreferCardinal = true;
                    }
                }
                catch { }
            }

            Point actionTile = intent.HasResolvedTile ? intent.ResolvedTile : tappedTile;
            int actionCheb = Math.Max(Math.Abs(playerTile.X - actionTile.X), Math.Abs(playerTile.Y - actionTile.Y));
            int actionManh = Math.Abs(playerTile.X - actionTile.X) + Math.Abs(playerTile.Y - actionTile.Y);

            // Detect Exit / Map-Edge Warps (FarmHouse exit rug, Shops exit, Coops/Barns exit, Mines, Map Exits!)
            // Building entry doors (Farmhouse, Coop, Barn, Shed, Town houses) are handled via Action/Building.doAction above!
            bool tappedWarp = false;
            Point warpGoal = tappedTile;
            if (intent.Kind == TileActionKind.None && TryFindNearbyWarp(loc, tappedTile, out Point foundWarp))
            {
                tappedWarp = true;
                warpGoal = foundWarp;
                intent.StopAdjacent = false;
            }

            bool requireCardNow = intent.PreferCardinal && HasWalkableCardinalNeighbor(loc, actionTile, playerTile, who);
            bool closeEnoughNow = (intent.Kind == TileActionKind.UseTool)
                ? (intent.AllowSameTile ? (actionCheb <= 1) : (actionCheb == 1))
                : (requireCardNow ? (actionManh == 1 || (intent.AllowSameTile && actionCheb == 0)) : (actionCheb <= 1));
            if (!tappedWarp && intent.Kind != TileActionKind.None && closeEnoughNow)
            {
                ClearPath();
                TriggerTileIntent(who, actionTile, intent);
                return;
            }

            // Tap empty adjacent tile while holding a placeable object (Chest, Keg, Fence, Path, Sprinkler, Furniture, Bomb, Seeds, etc.)!
            if (!tappedWarp && intent.Kind == TileActionKind.None && cheb == 1 && who.ActiveObject != null &&
                (who.ActiveObject.isPlaceable() || who.ActiveObject.bigCraftable.Value))
            {
                ClearPath();
                FaceTargetTile(who, tappedTile);
                bool placed = false;
                try
                {
                    placed = Utility.tryToPlaceItem(loc, who.ActiveObject, tappedTile.X * 64 + 32, tappedTile.Y * 64 + 32);
                }
                catch { }
                if (!placed)
                    _actionPulseAFrames = 1;
                return;
            }

            Point pathGoal = tappedWarp ? FindWarpApproachTile(loc, warpGoal, playerTile, who) : actionTile;
            List<Point> path = PathFinder.FindPath(loc, playerTile, pathGoal, who, intent.StopAdjacent, intent.PreferCardinal);
            if (path == null)
            {
                // Any new world tap immediately cancels an active auto-chop loop
                _repeatActive = false;
                // Even if A* couldn't path directly to an out-of-bounds door edge, if player is right beside the warp, push through!
                if (tappedWarp && Math.Max(Math.Abs(playerTile.X - warpGoal.X), Math.Abs(playerTile.Y - warpGoal.Y)) <= 2)
                {
                    ClearPath();
                    _pendingWarpTile = warpGoal;
                    _warpPushFrames = 28;
                    _warpPushStartHudCount = Game1.hudMessages?.Count ?? 0;
                }
                return;
            }

            if (path.Count == 0)
            {
                if (tappedWarp)
                {
                    ClearPath();
                    _pendingWarpTile = warpGoal;
                    _warpPushFrames = 28;
                    _warpPushStartHudCount = Game1.hudMessages?.Count ?? 0;
                    return;
                }
                if (intent.Kind != TileActionKind.None)
                {
                    ClearPath();
                    TriggerTileIntent(who, actionTile, intent);
                    return;
                }
            }

            ClearPath();
            _path = path;
            _pathIdx = 0;
            _targetTile = tappedWarp ? warpGoal : actionTile;
            _hasTargetTile = true;
            _pendingIntent = intent;
            _hasPendingWarp = tappedWarp;
            _pendingWarpTile = warpGoal;
            _warpPushFrames = 0;
            _lastPlayerPos = who.Position;
            _stuckFrames = 0;
        }

        private static bool IsWaterInFishingCastReach(GameLocation loc, Point playerTile, Point tappedTile)
        {
            if (loc == null) return false;
            try
            {
                // Must tap directly on water — OR on an impassable shoreline/cliff edge 1 tile beside water.
                // NEVER hijack taps on walkable piers, wooden docks, bridges, or beach floor!
                bool tapIsWater = loc.isWaterTile(tappedTile.X, tappedTile.Y);
                if (!tapIsWater)
                {
                    if (PathFinder.IsTileWalkable(loc, tappedTile.X, tappedTile.Y, Game1.player))
                        return false;

                    tapIsWater = loc.isWaterTile(tappedTile.X + 1, tappedTile.Y) ||
                                 loc.isWaterTile(tappedTile.X - 1, tappedTile.Y) ||
                                 loc.isWaterTile(tappedTile.X, tappedTile.Y + 1) ||
                                 loc.isWaterTile(tappedTile.X, tappedTile.Y - 1);
                    if (!tapIsWater) return false;
                }

                int cheb = Math.Max(Math.Abs(playerTile.X - tappedTile.X), Math.Abs(playerTile.Y - tappedTile.Y));
                if (cheb <= 2)
                    return true;
                if (cheb > 8)
                    return false;

                // Player tapped water 3..8 tiles away: start immediate charging ONLY if player is already standing
                // at the shore/dock/bridge (i.e. water exists within 1..3 tiles in the tapped direction).
                int dx = Math.Sign(tappedTile.X - playerTile.X);
                int dy = Math.Sign(tappedTile.Y - playerTile.Y);
                for (int step = 1; step <= 3; step++)
                {
                    if (loc.isWaterTile(playerTile.X + dx * step, playerTile.Y + dy * step))
                        return true;
                    if (dx != 0 && dy != 0)
                    {
                        if (loc.isWaterTile(playerTile.X + dx * step, playerTile.Y) ||
                            loc.isWaterTile(playerTile.X, playerTile.Y + dy * step))
                            return true;
                    }
                }
            }
            catch { }
            return false;
        }

        // For unwalkable/out-of-bounds door warps (e.g. FarmHouse exit (3,12) or Building humanDoor),
        // pick the walkable CARDINAL tile directly in front of the door (e.g. rug (3,11)) so A* walks
        // squarely onto the rug instead of stopping diagonally against the wall!
        private static bool HasWalkableCardinalNeighbor(GameLocation loc, Point goal, Point playerTile, Farmer who)
        {
            if (loc == null) return false;
            int[] cdx = { 0, 1, 0, -1 };
            int[] cdy = { -1, 0, 1, 0 };
            for (int i = 0; i < 4; i++)
            {
                int cx = goal.X + cdx[i];
                int cy = goal.Y + cdy[i];
                if ((cx == playerTile.X && cy == playerTile.Y) || PathFinder.IsTileWalkable(loc, cx, cy, who))
                    return true;
            }
            return false;
        }

        private static Point FindWarpApproachTile(GameLocation loc, Point warpGoal, Point playerTile, Farmer who)
        {
            if (loc == null || PathFinder.IsTileWalkable(loc, warpGoal.X, warpGoal.Y, who))
                return warpGoal;

            Point[] cardinals =
            {
                new Point(warpGoal.X, warpGoal.Y - 1),
                new Point(warpGoal.X, warpGoal.Y + 1),
                new Point(warpGoal.X - 1, warpGoal.Y),
                new Point(warpGoal.X + 1, warpGoal.Y)
            };

            Point best = warpGoal;
            int bestDistSq = int.MaxValue;
            for (int i = 0; i < cardinals.Length; i++)
            {
                Point c = cardinals[i];
                if (!PathFinder.IsTileWalkable(loc, c.X, c.Y, who))
                    continue;
                int dx = c.X - playerTile.X;
                int dy = c.Y - playerTile.Y;
                int dSq = dx * dx + dy * dy;
                if (dSq < bestDistSq)
                {
                    bestDistSq = dSq;
                    best = c;
                }
            }
            return best;
        }

        private static bool TryFindNearbyWarp(GameLocation loc, Point tappedTile, out Point warpTile)
        {
            warpTile = tappedTile;
            if (loc == null)
                return false;

            try
            {
                int mapW = loc.Map?.Layers?[0]?.LayerWidth ?? 0;
                int mapH = loc.Map?.Layers?[0]?.LayerHeight ?? 0;
                bool tapOutOrBlocked = tappedTile.X < 0 || tappedTile.Y < 0 || tappedTile.X >= mapW || tappedTile.Y >= mapH ||
                                       !PathFinder.IsTileWalkable(loc, tappedTile.X, tappedTile.Y, Game1.player);

                int bestDistSq = int.MaxValue;
                bool found = false;

                if (loc.warps != null)
                {
                    for (int i = 0; i < loc.warps.Count; i++)
                    {
                        Warp w = loc.warps[i];
                        if (w == null || w.npcOnly.Value)
                            continue;
                        int dx = Math.Abs(w.X - tappedTile.X);
                        int dy = Math.Abs(w.Y - tappedTile.Y);
                        int cheb = Math.Max(dx, dy);

                        bool match;
                        if (cheb == 0)
                        {
                            match = true;
                        }
                        else if (tapOutOrBlocked)
                        {
                            match = (cheb <= 2);
                        }
                        else
                        {
                            // Walkable tap (e.g. FarmHouse exit rug (3,11)): ONLY match a cardinally adjacent
                            // unwalkable/out-of-bounds warp (like (3,12)) — never accidentally trigger open road edges!
                            match = (dx + dy == 1) && !PathFinder.IsTileWalkable(loc, w.X, w.Y, Game1.player);
                        }

                        if (!match) continue;
                        int dSq = dx * dx + dy * dy;
                        if (dSq < bestDistSq)
                        {
                            bestDistSq = dSq;
                            warpTile = new Point(w.X, w.Y);
                            found = true;
                        }
                    }
                }

                return found;
            }
            catch
            {
                return false;
            }
        }

        private static bool IsSelfUsableObject(StardewValley.Object obj)
        {
            if (obj == null) return false;
            if (obj.Edibility > -300) return true; // Any edible food or drink (Coffee, Salad, Cheese, Elixir, etc.)
            string name = obj.Name ?? "";
            if (name.IndexOf("Totem", StringComparison.OrdinalIgnoreCase) >= 0 ||
                name.IndexOf("Bomb", StringComparison.OrdinalIgnoreCase) >= 0 ||
                name.IndexOf("Staircase", StringComparison.OrdinalIgnoreCase) >= 0 ||
                name.IndexOf("Tent", StringComparison.OrdinalIgnoreCase) >= 0 ||
                name.IndexOf("Book", StringComparison.OrdinalIgnoreCase) >= 0 ||
                name.IndexOf("Ticket", StringComparison.OrdinalIgnoreCase) >= 0)
                return true;
            return obj.isPlaceable();
        }

        private Vector2 StepPathFollower()
        {
            Farmer who = Game1.player;
            if (who == null || _path == null || _pathIdx >= _path.Count)
            {
                CompletePathArrival();
                return Vector2.Zero;
            }

            if (Vector2.DistanceSquared(who.Position, _lastPlayerPos) < 4f)
            {
                // 36 ticks (> Auto-Unstick's 18 ticks!) so Auto-Unstick rescues a frozen farmer BEFORE A* cancels!
                if (++_stuckFrames > 36)
                {
                    bool hadWarp = _hasPendingWarp;
                    Point warpT = _pendingWarpTile;
                    ClearPath();
                    if (hadWarp && Math.Max(Math.Abs(who.TilePoint.X - warpT.X), Math.Abs(who.TilePoint.Y - warpT.Y)) <= 2)
                    {
                        _pendingWarpTile = warpT;
                        _warpPushFrames = 26;
                        _warpPushStartHudCount = Game1.hudMessages?.Count ?? 0;
                    }
                    return Vector2.Zero;
                }
            }
            else
            {
                _lastPlayerPos = who.Position;
                _stuckFrames = 0;
            }

            Point wp = _path[_pathIdx];
            Vector2 wpCenter = new Vector2(wp.X * 64f + 32f, wp.Y * 64f + 32f);
            Vector2 playerCenter = who.GetBoundingBox().Center.ToVector2();
            Vector2 diff = wpCenter - playerCenter;

            bool isFinal = (_pathIdx == _path.Count - 1);
            bool isFinalCardinalStop = isFinal && _pendingIntent.PreferCardinal && _pendingIntent.Kind != TileActionKind.None;
            float arrivalRadius = isFinal ? (isFinalCardinalStop ? 11f : 14f) : 24f;

            // Advance waypoint cleanly when within arrival radius OR already passed intermediate waypoint toward next tile
            while (_pathIdx < _path.Count)
            {
                bool curFinal = (_pathIdx == _path.Count - 1);
                bool curFinalCard = curFinal && _pendingIntent.PreferCardinal && _pendingIntent.Kind != TileActionKind.None;
                float curRad = curFinal ? (curFinalCard ? 11f : 14f) : 24f;
                bool passedIntermediate = false;
                if (!curFinal && diff.LengthSquared() <= 42f * 42f)
                {
                    Point nextWp = _path[_pathIdx + 1];
                    Vector2 seg = new Vector2((nextWp.X - wp.X) * 64f, (nextWp.Y - wp.Y) * 64f);
                    if (Vector2.Dot(diff, seg) <= 0f)
                        passedIntermediate = true;
                }

                if (diff.Length() <= curRad || passedIntermediate ||
                    (curFinalCard && _stuckFrames >= 12 &&
                     Math.Abs(who.TilePoint.X - _targetTile.X) + Math.Abs(who.TilePoint.Y - _targetTile.Y) == 1))
                {
                    _pathIdx++;
                    if (_pathIdx >= _path.Count)
                    {
                        CompletePathArrival();
                        return Vector2.Zero;
                    }
                    wp = _path[_pathIdx];
                    wpCenter = new Vector2(wp.X * 64f + 32f, wp.Y * 64f + 32f);
                    diff = wpCenter - playerCenter;
                }
                else
                {
                    break;
                }
            }

            // Lookahead Path Smoothing: aim along collinear straight runs (up to 3 tiles ahead)
            // and gently round open L-corners so movement glides smoothly instead of snapping tile-by-tile!
            Vector2 aimTarget = wpCenter;
            if (_pathIdx + 1 < _path.Count)
            {
                Point next1 = _path[_pathIdx + 1];
                int sdx = next1.X - wp.X;
                int sdy = next1.Y - wp.Y;
                int lookIdx = _pathIdx;
                int maxLook = Math.Min(_path.Count - 1, _pathIdx + 3);
                while (lookIdx < maxLook)
                {
                    Point a = _path[lookIdx];
                    Point b = _path[lookIdx + 1];
                    if (b.X - a.X == sdx && b.Y - a.Y == sdy)
                        lookIdx++;
                    else
                        break;
                }
                if (lookIdx > _pathIdx)
                {
                    Point farWp = _path[lookIdx];
                    aimTarget = new Vector2(farWp.X * 64f + 32f, farWp.Y * 64f + 32f);
                }
                else if (diff.LengthSquared() <= 40f * 40f && Game1.currentLocation != null)
                {
                    // Mild corner-rounding blend ONLY if both orthogonal bridge tiles between player & next1 are walkable (never clips corners!)
                    Point pt = who.TilePoint;
                    if (Math.Abs(next1.X - pt.X) <= 1 && Math.Abs(next1.Y - pt.Y) <= 1 &&
                        PathFinder.IsTileWalkable(Game1.currentLocation, next1.X, pt.Y, who) &&
                        PathFinder.IsTileWalkable(Game1.currentLocation, pt.X, next1.Y, who))
                    {
                        Vector2 nextCenter = new Vector2(next1.X * 64f + 32f, next1.Y * 64f + 32f);
                        aimTarget = Vector2.Lerp(wpCenter, nextCenter, 0.35f);
                    }
                }
            }

            Vector2 steer = aimTarget - playerCenter;
            if (steer.LengthSquared() < 1f)
                return Vector2.Zero;

            steer.Normalize();
            return steer;
        }

        private void CompletePathArrival()
        {
            Farmer who = Game1.player;
            Point target = _targetTile;
            TileIntent intent = _pendingIntent;
            bool hadWarp = _hasPendingWarp;
            Point warpTile = _pendingWarpTile;
            ClearPath();

            if (who == null)
                return;

            if (hadWarp)
            {
                // Walk straight into the Warp tile so GameLocation.isCollidingWithWarp exits doors reliably!
                _pendingWarpTile = warpTile;
                _warpPushFrames = 28;
                _warpPushStartHudCount = Game1.hudMessages?.Count ?? 0;
                return;
            }

            if (intent.Kind != TileActionKind.None)
            {
                int dx = Math.Abs(who.TilePoint.X - target.X);
                int dy = Math.Abs(who.TilePoint.Y - target.Y);
                int cheb = Math.Max(dx, dy);
                int manh = dx + dy;
                bool requireCard = intent.PreferCardinal && HasWalkableCardinalNeighbor(Game1.currentLocation, target, who.TilePoint, who);
                bool reachedAction = (intent.Kind == TileActionKind.UseTool)
                    ? (intent.AllowSameTile ? (cheb <= 1) : (cheb == 1))
                    : (requireCard ? (manh == 1 || (intent.AllowSameTile && cheb == 0)) : (cheb <= 1));
                if (reachedAction)
                    TriggerTileIntent(who, target, intent);
            }
            else if (intent.StopAdjacent)
            {
                // e.g., walked to water shoreline while holding FishingRod -> face the water ready to hold-charge!
                FaceTargetTile(who, target);
            }
        }

        private static int CountErrorHudMessages()
        {
            var list = Game1.hudMessages;
            if (list == null) return 0;
            int count = 0;
            for (int i = 0; i < list.Count; i++)
            {
                HUDMessage m = list[i];
                if (m != null && (m.whatType == HUDMessage.error_type || m.noIcon))
                    count++;
            }
            return count;
        }

        private static bool FireTargetedToolSwing(Farmer who, Point tile)
        {
            if (who == null || who.CurrentTool == null ||
                who.CurrentTool is FishingRod || who.CurrentTool is Slingshot ||
                who.UsingTool || !who.CanMove || who.isEating || who.isRidingHorse() || who.IsSitting() ||
                Game1.activeClickableMenu != null || Game1.dialogueUp || !CanUseToolInCurrentState() || Game1.fadeToBlack)
                return false;

            try
            {
                who.Halt();
                FaceTargetTile(who, tile);
                who.toolPower.Value = 0;
                who.toolHold.Value = 0;
                who.lastClick = new Vector2(tile.X * 64f + 32f, tile.Y * 64f + 32f);
                Game1.lastCursorMotionWasMouse = false;
                who.BeginUsingTool();
                // Upgraded Hoe / WateringCan pause in windup until EndUsingTool(); finish single-tile swing cleanly!
                if (who.UsingTool && (who.CurrentTool is Hoe || who.CurrentTool is WateringCan) && who.CurrentTool.UpgradeLevel > 0)
                    who.EndUsingTool();
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static void FaceTargetTile(Farmer who, Point tile)
        {
            if (who == null) return;
            int dtx = tile.X - who.TilePoint.X;
            int dty = tile.Y - who.TilePoint.Y;
            if (dtx == 0 && dty == 0)
                return;
            // Exact cardinal direction when standing orthogonally adjacent so pixel edge offsets never aim wrong!
            if (Math.Abs(dtx) + Math.Abs(dty) == 1)
            {
                if (dty < 0) who.FacingDirection = 0;
                else if (dtx > 0) who.FacingDirection = 1;
                else if (dty > 0) who.FacingDirection = 2;
                else if (dtx < 0) who.FacingDirection = 3;
                return;
            }
            who.faceGeneralDirection(new Vector2(tile.X * 64f + 32f, tile.Y * 64f + 32f));
        }

        private void TriggerTileIntent(Farmer who, Point tile, TileIntent intent)
        {
            if (intent.Kind == TileActionKind.UseTool)
            {
                if (who.isRidingHorse() || !who.CanMove)
                    return;
                int cheb = Math.Max(Math.Abs(who.TilePoint.X - tile.X), Math.Abs(who.TilePoint.Y - tile.Y));
                if (cheb > 1)
                    return;
            }

            if (intent.PreferredToolSlot >= 0 && intent.PreferredToolSlot < who.Items.Count)
            {
                if (_cfg.RestoreToolAfterAuto && who.CurrentToolIndex != intent.PreferredToolSlot && _autoToolPrevSlot < 0)
                {
                    _autoToolPrevSlot = who.CurrentToolIndex;
                    _autoToolRestoreTimer = 36;
                }
                who.CurrentToolIndex = intent.PreferredToolSlot;
            }

            FaceTargetTile(who, tile);

            if (intent.Kind == TileActionKind.UseTool)
            {
                if (!FireTargetedToolSwing(who, tile))
                    _actionPulseXFrames = 2;
                if (_cfg.AutoRepeat && intent.Repeatable)
                {
                    _repeatActive = true;
                    _repeatTile = tile;
                    _repeatCooldown = 5;
                    _repeatSwings = 1;
                    _repeatStartHudCount = CountErrorHudMessages();
                    _repeatLastHealth = AutoToolAndCombat.GetTargetHealth(Game1.currentLocation, tile);
                    _repeatNoProgressSwings = 0;
                    _repeatObservedSwing = false;
                }
            }
            else if (intent.Kind == TileActionKind.Interact)
            {
                // Directly invoke loc.checkAction ONCE with SynthesizingTapAction=true (so Game1.didPlayerJustRightClick
                // returns true identically to PC right-click!). This fixes ShippingBin, FishPond, Furniture (TV/Bed/Dresser),
                // JunimoHut, MineShaft ladders/shafts, Mailboxes, Building doors, Shops, and modded buildings cleanly in 1 tap!
                bool handled = false;
                GameLocation loc = Game1.currentLocation;
                if (IsPlayableEventActive() &&
                    Game1.activeClickableMenu == null &&
                    !Game1.dialogueUp && !Game1.fadeToBlack)
                {
                    try
                    {
                        Game1.CurrentEvent?.receiveActionPress(tile.X, tile.Y);
                        handled = Game1.dialogueUp || Game1.activeClickableMenu != null;
                    }
                    catch { }
                }
                if (!handled && loc != null &&
                    Game1.activeClickableMenu == null &&
                    !Game1.dialogueUp && !Game1.eventUp && !Game1.fadeToBlack)
                {
                    // Prioritize direct petting of unpetted FarmAnimal / Pet at target tile (works even on eggs/truffles/hay!)
                    handled = TryDirectPetAnimalOrPet(loc, who, new Vector2(tile.X * 64f + 32f, tile.Y * 64f + 32f), onlyIfNoBlockingObject: false);
                }
                if (!handled && loc != null &&
                    Game1.activeClickableMenu == null &&
                    !Game1.dialogueUp && !IsBlockingCutsceneActive() && !Game1.fadeToBlack)
                {
                    ModEntry.SynthesizingTapAction = true;
                    MouseState savedOldMouse = Game1.oldMouseState;
                    MouseState savedCurMouse = default;
                    bool patchedMouseState = false;
                    try
                    {
                        // Zero-Harmony native right-click synthesis: ensures Game1.didPlayerJustRightClick() returns true
                        // even on 0% JIT where 0Harmony.dll is a no-op AND Game1.input is SMAPI's SInputState!
                        // Fixes diagonal/direct ShippingBin, FishPond, Furniture (without ripping table decor!), Chests, Well, etc.
                        if (Game1.input != null)
                        {
                            if (!_sInputMouseStateResolved)
                            {
                                _sInputMouseStateResolved = true;
                                _sInputMouseStateField = Game1.input.GetType().GetField("<MouseState>k__BackingField", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
                            }
                            if (InputCurrentMouseStateField != null || _sInputMouseStateField != null)
                            {
                                savedCurMouse = Game1.input.GetMouseState();
                                Game1.oldMouseState = new MouseState(
                                    savedOldMouse.X, savedOldMouse.Y, savedOldMouse.ScrollWheelValue,
                                    savedOldMouse.LeftButton, savedOldMouse.MiddleButton, ButtonState.Released,
                                    savedOldMouse.XButton1, savedOldMouse.XButton2);
                                var synthRight = new MouseState(
                                    savedCurMouse.X, savedCurMouse.Y, savedCurMouse.ScrollWheelValue,
                                    savedCurMouse.LeftButton, savedCurMouse.MiddleButton, ButtonState.Pressed,
                                    savedCurMouse.XButton1, savedCurMouse.XButton2);
                                InputCurrentMouseStateField?.SetValue(Game1.input, synthRight);
                                _sInputMouseStateField?.SetValue(Game1.input, synthRight);
                                patchedMouseState = true;
                            }
                        }
                        handled = Game1.tryToCheckAt(new Vector2(tile.X, tile.Y), who);
                    }
                    catch { }
                    finally
                    {
                        if (patchedMouseState && Game1.input != null)
                        {
                            try
                            {
                                Game1.oldMouseState = savedOldMouse;
                                InputCurrentMouseStateField?.SetValue(Game1.input, savedCurMouse);
                                _sInputMouseStateField?.SetValue(Game1.input, savedCurMouse);
                            }
                            catch { }
                        }
                        ModEntry.SynthesizingTapAction = false;
                    }

                    // Seeds / Fertilizer on HoeDirt, Crab Pots on water, and placeable objects use Utility.tryToPlaceItem!
                    if (!handled && who.ActiveObject != null &&
                        Game1.activeClickableMenu == null && !Game1.dialogueUp && !Game1.eventUp && !Game1.fadeToBlack)
                    {
                        try
                        {
                            handled = Utility.tryToPlaceItem(loc, who.ActiveObject, tile.X * 64 + 32, tile.Y * 64 + 32);
                        }
                        catch { }
                    }
                }

                // Never pulse A while mounted on a Horse (prevents accidental dismount when tapping chests/shipping bins/ground)!
                if (!handled && !who.isRidingHorse() && Game1.activeClickableMenu == null && !Game1.dialogueUp && !IsBlockingCutsceneActive() && !Game1.fadeToBlack)
                    _actionPulseAFrames = 2;
            }
        }

        // =========================================================================
        // STARDEW-PIXEL MULTI-SLOT SAVE MENU (Replaces legacy MODS drawer!)
        // =========================================================================
        private const int SaveVisibleRows = 4;

        private void OpenSaveMenu()
        {
            _gamepadHideHud = false;
            ResetGameplayState();
            _saveMenuOpen = true;
            _saveSwipeTouchId = -1;
            _saveSwipeMoved = false;
            var slots = _saveSlots.GetSlotsForCurrentSave(forceRefresh: true);
            _saveSelectedIdx = slots.Count > 0 ? 0 : -1;
            _saveScrollIdx = 0;
            ModEntry.ExternalInput?.SetManagedSuppressed(true);
            ModEntry.ExternalInput?.FlushFarmerMovementAndState(restoreAutoRun: false);
            try { Game1.playSound("bigSelect"); } catch { }
        }

        private void CloseSaveMenu(bool flushExternal = true)
        {
            bool wasOpen = _saveMenuOpen;
            _saveMenuOpen = false;
            _saveSwipeTouchId = -1;
            _saveSwipeMoved = false;
            if (wasOpen && flushExternal)
            {
                ModEntry.ExternalInput?.SetManagedSuppressed(IsUiOverlayBlockingExternalInput(_lastPadObj));
                ModEntry.ExternalInput?.FlushFarmerMovementAndState(restoreAutoRun: true);
            }
        }

        private Rectangle GetSaveSlotRowRect(int visibleRowIdx)
        {
            int gap = Math.Max(6, _saveListRect.Height / 40);
            int rowH = Math.Max(36, (_saveListRect.Height - gap * (SaveVisibleRows + 1)) / SaveVisibleRows);
            int y = _saveListRect.Y + gap + visibleRowIdx * (rowH + gap);
            return new Rectangle(_saveListRect.X + gap, y, _saveListRect.Width - gap * 2, rowH);
        }

        private void UpdateSaveMenuTouches(object pad, PadBridge br, TouchCollection touches, double nowSec)
        {
            var slots = _saveSlots.GetSlotsForCurrentSave();
            int maxScroll = Math.Max(0, slots.Count - SaveVisibleRows);
            _saveScrollIdx = Math.Clamp(_saveScrollIdx, 0, maxScroll);
            if (_saveSelectedIdx >= slots.Count) _saveSelectedIdx = slots.Count - 1;

            if (touches.Count == 0)
            {
                _saveSwipeTouchId = -1;
                _saveSwipeMoved = false;
                return;
            }

            for (int i = 0; i < touches.Count; i++)
            {
                TouchLocation tl = touches[i];
                Vector2 vp = MapRawToViewport(tl.Position);
                Point pt = new Point((int)vp.X, (int)vp.Y);

                if (tl.State == TouchLocationState.Pressed)
                {
                    if (_saveCloseRect.Contains(pt) || !_savePanelRect.Contains(pt))
                    {
                        CloseSaveMenu(flushExternal: true);
                        try { Game1.playSound("bigDeSelect"); } catch { }
                        return;
                    }
                    if (_saveNewBtnRect.Contains(pt))
                    {
                        _saveSlots.BeginPendingSnapshot(br);
                        bool ok = br != null && br.TryQuickSave(out string msg);
                        if (!ok)
                        {
                            _saveSlots.CancelPendingSnapshot();
                            ShowSaveToast(br != null ? "KHONG THE LUU LUC NAY" : "QUICKSAVE LOI", nowSec);
                            try { Game1.playSound("cancel"); } catch { }
                        }
                        else
                        {
                            ShowSaveToast("DANG LUU BAN MOI...", nowSec);
                            CloseSaveMenu(flushExternal: true);
                            try { Game1.playSound("coin"); } catch { }
                        }
                        return;
                    }
                    if (_saveLoadBtnRect.Contains(pt))
                    {
                        if (_saveSelectedIdx >= 0 && _saveSelectedIdx < slots.Count)
                        {
                            bool ok = _saveSlots.RestoreAndLoadSlot(slots[_saveSelectedIdx], br, out string msg);
                            ShowSaveToast(msg, nowSec);
                            if (ok)
                            {
                                CloseSaveMenu(flushExternal: true);
                                try { Game1.playSound("bigSelect"); } catch { }
                            }
                            else
                            {
                                try { Game1.playSound("cancel"); } catch { }
                            }
                        }
                        else if (br != null && br.HasQuickSave())
                        {
                            bool ok = br.TryQuickLoad(out string msg);
                            ShowSaveToast(msg, nowSec);
                            if (ok) CloseSaveMenu(flushExternal: true);
                        }
                        else
                        {
                            ShowSaveToast("CHON 1 BAN LUU DE TAI", nowSec);
                            try { Game1.playSound("cancel"); } catch { }
                        }
                        return;
                    }
                    if (_saveDelBtnRect.Contains(pt))
                    {
                        if (_saveSelectedIdx >= 0 && _saveSelectedIdx < slots.Count)
                        {
                            if (_saveSlots.DeleteSlot(slots[_saveSelectedIdx]))
                            {
                                var updated = _saveSlots.GetSlotsForCurrentSave();
                                _saveSelectedIdx = updated.Count > 0 ? Math.Min(_saveSelectedIdx, updated.Count - 1) : -1;
                                _saveScrollIdx = Math.Clamp(_saveScrollIdx, 0, Math.Max(0, updated.Count - SaveVisibleRows));
                                ShowSaveToast("DA XOA BAN LUU", nowSec);
                                try { Game1.playSound("trashcan"); } catch { }
                            }
                        }
                        return;
                    }
                    if (_saveUpBtnRect.Contains(pt))
                    {
                        if (_saveScrollIdx > 0) { _saveScrollIdx--; try { Game1.playSound("shwip"); } catch { } }
                        return;
                    }
                    if (_saveDnBtnRect.Contains(pt))
                    {
                        if (_saveScrollIdx < maxScroll) { _saveScrollIdx++; try { Game1.playSound("shwip"); } catch { } }
                        return;
                    }
                    if (_saveListRect.Contains(pt) && _saveSwipeTouchId < 0)
                    {
                        _saveSwipeTouchId = tl.Id;
                        _saveSwipeStartY = vp.Y;
                        _saveSwipeLastY = vp.Y;
                        _saveSwipeAccumY = 0f;
                        _saveSwipeMoved = false;
                    }
                }
                else if (tl.State == TouchLocationState.Moved && tl.Id == _saveSwipeTouchId)
                {
                    float dy = vp.Y - _saveSwipeLastY;
                    _saveSwipeLastY = vp.Y;
                    if (Math.Abs(vp.Y - _saveSwipeStartY) > 18f)
                        _saveSwipeMoved = true;
                    if (_saveSwipeMoved)
                    {
                        _saveSwipeAccumY += dy;
                        float step = Math.Max(34f, _saveListRect.Height / 5f);
                        while (Math.Abs(_saveSwipeAccumY) >= step)
                        {
                            int dir = _saveSwipeAccumY > 0 ? -1 : 1;
                            _saveSwipeAccumY -= Math.Sign(_saveSwipeAccumY) * step;
                            _saveScrollIdx = Math.Clamp(_saveScrollIdx + dir, 0, maxScroll);
                        }
                    }
                }
                else if ((tl.State == TouchLocationState.Released || tl.State == TouchLocationState.Invalid) && tl.Id == _saveSwipeTouchId)
                {
                    if (!_saveSwipeMoved && _saveListRect.Contains(pt))
                    {
                        for (int r = 0; r < SaveVisibleRows; r++)
                        {
                            int idx = _saveScrollIdx + r;
                            if (idx >= slots.Count) break;
                            if (GetSaveSlotRowRect(r).Contains(pt))
                            {
                                _saveSelectedIdx = idx;
                                try { Game1.playSound("smallSelect"); } catch { }
                                break;
                            }
                        }
                    }
                    _saveSwipeTouchId = -1;
                    _saveSwipeMoved = false;
                }
            }
        }

        private void DrawStardewPixelBox(SpriteBatch sb, Rectangle r, Color fill, Color outerBorder, Color innerBorder, int px)
        {
            sb.Draw(_pixel, r, fill);
            DrawRectOutline(sb, r, px, outerBorder);
            if (r.Width > px * 4 && r.Height > px * 4)
                DrawRectOutline(sb, new Rectangle(r.X + px, r.Y + px, r.Width - px * 2, r.Height - px * 2), px, innerBorder);
        }

        private void DrawStardewPixelButton(SpriteBatch sb, Rectangle r, string text, Color fill, Color hi, Color lo, Color ink, int fontSize, int px)
        {
            sb.Draw(_pixel, r, fill);
            sb.Draw(_pixel, new Rectangle(r.X + px, r.Y + px, r.Width - px * 2, px), hi);
            sb.Draw(_pixel, new Rectangle(r.X + px, r.Bottom - px * 2, r.Width - px * 2, px), lo);
            DrawRectOutline(sb, r, px, new Color(74, 37, 17));
            _bridge?.DrawCenteredString(sb, _pixel, text, r, ink, fontSize);
        }

        private static void DrawCenteredGameText(SpriteBatch sb, Texture2D pixel, PadBridge bridge, string text, Rectangle r, Color color, float scale, int fallbackFs)
        {
            if (string.IsNullOrEmpty(text)) return;
            try
            {
                if (Game1.smallFont != null)
                {
                    Vector2 sz = Game1.smallFont.MeasureString(text) * scale;
                    if (sz.X > r.Width - 10 && sz.X > 1f)
                    {
                        float fit = (r.Width - 10f) / sz.X;
                        scale *= fit;
                        sz *= fit;
                    }
                    Vector2 pos = new Vector2(r.X + (r.Width - sz.X) * 0.5f, r.Y + (r.Height - sz.Y) * 0.5f + 1f);
                    Utility.drawTextWithShadow(sb, text, Game1.smallFont, pos, color, scale);
                    return;
                }
            }
            catch { }
            bridge?.DrawCenteredString(sb, pixel, text, r, color, fallbackFs);
        }

        private void DrawSaveMenuModal(SpriteBatch sb)
        {
            int px = Math.Max(2, (int)Math.Round(_vpH / 320f));
            sb.Draw(_pixel, new Rectangle(0, 0, _vpW, _vpH), Color.Black * 0.54f);

            // Native Stardew 9-slice dialog panel (Game1.menuTexture — automatically skinned by Cat Valley UI & UI mods!)
            PixelUi.DrawNativeDialogBox(sb, _pixel, _savePanelRect, 1f, drawShadow: true);

            float fBase = Math.Clamp(_vpH / 820f, 0.72f, 1.45f);
            int titleFs = Math.Max(2, _vpH / 230);
            int btnFs = Math.Max(1, _vpH / 290);
            int rowFs = Math.Max(1, _vpH / 320);
            Color ink = Game1.textColor;

            var slots = _saveSlots.GetSlotsForCurrentSave();
            string title = $"QUẢN LÝ LƯU NHANH ({slots.Count})";
            var hdrRect = new Rectangle(_savePanelRect.X + px * 8, _savePanelRect.Y + px * 4, _savePanelRect.Width - _saveCloseRect.Width - px * 18, _saveCloseRect.Height);
            DrawCenteredGameText(sb, _pixel, _bridge, title, hdrRect, ink, fBase * 1.02f, titleFs);

            PixelUi.DrawNativeCloseX(sb, _saveCloseRect, 1f);

            // Native Stardew recessed list container (Game1.mouseCursors)
            PixelUi.DrawNativeSubBox(sb, _pixel, _saveListRect, Color.White, 0.92f);

            if (slots.Count == 0)
            {
                var empty1 = new Rectangle(_saveListRect.X + px * 4, _saveListRect.Y + _saveListRect.Height / 3, _saveListRect.Width - px * 8, _saveListRect.Height / 5);
                var empty2 = new Rectangle(_saveListRect.X + px * 4, empty1.Bottom + px * 2, _saveListRect.Width - px * 8, _saveListRect.Height / 5);
                DrawCenteredGameText(sb, _pixel, _bridge, "Chưa có bản lưu nhanh nào", empty1, ink, fBase * 0.90f, btnFs);
                DrawCenteredGameText(sb, _pixel, _bridge, "Bấm '+ Lưu mới' để tạo mốc thời gian", empty2, ink * 0.82f, fBase * 0.78f, rowFs);
            }
            else
            {
                for (int r = 0; r < SaveVisibleRows; r++)
                {
                    int idx = _saveScrollIdx + r;
                    if (idx >= slots.Count) break;
                    SaveSlotInfo slot = slots[idx];
                    Rectangle rowRect = GetSaveSlotRowRect(r);
                    bool sel = (idx == _saveSelectedIdx);

                    PixelUi.DrawNativeSubBox(sb, _pixel, rowRect, sel ? new Color(255, 240, 188) : Color.White, sel ? 1f : 0.90f);

                    int pad = px * 4;
                    int halfH = Math.Max(14, (rowRect.Height - pad * 2) / 2);
                    var topLine = new Rectangle(rowRect.X + pad, rowRect.Y + pad, rowRect.Width - pad * 2, halfH);
                    var subLine = new Rectangle(rowRect.X + pad, topLine.Bottom, rowRect.Width - pad * 2, rowRect.Height - pad * 2 - halfH);

                    string prefix = slot.IsAutoSave ? "" : $"#{slots.Count - idx} ";
                    DrawCenteredGameText(sb, _pixel, _bridge, prefix + slot.FormatHeaderLine(), topLine, ink, fBase * 0.80f, rowFs);
                    DrawCenteredGameText(sb, _pixel, _bridge, slot.FormatDetailLine(), subLine, ink * 0.84f, fBase * 0.72f, Math.Max(1, rowFs));
                }
            }

            // Native Stardew Up/Down scroll buttons (Game1.mouseCursors arrows!)
            bool canUp = _saveScrollIdx > 0;
            bool canDn = _saveScrollIdx + SaveVisibleRows < slots.Count;
            PixelUi.DrawNativeButton(sb, _pixel, _bridge, _saveUpBtnRect, null, Color.White * (canUp ? 1f : 0.50f), fBase * 0.86f, _vpH, drawShadow: false);
            PixelUi.DrawNativeButton(sb, _pixel, _bridge, _saveDnBtnRect, null, Color.White * (canDn ? 1f : 0.50f), fBase * 0.86f, _vpH, drawShadow: false);
            try
            {
                if (Game1.mouseCursors != null)
                {
                    int arrSz = Math.Max(18, Math.Min(_saveUpBtnRect.Width, _saveUpBtnRect.Height) / 2);
                    var upR = new Rectangle(_saveUpBtnRect.Center.X - arrSz / 2, _saveUpBtnRect.Center.Y - arrSz / 2, arrSz, arrSz);
                    var dnR = new Rectangle(_saveDnBtnRect.Center.X - arrSz / 2, _saveDnBtnRect.Center.Y - arrSz / 2, arrSz, arrSz);
                    sb.Draw(Game1.mouseCursors, upR, new Rectangle(421, 459, 11, 12), Color.White * (canUp ? 1f : 0.45f));
                    sb.Draw(Game1.mouseCursors, dnR, new Rectangle(421, 472, 11, 12), Color.White * (canDn ? 1f : 0.45f));
                }
            }
            catch { }

            // Native Stardew bottom action buttons (+ Lưu mới | Tải bản này | Xóa)
            bool hasSel = (_saveSelectedIdx >= 0 && _saveSelectedIdx < slots.Count);
            PixelUi.DrawNativeButton(sb, _pixel, _bridge, _saveNewBtnRect, "+ Lưu mới", new Color(234, 255, 232), fBase * 0.90f, _vpH);
            PixelUi.DrawNativeButton(sb, _pixel, _bridge, _saveLoadBtnRect, "Tải bản này", hasSel ? new Color(255, 246, 218) : (Color.White * 0.55f), fBase * 0.90f, _vpH);
            PixelUi.DrawNativeButton(sb, _pixel, _bridge, _saveDelBtnRect, "Xóa", hasSel ? new Color(255, 232, 228) : (Color.White * 0.55f), fBase * 0.90f, _vpH);
        }

        // =========================================================================
        // RENDERING (Gameplay Overlay + Custom PC Keys + Save Menu + Edit Layout)
        // =========================================================================
        public void DrawGameplayOverlay(SpriteBatch sb)
        {
            if (sb == null || sb.GraphicsDevice == null)
                return;

            EnsureTextures(sb.GraphicsDevice);
            if (!RefreshViewport()) return;
            ComputeLayout();
            PixelUi.GlobalOpacity = _cfg.PixelOpacity;

            if (MobileMinigamePad.DetectCurrentArcadeMinigame() != MobileMinigamePad.ArcadeKind.None)
            {
                if (!_gamepadHideHud)
                    _minigamePad.Draw(sb, _pixel, _circle, _ring, _bridge, _vpW, _vpH);
                return;
            }

            if (_editMode)
            {
                DrawEditLayoutOverlay(sb);
                return;
            }

            // 1. Tap-to-Move Crisp 16-Bit Pixel Target Tile Brackets (subtle, non-distracting!)
            if (_hasTargetTile && _path != null && Game1.currentLocation != null)
            {
                Vector2 tl = WorldToViewport(new Vector2(_targetTile.X * 64f, _targetTile.Y * 64f));
                Vector2 br = WorldToViewport(new Vector2((_targetTile.X + 1) * 64f, (_targetTile.Y + 1) * 64f));
                int w = Math.Max(12, (int)(br.X - tl.X));
                int h = Math.Max(12, (int)(br.Y - tl.Y));
                var tileRect = new Rectangle((int)tl.X, (int)tl.Y, w, h);
                PixelUi.DrawPixelTileTarget(sb, _pixel, tileRect, new Color(118, 226, 128), 0.14f);
            }

            // Hide GUI mode (1-tap HIDE -> clean full-screen view; double-tap anywhere restores GUI!)
            // Also Auto-Hide all touch buttons while physical Bluetooth GamePad is active!
            if ((_guiHidden || _gamepadHideHud) && !_saveMenuOpen)
            {
                double gNow = Environment.TickCount64 / 1000.0;
                if (!string.IsNullOrEmpty(_saveToastText) && gNow < _saveToastUntil)
                    DrawToastBanner(sb, gNow < _ramWarningUntil);
                return;
            }

            // 1b. Optional Full-Height Stardew Mobile Vertical Scrollable 36-Slot Toolbar
            if (_cfg.VerticalToolbar && !_saveMenuOpen)
            {
                _verticalToolbar.Draw(sb, _pixel, _vpH, _cfg.ToolbarOpacity);
            }

            // 2. Collapsible Top Utility Bar (BAG | MAP | QST | SAVE | KEY | [Emote] | [CTL] | [CHAT] | HIDE | EDIT | <)
            double nowSec = Environment.TickCount64 / 1000.0;
            bool isRamWarn = nowSec < _ramWarningUntil;
            if (_cfg.ShowTopUtility)
            {
                DrawMinimalPill(sb, _btnBagRect, "BAG", false);
                if (!_topBarCollapsed)
                {
                    DrawMinimalPill(sb, _btnMapRect, "MAP", false);
                    DrawMinimalPill(sb, _btnQuestRect, "QST", false);
                    if (isRamWarn && !_saveMenuOpen)
                    {
                        double rate = _ramCritical ? 6.0 : 3.0;
                        bool pulse = ((int)(nowSec * rate) % 2) == 0;
                        PixelUi.DrawPixelPill(sb, _pixel, _bridge, _btnSaveRect, "SAVE!",
                            _ramCritical ? PixelRole.Special : PixelRole.Warn, pulse, _vpH, -1, 0.96f);
                    }
                    else
                    {
                        DrawMinimalPill(sb, _btnSaveRect, "SAVE", _saveMenuOpen);
                    }
                    DrawMinimalPill(sb, _btnKeyRect, "KEY", false);
                    if (!_btnEmoteRect.IsEmpty)
                        PixelUi.DrawPixelSmileyButton(sb, _pixel, _btnEmoteRect, false, _vpH);
                    if (!_btnCtlModeRect.IsEmpty)
                        DrawMinimalPill(sb, _btnCtlModeRect, "CTL", _inCombatAutoSwitched);
                    if (!_btnChatRect.IsEmpty)
                        DrawMinimalPill(sb, _btnChatRect, "CHAT", false);
                    if (!_btnHideGuiRect.IsEmpty)
                        DrawMinimalPill(sb, _btnHideGuiRect, "HIDE", false);
                    DrawMinimalPill(sb, _btnEditRect, "EDIT", false);
                }
                DrawMinimalPill(sb, _btnCollapseRect, _topBarCollapsed ? ">" : "<", false);
            }

            // 3. Mode-specific Pixel-Art Overlay (subtle & low-opacity idle -> zero distraction!)
            // Reconstruct active joystick strictly from normalized 0..1 coordinates so Update vs Draw Viewport scaling
            // (e.g., UIScale=1.35 or Zoom=0.90) can NEVER shift the joystick to the bottom edge!
            if (EffectiveMode == MobileControlMode.VisibleJoystick2Btn)
            {
                bool joyAct = (_joyTouchId >= 0 && _joyActivated);
                Vector2 jCenter = _visJoyCenter;
                Vector2 jKnob = jCenter;
                if (joyAct)
                {
                    Vector2 off = new Vector2((_joyKnobNorm.X - _joyOriginNorm.X) * _vpW, (_joyKnobNorm.Y - _joyOriginNorm.Y) * _vpH);
                    float len = off.Length();
                    if (len > _visJoyRadius && len > 0.001f)
                        off *= (_visJoyRadius / len);
                    jKnob = jCenter + off;
                }
                PixelUi.DrawPixelJoystick(sb, jCenter, _visJoyRadius, jKnob, joyAct, _vpH, 0.92f);
                DrawActionCircle(sb, _visToolRect, "USE", _toolPressed, isTool: true);
                DrawActionCircle(sb, _visActRect, "ACT", _interactPressed, isTool: false);
            }
            else if (IsInvisibleBarMode && _cfg.ShowTouchHint)
            {
                if (_joyTouchId >= 0 && _joyActivated)
                {
                    float jr = _activeJoyRadius;
                    Vector2 jCenter = new Vector2(
                        Math.Clamp(_joyOriginNorm.X * _vpW, jr + 8f, Math.Max(jr + 8f, _vpW - jr - 8f)),
                        Math.Clamp(_joyOriginNorm.Y * _vpH, jr + 8f, Math.Max(jr + 8f, _vpH - jr - 8f)));
                    Vector2 off = new Vector2((_joyKnobNorm.X - _joyOriginNorm.X) * _vpW, (_joyKnobNorm.Y - _joyOriginNorm.Y) * _vpH);
                    float len = off.Length();
                    if (len > jr && len > 0.001f)
                        off *= (jr / len);
                    PixelUi.DrawPixelJoystick(sb, jCenter, jr, jCenter + off, true, _vpH, 0.45f);
                }
                if (_toolRippleAlpha > 0.02f)
                {
                    PixelUi.DrawPixelTileTarget(sb, _pixel, _invToolRect, new Color(235, 186, 98) * (_toolRippleAlpha * 0.55f), 0.10f * _toolRippleAlpha);
                }
                if (_interactRippleAlpha > 0.02f)
                {
                    PixelUi.DrawPixelTileTarget(sb, _pixel, _invActRect, new Color(118, 212, 134) * (_interactRippleAlpha * 0.55f), 0.10f * _interactRippleAlpha);
                }
            }

            // 4. User Custom PC Key Buttons (Stardew Pixel style)
            if (_cfg.CustomKeys.Count > 0)
                DrawCustomKeyButtons(sb);

            // 4b. Compact ROW button beside Horizontal PC Toolbar (hidden when Vertical Toolbar is active)
            if (!_cfg.VerticalToolbar && !_btnToolbarRowRect.IsEmpty && !_saveMenuOpen)
            {
                DrawMinimalPill(sb, _btnToolbarRowRect, "ROW", false);
            }

            // 4c. Auto-Context Furniture Rotate Button (ROT)
            if (GetHeldRotatableFurniture() != null && !_saveMenuOpen)
            {
                PixelUi.DrawPixelPill(sb, _pixel, _bridge, _btnRotateRect, "ROT", PixelRole.Tool, false, _vpH, Math.Max(1, _vpH / 290), 0.92f);
            }

            // 4d. Auto-Context Weapon Special Move Button (SPEC: Parry / Slam / Flurry)
            MeleeWeapon specW = GetHeldSpecialWeapon();
            if (specW != null && !_saveMenuOpen)
            {
                bool onCd = IsWeaponSpecialOnCooldown(specW);
                PixelUi.DrawPixelPill(sb, _pixel, _bridge, _btnSpecRect, "SPEC", PixelRole.Special, false, _vpH, Math.Max(1, _vpH / 290), onCd ? 0.40f : 0.88f);
            }

            // 4e. Slingshot Pixel Aiming Reticle while dragging (normalized so UIScale never shifts reticle,
            //     and mirrored across farmer in default pull-back mode so crosshair shows true shot trajectory!)
            if (_slingshotTouchId >= 0 && Game1.player?.CurrentTool is Slingshot)
            {
                float cr = Math.Max(24f, Math.Min(_vpW, _vpH) * 0.036f);
                Vector2 slingDrawPos = new Vector2(_slingshotNorm.X * _vpW, _slingshotNorm.Y * _vpH);
                if (Game1.options == null || !Game1.options.useLegacySlingshotFiring)
                {
                    Vector2 farmerVp = WorldToViewport(Game1.player.getStandingPosition() - new Vector2(0f, 32f));
                    slingDrawPos = farmerVp + (farmerVp - slingDrawPos);
                    slingDrawPos.X = Math.Clamp(slingDrawPos.X, cr, Math.Max(cr, _vpW - cr));
                    slingDrawPos.Y = Math.Clamp(slingDrawPos.Y, cr, Math.Max(cr, _vpH - cr));
                }
                PixelUi.DrawPixelCrosshair(sb, _pixel, slingDrawPos, cr, _vpH);
            }

            // 5. Stardew-Pixel Multi-Slot Save Menu Modal
            if (_saveMenuOpen)
                DrawSaveMenuModal(sb);

            // 6. Save Feedback & High-RAM Warning Toast Banner
            if (!string.IsNullOrEmpty(_saveToastText) && nowSec < _saveToastUntil)
                DrawToastBanner(sb, isRamWarn);
        }

        private void DrawToastBanner(SpriteBatch sb, bool isRamWarn)
        {
            int tw = isRamWarn
                ? Math.Clamp((int)(_vpW * 0.68f), 340, _vpW - 32)
                : Math.Clamp((int)(_vpW * 0.44f), 260, _vpW - 40);
            int th = Math.Max(40, (int)(_vpH * 0.072f));
            var toastR = new Rectangle((_vpW - tw) / 2, _vpH - th - Math.Max(18, _vpH / 26), tw, th);
            Color tint = isRamWarn ? new Color(255, 206, 198) : Color.White;
            PixelUi.DrawNativeDialogBox(sb, _pixel, toastR, 0.96f, drawShadow: true, tintOverride: tint);
            float fScale = Math.Clamp(_vpH / 900f, 0.72f, 1.30f);
            int fs = Math.Max(1, _vpH / 300);
            Color txtCol = isRamWarn ? new Color(156, 22, 18) : Game1.textColor;
            DrawCenteredGameText(sb, _pixel, _bridge, _saveToastText, toastR, txtCol, fScale, fs);
        }

        private void DrawCustomKeyButtons(SpriteBatch sb)
        {
            for (int i = 0; i < _cfg.CustomKeys.Count; i++)
            {
                var btn = _cfg.CustomKeys[i];
                Rectangle r = GetCustomKeyRect(btn);
                bool held = _customBtnsHeldNow.Contains(btn.Id);
                int fontSize = Math.Max(1, Math.Min(r.Height / 18, r.Width / Math.Max(1, btn.Label.Length * 9)));
                fontSize = Math.Clamp(fontSize, 1, Math.Max(2, _vpH / 180));
                PixelUi.DrawPixelPill(sb, _pixel, _bridge, r, btn.Label, PixelRole.CustomKey, held, _vpH, fontSize, 0.96f);
            }
        }

        private void DrawEditLayoutOverlay(SpriteBatch sb)
        {
            sb.Draw(_pixel, new Rectangle(0, 0, _vpW, _vpH), Color.Black * 0.48f);
            Color gridCol = Color.White * 0.07f;
            int step = Math.Max(60, _vpH / 10);
            for (int x = step; x < _vpW; x += step)
                sb.Draw(_pixel, new Rectangle(x, 0, 1, _vpH), gridCol);
            for (int y = step; y < _vpH; y += step)
                sb.Draw(_pixel, new Rectangle(0, y, _vpW, 1), gridCol);

            // Editable Vertical Toolbar preview (drag Left<->Right or Y, drag inner bottom + corner to resize size!)
            if (_cfg.VerticalToolbar && _verticalToolbar.Bounds.Width > 0)
            {
                _verticalToolbar.Draw(sb, _pixel, _vpH, _cfg.ToolbarOpacity);
                Rectangle tbR = _verticalToolbar.Bounds;
                bool sel = (_editSelected == EditTarget.Toolbar);
                Color tbAccent = sel ? new Color(255, 224, 96) : new Color(72, 210, 235);
                DrawRectOutline(sb, tbR, sel ? 4 : 3, tbAccent);
                string tbTag = $"{_cfg.ToolbarColumns}C {(int)Math.Round(_cfg.ToolbarSize * 100)}%";
                var tagR = new Rectangle(tbR.X, tbR.Y + 4, tbR.Width, Math.Max(24, _vpH / 28));
                sb.Draw(_pixel, tagR, Color.Black * 0.65f);
                _bridge?.DrawCenteredString(sb, _pixel, tbTag, tagR, Color.White, Math.Max(1, _vpH / 320));
                int hs = Math.Max(26, _vpH / 32);
                int hx = _cfg.ToolbarSide == 1 ? tbR.Left : tbR.Right - hs;
                var hRect = new Rectangle(hx, tbR.Bottom - hs, hs, hs);
                sb.Draw(_pixel, hRect, tbAccent);
                _bridge?.DrawCenteredString(sb, _pixel, "+", hRect, Color.Black, Math.Max(2, _vpH / 280));
            }

            // Standard Mobile controls
            if (_cfg.Mode != MobileControlMode.TapToMove)
            {
                if (IsInvisibleBarMode)
                {
                    DrawEditableRectBox(sb, _invJoyRect, "JOYSTICK", new Color(10, 132, 255), _editSelected == EditTarget.Joy);
                    DrawEditableRectBox(sb, _invToolRect, "USE", new Color(255, 159, 10), _editSelected == EditTarget.Tool);
                    DrawEditableRectBox(sb, _invActRect, "ACT", new Color(48, 209, 88), _editSelected == EditTarget.Act);
                }
                else
                {
                    DrawEditableCircleBox(sb, _visJoyCenter, _visJoyRadius, "JOY", new Color(10, 132, 255), _editSelected == EditTarget.Joy);
                    DrawEditableCircleBox(sb, _visToolRect.Center.ToVector2(), _visToolRect.Width * 0.5f, "USE", new Color(255, 159, 10), _editSelected == EditTarget.Tool);
                    DrawEditableCircleBox(sb, _visActRect.Center.ToVector2(), _visActRect.Width * 0.5f, "ACT", new Color(48, 209, 88), _editSelected == EditTarget.Act);
                }
            }

            // User Custom PC Key Buttons (violet boxes — movable & resizable!)
            for (int i = 0; i < _cfg.CustomKeys.Count; i++)
            {
                var btn = _cfg.CustomKeys[i];
                bool sel = (_editSelected == EditTarget.CustomKey && _editSelectedCustomId == btn.Id);
                DrawEditableRectBox(sb, GetCustomKeyRect(btn), btn.Label, new Color(175, 82, 222), sel);
            }

            // Draggable top utility bar
            if (_cfg.ShowTopUtility)
            {
                DrawMinimalPill(sb, _btnBagRect, "BAG", false);
                if (!_topBarCollapsed)
                {
                    DrawMinimalPill(sb, _btnMapRect, "MAP", false);
                    DrawMinimalPill(sb, _btnQuestRect, "QST", false);
                    DrawMinimalPill(sb, _btnSaveRect, "SAVE", false);
                    DrawMinimalPill(sb, _btnKeyRect, "KEY", false);
                    if (!_btnEmoteRect.IsEmpty)
                        PixelUi.DrawPixelSmileyButton(sb, _pixel, _btnEmoteRect, false, _vpH);
                    if (!_btnCtlModeRect.IsEmpty)
                        DrawMinimalPill(sb, _btnCtlModeRect, "CTL", false);
                    if (!_btnChatRect.IsEmpty)
                        DrawMinimalPill(sb, _btnChatRect, "CHAT", false);
                    if (!_btnHideGuiRect.IsEmpty)
                        DrawMinimalPill(sb, _btnHideGuiRect, "HIDE", false);
                    DrawMinimalPill(sb, _btnEditRect, "EDIT", false);
                }
                DrawMinimalPill(sb, _btnCollapseRect, _topBarCollapsed ? ">" : "<", false);
                Color tbBorder = _editSelected == EditTarget.TopBar ? new Color(255, 224, 110) : new Color(228, 198, 150) * 0.78f;
                PixelUi.DrawPixelTileTarget(sb, _pixel, _topBarGroupRect, tbBorder, 0.06f);
            }

            // Top-center native Stardew Edit Layout toolbar (+PHIM / XOA / RESET / HUY / LUU)
            PixelUi.DrawNativeDialogBox(sb, _pixel, _editToolbarRect, 0.96f, drawShadow: true);

            float tbScale = Math.Clamp(_vpH / 920f, 0.70f, 1.25f);
            PixelUi.DrawNativeButton(sb, _pixel, _bridge, _editAddKeyBtnRect, "+Phím", new Color(244, 232, 255), tbScale, _vpH, drawShadow: false);
            bool canDel = (_editSelected == EditTarget.CustomKey && _editSelectedCustomId > 0);
            PixelUi.DrawNativeButton(sb, _pixel, _bridge, _editDelKeyBtnRect, "Xóa", canDel ? new Color(255, 228, 224) : (Color.White * 0.55f), tbScale, _vpH, drawShadow: false);
            PixelUi.DrawNativeButton(sb, _pixel, _bridge, _editResetBtnRect, "Reset", Color.White, tbScale, _vpH, drawShadow: false);
            PixelUi.DrawNativeButton(sb, _pixel, _bridge, _editCancelBtnRect, "Hủy", new Color(255, 244, 220), tbScale, _vpH, drawShadow: false);
            PixelUi.DrawNativeButton(sb, _pixel, _bridge, _editSaveBtnRect, "Lưu", new Color(232, 255, 230), tbScale, _vpH, drawShadow: false);

            // In-Game PC Key Picker Modal
            if (_keyPickerOpen)
                DrawKeyPickerModal(sb);
        }

        private void DrawKeyPickerModal(SpriteBatch sb)
        {
            sb.Draw(_pixel, new Rectangle(0, 0, _vpW, _vpH), Color.Black * 0.54f);
            PixelUi.DrawNativeDialogBox(sb, _pixel, _pickerPanelRect, 1f, drawShadow: true);

            float fBase = Math.Clamp(_vpH / 840f, 0.72f, 1.35f);
            int titleFs = Math.Max(2, _vpH / 250);
            var hdrRect = new Rectangle(_pickerPanelRect.X + 18, _pickerPanelRect.Y + 10, _pickerPanelRect.Width - 120, Math.Max(36, _vpH / 16));
            DrawCenteredGameText(sb, _pixel, _bridge, "Chọn phím PC để thêm", hdrRect, Game1.textColor, fBase * 0.98f, titleFs);
            PixelUi.DrawNativeCloseX(sb, _pickerCloseRect, 1f);

            int cellFs = Math.Max(1, _vpH / 300);
            for (int k = 0; k < PcKeyCatalog.Length; k++)
            {
                Rectangle cell = GetKeyPickerCellRect(k);
                PixelUi.DrawPixelPill(sb, _pixel, _bridge, cell, PcKeyCatalog[k].Label,
                    (k < 12) ? PixelRole.Tool : PixelRole.CustomKey, false, _vpH, cellFs, 0.98f);
            }
        }

        private Rectangle GetKeyPickerCellRect(int index)
        {
            const int cols = 12;
            int rows = (PcKeyCatalog.Length + cols - 1) / cols;
            int padX = Math.Max(14, _pickerPanelRect.Width / 50);
            int topOffset = Math.Max(54, _pickerPanelRect.Height / 8);
            int padB = Math.Max(14, _pickerPanelRect.Height / 28);
            int gap = Math.Max(6, _pickerPanelRect.Width / 120);

            int availW = _pickerPanelRect.Width - padX * 2 - gap * (cols - 1);
            int availH = _pickerPanelRect.Height - topOffset - padB - gap * (rows - 1);
            int cw = Math.Max(24, availW / cols);
            int ch = Math.Max(24, availH / rows);

            int r = index / cols;
            int c = index % cols;
            return new Rectangle(_pickerPanelRect.X + padX + c * (cw + gap), _pickerPanelRect.Y + topOffset + r * (ch + gap), cw, ch);
        }

        private void DrawEditableRectBox(SpriteBatch sb, Rectangle r, string label, Color accent, bool selected)
        {
            int px = PixelUi.Step(_vpH);
            Color border = selected ? new Color(255, 232, 128) : accent * 0.90f;
            sb.Draw(_pixel, r, accent * (selected ? 0.30f : 0.16f));
            PixelUi.DrawPixelTileTarget(sb, _pixel, r, border, 0.04f);
            DrawRectOutline(sb, r, px, border * 0.55f);

            int fs = Math.Max(1, Math.Min(r.Height / 18, Math.Max(2, _vpH / 240)));
            _bridge?.DrawCenteredString(sb, _pixel, label, r, Color.White, fs);

            int g = Math.Clamp(Math.Min(r.Width, r.Height) / 3, 18, Math.Max(24, _vpH / 28));
            var gripRect = new Rectangle(r.Right - g, r.Bottom - g, g, g);
            DrawStardewPixelButton(sb, gripRect, "+", selected ? new Color(224, 174, 62) : new Color(168, 122, 64), new Color(255, 224, 140), new Color(96, 56, 20), Color.White, Math.Max(1, fs - 1), Math.Max(1, px / 2));
        }

        private void DrawEditableCircleBox(SpriteBatch sb, Vector2 center, float radius, string label, Color accent, bool selected)
        {
            int d = (int)(radius * 2f);
            var box = new Rectangle((int)(center.X - radius), (int)(center.Y - radius), d, d);
            PixelUi.DrawPixelMedallion(sb, _pixel, _bridge, box, label, selected ? PixelRole.Active : PixelRole.Neutral, selected, _vpH);
            PixelUi.DrawPixelTileTarget(sb, _pixel, box, selected ? new Color(255, 232, 128) : accent * 0.85f, 0.04f);

            int px = PixelUi.Step(_vpH);
            int g = Math.Max(22, _vpH / 28);
            var gripRect = new Rectangle(box.Right - g, box.Bottom - g, g, g);
            DrawStardewPixelButton(sb, gripRect, "+", selected ? new Color(224, 174, 62) : new Color(168, 122, 64), new Color(255, 224, 140), new Color(96, 56, 20), Color.White, 1, Math.Max(1, px / 2));
        }

        private void DrawToolbarActionButton(SpriteBatch sb, Rectangle r, string text, Color tint, int fontSize)
        {
            int px = PixelUi.Step(_vpH);
            Color hi = new Color(Math.Min(255, tint.R + 42), Math.Min(255, tint.G + 42), Math.Min(255, tint.B + 42));
            Color lo = new Color(Math.Max(0, tint.R - 46), Math.Max(0, tint.G - 46), Math.Max(0, tint.B - 46));
            DrawStardewPixelButton(sb, r, text, tint * 0.92f, hi * 0.90f, lo * 0.90f, Color.White, fontSize, px);
        }

        private void DrawMinimalPill(SpriteBatch sb, Rectangle r, string label, bool active)
        {
            PixelUi.DrawPixelPill(sb, _pixel, _bridge, r, label, active ? PixelRole.Active : PixelRole.Neutral, active, _vpH);
        }

        private void DrawActionCircle(SpriteBatch sb, Rectangle r, string label, bool pressed, bool isTool)
        {
            PixelUi.DrawPixelMedallion(sb, _pixel, _bridge, r, label, isTool ? PixelRole.Tool : PixelRole.Action, pressed, _vpH);
        }

        private void DrawCircle(SpriteBatch sb, Vector2 center, float radius, Color color)
        {
            int d = Math.Max(4, (int)(radius * 2f));
            sb.Draw(_circle, new Rectangle((int)(center.X - radius), (int)(center.Y - radius), d, d), color);
        }

        private void DrawRing(SpriteBatch sb, Vector2 center, float radius, Color color)
        {
            int d = Math.Max(4, (int)(radius * 2f));
            sb.Draw(_ring, new Rectangle((int)(center.X - radius), (int)(center.Y - radius), d, d), color);
        }

        private void DrawRectOutline(SpriteBatch sb, Rectangle r, int t, Color c)
        {
            sb.Draw(_pixel, new Rectangle(r.X, r.Y, r.Width, t), c);
            sb.Draw(_pixel, new Rectangle(r.X, r.Bottom - t, r.Width, t), c);
            sb.Draw(_pixel, new Rectangle(r.X, r.Y, t, r.Height), c);
            sb.Draw(_pixel, new Rectangle(r.Right - t, r.Y, t, r.Height), c);
        }

        private bool RefreshViewport()
        {
            try
            {
                var gd = Game1.graphics?.GraphicsDevice;
                if (gd != null)
                {
                    if (gd.Viewport.Width > 0 && gd.Viewport.Height > 0)
                    {
                        _vpW = gd.Viewport.Width;
                        _vpH = gd.Viewport.Height;
                    }
                    if (gd.PresentationParameters.BackBufferWidth > 0 && gd.PresentationParameters.BackBufferHeight > 0)
                    {
                        _rawW = gd.PresentationParameters.BackBufferWidth;
                        _rawH = gd.PresentationParameters.BackBufferHeight;
                    }
                }
                if ((_vpW <= 0 || _vpH <= 0) && Game1.viewport.Width > 0 && Game1.viewport.Height > 0)
                {
                    _vpW = Game1.viewport.Width;
                    _vpH = Game1.viewport.Height;
                }
                if (_rawW <= 0 || _rawH <= 0)
                {
                    _rawW = _vpW;
                    _rawH = _vpH;
                }
            }
            catch { }
            return _vpW > 0 && _vpH > 0;
        }

        private int PeekToolbarTopUiY()
        {
            if (_cachedHudToolbar != null && _cachedHudToolbar.buttons != null && _cachedHudToolbar.buttons.Count >= 12)
            {
                if (Game1.onScreenMenus != null && Game1.onScreenMenus.Contains(_cachedHudToolbar))
                    return _cachedHudToolbar.buttons[0].bounds.Y;
                _cachedHudToolbar = null;
            }
            if (Game1.onScreenMenus != null)
            {
                for (int i = 0; i < Game1.onScreenMenus.Count; i++)
                {
                    if (Game1.onScreenMenus[i] is Toolbar tb && tb.buttons != null && tb.buttons.Count >= 12)
                    {
                        _cachedHudToolbar = tb;
                        return tb.buttons[0].bounds.Y;
                    }
                }
            }
            return -1;
        }

        private void ComputeLayout(bool force = false)
        {
            MobileControlMode effMode = EffectiveMode;
            bool isMp = Context.IsMultiplayer;
            int maxItems = Game1.player != null ? Game1.player.MaxItems : 0;
            int uiW = Game1.uiViewport.Width;
            int uiH = Game1.uiViewport.Height;
            int tbTopY = (!_cfg.VerticalToolbar && maxItems > 12) ? PeekToolbarTopUiY() : -1;

            if (!force && !_editMode && _layoutValid &&
                _layoutVpW == _vpW && _layoutVpH == _vpH &&
                _layoutCfgRev == _cfg.Revision &&
                _layoutEffMode == effMode &&
                _layoutCollapsed == _topBarCollapsed &&
                _layoutIsMp == isMp &&
                _layoutMaxItems == maxItems &&
                _layoutUiW == uiW && _layoutUiH == uiH &&
                _layoutTbTopY == tbTopY)
            {
                return;
            }

            _layoutValid = !_editMode;
            _layoutVpW = _vpW;
            _layoutVpH = _vpH;
            _layoutCfgRev = _cfg.Revision;
            _layoutEffMode = effMode;
            _layoutCollapsed = _topBarCollapsed;
            _layoutIsMp = isMp;
            _layoutMaxItems = maxItems;
            _layoutUiW = uiW;
            _layoutUiH = uiH;
            _layoutTbTopY = tbTopY;

            float s = _cfg.ButtonScale;
            // On 16:9 / 19.5:9 iPhones _vpW * 0.56f >= _vpH (unchanged!); on 4:3 iPads it keeps touch buttons nicely proportioned instead of oversized!
            float unit = Math.Min(Math.Min(_vpW, _vpH), _vpW * 0.56f);

            // 1. Invisible Mode: Left Joystick Rect + 2 Tall Vertical Rectangular Bars on Right
            _invJoyRect = NormToRect(_cfg.InvJoyX, _cfg.InvJoyY, _cfg.InvJoyW, _cfg.InvJoyH);
            Rectangle rawToolBar = NormToRect(_cfg.InvToolX, _cfg.InvToolY, _cfg.InvToolW, _cfg.InvToolH);
            Rectangle rawActBar = NormToRect(_cfg.InvActX, _cfg.InvActY, _cfg.InvActW, _cfg.InvActH);
            if (_cfg.SwapRightButtons) { _invToolRect = rawActBar; _invActRect = rawToolBar; }
            else { _invToolRect = rawToolBar; _invActRect = rawActBar; }

            // 2. Visible 2-Button Mode: Circle Joystick + 2 Circular Buttons (clamped safely inside viewport bounds!)
            _visJoyRadius = Math.Clamp(unit * _cfg.VisJoyR * s, 48f, unit * 0.25f);
            _activeJoyRadius = IsInvisibleBarMode ? Math.Clamp(unit * 0.115f * s, 48f, unit * 0.20f) : _visJoyRadius;
            float jPad = _visJoyRadius + 10f;
            _visJoyCenter = new Vector2(
                Math.Clamp(_cfg.VisJoyX * _vpW, jPad, Math.Max(jPad, _vpW - jPad)),
                Math.Clamp(_cfg.VisJoyY * _vpH, jPad, Math.Max(jPad, _vpH - jPad)));

            int toolD = (int)Math.Clamp(unit * _cfg.VisToolR * 2f * s, 56f, unit * 0.34f);
            int actD = (int)Math.Clamp(unit * _cfg.VisActR * 2f * s, 56f, unit * 0.34f);
            Rectangle visTool = new Rectangle((int)(_cfg.VisToolX * _vpW - toolD * 0.5f), (int)(_cfg.VisToolY * _vpH - toolD * 0.5f), toolD, toolD);
            Rectangle visAct = new Rectangle((int)(_cfg.VisActX * _vpW - actD * 0.5f), (int)(_cfg.VisActY * _vpH - actD * 0.5f), actD, actD);
            if (_cfg.SwapRightButtons) { _visToolRect = visAct; _visActRect = visTool; }
            else { _visToolRect = visTool; _visActRect = visAct; }

            // 3. Safe Area + Multi-Column Vertical Toolbar FIRST (so Top Bar, Clock, Joystick & Action Buttons adapt dynamically to Left/Right edge & thickness!)
            _safeLeftPx = ComputeSafeLeftPx();
            _safeRightPx = ComputeSafeRightPx();
            if (_cfg.VerticalToolbar)
            {
                _verticalToolbar.ComputeLayout(
                    _vpW, _vpH,
                    _safeLeftPx, _safeRightPx,
                    _cfg.ToolbarSize,
                    _cfg.ToolbarColumns,
                    _cfg.ToolbarVisibleRows,
                    _cfg.ToolbarSide,
                    _cfg.ToolbarY);
            }

            // Collapsible Top Utility Bar — dynamically clears Vertical Toolbar (Left or Right) & auto-fits clear of Clock!
            int minLeftClear = (_cfg.VerticalToolbar && _cfg.ToolbarSide == 0) ? (_verticalToolbar.Bounds.Right + 10) : (_safeLeftPx + 8);
            int leftX = Math.Max(minLeftClear, (int)(_cfg.TopBarX * _vpW));
            int topY = (int)(_cfg.TopBarY * _vpH);
            int pillH = (int)Math.Clamp(unit * 0.056f, 28f, unit * 0.08f);
            bool showChatBtn = Context.IsMultiplayer;

            // Auto-fit Top Bar width so it NEVER collides with DayTimeMoneyBox (or Right-docked Vertical Toolbar!)
            int rightClockAndTb = _safeRightPx + Math.Max(215, (int)(_vpW * 0.21f));
            if (_cfg.VerticalToolbar && _cfg.ToolbarSide == 1 && _verticalToolbar.Bounds.Width > 0)
                rightClockAndTb += _verticalToolbar.Bounds.Width + 12;
            int maxTopBarRight = _vpW - rightClockAndTb;
            if (!_topBarCollapsed && maxTopBarRight > leftX + 180)
            {
                float estUnits = 1.85f * 4f + 2.15f * 3f + 1.10f
                    + (_cfg.ShowEmoteButton ? 1.25f : 0f)
                    + (_cfg.AutoCombatMode ? 1.85f : 0f)
                    + (showChatBtn ? 2.15f : 0f);
                int estSlots = 8 + (_cfg.ShowEmoteButton ? 1 : 0) + (_cfg.AutoCombatMode ? 1 : 0) + (showChatBtn ? 1 : 0);
                float estW = estUnits * pillH + (estSlots - 1) * Math.Max(4, pillH / 5);
                float availW = maxTopBarRight - leftX;
                if (estW > availW)
                {
                    float ratio = availW / Math.Max(1f, estW);
                    pillH = Math.Max(22, (int)(pillH * ratio));
                }
            }

            int pillW = (int)(pillH * 1.85f);
            int modsW = (int)(pillH * 2.15f);
            int colW = (int)(pillH * 1.10f);
            int emoteW = (int)(pillH * 1.25f);
            int pillGap = Math.Max(4, pillH / 5);

            int cx = leftX;
            _btnBagRect = new Rectangle(cx, topY, pillW, pillH);
            cx += pillW + pillGap;

            _btnEmoteRect = Rectangle.Empty;
            _btnCtlModeRect = Rectangle.Empty;
            _btnChatRect = Rectangle.Empty;
            _btnHideGuiRect = Rectangle.Empty;
            if (!_topBarCollapsed)
            {
                _btnMapRect = new Rectangle(cx, topY, pillW, pillH); cx += pillW + pillGap;
                _btnQuestRect = new Rectangle(cx, topY, pillW, pillH); cx += pillW + pillGap;
                _btnSaveRect = new Rectangle(cx, topY, modsW, pillH); cx += modsW + pillGap;
                _btnKeyRect = new Rectangle(cx, topY, pillW, pillH); cx += pillW + pillGap;
                if (_cfg.ShowEmoteButton)
                {
                    _btnEmoteRect = new Rectangle(cx, topY, emoteW, pillH);
                    cx += emoteW + pillGap;
                }
                if (_cfg.AutoCombatMode)
                {
                    _btnCtlModeRect = new Rectangle(cx, topY, pillW, pillH);
                    cx += pillW + pillGap;
                }
                if (showChatBtn)
                {
                    _btnChatRect = new Rectangle(cx, topY, modsW, pillH);
                    cx += modsW + pillGap;
                }
                _btnHideGuiRect = new Rectangle(cx, topY, modsW, pillH); cx += modsW + pillGap;
                _btnEditRect = new Rectangle(cx, topY, modsW, pillH); cx += modsW + pillGap;
            }
            else
            {
                _btnMapRect = _btnQuestRect = _btnSaveRect = _btnKeyRect = _btnEditRect = Rectangle.Empty;
            }

            _btnCollapseRect = new Rectangle(cx, topY, colW, pillH);
            _topBarGroupRect = new Rectangle(leftX - 4, topY - 4, (_btnCollapseRect.Right - leftX) + 8, pillH + 8);

            // Auto-Context Furniture Rotate (ROT), Weapon Special Move (SPEC) & Cutscene SKIP (clear of right Notch/Dynamic Island!)
            int rotW = (int)(pillH * 2.15f);
            int rotH = (int)(pillH * 1.18f);
            int rightEdgePad = Math.Max(_safeRightPx + 12, Math.Max(16, (int)(_vpW * 0.025f)));
            _btnRotateRect = new Rectangle(_vpW - rotW - rightEdgePad, (int)(_vpH * 0.34f), rotW, rotH);
            _btnSpecRect = new Rectangle(_vpW - rotW - rightEdgePad, (int)(_vpH * 0.34f), rotW, rotH);
            // Exact 22:15 pixel-perfect integer scale matching vanilla/Cat Valley UI Skip sprite (Game1.mouseCursors 205,406,22,15)
            int skipScale = Math.Clamp((int)Math.Round(unit * 0.0068f), 3, 6);
            int skipW = 22 * skipScale;
            int skipH = 15 * skipScale;
            int skipRightPad = Math.Max(_safeRightPx + 24, Math.Max(36, (int)(_vpW * 0.055f)));
            int skipTopPad = Math.Max(38, (int)(_vpH * 0.085f));
            _btnSkipEventRect = new Rectangle(_vpW - skipW - skipRightPad, skipTopPad, skipW, skipH);

            // 1-Tap Left-Handed Mirror Layout (WYSIWYG in both Gameplay AND Edit Layout!)
            if (_cfg.LeftHandedMobile)
            {
                Rectangle MirrorX(Rectangle r) => new Rectangle(_vpW - r.Right, r.Y, r.Width, r.Height);
                _invJoyRect = MirrorX(_invJoyRect);
                _invToolRect = MirrorX(_invToolRect);
                _invActRect = MirrorX(_invActRect);
                _visJoyCenter = new Vector2(_vpW - _visJoyCenter.X, _visJoyCenter.Y);
                _visToolRect = MirrorX(_visToolRect);
                _visActRect = MirrorX(_visActRect);
                _btnRotateRect = MirrorX(_btnRotateRect);
                _btnSpecRect = MirrorX(_btnSpecRect);
            }

            // Auto-clear VerticalToolbar (BOTH Left and Right docking!) so NEITHER Joystick NOR Action Buttons overlap it!
            if (_cfg.VerticalToolbar && !_editMode && _verticalToolbar.Bounds.Width > 0)
            {
                if (_cfg.ToolbarSide == 0)
                {
                    int minX = _verticalToolbar.Bounds.Right + 8;
                    if (!_cfg.LeftHandedMobile)
                    {
                        if (_invJoyRect.X < minX && _invJoyRect.Right > minX + 60)
                        {
                            int delta = minX - _invJoyRect.X;
                            _invJoyRect = new Rectangle(minX, _invJoyRect.Y, Math.Max(60, _invJoyRect.Width - delta), _invJoyRect.Height);
                        }
                        if (_visJoyCenter.X - _visJoyRadius < minX)
                            _visJoyCenter = new Vector2(minX + _visJoyRadius + 4, _visJoyCenter.Y);
                    }
                    else
                    {
                        int leftMostInv = Math.Min(_invToolRect.X, _invActRect.X);
                        if (leftMostInv < minX)
                        {
                            int shift = minX - leftMostInv;
                            _invToolRect = new Rectangle(_invToolRect.X + shift, _invToolRect.Y, _invToolRect.Width, _invToolRect.Height);
                            _invActRect = new Rectangle(_invActRect.X + shift, _invActRect.Y, _invActRect.Width, _invActRect.Height);
                        }
                        int leftMostVis = Math.Min(_visToolRect.X, _visActRect.X);
                        if (leftMostVis < minX)
                        {
                            int shift = minX - leftMostVis;
                            _visToolRect = new Rectangle(_visToolRect.X + shift, _visToolRect.Y, _visToolRect.Width, _visToolRect.Height);
                            _visActRect = new Rectangle(_visActRect.X + shift, _visActRect.Y, _visActRect.Width, _visActRect.Height);
                        }
                        if (_btnRotateRect.X < minX) _btnRotateRect = new Rectangle(minX, _btnRotateRect.Y, _btnRotateRect.Width, _btnRotateRect.Height);
                        if (_btnSpecRect.X < minX) _btnSpecRect = new Rectangle(minX, _btnSpecRect.Y, _btnSpecRect.Width, _btnSpecRect.Height);
                    }
                }
                else
                {
                    int maxX = _verticalToolbar.Bounds.Left - 8;
                    if (!_cfg.LeftHandedMobile)
                    {
                        int rightMostInv = Math.Max(_invToolRect.Right, _invActRect.Right);
                        if (rightMostInv > maxX)
                        {
                            int shift = rightMostInv - maxX;
                            _invToolRect = new Rectangle(Math.Max(8, _invToolRect.X - shift), _invToolRect.Y, _invToolRect.Width, _invToolRect.Height);
                            _invActRect = new Rectangle(Math.Max(8, _invActRect.X - shift), _invActRect.Y, _invActRect.Width, _invActRect.Height);
                        }
                        int rightMostVis = Math.Max(_visToolRect.Right, _visActRect.Right);
                        if (rightMostVis > maxX)
                        {
                            int shift = rightMostVis - maxX;
                            _visToolRect = new Rectangle(Math.Max(8, _visToolRect.X - shift), _visToolRect.Y, _visToolRect.Width, _visToolRect.Height);
                            _visActRect = new Rectangle(Math.Max(8, _visActRect.X - shift), _visActRect.Y, _visActRect.Width, _visActRect.Height);
                        }
                        if (_btnRotateRect.Right > maxX) _btnRotateRect = new Rectangle(Math.Max(8, maxX - _btnRotateRect.Width), _btnRotateRect.Y, _btnRotateRect.Width, _btnRotateRect.Height);
                        if (_btnSpecRect.Right > maxX) _btnSpecRect = new Rectangle(Math.Max(8, maxX - _btnSpecRect.Width), _btnSpecRect.Y, _btnSpecRect.Width, _btnSpecRect.Height);
                    }
                    else
                    {
                        if (_invJoyRect.Right > maxX && maxX - _invJoyRect.X > 60)
                            _invJoyRect = new Rectangle(_invJoyRect.X, _invJoyRect.Y, Math.Max(60, maxX - _invJoyRect.X), _invJoyRect.Height);
                        if (_visJoyCenter.X + _visJoyRadius > maxX)
                            _visJoyCenter = new Vector2(Math.Max(_visJoyRadius + 8, maxX - _visJoyRadius - 4), _visJoyCenter.Y);
                    }
                }
            }

            // Compact ROW quick-switch pill right beside Toolbar (only when player has > 12 inventory slots & Horizontal PC Toolbar!)
            _btnToolbarRowRect = Rectangle.Empty;
            if (!_cfg.VerticalToolbar && Game1.player != null && Game1.player.MaxItems > 12 && TryGetToolbarViewportBounds(out Rectangle tbR))
            {
                int rowW = Math.Max(42, (int)(tbR.Height * 0.92f));
                int rowH = Math.Max(30, (int)(tbR.Height * 0.78f));
                int rx = tbR.Right + Math.Max(6, rowW / 7);
                if (rx + rowW > _vpW - _safeRightPx - 8)
                    rx = Math.Max(_safeLeftPx + 8, tbR.X - rowW - Math.Max(6, rowW / 7));
                int ry = tbR.Y + (tbR.Height - rowH) / 2;
                _btnToolbarRowRect = new Rectangle(rx, ry, rowW, rowH);
            }

            // Context Menu Helper Bar (clear of left Dynamic Island / Notch!)
            int mx0 = Math.Max(_safeLeftPx + 10, (int)Math.Max(_vpW * 0.048f, unit * 0.06f));
            int mx = mx0;
            int my = (int)Math.Max(unit * 0.022f, 12f);
            _ctxQuestEscRect = new Rectangle(mx0, my, pillW, pillH);
            _ctxX1Rect   = new Rectangle(mx, my, pillW, pillH); mx += pillW + pillGap;
            _ctxHalfRect = new Rectangle(mx, my, pillW, pillH); mx += pillW + pillGap;
            _ctxXferRect = new Rectangle(mx, my, modsW, pillH); mx += modsW + pillGap;
            _ctxKeyRect  = new Rectangle(mx, my, pillW, pillH); mx += pillW + pillGap;
            _ctxEscRect  = new Rectangle(mx, my, pillW, pillH);

            // Multi-Slot Stardew-Pixel Save Menu Modal Layout (100% dynamic, never hardcoded!)
            int spw = Math.Clamp((int)(_vpW * 0.68f), 420, _vpW - 40);
            int sph = Math.Clamp((int)(_vpH * 0.76f), 280, _vpH - 32);
            _savePanelRect = new Rectangle((_vpW - spw) / 2, (_vpH - sph) / 2, spw, sph);
            int sPad = Math.Max(14, (int)(unit * 0.022f));
            int sClose = Math.Max(34, (int)(sph * 0.105f));
            _saveCloseRect = new Rectangle(_savePanelRect.Right - sClose - sPad, _savePanelRect.Y + sPad, sClose, sClose);

            int sBtnH = Math.Max(38, (int)(sph * 0.135f));
            int sBtnY = _savePanelRect.Bottom - sPad - sBtnH;
            int sBtnGap = Math.Max(10, sPad / 2);
            int sAvailW = spw - sPad * 2 - sBtnGap * 2;
            int sNewW = (int)(sAvailW * 0.36f);
            int sLoadW = (int)(sAvailW * 0.40f);
            int sDelW = sAvailW - sNewW - sLoadW;
            _saveNewBtnRect = new Rectangle(_savePanelRect.X + sPad, sBtnY, sNewW, sBtnH);
            _saveLoadBtnRect = new Rectangle(_saveNewBtnRect.Right + sBtnGap, sBtnY, sLoadW, sBtnH);
            _saveDelBtnRect = new Rectangle(_saveLoadBtnRect.Right + sBtnGap, sBtnY, sDelW, sBtnH);

            int sScrollW = Math.Max(36, (int)(spw * 0.068f));
            int sListTop = _saveCloseRect.Bottom + Math.Max(8, sPad / 2);
            int sListH = Math.Max(120, sBtnY - sListTop - Math.Max(10, sPad / 2));
            _saveListRect = new Rectangle(_savePanelRect.X + sPad, sListTop, spw - sPad * 2 - sScrollW - sBtnGap, sListH);
            int sHalfScrollH = (sListH - sBtnGap) / 2;
            _saveUpBtnRect = new Rectangle(_saveListRect.Right + sBtnGap, sListTop, sScrollW, sHalfScrollH);
            _saveDnBtnRect = new Rectangle(_saveListRect.Right + sBtnGap, sListTop + sHalfScrollH + sBtnGap, sScrollW, sListH - sHalfScrollH - sBtnGap);

            // 4. Edit Layout top-center toolbar (+PHIM / XOA / RESET / HUY / LUU)
            int ebH = (int)Math.Clamp(unit * 0.066f, 36f, unit * 0.09f);
            int ebW = (int)(ebH * 2.05f);
            int ebGap = Math.Max(8, ebH / 5);
            int pad = Math.Max(8, ebH / 5);
            int totalW = ebW * 5 + ebGap * 4 + pad * 2;
            int totalH = ebH + pad * 2;
            int tbX = (_vpW - totalW) / 2;
            int tbY = (int)Math.Max(unit * 0.024f, 14f);

            _editToolbarRect = new Rectangle(tbX, tbY, totalW, totalH);
            int bx = tbX + pad;
            _editAddKeyBtnRect = new Rectangle(bx, tbY + pad, ebW, ebH); bx += ebW + ebGap;
            _editDelKeyBtnRect = new Rectangle(bx, tbY + pad, ebW, ebH); bx += ebW + ebGap;
            _editResetBtnRect  = new Rectangle(bx, tbY + pad, ebW, ebH); bx += ebW + ebGap;
            _editCancelBtnRect = new Rectangle(bx, tbY + pad, ebW, ebH); bx += ebW + ebGap;
            _editSaveBtnRect   = new Rectangle(bx, tbY + pad, ebW, ebH);

            // 5. In-Game PC Key Picker modal rect
            int pw = (int)(_vpW * 0.84f);
            int ph = (int)(_vpH * 0.78f);
            _pickerPanelRect = new Rectangle((_vpW - pw) / 2, (_vpH - ph) / 2, pw, ph);
            int closeS = Math.Max(34, ph / 11);
            _pickerCloseRect = new Rectangle(_pickerPanelRect.Right - closeS - 12, _pickerPanelRect.Y + 10, closeS, closeS);
        }

        private Rectangle NormToRect(float nx, float ny, float nw, float nh)
        {
            int x = (int)Math.Round(nx * _vpW);
            int y = (int)Math.Round(ny * _vpH);
            int w = Math.Max(44, (int)Math.Round(nw * _vpW));
            int h = Math.Max(56, (int)Math.Round(nh * _vpH));
            return new Rectangle(x, y, w, h);
        }

        private Vector2 MapRawToViewport(Vector2 raw)
        {
            if (_rawW <= 0 || _rawH <= 0 || _vpW <= 0 || _vpH <= 0)
                return raw;
            return new Vector2(raw.X / _rawW * _vpW, raw.Y / _rawH * _vpH);
        }

        private Point ViewportToRaw(Vector2 vp)
        {
            if (_rawW <= 0 || _rawH <= 0 || _vpW <= 0 || _vpH <= 0)
                return new Point((int)Math.Round(vp.X), (int)Math.Round(vp.Y));
            return new Point(
                Math.Clamp((int)Math.Round(vp.X / _vpW * _rawW), 0, _rawW - 1),
                Math.Clamp((int)Math.Round(vp.Y / _vpH * _rawH), 0, _rawH - 1));
        }

        private Point ViewportToUi(Vector2 vp)
        {
            int uiW = Game1.uiViewport.Width;
            int uiH = Game1.uiViewport.Height;
            if (uiW <= 0 || uiH <= 0 || _vpW <= 0 || _vpH <= 0)
                return new Point((int)vp.X, (int)vp.Y);
            return new Point((int)(vp.X * uiW / _vpW), (int)(vp.Y * uiH / _vpH));
        }

        private Vector2 UiToViewport(Point uiPt)
        {
            int uiW = Game1.uiViewport.Width;
            int uiH = Game1.uiViewport.Height;
            if (uiW <= 0 || uiH <= 0 || _vpW <= 0 || _vpH <= 0)
                return new Vector2(uiPt.X, uiPt.Y);
            return new Vector2(uiPt.X * (float)_vpW / uiW, uiPt.Y * (float)_vpH / uiH);
        }

        private Vector2 ViewportToWorld(Vector2 vp)
        {
            float wx = Game1.viewport.X + vp.X * (Game1.viewport.Width / (float)Math.Max(1, _vpW));
            float wy = Game1.viewport.Y + vp.Y * (Game1.viewport.Height / (float)Math.Max(1, _vpH));
            return new Vector2(wx, wy);
        }

        private Vector2 WorldToViewport(Vector2 world)
        {
            float sx = (world.X - Game1.viewport.X) * (_vpW / (float)Math.Max(1, Game1.viewport.Width));
            float sy = (world.Y - Game1.viewport.Y) * (_vpH / (float)Math.Max(1, Game1.viewport.Height));
            return new Vector2(sx, sy);
        }

        private void EnsureTextures(GraphicsDevice gd)
        {
            if (_pixel != null && !_pixel.IsDisposed)
                return;

            _pixel = new Texture2D(gd, 1, 1);
            _pixel.SetData(new[] { Color.White });

            const int sz = 128;
            float r = sz * 0.5f;
            var fillData = new Color[sz * sz];
            var ringData = new Color[sz * sz];

            for (int y = 0; y < sz; y++)
            {
                for (int x = 0; x < sz; x++)
                {
                    float dx = (x + 0.5f) - r;
                    float dy = (y + 0.5f) - r;
                    float d = (float)Math.Sqrt(dx * dx + dy * dy);
                    int idx = y * sz + x;

                    float fillAlpha = Math.Clamp(r - 1.5f - d, 0f, 1f);
                    fillData[idx] = Color.White * fillAlpha;

                    float ringDist = Math.Abs(d - (r - 4.0f));
                    float ringAlpha = Math.Clamp(2.8f - ringDist, 0f, 1f);
                    ringData[idx] = Color.White * ringAlpha;
                }
            }

            _circle = new Texture2D(gd, sz, sz);
            _circle.SetData(fillData);

            _ring = new Texture2D(gd, sz, sz);
            _ring.SetData(ringData);
        }
    }
}
