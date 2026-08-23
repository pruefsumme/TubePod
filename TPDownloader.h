#import <Foundation/Foundation.h>

extern NSString * const TPDownloadProgressNotification;
extern NSString * const TPDownloadFinishedNotification;

@interface TPDownloadRequest : NSObject
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *artist;
@property(nonatomic, retain) NSURL *URL;
@property(nonatomic, retain) NSURL *artworkURL;
@property(nonatomic) NSTimeInterval duration;
@property(nonatomic) BOOL audioOnly;
@end

@interface TPDownloader : NSObject <NSURLConnectionDataDelegate>
+ (instancetype)sharedDownloader;
- (BOOL)startRequest:(TPDownloadRequest *)request error:(NSError **)error;
- (void)cancel;
@property(nonatomic, readonly, getter=isBusy) BOOL busy;
@end
