#import "TPImporter.h"
#import "TPPrivate.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sqlite3.h>
#import <math.h>

static NSString * const TPImportErrorDomain = @"com.pruefsumme.tubepod.import";
static NSString * const TPBridgePasteboardName = @"com.pruefsumme.tubepod.bridge";
static NSString * const TPBridgePasteboardType = @"com.pruefsumme.tubepod.request";
static NSString * const TPBridgeMediaType = @"com.pruefsumme.tubepod.media";

@interface TPImporter () <SSDownloadQueueObserver>
@property(nonatomic, copy) TPImportCompletion completion;
@property(nonatomic, copy) NSString *bridgeToken;
@property(nonatomic, strong) SSDownloadQueue *queue;
@property(nonatomic, strong) SSDownload *download;
@property(nonatomic, copy) NSString *importTitle;
@property(nonatomic, strong) NSSet *preexistingTrackIDs;
@property(nonatomic, strong) UIAlertView *musicProgressAlert;
@property(nonatomic, copy) NSString *stagedMusicPath;
@property(nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property(nonatomic) NSUInteger polls;
@property(nonatomic) NSUInteger repairPolls;
@property(nonatomic) NSUInteger cleanupPolls;
@property(nonatomic) NSUInteger cleanupQuietPolls;
@property(nonatomic) BOOL observedInQueue;
@end

@implementation TPImporter
+ (instancetype)sharedImporter { static TPImporter *x; static dispatch_once_t once; dispatch_once(&once, ^{ x = [self new]; x.backgroundTask = UIBackgroundTaskInvalid; }); return x; }

- (NSError *)error:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:TPImportErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown Music import error."}];
}

- (UIPasteboard *)bridgePasteboard {
    UIPasteboard *pasteboard = [UIPasteboard pasteboardWithName:TPBridgePasteboardName create:YES];
    pasteboard.persistent = NO;
    return pasteboard;
}

- (NSDictionary *)bridgeMessage {
    NSData *data = [[self bridgePasteboard] dataForPasteboardType:TPBridgePasteboardType];
    if (!data.length) return nil;
    return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
}

- (void)setBridgeMessage:(NSDictionary *)message mediaData:(NSData *)mediaData {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:message format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (!data) return;
    NSMutableDictionary *item = [NSMutableDictionary dictionaryWithObject:data forKey:TPBridgePasteboardType];
    if (mediaData.length) item[TPBridgeMediaType] = mediaData;
    [self bridgePasteboard].items = @[item];
}

- (void)setBridgeMessage:(NSDictionary *)message {
    [self setBridgeMessage:message mediaData:[[self bridgePasteboard] dataForPasteboardType:TPBridgeMediaType]];
}

- (void)importM4A:(NSURL *)fileURL metadata:(NSDictionary *)metadata completion:(TPImportCompletion)completion {
    if (_completion) { completion(NO, [self error:1 message:@"A Music import is already active."]); return; }
    self.completion = completion;
    self.bridgeToken = [[NSProcessInfo processInfo] globallyUniqueString];
    self.polls = 0;
    UIApplication *application = [UIApplication sharedApplication];
    __weak TPImporter *weakSelf = self;
    self.backgroundTask = [application beginBackgroundTaskWithExpirationHandler:^{
        TPImporter *importer = weakSelf;
        if (importer) [importer finishBridge:NO error:[importer error:9 message:@"YouTube ran out of background time before Music finished. The M4A was kept."]];
    }];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *mediaData = [NSData dataWithContentsOfFile:fileURL.path];
        dispatch_async(dispatch_get_main_queue(), ^{
            TPImporter *importer = weakSelf;
            if (!importer || !importer.completion) return;
            if (!mediaData.length) { [importer finishBridge:NO error:[importer error:28 message:@"TubePod could not read the completed M4A. It was kept."]]; return; }
            NSDictionary *request = @{ @"state": @"request", @"token": importer.bridgeToken,
                                       @"title": metadata[@"title"] ?: @"Untitled", @"artist": metadata[@"artist"] ?: @"Unknown Artist",
                                       @"duration": metadata[@"duration"] ?: @0, @"videoID": metadata[@"videoID"] ?: @"",
                                       @"mediaLength": @(mediaData.length) };
            [importer setBridgeMessage:request mediaData:mediaData];
            if (![application openURL:[NSURL URLWithString:@"music:"]]) { [importer finishBridge:NO error:[importer error:10 message:@"TubePod could not open Music. The M4A was kept."]]; return; }
            [importer performSelector:@selector(pollBridge) withObject:nil afterDelay:1.0];
        });
    });
}

- (void)pollBridge {
    if (!_completion || !_bridgeToken) return;
    NSDictionary *message = [self bridgeMessage];
    if ([message[@"token"] isEqualToString:_bridgeToken]) {
        NSString *state = message[@"state"];
        if ([state isEqualToString:@"success"]) { [self finishBridge:YES error:nil]; return; }
        if ([state isEqualToString:@"error"]) { [self finishBridge:NO error:[self error:11 message:message[@"message"] ?: @"Music could not import the file. The M4A was kept."]]; return; }
    }
    if (++_polls >= 180) { [self finishBridge:NO error:[self error:8 message:@"Music did not confirm the import. The M4A was kept."]]; return; }
    [self performSelector:@selector(pollBridge) withObject:nil afterDelay:1.0];
}

- (void)finishBridge:(BOOL)success error:(NSError *)error {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pollBridge) object:nil];
    if (_backgroundTask != UIBackgroundTaskInvalid) { [[UIApplication sharedApplication] endBackgroundTask:_backgroundTask]; self.backgroundTask = UIBackgroundTaskInvalid; }
    TPImportCompletion block = _completion; self.completion = nil; self.bridgeToken = nil;
    if (block) block(success, error);
}

- (void)startMusicBridgeListener {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.mobileipod"]) return;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cleanupStaleTubePodPlaceholders) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handlePendingMusicRequest) name:UIApplicationDidBecomeActiveNotification object:nil];
    [self performSelector:@selector(cleanupStaleTubePodPlaceholders) withObject:nil afterDelay:0.25];
    [self performSelector:@selector(handlePendingMusicRequest) withObject:nil afterDelay:1.0];
}

- (void)handlePendingMusicRequest {
    if (_completion) return;
    NSDictionary *request = [self bridgeMessage];
    if (![request[@"state"] isEqualToString:@"request"] || ![request[@"token"] isKindOfClass:[NSString class]]) return;
    NSData *mediaData = [[self bridgePasteboard] dataForPasteboardType:TPBridgeMediaType];
    if (!mediaData.length || [request[@"mediaLength"] unsignedIntegerValue] != mediaData.length) { [self respondToMusicRequest:request success:NO error:[self error:12 message:@"TubePod received incomplete audio data from YouTube."]]; return; }
    NSMutableDictionary *processing = [request mutableCopy]; processing[@"state"] = @"processing"; [self setBridgeMessage:processing];
    self.musicProgressAlert = [[UIAlertView alloc] initWithTitle:@"TubePod" message:@"Adding the song to Music…\nStay in Music until this finishes." delegate:nil cancelButtonTitle:nil otherButtonTitles:nil];
    [self.musicProgressAlert show];
    NSDictionary *metadata = @{ @"title": request[@"title"] ?: @"Untitled", @"artist": request[@"artist"] ?: @"Unknown Artist",
                                @"album": @"TubePod", @"duration": request[@"duration"] ?: @0, @"videoID": request[@"videoID"] ?: @"" };
    __weak TPImporter *weakSelf = self;
    [self stageAndImportData:mediaData metadata:metadata completion:^(BOOL success, NSError *error) { [weakSelf respondToMusicRequest:request success:success error:error]; }];
}

- (void)respondToMusicRequest:(NSDictionary *)request success:(BOOL)success error:(NSError *)error {
    [_musicProgressAlert dismissWithClickedButtonIndex:-1 animated:NO];
    self.musicProgressAlert = nil;
    [self setBridgeMessage:@{ @"state": success ? @"success" : @"error", @"token": request[@"token"] ?: @"", @"message": error.localizedDescription ?: @"" } mediaData:nil];
    NSString *message = success ? @"The song was added to Music." : (error.localizedDescription ?: @"The song could not be imported.");
    [[[UIAlertView alloc] initWithTitle:success ? @"TubePod Saved" : @"TubePod Error" message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
}

- (NSSet *)trackIDsForTitle:(NSString *)title completedOnly:(BOOL)completedOnly {
    sqlite3 *database = NULL;
    NSMutableSet *result = [NSMutableSet set];
    if (sqlite3_open_v2("/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb", &database, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (database) sqlite3_close(database);
        return result;
    }
    const char *SQL = completedOnly
        ? "SELECT e.item_pid FROM item_extra e JOIN item_stats s USING(item_pid) WHERE e.title=? AND e.location<>'' AND s.is_downloading=0 ORDER BY e.date_created DESC"
        : "SELECT item_pid FROM item_extra WHERE title=?";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(database, SQL, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, title.UTF8String, -1, SQLITE_TRANSIENT);
        while (sqlite3_step(statement) == SQLITE_ROW) [result addObject:@(sqlite3_column_int64(statement, 0))];
    }
    if (statement) sqlite3_finalize(statement);
    sqlite3_close(database);
    return result;
}

- (NSSet *)emptyPlaceholderTrackIDsForTitle:(NSString *)title {
    sqlite3 *database = NULL;
    NSMutableSet *result = [NSMutableSet set];
    if (sqlite3_open_v2("/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb", &database, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (database) sqlite3_close(database);
        return result;
    }
    const char *SQL = "SELECT e.item_pid FROM item_extra e JOIN item_stats s USING(item_pid) WHERE e.title=? AND e.location='' AND s.is_downloading=1";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(database, SQL, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, title.UTF8String, -1, SQLITE_TRANSIENT);
        while (sqlite3_step(statement) == SQLITE_ROW) [result addObject:@(sqlite3_column_int64(statement, 0))];
    }
    if (statement) sqlite3_finalize(statement);
    sqlite3_close(database);
    return result;
}

- (NSSet *)allEmptyTubePodPlaceholderTrackIDs {
    sqlite3 *database = NULL;
    NSMutableSet *result = [NSMutableSet set];
    if (sqlite3_open_v2("/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb", &database, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (database) sqlite3_close(database);
        return result;
    }
    const char *SQL = "SELECT e.item_pid FROM item_extra e JOIN item i USING(item_pid) JOIN album a ON a.album_pid=i.album_pid JOIN item_stats s USING(item_pid) WHERE a.album='TubePod' AND e.location='' AND s.is_downloading=1";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(database, SQL, -1, &statement, NULL) == SQLITE_OK) {
        while (sqlite3_step(statement) == SQLITE_ROW) [result addObject:@(sqlite3_column_int64(statement, 0))];
    }
    if (statement) sqlite3_finalize(statement);
    sqlite3_close(database);
    return result;
}

- (void)deleteTrackIDs:(NSSet *)trackIDs notify:(BOOL)notify {
    if (!trackIDs.count) return;
    void *framework = dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_NOW);
    Class libraryClass = NSClassFromString(@"ML3MusicLibrary"), trackClass = NSClassFromString(@"ML3Track");
    id library = framework && libraryClass ? ((id(*)(id,SEL))objc_msgSend)(libraryClass, NSSelectorFromString(@"sharedLibrary")) : nil;
    BOOL changed = NO;
    for (NSNumber *trackID in trackIDs) {
        id track = trackClass && library ? ((id(*)(id,SEL,long long,id))objc_msgSend)(trackClass, NSSelectorFromString(@"newWithPersistentID:inLibrary:"), trackID.longLongValue, library) : nil;
        if (track && ((BOOL(*)(id,SEL))objc_msgSend)(track, NSSelectorFromString(@"deleteFromLibrary"))) changed = YES;
    }
    if (changed && notify) {
        ((void(*)(id,SEL))objc_msgSend)(library, NSSelectorFromString(@"notifyContentsDidChange"));
        dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", RTLD_NOW);
        Class mediaLibraryClass = NSClassFromString(@"MPMediaLibrary");
        id mediaLibrary = mediaLibraryClass ? ((id(*)(id,SEL))objc_msgSend)(mediaLibraryClass, NSSelectorFromString(@"defaultMediaLibrary")) : nil;
        SEL reload = NSSelectorFromString(@"_reloadLibraryForContentsChangeWithNotificationInfo:");
        if ([mediaLibrary respondsToSelector:reload]) ((void(*)(id,SEL,id))objc_msgSend)(mediaLibrary, reload, nil);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MPMediaLibraryDidChangeNotification" object:mediaLibrary];
    }
}

- (void)cleanupStaleTubePodPlaceholders {
    if (_completion) return;
    [self deleteTrackIDs:[self allEmptyTubePodPlaceholderTrackIDs] notify:YES];
}

- (void)stageAndImportData:(NSData *)mediaData metadata:(NSDictionary *)metadata completion:(TPImportCompletion)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *directory = @"/var/mobile/Media/TubePod";
        NSString *name = [NSString stringWithFormat:@"%@.m4a", [[NSProcessInfo processInfo] globallyUniqueString]];
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error ?: [self error:25 message:@"Music could not create its TubePod staging folder."]); });
            return;
        }
        if (!mediaData.length || ![mediaData writeToFile:path options:NSDataWritingAtomic error:&error]) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, [self error:26 message:error.localizedDescription ?: @"Music could not write the staged M4A."]); });
            return;
        }
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        if (![asset tracksWithMediaType:AVMediaTypeAudio].count) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, [self error:27 message:[NSString stringWithFormat:@"Music received the file, but AVFoundation found no audio. The staging copy was kept at %@.", path]]); });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.stagedMusicPath = path;
            [self startStoreImportURL:[NSURL fileURLWithPath:path] metadata:metadata completion:completion];
        });
    });
}

- (void)startStoreImportURL:(NSURL *)assetURL metadata:(NSDictionary *)metadata completion:(TPImportCompletion)completion {
    if (_completion) { completion(NO, [self error:15 message:@"Music is already importing a TubePod song."]); return; }
    void *framework = dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", RTLD_NOW);
    Class metadataClass = NSClassFromString(@"SSDownloadMetadata"), downloadClass = NSClassFromString(@"SSDownload"), queueClass = NSClassFromString(@"SSDownloadQueue");
    if (!framework || !metadataClass || !downloadClass || !queueClass) { completion(NO, [self error:16 message:@"The required Apple StoreServices API is unavailable."]); return; }

    NSString *title = [metadata[@"title"] isKindOfClass:[NSString class]] ? metadata[@"title"] : @"Untitled";
    SSDownloadMetadata *downloadMetadata = [[metadataClass alloc] initWithKind:@"song"];
    [downloadMetadata setTitle:title];
    [downloadMetadata setArtistName:[metadata[@"artist"] isKindOfClass:[NSString class]] ? metadata[@"artist"] : @"Unknown Artist"];
    [downloadMetadata setCollectionName:@"TubePod"];
    [downloadMetadata setDurationInMilliseconds:@((long long)([metadata[@"duration"] doubleValue] * 1000.0))];
    [downloadMetadata setFileExtension:@"m4a"];
    [downloadMetadata setPrimaryAssetURL:assetURL];

    SSDownload *download = [[downloadClass alloc] initWithDownloadMetadata:downloadMetadata];
    SSDownloadQueue *queue = [[queueClass alloc] initWithDownloadKinds:[queueClass mediaDownloadKinds]];
    [queue setShouldAutomaticallyFinishDownloads:YES];
    [queue addObserver:self];
    for (SSDownload *oldDownload in [queue downloads]) {
        SSDownloadMetadata *oldMetadata = [oldDownload metadata];
        if ([[oldMetadata collectionName] isEqualToString:@"TubePod"]) [queue cancelDownload:oldDownload];
    }
    self.importTitle = title;
    self.preexistingTrackIDs = [self trackIDsForTitle:title completedOnly:NO];
    self.download = download;
    self.queue = queue;
    self.completion = completion;
    self.observedInQueue = NO;
    self.polls = 0;
    self.repairPolls = 0;
    UIApplication *application = [UIApplication sharedApplication];
    __weak TPImporter *weakSelf = self;
    self.backgroundTask = [application beginBackgroundTaskWithExpirationHandler:^{
        TPImporter *importer = weakSelf;
        if (importer) [importer finishStoreImport:NO error:[importer error:24 message:@"Music ran out of background time before the import finished."]];
    }];
    if (![queue addDownload:download]) { [self finishStoreImport:NO error:[self error:17 message:@"Apple's StoreServices rejected the import request."]]; return; }
    [self performSelector:@selector(pollStoreImport) withObject:nil afterDelay:0.5];
}

- (void)downloadQueue:(id)queue changedWithRemovals:(id)removals { (void)queue; (void)removals; [self pollStoreImport]; }
- (void)downloadQueue:(id)queue downloadStatesChangedAtIndexes:(id)indexes { (void)queue; (void)indexes; [self pollStoreImport]; }
- (void)downloadQueue:(id)queue downloadStatusChangedAtIndex:(NSInteger)index { (void)queue; (void)index; [self pollStoreImport]; }

- (void)pollStoreImport {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pollStoreImport) object:nil];
    if (!_completion || !_queue || !_download) return;
    NSError *failure = [_download failureError];
    if (failure) { [self finishStoreImport:NO error:[self error:18 message:failure.localizedDescription ?: @"StoreServices could not import the M4A."]]; return; }
    BOOL present = [[_queue downloads] containsObject:_download];
    if (present) self.observedInQueue = YES;
    if (_observedInQueue && !present) { [self performSelector:@selector(repairImportedTrack) withObject:nil afterDelay:0.5]; return; }
    if (++_polls >= 360) { [self finishStoreImport:NO error:[self error:19 message:@"Music did not finish the StoreServices import."]]; return; }
    [self performSelector:@selector(pollStoreImport) withObject:nil afterDelay:0.5];
}

static NSString *TPMusicProperty(void *handle, const char *name) {
    NSString * __unsafe_unretained *address = (NSString * __unsafe_unretained *)dlsym(handle, name);
    return address ? *address : nil;
}

- (void)repairImportedTrack {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(repairImportedTrack) object:nil];
    if (!_completion || !_importTitle) return;
    NSMutableSet *candidates = [[self trackIDsForTitle:_importTitle completedOnly:YES] mutableCopy];
    [candidates minusSet:_preexistingTrackIDs ?: [NSSet set]];
    NSNumber *persistentID = candidates.anyObject;
    if (!persistentID) {
        if (++_repairPolls < 30) { [self performSelector:@selector(repairImportedTrack) withObject:nil afterDelay:0.5]; return; }
        [self finishStoreImport:NO error:[self error:20 message:@"Music created no completed track to repair."]];
        return;
    }

    void *framework = dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_NOW);
    Class libraryClass = NSClassFromString(@"ML3MusicLibrary"), trackClass = NSClassFromString(@"ML3Track");
    if (!framework || !libraryClass || !trackClass) { [self finishStoreImport:NO error:[self error:21 message:@"MusicLibrary is unavailable for the final audio repair."]]; return; }
    id library = ((id(*)(id,SEL))objc_msgSend)(libraryClass, NSSelectorFromString(@"sharedLibrary"));
    id track = ((id(*)(id,SEL,long long,id))objc_msgSend)(trackClass, NSSelectorFromString(@"newWithPersistentID:inLibrary:"), persistentID.longLongValue, library);
    NSString *path = ((id(*)(id,SEL))objc_msgSend)(track, NSSelectorFromString(@"absoluteFilePath"));
    AVURLAsset *asset = path.length ? [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil] : nil;
    NSArray *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    AVAssetTrack *audioTrack = audioTracks.count ? audioTracks[0] : nil;
    const AudioStreamBasicDescription *description = NULL;
    if (audioTrack.formatDescriptions.count) description = CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)audioTrack.formatDescriptions[0]);
    long long sampleRate = description ? llround(description->mSampleRate) : 0;
    long long durationInSamples = sampleRate > 0 && CMTIME_IS_NUMERIC(asset.duration) ? CMTimeConvertScale(asset.duration, (int32_t)sampleRate, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value : 0;
    long long bitRate = llround(audioTrack.estimatedDataRate / 1000.0);
    if (!track || sampleRate <= 0 || durationInSamples <= 0 || bitRate <= 0) {
        if (++_repairPolls < 30) { [self performSelector:@selector(repairImportedTrack) withObject:nil afterDelay:0.5]; return; }
        [self finishStoreImport:NO error:[self error:22 message:@"Music imported the track but could not read its audio format."]];
        return;
    }

    NSString *sampleProperty = TPMusicProperty(framework, "ML3TrackPropertySampleRate");
    NSString *durationProperty = TPMusicProperty(framework, "ML3TrackPropertyDurationInSamples");
    NSString *bitRateProperty = TPMusicProperty(framework, "ML3TrackPropertyBitRate");
    SEL setValue = NSSelectorFromString(@"setValue:forProperty:");
    BOOL sampleOK = sampleProperty && ((BOOL(*)(id,SEL,id,id))objc_msgSend)(track, setValue, @(sampleRate), sampleProperty);
    BOOL durationOK = durationProperty && ((BOOL(*)(id,SEL,id,id))objc_msgSend)(track, setValue, @(durationInSamples), durationProperty);
    BOOL bitRateOK = bitRateProperty && ((BOOL(*)(id,SEL,id,id))objc_msgSend)(track, setValue, @(bitRate), bitRateProperty);
    BOOL integrityOK = ((BOOL(*)(id,SEL))objc_msgSend)(track, NSSelectorFromString(@"updateIntegrity"));
    if (!sampleOK || !durationOK || !bitRateOK || !integrityOK) { [self finishStoreImport:NO error:[self error:23 message:@"Music imported the track but rejected its audio metadata repair."]]; return; }
    ((void(*)(id,SEL))objc_msgSend)(library, NSSelectorFromString(@"notifyContentsDidChange"));

    self.cleanupPolls = 0;
    self.cleanupQuietPolls = 0;
    [self performSelector:@selector(pollPostImportCleanup) withObject:nil afterDelay:0.5];
}

- (void)pollPostImportCleanup {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pollPostImportCleanup) object:nil];
    if (!_completion || !_importTitle.length) return;
    NSMutableSet *emptyTrackIDs = [[self emptyPlaceholderTrackIDsForTitle:_importTitle] mutableCopy];
    [emptyTrackIDs minusSet:_preexistingTrackIDs ?: [NSSet set]];
    if (emptyTrackIDs.count) {
        [self deleteTrackIDs:emptyTrackIDs notify:YES];
        self.cleanupQuietPolls = 0;
    } else {
        self.cleanupQuietPolls++;
    }
    self.cleanupPolls++;
    if ((_cleanupPolls >= 8 && _cleanupQuietPolls >= 2) || _cleanupPolls >= 16) {
        [self finishStoreImport:YES error:nil];
        return;
    }
    [self performSelector:@selector(pollPostImportCleanup) withObject:nil afterDelay:0.5];
}

- (void)finishStoreImport:(BOOL)success error:(NSError *)error {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pollStoreImport) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(repairImportedTrack) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pollPostImportCleanup) object:nil];
    if (!success && _queue && _download) [_queue cancelDownload:_download];
    [_queue removeObserver:self];
    if (!success && _importTitle.length) {
        void *framework = dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_NOW);
        Class libraryClass = NSClassFromString(@"ML3MusicLibrary"), trackClass = NSClassFromString(@"ML3Track");
        id library = framework && libraryClass ? ((id(*)(id,SEL))objc_msgSend)(libraryClass, NSSelectorFromString(@"sharedLibrary")) : nil;
        NSMutableSet *emptyTrackIDs = [[self emptyPlaceholderTrackIDsForTitle:_importTitle] mutableCopy];
        [emptyTrackIDs minusSet:_preexistingTrackIDs ?: [NSSet set]];
        for (NSNumber *trackID in emptyTrackIDs) {
            id track = trackClass && library ? ((id(*)(id,SEL,long long,id))objc_msgSend)(trackClass, NSSelectorFromString(@"newWithPersistentID:inLibrary:"), trackID.longLongValue, library) : nil;
            if (track) ((BOOL(*)(id,SEL))objc_msgSend)(track, NSSelectorFromString(@"deleteFromLibrary"));
        }
        if (library) ((void(*)(id,SEL))objc_msgSend)(library, NSSelectorFromString(@"notifyContentsDidChange"));
    }
    if (_backgroundTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:_backgroundTask];
        self.backgroundTask = UIBackgroundTaskInvalid;
    }
    if (success && _stagedMusicPath.length) [[NSFileManager defaultManager] removeItemAtPath:_stagedMusicPath error:NULL];
    self.stagedMusicPath = nil;
    TPImportCompletion block = _completion;
    self.completion = nil;
    self.queue = nil;
    self.download = nil;
    self.importTitle = nil;
    self.preexistingTrackIDs = nil;
    if (block) block(success, error);
}
@end
