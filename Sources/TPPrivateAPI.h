#import <Foundation/Foundation.h>

@protocol SSDownloadQueueObserver <NSObject>
@optional
- (void)downloadQueue:(id)queue changedWithRemovals:(id)removals;
- (void)downloadQueue:(id)queue downloadStatesChangedAtIndexes:(id)indexes;
- (void)downloadQueue:(id)queue downloadStatusChangedAtIndex:(NSInteger)index;
@end

/*
 * All private-framework calls live behind this checked facade.  The concrete
 * classes are intentionally still opaque to the importer; this keeps one
 * objc_msgSend cast next to each runtime signature check.
 */
@interface TPPrivateAPI : NSObject
+ (BOOL)prepareStoreServices:(NSError **)error;
+ (id)newStoreMetadataWithTitle:(NSString *)title artist:(NSString *)artist durationMilliseconds:(NSNumber *)duration fileURL:(NSURL *)fileURL error:(NSError **)error;
+ (id)newStoreDownloadWithMetadata:(id)metadata error:(NSError **)error;
+ (id)newStoreQueue:(NSError **)error;
+ (BOOL)setStoreQueueAutomaticFinish:(id)queue error:(NSError **)error;
+ (BOOL)addStoreObserver:(id)observer toQueue:(id)queue error:(NSError **)error;
+ (BOOL)removeStoreObserver:(id)observer fromQueue:(id)queue error:(NSError **)error;
+ (BOOL)addStoreDownload:(id)download toQueue:(id)queue error:(NSError **)error;
+ (BOOL)cancelStoreDownload:(id)download fromQueue:(id)queue error:(NSError **)error;
+ (NSArray *)storeDownloads:(id)queue error:(NSError **)error;
+ (NSError *)storeFailureError:(id)download error:(NSError **)error;
+ (id)storeMetadataForDownload:(id)download error:(NSError **)error;
+ (NSString *)storeCollectionNameForMetadata:(id)metadata error:(NSError **)error;

+ (id)sharedMusicLibrary:(NSError **)error;
+ (id)newMusicTrackWithPersistentID:(long long)persistentID library:(id)library error:(NSError **)error;
+ (NSString *)musicTrackFilePath:(id)track error:(NSError **)error;
+ (BOOL)setMusicTrack:(id)track value:(id)value forPropertyName:(NSString *)propertyName error:(NSError **)error;
+ (id)musicTrackValue:(id)track forPropertyName:(NSString *)propertyName error:(NSError **)error;
+ (BOOL)updateMusicTrackIntegrity:(id)track error:(NSError **)error;
+ (BOOL)populateMusicTrackArtwork:(id)track data:(NSData *)data error:(NSError **)error;
+ (BOOL)deleteMusicTrack:(id)track error:(NSError **)error;
+ (BOOL)notifyMusicLibrary:(id)library error:(NSError **)error;
+ (BOOL)reloadMediaPlayerLibrary:(NSError **)error;
@end
