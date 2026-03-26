// FinderWindowController.m
#import "FinderWindowController.h"
#import "SidebarViewController.h"
#import "FileViewController.h"
#import "GoToFolderPanel.h"

@interface FinderWindowController () <SidebarViewControllerDelegate, FileViewControllerDelegate, NSToolbarDelegate>

@property (nonatomic, strong) NSSplitViewController *splitVC;
@property (nonatomic, strong) SidebarViewController *sidebarVC;
@property (nonatomic, strong) FileViewController    *fileVC;

// Navigation stack
@property (nonatomic, strong) NSMutableArray<NSString *> *history;
@property (nonatomic)         NSInteger                   historyIndex;

// Toolbar items
@property (nonatomic, strong) NSSegmentedControl *navControl;   // back / forward segments
@property (nonatomic, strong) NSSegmentedControl *viewModeControl;
@property (nonatomic, strong) NSTextField        *pathLabel;
@end

@implementation FinderWindowController

- (instancetype)initWithPath:(NSString *)path {
    // Create window programmatically
    NSRect frame = NSMakeRect(0, 0, 1000, 650);
    NSWindowStyleMask style = NSWindowStyleMaskTitled
                            | NSWindowStyleMaskClosable
                            | NSWindowStyleMaskMiniaturizable
                            | NSWindowStyleMaskResizable;

    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                               styleMask:style
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    win.title = @"R2 Finder";
    win.minSize = NSMakeSize(640, 400);
    [win center];

    self = [super initWithWindow:win];
    if (!self) return nil;

    _history       = [NSMutableArray array];
    _historyIndex  = -1;

    [self setupToolbar];
    [self setupContentWithPath:path];
    [self pushPath:path updateContent:NO];

    return self;
}

// ───────────────────────────────────────────────
#pragma mark – Toolbar
// ───────────────────────────────────────────────

- (void)setupToolbar {
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"R2FinderToolbar"];
    toolbar.delegate = self;
    toolbar.allowsUserCustomization = NO;
    toolbar.displayMode           = NSToolbarDisplayModeIconOnly;
    self.window.toolbar = toolbar;
    self.window.titlebarAppearsTransparent = NO;
}

// ───────────────────────────────────────────────
#pragma mark – Content
// ───────────────────────────────────────────────

- (void)setupContentWithPath:(NSString *)path {
    _sidebarVC = [[SidebarViewController alloc] init];
    _sidebarVC.delegate = self;

    _fileVC = [[FileViewController alloc] initWithPath:path];
    _fileVC.delegate = self;

    _splitVC = [[NSSplitViewController alloc] init];

    NSSplitViewItem *sideItem = [NSSplitViewItem sidebarWithViewController:_sidebarVC];
    sideItem.minimumThickness = 180;
    sideItem.maximumThickness = 280;

    NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:_fileVC];
    contentItem.minimumThickness = 300;

    [_splitVC addSplitViewItem:sideItem];
    [_splitVC addSplitViewItem:contentItem];

    self.window.contentViewController = _splitVC;
}

// ───────────────────────────────────────────────
#pragma mark – Navigation
// ───────────────────────────────────────────────

- (void)pushPath:(NSString *)path updateContent:(BOOL)update {
    // Truncate forward history
    if (_historyIndex < (NSInteger)_history.count - 1) {
        NSRange range = NSMakeRange((NSUInteger)(_historyIndex + 1),
                                    _history.count - (NSUInteger)(_historyIndex + 1));
        [_history removeObjectsInRange:range];
    }
    [_history addObject:path];
    _historyIndex = (NSInteger)_history.count - 1;
    [self updateToolbarState];
    if (update) [_fileVC loadPath:path];
    self.window.title = path.lastPathComponent ?: path;
    [self updatePathLabel:path];
}

- (void)navigateToPath:(NSString *)path {
    [self pushPath:path updateContent:YES];
    [_sidebarVC highlightPath:path];
}

- (IBAction)goBack:(id)sender {
    if (_historyIndex > 0) {
        _historyIndex--;
        NSString *path = _history[(NSUInteger)_historyIndex];
        [_fileVC loadPath:path];
        self.window.title = path.lastPathComponent ?: path;
        [self updatePathLabel:path];
        [_sidebarVC highlightPath:path];
        [self updateToolbarState];
    }
}

- (IBAction)goForward:(id)sender {
    if (_historyIndex < (NSInteger)_history.count - 1) {
        _historyIndex++;
        NSString *path = _history[(NSUInteger)_historyIndex];
        [_fileVC loadPath:path];
        self.window.title = path.lastPathComponent ?: path;
        [self updatePathLabel:path];
        [_sidebarVC highlightPath:path];
        [self updateToolbarState];
    }
}

- (void)updateToolbarState {
    [_navControl setEnabled:(_historyIndex > 0)                                    forSegment:0];
    [_navControl setEnabled:(_historyIndex < (NSInteger)_history.count - 1)        forSegment:1];
}

- (void)updatePathLabel:(NSString *)path {
    _pathLabel.stringValue = path ?: @"";
}

// ───────────────────────────────────────────────
#pragma mark – NSToolbarDelegate
// ───────────────────────────────────────────────

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[@"AppLogo", @"BackForward", @"ViewMode", NSToolbarFlexibleSpaceItemIdentifier, @"PathLabel", NSToolbarFlexibleSpaceItemIdentifier, @"NewFolder", @"GoToFolder"];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarDefaultItemIdentifiers:toolbar];
}

// FinderWindowController is the toolbar delegate
- (void)toolbar:(NSToolbar *)toolbar willAddItem:(NSToolbarItem *)item {}  // no-op conformance
- (void)toolbar:(NSToolbar *)toolbar didRemoveItem:(NSToolbarItem *)item {} // no-op conformance

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {

    if ([itemIdentifier isEqualToString:@"AppLogo"]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        static NSImage *s_logo = nil;
        if (!s_logo) {
            NSString *imgPath = [[NSBundle mainBundle] pathForResource:@"r2_finder" ofType:@"png"];
            if (!imgPath) {
                NSString *exePath = [[NSBundle mainBundle] executablePath];
                imgPath = [[exePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../../r2_finder.png"];
            }
            s_logo = [[NSImage alloc] initWithContentsOfFile:imgPath];
            if (!s_logo) s_logo = [NSImage imageWithSystemSymbolName:@"doc.text.magnifyingglass" accessibilityDescription:@"R2 Finder"];
        }
        NSImage *copy = [s_logo copy];
        copy.size = NSMakeSize(20, 20);
        item.image = copy;
        item.label = @"R2 Finder";
        item.toolTip = @"R2 Finder";
        return item;
    }

    if ([itemIdentifier isEqualToString:@"BackForward"]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        // NSSegmentSwitchTrackingMomentary: each click ALWAYS fires the action
        // with a valid selectedSegment (0 or 1). No toggle confusion.
        _navControl = [NSSegmentedControl
            segmentedControlWithImages:@[
                [NSImage imageWithSystemSymbolName:@"chevron.left"  accessibilityDescription:@"Atr\u00e1s"],
                [NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:@"Adelante"],
            ]
            trackingMode:NSSegmentSwitchTrackingMomentary
                  target:self
                  action:@selector(backForwardAction:)];
        _navControl.segmentStyle = NSSegmentStyleSeparated;
        [_navControl setEnabled:NO forSegment:0];
        [_navControl setEnabled:NO forSegment:1];
        item.view = _navControl;
        return item;
    }

    if ([itemIdentifier isEqualToString:@"ViewMode"]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        _viewModeControl = [[NSSegmentedControl alloc] init];
        _viewModeControl.segmentCount = 3;
        _viewModeControl.trackingMode = NSSegmentSwitchTrackingSelectOne;
        [_viewModeControl setImage:[NSImage imageWithSystemSymbolName:@"square.grid.2x2"      accessibilityDescription:@"Iconos"]   forSegment:0];
        [_viewModeControl setImage:[NSImage imageWithSystemSymbolName:@"list.bullet"           accessibilityDescription:@"Lista"]    forSegment:1];
        [_viewModeControl setImage:[NSImage imageWithSystemSymbolName:@"rectangle.split.3x1"   accessibilityDescription:@"Columnas"] forSegment:2];
        _viewModeControl.selectedSegment = 1;
        _viewModeControl.target = self;
        _viewModeControl.action = @selector(viewModeAction:);
        [_viewModeControl sizeToFit];
        item.view = _viewModeControl;
        return item;
    }

    if ([itemIdentifier isEqualToString:@"PathLabel"]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        _pathLabel = [NSTextField labelWithString:@""];
        _pathLabel.textColor      = [NSColor secondaryLabelColor];
        _pathLabel.font           = [NSFont systemFontOfSize:12];
        _pathLabel.alignment      = NSTextAlignmentCenter;
        _pathLabel.lineBreakMode  = NSLineBreakByTruncatingMiddle;
        _pathLabel.preferredMaxLayoutWidth = 400;
        item.view = _pathLabel;
        return item;
    }

    if ([itemIdentifier isEqualToString:@"NewFolder"]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        item.image  = [NSImage imageWithSystemSymbolName:@"folder.badge.plus" accessibilityDescription:@"Nueva carpeta"];
        item.label  = @"Nueva carpeta";
        item.target = self;
        item.action = @selector(createNewFolder:);
        return item;
    }

    if ([itemIdentifier isEqualToString:@"GoToFolder"]) {
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        item.image  = [NSImage imageWithSystemSymbolName:@"arrow.right.circle" accessibilityDescription:@"Ir a carpeta"];
        item.label  = @"Ir a carpeta";
        item.target = self;
        item.action = @selector(goToFolderAction:);
        return item;
    }

    return nil;
}

- (IBAction)viewModeAction:(NSSegmentedControl *)seg {
    _fileVC.viewMode = (FileViewMode)seg.selectedSegment;
}

- (IBAction)backForwardAction:(NSSegmentedControl *)seg {
    if (seg.selectedSegment == 0) [self goBack:seg];
    else                          [self goForward:seg];
}

- (IBAction)createNewFolder:(id)sender {
    // Use the FileViewController's own currentPath — it is always up to date
    // even if the history stack and the file view diverge momentarily.
    NSString *current = _fileVC.currentPath ?: (_historyIndex >= 0 ? _history[(NSUInteger)_historyIndex] : nil);
    if (!current) return;
    [_fileVC createNewFolderInPath:current];
}

- (IBAction)goToFolderAction:(id)sender {
    __weak typeof(self) wself = self;
    [GoToFolderPanel runAsSheetOnWindow:self.window completionHandler:^(NSString *path) {
        if (path) [wself navigateToPath:path];
    }];
}

// ───────────────────────────────────────────────
#pragma mark – SidebarViewControllerDelegate
// ───────────────────────────────────────────────

- (void)sidebar:(SidebarViewController *)sidebar didSelectPath:(NSString *)path {
    [self pushPath:path updateContent:YES];
}

- (void)sidebar:(SidebarViewController *)sidebar
   dropFilePaths:(NSArray<NSString *> *)paths
           toDir:(NSString *)dstDir
          isMove:(BOOL)isMove {
    [_fileVC performTransferFromPaths:paths toDir:dstDir isMove:isMove];
}

// ───────────────────────────────────────────────
#pragma mark – FileViewControllerDelegate
// ───────────────────────────────────────────────

- (void)fileViewController:(FileViewController *)vc didNavigateToPath:(NSString *)path {
    [self pushPath:path updateContent:NO]; // content already updated by fileVC
    [_sidebarVC highlightPath:path];
}

@end
