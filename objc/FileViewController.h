// FileViewController.h
#import <Cocoa/Cocoa.h>

@class FileViewController;

@protocol FileViewControllerDelegate <NSObject>
- (void)fileViewController:(FileViewController *)vc didNavigateToPath:(NSString *)path;
@end

typedef NS_ENUM(NSInteger, FileViewMode) {
    FileViewModeIcon = 0,
    FileViewModeList = 1,
    FileViewModeColumns = 2,
    FileViewModeGallery = 3,
};

@interface FileViewController : NSViewController

@property (nonatomic, weak)   id<FileViewControllerDelegate> delegate;
@property (nonatomic, readonly, copy) NSString *currentPath;
@property (nonatomic) FileViewMode viewMode;

- (instancetype)initWithPath:(NSString *)path;
- (void)loadPath:(NSString *)path;
- (void)createNewFolderInPath:(NSString *)path;
- (void)performTransferFromPaths:(NSArray<NSString *> *)paths
                           toDir:(NSString *)dstDir
                          isMove:(BOOL)isMove;

@end
