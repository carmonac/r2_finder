// FileViewController.m
#import "FileViewController.h"
#import "ProgressWindowController.h"
#import "bridge.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Quartz/Quartz.h>
#import <CoreServices/CoreServices.h>

// ─────────────────────────────────────────────────────────────────────────────
// FileEntry – lightweight model object for directory entries
// ─────────────────────────────────────────────────────────────────────────────

@interface FileEntry : NSObject
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, copy)   NSString *path;
@property (nonatomic)         BOOL      isDir;
@property (nonatomic)         BOOL      isSymlink;
@property (nonatomic)         uint64_t  size;
@property (nonatomic)         int64_t   mtime;
@property (nonatomic, strong) NSImage  *icon;
@property (nonatomic, strong) NSMutableArray<FileEntry *> *children;
@property (nonatomic)         BOOL      childrenLoaded;
@end
@implementation FileEntry @end

// ─────────────────────────────────────────────────────────────────────────────
// ContextMenuOutlineView – NSOutlineView subclass that supports per-row context menus
// ─────────────────────────────────────────────────────────────────────────────

@protocol ContextMenuOutlineViewDelegate <NSOutlineViewDelegate>
@optional
- (NSMenu *)contextMenuForOutlineView:(NSOutlineView *)ov clickedRow:(NSInteger)row;
@end

@interface ContextMenuOutlineView : NSOutlineView @end
@implementation ContextMenuOutlineView
- (NSMenu *)menuForEvent:(NSEvent *)event {
    CGPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:loc];
    id<ContextMenuOutlineViewDelegate> d = (id<ContextMenuOutlineViewDelegate>)self.delegate;
    if ([d respondsToSelector:@selector(contextMenuForOutlineView:clickedRow:)])
        return [d contextMenuForOutlineView:self clickedRow:row];
    return [super menuForEvent:event];
}
@end

// ─────────────────────────────────────────────────────────────────────────────
// IconCollectionViewItem – NSCollectionViewItem for icon grid view
// ─────────────────────────────────────────────────────────────────────────────

@interface IconCollectionViewItem : NSCollectionViewItem
@end

@implementation IconCollectionViewItem

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 90, 90)];

    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.imageScaling = NSImageScaleProportionallyDown;
    iv.imageAlignment = NSImageAlignCenter;
    [container addSubview:iv];

    NSTextField *tf = [NSTextField labelWithString:@""];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.alignment = NSTextAlignmentCenter;
    tf.lineBreakMode = NSLineBreakByTruncatingTail;
    tf.maximumNumberOfLines = 2;
    tf.font = [NSFont systemFontOfSize:11];
    [container addSubview:tf];

    [NSLayoutConstraint activateConstraints:@[
        [iv.topAnchor      constraintEqualToAnchor:container.topAnchor constant:4],
        [iv.centerXAnchor  constraintEqualToAnchor:container.centerXAnchor],
        [iv.widthAnchor    constraintEqualToConstant:64],
        [iv.heightAnchor   constraintEqualToConstant:64],
        [tf.topAnchor      constraintEqualToAnchor:iv.bottomAnchor constant:2],
        [tf.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:2],
        [tf.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-2],
    ]];

    self.view = container;
    self.imageView = iv;
    self.textField = tf;
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    self.view.layer.backgroundColor = selected
        ? [NSColor selectedContentBackgroundColor].CGColor
        : [NSColor clearColor].CGColor;
    self.view.layer.cornerRadius = 6;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// ContextMenuCollectionView – NSCollectionView with right-click menu support
// ─────────────────────────────────────────────────────────────────────────────

@protocol ContextMenuCollectionViewDelegate <NSCollectionViewDelegate>
@optional
- (NSMenu *)contextMenuForCollectionView:(NSCollectionView *)cv atPoint:(NSPoint)point;
@end

@protocol CollectionViewDoubleClickDelegate <NSObject>
@optional
- (void)collectionViewDidDoubleClick:(NSCollectionView *)cv atIndexPath:(NSIndexPath *)ip;
@end

@interface ContextMenuCollectionView : NSCollectionView @end
@implementation ContextMenuCollectionView
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    id<ContextMenuCollectionViewDelegate> d = (id<ContextMenuCollectionViewDelegate>)self.delegate;
    if ([d respondsToSelector:@selector(contextMenuForCollectionView:atPoint:)])
        return [d contextMenuForCollectionView:self atPoint:loc];
    return [super menuForEvent:event];
}
- (void)mouseDown:(NSEvent *)event {
    [super mouseDown:event];
    if (event.clickCount == 2) {
        NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
        NSIndexPath *ip = [self indexPathForItemAtPoint:loc];
        if (ip) {
            id<CollectionViewDoubleClickDelegate> d = (id<CollectionViewDoubleClickDelegate>)self.delegate;
            if ([d respondsToSelector:@selector(collectionViewDidDoubleClick:atIndexPath:)])
                [d collectionViewDidDoubleClick:self atIndexPath:ip];
        }
    }
}
@end

// ─────────────────────────────────────────────────────────────────────────────
// File-scope state
// ─────────────────────────────────────────────────────────────────────────────

static BOOL s_showHidden = NO;

typedef NS_ENUM(NSInteger, ClipboardOperation) {
    ClipboardOperationNone,
    ClipboardOperationCopy,
    ClipboardOperationCut,
};

// ─────────────────────────────────────────────────────────────────────────────
// FileViewController
// ─────────────────────────────────────────────────────────────────────────────

@interface FileViewController () <NSOutlineViewDataSource,
                                  NSOutlineViewDelegate,
                                  ContextMenuOutlineViewDelegate,
                                  NSCollectionViewDataSource,
                                  NSCollectionViewDelegate,
                                  ContextMenuCollectionViewDelegate,
                                  CollectionViewDoubleClickDelegate,
                                  NSBrowserDelegate,
                                  NSDraggingSource,
                                  NSTextFieldDelegate,
                                  NSMenuDelegate,
                                  QLPreviewPanelDataSource,
                                  QLPreviewPanelDelegate>
@property (nonatomic, strong) NSScrollView              *scrollView;      // list view
@property (nonatomic, strong) ContextMenuOutlineView     *outlineView;
@property (nonatomic, strong) NSScrollView              *iconScrollView;  // icon view
@property (nonatomic, strong) ContextMenuCollectionView *collectionView;
@property (nonatomic, strong) NSBrowser                 *browser;         // column view
@property (nonatomic, strong) NSMutableArray<NSMutableArray<FileEntry *> *> *columnEntries; // per-column data
@property (nonatomic, strong) NSMutableArray<NSString *> *columnPaths;    // path for each column
@property (nonatomic, strong) NSMutableArray<FileEntry *> *entries;
@property (nonatomic, copy)   NSString                 *currentPath;   // also satisfies the readonly public decl
@property (nonatomic, strong) NSArray<NSString *>      *clipboardPaths;
@property (nonatomic)         ClipboardOperation         clipboardOp;
@property (nonatomic)         NSInteger                  renameRow;
@property (nonatomic)         FSEventStreamRef           fsEventStream;
@property (nonatomic, strong) NSProgressIndicator       *loadingSpinner;
@property (nonatomic, strong) dispatch_queue_t            loadQueue;
@property (nonatomic)         NSUInteger                  loadGeneration;
@property (nonatomic)         BOOL                        isLoading;
@property (nonatomic, strong) dispatch_source_t           reloadDebounce;
@end

@implementation FileViewController

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – FSEvents directory monitoring
// ─────────────────────────────────────────────────────────────────────────────

static void fsEventsCallback(ConstFSEventStreamRef streamRef,
                             void *clientCallBackInfo,
                             size_t numEvents,
                             void *eventPaths,
                             const FSEventStreamEventFlags eventFlags[],
                             const FSEventStreamEventId eventIds[]) {
    FileViewController *vc = (__bridge FileViewController *)clientCallBackInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [vc scheduleReload];
    });
}

// Coalesce bursts of FSEvents (e.g. rsync deleting many files in a row over
// SMB) into a single reload that fires after a short quiet period.
- (void)scheduleReload {
    if (!_reloadDebounce) {
        _reloadDebounce = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_main_queue());
        __weak typeof(self) wself = self;
        dispatch_source_set_event_handler(_reloadDebounce, ^{
            typeof(self) sself = wself;
            if (!sself) return;
            dispatch_source_set_timer(sself.reloadDebounce, DISPATCH_TIME_FOREVER, 0, 0);
            if (sself.currentPath) [sself loadPath:sself.currentPath];
        });
        dispatch_resume(_reloadDebounce);
    }
    dispatch_source_set_timer(_reloadDebounce,
                              dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC),
                              DISPATCH_TIME_FOREVER, 50 * NSEC_PER_MSEC);
}

- (void)startWatchingPath:(NSString *)path {
    [self stopWatching];
    FSEventStreamContext ctx = { 0, (__bridge void *)self, NULL, NULL, NULL };
    _fsEventStream = FSEventStreamCreate(
        NULL, &fsEventsCallback, &ctx,
        (__bridge CFArrayRef)@[path],
        kFSEventStreamEventIdSinceNow,
        0.5,  // 500ms latency – batches rapid changes
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
    );
    FSEventStreamScheduleWithRunLoop(_fsEventStream, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    FSEventStreamStart(_fsEventStream);
}

- (void)stopWatching {
    if (_fsEventStream) {
        FSEventStreamStop(_fsEventStream);
        FSEventStreamInvalidate(_fsEventStream);
        FSEventStreamRelease(_fsEventStream);
        _fsEventStream = NULL;
    }
}

- (void)dealloc {
    [self stopWatching];
    if (_reloadDebounce) {
        dispatch_source_cancel(_reloadDebounce);
        _reloadDebounce = nil;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Init / View
// ─────────────────────────────────────────────────────────────────────────────

- (instancetype)initWithPath:(NSString *)path {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _entries       = [NSMutableArray array];
    _columnEntries = [NSMutableArray array];
    _columnPaths   = [NSMutableArray array];
    _clipboardOp   = ClipboardOperationNone;
    _renameRow     = -1;
    _viewMode      = FileViewModeList;
    _currentPath   = [path copy];
    _loadQueue     = dispatch_queue_create("com.r2finder.dirload", DISPATCH_QUEUE_SERIAL);
    _loadGeneration = 0;
    return self;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 700, 600)];
    self.view.wantsLayer = YES;

    // Status bar at bottom
    NSTextField *statusLabel = [NSTextField labelWithString:@""];
    statusLabel.tag           = 999;
    statusLabel.font          = [NSFont systemFontOfSize:11];
    statusLabel.textColor     = [NSColor secondaryLabelColor];
    statusLabel.alignment     = NSTextAlignmentCenter;
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:statusLabel];

    // Loading spinner (centered, hidden when stopped)
    _loadingSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 32, 32)];
    _loadingSpinner.style = NSProgressIndicatorStyleSpinning;
    _loadingSpinner.controlSize = NSControlSizeRegular;
    _loadingSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingSpinner.displayedWhenStopped = NO;
    [self.view addSubview:_loadingSpinner];

    // Outline view (replaces flat table view – supports expandable folders)
    _outlineView = [[ContextMenuOutlineView alloc] initWithFrame:NSZeroRect];
    _outlineView.allowsMultipleSelection = YES;
    _outlineView.allowsColumnResizing    = YES;
    _outlineView.allowsColumnReordering  = NO;
    _outlineView.rowSizeStyle            = NSTableViewRowSizeStyleMedium;
    _outlineView.gridStyleMask           = NSTableViewSolidHorizontalGridLineMask;
    _outlineView.dataSource              = self;
    _outlineView.delegate                = self;
    _outlineView.indentationPerLevel     = 18;
    _outlineView.autoresizesOutlineColumn = YES;
    [_outlineView setDoubleAction:@selector(tableViewDoubleClicked:)];

    // Drag source
    [_outlineView setDraggingSourceOperationMask:NSDragOperationCopy | NSDragOperationMove
                                        forLocal:NO];

    // Drag destination
    [_outlineView registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    _outlineView.draggingDestinationFeedbackStyle = NSTableViewDraggingDestinationFeedbackStyleRegular;

    // Columns
    BOOL firstColumn = YES;
    for (NSDictionary *def in @[
        @{ @"id": @"name", @"title": @"Nombre",                @"width": @340 },
        @{ @"id": @"size", @"title": @"Tamaño",                @"width": @100 },
        @{ @"id": @"date", @"title": @"Fecha de modificación", @"width": @180 },
        @{ @"id": @"kind", @"title": @"Tipo",                  @"width": @120 },
    ]) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:def[@"id"]];
        col.title = def[@"title"];
        col.width = [def[@"width"] floatValue];
        col.minWidth = 60;
        col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:def[@"id"] ascending:YES];
        [_outlineView addTableColumn:col];
        if (firstColumn) {
            _outlineView.outlineTableColumn = col;   // disclosure triangles in Name column
            firstColumn = NO;
        }
    }

    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.hasVerticalScroller   = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.documentView          = _outlineView;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_scrollView];

    // Icon view (NSCollectionView)
    NSCollectionViewFlowLayout *flow = [[NSCollectionViewFlowLayout alloc] init];
    flow.itemSize                = NSMakeSize(90, 90);
    flow.minimumInteritemSpacing = 10;
    flow.minimumLineSpacing      = 10;
    flow.sectionInset            = NSEdgeInsetsMake(10, 10, 10, 10);

    _collectionView = [[ContextMenuCollectionView alloc] initWithFrame:NSZeroRect];
    _collectionView.collectionViewLayout = flow;
    _collectionView.dataSource           = self;
    _collectionView.delegate             = self;
    _collectionView.selectable           = YES;
    _collectionView.allowsMultipleSelection = YES;
    _collectionView.backgroundColors     = @[[NSColor controlBackgroundColor]];
    [_collectionView registerClass:[IconCollectionViewItem class]
             forItemWithIdentifier:@"IconItem"];
    [_collectionView registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    [_collectionView setDraggingSourceOperationMask:NSDragOperationCopy | NSDragOperationMove
                                           forLocal:NO];

    _iconScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _iconScrollView.hasVerticalScroller   = YES;
    _iconScrollView.hasHorizontalScroller = NO;
    _iconScrollView.documentView          = _collectionView;
    _iconScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconScrollView.hidden = YES;  // start with list view
    [self.view addSubview:_iconScrollView];

    // Column view (NSBrowser)
    _browser = [[NSBrowser alloc] initWithFrame:NSZeroRect];
    _browser.allowsMultipleSelection = YES;
    _browser.allowsEmptySelection    = YES;
    _browser.hasHorizontalScroller   = YES;
    _browser.separatesColumns        = YES;
    _browser.titled                  = NO;
    _browser.minColumnWidth          = 180;
    _browser.maxVisibleColumns       = 10;
    _browser.translatesAutoresizingMaskIntoConstraints = NO;
    _browser.hidden = YES;
    _browser.target = self;
    _browser.action = @selector(browserSingleClick:);
    _browser.doubleAction = @selector(browserDoubleAction:);
    [_browser setCellClass:[NSBrowserCell class]];
    _browser.delegate = self;
    [self.view addSubview:_browser];

    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor     constraintEqualToAnchor:self.view.topAnchor],
        [_scrollView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor  constraintEqualToAnchor:statusLabel.topAnchor constant:-2],

        [_iconScrollView.topAnchor     constraintEqualToAnchor:self.view.topAnchor],
        [_iconScrollView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [_iconScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_iconScrollView.bottomAnchor  constraintEqualToAnchor:statusLabel.topAnchor constant:-2],

        [_browser.topAnchor     constraintEqualToAnchor:self.view.topAnchor],
        [_browser.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [_browser.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_browser.bottomAnchor  constraintEqualToAnchor:statusLabel.topAnchor constant:-2],

        [statusLabel.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [statusLabel.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor constant:-4],
        [statusLabel.heightAnchor   constraintEqualToConstant:18],

        [_loadingSpinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_loadingSpinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (_currentPath) [self loadPath:_currentPath];
}

- (void)setViewMode:(FileViewMode)viewMode {
    _viewMode = viewMode;
    _scrollView.hidden     = YES;
    _iconScrollView.hidden = YES;
    _browser.hidden        = YES;
    switch (viewMode) {
        case FileViewModeList:
            _scrollView.hidden = NO;
            break;
        case FileViewModeIcon:
            _iconScrollView.hidden = NO;
            [_collectionView reloadData];
            break;
        case FileViewModeColumns:
            _browser.hidden = NO;
            [self loadBrowserFromPath:_currentPath];
            break;
        default:
            // Gallery not yet implemented – fall back to list
            _scrollView.hidden = NO;
            break;
    }
}

- (void)keyDown:(NSEvent *)event {
    if (_renameRow >= 0) return;       // let the rename field handle all keys
    unichar c = [event.characters characterAtIndex:0];
    if (c == '\r')              { [self openSelected:nil];   return; }
    if (c == NSDeleteCharacter) { [self deleteSelected:nil]; return; }
    if (c == ' ') {
        QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
        if (panel.isVisible) {
            [panel orderOut:nil];
        } else {
            [panel makeKeyAndOrderFront:nil];
        }
        return;
    }
    [super keyDown:event];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Data loading
// ─────────────────────────────────────────────────────────────────────────────

- (void)loadPath:(NSString *)path {
    BOOL pathChanged = ![_currentPath isEqualToString:path];
    _currentPath = [path copy];
    if (pathChanged) [self startWatchingPath:path];

    // On navigation, blank the view immediately so the user sees they've moved.
    // On in-place refresh (FSEvents), keep the existing entries on screen so the
    // UI doesn't flicker through "Cargando…" every time rsync deletes a file.
    if (pathChanged) {
        [_entries removeAllObjects];
        [self reloadAllViews];
        _isLoading = YES;
        [_loadingSpinner startAnimation:nil];
        [self updateStatusBar];
    }

    // Capture generation to detect superseded loads
    NSUInteger thisGeneration = ++_loadGeneration;
    NSString *pathCopy = [path copy];
    BOOL showHidden = s_showHidden;

    dispatch_async(_loadQueue, ^{
        ZigDirListing *listing = zig_list_directory(pathCopy.UTF8String);

        NSMutableArray<FileEntry *> *newEntries = [NSMutableArray array];
        if (listing) {
            for (uint64_t i = 0; i < listing->count; i++) {
                ZigDirEntry e = listing->entries[i];
                if (!showHidden && e.name[0] == '.') continue;
                FileEntry *fe = [[FileEntry alloc] init];
                fe.name      = @(e.name);
                fe.path      = @(e.path);
                fe.isDir     = (BOOL)e.is_dir;
                fe.isSymlink = (BOOL)e.is_symlink;
                fe.size      = e.size;
                fe.mtime     = e.mtime;
                [newEntries addObject:fe];
            }
            zig_free_dir_listing(listing);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_loadGeneration != thisGeneration) return;

            self->_isLoading = NO;
            [self->_loadingSpinner stopAnimation:nil];

            NSWorkspace *ws = [NSWorkspace sharedWorkspace];
            for (FileEntry *fe in newEntries) {
                fe.icon = [ws iconForFile:fe.path];
                fe.icon.size = NSMakeSize(16, 16);
            }

            [self->_entries removeAllObjects];
            [self->_entries addObjectsFromArray:newEntries];
            [self reloadAllViews];
            [self updateStatusBar];
        });
    });
}

- (void)reloadAllViews {
    [_outlineView reloadData];
    [_collectionView reloadData];
    if (_viewMode == FileViewModeColumns)
        [self loadBrowserFromPath:_currentPath];
}

- (void)updateStatusBar {
    NSTextField *label = (NSTextField *)[self.view viewWithTag:999];
    if (_isLoading) {
        label.stringValue = @"Cargando…";
        return;
    }
    NSUInteger folders = 0, files = 0;
    for (FileEntry *e in _entries) { if (e.isDir) folders++; else files++; }
    label.stringValue = [NSString stringWithFormat:@"%lu carpeta%@, %lu archivo%@",
                         (unsigned long)folders, folders == 1 ? @"" : @"s",
                         (unsigned long)files,   files   == 1 ? @"" : @"s"];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Public API
// ─────────────────────────────────────────────────────────────────────────────

- (void)createNewFolderInPath:(NSString *)path {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText     = @"Nueva carpeta";
    alert.informativeText = @"Nombre de la nueva carpeta:";
    [alert addButtonWithTitle:@"Crear"];
    [alert addButtonWithTitle:@"Cancelar"];
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    input.placeholderString = @"Carpeta sin titulo";
    input.stringValue       = @"Carpeta sin titulo";
    alert.accessoryView     = input;
    __weak typeof(self) wself = self;
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;
        NSString *name = input.stringValue;
        if (!name.length) return;
        char errBuf[512] = {0};
        NSString *newPath = [path stringByAppendingPathComponent:name];
        if (!zig_create_directory(newPath.UTF8String, errBuf, sizeof(errBuf)))
            [wself showErrorMessage:@(errBuf)];
        else
            [wself loadPath:wself.currentPath];
    }];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Children loading helper
// ─────────────────────────────────────────────────────────────────────────────

- (void)loadChildrenForEntry:(FileEntry *)entry {
    if (entry.childrenLoaded) return;
    entry.childrenLoaded = YES;
    entry.children = [NSMutableArray array];
    ZigDirListing *listing = zig_list_directory(entry.path.UTF8String);
    if (!listing) return;
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    for (uint64_t i = 0; i < listing->count; i++) {
        ZigDirEntry e = listing->entries[i];
        if (!s_showHidden && e.name[0] == '.') continue;
        FileEntry *fe = [[FileEntry alloc] init];
        fe.name      = @(e.name);
        fe.path      = @(e.path);
        fe.isDir     = (BOOL)e.is_dir;
        fe.isSymlink = (BOOL)e.is_symlink;
        fe.size      = e.size;
        fe.mtime     = e.mtime;
        fe.icon      = [ws iconForFile:fe.path];
        fe.icon.size = NSMakeSize(16, 16);
        [entry.children addObject:fe];
    }
    zig_free_dir_listing(listing);
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSOutlineViewDataSource
// ─────────────────────────────────────────────────────────────────────────────

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    if (!item) return (NSInteger)_entries.count;  // root
    FileEntry *entry = (FileEntry *)item;
    if (!entry.isDir) return 0;
    [self loadChildrenForEntry:entry];
    return (NSInteger)entry.children.count;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    if (!item) return _entries[(NSUInteger)index];
    return ((FileEntry *)item).children[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    return ((FileEntry *)item).isDir;
}

- (void)outlineView:(NSOutlineView *)ov sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old {
    NSSortDescriptor *sd = ov.sortDescriptors.firstObject;
    if (!sd) return;
    NSComparator cmp = ^NSComparisonResult(FileEntry *a, FileEntry *b) {
        NSComparisonResult r = NSOrderedSame;
        if ([sd.key isEqualToString:@"name"])      r = [a.name localizedCaseInsensitiveCompare:b.name];
        else if ([sd.key isEqualToString:@"size"]) r = [@(a.size)  compare:@(b.size)];
        else if ([sd.key isEqualToString:@"date"]) r = [@(a.mtime) compare:@(b.mtime)];
        else if ([sd.key isEqualToString:@"kind"]) r = [@(a.isDir) compare:@(b.isDir)];
        return sd.ascending ? r : -r;
    };
    [_entries sortUsingComparator:cmp];
    [ov reloadData];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSOutlineViewDelegate (cell views)
// ─────────────────────────────────────────────────────────────────────────────

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    FileEntry *entry = (FileEntry *)item;
    NSString  *ident = col.identifier;

    if ([ident isEqualToString:@"name"]) {
        NSTableCellView *cell = [ov makeViewWithIdentifier:@"NameCell" owner:self];
        if (!cell) {
            cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
            cell.identifier = @"NameCell";
            NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            iv.imageScaling = NSImageScaleProportionallyDown;
            [cell addSubview:iv];
            cell.imageView = iv;
            NSTextField *tf = [NSTextField labelWithString:@""];
            tf.translatesAutoresizingMaskIntoConstraints = NO;
            tf.lineBreakMode = NSLineBreakByTruncatingTail;
            [cell addSubview:tf];
            cell.textField = tf;
            [NSLayoutConstraint activateConstraints:@[
                [iv.leadingAnchor  constraintEqualToAnchor:cell.leadingAnchor constant:4],
                [iv.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
                [iv.widthAnchor    constraintEqualToConstant:16],
                [iv.heightAnchor   constraintEqualToConstant:16],
                [tf.leadingAnchor  constraintEqualToAnchor:iv.trailingAnchor constant:5],
                [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
                [tf.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
            ]];
        }
        cell.textField.stringValue = entry.name;
        cell.imageView.image       = entry.icon;
        cell.alphaValue = (_clipboardOp == ClipboardOperationCut &&
                           [_clipboardPaths containsObject:entry.path]) ? 0.35 : 1.0;
        return cell;
    }

    NSTableCellView *cell = [ov makeViewWithIdentifier:@"BasicCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"BasicCell";
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:tf];
        cell.textField = tf;
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor  constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [tf.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    if ([ident isEqualToString:@"size"])
        cell.textField.stringValue = entry.isDir ? @"-" : [self formattedSize:entry.size];
    else if ([ident isEqualToString:@"date"])
        cell.textField.stringValue = [self formattedDate:entry.mtime];
    else if ([ident isEqualToString:@"kind"])
        cell.textField.stringValue = entry.isDir ? @"Carpeta" : (entry.isSymlink ? @"Alias" : [self kindForPath:entry.path]);
    return cell;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSCollectionViewDataSource
// ─────────────────────────────────────────────────────────────────────────────

- (NSInteger)collectionView:(NSCollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)_entries.count;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)cv
     itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
    IconCollectionViewItem *item = [cv makeItemWithIdentifier:@"IconItem" forIndexPath:indexPath];
    NSUInteger idx = indexPath.item;
    if (idx < _entries.count) {
        FileEntry *entry = _entries[idx];
        item.textField.stringValue = entry.name;
        // Use a larger icon for icon view
        NSImage *icon = [entry.icon copy];
        icon.size = NSMakeSize(64, 64);
        item.imageView.image = icon;
        item.view.alphaValue = (_clipboardOp == ClipboardOperationCut &&
                                [_clipboardPaths containsObject:entry.path]) ? 0.35 : 1.0;
    }
    return item;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSCollectionViewDelegate (double-click & context menu)
// ─────────────────────────────────────────────────────────────────────────────

- (void)collectionView:(NSCollectionView *)cv didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
    if ([QLPreviewPanel sharedPreviewPanelExists] && [QLPreviewPanel sharedPreviewPanel].isVisible)
        [[QLPreviewPanel sharedPreviewPanel] reloadData];
}

- (void)collectionView:(NSCollectionView *)cv didDeselectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
    if ([QLPreviewPanel sharedPreviewPanelExists] && [QLPreviewPanel sharedPreviewPanel].isVisible)
        [[QLPreviewPanel sharedPreviewPanel] reloadData];
}

- (NSMenu *)contextMenuForCollectionView:(NSCollectionView *)cv atPoint:(NSPoint)point {
    NSIndexPath *ip = [cv indexPathForItemAtPoint:point];
    if (ip) {
        NSSet *sel = cv.selectionIndexPaths;
        if (![sel containsObject:ip]) {
            cv.selectionIndexPaths = [NSSet setWithObject:ip];
        }
        FileEntry *entry = (ip.item < _entries.count) ? _entries[ip.item] : nil;
        return [self contextMenuForEntry:entry];
    }
    return [self contextMenuForEntry:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSCollectionViewDelegate (drag source)
// ─────────────────────────────────────────────────────────────────────────────

- (BOOL)collectionView:(NSCollectionView *)cv
    canDragItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths
               withEvent:(NSEvent *)event {
    return YES;
}

- (id<NSPasteboardWriting>)collectionView:(NSCollectionView *)cv
              pasteboardWriterForItemAtIndexPath:(NSIndexPath *)indexPath {
    NSUInteger idx = indexPath.item;
    if (idx < _entries.count)
        return [NSURL fileURLWithPath:_entries[idx].path];
    return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSCollectionViewDelegate (drag destination)
// ─────────────────────────────────────────────────────────────────────────────

- (NSDragOperation)collectionView:(NSCollectionView *)cv
                     validateDrop:(id<NSDraggingInfo>)info
                proposedIndexPath:(NSIndexPath *__nonnull *__nonnull)proposedIndexPath
                    dropOperation:(NSCollectionViewDropOperation *)proposedDropOperation {
    NSDragOperation mask = info.draggingSourceOperationMask;
    if (mask & NSDragOperationMove) return NSDragOperationMove;
    return NSDragOperationCopy;
}

- (BOOL)collectionView:(NSCollectionView *)cv
            acceptDrop:(id<NSDraggingInfo>)info
             indexPath:(NSIndexPath *)indexPath
         dropOperation:(NSCollectionViewDropOperation)dropOperation {
    NSArray<NSURL *> *urls = [info.draggingPasteboard
        readObjectsForClasses:@[[NSURL class]]
        options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    if (!urls.count) return NO;
    NSString *dstDir = _currentPath;
    if (dropOperation == NSCollectionViewDropOn && indexPath.item < _entries.count) {
        FileEntry *target = _entries[indexPath.item];
        if (target.isDir) dstDir = target.path;
    }
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *u in urls) [paths addObject:u.path];
    BOOL isMove = (info.draggingSourceOperationMask & NSDragOperationMove) != 0;
    [self performTransferFromPaths:paths toDir:dstDir isMove:isMove];
    return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSBrowserDelegate (column view)
// ─────────────────────────────────────────────────────────────────────────────

- (void)loadBrowserFromPath:(NSString *)rootPath {
    [_columnEntries removeAllObjects];
    [_columnPaths removeAllObjects];

    [_columnPaths addObject:rootPath];
    [_columnEntries addObject:[self entriesForPath:rootPath]];

    [_browser loadColumnZero];
}

- (NSMutableArray<FileEntry *> *)entriesForPath:(NSString *)path {
    NSMutableArray<FileEntry *> *result = [NSMutableArray array];
    ZigDirListing *listing = zig_list_directory(path.UTF8String);
    if (listing) {
        NSWorkspace *ws = [NSWorkspace sharedWorkspace];
        for (uint64_t i = 0; i < listing->count; i++) {
            ZigDirEntry e = listing->entries[i];
            if (!s_showHidden && e.name[0] == '.') continue;
            FileEntry *fe = [[FileEntry alloc] init];
            fe.name      = @(e.name);
            fe.path      = @(e.path);
            fe.isDir     = (BOOL)e.is_dir;
            fe.isSymlink = (BOOL)e.is_symlink;
            fe.size      = e.size;
            fe.mtime     = e.mtime;
            fe.icon      = [ws iconForFile:fe.path];
            fe.icon.size = NSMakeSize(16, 16);
            [result addObject:fe];
        }
        zig_free_dir_listing(listing);
    }
    [result sortUsingComparator:^NSComparisonResult(FileEntry *a, FileEntry *b) {
        if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return result;
}

// NSBrowser passive delegate: provide row count per column.
// For column > 0, load (or reload) entries based on the selected row in column-1.
- (NSInteger)browser:(NSBrowser *)browser numberOfRowsInColumn:(NSInteger)column {
    if (column > 0) {
        NSInteger prevCol = column - 1;
        NSInteger selRow  = [browser selectedRowInColumn:prevCol];
        if (selRow >= 0 && (NSUInteger)prevCol < _columnEntries.count) {
            NSMutableArray<FileEntry *> *prevEntries = _columnEntries[(NSUInteger)prevCol];
            if (selRow < (NSInteger)prevEntries.count) {
                FileEntry *fe = prevEntries[(NSUInteger)selRow];
                if (fe.isDir) {
                    NSString *expectedPath = fe.path;
                    // Check if we already have the correct data for this column
                    BOOL needsReload = ((NSUInteger)column >= _columnPaths.count ||
                                        ![_columnPaths[(NSUInteger)column] isEqualToString:expectedPath]);
                    if (needsReload) {
                        // Trim everything from this column onward
                        NSUInteger keepCount = (NSUInteger)column;
                        while (_columnEntries.count > keepCount) [_columnEntries removeLastObject];
                        while (_columnPaths.count > keepCount)   [_columnPaths removeLastObject];
                        [_columnEntries addObject:[self entriesForPath:expectedPath]];
                        [_columnPaths addObject:expectedPath];
                    }
                }
            }
        }
    }
    if ((NSUInteger)column < _columnEntries.count)
        return (NSInteger)_columnEntries[(NSUInteger)column].count;
    return 0;
}

// NSBrowser passive delegate: configure each cell
- (void)browser:(NSBrowser *)browser willDisplayCell:(NSBrowserCell *)cell
          atRow:(NSInteger)row column:(NSInteger)column {
    if ((NSUInteger)column >= _columnEntries.count) return;
    NSMutableArray<FileEntry *> *entries = _columnEntries[(NSUInteger)column];
    if (row >= (NSInteger)entries.count) return;
    FileEntry *fe = entries[(NSUInteger)row];
    cell.stringValue = fe.name;
    cell.image       = fe.icon;
    cell.leaf        = !fe.isDir;
}

// Single-click action — update currentPath and notify delegate
- (void)browserSingleClick:(NSBrowser *)browser {
    NSInteger col = browser.selectedColumn;
    if (col < 0 || (NSUInteger)col >= _columnEntries.count) return;
    NSInteger row = [browser selectedRowInColumn:col];
    if (row < 0) return;

    FileEntry *fe = _columnEntries[(NSUInteger)col][(NSUInteger)row];
    if (fe.isDir) {
        _currentPath = [fe.path copy];
        [self.delegate fileViewController:self didNavigateToPath:fe.path];
    } else {
        _currentPath = [_columnPaths[(NSUInteger)col] copy];
    }
    [self updateStatusBar];
}

- (void)browserDoubleAction:(NSBrowser *)browser {
    NSInteger col = browser.selectedColumn;
    NSInteger row = [browser selectedRowInColumn:col];
    if (col < 0 || row < 0) return;
    if ((NSUInteger)col >= _columnEntries.count) return;
    NSMutableArray<FileEntry *> *entries = _columnEntries[(NSUInteger)col];
    if ((NSUInteger)row >= entries.count) return;
    FileEntry *fe = entries[(NSUInteger)row];
    if (!fe.isDir) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:fe.path]];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Navigation
// ─────────────────────────────────────────────────────────────────────────────

- (IBAction)tableViewDoubleClicked:(id)sender {
    NSInteger row = _outlineView.clickedRow;
    if (row < 0) return;
    FileEntry *entry = [_outlineView itemAtRow:row];
    if (!entry) return;
    [self openEntry:entry];
}

- (void)collectionViewDidDoubleClick:(NSCollectionView *)cv atIndexPath:(NSIndexPath *)ip {
    if (ip.item < _entries.count)
        [self openEntry:_entries[ip.item]];
}

- (void)openEntry:(FileEntry *)e {
    if (!e) return;
    if (e.isDir) {
        [self loadPath:e.path];
        [self.delegate fileViewController:self didNavigateToPath:e.path];
    } else {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:e.path]];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Context menu (ContextMenuOutlineViewDelegate)
// ─────────────────────────────────────────────────────────────────────────────

- (NSMenu *)contextMenuForOutlineView:(NSOutlineView *)ov clickedRow:(NSInteger)row {
    FileEntry *entry = (row >= 0) ? [ov itemAtRow:row] : nil;
    if (row >= 0) {
        if (![ov.selectedRowIndexes containsIndex:(NSUInteger)row]) {
            [ov selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                byExtendingSelection:NO];
        }
    }
    return [self contextMenuForEntry:entry];
}

- (NSMenu *)contextMenuForEntry:(FileEntry *)entry {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    if (entry) {
        [[menu addItemWithTitle:@"Abrir"               action:@selector(openSelected:)     keyEquivalent:@""] setTarget:self];
        [menu addItem:[NSMenuItem separatorItem]];
        [[menu addItemWithTitle:@"Copiar"              action:@selector(copySelected:)     keyEquivalent:@""] setTarget:self];
        [[menu addItemWithTitle:@"Cortar"              action:@selector(cutSelected:)      keyEquivalent:@""] setTarget:self];
        [menu addItem:[NSMenuItem separatorItem]];
        [[menu addItemWithTitle:@"Renombrar"           action:@selector(renameSelected:)   keyEquivalent:@""] setTarget:self];
        [[menu addItemWithTitle:@"Obtener informacion" action:@selector(showInfoSelected:) keyEquivalent:@""] setTarget:self];
        [menu addItem:[NSMenuItem separatorItem]];
        // Compress / Uncompress
        {
            NSString *ext = entry.path.pathExtension.lowercaseString;
            BOOL isArchive = [ext isEqualToString:@"7z"] || [ext isEqualToString:@"zip"] ||
                             [ext isEqualToString:@"rar"] || [ext isEqualToString:@"tar"] ||
                             [ext isEqualToString:@"gz"] || [ext isEqualToString:@"bz2"] ||
                             [ext isEqualToString:@"xz"];
            if (isArchive) {
                [[menu addItemWithTitle:@"Descomprimir" action:@selector(uncompressSelected:) keyEquivalent:@""] setTarget:self];
            } else {
                [[menu addItemWithTitle:@"Comprimir" action:@selector(compressSelected:) keyEquivalent:@""] setTarget:self];
            }
            [[menu addItemWithTitle:@"Dividir en partes" action:@selector(splitSelected:) keyEquivalent:@""] setTarget:self];
        }
        [menu addItem:[NSMenuItem separatorItem]];
        [[menu addItemWithTitle:@"Mover a la papelera" action:@selector(deleteSelected:)  keyEquivalent:@""] setTarget:self];
        [menu addItem:[NSMenuItem separatorItem]];
    }
    NSMenuItem *paste = [menu addItemWithTitle:@"Pegar" action:@selector(pasteHere:) keyEquivalent:@""];
    paste.target = self;
    paste.keyEquivalentModifierMask = 0;

    // AppKit hides this item and shows it in place of "Pegar" while Option is
    // held. alternate = YES + matching keyEquivalent is the standard mechanism.
    NSMenuItem *moveHere = [menu addItemWithTitle:@"Trasladar aquí" action:@selector(moveHere:) keyEquivalent:@""];
    moveHere.target = self;
    moveHere.alternate = YES;
    moveHere.keyEquivalentModifierMask = NSEventModifierFlagOption;

    menu.delegate = self;

    [menu addItem:[NSMenuItem separatorItem]];
    [[menu addItemWithTitle:@"Nueva carpeta"    action:@selector(newFolderAction:)  keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:@"Mostrar ocultos"  action:@selector(toggleHidden:)     keyEquivalent:@""] setTarget:self];
    return menu;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSMenuDelegate
// ─────────────────────────────────────────────────────────────────────────────

// Proper enabled-state gate that respects autoenablesItems = YES.
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(pasteHere:) || item.action == @selector(moveHere:))
        return [self effectiveClipboardPaths].count > 0;
    if (item.action == @selector(toggleHidden:))
        item.title = s_showHidden ? @"Ocultar archivos ocultos" : @"Mostrar archivos ocultos";
    return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Clipboard actions
// ─────────────────────────────────────────────────────────────────────────────

// Returns the internal clipboard if set, otherwise falls back to file URLs on
// the system pasteboard (e.g. files copied from Finder or another app).
- (NSArray<NSString *> *)effectiveClipboardPaths {
    if (_clipboardPaths.count) return _clipboardPaths;
    NSArray<NSURL *> *urls = [[NSPasteboard generalPasteboard]
        readObjectsForClasses:@[[NSURL class]]
        options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    if (!urls.count) return nil;
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *u in urls) [paths addObject:u.path];
    return paths;
}

- (NSArray<NSString *> *)selectedPaths {
    NSMutableArray *paths = [NSMutableArray array];
    if (_viewMode == FileViewModeIcon) {
        for (NSIndexPath *ip in _collectionView.selectionIndexPaths) {
            NSUInteger idx = ip.item;
            if (idx < _entries.count)
                [paths addObject:_entries[idx].path];
        }
    } else if (_viewMode == FileViewModeColumns) {
        NSInteger col = _browser.selectedColumn;
        if (col >= 0 && (NSUInteger)col < _columnEntries.count) {
            NSIndexSet *rows = [_browser selectedRowIndexesInColumn:col];
            NSMutableArray<FileEntry *> *colEntries = _columnEntries[(NSUInteger)col];
            [rows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
                if (idx < colEntries.count)
                    [paths addObject:colEntries[idx].path];
            }];
        }
    } else {
        [_outlineView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            FileEntry *e = [self->_outlineView itemAtRow:idx];
            if (e) [paths addObject:e.path];
        }];
    }
    return paths;
}

- (IBAction)openSelected:(id)sender {
    NSArray<NSString *> *paths = [self selectedPaths];
    for (NSString *path in paths) {
        NSUInteger idx = [_entries indexOfObjectPassingTest:^BOOL(FileEntry *e, NSUInteger i, BOOL *stop) {
            return [e.path isEqualToString:path];
        }];
        if (idx == NSNotFound) continue;
        FileEntry *e = _entries[idx];
        if (e.isDir) {
            [self loadPath:e.path];
            [self.delegate fileViewController:self didNavigateToPath:e.path];
            return;
        } else {
            [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:e.path]];
        }
    }
}

- (IBAction)copySelected:(id)sender {
    _clipboardPaths = [self selectedPaths];
    _clipboardOp    = ClipboardOperationCopy;
    [self reloadAllViews];
}

- (IBAction)cutSelected:(id)sender {
    _clipboardPaths = [self selectedPaths];
    _clipboardOp    = ClipboardOperationCut;
    [self reloadAllViews];
}

- (IBAction)pasteHere:(id)sender {
    NSArray<NSString *> *paths = [self effectiveClipboardPaths];
    if (!paths.count) return;
    BOOL isMove = (_clipboardPaths.count > 0) && (_clipboardOp == ClipboardOperationCut);
    [self performTransferFromPaths:paths toDir:_currentPath isMove:isMove];
    if (isMove) {
        _clipboardPaths = nil;
        _clipboardOp    = ClipboardOperationNone;
        [self reloadAllViews];
    }
}

- (void)performTransferFromPaths:(NSArray<NSString *> *)paths
                           toDir:(NSString *)dstDir
                          isMove:(BOOL)isMove {
    // Build the cPaths array using heap-copies of the UTF-8 strings so the
    // pointers remain valid across runModal's autorelease-pool drains and
    // across the async Zig thread. Zig also dupeZ's them, but being explicit
    // here avoids any window where the NSString backing store could move.
    NSUInteger count = paths.count;
    const char **cPaths = malloc(count * sizeof(char *));
    if (!cPaths) return;
    char **owned = malloc(count * sizeof(char *)); // heap copies we free later
    if (!owned) { free(cPaths); return; }
    for (NSUInteger i = 0; i < count; i++) {
        owned[i] = strdup(paths[i].UTF8String);
        cPaths[i] = owned[i];
    }

    BOOL collision = zig_check_collision(cPaths, (uint64_t)count, dstDir.UTF8String);
    if (collision) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText     = @"Ya existe un elemento con ese nombre";
        alert.informativeText = @"Deseas reemplazar los archivos existentes?";
        [alert addButtonWithTitle:@"Reemplazar"];
        [alert addButtonWithTitle:@"Cancelar"];
        [alert addButtonWithTitle:@"Mantener ambos"];
        NSModalResponse resp = [alert runModal];
        if (resp == NSAlertSecondButtonReturn) {
            for (NSUInteger i = 0; i < count; i++) free(owned[i]);
            free(owned); free(cPaths); return;
        }
        [self startTransfer:cPaths owned:owned count:count dstDir:dstDir
                  overwrite:(resp == NSAlertFirstButtonReturn) isMove:isMove];
    } else {
        [self startTransfer:cPaths owned:owned count:count dstDir:dstDir
                  overwrite:NO isMove:isMove];
    }
}

static void progressCb(void *ctx, double progress, uint64_t bytesDone, uint64_t total, double speed, int64_t eta) {
    ProgressWindowController *pwc = (__bridge ProgressWindowController *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        [pwc updateProgress:progress bytesTransferred:bytesDone totalBytes:total speed:speed etaSecs:eta];
    });
}

static void doneCb(void *ctx, bool success, const char *errMsg) {
    // __bridge_transfer moves ownership from the void* retain into ARC.
    // The block's capture of pwc keeps the object alive until dispatch runs.
    ProgressWindowController *pwc = (__bridge_transfer ProgressWindowController *)ctx;
    NSString *msgStr = errMsg ? [NSString stringWithUTF8String:errMsg] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [pwc finishWithSuccess:success errorMessage:msgStr];
    });
    // pwc goes out of scope here; block holds the only remaining strong ref.
}

- (void)startTransfer:(const char **)cPaths
                owned:(char **)owned
                count:(NSUInteger)count
               dstDir:(NSString *)dstDir
            overwrite:(BOOL)overwrite
               isMove:(BOOL)isMove {
    __weak typeof(self) wself = self;
    ProgressWindowController *pwc = [[ProgressWindowController alloc]
                                        initWithTitle:isMove ? @"Moviendo" : @"Copiando"
                                    destinationFolder:dstDir
                                      refreshCallback:^{ [wself loadPath:wself.currentPath]; }];
    [pwc showWindow:nil];
    // __bridge_retained bumps retain count by 1; doneCb will consume it
    // with __bridge_transfer, giving the block sole ownership up to dealloc.
    void *ctx = (__bridge_retained void *)pwc;
    NSString *rsync = [self rsyncPath];
    if (!rsync) {
        [self showErrorMessage:@"No se encontró el binario rsync"];
        return;
    }
    if (isMove)
        zig_move_files(rsync.UTF8String, cPaths, (uint64_t)count, dstDir.UTF8String, overwrite, ctx, progressCb, doneCb);
    else
        zig_copy_files(rsync.UTF8String, cPaths, (uint64_t)count, dstDir.UTF8String, overwrite, ctx, progressCb, doneCb);
    // Zig has already dupeZ'd every string; free our heap copies.
    for (NSUInteger i = 0; i < count; i++) free(owned[i]);
    free(owned);
    free(cPaths);
}

- (IBAction)deleteSelected:(id)sender {
    NSArray<NSString *> *paths = [self selectedPaths];
    if (!paths.count) return;

    // Check if the volume supports Trash by testing trashItemAtURL on the first item.
    BOOL volumeSupportsTrash = YES;
    {
        NSURL *testURL = [NSURL fileURLWithPath:paths.firstObject];
        // Check if the volume supports trash by looking at the volume root.
        // Boot volume (/) always supports trash. External volumes need .Trashes.
        NSURL *volumeURL = nil;
        [testURL getResourceValue:&volumeURL forKey:NSURLVolumeURLKey error:nil];
        NSString *volumePath = volumeURL ? volumeURL.path : nil;
        if (volumePath && ![volumePath isEqualToString:@"/"]) {
            NSString *trashes = [volumePath stringByAppendingPathComponent:@".Trashes"];
            NSFileManager *fm = [NSFileManager defaultManager];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:trashes isDirectory:&isDir] || !isDir) {
                volumeSupportsTrash = NO;
            }
        }
    }

    if (volumeSupportsTrash) {
        [self confirmTrashDelete:paths];
    } else {
        [self confirmPermanentDelete:paths];
    }
}

- (void)confirmTrashDelete:(NSArray<NSString *> *)paths {
    NSAlert *alert = [[NSAlert alloc] init];
    if (paths.count == 1)
        alert.messageText = [NSString stringWithFormat:@"Mover \"%@\" a la papelera?",
                             paths.firstObject.lastPathComponent];
    else
        alert.messageText = [NSString stringWithFormat:@"Mover %lu elementos a la papelera?",
                             (unsigned long)paths.count];
    [alert addButtonWithTitle:@"Mover a la papelera"];
    [alert addButtonWithTitle:@"Cancelar"];
    alert.alertStyle = NSAlertStyleWarning;
    __weak typeof(self) wself = self;
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error = nil;
        for (NSString *path in paths) {
            NSURL *url = [NSURL fileURLWithPath:path];
            if (![fm trashItemAtURL:url resultingItemURL:nil error:&error]) {
                // Trash failed — fall back to offering permanent deletion
                [wself confirmPermanentDelete:paths];
                return;
            }
        }
        [wself loadPath:wself.currentPath];
    }];
}

- (void)confirmPermanentDelete:(NSArray<NSString *> *)paths {
    NSAlert *alert = [[NSAlert alloc] init];
    if (paths.count == 1)
        alert.messageText = [NSString stringWithFormat:
            @"\"%@\" se eliminará permanentemente.",
            paths.firstObject.lastPathComponent];
    else
        alert.messageText = [NSString stringWithFormat:
            @"%lu elementos se eliminarán permanentemente.",
            (unsigned long)paths.count];
    alert.informativeText = @"Este volumen no tiene papelera. Esta acción no se puede deshacer.";
    [alert addButtonWithTitle:@"Eliminar"];
    [alert addButtonWithTitle:@"Cancelar"];
    alert.alertStyle = NSAlertStyleCritical;
    // Make the "Eliminar" button visually destructive
    alert.buttons.firstObject.hasDestructiveAction = YES;
    __weak typeof(self) wself = self;
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;
        NSUInteger count = paths.count;
        const char **cPaths = malloc(count * sizeof(char *));
        for (NSUInteger i = 0; i < count; i++)
            cPaths[i] = paths[i].UTF8String;
        char errBuf[512] = {0};
        BOOL ok = zig_delete_files(cPaths, (uint64_t)count, errBuf, sizeof(errBuf));
        free(cPaths);
        if (!ok) {
            [wself showErrorMessage:@(errBuf)];
        }
        [wself loadPath:wself.currentPath];
    }];
}

- (IBAction)renameSelected:(id)sender {
    NSInteger row = _outlineView.selectedRow;
    if (row < 0) return;
    _renameRow = row;
    // Delay activation so the window fully settles after context-menu dismiss.
    [self performSelector:@selector(beginInlineRename) withObject:nil afterDelay:0.15];
}

- (void)beginInlineRename {
    if (_renameRow < 0) return;
    NSInteger nameCol = [_outlineView columnWithIdentifier:@"name"];
    if (nameCol < 0) { _renameRow = -1; return; }
    NSTableCellView *cell = [_outlineView viewAtColumn:nameCol
                                                   row:_renameRow
                                       makeIfNecessary:YES];
    if (!cell) { _renameRow = -1; return; }
    cell.textField.editable   = YES;
    cell.textField.selectable = YES;
    cell.textField.delegate   = self;
    // Use the outline view's own editing path to properly install
    // the field editor within the cell.
    [_outlineView editColumn:nameCol row:_renameRow withEvent:nil select:YES];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)sel {
    if (_renameRow < 0) return NO;
    if (sel == @selector(cancelOperation:)) {
        // Escape – cancel rename, restore original name
        FileEntry *entry = [_outlineView itemAtRow:_renameRow];
        NSTextField *tf = (NSTextField *)control;
        tf.stringValue = entry ? entry.name : @"";
        tf.editable    = NO;
        tf.selectable  = NO;
        _renameRow = -1;
        [self.view.window makeFirstResponder:_outlineView];
        return YES;
    }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
    if (_renameRow < 0) return;
    NSTextField *tf  = note.object;
    NSString *newName = tf.stringValue;
    tf.editable   = NO;
    tf.selectable = NO;
    FileEntry *entry = [_outlineView itemAtRow:_renameRow];
    _renameRow = -1;
    if (!entry || !newName.length || [newName isEqualToString:entry.name]) return;
    NSString *newPath = [entry.path.stringByDeletingLastPathComponent
                         stringByAppendingPathComponent:newName];
    char errBuf[512] = {0};
    if (!zig_rename(entry.path.UTF8String, newPath.UTF8String, errBuf, sizeof(errBuf)))
        [self showErrorMessage:@(errBuf)];
    else
        [self loadPath:_currentPath];
}

- (IBAction)showInfoSelected:(id)sender {
    NSArray<NSString *> *paths = [self selectedPaths];
    if (!paths.count) return;

    // Show info for the first selected item
    NSString *filePath = paths.firstObject;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
    if (!attrs) return;

    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    NSString *fileName = filePath.lastPathComponent;
    BOOL isDir = [attrs[NSFileType] isEqualToString:NSFileTypeDirectory];

    // Kind
    NSString *kind;
    if (isDir) {
        kind = @"Carpeta";
    } else {
        kind = [self kindForPath:filePath];
    }

    // Size
    NSString *sizeStr;
    if (isDir) {
        // Calculate folder size recursively
        uint64_t totalSize = 0;
        NSUInteger fileCount = 0;
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:fileURL
                                    includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsRegularFileKey]
                                                       options:0
                                                  errorHandler:nil];
        for (NSURL *url in enumerator) {
            NSNumber *isFile = nil;
            [url getResourceValue:&isFile forKey:NSURLIsRegularFileKey error:nil];
            if (isFile.boolValue) {
                NSNumber *fileSize = nil;
                [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
                totalSize += fileSize.unsignedLongLongValue;
                fileCount++;
            }
        }
        sizeStr = [NSString stringWithFormat:@"%@ (%lu archivos)",
                   [self formattedSize:totalSize], (unsigned long)fileCount];
    } else {
        uint64_t bytes = [attrs[NSFileSize] unsignedLongLongValue];
        sizeStr = [NSString stringWithFormat:@"%@ (%llu bytes)",
                   [self formattedSize:bytes], bytes];
    }

    // Dates
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateStyle = NSDateFormatterLongStyle;
    df.timeStyle = NSDateFormatterMediumStyle;

    NSString *createdStr  = [df stringFromDate:attrs[NSFileCreationDate]] ?: @"-";
    NSString *modifiedStr = [df stringFromDate:attrs[NSFileModificationDate]] ?: @"-";

    // Permissions
    NSUInteger posix = [attrs[NSFilePosixPermissions] unsignedIntegerValue];
    NSString *permsStr = [NSString stringWithFormat:@"%c%c%c%c%c%c%c%c%c",
        (posix & 0400) ? 'r' : '-', (posix & 0200) ? 'w' : '-', (posix & 0100) ? 'x' : '-',
        (posix & 0040) ? 'r' : '-', (posix & 0020) ? 'w' : '-', (posix & 0010) ? 'x' : '-',
        (posix & 0004) ? 'r' : '-', (posix & 0002) ? 'w' : '-', (posix & 0001) ? 'x' : '-'];

    // Icon
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:filePath];
    [icon setSize:NSMakeSize(64, 64)];

    // Build the info panel
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = fileName;
    alert.icon = icon;

    NSString *info = [NSString stringWithFormat:
        @"Tipo: %@\n\n"
        @"Tamaño: %@\n\n"
        @"Ubicación: %@\n\n"
        @"Creado: %@\n\n"
        @"Modificado: %@\n\n"
        @"Permisos: %@",
        kind, sizeStr, filePath.stringByDeletingLastPathComponent,
        createdStr, modifiedStr, permsStr];

    alert.informativeText = info;
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Mostrar en Finder"];

    NSModalResponse response = [alert runModal];
    if (response == NSAlertSecondButtonReturn) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[fileURL]];
    }
}

- (IBAction)moveHere:(id)sender {
    NSArray<NSString *> *paths = [self effectiveClipboardPaths];
    if (!paths.count) return;
    [self performTransferFromPaths:paths toDir:_currentPath isMove:YES];
    _clipboardPaths = nil;
    _clipboardOp    = ClipboardOperationNone;
    [self reloadAllViews];
}

- (IBAction)compressSelected:(id)sender {
    NSArray<NSString *> *paths = [self selectedPaths];
    if (!paths.count) return;

    // Archive name: based on the first selected item
    NSString *baseName = paths.firstObject.lastPathComponent.stringByDeletingPathExtension;
    NSString *archive  = [_currentPath stringByAppendingPathComponent:
                          [baseName stringByAppendingString:@".7z"]];

    NSString *sevenzzPath = [self sevenzzPath];
    if (!sevenzzPath) {
        [self showErrorMessage:@"No se encontró el binario 7zz"];
        return;
    }

    NSUInteger count = paths.count;
    const char **cPaths = malloc(count * sizeof(char *));
    char **owned = malloc(count * sizeof(char *));
    if (!cPaths || !owned) { free(cPaths); free(owned); return; }
    for (NSUInteger i = 0; i < count; i++) {
        owned[i] = strdup(paths[i].UTF8String);
        cPaths[i] = owned[i];
    }

    __weak typeof(self) wself = self;
    ProgressWindowController *pwc = [[ProgressWindowController alloc]
                                        initWithTitle:@"Comprimiendo"
                                    destinationFolder:_currentPath
                                      refreshCallback:^{ [wself loadPath:wself.currentPath]; }];
    [pwc showWindow:nil];
    void *ctx = (__bridge_retained void *)pwc;
    zig_compress(sevenzzPath.UTF8String, cPaths, (uint64_t)count,
                 archive.UTF8String, ctx, progressCb, doneCb);
    for (NSUInteger i = 0; i < count; i++) free(owned[i]);
    free(owned);
    free(cPaths);
}

- (IBAction)splitSelected:(id)sender {
    NSArray<NSString *> *paths = [self selectedPaths];
    if (!paths.count) return;

    NSString *sevenzzPath = [self sevenzzPath];
    if (!sevenzzPath) {
        [self showErrorMessage:@"No se encontró el binario 7zz"];
        return;
    }

    // Input panel asking for the part size in MB
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    field.placeholderString = @"Ej: 100";
    field.font = [NSFont systemFontOfSize:13];
    field.stringValue = @"100";

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText     = @"Dividir en partes";
    alert.informativeText = @"Tamaño de cada parte en MB:";
    [alert addButtonWithTitle:@"Dividir"];
    [alert addButtonWithTitle:@"Cancelar"];
    alert.accessoryView = field;

    NSWindow *parentWin = self.view.window;
    [alert beginSheetModalForWindow:parentWin completionHandler:^(NSModalResponse resp) {
        if (resp != NSAlertFirstButtonReturn) return;

        NSString *input = [field.stringValue
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSInteger sizeMB = input.integerValue;
        if (sizeMB <= 0) {
            [self showErrorMessage:@"El tamaño debe ser un número mayor que 0"];
            return;
        }

        // Detect if all selected files are already compressed archives
        NSSet *archiveExts = [NSSet setWithObjects:@"7z", @"zip", @"rar", @"tar",
                              @"gz", @"bz2", @"xz", @"tgz", @"tbz2", @"txz", nil];
        BOOL storeOnly = YES;
        for (NSString *p in paths) {
            if (![archiveExts containsObject:p.pathExtension.lowercaseString]) {
                storeOnly = NO;
                break;
            }
        }

        NSString *baseName = paths.firstObject.lastPathComponent.stringByDeletingPathExtension;
        NSString *archive  = [self->_currentPath stringByAppendingPathComponent:
                              [baseName stringByAppendingString:@".7z"]];

        NSUInteger count = paths.count;
        const char **cPaths = malloc(count * sizeof(char *));
        char **owned = malloc(count * sizeof(char *));
        if (!cPaths || !owned) { free(cPaths); free(owned); return; }
        for (NSUInteger i = 0; i < count; i++) {
            owned[i] = strdup(paths[i].UTF8String);
            cPaths[i] = owned[i];
        }

        __weak typeof(self) wself = self;
        ProgressWindowController *pwc = [[ProgressWindowController alloc]
                                            initWithTitle:@"Dividiendo"
                                        destinationFolder:self->_currentPath
                                          refreshCallback:^{ [wself loadPath:wself.currentPath]; }];
        [pwc showWindow:nil];
        void *ctx = (__bridge_retained void *)pwc;
        zig_compress_split(sevenzzPath.UTF8String, cPaths, (uint64_t)count,
                           archive.UTF8String, (uint32_t)sizeMB, storeOnly,
                           ctx, progressCb, doneCb);
        for (NSUInteger i = 0; i < count; i++) free(owned[i]);
        free(owned);
        free(cPaths);
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        [alert.window makeFirstResponder:field];
    });
}

- (IBAction)uncompressSelected:(id)sender {
    NSInteger row = _outlineView.selectedRow;
    if (row < 0) return;
    FileEntry *entry = [_outlineView itemAtRow:row];
    if (!entry) return;

    NSString *sevenzzPath = [self sevenzzPath];
    if (!sevenzzPath) {
        [self showErrorMessage:@"No se encontró el binario 7zz"];
        return;
    }

    // Extract to a folder with the archive's base name
    NSString *dstDir = [_currentPath stringByAppendingPathComponent:
                        entry.name.stringByDeletingPathExtension];

    __weak typeof(self) wself = self;
    ProgressWindowController *pwc = [[ProgressWindowController alloc]
                                        initWithTitle:@"Descomprimiendo"
                                    destinationFolder:_currentPath
                                      refreshCallback:^{ [wself loadPath:wself.currentPath]; }];
    [pwc showWindow:nil];
    void *ctx = (__bridge_retained void *)pwc;
    zig_uncompress(sevenzzPath.UTF8String, entry.path.UTF8String,
                   dstDir.UTF8String, ctx, progressCb, doneCb);
}

- (NSString *)sevenzzPath {
    NSString *bundled = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"7zz"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:bundled]) return bundled;
    // Fallback: check bin/7zz relative to executable (for zig build run)
    // Executable is at <project>/zig-out/bin/rs_2finder → go up 2 levels to project root
    NSString *exeDir = NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent;
    NSString *dev = [[exeDir stringByAppendingPathComponent:@"../../bin/7zz"] stringByStandardizingPath];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:dev]) return dev;
    return nil;
}

- (NSString *)rsyncPath {
    NSString *bundled = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"rsync"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:bundled]) return bundled;
    // Fallback: check bin/rsync relative to executable (for zig build run)
    NSString *exeDir = NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent;
    NSString *dev = [[exeDir stringByAppendingPathComponent:@"../../bin/rsync"] stringByStandardizingPath];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:dev]) return dev;
    return nil;
}

- (IBAction)newFolderAction:(id)sender  { [self createNewFolderInPath:_currentPath]; }
- (IBAction)toggleHidden:(id)sender     { s_showHidden = !s_showHidden; [self loadPath:_currentPath]; }

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSDraggingSource
// ─────────────────────────────────────────────────────────────────────────────

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationCopy | NSDragOperationMove;
}

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)ov
                pasteboardWriterForItem:(id)item {
    FileEntry *entry = (FileEntry *)item;
    return [NSURL fileURLWithPath:entry.path];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Drag destination
// ─────────────────────────────────────────────────────────────────────────────

- (NSDragOperation)outlineView:(NSOutlineView *)ov
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)index {
    if (item && !((FileEntry *)item).isDir) return NSDragOperationNone;
    NSDragOperation mask = info.draggingSourceOperationMask;
    if (mask & NSDragOperationMove) return NSDragOperationMove;
    return NSDragOperationCopy;
}

- (BOOL)outlineView:(NSOutlineView *)ov
         acceptDrop:(id<NSDraggingInfo>)info
               item:(id)item
         childIndex:(NSInteger)index {
    NSArray<NSURL *> *urls = [info.draggingPasteboard
        readObjectsForClasses:@[[NSURL class]]
        options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    if (!urls.count) return NO;
    NSString *dstDir = item ? ((FileEntry *)item).path : _currentPath;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *u in urls) [paths addObject:u.path];
    BOOL isMove = (info.draggingSourceOperationMask & NSDragOperationMove) != 0;
    [self performTransferFromPaths:paths toDir:dstDir isMove:isMove];
    return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Helpers
// ─────────────────────────────────────────────────────────────────────────────

- (void)showErrorMessage:(NSString *)msg {
    NSAlert *alert   = [[NSAlert alloc] init];
    alert.messageText     = @"Error";
    alert.informativeText = msg ?: @"Operacion fallida";
    alert.alertStyle      = NSAlertStyleCritical;
    if (self.view.window)
        [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
    else
        [alert runModal];
}

- (NSString *)formattedSize:(uint64_t)bytes {
    double v = (double)bytes;
    if (v < 1024)           return [NSString stringWithFormat:@"%.0f B",   v];
    if (v < 1048576)        return [NSString stringWithFormat:@"%.1f KB",  v/1024.0];
    if (v < 1073741824)     return [NSString stringWithFormat:@"%.1f MB",  v/1048576.0];
    return [NSString stringWithFormat:@"%.2f GB", v/1073741824.0];
}

- (NSString *)formattedDate:(int64_t)unix {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)unix];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateStyle = NSDateFormatterMediumStyle;
    df.timeStyle = NSDateFormatterShortStyle;
    return [df stringFromDate:date];
}

- (NSString *)kindForPath:(NSString *)path {
    NSURL *url     = [NSURL fileURLWithPath:path];
    NSString *utiStr = nil;
    [url getResourceValue:&utiStr forKey:NSURLTypeIdentifierKey error:nil];
    if (utiStr) {
        UTType *type = [UTType typeWithIdentifier:utiStr];
        if (type.localizedDescription) return type.localizedDescription;
    }
    NSString *ext = path.pathExtension.uppercaseString;
    return ext.length ? [NSString stringWithFormat:@"Archivo %@", ext] : @"Archivo";
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Quick Look (QLPreviewPanelController / DataSource)
// ─────────────────────────────────────────────────────────────────────────────

// AppKit asks each responder in the chain whether it can control the panel.
- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel *)panel { return YES; }

- (void)beginPreviewPanelControl:(QLPreviewPanel *)panel {
    panel.dataSource = self;
    panel.delegate   = self;
}

- (void)endPreviewPanelControl:(QLPreviewPanel *)panel {
    panel.dataSource = nil;
    panel.delegate   = nil;
}

// QLPreviewPanelDataSource
- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel {
    NSArray *sel = [self selectedPaths];
    return (NSInteger)sel.count;
}

- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index {
    NSArray *sel = [self selectedPaths];
    if (index < (NSInteger)sel.count)
        return [NSURL fileURLWithPath:sel[(NSUInteger)index]];
    return nil;
}

// QLPreviewPanelDelegate – forward arrow keys to the file view so the user
// can navigate the list while the preview panel is visible.
- (BOOL)previewPanel:(QLPreviewPanel *)panel handleEvent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown) {
        unichar c = [event.characters characterAtIndex:0];
        if (c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey ||
            c == NSLeftArrowFunctionKey || c == NSRightArrowFunctionKey) {
            NSView *target = nil;
            switch (_viewMode) {
                case FileViewModeIcon:    target = _collectionView; break;
                case FileViewModeColumns: target = _browser;        break;
                default:                  target = _outlineView;    break;
            }
            [target keyDown:event];
            return YES;
        }
        if (c == ' ') {
            [panel orderOut:nil];
            return YES;
        }
    }
    return NO;
}

// Keep the panel in sync when the selection changes.
- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    if ([QLPreviewPanel sharedPreviewPanelExists] && [QLPreviewPanel sharedPreviewPanel].isVisible)
        [[QLPreviewPanel sharedPreviewPanel] reloadData];
}

@end
