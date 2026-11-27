#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// ============================================================================
// NATIVE APPLE iOS DESIGN SYSTEM (Settings / Files / Control Center Aesthetic)
// 100% UIKit Dynamic System Colors · SF Pro · SF Symbols · Continuous Squircles
// Compatible with iOS 14.0 through iOS 26+ (Light & Dark Mode adaptive)
// ============================================================================

static inline UIColor *rgb(uint32_t hex) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:1.0];
}

static inline UIColor *rgba(uint32_t hex, CGFloat a) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:a];
}

// Dynamic Apple System Color Tokens
#define kBgCanvas          UIColor.systemGroupedBackgroundColor
#define kBgSidebar         UIColor.secondarySystemGroupedBackgroundColor
#define kBgCard            UIColor.secondarySystemGroupedBackgroundColor
#define kBgCardSubtle      UIColor.tertiarySystemFillColor
#define kBgCardDim         UIColor.tertiarySystemGroupedBackgroundColor
#define kSepColor          UIColor.separatorColor
#define kInkPrimary        UIColor.labelColor
#define kInkSecondary      UIColor.secondaryLabelColor
#define kInkTertiary       UIColor.tertiaryLabelColor

#define kTintBlue          UIColor.systemBlueColor
#define kTintGreen         UIColor.systemGreenColor
#define kTintOrange        UIColor.systemOrangeColor
#define kTintRed           UIColor.systemRedColor
#define kTintIndigo        UIColor.systemIndigoColor
#define kTintPurple        UIColor.systemPurpleColor
#define kTintTeal          UIColor.systemTealColor
#define kTintPink          UIColor.systemPinkColor

static inline UIFont *iosFont(CGFloat pt, UIFontWeight w) {
    return [UIFont systemFontOfSize:pt weight:w];
}

static inline UIFont *iosMonoDigits(CGFloat pt, UIFontWeight w) {
    return [UIFont monospacedDigitSystemFontOfSize:pt weight:w];
}

static inline UIImage *sfIcon(NSString *name, CGFloat pt, UIImageSymbolWeight w) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:pt weight:w];
    UIImage *img = [UIImage systemImageNamed:name withConfiguration:cfg];
    return img ? [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : nil;
}

static UIStackView *mkVStack(CGFloat spacing) {
    UIStackView *s = [UIStackView new];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = spacing;
    s.alignment = UIStackViewAlignmentFill;
    return s;
}

static UIStackView *mkHStack(CGFloat spacing) {
    UIStackView *s = [UIStackView new];
    s.axis = UILayoutConstraintAxisHorizontal;
    s.spacing = spacing;
    s.alignment = UIStackViewAlignmentCenter;
    return s;
}

static void pinAll(UIView *child, UIView *parent, CGFloat inset) {
    child.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:inset],
        [child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-inset],
        [child.topAnchor constraintEqualToAnchor:parent.topAnchor constant:inset],
        [child.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-inset]
    ]];
}

static void pinInsets(UIView *child, UIView *parent, UIEdgeInsets e) {
    child.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:e.left],
        [child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-e.right],
        [child.topAnchor constraintEqualToAnchor:parent.topAnchor constant:e.top],
        [child.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-e.bottom]
    ]];
}

static UILabel *mkLabel(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = iosFont(size, weight);
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

static UILabel *mkSectionHeader(NSString *title) {
    UILabel *l = [UILabel new];
    l.text = [title uppercaseString];
    l.font = iosFont(11.5, UIFontWeightSemibold);
    l.textColor = kInkSecondary;
    l.numberOfLines = 1;
    UIView *wrap = nil;
    (void)wrap;
    return l;
}

static UIView *mkSectionTitle(NSString *title) {
    UIView *box = [UIView new];
    UILabel *l = mkSectionHeader(title);
    [box addSubview:l];
    pinInsets(l, box, UIEdgeInsetsMake(6, 12, 0, 12));
    return box;
}

static UIView *mkSectionFooter(NSString *text) {
    UIView *box = [UIView new];
    UILabel *l = mkLabel(text, 12, UIFontWeightRegular, kInkSecondary);
    [box addSubview:l];
    pinInsets(l, box, UIEdgeInsetsMake(0, 12, 4, 12));
    return box;
}

static UIView *mkHairline(void) {
    UIView *v = [UIView new];
    v.backgroundColor = kSepColor;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [v.heightAnchor constraintEqualToConstant:0.5].active = YES;
    return v;
}

static UIView *mkInsetHairline(CGFloat leftInset) {
    UIView *wrap = [UIView new];
    UIView *line = [UIView new];
    line.backgroundColor = kSepColor;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [wrap addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [line.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:leftInset],
        [line.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor],
        [line.topAnchor constraintEqualToAnchor:wrap.topAnchor],
        [line.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor],
        [line.heightAnchor constraintEqualToConstant:0.5]
    ]];
    return wrap;
}

// Apple Settings 28x28 rounded-square colored SF Symbol badge
static UIView *mkSettingsIconBadge(NSString *symbolName, UIColor *bgColor, CGFloat boxSize) {
    UIView *box = [UIView new];
    box.backgroundColor = bgColor;
    box.layer.cornerRadius = round(boxSize * 0.24);
    box.layer.cornerCurve = kCACornerCurveContinuous;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    [box.widthAnchor constraintEqualToConstant:boxSize].active = YES;
    [box.heightAnchor constraintEqualToConstant:boxSize].active = YES;
    [box setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [box setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIImageView *iv = [[UIImageView alloc] initWithImage:sfIcon(symbolName, boxSize * 0.54, UIImageSymbolWeightSemibold)];
    iv.tintColor = UIColor.whiteColor;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:iv];
    [NSLayoutConstraint activateConstraints:@[
        [iv.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:box.centerYAnchor]
    ]];
    return box;
}

// Native Apple Inset Grouped Card Container (Aurora-frosted adaptive surface + luminous hairline)
static UIColor *sdvDynamicAuroraCardBg(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        BOOL dark = (tc.userInterfaceStyle == UIUserInterfaceStyleDark);
        return dark
            ? [UIColor colorWithRed:0.105 green:0.118 blue:0.188 alpha:0.78]
            : [UIColor colorWithRed:0.992 green:0.994 blue:1.000 alpha:0.84];
    }];
}

static UIColor *sdvDynamicAuroraCardBorder(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        BOOL dark = (tc.userInterfaceStyle == UIUserInterfaceStyleDark);
        return dark
            ? [UIColor colorWithRed:0.68 green:0.74 blue:1.00 alpha:0.17]
            : [UIColor colorWithRed:0.38 green:0.42 blue:0.88 alpha:0.16];
    }];
}

static UIView *mkGroupedCard(UIView *inner, UIEdgeInsets pad) {
    UIView *card = [UIView new];
    card.backgroundColor = sdvDynamicAuroraCardBg();
    card.layer.cornerRadius = 13.5;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.65;
    card.layer.borderColor = sdvDynamicAuroraCardBorder().CGColor;
    card.clipsToBounds = YES;
    [card addSubview:inner];
    pinInsets(inner, card, pad);
    return card;
}

// Native Apple Inset Grouped List (joins multiple row views with 0.5pt hairline separators!)
static UIView *mkGroupedRows(NSArray<UIView *> *rows, CGFloat sepLeftInset) {
    UIStackView *st = mkVStack(0);
    for (NSUInteger i = 0; i < rows.count; i++) {
        UIView *rWrap = [UIView new];
        [rWrap addSubview:rows[i]];
        pinInsets(rows[i], rWrap, UIEdgeInsetsMake(10, 14, 10, 14));
        [st addArrangedSubview:rWrap];
        if (i + 1 < rows.count) {
            [st addArrangedSubview:mkInsetHairline(sepLeftInset)];
        }
    }
    return mkGroupedCard(st, UIEdgeInsetsZero);
}

// Native Apple Tinted Pill Tag
static UILabel *mkBadgePill(NSString *text, UIColor *bg, UIColor *fg, CGFloat size) {
    UILabel *l = [UILabel new];
    l.text = [NSString stringWithFormat:@"  %@  ", text];
    l.font = iosFont(size, UIFontWeightSemibold);
    l.textColor = fg;
    l.backgroundColor = bg;
    l.layer.cornerRadius = 7.0;
    l.layer.cornerCurve = kCACornerCurveContinuous;
    l.clipsToBounds = YES;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [l setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [l setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [l.heightAnchor constraintGreaterThanOrEqualToConstant:size + 9.0].active = YES;
    return l;
}

// Native Apple Interactive Button with smooth tactile spring-opacity press feedback (iOS 14–26+)
@interface SDVAppleButton : UIButton
@property(nonatomic, strong) UIColor *normalBg;
@property(nonatomic, assign) CGFloat cornerRad;
@end

@implementation SDVAppleButton
-(instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
    }
    return self;
}
-(void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.alpha = highlighted ? 0.65 : 1.0;
        self.transform = highlighted ? CGAffineTransformMakeScale(0.985, 0.985) : CGAffineTransformIdentity;
    } completion:nil];
}
@end

static SDVAppleButton *mkIOSButton(NSString *title, NSString *sfSymbol, UIColor *bg, UIColor *fg, CGFloat fontSize, UIEdgeInsets pad) {
    SDVAppleButton *b = [SDVAppleButton buttonWithType:UIButtonTypeCustom];
    b.normalBg = bg;
    b.backgroundColor = bg;
    b.layer.cornerRadius = 11.0;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.tintColor = fg;
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.titleLabel.font = iosFont(fontSize, UIFontWeightSemibold);
    b.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    b.contentEdgeInsets = pad;
    if (title.length) [b setTitle:title forState:UIControlStateNormal];
    if (sfSymbol.length) {
        UIImage *img = sfIcon(sfSymbol, fontSize, UIImageSymbolWeightSemibold);
        if (img) {
            [b setImage:img forState:UIControlStateNormal];
            if (title.length) {
                b.imageEdgeInsets = UIEdgeInsetsMake(0, -3, 0, 3);
                b.titleEdgeInsets = UIEdgeInsetsMake(0, 3, 0, -3);
            }
        }
    }
#pragma clang diagnostic pop
    return b;
}

// Native Apple Frosted Glass Container (adapts seamlessly to iOS 14–18 Blur & iOS 26 Liquid Glass!)
static UIVisualEffectView *mkGlassCard(UIBlurEffectStyle style, CGFloat radius) {
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:style]];
    blur.layer.cornerRadius = radius;
    blur.layer.cornerCurve = kCACornerCurveContinuous;
    blur.clipsToBounds = YES;
    blur.layer.borderWidth = 0.5;
    blur.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
    return blur;
}

static NSString *const kSDVAuroraPrefChangedNotification = @"SDVAuroraPrefChangedNotification";
static BOOL gSdvAuroraEnabled = YES;

static inline void sdvSetAuroraBackdropEnabled(BOOL enabled) {
    if (gSdvAuroraEnabled == enabled) return;
    gSdvAuroraEnabled = enabled;
    [NSNotificationCenter.defaultCenter postNotificationName:kSDVAuroraPrefChangedNotification object:nil];
}

static inline BOOL sdvShouldPauseAmbientEffects(void) {
    return !gSdvAuroraEnabled || UIAccessibilityIsReduceMotionEnabled() || NSProcessInfo.processInfo.lowPowerModeEnabled;
}

// ============================================================================
// FULL-MENU LIVING AURORA AMBIENT BACKDROP (GPU Radial Ribbons · Light & Dark)
// ============================================================================
@interface SDVAuroraCanvasView : UIView
@end

@implementation SDVAuroraCanvasView {
    CAGradientLayer *_baseGrad;
    CAGradientLayer *_orbEmerald;
    CAGradientLayer *_orbBlurple;
    CAGradientLayer *_orbAmethyst;
    CAGradientLayer *_orbCyan;
    CAGradientLayer *_veilWave;
}

-(instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;

        _baseGrad = [CAGradientLayer layer];
        _baseGrad.startPoint = CGPointMake(0.0, 0.0);
        _baseGrad.endPoint = CGPointMake(1.0, 1.0);
        _baseGrad.locations = @[@(0.0), @(0.38), @(0.72), @(1.0)];
        [self.layer addSublayer:_baseGrad];

        _orbEmerald = [CAGradientLayer layer];
        _orbEmerald.type = kCAGradientLayerRadial;
        _orbEmerald.startPoint = CGPointMake(0.5, 0.5);
        _orbEmerald.endPoint = CGPointMake(1.0, 1.0);
        [self.layer addSublayer:_orbEmerald];

        _orbBlurple = [CAGradientLayer layer];
        _orbBlurple.type = kCAGradientLayerRadial;
        _orbBlurple.startPoint = CGPointMake(0.5, 0.5);
        _orbBlurple.endPoint = CGPointMake(1.0, 1.0);
        [self.layer addSublayer:_orbBlurple];

        _orbAmethyst = [CAGradientLayer layer];
        _orbAmethyst.type = kCAGradientLayerRadial;
        _orbAmethyst.startPoint = CGPointMake(0.5, 0.5);
        _orbAmethyst.endPoint = CGPointMake(1.0, 1.0);
        [self.layer addSublayer:_orbAmethyst];

        _orbCyan = [CAGradientLayer layer];
        _orbCyan.type = kCAGradientLayerRadial;
        _orbCyan.startPoint = CGPointMake(0.5, 0.5);
        _orbCyan.endPoint = CGPointMake(1.0, 1.0);
        [self.layer addSublayer:_orbCyan];

        _veilWave = [CAGradientLayer layer];
        _veilWave.startPoint = CGPointMake(0.0, 0.25);
        _veilWave.endPoint = CGPointMake(1.0, 0.75);
        _veilWave.locations = @[@(0.0), @(0.32), @(0.64), @(1.0)];
        [self.layer addSublayer:_veilWave];

        [self applyPaletteForCurrentTrait];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onMotionOrPowerChanged:) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onMotionOrPowerChanged:) name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(onMotionOrPowerChanged:) name:kSDVAuroraPrefChangedNotification object:nil];
    }
    return self;
}

-(void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

-(void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) {
        [self applyPaletteForCurrentTrait];
        [self updateAuroraAnimations];
    }
}

-(void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (!previousTraitCollection || previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
        [self applyPaletteForCurrentTrait];
    }
}

-(void)onMotionOrPowerChanged:(NSNotification *)n {
    (void)n;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateAuroraAnimations];
    });
}

-(void)applyPaletteForCurrentTrait {
    BOOL dark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (dark) {
        _baseGrad.colors = @[
            (id)rgb(0x090D1A).CGColor,
            (id)rgb(0x10172B).CGColor,
            (id)rgb(0x15122B).CGColor,
            (id)rgb(0x0B1624).CGColor
        ];
        _orbEmerald.colors = @[
            (id)[rgb(0x10B981) colorWithAlphaComponent:0.30].CGColor,
            (id)[rgb(0x10B981) colorWithAlphaComponent:0.10].CGColor,
            (id)[rgb(0x10B981) colorWithAlphaComponent:0.0].CGColor
        ];
        _orbBlurple.colors = @[
            (id)[rgb(0x5865F2) colorWithAlphaComponent:0.36].CGColor,
            (id)[rgb(0x4F46E5) colorWithAlphaComponent:0.13].CGColor,
            (id)[rgb(0x4F46E5) colorWithAlphaComponent:0.0].CGColor
        ];
        _orbAmethyst.colors = @[
            (id)[rgb(0xA855F7) colorWithAlphaComponent:0.28].CGColor,
            (id)[rgb(0xEC4899) colorWithAlphaComponent:0.09].CGColor,
            (id)[rgb(0xEC4899) colorWithAlphaComponent:0.0].CGColor
        ];
        _orbCyan.colors = @[
            (id)[rgb(0x06B6D4) colorWithAlphaComponent:0.28].CGColor,
            (id)[rgb(0x38BDF8) colorWithAlphaComponent:0.09].CGColor,
            (id)[rgb(0x38BDF8) colorWithAlphaComponent:0.0].CGColor
        ];
        _veilWave.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
            (id)[rgb(0x38BDF8) colorWithAlphaComponent:0.09].CGColor,
            (id)[rgb(0x8B5CF6) colorWithAlphaComponent:0.10].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
        ];
    } else {
        _baseGrad.colors = @[
            (id)rgb(0xEAF2FF).CGColor,
            (id)rgb(0xF1ECFF).CGColor,
            (id)rgb(0xE8FBF4).CGColor,
            (id)rgb(0xEEF4FF).CGColor
        ];
        _orbEmerald.colors = @[
            (id)[rgb(0x34D399) colorWithAlphaComponent:0.28].CGColor,
            (id)[rgb(0x34D399) colorWithAlphaComponent:0.10].CGColor,
            (id)[rgb(0x34D399) colorWithAlphaComponent:0.0].CGColor
        ];
        _orbBlurple.colors = @[
            (id)[rgb(0x6366F1) colorWithAlphaComponent:0.27].CGColor,
            (id)[rgb(0x6366F1) colorWithAlphaComponent:0.10].CGColor,
            (id)[rgb(0x6366F1) colorWithAlphaComponent:0.0].CGColor
        ];
        _orbAmethyst.colors = @[
            (id)[rgb(0xC084FC) colorWithAlphaComponent:0.26].CGColor,
            (id)[rgb(0xF472B6) colorWithAlphaComponent:0.08].CGColor,
            (id)[rgb(0xF472B6) colorWithAlphaComponent:0.0].CGColor
        ];
        _orbCyan.colors = @[
            (id)[rgb(0x38BDF8) colorWithAlphaComponent:0.27].CGColor,
            (id)[rgb(0x2DD4BF) colorWithAlphaComponent:0.09].CGColor,
            (id)[rgb(0x2DD4BF) colorWithAlphaComponent:0.0].CGColor
        ];
        _veilWave.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
            (id)[rgb(0x60A5FA) colorWithAlphaComponent:0.11].CGColor,
            (id)[rgb(0xA78BFA) colorWithAlphaComponent:0.11].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
        ];
    }
    [CATransaction commit];
}

-(void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = MAX(320.0, self.bounds.size.width);
    CGFloat h = MAX(240.0, self.bounds.size.height);
    CGFloat bigR = MAX(w, h) * 0.72;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _baseGrad.frame = self.bounds;
    _orbEmerald.frame  = CGRectMake(-bigR * 0.34, -bigR * 0.36, bigR, bigR);
    _orbBlurple.frame  = CGRectMake(w - bigR * 0.62, -bigR * 0.32, bigR * 1.04, bigR * 1.04);
    _orbAmethyst.frame = CGRectMake(w * 0.38, h - bigR * 0.60, bigR * 0.96, bigR * 0.96);
    _orbCyan.frame     = CGRectMake(-bigR * 0.18, h - bigR * 0.54, bigR * 0.90, bigR * 0.90);
    _veilWave.frame    = CGRectInset(self.bounds, -w * 0.20, -h * 0.15);
    [CATransaction commit];
}

-(void)addDriftToLayer:(CALayer *)layer key:(NSString *)key dx:(CGFloat)dx dy:(CGFloat)dy scale:(CGFloat)sc dur:(CFTimeInterval)dur {
    if ([layer animationForKey:key]) return;
    CABasicAnimation *ax = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    ax.fromValue = @(-dx);
    ax.toValue = @(dx);
    CABasicAnimation *ay = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    ay.fromValue = @(-dy);
    ay.toValue = @(dy);
    CABasicAnimation *as = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    as.fromValue = @(1.0);
    as.toValue = @(sc);
    CAAnimationGroup *g = [CAAnimationGroup animation];
    g.animations = @[ax, ay, as];
    g.duration = dur;
    g.autoreverses = YES;
    g.repeatCount = HUGE_VALF;
    g.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    g.removedOnCompletion = NO;
    [layer addAnimation:g forKey:key];
}

-(void)updateAuroraAnimations {
    if (sdvShouldPauseAmbientEffects() || !self.window) {
        [_orbEmerald removeAllAnimations];
        [_orbBlurple removeAllAnimations];
        [_orbAmethyst removeAllAnimations];
        [_orbCyan removeAllAnimations];
        [_veilWave removeAllAnimations];
        return;
    }
    [self addDriftToLayer:_orbEmerald  key:@"sdvAur1" dx:38.0  dy:24.0  scale:1.12 dur:7.6];
    [self addDriftToLayer:_orbBlurple  key:@"sdvAur2" dx:-44.0 dy:28.0  scale:1.15 dur:8.8];
    [self addDriftToLayer:_orbAmethyst key:@"sdvAur3" dx:-32.0 dy:-26.0 scale:1.14 dur:9.6];
    [self addDriftToLayer:_orbCyan     key:@"sdvAur4" dx:36.0  dy:-22.0 scale:1.10 dur:8.2];

    if (![_veilWave animationForKey:@"sdvAurVeil"]) {
        CABasicAnimation *sp = [CABasicAnimation animationWithKeyPath:@"startPoint"];
        sp.fromValue = [NSValue valueWithCGPoint:CGPointMake(0.0, 0.15)];
        sp.toValue = [NSValue valueWithCGPoint:CGPointMake(0.20, 0.85)];
        CABasicAnimation *ep = [CABasicAnimation animationWithKeyPath:@"endPoint"];
        ep.fromValue = [NSValue valueWithCGPoint:CGPointMake(1.0, 0.85)];
        ep.toValue = [NSValue valueWithCGPoint:CGPointMake(0.80, 0.15)];
        CAAnimationGroup *vg = [CAAnimationGroup animation];
        vg.animations = @[sp, ep];
        vg.duration = 10.4;
        vg.autoreverses = YES;
        vg.repeatCount = HUGE_VALF;
        vg.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        vg.removedOnCompletion = NO;
        [_veilWave addAnimation:vg forKey:@"sdvAurVeil"];
    }
}
@end
