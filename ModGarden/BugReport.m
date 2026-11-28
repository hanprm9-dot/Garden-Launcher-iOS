// Native Apple-style Online Bug Report & Privacy-Sanitized ErrorLogs.zip + Media (Image/Video) Uploader
// Connects to admin's Cloudflare Worker bridge -> Discord Webhook (keeps Discord URL 100% secret on server!)
#import <sys/sysctl.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>

// Inject private endpoint/key at build time via -include sdv_bug_report_local.h or -DSDV_BUG_REPORT_ENDPOINT=...
// Public source defaults to empty string so no live Worker URL or client key is exposed on GitHub.
#ifndef SDV_BUG_REPORT_ENDPOINT
#define SDV_BUG_REPORT_ENDPOINT ""
#endif
#ifndef SDV_BUG_REPORT_CLIENT_KEY
#define SDV_BUG_REPORT_CLIENT_KEY ""
#endif
static NSString *const kSDVBugReportEndpoint  = @SDV_BUG_REPORT_ENDPOINT;
static NSString *const kSDVBugReportClientKey = @SDV_BUG_REPORT_CLIENT_KEY;
static NSString *const kSDVBugReportLastSentKey = @"sdv_bug_report_last_sent_ts";
static const NSTimeInterval kSDVBugReportCooldownSec = 60.0;
static const NSUInteger kSDVBugReportMaxMediaCount = 3;
static const unsigned long long kSDVBugReportMaxZipBytes         = 3900ULL * 1024ULL;               // <= 3.9 MiB (compatible with both 4 MiB & 7.5 MiB Worker limits)
static const unsigned long long kSDVBugReportMaxSingleMediaBytes = 7ULL * 1024ULL * 1024ULL + 512ULL * 1024ULL; // 7.5 MiB (7,864,320 B)
static const unsigned long long kSDVBugReportMaxTotalUploadBytes = 8ULL * 1024ULL * 1024ULL + 512ULL * 1024ULL; // 8.5 MiB (8,912,896 B)

static NSString *sdvHardwareModelId(void) {
    size_t sz = 0;
    sysctlbyname("hw.machine", NULL, &sz, NULL, 0);
    if (sz == 0 || sz > 64) return UIDevice.currentDevice.model ?: @"iPhone";
    char buf[65] = {0};
    if (sysctlbyname("hw.machine", buf, &sz, NULL, 0) == 0 && buf[0]) {
        return [NSString stringWithUTF8String:buf] ?: @"iPhone";
    }
    return UIDevice.currentDevice.model ?: @"iPhone";
}

static NSString *sdvControlModeDisplayName(NSInteger mode) {
    switch (mode) {
        case 2: return @"2 Nút Pixel";
        case 3: return @"Chạm đi (Tap-to-Move)";
        case 4: return @"Kết hợp (Hybrid)";
        default: return @"Vô hình + 2 thanh dọc";
    }
}

static UIImage *sdvResizeImageMaxSide(UIImage *img, CGFloat maxSide) {
    if (!img) return nil;
    CGSize sz = img.size;
    CGFloat longest = MAX(sz.width, sz.height);
    if (longest <= 0.5) return img;
    CGFloat scale = (longest > maxSide) ? (maxSide / longest) : 1.0;
    CGSize target = CGSizeMake(MAX(1.0, floor(sz.width * scale)), MAX(1.0, floor(sz.height * scale)));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:target format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [img drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
}

static UIImage *sdvMakeVideoThumb(NSURL *videoUrl) {
    if (!videoUrl) return nil;
    @try {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoUrl options:nil];
        AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
        gen.appliesPreferredTrackTransform = YES;
        gen.maximumSize = CGSizeMake(160, 160);
        CMTime t0 = { 0, 1, kCMTimeFlags_Valid, 0 };
        CGImageRef cg = [gen copyCGImageAtTime:t0 actualTime:NULL error:nil];
        if (cg) {
            UIImage *img = [UIImage imageWithCGImage:cg];
            CGImageRelease(cg);
            return img;
        }
    } @catch (NSException *ex) { }
    return nil;
}

static void sdvCompressVideoToMp4(NSURL *srcUrl, NSString *preset, void (^completion)(NSData *mp4Data)) {
    if (!srcUrl || !completion) { if (completion) completion(nil); return; }
    @try {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:srcUrl options:nil];
        AVAssetExportSession *exp = [[AVAssetExportSession alloc] initWithAsset:asset presetName:preset ?: AVAssetExportPresetMediumQuality];
        if (!exp) { completion(nil); return; }
        NSString *outPath = join(NSTemporaryDirectory(), [NSString stringWithFormat:@"sdv_bug_vid_%@.mp4", NSUUID.UUID.UUIDString]);
        [fm() removeItemAtPath:outPath error:nil];
        NSURL *outUrl = [NSURL fileURLWithPath:outPath];
        exp.outputURL = outUrl;
        exp.outputFileType = AVFileTypeMPEG4;
        exp.shouldOptimizeForNetworkUse = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CMTime dur = asset.duration;
#pragma clang diagnostic pop
        if ((dur.flags & kCMTimeFlags_Valid) && dur.timescale > 0) {
            double sec = (double)dur.value / (double)dur.timescale;
            if (sec > 25.0) {
                CMTime tStart = { 0, 1, kCMTimeFlags_Valid, 0 };
                CMTime tLen = { 25, 1, kCMTimeFlags_Valid, 0 };
                CMTimeRange tr = { tStart, tLen };
                exp.timeRange = tr;
            }
        }
        [exp exportAsynchronouslyWithCompletionHandler:^{
            NSData *res = nil;
            if (exp.status == AVAssetExportSessionStatusCompleted) {
                res = [NSData dataWithContentsOfURL:outUrl];
            }
            [fm() removeItemAtPath:outPath error:nil];
            completion(res);
        }];
    } @catch (NSException *ex) {
        completion(nil);
    }
}

static NSString *sdvSafeAsciiMultipartFilename(NSString *raw, NSString *fallback) {
    NSString *src = raw.length ? raw : (fallback ?: @"attachment.bin");
    NSMutableString *out = [NSMutableString stringWithCapacity:src.length];
    for (NSUInteger i = 0; i < src.length && out.length < 64; i++) {
        unichar c = [src characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        [out appendFormat:@"%C", (unichar)(ok ? c : '_')];
    }
    return out.length ? out : (fallback ?: @"attachment.bin");
}

// Masks iOS sandbox container UUIDs and private LAN IPs while keeping all SMAPI/.NET version strings & stack traces intact.
static NSString *sdvSanitizeLogForReport(NSString *raw) {
    if (!raw.length) return @"";
    static NSRegularExpression *reUuid = nil;
    static NSRegularExpression *reLanIp = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reUuid = [NSRegularExpression regularExpressionWithPattern:@"/Containers/Data/Application/[0-9A-Fa-f-]{36}" options:0 error:nil];
        reLanIp = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:192\\.168\\.\\d{1,3}\\.\\d{1,3}|10\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}|172\\.(?:1[6-9]|2\\d|3[01])\\.\\d{1,3}\\.\\d{1,3})\\b" options:0 error:nil];
    });
    NSMutableString *s = [raw mutableCopy];
    if (reUuid) {
        [reUuid replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"/Containers/Data/Application/<APP_ID>"];
    }
    if (reLanIp) {
        [reLanIp replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"<LAN_IP>"];
    }
    return s;
}

static NSData *sdvReadTrimmedLogUtf8(NSString *path, NSUInteger maxBytes) {
    if (![fm() fileExistsAtPath:path]) return nil;
    NSData *raw = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!raw.length) return nil;
    NSString *text = nil;
    if (raw.length <= maxBytes) {
        text = sdvDecodeUtf8Slice(raw, NO, NO);
    } else {
        NSUInteger headLen = MIN((NSUInteger)24576, maxBytes / 4);
        NSUInteger tailLen = maxBytes - headLen;
        NSData *headD = [raw subdataWithRange:NSMakeRange(0, headLen)];
        NSData *tailD = [raw subdataWithRange:NSMakeRange(raw.length - tailLen, tailLen)];
        NSString *hs = sdvDecodeUtf8Slice(headD, NO, YES);
        NSString *ts = sdvDecodeUtf8Slice(tailD, YES, NO);
        NSUInteger skippedKb = (raw.length - headLen - tailLen) / 1024;
        text = [NSString stringWithFormat:@"%@\n\n... [trimmed %lu KB middle log for compact upload] ...\n\n%@",
            hs, (unsigned long)skippedKb, ts];
    }
    if (!text.length) return nil;
    NSString *cleanTxt = sdvSanitizeLogForReport(text);
    return [cleanTxt dataUsingEncoding:NSUTF8StringEncoding];
}

// Builds a compact, privacy-sanitized ErrorLogs.zip plus structured system metadata for online report or Share Sheet export.
static NSDictionary *sdvBuildBugReportBundle(NSString *docsPath) {
    NSString *ipaVer = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: kSDVAppVersion;
    NSString *effVer = sdvEffectiveAppVersion();
    NSString *appVer = [effVer isEqualToString:ipaVer] ? ipaVer : [NSString stringWithFormat:@"%@ (IPA %@)", effVer, ipaVer];
    NSString *iosVer = UIDevice.currentDevice.systemVersion ?: @"?";
    NSString *hwModel = sdvHardwareModelId();
    SDVRamSnapshot ram = [SDVRamMonitor.shared sample];
    NSString *ramInfo = [NSString stringWithFormat:@"Used %@ / Budget %@ (%.0f%%, Avail %@, Device %.1f GB)",
        sdvFmtMemMB(ram.usedBytes), sdvFmtMemMB(ram.budgetBytes), ram.usagePct,
        sdvFmtMemMB(ram.availBytes), (double)ram.deviceBytes / (1024.0 * 1024.0 * 1024.0)];

    SDVMobileCtrlConfig *mc = [SDVMobileCtrlConfig loadFromDocuments:docsPath];
    NSString *ctrlMode = mc.pureGamepadMode ? @"Tay cầm thuần (Pure Gamepad)" : sdvControlModeDisplayName(mc.mode);

    NSArray<NSDictionary *> *catalog = docsPath.length ? (modCatalog(docsPath) ?: @[]) : @[];
    NSArray<NSDictionary *> *issues = docsPath.length ? (sdvDiagnoseMods(docsPath) ?: @[]) : @[];

    NSMutableArray<NSString *> *enabledLines = [NSMutableArray array];
    NSMutableArray<NSString *> *allModLines = [NSMutableArray array];
    for (NSDictionary *m in catalog) {
        BOOL en = [m[@"enabled"] boolValue];
        NSString *nm = m[@"name"] ?: m[@"topFolder"] ?: @"?";
        NSString *ver = m[@"version"] ?: @"";
        NSString *uid = m[@"uniqueID"] ?: @"";
        NSString *line = ver.length ? [NSString stringWithFormat:@"%@ (%@)", nm, ver] : nm;
        if (en) [enabledLines addObject:line];
        [allModLines addObject:[NSString stringWithFormat:@"[%@] %@ | ID=%@ | Folder=%@",
            en ? @"ON " : @"OFF", line, uid, m[@"topFolder"] ?: @""]];
    }
    NSString *modsShort = enabledLines.count ? [enabledLines componentsJoinedByString:@"\n"] : @"Không có mod nào đang bật";
    if (modsShort.length > 900) modsShort = [sdvSafeTruncateUtf16(modsShort, 896) stringByAppendingString:@"\n..."];

    NSMutableArray<NSString *> *issueLines = [NSMutableArray array];
    for (NSDictionary *it in issues) {
        NSString *sev = [it[@"severity"] isEqualToString:@"error"] ? @"ERROR" : ([it[@"severity"] isEqualToString:@"info"] ? @"INFO" : @"WARN");
        [issueLines addObject:[NSString stringWithFormat:@"[%@] %@: %@", sev, it[@"title"] ?: @"", it[@"detail"] ?: @""]];
    }
    NSString *issueShort = issueLines.count ? [issueLines componentsJoinedByString:@"\n"] : @"";
    if (issueShort.length > 850) issueShort = [sdvSafeTruncateUtf16(issueShort, 846) stringByAppendingString:@"\n..."];

    NSString *vid = UIDevice.currentDevice.identifierForVendor.UUIDString ?: hwModel;
    NSString *devHash = [hashData([vid dataUsingEncoding:NSUTF8StringEncoding]) substringToIndex:16];

    NSMutableString *sysTxt = [NSMutableString string];
    [sysTxt appendFormat:@"Garden Launcher iOS Bug Report Diagnostics\n"];
    [sysTxt appendFormat:@"==========================================\n"];
    [sysTxt appendFormat:@"Timestamp   : %@\n", NSDate.date];
    [sysTxt appendFormat:@"App Version : %@\n", appVer];
    [sysTxt appendFormat:@"Device      : %@\n", hwModel];
    [sysTxt appendFormat:@"iOS Version : %@\n", iosVer];
    [sysTxt appendFormat:@"RAM         : %@\n", ramInfo];
    NSString *ecoFpsStr = (mc.batterySaverFpsMode == 1) ? @"30" : ((mc.batterySaverFpsMode == 2) ? @"45" : @"60");
    [sysTxt appendFormat:@"Control Mode: %@ (VerticalTB=%d, AutoTool=%d, AutoAttack=%d, EcoFPS=%@, ReduceWeather=%d)\n",
        ctrlMode, mc.verticalToolbar ? 1 : 0, mc.autoTool ? 1 : 0, mc.autoAttack ? 1 : 0,
        ecoFpsStr, mc.reduceWeather ? 1 : 0];
    [sysTxt appendFormat:@"\nInstalled Mods (%lu enabled / %lu total):\n", (unsigned long)enabledLines.count, (unsigned long)allModLines.count];
    for (NSString *ml in allModLines) [sysTxt appendFormat:@"  %@\n", ml];
    if (issueLines.count) {
        [sysTxt appendFormat:@"\nMod Diagnostics (%lu):\n", (unsigned long)issueLines.count];
        for (NSString *il in issueLines) [sysTxt appendFormat:@"  %@\n", il];
    }

    NSString *tmpDir = NSTemporaryDirectory();
    NSDate *nowSweep = NSDate.date;
    for (NSString *fn in ([fm() contentsOfDirectoryAtPath:tmpDir error:nil] ?: @[])) {
        if ([fn hasPrefix:@"GardenLauncher-ErrorLogs"] && [fn hasSuffix:@".zip"]) {
            NSString *oldP = join(tmpDir, fn);
            NSDate *mdt = [fm() attributesOfItemAtPath:oldP error:nil][NSFileModificationDate];
            if (mdt && [nowSweep timeIntervalSinceDate:mdt] > 600.0) {
                [fm() removeItemAtPath:oldP error:nil];
            }
        }
    }
    NSString *zipPath = join(tmpDir, [NSString stringWithFormat:@"GardenLauncher-ErrorLogs-%@.zip", NSUUID.UUID.UUIDString]);
    [fm() removeItemAtPath:zipPath error:nil];

    NSUInteger fileCount = 0;
    mz_zip_archive z = {0};
    if (mz_zip_writer_init_file(&z, zipPath.fileSystemRepresentation, 0)) {
        NSData *sysData = [sysTxt dataUsingEncoding:NSUTF8StringEncoding];
        if (sysData.length && mz_zip_writer_add_mem(&z, "system-summary.txt", sysData.bytes, sysData.length, MZ_DEFAULT_COMPRESSION)) {
            fileCount++;
        }

        NSString *errDir = docsPath.length ? join(docsPath, @"ErrorLogs") : @"";
        NSArray<NSArray *> *logSpecs = @[
            @[@"SMAPI-latest.txt",             @(768 * 1024)],
            @[@"SMAPI-previous.txt",           @(384 * 1024)],
            @[@"engine-latest.log",            @(512 * 1024)],
            @[@"shader-diag.log",              @(256 * 1024)],
            @[@"ram-monitor.log",              @(256 * 1024)],
            @[@"ram-monitor-previous.log",     @(128 * 1024)],
            @[@"launcher-boot.log",            @(256 * 1024)],
            @[@"launcher-boot-previous.log",   @(128 * 1024)],
            @[@"audio-diag.log",               @(128 * 1024)],
            @[@"native-crash.log",             @(256 * 1024)],
            @[@"crash-latest.log",             @(256 * 1024)],
            @[@"crash-previous.log",           @(256 * 1024)]
        ];
        if (errDir.length && dir(errDir)) {
            for (NSArray *spec in logSpecs) {
                NSString *fn = spec[0];
                NSUInteger cap = [spec[1] unsignedIntegerValue];
                NSData *d = sdvReadTrimmedLogUtf8(join(errDir, fn), cap);
                if (d.length && mz_zip_writer_add_mem(&z, fn.UTF8String, d.bytes, d.length, MZ_DEFAULT_COMPRESSION)) {
                    fileCount++;
                }
            }
        }
        mz_zip_writer_finalize_archive(&z);
        mz_zip_writer_end(&z);
    }

    NSDictionary *attrs = [fm() attributesOfItemAtPath:zipPath error:nil];
    unsigned long long zipBytes = [attrs[NSFileSize] unsignedLongLongValue];
    NSURL *zipUrl = (zipBytes > 0) ? [NSURL fileURLWithPath:zipPath] : nil;

    return @{
        @"url": zipUrl ?: NSNull.null,
        @"bytes": @(zipBytes),
        @"fileCount": @(fileCount),
        @"appVersion": appVer,
        @"iosVersion": iosVer,
        @"device": hwModel,
        @"ramInfo": ramInfo,
        @"controlMode": ctrlMode,
        @"modCount": [NSString stringWithFormat:@"%lu/%lu", (unsigned long)enabledLines.count, (unsigned long)allModLines.count],
        @"modsSummary": modsShort,
        @"issueSummary": issueShort,
        @"deviceHash": devHash
    };
}

static NSData *sdvBuildMultipartBody(
    NSDictionary<NSString *, NSString *> *fields,
    NSData *zipData,
    NSString *zipFilename,
    NSArray<NSDictionary *> *mediaItems,
    NSString *boundary
) {
    NSMutableData *body = [NSMutableData data];
    NSString *crlf = @"\r\n";
    for (NSString *k in [fields.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *v = fields[k] ?: @"";
        [body appendData:[[NSString stringWithFormat:@"--%@%@", boundary, crlf] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"%@%@", k, crlf, crlf] dataUsingEncoding:NSUTF8StringEncoding]];
        NSData *valData = [v dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES] ?: [NSData data];
        [body appendData:valData];
        [body appendData:[crlf dataUsingEncoding:NSUTF8StringEncoding]];
    }
    if (zipData.length) {
        [body appendData:[[NSString stringWithFormat:@"--%@%@", boundary, crlf] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"%@", zipFilename ?: @"ErrorLogs.zip", crlf] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:@"Content-Type: application/zip%@%@", crlf, crlf] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:zipData];
        [body appendData:[crlf dataUsingEncoding:NSUTF8StringEncoding]];
    }
    for (NSUInteger i = 0; i < mediaItems.count && i < kSDVBugReportMaxMediaCount; i++) {
        NSDictionary *item = mediaItems[i];
        NSData *md = item[@"data"];
        if (!md.length) continue;
        NSString *fn = sdvSafeAsciiMultipartFilename(item[@"name"], [NSString stringWithFormat:@"media_%lu.bin", (unsigned long)(i + 1)]);
        NSString *mime = item[@"mime"] ?: @"application/octet-stream";
        [body appendData:[[NSString stringWithFormat:@"--%@%@", boundary, crlf] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"media%lu\"; filename=\"%@\"%@", (unsigned long)i, fn, crlf] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:@"Content-Type: %@%@%@", mime, crlf, crlf] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:md];
        [body appendData:[crlf dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [body appendData:[[NSString stringWithFormat:@"--%@--%@", boundary, crlf] dataUsingEncoding:NSUTF8StringEncoding]];
    return body;
}

@interface SDVBugReportViewController : UIViewController <UITextViewDelegate, UITextFieldDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *docsPath;
@property(nonatomic, assign) BOOL embeddedInTab;
-(void)refreshBundleIfNeeded;
@end

@implementation SDVBugReportViewController {
    UIScrollView *_scroll;
    NSArray<NSString *> *_categories;
    NSMutableArray<SDVAppleButton *> *_catBtns;
    NSInteger _selectedCat;
    UITextView *_descView;
    UILabel *_descPlaceholder;
    UILabel *_charCountLbl;
    UITextField *_contactField;
    NSMutableArray<NSDictionary *> *_mediaItems; // @{@"name", @"mime", @"data", @"thumb", @"isVideo"}
    NSUInteger _mediaSeq;
    NSInteger _pendingMediaLoads;
    UIStackView *_mediaListStack;
    UILabel *_mediaHintLbl;
    SDVAppleButton *_addMediaBtn;
    UISwitch *_attachSwitch;
    UILabel *_zipStatusLbl;
    UILabel *_sysInfoLbl;
    SDVAppleButton *_sendBtn;
    SDVAppleButton *_shareBtn;
    UIActivityIndicatorView *_spinner;
    NSDictionary *_bundle;
    CFTimeInterval _bundleBuiltAt;
    BOOL _sending;
}

-(UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

-(void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

-(void)viewDidLoad {
    [super viewDidLoad];
    if (self.embeddedInTab) {
        self.view.backgroundColor = UIColor.clearColor;
    } else {
        self.view.backgroundColor = kBgCanvas;
        SDVAuroraCanvasView *aurora = [SDVAuroraCanvasView new];
        [self.view insertSubview:aurora atIndex:0];
        pinAll(aurora, self.view, 0);
    }
    _categories = @[
        @"Văng game (Crash)",
        @"Lỗi Mod / Xung đột",
        @"Điều khiển / Cảm ứng",
        @"Đồ họa / Shader",
        @"Âm thanh",
        @"Save / Co-op / Khác"
    ];
    _selectedCat = 0;
    _catBtns = [NSMutableArray array];
    _mediaItems = [NSMutableArray array];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;

    UIVisualEffectView *bar = nil;
    if (!self.embeddedInTab) {
        // Translucent Apple Top Bar (modal presentation only)
        bar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:bar];

        UIView *sep = mkHairline();
        [bar.contentView addSubview:sep];
        [NSLayoutConstraint activateConstraints:@[
            [sep.leadingAnchor constraintEqualToAnchor:bar.contentView.leadingAnchor],
            [sep.trailingAnchor constraintEqualToAnchor:bar.contentView.trailingAnchor],
            [sep.bottomAnchor constraintEqualToAnchor:bar.contentView.bottomAnchor]
        ]];

        UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [cancelBtn setTitle:@"Đóng" forState:UIControlStateNormal];
        cancelBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        [cancelBtn addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];
        cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *titleLbl = mkLabel(@"Báo lỗi cho Admin", 16.5, UIFontWeightSemibold, kInkPrimary);
        titleLbl.textAlignment = NSTextAlignmentCenter;

        UIStackView *barRow = mkHStack(8);
        [barRow addArrangedSubview:cancelBtn];
        [barRow addArrangedSubview:[UIView new]];
        [barRow addArrangedSubview:titleLbl];
        [barRow addArrangedSubview:[UIView new]];
        [barRow addArrangedSubview:_spinner];
        [bar.contentView addSubview:barRow];
        pinInsets(barRow, bar.contentView, UIEdgeInsetsMake(0, 16, 0, 16));
    }

    _scroll = [UIScrollView new];
    _scroll.backgroundColor = UIColor.clearColor;
    _scroll.alwaysBounceVertical = YES;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_scroll];

    UITapGestureRecognizer *tapDismiss = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(endEditingNow)];
    tapDismiss.cancelsTouchesInView = NO;
    [_scroll addGestureRecognizer:tapDismiss];

    UIStackView *pane = mkVStack(12);
    pane.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:pane];

    if (bar) {
        [NSLayoutConstraint activateConstraints:@[
            [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [bar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [bar.bottomAnchor constraintEqualToAnchor:safe.topAnchor constant:44],

            [_scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
            [_scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
            [_scroll.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
            [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
        ]];

        UIStackView *hdrRow = mkHStack(10);
        [hdrRow addArrangedSubview:mkSettingsIconBadge(@"ladybug.fill", kTintRed, 34)];
        UIStackView *hdrTxt = mkVStack(1.5);
        [hdrTxt addArrangedSubview:mkLabel(@"Gửi báo lỗi trực tuyến cho Admin", 15, UIFontWeightSemibold, kInkPrimary)];
        [hdrTxt addArrangedSubview:mkLabel(@"Chọn loại lỗi, đính kèm ảnh/video & tệp nén ErrorLogs.zip (đã tự ẩn mã máy & IP LAN).", 12, UIFontWeightRegular, kInkSecondary)];
        [hdrRow addArrangedSubview:hdrTxt];
        [hdrRow addArrangedSubview:_spinner];
        [pane addArrangedSubview:mkGroupedCard(hdrRow, UIEdgeInsetsMake(11, 14, 11, 14))];
    }

    [NSLayoutConstraint activateConstraints:@[
        [pane.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor constant:16],
        [pane.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [pane.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:12],
        [pane.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [pane.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-32]
    ]];

    // 1. Category Grid (2 rows x 3 cols)
    [pane addArrangedSubview:mkSectionTitle(@"1. Chọn loại lỗi bạn gặp")];
    UIStackView *catCard = mkVStack(8);
    for (NSInteger row = 0; row < 2; row++) {
        UIStackView *r = mkHStack(8);
        r.distribution = UIStackViewDistributionFillEqually;
        for (NSInteger col = 0; col < 3; col++) {
            NSInteger idx = row * 3 + col;
            SDVAppleButton *b = mkIOSButton(_categories[idx], nil, kBgCardSubtle, kInkPrimary, 12.5, UIEdgeInsetsMake(9, 8, 9, 8));
            b.tag = idx;
            b.layer.cornerRadius = 9.5;
            b.titleLabel.adjustsFontSizeToFitWidth = YES;
            b.titleLabel.minimumScaleFactor = 0.80;
            [b addTarget:self action:@selector(catTapped:) forControlEvents:UIControlEventTouchUpInside];
            [r addArrangedSubview:b];
            [_catBtns addObject:b];
        }
        [catCard addArrangedSubview:r];
    }
    [pane addArrangedSubview:mkGroupedCard(catCard, UIEdgeInsetsMake(11, 12, 11, 12))];
    [self refreshCategoryStyles];

    // 2. Description Card
    [pane addArrangedSubview:mkSectionTitle(@"2. Mô tả chi tiết vấn đề")];
    UIStackView *descCard = mkVStack(6);
    UIView *tvWrap = [UIView new];
    tvWrap.backgroundColor = kBgCardSubtle;
    tvWrap.layer.cornerRadius = 10;
    tvWrap.layer.borderWidth = 0.5;
    tvWrap.layer.borderColor = kSepColor.CGColor;
    tvWrap.translatesAutoresizingMaskIntoConstraints = NO;
    [tvWrap.heightAnchor constraintEqualToConstant:92].active = YES;

    _descView = [UITextView new];
    _descView.backgroundColor = UIColor.clearColor;
    _descView.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    _descView.textColor = kInkPrimary;
    _descView.delegate = self;
    _descView.textContainerInset = UIEdgeInsetsMake(8, 6, 8, 6);
    _descView.translatesAutoresizingMaskIntoConstraints = NO;
    [tvWrap addSubview:_descView];
    pinAll(_descView, tvWrap, 0);

    _descPlaceholder = mkLabel(@"Ghi rõ lỗi xảy ra lúc nào, bạn đang làm gì hoặc cài mod nào (tối thiểu 8 ký tự)…", 13, UIFontWeightRegular, kInkTertiary);
    _descPlaceholder.userInteractionEnabled = NO;
    [tvWrap addSubview:_descPlaceholder];
    [NSLayoutConstraint activateConstraints:@[
        [_descPlaceholder.leadingAnchor constraintEqualToAnchor:tvWrap.leadingAnchor constant:11],
        [_descPlaceholder.trailingAnchor constraintEqualToAnchor:tvWrap.trailingAnchor constant:-11],
        [_descPlaceholder.topAnchor constraintEqualToAnchor:tvWrap.topAnchor constant:8]
    ]];

    UIStackView *descFoot = mkHStack(6);
    [descFoot addArrangedSubview:mkLabel(@"Mô tả càng rõ, admin càng dễ tìm đúng nguyên nhân.", 11.5, UIFontWeightRegular, kInkSecondary)];
    [descFoot addArrangedSubview:[UIView new]];
    _charCountLbl = mkLabel(@"0 / 2000", 11.5, UIFontWeightMedium, kInkTertiary);
    _charCountLbl.font = iosMonoDigits(11.5, UIFontWeightMedium);
    [descFoot addArrangedSubview:_charCountLbl];

    [descCard addArrangedSubview:tvWrap];
    [descCard addArrangedSubview:descFoot];
    [pane addArrangedSubview:mkGroupedCard(descCard, UIEdgeInsetsMake(11, 12, 10, 12))];

    // 3. Optional Images / Video Attachments (up to 3 items, auto-compressed for Discord!)
    [pane addArrangedSubview:mkSectionTitle(@"3. Ảnh chụp màn hình / Video minh họa (tùy chọn)")];
    UIStackView *mediaCard = mkVStack(8);
    UIStackView *mediaHdr = mkHStack(10);
    [mediaHdr addArrangedSubview:mkSettingsIconBadge(@"photo.on.rectangle.angled", kTintPurple, 30)];
    UIStackView *mediaTxt = mkVStack(1.5);
    [mediaTxt addArrangedSubview:mkLabel(@"Đính kèm Ảnh hoặc Video ngắn", 13.5, UIFontWeightSemibold, kInkPrimary)];
    _mediaHintLbl = mkLabel(@"Tối đa 3 tệp · Ảnh tự nén gọn · Video ngắn ≤ 7.5 MB (tối đa ~25 giây)", 11.5, UIFontWeightRegular, kInkSecondary);
    [mediaTxt addArrangedSubview:_mediaHintLbl];
    _addMediaBtn = mkIOSButton(@"Thêm Ảnh/Video", @"plus.circle.fill", [kTintPurple colorWithAlphaComponent:0.14], kTintPurple, 12.5, UIEdgeInsetsMake(8, 11, 8, 11));
    [_addMediaBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_addMediaBtn addTarget:self action:@selector(addMediaTapped:) forControlEvents:UIControlEventTouchUpInside];
    [mediaHdr addArrangedSubview:mediaTxt];
    [mediaHdr addArrangedSubview:_addMediaBtn];
    [mediaCard addArrangedSubview:mediaHdr];

    _mediaListStack = mkVStack(6);
    _mediaListStack.hidden = YES;
    [mediaCard addArrangedSubview:_mediaListStack];
    [pane addArrangedSubview:mkGroupedCard(mediaCard, UIEdgeInsetsMake(11, 12, 11, 12))];

    // 4. Optional Contact Field
    [pane addArrangedSubview:mkSectionTitle(@"4. Liên hệ lại (không bắt buộc)")];
    UIView *cfWrap = [UIView new];
    cfWrap.backgroundColor = kBgCard;
    cfWrap.layer.cornerRadius = 13;
    cfWrap.layer.cornerCurve = kCACornerCurveContinuous;
    cfWrap.translatesAutoresizingMaskIntoConstraints = NO;
    _contactField = [UITextField new];
    _contactField.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    _contactField.textColor = kInkPrimary;
    _contactField.placeholder = @"Tên Facebook / Discord / Zalo nếu muốn admin phản hồi";
    _contactField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _contactField.returnKeyType = UIReturnKeyDone;
    _contactField.delegate = self;
    _contactField.translatesAutoresizingMaskIntoConstraints = NO;
    [cfWrap addSubview:_contactField];
    pinInsets(_contactField, cfWrap, UIEdgeInsetsMake(11, 14, 11, 14));
    [pane addArrangedSubview:cfWrap];

    // 5. ErrorLogs.zip Attachment & Privacy Info
    [pane addArrangedSubview:mkSectionTitle(@"5. Tệp nhật ký lỗi (ErrorLogs.zip) & Thông tin máy")];
    UIStackView *logRow = mkHStack(10);
    [logRow addArrangedSubview:mkSettingsIconBadge(@"doc.zipper", kTintOrange, 30)];
    UIStackView *logTxt = mkVStack(1.5);
    [logTxt addArrangedSubview:mkLabel(@"Đính kèm ErrorLogs.zip (khuyên bật)", 13.5, UIFontWeightSemibold, kInkPrimary)];
    _zipStatusLbl = mkLabel(@"Đang nén nhật ký lỗi & ẩn thông tin riêng tư…", 11.5, UIFontWeightRegular, kInkSecondary);
    [logTxt addArrangedSubview:_zipStatusLbl];
    _attachSwitch = [UISwitch new];
    _attachSwitch.on = YES;
    _attachSwitch.onTintColor = kTintGreen;
    [_attachSwitch setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [logRow addArrangedSubview:logTxt];
    [logRow addArrangedSubview:_attachSwitch];

    UIStackView *sysRow = mkHStack(10);
    [sysRow addArrangedSubview:mkSettingsIconBadge(@"iphone", kTintBlue, 30)];
    UIStackView *sysTxt = mkVStack(1.5);
    [sysTxt addArrangedSubview:mkLabel(@"Thông tin kỹ thuật gửi kèm (ẩn IP & mã định danh)", 12.5, UIFontWeightSemibold, kInkPrimary)];
    _sysInfoLbl = mkLabel(@"Đang thu thập thông tin thiết bị…", 11.5, UIFontWeightRegular, kInkSecondary);
    [sysTxt addArrangedSubview:_sysInfoLbl];
    [sysRow addArrangedSubview:sysTxt];

    [pane addArrangedSubview:mkGroupedRows(@[logRow, sysRow], 48)];

    // 6. Action Buttons
    UIStackView *actRow = mkHStack(10);
    _sendBtn = mkIOSButton(@"Gửi báo lỗi online", @"paperplane.fill", kTintBlue, UIColor.whiteColor, 14.5, UIEdgeInsetsMake(12, 14, 12, 14));
    [_sendBtn addTarget:self action:@selector(sendReportTapped) forControlEvents:UIControlEventTouchUpInside];
    _shareBtn = mkIOSButton(@"Xuất ErrorLogs.zip", @"square.and.arrow.up", kBgCard, kInkPrimary, 13.5, UIEdgeInsetsMake(12, 14, 12, 14));
    [_shareBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_shareBtn addTarget:self action:@selector(shareZipTapped:) forControlEvents:UIControlEventTouchUpInside];
    [actRow addArrangedSubview:_sendBtn];
    [actRow addArrangedSubview:_shareBtn];
    [pane addArrangedSubview:actRow];

    SDVAppleButton *discordHelpBtn = mkIOSButton(@"Cần hỗ trợ trực tiếp? Tham gia Server Discord Garden Launcher", @"bubble.left.and.bubble.right.fill", rgba(0x5865F2, 0.14), rgb(0x5865F2), 13.0, UIEdgeInsetsMake(10, 14, 10, 14));
    [discordHelpBtn addTarget:self action:@selector(openDiscordSupportTapped) forControlEvents:UIControlEventTouchUpInside];
    [pane addArrangedSubview:discordHelpBtn];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(kbWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(kbWillHide:) name:UIKeyboardWillHideNotification object:nil];

    [self refreshBundleIfNeeded];
}

-(void)refreshBundleIfNeeded {
    if (_sending) return;
    if (!self.isViewLoaded) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (_bundle != nil && _bundleBuiltAt > 0 && (now - _bundleBuiltAt) < 15.0) {
        return;
    }
    NSString *docs = self.docsPath ?: @"";
    _zipStatusLbl.text = @"Đang gom & ẩn danh thông tin nhạy cảm…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *b = sdvBuildBugReportBundle(docs);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_bundle = b;
            self->_bundleBuiltAt = CACurrentMediaTime();
            unsigned long long bytes = [b[@"bytes"] unsignedLongLongValue];
            NSUInteger cnt = [b[@"fileCount"] unsignedIntegerValue];
            self->_zipStatusLbl.text = (bytes > 0)
                ? [NSString stringWithFormat:@"Sẵn sàng · %lu tệp log · %@ (đã tự ẩn mã máy & IP LAN)", (unsigned long)cnt, formatBytes(bytes)]
                : @"Chưa có tệp log lỗi (sẽ gửi thông tin máy & danh sách mod)";
            self->_sysInfoLbl.text = [NSString stringWithFormat:@"%@ · iOS %@ · v%@ · Mod: %@ · %@",
                b[@"device"], b[@"iosVersion"], b[@"appVersion"], b[@"modCount"], b[@"controlMode"]];
        });
    });
}

-(void)kbWillShow:(NSNotification *)n {
    CGRect screenFr = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect localFr = [self.view convertRect:screenFr fromView:nil];
    CGFloat overlap = MAX(0.0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(localFr));
    UIEdgeInsets ins = UIEdgeInsetsMake(0, 0, overlap > 1.0 ? (overlap + 14.0) : 0.0, 0);
    _scroll.contentInset = ins;
    _scroll.scrollIndicatorInsets = ins;
}
-(void)kbWillHide:(NSNotification *)n {
    (void)n;
    _scroll.contentInset = UIEdgeInsetsZero;
    _scroll.scrollIndicatorInsets = UIEdgeInsetsZero;
}
-(void)endEditingNow { [self.view endEditing:YES]; }
-(void)openDiscordSupportTapped {
    NSString *s = sdvDiscordInviteURL();
    if (!s.length) return;
    UIPasteboard.generalPasteboard.string = s;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    NSURL *u = [NSURL URLWithString:s];
    if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
}
-(void)dismissSelf {
    if (self.embeddedInTab) {
        _descView.text = @"";
        [self textViewDidChange:_descView];
        [_mediaItems removeAllObjects];
        _mediaSeq = 0;
        [self rebuildMediaListUI];
        _bundleBuiltAt = 0;
        [self refreshBundleIfNeeded];
        return;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

-(void)refreshCategoryStyles {
    for (NSInteger i = 0; i < (NSInteger)_catBtns.count; i++) {
        SDVAppleButton *b = _catBtns[i];
        BOOL sel = (i == _selectedCat);
        b.backgroundColor = sel ? kTintBlue : kBgCardSubtle;
        [b setTitleColor:(sel ? UIColor.whiteColor : kInkPrimary) forState:UIControlStateNormal];
    }
}

-(void)catTapped:(UIButton *)btn {
    _selectedCat = btn.tag;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self refreshCategoryStyles];
}

-(unsigned long long)totalMediaBytes {
    unsigned long long sum = 0;
    for (NSDictionary *it in _mediaItems) {
        sum += ((NSData *)it[@"data"]).length;
    }
    return sum;
}

-(void)rebuildMediaListUI {
    for (UIView *v in [_mediaListStack.arrangedSubviews copy]) {
        [_mediaListStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    _mediaListStack.hidden = (_mediaItems.count == 0);
    _addMediaBtn.enabled = (_mediaItems.count < kSDVBugReportMaxMediaCount);
    _addMediaBtn.alpha = _addMediaBtn.enabled ? 1.0 : 0.45;

    if (_mediaItems.count == 0) {
        _mediaHintLbl.text = @"Tối đa 3 tệp · Ảnh tự nén gọn · Video ngắn ≤ 7.5 MB (tối đa ~25 giây)";
    } else {
        _mediaHintLbl.text = [NSString stringWithFormat:@"Đã đính kèm %lu/%lu tệp · Tổng %@",
            (unsigned long)_mediaItems.count, (unsigned long)kSDVBugReportMaxMediaCount, formatBytes([self totalMediaBytes])];
    }

    for (NSUInteger i = 0; i < _mediaItems.count; i++) {
        NSDictionary *it = _mediaItems[i];
        UIView *rowBg = [UIView new];
        rowBg.backgroundColor = kBgCardSubtle;
        rowBg.layer.cornerRadius = 9.5;
        rowBg.translatesAutoresizingMaskIntoConstraints = NO;

        UIStackView *row = mkHStack(9);
        UIImage *thumb = [it[@"thumb"] isKindOfClass:UIImage.class] ? it[@"thumb"] : nil;
        if (thumb) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:thumb];
            iv.contentMode = UIViewContentModeScaleAspectFill;
            iv.clipsToBounds = YES;
            iv.layer.cornerRadius = 6.5;
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            [iv.widthAnchor constraintEqualToConstant:36].active = YES;
            [iv.heightAnchor constraintEqualToConstant:36].active = YES;
            [row addArrangedSubview:iv];
        } else {
            BOOL isVid = [it[@"isVideo"] boolValue];
            [row addArrangedSubview:mkSettingsIconBadge(isVid ? @"film.fill" : @"photo.fill", isVid ? kTintOrange : kTintBlue, 32)];
        }

        UIStackView *txt = mkVStack(1);
        [txt addArrangedSubview:mkLabel(it[@"name"] ?: @"media", 12.5, UIFontWeightSemibold, kInkPrimary)];
        NSData *d = it[@"data"];
        NSString *kind = [it[@"isVideo"] boolValue] ? @"Video" : @"Hình ảnh";
        [txt addArrangedSubview:mkLabel([NSString stringWithFormat:@"%@ · %@", kind, formatBytes(d.length)], 11.5, UIFontWeightRegular, kInkSecondary)];
        [row addArrangedSubview:txt];

        SDVAppleButton *rmBtn = mkIOSButton(@"Xóa", @"xmark", [kTintRed colorWithAlphaComponent:0.12], kTintRed, 11.5, UIEdgeInsetsMake(6, 9, 6, 9));
        rmBtn.tag = (NSInteger)i;
        rmBtn.layer.cornerRadius = 7.5;
        [rmBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [rmBtn addTarget:self action:@selector(removeMediaTapped:) forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:rmBtn];

        [rowBg addSubview:row];
        pinInsets(row, rowBg, UIEdgeInsetsMake(6, 8, 6, 8));
        [_mediaListStack addArrangedSubview:rowBg];
    }
}

-(void)removeMediaTapped:(UIButton *)btn {
    NSInteger idx = btn.tag;
    if (idx < 0 || idx >= (NSInteger)_mediaItems.count) return;
    [_mediaItems removeObjectAtIndex:(NSUInteger)idx];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self rebuildMediaListUI];
}

-(void)beginMediaLoad {
    _pendingMediaLoads++;
    [_spinner startAnimating];
}

-(void)endMediaLoad {
    if (_pendingMediaLoads > 0) _pendingMediaLoads--;
    if (_pendingMediaLoads == 0 && !_sending) {
        [_spinner stopAnimating];
    }
}

-(void)processPickedVideoAtTempUrl:(NSURL *)tempUrl suggestedExt:(NSString *)extHint cleanupTemp:(BOOL)cleanupTemp {
    unsigned long long rawBytes = [[fm() attributesOfItemAtPath:tempUrl.path error:nil][NSFileSize] unsignedLongLongValue];
    if (rawBytes == 0 || rawBytes > 200ULL * 1024ULL * 1024ULL) {
        if (cleanupTemp) [fm() removeItemAtURL:tempUrl error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self endMediaLoad];
            if (rawBytes > 200ULL * 1024ULL * 1024ULL) {
                [self showAlertTitle:@"Video quá lớn (> 200 MB)"
                    msg:@"Để tránh tràn RAM văng game trên iOS, vui lòng cắt ngắn đoạn video quay lỗi dưới ~25 giây trước khi đính kèm."
                    closeAfter:NO];
            } else {
                [self showAlertTitle:@"Không đọc được video" msg:@"Tệp video trống hoặc không truy cập được." closeAfter:NO];
            }
        });
        return;
    }

    UIImage *thumb = sdvMakeVideoThumb(tempUrl);
    NSString *ext = (extHint.length ? extHint : tempUrl.pathExtension).lowercaseString;
    BOOL isMp4 = [ext isEqualToString:@"mp4"] || [ext isEqualToString:@"m4v"];

    void (^finishWithData)(NSData *, BOOL) = ^(NSData *finalData, BOOL forceMp4) {
        if (cleanupTemp) [fm() removeItemAtURL:tempUrl error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self endMediaLoad];
            if (!finalData.length || finalData.length > kSDVBugReportMaxSingleMediaBytes) {
                [self showAlertTitle:@"Video vượt giới hạn 7.5 MB"
                    msg:@"Sau khi nén tối đa, video vẫn lớn hơn 7.5 MB. Vui lòng cắt ngắn đoạn video (khoảng 10–20 giây) rồi thử lại."
                    closeAfter:NO];
                return;
            }
            self->_mediaSeq++;
            BOOL outMp4 = forceMp4 || isMp4;
            NSString *fn = [NSString stringWithFormat:@"video_%lu.%@", (unsigned long)self->_mediaSeq, outMp4 ? @"mp4" : @"mov"];
            NSString *mime = outMp4 ? @"video/mp4" : @"video/quicktime";
            [self appendPreparedMediaData:finalData name:fn mime:mime thumb:thumb isVideo:YES];
        });
    };

    if (rawBytes <= kSDVBugReportMaxSingleMediaBytes) {
        NSData *smallRaw = [NSData dataWithContentsOfURL:tempUrl options:NSDataReadingMappedIfSafe error:nil];
        if (smallRaw.length > 0 && smallRaw.length <= kSDVBugReportMaxSingleMediaBytes) {
            finishWithData(smallRaw, NO);
            return;
        }
    }

    // Video exceeds 7.5 MB (up to 200 MB): stream-transcode directly from disk URL without reading raw video into RAM!
    sdvCompressVideoToMp4(tempUrl, AVAssetExportPresetMediumQuality, ^(NSData *medData) {
        if (medData.length > 0 && medData.length <= kSDVBugReportMaxSingleMediaBytes) {
            finishWithData(medData, YES);
            return;
        }
        sdvCompressVideoToMp4(tempUrl, AVAssetExportPresetLowQuality, ^(NSData *lowData) {
            finishWithData((lowData.length > 0 && lowData.length <= kSDVBugReportMaxSingleMediaBytes) ? lowData : nil, YES);
        });
    });
}

-(void)addMediaTapped:(UIButton *)sender {
    [self endEditingNow];
    if (_mediaItems.count >= kSDVBugReportMaxMediaCount) {
        [self showAlertTitle:@"Đã đủ 3 tệp" msg:@"Mỗi báo lỗi đính kèm tối đa 3 ảnh/video. Hãy xóa bớt nếu muốn thay tệp khác." closeAfter:NO];
        return;
    }
    NSInteger remaining = (NSInteger)kSDVBugReportMaxMediaCount - (NSInteger)_mediaItems.count;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Thêm Ảnh hoặc Video minh họa"
        message:@"Chọn từ Thư viện Ảnh iPhone (hỗ trợ xoay ngang & chọn nhiều tệp) hoặc chọn tệp từ ứng dụng Tệp."
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Thư viện Ảnh & Video" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
        cfg.selectionLimit = MAX(1, remaining);
        cfg.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCompatible;
        cfg.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[PHPickerFilter.imagesFilter, PHPickerFilter.videosFilter]];
        PHPickerViewController *pk = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        pk.delegate = self;
        pk.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:pk animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Chọn từ ứng dụng Tệp (Files)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        NSArray<UTType *> *types = @[UTTypeImage, UTTypeMovie, UTTypeMPEG4Movie, UTTypeQuickTimeMovie];
        UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
        dp.allowsMultipleSelection = NO;
        dp.delegate = self;
        dp.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:dp animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = sender ?: self.view;
        sheet.popoverPresentationController.sourceRect = sender ? sender.bounds : CGRectMake(self.view.bounds.size.width * 0.5, self.view.bounds.size.height * 0.5, 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

-(void)appendPreparedMediaData:(NSData *)data name:(NSString *)name mime:(NSString *)mime thumb:(UIImage *)thumb isVideo:(BOOL)isVideo {
    if (_mediaItems.count >= kSDVBugReportMaxMediaCount) {
        return;
    }
    if (!data.length) {
        [self showAlertTitle:@"Không đọc được tệp" msg:@"Tệp ảnh/video trống hoặc định dạng không hỗ trợ." closeAfter:NO];
        return;
    }
    if (data.length > kSDVBugReportMaxSingleMediaBytes) {
        [self showAlertTitle:@"Tệp quá lớn (> 7.5 MB)"
            msg:[NSString stringWithFormat:@"Tệp '%@' nặng %@ (sau nén vẫn vượt 7.5 MB của Discord). Hãy cắt ngắn video dưới ~20 giây hoặc dùng ảnh chụp màn hình.", name, formatBytes(data.length)]
            closeAfter:NO];
        return;
    }
    unsigned long long zipSz = _attachSwitch.isOn ? [_bundle[@"bytes"] unsignedLongLongValue] : 0;
    if ([self totalMediaBytes] + data.length + zipSz > kSDVBugReportMaxTotalUploadBytes) {
        [self showAlertTitle:@"Tổng dung lượng vượt 8.5 MB"
            msg:@"Tổng dung lượng ảnh/video + ErrorLogs.zip vượt giới hạn gửi của Discord. Hãy xóa bớt tệp hoặc chọn video ngắn hơn."
            closeAfter:NO];
        return;
    }
    [_mediaItems addObject:@{
        @"name": name ?: @"media.jpg",
        @"mime": mime ?: @"image/jpeg",
        @"data": data,
        @"thumb": thumb ?: NSNull.null,
        @"isVideo": @(isVideo)
    }];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    [self rebuildMediaListUI];
}

-(void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!results.count) return;
        for (PHPickerResult *res in results) {
            NSItemProvider *prov = res.itemProvider;
            if (!prov) continue;
            if ([prov hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
                [self beginMediaLoad];
                [prov loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url, NSError *err) {
                    if (!url || err) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self endMediaLoad];
                            [self showAlertTitle:@"Không đọc được video" msg:err.localizedDescription ?: @"Không thể đọc tệp video đã chọn." closeAfter:NO];
                        });
                        return;
                    }
                    // Copy synchronously before PHPicker deletes the temporary URL on handler return!
                    NSString *ext = url.pathExtension.length ? url.pathExtension.lowercaseString : @"mov";
                    NSString *tmpPath = join(NSTemporaryDirectory(), [NSString stringWithFormat:@"sdv_pick_vid_%@.%@", NSUUID.UUID.UUIDString, ext]);
                    [fm() removeItemAtPath:tmpPath error:nil];
                    NSError *cpErr = nil;
                    BOOL copied = [fm() copyItemAtPath:url.path toPath:tmpPath error:&cpErr];
                    if (!copied) {
                        unsigned long long fbSz = [[fm() attributesOfItemAtPath:url.path error:nil][NSFileSize] unsignedLongLongValue];
                        if (fbSz > 0 && fbSz <= 32ULL * 1024ULL * 1024ULL) {
                            NSData *fallback = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
                            copied = fallback.length && [fallback writeToFile:tmpPath atomically:YES];
                        }
                    }
                    if (!copied) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self endMediaLoad];
                            [self showAlertTitle:@"Không đọc được video" msg:cpErr.localizedDescription ?: @"Không thể sao chép tệp video tạm." closeAfter:NO];
                        });
                        return;
                    }
                    NSURL *localUrl = [NSURL fileURLWithPath:tmpPath];
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        [self processPickedVideoAtTempUrl:localUrl suggestedExt:ext cleanupTemp:YES];
                    });
                }];
            } else if ([prov hasItemConformingToTypeIdentifier:UTTypeImage.identifier]) {
                [self beginMediaLoad];
                [prov loadDataRepresentationForTypeIdentifier:UTTypeImage.identifier completionHandler:^(NSData *rawData, NSError *err) {
                    if (!rawData.length || err) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self endMediaLoad];
                            [self showAlertTitle:@"Không đọc được ảnh" msg:err.localizedDescription ?: @"Không thể đọc ảnh đã chọn." closeAfter:NO];
                        });
                        return;
                    }
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        UIImage *img = [UIImage imageWithData:rawData];
                        UIImage *scaled = img ? sdvResizeImageMaxSide(img, 1600.0) : nil;
                        NSData *jd = scaled ? UIImageJPEGRepresentation(scaled, 0.82) : nil;
                        UIImage *th = scaled ? sdvResizeImageMaxSide(scaled, 120.0) : nil;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self->_mediaSeq++;
                            NSString *fn = [NSString stringWithFormat:@"screenshot_%lu.jpg", (unsigned long)self->_mediaSeq];
                            [self endMediaLoad];
                            [self appendPreparedMediaData:jd name:fn mime:@"image/jpeg" thumb:th isVideo:NO];
                        });
                    });
                }];
            }
        }
    }];
}

-(void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *u = urls.firstObject;
    if (!u) return;
    [self beginMediaLoad];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *ext = u.pathExtension.lowercaseString;
        BOOL isVid = [@[@"mp4", @"mov", @"m4v"] containsObject:ext];
        BOOL shouldClean = ([u.path containsString:@"/tmp/"] || [u.path containsString:@"/Inbox/"]);
        if (isVid) {
            [self processPickedVideoAtTempUrl:u suggestedExt:ext cleanupTemp:shouldClean];
            return;
        }
        NSData *raw = [NSData dataWithContentsOfURL:u];
        UIImage *img = raw.length ? [UIImage imageWithData:raw] : nil;
        NSData *outData = nil;
        UIImage *thumb = nil;
        NSString *origStem = (u.lastPathComponent.length ? [u.lastPathComponent stringByDeletingPathExtension] : @"image");
        if (img) {
            UIImage *scaled = sdvResizeImageMaxSide(img, 1600.0);
            outData = UIImageJPEGRepresentation(scaled, 0.82);
            thumb = sdvResizeImageMaxSide(scaled, 120.0);
        }
        if (shouldClean) {
            [fm() removeItemAtURL:u error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_mediaSeq++;
            NSString *fn = sdvSafeAsciiMultipartFilename([origStem stringByAppendingString:@".jpg"],
                [NSString stringWithFormat:@"image_%lu.jpg", (unsigned long)self->_mediaSeq]);
            [self endMediaLoad];
            [self appendPreparedMediaData:outData name:fn mime:@"image/jpeg" thumb:thumb isVideo:NO];
        });
    });
}

-(void)textViewDidChange:(UITextView *)tv {
    NSString *txt = tv.text ?: @"";
    if (txt.length > 2000) {
        tv.text = sdvSafeTruncateUtf16(txt, 2000);
        txt = tv.text;
    }
    _descPlaceholder.hidden = (txt.length > 0);
    _charCountLbl.text = [NSString stringWithFormat:@"%lu / 2000", (unsigned long)txt.length];
}

-(BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

-(void)showAlertTitle:(NSString *)title msg:(NSString *)msg closeAfter:(BOOL)closeAfter {
    if (self.presentedViewController) return;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        if (closeAfter) [self dismissSelf];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

-(void)shareZipTapped:(UIButton *)sender {
    [self endEditingNow];
    if (!_bundle) _bundle = sdvBuildBugReportBundle(self.docsPath ?: @"");
    id urlObj = _bundle[@"url"];
    if (![urlObj isKindOfClass:NSURL.class]) {
        [self showAlertTitle:@"Chưa có ErrorLogs.zip" msg:@"Không tạo được tệp nén nhật ký lỗi." closeAfter:NO];
        return;
    }
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[urlObj] applicationActivities:nil];
    if (av.popoverPresentationController) {
        av.popoverPresentationController.sourceView = sender ?: self.view;
        av.popoverPresentationController.sourceRect = sender ? sender.bounds : CGRectMake(self.view.bounds.size.width * 0.5, self.view.bounds.size.height * 0.5, 1, 1);
    }
    [self presentViewController:av animated:YES completion:nil];
}

-(void)sendReportTapped {
    if (_sending) return;
    [self endEditingNow];

    NSString *desc = [(_descView.text ?: @"") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (desc.length < 8) {
        [self showAlertTitle:@"Thiếu mô tả lỗi" msg:@"Vui lòng ghi rõ vấn đề bạn gặp (ít nhất 8 ký tự) để admin kiểm tra chính xác." closeAfter:NO];
        return;
    }

    if (!kSDVBugReportEndpoint.length) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Chưa gắn máy chủ Báo lỗi"
            message:@"Bản test này chưa cấu hình đường link Cloudflare Worker nhận báo lỗi. Bạn có thể bấm Xuất ErrorLogs.zip để chia sẻ thủ công ngay bây giờ."
            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Xuất ErrorLogs.zip" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;
            [self shareZipTapped:self->_shareBtn];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Để sau" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    if (_pendingMediaLoads > 0) {
        [self showAlertTitle:@"Đang xử lý ảnh/video" msg:@"Vui lòng đợi vài giây để nén xong ảnh/video đính kèm rồi bấm Gửi lại." closeAfter:NO];
        return;
    }

    if (_attachSwitch.isOn && !_bundle) {
        _bundle = sdvBuildBugReportBundle(self.docsPath ?: @"");
    }
    unsigned long long preZipSz = _attachSwitch.isOn ? [_bundle[@"bytes"] unsignedLongLongValue] : 0;
    if (_attachSwitch.isOn && preZipSz > kSDVBugReportMaxZipBytes) {
        [self showAlertTitle:@"Tệp ErrorLogs.zip vượt giới hạn"
            msg:@"Tệp nhật ký ErrorLogs.zip quá lớn so với giới hạn máy chủ nhận lỗi. Bạn có thể bấm Xuất ErrorLogs.zip để chia sẻ trực tiếp hoặc tắt công tắc đính kèm tệp log."
            closeAfter:NO];
        return;
    }
    if ([self totalMediaBytes] + preZipSz > kSDVBugReportMaxTotalUploadBytes) {
        [self showAlertTitle:@"Tổng dung lượng vượt 8.5 MB"
            msg:@"Tổng dung lượng ảnh/video + ErrorLogs.zip vượt giới hạn gửi của Discord. Hãy xóa bớt tệp đính kèm hoặc tắt đính kèm tệp log."
            closeAfter:NO];
        return;
    }

    double now = NSDate.date.timeIntervalSince1970;
    double last = [NSUserDefaults.standardUserDefaults doubleForKey:kSDVBugReportLastSentKey];
    if (last > 0 && (now - last) < kSDVBugReportCooldownSec) {
        NSInteger wait = (NSInteger)ceil(kSDVBugReportCooldownSec - (now - last));
        [self showAlertTitle:@"Vui lòng đợi một chút" msg:[NSString stringWithFormat:@"Bạn vừa gửi báo lỗi. Vui lòng đợi %ld giây nữa trước khi gửi tiếp.", (long)wait] closeAfter:NO];
        return;
    }

    _sending = YES;
    _sendBtn.enabled = NO;
    _sendBtn.alpha = 0.65;
    _addMediaBtn.enabled = NO;
    [_spinner startAnimating];

    NSString *cat = _categories[MAX(0, MIN((NSInteger)_categories.count - 1, _selectedCat))];
    NSString *contact = [(_contactField.text ?: @"") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL attachZip = _attachSwitch.isOn;
    NSArray<NSDictionary *> *mediaCopy = [_mediaItems copy];
    NSString *docs = self.docsPath ?: @"";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *b = self->_bundle ?: sdvBuildBugReportBundle(docs);
        NSData *zipData = nil;
        if (attachZip && [b[@"url"] isKindOfClass:NSURL.class]) {
            zipData = [NSData dataWithContentsOfURL:b[@"url"]];
            if (zipData.length > kSDVBugReportMaxZipBytes) zipData = nil;
        }
        NSDictionary<NSString *, NSString *> *fields = @{
            @"category":     cat,
            @"description":  desc,
            @"contact":      contact,
            @"appVersion":   b[@"appVersion"] ?: sdvEffectiveAppVersion(),
            @"iosVersion":   b[@"iosVersion"] ?: @"?",
            @"device":       b[@"device"] ?: @"iPhone",
            @"ramInfo":      b[@"ramInfo"] ?: @"?",
            @"controlMode":  b[@"controlMode"] ?: @"?",
            @"modCount":     b[@"modCount"] ?: @"0",
            @"modsSummary":  b[@"modsSummary"] ?: @"",
            @"issueSummary": b[@"issueSummary"] ?: @"",
            @"deviceHash":   b[@"deviceHash"] ?: @"anon"
        };

        NSString *boundary = [NSString stringWithFormat:@"----GardenReport%@", NSUUID.UUID.UUIDString];
        NSData *body = sdvBuildMultipartBody(fields, zipData, @"ErrorLogs.zip", mediaCopy, boundary);

        NSURL *epUrl = [NSURL URLWithString:kSDVBugReportEndpoint];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:epUrl cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:45.0];
        req.HTTPMethod = @"POST";
        [req setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
        [req setValue:@"GardenLauncher-iOS" forHTTPHeaderField:@"X-Garden-App"];
        [req setValue:kSDVBugReportClientKey forHTTPHeaderField:@"X-Garden-Key"];
        [req setValue:[NSString stringWithFormat:@"GardenLauncher-iOS/%@", sdvEffectiveAppVersion()] forHTTPHeaderField:@"User-Agent"];
        req.HTTPBody = body;

        NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
            NSDictionary *j = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_sending = NO;
                self->_sendBtn.enabled = YES;
                self->_sendBtn.alpha = 1.0;
                self->_addMediaBtn.enabled = (self->_mediaItems.count < kSDVBugReportMaxMediaCount);
                [self->_spinner stopAnimating];

                if (!err && code >= 200 && code < 300 && [j isKindOfClass:NSDictionary.class] && [j[@"ok"] boolValue]) {
                    [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970 forKey:kSDVBugReportLastSentKey];
                    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
                    NSString *rid = [j[@"reportId"] isKindOfClass:NSString.class] ? j[@"reportId"] : @"OK";
                    [self showAlertTitle:@"Đã gửi báo lỗi thành công!"
                                     msg:[NSString stringWithFormat:@"Mã báo lỗi: #%@\n\nCảm ơn bạn đã gửi phản hồi kèm nhật ký lỗi & ảnh/video cho Admin!", rid]
                              closeAfter:YES];
                } else {
                    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeError];
                    NSString *reason = ([j isKindOfClass:NSDictionary.class] && [j[@"error"] isKindOfClass:NSString.class])
                        ? j[@"error"]
                        : (err.localizedDescription ?: [NSString stringWithFormat:@"Máy chủ trả về mã lỗi HTTP %ld.", (long)code]);
                    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Gửi báo lỗi chưa thành công"
                        message:[NSString stringWithFormat:@"%@\n\nBạn có thể thử lại hoặc bấm Xuất ErrorLogs.zip để gửi thủ công.", reason]
                        preferredStyle:UIAlertControllerStyleAlert];
                    [ac addAction:[UIAlertAction actionWithTitle:@"Xuất ErrorLogs.zip" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                        (void)a;
                        [self shareZipTapped:self->_shareBtn];
                    }]];
                    [ac addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
                    [self presentViewController:ac animated:YES completion:nil];
                }
            });
        }];
        [task resume];
    });
}
@end
