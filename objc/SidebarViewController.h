// SidebarViewController.h
#import <Cocoa/Cocoa.h>

@class SidebarViewController;

@protocol SidebarViewControllerDelegate <NSObject>
- (void)sidebar:(SidebarViewController *)sidebar didSelectPath:(NSString *)path;
@optional
- (void)sidebar:(SidebarViewController *)sidebar
   dropFilePaths:(NSArray<NSString *> *)paths
           toDir:(NSString *)dstDir
          isMove:(BOOL)isMove;
@end

@interface SidebarViewController : NSViewController <NSOutlineViewDataSource, NSOutlineViewDelegate>

@property (nonatomic, weak) id<SidebarViewControllerDelegate> delegate;

/// Highlight the sidebar row matching the given path (best-effort).
- (void)highlightPath:(NSString *)path;

@end
