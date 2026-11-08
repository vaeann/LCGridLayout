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
// Same walk, but collecting the views themselves so they can be suppressed and
// later restored. Deliberately ignores hidden/alpha, otherwise a suppressed bar
// could never be found again.
static void LGCollectSearchBars(UIView *view, UIView *skip, NSMutableArray<UIView *> *result) {
    if (!view || view == skip) return;
    if (LGIsSearchField(view) && view.window) {
        [result addObject:view];
        return;
    }
    for (UIView *sub in view.subviews) LGCollectSearchBars(sub, skip, result);
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

@interface LGGridController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate, PHPickerViewControllerDelegate>
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
@property(nonatomic, strong) NSIndexPath *pressIndexPath;
@property(nonatomic, strong) LGEntry *pressEntry;
@property(nonatomic) CGPoint pressStart;
@property(nonatomic) BOOL hadNativeTopSearch;
@property(nonatomic) CGFloat lastTopInset;
@property(nonatomic) UIEdgeInsets lastSafeInsets;
@property(nonatomic, strong) NSMutableSet<NSString *> *pendingIcons;
// LiveContainer search bars we faded out in grid mode, kept for restoration.
@property(nonatomic, strong) NSHashTable<UIView *> *suppressedSearchViews;
@property(nonatomic, strong) id nativeSearchObserver;
- (CGFloat)lgTopInset;
- (void)lgSyncLayout;
- (void)refresh;
- (void)lgSuppressNativeSearch:(BOOL)suppress;
- (void)lgInstallSwitchButton;
- (void)handleSheetAction:(LGSheetAction)action;
@end

@implementation LGGridController
- (void)loadView {
    self.view = [LGPassView new];
    self.view.backgroundColor = UIColor.clearColor;
    self.icons = [NSCache new];
    self.icons.countLimit = 150;
    self.pendingIcons = [NSMutableSet new];
    self.suppressedSearchViews = [NSHashTable weakObjectsHashTable];
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
    [self.panel addGestureRecognizer:self.longPress];
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
    // SwiftUI rebuilds the page (and its search bar) on tab switches; re-apply
    // the fade so the entry point never comes back while the grid is showing.
    if (!self.nativeMode) [self lgSuppressNativeSearch:YES];
    // SwiftUI also reconciles navigationItem, which can drop our button.
    [self lgInstallSwitchButton];
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
    // The overlay view itself stays full-bleed so touches outside the panel still
    // pass through (LGPassView), but the panel starts below the navigation bar:
    // the host's buttons and "App" large title must stay visible and untouched.
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    BOOL navHidden = self.navigationController.isNavigationBarHidden;
    CGRect nativeSearch = navHidden ? CGRectZero : [self lgTopNativeSearchFrame];
    BOOL hasNativeTopSearch = !CGRectIsEmpty(nativeSearch);
    self.search.hidden = hasNativeTopSearch;
    CGFloat top = [self lgTopInset] + 2;
    // Tight means "flush under the bar"; loose adds breathing room. The old -44
    // (which cancelled the large-title inset) no longer applies now that the
    // title is visible — it pushed the search field up behind the bar.
    if (!hasNativeTopSearch && !navHidden && ![NSUserDefaults.standardUserDefaults boolForKey:LGCompactTop]) top += 24;
    if (hasNativeTopSearch) top = MAX(top, CGRectGetMaxY(nativeSearch) + 4);
    self.lastTopInset = [self lgTopInset];
    self.lastSafeInsets = safe;
    self.hadNativeTopSearch = hasNativeTopSearch;
    CGFloat panelHeight = MAX(0, h - top);
    self.panel.frame = CGRectMake(0, top, w, panelHeight);
    self.backgroundView.frame = self.panel.bounds;
    self.dimView.frame = self.panel.bounds;
    // Everything below is in panel coordinates.
    self.search.frame = CGRectMake(4, 0, MAX(0,w-8), 48);
    CGFloat footerHeight = MAX(24, self.footer.font.lineHeight + 2);
    CGFloat footerGap = 14;
    self.footer.frame = CGRectMake(0, MAX(0, panelHeight-safe.bottom-footerHeight-footerGap), w, footerHeight);
    CGFloat headerHeight = hasNativeTopSearch ? 8 : 48;
    CGRect frame = CGRectMake(0, headerHeight, w, MAX(0, panelHeight-headerHeight-safe.bottom-footerHeight-footerGap-2));
    BOOL resized = !CGSizeEqualToSize(self.collection.bounds.size, frame.size);
    self.collection.frame = frame;
    if (resized) [self.collection.collectionViewLayout invalidateLayout];
}
- (void)applyMode {
    self.panel.hidden = self.nativeMode;
    // The host navigation bar (buttons and large title) stays visible on purpose:
    // the grid only replaces the search field and the app list below it.
    [self lgSuppressNativeSearch:!self.nativeMode];
    [self lgInstallSwitchButton];
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

#pragma mark - Host bar button and search suppression

static const void *LGSwitchButtonKey = &LGSwitchButtonKey;

// LiveContainer's search bar lives in the navigation area. Even with the grid on
// top, its expansion animation still runs and pushes the content around. Hiding
// it (rather than fading) removes both the layout slot and the entry point; the
// views are remembered weakly so native mode can bring them back.
- (void)lgSuppressNativeSearch:(BOOL)suppress {
    if (suppress) {
        UIWindow *window = self.view.window;
        if (!window) return;
        NSMutableArray<UIView *> *bars = [NSMutableArray array];
        LGCollectSearchBars(window.rootViewController.view, self.view, bars);
        for (UIView *bar in bars) {
            if (bar.hidden) continue;
            [self.suppressedSearchViews addObject:bar];
            bar.hidden = YES;
        }
    } else {
        for (UIView *bar in self.suppressedSearchViews.allObjects) {
            bar.hidden = NO;
        }
        [self.suppressedSearchViews removeAllObjects];
    }
}

// The single entry point for switching layouts: one button on the real
// navigation bar that shows the *target* mode. Living on the host bar means it
// never competes with LiveContainer's own gestures.
- (void)lgInstallSwitchButton {
    UIViewController *host = self.parentViewController;
    if (!host) return;
    UIBarButtonItem *item = objc_getAssociatedObject(host, LGSwitchButtonKey);
    if (!item) {
        item = [[UIBarButtonItem alloc] initWithTitle:@"" style:UIBarButtonItemStylePlain target:self action:@selector(toggleMode)];
        objc_setAssociatedObject(host, LGSwitchButtonKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LGLog([NSString stringWithFormat:@"Toolbar probe: left=%lu right=%lu title=%@",
               (unsigned long)host.navigationItem.leftBarButtonItems.count,
               (unsigned long)host.navigationItem.rightBarButtonItems.count,
               host.navigationItem.title ?: @"(nil)"]);
    }
    item.target = self;   // the controller is rebuilt on every mount
    BOOL toNative = !self.nativeMode;
    item.image = [UIImage systemImageNamed:(toNative ? @"list.bullet" : @"square.grid.2x2")];
    item.accessibilityLabel = toNative ? @"列表布局" : @"宫格布局";

    // iOS 16+ SwiftUI toolbars are backed by item groups; setting
    // rightBarButtonItems on such a bar is silently ignored. Try groups first
    // and fall back to the legacy array only when there are none.
    if (@available(iOS 16.0, *)) {
        NSArray<UIBarButtonItemGroup *> *groups = host.navigationItem.trailingItemGroups;
        if (groups.count > 0) {
            for (UIBarButtonItemGroup *group in groups) {
                if ([group.barButtonItems containsObject:item]) return;
            }
            UIBarButtonItemGroup *ours = [[UIBarButtonItemGroup alloc] initWithBarButtonItems:@[item] representativeItem:nil];
            host.navigationItem.trailingItemGroups = [groups arrayByAddingObject:ours];
            return;
        }
    }

    NSMutableArray<UIBarButtonItem *> *items = [host.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    if (![items containsObject:item]) {
        [items addObject:item];
        host.navigationItem.rightBarButtonItems = items;
    }
}

- (void)toggleMode {
    if (self.nativeMode) {
        [self showGrid];
    } else {
        [self showNative];
    }
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
