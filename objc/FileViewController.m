// FileViewController.m
#import "FileViewController.h"
#import "ProgressWindowController.h"
#import "bridge.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Quartz/Quartz.h>

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
@end
@implementation FileEntry @end

// ─────────────────────────────────────────────────────────────────────────────
// ContextMenuTableView – NSTableView subclass that supports per-row context menus
// ─────────────────────────────────────────────────────────────────────────────

@protocol ContextMenuTableViewDelegate <NSTableViewDelegate>
@optional
- (NSMenu *)contextMenuForTableView:(NSTableView *)tv clickedRow:(NSInteger)row;
@end

@interface ContextMenuTableView : NSTableView @end
@implementation ContextMenuTableView
- (NSMenu *)menuForEvent:(NSEvent *)event {
    CGPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:loc];
    id<ContextMenuTableViewDelegate> d = (id<ContextMenuTableViewDelegate>)self.delegate;
    if ([d respondsToSelector:@selector(contextMenuForTableView:clickedRow:)])
        return [d contextMenuForTableView:self clickedRow:row];
    return [super menuForEvent:event];
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

@interface FileViewController () <NSTableViewDataSource,
                                  ContextMenuTableViewDelegate,
                                  NSDraggingSource,
                                  NSTextFieldDelegate,
                                  NSMenuDelegate,
                                  QLPreviewPanelDataSource,
                                  QLPreviewPanelDelegate>
@property (nonatomic, strong) NSScrollView              *scrollView;
@property (nonatomic, strong) ContextMenuTableView      *tableView;
@property (nonatomic, strong) NSMutableArray<FileEntry *> *entries;
@property (nonatomic, copy)   NSString                 *currentPath;   // also satisfies the readonly public decl
@property (nonatomic, strong) NSArray<NSString *>      *clipboardPaths;
@property (nonatomic)         ClipboardOperation         clipboardOp;
@property (nonatomic, strong) NSTextField              *renameField;
@property (nonatomic)         NSInteger                  renameRow;
@end

@implementation FileViewController

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Init / View
// ─────────────────────────────────────────────────────────────────────────────

- (instancetype)initWithPath:(NSString *)path {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _entries     = [NSMutableArray array];
    _clipboardOp = ClipboardOperationNone;
    _renameRow   = -1;
    _currentPath = [path copy];
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

    // Table view
    _tableView = [[ContextMenuTableView alloc] initWithFrame:NSZeroRect];
    _tableView.allowsMultipleSelection = YES;
    _tableView.allowsColumnResizing    = YES;
    _tableView.allowsColumnReordering  = NO;
    _tableView.rowSizeStyle            = NSTableViewRowSizeStyleMedium;
    _tableView.gridStyleMask           = NSTableViewSolidHorizontalGridLineMask;
    _tableView.dataSource              = self;
    _tableView.delegate                = self;
    [_tableView setDoubleAction:@selector(tableViewDoubleClicked:)];

    // Drag destination
    [_tableView registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    _tableView.draggingDestinationFeedbackStyle = NSTableViewDraggingDestinationFeedbackStyleRegular;

    // Columns
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
        [_tableView addTableColumn:col];
    }

    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.hasVerticalScroller   = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.documentView          = _tableView;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor     constraintEqualToAnchor:self.view.topAnchor],
        [_scrollView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor  constraintEqualToAnchor:statusLabel.topAnchor constant:-2],
        [statusLabel.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [statusLabel.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor constant:-4],
        [statusLabel.heightAnchor   constraintEqualToConstant:18],
    ]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (_currentPath) [self loadPath:_currentPath];
}

- (void)keyDown:(NSEvent *)event {
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
    _currentPath = [path copy];
    [_entries removeAllObjects];

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
            [_entries addObject:fe];
        }
        zig_free_dir_listing(listing);
    }
    [_tableView reloadData];
    [self updateStatusBar];
}

- (void)updateStatusBar {
    NSTextField *label = (NSTextField *)[self.view viewWithTag:999];
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
#pragma mark – NSTableViewDataSource
// ─────────────────────────────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)_entries.count;
}

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    return _entries[(NSUInteger)row];
}

- (void)tableView:(NSTableView *)tv sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old {
    NSSortDescriptor *sd = tv.sortDescriptors.firstObject;
    if (!sd) return;
    [_entries sortUsingComparator:^NSComparisonResult(FileEntry *a, FileEntry *b) {
        NSComparisonResult r = NSOrderedSame;
        if ([sd.key isEqualToString:@"name"])      r = [a.name localizedCaseInsensitiveCompare:b.name];
        else if ([sd.key isEqualToString:@"size"]) r = [@(a.size)  compare:@(b.size)];
        else if ([sd.key isEqualToString:@"date"]) r = [@(a.mtime) compare:@(b.mtime)];
        else if ([sd.key isEqualToString:@"kind"]) r = [@(a.isDir) compare:@(b.isDir)];
        return sd.ascending ? r : -r;
    }];
    [tv reloadData];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSTableViewDelegate (cell views)
// ─────────────────────────────────────────────────────────────────────────────

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    FileEntry *entry = _entries[(NSUInteger)row];
    NSString  *ident = col.identifier;

    if ([ident isEqualToString:@"name"]) {
        NSTableCellView *cell = [tv makeViewWithIdentifier:@"NameCell" owner:self];
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

    NSTableCellView *cell = [tv makeViewWithIdentifier:@"BasicCell" owner:self];
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
#pragma mark – Navigation
// ─────────────────────────────────────────────────────────────────────────────

- (IBAction)tableViewDoubleClicked:(id)sender {
    NSInteger row = _tableView.clickedRow;
    if (row < 0) return;
    FileEntry *e = _entries[(NSUInteger)row];
    if (e.isDir) {
        [self loadPath:e.path];
        [self.delegate fileViewController:self didNavigateToPath:e.path];
    } else {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:e.path]];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Context menu (ContextMenuTableViewDelegate)
// ─────────────────────────────────────────────────────────────────────────────

- (NSMenu *)contextMenuForTableView:(NSTableView *)tv clickedRow:(NSInteger)row {
    if (row >= 0) {
        // Only change selection if the clicked row is not already selected
        // (preserves multi-selection for context menu actions)
        if (![tv.selectedRowIndexes containsIndex:(NSUInteger)row]) {
            [tv selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                byExtendingSelection:NO];
        }
    }
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    if (row >= 0) {
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
            FileEntry *entry = _entries[(NSUInteger)row];
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
    [_tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [paths addObject:self.entries[idx].path];
    }];
    return paths;
}

- (IBAction)openSelected:(id)sender {
    [_tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        FileEntry *e = self.entries[idx];
        if (e.isDir) {
            [self loadPath:e.path];
            [self.delegate fileViewController:self didNavigateToPath:e.path];
            *stop = YES;
        } else {
            [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:e.path]];
        }
    }];
}

- (IBAction)copySelected:(id)sender {
    _clipboardPaths = [self selectedPaths];
    _clipboardOp    = ClipboardOperationCopy;
    [_tableView reloadData];
}

- (IBAction)cutSelected:(id)sender {
    _clipboardPaths = [self selectedPaths];
    _clipboardOp    = ClipboardOperationCut;
    [_tableView reloadData];
}

- (IBAction)pasteHere:(id)sender {
    NSArray<NSString *> *paths = [self effectiveClipboardPaths];
    if (!paths.count) return;
    BOOL isMove = (_clipboardPaths.count > 0) && (_clipboardOp == ClipboardOperationCut);
    [self performTransferFromPaths:paths toDir:_currentPath isMove:isMove];
    if (isMove) {
        _clipboardPaths = nil;
        _clipboardOp    = ClipboardOperationNone;
        [_tableView reloadData];
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
    if (isMove)
        zig_move_files(cPaths, (uint64_t)count, dstDir.UTF8String, overwrite, ctx, progressCb, doneCb);
    else
        zig_copy_files(cPaths, (uint64_t)count, dstDir.UTF8String, overwrite, ctx, progressCb, doneCb);
    // Zig has already dupeZ'd every string; free our heap copies.
    for (NSUInteger i = 0; i < count; i++) free(owned[i]);
    free(owned);
    free(cPaths);
}

- (IBAction)deleteSelected:(id)sender {
    NSArray<NSString *> *paths = [self selectedPaths];
    if (!paths.count) return;
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
                [wself showErrorMessage:error.localizedDescription];
                return;
            }
        }
        [wself loadPath:wself.currentPath];
    }];
}

- (IBAction)renameSelected:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row < 0) return;
    FileEntry *entry = _entries[(NSUInteger)row];
    NSRect rowRect = [_tableView rectOfRow:row];
    NSRect nameRect = rowRect;
    nameRect.origin.x   += 26;
    nameRect.size.width -= 26;
    nameRect.size.height = 22;
    _renameRow   = row;
    _renameField = [[NSTextField alloc] initWithFrame:
        [_tableView.enclosingScrollView convertRect:nameRect fromView:_tableView]];
    _renameField.stringValue   = entry.name;
    _renameField.font          = [NSFont systemFontOfSize:13];
    _renameField.delegate      = self;
    _renameField.focusRingType = NSFocusRingTypeDefault;
    [_tableView.enclosingScrollView addSubview:_renameField];
    [self.view.window makeFirstResponder:_renameField];
    [_renameField selectText:nil];
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
    if (note.object != _renameField) return;
    NSString *newName = _renameField.stringValue;
    [_renameField removeFromSuperview];
    _renameField = nil;
    if (!newName.length || _renameRow < 0) return;
    FileEntry *entry   = _entries[(NSUInteger)_renameRow];
    NSString *newPath  = [entry.path.stringByDeletingLastPathComponent
                          stringByAppendingPathComponent:newName];
    char errBuf[512] = {0};
    if (!zig_rename(entry.path.UTF8String, newPath.UTF8String, errBuf, sizeof(errBuf)))
        [self showErrorMessage:@(errBuf)];
    else
        [self loadPath:_currentPath];
    _renameRow = -1;
}

- (IBAction)showInfoSelected:(id)sender {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    [_tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [urls addObject:[NSURL fileURLWithPath:self.entries[idx].path]];
    }];
    if (urls.count) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:urls];
}

- (IBAction)moveHere:(id)sender {
    NSArray<NSString *> *paths = [self effectiveClipboardPaths];
    if (!paths.count) return;
    [self performTransferFromPaths:paths toDir:_currentPath isMove:YES];
    _clipboardPaths = nil;
    _clipboardOp    = ClipboardOperationNone;
    [_tableView reloadData];
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

- (IBAction)uncompressSelected:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row < 0) return;
    FileEntry *entry = _entries[(NSUInteger)row];

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
    NSString *resolved = dev;
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:resolved]) return resolved;
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

- (BOOL)tableView:(NSTableView *)tv
       writeRowsWithIndexes:(NSIndexSet *)rowIndexes
               toPasteboard:(NSPasteboard *)pb {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    [rowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [urls addObject:[NSURL fileURLWithPath:self.entries[idx].path]];
    }];
    [pb clearContents];
    [pb writeObjects:urls];
    return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Drag destination
// ─────────────────────────────────────────────────────────────────────────────

- (NSDragOperation)tableView:(NSTableView *)tv
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)op {
    if (op == NSTableViewDropOn && row >= 0 && (NSUInteger)row < _entries.count) {
        if (!_entries[(NSUInteger)row].isDir) return NSDragOperationNone;
    } else if (op == NSTableViewDropAbove) {
        // Retarget "between rows" drops to the whole table (drop into current dir)
        [tv setDropRow:-1 dropOperation:NSTableViewDropOn];
    }
    // Support both copy (default) and move (Option key held)
    NSDragOperation mask = info.draggingSourceOperationMask;
    if (mask & NSDragOperationMove) return NSDragOperationMove;
    return NSDragOperationCopy;
}

- (BOOL)tableView:(NSTableView *)tv
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)op {
    NSArray<NSURL *> *urls = [info.draggingPasteboard
        readObjectsForClasses:@[[NSURL class]]
        options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    if (!urls.count) return NO;
    NSString *dstDir = (op == NSTableViewDropOn && row >= 0 && (NSUInteger)row < _entries.count
                        && _entries[(NSUInteger)row].isDir)
        ? _entries[(NSUInteger)row].path : _currentPath;
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
    return (NSInteger)_tableView.selectedRowIndexes.count;
}

- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index {
    __block NSInteger current = 0;
    __block NSString *path = nil;
    [_tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (current == index) { path = self.entries[idx].path; *stop = YES; }
        current++;
    }];
    return path ? [NSURL fileURLWithPath:path] : nil;
}

// QLPreviewPanelDelegate – keep the panel in sync when the table selection changes.
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if ([QLPreviewPanel sharedPreviewPanelExists] && [QLPreviewPanel sharedPreviewPanel].isVisible)
        [[QLPreviewPanel sharedPreviewPanel] reloadData];
}

@end
