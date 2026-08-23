#import <Foundation/Foundation.h>

@protocol SSDownloadQueueObserver <NSObject>
@optional
- (void)downloadQueue:(id)queue changedWithRemovals:(id)removals;
- (void)downloadQueue:(id)queue downloadStatesChangedAtIndexes:(id)indexes;
- (void)downloadQueue:(id)queue downloadStatusChangedAtIndex:(NSInteger)index;
@end

@interface SSDownloadMetadata : NSObject
- (id)initWithDictionary:(NSDictionary *)dictionary;
- (id)initWithKind:(NSString *)kind;
- (void)setTitle:(NSString *)title;
- (void)setArtistName:(NSString *)artist;
- (void)setCollectionName:(NSString *)album;
- (NSString *)collectionName;
- (void)setKind:(NSString *)kind;
- (void)setDuration:(NSNumber *)duration;
- (void)setDurationInMilliseconds:(NSNumber *)duration;
- (void)setFileExtension:(NSString *)extension;
- (void)setPrimaryAssetURL:(NSURL *)url;
- (void)setThumbnailImageURL:(NSURL *)url;
@end

@interface SSDownload : NSObject
- (id)initWithURL:(NSURL *)url;
- (id)initWithDownloadMetadata:(SSDownloadMetadata *)metadata;
- (void)setMetadata:(SSDownloadMetadata *)metadata;
- (void)setDownloadMetadata:(SSDownloadMetadata *)metadata;
- (id)downloadStatus;
- (NSError *)failureError;
- (NSString *)downloadIdentifier;
- (SSDownloadMetadata *)metadata;
@end

@interface SSDownloadQueue : NSObject
+ (id)downloadQueueForDownloadKind:(NSString *)kind;
+ (id)mediaDownloadKinds;
- (id)initWithDownloadKinds:(id)kinds;
- (void)addObserver:(id<SSDownloadQueueObserver>)observer;
- (void)removeObserver:(id<SSDownloadQueueObserver>)observer;
- (BOOL)addDownload:(SSDownload *)download;
- (BOOL)cancelDownload:(SSDownload *)download;
- (NSArray *)downloads;
- (void)setShouldAutomaticallyFinishDownloads:(BOOL)automaticallyFinish;
@end
