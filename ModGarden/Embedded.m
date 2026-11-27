#define GARDEN_IN_GAME 1
#import <AVFAudio/AVAudioSession.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <execinfo.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <os/lock.h>
#import "main.m"

// Self-contained compiler-rt helper for @available(...) when linking directly with LLVM ld64.lld
__attribute__((visibility("hidden")))
int32_t __isPlatformVersionAtLeast(uint32_t platform, uint32_t major, uint32_t minor, uint32_t subminor) {
    (void)platform;
    NSOperatingSystemVersion v = { (NSInteger)major, (NSInteger)minor, (NSInteger)subminor };
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:v] ? 1 : 0;
}

// ---- Native Boot & Crash Logger (always writes to Documents/ErrorLogs/ even on instant crash!) ----
static char gSdvBootLogPath[1024] = {0};
static char gSdvCrashLogPath[1024] = {0};
static char gSdvPauseFlagPath[1024] = {0};
static char gSdvHapticFlagPath[1024] = {0};
static char gSdvSafeAreaPath[1024] = {0};
static char gSdvBootReadyPath[1024] = {0};
static char gSdvBootStagePath[1024] = {0};
static char gSdvEngineLogPath[1024] = {0};
static char gSdvSmapiLogPath[1024] = {0};
static CFAbsoluteTime gSdvBootStartTime = 0;
static time_t gSdvBootStartEpoch = 0;
static char gSdvLastSafeAreaBuf[64] = {0};
static volatile sig_atomic_t gSdvCrashHandled = 0;
// Async-signal-safe 16-line boot/SMAPI ring buffer for native crash diagnostics (credit @Mudkip267)
static char gSdvRecentBootLines[16][256];
static volatile uint32_t gSdvRecentBootIdx = 0;

// ---- Live Real-Time Boot Progress Telemetry (fed directly on Main Thread by SDViOS.dll & SDVMobileControls!) ----
static os_unfair_lock gBootTelLock = OS_UNFAIR_LOCK_INIT;
static volatile int32_t gSdvBootDone = 0;
static volatile int32_t gSdvGardenOpenFlag = 0;
static volatile int32_t gSdvMultiplayerActive = 0;
static __weak CADisplayLink *gSdvGameDisplayLink = nil;
static BOOL gSdvPausedGameLinkForGarden = NO;

static void sdvApplyGameDisplayLinkPauseForGarden(BOOL gardenOpen) {
    CADisplayLink *dl = gSdvGameDisplayLink;
    if (!dl) return;
    if (gardenOpen) {
        if (gSdvBootDone && __atomic_load_n(&gSdvMultiplayerActive, __ATOMIC_RELAXED) == 0) {
            if (!dl.paused) {
                dl.paused = YES;
                gSdvPausedGameLinkForGarden = YES;
            }
        }
    } else {
        if (gSdvPausedGameLinkForGarden) {
            gSdvPausedGameLinkForGarden = NO;
            dl.paused = NO;
        }
    }
}

__attribute__((visibility("default")))
int32_t sdv_is_garden_open(void) {
    return __atomic_load_n(&gSdvGardenOpenFlag, __ATOMIC_RELAXED);
}

__attribute__((visibility("default")))
void sdv_register_game_display_link(void *dlPtr) {
    gSdvGameDisplayLink = dlPtr ? (__bridge CADisplayLink *)dlPtr : nil;
    if (gSdvGameDisplayLink && __atomic_load_n(&gSdvGardenOpenFlag, __ATOMIC_RELAXED) != 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            sdvApplyGameDisplayLinkPauseForGarden(__atomic_load_n(&gSdvGardenOpenFlag, __ATOMIC_RELAXED) != 0);
        });
    }
}

__attribute__((visibility("default")))
void sdv_set_multiplayer_active(int32_t isMp) {
    __atomic_store_n(&gSdvMultiplayerActive, isMp ? 1 : 0, __ATOMIC_RELAXED);
}
static volatile int32_t gBootSmapiStarted = 0;
static double gBootLivePct = 0.02;
static NSInteger gBootLiveStep = 0;
static NSString *gBootLiveStage = nil;
static NSString *gBootLiveDetail = nil;
static int32_t gBootModsCount = 0;
static int32_t gBootPacksCount = 0;
static int32_t gBootListedItems = 0;
static int32_t gBootPatchItems = 0;
static int32_t gBootEntryMods = 0;
static CFTimeInterval gBootLastPumpTime = 0.0;
static double gBootLastPumpedPct = 0.0;
static BOOL gBootInRunLoopPump = NO;

static void sdvBootPumpMainThreadNow(BOOL forceFlush);

static void sdvWriteRawFd(const char *path, const char *buf, size_t len) {
    if (!path || !path[0] || !buf || len == 0) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        (void)write(fd, buf, len);
        fsync(fd);
        close(fd);
    }
}

static void sdvBootLog(const char *msg) {
    if (!gSdvBootLogPath[0] || !msg) return;
    sdvWriteRawFd(gSdvBootLogPath, msg, strlen(msg));
    sdvWriteRawFd(gSdvBootLogPath, "\n", 1);
}

static void sdvBootLogFmt(NSString *line) {
    if (!line.length) return;
    const char *utf8 = line.UTF8String;
    if (utf8) sdvBootLog(utf8);
}

static void sdvSignalCrashHandler(int sig, siginfo_t *info, void *ucontext) {
    (void)ucontext;
    if (gSdvCrashHandled) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    gSdvCrashHandled = 1;
    int fd = open(gSdvCrashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        const char *hdr = "\n=== NATIVE SIGNAL CRASH ===\nSignal: ";
        (void)write(fd, hdr, strlen(hdr));
        char num[32];
        int n = 0;
        int v = sig;
        if (v < 0) { num[n++] = '-'; v = -v; }
        char rev[16]; int rn = 0;
        do { rev[rn++] = (char)('0' + (v % 10)); v /= 10; } while (v > 0 && rn < 15);
        while (rn > 0) num[n++] = rev[--rn];
        num[n++] = '\n';
        (void)write(fd, num, (size_t)n);
        if (info) {
            const char *ah = "Fault addr (hex): 0x";
            (void)write(fd, ah, strlen(ah));
            uintptr_t addr = (uintptr_t)info->si_addr;
            char hex[17];
            const char *hd = "0123456789abcdef";
            for (int i = 15; i >= 0; i--) { hex[15 - i] = hd[(addr >> (i * 4)) & 0xF]; }
            hex[16] = '\n';
            (void)write(fd, hex, 17);
        }
        const char *bh = "Backtrace:\n";
        (void)write(fd, bh, strlen(bh));
        void *frames[64];
        int count = backtrace(frames, 64);
        if (count > 0) backtrace_symbols_fd(frames, count, fd);
        uint32_t curIdx = __atomic_load_n(&gSdvRecentBootIdx, __ATOMIC_RELAXED);
        if (curIdx > 0) {
            const char *rh = "Recent Boot/SMAPI Logs:\n";
            (void)write(fd, rh, strlen(rh));
            uint32_t total = curIdx < 16 ? curIdx : 16;
            uint32_t start = curIdx - total;
            for (uint32_t k = 0; k < total; k++) {
                const char *line = gSdvRecentBootLines[(start + k) & 15u];
                size_t l = 0;
                while (l < 255 && line[l] != '\0') l++;
                if (l > 0) {
                    (void)write(fd, "  ", 2);
                    (void)write(fd, line, l);
                    (void)write(fd, "\n", 1);
                }
            }
        }
        fsync(fd);
        close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static NSUncaughtExceptionHandler *gPrevUncaughtHandler = NULL;
static void sdvUncaughtExceptionHandler(NSException *exception) {
    @try {
        NSString *txt = [NSString stringWithFormat:@"\n=== UNCAUGHT NSException ===\nName: %@\nReason: %@\nStack:\n%@\n",
            exception.name ?: @"?", exception.reason ?: @"?",
            [exception.callStackSymbols componentsJoinedByString:@"\n"] ?: @""];
        const char *u = txt.UTF8String;
        if (u) sdvWriteRawFd(gSdvCrashLogPath, u, strlen(u));
    } @catch (NSException *ignored) { }
    if (gPrevUncaughtHandler) gPrevUncaughtHandler(exception);
}

static NSString *sdvDeviceMachineModel(void) {
    size_t sz = 0;
    if (sysctlbyname("hw.machine", NULL, &sz, NULL, 0) != 0 || sz == 0 || sz > 128) return @"unknown";
    char buf[129] = {0};
    if (sysctlbyname("hw.machine", buf, &sz, NULL, 0) != 0) return @"unknown";
    return [NSString stringWithUTF8String:buf] ?: @"unknown";
}

static void sdvInitBootAndCrashLogging(NSString *docsPath) {
    if (!docsPath.length) return;
    @try {
        NSString *errDir = [docsPath stringByAppendingPathComponent:@"ErrorLogs"];
        [fm() createDirectoryAtPath:errDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *bootCur = [errDir stringByAppendingPathComponent:@"launcher-boot.log"];
        NSString *bootPrev = [errDir stringByAppendingPathComponent:@"launcher-boot-previous.log"];
        if ([fm() fileExistsAtPath:bootCur]) {
            [fm() removeItemAtPath:bootPrev error:nil];
            [fm() moveItemAtPath:bootCur toPath:bootPrev error:nil];
        }
        NSString *crashLog = [errDir stringByAppendingPathComponent:@"native-crash.log"];
        strlcpy(gSdvBootLogPath, bootCur.fileSystemRepresentation, sizeof(gSdvBootLogPath));
        strlcpy(gSdvCrashLogPath, crashLog.fileSystemRepresentation, sizeof(gSdvCrashLogPath));

        // Install Objective-C exception + POSIX signal handlers immediately
        gPrevUncaughtHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&sdvUncaughtExceptionHandler);

        int sigs[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE };
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = sdvSignalCrashHandler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
        for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
            sigaction(sigs[i], &sa, NULL);
        }

        NSString *osVer = NSProcessInfo.processInfo.operatingSystemVersionString ?: @"?";
        NSString *model = sdvDeviceMachineModel();
        double ramGB = (double)NSProcessInfo.processInfo.physicalMemory / (1024.0 * 1024.0 * 1024.0);
        NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"?";
        sdvBootLogFmt([NSString stringWithFormat:
            @"[BOOT 1] Garden Launcher %@ | iOS %@ | Device=%@ | RAM=%.2f GB | Bundle=%@",
            sdvEffectiveAppVersion(), osVer, model, ramGB, bid]);
    } @catch (NSException *ex) { }
}

// ---- Native iOS Audio Session Manager (Playback by default, or Ambient if user enables Respect Mute Switch!) ----
static void sdvEnsureAudioSession(const char *reason) {
    @try {
        AVAudioSession *s = AVAudioSession.sharedInstance;
        NSError *catErr = nil;
        NSError *actErr = nil;
        BOOL respectMute = [NSUserDefaults.standardUserDefaults boolForKey:@"sdv_respect_mute_v1"];
        AVAudioSessionCategory targetCat = respectMute ? AVAudioSessionCategoryAmbient : AVAudioSessionCategoryPlayback;
        [s setCategory:targetCat
                  mode:AVAudioSessionModeDefault
               options:AVAudioSessionCategoryOptionMixWithOthers
                 error:&catErr];
        [s setActive:YES error:&actErr];
        NSString *outPort = s.currentRoute.outputs.firstObject.portType ?: @"none";
        sdvBootLogFmt([NSString stringWithFormat:
            @"[AUDIO] %s | cat=%@ | out=%@ | vol=%.2f | catErr=%@ | actErr=%@",
            reason ?: "init", s.category ?: @"?", outPort, s.outputVolume,
            catErr ? catErr.localizedDescription : @"none",
            actErr ? actErr.localizedDescription : @"none"]);
    } @catch (NSException *ex) {
        sdvBootLogFmt([NSString stringWithFormat:@"[AUDIO] exception: %@", ex]);
    }
}

// ---- Home Indicator Deferral (keeps Home Bar dimmed, prevents waking bright on taps, requires 2 swipes to exit!) ----
static BOOL sdvPreferDimmedDeferredHomeIndicator(id self, SEL _cmd) { (void)self; (void)_cmd; return NO; }
static UIRectEdge sdvDeferAllSystemEdges(id self, SEL _cmd) { (void)self; (void)_cmd; return UIRectEdgeAll; }

static void sdvApplyAutoHideHomeIndicator(UIViewController *vc) {
    if (!vc) return;
    @try {
        Class cls = object_getClass(vc);
        if (!cls) return;
        NSString *cn = NSStringFromClass(cls);
        // CRITICAL for iOS 26/27: NEVER mutate Apple's system UIKit classes (UIViewController, UINavigationController, _UI*...)!
        if (cn.length && ![cn hasPrefix:@"UI"] && ![cn hasPrefix:@"_"]) {
            static NSMutableSet<NSString *> *patched;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{ patched = [NSMutableSet set]; });
            if (![patched containsObject:cn]) {
                [patched addObject:cn];
                class_replaceMethod(cls, @selector(prefersHomeIndicatorAutoHidden), (IMP)sdvPreferDimmedDeferredHomeIndicator, "B@:");
                class_replaceMethod(cls, @selector(preferredScreenEdgesDeferringSystemGestures), (IMP)sdvDeferAllSystemEdges, "Q@:");
            }
        }
        [vc setNeedsUpdateOfHomeIndicatorAutoHidden];
        [vc setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    } @catch (NSException *ex) { }
}

// ---- Native UIScene Lifecycle Support (iOS 14 – iOS 26 & iOS 27 Mandatory Scene Compliance) ----
@interface SDVSceneHostViewController : UIViewController
@end
@implementation SDVSceneHostViewController
-(void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.10 alpha:1.0];
}
-(BOOL)prefersStatusBarHidden { return YES; }
-(BOOL)prefersHomeIndicatorAutoHidden { return NO; }
-(UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
-(UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

@interface SDVSceneHostWindow : UIWindow
@end
@implementation SDVSceneHostWindow
@end

// ---- Transparent Toast / Banner VC (keeps Status Bar hidden & Home Indicator deferred on all iOS 14-27+) ----
@interface SDVOverlayToastController : UIViewController
@end
@implementation SDVOverlayToastController
-(void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.userInteractionEnabled = NO;
}
-(BOOL)prefersStatusBarHidden { return YES; }
-(BOOL)prefersHomeIndicatorAutoHidden { return NO; }
-(UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
-(UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end

// ---- Pass-through Overlay Window (never steals touches outside interactiveView) ----
@interface SDVPassThroughWindow : UIWindow
@property(nonatomic, weak) UIView *interactiveView;
@end

@implementation SDVPassThroughWindow
-(UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.interactiveView || self.interactiveView.hidden || self.interactiveView.alpha < 0.05) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit) return nil;
    return (hit == self.interactiveView || [hit isDescendantOfView:self.interactiveView]) ? hit : nil;
}
@end

// ---- Native iOS Frosted Glass Multi-Target Live UI HUD ----
@interface SDVLiveMenuBarController : UIViewController
@property(nonatomic, copy) NSString *docsPath;
@property(nonatomic, copy) void (^onDone)(void);
@property(nonatomic, readonly) UIView *capsuleView;
@end

@implementation SDVLiveMenuBarController {
    UIView *_capsuleShadow;
    UIVisualEffectView *_capsule;
    SDVUiConfig *_cfg;
    NSInteger _target; // 0=MenuBar, 1=XYAB, 2=LT/RT, 3=Stick, 4=SET/MODS
    UISegmentedControl *_seg;

    UILabel *_lbl1;
    UISlider *_sl1;
    UILabel *_val1;

    UILabel *_lbl2;
    UISlider *_sl2;
    UILabel *_val2;

    UIStackView *_menuBarRow;
    UILabel *_posBadge;

    UIStackView *_abxyRow;
    UISlider *_slSpacing;
    UILabel *_valSpacing;

    NSTimeInterval _lastSave;
}

-(UIView *)capsuleView { return _capsuleShadow; }
-(BOOL)prefersStatusBarHidden { return YES; }
-(BOOL)prefersHomeIndicatorAutoHidden { return NO; }
-(UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
-(UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

-(UISlider *)makeHudSliderWithTag:(NSInteger)tag tint:(UIColor *)tint {
    UISlider *s = [UISlider new];
    s.tag = tag;
    s.minimumTrackTintColor = tint;
    s.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.22];
    [s addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
    [s addTarget:self action:@selector(sliderDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return s;
}

-(void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _cfg = [SDVUiConfig loadFromDocuments:_docsPath];
    _target = 0;

    _capsuleShadow = [UIView new];
    _capsuleShadow.layer.shadowColor = UIColor.blackColor.CGColor;
    _capsuleShadow.layer.shadowOpacity = 0.42;
    _capsuleShadow.layer.shadowRadius = 16;
    _capsuleShadow.layer.shadowOffset = CGSizeMake(0, 6);
    _capsuleShadow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_capsuleShadow];

    _capsule = mkGlassCard(UIBlurEffectStyleSystemChromeMaterialDark, 18.0);
    [_capsuleShadow addSubview:_capsule];
    pinAll(_capsule, _capsuleShadow, 0);

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *widthPref = [_capsuleShadow.widthAnchor constraintEqualToConstant:610];
    widthPref.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [_capsuleShadow.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [_capsuleShadow.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [_capsuleShadow.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:12],
        [_capsuleShadow.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-12],
        widthPref
    ]];

    UIStackView *root = mkVStack(8);
    [_capsule.contentView addSubview:root];
    pinInsets(root, _capsule.contentView, UIEdgeInsetsMake(10, 12, 10, 12));

    // Row 1: Native Segmented Control + Reset + Done
    UIStackView *row1 = mkHStack(7);
    _seg = [[UISegmentedControl alloc] initWithItems:@[@"Menu Bar", @"XYAB", @"LT/RT", @"Stick", @"SET"]];
    _seg.selectedSegmentIndex = 0;
    [_seg addTarget:self action:@selector(targetChanged:) forControlEvents:UIControlEventValueChanged];
    [row1 addArrangedSubview:_seg];

    SDVAppleButton *resetBtn = mkIOSButton(@"", @"arrow.counterclockwise", [UIColor colorWithWhite:1.0 alpha:0.14], UIColor.whiteColor, 12.5, UIEdgeInsetsMake(6, 9, 6, 9));
    resetBtn.layer.cornerRadius = 9;
    [resetBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [resetBtn addTarget:self action:@selector(resetCurrentTarget) forControlEvents:UIControlEventTouchUpInside];
    [row1 addArrangedSubview:resetBtn];

    SDVAppleButton *doneBtn = mkIOSButton(@"Xong", @"checkmark", kTintBlue, UIColor.whiteColor, 13, UIEdgeInsetsMake(6, 12, 6, 12));
    doneBtn.layer.cornerRadius = 9;
    [doneBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [doneBtn addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
    [row1 addArrangedSubview:doneBtn];
    [root addArrangedSubview:row1];

    // Row 2: Two side-by-side native sliders
    UIStackView *row2 = mkHStack(8);
    _lbl1 = mkLabel(@"Cỡ", 12, UIFontWeightSemibold, UIColor.whiteColor);
    _lbl1.numberOfLines = 1;
    [_lbl1 setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _sl1 = [self makeHudSliderWithTag:1 tint:kTintBlue];
    _val1 = mkBadgePill(@"100%", [UIColor colorWithWhite:1.0 alpha:0.13], UIColor.whiteColor, 11);
    _val1.font = iosMonoDigits(11, UIFontWeightSemibold);

    UIView *sep = [UIView new];
    sep.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [sep.widthAnchor constraintEqualToConstant:0.5].active = YES;
    [sep.heightAnchor constraintEqualToConstant:18].active = YES;

    _lbl2 = mkLabel(@"Rõ", 12, UIFontWeightSemibold, UIColor.whiteColor);
    _lbl2.numberOfLines = 1;
    [_lbl2 setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _sl2 = [self makeHudSliderWithTag:2 tint:kTintGreen];
    _val2 = mkBadgePill(@"75%", [UIColor colorWithWhite:1.0 alpha:0.13], UIColor.whiteColor, 11);
    _val2.font = iosMonoDigits(11, UIFontWeightSemibold);

    [row2 addArrangedSubview:_lbl1];
    [row2 addArrangedSubview:_sl1];
    [row2 addArrangedSubview:_val1];
    [row2 addArrangedSubview:sep];
    [row2 addArrangedSubview:_lbl2];
    [row2 addArrangedSubview:_sl2];
    [row2 addArrangedSubview:_val2];
    [_sl1.widthAnchor constraintEqualToAnchor:_sl2.widthAnchor].active = YES;
    [root addArrangedSubview:row2];

    // Row 3A (Menu Bar extra): Quick presets + arrow nudgers
    _menuBarRow = mkHStack(5);
    _posBadge = mkLabel(@"L56 · T24", 11, UIFontWeightMedium, [UIColor colorWithWhite:1.0 alpha:0.75]);
    _posBadge.font = iosMonoDigits(11, UIFontWeightMedium);
    _posBadge.numberOfLines = 1;
    [_posBadge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_menuBarRow addArrangedSubview:_posBadge];

    NSArray *pTitles = @[@"75%", @"100%", @"135%", @"170%"];
    for (int i = 0; i < 4; i++) {
        SDVAppleButton *pb = mkIOSButton(pTitles[i], nil, [UIColor colorWithWhite:1.0 alpha:0.14], UIColor.whiteColor, 11.5, UIEdgeInsetsMake(4, 8, 4, 8));
        pb.layer.cornerRadius = 7.5;
        pb.tag = 200 + i;
        [pb addTarget:self action:@selector(menuPresetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_menuBarRow addArrangedSubview:pb];
    }
    [_menuBarRow addArrangedSubview:[UIView new]];

    NSArray *arrows = @[@"chevron.left", @"chevron.right", @"chevron.up", @"chevron.down"];
    for (int i = 0; i < 4; i++) {
        SDVAppleButton *ab = mkIOSButton(@"", arrows[i], [UIColor colorWithWhite:1.0 alpha:0.16], UIColor.whiteColor, 11.5, UIEdgeInsetsMake(5, 8, 5, 8));
        ab.layer.cornerRadius = 7.5;
        ab.tag = 300 + i;
        [ab addTarget:self action:@selector(nudgePos:) forControlEvents:UIControlEventTouchUpInside];
        [_menuBarRow addArrangedSubview:ab];
    }
    [root addArrangedSubview:_menuBarRow];

    // Row 3B (XYAB extra): Spacing slider + opacity presets
    _abxyRow = mkHStack(6);
    UILabel *spLbl = mkLabel(@"Giãn", 12, UIFontWeightSemibold, UIColor.whiteColor);
    spLbl.numberOfLines = 1;
    [spLbl setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _slSpacing = [self makeHudSliderWithTag:3 tint:kTintOrange];
    _slSpacing.minimumValue = 0.60f;
    _slSpacing.maximumValue = 1.80f;
    _valSpacing = mkBadgePill(@"100%", [UIColor colorWithWhite:1.0 alpha:0.13], UIColor.whiteColor, 11);
    _valSpacing.font = iosMonoDigits(11, UIFontWeightSemibold);

    [_abxyRow addArrangedSubview:spLbl];
    [_abxyRow addArrangedSubview:_slSpacing];
    [_abxyRow addArrangedSubview:_valSpacing];

    NSArray *opTitles = @[@"15%", @"40%", @"70%", @"100%"];
    for (int i = 0; i < 4; i++) {
        SDVAppleButton *ob = mkIOSButton(opTitles[i], nil, [UIColor colorWithWhite:1.0 alpha:0.14], UIColor.whiteColor, 11.5, UIEdgeInsetsMake(4, 7, 4, 7));
        ob.layer.cornerRadius = 7.5;
        ob.tag = 400 + i;
        [ob addTarget:self action:@selector(abxyOpacityPresetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_abxyRow addArrangedSubview:ob];
    }
    [root addArrangedSubview:_abxyRow];

    [self syncTargetUI];
}

-(void)syncTargetUI {
    _menuBarRow.hidden = (_target != 0);
    _abxyRow.hidden = (_target != 1);

    switch (_target) {
        case 0:
            _lbl1.text = @"Cỡ";
            _sl1.minimumValue = 0.55f; _sl1.maximumValue = 2.20f; _sl1.value = _cfg.menuBarScale;
            _lbl2.text = @"Rõ";
            _sl2.minimumValue = 0.10f; _sl2.maximumValue = 1.00f; _sl2.value = _cfg.menuBarOpacity;
            break;
        case 1:
            _lbl1.text = @"Cỡ";
            _sl1.minimumValue = 0.50f; _sl1.maximumValue = 2.20f; _sl1.value = _cfg.abxyScale;
            _lbl2.text = @"Rõ";
            _sl2.minimumValue = 0.05f; _sl2.maximumValue = 1.00f; _sl2.value = _cfg.abxyOpacity;
            _slSpacing.value = _cfg.abxySpacing;
            break;
        case 2:
            _lbl1.text = @"Cỡ";
            _sl1.minimumValue = 0.50f; _sl1.maximumValue = 2.20f; _sl1.value = _cfg.trigScale;
            _lbl2.text = @"Rõ";
            _sl2.minimumValue = 0.05f; _sl2.maximumValue = 1.00f; _sl2.value = _cfg.trigOpacity;
            break;
        case 3:
            _lbl1.text = @"Cỡ";
            _sl1.minimumValue = 0.50f; _sl1.maximumValue = 2.20f; _sl1.value = _cfg.joyScale;
            _lbl2.text = @"Rõ";
            _sl2.minimumValue = 0.05f; _sl2.maximumValue = 1.00f; _sl2.value = _cfg.joyOpacity;
            break;
        case 4:
            _lbl1.text = @"SET";
            _sl1.minimumValue = 1.00f; _sl1.maximumValue = 2.00f; _sl1.value = _cfg.modalScale;
            _lbl2.text = @"MODS";
            _sl2.minimumValue = 0.80f; _sl2.maximumValue = 2.00f; _sl2.value = _cfg.drawerScale;
            break;
    }
    [self refreshReadout];
}

-(void)refreshReadout {
    _val1.text = [NSString stringWithFormat:@"  %d%%  ", (int)roundf(_sl1.value * 100)];
    _val2.text = [NSString stringWithFormat:@"  %d%%  ", (int)roundf(_sl2.value * 100)];
    _posBadge.text = [NSString stringWithFormat:@"L%d · T%d", (int)roundf(_cfg.menuBarLeftX), (int)roundf(_cfg.menuBarTopY)];
    _valSpacing.text = [NSString stringWithFormat:@"  %d%%  ", (int)roundf(_cfg.abxySpacing * 100)];
}

-(void)targetChanged:(UISegmentedControl *)seg {
    _target = seg.selectedSegmentIndex;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self syncTargetUI];
}

-(void)applySliderValue:(UISlider *)s {
    float q = roundf(s.value * 20.0f) / 20.0f;
    if (s.tag == 3) {
        _cfg.abxySpacing = sdvClampf(q, 0.60f, 1.80f);
        return;
    }
    switch (_target) {
        case 0:
            if (s.tag == 1) _cfg.menuBarScale   = sdvClampf(q, 0.55f, 2.20f);
            else            _cfg.menuBarOpacity = sdvClampf(q, 0.10f, 1.00f);
            break;
        case 1:
            if (s.tag == 1) _cfg.abxyScale   = sdvClampf(q, 0.50f, 2.20f);
            else            _cfg.abxyOpacity = sdvClampf(q, 0.05f, 1.00f);
            break;
        case 2:
            if (s.tag == 1) _cfg.trigScale   = sdvClampf(q, 0.50f, 2.20f);
            else            _cfg.trigOpacity = sdvClampf(q, 0.05f, 1.00f);
            break;
        case 3:
            if (s.tag == 1) _cfg.joyScale   = sdvClampf(q, 0.50f, 2.20f);
            else            _cfg.joyOpacity = sdvClampf(q, 0.05f, 1.00f);
            break;
        case 4:
            if (s.tag == 1) _cfg.modalScale  = sdvClampf(q, 1.00f, 2.00f);
            else            _cfg.drawerScale = sdvClampf(q, 0.80f, 2.00f);
            break;
    }
}

-(void)commitNow {
    [_cfg saveLiveCfgOnlyToDocuments:_docsPath];
    [self syncTargetUI];
}

-(void)sliderMoved:(UISlider *)s {
    [self applySliderValue:s];
    [self refreshReadout];
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (now - _lastSave > 0.08) {
        _lastSave = now;
        [_cfg saveLiveCfgOnlyToDocuments:_docsPath];
    }
}

-(void)sliderDone:(UISlider *)s {
    [self applySliderValue:s];
    [self commitNow];
}

-(void)menuPresetTapped:(UIButton *)b {
    float vals[4] = {0.75f, 1.00f, 1.35f, 1.70f};
    NSInteger idx = b.tag - 200;
    if (idx < 0 || idx > 3) return;
    _cfg.menuBarScale = vals[idx];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self commitNow];
}

-(void)abxyOpacityPresetTapped:(UIButton *)b {
    float vals[4] = {0.15f, 0.40f, 0.70f, 1.00f};
    NSInteger idx = b.tag - 400;
    if (idx < 0 || idx > 3) return;
    _cfg.abxyOpacity = vals[idx];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self commitNow];
}

-(void)nudgePos:(UIButton *)b {
    switch (b.tag - 300) {
        case 0: _cfg.menuBarLeftX = sdvClampf(_cfg.menuBarLeftX - 12.0f, 8.0f, 240.0f); break;
        case 1: _cfg.menuBarLeftX = sdvClampf(_cfg.menuBarLeftX + 12.0f, 8.0f, 240.0f); break;
        case 2: _cfg.menuBarTopY  = sdvClampf(_cfg.menuBarTopY  - 8.0f,  4.0f, 160.0f); break;
        case 3: _cfg.menuBarTopY  = sdvClampf(_cfg.menuBarTopY  + 8.0f,  4.0f, 160.0f); break;
    }
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self commitNow];
}

-(void)resetCurrentTarget {
    switch (_target) {
        case 0:
            _cfg.menuBarScale   = 1.00f;
            _cfg.menuBarLeftX   = 56.0f;
            _cfg.menuBarTopY    = 24.0f;
            _cfg.menuBarGap     = 8.0f;
            _cfg.menuBarOpacity = 0.75f;
            break;
        case 1:
            _cfg.abxyScale   = 1.00f;
            _cfg.abxySpacing = 1.00f;
            _cfg.abxyOpacity = 0.70f;
            break;
        case 2:
            _cfg.trigScale   = 1.00f;
            _cfg.trigOpacity = 0.70f;
            break;
        case 3:
            _cfg.joyScale   = 1.00f;
            _cfg.joyOpacity = 0.65f;
            break;
        case 4:
            _cfg.modalScale  = 1.55f;
            _cfg.drawerScale = 1.35f;
            break;
    }
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self commitNow];
}

-(void)doneTapped {
    [self commitNow];
    if (self.onDone) self.onDone();
}
@end

// ---- Floating Draggable Apple Glass RAM & FPS Pill HUD ----
@interface SDVRamHudController : UIViewController
@property(nonatomic, readonly) UIView *badgeView;
-(void)stopMonitoring;
-(void)setMonitoringPaused:(BOOL)paused;
@end

@implementation SDVRamHudController {
    UIVisualEffectView *_badge;
    UIView *_led;
    UILabel *_lbl;
    NSLayoutConstraint *_centerXC;
    NSLayoutConstraint *_topC;
    CGPoint _panStart;
    CADisplayLink *_link;
    CFTimeInterval _lastFpsStamp;
    NSInteger _frames;
    NSInteger _fps;
    NSString *_mobileCfgPath;
    time_t _lastCfgMtime;
    NSInteger _ecoFpsMode; // 0=60, 1=30, 2=45
}

-(UIView *)badgeView { return _badge; }
-(BOOL)prefersStatusBarHidden { return YES; }
-(BOOL)prefersHomeIndicatorAutoHidden { return NO; }
-(UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
-(UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

-(void)dealloc {
    [self stopMonitoring];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

-(void)stopMonitoring {
    [_link invalidate];
    _link = nil;
}

-(void)setMonitoringPaused:(BOOL)paused {
    if (!_link) return;
    if (!paused && _link.paused) {
        _frames = 0;
        _lastFpsStamp = CACurrentMediaTime();
    }
    _link.paused = paused;
}

-(void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    _badge = mkGlassCard(UIBlurEffectStyleSystemUltraThinMaterialDark, 12.5);
    _badge.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_badge];

    UIStackView *row = mkHStack(6);
    _led = [UIView new];
    _led.backgroundColor = kTintGreen;
    _led.layer.cornerRadius = 3.5;
    _led.translatesAutoresizingMaskIntoConstraints = NO;
    [_led.widthAnchor constraintEqualToConstant:7].active = YES;
    [_led.heightAnchor constraintEqualToConstant:7].active = YES;

    _lbl = mkLabel(@"RAM --M · Dư --G · --FPS", 11, UIFontWeightSemibold, UIColor.whiteColor);
    _lbl.font = iosMonoDigits(11, UIFontWeightSemibold);
    _lbl.numberOfLines = 1;
    [row addArrangedSubview:_led];
    [row addArrangedSubview:_lbl];
    [_badge.contentView addSubview:row];
    pinInsets(row, _badge.contentView, UIEdgeInsetsMake(4.5, 9, 4.5, 9));

    CGPoint saved = [SDVRamMonitor.shared savedHudOffset];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    _centerXC = [_badge.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor constant:saved.x];
    _topC = [_badge.topAnchor constraintEqualToAnchor:safe.topAnchor constant:MAX(3.0, 5.0 + saved.y)];
    [NSLayoutConstraint activateConstraints:@[_centerXC, _topC]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [_badge addGestureRecognizer:pan];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resetPos) name:kSDVRamHudResetPosNotification object:nil];

    _fps = 60;
    _lastFpsStamp = CACurrentMediaTime();
    NSString *docsDir = [fm() URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
    _mobileCfgPath = docsDir.length ? [sdvHiddenGardenDir(docsDir) stringByAppendingPathComponent:@"sdv_mobile_ctrl.cfg"] : nil;
    _lastCfgMtime = 0;
    _ecoFpsMode = 0;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self refreshLabel];
}

-(void)resetPos {
    _centerXC.constant = 0;
    _topC.constant = 5.0;
}

-(void)handlePan:(UIPanGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) {
        _panStart = CGPointMake(_centerXC.constant, _topC.constant);
    } else if (gr.state == UIGestureRecognizerStateChanged || gr.state == UIGestureRecognizerStateEnded) {
        CGPoint t = [gr translationInView:self.view];
        CGRect safe = self.view.safeAreaLayoutGuide.layoutFrame;
        CGFloat halfW = MAX(40.0, safe.size.width * 0.5 - _badge.bounds.size.width * 0.5 - 6.0);
        CGFloat maxY = MAX(6.0, safe.size.height - _badge.bounds.size.height - 6.0);
        CGFloat nx = MAX(-halfW, MIN(halfW, _panStart.x + t.x));
        CGFloat ny = MAX(3.0, MIN(maxY, _panStart.y + t.y));
        _centerXC.constant = nx;
        _topC.constant = ny;
        if (gr.state == UIGestureRecognizerStateEnded) {
            [SDVRamMonitor.shared saveHudOffset:CGPointMake(nx, ny - 5.0)];
        }
    }
}

-(void)onFrame:(CADisplayLink *)link {
    _frames++;
    CFTimeInterval now = link.timestamp;
    CFTimeInterval dt = now - _lastFpsStamp;
    if (dt >= 0.75) {
        _fps = (NSInteger)llround((double)_frames / dt);
        _frames = 0;
        _lastFpsStamp = now;
        [self refreshLabel];
    }
}

-(void)syncEcoFpsMode {
    if (!_mobileCfgPath.length) return;
    struct stat st;
    if (stat(_mobileCfgPath.fileSystemRepresentation, &st) != 0) return;
    if (st.st_mtime == _lastCfgMtime) return;
    _lastCfgMtime = st.st_mtime;
    NSString *raw = [NSString stringWithContentsOfFile:_mobileCfgPath encoding:NSUTF8StringEncoding error:nil];
    if ([raw containsString:@"saver30fps=2"]) _ecoFpsMode = 2;
    else if ([raw containsString:@"saver30fps=1"]) _ecoFpsMode = 1;
    else _ecoFpsMode = 0;
}

-(void)refreshLabel {
    [self syncEcoFpsMode];
    SDVRamSnapshot s = [SDVRamMonitor.shared sample];
    UIColor *ledCol = (s.usagePct >= 90.0) ? kTintRed : ((s.usagePct >= 85.0) ? kTintOrange : kTintGreen);
    _led.backgroundColor = ledCol;
    _lbl.textColor = (s.usagePct >= 90.0) ? rgb(0xFF8A80) : ((s.usagePct >= 85.0) ? rgb(0xFFD180) : UIColor.whiteColor);
    if (_ecoFpsMode == 1) {
        NSInteger dispFps = (_fps >= 40) ? (_fps / 2) : _fps;
        _lbl.text = [NSString stringWithFormat:@"RAM %@ · Dư %@ · %ldFPS Eco",
            sdvFmtMemCompact(s.usedBytes), sdvFmtMemCompact(s.availBytes), (long)dispFps];
    } else if (_ecoFpsMode == 2) {
        NSInteger dispFps = (_fps >= 50) ? ((_fps * 3) / 4) : _fps;
        _lbl.text = [NSString stringWithFormat:@"RAM %@ · Dư %@ · %ldFPS Eco",
            sdvFmtMemCompact(s.usedBytes), sdvFmtMemCompact(s.availBytes), (long)dispFps];
    } else {
        _lbl.text = [NSString stringWithFormat:@"RAM %@ · Dư %@ · %ldFPS",
            sdvFmtMemCompact(s.usedBytes), sdvFmtMemCompact(s.availBytes), (long)_fps];
    }
}
@end

// ---- Stardew Valley × Garden Launcher Startup Loading Screen (GPU CoreAnimation 60fps, 0 MB after fade-out) ----
static UIImage *sdvMakeSoftGlowImage(CGSize size, UIColor *coreColor, UIColor *midColor) {
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSArray *cols = @[
            (id)coreColor.CGColor,
            (id)midColor.CGColor,
            (id)[midColor colorWithAlphaComponent:0.0].CGColor
        ];
        CGFloat locs[] = {0.0, 0.42, 1.0};
        CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols, locs);
        CGPoint center = CGPointMake(size.width * 0.5, size.height * 0.5);
        CGContextSaveGState(c);
        CGContextTranslateCTM(c, center.x, center.y);
        CGContextScaleCTM(c, 1.0, size.height / MAX(1.0, size.width));
        CGContextDrawRadialGradient(c, g, CGPointZero, 0.0, CGPointZero, size.width * 0.5, kCGGradientDrawsBeforeStartLocation);
        CGContextRestoreGState(c);
        CGGradientRelease(g);
        CGColorSpaceRelease(cs);
    }];
}

static UIImage *sdvMakePixelSparkleStarImage(CGSize size, UIColor *coreColor, UIColor *glowColor) {
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGFloat w = size.width, h = size.height;
        CGPoint ctr = CGPointMake(w * 0.5, h * 0.5);
        // Subtle halo behind pixel 4-point star
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSArray *cols = @[(id)[glowColor colorWithAlphaComponent:0.55].CGColor, (id)[glowColor colorWithAlphaComponent:0.0].CGColor];
        CGFloat locs[] = {0.0, 1.0};
        CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols, locs);
        CGContextDrawRadialGradient(c, g, ctr, 0, ctr, MIN(w, h) * 0.48, kCGGradientDrawsBeforeStartLocation);
        CGGradientRelease(g);
        CGColorSpaceRelease(cs);

        // Crisp pixel-art 4-point diamond cross
        CGFloat p = MAX(1.5, floor(MIN(w, h) / 7.0));
        CGContextSetFillColorWithColor(c, coreColor.CGColor);
        CGContextFillRect(c, CGRectMake(ctr.x - p * 0.5, ctr.y - p * 2.5, p, p * 5.0));
        CGContextFillRect(c, CGRectMake(ctr.x - p * 2.5, ctr.y - p * 0.5, p * 5.0, p));
        CGContextSetFillColorWithColor(c, UIColor.whiteColor.CGColor);
        CGContextFillRect(c, CGRectMake(ctr.x - p * 0.5, ctr.y - p * 0.5, p, p));
    }];
}

// Authentic 16-Bit Stardew Valley Pixel-Art Wooden Loading Frame, Segmented RPG Bar, Hopping Junimo & Milestone Stepper
static inline void sdvFillPx(CGContextRef c, CGFloat x, CGFloat y, CGFloat w, CGFloat h, UIColor *col) {
    CGContextSetFillColorWithColor(c, col.CGColor);
    CGContextFillRect(c, CGRectMake(floor(x), floor(y), floor(w), floor(h)));
}

static void sdvDrawPixelSprite(CGContextRef c, CGFloat ox, CGFloat oy, CGFloat p, const char **rows, int rowCount, BOOL flipX) {
    for (int r = 0; r < rowCount; r++) {
        const char *row = rows[r];
        int len = (int)strlen(row);
        for (int col = 0; col < len; col++) {
            char ch = row[flipX ? (len - 1 - col) : col];
            UIColor *fill = nil;
            if (ch == 'K') fill = rgb(0x13380E);      // dark pixel leaf/junimo outline
            else if (ch == 'G') fill = rgb(0x34A832); // emerald leaf body
            else if (ch == 'L') fill = rgb(0x9EF25E); // sunlit lime pixel highlight
            else if (ch == 'S') fill = rgb(0x288424); // deep forest emerald shade
            else if (ch == 'D') fill = rgb(0x2B1104); // dark oak outline
            else if (ch == 'Y') fill = rgb(0xFFD654); // golden diamond / flower fill
            else if (ch == 'O') fill = rgb(0xD97E1E); // shaded gold facet
            else if (ch == 'W') fill = rgb(0xFFFBE0); // bright glint pixel
            else if (ch == 'P') fill = rgb(0xFFA6C8); // wildflower sakura pink
            else if (ch == 'R') fill = rgb(0xE8638E); // deep pink petal
            else if (ch == 'B') fill = rgb(0xFF98A8); // cute rosy junimo cheek
            else if (ch == 'E') fill = rgb(0x140A05); // crisp dark eye pixel
            else if (ch == 'T') fill = rgb(0x784418); // tiny leaf stem
            else if (ch == 'J') fill = rgb(0x55D444); // bright apple-green junimo body
            else if (ch == 'H') fill = rgb(0xC6FF7A); // sunlit top junimo highlight
            if (fill) {
                sdvFillPx(c, ox + col * p, oy + r * p, p, p, fill);
            }
        }
    }
}

static UIImage *sdvMakePixelJunimoImage(BOOL hopFrame) {
    static const char *standRows[] = {
        ".....KK.....",
        "....KYLK....",
        ".....TK.....",
        "...KKKKKK...",
        "..KHHJJJJK..",
        ".KHJJJJJJJK.",
        "KKJJEJJEJJKK",
        ".KJJBJJBJJK.",
        ".KJJSSSSJJK.",
        "..KSSSSSSK..",
        "...KK..KK...",
        "............"
    };
    static const char *hopRows[] = {
        "....KYLK....",
        ".....TK.....",
        "...KKKKKK...",
        "..KHHJJJJK..",
        "KKHJJJJJJJKK",
        ".KJJEJJEJJK.",
        ".KJJBJJBJJK.",
        ".KJJSSSSJJK.",
        "..KSSSSSSK..",
        "...KKKKKK...",
        "....K..K....",
        "............"
    };
    CGFloat p = 2.0;
    CGSize sz = CGSizeMake(12.0 * p, 12.0 * p);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextSetShouldAntialias(c, false);
        sdvDrawPixelSprite(c, 0, 0, p, hopFrame ? hopRows : standRows, 12, NO);
    }];
}

static UIImage *sdvMakePixelBirdImage(BOOL wingsUp) {
    static const char *upRows[] = {
        "WW.....WW",
        ".WW...WW.",
        "..WWWWW..",
        "...CCC...",
        "........."
    };
    static const char *dnRows[] = {
        ".........",
        "..WWWWW..",
        ".WWCCCWW.",
        "WW.....WW",
        "........."
    };
    CGFloat p = 2.0;
    CGSize sz = CGSizeMake(9.0 * p, 5.0 * p);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextSetShouldAntialias(c, false);
        const char **rows = wingsUp ? upRows : dnRows;
        for (int y = 0; y < 5; y++) {
            for (int x = 0; x < 9; x++) {
                char ch = rows[y][x];
                if (ch == 'W') sdvFillPx(c, x * p, y * p, p, p, [rgb(0xFFFDF5) colorWithAlphaComponent:0.92]);
                else if (ch == 'C') sdvFillPx(c, x * p, y * p, p, p, [rgb(0xB8DCFF) colorWithAlphaComponent:0.86]);
            }
        }
    }];
}

static UIImage *sdvMakePixelCloudImage(NSInteger variant) {
    static const char *cloudA[] = {
        "........WWWWWW........",
        ".....WWWWWWWWWWWW.....",
        "...WWWWWWWWWWWWWWWW...",
        ".WWWWWWWWWWWWWWWWWWWW.",
        "WWWWWWWWWWWWWWWWWWWWWW",
        "WWCCCCCCCCCCCCCCCCCCWW",
        ".CCCCCCCCCCCCCCCCCCCC."
    };
    static const char *cloudB[] = {
        ".....WWWWW......",
        "...WWWWWWWWW....",
        ".WWWWWWWWWWWWW..",
        "WWWWWWWWWWWWWWWW",
        ".CCCCCCCCCCCCCC."
    };
    const char **rows = (variant == 0) ? cloudA : cloudB;
    int rowCnt = (variant == 0) ? 7 : 5;
    int colCnt = (int)strlen(rows[0]);
    CGFloat p = (variant == 0) ? 3.0 : 2.5;
    CGSize sz = CGSizeMake(colCnt * p, rowCnt * p);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextSetShouldAntialias(c, false);
        for (int y = 0; y < rowCnt; y++) {
            for (int x = 0; x < colCnt; x++) {
                char ch = rows[y][x];
                if (ch == 'W') sdvFillPx(c, x * p, y * p, p, p, [rgb(0xF6FBFF) colorWithAlphaComponent:0.78]);
                else if (ch == 'C') sdvFillPx(c, x * p, y * p, p, p, [rgb(0xC2E2FA) colorWithAlphaComponent:0.72]);
            }
        }
    }];
}

@interface SDVPixelBadgeView : UIView
@end

@implementation SDVPixelBadgeView
-(instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}
-(void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetShouldAntialias(c, false);
    CGFloat p = 2.0;
    CGFloat w = floor(self.bounds.size.width / p) * p;
    CGFloat h = floor(self.bounds.size.height / p) * p;
    if (w < 16 || h < 12) return;

    // Stepped-corner dark oak outer silhouette
    sdvFillPx(c, p, 0, w - 2*p, h, rgb(0x2B1104));
    sdvFillPx(c, 0, p, w, h - 2*p, rgb(0x2B1104));
    // Golden-oak pixel border
    sdvFillPx(c, p, p, w - 2*p, h - 2*p, rgb(0xD67B1C));
    sdvFillPx(c, 2*p, p, w - 4*p, p, rgb(0xFFD25A));          // top bright highlight
    sdvFillPx(c, p, 2*p, p, h - 4*p, rgb(0xF09B22));          // left warm highlight
    sdvFillPx(c, 2*p, h - 2*p, w - 4*p, p, rgb(0x853908));    // bottom shadow
    // Dark night-sky pixel interior
    sdvFillPx(c, 2*p, 2*p, w - 4*p, h - 4*p, [rgb(0x190E30) colorWithAlphaComponent:0.90]);
    sdvFillPx(c, 2*p, 2*p, w - 4*p, p, [rgb(0x0E071D) colorWithAlphaComponent:0.85]);
}
@end

@interface SDVPixelBarTrackView : UIView
@end

@implementation SDVPixelBarTrackView
-(instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}
-(void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetShouldAntialias(c, false);
    CGFloat p = 2.0;
    CGFloat w = floor(self.bounds.size.width / p) * p;
    CGFloat h = floor(self.bounds.size.height / p) * p;
    if (w < 24 || h < 14) return;

    // Stepped-pixel recessed trough border
    sdvFillPx(c, p, 0, w - 2*p, h, rgb(0x2B1104));
    sdvFillPx(c, 0, p, w, h - 2*p, rgb(0x2B1104));
    // Carved inner wooden bezel (shadow top/left, golden catchlight bottom/right!)
    sdvFillPx(c, p, p, w - 2*p, p, rgb(0x522108));
    sdvFillPx(c, p, p, p, h - 2*p, rgb(0x522108));
    sdvFillPx(c, p, h - 2*p, w - 2*p, p, rgb(0xD4832A));
    sdvFillPx(c, w - 2*p, p, p, h - 2*p, rgb(0xA65A18));
    // Deep warm-walnut pixel interior bed
    CGFloat ix = 2*p, iy = 2*p, iw = w - 4*p, ih = h - 4*p;
    sdvFillPx(c, ix, iy, iw, ih, rgb(0x160A04));
    sdvFillPx(c, ix, iy, iw, p, rgb(0x0B0401));

    // Subtle 16-bit checkerboard dither texture along empty bed
    UIColor *dith = [rgb(0x271308) colorWithAlphaComponent:0.58];
    for (CGFloat tx = ix + p; tx < ix + iw - p; tx += 4*p) {
        sdvFillPx(c, tx, iy + 2*p, p, p, dith);
        if (ih > 5*p) sdvFillPx(c, tx + 2*p, iy + 4*p, p, p, dith);
    }

    // Crisp 10pt pixel cell dividers along empty trough
    UIColor *cellLine = [rgb(0x33190B) colorWithAlphaComponent:0.70];
    for (CGFloat sx = ix + 10.0; sx < ix + iw - 2.0; sx += 10.0) {
        sdvFillPx(c, sx, iy, p, ih, cellLine);
    }

    // Golden quartile milestone pips at 25%, 50%, 75% on top & bottom bezel!
    UIColor *pipCol = rgb(0xFFE07D);
    for (int q = 1; q <= 3; q++) {
        CGFloat qx = floor((ix + iw * (q * 0.25)) / p) * p;
        sdvFillPx(c, qx, p, p, p, pipCol);
        sdvFillPx(c, qx, h - 2*p, p, p, pipCol);
    }
}
@end

@interface SDVPixelBarFillView : UIView
@property(nonatomic, assign) CGFloat fullTrackWidth;
@end

@implementation SDVPixelBarFillView
-(instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.clipsToBounds = YES;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}
-(void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetShouldAntialias(c, false);
    CGFloat p = 2.0;
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat refW = MAX(w, MAX(120.0, self.fullTrackWidth));
    if (w < 2.0 || h < 6.0) return;

    // 16-Bit RPG Segmented Pixel Energy Blocks (Emerald -> Meadow Lime -> Golden Honey -> Starfruit Gold!)
    CGFloat step = 10.0; // 8pt glowing pixel gem cell + 2pt dark groove
    for (CGFloat bx = 0.0; bx < w; bx += step) {
        CGFloat cw = MIN(step - p, w - bx);
        if (cw <= 0.0) break;
        CGFloat t = MIN(1.0, MAX(0.0, (bx + cw * 0.5) / refW));

        // Interpolate vibrant Stardew 16-bit palette: #2EB845 -> #8FE042 -> #FFD654
        CGFloat cr, cg, cb;
        if (t < 0.55) {
            CGFloat k = t / 0.55;
            cr = (0x2E + (0x8F - 0x2E) * k) / 255.0;
            cg = (0xB8 + (0xE0 - 0xB8) * k) / 255.0;
            cb = (0x45 + (0x42 - 0x45) * k) / 255.0;
        } else {
            CGFloat k = (t - 0.55) / 0.45;
            cr = (0x8F + (0xFF - 0x8F) * k) / 255.0;
            cg = (0xE0 + (0xD6 - 0xE0) * k) / 255.0;
            cb = (0x42 + (0x54 - 0x42) * k) / 255.0;
        }
        UIColor *bodyCol = [UIColor colorWithRed:cr green:cg blue:cb alpha:1.0];
        UIColor *hiCol   = [UIColor colorWithRed:MIN(1.0, cr + 0.30) green:MIN(1.0, cg + 0.24) blue:MIN(1.0, cb + 0.22) alpha:1.0];
        UIColor *midCol  = [UIColor colorWithRed:MAX(0.0, cr * 0.86) green:MAX(0.0, cg * 0.86) blue:MAX(0.0, cb * 0.82) alpha:1.0];
        UIColor *loCol   = [UIColor colorWithRed:MAX(0.0, cr * 0.52) green:MAX(0.0, cg * 0.54) blue:MAX(0.0, cb * 0.48) alpha:1.0];

        // Cell core
        sdvFillPx(c, bx, 0, cw, h, bodyCol);
        // Sunlit top pixel bevel + bright corner glint pixel!
        sdvFillPx(c, bx, 0, cw, p, hiCol);
        if (cw >= 4.0) {
            sdvFillPx(c, bx, p, p, p, [rgb(0xFFFCE0) colorWithAlphaComponent:0.82]);
        }
        // Lower midtone band & deep bottom carved shade
        if (h >= 10.0) {
            sdvFillPx(c, bx, h - 2*p, cw, p, midCol);
        }
        sdvFillPx(c, bx, h - p, cw, p, loCol);

        // Crisp dark pixel separator groove between cells
        if (bx + step - p < w) {
            sdvFillPx(c, bx + step - p, 0, p, h, [rgb(0x180903) colorWithAlphaComponent:0.56]);
        }
    }
    // Bright energetic leading edge pixel cap
    if (w >= 4.0) {
        sdvFillPx(c, w - p, 0, p, h, [rgb(0xFFFBE0) colorWithAlphaComponent:0.88]);
    }
}
@end

@interface SDVPixelBarDividersView : UIView
@end

@implementation SDVPixelBarDividersView
-(instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}
-(void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetShouldAntialias(c, false);
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w < 16 || h < 4) return;
    // Crisp dark pixel top shadow inside trough lip
    sdvFillPx(c, 0.0, 0.0, w, 2.0, [rgb(0x0B0401) colorWithAlphaComponent:0.22]);
}
@end

// Live 5-Stage 16-Bit Pixel Gem Milestone Stepper (.NET -> SMAPI -> Mods -> Nội dung -> Vào Game)
@interface SDVPixelMilestoneStripView : UIView
@property(nonatomic, assign) NSInteger activeStep; // 0..4
@property(nonatomic, assign) BOOL allDone;
@end

@implementation SDVPixelMilestoneStripView {
    NSArray<UILabel *> *_labels;
}

-(instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;

        NSArray<NSString *> *titles = @[@".NET", @"SMAPI", @"Mods", @"Nội dung", @"Vào Game"];
        NSMutableArray<UILabel *> *lbls = [NSMutableArray arrayWithCapacity:titles.count];
        for (NSString *t in titles) {
            UILabel *l = [UILabel new];
            l.text = t;
            l.font = iosMonoDigits(9.5, UIFontWeightBold);
            l.textAlignment = NSTextAlignmentCenter;
            l.textColor = rgb(0x9E7D5A);
            [self addSubview:l];
            [lbls addObject:l];
        }
        _labels = lbls;
    }
    return self;
}

-(void)setActiveStep:(NSInteger)activeStep {
    if (_activeStep == activeStep) return;
    _activeStep = activeStep;
    [self syncLabelStyles];
    [self setNeedsDisplay];
}

-(void)setAllDone:(BOOL)allDone {
    if (_allDone == allDone) return;
    _allDone = allDone;
    [self syncLabelStyles];
    [self setNeedsDisplay];
}

-(void)syncLabelStyles {
    for (NSInteger i = 0; i < (NSInteger)_labels.count; i++) {
        UILabel *l = _labels[i];
        if (self.allDone || i < self.activeStep) {
            l.textColor = rgb(0xB8F57B); // Completed sunlit meadow green
        } else if (i == self.activeStep) {
            l.textColor = rgb(0xFFE888); // Active golden star
        } else {
            l.textColor = [rgb(0xB5936F) colorWithAlphaComponent:0.65]; // Pending warm wood tan
        }
    }
}

-(void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    if (w < 60 || !_labels.count) return;
    CGFloat segW = w / (CGFloat)_labels.count;
    for (NSInteger i = 0; i < (NSInteger)_labels.count; i++) {
        _labels[i].frame = CGRectMake(floor(i * segW), 11.0, floor(segW), 12.0);
    }
    [self syncLabelStyles];
}

-(void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetShouldAntialias(c, false);
    CGFloat w = self.bounds.size.width;
    if (w < 60) return;

    CGFloat p = 2.0;
    NSInteger count = 5;
    CGFloat segW = w / (CGFloat)count;
    CGFloat cy = 4.0;

    // 1. Connecting pixel rails between the 5 milestone gems
    for (NSInteger i = 0; i < count - 1; i++) {
        CGFloat x1 = floor((i + 0.5) * segW / p) * p + 3*p;
        CGFloat x2 = floor((i + 1.5) * segW / p) * p - 3*p;
        if (x2 <= x1) continue;
        BOOL lit = (self.allDone || i < self.activeStep);
        sdvFillPx(c, x1, cy, x2 - x1, p, lit ? rgb(0x69D64D) : rgb(0x402112));
        if (lit) {
            sdvFillPx(c, x1, cy, x2 - x1, 1.0, [rgb(0xD8FF96) colorWithAlphaComponent:0.75]);
        }
    }

    // 2. Five crisp 5x5 pixel diamond gem nodes
    static const char *doneGem[] = {
        "..D..",
        ".DLG.",
        "DLWGD",
        ".DGG.",
        "..D.."
    };
    static const char *actGem[] = {
        "..D..",
        ".DYW.",
        "DYWYD",
        ".DYO.",
        "..D.."
    };
    for (NSInteger i = 0; i < count; i++) {
        CGFloat gx = floor(((i + 0.5) * segW - 5.0) / p) * p;
        CGFloat gy = 0.0;
        if (self.allDone || i < self.activeStep) {
            sdvDrawPixelSprite(c, gx, gy, p, doneGem, 5, NO);
        } else if (i == self.activeStep) {
            // Subtle warm halo behind active gem
            sdvFillPx(c, gx - p, gy, 7*p, 5*p, [rgb(0xFFD654) colorWithAlphaComponent:0.20]);
            sdvDrawPixelSprite(c, gx, gy, p, actGem, 5, NO);
        } else {
            // Recessed unlit socket
            sdvFillPx(c, gx + p, gy + p, 3*p, 3*p, rgb(0x160903));
            sdvFillPx(c, gx + 2*p, gy + 2*p, p, p, rgb(0x5A3620));
        }
    }
}
@end

@interface SDVOrnateLoadingFrameView : UIView
@end

@implementation SDVOrnateLoadingFrameView
-(instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

-(void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGContextSetShouldAntialias(c, false);

    CGFloat p = 2.0; // Crisp 16-bit pixel block unit (2pt = 6px on 3x Retina!)
    CGFloat w = floor(self.bounds.size.width / p) * p;
    CGFloat h = floor(self.bounds.size.height / p) * p;

    // Frame bounds with 12pt breathing room around top/left/right for pixel leaves, wildflowers & diamond crest
    CGFloat bx = 12.0;
    CGFloat by = 12.0;
    CGFloat bw = w - 24.0;
    CGFloat bh = h - 16.0;
    if (bw < 60 || bh < 40) return;

    // 1. Stepped-corner dark espresso pixel outer frame (#2B1104)
    sdvFillPx(c, bx + 2*p, by,       bw - 4*p, bh,       rgb(0x2B1104));
    sdvFillPx(c, bx + p,   by + p,   bw - 2*p, bh - 2*p, rgb(0x2B1104));
    sdvFillPx(c, bx,       by + 2*p, bw,       bh - 4*p, rgb(0x2B1104));

    // 2. Stepped-corner Warm Carved Golden-Oak Pixel Wood Frame
    CGFloat wx = bx + p, wy = by + p, ww = bw - 2*p, wh = bh - 2*p;
    sdvFillPx(c, wx + p, wy,     ww - 2*p, wh,       rgb(0xD67B1C));
    sdvFillPx(c, wx,     wy + p, ww,       wh - 2*p, rgb(0xD67B1C));

    // Top & Left sunlit golden bevel (2 pixel steps!)
    sdvFillPx(c, wx + p,   wy,       ww - 2*p, p,        rgb(0xFFE27D));
    sdvFillPx(c, wx + p,   wy + p,   ww - 2*p, p,        rgb(0xF2A229));
    sdvFillPx(c, wx,       wy + p,   p,        wh - 2*p, rgb(0xF5B53B));
    sdvFillPx(c, wx + p,   wy + 2*p, p,        wh - 4*p, rgb(0xE89120));

    // Bottom & Right chestnut wood shadow bevel
    sdvFillPx(c, wx + p,        wy + wh - p,   ww - 2*p, p,        rgb(0x7D3408));
    sdvFillPx(c, wx + p,        wy + wh - 2*p, ww - 2*p, p,        rgb(0xA64B0F));
    sdvFillPx(c, wx + ww - p,   wy + p,        p,        wh - 2*p, rgb(0x8C3D0B));
    sdvFillPx(c, wx + ww - 2*p, wy + 2*p,      p,        wh - 4*p, rgb(0xB35812));

    // Rich horizontal pixel wood-grain ticks & plank joints along top & bottom wooden bars
    for (CGFloat gx = wx + 22.0; gx < wx + ww - 26.0; gx += 26.0) {
        sdvFillPx(c, gx,        wy + 2*p,      6*p, p, rgb(0xBA6010));
        sdvFillPx(c, gx + 12.0, wy + p,        4*p, p, rgb(0xFFD966));
        sdvFillPx(c, gx + 6.0,  wy + wh - 3*p, 5*p, p, rgb(0xBA6010));
        sdvFillPx(c, gx + 16.0, wy + wh - 2*p, 3*p, p, rgb(0xC96C14));
    }

    // 3. Inner dark espresso carved lip (4*p inset from outer box)
    CGFloat lx = bx + 4*p, ly = by + 4*p, lw = bw - 8*p, lh = bh - 8*p;
    sdvFillPx(c, lx + p, ly,     lw - 2*p, lh,       rgb(0x2B1104));
    sdvFillPx(c, lx,     ly + p, lw,       lh - 2*p, rgb(0x2B1104));

    // 4. Deep Warm Walnut Pixel Recessed Interior Bed (subtle horizontal plank grain!)
    CGFloat ix = lx + p, iy = ly + p, iw = lw - 2*p, ih = lh - 2*p;
    sdvFillPx(c, ix, iy, iw, ih, [rgb(0x231107) colorWithAlphaComponent:0.95]);
    // Subtle dark-walnut horizontal wood-board seams inside the recessed panel
    for (CGFloat py = iy + 18.0; py < iy + ih - 8.0; py += 22.0) {
        sdvFillPx(c, ix, py, iw, p, [rgb(0x180B04) colorWithAlphaComponent:0.45]);
    }
    // Recessed pixel top shadow & bottom warm catchlight
    sdvFillPx(c, ix, iy,          iw, 2*p, [rgb(0x110702) colorWithAlphaComponent:0.88]);
    sdvFillPx(c, ix, iy + ih - p, iw, p,   [rgb(0x3E2211) colorWithAlphaComponent:0.78]);

    // Delicate pixel-art antique-gold corner L-brackets inside the recessed bed
    UIColor *goldTrim = [rgb(0xF6C667) colorWithAlphaComponent:0.50];
    CGFloat fx = ix + p, fy = iy + p, fw = iw - 2*p, fh = ih - 2*p;
    sdvFillPx(c, fx, fy, 5*p, p, goldTrim);
    sdvFillPx(c, fx, fy, p, 3*p, goldTrim);
    sdvFillPx(c, fx + fw - 5*p, fy, 5*p, p, goldTrim);
    sdvFillPx(c, fx + fw - p,   fy, p, 3*p, goldTrim);
    sdvFillPx(c, fx, fy + fh - p,   5*p, p, goldTrim);
    sdvFillPx(c, fx, fy + fh - 3*p, p, 3*p, goldTrim);
    sdvFillPx(c, fx + fw - 5*p, fy + fh - p,   5*p, p, goldTrim);
    sdvFillPx(c, fx + fw - p,   fy + fh - 3*p, p, 3*p, goldTrim);

    // 5. Four Stepped Pixel Brass Nails/Rivets on Wooden Frame Corners
    const char *rivetSprite[] = {
        ".D.",
        "DWD",
        ".D."
    };
    CGPoint rPts[] = {
        CGPointMake(bx + p,           by + p),
        CGPointMake(bx + bw - 4*p,    by + p),
        CGPointMake(bx + p,           by + bh - 4*p),
        CGPointMake(bx + bw - 4*p,    by + bh - 4*p)
    };
    for (int i = 0; i < 4; i++) {
        sdvDrawPixelSprite(c, rPts[i].x, rPts[i].y, p, rivetSprite, 3, NO);
        sdvFillPx(c, rPts[i].x + p, rPts[i].y + p, p, p, rgb(0xFFF0A0));
    }

    // 6. Top-Center Pixel-Art Golden Diamond Medallion + Twin Sprouting Pixel Leaves!
    static const char *topLeafSprite[] = {
        "..KKK...",
        ".KLLGK..",
        "KGGLLGK.",
        ".KGGGGK.",
        "..KKKK.."
    };
    static const char *diamondSprite[] = {
        "...D...",
        "..DYD..",
        ".DYWYD.",
        "DYWWYOD",
        ".DYYOD.",
        "..DOD..",
        "...D..."
    };
    CGFloat cx = floor((w * 0.5) / p) * p;
    sdvDrawPixelSprite(c, cx - 10*p, by - 2*p, p, topLeafSprite, 5, NO);
    sdvDrawPixelSprite(c, cx + 2*p,  by - 2*p, p, topLeafSprite, 5, YES);
    sdvDrawPixelSprite(c, cx - 3*p,  by - 3*p, p, diamondSprite, 7, NO);

    // 7. Pixel-Art Emerald Corner Sprout Leaves + Tiny Wildflowers + Trailing Vine Tendrils!
    static const char *cornerLeafSprite[] = {
        "..KKK...",
        ".KLGGK..",
        "KGLGGK..",
        ".KGGKK..",
        "..KKK..."
    };
    static const char *flowerPink[] = {
        ".P.",
        "PYP",
        ".R."
    };
    static const char *flowerGold[] = {
        ".Y.",
        "YWY",
        ".O."
    };
    sdvDrawPixelSprite(c, bx - 2*p,       by - 2*p, p, cornerLeafSprite, 5, NO);
    sdvDrawPixelSprite(c, bx + bw - 6*p,  by - 2*p, p, cornerLeafSprite, 5, YES);
    sdvDrawPixelSprite(c, bx + 4*p,       by - 2*p, p, flowerPink, 3, NO);
    sdvDrawPixelSprite(c, bx + bw - 7*p,  by - 2*p, p, flowerGold, 3, NO);
    // Cute trailing pixel vine sprigs hugging upper left & right frame edges
    sdvFillPx(c, bx - p, by + 4*p, p, 3*p, rgb(0x288424));
    sdvFillPx(c, bx - 2*p, by + 6*p, p, 2*p, rgb(0x9EF25E));
    sdvFillPx(c, bx + bw, by + 4*p, p, 3*p, rgb(0x288424));
    sdvFillPx(c, bx + bw + p, by + 6*p, p, 2*p, rgb(0x9EF25E));
}
@end

@interface SDVBootLoadingViewController : UIViewController
-(void)updateProgress:(double)pct stage:(NSString *)stage detail:(NSString *)detail stepIdx:(NSInteger)stepIdx elapsed:(double)elapsed;
-(void)flushToScreenNow;
@end

@implementation SDVBootLoadingViewController {
    UIView *_sceneStage;
    UIView *_starHost;
    UIView *_cloudHost;
    UIView *_sunHost;
    UIView *_titleCluster;
    UIImageView *_mainTitleIv;
    UIImageView *_subTitleIv;
    UIView *_subOrnamentRow;
    UILabel *_ramPillLbl;
    UILabel *_stageLabel;
    UILabel *_elapsedLabel;
    UILabel *_pctLabel;
    UILabel *_detailLabel;
    CAGradientLayer *_botScrim;
    SDVPixelBarTrackView *_barTrack;
    SDVPixelBarFillView *_barFill;
    NSLayoutConstraint *_barFillWidth;
    CAGradientLayer *_barShimmer;
    UIImageView *_junimoRider;
    UIImageView *_barTipSpark;
    SDVPixelMilestoneStripView *_milestoneStrip;
    NSLayoutConstraint *_mainTitleH;
    NSLayoutConstraint *_subTitleH;
    NSLayoutConstraint *_titleTopC;
    double _currentPct;
    double _lastSparklePct;
    double _lastTipSwitchSec;
    NSInteger _tipIdx;
    CGSize _fxBuiltSize;
    CGFloat _shimmerBarW;
    BOOL _fxBuilt;
}
-(BOOL)prefersStatusBarHidden { return YES; }
-(BOOL)prefersHomeIndicatorAutoHidden { return YES; }
-(UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
-(UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

static UIImage *sdvLoadBootFrameworkImage(NSString *filename) {
    NSString *p = [[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/SDVModGarden.framework"] stringByAppendingPathComponent:filename];
    return [fm() fileExistsAtPath:p] ? [UIImage imageWithContentsOfFile:p] : nil;
}

-(void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = rgb(0x160936);
    _currentPct = 0.04;
    _lastSparklePct = 0.04;

    // 1. Unified Cinematic Mountain Valley Scene (iconic Stardew valley backdrop!)
    _sceneStage = [UIView new];
    _sceneStage.backgroundColor = rgb(0x160936);
    _sceneStage.clipsToBounds = YES;
    _sceneStage.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_sceneStage];
    pinAll(_sceneStage, self.view, 0);

    UIImage *bgImg = sdvLoadBootFrameworkImage(@"boot_bg.jpg");
    if (bgImg) {
        UIImageView *bgIv = [[UIImageView alloc] initWithImage:bgImg];
        bgIv.contentMode = UIViewContentModeScaleAspectFill;
        bgIv.clipsToBounds = YES;
        bgIv.translatesAutoresizingMaskIntoConstraints = NO;
        [_sceneStage addSubview:bgIv];
        pinAll(bgIv, _sceneStage, 0);
    }

    // 2. Twinkling Starry Sky Host (upper indigo-to-royal-blue sky!)
    _starHost = [UIView new];
    _starHost.backgroundColor = UIColor.clearColor;
    _starHost.clipsToBounds = YES;
    _starHost.userInteractionEnabled = NO;
    _starHost.translatesAutoresizingMaskIntoConstraints = NO;
    [_sceneStage addSubview:_starHost];
    pinAll(_starHost, _sceneStage, 0);

    // 2b. Drifting 16-Bit Pixel Clouds & Flapping Valley Birds Host
    _cloudHost = [UIView new];
    _cloudHost.backgroundColor = UIColor.clearColor;
    _cloudHost.clipsToBounds = YES;
    _cloudHost.userInteractionEnabled = NO;
    _cloudHost.translatesAutoresizingMaskIntoConstraints = NO;
    [_sceneStage addSubview:_cloudHost];
    pinAll(_cloudHost, _sceneStage, 0);

    // 3. Warm Sunrise Glow + Volumetric Sunbeams (God Rays) + Floating Sunlit Motes Host
    _sunHost = [UIView new];
    _sunHost.backgroundColor = UIColor.clearColor;
    _sunHost.clipsToBounds = YES;
    _sunHost.userInteractionEnabled = NO;
    _sunHost.translatesAutoresizingMaskIntoConstraints = NO;
    [_sceneStage addSubview:_sunHost];
    pinAll(_sunHost, _sceneStage, 0);

    // Soft bottom vignette for crisp readability of the ornate loading plaque over forest foreground
    _botScrim = [CAGradientLayer layer];
    _botScrim.colors = @[
        (id)UIColor.clearColor.CGColor,
        (id)[rgb(0x0B1510) colorWithAlphaComponent:0.30].CGColor,
        (id)[rgb(0x08100C) colorWithAlphaComponent:0.74].CGColor
    ];
    _botScrim.locations = @[@(0.0), @(0.48), @(1.0)];
    [self.view.layer addSublayer:_botScrim];

    // 4a. Top-Left Stepped-Pixel Version Plaque
    SDVPixelBadgeView *verPill = [SDVPixelBadgeView new];
    verPill.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *verPillLbl = [UILabel new];
    NSString *effBootVer = sdvEffectiveAppVersion();
    verPillLbl.text = [effBootVer isEqualToString:kSDVAppVersion]
        ? (@"v" kSDVAppVersion @" · SMAPI 4.5.2")
        : [NSString stringWithFormat:@"v%@ · SMAPI 4.5.2", effBootVer];
    verPillLbl.font = iosMonoDigits(10.5, UIFontWeightBold);
    verPillLbl.textColor = rgb(0xFFF0C4);
    verPillLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [verPill addSubview:verPillLbl];
    pinInsets(verPillLbl, verPill, UIEdgeInsetsMake(5.5, 10.5, 5.5, 10.5));
    [self.view addSubview:verPill];

    // 4b. Top-Right Balanced Live Engine / RAM Pixel Plaque
    SDVPixelBadgeView *ramPill = [SDVPixelBadgeView new];
    ramPill.translatesAutoresizingMaskIntoConstraints = NO;
    _ramPillLbl = [UILabel new];
    _ramPillLbl.text = @"iOS Native · 0% JIT";
    _ramPillLbl.font = iosMonoDigits(10.5, UIFontWeightBold);
    _ramPillLbl.textColor = rgb(0xC6F8A8);
    _ramPillLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [ramPill addSubview:_ramPillLbl];
    pinInsets(_ramPillLbl, ramPill, UIEdgeInsetsMake(5.5, 10.5, 5.5, 10.5));
    [self.view addSubview:ramPill];

    // 5. Dual-Title Hero Stack: PRIMARY = STARDEW VALLEY (Large), SECONDARY = GARDEN LAUNCHER (Subordinate & Framed!)
    _titleCluster = [UIView new];
    _titleCluster.backgroundColor = UIColor.clearColor;
    _titleCluster.userInteractionEnabled = NO;
    _titleCluster.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_titleCluster];

    UIStackView *titleStack = mkVStack(4.0);
    titleStack.alignment = UIStackViewAlignmentCenter;
    titleStack.translatesAutoresizingMaskIntoConstraints = NO;
    [_titleCluster addSubview:titleStack];
    pinAll(titleStack, _titleCluster, 0);

    // 6a. PRIMARY TITLE: STARDEW VALLEY wooden pixel logo
    UIImage *mainImg = sdvLoadBootFrameworkImage(@"boot_title_main.png");
    if (mainImg) {
        _mainTitleIv = [[UIImageView alloc] initWithImage:mainImg];
        _mainTitleIv.contentMode = UIViewContentModeScaleAspectFit;
        _mainTitleIv.layer.shadowColor = [rgb(0x160902) colorWithAlphaComponent:0.85].CGColor;
        _mainTitleIv.layer.shadowOpacity = 0.72;
        _mainTitleIv.layer.shadowRadius = 10.0;
        _mainTitleIv.layer.shadowOffset = CGSizeMake(0, 5);
        _mainTitleIv.translatesAutoresizingMaskIntoConstraints = NO;
        CGFloat mainAspect = mainImg.size.width / MAX(1.0, mainImg.size.height);
        _mainTitleH = [_mainTitleIv.heightAnchor constraintEqualToConstant:112.0];
        [NSLayoutConstraint activateConstraints:@[
            _mainTitleH,
            [_mainTitleIv.widthAnchor constraintEqualToAnchor:_mainTitleIv.heightAnchor multiplier:mainAspect]
        ]];
        [titleStack addArrangedSubview:_mainTitleIv];
    } else {
        UILabel *mainFb = [UILabel new];
        mainFb.text = @"STARDEW VALLEY";
        mainFb.font = [UIFont systemFontOfSize:34.0 weight:UIFontWeightHeavy];
        mainFb.textColor = rgb(0xFFE58F);
        mainFb.layer.shadowColor = rgb(0x160902).CGColor;
        mainFb.layer.shadowOpacity = 0.85;
        mainFb.layer.shadowRadius = 6.0;
        mainFb.layer.shadowOffset = CGSizeMake(0, 3);
        [titleStack addArrangedSubview:mainFb];
    }

    // 6b. SECONDARY TITLE: ◆ ━━ [GARDEN LAUNCHER] ━━ ◆
    _subOrnamentRow = [UIView new];
    _subOrnamentRow.backgroundColor = UIColor.clearColor;
    _subOrnamentRow.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *subRow = mkHStack(8.0);
    subRow.alignment = UIStackViewAlignmentCenter;
    subRow.translatesAutoresizingMaskIntoConstraints = NO;
    [_subOrnamentRow addSubview:subRow];
    pinAll(subRow, _subOrnamentRow, 0);

    UIView *leftRule = [UIView new];
    leftRule.backgroundColor = [rgb(0xFFE07D) colorWithAlphaComponent:0.78];
    leftRule.layer.shadowColor = rgb(0x2B1104).CGColor;
    leftRule.layer.shadowOpacity = 0.75;
    leftRule.layer.shadowRadius = 2.0;
    leftRule.layer.shadowOffset = CGSizeMake(0, 1);
    leftRule.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [leftRule.widthAnchor constraintEqualToConstant:26.0],
        [leftRule.heightAnchor constraintEqualToConstant:2.0]
    ]];

    UIView *leftDia = [UIView new];
    leftDia.backgroundColor = rgb(0xFFF0A6);
    leftDia.transform = CGAffineTransformMakeRotation((CGFloat)M_PI_4);
    leftDia.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [leftDia.widthAnchor constraintEqualToConstant:5.0],
        [leftDia.heightAnchor constraintEqualToConstant:5.0]
    ]];

    UIView *rightDia = [UIView new];
    rightDia.backgroundColor = rgb(0xFFF0A6);
    rightDia.transform = CGAffineTransformMakeRotation((CGFloat)M_PI_4);
    rightDia.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [rightDia.widthAnchor constraintEqualToConstant:5.0],
        [rightDia.heightAnchor constraintEqualToConstant:5.0]
    ]];

    UIView *rightRule = [UIView new];
    rightRule.backgroundColor = [rgb(0xFFE07D) colorWithAlphaComponent:0.78];
    rightRule.layer.shadowColor = rgb(0x2B1104).CGColor;
    rightRule.layer.shadowOpacity = 0.75;
    rightRule.layer.shadowRadius = 2.0;
    rightRule.layer.shadowOffset = CGSizeMake(0, 1);
    rightRule.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [rightRule.widthAnchor constraintEqualToConstant:26.0],
        [rightRule.heightAnchor constraintEqualToConstant:2.0]
    ]];

    [subRow addArrangedSubview:leftRule];
    [subRow addArrangedSubview:leftDia];

    UIImage *subImg = sdvLoadBootFrameworkImage(@"boot_title_sub.png");
    if (subImg) {
        _subTitleIv = [[UIImageView alloc] initWithImage:subImg];
        _subTitleIv.contentMode = UIViewContentModeScaleAspectFit;
        _subTitleIv.layer.shadowColor = [rgb(0x160902) colorWithAlphaComponent:0.88].CGColor;
        _subTitleIv.layer.shadowOpacity = 0.78;
        _subTitleIv.layer.shadowRadius = 6.0;
        _subTitleIv.layer.shadowOffset = CGSizeMake(0, 3);
        _subTitleIv.translatesAutoresizingMaskIntoConstraints = NO;
        CGFloat subAspect = subImg.size.width / MAX(1.0, subImg.size.height);
        _subTitleH = [_subTitleIv.heightAnchor constraintEqualToConstant:26.0];
        [NSLayoutConstraint activateConstraints:@[
            _subTitleH,
            [_subTitleIv.widthAnchor constraintEqualToAnchor:_subTitleIv.heightAnchor multiplier:subAspect]
        ]];
        [subRow addArrangedSubview:_subTitleIv];
    } else {
        UILabel *fb = [UILabel new];
        fb.text = @"GARDEN LAUNCHER";
        fb.font = [UIFont systemFontOfSize:16 weight:UIFontWeightHeavy];
        fb.textColor = rgb(0xFFE07D);
        [subRow addArrangedSubview:fb];
    }

    [subRow addArrangedSubview:rightDia];
    [subRow addArrangedSubview:rightRule];
    [titleStack addArrangedSubview:_subOrnamentRow];

    // 7. Handcrafted 16-Bit Stardew Golden-Oak, Vine & Wildflower Pixel Loading Frame
    SDVOrnateLoadingFrameView *ornateBox = [SDVOrnateLoadingFrameView new];
    ornateBox.layer.shadowColor = UIColor.blackColor.CGColor;
    ornateBox.layer.shadowOpacity = 0.62;
    ornateBox.layer.shadowRadius = 14.0;
    ornateBox.layer.shadowOffset = CGSizeMake(0, 6);
    ornateBox.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:ornateBox];

    UIStackView *hudStack = mkVStack(6.0);
    hudStack.alignment = UIStackViewAlignmentFill;
    [ornateBox addSubview:hudStack];
    pinInsets(hudStack, ornateBox, UIEdgeInsetsMake(23, 28, 14, 28));

    // Row A: Pulsing golden pixel star + Live Vietnamese Stage + Elapsed Timer + Bold Golden %
    UIStackView *statusRow = mkHStack(6.0);
    statusRow.alignment = UIStackViewAlignmentCenter;

    UIImageView *starBadge = [[UIImageView alloc] initWithImage:sdvMakePixelSparkleStarImage(CGSizeMake(16, 16), rgb(0xFFE57F), rgb(0xFFC13B))];
    starBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [starBadge.widthAnchor constraintEqualToConstant:15],
        [starBadge.heightAnchor constraintEqualToConstant:15]
    ]];
    CABasicAnimation *starPulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    starPulse.fromValue = @(0.82);
    starPulse.toValue = @(1.18);
    starPulse.duration = 1.05;
    starPulse.autoreverses = YES;
    starPulse.repeatCount = HUGE_VALF;
    starPulse.removedOnCompletion = NO;
    [starBadge.layer addAnimation:starPulse forKey:@"starPulse"];
    [statusRow addArrangedSubview:starBadge];

    _stageLabel = [UILabel new];
    _stageLabel.text = @"Đang khởi động lõi .NET & SMAPI 4.5.2…";
    _stageLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    _stageLabel.textColor = rgb(0xFFF6E2);
    _stageLabel.numberOfLines = 1;
    _stageLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [statusRow addArrangedSubview:_stageLabel];
    [statusRow addArrangedSubview:[UIView new]];

    _elapsedLabel = [UILabel new];
    _elapsedLabel.text = @"0.0s";
    _elapsedLabel.font = iosMonoDigits(10.5, UIFontWeightMedium);
    _elapsedLabel.textColor = [rgb(0xD8BC94) colorWithAlphaComponent:0.85];
    [_elapsedLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [statusRow addArrangedSubview:_elapsedLabel];

    _pctLabel = [UILabel new];
    _pctLabel.text = @"4%";
    _pctLabel.font = iosMonoDigits(13.5, UIFontWeightBold);
    _pctLabel.textColor = rgb(0xFFE07D);
    [_pctLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [statusRow addArrangedSubview:_pctLabel];
    [hudStack addArrangedSubview:statusRow];

    // Row B: Chunky 22pt 16-Bit RPG Pixel Progress Bar + Segmented Blocks + Hopping Pixel Junimo Rider!
    _barTrack = [SDVPixelBarTrackView new];
    _barTrack.clipsToBounds = NO;
    _barTrack.translatesAutoresizingMaskIntoConstraints = NO;
    [_barTrack.heightAnchor constraintEqualToConstant:22.0].active = YES;

    _barFill = [SDVPixelBarFillView new];
    _barFill.translatesAutoresizingMaskIntoConstraints = NO;
    [_barTrack addSubview:_barFill];
    _barFillWidth = [_barFill.widthAnchor constraintEqualToConstant:18.0];
    [NSLayoutConstraint activateConstraints:@[
        [_barFill.leadingAnchor constraintEqualToAnchor:_barTrack.leadingAnchor constant:4.0],
        [_barFill.topAnchor constraintEqualToAnchor:_barTrack.topAnchor constant:4.0],
        [_barFill.bottomAnchor constraintEqualToAnchor:_barTrack.bottomAnchor constant:-4.0],
        _barFillWidth
    ]];

    // Diagonal gleaming light sweep gliding smoothly across the glowing pixel blocks
    _barShimmer = [CAGradientLayer layer];
    _barShimmer.colors = @[
        (id)UIColor.clearColor.CGColor,
        (id)[rgb(0xFFFDE0) colorWithAlphaComponent:0.52].CGColor,
        (id)UIColor.clearColor.CGColor
    ];
    _barShimmer.startPoint = CGPointMake(0.0, 0.25);
    _barShimmer.endPoint = CGPointMake(1.0, 0.75);
    _barShimmer.frame = CGRectMake(-80, 0, 56, 14);
    [_barFill.layer addSublayer:_barShimmer];

    SDVPixelBarDividersView *barDivs = [SDVPixelBarDividersView new];
    barDivs.translatesAutoresizingMaskIntoConstraints = NO;
    [_barTrack addSubview:barDivs];
    [NSLayoutConstraint activateConstraints:@[
        [barDivs.leadingAnchor constraintEqualToAnchor:_barTrack.leadingAnchor constant:4.0],
        [barDivs.trailingAnchor constraintEqualToAnchor:_barTrack.trailingAnchor constant:-4.0],
        [barDivs.topAnchor constraintEqualToAnchor:_barTrack.topAnchor constant:4.0],
        [barDivs.bottomAnchor constraintEqualToAnchor:_barTrack.bottomAnchor constant:-4.0]
    ]];

    // Leading-edge pixel sparkle halo right at the progress tip
    _barTipSpark = [[UIImageView alloc] initWithImage:sdvMakePixelSparkleStarImage(CGSizeMake(18, 18), rgb(0xFFF8CC), rgb(0xFFD654))];
    _barTipSpark.translatesAutoresizingMaskIntoConstraints = NO;
    [_barTrack addSubview:_barTipSpark];
    [NSLayoutConstraint activateConstraints:@[
        [_barTipSpark.centerXAnchor constraintEqualToAnchor:_barFill.trailingAnchor],
        [_barTipSpark.centerYAnchor constraintEqualToAnchor:_barTrack.centerYAnchor],
        [_barTipSpark.widthAnchor constraintEqualToConstant:16.0],
        [_barTipSpark.heightAnchor constraintEqualToConstant:16.0]
    ]];

    // Adorable 2-Frame Animated 16-Bit Pixel Junimo literally hopping along the top of the loading bar!
    UIImage *j0 = sdvMakePixelJunimoImage(NO);
    UIImage *j1 = sdvMakePixelJunimoImage(YES);
    _junimoRider = [[UIImageView alloc] initWithImage:j0];
    _junimoRider.animationImages = @[j0, j1];
    _junimoRider.animationDuration = 0.42;
    _junimoRider.animationRepeatCount = 0;
    [_junimoRider startAnimating];
    _junimoRider.layer.magnificationFilter = kCAFilterNearest;
    _junimoRider.translatesAutoresizingMaskIntoConstraints = NO;
    [_barTrack addSubview:_junimoRider];
    [NSLayoutConstraint activateConstraints:@[
        [_junimoRider.centerXAnchor constraintEqualToAnchor:_barFill.trailingAnchor constant:-1.0],
        [_junimoRider.bottomAnchor constraintEqualToAnchor:_barTrack.topAnchor constant:6.0],
        [_junimoRider.widthAnchor constraintEqualToConstant:22.0],
        [_junimoRider.heightAnchor constraintEqualToConstant:22.0]
    ]];
    CAKeyframeAnimation *junimoHop = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.y"];
    junimoHop.values = @[@(0.0), @(-5.0), @(0.0), @(0.8), @(0.0)];
    junimoHop.keyTimes = @[@(0.0), @(0.42), @(0.82), @(0.92), @(1.0)];
    junimoHop.duration = 0.42;
    junimoHop.repeatCount = HUGE_VALF;
    junimoHop.removedOnCompletion = NO;
    [_junimoRider.layer addAnimation:junimoHop forKey:@"junimoHop"];

    [hudStack addArrangedSubview:_barTrack];

    // Row C: Live 5-Stage Pixel Gem Milestone Stepper (.NET -> SMAPI -> Mods -> Nội dung -> Vào Game)
    _milestoneStrip = [SDVPixelMilestoneStripView new];
    _milestoneStrip.translatesAutoresizingMaskIntoConstraints = NO;
    [_milestoneStrip.heightAnchor constraintEqualToConstant:23.0].active = YES;
    [hudStack addArrangedSubview:_milestoneStrip];

    // Row D: Live SMAPI Detail & Rotating Helpful Micro-Tip Ticker
    _detailLabel = [UILabel new];
    _detailLabel.text = @"SMAPI 4.5.2 · Mono Interpreter 0% JIT · Tự động tối ưu RAM & Shader";
    _detailLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    _detailLabel.textColor = [rgb(0xE8D4B2) colorWithAlphaComponent:0.86];
    _detailLabel.textAlignment = NSTextAlignmentCenter;
    _detailLabel.numberOfLines = 1;
    _detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [hudStack addArrangedSubview:_detailLabel];

    // 8. Subtle Bottom Gesture Hint
    UILabel *hintLbl = [UILabel new];
    hintLbl.text = @"Chạm 3 ngón × 2 bất cứ lúc nào để mở Mod Garden";
    hintLbl.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
    hintLbl.textColor = [rgb(0xFFF4D9) colorWithAlphaComponent:0.84];
    hintLbl.textAlignment = NSTextAlignmentCenter;
    hintLbl.layer.shadowColor = UIColor.blackColor.CGColor;
    hintLbl.layer.shadowOffset = CGSizeMake(0, 1);
    hintLbl.layer.shadowRadius = 4.0;
    hintLbl.layer.shadowOpacity = 0.90;
    hintLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:hintLbl];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    _titleTopC = [_titleCluster.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16.0];
    NSLayoutConstraint *hudW = [ornateBox.widthAnchor constraintEqualToConstant:488.0];
    hudW.priority = UILayoutPriorityDefaultHigh;
    NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray arrayWithArray:@[
        [verPill.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
        [verPill.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8.0],
        [ramPill.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [ramPill.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8.0],
        [_titleCluster.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        _titleTopC,
        [_titleCluster.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16.0],
        [_titleCluster.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-16.0],
        [ornateBox.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [ornateBox.bottomAnchor constraintEqualToAnchor:hintLbl.topAnchor constant:-5.0],
        [ornateBox.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16.0],
        [ornateBox.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-16.0],
        hudW,
        [hintLbl.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [hintLbl.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4.0]
    ]];
    [NSLayoutConstraint activateConstraints:cs];
}

-(void)spawnTipSparkleAtX:(CGFloat)x {
    if (!_barTrack || x < 8.0) return;
    UIColor *col = (arc4random_uniform(2) == 0) ? rgb(0xFFF6B0) : rgb(0xB8FF7A);
    CGFloat sz = (arc4random_uniform(2) == 0) ? 4.0 : 2.0;
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(floor(x - sz * 0.5), 6.0 + (CGFloat)arc4random_uniform(8), sz, sz)];
    dot.backgroundColor = col;
    dot.userInteractionEnabled = NO;
    [_barTrack addSubview:dot];
    CGFloat dx = -6.0 - (CGFloat)arc4random_uniform(12);
    CGFloat dy = -8.0 - (CGFloat)arc4random_uniform(12);
    [UIView animateWithDuration:0.46 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        dot.center = CGPointMake(dot.center.x + dx, dot.center.y + dy);
        dot.alpha = 0.0;
    } completion:^(BOOL finished) {
        (void)finished;
        [dot removeFromSuperview];
    }];
}

-(void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize sz = self.view.bounds.size;
    if (sz.width < 120 || sz.height < 120) return;

    // Responsive Primary / Secondary Title scaling across iPhone SE (320pt), iPhone XS/16 Pro (375–430pt) & iPad!
    CGFloat mainH = MIN(184.0, MAX(88.0, floor(sz.height * 0.30)));
    CGFloat subH  = MIN(40.0,  MAX(22.0, floor(sz.height * 0.072)));
    if (_mainTitleH) _mainTitleH.constant = mainH;
    if (_subTitleH)  _subTitleH.constant  = subH;
    if (_titleTopC)  _titleTopC.constant  = MAX(10.0, floor(sz.height * 0.045));

    _botScrim.frame = CGRectMake(0, sz.height * 0.56, sz.width, sz.height * 0.44);

    CGFloat trackW = MAX(0.0, _barTrack.bounds.size.width - 8.0);
    if (trackW > 40) {
        _barFill.fullTrackWidth = trackW;
        CGFloat fw = MAX(10.0, floor((trackW * _currentPct) / 2.0) * 2.0);
        _barFillWidth.constant = fw;
        [_barFill setNeedsDisplay];
        if (fabs(trackW - _shimmerBarW) > 6.0) {
            _shimmerBarW = trackW;
            [_barShimmer removeAnimationForKey:@"sdvBarShim"];
            _barShimmer.frame = CGRectMake(-60, 0, 56, 14);
            CABasicAnimation *shim = [CABasicAnimation animationWithKeyPath:@"position.x"];
            shim.fromValue = @(-54.0);
            shim.toValue = @(trackW + 54.0);
            shim.duration = 1.65;
            shim.repeatCount = HUGE_VALF;
            shim.removedOnCompletion = NO;
            [_barShimmer addAnimation:shim forKey:@"sdvBarShim"];
        }
    }

    // Wait for true landscape dimensions, and rebuild backdrop FX cleanly if viewport size changes (e.g. Portrait->Landscape scene transition!)
    if (sz.width < sz.height) return;
    if (_fxBuilt && fabs(sz.width - _fxBuiltSize.width) <= 16.0 && fabs(sz.height - _fxBuiltSize.height) <= 16.0) return;
    _fxBuilt = YES;
    _fxBuiltSize = sz;

    for (UIView *sub in [_starHost.subviews copy]) [sub removeFromSuperview];
    for (UIView *sub in [_cloudHost.subviews copy]) [sub removeFromSuperview];
    for (UIView *sub in [_sunHost.subviews copy]) [sub removeFromSuperview];
    [_titleCluster.layer removeAnimationForKey:@"titleBob"];
    [_sceneStage.layer removeAnimationForKey:@"sceneBreath"];

    // Gentle floating motion on Hero Title Cluster
    CABasicAnimation *titleBob = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    titleBob.fromValue = @(-2.5);
    titleBob.toValue = @(2.5);
    titleBob.duration = 3.8;
    titleBob.autoreverses = YES;
    titleBob.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    titleBob.repeatCount = HUGE_VALF;
    titleBob.removedOnCompletion = NO;
    [_titleCluster.layer addAnimation:titleBob forKey:@"titleBob"];

    // Slow cinematic breathing parallax on mountain scene
    CABasicAnimation *zoom = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    zoom.fromValue = @(1.0);
    zoom.toValue = @(1.032);
    zoom.duration = 16.0;
    zoom.autoreverses = YES;
    zoom.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    zoom.repeatCount = HUGE_VALF;
    zoom.removedOnCompletion = NO;
    [_sceneStage.layer addAnimation:zoom forKey:@"sceneBreath"];

    // =========================================================================
    // A. TWINKLING STARRY SKY (Pinpoint Pixel Stars + 4-Point Sparkles + Shooting Stars)
    // =========================================================================
    CGFloat starDots[][4] = {
        {0.04, 0.06, 2.5, 2.1}, {0.09, 0.14, 2.0, 3.2}, {0.13, 0.05, 3.0, 2.6}, {0.17, 0.22, 2.0, 3.8},
        {0.21, 0.10, 2.5, 1.9}, {0.25, 0.29, 2.0, 3.5}, {0.29, 0.06, 2.5, 2.8}, {0.33, 0.16, 2.0, 4.1},
        {0.38, 0.04, 3.0, 2.3}, {0.42, 0.12, 2.0, 3.1}, {0.47, 0.05, 2.5, 2.7}, {0.52, 0.09, 2.0, 3.6},
        {0.57, 0.04, 3.0, 2.2}, {0.61, 0.14, 2.0, 3.4}, {0.66, 0.07, 2.5, 2.9}, {0.70, 0.19, 2.0, 4.0},
        {0.74, 0.05, 3.0, 2.4}, {0.79, 0.12, 2.5, 3.0}, {0.83, 0.25, 2.0, 3.7}, {0.87, 0.08, 2.5, 2.1},
        {0.91, 0.17, 2.0, 3.3}, {0.95, 0.06, 3.0, 2.5}, {0.07, 0.28, 2.0, 3.9}, {0.15, 0.34, 2.0, 4.2},
        {0.77, 0.31, 2.0, 3.6}, {0.89, 0.30, 2.0, 4.3}, {0.44, 0.22, 2.0, 3.1}, {0.63, 0.24, 2.0, 3.5}
    };
    UIColor *starCols[] = { rgb(0xFFFDF2), rgb(0xD4F0FF), rgb(0xFFEBA8) };
    for (int i = 0; i < 28; i++) {
        CGFloat d = starDots[i][2];
        UIView *sv = [[UIView alloc] initWithFrame:CGRectMake(floor(sz.width * starDots[i][0]), floor(sz.height * starDots[i][1]), d, d)];
        sv.backgroundColor = starCols[i % 3];
        sv.layer.shadowColor = starCols[i % 3].CGColor;
        sv.layer.shadowRadius = 2.5;
        sv.layer.shadowOpacity = 0.85;
        sv.layer.shadowOffset = CGSizeZero;
        [_starHost addSubview:sv];

        CAKeyframeAnimation *tw = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        tw.values = @[@(0.18), @(0.98), @(0.32), @(0.88), @(0.18)];
        tw.duration = starDots[i][3];
        tw.timeOffset = (i * 0.37);
        tw.repeatCount = HUGE_VALF;
        tw.removedOnCompletion = NO;
        [sv.layer addAnimation:tw forKey:@"twinkle"];
    }

    UIImage *goldSpark = sdvMakePixelSparkleStarImage(CGSizeMake(20, 20), rgb(0xFFF6C4), rgb(0xFFE07D));
    UIImage *iceSpark  = sdvMakePixelSparkleStarImage(CGSizeMake(20, 20), rgb(0xE8F8FF), rgb(0x88D8FF));
    CGFloat bigStars[][4] = {
        {0.08, 0.10, 15.0, 2.8}, {0.19, 0.17, 13.0, 3.4}, {0.27, 0.09, 14.0, 2.5},
        {0.36, 0.13, 12.0, 3.7}, {0.54, 0.07, 13.0, 3.1}, {0.68, 0.12, 15.0, 2.6},
        {0.78, 0.18, 13.0, 3.3}, {0.86, 0.13, 14.0, 2.9}, {0.93, 0.22, 12.0, 3.8}
    };
    for (int s = 0; s < 9; s++) {
        CGFloat ss = bigStars[s][2];
        UIImageView *sp = [[UIImageView alloc] initWithImage:((s % 2 == 0) ? goldSpark : iceSpark)];
        sp.frame = CGRectMake(sz.width * bigStars[s][0] - ss * 0.5, sz.height * bigStars[s][1] - ss * 0.5, ss, ss);
        [_starHost addSubview:sp];

        CAKeyframeAnimation *op = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        op.values = @[@(0.22), @(1.0), @(0.35), @(0.92), @(0.22)];
        CAKeyframeAnimation *sc = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        sc.values = @[@(0.68), @(1.18), @(0.78), @(1.08), @(0.68)];
        CAAnimationGroup *grp = [CAAnimationGroup animation];
        grp.animations = @[op, sc];
        grp.duration = bigStars[s][3];
        grp.timeOffset = s * 0.55;
        grp.repeatCount = HUGE_VALF;
        grp.removedOnCompletion = NO;
        [sp.layer addAnimation:grp forKey:@"bigSparkle"];
    }

    for (int m = 0; m < 2; m++) {
        UIView *meteor = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 56, 2.0)];
        meteor.backgroundColor = UIColor.clearColor;
        CAGradientLayer *mg = [CAGradientLayer layer];
        mg.frame = meteor.bounds;
        mg.colors = @[
            (id)UIColor.clearColor.CGColor,
            (id)[rgb(0xFFF3B8) colorWithAlphaComponent:0.55].CGColor,
            (id)UIColor.whiteColor.CGColor
        ];
        mg.startPoint = CGPointMake(0.0, 0.5);
        mg.endPoint = CGPointMake(1.0, 0.5);
        [meteor.layer addSublayer:mg];
        meteor.transform = CGAffineTransformMakeRotation((CGFloat)(M_PI * 0.13));
        meteor.alpha = 0.0;
        [_starHost addSubview:meteor];

        CGPoint p0 = CGPointMake(sz.width * (m == 0 ? 0.10 : 0.62), sz.height * (m == 0 ? 0.07 : 0.05));
        CGPoint p1 = CGPointMake(p0.x + sz.width * 0.24, p0.y + sz.height * 0.18);
        CAKeyframeAnimation *pos = [CAKeyframeAnimation animationWithKeyPath:@"position"];
        pos.values = @[[NSValue valueWithCGPoint:p0], [NSValue valueWithCGPoint:p1], [NSValue valueWithCGPoint:p1]];
        pos.keyTimes = @[@(0.0), @(0.13), @(1.0)];
        CAKeyframeAnimation *op = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        op.values = @[@(0.0), @(0.92), @(0.0), @(0.0)];
        op.keyTimes = @[@(0.0), @(0.04), @(0.13), @(1.0)];
        CAAnimationGroup *mgp = [CAAnimationGroup animation];
        mgp.animations = @[pos, op];
        mgp.duration = (m == 0) ? 7.8 : 10.6;
        mgp.timeOffset = (m == 0) ? 1.5 : 5.2;
        mgp.repeatCount = HUGE_VALF;
        mgp.removedOnCompletion = NO;
        [meteor.layer addAnimation:mgp forKey:@"meteor"];
    }

    // =========================================================================
    // A2. DRIFTING 16-BIT PIXEL CLOUDS & FLAPPING VALLEY BIRDS (Iconic Stardew Sky!)
    // =========================================================================
    UIImage *cloudImgA = sdvMakePixelCloudImage(0);
    UIImage *cloudImgB = sdvMakePixelCloudImage(1);
    CGFloat cloudDefs[][4] = {
        // yFrac, durSec, timeOffset, alpha
        {0.41, 44.0, 6.0,  0.54},
        {0.49, 36.0, 20.0, 0.48},
        {0.34, 52.0, 34.0, 0.40}
    };
    for (int ci = 0; ci < 3; ci++) {
        UIImage *cImg = (ci % 2 == 0) ? cloudImgA : cloudImgB;
        UIImageView *cv = [[UIImageView alloc] initWithImage:cImg];
        cv.frame = CGRectMake(-cImg.size.width, floor(sz.height * cloudDefs[ci][0]), cImg.size.width, cImg.size.height);
        cv.alpha = cloudDefs[ci][3];
        cv.layer.magnificationFilter = kCAFilterNearest;
        [_cloudHost addSubview:cv];

        CABasicAnimation *drift = [CABasicAnimation animationWithKeyPath:@"position.x"];
        drift.fromValue = @(sz.width + cImg.size.width * 0.6);
        drift.toValue = @(-cImg.size.width * 0.6);
        drift.duration = cloudDefs[ci][1];
        drift.timeOffset = cloudDefs[ci][2];
        drift.repeatCount = HUGE_VALF;
        drift.removedOnCompletion = NO;
        [cv.layer addAnimation:drift forKey:@"cloudDrift"];
    }

    UIImage *bUp = sdvMakePixelBirdImage(YES);
    UIImage *bDn = sdvMakePixelBirdImage(NO);
    CGFloat birdDefs[][4] = {
        // yFrac, durSec, timeOffset, scale
        {0.55, 22.0, 2.0,  0.85},
        {0.58, 24.5, 3.2,  0.72},
        {0.51, 28.0, 14.0, 0.78}
    };
    for (int bi = 0; bi < 3; bi++) {
        CGFloat bs = birdDefs[bi][3];
        UIImageView *bv = [[UIImageView alloc] initWithImage:bUp];
        bv.animationImages = @[bUp, bDn];
        bv.animationDuration = 0.56 + bi * 0.08;
        bv.animationRepeatCount = 0;
        [bv startAnimating];
        bv.frame = CGRectMake(-24.0, floor(sz.height * birdDefs[bi][0]), floor(bUp.size.width * bs), floor(bUp.size.height * bs));
        bv.alpha = 0.85;
        bv.layer.magnificationFilter = kCAFilterNearest;
        [_cloudHost addSubview:bv];

        CABasicAnimation *flyX = [CABasicAnimation animationWithKeyPath:@"position.x"];
        flyX.fromValue = @(sz.width + 24.0);
        flyX.toValue = @(-24.0);
        flyX.duration = birdDefs[bi][1];
        flyX.timeOffset = birdDefs[bi][2];
        flyX.repeatCount = HUGE_VALF;
        flyX.removedOnCompletion = NO;
        [bv.layer addAnimation:flyX forKey:@"birdFlyX"];

        CABasicAnimation *bobY = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        bobY.fromValue = @(-4.0);
        bobY.toValue = @(4.0);
        bobY.duration = 1.9 + bi * 0.35;
        bobY.autoreverses = YES;
        bobY.repeatCount = HUGE_VALF;
        bobY.removedOnCompletion = NO;
        [bv.layer addAnimation:bobY forKey:@"birdBobY"];
    }

    // =========================================================================
    // B. WARM SUNRISE GLOW + VOLUMETRIC SUNBEAMS (GOD RAYS) + SUNLIT MOTES
    // =========================================================================
    UIImage *sunBloomImg = sdvMakeSoftGlowImage(CGSizeMake(240, 140),
        [rgb(0xFFF9D4) colorWithAlphaComponent:0.62],
        [rgb(0xFFCE54) colorWithAlphaComponent:0.20]);
    CGFloat bw = sz.width * 0.72;
    CGFloat bh = sz.height * 0.56;
    UIImageView *sunBloom = [[UIImageView alloc] initWithImage:sunBloomImg];
    sunBloom.frame = CGRectMake(sz.width * 0.5 - bw * 0.5, sz.height * 0.65 - bh * 0.5, bw, bh);
    [_sunHost addSubview:sunBloom];
    CABasicAnimation *bloomBreath = [CABasicAnimation animationWithKeyPath:@"opacity"];
    bloomBreath.fromValue = @(0.46);
    bloomBreath.toValue = @(0.82);
    bloomBreath.duration = 5.4;
    bloomBreath.autoreverses = YES;
    bloomBreath.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    bloomBreath.repeatCount = HUGE_VALF;
    bloomBreath.removedOnCompletion = NO;
    [sunBloom.layer addAnimation:bloomBreath forKey:@"sunBloom"];

    CGFloat rayDefs[][4] = {
        {-34.0, 74.0, 0.17, 5.8},
        {-20.0, 96.0, 0.22, 4.7},
        { -6.0, 88.0, 0.25, 6.2},
        {  8.0, 92.0, 0.24, 5.1},
        { 22.0, 82.0, 0.20, 6.6},
        { 35.0, 68.0, 0.16, 5.4}
    };
    CGFloat rayLen = MAX(sz.width, sz.height) * 0.94;
    CGPoint rayOrigin = CGPointMake(sz.width * 0.50, sz.height * 0.70);
    for (int r = 0; r < 6; r++) {
        CGFloat rw = rayDefs[r][1];
        UIView *rayView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, rw, rayLen)];
        rayView.layer.anchorPoint = CGPointMake(0.5, 1.0);
        rayView.layer.position = rayOrigin;
        rayView.backgroundColor = UIColor.clearColor;

        CAGradientLayer *rg = [CAGradientLayer layer];
        rg.frame = rayView.bounds;
        rg.colors = @[
            (id)UIColor.clearColor.CGColor,
            (id)[rgb(0xFFF6C2) colorWithAlphaComponent:0.55].CGColor,
            (id)[rgb(0xFFE88A) colorWithAlphaComponent:0.95].CGColor,
            (id)UIColor.clearColor.CGColor
        ];
        rg.locations = @[@(0.0), @(0.42), @(0.88), @(1.0)];
        rg.startPoint = CGPointMake(0.5, 0.0);
        rg.endPoint = CGPointMake(0.5, 1.0);
        [rayView.layer addSublayer:rg];

        CAGradientLayer *hMask = [CAGradientLayer layer];
        hMask.frame = rayView.bounds;
        hMask.colors = @[
            (id)UIColor.clearColor.CGColor,
            (id)UIColor.whiteColor.CGColor,
            (id)UIColor.whiteColor.CGColor,
            (id)UIColor.clearColor.CGColor
        ];
        hMask.locations = @[@(0.0), @(0.34), @(0.66), @(1.0)];
        hMask.startPoint = CGPointMake(0.0, 0.5);
        hMask.endPoint = CGPointMake(1.0, 0.5);
        rayView.layer.mask = hMask;

        CGFloat rad = (CGFloat)(rayDefs[r][0] * M_PI / 180.0);
        rayView.transform = CGAffineTransformMakeRotation(rad);
        rayView.alpha = rayDefs[r][2];
        [_sunHost addSubview:rayView];

        CABasicAnimation *rayPulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        rayPulse.fromValue = @(rayDefs[r][2] * 0.35);
        rayPulse.toValue = @(rayDefs[r][2]);
        rayPulse.duration = rayDefs[r][3];
        rayPulse.timeOffset = r * 0.85;
        rayPulse.autoreverses = YES;
        rayPulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        rayPulse.repeatCount = HUGE_VALF;
        rayPulse.removedOnCompletion = NO;
        [rayView.layer addAnimation:rayPulse forKey:@"rayPulse"];
    }

    UIImage *moteImg = sdvMakeSoftGlowImage(CGSizeMake(14, 14),
        [rgb(0xFFF9C8) colorWithAlphaComponent:0.95],
        [rgb(0xFFD65E) colorWithAlphaComponent:0.25]);
    CGFloat motes[][4] = {
        {0.08, 0.72, 5.4, 0.2}, {0.16, 0.66, 6.0, 1.5}, {0.24, 0.78, 5.1, 2.8}, {0.31, 0.64, 5.8, 0.9},
        {0.39, 0.73, 4.9, 2.1}, {0.47, 0.68, 6.2, 3.4}, {0.55, 0.74, 5.3, 1.1}, {0.63, 0.65, 5.9, 2.5},
        {0.71, 0.72, 4.8, 0.6}, {0.79, 0.67, 5.7, 1.9}, {0.86, 0.76, 5.2, 3.1}, {0.93, 0.70, 6.1, 1.4},
        {0.20, 0.84, 5.5, 2.2}, {0.76, 0.83, 5.0, 0.8}
    };
    for (int f = 0; f < 14; f++) {
        CGPoint fp = CGPointMake(sz.width * motes[f][0], sz.height * motes[f][1]);
        CGFloat fs = (f % 3 == 0) ? 9.5 : 7.0;
        UIImageView *mv = [[UIImageView alloc] initWithImage:moteImg];
        mv.frame = CGRectMake(fp.x - fs * 0.5, fp.y - fs * 0.5, fs, fs);
        [_sunHost addSubview:mv];

        CABasicAnimation *rise = [CABasicAnimation animationWithKeyPath:@"position.y"];
        rise.fromValue = @(fp.y + 10.0);
        rise.toValue = @(fp.y - 34.0);
        rise.duration = motes[f][2];
        rise.timeOffset = motes[f][3];
        rise.repeatCount = HUGE_VALF;
        rise.removedOnCompletion = NO;
        [mv.layer addAnimation:rise forKey:@"moteRise"];

        CABasicAnimation *sway = [CABasicAnimation animationWithKeyPath:@"position.x"];
        sway.fromValue = @(fp.x - 10.0);
        sway.toValue = @(fp.x + 10.0);
        sway.duration = motes[f][2] * 0.72;
        sway.autoreverses = YES;
        sway.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        sway.repeatCount = HUGE_VALF;
        sway.removedOnCompletion = NO;
        [mv.layer addAnimation:sway forKey:@"moteSway"];

        CAKeyframeAnimation *glow = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        glow.values = @[@(0.0), @(0.88), @(0.36), @(0.94), @(0.0)];
        glow.duration = motes[f][2];
        glow.timeOffset = motes[f][3];
        glow.repeatCount = HUGE_VALF;
        glow.removedOnCompletion = NO;
        [mv.layer addAnimation:glow forKey:@"moteGlow"];
    }
}

-(void)updateProgress:(double)pct stage:(NSString *)stage detail:(NSString *)detail stepIdx:(NSInteger)stepIdx elapsed:(double)elapsed {
    if (pct < _currentPct) pct = _currentPct; // Never move backwards!
    if (pct > 1.0) pct = 1.0;
    _currentPct = pct;

    int pctInt = (int)llround(pct * 100.0);
    if (pctInt < 1) pctInt = 1;
    if (pctInt > 100) pctInt = 100;
    _pctLabel.text = [NSString stringWithFormat:@"%d%%", pctInt];
    _elapsedLabel.text = [NSString stringWithFormat:@"%.1fs", MAX(0.0, elapsed)];
    if (stage.length && ![_stageLabel.text isEqualToString:stage]) {
        _stageLabel.text = stage;
    }

    // Update top-right live RAM plaque smoothly (~every 0.6s)
    static CFTimeInterval sLastRamStamp = 0.0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - sLastRamStamp >= 0.6) {
        sLastRamStamp = now;
        SDVRamSnapshot rs = [SDVRamMonitor.shared sample];
        if (rs.usedBytes > 0) {
            _ramPillLbl.text = [NSString stringWithFormat:@"RAM %@ · 0%% JIT", sdvFmtMemCompact(rs.usedBytes)];
        }
    }

    // Update 5-stage live pixel gem stepper
    _milestoneStrip.activeStep = MAX(0, MIN(4, stepIdx));
    _milestoneStrip.allDone = (pct >= 0.999);

    // Update live telemetry or gently rotate micro-tips every 4.2s
    if (detail.length) {
        if (![_detailLabel.text isEqualToString:detail]) _detailLabel.text = detail;
    } else if (now - _lastTipSwitchSec >= 4.2) {
        _lastTipSwitchSec = now;
        NSArray<NSString *> *tips = @[
            @"SMAPI 4.5.2 · Mono Interpreter 0% JIT · Tương thích iOS 14–27+",
            @"Mẹo: Hỗ trợ Tay cầm, Bàn phím & Chuột rời — chạm màn hình để về cảm ứng",
            @"Mẹo: Bấm SAVE trong game để tạo tối đa 20 mốc lưu nhanh bất kỳ lúc nào",
            @"Mẹo: Gặp lỗi mod? Vào tab Báo lỗi trong Mod Garden để gửi ảnh/video & log"
        ];
        _detailLabel.text = tips[_tipIdx % tips.count];
        _tipIdx++;
    }

    CGFloat trackW = MAX(0.0, _barTrack.bounds.size.width - 8.0);
    if (trackW > 40) {
        _barFill.fullTrackWidth = trackW;
        CGFloat targetW = MAX(10.0, floor((trackW * pct) / 2.0) * 2.0);
        if (fabs(_barFillWidth.constant - targetW) >= 2.0) {
            _barFillWidth.constant = targetW;
            [_barFill setNeedsDisplay];
            if (pct - _lastSparklePct >= 0.025) {
                _lastSparklePct = pct;
                [self spawnTipSparkleAtX:targetW + 4.0];
            }
            [UIView animateWithDuration:0.14 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
                [self->_barTrack layoutIfNeeded];
            } completion:nil];
        }
    }
}

-(void)flushToScreenNow {
    if (!self.isViewLoaded) return;
    [self.view layoutIfNeeded];
    [_barTrack layoutIfNeeded];
    [_barFill.layer displayIfNeeded];
    [_milestoneStrip.layer displayIfNeeded];
    [CATransaction flush];
}
@end

// ---- Dedicated Fullscreen Overlay Window for Mod Garden ----
@interface SDVGardenOverlayWindow : UIWindow
@end
@implementation SDVGardenOverlayWindow
@end

// ---- 3-Finger Double-Tap Host & Lifecycle Coordinator (iOS 14 – iOS 26+ Multi-Scene Safe) ----
@interface SDVGardenGestureHost : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) NSHashTable<UIWindow *> *attachedWindows;
@property(nonatomic, strong) SDVGardenOverlayWindow *gardenWindow;
@property(nonatomic, strong) SDVPassThroughWindow *loadingWindow;
@property(nonatomic, strong) SDVBootLoadingViewController *loadingVC;
@property(nonatomic, strong) NSTimer *bootPollTimer;
@property(nonatomic, assign) BOOL bootLoadingDismissed;
@property(nonatomic, assign) BOOL bootFinishing;
@property(nonatomic, assign) double bootDisplayPct;
@property(nonatomic, strong) SDVPassThroughWindow *liveHudWindow;
@property(nonatomic, strong) SDVPassThroughWindow *ramHudWindow;
@property(nonatomic, strong) SDVPassThroughWindow *toastWindow;
@property(nonatomic, assign) BOOL shownStartupToast;
@property(nonatomic, assign) BOOL autoOpenedSetup;
@property(nonatomic, assign) BOOL gameDataReadyCached;
@property(nonatomic, strong) NSTimer *hapticTimer;
@property(nonatomic, assign) UIBackgroundTaskIdentifier bgSaveTaskId;
-(BOOL)isGardenOpen;
-(void)attachToGameWindows;
-(void)showBootLoadingOverlayIfNeeded;
-(void)dismissBootLoadingOverlayAnimated:(BOOL)animated;
-(void)startHapticTimer;
-(void)stopHapticTimer;
@end

static SDVGardenGestureHost *gSdvGardenHost = nil;
static void sdvExtInputStart(void);
static void sdvExtInputAttachWindow(UIWindow *win);
static void sdvExtSetGardenOpen(BOOL open);

// ---- Native UIWindowSceneDelegate for iOS 14 – iOS 26 & iOS 27 Mandatory Scene Lifecycle ----
@interface SDVKeyboardAlertWindow : UIWindow
@end
@implementation SDVKeyboardAlertWindow
@end

@interface SDVSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) SDVSceneHostWindow *placeholderWindow;
@end

@implementation SDVSceneDelegate

-(void)adoptRealWindowForScene:(UIWindowScene *)ws {
    if (!ws) return;
    @try {
        // Never steal keyWindow while Mod Garden overlay or Native Keyboard alert is actively presented!
        if (gSdvGardenHost && [gSdvGardenHost isGardenOpen]) return;
        for (UIWindow *ow in ws.windows) {
            if ([ow isKindOfClass:SDVKeyboardAlertWindow.class] && !ow.hidden) return;
        }

        // 1. Prefer an ALREADY-ACTIVE MonoGame / SDViOS real game window attached to this scene!
        //    (Prevents stale AppDelegate.window from stealing keyWindow on iPadOS/iOS 26-27!)
        UIWindow *bestGameWin = nil;
        for (UIWindow *w in ws.windows) {
            if ([w isKindOfClass:SDVSceneHostWindow.class] ||
                [w isKindOfClass:SDVGardenOverlayWindow.class] ||
                [w isKindOfClass:SDVPassThroughWindow.class] ||
                [w isKindOfClass:SDVKeyboardAlertWindow.class]) continue;
            if (w.windowLevel >= UIWindowLevelAlert || w.hidden || !w.rootViewController) continue;
            NSString *rcName = NSStringFromClass(w.rootViewController.class) ?: @"";
            if ([rcName containsString:@"GameViewController"] || [rcName containsString:@"iOSGame"]) {
                bestGameWin = w;
                break;
            }
            if (!bestGameWin) bestGameWin = w;
        }
        if (bestGameWin) {
            BOOL hadPlaceholder = (self.placeholderWindow != nil);
            if (hadPlaceholder) {
                self.placeholderWindow.hidden = YES;
                self.placeholderWindow = nil;
                sdvBootLog("[SCENE] Retired placeholder host window (real game window active)");
            }
            if (self.window != bestGameWin) {
                self.window = bestGameWin;
            }
            if (!bestGameWin.isKeyWindow) {
                [bestGameWin makeKeyAndVisible];
            }
            return;
        }

        // 2. Fallback: adopt AppDelegate.window only if no real game window exists on this scene yet
        //    (e.g., ShowMissingFilesScreen / ShowErrorScreen before MonoGame initializes)
        id<UIApplicationDelegate> appDel = UIApplication.sharedApplication.delegate;
        if (appDel && [appDel respondsToSelector:@selector(window)]) {
            UIWindow *dw = [appDel window];
            if (dw && ![dw isKindOfClass:SDVSceneHostWindow.class] &&
                ![dw isKindOfClass:SDVGardenOverlayWindow.class] &&
                ![dw isKindOfClass:SDVPassThroughWindow.class] &&
                ![dw isKindOfClass:SDVKeyboardAlertWindow.class]) {
                BOOL needsAdopt = (dw.windowScene != ws || dw.hidden || self.window != dw || self.placeholderWindow != nil);
                if (!needsAdopt) return;
                if (dw.windowScene != ws) {
                    dw.windowScene = ws;
                    dw.frame = ws.coordinateSpace.bounds;
                }
                if (dw.hidden) dw.hidden = NO;
                [dw makeKeyAndVisible];
                self.window = dw;
                if (self.placeholderWindow && self.placeholderWindow != dw) {
                    self.placeholderWindow.hidden = YES;
                    self.placeholderWindow = nil;
                }
                sdvBootLog("[SCENE] Adopted AppDelegate.window onto UIWindowScene");
                return;
            }
        }
    } @catch (NSException *ex) { }
}

-(void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    (void)session; (void)connectionOptions;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *ws = (UIWindowScene *)scene;
    sdvBootLog("[BOOT 5] SDVSceneDelegate willConnectToSession");

    [self adoptRealWindowForScene:ws];
    if (!self.window) {
        SDVSceneHostWindow *hw = [[SDVSceneHostWindow alloc] initWithWindowScene:ws];
        hw.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.10 alpha:1.0];
        hw.windowLevel = UIWindowLevelNormal - 1;
        hw.rootViewController = [SDVSceneHostViewController new];
        [hw makeKeyAndVisible];
        self.placeholderWindow = hw;
        self.window = hw;
        sdvBootLog("[SCENE] Installed placeholder SDVSceneHostWindow while game initializes");
    }
    if (gSdvGardenHost) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [gSdvGardenHost attachToGameWindows];
        });
    }
}

-(void)sceneDidBecomeActive:(UIScene *)scene {
    if ([scene isKindOfClass:UIWindowScene.class]) {
        [self adoptRealWindowForScene:(UIWindowScene *)scene];
    }
    if (gSdvGardenHost) {
        [gSdvGardenHost attachToGameWindows];
        if ([gSdvGardenHost isGardenOpen]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gSdvGardenHost && [gSdvGardenHost isGardenOpen]) {
                    sdvApplyGameDisplayLinkPauseForGarden(YES);
                }
            });
        }
    }
}

-(void)sceneWillEnterForeground:(UIScene *)scene {
    if ([scene isKindOfClass:UIWindowScene.class]) {
        [self adoptRealWindowForScene:(UIWindowScene *)scene];
    }
}

@end

@implementation SDVGardenGestureHost

-(instancetype)init {
    self = [super init];
    if (self) {
        _attachedWindows = [NSHashTable weakObjectsHashTable];
        _bgSaveTaskId = UIBackgroundTaskInvalid;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(syncRamHudVisibility) name:kSDVRamHudToggleNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onHighRamWarning:) name:kSDVRamHighWarningNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onSceneOrAppNotification) name:UISceneDidActivateNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onSceneOrAppNotification) name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onAppWillResignOrDeactivate) name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onAppWillResignOrDeactivate) name:UISceneWillDeactivateNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onAppDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onAppDidEnterBackground) name:UISceneDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onOrientationChanged) name:UIDeviceOrientationDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onAudioModeChanged) name:@"SDVAudioModeChangedNotification" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onAudioInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onAudioRouteChange:) name:AVAudioSessionRouteChangeNotification object:nil];
    }
    return self;
}

-(void)startHapticTimer {
    if (self.hapticTimer) return;
    self.hapticTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:YES block:^(NSTimer *t) {
        (void)t;
        [self pollFishBiteHaptic];
    }];
}

-(void)stopHapticTimer {
    [self.hapticTimer invalidate];
    self.hapticTimer = nil;
}

-(void)endBackgroundSaveGuardIfNeeded {
    if (self.bgSaveTaskId != UIBackgroundTaskInvalid) {
        UIBackgroundTaskIdentifier tid = self.bgSaveTaskId;
        self.bgSaveTaskId = UIBackgroundTaskInvalid;
        [UIApplication.sharedApplication endBackgroundTask:tid];
    }
}

-(void)onAppDidEnterBackground {
    [self stopHapticTimer];
    if (self.ramHudWindow && [self.ramHudWindow.rootViewController isKindOfClass:SDVRamHudController.class]) {
        [(SDVRamHudController *)self.ramHudWindow.rootViewController setMonitoringPaused:YES];
    }
    // Protect any active end-of-day XML serialization or QuickSave write when user swipes Home!
    if (self.bgSaveTaskId == UIBackgroundTaskInvalid) {
        __weak typeof(self) weakSelf = self;
        self.bgSaveTaskId = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"GardenSaveFlushGuard" expirationHandler:^{
            [weakSelf endBackgroundSaveGuardIfNeeded];
        }];
        if (self.bgSaveTaskId != UIBackgroundTaskInvalid) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf endBackgroundSaveGuardIfNeeded];
            });
        }
    }
}

-(void)onAudioModeChanged {
    sdvEnsureAudioSession("mute-switch-pref-changed");
}

-(void)onAppWillResignOrDeactivate {
    if (gSdvPauseFlagPath[0]) {
        int fd = open(gSdvPauseFlagPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            (void)write(fd, "1", 1);
            close(fd);
        }
    }
}

-(void)onOrientationChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self syncSafeAreaToDocs];
    });
    // Re-sync after UIKit rotation animation completes so Notch/Dynamic Island insets update immediately!
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self syncSafeAreaToDocs];
    });
}

-(void)syncSafeAreaToDocs {
    if (!gSdvSafeAreaPath[0]) return;
    UIWindow *game = [self gameWindow];
    if (!game) return;
    CGSize sz = game.bounds.size;
    if (sz.width < 100.0 || sz.height < 100.0) return;
    UIEdgeInsets ins = game.safeAreaInsets;
    float lf = (float)(ins.left / sz.width);
    float rf = (float)(ins.right / sz.width);
    if (lf < 0.0f) lf = 0.0f;
    if (lf > 0.14f) lf = 0.14f;
    if (rf < 0.0f) rf = 0.0f;
    if (rf > 0.14f) rf = 0.14f;
    char buf[64];
    int n = snprintf(buf, sizeof(buf), "%.4f,%.4f", lf, rf);
    if (n > 0 && strcmp(buf, gSdvLastSafeAreaBuf) != 0) {
        strncpy(gSdvLastSafeAreaBuf, buf, sizeof(gSdvLastSafeAreaBuf) - 1);
        int fd = open(gSdvSafeAreaPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            (void)write(fd, buf, (size_t)n);
            close(fd);
        }
    }
}

-(void)pollFishBiteHaptic {
    if (!gSdvHapticFlagPath[0]) return;
    if (access(gSdvHapticFlagPath, F_OK) == 0) {
        unlink(gSdvHapticFlagPath);
        static UIImpactFeedbackGenerator *sFishGen = nil;
        if (!sFishGen) sFishGen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [sFishGen impactOccurred];
    }
}

-(void)onAudioInterruption:(NSNotification *)n {
    NSNumber *t = n.userInfo[AVAudioSessionInterruptionTypeKey];
    if (t && t.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
        sdvEnsureAudioSession("interruption-ended");
    }
}

-(void)onAudioRouteChange:(NSNotification *)n {
    (void)n;
    sdvEnsureAudioSession("route-change");
}

-(void)onSceneOrAppNotification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self endBackgroundSaveGuardIfNeeded];
        if (self.ramHudWindow && !self.ramHudWindow.hidden && [self.ramHudWindow.rootViewController isKindOfClass:SDVRamHudController.class]) {
            [(SDVRamHudController *)self.ramHudWindow.rootViewController setMonitoringPaused:[self isGardenOpen]];
        }
        sdvEnsureAudioSession("did-become-active");
        [self startHapticTimer];
        [self attachToGameWindows];
        // Re-apply shortly after activation so SDViOS AppDelegate.OnActivated never overrides respectMuteSwitch
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            sdvEnsureAudioSession("did-become-active-settled");
        });
    });
}

-(NSString *)docsPath {
    return [fm() URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
}

-(BOOL)isOwnWindow:(UIWindow *)w {
    if (!w) return YES;
    return w == self.gardenWindow || w == self.loadingWindow || w == self.liveHudWindow || w == self.ramHudWindow || w == self.toastWindow ||
           [w isKindOfClass:SDVGardenOverlayWindow.class] || [w isKindOfClass:SDVPassThroughWindow.class] || [w isKindOfClass:SDVKeyboardAlertWindow.class];
}

-(UIWindowScene *)primaryWindowScene {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (ws.activationState == UISceneActivationStateForegroundInactive && !fallback) fallback = ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

-(UIWindow *)gameWindow {
    UIWindow *fallback = nil;
    UIWindow *hostFallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        UISceneActivationState st = ws.activationState;
        BOOL fg = (st == UISceneActivationStateForegroundActive || st == UISceneActivationStateForegroundInactive);
        if (@available(iOS 15.0, *)) {
            UIWindow *kw = ws.keyWindow;
            if (kw && ![self isOwnWindow:kw] && !kw.hidden && kw.windowLevel < UIWindowLevelAlert && kw.rootViewController) {
                if ([kw isKindOfClass:SDVSceneHostWindow.class]) {
                    if (!hostFallback) hostFallback = kw;
                } else if (fg) {
                    return kw;
                } else if (!fallback) {
                    fallback = kw;
                }
            }
        }
        for (UIWindow *w in ws.windows) {
            if ([self isOwnWindow:w] || w.hidden) continue;
            if (w.windowLevel >= UIWindowLevelAlert) continue;
            if (!w.rootViewController) continue;
            if ([w isKindOfClass:SDVSceneHostWindow.class]) {
                if (!hostFallback) hostFallback = w;
                continue;
            }
            if (fg && w.isKeyWindow) return w;
            if (!fallback) fallback = w;
        }
    }
    return fallback ?: hostFallback;
}

-(BOOL)isGardenOpen {
    return (self.gardenWindow != nil && !self.gardenWindow.hidden);
}

-(void)attachToGameWindows {
    @try {
        // Fast-path once boot has completed, toast has shown, Mod Garden is closed, and active game window is already attached:
        // avoids redundant main-thread UIKit scans & disk gameDataStatus() checks every few seconds during gameplay!
        if (self.gameDataReadyCached && self.bootLoadingDismissed && self.shownStartupToast && ![self isGardenOpen]) {
            UIWindow *gw = [self gameWindow];
            if (gw && [self.attachedWindows containsObject:gw]) {
                return;
            }
        }
        // Ensure any detached AppDelegate.window (created before scene connected) is linked to the active UIWindowScene!
        UIWindowScene *activeScene = [self primaryWindowScene];
        if (activeScene) {
            if ([activeScene.delegate isKindOfClass:SDVSceneDelegate.class]) {
                [(SDVSceneDelegate *)activeScene.delegate adoptRealWindowForScene:activeScene];
            } else {
                id<UIApplicationDelegate> appDel = UIApplication.sharedApplication.delegate;
                if (appDel && [appDel respondsToSelector:@selector(window)]) {
                    UIWindow *dw = [appDel window];
                    if (dw && !dw.windowScene && ![self isOwnWindow:dw]) {
                        dw.windowScene = activeScene;
                        dw.frame = activeScene.coordinateSpace.bounds;
                        [dw makeKeyAndVisible];
                    }
                }
            }
        }

        NSMutableArray<UIWindow *> *candidates = [NSMutableArray array];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if ([self isOwnWindow:w] || w.hidden || [w isKindOfClass:SDVSceneHostWindow.class]) continue;
                if (w.windowLevel >= UIWindowLevelAlert) continue;
                NSString *wCls = NSStringFromClass(w.class) ?: @"";
                if ([wCls hasPrefix:@"UITextEffects"] || [wCls hasPrefix:@"_UI"] || [wCls containsString:@"RemoteKeyboard"]) continue;
                [candidates addObject:w];
            }
        }

        for (UIWindow *w in candidates) {
            if (w.rootViewController) sdvApplyAutoHideHomeIndicator(w.rootViewController);
            sdvExtInputAttachWindow(w);
            if ([self.attachedWindows containsObject:w]) continue;
            w.multipleTouchEnabled = YES;
            if (w.rootViewController.view) w.rootViewController.view.multipleTouchEnabled = YES;

            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleThreeFingerDoubleTap:)];
            tap.numberOfTouchesRequired = 3;
            tap.numberOfTapsRequired = 2;
            tap.cancelsTouchesInView = NO;
            tap.delaysTouchesBegan = NO;
            tap.delaysTouchesEnded = NO;
            tap.delegate = self;
            [w addGestureRecognizer:tap];
            [self.attachedWindows addObject:w];
        }

        if (self.gardenWindow && !self.gardenWindow.hidden) {
            UIWindow *game = [self gameWindow];
            if (game && !CGRectIsEmpty(game.frame)) self.gardenWindow.frame = game.frame;
        }
        [self syncSafeAreaToDocs];
        [self syncRamHudVisibility];

        BOOL hasWindow = ([self gameWindow] != nil);
        BOOL dataReady = self.gameDataReadyCached;
        if (hasWindow && !dataReady) {
            dataReady = [gameDataStatus([self docsPath])[@"ready"] boolValue];
            if (dataReady) self.gameDataReadyCached = YES;
        }
        if (!self.autoOpenedSetup && hasWindow && !dataReady) {
            self.autoOpenedSetup = YES;
            self.shownStartupToast = YES;
            self.bootLoadingDismissed = YES;
            [self dismissBootLoadingOverlayAnimated:NO];
            sdvBootLog("[BOOT 6] Game data missing -> scheduling Mod Garden setup UI");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (![gameDataStatus([self docsPath])[@"ready"] boolValue]) {
                    [self openGarden];
                }
            });
        } else if (hasWindow && dataReady) {
            if (!self.bootLoadingDismissed) {
                [self showBootLoadingOverlayIfNeeded];
            } else if (!self.shownStartupToast) {
                self.shownStartupToast = YES;
                sdvBootLog("[BOOT 6] Game data ready -> scheduling startup hint toast");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self showStartupHintToast];
                });
            }
        }
    } @catch (NSException *ex) {
        sdvBootLogFmt([NSString stringWithFormat:@"[WARN] attachToGameWindows exception: %@", ex]);
    }
}

-(void)showBootLoadingOverlayIfNeeded {
    if (self.bootLoadingDismissed || self.loadingWindow || [self isGardenOpen]) return;
    if (gSdvBootReadyPath[0] && access(gSdvBootReadyPath, F_OK) == 0) {
        self.bootLoadingDismissed = YES;
        gSdvBootDone = 1;
        unlink(gSdvBootReadyPath);
        NSString *bootDocs = [self docsPath];
        if (bootDocs.length) sdvMarkHotPatchBootSucceeded(bootDocs);
        return;
    }
    UIWindow *game = [self gameWindow];
    UIWindowScene *ws = game.windowScene ?: [self primaryWindowScene];
    if (!game && !ws) return;

    CGRect bounds = (game && !CGRectIsEmpty(game.frame)) ? game.frame : (ws ? ws.coordinateSpace.bounds : CGRectZero);
    SDVPassThroughWindow *lw = ws
        ? [[SDVPassThroughWindow alloc] initWithWindowScene:ws]
        : [[SDVPassThroughWindow alloc] initWithFrame:bounds];
    if (!CGRectIsEmpty(bounds)) lw.frame = bounds;
    lw.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    lw.backgroundColor = rgb(0x161D3E);
    lw.windowLevel = UIWindowLevelNormal + 4;
    lw.userInteractionEnabled = NO;
    lw.interactiveView = nil;

    SDVBootLoadingViewController *vc = [SDVBootLoadingViewController new];
    lw.rootViewController = vc;
    lw.hidden = NO; // Never call makeKeyAndVisible so game/scene keyWindow is untouched!
    self.loadingWindow = lw;
    self.loadingVC = vc;
    sdvBootLog("[BOOT 6] Native startup loading screen displayed");

    if (!self.bootPollTimer) {
        __weak typeof(self) weakSelf = self;
        self.bootPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.20 repeats:YES block:^(NSTimer *t) {
            (void)t;
            [weakSelf pollBootLoadingState];
        }];
    }
    [self pollBootLoadingState];
}

-(BOOL)engineLogShowsRenderedFrames {
    if (!gSdvEngineLogPath[0]) return NO;
    struct stat st;
    if (stat(gSdvEngineLogPath, &st) != 0 || st.st_mtime < gSdvBootStartEpoch || st.st_size < 128) return NO;
    int fd = open(gSdvEngineLogPath, O_RDONLY);
    if (fd < 0) return NO;
    off_t readSz = (st.st_size > 4096) ? 4096 : st.st_size;
    if (st.st_size > readSz) lseek(fd, st.st_size - readSz, SEEK_SET);
    char buf[4097];
    ssize_t n = read(fd, buf, (size_t)readSz);
    close(fd);
    if (n <= 0) return NO;
    buf[n] = '\0';
    BOOL hasFrame = (strstr(buf, "Frame #3:") != NULL || strstr(buf, "Frame #4:") != NULL || strstr(buf, "Frame #5:") != NULL);
    if (!hasFrame) return NO;
    // Only treat frames as genuine once GameRunner & Game1 are actually ticking (not G1.ticks=0!)
    return (strstr(buf, "RunnerTick=True") != NULL && strstr(buf, "G1.ticks=0") == NULL);
}

-(void)detectSmapiMilestonePct:(double *)outPct stage:(NSString **)outStage detail:(NSString **)outDetail stepIdx:(NSInteger *)outStep cap:(double *)outCap {
    if (!gSdvSmapiLogPath[0]) return;
    // Never read stale SMAPI-latest.txt from previous session before SMAPI initializes in this run!
    if (__atomic_load_n(&gBootSmapiStarted, __ATOMIC_RELAXED) == 0) return;
    struct stat st;
    if (stat(gSdvSmapiLogPath, &st) != 0 || st.st_mtime < gSdvBootStartEpoch || st.st_size < 32) return;
    int fd = open(gSdvSmapiLogPath, O_RDONLY);
    if (fd < 0) return;
    off_t maxRead = 32768;
    off_t readSz = (st.st_size > maxRead) ? maxRead : st.st_size;
    if (st.st_size > readSz) lseek(fd, st.st_size - readSz, SEEK_SET);
    char *buf = (char *)malloc((size_t)readSz + 1);
    if (!buf) { close(fd); return; }
    ssize_t n = read(fd, buf, (size_t)readSz);
    close(fd);
    if (n <= 0) { free(buf); return; }
    buf[n] = '\0';

    if (strstr(buf, "Propagated ") != NULL || strstr(buf, "Invalidated ") != NULL) {
        *outPct = 0.89; *outCap = 0.96; *outStep = 4;
        *outStage = @"Đang đồng bộ tài nguyên & giao diện…";
        *outDetail = @"Content Patcher & kết xuất màn hình chính";
    } else if (strstr(buf, "GameLaunched:") != NULL || strstr(buf, "GameLaunched") != NULL) {
        *outPct = 0.86; *outCap = 0.94; *outStep = 4;
        *outStage = @"Kích hoạt sự kiện GameLaunched…";
        *outDetail = @"Các Mod đang hoàn tất cấu hình sau khởi động";
    } else if (strstr(buf, "Instance_LoadContent() finished") != NULL) {
        *outPct = 0.78; *outCap = 0.88; *outStep = 3;
        *outStage = @"Đã nạp nội dung game — đồng bộ Mod…";
        *outDetail = @"Đang kích hoạt Content Patcher & bản đồ";
    } else if (strstr(buf, "Mods loaded and ready!") != NULL || strstr(buf, "Launching mods...") != NULL) {
        *outPct = 0.62; *outCap = 0.78; *outStep = 3;
        *outStage = @"Đang nạp bản đồ, âm thanh & font chữ…";
        *outDetail = @"Stardew Valley đang nạp tài nguyên XNB";
    } else if (strstr(buf, "Loaded ") != NULL && strstr(buf, " content packs:") != NULL) {
        *outPct = 0.52; *outCap = 0.64; *outStep = 2;
        *outStage = @"Đã nạp các gói Content Pack…";
    } else if (strstr(buf, "Loaded ") != NULL && strstr(buf, " mods:") != NULL) {
        *outPct = 0.42; *outCap = 0.54; *outStep = 2;
        *outStage = @"Đã nạp các Mod C# — tiếp tục Content Pack…";
    } else if (strstr(buf, "Loading mods...") != NULL) {
        *outPct = 0.29; *outCap = 0.44; *outStep = 2;
        *outStage = @"SMAPI đang nạp & kiểm tra các Mod…";
    } else if (strstr(buf, "Loading mod metadata") != NULL || strstr(buf, "Instance_Initialize") != NULL) {
        *outPct = 0.22; *outCap = 0.32; *outStep = 1;
        *outStage = @"SMAPI đang quét thư mục Mod…";
    } else if (strstr(buf, "SMAPI ") != NULL) {
        *outPct = 0.16; *outCap = 0.25; *outStep = 1;
        *outStage = @"Đang khởi động lõi SMAPI 4.5.2…";
    }
    free(buf);
}

-(void)pollBootLoadingState {
    if (!self.loadingWindow || self.bootLoadingDismissed) {
        [self.bootPollTimer invalidate];
        self.bootPollTimer = nil;
        return;
    }
    if ([self isGardenOpen]) {
        [self dismissBootLoadingOverlayAnimated:NO];
        return;
    }
    UIWindow *game = [self gameWindow];
    if (game && !CGRectIsEmpty(game.frame)) {
        self.loadingWindow.frame = game.frame;
    }
    if (self.bootFinishing) return;

    double elapsed = (gSdvBootStartTime > 0) ? (CFAbsoluteTimeGetCurrent() - gSdvBootStartTime) : 0.0;
    double milestonePct = 0.02;
    double stageCap = 0.14;
    NSInteger stepIdx = 0;
    NSString *stageText = @"Khởi tạo lõi .NET & hệ thống tệp…";
    NSString *detailText = nil;

    // 0. Pull live in-memory telemetry pushed directly from SDViOS.dll / SMAPI / SDVMobileControls
    os_unfair_lock_lock(&gBootTelLock);
    double livePct = gBootLivePct;
    NSInteger liveStep = gBootLiveStep;
    NSString *liveStage = gBootLiveStage;
    NSString *liveDetail = gBootLiveDetail;
    int32_t modsCnt = gBootModsCount;
    int32_t packsCnt = gBootPacksCount;
    os_unfair_lock_unlock(&gBootTelLock);

    if (livePct > milestonePct) {
        milestonePct = livePct;
        stageCap = MIN(0.96, livePct + 0.08);
    }
    if (liveStep > stepIdx) stepIdx = liveStep;
    if (liveStage.length) stageText = liveStage;
    if (liveDetail.length) detailText = liveDetail;

    // 1. Read explicit stage milestone file written by Embedded.m / ModEntry.cs ("pct|message")
    if (gSdvBootStagePath[0]) {
        int fd = open(gSdvBootStagePath, O_RDONLY);
        if (fd >= 0) {
            char sbuf[256];
            ssize_t sn = read(fd, sbuf, sizeof(sbuf) - 1);
            close(fd);
            if (sn > 0) {
                sbuf[sn] = '\0';
                NSString *raw = [[NSString stringWithUTF8String:sbuf] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                NSRange sep = [raw rangeOfString:@"|"];
                if (sep.location != NSNotFound) {
                    double p = [[raw substringToIndex:sep.location] doubleValue] / 100.0;
                    NSString *msg = [raw substringFromIndex:sep.location + 1];
                    if (p > milestonePct && p <= 0.96) {
                        milestonePct = p;
                        stageCap = MIN(0.96, milestonePct + 0.10);
                        if (msg.length) stageText = msg;
                        NSInteger stFromP = (p >= 0.88) ? 4 : (p >= 0.62 ? 3 : (p >= 0.28 ? 2 : (p >= 0.16 ? 1 : 0)));
                        if (stFromP > stepIdx) stepIdx = stFromP;
                    }
                }
            }
        }
    }

    // 2. Fallback scan of SMAPI-latest.txt on disk if ahead of live telemetry
    double smapiPct = 0.0, smapiCap = 0.18;
    NSInteger smapiStep = 0;
    NSString *smapiStage = nil;
    NSString *smapiDetail = nil;
    [self detectSmapiMilestonePct:&smapiPct stage:&smapiStage detail:&smapiDetail stepIdx:&smapiStep cap:&smapiCap];
    if (smapiPct > milestonePct) {
        milestonePct = smapiPct;
        stageCap = smapiCap;
        if (smapiStep > stepIdx) stepIdx = smapiStep;
        if (smapiStage.length) stageText = smapiStage;
        if (smapiDetail.length && !detailText.length) detailText = smapiDetail;
    }

    // 3. Smooth non-stalling progression toward real milestone (never moves backwards!)
    if (self.bootDisplayPct < 0.02) self.bootDisplayPct = 0.02;
    if (self.bootDisplayPct < milestonePct) {
        self.bootDisplayPct += (milestonePct - self.bootDisplayPct) * 0.55 + 0.008;
        if (self.bootDisplayPct > milestonePct) self.bootDisplayPct = milestonePct;
    } else if (self.bootDisplayPct < stageCap) {
        self.bootDisplayPct += (stageCap - self.bootDisplayPct) * 0.04 + 0.002;
        if (self.bootDisplayPct > stageCap) self.bootDisplayPct = stageCap;
    }
    if (self.bootDisplayPct > 0.97) self.bootDisplayPct = 0.97;

    BOOL ready = (gSdvBootReadyPath[0] && access(gSdvBootReadyPath, F_OK) == 0);
    if (!ready && elapsed >= 6.0 && [self engineLogShowsRenderedFrames]) {
        ready = YES;
    }
    if (ready || elapsed >= 90.0) {
        self.bootFinishing = YES;
        gSdvBootDone = 1;
        self.bootDisplayPct = 1.0;
        NSString *doneDetail = (modsCnt > 0 || packsCnt > 0)
            ? [NSString stringWithFormat:@"Hoàn tất %d Mod · %d Content Pack · Chúc bạn chơi vui!", modsCnt, packsCnt]
            : @"Chào mừng trở lại Thung lũng Stardew!";
        [self.loadingVC updateProgress:1.0 stage:@"Sẵn sàng vào Stardew Valley!" detail:doneDetail stepIdx:4 elapsed:elapsed];
        [self.loadingVC flushToScreenNow];
        sdvBootLogFmt([NSString stringWithFormat:@"[BOOT 6b] Dismissing startup loading screen (ready=%d, elapsed=%.1fs, mods=%d, packs=%d)", ready ? 1 : 0, elapsed, modsCnt, packsCnt]);
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.32 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf dismissBootLoadingOverlayAnimated:YES];
        });
        return;
    }

    [self.loadingVC updateProgress:self.bootDisplayPct stage:stageText detail:detailText stepIdx:stepIdx elapsed:elapsed];
}

-(void)dismissBootLoadingOverlayAnimated:(BOOL)animated {
    self.bootLoadingDismissed = YES;
    gSdvBootDone = 1;
    [self.bootPollTimer invalidate];
    self.bootPollTimer = nil;
    if (gSdvBootReadyPath[0]) unlink(gSdvBootReadyPath);
    NSString *bootDocs = [fm() URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
    if (bootDocs.length) sdvMarkHotPatchBootSucceeded(bootDocs);

    SDVPassThroughWindow *lw = self.loadingWindow;
    self.loadingWindow = nil;
    self.loadingVC = nil;
    if (!lw) return;

    void (^cleanup)(void) = ^{
        lw.hidden = YES;
        lw.rootViewController = nil;
        if (![self isGardenOpen] && !self.shownStartupToast) {
            self.shownStartupToast = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self showStartupHintToast];
            });
        }
    };
    if (!animated) {
        cleanup();
        return;
    }
    [UIView animateWithDuration:0.35 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        lw.alpha = 0.0;
    } completion:^(BOOL finished) {
        (void)finished;
        cleanup();
    }];
}

-(BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

-(BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    return ![self isGardenOpen];
}

-(void)handleThreeFingerDoubleTap:(UITapGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateRecognized) return;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    [self closeLiveMenuBarHUD];
    [self openGarden];
}

-(void)showStartupHintToast {
    UIWindow *game = [self gameWindow];
    if (!game || [self isGardenOpen]) return;

    SDVPassThroughWindow *tw = game.windowScene
        ? [[SDVPassThroughWindow alloc] initWithWindowScene:game.windowScene]
        : [[SDVPassThroughWindow alloc] initWithFrame:game.frame];
    tw.backgroundColor = UIColor.clearColor;
    tw.windowLevel = UIWindowLevelNormal + 2;
    tw.userInteractionEnabled = NO;
    tw.interactiveView = nil;

    SDVOverlayToastController *vc = [SDVOverlayToastController new];
    tw.rootViewController = vc;

    UIVisualEffectView *pill = mkGlassCard(UIBlurEffectStyleSystemMaterialDark, 16.0);
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    NSDictionary *updToast = sdvAvailableLauncherUpdate(NO);
    NSTimeInterval holdSec = updToast ? 4.6 : 2.8;
    if (updToast) {
        BOOL isHpToast = [updToast[@"canHotPatch"] boolValue];
        UIStackView *row = mkHStack(9);
        UIImageView *ic = [[UIImageView alloc] initWithImage:sfIcon(isHpToast ? @"bolt.circle.fill" : @"arrow.down.circle.fill", 17, UIImageSymbolWeightSemibold)];
        ic.tintColor = kTintGreen;
        [ic setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *col = mkVStack(1.5);
        NSString *toastTitle = isHpToast
            ? [NSString stringWithFormat:@"⚡ Đã có bản cập nhật nhanh v%@ (Không cần ký lại IPA · Chạm 3 ngón × 2)", updToast[@"version"]]
            : [NSString stringWithFormat:@"Đã có Garden Launcher v%@ mới! (Chạm 3 ngón × 2 để xem)", updToast[@"version"]];
        UILabel *lbl1 = mkLabel(toastTitle, 12.5, UIFontWeightSemibold, UIColor.whiteColor);
        lbl1.numberOfLines = 1;
        [col addArrangedSubview:lbl1];
        NSString *firstSum = [[(updToast[@"summary"] ?: @"") componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] firstObject];
        if (firstSum.length) {
            UILabel *lbl2 = mkLabel(firstSum, 11.5, UIFontWeightRegular, [UIColor colorWithWhite:0.88 alpha:1.0]);
            lbl2.numberOfLines = 1;
            [col addArrangedSubview:lbl2];
        }
        [row addArrangedSubview:ic];
        [row addArrangedSubview:col];
        [pill.contentView addSubview:row];
        pinInsets(row, pill.contentView, UIEdgeInsetsMake(8, 14, 8, 14));
    } else {
        UIStackView *row = mkHStack(8);
        UIImageView *ic = [[UIImageView alloc] initWithImage:sfIcon(@"hand.tap.fill", 15, UIImageSymbolWeightSemibold)];
        ic.tintColor = kTintBlue;
        UILabel *lbl = mkLabel(@"Chạm 3 ngón × 2 để mở Mod Garden", 13, UIFontWeightSemibold, UIColor.whiteColor);
        lbl.numberOfLines = 1;
        [row addArrangedSubview:ic];
        [row addArrangedSubview:lbl];
        [pill.contentView addSubview:row];
        pinInsets(row, pill.contentView, UIEdgeInsetsMake(7, 14, 7, 14));
    }

    pill.alpha = 0.0;
    pill.transform = CGAffineTransformMakeTranslation(0, 12);
    [vc.view addSubview:pill];
    [NSLayoutConstraint activateConstraints:@[
        [pill.centerXAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.centerXAnchor],
        [pill.leadingAnchor constraintGreaterThanOrEqualToAnchor:vc.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [pill.trailingAnchor constraintLessThanOrEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [pill.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-14]
    ]];

    tw.hidden = NO;
    self.toastWindow = tw;

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        pill.alpha = 1.0;
        pill.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.35 delay:holdSec options:UIViewAnimationOptionCurveEaseIn animations:^{
            pill.alpha = 0.0;
            pill.transform = CGAffineTransformMakeTranslation(0, 8);
        } completion:^(BOOL done) {
            self.toastWindow.hidden = YES;
            self.toastWindow = nil;
        }];
    }];
}

-(void)onHighRamWarning:(NSNotification *)n {
    NSString *msg = n.userInfo[@"msg"];
    BOOL critical = [n.userInfo[@"critical"] boolValue];
    if (!msg.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showHighRamWarningBanner:msg critical:critical];
    });
}

-(void)showHighRamWarningBanner:(NSString *)msg critical:(BOOL)critical {
    UIWindow *game = [self gameWindow];
    if (!game || [self isGardenOpen]) return;

    if (self.toastWindow) {
        self.toastWindow.hidden = YES;
        self.toastWindow = nil;
    }

    SDVPassThroughWindow *tw = game.windowScene
        ? [[SDVPassThroughWindow alloc] initWithWindowScene:game.windowScene]
        : [[SDVPassThroughWindow alloc] initWithFrame:game.frame];
    tw.backgroundColor = UIColor.clearColor;
    tw.windowLevel = UIWindowLevelNormal + 4;
    tw.userInteractionEnabled = NO;
    tw.interactiveView = nil;

    SDVOverlayToastController *vc = [SDVOverlayToastController new];
    tw.rootViewController = vc;

    UIVisualEffectView *pill = mkGlassCard(UIBlurEffectStyleSystemChromeMaterialDark, 16.0);
    pill.layer.borderWidth = critical ? 2.2 : 1.4;
    pill.layer.borderColor = (critical ? kTintRed : kTintOrange).CGColor;
    if (critical) {
        pill.contentView.backgroundColor = [kTintRed colorWithAlphaComponent:0.28];
    }
    pill.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *row = mkHStack(10);
    UIImageView *ic = [[UIImageView alloc] initWithImage:sfIcon(@"exclamationmark.triangle.fill", critical ? 21 : 18, UIImageSymbolWeightBold)];
    ic.tintColor = critical ? kTintRed : kTintOrange;
    [ic setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *lbl = mkLabel(msg, critical ? 13.0 : 12.5, critical ? UIFontWeightBold : UIFontWeightSemibold, UIColor.whiteColor);
    lbl.numberOfLines = 2;
    [row addArrangedSubview:ic];
    [row addArrangedSubview:lbl];
    [pill.contentView addSubview:row];
    pinInsets(row, pill.contentView, UIEdgeInsetsMake(critical ? 10 : 8, 15, critical ? 10 : 8, 15));

    pill.alpha = 0.0;
    pill.transform = CGAffineTransformMakeTranslation(0, -14);
    [vc.view addSubview:pill];
    [NSLayoutConstraint activateConstraints:@[
        [pill.centerXAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.centerXAnchor],
        [pill.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:28],
        [pill.widthAnchor constraintLessThanOrEqualToConstant:550]
    ]];

    tw.hidden = NO;
    self.toastWindow = tw;

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        pill.alpha = 1.0;
        pill.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.35 delay:(critical ? 8.0 : 5.5) options:UIViewAnimationOptionCurveEaseIn animations:^{
            pill.alpha = 0.0;
            pill.transform = CGAffineTransformMakeTranslation(0, -10);
        } completion:^(BOOL done) {
            if (self.toastWindow == tw) {
                self.toastWindow.hidden = YES;
                self.toastWindow = nil;
            }
        }];
    }];
}

-(void)openGarden {
    if ([self isGardenOpen]) return;
    [self dismissBootLoadingOverlayAnimated:NO];
    UIWindow *game = [self gameWindow];
    UIWindowScene *ws = game.windowScene ?: [self primaryWindowScene];
    if (!game && !ws) return;

    CGRect bounds = (game && !CGRectIsEmpty(game.frame)) ? game.frame : (ws ? ws.coordinateSpace.bounds : CGRectZero);
    SDVGardenOverlayWindow *gw = ws
        ? [[SDVGardenOverlayWindow alloc] initWithWindowScene:ws]
        : [[SDVGardenOverlayWindow alloc] initWithFrame:bounds];
    if (!CGRectIsEmpty(bounds)) gw.frame = bounds;
    gw.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    gw.backgroundColor = kBgCanvas;
    gw.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
    gw.windowLevel = UIWindowLevelNormal + 5;

    Home *mgr = [Home new];
    __weak typeof(self) weakSelf = self;
    mgr.onRequestClose = ^{
        [weakSelf closeGarden];
    };
    mgr.onRequestLiveMenuBarMode = ^{
        [weakSelf showLiveMenuBarHUD];
    };
    gw.rootViewController = mgr;
    gw.alpha = 0.0;
    gw.hidden = NO;
    [gw makeKeyAndVisible];
    self.gardenWindow = gw;
    sdvExtSetGardenOpen(YES);
    __atomic_store_n(&gSdvGardenOpenFlag, 1, __ATOMIC_RELEASE);
    sdvApplyGameDisplayLinkPauseForGarden(YES);
    sdvBootLog("[BOOT 7] Mod Garden overlay window opened");

    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        gw.alpha = 1.0;
    } completion:nil];
}

-(void)closeGarden {
    SDVGardenOverlayWindow *gw = self.gardenWindow;
    if (!gw) return;
    self.gardenWindow = nil;
    sdvExtSetGardenOpen(NO);
    __atomic_store_n(&gSdvGardenOpenFlag, 0, __ATOMIC_RELEASE);
    sdvApplyGameDisplayLinkPauseForGarden(NO);
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        gw.alpha = 0.0;
    } completion:^(BOOL finished) {
        gw.hidden = YES;
        gw.rootViewController = nil;
        UIWindow *game = [self gameWindow];
        if (game) {
            [game makeKeyAndVisible];
            if (game.rootViewController) sdvApplyAutoHideHomeIndicator(game.rootViewController);
        }
    }];
}

-(void)showLiveMenuBarHUD {
    UIWindow *game = [self gameWindow];
    if (!game) return;
    [self closeLiveMenuBarHUD];

    SDVPassThroughWindow *w = game.windowScene
        ? [[SDVPassThroughWindow alloc] initWithWindowScene:game.windowScene]
        : [[SDVPassThroughWindow alloc] initWithFrame:game.frame];
    w.backgroundColor = UIColor.clearColor;
    w.windowLevel = UIWindowLevelNormal + 6;

    SDVLiveMenuBarController *ctrl = [SDVLiveMenuBarController new];
    ctrl.docsPath = [self docsPath];
    __weak typeof(self) weakSelf = self;
    ctrl.onDone = ^{
        [weakSelf closeLiveMenuBarHUD];
    };
    w.rootViewController = ctrl;
    [ctrl loadViewIfNeeded];
    w.interactiveView = ctrl.capsuleView;
    w.frame = game.frame;
    w.hidden = NO;
    self.liveHudWindow = w;
}

-(void)closeLiveMenuBarHUD {
    if (self.liveHudWindow) {
        self.liveHudWindow.hidden = YES;
        self.liveHudWindow.rootViewController = nil;
        self.liveHudWindow = nil;
    }
}

-(void)syncRamHudVisibility {
    BOOL want = SDVRamMonitor.shared.hudEnabled;
    if (!want) {
        if (self.ramHudWindow) {
            if ([self.ramHudWindow.rootViewController isKindOfClass:SDVRamHudController.class]) {
                [(SDVRamHudController *)self.ramHudWindow.rootViewController stopMonitoring];
            }
            self.ramHudWindow.hidden = YES;
            self.ramHudWindow.rootViewController = nil;
            self.ramHudWindow = nil;
        }
        return;
    }
    UIWindow *game = [self gameWindow];
    if (!game) return;
    if (self.ramHudWindow) {
        self.ramHudWindow.frame = game.frame;
        self.ramHudWindow.hidden = NO;
        return;
    }
    SDVPassThroughWindow *w = game.windowScene
        ? [[SDVPassThroughWindow alloc] initWithWindowScene:game.windowScene]
        : [[SDVPassThroughWindow alloc] initWithFrame:game.frame];
    w.backgroundColor = UIColor.clearColor;
    w.windowLevel = UIWindowLevelNormal + 3;
    SDVRamHudController *ctrl = [SDVRamHudController new];
    w.rootViewController = ctrl;
    [ctrl loadViewIfNeeded];
    w.interactiveView = ctrl.badgeView;
    w.frame = game.frame;
    w.hidden = NO;
    self.ramHudWindow = w;
}
@end

static void sdvBootPumpMainThreadNow(BOOL forceFlush) {
    if (gSdvBootDone || gBootInRunLoopPump) return;
    if (![NSThread isMainThread]) return;
    SDVGardenGestureHost *host = gSdvGardenHost;
    if (!host || !host.loadingVC || !host.loadingWindow || host.bootFinishing || host.bootLoadingDismissed) return;

    os_unfair_lock_lock(&gBootTelLock);
    double pct = gBootLivePct;
    NSInteger step = gBootLiveStep;
    NSString *stage = gBootLiveStage;
    NSString *detail = gBootLiveDetail;
    os_unfair_lock_unlock(&gBootTelLock);

    CFTimeInterval now = CACurrentMediaTime();
    if (!forceFlush && (now - gBootLastPumpTime) < 0.055 && (pct - gBootLastPumpedPct) < 0.035) {
        return;
    }
    gBootLastPumpTime = now;
    gBootLastPumpedPct = pct;

    if (pct > host.bootDisplayPct) {
        host.bootDisplayPct = MIN(0.98, pct);
    }
    double elapsed = (gSdvBootStartTime > 0) ? (CFAbsoluteTimeGetCurrent() - gSdvBootStartTime) : 0.0;
    [host.loadingVC updateProgress:host.bootDisplayPct
                             stage:(stage.length ? stage : @"Đang khởi động Stardew Valley…")
                            detail:detail
                           stepIdx:step
                           elapsed:elapsed];
    [host.loadingVC flushToScreenNow];

    gBootInRunLoopPump = YES;
    @try {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, false);
    } @finally {
        gBootInRunLoopPump = NO;
    }
}

__attribute__((visibility("default")))
void sdv_boot_report(int32_t pctInt, const char *stageUtf8, const char *detailUtf8, int32_t stepIdx) {
    if (gSdvBootDone) return;
    @autoreleasepool {
        double p = (double)pctInt / 100.0;
        if (p < 0.01) p = 0.01;
        if (p > 0.99) p = 0.99;
        NSString *st = (stageUtf8 && stageUtf8[0]) ? [NSString stringWithUTF8String:stageUtf8] : nil;
        NSString *dt = (detailUtf8 && detailUtf8[0]) ? [NSString stringWithUTF8String:detailUtf8] : nil;
        BOOL major = NO;

        os_unfair_lock_lock(&gBootTelLock);
        if (p > gBootLivePct) {
            if (p - gBootLivePct >= 0.035) major = YES;
            gBootLivePct = p;
        }
        if (stepIdx > gBootLiveStep && stepIdx <= 4) {
            gBootLiveStep = stepIdx;
            major = YES;
        }
        if (st.length) gBootLiveStage = st;
        if (dt.length) gBootLiveDetail = dt;
        os_unfair_lock_unlock(&gBootTelLock);

        sdvBootPumpMainThreadNow(major);
    }
}

static void sdvBootParseSingleLine(const char *s, size_t len, BOOL *outMajor) {
    while (len > 0 && (*s == '\r' || *s == '\n' || *s == ' ' || *s == '\t')) { s++; len--; }
    while (len > 0 && (s[len - 1] == '\r' || s[len - 1] == '\n' || s[len - 1] == ' ' || s[len - 1] == '\t')) { len--; }
    if (len >= 8 && strncmp(s, "[SMAPI] ", 8) == 0) {
        s += 8;
        len -= 8;
    }
    if (len < 4) return;

    char buf[512];
    size_t cpy = (len < sizeof(buf) - 1) ? len : (sizeof(buf) - 1);
    memcpy(buf, s, cpy);
    buf[cpy] = '\0';

    double newPct = 0.0;
    NSInteger newStep = -1;
    NSString *newStage = nil;
    NSString *newDetail = nil;

    // 1. EngineLogger / GameHost Phase 0 (.NET + Runtime Patchers: 5%..16%)
    if (strstr(buf, "Found StardewModdingAPI") != NULL || strstr(buf, "InitializeFileSystem") != NULL) {
        newPct = 0.08; newStep = 0;
        newStage = @"Khởi tạo lõi .NET & hệ thống tệp…";
        newDetail = @"Tìm thấy StardewModdingAPI.dll · Đang chuẩn bị khởi chạy";
    } else if (strstr(buf, "smapi-internal") != NULL) {
        newPct = 0.10; newStep = 0;
        newStage = @"Đồng bộ tài nguyên smapi-internal…";
        newDetail = @"Chuẩn bị cấu hình SMAPI & danh sách tương thích";
    } else if (strstr(buf, "Harmony") != NULL && (strstr(buf, "Patch") != NULL || strstr(buf, "DetourHelper") != NULL)) {
        newPct = 0.12; newStep = 0;
        newStage = @"Áp dụng bản vá tương thích 0Harmony…";
        newDetail = @"Chế độ Mono Interpreter 0% JIT an toàn cho iOS";
    } else if (strstr(buf, "EnsureGameRunnerPatched") != NULL || strstr(buf, "EnsureSmapiPatched") != NULL || strstr(buf, "EnsureModsPatched") != NULL) {
        newPct = 0.15; newStep = 0;
        newStage = @"Kiểm tra & vá tương thích thư viện Mod…";
        newDetail = @"Tối ưu hóa tương thích ARM64 cho toàn bộ Mod";
    } else if (strstr(buf, "[RuntimeSmapiPatcher]") != NULL || strstr(buf, "Patched ") != NULL) {
        int32_t pi = __atomic_add_fetch(&gBootPatchItems, 1, __ATOMIC_RELAXED);
        double pp = 0.13 + MIN(0.04, pi * 0.004);
        newPct = pp; newStep = 0;
        newStage = @"Kiểm tra tương thích thư viện Mod…";
        newDetail = [NSString stringWithFormat:@"Đang tối ưu thư viện tương thích (%d)…", pi];
    }
    // 2. SMAPI Startup Phase 1 (17%..29%)
    else if (strstr(buf, "Instantiating persistent SCore") != NULL || strstr(buf, "SMAPI 4.") != NULL) {
        __atomic_store_n(&gBootSmapiStarted, 1, __ATOMIC_RELAXED);
        newPct = 0.19; newStep = 1;
        newStage = @"Đang khởi động lõi SMAPI 4.5.2…";
        newDetail = @"Stardew Valley 1.6.15 · iOS Native 0% JIT";
    } else if (strstr(buf, "Mods go here:") != NULL || strstr(buf, "Waiting for game") != NULL) {
        __atomic_store_n(&gBootSmapiStarted, 1, __ATOMIC_RELAXED);
        newPct = 0.22; newStep = 1;
        newStage = @"SMAPI sẵn sàng — kiểm tra môi trường…";
        newDetail = @"Kết nối thư mục Mods & cấu hình người dùng";
    } else if (strstr(buf, "Loading mod metadata") != NULL) {
        __atomic_store_n(&gBootSmapiStarted, 1, __ATOMIC_RELAXED);
        newPct = 0.25; newStep = 1;
        newStage = @"SMAPI đang quét danh sách & metadata Mod…";
        newDetail = @"Đọc manifest.json và kiểm tra phụ thuộc giữa các Mod";
    } else if (strstr(buf, "Loading mods...") != NULL) {
        __atomic_store_n(&gBootSmapiStarted, 1, __ATOMIC_RELAXED);
        newPct = 0.29; newStep = 2;
        newStage = @"Đang nạp các Mod C# & Content Pack…";
        newDetail = @"Đang giải mã & tải các tệp DLL của Mod vào bộ nhớ";
    }
    // 3. SMAPI Mod & Content Pack Counts + Per-Mod Live Names (30%..62%)
    else if (strstr(buf, "Loaded ") != NULL && strstr(buf, " mods:") != NULL) {
        const char *p = strstr(buf, "Loaded ");
        int n = p ? atoi(p + 7) : 0;
        if (n > 0) __atomic_store_n(&gBootModsCount, (int32_t)n, __ATOMIC_RELAXED);
        newPct = 0.42; newStep = 2;
        newStage = (n > 0)
            ? [NSString stringWithFormat:@"Đã nạp %d Mod C# — kiểm tra Content Pack…", n]
            : @"Đã nạp xong các Mod C#…";
        newDetail = (n > 0)
            ? [NSString stringWithFormat:@"Tổng %d Mod C# đã được SMAPI nhận diện", n]
            : @"Tiếp tục đọc các gói nội dung (Content Packs)";
    } else if (strstr(buf, "Loaded ") != NULL && strstr(buf, " content packs:") != NULL) {
        const char *p = strstr(buf, "Loaded ");
        int m = p ? atoi(p + 7) : 0;
        if (m > 0) __atomic_store_n(&gBootPacksCount, (int32_t)m, __ATOMIC_RELAXED);
        int32_t mc = __atomic_load_n(&gBootModsCount, __ATOMIC_RELAXED);
        newPct = 0.52; newStep = 2;
        newStage = (m > 0)
            ? [NSString stringWithFormat:@"Đã nạp %d Mod & %d Content Pack…", mc, m]
            : @"Đã nạp xong các Content Pack…";
        newDetail = @"Đang khởi chạy & đăng ký sự kiện cho từng Mod";
    } else if (strstr(buf, "Mods loaded and ready!") != NULL || strstr(buf, "Launching mods...") != NULL || strstr(buf, "Invoked SCore.InitializeBeforeFirstAssetLoaded") != NULL) {
        int32_t mc = __atomic_load_n(&gBootModsCount, __ATOMIC_RELAXED);
        int32_t pc = __atomic_load_n(&gBootPacksCount, __ATOMIC_RELAXED);
        newPct = 0.62; newStep = 3;
        newStage = @"Đã nạp toàn bộ Mod — vào nạp tài nguyên game…";
        newDetail = (mc > 0 || pc > 0)
            ? [NSString stringWithFormat:@"%d Mod · %d Content Pack đã sẵn sàng · Đang tải XNB…", mc, pc]
            : @"Stardew Valley đang nạp đồ họa, bản đồ & âm thanh";
    }
    // 4. Content & Game Launch Phase 3..4 (63%..99%)
    else if (strstr(buf, "Instance_LoadContent() finished") != NULL) {
        newPct = 0.83; newStep = 3;
        newStage = @"Đã nạp tài nguyên game — đồng bộ Content Patcher…";
        newDetail = @"Đang áp dụng bản đồ, chân dung & giao diện từ Mod";
    } else if (strstr(buf, "Propagated ") != NULL || strstr(buf, "Invalidated ") != NULL) {
        newPct = 0.87; newStep = 3;
        newStage = @"Content Patcher đang đồng bộ gói dữ liệu…";
        newDetail = @"Cập nhật texture, bản đồ & hội thoại đã chỉnh sửa";
    } else if (strstr(buf, "GameLaunched") != NULL) {
        newPct = 0.90; newStep = 4;
        newStage = @"Kích hoạt GameLaunched — chuẩn bị vào game…";
        newDetail = @"Hoàn tất cấu hình Mod & giao diện cảm ứng";
    } else if (strstr(buf, "AttachTouchOverlay") != NULL) {
        os_unfair_lock_lock(&gBootTelLock);
        double curP = gBootLivePct;
        os_unfair_lock_unlock(&gBootTelLock);
        if (curP >= 0.85) {
            newPct = 0.93; newStep = 4;
            newStage = @"Đang gắn cửa sổ đồ họa & điều khiển…";
            newDetail = @"Thiết lập màn hình toàn cảnh & bộ cảm ứng";
        }
    } else if (strstr(buf, "Frame #1:") != NULL && strstr(buf, "RunnerTick=True") != NULL && strstr(buf, "G1.ticks=0") == NULL) {
        newPct = 0.95; newStep = 4;
        newStage = @"Đang dựng khung hình đầu tiên…";
        newDetail = @"Khởi tạo GPU OpenGL ES & màn hình tiêu đề";
    } else if (strstr(buf, "Frame #2:") != NULL && strstr(buf, "RunnerTick=True") != NULL && strstr(buf, "G1.ticks=0") == NULL) {
        newPct = 0.97; newStep = 4;
        newStage = @"Hoàn thiện hiển thị màn hình chính…";
        newDetail = @"Sắp sẵn sàng vào Thung lũng Stardew!";
    } else if (strstr(buf, "Frame #3:") != NULL && strstr(buf, "RunnerTick=True") != NULL && strstr(buf, "G1.ticks=0") == NULL) {
        newPct = 0.99; newStep = 4;
        newStage = @"Sẵn sàng vào Stardew Valley!";
    } else {
        // Parse individual SMAPI mod / content-pack listing lines or per-mod Entry() logs!
        const char *smapiTag = strstr(buf, "SMAPI]");
        if (smapiTag != NULL) {
            const char *after = smapiTag + 6;
            // Indented listing under "Loaded N mods:" / "Loaded M content packs:" OR TRACE "Loading <Mod>..."
            const char *traceLoad = strstr(after, "Loading ");
            if (traceLoad != NULL && strncmp(traceLoad, "Loading mod", 11) != 0 && strncmp(traceLoad, "Loading game", 12) != 0) {
                const char *nm = traceLoad + 8;
                const char *end = nm + strlen(nm);
                const char *pEll = strstr(nm, "...");
                const char *pFrom = strstr(nm, " from ");
                if (pEll && pEll < end) end = pEll;
                if (pFrom && pFrom < end) end = pFrom;
                size_t nlen = (size_t)(end - nm);
                if (nlen >= 2) {
                    if (nlen > 36) nlen = 36;
                    char nameBuf[44];
                    memcpy(nameBuf, nm, nlen);
                    nameBuf[nlen] = '\0';
                    int32_t li = __atomic_add_fetch(&gBootListedItems, 1, __ATOMIC_RELAXED);
                    newPct = 0.29 + MIN(0.12, li * 0.004);
                    newStep = 2;
                    newStage = [NSString stringWithFormat:@"Đang tải thư viện Mod (%d)…", li];
                    NSString *mName = [NSString stringWithUTF8String:nameBuf];
                    if (mName.length) newDetail = [NSString stringWithFormat:@"Đang tải: %@", mName];
                }
            } else if (after[0] == ' ' && after[1] == ' ' && after[2] == ' ') {
                while (*after == ' ') after++;
                if (*after && *after != '-' && strncmp(after, "These ", 6) != 0 &&
                    strncmp(after, "Skipped", 7) != 0 && strncmp(after, "You can", 7) != 0 &&
                    strncmp(after, "Consider", 8) != 0 && strncmp(after, "http", 4) != 0) {
                    const char *end = after + strlen(after);
                    const char *pBy = strstr(after, " by ");
                    const char *pBar = strstr(after, " | ");
                    const char *pFor = strstr(after, " for ");
                    if (pBy && pBy < end) end = pBy;
                    if (pBar && pBar < end) end = pBar;
                    if (pFor && pFor < end) end = pFor;
                    size_t nlen = (size_t)(end - after);
                    if (nlen >= 2) {
                        if (nlen > 38) nlen = 38;
                        char nameBuf[48];
                        memcpy(nameBuf, after, nlen);
                        nameBuf[nlen] = '\0';
                        int32_t li = __atomic_add_fetch(&gBootListedItems, 1, __ATOMIC_RELAXED);
                        int32_t mc = __atomic_load_n(&gBootModsCount, __ATOMIC_RELAXED);
                        int32_t pc = __atomic_load_n(&gBootPacksCount, __ATOMIC_RELAXED);
                        int32_t totalEst = mc + pc;
                        double frac = (totalEst > 0) ? MIN(1.0, (double)li / (double)totalEst) : MIN(1.0, li / 40.0);
                        newPct = 0.34 + frac * 0.24; // Smoothly glides 34% -> 58% across every single mod & pack!
                        newStep = 2;
                        newStage = (totalEst > 0)
                            ? [NSString stringWithFormat:@"Đang nạp Mod & Content Pack (%d/%d)…", MIN(li, totalEst), totalEst]
                            : [NSString stringWithFormat:@"Đang nạp các Mod (%d)…", li];
                        NSString *mName = [NSString stringWithUTF8String:nameBuf];
                        if (mName.length) {
                            newDetail = [NSString stringWithFormat:@"Đang nạp: %@", mName];
                        }
                    }
                }
            }
        } else if (buf[0] == '[') {
            // Check "[HH:MM:SS LEVEL ModName]" pattern to show which mod is actively initializing!
            const char *rb = strchr(buf, ']');
            if (rb && (rb - buf) > 16 && (rb - buf) < 72) {
                const char *lvl = strstr(buf, " INFO ");
                if (!lvl) lvl = strstr(buf, " TRACE ");
                if (!lvl) lvl = strstr(buf, " DEBUG ");
                if (!lvl) lvl = strstr(buf, " ALERT ");
                if (lvl && lvl < rb) {
                    const char *nm = lvl + 6;
                    while (nm < rb && *nm == ' ') nm++;
                    size_t nlen = (size_t)(rb - nm);
                    while (nlen > 0 && nm[nlen - 1] == ' ') nlen--;
                    if (nlen >= 2 && nlen < 42 &&
                        strncmp(nm, "SMAPI", 5) != 0 && strncmp(nm, "game", 4) != 0 && strncmp(nm, "GameHost", 8) != 0) {
                        char mBuf[48];
                        memcpy(mBuf, nm, nlen);
                        mBuf[nlen] = '\0';
                        NSString *modName = [NSString stringWithUTF8String:mBuf];
                        if (modName.length) {
                            int32_t em = __atomic_add_fetch(&gBootEntryMods, 1, __ATOMIC_RELAXED);
                            if ([modName isEqualToString:@"Content Patcher"]) {
                                os_unfair_lock_lock(&gBootTelLock);
                                double curP = gBootLivePct;
                                os_unfair_lock_unlock(&gBootTelLock);
                                if (curP >= 0.75) {
                                    newPct = MIN(0.89, MAX(0.84, curP + 0.004));
                                    newStep = 3;
                                    newStage = @"Content Patcher đang nạp gói tài nguyên…";
                                    newDetail = @"Áp dụng bản vá dữ liệu, bản đồ & giao diện";
                                } else {
                                    newPct = MIN(0.59, MAX(0.32, curP + 0.006));
                                    newStep = 2;
                                    newStage = @"Content Patcher đang đọc cấu hình gói Mod…";
                                    newDetail = @"Chuẩn bị dữ liệu Content Pack trước khi nạp game";
                                }
                            } else {
                                newPct = 0.54 + MIN(0.08, em * 0.004);
                                newStep = 2;
                                newStage = @"Đang khởi chạy & đăng ký các Mod…";
                                newDetail = [NSString stringWithFormat:@"Khởi chạy Mod: %@", modName];
                            }
                        }
                    }
                }
            }
        }
    }

    if (newPct <= 0.0 && newStep < 0 && !newStage && !newDetail) return;

    os_unfair_lock_lock(&gBootTelLock);
    if (newPct > gBootLivePct) {
        if (newPct - gBootLivePct >= 0.035) *outMajor = YES;
        gBootLivePct = newPct;
    }
    if (newStep > gBootLiveStep && newStep <= 4) {
        gBootLiveStep = newStep;
        *outMajor = YES;
    }
    if (newStage.length) gBootLiveStage = newStage;
    if (newDetail.length) gBootLiveDetail = newDetail;
    os_unfair_lock_unlock(&gBootTelLock);
}

__attribute__((visibility("default")))
int32_t sdv_is_boot_done(void) {
    return gSdvBootDone;
}

__attribute__((visibility("default")))
void sdv_boot_on_log(const char *utf8Line) {
    if (!utf8Line || !utf8Line[0]) return;
    {
        const char *p = utf8Line;
        while (*p) {
            const char *nl = strchr(p, '\n');
            size_t len = nl ? (size_t)(nl - p) : strlen(p);
            while (len > 0 && (p[len - 1] == '\r' || p[len - 1] == ' ')) len--;
            if (len > 0) {
                uint32_t slot = __atomic_fetch_add(&gSdvRecentBootIdx, 1u, __ATOMIC_RELAXED) & 15u;
                size_t copyLen = len < 255 ? len : 255;
                memcpy(gSdvRecentBootLines[slot], p, copyLen);
                gSdvRecentBootLines[slot][copyLen] = '\0';
            }
            if (!nl) break;
            p = nl + 1;
        }
    }
    if (gSdvBootDone) return;
    @autoreleasepool {
        BOOL major = NO;
        const char *p = utf8Line;
        while (*p) {
            const char *nl = strchr(p, '\n');
            size_t len = nl ? (size_t)(nl - p) : strlen(p);
            if (len > 0) {
                sdvBootParseSingleLine(p, len, &major);
            }
            if (!nl) break;
            p = nl + 1;
        }
        sdvBootPumpMainThreadNow(major);
    }
}

// ---- Bulletproof Native iOS 14 – iOS 27 Keyboard Input Bridge (UIWindowScene + Dedicated Alert Window) ----
static os_unfair_lock gSdvKbLock = OS_UNFAIR_LOCK_INIT;
static int gSdvKbState = 0; // 0=idle, 1=active, 2=submitted, 3=cancelled
static char gSdvKbResult[1024] = {0};
static SDVKeyboardAlertWindow *gSdvKbWindow = nil;

@interface SDVKeyboardFieldDelegate : NSObject <UITextFieldDelegate>
@property(nonatomic, copy) void (^onReturnBlock)(void);
@end
@implementation SDVKeyboardFieldDelegate
-(BOOL)textFieldShouldReturn:(UITextField *)textField {
    (void)textField;
    if (self.onReturnBlock) self.onReturnBlock();
    return YES;
}
@end

static SDVKeyboardFieldDelegate *gSdvKbDelegate = nil;

static void sdvKbFinishOnMain(int finalState, NSString *text) {
    os_unfair_lock_lock(&gSdvKbLock);
    if (gSdvKbState == 1) {
        gSdvKbState = finalState;
        if (finalState == 2 && text) {
            const char *u = text.UTF8String;
            if (u) {
                strncpy(gSdvKbResult, u, sizeof(gSdvKbResult) - 1);
                gSdvKbResult[sizeof(gSdvKbResult) - 1] = 0;
            } else {
                gSdvKbResult[0] = 0;
            }
        } else {
            gSdvKbResult[0] = 0;
        }
    }
    os_unfair_lock_unlock(&gSdvKbLock);

    if (gSdvKbWindow) {
        gSdvKbWindow.hidden = YES;
        gSdvKbWindow.rootViewController = nil;
        gSdvKbWindow = nil;
    }
    gSdvKbDelegate = nil;

    if (gSdvGardenHost && ![gSdvGardenHost isGardenOpen]) {
        UIWindow *game = [gSdvGardenHost gameWindow];
        if (game && !game.hidden) {
            [game makeKeyAndVisible];
            if (game.rootViewController) sdvApplyAutoHideHomeIndicator(game.rootViewController);
        }
    }
}

__attribute__((visibility("default")))
int sdv_kb_is_active(void) {
    os_unfair_lock_lock(&gSdvKbLock);
    int active = (gSdvKbState == 1) ? 1 : 0;
    os_unfair_lock_unlock(&gSdvKbLock);
    return active;
}

__attribute__((visibility("default")))
int sdv_kb_poll(char *outUtf8, int outCap) {
    os_unfair_lock_lock(&gSdvKbLock);
    int st = gSdvKbState;
    if (st == 2) {
        if (outUtf8 && outCap > 0) {
            strncpy(outUtf8, gSdvKbResult, (size_t)(outCap - 1));
            outUtf8[outCap - 1] = 0;
        }
        gSdvKbResult[0] = 0;
        gSdvKbState = 0;
    } else if (st == 3) {
        gSdvKbResult[0] = 0;
        gSdvKbState = 0;
    }
    os_unfair_lock_unlock(&gSdvKbLock);
    return st;
}

__attribute__((visibility("default")))
int sdv_kb_show(const char *titleUtf8, const char *initialUtf8) {
    os_unfair_lock_lock(&gSdvKbLock);
    if (gSdvKbState == 1) {
        os_unfair_lock_unlock(&gSdvKbLock);
        return 0;
    }
    gSdvKbState = 1;
    gSdvKbResult[0] = 0;
    os_unfair_lock_unlock(&gSdvKbLock);

    NSString *title = (titleUtf8 && titleUtf8[0]) ? [NSString stringWithUTF8String:titleUtf8] : @"Nhập chữ";
    NSString *initial = (initialUtf8 && initialUtf8[0]) ? [NSString stringWithUTF8String:initialUtf8] : @"";

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (gSdvKbWindow) {
                gSdvKbWindow.hidden = YES;
                gSdvKbWindow.rootViewController = nil;
                gSdvKbWindow = nil;
            }

            UIWindowScene *ws = gSdvGardenHost ? [gSdvGardenHost primaryWindowScene] : nil;
            SDVKeyboardAlertWindow *kw = nil;
            if (ws) {
                kw = [[SDVKeyboardAlertWindow alloc] initWithWindowScene:ws];
                kw.frame = ws.coordinateSpace.bounds;
            } else {
                kw = [[SDVKeyboardAlertWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
            }
            kw.backgroundColor = UIColor.clearColor;
            kw.windowLevel = UIWindowLevelAlert + 2;

            SDVSceneHostViewController *hostVC = [SDVSceneHostViewController new];
            hostVC.view.backgroundColor = UIColor.clearColor;
            kw.rootViewController = hostVC;
            gSdvKbWindow = kw;
            [kw makeKeyAndVisible];

            UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
            __block UITextField *capturedField = nil;
            __block BOOL doneOnce = NO;

            void (^doSubmit)(void) = ^{
                if (doneOnce) return;
                doneOnce = YES;
                NSString *val = capturedField.text ?: @"";
                sdvKbFinishOnMain(2, val);
            };
            void (^doCancel)(void) = ^{
                if (doneOnce) return;
                doneOnce = YES;
                sdvKbFinishOnMain(3, nil);
            };

            SDVKeyboardFieldDelegate *del = [SDVKeyboardFieldDelegate new];
            __weak UIAlertController *weakAlert = alert;
            del.onReturnBlock = ^{
                UIAlertController *sa = weakAlert;
                if (sa) {
                    [sa dismissViewControllerAnimated:YES completion:^{ doSubmit(); }];
                } else {
                    doSubmit();
                }
            };
            gSdvKbDelegate = del;

            [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                capturedField = tf;
                tf.text = initial;
                tf.autocorrectionType = UITextAutocorrectionTypeNo;
                tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
                tf.returnKeyType = UIReturnKeyDone;
                tf.clearButtonMode = UITextFieldViewModeWhileEditing;
                tf.delegate = del;
            }];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                (void)a;
                doSubmit();
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
                (void)a;
                doCancel();
            }]];

            [hostVC presentViewController:alert animated:YES completion:^{
                if (capturedField) [capturedField becomeFirstResponder];
            }];
        } @catch (NSException *ex) {
            sdvBootLogFmt([NSString stringWithFormat:@"[KB] Native keyboard error: %@", ex]);
            sdvKbFinishOnMain(3, nil);
        }
    });
    return 1;
}

__attribute__((constructor)) static void startGardenControls(void) {
    @autoreleasepool {
        @try {
            NSString *docs = [fm() URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
            NSString *hpBootNote = @"none";
            if (docs.length) {
                sdvRepairSandboxPermissions(docs);
            }
            // Initialize native crash & boot logger FIRST so constructor migrations are 100% protected & logged!
            sdvInitBootAndCrashLogging(docs);
            if (docs.length) {
                // Migrate & hide all non-user game/runtime/config files + dropped Saves/ BEFORE .NET GameHost initializes!
                sdvMigrateDocumentsToHiddenLayout(docs);
                @try { sdvMigrateLegacyDocumentsSaves(docs); } @catch (NSException *ignored) { }
                hpBootNote = sdvInitHotPatchOnBoot(docs);
                NSString *gdir = sdvHiddenGardenDir(docs);
                snprintf(gSdvPauseFlagPath, sizeof(gSdvPauseFlagPath), "%s/sdv_pause_now.flag", gdir.UTF8String);
                snprintf(gSdvHapticFlagPath, sizeof(gSdvHapticFlagPath), "%s/sdv_haptic_bite.flag", gdir.UTF8String);
                snprintf(gSdvSafeAreaPath, sizeof(gSdvSafeAreaPath), "%s/sdv_safe_area.cfg", gdir.UTF8String);
                snprintf(gSdvBootReadyPath, sizeof(gSdvBootReadyPath), "%s/sdv_boot_ready.flag", gdir.UTF8String);
                snprintf(gSdvBootStagePath, sizeof(gSdvBootStagePath), "%s/sdv_boot_stage.txt", gdir.UTF8String);
                snprintf(gSdvEngineLogPath, sizeof(gSdvEngineLogPath), "%s/ErrorLogs/engine-latest.log", docs.UTF8String);
                snprintf(gSdvSmapiLogPath, sizeof(gSdvSmapiLogPath), "%s/ErrorLogs/SMAPI-latest.txt", docs.UTF8String);
                gSdvBootStartTime = CFAbsoluteTimeGetCurrent();
                gSdvBootStartEpoch = time(NULL);
                unlink(gSdvBootReadyPath);
                unlink(gSdvPauseFlagPath);
                // Permanently prevent SMAPI LogManager.HandleMarkerFiles() -> System.Console.ReadKey()
                // from throwing PlatformNotSupportedException on iOS after any previous crash or update!
                NSArray<NSString *> *markerDirs = @[
                    [docs stringByAppendingPathComponent:@"StardewValley/smapi-internal"],
                    [docs stringByAppendingPathComponent:@".game/smapi-internal"],
                    [docs stringByAppendingPathComponent:@"smapi-internal"],
                    [docs stringByAppendingPathComponent:@"ErrorLogs"]
                ];
                NSArray<NSString *> *markerNames = @[
                    @"StardewModdingAPI.crash.marker",
                    @"StardewModdingAPI.update.marker",
                    @"StardewModdingAPI.crash.marker",
                    @"SMAPI-crash.marker",
                    @"SMAPI-update.marker"
                ];
                for (NSString *mdir in markerDirs) {
                    for (NSString *mname in markerNames) {
                        NSString *mp = [mdir stringByAppendingPathComponent:mname];
                        unlink(mp.fileSystemRepresentation);
                    }
                }
                const char *initStage = "2|Đang khởi tạo lõi .NET 8 & hệ thống tệp…";
                int sfd = open(gSdvBootStagePath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
                if (sfd >= 0) {
                    (void)write(sfd, initStage, strlen(initStage));
                    close(sfd);
                }
            }
            // Dynamically tune Mono SGen GC heap limit based on real physical iPhone RAM (runs before main()/Mono init!)
            uint64_t physRam = NSProcessInfo.processInfo.physicalMemory;
            if (physRam >= 5500ULL * 1024 * 1024) {
                setenv("MONO_GC_PARAMS", "nursery-size=8m,soft-heap-limit=640m,evacuation-threshold=66", 1);
            } else {
                setenv("MONO_GC_PARAMS", "nursery-size=4m,soft-heap-limit=384m,evacuation-threshold=66", 1);
            }
            sdvBootLogFmt([NSString stringWithFormat:@"[GC] MONO_GC_PARAMS=%s", getenv("MONO_GC_PARAMS") ?: "?"]);
            sdvEnsureAudioSession("constructor");
            syncBundledLidgren(docs);
            NSString *smapiSyncNote = syncBundledSmapi(docs);
            syncBundledMobileControls(docs);
            NSUInteger hpFiles = sdvDeployActiveHotPatchFiles(docs);
            NSUInteger cpFallbackLinked = syncContentPackLocaleFallbacks(docs);
            sdvBootLogFmt([NSString stringWithFormat:@"[BOOT 2] Bundled Lidgren / SMAPI (%@) / SDVMobileControls synced (ver=%@, hotpatch=%@:%lu, cpLocaleFallbacks=%lu)", smapiSyncNote ?: @"?", sdvEffectiveAppVersion(), hpBootNote ?: @"none", (unsigned long)hpFiles, (unsigned long)cpFallbackLinked]);
            [SDVRamMonitor.shared startWithDocsPath:docs];
            sdvBootLog("[BOOT 3] SDVRamMonitor started");
        } @catch (NSException *ex) {
            sdvBootLogFmt([NSString stringWithFormat:@"[ERR] constructor exception: %@", ex]);
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            sdvBootLog("[BOOT 4] Main runloop active -> starting SDVGardenGestureHost");
            sdvExtInputStart();
            sdvCheckLauncherUpdate(NO, nil);
            gSdvGardenHost = [SDVGardenGestureHost new];
            [gSdvGardenHost attachToGameWindows];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [gSdvGardenHost attachToGameWindows];
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [gSdvGardenHost attachToGameWindows];
            });
            [NSTimer scheduledTimerWithTimeInterval:4.0 repeats:YES block:^(NSTimer *t) {
                (void)t;
                [gSdvGardenHost attachToGameWindows];
            }];
            [gSdvGardenHost startHapticTimer];
        } @catch (NSException *ex) {
            sdvBootLogFmt([NSString stringWithFormat:@"[ERR] main init exception: %@", ex]);
        }
    });
}

#import "ExternalInput.m"
