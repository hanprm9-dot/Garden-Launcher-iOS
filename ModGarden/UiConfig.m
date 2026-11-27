#import <Foundation/Foundation.h>

static inline void sdvSetAuroraBackdropEnabled(BOOL enabled);

@interface SDVUiConfig : NSObject
// Menu Bar
@property(nonatomic, assign) float menuBarScale;
@property(nonatomic, assign) float menuBarTopY;
@property(nonatomic, assign) float menuBarLeftX;
@property(nonatomic, assign) float menuBarGap;
@property(nonatomic, assign) float menuBarOpacity;

// Action Buttons (X / Y / A / B)
@property(nonatomic, assign) float abxyScale;
@property(nonatomic, assign) float abxySpacing;
@property(nonatomic, assign) float abxyOpacity;

// Shoulder Triggers (LT / RT)
@property(nonatomic, assign) float trigScale;
@property(nonatomic, assign) float trigOpacity;

// Joystick
@property(nonatomic, assign) float joyScale;
@property(nonatomic, assign) float joyOpacity;

// SDViOS Modals (Touch Control Settings + Key Picker + Hotkey Drawer)
@property(nonatomic, assign) float modalScale;
@property(nonatomic, assign) float drawerScale;

// Standard TouchOverlaySettings fields (touch_overlay_config.json)
@property(nonatomic, assign) float opacity;
@property(nonatomic, assign) float padScale;
@property(nonatomic, assign) BOOL leftHanded;
@property(nonatomic, assign) BOOL showKeyboardBtn;
@property(nonatomic, assign) BOOL showMenuBtn;
@property(nonatomic, assign) BOOL showHotkeyDrawerBtn;
@property(nonatomic, assign) NSInteger mouseMode; // 0=PointAndClick, 1=Trackpad, 2=Disabled

+(instancetype)loadFromDocuments:(NSString *)docsPath;
-(void)resetDefaults;
-(void)saveToDocuments:(NSString *)docsPath;
-(void)saveLiveCfgOnlyToDocuments:(NSString *)docsPath;
@end

static float sdvClampf(float v, float lo, float hi) {
    if (isnan(v) || isinf(v)) return lo;
    return v < lo ? lo : (v > hi ? hi : v);
}

static long long sdvNextRev(void) {
    static long long sLastRev = 0;
    long long now = (long long)(NSDate.date.timeIntervalSince1970 * 1000.0);
    if (now <= sLastRev) now = sLastRev + 1;
    sLastRev = now;
    return now;
}

@implementation SDVUiConfig

-(instancetype)init {
    self = [super init];
    if (self) [self resetDefaults];
    return self;
}

-(void)resetDefaults {
    _menuBarScale   = 1.00f;
    _menuBarTopY    = 24.0f;
    _menuBarLeftX   = 56.0f;
    _menuBarGap     = 8.0f;
    _menuBarOpacity = 0.75f;

    _abxyScale   = 1.00f;
    _abxySpacing = 1.00f;
    _abxyOpacity = 0.70f;

    _trigScale   = 1.00f;
    _trigOpacity = 0.70f;

    _joyScale   = 1.00f;
    _joyOpacity = 0.65f;

    _modalScale  = 1.55f;
    _drawerScale = 1.35f;

    _opacity = 0.65f;
    _padScale = 1.00f;
    _leftHanded = NO;
    _showKeyboardBtn = YES;
    _showMenuBtn = YES;
    _showHotkeyDrawerBtn = YES;
    _mouseMode = 0;
}

+(instancetype)loadFromDocuments:(NSString *)docsPath {
    SDVUiConfig *cfg = [SDVUiConfig new];
    if (!docsPath.length) return cfg;

    // 1. Read .garden/sdv_menubar.cfg (14 comma-separated floats + rev)
    NSString *gd = sdvHiddenGardenDir(docsPath);
    NSString *mbPath = [gd stringByAppendingPathComponent:@"sdv_menubar.cfg"];
    NSString *mbRaw = [NSString stringWithContentsOfFile:mbPath encoding:NSUTF8StringEncoding error:nil];
    if (mbRaw.length) {
        NSArray<NSString *> *p = [mbRaw componentsSeparatedByString:@","];
        float (^readAt)(NSUInteger, float, float, float) = ^float(NSUInteger idx, float defV, float lo, float hi) {
            if (idx >= p.count) return defV;
            NSString *s = [p[idx] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!s.length) return defV;
            return sdvClampf(s.floatValue, lo, hi);
        };
        cfg.menuBarScale   = readAt(0,  1.00f, 0.55f, 2.20f);
        cfg.menuBarTopY    = readAt(1, 24.0f,  4.0f, 160.0f);
        cfg.menuBarLeftX   = readAt(2, 56.0f,  8.0f, 240.0f);
        cfg.menuBarGap     = readAt(3,  8.0f,  2.0f,  22.0f);
        if (p.count >= 14) {
            cfg.menuBarOpacity = readAt(4,  0.75f, 0.10f, 1.00f);
            cfg.abxyScale      = readAt(5,  1.00f, 0.50f, 2.20f);
            cfg.abxySpacing    = readAt(6,  1.00f, 0.60f, 1.80f);
            cfg.abxyOpacity    = readAt(7,  0.70f, 0.05f, 1.00f);
            cfg.trigScale      = readAt(8,  1.00f, 0.50f, 2.20f);
            cfg.trigOpacity    = readAt(9,  0.70f, 0.05f, 1.00f);
            cfg.joyScale       = readAt(10, 1.00f, 0.50f, 2.20f);
            cfg.joyOpacity     = readAt(11, 0.65f, 0.05f, 1.00f);
            cfg.modalScale     = readAt(12, 1.55f, 1.00f, 2.00f);
            cfg.drawerScale    = readAt(13, 1.35f, 0.80f, 2.00f);
        }
    }

    // 2. Read .garden/touch_overlay_config.json
    NSString *ovPath = [gd stringByAppendingPathComponent:@"touch_overlay_config.json"];
    NSString *ovRaw = [NSString stringWithContentsOfFile:ovPath encoding:NSUTF8StringEncoding error:nil];
    if (ovRaw.length) {
        NSCharacterSet *trim = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        NSCharacterSet *quotes = [NSCharacterSet characterSetWithCharactersInString:@"\" "];
        for (NSString *rawLine in [ovRaw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *line = [rawLine stringByTrimmingCharactersInSet:trim];
            if ([line hasSuffix:@","]) line = [line substringToIndex:line.length - 1];
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            NSString *key = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:quotes];
            NSString *val = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:quotes];
            if (!key.length || !val.length) continue;

            if ([key caseInsensitiveCompare:@"Opacity"] == NSOrderedSame)
                cfg.opacity = sdvClampf(val.floatValue, 0.15f, 1.00f);
            else if ([key caseInsensitiveCompare:@"Scale"] == NSOrderedSame)
                cfg.padScale = sdvClampf(val.floatValue, 0.50f, 2.00f);
            else if ([key caseInsensitiveCompare:@"LeftHanded"] == NSOrderedSame)
                cfg.leftHanded = ([val caseInsensitiveCompare:@"true"] == NSOrderedSame);
            else if ([key caseInsensitiveCompare:@"ShowKeyboardBtn"] == NSOrderedSame)
                cfg.showKeyboardBtn = ([val caseInsensitiveCompare:@"true"] == NSOrderedSame);
            else if ([key caseInsensitiveCompare:@"ShowMenuBtn"] == NSOrderedSame)
                cfg.showMenuBtn = ([val caseInsensitiveCompare:@"true"] == NSOrderedSame);
            else if ([key caseInsensitiveCompare:@"ShowHotkeyDrawerBtn"] == NSOrderedSame)
                cfg.showHotkeyDrawerBtn = ([val caseInsensitiveCompare:@"true"] == NSOrderedSame);
            else if ([key caseInsensitiveCompare:@"MouseControlMode"] == NSOrderedSame) {
                if ([val caseInsensitiveCompare:@"Trackpad"] == NSOrderedSame || [val isEqualToString:@"1"]) cfg.mouseMode = 1;
                else if ([val caseInsensitiveCompare:@"Disabled"] == NSOrderedSame || [val isEqualToString:@"2"]) cfg.mouseMode = 2;
                else cfg.mouseMode = 0;
            }
        }
    }
    return cfg;
}

-(void)saveLiveCfgOnlyToDocuments:(NSString *)docsPath {
    if (!docsPath.length) return;
    NSString *gd = sdvHiddenGardenDir(docsPath);
    NSString *mbPath = [gd stringByAppendingPathComponent:@"sdv_menubar.cfg"];
    NSString *content = [NSString stringWithFormat:@"%.2f,%.0f,%.0f,%.0f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%lld",
        sdvClampf(_menuBarScale,   0.55f, 2.20f),
        sdvClampf(_menuBarTopY,    4.0f, 160.0f),
        sdvClampf(_menuBarLeftX,   8.0f, 240.0f),
        sdvClampf(_menuBarGap,     2.0f,  22.0f),
        sdvClampf(_menuBarOpacity, 0.10f, 1.00f),
        sdvClampf(_abxyScale,      0.50f, 2.20f),
        sdvClampf(_abxySpacing,    0.60f, 1.80f),
        sdvClampf(_abxyOpacity,    0.05f, 1.00f),
        sdvClampf(_trigScale,      0.50f, 2.20f),
        sdvClampf(_trigOpacity,    0.05f, 1.00f),
        sdvClampf(_joyScale,       0.50f, 2.20f),
        sdvClampf(_joyOpacity,     0.05f, 1.00f),
        sdvClampf(_modalScale,     1.00f, 2.00f),
        sdvClampf(_drawerScale,    0.80f, 2.00f),
        sdvNextRev()];
    [content writeToFile:mbPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

-(void)saveToDocuments:(NSString *)docsPath {
    if (!docsPath.length) return;
    NSString *gd = sdvHiddenGardenDir(docsPath);

    NSString *ovPath = [gd stringByAppendingPathComponent:@"touch_overlay_config.json"];
    NSString *mouseStr = (_mouseMode == 1) ? @"Trackpad" : ((_mouseMode == 2) ? @"Disabled" : @"PointAndClick");

    NSMutableDictionary *rootObj = nil;
    NSData *existingData = [NSData dataWithContentsOfFile:ovPath options:0 error:nil];
    if (existingData.length) {
        id parsed = [NSJSONSerialization JSONObjectWithData:existingData options:NSJSONReadingMutableContainers error:nil];
        if (![parsed isKindOfClass:NSMutableDictionary.class]) {
            NSData *san = stripJson5ForIOS14(existingData);
            parsed = [NSJSONSerialization JSONObjectWithData:san options:NSJSONReadingMutableContainers error:nil];
        }
        if ([parsed isKindOfClass:NSMutableDictionary.class]) {
            rootObj = (NSMutableDictionary *)parsed;
        }
    }
    if (!rootObj) rootObj = [NSMutableDictionary dictionary];

    // Preserve case-insensitive existing keys while keeping HotkeyKeys / HotkeyLabels JSON arrays 100% intact!
    NSDictionary<NSString *, id> *typedUpdates = @{
        @"Opacity": @(round(sdvClampf(_opacity, 0.15f, 1.00f) * 100.0) / 100.0),
        @"Scale": @(round(sdvClampf(_padScale, 0.50f, 2.00f) * 100.0) / 100.0),
        @"LeftHanded": @(_leftHanded),
        @"ShowKeyboardBtn": @(_showKeyboardBtn),
        @"ShowMenuBtn": @(_showMenuBtn),
        @"ShowHotkeyDrawerBtn": @(_showHotkeyDrawerBtn),
        @"MouseControlMode": mouseStr
    };
    for (NSString *uk in @[@"Opacity", @"Scale", @"LeftHanded", @"ShowKeyboardBtn", @"ShowMenuBtn", @"ShowHotkeyDrawerBtn", @"MouseControlMode"]) {
        NSString *matchKey = nil;
        for (id ek in rootObj.allKeys) {
            if ([ek isKindOfClass:NSString.class] && [(NSString *)ek caseInsensitiveCompare:uk] == NSOrderedSame) {
                matchKey = (NSString *)ek;
                break;
            }
        }
        rootObj[matchKey ?: uk] = typedUpdates[uk];
    }

    NSData *outJsonData = [NSJSONSerialization dataWithJSONObject:rootObj options:NSJSONWritingPrettyPrinted error:nil];
    if (outJsonData.length) {
        sdvPrepareWritableFileTarget(ovPath);
        [outJsonData writeToFile:ovPath options:NSDataWritingAtomic error:nil];
    }

    [self saveLiveCfgOnlyToDocuments:docsPath];
}

@end

// ---- Mobile Touch Controls Config (Documents/sdv_mobile_ctrl.cfg -> SDVMobileControls.dll) ----
@interface SDVCustomKeyEntry : NSObject
@property(nonatomic, assign) NSInteger keyId;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, assign) NSInteger keyCode;
@property(nonatomic, assign) float x, y, w, h;
@end
@implementation SDVCustomKeyEntry @end

@interface SDVMobileCtrlConfig : NSObject
@property(nonatomic, assign) NSInteger mode; // 0=Gamepad, 1=InvisibleJoy+2Btn, 2=VisibleJoy+2Btn, 3=TapToMove, 4=Hybrid
@property(nonatomic, assign) BOOL autoTool;
@property(nonatomic, assign) BOOL autoAttack; // Default OFF
@property(nonatomic, assign) BOOL pinchZoom;
@property(nonatomic, assign) BOOL showTouchHint; // Default OFF (no blinking)
@property(nonatomic, assign) BOOL showTopUtility;
@property(nonatomic, assign) BOOL swapRightButtons;
@property(nonatomic, assign) BOOL mobileShopAndDrag;
@property(nonatomic, assign) BOOL autoKeyboard;
@property(nonatomic, assign) BOOL safeCrafting;
@property(nonatomic, assign) NSInteger autoSaveMinutes; // 0=Off, 3, 5, 10
@property(nonatomic, assign) BOOL reduceWeather;
@property(nonatomic, assign) float uiScaleOverride; // 0 = game default, 0.75..1.50
@property(nonatomic, assign) float buttonScale;
@property(nonatomic, assign) BOOL showEmoteButton;
@property(nonatomic, assign) BOOL autoRepeat;
@property(nonatomic, assign) BOOL restoreToolAfterAuto;
@property(nonatomic, assign) BOOL showSpecButton;
@property(nonatomic, assign) BOOL autoCombatMode;
@property(nonatomic, assign) BOOL autoHideOnGamepad;
@property(nonatomic, assign) BOOL autoPauseOnBackground;
@property(nonatomic, assign) BOOL fishingHaptic;
@property(nonatomic, assign) NSInteger safePaddingPx; // -1 = Auto, 0..80 px
@property(nonatomic, assign) BOOL safeDialogueAndTooltip;
@property(nonatomic, assign) BOOL verticalToolbar;
@property(nonatomic, assign) float toolbarSize; // 0.55..1.50
@property(nonatomic, assign) float toolbarOpacity; // 0.20..1.00
@property(nonatomic, assign) NSInteger toolbarColumns; // 1..3
@property(nonatomic, assign) NSInteger toolbarVisibleRows; // 0=Auto, 4..12
@property(nonatomic, assign) NSInteger toolbarSide; // 0=Left, 1=Right
@property(nonatomic, assign) float toolbarY; // 0.0..1.0 (vertical position)
@property(nonatomic, assign) BOOL showToolHitLocation; // Default YES
@property(nonatomic, assign) NSInteger batterySaverFpsMode; // 0=60 FPS, 1=30 FPS, 2=45 FPS
@property(nonatomic, assign) BOOL menuFps30; // Default NO (60 FPS smooth in-game menus), YES = 30 FPS battery saver
@property(nonatomic, assign) BOOL auroraBackdrop; // Default YES (living Aurora backdrop in Mod Garden)
@property(nonatomic, assign) float pixelOpacity; // 0.25..1.00
@property(nonatomic, assign) BOOL leftHandedMobile;
@property(nonatomic, assign) float joyDeadzone; // 0.05..0.25
@property(nonatomic, assign) BOOL respectMuteSwitch;
@property(nonatomic, assign) BOOL pureGamepadMode;
@property(nonatomic, strong) NSMutableArray<SDVCustomKeyEntry *> *customKeys;

+(instancetype)defaults;
+(instancetype)loadFromDocuments:(NSString *)docsPath;
-(void)saveToDocuments:(NSString *)docsPath;
-(SDVCustomKeyEntry *)addCustomKeyLabel:(NSString *)label keyCode:(NSInteger)keyCode;
-(void)removeCustomKeyWithId:(NSInteger)keyId;
+(void)triggerEditLayoutInDocs:(NSString *)docsPath;
@end

@implementation SDVMobileCtrlConfig

+(instancetype)defaults {
    SDVMobileCtrlConfig *c = [SDVMobileCtrlConfig new];
    c.mode = 1;
    c.autoTool = YES;
    c.autoAttack = NO;
    c.pinchZoom = YES;
    c.showTouchHint = NO; // Default OFF (no flashing!)
    c.showTopUtility = YES;
    c.swapRightButtons = NO;
    c.mobileShopAndDrag = YES;
    c.autoKeyboard = YES;
    c.safeCrafting = YES;
    c.autoSaveMinutes = 0; // Default OFF (zero stutter while playing; user can pick 3/5/10 min)
    c.reduceWeather = NO; // Default OFF (keeps full rain/wind particles unless user enables optimization)
    c.uiScaleOverride = 0.0f; // 0 = game default
    c.buttonScale = 1.00f;
    c.showEmoteButton = YES;
    c.autoRepeat = YES;
    c.restoreToolAfterAuto = NO;
    c.showSpecButton = YES;
    c.autoCombatMode = NO;
    c.autoHideOnGamepad = YES;
    c.autoPauseOnBackground = YES;
    c.fishingHaptic = YES;
    c.safePaddingPx = -1; // -1 = Auto from iOS safeAreaInsets
    c.safeDialogueAndTooltip = YES;
    c.verticalToolbar = NO;
    c.toolbarSize = 1.00f;
    c.toolbarOpacity = 0.90f;
    c.toolbarColumns = 1;
    c.toolbarVisibleRows = 0;
    c.toolbarSide = 0;
    c.toolbarY = 0.50f;
    c.showToolHitLocation = YES;
    c.batterySaverFpsMode = 0;
    c.menuFps30 = NO;
    c.auroraBackdrop = YES;
    c.pixelOpacity = 1.00f;
    c.leftHandedMobile = NO;
    c.joyDeadzone = 0.11f;
    c.respectMuteSwitch = [NSUserDefaults.standardUserDefaults boolForKey:@"sdv_respect_mute_v1"];
    c.pureGamepadMode = NO;
    c.customKeys = [NSMutableArray array];
    return c;
}

+(instancetype)loadFromDocuments:(NSString *)docsPath {
    SDVMobileCtrlConfig *c = [self defaults];
    if (!docsPath.length) return c;
    NSString *gd = sdvHiddenGardenDir(docsPath);
    NSString *gpFlag = [gd stringByAppendingPathComponent:@"sdv_gamepad_only.flag"];
    BOOL flagOnDisk = [NSFileManager.defaultManager fileExistsAtPath:gpFlag];
    c.pureGamepadMode = flagOnDisk;
    NSString *p = [gd stringByAppendingPathComponent:@"sdv_mobile_ctrl.cfg"];
    NSString *raw = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (!raw.length) return c;
    for (NSString *line in [raw componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
        NSString *v = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([k isEqualToString:@"mode"]) {
            NSInteger m = v.integerValue;
            c.mode = (m >= 1 && m <= 4) ? m : 1;
        } else if ([k isEqualToString:@"autotool"]) {
            c.autoTool = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"autoattack"]) {
            c.autoAttack = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"pinchzoom"]) {
            c.pinchZoom = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"touchhint2"]) {
            c.showTouchHint = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"toputility"]) {
            c.showTopUtility = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"swapbuttons"]) {
            c.swapRightButtons = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"mobileshopdrag"]) {
            c.mobileShopAndDrag = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"autokeyboard"]) {
            c.autoKeyboard = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"safecrafting"]) {
            c.safeCrafting = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"autosavemin"]) {
            NSInteger am = v.integerValue;
            if (am == 0 || am == 3 || am == 5 || am == 10) c.autoSaveMinutes = am;
        } else if ([k isEqualToString:@"reduceweather"]) {
            c.reduceWeather = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"uiscale"]) {
            float us = v.floatValue;
            c.uiScaleOverride = (us >= 0.70f) ? sdvClampf(us, 0.75f, 1.50f) : 0.0f;
        } else if ([k isEqualToString:@"buttonscale"]) {
            c.buttonScale = sdvClampf(v.floatValue, 0.75f, 1.45f);
        } else if ([k isEqualToString:@"emotebtn"]) {
            c.showEmoteButton = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"autorepeat"]) {
            c.autoRepeat = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"restoretool"]) {
            c.restoreToolAfterAuto = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"specbtn"]) {
            c.showSpecButton = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"autocombatmode"]) {
            c.autoCombatMode = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"autohidegp"]) {
            c.autoHideOnGamepad = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"autopause"]) {
            c.autoPauseOnBackground = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"fishhaptic"]) {
            c.fishingHaptic = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"safepadding"]) {
            NSInteger sp = v.integerValue;
            c.safePaddingPx = (sp < 0) ? -1 : MAX(0, MIN(80, sp));
        } else if ([k isEqualToString:@"safedialogue"]) {
            c.safeDialogueAndTooltip = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"verticaltb"]) {
            c.verticalToolbar = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"tbsize"]) {
            c.toolbarSize = sdvClampf(v.floatValue, 0.55f, 1.50f);
        } else if ([k isEqualToString:@"tbopacity"]) {
            c.toolbarOpacity = sdvClampf(v.floatValue, 0.20f, 1.00f);
        } else if ([k isEqualToString:@"tbcols"]) {
            NSInteger tc = v.integerValue;
            c.toolbarColumns = MAX(1, MIN(3, tc));
        } else if ([k isEqualToString:@"tbrows"]) {
            NSInteger tr = v.integerValue;
            c.toolbarVisibleRows = (tr <= 0) ? 0 : MAX(4, MIN(12, tr));
        } else if ([k isEqualToString:@"tbside"]) {
            c.toolbarSide = (v.integerValue == 1) ? 1 : 0;
        } else if ([k isEqualToString:@"tby"]) {
            c.toolbarY = sdvClampf(v.floatValue, 0.0f, 1.0f);
        } else if ([k isEqualToString:@"toolhitbox"]) {
            c.showToolHitLocation = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"saver30fps"]) {
            NSString *lv = v.lowercaseString;
            if ([lv isEqualToString:@"2"] || [lv isEqualToString:@"45"]) c.batterySaverFpsMode = 2;
            else if ([lv isEqualToString:@"1"] || [lv isEqualToString:@"true"] || [lv isEqualToString:@"30"]) c.batterySaverFpsMode = 1;
            else c.batterySaverFpsMode = 0;
        } else if ([k isEqualToString:@"menufps30"]) {
            c.menuFps30 = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"aurora"]) {
            c.auroraBackdrop = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"pixelopacity"]) {
            c.pixelOpacity = sdvClampf(v.floatValue, 0.25f, 1.00f);
        } else if ([k isEqualToString:@"lefthanded"]) {
            c.leftHandedMobile = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"joydeadzone"]) {
            c.joyDeadzone = sdvClampf(v.floatValue, 0.05f, 0.25f);
        } else if ([k isEqualToString:@"respectmute"]) {
            c.respectMuteSwitch = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"puregamepad"]) {
            c.pureGamepadMode = ([v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]);
        } else if ([k isEqualToString:@"ckey"] && c.customKeys.count < 16) {
            NSArray<NSString *> *pts = [v componentsSeparatedByString:@"|"];
            if (pts.count >= 7 && pts[2].integerValue > 0) {
                SDVCustomKeyEntry *e = [SDVCustomKeyEntry new];
                e.keyId = pts[0].integerValue;
                e.label = pts[1].length ? pts[1] : @"KEY";
                e.keyCode = pts[2].integerValue;
                e.x = sdvClampf(pts[3].floatValue, 0.0f, 0.95f);
                e.y = sdvClampf(pts[4].floatValue, 0.0f, 0.92f);
                e.w = sdvClampf(pts[5].floatValue, 0.035f, 0.35f);
                e.h = sdvClampf(pts[6].floatValue, 0.050f, 0.45f);
                [c.customKeys addObject:e];
            }
        }
    }
    sdvSetAuroraBackdropEnabled(c.auroraBackdrop);
    return c;
}

-(SDVCustomKeyEntry *)addCustomKeyLabel:(NSString *)label keyCode:(NSInteger)keyCode {
    if (self.customKeys.count >= 16) return nil;
    NSInteger nextId = 1;
    for (SDVCustomKeyEntry *e in self.customKeys) {
        if (e.keyId >= nextId) nextId = e.keyId + 1;
    }
    float candX = 0.56f;
    float candY = 0.16f;
    for (NSInteger slot = 0; slot < 16; slot++) {
        NSInteger col = slot % 4;
        NSInteger row = slot / 4;
        float cx = sdvClampf(0.56f + col * 0.085f, 0.05f, 0.90f);
        float cy = sdvClampf(0.16f + row * 0.135f, 0.08f, 0.84f);
        BOOL overlap = NO;
        for (SDVCustomKeyEntry *ex in self.customKeys) {
            if (fabsf(ex.x - cx) < 0.045f && fabsf(ex.y - cy) < 0.065f) {
                overlap = YES;
                break;
            }
        }
        if (!overlap) {
            candX = cx;
            candY = cy;
            break;
        }
    }
    NSString *clean = [[label stringByReplacingOccurrencesOfString:@"|" withString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
    if (!clean.length) clean = @"KEY";
    if (clean.length > 6) clean = [clean substringToIndex:6];

    SDVCustomKeyEntry *e = [SDVCustomKeyEntry new];
    e.keyId = nextId;
    e.label = clean;
    e.keyCode = keyCode;
    e.x = candX;
    e.y = candY;
    e.w = 0.068f;
    e.h = 0.105f;
    [self.customKeys addObject:e];
    return e;
}

-(void)removeCustomKeyWithId:(NSInteger)keyId {
    for (NSInteger i = (NSInteger)self.customKeys.count - 1; i >= 0; i--) {
        if (self.customKeys[i].keyId == keyId) {
            [self.customKeys removeObjectAtIndex:i];
            break;
        }
    }
}

-(void)saveToDocuments:(NSString *)docsPath {
    if (!docsPath.length) return;
    [NSFileManager.defaultManager createDirectoryAtPath:docsPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *p = [sdvHiddenGardenDir(docsPath) stringByAppendingPathComponent:@"sdv_mobile_ctrl.cfg"];

    // Preserve custom Edit Layout coordinates (inv_*, vis_*, topbar_*) saved by SDVMobileControls.dll
    NSMutableArray<NSString *> *extraLines = [NSMutableArray array];
    NSString *existing = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (existing.length) {
        for (NSString *line in [existing componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *tr = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!tr.length) continue;
            if ([tr hasPrefix:@"inv_"] || [tr hasPrefix:@"vis_"] || [tr hasPrefix:@"topbar_"]) {
                [extraLines addObject:tr];
            }
        }
    }

    BOOL prevMute = [NSUserDefaults.standardUserDefaults boolForKey:@"sdv_respect_mute_v1"];
    if (self.respectMuteSwitch != prevMute) {
        [NSUserDefaults.standardUserDefaults setBool:self.respectMuteSwitch forKey:@"sdv_respect_mute_v1"];
        [NSNotificationCenter.defaultCenter postNotificationName:@"SDVAudioModeChangedNotification" object:nil];
    }

    NSMutableString *s = [NSMutableString stringWithFormat:
        @"mode=%ld\nautotool=%d\nautoattack=%d\npinchzoom=%d\ntouchhint2=%d\ntoputility=%d\nswapbuttons=%d\nmobileshopdrag=%d\nautokeyboard=%d\nsafecrafting=%d\nautosavemin=%ld\nreduceweather=%d\nuiscale=%.2f\nbuttonscale=%.2f\nemotebtn=%d\nautorepeat=%d\nrestoretool=%d\nspecbtn=%d\nautocombatmode=%d\nautohidegp=%d\nautopause=%d\nfishhaptic=%d\nsafepadding=%ld\nsafedialogue=%d\nverticaltb=%d\ntbsize=%.2f\ntbopacity=%.2f\ntbcols=%ld\ntbrows=%ld\ntbside=%ld\ntby=%.3f\ntoolhitbox=%d\nsaver30fps=%d\nmenufps30=%d\naurora=%d\npixelopacity=%.2f\nlefthanded=%d\njoydeadzone=%.2f\nrespectmute=%d\npuregamepad=%d\n",
        (long)MAX(1, MIN(4, self.mode)), self.autoTool ? 1 : 0, self.autoAttack ? 1 : 0,
        self.pinchZoom ? 1 : 0, self.showTouchHint ? 1 : 0,
        self.showTopUtility ? 1 : 0, self.swapRightButtons ? 1 : 0,
        self.mobileShopAndDrag ? 1 : 0, self.autoKeyboard ? 1 : 0,
        self.safeCrafting ? 1 : 0, (long)self.autoSaveMinutes,
        self.reduceWeather ? 1 : 0,
        (self.uiScaleOverride >= 0.70f) ? sdvClampf(self.uiScaleOverride, 0.75f, 1.50f) : 0.0f,
        sdvClampf(self.buttonScale, 0.75f, 1.45f),
        self.showEmoteButton ? 1 : 0, self.autoRepeat ? 1 : 0,
        self.restoreToolAfterAuto ? 1 : 0, self.showSpecButton ? 1 : 0,
        self.autoCombatMode ? 1 : 0, self.autoHideOnGamepad ? 1 : 0,
        self.autoPauseOnBackground ? 1 : 0, self.fishingHaptic ? 1 : 0,
        (long)self.safePaddingPx, self.safeDialogueAndTooltip ? 1 : 0,
        self.verticalToolbar ? 1 : 0,
        sdvClampf(self.toolbarSize, 0.55f, 1.50f),
        sdvClampf(self.toolbarOpacity, 0.20f, 1.00f),
        (long)MAX(1, MIN(3, self.toolbarColumns)),
        (long)(self.toolbarVisibleRows <= 0 ? 0 : MAX(4, MIN(12, self.toolbarVisibleRows))),
        (long)(self.toolbarSide == 1 ? 1 : 0),
        sdvClampf(self.toolbarY, 0.0f, 1.0f),
        self.showToolHitLocation ? 1 : 0,
        (int)MAX(0, MIN(2, self.batterySaverFpsMode)),
        self.menuFps30 ? 1 : 0,
        self.auroraBackdrop ? 1 : 0,
        sdvClampf(self.pixelOpacity, 0.25f, 1.00f), self.leftHandedMobile ? 1 : 0,
        sdvClampf(self.joyDeadzone, 0.05f, 0.25f), self.respectMuteSwitch ? 1 : 0,
        self.pureGamepadMode ? 1 : 0];
    sdvSetAuroraBackdropEnabled(self.auroraBackdrop);
    for (NSString *ex in extraLines) {
        [s appendFormat:@"%@\n", ex];
    }
    for (SDVCustomKeyEntry *e in self.customKeys) {
        [s appendFormat:@"ckey=%ld|%@|%ld|%.3f|%.3f|%.3f|%.3f\n",
            (long)e.keyId, e.label ?: @"KEY", (long)e.keyCode, e.x, e.y, e.w, e.h];
    }
    [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *gpFlag = [sdvHiddenGardenDir(docsPath) stringByAppendingPathComponent:@"sdv_gamepad_only.flag"];
    if (self.pureGamepadMode) {
        [@"1" writeToFile:gpFlag atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [NSFileManager.defaultManager removeItemAtPath:gpFlag error:nil];
    }
}

+(void)triggerEditLayoutInDocs:(NSString *)docsPath {
    if (!docsPath.length) return;
    NSString *flag = [sdvHiddenGardenDir(docsPath) stringByAppendingPathComponent:@"sdv_mobile_edit.flag"];
    [@"1" writeToFile:flag atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@end
