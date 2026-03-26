// SidebarViewController.m
#import "SidebarViewController.h"
#import "bridge.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netdb.h>
#import <fcntl.h>

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - Internal model
// ─────────────────────────────────────────────────────────────────────────────

@interface SidebarItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSImage *icon;
@property (nonatomic) BOOL isHeader;          // section header row
@property (nonatomic, copy) NSString *networkHostname;  // non-nil for network hosts
@property (nonatomic, strong) NSMutableArray<SidebarItem *> *children;
@end

@implementation SidebarItem
- (instancetype)initHeader:(NSString *)title {
    self = [super init];
    _name = title;
    _isHeader = YES;
    _children = [NSMutableArray array];
    return self;
}
- (instancetype)initWithName:(NSString *)name path:(NSString *)path icon:(NSImage *)icon {
    self = [super init];
    _name = name;
    _path = path;
    _icon = icon;
    _isHeader = NO;
    _children = [NSMutableArray array];
    return self;
}
- (instancetype)initNetworkHost:(NSString *)name hostname:(NSString *)hostname icon:(NSImage *)icon {
    self = [super init];
    _name = name;
    _networkHostname = hostname;
    _icon = icon;
    _isHeader = NO;
    _children = [NSMutableArray array];
    return self;
}
@end

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark - SidebarViewController
// ─────────────────────────────────────────────────────────────────────────────

@interface SidebarViewController () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property (nonatomic, strong) NSScrollView   *scrollView;
@property (nonatomic, strong) NSOutlineView  *outlineView;
@property (nonatomic, strong) NSMutableArray<SidebarItem *> *sections;
// Set while highlightPath: is executing a programmatic selection so that
// outlineViewSelectionDidChange: doesn't call back into the delegate (and
// hence pushPath:) for a selection change we initiated ourselves.
@property (nonatomic) BOOL isHighlighting;
// Network discovery
@property (nonatomic, strong) NSNetServiceBrowser *smbBrowser;
@property (nonatomic, strong) NSMutableArray<NSNetService *> *discoveredServices;
@property (nonatomic, strong) SidebarItem *networkHeader;
@end

@implementation SidebarViewController

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 600)];
    self.view.wantsLayer = YES;

    _outlineView = [[NSOutlineView alloc] initWithFrame:self.view.bounds];
    _outlineView.autoresizingMask         = NSViewWidthSizable | NSViewHeightSizable;
    _outlineView.headerView               = nil;
    _outlineView.indentationPerLevel      = 12;
    _outlineView.rowSizeStyle             = NSTableViewRowSizeStyleMedium;
    _outlineView.selectionHighlightStyle  = NSTableViewSelectionHighlightStyleSourceList;
    _outlineView.floatsGroupRows          = NO;
    _outlineView.dataSource               = self;
    _outlineView.delegate                 = self;
    [_outlineView setTarget:self];
    [_outlineView setDoubleAction:@selector(outlineViewDoubleClicked:)];

    // Drag destination – accept file drops onto sidebar items
    [_outlineView registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_outlineView addTableColumn:col];

    _scrollView = [[NSScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask       = NSViewWidthSizable | NSViewHeightSizable;
    _scrollView.hasVerticalScroller    = YES;
    _scrollView.drawsBackground        = NO;
    _scrollView.documentView           = _outlineView;

    [self.view addSubview:_scrollView];

    [self buildSections];
    [_outlineView reloadData];
    [_outlineView expandItem:nil expandChildren:YES];

    // Observe workspace notifications for volume mount/unmount
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(volumesChanged:)
               name:NSWorkspaceDidMountNotification
             object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self
           selector:@selector(volumesChanged:)
               name:NSWorkspaceDidUnmountNotification
             object:nil];
}

- (void)dealloc {
    [_smbBrowser stop];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
}

// ─────────────
// Build model
// ─────────────

- (void)buildSections {
    _sections = [NSMutableArray array];

    // ── Favourites ────────────────────────────────────────────────────────
    SidebarItem *favHeader = [[SidebarItem alloc] initHeader:@"FAVORITOS"];
    ZigVolumeList *specials = zig_get_special_dirs();
    if (specials) {
        for (uint64_t i = 0; i < specials->count; i++) {
            NSString *name = @(specials->volumes[i].name);
            NSString *path = @(specials->volumes[i].path);
            NSImage  *icon = [self iconForSpecialDir:name defaultPath:path];
            SidebarItem *item = [[SidebarItem alloc] initWithName:name path:path icon:icon];
            [favHeader.children addObject:item];
        }
        zig_free_volume_list(specials);
    }
    [_sections addObject:favHeader];

    // ── Devices / Volumes ─────────────────────────────────────────────────
    SidebarItem *volHeader = [[SidebarItem alloc] initHeader:@"DISPOSITIVOS"];
    [self populateVolumes:volHeader];
    [_sections addObject:volHeader];

    // ── Network ──────────────────────────────────────────────────────────
    _networkHeader = [[SidebarItem alloc] initHeader:@"RED"];
    [_sections addObject:_networkHeader];
    [self startNetworkDiscovery];
}

- (void)populateVolumes:(SidebarItem *)header {
    [header.children removeAllObjects];

    // Always add Macintosh HD (root)
    NSImage *hddIcon = [NSImage imageWithSystemSymbolName:@"internaldrive" accessibilityDescription:nil] ?:
                       [NSImage imageNamed:NSImageNameComputer];
    SidebarItem *root = [[SidebarItem alloc] initWithName:@"Macintosh HD" path:@"/" icon:hddIcon];
    [header.children addObject:root];

    ZigVolumeList *vols = zig_get_volumes();
    if (vols) {
        for (uint64_t i = 0; i < vols->count; i++) {
            NSString *name = @(vols->volumes[i].name);
            NSString *path = @(vols->volumes[i].path);
            // Skip the symlink that points to /
            if ([path isEqualToString:@"/Volumes/Macintosh HD"]) continue;
            NSImage *icon = [NSImage imageWithSystemSymbolName:@"externaldrive" accessibilityDescription:nil] ?:
                            [NSImage imageNamed:NSImageNameMultipleDocuments];
            SidebarItem *item = [[SidebarItem alloc] initWithName:name path:path icon:icon];
            [header.children addObject:item];
        }
        zig_free_volume_list(vols);
    }
}

- (NSImage *)iconForSpecialDir:(NSString *)name defaultPath:(NSString *)path {
    static NSDictionary<NSString *, NSString *> *symbolMap = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        symbolMap = @{
            @"Inicio":       @"house",
            @"Escritorio":   @"desktopcomputer",
            @"Documentos":   @"doc",
            @"Descargas":    @"arrow.down.circle",
            @"Música":       @"music.note",
            @"Imágenes":     @"photo",
            @"Películas":    @"film",
            @"Aplicaciones": @"square.grid.2x2",
        };
    });
    NSString *sym = symbolMap[name];
    if (sym) {
        NSImage *img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:name];
        if (img) return img;
    }
    return [[NSWorkspace sharedWorkspace] iconForFile:path];
}

// ─────────────
// Volume changes
// ─────────────

- (void)volumesChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        // DISPOSITIVOS is the second section (index 1)
        if (self.sections.count < 2) return;
        SidebarItem *volHeader = self.sections[1];
        [self populateVolumes:volHeader];
        [self.outlineView reloadData];
        [self.outlineView expandItem:nil expandChildren:YES];
    });
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Network discovery
// ─────────────────────────────────────────────────────────────────────────────

- (void)startNetworkDiscovery {
    _discoveredServices = [NSMutableArray array];

    // 1) Bonjour – finds servers that advertise via mDNS/Avahi
    _smbBrowser = [[NSNetServiceBrowser alloc] init];
    _smbBrowser.delegate = self;
    [_smbBrowser searchForServicesOfType:@"_smb._tcp." inDomain:@""];

    // 2) Port scan – finds SMB servers that don't advertise via Bonjour
    [self scanSubnetForSMB];
}

// ─── Bonjour delegate ────────────────────────────────────────────────────────

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
           didFindService:(NSNetService *)service
               moreComing:(BOOL)moreComing {
    service.delegate = self;
    [service resolveWithTimeout:5.0];
    [_discoveredServices addObject:service];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
         didRemoveService:(NSNetService *)service
               moreComing:(BOOL)moreComing {
    [_discoveredServices removeObject:service];
    NSMutableArray *toRemove = [NSMutableArray array];
    for (SidebarItem *item in _networkHeader.children) {
        if ([item.name isEqualToString:service.name]) [toRemove addObject:item];
    }
    [_networkHeader.children removeObjectsInArray:toRemove];
    if (!moreComing) {
        [_outlineView reloadData];
        [_outlineView expandItem:nil expandChildren:YES];
    }
}

- (void)netServiceDidResolveAddress:(NSNetService *)service {
    NSString *hostname = service.hostName;
    if ([hostname hasSuffix:@"."]) hostname = [hostname substringToIndex:hostname.length - 1];
    [self addNetworkHostWithName:service.name hostname:hostname];
}

- (void)netService:(NSNetService *)sender
     didNotResolve:(NSDictionary<NSString *,NSNumber *> *)errorDict {
    [self addNetworkHostWithName:sender.name hostname:sender.name];
}

// ─── Subnet scan for port 445 (SMB) ─────────────────────────────────────────

- (void)scanSubnetForSMB {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Get local IPv4 addresses and their netmasks
        struct ifaddrs *ifaddrs = NULL;
        if (getifaddrs(&ifaddrs) != 0) return;

        for (struct ifaddrs *ifa = ifaddrs; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            // Skip loopback
            if (ifa->ifa_flags & IFF_LOOPBACK) continue;
            // Must be up and running
            if (!(ifa->ifa_flags & IFF_UP) || !(ifa->ifa_flags & IFF_RUNNING)) continue;

            struct sockaddr_in *addr = (struct sockaddr_in *)ifa->ifa_addr;
            struct sockaddr_in *mask = (struct sockaddr_in *)ifa->ifa_netmask;
            uint32_t ip   = ntohl(addr->sin_addr.s_addr);
            uint32_t net  = ntohl(mask->sin_addr.s_addr);
            uint32_t base = ip & net;
            uint32_t bcast = base | ~net;
            // Limit scan to /24 or smaller to avoid flooding large subnets
            uint32_t range = bcast - base;
            if (range > 254) range = 254;

            dispatch_group_t group = dispatch_group_create();
            dispatch_queue_t queue = dispatch_queue_create("smb.scan", DISPATCH_QUEUE_CONCURRENT);

            for (uint32_t i = 1; i <= range; i++) {
                uint32_t target = base + i;
                if (target == ip) continue; // skip self

                dispatch_group_enter(group);
                dispatch_async(queue, ^{
                    [self probeSMBAtIP:target];
                    dispatch_group_leave(group);
                });
            }

            dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));
        }

        freeifaddrs(ifaddrs);
    });
}

- (void)probeSMBAtIP:(uint32_t)ip {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;

    // Set non-blocking
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(445);
    addr.sin_addr.s_addr = htonl(ip);

    connect(fd, (struct sockaddr *)&addr, sizeof(addr));

    // Wait up to 300ms for connection
    fd_set writefds;
    FD_ZERO(&writefds);
    FD_SET(fd, &writefds);
    struct timeval tv = { .tv_sec = 0, .tv_usec = 300000 };

    int result = select(fd + 1, NULL, &writefds, NULL, &tv);
    if (result > 0) {
        int err = 0;
        socklen_t len = sizeof(err);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
        if (err == 0) {
            // Port 445 is open – resolve hostname
            struct sockaddr_in sa;
            memset(&sa, 0, sizeof(sa));
            sa.sin_family = AF_INET;
            sa.sin_addr.s_addr = htonl(ip);
            char hostbuf[NI_MAXHOST];
            char ipstr[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &sa.sin_addr, ipstr, sizeof(ipstr));

            NSString *displayName;
            NSString *hostname;
            if (getnameinfo((struct sockaddr *)&sa, sizeof(sa),
                            hostbuf, sizeof(hostbuf), NULL, 0,
                            NI_NAMEREQD) == 0) {
                // Got a DNS name – use short name for display
                NSString *fullName = @(hostbuf);
                // Strip domain suffix for display (e.g. "server.local" → "server")
                NSArray *parts = [fullName componentsSeparatedByString:@"."];
                displayName = parts.firstObject;
                hostname = fullName;
            } else {
                // No reverse DNS – use IP address
                displayName = @(ipstr);
                hostname = @(ipstr);
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [self addNetworkHostWithName:displayName hostname:hostname];
            });
        }
    }
    close(fd);
}

// ─── Common helper ───────────────────────────────────────────────────────────

- (void)addNetworkHostWithName:(NSString *)name hostname:(NSString *)hostname {
    // Avoid duplicates
    for (SidebarItem *existing in _networkHeader.children) {
        if ([existing.networkHostname isEqualToString:hostname]) return;
    }
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"network" accessibilityDescription:nil] ?:
                    [NSImage imageNamed:NSImageNameNetwork];
    SidebarItem *item = [[SidebarItem alloc] initNetworkHost:name
                                                    hostname:hostname
                                                        icon:icon];
    [_networkHeader.children addObject:item];
    [_outlineView reloadData];
    [_outlineView expandItem:nil expandChildren:YES];
}

- (void)connectToNetworkHost:(SidebarItem *)item {
    // Open smb://hostname – macOS handles authentication and mounting.
    // Once mounted the volume appears in /Volumes and our NSWorkspace
    // mount notification refreshes DISPOSITIVOS automatically.
    NSString *urlStr = [NSString stringWithFormat:@"smb://%@", item.networkHostname];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Public API
// ─────────────────────────────────────────────────────────────────────────────

- (void)highlightPath:(NSString *)path {
    _isHighlighting = YES;
    for (SidebarItem *section in _sections) {
        for (SidebarItem *item in section.children) {
            if ([path hasPrefix:item.path]) {
                NSInteger row = [_outlineView rowForItem:item];
                if (row >= 0) {
                    [_outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]
                              byExtendingSelection:NO];
                    _isHighlighting = NO;
                    return;
                }
            }
        }
    }
    // No match – deselect
    [_outlineView deselectAll:nil];
    _isHighlighting = NO;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSOutlineViewDataSource
// ─────────────────────────────────────────────────────────────────────────────

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    if (!item) return (NSInteger)_sections.count;
    SidebarItem *si = item;
    return (NSInteger)si.children.count;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    if (!item) return _sections[(NSUInteger)index];
    SidebarItem *si = item;
    return si.children[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    SidebarItem *si = item;
    return si.children.count > 0;
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – NSOutlineViewDelegate
// ─────────────────────────────────────────────────────────────────────────────

- (BOOL)outlineView:(NSOutlineView *)ov isGroupItem:(id)item {
    return ((SidebarItem *)item).isHeader;
}

- (BOOL)outlineView:(NSOutlineView *)ov shouldSelectItem:(id)item {
    return !((SidebarItem *)item).isHeader;
}

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    SidebarItem *si = item;

    if (si.isHeader) {
        NSTableCellView *cell = [ov makeViewWithIdentifier:@"HeaderCell" owner:self];
        if (!cell) {
            cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
            cell.identifier = @"HeaderCell";
            NSTextField *tf = [NSTextField labelWithString:@""];
            tf.font        = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
            tf.textColor   = [NSColor tertiaryLabelColor];
            tf.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:tf];
            cell.textField = tf;
            [NSLayoutConstraint activateConstraints:@[
                [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
                [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
        }
        cell.textField.stringValue = si.name;
        return cell;
    }

    NSTableCellView *cell = [ov makeViewWithIdentifier:@"ItemCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"ItemCell";

        NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.imageScaling = NSImageScaleProportionallyDown;
        [cell addSubview:iv];
        cell.imageView = iv;

        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.font = [NSFont systemFontOfSize:13];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:tf];
        cell.textField = tf;

        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor  constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [iv.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
            [iv.widthAnchor    constraintEqualToConstant:16],
            [iv.heightAnchor   constraintEqualToConstant:16],
            [tf.leadingAnchor  constraintEqualToAnchor:iv.trailingAnchor constant:6],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [tf.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    cell.textField.stringValue = si.name;
    NSImage *icon = si.icon ?: [[NSWorkspace sharedWorkspace] iconForFile:si.path ?: @"/"];
    icon.size = NSMakeSize(16, 16);
    cell.imageView.image = icon;
    return cell;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    if (_isHighlighting) return;  // programmatic selection – don't push to history
    NSInteger row = _outlineView.selectedRow;
    if (row < 0) return;
    SidebarItem *item = [_outlineView itemAtRow:row];
    if (item.isHeader) return;

    if (item.networkHostname) {
        [self connectToNetworkHost:item];
        return;
    }
    if (!item.path) return;
    [self.delegate sidebar:self didSelectPath:item.path];
}

- (IBAction)outlineViewDoubleClicked:(id)sender {
    // Double-click on sidebar item is same as single select (already handled)
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Drag destination
// ─────────────────────────────────────────────────────────────────────────────

- (NSDragOperation)outlineView:(NSOutlineView *)ov
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)index {
    if (!item) return NSDragOperationNone;
    SidebarItem *si = item;
    if (si.isHeader || !si.path) return NSDragOperationNone;
    NSDragOperation mask = info.draggingSourceOperationMask;
    if (mask & NSDragOperationMove) return NSDragOperationMove;
    return NSDragOperationCopy;
}

- (BOOL)outlineView:(NSOutlineView *)ov
         acceptDrop:(id<NSDraggingInfo>)info
               item:(id)item
         childIndex:(NSInteger)index {
    SidebarItem *si = item;
    if (!si || si.isHeader || !si.path) return NO;
    NSArray<NSURL *> *urls = [info.draggingPasteboard
        readObjectsForClasses:@[[NSURL class]]
        options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    if (!urls.count) return NO;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *u in urls) [paths addObject:u.path];
    BOOL isMove = (info.draggingSourceOperationMask & NSDragOperationMove) != 0;
    if ([self.delegate respondsToSelector:@selector(sidebar:dropFilePaths:toDir:isMove:)]) {
        [self.delegate sidebar:self dropFilePaths:paths toDir:si.path isMove:isMove];
    }
    return YES;
}

@end
