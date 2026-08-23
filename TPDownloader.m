#import "TPDownloader.h"
#import "TPImporter.h"
#import <AVFoundation/AVFoundation.h>

NSString * const TPDownloadProgressNotification = @"TPDownloadProgressNotification";
NSString * const TPDownloadFinishedNotification = @"TPDownloadFinishedNotification";
static NSString * const TPErrorDomain = @"com.pruefsumme.tubepod";

@implementation TPDownloadRequest
@end

@interface TPDownloader ()
@property(nonatomic, retain) TPDownloadRequest *request;
@property(nonatomic, retain) NSURLConnection *connection;
@property(nonatomic, retain) NSFileHandle *handle;
@property(nonatomic, copy) NSString *partPath;
@property(nonatomic, copy) NSString *retainedPath;
@property(nonatomic) unsigned long long offset;
@property(nonatomic) long long expected;
@property(nonatomic, readwrite, getter=isBusy) BOOL busy;
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
    return [NSError errorWithDomain:TPErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

- (void)writeState:(NSString *)status {
    if (!_request.videoID.length) return;
    NSString *path = [[self baseDirectory] stringByAppendingPathComponent:@"state.plist"];
    NSMutableDictionary *state = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    state[_request.videoID] = @{ @"status": status ?: @"partial", @"bytes": @(_offset), @"date": [NSDate date] };
    [state writeToFile:path atomically:YES];
}

- (BOOL)startRequest:(TPDownloadRequest *)request error:(NSError **)error {
    if (_busy) { if (error) *error = [self error:1 message:@"Another download is already running."]; return NO; }
    if (!request.videoID.length || !request.URL || ![request.URL.scheme.lowercaseString isEqualToString:@"https"]) {
        if (error) *error = [self error:2 message:@"The video did not expose a direct HTTPS stream."]; return NO;
    }
    NSString *baseDirectory = [self baseDirectory];
    if (!baseDirectory.length) {
        if (error) *error = [self error:8 message:@"YouTube could not create TubePod's download folder."];
        return NO;
    }
    self.request = request;
    NSString *existingM4A = [baseDirectory stringByAppendingPathComponent:[request.videoID stringByAppendingString:@".m4a"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:existingM4A]) {
        self.retainedPath = existingM4A;
        self.busy = YES;
        [self writeState:@"converted"];
        [self importPath:existingM4A];
        return YES;
    }
    self.partPath = [baseDirectory stringByAppendingPathComponent:[request.videoID stringByAppendingString:@".part"]];
    NSError *spaceError = nil;
    NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:baseDirectory error:&spaceError];
    if (!fs) {
        if (error) *error = [self error:9 message:@"TubePod could not read the available storage."];
        self.request = nil;
        return NO;
    }
    if ([fs[NSFileSystemFreeSize] unsignedLongLongValue] < 20ULL * 1024ULL * 1024ULL) {
        if (error) *error = [self error:3 message:@"Less than 20 MB of storage is available."]; return NO;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:_partPath]) [[NSData data] writeToFile:_partPath atomically:YES];
    self.offset = [[[[NSFileManager defaultManager] attributesOfItemAtPath:_partPath error:NULL] objectForKey:NSFileSize] unsignedLongLongValue];
    self.handle = [NSFileHandle fileHandleForWritingAtPath:_partPath];
    [_handle seekToEndOfFile];
    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:request.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    [urlRequest setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    if (_offset) [urlRequest setValue:[NSString stringWithFormat:@"bytes=%llu-", _offset] forHTTPHeaderField:@"Range"];
    self.busy = YES;
    self.connection = [[NSURLConnection alloc] initWithRequest:urlRequest delegate:self startImmediately:YES];
    [self writeState:@"partial"];
    return YES;
}

- (void)cancel { [_connection cancel]; [self finishWithError:[self error:NSURLErrorCancelled message:@"Download cancelled. The partial file was kept."]]; }

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSInteger status = http.statusCode;
    if (status == 403) { [connection cancel]; [self finishWithError:[self error:403 message:@"The stream URL expired. Reopen the video and retry."]]; return; }
    if (status != 200 && status != 206) { [connection cancel]; [self finishWithError:[self error:status message:[NSString stringWithFormat:@"Server returned HTTP %ld.", (long)status]]]; return; }
    if (_offset && status == 206) {
        NSString *range = [http.allHeaderFields objectForKey:@"Content-Range"];
        if (![range hasPrefix:[NSString stringWithFormat:@"bytes %llu-", _offset]]) { [connection cancel]; [self finishWithError:[self error:4 message:@"The server returned an invalid resume range."]]; return; }
    } else if (_offset && status == 200) {
        [_handle truncateFileAtOffset:0]; [_handle seekToFileOffset:0]; self.offset = 0;
    }
    NSString *mime = response.MIMEType.lowercaseString;
    if (mime.length && ![mime hasPrefix:@"audio/"] && ![mime isEqualToString:@"video/mp4"] && ![mime isEqualToString:@"application/octet-stream"]) {
        [connection cancel]; [self finishWithError:[self error:5 message:@"The response is not supported audio or MP4 media."]]; return;
    }
    self.expected = response.expectedContentLength > 0 ? (long long)_offset + response.expectedContentLength : -1;
    unsigned long long free = [[[[NSFileManager defaultManager] attributesOfFileSystemForPath:[self baseDirectory] error:NULL] objectForKey:NSFileSystemFreeSize] unsignedLongLongValue];
    if (_expected > 0 && free < (unsigned long long)(_expected - (long long)_offset) + 5ULL * 1024ULL * 1024ULL) { [connection cancel]; [self finishWithError:[self error:3 message:[NSString stringWithFormat:@"Insufficient storage: %llu bytes required, %llu available.", (unsigned long long)(_expected - (long long)_offset), free]]]; }
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response { (void)connection; if (response && ![request.URL.scheme.lowercaseString isEqualToString:@"https"]) return nil; return request; }

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    (void)connection; [_handle writeData:data]; self.offset += data.length;
    double fraction = _expected > 0 ? MIN(1.0, (double)_offset / (double)_expected) : -1;
    [[NSNotificationCenter defaultCenter] postNotificationName:TPDownloadProgressNotification object:self userInfo:@{@"fraction": @(fraction), @"bytes": @(_offset)}];
}
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error { (void)connection; [self finishWithError:error]; }
- (void)connectionDidFinishLoading:(NSURLConnection *)connection { (void)connection; [_handle synchronizeFile]; [_handle closeFile]; self.handle = nil; [self prepareDownloadedFile]; }

- (void)prepareDownloadedFile {
    NSString *m4aPath = [[self baseDirectory] stringByAppendingPathComponent:[_request.videoID stringByAppendingString:@".m4a"]];
    [[NSFileManager defaultManager] removeItemAtPath:m4aPath error:NULL];
    if (_request.audioOnly) {
        NSError *moveError = nil;
        if (![[NSFileManager defaultManager] moveItemAtPath:_partPath toPath:m4aPath error:&moveError]) { [self finishWithError:moveError]; return; }
        [self importPath:m4aPath]; return;
    }
    // iOS 6 AVFoundation relies on the filename extension when identifying a
    // local container. A complete MP4 left with the resume-only .part suffix
    // appears to have no tracks even though its moov atom contains AAC audio.
    NSString *mp4Path = [[self baseDirectory] stringByAppendingPathComponent:[_request.videoID stringByAppendingString:@".mp4"]];
    [[NSFileManager defaultManager] removeItemAtPath:mp4Path error:NULL];
    NSError *moveError = nil;
    if (![[NSFileManager defaultManager] moveItemAtPath:_partPath toPath:mp4Path error:&moveError]) { [self finishWithError:moveError]; return; }
    self.retainedPath = mp4Path;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:mp4Path] options:nil];
    if (![asset tracksWithMediaType:AVMediaTypeAudio].count) { [self finishWithError:[self error:6 message:@"The downloaded MP4 has no audio track."]]; return; }
    AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    exporter.outputURL = [NSURL fileURLWithPath:m4aPath]; exporter.outputFileType = AVFileTypeAppleM4A;
    [exporter exportAsynchronouslyWithCompletionHandler:^{ dispatch_async(dispatch_get_main_queue(), ^{
        if (exporter.status == AVAssetExportSessionStatusCompleted) { [[NSFileManager defaultManager] removeItemAtPath:mp4Path error:NULL]; self.retainedPath = nil; [self importPath:m4aPath]; }
        else [self finishWithError:exporter.error ?: [self error:7 message:@"Audio conversion failed; the MP4 was kept."]];
    }); }];
}

- (void)importPath:(NSString *)path {
    self.retainedPath = path;
    [[NSNotificationCenter defaultCenter] postNotificationName:TPDownloadProgressNotification object:self userInfo:@{ @"fraction": @1, @"phase": @"importing" }];
    NSDictionary *metadata = @{ @"title": _request.title ?: @"Untitled", @"artist": _request.artist ?: @"Unknown Artist", @"album": @"TubePod", @"duration": @(_request.duration), @"videoID": _request.videoID };
    [[TPImporter sharedImporter] importM4A:[NSURL fileURLWithPath:path] metadata:metadata completion:^(BOOL success, NSError *error) {
        if (success) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
            [self writeState:@"imported"];
        }
        [self finishWithError:error];
    }];
}

- (void)finishWithError:(NSError *)error {
    [_handle closeFile]; self.handle = nil; self.connection = nil; self.busy = NO;
    if (error) [self writeState:@"partial"];
    NSString *keptPath = _retainedPath ?: _partPath ?: @"";
    [[NSNotificationCenter defaultCenter] postNotificationName:TPDownloadFinishedNotification object:self userInfo:error ? @{@"error": error, @"path": keptPath} : @{@"success": @YES}];
    self.request = nil; self.retainedPath = nil;
}
@end
