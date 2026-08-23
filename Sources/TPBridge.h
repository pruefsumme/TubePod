#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, TPBridgeCommandKind) {
    TPBridgeCommandKindRequest = 0,
    TPBridgeCommandKindCancel = 1
};

typedef NS_ENUM(NSInteger, TPBridgeStatusKind) {
    TPBridgeStatusKindProcessing = 0,
    TPBridgeStatusKindCancelled = 1,
    TPBridgeStatusKindSuccess = 2,
    TPBridgeStatusKindError = 3
};

extern NSString * const TPBridgeErrorDomain;
extern NSString * const TPBridgeVideoIDKey;
extern NSString * const TPBridgeSourceVideoIDKey;
extern NSString * const TPBridgeTokenKey;
extern NSString * const TPBridgeVersionKey;
extern NSString * const TPBridgeCommandKey;
extern NSString * const TPBridgeStatusKey;
extern NSString * const TPBridgeMediaLengthKey;
extern NSString * const TPBridgeMessageKey;
extern NSString * const TPBridgeAllowDuplicateKey;
extern const NSUInteger TPBridgeProtocolVersion;
extern const NSUInteger TPBridgeMaximumMediaBytes;

#ifdef __cplusplus
extern "C" {
#endif
BOOL TPVideoIDIsValid(NSString *videoID);
#ifdef __cplusplus
}
#endif

@interface TPBridge : NSObject
+ (UIPasteboard *)commandPasteboard;
+ (UIPasteboard *)statusPasteboard;
+ (UIPasteboard *)payloadPasteboard;

+ (NSDictionary *)readCommand;
+ (NSDictionary *)readStatus;
+ (NSData *)readPayload;

+ (NSDictionary *)requestCommandWithToken:(NSString *)token videoID:(NSString *)videoID sourceVideoID:(NSString *)sourceVideoID title:(NSString *)title artist:(NSString *)artist duration:(NSNumber *)duration mediaLength:(NSUInteger)mediaLength allowDuplicate:(BOOL)allowDuplicate error:(NSError **)error;
+ (NSDictionary *)cancelCommandWithToken:(NSString *)token videoID:(NSString *)videoID error:(NSError **)error;
+ (NSDictionary *)statusWithKind:(TPBridgeStatusKind)kind token:(NSString *)token message:(NSString *)message;

+ (BOOL)writeCommand:(NSDictionary *)command error:(NSError **)error;
+ (BOOL)writeStatus:(NSDictionary *)status error:(NSError **)error;
+ (BOOL)writePayload:(NSData *)data error:(NSError **)error;

+ (BOOL)validateCommand:(NSDictionary *)command error:(NSError **)error;
+ (BOOL)validateStatus:(NSDictionary *)status error:(NSError **)error;
+ (void)clearCommand;
+ (void)clearPayload;
+ (NSString *)statusNameForKind:(TPBridgeStatusKind)kind;
+ (TPBridgeStatusKind)statusKindForName:(NSString *)name;
@end
