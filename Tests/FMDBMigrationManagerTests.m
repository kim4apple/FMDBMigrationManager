//
//  FMDBMigrationManagerTests.m
//  FMDBMigrationManager
//
//  Created by Blake Watters on 6/6/14.
//
//

#import <XCTest/XCTest.h>
#define EXP_SHORTHAND
#import "Expecta.h"
#import "FMDBmigrationManager.h"

static NSString *FMDBApplicationDataDirectory(void)
{
#if TARGET_OS_IPHONE
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
#else
    NSFileManager *sharedFM = [NSFileManager defaultManager];
    
    NSArray *possibleURLs = [sharedFM URLsForDirectory:NSApplicationSupportDirectory
                                             inDomains:NSUserDomainMask];
    NSURL *appSupportDir = nil;
    NSURL *appDirectory = nil;
    
    if ([possibleURLs count] >= 1) {
        appSupportDir = [possibleURLs objectAtIndex:0];
    }
    
    if (appSupportDir) {
        NSString *executableName = [[[NSBundle mainBundle] executablePath] lastPathComponent];
        appDirectory = [appSupportDir URLByAppendingPathComponent:executableName];
        return [appDirectory path];
    }
    
    return nil;
#endif
}

static NSString *FMDBRandomDatabasePath()
{
    return [FMDBApplicationDataDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
}

static NSBundle *FMDBMigrationsTestBundle()
{
    NSBundle *parentBundle = [NSBundle bundleForClass:NSClassFromString(@"FMDBMigrationManagerTests")];
    return [NSBundle bundleWithPath:[parentBundle pathForResource:@"Migrations" ofType:@"bundle"]];
}

static FMDatabase *FMDatabaseWithSchemaMigrationsTable()
{
    FMDatabase *database = [FMDatabase databaseWithPath:FMDBRandomDatabasePath()];
    [database open];
    [database executeStatements:@"CREATE TABLE schema_migrations(version INTEGER UNIQUE NOT NULL);"];
    return database;
}

@interface FMDBTestObjectMigration : NSObject <FMDBMigrating>
@end

@implementation FMDBTestObjectMigration

- (NSString *)name
{
    return @"My Object Migration";
}

- (uint64_t)version
{
    return 201499000000000;
}

- (BOOL)migrateDatabase:(FMDatabase *)database error:(out NSError *__autoreleasing *)error
{
    return YES;
}

@end

@interface FMDBMigrationManagerTests : XCTestCase
@end

@implementation FMDBMigrationManagerTests

+ (void)setUp
{
    NSString *applicationDataDirectory = FMDBApplicationDataDirectory();
    BOOL isDirectory;
    if ([[NSFileManager defaultManager] fileExistsAtPath:applicationDataDirectory isDirectory:&isDirectory]) {
        if (!isDirectory) [NSException raise:NSInternalInconsistencyException format:@"Cannot execute tests: expected to find directory at path returned by `FMDBApplicationDataDirectory()`, but instead found a file. (%@)", applicationDataDirectory];
    } else {
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:applicationDataDirectory withIntermediateDirectories:YES attributes:nil error:&error]) {
            [NSException raise:NSInternalInconsistencyException format:@"Cannot execute tests: failed while attempting to create path returned by `FMDBApplicationDataDirectory()`: %@ (%@)", error, applicationDataDirectory];
        }
    }
}

- (void)testHasMigrationTableWhenTableDoesntExist
{
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:FMDBRandomDatabasePath() migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.hasMigrationsTable).to.beFalsy();
}

- (void)testHasMigrationTableWhenTableExists
{
    FMDatabase *database = FMDatabaseWithSchemaMigrationsTable();
    [database close];
    
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:database.databasePath migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.hasMigrationsTable).to.beTruthy();
}

- (void)testGettingMigrations
{
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:FMDBRandomDatabasePath() migrationsBundle:FMDBMigrationsTestBundle()];
    NSArray *migrations = manager.migrations;
    expect(migrations).to.haveCountOf(3);
    expect([migrations valueForKey:@"name"]).to.equal(@[@"create_mb-demo-schema", @"create_add_second_table", @"My Object Migration"]);
    expect([migrations valueForKey:@"version"]).to.equal(@[@201406063106474, @201406063548463, @201499000000000 ]);
}

- (void)testGettingMigrationByVersion
{
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:FMDBRandomDatabasePath() migrationsBundle:FMDBMigrationsTestBundle()];
    FMDBFileMigration *migration = [manager migrationForVersion:201406063106474];
    NSString *expectedPath = [FMDBMigrationsTestBundle() pathForResource:@"201406063106474_create_mb-demo-schema" ofType:@"sql"];
    expect(migration.version).to.equal(201406063106474);
    expect(migration.name).to.equal(@"create_mb-demo-schema");
    expect(migration.path).to.equal(expectedPath);
}

- (void)testGettingMigrationByName
{
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:FMDBRandomDatabasePath() migrationsBundle:FMDBMigrationsTestBundle()];
    FMDBFileMigration *migration = [manager migrationForName:@"create_mb-demo-schema"];
    NSString *expectedPath = [FMDBMigrationsTestBundle() pathForResource:@"201406063106474_create_mb-demo-schema" ofType:@"sql"];
    expect(migration.version).to.equal(201406063106474);
    expect(migration.name).to.equal(@"create_mb-demo-schema");
    expect(migration.path).to.equal(expectedPath);
}

- (void)testNewDatabaseReturnsZeroForCurrentVersion
{
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:FMDBRandomDatabasePath() migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.currentVersion).to.equal(0);
}

- (void)testCreatingSchemaMigrationsTable
{
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:FMDBRandomDatabasePath() migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.hasMigrationsTable).to.beFalsy();
    NSError *error = nil;
    BOOL success = [manager createMigrationsTable:&error];
    expect(success).to.beTruthy();
    expect(error).to.beNil();
    expect(manager.hasMigrationsTable).to.beTruthy();
}

- (void)testDatabaseWithSingleRowReturnsItForCurrentVersion
{
    FMDatabase *database = FMDatabaseWithSchemaMigrationsTable();
    [database executeUpdate:@"INSERT INTO schema_migrations(version) VALUES (?)", @31337];
    [database close];
    
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:database.databasePath migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.currentVersion).to.equal(31337);
}

- (void)testDatabaseWithSingleRowReturnsItForOriginVersion
{
    FMDatabase *database = FMDatabaseWithSchemaMigrationsTable();
    [database executeUpdate:@"INSERT INTO schema_migrations(version) VALUES (?)", @31337];
    [database close];
    
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:database.databasePath migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.originVersion).to.equal(31337);
}

- (void)testDatabaseWithMultipleVersionReturnsCorrectValueForOriginVersion
{
    FMDatabase *database = FMDatabaseWithSchemaMigrationsTable();
    [database executeUpdate:@"INSERT INTO schema_migrations(version) VALUES (?)", @31337];
    [database executeUpdate:@"INSERT INTO schema_migrations(version) VALUES (?)", @99999];
    [database close];
    
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:database.databasePath migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.originVersion).to.equal(31337);
}

- (void)testDatabaseWithMultipleVersionReturnsCorrectValueForCurrentVersion
{
    FMDatabase *database = FMDatabaseWithSchemaMigrationsTable();
    [database executeUpdate:@"INSERT INTO schema_migrations(version) VALUES (?)", @31337];
    [database executeUpdate:@"INSERT INTO schema_migrations(version) VALUES (?)", @99999];
    [database close];
    
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:database.databasePath migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.currentVersion).to.equal(99999);
}

- (void)testNewDatabaseReturnsZeroForOriginVersion
{
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:FMDBRandomDatabasePath() migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.originVersion).to.equal(0);
}

- (void)testNewDatabaseReturnsEmptyArrayForAppliedVersions
{
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:FMDBRandomDatabasePath() migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.appliedVersions).to.beEmpty();
}

- (void)testAppliedVersionReturnsAllRowsFromTheSchemaMigrationsTable
{
    FMDatabase *database = FMDatabaseWithSchemaMigrationsTable();
    [database executeUpdate:@"INSERT INTO schema_migrations(version) VALUES (?)", @31337];
    [database executeUpdate:@"INSERT INTO schema_migrations(version) VALUES (?)", @99999];
    [database close];
    
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:database.databasePath migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.appliedVersions).to.equal(@[ @31337, @99999 ]);
}

- (void)testPendingVersionsForNewDatabase
{
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:FMDBRandomDatabasePath() migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.pendingVersions).to.equal(@[@201406063106474, @201406063548463, @201499000000000]);
}

- (void)testPendingVersionsForNonUpToDateMigration
{
    FMDatabase *database = FMDatabaseWithSchemaMigrationsTable();
    [database executeUpdate:@"INSERT INTO schema_migrations(version) VALUES (?)", @201406063106474];
    [database close];
    
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:database.databasePath migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.pendingVersions).to.equal(@[ @201406063548463, @201499000000000 ]);
}

- (void)testMigratingNewDatabaseToLatestVersion
{
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:FMDBRandomDatabasePath() migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.hasMigrationsTable).to.beFalsy();
    NSError *error = nil;
    BOOL success = [manager migrateDatabaseToVersion:UINT64_MAX progress:nil error:&error];
    expect(success).to.beTruthy();
    expect(error).to.beNil();
    expect(manager.hasMigrationsTable).to.beTruthy();
    expect(manager.currentVersion).to.equal(201499000000000);
}

- (void)testMigratingNewDatabaseToSpecificVersion
{
    FMDBMigrationManager *manager = [FMDBMigrationManager managerWithDatabaseAtPath:FMDBRandomDatabasePath() migrationsBundle:FMDBMigrationsTestBundle()];
    expect(manager.hasMigrationsTable).to.beFalsy();
    NSError *error = nil;
    BOOL success = [manager migrateDatabaseToVersion:201406063106474 progress:nil error:&error];
    expect(success).to.beTruthy();
    expect(error).to.beNil();
    expect(manager.hasMigrationsTable).to.beTruthy();
    expect(manager.currentVersion).to.equal(201406063106474);
}

@end