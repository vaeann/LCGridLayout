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
    for (NSString *name in @[@"AppIcon60x60@3x.png", @"AppIcon60x60@2x.png", @"AppIcon76x76@2x~ipad.png", @"AppIcon76x76@1x~ipad.png"]) {
        UIImage *image = [UIImage imageWithContentsOfFile:[entry.url URLByAppendingPathComponent:name].path];
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

@interface LGCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *icon;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UIImageView *lock;
@property(nonatomic) BOOL showName;
@property(nonatomic) BOOL locked;
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
        [self.contentView addSubview:_icon];
        [self.contentView addSubview:_lock];
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
    _label.frame = CGRectMake(1, size+11, self.bounds.size.width-2, 18);
    _label.hidden = !self.showName;
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.contentView.alpha = highlighted ? 0.55 : 1;
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
};

// Card layout instead of the long, thin alert action sheet the settings used to
// be. Purely presentational: it reports which control was used and the grid
// controller decides what to change.
@interface LGSheetController : UIViewController
@property(nonatomic, copy) NSString *summary;
@property(nonatomic) NSInteger columns;
@property(nonatomic) BOOL showNames;
@property(nonatomic) BOOL compactTop;
@property(nonatomic) BOOL hasBackground;
@property(nonatomic, copy) void (^handler)(LGSheetAction action);
@end

// Small centred card, visually consistent with LGSheetController. Used where a
// full settings sheet would be overkill (native mode only needs one action).
@interface LGCardAlertController : UIViewController
@property(nonatomic, copy) NSString *titleText;
@property(nonatomic, copy) NSString *messageText;
@property(nonatomic, copy) NSString *confirmTitle;
@property(nonatomic, copy) void (^onConfirm)(void);
@end

@interface LGGridController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate, PHPickerViewControllerDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) UIImageView *backgroundView;
@property(nonatomic, strong) UIView *dimView;
@property(nonatomic, strong) UICollectionView *collection;
@property(nonatomic, strong) UISearchBar *search;
@property(nonatomic, strong) UILabel *empty;
@property(nonatomic, strong) NSArray<LGEntry *> *entries;
@property(nonatomic, strong) NSArray<LGEntry *> *filtered;
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *icons;
@property(nonatomic) BOOL nativeMode;
@property(nonatomic) BOOL wasAway;
@property(nonatomic) BOOL hiddenUnlocked;
@property(nonatomic) BOOL draggingCell;
@property(nonatomic) BOOL moved;
@property(nonatomic) BOOL menuShown;
@property(nonatomic) NSInteger menuToken;
@property(nonatomic, strong) UILabel *footer;
@property(nonatomic, strong) UILongPressGestureRecognizer *longPress;
// The footer counter is the settings entry: a fixed, always-visible target
// beats "long press somewhere empty".
@property(nonatomic, strong) UILongPressGestureRecognizer *footerPress;
// Native list mode: the panel is hidden, so nothing of ours can receive touches.
// This one rides on the host navigation controller's view instead.
@property(nonatomic, strong) UILongPressGestureRecognizer *hostLongPress;
// Double tap in the blank strip under the Dynamic Island — above the search
// field — switches layout after a confirmation. One recognizer serves both
// modes: it lives on the host navigation controller's view and picks the
// direction from nativeMode.
@property(nonatomic, strong) UITapGestureRecognizer *navDoubleTap;
@property(nonatomic, strong) NSIndexPath *pressIndexPath;
@property(nonatomic, strong) LGEntry *pressEntry;
@property(nonatomic) CGPoint pressStart;
@property(nonatomic) BOOL hadNativeTopSearch;
@property(nonatomic) CGFloat lastTopInset;
@property(nonatomic) UIEdgeInsets lastSafeInsets;
@property(nonatomic, strong) NSMutableSet<NSString *> *pendingIcons;
@property(nonatomic, strong) id nativeSearchObserver;
- (CGFloat)lgTopInset;
- (void)lgSyncLayout;
- (void)refresh;
- (void)lgEnsureHostPress;
- (BOOL)lgGestureAllowsTouch:(UIGestureRecognizer *)gesture;
- (void)handleHostLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)handleNavDoubleTap:(UITapGestureRecognizer *)gesture;
- (void)confirmSwitchToNative:(BOOL)toNative;
- (void)showNativeSwitchMenu;
- (void)handleSheetAction:(LGSheetAction)action;
@end

@implementation LGGridController
- (void)loadView {
    self.view = [LGPassView new];
    self.view.backgroundColor = UIColor.clearColor;
    self.icons = [NSCache new];
    self.icons.countLimit = 150;
    self.pendingIcons = [NSMutableSet new];
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
    // The top toolbar (back-to-native / grid settings) is intentionally gone:
    // both entries now live behind a long press on empty space, so the grid
    // starts right below the navigation bar.
    self.search = [UISearchBar new];
    self.search.searchBarStyle = UISearchBarStyleMinimal;
    self.search.placeholder = @"搜索应用";
    self.search.delegate = self;
    [self.panel addSubview:self.search];
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 0;
    layout.minimumLineSpacing = 16;
    layout.sectionInset = UIEdgeInsetsMake(12, 12, 28, 12);
    self.collection = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collection.backgroundColor = UIColor.clearColor;
    self.collection.alwaysBounceVertical = YES;
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
    self.longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    self.longPress.minimumPressDuration = 0.3;
    [self.collection addGestureRecognizer:self.longPress];
    // Native mode hides the panel, so nothing of ours can receive touches there.
    // This recognizer is attached to the host's navigation controller view
    // instead, covering everything under the Dynamic Island.
    self.hostLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleHostLongPress:)];
    self.hostLongPress.minimumPressDuration = 0.5;
    self.hostLongPress.delegate = self;
    self.hostLongPress.enabled = NO;
    self.navDoubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleNavDoubleTap:)];
    self.navDoubleTap.numberOfTapsRequired = 2;
    self.navDoubleTap.delegate = self;
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
    [self applyMode];
    [self loadBackground];
    [self refresh];
}
- (CGFloat)lgTopInset {
    // Sit right below the navigation bar instead of trusting safeAreaInsets, which
    // can include the large-title area and leaves a visible gap.
    UINavigationController *nav = self.navigationController;
    if (nav && !nav.navigationBarHidden && nav.navigationBar) {
        CGRect bar = [nav.navigationBar convertRect:nav.navigationBar.bounds toView:self.view];
        return MAX(0, CGRectGetMaxY(bar));
    }
    return self.view.safeAreaInsets.top;
}
// Navigation bar large-title collapse changes geometry without changing our
// bounds, so viewDidLayoutSubviews never fires and the header keeps its old
// offset (the big blank above the toolbar). Re-layout when that geometry moves.
- (void)lgSyncLayout {
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
    BOOL navHidden = self.navigationController.isNavigationBarHidden;
    // With the host bar hidden, LiveContainer's search field sits inside the
    // content area we already cover; letting it influence geometry would hide
    // our own search bar for no reason.
    CGRect nativeSearch = navHidden ? CGRectZero : [self lgTopNativeSearchFrame];
    BOOL hasNativeTopSearch = !CGRectIsEmpty(nativeSearch);
    self.search.hidden = hasNativeTopSearch;
    CGFloat top = [self lgTopInset] + 2;
    // Compact mode removes the phantom large-title inset. With the bar hidden
    // there is no large title, so the compensation must not apply.
    if (!hasNativeTopSearch && !navHidden && [NSUserDefaults.standardUserDefaults boolForKey:LGCompactTop]) top = MAX(0, top - 44);
    if (hasNativeTopSearch) top = MAX(top, CGRectGetMaxY(nativeSearch) + 4);
    self.lastTopInset = [self lgTopInset];
    self.lastSafeInsets = safe;
    self.hadNativeTopSearch = hasNativeTopSearch;
    self.panel.frame = self.view.bounds;
    self.backgroundView.frame = self.panel.bounds;
    self.dimView.frame = self.panel.bounds;
    self.search.frame = CGRectMake(4, top, MAX(0,w-8), 48);
    CGFloat footerHeight = MAX(24, self.footer.font.lineHeight + 2);
    CGFloat footerGap = 14;
    self.footer.frame = CGRectMake(0, MAX(0, h-safe.bottom-footerHeight-footerGap), w, footerHeight);
    // No toolbar row above the search field any more; the header is just the
    // search bar (or a small gap when LiveContainer's own search field is used).
    CGFloat headerHeight = hasNativeTopSearch ? 8 : 48;
    CGRect frame = CGRectMake(0, top+headerHeight, w, MAX(0, h-top-headerHeight-safe.bottom-footerHeight-footerGap-2));
    BOOL resized = !CGSizeEqualToSize(self.collection.bounds.size, frame.size);
    self.collection.frame = frame;
    [self lgEnsureHostPress];
    if (resized) [self.collection.collectionViewLayout invalidateLayout];
}
- (void)applyMode {
    self.panel.hidden = self.nativeMode;
    self.hostLongPress.enabled = self.nativeMode;
    // The host navigation bar (buttons and large title) stays visible on purpose:
    // the grid only replaces the search field and the app list below it.
    [self lgEnsureHostPress];
    [NSUserDefaults.standardUserDefaults setBool:self.nativeMode forKey:LGNative];
}

- (void)showNative { [self.view endEditing:YES]; self.nativeMode = YES; [self applyMode]; }
- (void)showGrid { self.nativeMode = NO; [self applyMode]; [self refresh]; }
- (void)refresh {
    self.entries = LGReadApps(self.hiddenUnlocked);
    // Keep the icon cache: clearing it forced every icon to be regenerated on each
    // tab switch, which is what made returning to this page stall for ~1s.
    [self filter];
    [self.collection.refreshControl endRefreshing];
    LGLog([NSString stringWithFormat:@"Loaded %lu app(s); skipped hidden=%lu ambiguous=%lu damaged=%lu",
           (unsigned long)self.entries.count, (unsigned long)LGCountHidden,
           (unsigned long)LGCountAmbiguous, (unsigned long)LGCountDamaged]);
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
        cell.icon.image = icon;
    } else {
        // First frame: use the bundle's own PNG (a few ms) instead of blocking on
        // IconServices. The themed icon is generated one per run-loop turn below.
        UIImage *fast = LGFastIcon(entry);
        cell.icon.image = fast ?: [UIImage systemImageNamed:@"app.fill"];
        [self requestIconForEntry:entry key:key];
    }
    [cell setNeedsLayout];
    return cell;
}
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)path {
    NSInteger columns = [NSUserDefaults.standardUserDefaults integerForKey:LGColumns] == 5 ? 5 : 4;
    CGFloat width = floor(MAX(0, collectionView.bounds.size.width - 24) / columns);
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
    if (index != NSNotFound) {
        [self.collection reloadItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:index inSection:0]]];
    }
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
    NSString *scheme = LGGet(NSClassFromString(@"LCUtils"), @"appUrlScheme");
    if (![scheme isKindOfClass:NSString.class] || scheme.length == 0) {
        LGLog(@"Launch refused: no native URL scheme");
        [self showError:@"LiveContainer 没有提供启动用的 URL scheme，无法从这个网格启动应用。请改用原生列表。"];
        return;
    }
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = scheme;
    components.host = @"livecontainer-launch";
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"bundle-name" value:entry.folder]];
    NSURL *url = components.URL;
    if (!url) return;
    [self.view endEditing:YES];
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        LGLog(success ? @"Native launch URL accepted (guest launch outcome not asserted)" : @"Native launch URL rejected");
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showError:@"系统拒绝了启动请求。请改用原生列表，并查看 LCGridLayout.log。"];
            });
        }
    }];
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
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:share animated:YES completion:nil];
}

#pragma mark - Empty-space long press

// Anything that already handles its own taps (buttons, list rows) must keep
// working; only genuinely blank areas should open our sheet. Walking up from
// the hit view stops at the first list, so the list's own background still
// counts as blank space.
static BOOL LGIsInteractive(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:UIControl.class]) return YES;
        if ([v isKindOfClass:UICollectionViewCell.class] || [v isKindOfClass:UITableViewCell.class]) return YES;
        if ([v isKindOfClass:UICollectionView.class] || [v isKindOfClass:UITableView.class]) return NO;
    }
    return NO;
}

- (void)lgEnsureHostPress {
    // Native mode hides our panel, so the only place left to receive gestures is
    // the host navigation controller's view. Attaching them there also covers
    // the navigation bar — the blank strip under the Dynamic Island.
    UIView *navView = self.navigationController.view;
    if (!navView) return;
    for (UIGestureRecognizer *gesture in @[self.hostLongPress, self.navDoubleTap]) {
        if (gesture.view == navView) continue;
        [gesture.view removeGestureRecognizer:gesture];
        [navView addGestureRecognizer:gesture];
    }
}

// Anything that already handles taps must keep working, and the double tap is
// only meant for the strip above the search field. Deciding this in
// shouldReceiveTouch — not shouldBegin — is what keeps a single tap on an app
// icon from being delayed while UIKit waits for a possible second tap.
- (BOOL)lgGestureAllowsTouch:(UIGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    if (!view) return NO;
    CGPoint point = [gesture locationInView:view];
    if (LGIsInteractive([view hitTest:point withEvent:nil])) return NO;
    if (gesture != self.navDoubleTap) return YES;
    if (self.nativeMode) {
        // Native list: stay below the native search field. The navigation bar
        // belongs to LiveContainer — a double tap up there opens its search.
        CGPoint inSelf = [gesture locationInView:self.view];
        return inSelf.y > [self lgTopInset] + 64;
    }
    // Grid: any blank spot in the grid. The strip above the search field is only
    // a few points tall now that the host bar is visible again, so limiting the
    // double tap to it would make the gesture practically unhittable.
    CGPoint inPanel = [gesture locationInView:self.panel];
    return inPanel.y >= 0;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == self.hostLongPress || gestureRecognizer == self.navDoubleTap) {
        return [self lgGestureAllowsTouch:gestureRecognizer];
    }
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.hostLongPress || gestureRecognizer == self.navDoubleTap) {
        return [self lgGestureAllowsTouch:gestureRecognizer];
    }
    return YES;
}

- (void)handleNavDoubleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    [self confirmSwitchToNative:!self.nativeMode];
}

- (void)confirmSwitchToNative:(BOOL)toNative {
    if (self.presentedViewController) return;
    NSString *title = toNative ? @"确定切换到原生列表吗？" : @"确定切换到网格布局吗？";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"是" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (toNative) {
            [self showNative];
        } else {
            [self showGrid];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"否" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleHostLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    [self showNativeSwitchMenu];
}

// Native mode has exactly one job: get back to the grid. Everything else in
// the settings sheet would change something the user cannot see right now.
- (void)showNativeSwitchMenu {
    if (self.presentedViewController) return;
    LGCardAlertController *card = [LGCardAlertController new];
    card.titleText = @"切换布局";
    card.messageText = @"当前显示的是原生列表";
    card.confirmTitle = @"切换到网格布局";
    card.modalPresentationStyle = UIModalPresentationOverFullScreen;
    card.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    __weak typeof(self) weakSelf = self;
    card.onConfirm = ^{ [weakSelf showGrid]; };
    [self presentViewController:card animated:YES completion:nil];
}

#pragma mark - Long-press actions (hide / uninstall / reorder)

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:self.collection];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            NSIndexPath *indexPath = [self.collection indexPathForItemAtPoint:point];
            BOOL onCell = indexPath && indexPath.item < (NSInteger)self.filtered.count;
            // Empty space opens the settings sheet; a real cell keeps the
            // existing drag-reorder / hide / uninstall behaviour.
            self.pressIndexPath = onCell ? indexPath : nil;
            self.pressEntry = onCell ? self.filtered[indexPath.item] : nil;
            self.pressStart = point;
            self.moved = NO;
            self.menuShown = NO;
            self.draggingCell = NO;
            if (onCell) {
                UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                [haptic impactOccurred];
            }
            // Keep holding still: the menu shows without waiting for the finger to lift.
            NSInteger token = ++self.menuToken;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!weakSelf || weakSelf.menuToken != token || weakSelf.moved || weakSelf.menuShown) return;
                weakSelf.menuShown = YES;
                if (weakSelf.pressEntry) {
                    UICollectionViewCell *cell = [weakSelf.collection cellForItemAtIndexPath:weakSelf.pressIndexPath];
                    [weakSelf showActionsForEntry:weakSelf.pressEntry cell:cell];
                } else {
                    [weakSelf showSettings];
                }
            });
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (self.menuShown) return;
            CGFloat dx = point.x - self.pressStart.x;
            CGFloat dy = point.y - self.pressStart.y;
            if (!self.moved && sqrt(dx * dx + dy * dy) > 6) {
                self.moved = YES;
                self.menuToken++;  // cancels the pending menu
                if (self.pressEntry) {
                    self.draggingCell = YES;
                    [self.collection beginInteractiveMovementForItemAtIndexPath:self.pressIndexPath];
                    UIImpactFeedbackGenerator *dragHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                    [dragHaptic impactOccurred];
                }
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
            } else if (!self.menuShown) {
                // Quick release before the timer: still show the menu.
                if (self.pressEntry) {
                    UICollectionViewCell *cell = [self.collection cellForItemAtIndexPath:self.pressIndexPath];
                    [self showActionsForEntry:self.pressEntry cell:cell];
                } else {
                    [self showSettings];
                }
            }
            self.pressEntry = nil;
            self.pressIndexPath = nil;
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
    // The recognizers live on the host's view, which outlives us.
    [self.hostLongPress.view removeGestureRecognizer:self.hostLongPress];
    [self.navDoubleTap.view removeGestureRecognizer:self.navDoubleTap];
}
- (void)setHiddenUnlocked:(BOOL)unlocked {
    _hiddenUnlocked = unlocked;
    [self refresh];
    LGLog(@"Hidden apps unlocked for this session");
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
    sheet.summary = [NSString stringWithFormat:@"共 %lu 个应用 · 隐藏 %lu · 冲突 %lu · 异常 %lu",
                     (unsigned long)self.entries.count,
                     (unsigned long)LGCountHidden,
                     (unsigned long)LGCountAmbiguous,
                     (unsigned long)LGCountDamaged];
    sheet.columns = [NSUserDefaults.standardUserDefaults integerForKey:LGColumns];
    sheet.showNames = [NSUserDefaults.standardUserDefaults boolForKey:LGNames];
    sheet.compactTop = [NSUserDefaults.standardUserDefaults boolForKey:LGCompactTop];
    sheet.hasBackground = self.backgroundView.image != nil;
    __weak typeof(self) weakSelf = self;
    sheet.handler = ^(LGSheetAction action) {
        [weakSelf handleSheetAction:action];
    };
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
            // The sheet has just been dismissed; give UIKit a beat before
            // presenting the picker or the share sheet on top of it.
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
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) [self.collection reloadData];
}
@end

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
    UIButton *choose = [self pillButton:(self.hasBackground ? @"更换" : @"选择") action:@selector(chooseTapped)];
    [backgroundRows addObject:[self rowWithTitle:@"背景图片" control:choose]];
    if (self.hasBackground) {
        [backgroundRows addObject:[self separator]];
        UIButton *remove = [self pillButton:@"移除" action:@selector(removeTapped)];
        remove.tintColor = UIColor.systemRedColor;
        [backgroundRows addObject:[self rowWithTitle:@"恢复默认底色" control:remove]];
    }
    [root addArrangedSubview:[self cardWithRows:backgroundRows]];
    [root setCustomSpacing:6 afterView:root.arrangedSubviews.lastObject];

    UIButton *log = [UIButton buttonWithType:UIButtonTypeSystem];
    [log setTitle:@"导出调试日志" forState:UIControlStateNormal];
    log.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    log.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [log addTarget:self action:@selector(exportTapped) forControlEvents:UIControlEventTouchUpInside];
    [log.heightAnchor constraintEqualToConstant:52].active = YES;
    [root addArrangedSubview:[self cardWithRows:@[log]]];
    [root setCustomSpacing:20 afterView:root.arrangedSubviews.lastObject];

    UIButton *switchMode = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = @"切换到原生列表";
    config.baseBackgroundColor = UIColor.labelColor;
    config.baseForegroundColor = UIColor.systemBackgroundColor;
    config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    switchMode.configuration = config;
    [switchMode.heightAnchor constraintEqualToConstant:50].active = YES;
    [switchMode addTarget:self action:@selector(switchTapped) forControlEvents:UIControlEventTouchUpInside];
    [root addArrangedSubview:switchMode];
}

- (UIView *)headerView {
    UILabel *title = [UILabel new];
    title.text = @"网格设置";
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

// Settings that are visible behind the sheet apply immediately and keep it
// open, so the effect can be judged without reopening. Everything that leaves
// the grid (picker, share sheet, mode switch) runs after the dismissal.
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
- (void)switchTapped { [self fire:LGSheetActionSwitchMode dismiss:YES]; }

@end

#pragma mark - Centred card implementation

@implementation LGCardAlertController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backgroundTapped:)];
    [self.view addGestureRecognizer:tap];

    UIView *card = [UIView new];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 20;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    UILabel *title = [UILabel new];
    title.text = self.titleText;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;

    UILabel *message = [UILabel new];
    message.text = self.messageText;
    message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    message.textColor = UIColor.secondaryLabelColor;
    message.textAlignment = NSTextAlignmentCenter;
    message.numberOfLines = 0;

    UIButton *confirm = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = self.confirmTitle;
    config.baseBackgroundColor = UIColor.labelColor;
    config.baseForegroundColor = UIColor.systemBackgroundColor;
    config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    confirm.configuration = config;
    [confirm.heightAnchor constraintEqualToConstant:46].active = YES;
    [confirm addTarget:self action:@selector(confirmTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [cancel.heightAnchor constraintEqualToConstant:40].active = YES;
    [cancel addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, message, confirm, cancel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:4 afterView:title];
    [stack setCustomSpacing:20 afterView:message];
    [stack setCustomSpacing:4 afterView:confirm];
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:300],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
}

- (void)backgroundTapped:(UITapGestureRecognizer *)gesture {
    // Only taps that land on the dimmed backdrop dismiss; the card itself is a
    // subview and will hit-test to something else.
    UIView *hit = [self.view hitTest:[gesture locationInView:self.view] withEvent:nil];
    if (hit == self.view) [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)confirmTapped {
    void (^callback)(void) = self.onConfirm;
    [self dismissViewControllerAnimated:YES completion:^{
        if (callback) callback();
    }];
}

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static const void *LGOverlayKey = &LGOverlayKey;
static NSHashTable<LGGridController *> *LGOverlays;
static NSString *LGTitle(void) {
    NSBundle *bundle = LGGet(NSUserDefaults.class, @"lcMainBundle");
    return [bundle localizedStringForKey:@"lc.appList.myApps" value:@"My Apps" table:nil];
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
            grid = [LGGridController new];
            [host addChildViewController:grid];
            grid.view.translatesAutoresizingMaskIntoConstraints = NO;
            [host.view addSubview:grid.view];
            // Cover the host view edge to edge: the native list may extend under
            // the translucent tab bar, and leaving that strip uncovered leaks the
            // unmodified rows through the glass. Content is inset by safeAreaInsets
            // inside LGGridController instead.
            [NSLayoutConstraint activateConstraints:@[
                [grid.view.leadingAnchor constraintEqualToAnchor:host.view.leadingAnchor],
                [grid.view.trailingAnchor constraintEqualToAnchor:host.view.trailingAnchor],
                [grid.view.topAnchor constraintEqualToAnchor:host.view.topAnchor],
                [grid.view.bottomAnchor constraintEqualToAnchor:host.view.bottomAnchor]
            ]];
            [grid didMoveToParentViewController:host];
            objc_setAssociatedObject(host, LGOverlayKey, grid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [LGOverlays addObject:grid];
            [active addObject:grid];
            LGLog([NSString stringWithFormat:@"Mounted on native app-list hosting controller after %.0f ms (safe.top=%.1f navBottom=%.1f)",
                   (CFAbsoluteTimeGetCurrent() - LGStartTime) * 1000.0,
                   host.view.safeAreaInsets.top, [grid lgTopInset]]);
        }
    }
    for (LGGridController *grid in LGOverlays) {
        // Never hide the overlay while the host page is off-screen (tab switch,
        // pushed sheet): the view is simply not visible then, and hiding it makes
        // the native list flash for up to one tick when the user comes back.
        if ([active containsObject:grid]) {
            if (grid.wasAway) {
                grid.wasAway = NO;
                [grid refresh];
            }
            [grid lgSyncLayout];
        } else {
            grid.wasAway = YES;
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

__attribute__((constructor)) static void LGInitialize(void) {
    @autoreleasepool {
        if (!LGHost()) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            LGOverlays = [NSHashTable weakObjectsHashTable];
            LGStartTime = CFAbsoluteTimeGetCurrent();
            [NSUserDefaults.standardUserDefaults registerDefaults:@{LGColumns:@4, LGNames:@YES, LGNative:@NO, LGCompactTop:@YES}];
            LGLog([NSString stringWithFormat:@"Host gate passed: LiveContainer %@ (>= 3.8.0); %@ loaded; no method hooks installed", LGDetectedVersion ?: @"?", LGLoadedName()]);
            // Public UI containment and a low-frequency foreground discovery timer.
            // No swizzling, substrate hooks, key window replacement or gesture hooks.
            // 0.15s discovery: a 1s poll is what made returning to the App tab show
            // the native list for about a second before the grid reappeared.
            NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) { LGTick(); }];
            timer.tolerance = 0.03;
            // Startup burst: poll at 30ms for the first 1.2s so the overlay lands on
            // the host page within one frame instead of one 100ms tick. It stops as
            // soon as the burst window ends; the steady 0.1s timer takes over.
            LGTick();
            [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *burstTimer) {
                LGTick();
                if (CFAbsoluteTimeGetCurrent() - LGStartTime > 1.2) [burstTimer invalidate];
            }];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                LGTick();
                // Pick up apps installed/removed while the host was in background.
                for (LGGridController *grid in LGOverlays) [grid refresh];
            }];
        });
    }
}
