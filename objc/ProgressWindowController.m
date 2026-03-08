// ProgressWindowController.m
#import "ProgressWindowController.h"

@interface ProgressWindowController ()
@property (nonatomic, copy) void (^refreshCallback)(void);
@property (nonatomic, strong) NSProgressIndicator *progressBar;
@property (nonatomic, strong) NSTextField         *titleLabel;
@property (nonatomic, strong) NSTextField         *detailLabel;
@property (nonatomic, strong) NSTextField         *speedLabel;
@property (nonatomic, strong) NSButton            *cancelButton;
@property (nonatomic, copy)   NSString            *operationTitle;
@end

@implementation ProgressWindowController

- (instancetype)initWithTitle:(NSString *)title
            destinationFolder:(NSString *)dst
             refreshCallback:(void (^)(void))refresh {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 160)
                                               styleMask:NSWindowStyleMaskTitled
                                                         | NSWindowStyleMaskClosable
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    win.title          = title;
    win.releasedWhenClosed = NO;
    [win center];

    self = [super initWithWindow:win];
    if (!self) return nil;
    _operationTitle  = [title copy];
    _refreshCallback = [refresh copy];

    [self buildUI:dst];
    return self;
}

- (void)buildUI:(NSString *)dst {
    NSView *cv = self.window.contentView;

    // Title
    _titleLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%@…", _operationTitle]];
    _titleLabel.font = [NSFont boldSystemFontOfSize:14];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:_titleLabel];

    // Detail (destination)
    _detailLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"Destino: %@", dst]];
    _detailLabel.font        = [NSFont systemFontOfSize:11];
    _detailLabel.textColor   = [NSColor secondaryLabelColor];
    _detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:_detailLabel];

    // Progress bar
    _progressBar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _progressBar.style           = NSProgressIndicatorStyleBar;
    _progressBar.minValue        = 0.0;
    _progressBar.maxValue        = 1.0;
    _progressBar.doubleValue     = 0.0;
    _progressBar.indeterminate   = YES;
    _progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    [_progressBar startAnimation:nil];
    [cv addSubview:_progressBar];

    // Speed / ETA
    _speedLabel = [NSTextField labelWithString:@"Calculando…"];
    _speedLabel.font      = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _speedLabel.textColor = [NSColor secondaryLabelColor];
    _speedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:_speedLabel];

    // Cancel
    _cancelButton = [NSButton buttonWithTitle:@"Cancelar" target:self action:@selector(cancelClicked:)];
    _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:_cancelButton];

    CGFloat m = 20;
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor      constraintEqualToAnchor:cv.topAnchor       constant:m],
        [_titleLabel.leadingAnchor  constraintEqualToAnchor:cv.leadingAnchor   constant:m],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor  constant:-m],

        [_detailLabel.topAnchor      constraintEqualToAnchor:_titleLabel.bottomAnchor constant:6],
        [_detailLabel.leadingAnchor  constraintEqualToAnchor:cv.leadingAnchor  constant:m],
        [_detailLabel.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-m],

        [_progressBar.topAnchor      constraintEqualToAnchor:_detailLabel.bottomAnchor constant:14],
        [_progressBar.leadingAnchor  constraintEqualToAnchor:cv.leadingAnchor  constant:m],
        [_progressBar.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-m],

        [_speedLabel.topAnchor      constraintEqualToAnchor:_progressBar.bottomAnchor constant:6],
        [_speedLabel.leadingAnchor  constraintEqualToAnchor:cv.leadingAnchor   constant:m],

        [_cancelButton.centerYAnchor  constraintEqualToAnchor:_speedLabel.centerYAnchor],
        [_cancelButton.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-m],
    ]];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Public API (called from Zig callbacks, always on main thread)
// ─────────────────────────────────────────────────────────────────────────────

- (void)updateProgress:(double)progress
      bytesTransferred:(uint64_t)bytesDone
            totalBytes:(uint64_t)total
                 speed:(double)bytesPerSec
               etaSecs:(int64_t)eta {

    // progress > 1.0 signals the sync-to-disk phase (OS write cache flush)
    if (progress > 1.0) {
        if (!_progressBar.isIndeterminate) {
            _progressBar.indeterminate = YES;
            [_progressBar startAnimation:nil];
        }
        NSString *sizeStr = total > 0
            ? [NSString stringWithFormat:@"%@", [self formattedSize:total]]
            : [self formattedSize:bytesDone];
        _speedLabel.stringValue = [NSString stringWithFormat:@"%@   Sincronizando…", sizeStr];
        return;
    }

    if (_progressBar.isIndeterminate) {
        _progressBar.indeterminate = NO;
        [_progressBar stopAnimation:nil];
    }
    _progressBar.doubleValue = progress;

    // Speed string
    NSString *speedStr = [self formattedSpeed:bytesPerSec];
    NSString *etaStr   = eta > 0 ? [self formattedETA:eta] : @"—";
    NSString *sizeStr  = total > 0
        ? [NSString stringWithFormat:@"%@ / %@", [self formattedSize:bytesDone], [self formattedSize:total]]
        : [self formattedSize:bytesDone];
    _speedLabel.stringValue = [NSString stringWithFormat:@"%@   %@   ETA: %@", sizeStr, speedStr, etaStr];
}

- (void)finishWithSuccess:(BOOL)success errorMessage:(NSString *)msg {
    if (success) {
        [self close];
        if (_refreshCallback) _refreshCallback();
    } else {
        _progressBar.indeterminate  = YES;
        [_progressBar startAnimation:nil];
        _titleLabel.stringValue     = @"Error en la operación";
        _speedLabel.stringValue     = msg ?: @"Error desconocido";
        _cancelButton.title         = @"Cerrar";
    }
    // Object lifetime is managed by the doneCb block's ARC capture of pwc.
    // No manual bridge release needed here.
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Actions
// ─────────────────────────────────────────────────────────────────────────────

- (IBAction)cancelClicked:(id)sender {
    // TODO: send SIGTERM to rsync process. For now just close.
    [self close];
}

// ─────────────────────────────────────────────────────────────────────────────
#pragma mark – Helpers
// ─────────────────────────────────────────────────────────────────────────────

- (NSString *)formattedSize:(uint64_t)bytes {
    double v = (double)bytes;
    if (v < 1024)         return [NSString stringWithFormat:@"%.0f B",    v];
    if (v < 1024*1024)    return [NSString stringWithFormat:@"%.1f KB",   v/1024];
    if (v < 1024*1024*1024) return [NSString stringWithFormat:@"%.1f MB", v/1024/1024];
    return [NSString stringWithFormat:@"%.2f GB", v/1024/1024/1024];
}

- (NSString *)formattedSpeed:(double)bps {
    if (bps <= 0) return @"";
    if (bps < 1024)       return [NSString stringWithFormat:@"%.0f B/s",   bps];
    if (bps < 1024*1024)  return [NSString stringWithFormat:@"%.1f KB/s",  bps/1024];
    return [NSString stringWithFormat:@"%.1f MB/s", bps/1024/1024];
}

- (NSString *)formattedETA:(int64_t)secs {
    if (secs < 0) return @"—";
    long h = secs / 3600;
    long m = (secs % 3600) / 60;
    long s = secs % 60;
    if (h > 0) return [NSString stringWithFormat:@"%ldh %ldm", h, m];
    if (m > 0) return [NSString stringWithFormat:@"%ldm %lds", m, s];
    return [NSString stringWithFormat:@"%lds", s];
}

@end
