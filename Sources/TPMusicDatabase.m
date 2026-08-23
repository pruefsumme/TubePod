#import "TPMusicDatabase.h"
#import <sqlite3.h>

NSString * const TPMusicDatabaseErrorDomain = @"com.pruefsumme.tubepod.database";
static NSString * const TPMusicDatabasePath = @"/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb";

static NSError *TPMusicDatabaseError(sqlite3 *database, NSInteger code, NSString *fallback) {
    const char *message = database ? sqlite3_errmsg(database) : NULL;
    return [NSError errorWithDomain:TPMusicDatabaseErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message && *message ? [NSString stringWithUTF8String:message] : (fallback ?: @"Music database query failed.")}];
}

static NSSet *TPQueryIDs(NSString *sql, NSArray *values, NSError **error) {
    sqlite3 *database = NULL;
    sqlite3_stmt *statement = NULL;
    NSMutableSet *result = [NSMutableSet set];
    int status = sqlite3_open_v2(TPMusicDatabasePath.UTF8String, &database, SQLITE_OPEN_READONLY, NULL);
    if (status != SQLITE_OK) {
        if (error) *error = TPMusicDatabaseError(database, status, @"Music could not open its read-only library database.");
        if (database) sqlite3_close(database);
        return nil;
    }
    sqlite3_busy_timeout(database, 1000);
    status = sqlite3_prepare_v2(database, sql.UTF8String, -1, &statement, NULL);
    if (status != SQLITE_OK) {
        if (error) *error = TPMusicDatabaseError(database, status, @"Music could not prepare its read-only library query.");
        sqlite3_close(database);
        return nil;
    }
    for (NSUInteger index = 0; index < values.count; index++) {
        NSString *value = values[index];
        status = sqlite3_bind_text(statement, (int)index + 1, value.UTF8String, -1, SQLITE_TRANSIENT);
        if (status != SQLITE_OK) {
            if (error) *error = TPMusicDatabaseError(database, status, @"Music could not bind its read-only library query.");
            sqlite3_finalize(statement); sqlite3_close(database); return nil;
        }
    }
    while ((status = sqlite3_step(statement)) == SQLITE_ROW) [result addObject:@(sqlite3_column_int64(statement, 0))];
    if (status != SQLITE_DONE) {
        if (error) *error = TPMusicDatabaseError(database, status, @"Music could not read its library query result.");
        result = nil;
    }
    sqlite3_finalize(statement);
    sqlite3_close(database);
    return result;
}

@implementation TPMusicDatabase
+ (NSSet *)allTrackIDsForTitle:(NSString *)title album:(NSString *)album error:(NSError **)error {
    if (!title.length || !album.length) { if (error) *error = [NSError errorWithDomain:TPMusicDatabaseErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"Music received empty track matching fields."}]; return nil; }
    return TPQueryIDs(@"SELECT e.item_pid FROM item_extra e JOIN item i USING(item_pid) JOIN album a ON a.album_pid=i.album_pid WHERE e.title=? AND a.album=?", @[title, album], error);
}

+ (NSSet *)completedTrackIDsForTitle:(NSString *)title album:(NSString *)album error:(NSError **)error {
    if (!title.length || !album.length) { if (error) *error = [NSError errorWithDomain:TPMusicDatabaseErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"Music received empty track matching fields."}]; return nil; }
    return TPQueryIDs(@"SELECT e.item_pid FROM item_extra e JOIN item i USING(item_pid) JOIN album a ON a.album_pid=i.album_pid JOIN item_stats s USING(item_pid) WHERE e.title=? AND a.album=? AND e.location<>'' AND s.is_downloading=0 ORDER BY e.date_created DESC", @[title, album], error);
}

+ (NSSet *)emptyPlaceholderTrackIDsForTitle:(NSString *)title album:(NSString *)album error:(NSError **)error {
    if (!title.length || !album.length) { if (error) *error = [NSError errorWithDomain:TPMusicDatabaseErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"Music received empty placeholder matching fields."}]; return nil; }
    return TPQueryIDs(@"SELECT e.item_pid FROM item_extra e JOIN item i USING(item_pid) JOIN album a ON a.album_pid=i.album_pid JOIN item_stats s USING(item_pid) WHERE e.title=? AND a.album=? AND e.location='' AND s.is_downloading=1", @[title, album], error);
}

+ (NSSet *)allEmptyPlaceholderTrackIDsForAlbum:(NSString *)album error:(NSError **)error {
    if (!album.length) { if (error) *error = [NSError errorWithDomain:TPMusicDatabaseErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"Music received an empty album matching field."}]; return nil; }
    return TPQueryIDs(@"SELECT e.item_pid FROM item_extra e JOIN item i USING(item_pid) JOIN album a ON a.album_pid=i.album_pid JOIN item_stats s USING(item_pid) WHERE a.album=? AND e.location='' AND s.is_downloading=1", @[album], error);
}

+ (NSDictionary *)recordForPersistentID:(NSNumber *)persistentID error:(NSError **)error {
    sqlite3 *database = NULL;
    sqlite3_stmt *statement = NULL;
    if (!persistentID) { if (error) *error = [NSError errorWithDomain:TPMusicDatabaseErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"Music received an empty persistent ID."}]; return nil; }
    int status = sqlite3_open_v2(TPMusicDatabasePath.UTF8String, &database, SQLITE_OPEN_READONLY, NULL);
    if (status != SQLITE_OK) { if (error) *error = TPMusicDatabaseError(database, status, @"Music could not open its read-only library database."); if (database) sqlite3_close(database); return nil; }
    sqlite3_busy_timeout(database, 1000);
    NSString *sql = @"SELECT e.item_pid,e.title,a.album,e.location,s.is_downloading FROM item_extra e JOIN item i USING(item_pid) JOIN album a ON a.album_pid=i.album_pid JOIN item_stats s USING(item_pid) WHERE e.item_pid=?";
    status = sqlite3_prepare_v2(database, sql.UTF8String, -1, &statement, NULL);
    int bindStatus = status == SQLITE_OK ? sqlite3_bind_int64(statement, 1, persistentID.longLongValue) : status;
    if (status != SQLITE_OK || bindStatus != SQLITE_OK) {
        status = status != SQLITE_OK ? status : bindStatus;
        if (error) *error = TPMusicDatabaseError(database, status, @"Music could not prepare its persistent-ID query.");
        if (statement) sqlite3_finalize(statement); sqlite3_close(database); return nil;
    }
    status = sqlite3_step(statement);
    if (status == SQLITE_DONE) { sqlite3_finalize(statement); sqlite3_close(database); return nil; }
    if (status != SQLITE_ROW) { if (error) *error = TPMusicDatabaseError(database, status, @"Music could not read its persistent-ID query."); sqlite3_finalize(statement); sqlite3_close(database); return nil; }
    const unsigned char *title = sqlite3_column_text(statement, 1);
    const unsigned char *album = sqlite3_column_text(statement, 2);
    const unsigned char *location = sqlite3_column_text(statement, 3);
    NSDictionary *record = @{ @"persistentID": @(sqlite3_column_int64(statement, 0)), @"title": title ? [NSString stringWithUTF8String:(const char *)title] : @"", @"album": album ? [NSString stringWithUTF8String:(const char *)album] : @"", @"location": location ? [NSString stringWithUTF8String:(const char *)location] : @"", @"downloading": @(sqlite3_column_int(statement, 4)) };
    sqlite3_finalize(statement); sqlite3_close(database); return record;
}
@end
