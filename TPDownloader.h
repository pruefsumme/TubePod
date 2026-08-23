#import <Foundation/Foundation.h>

@class TPDownloadSession;

typedef void (^TPDownloadProgressBlock)(TPDownloadSession *session, double fraction, NSString *phase);
typedef void (^TPDownloadCompletionBlock)(TPDownloadSession *session, NSError *error, NSString *path);

@interface TPDownloadRequest : NSObject
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, copy) NSString *sourceVideoID;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *artist;
@property(nonatomic, retain) NSURL *URL;
@property(nonatomic) NSTimeInterval duration;
@property(nonatomic) BOOL audioOnly;
@property(nonatomic) BOOL allowDuplicate;
@end

@interface TPDownloadSession : NSObject
@property(nonatomic, readonly, copy) NSString *sessionID;
@end

@interface TPDownloader : NSObject <NSURLConnectionDataDelegate>
+ (instancetype)sharedDownloader;
- (TPDownloadSession *)startRequest:(TPDownloadRequest *)request progress:(TPDownloadProgressBlock)progress completion:(TPDownloadCompletionBlock)completion error:(NSError **)error;
- (void)cancel;
- (void)cancelSession:(TPDownloadSession *)session;
@property(nonatomic, readonly, getter=isBusy) BOOL busy;
@end
