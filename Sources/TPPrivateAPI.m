#import "TPPrivateAPI.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <UIKit/UIKit.h>

static NSString * const TPPrivateErrorDomain = @"com.pruefsumme.tubepod.private";

typedef NS_ENUM(NSUInteger, TPPrivateReturnKind) {
    TPPrivateReturnObject,
    TPPrivateReturnBoolean,
    TPPrivateReturnVoid
};

static NSError *TPPrivateError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:TPPrivateErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"An Apple private API is incompatible with this device."}];
}

static BOOL TPReturnMatches(const char *encoding, TPPrivateReturnKind kind) {
    if (!encoding || !*encoding) return NO;
    switch (kind) {
        case TPPrivateReturnObject: return encoding[0] == '@' || encoding[0] == '#';
        case TPPrivateReturnBoolean: return encoding[0] == 'B' || encoding[0] == 'c' || encoding[0] == 'C';
        case TPPrivateReturnVoid: return encoding[0] == 'v';
    }
    return NO;
}

static BOOL TPCheck(id target, SEL selector, NSUInteger argumentCount, TPPrivateReturnKind returnKind, NSError **error) {
    if (!target || ![target respondsToSelector:selector]) {
        if (error) *error = TPPrivateError(1, [NSString stringWithFormat:@"Required private selector %@ is unavailable.", NSStringFromSelector(selector)]);
        return NO;
    }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != argumentCount + 2 || !TPReturnMatches(signature.methodReturnType, returnKind)) {
        if (error) *error = TPPrivateError(2, [NSString stringWithFormat:@"Private selector %@ has an incompatible signature.", NSStringFromSelector(selector)]);
        return NO;
    }
    return YES;
}

static void *TPLoad(NSString *path, NSError **error) {
    void *handle = dlopen(path.UTF8String, RTLD_NOW);
    if (!handle && error) *error = TPPrivateError(3, [NSString stringWithFormat:@"Required private framework is unavailable: %@.", path.lastPathComponent]);
    return handle;
}

static Class TPClass(NSString *name, NSError **error) {
    Class klass = NSClassFromString(name);
    if (!klass && error) *error = TPPrivateError(4, [NSString stringWithFormat:@"Required private class %@ is unavailable.", name]);
    return klass;
}

@implementation TPPrivateAPI
+ (BOOL)prepareStoreServices:(NSError **)error {
    return TPLoad(@"/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", error) != NULL &&
           TPClass(@"SSDownloadMetadata", error) && TPClass(@"SSDownload", error) && TPClass(@"SSDownloadQueue", error);
}

+ (id)newStoreMetadataWithTitle:(NSString *)title artist:(NSString *)artist durationMilliseconds:(NSNumber *)duration fileURL:(NSURL *)fileURL error:(NSError **)error {
    if (![self prepareStoreServices:error]) return nil;
    Class klass = TPClass(@"SSDownloadMetadata", error);
    SEL initSelector = NSSelectorFromString(@"initWithKind:");
    if (!TPCheck(klass, NSSelectorFromString(@"alloc"), 0, TPPrivateReturnObject, error)) return nil;
    id metadata = ((id(*)(id,SEL))objc_msgSend)(klass, NSSelectorFromString(@"alloc"));
    if (!TPCheck(metadata, initSelector, 1, TPPrivateReturnObject, error)) return nil;
    metadata = ((id(*)(id,SEL,id))objc_msgSend)(metadata, initSelector, @"song");
    if (!metadata) { if (error) *error = TPPrivateError(5, @"StoreServices could not allocate import metadata."); return nil; }
    NSArray *setters = @[
        @[NSStringFromSelector(@selector(setTitle:)), title ?: @"Untitled"],
        @[NSStringFromSelector(@selector(setArtistName:)), artist ?: @"Unknown Artist"],
        @[NSStringFromSelector(@selector(setCollectionName:)), @"TubePod"],
        @[NSStringFromSelector(@selector(setDurationInMilliseconds:)), duration ?: @0],
        @[NSStringFromSelector(@selector(setFileExtension:)), @"m4a"],
        @[NSStringFromSelector(@selector(setPrimaryAssetURL:)), fileURL ?: [NSURL URLWithString:@""]]
    ];
    for (NSArray *setter in setters) {
        SEL selector = NSSelectorFromString(setter[0]);
        if (!TPCheck(metadata, selector, 1, TPPrivateReturnVoid, error)) return nil;
        ((void(*)(id,SEL,id))objc_msgSend)(metadata, selector, setter[1]);
    }
    return metadata;
}

+ (id)newStoreDownloadWithMetadata:(id)metadata error:(NSError **)error {
    if (!metadata) { if (error) *error = TPPrivateError(6, @"StoreServices received empty import metadata."); return nil; }
    Class klass = TPClass(@"SSDownload", error);
    SEL selector = NSSelectorFromString(@"initWithDownloadMetadata:");
    if (!TPCheck(klass, @selector(alloc), 0, TPPrivateReturnObject, error)) return nil;
    id download = ((id(*)(id,SEL))objc_msgSend)(klass, @selector(alloc));
    if (!TPCheck(download, selector, 1, TPPrivateReturnObject, error)) return nil;
    download = ((id(*)(id,SEL,id))objc_msgSend)(download, selector, metadata);
    if (!download && error) *error = TPPrivateError(7, @"StoreServices could not allocate the import job.");
    return download;
}

+ (id)newStoreQueue:(NSError **)error {
    Class klass = TPClass(@"SSDownloadQueue", error);
    SEL kindsSelector = NSSelectorFromString(@"mediaDownloadKinds");
    SEL initSelector = NSSelectorFromString(@"initWithDownloadKinds:");
    if (!TPCheck(klass, kindsSelector, 0, TPPrivateReturnObject, error) || !TPCheck(klass, @selector(alloc), 0, TPPrivateReturnObject, error)) return nil;
    id kinds = ((id(*)(id,SEL))objc_msgSend)(klass, kindsSelector);
    id queue = ((id(*)(id,SEL))objc_msgSend)(klass, @selector(alloc));
    if (!TPCheck(queue, initSelector, 1, TPPrivateReturnObject, error)) return nil;
    queue = ((id(*)(id,SEL,id))objc_msgSend)(queue, initSelector, kinds);
    if (!queue && error) *error = TPPrivateError(8, @"StoreServices could not create its media queue.");
    return queue;
}

+ (BOOL)setStoreQueueAutomaticFinish:(id)queue error:(NSError **)error {
    SEL selector = NSSelectorFromString(@"setShouldAutomaticallyFinishDownloads:");
    if (!TPCheck(queue, selector, 1, TPPrivateReturnVoid, error)) return NO;
    ((void(*)(id,SEL,BOOL))objc_msgSend)(queue, selector, YES); return YES;
}
+ (BOOL)addStoreObserver:(id)observer toQueue:(id)queue error:(NSError **)error { SEL selector = NSSelectorFromString(@"addObserver:"); if (!TPCheck(queue, selector, 1, TPPrivateReturnVoid, error)) return NO; ((void(*)(id,SEL,id))objc_msgSend)(queue, selector, observer); return YES; }
+ (BOOL)removeStoreObserver:(id)observer fromQueue:(id)queue error:(NSError **)error { SEL selector = NSSelectorFromString(@"removeObserver:"); if (!TPCheck(queue, selector, 1, TPPrivateReturnVoid, error)) return NO; ((void(*)(id,SEL,id))objc_msgSend)(queue, selector, observer); return YES; }
+ (BOOL)addStoreDownload:(id)download toQueue:(id)queue error:(NSError **)error { SEL selector = NSSelectorFromString(@"addDownload:"); if (!TPCheck(queue, selector, 1, TPPrivateReturnBoolean, error)) return NO; return ((BOOL(*)(id,SEL,id))objc_msgSend)(queue, selector, download); }
+ (BOOL)cancelStoreDownload:(id)download fromQueue:(id)queue error:(NSError **)error { SEL selector = NSSelectorFromString(@"cancelDownload:"); if (!TPCheck(queue, selector, 1, TPPrivateReturnBoolean, error)) return NO; return ((BOOL(*)(id,SEL,id))objc_msgSend)(queue, selector, download); }
+ (NSArray *)storeDownloads:(id)queue error:(NSError **)error { SEL selector = NSSelectorFromString(@"downloads"); if (!TPCheck(queue, selector, 0, TPPrivateReturnObject, error)) return nil; id downloads = ((id(*)(id,SEL))objc_msgSend)(queue, selector); return [downloads isKindOfClass:[NSArray class]] ? downloads : nil; }
+ (NSError *)storeFailureError:(id)download error:(NSError **)error { SEL selector = NSSelectorFromString(@"failureError"); if (!TPCheck(download, selector, 0, TPPrivateReturnObject, error)) return nil; id failure = ((id(*)(id,SEL))objc_msgSend)(download, selector); return [failure isKindOfClass:[NSError class]] ? failure : nil; }
+ (id)storeMetadataForDownload:(id)download error:(NSError **)error { SEL selector = NSSelectorFromString(@"metadata"); if (!TPCheck(download, selector, 0, TPPrivateReturnObject, error)) return nil; return ((id(*)(id,SEL))objc_msgSend)(download, selector); }
+ (NSString *)storeCollectionNameForMetadata:(id)metadata error:(NSError **)error { SEL selector = NSSelectorFromString(@"collectionName"); if (!TPCheck(metadata, selector, 0, TPPrivateReturnObject, error)) return nil; id value = ((id(*)(id,SEL))objc_msgSend)(metadata, selector); return [value isKindOfClass:[NSString class]] ? value : nil; }

+ (id)sharedMusicLibrary:(NSError **)error {
    if (!TPLoad(@"/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", error)) return nil;
    Class klass = TPClass(@"ML3MusicLibrary", error); SEL selector = NSSelectorFromString(@"sharedLibrary");
    if (!TPCheck(klass, selector, 0, TPPrivateReturnObject, error)) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(klass, selector);
}
+ (id)newMusicTrackWithPersistentID:(long long)persistentID library:(id)library error:(NSError **)error {
    Class klass = TPClass(@"ML3Track", error); SEL selector = NSSelectorFromString(@"newWithPersistentID:inLibrary:");
    if (!TPCheck(klass, selector, 2, TPPrivateReturnObject, error)) return nil;
    return ((id(*)(id,SEL,long long,id))objc_msgSend)(klass, selector, persistentID, library);
}
+ (NSString *)musicTrackFilePath:(id)track error:(NSError **)error { SEL selector = NSSelectorFromString(@"absoluteFilePath"); if (!TPCheck(track, selector, 0, TPPrivateReturnObject, error)) return nil; id path = ((id(*)(id,SEL))objc_msgSend)(track, selector); return [path isKindOfClass:[NSString class]] ? path : nil; }
+ (BOOL)setMusicTrack:(id)track value:(id)value forPropertyName:(NSString *)propertyName error:(NSError **)error {
    if (!propertyName.length) { if (error) *error = TPPrivateError(9, @"Music did not expose the requested track property."); return NO; }
    void *framework = dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_NOW);
    NSString * __unsafe_unretained *address = framework ? (NSString * __unsafe_unretained *)dlsym(framework, propertyName.UTF8String) : NULL;
    NSString *property = address ? *address : nil; SEL selector = NSSelectorFromString(@"setValue:forProperty:");
    if (!property.length || !TPCheck(track, selector, 2, TPPrivateReturnBoolean, error)) return NO;
    return ((BOOL(*)(id,SEL,id,id))objc_msgSend)(track, selector, value, property);
}
+ (id)musicTrackValue:(id)track forPropertyName:(NSString *)propertyName error:(NSError **)error {
    if (!propertyName.length) { if (error) *error = TPPrivateError(9, @"Music did not expose the requested track property."); return nil; }
    void *framework = dlopen("/System/Library/PrivateFrameworks/MusicLibrary.framework/MusicLibrary", RTLD_NOW);
    NSString * __unsafe_unretained *address = framework ? (NSString * __unsafe_unretained *)dlsym(framework, propertyName.UTF8String) : NULL;
    NSString *property = address ? *address : nil; SEL selector = NSSelectorFromString(@"valueForProperty:");
    if (!property.length || !TPCheck(track, selector, 1, TPPrivateReturnObject, error)) return nil;
    return ((id(*)(id,SEL,id))objc_msgSend)(track, selector, property);
}
+ (BOOL)updateMusicTrackIntegrity:(id)track error:(NSError **)error { SEL selector = NSSelectorFromString(@"updateIntegrity"); if (!TPCheck(track, selector, 0, TPPrivateReturnBoolean, error)) return NO; return ((BOOL(*)(id,SEL))objc_msgSend)(track, selector); }
+ (BOOL)populateMusicTrackArtwork:(id)track data:(NSData *)data error:(NSError **)error {
    if (!data.length) { if (error) *error = TPPrivateError(10, @"Music received empty artwork data."); return NO; }
    SEL selector = NSSelectorFromString(@"populateArtworkCacheWithArtworkData:");
    if (!TPCheck(track, selector, 1, TPPrivateReturnBoolean, error)) return NO;
    return ((BOOL(*)(id,SEL,id))objc_msgSend)(track, selector, data);
}
+ (BOOL)deleteMusicTrack:(id)track error:(NSError **)error { SEL selector = NSSelectorFromString(@"deleteFromLibrary"); if (!TPCheck(track, selector, 0, TPPrivateReturnBoolean, error)) return NO; return ((BOOL(*)(id,SEL))objc_msgSend)(track, selector); }
+ (BOOL)notifyMusicLibrary:(id)library error:(NSError **)error { SEL selector = NSSelectorFromString(@"notifyContentsDidChange"); if (!TPCheck(library, selector, 0, TPPrivateReturnVoid, error)) return NO; ((void(*)(id,SEL))objc_msgSend)(library, selector); return YES; }
+ (BOOL)reloadMediaPlayerLibrary:(NSError **)error {
    if (!TPLoad(@"/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", error)) return NO;
    Class klass = TPClass(@"MPMediaLibrary", error); SEL defaultSelector = NSSelectorFromString(@"defaultMediaLibrary");
    SEL reloadSelector = NSSelectorFromString(@"_reloadLibraryForContentsChangeWithNotificationInfo:");
    if (!TPCheck(klass, defaultSelector, 0, TPPrivateReturnObject, error)) return NO;
    id library = ((id(*)(id,SEL))objc_msgSend)(klass, defaultSelector);
    if (!TPCheck(library, reloadSelector, 1, TPPrivateReturnVoid, error)) return NO;
    ((void(*)(id,SEL,id))objc_msgSend)(library, reloadSelector, nil);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MPMediaLibraryDidChangeNotification" object:library];
    return YES;
}
@end
