#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <ctype.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <sys/stat.h>
#import <unistd.h>
#import <wchar.h>
#import "vendor/miniz.h"

static NSFileManager *fm(void) { return NSFileManager.defaultManager; }
static void fail(NSString *s) { @throw [NSException exceptionWithName:@"GardenError" reason:s userInfo:nil]; }
static void check(BOOL ok, NSError *error) { if (!ok) fail(error.localizedDescription ?: @"Không thể đọc hoặc ghi tệp."); }
static NSString *join(NSString *a, NSString *b) { return [a stringByAppendingPathComponent:b]; }
static BOOL dir(NSString *p) { BOOL d=NO; return [fm() fileExistsAtPath:p isDirectory:&d] && d; }
static void sdvUnlockPermissionsRecursive(NSString *p) {
    if (!p.length) return;
    const char *cp = p.fileSystemRepresentation;
    if (!cp) return;
    struct stat st;
    if (lstat(cp, &st) != 0) return;
    if (S_ISLNK(st.st_mode)) return;
    if (S_ISDIR(st.st_mode)) {
        chmod(cp, 0755);
        NSArray<NSString *> *subs = [fm() contentsOfDirectoryAtPath:p error:nil];
        for (NSString *sub in subs) {
            sdvUnlockPermissionsRecursive([p stringByAppendingPathComponent:sub]);
        }
    } else if (S_ISREG(st.st_mode)) {
        chmod(cp, 0644);
    }
}

static BOOL sdvRemoveItemQuiet(NSString *p) {
    if (!p.length) return YES;
    const char *cp = p.fileSystemRepresentation;
    struct stat st;
    if (!cp || lstat(cp, &st) != 0) return YES;
    sdvUnlockPermissionsRecursive(p);
    return [fm() removeItemAtPath:p error:nil];
}

static void sdvPrepareWritableFileTarget(NSString *p) {
    if (!p.length) return;
    const char *cp = p.fileSystemRepresentation;
    struct stat st;
    if (!cp || lstat(cp, &st) != 0) return;
    if (S_ISDIR(st.st_mode)) {
        sdvRemoveItemQuiet(p);
    } else if (S_ISREG(st.st_mode)) {
        chmod(cp, 0644);
    }
}

static void mkdirs(NSString *p) {
    if (!p.length) return;
    const char *cp = p.fileSystemRepresentation;
    struct stat st;
    if (cp && lstat(cp, &st) == 0 && S_ISDIR(st.st_mode)) {
        if ((st.st_mode & 0700) != 0700) chmod(cp, 0755);
        return;
    }
    NSError *e = nil;
    BOOL ok = [fm() createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:&e];
    check(ok, e);
}

static void removeItem(NSString *p) {
    if (!p.length) return;
    const char *cp = p.fileSystemRepresentation;
    struct stat st;
    if (!cp || lstat(cp, &st) != 0) return;
    sdvUnlockPermissionsRecursive(p);
    NSError *e = nil;
    BOOL ok = [fm() removeItemAtPath:p error:&e];
    check(ok, e);
}

static NSString *hashData(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    NSMutableString *s=[NSMutableString string]; for (int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [s appendFormat:@"%02x",bytes[i]]; return s;
}
static NSData *readFile(NSString *p) { NSError *e=nil; NSData *d=[NSData dataWithContentsOfFile:p options:NSDataReadingMappedIfSafe error:&e]; check(d!=nil,e); return d; }
static void writeFile(NSData *d, NSString *p) {
    mkdirs(p.stringByDeletingLastPathComponent);
    sdvPrepareWritableFileTarget(p);
    NSError *e = nil;
    BOOL ok = [d writeToFile:p options:NSDataWritingAtomic error:&e];
    check(ok, e);
}

// Safely decodes a byte-sliced UTF-8 buffer without failing on mid-character multi-byte Vietnamese / Emoji boundaries!
static NSString *sdvDecodeUtf8Slice(NSData *raw, BOOL trimLeadingCont, BOOL trimTrailingIncomplete) {
    if (!raw.length) return @"";
    const uint8_t *b = (const uint8_t *)raw.bytes;
    NSUInteger start = 0;
    NSUInteger end = raw.length;
    if (!trimLeadingCont) {
        while (start + 3 <= end && b[start] == 0xEF && b[start + 1] == 0xBB && b[start + 2] == 0xBF) {
            start += 3;
        }
    } else {
        NSUInteger skipped = 0;
        while (start < end && skipped < 4 && (b[start] & 0xC0) == 0x80) {
            start++;
            skipped++;
        }
    }
    if (trimTrailingIncomplete && end > start) {
        NSUInteger scanBack = MIN((NSUInteger)4, end - start);
        for (NSUInteger k = 1; k <= scanBack; k++) {
            uint8_t c = b[end - k];
            if ((c & 0x80) == 0) break; // Valid 1-byte ASCII terminator
            if ((c & 0xC0) == 0xC0) {
                NSUInteger need = ((c & 0xE0) == 0xC0) ? 2 : (((c & 0xF0) == 0xE0) ? 3 : 4);
                if (k < need) end -= k;
                break;
            }
        }
    }
    if (end <= start) return @"";
    NSData *sub = (start == 0 && end == raw.length) ? raw : [raw subdataWithRange:NSMakeRange(start, end - start)];
    return [[NSString alloc] initWithData:sub encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:sub encoding:NSISOLatin1StringEncoding]
        ?: @"";
}

// Truncates an NSString cleanly on composed grapheme/surrogate-pair boundaries so Emoji/UTF-16 never splits!
static NSString *sdvSafeTruncateUtf16(NSString *s, NSUInteger maxLen) {
    if (!s || s.length <= maxLen) return s ?: @"";
    if (maxLen == 0) return @"";
    NSRange r = [s rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, maxLen)];
    while (r.length > maxLen && maxLen > 0) {
        maxLen--;
        r = [s rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, maxLen)];
    }
    return (r.length <= s.length) ? [s substringWithRange:r] : @"";
}

static NSData *stripJson5ForIOS14(NSData *raw) {
    if (!raw.length) return raw;
    const unsigned char *b = (const unsigned char *)raw.bytes;
    NSUInteger len = raw.length, start = 0;
    if (len >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) start = 3;
    NSMutableData *out = [NSMutableData dataWithCapacity:len];
    BOOL inStr = NO, esc = NO;
    for (NSUInteger i = start; i < len; ) {
        unsigned char c = b[i];
        if (inStr) {
            [out appendBytes:&c length:1];
            if (esc) esc = NO;
            else if (c == '\\') esc = YES;
            else if (c == '"') inStr = NO;
            i++;
            continue;
        }
        if (c == '"') { inStr = YES; [out appendBytes:&c length:1]; i++; continue; }
        if (c == '/' && i + 1 < len && b[i+1] == '/') {
            i += 2;
            while (i < len && b[i] != '\n' && b[i] != '\r') i++;
            continue;
        }
        if (c == '/' && i + 1 < len && b[i+1] == '*') {
            i += 2;
            while (i + 1 < len && !(b[i] == '*' && b[i+1] == '/')) i++;
            i = (i + 1 < len) ? i + 2 : len;
            continue;
        }
        if (c == ',') {
            NSUInteger j = i + 1;
            while (j < len) {
                unsigned char n = b[j];
                if (n == ' ' || n == '\t' || n == '\r' || n == '\n') { j++; continue; }
                if (n == '/' && j + 1 < len && b[j+1] == '/') { j += 2; while (j < len && b[j] != '\n') j++; continue; }
                if (n == '/' && j + 1 < len && b[j+1] == '*') { j += 2; while (j + 1 < len && !(b[j] == '*' && b[j+1] == '/')) j++; j = (j + 1 < len) ? j + 2 : len; continue; }
                break;
            }
            if (j < len && (b[j] == '}' || b[j] == ']')) { i++; continue; }
        }
        [out appendBytes:&c length:1];
        i++;
    }
    return out;
}

static id jsonAt(NSString *p) {
    NSData *raw = readFile(p);
    if (!raw.length) fail([NSString stringWithFormat:@"%@ — tệp trống.", p.lastPathComponent]);
    // Handle UTF-16LE / UTF-16BE BOM transparently (common in Windows-edited Vietnamese mods!)
    const unsigned char *b = (const unsigned char *)raw.bytes;
    if (raw.length >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) {
        NSStringEncoding enc = (b[0] == 0xFF) ? NSUTF16LittleEndianStringEncoding : NSUTF16BigEndianStringEncoding;
        NSString *s = [[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(2, raw.length - 2)] encoding:enc];
        if (s) raw = [s dataUsingEncoding:NSUTF8StringEncoding];
    }
    // Always strip UTF-8 BOM + JSON5 comments/trailing commas for maximum compatibility across iOS 14-27+
    NSData *sanitized = stripJson5ForIOS14(raw);
    NSError *e = nil;
    id j = nil;
    if (@available(iOS 15.0, *)) {
        j = [NSJSONSerialization JSONObjectWithData:sanitized options:NSJSONReadingJSON5Allowed | NSJSONReadingAllowFragments error:&e];
        if (!j) j = [NSJSONSerialization JSONObjectWithData:raw options:NSJSONReadingJSON5Allowed error:&e];
    } else {
        j = [NSJSONSerialization JSONObjectWithData:sanitized options:NSJSONReadingAllowFragments error:&e];
    }
    if (!j) fail([NSString stringWithFormat:@"%@ — %@", p.lastPathComponent, e.localizedDescription]);
    return j;
}

// Visible game directory Documents/StardewValley/ so users can freely access & edit Content/*.xnb in Apple's Files (Tệp) app!
static NSString *sdvHiddenGameDir(NSString *docsPath) {
    if (!docsPath.length) return @"";
    NSString *d = join(docsPath, @"StardewValley");
    [fm() createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static NSString *sdvHiddenGardenDir(NSString *docsPath) {
    if (!docsPath.length) return @"";
    NSString *d = join(docsPath, @".garden");
    [fm() createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static BOOL sdvIsUnusedGameRootJunk(NSString *fileLow, NSString *extLow) {
    if (!fileLow.length) return YES;
    if ([extLow isEqualToString:@"xml"] || [extLow isEqualToString:@"pdb"] ||
        [extLow isEqualToString:@"exe"] || [extLow isEqualToString:@"so"] ||
        [extLow isEqualToString:@"dylib"] || [extLow isEqualToString:@"bat"] ||
        [extLow isEqualToString:@"sh"] || [extLow isEqualToString:@"cmd"] ||
        [extLow isEqualToString:@"ini"] || [extLow isEqualToString:@"cdx"] ||
        [extLow isEqualToString:@"md"] || [fileLow containsString:@".so."]) {
        return YES;
    }
    if ([fileLow hasSuffix:@"_license.txt"] || [fileLow hasPrefix:@"license"] ||
        [fileLow hasPrefix:@"readme"] || [fileLow hasPrefix:@"notice"] ||
        [fileLow hasPrefix:@"api-ms-win-"] || [fileLow hasPrefix:@"mscordaccore_"] ||
        [fileLow hasPrefix:@"microsoft.diasymreader"]) {
        return YES;
    }
    static NSSet<NSString *> *desktopJunk = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        desktopJunk = [NSSet setWithArray:@[
            @"coreclr.dll", @"clrjit.dll", @"clrgc.dll", @"clretwrc.dll",
            @"hostfxr.dll", @"hostpolicy.dll", @"ucrtbase.dll", @"msquic.dll",
            @"mscordaccore.dll", @"mscordbi.dll", @"mscorrc.dll", @"dbgshim.dll",
            @"steamworks.net.dll", @"galaxycsharp.dll", @"galaxy64.dll", @"galaxycsharpglue.dll",
            @"steam_api64.dll", @"steam_api64.cdx", @"steam_emu.ini",
            @"sdl2.dll", @"faudio.dll", @"soft_oal.dll", @"libskiasharp.dll",
            @"liblwjgl_lz4.dll", @"stb_png_writer.dll", @"system.io.compression.native.dll",
            @"system.private.corelib.dll"
        ]];
    });
    return [desktopJunk containsObject:fileLow];
}

static void sdvRepairDirModesRecursive(NSString *dirPath, int maxDepth) {
    if (!dirPath.length || maxDepth < 0) return;
    const char *cp = dirPath.fileSystemRepresentation;
    if (!cp) return;
    struct stat st;
    if (lstat(cp, &st) != 0 || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) return;
    if ((st.st_mode & 0700) != 0700) {
        chmod(cp, 0755);
    }
    if (maxDepth == 0) return;
    NSArray<NSString *> *subs = [fm() contentsOfDirectoryAtPath:dirPath error:nil];
    for (NSString *sub in subs) {
        sdvRepairDirModesRecursive([dirPath stringByAppendingPathComponent:sub], maxDepth - 1);
    }
}

static void sdvRepairSandboxPermissions(NSString *docsPath) {
    @try {
        NSString *tmpDir = NSTemporaryDirectory();
        if (tmpDir.length) {
            sdvRepairDirModesRecursive(tmpDir, 4);
        }
        if (docsPath.length) {
            for (NSString *sub in @[@"Mods", @"Saves", @".config/StardewValley/Saves", @"StardewValley", @".garden", @"ErrorLogs"]) {
                sdvRepairDirModesRecursive(join(docsPath, sub), 4);
            }
        }
    } @catch (NSException *ex) { }
}

static void sdvMoveMergeDir(NSString *srcDir, NSString *dstDir) {
    if (!dir(srcDir)) return;
    if (![fm() fileExistsAtPath:dstDir]) {
        [fm() createDirectoryAtPath:dstDir.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if ([fm() moveItemAtPath:srcDir toPath:dstDir error:nil]) return;
    }
    [fm() createDirectoryAtPath:dstDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *sub in ([fm() contentsOfDirectoryAtPath:srcDir error:nil] ?: @[])) {
        NSString *sp = join(srcDir, sub);
        NSString *dp = join(dstDir, sub);
        if (dir(sp)) {
            sdvMoveMergeDir(sp, dp);
        } else {
            if ([fm() fileExistsAtPath:dp]) {
                sdvRemoveItemQuiet(dp);
            }
            [fm() moveItemAtPath:sp toPath:dp error:nil];
        }
    }
    sdvRemoveItemQuiet(srcDir);
}

// Organizes Documents/ cleanly for Apple's Files (Tệp) app:
// - Restores visible Documents/StardewValley/ (auto-migrating v1.0.1/v1.0.2 hidden .game/ -> StardewValley/) so users can view/edit Content/*.xnb!
// - Keeps internal launcher/controller config & IPC flag files tucked inside hidden Documents/.garden/.
static void sdvMigrateDocumentsToHiddenLayout(NSString *docsPath) {
    if (!docsPath.length) return;
    @try {
        // Heal any directories previously locked with 0644 (#GL-WY7FCB) before touching tmp/ or Documents/!
        sdvRepairSandboxPermissions(docsPath);

        // Fast O(1) rename if migrating from v1.0.1/v1.0.2 hidden Documents/.game/ -> Documents/StardewValley/
        NSString *legacyHidden = join(docsPath, @".game");
        NSString *visibleGame = join(docsPath, @"StardewValley");
        if (dir(legacyHidden) && ![fm() fileExistsAtPath:visibleGame]) {
            [fm() moveItemAtPath:legacyHidden toPath:visibleGame error:nil];
        }

        NSString *gameDir = sdvHiddenGameDir(docsPath);
        NSString *gardenDir = sdvHiddenGardenDir(docsPath);
        if (dir(legacyHidden)) {
            sdvMoveMergeDir(legacyHidden, gameDir);
        }
        NSURL *gu = [NSURL fileURLWithPath:gameDir isDirectory:YES];
        [gu setResourceValue:@NO forKey:NSURLIsExcludedFromBackupKey error:nil];

        // 1. Move internal launcher/controller config & IPC flag files -> Documents/.garden/
        NSArray<NSString *> *gardenFiles = @[
            @"sdv_perf.cfg", @"sdv_menubar.cfg", @"sdv_mobile_ctrl.cfg",
            @"sdv_mobile_edit.flag", @"sdv_ram_alert.txt", @"sdv_pause_now.flag",
            @"sdv_haptic_bite.flag", @"sdv_safe_area.cfg", @"sdv_boot_stage.txt",
            @"sdv_boot_ready.flag", @"sdv_gc_now.flag", @"sdv_prune_now.flag",
            @"sdv_gamepad_only.flag", @"touch_overlay_config.json"
        ];
        for (NSString *gf in gardenFiles) {
            NSString *src = join(docsPath, gf);
            NSString *dst = join(gardenDir, gf);
            if ([fm() fileExistsAtPath:src]) {
                if (![fm() fileExistsAtPath:dst]) {
                    [fm() moveItemAtPath:src toPath:dst error:nil];
                } else {
                    sdvRemoveItemQuiet(src);
                }
            }
        }
        NSString *oldDisabled = join(docsPath, @"DisabledMods");
        if (dir(oldDisabled)) {
            sdvMoveMergeDir(oldDisabled, join(gardenDir, @"DisabledMods"));
        }

        // 2. Move loose PC game files & folders from Documents/ -> Documents/StardewValley/, and delete unused PC doc/license junk
        NSArray<NSString *> *rootItems = [fm() contentsOfDirectoryAtPath:docsPath error:nil] ?: @[];
        for (NSString *item in rootItems) {
            if ([item hasPrefix:@"."]) continue;
            NSString *low = item.lowercaseString;
            if ([low isEqualToString:@"stardewvalley"] || [low isEqualToString:@"mods"] || [low isEqualToString:@"saves"] || [low isEqualToString:@"errorlogs"]) continue;
            NSString *src = join(docsPath, item);
            if (dir(src)) {
                if ([low isEqualToString:@"content"]) {
                    sdvMoveMergeDir(src, join(gameDir, @"Content"));
                } else if ([low isEqualToString:@"smapi-internal"]) {
                    NSString *dstSi = join(gameDir, @"smapi-internal");
                    if (!dir(dstSi)) {
                        [fm() moveItemAtPath:src toPath:dstSi error:nil];
                    } else {
                        NSString *srcCfg = join(src, @"config.user.json");
                        NSString *dstCfg = join(dstSi, @"config.user.json");
                        if ([fm() fileExistsAtPath:srcCfg] && ![fm() fileExistsAtPath:dstCfg]) {
                            [fm() moveItemAtPath:srcCfg toPath:dstCfg error:nil];
                        }
                        sdvRemoveItemQuiet(src);
                    }
                }
                continue;
            }
            NSString *ext = item.pathExtension.lowercaseString;
            if (sdvIsUnusedGameRootJunk(low, ext)) {
                sdvRemoveItemQuiet(src);
                continue;
            }
            BOOL isGameRuntimeFile =
                [ext isEqualToString:@"dll"] ||
                [low hasPrefix:@"stardew valley."] ||
                [low hasPrefix:@"stardewmoddingapi."] ||
                [low isEqualToString:@"force_vanilla.txt"];
            if (isGameRuntimeFile) {
                NSString *dst = join(gameDir, item);
                if (![fm() fileExistsAtPath:dst]) {
                    [fm() moveItemAtPath:src toPath:dst error:nil];
                } else {
                    sdvRemoveItemQuiet(src);
                }
            }
        }

        // 3. Also prune unused desktop doc/license junk inside StardewValley/ root
        for (NSString *gitem in ([fm() contentsOfDirectoryAtPath:gameDir error:nil] ?: @[])) {
            NSString *gp = join(gameDir, gitem);
            if (dir(gp)) continue;
            if (sdvIsUnusedGameRootJunk(gitem.lowercaseString, gitem.pathExtension.lowercaseString)) {
                sdvRemoveItemQuiet(gp);
            }
        }
    } @catch (NSException *ex) { }
}

static NSDictionary *sdvActiveHotPatchInfo(void);
static BOOL sdvHotPatchOverridesRelPath(NSString *docsPath, NSString *relPath);
static NSUInteger sdvDeployActiveHotPatchFiles(NSString *docsPath);

static void syncBundledLidgren(NSString *docsPath) {
    if (!docsPath.length) return;
    @try {
        if (sdvHotPatchOverridesRelPath(docsPath, @"StardewValley/Lidgren.Network.dll")) {
            sdvDeployActiveHotPatchFiles(docsPath);
            return;
        }
        NSArray<NSString *> *cands = @[
            join(join(join(NSBundle.mainBundle.bundlePath, @"Frameworks"), @"SDVModGarden.framework"), @"Lidgren.Network.dll"),
            join(NSBundle.mainBundle.bundlePath, @"Lidgren.Network.dll"),
            join(join(NSBundle.mainBundle.bundlePath, @"BundledGame"), @"Lidgren.Network.dll")
        ];
        NSString *src = nil;
        for (NSString *c in cands) {
            if ([fm() fileExistsAtPath:c]) { src = c; break; }
        }
        if (!src) return;
        NSData *srcData = [NSData dataWithContentsOfFile:src options:NSDataReadingMappedIfSafe error:nil];
        if (!srcData.length) return;
        NSString *srcHash = hashData(srcData);

        NSString *base = sdvHiddenGameDir(docsPath);
        NSString *dst = join(base, @"Lidgren.Network.dll");
        NSData *dstData = (!dir(dst) && [fm() fileExistsAtPath:dst]) ? [NSData dataWithContentsOfFile:dst options:NSDataReadingMappedIfSafe error:nil] : nil;
        if (!dstData || dstData.length != srcData.length || ![srcHash isEqualToString:hashData(dstData)]) {
            [fm() createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
            sdvPrepareWritableFileTarget(dst);
            [srcData writeToFile:dst options:NSDataWritingAtomic error:nil];
        }
    } @catch (NSException *ex) { }
}

static BOOL dataContainsAscii(NSData *data, const char *needle) {
    if (!data.length || !needle || !needle[0]) return NO;
    NSData *pat = [NSData dataWithBytesNoCopy:(void *)needle length:strlen(needle) freeWhenDone:NO];
    return [data rangeOfData:pat options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
}

static NSString *syncBundledSmapi(NSString *docsPath) {
    if (!docsPath.length) return @"no-docs";
    @try {
        if (sdvHotPatchOverridesRelPath(docsPath, @"StardewValley/StardewModdingAPI.dll") ||
            sdvHotPatchOverridesRelPath(docsPath, @"StardewValley/smapi-internal/SMAPI.Toolkit.dll")) {
            sdvDeployActiveHotPatchFiles(docsPath);
            return @"hotpatched";
        }
        NSString *smapiRoot = join(join(join(NSBundle.mainBundle.bundlePath, @"Frameworks"), @"SDVModGarden.framework"), @"BundledSMAPI");
        if (!dir(smapiRoot)) return @"no-bundle";
        [fm() createDirectoryAtPath:docsPath withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *srcDll = join(smapiRoot, @"StardewModdingAPI.dll");
        NSString *srcInternal = join(smapiRoot, @"smapi-internal");
        if (![fm() fileExistsAtPath:srcDll]) return @"no-src-dll";
        NSData *srcDllData = [NSData dataWithContentsOfFile:srcDll options:NSDataReadingMappedIfSafe error:nil];
        if (!srcDllData.length) return @"empty-src-dll";
        NSString *srcHash = hashData(srcDllData);

        NSString *srcToolkit = join(srcInternal, @"SMAPI.Toolkit.dll");
        NSData *srcToolkitData = [fm() fileExistsAtPath:srcToolkit] ? [NSData dataWithContentsOfFile:srcToolkit options:NSDataReadingMappedIfSafe error:nil] : nil;
        NSString *srcToolkitHash = srcToolkitData.length ? hashData(srcToolkitData) : nil;

        NSArray<NSString *> *targets = @[sdvHiddenGameDir(docsPath)];

        NSMutableArray<NSString *> *notes = [NSMutableArray array];
        for (NSString *base in targets) {
            NSString *dstDll = join(base, @"StardewModdingAPI.dll");
            NSString *dstInternal = join(base, @"smapi-internal");
            NSString *stampPath = join(dstInternal, @".garden_smapi_v1");

            NSString *reason = nil;
            NSData *dstData = (!dir(dstDll) && [fm() fileExistsAtPath:dstDll]) ? [NSData dataWithContentsOfFile:dstDll options:NSDataReadingMappedIfSafe error:nil] : nil;
            if (!dstData || dstData.length < 100 * 1024) {
                reason = @"missing";
            } else if (dataContainsAscii(dstData, "set_InputEncoding") || dataContainsAscii(dstData, "set_OutputEncoding")) {
                // Windows-compiled SMAPI calls Console.set_InputEncoding/OutputEncoding -> PlatformNotSupportedException on iOS!
                reason = @"windows-smapi-detected";
            } else if (!dataContainsAscii(dstData, "ConsoleColorSchemes")) {
                // Older SMAPI (<=4.3) incompatible with bundled SMAPI 4.5.2 internals
                reason = @"legacy-smapi-detected";
            } else {
                NSString *stamp = [NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:nil];
                stamp = [stamp stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (![stamp isEqualToString:srcHash]) {
                    reason = @"stamp-mismatch";
                } else {
                    // RuntimeSmapiPatcher patches StardewModdingAPI.dll in-place on first boot, altering its SHA-256 & byte length slightly!
                    // Accept valid in-place patched iOS SMAPI when .garden_smapi_v1 matches the bundled IPA source hash so Cold-Boot Stamp Cache hits on boot #2+.
                    NSUInteger minValid = (srcDllData.length > 65536) ? (srcDllData.length - 65536) : 100 * 1024;
                    NSUInteger maxValid = srcDllData.length + 131072;
                    if (dstData.length < minValid || dstData.length > maxValid) {
                        reason = @"dll-size-corrupt";
                    }
                }
            }

            if (!reason && srcToolkitHash.length) {
                NSString *dstToolkit = join(dstInternal, @"SMAPI.Toolkit.dll");
                NSData *dstTk = (!dir(dstToolkit) && [fm() fileExistsAtPath:dstToolkit]) ? [NSData dataWithContentsOfFile:dstToolkit options:NSDataReadingMappedIfSafe error:nil] : nil;
                if (!dstTk || dstTk.length != srcToolkitData.length || ![hashData(dstTk) isEqualToString:srcToolkitHash]) {
                    reason = @"toolkit-mismatch";
                }
            }

            if (!reason && dir(srcInternal)) {
                NSDirectoryEnumerator *chkEn = [fm() enumeratorAtPath:srcInternal];
                for (NSString *rel in chkEn) {
                    if (![chkEn.fileAttributes.fileType isEqualToString:NSFileTypeRegular]) continue;
                    if (![fm() fileExistsAtPath:join(dstInternal, rel)]) {
                        reason = @"missing-internal";
                        break;
                    }
                }
            }

            // Also remove any stale cached StardewModdingAPI.dll inside smapi-internal/ if it is a Windows SMAPI or when re-syncing
            NSString *cachedSmapi = join(dstInternal, @"StardewModdingAPI.dll");
            if ([fm() fileExistsAtPath:cachedSmapi]) {
                NSData *cd = !dir(cachedSmapi) ? [NSData dataWithContentsOfFile:cachedSmapi options:NSDataReadingMappedIfSafe error:nil] : nil;
                if (reason || !cd.length || dataContainsAscii(cd, "set_InputEncoding") || dataContainsAscii(cd, "set_OutputEncoding")) {
                    sdvRemoveItemQuiet(cachedSmapi);
                }
            }

            if (reason) {
                [fm() createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
                sdvPrepareWritableFileTarget(dstDll);
                [srcDllData writeToFile:dstDll options:NSDataWritingAtomic error:nil];

                // Preserve user's config.user.json if present, then cleanly deploy iOS-verified smapi-internal/
                NSData *savedUserCfg = nil;
                NSString *userCfgPath = join(dstInternal, @"config.user.json");
                if (!dir(userCfgPath) && [fm() fileExistsAtPath:userCfgPath]) {
                    savedUserCfg = [NSData dataWithContentsOfFile:userCfgPath options:0 error:nil];
                }
                if (dir(srcInternal)) {
                    if ([fm() fileExistsAtPath:dstInternal]) {
                        sdvRemoveItemQuiet(dstInternal);
                    }
                    [fm() createDirectoryAtPath:dstInternal withIntermediateDirectories:YES attributes:nil error:nil];
                    NSDirectoryEnumerator *en = [fm() enumeratorAtPath:srcInternal];
                    for (NSString *rel in en) {
                        if (![en.fileAttributes.fileType isEqualToString:NSFileTypeRegular]) continue;
                        NSString *dst = join(dstInternal, rel);
                        [fm() createDirectoryAtPath:dst.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                        NSData *d = [NSData dataWithContentsOfFile:join(srcInternal, rel) options:NSDataReadingMappedIfSafe error:nil];
                        if (d) {
                            sdvPrepareWritableFileTarget(dst);
                            [d writeToFile:dst options:NSDataWritingAtomic error:nil];
                        }
                    }
                    if (savedUserCfg.length) {
                        sdvPrepareWritableFileTarget(userCfgPath);
                        [savedUserCfg writeToFile:userCfgPath options:NSDataWritingAtomic error:nil];
                    }
                }
                sdvPrepareWritableFileTarget(stampPath);
                [srcHash writeToFile:stampPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [notes addObject:[NSString stringWithFormat:@"synced:%@", reason]];
            } else {
                [notes addObject:@"ok"];
            }
        }
        if (sdvActiveHotPatchInfo() != nil) {
            sdvDeployActiveHotPatchFiles(docsPath);
        }
        return notes.count ? [notes componentsJoinedByString:@","] : @"ok";
    } @catch (NSException *ex) {
        return [NSString stringWithFormat:@"err:%@", ex.reason ?: @"?"];
    }
}
static void syncBundledMobileControls(NSString *docsPath) {
    if (!docsPath.length) return;
    @try {
        NSString *srcMod = join(join(join(join(NSBundle.mainBundle.bundlePath, @"Frameworks"), @"SDVModGarden.framework"), @"BundledMods"), @"SDVMobileControls");
        NSString *modsDir = join(docsPath, @"Mods");
        // Respect user explicitly disabling via .SDVMobileControls folder
        if (dir(srcMod) && !dir(join(modsDir, @".SDVMobileControls"))) {
            NSString *dstMod = join(modsDir, @"SDVMobileControls");
            [fm() createDirectoryAtPath:dstMod withIntermediateDirectories:YES attributes:nil error:nil];
            for (NSString *fn in @[@"manifest.json", @"SDVMobileControls.dll"]) {
                NSString *rel = [NSString stringWithFormat:@"Mods/SDVMobileControls/%@", fn];
                if (sdvHotPatchOverridesRelPath(docsPath, rel)) continue;
                NSString *sp = join(srcMod, fn);
                if (![fm() fileExistsAtPath:sp]) continue;
                NSData *sd = [NSData dataWithContentsOfFile:sp options:NSDataReadingMappedIfSafe error:nil];
                if (!sd.length) continue;
                NSString *dp = join(dstMod, fn);
                NSData *dd = (!dir(dp) && [fm() fileExistsAtPath:dp]) ? [NSData dataWithContentsOfFile:dp options:NSDataReadingMappedIfSafe error:nil] : nil;
                if (!dd || dd.length != sd.length || ![hashData(sd) isEqualToString:hashData(dd)]) {
                    sdvPrepareWritableFileTarget(dp);
                    [sd writeToFile:dp options:NSDataWritingAtomic error:nil];
                }
            }
        }
        // Also keep bundled SDViOSTouchControls DLLs in sync with the updated IPA bundle (unless overridden by an active Hot-Patch!)
        BOOL hpOverridesTouch = sdvHotPatchOverridesRelPath(docsPath, @"Mods/SDViOSTouchControls/SDViOSTouchControls.dll") ||
                                sdvHotPatchOverridesRelPath(docsPath, @"Mods/SDViOSTouchControls/SDViOSTouchControlsMod.dll");
        NSString *srcTouchMod = join(join(NSBundle.mainBundle.bundlePath, @"Mods"), @"SDViOSTouchControls");
        if (!hpOverridesTouch && dir(srcTouchMod) && !dir(join(modsDir, @".SDViOSTouchControls"))) {
            NSString *dstTouchMod = join(modsDir, @"SDViOSTouchControls");
            [fm() createDirectoryAtPath:dstTouchMod withIntermediateDirectories:YES attributes:nil error:nil];
            for (NSString *fn in @[@"SDViOSTouchControlsMod.dll", @"SDViOSTouchControls.dll", @"manifest.json"]) {
                NSString *sp = join(srcTouchMod, fn);
                if (![fm() fileExistsAtPath:sp]) continue;
                NSData *sd = [NSData dataWithContentsOfFile:sp options:NSDataReadingMappedIfSafe error:nil];
                if (!sd.length) continue;
                NSString *dp = join(dstTouchMod, fn);
                NSData *dd = (!dir(dp) && [fm() fileExistsAtPath:dp]) ? [NSData dataWithContentsOfFile:dp options:NSDataReadingMappedIfSafe error:nil] : nil;
                if (!dd || dd.length != sd.length || ![hashData(sd) isEqualToString:hashData(dd)]) {
                    sdvPrepareWritableFileTarget(dp);
                    [sd writeToFile:dp options:NSDataWritingAtomic error:nil];
                }
            }
        }
        if (sdvActiveHotPatchInfo() != nil) {
            sdvDeployActiveHotPatchFiles(docsPath);
        }
    } @catch (NSException *ex) { }
}

static NSUInteger syncContentPackLocaleFallbacks(NSString *docsPath) {
    if (!docsPath.length) return 0;
    NSUInteger created = 0;
    @try {
        NSMutableArray<NSString *> *modRoots = [NSMutableArray array];
        NSString *m1 = join(docsPath, @"Mods");
        NSString *m2 = join(join(docsPath, @"StardewValley"), @"Mods");
        if (dir(m1)) [modRoots addObject:m1];
        if (dir(m2) && ![m2 isEqualToString:m1]) [modRoots addObject:m2];

        NSSet<NSString *> *assetExts = [NSSet setWithArray:@[@"png", @"xnb", @"json", @"tmx", @"tbin", @"yaml"]];
        NSSet<NSString *> *skipTop = [NSSet setWithArray:@[
            @"sdviostouchcontrols", @"sdvmobilecontrols", @"contentpatcher",
            @"savebackup", @"genericmodconfigmenu", @"consolecommands", @"errorhandler"
        ]];

        for (NSString *modsDir in modRoots) {
            NSDirectoryEnumerator *packEnum = [fm() enumeratorAtPath:modsDir];
            NSString *rel = nil;
            NSMutableArray<NSString *> *cpPackDirs = [NSMutableArray array];
            while ((rel = [packEnum nextObject])) {
                NSArray<NSString *> *parts = rel.pathComponents;
                if (!parts.count) continue;
                NSString *top = parts.firstObject;
                if ([top hasPrefix:@"."] || [skipTop containsObject:top.lowercaseString]) {
                    if (parts.count == 1) [packEnum skipDescendants];
                    continue;
                }
                if (parts.count > 4) continue;
                if (![rel.lastPathComponent.lowercaseString isEqualToString:@"manifest.json"]) continue;
                NSString *packDir = join(modsDir, rel).stringByDeletingLastPathComponent;
                if (![fm() fileExistsAtPath:join(packDir, @"content.json")]) continue;
                [cpPackDirs addObject:packDir];
            }

            for (NSString *packDir in cpPackDirs) { @autoreleasepool {
                NSDictionary *mf = nil;
                @try {
                    id parsed = jsonAt(join(packDir, @"manifest.json"));
                    if ([parsed isKindOfClass:NSDictionary.class]) mf = parsed;
                } @catch (NSException *ex) { continue; }
                if (!mf) continue;

                // Must be a Content Patcher pack
                NSDictionary *cpf = [mf[@"ContentPackFor"] isKindOfClass:NSDictionary.class] ? mf[@"ContentPackFor"] : nil;
                NSString *cpfUid = [cpf[@"UniqueID"] isKindOfClass:NSString.class] ? cpf[@"UniqueID"] : @"";
                if ([cpfUid caseInsensitiveCompare:@"Pathoschild.ContentPatcher"] != NSOrderedSame) continue;

                // Skip Vietnamese translation packs themselves
                NSString *uidStr = [mf[@"UniqueID"] isKindOfClass:NSString.class] ? (NSString *)mf[@"UniqueID"] : @"";
                NSString *nameStr = [mf[@"Name"] isKindOfClass:NSString.class] ? (NSString *)mf[@"Name"] : @"";
                NSString *uidLow = uidStr.lowercaseString;
                NSString *nameLow = nameStr.lowercaseString;
                if ([uidLow containsString:@"viethoa"] || [uidLow containsString:@"vietnam"] ||
                    [nameLow containsString:@"việt hóa"] || [nameLow containsString:@"vietnamese"] ||
                    [nameLow containsString:@"viethoa"]) continue;

                // Fast pre-check: inspect content.json first; only scan sub-JSONs when content.json uses Include
                // (avoids walking huge assets/ trees unless included JSONs exist; @autoreleasepool caps memory — credit @Mudkip267)
                NSData *rootCj = [NSData dataWithContentsOfFile:join(packDir, @"content.json") options:NSDataReadingMappedIfSafe error:nil];
                BOOL usesLanguageToken = NO;
                BOOL hasIncludeAction = NO;
                if (rootCj.length > 0 && rootCj.length <= 2 * 1024 * 1024) {
                    NSString *cjs = [[NSString alloc] initWithData:rootCj encoding:NSUTF8StringEncoding];
                    if (cjs) {
                        if ([cjs rangeOfString:@"{{language}}" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                            usesLanguageToken = YES;
                        } else if ([cjs rangeOfString:@"\"Include\"" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                            hasIncludeAction = YES;
                        }
                    }
                }
                if (!usesLanguageToken && hasIncludeAction) {
                    NSDirectoryEnumerator *je = [fm() enumeratorAtPath:packDir];
                    NSString *jRel = nil;
                    while ((jRel = [je nextObject])) { @autoreleasepool {
                        NSString *ft = je.fileAttributes.fileType;
                        NSString *topSub = jRel.pathComponents.firstObject.lowercaseString;
                        if ([ft isEqualToString:NSFileTypeDirectory] && [topSub isEqualToString:@"i18n"]) {
                            [je skipDescendants];
                            continue;
                        }
                        if (![ft isEqualToString:NSFileTypeRegular] || ![jRel.pathExtension.lowercaseString isEqualToString:@"json"]) continue;
                        if ([jRel.lowercaseString isEqualToString:@"content.json"] || [jRel.lowercaseString isEqualToString:@"manifest.json"]) continue;
                        NSData *jd = [NSData dataWithContentsOfFile:join(packDir, jRel) options:NSDataReadingMappedIfSafe error:nil];
                        if (jd.length > 0 && jd.length <= 1024 * 1024) {
                            NSString *js = [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding];
                            if (js && [js rangeOfString:@"{{language}}" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                                usesLanguageToken = YES;
                                break;
                            }
                        }
                    }}
                }
                if (!usesLanguageToken) continue;

                NSMutableArray<NSString *> *packFiles = [NSMutableArray array];
                NSDirectoryEnumerator *fe = [fm() enumeratorAtPath:packDir];
                NSString *fRel = nil;
                while ((fRel = [fe nextObject])) { @autoreleasepool {
                    if ([fe.fileAttributes.fileType isEqualToString:NSFileTypeRegular]) {
                        [packFiles addObject:fRel];
                    }
                }}

                // Create 0-byte APFS copy-on-write clones (*.en.<ext> -> *.vi.<ext>, *_en.<ext> -> *_vi.<ext>, en/ -> vi/)
                // Uses copyItemAtPath (APFS clonefile, st_nlink=1) instead of linkItemAtPath (hardlink st_nlink=2 breaks iOS AFC).
                // Never overwrites any genuine existing Vietnamese asset!
                for (NSString *fRel in packFiles) { @autoreleasepool {
                    NSString *ext = fRel.pathExtension;
                    if (!ext.length || ![assetExts containsObject:ext.lowercaseString]) continue;
                    NSString *topSub = fRel.pathComponents.firstObject.lowercaseString;
                    if ([topSub isEqualToString:@"i18n"]) continue;

                    NSString *baseName = fRel.lastPathComponent;
                    NSString *stem = [baseName stringByDeletingPathExtension];
                    NSString *dirRel = [fRel stringByDeletingLastPathComponent];
                    NSString *srcFull = join(packDir, fRel);
                    NSString *dstRel = nil;

                    NSString *newBase = baseName;
                    BOOL matchedStem = NO;
                    if (stem.length > 3 && [stem.lowercaseString hasSuffix:@".en"]) {
                        newBase = [NSString stringWithFormat:@"%@.vi.%@", [stem substringToIndex:stem.length - 3], ext];
                        matchedStem = YES;
                    } else if (stem.length > 3 && [stem.lowercaseString hasSuffix:@"_en"]) {
                        newBase = [NSString stringWithFormat:@"%@_vi.%@", [stem substringToIndex:stem.length - 3], ext];
                        matchedStem = YES;
                    }
                    // Apply BOTH `en/` -> `vi/` directory segment mapping AND `.en`/`_en` filename suffix mapping!
                    NSArray<NSString *> *segs = fRel.pathComponents;
                    if (segs.count >= 2) {
                        NSMutableArray<NSString *> *mSegs = [segs mutableCopy];
                        BOOL matchedSeg = NO;
                        for (NSUInteger si = 0; si + 1 < mSegs.count; si++) {
                            if ([mSegs[si].lowercaseString isEqualToString:@"en"]) {
                                mSegs[si] = @"vi";
                                matchedSeg = YES;
                            }
                        }
                        if (matchedStem) mSegs[mSegs.count - 1] = newBase;
                        if (matchedSeg || matchedStem) dstRel = [NSString pathWithComponents:mSegs];
                    } else if (matchedStem) {
                        dstRel = dirRel.length ? join(dirRel, newBase) : newBase;
                    }

                    if (!dstRel.length || [dstRel isEqualToString:fRel]) continue;
                    NSString *dstFull = join(packDir, dstRel);
                    if ([fm() fileExistsAtPath:dstFull]) {
                        // Auto-heal legacy hardlinked fallbacks (st_nlink > 1) into independent APFS CoW clones (st_nlink = 1)
                        struct stat stSrc, stDst;
                        if (stat(srcFull.fileSystemRepresentation, &stSrc) == 0 &&
                            stat(dstFull.fileSystemRepresentation, &stDst) == 0 &&
                            stSrc.st_ino == stDst.st_ino && stDst.st_nlink > 1) {
                            [fm() removeItemAtPath:dstFull error:nil];
                            if ([fm() copyItemAtPath:srcFull toPath:dstFull error:nil]) created++;
                        }
                        continue;
                    }

                    [fm() createDirectoryAtPath:dstFull.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                    if ([fm() copyItemAtPath:srcFull toPath:dstFull error:nil]) {
                        created++;
                    }
                }}
            }}
        }
    } @catch (NSException *ex) { }
    return created;
}

static NSDictionary *gameDataStatus(NSString *docsPath) {
    if (!docsPath.length) {
        return @{@"hasSdvDll": @NO, @"hasContent": @NO, @"hasSmapi": @NO, @"hasSmapiInternal": @NO, @"ready": @NO, @"gameDir": @""};
    }
    NSString *sub = join(docsPath, @"StardewValley");
    NSString *hiddenGame = join(docsPath, @".game");
    NSString *gameDir = sub;
    if ([fm() fileExistsAtPath:join(sub, @"Stardew Valley.dll")] || dir(join(sub, @"Content"))) {
        gameDir = sub;
    } else if ([fm() fileExistsAtPath:join(hiddenGame, @"Stardew Valley.dll")] || dir(join(hiddenGame, @"Content"))) {
        gameDir = hiddenGame;
    } else if ([fm() fileExistsAtPath:join(docsPath, @"Stardew Valley.dll")] || dir(join(docsPath, @"Content"))) {
        gameDir = docsPath;
    }
    BOOL hasSdv = [fm() fileExistsAtPath:join(gameDir, @"Stardew Valley.dll")];
    NSString *contentDir = join(gameDir, @"Content");
    BOOL hasContent = dir(contentDir) && ([fm() contentsOfDirectoryAtPath:contentDir error:nil].count > 0);
    BOOL hasSmapi = [fm() fileExistsAtPath:join(gameDir, @"StardewModdingAPI.dll")] ||
                    [fm() fileExistsAtPath:join(sub, @"StardewModdingAPI.dll")] ||
                    [fm() fileExistsAtPath:join(hiddenGame, @"StardewModdingAPI.dll")] ||
                    [fm() fileExistsAtPath:join(docsPath, @"StardewModdingAPI.dll")];
    NSString *si0 = join(sub, @"smapi-internal");
    NSString *si1 = join(gameDir, @"smapi-internal");
    NSString *si2 = join(hiddenGame, @"smapi-internal");
    NSString *si3 = join(docsPath, @"smapi-internal");
    BOOL hasSi = (dir(si0) && [fm() contentsOfDirectoryAtPath:si0 error:nil].count > 0) ||
                 (dir(si1) && [fm() contentsOfDirectoryAtPath:si1 error:nil].count > 0) ||
                 (dir(si2) && [fm() contentsOfDirectoryAtPath:si2 error:nil].count > 0) ||
                 (dir(si3) && [fm() contentsOfDirectoryAtPath:si3 error:nil].count > 0);
    return @{
        @"hasSdvDll": @(hasSdv),
        @"hasContent": @(hasContent),
        @"hasSmapi": @(hasSmapi),
        @"hasSmapiInternal": @(hasSi),
        @"ready": @(hasSdv && hasContent),
        @"gameDir": gameDir
    };
}

static NSString *sanitizeFolderName(NSString *raw, NSString *fallback);

static BOOL sdvLooksLikeValidCjkName(NSString *s) {
    if (!s.length) return NO;
    NSUInteger cjkCount = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar ch = [s characterAtIndex:i];
        if (ch == 0xFFFD || ch < 0x20 || (ch >= 0xE000 && ch <= 0xF8FF)) return NO;
        if ((ch >= 0x4E00 && ch <= 0x9FFF) ||   // CJK Unified Ideographs
            (ch >= 0x3400 && ch <= 0x4DBF) ||   // CJK Extension A
            (ch >= 0x3040 && ch <= 0x30FF) ||   // Hiragana / Katakana
            (ch >= 0xAC00 && ch <= 0xD7AF)) {   // Hangul Syllables
            cjkCount++;
        }
    }
    return cjkCount > 0;
}

static NSString *decodeZipEntryName(const char *bytes, unsigned len) {
    if (!bytes || len == 0) return nil;
    NSString *r = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
    if (r.length) return r;

    // Detect consecutive multi-byte non-ASCII runs (Chinese GB18030/Big5, Japanese ShiftJIS, Korean EUC-KR)
    // BEFORE falling back to single-byte CP1258/CP1252 (which accept any byte and garble CJK mod folder names!).
    unsigned highPairs = 0;
    const unsigned char *ub = (const unsigned char *)bytes;
    for (unsigned i = 0; i + 1 < len; i++) {
        if (ub[i] >= 0x80 && ub[i + 1] >= 0x80) {
            highPairs++;
            i++;
        }
    }
    if (highPairs >= 2) {
        NSStringEncoding cjkEncs[] = {
            CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000),
            NSShiftJISStringEncoding,
            CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_KR),
            CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingBig5)
        };
        for (size_t k = 0; k < sizeof(cjkEncs) / sizeof(cjkEncs[0]); k++) {
            r = [[NSString alloc] initWithBytes:bytes length:len encoding:cjkEncs[k]];
            if (sdvLooksLikeValidCjkName(r)) return r;
        }
    }

    // Fallback for Windows-packed Vietnamese / Western ZIP archives (CP1258 -> CP1252 -> CP437 -> Latin1)
    NSStringEncoding encs[] = {
        CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingWindowsVietnamese),
        NSWindowsCP1252StringEncoding,
        CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSLatinUS),
        NSISOLatin1StringEncoding
    };
    for (size_t k = 0; k < sizeof(encs) / sizeof(encs[0]); k++) {
        r = [[NSString alloc] initWithBytes:bytes length:len encoding:encs[k]];
        if (r.length) return r;
    }
    return nil;
}

static NSString *clean(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length || path.length > 1400) fail(@"Đường dẫn tệp trống hoặc quá dài.");
    NSString *norm = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSMutableArray<NSString *> *outParts = [NSMutableArray array];
    for (NSString *rawSeg in [norm componentsSeparatedByString:@"/"]) {
        if (!rawSeg.length || [rawSeg isEqualToString:@"."]) continue;
        if ([rawSeg isEqualToString:@".."] || [rawSeg rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
            fail(@"Gói chứa đường dẫn không hợp lệ.");
        }
        // Replace stray colons in archive names (Windows/macOS zip edge cases) safely instead of aborting
        NSString *seg = [rawSeg stringByReplacingOccurrencesOfString:@":" withString:@"_"];
        [outParts addObject:seg];
    }
    if (!outParts.count) fail(@"Đường dẫn tệp trống.");
    return [outParts componentsJoinedByString:@"/"];
}
static NSString *inside(NSString *root, NSString *rel) {
    NSString *p=root;
    for(NSString *s in [clean(rel) componentsSeparatedByString:@"/"]) {
        p=join(p,s);
        if([[[fm() attributesOfItemAtPath:p error:nil] fileType] isEqual:NSFileTypeSymbolicLink]) fail(@"Đường dẫn chứa liên kết tượng trưng.");
    }
    return p;
}
static NSArray *files(NSString *p) {
    NSMutableArray *a=[NSMutableArray array]; NSDirectoryEnumerator *en=[fm() enumeratorAtPath:p];
    for(NSString *r in en){ NSString *type=en.fileAttributes.fileType; if([type isEqual:NSFileTypeRegular]) [a addObject:r]; }
    return [a sortedArrayUsingSelector:@selector(compare:)];
}

// Fast manifest-only scanner for Mods/ (skips assets/, i18n/, data/, SaveSlots/ subtrees -> 20x-50x faster with SVE/Ridgeside!)
static NSArray<NSString *> *modManifestFiles(NSString *modsDir) {
    if (!modsDir.length || !dir(modsDir)) return @[];
    static NSSet<NSString *> *skipSubdirs = nil;
    static dispatch_once_t onceSkip;
    dispatch_once(&onceSkip, ^{
        skipSubdirs = [NSSet setWithArray:@[
            @"assets", @"i18n", @"data", @".git", @"__macosx", @"saveslots", @"screenshots", @"cache"
        ]];
    });
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSDirectoryEnumerator *en = [fm() enumeratorAtPath:modsDir];
    for (NSString *r in en) {
        NSArray<NSString *> *parts = r.pathComponents;
        NSString *ft = en.fileAttributes.fileType;
        if ([ft isEqualToString:NSFileTypeDirectory]) {
            if (parts.count >= 4 || (parts.count >= 2 && [skipSubdirs containsObject:parts.lastObject.lowercaseString])) {
                [en skipDescendants];
            }
            continue;
        }
        if ([ft isEqualToString:NSFileTypeRegular] && [r.lastPathComponent.lowercaseString isEqualToString:@"manifest.json"]) {
            [out addObject:r];
        }
    }
    return [out sortedArrayUsingSelector:@selector(compare:)];
}

static BOOL sdvSafeCaseRenameInDir(NSString *dirPath, NSString *oldName, NSString *newName) {
    if (!dirPath.length || !oldName.length || !newName.length) return NO;
    if ([oldName isEqualToString:newName]) return NO;
    if ([oldName caseInsensitiveCompare:newName] != NSOrderedSame) return NO;
    NSString *src = join(dirPath, oldName);
    NSString *dst = join(dirPath, newName);
    if (![fm() fileExistsAtPath:src]) return NO;
    // On APFS Case-Sensitive, dst will not exist if only casing differs (unless both files exist simultaneously)
    if ([fm() fileExistsAtPath:dst]) {
        struct stat stA, stB;
        if (lstat(src.fileSystemRepresentation, &stA) == 0 && lstat(dst.fileSystemRepresentation, &stB) == 0 && stA.st_ino != stB.st_ino) {
            return NO; // Distinct file already exists with exact target case
        }
    }
    NSString *tmp = join(dirPath, [NSString stringWithFormat:@".garden_case_%@", NSUUID.UUID.UUIDString]);
    if (![fm() moveItemAtPath:src toPath:tmp error:nil]) return NO;
    if (![fm() moveItemAtPath:tmp toPath:dst error:nil]) {
        [fm() moveItemAtPath:tmp toPath:src error:nil];
        return NO;
    }
    return YES;
}

// Auto-heals Windows/macOS case mismatches inside a mod root or staging directory (Manifest.json, Content.json, Config.json, I18N/*.JSON, EntryDll)
static NSDictionary *sdvHealModTreeCaseSensitivity(NSString *treeRoot) {
    NSUInteger fixedJson = 0, fixedDll = 0;
    if (!treeRoot.length || !dir(treeRoot)) return @{@"fixedJson": @0, @"fixedDll": @0};

    // Pass 1: Normalize manifest.json / content.json / config.json & i18n/ folder casing
    NSMutableArray<NSString *> *dirsToCheck = [NSMutableArray arrayWithObject:treeRoot];
    NSDirectoryEnumerator *en = [fm() enumeratorAtPath:treeRoot];
    for (NSString *rel in en) {
        if (![en.fileAttributes.fileType isEqualToString:NSFileTypeDirectory]) continue;
        NSArray<NSString *> *parts = rel.pathComponents;
        NSString *leafLow = parts.lastObject.lowercaseString;
        if (parts.count > 4 || [leafLow isEqualToString:@"assets"] || [leafLow isEqualToString:@".git"] || [leafLow isEqualToString:@"__macosx"]) {
            [en skipDescendants];
            continue;
        }
        [dirsToCheck addObject:join(treeRoot, rel)];
    }

    for (NSString *dPath in dirsToCheck) { @autoreleasepool {
        NSArray<NSString *> *entries = [fm() contentsOfDirectoryAtPath:dPath error:nil] ?: @[];
        for (NSString *fn in entries) {
            NSString *lo = fn.lowercaseString;
            if ([lo isEqualToString:@"manifest.json"] && ![fn isEqualToString:@"manifest.json"]) {
                if (sdvSafeCaseRenameInDir(dPath, fn, @"manifest.json")) fixedJson++;
            } else if ([lo isEqualToString:@"content.json"] && ![fn isEqualToString:@"content.json"]) {
                if (sdvSafeCaseRenameInDir(dPath, fn, @"content.json")) fixedJson++;
            } else if ([lo isEqualToString:@"config.json"] && ![fn isEqualToString:@"config.json"]) {
                if (sdvSafeCaseRenameInDir(dPath, fn, @"config.json")) fixedJson++;
            } else if ([lo isEqualToString:@"i18n"] && ![fn isEqualToString:@"i18n"] && dir(join(dPath, fn))) {
                if (sdvSafeCaseRenameInDir(dPath, fn, @"i18n")) fixedJson++;
            }
        }
        NSString *i18nDir = join(dPath, @"i18n");
        if (dir(i18nDir)) {
            for (NSString *tf in ([fm() contentsOfDirectoryAtPath:i18nDir error:nil] ?: @[])) {
                if ([tf.pathExtension.lowercaseString isEqualToString:@"json"] && ![tf.pathExtension isEqualToString:@"json"]) {
                    NSString *target = [[tf stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"];
                    if (sdvSafeCaseRenameInDir(i18nDir, tf, target)) fixedJson++;
                }
            }
        }
        // Pass 2: Match EntryDll in manifest.json case-insensitively against .dll files on disk
        NSString *mfPath = join(dPath, @"manifest.json");
        if ([fm() fileExistsAtPath:mfPath] && !dir(mfPath)) {
            @try {
                id parsed = jsonAt(mfPath);
                if ([parsed isKindOfClass:NSDictionary.class]) {
                    NSString *entryDll = nil;
                    for (id k in [(NSDictionary *)parsed allKeys]) {
                        if ([k isKindOfClass:NSString.class] && [k caseInsensitiveCompare:@"EntryDll"] == NSOrderedSame && [parsed[k] isKindOfClass:NSString.class]) {
                            entryDll = parsed[k];
                            break;
                        }
                    }
                    if (entryDll.length && ![entryDll containsString:@"/"] && ![entryDll containsString:@"\\"]) {
                        if (![fm() fileExistsAtPath:join(dPath, entryDll)]) {
                            for (NSString *cand in ([fm() contentsOfDirectoryAtPath:dPath error:nil] ?: @[])) {
                                if ([cand caseInsensitiveCompare:entryDll] == NSOrderedSame && ![cand isEqualToString:entryDll]) {
                                    if (sdvSafeCaseRenameInDir(dPath, cand, entryDll)) fixedDll++;
                                    break;
                                }
                            }
                        }
                    }
                }
            } @catch (NSException *ignored) { }
        }
    }}
    return @{@"fixedJson": @(fixedJson), @"fixedDll": @(fixedDll)};
}

static BOOL isJunkArchiveEntry(NSString *r) {
    if (!r.length) return YES;
    if ([r.pathComponents containsObject:@"__MACOSX"]) return YES;
    NSString *lastLow = r.lastPathComponent.lowercaseString;
    return [lastLow isEqualToString:@".ds_store"] || [lastLow isEqualToString:@"thumbs.db"] || [lastLow isEqualToString:@"desktop.ini"];
}

static void copyModDirectoryRecursive(NSString *srcDir, NSString *dstDir) {
    mkdirs(dstDir);
    NSDirectoryEnumerator *en = [fm() enumeratorAtPath:srcDir];
    uint64_t total = 0;
    NSUInteger count = 0;
    for (NSString *rel in en) {
        @autoreleasepool {
            NSString *type = en.fileAttributes.fileType;
            if (![type isEqualToString:NSFileTypeRegular]) continue;
            if (isJunkArchiveEntry(rel)) continue;
            if (++count > 40000) fail(@"Thư mục mod vượt quá 40.000 tệp.");
            NSString *srcFile = join(srcDir, rel);
            unsigned long long sz = [en.fileAttributes fileSize];
            if (sz > 1024ULL * 1024 * 1024 || (total += sz) > 4ULL * 1024 * 1024 * 1024) {
                fail(@"Thư mục mod vượt giới hạn dung lượng (4 GB).");
            }
            NSString *dstFile = inside(dstDir, rel);
            mkdirs(dstFile.stringByDeletingLastPathComponent);
            NSError *e = nil;
            if ([fm() fileExistsAtPath:dstFile]) sdvRemoveItemQuiet(dstFile);
            BOOL ok = [fm() copyItemAtPath:srcFile toPath:dstFile error:&e];
            check(ok, e);
            chmod(dstFile.fileSystemRepresentation, 0644);
        }
    }
}

static BOOL isNestedArchivePath(NSString *path) {
    NSString *low = path.lastPathComponent.lowercaseString;
    if ([low hasSuffix:@".tar.gz"] || [low hasSuffix:@".tar.bz2"] || [low hasSuffix:@".tar.xz"] ||
        [low hasSuffix:@".tar.zst"] || [low hasSuffix:@".tar.lz4"]) {
        return YES;
    }
    NSString *ext = path.pathExtension.lowercaseString;
    static NSSet<NSString *> *sArchExts = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sArchExts = [NSSet setWithArray:@[
            @"zip", @"rar", @"7z", @"tar", @"tgz", @"tbz2", @"txz", @"tzst", @"tlz4",
            @"cab", @"xar", @"cpio", @"lha", @"lzh", @"iso"
        ]];
    });
    return [sArchExts containsObject:ext];
}

// Dynamic bridge to iOS system /usr/lib/libarchive.2.dylib (supports .RAR [RAR4/RAR5], .7Z, .ZIP [Deflate64/LZMA/BZip2/Zstd], .TAR.GZ/.BZ2/.XZ, .CAB, .XAR, .ISO...)
typedef struct {
    BOOL ready;
    void *(*read_new)(void);
    int (*support_filter_all)(void *);
    int (*support_format_all)(void *);
    int (*open_filename)(void *, const char *, size_t);
    int (*next_header)(void *, void **);
    ssize_t (*read_data)(void *, void *, size_t);
    int (*data_skip)(void *);
    int (*read_free)(void *);
    const char *(*error_string)(void *);
    const char *(*entry_pathname)(void *);
    const char *(*entry_pathname_utf8)(void *);
    const wchar_t *(*entry_pathname_w)(void *);
    unsigned int (*entry_filetype)(void *);
    int (*entry_is_encrypted)(void *);
} SDVLibArchiveAPI;

static const SDVLibArchiveAPI *sdvLibArchive(void) {
    static SDVLibArchiveAPI api = {0};
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *h = dlopen("/usr/lib/libarchive.2.dylib", RTLD_LAZY);
        if (!h) return;
        api.read_new            = (void *(*)(void))dlsym(h, "archive_read_new");
        api.support_filter_all  = (int (*)(void *))dlsym(h, "archive_read_support_filter_all");
        api.support_format_all  = (int (*)(void *))dlsym(h, "archive_read_support_format_all");
        api.open_filename       = (int (*)(void *, const char *, size_t))dlsym(h, "archive_read_open_filename");
        api.next_header         = (int (*)(void *, void **))dlsym(h, "archive_read_next_header");
        api.read_data           = (ssize_t (*)(void *, void *, size_t))dlsym(h, "archive_read_data");
        api.data_skip           = (int (*)(void *))dlsym(h, "archive_read_data_skip");
        api.read_free           = (int (*)(void *))dlsym(h, "archive_read_free");
        api.error_string        = (const char *(*)(void *))dlsym(h, "archive_error_string");
        api.entry_pathname      = (const char *(*)(void *))dlsym(h, "archive_entry_pathname");
        api.entry_pathname_utf8 = (const char *(*)(void *))dlsym(h, "archive_entry_pathname_utf8");
        api.entry_pathname_w    = (const wchar_t *(*)(void *))dlsym(h, "archive_entry_pathname_w");
        api.entry_filetype      = (unsigned int (*)(void *))dlsym(h, "archive_entry_filetype");
        api.entry_is_encrypted  = (int (*)(void *))dlsym(h, "archive_entry_is_encrypted");
        api.ready = (api.read_new && api.support_filter_all && api.support_format_all &&
                     api.open_filename && api.next_header && api.read_data && api.read_free);
    });
    return &api;
}

static NSString *decodeLibArchiveEntryName(const SDVLibArchiveAPI *api, void *entry) {
    if (!api || !entry) return nil;
    if (api->entry_pathname_utf8) {
        const char *u8 = api->entry_pathname_utf8(entry);
        if (u8 && u8[0]) {
            NSString *s = [NSString stringWithUTF8String:u8];
            if (s.length) return s;
        }
    }
    if (api->entry_pathname) {
        const char *raw = api->entry_pathname(entry);
        if (raw && raw[0]) {
            NSString *s = decodeZipEntryName(raw, (unsigned)strlen(raw));
            if (s.length) return s;
        }
    }
    if (api->entry_pathname_w) {
        const wchar_t *w = api->entry_pathname_w(entry);
        if (w && w[0]) {
            size_t wlen = wcslen(w);
            NSString *s = [[NSString alloc] initWithBytes:w length:wlen * sizeof(wchar_t) encoding:NSUTF32LittleEndianStringEncoding];
            if (s.length) return s;
        }
    }
    return nil;
}

static void extractArchiveFileToDir(NSString *archivePath, NSString *displayName, NSString *tmp, int depth);

static BOOL extractWithLibArchive(NSString *archivePath, NSString *displayName, NSString *tmp, int depth, NSMutableArray<NSString *> *nestedArchives, NSString **outErr) {
    const SDVLibArchiveAPI *api = sdvLibArchive();
    if (!api->ready) {
        if (outErr) *outErr = @"Không tải được bộ giải nén hệ thống iOS (libarchive).";
        return NO;
    }
    void *a = api->read_new();
    if (!a) {
        if (outErr) *outErr = @"Không khởi tạo được bộ giải nén.";
        return NO;
    }
    api->support_filter_all(a);
    api->support_format_all(a);

    if (api->open_filename(a, archivePath.fileSystemRepresentation, 65536) != 0) {
        const char *es = api->error_string ? api->error_string(a) : NULL;
        if (outErr) *outErr = [NSString stringWithFormat:@"Không mở được tệp nén '%@' (%s).", displayName, es ?: "tệp hỏng hoặc định dạng không hỗ trợ"];
        api->read_free(a);
        return NO;
    }

    uint64_t total = 0;
    unsigned count = 0;
    unsigned extracted = 0;
    uint8_t *buf = (uint8_t *)malloc(65536);
    if (!buf) {
        api->read_free(a);
        if (outErr) *outErr = @"Thiếu bộ nhớ tạm khi giải nén.";
        return NO;
    }

    BOOL ok = YES;
    void *entry = NULL;
    for (;;) {
        int rc = api->next_header(a, &entry);
        if (rc == 1) break; // ARCHIVE_EOF
        if (rc < 0 && rc != -20) { // allow ARCHIVE_WARN (-20)
            const char *es = api->error_string ? api->error_string(a) : NULL;
            if (outErr) *outErr = [NSString stringWithFormat:@"Tệp nén '%@' không đọc được header (%s).", displayName, es ?: "dữ liệu lỗi"];
            ok = NO;
            break;
        }
        if (++count > 40000) {
            if (outErr) *outErr = @"Gói nén vượt quá 40.000 mục.";
            ok = NO;
            break;
        }
        @autoreleasepool {
            NSString *rawName = decodeLibArchiveEntryName(api, entry);
            if (!rawName.length) {
                if (api->data_skip) api->data_skip(a);
                continue;
            }
            rawName = [rawName stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            unsigned int ft = api->entry_filetype ? (api->entry_filetype(entry) & 0170000) : 0;
            // Skip directories (0040000), symlinks (0120000), and OS metadata junk
            if (ft == 0040000 || ft == 0120000 || [rawName hasSuffix:@"/"] || isJunkArchiveEntry(rawName)) {
                if (api->data_skip) api->data_skip(a);
                continue;
            }
            if (api->entry_is_encrypted && api->entry_is_encrypted(entry)) {
                if (outErr) *outErr = [NSString stringWithFormat:@"Tệp nén '%@' có đặt mật khẩu bảo vệ (mục '%@'). Hãy giải nén bằng mật khẩu trước rồi chọn thư mục Mod!", displayName, rawName.lastPathComponent];
                ok = NO;
                break;
            }
            NSString *r = nil;
            NSString *p = nil;
            @try {
                r = clean(rawName);
                p = inside(tmp, r);
                mkdirs(p.stringByDeletingLastPathComponent);
            } @catch (NSException *ex) {
                if (outErr) *outErr = ex.reason ?: @"Đường dẫn trong gói nén không hợp lệ.";
                ok = NO;
                break;
            }

            sdvPrepareWritableFileTarget(p);
            FILE *fp = fopen(p.fileSystemRepresentation, "wb");
            if (!fp) {
                if (outErr) *outErr = [NSString stringWithFormat:@"Không tạo được tệp '%@'.", r.lastPathComponent];
                ok = NO;
                break;
            }

            BOOL entryOk = YES;
            for (;;) {
                ssize_t rd = api->read_data(a, buf, 65536);
                if (rd == 0) break;
                if (rd < 0) {
                    const char *es = api->error_string ? api->error_string(a) : NULL;
                    BOOL isRar = [displayName.lowercaseString hasSuffix:@".rar"];
                    NSString *hint = isRar
                        ? @" (Gợi ý: iOS cũ có thể không hỗ trợ chuẩn nén RAR5 mới của WinRAR 6/7 — hãy đổi sang tệp .ZIP hoặc giải nén sẵn thành thư mục rồi chọn!)"
                        : @"";
                    if (outErr) *outErr = [NSString stringWithFormat:@"Không giải nén được '%@' trong '%@' (%s).%@", r.lastPathComponent, displayName, es ?: "chuẩn nén đặc biệt hoặc có mật khẩu", hint];
                    entryOk = NO;
                    break;
                }
                total += (uint64_t)rd;
                if (total > 4ULL * 1024 * 1024 * 1024) {
                    if (outErr) *outErr = @"Gói vượt giới hạn giải nén (4 GB).";
                    entryOk = NO;
                    break;
                }
                if (fwrite(buf, 1, (size_t)rd, fp) != (size_t)rd) {
                    if (outErr) *outErr = @"Không ghi được tệp khi giải nén (kiểm tra dung lượng trống trên iPhone).";
                    entryOk = NO;
                    break;
                }
            }
            fclose(fp);
            if (!entryOk) {
                sdvRemoveItemQuiet(p);
                ok = NO;
                break;
            }
            extracted++;
            if (depth < 2 && isNestedArchivePath(r)) {
                [nestedArchives addObject:p];
            }
        }
    }

    free(buf);
    api->read_free(a);
    if (ok && extracted == 0 && count == 0) {
        if (outErr) *outErr = [NSString stringWithFormat:@"Tệp nén '%@' trống hoặc không chứa tệp hợp lệ.", displayName];
        return NO;
    }
    return ok;
}

static void unpackNestedArchives(NSArray<NSString *> *nestedArchives, int depth) {
    if (depth >= 2 || !nestedArchives.count) return;
    for (NSString *na in nestedArchives) {
        @try {
            NSString *baseName = [na.lastPathComponent stringByDeletingPathExtension];
            if ([baseName.lowercaseString hasSuffix:@".tar"]) {
                baseName = [baseName stringByDeletingPathExtension];
            }
            NSString *subOut = join(na.stringByDeletingLastPathComponent, sanitizeFolderName(baseName, @"SubMod"));
            mkdirs(subOut);
            extractArchiveFileToDir(na, na.lastPathComponent, subOut, depth + 1);
            sdvRemoveItemQuiet(na);
        } @catch (NSException *ignored) { }
    }
}

static void extractArchiveFileToDir(NSString *archivePath, NSString *displayName, NSString *tmp, int depth) {
    if (depth > 2) return;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:archivePath];
    NSData *hdr = fh ? [fh readDataOfLength:8] : nil;
    [fh closeFile];
    const unsigned char *hb = (const unsigned char *)hdr.bytes;
    NSUInteger hl = hdr.length;
    BOOL isZipMagic = (hl >= 4 && hb[0] == 'P' && hb[1] == 'K' && (hb[2] == 3 || hb[2] == 5 || hb[2] == 7));

    NSMutableArray<NSString *> *nestedArchives = [NSMutableArray array];

    // Fast path for standard Deflate/Store ZIP via miniz; automatically falls back to iOS system libarchive
    // if ZIP uses Deflate64/LZMA/BZip2/Zstd or streaming descriptors, AND handles .RAR / .7Z / .TAR.GZ / .TAR.XZ / .CAB / .ISO directly!
    if (isZipMagic) {
        mz_zip_archive z = {0};
        if (mz_zip_reader_init_file(&z, archivePath.fileSystemRepresentation, 0)) {
            BOOL fallbackToLibArchive = NO;
            @try {
                uint64_t total = 0;
                unsigned count = mz_zip_reader_get_num_files(&z);
                if (count > 40000) fail(@"Gói vượt 40.000 mục.");
                for (unsigned i = 0; i < count; i++) { @autoreleasepool {
                    mz_zip_archive_file_stat st;
                    if (!mz_zip_reader_file_stat(&z, i, &st)) { fallbackToLibArchive = YES; break; }
                    if (st.m_is_directory) continue;
                    unsigned n = mz_zip_reader_get_filename(&z, i, NULL, 0);
                    if (n > 4096 || n < 2) continue;
                    char name[4096];
                    mz_zip_reader_get_filename(&z, i, name, n);
                    NSString *rawName = decodeZipEntryName(name, n - 1);
                    if (!rawName.length) continue;
                    rawName = [rawName stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
                    if (isJunkArchiveEntry(rawName)) continue;
                    if (((st.m_external_attr >> 16) & 0170000) == 0120000) continue;
                    if (st.m_is_encrypted) {
                        fail([NSString stringWithFormat:@"Tệp nén '%@' có đặt mật khẩu bảo vệ (mục '%@'). Hãy giải nén bằng mật khẩu trước rồi chọn thư mục Mod!", displayName, rawName.lastPathComponent]);
                    }
                    if (!st.m_is_supported) {
                        // e.g. Deflate64 / LZMA / BZip2 / Zstd inside .zip -> let libarchive handle it!
                        fallbackToLibArchive = YES;
                        break;
                    }
                    if (st.m_uncomp_size > 1024ULL * 1024 * 1024 || (total += st.m_uncomp_size) > 4ULL * 1024 * 1024 * 1024) {
                        fail(@"Gói vượt giới hạn giải nén (4 GB).");
                    }
                    NSString *r = clean(rawName);
                    NSString *p = inside(tmp, r);
                    mkdirs(p.stringByDeletingLastPathComponent);
                    sdvPrepareWritableFileTarget(p);
                    if (!mz_zip_reader_extract_to_file(&z, i, p.fileSystemRepresentation, 0)) {
                        fallbackToLibArchive = YES;
                        break;
                    }
                    if (depth < 2 && isNestedArchivePath(r)) {
                        [nestedArchives addObject:p];
                    }
                }}
            } @finally {
                mz_zip_reader_end(&z);
            }
            if (!fallbackToLibArchive) {
                unpackNestedArchives(nestedArchives, depth);
                return;
            }
            [nestedArchives removeAllObjects];
        }
    }

    NSString *laErr = nil;
    if (!extractWithLibArchive(archivePath, displayName, tmp, depth, nestedArchives, &laErr)) {
        fail(laErr ?: [NSString stringWithFormat:@"Không giải nén được '%@'.", displayName]);
    }
    unpackNestedArchives(nestedArchives, depth);
}

static NSString *unpack(NSURL *url, NSString *tmp) {
    mkdirs(tmp);
    BOOL isDir = NO;
    if ([fm() fileExistsAtPath:url.path isDirectory:&isDir] && isDir) {
        NSString *leaf = sanitizeFolderName(url.lastPathComponent, @"ModFolder");
        copyModDirectoryRecursive(url.path, join(tmp, leaf));
        return tmp;
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:url.path];
    NSData *hdr = fh ? [fh readDataOfLength:8] : nil;
    [fh closeFile];
    const unsigned char *hb = (const unsigned char *)hdr.bytes;
    NSUInteger hl = hdr.length;

    BOOL isXnbMagic = (hl >= 3 && hb[0] == 'X' && hb[1] == 'N' && hb[2] == 'B');
    NSString *ext = url.pathExtension.lowercaseString;

    // Loose direct mod/content asset (.xnb, .json, .dll, .png, .tbin, .tmxl)
    if (isXnbMagic || [ext isEqualToString:@"xnb"] || [ext isEqualToString:@"json"] ||
        [ext isEqualToString:@"dll"] || [ext isEqualToString:@"png"] || [ext isEqualToString:@"tbin"]) {
        writeFile(readFile(url.path), inside(tmp, url.lastPathComponent));
        return tmp;
    }

    // Extract ANY archive format supported by iOS (.ZIP, .RAR, .7Z, .TAR.GZ, .TGZ, .TAR.BZ2, .TAR.XZ, .TAR, .CAB, .XAR, .ISO...)
    extractArchiveFileToDir(url.path, url.lastPathComponent ?: @"mod_archive", tmp, 0);
    return tmp;
}

static BOOL sdvIsKnownContentSubfolder(NSString *segLow) {
    if (!segLow.length) return NO;
    static NSSet<NSString *> *sDirs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sDirs = [NSSet setWithArray:@[
            @"animals", @"buildings", @"characters", @"data", @"effects", @"fonts",
            @"loosesprites", @"maps", @"minigames", @"portraits", @"strings",
            @"terrainfeatures", @"tilesheets", @"volcanodungeon", @"xact"
        ]];
    });
    return [sDirs containsObject:segLow];
}

static BOOL sdvIsKnownContentAssetExt(NSString *extLow) {
    return [extLow isEqualToString:@"xnb"] || [extLow isEqualToString:@"xwb"] ||
           [extLow isEqualToString:@"xsb"] || [extLow isEqualToString:@"xgs"];
}

static NSUInteger importGameDataFromDirectory(NSURL *dirUrl, NSString *docsPath) {
    NSString *srcRoot = dirUrl.path;
    if (!dir(srcRoot)) fail(@"Không đọc được thư mục dữ liệu đã chọn.");
    BOOL hasExistingSdv = [gameDataStatus(docsPath)[@"hasSdvDll"] boolValue];

    // Detect whether user picked Stardew Valley root folder, Content/ folder, or a Content subfolder (e.g. Portraits/)
    NSString *srcGameRoot = nil;
    NSString *contentOnlyPrefix = nil;
    if ([fm() fileExistsAtPath:join(srcRoot, @"Stardew Valley.dll")] || dir(join(srcRoot, @"Content"))) {
        srcGameRoot = srcRoot;
    } else if ([srcRoot.lastPathComponent.lowercaseString isEqualToString:@"content"]) {
        contentOnlyPrefix = @"Content";
    } else if (hasExistingSdv && sdvIsKnownContentSubfolder(srcRoot.lastPathComponent.lowercaseString)) {
        contentOnlyPrefix = join(@"Content", srcRoot.lastPathComponent);
    } else {
        // Check 1 level deeper wrapper folder
        for (NSString *sub in ([fm() contentsOfDirectoryAtPath:srcRoot error:nil] ?: @[])) {
            if ([sub hasPrefix:@"."]) continue;
            NSString *sp = join(srcRoot, sub);
            if (!dir(sp)) continue;
            if ([fm() fileExistsAtPath:join(sp, @"Stardew Valley.dll")] || dir(join(sp, @"Content"))) {
                srcGameRoot = sp;
                break;
            }
            if (hasExistingSdv && sdvIsKnownContentSubfolder(sub.lowercaseString)) {
                contentOnlyPrefix = @"Content";
                break;
            }
        }
    }
    if (!srcGameRoot && !contentOnlyPrefix) {
        fail(@"Thư mục này không chứa dữ liệu game PC (Stardew Valley.dll hoặc Content/).");
    }

    mkdirs(docsPath);
    NSString *gameRoot = sdvHiddenGameDir(docsPath);
    mkdirs(join(docsPath, @"Mods"));
    mkdirs(join(docsPath, @"Saves"));
    mkdirs(join(docsPath, @"ErrorLogs"));

    NSMutableSet<NSString *> *bundleRuntimeFiles = [NSMutableSet set];
    for (NSString *bf in ([fm() contentsOfDirectoryAtPath:NSBundle.mainBundle.bundlePath error:nil] ?: @[])) {
        if ([bf.pathExtension.lowercaseString isEqualToString:@"dll"]) [bundleRuntimeFiles addObject:bf.lowercaseString];
    }

    NSString *enumBase = srcGameRoot ?: srcRoot;
    NSDirectoryEnumerator *en = [fm() enumeratorAtPath:enumBase];
    NSUInteger written = 0;
    for (NSString *rawRel in en) { @autoreleasepool {
        if (![en.fileAttributes.fileType isEqualToString:NSFileTypeRegular]) continue;
        if (isJunkArchiveEntry(rawRel)) continue;
        NSString *rel = contentOnlyPrefix ? join(contentOnlyPrefix, rawRel) : rawRel;
        rel = clean(rel);
        NSArray<NSString *> *relParts = rel.pathComponents;
        NSString *topLow = relParts.firstObject.lowercaseString;
        NSString *fileLow = rel.lastPathComponent.lowercaseString;
        NSString *extLow = rel.pathExtension.lowercaseString;
        if ([topLow isEqualToString:@"saves"] || [topLow isEqualToString:@"smapi-internal"]) continue;
        if ([topLow isEqualToString:@"mods"] && relParts.count >= 2 &&
            ([relParts[1] caseInsensitiveCompare:@"SDViOSTouchControls"] == NSOrderedSame ||
             [relParts[1] caseInsensitiveCompare:@"SDVMobileControls"] == NSOrderedSame)) continue;
        if (relParts.count == 1 && ([fileLow hasPrefix:@"stardewmoddingapi"] || sdvIsUnusedGameRootJunk(fileLow, extLow) || [bundleRuntimeFiles containsObject:fileLow])) continue;

        NSString *srcFile = join(enumBase, rawRel);
        NSString *targetBase = [topLow isEqualToString:@"mods"] ? docsPath : gameRoot;
        NSString *dst = inside(targetBase, rel);
        mkdirs(dst.stringByDeletingLastPathComponent);
        if ([fm() fileExistsAtPath:dst]) {
            sdvRemoveItemQuiet(dst);
        }
        NSError *ce = nil;
        if ([fm() copyItemAtPath:srcFile toPath:dst error:&ce]) {
            chmod(dst.fileSystemRepresentation, 0644);
            written++;
        }
    }}
    if (written == 0) fail(@"Không chép được tệp dữ liệu nào từ thư mục đã chọn.");
    sdvMigrateDocumentsToHiddenLayout(docsPath);
    syncBundledLidgren(docsPath);
    syncBundledSmapi(docsPath);
    syncBundledMobileControls(docsPath);
    return written;
}

static NSUInteger importGameDataWithLibArchive(NSURL *url, NSString *docsPath) {
    const SDVLibArchiveAPI *api = sdvLibArchive();
    if (!api->ready) fail(@"Không tải được bộ giải nén hệ thống iOS (libarchive).");
    BOOL hasExistingSdv = [gameDataStatus(docsPath)[@"hasSdvDll"] boolValue];

    // Pass 1: Detect wrapper folder prefix containing Stardew Valley.dll / Content/ / Content subfolders / StardewModdingAPI.dll
    NSString *bestPrefix = nil;
    NSInteger bestScore = -1;
    BOOL wrapIntoContent = NO;
    {
        void *a = api->read_new();
        api->support_filter_all(a);
        api->support_format_all(a);
        if (api->open_filename(a, url.fileSystemRepresentation, 65536) != 0) {
            const char *es = api->error_string ? api->error_string(a) : NULL;
            NSString *msg = [NSString stringWithFormat:@"Không mở được gói dữ liệu '%@' (%s).", url.lastPathComponent ?: @"archive", es ?: "định dạng không hỗ trợ"];
            api->read_free(a);
            fail(msg);
        }
        void *entry = NULL;
        unsigned count = 0;
        for (;;) {
            int rc = api->next_header(a, &entry);
            if (rc == 1) break;
            if (rc < 0 && rc != -20) break;
            if (++count > 80000) { api->read_free(a); fail(@"Gói vượt quá 80.000 mục."); }
            @autoreleasepool {
                if (api->entry_is_encrypted && api->entry_is_encrypted(entry)) {
                    api->read_free(a);
                    fail(@"Gói dữ liệu có đặt mật khẩu bảo vệ. Hãy giải nén bằng mật khẩu trước rồi chọn lại!");
                }
                NSString *raw = decodeLibArchiveEntryName(api, entry);
                if (api->data_skip) api->data_skip(a);
                if (!raw.length) continue;
                raw = [raw stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
                if (isJunkArchiveEntry(raw) || [raw hasSuffix:@"/"]) continue;
                NSArray<NSString *> *parts = raw.pathComponents;
                NSString *lastLow = raw.lastPathComponent.lowercaseString;
                NSString *extLow = raw.pathExtension.lowercaseString;
                if ([lastLow isEqualToString:@"stardew valley.dll"]) {
                    NSString *pref = (parts.count > 1) ? [[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, parts.count - 1)]] stringByAppendingString:@"/"] : @"";
                    if (bestScore < 100 || (bestScore == 100 && pref.length < bestPrefix.length)) { bestScore = 100; bestPrefix = pref; wrapIntoContent = NO; }
                } else if ([lastLow isEqualToString:@"stardewmoddingapi.dll"]) {
                    NSString *pref = (parts.count > 1) ? [[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, parts.count - 1)]] stringByAppendingString:@"/"] : @"";
                    if (bestScore < 80) { bestScore = 80; bestPrefix = pref; wrapIntoContent = NO; }
                } else {
                    for (NSUInteger k = 0; k + 1 < parts.count; k++) {
                        NSString *seg = parts[k].lowercaseString;
                        if ([seg isEqualToString:@"content"] || [seg isEqualToString:@"smapi-internal"]) {
                            NSInteger sc = [seg isEqualToString:@"content"] ? 90 : 70;
                            NSString *pref = (k > 0) ? [[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, k)]] stringByAppendingString:@"/"] : @"";
                            if (bestScore < sc || (bestScore == sc && pref.length < bestPrefix.length)) { bestScore = sc; bestPrefix = pref; wrapIntoContent = NO; }
                            break;
                        }
                        if (hasExistingSdv && sdvIsKnownContentSubfolder(seg) && sdvIsKnownContentAssetExt(extLow)) {
                            NSString *pref = (k > 0) ? [[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, k)]] stringByAppendingString:@"/"] : @"";
                            if (bestScore < 85 || (bestScore == 85 && pref.length < bestPrefix.length)) { bestScore = 85; bestPrefix = pref; wrapIntoContent = YES; }
                            break;
                        }
                    }
                }
            }
        }
        api->read_free(a);
    }

    if (bestScore < 0 || bestPrefix == nil) {
        fail(@"Gói nén này không chứa dữ liệu game PC (Stardew Valley.dll hoặc Content/). Nếu đây là file mod, hãy dùng nút Chọn tệp Mod!");
    }
    if (bestScore < 85) {
        fail(@"SMAPI 4.5.2 bản iOS đã tích hợp sẵn trong Garden Launcher — bạn không cần nhập gói SMAPI từ PC! Hãy chọn gói dữ liệu game PC chứa Stardew Valley.dll và thư mục Content/.");
    }

    // Pass 2: Stream-extract into visible Documents/StardewValley/ (and Mods/ if included), safely overwriting read-only XNB files!
    mkdirs(docsPath);
    NSString *gameRoot = sdvHiddenGameDir(docsPath);
    mkdirs(join(docsPath, @"Mods"));
    mkdirs(join(docsPath, @"Saves"));
    mkdirs(join(docsPath, @"ErrorLogs"));

    NSMutableSet<NSString *> *bundleRuntimeFiles = [NSMutableSet set];
    for (NSString *bf in ([fm() contentsOfDirectoryAtPath:NSBundle.mainBundle.bundlePath error:nil] ?: @[])) {
        if ([bf.pathExtension.lowercaseString isEqualToString:@"dll"]) [bundleRuntimeFiles addObject:bf.lowercaseString];
    }

    void *a = api->read_new();
    api->support_filter_all(a);
    api->support_format_all(a);
    if (api->open_filename(a, url.fileSystemRepresentation, 65536) != 0) {
        api->read_free(a);
        fail(@"Không mở lại được gói dữ liệu để giải nén.");
    }
    uint8_t *buf = (uint8_t *)malloc(65536);
    uint64_t totalBytes = 0;
    NSUInteger written = 0;
    void *entry = NULL;
    @try {
        for (;;) {
            int rc = api->next_header(a, &entry);
            if (rc == 1) break;
            if (rc < 0 && rc != -20) break;
            @autoreleasepool {
                NSString *raw = decodeLibArchiveEntryName(api, entry);
                unsigned int ft = api->entry_filetype ? (api->entry_filetype(entry) & 0170000) : 0;
                if (!raw.length || ft == 0040000 || ft == 0120000 || (api->entry_is_encrypted && api->entry_is_encrypted(entry))) {
                    if (api->data_skip) api->data_skip(a);
                    continue;
                }
                raw = [raw stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
                if (isJunkArchiveEntry(raw) || [raw hasSuffix:@"/"]) {
                    if (api->data_skip) api->data_skip(a);
                    continue;
                }
                NSString *rel = raw;
                if (bestPrefix.length) {
                    if (![rel hasPrefix:bestPrefix]) {
                        if (api->data_skip) api->data_skip(a);
                        continue;
                    }
                    rel = [rel substringFromIndex:bestPrefix.length];
                }
                while ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
                if (!rel.length) {
                    if (api->data_skip) api->data_skip(a);
                    continue;
                }
                if (wrapIntoContent) rel = [@"Content/" stringByAppendingString:rel];
                rel = clean(rel);
                NSArray<NSString *> *relParts = rel.pathComponents;
                NSString *topLow = relParts.firstObject.lowercaseString;
                NSString *fileLow = rel.lastPathComponent.lowercaseString;
                NSString *extLow = rel.pathExtension.lowercaseString;

                if ([topLow isEqualToString:@"saves"] ||
                    [topLow isEqualToString:@"smapi-internal"] ||
                    ([topLow isEqualToString:@"mods"] && relParts.count >= 2 &&
                     ([relParts[1] caseInsensitiveCompare:@"SDViOSTouchControls"] == NSOrderedSame ||
                      [relParts[1] caseInsensitiveCompare:@"SDVMobileControls"] == NSOrderedSame)) ||
                    (relParts.count == 1 && ([fileLow hasPrefix:@"stardewmoddingapi"] || sdvIsUnusedGameRootJunk(fileLow, extLow) || [bundleRuntimeFiles containsObject:fileLow]))) {
                    if (api->data_skip) api->data_skip(a);
                    continue;
                }

                NSString *targetBase = [topLow isEqualToString:@"mods"] ? docsPath : gameRoot;
                NSString *dst = inside(targetBase, rel);
                mkdirs(dst.stringByDeletingLastPathComponent);
                if ([fm() fileExistsAtPath:dst]) sdvRemoveItemQuiet(dst);
                FILE *fp = fopen(dst.fileSystemRepresentation, "wb");
                if (!fp) fail([NSString stringWithFormat:@"Không tạo được tệp dữ liệu game (%@).", rel.lastPathComponent]);
                for (;;) {
                    ssize_t rd = api->read_data(a, buf, 65536);
                    if (rd == 0) break;
                    if (rd < 0) {
                        const char *es = api->error_string ? api->error_string(a) : NULL;
                        fclose(fp);
                        unlink(dst.fileSystemRepresentation);
                        fail([NSString stringWithFormat:@"Giải nén tệp '%@' thất bại (%s).", rel.lastPathComponent, es ?: "chuẩn nén không hỗ trợ"]);
                    }
                    if ((totalBytes += (uint64_t)rd) > 8ULL * 1024 * 1024 * 1024) { fclose(fp); fail(@"Vượt giới hạn dung lượng 8 GB."); }
                    if (fwrite(buf, 1, (size_t)rd, fp) != (size_t)rd) { fclose(fp); fail(@"Không ghi được dữ liệu game (kiểm tra bộ nhớ trống)."); }
                }
                fclose(fp);
                chmod(dst.fileSystemRepresentation, 0644);
                written++;
            }
        }
    } @finally {
        free(buf);
        api->read_free(a);
    }
    if (written == 0) fail(@"Không giải nén được tệp nào từ gói dữ liệu.");
    sdvMigrateDocumentsToHiddenLayout(docsPath);
    syncBundledLidgren(docsPath);
    syncBundledSmapi(docsPath);
    syncBundledMobileControls(docsPath);
    return written;
}

static NSUInteger importGameDataZip(NSURL *url, NSString *docsPath) {
    if (!docsPath.length) fail(@"Không tìm thấy thư mục Documents của game.");
    BOOL isDirPick = NO;
    if ([fm() fileExistsAtPath:url.path isDirectory:&isDirPick] && isDirPick) {
        return importGameDataFromDirectory(url, docsPath);
    }
    NSString *ext = url.pathExtension.lowercaseString;
    if (![ext isEqualToString:@"zip"]) {
        return importGameDataWithLibArchive(url, docsPath);
    }
    mz_zip_archive z = {0};
    if (!mz_zip_reader_init_file(&z, url.fileSystemRepresentation, 0)) {
        return importGameDataWithLibArchive(url, docsPath);
    }
    BOOL hasExistingSdv = [gameDataStatus(docsPath)[@"hasSdvDll"] boolValue];
    BOOL fallbackToLibArchive = NO;
    NSUInteger written = 0;
    @try {
        unsigned count = mz_zip_reader_get_num_files(&z);
        if (count == 0 || count > 80000) fail(@"Gói ZIP trống hoặc vượt quá 80.000 mục.");

        // Pass 1: Detect wrapper folder prefix AND check if ANY entry uses Deflate64/LZMA/BZip2/Zstd (!st.m_is_supported)
        // Windows Explorer "Compress to ZIP" uses Deflate64 on Wave Bank.xwb (~440 MB) — falling back to libarchive prevents silent missing audio/XNB (#GL-FKRBMM)!
        NSString *bestPrefix = nil;
        NSInteger bestScore = -1;
        BOOL wrapIntoContent = NO;
        for (unsigned i = 0; i < count; i++) { @autoreleasepool {
            mz_zip_archive_file_stat st;
            if (!mz_zip_reader_file_stat(&z, i, &st)) { fallbackToLibArchive = YES; break; }
            if (st.m_is_directory) continue;
            if (st.m_is_encrypted) {
                fail(@"Gói ZIP có đặt mật khẩu bảo vệ. Hãy giải nén bằng mật khẩu trước rồi chọn lại!");
            }
            unsigned n = mz_zip_reader_get_filename(&z, i, NULL, 0);
            if (n < 2 || n > 4096) continue;
            char buf[4096]; mz_zip_reader_get_filename(&z, i, buf, n);
            NSString *raw = decodeZipEntryName(buf, n - 1);
            if (!raw.length) continue;
            raw = [raw stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            if (isJunkArchiveEntry(raw)) continue;
            if (!st.m_is_supported) {
                fallbackToLibArchive = YES;
                break;
            }

            NSArray<NSString *> *parts = raw.pathComponents;
            NSString *lastLow = raw.lastPathComponent.lowercaseString;
            NSString *extLow = raw.pathExtension.lowercaseString;
            if ([lastLow isEqualToString:@"stardew valley.dll"]) {
                NSString *pref = (parts.count > 1) ? [[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, parts.count - 1)]] stringByAppendingString:@"/"] : @"";
                if (bestScore < 100 || (bestScore == 100 && pref.length < bestPrefix.length)) { bestScore = 100; bestPrefix = pref; wrapIntoContent = NO; }
            } else if ([lastLow isEqualToString:@"stardewmoddingapi.dll"]) {
                NSString *pref = (parts.count > 1) ? [[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, parts.count - 1)]] stringByAppendingString:@"/"] : @"";
                if (bestScore < 80) { bestScore = 80; bestPrefix = pref; wrapIntoContent = NO; }
            } else {
                for (NSUInteger k = 0; k + 1 < parts.count; k++) {
                    NSString *seg = parts[k].lowercaseString;
                    if ([seg isEqualToString:@"content"] || [seg isEqualToString:@"smapi-internal"]) {
                        NSInteger sc = [seg isEqualToString:@"content"] ? 90 : 70;
                        NSString *pref = (k > 0) ? [[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, k)]] stringByAppendingString:@"/"] : @"";
                        if (bestScore < sc || (bestScore == sc && pref.length < bestPrefix.length)) { bestScore = sc; bestPrefix = pref; wrapIntoContent = NO; }
                        break;
                    }
                    if (hasExistingSdv && sdvIsKnownContentSubfolder(seg) && sdvIsKnownContentAssetExt(extLow)) {
                        NSString *pref = (k > 0) ? [[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, k)]] stringByAppendingString:@"/"] : @"";
                        if (bestScore < 85 || (bestScore == 85 && pref.length < bestPrefix.length)) { bestScore = 85; bestPrefix = pref; wrapIntoContent = YES; }
                        break;
                    }
                }
            }
        }}

        if (fallbackToLibArchive) {
            return 0; // Handled right after @finally
        }
        if (bestScore < 0 || bestPrefix == nil) {
            fail(@"Gói ZIP này không chứa dữ liệu game PC (Stardew Valley.dll hoặc Content/). Nếu đây là file mod, hãy dùng nút Chọn tệp Mod!");
        }
        if (bestScore < 85) {
            fail(@"SMAPI 4.5.2 bản iOS đã tích hợp sẵn trong Garden Launcher — bạn không cần nhập gói SMAPI từ PC! Hãy chọn gói dữ liệu game PC chứa Stardew Valley.dll và thư mục Content/.");
        }

        // Pass 2: Extract cleanly into visible Documents/StardewValley/ (and Mods/ if included, skipping unused PC doc/license/runtime files!)
        uint64_t totalBytes = 0;
        mkdirs(docsPath);
        NSString *gameRoot = sdvHiddenGameDir(docsPath);
        mkdirs(join(docsPath, @"Mods"));
        mkdirs(join(docsPath, @"Saves"));
        mkdirs(join(docsPath, @"ErrorLogs"));

        // Build case-insensitive set of DLLs already shipped in SDViOS.app bundle (.NET 8 iOS runtime / MonoGame / Harmony)
        NSMutableSet<NSString *> *bundleRuntimeFiles = [NSMutableSet set];
        for (NSString *bf in ([fm() contentsOfDirectoryAtPath:NSBundle.mainBundle.bundlePath error:nil] ?: @[])) {
            if ([bf.pathExtension.lowercaseString isEqualToString:@"dll"]) {
                [bundleRuntimeFiles addObject:bf.lowercaseString];
            }
        }

        for (unsigned i = 0; i < count; i++) { @autoreleasepool {
            mz_zip_archive_file_stat st;
            if (!mz_zip_reader_file_stat(&z, i, &st) || st.m_is_directory) continue;
            if (((st.m_external_attr >> 16) & 0170000) == 0120000) continue;
            unsigned n = mz_zip_reader_get_filename(&z, i, NULL, 0);
            if (n < 2 || n > 4096) continue;
            char buf[4096]; mz_zip_reader_get_filename(&z, i, buf, n);
            NSString *raw = decodeZipEntryName(buf, n - 1);
            if (!raw.length) continue;
            raw = [raw stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            if (isJunkArchiveEntry(raw)) continue;

            NSString *rel = raw;
            if (bestPrefix.length) {
                if (![rel hasPrefix:bestPrefix]) continue;
                rel = [rel substringFromIndex:bestPrefix.length];
            }
            while ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
            if (!rel.length) continue;
            if (wrapIntoContent) rel = [@"Content/" stringByAppendingString:rel];
            rel = clean(rel);

            NSArray<NSString *> *relParts = rel.pathComponents;
            NSString *topLow = relParts.firstObject.lowercaseString;
            NSString *fileLow = rel.lastPathComponent.lowercaseString;
            NSString *extLow = rel.pathExtension.lowercaseString;

            // Protect existing user saves, bundled iOS SMAPI 4.5.2 & built-in touch controls mods
            if ([topLow isEqualToString:@"saves"]) continue;
            if ([topLow isEqualToString:@"smapi-internal"]) continue;
            if ([topLow isEqualToString:@"mods"] && relParts.count >= 2 &&
                ([relParts[1] caseInsensitiveCompare:@"SDViOSTouchControls"] == NSOrderedSame ||
                 [relParts[1] caseInsensitiveCompare:@"SDVMobileControls"] == NSOrderedSame)) continue;

            // Skip PC Windows SMAPI, unused XML/license junk, desktop native binaries & BCL DLLs already provided by SDViOS.app
            if (relParts.count == 1) {
                if ([fileLow hasPrefix:@"stardewmoddingapi"]) continue;
                if (sdvIsUnusedGameRootJunk(fileLow, extLow) || [bundleRuntimeFiles containsObject:fileLow]) continue;
            }

            // Allow large single files like Content/XACT/Wave Bank.xwb (~440 MB) up to 2 GB each / 8 GB total
            if (st.m_uncomp_size > 2ULL * 1024 * 1024 * 1024 || (totalBytes += st.m_uncomp_size) > 8ULL * 1024 * 1024 * 1024) {
                fail(@"Gói dữ liệu vượt quá giới hạn dung lượng (tối đa 2 GB/tệp, 8 GB tổng).");
            }
            NSString *targetBase = [topLow isEqualToString:@"mods"] ? docsPath : gameRoot;
            NSString *dst = inside(targetBase, rel);
            mkdirs(dst.stringByDeletingLastPathComponent);
            if ([fm() fileExistsAtPath:dst]) sdvRemoveItemQuiet(dst);
            if (!mz_zip_reader_extract_to_file(&z, i, dst.fileSystemRepresentation, 0)) {
                fallbackToLibArchive = YES;
                break;
            }
            chmod(dst.fileSystemRepresentation, 0644);
            written++;
        }}
    } @finally {
        mz_zip_reader_end(&z);
    }
    if (fallbackToLibArchive) {
        return importGameDataWithLibArchive(url, docsPath);
    }
    if (written == 0) fail(@"Không giải nén được tệp nào từ gói ZIP.");
    sdvMigrateDocumentsToHiddenLayout(docsPath);
    syncBundledLidgren(docsPath);
    syncBundledSmapi(docsPath);
    syncBundledMobileControls(docsPath);
    return written;
}
static id dictValueCI(NSDictionary *m, NSString *key) {
    if (![m isKindOfClass:NSDictionary.class] || !key.length) return nil;
    id v = m[key];
    if (v) return v;
    for (id k in m.allKeys) {
        if ([k isKindOfClass:NSString.class] && [(NSString *)k caseInsensitiveCompare:key] == NSOrderedSame) {
            return m[k];
        }
    }
    return nil;
}
static NSString *field(NSDictionary *m, NSString *key) {
    id v = dictValueCI(m, key);
    if ([v isKindOfClass:NSString.class]) return v;
    if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v stringValue];
    if ([v isKindOfClass:NSDictionary.class] && [key caseInsensitiveCompare:@"Version"] == NSOrderedSame) {
        id maj = dictValueCI(v, @"MajorVersion");
        id min = dictValueCI(v, @"MinorVersion");
        id pat = dictValueCI(v, @"PatchVersion");
        if (maj || min || pat) {
            return [NSString stringWithFormat:@"%ld.%ld.%ld",
                (long)[maj integerValue], (long)[min integerValue], (long)[pat integerValue]];
        }
    }
    return @"";
}
static NSDictionary *manifest(NSString *p) {
    id m = jsonAt(p);
    if (![m isKindOfClass:NSDictionary.class] || !field(m, @"UniqueID").length) {
        fail([@"Manifest thiếu UniqueID trong " stringByAppendingString:p.stringByDeletingLastPathComponent.lastPathComponent]);
    }
    return m;
}
static NSString *parent(NSString *p) { NSRange i=[p rangeOfString:@"/" options:NSBackwardsSearch]; return i.location==NSNotFound?@"":[p substringToIndex:i.location]; }
static NSString *below(NSString *r,NSString *base) {
    if(!base.length) return r; NSString *prefix=[base stringByAppendingString:@"/"]; return [r hasPrefix:prefix]?[r substringFromIndex:prefix.length]:nil;
}
static BOOL childScope(NSString *root) {
    return [root.lastPathComponent isEqual:@"Mods"] || [root.lastPathComponent isEqual:@"Content"];
}
static NSString *gamePath(NSString *root, NSString *relative) {
    if (!childScope(root)) {
        NSString *cr = clean(relative);
        if ([cr isEqualToString:@"Content"] || [cr hasPrefix:@"Content/"]) {
            if (dir(join(join(root, @"StardewValley"), @"Content")) && !dir(join(root, @"Content"))) {
                return inside(join(root, @"StardewValley"), cr);
            }
            if (dir(join(join(root, @".game"), @"Content")) && !dir(join(root, @"Content"))) {
                return inside(join(root, @".game"), cr);
            }
        }
        return inside(root, cr);
    }
    NSArray *parts=clean(relative).pathComponents;
    if (![parts.firstObject isEqual:root.lastPathComponent]) fail([NSString stringWithFormat:@"Gói này cần thư mục %@. Nhấn Đổi thư mục rồi chọn %@ trong Stardew Mobile.", parts.firstObject, parts.firstObject]);
    if (parts.count==1) return root;
    return inside(root,[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(1,parts.count-1)]]);
}
static BOOL isHiddenRelPath(NSString *rel) {
    for (NSString *part in rel.pathComponents) {
        if ([part hasPrefix:@"."]) return YES;
    }
    return NO;
}
__attribute__((unused)) static NSString *formatBytes(unsigned long long bytes) {
    if (bytes < 1024ULL) return [NSString stringWithFormat:@"%llu B", bytes];
    if (bytes < 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
}

// Active mods indexed by lowercase UniqueID (never crashes if a duplicate ID exists on disk)
static NSDictionary *installed(NSString *root) {
    if ([root.lastPathComponent isEqual:@"Content"]) return @{};
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSString *mods = gamePath(root, @"Mods");
    if (!dir(mods)) return d;
    for (NSString *r in modManifestFiles(mods)) {
        if (isHiddenRelPath(r)) continue;
        @try {
            NSDictionary *m = manifest(inside(mods, r));
            NSString *key = field(m, @"UniqueID").lowercaseString;
            if (key.length && !d[key]) {
                d[key] = @{@"dir": parent(r), @"manifest": m};
            }
        } @catch (NSException *ex) { }
    }
    return d;
}

// Disabled dot-prefixed mods indexed by lowercase UniqueID -> top-level ".FolderName"
static NSDictionary<NSString *, NSString *> *disabledModsById(NSString *root) {
    if ([root.lastPathComponent isEqual:@"Content"]) return @{};
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSString *mods = gamePath(root, @"Mods");
    if (!dir(mods)) return d;
    for (NSString *r in modManifestFiles(mods)) {
        NSString *top = r.pathComponents.firstObject;
        if (![top hasPrefix:@"."]) continue;
        @try {
            NSDictionary *m = manifest(inside(mods, r));
            NSString *key = field(m, @"UniqueID").lowercaseString;
            if (key.length) d[key] = top;
        } @catch (NSException *ex) { }
    }
    return d;
}

static NSArray<NSDictionary *> *modCatalog(NSString *root) {
    if (!root.length || [root.lastPathComponent isEqual:@"Content"]) return @[];
    NSString *mods = gamePath(root, @"Mods");
    if (!dir(mods)) return @[];
    NSMutableDictionary *byTopFolder = [NSMutableDictionary dictionary];
    for (NSString *r in modManifestFiles(mods)) {
        NSArray *parts = r.pathComponents;
        if (parts.count < 2) continue;
        NSString *top = parts.firstObject;
        BOOL enabled = ![top hasPrefix:@"."];
        NSString *cleanTop = enabled ? top : [top substringFromIndex:1];
        if (!cleanTop.length) continue;
        NSString *packDir = inside(mods, r).stringByDeletingLastPathComponent;
        NSString *cfgPath = join(packDir, @"config.json");
        BOOL hasCfg = ([fm() fileExistsAtPath:cfgPath] && !dir(cfgPath));
        @try {
            NSDictionary *m = manifest(inside(mods, r));
            NSString *name = field(m, @"Name");
            NSString *uid = field(m, @"UniqueID");
            NSString *ver = field(m, @"Version");
            NSString *author = field(m, @"Author");
            BOOL isSystem = [cleanTop caseInsensitiveCompare:@"SDViOSTouchControls"] == NSOrderedSame ||
                            [uid.lowercaseString containsString:@"sdviostouchcontrols"];
            NSMutableDictionary *entry = byTopFolder[top];
            if (!entry) {
                entry = [@{
                    @"topFolder": top,
                    @"cleanFolder": cleanTop,
                    @"name": name.length ? name : (uid.length ? uid : cleanTop),
                    @"uniqueID": uid,
                    @"version": ver.length ? ver : @"1.0",
                    @"author": author,
                    @"enabled": @(enabled),
                    @"protected": @(isSystem),
                    @"packCount": @(1),
                    @"hasConfig": @(hasCfg),
                    @"configPath": hasCfg ? cfgPath : @""
                } mutableCopy];
                byTopFolder[top] = entry;
            } else {
                entry[@"packCount"] = @([entry[@"packCount"] integerValue] + 1);
                if (hasCfg && ![entry[@"hasConfig"] boolValue]) {
                    entry[@"hasConfig"] = @YES;
                    entry[@"configPath"] = cfgPath;
                }
                if (parts.count == 2) {
                    entry[@"name"] = name.length ? name : entry[@"name"];
                    entry[@"version"] = ver.length ? ver : entry[@"version"];
                    entry[@"author"] = author.length ? author : entry[@"author"];
                    if (hasCfg) {
                        entry[@"hasConfig"] = @YES;
                        entry[@"configPath"] = cfgPath;
                    }
                }
            }
        } @catch (NSException *ex) {
            if (!byTopFolder[top]) {
                byTopFolder[top] = [@{
                    @"topFolder": top,
                    @"cleanFolder": cleanTop,
                    @"name": cleanTop,
                    @"uniqueID": @"",
                    @"version": @"?",
                    @"author": @"",
                    @"enabled": @(enabled),
                    @"protected": @(NO),
                    @"packCount": @(1)
                } mutableCopy];
            }
        }
    }
    NSArray *sorted = [byTopFolder.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        if ([a[@"protected"] boolValue] != [b[@"protected"] boolValue]) return [a[@"protected"] boolValue] ? NSOrderedDescending : NSOrderedAscending;
        if ([a[@"enabled"] boolValue] != [b[@"enabled"] boolValue]) return [a[@"enabled"] boolValue] ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return sorted;
}

static void toggleModEnabled(NSString *root, NSString *topFolder) {
    NSString *cleanName = [topFolder hasPrefix:@"."] ? [topFolder substringFromIndex:1] : topFolder;
    if ([cleanName caseInsensitiveCompare:@"SDViOSTouchControls"] == NSOrderedSame) fail(@"Không thể tắt mod điều khiển hệ thống.");
    NSString *mods = gamePath(root, @"Mods");
    NSString *src = inside(mods, topFolder);
    NSString *dstName = [topFolder hasPrefix:@"."] ? cleanName : [@"." stringByAppendingString:topFolder];
    NSString *dst = inside(mods, dstName);
    if ([fm() fileExistsAtPath:dst]) removeItem(dst);
    NSError *e = nil;
    BOOL ok = [fm() moveItemAtPath:src toPath:dst error:&e];
    check(ok, e);
}

static void deleteModFolder(NSString *root, NSString *topFolder) {
    NSString *cleanName = [topFolder hasPrefix:@"."] ? [topFolder substringFromIndex:1] : topFolder;
    if ([cleanName caseInsensitiveCompare:@"SDViOSTouchControls"] == NSOrderedSame) fail(@"Không thể xóa mod điều khiển hệ thống.");
    NSString *mods = gamePath(root, @"Mods");
    // Remove requested folder AND any opposite-state leftover (.Folder / Folder) so reinstalling NEVER collides!
    removeItem(inside(mods, topFolder));
    NSString *alt = [topFolder hasPrefix:@"."] ? cleanName : [@"." stringByAppendingString:cleanName];
    NSString *altPath = inside(mods, alt);
    if ([fm() fileExistsAtPath:altPath]) removeItem(altPath);
}

// Check if an existing Mods/<folder> contains an active manifest belonging to a DIFFERENT UniqueID
static BOOL folderOwnedByOtherMod(NSString *modsRoot, NSString *folder, NSString *incomingKey) {
    NSString *dirPath = join(modsRoot, folder);
    if (!dir(dirPath)) return NO;
    for (NSString *sub in files(dirPath)) {
        if (![sub.lastPathComponent.lowercaseString isEqual:@"manifest.json"]) continue;
        @try {
            NSDictionary *m = manifest(inside(dirPath, sub));
            NSString *existingKey = field(m, @"UniqueID").lowercaseString;
            if (existingKey.length && ![existingKey isEqualToString:incomingKey]) return YES;
        } @catch (NSException *ex) { }
    }
    return NO;
}

static NSString *sanitizeFolderName(NSString *raw, NSString *fallback) {
    NSString *s = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([s hasPrefix:@"."]) s = [s substringFromIndex:1];
    s = [s stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
    s = [s stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    return s.length ? s : (fallback.length ? fallback : @"Mod");
}

static BOOL sdvHasMobileEditionMarker(NSString *raw) {
    if (!raw.length) return NO;
    NSString *low = raw.lowercaseString;
    // Never false-positive on our own system mods or normal PC mods like MobilePhone / Automobile
    if ([low containsString:@"sdvmobilecontrols"] || [low containsString:@"sdviostouchcontrols"] ||
        [low containsString:@"gardenlauncher.mobilecontrols"]) return NO;
    NSArray<NSString *> *markers = @[
        @"mobile interface", @"mobile ui", @"mobile version", @"mobile ver",
        @"mobile port", @"mobile edition", @"mobile only", @"mobile-only", @"mobile_only",
        @"for mobile", @"(mobile", @"[mobile", @"bản mobile", @"ban mobile", @"cho mobile",
        @"smapi mobile", @"smapi android", @"mobileatlas",
        @"android port", @"for android", @"(android", @"[android", @"_android", @"-android", @".android",
        @"bản android", @"ban android", @"cho android", @"thai-android"
    ];
    for (NSString *mk in markers) {
        if ([low containsString:mk]) return YES;
    }
    // Check standalone word "android" (bounded by non-alphanumeric chars)
    NSRange r = [low rangeOfString:@"android"];
    while (r.location != NSNotFound) {
        BOOL leftOk = (r.location == 0) || !isalnum([low characterAtIndex:r.location - 1]);
        NSUInteger end = r.location + r.length;
        BOOL rightOk = (end >= low.length) || !isalnum([low characterAtIndex:end]);
        if (leftOk && rightOk) return YES;
        if (end >= low.length) break;
        r = [low rangeOfString:@"android" options:0 range:NSMakeRange(end, low.length - end)];
    }
    return NO;
}

static BOOL sdvDataContainsAscii(NSData *data, const char *needle) {
    if (!data.length || !needle) return NO;
    size_t nlen = strlen(needle);
    if (nlen == 0 || data.length < nlen) return NO;
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    size_t limit = MIN((size_t)data.length, (size_t)(2 * 1024 * 1024));
    if (limit < nlen) return NO;
    return memmem(bytes, limit, needle, nlen) != NULL;
}

static NSInteger sdvSemverSuffixRank(NSString *raw) {
    NSString *s = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRange plus = [s rangeOfString:@"+"];
    if (plus.location != NSNotFound) s = [s substringToIndex:plus.location];
    NSRange dash = [s rangeOfString:@"-"];
    if (dash.location == NSNotFound || dash.location + 1 >= s.length) return 0; // Clean release
    NSString *suf = [[s substringFromIndex:dash.location + 1] lowercaseString];
    if ([suf hasPrefix:@"p"] || [suf hasPrefix:@"hotfix"] || [suf hasPrefix:@"hf"]) {
        NSString *digits = [suf stringByTrimmingCharactersInSet:[NSCharacterSet.decimalDigitCharacterSet invertedSet]];
        return MAX(1, digits.integerValue); // Post-release hot-patch (e.g. -p1 > base > -rc1)
    }
    return -1; // Pre-release (-alpha, -beta, -rc) < base release
}

static NSInteger sdvCompareSemver(NSString *a, NSString *b) {
    if (!a.length && !b.length) return 0;
    if (!a.length) return -1;
    if (!b.length) return 1;
    NSString *ta = [a stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"vV \t\r\n"]];
    NSString *tb = [b stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"vV \t\r\n"]];
    NSString *ca = [[ta componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-+ "]] firstObject] ?: @"";
    NSString *cb = [[tb componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-+ "]] firstObject] ?: @"";
    NSArray<NSString *> *pa = [ca componentsSeparatedByString:@"."];
    NSArray<NSString *> *pb = [cb componentsSeparatedByString:@"."];
    NSUInteger maxParts = MAX((NSUInteger)4, MAX(pa.count, pb.count));
    if (maxParts > 6) maxParts = 6;
    for (NSUInteger i = 0; i < maxParts; i++) {
        NSInteger va = (i < pa.count) ? pa[i].integerValue : 0;
        NSInteger vb = (i < pb.count) ? pb[i].integerValue : 0;
        if (va < vb) return -1;
        if (va > vb) return 1;
    }
    NSInteger ra = sdvSemverSuffixRank(ta);
    NSInteger rb = sdvSemverSuffixRank(tb);
    if (ra < rb) return -1;
    if (ra > rb) return 1;
    return [ta localizedStandardCompare:tb];
}

static void sdvExtractCpLoadTargetsRecursive(NSString *jsonPath, NSString *packDir, NSMutableSet<NSString *> *targets, NSMutableSet<NSString *> *visited, int depth) {
    if (depth > 2 || !jsonPath.length || [visited containsObject:jsonPath]) return;
    [visited addObject:jsonPath];
    @try {
        struct stat st;
        if (stat(jsonPath.fileSystemRepresentation, &st) != 0 || st.st_size <= 0 || st.st_size > 2 * 1024 * 1024) return;
        id parsed = jsonAt(jsonPath);
        if (![parsed isKindOfClass:NSDictionary.class]) return;
        id changes = dictValueCI((NSDictionary *)parsed, @"Changes");
        if (![changes isKindOfClass:NSArray.class]) return;
        for (id item in (NSArray *)changes) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *ch = (NSDictionary *)item;
            NSString *act = field(ch, @"Action").lowercaseString;
            if ([act isEqualToString:@"include"] && packDir.length && depth < 2) {
                NSString *fromFile = field(ch, @"FromFile");
                if (!fromFile.length || [fromFile containsString:@"{{"]) continue;
                for (NSString *part in [fromFile componentsSeparatedByString:@","]) {
                    NSString *rel = [[part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                        stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
                    if (!rel.length || [rel containsString:@".."]) continue;
                    NSString *incPath = join(packDir, rel);
                    if ([fm() fileExistsAtPath:incPath]) {
                        sdvExtractCpLoadTargetsRecursive(incPath, packDir, targets, visited, depth + 1);
                    }
                }
                continue;
            }
            if (![act isEqualToString:@"load"]) continue;
            NSString *rawTarget = field(ch, @"Target");
            if (!rawTarget.length) continue;
            for (NSString *part in [rawTarget componentsSeparatedByString:@","]) {
                NSString *t = [[part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                    stringByReplacingOccurrencesOfString:@"\\" withString:@"/"].lowercaseString;
                // Skip dynamic token targets (e.g. {{Target}}) since they cannot be statically matched without runtime evaluation
                if (!t.length || [t containsString:@"{{"]) continue;
                [targets addObject:t];
            }
        }
    } @catch (NSException *ex) { }
}

static NSSet<NSString *> *sdvExtractCpLoadTargetsFromFile(NSString *contentJsonPath) {
    NSMutableSet<NSString *> *targets = [NSMutableSet set];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    NSString *packDir = contentJsonPath.stringByDeletingLastPathComponent;
    sdvExtractCpLoadTargetsRecursive(contentJsonPath, packDir, targets, visited, 0);
    return targets;
}

// Generic byte-level scan of ANY C# mod DLL + its folder to detect shared rendering/Harmony hook domains (0% hardcoded mod IDs!)
static NSSet<NSString *> *sdvExtractModHookDomains(NSString *packDir, NSString *entryDll, NSData *dllData) {
    NSMutableSet<NSString *> *domains = [NSMutableSet set];
    if (!packDir.length || !entryDll.length) return domains;

    // Detect if the mod bundles compiled shaders (.mgfxo / .xnb shader assets)
    BOOL hasShaderFiles = NO;
    @try {
        for (NSString *rel in files(packDir)) {
            NSString *low = rel.lowercaseString;
            if ([low hasSuffix:@".mgfxo"] || [low hasSuffix:@".fxc"] || [low hasSuffix:@".fx"]) {
                hasShaderFiles = YES;
                break;
            }
        }
    } @catch (NSException *ex) { }

    BOOL usesHarmony = dllData.length > 0 && (sdvDataContainsAscii(dllData, "HarmonyLib") || sdvDataContainsAscii(dllData, "0Harmony"));
    if (!usesHarmony && !hasShaderFiles) return domains;

    if (usesHarmony) {
        if (sdvDataContainsAscii(dllData, "drawWater") || sdvDataContainsAscii(dllData, "DrawWater")) {
            [domains addObject:@"water:Mặt nước (GameLocation.drawWater)"];
        }
        if (sdvDataContainsAscii(dllData, "renderScreenBuffer")) {
            [domains addObject:@"screenbuf:Hậu kỳ màn hình (Game1.renderScreenBuffer)"];
        }
        if (sdvDataContainsAscii(dllData, "DrawLighting") || sdvDataContainsAscii(dllData, "lightmap")) {
            if (hasShaderFiles || sdvDataContainsAscii(dllData, "DrawLighting")) {
                [domains addObject:@"lighting:Ánh sáng & bóng đổ (Game1.DrawLighting)"];
            }
        }
        if (sdvDataContainsAscii(dllData, "BobberBar") && (sdvDataContainsAscii(dllData, "Postfix") || sdvDataContainsAscii(dllData, "Prefix") || sdvDataContainsAscii(dllData, "Transpiler"))) {
            [domains addObject:@"fishing:Minigame câu cá (BobberBar)"];
        }
    }
    if (hasShaderFiles) {
        [domains addObject:@"shader:Hiệu ứng Shader tùy chỉnh (.mgfxo)"];
    }
    return domains;
}

static NSDictionary<NSString *, NSSet<NSString *> *> *sdvCollectInstalledCpLoadTargets(NSString *root) {
    NSMutableDictionary<NSString *, NSSet<NSString *> *> *res = [NSMutableDictionary dictionary];
    if (!root.length || [root.lastPathComponent isEqual:@"Content"]) return res;
    NSString *mods = gamePath(root, @"Mods");
    if (!dir(mods)) return res;
    for (NSString *r in modManifestFiles(mods)) { @autoreleasepool {
        if (isHiddenRelPath(r)) continue;
        @try {
            NSDictionary *m = manifest(inside(mods, r));
            NSString *uidLow = field(m, @"UniqueID").lowercaseString;
            if (!uidLow.length) continue;
            id cpf = dictValueCI(m, @"ContentPackFor");
            if (![cpf isKindOfClass:NSDictionary.class]) continue;
            if ([field(cpf, @"UniqueID") caseInsensitiveCompare:@"Pathoschild.ContentPatcher"] != NSOrderedSame) continue;
            NSString *packDir = inside(mods, r).stringByDeletingLastPathComponent;
            NSString *cj = join(packDir, @"content.json");
            if ([fm() fileExistsAtPath:cj]) {
                NSSet<NSString *> *lt = sdvExtractCpLoadTargetsFromFile(cj);
                if (lt.count) res[uidLow] = lt;
            }
        } @catch (NSException *ex) { }
    }}
    return res;
}

static NSString *sdvTranslateSmapiSkipReason(NSString *reason) {
    NSString *low = reason.lowercaseString;
    if ([low containsString:@"no longer compatible"]) return @"không còn tương thích Stardew Valley 1.6.15 (cần bản cập nhật mới hoặc xóa bớt).";
    if ([low containsString:@"none of them are manifest.json"]) return @"chứa tệp nhưng thiếu manifest.json (thư mục rác/cài thiếu).";
    if ([low containsString:@"empty folder"]) return @"thư mục trống không có dữ liệu mod.";
    if ([low containsString:@"requires mods which aren't installed"]) return [NSString stringWithFormat:@"thiếu mod phụ thuộc (%@).", reason];
    if ([low containsString:@"multiple copies"]) return @"cài trùng nhiều bản sao cùng lúc.";
    if ([low containsString:@"couldn't be loaded"]) return [NSString stringWithFormat:@"lỗi nạp tệp DLL (%@).", reason];
    return reason;
}

// Comprehensive local Mod Health & Conflict Diagnostics (static + live SMAPI-latest.txt, 0% network, <20ms)
static NSArray<NSDictionary *> *sdvDiagnoseMods(NSString *root) {
    NSMutableArray<NSDictionary *> *issues = [NSMutableArray array];
    if (!root.length || [root.lastPathComponent isEqual:@"Content"]) return issues;
    NSString *mods = gamePath(root, @"Mods");
    if (!dir(mods)) return issues;

    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];
    void (^addIssue)(NSString *, NSString *, NSString *, NSString *, NSString *) =
    ^(NSString *dedupKey, NSString *sev, NSString *title, NSString *detail, NSString *orphanFolder) {
        if (!dedupKey.length || [seenKeys containsObject:dedupKey]) return;
        [seenKeys addObject:dedupKey];
        NSMutableDictionary *d = [@{@"severity": sev ?: @"warn", @"title": title ?: @"", @"detail": detail ?: @""} mutableCopy];
        if (orphanFolder.length) d[@"orphanFolder"] = orphanFolder;
        [issues addObject:d];
    };

    // 1. Scan active mods, detect duplicate UniqueIDs, orphan folders, legacy DLLs, Mobile mods, CP Load targets & C# hook domains
    NSMutableDictionary<NSString *, NSDictionary *> *activeById = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *idFolders = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSSet<NSString *> *> *cpLoads = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDictionary *> *portraitPacks = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSSet<NSString *> *> *modHookDomains = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *topWithManifest = [NSMutableSet set];
    NSDictionary<NSString *, NSString *> *disabledMap = disabledModsById(root);
    NSSet<NSString *> *sysIds = [NSSet setWithArray:@[@"com.deadakj.sdviostouchcontrols", @"gardenlauncher.mobilecontrols"]];

    for (NSString *r in modManifestFiles(mods)) { @autoreleasepool {
        if (isHiddenRelPath(r)) continue;
        NSString *top = r.pathComponents.firstObject;
        if (top.length) [topWithManifest addObject:top];
        NSDictionary *m = nil;
        @try {
            m = manifest(inside(mods, r));
        } @catch (NSException *ex) {
            addIssue([@"badmf:" stringByAppendingString:r], @"error",
                [NSString stringWithFormat:@"Lỗi manifest.json: %@", top ?: r],
                ex.reason ?: @"Tệp manifest.json bị sai cú pháp JSON.", nil);
            continue;
        }
        NSString *uid = field(m, @"UniqueID");
        NSString *uidLow = uid.lowercaseString;
        if (!uidLow.length) continue;
        NSString *dispName = field(m, @"Name").length ? field(m, @"Name") : uid;
        NSString *packDir = inside(mods, r).stringByDeletingLastPathComponent;

        if (!idFolders[uidLow]) idFolders[uidLow] = [NSMutableArray array];
        [idFolders[uidLow] addObject:(top ?: r)];
        if (!activeById[uidLow]) {
            activeById[uidLow] = @{@"m": m, @"name": dispName, @"top": top ?: @"", @"dir": packDir};
        }

        if (![sysIds containsObject:uidLow]) {
            NSString *minApi = field(m, @"MinimumApiVersion");
            NSString *entryDll = field(m, @"EntryDll");
            if (minApi.length && sdvCompareSemver(minApi, @"4.5.2") > 0) {
                addIssue([@"api:" stringByAppendingString:uidLow], @"error",
                    [NSString stringWithFormat:@"Cần SMAPI mới hơn: %@", dispName],
                    [NSString stringWithFormat:@"Yêu cầu SMAPI v%@ (Garden Launcher hiện dùng 4.5.2).", minApi], nil);
            } else if (entryDll.length && minApi.length && sdvCompareSemver(minApi, @"3.99.0") < 0) {
                addIssue([@"legacy:" stringByAppendingString:uidLow], @"warn",
                    [NSString stringWithFormat:@"Mod C# đời cũ (1.5): %@", dispName],
                    [NSString stringWithFormat:@"Biên dịch cho SMAPI %@ — có thể không tương thích Stardew 1.6.15.", minApi], nil);
            }
            if (entryDll.length) {
                if ([uidLow containsString:@"portraiture"] || [uidLow containsString:@"hdportraits"] || [uidLow containsString:@"hd.portraits"]) {
                    addIssue([@"harmonyportrait:" stringByAppendingString:uidLow], @"warn",
                        [NSString stringWithFormat:@"Mod chân dung cần Harmony/JIT: %@", dispName],
                        @"Trên iOS 0% JIT (không bật Harmony), Portraiture / HD Portraits không thể móc nối vẽ chân dung. Hãy dùng gói chân dung dạng Content Patcher ([CP]) chuẩn (như [CP] OhoDavi Anime).", nil);
                }
                NSString *dllFull = join(packDir, entryDll);
                if (![fm() fileExistsAtPath:dllFull]) {
                    addIssue([@"missdll:" stringByAppendingString:uidLow], @"error",
                        [NSString stringWithFormat:@"Thiếu tệp DLL: %@", dispName],
                        [NSString stringWithFormat:@"manifest.json khai báo %@ nhưng không tìm thấy tệp trong thư mục mod (có thể giải nén thiếu hoặc nhầm mã nguồn).", entryDll], nil);
                } else {
                    NSData *dd = [NSData dataWithContentsOfFile:dllFull options:NSDataReadingMappedIfSafe error:nil];
                    if (sdvDataContainsAscii(dd, "Mono.Android") || sdvDataContainsAscii(dd, "SMAPI.Android")) {
                        addIssue([@"androiddll:" stringByAppendingString:uidLow], @"error",
                            [NSString stringWithFormat:@"Mod biên dịch riêng Android: %@", dispName],
                            [NSString stringWithFormat:@"%@ dùng SMAPI Android, có thể lỗi trên bản PC 1.6.15 — khuyên tải bản PC.", entryDll], nil);
                    }
                    // Inform users when an active C# mod relies on 0Harmony runtime IL patching (which is a safe no-op on 0% JIT iOS)
                    BOOL isSafeHarmonyUser = [uidLow hasPrefix:@"pathoschild.contentpatcher"] ||
                                             [uidLow hasPrefix:@"spacechase0.genericmodconfigmenu"] ||
                                             [uidLow hasPrefix:@"smapi."] ||
                                             [uidLow containsString:@"portraiture"] ||
                                             [uidLow containsString:@"hdportraits"] ||
                                             [uidLow containsString:@"hd.portraits"] ||
                                             [uidLow isEqualToString:@"digus.mailframeworkmod"];
                    if (!isSafeHarmonyUser && (sdvDataContainsAscii(dd, "0Harmony") || sdvDataContainsAscii(dd, "HarmonyLib"))) {
                        addIssue([@"harmony0jit:" stringByAppendingString:uidLow], @"warn",
                            [NSString stringWithFormat:@"Mod C# dùng Harmony (0%% JIT): %@", dispName],
                            @"Trên iOS không bật JIT, các móc nối Harmony C# (như Visible Fish, Alternative Textures, More Grass…) tự bỏ qua để tránh văng game; chỉ phần sự kiện SMAPI & gói Content Patcher ([CP]) hoạt động.", nil);
                    }
                    NSSet<NSString *> *doms = sdvExtractModHookDomains(packDir, entryDll, dd);
                    if (doms.count) modHookDomains[uidLow] = doms;
                }
            }
            if (sdvHasMobileEditionMarker(dispName) || sdvHasMobileEditionMarker(uid) ||
                sdvHasMobileEditionMarker(field(m, @"Description")) || sdvHasMobileEditionMarker(top)) {
                addIssue([@"mobile:" stringByAppendingString:uidLow], @"warn",
                    [NSString stringWithFormat:@"Mod bản Mobile/Android: %@", dispName],
                    @"Được đánh dấu dành cho bản Mobile — có thể lệch giao diện hoặc lỗi nhỏ trên lõi PC 1.6.15.", nil);
            }
            id cpf = dictValueCI(m, @"ContentPackFor");
            if ([cpf isKindOfClass:NSDictionary.class] &&
                [field(cpf, @"UniqueID") caseInsensitiveCompare:@"Pathoschild.ContentPatcher"] == NSOrderedSame) {
                NSString *cj = join(packDir, @"content.json");
                if ([fm() fileExistsAtPath:cj]) {
                    NSSet<NSString *> *lt = sdvExtractCpLoadTargetsFromFile(cj);
                    if (lt.count) cpLoads[uidLow] = lt;
                    NSData *cjd = [NSData dataWithContentsOfFile:cj options:NSDataReadingMappedIfSafe error:nil];
                    if (sdvDataContainsAscii(cjd, "MobileAtlas") || sdvDataContainsAscii(cjd, "mobileatlas")) {
                        addIssue([@"mobileatlas:" stringByAppendingString:uidLow], @"warn",
                            [NSString stringWithFormat:@"Content Pack bản Mobile: %@", dispName],
                            @"Chỉnh sửa tài nguyên MobileAtlas riêng của bản Mobile — khuyên tải bản PC 1.6.", nil);
                    }
                    // Detect villager Portrait packs (EditImage/Load on Portraits/* or Seasonal Cute Characters Data/Characters redirect)
                    NSString *metaLow = [[NSString stringWithFormat:@"%@ %@ %@", dispName, uid, field(m, @"Description")] lowercaseString];
                    BOOL editsPortraits = sdvDataContainsAscii(cjd, "Portraits/") || sdvDataContainsAscii(cjd, "portraits/");
                    BOOL isSeasonalChar = [uidLow containsString:@"seasonalcutecharacters"] ||
                                          ([metaLow containsString:@"seasonal"] && [metaLow containsString:@"character"]) ||
                                          (sdvDataContainsAscii(cjd, "Data/Characters") && ([metaLow containsString:@"outfit"] || [metaLow containsString:@"portrait"] || [metaLow containsString:@"seasonal"]));
                    BOOL isPortraitPack = isSeasonalChar ||
                                          (editsPortraits && ([metaLow containsString:@"portrait"] || [metaLow containsString:@"anime"] || [metaLow containsString:@"ohodavi"] || [metaLow containsString:@"chân dung"] || [metaLow containsString:@"dcburger"] || [metaLow containsString:@"character"] || sdvDataContainsAscii(cjd, "Portraits/Abigail")));
                    if (isPortraitPack) {
                        portraitPacks[uidLow] = @{@"name": dispName, @"seasonal": @(isSeasonalChar)};
                    }
                }
            }
        }
    }}

    // 2. Duplicate UniqueIDs
    for (NSString *uidLow in idFolders) {
        NSArray<NSString *> *flist = idFolders[uidLow];
        if (flist.count > 1) {
            NSString *nm = activeById[uidLow][@"name"] ?: uidLow;
            addIssue([@"dup:" stringByAppendingString:uidLow], @"error",
                [NSString stringWithFormat:@"Cài trùng %lu bản: %@", (unsigned long)flist.count, nm],
                [NSString stringWithFormat:@"Cùng UniqueID ở thư mục: %@. SMAPI sẽ bỏ qua cả hai — hãy xóa bớt 1 bản.", [flist componentsJoinedByString:@", "]], nil);
        }
    }

    // 3. Orphan / broken top-level folders inside Mods/ (no manifest.json anywhere inside)
    NSArray<NSString *> *topItems = [fm() contentsOfDirectoryAtPath:mods error:nil] ?: @[];
    for (NSString *entry in topItems) {
        if ([entry hasPrefix:@"."]) continue;
        NSString *full = join(mods, entry);
        if (!dir(full)) continue;
        if ([topWithManifest containsObject:entry]) continue;
        BOOL hasDisabledTwin = dir(join(mods, [@"." stringByAppendingString:entry]));
        NSString *detail = hasDisabledTwin
            ? [NSString stringWithFormat:@"Thư mục Mods/%@ còn sót tệp (thiếu manifest.json) bên cạnh bản đã tắt .%@ khiến SMAPI báo lỗi đỏ khi mở game.", entry, entry]
            : [NSString stringWithFormat:@"Thư mục Mods/%@ không chứa manifest.json nên SMAPI không thể nạp.", entry];
        addIssue([@"orphan:" stringByAppendingString:entry.lowercaseString], @"warn",
            [NSString stringWithFormat:@"Thư mục lỗi: %@", entry], detail, entry);
    }

    // 4. Missing / Disabled dependencies & MinimumVersion mismatch across active mods
    for (NSString *uidLow in activeById) {
        NSDictionary *info = activeById[uidLow];
        NSDictionary *m = info[@"m"];
        NSString *dispName = info[@"name"];
        NSMutableArray *deps = [NSMutableArray array];
        id rawDeps = dictValueCI(m, @"Dependencies");
        id rawCp = dictValueCI(m, @"ContentPackFor");
        if ([rawDeps isKindOfClass:NSArray.class]) [deps addObjectsFromArray:rawDeps];
        if ([rawCp isKindOfClass:NSDictionary.class]) [deps addObject:rawCp];
        for (id dep in deps) {
            if (![dep isKindOfClass:NSDictionary.class]) continue;
            NSString *depId = field(dep, @"UniqueID");
            NSString *depLow = depId.lowercaseString;
            id req = dictValueCI(dep, @"IsRequired");
            if (!depLow.length || [req isEqual:@NO]) continue;
            if (!activeById[depLow]) {
                if (disabledMap[depLow]) {
                    addIssue([NSString stringWithFormat:@"disdep:%@:%@", uidLow, depLow], @"error",
                        [NSString stringWithFormat:@"%@: thiếu mod đang bị tắt", dispName],
                        [NSString stringWithFormat:@"Cần %@ (hiện đang tắt ở .%@) — hãy bật lại trong Thư viện.", depId, disabledMap[depLow]], nil);
                } else {
                    addIssue([NSString stringWithFormat:@"missdep:%@:%@", uidLow, depLow], @"error",
                        [NSString stringWithFormat:@"%@: thiếu mod phụ thuộc", dispName],
                        [NSString stringWithFormat:@"Cần cài thêm %@ để mod hoạt động.", depId], nil);
                }
            } else {
                NSString *minV = field(dep, @"MinimumVersion");
                NSString *instV = field(activeById[depLow][@"m"], @"Version");
                if (minV.length && instV.length && sdvCompareSemver(instV, minV) < 0) {
                    addIssue([NSString stringWithFormat:@"olddep:%@:%@", uidLow, depLow], @"error",
                        [NSString stringWithFormat:@"%@: phụ thuộc quá cũ", dispName],
                        [NSString stringWithFormat:@"Yêu cầu %@ ≥ v%@ (hiện đang cài v%@).", depId, minV, instV], nil);
                }
            }
        }
    }

    // 5. Content Patcher Action:Load conflicts between active packs
    NSArray<NSString *> *cpKeys = [cpLoads.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; i < cpKeys.count; i++) {
        for (NSUInteger j = i + 1; j < cpKeys.count; j++) {
            NSString *k1 = cpKeys[i], *k2 = cpKeys[j];
            NSSet<NSString *> *s1 = cpLoads[k1], *s2 = cpLoads[k2];
            NSMutableArray<NSString *> *overlap = [NSMutableArray array];
            for (NSString *t in s1) {
                if ([s2 containsObject:t]) [overlap addObject:t];
            }
            if (overlap.count) {
                [overlap sortUsingSelector:@selector(compare:)];
                NSString *n1 = activeById[k1][@"name"] ?: k1;
                NSString *n2 = activeById[k2][@"name"] ?: k2;
                NSString *sample = (overlap.count > 2)
                    ? [NSString stringWithFormat:@"%@, %@ (+%lu mục)", overlap[0], overlap[1], (unsigned long)(overlap.count - 2)]
                    : [overlap componentsJoinedByString:@", "];
                addIssue([NSString stringWithFormat:@"cpconf:%@:%@", k1, k2], @"warn",
                    [NSString stringWithFormat:@"Xung đột ghi đè: %@ ↔ %@", n1, n2],
                    [NSString stringWithFormat:@"Cả 2 cùng dùng Action: Load cho %@ — chỉ 1 mod có hiệu lực, nên tắt bớt 1 mod.", sample], nil);
            }
        }
    }

    // 5b. Generic C# Harmony / Shader / Rendering pipeline conflict detection across ALL active mods (0% hardcoded mod IDs!)
    NSArray<NSString *> *hookModKeys = [modHookDomains.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; i < hookModKeys.count; i++) {
        for (NSUInteger j = i + 1; j < hookModKeys.count; j++) {
            NSString *k1 = hookModKeys[i], *k2 = hookModKeys[j];
            NSSet<NSString *> *d1 = modHookDomains[k1], *d2 = modHookDomains[k2];
            NSMutableArray<NSString *> *sharedLabels = [NSMutableArray array];
            for (NSString *dom in d1) {
                if ([d2 containsObject:dom]) {
                    NSRange sep = [dom rangeOfString:@":"];
                    NSString *label = (sep.location != NSNotFound) ? [dom substringFromIndex:sep.location + 1] : dom;
                    [sharedLabels addObject:label];
                }
            }
            if (sharedLabels.count) {
                [sharedLabels sortUsingSelector:@selector(compare:)];
                NSString *n1 = activeById[k1][@"name"] ?: k1;
                NSString *n2 = activeById[k2][@"name"] ?: k2;
                addIssue([NSString stringWithFormat:@"hookconf:%@:%@", k1, k2], @"warn",
                    [NSString stringWithFormat:@"Có thể xung đột hiển thị/hook: %@ ↔ %@", n1, n2],
                    [NSString stringWithFormat:@"Cả 2 mod C# cùng can thiệp vào %@. Nếu bị mất hiệu ứng hoặc lỗi hình ảnh, hãy thử tắt bớt 1 trong 2 mod.", [sharedLabels componentsJoinedByString:@", "]], nil);
            }
        }
    }

    // 5c. Villager Portrait / Anime Pack conflict detection (e.g. Seasonal Cute Characters overrides OhoDavi Anime Portraits!)
    if (portraitPacks.count >= 2) {
        NSArray<NSString *> *pKeys = [portraitPacks.allKeys sortedArrayUsingSelector:@selector(compare:)];
        for (NSUInteger i = 0; i < pKeys.count; i++) {
            for (NSUInteger j = i + 1; j < pKeys.count; j++) {
                NSDictionary *p1 = portraitPacks[pKeys[i]];
                NSDictionary *p2 = portraitPacks[pKeys[j]];
                BOOL hasSeasonal = [p1[@"seasonal"] boolValue] || [p2[@"seasonal"] boolValue];
                NSString *detail = hasSeasonal
                    ? @"Gói trang phục theo mùa (như Seasonal Cute Characters) đổi đường dẫn trong Data/Characters sang Portraits/*_Spring/_Summer… nên sẽ ĐÈ HOÀN TOÀN ảnh Anime/Portrait của gói còn lại! Hãy tắt bớt 1 gói trong Thư viện rồi khởi động lại game."
                    : @"Cả 2 gói đều chỉnh sửa Portraits/* của dân làng nên sẽ đè lên nhau — chỉ 1 gói hiện đầy đủ. Hãy tắt bớt 1 gói trong Thư viện.";
                addIssue([NSString stringWithFormat:@"portraitconf:%@:%@", pKeys[i], pKeys[j]], @"warn",
                    [NSString stringWithFormat:@"Xung đột chân dung (Portrait): %@ ↔ %@", p1[@"name"], p2[@"name"]],
                    detail, nil);
            }
        }
    }

    // 6. Live SMAPI-latest.txt Skipped mods & runtime ERROR parser (ground truth from last launch for ALL mods)
    NSString *smapiLog = join(join(root, @"ErrorLogs"), @"SMAPI-latest.txt");
    @try {
        struct stat st;
        if (stat(smapiLog.fileSystemRepresentation, &st) == 0 && st.st_size > 0 && st.st_size <= 2 * 1024 * 1024) {
            NSString *txt = [NSString stringWithContentsOfFile:smapiLog encoding:NSUTF8StringEncoding error:nil];
            if (txt.length) {
                BOOL inSkipped = NO;
                NSUInteger errLinesAdded = 0;
                for (NSString *rawLine in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                    NSString *line = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (!line.length) { inSkipped = NO; continue; }
                    if ([line containsString:@"ERROR SMAPI]    Skipped mods"] ||
                        [line containsString:@"ERROR SMAPI]    These mods could not be added"]) {
                        inSkipped = YES;
                        continue;
                    }
                    if (inSkipped) {
                        if (![line containsString:@"ERROR SMAPI]"]) { inSkipped = NO; continue; }
                        NSRange dashR = [line rangeOfString:@"   - "];
                        if (dashR.location != NSNotFound) {
                            NSString *entry = [line substringFromIndex:dashR.location + dashR.length];
                            NSRange becR = [entry rangeOfString:@" because "];
                            NSString *modTitle = (becR.location != NSNotFound) ? [entry substringToIndex:becR.location] : entry;
                            NSString *reason = (becR.location != NSNotFound) ? [entry substringFromIndex:becR.location + becR.length] : @"không thể nạp.";
                            // Skip if already reported as orphan folder
                            NSString *orphanKey = [@"orphan:" stringByAppendingString:modTitle.lowercaseString];
                            if ([seenKeys containsObject:orphanKey]) continue;
                            addIssue([@"skip:" stringByAppendingString:modTitle.lowercaseString], @"error",
                                [NSString stringWithFormat:@"SMAPI bỏ qua: %@", modTitle],
                                sdvTranslateSmapiSkipReason(reason), nil);
                        }
                    } else if (errLinesAdded < 12 && [line containsString:@" ERROR "] && ![line containsString:@"ERROR SMAPI]"]) {
                        // Extract mod name & concise error snippet from runtime mod errors
                        NSRange errR = [line rangeOfString:@" ERROR "];
                        if (errR.location != NSNotFound) {
                            NSString *after = [line substringFromIndex:errR.location + errR.length];
                            NSRange brR = [after rangeOfString:@"] "];
                            if (brR.location != NSNotFound) {
                                NSString *modSrc = [[after substringToIndex:brR.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                                NSString *msg = [after substringFromIndex:brR.location + brR.length];
                                if (msg.length > 180) msg = [[msg substringToIndex:180] stringByAppendingString:@"…"];
                                addIssue([NSString stringWithFormat:@"rt:%@", modSrc.lowercaseString], @"error",
                                    [NSString stringWithFormat:@"Lỗi khi chạy: %@", modSrc], msg, nil);
                                errLinesAdded++;
                            }
                        }
                    }
                }
            }
        }
    } @catch (NSException *ex) { }

    // 7. Optional OTA Live Compatibility Rules (.garden/extra_mod_rules.json)
    NSString *extraRulesPath = join(sdvHiddenGardenDir(root), @"extra_mod_rules.json");
    if ([fm() fileExistsAtPath:extraRulesPath] && !dir(extraRulesPath)) {
        @try {
            id rulesObj = jsonAt(extraRulesPath);
            NSArray *rulesArr = [rulesObj isKindOfClass:NSArray.class] ? (NSArray *)rulesObj
                : ([rulesObj isKindOfClass:NSDictionary.class] && [rulesObj[@"rules"] isKindOfClass:NSArray.class] ? rulesObj[@"rules"] : nil);
            for (NSDictionary *rl in rulesArr) {
                if (![rl isKindOfClass:NSDictionary.class]) continue;
                NSString *ruid = [field(rl, @"uid") lowercaseString];
                if (!ruid.length) ruid = [field(rl, @"uniqueID") lowercaseString];
                if (!ruid.length || !activeById[ruid]) continue;
                NSString *sev = [field(rl, @"severity").lowercaseString isEqualToString:@"error"] ? @"error" : @"warn";
                NSString *rTitle = field(rl, @"title");
                NSString *rDetail = field(rl, @"detail");
                if (!rTitle.length) rTitle = [NSString stringWithFormat:@"Cảnh báo tương thích: %@", activeById[ruid][@"name"] ?: ruid];
                if (rDetail.length) {
                    addIssue([@"otarule:" stringByAppendingString:ruid], sev, rTitle, rDetail, nil);
                }
            }
        } @catch (NSException *ignored) { }
    }

    // Sort errors first, then warnings
    [issues sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL ea = [a[@"severity"] isEqualToString:@"error"];
        BOOL eb = [b[@"severity"] isEqualToString:@"error"];
        if (ea != eb) return ea ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"title"] compare:b[@"title"]];
    }];
    return issues;
}

// Canonicalizes a relative path under Content/ (e.g. "portraits/abigail.xnb" -> "Portraits/Abigail.xnb") against existing StardewValley/Content on APFS
static NSString *sdvCanonicalizeContentSubpath(NSString *root, NSString *subRel) {
    if (!root.length || !subRel.length) return subRel;
    NSString *contentRoot = nil;
    @try { contentRoot = gamePath(root, @"Content"); } @catch (NSException *ex) { return subRel; }
    if (!contentRoot.length || !dir(contentRoot)) return subRel;

    NSArray<NSString *> *parts = [clean(subRel) componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *resolved = [NSMutableArray arrayWithCapacity:parts.count];
    NSString *curDisk = contentRoot;
    BOOL walkValid = YES;
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *seg = parts[i];
        if (!walkValid || !dir(curDisk)) {
            [resolved addObject:seg];
            continue;
        }
        NSString *exactMatch = nil;
        NSString *ciMatch = nil;
        for (NSString *cand in ([fm() contentsOfDirectoryAtPath:curDisk error:nil] ?: @[])) {
            if ([cand isEqualToString:seg]) { exactMatch = cand; break; }
            if (!ciMatch && [cand caseInsensitiveCompare:seg] == NSOrderedSame) ciMatch = cand;
        }
        NSString *chosen = exactMatch ?: (ciMatch ?: seg);
        [resolved addObject:chosen];
        NSString *nextDisk = join(curDisk, chosen);
        if (!exactMatch && !ciMatch) walkValid = NO;
        curDisk = nextDisk;
    }
    return [resolved componentsJoinedByString:@"/"];
}

// 1-tap APFS Case-Sensitivity Healer across installed Mods/ and StardewValley/Content/
static NSDictionary *sdvHealInstalledCaseSensitivity(NSString *root) {
    if (!root.length) return @{@"fixedJson": @0, @"fixedDll": @0, @"fixedContent": @0};
    NSString *mods = [root.lastPathComponent isEqual:@"Content"] ? nil : gamePath(root, @"Mods");
    NSDictionary *modRes = (mods.length && dir(mods)) ? sdvHealModTreeCaseSensitivity(mods) : @{@"fixedJson": @0, @"fixedDll": @0};

    NSUInteger fixedContent = 0;
    NSString *contentDir = nil;
    @try { contentDir = gamePath(root, @"Content"); } @catch (NSException *ex) { contentDir = nil; }
    if (contentDir.length && dir(contentDir)) {
        NSArray<NSString *> *canonicalTopDirs = @[
            @"Animals", @"Buildings", @"Characters", @"Data", @"Effects", @"Fonts",
            @"LooseSprites", @"Maps", @"Minigames", @"Portraits", @"Strings",
            @"TerrainFeatures", @"TileSheets", @"VolcanoLayouts", @"XACT"
        ];
        NSDictionary<NSString *, NSString *> *canonByLow = ({
            NSMutableDictionary *d = [NSMutableDictionary dictionary];
            for (NSString *c in canonicalTopDirs) d[c.lowercaseString] = c;
            d;
        });
        for (NSString *entry in ([fm() contentsOfDirectoryAtPath:contentDir error:nil] ?: @[])) {
            NSString *canon = canonByLow[entry.lowercaseString];
            if (!canon || [entry isEqualToString:canon]) continue;
            NSString *wrongDir = join(contentDir, entry);
            NSString *rightDir = join(contentDir, canon);
            if (!dir(wrongDir)) continue;
            if (![fm() fileExistsAtPath:rightDir]) {
                if (sdvSafeCaseRenameInDir(contentDir, entry, canon)) fixedContent++;
            } else if (dir(rightDir)) {
                // Merge mis-cased files from wrongDir into canonical rightDir (matching existing file casing inside rightDir)
                for (NSString *subRel in files(wrongDir)) {
                    NSString *canonSub = sdvCanonicalizeContentSubpath(root, join(canon, subRel));
                    NSString *srcF = join(wrongDir, subRel);
                    NSString *dstF = join(contentDir, canonSub);
                    NSData *d = [NSData dataWithContentsOfFile:srcF options:NSDataReadingMappedIfSafe error:nil];
                    if (d.length) {
                        writeFile(d, dstF);
                        fixedContent++;
                    }
                }
                sdvRemoveItemQuiet(wrongDir);
            }
        }
    }
    return @{
        @"fixedJson": modRes[@"fixedJson"] ?: @0,
        @"fixedDll": modRes[@"fixedDll"] ?: @0,
        @"fixedContent": @(fixedContent)
    };
}

// Plan installing ONE OR MULTIPLE staged packages inside `stage` (each package unpacked into `stage/pkg_<i>/...`)
static NSDictionary *plan(NSString *root, NSString *stage, NSArray *preferences, NSDictionary *translations, NSArray<NSString *> *stagedFileNames) {
    // Auto-heal Windows/macOS case mismatches in staging BEFORE scanning manifests, DLLs & i18n!
    sdvHealModTreeCaseSensitivity(stage);
    NSArray *items = files(stage);
    NSDictionary *library = installed(root);
    NSDictionary<NSString *, NSString *> *disabledMap = disabledModsById(root);
    NSMutableDictionary *combinedLibrary = [library mutableCopy];
    NSMutableDictionary *incoming = [NSMutableDictionary dictionary];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSMutableSet *ids = [NSMutableSet set];
    NSMutableSet *claimedFolders = [NSMutableSet set];
    NSMutableSet *warnings = [NSMutableSet set];
    NSMutableArray<NSString *> *mobileWarnings = [NSMutableArray array];
    NSMutableSet<NSString *> *mobileWarnSeen = [NSMutableSet set];
    void (^addMobileWarn)(NSString *) = ^(NSString *msg) {
        if (!msg.length || [mobileWarnSeen containsObject:msg]) return;
        [mobileWarnSeen addObject:msg];
        [mobileWarnings addObject:msg];
    };
    NSMutableSet *obsoleteDisabled = [NSMutableSet set];
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *choices = [NSMutableArray array];
    NSString *translationOwner = nil;
    NSString *modsRoot = [root.lastPathComponent isEqual:@"Content"] ? nil : gamePath(root, @"Mods");

    // Check staged archive / folder filenames for Mobile / Android edition markers
    for (NSString *sf in stagedFileNames) {
        if (sdvHasMobileEditionMarker(sf)) {
            addMobileWarn([NSString stringWithFormat:@"Tệp nguồn \"%@\" có tên dành cho bản Mobile/Android.", sf]);
        }
    }

    void (^add)(NSString *, NSString *) = ^(NSString *dst, NSString *src) {
        gamePath(root, dst);
        // Safely overwrite if a later package in the same batch overrides an earlier destination (e.g., i18n patch over base mod)
        out[dst] = src;
    };

    // Pass 1: Discover all SMAPI mods (manifest.json) across all staged packages
    NSMutableArray<NSString *> *badManifests = [NSMutableArray array];
    NSMutableArray<NSString *> *skippedBases = [NSMutableArray array];
    for (NSString *r in items) {
        if (![r.lastPathComponent.lowercaseString isEqual:@"manifest.json"]) continue;
        NSDictionary *m = nil;
        @try {
            m = manifest(inside(stage, r));
        } @catch (NSException *ex) {
            [badManifests addObject:(ex.reason ?: r)];
            continue;
        }
        NSString *uid = field(m, @"UniqueID");
        NSString *key = uid.lowercaseString;
        NSString *base = parent(r);
        if ([ids containsObject:key]) {
            // User selected a duplicate copy / variant of the same mod -> claim its base so variant files never leak into Pass 3b!
            if (base.length) [skippedBases addObject:base];
            continue;
        }
        [ids addObject:key];

        // If a disabled ".Folder" copy of this mod exists, mark it for clean removal on install
        if (disabledMap[key]) {
            [obsoleteDisabled addObject:disabledMap[key]];
        }

        // Determine destination folder cleanly (NEVER fails on leftover/deleted folders!)
        NSString *folder = library[key][@"dir"];
        if (!folder.length) {
            // Extract leaf folder name inside the package (ignoring synthetic pkg_NNN wrapper if manifest is at pkg root)
            NSArray *bParts = base.length ? base.pathComponents : @[];
            NSString *candidate = (bParts.count >= 2) ? bParts.lastObject : uid;
            folder = sanitizeFolderName(candidate, sanitizeFolderName(uid, @"Mod"));
            if (modsRoot && (folderOwnedByOtherMod(modsRoot, folder, key) || [claimedFolders containsObject:folder.lowercaseString])) {
                NSString *alt = sanitizeFolderName(uid, folder);
                NSString *tryName = alt;
                int n = 2;
                while ((folderOwnedByOtherMod(modsRoot, tryName, key) || [claimedFolders containsObject:tryName.lowercaseString]) && n < 100) {
                    tryName = [NSString stringWithFormat:@"%@_%d", alt, n++];
                }
                folder = tryName;
            }
        }
        [claimedFolders addObject:folder.lowercaseString];
        incoming[base] = @{@"dest": join(@"Mods", folder), @"m": m, @"folder": folder};
        combinedLibrary[key] = @{@"dir": folder, @"manifest": m};
        NSString *dispName = field(m, @"Name").length ? field(m, @"Name") : uid;
        [names addObject:[NSString stringWithFormat:@"%@  v%@", dispName, field(m, @"Version").length ? field(m, @"Version") : @"1.0"]];

        // Detect Android/Mobile-specific metadata in manifest.json / folder path / content.json / compiled DLLs
        NSString *desc = field(m, @"Description");
        if (sdvHasMobileEditionMarker(dispName) || sdvHasMobileEditionMarker(uid) ||
            sdvHasMobileEditionMarker(desc) || sdvHasMobileEditionMarker(base)) {
            addMobileWarn([NSString stringWithFormat:@"Mod \"%@\" được đánh dấu dành cho bản Mobile/Android.", dispName]);
        }
        NSString *entryDll = field(m, @"EntryDll");
        if (entryDll.length) {
            NSString *dllFull = inside(stage, base.length ? join(base, entryDll) : entryDll);
            NSData *dllData = [NSData dataWithContentsOfFile:dllFull options:NSDataReadingMappedIfSafe error:nil];
            if (sdvDataContainsAscii(dllData, "Mono.Android") ||
                sdvDataContainsAscii(dllData, "SMAPI.Android") ||
                sdvDataContainsAscii(dllData, "StardewValley.Android")) {
                addMobileWarn([NSString stringWithFormat:@"Mod \"%@\" (%@) biên dịch riêng cho SMAPI Android — có thể lỗi hoặc không tải được trên bản PC 1.6.15.", dispName, entryDll]);
            }
        }
        NSString *cpJsonPath = inside(stage, base.length ? join(base, @"content.json") : @"content.json");
        if ([fm() fileExistsAtPath:cpJsonPath]) {
            NSData *cjData = [NSData dataWithContentsOfFile:cpJsonPath options:NSDataReadingMappedIfSafe error:nil];
            if (sdvDataContainsAscii(cjData, "MobileAtlas") ||
                sdvDataContainsAscii(cjData, "mobileatlas") ||
                sdvDataContainsAscii(cjData, "NRTnarathip")) {
                addMobileWarn([NSString stringWithFormat:@"Content Pack \"%@\" chỉnh sửa tài nguyên riêng của bản Mobile (MobileAtlas).", dispName]);
            }
        }
    }
    for (NSString *bm in badManifests) {
        [warnings addObject:[@"Bỏ qua manifest lỗi: " stringByAppendingString:bm]];
    }

    NSArray *bases = [incoming.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [@(b.length) compare:@(a.length)];
    }];

    // Pass 2: Check dependencies, SMAPI API version, legacy 1.5 DLLs, and Content Patcher Load conflicts!
    NSDictionary<NSString *, NSSet<NSString *> *> *existingCpLoads = sdvCollectInstalledCpLoadTargets(root);
    for (NSString *base in bases) {
        NSDictionary *m = incoming[base][@"m"];
        NSString *dispName = field(m, @"Name").length ? field(m, @"Name") : field(m, @"UniqueID");
        NSString *minApi = field(m, @"MinimumApiVersion");
        if (minApi.length) {
            if (sdvCompareSemver(minApi, @"4.5.2") > 0) {
                [warnings addObject:[NSString stringWithFormat:@"%@ yêu cầu SMAPI v%@ (hiện tại 4.5.2).", dispName, minApi]];
            } else if (field(m, @"EntryDll").length && sdvCompareSemver(minApi, @"3.99.0") < 0) {
                [warnings addObject:[NSString stringWithFormat:@"%@ là mod C# đời cũ (SMAPI %@) — có thể không tương thích Stardew 1.6.15.", dispName, minApi]];
            }
        }
        NSMutableArray *deps = [NSMutableArray array];
        id rawDeps = dictValueCI(m, @"Dependencies");
        id rawCp = dictValueCI(m, @"ContentPackFor");
        if ([rawDeps isKindOfClass:NSArray.class]) [deps addObjectsFromArray:rawDeps];
        if ([rawCp isKindOfClass:NSDictionary.class]) [deps addObject:rawCp];
        for (id dep in deps) {
            if (![dep isKindOfClass:NSDictionary.class]) continue;
            NSString *uid = field(dep, @"UniqueID");
            NSString *uidLow = uid.lowercaseString;
            id req = dictValueCI(dep, @"IsRequired");
            if (uid.length && ![req isEqual:@NO]) {
                if (!combinedLibrary[uidLow]) {
                    if (disabledMap[uidLow]) {
                        [warnings addObject:[NSString stringWithFormat:@"Mod phụ thuộc đang bị TẮT: %@ (hãy bật lại trong Thư viện).", uid]];
                    } else {
                        [warnings addObject:[@"Thiếu mod phụ thuộc: " stringByAppendingString:uid]];
                    }
                } else {
                    NSString *minV = field(dep, @"MinimumVersion");
                    NSString *instV = field(combinedLibrary[uidLow][@"manifest"], @"Version");
                    if (minV.length && instV.length && sdvCompareSemver(instV, minV) < 0) {
                        [warnings addObject:[NSString stringWithFormat:@"%@ cần %@ ≥ v%@ (đang có v%@).", dispName, uid, minV, instV]];
                    }
                }
            }
        }
        // Check Content Patcher Action:Load conflicts against already-installed active CP packs
        NSString *cpJsonPath = inside(stage, base.length ? join(base, @"content.json") : @"content.json");
        if ([fm() fileExistsAtPath:cpJsonPath]) {
            NSSet<NSString *> *newLoads = sdvExtractCpLoadTargetsFromFile(cpJsonPath);
            NSString *selfUidLow = field(m, @"UniqueID").lowercaseString;
            for (NSString *otherKey in existingCpLoads) {
                if ([otherKey isEqualToString:selfUidLow]) continue;
                NSSet<NSString *> *otherTargets = existingCpLoads[otherKey];
                NSMutableArray<NSString *> *overlap = [NSMutableArray array];
                for (NSString *t in newLoads) {
                    if ([otherTargets containsObject:t]) [overlap addObject:t];
                }
                if (overlap.count) {
                    NSString *otherName = field(library[otherKey][@"manifest"], @"Name");
                    if (!otherName.length) otherName = otherKey;
                    [warnings addObject:[NSString stringWithFormat:@"Xung đột Content Patcher với \"%@\": cùng Load %@%@",
                        otherName, overlap.firstObject,
                        overlap.count > 1 ? [NSString stringWithFormat:@" (+%lu mục)", (unsigned long)(overlap.count - 1)] : @""]];
                }
            }
        }
    }

    // Pass 3a: Map all files belonging to discovered SMAPI mods first
    NSMutableArray *remaining = [NSMutableArray array];
    for (NSString *r in items) { @autoreleasepool {
        BOOL found = NO;
        for (NSString *base in bases) {
            NSString *tail = below(r, base);
            if (!tail) continue;
            NSString *dst = join(incoming[base][@"dest"], tail);
            if (!([tail.lowercaseString isEqual:@"config.json"] && [fm() fileExistsAtPath:gamePath(root, dst)])) {
                add(dst, r);
            }
            found = YES;
            break;
        }
        if (!found) {
            for (NSString *sb in skippedBases) {
                if (below(r, sb) != nil) { found = YES; break; }
            }
        }
        if (!found) [remaining addObject:r];
    }}

    // Pass 3b: Map Content/ overrides (Vietnamese fonts, .xnb, Strings, Data), standalone i18n packs, and loose XNB files
    NSArray *assets = nil;
    NSMutableSet *addedExtraNames = [NSMutableSet set];
    for (NSString *r in remaining) { @autoreleasepool {
        NSArray *parts = r.pathComponents;
        NSString *extLow = r.pathExtension.lowercaseString;

        // Direct Content/ subfolder inside pack (e.g. LOANMODVIETHOA/Content/Fonts/..., Content/Strings/..., Content/Data/...)
        NSUInteger contentIdx = [parts indexOfObjectPassingTest:^BOOL(NSString *s, NSUInteger i, BOOL *stop) {
            return i > 0 && [s.lowercaseString isEqualToString:@"content"];
        }];
        if (contentIdx != NSNotFound && contentIdx + 1 < parts.count) {
            if ([extLow isEqualToString:@"xnb"] || [extLow isEqualToString:@"json"] || [extLow isEqualToString:@"png"] || [extLow isEqualToString:@"tmx"] || [extLow isEqualToString:@"yaml"] || [extLow isEqualToString:@"fnt"]) {
                NSString *subRel = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(contentIdx + 1, parts.count - contentIdx - 1)]];
                NSString *fnLow = r.lastPathComponent.lowercaseString;
                // Protect PC Content UI XNBs from Android/Mobile optional XNB folders bundled inside a Content Patcher ZIP
                if (bases.count > 0 && [extLow isEqualToString:@"xnb"] &&
                    ([fnLow hasPrefix:@"mobileatlas"] || [fnLow isEqualToString:@"titlebuttons.xnb"] ||
                     [fnLow isEqualToString:@"menutiles.xnb"] || [fnLow isEqualToString:@"cursors.xnb"] ||
                     [fnLow isEqualToString:@"clouds.xnb"])) {
                    [warnings addObject:[NSString stringWithFormat:@"Bỏ qua XNB giao diện bản Mobile (%@) để bảo vệ Content gốc — mod đã dùng Content Patcher.", r.lastPathComponent]];
                    addMobileWarn([NSString stringWithFormat:@"Gói có chứa tệp giao diện bản Mobile (%@) — đã tự bỏ qua để bảo vệ Content PC gốc.", r.lastPathComponent]);
                    continue;
                }
                if ([fnLow hasPrefix:@"mobileatlas"]) {
                    addMobileWarn([NSString stringWithFormat:@"Chứa tệp riêng bản Mobile (%@) — có thể không tương thích giao diện PC 1.6.15.", r.lastPathComponent]);
                }
                NSString *canonSubRel = sdvCanonicalizeContentSubpath(root, subRel);
                add(join(@"Content", canonSubRel), r);
                NSString *topSub = canonSubRel.pathComponents.firstObject ?: parts[contentIdx + 1];
                NSString *lbl = [NSString stringWithFormat:@"Content/%@ (Việt hóa / Tài nguyên)", topSub];
                if (![addedExtraNames containsObject:lbl]) { [addedExtraNames addObject:lbl]; [names addObject:lbl]; }
                continue;
            }
        }

        NSUInteger idx = [parts indexOfObjectPassingTest:^BOOL(NSString *s, NSUInteger i, BOOL *stop) {
            return [s.lowercaseString isEqual:@"i18n"];
        }];
        if (idx != NSNotFound && [extLow isEqual:@"json"]) {
            NSString *owner = (idx > 0 && ![parts[idx-1] hasPrefix:@"pkg_"]) ? parts[idx-1] : @"";
            NSMutableArray *matches = [NSMutableArray array];
            for (NSDictionary *mod in combinedLibrary.allValues) {
                NSString *mdir = mod[@"dir"];
                if (mdir.length && mdir.lastPathComponent && owner.length &&
                    [owner caseInsensitiveCompare:mdir.lastPathComponent] == NSOrderedSame) {
                    [matches addObject:mdir];
                }
            }
            if (matches.count != 1) {
                NSString *selected = translations[owner];
                if (selected && combinedLibrary[selected]) {
                    [matches removeAllObjects];
                    [matches addObject:combinedLibrary[selected][@"dir"]];
                } else if (bases.count > 0 || out.count > 0) {
                    // Multi-mod pack contains an i18n file for a mod not currently installed -> warn & continue instead of aborting!
                    if (owner.length) [warnings addObject:[NSString stringWithFormat:@"Bỏ qua bản dịch i18n cho mod chưa cài: %@", owner]];
                    continue;
                } else {
                    if (!combinedLibrary.count) fail(@"Cài mod gốc trước (hoặc chọn chung với mod gốc) khi thêm bản dịch i18n.");
                    translationOwner = owner;
                    break;
                }
            }
            @try {
                if (![jsonAt(inside(stage, r)) isKindOfClass:NSDictionary.class]) continue;
            } @catch (NSException *ex) {
                [warnings addObject:[NSString stringWithFormat:@"Bỏ qua tệp dịch lỗi: %@", r.lastPathComponent]];
                continue;
            }
            NSString *targetDir = matches[0];
            add(join(join(@"Mods", targetDir), [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(idx, parts.count - idx)]]), r);
            NSString *lbl = [NSString stringWithFormat:@"Bản dịch i18n → %@", targetDir.lastPathComponent];
            if (![addedExtraNames containsObject:lbl]) { [addedExtraNames addObject:lbl]; [names addObject:lbl]; }
            continue;
        }

        if (![extLow isEqual:@"xnb"]) continue;
        // If this archive already installs SMAPI/Content Patcher mods, never silently overwrite PC Content/*.xnb
        // with loose sibling Android/Mobile XNB files (e.g. TitleButtons.xnb, MenuTiles.xnb, MobileAtlas*.xnb).
        if (bases.count > 0) {
            [warnings addObject:[NSString stringWithFormat:@"Bỏ qua XNB đi kèm (%@) vì gói đã có mod SMAPI/Content Patcher.", r.lastPathComponent]];
            if ([r.lastPathComponent.lowercaseString hasPrefix:@"mobileatlas"] ||
                [r.lastPathComponent.lowercaseString isEqualToString:@"titlebuttons.xnb"] ||
                [r.lastPathComponent.lowercaseString isEqualToString:@"menutiles.xnb"]) {
                addMobileWarn([NSString stringWithFormat:@"Gói có kẹp tệp XNB giao diện bản Mobile (%@) — đã tự bỏ qua để tránh hỏng màn hình.", r.lastPathComponent]);
            }
            continue;
        }
        if ([r.lastPathComponent.lowercaseString hasPrefix:@"mobileatlas"]) {
            addMobileWarn([NSString stringWithFormat:@"Tệp XNB riêng của bản Mobile (%@) — có thể gây lỗi hiển thị trên bản PC 1.6.15.", r.lastPathComponent]);
        }
        NSData *data = readFile(inside(stage, r));
        if (data.length < 10 || memcmp(data.bytes, "XNB", 3)) {
            [warnings addObject:[@"Bỏ qua tệp XNB không hợp lệ: " stringByAppendingString:r.lastPathComponent]];
            continue;
        }
        if (!assets) assets = files(gamePath(root, @"Content"));
        NSMutableArray *matches = [NSMutableArray array], *specific = [NSMutableArray array];
        // Strip synthetic pkg_NNN prefix when comparing relative XNB paths
        NSString *relNoPkg = r;
        if (parts.count >= 2 && [parts.firstObject hasPrefix:@"pkg_"]) {
            relNoPkg = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)]];
        }
        for (NSString *a in assets) {
            if ([a.lastPathComponent caseInsensitiveCompare:r.lastPathComponent] == NSOrderedSame) {
                [matches addObject:a];
                if ([relNoPkg.lowercaseString isEqual:a.lowercaseString] || [relNoPkg.lowercaseString hasSuffix:[@"/" stringByAppendingString:a.lowercaseString]]) {
                    [specific addObject:a];
                }
            }
        }
        if (specific.count == 1) matches = specific;
        if (!matches.count) {
            // If it's a localized .vi-VN.xnb (or similar) matching a known Content subfolder (e.g. Strings/Data/Fonts), install directly!
            NSArray<NSString *> *noPkgParts = relNoPkg.pathComponents;
            NSString *knownSub = nil;
            NSSet *contentDirs = [NSSet setWithArray:@[@"fonts", @"strings", @"data", @"characters", @"portraits", @"loosesprites", @"maps", @"minigames", @"terrainfeatures", @"tilesheets", @"animals", @"buildings", @"effects"]];
            for (NSUInteger k = 0; k + 1 < noPkgParts.count; k++) {
                if ([contentDirs containsObject:noPkgParts[k].lowercaseString]) {
                    knownSub = [NSString pathWithComponents:[noPkgParts subarrayWithRange:NSMakeRange(k, noPkgParts.count - k)]];
                    break;
                }
            }
            if (knownSub.length) {
                NSString *canonKnown = sdvCanonicalizeContentSubpath(root, knownSub);
                add(join(@"Content", canonKnown), r);
                NSString *lbl = [NSString stringWithFormat:@"XNB → Content/%@", canonKnown];
                if (![addedExtraNames containsObject:lbl]) { [addedExtraNames addObject:lbl]; [names addObject:lbl]; }
                continue;
            }
            if (out.count > 0) {
                [warnings addObject:[@"Bỏ qua XNB không rõ thư mục Content: " stringByAppendingString:r.lastPathComponent]];
                continue;
            }
            fail([@"Không tìm thấy XNB tương ứng trong Content: " stringByAppendingString:r.lastPathComponent]);
        }
        NSString *dst = nil;
        if (matches.count == 1) dst = matches[0];
        else {
            for (NSString *choice in preferences) {
                for (NSString *a in matches) if ([parent(a) isEqual:choice]) dst = a;
                if (dst) break;
            }
            // Auto-prefer Content/Portraits for flat XNB portrait packs (e.g. OhoDavi Portrait xnb)
            // when archive name or sibling portrait-only XNBs identify it unambiguously as Portraits!
            if (!dst) {
                BOOL looksLikePortraitPack = NO;
                for (NSString *sn in stagedFileNames) {
                    NSString *sl = sn.lowercaseString;
                    if ([sl containsString:@"portrait"] || [sl containsString:@"anime"]) { looksLikePortraitPack = YES; break; }
                }
                if (!looksLikePortraitPack) {
                    for (NSString *it in items) {
                        NSString *il = it.lastPathComponent.lowercaseString;
                        if ([il isEqualToString:@"answeringmachine.xnb"] || [il isEqualToString:@"dobson.xnb"] || [il isEqualToString:@"gil.xnb"]) {
                            looksLikePortraitPack = YES;
                            break;
                        }
                    }
                }
                if (looksLikePortraitPack) {
                    for (NSString *a in matches) {
                        if ([[parent(a) lowercaseString] isEqualToString:@"portraits"]) { dst = a; break; }
                    }
                }
            }
            if (!dst) {
                for (NSString *a in matches) if (![choices containsObject:parent(a)]) [choices addObject:parent(a)];
                break;
            }
        }
        add(join(@"Content", dst), r);
        NSString *lbl = [NSString stringWithFormat:@"XNB → Content/%@", dst];
        if (![addedExtraNames containsObject:lbl]) { [addedExtraNames addObject:lbl]; [names addObject:lbl]; }
    }}

    if (!out.count && !choices.count && translationOwner == nil) {
        if (badManifests.count) {
            fail([@"Không tìm thấy mod hợp lệ. Lỗi manifest: " stringByAppendingString:badManifests.firstObject]);
        }
        fail(@"Gói cần có manifest.json, thư mục Content/, bản dịch i18n hoặc tệp XNB.");
    }
    return @{
        @"map": out,
        @"names": names,
        @"warnings": warnings.allObjects,
        @"mobileWarnings": mobileWarnings,
        @"choices": choices,
        @"translationOwner": translationOwner ?: NSNull.null,
        @"obsoleteDisabled": obsoleteDisabled.allObjects,
        @"combinedLibrary": combinedLibrary
    };
}

// ============================================================================
// GARDEN LAUNCHER UPDATE CHECKER + OTA HOT-PATCH ENGINE (0% IPA Re-Signing!)
// ============================================================================
#define kSDVAppVersion @"1.1.2"
#define kSDVAppBuild   11200
static NSString *const kSDVUpdateNotification = @"SDVLauncherUpdateDidChangeNotification";
static NSString *const kSDVDismissedUpdatePrefKey = @"sdv_dismissed_update_id";
static NSString *const kSDVDefaultDiscordURL = @"https://discord.gg/tuTKv9xQ2Z";
static NSString *const kSDVDiscordUrlPrefKey = @"sdv_discord_invite_url";
static NSString *const kSDVDiscordStatsNotification = @"SDVDiscordStatsDidUpdateNotification";
static NSString *const kSDVVersionApiRawURL = @"https://api.github.com/repos/hanprm9-dot/Garden-Launcher-iOS/contents/version.json?ref=main";
static NSString *const kSDVVersionJsonURL = @"https://raw.githubusercontent.com/hanprm9-dot/Garden-Launcher-iOS/main/version.json";
static NSString *const kSDVLatestReleaseApiURL = @"https://api.github.com/repos/hanprm9-dot/Garden-Launcher-iOS/releases/latest";

static NSInteger gSdvDiscordOnlineCount = 0;
static NSInteger gSdvDiscordMemberCount = 0;
static NSTimeInterval gSdvLastDiscordStatsAt = 0;
static BOOL gSdvDiscordStatsInFlight = NO;

static BOOL sdvIsAllowedDiscordInviteURL(NSString *raw) {
    if (![raw isKindOfClass:NSString.class]) return NO;
    NSString *s = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (s.length < 16 || s.length > 128) return NO;
    if ([s rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return NO;
    NSString *low = s.lowercaseString;
    return [low hasPrefix:@"https://discord.gg/"] || [low hasPrefix:@"https://discord.com/invite/"];
}

static NSString *sdvDiscordInviteURL(void) {
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kSDVDiscordUrlPrefKey];
    if (sdvIsAllowedDiscordInviteURL(saved)) {
        return [saved stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    return kSDVDefaultDiscordURL;
}

static NSString *sdvExtractDiscordInviteCode(NSString *urlStr) {
    if (!urlStr.length) return @"";
    NSString *s = [urlStr stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/ \t\r\n"]];
    NSRange q = [s rangeOfString:@"?"];
    if (q.location != NSNotFound) s = [s substringToIndex:q.location];
    NSString *code = s.lastPathComponent ?: @"";
    if (code.length < 2 || code.length > 48) return @"";
    for (NSUInteger i = 0; i < code.length; i++) {
        unichar c = [code characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
        if (!ok) return @"";
    }
    return code;
}

static NSInteger sdvDiscordOnlineCount(void) { return gSdvDiscordOnlineCount; }
static NSInteger sdvDiscordMemberCount(void) { return gSdvDiscordMemberCount; }

static void sdvRefreshDiscordLiveStats(BOOL force) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ sdvRefreshDiscordLiveStats(force); });
        return;
    }
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (!force && gSdvLastDiscordStatsAt > 0 && (now - gSdvLastDiscordStatsAt) < 600.0) return;
    if (gSdvDiscordStatsInFlight) return;
    NSString *code = sdvExtractDiscordInviteCode(sdvDiscordInviteURL());
    if (!code.length) return;
    gSdvDiscordStatsInFlight = YES;

    NSString *apiStr = [NSString stringWithFormat:@"https://discord.com/api/v10/invites/%@?with_counts=true", code];
    NSURL *apiUrl = [NSURL URLWithString:apiStr];
    if (!apiUrl) {
        gSdvDiscordStatsInFlight = NO;
        return;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 5.0;
    cfg.timeoutIntervalForResource = 8.0;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];
    [[sess dataTaskWithURL:apiUrl completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSInteger online = 0;
        NSInteger members = 0;
        BOOL ok = NO;
        if (!err && status == 200 && data.length > 0) {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([j isKindOfClass:NSDictionary.class]) {
                if ([j[@"approximate_presence_count"] respondsToSelector:@selector(integerValue)]) {
                    online = [j[@"approximate_presence_count"] integerValue];
                }
                if ([j[@"approximate_member_count"] respondsToSelector:@selector(integerValue)]) {
                    members = [j[@"approximate_member_count"] integerValue];
                }
                ok = (members > 0 || online > 0);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            gSdvDiscordStatsInFlight = NO;
            if (ok) {
                gSdvLastDiscordStatsAt = CFAbsoluteTimeGetCurrent();
                BOOL changed = (gSdvDiscordOnlineCount != online || gSdvDiscordMemberCount != members);
                gSdvDiscordOnlineCount = online;
                gSdvDiscordMemberCount = members;
                if (changed) {
                    [NSNotificationCenter.defaultCenter postNotificationName:kSDVDiscordStatsNotification object:nil];
                }
            }
        });
        [sess finishTasksAndInvalidate];
    }] resume];
}

typedef void (^SDVUpdateCheckCompletion)(NSDictionary *updateInfo, NSString *statusMsg);
static NSDictionary *gSdvLatestUpdateInfo = nil;
static NSTimeInterval gSdvLastUpdateCheckAt = 0;
static BOOL gSdvUpdateCheckInFlight = NO;
static NSMutableArray<SDVUpdateCheckCompletion> *gSdvPendingUpdateCallbacks = nil;

static os_unfair_lock gSdvHotPatchLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary *gSdvActiveHotPatchInfo = nil;

static NSString *sdvHotPatchRootDir(NSString *docsPath) {
    if (!docsPath.length) return @"";
    return join(join(docsPath, @".garden"), @"hotpatch");
}

static NSDictionary *sdvActiveHotPatchInfo(void) {
    os_unfair_lock_lock(&gSdvHotPatchLock);
    NSDictionary *snap = gSdvActiveHotPatchInfo;
    os_unfair_lock_unlock(&gSdvHotPatchLock);
    return snap;
}

static void sdvSetActiveHotPatchInfo(NSDictionary *info) {
    NSDictionary *copied = info ? [info copy] : nil;
    os_unfair_lock_lock(&gSdvHotPatchLock);
    gSdvActiveHotPatchInfo = copied;
    os_unfair_lock_unlock(&gSdvHotPatchLock);
}

static BOOL sdvHotPatchOverridesRelPath(NSString *docsPath, NSString *relPath) {
    if (!docsPath.length || !relPath.length || sdvActiveHotPatchInfo() == nil) return NO;
    NSString *p = join(join(sdvHotPatchRootDir(docsPath), @"payload"), relPath);
    return !dir(p) && [fm() fileExistsAtPath:p];
}

static NSString *sdvEffectiveAppVersion(void) {
    NSDictionary *hp = sdvActiveHotPatchInfo();
    NSString *hpVer = [hp[@"version"] isKindOfClass:NSString.class] ? hp[@"version"] : nil;
    NSInteger hpBuild = [hp[@"build"] respondsToSelector:@selector(integerValue)] ? [hp[@"build"] integerValue] : 0;
    if (hpVer.length && (hpBuild > kSDVAppBuild || sdvCompareSemver(hpVer, kSDVAppVersion) > 0)) {
        return hpVer;
    }
    return kSDVAppVersion;
}

static NSInteger sdvEffectiveAppBuild(void) {
    NSDictionary *hp = sdvActiveHotPatchInfo();
    NSInteger hpBuild = [hp[@"build"] respondsToSelector:@selector(integerValue)] ? [hp[@"build"] integerValue] : 0;
    return (hpBuild > kSDVAppBuild) ? hpBuild : kSDVAppBuild;
}

static BOOL sdvIsHexSha256String(NSString *s) {
    if (![s isKindOfClass:NSString.class] || s.length != 64) return NO;
    for (NSUInteger i = 0; i < 64; i++) {
        unichar c = [s characterAtIndex:i];
        if (c > 127 || !isxdigit((int)c)) return NO;
    }
    return YES;
}

static void sdvClearHotPatchStamps(NSString *docsPath) {
    if (!docsPath.length) return;
    NSString *touchStamp = join(join(join(docsPath, @"Mods"), @"SDViOSTouchControls"), @".embedded_sha256");
    NSString *smapiStamp = join(join(sdvHiddenGameDir(docsPath), @"smapi-internal"), @".garden_smapi_v1");
    NSString *patchStampsDir = join(sdvHiddenGardenDir(docsPath), @"patch_stamps");
    sdvRemoveItemQuiet(touchStamp);
    sdvRemoveItemQuiet(smapiStamp);
    sdvRemoveItemQuiet(patchStampsDir);
}

// ============================================================================
// MOD PROFILES, SMART HOTKEY SCANNER & CO-OP LAN MODPACK HASH (v1.1.0)
// ============================================================================
static NSString *sdvModProfilesFilePath(NSString *root) {
    return join(sdvHiddenGardenDir(root), @"mod_profiles.json");
}

static NSArray<NSDictionary *> *sdvListSavedModProfiles(NSString *root) {
    NSString *p = sdvModProfilesFilePath(root);
    if (!p.length || ![fm() fileExistsAtPath:p] || dir(p)) return @[];
    @try {
        id parsed = jsonAt(p);
        if ([parsed isKindOfClass:NSArray.class]) return (NSArray *)parsed;
    } @catch (NSException *ex) { }
    return @[];
}

static void sdvSaveModProfileNamed(NSString *root, NSString *profileName) {
    NSString *trim = [profileName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trim.length) fail(@"Tên hồ sơ không được để trống.");
    NSArray<NSDictionary *> *cat = modCatalog(root);
    NSMutableArray<NSString *> *enabledClean = [NSMutableArray array];
    for (NSDictionary *m in cat) {
        if ([m[@"protected"] boolValue]) continue;
        if ([m[@"enabled"] boolValue] && [m[@"cleanFolder"] length]) {
            [enabledClean addObject:m[@"cleanFolder"]];
        }
    }
    NSMutableArray<NSDictionary *> *all = [sdvListSavedModProfiles(root) mutableCopy];
    NSInteger replaceIdx = NSNotFound;
    for (NSUInteger i = 0; i < all.count; i++) {
        if ([all[i][@"name"] caseInsensitiveCompare:trim] == NSOrderedSame) { replaceIdx = (NSInteger)i; break; }
    }
    NSDictionary *rec = @{
        @"name": trim,
        @"enabledCleanFolders": enabledClean,
        @"count": @(enabledClean.count),
        @"savedAt": @((long)time(NULL))
    };
    if (replaceIdx != NSNotFound) all[(NSUInteger)replaceIdx] = rec;
    else [all addObject:rec];
    NSData *out = [NSJSONSerialization dataWithJSONObject:all options:NSJSONWritingPrettyPrinted error:nil];
    if (out.length) writeFile(out, sdvModProfilesFilePath(root));
}

static void sdvDeleteModProfileNamed(NSString *root, NSString *profileName) {
    NSMutableArray<NSDictionary *> *all = [sdvListSavedModProfiles(root) mutableCopy];
    for (NSInteger i = (NSInteger)all.count - 1; i >= 0; i--) {
        if ([all[(NSUInteger)i][@"name"] caseInsensitiveCompare:profileName] == NSOrderedSame) {
            [all removeObjectAtIndex:(NSUInteger)i];
        }
    }
    NSData *out = [NSJSONSerialization dataWithJSONObject:all options:NSJSONWritingPrettyPrinted error:nil];
    if (out.length) writeFile(out, sdvModProfilesFilePath(root));
}

// mode: @"all_on", @"safe_mode" (only SDViOSTouchControls + SDVMobileControls), or @"profile:<name>"
static NSUInteger sdvApplyModProfileMode(NSString *root, NSString *mode) {
    NSArray<NSDictionary *> *cat = modCatalog(root);
    NSSet<NSString *> *targetOnClean = nil;
    if ([mode hasPrefix:@"profile:"]) {
        NSString *pName = [mode substringFromIndex:8];
        for (NSDictionary *pr in sdvListSavedModProfiles(root)) {
            if ([pr[@"name"] caseInsensitiveCompare:pName] == NSOrderedSame && [pr[@"enabledCleanFolders"] isKindOfClass:NSArray.class]) {
                NSMutableSet *s = [NSMutableSet set];
                for (NSString *cf in pr[@"enabledCleanFolders"]) [s addObject:cf.lowercaseString];
                targetOnClean = s;
                break;
            }
        }
        if (!targetOnClean) fail(@"Không tìm thấy hồ sơ Mod đã lưu.");
    }

    NSUInteger toggled = 0;
    for (NSDictionary *m in cat) {
        if ([m[@"protected"] boolValue]) continue;
        NSString *cleanLow = [m[@"cleanFolder"] lowercaseString];
        BOOL curOn = [m[@"enabled"] boolValue];
        BOOL wantOn = curOn;
        if ([mode isEqualToString:@"all_on"]) {
            wantOn = YES;
        } else if ([mode isEqualToString:@"safe_mode"]) {
            wantOn = ([cleanLow isEqualToString:@"sdvmobilecontrols"]);
        } else if (targetOnClean) {
            wantOn = [targetOnClean containsObject:cleanLow];
        }
        if (curOn != wantOn) {
            toggleModEnabled(root, m[@"topFolder"]);
            toggled++;
        }
    }
    return toggled;
}

static NSDictionary *sdvComputeCoopModpackInfo(NSString *root) {
    NSArray<NSDictionary *> *cat = modCatalog(root);
    NSSet<NSString *> *localOnly = [NSSet setWithArray:@[
        @"com.deadakj.sdviostouchcontrols", @"gardenlauncher.mobilecontrols",
        @"spacechase0.genericmodconfigmenu"
    ]];
    NSMutableArray<NSString *> *sigItems = [NSMutableArray array];
    NSMutableArray<NSString *> *humanLines = [NSMutableArray array];
    for (NSDictionary *m in cat) {
        if (![m[@"enabled"] boolValue]) continue;
        NSString *uid = [m[@"uniqueID"] isKindOfClass:NSString.class] ? m[@"uniqueID"] : @"";
        NSString *uidLow = uid.lowercaseString;
        if (!uidLow.length || [localOnly containsObject:uidLow]) continue;
        NSString *ver = m[@"version"] ?: @"1.0";
        [sigItems addObject:[NSString stringWithFormat:@"%@@%@", uidLow, ver.lowercaseString]];
        [humanLines addObject:[NSString stringWithFormat:@"• %@ (v%@)", m[@"name"] ?: uid, ver]];
    }
    [sigItems sortUsingSelector:@selector(compare:)];
    [humanLines sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSString *joined = sigItems.count ? [sigItems componentsJoinedByString:@"|"] : @"vanilla-1.6.15";
    NSString *fullSha = [hashData([joined dataUsingEncoding:NSUTF8StringEncoding]) uppercaseString];
    NSString *code = sigItems.count
        ? [NSString stringWithFormat:@"#COOP-%@", [fullSha substringToIndex:6]]
        : @"#COOP-VANILLA";
    NSMutableString *copyText = [NSMutableString stringWithFormat:@"Mã đồng bộ Co-op: %@ (Stardew 1.6.15 · %lu Mod active)", code, (unsigned long)sigItems.count];
    if (humanLines.count) {
        [copyText appendString:@"\n"];
        NSUInteger lim = MIN((NSUInteger)25, humanLines.count);
        for (NSUInteger i = 0; i < lim; i++) [copyText appendFormat:@"%@\n", humanLines[i]];
        if (humanLines.count > lim) [copyText appendFormat:@"… (+%lu mod khác)", (unsigned long)(humanLines.count - lim)];
    }
    return @{
        @"code": code,
        @"count": @(sigItems.count),
        @"copyText": copyText
    };
}

// Removes non-bundled Hot-Patch extra files (e.g. .garden/extra_mod_rules.json) before retiring or replacing a Hot-Patch payload
static void sdvCleanupHotPatchExtraFiles(NSString *docsPath) {
    if (!docsPath.length) return;
    NSString *payloadDir = join(sdvHotPatchRootDir(docsPath), @"payload");
    if (!dir(payloadDir)) return;
    NSSet<NSString *> *keepUserCfg = [NSSet setWithArray:@[
        @".garden/sdv_mobile_ctrl.cfg",
        @".garden/touch_overlay_config.json",
        @".garden/sdv_menubar.cfg",
        @".garden/sdv_perf.cfg"
    ]];
    NSDirectoryEnumerator *en = [fm() enumeratorAtPath:payloadDir];
    for (NSString *rawRel in en) {
        if (![en.fileAttributes.fileType isEqualToString:NSFileTypeRegular]) continue;
        NSString *rel = [rawRel stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if ([keepUserCfg containsObject:rel]) continue;
        if ([rel hasPrefix:@".garden/"]) {
            sdvRemoveItemQuiet(join(docsPath, rel));
        }
    }
}

static BOOL sdvValidateHotPatchRelPathAndData(NSString *rawRel, NSData *data, NSString **outReason) {
    if (!rawRel.length || !data.length) {
        if (outReason) *outReason = @"Tệp trong gói cập nhật nhanh bị trống.";
        return NO;
    }
    NSString *rel = [[rawRel stringByReplacingOccurrencesOfString:@"\\" withString:@"/"]
        stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/ "]];
    NSArray<NSString *> *parts = rel.pathComponents;
    if (!parts.count) {
        if (outReason) *outReason = @"Đường dẫn tệp không hợp lệ.";
        return NO;
    }
    for (NSString *seg in parts) {
        if (!seg.length || [seg isEqualToString:@"."] || [seg isEqualToString:@".."]) {
            if (outReason) *outReason = [NSString stringWithFormat:@"Đường dẫn không an toàn: %@", rel];
            return NO;
        }
    }
    NSString *ext = rel.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"dylib"] || [ext isEqualToString:@"so"] || [ext isEqualToString:@"exe"] ||
        [ext isEqualToString:@"app"] || [ext isEqualToString:@"ipa"] || [ext isEqualToString:@"sh"] ||
        [ext isEqualToString:@"bat"] || [ext isEqualToString:@"cmd"]) {
        if (outReason) *outReason = [NSString stringWithFormat:@"Gói cập nhật nhanh không được phép chứa mã thực thi hệ thống (%@) — cần cài bản IPA đầy đủ.", rel.lastPathComponent];
        return NO;
    }
    if (data.length >= 4) {
        uint32_t magic = 0;
        memcpy(&magic, data.bytes, 4);
        if (magic == 0xfeedfacfU || magic == 0xcffaedfeU || magic == 0xfeedfaceU ||
            magic == 0xcefaedfeU || magic == 0xcafebabeU || magic == 0xbebafecaU) {
            if (outReason) *outReason = [NSString stringWithFormat:@"Phát hiện nhị phân Mach-O gốc (%@) — cần cài lại IPA đầy đủ.", rel.lastPathComponent];
            return NO;
        }
    }
    BOOL allowed = NO;
    if ([rel hasPrefix:@"Mods/SDVMobileControls/"] && parts.count >= 3) {
        allowed = YES;
    } else if ([rel hasPrefix:@"Mods/SDViOSTouchControls/"] && parts.count >= 3) {
        allowed = YES;
    } else if ([rel isEqualToString:@"StardewValley/Lidgren.Network.dll"] ||
               [rel isEqualToString:@"StardewValley/StardewModdingAPI.dll"]) {
        allowed = YES;
    } else if ([rel hasPrefix:@"StardewValley/smapi-internal/"] && parts.count >= 3) {
        allowed = YES;
    } else if ([rel hasPrefix:@".garden/"] && parts.count == 2 && ![parts[1].lowercaseString isEqualToString:@"hotpatch"] &&
               ([ext isEqualToString:@"json"] || [ext isEqualToString:@"cfg"] || [ext isEqualToString:@"txt"])) {
        allowed = YES;
    }
    if (!allowed) {
        if (outReason) *outReason = [NSString stringWithFormat:@"Đường dẫn nằm ngoài danh mục cho phép của Hot-Patch: %@", rel];
        return NO;
    }
    if ([ext isEqualToString:@"dll"]) {
        const unsigned char *b = (const unsigned char *)data.bytes;
        if (data.length < 128 || b[0] != 'M' || b[1] != 'Z') {
            if (outReason) *outReason = [NSString stringWithFormat:@"Tệp thư viện .NET không hợp lệ hoặc bị hỏng: %@", rel.lastPathComponent];
            return NO;
        }
    } else if ([ext isEqualToString:@"json"]) {
        NSData *san = stripJson5ForIOS14(data);
        NSError *je = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:san options:NSJSONReadingAllowFragments error:&je];
        if (!obj) {
            if (outReason) *outReason = [NSString stringWithFormat:@"Tệp cấu hình JSON lỗi cú pháp (%@): %@", rel.lastPathComponent, je.localizedDescription ?: @"?"];
            return NO;
        }
    }
    return YES;
}

static NSString *sdvInitHotPatchOnBoot(NSString *docsPath) {
    if (!docsPath.length) {
        sdvSetActiveHotPatchInfo(nil);
        return @"no-docs";
    }
    @try {
        NSString *hpRoot = sdvHotPatchRootDir(docsPath);
        NSString *metaPath = join(hpRoot, @"meta.json");
        NSString *payloadDir = join(hpRoot, @"payload");
        if (![fm() fileExistsAtPath:metaPath]) {
            sdvSetActiveHotPatchInfo(nil);
            return @"none";
        }
        NSData *raw = [NSData dataWithContentsOfFile:metaPath options:0 error:nil];
        NSDictionary *meta = raw.length ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil;
        if (![meta isKindOfClass:NSDictionary.class]) {
            sdvCleanupHotPatchExtraFiles(docsPath);
            sdvRemoveItemQuiet(hpRoot);
            sdvClearHotPatchStamps(docsPath);
            sdvSetActiveHotPatchInfo(nil);
            return @"pruned-corrupt-meta";
        }
        NSString *ver = [meta[@"version"] isKindOfClass:NSString.class] ? meta[@"version"] : @"";
        NSInteger metaBuild = [meta[@"build"] respondsToSelector:@selector(integerValue)] ? [meta[@"build"] integerValue] : 0;
        NSInteger minIpaBuild = [meta[@"minIpaBuild"] respondsToSelector:@selector(integerValue)] ? [meta[@"minIpaBuild"] integerValue] : 0;
        NSInteger attempts = [meta[@"bootAttempts"] respondsToSelector:@selector(integerValue)] ? [meta[@"bootAttempts"] integerValue] : 0;

        // Auto-prune if user installed a newer or equal IPA over an older Hot-Patch, or if minIpaBuild exceeds this IPA
        BOOL isNewerThanBase = (metaBuild > kSDVAppBuild) || (metaBuild == 0 && sdvCompareSemver(ver, kSDVAppVersion) > 0);
        if (!ver.length || !isNewerThanBase || (minIpaBuild > 0 && minIpaBuild > kSDVAppBuild) || !dir(payloadDir)) {
            sdvCleanupHotPatchExtraFiles(docsPath);
            sdvRemoveItemQuiet(hpRoot);
            sdvClearHotPatchStamps(docsPath);
            sdvSetActiveHotPatchInfo(nil);
            return @"pruned-obsolete";
        }

        // Crash-loop safety valve: if 4 consecutive boots never reached Title Screen or Mod Garden, auto-revert to bundled IPA!
        if (attempts >= 4) {
            sdvCleanupHotPatchExtraFiles(docsPath);
            sdvRemoveItemQuiet(hpRoot);
            sdvClearHotPatchStamps(docsPath);
            sdvSetActiveHotPatchInfo(nil);
            return @"rollback-crashloop";
        }

        NSMutableDictionary *mut = [meta mutableCopy];
        mut[@"bootAttempts"] = @(attempts + 1);
        NSData *outMeta = [NSJSONSerialization dataWithJSONObject:mut options:NSJSONWritingPrettyPrinted error:nil];
        if (outMeta.length) [outMeta writeToFile:metaPath options:NSDataWritingAtomic error:nil];
        sdvSetActiveHotPatchInfo(mut);
        return [NSString stringWithFormat:@"active:%@#%ld(try=%ld)", ver, (long)metaBuild, (long)(attempts + 1)];
    } @catch (NSException *ex) {
        sdvSetActiveHotPatchInfo(nil);
        return @"err-init";
    }
}

static void sdvMarkHotPatchBootSucceeded(NSString *docsPath) {
    if (!docsPath.length) return;
    NSDictionary *hp = sdvActiveHotPatchInfo();
    if (!hp) return;
    NSInteger attempts = [hp[@"bootAttempts"] respondsToSelector:@selector(integerValue)] ? [hp[@"bootAttempts"] integerValue] : 0;
    if (attempts <= 0) return;
    @try {
        NSString *metaPath = join(sdvHotPatchRootDir(docsPath), @"meta.json");
        if (![fm() fileExistsAtPath:metaPath]) return;
        NSMutableDictionary *mut = [hp mutableCopy];
        mut[@"bootAttempts"] = @(0);
        NSData *outMeta = [NSJSONSerialization dataWithJSONObject:mut options:NSJSONWritingPrettyPrinted error:nil];
        if (outMeta.length) [outMeta writeToFile:metaPath options:NSDataWritingAtomic error:nil];
        sdvSetActiveHotPatchInfo(mut);
    } @catch (NSException *ex) { }
}

static NSUInteger sdvDeployActiveHotPatchFiles(NSString *docsPath) {
    if (!docsPath.length) return 0;
    NSDictionary *hp = sdvActiveHotPatchInfo();
    if (!hp) return 0;
    NSString *payloadDir = join(sdvHotPatchRootDir(docsPath), @"payload");
    if (!dir(payloadDir)) return 0;

    NSUInteger deployed = 0;
    @try {
        NSString *modsDir = join(docsPath, @"Mods");
        BOOL mcDisabled = dir(join(modsDir, @".SDVMobileControls"));

        NSDirectoryEnumerator *en = [fm() enumeratorAtPath:payloadDir];
        for (NSString *rawRel in en) {
            if (![en.fileAttributes.fileType isEqualToString:NSFileTypeRegular]) continue;
            NSString *rel = [rawRel stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            NSString *srcPath = join(payloadDir, rawRel);
            NSData *sd = [NSData dataWithContentsOfFile:srcPath options:NSDataReadingMappedIfSafe error:nil];
            if (!sdvValidateHotPatchRelPathAndData(rel, sd, nil)) continue;

            if ([rel hasPrefix:@"Mods/SDVMobileControls/"] && mcDisabled) continue;

            NSString *dstPath = join(docsPath, rel);
            NSString *fnLow = rel.lastPathComponent.lowercaseString;
            // Preserve user's customized mod/launcher/SMAPI configs
            if (([rel isEqualToString:@"Mods/SDVMobileControls/config.json"] ||
                 [rel isEqualToString:@".garden/sdv_mobile_ctrl.cfg"] ||
                 [rel isEqualToString:@".garden/touch_overlay_config.json"] ||
                 [rel isEqualToString:@".garden/sdv_menubar.cfg"] ||
                 [rel isEqualToString:@".garden/sdv_perf.cfg"] ||
                 [rel isEqualToString:@"StardewValley/smapi-internal/config.user.json"] ||
                 [fnLow isEqualToString:@"config.user.json"]) &&
                [fm() fileExistsAtPath:dstPath]) {
                continue;
            }

            [fm() createDirectoryAtPath:dstPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            NSData *dd = (!dir(dstPath) && [fm() fileExistsAtPath:dstPath]) ? [NSData dataWithContentsOfFile:dstPath options:NSDataReadingMappedIfSafe error:nil] : nil;
            NSString *sh = hashData(sd);
            if (!dd || dd.length != sd.length || ![sh isEqualToString:hashData(dd)]) {
                sdvPrepareWritableFileTarget(dstPath);
                [sd writeToFile:dstPath options:NSDataWritingAtomic error:nil];
            }
            deployed++;

            // Mirror SDViOSTouchControls.dll <-> SDViOSTouchControlsMod.dll (EntryDll in manifest.json!) and stamp .embedded_sha256
            // with the bundled resource's SHA-256 so SDViOS.Loader.GameHost::EnsureDefaultModsDeployed keeps our hot-patched assembly intact!
            if ([rel isEqualToString:@"Mods/SDViOSTouchControls/SDViOSTouchControls.dll"] ||
                [rel isEqualToString:@"Mods/SDViOSTouchControls/SDViOSTouchControlsMod.dll"]) {
                NSString *dstTouchDir = dstPath.stringByDeletingLastPathComponent;
                NSString *siblingName = [rel hasSuffix:@"Mod.dll"] ? @"SDViOSTouchControls.dll" : @"SDViOSTouchControlsMod.dll";
                NSString *siblingPath = join(dstTouchDir, siblingName);
                NSData *md = (!dir(siblingPath) && [fm() fileExistsAtPath:siblingPath]) ? [NSData dataWithContentsOfFile:siblingPath options:NSDataReadingMappedIfSafe error:nil] : nil;
                if (!md || md.length != sd.length || ![sh isEqualToString:hashData(md)]) {
                    sdvPrepareWritableFileTarget(siblingPath);
                    [sd writeToFile:siblingPath options:NSDataWritingAtomic error:nil];
                }
                NSString *appTouchDir = join(join(NSBundle.mainBundle.bundlePath, @"Mods"), @"SDViOSTouchControls");
                NSString *dstManifest = join(dstTouchDir, @"manifest.json");
                NSString *appManifest = join(appTouchDir, @"manifest.json");
                if (![fm() fileExistsAtPath:dstManifest] && [fm() fileExistsAtPath:appManifest]) {
                    NSData *mfd = [NSData dataWithContentsOfFile:appManifest options:0 error:nil];
                    if (mfd.length) {
                        sdvPrepareWritableFileTarget(dstManifest);
                        [mfd writeToFile:dstManifest options:NSDataWritingAtomic error:nil];
                    }
                }
                NSString *appTouchDll = join(appTouchDir, @"SDViOSTouchControls.dll");
                NSData *appTouchData = [fm() fileExistsAtPath:appTouchDll] ? [NSData dataWithContentsOfFile:appTouchDll options:NSDataReadingMappedIfSafe error:nil] : nil;
                if (appTouchData.length) {
                    NSString *embStamp = [hashData(appTouchData) uppercaseString];
                    NSString *stampDst = join(dstTouchDir, @".embedded_sha256");
                    sdvPrepareWritableFileTarget(stampDst);
                    [embStamp writeToFile:stampDst atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
            } else if ([rel isEqualToString:@"StardewValley/StardewModdingAPI.dll"]) {
                NSString *appSmapiDll = join(join(join(join(NSBundle.mainBundle.bundlePath, @"Frameworks"), @"SDVModGarden.framework"), @"BundledSMAPI"), @"StardewModdingAPI.dll");
                NSData *appSmapiData = [fm() fileExistsAtPath:appSmapiDll] ? [NSData dataWithContentsOfFile:appSmapiDll options:NSDataReadingMappedIfSafe error:nil] : nil;
                if (appSmapiData.length) {
                    NSString *smapiInternalDir = join(sdvHiddenGameDir(docsPath), @"smapi-internal");
                    [fm() createDirectoryAtPath:smapiInternalDir withIntermediateDirectories:YES attributes:nil error:nil];
                    NSString *smapiStampDst = join(smapiInternalDir, @".garden_smapi_v1");
                    sdvPrepareWritableFileTarget(smapiStampDst);
                    [hashData(appSmapiData) writeToFile:smapiStampDst atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
            }
        }
    } @catch (NSException *ex) { }
    return deployed;
}

static NSUInteger sdvInstallHotPatchSync(NSDictionary *info, NSString *docsPath) {
    if (!docsPath.length) fail(@"Không tìm thấy thư mục Documents của ứng dụng.");
    NSString *ver = [info[@"version"] isKindOfClass:NSString.class] ? info[@"version"] : @"";
    NSInteger build = [info[@"build"] respondsToSelector:@selector(integerValue)] ? [info[@"build"] integerValue] : 0;
    NSInteger minIpaBuild = [info[@"minIpaBuild"] respondsToSelector:@selector(integerValue)] ? [info[@"minIpaBuild"] integerValue] : kSDVAppBuild;
    NSString *hpUrl = [info[@"hotpatchUrl"] isKindOfClass:NSString.class] ? info[@"hotpatchUrl"] : @"";
    NSString *expSha = [info[@"hotpatchSha256"] isKindOfClass:NSString.class] ? [info[@"hotpatchSha256"] lowercaseString] : @"";
    NSString *dateStr = [info[@"date"] isKindOfClass:NSString.class] ? info[@"date"] : @"";

    if (!ver.length || !hpUrl.length || ![hpUrl.lowercaseString hasPrefix:@"https://"]) {
        fail(@"Bản cập nhật này không cung cấp liên kết cập nhật nhanh HTTPS hợp lệ.");
    }
    if (!sdvIsHexSha256String(expSha)) {
        fail(@"Thiếu mã xác thực bảo mật SHA-256 cho gói cập nhật nhanh.");
    }
    if (minIpaBuild > kSDVAppBuild) {
        fail([NSString stringWithFormat:@"Bản cập nhật v%@ yêu cầu nền IPA mới hơn (build ≥ %ld). Vui lòng bấm Tải IPA để cập nhật.", ver, (long)minIpaBuild]);
    }

    // 1. Download hotpatch package over HTTPS (ephemeral, zero cache)
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 15.0;
    cfg.timeoutIntervalForResource = 45.0;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:hpUrl]];
    [req setValue:[NSString stringWithFormat:@"GardenLauncher-iOS/%@", sdvEffectiveAppVersion()] forHTTPHeaderField:@"User-Agent"];

    __block NSData *dlData = nil;
    __block NSInteger httpCode = 0;
    __block NSError *dlErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[sess dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dlData = data;
        dlErr = err;
        if ([resp isKindOfClass:NSHTTPURLResponse.class]) {
            httpCode = [(NSHTTPURLResponse *)resp statusCode];
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    long waitRc = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_SEC)));
    [sess finishTasksAndInvalidate];

    if (waitRc != 0) fail(@"Quá thời gian tải gói cập nhật nhanh. Vui lòng kiểm tra kết nối mạng và thử lại.");
    if (dlErr || httpCode != 200 || !dlData.length) {
        fail([NSString stringWithFormat:@"Không tải được gói cập nhật nhanh (HTTP %ld%@).", (long)httpCode, dlErr ? [NSString stringWithFormat:@" — %@", dlErr.localizedDescription] : @""]);
    }
    if (dlData.length < 64 || dlData.length > 64 * 1024 * 1024) {
        fail([NSString stringWithFormat:@"Kích thước gói cập nhật nhanh không hợp lệ (%lu bytes).", (unsigned long)dlData.length]);
    }

    // 2. Cryptographic SHA-256 verification BEFORE touching disk extraction!
    NSString *actualSha = [hashData(dlData) lowercaseString];
    if (![actualSha isEqualToString:expSha]) {
        fail([NSString stringWithFormat:@"Mã xác thực SHA-256 không khớp (nhận %@…, cần %@…). Đã hủy cài đặt để bảo vệ an toàn!", [actualSha substringToIndex:10], [expSha substringToIndex:10]]);
    }

    // 3. Extract & strictly whitelist every file in isolated temp directories
    NSString *uid = NSUUID.UUID.UUIDString;
    NSString *tmpZip = join(NSTemporaryDirectory(), [NSString stringWithFormat:@"hp_pkg_%@.zip", uid]);
    NSString *tmpUnpack = join(NSTemporaryDirectory(), [NSString stringWithFormat:@"hp_unpack_%@", uid]);
    NSString *tmpReady = join(NSTemporaryDirectory(), [NSString stringWithFormat:@"hp_ready_%@", uid]);
    NSUInteger deployedCount = 0;

    @try {
        writeFile(dlData, tmpZip);
        mkdirs(tmpUnpack);
        extractArchiveFileToDir(tmpZip, [NSString stringWithFormat:@"Garden-HotPatch-%@.zip", ver], tmpUnpack, 0);

        NSArray<NSString *> *rawItems = files(tmpUnpack);
        if (!rawItems.count) fail(@"Gói cập nhật nhanh trống.");

        // Support optional single top-level wrapper folder (e.g. Garden-HotPatch-1.0.4/Mods/...)
        NSSet<NSString *> *knownRoots = [NSSet setWithArray:@[@"mods", @"stardewvalley", @".garden"]];
        NSString *commonWrap = nil;
        BOOL canStripWrap = YES;
        for (NSString *it in rawItems) {
            NSArray<NSString *> *pc = [it stringByReplacingOccurrencesOfString:@"\\" withString:@"/"].pathComponents;
            if (pc.count < 2 || [knownRoots containsObject:pc.firstObject.lowercaseString]) {
                canStripWrap = NO;
                break;
            }
            if (!commonWrap) commonWrap = pc.firstObject;
            else if (![commonWrap isEqualToString:pc.firstObject]) {
                canStripWrap = NO;
                break;
            }
        }

        NSString *readyPayload = join(tmpReady, @"payload");
        mkdirs(readyPayload);
        NSUInteger validFiles = 0;
        for (NSString *it in rawItems) {
            NSString *normRel = [it stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            if (canStripWrap && commonWrap.length) {
                NSArray<NSString *> *pc = normRel.pathComponents;
                normRel = [NSString pathWithComponents:[pc subarrayWithRange:NSMakeRange(1, pc.count - 1)]];
            }
            NSData *fd = readFile(inside(tmpUnpack, it));
            NSString *badReason = nil;
            if (!sdvValidateHotPatchRelPathAndData(normRel, fd, &badReason)) {
                fail(badReason ?: @"Tệp trong gói cập nhật nhanh không hợp lệ.");
            }
            writeFile(fd, inside(readyPayload, normRel));
            validFiles++;
        }
        if (validFiles == 0) fail(@"Không tìm thấy tệp cập nhật hợp lệ trong gói.");

        NSDictionary *meta = @{
            @"version": ver,
            @"build": @(build > kSDVAppBuild ? build : (sdvEffectiveAppBuild() + 1)),
            @"minIpaBuild": @(minIpaBuild),
            @"date": dateStr ?: @"",
            @"sha256": actualSha,
            @"size": @(dlData.length),
            @"fileCount": @(validFiles),
            @"installedAt": @((long)time(NULL)),
            @"bootAttempts": @(0)
        };
        NSData *metaData = [NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:nil];
        if (!metaData.length) fail(@"Không tạo được tệp metadata cho bản cập nhật nhanh.");
        writeFile(metaData, join(tmpReady, @"meta.json"));

        // 4. Clean up any files from a previous Hot-Patch, restore base bundled files, then swap & deploy new Hot-Patch atomically!
        sdvHiddenGardenDir(docsPath);
        NSString *hpRoot = sdvHotPatchRootDir(docsPath);
        BOOL hadPrevHotPatch = [fm() fileExistsAtPath:hpRoot];
        if (hadPrevHotPatch) {
            sdvSetActiveHotPatchInfo(nil);
            sdvCleanupHotPatchExtraFiles(docsPath);
            removeItem(hpRoot);
            sdvClearHotPatchStamps(docsPath);
            syncBundledLidgren(docsPath);
            syncBundledSmapi(docsPath);
            syncBundledMobileControls(docsPath);
        }
        NSError *mvErr = nil;
        if (![fm() moveItemAtPath:tmpReady toPath:hpRoot error:&mvErr]) {
            check(NO, mvErr);
        }
        sdvSetActiveHotPatchInfo(meta);
        deployedCount = sdvDeployActiveHotPatchFiles(docsPath);

        dispatch_async(dispatch_get_main_queue(), ^{
            gSdvLatestUpdateInfo = nil;
            [NSNotificationCenter.defaultCenter postNotificationName:kSDVUpdateNotification object:nil];
        });
    } @finally {
        sdvRemoveItemQuiet(tmpZip);
        sdvRemoveItemQuiet(tmpUnpack);
        sdvRemoveItemQuiet(tmpReady);
    }
    return deployedCount;
}

static void sdvRollbackHotPatchSync(NSString *docsPath) {
    if (!docsPath.length) return;
    sdvSetActiveHotPatchInfo(nil);
    sdvCleanupHotPatchExtraFiles(docsPath);
    NSString *hpRoot = sdvHotPatchRootDir(docsPath);
    if ([fm() fileExistsAtPath:hpRoot]) removeItem(hpRoot);
    sdvClearHotPatchStamps(docsPath);
    syncBundledLidgren(docsPath);
    syncBundledSmapi(docsPath);
    syncBundledMobileControls(docsPath);
    gSdvLastUpdateCheckAt = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:kSDVUpdateNotification object:nil];
    });
}

static NSString *sdvNormalizeSummaryLines(id rawSummary, NSString *fallbackBody) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if ([rawSummary isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)rawSummary) {
            if ([item isKindOfClass:NSString.class]) {
                NSString *t = [(NSString *)item stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (t.length) {
                    if (![t hasPrefix:@"•"] && ![t hasPrefix:@"-"]) t = [@"• " stringByAppendingString:t];
                    else if ([t hasPrefix:@"- "]) t = [@"• " stringByAppendingString:[t substringFromIndex:2]];
                    [lines addObject:t];
                }
            }
            if (lines.count >= 6) break;
        }
    } else if ([rawSummary isKindOfClass:NSString.class] && [(NSString *)rawSummary length] > 0) {
        for (NSString *ln in [(NSString *)rawSummary componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *t = [ln stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!t.length) continue;
            if (![t hasPrefix:@"•"] && ![t hasPrefix:@"-"]) t = [@"• " stringByAppendingString:t];
            else if ([t hasPrefix:@"- "]) t = [@"• " stringByAppendingString:[t substringFromIndex:2]];
            [lines addObject:t];
            if (lines.count >= 6) break;
        }
    }
    if (!lines.count && fallbackBody.length) {
        for (NSString *ln in [fallbackBody componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *t = [ln stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if ([t hasPrefix:@"- "] || [t hasPrefix:@"* "]) {
                NSString *clean = [[t substringFromIndex:2] stringByReplacingOccurrencesOfString:@"**" withString:@""];
                if (clean.length > 110) clean = [[clean substringToIndex:107] stringByAppendingString:@"…"];
                [lines addObject:[@"• " stringByAppendingString:clean]];
                if (lines.count >= 5) break;
            }
        }
    }
    if (!lines.count) {
        [lines addObject:@"• Cải thiện hiệu năng, độ ổn định và sửa các lỗi người dùng báo cáo."];
    }
    return [lines componentsJoinedByString:@"\n"];
}

static NSDictionary *sdvAvailableLauncherUpdate(BOOL includeDismissed) {
    NSDictionary *info = gSdvLatestUpdateInfo;
    if (!info) return nil;
    if (!includeDismissed) {
        NSString *dismissed = [NSUserDefaults.standardUserDefaults stringForKey:kSDVDismissedUpdatePrefKey];
        if (dismissed.length && [dismissed isEqualToString:info[@"updateId"]]) return nil;
    }
    return info;
}

static void sdvDismissLauncherUpdate(NSString *updateId) {
    if (!updateId.length) return;
    [NSUserDefaults.standardUserDefaults setObject:updateId forKey:kSDVDismissedUpdatePrefKey];
    [NSNotificationCenter.defaultCenter postNotificationName:kSDVUpdateNotification object:nil];
}

static NSString *sdvRecommendedUpdateDownloadURL(NSDictionary *info) {
    if (!info) return @"https://github.com/hanprm9-dot/Garden-Launcher-iOS/releases/latest";
    NSInteger majorIOS = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    NSString *pick = (majorIOS >= 19) ? info[@"ios26Url"] : info[@"ios14Url"];
    if (!pick.length) pick = info[@"releaseUrl"];
    return pick.length ? pick : @"https://github.com/hanprm9-dot/Garden-Launcher-iOS/releases/latest";
}

static void sdvCompletePendingUpdateCallbacks(NSDictionary *info, NSString *msg, BOOL networkSucceeded) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gSdvUpdateCheckInFlight = NO;
        if (networkSucceeded) {
            gSdvLastUpdateCheckAt = CFAbsoluteTimeGetCurrent();
        }
        NSArray<SDVUpdateCheckCompletion> *cbs = gSdvPendingUpdateCallbacks.count ? [gSdvPendingUpdateCallbacks copy] : nil;
        [gSdvPendingUpdateCallbacks removeAllObjects];
        for (SDVUpdateCheckCompletion cb in cbs) {
            cb(info, msg);
        }
    });
}

static void sdvParseAndStoreRemoteUpdateDict(NSDictionary *json, BOOL isGithubReleaseApi) {
    NSString *ver = nil;
    NSInteger build = 0;
    NSInteger minIpaBuild = kSDVAppBuild;
    NSString *dateStr = @"";
    NSString *summary = @"";
    NSString *ios14Url = @"";
    NSString *ios26Url = @"";
    NSString *hotpatchUrl = @"";
    NSString *hotpatchSha256 = @"";
    long long hotpatchSize = 0;
    NSString *relUrl = @"https://github.com/hanprm9-dot/Garden-Launcher-iOS/releases/latest";

    if (!isGithubReleaseApi) {
        ver = [json[@"version"] isKindOfClass:NSString.class] ? json[@"version"] : @"";
        if ([ver hasPrefix:@"v"] || [ver hasPrefix:@"V"]) ver = [ver substringFromIndex:1];
        if ([json[@"build"] respondsToSelector:@selector(integerValue)]) build = [json[@"build"] integerValue];
        if ([json[@"min_ipa_build"] respondsToSelector:@selector(integerValue)] && [json[@"min_ipa_build"] integerValue] > 0) {
            minIpaBuild = [json[@"min_ipa_build"] integerValue];
        }
        if ([json[@"date"] isKindOfClass:NSString.class]) dateStr = json[@"date"];
        if ([json[@"release_url"] isKindOfClass:NSString.class] && [json[@"release_url"] length]) relUrl = json[@"release_url"];
        if ([json[@"ios14_url"] isKindOfClass:NSString.class]) ios14Url = json[@"ios14_url"];
        if ([json[@"ios26_url"] isKindOfClass:NSString.class]) ios26Url = json[@"ios26_url"];
        if ([json[@"hotpatch_url"] isKindOfClass:NSString.class]) hotpatchUrl = json[@"hotpatch_url"];
        if ([json[@"hotpatch_sha256"] isKindOfClass:NSString.class]) hotpatchSha256 = [json[@"hotpatch_sha256"] lowercaseString];
        if ([json[@"hotpatch_size"] respondsToSelector:@selector(longLongValue)]) hotpatchSize = [json[@"hotpatch_size"] longLongValue];
        if ([json[@"discord_url"] isKindOfClass:NSString.class] && sdvIsAllowedDiscordInviteURL(json[@"discord_url"])) {
            NSString *cleanDiscord = [json[@"discord_url"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *prev = [NSUserDefaults.standardUserDefaults stringForKey:kSDVDiscordUrlPrefKey];
                if (![prev isEqualToString:cleanDiscord]) {
                    [NSUserDefaults.standardUserDefaults setObject:cleanDiscord forKey:kSDVDiscordUrlPrefKey];
                    sdvRefreshDiscordLiveStats(YES);
                }
            });
        }
        summary = sdvNormalizeSummaryLines(json[@"summary"], nil);
    } else {
        ver = [json[@"tag_name"] isKindOfClass:NSString.class] ? json[@"tag_name"] : @"";
        if ([ver hasPrefix:@"v"] || [ver hasPrefix:@"V"]) ver = [ver substringFromIndex:1];
        if ([json[@"html_url"] isKindOfClass:NSString.class] && [json[@"html_url"] length]) relUrl = json[@"html_url"];
        if ([json[@"published_at"] isKindOfClass:NSString.class] && [json[@"published_at"] length] >= 10) {
            dateStr = [json[@"published_at"] substringToIndex:10];
        }
        NSArray *assets = [json[@"assets"] isKindOfClass:NSArray.class] ? json[@"assets"] : @[];
        for (NSDictionary *a in assets) {
            if (![a isKindOfClass:NSDictionary.class]) continue;
            NSString *nm = [a[@"name"] isKindOfClass:NSString.class] ? [a[@"name"] lowercaseString] : @"";
            NSString *dl = [a[@"browser_download_url"] isKindOfClass:NSString.class] ? a[@"browser_download_url"] : @"";
            if (!dl.length) continue;
            if ([nm containsString:@"ios14"]) ios14Url = dl;
            else if ([nm containsString:@"ios26"]) ios26Url = dl;
            else if ([nm containsString:@"hotpatch"] && [nm hasSuffix:@".zip"]) {
                hotpatchUrl = dl;
                if ([a[@"size"] respondsToSelector:@selector(longLongValue)]) hotpatchSize = [a[@"size"] longLongValue];
                NSString *dig = [a[@"digest"] isKindOfClass:NSString.class] ? [a[@"digest"] lowercaseString] : @"";
                if ([dig hasPrefix:@"sha256:"] && dig.length == 71) {
                    hotpatchSha256 = [dig substringFromIndex:7];
                }
            }
        }
        NSString *body = [json[@"body"] isKindOfClass:NSString.class] ? json[@"body"] : @"";
        // Only trust GitHub Release fallback hot-patch if release body explicitly specifies `min_ipa_build: <int>`;
        // otherwise require full IPA or version.json so an older base IPA never installs an incompatible Hot-Patch!
        minIpaBuild = NSIntegerMax;
        if (body.length) {
            NSRegularExpression *reMin = [NSRegularExpression regularExpressionWithPattern:@"min_ipa_build\\s*[:=]\\s*(\\d{4,6})" options:NSRegularExpressionCaseInsensitive error:nil];
            NSTextCheckingResult *m = [reMin firstMatchInString:body options:0 range:NSMakeRange(0, body.length)];
            if (m && m.numberOfRanges >= 2) {
                minIpaBuild = [[body substringWithRange:[m rangeAtIndex:1]] integerValue];
            }
        }
        summary = sdvNormalizeSummaryLines(nil, body);
    }

    if (!ver.length) {
        sdvCompletePendingUpdateCallbacks(nil, @"Không đọc được thông tin phiên bản từ máy chủ.", NO);
        return;
    }

    NSString *curVer = sdvEffectiveAppVersion();
    NSInteger curBuild = sdvEffectiveAppBuild();
    BOOL isNewer = (build > curBuild) || (build == 0 && sdvCompareSemver(ver, curVer) > 0);
    // Only synthesize default IPA download URLs when version.json omitted them AND this is not a hotpatch-only release!
    if (!isGithubReleaseApi && !hotpatchUrl.length) {
        if (!ios14Url.length) {
            ios14Url = [NSString stringWithFormat:@"https://github.com/hanprm9-dot/Garden-Launcher-iOS/releases/download/v%@/Garden-Launcher-%@-iOS14-18.ipa", ver, ver];
        }
        if (!ios26Url.length) {
            ios26Url = [NSString stringWithFormat:@"https://github.com/hanprm9-dot/Garden-Launcher-iOS/releases/download/v%@/Garden-Launcher-%@-iOS26-27.ipa", ver, ver];
        }
    }

    BOOL canHotPatch = (hotpatchUrl.length > 0 &&
                        [hotpatchUrl.lowercaseString hasPrefix:@"https://"] &&
                        sdvIsHexSha256String(hotpatchSha256) &&
                        minIpaBuild <= kSDVAppBuild);

    NSString *updateId = [NSString stringWithFormat:@"%@#%ld", ver, (long)build];
    NSDictionary *info = isNewer ? @{
        @"version": ver,
        @"build": @(build),
        @"minIpaBuild": @(minIpaBuild),
        @"updateId": updateId,
        @"date": dateStr ?: @"",
        @"summary": summary ?: @"",
        @"ios14Url": ios14Url,
        @"ios26Url": ios26Url,
        @"releaseUrl": relUrl,
        @"canHotPatch": @(canHotPatch),
        @"hotpatchUrl": hotpatchUrl ?: @"",
        @"hotpatchSha256": hotpatchSha256 ?: @"",
        @"hotpatchSize": @(hotpatchSize)
    } : nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        gSdvLatestUpdateInfo = info;
        NSString *msg = nil;
        if (info) {
            [NSNotificationCenter.defaultCenter postNotificationName:kSDVUpdateNotification object:nil];
            msg = canHotPatch
                ? [NSString stringWithFormat:@"Đã có bản cập nhật nhanh v%@ — cập nhật trực tiếp ngay trong app, không cần ký lại IPA!", ver]
                : [NSString stringWithFormat:@"Đã tìm thấy bản cập nhật mới v%@!", ver];
        } else {
            msg = [NSString stringWithFormat:@"Bạn đang dùng phiên bản mới nhất (v%@).", sdvEffectiveAppVersion()];
        }
        sdvCompletePendingUpdateCallbacks(info, msg, YES);
    });
}

static void sdvCheckLauncherUpdate(BOOL force, SDVUpdateCheckCompletion completion) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            sdvCheckLauncherUpdate(force, completion);
        });
        return;
    }
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (!force && gSdvLastUpdateCheckAt > 0 && (now - gSdvLastUpdateCheckAt) < 1800.0) {
        if (completion) {
            completion(gSdvLatestUpdateInfo, gSdvLatestUpdateInfo ? nil : [NSString stringWithFormat:@"Bạn đang dùng phiên bản mới nhất (v%@).", sdvEffectiveAppVersion()]);
        }
        return;
    }
    if (completion) {
        if (!gSdvPendingUpdateCallbacks) gSdvPendingUpdateCallbacks = [NSMutableArray array];
        [gSdvPendingUpdateCallbacks addObject:[completion copy]];
    }
    if (gSdvUpdateCheckInFlight) return;
    gSdvUpdateCheckInFlight = YES;

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 6.0;
    cfg.timeoutIntervalForResource = 12.0;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];

    NSString *ua = [NSString stringWithFormat:@"GardenLauncher-iOS/%@", sdvEffectiveAppVersion()];
    NSMutableURLRequest *(^makeRawReq)(NSTimeInterval) = ^NSMutableURLRequest *(NSTimeInterval timeout) {
        NSString *u = [NSString stringWithFormat:@"%@?t=%ld", kSDVVersionJsonURL, (long)time(NULL)];
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]];
        r.timeoutInterval = timeout;
        [r setValue:ua forHTTPHeaderField:@"User-Agent"];
        return r;
    };
    NSMutableURLRequest *(^makeApiReq)(NSTimeInterval) = ^NSMutableURLRequest *(NSTimeInterval timeout) {
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kSDVVersionApiRawURL]];
        r.timeoutInterval = timeout;
        [r setValue:ua forHTTPHeaderField:@"User-Agent"];
        [r setValue:@"application/vnd.github.raw+json" forHTTPHeaderField:@"Accept"];
        return r;
    };

    // Automatic boot check (force == NO): try raw.githubusercontent.com (4s, zero REST API rate-limit cost on CGNAT) -> GitHub Contents API -> Releases API.
    // Manual check (force == YES): try GitHub Contents API first (0s CDN lag + bypasses Vietnam ISP raw blocks) -> raw.githubusercontent.com -> Releases API.
    NSMutableURLRequest *firstReq  = force ? makeApiReq(6.0) : makeRawReq(4.0);
    NSMutableURLRequest *secondReq = force ? makeRawReq(6.0) : makeApiReq(6.0);

    [[sess dataTaskWithRequest:firstReq completionHandler:^(NSData *d1, NSURLResponse *r1, NSError *e1) {
        NSHTTPURLResponse *h1 = [r1 isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)r1 : nil;
        if (!e1 && h1.statusCode == 200 && d1.length > 8) {
            NSDictionary *j1 = [NSJSONSerialization JSONObjectWithData:d1 options:0 error:nil];
            if ([j1 isKindOfClass:NSDictionary.class] && [j1[@"version"] isKindOfClass:NSString.class]) {
                sdvParseAndStoreRemoteUpdateDict(j1, NO);
                [sess finishTasksAndInvalidate];
                return;
            }
        }
        [[sess dataTaskWithRequest:secondReq completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
            NSHTTPURLResponse *h2 = [r2 isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)r2 : nil;
            if (!e2 && h2.statusCode == 200 && d2.length > 8) {
                NSDictionary *j2 = [NSJSONSerialization JSONObjectWithData:d2 options:0 error:nil];
                if ([j2 isKindOfClass:NSDictionary.class] && [j2[@"version"] isKindOfClass:NSString.class]) {
                    sdvParseAndStoreRemoteUpdateDict(j2, NO);
                    [sess finishTasksAndInvalidate];
                    return;
                }
            }
            NSMutableURLRequest *fbReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kSDVLatestReleaseApiURL]];
            fbReq.timeoutInterval = 6.0;
            [fbReq setValue:ua forHTTPHeaderField:@"User-Agent"];
            [fbReq setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
            [[sess dataTaskWithRequest:fbReq completionHandler:^(NSData *fbData, NSURLResponse *fbResp, NSError *fbErr) {
                NSHTTPURLResponse *fbHttp = [fbResp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)fbResp : nil;
                if (!fbErr && fbHttp.statusCode == 200 && fbData.length > 16) {
                    NSDictionary *fbJson = [NSJSONSerialization JSONObjectWithData:fbData options:0 error:nil];
                    if ([fbJson isKindOfClass:NSDictionary.class] && [fbJson[@"tag_name"] isKindOfClass:NSString.class]) {
                        sdvParseAndStoreRemoteUpdateDict(fbJson, YES);
                        [sess finishTasksAndInvalidate];
                        return;
                    }
                }
                sdvCompletePendingUpdateCallbacks(nil, @"Không thể kết nối kiểm tra cập nhật. Vui lòng thử lại khi có mạng.", NO);
                [sess finishTasksAndInvalidate];
            }] resume];
        }] resume];
    }] resume];
}
