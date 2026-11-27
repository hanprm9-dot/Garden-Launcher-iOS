using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Input;
using StardewModdingAPI;
using StardewValley;
using StardewValley.Menus;

namespace SDVMobileControls
{
    internal enum ExternalInputMode
    {
        Touch = 0,
        Gamepad = 1,
        KeyboardMouse = 2
    }

    /// <summary>
    /// Bridges native iOS 14–27+ GameController.framework + CoreHaptics peripherals (ExternalInput.m in SDVModGarden.framework)
    /// into MonoGame, Stardew Valley, and SMAPI (100% Zero-Harmony compatible for 0% JIT Mono Interpreter):
    ///   - Full Physical Gamepad (sticks, triggers, bumpers, L3/R3, Options/Menu, D-Pad, CoreHaptics Rumble)
    ///   - Console-grade SnappyMenus + same-frame SInputState/oldMouseState sync, LB/RB/LT/RT frame &amp; tab switching,
    ///     item Swap / Drop (-99998 safe-clamp fix) / Hold-A Drag-and-Drop, and universal R-Stick menu cursor
    ///   - Optional Pure Gamepad Mode (disables virtual touch HUD &amp; touch interceptors cleanly from boot)
    ///   - Full Physical Hardware Keyboard &amp; Mouse / Trackpad
    /// </summary>
    internal sealed class ExternalInputBridge
    {
        private const int ExpectedStructSize = 212;

        // Exact byte offsets of SDVExtInputSnapshot in ExternalInput.m (all 4-byte aligned on arm64)
        private const int OffStructSize = 0;
        private const int OffSuppress = 4;
        private const int OffGpConnected = 8;
        private const int OffGpButtonsMask = 12;
        private const int OffGpLeftX = 16;
        private const int OffGpLeftY = 20;
        private const int OffGpRightX = 24;
        private const int OffGpRightY = 28;
        private const int OffGpLeftTrigger = 32;
        private const int OffGpRightTrigger = 36;
        private const int OffGpActivitySeq = 40;
        private const int OffKbConnected = 44;
        private const int OffKbKeyCount = 48;
        private const int OffKbKeys = 52;       // 32 * uint16 (64 bytes -> ends 116)
        private const int OffTextCharCount = 116;
        private const int OffTextChars = 120;   // 32 * uint16 (64 bytes -> ends 184)
        private const int OffKbActivitySeq = 184;
        private const int OffMouseConnected = 188;
        private const int OffMouseNormX = 192;
        private const int OffMouseNormY = 196;
        private const int OffMouseButtonsMask = 200;
        private const int OffMouseScrollDelta = 204;
        private const int OffMouseActivitySeq = 208;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int PollInputDelegate(IntPtr outBuf);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void SetMouseNormDelegate(float nx, float ny);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int GetDirectTouchCountDelegate();

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void SetRumbleDelegate(float leftMotor, float rightMotor);

        [DllImport("/usr/lib/libSystem.dylib", EntryPoint = "dlsym")]
        private static extern IntPtr DarwinDlsym(IntPtr handle, [MarshalAs(UnmanagedType.LPStr)] string symbol);

        private static readonly IntPtr RTLD_DEFAULT = new IntPtr(-2);

        private static readonly MethodInfo KeyboardSetKeysMethod =
            typeof(Keyboard).GetMethod("SetKeys", BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public, null, new[] { typeof(List<Keys>) }, null);

        private static readonly MethodInfo GamePadPlatformGetStateMethod =
            typeof(GamePad).GetMethod("PlatformGetState",
                BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public,
                null,
                new[] { typeof(int), typeof(GamePadDeadZone), typeof(GamePadDeadZone) },
                null);

        private static readonly object[] GamePadPlatformArgs =
            new object[] { 0, GamePadDeadZone.IndependentAxes, GamePadDeadZone.IndependentAxes };

        private static readonly FieldInfo InputCurrentMouseField =
            typeof(InputState).GetField("_currentMouseState", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        private static readonly FieldInfo InputCurrentGamepadField =
            typeof(InputState).GetField("_currentGamepadState", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
        private static readonly FieldInfo MousePrimaryWindowField =
            typeof(Mouse).GetField("PrimaryWindow", BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public);
        private static PropertyInfo _windowMouseStateProp;
        private static FieldInfo _windowMouseStateField;
        private static bool _windowMouseMemberResolved;
        private static FieldInfo _sInputControllerField;
        private static FieldInfo _sInputMouseField;
        private static bool _sInputFieldsResolved;

        // Cached reflection handles for StardewValley.Rumble (100% Zero-Harmony console/Switch rumble mirror!)
        private static bool _rumbleFieldsResolved;
        private static FieldInfo _fRumbleIsRumbling;
        private static FieldInfo _fRumbleStrength;
        private static FieldInfo _fRumbleTimerCurrent;
        private static FieldInfo _fRumbleTimerMax;
        private static FieldInfo _fRumbleFade;
        private static FieldInfo _fRumbleDuringFade;

        private readonly IMonitor _monitor;
        private readonly IntPtr _snapBuf;
        private PollInputDelegate _nativePoll;
        private SetMouseNormDelegate _nativeSetMouseNorm;
        private GetDirectTouchCountDelegate _nativeDirectTouches;
        private SetRumbleDelegate _nativeSetRumble;
        private float _lastSentRumbleL;
        private float _lastSentRumbleR;
        private bool _ensuredDefaultRumbleOnce;
        private bool _nativeResolved;
        private bool _nativeAvailable;
        private bool _abiMismatchLogged;

        private int _lastPollTick = -1;
        private long _lastPollMs;

        private uint _lastGpSeq;
        private uint _lastKbSeq;
        private uint _lastMouseSeq;
        private bool _seqInitialized;

        private bool _nativeSuppressed;
        private bool _managedSuppressed;
        private bool _wasSuppressed;
        private bool _gpConnected;
        private bool _kbConnected;
        private bool _mouseConnected;
        private bool _mouseEverUsed;
        private int _scrollWheelValue;
        private int _gamepadCursorX = 640;
        private int _gamepadCursorY = 360;
        private float _gamepadCursorXf = 640f;
        private float _gamepadCursorYf = 360f;
        private bool _gamepadCursorInit;
        private long _lastRightStickStepMs;

        public bool PureGamepadMode { get; private set; }
        public bool IsRightStickSteeringGameplayCursor { get; private set; }
        public bool IsRightStickMenuCursorActive { get; private set; }
        public bool SuppressGamepadAButtonThisFrame { get; private set; }
        public bool SuppressGamepadXButtonThisFrame { get; private set; }
        public bool SuppressGamepadShoulderThisFrame { get; private set; }
        public bool SuppressGamepadTriggerThisFrame { get; private set; }

        private bool _prevGamepadAButtonDown;
        private bool _prevGamepadXButtonDown;
        private bool _prevGamepadR3ButtonDown;
        private bool _prevGamepadLBDown;
        private bool _prevGamepadRBDown;
        private bool _prevGamepadLTDown;
        private bool _prevGamepadRTDown;
        private int _menuSyntheticLeftClickFrames;
        private int _menuSyntheticRightClickFrames;
        private bool _rStickModHoldLeftDown;
        private bool _rStickModHoldRightDown;

        // Auto-snap & Hold-A Drag-and-Drop tracking across menus
        private WeakReference<IClickableMenu> _lastSnappedMenuRef;
        private int _lastGameMenuTab = -1;
        private bool _gpDragTracking;
        private bool _gpDragMoved;
        private Point _gpDragStartUi;
        private int _gpDragStartSnapId = int.MinValue;

        private static readonly List<Keys> EmptyKeysList = new List<Keys>(0);
        private static readonly object[] EmptyKeysArg = new object[] { EmptyKeysList };
        private readonly List<Keys> _physicalKeys = new List<Keys>(32);
        private readonly object[] _kbSetKeysArg = new object[1];
        private readonly HashSet<Keys> _prevSpecialKeys = new HashSet<Keys>();
        private readonly HashSet<Keys> _currSpecialKeys = new HashSet<Keys>();
        private readonly List<Keys> _mergeScratch = new List<Keys>(48);
        private bool _syncedEmptyMonoGameKeys = true;

        public ExternalInputMode ActiveMode { get; private set; } = ExternalInputMode.Touch;
        public GamePadState CurrentGamePadState { get; private set; }
        public MouseState CurrentMouseState { get; private set; }
        public bool IsSuppressed => _nativeSuppressed || _managedSuppressed;
        public bool IsGamepadConnected => _gpConnected;
        public bool IsKeyboardConnected => _kbConnected;
        public bool IsMouseConnected => _mouseConnected;
        public bool IsPhysicalGamepadActive =>
            !IsSuppressed &&
            ((ActiveMode == ExternalInputMode.Gamepad && _gpConnected) ||
             (PureGamepadMode && ActiveMode != ExternalInputMode.KeyboardMouse));
        public bool IsExternalMouseActive => ActiveMode == ExternalInputMode.KeyboardMouse && _mouseConnected && _mouseEverUsed && !IsSuppressed;
        public bool IsExternalDeviceActive => (PureGamepadMode || ActiveMode != ExternalInputMode.Touch) && !IsSuppressed;
        public bool ShouldOverrideMouse => IsExternalMouseActive || IsPhysicalGamepadActive;

        // Only push/overwrite Game1.input._currentMouseState & Mouse.PrimaryWindow when external mouse is active,
        // during free gameplay (no menu), or while actively steering/clicking the R-stick cursor inside a menu.
        // Otherwise inside menus, let Stardew's native SnappyMenus + Game1.setMousePositionRaw() own the cursor!
        public bool ShouldPushMouseStateNow =>
            IsExternalMouseActive ||
            (IsPhysicalGamepadActive && (
                Game1.activeClickableMenu == null ||
                IsRightStickMenuCursorActive ||
                _menuSyntheticLeftClickFrames > 0 ||
                _menuSyntheticRightClickFrames > 0 ||
                _rStickModHoldLeftDown ||
                _rStickModHoldRightDown));

        public bool HasPhysicalKeysPressed => !IsSuppressed && _physicalKeys.Count > 0;
        public IReadOnlyList<Keys> PhysicalKeys => _physicalKeys;

        public event Action<ExternalInputMode> ModeChanged;

        public ExternalInputBridge(IMonitor monitor, bool pureGamepadMode = false)
        {
            _monitor = monitor;
            PureGamepadMode = pureGamepadMode;
            if (pureGamepadMode)
                ActiveMode = ExternalInputMode.Gamepad;
            _snapBuf = Marshal.AllocHGlobal(256);
            ResolveNativeExports();
        }

        public void SyncPureGamepadConfig(bool enabled)
        {
            if (PureGamepadMode == enabled)
                return;
            PureGamepadMode = enabled;
            if (enabled && ActiveMode == ExternalInputMode.Touch)
                SetActiveMode(ExternalInputMode.Gamepad);
            else if (!enabled && ActiveMode == ExternalInputMode.Gamepad && !_gpConnected)
                SetActiveMode(ExternalInputMode.Touch);
        }

        private static bool IsBlockingNonPlayableEvent()
        {
            if (!Game1.eventUp)
                return false;
            try
            {
                Event ev = Game1.CurrentEvent;
                return ev == null || !ev.playerControlSequence;
            }
            catch
            {
                return true;
            }
        }

        private void ResolveNativeExports()
        {
            if (_nativeResolved) return;
            _nativeResolved = true;
            try
            {
                IntPtr pPoll = IntPtr.Zero;
                IntPtr pSetMouse = IntPtr.Zero;
                IntPtr pDirectTouch = IntPtr.Zero;
                IntPtr pSetRumble = IntPtr.Zero;

                string[] libNames =
                {
                    "@rpath/SDVModGarden.framework/SDVModGarden",
                    "SDVModGarden.framework/SDVModGarden"
                };

                foreach (string lib in libNames)
                {
                    if (NativeLibrary.TryLoad(lib, out IntPtr h) && h != IntPtr.Zero)
                    {
                        NativeLibrary.TryGetExport(h, "sdv_ext_poll_input", out pPoll);
                        NativeLibrary.TryGetExport(h, "sdv_ext_set_mouse_norm", out pSetMouse);
                        NativeLibrary.TryGetExport(h, "sdv_ext_get_direct_touch_count", out pDirectTouch);
                        NativeLibrary.TryGetExport(h, "sdv_ext_set_rumble", out pSetRumble);
                        if (pPoll != IntPtr.Zero) break;
                    }
                }

                if (pPoll == IntPtr.Zero)
                {
                    try
                    {
                        pPoll = DarwinDlsym(RTLD_DEFAULT, "sdv_ext_poll_input");
                        pSetMouse = DarwinDlsym(RTLD_DEFAULT, "sdv_ext_set_mouse_norm");
                        pDirectTouch = DarwinDlsym(RTLD_DEFAULT, "sdv_ext_get_direct_touch_count");
                        pSetRumble = DarwinDlsym(RTLD_DEFAULT, "sdv_ext_set_rumble");
                    }
                    catch { }
                }
                else if (pSetRumble == IntPtr.Zero)
                {
                    try { pSetRumble = DarwinDlsym(RTLD_DEFAULT, "sdv_ext_set_rumble"); } catch { }
                }

                if (pPoll != IntPtr.Zero)
                {
                    _nativePoll = Marshal.GetDelegateForFunctionPointer<PollInputDelegate>(pPoll);
                    if (pSetMouse != IntPtr.Zero)
                        _nativeSetMouseNorm = Marshal.GetDelegateForFunctionPointer<SetMouseNormDelegate>(pSetMouse);
                    if (pDirectTouch != IntPtr.Zero)
                        _nativeDirectTouches = Marshal.GetDelegateForFunctionPointer<GetDirectTouchCountDelegate>(pDirectTouch);
                    if (pSetRumble != IntPtr.Zero)
                        _nativeSetRumble = Marshal.GetDelegateForFunctionPointer<SetRumbleDelegate>(pSetRumble);
                    _nativeAvailable = true;
                    _monitor?.Log($"[ExternalInput] Bound native iOS GameController bridge (Gamepad + Keyboard + Mouse + CoreHapticsRumble={_nativeSetRumble != null}, PureGamepad={PureGamepadMode}).", LogLevel.Info);
                }
                else
                {
                    _monitor?.Log("[ExternalInput] Native bridge export not found; falling back to MonoGame GamePad only.", LogLevel.Warn);
                }
            }
            catch (Exception ex)
            {
                _monitor?.Log($"[ExternalInput] Native bridge init fallback: {ex.Message}", LogLevel.Warn);
            }
        }

        private static float ReadFloat(IntPtr ptr, int offset)
        {
            return BitConverter.Int32BitsToSingle(Marshal.ReadInt32(ptr, offset));
        }

        private static void GetBackBufferSize(out int bw, out int bh)
        {
            bw = 1280;
            bh = 720;
            try
            {
                var gd = Game1.graphics?.GraphicsDevice;
                if (gd != null)
                {
                    var pp = gd.PresentationParameters;
                    if (pp != null && pp.BackBufferWidth > 100 && pp.BackBufferHeight > 100)
                    {
                        bw = pp.BackBufferWidth;
                        bh = pp.BackBufferHeight;
                        return;
                    }
                    if (gd.Viewport.Width > 100 && gd.Viewport.Height > 100)
                    {
                        bw = gd.Viewport.Width;
                        bh = gd.Viewport.Height;
                        return;
                    }
                }
            }
            catch { }
        }

        public void SetManagedSuppressed(bool suppressed)
        {
            if (_managedSuppressed == suppressed) return;
            bool prev = IsSuppressed;
            _managedSuppressed = suppressed;
            bool cur = IsSuppressed;
            _wasSuppressed = cur;
            if (cur != prev)
                OnSuppressionTransition(prev, cur);
        }

        private void OnSuppressionTransition(bool wasSuppressed, bool nowSuppressed)
        {
            if (nowSuppressed)
                PushRumbleToNative(0f, 0f);
            CurrentGamePadState = default;
            _physicalKeys.Clear();
            _prevSpecialKeys.Clear();
            _gpDragTracking = false;
            _gpDragMoved = false;
            _rStickModHoldLeftDown = false;
            _rStickModHoldRightDown = false;
            SyncMonoGameKeyboardKeys(forceClear: true);

            if (!nowSuppressed)
            {
                _seqInitialized = false;
            }

            ApplyStardewGamepadMode();
            FlushFarmerMovementAndState(restoreAutoRun: !nowSuppressed);
        }

        public void FlushFarmerMovementAndState(bool restoreAutoRun = true)
        {
            try { Game1.oldPadState = default; } catch { }
            try
            {
                Farmer who = Game1.player;
                if (who != null && !IsBlockingNonPlayableEvent() && who.controller == null &&
                    !who.UsingTool && !who.isEating && !who.IsSitting())
                {
                    if (who.movementDirections != null && who.movementDirections.Count > 0)
                        who.movementDirections.Clear();
                    who.Halt();
                    if (restoreAutoRun && Game1.options != null &&
                        !who.canOnlyWalk && !who.bathingClothes.Value &&
                        who.stamina > 0f && !who.isRidingHorse())
                    {
                        bool wantRun = Game1.options.autoRun;
                        if (who.running != wantRun)
                            who.setRunning(wantRun, force: false);
                    }
                }
            }
            catch { }
        }

        public KeyboardState BuildPhysicalKeyboardState()
        {
            if (!HasPhysicalKeysPressed)
                return default;
            return new KeyboardState(_physicalKeys.ToArray());
        }

        public void NotifyDirectTouch(int directTouchCount)
        {
            // In Pure Gamepad Mode (or while Mod Garden / Edit Layout / Save Menu is open),
            // NEVER allow accidental screen touches to switch ActiveMode back to Touch!
            if (IsSuppressed || PureGamepadMode) return;
            if (directTouchCount > 0 && ActiveMode != ExternalInputMode.Touch)
            {
                SetActiveMode(ExternalInputMode.Touch);
            }
        }

        private void SetActiveMode(ExternalInputMode next)
        {
            if (PureGamepadMode && next == ExternalInputMode.Touch)
                next = ExternalInputMode.Gamepad;
            if (ActiveMode == next) return;
            ExternalInputMode prev = ActiveMode;
            ActiveMode = next;

            if (next == ExternalInputMode.Gamepad)
            {
                GetBackBufferSize(out int bw, out int bh);
                EnsureValidLocalMultiplayerWindow(bw, bh);
                if (!_gamepadCursorInit || (_gamepadCursorX == 0 && _gamepadCursorY == 0))
                {
                    _gamepadCursorX = bw / 2;
                    _gamepadCursorY = bh / 2;
                    _gamepadCursorXf = _gamepadCursorX;
                    _gamepadCursorYf = _gamepadCursorY;
                    _gamepadCursorInit = true;
                }
            }
            if (next != ExternalInputMode.Gamepad)
            {
                IsRightStickSteeringGameplayCursor = false;
                IsRightStickMenuCursorActive = false;
                SuppressGamepadAButtonThisFrame = false;
                SuppressGamepadXButtonThisFrame = false;
                SuppressGamepadShoulderThisFrame = false;
                SuppressGamepadTriggerThisFrame = false;
                _menuSyntheticLeftClickFrames = 0;
                _menuSyntheticRightClickFrames = 0;
                _rStickModHoldLeftDown = false;
                _rStickModHoldRightDown = false;
                _gpDragTracking = false;
                _gpDragMoved = false;
                _lastRightStickStepMs = 0;
                PushRumbleToNative(0f, 0f);
            }

            if (next == ExternalInputMode.Gamepad || prev == ExternalInputMode.Gamepad)
            {
                if (_physicalKeys.Count == 0)
                    SyncMonoGameKeyboardKeys(forceClear: true);
            }

            ApplyStardewGamepadMode();

            if (prev == ExternalInputMode.Gamepad)
            {
                FlushFarmerMovementAndState(restoreAutoRun: true);
            }
            else if (next == ExternalInputMode.Gamepad)
            {
                try { Game1.oldPadState = default; } catch { }
                try
                {
                    Farmer who = Game1.player;
                    if (who != null && Game1.options != null && !IsBlockingNonPlayableEvent() &&
                        who.controller == null && !who.UsingTool && !who.isEating &&
                        !who.IsSitting() && !who.canOnlyWalk && !who.bathingClothes.Value &&
                        who.stamina > 0f && !who.isRidingHorse())
                    {
                        bool wantRun = Game1.options.autoRun;
                        if (who.running != wantRun)
                            who.setRunning(wantRun, force: false);
                    }
                }
                catch { }
            }

            try { ModeChanged?.Invoke(next); } catch { }
        }

        public void ApplyStardewGamepadMode()
        {
            try
            {
                if (Game1.options == null) return;
                if (IsPhysicalGamepadActive)
                {
                    if (Game1.options.gamepadMode != Options.GamepadModes.ForceOn)
                        Game1.options.gamepadMode = Options.GamepadModes.ForceOn;
                    if (!Game1.options.gamepadControls)
                        Game1.options.gamepadControls = true;
                    if (!_ensuredDefaultRumbleOnce)
                    {
                        _ensuredDefaultRumbleOnce = true;
                        Game1.options.rumble = true;
                    }
                    // CRITICAL for StardewValley.Rumble.update(): if playerOneIndex < 0, Rumble returns early!
                    if ((int)Game1.playerOneIndex < 0)
                        Game1.playerOneIndex = PlayerIndex.One;
                }
                else
                {
                    if (Game1.options.gamepadMode != Options.GamepadModes.ForceOff)
                        Game1.options.gamepadMode = Options.GamepadModes.ForceOff;
                    if (Game1.options.gamepadControls)
                        Game1.options.gamepadControls = false;
                }
            }
            catch { }
        }

        public void EnsureValidLocalMultiplayerWindow()
        {
            GetBackBufferSize(out int bw, out int bh);
            EnsureValidLocalMultiplayerWindow(bw, bh);
        }

        private static void EnsureValidLocalMultiplayerWindow(int bw, int bh)
        {
            try
            {
                var g = Game1.game1;
                if (g != null && bw > 100 && bh > 100 &&
                    (g.localMultiplayerWindow.Width <= 100 || g.localMultiplayerWindow.Height <= 100))
                {
                    g.localMultiplayerWindow = new Rectangle(0, 0, bw, bh);
                }
            }
            catch { }
        }

        public static GamePadState StripRightStick(GamePadState gs)
        {
            return new GamePadState(
                new GamePadThumbSticks(gs.ThumbSticks.Left, Vector2.Zero),
                gs.Triggers,
                gs.Buttons,
                gs.DPad);
        }

        public GamePadState GetEffectiveGamePadStateForGame()
        {
            GamePadState gs = CurrentGamePadState;
            bool stripR = IsRightStickSteeringGameplayCursor || IsRightStickMenuCursorActive;
            bool stripA = SuppressGamepadAButtonThisFrame;
            bool stripX = SuppressGamepadXButtonThisFrame;
            bool stripSh = SuppressGamepadShoulderThisFrame;
            bool stripTr = SuppressGamepadTriggerThisFrame;
            if (!stripR && !stripA && !stripX && !stripSh && !stripTr)
                return gs;

            Buttons mask = 0;
            if (!stripA && gs.Buttons.A == ButtonState.Pressed) mask |= Buttons.A;
            if (gs.Buttons.B == ButtonState.Pressed) mask |= Buttons.B;
            if (!stripX && gs.Buttons.X == ButtonState.Pressed) mask |= Buttons.X;
            if (gs.Buttons.Y == ButtonState.Pressed) mask |= Buttons.Y;
            if (!stripSh && gs.Buttons.LeftShoulder == ButtonState.Pressed) mask |= Buttons.LeftShoulder;
            if (!stripSh && gs.Buttons.RightShoulder == ButtonState.Pressed) mask |= Buttons.RightShoulder;
            if (gs.Buttons.Start == ButtonState.Pressed) mask |= Buttons.Start;
            if (gs.Buttons.Back == ButtonState.Pressed) mask |= Buttons.Back;
            if (gs.Buttons.BigButton == ButtonState.Pressed) mask |= Buttons.BigButton;
            if (gs.Buttons.LeftStick == ButtonState.Pressed) mask |= Buttons.LeftStick;
            if (gs.Buttons.RightStick == ButtonState.Pressed) mask |= Buttons.RightStick;
            if (gs.DPad.Up == ButtonState.Pressed) mask |= Buttons.DPadUp;
            if (gs.DPad.Down == ButtonState.Pressed) mask |= Buttons.DPadDown;
            if (gs.DPad.Left == ButtonState.Pressed) mask |= Buttons.DPadLeft;
            if (gs.DPad.Right == ButtonState.Pressed) mask |= Buttons.DPadRight;

            float lt = stripTr ? 0f : gs.Triggers.Left;
            float rt = stripTr ? 0f : gs.Triggers.Right;
            if (lt > 0.35f) mask |= Buttons.LeftTrigger;
            if (rt > 0.35f) mask |= Buttons.RightTrigger;

            Vector2 ls = gs.ThumbSticks.Left;
            if (ls.Y > 0.5f) mask |= Buttons.LeftThumbstickUp;
            else if (ls.Y < -0.5f) mask |= Buttons.LeftThumbstickDown;
            if (ls.X < -0.5f) mask |= Buttons.LeftThumbstickLeft;
            else if (ls.X > 0.5f) mask |= Buttons.LeftThumbstickRight;

            Vector2 rs = stripR ? Vector2.Zero : gs.ThumbSticks.Right;
            if (rs.Y > 0.5f) mask |= Buttons.RightThumbstickUp;
            else if (rs.Y < -0.5f) mask |= Buttons.RightThumbstickDown;
            if (rs.X < -0.5f) mask |= Buttons.RightThumbstickLeft;
            else if (rs.X > 0.5f) mask |= Buttons.RightThumbstickRight;

            return new GamePadState(
                new GamePadThumbSticks(ls, rs),
                new GamePadTriggers(lt, rt),
                new GamePadButtons(mask),
                gs.DPad);
        }

        public static bool IsPointOnVanillaInventoryControl(GameMenu gm, Point ui)
        {
            if (gm == null) return false;
            try
            {
                if (gm.upperRightCloseButton != null && gm.upperRightCloseButton.containsPoint(ui.X, ui.Y))
                    return true;
                if (gm.tabs != null)
                {
                    for (int i = 0; i < gm.tabs.Count; i++)
                    {
                        var t = gm.tabs[i];
                        if (t != null && t.containsPoint(ui.X, ui.Y))
                            return true;
                    }
                }
                if (gm.GetCurrentPage() is InventoryPage inv)
                {
                    if (inv.inventory?.inventory != null)
                    {
                        for (int i = 0; i < inv.inventory.inventory.Count; i++)
                        {
                            var cc = inv.inventory.inventory[i];
                            if (cc != null && cc.containsPoint(ui.X, ui.Y))
                                return true;
                        }
                    }
                    if (inv.equipmentIcons != null)
                    {
                        for (int i = 0; i < inv.equipmentIcons.Count; i++)
                        {
                            var eq = inv.equipmentIcons[i];
                            if (eq != null && eq.containsPoint(ui.X, ui.Y))
                                return true;
                        }
                    }
                    if (inv.organizeButton != null && inv.organizeButton.containsPoint(ui.X, ui.Y)) return true;
                    if (inv.trashCan != null && inv.trashCan.containsPoint(ui.X, ui.Y)) return true;
                    if (inv.junimoNoteIcon != null && inv.junimoNoteIcon.containsPoint(ui.X, ui.Y)) return true;
                }
            }
            catch { }
            return false;
        }

        private static Point RawToUiPoint(int rawX, int rawY, int bw, int bh)
        {
            int uiW = Game1.uiViewport.Width;
            int uiH = Game1.uiViewport.Height;
            if (uiW <= 0 || uiH <= 0 || bw <= 0 || bh <= 0)
                return new Point(rawX, rawY);
            return new Point((int)((long)rawX * uiW / bw), (int)((long)rawY * uiH / bh));
        }

        private bool TryReadLiveGameMousePosition(int bw, int bh, out int lx, out int ly)
        {
            lx = 0;
            ly = 0;
            try
            {
                if (Game1.input != null)
                {
                    if (InputCurrentMouseField != null &&
                        InputCurrentMouseField.GetValue(Game1.input) is MouseState baseMs &&
                        baseMs.X >= 0 && baseMs.X < bw && baseMs.Y >= 0 && baseMs.Y < bh && (baseMs.X != 0 || baseMs.Y != 0))
                    {
                        lx = baseMs.X;
                        ly = baseMs.Y;
                        return true;
                    }
                    MouseState liveMs = Game1.input.GetMouseState();
                    if (liveMs.X >= 0 && liveMs.X < bw && liveMs.Y >= 0 && liveMs.Y < bh && (liveMs.X != 0 || liveMs.Y != 0))
                    {
                        lx = liveMs.X;
                        ly = liveMs.Y;
                        return true;
                    }
                }
            }
            catch { }
            return false;
        }

        private static IClickableMenu ResolveTopMenuForSnap(IClickableMenu raw)
        {
            if (raw == null) return null;
            try
            {
                if (raw is TitleMenu && TitleMenu.subMenu != null)
                    raw = TitleMenu.subMenu;
                int guard = 0;
                while (raw.GetChildMenu() != null && guard++ < 8)
                    raw = raw.GetChildMenu();
                if (raw is GameMenu gm)
                {
                    IClickableMenu page = gm.GetCurrentPage();
                    if (page != null)
                        return page;
                }
            }
            catch { }
            return raw;
        }

        private static bool IsThirdPartyMenu(IClickableMenu menu)
        {
            if (menu == null) return false;
            try { return menu.GetType().Assembly != typeof(Game1).Assembly; }
            catch { return false; }
        }

        private static bool IsTextSubscriberActive()
        {
            try
            {
                var sub = Game1.keyboardDispatcher?.Subscriber;
                return sub != null && sub.Selected;
            }
            catch { return false; }
        }

        private static void SnapMenuToComponent(IClickableMenu menu, ClickableComponent target)
        {
            if (menu == null || target == null) return;
            try
            {
                menu.currentlySnappedComponent = target;
                menu.snapCursorToCurrentSnappedComponent();
                Game1.playSound("shiny4");
            }
            catch { }
        }

        private static Item GetHeldItemInMenu(IClickableMenu rawMenu)
        {
            if (rawMenu == null) return null;
            try
            {
                if (rawMenu is GameMenu gm)
                {
                    if (gm.GetCurrentPage() is InventoryPage)
                        return Game1.player?.CursorSlotItem;
                    if (gm.GetCurrentPage() is CraftingPage cp)
                    {
                        FieldInfo fHeld = typeof(CraftingPage).GetField("heldItem", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
                        return fHeld?.GetValue(cp) as Item;
                    }
                }
                if (rawMenu is MenuWithInventory mwi)
                    return mwi.heldItem;
            }
            catch { }
            return null;
        }

        private static bool SupportsHoldADrag(IClickableMenu rawMenu)
        {
            if (rawMenu == null) return false;
            if (rawMenu is GameMenu gm)
            {
                var p = gm.GetCurrentPage();
                return p is InventoryPage || p is CraftingPage;
            }
            return rawMenu is ItemGrabMenu || rawMenu is ForgeMenu || rawMenu is TailoringMenu || rawMenu is JunimoNoteMenu;
        }

        private static bool IsPointOutsideMenuFrame(IClickableMenu menu, Point ui)
        {
            if (menu == null) return false;
            if (menu is GameMenu gm)
            {
                for (int i = 0; i < (gm.tabs?.Count ?? 0); i++)
                {
                    if (gm.tabs[i] != null && gm.tabs[i].containsPoint(ui.X, ui.Y))
                        return false;
                }
                if (gm.upperRightCloseButton != null && gm.upperRightCloseButton.containsPoint(ui.X, ui.Y))
                    return false;
            }
            return ui.X < menu.xPositionOnScreen - 24 ||
                   ui.X > menu.xPositionOnScreen + menu.width + 24 ||
                   ui.Y < menu.yPositionOnScreen - 24 ||
                   ui.Y > menu.yPositionOnScreen + menu.height + 24;
        }

        private static bool TryDropHeldItemFromMenu(IClickableMenu rawMenu, bool singleItemOnly)
        {
            if (rawMenu == null || Game1.player == null)
                return false;
            try
            {
                if (rawMenu is GameMenu gm && gm.GetCurrentPage() is InventoryPage)
                {
                    Item cur = Game1.player.CursorSlotItem;
                    if (cur == null || !cur.canBeDropped())
                        return false;
                    Item toDrop;
                    if (singleItemOnly && cur.Stack > 1)
                    {
                        toDrop = cur.getOne();
                        cur.Stack -= 1;
                    }
                    else
                    {
                        toDrop = cur;
                        Game1.player.CursorSlotItem = null;
                    }
                    Game1.createItemDebris(toDrop, Game1.player.getStandingPosition(), Game1.player.FacingDirection);
                    Game1.playSound("throwDownITem");
                    return true;
                }
                if (rawMenu is MenuWithInventory mwi && mwi.heldItem != null && mwi.heldItem.canBeDropped())
                {
                    if (singleItemOnly && mwi.heldItem.Stack > 1)
                    {
                        Item one = mwi.heldItem.getOne();
                        mwi.heldItem.Stack -= 1;
                        int dropDir = (rawMenu is ItemGrabMenu igmMus && igmMus.context is StardewValley.Locations.LibraryMuseum)
                            ? 2
                            : Game1.player.FacingDirection;
                        Game1.createItemDebris(one, Game1.player.getStandingPosition(), dropDir);
                        Game1.playSound("throwDownITem");
                    }
                    else
                    {
                        // Note: MenuWithInventory.DropHeldItem() already plays "throwDownITem" internally!
                        mwi.DropHeldItem();
                    }
                    return true;
                }
            }
            catch { }
            return false;
        }

        private void HandleMenuFrameSwitching(IClickableMenu rawMenu, bool lbEdge, bool rbEdge, bool ltEdge, bool rtEdge)
        {
            if (rawMenu == null || IsTextSubscriberActive())
                return;
            if (!lbEdge && !rbEdge && !ltEdge && !rtEdge)
                return;

            try
            {
                // 1. GameMenu: LB/RB switches top tabs when readyToClose(), OR cycles Backpack <-> Equipment <-> Side buttons when holding an item!
                if (rawMenu is GameMenu gm && gm.GetChildMenu() == null)
                {
                    IClickableMenu curPage = gm.GetCurrentPage();
                    int dir = (rbEdge || rtEdge) ? 1 : -1;

                    if ((lbEdge || rbEdge) && curPage != null && curPage.readyToClose())
                    {
                        SuppressGamepadShoulderThisFrame = true;
                        IsRightStickMenuCursorActive = false;
                        int tabsMax = (gm.tabs != null && gm.tabs.Count > 0) ? (gm.tabs.Count - 1) : -1;
                        int maxTab = (gm.pages != null && gm.pages.Count > 0 && tabsMax >= 0)
                            ? Math.Min(GameMenu.numberOfTabs, Math.Min(gm.pages.Count - 1, tabsMax))
                            : -1;
                        if (maxTab < 0)
                            return;
                        if (gm.currentTab == GameMenu.mapTab)
                        {
                            int nextFromMap = dir > 0 ? (GameMenu.mapTab + 1) : (GameMenu.mapTab - 1);
                            if (nextFromMap >= 0 && nextFromMap <= maxTab)
                            {
                                Game1.activeClickableMenu = new GameMenu(nextFromMap, -1, playOpeningSound: false);
                                Game1.playSound("smallSelect");
                            }
                            return;
                        }
                        int targetTab = gm.currentTab + dir;
                        if (targetTab >= 0 && targetTab <= maxTab)
                        {
                            gm.changeTab(targetTab, playSound: true);
                        }
                        return;
                    }

                    // Inside InventoryPage while holding an item on cursor (tabs locked): cycle Backpack <-> Equipment <-> Trash/Organize!
                    if (curPage is InventoryPage inv && Game1.player?.CursorSlotItem != null)
                    {
                        if (lbEdge || rbEdge) SuppressGamepadShoulderThisFrame = true;
                        if (ltEdge || rtEdge) SuppressGamepadTriggerThisFrame = true;
                        IsRightStickMenuCursorActive = false;

                        ClickableComponent curSnap = inv.currentlySnappedComponent;
                        int section = 0; // 0=Backpack, 1=Equipment, 2=Organize/Trash
                        if (curSnap != null)
                        {
                            if (inv.equipmentIcons != null && inv.equipmentIcons.Contains(curSnap))
                                section = 1;
                            else if (curSnap == inv.organizeButton || curSnap == inv.trashCan || curSnap == inv.junimoNoteIcon)
                                section = 2;
                        }
                        int nextSec = (section + dir + 3) % 3;
                        ClickableComponent dst = null;
                        if (nextSec == 0 && inv.inventory?.inventory != null && inv.inventory.inventory.Count > 0)
                            dst = inv.inventory.inventory[0];
                        else if (nextSec == 1 && inv.equipmentIcons != null && inv.equipmentIcons.Count > 0)
                            dst = inv.equipmentIcons[0];
                        else
                            dst = (ClickableComponent)inv.trashCan ?? inv.organizeButton ?? (inv.inventory?.inventory?.Count > 0 ? inv.inventory.inventory[0] : null);
                        SnapMenuToComponent(inv, dst);
                        return;
                    }
                }

                // 2. ItemGrabMenu (Chest / Fridge / Junimo Chest):
                //    - LT / RT toggles directly between Chest slots <-> Player Backpack slots (preserving column!)
                //    - LB / RB cycles cleanly between Chest <-> Backpack <-> Side Buttons (Fill Stacks / Organize / Color / Trash)
                if (rawMenu is ItemGrabMenu igm && igm.GetChildMenu() == null && !igm.shippingBin && igm.ItemsToGrabMenu?.inventory != null && igm.inventory?.inventory != null)
                {
                    var chestSlots = igm.ItemsToGrabMenu.inventory;
                    var bagSlots = igm.inventory.inventory;
                    if (chestSlots.Count > 0 && bagSlots.Count > 0)
                    {
                        ClickableComponent cur = igm.currentlySnappedComponent;
                        int curFrame = 0; // 0=Chest, 1=Backpack, 2=SideButtons
                        int curCol = 0;
                        if (cur != null)
                        {
                            int cIdx = chestSlots.IndexOf(cur);
                            int bIdx = bagSlots.IndexOf(cur);
                            if (cIdx >= 0) { curFrame = 0; curCol = cIdx % 12; }
                            else if (bIdx >= 0) { curFrame = 1; curCol = bIdx % 12; }
                            else curFrame = 2;
                        }

                        if (ltEdge || rtEdge)
                        {
                            SuppressGamepadTriggerThisFrame = true;
                            IsRightStickMenuCursorActive = false;
                            var targetList = (curFrame == 0) ? bagSlots : chestSlots;
                            int dstIdx = Math.Clamp(curCol, 0, targetList.Count - 1);
                            SnapMenuToComponent(igm, targetList[dstIdx]);
                            return;
                        }

                        if (lbEdge || rbEdge)
                        {
                            SuppressGamepadShoulderThisFrame = true;
                            IsRightStickMenuCursorActive = false;
                            ClickableComponent sideBtn = (ClickableComponent)igm.fillStacksButton
                                ?? igm.organizeButton
                                ?? igm.colorPickerToggleButton
                                ?? igm.trashCan;
                            int frameCount = sideBtn != null ? 3 : 2;
                            int dir = rbEdge ? 1 : -1;
                            int nextFrame = (curFrame + dir + frameCount) % frameCount;
                            ClickableComponent dst = nextFrame == 0
                                ? chestSlots[Math.Clamp(curCol, 0, chestSlots.Count - 1)]
                                : nextFrame == 1
                                    ? bagSlots[Math.Clamp(curCol, 0, bagSlots.Count - 1)]
                                    : sideBtn;
                            SnapMenuToComponent(igm, dst);
                            return;
                        }
                    }
                }

                // 3. ShopMenu: LB/RB or LT/RT toggles cleanly between Shop Goods list <-> Player Inventory!
                if (rawMenu is ShopMenu sm && sm.GetChildMenu() == null && sm.forSaleButtons != null && sm.forSaleButtons.Count > 0 && sm.inventory?.inventory != null && sm.inventory.inventory.Count > 0)
                {
                    if (lbEdge || rbEdge) SuppressGamepadShoulderThisFrame = true;
                    if (ltEdge || rtEdge) SuppressGamepadTriggerThisFrame = true;
                    IsRightStickMenuCursorActive = false;

                    ClickableComponent cur = sm.currentlySnappedComponent;
                    bool inBag = cur != null && sm.inventory.inventory.Contains(cur);
                    ClickableComponent dst = inBag ? (ClickableComponent)sm.forSaleButtons[0] : sm.inventory.inventory[0];
                    SnapMenuToComponent(sm, dst);
                }
            }
            catch { }
        }

        private void StepGamepadRightStickCursor(float rx, float ry, int bw, int bh)
        {
            EnsureValidLocalMultiplayerWindow(bw, bh);
            if (!_gamepadCursorInit)
            {
                _gamepadCursorX = bw / 2;
                _gamepadCursorY = bh / 2;
                _gamepadCursorXf = _gamepadCursorX;
                _gamepadCursorYf = _gamepadCursorY;
                _gamepadCursorInit = true;
            }

            SuppressGamepadAButtonThisFrame = false;
            SuppressGamepadXButtonThisFrame = false;
            SuppressGamepadShoulderThisFrame = false;
            SuppressGamepadTriggerThisFrame = false;

            IClickableMenu rawMenu = Game1.activeClickableMenu;
            bool inMenu = rawMenu != null;
            bool isFishingBar = rawMenu is BobberBar;
            IClickableMenu snapTargetMenu = ResolveTopMenuForSnap(rawMenu);
            bool isThirdPartyMenu = IsThirdPartyMenu(snapTargetMenu);

            if (!inMenu || isFishingBar)
            {
                IsRightStickMenuCursorActive = false;
                _menuSyntheticLeftClickFrames = 0;
                _menuSyntheticRightClickFrames = 0;
                _rStickModHoldLeftDown = false;
                _rStickModHoldRightDown = false;
                _gpDragTracking = false;
                _gpDragMoved = false;
                _lastSnappedMenuRef = null;
                _lastGameMenuTab = -1;
            }
            else
            {
                // Auto-snap newly opened menus / switched GameMenu tabs so SnappyMenus cursor is immediately ready!
                int curGmTab = (rawMenu is GameMenu gmChk) ? gmChk.currentTab : -1;
                IClickableMenu prevMenu = null;
                _lastSnappedMenuRef?.TryGetTarget(out prevMenu);
                if (!ReferenceEquals(prevMenu, snapTargetMenu) || curGmTab != _lastGameMenuTab)
                {
                    _lastSnappedMenuRef = new WeakReference<IClickableMenu>(snapTargetMenu);
                    _lastGameMenuTab = curGmTab;
                    _gpDragTracking = false;
                    _gpDragMoved = false;
                    if (!IsRightStickMenuCursorActive && !isThirdPartyMenu && snapTargetMenu != null)
                    {
                        try
                        {
                            if (snapTargetMenu.allClickableComponents == null)
                                snapTargetMenu.populateClickableComponentList();
                            if (snapTargetMenu.currentlySnappedComponent == null)
                                snapTargetMenu.snapToDefaultClickableComponent();
                        }
                        catch { }
                    }
                }

                // If user navigates with Left Stick, D-Pad, bumpers, triggers, or B/Y/Start,
                // immediately hand cursor control right back to Stardew's native SnappyMenus!
                Vector2 ls = CurrentGamePadState.ThumbSticks.Left;
                var btns = CurrentGamePadState.Buttons;
                bool navUsed = (ls.X * ls.X + ls.Y * ls.Y > 0.09f) ||
                    CurrentGamePadState.DPad.Up == ButtonState.Pressed ||
                    CurrentGamePadState.DPad.Down == ButtonState.Pressed ||
                    CurrentGamePadState.DPad.Left == ButtonState.Pressed ||
                    CurrentGamePadState.DPad.Right == ButtonState.Pressed ||
                    btns.LeftShoulder == ButtonState.Pressed ||
                    btns.RightShoulder == ButtonState.Pressed ||
                    CurrentGamePadState.Triggers.Left > 0.35f ||
                    CurrentGamePadState.Triggers.Right > 0.35f ||
                    btns.B == ButtonState.Pressed ||
                    btns.Y == ButtonState.Pressed ||
                    btns.Start == ButtonState.Pressed;
                if (navUsed && !isThirdPartyMenu)
                {
                    IsRightStickMenuCursorActive = false;
                    _menuSyntheticLeftClickFrames = 0;
                    _menuSyntheticRightClickFrames = 0;
                    _rStickModHoldLeftDown = false;
                    _rStickModHoldRightDown = false;
                }
            }

            // Edge detection for A, X, R3, LB, RB, LT, RT
            bool aNow = CurrentGamePadState.Buttons.A == ButtonState.Pressed;
            bool xNow = CurrentGamePadState.Buttons.X == ButtonState.Pressed;
            bool r3Now = CurrentGamePadState.Buttons.RightStick == ButtonState.Pressed;
            bool lbNow = CurrentGamePadState.Buttons.LeftShoulder == ButtonState.Pressed;
            bool rbNow = CurrentGamePadState.Buttons.RightShoulder == ButtonState.Pressed;
            bool ltNow = CurrentGamePadState.Triggers.Left > 0.45f;
            bool rtNow = CurrentGamePadState.Triggers.Right > 0.45f;

            bool aRising = aNow && !_prevGamepadAButtonDown;
            bool aFalling = !aNow && _prevGamepadAButtonDown;
            bool xRising = xNow && !_prevGamepadXButtonDown;
            bool r3Rising = r3Now && !_prevGamepadR3ButtonDown;
            bool lbRising = lbNow && !_prevGamepadLBDown;
            bool rbRising = rbNow && !_prevGamepadRBDown;
            bool ltRising = ltNow && !_prevGamepadLTDown;
            bool rtRising = rtNow && !_prevGamepadRTDown;

            _prevGamepadAButtonDown = aNow;
            _prevGamepadXButtonDown = xNow;
            _prevGamepadR3ButtonDown = r3Now;
            _prevGamepadLBDown = lbNow;
            _prevGamepadRBDown = rbNow;
            _prevGamepadLTDown = ltNow;
            _prevGamepadRTDown = rtNow;

            // Frame & Tab switching (GameMenu LB/RB, ItemGrabMenu Chest <-> Backpack <-> Side Buttons, ShopMenu Goods <-> Bag)
            if (inMenu && !isFishingBar && (lbRising || rbRising || ltRising || rtRising))
            {
                HandleMenuFrameSwitching(rawMenu, lbRising, rbRising, ltRising, rtRising);
            }

            // Adopt Stardew's live snapped cursor from Game1.input._currentMouseState whenever SnappyMenus owns the menu
            if (inMenu && !IsRightStickMenuCursorActive && _menuSyntheticLeftClickFrames == 0 && _menuSyntheticRightClickFrames == 0 && !_rStickModHoldLeftDown && !_rStickModHoldRightDown)
            {
                if (TryReadLiveGameMousePosition(bw, bh, out int liveX, out int liveY))
                {
                    _gamepadCursorX = liveX;
                    _gamepadCursorY = liveY;
                    _gamepadCursorXf = liveX;
                    _gamepadCursorYf = liveY;
                }
            }

            // Universal smooth analog Right-Stick cursor in BOTH free gameplay AND ALL non-BobberBar/non-Museum menus!
            // (In MuseumMenu, SnappyMenus uses ThumbSticks.Right natively to pan the Museum camera to East/South tables!)
            bool isMuseumPanMenu = rawMenu is MuseumMenu;
            if (isMuseumPanMenu)
                IsRightStickMenuCursorActive = false;
            bool canFreeCursor = (!inMenu && Game1.currentMinigame == null && Game1.emoteMenu == null) || (inMenu && !isFishingBar && !isMuseumPanMenu);
            float magSq = rx * rx + ry * ry;
            float entryThresholdSq = (inMenu && !IsRightStickMenuCursorActive) ? 0.0625f : 0.0001f;
            if (canFreeCursor && magSq > entryThresholdSq)
            {
                long nowMs = Environment.TickCount64;
                float dt = (_lastRightStickStepMs > 0) ? (nowMs - _lastRightStickStepMs) / 1000f : (1f / 60f);
                if (dt > 0.06f) dt = 1f / 60f;
                dt = Math.Clamp(dt, 0.004f, 0.05f);
                _lastRightStickStepMs = nowMs;

                if (Game1.timerUntilMouseFade <= 0 && _gamepadCursorX == 0 && _gamepadCursorY == 0)
                {
                    _gamepadCursorXf = bw * 0.5f;
                    _gamepadCursorYf = bh * 0.5f;
                }

                float mag = MathF.Sqrt(magSq);
                float clampedMag = Math.Min(1f, mag);
                float dx = rx / mag;
                float dy = ry / mag;
                float curved = 0.35f * clampedMag + 0.65f * clampedMag * clampedMag;
                float speedPxPerSec = Math.Max(680f, bh * 1.15f);

                _gamepadCursorXf = Math.Clamp(_gamepadCursorXf + dx * curved * speedPxPerSec * dt, 0f, Math.Max(0, bw - 1));
                _gamepadCursorYf = Math.Clamp(_gamepadCursorYf - dy * curved * speedPxPerSec * dt, 0f, Math.Max(0, bh - 1));
                _gamepadCursorX = (int)Math.Round(_gamepadCursorXf);
                _gamepadCursorY = (int)Math.Round(_gamepadCursorYf);
                IsRightStickSteeringGameplayCursor = !inMenu;
                if (inMenu)
                    IsRightStickMenuCursorActive = true;

                try
                {
                    Game1.timerUntilMouseFade = 4000;
                    Game1.mouseCursorTransparency = 1f;
                    Game1.wasMouseVisibleThisFrame = true;
                    Game1.lastCursorMotionWasMouse = inMenu && isThirdPartyMenu;
                    Game1.lastMousePositionBeforeFade = new Point(_gamepadCursorX, _gamepadCursorY);
                    Game1.input?.SetMousePosition(_gamepadCursorX, _gamepadCursorY);
                }
                catch { }
            }
            else
            {
                IsRightStickSteeringGameplayCursor = false;
                _lastRightStickStepMs = 0;
                _gamepadCursorX = Math.Clamp(_gamepadCursorX, 0, Math.Max(0, bw - 1));
                _gamepadCursorY = Math.Clamp(_gamepadCursorY, 0, Math.Max(0, bh - 1));
                _gamepadCursorXf = _gamepadCursorX;
                _gamepadCursorYf = _gamepadCursorY;
            }

            if (inMenu && !isFishingBar)
            {
                Point uiPt = RawToUiPoint(_gamepadCursorX, _gamepadCursorY, bw, bh);
                ClickableComponent curSnap = snapTargetMenu?.currentlySnappedComponent;
                int curSnapId = curSnap?.myID ?? int.MinValue;

                // A) R-Stick free cursor clicks on 3rd-party mod menus (GMCM, CJB, Chests Anywhere, UIIS2 popups)
                //    OR non-vanilla areas inside GameMenu (UI Info Suite 2 Calendar & Help Wanted Quest icons!)
                GameMenu gmMod = rawMenu as GameMenu;
                bool isNonVanillaGameMenuSpot = gmMod != null && IsRightStickMenuCursorActive && !IsPointOnVanillaInventoryControl(gmMod, uiPt) && GetHeldItemInMenu(rawMenu) == null;
                if (isThirdPartyMenu || isNonVanillaGameMenuSpot)
                {
                    if (IsRightStickMenuCursorActive)
                    {
                        try
                        {
                            Game1.timerUntilMouseFade = 4000;
                            Game1.mouseCursorTransparency = 1f;
                            Game1.wasMouseVisibleThisFrame = true;
                        }
                        catch { }
                    }

                    if (isThirdPartyMenu)
                    {
                        // Hold-capable real mouse button synthesis so GMCM sliders, checkboxes, dropdowns & scrollbars work!
                        if (aRising || r3Rising)
                        {
                            _rStickModHoldLeftDown = true;
                            try
                            {
                                Game1.lastCursorMotionWasMouse = true;
                                Game1.input?.SetMousePosition(_gamepadCursorX, _gamepadCursorY);
                            }
                            catch { }
                        }
                        if (!aNow && !r3Now)
                            _rStickModHoldLeftDown = false;
                        if (_rStickModHoldLeftDown)
                            SuppressGamepadAButtonThisFrame = true;

                        if (xRising)
                            _rStickModHoldRightDown = true;
                        if (!xNow)
                            _rStickModHoldRightDown = false;
                        if (_rStickModHoldRightDown)
                            SuppressGamepadXButtonThisFrame = true;
                    }
                    else if (r3Rising || aRising)
                    {
                        _menuSyntheticLeftClickFrames = 2;
                        SuppressGamepadAButtonThisFrame = true;
                        try
                        {
                            Game1.lastCursorMotionWasMouse = true;
                            Game1.input?.SetMousePosition(_gamepadCursorX, _gamepadCursorY);
                        }
                        catch { }
                    }
                }
                else
                {
                    _rStickModHoldLeftDown = false;
                    _rStickModHoldRightDown = false;

                    // B) Item Drop Fix (-99998 region_dropItem or R-stick cursor outside menu frame on scaled iPhone UI!)
                    bool onDropSpot = (!IsRightStickMenuCursorActive && (curSnapId == -99998 || (rawMenu is MenuWithInventory mwiDrop && curSnap != null && curSnap == mwiDrop.dropItemInvisibleButton))) ||
                                      (IsRightStickMenuCursorActive && IsPointOutsideMenuFrame(rawMenu, uiPt));
                    if (onDropSpot && (aRising || xRising) && GetHeldItemInMenu(rawMenu) != null)
                    {
                        if (TryDropHeldItemFromMenu(rawMenu, singleItemOnly: xRising && !aRising))
                        {
                            if (aRising) SuppressGamepadAButtonThisFrame = true;
                            if (xRising) SuppressGamepadXButtonThisFrame = true;
                            _gpDragTracking = false;
                            _gpDragMoved = false;
                        }
                    }

                    // C) Hold-A + Move (R-Stick / D-Pad / L-Stick) + Release-A single-motion Drag-and-Drop!
                    //    Coexists 100% with classic Console 2-press A pickup & swap!
                    //    CRITICAL: Suppress Buttons.A on frames AFTER aRising so vanilla Game1.updateActiveMenu's
                    //    650ms turbo-repeat (gamePadAButtonPolling) NEVER rapid-swaps items mid-drag!
                    if (SupportsHoldADrag(rawMenu))
                    {
                        Point activeSlotUi = (!IsRightStickMenuCursorActive && curSnap != null && curSnap.myID != -99998 && curSnap.bounds.Width > 0)
                            ? curSnap.bounds.Center
                            : uiPt;

                        if (aRising && !SuppressGamepadAButtonThisFrame)
                        {
                            _gpDragTracking = true;
                            _gpDragMoved = false;
                            _gpDragStartUi = activeSlotUi;
                            _gpDragStartSnapId = IsRightStickMenuCursorActive ? int.MinValue : curSnapId;
                        }
                        else if (aNow && _gpDragTracking)
                        {
                            SuppressGamepadAButtonThisFrame = true;
                            int dxUi = activeSlotUi.X - _gpDragStartUi.X;
                            int dyUi = activeSlotUi.Y - _gpDragStartUi.Y;
                            bool movedBySnap = !IsRightStickMenuCursorActive && _gpDragStartSnapId != int.MinValue && curSnapId != int.MinValue && curSnapId != _gpDragStartSnapId;
                            bool movedByDist = IsRightStickMenuCursorActive && (dxUi * dxUi + dyUi * dyUi) > 484; // >22 UI px
                            if (movedBySnap || movedByDist)
                                _gpDragMoved = true;
                            if (_gpDragMoved)
                            {
                                try { rawMenu.performHoverAction(activeSlotUi.X, activeSlotUi.Y); } catch { }
                            }
                        }
                        else if (aFalling && _gpDragTracking)
                        {
                            bool didMove = _gpDragMoved;
                            _gpDragTracking = false;
                            _gpDragMoved = false;
                            if (didMove && GetHeldItemInMenu(rawMenu) != null)
                            {
                                if (onDropSpot)
                                {
                                    TryDropHeldItemFromMenu(rawMenu, singleItemOnly: false);
                                }
                                else
                                {
                                    try
                                    {
                                        rawMenu.performHoverAction(activeSlotUi.X, activeSlotUi.Y);
                                        rawMenu.receiveLeftClick(activeSlotUi.X, activeSlotUi.Y, playSound: true);
                                        rawMenu.releaseLeftClick(activeSlotUi.X, activeSlotUi.Y);
                                    }
                                    catch { }
                                }
                            }
                        }
                    }
                }
            }

            ButtonState synthLeft = _rStickModHoldLeftDown ? ButtonState.Pressed : ButtonState.Released;
            if (_menuSyntheticLeftClickFrames > 0)
            {
                _menuSyntheticLeftClickFrames--;
                synthLeft = ButtonState.Pressed;
            }
            ButtonState synthRight = _rStickModHoldRightDown ? ButtonState.Pressed : ButtonState.Released;
            if (_menuSyntheticRightClickFrames > 0)
            {
                _menuSyntheticRightClickFrames--;
                synthRight = ButtonState.Pressed;
            }

            CurrentMouseState = new MouseState(
                _gamepadCursorX, _gamepadCursorY, _scrollWheelValue,
                synthLeft, ButtonState.Released, synthRight, ButtonState.Released, ButtonState.Released);
        }

        private static void EnsureRumbleFieldsResolved()
        {
            if (_rumbleFieldsResolved) return;
            _rumbleFieldsResolved = true;
            try
            {
                const BindingFlags stat = BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public;
                Type rt = typeof(Rumble);
                _fRumbleIsRumbling = rt.GetField("isRumbling", stat);
                _fRumbleStrength = rt.GetField("rumbleStrength", stat);
                _fRumbleTimerCurrent = rt.GetField("rumbleTimerCurrent", stat);
                _fRumbleTimerMax = rt.GetField("rumbleTimerMax", stat);
                _fRumbleFade = rt.GetField("fade", stat);
                _fRumbleDuringFade = rt.GetField("rumbleDuringFade", stat);
            }
            catch { }
        }

        public void SetRumbleDirect(float leftMotor, float rightMotor)
        {
            if ((!IsPhysicalGamepadActive && !_gpConnected) || IsSuppressed || Game1.options == null || !Game1.options.rumble || Game1.paused)
            {
                PushRumbleToNative(0f, 0f);
                return;
            }
            ShapeAndPushConsoleRumble(leftMotor, rightMotor);
        }

        public void UpdateControllerRumble()
        {
            if (_nativeSetRumble == null)
                return;

            if ((!IsPhysicalGamepadActive && !_gpConnected) || IsSuppressed || Game1.options == null || !Game1.options.rumble || Game1.paused)
            {
                PushRumbleToNative(0f, 0f);
                return;
            }

            EnsureRumbleFieldsResolved();
            if (_fRumbleIsRumbling == null)
                return;

            try
            {
                bool active = (bool)_fRumbleIsRumbling.GetValue(null);
                float strength = 0f;
                if (active)
                {
                    float tCur = _fRumbleTimerCurrent != null ? (float)_fRumbleTimerCurrent.GetValue(null) : 0f;
                    float tMax = _fRumbleTimerMax != null ? (float)_fRumbleTimerMax.GetValue(null) : 0f;
                    if (tCur <= tMax)
                    {
                        bool fading = _fRumbleFade != null && (bool)_fRumbleFade.GetValue(null);
                        if (fading)
                        {
                            float rawFade = _fRumbleDuringFade != null ? (float)_fRumbleDuringFade.GetValue(null) : 0f;
                            strength = Math.Clamp(rawFade * 1.45f, 0f, 1f);
                        }
                        else
                        {
                            strength = _fRumbleStrength != null ? (float)_fRumbleStrength.GetValue(null) : 0f;
                        }
                    }
                }
                strength = Math.Clamp(strength, 0f, 1f);
                ShapeAndPushConsoleRumble(strength, strength);
            }
            catch
            {
                PushRumbleToNative(0f, 0f);
            }
        }

        private void ShapeAndPushConsoleRumble(float rawLeft, float rawRight)
        {
            float l = Math.Clamp(rawLeft, 0f, 1f);
            float r = Math.Clamp(rawRight, 0f, 1f);
            float peak = Math.Max(l, r);
            if (peak <= 0.005f)
            {
                PushRumbleToNative(0f, 0f);
                return;
            }

            float outL, outR;
            if (peak >= 0.60f)
            {
                outL = l;
                outR = r * 0.85f;
            }
            else if (peak >= 0.25f)
            {
                outL = l;
                outR = r * 0.92f;
            }
            else
            {
                outL = l * 0.72f;
                outR = Math.Clamp(Math.Max(r * 1.28f, 0.15f), 0f, 1f);
            }
            PushRumbleToNative(outL, outR);
        }

        private void PushRumbleToNative(float left, float right)
        {
            if (_nativeSetRumble == null)
                return;
            left = Math.Clamp(left, 0f, 1f);
            right = Math.Clamp(right, 0f, 1f);
            bool activeNow = left > 0.005f || right > 0.005f;
            bool activePrev = _lastSentRumbleL > 0.005f || _lastSentRumbleR > 0.005f;
            if (!activeNow && !activePrev)
                return;
            if (activeNow == activePrev &&
                Math.Abs(left - _lastSentRumbleL) < 0.015f &&
                Math.Abs(right - _lastSentRumbleR) < 0.015f)
                return;

            _lastSentRumbleL = left;
            _lastSentRumbleR = right;
            try { _nativeSetRumble(left, right); } catch { }
        }

        public void OnGameSetMousePositionRaw(int x, int y)
        {
            GetBackBufferSize(out int bw, out int bh);
            int cx = Math.Clamp(x, 0, Math.Max(0, bw - 1));
            int cy = Math.Clamp(y, 0, Math.Max(0, bh - 1));
            _gamepadCursorX = cx;
            _gamepadCursorY = cy;
            _gamepadCursorXf = cx;
            _gamepadCursorYf = cy;
            _gamepadCursorInit = true;

            if (IsExternalMouseActive && _nativeSetMouseNorm != null && bw > 1 && bh > 1)
            {
                try { _nativeSetMouseNorm((float)cx / bw, (float)cy / bh); } catch { }
            }

            if (ShouldOverrideMouse)
            {
                var cur = CurrentMouseState;
                CurrentMouseState = new MouseState(cx, cy, cur.ScrollWheelValue, cur.LeftButton, cur.MiddleButton, cur.RightButton, cur.XButton1, cur.XButton2);
            }
        }

        public void PollFrame(int directTouchCount = -1)
        {
            if (directTouchCount < 0)
            {
                directTouchCount = 0;
                if (!PureGamepadMode && _nativeDirectTouches != null)
                {
                    try { directTouchCount = _nativeDirectTouches(); } catch { }
                }
            }
            int tick = Game1.ticks;
            long nowMs = Environment.TickCount64;
            if (tick == _lastPollTick)
            {
                if (directTouchCount > 0) NotifyDirectTouch(directTouchCount);
                return;
            }
            _lastPollTick = tick;
            _lastPollMs = nowMs;

            if (directTouchCount > 0)
            {
                NotifyDirectTouch(directTouchCount);
            }

            if (!_nativeAvailable || _nativePoll == null)
            {
                PollFallbackMonoGameGamepad(directTouchCount);
                return;
            }

            int ok = 0;
            try { ok = _nativePoll(_snapBuf); } catch { ok = 0; }
            if (ok == 0)
                return;

            int sz = Marshal.ReadInt32(_snapBuf, OffStructSize);
            if (sz != ExpectedStructSize)
            {
                if (!_abiMismatchLogged)
                {
                    _abiMismatchLogged = true;
                    _monitor?.Log($"[ExternalInput] Struct size mismatch: native={sz}, managed={ExpectedStructSize}", LogLevel.Warn);
                }
                return;
            }

            bool prevSup = _wasSuppressed;
            _nativeSuppressed = Marshal.ReadInt32(_snapBuf, OffSuppress) != 0;
            bool curSup = IsSuppressed;
            _wasSuppressed = curSup;
            if (curSup != prevSup)
            {
                OnSuppressionTransition(prevSup, curSup);
            }

            _gpConnected = Marshal.ReadInt32(_snapBuf, OffGpConnected) != 0;
            _kbConnected = Marshal.ReadInt32(_snapBuf, OffKbConnected) != 0;
            _mouseConnected = Marshal.ReadInt32(_snapBuf, OffMouseConnected) != 0;

            uint gpSeq = unchecked((uint)Marshal.ReadInt32(_snapBuf, OffGpActivitySeq));
            uint kbSeq = unchecked((uint)Marshal.ReadInt32(_snapBuf, OffKbActivitySeq));
            uint mouseSeq = unchecked((uint)Marshal.ReadInt32(_snapBuf, OffMouseActivitySeq));

            bool gpActiveEdge = _seqInitialized && gpSeq != _lastGpSeq;
            bool kbActiveEdge = _seqInitialized && kbSeq != _lastKbSeq;
            bool mouseActiveEdge = _seqInitialized && mouseSeq != _lastMouseSeq;
            _lastGpSeq = gpSeq;
            _lastKbSeq = kbSeq;
            _lastMouseSeq = mouseSeq;
            _seqInitialized = true;

            // --- 1. Physical Gamepad State ---
            if (_gpConnected && !curSup)
            {
                uint mask = unchecked((uint)Marshal.ReadInt32(_snapBuf, OffGpButtonsMask));
                float lx = ApplyAxisDeadzone(ReadFloat(_snapBuf, OffGpLeftX), 0.14f);
                float ly = ApplyAxisDeadzone(ReadFloat(_snapBuf, OffGpLeftY), 0.14f);
                float rx = ApplyAxisDeadzone(ReadFloat(_snapBuf, OffGpRightX), 0.14f);
                float ry = ApplyAxisDeadzone(ReadFloat(_snapBuf, OffGpRightY), 0.14f);
                float lt = Math.Clamp(ReadFloat(_snapBuf, OffGpLeftTrigger), 0f, 1f);
                float rt = Math.Clamp(ReadFloat(_snapBuf, OffGpRightTrigger), 0f, 1f);

                CurrentGamePadState = BuildGamePadState(mask, lx, ly, rx, ry, lt, rt);

                if ((PureGamepadMode || directTouchCount == 0) &&
                    (PureGamepadMode || gpActiveEdge || mask != 0 || lx * lx + ly * ly > 0.04f || rx * rx + ry * ry > 0.04f || lt > 0.2f || rt > 0.2f))
                {
                    SetActiveMode(ExternalInputMode.Gamepad);
                }
            }
            else
            {
                CurrentGamePadState = default;
                if (!PureGamepadMode && ActiveMode == ExternalInputMode.Gamepad && !_gpConnected)
                    SetActiveMode(ExternalInputMode.Touch);
            }

            // --- 2. Physical Keyboard State + Native TextBox Input ---
            _physicalKeys.Clear();
            if (_kbConnected && !curSup)
            {
                int kCnt = Math.Clamp(Marshal.ReadInt32(_snapBuf, OffKbKeyCount), 0, 32);
                for (int i = 0; i < kCnt; i++)
                {
                    ushort kCode = unchecked((ushort)Marshal.ReadInt16(_snapBuf, OffKbKeys + i * 2));
                    if (kCode > 0 && kCode <= 255)
                        _physicalKeys.Add((Keys)kCode);
                }

                if (!PureGamepadMode && directTouchCount == 0 && (kbActiveEdge || _physicalKeys.Count > 0))
                {
                    SetActiveMode(ExternalInputMode.KeyboardMouse);
                }

                DispatchNativeKeyboardTextInput();
            }
            else
            {
                _prevSpecialKeys.Clear();
            }

            SyncMonoGameKeyboardKeys();

            // --- 3. Physical Mouse / Trackpad State ---
            GetBackBufferSize(out int bw, out int bh);
            int scrollDelta = Marshal.ReadInt32(_snapBuf, OffMouseScrollDelta);
            if (!curSup && scrollDelta != 0)
            {
                _scrollWheelValue += scrollDelta;
            }

            if (_mouseConnected && !curSup)
            {
                float nx = Math.Clamp(ReadFloat(_snapBuf, OffMouseNormX), 0f, 1f);
                float ny = Math.Clamp(ReadFloat(_snapBuf, OffMouseNormY), 0f, 1f);
                uint mMask = unchecked((uint)Marshal.ReadInt32(_snapBuf, OffMouseButtonsMask));

                if ((PureGamepadMode || directTouchCount == 0) && (mouseActiveEdge || mMask != 0 || scrollDelta != 0))
                {
                    _mouseEverUsed = true;
                    SetActiveMode(ExternalInputMode.KeyboardMouse);
                }

                if (IsExternalMouseActive)
                {
                    int mx = Math.Clamp((int)Math.Round(nx * bw), 0, Math.Max(0, bw - 1));
                    int my = Math.Clamp((int)Math.Round(ny * bh), 0, Math.Max(0, bh - 1));
                    CurrentMouseState = new MouseState(
                        mx, my, _scrollWheelValue,
                        (mMask & (1u << 0)) != 0 ? ButtonState.Pressed : ButtonState.Released,
                        (mMask & (1u << 2)) != 0 ? ButtonState.Pressed : ButtonState.Released,
                        (mMask & (1u << 1)) != 0 ? ButtonState.Pressed : ButtonState.Released,
                        (mMask & (1u << 3)) != 0 ? ButtonState.Pressed : ButtonState.Released,
                        (mMask & (1u << 4)) != 0 ? ButtonState.Pressed : ButtonState.Released);
                }
            }
            else if (ActiveMode == ExternalInputMode.KeyboardMouse && !_kbConnected && !_mouseConnected)
            {
                SetActiveMode(PureGamepadMode ? ExternalInputMode.Gamepad : ExternalInputMode.Touch);
            }

            if (IsPhysicalGamepadActive)
            {
                Vector2 rStick = CurrentGamePadState.ThumbSticks.Right;
                StepGamepadRightStickCursor(rStick.X, rStick.Y, bw, bh);
            }
            else
            {
                IsRightStickSteeringGameplayCursor = false;
                IsRightStickMenuCursorActive = false;
                _lastRightStickStepMs = 0;
            }

            ApplyStardewGamepadMode();
            SyncDirectZeroHarmonyInputStates();
        }

        private static void EnsureSInputFieldsResolved(InputState inp)
        {
            if (_sInputFieldsResolved || inp == null) return;
            _sInputFieldsResolved = true;
            try
            {
                const BindingFlags instAny = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;
                Type t = inp.GetType();
                _sInputControllerField = t.GetField("<ControllerState>k__BackingField", instAny);
                _sInputMouseField = t.GetField("<MouseState>k__BackingField", instAny);
            }
            catch { }
        }

        public void SyncDirectZeroHarmonyInputStates()
        {
            if (!ShouldPushMouseStateNow && !IsPhysicalGamepadActive)
                return;
            try
            {
                InputState inp = Game1.input;
                if (inp != null)
                    EnsureSInputFieldsResolved(inp);

                if (ShouldPushMouseStateNow)
                {
                    MouseState ms = CurrentMouseState;
                    if (inp != null)
                    {
                        if (InputCurrentMouseField != null)
                            InputCurrentMouseField.SetValue(inp, ms);
                        if (_sInputMouseField != null)
                            _sInputMouseField.SetValue(inp, ms);
                    }
                    if (MousePrimaryWindowField != null)
                    {
                        object win = MousePrimaryWindowField.GetValue(null);
                        if (win != null)
                        {
                            if (!_windowMouseMemberResolved)
                            {
                                _windowMouseMemberResolved = true;
                                Type wt = win.GetType();
                                const BindingFlags any = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;
                                _windowMouseStateField = wt.GetField("MouseState", any);
                                _windowMouseStateProp = wt.GetProperty("MouseState", any);
                            }
                            if (_windowMouseStateField != null)
                                _windowMouseStateField.SetValue(win, ms);
                            else if (_windowMouseStateProp != null && _windowMouseStateProp.CanWrite)
                                _windowMouseStateProp.SetValue(win, ms);
                        }
                    }
                }
                else if (IsPhysicalGamepadActive && inp != null && Game1.activeClickableMenu != null &&
                         InputCurrentMouseField != null && _sInputMouseField != null)
                {
                    // Same-frame SnappyMenus cursor sync on 0% JIT:
                    // Game1.setMousePositionRaw(x, y) updates InputState._currentMouseState, NOT SInputState.<MouseState>k__BackingField!
                    // Mirroring _currentMouseState -> _sInputMouseField + Game1.oldMouseState immediately keeps hover & click 100% aligned!
                    if (InputCurrentMouseField.GetValue(inp) is MouseState baseMs &&
                        _sInputMouseField.GetValue(inp) is MouseState smapiMs &&
                        (baseMs.X != smapiMs.X || baseMs.Y != smapiMs.Y))
                    {
                        _sInputMouseField.SetValue(inp, baseMs);
                        MouseState prevOld = Game1.oldMouseState;
                        Game1.oldMouseState = new MouseState(
                            baseMs.X, baseMs.Y, prevOld.ScrollWheelValue,
                            prevOld.LeftButton, prevOld.MiddleButton, prevOld.RightButton,
                            prevOld.XButton1, prevOld.XButton2);
                        _gamepadCursorX = baseMs.X;
                        _gamepadCursorY = baseMs.Y;
                        _gamepadCursorXf = baseMs.X;
                        _gamepadCursorYf = baseMs.Y;
                    }
                }

                if (IsPhysicalGamepadActive && inp != null)
                {
                    GamePadState gps = GetEffectiveGamePadStateForGame();
                    if (InputCurrentGamepadField != null)
                        InputCurrentGamepadField.SetValue(inp, gps);
                    if (_sInputControllerField != null)
                        _sInputControllerField.SetValue(inp, gps);
                }
            }
            catch { }
        }

        private void PollFallbackMonoGameGamepad(int directTouchCount)
        {
            if (IsSuppressed)
            {
                CurrentGamePadState = default;
                ApplyStardewGamepadMode();
                return;
            }
            if (GamePadPlatformGetStateMethod == null) return;
            try
            {
                object res = GamePadPlatformGetStateMethod.Invoke(null, GamePadPlatformArgs);
                if (res is GamePadState gs && gs.IsConnected)
                {
                    _gpConnected = true;
                    CurrentGamePadState = gs;
                    bool used =
                        gs.ThumbSticks.Left.LengthSquared() > 0.06f ||
                        gs.ThumbSticks.Right.LengthSquared() > 0.06f ||
                        gs.Triggers.Left > 0.2f || gs.Triggers.Right > 0.2f ||
                        gs.Buttons.A == ButtonState.Pressed || gs.Buttons.B == ButtonState.Pressed ||
                        gs.Buttons.X == ButtonState.Pressed || gs.Buttons.Y == ButtonState.Pressed ||
                        gs.Buttons.LeftShoulder == ButtonState.Pressed || gs.Buttons.RightShoulder == ButtonState.Pressed ||
                        gs.Buttons.Start == ButtonState.Pressed || gs.Buttons.Back == ButtonState.Pressed ||
                        gs.DPad.Up == ButtonState.Pressed || gs.DPad.Down == ButtonState.Pressed ||
                        gs.DPad.Left == ButtonState.Pressed || gs.DPad.Right == ButtonState.Pressed;
                    if ((PureGamepadMode || directTouchCount == 0) && (PureGamepadMode || used))
                        SetActiveMode(ExternalInputMode.Gamepad);
                    if (IsPhysicalGamepadActive)
                    {
                        GetBackBufferSize(out int fbw, out int fbh);
                        float frx = ApplyAxisDeadzone(gs.ThumbSticks.Right.X, 0.14f);
                        float fry = ApplyAxisDeadzone(gs.ThumbSticks.Right.Y, 0.14f);
                        StepGamepadRightStickCursor(frx, fry, fbw, fbh);
                    }
                    ApplyStardewGamepadMode();
                    SyncDirectZeroHarmonyInputStates();
                    return;
                }
            }
            catch { }

            _gpConnected = false;
            CurrentGamePadState = default;
            if (!PureGamepadMode && ActiveMode == ExternalInputMode.Gamepad)
                SetActiveMode(ExternalInputMode.Touch);
        }

        private static float ApplyAxisDeadzone(float v, float deadzone)
        {
            float av = Math.Abs(v);
            if (av <= deadzone) return 0f;
            float scaled = (av - deadzone) / (1f - deadzone);
            return Math.Sign(v) * Math.Clamp(scaled, 0f, 1f);
        }

        private static GamePadState BuildGamePadState(uint mask, float lx, float ly, float rx, float ry, float lt, float rt)
        {
            Buttons b = 0;
            if ((mask & (1u << 0)) != 0) b |= Buttons.A;
            if ((mask & (1u << 1)) != 0) b |= Buttons.B;
            if ((mask & (1u << 2)) != 0) b |= Buttons.X;
            if ((mask & (1u << 3)) != 0) b |= Buttons.Y;
            if ((mask & (1u << 4)) != 0) b |= Buttons.LeftShoulder;
            if ((mask & (1u << 5)) != 0) b |= Buttons.RightShoulder;
            if ((mask & (1u << 6)) != 0) b |= Buttons.Start;
            if ((mask & (1u << 7)) != 0) b |= Buttons.Back;
            if ((mask & (1u << 8)) != 0) b |= Buttons.BigButton;
            if ((mask & (1u << 9)) != 0) b |= Buttons.LeftStick;
            if ((mask & (1u << 10)) != 0) b |= Buttons.RightStick;

            ButtonState dUp = (mask & (1u << 11)) != 0 ? ButtonState.Pressed : ButtonState.Released;
            ButtonState dDown = (mask & (1u << 12)) != 0 ? ButtonState.Pressed : ButtonState.Released;
            ButtonState dLeft = (mask & (1u << 13)) != 0 ? ButtonState.Pressed : ButtonState.Released;
            ButtonState dRight = (mask & (1u << 14)) != 0 ? ButtonState.Pressed : ButtonState.Released;

            if (dUp == ButtonState.Pressed) b |= Buttons.DPadUp;
            if (dDown == ButtonState.Pressed) b |= Buttons.DPadDown;
            if (dLeft == ButtonState.Pressed) b |= Buttons.DPadLeft;
            if (dRight == ButtonState.Pressed) b |= Buttons.DPadRight;

            if (lt > 0.35f) b |= Buttons.LeftTrigger;
            if (rt > 0.35f) b |= Buttons.RightTrigger;

            if (ly > 0.5f) b |= Buttons.LeftThumbstickUp;
            else if (ly < -0.5f) b |= Buttons.LeftThumbstickDown;
            if (lx < -0.5f) b |= Buttons.LeftThumbstickLeft;
            else if (lx > 0.5f) b |= Buttons.LeftThumbstickRight;

            if (ry > 0.5f) b |= Buttons.RightThumbstickUp;
            else if (ry < -0.5f) b |= Buttons.RightThumbstickDown;
            if (rx < -0.5f) b |= Buttons.RightThumbstickLeft;
            else if (rx > 0.5f) b |= Buttons.RightThumbstickRight;

            return new GamePadState(
                new GamePadThumbSticks(new Vector2(lx, ly), new Vector2(rx, ry)),
                new GamePadTriggers(lt, rt),
                new GamePadButtons(b),
                new GamePadDPad(dUp, dDown, dLeft, dRight));
        }

        public GamePadState GetStateForMonoGameHook(int index)
        {
            if (index != 0)
                return default;
            try
            {
                if (IsPhysicalGamepadActive)
                    return GetEffectiveGamePadStateForGame();
            }
            catch { }
            return default;
        }

        public GamePadState PollAndGetStateForMonoGameHook(int index)
        {
            if (index != 0)
                return default;
            try
            {
                PollFrame();
                if (IsPhysicalGamepadActive)
                    return GetEffectiveGamePadStateForGame();
            }
            catch { }
            return default;
        }

        public void OnReturnedToTitle()
        {
            _lastPollTick = -1;
            _lastPollMs = 0;
            IsRightStickSteeringGameplayCursor = false;
            IsRightStickMenuCursorActive = false;
            SuppressGamepadAButtonThisFrame = false;
            SuppressGamepadXButtonThisFrame = false;
            SuppressGamepadShoulderThisFrame = false;
            SuppressGamepadTriggerThisFrame = false;
            _menuSyntheticLeftClickFrames = 0;
            _menuSyntheticRightClickFrames = 0;
            _rStickModHoldLeftDown = false;
            _rStickModHoldRightDown = false;
            _gpDragTracking = false;
            _gpDragMoved = false;
            _lastRightStickStepMs = 0;
            PushRumbleToNative(0f, 0f);
        }

        private void SyncMonoGameKeyboardKeys(bool forceClear = false)
        {
            if (KeyboardSetKeysMethod == null) return;
            // Never overwrite TouchVirtualPad's virtual/custom keys when Touch mode is active and no physical keys are held!
            if (!forceClear && ActiveMode == ExternalInputMode.Touch && _physicalKeys.Count == 0 && _syncedEmptyMonoGameKeys)
                return;
            try
            {
                if (!forceClear && _physicalKeys.Count > 0)
                {
                    var merged = new List<Keys>(_physicalKeys.Count + 8);
                    for (int i = 0; i < _physicalKeys.Count; i++)
                        merged.Add(_physicalKeys[i]);
                    try { ModEntry.Engine?.PopulateExtraKeysList(merged); } catch { }
                    _kbSetKeysArg[0] = merged;
                    KeyboardSetKeysMethod.Invoke(null, _kbSetKeysArg);
                    _syncedEmptyMonoGameKeys = false;
                }
                else if (forceClear || !_syncedEmptyMonoGameKeys)
                {
                    var touchOnly = new List<Keys>(8);
                    try { ModEntry.Engine?.PopulateExtraKeysList(touchOnly); } catch { }
                    _kbSetKeysArg[0] = touchOnly;
                    KeyboardSetKeysMethod.Invoke(null, touchOnly.Count > 0 ? _kbSetKeysArg : EmptyKeysArg);
                    _syncedEmptyMonoGameKeys = true;
                }
            }
            catch { }
        }

        private void DispatchNativeKeyboardTextInput()
        {
            try
            {
                IKeyboardSubscriber sub = Game1.keyboardDispatcher?.Subscriber;
                int tCnt = Math.Clamp(Marshal.ReadInt32(_snapBuf, OffTextCharCount), 0, 32);
                if (sub != null && sub.Selected)
                {
                    for (int i = 0; i < tCnt; i++)
                    {
                        char ch = (char)unchecked((ushort)Marshal.ReadInt16(_snapBuf, OffTextChars + i * 2));
                        if (ch == '\b' || ch == '\r' || ch == '\t')
                            sub.RecieveCommandInput(ch);
                        else if (ch >= ' ')
                            sub.RecieveTextInput(ch);
                    }

                    _currSpecialKeys.Clear();
                    for (int i = 0; i < _physicalKeys.Count; i++)
                    {
                        Keys k = _physicalKeys[i];
                        if (k == Keys.Left || k == Keys.Right || k == Keys.Up || k == Keys.Down ||
                            k == Keys.Delete || k == Keys.Home || k == Keys.End)
                        {
                            _currSpecialKeys.Add(k);
                            if (!_prevSpecialKeys.Contains(k))
                                sub.RecieveSpecialInput(k);
                        }
                    }
                    _prevSpecialKeys.Clear();
                    foreach (Keys k in _currSpecialKeys)
                        _prevSpecialKeys.Add(k);
                }
                else
                {
                    _prevSpecialKeys.Clear();
                }
            }
            catch { }
        }

        public void PopulateExtraKeys(HashSet<Keys> targetSet)
        {
            if (targetSet == null || !HasPhysicalKeysPressed) return;
            for (int i = 0; i < _physicalKeys.Count; i++)
                targetSet.Add(_physicalKeys[i]);
        }

        public void PopulateExtraKeysList(List<Keys> targetList)
        {
            if (targetList == null || !HasPhysicalKeysPressed) return;
            for (int i = 0; i < _physicalKeys.Count; i++)
            {
                Keys k = _physicalKeys[i];
                if (!targetList.Contains(k))
                    targetList.Add(k);
            }
        }

        public KeyboardState MergeKeyboardState(KeyboardState existing)
        {
            if (!HasPhysicalKeysPressed)
                return existing;

            _mergeScratch.Clear();
            Keys[] cur = existing.GetPressedKeys();
            if (cur != null)
            {
                for (int i = 0; i < cur.Length; i++)
                    _mergeScratch.Add(cur[i]);
            }
            for (int i = 0; i < _physicalKeys.Count; i++)
            {
                Keys k = _physicalKeys[i];
                if (!_mergeScratch.Contains(k))
                    _mergeScratch.Add(k);
            }
            return new KeyboardState(_mergeScratch.ToArray());
        }
    }
}
