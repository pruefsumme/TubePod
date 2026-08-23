#import <Foundation/Foundation.h>

typedef void (^TPImportCompletion)(BOOL success, NSError *error);

@interface TPImporter : NSObject
+ (instancetype)sharedImporter;
- (void)importM4A:(NSURL *)fileURL metadata:(NSDictionary *)metadata completion:(TPImportCompletion)completion;
- (void)startMusicBridgeListener;
@end
