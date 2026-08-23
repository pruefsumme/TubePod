#import <Foundation/Foundation.h>

extern NSString * const TPDatabaseErrorDomain;

@interface TPDatabase : NSObject
+ (NSSet *)allTrackIDsForTitle:(NSString *)title album:(NSString *)album error:(NSError **)error;
+ (NSSet *)completedTrackIDsForTitle:(NSString *)title album:(NSString *)album error:(NSError **)error;
+ (NSSet *)emptyPlaceholderTrackIDsForTitle:(NSString *)title album:(NSString *)album error:(NSError **)error;
+ (NSSet *)allEmptyPlaceholderTrackIDsForAlbum:(NSString *)album error:(NSError **)error;
+ (NSDictionary *)recordForPersistentID:(NSNumber *)persistentID error:(NSError **)error;
@end
