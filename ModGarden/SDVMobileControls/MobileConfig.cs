using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace SDVMobileControls
{
    public enum MobileControlMode
    {
        VirtualGamepad = 0,        // Original SDViOSTouchControls gamepad overlay
        InvisibleJoystick2Btn = 1, // Floating invisible joystick (left rect) + 2 tall vertical rectangular zones (right)
        VisibleJoystick2Btn = 2,   // Clean minimal joystick + 2 circular buttons
        TapToMove = 3,             // Tap-to-Move A* + Hold-to-Walk + Tap-to-Interact
        TapAndJoystick = 4         // Hybrid: Tap-to-Move + Floating invisible joystick + 2 vertical rectangular zones
    }

    public sealed class CustomKeyButton
    {
        public int Id { get; set; }
        public string Label { get; set; } = "P";
        public int KeyCode { get; set; } = 80; // Keys.P
        public float X { get; set; } = 0.84f;
        public float Y { get; set; } = 0.05f;
        public float W { get; set; } = 0.068f;
        public float H { get; set; } = 0.105f;
    }

    public sealed class MobileConfig
    {
        public MobileControlMode Mode { get; set; } = MobileControlMode.InvisibleJoystick2Btn;
        public bool AutoTool { get; set; } = true;
        public bool AutoAttack { get; set; } = false; // Default OFF
        public bool PinchZoom { get; set; } = true;
        public bool ShowTouchHint { get; set; } = false; // Default OFF (no flashing on invisible buttons!)
        public bool ShowTopUtility { get; set; } = true;
        public bool SwapRightButtons { get; set; } = false;
        public bool MobileShopAndDrag { get; set; } = true; // Mobile Shop quantity slider + Drag-and-Drop + Chest 1-tap transfer
        public bool AutoKeyboard { get; set; } = true;      // Auto-open iOS keyboard when tapping any TextBox
        public bool SafeCrafting { get; set; } = true;      // Hover-first 2-tap safe crafting/cooking/bundles
        public int AutoSaveMinutes { get; set; } = 0;       // 0 = OFF (default, zero stutter), 3 / 5 / 10 minutes periodic AutoSave slot
        public bool ReduceWeather { get; set; } = false;    // Default OFF; optional cap on excessive rain/wind debris particles for smoother FPS
        public float UiScaleOverride { get; set; } = 0.0f;  // 0 = game default, or 0.75..1.50 live UI scale for PC mod menus
        public float ButtonScale { get; set; } = 1.0f;

        // v7.11 Mobile Pro toggles (all cleanly switchable in Mod Garden!)
        public bool ShowEmoteButton { get; set; } = true;         // Smiley-face pixel Emote button in top utility bar
        public bool AutoRepeat { get; set; } = true;              // 1-tap auto-repeat chop/mine until broken
        public bool RestoreToolAfterAuto { get; set; } = false;   // Optional: restore previous slot after Auto-Tool finishes
        public bool ShowSpecButton { get; set; } = true;          // Context SPEC (Parry/Slam) button when holding MeleeWeapon
        public bool AutoCombatMode { get; set; } = false;         // Auto-switch to Joystick in Mines/Volcano + quick CTL toggle pill
        public bool AutoHideOnGamepad { get; set; } = true;       // Auto-hide touch buttons when Bluetooth controller is active
        public bool AutoPauseOnBackground { get; set; } = true;   // Auto-pause when Notification/Control Center or switching apps
        public bool FishingHaptic { get; set; } = true;           // Light iOS haptic tap when fish bites
        public int SafePaddingPx { get; set; } = -1;              // -1 = Auto from iOS safeAreaInsets, or 0..80 manual px
        public bool SafeDialogueAndTooltip { get; set; } = true;  // Fixed compact item tooltip + 2-tap safe dialogue choice confirmation
        public bool VerticalToolbar { get; set; } = false;        // Optional Mobile-style left vertical 36-slot scrollable toolbar
        public int BatterySaverFpsMode { get; set; } = 0;         // 0 = 60 FPS (default), 1 = 30 FPS, 2 = 45 FPS (keeps full 60Hz logic speed!)
        public bool MenuFps30 { get; set; } = false;              // false = 60 FPS smooth in-game menus (default), true = 30 FPS battery saver in menus
        public float PixelOpacity { get; set; } = 1.0f;           // 0.25..1.00 opacity scale for Pixel-Art touch controls
        public bool LeftHandedMobile { get; set; } = false;       // 1-tap mirror layout for left-handed players (Joy right, Buttons left)
        public float JoyDeadzone { get; set; } = 0.11f;           // 0.05..0.25 joystick deadzone sensitivity
        public float ToolbarSize { get; set; } = 1.00f;           // 0.55..1.50 thickness / slot size of vertical toolbar
        public float ToolbarOpacity { get; set; } = 0.90f;        // 0.20..1.00 opacity of vertical toolbar
        public int ToolbarColumns { get; set; } = 1;              // 1..3 columns on vertical toolbar
        public int ToolbarVisibleRows { get; set; } = 0;          // 0 = Auto full-height, or 4..12 visible slots per column
        public int ToolbarSide { get; set; } = 0;                 // 0 = Left edge, 1 = Right edge
        public float ToolbarY { get; set; } = 0.50f;              // 0.0..1.0 vertical alignment when shorter than screen height
        public bool ShowToolHitLocation { get; set; } = true;     // Always show red tool hit box (PC default false -> essential for mobile!)
        public bool PureGamepadMode { get; set; } = false;        // Pure Gamepad Mode (disables virtual touch HUD & touch interceptors from boot)

        // Normalized layout (0..1 of viewport) for Invisible Mode: Left Joystick Rect + 2 Right Vertical Rectangular Bars
        public float InvJoyX { get; set; }
        public float InvJoyY { get; set; }
        public float InvJoyW { get; set; }
        public float InvJoyH { get; set; }

        public float InvToolX { get; set; }
        public float InvToolY { get; set; }
        public float InvToolW { get; set; }
        public float InvToolH { get; set; }

        public float InvActX { get; set; }
        public float InvActY { get; set; }
        public float InvActW { get; set; }
        public float InvActH { get; set; }

        // Normalized layout (0..1) for Visible 2-Button Mode
        public float VisJoyX { get; set; }
        public float VisJoyY { get; set; }
        public float VisJoyR { get; set; }

        public float VisToolX { get; set; }
        public float VisToolY { get; set; }
        public float VisToolR { get; set; }

        public float VisActX { get; set; }
        public float VisActY { get; set; }
        public float VisActR { get; set; }

        // Top utility bar normalized top-left
        public float TopBarX { get; set; }
        public float TopBarY { get; set; }

        // User-added custom PC keyboard buttons (movable & resizable in Edit Layout!)
        public List<CustomKeyButton> CustomKeys { get; } = new List<CustomKeyButton>();

        private readonly string _path;
        private readonly string _editFlagPath;
        private readonly string _ramAlertPath;
        private readonly string _pauseFlagPath;
        private readonly string _hapticBiteFlagPath;
        private readonly string _safeAreaPath;
        private readonly string _pureGamepadFlagPath;
        private DateTime _lastWriteUtc = DateTime.MinValue;
        private DateTime _lastSafeAreaUtc = DateTime.MinValue;
        private int _pollCounter;
        private int _flagCounter;
        private int _ramAlertCounter;
        private int _pauseCounter;
        private int _safeAreaCounter;

        public float NativeSafeLeftFrac { get; private set; }
        public float NativeSafeRightFrac { get; private set; }
        public int Revision { get; private set; } = 1;

        public MobileConfig()
        {
            string docs = Environment.GetFolderPath(Environment.SpecialFolder.Personal);
            string gardenDir = Path.Combine(docs, ".garden");
            try { Directory.CreateDirectory(gardenDir); } catch { }
            _path = Path.Combine(gardenDir, "sdv_mobile_ctrl.cfg");
            _editFlagPath = Path.Combine(gardenDir, "sdv_mobile_edit.flag");
            _ramAlertPath = Path.Combine(gardenDir, "sdv_ram_alert.txt");
            _pauseFlagPath = Path.Combine(gardenDir, "sdv_pause_now.flag");
            _hapticBiteFlagPath = Path.Combine(gardenDir, "sdv_haptic_bite.flag");
            _safeAreaPath = Path.Combine(gardenDir, "sdv_safe_area.cfg");
            _pureGamepadFlagPath = Path.Combine(gardenDir, "sdv_gamepad_only.flag");
            try { PureGamepadMode = File.Exists(_pureGamepadFlagPath); } catch { }
            ResetLayoutDefaults();
            Reload(force: true);
            PollNativeSafeArea(force: true);
        }

        public void ResetLayoutDefaults()
        {
            InvJoyX = 0.02f;  InvJoyY = 0.22f;  InvJoyW = 0.42f;  InvJoyH = 0.74f;
            InvToolX = 0.72f; InvToolY = 0.20f; InvToolW = 0.125f; InvToolH = 0.74f;
            InvActX = 0.855f; InvActY = 0.20f;  InvActW = 0.125f;  InvActH = 0.74f;

            VisJoyX = 0.15f;  VisJoyY = 0.76f;  VisJoyR = 0.115f;
            VisToolX = 0.79f; VisToolY = 0.80f; VisToolR = 0.075f;
            VisActX = 0.90f;  VisActY = 0.70f;  VisActR = 0.075f;

            TopBarX = 0.055f; TopBarY = 0.028f;
            ToolbarSize = 1.00f;
            ToolbarColumns = 1;
            ToolbarVisibleRows = 0;
            ToolbarSide = 0;
            ToolbarY = 0.50f;
            Revision++;
        }

        public CustomKeyButton AddCustomKey(string label, int keyCode)
        {
            if (CustomKeys.Count >= 16)
                return null;

            int nextId = 1;
            foreach (var b in CustomKeys)
                if (b.Id >= nextId) nextId = b.Id + 1;

            float x = 0.56f;
            float y = 0.16f;
            for (int slot = 0; slot < 16; slot++)
            {
                int col = slot % 4;
                int row = slot / 4;
                float cx = Math.Clamp(0.56f + col * 0.085f, 0.05f, 0.90f);
                float cy = Math.Clamp(0.16f + row * 0.135f, 0.08f, 0.84f);
                bool overlap = false;
                for (int i = 0; i < CustomKeys.Count; i++)
                {
                    if (Math.Abs(CustomKeys[i].X - cx) < 0.045f && Math.Abs(CustomKeys[i].Y - cy) < 0.065f)
                    {
                        overlap = true;
                        break;
                    }
                }
                if (!overlap)
                {
                    x = cx;
                    y = cy;
                    break;
                }
            }

            string cleanLabel = SanitizeLabel(label);
            var btn = new CustomKeyButton
            {
                Id = nextId,
                Label = cleanLabel,
                KeyCode = keyCode,
                X = x,
                Y = y,
                W = 0.068f,
                H = 0.105f
            };
            CustomKeys.Add(btn);
            Save();
            return btn;
        }

        public bool RemoveCustomKey(int id)
        {
            for (int i = 0; i < CustomKeys.Count; i++)
            {
                if (CustomKeys[i].Id == id)
                {
                    CustomKeys.RemoveAt(i);
                    Save();
                    return true;
                }
            }
            return false;
        }

        private static string SanitizeLabel(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw)) return "KEY";
            string s = raw.Trim().Replace("|", "").Replace("\n", "").Replace("\r", "");
            if (s.Length > 6) s = s.Substring(0, 6);
            return s.ToUpperInvariant();
        }

        public bool ConsumeEditLayoutFlag()
        {
            if (++_flagCounter < 25)
                return false;
            _flagCounter = 0;
            try
            {
                if (!File.Exists(_editFlagPath))
                    return false;
                File.Delete(_editFlagPath);
                Reload(force: true);
                return true;
            }
            catch
            {
                return false;
            }
        }

        public bool TryConsumeRamAlertFlag(out string alertMsg)
        {
            alertMsg = null;
            if (++_ramAlertCounter < 60)
                return false;
            _ramAlertCounter = 0;
            try
            {
                if (!File.Exists(_ramAlertPath))
                    return false;
                alertMsg = File.ReadAllText(_ramAlertPath)?.Trim();
                File.Delete(_ramAlertPath);
                return !string.IsNullOrEmpty(alertMsg);
            }
            catch
            {
                return false;
            }
        }

        public bool ConsumePauseFlag()
        {
            if (++_pauseCounter < 20)
                return false;
            _pauseCounter = 0;
            try
            {
                if (!File.Exists(_pauseFlagPath))
                    return false;
                File.Delete(_pauseFlagPath);
                return true;
            }
            catch { return false; }
        }

        public void TriggerFishBiteHaptic()
        {
            try { File.WriteAllText(_hapticBiteFlagPath, "1"); } catch { }
        }

        public void PollNativeSafeArea(bool force = false)
        {
            if (!force && ++_safeAreaCounter < 45)
                return;
            _safeAreaCounter = 0;
            try
            {
                if (!File.Exists(_safeAreaPath)) return;
                DateTime mt = File.GetLastWriteTimeUtc(_safeAreaPath);
                if (!force && mt == _lastSafeAreaUtc) return;
                _lastSafeAreaUtc = mt;
                string raw = File.ReadAllText(_safeAreaPath)?.Trim();
                if (string.IsNullOrEmpty(raw)) return;
                string[] parts = raw.Split(',');
                if (parts.Length >= 2)
                {
                    float nl = ParseFloat(parts[0], 0f, 0f, 0.14f);
                    float nr = ParseFloat(parts[1], 0f, 0f, 0.14f);
                    if (Math.Abs(nl - NativeSafeLeftFrac) > 0.0001f || Math.Abs(nr - NativeSafeRightFrac) > 0.0001f)
                    {
                        NativeSafeLeftFrac = nl;
                        NativeSafeRightFrac = nr;
                        Revision++;
                    }
                }
            }
            catch { }
        }

        public void PollReload()
        {
            PollNativeSafeArea(force: false);
            if (++_pollCounter < 60)
                return;
            _pollCounter = 0;
            Reload(force: false);
        }

        public void Reload(bool force)
        {
            try
            {
                if (!File.Exists(_path))
                {
                    if (force)
                        Save();
                    return;
                }

                DateTime mtime = File.GetLastWriteTimeUtc(_path);
                if (!force && mtime == _lastWriteUtc)
                    return;
                _lastWriteUtc = mtime;

                string[] lines = File.ReadAllLines(_path);
                CustomKeys.Clear();
                bool sawTouchHint2 = false;

                foreach (string raw in lines)
                {
                    if (string.IsNullOrWhiteSpace(raw))
                        continue;
                    int eq = raw.IndexOf('=');
                    if (eq <= 0)
                        continue;
                    string k = raw.Substring(0, eq).Trim().ToLowerInvariant();
                    string v = raw.Substring(eq + 1).Trim();

                    switch (k)
                    {
                        case "mode":
                            if (int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out int m))
                                Mode = (m >= 1 && m <= 4) ? (MobileControlMode)m : MobileControlMode.InvisibleJoystick2Btn;
                            break;
                        case "autotool": AutoTool = ParseBool(v, true); break;
                        case "autoattack": AutoAttack = ParseBool(v, false); break;
                        case "pinchzoom": PinchZoom = ParseBool(v, true); break;
                        case "touchhint2":
                            ShowTouchHint = ParseBool(v, false);
                            sawTouchHint2 = true;
                            break;
                        case "toputility": ShowTopUtility = ParseBool(v, true); break;
                        case "swapbuttons": SwapRightButtons = ParseBool(v, false); break;
                        case "mobileshopdrag": MobileShopAndDrag = ParseBool(v, true); break;
                        case "autokeyboard": AutoKeyboard = ParseBool(v, true); break;
                        case "safecrafting": SafeCrafting = ParseBool(v, true); break;
                        case "autosavemin":
                            if (int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out int am) && (am == 0 || am == 3 || am == 5 || am == 10))
                                AutoSaveMinutes = am;
                            break;
                        case "reduceweather": ReduceWeather = ParseBool(v, false); break;
                        case "uiscale":
                            float us = ParseFloat(v, 0.0f, 0.0f, 1.50f);
                            UiScaleOverride = (us >= 0.70f) ? Math.Clamp(us, 0.75f, 1.50f) : 0.0f;
                            break;
                        case "buttonscale": ButtonScale = ParseFloat(v, 1.0f, 0.75f, 1.45f); break;
                        case "emotebtn": ShowEmoteButton = ParseBool(v, true); break;
                        case "autorepeat": AutoRepeat = ParseBool(v, true); break;
                        case "restoretool": RestoreToolAfterAuto = ParseBool(v, false); break;
                        case "specbtn": ShowSpecButton = ParseBool(v, true); break;
                        case "autocombatmode": AutoCombatMode = ParseBool(v, false); break;
                        case "autohidegp": AutoHideOnGamepad = ParseBool(v, true); break;
                        case "autopause": AutoPauseOnBackground = ParseBool(v, true); break;
                        case "fishhaptic": FishingHaptic = ParseBool(v, true); break;
                        case "safepadding":
                            if (int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out int sp))
                                SafePaddingPx = sp < 0 ? -1 : Math.Clamp(sp, 0, 80);
                            break;
                        case "safedialogue": SafeDialogueAndTooltip = ParseBool(v, true); break;
                        case "verticaltb": VerticalToolbar = ParseBool(v, false); break;
                        case "saver30fps":
                            if (v == "2" || v == "45") BatterySaverFpsMode = 2;
                            else if (v == "1" || v == "30" || v.Equals("true", StringComparison.OrdinalIgnoreCase)) BatterySaverFpsMode = 1;
                            else BatterySaverFpsMode = 0;
                            break;
                        case "menufps30": MenuFps30 = ParseBool(v, false); break;
                        case "pixelopacity": PixelOpacity = ParseFloat(v, 1.0f, 0.25f, 1.00f); break;
                        case "lefthanded": LeftHandedMobile = ParseBool(v, false); break;
                        case "joydeadzone": JoyDeadzone = ParseFloat(v, 0.11f, 0.05f, 0.25f); break;
                        case "tbsize": ToolbarSize = ParseFloat(v, 1.00f, 0.55f, 1.50f); break;
                        case "tbopacity": ToolbarOpacity = ParseFloat(v, 0.90f, 0.20f, 1.00f); break;
                        case "tbcols":
                            if (int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out int tc))
                                ToolbarColumns = Math.Clamp(tc, 1, 3);
                            break;
                        case "tbrows":
                            if (int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out int tr))
                                ToolbarVisibleRows = tr <= 0 ? 0 : Math.Clamp(tr, 4, 12);
                            break;
                        case "tbside":
                            if (int.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out int ts))
                                ToolbarSide = ts == 1 ? 1 : 0;
                            break;
                        case "tby": ToolbarY = ParseFloat(v, 0.50f, 0.0f, 1.0f); break;
                        case "toolhitbox": ShowToolHitLocation = ParseBool(v, true); break;
                        case "puregamepad": PureGamepadMode = ParseBool(v, PureGamepadMode); break;

                        case "inv_joy_x": InvJoyX = ParseFloat(v, InvJoyX, 0.0f, 0.90f); break;
                        case "inv_joy_y": InvJoyY = ParseFloat(v, InvJoyY, 0.0f, 0.90f); break;
                        case "inv_joy_w": InvJoyW = ParseFloat(v, InvJoyW, 0.12f, 0.75f); break;
                        case "inv_joy_h": InvJoyH = ParseFloat(v, InvJoyH, 0.18f, 0.95f); break;

                        case "inv_tool_x": InvToolX = ParseFloat(v, InvToolX, 0.0f, 0.94f); break;
                        case "inv_tool_y": InvToolY = ParseFloat(v, InvToolY, 0.0f, 0.90f); break;
                        case "inv_tool_w": InvToolW = ParseFloat(v, InvToolW, 0.055f, 0.45f); break;
                        case "inv_tool_h": InvToolH = ParseFloat(v, InvToolH, 0.12f, 0.95f); break;

                        case "inv_act_x": InvActX = ParseFloat(v, InvActX, 0.0f, 0.94f); break;
                        case "inv_act_y": InvActY = ParseFloat(v, InvActY, 0.0f, 0.90f); break;
                        case "inv_act_w": InvActW = ParseFloat(v, InvActW, 0.055f, 0.45f); break;
                        case "inv_act_h": InvActH = ParseFloat(v, InvActH, 0.12f, 0.95f); break;

                        case "vis_joy_x": VisJoyX = ParseFloat(v, VisJoyX, 0.05f, 0.95f); break;
                        case "vis_joy_y": VisJoyY = ParseFloat(v, VisJoyY, 0.08f, 0.95f); break;
                        case "vis_joy_r": VisJoyR = ParseFloat(v, VisJoyR, 0.07f, 0.22f); break;

                        case "vis_tool_x": VisToolX = ParseFloat(v, VisToolX, 0.05f, 0.95f); break;
                        case "vis_tool_y": VisToolY = ParseFloat(v, VisToolY, 0.08f, 0.95f); break;
                        case "vis_tool_r": VisToolR = ParseFloat(v, VisToolR, 0.045f, 0.16f); break;

                        case "vis_act_x": VisActX = ParseFloat(v, VisActX, 0.05f, 0.95f); break;
                        case "vis_act_y": VisActY = ParseFloat(v, VisActY, 0.08f, 0.95f); break;
                        case "vis_act_r": VisActR = ParseFloat(v, VisActR, 0.045f, 0.16f); break;

                        case "topbar_x": TopBarX = ParseFloat(v, TopBarX, 0.01f, 0.85f); break;
                        case "topbar_y": TopBarY = ParseFloat(v, TopBarY, 0.005f, 0.90f); break;

                        case "ckey":
                            TryParseCustomKey(v);
                            break;
                    }
                }

                if (!sawTouchHint2)
                    ShowTouchHint = false;
                Revision++;
            }
            catch
            {
                // Keep previous safe settings
            }
        }

        private void TryParseCustomKey(string v)
        {
            if (CustomKeys.Count >= 16) return;
            string[] parts = v.Split('|');
            if (parts.Length < 7) return;
            if (!int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out int id)) return;
            if (!int.TryParse(parts[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out int kc) || kc <= 0) return;

            CustomKeys.Add(new CustomKeyButton
            {
                Id = id,
                Label = SanitizeLabel(parts[1]),
                KeyCode = kc,
                X = ParseFloat(parts[3], 0.80f, 0.0f, 0.95f),
                Y = ParseFloat(parts[4], 0.15f, 0.0f, 0.92f),
                W = ParseFloat(parts[5], 0.068f, 0.035f, 0.35f),
                H = ParseFloat(parts[6], 0.105f, 0.050f, 0.45f)
            });
        }

        public void Save()
        {
            try
            {
                string dir = Path.GetDirectoryName(_path);
                if (!string.IsNullOrEmpty(dir))
                    Directory.CreateDirectory(dir);

                string F(float x) => x.ToString("0.000", CultureInfo.InvariantCulture);
                var sb = new StringBuilder(512);
                sb.AppendLine($"mode={(int)Mode}");
                sb.AppendLine($"autotool={(AutoTool ? 1 : 0)}");
                sb.AppendLine($"autoattack={(AutoAttack ? 1 : 0)}");
                sb.AppendLine($"pinchzoom={(PinchZoom ? 1 : 0)}");
                sb.AppendLine($"touchhint2={(ShowTouchHint ? 1 : 0)}");
                sb.AppendLine($"toputility={(ShowTopUtility ? 1 : 0)}");
                sb.AppendLine($"swapbuttons={(SwapRightButtons ? 1 : 0)}");
                sb.AppendLine($"mobileshopdrag={(MobileShopAndDrag ? 1 : 0)}");
                sb.AppendLine($"autokeyboard={(AutoKeyboard ? 1 : 0)}");
                sb.AppendLine($"safecrafting={(SafeCrafting ? 1 : 0)}");
                sb.AppendLine($"autosavemin={AutoSaveMinutes}");
                sb.AppendLine($"reduceweather={(ReduceWeather ? 1 : 0)}");
                sb.AppendLine($"uiscale={UiScaleOverride.ToString("0.00", CultureInfo.InvariantCulture)}");
                sb.AppendLine($"buttonscale={ButtonScale.ToString("0.00", CultureInfo.InvariantCulture)}");
                sb.AppendLine($"emotebtn={(ShowEmoteButton ? 1 : 0)}");
                sb.AppendLine($"autorepeat={(AutoRepeat ? 1 : 0)}");
                sb.AppendLine($"restoretool={(RestoreToolAfterAuto ? 1 : 0)}");
                sb.AppendLine($"specbtn={(ShowSpecButton ? 1 : 0)}");
                sb.AppendLine($"autocombatmode={(AutoCombatMode ? 1 : 0)}");
                sb.AppendLine($"autohidegp={(AutoHideOnGamepad ? 1 : 0)}");
                sb.AppendLine($"autopause={(AutoPauseOnBackground ? 1 : 0)}");
                sb.AppendLine($"fishhaptic={(FishingHaptic ? 1 : 0)}");
                sb.AppendLine($"safepadding={SafePaddingPx}");
                sb.AppendLine($"safedialogue={(SafeDialogueAndTooltip ? 1 : 0)}");
                sb.AppendLine($"verticaltb={(VerticalToolbar ? 1 : 0)}");
                sb.AppendLine($"saver30fps={Math.Clamp(BatterySaverFpsMode, 0, 2)}");
                sb.AppendLine($"menufps30={(MenuFps30 ? 1 : 0)}");
                sb.AppendLine($"pixelopacity={PixelOpacity.ToString("0.00", CultureInfo.InvariantCulture)}");
                sb.AppendLine($"lefthanded={(LeftHandedMobile ? 1 : 0)}");
                sb.AppendLine($"joydeadzone={JoyDeadzone.ToString("0.00", CultureInfo.InvariantCulture)}");
                sb.AppendLine($"tbsize={ToolbarSize.ToString("0.00", CultureInfo.InvariantCulture)}");
                sb.AppendLine($"tbopacity={ToolbarOpacity.ToString("0.00", CultureInfo.InvariantCulture)}");
                sb.AppendLine($"tbcols={Math.Clamp(ToolbarColumns, 1, 3)}");
                sb.AppendLine($"tbrows={(ToolbarVisibleRows <= 0 ? 0 : Math.Clamp(ToolbarVisibleRows, 4, 12))}");
                sb.AppendLine($"tbside={(ToolbarSide == 1 ? 1 : 0)}");
                sb.AppendLine($"tby={ToolbarY.ToString("0.000", CultureInfo.InvariantCulture)}");
                sb.AppendLine($"toolhitbox={(ShowToolHitLocation ? 1 : 0)}");
                sb.AppendLine($"puregamepad={(PureGamepadMode ? 1 : 0)}");
                sb.AppendLine($"inv_joy_x={F(InvJoyX)}");
                sb.AppendLine($"inv_joy_y={F(InvJoyY)}");
                sb.AppendLine($"inv_joy_w={F(InvJoyW)}");
                sb.AppendLine($"inv_joy_h={F(InvJoyH)}");
                sb.AppendLine($"inv_tool_x={F(InvToolX)}");
                sb.AppendLine($"inv_tool_y={F(InvToolY)}");
                sb.AppendLine($"inv_tool_w={F(InvToolW)}");
                sb.AppendLine($"inv_tool_h={F(InvToolH)}");
                sb.AppendLine($"inv_act_x={F(InvActX)}");
                sb.AppendLine($"inv_act_y={F(InvActY)}");
                sb.AppendLine($"inv_act_w={F(InvActW)}");
                sb.AppendLine($"inv_act_h={F(InvActH)}");
                sb.AppendLine($"vis_joy_x={F(VisJoyX)}");
                sb.AppendLine($"vis_joy_y={F(VisJoyY)}");
                sb.AppendLine($"vis_joy_r={F(VisJoyR)}");
                sb.AppendLine($"vis_tool_x={F(VisToolX)}");
                sb.AppendLine($"vis_tool_y={F(VisToolY)}");
                sb.AppendLine($"vis_tool_r={F(VisToolR)}");
                sb.AppendLine($"vis_act_x={F(VisActX)}");
                sb.AppendLine($"vis_act_y={F(VisActY)}");
                sb.AppendLine($"vis_act_r={F(VisActR)}");
                sb.AppendLine($"topbar_x={F(TopBarX)}");
                sb.AppendLine($"topbar_y={F(TopBarY)}");

                foreach (var b in CustomKeys)
                {
                    sb.AppendLine($"ckey={b.Id}|{SanitizeLabel(b.Label)}|{b.KeyCode}|{F(b.X)}|{F(b.Y)}|{F(b.W)}|{F(b.H)}");
                }

                File.WriteAllText(_path, sb.ToString());
                _lastWriteUtc = File.GetLastWriteTimeUtc(_path);
                Revision++;
            }
            catch
            {
                // Ignore transient I/O errors
            }
        }

        private static bool ParseBool(string v, bool fallback)
        {
            if (v == "1" || v.Equals("true", StringComparison.OrdinalIgnoreCase)) return true;
            if (v == "0" || v.Equals("false", StringComparison.OrdinalIgnoreCase)) return false;
            return fallback;
        }

        private static float ParseFloat(string v, float fallback, float min, float max)
        {
            if (float.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out float f))
                return Math.Clamp(f, min, max);
            return fallback;
        }
    }
}
