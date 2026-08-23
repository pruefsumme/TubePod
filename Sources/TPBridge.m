#import "TPBridge.h"
#import <UIKit/UIKit.h>

NSString * const TPBridgeErrorDomain = @"com.pruefsumme.tubepod.bridge";
NSString * const TPBridgeVideoIDKey = @"videoID";
NSString * const TPBridgeSourceVideoIDKey = @"sourceVideoID";
NSString * const TPBridgeTokenKey = @"token";
NSString * const TPBridgeVersionKey = @"version";
NSString * const TPBridgeCommandKey = @"command";
NSString * const TPBridgeStatusKey = @"status";
NSString * const TPBridgeMediaLengthKey = @"mediaLength";
NSString * const TPBridgeMessageKey = @"message";
NSString * const TPBridgeAllowDuplicateKey = @"allowDuplicate";
const NSUInteger TPBridgeProtocolVersion = 1;
const NSUInteger TPBridgeMaximumMediaBytes = 24U * 1024U * 1024U;

static NSString * const TPCommandPasteboardName = @"com.pruefsumme.tubepod.command";
static NSString * const TPCommandPasteboardType = @"com.pruefsumme.tubepod.command.plist";
static NSString * const TPStatusPasteboardName = @"com.pruefsumme.tubepod.status";
static NSString * const TPStatusPasteboardType = @"com.pruefsumme.tubepod.status.plist";
static NSString * const TPPayloadPasteboardName = @"com.pruefsumme.tubepod.payload";
static NSString * const TPPayloadPasteboardType = @"com.pruefsumme.tubepod.payload.m4a";

static NSError *TPBridgeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:TPBridgeErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"Invalid TubePod bridge message."}];
}

BOOL TPVideoIDIsValid(NSString *videoID) {
    if (![videoID isKindOfClass:[NSString class]] || videoID.length != 11) return NO;
    for (NSUInteger index = 0; index < videoID.length; index++) {
        unichar character = [videoID characterAtIndex:index];
        if (!((character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') ||
              (character >= '0' && character <= '9') || character == '_' || character == '-')) return NO;
    }
    return YES;
}

static UIPasteboard *TPNamedPasteboard(NSString *name) {
    UIPasteboard *pasteboard = [UIPasteboard pasteboardWithName:name create:YES];
    // The bridge only needs to survive the YouTube-to-Music app switch. Keeping
    // a request across a reboot could unexpectedly replay an abandoned import.
    pasteboard.persistent = NO;
    return pasteboard;
}

static BOOL TPWritePlist(UIPasteboard *pasteboard, NSString *type, NSDictionary *message, NSError **error) {
    if (![message isKindOfClass:[NSDictionary class]]) {
        if (error) *error = TPBridgeError(1, @"TubePod could not serialize its bridge message.");
        return NO;
    }
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:message format:NSPropertyListBinaryFormat_v1_0 options:0 error:&serializationError];
    if (!data) {
        if (error) *error = serializationError ?: TPBridgeError(2, @"TubePod could not serialize its bridge message.");
        return NO;
    }
    @try {
        [pasteboard setData:data forPasteboardType:type];
    } @catch (NSException *exception) {
        if (error) *error = TPBridgeError(3, [NSString stringWithFormat:@"TubePod could not write its bridge message: %@.", exception.reason ?: @"pasteboard failure"]);
        return NO;
    }
    return YES;
}

static NSDictionary *TPReadPlist(UIPasteboard *pasteboard, NSString *type) {
    NSData *data = [pasteboard dataForPasteboardType:type];
    if (!data.length) return nil;
    @autoreleasepool {
        id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
        return [value isKindOfClass:[NSDictionary class]] ? [value copy] : nil;
    }
}

@implementation TPBridge
+ (UIPasteboard *)commandPasteboard { return TPNamedPasteboard(TPCommandPasteboardName); }
+ (UIPasteboard *)statusPasteboard { return TPNamedPasteboard(TPStatusPasteboardName); }
+ (UIPasteboard *)payloadPasteboard { return TPNamedPasteboard(TPPayloadPasteboardName); }
+ (NSDictionary *)readCommand { return TPReadPlist([self commandPasteboard], TPCommandPasteboardType); }
+ (NSDictionary *)readStatus { return TPReadPlist([self statusPasteboard], TPStatusPasteboardType); }
+ (NSData *)readPayload { return [[self payloadPasteboard] dataForPasteboardType:TPPayloadPasteboardType]; }

+ (NSDictionary *)requestCommandWithToken:(NSString *)token videoID:(NSString *)videoID sourceVideoID:(NSString *)sourceVideoID title:(NSString *)title artist:(NSString *)artist duration:(NSNumber *)duration mediaLength:(NSUInteger)mediaLength allowDuplicate:(BOOL)allowDuplicate error:(NSError **)error {
    NSDictionary *command = @{TPBridgeVersionKey: @(TPBridgeProtocolVersion), TPBridgeCommandKey: @"request",
                               TPBridgeTokenKey: token ?: @"", TPBridgeVideoIDKey: videoID ?: @"",
                               TPBridgeSourceVideoIDKey: sourceVideoID ?: videoID ?: @"",
                               @"title": title ?: @"Untitled", @"artist": artist ?: @"Unknown Artist",
                               @"duration": duration ?: @0, TPBridgeMediaLengthKey: @(mediaLength),
                               TPBridgeAllowDuplicateKey: @(allowDuplicate)};
    if (![self validateCommand:command error:error]) return nil;
    return command;
}

+ (NSDictionary *)cancelCommandWithToken:(NSString *)token videoID:(NSString *)videoID error:(NSError **)error {
    NSDictionary *command = @{TPBridgeVersionKey: @(TPBridgeProtocolVersion), TPBridgeCommandKey: @"cancel", TPBridgeTokenKey: token ?: @"", TPBridgeVideoIDKey: videoID ?: @""};
    if (![self validateCommand:command error:error]) return nil;
    return command;
}

+ (NSDictionary *)statusWithKind:(TPBridgeStatusKind)kind token:(NSString *)token message:(NSString *)message {
    return @{TPBridgeVersionKey: @(TPBridgeProtocolVersion), TPBridgeStatusKey: [self statusNameForKind:kind], TPBridgeTokenKey: token ?: @"", TPBridgeMessageKey: message ?: @""};
}

+ (BOOL)writeCommand:(NSDictionary *)command error:(NSError **)error {
    if (![self validateCommand:command error:error]) return NO;
    return TPWritePlist([self commandPasteboard], TPCommandPasteboardType, command, error);
}
+ (BOOL)writeStatus:(NSDictionary *)status error:(NSError **)error {
    if (![self validateStatus:status error:error]) return NO;
    return TPWritePlist([self statusPasteboard], TPStatusPasteboardType, status, error);
}

+ (BOOL)writePayload:(NSData *)data error:(NSError **)error {
    if (!data.length || data.length > TPBridgeMaximumMediaBytes) {
        if (error) *error = TPBridgeError(4, data.length > TPBridgeMaximumMediaBytes ? @"The converted M4A is larger than the 24 MiB bridge limit." : @"The converted M4A is empty.");
        return NO;
    }
    @try {
        [[self payloadPasteboard] setData:data forPasteboardType:TPPayloadPasteboardType];
    } @catch (NSException *exception) {
        if (error) *error = TPBridgeError(5, [NSString stringWithFormat:@"TubePod could not write the M4A payload: %@.", exception.reason ?: @"pasteboard failure"]);
        return NO;
    }
    return YES;
}

+ (BOOL)validateCommand:(NSDictionary *)command error:(NSError **)error {
    if (![command isKindOfClass:[NSDictionary class]] || [command[TPBridgeVersionKey] unsignedIntegerValue] != TPBridgeProtocolVersion) {
        if (error) *error = TPBridgeError(6, @"TubePod received an unsupported bridge protocol version.");
        return NO;
    }
    NSString *kind = command[TPBridgeCommandKey];
    NSString *token = command[TPBridgeTokenKey];
    if (![kind isKindOfClass:[NSString class]] || !([kind isEqualToString:@"request"] || [kind isEqualToString:@"cancel"]) || ![token isKindOfClass:[NSString class]] || !token.length) {
        if (error) *error = TPBridgeError(7, @"TubePod received a malformed bridge command.");
        return NO;
    }
    if (!TPVideoIDIsValid(command[TPBridgeVideoIDKey])) {
        if (error) *error = TPBridgeError(8, @"TubePod received a command without a valid video ID.");
        return NO;
    }
    if ([kind isEqualToString:@"request"]) {
        if (!TPVideoIDIsValid(command[TPBridgeVideoIDKey]) || ![command[TPBridgeSourceVideoIDKey] isKindOfClass:[NSString class]] ||
            ![command[@"title"] isKindOfClass:[NSString class]] || ![command[@"artist"] isKindOfClass:[NSString class]] ||
            ![command[@"duration"] isKindOfClass:[NSNumber class]] || ![command[TPBridgeAllowDuplicateKey] isKindOfClass:[NSNumber class]] ||
            [command[TPBridgeMediaLengthKey] unsignedIntegerValue] == 0 ||
            [command[TPBridgeMediaLengthKey] unsignedIntegerValue] > TPBridgeMaximumMediaBytes) {
            if (error) *error = TPBridgeError(8, @"TubePod received a malformed or oversized import request.");
            return NO;
        }
    }
    return YES;
}

+ (BOOL)validateStatus:(NSDictionary *)status error:(NSError **)error {
    if (![status isKindOfClass:[NSDictionary class]] || [status[TPBridgeVersionKey] unsignedIntegerValue] != TPBridgeProtocolVersion ||
        ![status[TPBridgeTokenKey] isKindOfClass:[NSString class]] || ![status[TPBridgeTokenKey] length] ||
        [self statusKindForName:status[TPBridgeStatusKey]] == NSNotFound) {
        if (error) *error = TPBridgeError(9, @"TubePod received a malformed or unsupported Music status.");
        return NO;
    }
    return YES;
}

+ (void)clearCommand { @try { [[self commandPasteboard] setItems:@[]]; } @catch (__unused NSException *exception) {} }
+ (void)clearPayload { @try { [[self payloadPasteboard] setItems:@[]]; } @catch (__unused NSException *exception) {} }

+ (NSString *)statusNameForKind:(TPBridgeStatusKind)kind {
    switch (kind) {
        case TPBridgeStatusKindProcessing: return @"processing";
        case TPBridgeStatusKindCancelled: return @"cancelled";
        case TPBridgeStatusKindSuccess: return @"success";
        case TPBridgeStatusKindError: return @"error";
    }
    return @"error";
}

+ (TPBridgeStatusKind)statusKindForName:(NSString *)name {
    if ([name isEqualToString:@"processing"]) return TPBridgeStatusKindProcessing;
    if ([name isEqualToString:@"cancelled"]) return TPBridgeStatusKindCancelled;
    if ([name isEqualToString:@"success"]) return TPBridgeStatusKindSuccess;
    if ([name isEqualToString:@"error"]) return TPBridgeStatusKindError;
    return NSNotFound;
}
@end
