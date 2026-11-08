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
// Native list mode: the panel is hidden, so nothing of ours can receive touches.
// This one rides on the host navigation controller's view instead.
@property(nonatomic, strong) UILongPressGestureRecognizer *hostLongPress;
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
    // Long press rides on the panel rather than the collection: empty space
    // outside the grid (below the last row, around the footer) should open the
    // settings sheet too. A hit on a cell still takes the drag / menu path.
    self.longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    self.longPress.minimumPressDuration = 0.3;
    [self.panel addGestureRecognizer:self.longPress];
    // Native mode hides the panel, so nothing of ours can receive touches there.
    // This recognizer is attached to the host's navigation controller view
    // instead, covering everything under the Dynamic Island.
    self.hostLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleHostLongPress:)];
    self.hostLongPress.minimumPressDuration = 0.5;
    self.hostLongPress.delegate = self;
    self.hostLongPress.enabled = NO;
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
    CGRect nativeSearch = [self lgTopNativeSearchFrame];
    BOOL hasNativeTopSearch = !CGRectIsEmpty(nativeSearch);
    self.search.hidden = hasNativeTopSearch;
    CGFloat top = [self lgTopInset] + 2;
    // Compact mode removes the phantom large-title inset, but only when there is
    // no native search field to sit below.
    if (!hasNativeTopSearch && [NSUserDefaults.standardUserDefaults boolForKey:LGCompactTop]) top = MAX(0, top - 44);
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
    // Native mode hides our panel, so the only place left to receive a long
    // press is the host navigation controller's view. Attaching it there also
    // covers the navigation bar — the biggest blank area under the Dynamic
    // Island — instead of a narrow strip of list background.
    UIView *navView = self.navigationController.view;
    if (!navView) return;
    if (self.hostLongPress.view == navView) return;
    [self.hostLongPress.view removeGestureRecognizer:self.hostLongPress];
    [navView addGestureRecognizer:self.hostLongPress];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.hostLongPress) return YES;
    UIView *navView = self.navigationController.view;
    if (!navView) return NO;
    CGPoint point = [gestureRecognizer locationInView:navView];
    UIView *hit = [navView hitTest:point withEvent:nil];
    return !LGIsInteractive(hit);
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
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"切换到网格布局" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showGrid];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
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
    // The recognizer lives on the host's view, which outlives us.
    [self.hostLongPress.view removeGestureRecognizer:self.hostLongPress];
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
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[LGLoadedName() stringByDeletingPathExtension]
        message:[NSString stringWithFormat:@"已显示 %lu 个应用（隐藏 %lu，文件夹冲突 %lu，元数据异常 %lu）。应用管理、容器选择和隐藏应用解锁请使用原生列表。",
                 (unsigned long)self.entries.count, (unsigned long)LGCountHidden,
                 (unsigned long)LGCountAmbiguous, (unsigned long)LGCountDamaged]
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *count in @[@4,@5]) {
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ 列",count] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [NSUserDefaults.standardUserDefaults setInteger:count.integerValue forKey:LGColumns];
            [self.collection.collectionViewLayout invalidateLayout];
            [self.collection reloadData];
        }]];
    }
    BOOL names = [NSUserDefaults.standardUserDefaults boolForKey:LGNames];
    [sheet addAction:[UIAlertAction actionWithTitle:names ? @"隐藏应用名称" : @"显示应用名称" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [NSUserDefaults.standardUserDefaults setBool:!names forKey:LGNames];
        [self.collection.collectionViewLayout invalidateLayout];
        [self.collection reloadData];
    }]];
    if ([NSFileManager.defaultManager fileExistsAtPath:LGLogPath()]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"导出调试日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            // Wait for the action sheet to finish dismissing before presenting the share sheet.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self exportLog];
            });
        }]];
    }
    BOOL hasBackground = self.backgroundView.image != nil;
    [sheet addAction:[UIAlertAction actionWithTitle:hasBackground ? @"更换背景图片" : @"选择背景图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self chooseBackground];
    }]];
    if (hasBackground) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"移除背景" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self removeBackground];
        }]];
    }
    BOOL compact = [NSUserDefaults.standardUserDefaults boolForKey:LGCompactTop];
    [sheet addAction:[UIAlertAction actionWithTitle:(compact ? @"顶部间距：紧凑（点此改为宽松）" : @"顶部间距：宽松（点此改为紧凑）") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [NSUserDefaults.standardUserDefaults setBool:!compact forKey:LGCompactTop];
        [self.view setNeedsLayout];
    }]];
    // Single entry point for both directions now that the toolbar and the
    // floating "back to grid" button are gone.
    BOOL native = self.nativeMode;
    [sheet addAction:[UIAlertAction actionWithTitle:(native ? @"切换到网格布局" : @"切换到原生列表") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (native) {
            [self showGrid];
        } else {
            [self showNative];
        }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) [self.collection reloadData];
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
