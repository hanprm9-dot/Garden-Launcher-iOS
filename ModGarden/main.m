#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import "History.m"
#import "UiConfig.m"
#import "AppleTheme.m"
#import "RamMonitor.m"
#import "SaveManager.m"
#import "BugReport.m"

static NSString *sdvAppDisplayName(void) {
    NSString *n = NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"];
    return n.length ? n : @"Garden Launcher";
}

// ---- POSIX Network Helpers (universal iOS 14 - iOS 26+) ----
static NSArray<NSDictionary *> *sdvLocalIPv4Interfaces(void) {
    NSMutableArray *list = [NSMutableArray array];
    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) != 0 || !addrs) return list;
    for (struct ifaddrs *cur = addrs; cur != NULL; cur = cur->ifa_next) {
        if (!cur->ifa_addr || cur->ifa_addr->sa_family != AF_INET) continue;
        unsigned int flags = cur->ifa_flags;
        if (!(flags & IFF_UP) || (flags & IFF_LOOPBACK)) continue;
        char ipBuf[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
        if (!inet_ntop(AF_INET, &sin->sin_addr, ipBuf, sizeof(ipBuf))) continue;
        NSString *name = [NSString stringWithUTF8String:cur->ifa_name ?: ""];
        NSString *ip = [NSString stringWithUTF8String:ipBuf];
        if ([ip hasPrefix:@"169.254."] || [ip hasPrefix:@"127."]) continue;
        NSString *kind = @"Mạng khác";
        NSInteger order = 2;
        if ([name isEqualToString:@"en0"] || [name hasPrefix:@"en"]) {
            kind = @"Wi-Fi / LAN";
            order = 0;
        } else if ([name hasPrefix:@"utun"] || [name hasPrefix:@"ipsec"] || [name hasPrefix:@"ppp"]) {
            kind = @"VPN / Tailscale / ZeroTier";
            order = 1;
        } else if ([name hasPrefix:@"pdp_ip"]) {
            kind = @"Di động (4G/5G)";
            order = 3;
        }
        [list addObject:@{@"iface": name, @"ip": ip, @"kind": kind, @"order": @(order)}];
    }
    freeifaddrs(addrs);
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult r = [a[@"order"] compare:b[@"order"]];
        return r != NSOrderedSame ? r : [a[@"iface"] compare:b[@"iface"]];
    }];
    return list;
}

static NSString *sdvProbeLocalNetwork(void) {
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) return @"Không mở được UDP socket trên thiết bị.";
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));

    struct sockaddr_in bindAddr;
    memset(&bindAddr, 0, sizeof(bindAddr));
    bindAddr.sin_family = AF_INET;
    bindAddr.sin_addr.s_addr = htonl(INADDR_ANY);
    bindAddr.sin_port = htons(0);
    if (bind(fd, (struct sockaddr *)&bindAddr, sizeof(bindAddr)) != 0) {
        int e = errno;
        close(fd);
        return [NSString stringWithFormat:@"Lỗi bind UDP (errno %d).", e];
    }

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(24642);
    dst.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    unsigned char ping[1] = {0};
    ssize_t sent = sendto(fd, ping, 1, 0, (struct sockaddr *)&dst, sizeof(dst));
    int sendErr = (sent < 0) ? errno : 0;

    NSArray<NSDictionary *> *ifaces = sdvLocalIPv4Interfaces();
    for (NSDictionary *info in ifaces) {
        if ([info[@"order"] integerValue] == 0) {
            NSArray *oct = [info[@"ip"] componentsSeparatedByString:@"."];
            if (oct.count == 4) {
                NSString *subBc = [NSString stringWithFormat:@"%@.%@.%@.255", oct[0], oct[1], oct[2]];
                if (inet_pton(AF_INET, subBc.UTF8String, &dst.sin_addr) == 1) {
                    ssize_t s2 = sendto(fd, ping, 1, 0, (struct sockaddr *)&dst, sizeof(dst));
                    if (s2 >= 0) { sent = s2; sendErr = 0; }
                }
            }
            break;
        }
    }
    close(fd);

    if (sent >= 0) {
        return @"UDP cổng 24642 đã sẵn sàng! Nếu iOS hiện bảng hỏi 'Mạng cục bộ', hãy chọn Cho phép (Allow).";
    }
    if (sendErr == EHOSTUNREACH || sendErr == EACCES || sendErr == EPERM) {
        return [NSString stringWithFormat:@"iOS đang chặn quyền Mạng cục bộ. Vào Cài đặt → Quyền riêng tư & Bảo mật → Mạng cục bộ → bật %@.", sdvAppDisplayName()];
    }
    return [NSString stringWithFormat:@"Đã kiểm tra UDP (mã %d). Đảm bảo iPhone đang bật Wi-Fi hoặc Tailscale/ZeroTier.", sendErr];
}

// ---- Native iOS Rounded Screen Preview for Menu Bar ----
@interface SDVMenuBarPreviewView : UIView
@property(nonatomic, strong) SDVUiConfig *config;
-(void)updateWithConfig:(SDVUiConfig *)cfg;
@end

@implementation SDVMenuBarPreviewView {
    UIView *_island;
    UIView *_clockBox;
    UILabel *_clockLabel;
    UIView *_barContainer;
    NSArray<UIView *> *_pills;
    NSArray<UILabel *> *_pillLabels;
}

-(instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = rgb(0x4EA354);
        self.layer.cornerRadius = 11.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = kSepColor.CGColor;
        self.clipsToBounds = YES;

        UIView *sky = [UIView new];
        sky.backgroundColor = rgb(0x52B2DE);
        sky.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:sky];
        [NSLayoutConstraint activateConstraints:@[
            [sky.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [sky.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [sky.topAnchor constraintEqualToAnchor:self.topAnchor],
            [sky.heightAnchor constraintEqualToConstant:36]
        ]];

        UIView *ground = [UIView new];
        ground.backgroundColor = rgb(0xC28B4E);
        ground.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:ground];
        [NSLayoutConstraint activateConstraints:@[
            [ground.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [ground.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [ground.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [ground.heightAnchor constraintEqualToConstant:10]
        ]];

        _island = [UIView new];
        _island.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        _island.layer.cornerRadius = 3.0;
        [self addSubview:_island];

        _clockBox = [UIView new];
        _clockBox.backgroundColor = rgba(0xFFF6DE, 0.94);
        _clockBox.layer.cornerRadius = 5.0;
        _clockBox.layer.borderWidth = 0.5;
        _clockBox.layer.borderColor = rgba(0x6E4222, 0.45).CGColor;
        _clockLabel = mkLabel(@"9:40 AM", 9, UIFontWeightSemibold, rgb(0x4B2B14));
        _clockLabel.font = iosMonoDigits(9, UIFontWeightSemibold);
        _clockLabel.textAlignment = NSTextAlignmentCenter;
        [_clockBox addSubview:_clockLabel];
        pinAll(_clockLabel, _clockBox, 1);
        [self addSubview:_clockBox];

        _barContainer = [UIView new];
        [self addSubview:_barContainer];

        NSArray *titles = @[@"HIDE", @"SET", @"KEY", @"MENU", @"MODS"];
        NSArray *colors = @[rgba(0x1C2A32, 0.88), rgba(0x1C2A32, 0.88), rgba(0x224455, 0.88), rgba(0x664024, 0.88), rgba(0x483B66, 0.88)];
        NSMutableArray *ps = [NSMutableArray array];
        NSMutableArray *ls = [NSMutableArray array];
        for (NSUInteger i = 0; i < titles.count; i++) {
            UIView *pill = [UIView new];
            pill.backgroundColor = colors[i];
            pill.layer.cornerRadius = 4.0;
            pill.layer.cornerCurve = kCACornerCurveContinuous;
            UILabel *lbl = mkLabel(titles[i], 8.5, UIFontWeightSemibold, UIColor.whiteColor);
            lbl.textAlignment = NSTextAlignmentCenter;
            lbl.adjustsFontSizeToFitWidth = YES;
            lbl.minimumScaleFactor = 0.5;
            [pill addSubview:lbl];
            pinInsets(lbl, pill, UIEdgeInsetsMake(1, 2, 1, 2));
            [_barContainer addSubview:pill];
            [ps addObject:pill];
            [ls addObject:lbl];
        }
        _pills = ps;
        _pillLabels = ls;
    }
    return self;
}

-(void)updateWithConfig:(SDVUiConfig *)cfg {
    _config = cfg;
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

-(void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w < 10 || h < 10) return;

    _island.frame = CGRectMake(4, (h - 24) * 0.5, 5, 24);
    _clockBox.frame = CGRectMake(w - 58, 6, 52, 20);
    _barContainer.frame = self.bounds;

    SDVUiConfig *c = _config ?: [SDVUiConfig new];
    CGFloat ratio = w / 1600.0;
    CGFloat mbScale = c.menuBarScale;
    CGFloat topY = MAX(4.0, c.menuBarTopY * ratio * 1.15);
    CGFloat curX = MAX(14.0, c.menuBarLeftX * ratio * 1.15);
    CGFloat btnH = MAX(12.0, MIN(h - topY - 4.0, 42.0 * mbScale * ratio * 1.35));
    CGFloat baseW = 64.0 * mbScale * ratio * 1.35;
    CGFloat gap = MAX(2.0, c.menuBarGap * ratio * 1.25);

    NSArray<NSNumber *> *widths = @[@(baseW), @(baseW), @(baseW), @(68.0 * mbScale * ratio * 1.35), @(72.0 * mbScale * ratio * 1.35)];
    NSArray<NSNumber *> *visible = @[@YES, @YES, @(c.showKeyboardBtn), @(c.showMenuBtn), @(c.showHotkeyDrawerBtn)];
    CGFloat alpha = sdvClampf(c.menuBarOpacity, 0.10f, 1.00f);

    for (NSUInteger i = 0; i < _pills.count; i++) {
        UIView *p = _pills[i];
        BOOL show = visible[i].boolValue;
        p.hidden = !show;
        if (!show) continue;
        CGFloat bw = MAX(18.0, widths[i].doubleValue);
        p.frame = CGRectMake(curX, topY, bw, btnH);
        p.alpha = alpha;
        _pillLabels[i].font = iosFont(MAX(7.0, MIN(12.0, btnH * 0.42)), UIFontWeightSemibold);
        curX += bw + gap;
    }
}
@end

// ============================================================================
// ANIMATED DISCORD COMMUNITY COMPONENTS (Aurora Mesh · Vector Clyde · Sparkles)
// ============================================================================
static UIBezierPath *sdvDiscordClydePath(CGRect box) {
    CGFloat ox = box.origin.x;
    CGFloat oy = box.origin.y;
    CGFloat sx = box.size.width / 24.0;
    CGFloat sy = box.size.height / 24.0;
    UIBezierPath *p = [UIBezierPath bezierPath];
    p.usesEvenOddFillRule = YES;
    #define DCP(px, py) CGPointMake(ox + (px) * sx, oy + (py) * sy)
    [p moveToPoint:DCP(20.3170, 4.3698)];
    [p addCurveToPoint:DCP(15.4319, 2.8546) controlPoint1:DCP(18.7610, 3.6556) controlPoint2:DCP(17.1189, 3.1462)];
    [p addCurveToPoint:DCP(15.3534, 2.8917) controlPoint1:DCP(15.4006, 2.8488) controlPoint2:DCP(15.3688, 2.8638)];
    [p addCurveToPoint:DCP(14.7451, 4.1412) controlPoint1:DCP(15.1424, 3.2670) controlPoint2:DCP(14.9087, 3.7565)];
    [p addCurveToPoint:DCP(9.2583, 4.1412) controlPoint1:DCP(12.9004, 3.8650) controlPoint2:DCP(11.0651, 3.8650)];
    [p addCurveToPoint:DCP(8.6406, 2.8917) controlPoint1:DCP(9.0947, 3.7479) controlPoint2:DCP(8.8525, 3.2670)];
    [p addCurveToPoint:DCP(8.5621, 2.8547) controlPoint1:DCP(8.6246, 2.8645) controlPoint2:DCP(8.5933, 2.8497)];
    [p addCurveToPoint:DCP(3.6769, 4.3697) controlPoint1:DCP(6.8749, 3.1457) controlPoint2:DCP(5.2327, 3.6549)];
    [p addCurveToPoint:DCP(3.6448, 4.3974) controlPoint1:DCP(3.6636, 4.3754) controlPoint2:DCP(3.6524, 4.3851)];
    [p addCurveToPoint:DCP(0.0992, 18.0578) controlPoint1:DCP(0.5334, 9.0458) controlPoint2:DCP(-0.3190, 13.5799)];
    [p addCurveToPoint:DCP(0.1304, 18.1139) controlPoint1:DCP(0.1016, 18.0799) controlPoint2:DCP(0.1129, 18.1002)];
    [p addCurveToPoint:DCP(6.1233, 21.1433) controlPoint1:DCP(2.1832, 19.6215) controlPoint2:DCP(4.1717, 20.5367)];
    [p addCurveToPoint:DCP(6.2075, 21.1157) controlPoint1:DCP(6.1543, 21.1526) controlPoint2:DCP(6.1880, 21.1415)];
    [p addCurveToPoint:DCP(7.4335, 19.1215) controlPoint1:DCP(6.6691, 20.4853) controlPoint2:DCP(7.0806, 19.8205)];
    [p addCurveToPoint:DCP(7.4364, 19.0593) controlPoint1:DCP(7.4433, 19.1021) controlPoint2:DCP(7.4444, 19.0795)];
    [p addCurveToPoint:DCP(7.3919, 19.0158) controlPoint1:DCP(7.4285, 19.0391) controlPoint2:DCP(7.4123, 19.0233)];
    [p addCurveToPoint:DCP(5.5197, 18.1235) controlPoint1:DCP(6.7391, 18.7682) controlPoint2:DCP(6.1176, 18.4663)];
    [p addCurveToPoint:DCP(5.4818, 18.0617) controlPoint1:DCP(5.4976, 18.1105) controlPoint2:DCP(5.4834, 18.0873)];
    [p addCurveToPoint:DCP(5.5121, 17.9958) controlPoint1:DCP(5.4803, 18.0361) controlPoint2:DCP(5.4917, 18.0113)];
    [p addCurveToPoint:DCP(5.8839, 17.7044) controlPoint1:DCP(5.6379, 17.9015) controlPoint2:DCP(5.7638, 17.8035)];
    [p addCurveToPoint:DCP(5.9615, 17.6939) controlPoint1:DCP(5.9056, 17.6865) controlPoint2:DCP(5.9358, 17.6824)];
    [p addCurveToPoint:DCP(18.0229, 17.6939) controlPoint1:DCP(9.8893, 19.4872) controlPoint2:DCP(14.1415, 19.4872)];
    [p addCurveToPoint:DCP(18.1014, 17.7034) controlPoint1:DCP(18.0487, 17.6816) controlPoint2:DCP(18.0793, 17.6854)];
    [p addCurveToPoint:DCP(18.4742, 17.9958) controlPoint1:DCP(18.2216, 17.8024) controlPoint2:DCP(18.3474, 17.9015)];
    [p addCurveToPoint:DCP(18.5049, 18.0614) controlPoint1:DCP(18.4947, 18.0112) controlPoint2:DCP(18.5062, 18.0358)];
    [p addCurveToPoint:DCP(18.4676, 18.1234) controlPoint1:DCP(18.5035, 18.0869) controlPoint2:DCP(18.4896, 18.1102)];
    [p addCurveToPoint:DCP(16.5946, 19.0148) controlPoint1:DCP(17.8695, 18.4727) controlPoint2:DCP(17.2429, 18.7709)];
    [p addCurveToPoint:DCP(16.5504, 19.0590) controlPoint1:DCP(16.5742, 19.0226) controlPoint2:DCP(16.5582, 19.0387)];
    [p addCurveToPoint:DCP(16.5539, 19.1215) controlPoint1:DCP(16.5426, 19.0794) controlPoint2:DCP(16.5439, 19.1021)];
    [p addCurveToPoint:DCP(17.7789, 21.1147) controlPoint1:DCP(16.9143, 19.8195) controlPoint2:DCP(17.3258, 20.4843)];
    [p addCurveToPoint:DCP(17.8631, 21.1433) controlPoint1:DCP(17.7978, 21.1413) controlPoint2:DCP(17.8319, 21.1529)];
    [p addCurveToPoint:DCP(23.8654, 18.1139) controlPoint1:DCP(19.8241, 20.5366) controlPoint2:DCP(21.8126, 19.6214)];
    [p addCurveToPoint:DCP(23.8967, 18.0587) controlPoint1:DCP(23.8833, 18.1009) controlPoint2:DCP(23.8947, 18.0807)];
    [p addCurveToPoint:DCP(20.3482, 4.3983) controlPoint1:DCP(24.3971, 12.8817) controlPoint2:DCP(23.0585, 8.3848)];
    [p addCurveToPoint:DCP(20.3170, 4.3697) controlPoint1:DCP(20.3415, 4.3854) controlPoint2:DCP(20.3305, 4.3752)];
    [p closePath];
    // Left eye cutout
    [p moveToPoint:DCP(8.0200, 15.3312)];
    [p addCurveToPoint:DCP(5.8631, 12.9122) controlPoint1:DCP(6.8375, 15.3312) controlPoint2:DCP(5.8631, 14.2455)];
    [p addCurveToPoint:DCP(8.0201, 10.4933) controlPoint1:DCP(5.8631, 11.5790) controlPoint2:DCP(6.8186, 10.4933)];
    [p addCurveToPoint:DCP(10.1769, 12.9123) controlPoint1:DCP(9.2309, 10.4933) controlPoint2:DCP(10.1958, 11.5885)];
    [p addCurveToPoint:DCP(8.0200, 15.3312) controlPoint1:DCP(10.1769, 14.2455) controlPoint2:DCP(9.2214, 15.3312)];
    [p closePath];
    // Right eye cutout
    [p moveToPoint:DCP(15.9948, 15.3312)];
    [p addCurveToPoint:DCP(13.8379, 12.9122) controlPoint1:DCP(14.8123, 15.3312) controlPoint2:DCP(13.8379, 14.2455)];
    [p addCurveToPoint:DCP(15.9948, 10.4933) controlPoint1:DCP(13.8379, 11.5790) controlPoint2:DCP(14.7933, 10.4933)];
    [p addCurveToPoint:DCP(18.1516, 12.9123) controlPoint1:DCP(17.2056, 10.4933) controlPoint2:DCP(18.1705, 11.5885)];
    [p addCurveToPoint:DCP(15.9948, 15.3312) controlPoint1:DCP(18.1516, 14.2455) controlPoint2:DCP(17.2056, 15.3312)];
    [p closePath];
    #undef DCP
    return p;
}

static UIImage *sdvDiscordClydeImage(CGFloat ptSize, UIColor *fillColor) {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *ren = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(ptSize, ptSize) format:fmt];
    return [ren imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [(fillColor ?: UIColor.whiteColor) setFill];
        [sdvDiscordClydePath(CGRectMake(0, 0, ptSize, ptSize)) fill];
    }];
}

static UIBezierPath *sdvFourPointStarPath(CGFloat r) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    CGFloat c = r * 0.22;
    [p moveToPoint:CGPointMake(0, -r)];
    [p addQuadCurveToPoint:CGPointMake(r, 0) controlPoint:CGPointMake(c, -c)];
    [p addQuadCurveToPoint:CGPointMake(0, r) controlPoint:CGPointMake(c, c)];
    [p addQuadCurveToPoint:CGPointMake(-r, 0) controlPoint:CGPointMake(-c, c)];
    [p addQuadCurveToPoint:CGPointMake(0, -r) controlPoint:CGPointMake(-c, -c)];
    [p closePath];
    return p;
}

static void sdvSpawnDiscordSparkleBurst(UIView *hostView, CGPoint origin, CGFloat maxDist) {
    if (!hostView || UIAccessibilityIsReduceMotionEnabled()) return;
    NSArray<UIColor *> *palette = @[
        UIColor.whiteColor,
        rgb(0xFDE047), // Stardew Gold
        rgb(0x34D399), // Live Emerald
        rgb(0x67E8F9), // Crystal Cyan
        rgb(0xC084FC)  // Amethyst Violet
    ];
    NSInteger count = 14;
    for (NSInteger i = 0; i < count; i++) {
        CAShapeLayer *sp = [CAShapeLayer layer];
        BOOL isStar = (i % 2 == 0);
        CGFloat sz = isStar ? (5.2 + (i % 3) * 1.4) : (2.6 + (i % 2) * 1.0);
        sp.path = isStar ? sdvFourPointStarPath(sz).CGPath : [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-sz, -sz, sz * 2.0, sz * 2.0)].CGPath;
        sp.fillColor = palette[(NSUInteger)i % palette.count].CGColor;
        sp.position = origin;
        [hostView.layer addSublayer:sp];

        CGFloat baseAng = ((CGFloat)i / (CGFloat)count) * (CGFloat)(M_PI * 2.0) + ((i % 3) - 1) * 0.11;
        CGFloat dist = maxDist * (0.58 + (CGFloat)((i * 37) % 45) / 100.0);
        CGPoint dst = CGPointMake(origin.x + cos(baseAng) * dist, origin.y + sin(baseAng) * dist);

        CABasicAnimation *posAnim = [CABasicAnimation animationWithKeyPath:@"position"];
        posAnim.fromValue = [NSValue valueWithCGPoint:origin];
        posAnim.toValue = [NSValue valueWithCGPoint:dst];
        posAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];

        CAKeyframeAnimation *scAnim = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        scAnim.values = @[@(0.25), @(1.25), @(0.85), @(0.05)];
        scAnim.keyTimes = @[@(0.0), @(0.28), @(0.72), @(1.0)];

        CABasicAnimation *rotAnim = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rotAnim.fromValue = @(0.0);
        rotAnim.toValue = @((i % 2 == 0 ? 1.0 : -1.0) * M_PI * 0.85);

        CAKeyframeAnimation *opAnim = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        opAnim.values = @[@(1.0), @(1.0), @(0.0)];
        opAnim.keyTimes = @[@(0.0), @(0.55), @(1.0)];

        CAAnimationGroup *grp = [CAAnimationGroup animation];
        grp.animations = @[posAnim, scAnim, rotAnim, opAnim];
        grp.duration = 0.56;
        grp.fillMode = kCAFillModeForwards;
        grp.removedOnCompletion = NO;
        [sp addAnimation:grp forKey:@"sdvSparkleBurst"];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [sp removeFromSuperlayer];
        });
    }
}

// Compact Animated Top-Bar Pill (visible across all 9 tabs!)
@interface SDVDiscordPillControl : UIControl
-(void)playTapCelebration;
@end

@implementation SDVDiscordPillControl {
    CAGradientLayer *_bgGrad;
    CAGradientLayer *_sheenGrad;
    UIImageView *_clydeView;
    UILabel *_titleLbl;
    UIView *_dotWrap;
    CAShapeLayer *_radarRing;
}

-(instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 13.5;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.75;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;
        self.clipsToBounds = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self.heightAnchor constraintEqualToConstant:27.0].active = YES;
        [self setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        _bgGrad = [CAGradientLayer layer];
        _bgGrad.colors = @[
            (id)rgb(0x4F46E5).CGColor,
            (id)rgb(0x5865F2).CGColor,
            (id)rgb(0x7C3AED).CGColor
        ];
        _bgGrad.startPoint = CGPointMake(0.0, 0.15);
        _bgGrad.endPoint = CGPointMake(1.0, 0.85);
        [self.layer addSublayer:_bgGrad];

        _sheenGrad = [CAGradientLayer layer];
        _sheenGrad.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.28].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
        ];
        _sheenGrad.startPoint = CGPointMake(0.0, 0.0);
        _sheenGrad.endPoint = CGPointMake(1.0, 0.35);
        _sheenGrad.locations = @[@(-0.8), @(-0.4), @(0.0)];
        [self.layer addSublayer:_sheenGrad];

        UIStackView *row = mkHStack(5.5);
        row.userInteractionEnabled = NO;

        _clydeView = [[UIImageView alloc] initWithImage:sdvDiscordClydeImage(14.5, UIColor.whiteColor)];
        _clydeView.contentMode = UIViewContentModeScaleAspectFit;
        _clydeView.translatesAutoresizingMaskIntoConstraints = NO;
        [_clydeView.widthAnchor constraintEqualToConstant:14.5].active = YES;
        [_clydeView.heightAnchor constraintEqualToConstant:14.5].active = YES;

        _titleLbl = mkLabel(@"Discord", 11.5, UIFontWeightBold, UIColor.whiteColor);
        _titleLbl.numberOfLines = 1;

        _dotWrap = [UIView new];
        _dotWrap.translatesAutoresizingMaskIntoConstraints = NO;
        [_dotWrap.widthAnchor constraintEqualToConstant:8.0].active = YES;
        [_dotWrap.heightAnchor constraintEqualToConstant:8.0].active = YES;

        _radarRing = [CAShapeLayer layer];
        _radarRing.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(1.0, 1.0, 6.0, 6.0)].CGPath;
        _radarRing.fillColor = rgb(0x4ADE80).CGColor;
        _radarRing.frame = CGRectMake(0, 0, 8.0, 8.0);
        [_dotWrap.layer addSublayer:_radarRing];

        UIView *coreDot = [[UIView alloc] initWithFrame:CGRectMake(1.0, 1.0, 6.0, 6.0)];
        coreDot.backgroundColor = rgb(0x22C55E);
        coreDot.layer.cornerRadius = 3.0;
        coreDot.layer.borderWidth = 0.75;
        coreDot.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
        [_dotWrap addSubview:coreDot];

        [row addArrangedSubview:_clydeView];
        [row addArrangedSubview:_titleLbl];
        [row addArrangedSubview:_dotWrap];
        [self addSubview:row];
        pinInsets(row, self, UIEdgeInsetsMake(4, 10, 4, 9));

        [self updateStatsLabelAnimated:NO];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onStatsUpdated:) name:kSDVDiscordStatsNotification object:nil];
    }
    return self;
}

-(void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

-(void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self startAmbientAnimations];
}

-(void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _bgGrad.frame = self.bounds;
    _sheenGrad.frame = CGRectInset(self.bounds, -16.0, 0);
    [CATransaction commit];
}

-(void)onStatsUpdated:(NSNotification *)n {
    (void)n;
    [self updateStatsLabelAnimated:YES];
}

-(void)updateStatsLabelAnimated:(BOOL)animated {
    NSInteger on = sdvDiscordOnlineCount();
    NSString *txt = (on > 0) ? [NSString stringWithFormat:@"Discord · %ld", (long)on] : @"Discord";
    if ([_titleLbl.text isEqualToString:txt]) return;
    if (animated && !UIAccessibilityIsReduceMotionEnabled()) {
        [UIView transitionWithView:_titleLbl duration:0.22 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            self->_titleLbl.text = txt;
        } completion:nil];
    } else {
        _titleLbl.text = txt;
    }
}

-(void)startAmbientAnimations {
    if (sdvShouldPauseAmbientEffects()) return;
    if (![_sheenGrad animationForKey:@"sdvPillSheen"]) {
        CABasicAnimation *sh = [CABasicAnimation animationWithKeyPath:@"locations"];
        sh.fromValue = @[@(-0.85), @(-0.42), @(0.0)];
        sh.toValue = @[@(1.0), @(1.42), @(1.85)];
        sh.duration = 3.6;
        sh.repeatCount = HUGE_VALF;
        sh.removedOnCompletion = NO;
        [_sheenGrad addAnimation:sh forKey:@"sdvPillSheen"];
    }
    if (![_radarRing animationForKey:@"sdvPillRadar"]) {
        CABasicAnimation *sc = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        sc.fromValue = @(1.0);
        sc.toValue = @(2.35);
        CABasicAnimation *op = [CABasicAnimation animationWithKeyPath:@"opacity"];
        op.fromValue = @(0.85);
        op.toValue = @(0.0);
        CAAnimationGroup *g = [CAAnimationGroup animation];
        g.animations = @[sc, op];
        g.duration = 1.85;
        g.repeatCount = HUGE_VALF;
        g.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        g.removedOnCompletion = NO;
        [_radarRing addAnimation:g forKey:@"sdvPillRadar"];
    }
    if (![_clydeView.layer animationForKey:@"sdvPillBob"]) {
        CABasicAnimation *bob = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        bob.fromValue = @(-0.9);
        bob.toValue = @(0.9);
        bob.duration = 1.6;
        bob.autoreverses = YES;
        bob.repeatCount = HUGE_VALF;
        bob.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        bob.removedOnCompletion = NO;
        [_clydeView.layer addAnimation:bob forKey:@"sdvPillBob"];
    }
}

-(void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if (highlighted) {
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    }
    [UIView animateWithDuration:(highlighted ? 0.11 : 0.36)
                          delay:0
         usingSpringWithDamping:(highlighted ? 1.0 : 0.52)
          initialSpringVelocity:(highlighted ? 0.0 : 0.85)
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.92, 0.92) : CGAffineTransformIdentity;
        self.alpha = highlighted ? 0.88 : 1.0;
    } completion:nil];
}

-(void)playTapCelebration {
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        CAKeyframeAnimation *spin = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.values = @[@(0.0), @(-0.22), @(M_PI * 2.0)];
        spin.keyTimes = @[@(0.0), @(0.18), @(1.0)];
        spin.duration = 0.45;
        spin.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_clydeView.layer addAnimation:spin forKey:@"sdvTapSpin"];

        if (self.superview) {
            CGPoint pt = [self.superview convertPoint:CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds)) fromView:self];
            sdvSpawnDiscordSparkleBurst(self.superview, pt, 34.0);
        }
    }
}
@end

// Full Interactive Hero Discord Community Card (Tab 0 Setup/Install, Tab 4 Co-op, Tab 7 Credit)
@interface SDVDiscordHeroCard : UIControl
-(instancetype)initWithCustomSubtitle:(NSString *)customSubtitle;
-(void)playTapCelebration;
@end

@implementation SDVDiscordHeroCard {
    CAGradientLayer *_auroraGrad;
    CAGradientLayer *_orbCyan;
    CAGradientLayer *_orbViolet;
    CAGradientLayer *_sheenGrad;
    UIView *_mascotBox;
    UIImageView *_clydeView;
    NSArray<CAShapeLayer *> *_starLayers;
    CAShapeLayer *_liveRadarRing;
    UILabel *_liveStatsLbl;
    UIView *_ctaPill;
    UIImageView *_ctaArrow;
}

-(instancetype)initWithCustomSubtitle:(NSString *)customSubtitle {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.layer.cornerRadius = 16.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.26].CGColor;
        self.clipsToBounds = YES;

        // 1. Deep Cosmic Blurple -> Indigo -> Amethyst Aurora Gradient
        _auroraGrad = [CAGradientLayer layer];
        _auroraGrad.colors = @[
            (id)rgb(0x312E81).CGColor,
            (id)rgb(0x4F46E5).CGColor,
            (id)rgb(0x5865F2).CGColor,
            (id)rgb(0x7C3AED).CGColor
        ];
        _auroraGrad.locations = @[@(0.0), @(0.35), @(0.70), @(1.0)];
        _auroraGrad.startPoint = CGPointMake(0.0, 0.0);
        _auroraGrad.endPoint = CGPointMake(1.0, 1.0);
        [self.layer addSublayer:_auroraGrad];

        // 2. Soft Drifting Radial Glow Orbs
        _orbCyan = [CAGradientLayer layer];
        _orbCyan.type = kCAGradientLayerRadial;
        _orbCyan.colors = @[
            (id)[rgb(0x38BDF8) colorWithAlphaComponent:0.32].CGColor,
            (id)[rgb(0x38BDF8) colorWithAlphaComponent:0.0].CGColor
        ];
        _orbCyan.startPoint = CGPointMake(0.5, 0.5);
        _orbCyan.endPoint = CGPointMake(1.0, 1.0);
        [self.layer addSublayer:_orbCyan];

        _orbViolet = [CAGradientLayer layer];
        _orbViolet.type = kCAGradientLayerRadial;
        _orbViolet.colors = @[
            (id)[rgb(0xE879F9) colorWithAlphaComponent:0.28].CGColor,
            (id)[rgb(0xE879F9) colorWithAlphaComponent:0.0].CGColor
        ];
        _orbViolet.startPoint = CGPointMake(0.5, 0.5);
        _orbViolet.endPoint = CGPointMake(1.0, 1.0);
        [self.layer addSublayer:_orbViolet];

        // 3. Holographic Diagonal Shimmer Sweep
        _sheenGrad = [CAGradientLayer layer];
        _sheenGrad.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.18].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
        ];
        _sheenGrad.startPoint = CGPointMake(0.0, 0.0);
        _sheenGrad.endPoint = CGPointMake(1.0, 0.42);
        _sheenGrad.locations = @[@(-0.7), @(-0.35), @(0.0)];
        [self.layer addSublayer:_sheenGrad];

        // 4. Content Row (non-interactive subviews so whole card acts as responsive UIControl)
        UIStackView *mainRow = mkHStack(13.0);
        mainRow.userInteractionEnabled = NO;

        // Left Mascot Stage (54x54) with Frosted Squircle + Levitating Clyde + 4 Twinkling Stars
        UIView *stage = [UIView new];
        stage.translatesAutoresizingMaskIntoConstraints = NO;
        [stage.widthAnchor constraintEqualToConstant:54.0].active = YES;
        [stage.heightAnchor constraintEqualToConstant:54.0].active = YES;
        [stage setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [stage setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        _mascotBox = [UIView new];
        _mascotBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.17];
        _mascotBox.layer.cornerRadius = 14.5;
        _mascotBox.layer.cornerCurve = kCACornerCurveContinuous;
        _mascotBox.layer.borderWidth = 1.0;
        _mascotBox.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.36].CGColor;
        _mascotBox.translatesAutoresizingMaskIntoConstraints = NO;
        [stage addSubview:_mascotBox];
        [NSLayoutConstraint activateConstraints:@[
            [_mascotBox.centerXAnchor constraintEqualToAnchor:stage.centerXAnchor],
            [_mascotBox.centerYAnchor constraintEqualToAnchor:stage.centerYAnchor],
            [_mascotBox.widthAnchor constraintEqualToConstant:48.0],
            [_mascotBox.heightAnchor constraintEqualToConstant:48.0]
        ]];

        _clydeView = [[UIImageView alloc] initWithImage:sdvDiscordClydeImage(27.0, UIColor.whiteColor)];
        _clydeView.contentMode = UIViewContentModeScaleAspectFit;
        _clydeView.translatesAutoresizingMaskIntoConstraints = NO;
        [_mascotBox addSubview:_clydeView];
        [NSLayoutConstraint activateConstraints:@[
            [_clydeView.centerXAnchor constraintEqualToAnchor:_mascotBox.centerXAnchor],
            [_clydeView.centerYAnchor constraintEqualToAnchor:_mascotBox.centerYAnchor],
            [_clydeView.widthAnchor constraintEqualToConstant:27.0],
            [_clydeView.heightAnchor constraintEqualToConstant:27.0]
        ]];

        NSArray<NSValue *> *starPts = @[
            [NSValue valueWithCGPoint:CGPointMake(5.0, 6.0)],
            [NSValue valueWithCGPoint:CGPointMake(49.5, 8.0)],
            [NSValue valueWithCGPoint:CGPointMake(48.0, 47.5)],
            [NSValue valueWithCGPoint:CGPointMake(6.5, 46.5)]
        ];
        NSArray<UIColor *> *starCols = @[rgb(0xFDE047), rgb(0x67E8F9), rgb(0x6EE7B7), UIColor.whiteColor];
        NSArray<NSNumber *> *starRadii = @[@(4.8), @(3.8), @(4.2), @(3.4)];
        NSMutableArray<CAShapeLayer *> *sLayers = [NSMutableArray array];
        for (NSUInteger i = 0; i < starPts.count; i++) {
            CAShapeLayer *st = [CAShapeLayer layer];
            st.path = sdvFourPointStarPath(starRadii[i].doubleValue).CGPath;
            st.fillColor = starCols[i].CGColor;
            st.position = starPts[i].CGPointValue;
            [stage.layer addSublayer:st];
            [sLayers addObject:st];
        }
        _starLayers = sLayers;

        // Center Text Column
        UIStackView *midCol = mkVStack(3.5);

        UIStackView *badgeRow = mkHStack(6.0);
        UILabel *tagPill = mkBadgePill(@"DISCORD CHÍNH THỨC", [UIColor colorWithWhite:1.0 alpha:0.17], rgb(0xE0E7FF), 9.5);

        UIView *livePill = [UIView new];
        livePill.backgroundColor = [rgb(0x052E16) colorWithAlphaComponent:0.52];
        livePill.layer.cornerRadius = 7.5;
        livePill.layer.cornerCurve = kCACornerCurveContinuous;
        livePill.layer.borderWidth = 0.75;
        livePill.layer.borderColor = [rgb(0x4ADE80) colorWithAlphaComponent:0.48].CGColor;
        UIStackView *liveInner = mkHStack(4.5);
        UIView *liveDotBox = [UIView new];
        liveDotBox.translatesAutoresizingMaskIntoConstraints = NO;
        [liveDotBox.widthAnchor constraintEqualToConstant:7.5].active = YES;
        [liveDotBox.heightAnchor constraintEqualToConstant:7.5].active = YES;

        _liveRadarRing = [CAShapeLayer layer];
        _liveRadarRing.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0.75, 0.75, 6.0, 6.0)].CGPath;
        _liveRadarRing.fillColor = rgb(0x4ADE80).CGColor;
        _liveRadarRing.frame = CGRectMake(0, 0, 7.5, 7.5);
        [liveDotBox.layer addSublayer:_liveRadarRing];

        UIView *liveCore = [[UIView alloc] initWithFrame:CGRectMake(0.75, 0.75, 6.0, 6.0)];
        liveCore.backgroundColor = rgb(0x22C55E);
        liveCore.layer.cornerRadius = 3.0;
        [liveDotBox addSubview:liveCore];

        _liveStatsLbl = mkLabel(@"TRỰC TUYẾN", 9.5, UIFontWeightBold, rgb(0x86EFAC));
        _liveStatsLbl.numberOfLines = 1;
        [liveInner addArrangedSubview:liveDotBox];
        [liveInner addArrangedSubview:_liveStatsLbl];
        [livePill addSubview:liveInner];
        pinInsets(liveInner, livePill, UIEdgeInsetsMake(2.5, 6.5, 2.5, 7.0));

        [badgeRow addArrangedSubview:tagPill];
        [badgeRow addArrangedSubview:livePill];
        [badgeRow addArrangedSubview:[UIView new]];

        UILabel *titleLbl = mkLabel(@"Vườn Bách Thú 🦖 · Garden Launcher", 15.0, UIFontWeightBold, UIColor.whiteColor);
        titleLbl.numberOfLines = 1;
        titleLbl.adjustsFontSizeToFitWidth = YES;
        titleLbl.minimumScaleFactor = 0.82;

        NSString *subText = customSubtitle.length
            ? customSubtitle
            : @"Giao lưu Co-op, kho Mod & Việt hóa 1.6, hỏi đáp Haley AI 🌻, nhận bản cập nhật sớm & hỗ trợ sửa lỗi trực tiếp.";
        UILabel *subLbl = mkLabel(subText, 12.0, UIFontWeightRegular, [UIColor colorWithWhite:1.0 alpha:0.90]);
        subLbl.numberOfLines = 3;

        [midCol addArrangedSubview:badgeRow];
        [midCol addArrangedSubview:titleLbl];
        [midCol addArrangedSubview:subLbl];

        // Right Glossy White CTA Pill ("Tham gia ↗")
        _ctaPill = [UIView new];
        _ctaPill.backgroundColor = UIColor.whiteColor;
        _ctaPill.layer.cornerRadius = 17.0;
        _ctaPill.layer.cornerCurve = kCACornerCurveContinuous;
        _ctaPill.translatesAutoresizingMaskIntoConstraints = NO;
        [_ctaPill.heightAnchor constraintEqualToConstant:34.0].active = YES;
        [_ctaPill setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_ctaPill setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        UIStackView *ctaRow = mkHStack(4.5);
        UILabel *ctaLbl = mkLabel(@"Tham gia", 12.5, UIFontWeightBold, rgb(0x4338CA));
        ctaLbl.numberOfLines = 1;
        _ctaArrow = [[UIImageView alloc] initWithImage:sfIcon(@"arrow.up.right", 11.5, UIImageSymbolWeightBold)];
        _ctaArrow.tintColor = rgb(0x4F46E5);
        [ctaRow addArrangedSubview:ctaLbl];
        [ctaRow addArrangedSubview:_ctaArrow];
        [_ctaPill addSubview:ctaRow];
        pinInsets(ctaRow, _ctaPill, UIEdgeInsetsMake(6, 13, 6, 12));

        [mainRow addArrangedSubview:stage];
        [mainRow addArrangedSubview:midCol];
        [mainRow addArrangedSubview:_ctaPill];
        [self addSubview:mainRow];
        pinInsets(mainRow, self, UIEdgeInsetsMake(13, 14, 13, 14));

        [self updateStatsBadgeAnimated:NO];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onStatsChanged:) name:kSDVDiscordStatsNotification object:nil];
    }
    return self;
}

-(void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

-(void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self startHeroAnimations];
}

-(void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _auroraGrad.frame = self.bounds;
    _orbCyan.frame = CGRectMake(w - 140.0, -55.0, 210.0, 210.0);
    _orbViolet.frame = CGRectMake(-50.0, h - 115.0, 190.0, 190.0);
    _sheenGrad.frame = CGRectInset(self.bounds, -40.0, 0);
    [CATransaction commit];
}

-(void)onStatsChanged:(NSNotification *)n {
    (void)n;
    [self updateStatsBadgeAnimated:YES];
}

-(void)updateStatsBadgeAnimated:(BOOL)animated {
    NSInteger on = sdvDiscordOnlineCount();
    NSInteger mem = sdvDiscordMemberCount();
    NSString *txt = (on > 0 && mem > 0)
        ? [NSString stringWithFormat:@"%ld ONLINE · %ld THÀNH VIÊN", (long)on, (long)mem]
        : ((on > 0) ? [NSString stringWithFormat:@"%ld ĐANG ONLINE", (long)on] : @"TRỰC TUYẾN 24/7");
    if ([_liveStatsLbl.text isEqualToString:txt]) return;
    if (animated && !UIAccessibilityIsReduceMotionEnabled()) {
        [UIView transitionWithView:_liveStatsLbl duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
            self->_liveStatsLbl.text = txt;
        } completion:nil];
    } else {
        _liveStatsLbl.text = txt;
    }
}

-(void)startHeroAnimations {
    if (sdvShouldPauseAmbientEffects()) return;

    // 1. Slow breathing Aurora color/angle shift
    if (![_auroraGrad animationForKey:@"sdvAuroraShift"]) {
        CABasicAnimation *sp = [CABasicAnimation animationWithKeyPath:@"startPoint"];
        sp.fromValue = [NSValue valueWithCGPoint:CGPointMake(0.0, 0.0)];
        sp.toValue = [NSValue valueWithCGPoint:CGPointMake(0.25, 0.85)];
        CABasicAnimation *ep = [CABasicAnimation animationWithKeyPath:@"endPoint"];
        ep.fromValue = [NSValue valueWithCGPoint:CGPointMake(1.0, 1.0)];
        ep.toValue = [NSValue valueWithCGPoint:CGPointMake(0.80, 0.15)];
        CAAnimationGroup *ag = [CAAnimationGroup animation];
        ag.animations = @[sp, ep];
        ag.duration = 5.4;
        ag.autoreverses = YES;
        ag.repeatCount = HUGE_VALF;
        ag.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        ag.removedOnCompletion = NO;
        [_auroraGrad addAnimation:ag forKey:@"sdvAuroraShift"];
    }

    // 2. Gentle ambient orb drift
    if (![_orbCyan animationForKey:@"sdvOrbDrift"]) {
        CABasicAnimation *dx = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        dx.fromValue = @(-18.0);
        dx.toValue = @(18.0);
        dx.duration = 4.6;
        dx.autoreverses = YES;
        dx.repeatCount = HUGE_VALF;
        dx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        dx.removedOnCompletion = NO;
        [_orbCyan addAnimation:dx forKey:@"sdvOrbDrift"];
    }
    if (![_orbViolet animationForKey:@"sdvOrbDrift2"]) {
        CABasicAnimation *dy = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        dy.fromValue = @(16.0);
        dy.toValue = @(-16.0);
        dy.duration = 5.2;
        dy.autoreverses = YES;
        dy.repeatCount = HUGE_VALF;
        dy.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        dy.removedOnCompletion = NO;
        [_orbViolet addAnimation:dy forKey:@"sdvOrbDrift2"];
    }

    // 3. Holographic diagonal sheen sweep
    if (![_sheenGrad animationForKey:@"sdvHeroSheen"]) {
        CABasicAnimation *sh = [CABasicAnimation animationWithKeyPath:@"locations"];
        sh.fromValue = @[@(-0.75), @(-0.37), @(0.0)];
        sh.toValue = @[@(1.0), @(1.37), @(1.75)];
        sh.duration = 4.3;
        sh.repeatCount = HUGE_VALF;
        sh.removedOnCompletion = NO;
        [_sheenGrad addAnimation:sh forKey:@"sdvHeroSheen"];
    }

    // 4. Floating & gently rocking Clyde mascot
    if (![_clydeView.layer animationForKey:@"sdvClydeFloat"]) {
        CABasicAnimation *fl = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        fl.fromValue = @(-2.6);
        fl.toValue = @(2.6);
        fl.duration = 2.1;
        fl.autoreverses = YES;
        fl.repeatCount = HUGE_VALF;
        fl.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        fl.removedOnCompletion = NO;
        [_clydeView.layer addAnimation:fl forKey:@"sdvClydeFloat"];

        CABasicAnimation *rk = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        rk.fromValue = @(-0.065);
        rk.toValue = @(0.065);
        rk.duration = 2.9;
        rk.autoreverses = YES;
        rk.repeatCount = HUGE_VALF;
        rk.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        rk.removedOnCompletion = NO;
        [_clydeView.layer addAnimation:rk forKey:@"sdvClydeRock"];
    }

    // 5. Staggered twinkling Stardew/Discord sparkle stars
    for (NSUInteger i = 0; i < _starLayers.count; i++) {
        CAShapeLayer *st = _starLayers[i];
        if ([st animationForKey:@"sdvTwinkle"]) continue;
        CAKeyframeAnimation *op = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        op.values = @[@(0.18), @(1.0), @(0.25), @(0.92), @(0.18)];
        op.keyTimes = @[@(0.0), @(0.28), @(0.55), @(0.80), @(1.0)];

        CAKeyframeAnimation *sc = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        sc.values = @[@(0.55), @(1.18), @(0.68), @(1.05), @(0.55)];
        sc.keyTimes = @[@(0.0), @(0.28), @(0.55), @(0.80), @(1.0)];

        CAAnimationGroup *tg = [CAAnimationGroup animation];
        tg.animations = @[op, sc];
        tg.duration = 2.8 + (double)i * 0.35;
        tg.timeOffset = (double)i * 0.65;
        tg.repeatCount = HUGE_VALF;
        tg.removedOnCompletion = NO;
        [st addAnimation:tg forKey:@"sdvTwinkle"];
    }

    // 6. Live emerald sonar ripple
    if (![_liveRadarRing animationForKey:@"sdvLiveRadar"]) {
        CABasicAnimation *sc = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        sc.fromValue = @(1.0);
        sc.toValue = @(2.5);
        CABasicAnimation *op = [CABasicAnimation animationWithKeyPath:@"opacity"];
        op.fromValue = @(0.85);
        op.toValue = @(0.0);
        CAAnimationGroup *rg = [CAAnimationGroup animation];
        rg.animations = @[sc, op];
        rg.duration = 1.8;
        rg.repeatCount = HUGE_VALF;
        rg.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        rg.removedOnCompletion = NO;
        [_liveRadarRing addAnimation:rg forKey:@"sdvLiveRadar"];
    }

    // 7. Subtle diagonal arrow nudge on CTA pill
    if (![_ctaArrow.layer animationForKey:@"sdvArrowNudge"]) {
        CABasicAnimation *nx = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        nx.fromValue = @(0.0);
        nx.toValue = @(2.0);
        CABasicAnimation *ny = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        ny.fromValue = @(0.0);
        ny.toValue = @(-2.0);
        CAAnimationGroup *ng = [CAAnimationGroup animation];
        ng.animations = @[nx, ny];
        ng.duration = 0.95;
        ng.autoreverses = YES;
        ng.repeatCount = HUGE_VALF;
        ng.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        ng.removedOnCompletion = NO;
        [_ctaArrow.layer addAnimation:ng forKey:@"sdvArrowNudge"];
    }
}

-(void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if (highlighted) {
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    }
    [UIView animateWithDuration:(highlighted ? 0.12 : 0.42)
                          delay:0
         usingSpringWithDamping:(highlighted ? 1.0 : 0.54)
          initialSpringVelocity:(highlighted ? 0.0 : 0.85)
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.968, 0.968) : CGAffineTransformIdentity;
        self->_ctaPill.transform = highlighted ? CGAffineTransformMakeScale(0.93, 0.93) : CGAffineTransformIdentity;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:(highlighted ? 0.58 : 0.26)].CGColor;
    } completion:nil];
}

-(void)playTapCelebration {
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        CAKeyframeAnimation *spin = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.values = @[@(0.0), @(-0.25), @(M_PI * 2.0)];
        spin.keyTimes = @[@(0.0), @(0.18), @(1.0)];
        spin.duration = 0.48;
        spin.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_clydeView.layer addAnimation:spin forKey:@"sdvHeroSpin"];

        CAKeyframeAnimation *pop = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        pop.values = @[@(1.0), @(1.20), @(0.94), @(1.0)];
        pop.keyTimes = @[@(0.0), @(0.32), @(0.70), @(1.0)];
        pop.duration = 0.44;
        [_mascotBox.layer addAnimation:pop forKey:@"sdvHeroPop"];

        CGPoint mascotCenter = [self convertPoint:CGPointMake(CGRectGetMidX(_mascotBox.bounds), CGRectGetMidY(_mascotBox.bounds)) fromView:_mascotBox];
        CGPoint ctaCenter = [self convertPoint:CGPointMake(CGRectGetMidX(_ctaPill.bounds), CGRectGetMidY(_ctaPill.bounds)) fromView:_ctaPill];
        sdvSpawnDiscordSparkleBurst(self, mascotCenter, 46.0);
        sdvSpawnDiscordSparkleBurst(self, ctaCenter, 38.0);
    }
}
@end

// ============================================================
// OFFLINE VISUAL MOD CONFIG.JSON EDITOR (GMCM Pre-Boot Editor)
// ============================================================
@interface SDVModConfigEditorController : UIViewController <UITextFieldDelegate>
@property(nonatomic, copy) NSString *modName;
@property(nonatomic, copy) NSString *configPath;
@property(nonatomic, copy) void (^onSaved)(void);
@end

@implementation SDVModConfigEditorController {
    NSMutableDictionary *_rootDict;
    UIScrollView *_scroll;
    UIStackView *_pane;
    UITextView *_rawTextView;
    BOOL _rawMode;
    NSMutableArray<NSDictionary *> *_fieldBindings; // @{@"dict", @"key", @"tf", @"isNumber"}
}

-(UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

-(void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = kBgCanvas;
    SDVAuroraCanvasView *aurora = [SDVAuroraCanvasView new];
    [self.view insertSubview:aurora atIndex:0];
    pinAll(aurora, self.view, 0);

    _fieldBindings = [NSMutableArray array];
    @try {
        NSData *raw = readFile(self.configPath);
        NSData *san = stripJson5ForIOS14(raw);
        id obj = [NSJSONSerialization JSONObjectWithData:san options:NSJSONReadingMutableContainers | NSJSONReadingMutableLeaves error:nil];
        if ([obj isKindOfClass:NSMutableDictionary.class]) {
            _rootDict = obj;
        }
    } @catch (NSException *ex) { }
    if (!_rootDict) {
        _rawMode = YES;
    }

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    UIVisualEffectView *bar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];

    SDVAppleButton *closeBtn = mkIOSButton(@"Đóng", @"xmark", kBgCardSubtle, kInkPrimary, 13, UIEdgeInsetsMake(6, 11, 6, 11));
    [closeBtn addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];

    UILabel *titleLbl = mkLabel([NSString stringWithFormat:@"⚙️ Cấu hình · %@", self.modName ?: @"config.json"], 15, UIFontWeightSemibold, kInkPrimary);
    titleLbl.lineBreakMode = NSLineBreakByTruncatingTail;

    SDVAppleButton *modeBtn = mkIOSButton(_rawMode ? @"Trực quan" : @"JSON thô", @"curlybraces", [kTintPurple colorWithAlphaComponent:0.14], kTintPurple, 12.5, UIEdgeInsetsMake(6, 10, 6, 10));
    [modeBtn addTarget:self action:@selector(toggleModeTapped:) forControlEvents:UIControlEventTouchUpInside];

    SDVAppleButton *saveBtn = mkIOSButton(@"Lưu config", @"checkmark.circle.fill", kTintGreen, UIColor.whiteColor, 13, UIEdgeInsetsMake(6, 12, 6, 12));
    [saveBtn addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *barRow = mkHStack(8);
    [barRow addArrangedSubview:closeBtn];
    [barRow addArrangedSubview:titleLbl];
    [barRow addArrangedSubview:[UIView new]];
    if (_rootDict) [barRow addArrangedSubview:modeBtn];
    [barRow addArrangedSubview:saveBtn];
    [bar.contentView addSubview:barRow];
    pinInsets(barRow, bar.contentView, UIEdgeInsetsMake(0, 14, 0, 14));

    _scroll = [UIScrollView new];
    _scroll.alwaysBounceVertical = YES;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_scroll];

    _pane = mkVStack(10);
    _pane.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:_pane];

    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:safe.topAnchor constant:46],

        [_scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_pane.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor constant:16],
        [_pane.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [_pane.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:12],
        [_pane.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [_pane.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-32]
    ]];

    [self rebuildBody];
}

-(void)syncTextFieldsIntoDict {
    for (NSDictionary *b in _fieldBindings) {
        NSMutableDictionary *d = b[@"dict"];
        NSString *k = b[@"key"];
        UITextField *tf = b[@"tf"];
        BOOL isNum = [b[@"isNumber"] boolValue];
        NSString *txt = [tf.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
        if (isNum) {
            if ([txt containsString:@"."]) d[k] = @(txt.doubleValue);
            else d[k] = @(txt.longLongValue);
        } else {
            d[k] = txt;
        }
    }
}

-(void)rebuildBody {
    for (UIView *v in [_pane.arrangedSubviews copy]) {
        [_pane removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [_fieldBindings removeAllObjects];
    _rawTextView = nil;

    if (_rawMode || !_rootDict) {
        NSString *pretty = @"";
        if (_rootDict) {
            NSData *pd = [NSJSONSerialization dataWithJSONObject:_rootDict options:NSJSONWritingPrettyPrinted error:nil];
            pretty = pd ? [[NSString alloc] initWithData:pd encoding:NSUTF8StringEncoding] : @"";
        }
        if (!pretty.length) {
            pretty = [NSString stringWithContentsOfFile:self.configPath encoding:NSUTF8StringEncoding error:nil] ?: @"{}";
        }
        UITextView *tv = [UITextView new];
        tv.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightRegular];
        tv.backgroundColor = rgb(0x0F172A);
        tv.textColor = rgb(0xE2E8F0);
        tv.layer.cornerRadius = 12;
        tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
        tv.text = pretty;
        [tv.heightAnchor constraintEqualToConstant:MAX(240.0, self.view.bounds.size.height - 110.0)].active = YES;
        _rawTextView = tv;
        [_pane addArrangedSubview:tv];
        return;
    }

    [_pane addArrangedSubview:mkSectionFooter(@"Chỉnh cấu hình trực tiếp trước khi vào game (thay thế GMCM trên 0% JIT). Bấm \"Lưu config\" ở góc trên phải sau khi chỉnh xong.")];
    [self appendRowsForDict:_rootDict sectionTitle:@"Thiết lập chính"];
}

-(void)appendRowsForDict:(NSMutableDictionary *)dict sectionTitle:(NSString *)secTitle {
    NSArray<NSString *> *keys = [[dict allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray<UIView *> *scalarRows = [NSMutableArray array];
    NSMutableArray<NSString *> *subDictKeys = [NSMutableArray array];

    for (NSString *k in keys) {
        id val = dict[k];
        if ([val isKindOfClass:NSMutableDictionary.class]) {
            [subDictKeys addObject:k];
            continue;
        }
        if ([val isKindOfClass:NSArray.class]) {
            UIStackView *r = mkHStack(8);
            [r addArrangedSubview:mkLabel(k, 13.5, UIFontWeightMedium, kInkPrimary)];
            [r addArrangedSubview:[UIView new]];
            [r addArrangedSubview:mkBadgePill([NSString stringWithFormat:@"Danh sách (%lu mục · dùng JSON thô)", (unsigned long)[(NSArray *)val count]], kBgCardSubtle, kInkSecondary, 11)];
            [scalarRows addObject:r];
            continue;
        }
        if ([val isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)val) == CFBooleanGetTypeID()) {
            UIStackView *r = mkHStack(10);
            [r addArrangedSubview:mkLabel(k, 13.5, UIFontWeightMedium, kInkPrimary)];
            [r addArrangedSubview:[UIView new]];
            UISwitch *sw = [UISwitch new];
            sw.on = [val boolValue];
            sw.onTintColor = kTintGreen;
            sw.transform = CGAffineTransformMakeScale(0.86, 0.86);
            sw.accessibilityIdentifier = k;
            objc_setAssociatedObject(sw, "cfgDict", dict, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [sw addTarget:self action:@selector(boolSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [r addArrangedSubview:sw];
            [scalarRows addObject:r];
            continue;
        }
        BOOL isNum = [val isKindOfClass:NSNumber.class];
        UIStackView *r = mkHStack(8);
        UILabel *kl = mkLabel(k, 13.5, UIFontWeightMedium, kInkPrimary);
        kl.numberOfLines = 1;
        [r addArrangedSubview:kl];
        [r addArrangedSubview:[UIView new]];

        UITextField *tf = [UITextField new];
        tf.text = [val description] ?: @"";
        tf.font = iosMonoDigits(13, UIFontWeightSemibold);
        tf.textColor = kTintBlue;
        tf.textAlignment = NSTextAlignmentRight;
        tf.backgroundColor = kBgCardSubtle;
        tf.layer.cornerRadius = 7;
        tf.returnKeyType = UIReturnKeyDone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.keyboardType = isNum ? UIKeyboardTypeNumbersAndPunctuation : UIKeyboardTypeASCIICapable;
        tf.delegate = self;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [tf.widthAnchor constraintEqualToConstant:isNum ? 110 : 170].active = YES;
        [tf.heightAnchor constraintEqualToConstant:30].active = YES;
        [r addArrangedSubview:tf];

        [_fieldBindings addObject:@{@"dict": dict, @"key": k, @"tf": tf, @"isNumber": @(isNum)}];
        [scalarRows addObject:r];
    }

    if (scalarRows.count) {
        [_pane addArrangedSubview:mkSectionTitle(secTitle)];
        [_pane addArrangedSubview:mkGroupedRows(scalarRows, 14)];
    }
    for (NSString *sk in subDictKeys) {
        NSMutableDictionary *sub = dict[sk];
        if ([sub isKindOfClass:NSMutableDictionary.class]) {
            [self appendRowsForDict:sub sectionTitle:sk];
        }
    }
}

-(void)boolSwitchChanged:(UISwitch *)sw {
    NSMutableDictionary *d = objc_getAssociatedObject(sw, "cfgDict");
    NSString *k = sw.accessibilityIdentifier;
    if (d && k.length) {
        d[k] = sw.isOn ? @YES : @NO;
    }
}

-(BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

-(void)toggleModeTapped:(SDVAppleButton *)btn {
    [self.view endEditing:YES];
    if (_rawMode) {
        NSData *d = [(_rawTextView.text ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
        NSData *san = stripJson5ForIOS14(d);
        NSError *je = nil;
        id obj = san ? [NSJSONSerialization JSONObjectWithData:san options:NSJSONReadingMutableContainers | NSJSONReadingMutableLeaves error:&je] : nil;
        if (![obj isKindOfClass:NSMutableDictionary.class]) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"JSON không hợp lệ" message:je.localizedDescription ?: @"Kiểm tra lại dấu phẩy hoặc ngoặc kép." preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            return;
        }
        _rootDict = obj;
        _rawMode = NO;
        [btn setTitle:@"JSON thô" forState:UIControlStateNormal];
    } else {
        [self syncTextFieldsIntoDict];
        _rawMode = YES;
        [btn setTitle:@"Trực quan" forState:UIControlStateNormal];
    }
    [self rebuildBody];
}

-(void)saveTapped {
    [self.view endEditing:YES];
    NSData *outData = nil;
    if (_rawMode && _rawTextView) {
        NSData *raw = [(_rawTextView.text ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
        NSData *san = stripJson5ForIOS14(raw);
        NSError *je = nil;
        id parsed = san ? [NSJSONSerialization JSONObjectWithData:san options:NSJSONReadingAllowFragments error:&je] : nil;
        if (!parsed) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Lỗi cú pháp JSON" message:je.localizedDescription ?: @"Không thể lưu tệp JSON lỗi." preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            return;
        }
        outData = [NSJSONSerialization dataWithJSONObject:parsed options:NSJSONWritingPrettyPrinted error:nil];
    } else if (_rootDict) {
        [self syncTextFieldsIntoDict];
        outData = [NSJSONSerialization dataWithJSONObject:_rootDict options:NSJSONWritingPrettyPrinted error:nil];
    }
    if (!outData.length) return;
    @try {
        writeFile(outData, self.configPath);
        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
        if (self.onSaved) self.onSaved();
        [self dismissViewControllerAnimated:YES completion:nil];
    } @catch (NSException *ex) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Không lưu được" message:ex.reason ?: @"Lỗi ghi tệp." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

-(void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

#ifdef GARDEN_IN_GAME
#define Home SDVGardenManagerController
#endif

@interface Home : UIViewController <UIDocumentPickerDelegate>
#ifdef GARDEN_IN_GAME
@property(nonatomic, copy) void (^onRequestLiveMenuBarMode)(void);
@property(nonatomic, copy) void (^onRequestClose)(void);
#endif
@end

@implementation Home {
    UIVisualEffectView *_sidebar;
    UIStackView *_sidebarTabs;
    UILabel *_statusLabel;
    UILabel *_navTitleLabel;
    UIScrollView *_scroll;
    UIStackView *_pane;
    SDVBugReportViewController *_bugTabVC;
    UIView *_veil;

    // 0 = Cài Mod, 1 = Thư viện, 2 = File Save, 3 = Hiệu năng & Nút, 4 = Co-op LAN, 5 = Hướng dẫn, 6 = Báo lỗi, 7 = Credit
    NSInteger _tab;
    NSInteger _uiSubTab; // 0 = Menu Bar, 1 = Nút & Joystick, 2 = Bảng SET/MODS
    NSArray<SDVAppleButton *> *_tabButtons;
    UIView *_creditCard;

    NSURL *_root;
    NSString *_stage;
    NSMutableArray<NSString *> *_stagedFiles;
    NSInteger _nextPkgIdx;
    BOOL _appendPick;
    NSString *_last;
    NSString *_message;
    BOOL _messageIsError;
    NSDictionary *_plan;
    NSDictionary *_library;
    NSArray<NSDictionary *> *_catalog;
    NSArray<NSDictionary *> *_modIssues;
    NSArray<NSDictionary *> *_savesList;
    NSArray *_prefs;
    NSMutableDictionary *_translations;
    BOOL _choosingFolder;
    BOOL _importingGameData;
    BOOL _importingSave;

    // Live UI Studio refs
    SDVUiConfig *_uiCfg;
    SDVMobileCtrlConfig *_mobileCfg;
    SDVMenuBarPreviewView *_preview;
    UILabel *_lblPreviewMeta;
    NSMutableDictionary<NSNumber *, UILabel *> *_sliderLabels;
    NSArray<SDVAppleButton *> *_presetButtons;
    NSTimeInterval _lastLiveSave;

    // Live RAM Monitor refs
    UILabel *_ramHeadlineLbl;
    UILabel *_ramDetailLbl;
    UIView *_ramBarTrack;
    UIView *_ramBarFill;
    NSLayoutConstraint *_ramBarFillW;
    NSTimer *_ramUiTimer;
    BOOL _showPcKeyPicker;
    BOOL _tbAutoEnabledBySlider;
    NSInteger _ctrlSectionTab; // 0=Điều khiển, 1=Giao diện, 2=Phím PC, 3=Hiệu năng

    // Live SMAPI / Engine Console Log tab refs
    NSInteger _consoleSource; // 0=SMAPI, 1=Engine, 2=Boot
    NSInteger _consoleFilter; // 0=All, 1=Warn+Err, 2=Info+Warn+Err
    BOOL _consoleAutoScroll;
    BOOL _consolePaused;
    UITextView *_consoleTextView;
    UILabel *_consoleMetaLbl;
    SDVAppleButton *_consoleLiveBtn;
    SDVAppleButton *_consoleScrollBtn;
    NSTimer *_consoleTimer;
    long long _consoleLastSize;
    time_t _consoleLastMtime;
    NSString *_consoleRawCache;
    UILabel *_verPillLabel;

    // v1.1.0 Library Search/Filter & QuickSave Browser state
    NSString *_modSearchQuery;
    NSInteger _modFilterMode; // 0=All, 1=Enabled, 2=Disabled
    NSArray<NSDictionary *> *_quickSlotsList;
}

-(void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_ramUiTimer invalidate];
    _ramUiTimer = nil;
    [_consoleTimer invalidate];
    _consoleTimer = nil;
}

-(void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_root.path.length) {
        if (_root.path.length) sdvMarkHotPatchBootSucceeded(_root.path);
    _uiCfg = [SDVUiConfig loadFromDocuments:_root.path];
        _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
        _savesList = sdvListSaves(_root.path);
        if (_pane) [self renderAll:NO];
    }
}

-(void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_ramUiTimer invalidate];
    _ramUiTimer = nil;
    [_consoleTimer invalidate];
    _consoleTimer = nil;
}

-(BOOL)prefersStatusBarHidden { return YES; }
-(BOOL)prefersHomeIndicatorAutoHidden { return NO; }
-(UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }

#ifdef GARDEN_IN_GAME
-(UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}
#endif

-(void)presentSafely:(UIViewController *)vc {
    if (vc.popoverPresentationController) {
        vc.popoverPresentationController.sourceView = self.view;
        CGRect b = self.view.bounds;
        vc.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(b), CGRectGetMidY(b), 1, 1);
        vc.popoverPresentationController.permittedArrowDirections = (UIPopoverArrowDirection)0;
    }
    [self presentViewController:vc animated:YES completion:nil];
}

-(void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = kBgCanvas;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified; // Follow iOS system Light/Dark Mode!

    _stage = join(NSTemporaryDirectory(), @"ModGardenBatch");
    _stagedFiles = [NSMutableArray array];
    _sliderLabels = [NSMutableDictionary dictionary];
    sdvRemoveItemQuiet(_stage);

#ifdef GARDEN_IN_GAME
    _root = [fm() URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
#else
    NSData *bm = [NSUserDefaults.standardUserDefaults dataForKey:@"gameFolder"];
    if (bm) {
        BOOL stale = NO;
        _root = [NSURL URLByResolvingBookmarkData:bm options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
    }
#endif
    if (_root.path.length) sdvMarkHotPatchBootSucceeded(_root.path);
    _uiCfg = [SDVUiConfig loadFromDocuments:_root.path];
    _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
    _savesList = sdvListSaves(_root.path);
    _tab = 0;
    _uiSubTab = 0;
    _consoleSource = 0;
    _consoleFilter = 0;
    _consoleAutoScroll = YES;
    _consolePaused = NO;

    [self buildShell];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onLauncherUpdateNotification:) name:kSDVUpdateNotification object:nil];
    sdvCheckLauncherUpdate(NO, nil);
    sdvRefreshDiscordLiveStats(NO);
    [self renderAll:NO];
#ifdef GARDEN_IN_GAME
    if (_root && [gameDataStatus(_root.path)[@"ready"] boolValue]) [self refresh];
#else
    if (_root) [self refresh];
#endif
}

-(void)buildShell {
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // Full-menu living Aurora backdrop spanning behind Sidebar, Top Header, Scroll Canvas & Bug Report tab
    SDVAuroraCanvasView *auroraBg = [SDVAuroraCanvasView new];
    [self.view insertSubview:auroraBg atIndex:0];
    pinAll(auroraBg, self.view, 0);

    // Translucent Apple Split-View Sidebar (blurs Aurora ribbons natively on iOS 14–18 Material & iOS 26 Glass)
    _sidebar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    _sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_sidebar];

    UIView *divider = [UIView new];
    divider.backgroundColor = sdvDynamicAuroraCardBorder();
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:divider];

    // Native Apple Top Navigation Header Bar above detail pane
    UIVisualEffectView *topBar = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    topBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:topBar];

    UIView *topSep = mkHairline();
    topSep.backgroundColor = sdvDynamicAuroraCardBorder();
    [topBar.contentView addSubview:topSep];
    [NSLayoutConstraint activateConstraints:@[
        [topSep.leadingAnchor constraintEqualToAnchor:topBar.contentView.leadingAnchor],
        [topSep.trailingAnchor constraintEqualToAnchor:topBar.contentView.trailingAnchor],
        [topSep.bottomAnchor constraintEqualToAnchor:topBar.contentView.bottomAnchor]
    ]];

    UIStackView *topBarRow = mkHStack(8);
    _navTitleLabel = mkLabel(@"Cài Mod", 17, UIFontWeightSemibold, kInkPrimary);
    _navTitleLabel.numberOfLines = 1;
    [topBarRow addArrangedSubview:_navTitleLabel];
    [topBarRow addArrangedSubview:[UIView new]];
    SDVDiscordPillControl *discordTopPill = [SDVDiscordPillControl new];
    [discordTopPill addTarget:self action:@selector(openDiscordServerTapped:) forControlEvents:UIControlEventTouchUpInside];
    [topBarRow addArrangedSubview:discordTopPill];
    _verPillLabel = mkBadgePill(@"v" kSDVAppVersion @" · Native", [kTintBlue colorWithAlphaComponent:0.12], kTintBlue, 11);
    [topBarRow addArrangedSubview:_verPillLabel];
    [topBar.contentView addSubview:topBarRow];
    pinInsets(topBarRow, topBar.contentView, UIEdgeInsetsMake(0, 16, 0, 16));

    _scroll = [UIScrollView new];
    _scroll.backgroundColor = UIColor.clearColor;
    _scroll.alwaysBounceVertical = YES;
    _scroll.showsVerticalScrollIndicator = YES;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_scroll];

    _pane = mkVStack(12);
    _pane.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:_pane];

    // Embedded dedicated Bug Report tab (Tab 6)
    _bugTabVC = [SDVBugReportViewController new];
    _bugTabVC.embeddedInTab = YES;
    _bugTabVC.docsPath = _root.path ?: [fm() URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
    [self addChildViewController:_bugTabVC];
    _bugTabVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    _bugTabVC.view.hidden = YES;
    [self.view addSubview:_bugTabVC.view];
    [_bugTabVC didMoveToParentViewController:self];

    // Scene-safe layout width (no deprecated UIScreen.mainScreen!)
    CGFloat sideW = 196.0;

    [NSLayoutConstraint activateConstraints:@[
        [_sidebar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_sidebar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_sidebar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_sidebar.trailingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:sideW],

        [divider.leadingAnchor constraintEqualToAnchor:_sidebar.trailingAnchor],
        [divider.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [divider.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [divider.widthAnchor constraintEqualToConstant:0.5],

        [topBar.leadingAnchor constraintEqualToAnchor:divider.trailingAnchor],
        [topBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [topBar.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [topBar.bottomAnchor constraintEqualToAnchor:safe.topAnchor constant:44],

        [_scroll.leadingAnchor constraintEqualToAnchor:divider.trailingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:topBar.bottomAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_bugTabVC.view.leadingAnchor constraintEqualToAnchor:divider.trailingAnchor],
        [_bugTabVC.view.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_bugTabVC.view.topAnchor constraintEqualToAnchor:topBar.bottomAnchor],
        [_bugTabVC.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_pane.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor constant:16],
        [_pane.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [_pane.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:12],
        [_pane.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-22],
        [_pane.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-32]
    ]];

    UIStackView *sideStack = mkVStack(8);
    sideStack.translatesAutoresizingMaskIntoConstraints = NO;
    [_sidebar.contentView addSubview:sideStack];
    [NSLayoutConstraint activateConstraints:@[
        [sideStack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10],
        [sideStack.trailingAnchor constraintEqualToAnchor:_sidebar.contentView.trailingAnchor constant:-10],
        [sideStack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        [sideStack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10]
    ]];

    // Native Apple App Brand Header
    UIStackView *brandRow = mkHStack(9);
    UIImage *appIconImg = [UIImage imageNamed:@"AppIcon60x60"] ?: [UIImage imageNamed:@"orchard.png"];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:appIconImg];
    iconView.contentMode = UIViewContentModeScaleAspectFill;
    iconView.layer.cornerRadius = 8.5;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.clipsToBounds = YES;
    iconView.layer.borderWidth = 0.5;
    iconView.layer.borderColor = kSepColor.CGColor;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [iconView.widthAnchor constraintEqualToConstant:34].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:34].active = YES;

    UIStackView *brandText = mkVStack(1);
    UILabel *appTitle = mkLabel(@"Mod Garden", 15, UIFontWeightSemibold, kInkPrimary);
    appTitle.numberOfLines = 1;
    _statusLabel = mkLabel(@"Đang tải…", 11.5, UIFontWeightRegular, kInkSecondary);
    _statusLabel.numberOfLines = 1;
    [brandText addArrangedSubview:appTitle];
    [brandText addArrangedSubview:_statusLabel];
    [brandRow addArrangedSubview:iconView];
    [brandRow addArrangedSubview:brandText];
    UIView *brandWrap = [UIView new];
    [brandWrap addSubview:brandRow];
    pinInsets(brandRow, brandWrap, UIEdgeInsetsMake(2, 4, 4, 2));
    [sideStack addArrangedSubview:brandWrap];

    // 9 Native iOS Split-View Sidebar Rows (Cài Mod | Thư viện | Console Log | File Save | Hiệu năng & Nút | Co-op LAN | Hướng dẫn | Báo lỗi | Credit)
    UIScrollView *tabScroll = [UIScrollView new];
    tabScroll.showsVerticalScrollIndicator = NO;
    tabScroll.alwaysBounceVertical = NO;
    tabScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [tabScroll setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [tabScroll setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];

    _sidebarTabs = mkVStack(1.5);
    _sidebarTabs.translatesAutoresizingMaskIntoConstraints = NO;
    [tabScroll addSubview:_sidebarTabs];
    [NSLayoutConstraint activateConstraints:@[
        [_sidebarTabs.leadingAnchor constraintEqualToAnchor:tabScroll.contentLayoutGuide.leadingAnchor],
        [_sidebarTabs.trailingAnchor constraintEqualToAnchor:tabScroll.contentLayoutGuide.trailingAnchor],
        [_sidebarTabs.topAnchor constraintEqualToAnchor:tabScroll.contentLayoutGuide.topAnchor],
        [_sidebarTabs.bottomAnchor constraintEqualToAnchor:tabScroll.contentLayoutGuide.bottomAnchor],
        [_sidebarTabs.widthAnchor constraintEqualToAnchor:tabScroll.frameLayoutGuide.widthAnchor]
    ]];

    // Display order places Console Log (tag 8) right beside Thư viện Mod while preserving all existing tab IDs 0..7!
    NSInteger tabOrder[9] = {0, 1, 8, 2, 3, 4, 5, 6, 7};
    NSMutableArray *tBtns = [NSMutableArray array];
    for (NSInteger pos = 0; pos < 9; pos++) {
        NSInteger tagId = tabOrder[pos];
        SDVAppleButton *b = [SDVAppleButton buttonWithType:UIButtonTypeCustom];
        b.tag = tagId;
        b.layer.cornerRadius = 8.5;
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        b.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
        b.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 8);
        b.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, -8);
#pragma clang diagnostic pop
        [b.heightAnchor constraintEqualToConstant:26.5].active = YES;
        [b addTarget:self action:@selector(selectTab:) forControlEvents:UIControlEventTouchUpInside];
        [_sidebarTabs addArrangedSubview:b];
        [tBtns addObject:b];
    }
    _tabButtons = tBtns;
    [sideStack addArrangedSubview:tabScroll];

    UILabel *hint = mkLabel(@"Chạm 3 ngón × 2 để mở", 11, UIFontWeightRegular, kInkTertiary);
    hint.textAlignment = NSTextAlignmentCenter;
    [sideStack addArrangedSubview:hint];

#ifdef GARDEN_IN_GAME
    SDVAppleButton *restartBtn = mkIOSButton(@"Khởi động lại", @"arrow.clockwise", kBgCardSubtle, kTintOrange, 13, UIEdgeInsetsMake(6, 10, 6, 10));
    [restartBtn.heightAnchor constraintEqualToConstant:32].active = YES;
    [restartBtn addTarget:self action:@selector(restartGameTapped) forControlEvents:UIControlEventTouchUpInside];
    [sideStack addArrangedSubview:restartBtn];

    SDVAppleButton *closeBtn = mkIOSButton(@"Về game", @"play.fill", kTintBlue, UIColor.whiteColor, 14, UIEdgeInsetsMake(8, 12, 8, 12));
    [closeBtn.heightAnchor constraintEqualToConstant:36].active = YES;
    [closeBtn addTarget:self action:@selector(closeManager) forControlEvents:UIControlEventTouchUpInside];
    [sideStack addArrangedSubview:closeBtn];
#endif
}

-(void)updateSidebarChrome {
    NSInteger enabledCount = 0;
    for (NSDictionary *m in _catalog) if ([m[@"enabled"] boolValue]) enabledCount++;
    _statusLabel.text = _library
        ? [NSString stringWithFormat:@"%ld mod · Native", (long)enabledCount]
        : @"Stardew 1.6.15 · Native";

    NSArray *titles = @[
        _stagedFiles.count > 0 ? [NSString stringWithFormat:@"Cài Mod (%lu)", (unsigned long)_stagedFiles.count] : @"Cài Mod",
        _catalog.count > 0 ? [NSString stringWithFormat:@"Thư viện (%lu)", (unsigned long)_catalog.count] : @"Thư viện",
        _savesList.count > 0 ? [NSString stringWithFormat:@"File Save (%lu)", (unsigned long)_savesList.count] : @"File Save",
        @"Hiệu năng & Nút",
        @"Co-op LAN",
        @"Hướng dẫn",
        @"Báo lỗi",
        @"Credit",
        @"Console Log"
    ];
    NSArray *navTitles = @[@"Cài đặt Mod", @"Thư viện Mod", @"Quản lý File Save", @"Hiệu năng & Điều khiển", @"Co-op LAN / IP", @"Hướng dẫn sử dụng", @"Báo lỗi cho Admin", @"Credit & Cộng đồng", @"Console Log (Realtime)"];
    NSArray *icons = @[@"square.and.arrow.down.fill", @"square.stack.3d.up.fill", @"externaldrive.fill", @"slider.horizontal.3", @"wifi", @"book.fill", @"ladybug.fill", @"heart.fill", @"terminal.fill"];
    NSArray *iconTints = @[kTintBlue, kTintIndigo, kTintOrange, kTintGreen, kTintTeal, kTintPurple, kTintRed, kTintPink, kTintTeal];

    if (_tab >= 0 && _tab < (NSInteger)navTitles.count) {
        _navTitleLabel.text = navTitles[_tab];
    }
    NSDictionary *updBadge = sdvAvailableLauncherUpdate(NO);
    if (_verPillLabel) {
    if (updBadge) {
        if ([updBadge[@"canHotPatch"] boolValue]) {
            _verPillLabel.text = [NSString stringWithFormat:@"  ⚡ Cập nhật v%@  ", updBadge[@"version"]];
        } else {
            _verPillLabel.text = [NSString stringWithFormat:@"  🔔 Có bản v%@  ", updBadge[@"version"]];
        }
        _verPillLabel.backgroundColor = [kTintGreen colorWithAlphaComponent:0.16];
        _verPillLabel.textColor = kTintGreen;
    } else if (sdvActiveHotPatchInfo() != nil) {
        _verPillLabel.text = [NSString stringWithFormat:@"  ⚡ v%@ · Hot-Patch  ", sdvEffectiveAppVersion()];
        _verPillLabel.backgroundColor = [kTintTeal colorWithAlphaComponent:0.14];
        _verPillLabel.textColor = kTintTeal;
    } else {
        _verPillLabel.text = @"  v" kSDVAppVersion @" · Native  ";
        _verPillLabel.backgroundColor = [kTintBlue colorWithAlphaComponent:0.12];
        _verPillLabel.textColor = kTintBlue;
    }
    }

    for (NSInteger i = 0; i < (NSInteger)_tabButtons.count; i++) {
        SDVAppleButton *b = _tabButtons[i];
        NSInteger tid = b.tag;
        if (tid < 0 || tid >= (NSInteger)titles.count) continue;
        BOOL active = (tid == _tab);
        b.backgroundColor = active ? rgba(0x4F46E5, 0.90) : UIColor.clearColor;
        b.layer.borderWidth = active ? 0.75 : 0.0;
        b.layer.borderColor = active ? [UIColor colorWithWhite:1.0 alpha:0.28].CGColor : UIColor.clearColor.CGColor;
        UIColor *fg = active ? UIColor.whiteColor : kInkPrimary;
        b.tintColor = active ? UIColor.whiteColor : iconTints[tid];
        [b setImage:sfIcon(icons[tid], 14.0, active ? UIImageSymbolWeightSemibold : UIImageSymbolWeightMedium) forState:UIControlStateNormal];
        [b setTitle:titles[tid] forState:UIControlStateNormal];
        [b setTitleColor:fg forState:UIControlStateNormal];
        b.titleLabel.font = iosFont(13.0, active ? UIFontWeightSemibold : UIFontWeightRegular);
    }
}

-(void)selectTab:(UIButton *)sender {
    if (_tab == sender.tag) return;
    if (_tab == 6) [self.view endEditing:YES];
    _tab = sender.tag;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    if (_tab == 2) {
        _savesList = sdvListSaves(_root.path);
    } else if (_tab == 3) {
        if (_root.path.length) sdvMarkHotPatchBootSucceeded(_root.path);
    _uiCfg = [SDVUiConfig loadFromDocuments:_root.path];
        _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
    }
    [self renderAll:YES];
    [_scroll setContentOffset:CGPointZero animated:NO];
}

-(void)renderAll:(BOOL)animate {
    [self updateSidebarChrome];
    for (UIView *v in _pane.arrangedSubviews) {
        [_pane removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    _preview = nil;
    _presetButtons = nil;
    _creditCard = nil;
    _ramHeadlineLbl = nil;
    _ramDetailLbl = nil;
    _ramBarTrack = nil;
    _ramBarFill = nil;
    _ramBarFillW = nil;
    [_ramUiTimer invalidate];
    _ramUiTimer = nil;
    [_consoleTimer invalidate];
    _consoleTimer = nil;
    _consoleTextView = nil;
    _consoleMetaLbl = nil;
    _consoleLiveBtn = nil;
    _consoleScrollBtn = nil;
    [_sliderLabels removeAllObjects];

    if (_message.length) {
        UIStackView *row = mkHStack(10);
        UIColor *tint = _messageIsError ? kTintRed : kTintGreen;
        UIImageView *ic = [[UIImageView alloc] initWithImage:sfIcon(_messageIsError ? @"exclamationmark.triangle.fill" : @"checkmark.circle.fill", 18, UIImageSymbolWeightSemibold)];
        ic.tintColor = tint;
        [ic setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UILabel *ml = mkLabel(_message, 13, UIFontWeightMedium, kInkPrimary);
        SDVAppleButton *x = mkIOSButton(@"", @"xmark", kBgCardSubtle, kInkSecondary, 11.5, UIEdgeInsetsMake(5, 6, 5, 6));
        x.layer.cornerRadius = 11;
        [x setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [x addTarget:self action:@selector(clearMessage) forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:ic];
        [row addArrangedSubview:ml];
        [row addArrangedSubview:x];
        UIView *banner = mkGroupedCard(row, UIEdgeInsetsMake(10, 12, 10, 10));
        banner.backgroundColor = [tint colorWithAlphaComponent:0.12];
        [_pane addArrangedSubview:banner];
    }

    // Show Launcher Update Card (with concise summary of what the update fixes!) at top of Mod Garden / Launcher Setup
    NSDictionary *updInfo = sdvAvailableLauncherUpdate(_tab == 7);
    if (updInfo && _tab != 6) {
        [_pane addArrangedSubview:[self buildLauncherUpdateCard:updInfo]];
    }

    if (_tab == 6) {
        _scroll.hidden = YES;
        _bugTabVC.docsPath = _root.path ?: [fm() URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
        _bugTabVC.view.hidden = NO;
        [_bugTabVC refreshBundleIfNeeded];
        if (animate && !UIAccessibilityIsReduceMotionEnabled()) {
            _bugTabVC.view.alpha = 0.35;
            [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                self->_bugTabVC.view.alpha = 1.0;
            } completion:nil];
        }
        return;
    }

    _bugTabVC.view.hidden = YES;
    _scroll.hidden = NO;

    if (_tab == 0) [self renderInstallTab];
    else if (_tab == 1) [self renderLibraryTab];
    else if (_tab == 2) [self renderSavesTab];
    else if (_tab == 3) [self renderUiStudioTab];
    else if (_tab == 4) [self renderCoopTab];
    else if (_tab == 5) [self renderGuideTab];
    else if (_tab == 8) [self renderConsoleLogTab];
    else [self renderCreditTab];

    if (animate && !UIAccessibilityIsReduceMotionEnabled()) {
        _pane.alpha = 0.35;
        [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self->_pane.alpha = 1.0;
        } completion:nil];
    }
}

-(void)clearMessage { _message = nil; [self renderAll:NO]; }

// ============================================================
// TAB 0: CÀI MOD & THIẾT LẬP LAUNCHER (NHẬP DỮ LIỆU GAME PC)
// ============================================================
-(UIView *)mkChecklistRow:(NSString *)title sub:(NSString *)sub ok:(BOOL)ok {
    UIStackView *row = mkHStack(10);
    UIImageView *ic = [[UIImageView alloc] initWithImage:sfIcon(ok ? @"checkmark.circle.fill" : @"exclamationmark.circle.fill", 20, UIImageSymbolWeightMedium)];
    ic.tintColor = ok ? kTintGreen : kTintRed;
    [ic setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *txt = mkVStack(1);
    [txt addArrangedSubview:mkLabel(title, 13.5, UIFontWeightSemibold, kInkPrimary)];
    [txt addArrangedSubview:mkLabel(sub, 12, UIFontWeightRegular, kInkSecondary)];
    [row addArrangedSubview:ic];
    [row addArrangedSubview:txt];
    [row addArrangedSubview:[UIView new]];
    [row addArrangedSubview:mkBadgePill(ok ? @"Đã có" : @"Thiếu", [ok ? kTintGreen : kTintRed colorWithAlphaComponent:0.14], ok ? kTintGreen : kTintRed, 11)];
    return row;
}

-(void)renderInstallTab {
#ifdef GARDEN_IN_GAME
    NSDictionary *gstat = gameDataStatus(_root.path);
    if (![gstat[@"ready"] boolValue]) {
        NSString *appNm = sdvAppDisplayName();
        UIStackView *hero = mkVStack(12);
        UIStackView *top = mkHStack(12);
        [top addArrangedSubview:mkSettingsIconBadge(@"arrow.down.doc.fill", kTintBlue, 42)];
        UIStackView *ht = mkVStack(3);
        [ht addArrangedSubview:mkLabel([NSString stringWithFormat:@"Thiết lập %@", appNm], 17, UIFontWeightSemibold, kInkPrimary)];
        [ht addArrangedSubview:mkLabel(@"Launcher sạch tích hợp sẵn SMAPI 4.5.2, điều khiển kiểu Mobile, Co-op LAN và tối ưu RAM 4 lớp (không kèm tệp bản quyền). Nạp thư mục Stardew Valley PC 1.6.15 để bắt đầu.", 13, UIFontWeightRegular, kInkSecondary)];
        [top addArrangedSubview:ht];
        [hero addArrangedSubview:top];

        UIStackView *btns = mkHStack(8);
        SDVAppleButton *impBtn = mkIOSButton(@"Nhập gói dữ liệu game (.ZIP)", @"square.and.arrow.down.fill", kTintBlue, UIColor.whiteColor, 14, UIEdgeInsetsMake(11, 14, 11, 14));
        [impBtn addTarget:self action:@selector(importGameDataTapped) forControlEvents:UIControlEventTouchUpInside];
        SDVAppleButton *chkBtn = mkIOSButton(@"Kiểm tra lại", @"arrow.clockwise", kBgCardSubtle, kInkPrimary, 13.5, UIEdgeInsetsMake(11, 13, 11, 13));
        [chkBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [chkBtn addTarget:self action:@selector(recheckGameData) forControlEvents:UIControlEventTouchUpInside];
        [btns addArrangedSubview:impBtn];
        [btns addArrangedSubview:chkBtn];
        [hero addArrangedSubview:btns];
        [_pane addArrangedSubview:mkGroupedCard(hero, UIEdgeInsetsMake(14, 14, 14, 14))];
        [_pane addArrangedSubview:[self makeDiscordHeroCardWithSubtitle:nil]];

        [_pane addArrangedSubview:mkSectionTitle([NSString stringWithFormat:@"Trạng thái tệp · Tệp → Trên iPhone → %@", appNm])];
        [_pane addArrangedSubview:mkGroupedRows(@[
            [self mkChecklistRow:@"Stardew Valley.dll" sub:@"Bắt buộc — tệp chạy bản PC 1.6.15" ok:[gstat[@"hasSdvDll"] boolValue]],
            [self mkChecklistRow:@"Thư mục Content/" sub:@"Bắt buộc — tài nguyên hình ảnh, bản đồ, âm thanh" ok:[gstat[@"hasContent"] boolValue]],
            [self mkChecklistRow:@"SMAPI 4.5.2" sub:@"Đã tích hợp sẵn trong Launcher — tự nạp mod" ok:[gstat[@"hasSmapi"] boolValue]],
            [self mkChecklistRow:@"Thư mục smapi-internal/" sub:@"Đã tích hợp sẵn (mã nguồn mở Pathoschild)" ok:[gstat[@"hasSmapiInternal"] boolValue]]
        ], 44)];

        [_pane addArrangedSubview:mkSectionTitle(@"Hướng dẫn nạp dữ liệu PC")];
        UILabel *howLbl = mkLabel([NSString stringWithFormat:@"• Cách 1 (Nhanh nhất): Nén thư mục Stardew Valley PC 1.6.15 thành tệp .ZIP/.RAR/.7Z rồi bấm Nhập gói dữ liệu game (.ZIP). Thư mục StardewValley/Content/, Mods, Saves và ErrorLogs đều hiển thị trực tiếp trong ứng dụng Tệp.\n• Cách 2 (Thủ công): Mở ứng dụng Tệp → Trên iPhone của tôi → %@ → StardewValley rồi chép Content/, Stardew Valley.dll, xTile.dll, BmFont.dll và StardewValley.GameData.dll vào đó.\n• Hoàn tất: Vuốt tắt hẳn ứng dụng rồi mở lại để vào game.", appNm], 13, UIFontWeightRegular, kInkSecondary);
        [_pane addArrangedSubview:mkGroupedCard(howLbl, UIEdgeInsetsMake(12, 14, 12, 14))];
        return;
    }
    if (!_library) {
        UIStackView *box = mkVStack(10);
        [box addArrangedSubview:mkLabel(@"Dữ liệu game đã sẵn sàng", 16, UIFontWeightSemibold, kInkPrimary)];
        [box addArrangedSubview:mkLabel(@"Đã phát hiện đầy đủ Stardew Valley.dll và Content/. Bấm nút dưới để nạp danh sách mod, hoặc mở lại app để vào game.", 13, UIFontWeightRegular, kInkSecondary)];
        SDVAppleButton *btn = mkIOSButton(@"Đọc dữ liệu & danh sách Mod", @"arrow.clockwise", kTintBlue, UIColor.whiteColor, 14, UIEdgeInsetsMake(10, 14, 10, 14));
        [btn addTarget:self action:@selector(refresh) forControlEvents:UIControlEventTouchUpInside];
        [box addArrangedSubview:btn];
        [_pane addArrangedSubview:mkGroupedCard(box, UIEdgeInsetsMake(14, 14, 14, 14))];
        return;
    }
#else
    if (!_library) {
        UIStackView *box = mkVStack(10);
        [box addArrangedSubview:mkLabel(@"Kết nối Stardew Mobile", 16, UIFontWeightSemibold, kInkPrimary)];
        SDVAppleButton *btn = mkIOSButton(@"Chọn thư mục game", @"folder.fill", kTintBlue, UIColor.whiteColor, 14, UIEdgeInsetsMake(10, 14, 10, 14));
        [btn addTarget:self action:@selector(folder) forControlEvents:UIControlEventTouchUpInside];
        [box addArrangedSubview:btn];
        [_pane addArrangedSubview:mkGroupedCard(box, UIEdgeInsetsMake(14, 14, 14, 14))];
        return;
    }
#endif

    // Active Batch Preview
    if (_plan) {
        [_pane addArrangedSubview:mkSectionTitle(@"Hàng chờ cài đặt")];
        UIStackView *ps = mkVStack(10);
        UIStackView *hdr = mkHStack(8);
        [hdr addArrangedSubview:mkBadgePill([NSString stringWithFormat:@"%lu GÓI", (unsigned long)_stagedFiles.count], [kTintBlue colorWithAlphaComponent:0.14], kTintBlue, 11)];
        [hdr addArrangedSubview:mkLabel(@"Sẵn sàng cài vào game", 15, UIFontWeightSemibold, kInkPrimary)];
        [hdr addArrangedSubview:[UIView new]];
        [hdr addArrangedSubview:mkBadgePill([NSString stringWithFormat:@"%lu tệp", (unsigned long)[_plan[@"map"] count]], [kTintGreen colorWithAlphaComponent:0.14], kTintGreen, 11)];
        [ps addArrangedSubview:hdr];

        if (_stagedFiles.count) {
            UIStackView *fBox = mkVStack(4);
            [fBox addArrangedSubview:mkLabel(@"Tệp nguồn đã chọn", 12, UIFontWeightSemibold, kInkSecondary)];
            for (NSString *fn in _stagedFiles) {
                UILabel *fl = mkLabel([@"• " stringByAppendingString:fn], 13, UIFontWeightRegular, kInkPrimary);
                fl.numberOfLines = 1;
                fl.lineBreakMode = NSLineBreakByTruncatingMiddle;
                [fBox addArrangedSubview:fl];
            }
            UIView *fWrap = [UIView new];
            fWrap.backgroundColor = kBgCardSubtle;
            fWrap.layer.cornerRadius = 10;
            fWrap.layer.cornerCurve = kCACornerCurveContinuous;
            [fWrap addSubview:fBox];
            pinInsets(fBox, fWrap, UIEdgeInsetsMake(8, 10, 8, 10));
            [ps addArrangedSubview:fWrap];
        }

        NSArray *names = _plan[@"names"];
        if (names.count) {
            UIStackView *modList = mkVStack(3);
            [modList addArrangedSubview:mkLabel(@"Nội dung sẽ cài", 12, UIFontWeightSemibold, kInkSecondary)];
            for (NSString *n in names) {
                [modList addArrangedSubview:mkLabel([@"✓ " stringByAppendingString:n], 13.5, UIFontWeightSemibold, kTintGreen)];
            }
            [ps addArrangedSubview:modList];
        }

        NSArray<NSString *> *mobileWarns = _plan[@"mobileWarnings"];
        if (mobileWarns.count) {
            UIStackView *mBoxStack = mkVStack(6);
            UIStackView *mHdr = mkHStack(7);
            UIImageView *mIc = [[UIImageView alloc] initWithImage:sfIcon(@"exclamationmark.triangle.fill", 16, UIImageSymbolWeightBold)];
            mIc.tintColor = kTintOrange;
            [mIc setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            UILabel *mTitle = mkLabel(@"Cảnh báo: Mod dành riêng cho bản Mobile / Android", 13.5, UIFontWeightBold, kTintOrange);
            [mHdr addArrangedSubview:mIc];
            [mHdr addArrangedSubview:mTitle];
            [mBoxStack addArrangedSubview:mHdr];

            [mBoxStack addArrangedSubview:mkLabel(@"Garden Launcher chạy lõi Stardew Valley PC 1.6.15. Mod dành cho bản Mobile/Android có thể gặp lỗi hiển thị, lệch giao diện hoặc không hoạt động đúng — khuyên bạn ưu tiên tải bản PC 1.6 nếu có.", 12.5, UIFontWeightRegular, kInkPrimary)];
            for (NSString *mw in mobileWarns) {
                [mBoxStack addArrangedSubview:mkLabel([@"• " stringByAppendingString:mw], 12, UIFontWeightMedium, kInkSecondary)];
            }
            UIView *mWrap = [UIView new];
            mWrap.backgroundColor = [kTintOrange colorWithAlphaComponent:0.13];
            mWrap.layer.cornerRadius = 11;
            mWrap.layer.cornerCurve = kCACornerCurveContinuous;
            mWrap.layer.borderWidth = 1.0;
            mWrap.layer.borderColor = [kTintOrange colorWithAlphaComponent:0.45].CGColor;
            [mWrap addSubview:mBoxStack];
            pinInsets(mBoxStack, mWrap, UIEdgeInsetsMake(10, 12, 10, 12));
            [ps addArrangedSubview:mWrap];
        }

        for (NSString *w in _plan[@"warnings"]) {
            UILabel *wl = mkLabel(w, 12.5, UIFontWeightMedium, kTintRed);
            UIView *wBox = [UIView new];
            wBox.backgroundColor = [kTintRed colorWithAlphaComponent:0.11];
            wBox.layer.cornerRadius = 9;
            [wBox addSubview:wl];
            pinInsets(wl, wBox, UIEdgeInsetsMake(7, 10, 7, 10));
            [ps addArrangedSubview:wBox];
        }

        UIStackView *acts = mkHStack(8);
        SDVAppleButton *bApply = mkIOSButton([NSString stringWithFormat:@"Cài tất cả (%lu)", (unsigned long)_stagedFiles.count], @"arrow.down.circle.fill", kTintBlue, UIColor.whiteColor, 13.5, UIEdgeInsetsMake(10, 12, 10, 12));
        [bApply addTarget:self action:@selector(apply) forControlEvents:UIControlEventTouchUpInside];
        SDVAppleButton *bAdd = mkIOSButton(@"Thêm", @"plus", kBgCardSubtle, kTintBlue, 13, UIEdgeInsetsMake(10, 10, 10, 10));
        [bAdd addTarget:self action:@selector(addMorePackages) forControlEvents:UIControlEventTouchUpInside];
        SDVAppleButton *bPaths = mkIOSButton(@"Xem tệp", @"list.bullet", kBgCardSubtle, kInkPrimary, 13, UIEdgeInsetsMake(10, 10, 10, 10));
        [bPaths addTarget:self action:@selector(paths) forControlEvents:UIControlEventTouchUpInside];
        SDVAppleButton *bCancel = mkIOSButton(@"Hủy", @"xmark", [kTintRed colorWithAlphaComponent:0.13], kTintRed, 13, UIEdgeInsetsMake(10, 10, 10, 10));
        [bCancel addTarget:self action:@selector(cancelPlan) forControlEvents:UIControlEventTouchUpInside];
        [acts addArrangedSubview:bApply];
        [acts addArrangedSubview:bAdd];
        [acts addArrangedSubview:bPaths];
        [acts addArrangedSubview:bCancel];
        [ps addArrangedSubview:acts];

        [_pane addArrangedSubview:mkGroupedCard(ps, UIEdgeInsetsMake(14, 14, 14, 14))];
        return;
    }

    // Hero Multi-File Picker Card
    UIStackView *hero = mkVStack(12);
    UIStackView *heroTop = mkHStack(12);
    [heroTop addArrangedSubview:mkSettingsIconBadge(@"shippingbox.fill", kTintBlue, 40)];
    UIStackView *heroTxt = mkVStack(2);
    [heroTxt addArrangedSubview:mkLabel(@"Cài Mod từ ứng dụng Tệp", 16, UIFontWeightSemibold, kInkPrimary)];
    [heroTxt addArrangedSubview:mkLabel(@"Hỗ trợ trực tiếp .ZIP, .RAR, .7Z, .TAR.GZ, .TAR.XZ, .XNB hoặc chọn thẳng thư mục mod đã giải nén (tự bung gói nén lồng nhau & tên tiếng Việt).", 13, UIFontWeightRegular, kInkSecondary)];
    [heroTop addArrangedSubview:heroTxt];
    [hero addArrangedSubview:heroTop];

    UIStackView *pickRow = mkHStack(8);
    SDVAppleButton *pickBtn = mkIOSButton(@"Chọn tệp Mod (ZIP/RAR/7Z/...)", @"plus.circle.fill", kTintBlue, UIColor.whiteColor, 13.5, UIEdgeInsetsMake(11, 12, 11, 12));
    [pickBtn addTarget:self action:@selector(package) forControlEvents:UIControlEventTouchUpInside];
    SDVAppleButton *pickDirBtn = mkIOSButton(@"Chọn thư mục Mod", @"folder.badge.plus", [kTintGreen colorWithAlphaComponent:0.15], kTintGreen, 13.5, UIEdgeInsetsMake(11, 12, 11, 12));
    [pickDirBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [pickDirBtn addTarget:self action:@selector(pickModFolder) forControlEvents:UIControlEventTouchUpInside];
    [pickRow addArrangedSubview:pickBtn];
    [pickRow addArrangedSubview:pickDirBtn];
    [hero addArrangedSubview:pickRow];

    UIStackView *chips = mkHStack(6);
    [chips addArrangedSubview:mkBadgePill(@"Chọn nhiều file", [kTintBlue colorWithAlphaComponent:0.12], kTintBlue, 11)];
    [chips addArrangedSubview:mkBadgePill(@"Tự gộp i18n", [kTintGreen colorWithAlphaComponent:0.12], kTintGreen, 11)];
    [chips addArrangedSubview:mkBadgePill(@"Tự sao lưu", kBgCardSubtle, kInkSecondary, 11)];
    [chips addArrangedSubview:[UIView new]];
    [hero addArrangedSubview:chips];

    [_pane addArrangedSubview:mkGroupedCard(hero, UIEdgeInsetsMake(14, 14, 14, 14))];
    [_pane addArrangedSubview:[self makeDiscordHeroCardWithSubtitle:nil]];

#ifdef GARDEN_IN_GAME
    // Direct Content / Game Data Re-Import & Open Files Access Card (fixes #GL-FKRBMM!)
    {
        [_pane addArrangedSubview:mkSectionTitle(@"Dữ liệu Game gốc & Thư mục Content (.XNB)")];
        UIStackView *gdBox = mkVStack(9);
        UIStackView *gdTop = mkHStack(10);
        [gdTop addArrangedSubview:mkSettingsIconBadge(@"folder.fill.badge.gearshape", kTintIndigo, 34)];
        UIStackView *gdTxt = mkVStack(2);
        [gdTxt addArrangedSubview:mkLabel(@"Truy cập tệp gốc & Nạp lại Content", 14.5, UIFontWeightSemibold, kInkPrimary)];
        [gdTxt addArrangedSubview:mkLabel([NSString stringWithFormat:@"Đã mở quyền truy cập trực tiếp tại Tệp → Trên iPhone → %@ → StardewValley/Content/. Bạn có thể sửa/chép đè .XNB thẳng trong Tệp hoặc nạp lại gói Content / Game bên dưới.", sdvAppDisplayName()], 12, UIFontWeightRegular, kInkSecondary)];
        [gdTop addArrangedSubview:gdTxt];
        [gdBox addArrangedSubview:gdTop];

        UIStackView *gdBtns = mkHStack(8);
        SDVAppleButton *reImpBtn = mkIOSButton(@"Nạp lại Game / Content (ZIP/RAR/7Z)", @"arrow.triangle.2.circlepath.doc.on.clipboard", [kTintIndigo colorWithAlphaComponent:0.15], kTintIndigo, 13, UIEdgeInsetsMake(9, 12, 9, 12));
        [reImpBtn addTarget:self action:@selector(importGameDataTapped) forControlEvents:UIControlEventTouchUpInside];
        SDVAppleButton *reDirBtn = mkIOSButton(@"Chọn thư mục", @"folder", kBgCardSubtle, kInkPrimary, 12.5, UIEdgeInsetsMake(9, 11, 9, 11));
        [reDirBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [reDirBtn addTarget:self action:@selector(importGameDataFolderTapped) forControlEvents:UIControlEventTouchUpInside];
        [gdBtns addArrangedSubview:reImpBtn];
        [gdBtns addArrangedSubview:reDirBtn];
        [gdBox addArrangedSubview:gdBtns];
        [_pane addArrangedSubview:mkGroupedCard(gdBox, UIEdgeInsetsMake(12, 14, 12, 14))];
    }
#endif

    // Undo Row
    if (_last.length) {
        [_pane addArrangedSubview:mkSectionTitle(@"Hoàn tác gần nhất")];
        UIStackView *uRow = mkHStack(10);
        [uRow addArrangedSubview:mkSettingsIconBadge(@"arrow.uturn.backward", kTintOrange, 28)];
        UIStackView *uText = mkVStack(1);
        [uText addArrangedSubview:mkLabel(@"Gói vừa cài đặt", 13.5, UIFontWeightSemibold, kInkPrimary)];
        UILabel *ul = mkLabel(_last, 12, UIFontWeightRegular, kInkSecondary);
        ul.numberOfLines = 1;
        ul.lineBreakMode = NSLineBreakByTruncatingTail;
        [uText addArrangedSubview:ul];
        SDVAppleButton *uBtn = mkIOSButton(@"Hoàn tác", nil, [kTintOrange colorWithAlphaComponent:0.14], kTintOrange, 13, UIEdgeInsetsMake(7, 12, 7, 12));
        [uBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [uBtn addTarget:self action:@selector(askUndo) forControlEvents:UIControlEventTouchUpInside];
        [uRow addArrangedSubview:uText];
        [uRow addArrangedSubview:uBtn];
        [_pane addArrangedSubview:mkGroupedCard(uRow, UIEdgeInsetsMake(10, 14, 10, 14))];
    }

    [_pane addArrangedSubview:mkSectionFooter(@"Mẹo: Trong cửa sổ Tệp, chạm vào từng tệp .ZIP / .XNB để chọn nhiều gói một lượt rồi bấm Mở ở góc trên phải.")];
}

// ============================================================
// TAB 1: THƯ VIỆN MOD (Apple Inset Grouped List)
// ============================================================
-(void)renderLibraryTab {
    NSInteger onCount = 0;
    for (NSDictionary *m in _catalog) if ([m[@"enabled"] boolValue]) onCount++;

    UIStackView *hdr = mkHStack(8);
    UILabel *secLbl = mkSectionHeader([NSString stringWithFormat:@"Đã cài đặt (%ld/%lu đang bật)", (long)onCount, (unsigned long)_catalog.count]);
    [hdr addArrangedSubview:secLbl];
    [hdr addArrangedSubview:[UIView new]];
    SDVAppleButton *profBtn = mkIOSButton(@"Hồ sơ Mod", @"square.stack.3d.up.fill", [kTintPurple colorWithAlphaComponent:0.14], kTintPurple, 12, UIEdgeInsetsMake(5, 9, 5, 9));
    [profBtn addTarget:self action:@selector(openModProfilesSheet:) forControlEvents:UIControlEventTouchUpInside];
    [hdr addArrangedSubview:profBtn];
    SDVAppleButton *caseBtn = mkIOSButton(@"Sửa Hoa/Thường", @"textformat.abc", [kTintTeal colorWithAlphaComponent:0.14], kTintTeal, 12, UIEdgeInsetsMake(5, 9, 5, 9));
    [caseBtn addTarget:self action:@selector(healCaseSensitivityTapped) forControlEvents:UIControlEventTouchUpInside];
    [hdr addArrangedSubview:caseBtn];
    SDVAppleButton *ref = mkIOSButton(@"Làm mới", @"arrow.clockwise", [kTintBlue colorWithAlphaComponent:0.12], kTintBlue, 12, UIEdgeInsetsMake(5, 9, 5, 9));
    [ref addTarget:self action:@selector(refresh) forControlEvents:UIControlEventTouchUpInside];
    [hdr addArrangedSubview:ref];
    UIView *hdrWrap = [UIView new];
    [hdrWrap addSubview:hdr];
    pinInsets(hdr, hdrWrap, UIEdgeInsetsMake(2, 12, 0, 4));
    [_pane addArrangedSubview:hdrWrap];

    if (_catalog.count > 0) {
        UIStackView *fltBox = mkHStack(8);
        UITextField *searchTf = [UITextField new];
        searchTf.placeholder = @"🔍 Tìm tên mod, tác giả, thư mục…";
        searchTf.text = _modSearchQuery ?: @"";
        searchTf.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        searchTf.textColor = kInkPrimary;
        searchTf.clearButtonMode = UITextFieldViewModeWhileEditing;
        searchTf.returnKeyType = UIReturnKeySearch;
        searchTf.autocorrectionType = UITextAutocorrectionTypeNo;
        searchTf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        [searchTf addTarget:self action:@selector(modSearchEditingEnded:) forControlEvents:UIControlEventEditingDidEnd | UIControlEventEditingDidEndOnExit];
        [fltBox addArrangedSubview:searchTf];

        UISegmentedControl *fSeg = [[UISegmentedControl alloc] initWithItems:@[@"Tất cả", @"Đang bật", @"Đang tắt"]];
        fSeg.selectedSegmentIndex = MAX(0, MIN(2, _modFilterMode));
        [fSeg setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [fSeg addTarget:self action:@selector(modFilterSegChanged:) forControlEvents:UIControlEventValueChanged];
        [fltBox addArrangedSubview:fSeg];
        [_pane addArrangedSubview:mkGroupedCard(fltBox, UIEdgeInsetsMake(8, 12, 8, 12))];
    }

    if (!_catalog.count && !_modIssues.count) {
        UILabel *empty = mkLabel(@"Chưa có mod nào ngoài mod hệ thống.", 13.5, UIFontWeightRegular, kInkSecondary);
        [_pane addArrangedSubview:mkGroupedCard(empty, UIEdgeInsetsMake(14, 14, 14, 14))];
        return;
    }

    // Mod Health & Conflict Diagnostics Card
    if (_modIssues.count) {
        NSInteger errCnt = 0, warnCnt = 0, infoCnt = 0;
        for (NSDictionary *it in _modIssues) {
            NSString *sev = it[@"severity"];
            if ([sev isEqualToString:@"error"]) errCnt++;
            else if ([sev isEqualToString:@"info"]) infoCnt++;
            else warnCnt++;
        }
        UIStackView *diagStack = mkVStack(8);
        UIStackView *dHdr = mkHStack(8);
        UIColor *hdrCol = (errCnt > 0) ? kTintRed : ((warnCnt > 0) ? kTintOrange : kTintBlue);
        NSString *hdrIcon = (errCnt > 0) ? @"exclamationmark.octagon.fill" : ((warnCnt > 0) ? @"exclamationmark.triangle.fill" : @"info.circle.fill");
        NSString *hdrText = nil;
        if (errCnt > 0 && warnCnt > 0) {
            hdrText = [NSString stringWithFormat:@"Chẩn đoán Mod (%ld lỗi · %ld cảnh báo)", (long)errCnt, (long)warnCnt];
        } else if (errCnt > 0) {
            hdrText = [NSString stringWithFormat:@"Chẩn đoán Mod (%ld lỗi cần xử lý)", (long)errCnt];
        } else if (warnCnt > 0) {
            hdrText = [NSString stringWithFormat:@"Chẩn đoán Mod (%ld cảnh báo)", (long)warnCnt];
        } else {
            hdrText = [NSString stringWithFormat:@"Thông tin tương thích 0%% JIT (%ld ghi chú)", (long)infoCnt];
        }
        UIImageView *dIc = [[UIImageView alloc] initWithImage:sfIcon(hdrIcon, 17, UIImageSymbolWeightBold)];
        dIc.tintColor = hdrCol;
        [dIc setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UILabel *dTitle = mkLabel(hdrText, 13.5, UIFontWeightBold, hdrCol);
        [dHdr addArrangedSubview:dIc];
        [dHdr addArrangedSubview:dTitle];
        [diagStack addArrangedSubview:dHdr];

        for (NSUInteger idx = 0; idx < _modIssues.count; idx++) {
            NSDictionary *it = _modIssues[idx];
            BOOL isErr = [it[@"severity"] isEqualToString:@"error"];
            BOOL isInfo = [it[@"severity"] isEqualToString:@"info"];
            UIColor *col = isErr ? kTintRed : (isInfo ? kTintBlue : kTintOrange);
            NSString *rowIcon = isErr ? @"xmark.circle.fill" : (isInfo ? @"info.circle.fill" : @"exclamationmark.circle.fill");
            UIStackView *iRow = mkHStack(8);
            UIImageView *ic = [[UIImageView alloc] initWithImage:sfIcon(rowIcon, 15, UIImageSymbolWeightSemibold)];
            ic.tintColor = col;
            [ic setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            UIStackView *iTxt = mkVStack(1.5);
            [iTxt addArrangedSubview:mkLabel(it[@"title"], 12.5, UIFontWeightSemibold, kInkPrimary)];
            [iTxt addArrangedSubview:mkLabel(it[@"detail"], 11.5, UIFontWeightRegular, kInkSecondary)];
            [iRow addArrangedSubview:ic];
            [iRow addArrangedSubview:iTxt];
            NSString *orphan = it[@"orphanFolder"];
            if (orphan.length) {
                SDVAppleButton *cleanBtn = mkIOSButton(@"Dọn", @"trash", [kTintRed colorWithAlphaComponent:0.14], kTintRed, 12, UIEdgeInsetsMake(5, 9, 5, 9));
                cleanBtn.tag = (NSInteger)idx;
                [cleanBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
                [cleanBtn addTarget:self action:@selector(cleanOrphanModFolderTapped:) forControlEvents:UIControlEventTouchUpInside];
                [iRow addArrangedSubview:cleanBtn];
            }
            UIView *iWrap = [UIView new];
            iWrap.backgroundColor = [col colorWithAlphaComponent:0.09];
            iWrap.layer.cornerRadius = 9;
            iWrap.layer.cornerCurve = kCACornerCurveContinuous;
            [iWrap addSubview:iRow];
            pinInsets(iRow, iWrap, UIEdgeInsetsMake(7, 9, 7, 9));
            [diagStack addArrangedSubview:iWrap];
        }
        UIView *dCard = mkGroupedCard(diagStack, UIEdgeInsetsMake(12, 13, 12, 13));
        dCard.layer.borderWidth = 0.8;
        dCard.layer.borderColor = [hdrCol colorWithAlphaComponent:0.35].CGColor;
        [_pane addArrangedSubview:dCard];
    } else if (_catalog.count) {
        UIStackView *okRow = mkHStack(7);
        UIImageView *okIc = [[UIImageView alloc] initWithImage:sfIcon(@"checkmark.shield.fill", 15, UIImageSymbolWeightSemibold)];
        okIc.tintColor = kTintGreen;
        [okIc setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [okRow addArrangedSubview:okIc];
        [okRow addArrangedSubview:mkLabel(@"Không phát hiện xung đột, thiếu phụ thuộc hay mod lỗi.", 12.5, UIFontWeightMedium, kInkSecondary)];
        [_pane addArrangedSubview:mkGroupedCard(okRow, UIEdgeInsetsMake(9, 13, 9, 13))];
    }

    NSMutableArray<UIView *> *rows = [NSMutableArray array];
    NSString *qLow = [[_modSearchQuery ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    for (NSUInteger i = 0; i < _catalog.count; i++) {
        NSDictionary *m = _catalog[i];
        BOOL enabled = [m[@"enabled"] boolValue];
        BOOL sys = [m[@"protected"] boolValue];
        if (_modFilterMode == 1 && !enabled) continue;
        if (_modFilterMode == 2 && enabled) continue;
        if (qLow.length) {
            NSString *hay = [[NSString stringWithFormat:@"%@ %@ %@ %@", m[@"name"] ?: @"", m[@"author"] ?: @"", m[@"cleanFolder"] ?: @"", m[@"uniqueID"] ?: @""] lowercaseString];
            if (![hay containsString:qLow]) continue;
        }

        UIStackView *row = mkHStack(10);
        UIView *dot = [UIView new];
        dot.backgroundColor = enabled ? kTintGreen : kInkTertiary;
        dot.layer.cornerRadius = 4.0;
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        [dot.widthAnchor constraintEqualToConstant:8].active = YES;
        [dot.heightAnchor constraintEqualToConstant:8].active = YES;
        [row addArrangedSubview:dot];

        UIStackView *info = mkVStack(2);
        UIStackView *topLine = mkHStack(6);
        UILabel *nameLbl = mkLabel(m[@"name"], 14, UIFontWeightSemibold, enabled ? kInkPrimary : kInkSecondary);
        nameLbl.numberOfLines = 1;
        nameLbl.lineBreakMode = NSLineBreakByTruncatingTail;
        [topLine addArrangedSubview:nameLbl];
        [topLine addArrangedSubview:mkBadgePill([@"v" stringByAppendingString:m[@"version"]], kBgCardSubtle, kInkSecondary, 10.5)];
        if ([m[@"packCount"] integerValue] > 1) {
            [topLine addArrangedSubview:mkBadgePill([NSString stringWithFormat:@"%@ gói", m[@"packCount"]], [kTintBlue colorWithAlphaComponent:0.12], kTintBlue, 10.5)];
        }
        [topLine addArrangedSubview:[UIView new]];
        [info addArrangedSubview:topLine];

        NSString *author = m[@"author"];
        NSString *subText = author.length ? [NSString stringWithFormat:@"%@ · %@", author, m[@"cleanFolder"]] : m[@"cleanFolder"];
        UILabel *subLbl = mkLabel(subText, 12, UIFontWeightRegular, kInkSecondary);
        subLbl.numberOfLines = 1;
        subLbl.lineBreakMode = NSLineBreakByTruncatingTail;
        [info addArrangedSubview:subLbl];
        [row addArrangedSubview:info];

        if ([m[@"hasConfig"] boolValue]) {
            SDVAppleButton *cfgBtn = mkIOSButton(@"", @"slider.horizontal.3", [kTintBlue colorWithAlphaComponent:0.13], kTintBlue, 12.5, UIEdgeInsetsMake(7, 8, 7, 8));
            cfgBtn.layer.cornerRadius = 9;
            cfgBtn.tag = 9000 + (NSInteger)i;
            [cfgBtn addTarget:self action:@selector(openModConfigEditorTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:cfgBtn];
        }

        if (sys) {
            [row addArrangedSubview:mkBadgePill(@"Hệ thống", [kTintOrange colorWithAlphaComponent:0.14], kTintOrange, 11)];
        } else {
            UISwitch *sw = [UISwitch new];
            sw.on = enabled;
            sw.onTintColor = kTintGreen;
            sw.tag = (NSInteger)i;
            sw.transform = CGAffineTransformMakeScale(0.86, 0.86);
            [sw addTarget:self action:@selector(toggleModSwitch:) forControlEvents:UIControlEventValueChanged];
            [row addArrangedSubview:sw];

            SDVAppleButton *del = mkIOSButton(@"", @"trash.fill", [kTintRed colorWithAlphaComponent:0.12], kTintRed, 13, UIEdgeInsetsMake(7, 8, 7, 8));
            del.layer.cornerRadius = 9;
            del.tag = (NSInteger)i;
            [del addTarget:self action:@selector(askDeleteMod:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:del];
        }
        [rows addObject:row];
    }
    if (rows.count) {
        [_pane addArrangedSubview:mkGroupedRows(rows, 32)];
    } else {
        [_pane addArrangedSubview:mkGroupedCard(mkLabel(@"Không có Mod nào khớp bộ lọc tìm kiếm hiện tại.", 13, UIFontWeightRegular, kInkSecondary), UIEdgeInsetsMake(12, 14, 12, 14))];
    }
    [_pane addArrangedSubview:mkSectionFooter(@"Mẹo: Bấm nút thanh trượt (⚙️) trên từng Mod để chỉnh config.json trước khi vào game, hoặc dùng Hồ sơ Mod để chuyển nhanh bộ Mod / Safe Mode.")];
}

// ============================================================
// TAB 2: QUẢN LÝ FILE SAVE (NHẬP / XUẤT / TỰ CẤU HÌNH ĐA NỀN TẢNG)
// ============================================================
-(void)renderSavesTab {
    _savesList = sdvListSaves(_root.path);
    _quickSlotsList = sdvListQuickSavesAndSlots(_root.path);

    // Card 1: Nhập File Save đa nền tảng (ZIP/RAR/7Z, thư mục, hoặc tệp Save rời)
    UIStackView *impBox = mkVStack(10);
    UIStackView *impHdr = mkHStack(10);
    [impHdr addArrangedSubview:mkSettingsIconBadge(@"tray.and.arrow.down.fill", kTintOrange, 32)];
    UIStackView *impTxt = mkVStack(1.5);
    [impTxt addArrangedSubview:mkLabel(@"Nhập File Save (Tự động cấu hình đa nền tảng)", 15, UIFontWeightSemibold, kInkPrimary)];
    [impTxt addArrangedSubview:mkLabel(@"Hỗ trợ Save từ PC (Windows / Mac / Linux), Android (Mobile / SMAPI) & iOS (App Store / Arcade).", 12, UIFontWeightRegular, kInkSecondary)];
    [impHdr addArrangedSubview:impTxt];
    [impBox addArrangedSubview:impHdr];

    UIStackView *btnRow = mkHStack(8);
    btnRow.distribution = UIStackViewDistributionFillEqually;
    SDVAppleButton *zipBtn = mkIOSButton(@"Nhập file nén / XML", @"doc.zipper", kTintBlue, UIColor.whiteColor, 13, UIEdgeInsetsMake(10, 10, 10, 10));
    [zipBtn addTarget:self action:@selector(importSaveZipTapped) forControlEvents:UIControlEventTouchUpInside];
    SDVAppleButton *dirBtn = mkIOSButton(@"Chọn thư mục Save", @"folder.badge.plus", [kTintOrange colorWithAlphaComponent:0.15], kTintOrange, 13, UIEdgeInsetsMake(10, 10, 10, 10));
    [dirBtn addTarget:self action:@selector(importSaveFolderTapped) forControlEvents:UIControlEventTouchUpInside];
    [btnRow addArrangedSubview:zipBtn];
    [btnRow addArrangedSubview:dirBtn];
    [impBox addArrangedSubview:btnRow];

    [impBox addArrangedSubview:mkLabel(@"Tự động chuẩn hóa tên thư mục/tệp (tránh lỗi phân biệt hoa thường trên iOS), xóa rác __MACOSX / EMERGENCY_SAVE, bỏ BOM UTF-8, tự tạo SaveGameInfo nếu thiếu và sao lưu bản cũ khi trùng tên.", 11.5, UIFontWeightRegular, kInkSecondary)];
    [_pane addArrangedSubview:mkGroupedCard(impBox, UIEdgeInsetsMake(13, 14, 13, 14))];

    // Card 2: Danh sách Save hiện có & Xuất File Save (.ZIP đa nền tảng)
    UIStackView *secRow = mkHStack(8);
    [secRow addArrangedSubview:mkSectionTitle([NSString stringWithFormat:@"Danh sách File Save (%lu)", (unsigned long)_savesList.count])];
    [secRow addArrangedSubview:[UIView new]];
    SDVAppleButton *refBtn = mkIOSButton(@"Làm mới", @"arrow.clockwise", kBgCardSubtle, kTintBlue, 12, UIEdgeInsetsMake(5, 10, 5, 10));
    refBtn.layer.cornerRadius = 8;
    [refBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [refBtn addTarget:self action:@selector(refreshSavesTapped) forControlEvents:UIControlEventTouchUpInside];
    [secRow addArrangedSubview:refBtn];
    [_pane addArrangedSubview:secRow];

    if (!_savesList.count) {
        UIStackView *empty = mkVStack(6);
        [empty addArrangedSubview:mkLabel(@"Chưa có file Save nào trong StardewValley/Saves", 14, UIFontWeightSemibold, kInkPrimary)];
        [empty addArrangedSubview:mkLabel(@"Hãy tạo nhân vật mới trong game hoặc bấm \"Nhập file nén / XML\" ở trên để đưa file Save từ PC, Android hoặc iOS vào chơi ngay (tự đồng bộ nếu bạn chép tay vào Documents/Saves).", 12.5, UIFontWeightRegular, kInkSecondary)];
        [_pane addArrangedSubview:mkGroupedCard(empty, UIEdgeInsetsMake(14, 14, 14, 14))];
    } else {
        NSMutableArray<UIView *> *rows = [NSMutableArray array];
        for (NSUInteger i = 0; i < _savesList.count; i++) {
            NSDictionary *sv = _savesList[i];
            UIStackView *row = mkHStack(10);
            [row addArrangedSubview:mkSettingsIconBadge(@"leaf.fill", kTintGreen, 30)];

            UIStackView *info = mkVStack(2);
            NSString *title = [NSString stringWithFormat:@"%@ · Nông trại %@", sv[@"farmerName"], sv[@"farmName"]];
            [info addArrangedSubview:mkLabel(title, 13.5, UIFontWeightSemibold, kInkPrimary)];

            NSString *meta = [NSString stringWithFormat:@"%@ · Ngày %@ · Năm %@ · %@g · v%@ · %@",
                sv[@"season"], sv[@"day"], sv[@"year"], sv[@"money"], sv[@"gameVersion"], sv[@"sizeText"]];
            [info addArrangedSubview:mkLabel(meta, 11.5, UIFontWeightRegular, kInkSecondary)];

            NSMutableArray<NSString *> *tags = [NSMutableArray arrayWithObject:sv[@"folderName"]];
            BOOL needsFix = (![sv[@"hasInfo"] boolValue] || [sv[@"caseMismatch"] boolValue]);
            if ([sv[@"hasQuickSave"] boolValue]) [tags addObject:@"Có QuickSave"];
            if (![sv[@"hasInfo"] boolValue]) [tags addObject:@"Thiếu SaveGameInfo"];
            if ([sv[@"caseMismatch"] boolValue]) [tags addObject:@"Lệch hoa/thường"];
            [info addArrangedSubview:mkLabel([tags componentsJoinedByString:@" · "], 11, UIFontWeightMedium, needsFix ? kTintOrange : kInkTertiary)];
            [row addArrangedSubview:info];

            if (needsFix) {
                SDVAppleButton *fixBtn = mkIOSButton(@"Sửa lỗi", @"wrench.and.screwdriver.fill", [kTintOrange colorWithAlphaComponent:0.15], kTintOrange, 12, UIEdgeInsetsMake(7, 9, 7, 9));
                fixBtn.layer.cornerRadius = 9;
                fixBtn.tag = 7200 + (NSInteger)i;
                [fixBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
                [fixBtn addTarget:self action:@selector(repairSaveTapped:) forControlEvents:UIControlEventTouchUpInside];
                [row addArrangedSubview:fixBtn];
            }

            SDVAppleButton *expBtn = mkIOSButton(@"Xuất .ZIP", @"square.and.arrow.up", [kTintBlue colorWithAlphaComponent:0.13], kTintBlue, 12.5, UIEdgeInsetsMake(7, 10, 7, 10));
            expBtn.layer.cornerRadius = 9;
            expBtn.tag = 7000 + (NSInteger)i;
            [expBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [expBtn addTarget:self action:@selector(exportSaveTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:expBtn];

            SDVAppleButton *delBtn = mkIOSButton(@"", @"trash.fill", [kTintRed colorWithAlphaComponent:0.12], kTintRed, 12.5, UIEdgeInsetsMake(7, 8, 7, 8));
            delBtn.layer.cornerRadius = 9;
            delBtn.tag = 7500 + (NSInteger)i;
            [delBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [delBtn addTarget:self action:@selector(deleteSaveTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:delBtn];

            [rows addObject:row];
        }
        [_pane addArrangedSubview:mkGroupedRows(rows, 48)];
        [_pane addArrangedSubview:mkSectionFooter(@"Bấm \"Xuất .ZIP\" để đóng gói chuẩn đa nền tảng (PC Windows / Mac / Linux / Android SMAPI / iOS) rồi lưu ra Tệp, iCloud Drive hoặc gửi qua AirDrop / Zalo / Telegram.")];
    }

    // Card 3: QuickSave & 20-Slot SaveSlots Browser (v1.1.0)
    if (_quickSlotsList.count > 0) {
        [_pane addArrangedSubview:mkSectionTitle([NSString stringWithFormat:@"Mốc Lưu Nhanh & QuickSave (%lu)", (unsigned long)_quickSlotsList.count])];
        NSMutableArray<UIView *> *qsRows = [NSMutableArray array];
        for (NSUInteger i = 0; i < _quickSlotsList.count; i++) {
            NSDictionary *qs = _quickSlotsList[i];
            BOOL isQs = [qs[@"kind"] isEqualToString:@"quicksave"];
            UIStackView *row = mkHStack(10);
            [row addArrangedSubview:mkSettingsIconBadge(isQs ? @"bolt.fill" : @"clock.arrow.circlepath", isQs ? kTintPurple : kTintTeal, 28)];
            UIStackView *info = mkVStack(1.5);
            [info addArrangedSubview:mkLabel(qs[@"title"] ?: @"QuickSave", 13.5, UIFontWeightSemibold, kInkPrimary)];
            [info addArrangedSubview:mkLabel(qs[@"subtitle"] ?: @"", 11.5, UIFontWeightRegular, kInkSecondary)];
            [row addArrangedSubview:info];
            [row addArrangedSubview:[UIView new]];

            SDVAppleButton *shBtn = mkIOSButton(@"Chia sẻ", @"square.and.arrow.up", [kTintBlue colorWithAlphaComponent:0.13], kTintBlue, 12, UIEdgeInsetsMake(6, 9, 6, 9));
            shBtn.layer.cornerRadius = 8.5;
            shBtn.tag = 7800 + (NSInteger)i;
            [shBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [shBtn addTarget:self action:@selector(shareQuickSlotTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:shBtn];

            SDVAppleButton *rmBtn = mkIOSButton(@"", @"trash.fill", [kTintRed colorWithAlphaComponent:0.12], kTintRed, 12, UIEdgeInsetsMake(6, 8, 6, 8));
            rmBtn.layer.cornerRadius = 8.5;
            rmBtn.tag = 7900 + (NSInteger)i;
            [rmBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [rmBtn addTarget:self action:@selector(deleteQuickSlotTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:rmBtn];
            [qsRows addObject:row];
        }
        [_pane addArrangedSubview:mkGroupedRows(qsRows, 46)];
        [_pane addArrangedSubview:mkSectionFooter(@"Quản lý trực tiếp các bản lưu giữa ngày (QuickSave) và 20 ô lưu nhanh (SaveSlots) mà không cần vào game.")];
    }
}

-(void)refreshSavesTapped {
    _savesList = sdvListSaves(_root.path);
    _quickSlotsList = sdvListQuickSavesAndSlots(_root.path);
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self renderAll:NO];
}

-(void)shareQuickSlotTapped:(UIButton *)btn {
    NSInteger idx = btn.tag - 7800;
    if (idx < 0 || idx >= (NSInteger)_quickSlotsList.count) return;
    NSDictionary *qs = _quickSlotsList[(NSUInteger)idx];
    NSString *targetPath = qs[@"path"];
    if (!targetPath.length || ![fm() fileExistsAtPath:targetPath]) return;

    __block NSURL *shareUrl = nil;
    [self work:@"Đang chuẩn bị tệp chia sẻ…" action:^{
        if (!dir(targetPath)) {
            shareUrl = [NSURL fileURLWithPath:targetPath];
        } else {
            NSString *expDir = join(NSTemporaryDirectory(), @"GardenSaveExports");
            mkdirs(expDir);
            NSString *zipName = [NSString stringWithFormat:@"%@.zip", sanitizeFolderName(qs[@"title"] ?: @"SaveSlot", @"SaveSlot")];
            NSString *zipPath = join(expDir, zipName);
            sdvRemoveItemQuiet(zipPath);
            mz_zip_archive z = {0};
            if (mz_zip_writer_init_file(&z, zipPath.fileSystemRepresentation, 0)) {
                @try {
                    for (NSString *rel in files(targetPath)) {
                        NSData *d = [NSData dataWithContentsOfFile:join(targetPath, rel)];
                        if (d.length) {
                            mz_zip_writer_add_mem(&z, rel.UTF8String, d.bytes, d.length, MZ_DEFAULT_COMPRESSION);
                        }
                    }
                    mz_zip_writer_finalize_archive(&z);
                    shareUrl = [NSURL fileURLWithPath:zipPath];
                } @finally {
                    mz_zip_writer_end(&z);
                }
            }
        }
    } done:^{
        if (!shareUrl) return;
        UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[shareUrl] applicationActivities:nil];
        [self presentSafely:avc];
    }];
}

-(void)deleteQuickSlotTapped:(UIButton *)btn {
    NSInteger idx = btn.tag - 7900;
    if (idx < 0 || idx >= (NSInteger)_quickSlotsList.count) return;
    NSDictionary *qs = _quickSlotsList[(NSUInteger)idx];
    NSString *targetPath = qs[@"path"];
    NSString *title = qs[@"title"] ?: @"Mốc lưu nhanh";
    if (!targetPath.length) return;

    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"Xóa mốc lưu nhanh?"
                                                                message:[NSString stringWithFormat:@"Xóa \"%@\"? File Save chính khi đi ngủ của nhân vật vẫn giữ nguyên 100%%.", title]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:@"Xóa" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        (void)a;
        sdvRemoveItemQuiet(targetPath);
        self->_savesList = sdvListSaves(self->_root.path);
        self->_quickSlotsList = sdvListQuickSavesAndSlots(self->_root.path);
        self->_message = [NSString stringWithFormat:@"Đã xóa %@.", title];
        self->_messageIsError = NO;
        [self renderAll:NO];
    }]];
    [self presentSafely:al];
}

-(void)importSaveZipTapped {
    _choosingFolder = NO; _importingGameData = NO; _importingSave = YES; _appendPick = NO;
    [self picker:sdvAllArchivePickerTypes() copy:YES multi:YES];
}

-(void)importSaveFolderTapped {
    _choosingFolder = NO; _importingGameData = NO; _importingSave = YES; _appendPick = NO;
    [self picker:@[UTTypeFolder] copy:NO multi:NO];
}

-(void)repairSaveTapped:(UIButton *)btn {
    NSInteger idx = btn.tag - 7200;
    if (idx < 0 || idx >= (NSInteger)_savesList.count) return;
    NSDictionary *sv = _savesList[(NSUInteger)idx];
    NSString *folderPath = sv[@"folderPath"];
    NSString *folderName = sv[@"folderName"];
    __block NSString *detail = nil;
    [self work:@"Đang chuẩn hóa File Save…" action:^{
        detail = sdvRepairSaveFolder(folderPath);
        self->_savesList = sdvListSaves(self->_root.path);
    } done:^{
        self->_message = [NSString stringWithFormat:@"Đã chuẩn hóa Save %@ (%@).", folderName, detail ?: @"OK"];
        self->_messageIsError = NO;
        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
        [self renderAll:NO];
    }];
}

-(void)exportSaveTapped:(UIButton *)btn {
    NSInteger idx = btn.tag - 7000;
    if (idx < 0 || idx >= (NSInteger)_savesList.count) return;
    NSDictionary *sv = _savesList[(NSUInteger)idx];
    NSString *folderPath = sv[@"folderPath"];
    NSString *label = [NSString stringWithFormat:@"%@ (%@)", sv[@"farmerName"], sv[@"folderName"]];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Chọn định dạng Xuất File Save"
                                                                   message:[NSString stringWithFormat:@"Save: %@\nTự động chuẩn hóa UTF-8, tên thư mục khớp chữ hoa/thường và đóng gói .ZIP sạch.", label]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    void (^runExport)(NSInteger) = ^(NSInteger mode) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        __block NSURL *zipUrl = nil;
        [s work:@"Đang đóng gói File Save (.ZIP)…" action:^{
            zipUrl = sdvExportSaveToZip(folderPath, s->_root.path, mode);
        } done:^{
            if (!zipUrl) return;
            UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[zipUrl] applicationActivities:nil];
            avc.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
                (void)activityType; (void)returnedItems; (void)activityError;
                if (completed) {
                    s->_message = [NSString stringWithFormat:@"Đã xuất File Save \"%@\" thành công!", zipUrl.lastPathComponent];
                    s->_messageIsError = NO;
                    [s renderAll:NO];
                }
            };
            [s presentSafely:avc];
        }];
    };

    [sheet addAction:[UIAlertAction actionWithTitle:@"Đa nền tảng chuẩn (PC / Mac / Linux / Android SMAPI / iOS)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { (void)a; runExport(0); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Sao lưu Garden Launcher iOS (Kèm QuickSave)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { (void)a; runExport(1); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Tương thích Mobile gốc (iOS App Store / Android)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { (void)a; runExport(2); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSafely:sheet];
}

-(void)deleteSaveTapped:(UIButton *)btn {
    NSInteger idx = btn.tag - 7500;
    if (idx < 0 || idx >= (NSInteger)_savesList.count) return;
    NSDictionary *sv = _savesList[(NSUInteger)idx];
    NSString *folderPath = sv[@"folderPath"];
    NSString *folderName = sv[@"folderName"];

    UIAlertController *al = [UIAlertController alertControllerWithTitle:@"Xóa File Save?"
                                                                message:[NSString stringWithFormat:@"Xóa vĩnh viễn Save \"%@ (%@)\" (kèm QuickSave & các mốc lưu của nhân vật này)? Bạn nên bấm \"Xuất .ZIP\" để sao lưu trước khi xóa.", sv[@"farmerName"], folderName]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [al addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:@"Xóa" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        (void)a;
        [self work:@"Đang xóa Save…" action:^{
            sdvDeleteSaveFolder(folderPath, self->_root.path);
        } done:^{
            self->_savesList = sdvListSaves(self->_root.path);
            self->_quickSlotsList = sdvListQuickSavesAndSlots(self->_root.path);
            self->_message = [NSString stringWithFormat:@"Đã xóa File Save %@.", folderName];
            self->_messageIsError = NO;
            [self renderAll:NO];
        }];
    }]];
    [self presentSafely:al];
}

// ============================================================
// TAB 3: HIỆU NĂNG (v6 KHÓA 2.0×) & TÙY CHỈNH NÚT BẤM
// ============================================================
-(UIView *)mkSliderRow:(NSString *)title min:(float)lo max:(float)hi val:(float)val valText:(NSString *)valText tag:(NSInteger)tag {
    UIStackView *box = mkVStack(4);
    UIStackView *hdr = mkHStack(8);
    [hdr addArrangedSubview:mkLabel(title, 13.5, UIFontWeightRegular, kInkPrimary)];
    [hdr addArrangedSubview:[UIView new]];
    UILabel *vl = mkLabel(valText, 13.5, UIFontWeightSemibold, kTintBlue);
    vl.font = iosMonoDigits(13.5, UIFontWeightSemibold);
    vl.textAlignment = NSTextAlignmentRight;
    [hdr addArrangedSubview:vl];
    _sliderLabels[@(tag)] = vl;

    UISlider *sl = [UISlider new];
    sl.minimumValue = lo;
    sl.maximumValue = hi;
    sl.value = val;
    sl.minimumTrackTintColor = kTintBlue;
    sl.tag = tag;
    [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [sl addTarget:self action:@selector(sliderEnded:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    [box addArrangedSubview:hdr];
    [box addArrangedSubview:sl];
    return box;
}

-(UIView *)mkSettingsSwitchRow:(NSString *)title icon:(NSString *)sym color:(UIColor *)col on:(BOOL)on tag:(NSInteger)tag {
    UIStackView *row = mkHStack(10);
    if (sym.length) [row addArrangedSubview:mkSettingsIconBadge(sym, col ?: kTintBlue, 28)];
    [row addArrangedSubview:mkLabel(title, 13.5, UIFontWeightRegular, kInkPrimary)];
    [row addArrangedSubview:[UIView new]];
    UISwitch *sw = [UISwitch new];
    sw.on = on;
    sw.onTintColor = kTintGreen;
    sw.tag = tag;
    sw.transform = CGAffineTransformMakeScale(0.88, 0.88);
    [sw addTarget:self action:@selector(uiSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [row addArrangedSubview:sw];
    return row;
}

-(void)renderUiStudioTab {
    if (!_uiCfg) _uiCfg = [SDVUiConfig loadFromDocuments:_root.path];
    _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path]; // Always reload latest Edit Layout & custom PC keys!

    // Scientific 4-Tab Segmented Bar: zero endless scrolling, find any setting in 1 tap!
    UISegmentedControl *topSecSeg = [[UISegmentedControl alloc] initWithItems:@[@"Điều khiển", @"Giao diện", @"Phím PC", @"Hiệu năng"]];
    topSecSeg.selectedSegmentIndex = MAX(0, MIN(3, _ctrlSectionTab));
    [topSecSeg addTarget:self action:@selector(ctrlSectionChanged:) forControlEvents:UIControlEventValueChanged];
    [_pane addArrangedSubview:topSecSeg];

    if (_ctrlSectionTab == 0) {
        // ==================== TAB 0: ĐIỀU KHIỂN & CHIẾN ĐẤU ====================
        [_pane addArrangedSubview:mkSectionTitle(@"Chế độ Tay cầm chuyên dụng (Console / Bluetooth / USB-C)")];
        {
            UIStackView *gpCard = mkVStack(8);
            UIView *gpSw = [self mkSettingsSwitchRow:@"Chế độ Tay cầm thuần (tắt hẳn lớp cảm ứng ảo)" icon:@"gamecontroller.fill" color:kTintPurple on:_mobileCfg.pureGamepadMode tag:54];
            [gpCard addArrangedSubview:gpSw];
            UILabel *gpDesc = mkLabel(@"Ngắt sạch bộ điều khiển cảm ứng ảo ngay từ lúc mở game để không bao giờ chạm nhầm màn hình khi gắn tay cầm (Backbone, Gamesir, Xbox, DualSense, Switch…). Giữ nguyên 100% bản fix tay cầm: Rung CoreHaptics, SnappyMenus, LB/RB chuyển tab & khung rương, thay/kéo/thả/vứt đồ và con trỏ R-Stick.", 12, UIFontWeightRegular, kInkSecondary);
            [gpCard addArrangedSubview:gpDesc];
#ifdef GARDEN_IN_GAME
            UIStackView *gpAct = mkHStack(8);
            UILabel *gpStatus = mkBadgePill(_mobileCfg.pureGamepadMode ? @"ĐANG BẬT · Cần khởi động lại nếu vừa đổi" : @"ĐANG TẮT · Tự động chuyển Cảm ứng ↔ Tay cầm",
                [(_mobileCfg.pureGamepadMode ? kTintPurple : kTintBlue) colorWithAlphaComponent:0.14],
                _mobileCfg.pureGamepadMode ? kTintPurple : kTintBlue, 11);
            [gpAct addArrangedSubview:gpStatus];
            [gpAct addArrangedSubview:[UIView new]];
            SDVAppleButton *rstBtn = mkIOSButton(@"Khởi động lại ngay", @"power", [kTintRed colorWithAlphaComponent:0.14], kTintRed, 12, UIEdgeInsetsMake(6, 10, 6, 10));
            [rstBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [rstBtn addTarget:self action:@selector(restartGameTapped) forControlEvents:UIControlEventTouchUpInside];
            [gpAct addArrangedSubview:rstBtn];
            [gpCard addArrangedSubview:gpAct];
#endif
            [_pane addArrangedSubview:mkGroupedCard(gpCard, UIEdgeInsetsMake(11, 14, 11, 14))];
        }

        [_pane addArrangedSubview:mkSectionTitle(@"Chế độ điều khiển cảm ứng")];
        UIStackView *mcTop = mkVStack(8);
        UIStackView *mcHdr = mkHStack(8);
        [mcHdr addArrangedSubview:mkSettingsIconBadge(@"hand.point.up.left.fill", kTintBlue, 28)];
        [mcHdr addArrangedSubview:mkLabel(@"Kiểu điều khiển trong game", 14, UIFontWeightSemibold, kInkPrimary)];
        [mcHdr addArrangedSubview:[UIView new]];
        [mcHdr addArrangedSubview:mkBadgePill(@"Đổi trực tiếp", [kTintBlue colorWithAlphaComponent:0.14], kTintBlue, 11)];
        [mcTop addArrangedSubview:mcHdr];

        // Segment order: 0=Vô hình (mode 1), 1=2 Nút (mode 2), 2=Chạm đi (mode 3), 3=Kết hợp (mode 4)
        NSInteger effMode = (_mobileCfg.mode >= 1 && _mobileCfg.mode <= 4) ? _mobileCfg.mode : 1;
        UISegmentedControl *mcSeg = [[UISegmentedControl alloc] initWithItems:@[@"Vô hình", @"2 Nút", @"Chạm đi", @"Kết hợp"]];
        mcSeg.selectedSegmentIndex = effMode - 1;
        [mcSeg addTarget:self action:@selector(mobileModeChanged:) forControlEvents:UIControlEventValueChanged];
        [mcTop addArrangedSubview:mcSeg];

        NSString *modeDesc = @"";
        switch (effMode) {
            case 2: modeDesc = @"Joystick + 2 nút Pixel: Hiện Joystick và 2 nút huy hiệu Pixel tối giản dịu mắt (USE / ACT)."; break;
            case 3: modeDesc = @"Chạm đâu đi đó (Tap-to-Move): Chạm đất tìm đường A*, giữ kéo lướt thu hoạch, giữ gồng Cần câu/Cuốc/Bình tưới, chạm mình ăn đồ/xuống ngựa."; break;
            case 4: modeDesc = @"Kết hợp: Vừa chạm để đi/tương tác/câu cá, vừa kéo Joystick vô hình bên trái + 2 thanh dọc bên phải."; break;
            default: modeDesc = @"Vô hình + 2 thanh dọc: Joystick động bên trái · 2 thanh dọc ẩn bên phải (USE / ACT). Dùng Edit Layout để kéo vị trí & cỡ."; break;
        }
        [mcTop addArrangedSubview:mkLabel(modeDesc, 12, UIFontWeightRegular, kInkSecondary)];

        NSMutableArray<UIView *> *modeRows = [NSMutableArray arrayWithObject:mcTop];
        {
            UIStackView *editRow = mkHStack(10);
            [editRow addArrangedSubview:mkSettingsIconBadge(@"slider.horizontal.below.rectangle", kTintBlue, 28)];
            UIStackView *editTxt = mkVStack(1);
            [editTxt addArrangedSubview:mkLabel(@"Chỉnh bố cục & cỡ vùng chạm", 13.5, UIFontWeightSemibold, kInkPrimary)];
            [editTxt addArrangedSubview:mkLabel(@"Kéo di chuyển & kéo góc + để chỉnh vị trí / kích thước trực tiếp trên game", 11.5, UIFontWeightRegular, kInkSecondary)];
            SDVAppleButton *editBtn = mkIOSButton(@"Edit Layout", @"arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", kTintBlue, UIColor.whiteColor, 12.5, UIEdgeInsetsMake(8, 12, 8, 12));
            [editBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [editBtn addTarget:self action:@selector(enterMobileEditLayoutTapped) forControlEvents:UIControlEventTouchUpInside];
            [editRow addArrangedSubview:editTxt];
            [editRow addArrangedSubview:editBtn];
            [modeRows addObject:editRow];
        }
        [_pane addArrangedSubview:mkGroupedRows(modeRows, 48)];

        {
            // Card 2: Bố cục & Cảm giác tay
            [_pane addArrangedSubview:mkSectionTitle(@"Bố cục & Cảm giác tay")];
            NSMutableArray<UIView *> *feelRows = [NSMutableArray array];
            [feelRows addObject:[self mkSliderRow:@"Kích thước nút / vùng chạm" min:0.75f max:1.45f val:_mobileCfg.buttonScale valText:[NSString stringWithFormat:@"%d%%", (int)roundf(_mobileCfg.buttonScale * 100)] tag:17]];
            [feelRows addObject:[self mkSliderRow:@"Độ rõ (Opacity) bộ nút Pixel" min:0.25f max:1.00f val:_mobileCfg.pixelOpacity valText:[NSString stringWithFormat:@"%d%%", (int)roundf(_mobileCfg.pixelOpacity * 100)] tag:20]];
            if (effMode != 3) {
                [feelRows addObject:[self mkSliderRow:@"Vùng chết Joystick (Deadzone)" min:0.05f max:0.25f val:_mobileCfg.joyDeadzone valText:[NSString stringWithFormat:@"%d%%", (int)roundf(_mobileCfg.joyDeadzone * 100)] tag:21]];
                [feelRows addObject:[self mkSettingsSwitchRow:@"Đổi vị trí 2 nút hành động (Đánh ↔ Tương tác)" icon:@"arrow.left.arrow.right" color:kTintPurple on:_mobileCfg.swapRightButtons tag:35]];
                [feelRows addObject:[self mkSettingsSwitchRow:@"Đảo bố cục tay trái 1 chạm (Joystick phải · Nút trái)" icon:@"hand.raised.fingers.spread.fill" color:kTintPurple on:_mobileCfg.leftHandedMobile tag:51]];
            }
            if (effMode == 1 || effMode == 4) {
                [feelRows addObject:[self mkSettingsSwitchRow:@"Chớp khung mờ khi chạm (chế độ Vô hình)" icon:@"circle.dashed" color:kTintIndigo on:_mobileCfg.showTouchHint tag:33]];
            }
            [feelRows addObject:[self mkSettingsSwitchRow:@"Chụm 2 ngón phóng to/nhỏ (Pinch Zoom)" icon:@"arrow.up.left.and.arrow.down.right" color:kTintBlue on:_mobileCfg.pinchZoom tag:32]];
            [feelRows addObject:[self mkSettingsSwitchRow:@"Tự ẩn nút cảm ứng khi dùng Tay cầm / Phím / Chuột ngoài" icon:@"gamecontroller.fill" color:kTintPurple on:_mobileCfg.autoHideOnGamepad tag:50]];
            [_pane addArrangedSubview:mkGroupedRows(feelRows, 48)];

            // Card 3: Tự động & Chiến đấu
            [_pane addArrangedSubview:mkSectionTitle(@"Hỗ trợ Tự động & Chiến đấu")];
            [_pane addArrangedSubview:mkGroupedRows(@[
                [self mkSettingsSwitchRow:@"Tự chọn công cụ (Auto-Tool: Cây · Đá · Gia súc · Đãi vàng)" icon:@"hammer.fill" color:kTintOrange on:_mobileCfg.autoTool tag:30],
                [self mkSettingsSwitchRow:@"Tự bổ/đào liên tục 1 chạm (Auto-Repeat cây & đá)" icon:@"repeat.circle.fill" color:kTintOrange on:_mobileCfg.autoRepeat tag:41],
                [self mkSettingsSwitchRow:@"Tự trả về đồ cầm cũ sau khi Auto-Tool xong" icon:@"arrow.uturn.backward.circle.fill" color:kTintIndigo on:_mobileCfg.restoreToolAfterAuto tag:42],
                [self mkSettingsSwitchRow:@"Tự động đánh quái (Auto-Attack)" icon:@"bolt.shield.fill" color:kTintRed on:_mobileCfg.autoAttack tag:31],
                [self mkSettingsSwitchRow:@"Hiện nút chiêu đặc biệt SPEC (đỡ Kiếm / đập Búa)" icon:@"shield.lefthalf.filled" color:kTintRed on:_mobileCfg.showSpecButton tag:43],
                [self mkSettingsSwitchRow:@"Tự sang Joystick khi vào Mỏ/Núi lửa + nút đổi nhanh CTL" icon:@"flame.fill" color:kTintRed on:_mobileCfg.autoCombatMode tag:44]
            ], 48)];
        }
    } else if (_ctrlSectionTab == 1) {
        // ==================== TAB 1: GIAO DIỆN & MENU ====================
        [_pane addArrangedSubview:mkSectionTitle(@"Thanh Item dọc kiểu Mobile (Toolbar)")];
        NSMutableArray<UIView *> *tbRows = [NSMutableArray array];
        [tbRows addObject:[self mkSettingsSwitchRow:@"Bật thanh item dọc 36 ô (thay thanh ngang PC)" icon:@"sidebar.left" color:kTintBlue on:_mobileCfg.verticalToolbar tag:48]];

        // Vị trí cạnh (Trái / Phải)
        {
            UIStackView *sideRow = mkHStack(10);
            [sideRow addArrangedSubview:mkSettingsIconBadge(@"rectangle.lefthalf.inset.filled", kTintIndigo, 28)];
            [sideRow addArrangedSubview:mkLabel(@"Vị trí cạnh màn hình", 13.5, UIFontWeightMedium, kInkPrimary)];
            [sideRow addArrangedSubview:[UIView new]];
            UISegmentedControl *sideSeg = [[UISegmentedControl alloc] initWithItems:@[@"Cạnh trái", @"Cạnh phải"]];
            sideSeg.selectedSegmentIndex = (_mobileCfg.toolbarSide == 1) ? 1 : 0;
            [sideSeg setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [sideSeg addTarget:self action:@selector(toolbarSideChanged:) forControlEvents:UIControlEventValueChanged];
            [sideRow addArrangedSubview:sideSeg];
            [tbRows addObject:sideRow];
        }

        // Số cột hiển thị (1 / 2 / 3 cột)
        {
            UIStackView *colRow = mkHStack(10);
            [colRow addArrangedSubview:mkSettingsIconBadge(@"square.grid.2x2.fill", kTintPurple, 28)];
            [colRow addArrangedSubview:mkLabel(@"Số cột hiển thị", 13.5, UIFontWeightMedium, kInkPrimary)];
            [colRow addArrangedSubview:[UIView new]];
            UISegmentedControl *colSeg = [[UISegmentedControl alloc] initWithItems:@[@"1 cột", @"2 cột", @"3 cột"]];
            colSeg.selectedSegmentIndex = MAX(0, MIN(2, _mobileCfg.toolbarColumns - 1));
            [colSeg setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [colSeg addTarget:self action:@selector(toolbarColumnsChanged:) forControlEvents:UIControlEventValueChanged];
            [colRow addArrangedSubview:colSeg];
            [tbRows addObject:colRow];
        }

        // Số ô hiển thị mỗi cột (Tự động hoặc 4..12 ô)
        NSString *tbRowsTxt = (_mobileCfg.toolbarVisibleRows <= 0)
            ? @"Tự động (tràn dọc)"
            : [NSString stringWithFormat:@"%ld ô / cột", (long)_mobileCfg.toolbarVisibleRows];
        float tbRowsVal = (_mobileCfg.toolbarVisibleRows <= 0) ? 3.0f : (float)_mobileCfg.toolbarVisibleRows;
        [tbRows addObject:[self mkSliderRow:@"Số lượng item hiển thị / cột" min:3.0f max:12.0f val:tbRowsVal valText:tbRowsTxt tag:24]];
        [tbRows addObject:[self mkSliderRow:@"Kích thước / Độ dày ô item" min:0.55f max:1.50f val:_mobileCfg.toolbarSize valText:[NSString stringWithFormat:@"%d%%", (int)roundf(_mobileCfg.toolbarSize * 100)] tag:22]];
        [tbRows addObject:[self mkSliderRow:@"Độ trong suốt thanh item" min:0.20f max:1.00f val:_mobileCfg.toolbarOpacity valText:[NSString stringWithFormat:@"%d%%", (int)roundf(_mobileCfg.toolbarOpacity * 100)] tag:23]];

        // Nút mở nhanh Edit Layout kéo vị trí & cỡ thanh item trực tiếp trên màn hình game
        {
            UIStackView *edRow = mkHStack(10);
            [edRow addArrangedSubview:mkSettingsIconBadge(@"arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", kTintBlue, 28)];
            UIStackView *edTxt = mkVStack(1);
            [edTxt addArrangedSubview:mkLabel(@"Chỉnh bố cục trực tiếp trên màn hình game", 13.5, UIFontWeightSemibold, kInkPrimary)];
            [edTxt addArrangedSubview:mkLabel(@"Kéo thanh item sang trái/phải/lên/xuống & kéo góc + để đổi cỡ", 11.5, UIFontWeightRegular, kInkSecondary)];
            SDVAppleButton *edBtn = mkIOSButton(@"Edit Layout", @"slider.horizontal.below.rectangle", kTintBlue, UIColor.whiteColor, 12.5, UIEdgeInsetsMake(8, 12, 8, 12));
            [edBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [edBtn addTarget:self action:@selector(editToolbarLayoutTapped) forControlEvents:UIControlEventTouchUpInside];
            [edRow addArrangedSubview:edTxt];
            [edRow addArrangedSubview:edBtn];
            [tbRows addObject:edRow];
        }
        [_pane addArrangedSubview:mkGroupedRows(tbRows, 48)];
        [_pane addArrangedSubview:mkSectionFooter(@"Thanh item tự căn giữa icon, số lượng, sao chất lượng & thanh nước ở mọi kích thước. Tự động né đồng hồ & nút bấm dù đặt cạnh trái hay cạnh phải.")];

        [_pane addArrangedSubview:mkSectionTitle(@"Thanh công cụ & Tiện ích HUD")];
        [_pane addArrangedSubview:mkGroupedRows(@[
            [self mkSettingsSwitchRow:@"Hiện thanh tiện ích (BAG · MAP · QST · SAVE · KEY · EDIT · HIDE)" icon:@"rectangle.topthird.inset.filled" color:kTintGreen on:_mobileCfg.showTopUtility tag:34],
            [self mkSettingsSwitchRow:@"Hiện nút thả biểu cảm mặt cười (Emote)" icon:@"face.smiling.fill" color:kTintOrange on:_mobileCfg.showEmoteButton tag:40],
            [self mkSettingsSwitchRow:@"Hiện ô vuông đỏ chỉ mục tiêu công cụ (Tool Hit Box)" icon:@"viewfinder" color:kTintRed on:_mobileCfg.showToolHitLocation tag:53]
        ], 48)];
        [_pane addArrangedSubview:mkSectionFooter(@"Mẹo: Bấm nút HIDE trên thanh tiện ích để ẩn sạch toàn bộ nút trên màn hình — chạm đúp (2 lần nhanh) bất kỳ đâu để hiện lại.")];

        [_pane addArrangedSubview:mkSectionTitle(@"Thao tác Menu & An toàn")];
        [_pane addArrangedSubview:mkGroupedRows(@[
            [self mkSettingsSwitchRow:@"Mua đồ kiểu Mobile & Kéo thả vật phẩm (Tủ đồ 1 chạm, gắn mồi/phao)" icon:@"cart.fill" color:kTintGreen on:_mobileCfg.mobileShopAndDrag tag:36],
            [self mkSettingsSwitchRow:@"Chế tạo kiểu Mobile (chạm 1 mở bảng nguyên liệu & chọn số lượng)" icon:@"wrench.and.screwdriver.fill" color:kTintOrange on:_mobileCfg.safeCrafting tag:38],
            [self mkSettingsSwitchRow:@"Mô tả đồ cố định + Chạm 2 lần chọn Hội thoại an toàn" icon:@"text.bubble.fill" color:kTintTeal on:_mobileCfg.safeDialogueAndTooltip tag:47],
            [self mkSettingsSwitchRow:@"Tự bật bàn phím iOS khi chạm ô nhập chữ" icon:@"keyboard.chevron.compact.down" color:kTintTeal on:_mobileCfg.autoKeyboard tag:37]
        ], 48)];

        [_pane addArrangedSubview:mkSectionTitle(@"Tỉ lệ hiển thị & Tai thỏ (Dynamic Island)")];
        NSString *uiScTxt = (_mobileCfg.uiScaleOverride >= 0.73f)
            ? [NSString stringWithFormat:@"%d%%", (int)roundf(_mobileCfg.uiScaleOverride * 100)]
            : @"Mặc định";
        float uiScVal = (_mobileCfg.uiScaleOverride >= 0.73f) ? _mobileCfg.uiScaleOverride : 0.70f;
        NSString *safePadTxt = (_mobileCfg.safePaddingPx < 0)
            ? @"Tự động"
            : [NSString stringWithFormat:@"%ld px", (long)_mobileCfg.safePaddingPx];
        float safePadVal = (_mobileCfg.safePaddingPx < 0) ? -4.0f : (float)_mobileCfg.safePaddingPx;
        [_pane addArrangedSubview:mkGroupedRows(@[
            [self mkSliderRow:@"Đệm lề né Tai thỏ / Dynamic Island" min:-4.0f max:80.0f val:safePadVal valText:safePadTxt tag:19],
            [self mkSliderRow:@"Cỡ chữ & Menu PC / Mod (UI Scale)" min:0.70f max:1.50f val:uiScVal valText:uiScTxt tag:18]
        ], 14)];

    } else if (_ctrlSectionTab == 2) {
        // ==================== TAB 2: PHÍM PC TÙY CHỌN (56 PHÍM + TỰ GẮN PHÍM MOD) ====================
        NSArray<NSDictionary *> *detectedModKeys = [self detectInstalledModHotkeys];
        if (detectedModKeys.count > 0) {
            [_pane addArrangedSubview:mkSectionTitle(@"Tự động nhận diện Phím tắt Mod đã cài")];
            UIStackView *smBox = mkVStack(8);
            UIStackView *smHdr = mkHStack(10);
            [smHdr addArrangedSubview:mkSettingsIconBadge(@"wand.and.stars", kTintGreen, 30)];
            UIStackView *smTxt = mkVStack(1.5);
            [smTxt addArrangedSubview:mkLabel([NSString stringWithFormat:@"Phát hiện %lu phím tắt từ Mod đang bật", (unsigned long)detectedModKeys.count], 14, UIFontWeightSemibold, kInkPrimary)];
            NSMutableArray<NSString *> *summaryParts = [NSMutableArray array];
            NSUInteger missingCnt = 0;
            for (NSDictionary *mk in detectedModKeys) {
                BOOL exists = [mk[@"alreadyBound"] boolValue];
                if (!exists) missingCnt++;
                [summaryParts addObject:[NSString stringWithFormat:@"%@ [%@%@]", mk[@"modName"], mk[@"label"], exists ? @" ✓" : @""]];
            }
            [smTxt addArrangedSubview:mkLabel([summaryParts componentsJoinedByString:@" · "], 12, UIFontWeightRegular, kInkSecondary)];
            [smHdr addArrangedSubview:smTxt];
            [smBox addArrangedSubview:smHdr];

            if (missingCnt > 0) {
                SDVAppleButton *autoBtn = mkIOSButton([NSString stringWithFormat:@"⚡ Tự gắn %lu phím tắt còn thiếu lên màn hình", (unsigned long)missingCnt], @"bolt.badge.checkmark.fill", kTintGreen, UIColor.whiteColor, 13, UIEdgeInsetsMake(9, 12, 9, 12));
                [autoBtn addTarget:self action:@selector(autoBindModHotkeysTapped) forControlEvents:UIControlEventTouchUpInside];
                [smBox addArrangedSubview:autoBtn];
            } else {
                [smBox addArrangedSubview:mkLabel(@"✓ Toàn bộ phím tắt của các Mod trên đã có sẵn trên màn hình!", 12, UIFontWeightSemibold, kTintGreen)];
            }
            [_pane addArrangedSubview:mkGroupedCard(smBox, UIEdgeInsetsMake(11, 14, 11, 14))];
        }

        [_pane addArrangedSubview:mkSectionTitle(@"Nút phím máy tính tùy chọn (PC Keys)")];
        {
            NSMutableArray<UIView *> *ckRows = [NSMutableArray array];
            UIStackView *addRow = mkHStack(10);
            [addRow addArrangedSubview:mkSettingsIconBadge(@"keyboard.fill", kTintPurple, 28)];
            UIStackView *addTxt = mkVStack(1);
            [addTxt addArrangedSubview:mkLabel([NSString stringWithFormat:@"Nút phím PC trên màn hình (%lu/16)", (unsigned long)_mobileCfg.customKeys.count], 13.5, UIFontWeightSemibold, kInkPrimary)];
            [addTxt addArrangedSubview:mkLabel(@"Chạm phím bên dưới để thêm ngay · Bấm Edit Layout để kéo vị trí & cỡ", 11.5, UIFontWeightRegular, kInkSecondary)];
            SDVAppleButton *editBtn = mkIOSButton(@"Edit Layout", @"slider.horizontal.below.rectangle", kTintBlue, UIColor.whiteColor, 12.5, UIEdgeInsetsMake(8, 11, 8, 11));
            [editBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [editBtn addTarget:self action:@selector(enterMobileEditLayoutTapped) forControlEvents:UIControlEventTouchUpInside];
            [addRow addArrangedSubview:addTxt];
            [addRow addArrangedSubview:editBtn];
            [ckRows addObject:addRow];

            static NSArray<NSDictionary *> *kAllPcKeys = nil;
            if (!kAllPcKeys) {
                kAllPcKeys = @[
                    @{@"l": @"P",    @"k": @80},  @{@"l": @"I",    @"k": @73},  @{@"l": @"F1",   @"k": @112}, @{@"l": @"TAB",  @"k": @9},
                    @{@"l": @"ESC",  @"k": @27},  @{@"l": @"SHFT", @"k": @160}, @{@"l": @"CTRL", @"k": @162}, @{@"l": @"ALT",  @"k": @164},
                    @{@"l": @"SPC",  @"k": @32},  @{@"l": @"ENT",  @"k": @13},  @{@"l": @"T",    @"k": @84},  @{@"l": @"Y",    @"k": @89},
                    @{@"l": @"F2",   @"k": @113}, @{@"l": @"F3",   @"k": @114}, @{@"l": @"F4",   @"k": @115}, @{@"l": @"F5",   @"k": @116},
                    @{@"l": @"F6",   @"k": @117}, @{@"l": @"F7",   @"k": @118}, @{@"l": @"F8",   @"k": @119}, @{@"l": @"F9",   @"k": @120},
                    @{@"l": @"F10",  @"k": @121}, @{@"l": @"F11",  @"k": @122}, @{@"l": @"F12",  @"k": @123}, @{@"l": @"BCK",  @"k": @8},
                    @{@"l": @"A",    @"k": @65},  @{@"l": @"B",    @"k": @66},  @{@"l": @"C",    @"k": @67},  @{@"l": @"D",    @"k": @68},
                    @{@"l": @"E",    @"k": @69},  @{@"l": @"F",    @"k": @70},  @{@"l": @"G",    @"k": @71},  @{@"l": @"H",    @"k": @72},
                    @{@"l": @"J",    @"k": @74},  @{@"l": @"K",    @"k": @75},  @{@"l": @"L",    @"k": @76},  @{@"l": @"M",    @"k": @77},
                    @{@"l": @"N",    @"k": @78},  @{@"l": @"O",    @"k": @79},  @{@"l": @"Q",    @"k": @81},  @{@"l": @"R",    @"k": @82},
                    @{@"l": @"S",    @"k": @83},  @{@"l": @"U",    @"k": @85},  @{@"l": @"V",    @"k": @86},  @{@"l": @"W",    @"k": @87},
                    @{@"l": @"X",    @"k": @88},  @{@"l": @"Z",    @"k": @90},  @{@"l": @"1",    @"k": @49},  @{@"l": @"2",    @"k": @50},
                    @{@"l": @"3",    @"k": @51},  @{@"l": @"4",    @"k": @52},  @{@"l": @"5",    @"k": @53},  @{@"l": @"6",    @"k": @54},
                    @{@"l": @"7",    @"k": @55},  @{@"l": @"8",    @"k": @56},  @{@"l": @"9",    @"k": @57},  @{@"l": @"0",    @"k": @48},
                    @{@"l": @"-",    @"k": @189}, @{@"l": @"+",    @"k": @187}, @{@"l": @"[",    @"k": @219}, @{@"l": @"]",    @"k": @221},
                    @{@"l": @"~",    @"k": @192}, @{@"l": @"UP",   @"k": @38},  @{@"l": @"DN",   @"k": @40},  @{@"l": @"LT",   @"k": @37},
                    @{@"l": @"RT",   @"k": @39}
                ];
            }
            UIStackView *gridBox = mkVStack(6);
            [gridBox addArrangedSubview:mkLabel(@"Hàng tím là các phím Mod PC thông dụng nhất (nhấn 1 chạm để thêm):", 11.5, UIFontWeightMedium, kInkSecondary)];
            NSInteger cols = 8;
            NSInteger total = (NSInteger)kAllPcKeys.count;
            for (NSInteger r = 0; r < (total + cols - 1) / cols; r++) {
                UIStackView *gRow = mkHStack(5);
                gRow.distribution = UIStackViewDistributionFillEqually;
                for (NSInteger c = 0; c < cols; c++) {
                    NSInteger idx = r * cols + c;
                    if (idx < total) {
                        NSDictionary *kd = kAllPcKeys[idx];
                        BOOL isHot = (idx < 12);
                        UIColor *bg = isHot ? [kTintPurple colorWithAlphaComponent:0.16] : kBgCardSubtle;
                        UIColor *fg = isHot ? kTintPurple : kInkPrimary;
                        SDVAppleButton *kb = mkIOSButton(kd[@"l"], nil, bg, fg, 12, UIEdgeInsetsMake(7, 2, 7, 2));
                        kb.layer.cornerRadius = 7.5;
                        kb.tag = 6000 + [kd[@"k"] integerValue];
                        kb.accessibilityValue = kd[@"l"];
                        [kb addTarget:self action:@selector(pcKeyGridButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
                        [gRow addArrangedSubview:kb];
                    } else {
                        [gRow addArrangedSubview:[UIView new]];
                    }
                }
                [gridBox addArrangedSubview:gRow];
            }
            [ckRows addObject:gridBox];
            [_pane addArrangedSubview:mkGroupedRows(ckRows, 14)];

            if (_mobileCfg.customKeys.count > 0) {
                [_pane addArrangedSubview:mkSectionTitle(@"Danh sách phím đang hiện trên màn hình")];
                NSMutableArray<UIView *> *activeKeys = [NSMutableArray array];
                for (SDVCustomKeyEntry *ce in _mobileCfg.customKeys) {
                    UIStackView *kr = mkHStack(10);
                    [kr addArrangedSubview:mkBadgePill(ce.label ?: @"KEY", [kTintPurple colorWithAlphaComponent:0.16], kTintPurple, 12)];
                    UIStackView *kt = mkVStack(1);
                    [kt addArrangedSubview:mkLabel([NSString stringWithFormat:@"Phím %@ (KeyCode %ld)", ce.label, (long)ce.keyCode], 13, UIFontWeightSemibold, kInkPrimary)];
                    [kt addArrangedSubview:mkLabel([NSString stringWithFormat:@"Vị trí %.0f%%, %.0f%% · Cỡ %.0f%% × %.0f%%", ce.x * 100, ce.y * 100, ce.w * 100, ce.h * 100], 11.5, UIFontWeightRegular, kInkSecondary)];
                    [kr addArrangedSubview:kt];
                    [kr addArrangedSubview:[UIView new]];
                    SDVAppleButton *delBtn = mkIOSButton(@"Xóa", @"trash", [kTintRed colorWithAlphaComponent:0.14], kTintRed, 12, UIEdgeInsetsMake(6, 10, 6, 10));
                    delBtn.tag = 5000 + ce.keyId;
                    [delBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
                    [delBtn addTarget:self action:@selector(deleteCustomPcKeyTapped:) forControlEvents:UIControlEventTouchUpInside];
                    [kr addArrangedSubview:delBtn];
                    [activeKeys addObject:kr];
                }
                [_pane addArrangedSubview:mkGroupedRows(activeKeys, 46)];
            }
        }
    } else {
        // ==================== TAB 3: HIỆU NĂNG, BỘ NHỚ RAM, ÂM THANH & PIN ====================
        [_pane addArrangedSubview:mkSectionTitle(@"Bộ nhớ RAM & Tối ưu 4 lớp")];

        UIStackView *ramRow = mkVStack(7);
        UIStackView *ramHdr = mkHStack(8);
        [ramHdr addArrangedSubview:mkSettingsIconBadge(@"memorychip.fill", kTintPurple, 28)];
        [ramHdr addArrangedSubview:mkLabel(@"Bộ nhớ RAM", 14, UIFontWeightSemibold, kInkPrimary)];
        [ramHdr addArrangedSubview:[UIView new]];
        _ramHeadlineLbl = mkLabel(@"-- MB", 13.5, UIFontWeightSemibold, kTintGreen);
        _ramHeadlineLbl.font = iosMonoDigits(13.5, UIFontWeightSemibold);
        [ramHdr addArrangedSubview:_ramHeadlineLbl];
        [ramRow addArrangedSubview:ramHdr];

        _ramBarTrack = [UIView new];
        _ramBarTrack.backgroundColor = kBgCardSubtle;
        _ramBarTrack.layer.cornerRadius = 4.0;
        _ramBarTrack.clipsToBounds = YES;
        [_ramBarTrack.heightAnchor constraintEqualToConstant:8].active = YES;

        _ramBarFill = [UIView new];
        _ramBarFill.backgroundColor = kTintGreen;
        _ramBarFill.layer.cornerRadius = 4.0;
        _ramBarFill.translatesAutoresizingMaskIntoConstraints = NO;
        [_ramBarTrack addSubview:_ramBarFill];
        _ramBarFillW = [_ramBarFill.widthAnchor constraintEqualToConstant:40];
        [NSLayoutConstraint activateConstraints:@[
            [_ramBarFill.leadingAnchor constraintEqualToAnchor:_ramBarTrack.leadingAnchor],
            [_ramBarFill.topAnchor constraintEqualToAnchor:_ramBarTrack.topAnchor],
            [_ramBarFill.bottomAnchor constraintEqualToAnchor:_ramBarTrack.bottomAnchor],
            _ramBarFillW
        ]];
        [ramRow addArrangedSubview:_ramBarTrack];

        _ramDetailLbl = mkLabel(@"Đang đọc bộ nhớ…", 12, UIFontWeightRegular, kInkSecondary);
        _ramDetailLbl.font = iosMonoDigits(12, UIFontWeightRegular);
        [ramRow addArrangedSubview:_ramDetailLbl];

        UIStackView *resRow = mkHStack(10);
        [resRow addArrangedSubview:mkSettingsIconBadge(@"display", kTintIndigo, 28)];
        UIStackView *resTxt = mkVStack(1);
        [resTxt addArrangedSubview:mkLabel(@"Độ phân giải & GC RAM động", 13.5, UIFontWeightRegular, kInkPrimary)];
        [resTxt addArrangedSubview:mkLabel(@"Tự động theo màn hình + RAM thực máy (384M ≤4GB · 640M ≥6GB)", 11.5, UIFontWeightRegular, kInkSecondary)];
        [resRow addArrangedSubview:resTxt];
        [resRow addArrangedSubview:[UIView new]];
        [resRow addArrangedSubview:mkBadgePill(@"Tự động", [kTintGreen colorWithAlphaComponent:0.14], kTintGreen, 11.5)];

        UIView *alertSwRow = [self mkSettingsSwitchRow:@"Cảnh báo lưu game khi RAM đạt 85% / 90%" icon:@"exclamationmark.shield.fill" color:kTintRed on:SDVRamMonitor.shared.ramAlertEnabled tag:22];
        UIView *hudSwRow = [self mkSettingsSwitchRow:@"Thanh đo RAM & FPS nổi" icon:@"gauge.medium" color:kTintGreen on:SDVRamMonitor.shared.hudEnabled tag:20];
        UIView *logSwRow = [self mkSettingsSwitchRow:@"Giảm ghi log TRACE thừa" icon:@"doc.text.magnifyingglass" color:kTintOrange on:[SDVRamMonitor.shared trimLogsEnabledForDocs:_root.path] tag:21];

        UIStackView *ramBtns = mkHStack(8);
        SDVAppleButton *gcBtn = mkIOSButton(@"Dọn RAM ngay", @"sparkles", [kTintBlue colorWithAlphaComponent:0.14], kTintBlue, 13, UIEdgeInsetsMake(8, 12, 8, 12));
        [gcBtn addTarget:self action:@selector(forceGcNowTapped) forControlEvents:UIControlEventTouchUpInside];
        SDVAppleButton *rstPeak = mkIOSButton(@"Đặt lại Peak", @"arrow.counterclockwise", kBgCardSubtle, kInkPrimary, 12.5, UIEdgeInsetsMake(8, 10, 8, 10));
        [rstPeak addTarget:self action:@selector(resetRamPeakTapped) forControlEvents:UIControlEventTouchUpInside];
        SDVAppleButton *rstPos = mkIOSButton(@"Về góc trên", @"arrow.up.to.line", kBgCardSubtle, kInkPrimary, 12.5, UIEdgeInsetsMake(8, 10, 8, 10));
        [rstPos addTarget:self action:@selector(resetRamHudPosTapped) forControlEvents:UIControlEventTouchUpInside];
        [ramBtns addArrangedSubview:gcBtn];
        [ramBtns addArrangedSubview:rstPeak];
        [ramBtns addArrangedSubview:rstPos];
        [ramBtns addArrangedSubview:[UIView new]];

        [_pane addArrangedSubview:mkGroupedRows(@[ramRow, resRow, alertSwRow, hudSwRow, logSwRow, ramBtns], 52)];
        [self refreshRamCardNow];
        __weak typeof(self) weakSelf = self;
        _ramUiTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            [weakSelf refreshRamCardNow];
        }];

        // Card 2: FPS, Thời tiết & Pin
        [_pane addArrangedSubview:mkSectionTitle(@"FPS, Thời tiết & Pin")];
        UIStackView *fpsRow = mkVStack(6);
        UIStackView *fpsTop = mkHStack(10);
        [fpsTop addArrangedSubview:mkSettingsIconBadge(@"battery.75", kTintGreen, 28)];
        UIStackView *fpsTxt = mkVStack(1);
        [fpsTxt addArrangedSubview:mkLabel(@"Tiết kiệm pin / Giảm nóng máy (Giới hạn FPS)", 13.5, UIFontWeightRegular, kInkPrimary)];
        [fpsTxt addArrangedSubview:mkLabel(@"Logic game vẫn chuẩn 60Hz · tự lên 60 FPS khi câu cá / minigame", 11.5, UIFontWeightRegular, kInkSecondary)];
        [fpsTop addArrangedSubview:fpsTxt];
        [fpsRow addArrangedSubview:fpsTop];
        UISegmentedControl *fpsSeg = [[UISegmentedControl alloc] initWithItems:@[@"60 FPS", @"45 FPS", @"30 FPS"]];
        NSInteger fpsIdx = (_mobileCfg.batterySaverFpsMode == 2) ? 1 : ((_mobileCfg.batterySaverFpsMode == 1) ? 2 : 0);
        fpsSeg.selectedSegmentIndex = fpsIdx;
        [fpsSeg addTarget:self action:@selector(batterySaverFpsChanged:) forControlEvents:UIControlEventValueChanged];
        [fpsRow addArrangedSubview:fpsSeg];

        UIStackView *menuFpsRow = mkVStack(6);
        UIStackView *menuFpsTop = mkHStack(10);
        [menuFpsTop addArrangedSubview:mkSettingsIconBadge(@"speedometer", kTintBlue, 28)];
        UIStackView *menuFpsTxt = mkVStack(1);
        [menuFpsTxt addArrangedSubview:mkLabel(@"FPS trong Menu game (Balo, Rương, Shop)", 13.5, UIFontWeightRegular, kInkPrimary)];
        [menuFpsTxt addArrangedSubview:mkLabel(@"60 FPS giúp kéo đồ Balo & cuộn Shop mượt · 30 FPS mát máy, tiết kiệm pin hơn", 11.5, UIFontWeightRegular, kInkSecondary)];
        [menuFpsTop addArrangedSubview:menuFpsTxt];
        [menuFpsRow addArrangedSubview:menuFpsTop];
        UISegmentedControl *menuFpsSeg = [[UISegmentedControl alloc] initWithItems:@[@"60 FPS (Mượt)", @"30 FPS (Tiết kiệm)"]];
        menuFpsSeg.selectedSegmentIndex = _mobileCfg.menuFps30 ? 1 : 0;
        [menuFpsSeg addTarget:self action:@selector(menuFpsChanged:) forControlEvents:UIControlEventValueChanged];
        [menuFpsRow addArrangedSubview:menuFpsSeg];

        [_pane addArrangedSubview:mkGroupedRows(@[
            [self mkSettingsSwitchRow:@"Giảm hạt thời tiết thừa (giữ mượt FPS lúc mưa/bão)" icon:@"cloud.rain.fill" color:kTintTeal on:_mobileCfg.reduceWeather tag:39],
            fpsRow,
            menuFpsRow,
            [self mkSettingsSwitchRow:@"Hiệu ứng nền động Cực Quang (Aurora) trong Mod Garden" icon:@"sparkles" color:kTintPurple on:_mobileCfg.auroraBackdrop tag:55]
        ], 48)];

        // Card 3: Lưu tự động, Tạm dừng & Âm thanh
        [_pane addArrangedSubview:mkSectionTitle(@"Hệ thống, Lưu tự động & Âm thanh")];
        UIStackView *asRow = mkVStack(6);
        UIStackView *asTop = mkHStack(10);
        [asTop addArrangedSubview:mkSettingsIconBadge(@"clock.arrow.circlepath", kTintTeal, 28)];
        UIStackView *asTxt = mkVStack(1);
        [asTxt addArrangedSubview:mkLabel(@"Tự động lưu định kỳ (slot [AUTO])", 13.5, UIFontWeightRegular, kInkPrimary)];
        [asTxt addArrangedSubview:mkLabel(@"Chỉ lưu khi đứng yên ngoài mỏ/hang để không khựng khi đánh quái", 11.5, UIFontWeightRegular, kInkSecondary)];
        [asTop addArrangedSubview:asTxt];
        [asRow addArrangedSubview:asTop];
        UISegmentedControl *asSeg = [[UISegmentedControl alloc] initWithItems:@[@"Tắt", @"3 phút", @"5 phút", @"10 phút"]];
        NSInteger asIdx = 0;
        if (_mobileCfg.autoSaveMinutes == 3) asIdx = 1;
        else if (_mobileCfg.autoSaveMinutes == 5) asIdx = 2;
        else if (_mobileCfg.autoSaveMinutes == 10) asIdx = 3;
        asSeg.selectedSegmentIndex = asIdx;
        [asSeg addTarget:self action:@selector(autoSaveMinutesChanged:) forControlEvents:UIControlEventValueChanged];
        [asRow addArrangedSubview:asSeg];

        [_pane addArrangedSubview:mkGroupedRows(@[
            asRow,
            [self mkSettingsSwitchRow:@"Tự tạm dừng game khi vuốt Thông báo / chuyển app" icon:@"pause.circle.fill" color:kTintIndigo on:_mobileCfg.autoPauseOnBackground tag:45],
            [self mkSettingsSwitchRow:@"Rung nhẹ Haptic khi cá cắn câu" icon:@"waveform.path" color:kTintBlue on:_mobileCfg.fishingHaptic tag:46],
            [self mkSettingsSwitchRow:@"Tôn trọng nút gạt im lặng iPhone (tắt tiếng khi gạt)" icon:@"bell.slash.fill" color:kTintOrange on:_mobileCfg.respectMuteSwitch tag:52]
        ], 48)];
    }
}

-(void)ctrlSectionChanged:(UISegmentedControl *)seg {
    _ctrlSectionTab = seg.selectedSegmentIndex;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self renderAll:NO];
}

-(void)uiSubTabChanged:(UISegmentedControl *)seg {
    _uiSubTab = seg.selectedSegmentIndex;
    [self renderAll:NO];
}

-(void)syncLiveLabels {
    NSDictionary<NSNumber *, NSString *> *txt = @{
        @1:  [NSString stringWithFormat:@"%d%%", (int)roundf(_uiCfg.menuBarScale * 100)],
        @2:  [NSString stringWithFormat:@"%d px", (int)roundf(_uiCfg.menuBarLeftX)],
        @3:  [NSString stringWithFormat:@"%d px", (int)roundf(_uiCfg.menuBarTopY)],
        @4:  [NSString stringWithFormat:@"%d px", (int)roundf(_uiCfg.menuBarGap)],
        @5:  [NSString stringWithFormat:@"%d%%", (int)roundf(_uiCfg.padScale * 100)],
        @7:  [NSString stringWithFormat:@"%d%%", (int)roundf(_uiCfg.menuBarOpacity * 100)],
        @8:  [NSString stringWithFormat:@"%d%%", (int)roundf(_uiCfg.abxyScale * 100)],
        @9:  [NSString stringWithFormat:@"%d%%", (int)roundf(_uiCfg.abxyOpacity * 100)],
        @10: [NSString stringWithFormat:@"%d%%", (int)roundf(_uiCfg.abxySpacing * 100)],
        @11: [NSString stringWithFormat:@"%d%%", (int)roundf(_uiCfg.trigScale * 100)],
        @12: [NSString stringWithFormat:@"%d%%", (int)roundf(_uiCfg.trigOpacity * 100)],
        @13: [NSString stringWithFormat:@"%d%%", (int)roundf(_uiCfg.joyScale * 100)],
        @14: [NSString stringWithFormat:@"%d%%", (int)roundf(_uiCfg.joyOpacity * 100)],
        @15: [NSString stringWithFormat:@"%d%%", (int)roundf(_uiCfg.modalScale * 100)],
        @16: [NSString stringWithFormat:@"%d%%", (int)roundf(_uiCfg.drawerScale * 100)],
        @17: [NSString stringWithFormat:@"%d%%", (int)roundf((_mobileCfg ? _mobileCfg.buttonScale : 1.0f) * 100)],
        @18: (_mobileCfg && _mobileCfg.uiScaleOverride >= 0.73f)
            ? [NSString stringWithFormat:@"%d%%", (int)roundf(_mobileCfg.uiScaleOverride * 100)]
            : @"Mặc định",
        @19: (!_mobileCfg || _mobileCfg.safePaddingPx < 0)
            ? @"Tự động"
            : [NSString stringWithFormat:@"%ld px", (long)_mobileCfg.safePaddingPx],
        @20: [NSString stringWithFormat:@"%d%%", (int)roundf((_mobileCfg ? _mobileCfg.pixelOpacity : 1.0f) * 100)],
        @21: [NSString stringWithFormat:@"%d%%", (int)roundf((_mobileCfg ? _mobileCfg.joyDeadzone : 0.11f) * 100)],
        @22: [NSString stringWithFormat:@"%d%%", (int)roundf((_mobileCfg ? _mobileCfg.toolbarSize : 1.00f) * 100)],
        @23: [NSString stringWithFormat:@"%d%%", (int)roundf((_mobileCfg ? _mobileCfg.toolbarOpacity : 0.90f) * 100)],
        @24: (!_mobileCfg || _mobileCfg.toolbarVisibleRows <= 0)
            ? @"Tự động (tràn dọc)"
            : [NSString stringWithFormat:@"%ld ô / cột", (long)_mobileCfg.toolbarVisibleRows]
    };
    for (NSNumber *k in txt) {
        UILabel *l = _sliderLabels[k];
        if (l) l.text = txt[k];
    }
    if (_lblPreviewMeta) {
        _lblPreviewMeta.text = [NSString stringWithFormat:@"%d%% · Rõ %d%% · L%d T%d",
            (int)roundf(_uiCfg.menuBarScale * 100), (int)roundf(_uiCfg.menuBarOpacity * 100),
            (int)roundf(_uiCfg.menuBarLeftX), (int)roundf(_uiCfg.menuBarTopY)];
    }
    if (_preview) [_preview updateWithConfig:_uiCfg];
}

-(void)sliderChanged:(UISlider *)sl {
    float q = roundf(sl.value * 20.0f) / 20.0f;
    switch (sl.tag) {
        case 1:  _uiCfg.menuBarScale   = sdvClampf(q, 0.55f, 2.20f); break;
        case 2:  _uiCfg.menuBarLeftX   = roundf(sl.value); break;
        case 3:  _uiCfg.menuBarTopY    = roundf(sl.value); break;
        case 4:  _uiCfg.menuBarGap     = roundf(sl.value); break;
        case 5:  _uiCfg.padScale       = sdvClampf(q, 0.50f, 2.00f); break;
        case 7:  _uiCfg.menuBarOpacity = sdvClampf(q, 0.10f, 1.00f); break;
        case 8:  _uiCfg.abxyScale      = sdvClampf(q, 0.50f, 2.20f); break;
        case 9:  _uiCfg.abxyOpacity    = sdvClampf(q, 0.05f, 1.00f); break;
        case 10: _uiCfg.abxySpacing    = sdvClampf(q, 0.60f, 1.80f); break;
        case 11: _uiCfg.trigScale      = sdvClampf(q, 0.50f, 2.20f); break;
        case 12: _uiCfg.trigOpacity    = sdvClampf(q, 0.05f, 1.00f); break;
        case 13: _uiCfg.joyScale       = sdvClampf(q, 0.50f, 2.20f); break;
        case 14: _uiCfg.joyOpacity     = sdvClampf(q, 0.05f, 1.00f); break;
        case 15: _uiCfg.modalScale     = sdvClampf(q, 1.00f, 2.00f); break;
        case 16: _uiCfg.drawerScale    = sdvClampf(q, 0.80f, 2.00f); break;
        case 17:
            if (!_mobileCfg) _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
            _mobileCfg.buttonScale = sdvClampf(q, 0.75f, 1.45f);
            [self syncLiveLabels];
            {
                NSTimeInterval nowM = NSDate.date.timeIntervalSinceReferenceDate;
                if (nowM - _lastLiveSave > 0.10) {
                    _lastLiveSave = nowM;
                    [_mobileCfg saveToDocuments:_root.path];
                }
            }
            return;
        case 18:
            if (!_mobileCfg) _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
            _mobileCfg.uiScaleOverride = (sl.value < 0.73f) ? 0.0f : sdvClampf(q, 0.75f, 1.50f);
            [self syncLiveLabels];
            {
                NSTimeInterval nowM = NSDate.date.timeIntervalSinceReferenceDate;
                if (nowM - _lastLiveSave > 0.10) {
                    _lastLiveSave = nowM;
                    [_mobileCfg saveToDocuments:_root.path];
                }
            }
            return;
        case 19:
            if (!_mobileCfg) _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
            _mobileCfg.safePaddingPx = (sl.value < 0.0f) ? -1 : MAX(0, MIN(80, (NSInteger)roundf(sl.value)));
            [self syncLiveLabels];
            {
                NSTimeInterval nowM = NSDate.date.timeIntervalSinceReferenceDate;
                if (nowM - _lastLiveSave > 0.10) {
                    _lastLiveSave = nowM;
                    [_mobileCfg saveToDocuments:_root.path];
                }
            }
            return;
        case 20:
            if (!_mobileCfg) _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
            _mobileCfg.pixelOpacity = sdvClampf(q, 0.25f, 1.00f);
            [self syncLiveLabels];
            {
                NSTimeInterval nowM = NSDate.date.timeIntervalSinceReferenceDate;
                if (nowM - _lastLiveSave > 0.10) {
                    _lastLiveSave = nowM;
                    [_mobileCfg saveToDocuments:_root.path];
                }
            }
            return;
        case 21:
            if (!_mobileCfg) _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
            _mobileCfg.joyDeadzone = sdvClampf(roundf(sl.value * 100.0f) / 100.0f, 0.05f, 0.25f);
            [self syncLiveLabels];
            {
                NSTimeInterval nowM = NSDate.date.timeIntervalSinceReferenceDate;
                if (nowM - _lastLiveSave > 0.10) {
                    _lastLiveSave = nowM;
                    [_mobileCfg saveToDocuments:_root.path];
                }
            }
            return;
        case 22:
            if (!_mobileCfg) _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
            if (!_mobileCfg.verticalToolbar) { _mobileCfg.verticalToolbar = YES; _tbAutoEnabledBySlider = YES; }
            _mobileCfg.toolbarSize = sdvClampf(q, 0.55f, 1.50f);
            [self syncLiveLabels];
            {
                NSTimeInterval nowM = NSDate.date.timeIntervalSinceReferenceDate;
                if (nowM - _lastLiveSave > 0.10) {
                    _lastLiveSave = nowM;
                    [_mobileCfg saveToDocuments:_root.path];
                }
            }
            return;
        case 23:
            if (!_mobileCfg) _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
            if (!_mobileCfg.verticalToolbar) { _mobileCfg.verticalToolbar = YES; _tbAutoEnabledBySlider = YES; }
            _mobileCfg.toolbarOpacity = sdvClampf(q, 0.20f, 1.00f);
            [self syncLiveLabels];
            {
                NSTimeInterval nowM = NSDate.date.timeIntervalSinceReferenceDate;
                if (nowM - _lastLiveSave > 0.10) {
                    _lastLiveSave = nowM;
                    [_mobileCfg saveToDocuments:_root.path];
                }
            }
            return;
        case 24:
            if (!_mobileCfg) _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
            if (!_mobileCfg.verticalToolbar) { _mobileCfg.verticalToolbar = YES; _tbAutoEnabledBySlider = YES; }
            _mobileCfg.toolbarVisibleRows = (sl.value < 3.5f) ? 0 : MAX(4, MIN(12, (NSInteger)roundf(sl.value)));
            [self syncLiveLabels];
            {
                NSTimeInterval nowM = NSDate.date.timeIntervalSinceReferenceDate;
                if (nowM - _lastLiveSave > 0.10) {
                    _lastLiveSave = nowM;
                    [_mobileCfg saveToDocuments:_root.path];
                }
            }
            return;
    }
    [self syncLiveLabels];
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (now - _lastLiveSave > 0.10) {
        _lastLiveSave = now;
        [_uiCfg saveToDocuments:_root.path];
    }
}

-(void)sliderEnded:(UISlider *)sl {
    if (sl.tag >= 17 && sl.tag <= 24) {
        [_mobileCfg saveToDocuments:_root.path];
        if (_tbAutoEnabledBySlider) {
            _tbAutoEnabledBySlider = NO;
            [self renderAll:NO];
        }
        return;
    }
    [_uiCfg saveToDocuments:_root.path];
}

-(void)toolbarSideChanged:(UISegmentedControl *)seg {
    _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
    _mobileCfg.verticalToolbar = YES;
    _mobileCfg.toolbarSide = (seg.selectedSegmentIndex == 1) ? 1 : 0;
    [_mobileCfg saveToDocuments:_root.path];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self renderAll:NO];
}

-(void)toolbarColumnsChanged:(UISegmentedControl *)seg {
    _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
    _mobileCfg.verticalToolbar = YES;
    _mobileCfg.toolbarColumns = MAX(1, MIN(3, seg.selectedSegmentIndex + 1));
    [_mobileCfg saveToDocuments:_root.path];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self renderAll:NO];
}

-(void)editToolbarLayoutTapped {
    if (_veil) return;
    _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
    if (!_mobileCfg.verticalToolbar) {
        _mobileCfg.verticalToolbar = YES;
        [_mobileCfg saveToDocuments:_root.path];
    }
    [self enterMobileEditLayoutTapped];
}

-(void)batterySaverFpsChanged:(UISegmentedControl *)seg {
    _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
    NSInteger idx = seg.selectedSegmentIndex;
    // Seg 0 = 60 FPS (0), Seg 1 = 45 FPS (2), Seg 2 = 30 FPS (1) — preserves backwards compatibility with saver30fps=1!
    _mobileCfg.batterySaverFpsMode = (idx == 1) ? 2 : ((idx == 2) ? 1 : 0);
    [_mobileCfg saveToDocuments:_root.path];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}

-(void)menuFpsChanged:(UISegmentedControl *)seg {
    _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
    _mobileCfg.menuFps30 = (seg.selectedSegmentIndex == 1);
    [_mobileCfg saveToDocuments:_root.path];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}

-(void)autoSaveMinutesChanged:(UISegmentedControl *)seg {
    _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
    NSInteger map[4] = {0, 3, 5, 10};
    NSInteger idx = seg.selectedSegmentIndex;
    _mobileCfg.autoSaveMinutes = (idx >= 0 && idx < 4) ? map[idx] : 0;
    [_mobileCfg saveToDocuments:_root.path];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}

-(void)mobileModeChanged:(UISegmentedControl *)seg {
    if (!_mobileCfg) _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
    NSInteger idx = seg.selectedSegmentIndex;
    _mobileCfg.mode = MAX(1, MIN(4, idx + 1));
    [_mobileCfg saveToDocuments:_root.path];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self renderAll:NO];
}

-(void)enterMobileEditLayoutTapped {
    if (_veil) return;
    [SDVMobileCtrlConfig triggerEditLayoutInDocs:_root.path];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
#ifdef GARDEN_IN_GAME
    [self closeManager];
#endif
}

-(void)deleteCustomPcKeyTapped:(UIButton *)btn {
    NSInteger kid = btn.tag - 5000;
    if (kid <= 0) return;
    _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
    [_mobileCfg removeCustomKeyWithId:kid];
    [_mobileCfg saveToDocuments:_root.path];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self renderAll:NO];
}

-(void)openAddPcKeySheet {
    if (_veil) return;
    _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
    _showPcKeyPicker = !_showPcKeyPicker;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self renderAll:NO];
}

-(void)pcKeyGridButtonTapped:(UIButton *)btn {
    if (_veil) return;
    NSInteger keyCode = btn.tag - 6000;
    NSString *label = btn.accessibilityValue ?: @"KEY";
    if (keyCode <= 0) return;
    _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
    if (_mobileCfg.customKeys.count >= 16) {
        _message = @"Đã đạt tối đa 16 nút phím PC tùy chọn.";
        _messageIsError = YES;
        [self renderAll:NO];
        return;
    }
    [_mobileCfg addCustomKeyLabel:label keyCode:keyCode];
    [_mobileCfg saveToDocuments:_root.path];
    _message = [NSString stringWithFormat:@"Đã thêm nút [%@] lên màn hình! Bấm Edit Layout để kéo vị trí & chỉnh kích thước.", label];
    _messageIsError = NO;
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self renderAll:NO];
}

static BOOL sdvResolveXnaKeyString(NSString *rawKey, NSString **outLabel, NSInteger *outCode) {
    if (![rawKey isKindOfClass:NSString.class] || !rawKey.length) return NO;
    // Take first primary token if keybind list e.g. "LeftShift + F1, J" -> last key in chord or first standalone key
    NSString *firstBind = [[rawKey componentsSeparatedByString:@","].firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *chordParts = [firstBind componentsSeparatedByString:@"+"];
    NSString *tok = [[chordParts.lastObject ?: firstBind stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if (!tok.length || [tok isEqualToString:@"NONE"]) return NO;

    if (tok.length == 1) {
        unichar c = [tok characterAtIndex:0];
        if (c >= 'A' && c <= 'Z') { *outLabel = tok; *outCode = (NSInteger)c; return YES; }
        if (c >= '0' && c <= '9') { *outLabel = tok; *outCode = (NSInteger)c; return YES; }
    }
    if ([tok hasPrefix:@"D"] && tok.length == 2 && [tok characterAtIndex:1] >= '0' && [tok characterAtIndex:1] <= '9') {
        NSString *d = [tok substringFromIndex:1];
        *outLabel = d; *outCode = (NSInteger)[d characterAtIndex:0]; return YES;
    }
    if ([tok hasPrefix:@"F"] && tok.length >= 2 && tok.length <= 3) {
        NSInteger fn = [[tok substringFromIndex:1] integerValue];
        if (fn >= 1 && fn <= 12) { *outLabel = tok; *outCode = 111 + fn; return YES; }
    }
    NSDictionary<NSString *, NSArray *> *named = @{
        @"BACK": @[@"BCK", @8], @"BACKSPACE": @[@"BCK", @8],
        @"TAB": @[@"TAB", @9], @"ENTER": @[@"ENT", @13], @"RETURN": @[@"ENT", @13],
        @"ESCAPE": @[@"ESC", @27], @"ESC": @[@"ESC", @27], @"SPACE": @[@"SPC", @32],
        @"LEFTSHIFT": @[@"SHFT", @160], @"RIGHTSHIFT": @[@"SHFT", @160],
        @"LEFTCONTROL": @[@"CTRL", @162], @"RIGHTCONTROL": @[@"CTRL", @162],
        @"LEFTALT": @[@"ALT", @164], @"RIGHTALT": @[@"ALT", @164],
        @"OEMTILDE": @[@"~", @192], @"OEMMINUS": @[@"-", @189], @"OEMPLUS": @[@"+", @187],
        @"OEMOPENBRACKETS": @[@"[", @219], @"OEMCLOSEBRACKETS": @[@"]", @221]
    };
    NSArray *hit = named[tok];
    if (hit) {
        *outLabel = hit[0];
        *outCode = [hit[1] integerValue];
        return YES;
    }
    return NO;
}

-(NSArray<NSDictionary *> *)detectInstalledModHotkeys {
    NSArray<NSDictionary *> *cat = _catalog.count ? _catalog : (_root.path.length ? modCatalog(_root.path) : @[]);
    if (!cat.count) return @[];
    if (!_mobileCfg) _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];

    NSMutableSet<NSNumber *> *existingCodes = [NSMutableSet set];
    for (SDVCustomKeyEntry *ce in _mobileCfg.customKeys) [existingCodes addObject:@(ce.keyCode)];

    NSDictionary<NSString *, NSDictionary *> *knownMods = @{
        @"cjbok.cheatsmenu":          @{@"short": @"CJB Cheats",    @"keys": @[@"OpenMenuKey"],               @"defL": @"P",   @"defK": @80},
        @"cjbok.itemspawner":         @{@"short": @"CJB Spawner",   @"keys": @[@"ShowMenuKey"],               @"defL": @"I",   @"defK": @73},
        @"pathoschild.lookupanything":@{@"short": @"Lookup Anything",@"keys": @[@"ToggleLookup", @"Keys.ToggleLookup"], @"defL": @"F1", @"defK": @112},
        @"annosz.uiinfosuite2":       @{@"short": @"UI Info Suite 2",@"keys": @[@"OpenCalendarAndQuestKeybind"], @"defL": @"F2", @"defK": @113},
        @"bouhm.npcmaplocations":     @{@"short": @"NPC Map",       @"keys": @[@"MenuKey"],                   @"defL": @"M",   @"defK": @77},
        @"pathoschild.tractormod":    @{@"short": @"Tractor Mod",   @"keys": @[@"SummonKey", @"Controls.SummonTractor"], @"defL": @"BCK", @"defK": @8},
        @"pathoschild.automate":      @{@"short": @"Automate",      @"keys": @[@"ToggleOverlayKey", @"Controls.ToggleOverlay"], @"defL": @"U", @"defK": @85},
        @"cantorsdust.timespeed":     @{@"short": @"TimeSpeed",     @"keys": @[@"FreezeTimeKey", @"Keys.FreezeTime"], @"defL": @"N", @"defK": @78}
    };

    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seenCodes = [NSMutableSet set];
    for (NSDictionary *m in cat) {
        if (![m[@"enabled"] boolValue] || [m[@"protected"] boolValue]) continue;
        NSString *uidLow = [m[@"uniqueID"] isKindOfClass:NSString.class] ? [m[@"uniqueID"] lowercaseString] : @"";
        NSDictionary *spec = knownMods[uidLow];
        NSString *cfgPath = [m[@"configPath"] isKindOfClass:NSString.class] ? m[@"configPath"] : @"";
        NSDictionary *cfgJson = nil;
        if (cfgPath.length && [fm() fileExistsAtPath:cfgPath]) {
            @try {
                id parsed = jsonAt(cfgPath);
                if ([parsed isKindOfClass:NSDictionary.class]) cfgJson = parsed;
            } @catch (NSException *ex) { }
        }

        if (spec) {
            NSString *lbl = spec[@"defL"];
            NSInteger code = [spec[@"defK"] integerValue];
            if (cfgJson) {
                for (NSString *kp in spec[@"keys"]) {
                    NSArray<NSString *> *segs = [kp componentsSeparatedByString:@"."];
                    id cur = cfgJson;
                    for (NSString *s in segs) {
                        if ([cur isKindOfClass:NSDictionary.class]) cur = dictValueCI(cur, s);
                        else { cur = nil; break; }
                    }
                    NSString *candL = nil; NSInteger candK = 0;
                    if ([cur isKindOfClass:NSString.class] && sdvResolveXnaKeyString(cur, &candL, &candK)) {
                        lbl = candL; code = candK; break;
                    }
                }
            }
            if (code > 0 && ![seenCodes containsObject:@(code)]) {
                [seenCodes addObject:@(code)];
                [out addObject:@{
                    @"modName": spec[@"short"],
                    @"label": lbl,
                    @"keyCode": @(code),
                    @"alreadyBound": @([existingCodes containsObject:@(code)])
                }];
            }
        } else if (cfgJson) {
            for (NSString *k in cfgJson.allKeys) {
                if (![k isKindOfClass:NSString.class]) continue;
                NSString *kl = k.lowercaseString;
                if ([kl hasSuffix:@"key"] || [kl hasSuffix:@"keybind"] || [kl hasSuffix:@"hotkey"]) {
                    NSString *candL = nil; NSInteger candK = 0;
                    if ([cfgJson[k] isKindOfClass:NSString.class] && sdvResolveXnaKeyString(cfgJson[k], &candL, &candK)) {
                        if (candK > 0 && ![seenCodes containsObject:@(candK)]) {
                            [seenCodes addObject:@(candK)];
                            [out addObject:@{
                                @"modName": m[@"name"] ?: uidLow,
                                @"label": candL,
                                @"keyCode": @(candK),
                                @"alreadyBound": @([existingCodes containsObject:@(candK)])
                            }];
                        }
                        break;
                    }
                }
            }
        }
    }
    return out;
}

-(void)autoBindModHotkeysTapped {
    if (_veil) return;
    _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
    NSArray<NSDictionary *> *detected = [self detectInstalledModHotkeys];
    NSUInteger added = 0;
    NSMutableArray<NSString *> *addedLabels = [NSMutableArray array];
    for (NSDictionary *mk in detected) {
        if ([mk[@"alreadyBound"] boolValue]) continue;
        if (_mobileCfg.customKeys.count >= 16) break;
        NSString *lbl = mk[@"label"] ?: @"KEY";
        NSInteger kc = [mk[@"keyCode"] integerValue];
        if (kc > 0) {
            [_mobileCfg addCustomKeyLabel:lbl keyCode:kc];
            [addedLabels addObject:lbl];
            added++;
        }
    }
    if (added > 0) {
        [_mobileCfg saveToDocuments:_root.path];
        _message = [NSString stringWithFormat:@"⚡ Đã tự gắn %lu phím tắt Mod (%@) lên màn hình! Bấm Edit Layout nếu muốn dời vị trí.", (unsigned long)added, [addedLabels componentsJoinedByString:@", "]];
        _messageIsError = NO;
        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    } else {
        _message = (_mobileCfg.customKeys.count >= 16) ? @"Đã đầy tối đa 16 nút phím PC trên màn hình." : @"Tất cả phím tắt Mod đã có sẵn trên màn hình.";
        _messageIsError = (_mobileCfg.customKeys.count >= 16);
    }
    [self renderAll:NO];
}

-(void)applyPreset:(UIButton *)btn {
    float presetVals[4] = {0.75f, 1.00f, 1.35f, 1.75f};
    NSInteger idx = btn.tag - 100;
    if (idx < 0 || idx > 3) return;
    _uiCfg.menuBarScale = presetVals[idx];
    [_uiCfg saveToDocuments:_root.path];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self renderAll:NO];
}

-(void)applyModalPreset:(UIButton *)btn {
    float vals[3] = {1.25f, 1.55f, 1.85f};
    float dVals[3] = {1.15f, 1.35f, 1.65f};
    NSInteger idx = btn.tag - 150;
    if (idx < 0 || idx > 2) return;
    _uiCfg.modalScale = vals[idx];
    _uiCfg.drawerScale = dVals[idx];
    [_uiCfg saveToDocuments:_root.path];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self renderAll:NO];
}

-(void)uiSwitchChanged:(UISwitch *)sw {
    if (sw.tag == 20) {
        [SDVRamMonitor.shared setHudEnabled:sw.isOn];
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        return;
    }
    if (sw.tag == 22) {
        [SDVRamMonitor.shared setRamAlertEnabled:sw.isOn];
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        return;
    }
    if (sw.tag == 21) {
        [SDVRamMonitor.shared savePerfConfig:1 trimLogs:sw.isOn toDocs:_root.path];
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        _message = sw.isOn
            ? @"Đã bật giảm ghi log TRACE thừa xuống ổ đĩa."
            : @"Đã tắt lọc log TRACE (ghi đầy đủ dòng TRACE vào engine-latest.log).";
        _messageIsError = NO;
        [self renderAll:NO];
        return;
    }
    if (sw.tag >= 30 && sw.tag <= 55) {
        _mobileCfg = [SDVMobileCtrlConfig loadFromDocuments:_root.path];
        switch (sw.tag) {
            case 30: _mobileCfg.autoTool = sw.isOn; break;
            case 31: _mobileCfg.autoAttack = sw.isOn; break;
            case 32: _mobileCfg.pinchZoom = sw.isOn; break;
            case 33: _mobileCfg.showTouchHint = sw.isOn; break;
            case 34: _mobileCfg.showTopUtility = sw.isOn; break;
            case 35: _mobileCfg.swapRightButtons = sw.isOn; break;
            case 36: _mobileCfg.mobileShopAndDrag = sw.isOn; break;
            case 37: _mobileCfg.autoKeyboard = sw.isOn; break;
            case 38: _mobileCfg.safeCrafting = sw.isOn; break;
            case 39: _mobileCfg.reduceWeather = sw.isOn; break;
            case 40: _mobileCfg.showEmoteButton = sw.isOn; break;
            case 41: _mobileCfg.autoRepeat = sw.isOn; break;
            case 42: _mobileCfg.restoreToolAfterAuto = sw.isOn; break;
            case 43: _mobileCfg.showSpecButton = sw.isOn; break;
            case 44: _mobileCfg.autoCombatMode = sw.isOn; break;
            case 45: _mobileCfg.autoPauseOnBackground = sw.isOn; break;
            case 46: _mobileCfg.fishingHaptic = sw.isOn; break;
            case 47: _mobileCfg.safeDialogueAndTooltip = sw.isOn; break;
            case 48: _mobileCfg.verticalToolbar = sw.isOn; break;
            case 49: _mobileCfg.batterySaverFpsMode = sw.isOn ? 1 : 0; break;
            case 50: _mobileCfg.autoHideOnGamepad = sw.isOn; break;
            case 51: _mobileCfg.leftHandedMobile = sw.isOn; break;
            case 52: _mobileCfg.respectMuteSwitch = sw.isOn; break;
            case 53: _mobileCfg.showToolHitLocation = sw.isOn; break;
            case 54: _mobileCfg.pureGamepadMode = sw.isOn; break;
            case 55: _mobileCfg.auroraBackdrop = sw.isOn; break;
        }
        [_mobileCfg saveToDocuments:_root.path];
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        if (sw.tag == 54) {
            _message = sw.isOn
                ? @"Đã bật Chế độ Tay cầm thuần! Hãy lưu game (nếu đang chơi) rồi khởi động lại để ngắt hẳn cảm ứng ảo."
                : @"Đã tắt Chế độ Tay cầm thuần! Khởi động lại game để khôi phục bộ điều khiển cảm ứng Mobile.";
            _messageIsError = NO;
            [self renderAll:NO];
#ifdef GARDEN_IN_GAME
            [self restartGameTapped];
#endif
            return;
        }
        if (sw.tag == 48) [self renderAll:NO];
        return;
    }
    switch (sw.tag) {
        case 10: _uiCfg.showKeyboardBtn = sw.isOn; break;
        case 11: _uiCfg.showMenuBtn = sw.isOn; break;
        case 12: _uiCfg.showHotkeyDrawerBtn = sw.isOn; break;
        case 13: _uiCfg.leftHanded = sw.isOn; break;
    }
    [_uiCfg saveToDocuments:_root.path];
    [self syncLiveLabels];
}

-(void)forceGcNowTapped {
    [SDVRamMonitor.shared triggerManualGCInDocs:_root.path];
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    _message = @"Đã gửi lệnh Dọn RAM & nén bộ nhớ (Compacting GC).";
    _messageIsError = NO;
    [self renderAll:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshRamCardNow];
    });
}

-(void)refreshRamCardNow {
    if (!_ramHeadlineLbl || !_ramDetailLbl) return;
    SDVRamSnapshot s = [SDVRamMonitor.shared sample];
    UIColor *col = (s.usagePct >= 90.0) ? kTintRed : ((s.usagePct >= 85.0) ? kTintOrange : kTintGreen);
    _ramHeadlineLbl.text = [NSString stringWithFormat:@"%@ / %@ (%.0f%%)", sdvFmtMemMB(s.usedBytes), sdvFmtMemMB(s.budgetBytes), s.usagePct];
    _ramHeadlineLbl.textColor = col;
    _ramDetailLbl.text = [NSString stringWithFormat:@"Dư trước Jetsam: %@ · Peak: %@ · Máy: %.1f GB · Nhiệt: %@",
        sdvFmtMemMB(s.availBytes), sdvFmtMemMB(s.peakBytes), (double)s.deviceBytes / (1024.0 * 1024.0 * 1024.0), sdvThermalLabel(s.thermal)];
    _ramBarFill.backgroundColor = col;
    CGFloat trackW = _ramBarTrack.bounds.size.width;
    if (trackW > 8) {
        CGFloat frac = MAX(0.02, MIN(1.0, s.usagePct / 100.0));
        _ramBarFillW.constant = trackW * frac;
    }
}

-(void)resetRamPeakTapped {
    [SDVRamMonitor.shared resetPeak];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self refreshRamCardNow];
}

-(void)resetRamHudPosTapped {
    [SDVRamMonitor.shared resetHudOffset];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    _message = @"Đã đưa thanh đo RAM & FPS về giữa mép trên.";
    _messageIsError = NO;
    [self renderAll:NO];
}

-(void)mouseModeChanged:(UISegmentedControl *)seg {
    _uiCfg.mouseMode = seg.selectedSegmentIndex;
    [_uiCfg saveToDocuments:_root.path];
}

-(void)resetUiConfig {
    [_uiCfg resetDefaults];
    [_uiCfg saveToDocuments:_root.path];
    _message = @"Đã khôi phục mặc định toàn bộ giao diện nút bấm.";
    _messageIsError = NO;
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    [self renderAll:NO];
}

// ============================================================
// TAB 3: CO-OP LAN / IP (iOS 14 - iOS 26+)
// ============================================================
-(void)renderCoopTab {
    NSArray<NSDictionary *> *ifaces = sdvLocalIPv4Interfaces();

    UIStackView *hdrBox = mkVStack(10);
    UIStackView *hdrTop = mkHStack(10);
    [hdrTop addArrangedSubview:mkSettingsIconBadge(@"wifi", kTintTeal, 32)];
    UIStackView *ht = mkVStack(1);
    [ht addArrangedSubview:mkLabel(@"Co-op LAN / IP trực tiếp", 15.5, UIFontWeightSemibold, kInkPrimary)];
    [ht addArrangedSubview:mkLabel(@"Đã tích hợp bản vá Lidgren.Network & quyền Mạng cục bộ.", 12.5, UIFontWeightRegular, kInkSecondary)];
    [hdrTop addArrangedSubview:ht];
    [hdrTop addArrangedSubview:[UIView new]];
    [hdrTop addArrangedSubview:mkBadgePill(@"UDP 24642", [kTintTeal colorWithAlphaComponent:0.14], kTintTeal, 11)];
    [hdrBox addArrangedSubview:hdrTop];

    UIStackView *btnRow = mkHStack(8);
    SDVAppleButton *probeBtn = mkIOSButton(@"Kích hoạt & kiểm tra quyền LAN", @"antenna.radiowaves.left.and.right", kTintBlue, UIColor.whiteColor, 13, UIEdgeInsetsMake(9, 12, 9, 12));
    [probeBtn addTarget:self action:@selector(runLanProbe) forControlEvents:UIControlEventTouchUpInside];
    SDVAppleButton *refBtn = mkIOSButton(@"Cập nhật IP", @"arrow.clockwise", kBgCardSubtle, kInkPrimary, 13, UIEdgeInsetsMake(9, 12, 9, 12));
    [refBtn addTarget:self action:@selector(refreshCoopTab) forControlEvents:UIControlEventTouchUpInside];
    [btnRow addArrangedSubview:probeBtn];
    [btnRow addArrangedSubview:refBtn];
    [hdrBox addArrangedSubview:btnRow];
    [_pane addArrangedSubview:mkGroupedCard(hdrBox, UIEdgeInsetsMake(13, 14, 13, 14))];

    [_pane addArrangedSubview:mkSectionTitle(@"Địa chỉ IP thiết bị (dùng khi làm Host)")];
    if (!ifaces.count) {
        [_pane addArrangedSubview:mkGroupedCard(mkLabel(@"Chưa thấy IP Wi-Fi / VPN. Hãy kết nối Wi-Fi hoặc bật Tailscale / ZeroTier rồi bấm Cập nhật IP.", 13, UIFontWeightRegular, kInkSecondary), UIEdgeInsetsMake(12, 14, 12, 14))];
    } else {
        NSMutableArray<UIView *> *ipRows = [NSMutableArray array];
        for (NSDictionary *info in ifaces) {
            UIStackView *row = mkHStack(10);
            UIStackView *left = mkVStack(1);
            UILabel *ipLbl = mkLabel(info[@"ip"], 16, UIFontWeightSemibold, kInkPrimary);
            ipLbl.font = iosMonoDigits(16, UIFontWeightSemibold);
            [left addArrangedSubview:ipLbl];
            [left addArrangedSubview:mkLabel([NSString stringWithFormat:@"%@  (%@)", info[@"kind"], info[@"iface"]], 12, UIFontWeightRegular, kInkSecondary)];
            [row addArrangedSubview:left];
            [row addArrangedSubview:[UIView new]];
            SDVAppleButton *cp = mkIOSButton(@"Chép IP", @"doc.on.doc", [kTintBlue colorWithAlphaComponent:0.13], kTintBlue, 12.5, UIEdgeInsetsMake(7, 11, 7, 11));
            cp.accessibilityValue = info[@"ip"];
            [cp addTarget:self action:@selector(copyCoopIP:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:cp];
            [ipRows addObject:row];
        }
        [_pane addArrangedSubview:mkGroupedRows(ipRows, 14)];
    }

    // Co-op Modpack Compatibility Fingerprint (#COOP-XXXXXX)
    if (_root.path.length) {
        NSDictionary *mpInfo = sdvComputeCoopModpackInfo(_root.path);
        NSString *mpCode = mpInfo[@"code"] ?: @"#COOP-VANILLA";
        NSInteger mpCnt = [mpInfo[@"count"] integerValue];
        [_pane addArrangedSubview:mkSectionTitle(@"Mã Đồng Bộ Bộ Mod Co-op (Chống lệch Mod)")];
        UIStackView *mpBox = mkVStack(8);
        UIStackView *mpTop = mkHStack(10);
        [mpTop addArrangedSubview:mkSettingsIconBadge(@"checkmark.seal.fill", kTintPurple, 30)];
        UIStackView *mpTxt = mkVStack(1.5);
        UILabel *codeLbl = mkLabel(mpCode, 16, UIFontWeightBold, kTintPurple);
        codeLbl.font = iosMonoDigits(16, UIFontWeightBold);
        [mpTxt addArrangedSubview:codeLbl];
        [mpTxt addArrangedSubview:mkLabel([NSString stringWithFormat:@"Đang tính trên %ld Mod gameplay đang bật (tự bỏ qua mod điều khiển riêng của máy).", (long)mpCnt], 12, UIFontWeightRegular, kInkSecondary)];
        [mpTop addArrangedSubview:mpTxt];
        [mpTop addArrangedSubview:[UIView new]];
        SDVAppleButton *cpMp = mkIOSButton(@"Chép Mã & Modlist", @"doc.on.doc.fill", [kTintPurple colorWithAlphaComponent:0.15], kTintPurple, 12.5, UIEdgeInsetsMake(8, 11, 8, 11));
        cpMp.accessibilityValue = mpInfo[@"copyText"];
        [cpMp setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [cpMp addTarget:self action:@selector(copyCoopModpackTapped:) forControlEvents:UIControlEventTouchUpInside];
        [mpTop addArrangedSubview:cpMp];
        [mpBox addArrangedSubview:mpTop];
        [mpBox addArrangedSubview:mkLabel(@"So sánh mã #COOP-... giữa máy Host và máy Tham gia trước khi vào phòng: trùng mã nghĩa là 100% khớp phiên bản Mod gameplay!", 12, UIFontWeightRegular, kInkSecondary)];
        [_pane addArrangedSubview:mkGroupedCard(mpBox, UIEdgeInsetsMake(12, 14, 12, 14))];
    }

    [_pane addArrangedSubview:mkSectionTitle(@"Hướng dẫn kết nối")];
    UILabel *guide = mkLabel(@"1. Cùng Wi-Fi (LAN): Chủ phòng vào Co-op → Tạo phòng (Host) và gửi IP Wi-Fi ở trên. Máy kia vào Co-op → Tham gia LAN → bấm KEY để gõ IP → OK.\n2. Online khác mạng: Cả 2 máy cài Tailscale hoặc ZeroTier, vào chung 1 mạng ảo rồi nhập IP mạng ảo (100.x.x.x).\nLưu ý: Các máy cần trùng bản 1.6.15, trùng mod gameplay và farm máy Host phải có sẵn nhà phụ (Cabin).", 13, UIFontWeightRegular, kInkSecondary);
    [_pane addArrangedSubview:mkGroupedCard(guide, UIEdgeInsetsMake(12, 14, 12, 14))];

    [_pane addArrangedSubview:mkSectionTitle(@"Tìm bạn chơi chung Co-op & Đồng bộ Mod")];
    [_pane addArrangedSubview:[self makeDiscordHeroCardWithSubtitle:@"Tìm bạn chơi Co-op qua Tailscale / ZeroTier / LAN, tải chung bộ Mod đồng bộ & bật mic kênh thoại trực tiếp trên Discord!"]];
}

-(void)refreshCoopTab {
    _message = @"Đã cập nhật danh sách IP mạng.";
    _messageIsError = NO;
    [self renderAll:NO];
}

-(void)copyCoopIP:(UIButton *)btn {
    NSString *ip = btn.accessibilityValue;
    if (!ip.length) return;
    UIPasteboard.generalPasteboard.string = ip;
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    _message = [NSString stringWithFormat:@"Đã sao chép IP %@ (cổng UDP 24642).", ip];
    _messageIsError = NO;
    [self renderAll:NO];
}

-(void)copyCoopModpackTapped:(UIButton *)btn {
    NSString *txt = btn.accessibilityValue;
    if (!txt.length) return;
    UIPasteboard.generalPasteboard.string = txt;
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    _message = @"Đã sao chép Mã đồng bộ #COOP kèm danh sách Mod đang bật vào bộ nhớ tạm!";
    _messageIsError = NO;
    [self renderAll:NO];
}

-(void)runLanProbe {
    NSString *res = sdvProbeLocalNetwork();
    _message = res;
    _messageIsError = [res containsString:@"chặn"] || [res containsString:@"Lỗi"];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    [self renderAll:NO];
}

// ============================================================
// TAB 4: HƯỚNG DẪN SỬ DỤNG (v1.1.0)
// ============================================================
-(UIView *)mkGuideStep:(NSString *)num title:(NSString *)title body:(NSString *)body color:(UIColor *)col {
    UIStackView *row = mkHStack(11);
    row.alignment = UIStackViewAlignmentTop;
    UILabel *badge = mkLabel(num, 13, UIFontWeightBold, UIColor.whiteColor);
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = col;
    badge.layer.cornerRadius = 12;
    badge.clipsToBounds = YES;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [badge.widthAnchor constraintEqualToConstant:24].active = YES;
    [badge.heightAnchor constraintEqualToConstant:24].active = YES;

    UIStackView *txt = mkVStack(2);
    [txt addArrangedSubview:mkLabel(title, 13.5, UIFontWeightSemibold, kInkPrimary)];
    [txt addArrangedSubview:mkLabel(body, 12.5, UIFontWeightRegular, kInkSecondary)];
    [row addArrangedSubview:badge];
    [row addArrangedSubview:txt];
    return row;
}

-(UIView *)mkCreditRow:(NSString *)role name:(NSString *)name detail:(NSString *)detail url:(NSString *)urlStr urlLabel:(NSString *)urlLabel {
    UIStackView *row = mkHStack(10);
    UIStackView *left = mkVStack(2);
    [left addArrangedSubview:mkLabel(role, 10.5, UIFontWeightSemibold, kTintBlue)];
    [left addArrangedSubview:mkLabel(name, 14, UIFontWeightSemibold, kInkPrimary)];
    if (detail.length) [left addArrangedSubview:mkLabel(detail, 12.5, UIFontWeightRegular, kInkSecondary)];
    [row addArrangedSubview:left];
    if (urlStr.length) {
        [row addArrangedSubview:[UIView new]];
        SDVAppleButton *btn = mkIOSButton(urlLabel ?: @"Mở", @"arrow.up.right", [kTintBlue colorWithAlphaComponent:0.12], kTintBlue, 12, UIEdgeInsetsMake(6, 10, 6, 10));
        btn.accessibilityValue = urlStr;
        [btn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [btn addTarget:self action:@selector(openExternalLink:) forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:btn];
    }
    return row;
}

-(void)renderGuideTab {
    NSString *appNm = sdvAppDisplayName();

    UIStackView *topRow = mkHStack(10);
    [topRow addArrangedSubview:mkSettingsIconBadge(@"book.fill", kTintOrange, 34)];
    UIStackView *topTxt = mkVStack(1);
    [topTxt addArrangedSubview:mkLabel([NSString stringWithFormat:@"%@ v%@ — Hướng dẫn toàn diện", appNm, sdvEffectiveAppVersion()], 15.5, UIFontWeightSemibold, kInkPrimary)];
    [topTxt addArrangedSubview:mkLabel(@"Đồ họa Native · SMAPI 4.5.2 · Tay cầm & Mobile Controls · Shader GLSL ES (iOS 14–27+)", 12, UIFontWeightRegular, kInkSecondary)];
    SDVAppleButton *jumpBtn = mkIOSButton(@"Xem Credit", @"heart.fill", [kTintPink colorWithAlphaComponent:0.13], kTintPink, 12.5, UIEdgeInsetsMake(7, 11, 7, 11));
    [jumpBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [jumpBtn addTarget:self action:@selector(switchToCreditTab) forControlEvents:UIControlEventTouchUpInside];
    [topRow addArrangedSubview:topTxt];
    [topRow addArrangedSubview:jumpBtn];
    [_pane addArrangedSubview:mkGroupedCard(topRow, UIEdgeInsetsMake(12, 14, 12, 14))];

    // Quick Online Bug Report Card (auto-zips sanitized ErrorLogs.zip + sends to Admin Discord via Cloudflare Worker)
    UIStackView *bugCard = mkHStack(10);
    [bugCard addArrangedSubview:mkSettingsIconBadge(@"ladybug.fill", kTintRed, 32)];
    UIStackView *bugTxt = mkVStack(1.5);
    [bugTxt addArrangedSubview:mkLabel(@"Gặp lỗi game / Mod / Shader?", 14, UIFontWeightSemibold, kInkPrimary)];
    [bugTxt addArrangedSubview:mkLabel(@"Chọn loại lỗi, mô tả ngắn gọn và gửi trực tiếp cho Admin kèm tệp nén ErrorLogs.zip.", 12, UIFontWeightRegular, kInkSecondary)];
    SDVAppleButton *bugOpenBtn = mkIOSButton(@"Báo lỗi", @"paperplane.fill", kTintRed, UIColor.whiteColor, 12.5, UIEdgeInsetsMake(8, 12, 8, 12));
    [bugOpenBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [bugOpenBtn addTarget:self action:@selector(openBugReportModal) forControlEvents:UIControlEventTouchUpInside];
    [bugCard addArrangedSubview:bugTxt];
    [bugCard addArrangedSubview:bugOpenBtn];
    [_pane addArrangedSubview:mkGroupedCard(bugCard, UIEdgeInsetsMake(11, 14, 11, 14))];

    [_pane addArrangedSubview:mkSectionTitle(@"1. Thiết lập Game & Cài đặt Mod (5 bước)")];
    [_pane addArrangedSubview:mkGroupedRows(@[
        [self mkGuideStep:@"1" title:@"Nạp dữ liệu Stardew Valley PC 1.6.15" body:@"Lần đầu mở app, chọn tệp nén (.ZIP / .RAR / .7Z) hoặc thư mục chứa dữ liệu game PC 1.6.15 (gồm thư mục Content và Stardew Valley.dll). Hệ thống tự kiểm tra và giải nén chuẩn." color:kTintBlue],
        [self mkGuideStep:@"2" title:@"Mở Mod Garden ngay trong lúc chơi" body:[NSString stringWithFormat:@"Chạm 3 ngón tay 2 lần (3-finger double tap) lên màn hình bất kỳ lúc nào để bật nhanh bảng quản lý %@.", appNm] color:kTintGreen],
        [self mkGuideStep:@"3" title:@"Cài Mod & Việt hóa đa định dạng" body:@"Tại tab Cài Mod, bấm Chọn tệp Mod để nạp 1 hoặc nhiều gói .ZIP, .RAR, .7Z, .TAR.GZ, .XNB cùng lúc (hoặc Chọn thư mục Mod). Tương thích cả mod C# và mod Shader (DynamicReflections, DynamicShader…)." color:kTintOrange],
        [self mkGuideStep:@"4" title:@"Quản lý Thư viện & Hoàn tác an toàn" body:@"Mod Garden tự kiểm tra mod phụ thuộc (Dependencies), cập nhật mod trùng tên mà không mất config.json và cho phép Bật/Tắt/Xóa hoặc Hoàn tác tại tab Thư viện." color:kTintPurple],
        [self mkGuideStep:@"5" title:@"Khởi động lại để SMAPI 4.5.2 nạp mod" body:@"Sau khi cài thêm hoặc bật/tắt mod, hãy vuốt tắt hẳn ứng dụng rồi mở lại để SMAPI nạp danh sách mod mới." color:kTintTeal]
    ], 48)];

    [_pane addArrangedSubview:mkSectionTitle(@"2. Điều khiển Mobile, Thanh Item, Phím PC & Quản lý Save")];
    [_pane addArrangedSubview:mkGroupedRows(@[
        [self mkGuideStep:@"A" title:@"4 Chế độ Mobile & Tiện ích cảm ứng chuyên sâu" body:@"Chuyển trực tiếp giữa Vô hình, 2 Nút, Chạm đi (A* tự qua cửa, giữ trực tiếp trên nước để gồng Cần câu 0ms, giữ trên đất để gồng Cuốc/Bình tưới nâng cấp, kéo lướt thu hoạch) và Kết hợp. Hỗ trợ Thanh Item dọc kiểu Mobile (1–3 cột, 4–12 ô/cột, cạnh Trái/Phải, kéo cỡ trong Edit Layout), kéo mồi/phao thả lên cần câu, tự hiện nút ROT/SPEC, ngắm Súng cao su, lia camera ở Robin & Bảo tàng và máy thùng Prairie King / Junimo Kart / Crane Game." color:kTintBlue],
        [self mkGuideStep:@"B" title:@"Thanh tiện ích (BAG · MAP · QST · SAVE · KEY · HIDE · EDIT)" body:@"Mở nhanh Túi đồ (BAG), Bản đồ (MAP), Nhiệm vụ (QST), Bàn phím ảo iOS (KEY), ẩn toàn bộ nút (HIDE — chạm đúp để hiện lại) và chế độ chỉnh vị trí nút (EDIT). Bấm dấu < để thu gọn thanh khi cần màn hình thoáng." color:kTintGreen],
        [self mkGuideStep:@"C" title:@"Save Menu 20 mốc & Nhập / Xuất File Save đa nền tảng" body:@"Bấm nút SAVE trong game để tạo tới 20 mốc thời gian bất kỳ lúc nào. Vào tab File Save ở thanh bên để Nhập Save từ PC (Windows/Mac/Linux), Android, iOS (tự chuẩn hóa hoa-thường, tạo SaveGameInfo, sao lưu bản cũ) hoặc Xuất .ZIP đa nền tảng (kèm QuickSave)." color:kTintOrange],
        [self mkGuideStep:@"D" title:@"Chế độ Tay cầm thuần, Rung CoreHaptics & Phím / Chuột ngoài" body:@"Hỗ trợ Tay cầm Bluetooth/USB-C chuẩn Console (rung CoreHaptics 2 mô-tơ, SnappyMenus, LB/RB chuyển tab & khung rương, kéo/thay/vứt đồ, con trỏ R-Stick cho UI Info Suite 2 & GMCM) kèm nút bật Chế độ Tay cầm thuần ngắt hẳn cảm ứng ảo. Ngoài ra thêm tối đa 16 phím PC tùy chọn, Bàn phím rời và Chuột rời." color:kTintPurple]
    ], 48)];

    [_pane addArrangedSubview:mkSectionTitle(@"3. Tối ưu RAM, Cảnh báo Lưu Game 85% / 90% & Lưu ý iOS 14–27+")];
    UILabel *tipsLbl = mkLabel(@"• Cảnh báo RAM tự động 2 mức: Khi RAM đạt 85% giới hạn iOS, hệ thống tự động gom rác bộ nhớ (Auto-GC), hiện thông báo cam và nhấp nháy nút SAVE! để nhắc bạn lưu game. Khi đạt 90%+, hệ thống bật cảnh báo đỏ khẩn cấp và chớp nhanh nút SAVE! để tránh văng game do tràn RAM.\n• Mẹo giảm RAM khi dùng mod Recolor / Expansion: Các mod Recolor nạp nhiều bảng ảnh bản đồ vào bộ nhớ của Content Patcher. Bạn có thể bấm Dọn RAM ngay trong tab Hiệu năng & Nút hoặc tắt bớt tuỳ chọn recolor lễ hội trong GMCM.\n• Tương thích iOS 14 – iOS 27+: Chạy thuần Mono Interpreter (0% JIT), không cần bật JIT. Khi cập nhật IPA mới, chỉ cần cài đè cùng Bundle ID để giữ nguyên toàn bộ save và mod.", 13, UIFontWeightRegular, kInkSecondary);
    [_pane addArrangedSubview:mkGroupedCard(tipsLbl, UIEdgeInsetsMake(12, 14, 12, 14))];
}

// ============================================================
// TAB 8: CONSOLE LOG REALTIME (SMAPI / ENGINE / BOOT)
// ============================================================
-(NSString *)consoleLogFilePath {
    NSString *docs = _root.path ?: [fm() URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
    if (!docs.length) return nil;
    NSString *errDir = join(docs, @"ErrorLogs");
    if (_consoleSource == 1) return join(errDir, @"engine-latest.log");
    if (_consoleSource == 2) return join(errDir, @"launcher-boot.log");
    return join(errDir, @"SMAPI-latest.txt");
}

-(NSString *)readTailOfFile:(NSString *)path maxBytes:(NSUInteger)maxBytes totalSize:(long long *)outTotal {
    if (outTotal) *outTotal = 0;
    if (!path.length) return @"";
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return @"";
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        close(fd);
        return @"";
    }
    long long fsz = (long long)st.st_size;
    if (outTotal) *outTotal = fsz;
    off_t startOff = (fsz > (long long)maxBytes) ? (off_t)(fsz - (long long)maxBytes) : 0;
    if (startOff > 0) lseek(fd, startOff, SEEK_SET);
    size_t toRead = (size_t)(fsz - (long long)startOff);
    NSMutableData *buf = [NSMutableData dataWithLength:toRead];
    ssize_t n = read(fd, buf.mutableBytes, toRead);
    close(fd);
    if (n <= 0) return @"";
    buf.length = (NSUInteger)n;
    NSString *txt = sdvDecodeUtf8Slice(buf, startOff > 0, NO);
    if (startOff > 0) {
        NSRange nl = [txt rangeOfString:@"\n"];
        if (nl.location != NSNotFound && nl.location + 1 < txt.length) {
            txt = [txt substringFromIndex:nl.location + 1];
        }
    }
    return txt;
}

-(void)refreshConsoleLogForce:(BOOL)force {
    if (!_consoleTextView) return;
    if (_consolePaused && !force) return;

    NSString *path = [self consoleLogFilePath];
    struct stat st;
    BOOL exists = (path.length && stat(path.fileSystemRepresentation, &st) == 0);
    if (!exists) {
        _consoleLastSize = -1;
        _consoleLastMtime = 0;
        _consoleRawCache = @"";
        _consoleMetaLbl.text = @"Chưa có tệp log — hãy đợi SMAPI khởi chạy hoặc vào game.";
        _consoleTextView.attributedText = [[NSAttributedString alloc] initWithString:@"(Chưa có dữ liệu log)"
            attributes:@{
                NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular],
                NSForegroundColorAttributeName: rgb(0x94A3B8)
            }];
        return;
    }

    if (!force && (long long)st.st_size == _consoleLastSize && st.st_mtime == _consoleLastMtime) {
        return;
    }
    _consoleLastSize = (long long)st.st_size;
    _consoleLastMtime = st.st_mtime;

    long long totalBytes = 0;
    NSString *raw = [self readTailOfFile:path maxBytes:64 * 1024 totalSize:&totalBytes];
    NSArray<NSString *> *lines = [raw componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];

    UIFont *monoFont = [UIFont fontWithName:@"Menlo-Regular" size:10.5]
        ?: [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    UIFont *monoBold = [UIFont fontWithName:@"Menlo-Bold" size:10.5]
        ?: [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightSemibold];

    NSMutableAttributedString *attr = [NSMutableAttributedString new];
    NSMutableString *plainOut = [NSMutableString new];
    NSInteger shown = 0, errCnt = 0, warnCnt = 0;

    for (NSString *line in lines) {
        if (!line.length) continue;
        BOOL isErr = ([line containsString:@" ERROR "] || [line containsString:@"[ERROR]"] || [line containsString:@"[ERR]"] ||
                      [line containsString:@" ALERT "] || [line containsString:@"Exception"] || [line containsString:@"FATAL"]);
        BOOL isWarn = !isErr && ([line containsString:@" WARN "] || [line containsString:@"[WARN]"] || [line containsString:@"WARNING"]);
        BOOL isTrace = !isErr && !isWarn && ([line containsString:@" TRACE "] || [line containsString:@" DEBUG "] || [line containsString:@"[DEBUG]"]);

        if (isErr) errCnt++;
        else if (isWarn) warnCnt++;

        if (_consoleFilter == 1 && !isErr && !isWarn) continue;
        if (_consoleFilter == 2 && isTrace) continue;

        UIColor *col = rgb(0xE2E8F0);
        UIFont *fnt = monoFont;
        if (isErr) { col = rgb(0xFF6B6B); fnt = monoBold; }
        else if (isWarn) { col = rgb(0xFFD166); fnt = monoBold; }
        else if (isTrace) { col = rgb(0x8899AC); }
        else if ([line containsString:@"Loaded "] || [line containsString:@"LIVE INTERCEPT"] || [line containsString:@"Successfully"]) {
            col = rgb(0x6EE7B7);
        }

        NSString *ln = [line stringByAppendingString:@"\n"];
        [plainOut appendString:ln];
        [attr appendAttributedString:[[NSAttributedString alloc] initWithString:ln attributes:@{
            NSFontAttributeName: fnt,
            NSForegroundColorAttributeName: col
        }]];
        shown++;
    }

    _consoleRawCache = plainOut;
    if (shown == 0) {
        _consoleTextView.attributedText = [[NSAttributedString alloc] initWithString:@"(Không có dòng log nào khớp bộ lọc hiện tại)"
            attributes:@{ NSFontAttributeName: monoFont, NSForegroundColorAttributeName: rgb(0x94A3B8) }];
    } else {
        _consoleTextView.attributedText = attr;
    }

    NSString *fname = path.lastPathComponent ?: @"log";
    _consoleMetaLbl.text = [NSString stringWithFormat:@"%@ · %.1f KB · %ld dòng · %ld lỗi · %ld cảnh báo%@",
        fname, (double)totalBytes / 1024.0, (long)shown, (long)errCnt, (long)warnCnt,
        _consolePaused ? @" · ĐÃ TẠM DỪNG" : @" · LIVE 1s"];

    if (_consoleAutoScroll && _consoleTextView.attributedText.length > 0) {
        NSRange endRange = NSMakeRange(_consoleTextView.attributedText.length - 1, 1);
        [_consoleTextView scrollRangeToVisible:endRange];
    }
}

-(void)consoleSourceChanged:(UISegmentedControl *)seg {
    _consoleSource = seg.selectedSegmentIndex;
    _consoleLastSize = -1;
    [self refreshConsoleLogForce:YES];
}

-(void)consoleFilterChanged:(UISegmentedControl *)seg {
    _consoleFilter = seg.selectedSegmentIndex;
    _consoleLastSize = -1;
    [self refreshConsoleLogForce:YES];
}

-(void)consoleTogglePause {
    _consolePaused = !_consolePaused;
    [_consoleLiveBtn setTitle:_consolePaused ? @"Tiếp tục" : @"LIVE" forState:UIControlStateNormal];
    _consoleLiveBtn.backgroundColor = _consolePaused ? kBgCardSubtle : [kTintGreen colorWithAlphaComponent:0.18];
    [_consoleLiveBtn setTitleColor:_consolePaused ? kInkPrimary : kTintGreen forState:UIControlStateNormal];
    if (!_consolePaused) {
        _consoleLastSize = -1;
        [self refreshConsoleLogForce:YES];
    } else {
        [self refreshConsoleLogForce:NO];
    }
}

-(void)consoleToggleAutoScroll {
    _consoleAutoScroll = !_consoleAutoScroll;
    _consoleScrollBtn.backgroundColor = _consoleAutoScroll ? [kTintBlue colorWithAlphaComponent:0.16] : kBgCardSubtle;
    [_consoleScrollBtn setTitleColor:_consoleAutoScroll ? kTintBlue : kInkSecondary forState:UIControlStateNormal];
    if (_consoleAutoScroll && _consoleTextView.attributedText.length > 0) {
        [_consoleTextView scrollRangeToVisible:NSMakeRange(_consoleTextView.attributedText.length - 1, 1)];
    }
}

-(void)consoleRefreshNow {
    _consoleLastSize = -1;
    [self refreshConsoleLogForce:YES];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
}

-(void)consoleCopyTapped {
    NSString *txt = _consoleRawCache.length ? _consoleRawCache : (_consoleTextView.text ?: @"");
    UIPasteboard.generalPasteboard.string = txt;
    [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    _message = [NSString stringWithFormat:@"Đã sao chép %lu ký tự Console Log vào bộ nhớ tạm.", (unsigned long)txt.length];
    _messageIsError = NO;
    [self renderAll:NO];
}

-(void)renderConsoleLogTab {
    UIStackView *ctrlBox = mkVStack(8);

    UISegmentedControl *srcSeg = [[UISegmentedControl alloc] initWithItems:@[@"SMAPI Log", @"Engine Log", @"Boot Log"]];
    srcSeg.selectedSegmentIndex = MAX(0, MIN(2, _consoleSource));
    [srcSeg addTarget:self action:@selector(consoleSourceChanged:) forControlEvents:UIControlEventValueChanged];
    [ctrlBox addArrangedSubview:srcSeg];

    UISegmentedControl *fltSeg = [[UISegmentedControl alloc] initWithItems:@[@"Tất cả", @"Lỗi & Cảnh báo", @"Bỏ TRACE"]];
    fltSeg.selectedSegmentIndex = MAX(0, MIN(2, _consoleFilter));
    [fltSeg addTarget:self action:@selector(consoleFilterChanged:) forControlEvents:UIControlEventValueChanged];
    [ctrlBox addArrangedSubview:fltSeg];

    UIStackView *btnRow = mkHStack(8);
    _consoleLiveBtn = mkIOSButton(_consolePaused ? @"Tiếp tục" : @"LIVE", @"dot.radiowaves.left.and.right",
        _consolePaused ? kBgCardSubtle : [kTintGreen colorWithAlphaComponent:0.18],
        _consolePaused ? kInkPrimary : kTintGreen, 12.0, UIEdgeInsetsMake(6, 10, 6, 10));
    [_consoleLiveBtn addTarget:self action:@selector(consoleTogglePause) forControlEvents:UIControlEventTouchUpInside];

    _consoleScrollBtn = mkIOSButton(@"Tự cuộn", @"arrow.down.to.line",
        _consoleAutoScroll ? [kTintBlue colorWithAlphaComponent:0.16] : kBgCardSubtle,
        _consoleAutoScroll ? kTintBlue : kInkSecondary, 12.0, UIEdgeInsetsMake(6, 10, 6, 10));
    [_consoleScrollBtn addTarget:self action:@selector(consoleToggleAutoScroll) forControlEvents:UIControlEventTouchUpInside];

    SDVAppleButton *refBtn = mkIOSButton(@"Làm mới", @"arrow.clockwise", kBgCardSubtle, kInkPrimary, 12.0, UIEdgeInsetsMake(6, 10, 6, 10));
    [refBtn addTarget:self action:@selector(consoleRefreshNow) forControlEvents:UIControlEventTouchUpInside];

    SDVAppleButton *cpBtn = mkIOSButton(@"Sao chép", @"doc.on.doc", kTintBlue, UIColor.whiteColor, 12.0, UIEdgeInsetsMake(6, 10, 6, 10));
    [cpBtn addTarget:self action:@selector(consoleCopyTapped) forControlEvents:UIControlEventTouchUpInside];

    [btnRow addArrangedSubview:_consoleLiveBtn];
    [btnRow addArrangedSubview:_consoleScrollBtn];
    [btnRow addArrangedSubview:refBtn];
    [btnRow addArrangedSubview:[UIView new]];
    [btnRow addArrangedSubview:cpBtn];
    [ctrlBox addArrangedSubview:btnRow];

    _consoleMetaLbl = mkLabel(@"Đang đọc log realtime…", 11.5, UIFontWeightMedium, kInkSecondary);
    [ctrlBox addArrangedSubview:_consoleMetaLbl];

    [_pane addArrangedSubview:mkGroupedCard(ctrlBox, UIEdgeInsetsMake(10, 12, 10, 12))];

    UITextView *tv = [UITextView new];
    tv.editable = NO;
    tv.selectable = YES;
    tv.backgroundColor = rgb(0x0B101A);
    tv.layer.cornerRadius = 12;
    tv.layer.cornerCurve = kCACornerCurveContinuous;
    tv.layer.borderWidth = 1.0;
    tv.layer.borderColor = rgb(0x233044).CGColor;
    tv.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    tv.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat availH = self.view.bounds.size.height > 160.0 ? self.view.bounds.size.height : 420.0;
    CGFloat tvH = MAX(220.0, MIN(480.0, availH * 0.56));
    [tv.heightAnchor constraintEqualToConstant:tvH].active = YES;
    _consoleTextView = tv;
    [_pane addArrangedSubview:tv];

    _consoleLastSize = -1;
    _consoleLastMtime = 0;
    [self refreshConsoleLogForce:YES];

    __weak typeof(self) weakSelf = self;
    _consoleTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        (void)t;
        [weakSelf refreshConsoleLogForce:NO];
    }];
}

// ============================================================
// TAB 5: CREDIT, CỘNG ĐỒNG STARDEW VALLEY VIỆT NAM & ỦNG HỘ NPH
// ============================================================
-(void)renderCreditTab {
    NSString *appNm = sdvAppDisplayName();
    NSString *effVer = sdvEffectiveAppVersion();
    NSDictionary *activeHp = sdvActiveHotPatchInfo();

    UIStackView *topRow = mkHStack(10);
    [topRow addArrangedSubview:mkSettingsIconBadge(@"heart.fill", kTintPink, 34)];
    UIStackView *topTxt = mkVStack(1);
    [topTxt addArrangedSubview:mkLabel([NSString stringWithFormat:@"%@ v%@ — Credit & Cộng đồng", appNm, effVer], 15.5, UIFontWeightSemibold, kInkPrimary)];
    [topTxt addArrangedSubview:mkLabel(@"Hỗ trợ Cập nhật nhanh trực tiếp trong ứng dụng (OTA Hot-Patch xác thực SHA-256 — không cần ký lại IPA)", 12, UIFontWeightRegular, kInkSecondary)];
    SDVAppleButton *chkUpdBtn = mkIOSButton(@"Kiểm tra cập nhật", @"arrow.triangle.2.circlepath", [kTintBlue colorWithAlphaComponent:0.13], kTintBlue, 12.5, UIEdgeInsetsMake(7, 11, 7, 11));
    [chkUpdBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [chkUpdBtn addTarget:self action:@selector(manualCheckUpdateTapped) forControlEvents:UIControlEventTouchUpInside];
    [topRow addArrangedSubview:topTxt];
    [topRow addArrangedSubview:chkUpdBtn];
    [_pane addArrangedSubview:mkGroupedCard(topRow, UIEdgeInsetsMake(12, 14, 12, 14))];

    if (activeHp) {
        NSString *hpSha = [activeHp[@"sha256"] isKindOfClass:NSString.class] ? activeHp[@"sha256"] : @"";
        NSString *shaShort = (hpSha.length >= 10) ? [hpSha substringToIndex:10] : hpSha;
        UIStackView *hpRow = mkHStack(10);
        [hpRow addArrangedSubview:mkSettingsIconBadge(@"bolt.horizontal.circle.fill", kTintTeal, 32)];
        UIStackView *hpTxt = mkVStack(1.5);
        [hpTxt addArrangedSubview:mkLabel([NSString stringWithFormat:@"Đang chạy Bản vá nóng v%@ (trên nền IPA gốc v" kSDVAppVersion @")", effVer], 13.5, UIFontWeightSemibold, kInkPrimary)];
        [hpTxt addArrangedSubview:mkLabel([NSString stringWithFormat:@"Đã xác thực SHA-256 (%@…) · %ld tệp · Tự động giữ nguyên qua các lần mở game", shaShort, (long)[activeHp[@"fileCount"] integerValue]], 11.5, UIFontWeightRegular, kInkSecondary)];
        SDVAppleButton *rbBtn = mkIOSButton(@"Về gốc IPA", @"arrow.uturn.backward", [kTintOrange colorWithAlphaComponent:0.14], kTintOrange, 12, UIEdgeInsetsMake(7, 10, 7, 10));
        [rbBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [rbBtn addTarget:self action:@selector(rollbackHotPatchTapped) forControlEvents:UIControlEventTouchUpInside];
        [hpRow addArrangedSubview:hpTxt];
        [hpRow addArrangedSubview:rbBtn];
        [_pane addArrangedSubview:mkGroupedCard(hpRow, UIEdgeInsetsMake(11, 14, 11, 14))];
    }

    [_pane addArrangedSubview:mkSectionTitle(@"Server Discord Chính Thức (Trực tuyến 24/7)")];
    [_pane addArrangedSubview:[self makeDiscordHeroCardWithSubtitle:nil]];

    [_pane addArrangedSubview:mkSectionTitle(@"Cộng đồng Stardew Valley Việt Nam (Facebook Groups & Pages)")];
    [_pane addArrangedSubview:mkGroupedRows(@[
        [self mkCreditRow:@"GROUP CỘNG ĐỒNG FACEBOOK" name:@"Stardew Valley Việt Nam (Group)" detail:@"Nhóm giao lưu, chia sẻ kinh nghiệm chơi, hỏi đáp & hướng dẫn mod Stardew Valley." url:@"https://www.facebook.com/groups/261129932243154/" urlLabel:@"Tham gia"],
        [self mkCreditRow:@"GROUP CỘNG ĐỒNG FACEBOOK" name:@"Cộng đồng Stardew Valley Việt Nam" detail:@"Sân chơi kết nối cộng đồng người chơi Stardew Valley trên PC & Mobile tại Việt Nam." url:@"https://www.facebook.com/groups/stardewvalleyvietnam/" urlLabel:@"Tham gia"],
        [self mkCreditRow:@"FANPAGE CHÍNH THỨC" name:@"Stardew Valley Vietnam Official" detail:@"Trang thông tin, tin tức cập nhật & hoạt động cộng đồng Stardew Valley Vietnam." url:@"https://www.facebook.com/StardewValleyVietnam.Official" urlLabel:@"Mở Page"],
        [self mkCreditRow:@"FANPAGE MOD & VIỆT HÓA" name:@"Stardew Valley Vietnam Mod" detail:@"Trang chia sẻ các bản Mod hay, bản dịch Việt hóa & hướng dẫn cài đặt Mod chi tiết." url:@"https://www.facebook.com/StardewValleyVietnam.Mod" urlLabel:@"Mở Page"]
    ], 14)];

    [_pane addArrangedSubview:mkSectionTitle(@"Đội ngũ phát triển & Nền tảng mã nguồn mở")];
    _creditCard = mkGroupedRows(@[
        [self mkCreditRow:@"GAME GỐC — NHÀ PHÁT TRIỂN" name:@"ConcernedApe (Eric Barone)" detail:@"Tác giả toàn bộ trò chơi Stardew Valley. Mọi bản quyền thuộc về ConcernedApe LLC." url:@"https://www.stardewvalley.net" urlLabel:@"Web"],
        [self mkCreditRow:@"NỀN TẢNG iOS PORT (MIT)" name:@"DeadAKJ — SDViosport" detail:@"Mã nguồn host .NET 8 iOS, MonoGame, tích hợp SMAPI và tay cầm cảm ứng SDViOSTouchControls." url:@"https://github.com/DeadAKJ/SDViosport" urlLabel:@"GitHub"],
        [self mkCreditRow:@"NỀN TẢNG MODDING" name:@"SMAPI — Pathoschild & Cộng đồng" detail:@"Stardew Modding API cùng các tác giả mod trên NexusMods và nhóm Việt hóa cộng đồng." url:@"https://smapi.io" urlLabel:@"smapi.io"],
        [self mkCreditRow:@"ĐÓNG GÓP MÃ NGUỒN — TAY CẦM, RUMBLE & MOBILE UX" name:@"Nguyễn Ngọc Nguyên (Mudkip267)" detail:@"Rung tay cầm CoreHaptics 2 mô-tơ chuẩn Console, tương thích UI Info Suite 2 & đồng bộ chân dung Seasonal Anime Portrait, nút SKIP cutscene chuẩn giao diện, tối ưu thanh cuộn Shop & rương Mobile và khôi phục âm thanh SoundBank." url:@"https://github.com/Mudkip267/Garden-Launcher-iOS" urlLabel:@"GitHub"],
        [self mkCreditRow:@"TRÌNH QUẢN LÝ & LAUNCHER iOS" name:@"Garden Launcher iOS (v" kSDVAppVersion @" Native Edition)" detail:@"Giao diện iOS chuẩn Apple, Cập nhật nhanh OTA Hot-Patch không cần ký lại IPA, mở trực tiếp thư mục StardewValley/Content trong Tệp, Chế độ Tay cầm thuần + fix kéo/thay/vứt đồ & chuyển khung, đi lại trong Event/Lễ hội, giải nén mọi định dạng (.ZIP/Deflate64/.RAR/.7Z), Shader GLSL ES và hỗ trợ iOS 14–27+." url:@"https://github.com/hanprm9-dot/Garden-Launcher-iOS" urlLabel:@"GitHub"]
    ], 14);
    [_pane addArrangedSubview:_creditCard];

    [_pane addArrangedSubview:mkSectionTitle(@"Ủng hộ nhà phát hành")];
    UIStackView *supBox = mkVStack(10);
    UIStackView *supHdr = mkHStack(10);
    [supHdr addArrangedSubview:mkSettingsIconBadge(@"heart.fill", kTintPink, 28)];
    [supHdr addArrangedSubview:mkLabel(@"Hãy mua game bản quyền để ủng hộ NPH!", 14.5, UIFontWeightSemibold, kInkPrimary)];
    [supBox addArrangedSubview:supHdr];
    [supBox addArrangedSubview:mkLabel(@"Stardew Valley là tác phẩm tâm huyết của nhà phát triển độc lập ConcernedApe. Nếu yêu thích trò chơi, hãy mua bản quyền chính thức trên App Store hoặc Steam để ủng hộ tác giả nhé!", 13, UIFontWeightRegular, kInkSecondary)];

    UIStackView *storeRow = mkHStack(8);
    storeRow.distribution = UIStackViewDistributionFillEqually;
    SDVAppleButton *appStoreBtn = mkIOSButton(@"App Store (iOS)", @"bag.fill", kTintBlue, UIColor.whiteColor, 13.5, UIEdgeInsetsMake(10, 10, 10, 10));
    appStoreBtn.accessibilityValue = @"https://apps.apple.com/app/id1406710800";
    [appStoreBtn addTarget:self action:@selector(openExternalLink:) forControlEvents:UIControlEventTouchUpInside];
    SDVAppleButton *steamBtn = mkIOSButton(@"Steam (PC)", @"desktopcomputer", kBgCardSubtle, kInkPrimary, 13.5, UIEdgeInsetsMake(10, 10, 10, 10));
    steamBtn.accessibilityValue = @"https://store.steampowered.com/app/413150/Stardew_Valley/";
    [steamBtn addTarget:self action:@selector(openExternalLink:) forControlEvents:UIControlEventTouchUpInside];
    [storeRow addArrangedSubview:appStoreBtn];
    [storeRow addArrangedSubview:steamBtn];
    [supBox addArrangedSubview:storeRow];
    [_pane addArrangedSubview:mkGroupedCard(supBox, UIEdgeInsetsMake(13, 14, 13, 14))];
}

-(void)switchToCreditTab {
    _tab = 7;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self renderAll:YES];
    [_scroll setContentOffset:CGPointZero animated:NO];
}

-(void)onLauncherUpdateNotification:(NSNotification *)n {
    (void)n;
    if (!self.isViewLoaded || !_pane || _veil) return;
    [self updateSidebarChrome];
    if (_tab != 6 && _tab != 8) {
        [self renderAll:NO];
    }
}

-(UIView *)buildLauncherUpdateCard:(NSDictionary *)info {
    NSString *ver = info[@"version"] ?: @"?";
    NSString *dateStr = info[@"date"] ?: @"";
    NSString *summary = info[@"summary"] ?: @"";
    NSString *updateId = info[@"updateId"] ?: @"";
    BOOL canHotPatch = [info[@"canHotPatch"] boolValue];
    long long hpSize = [info[@"hotpatchSize"] respondsToSelector:@selector(longLongValue)] ? [info[@"hotpatchSize"] longLongValue] : 0;
    NSInteger majorIOS = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    NSString *ipaLabel = (majorIOS >= 19) ? @"Tải IPA (iOS 26–27+)" : @"Tải IPA (iOS 14–18)";
    NSString *dlUrl = sdvRecommendedUpdateDownloadURL(info);
    NSString *relUrl = info[@"releaseUrl"] ?: @"https://github.com/hanprm9-dot/Garden-Launcher-iOS/releases/latest";

    UIStackView *box = mkVStack(8);

    UIStackView *hdr = mkHStack(10);
    [hdr addArrangedSubview:mkSettingsIconBadge(canHotPatch ? @"bolt.horizontal.circle.fill" : @"arrow.down.circle.fill", kTintGreen, 32)];
    UIStackView *hdrTxt = mkVStack(1.5);
    NSString *titlePrefix = canHotPatch ? @"Đã có Bản cập nhật nhanh" : @"Đã có bản cập nhật mới";
    NSString *titleText = dateStr.length
        ? [NSString stringWithFormat:@"%@ — Garden Launcher v%@ (%@)", titlePrefix, ver, dateStr]
        : [NSString stringWithFormat:@"%@ — Garden Launcher v%@", titlePrefix, ver];
    [hdrTxt addArrangedSubview:mkLabel(titleText, 14, UIFontWeightSemibold, kInkPrimary)];
    if (canHotPatch) {
        NSString *szTxt = (hpSize > 0) ? [NSString stringWithFormat:@"~%.0f KB · ", MAX(1.0, (double)hpSize / 1024.0)] : @"";
        [hdrTxt addArrangedSubview:mkLabel([NSString stringWithFormat:@"⚡ Cập nhật trực tiếp ngay trong app (%@Xác thực SHA-256) — KHÔNG CẦN tải hay ký lại tệp IPA!", szTxt], 11.5, UIFontWeightMedium, kTintGreen)];
    } else {
        [hdrTxt addArrangedSubview:mkLabel(@"Bản này nâng cấp lõi hệ thống/biểu tượng nên cần cài đè IPA (giữ nguyên 100% File Save & Mod đã cài)", 11.5, UIFontWeightRegular, kInkSecondary)];
    }
    [hdr addArrangedSubview:hdrTxt];
    [box addArrangedSubview:hdr];

    if (summary.length) {
        UIStackView *sumBox = mkVStack(4);
        [sumBox addArrangedSubview:mkLabel(@"Bản cập nhật này sửa những gì:", 12, UIFontWeightSemibold, kTintBlue)];
        UILabel *sumLbl = mkLabel(summary, 12.5, UIFontWeightRegular, kInkPrimary);
        sumLbl.numberOfLines = 0;
        [sumBox addArrangedSubview:sumLbl];
        UIView *sumWrap = mkGroupedCard(sumBox, UIEdgeInsetsMake(9, 11, 9, 11));
        sumWrap.backgroundColor = kBgCardSubtle;
        [box addArrangedSubview:sumWrap];
    }

    UIStackView *btnRow = mkHStack(8);
    if (canHotPatch) {
        SDVAppleButton *hpBtn = mkIOSButton(@"⚡ Cập nhật nhanh ngay", @"bolt.fill", kTintGreen, UIColor.whiteColor, 13, UIEdgeInsetsMake(9, 12, 9, 12));
        [hpBtn addTarget:self action:@selector(installHotPatchTapped:) forControlEvents:UIControlEventTouchUpInside];
        [btnRow addArrangedSubview:hpBtn];

        SDVAppleButton *ipaSubBtn = mkIOSButton(@"Tải IPA", @"arrow.down.to.line.compact", [kTintBlue colorWithAlphaComponent:0.13], kTintBlue, 12.5, UIEdgeInsetsMake(9, 10, 9, 10));
        ipaSubBtn.accessibilityValue = dlUrl;
        [ipaSubBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [ipaSubBtn addTarget:self action:@selector(openExternalLink:) forControlEvents:UIControlEventTouchUpInside];
        [btnRow addArrangedSubview:ipaSubBtn];
    } else {
        SDVAppleButton *dlBtn = mkIOSButton(ipaLabel, @"arrow.down.to.line.compact", kTintGreen, UIColor.whiteColor, 13, UIEdgeInsetsMake(9, 12, 9, 12));
        dlBtn.accessibilityValue = dlUrl;
        [dlBtn addTarget:self action:@selector(openExternalLink:) forControlEvents:UIControlEventTouchUpInside];
        [btnRow addArrangedSubview:dlBtn];
    }

    SDVAppleButton *ghBtn = mkIOSButton(@"GitHub", @"arrow.up.right.square", [kTintBlue colorWithAlphaComponent:0.13], kTintBlue, 12.5, UIEdgeInsetsMake(9, 11, 9, 11));
    ghBtn.accessibilityValue = relUrl;
    [ghBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [ghBtn addTarget:self action:@selector(openExternalLink:) forControlEvents:UIControlEventTouchUpInside];

    SDVAppleButton *skipBtn = mkIOSButton(@"Để sau", @"xmark", kBgCardSubtle, kInkSecondary, 12.5, UIEdgeInsetsMake(9, 10, 9, 10));
    skipBtn.accessibilityValue = updateId;
    [skipBtn setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [skipBtn addTarget:self action:@selector(dismissLauncherUpdateTapped:) forControlEvents:UIControlEventTouchUpInside];

    [btnRow addArrangedSubview:ghBtn];
    if (_tab != 7) [btnRow addArrangedSubview:skipBtn];
    [box addArrangedSubview:btnRow];

    UIView *card = mkGroupedCard(box, UIEdgeInsetsMake(12, 13, 12, 13));
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [kTintGreen colorWithAlphaComponent:0.45].CGColor;
    return card;
}

-(void)installHotPatchTapped:(UIButton *)sender {
    (void)sender;
    if (_veil) return;
    NSDictionary *info = sdvAvailableLauncherUpdate(YES);
    if (![info[@"canHotPatch"] boolValue]) return;
    NSString *docs = _root.path.length ? _root.path : [fm() URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
    NSString *ver = info[@"version"] ?: @"?";
    __block NSUInteger deployed = 0;
    [self work:@"Đang tải & xác thực gói cập nhật nhanh (SHA-256)…" action:^{
        deployed = sdvInstallHotPatchSync(info, docs);
        if (self->_root && [gameDataStatus(docs)[@"ready"] boolValue]) {
            [self scan:self->_root];
        }
    } done:^{
        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
        self->_message = [NSString stringWithFormat:@"⚡ Đã cập nhật nhanh lên v%@ (%lu tệp, không cần ký lại IPA)! Mở lại game để áp dụng ngay.", ver, (unsigned long)deployed];
        self->_messageIsError = NO;
        [self updateSidebarChrome];
        [self renderAll:YES];

        UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"⚡ Đã cập nhật lên v%@!", ver]
            message:[NSString stringWithFormat:@"Đã tải, xác thực SHA-256 và áp dụng %lu tệp cập nhật trực tiếp mà không cần tải hay ký lại tệp IPA.\n\nNếu đang chơi trong nông trại, hãy lưu game (SAVE / đi ngủ) trước rồi bấm Đóng & Mở lại để chạy bản mới.", (unsigned long)deployed]
            preferredStyle:UIAlertControllerStyleAlert];
#ifdef GARDEN_IN_GAME
        [a addAction:[UIAlertAction actionWithTitle:@"Đóng & Khởi động lại" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
            (void)act;
            @try {
                [self->_uiCfg saveToDocuments:docs];
                [self->_mobileCfg saveToDocuments:docs];
                [NSUserDefaults.standardUserDefaults synchronize];
                fflush(NULL);
            } @catch (NSException *ex) { }
            [UIView animateWithDuration:0.18 animations:^{
                self.view.window.alpha = 0.0;
            } completion:^(BOOL finished) {
                (void)finished;
                _exit(0);
            }];
        }]];
#endif
        [a addAction:[UIAlertAction actionWithTitle:@"Để lát nữa" style:UIAlertActionStyleCancel handler:nil]];
        [self presentSafely:a];
    }];
}

-(void)rollbackHotPatchTapped {
    if (_veil) return;
    NSString *docs = _root.path.length ? _root.path : [fm() URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Khôi phục về bản gốc IPA?"
        message:[NSString stringWithFormat:@"Sẽ gỡ bỏ Bản vá nóng hiện tại và khôi phục nguyên bản các tệp hệ thống của IPA gốc (v%@). Toàn bộ File Save & Mod của bạn vẫn giữ nguyên 100%%.", kSDVAppVersion]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Khôi phục gốc IPA" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *ac) {
        (void)ac;
        [self work:@"Đang khôi phục tệp gốc từ IPA…" action:^{
            sdvRollbackHotPatchSync(docs);
            if (self->_root && [gameDataStatus(docs)[@"ready"] boolValue]) {
                [self scan:self->_root];
            }
        } done:^{
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
            self->_message = [NSString stringWithFormat:@"Đã khôi phục về bản gốc IPA (v%@). Mở lại game để áp dụng.", kSDVAppVersion];
            self->_messageIsError = NO;
            [self updateSidebarChrome];
            [self renderAll:YES];
        }];
    }]];
    [self presentSafely:a];
}

-(void)dismissLauncherUpdateTapped:(UIButton *)sender {
    NSString *updId = sender.accessibilityValue;
    if (updId.length) {
        sdvDismissLauncherUpdate(updId);
        [self renderAll:YES];
    }
}

-(void)manualCheckUpdateTapped {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    _message = @"Đang kiểm tra bản cập nhật mới từ GitHub…";
    _messageIsError = NO;
    [self renderAll:NO];
    __weak typeof(self) weakSelf = self;
    sdvCheckLauncherUpdate(YES, ^(NSDictionary *updateInfo, NSString *statusMsg) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_message = statusMsg ?: @"Đã hoàn tất kiểm tra cập nhật.";
        strongSelf->_messageIsError = NO;
        [strongSelf renderAll:YES];
    });
}

-(void)openBugReportModal {
    if (_veil) return;
    _tab = 6;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self renderAll:YES];
}

-(UIView *)makeDiscordHeroCardWithSubtitle:(NSString *)subtitle {
    SDVDiscordHeroCard *card = [[SDVDiscordHeroCard alloc] initWithCustomSubtitle:subtitle];
    [card addTarget:self action:@selector(openDiscordServerTapped:) forControlEvents:UIControlEventTouchUpInside];
    return card;
}

-(void)openDiscordServerTapped:(UIControl *)sender {
    NSString *s = sdvDiscordInviteURL();
    if (!s.length) return;
    UIPasteboard.generalPasteboard.string = s;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    if ([sender isKindOfClass:SDVDiscordHeroCard.class]) {
        [(SDVDiscordHeroCard *)sender playTapCelebration];
    } else if ([sender isKindOfClass:SDVDiscordPillControl.class]) {
        [(SDVDiscordPillControl *)sender playTapCelebration];
    }
    NSURL *u = [NSURL URLWithString:s];
    if (!u) return;
    NSTimeInterval delay = UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.20;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:u options:@{} completionHandler:^(BOOL ok) {
            if (!ok) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf->_message = [NSString stringWithFormat:@"Đã sao chép link mời Discord vào bộ nhớ tạm: %@", s];
                strongSelf->_messageIsError = NO;
                [strongSelf renderAll:NO];
            }
        }];
    });
}

-(void)openExternalLink:(UIButton *)btn {
    NSString *s = btn.accessibilityValue;
    if (!s.length) return;
    NSURL *u = [NSURL URLWithString:s];
    if (u) {
        [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
    }
    UIPasteboard.generalPasteboard.string = s;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    _message = [NSString stringWithFormat:@"Đã mở và sao chép liên kết: %@", s];
    _messageIsError = NO;
    [self renderAll:NO];
}

#ifdef GARDEN_IN_GAME
-(void)enterLiveMenuBarMode {
    if (_veil) return;
    [_uiCfg saveToDocuments:_root.path];
    void (^cb)(void) = self.onRequestLiveMenuBarMode;
    void (^closeCb)(void) = self.onRequestClose;
    if (closeCb) {
        closeCb();
        if (cb) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), cb);
        return;
    }
    if (cb) cb();
}
#endif

// ---- Mod Library Actions ----
-(void)modSearchEditingEnded:(UITextField *)tf {
    _modSearchQuery = tf.text ?: @"";
    [self renderAll:NO];
}

-(void)modFilterSegChanged:(UISegmentedControl *)seg {
    _modFilterMode = seg.selectedSegmentIndex;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [self renderAll:NO];
}

-(void)openModConfigEditorTapped:(UIButton *)btn {
    NSInteger idx = btn.tag - 9000;
    if (idx < 0 || idx >= (NSInteger)_catalog.count) return;
    NSDictionary *m = _catalog[(NSUInteger)idx];
    NSString *cfgPath = m[@"configPath"];
    if (![cfgPath isKindOfClass:NSString.class] || !cfgPath.length || ![fm() fileExistsAtPath:cfgPath]) {
        [self alert:@"Chưa có config.json" text:@"Mod này chưa sinh tệp config.json. Hãy vào game chạy Mod 1 lần rồi mở lại trình chỉnh sửa."];
        return;
    }
    SDVModConfigEditorController *ed = [SDVModConfigEditorController new];
    ed.modName = m[@"name"] ?: m[@"cleanFolder"];
    ed.configPath = cfgPath;
    __weak typeof(self) weakSelf = self;
    ed.onSaved = ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        s->_message = [NSString stringWithFormat:@"Đã lưu config.json của %@! Mở lại game nếu Mod cần nạp lại cấu hình từ đầu.", ed.modName];
        s->_messageIsError = NO;
        [s renderAll:NO];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:ed];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentSafely:nav];
}

-(void)healCaseSensitivityTapped {
    if (_veil) return;
    __block NSDictionary *res = nil;
    [self work:@"Đang quét & sửa lệch chữ Hoa/Thường APFS…" action:^{
        [self access:YES block:^(NSURL *r) {
            res = sdvHealInstalledCaseSensitivity(r.path);
            syncContentPackLocaleFallbacks(r.path);
            [self scan:r];
        }];
    } done:^{
        NSUInteger fj = [res[@"fixedJson"] unsignedIntegerValue];
        NSUInteger fd = [res[@"fixedDll"] unsignedIntegerValue];
        NSUInteger fc = [res[@"fixedContent"] unsignedIntegerValue];
        NSUInteger tot = fj + fd + fc;
        self->_message = (tot > 0)
            ? [NSString stringWithFormat:@"Đã tự sửa %lu tệp/thư mục lệch chữ Hoa/Thường (%lu JSON/i18n, %lu EntryDll, %lu Content)!", (unsigned long)tot, (unsigned long)fj, (unsigned long)fd, (unsigned long)fc]
            : @"Toàn bộ thư mục Mods/ và Content/ đã chuẩn chữ Hoa/Thường APFS 100%.";
        self->_messageIsError = NO;
        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
        [self renderAll:NO];
    }];
}

-(void)openModProfilesSheet:(UIButton *)sender {
    (void)sender;
    if (_veil || !_root.path.length) return;
    NSArray<NSDictionary *> *profiles = sdvListSavedModProfiles(_root.path);
    UIAlertController *sh = [UIAlertController alertControllerWithTitle:@"Hồ sơ Bộ Mod & Chế độ An toàn"
        message:@"Chuyển nhanh giữa các bộ Mod (Vanilla, SVE, Co-op…) hoặc bật Safe Mode tắt tạm toàn bộ Mod ngoài để kiểm tra lỗi mà không xóa tệp."
        preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    void (^applyMode)(NSString *, NSString *) = ^(NSString *mode, NSString *doneText) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        __block NSUInteger changed = 0;
        [s work:@"Đang chuyển đổi Hồ sơ Mod…" action:^{
            [s access:YES block:^(NSURL *r) {
                changed = sdvApplyModProfileMode(r.path, mode);
                [s scan:r];
            }];
        } done:^{
            s->_message = [NSString stringWithFormat:@"%@ (đã đổi trạng thái %lu mod). Mở lại game để áp dụng.", doneText, (unsigned long)changed];
            s->_messageIsError = NO;
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
            [s renderAll:NO];
        }];
    };

    [sh addAction:[UIAlertAction actionWithTitle:@"💾 Lưu bộ Mod đang bật thành Hồ sơ mới…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        UIAlertController *inp = [UIAlertController alertControllerWithTitle:@"Lưu Hồ sơ Mod mới"
            message:@"Đặt tên cho bộ Mod đang bật hiện tại (VD: Nông trại SVE, Chơi Co-op, Gọn nhẹ 4GB…):"
            preferredStyle:UIAlertControllerStyleAlert];
        [inp addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"Tên hồ sơ Mod";
            tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
        }];
        [inp addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
        [inp addAction:[UIAlertAction actionWithTitle:@"Lưu Hồ sơ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *ac) {
            (void)ac;
            NSString *pName = [inp.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!pName.length) return;
            [s work:@"Đang lưu Hồ sơ Mod…" action:^{
                [s access:YES block:^(NSURL *r) {
                    sdvSaveModProfileNamed(r.path, pName);
                }];
            } done:^{
                s->_message = [NSString stringWithFormat:@"Đã lưu hồ sơ Mod \"%@\" thành công!", pName];
                s->_messageIsError = NO;
                [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
                [s renderAll:NO];
            }];
        }]];
        [s presentSafely:inp];
    }]];

    for (NSDictionary *pr in profiles) {
        NSString *pName = pr[@"name"] ?: @"Hồ sơ";
        NSInteger cnt = [pr[@"count"] integerValue];
        NSString *title = [NSString stringWithFormat:@"📂 Nạp hồ sơ \"%@\" (%ld mod)", pName, (long)cnt];
        [sh addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;
            applyMode([@"profile:" stringByAppendingString:pName], [NSString stringWithFormat:@"Đã nạp hồ sơ \"%@\"", pName]);
        }]];
    }

    [sh addAction:[UIAlertAction actionWithTitle:@"⚡ Bật tất cả Mod đã cài" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        applyMode(@"all_on", @"Đã bật tất cả Mod");
    }]];

    [sh addAction:[UIAlertAction actionWithTitle:@"🛡️ Chế độ An toàn (Safe Mode — tắt tạm Mod ngoài)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        (void)a;
        applyMode(@"safe_mode", @"Đã bật Chế độ An toàn (chỉ giữ điều khiển hệ thống)");
    }]];

    if (profiles.count > 0) {
        [sh addAction:[UIAlertAction actionWithTitle:@"🗑️ Xóa Hồ sơ đã lưu…" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            (void)a;
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            UIAlertController *delSh = [UIAlertController alertControllerWithTitle:@"Chọn Hồ sơ cần xóa" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSDictionary *pr in profiles) {
                NSString *pName = pr[@"name"] ?: @"";
                if (!pName.length) continue;
                [delSh addAction:[UIAlertAction actionWithTitle:[@"Xóa \"" stringByAppendingFormat:@"%@\"", pName] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *da) {
                    (void)da;
                    sdvDeleteModProfileNamed(s->_root.path, pName);
                    s->_message = [NSString stringWithFormat:@"Đã xóa hồ sơ \"%@\".", pName];
                    s->_messageIsError = NO;
                    [s renderAll:NO];
                }]];
            }
            [delSh addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
            [s presentSafely:delSh];
        }]];
    }

    [sh addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSafely:sh];
}

-(void)toggleModSwitch:(UISwitch *)sw {
    NSInteger idx = sw.tag;
    if (idx < 0 || idx >= (NSInteger)_catalog.count) return;
    NSDictionary *m = _catalog[idx];
    NSString *topFolder = m[@"topFolder"];
    NSString *modName = m[@"name"];
    BOOL targetOn = sw.isOn;
    [self work:targetOn ? @"Đang bật mod…" : @"Đang tắt mod…" action:^{
        [self access:YES block:^(NSURL *r) {
            toggleModEnabled(r.path, topFolder);
            [self scan:r];
        }];
    } done:^{
        self->_plan = nil;
        self->_message = [NSString stringWithFormat:@"Đã %@ %@. Mở lại game để áp dụng.", targetOn ? @"bật" : @"tắt", modName];
        self->_messageIsError = NO;
        [self renderAll:NO];
    }];
}

-(void)askDeleteMod:(UIButton *)btn {
    NSInteger idx = btn.tag;
    if (idx < 0 || idx >= (NSInteger)_catalog.count) return;
    NSDictionary *m = _catalog[idx];
    NSString *topFolder = m[@"topFolder"];
    NSString *modName = m[@"name"];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Xóa mod này?" message:[NSString stringWithFormat:@"Xóa sạch %@ khỏi Mods. Bạn có thể cài lại bất kỳ lúc nào.", modName] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Giữ lại" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Xóa" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *ac) {
        [self work:@"Đang xóa mod…" action:^{
            [self access:YES block:^(NSURL *r) {
                deleteModFolder(r.path, topFolder);
                [self scan:r];
            }];
        } done:^{
            self->_plan = nil;
            [self->_stagedFiles removeAllObjects];
            self->_message = [NSString stringWithFormat:@"Đã xóa sạch %@.", modName];
            self->_messageIsError = NO;
            [self renderAll:NO];
        }];
    }]];
    [self presentSafely:a];
}

// ---- Core Work / Storage / Multi-File Picker / Batch Install Engine ----
-(void)alert:(NSString *)title text:(NSString *)s {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:s preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSafely:a];
}

-(void)work:(NSString *)title action:(void(^)(void))fn done:(void(^)(void))done {
    if (_veil) return;
    _veil = [UIView new];
    _veil.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    [self.view addSubview:_veil];
    pinAll(_veil, self.view, 0);

    UIVisualEffectView *hud = mkGlassCard(UIBlurEffectStyleSystemThickMaterial, 18);
    hud.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *s = mkVStack(12);
    s.alignment = UIStackViewAlignmentCenter;
    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    [spin startAnimating];
    [s addArrangedSubview:spin];
    [s addArrangedSubview:mkLabel(title, 14, UIFontWeightSemibold, kInkPrimary)];
    [hud.contentView addSubview:s];
    pinInsets(s, hud.contentView, UIEdgeInsetsMake(20, 26, 20, 26));
    [_veil addSubview:hud];
    [NSLayoutConstraint activateConstraints:@[
        [hud.centerXAnchor constraintEqualToAnchor:_veil.centerXAnchor],
        [hud.centerYAnchor constraintEqualToAnchor:_veil.centerYAnchor]
    ]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *error = nil;
            @try { fn(); }
            @catch (NSException *e) { error = e.reason ?: @"Không hoàn thành được thao tác."; }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_veil removeFromSuperview];
                self->_veil = nil;
                [self renderAll:NO];
                if (error) [self alert:@"Mod Garden" text:error];
                else if (done) done();
            });
        }
    });
}

-(void)access:(BOOL)write block:(void(^)(NSURL *))fn {
#ifdef GARDEN_IN_GAME
    NSURL *local = [fm() URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (![gameDataStatus(local.path)[@"hasContent"] boolValue] || !dir(join(local.path, @"Mods"))) {
        fail(@"Game đang giải nén dữ liệu. Đợi đến màn hình chính rồi thử lại.");
    }
    fn(local);
    return;
#endif
    NSURL *u = _root;
    if (!u) fail(@"Chọn lại thư mục game.");
    BOOL scoped = [u startAccessingSecurityScopedResource];
    @try {
        NSFileCoordinator *c = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        NSError *e = nil;
        __block NSException *problem = nil;
        void (^accessor)(NSURL *) = ^(NSURL *r) {
            @try {
                NSDictionary *gst = gameDataStatus(r.path);
                if (!childScope(r.path) && (![gst[@"hasContent"] boolValue] || !dir(inside(r.path, @"Mods")) || ![gst[@"hasSdvDll"] boolValue])) {
                    fail(@"Hãy chọn thư mục chứa Mods, Content và Stardew Valley.dll.");
                }
                NSError *readError = nil;
                if (![fm() contentsOfDirectoryAtPath:r.path error:&readError]) fail(readError.localizedDescription ?: @"iOS chưa cấp quyền đọc thư mục.");
                fn(r);
            } @catch (NSException *ex) { problem = ex; }
        };
        if (write) [c coordinateWritingItemAtURL:u options:NSFileCoordinatorWritingForMerging error:&e byAccessor:accessor];
        else [c coordinateReadingItemAtURL:u options:0 error:&e byAccessor:accessor];
        if (problem) @throw problem;
        if (e) fail(e.localizedDescription);
    } @finally {
        if (scoped) [u stopAccessingSecurityScopedResource];
    }
}

-(void)scan:(NSURL *)r {
    NSDictionary *lib = installed(r.path);
    NSArray<NSDictionary *> *cat = modCatalog(r.path);
    NSArray<NSDictionary *> *issues = sdvDiagnoseMods(r.path);
    NSArray<NSDictionary *> *saves = sdvListSaves(r.path);
    NSArray<NSDictionary *> *qslots = sdvListQuickSavesAndSlots(r.path);
    NSString *h = latest(r);
    NSString *lastName = h ? journal(h)[@"name"] : nil;
    @synchronized(self) {
        _library = lib;
        _catalog = cat;
        _modIssues = issues;
        _savesList = saves;
        _quickSlotsList = qslots;
        _last = lastName;
    }
}

-(void)cleanOrphanModFolderTapped:(UIButton *)btn {
    if (btn.tag < 0 || (NSUInteger)btn.tag >= _modIssues.count) return;
    NSString *folder = _modIssues[(NSUInteger)btn.tag][@"orphanFolder"];
    if (!folder.length) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Dọn thư mục lỗi %@?", folder]
        message:[NSString stringWithFormat:@"Sẽ xóa thư mục Mods/%@ (thiếu manifest.json). Bản đã tắt .%@ nếu có sẽ được giữ nguyên.", folder, folder]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Xóa thư mục lỗi" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *ac) {
        [self work:@"Đang dọn thư mục lỗi…" action:^{
            [self access:YES block:^(NSURL *r) {
                NSString *target = inside(gamePath(r.path, @"Mods"), folder);
                if ([fm() fileExistsAtPath:target]) removeItem(target);
                [self scan:r];
            }];
        } done:^{
            self->_message = [NSString stringWithFormat:@"Đã dọn sạch thư mục lỗi Mods/%@.", folder];
            self->_messageIsError = NO;
            [self renderAll:YES];
        }];
    }]];
    [self presentSafely:a];
}

-(void)refresh {
    [self work:@"Đang đọc dữ liệu game…" action:^{
        [self access:NO block:^(NSURL *r) {
            [self scan:r];
#ifndef GARDEN_IN_GAME
            NSData *b = [self->_root bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
            if (b) [NSUserDefaults.standardUserDefaults setObject:b forKey:@"gameFolder"];
#endif
        }];
    } done:nil];
}

static NSArray<UTType *> *sdvAllArchivePickerTypes(void) {
    NSMutableArray<UTType *> *arr = [NSMutableArray arrayWithObjects:UTTypeArchive, UTTypeZIP, UTTypeData, UTTypeItem, UTTypeContent, UTTypePackage, nil];
    for (NSString *ext in @[@"rar", @"7z", @"tar", @"gz", @"tgz", @"bz2", @"tbz2", @"xz", @"txz", @"xnb"]) {
        UTType *t = [UTType typeWithFilenameExtension:ext];
        if (t && ![arr containsObject:t]) [arr addObject:t];
    }
    return arr;
}

-(void)folder { _choosingFolder = YES; _importingGameData = NO; _importingSave = NO; _appendPick = NO; [self picker:@[UTTypeFolder] copy:NO multi:NO]; }
-(void)package { _choosingFolder = NO; _importingGameData = NO; _importingSave = NO; _appendPick = NO; [self picker:sdvAllArchivePickerTypes() copy:YES multi:YES]; }
-(void)pickModFolder { _choosingFolder = NO; _importingGameData = NO; _importingSave = NO; _appendPick = NO; [self picker:@[UTTypeFolder] copy:NO multi:NO]; }
-(void)addMorePackages { _choosingFolder = NO; _importingGameData = NO; _importingSave = NO; _appendPick = YES; [self picker:sdvAllArchivePickerTypes() copy:YES multi:YES]; }
-(void)importGameDataTapped { _choosingFolder = NO; _importingGameData = YES; _importingSave = NO; _appendPick = NO; [self picker:sdvAllArchivePickerTypes() copy:YES multi:NO]; }
-(void)importGameDataFolderTapped { _choosingFolder = NO; _importingGameData = YES; _importingSave = NO; _appendPick = NO; [self picker:@[UTTypeFolder] copy:NO multi:NO]; }

-(void)recheckGameData {
    sdvMigrateDocumentsToHiddenLayout(_root.path);
    syncBundledLidgren(_root.path);
    syncBundledSmapi(_root.path);
    syncBundledMobileControls(_root.path);
    syncContentPackLocaleFallbacks(_root.path);
    NSDictionary *st = gameDataStatus(_root.path);
    if ([st[@"ready"] boolValue]) {
        [self refresh];
        _message = @"Đã tìm thấy đầy đủ dữ liệu game! Vuốt tắt hẳn app rồi mở lại để vào Stardew Valley.";
        _messageIsError = NO;
        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
    } else {
        NSMutableArray *miss = [NSMutableArray array];
        if (![st[@"hasSdvDll"] boolValue]) [miss addObject:@"Stardew Valley.dll"];
        if (![st[@"hasContent"] boolValue]) [miss addObject:@"thư mục Content/"];
        _message = [NSString stringWithFormat:@"Vẫn còn thiếu: %@. Hãy nhập gói .ZIP hoặc chép vào Tệp → Trên iPhone → %@.", [miss componentsJoinedByString:@", "], sdvAppDisplayName()];
        _messageIsError = YES;
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
        [self renderAll:NO];
    }
}

-(void)picker:(NSArray *)types copy:(BOOL)copy multi:(BOOL)multi {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:copy];
    p.allowsMultipleSelection = multi;
    p.modalPresentationStyle = UIModalPresentationFormSheet;
    p.delegate = self;
    [self presentSafely:p];
}

-(void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!urls.count) return;
    NSArray<NSURL *> *picked = [urls copy];
    if (picker.presentingViewController && !picker.isBeingDismissed) {
        [picker dismissViewControllerAnimated:YES completion:^{ [self handlePickedURLs:picked]; }];
    } else if (picker.isBeingDismissed && picker.transitionCoordinator && [picker.transitionCoordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) { [self handlePickedURLs:picked]; }]) {
        return;
    } else {
        [self handlePickedURLs:picked];
    }
}

-(void)handlePickedURLs:(NSArray<NSURL *> *)urls {
    _message = nil;
    if (_choosingFolder) {
        _root = urls.firstObject; _library = nil; _last = nil; [self refresh]; return;
    }
    if (_importingSave) {
        _importingSave = NO;
        _tab = 2;
        __block NSDictionary *res = nil;
        [self work:@"Đang giải nén & tự động cấu hình File Save đa nền tảng…" action:^{
            @try {
                res = sdvImportSavesFromURLs(urls, self->_root.path);
            } @finally {
                for (NSURL *u in urls) {
                    if ([u.path containsString:@"/tmp/"] || [u.path containsString:@"/Inbox/"]) {
                        [fm() removeItemAtURL:u error:nil];
                    }
                }
            }
            self->_savesList = sdvListSaves(self->_root.path);
        } done:^{
            self->_message = res[@"message"] ?: @"Đã nhập File Save thành công!";
            self->_messageIsError = NO;
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
            [self renderAll:YES];
        }];
        return;
    }
    if (_importingGameData) {
        _importingGameData = NO;
        NSURL *zipUrl = urls.firstObject;
        __block NSUInteger extracted = 0;
        [self work:@"Đang giải nén & cập nhật dữ liệu game / Content… (chờ 15–40 giây)" action:^{
            BOOL scoped = [zipUrl startAccessingSecurityScopedResource];
            @try {
                extracted = importGameDataZip(zipUrl, self->_root.path);
            } @finally {
                if (scoped) [zipUrl stopAccessingSecurityScopedResource];
                if ([zipUrl.path containsString:@"/tmp/"] || [zipUrl.path containsString:@"/Inbox/"]) {
                    [fm() removeItemAtURL:zipUrl error:nil];
                }
            }
            if ([gameDataStatus(self->_root.path)[@"ready"] boolValue]) {
                [self scan:self->_root];
            }
        } done:^{
            BOOL ready = [gameDataStatus(self->_root.path)[@"ready"] boolValue];
            self->_message = ready
                ? [NSString stringWithFormat:@"Đã nạp thành công %lu tệp dữ liệu game / Content! Khởi động lại game để áp dụng tài nguyên mới.", (unsigned long)extracted]
                : [NSString stringWithFormat:@"Đã giải nén %lu tệp. Kiểm tra mục còn thiếu bên dưới.", (unsigned long)extracted];
            self->_messageIsError = NO;
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
            [self renderAll:YES];
        }];
        return;
    }
    _tab = 0;
    BOOL append = _appendPick;
    if (!append) {
        _plan = nil;
        [_stagedFiles removeAllObjects];
        _nextPkgIdx = 0;
        _prefs = @[];
        _translations = [NSMutableDictionary dictionary];
    }
    NSString *msg = (urls.count > 1)
        ? [NSString stringWithFormat:@"Đang giải nén %lu gói mod…", (unsigned long)urls.count]
        : @"Đang giải nén & kiểm tra gói…";
    [self work:msg action:^{
        if (!append) removeItem(self->_stage);
        mkdirs(self->_stage);
        for (NSURL *u in urls) {
            NSString *sub = join(self->_stage, [NSString stringWithFormat:@"pkg_%03ld", (long)self->_nextPkgIdx++]);
            BOOL scoped = [u startAccessingSecurityScopedResource];
            @try {
                unpack(u, sub);
            } @finally {
                if (scoped) [u stopAccessingSecurityScopedResource];
            }
            [self->_stagedFiles addObject:u.lastPathComponent ?: @"mod.zip"];
        }
    } done:^{
        [self prepare];
    }];
}

-(void)prepare {
    __block NSDictionary *p = nil;
    [self work:@"Đang đối chiếu với game…" action:^{
        [self access:NO block:^(NSURL *r) {
            p = plan(r.path, self->_stage, self->_prefs, self->_translations, self->_stagedFiles);
        }];
    } done:^{
        if (p[@"translationOwner"] != NSNull.null) {
            NSString *owner = p[@"translationOwner"];
            NSDictionary *combined = p[@"combinedLibrary"] ?: self->_library;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Chọn mod nhận bản dịch" message:owner.length ? owner : @"Gói chỉ chứa i18n. Chọn đúng mod gốc cho bản dịch này." preferredStyle:UIAlertControllerStyleAlert];
            for (NSString *key in [combined.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                NSDictionary *m = combined[key][@"manifest"];
                [a addAction:[UIAlertAction actionWithTitle:field(m, @"Name").length ? field(m, @"Name") : key style:UIAlertActionStyleDefault handler:^(UIAlertAction *ac) {
                    self->_translations[owner] = key;
                    [self prepare];
                }]];
            }
            [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
            [self presentSafely:a];
        } else if ([p[@"choices"] count]) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Chọn thư mục XNB" message:@"Có nhiều tệp trùng tên. Với ảnh hội thoại, chọn Portraits. Với nhân vật đi lại, chọn Characters." preferredStyle:UIAlertControllerStyleAlert];
            for (NSString *c in p[@"choices"]) {
                [a addAction:[UIAlertAction actionWithTitle:c style:UIAlertActionStyleDefault handler:^(UIAlertAction *ac) {
                    self->_prefs = [@[c] arrayByAddingObjectsFromArray:self->_prefs];
                    [self prepare];
                }]];
            }
            [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
            [self presentSafely:a];
        } else {
            self->_plan = p;
            [self renderAll:YES];
        }
    }];
}

-(void)paths {
    UIViewController *vc = [UIViewController new];
    vc.title = @"Tệp sẽ cài";
    UITextView *text = [UITextView new];
    text.editable = NO;
    text.backgroundColor = kBgCanvas;
    text.textColor = kInkPrimary;
    text.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    text.textContainerInset = UIEdgeInsetsMake(12, 14, 12, 14);
    text.text = [[[_plan[@"map"] allKeys] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"\n"];
    vc.view = text;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Đóng" style:UIBarButtonItemStyleDone target:self action:@selector(closeSheet)];
    [self presentSafely:nav];
}

-(void)closeSheet { [self dismissViewControllerAnimated:YES completion:nil]; }

#ifdef GARDEN_IN_GAME
-(void)restartGameTapped {
    if (_veil) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Khởi động lại game?"
        message:@"Nếu đang chơi trong nông trại, hãy lưu game (SAVE hoặc đi ngủ) trước để không mất tiến độ.\n\nỨng dụng sẽ lưu cấu hình, đóng sạch tiến trình rồi bạn chỉ cần mở lại Garden Launcher để nạp mod / cài đặt mới."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Đóng & Khởi động lại" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        (void)act;
        @try {
            [_uiCfg saveToDocuments:_root.path];
            [_mobileCfg saveToDocuments:_root.path];
            [NSUserDefaults.standardUserDefaults synchronize];
            fflush(NULL);
        } @catch (NSException *ex) { }
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
        [UIView animateWithDuration:0.18 animations:^{
            self.view.window.alpha = 0.0;
        } completion:^(BOOL finished) {
            (void)finished;
            _exit(0);
        }];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

-(void)closeManager {
    if (_veil) return;
    [_uiCfg saveToDocuments:_root.path];
    if (self.onRequestClose) { self.onRequestClose(); return; }
    UIViewController *presenter = self.presentingViewController ?: self.navigationController.presentingViewController;
    if (presenter) [presenter dismissViewControllerAnimated:YES completion:nil];
    else [self dismissViewControllerAnimated:YES completion:nil];
}
#endif

-(void)cancelPlan {
    _plan = nil;
    [_stagedFiles removeAllObjects];
    _nextPkgIdx = 0;
    sdvRemoveItemQuiet(_stage);
    [self renderAll:NO];
}

-(void)apply {
    NSArray<NSString *> *mobileWarns = _plan[@"mobileWarnings"];
    if (mobileWarns.count) {
        NSString *detail = [mobileWarns componentsJoinedByString:@"\n• "];
        NSString *msg = [NSString stringWithFormat:@"Mod này có dấu hiệu dành riêng cho Stardew Valley Mobile/Android nên có thể gặp lỗi hiển thị hoặc không tương thích trên bản PC 1.6.15 của Garden Launcher.\n\n• %@\n\nKhuyên bạn tải bản PC 1.6 nếu có. Bạn vẫn muốn tiếp tục cài đặt?", detail];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"⚠️ Cảnh báo Mod bản Mobile" message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Vẫn cài đặt" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *ac) {
            [self performApply];
        }]];
        [self presentSafely:a];
        return;
    }
    [self performApply];
}

-(void)performApply {
    NSString *batchLabel = (_stagedFiles.count == 1)
        ? _stagedFiles.firstObject
        : [NSString stringWithFormat:@"%lu gói (%@…)", (unsigned long)_stagedFiles.count, _stagedFiles.firstObject ?: @"Mods"];
    __block NSUInteger written = 0;
    [self work:@"Đang sao lưu và cài các gói mod…" action:^{
        [self access:YES block:^(NSURL *r) {
            NSDictionary *p = plan(r.path, self->_stage, self->_prefs, self->_translations, self->_stagedFiles);
            written = installBatch(r, self->_stage, p[@"map"], p[@"obsoleteDisabled"], batchLabel);
            syncContentPackLocaleFallbacks(r.path);
            self->_plan = nil;
            [self->_stagedFiles removeAllObjects];
            self->_nextPkgIdx = 0;
            sdvRemoveItemQuiet(self->_stage);
            [self scan:r];
        }];
    } done:^{
        self->_message = (written > 0)
            ? [NSString stringWithFormat:@"Đã cài xong %@ (%lu tệp)! Mở lại %@ để nạp mod.", batchLabel, (unsigned long)written, sdvAppDisplayName()]
            : [NSString stringWithFormat:@"%@ đã giống hệt bản hiện có trong game.", batchLabel];
        self->_messageIsError = NO;
        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
        [self renderAll:YES];
    }];
}

-(void)askUndo {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Hoàn tác lần cài gần nhất?" message:_last preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Giữ nguyên" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Hoàn tác" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *ac) { [self runUndo]; }]];
    [self presentSafely:a];
}

-(void)runUndo {
    __block NSString *doneName = nil;
    [self work:@"Đang khôi phục bản sao lưu…" action:^{
        [self access:YES block:^(NSURL *r) {
            NSString *h = latest(r);
            if (h) {
                doneName = journal(h)[@"name"];
                restore(r, h);
            }
            [self scan:r];
        }];
    } done:^{
        self->_message = [NSString stringWithFormat:@"Đã hoàn tác %@.", doneName ?: @"gói mod"];
        self->_messageIsError = NO;
        [self renderAll:NO];
    }];
}
@end

#ifndef GARDEN_IN_GAME
@interface App : UIResponder <UIApplicationDelegate>
@property(strong) UIWindow *window;
@end
@implementation App
-(BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    UIWindowScene *ws = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]) { ws = (UIWindowScene *)s; break; }
    }
    self.window = ws ? [[UIWindow alloc] initWithWindowScene:ws] : [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 812, 375)];
    self.window.rootViewController = [Home new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); } }
#endif
