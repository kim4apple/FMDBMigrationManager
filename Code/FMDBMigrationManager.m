//
//  FMDBMigrationManager.m
//  
//
//  Created by Blake Watters on 6/4/14.
//
//

#import "FMDBMigrationManager.h"
#import <objc/runtime.h>

BOOL FMDBIsMigrationAtPath(NSString *path)
{
    static NSRegularExpression *migrationRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        migrationRegex = [NSRegularExpression regularExpressionWithPattern:@"\\d{1,15}_.+sql$" options:0 error:nil];
    });
    NSString *filename = [path lastPathComponent];
    return [migrationRegex rangeOfFirstMatchInString:filename options:0 range:NSMakeRange(0, [filename length])].location != NSNotFound;
}

static NSArray *FMDBClassesConformingToProtocol(Protocol *protocol)
{
    NSMutableArray *conformingClasses = [NSMutableArray new];
    Class *classes = NULL;
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses > 0 ) {
        classes = (Class *)malloc(sizeof(Class) * numClasses);
        numClasses = objc_getClassList(classes, numClasses);
        for (int index = 0; index < numClasses; index++) {
            Class nextClass = classes[index];
            if (class_conformsToProtocol(nextClass, protocol)) {
                [conformingClasses addObject:nextClass];
            }
        }
        free(classes);
    }
    return conformingClasses;
}

@interface FMDBMigrationManager ()
@property (nonatomic, strong) FMDatabase *database;
@end

@implementation FMDBMigrationManager

+ (instancetype)managerWithDatabaseAtPath:(NSString *)path migrationsBundle:(NSBundle *)bundle
{
    return [[self alloc] initWithDatabasePath:path migrationsBundle:bundle];
}

- (id)initWithDatabasePath:(NSString *)databasePath migrationsBundle:(NSBundle *)migrationsBundle
{
    self = [super init];
    if (self) {
        _databasePath = databasePath;
        _migrationsBundle = migrationsBundle;
        _database = [FMDatabase databaseWithPath:databasePath];
        [_database open];
    }
    return self;
}

- (id)init
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Failed to call designated initializer." userInfo:nil];
}

- (void)dealloc
{
    [_database close];
}

- (BOOL)hasMigrationsTable
{
    FMResultSet *resultSet = [self.database executeQuery:@"SELECT name FROM sqlite_master WHERE type='table' AND name=?", @"schema_migrations"];
    if ([resultSet next]) {
        return [resultSet stringForColumn:@"name"] != nil;
    }
    return NO;
}

- (BOOL)createMigrationsTable:(NSError **)error
{
    BOOL success = [self.database executeStatements:@"CREATE TABLE schema_migrations(version INTEGER UNIQUE NOT NULL)"];
    if (!success && error) *error = self.database.lastError;
    return success;
}

- (uint64_t)currentVersion
{
    FMResultSet *resultSet = [self.database executeQuery:@"SELECT MAX(version) FROM schema_migrations"];
    if ([resultSet next]) {
        return [resultSet unsignedLongLongIntForColumnIndex:0];
    }
    return 0;
}

- (uint64_t)originVersion
{
    FMResultSet *resultSet = [self.database executeQuery:@"SELECT MIN(version) FROM schema_migrations"];
    if ([resultSet next]) {
        return [resultSet unsignedLongLongIntForColumnIndex:0];
    }
    return 0;
}

- (NSArray *)appliedVersions
{
    NSMutableArray *versions = [NSMutableArray new];
    FMResultSet *resultSet = [self.database executeQuery:@"SELECT version FROM schema_migrations"];
    while ([resultSet next]) {
        uint64_t version = [resultSet unsignedLongLongIntForColumnIndex:0];
        [versions addObject:@(version)];
    }
    return versions;
}

- (NSArray *)pendingVersions
{
    NSMutableArray *pendingVersions = [[[self migrations] valueForKey:@"version"] mutableCopy];
    [pendingVersions removeObjectsInArray:self.appliedVersions];
    return pendingVersions;
}

- (NSArray *)migrations
{
    NSArray *migrationPaths = [self.migrationsBundle pathsForResourcesOfType:@"sql" inDirectory:nil];
    NSRegularExpression *migrationRegex = [NSRegularExpression regularExpressionWithPattern:@"\\d{15}_.+sql$" options:0 error:nil];
    NSMutableArray *migrations = [NSMutableArray new];
    for (NSString *path in migrationPaths) {
        NSString *filename = [path lastPathComponent];
        if ([migrationRegex rangeOfFirstMatchInString:filename options:0 range:NSMakeRange(0, [filename length])].location != NSNotFound) {
            FMDBFileMigration *migration = [FMDBFileMigration migrationWithPath:path];
            [migrations addObject:migration];
        }
    }
    
    // Find all classes implementing FMDBMigrating
    NSArray *conformingClasses = FMDBClassesConformingToProtocol(@protocol(FMDBMigrating));
    for (Class migrationClass in conformingClasses) {
        if ([migrationClass isSubclassOfClass:[FMDBFileMigration class]]) continue;
        id<FMDBMigrating> migration = [migrationClass new];
        [migrations addObject:migration];
    }
    return migrations;
}

- (id<FMDBMigrating>)migrationForVersion:(uint64_t)version
{
    for (id<FMDBMigrating>migration in [self migrations]) {
        if (migration.version == version) return migration;
    }
    return nil;
}

- (id<FMDBMigrating>)migrationForName:(NSString *)name
{
    for (id<FMDBMigrating>migration in [self migrations]) {
        if ([migration.name isEqualToString:name]) return migration;
    }
    return nil;
}

- (BOOL)migrateDatabaseToVersion:(uint64_t)version progress:(void (^)(NSProgress *progress))progressBlock error:(NSError **)error
{
    [self.database beginTransaction];
    BOOL success = YES;
    NSArray *pendingVersions = self.pendingVersions;
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:[pendingVersions count]];
    for (NSNumber *migrationVersionNumber in pendingVersions) {
        uint64_t migrationVersion = [migrationVersionNumber unsignedLongLongValue];
        if (migrationVersion > version) break;
        id<FMDBMigrating> migration = [self migrationForVersion:migrationVersion];
        success = [migration migrateDatabase:self.database error:error];
        if (!success) break;
        [self.database executeUpdate:@"INSERT INTO schema_migrations(version) VALUES (?)", @(migration.version)];
        progress.completedUnitCount++;
        if (progressBlock) progressBlock(progress);
        if (progress.cancelled) break;
    }
    if (!success || progress.cancelled) {
        [self.database rollback];
        return NO;
    }
    [self.database commit];
    return YES;
}

@end

static BOOL FMDBMigrationScanMetadataFromPath(NSString *path, uint64_t *version, NSString **name)
{
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d{15})_(.+)$" options:0 error:&error];
    if (!regex) {
        NSLog(@"[FMDBMigration] Failed constructing regex: %@", error);
        return NO;
    }
    NSString *migrationName = [[path lastPathComponent] stringByDeletingPathExtension];
    NSTextCheckingResult *result = [regex firstMatchInString:migrationName options:0 range:NSMakeRange(0, [migrationName length])];
    if ([result numberOfRanges] != 3) return NO;
    NSString *versionString = [migrationName substringWithRange:[result rangeAtIndex:1]];
    NSScanner *scanner = [NSScanner scannerWithString:versionString];
    [scanner scanUnsignedLongLong:version];
    *name = [migrationName substringWithRange:[result rangeAtIndex:2]];
    return YES;
}

@interface FMDBFileMigration ()
@property (nonatomic, readwrite) NSString *name;
@property (nonatomic, readwrite) uint64_t version;
@end

@implementation FMDBFileMigration

+ (instancetype)migrationWithPath:(NSString *)path
{
    return [[self alloc] initWithPath:path];
}

- (id)initWithPath:(NSString *)path
{
    NSString *name;
    uint64_t version;
    if (!FMDBMigrationScanMetadataFromPath(path, &version, &name)) return nil;
    
    self = [super init];
    if (self) {
        _path = path;
        _version = version;
        _name = name;
    }
    return self;
}

- (id)init
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Failed to call designated initializer." userInfo:nil];
}

- (NSString *)SQL
{
    return [NSString stringWithContentsOfFile:self.path encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)migrateDatabase:(FMDatabase *)database error:(out NSError *__autoreleasing *)error
{
    BOOL success = [database executeStatements:self.SQL];
    if (!success && error) *error = database.lastError;
    return success;
}

@end