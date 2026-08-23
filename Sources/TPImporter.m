#import "TPImporter.h"
#import "TPBridge.h"
#import "TPMusicDatabase.h"
#import "TPPrivateAPI.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <math.h>

static NSString * const TPImportErrorDomain = @"com.pruefsumme.tubepod.import";
static NSString * const TPMusicAlbum = @"TubePod";
static NSString * const TPLedgerPath = @"/var/mobile/Media/TubePod/transactions.plist";
static NSTimeInterval const TPLedgerRetention = 7.0 * 24.0 * 60.0 * 60.0;

@interface TPImporter () <SSDownloadQueueObserver>
@property(nonatomic, copy) TPImportCompletion completion;
@property(nonatomic, copy) NSString *bridgeToken;
@property(nonatomic, copy) NSString *bridgeVideoID;
@property(nonatomic, strong) id queue;
@property(nonatomic, strong) id download;
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
@property(nonatomic, copy) NSString *activeMusicToken;
@property(nonatomic, copy) NSDictionary *activeMusicRequest;
@property(nonatomic) BOOL cancelRequested;
@property(nonatomic) BOOL playableResultVerified;
@property(nonatomic, strong) NSNumber *importedPersistentID;
@property(nonatomic) BOOL artworkExpected;
@property(nonatomic) BOOL artworkEmbedded;
@property(nonatomic) BOOL artworkRegistered;
@end

static NSError *TPImportError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:TPImportErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown Music import error."}];
}

static NSString *TPResultForStatus(TPBridgeStatusKind kind) {
    return [TPBridge statusNameForKind:kind];
}

static NSMutableDictionary *TPLoadLedger(void) {
    id storedLedger = [NSDictionary dictionaryWithContentsOfFile:TPLedgerPath];
    NSMutableDictionary *ledger = [storedLedger isKindOfClass:[NSDictionary class]] ? [storedLedger mutableCopy] : [NSMutableDictionary dictionary];
    NSDate *now = [NSDate date];
    NSMutableArray *expired = [NSMutableArray array];
    [ledger enumerateKeysAndObjectsUsingBlock:^(id videoID, id storedEntry, BOOL *stop) {
        (void)stop;
        if (!TPVideoIDIsValid(videoID) || ![storedEntry isKindOfClass:[NSDictionary class]]) { [expired addObject:videoID]; return; }
        NSDictionary *entry = storedEntry;
        NSDate *date = entry[@"completionDate"];
        if (![date isKindOfClass:[NSDate class]] || (![entry[@"result"] isEqualToString:@"success"] && [now timeIntervalSinceDate:date] > TPLedgerRetention)) [expired addObject:videoID];
    }];
    [ledger removeObjectsForKeys:expired];
    if (expired.count) [ledger writeToFile:TPLedgerPath atomically:YES];
    return ledger;
}

static BOOL TPRecordLedger(NSString *videoID, NSString *token, NSString *result, NSNumber *persistentID, NSError **error) {
    if (!TPVideoIDIsValid(videoID) || !token.length || !result.length) { if (error) *error = TPImportError(40, @"Music could not record an invalid transaction state."); return NO; }
    NSString *directory = [TPLedgerPath stringByDeletingLastPathComponent];
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&directoryError]) { if (error) *error = directoryError ?: TPImportError(41, @"Music could not create its transaction ledger folder."); return NO; }
    NSMutableDictionary *ledger = TPLoadLedger();
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:@{TPBridgeVersionKey: @(TPBridgeProtocolVersion), TPBridgeVideoIDKey: videoID, TPBridgeTokenKey: token, @"result": result, @"completionDate": [NSDate date]}];
    if (persistentID) entry[@"musicPersistentID"] = persistentID;
    ledger[videoID] = entry;
    if (![ledger writeToFile:TPLedgerPath atomically:YES]) { if (error) *error = TPImportError(42, @"Music could not atomically update its transaction ledger."); return NO; }
    return YES;
}

static NSDictionary *TPLedgerEntry(NSString *videoID) {
    return TPLoadLedger()[videoID];
}

@implementation TPImporter
+ (instancetype)sharedImporter { static TPImporter *x; static dispatch_once_t once; dispatch_once(&once, ^{ x = [self new]; x.backgroundTask = UIBackgroundTaskInvalid; }); return x; }

- (NSError *)error:(NSInteger)code message:(NSString *)message { return TPImportError(code, message); }

- (BOOL)verifyLedgerSuccess:(NSDictionary *)entry error:(NSError **)error {
    NSNumber *persistentID = entry[@"musicPersistentID"];
    if (![persistentID isKindOfClass:[NSNumber class]]) return NO;
    NSDictionary *record = [TPMusicDatabase recordForPersistentID:persistentID error:error];
    if (!record) return NO;
    if (![record[@"album"] isEqualToString:TPMusicAlbum] || ![record[@"title"] length] || ![record[@"location"] length] || [record[@"downloading"] boolValue]) return NO;
    NSError *privateError = nil;
    id library = [TPPrivateAPI sharedMusicLibrary:&privateError];
    id track = library ? [TPPrivateAPI newMusicTrackWithPersistentID:persistentID.longLongValue library:library error:&privateError] : nil;
    NSString *path = track ? [TPPrivateAPI musicTrackFilePath:track error:&privateError] : nil;
    NSDictionary *attributes = path.length ? [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&privateError] : nil;
    if (!track || !path.length || !attributes || [attributes[NSFileSize] unsignedLongLongValue] == 0) { if (error && privateError) *error = privateError; return NO; }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] count] ? [[asset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0] : nil;
    if (!audioTrack) return NO;
    id sampleRate = [TPPrivateAPI musicTrackValue:track forPropertyName:@"ML3TrackPropertySampleRate" error:&privateError];
    id duration = [TPPrivateAPI musicTrackValue:track forPropertyName:@"ML3TrackPropertyDurationInSamples" error:&privateError];
    id bitRate = [TPPrivateAPI musicTrackValue:track forPropertyName:@"ML3TrackPropertyBitRate" error:&privateError];
    if (![sampleRate respondsToSelector:@selector(longLongValue)] || ![duration respondsToSelector:@selector(longLongValue)] || ![bitRate respondsToSelector:@selector(longLongValue)] || [sampleRate longLongValue] <= 0 || [duration longLongValue] <= 0 || [bitRate longLongValue] <= 0) { if (error && privateError) *error = privateError; return NO; }
    return YES;
}

- (BOOL)writeStatus:(TPBridgeStatusKind)kind token:(NSString *)token message:(NSString *)message error:(NSError **)error {
    return [TPBridge writeStatus:[TPBridge statusWithKind:kind token:token message:message] error:error];
}

- (void)pollActiveMusicCommand {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pollActiveMusicCommand) object:nil];
    if (!_activeMusicToken.length) return;
    NSDictionary *command = [TPBridge readCommand];
    NSError *error = nil;
    if ([TPBridge validateCommand:command error:&error] &&
        [command[TPBridgeTokenKey] isEqualToString:_activeMusicToken] &&
        [command[TPBridgeCommandKey] isEqualToString:@"cancel"]) {
        [self cancelActiveMusicRequest];
    }
    if (_activeMusicToken.length) [self performSelector:@selector(pollActiveMusicCommand) withObject:nil afterDelay:0.5];
}

- (void)importM4A:(NSURL *)fileURL metadata:(NSDictionary *)metadata completion:(TPImportCompletion)completion {
    if (_completion) { completion(NO, [self error:1 message:@"A Music import is already active."]); return; }
    NSString *videoID = metadata[TPBridgeVideoIDKey];
    if (!TPVideoIDIsValid(videoID) || !fileURL.isFileURL || !fileURL.path.length) { completion(NO, [self error:2 message:@"The import has an invalid video ID or local file."]); return; }
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:fileURL.path error:NULL];
    unsigned long long expectedLength = [attributes[NSFileSize] unsignedLongLongValue];
    if (!attributes || expectedLength == 0) { completion(NO, [self error:28 message:@"TubePod could not read the completed M4A. It was kept."]); return; }
    if (expectedLength > TPBridgeMaximumMediaBytes) { completion(NO, [self error:29 message:@"The converted M4A is larger than 24 MiB and was kept before pasteboard loading."]); return; }
    self.completion = completion;
    self.bridgeToken = [[NSProcessInfo processInfo] globallyUniqueString];
    self.bridgeVideoID = videoID;
    UIApplication *application = [UIApplication sharedApplication];
    __weak TPImporter *weakSelf = self;
    self.backgroundTask = [application beginBackgroundTaskWithExpirationHandler:^{
        TPImporter *importer = weakSelf;
        if (importer && importer.completion) {
            NSError *cancelError = nil;
            [importer publishCancelForToken:importer.bridgeToken error:&cancelError];
            [importer finishBridge:NO error:[importer error:9 message:@"YouTube ran out of background time before Music finished. The M4A was kept."]];
        }
    }];
    NSString *path = fileURL.path;
    NSString *token = _bridgeToken;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *mediaData = nil;
        @autoreleasepool {
            mediaData = [[NSData dataWithContentsOfFile:path] copy];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            TPImporter *importer = weakSelf;
            if (!importer || !importer.completion || ![importer.bridgeToken isEqualToString:token]) return;
            NSDictionary *afterAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
            if (!mediaData.length || !afterAttributes || [mediaData length] != [afterAttributes[NSFileSize] unsignedLongLongValue] || mediaData.length != expectedLength) { [importer finishBridge:NO error:[importer error:28 message:@"TubePod could not read a stable completed M4A. It was kept."]]; return; }
            NSError *bridgeError = nil;
            if (![TPBridge writePayload:mediaData error:&bridgeError]) { [importer finishBridge:NO error:bridgeError]; return; }
            NSDictionary *request = [TPBridge requestCommandWithToken:token videoID:videoID sourceVideoID:metadata[TPBridgeSourceVideoIDKey] ?: videoID title:metadata[@"title"] artist:metadata[@"artist"] duration:metadata[@"duration"] mediaLength:mediaData.length artworkData:metadata[TPBridgeArtworkDataKey] allowDuplicate:[metadata[TPBridgeAllowDuplicateKey] boolValue] error:&bridgeError];
            if (!request || ![TPBridge writeCommand:request error:&bridgeError]) { [TPBridge clearPayload]; [importer finishBridge:NO error:bridgeError ?: [importer error:30 message:@"TubePod could not publish its Music request."]]; return; }
            if (![application openURL:[NSURL URLWithString:@"music:"]]) { [importer publishCancelForToken:token error:NULL]; [importer finishBridge:NO error:[importer error:10 message:@"TubePod could not open Music. The M4A was kept."]]; return; }
            [importer performSelector:@selector(pollBridge) withObject:nil afterDelay:1.0];
        });
    });
}

- (BOOL)publishCancelForToken:(NSString *)token error:(NSError **)error {
    NSString *videoID = self.bridgeVideoID;
    NSDictionary *existing = [TPBridge readCommand];
    if (!videoID.length && [existing[TPBridgeVideoIDKey] isKindOfClass:[NSString class]]) videoID = existing[TPBridgeVideoIDKey];
    NSDictionary *cancel = [TPBridge cancelCommandWithToken:token videoID:videoID error:error];
    return cancel && [TPBridge writeCommand:cancel error:error];
}

- (void)pollBridge {
    if (!_completion || !_bridgeToken) return;
    NSDictionary *status = [TPBridge readStatus];
    NSError *validationError = nil;
    if ([TPBridge validateStatus:status error:&validationError] && [status[TPBridgeTokenKey] isEqualToString:_bridgeToken]) {
        TPBridgeStatusKind kind = [TPBridge statusKindForName:status[TPBridgeStatusKey]];
        if (kind == TPBridgeStatusKindSuccess) { [self finishBridge:YES error:nil]; return; }
        NSString *statusMessage = [status[TPBridgeMessageKey] isKindOfClass:[NSString class]] ? status[TPBridgeMessageKey] : @"";
        if (kind == TPBridgeStatusKindCancelled) { [self finishBridge:NO error:[self error:NSURLErrorCancelled message:statusMessage.length ? statusMessage : @"Music cancelled the import."]]; return; }
        if (kind == TPBridgeStatusKindError) { [self finishBridge:NO error:[self error:11 message:statusMessage.length ? statusMessage : @"Music could not import the file. The M4A was kept."]]; return; }
    }
    if (++_polls >= 180) { [self publishCancelForToken:_bridgeToken error:NULL]; [self finishBridge:NO error:[self error:8 message:@"Music did not confirm the import. The M4A was kept."]]; return; }
    [self performSelector:@selector(pollBridge) withObject:nil afterDelay:1.0];
}

- (void)finishBridge:(BOOL)success error:(NSError *)error {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pollBridge) object:nil];
    if (_backgroundTask != UIBackgroundTaskInvalid) { [[UIApplication sharedApplication] endBackgroundTask:_backgroundTask]; self.backgroundTask = UIBackgroundTaskInvalid; }
    [TPBridge clearCommand];
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
    NSDictionary *command = [TPBridge readCommand];
    if (!command) return;
    NSError *validationError = nil;
    if (![TPBridge validateCommand:command error:&validationError]) { [TPBridge clearPayload]; [TPBridge clearCommand]; return; }
    NSString *token = command[TPBridgeTokenKey];
    NSString *videoID = command[TPBridgeVideoIDKey];
    BOOL allowDuplicate = [command[TPBridgeAllowDuplicateKey] boolValue];
    NSDictionary *entry = TPLedgerEntry(videoID);
    BOOL isCancel = [command[TPBridgeCommandKey] isEqualToString:@"cancel"];
    if (isCancel) {
        if (_activeMusicToken.length && [_activeMusicToken isEqualToString:token]) { [self cancelActiveMusicRequest]; return; }
        if ([entry[TPBridgeTokenKey] isEqualToString:token] && [entry[@"result"] isEqualToString:@"success"]) { [self writeStatus:TPBridgeStatusKindSuccess token:token message:@"" error:NULL]; return; }
        if ([entry[TPBridgeTokenKey] isEqualToString:token] && [entry[@"result"] isEqualToString:@"cancelled"]) { [self writeStatus:TPBridgeStatusKindCancelled token:token message:@"Import cancelled." error:NULL]; return; }
        TPRecordLedger(videoID, token, @"cancelled", nil, NULL);
        [TPBridge clearPayload];
        [self writeStatus:TPBridgeStatusKindCancelled token:token message:@"Import cancelled before Music started." error:NULL];
        return;
    }
    if (_activeMusicToken.length) {
        if ([_activeMusicToken isEqualToString:token]) return;
        [self writeStatus:TPBridgeStatusKindError token:token message:@"Music is already importing another TubePod song." error:NULL];
        return;
    }
    if ([entry[TPBridgeTokenKey] isEqualToString:token] && ![entry[@"result"] isEqualToString:@"processing"]) {
        NSString *result = entry[@"result"];
        if ([result isEqualToString:@"success"]) {
            NSError *verifyError = nil;
            if ([self verifyLedgerSuccess:entry error:&verifyError]) { [TPBridge clearPayload]; [self writeStatus:TPBridgeStatusKindSuccess token:token message:@"Already imported." error:NULL]; return; }
            if (verifyError) { [TPBridge clearPayload]; [self writeStatus:TPBridgeStatusKindError token:token message:verifyError.localizedDescription error:NULL]; return; }
        } else {
            [TPBridge clearPayload];
            [self writeStatus:([result isEqualToString:@"cancelled"] ? TPBridgeStatusKindCancelled : TPBridgeStatusKindError) token:token message:([result isEqualToString:@"cancelled"] ? @"Import cancelled." : @"The previous import failed.") error:NULL];
            return;
        }
    }
    if (!allowDuplicate && [entry[@"result"] isEqualToString:@"success"]) {
        NSError *verifyError = nil;
        if ([self verifyLedgerSuccess:entry error:&verifyError]) { TPRecordLedger(videoID, token, @"success", entry[@"musicPersistentID"], NULL); [TPBridge clearPayload]; [self writeStatus:TPBridgeStatusKindSuccess token:token message:@"Already imported." error:NULL]; return; }
        if (verifyError) { [TPBridge clearPayload]; [self writeStatus:TPBridgeStatusKindError token:token message:verifyError.localizedDescription error:NULL]; return; }
        NSMutableDictionary *ledger = TPLoadLedger(); [ledger removeObjectForKey:videoID]; [ledger writeToFile:TPLedgerPath atomically:YES];
    }
    NSData *mediaData = nil;
    @autoreleasepool { mediaData = [[TPBridge readPayload] copy]; }
    NSUInteger expectedLength = [command[TPBridgeMediaLengthKey] unsignedIntegerValue];
    if (!mediaData.length || mediaData.length > TPBridgeMaximumMediaBytes || expectedLength != mediaData.length) {
        [TPBridge clearPayload]; TPRecordLedger(videoID, token, @"failure", nil, NULL); [self writeStatus:TPBridgeStatusKindError token:token message:@"TubePod received incomplete or oversized audio data." error:NULL]; return;
    }
    self.activeMusicToken = token;
    self.activeMusicRequest = command;
    self.cancelRequested = NO;
    self.playableResultVerified = NO;
    self.artworkExpected = [command[TPBridgeArtworkDataKey] length] > 0;
    self.artworkEmbedded = NO;
    self.artworkRegistered = NO;
    if (!TPRecordLedger(videoID, token, @"processing", nil, &validationError)) { [self respondToMusicRequest:command kind:TPBridgeStatusKindError error:validationError persistentID:nil]; return; }
    [self writeStatus:TPBridgeStatusKindProcessing token:token message:@"" error:NULL];
    [self performSelector:@selector(pollActiveMusicCommand) withObject:nil afterDelay:0.5];
    self.musicProgressAlert = [[UIAlertView alloc] initWithTitle:@"TubePod" message:@"Adding the song to Music…\nStay in Music until this finishes." delegate:nil cancelButtonTitle:nil otherButtonTitles:nil];
    [self.musicProgressAlert show];
    NSDictionary *metadata = @{ @"title": command[@"title"] ?: @"Untitled", @"artist": command[@"artist"] ?: @"Unknown Artist", @"album": TPMusicAlbum, @"duration": command[@"duration"] ?: @0, TPBridgeVideoIDKey: videoID, TPBridgeArtworkDataKey: command[TPBridgeArtworkDataKey] ?: [NSData data] };
    __weak TPImporter *weakSelf = self;
    [self stageAndImportData:mediaData metadata:metadata completion:^(BOOL success, NSError *error) {
        TPImporter *importer = weakSelf;
        if (!importer || ![importer.activeMusicToken isEqualToString:token]) return;
        if (importer.cancelRequested) { [importer respondToMusicRequest:command kind:TPBridgeStatusKindCancelled error:nil persistentID:nil]; return; }
        if (!success) { [importer respondToMusicRequest:command kind:TPBridgeStatusKindError error:error persistentID:nil]; return; }
        [importer startStoreImportURL:[NSURL fileURLWithPath:importer.stagedMusicPath] metadata:metadata completion:^(BOOL imported, NSError *importError) {
            TPBridgeStatusKind kind = importer.cancelRequested ? TPBridgeStatusKindCancelled : (imported ? TPBridgeStatusKindSuccess : TPBridgeStatusKindError);
            [importer respondToMusicRequest:command kind:kind error:importError persistentID:importer.importedPersistentID];
        }];
    }];
}

- (void)respondToMusicRequest:(NSDictionary *)request kind:(TPBridgeStatusKind)kind error:(NSError *)error persistentID:(NSNumber *)persistentID {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pollActiveMusicCommand) object:nil];
    NSString *token = request[TPBridgeTokenKey]; NSString *videoID = request[TPBridgeVideoIDKey];
    NSString *result = TPResultForStatus(kind);
    NSError *ledgerError = nil;
    if (!TPRecordLedger(videoID, token, result, kind == TPBridgeStatusKindSuccess ? persistentID : nil, &ledgerError) && kind == TPBridgeStatusKindSuccess) { kind = TPBridgeStatusKindError; result = @"error"; error = ledgerError; TPRecordLedger(videoID, token, result, nil, NULL); }
    [TPBridge clearPayload];
    [self writeStatus:kind token:token message:error.localizedDescription ?: (kind == TPBridgeStatusKindSuccess ? @"" : (kind == TPBridgeStatusKindCancelled ? @"Import cancelled." : @"The song could not be imported.")) error:NULL];
    [_musicProgressAlert dismissWithClickedButtonIndex:-1 animated:NO]; self.musicProgressAlert = nil;
    NSString *message = kind == TPBridgeStatusKindSuccess ? (_artworkExpected && !_artworkRegistered ? @"The song was added to Music, but Music could not register its cover." : (_artworkRegistered ? @"The song and cover were added to Music." : @"The song was added to Music.")) : (error.localizedDescription ?: (kind == TPBridgeStatusKindCancelled ? @"The import was cancelled." : @"The song could not be imported."));
    [[[UIAlertView alloc] initWithTitle:kind == TPBridgeStatusKindSuccess ? @"TubePod Saved" : (kind == TPBridgeStatusKindCancelled ? @"TubePod Cancelled" : @"TubePod Error") message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
    self.activeMusicToken = nil; self.activeMusicRequest = nil; self.cancelRequested = NO; self.playableResultVerified = NO; self.importedPersistentID = nil; self.artworkExpected = NO; self.artworkEmbedded = NO; self.artworkRegistered = NO;
}

- (void)cancelActiveMusicRequest {
    if (!_activeMusicToken.length) return;
    if (_playableResultVerified) return;
    self.cancelRequested = YES;
    if (_queue && _download) { [self finishStoreImport:NO error:[self error:NSURLErrorCancelled message:@"Music cancelled the import."]]; return; }
    if (!_completion) { NSDictionary *request = _activeMusicRequest; [self respondToMusicRequest:request kind:TPBridgeStatusKindCancelled error:nil persistentID:nil]; }
}

- (void)cleanupStaleTubePodPlaceholders {
    if (_activeMusicToken.length) return;
    NSError *error = nil;
    NSSet *ids = [TPMusicDatabase allEmptyPlaceholderTrackIDsForAlbum:TPMusicAlbum error:&error];
    if (ids && ids.count) [self deleteTrackIDs:ids notify:YES error:NULL];
}

- (BOOL)deleteTrackIDs:(NSSet *)trackIDs notify:(BOOL)notify error:(NSError **)error {
    if (!trackIDs.count) return YES;
    id library = [TPPrivateAPI sharedMusicLibrary:error];
    if (!library) return NO;
    BOOL changed = NO;
    for (NSNumber *trackID in trackIDs) {
        id track = [TPPrivateAPI newMusicTrackWithPersistentID:trackID.longLongValue library:library error:error];
        if (!track) continue;
        if (![TPPrivateAPI deleteMusicTrack:track error:error]) return NO;
        changed = YES;
    }
    if (changed && notify) { if (![TPPrivateAPI notifyMusicLibrary:library error:error]) return NO; [TPPrivateAPI reloadMediaPlayerLibrary:NULL]; }
    return YES;
}

- (void)stageAndImportData:(NSData *)mediaData metadata:(NSDictionary *)metadata completion:(TPImportCompletion)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *directory = @"/var/mobile/Media/TubePod";
        NSString *name = [NSString stringWithFormat:@"%@.m4a", [[NSProcessInfo processInfo] globallyUniqueString]];
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) { dispatch_async(dispatch_get_main_queue(), ^{ [TPBridge clearPayload]; completion(NO, error ?: TPImportError(25, @"Music could not create its TubePod staging folder.")); }); return; }
        BOOL wrote = NO;
        @autoreleasepool { wrote = mediaData.length && [mediaData writeToFile:path options:NSDataWritingAtomic error:&error]; }
        if (!wrote) { [[NSFileManager defaultManager] removeItemAtPath:path error:NULL]; dispatch_async(dispatch_get_main_queue(), ^{ [TPBridge clearPayload]; completion(NO, TPImportError(26, error.localizedDescription ?: @"Music could not write the staged M4A.")); }); return; }
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&error];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        BOOL playable = attributes && [attributes[NSFileSize] unsignedLongLongValue] == mediaData.length && [asset tracksWithMediaType:AVMediaTypeAudio].count > 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            [TPBridge clearPayload];
            if (!playable) { completion(NO, TPImportError(27, [NSString stringWithFormat:@"Music received the file, but AVFoundation found no playable audio. The staging copy was kept at %@.", path])); return; }
            NSData *artworkData = metadata[TPBridgeArtworkDataKey];
            if (!artworkData.length) { self.stagedMusicPath = path; completion(YES, nil); return; }
            NSString *taggedPath = [[path stringByDeletingPathExtension] stringByAppendingString:@"-artwork.m4a"];
            [[NSFileManager defaultManager] removeItemAtPath:taggedPath error:NULL];
            AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetPassthrough];
            if (!exporter || ![exporter.supportedFileTypes containsObject:AVFileTypeAppleM4A]) { self.stagedMusicPath = path; completion(YES, nil); return; }
            AVMutableMetadataItem *artworkItem = [AVMutableMetadataItem metadataItem];
            artworkItem.keySpace = AVMetadataKeySpaceCommon;
            artworkItem.key = AVMetadataCommonKeyArtwork;
            artworkItem.value = artworkData;
            NSArray *outputMetadata = @[artworkItem];
            exporter.outputURL = [NSURL fileURLWithPath:taggedPath];
            exporter.outputFileType = AVFileTypeAppleM4A;
            exporter.metadata = outputMetadata;
            [exporter exportAsynchronouslyWithCompletionHandler:^{
                BOOL exported = exporter.status == AVAssetExportSessionStatusCompleted;
                NSDictionary *taggedAttributes = exported ? [[NSFileManager defaultManager] attributesOfItemAtPath:taggedPath error:NULL] : nil;
                AVURLAsset *taggedAsset = taggedAttributes ? [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:taggedPath] options:nil] : nil;
                NSArray *embeddedArtwork = taggedAsset ? [AVMetadataItem metadataItemsFromArray:taggedAsset.commonMetadata withKey:AVMetadataCommonKeyArtwork keySpace:AVMetadataKeySpaceCommon] : nil;
                BOOL taggedPlayable = taggedAttributes && [taggedAttributes[NSFileSize] unsignedLongLongValue] > 0 && [taggedAsset tracksWithMediaType:AVMediaTypeAudio].count > 0 && embeddedArtwork.count > 0;
                NSString *selectedPath = path;
                if (taggedPlayable) { [[NSFileManager defaultManager] removeItemAtPath:path error:NULL]; selectedPath = taggedPath; }
                else [[NSFileManager defaultManager] removeItemAtPath:taggedPath error:NULL];
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.artworkEmbedded = taggedPlayable;
                    self.stagedMusicPath = selectedPath;
                    completion(YES, nil);
                });
            }];
        });
    });
}

- (void)startStoreImportURL:(NSURL *)assetURL metadata:(NSDictionary *)metadata completion:(TPImportCompletion)completion {
    NSError *error = nil;
    if (_completion) { completion(NO, [self error:15 message:@"Music is already importing a TubePod song."]); return; }
    if (![TPPrivateAPI prepareStoreServices:&error]) { completion(NO, error); return; }
    id downloadMetadata = [TPPrivateAPI newStoreMetadataWithTitle:metadata[@"title"] artist:metadata[@"artist"] durationMilliseconds:@((long long)([metadata[@"duration"] doubleValue] * 1000.0)) fileURL:assetURL error:&error];
    id download = downloadMetadata ? [TPPrivateAPI newStoreDownloadWithMetadata:downloadMetadata error:&error] : nil;
    id queue = download ? [TPPrivateAPI newStoreQueue:&error] : nil;
    if (!download || !queue || ![TPPrivateAPI setStoreQueueAutomaticFinish:queue error:&error]) { completion(NO, error ?: [self error:16 message:@"The required Apple StoreServices API is unavailable."]); return; }
    NSArray *oldDownloads = [TPPrivateAPI storeDownloads:queue error:&error];
    if (!oldDownloads) { completion(NO, error); return; }
    for (id oldDownload in oldDownloads) {
        id oldMetadata = [TPPrivateAPI storeMetadataForDownload:oldDownload error:&error];
        NSString *album = oldMetadata ? [TPPrivateAPI storeCollectionNameForMetadata:oldMetadata error:&error] : nil;
        if ([album isEqualToString:TPMusicAlbum] && ![TPPrivateAPI cancelStoreDownload:oldDownload fromQueue:queue error:&error]) { completion(NO, error ?: [self error:31 message:@"Music could not cancel an older TubePod StoreServices job."]); return; }
    }
    NSSet *preexisting = [TPMusicDatabase allTrackIDsForTitle:metadata[@"title"] album:TPMusicAlbum error:&error];
    if (!preexisting) { completion(NO, error); return; }
    self.importTitle = metadata[@"title"];
    self.preexistingTrackIDs = preexisting;
    self.download = download; self.queue = queue; self.completion = completion; self.observedInQueue = NO; self.polls = 0; self.repairPolls = 0; self.importedPersistentID = nil;
    if (![TPPrivateAPI addStoreObserver:self toQueue:queue error:&error] || ![TPPrivateAPI addStoreDownload:download toQueue:queue error:&error]) { [self finishStoreImport:NO error:error ?: [self error:17 message:@"Apple's StoreServices rejected the import request."]]; return; }
    UIApplication *application = [UIApplication sharedApplication]; __weak TPImporter *weakSelf = self;
    self.backgroundTask = [application beginBackgroundTaskWithExpirationHandler:^{ TPImporter *importer = weakSelf; if (importer) [importer finishStoreImport:NO error:[importer error:24 message:@"Music ran out of background time before the import finished."]]; }];
    [self performSelector:@selector(pollStoreImport) withObject:nil afterDelay:0.5];
}

- (void)downloadQueue:(id)queue changedWithRemovals:(id)removals { (void)queue; (void)removals; [self pollStoreImport]; }
- (void)downloadQueue:(id)queue downloadStatesChangedAtIndexes:(id)indexes { (void)queue; (void)indexes; [self pollStoreImport]; }
- (void)downloadQueue:(id)queue downloadStatusChangedAtIndex:(NSInteger)index { (void)queue; (void)index; [self pollStoreImport]; }

- (void)pollStoreImport {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pollStoreImport) object:nil];
    if (!_completion || !_queue || !_download) return;
    NSError *error = nil; NSError *failure = [TPPrivateAPI storeFailureError:_download error:&error];
    if (error) { [self finishStoreImport:NO error:error]; return; }
    if (failure) { [self finishStoreImport:NO error:[self error:18 message:failure.localizedDescription ?: @"StoreServices could not import the M4A."]]; return; }
    NSArray *downloads = [TPPrivateAPI storeDownloads:_queue error:&error];
    if (!downloads) { [self finishStoreImport:NO error:error]; return; }
    BOOL present = [downloads containsObject:_download];
    if (present) self.observedInQueue = YES;
    if (_observedInQueue && !present) { [self performSelector:@selector(repairImportedTrack) withObject:nil afterDelay:0.5]; return; }
    if (++_polls >= 360) { [self finishStoreImport:NO error:[self error:19 message:@"Music did not finish the StoreServices import."]]; return; }
    [self performSelector:@selector(pollStoreImport) withObject:nil afterDelay:0.5];
}

- (void)repairImportedTrack {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(repairImportedTrack) object:nil];
    if (!_completion || !_importTitle) return;
    NSError *error = nil;
    NSMutableSet *candidates = [[TPMusicDatabase completedTrackIDsForTitle:_importTitle album:TPMusicAlbum error:&error] mutableCopy] ?: [NSMutableSet set];
    if (error) { [self finishStoreImport:NO error:error]; return; }
    [candidates minusSet:_preexistingTrackIDs ?: [NSSet set]];
    NSNumber *persistentID = candidates.anyObject;
    if (!persistentID) { if (++_repairPolls < 30) { [self performSelector:@selector(repairImportedTrack) withObject:nil afterDelay:0.5]; return; } [self finishStoreImport:NO error:[self error:20 message:@"Music created no completed TubePod track to repair."]]; return; }
    id library = [TPPrivateAPI sharedMusicLibrary:&error];
    id track = library ? [TPPrivateAPI newMusicTrackWithPersistentID:persistentID.longLongValue library:library error:&error] : nil;
    NSString *path = track ? [TPPrivateAPI musicTrackFilePath:track error:&error] : nil;
    NSDictionary *attributes = path.length ? [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&error] : nil;
    AVURLAsset *asset = path.length ? [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil] : nil;
    AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] count] ? [[asset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0] : nil;
    const AudioStreamBasicDescription *description = NULL;
    if (audioTrack.formatDescriptions.count) description = CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)audioTrack.formatDescriptions[0]);
    long long sampleRate = description ? llround(description->mSampleRate) : 0;
    long long durationInSamples = sampleRate > 0 && CMTIME_IS_NUMERIC(asset.duration) ? CMTimeConvertScale(asset.duration, (int32_t)sampleRate, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value : 0;
    long long bitRate = audioTrack ? llround(audioTrack.estimatedDataRate / 1000.0) : 0;
    if (!track || !attributes || [attributes[NSFileSize] unsignedLongLongValue] == 0 || !audioTrack || sampleRate <= 0 || durationInSamples <= 0 || bitRate <= 0) { if (++_repairPolls < 30) { [self performSelector:@selector(repairImportedTrack) withObject:nil afterDelay:0.5]; return; } [self finishStoreImport:NO error:[self error:22 message:@"Music imported the track but could not read its playable audio format."]]; return; }
    BOOL sampleOK = [TPPrivateAPI setMusicTrack:track value:@(sampleRate) forPropertyName:@"ML3TrackPropertySampleRate" error:&error];
    BOOL durationOK = sampleOK && [TPPrivateAPI setMusicTrack:track value:@(durationInSamples) forPropertyName:@"ML3TrackPropertyDurationInSamples" error:&error];
    BOOL bitRateOK = durationOK && [TPPrivateAPI setMusicTrack:track value:@(bitRate) forPropertyName:@"ML3TrackPropertyBitRate" error:&error];
    BOOL integrityOK = bitRateOK && [TPPrivateAPI updateMusicTrackIntegrity:track error:&error];
    if (!sampleOK || !durationOK || !bitRateOK || !integrityOK) { [self finishStoreImport:NO error:error ?: [self error:23 message:@"Music imported the track but rejected its audio metadata repair."]]; return; }
    if (_artworkEmbedded) {
        NSArray *artworkItems = [AVMetadataItem metadataItemsFromArray:asset.commonMetadata withKey:AVMetadataCommonKeyArtwork keySpace:AVMetadataKeySpaceCommon];
        AVMetadataItem *artworkItem = [artworkItems count] ? artworkItems[0] : nil;
        id artworkValue = artworkItem.value;
        NSData *artworkData = [artworkValue isKindOfClass:[NSData class]] ? artworkValue : nil;
        self.artworkRegistered = artworkData.length && [TPPrivateAPI populateMusicTrackArtwork:track data:artworkData error:NULL];
    }
    if (![TPPrivateAPI notifyMusicLibrary:library error:&error]) { [self finishStoreImport:NO error:error]; return; }
    if (_artworkRegistered) [TPPrivateAPI reloadMediaPlayerLibrary:NULL];
    self.importedPersistentID = persistentID;
    self.playableResultVerified = YES;
    self.cleanupPolls = 0; self.cleanupQuietPolls = 0;
    [self performSelector:@selector(pollPostImportCleanup) withObject:nil afterDelay:0.5];
}

- (void)pollPostImportCleanup {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pollPostImportCleanup) object:nil];
    if (!_completion || !_importTitle.length) return;
    NSError *error = nil;
    NSMutableSet *emptyTrackIDs = [[TPMusicDatabase emptyPlaceholderTrackIDsForTitle:_importTitle album:TPMusicAlbum error:&error] mutableCopy] ?: [NSMutableSet set];
    if (error) { [self finishStoreImport:NO error:error]; return; }
    [emptyTrackIDs minusSet:_preexistingTrackIDs ?: [NSSet set]];
    if (emptyTrackIDs.count) { if (![self deleteTrackIDs:emptyTrackIDs notify:YES error:&error]) { [self finishStoreImport:NO error:error]; return; } self.cleanupQuietPolls = 0; } else self.cleanupQuietPolls++;
    self.cleanupPolls++;
    if ((_cleanupPolls >= 8 && _cleanupQuietPolls >= 2) || _cleanupPolls >= 16) { [self finishStoreImport:YES error:nil]; return; }
    [self performSelector:@selector(pollPostImportCleanup) withObject:nil afterDelay:0.5];
}

- (void)finishStoreImport:(BOOL)success error:(NSError *)error {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pollStoreImport) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(repairImportedTrack) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(pollPostImportCleanup) object:nil];
    if (!success && _queue && _download) [TPPrivateAPI cancelStoreDownload:_download fromQueue:_queue error:NULL];
    if (_queue) [TPPrivateAPI removeStoreObserver:self fromQueue:_queue error:NULL];
    if (!success && _importTitle.length) {
        NSError *cleanupError = nil;
        NSSet *emptyTrackIDs = [TPMusicDatabase emptyPlaceholderTrackIDsForTitle:_importTitle album:TPMusicAlbum error:&cleanupError];
        NSMutableSet *newIDs = [emptyTrackIDs mutableCopy]; [newIDs minusSet:_preexistingTrackIDs ?: [NSSet set]];
        if (newIDs && ![self deleteTrackIDs:newIDs notify:YES error:&cleanupError] && !error) error = cleanupError;
    }
    if (_backgroundTask != UIBackgroundTaskInvalid) { [[UIApplication sharedApplication] endBackgroundTask:_backgroundTask]; self.backgroundTask = UIBackgroundTaskInvalid; }
    if (success && _stagedMusicPath.length) [[NSFileManager defaultManager] removeItemAtPath:_stagedMusicPath error:NULL];
    self.stagedMusicPath = nil;
    TPImportCompletion block = _completion; self.completion = nil; self.queue = nil; self.download = nil; self.importTitle = nil; self.preexistingTrackIDs = nil;
    if (block) block(success, error);
}
@end
