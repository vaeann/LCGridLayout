// LCGridLayout: standalone host-only UI overlay for LiveContainer 3.8.0.
// Development source. A successful build is NOT a substitute for device validation.
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>

static NSString *const LGColumns = @"LCGridLayout.columns";
static NSString *const LGNames = @"LCGridLayout.showNames";
static NSString *const LGNative = @"LCGridLayout.nativeList";
static NSString *const LGCompactTop = @"LCGridLayout.compactTop";
static NSString *const LGOrder = @"LCGridLayout.order";
static CFTimeInterval LGStartTime;

static id LGGet(id object, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    return [object respondsToSelector:sel] ? ((id (*)(id, SEL))objc_msgSend)(object, sel) : nil;
}
static NSString *LGLogPath(void) {
    NSURL *library = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    return [library URLByAppendingPathComponent:@"Logs/LCGridLayout.log"].path;
}
static void LGLog(NSString *message) {
    NSLog(@"[LCGridLayout] %@", message);
    NSURL *url = [NSURL fileURLWithPath:LGLogPath()];
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [[NSString stringWithFormat:@"%@ pid=%d %@\n", NSDate.date, getpid(), message] dataUsingEncoding:NSUTF8StringEncoding];
    // Bounded, plugin-owned log only; no application names or container paths.
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    if (!attrs || [attrs fileSize] > 131072) { [data writeToURL:url atomically:YES]; return; }
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:url.path];
    @try { [file seekToEndOfFile]; [file writeData:data]; [file closeFile]; } @catch (__unused NSException *e) {}
}
static NSString *LGDetectedVersion;

// Numeric semantic-version comparison; "3.8.11" > "3.8.2" > "3.8.0".
static BOOL LGVersionAtLeast(NSString *version, NSString *minimum) {
    NSArray<NSString *> *have = [version componentsSeparatedByString:@"."];
    NSArray<NSString *> *need = [minimum componentsSeparatedByString:@"."];
    NSUInteger count = MAX(have.count, need.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger a = i < have.count ? have[i].integerValue : 0;
        NSInteger b = i < need.count ? need[i].integerValue : 0;
        if (a != b) return a > b;
    }
    return YES;
}

static BOOL LGHost(void) {
    // Runtime host state is essential: guest processes may also contain LC frameworks.
    Class defaults = NSUserDefaults.class;
    SEL liveProcess = NSSelectorFromString(@"isLiveProcess");
    if (![defaults respondsToSelector:liveProcess] ||
        ![defaults respondsToSelector:NSSelectorFromString(@"lcGuestAppId")]) return NO;
    if (((BOOL (*)(id, SEL))objc_msgSend)(defaults, liveProcess)) return NO;
    if (LGGet(defaults, @"lcGuestAppId") != nil) return NO;
    NSBundle *bundle = LGGet(defaults, @"lcMainBundle");
    NSString *version = bundle.infoDictionary[@"CFBundleShortVersionString"];
    // Accept 3.8.0 and every later release/nightly (3.8.2, 3.8.11, 3.9.x, ...).
    // The APIs this plugin relies on (LCUtils, generateIconForBundleURL:,
    // livecontainer-launch, LCLoadTweaksToSelf) are unchanged across 3.8.x.
    if (![version isKindOfClass:NSString.class] || !LGVersionAtLeast(version, @"3.8.0")) return NO;
    LGDetectedVersion = version;
    return NSClassFromString(@"LCUtils") != Nil;
}
static NSDictionary *LGPlist(NSURL *url) {
    return [NSDictionary dictionaryWithContentsOfURL:url];
}
typedef NS_ENUM(NSInteger, LGEntryState) {
    LGEntryStateOK,
    LGEntryStateHidden,
    LGEntryStateDamaged
};
// Single source of truth for "may this app be shown / launched from the grid".
// Damaged or ambiguous metadata fails closed.
static LGEntryState LGStateFor(NSDictionary *info, NSDictionary *meta, BOOL metaOnDisk) {
    if (!info || (metaOnDisk && !meta)) return LGEntryStateDamaged;
    if ([info[@"isHidden"] boolValue] || [meta[@"isHidden"] boolValue]) return LGEntryStateHidden;
    return LGEntryStateOK;
}
static LGEntryState LGEntryStateFor(NSURL *url) {
    NSURL *metaURL = [url URLByAppendingPathComponent:@"LCAppInfo.plist"];
    return LGStateFor(LGPlist([url URLByAppendingPathComponent:@"Info.plist"]),
                      LGPlist(metaURL),
                      [NSFileManager.defaultManager fileExistsAtPath:metaURL.path]);
}

// Version is derived from the dylib's own file name (e.g. LCGridLayout_v4.dylib),
// so the log always names the build that is actually loaded.
static NSString *LGLoadedName(void) {
    Dl_info info;
    if (dladdr((const void *)&LGLoadedName, &info) && info.dli_fname) {
        return [NSString stringWithUTF8String:info.dli_fname].lastPathComponent;
    }
    return @"LCGridLayout";
}

static NSString *LGBackgroundPath(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [support URLByAppendingPathComponent:@"LCGridLayout" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"background.jpg"].path;
}

static NSUserDefaults *LGAppGroupDefaults(void) {
    NSString *groupID = LGGet(NSClassFromString(@"LCSharedUtils"), @"appGroupID");
    if (![groupID isKindOfClass:NSString.class] || groupID.length == 0) return nil;
    return [[NSUserDefaults alloc] initWithSuiteName:groupID];
}

@interface LGEntry : NSObject
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *folder;
@property(nonatomic, copy) NSString *bundleId;
// LCDataUUID from LCAppInfo.plist — the data container LiveContainer would use
// for this app by default. The native launch route needs it, otherwise it falls
// back to whatever container another app had selected.
@property(nonatomic, copy) NSString *container;
// Launch preferences read straight from LCAppInfo.plist. LiveContainer decides
// between "multitask window" and "classic (restart into guest)" per app, and the
// grid has to make the same call or a user who enabled multitasking gets the old
// behaviour for every icon.
@property(nonatomic) NSInteger multitaskSpecified;   // 0 default / 1 no / 2 yes
@property(nonatomic) BOOL classicMode;
@property(nonatomic) BOOL jitNeeded;
@property(nonatomic) BOOL locked;
@property(nonatomic) BOOL shared;
@property(nonatomic) BOOL hidden;
@end
@implementation LGEntry
@end

static NSUInteger LGCountHidden, LGCountAmbiguous, LGCountDamaged;

static NSArray<LGEntry *> *LGReadApps(BOOL includeHidden) {
    NSFileManager *fm = NSFileManager.defaultManager;
    LGCountHidden = LGCountAmbiguous = LGCountDamaged = 0;
    NSURL *docs = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    NSMutableArray<NSURL *> *roots = [NSMutableArray arrayWithObject:[docs URLByAppendingPathComponent:@"Applications"]];
    NSURL *group = LGGet(NSClassFromString(@"LCSharedUtils"), @"appGroupPath");
    if (!group) group = [fm containerURLForSecurityApplicationGroupIdentifier:@"group.com.SideStore.SideStore"];
    if (group) [roots addObject:[group URLByAppendingPathComponent:@"LiveContainer/Applications"]];
    NSMutableArray<LGEntry *> *result = [NSMutableArray new];
    NSMutableSet *seenPaths = [NSMutableSet new];
    NSMutableSet *ambiguousFolders = [NSMutableSet new];
    NSMutableSet *seenFolders = [NSMutableSet new];
    for (NSUInteger rootIndex = 0; rootIndex < roots.count; rootIndex++) {
        NSURL *root = roots[rootIndex];
        BOOL shared = rootIndex > 0;
        for (NSURL *url in [fm contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
            if (![url.pathExtension isEqual:@"app"] || [seenPaths containsObject:url.URLByResolvingSymlinksInPath.path]) continue;
            [seenPaths addObject:url.URLByResolvingSymlinksInPath.path];
            if ([seenFolders containsObject:url.lastPathComponent]) [ambiguousFolders addObject:url.lastPathComponent];
            [seenFolders addObject:url.lastPathComponent];
            NSURL *metaURL = [url URLByAppendingPathComponent:@"LCAppInfo.plist"];
            NSDictionary *info = LGPlist([url URLByAppendingPathComponent:@"Info.plist"]);
            NSDictionary *meta = LGPlist(metaURL);
            // Fail closed for damaged or ambiguous metadata, but count the reason so
            // the user can tell why an app visible in the native list is missing here.
            LGEntryState state = LGStateFor(info, meta, [fm fileExistsAtPath:metaURL.path]);
            if (state == LGEntryStateDamaged) { LGCountDamaged++; continue; }
            if (state == LGEntryStateHidden) {
                LGCountHidden++;
                if (!includeHidden) continue;
            }
            LGEntry *entry = [LGEntry new];
            entry.url = url;
            entry.folder = url.lastPathComponent;
            entry.bundleId = info[@"CFBundleIdentifier"];
            entry.shared = shared;
            entry.hidden = (state == LGEntryStateHidden);
            entry.locked = [meta[@"isLocked"] boolValue];
            entry.multitaskSpecified = [meta[@"MultitaskSpecified"] integerValue];
            entry.classicMode = [meta[@"classicMode"] boolValue];
            entry.jitNeeded = [meta[@"isJITNeeded"] boolValue];
            id container = meta[@"LCDataUUID"];
            if ([container isKindOfClass:NSString.class] && [container length] > 0) {
                entry.container = container;
            } else {
                // Older records have no LCDataUUID. LC itself accepts an explicit
                // container, so infer it when there is exactly one.
                id list = meta[@"LCContainers"];
                NSMutableArray<NSString *> *names = [NSMutableArray new];
                if ([list isKindOfClass:NSArray.class]) {
                    for (id item in list) {
                        id name = [item isKindOfClass:NSDictionary.class] ? ((NSDictionary *)item)[@"folderName"] : nil;
                        if ([name isKindOfClass:NSString.class] && [name length] > 0) [names addObject:name];
                    }
                }
                if (names.count == 1) entry.container = names.firstObject;
            }
            entry.name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: entry.folder.stringByDeletingPathExtension;
            if (![entry.name isKindOfClass:NSString.class]) entry.name = entry.folder;
            [result addObject:entry];
        }
    }
    // The native launch route identifies a folder, not its storage root. Do not
    // offer ambiguous folders that could open a different local/shared app.
    NSUInteger beforeFilter = result.count;
    [result filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(LGEntry *entry, NSDictionary *bindings) {
        return ![ambiguousFolders containsObject:entry.folder];
    }]];
    LGCountAmbiguous = beforeFilter - result.count;
    NSArray<NSString *> *savedOrder = [NSUserDefaults.standardUserDefaults arrayForKey:LGOrder];
    NSMutableDictionary<NSString *, NSNumber *> *rank = [NSMutableDictionary new];
    for (NSString *folder in savedOrder) {
        if ([folder isKindOfClass:NSString.class]) rank[folder] = @(rank.count);
    }
    [result sortUsingComparator:^NSComparisonResult(LGEntry *a, LGEntry *b) {
        if (a.hidden != b.hidden) return a.hidden ? NSOrderedDescending : NSOrderedAscending;
        NSNumber *rankA = rank[a.folder], *rankB = rank[b.folder];
        if (rankA && rankB) return rankA.integerValue < rankB.integerValue ? NSOrderedAscending : NSOrderedDescending;
        if (rankA) return NSOrderedAscending;
        if (rankB) return NSOrderedDescending;
        return [a.name localizedStandardCompare:b.name];
    }];
    return result;
}

// Cheap first-paint icon straight from the bundle (no IconServices rendering).
static UIImage *LGFastIcon(LGEntry *entry) {
    static NSArray<NSString *> *known;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        known = @[@"AppIcon60x60@3x.png", @"AppIcon60x60@2x.png",
                  @"AppIcon76x76@2x~ipad.png", @"AppIcon76x76@1x~ipad.png"];
    });
    for (NSString *name in known) {
        UIImage *image = [UIImage imageWithContentsOfFile:[entry.url URLByAppendingPathComponent:name].path];
        if (image) return image;
    }
    // Sideloaded IPAs don't always use Apple's file names. Reading the declared
    // CFBundleIcons / CFBundleIconFiles covers those; missing them was what made
    // some cells flash a solid glyph before the themed icon arrived.
    NSDictionary *info = LGPlist([entry.url URLByAppendingPathComponent:@"Info.plist"]);
    NSMutableArray<NSString *> *declared = [NSMutableArray new];
    id icons = info[@"CFBundleIcons"];
    id primary = [icons isKindOfClass:NSDictionary.class] ? icons[@"CFBundlePrimaryIcon"] : nil;
    id primaryFiles = [primary isKindOfClass:NSDictionary.class] ? primary[@"CFBundleIconFiles"] : nil;
    if ([primaryFiles isKindOfClass:NSArray.class]) [declared addObjectsFromArray:primaryFiles];
    id legacyFiles = info[@"CFBundleIconFiles"];
    if ([legacyFiles isKindOfClass:NSArray.class]) [declared addObjectsFromArray:legacyFiles];
    for (id base in declared) {
        if (![base isKindOfClass:NSString.class]) continue;
        for (NSString *suffix in @[@"@3x.png", @"@2x.png", @".png"]) {
            NSString *file = [(NSString *)base stringByAppendingString:suffix];
            UIImage *image = [UIImage imageWithContentsOfFile:[entry.url URLByAppendingPathComponent:file].path];
            if (image) return image;
        }
    }
    // Last resort: any PNG in the bundle root whose name looks like an icon.
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:entry.url.path error:nil]) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
        if ([file rangeOfString:@"icon" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        UIImage *image = [UIImage imageWithContentsOfFile:[entry.url URLByAppendingPathComponent:file].path];
        if (image) return image;
    }
    return nil;
}

// LiveContainer 3.8.x can show its own search field in the navigation area.
// Walking the window (skipping our overlay) lets us avoid stacking a second one.
static BOOL LGIsSearchField(UIView *view) {
    if ([view isKindOfClass:UISearchBar.class]) return YES;
    NSString *name = NSStringFromClass(view.class);
    return [name containsString:@"SearchField"] || [name containsString:@"SearchBar"];
}
// Same walk, but collecting the views themselves so they can be hidden and later
// restored. Deliberately ignores hidden/alpha: an already suppressed bar would
// otherwise never be found again.
static void LGCollectSearchBars(UIView *view, UIView *skip, NSMutableArray<UIView *> *result) {
    if (!view || view == skip) return;
    if (LGIsSearchField(view) && view.window) {
        [result addObject:view];
        return;
    }
    for (UIView *sub in view.subviews) LGCollectSearchBars(sub, skip, result);
}
// Anything that already handles taps itself. Used to keep our guard gestures off
// the host's buttons and rows.
static BOOL LGIsControlLike(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:UIControl.class]) return YES;
        if ([v isKindOfClass:UITableViewCell.class] || [v isKindOfClass:UICollectionViewCell.class]) return YES;
    }
    return NO;
}
static void LGCollectSearchFields(UIView *view, UIView *skip, NSMutableArray<NSValue *> *result) {
    if (!view || view == skip || view.hidden || view.alpha < 0.01) return;
    if (LGIsSearchField(view) && view.window) {
        [result addObject:[NSValue valueWithCGRect:[view convertRect:view.bounds toView:nil]]];
        return;
    }
    for (UIView *sub in view.subviews) LGCollectSearchFields(sub, skip, result);
}

@interface LGPassView : UIView
@end
@implementation LGPassView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

// Running state. LC exposes the container owner as a URL scheme; a non-empty answer
// means some LiveContainer instance is holding that container, i.e. the guest is up.
static BOOL LGRunningGuest(NSString *container) {
    if (container.length == 0) return NO;
    Class utils = NSClassFromString(@"LCSharedUtils");
    SEL selector = NSSelectorFromString(@"getContainerUsingLCSchemeWithFolderName:");
    if (!utils || ![utils respondsToSelector:selector]) return NO;
    id owner = nil;
    @try { owner = ((id (*)(id, SEL, id))objc_msgSend)(utils, selector, container); }
    @catch (__unused NSException *e) { return NO; }
    return [owner isKindOfClass:NSString.class] && ((NSString *)owner).length > 0;
}

// Closing a running guest needs the multitask layer. Stock LC has no such call, so the
// X badge only appears where it can actually do something.
static BOOL LGCanCloseGuests(void) {
    Class multitask = NSClassFromString(@"LCOrbitMultitask");
    return multitask && [multitask respondsToSelector:NSSelectorFromString(@"closeGuest:error:")];
}
static BOOL LGCloseGuestEntry(LGEntry *entry) {
    Class multitask = NSClassFromString(@"LCOrbitMultitask");
    SEL selector = NSSelectorFromString(@"closeGuest:error:");
    if (!multitask || ![multitask respondsToSelector:selector]) return NO;
    NSDictionary *guest = @{@"path": entry.folder ?: @"",
                            @"uuid": entry.container ?: @"",
                            @"folder": entry.url.path ?: @""};
    NSError *error = nil;
    BOOL ok = NO;
    @try { ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(multitask, selector, guest, &error); }
    @catch (__unused NSException *e) { return NO; }
    if (!ok) LGLog([NSString stringWithFormat:@"Close guest refused: %@", error.localizedDescription ?: @"?"]);
    return ok;
}

// Red disc with a white cross, drawn rather than borrowed from SF Symbols: the symbol's
// cross is a knockout, so it goes transparent once the ring is removed.
static UIImage *LGCloseBadgeImage(CGFloat diameter) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(diameter, diameter) format:format];
    return [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef ctx = context.CGContext;
        [UIColor.systemRedColor setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(0, 0, diameter, diameter));
        CGFloat inset = diameter * 0.29, width = MAX(1.4, diameter * 0.13);
        [UIColor.whiteColor setStroke];
        CGContextSetLineWidth(ctx, width);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextMoveToPoint(ctx, inset, inset);
        CGContextAddLineToPoint(ctx, diameter - inset, diameter - inset);
        CGContextMoveToPoint(ctx, diameter - inset, inset);
        CGContextAddLineToPoint(ctx, inset, diameter - inset);
        CGContextStrokePath(ctx);
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

// Emerald light with a breathing halo, same language as the floating-menu tweak.
static UIView *LGRunningLight(CGFloat size) {
    UIView *light = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    light.userInteractionEnabled = NO;
    UIView *halo = [[UIView alloc] initWithFrame:CGRectInset(light.bounds, 1, 1)];
    halo.layer.cornerRadius = CGRectGetWidth(halo.bounds) * 0.5;
    halo.backgroundColor = [UIColor colorWithRed:0.16 green:0.79 blue:0.41 alpha:0.28];
    [light addSubview:halo];
    CGFloat coreSize = MAX(5, MIN(7, size * 0.5));
    UIView *core = [[UIView alloc] initWithFrame:CGRectMake((size - coreSize) * 0.5, (size - coreSize) * 0.5, coreSize, coreSize)];
    core.backgroundColor = [UIColor colorWithRed:0.19 green:0.88 blue:0.47 alpha:1];
    core.layer.cornerRadius = coreSize * 0.5;
    [light addSubview:core];
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        CABasicAnimation *breath = [CABasicAnimation animationWithKeyPath:@"opacity"];
        breath.fromValue = @0.18;
        breath.toValue = @0.78;
        breath.duration = 1.85;
        breath.autoreverses = YES;
        breath.repeatCount = HUGE_VALF;
        breath.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [halo.layer addAnimation:breath forKey:@"lg.running.breath"];
    }
    return light;
}

@interface LGCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *icon;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UIImageView *lock;
@property(nonatomic) BOOL showName;
@property(nonatomic) BOOL locked;
@property(nonatomic, strong) UIView *runningLight;
@property(nonatomic, strong) UIButton *closeBadge;
@property(nonatomic, copy) void (^onClose)(void);
- (void)setRunning:(BOOL)running closable:(BOOL)closable;
- (void)lgShowIcon:(UIImage *)image animated:(BOOL)animated;
- (void)lgShowPlaceholder;
@end
@implementation LGCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _icon = [UIImageView new];
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.clipsToBounds = YES;
        _icon.layer.cornerCurve = kCACornerCurveContinuous;
        _label = [UILabel new];
        _label.font = [UIFont systemFontOfSize:12];
        _label.textColor = UIColor.labelColor;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _lock = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.fill"]];
        _lock.contentMode = UIViewContentModeCenter;
        _lock.tintColor = UIColor.whiteColor;
        _lock.backgroundColor = [UIColor colorWithWhite:0 alpha:0.62];
        _lock.layer.cornerRadius = 9;
        _lock.clipsToBounds = YES;
        _lock.hidden = YES;
        _runningLight = LGRunningLight(12);
        _runningLight.hidden = YES;
        _closeBadge = [UIButton buttonWithType:UIButtonTypeCustom];
        [_closeBadge setImage:LGCloseBadgeImage(19) forState:UIControlStateNormal];
        _closeBadge.hidden = YES;
        [_closeBadge addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_icon];
        [self.contentView addSubview:_lock];
        [self.contentView addSubview:_runningLight];
        [self.contentView addSubview:_closeBadge];
        [self.contentView addSubview:_label];
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}
- (void)setLocked:(BOOL)locked {
    _locked = locked;
    self.lock.hidden = !locked;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat size = MIN(60, MAX(44, self.bounds.size.width - 12));
    _icon.frame = CGRectMake((self.bounds.size.width-size)/2, 6, size, size);
    _icon.layer.cornerRadius = size * 0.2237;
    _lock.frame = CGRectMake(CGRectGetMaxX(_icon.frame)-19, CGRectGetMaxY(_icon.frame)-19, 18, 18);
    // Running light hugs the icon's bottom-right; the close X sits on the top-right so
    // the two never overlap.
    CGFloat lightSize = 12;
    _runningLight.frame = CGRectMake(CGRectGetMaxX(_icon.frame)-lightSize-1,
                                     CGRectGetMaxY(_icon.frame)-lightSize-1, lightSize, lightSize);
    CGFloat badgeSize = 24;
    _closeBadge.frame = CGRectMake(CGRectGetMaxX(_icon.frame)-badgeSize+5,
                                   CGRectGetMinY(_icon.frame)-5, badgeSize, badgeSize);
    _label.frame = CGRectMake(1, size+11, self.bounds.size.width-2, 18);
    _label.hidden = !self.showName;
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.contentView.alpha = highlighted ? 0.55 : 1;
}
- (void)setRunning:(BOOL)running closable:(BOOL)closable {
    self.runningLight.hidden = !running;
    self.closeBadge.hidden = !(running && closable);
    self.accessibilityValue = running ? @"正在运行" : nil;
}
- (void)prepareForReuse {
    [super prepareForReuse];
    self.runningLight.hidden = YES;
    self.closeBadge.hidden = YES;
    self.onClose = nil;
}
- (void)closeTapped {
    if (self.onClose) self.onClose();
}
// Icons arrive in two steps: a cheap bundle PNG on first paint, the themed icon a
// moment later. Fading the second one in removes the hard cut that reads as a
// flash.
- (void)lgShowIcon:(UIImage *)image animated:(BOOL)animated {
    if (!image) { [self lgShowPlaceholder]; return; }
    BOOL wasBlank = self.icon.image == nil;
    self.icon.backgroundColor = UIColor.clearColor;
    self.icon.image = image;
    if (animated && wasBlank) {
        self.icon.alpha = 0;
        [UIView animateWithDuration:0.18 animations:^{ self.icon.alpha = 1; }];
    } else {
        self.icon.alpha = 1;
    }
}
- (void)lgShowPlaceholder {
    // A neutral plate instead of `app.fill`: that SF glyph is a solid block and is
    // exactly the "pure colour flash" seen before the real icon loads.
    self.icon.image = nil;
    self.icon.alpha = 1;
    self.icon.backgroundColor = UIColor.tertiarySystemFillColor;
}
@end

#pragma mark - Settings sheet

typedef NS_ENUM(NSInteger, LGSheetAction) {
    LGSheetActionColumns4 = 0,
    LGSheetActionColumns5,
    LGSheetActionToggleNames,
    LGSheetActionToggleCompact,
    LGSheetActionChooseBackground,
    LGSheetActionRemoveBackground,
    LGSheetActionExportLog,
    LGSheetActionSwitchMode,
    LGSheetActionSwitchToGrid,
};

// Grouped card layout instead of a tall action sheet: every setting is one row
// in a rounded card, with segmented controls and switches as the input.
@interface LGSheetController : UIViewController
@property(nonatomic, copy) NSString *summary;
@property(nonatomic) NSInteger columns;
@property(nonatomic) BOOL showNames;
@property(nonatomic) BOOL compactTop;
@property(nonatomic) BOOL hasBackground;
// Native list mode shows a trimmed sheet: grid settings are meaningless while the
// grid is not on screen, only the switch back matters.
@property(nonatomic) BOOL nativeMode;
@property(nonatomic, copy) void (^handler)(LGSheetAction action);
- (UIView *)headerView;
- (void)buildNativeBranchInRoot:(UIStackView *)root;
- (UIView *)rowWithTitle:(NSString *)title control:(UIView *)control;
- (UIView *)cardWithRows:(NSArray<UIView *> *)rows;
- (UIView *)separator;
- (UIButton *)pillButton:(NSString *)title action:(SEL)action;
@end

@interface LGGridController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate, PHPickerViewControllerDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) UIImageView *backgroundView;
@property(nonatomic, strong) UIView *dimView;
@property(nonatomic, strong) UICollectionView *collection;
@property(nonatomic, strong) UISearchBar *search;
// The host draws "App" as a large title inside its navigation bar, which sits above
// our overlay. In grid mode that bar is covered, so the title is reproduced here with
// the same font and inset to keep the page visually identical.
@property(nonatomic, strong) UILabel *titleLabel;
// Native hides its search field until the list is pulled down; mirror that instead of
// parking an always-visible field above the icons.
@property(nonatomic) BOOL searchRevealed;
@property(nonatomic) CFTimeInterval searchToggleTime;
@property(nonatomic) CFTimeInterval lastRunningCheck;
// Host recognizers we already made wait for the nav guard. Without this the 0.5s
// rescan re-applied requireGestureRecognizerToFail: to the same objects and logged
// once per scan, which is what flooded the device log.
@property(nonatomic, strong) NSHashTable<UIGestureRecognizer *> *adoptedGestures;
@property(nonatomic) BOOL loggedNavAdoption;
// Single floating entry point. Tap toggles grid / native list, long press opens the
// settings sheet — one control, two gestures, both modes.
@property(nonatomic, strong) UIButton *switchButton;
@property(nonatomic, strong) UILabel *empty;
@property(nonatomic, strong) NSArray<LGEntry *> *entries;
@property(nonatomic, strong) NSArray<LGEntry *> *filtered;
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *icons;
@property(nonatomic) BOOL nativeMode;
@property(nonatomic) BOOL wasAway;
@property(nonatomic) CFTimeInterval awaySince;
@property(nonatomic) NSUInteger lastLoggedCount;
@property(nonatomic) BOOL hiddenUnlocked;
@property(nonatomic) BOOL draggingCell;
@property(nonatomic) BOOL moved;
@property(nonatomic) BOOL menuShown;
@property(nonatomic) NSInteger menuToken;
@property(nonatomic, strong) UILabel *footer;
@property(nonatomic, strong) UILongPressGestureRecognizer *longPress;
@property(nonatomic, strong) NSIndexPath *pressIndexPath;
@property(nonatomic, strong) LGEntry *pressEntry;
@property(nonatomic) CGPoint pressStart;
@property(nonatomic) BOOL hadNativeTopSearch;
@property(nonatomic) CGFloat lastTopInset;
@property(nonatomic) UIEdgeInsets lastSafeInsets;
@property(nonatomic, strong) NSMutableSet<NSString *> *pendingIcons;
@property(nonatomic, strong) id nativeSearchObserver;
// LiveContainer search bars we hid in grid mode, kept for restoration.
@property(nonatomic, strong) NSHashTable<UIView *> *suppressedSearchViews;
@property(nonatomic) CFTimeInterval lastSuppressTime;
// Swallows double taps in the host navigation area, which would otherwise wake
// LiveContainer's searchable and cover the grid.
@property(nonatomic, strong) UITapGestureRecognizer *navTapGuard;
// While the grid covers the page, the native list underneath must not react to
// anything: the "expand search" state is reached through the list's own gestures
// (double tap / scroll to top), which live below our overlay and are therefore out
// of reach for a guard attached to the navigation bar.
@property(nonatomic, strong) NSHashTable<UIView *> *hostDisabledViews;
@property(nonatomic, strong) NSHashTable<UIGestureRecognizer *> *hostDisabledGestures;
@property(nonatomic, strong) NSHashTable<UIScrollView *> *hostFrozenScrollViews;
- (CGFloat)lgTopInset;
- (void)lgSyncLayout;
- (void)lgSuppressNativeSearch:(BOOL)suppress;
- (void)lgEnsureNavGuard;
- (void)prefetchIcons;
- (BOOL)lgContainerExists:(LGEntry *)entry;
- (void)lgLaunchEntry:(LGEntry *)entry;
- (BOOL)lgShouldUseMultitask:(LGEntry *)entry;
- (BOOL)lgLaunchMultitaskEntry:(LGEntry *)entry;
- (void)lgUpdateTabVisibility;
- (void)lgUpdateTabVisibilityForce:(BOOL)force;
- (NSNumber *)lgAppsTabState;
- (NSString *)lgAppsTabTitle;
- (NSNumber *)lgSelectedTabViaAccessibility:(NSString *)apps;
- (NSNumber *)lgNavTitleState:(NSString *)apps;
- (BOOL)lgViewOnScreen:(UIView *)view;
- (NSString *)lgNavLabelDump;
- (CGRect)lgNativeTitleFrame;
@property(nonatomic) CFTimeInterval lastLaunchTime;
@property(nonatomic) CFTimeInterval lastTabCheck;
@property(nonatomic) BOOL loggedLayout;
@property(nonatomic) BOOL onAppsTab;
@property(nonatomic) CFTimeInterval lastNativeTitleProbe;
@property(nonatomic) CGRect cachedNativeTitleFrame;
@property(nonatomic, strong) UIFont *cachedNativeTitleFont;
@property(nonatomic, weak) UITabBar *cachedTabBar;
- (void)lgCollapseHostSearchIfNeeded;
- (void)lgAdoptHostDoubleTaps:(UIView *)root;
- (CGFloat)lgNavButtonBottomInBar:(UIView *)bar;
- (void)lgRefreshRunningBadges;
- (void)lgCloseEntry:(LGEntry *)entry;
- (void)lgLayoutContentWithWidth:(CGFloat)w height:(CGFloat)h top:(CGFloat)top safe:(UIEdgeInsets)safe;
- (void)setSearchRevealed:(BOOL)revealed animated:(BOOL)animated;
- (void)lgUpdateSwitchButton;
- (void)toggleMode;
- (void)handleSwitchLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)lgFreezeHostContent:(BOOL)freeze;
- (void)refresh;
@end

@implementation LGGridController
- (void)loadView {
    self.view = [LGPassView new];
    self.view.backgroundColor = UIColor.clearColor;
    self.icons = [NSCache new];
    self.icons.countLimit = 150;
    self.pendingIcons = [NSMutableSet new];
    self.suppressedSearchViews = [NSHashTable weakObjectsHashTable];
    self.hostDisabledViews = [NSHashTable weakObjectsHashTable];
    self.hostDisabledGestures = [NSHashTable weakObjectsHashTable];
    self.hostFrozenScrollViews = [NSHashTable weakObjectsHashTable];
    self.adoptedGestures = [NSHashTable weakObjectsHashTable];
    self.entries = @[];
    self.filtered = @[];
    self.panel = [UIView new];
    self.panel.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.panel.accessibilityViewIsModal = YES;
    [self.view addSubview:self.panel];
    // Background layers sit at the bottom of the panel so the whole page (including
    // the strip under the tab bar) stays opaque.
    self.backgroundView = [UIImageView new];
    self.backgroundView.contentMode = UIViewContentModeScaleAspectFill;
    self.backgroundView.clipsToBounds = YES;
    self.backgroundView.hidden = YES;
    [self.panel addSubview:self.backgroundView];
    self.dimView = [UIView new];
    self.dimView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    self.dimView.userInteractionEnabled = NO;
    self.dimView.hidden = YES;
    [self.panel addSubview:self.dimView];
    self.titleLabel = [UILabel new];
    self.titleLabel.text = @"App";
    // Explicit bold: preferredFontForTextStyle does not guarantee the nav-bar weight.
    // Back to 34pt: the 31pt reading came from a 6.67pt-wide sub-label in the bar, not
    // from the large title itself. Size was never different between the two layouts;
    // only the vertical offset was.
    UIFont *titleBase = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    self.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle] scaledFontForFont:titleBase];
    self.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.titleLabel.textColor = UIColor.labelColor;
    [self.panel addSubview:self.titleLabel];
    self.search = [UISearchBar new];
    self.search.searchBarStyle = UISearchBarStyleMinimal;
    self.search.placeholder = @"搜索";
    self.search.delegate = self;
    self.search.hidden = YES;   // revealed by pulling the grid down, like the host
    self.search.searchTextField.backgroundColor = UIColor.tertiarySystemFillColor;
    [self.panel addSubview:self.search];
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 0;
    layout.minimumLineSpacing = 16;
    layout.sectionInset = UIEdgeInsetsMake(10, 16, 28, 16);
    self.collection = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collection.backgroundColor = UIColor.clearColor;
    self.collection.alwaysBounceVertical = YES;
    // We position the grid ourselves; UIKit's automatic safe-area inset added another
    // ~52pt above the first row (our view lives inside a large-safe-area host).
    self.collection.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.collection.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.collection.dataSource = self;
    self.collection.delegate = self;
    [self.collection registerClass:LGCell.class forCellWithReuseIdentifier:@"App"];
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
    self.collection.refreshControl = refresh;
    self.empty = [UILabel new];
    self.empty.text = @"没有可显示的应用\n隐藏应用和完整管理请打开原生列表";
    self.empty.numberOfLines = 0;
    self.empty.textColor = UIColor.secondaryLabelColor;
    self.empty.textAlignment = NSTextAlignmentCenter;
    self.collection.backgroundView = self.empty;
    [self.panel addSubview:self.collection];
    // One floating button: tap switches layout, long press opens settings. The icon
    // shows the *target* mode, so it reads as "go there".
    UIButtonConfiguration *switchConfig = [UIButtonConfiguration filledButtonConfiguration];
    switchConfig.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    self.switchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.switchButton.configuration = switchConfig;
    [self.switchButton addTarget:self action:@selector(toggleMode) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *switchPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwitchLongPress:)];
    switchPress.minimumPressDuration = 0.45;
    [self.switchButton addGestureRecognizer:switchPress];
    [self.view addSubview:self.switchButton];
    [self lgUpdateSwitchButton];
    self.longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    self.longPress.minimumPressDuration = 0.3;
    self.longPress.delegate = self;   // keep long press off the close badge
    [self.collection addGestureRecognizer:self.longPress];
    self.footer = [UILabel new];
    self.footer.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.footer.textColor = UIColor.secondaryLabelColor;
    self.footer.textAlignment = NSTextAlignmentCenter;
    self.footer.userInteractionEnabled = YES;
    UITapGestureRecognizer *footerTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(footerTapped:)];
    footerTap.numberOfTapsRequired = 3;
    [self.footer addGestureRecognizer:footerTap];
    [self.panel addSubview:self.footer];
    // LiveContainer may show its own search field at the top. Mirror its text into
    // our filter so typing there actually filters the grid (the native list is hidden).
    __weak typeof(self) weakSelf = self;
    self.nativeSearchObserver = [NSNotificationCenter.defaultCenter addObserverForName:UITextFieldTextDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        [weakSelf mirrorNativeSearchText:note.object];
    }];
    self.nativeMode = [NSUserDefaults.standardUserDefaults boolForKey:LGNative];
    self.onAppsTab = YES;   // until the tab probe says otherwise
    [self applyMode];
    [self loadBackground];
    [self refresh];
}
- (CGFloat)lgTopInset {
    // Anchor on the bar's *buttons*, not on the bar's height. The bar grows by ~52pt
    // for the large title and again by ~52pt when the search field is revealed; both
    // of those are counted from the same button row, which never moves. Anything
    // derived from the total height therefore needs to know which state it is in.
    UINavigationController *nav = self.navigationController;
    if (nav && !nav.navigationBarHidden && nav.navigationBar) {
        CGFloat bottom = [self lgNavButtonBottomInBar:nav.navigationBar];
        // Native leaves ~22pt between the button row and the large title; the title
        // itself is drawn another 8pt lower, so 12 here lands on the same line.
        if (bottom > 0) return bottom + 12;
        CGFloat status = self.view.window.safeAreaInsets.top;
        if (status <= 0) status = self.view.safeAreaInsets.top;
        CGFloat row = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) ? 50 : 44;
        return status + row;
    }
    return self.view.safeAreaInsets.top;
}

// Bottom of the lowest *non-search* control inside the navigation bar. Buttons live in
// the bar's content row and are the one thing that stays put across large-title and
// search-expanded states.
- (CGFloat)lgNavButtonBottomInBar:(UIView *)bar {
    CGFloat best = CGFLOAT_MAX;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:bar];
    NSUInteger visited = 0;
    while (queue.count > 0 && visited < 300) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        NSString *name = NSStringFromClass(view.class);
        BOOL isSearch = [name rangeOfString:@"Search" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (!isSearch && [view isKindOfClass:UIControl.class]) {
            CGRect frame = [view convertRect:view.bounds toView:self.view];
            if (CGRectGetHeight(frame) > 8) best = MIN(best, CGRectGetMaxY(frame));
        }
        if (view.subviews.count > 0 && visited < 300) [queue addObjectsFromArray:view.subviews];
    }
    if (best == CGFLOAT_MAX) return 0;
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        LGLog([NSString stringWithFormat:@"Nav anchor: buttonsBottom=%.0f barHeight=%.0f",
               best, CGRectGetHeight([bar convertRect:bar.bounds toView:self.view])]);
    }
    return best;
}
// Navigation bar large-title collapse changes geometry without changing our
// bounds, so viewDidLayoutSubviews never fires and the header keeps its old
// offset (the big blank above the toolbar). Re-layout when that geometry moves.
- (void)lgSyncLayout {
    [self lgUpdateTabVisibility];
    // Another tab is up: the host page underneath owns the screen, and freezing or
    // restyling anything from here would hit pages that are not ours.
    if (!self.onAppsTab) return;
    if (!self.nativeMode) {
        // SwiftUI rebuilds the page (and its search bar) on tab switches; re-apply
        // the suppression, but only a couple of times per second — the walk covers
        // the whole window.
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - self.lastSuppressTime > 0.5) {
            self.lastSuppressTime = now;
            [self lgSuppressNativeSearch:YES];
            [self lgFreezeHostContent:YES];
            [self lgCollapseHostSearchIfNeeded];
            [self lgAdoptHostDoubleTaps:self.navigationController.view];
        }
        [self lgEnsureNavGuard];
        CFTimeInterval runningNow = CFAbsoluteTimeGetCurrent();
        if (runningNow - self.lastRunningCheck > 1.0) {
            self.lastRunningCheck = runningNow;
            [self lgRefreshRunningBadges];
        }
    }
    CGFloat top = [self lgTopInset];
    UIEdgeInsets safe = self.view.safeAreaInsets;
    BOOL hasNativeSearch = !CGRectIsEmpty([self lgTopNativeSearchFrame]);
    if (fabs(top - self.lastTopInset) > 0.5 || !UIEdgeInsetsEqualToEdgeInsets(safe, self.lastSafeInsets) ||
        hasNativeSearch != self.hadNativeTopSearch) {
        [self.view setNeedsLayout];
    }
}
- (CGRect)lgTopNativeSearchFrame {
    UIWindow *window = self.view.window;
    if (!window) return CGRectZero;
    NSMutableArray<NSValue *> *frames = [NSMutableArray new];
    LGCollectSearchFields(window.rootViewController.view, self.view, frames);
    CGRect result = CGRectZero;
    for (NSValue *value in frames) {
        CGRect inSelf = [window convertRect:value.CGRectValue toView:self.view];
        if (inSelf.size.width < 60 || inSelf.size.height < 1) continue;
        CGFloat topInWindow = [self.view convertRect:inSelf toView:nil].origin.y;
        if (topInWindow > 220) continue;  // only the search field in the top area matters
        result = CGRectIsEmpty(result) ? inSelf : CGRectUnion(result, inSelf);
    }
    return result;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // The overlay covers the whole host view (so nothing leaks through the
    // translucent tab bar); interactive content stays inside the safe area.
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGFloat top = [self lgTopInset] + 2;
    // Loose mode adds breathing room under the bar; compact sits flush.
    if (![NSUserDefaults.standardUserDefaults boolForKey:LGCompactTop]) top += 24;
    self.lastTopInset = [self lgTopInset];
    self.lastSafeInsets = safe;
    self.hadNativeTopSearch = NO;
    self.panel.frame = self.view.bounds;
    self.backgroundView.frame = self.panel.bounds;
    self.dimView.frame = self.panel.bounds;
    [self lgLayoutContentWithWidth:w height:h top:top safe:safe];
    CGFloat footerHeight = MAX(24, self.footer.font.lineHeight + 2);
    CGFloat footerGap = 14;
    self.footer.frame = CGRectMake(0, MAX(0, h-safe.bottom-footerHeight-footerGap), w, footerHeight);
    // The gear sits just above the tab bar. safeAreaInsets.bottom is the tab bar's
    // own inset, so clamp to its real top edge instead.
    CGFloat bottomLimit = h - safe.bottom;
    UITabBar *tabBar = self.tabBarController.tabBar;
    if (tabBar && !tabBar.hidden && tabBar.window) {
        CGRect tabFrame = [tabBar convertRect:tabBar.bounds toView:self.view];
        if (!CGRectIsEmpty(tabFrame)) bottomLimit = MIN(bottomLimit, CGRectGetMinY(tabFrame));
    }
    CGFloat buttonHeight = 44, settingsWidth = 44;
    self.switchButton.frame = CGRectMake(MAX(8, w - 16 - settingsWidth), MAX(0, bottomLimit - buttonHeight - 14), settingsWidth, buttonHeight);
    // Forced, not throttled: when the Apps tab comes back this is the first thing
    // that runs, and the panel has to be visible again in this same frame or the
    // native list paints once underneath it.
    [self lgUpdateTabVisibilityForce:YES];
    // SwiftUI re-inserts its page view when a tab returns, which can put it above the
    // overlay until the next tick; do it here so the frame is already correct.
    if (self.view.superview && self.view.superview.subviews.lastObject != self.view) {
        [self.view.superview bringSubviewToFront:self.view];
    }
    if (self.onAppsTab) {
        if (!self.nativeMode) [self lgEnsureNavGuard];
        [self lgFreezeHostContent:!self.nativeMode];
    }
}

// First large-title label the host has on screen. Used once per session, to compare
// our hand-drawn "App" against the real one while switching layouts.
- (UILabel *)lgNativeLargeTitle {
    UIWindow *window = self.view.window;
    if (!window || !window.rootViewController) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window.rootViewController.view];
    NSUInteger visited = 0;
    while (queue.count > 0 && visited < 800) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if ([view isKindOfClass:UILabel.class]) {
            UILabel *label = (UILabel *)view;
            // Never match our own "App" — it is the same size and would make the
            // alignment read its own position back.
            if ([label isDescendantOfView:self.view]) {
                continue;
            }
            if (label.font.pointSize >= 30 && label.font.pointSize <= 40 &&
                label.text.length > 0 && !label.hidden && label.alpha > 0.05) return label;
        }
        for (UIView *sub in view.subviews) if (sub != self.view) [queue addObject:sub];
    }
    return nil;
}

// Native large title frame in our own coordinates. Probed once a second rather than
// on every layout pass: it walks the whole window, and the value only changes when
// the host re-lays out. CGRectNull means "not found yet", which makes the caller fall
// back to its own default.
- (CGRect)lgNativeTitleFrame {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - self.lastNativeTitleProbe < 1.0) return self.cachedNativeTitleFrame;
    self.lastNativeTitleProbe = now;
    UILabel *label = [self lgNativeLargeTitle];
    self.cachedNativeTitleFrame = label
        ? [label convertRect:label.bounds toView:self.view]
        : CGRectNull;
    // Copy the host's own font object: point size, weight and line height then match
    // exactly, instead of approximating with a scaled 34pt bold (which measured 39pt
    // tall against the host's 37pt).
    if (label.font && label.font.pointSize > 0) self.cachedNativeTitleFont = label.font;
    return self.cachedNativeTitleFrame;
}

// One-shot dump of every label inside the host navigation bar. The large title is
// not a plain UILabel on every iOS version, so guessing its frame from a font size
// was unreliable; this prints what is actually there.
- (NSString *)lgNavLabelDump {
    UIWindow *window = self.view.window;
    if (!window) return @"(no window)";
    UINavigationBar *bar = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    NSUInteger visited = 0;
    while (queue.count > 0 && visited < 900) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if ([view isKindOfClass:UINavigationBar.class]) { bar = (UINavigationBar *)view; break; }
        for (UIView *sub in view.subviews) [queue addObject:sub];
    }
    if (!bar) return @"(no nav bar)";
    NSMutableString *out = [NSMutableString string];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:bar];
    visited = 0;
    while (pending.count > 0 && visited < 500 && out.length < 300) {
        UIView *view = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        if ([view isKindOfClass:UILabel.class]) {
            UILabel *label = (UILabel *)view;
            if (label.text.length > 0) {
                [out appendFormat:@"\"%@\" %.0fpt %@  ", label.text, label.font.pointSize,
                 NSStringFromCGRect([label convertRect:label.bounds toView:self.view])];
            }
        }
        for (UIView *sub in view.subviews) [pending addObject:sub];
    }
    return out.length > 0 ? out : @"(no labels)";
}

// Title / search / grid frames. Split out so revealing the search field can animate
// just these three without a full layout pass.
- (void)lgLayoutContentWithWidth:(CGFloat)w height:(CGFloat)h top:(CGFloat)top safe:(UIEdgeInsets)safe {
    // Probe first (once a second), then borrow the host's font before measuring the
    // line height, so the title is the same object the native page draws.
    [self lgNativeTitleFrame];
    if (self.cachedNativeTitleFont) {
        self.titleLabel.adjustsFontForContentSizeCategory = NO;
        self.titleLabel.font = self.cachedNativeTitleFont;
    }
    CGFloat titleHeight = ceil(self.titleLabel.font.lineHeight);
    // +13 puts the title exactly on the host's 119.333; with the host's font copied
    // over, the old "2pt too low" reading no longer applies.
    CGFloat contentTop = top + 13 + titleHeight + 6;
    self.search.hidden = !self.searchRevealed;
    // The host list keeps everything on one 16pt vertical line: large title, search
    // field and row content all start there. UISearchBar adds its own inset inside
    // that frame, and the value differs between iOS versions, so take the line from
    // the text field itself instead of hard-coding what that inset is.
    CGFloat barX = 8;
    self.search.frame = CGRectMake(barX, contentTop, MAX(0, w - barX * 2), 48);
    [self.search layoutIfNeeded];
    CGFloat inset = 16;
    CGFloat fieldX = CGRectGetMinX(self.search.searchTextField.frame);
    if (fieldX > 0 && fieldX < 40) inset = barX + fieldX;
    // Follow the host's own large title when it can be measured. That is the only
    // value guaranteed to match, whatever horizontal inset this iOS version uses —
    // the host title sits right above the grid and is simply covered, not removed.
    CGRect hostTitle = [self lgNativeTitleFrame];
    if (!CGRectIsNull(hostTitle)) {
        CGFloat hostX = CGRectGetMinX(hostTitle);
        if (hostX > 4 && hostX < 60) inset = hostX;
    }
    self.titleLabel.frame = CGRectMake(inset, top + 13, MAX(0, w - inset * 2), titleHeight);
    CGFloat headerHeight = self.searchRevealed ? 48 : 0;
    CGFloat footerHeight = MAX(24, self.footer.font.lineHeight + 2);
    CGFloat footerGap = 14;
    CGRect frame = CGRectMake(0, contentTop + headerHeight, w,
        MAX(0, h - (contentTop + headerHeight) - safe.bottom - footerHeight - footerGap - 2));
    BOOL resized = !CGSizeEqualToSize(self.collection.bounds.size, frame.size);
    self.collection.frame = frame;
    if (resized) [self.collection.collectionViewLayout invalidateLayout];
    // Measure once the overlay actually has a window: on the first mount it does not,
    // and the host's large title is unreachable, which is why the earlier probe said
    // "(none)". Reset on every layout switch so both states get a reading.
    if (!self.loggedLayout && self.view.window) {
        self.loggedLayout = YES;
        CGRect measured = [self lgNativeTitleFrame];
        NSString *nativeFrame = CGRectIsNull(measured) ? @"(none)" : NSStringFromCGRect(measured);
        LGLog([NSString stringWithFormat:@"Layout top=%.0f inset=%.0f search=%@ title=%@ nativeTitle=%@ grid=%@ navLabels=%@",
               top, inset, NSStringFromCGRect(self.search.frame), NSStringFromCGRect(self.titleLabel.frame),
               nativeFrame, NSStringFromCGRect(frame), [self lgNavLabelDump]]);
    }
}

- (UITabBar *)lgTabBarIn:(UIView *)root {
    if (!root) return nil;
    if ([root isKindOfClass:UITabBar.class]) return (UITabBar *)root;
    for (UIView *sub in root.subviews) {
        UITabBar *found = [self lgTabBarIn:sub];
        if (found) return found;
    }
    return nil;
}

- (NSString *)lgAppsTabTitle {
    NSBundle *bundle = LGGet(NSUserDefaults.class, @"lcMainBundle");
    return [bundle localizedStringForKey:@"lc.tabView.apps" value:@"" table:nil];
}

// LiveContainer's shell is a single SwiftUI TabView (LCTabView): all four tabs share
// one hosting container, so the overlay covers every page unless it is told which
// tab is up. A wrong guess blanks the grid, so the answer is three-valued — @YES and
// @NO only when the selected tab is actually readable, nil when it is not.
- (NSNumber *)lgAppsTabState {
    NSString *apps = [self lgAppsTabTitle];
    if (apps.length == 0) return nil;   // localization unavailable: never hide

    UITabBarController *tabs = self.tabBarController;
    if (tabs) {
        NSString *title = tabs.selectedViewController.tabBarItem.title;
        if (title.length == 0) {
            NSInteger index = tabs.selectedIndex;
            if (index >= 0 && index < (NSInteger)tabs.tabBar.items.count) {
                title = tabs.tabBar.items[index].title;
            }
        }
        if (title.length > 0) return @([title isEqualToString:apps]);
    }

    UITabBar *bar = self.cachedTabBar;
    if (!bar || !bar.window) {
        bar = [self lgTabBarIn:self.view.window];
        self.cachedTabBar = bar;
    }
    if (bar.selectedItem.title.length > 0) return @([bar.selectedItem.title isEqualToString:apps]);

    // SwiftUI's own NavigationStack still shows a real UINavigationBar; the Apps page
    // is the only one whose bar carries this title.
    NSNumber *navState = [self lgNavTitleState:apps];
    if (navState) return navState;

    // Last resort: even a self-drawn SwiftUI tab bar exposes the selected item as an
    // accessibility element carrying the selected trait.
    return [self lgSelectedTabViaAccessibility:apps];
}

- (BOOL)lgViewOnScreen:(UIView *)view {
    if (!view || !view.window) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if (v.hidden || v.alpha < 0.1) return NO;
    }
    CGRect frame = [view convertRect:view.bounds toView:view.window];
    return CGRectIntersectsRect(frame, view.window.bounds);
}

- (NSNumber *)lgNavTitleState:(NSString *)apps {
    UIWindow *window = self.view.window;
    if (!window) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
    NSUInteger visited = 0;
    while (queue.count > 0 && visited < 900) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if ([view isKindOfClass:UINavigationBar.class] && [self lgViewOnScreen:view]) {
            UINavigationBar *bar = (UINavigationBar *)view;
            NSString *title = bar.topItem.title ?: bar.items.firstObject.title;
            if (title.length > 0) return @([title isEqualToString:apps]);
        }
        for (UIView *sub in view.subviews) [queue addObject:sub];
    }
    return nil;
}

- (NSNumber *)lgSelectedTabViaAccessibility:(NSString *)apps {
    UIWindow *window = self.view.window;
    if (!window) return nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
    NSUInteger visited = 0;
    while (stack.count > 0 && visited < 1200) {
        id node = stack.lastObject;
        [stack removeLastObject];
        visited++;
        NSString *label = nil;
        UIAccessibilityTraits traits = 0;
        if ([node isKindOfClass:UIView.class]) {
            UIView *view = node;
            if (view.isAccessibilityElement) {
                label = view.accessibilityLabel;
                traits = view.accessibilityTraits;
            }
            NSArray *elements = view.accessibilityElements;
            if (elements.count > 0) {
                for (id element in elements) if (element != view) [stack addObject:element];
            }
            for (UIView *sub in view.subviews) [stack addObject:sub];
        } else if ([node respondsToSelector:@selector(accessibilityLabel)] &&
                   [node respondsToSelector:@selector(accessibilityTraits)]) {
            label = [(id)node accessibilityLabel];
            traits = [(id)node accessibilityTraits];
        }
        if (label.length > 0 && (traits & UIAccessibilityTraitSelected)) {
            return @([label isEqualToString:apps]);
        }
    }
    return nil;
}

- (void)lgUpdateTabVisibility {
    [self lgUpdateTabVisibilityForce:NO];
}

- (void)lgUpdateTabVisibilityForce:(BOOL)force {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (!force && now - self.lastTabCheck < 0.15) return;
    self.lastTabCheck = now;
    NSNumber *state = [self lgAppsTabState];
    BOOL onApps = state ? state.boolValue : YES;
    self.onAppsTab = onApps;
    // The overlay sits in the container shared by all four tabs, so on any other tab
    // it would paint the grid over that page. Hide the content and the button, but
    // keep the (transparent, hit-test-passing) view itself mounted so switching back
    // does not depend on a probe that may not be able to read the current tab.
    self.panel.hidden = self.nativeMode || !onApps;
    self.switchButton.hidden = !onApps;
    // The freeze pass disables every sibling of the overlay — on the shared container
    // that includes the other three tabs, which would leave them unresponsive.
    if (!onApps && !self.nativeMode) [self lgFreezeHostContent:NO];
    NSInteger current = state ? (state.boolValue ? 1 : 0) : -1;
    static NSInteger lastState = -2;
    if (current != lastState) {
        lastState = current;
        UITabBarController *tabs = self.tabBarController;
        NSString *selected = tabs.selectedViewController.tabBarItem.title ?: self.cachedTabBar.selectedItem.title;
        LGLog([NSString stringWithFormat:@"Apps tab state=%ld selected=%@ tabBar=%@ tabBarVC=%@",
               (long)current, selected.length ? selected : @"?",
               self.cachedTabBar ? NSStringFromClass(self.cachedTabBar.class) : @"nil",
               tabs ? NSStringFromClass(tabs.class) : @"nil"]);
    }
}

- (void)setSearchRevealed:(BOOL)revealed animated:(BOOL)animated {
    if (self.searchRevealed == revealed) return;
    self.searchRevealed = revealed;
    self.searchToggleTime = CFAbsoluteTimeGetCurrent();
    void (^changes)(void) = ^{
        [self lgLayoutContentWithWidth:self.view.bounds.size.width
                                height:self.view.bounds.size.height
                                   top:[self lgTopInset] + 2 +
                                       ([NSUserDefaults.standardUserDefaults boolForKey:LGCompactTop] ? 0 : 24)
                                  safe:self.view.safeAreaInsets];
    };
    if (animated) {
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:changes completion:nil];
    } else {
        changes();
    }
    if (!revealed) {
        self.search.text = @"";
        [self.search resignFirstResponder];
        [self filter];
    }
}

// Same behaviour as the host list: pull down past the top to reveal the field, scroll
// up again to put it away. The cooldown keeps the frame change itself from re-triggering.
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != self.collection) return;
    if (CFAbsoluteTimeGetCurrent() - self.searchToggleTime < 0.35) return;
    CGFloat offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top;
    if (!self.searchRevealed && offset < -24) {
        [self setSearchRevealed:YES animated:YES];
    } else if (self.searchRevealed && offset > 12 && !self.search.isFirstResponder) {
        [self setSearchRevealed:NO animated:YES];
    }
}

- (void)lgUpdateSwitchButton {
    BOOL toNative = !self.nativeMode;
    UIButtonConfiguration *config = self.switchButton.configuration;
    config.image = [UIImage systemImageNamed:(toNative ? @"list.bullet" : @"square.grid.3x3.fill")];
    self.switchButton.configuration = config;   // struct: reassign to apply
    self.switchButton.accessibilityLabel = toNative ? @"切换到列表布局" : @"切换到宫格布局";
    self.switchButton.accessibilityHint = @"长按打开网格设置";
}
- (void)toggleMode {
    if (self.nativeMode) [self showGrid]; else [self showNative];
}
- (void)handleSwitchLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    [self showSettings];
}
- (void)applyMode {
    self.panel.hidden = self.nativeMode || !self.onAppsTab;
    [self lgUpdateSwitchButton];
    [self lgSuppressNativeSearch:!self.nativeMode];
    [self lgFreezeHostContent:!self.nativeMode];
    if (self.nativeMode && self.navTapGuard) {
        [self.navTapGuard.view removeGestureRecognizer:self.navTapGuard];
        self.navTapGuard = nil;
    }
    [NSUserDefaults.standardUserDefaults setBool:self.nativeMode forKey:LGNative];
}
- (void)showNative { [self.view endEditing:YES]; self.nativeMode = YES; self.loggedLayout = NO; self.lastNativeTitleProbe = 0; [self applyMode]; }
- (void)showGrid { self.nativeMode = NO; self.loggedLayout = NO; self.lastNativeTitleProbe = 0; [self applyMode]; [self refresh]; }
- (void)refresh {
    self.entries = LGReadApps(self.hiddenUnlocked);
    // Keep the icon cache: clearing it forced every icon to be regenerated on each
    // tab switch, which is what made returning to this page stall for ~1s.
    [self filter];
    [self.collection.refreshControl endRefreshing];
    [self prefetchIcons];
    // Log on change only: a rescan runs on every tab return and the line was printed
    // dozens of times a minute, burying anything useful.
    NSUInteger total = self.entries.count + LGCountHidden + LGCountAmbiguous + LGCountDamaged;
    if (total != self.lastLoggedCount) {
        self.lastLoggedCount = total;
        LGLog([NSString stringWithFormat:@"Loaded %lu app(s); skipped hidden=%lu ambiguous=%lu damaged=%lu",
               (unsigned long)self.entries.count, (unsigned long)LGCountHidden,
               (unsigned long)LGCountAmbiguous, (unsigned long)LGCountDamaged]);
    }
}
// Generate themed icons for everything currently listed, one per run-loop turn.
// Without this each cell had to wait for the generator on first display, which is
// when the placeholder plate was visible.
- (void)prefetchIcons {
    for (LGEntry *entry in self.filtered) {
        NSString *key = [self iconKeyForEntry:entry];
        if ([self.icons objectForKey:key]) continue;
        [self requestIconForEntry:entry key:key];
    }
}
- (void)filter {
    NSString *query = self.search.text ?: @"";
    self.filtered = [self.entries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(LGEntry *entry, NSDictionary *bindings) {
        return query.length == 0 || [entry.name localizedCaseInsensitiveContainsString:query];
    }]];
    self.empty.hidden = self.filtered.count != 0;
    NSString *fmt = [LGGet(NSUserDefaults.class, @"lcMainBundle") localizedStringForKey:@"lc.appList.appCounter" value:@"共 %lld 个 App" table:nil];
    if (![fmt isKindOfClass:NSString.class] || fmt.length == 0) fmt = @"共 %lld 个 App";
    NSString *counter = [NSString localizedStringWithFormat:fmt, (long long)self.filtered.count];
    self.footer.text = counter;
    [self.collection reloadData];
}
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText { [self filter]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section { return self.filtered.count; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    LGCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"App" forIndexPath:indexPath];
    LGEntry *entry = self.filtered[indexPath.item];
    cell.label.text = entry.name;
    cell.locked = entry.locked;
    cell.accessibilityLabel = entry.name;
    cell.showName = [NSUserDefaults.standardUserDefaults boolForKey:LGNames];
    NSString *key = [self iconKeyForEntry:entry];
    UIImage *icon = [self.icons objectForKey:key];
    if (icon) {
        [cell lgShowIcon:icon animated:NO];
    } else {
        // First frame: the bundle's own PNG (a few ms) instead of blocking on
        // IconServices. The themed icon replaces it one run-loop turn later, and
        // fades in so the swap is not a visible flash.
        [cell lgShowIcon:LGFastIcon(entry) animated:NO];
        [self requestIconForEntry:entry key:key];
    }
    __weak typeof(self) weakSelf = self;
    cell.onClose = ^{ [weakSelf lgCloseEntry:entry]; };
    [cell setRunning:LGRunningGuest(entry.container) closable:LGCanCloseGuests()];
    [cell setNeedsLayout];
    return cell;
}
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)path {
    NSInteger columns = [NSUserDefaults.standardUserDefaults integerForKey:LGColumns] == 5 ? 5 : 4;
    // Match sectionInset's 16pt sides: the host list starts its rows on the same line.
    CGFloat width = floor(MAX(0, collectionView.bounds.size.width - 32) / columns);
    return CGSizeMake(width, [NSUserDefaults.standardUserDefaults boolForKey:LGNames] ? 92 : 74);
}
- (NSString *)iconKeyForEntry:(LGEntry *)entry {
    NSInteger style = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? 1 : 0;
    return [NSString stringWithFormat:@"%@:%ld", entry.url.path, (long)style];
}
- (void)requestIconForEntry:(LGEntry *)entry key:(NSString *)key {
    if ([self.pendingIcons containsObject:key]) return;
    [self.pendingIcons addObject:key];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf generateIconForEntry:entry key:key];
    });
}
- (void)generateIconForEntry:(LGEntry *)entry key:(NSString *)key {
    [self.pendingIcons removeObject:key];
    if ([self.icons objectForKey:key]) return;
    SEL selector = NSSelectorFromString(@"generateIconForBundleURL:style:hasBorder:");
    if (![UIImage.class respondsToSelector:selector]) return;
    UIImage *icon = nil;
    @try {
        NSInteger style = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? 1 : 0;
        icon = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(UIImage.class, selector, entry.url, style, NO);
    } @catch (__unused NSException *e) { LGLog(@"Host icon provider failed; using fallback"); }
    if (!icon) return;
    [self.icons setObject:icon forKey:key];
    NSUInteger index = [self.filtered indexOfObjectPassingTest:^BOOL(LGEntry *candidate, NSUInteger idx, BOOL *stop) {
        return [candidate.url.path isEqualToString:entry.url.path];
    }];
    if (index == NSNotFound) return;
    // Update in place with a fade instead of reloading the row: a reload swapped the
    // image in one frame, which is what made the change look like a flash.
    LGCell *visible = (LGCell *)[self.collection cellForItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]];
    if (visible) [visible lgShowIcon:icon animated:YES];
}
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    LGEntry *entry = self.filtered[indexPath.item];
    // Hidden entries are shown only after unlocking, so they must stay launchable;
    // only damaged metadata (or a stale hidden entry) is dropped here.
    LGEntryState state = LGEntryStateFor(entry.url);
    if (state == LGEntryStateDamaged || (state == LGEntryStateHidden && !self.hiddenUnlocked)) {
        [self refresh];
        return;
    }
    if (entry.container.length > 0 && ![self lgContainerExists:entry]) {
        // LiveContainer's own list fails on this app too ("未能打开文件…"): the
        // LCDataUUID points at a data container that is no longer on disk. Say so
        // instead of letting the host throw a bare filename at the user.
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法启动"
                                                                       message:[NSString stringWithFormat:
            @"这个应用的数据容器“%@”在 LiveContainer 里已不存在。\n\nLiveContainer 的原生列表点它也会报同样的错，所以不是网格的问题。请在 LC 里给它重建容器，或重新导入这个 app。\n\n仍可点「仍然尝试」，但通常会失败。",
            entry.container]
                                                            preferredStyle:UIAlertControllerStyleAlert];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"仍然尝试" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf lgLaunchEntry:entry];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self lgLaunchEntry:entry];
}

// Container folders live next to the app: private list under Documents/Data/
// Application, shared list under the app group. If neither has the folder, the
// record is stale.
- (BOOL)lgContainerExists:(LGEntry *)entry {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *docs = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    NSMutableArray<NSURL *> *roots = [NSMutableArray arrayWithObject:
        [[docs URLByAppendingPathComponent:@"Data/Application"] URLByAppendingPathComponent:entry.container]];
    NSURL *group = LGGet(NSClassFromString(@"LCSharedUtils"), @"appGroupPath");
    if (!group) group = [fm containerURLForSecurityApplicationGroupIdentifier:@"group.com.SideStore.SideStore"];
    if (group) {
        [roots addObject:[[[group URLByAppendingPathComponent:@"LiveContainer"]
                           URLByAppendingPathComponent:@"Data/Application"]
                          URLByAppendingPathComponent:entry.container]];
    }
    for (NSURL *url in roots) {
        BOOL directory = NO;
        if ([fm fileExistsAtPath:url.path isDirectory:&directory] && directory) return YES;
    }
    return NO;
}

// LiveContainer picks the launch route per app: a multitask window when that app (or
// the global default) asks for it, a classic restart into the guest otherwise.
// Mirrors LCAppModel.shouldLaunchInMultitaskMode, so the grid does not silently
// disable a setting the user turned on.
- (BOOL)lgShouldUseMultitask:(LGEntry *)entry {
    if (entry.classicMode || entry.jitNeeded) return NO;
    if (entry.multitaskSpecified == 1) return NO;
    if (@available(iOS 16.0, *)) {
        if (entry.multitaskSpecified == 2) return YES;
        return [NSUserDefaults.standardUserDefaults boolForKey:@"LCLaunchInMultitaskMode"];
    }
    return NO;
}

// LCUtils reads `selected` / `selectedContainer` and removes them again, so they
// must be written immediately before the call. NO means the entry point is missing
// and the caller should fall back to the classic URL launch.
- (BOOL)lgLaunchMultitaskEntry:(LGEntry *)entry {
    Class utils = NSClassFromString(@"LCUtils");
    SEL selector = NSSelectorFromString(@"launchMultitaskGuestApp:completionHandler:");
    if (!utils || ![utils respondsToSelector:selector]) return NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:entry.folder forKey:@"selected"];
    if (entry.container.length > 0) {
        [defaults setObject:entry.container forKey:@"selectedContainer"];
    } else {
        [defaults removeObjectForKey:@"selectedContainer"];
    }
    __weak typeof(self) weakSelf = self;
    void (^completion)(NSNumber *, NSError *) = ^(NSNumber *pid, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                LGLog([NSString stringWithFormat:@"Multitask launch failed: %@", error.localizedDescription]);
                [weakSelf showError:[NSString stringWithFormat:
                    @"多任务启动失败：%@\n\n可以再点一次，或改用原生列表启动。", error.localizedDescription]];
                return;
            }
            LGLog([NSString stringWithFormat:@"Multitask launch accepted (pid=%@)", pid]);
            [weakSelf lgRefreshRunningBadges];
        });
    };
    @try {
        ((void (*)(id, SEL, NSString *, void (^)(NSNumber *, NSError *)))objc_msgSend)(utils, selector, entry.name ?: entry.folder, completion);
    } @catch (__unused NSException *e) {
        return NO;
    }
    return YES;
}

- (void)lgLaunchEntry:(LGEntry *)entry {
    if ([self lgShouldUseMultitask:entry]) {
        // Double taps arrive twice; LCUtils consumes the global `selected` key, so a
        // second call while the first is in flight would start the wrong app.
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - self.lastLaunchTime < 1.0) return;
        self.lastLaunchTime = now;
        [self.view endEditing:YES];
        if ([self lgLaunchMultitaskEntry:entry]) {
            LGLog([NSString stringWithFormat:@"Launching %@ via=multitask spec=%ld jit=%d",
                   entry.folder, (long)entry.multitaskSpecified, entry.jitNeeded]);
            return;
        }
        LGLog(@"Multitask entry point unavailable; falling back to classic launch");
    }
    NSString *scheme = LGGet(NSClassFromString(@"LCUtils"), @"appUrlScheme");
    if (![scheme isKindOfClass:NSString.class] || scheme.length == 0) {
        LGLog(@"Launch refused: no native URL scheme");
        [self showError:@"LiveContainer 没有提供启动用的 URL scheme，无法从这个网格启动应用。请改用原生列表。"];
        return;
    }
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = scheme;
    components.host = @"livecontainer-launch";
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithObject:
        [NSURLQueryItem queryItemWithName:@"bundle-name" value:entry.folder]];
    if (entry.container.length > 0) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"container-folder-name" value:entry.container]];
    }
    components.queryItems = items;
    NSURL *url = components.URL;
    if (!url) return;
    [self.view endEditing:YES];
    LGLog([NSString stringWithFormat:@"Launching %@ (container=%@)", entry.folder, entry.container ?: @"(default)"]);

    // Prefer the host's own entry point: same URL, but handed straight to
    // LCSharedUtils instead of round-tripping through SpringBoard. This is what the
    // floating-menu tweak does and it survives states where openURL is refused.
    Class utils = NSClassFromString(@"LCSharedUtils");
    SEL direct = NSSelectorFromString(@"launchToGuestAppWithURL:");
    if (utils && [utils respondsToSelector:direct]) {
        BOOL accepted = NO;
        @try {
            accepted = ((BOOL (*)(id, SEL, NSURL *))objc_msgSend)(utils, direct, url);
        } @catch (__unused NSException *e) { accepted = NO; }
        if (accepted) {
            LGLog(@"Host launch API accepted the request");
            return;
        }
        LGLog(@"Host launch API refused; falling back to openURL");
    }

    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        LGLog(success ? @"Native launch URL accepted (guest launch outcome not asserted)" : @"Native launch URL rejected");
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showError:@"系统拒绝了启动请求。请改用原生列表，并查看 LCGridLayout.log。"];
            });
        }
    }];
}
// Poll the host for container ownership once a second; only visible cells are touched,
// so the cost stays flat with the library size.
- (void)lgRefreshRunningBadges {
    BOOL closable = LGCanCloseGuests();
    for (NSIndexPath *indexPath in self.collection.indexPathsForVisibleItems) {
        if (indexPath.item >= (NSInteger)self.filtered.count) continue;
        LGEntry *entry = self.filtered[indexPath.item];
        LGCell *cell = (LGCell *)[self.collection cellForItemAtIndexPath:indexPath];
        if (!cell) continue;
        [cell setRunning:LGRunningGuest(entry.container) closable:closable];
    }
}

- (void)lgCloseEntry:(LGEntry *)entry {
    if (!LGCloseGuestEntry(entry)) {
        [self showError:@"当前 LiveContainer 不支持从网格结束正在运行的应用。请在 LC 的多任务界面里关闭它。"];
        return;
    }
    LGLog([NSString stringWithFormat:@"Closed running guest %@", entry.folder]);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf lgRefreshRunningBadges];
    });
}

- (void)showError:(NSString *)message {
    if (self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法启动" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)loadBackground {
    UIImage *image = [UIImage imageWithContentsOfFile:LGBackgroundPath()];
    self.backgroundView.image = image;
    self.backgroundView.hidden = image == nil;
    self.dimView.hidden = image == nil;
    self.panel.backgroundColor = image ? UIColor.clearColor : UIColor.systemGroupedBackgroundColor;
}
- (void)chooseBackground {
    [self chooseBackgroundRetrying:2];
}
- (void)chooseBackgroundRetrying:(NSInteger)retries {
    // Called from the settings action sheet as well: let it finish dismissing first.
    if (self.presentedViewController) {
        if (retries <= 0) return;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf chooseBackgroundRetrying:retries - 1];
        });
        return;
    }
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = [PHPickerFilter imagesFilter];
    config.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;
    NSItemProvider *provider = results.firstObject.itemProvider;
    if (![provider canLoadObjectOfClass:UIImage.class]) {
        [self showError:@"这张图片无法读取，请换一张试试。"];
        return;
    }
    [provider loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
        UIImage *image = [object isKindOfClass:UIImage.class] ? (UIImage *)object : nil;
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [self applyBackground:image]; });
    }];
}
- (void)applyBackground:(UIImage *)image {
    // Cap the stored file so decoding stays cheap on launch.
    CGFloat maxSide = 2200;
    CGSize size = image.size;
    CGFloat ratio = MIN(1, maxSide / MAX(size.width, size.height));
    if (ratio < 1) {
        CGSize target = CGSizeMake(round(size.width * ratio), round(size.height * ratio));
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target];
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
        }];
    }
    NSData *data = UIImageJPEGRepresentation(image, 0.9);
    if (!data || ![data writeToFile:LGBackgroundPath() atomically:YES]) {
        [self showError:@"背景图片保存失败，请重试。"];
        return;
    }
    [self loadBackground];
    LGLog(@"Background image updated");
}
- (void)removeBackground {
    [NSFileManager.defaultManager removeItemAtPath:LGBackgroundPath() error:nil];
    [self loadBackground];
}
- (void)exportLog {
    if (self.presentedViewController) return;
    NSURL *url = [NSURL fileURLWithPath:LGLogPath()];
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        [self showError:@"还没有日志文件：插件可能没有被加载。"];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.switchButton;
    share.popoverPresentationController.sourceRect = self.switchButton.bounds;
    [self presentViewController:share animated:YES completion:nil];
}

#pragma mark - Long-press actions (hide / uninstall / reorder)

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:self.collection];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            NSIndexPath *indexPath = [self.collection indexPathForItemAtPoint:point];
            if (!indexPath || indexPath.item >= (NSInteger)self.filtered.count) return;
            self.pressIndexPath = indexPath;
            self.pressEntry = self.filtered[indexPath.item];
            self.pressStart = point;
            self.moved = NO;
            self.menuShown = NO;
            self.draggingCell = NO;
            UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [haptic impactOccurred];
            // Keep holding still: the menu shows without waiting for the finger to lift.
            NSInteger token = ++self.menuToken;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!weakSelf || weakSelf.menuToken != token || weakSelf.moved || weakSelf.menuShown || !weakSelf.pressEntry) return;
                weakSelf.menuShown = YES;
                UICollectionViewCell *cell = [weakSelf.collection cellForItemAtIndexPath:weakSelf.pressIndexPath];
                [weakSelf showActionsForEntry:weakSelf.pressEntry cell:cell];
            });
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!self.pressEntry || self.menuShown) return;
            CGFloat dx = point.x - self.pressStart.x;
            CGFloat dy = point.y - self.pressStart.y;
            if (!self.moved && sqrt(dx * dx + dy * dy) > 6) {
                self.moved = YES;
                self.menuToken++;  // cancels the pending menu
                self.draggingCell = YES;
                [self.collection beginInteractiveMovementForItemAtIndexPath:self.pressIndexPath];
                UIImpactFeedbackGenerator *dragHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                [dragHaptic impactOccurred];
            }
            if (self.draggingCell) [self.collection updateInteractiveMovementTargetPosition:point];
            break;
        }
        case UIGestureRecognizerStateEnded: {
            self.menuToken++;
            if (self.moved && self.draggingCell) {
                self.draggingCell = NO;
                [self.collection endInteractiveMovement];
                [self saveOrder];
            } else if (!self.menuShown && self.pressEntry) {
                // Quick release before the timer: still show the menu.
                UICollectionViewCell *cell = [self.collection cellForItemAtIndexPath:self.pressIndexPath];
                [self showActionsForEntry:self.pressEntry cell:cell];
            }
            self.pressEntry = nil;
            break;
        }
        default: {
            self.menuToken++;
            if (self.draggingCell) {
                self.draggingCell = NO;
                [self.collection cancelInteractiveMovement];
            }
            self.pressEntry = nil;
            break;
        }
    }
}
- (void)showActionsForEntry:(LGEntry *)entry cell:(UICollectionViewCell *)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:entry.name message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"隐藏" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf hideEntry:entry];
    }]];
    if (!entry.shared) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"卸载" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [weakSelf confirmUninstallEntry:entry];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    // iPhone: leave the source unset so UIKit shows the standard bottom sheet.
    // Setting an anchor makes iOS 26 draw it as a bubble near the icon instead.
    if (sheet.popoverPresentationController && self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = cell ?: self.collection;
        sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.collection.bounds;
    }
    [self presentAlert:sheet retries:3];
}

- (void)presentAlert:(UIAlertController *)alert retries:(NSInteger)retries {
    if (self.presentedViewController) {
        if (retries <= 0) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self presentAlert:alert retries:retries - 1];
        });
        return;
    }
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showAlertTitle:(NSString *)title message:(NSString *)message {
    if (self.presentedViewController) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf showAlertTitle:title message:message];
        });
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)hideEntry:(LGEntry *)entry {
    NSURL *metaURL = [entry.url URLByAppendingPathComponent:@"LCAppInfo.plist"];
    NSMutableDictionary *meta = [[NSDictionary dictionaryWithContentsOfURL:metaURL] mutableCopy];
    if (!meta) meta = [NSMutableDictionary new];
    meta[@"isHidden"] = @YES;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:meta format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data || ![data writeToURL:metaURL atomically:YES]) {
        [self showAlertTitle:@"隐藏失败" message:@"无法写入应用元数据，请重试或改用原生列表。"];
        return;
    }
    [self refresh];
    LGLog(@"Hid an app via LCAppInfo.plist");
}

- (NSArray<NSString *> *)containerFoldersForEntry:(LGEntry *)entry {
    NSDictionary *meta = LGPlist([entry.url URLByAppendingPathComponent:@"LCAppInfo.plist"]);
    NSMutableArray<NSString *> *folders = [NSMutableArray new];
    for (NSDictionary *container in meta[@"LCContainers"]) {
        NSString *folder = [container isKindOfClass:NSDictionary.class] ? container[@"folderName"] : nil;
        if ([folder isKindOfClass:NSString.class] && folder.length) [folders addObject:folder];
    }
    return folders;
}

- (void)confirmUninstallEntry:(LGEntry *)entry {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"卸载「%@」？", entry.name]
                                                                   message:@"将删除应用包，此操作不可撤销。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"卸载" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self askDeleteDataForEntry:entry];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentAlert:alert retries:3];
}

- (void)askDeleteDataForEntry:(LGEntry *)entry {
    NSArray<NSString *> *containers = [self containerFoldersForEntry:entry];
    if (containers.count == 0) {
        [self performUninstallEntry:entry deleteContainers:@[]];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"是否删除应用数据？"
                                                                   message:@"保留数据可以以后恢复；删除后不可找回。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"同时删除数据" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self performUninstallEntry:entry deleteContainers:containers];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保留数据" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self performUninstallEntry:entry deleteContainers:@[]];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentAlert:alert retries:3];
}

- (void)performUninstallEntry:(LGEntry *)entry deleteContainers:(NSArray<NSString *> *)containers {
    NSError *error = nil;
    if (![[NSFileManager defaultManager] removeItemAtURL:entry.url error:&error]) {
        [self showAlertTitle:@"卸载失败" message:[error localizedDescription] ?: @"无法删除应用包。"];
        return;
    }
    if (containers.count) {
        NSURL *dataRoot = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject URLByAppendingPathComponent:@"Data/Application"];
        for (NSString *folder in containers) {
            [[NSFileManager defaultManager] removeItemAtURL:[dataRoot URLByAppendingPathComponent:folder] error:nil];
        }
    }
    NSMutableArray<NSString *> *order = [[[NSUserDefaults standardUserDefaults] arrayForKey:LGOrder] mutableCopy];
    if (!order) order = [NSMutableArray new];
    [order removeObject:entry.folder];
    [[NSUserDefaults standardUserDefaults] setObject:order forKey:LGOrder];
    [self refresh];
    [self showAlertTitle:@"已卸载" message:@"应用包已删除。建议完全退出并重新打开 LiveContainer，刷新原生列表。"];
}

#pragma mark - Reordering

- (void)saveOrder {
    NSArray<NSString *> *folders = [self.filtered valueForKey:@"folder"];
    [[NSUserDefaults standardUserDefaults] setObject:folders forKey:LGOrder];
    // Mirror into LiveContainer's custom-sort store only when the user already
    // selected custom sorting there, so the native list never changes mode itself.
    NSUserDefaults *group = LGAppGroupDefaults();
    if (group && [[group stringForKey:@"LCAppSortType"] isEqualToString:@"custom"]) {
        NSMutableArray<NSString *> *nativeOrder = [NSMutableArray new];
        for (LGEntry *entry in self.filtered) {
            if (entry.bundleId.length) [nativeOrder addObject:[NSString stringWithFormat:@"%@:%@", entry.bundleId, entry.folder]];
        }
        [group setObject:nativeOrder forKey:@"LCCustomSortOrder"];
    }
}
- (BOOL)collectionView:(UICollectionView *)collectionView canMoveItemAtIndexPath:(NSIndexPath *)indexPath {
    return self.search.text.length == 0;
}
- (void)collectionView:(UICollectionView *)collectionView moveItemAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (self.search.text.length) return;
    NSMutableArray<LGEntry *> *items = [self.filtered mutableCopy];
    if ((NSUInteger)sourceIndexPath.item >= items.count) return;
    LGEntry *entry = items[sourceIndexPath.item];
    [items removeObjectAtIndex:sourceIndexPath.item];
    NSUInteger destination = MIN((NSUInteger)destinationIndexPath.item, items.count);
    [items insertObject:entry atIndex:destination];
    self.filtered = items;
    [self saveOrder];
}

#pragma mark - Hidden apps unlock

- (void)footerTapped:(UITapGestureRecognizer *)gesture {
    if (self.hiddenUnlocked) return;
    LAContext *context = [LAContext new];
    NSError *error = nil;
    if (![context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        if (error.code == LAErrorPasscodeNotSet) {
            [self setHiddenUnlocked:YES];
        } else {
            [self showAlertTitle:@"无法解锁隐藏应用" message:@"此设备没有可用的面容 ID 或密码。"];
        }
        return;
    }
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:@"解锁隐藏应用" reply:^(BOOL success, NSError *authError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success || authError.code == LAErrorPasscodeNotSet) {
                [self setHiddenUnlocked:YES];
            } else if (authError.code != LAErrorUserCancel && authError.code != LAErrorSystemCancel) {
                [self showAlertTitle:@"解锁失败" message:authError.localizedDescription ?: @"认证未通过。"];
            }
        });
    }];
}
- (void)dealloc {
    if (self.nativeSearchObserver) [NSNotificationCenter.defaultCenter removeObserver:self.nativeSearchObserver];
    [self.navTapGuard.view removeGestureRecognizer:self.navTapGuard];
    // Never leave the host with a hidden search bar.
    [self lgSuppressNativeSearch:NO];
    [self lgFreezeHostContent:NO];
}
- (void)setHiddenUnlocked:(BOOL)unlocked {
    _hiddenUnlocked = unlocked;
    [self refresh];
    LGLog(@"Hidden apps unlocked for this session");
}

#pragma mark - Host search suppression / navigation guard

// LiveContainer's searchable sits in the navigation area. A double tap up there
// wakes it and its presentation covers our own search field, so the grid loses both
// its search bar and the space it occupied. Hiding the bar removes the entry point;
// the original state is restored in native mode.
- (void)lgSuppressNativeSearch:(BOOL)suppress {
    if (suppress) {
        UIWindow *window = self.view.window;
        if (!window) return;
        NSMutableArray<UIView *> *bars = [NSMutableArray array];
        LGCollectSearchBars(window.rootViewController.view, self.view, bars);
        BOOL changed = NO;
        for (UIView *bar in bars) {
            if (bar.hidden && !bar.userInteractionEnabled) continue;
            [self.suppressedSearchViews addObject:bar];
            bar.hidden = YES;
            bar.userInteractionEnabled = NO;
            changed = YES;
        }
        // The native field no longer reserves space at the top, so our own header has
        // to move up; without this the grid keeps the old offset for a frame.
        if (changed) [self.view setNeedsLayout];
    } else {
        for (UIView *bar in self.suppressedSearchViews.allObjects) {
            bar.hidden = NO;
            bar.userInteractionEnabled = YES;
        }
        if (self.suppressedSearchViews.count > 0) [self.view setNeedsLayout];
        [self.suppressedSearchViews removeAllObjects];
    }
}

// Swallow double taps in the host navigation area. Buttons are excluded so ➕ / ❓ /
// 🔗 / 排序 keep their single-tap behaviour; the guard only eats taps that land on
// blank navigation chrome.
- (void)lgEnsureNavGuard {
    if (self.nativeMode) return;
    UIView *navView = self.navigationController.view;
    if (!navView) return;
    if (self.navTapGuard.view == navView) return;
    [self.navTapGuard.view removeGestureRecognizer:self.navTapGuard];
    self.navTapGuard = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(lgNavTapGuardFired:)];
    self.navTapGuard.numberOfTapsRequired = 2;
    self.navTapGuard.cancelsTouchesInView = YES;
    self.navTapGuard.delegate = self;
    [navView addGestureRecognizer:self.navTapGuard];
    [self lgAdoptHostDoubleTaps:navView];
}

// cancelsTouchesInView only stops touch delivery, not another recognizer from
// recognising. Making the host's own double taps wait for ours is what actually
// keeps LiveContainer's searchable from firing.
- (void)lgAdoptHostDoubleTaps:(UIView *)root {
    if (!self.navTapGuard) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0, adopted = 0;
    while (stack.count > 0 && visited < 500) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        visited++;
        for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
            if (gesture == self.navTapGuard) continue;
            if (![gesture isKindOfClass:UITapGestureRecognizer.class]) continue;
            if (((UITapGestureRecognizer *)gesture).numberOfTapsRequired < 2) continue;
            if ([self.adoptedGestures containsObject:gesture]) continue;
            @try { [gesture requireGestureRecognizerToFail:self.navTapGuard]; } @catch (__unused NSException *e) { continue; }
            [self.adoptedGestures addObject:gesture];
            adopted++;
        }
        [stack addObjectsFromArray:view.subviews];
    }
    // Only new adoptions are worth a line, and only once per session: the rescan runs
    // twice a second and used to print forever.
    if (adopted > 0 && !self.loggedNavAdoption) {
        self.loggedNavAdoption = YES;
        LGLog([NSString stringWithFormat:@"Nav guard adopted %lu host double tap(s)", (unsigned long)adopted]);
    }
}

// The expanded-search state is not a navigation-bar gesture: LiveContainer's own
// list reacts to a double tap / scroll-to-top and asks the search field to reveal,
// which grows the navigation bar and pushes everything down. Our overlay sits on
// top of that list, so the only reliable fix is to take the list's input away while
// the grid is showing. Everything recorded here is restored when the grid hides.
- (void)lgFreezeHostContent:(BOOL)freeze {
    UIView *host = self.view.superview;
    if (!host) return;
    if (freeze) {
        for (UIView *sub in host.subviews) {
            if (sub == self.view) continue;          // never touch our own overlay
            if (!sub.userInteractionEnabled) continue;
            [self.hostDisabledViews addObject:sub];
            sub.userInteractionEnabled = NO;
            [self lgFreezeScrollViewsIn:sub];
        }
        for (UIGestureRecognizer *gesture in host.gestureRecognizers) {
            if (!gesture.enabled) continue;
            [self.hostDisabledGestures addObject:gesture];
            gesture.enabled = NO;
        }
    } else {
        for (UIView *view in self.hostDisabledViews.allObjects) view.userInteractionEnabled = YES;
        for (UIGestureRecognizer *gesture in self.hostDisabledGestures.allObjects) gesture.enabled = YES;
        for (UIScrollView *scroll in self.hostFrozenScrollViews.allObjects) scroll.scrollsToTop = YES;
        [self.hostDisabledViews removeAllObjects];
        [self.hostDisabledGestures removeAllObjects];
        [self.hostFrozenScrollViews removeAllObjects];
    }
}

// `scrollsToTop` is a separate system path: it can scroll the list even when the
// view does not receive the touch itself, and scrolling to the top is exactly what
// reveals the native search field.
- (void)lgFreezeScrollViewsIn:(UIView *)root {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (stack.count > 0 && visited < 400) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        visited++;
        if ([view isKindOfClass:UIScrollView.class] && ((UIScrollView *)view).scrollsToTop) {
            UIScrollView *scroll = (UIScrollView *)view;
            [self.hostFrozenScrollViews addObject:scroll];
            scroll.scrollsToTop = NO;
        }
        [stack addObjectsFromArray:view.subviews];
    }
}

// Second layer: if the search UI still went active (SwiftUI can drive it without a
// recognizer we can see), collapse it right away instead of leaving a blank sheet
// covering the grid.
- (void)lgCollapseHostSearchIfNeeded {
    UINavigationController *nav = self.navigationController;
    if (!nav) return;
    UINavigationItem *item = nav.topViewController.navigationItem ?: self.parentViewController.navigationItem;
    if (@available(iOS 13.0, *)) {
        UISearchController *search = item.searchController;
        if (search && search.isActive) {
            search.active = NO;
            LGLog(@"Collapsed an activated host search");
        }
    }
}
- (void)lgNavTapGuardFired:(UITapGestureRecognizer *)gesture {
    LGLog(@"Swallowed a double tap in the host navigation area");
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == self.longPress) {
        // The close badge is a button inside the cell; long pressing it must not start a
        // drag or open the cell menu.
        UIView *view = touch.view;
        if ([view isKindOfClass:UIButton.class] || [view.superview isKindOfClass:UIButton.class]) return NO;
        return YES;
    }
    if (gestureRecognizer != self.navTapGuard) return YES;
    return !LGIsControlLike(touch.view);
}

- (void)mirrorNativeSearchText:(id)object {
    if (![object isKindOfClass:UITextField.class] || self.nativeMode) return;
    UITextField *field = (UITextField *)object;
    if ([field isDescendantOfView:self.view]) return;  // our own search bar
    if (![NSStringFromClass(field.class) containsString:@"Search"]) return;
    if (!self.search.hidden) return;                   // native field is not the visible one
    NSString *text = field.text ?: @"";
    if ([self.search.text isEqualToString:text]) return;
    self.search.text = text;
    [self filter];
}
- (void)showSettings {
    if (self.presentedViewController) return;
    LGSheetController *sheet = [LGSheetController new];
    sheet.nativeMode = self.nativeMode;
    sheet.summary = self.nativeMode
        ? @"原生列表模式下，网格设置暂不可用"
        : [NSString stringWithFormat:@"共 %lu 个应用 · 隐藏 %lu · 冲突 %lu · 异常 %lu",
           (unsigned long)self.entries.count,
           (unsigned long)LGCountHidden,
           (unsigned long)LGCountAmbiguous,
           (unsigned long)LGCountDamaged];
    sheet.columns = [NSUserDefaults.standardUserDefaults integerForKey:LGColumns];
    sheet.showNames = [NSUserDefaults.standardUserDefaults boolForKey:LGNames];
    sheet.compactTop = [NSUserDefaults.standardUserDefaults boolForKey:LGCompactTop];
    sheet.hasBackground = self.backgroundView.image != nil;
    __weak typeof(self) weakSelf = self;
    sheet.handler = ^(LGSheetAction action) { [weakSelf handleSheetAction:action]; };
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *presentation = sheet.sheetPresentationController;
        presentation.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                                 UISheetPresentationControllerDetent.largeDetent];
        presentation.prefersGrabberVisible = YES;
        presentation.preferredCornerRadius = 24;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)handleSheetAction:(LGSheetAction)action {
    switch (action) {
        case LGSheetActionColumns4:
        case LGSheetActionColumns5: {
            NSInteger columns = (action == LGSheetActionColumns4) ? 4 : 5;
            [NSUserDefaults.standardUserDefaults setInteger:columns forKey:LGColumns];
            [self.collection.collectionViewLayout invalidateLayout];
            [self.collection reloadData];
            break;
        }
        case LGSheetActionToggleNames: {
            BOOL names = [NSUserDefaults.standardUserDefaults boolForKey:LGNames];
            [NSUserDefaults.standardUserDefaults setBool:!names forKey:LGNames];
            [self.collection.collectionViewLayout invalidateLayout];
            [self.collection reloadData];
            break;
        }
        case LGSheetActionToggleCompact: {
            BOOL compact = [NSUserDefaults.standardUserDefaults boolForKey:LGCompactTop];
            [NSUserDefaults.standardUserDefaults setBool:!compact forKey:LGCompactTop];
            [self.view setNeedsLayout];
            break;
        }
        case LGSheetActionChooseBackground:
        case LGSheetActionRemoveBackground:
        case LGSheetActionExportLog: {
            // The sheet is dismissing; give UIKit a beat before presenting the
            // picker or the share sheet on top of it. The braces are required:
            // a block literal inside a case would otherwise be skipped by the
            // jumps to later case labels (error: cannot jump to this case label).
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (action == LGSheetActionChooseBackground) [self chooseBackground];
                else if (action == LGSheetActionRemoveBackground) [self removeBackground];
                else [self exportLog];
            });
            break;
        }
        case LGSheetActionSwitchMode:
            [self showNative];
            break;
        case LGSheetActionSwitchToGrid:
            [self showGrid];
            break;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) [self.collection reloadData];
}
@end

static const void *LGOverlayKey = &LGOverlayKey;
static NSHashTable<LGGridController *> *LGOverlays;

// Only the tab bar controller knows a tab change is happening. Polling it means the
// grid comes back up to one tick late, which reads as a flash of the native list;
// hooking the setter puts the panel back in the same runloop turn, before the frame
// is composited. Lives on the concrete SwiftUI subclass when it exists, because that
// subclass overrides the setters and would never reach a hook on the base class.
static void LGRefreshAllTabVisibility(void) {
    for (LGGridController *grid in LGOverlays) [grid lgUpdateTabVisibilityForce:YES];
}

static BOOL LGTabHookInstalled = NO;
static NSInteger LGTabHookAttempts = 0;
static IMP LGOriginalSelectIndex;
static IMP LGOriginalSelectController;

static void LGInstallTabSwitchHook(void) {
    // Bounded retries: the class does not exist during the dyld constructor, and
    // hooking the base class is pointless when the subclass overrides the setters.
    if (LGTabHookInstalled || LGTabHookAttempts > 30) return;
    LGTabHookAttempts++;
    Class cls = NSClassFromString(@"SwiftUI.UIKitTabBarController");
    if (!cls) return;
    BOOL hooked = NO;
    SEL indexSel = @selector(setSelectedIndex:);
    Method indexMethod = class_getInstanceMethod(cls, indexSel);
    if (indexMethod) {
        IMP replacement = imp_implementationWithBlock(^(UITabBarController *tab, NSUInteger index) {
            if (LGOriginalSelectIndex) ((void (*)(id, SEL, NSUInteger))LGOriginalSelectIndex)(tab, indexSel, index);
            LGRefreshAllTabVisibility();
        });
        IMP previous = method_setImplementation(indexMethod, replacement);
        if (previous) { LGOriginalSelectIndex = previous; hooked = YES; }
    }
    SEL controllerSel = @selector(setSelectedViewController:);
    Method controllerMethod = class_getInstanceMethod(cls, controllerSel);
    if (controllerMethod) {
        IMP replacement = imp_implementationWithBlock(^(UITabBarController *tab, UIViewController *controller) {
            if (LGOriginalSelectController) ((void (*)(id, SEL, id))LGOriginalSelectController)(tab, controllerSel, controller);
            LGRefreshAllTabVisibility();
        });
        IMP previous = method_setImplementation(controllerMethod, replacement);
        if (previous) { LGOriginalSelectController = previous; hooked = YES; }
    }
    LGTabHookInstalled = hooked;
}

static NSString *LGTitle(void) {
    // Called on every layout pass by the appearance hook, so resolve it once.
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = LGGet(NSUserDefaults.class, @"lcMainBundle");
        cached = [bundle localizedStringForKey:@"lc.appList.myApps" value:@"My Apps" table:nil];
    });
    return cached;
}
static UIViewController *LGFindList(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded || !vc.view.window || vc.view.hidden) return nil;
    if ([vc isKindOfClass:LGGridController.class]) return nil;
    if ([vc isKindOfClass:UITabBarController.class]) return LGFindList(((UITabBarController *)vc).selectedViewController);
    if ([vc isKindOfClass:UINavigationController.class]) {
        UINavigationController *nav = (id)vc;
        UIViewController *top = nav.topViewController;
        // Do not cover pushed management screens or unknown SwiftUI hierarchies.
        NSString *title = top.navigationItem.title ?: nav.navigationBar.topItem.title;
        NSString *hostingClass = NSStringFromClass(top.class);
        BOOL isHosting = [hostingClass containsString:@"HostingController"];
        BOOL titleMatches = [title isEqualToString:LGTitle()] || title.length == 0;
        if (nav.viewControllers.count == 1 && isHosting && titleMatches) return top;
        return nil;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = LGFindList(child);
        if (found) return found;
    }
    return nil;
}

// Re-entrancy guard for the synchronous layout below: forcing layout inside a
// layout callback would recurse.
static BOOL LGForcingLayout = NO;

// A replaced overlay used to be dropped by clearing the association only. The host
// still retained it as a child view controller, so every SwiftUI rebuild left another
// live grid laying itself out (and logging) behind the current one. Detach it fully.
static void LGDetachOverlay(LGGridController *grid) {
    if (!grid) return;
    [grid willMoveToParentViewController:nil];
    [grid.view removeFromSuperview];
    [grid removeFromParentViewController];
    [LGOverlays removeObject:grid];
}

// Mounting is shared by the polling tick and by the UIKit appearance hooks. The
// hooks are the ones that matter on cold start: they run before the host page is
// composited, so the grid is already in place for the very first frame.
static LGGridController *LGMountOverlay(UIViewController *host) {
    if (!host || !host.view) return nil;
    LGGridController *grid = objc_getAssociatedObject(host, LGOverlayKey);
    if (grid && grid.view.superview == host.view) return grid;
    if (grid) {
        LGDetachOverlay(grid);
        objc_setAssociatedObject(host, LGOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    grid = [LGGridController new];
    [host addChildViewController:grid];
    grid.view.translatesAutoresizingMaskIntoConstraints = NO;
    [host.view addSubview:grid.view];
    // Cover the host view edge to edge: the native list may extend under the
    // translucent tab bar, and leaving that strip uncovered leaks the unmodified
    // rows through the glass. Content is inset by safeAreaInsets inside
    // LGGridController instead.
    [NSLayoutConstraint activateConstraints:@[
        [grid.view.leadingAnchor constraintEqualToAnchor:host.view.leadingAnchor],
        [grid.view.trailingAnchor constraintEqualToAnchor:host.view.trailingAnchor],
        [grid.view.topAnchor constraintEqualToAnchor:host.view.topAnchor],
        [grid.view.bottomAnchor constraintEqualToAnchor:host.view.bottomAnchor]
    ]];
    [grid didMoveToParentViewController:host];
    objc_setAssociatedObject(host, LGOverlayKey, grid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!LGOverlays) LGOverlays = [NSHashTable weakObjectsHashTable];
    [LGOverlays addObject:grid];
    // The overlay's own frames are only computed in viewDidLayoutSubviews. Mounting
    // from a timer callback does not schedule one before the frame is composited,
    // which left the first frame as an empty transparent overlay — the native list
    // showing straight through. Lay out synchronously while the host still has a
    // size; skip it during a layout callback, where it would recurse.
    if (!LGForcingLayout && !CGSizeEqualToSize(host.view.bounds.size, CGSizeZero)) {
        LGForcingLayout = YES;
        [host.view layoutIfNeeded];
        LGForcingLayout = NO;
    }
    // LC may still be loading its own list when the page first appears — the hook
    // fires earlier than the old timer did. Only a scan that came back empty is
    // worth repeating; reloading on every mount would make the icons blink.
    if (grid.entries.count == 0) {
        __weak LGGridController *weakGrid = grid;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakGrid refresh];
        });
    }
    LGLog([NSString stringWithFormat:@"Mounted on native app-list hosting controller after %.0f ms (safe.top=%.1f navBottom=%.1f)",
           (CFAbsoluteTimeGetCurrent() - LGStartTime) * 1000.0,
           host.view.safeAreaInsets.top, [grid lgTopInset]]);
    return grid;
}

// Same shape test as LGFindList, minus the on-screen requirement: the appearance
// hooks fire before the page has a window, which is exactly the point.
static BOOL LGIsAppListHost(UIViewController *vc) {
    if (!vc || [vc isKindOfClass:LGGridController.class]) return NO;
    if (!strstr(class_getName(vc.class), "HostingController")) return NO;
    UINavigationController *nav = vc.navigationController;
    if (!nav || nav.viewControllers.count != 1 || nav.topViewController != vc) return NO;
    // Never claim a background tab: its page is built ahead of time and would get
    // a grid that belongs to another screen.
    UIViewController *child = vc;
    UIViewController *parent = vc.parentViewController;
    while (parent) {
        if ([parent isKindOfClass:UITabBarController.class]) {
            if (((UITabBarController *)parent).selectedViewController != child) return NO;
            break;
        }
        child = parent;
        parent = parent.parentViewController;
    }
    NSString *title = vc.navigationItem.title ?: nav.navigationBar.topItem.title;
    return title.length == 0 || [title isEqualToString:LGTitle()];
}

static void LGDumpController(UIViewController *vc, NSUInteger depth, NSMutableString *out) {
    if (!vc || depth > 6 || out.length > 1600) return;
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    NSString *title = vc.navigationItem.title ?: vc.title;
    [out appendFormat:@"%@%@%@%@\n", indent, NSStringFromClass(vc.class),
        vc.isViewLoaded ? (vc.view.window ? @" [on-screen]" : @" [loaded]") : @" [no-view]",
        title.length ? [NSString stringWithFormat:@" \"%@\"", title] : @""];
    for (UIViewController *child in vc.childViewControllers) LGDumpController(child, depth + 1, out);
}
static void LGDumpWindows(void) {
    NSMutableString *out = [NSMutableString string];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha == 0) continue;
            [out appendFormat:@"window level=%.1f root=%@\n", window.windowLevel, NSStringFromClass(window.rootViewController.class)];
            LGDumpController(window.rootViewController, 1, out);
        }
    }
    // Classes/titles only: no app names, bundle ids or container paths.
    LGLog([NSString stringWithFormat:@"No host matched after 6s; view hierarchy:\n%@", out]);
}

static void LGTick(void) {
    // The tab bar controller class may not exist yet during the dyld constructor.
    if (!LGTabHookInstalled) LGInstallTabSwitchHook();
    static BOOL loggedTabHook = NO;
    if (LGTabHookInstalled && !loggedTabHook) {
        loggedTabHook = YES;
        LGLog(@"Tab switch hook active (setSelectedIndex / setSelectedViewController)");
    }
    // Inactive is normal during the launch animation; only skip when backgrounded.
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    static BOOL loggedFirstTick = NO;
    if (!loggedFirstTick) {
        loggedFirstTick = YES;
        LGLog([NSString stringWithFormat:@"First tick after %.0f ms (appState=%ld)",
               (CFAbsoluteTimeGetCurrent() - LGStartTime) * 1000.0,
               (long)UIApplication.sharedApplication.applicationState]);
    }
    NSHashTable *active = [NSHashTable weakObjectsHashTable];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState == UISceneActivationStateUnattached || scene.activationState == UISceneActivationStateBackground) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha == 0 || window.windowLevel != UIWindowLevelNormal) continue;
            UIViewController *host = LGFindList(window.rootViewController);
            if (!host) continue;
            LGGridController *grid = objc_getAssociatedObject(host, LGOverlayKey);
            if (grid && grid.view.superview != host.view) {
                // SwiftUI rebuilt the page view under us; drop the stale overlay so
                // it is mounted fresh below instead of silently doing nothing.
                LGDetachOverlay(grid);
                objc_setAssociatedObject(host, LGOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                grid = nil;
            }
            if (grid) {
                // SwiftUI re-inserts its own content when a tab comes back; without
                // this the native list paints above our overlay until the next tick.
                if (host.view.subviews.lastObject != grid.view) [host.view bringSubviewToFront:grid.view];
                [active addObject:grid];
                continue;
            }
            grid = LGMountOverlay(host);
            if (grid) [active addObject:grid];
        }
    }
    for (LGGridController *grid in LGOverlays) {
        // Independent of `active`: when SwiftUI swaps tab containers the host page can
        // drop out of the window entirely, and this is the only thing that brings the
        // overlay back when the Apps tab returns.
        [grid lgUpdateTabVisibility];
        // Never hide the overlay while the host page is off-screen (tab switch,
        // pushed sheet): the view is simply not visible then, and hiding it makes
        // the native list flash for up to one tick when the user comes back.
        if ([active containsObject:grid]) {
            if (grid.wasAway) {
                grid.wasAway = NO;
                // One missed tick is normal while SwiftUI swaps its hierarchy; only a
                // real absence is worth a rescan. Without this guard the list reloaded
                // and logged "Loaded N app(s)" several times a second.
                if (grid.awaySince > 0 && CFAbsoluteTimeGetCurrent() - grid.awaySince > 0.4) [grid refresh];
                grid.awaySince = 0;
            }
            [grid lgSyncLayout];
        } else if (!grid.wasAway) {
            grid.wasAway = YES;
            grid.awaySince = CFAbsoluteTimeGetCurrent();
        }
    }
    static CFTimeInterval idleSince = 0;
    static BOOL dumpedHierarchy = NO;
    if (LGOverlays.count == 0) {
        if (idleSince == 0) idleSince = CFAbsoluteTimeGetCurrent();
        if (!dumpedHierarchy && CFAbsoluteTimeGetCurrent() - idleSince > 6) {
            dumpedHierarchy = YES;
            LGDumpWindows();
        }
    } else {
        idleSince = 0;
    }
}

#pragma mark - Appearance hooks (system level)

// Cold start used to depend on the 16ms timer, so the host page could be
// composited once with the native list before the overlay landed. These two UIKit
// callbacks both run inside the pass that produces that frame: viewWillAppear:
// precedes the first layout, and viewDidLayoutSubviews: happens while the frame is
// being laid out. Mounting there makes the overlay part of the frame that gets
// drawn instead of the frame after it.
@interface UIViewController (LCGridEarlyMount)
- (void)lg_earlyViewWillAppear:(BOOL)animated;
- (void)lg_earlyViewDidLayoutSubviews;
@end

@implementation UIViewController (LCGridEarlyMount)
- (void)lg_earlyViewWillAppear:(BOOL)animated {
    [self lg_earlyViewWillAppear:animated];   // original IMP after the exchange
    if (LGIsAppListHost(self)) LGMountOverlay(self);
}
- (void)lg_earlyViewDidLayoutSubviews {
    [self lg_earlyViewDidLayoutSubviews];
    if (!LGForcingLayout && LGIsAppListHost(self)) LGMountOverlay(self);
}
@end

static BOOL LGWillAppearHooked = NO;
static BOOL LGDidLayoutHooked = NO;

static void LGInstallAppearanceHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    Class cls = UIViewController.class;
    Method will = class_getInstanceMethod(cls, @selector(viewWillAppear:));
    Method mineWill = class_getInstanceMethod(cls, @selector(lg_earlyViewWillAppear:));
    Method layout = class_getInstanceMethod(cls, @selector(viewDidLayoutSubviews));
    Method mineLayout = class_getInstanceMethod(cls, @selector(lg_earlyViewDidLayoutSubviews));
    if (will && mineWill) {
        method_exchangeImplementations(will, mineWill);
        LGWillAppearHooked = YES;
    }
    // Never invent the method when the original is missing: the replacement calls
    // itself through that selector, so it would recurse forever.
    if (layout && mineLayout) {
        method_exchangeImplementations(layout, mineLayout);
        LGDidLayoutHooked = YES;
    }
    // Logging is deferred to the first main-queue turn: this runs inside a dyld
    // constructor, where file IO through NSFileManager is best left alone.
}

__attribute__((constructor)) static void LGInitialize(void) {
    @autoreleasepool {
        if (!LGHost()) return;
        // Everything the hooks touch must exist before the first UI callback, so it
        // is set up synchronously here rather than on the next main-queue turn.
        LGOverlays = [NSHashTable weakObjectsHashTable];
        LGStartTime = CFAbsoluteTimeGetCurrent();
        [NSUserDefaults.standardUserDefaults registerDefaults:@{LGColumns:@4, LGNames:@YES, LGNative:@NO, LGCompactTop:@YES}];
        LGInstallAppearanceHooks();
        LGInstallTabSwitchHook();
        dispatch_async(dispatch_get_main_queue(), ^{
            // Start every launch with a clean log. LGLog appends and only rewrites past
            // 128 KB, so old processes' lines used to pile up and the exported file was
            // mostly history. One session per file is what the export button implies.
            [NSFileManager.defaultManager removeItemAtPath:LGLogPath() error:nil];
            LGLog([NSString stringWithFormat:@"Host gate passed: LiveContainer %@ (>= 3.8.0); %@ loaded; hooks viewWillAppear=%d viewDidLayoutSubviews=%d",
                   LGDetectedVersion ?: @"?", LGLoadedName(), LGWillAppearHooked, LGDidLayoutHooked]);
            // Polling is now only a safety net: the appearance hooks do the real
            // mount before the first frame. The tick still matters for pages that
            // never go through viewWillAppear (SwiftUI rebuilding the page under a
            // live overlay) and for keeping the badge state fresh.
            // 0.1s discovery: a 1s poll is what made returning to the App tab show
            // the native list for about a second before the grid reappeared.
            NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) { LGTick(); }];
            timer.tolerance = 0.03;
            // Startup burst: poll at 30ms for the first 1.2s so the overlay lands on
            // the host page within one frame instead of one 100ms tick. It stops as
            // soon as the burst window ends; the steady 0.1s timer takes over.
            LGTick();
            // 16ms = one frame. The native list paints once before the overlay
            // mounts, and this burst is what shortens that flash; going lower only
            // burns CPU, since the host view does not exist until SwiftUI builds it.
            [NSTimer scheduledTimerWithTimeInterval:0.016 repeats:YES block:^(NSTimer *burstTimer) {
                LGTick();
                if (CFAbsoluteTimeGetCurrent() - LGStartTime > 1.6) [burstTimer invalidate];
            }];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                LGTick();
                // Pick up apps installed/removed while the host was in background.
                for (LGGridController *grid in LGOverlays) [grid refresh];
            }];
        });
    }
}

#pragma mark - Settings sheet implementation

@implementation LGSheetController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UIScrollView *scroll = [UIScrollView new];
    scroll.alwaysBounceVertical = YES;
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *root = [UIStackView new];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 16;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [root.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:10],
        [root.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [root.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [root.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [root.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];

    [root addArrangedSubview:[self headerView]];

    UILabel *summary = [UILabel new];
    summary.text = self.summary;
    summary.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    summary.textColor = UIColor.secondaryLabelColor;
    summary.numberOfLines = 0;
    summary.adjustsFontForContentSizeCategory = YES;
    [root addArrangedSubview:summary];
    [root setCustomSpacing:6 afterView:summary];

    if (self.nativeMode) {
        [self buildNativeBranchInRoot:root];
        return;
    }

    UISegmentedControl *columns = [[UISegmentedControl alloc] initWithItems:@[@"4 列", @"5 列"]];
    columns.selectedSegmentIndex = self.columns == 5 ? 1 : 0;
    [columns addTarget:self action:@selector(columnsChanged:) forControlEvents:UIControlEventValueChanged];
    [columns.widthAnchor constraintEqualToConstant:150].active = YES;
    [root addArrangedSubview:[self cardWithRows:@[[self rowWithTitle:@"列数" control:columns]]]];
    [root setCustomSpacing:6 afterView:root.arrangedSubviews.lastObject];

    UISwitch *names = [UISwitch new];
    names.on = self.showNames;
    [names addTarget:self action:@selector(namesChanged:) forControlEvents:UIControlEventValueChanged];
    UISegmentedControl *spacing = [[UISegmentedControl alloc] initWithItems:@[@"紧凑", @"宽松"]];
    spacing.selectedSegmentIndex = self.compactTop ? 0 : 1;
    [spacing addTarget:self action:@selector(spacingChanged:) forControlEvents:UIControlEventValueChanged];
    [spacing.widthAnchor constraintEqualToConstant:150].active = YES;
    [root addArrangedSubview:[self cardWithRows:@[
        [self rowWithTitle:@"应用名称" control:names],
        [self separator],
        [self rowWithTitle:@"顶部间距" control:spacing],
    ]]];
    [root setCustomSpacing:6 afterView:root.arrangedSubviews.lastObject];

    NSMutableArray<UIView *> *backgroundRows = [NSMutableArray array];
    [backgroundRows addObject:[self rowWithTitle:@"背景图片" control:[self pillButton:(self.hasBackground ? @"更换" : @"选择") action:@selector(chooseTapped)]]];
    if (self.hasBackground) {
        [backgroundRows addObject:[self separator]];
        UIButton *remove = [self pillButton:@"移除" action:@selector(removeTapped)];
        remove.tintColor = UIColor.systemRedColor;
        [backgroundRows addObject:[self rowWithTitle:@"恢复默认底色" control:remove]];
    }
    [root addArrangedSubview:[self cardWithRows:backgroundRows]];
    [root setCustomSpacing:6 afterView:root.arrangedSubviews.lastObject];

    // Plain row on the sheet background: no card, no separator, no shadow. It reads as
    // a secondary action, which is what it is.
    UIButton *log = [UIButton buttonWithType:UIButtonTypeSystem];
    [log setTitle:@"导出调试日志" forState:UIControlStateNormal];
    log.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    log.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [log addTarget:self action:@selector(exportTapped) forControlEvents:UIControlEventTouchUpInside];
    UIView *logRow = [UIView new];
    log.translatesAutoresizingMaskIntoConstraints = NO;
    [logRow addSubview:log];
    [NSLayoutConstraint activateConstraints:@[
        [logRow.heightAnchor constraintEqualToConstant:52],
        [log.leadingAnchor constraintEqualToAnchor:logRow.leadingAnchor constant:16],
        [log.trailingAnchor constraintEqualToAnchor:logRow.trailingAnchor],
        [log.centerYAnchor constraintEqualToAnchor:logRow.centerYAnchor],
    ]];
    [root addArrangedSubview:logRow];
    [root setCustomSpacing:20 afterView:logRow];

    UIButton *switchMode = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = @"切换到原生列表";
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    switchMode.configuration = config;
    [switchMode.heightAnchor constraintEqualToConstant:50].active = YES;
    [switchMode addTarget:self action:@selector(switchTapped) forControlEvents:UIControlEventTouchUpInside];
    [root addArrangedSubview:switchMode];
}

// Native mode: one action, no grid options.
- (void)buildNativeBranchInRoot:(UIStackView *)root {
    UILabel *hint = [UILabel new];
    hint.text = @"当前显示的是原生列表。宫格布局的设置项等切回宫格后再调整。";
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    hint.textColor = UIColor.secondaryLabelColor;
    hint.numberOfLines = 0;
    hint.adjustsFontForContentSizeCategory = YES;
    [root addArrangedSubview:hint];
    [root setCustomSpacing:20 afterView:hint];

    UIButton *switchMode = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = @"切换到宫格布局";
    config.image = [UIImage systemImageNamed:@"square.grid.3x3.fill"];
    config.imagePadding = 8;
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    switchMode.configuration = config;
    [switchMode.heightAnchor constraintEqualToConstant:52].active = YES;
    [switchMode addTarget:self action:@selector(switchTapped) forControlEvents:UIControlEventTouchUpInside];
    [root addArrangedSubview:switchMode];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [root addArrangedSubview:cancel];
}

- (UIView *)headerView {
    UILabel *title = [UILabel new];
    title.text = self.nativeMode ? @"布局" : @"网格设置";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;
    [title setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = UIColor.tertiaryLabelColor;
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [close.widthAnchor constraintEqualToConstant:30].active = YES;
    [close.heightAnchor constraintEqualToConstant:30].active = YES;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[title, [UIView new], close]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (UIView *)rowWithTitle:(NSString *)title control:(UIView *)control {
    UIView *row = [UIView new];
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:label];
    [row addSubview:control];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:52],
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:control.leadingAnchor constant:-12],
        [control.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [control.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [control.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:8],
        [control.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-8],
    ]];
    return row;
}

- (UIView *)cardWithRows:(NSArray<UIView *> *)rows {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:rows];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *card = [UIView new];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 14;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
    ]];
    return card;
}

- (UIView *)separator {
    UIView *line = [UIView new];
    line.backgroundColor = UIColor.separatorColor;
    [line.heightAnchor constraintEqualToConstant:0.5].active = YES;
    return line;
}

- (UIButton *)pillButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration grayButtonConfiguration];
    config.title = title;
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.contentInsets = NSDirectionalEdgeInsetsMake(6, 14, 6, 14);
    button.configuration = config;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

// Live settings (columns/names/spacing) apply behind the sheet without closing
// it; anything that presents another controller runs after dismissal.
- (void)fire:(LGSheetAction)action dismiss:(BOOL)dismiss {
    void (^handler)(LGSheetAction) = self.handler;
    if (!dismiss) {
        if (handler) handler(action);
        return;
    }
    [self dismissViewControllerAnimated:YES completion:^{
        if (handler) handler(action);
    }];
}

- (void)closeTapped { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)columnsChanged:(UISegmentedControl *)control { [self fire:(control.selectedSegmentIndex == 0 ? LGSheetActionColumns4 : LGSheetActionColumns5) dismiss:NO]; }
- (void)namesChanged:(UISwitch *)control { [self fire:LGSheetActionToggleNames dismiss:NO]; }
- (void)spacingChanged:(UISegmentedControl *)control { [self fire:LGSheetActionToggleCompact dismiss:NO]; }
- (void)chooseTapped { [self fire:LGSheetActionChooseBackground dismiss:YES]; }
- (void)removeTapped { [self fire:LGSheetActionRemoveBackground dismiss:YES]; }
- (void)exportTapped { [self fire:LGSheetActionExportLog dismiss:YES]; }
- (void)switchTapped {
    [self fire:(self.nativeMode ? LGSheetActionSwitchToGrid : LGSheetActionSwitchMode) dismiss:YES];
}

@end

