// AppDelegate.m
#import "AppDelegate.h"
#import "FinderWindowController.h"
#import "GoToFolderPanel.h"

@interface AppDelegate ()
// Strong-retain every FinderWindowController so ARC doesn't release it when
// openNewWindow's local 'wc' goes out of scope.  NSWindow.windowController is
// an assign (non-retaining) property, so without this the controller would be
// immediately deallocated, turning all weak delegate references into nil and
// making sidebar/toolbar clicks silently do nothing.
@property (nonatomic, strong) NSMutableArray<FinderWindowController *> *openControllers;
@end

@implementation AppDelegate

// ───────────────────────────────────────────────
#pragma mark - App lifecycle
// ───────────────────────────────────────────────

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _openControllers = [NSMutableArray array];

    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self buildMainMenu];
    [NSApp activateIgnoringOtherApps:YES];
    [self openNewWindow];
}

// ───────────────────────────────────────────────
#pragma mark - Main menu
// ───────────────────────────────────────────────

- (void)buildMainMenu {
    NSMenu *main = [[NSMenu alloc] initWithTitle:@""];
    [NSApp setMainMenu:main];

    // ── R2 Finder ─────────────────────────────────────────────────────────────
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"R2 Finder"];
    [main addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = appMenu;

    [appMenu addItemWithTitle:@"Acerca de R2 Finder"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenu *servicesMenu = [[NSMenu alloc] initWithTitle:@"Servicios"];
    [appMenu addItemWithTitle:@"Servicios" action:nil keyEquivalent:@""].submenu = servicesMenu;
    [NSApp setServicesMenu:servicesMenu];

    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Ocultar R2 Finder"
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Ocultar otros"
                                                action:@selector(hideOtherApplications:)
                                         keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItemWithTitle:@"Mostrar todo"
                       action:@selector(unhideAllApplications:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Salir de R2 Finder"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];

    // ── Archivo ───────────────────────────────────────────────────────────────
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"Archivo"];
    [main addItemWithTitle:@"Archivo" action:nil keyEquivalent:@""].submenu = fileMenu;

    NSMenuItem *newWin = [fileMenu addItemWithTitle:@"Nueva ventana"
                                             action:@selector(openNewWindow)
                                      keyEquivalent:@"n"];
    newWin.target = self;

    // target = nil → first responder chain reaches FinderWindowController
    [fileMenu addItemWithTitle:@"Nueva carpeta"
                        action:@selector(createNewFolder:)
                 keyEquivalent:@"N"]; // Cmd+Shift+N

    [fileMenu addItem:[NSMenuItem separatorItem]];

    [fileMenu addItemWithTitle:@"Cerrar ventana"
                        action:@selector(performClose:)
                 keyEquivalent:@"w"];

    // ── Edición ──────────────────────────────────────────────────────────────
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edición"];
    [main addItemWithTitle:@"Edición" action:nil keyEquivalent:@""].submenu = editMenu;

    // target = nil → first-responder chain reaches FileViewController
    [editMenu addItemWithTitle:@"Copiar"  action:@selector(copySelected:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Cortar"  action:@selector(cutSelected:)  keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Pegar"   action:@selector(pasteHere:)    keyEquivalent:@"v"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Seleccionar todo" action:@selector(selectAll:) keyEquivalent:@"a"];

    // ── Ventana ───────────────────────────────────────────────────────────────
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Ventana"];
    [main addItemWithTitle:@"Ventana" action:nil keyEquivalent:@""].submenu = windowMenu;
    [NSApp setWindowsMenu:windowMenu];

    [windowMenu addItemWithTitle:@"Minimizar"
                          action:@selector(performMiniaturize:)
                   keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom"
                          action:@selector(performZoom:)
                   keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:@"Traer todo al frente"
                          action:@selector(arrangeInFront:)
                   keyEquivalent:@""];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (!flag) [self openNewWindow];
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO;
}

// ───────────────────────────────────────────────
#pragma mark - Dock context menu
// ───────────────────────────────────────────────

- (NSMenu *)applicationDockMenu:(NSApplication *)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem *newWin = [[NSMenuItem alloc]
        initWithTitle:@"Nueva ventana"
               action:@selector(openNewWindow)
        keyEquivalent:@""];
    newWin.target = self;
    [menu addItem:newWin];

    NSMenuItem *goTo = [[NSMenuItem alloc]
        initWithTitle:@"Ir a la carpeta…"
               action:@selector(goToFolder)
        keyEquivalent:@""];
    goTo.target = self;
    [menu addItem:goTo];

    return menu;
}

// ───────────────────────────────────────────────
#pragma mark - Actions
// ───────────────────────────────────────────────

- (void)openNewWindow {
    NSString *home = NSHomeDirectory();
    FinderWindowController *wc = [[FinderWindowController alloc] initWithPath:home];
    [_openControllers addObject:wc];  // retain so ARC doesn't free it
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(windowWillClose:)
               name:NSWindowWillCloseNotification
             object:wc.window];
    [wc showWindow:nil];
    [wc.window makeKeyAndOrderFront:nil];
}

- (void)windowWillClose:(NSNotification *)note {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowWillCloseNotification
                                                  object:note.object];
    // Remove the controller whose window just closed; ARC will then free it.
    NSWindow *closing = note.object;
    [_openControllers filterUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(FinderWindowController *wc, NSDictionary *_) {
            return wc.window != closing;
        }]];
}

- (void)goToFolder {
    NSWindow *parent = [NSApp mainWindow];
    if (!parent) {
        // No window yet – open one first
        [self openNewWindow];
        parent = [NSApp mainWindow];
    }

    [GoToFolderPanel runAsSheetOnWindow:parent completionHandler:^(NSString *path) {
        if (!path) return;
        // If a FinderWindowController is front, navigate it; else open new window.
        FinderWindowController *wc = (FinderWindowController *)parent.windowController;
        if ([wc isKindOfClass:[FinderWindowController class]]) {
            [wc navigateToPath:path];
        } else {
            FinderWindowController *newWC = [[FinderWindowController alloc] initWithPath:path];
            [newWC showWindow:nil];
        }
    }];
}

@end

// ───────────────────────────────────────────────
// C entry-point called from Zig main()
// ───────────────────────────────────────────────

void objc_run_app(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
}
