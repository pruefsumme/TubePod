#import "TPDownloader.h"
#import "TPBridge.h"
#import "TPImporter.h"
#import <AVFoundation/AVFoundation.h>

static NSString * const TPErrorDomain = @"com.pruefsumme.tubepod";

@interface TPDownloadSession ()
@property(nonatomic, copy, readwrite) NSString *sessionID;
@end

@implementation TPDownloadSession
@end

@implementation TPDownloadRequest
@end

@interface TPDownloader ()
@property(nonatomic, retain) TPDownloadRequest *request;
@property(nonatomic, retain) TPDownloadSession *session;
@property(nonatomic, retain) NSURLConnection *connection;
@property(nonatomic, retain) NSFileHandle *handle;
@property(nonatomic, copy) NSString *partPath;
@property(nonatomic, copy) NSString *retainedPath;
@property(nonatomic, copy) TPDownloadProgressBlock progressBlock;
@property(nonatomic, copy) TPDownloadCompletionBlock completionBlock;
@property(nonatomic) unsigned long long offset;
@property(nonatomic) long long expected;
@property(nonatomic, readwrite, getter=isBusy) BOOL busy;
@property(nonatomic) BOOL terminal;
@end

@implementation TPDownloader
+ (instancetype)sharedDownloader { static TPDownloader *x; static dispatch_once_t once; dispatch_once(&once, ^{ x = [self new]; }); return x; }

- (NSString *)baseDirectory {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TubePod"];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error]) return nil;
    return path;
}

- (NSError *)error:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:TPErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown download error."}];
}

- (BOOL)isCurrentConnection:(NSURLConnection *)connection {
    return _busy && !_terminal && connection && connection == _connection && _session.sessionID.length;
}

- (void)writeState:(NSString *)status {
    if (!TPVideoIDIsValid(_request.videoID)) return;
    NSString *base = [self baseDirectory];
    if (!base.length) return;
    NSString *path = [base stringByAppendingPathComponent:@"state.plist"];
    NSMutableDictionary *state = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    state[_request.videoID] = @{ @"status": status ?: @"partial", @"bytes": @(_offset), @"date": [NSDate date], @"sourceVideoID": _request.sourceVideoID ?: _request.videoID };
    [state writeToFile:path atomically:YES];
}

- (BOOL)preparePartFile:(NSError **)error {
    if (![[NSFileManager defaultManager] fileExistsAtPath:_partPath] && ![[NSFileManager defaultManager] createFileAtPath:_partPath contents:nil attributes:nil]) {
        if (error) *error = [self error:10 message:@"TubePod could not create the partial download file. The source can be retried."];
        return NO;
    }
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:_partPath error:error];
    if (!attributes) {
        if (error && !*error) *error = [self error:11 message:@"TubePod could not inspect the partial download file."];
        return NO;
    }
    self.offset = [attributes[NSFileSize] unsignedLongLongValue];
    @try {
        self.handle = [NSFileHandle fileHandleForWritingAtPath:_partPath];
        if (!_handle) {
            if (error) *error = [self error:12 message:@"TubePod could not open the partial download file for writing."];
            return NO;
        }
        [_handle seekToEndOfFile];
    } @catch (NSException *exception) {
        if (error) *error = [self error:13 message:[NSString stringWithFormat:@"TubePod could not prepare the partial file: %@.", exception.reason ?: @"file handle failure"]];
        self.handle = nil;
        return NO;
    }
    return YES;
}

- (TPDownloadSession *)startRequest:(TPDownloadRequest *)request progress:(TPDownloadProgressBlock)progress completion:(TPDownloadCompletionBlock)completion error:(NSError **)error {
    if (_busy) { if (error) *error = [self error:1 message:@"Another download is already running."]; return nil; }
    if (!request || !TPVideoIDIsValid(request.videoID) || !request.URL || ![request.URL.scheme.lowercaseString isEqualToString:@"https"]) {
        if (error) *error = [self error:2 message:@"The video ID or direct HTTPS stream is invalid."];
        return nil;
    }
    NSString *baseDirectory = [self baseDirectory];
    if (!baseDirectory.length) { if (error) *error = [self error:8 message:@"YouTube could not create TubePod's download folder."]; return nil; }
    self.request = request;
    self.session = [TPDownloadSession new];
    self.session.sessionID = [[NSProcessInfo processInfo] globallyUniqueString];
    TPDownloadSession *startedSession = self.session;
    self.progressBlock = progress;
    self.completionBlock = completion;
    self.terminal = NO;
    self.expected = -1;

    NSString *existingM4A = [baseDirectory stringByAppendingPathComponent:[request.videoID stringByAppendingString:@".m4a"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:existingM4A]) {
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:existingM4A error:error];
        if (!attributes) { self.request = nil; self.session = nil; self.progressBlock = nil; self.completionBlock = nil; return nil; }
        if ([attributes[NSFileSize] unsignedLongLongValue] == 0) { if (error) *error = [self error:14 message:@"TubePod found an empty converted M4A and kept it for inspection."]; self.request = nil; self.session = nil; self.progressBlock = nil; self.completionBlock = nil; return nil; }
        self.retainedPath = existingM4A;
        self.busy = YES;
        [self writeState:@"converted"];
        [self importPath:existingM4A];
        return startedSession;
    }
    self.partPath = [baseDirectory stringByAppendingPathComponent:[request.videoID stringByAppendingString:@".part"]];
    NSError *spaceError = nil;
    NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:baseDirectory error:&spaceError];
    if (!fs) { if (error) *error = [self error:9 message:@"TubePod could not read the available storage."]; self.request = nil; self.session = nil; self.progressBlock = nil; self.completionBlock = nil; return nil; }
    if ([fs[NSFileSystemFreeSize] unsignedLongLongValue] < 20ULL * 1024ULL * 1024ULL) { if (error) *error = [self error:3 message:@"Less than 20 MB of storage is available."]; self.request = nil; self.session = nil; self.progressBlock = nil; self.completionBlock = nil; return nil; }
    if (![self preparePartFile:error]) { self.request = nil; self.session = nil; self.progressBlock = nil; self.completionBlock = nil; return nil; }
    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:request.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    [urlRequest setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    if (_offset) [urlRequest setValue:[NSString stringWithFormat:@"bytes=%llu-", _offset] forHTTPHeaderField:@"Range"];
    self.busy = YES;
    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:urlRequest delegate:self startImmediately:NO];
    self.connection = connection;
    if (!_connection) {
        @try { [_handle closeFile]; } @catch (__unused NSException *exception) {}
        self.handle = nil; self.busy = NO; self.request = nil; self.session = nil; self.progressBlock = nil; self.completionBlock = nil;
        if (error) *error = [self error:15 message:@"TubePod could not start the HTTPS transfer. The partial file was kept."];
        return nil;
    }
    [connection start];
    [self writeState:@"partial"];
    return startedSession;
}

- (void)cancel { [self cancelSession:_session]; }
- (void)cancelSession:(TPDownloadSession *)session {
    if (!_busy || !_session || session != _session || _terminal) return;
    [_connection cancel];
    [self finishWithError:[self error:NSURLErrorCancelled message:@"Download cancelled. The partial file was kept."]];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if (![self isCurrentConnection:connection]) return;
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSInteger status = [http isKindOfClass:[NSHTTPURLResponse class]] ? http.statusCode : 200;
    if (status == 403) { [connection cancel]; [self finishWithError:[self error:403 message:@"The stream URL expired. Reopen the video and retry."]]; return; }
    if (status != 200 && status != 206) { [connection cancel]; [self finishWithError:[self error:status message:[NSString stringWithFormat:@"Server returned HTTP %ld.", (long)status]]]; return; }
    @try {
        if (_offset && status == 206) {
            NSString *range = http.allHeaderFields[@"Content-Range"];
            if (![range hasPrefix:[NSString stringWithFormat:@"bytes %llu-", _offset]]) { [connection cancel]; [self finishWithError:[self error:4 message:@"The server returned an invalid resume range."]]; return; }
        } else if (_offset && status == 200) {
            [_handle truncateFileAtOffset:0]; [_handle seekToFileOffset:0]; self.offset = 0;
        }
    } @catch (NSException *exception) {
        [connection cancel]; [self finishWithError:[self error:16 message:[NSString stringWithFormat:@"TubePod could not reset its partial file: %@.", exception.reason ?: @"file error"]]]; return;
    }
    NSString *mime = response.MIMEType.lowercaseString;
    if (mime.length && ![mime hasPrefix:@"audio/"] && ![mime isEqualToString:@"video/mp4"] && ![mime isEqualToString:@"application/octet-stream"]) { [connection cancel]; [self finishWithError:[self error:5 message:@"The response is not supported audio or MP4 media."]]; return; }
    self.expected = response.expectedContentLength > 0 ? (long long)_offset + response.expectedContentLength : -1;
    NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:[self baseDirectory] error:NULL];
    unsigned long long free = [fs[NSFileSystemFreeSize] unsignedLongLongValue];
    if (_expected > 0 && free < (unsigned long long)(_expected - (long long)_offset) + 5ULL * 1024ULL * 1024ULL) { [connection cancel]; [self finishWithError:[self error:3 message:[NSString stringWithFormat:@"Insufficient storage: %llu bytes required, %llu available.", (unsigned long long)(_expected - (long long)_offset), free]]]; }
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response {
    if (![self isCurrentConnection:connection]) return nil;
    if (response && ![request.URL.scheme.lowercaseString isEqualToString:@"https"]) return nil;
    return request;
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (![self isCurrentConnection:connection] || !data.length) return;
    @try {
        if (!_handle) { [self finishWithError:[self error:17 message:@"TubePod lost the partial file while downloading."]]; return; }
        [_handle writeData:data];
        self.offset += data.length;
    } @catch (NSException *exception) {
        [connection cancel]; [self finishWithError:[self error:18 message:[NSString stringWithFormat:@"TubePod could not write the download: %@. The partial file was kept.", exception.reason ?: @"disk error"]]]; return;
    }
    double fraction = _expected > 0 ? MIN(1.0, (double)_offset / (double)_expected) : -1;
    TPDownloadProgressBlock block = _progressBlock; TPDownloadSession *session = _session;
    if (block) block(session, fraction, nil);
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error { if ([self isCurrentConnection:connection]) [self finishWithError:error]; }

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    if (![self isCurrentConnection:connection]) return;
    @try { [_handle synchronizeFile]; [_handle closeFile]; self.handle = nil; } @catch (NSException *exception) { [self finishWithError:[self error:19 message:[NSString stringWithFormat:@"TubePod could not close the completed download: %@.", exception.reason ?: @"file error"]]]; return; }
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:_partPath error:NULL];
    unsigned long long actual = [attributes[NSFileSize] unsignedLongLongValue];
    if (actual == 0) { [self finishWithError:[self error:20 message:@"The stream finished with an empty media file. The partial file was kept."]]; return; }
    if (_expected > 0 && actual != (unsigned long long)_expected) { [self finishWithError:[self error:21 message:[NSString stringWithFormat:@"The stream finished at %llu bytes, but %lld bytes were expected. The partial file was kept.", actual, _expected]]]; return; }
    [self prepareDownloadedFile];
}

- (void)prepareDownloadedFile {
    if (!_request || _terminal) return;
    NSString *base = [self baseDirectory];
    NSString *m4aPath = [base stringByAppendingPathComponent:[_request.videoID stringByAppendingString:@".m4a"]];
    self.retainedPath = _partPath;
    if (_request.audioOnly) {
        NSError *moveError = nil;
        if (![[NSFileManager defaultManager] moveItemAtPath:_partPath toPath:m4aPath error:&moveError]) { [self finishWithError:moveError ?: [self error:22 message:@"TubePod could not retain the downloaded audio file."]]; return; }
        self.retainedPath = m4aPath;
        [self importPath:m4aPath]; return;
    }
    NSString *mp4Path = [base stringByAppendingPathComponent:[_request.videoID stringByAppendingString:@".mp4"]];
    // A failed conversion from an older attempt may have left this path behind.
    // The new .part is complete and validated, so it safely replaces that copy.
    [[NSFileManager defaultManager] removeItemAtPath:mp4Path error:NULL];
    NSError *moveError = nil;
    if (![[NSFileManager defaultManager] moveItemAtPath:_partPath toPath:mp4Path error:&moveError]) { [self finishWithError:moveError ?: [self error:22 message:@"TubePod could not retain the downloaded MP4."]]; return; }
    self.retainedPath = mp4Path;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:mp4Path] options:nil];
    if (![asset tracksWithMediaType:AVMediaTypeAudio].count) { [self finishWithError:[self error:6 message:@"The downloaded MP4 has no audio track. The MP4 was kept."]]; return; }
    [[NSFileManager defaultManager] removeItemAtPath:m4aPath error:NULL];
    AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    exporter.outputURL = [NSURL fileURLWithPath:m4aPath]; exporter.outputFileType = AVFileTypeAppleM4A;
    __weak TPDownloader *weakSelf = self;
    [exporter exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            TPDownloader *downloader = weakSelf;
            if (!downloader || downloader.terminal) return;
            if (exporter.status == AVAssetExportSessionStatusCompleted) {
                [[NSFileManager defaultManager] removeItemAtPath:mp4Path error:NULL];
                downloader.retainedPath = m4aPath;
                [downloader importPath:m4aPath];
            } else {
                [downloader finishWithError:exporter.error ?: [downloader error:7 message:@"Audio conversion failed; the MP4 was kept."]];
            }
        });
    }];
}

- (void)importPath:(NSString *)path {
    if (_terminal || !path.length) return;
    self.retainedPath = path;
    TPDownloadProgressBlock progress = _progressBlock; TPDownloadSession *session = _session;
    if (progress) {
        __weak TPDownloader *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            TPDownloader *downloader = weakSelf;
            if (downloader && !downloader.terminal && downloader.session == session && downloader.progressBlock) downloader.progressBlock(session, 1.0, @"importing");
        });
    }
    NSDictionary *metadata = @{ @"title": _request.title ?: @"Untitled", @"artist": _request.artist ?: @"Unknown Artist", @"album": @"TubePod", @"duration": @(_request.duration), TPBridgeVideoIDKey: _request.videoID, TPBridgeSourceVideoIDKey: _request.sourceVideoID ?: _request.videoID, TPBridgeAllowDuplicateKey: @(_request.allowDuplicate) };
    __weak TPDownloader *weakSelf = self;
    [[TPImporter sharedImporter] importM4A:[NSURL fileURLWithPath:path] metadata:metadata completion:^(BOOL success, NSError *error) {
        TPDownloader *downloader = weakSelf;
        if (!downloader || downloader.terminal) return;
        if (success) {
            NSError *removeError = nil;
            if (![[NSFileManager defaultManager] removeItemAtPath:path error:&removeError]) { [downloader finishWithError:[downloader error:23 message:[NSString stringWithFormat:@"Music confirmed the import, but TubePod could not remove its retained copy: %@.", removeError.localizedDescription ?: @"file cleanup failed"]]]; return; }
            [downloader writeState:@"imported"];
        }
        [downloader finishWithError:error];
    }];
}

- (void)finishWithError:(NSError *)error {
    if (_terminal) return;
    self.terminal = YES;
    TPDownloadSession *session = _session;
    NSString *keptPath = _retainedPath ?: _partPath ?: @"";
    @try { [_handle closeFile]; } @catch (__unused NSException *exception) {}
    self.handle = nil; self.connection = nil; self.busy = NO;
    if (error) [self writeState:@"partial"];
    TPDownloadCompletionBlock block = _completionBlock;
    self.progressBlock = nil; self.completionBlock = nil;
    if (block) block(session, error, error ? keptPath : @"");
    self.request = nil; self.session = nil; self.retainedPath = nil; self.partPath = nil;
}
@end
