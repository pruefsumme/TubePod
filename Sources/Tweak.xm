#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "TPDownloader.h"
#import "TPImporter.h"
#import "TPBridge.h"

static char TPProxyKey;
static void (*TPOriginalShow)(UIActionSheet *, SEL, UIView *);
static NSMutableSet *TPActiveProxies;

static id TPSafeValue(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static id TPFirstValue(id object, NSArray *keys) {
    for (NSString *key in keys) { id value = TPSafeValue(object, key); if (value && value != [NSNull null]) return value; }
    return nil;
}

static NSString *TPBaseDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/TubePod"];
}

static NSDictionary *TPVideoInfo(id source) {
    id video = TPFirstValue(source, @[@"video", @"currentVideo", @"activeVideo", @"media", @"playerVideo"]);
    if (!video) video = source;
    NSString *videoID = TPFirstValue(video, @[@"ID", @"videoID", @"videoId", @"identifier"]);
    NSString *title = TPFirstValue(video, @[@"title", @"videoTitle"]);
    NSString *artist = TPFirstValue(video, @[@"uploaderDisplayName", @"author", @"uploader", @"channelTitle"]);
    NSNumber *duration = TPFirstValue(video, @[@"duration", @"lengthSeconds"]);
    id streamRoot = TPFirstValue(video, @[@"streamingData", @"streams", @"streamInfo", @"playbackData"]);
    NSArray *streams = nil;
    if ([streamRoot isKindOfClass:[NSArray class]]) streams = streamRoot;
    else streams = TPFirstValue(streamRoot, @[@"adaptiveFormats", @"formats", @"streams"]);
    if (![streams isKindOfClass:[NSArray class]]) streams = TPFirstValue(video, @[@"adaptiveFormats", @"formats", @"videoStreams"]);
    NSDictionary *bestAudio = nil, *bestMedia = nil;
    for (id stream in streams) {
        NSURL *URL = TPFirstValue(stream, @[@"URL", @"url"]); if ([URL isKindOfClass:[NSString class]]) URL = [NSURL URLWithString:(NSString *)URL];
        NSString *mime = TPFirstValue(stream, @[@"mimeType", @"type", @"MIMEType"]);
        NSNumber *bitrate = TPFirstValue(stream, @[@"bitrate", @"averageBitrate"]);
        NSNumber *format = TPFirstValue(stream, @[@"format", @"itag"]);
        if (![URL isKindOfClass:[NSURL class]] || ![URL.scheme.lowercaseString isEqualToString:@"https"]) continue;
        // YouTube 1.4.0 exposes YTStream objects with URL + numeric format,
        // while newer models expose MIME type + bitrate. Support both shapes.
        NSNumber *score = bitrate ?: format ?: @0;
        NSDictionary *candidate = @{ @"url": URL, @"score": score };
        if ([mime.lowercaseString hasPrefix:@"audio/mp4"] && (!bestAudio || [score longLongValue] > [bestAudio[@"score"] longLongValue])) bestAudio = candidate;
        if ((!mime.length || [mime.lowercaseString hasPrefix:@"video/mp4"] || [mime.lowercaseString hasPrefix:@"video/3gpp"]) &&
            (!bestMedia || [score longLongValue] > [bestMedia[@"score"] longLongValue])) bestMedia = candidate;
    }
    NSDictionary *selected = bestAudio ?: bestMedia;
    if (![videoID isKindOfClass:[NSString class]]) videoID = [videoID description];
    if (![title isKindOfClass:[NSString class]]) title = [title description];
    if (![artist isKindOfClass:[NSString class]]) artist = [artist description];
    if (!TPVideoIDIsValid(videoID) || !selected) return nil;
    return @{ @"videoID": videoID, @"sourceVideoID": videoID, @"title": title ?: @"Untitled", @"artist": artist ?: @"Unknown Artist", @"duration": duration ?: @0, @"url": selected[@"url"], @"audioOnly": @(bestAudio != nil) };
}

@interface TPActionProxy : NSObject <UIActionSheetDelegate, UIAlertViewDelegate>
@property(nonatomic, weak) id originalDelegate;
@property(nonatomic, strong) NSDictionary *info;
@property(nonatomic) NSInteger saveIndex;
@property(nonatomic, strong) UIAlertView *progressAlert;
@property(nonatomic, strong) TPDownloadSession *downloadSession;
@property(nonatomic) BOOL allowDuplicate;
@end

@implementation TPActionProxy
- (instancetype)init { return [super init]; }
- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
    if (index == _saveIndex) { [self beginSave]; return; }
    if ([_originalDelegate respondsToSelector:_cmd]) [_originalDelegate actionSheet:sheet clickedButtonAtIndex:index];
}
- (void)actionSheet:(UIActionSheet *)sheet didDismissWithButtonIndex:(NSInteger)index {
    // YTVideoActionsController performs its menu command on dismissal. Do not
    // let it interpret TubePod's appended index as one of YouTube's commands.
    if (index == _saveIndex) return;
    if ([_originalDelegate respondsToSelector:_cmd]) [_originalDelegate actionSheet:sheet didDismissWithButtonIndex:index];
}
- (void)beginSave {
    self.allowDuplicate = NO;
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:[TPBaseDirectory() stringByAppendingPathComponent:@"state.plist"]];
    if ([state[_info[@"videoID"]][@"status"] isEqualToString:@"imported"]) { UIAlertView *again = [[UIAlertView alloc] initWithTitle:@"Already Saved" message:@"This video was previously imported." delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Download Again", nil]; again.tag = 100; [again show]; return; }
    [self startDownload];
}
- (void)startDownload {
    TPDownloadRequest *request = [TPDownloadRequest new]; request.videoID = _info[@"videoID"]; request.sourceVideoID = _info[@"sourceVideoID"] ?: _info[@"videoID"]; request.title = _info[@"title"]; request.artist = _info[@"artist"]; request.duration = [_info[@"duration"] doubleValue]; request.URL = _info[@"url"]; request.audioOnly = [_info[@"audioOnly"] boolValue]; request.allowDuplicate = self.allowDuplicate; self.allowDuplicate = NO;
    [TPActiveProxies addObject:self];
    self.progressAlert = [[UIAlertView alloc] initWithTitle:@"Saving Audio" message:@"0%\nKeep YouTube open." delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:nil]; [_progressAlert show];
    NSError *error = nil;
    __weak TPActionProxy *weakSelf = self;
    self.downloadSession = [[TPDownloader sharedDownloader] startRequest:request progress:^(TPDownloadSession *session, double fraction, NSString *phase) {
        TPActionProxy *proxy = weakSelf;
        if (!proxy || proxy.downloadSession != session) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [proxy downloadProgressForSession:session fraction:fraction phase:phase]; });
    } completion:^(TPDownloadSession *session, NSError *completionError, NSString *path) {
        TPActionProxy *proxy = weakSelf;
        if (!proxy || proxy.downloadSession != session) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [proxy downloadFinishedForSession:session error:completionError path:path]; });
    } error:&error];
    if (!self.downloadSession) {
        [_progressAlert dismissWithClickedButtonIndex:-1 animated:NO]; self.progressAlert = nil; [TPActiveProxies removeObject:self];
        [[[UIAlertView alloc] initWithTitle:@"TubePod" message:error.localizedDescription delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
    }
}
- (void)alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)index { if (alert.tag == 100) { if (index == 1) { self.allowDuplicate = YES; [self startDownload]; } return; } if (alert == _progressAlert && self.downloadSession) [[TPDownloader sharedDownloader] cancelSession:self.downloadSession]; }
- (void)downloadProgressForSession:(TPDownloadSession *)session fraction:(double)fraction phase:(NSString *)phase {
    if (self.downloadSession != session) return;
    if ([phase isEqualToString:@"artwork"]) {
        _progressAlert.message = @"Preparing cover…\nKeep YouTube open.";
        return;
    }
    if ([phase isEqualToString:@"importing"]) {
        [_progressAlert dismissWithClickedButtonIndex:-1 animated:NO];
        self.progressAlert = [[UIAlertView alloc] initWithTitle:@"Adding to Music" message:@"Download complete.\nStay in Music until TubePod says Saved." delegate:self cancelButtonTitle:nil otherButtonTitles:nil];
        [_progressAlert show];
        return;
    }
    _progressAlert.message = fraction >= 0 ? [NSString stringWithFormat:@"%.0f%%\nKeep YouTube open.", fraction * 100.0] : @"Downloading…\nKeep YouTube open.";
}
- (void)downloadFinishedForSession:(TPDownloadSession *)session error:(NSError *)error path:(NSString *)path { if (self.downloadSession != session) return; [_progressAlert dismissWithClickedButtonIndex:-1 animated:YES]; self.progressAlert = nil; NSString *message = error ? [NSString stringWithFormat:@"%@\nKept at: %@", error.localizedDescription, path] : @"The song was added to Music."; [[[UIAlertView alloc] initWithTitle:error ? @"TubePod Error" : @"Saved" message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show]; self.downloadSession = nil; [TPActiveProxies removeObject:self]; }
- (BOOL)respondsToSelector:(SEL)sel { return [super respondsToSelector:sel] || [_originalDelegate respondsToSelector:sel]; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [super methodSignatureForSelector:sel] ?: [_originalDelegate methodSignatureForSelector:sel]; }
- (void)forwardInvocation:(NSInvocation *)invocation { if ([_originalDelegate respondsToSelector:invocation.selector]) [invocation invokeWithTarget:_originalDelegate]; else [super forwardInvocation:invocation]; }
@end

static void TPShowActionSheet(UIActionSheet *sheet, SEL cmd, UIView *view) {
    NSString *delegateName = NSStringFromClass([sheet.delegate class]);
    BOOL videoController = [delegateName rangeOfString:@"Video" options:NSCaseInsensitiveSearch].location != NSNotFound || [delegateName rangeOfString:@"Watch" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (videoController && !objc_getAssociatedObject(sheet, &TPProxyKey)) {
        NSDictionary *info = TPVideoInfo(sheet.delegate);
        if (info) { TPActionProxy *proxy = [TPActionProxy new]; proxy.originalDelegate = sheet.delegate; proxy.info = info; proxy.saveIndex = [sheet addButtonWithTitle:@"Save Audio"]; sheet.delegate = proxy; objc_setAssociatedObject(sheet, &TPProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    }
    TPOriginalShow(sheet, cmd, view);
}

%ctor {
    @autoreleasepool {
        TPActiveProxies = [NSMutableSet set];
        NSBundle *bundle = [NSBundle mainBundle];
        if ([[bundle bundleIdentifier] isEqualToString:@"com.apple.mobileipod"]) { [[TPImporter sharedImporter] startMusicBridgeListener]; return; }
        if (![[bundle bundleIdentifier] isEqualToString:@"com.google.ios.youtube"] || ![[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqualToString:@"1.4.0"]) return;
        MSHookMessageEx([UIActionSheet class], @selector(showInView:), (IMP)TPShowActionSheet, (IMP *)&TPOriginalShow);
    }
}
