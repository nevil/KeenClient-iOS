//
//  KeenClient.m
//  KeenClient
//
//  Created by Daniel Kador on 2/8/12.
//  Copyright (c) 2012 Keen Labs. All rights reserved.
//

#import "KeenClient.h"
#import "KeenConstants.h"
#import "KIOEventStore.h"
#import <CoreLocation/CoreLocation.h>


static KeenClient *sharedClient;
static BOOL loggingEnabled = NO;
static KIOEventStore *eventStore;

@interface KeenClient ()

// The project ID for this particular client.
@property (nonatomic, strong) NSString *projectId;

// The Write Key for this particular client.
@property (nonatomic, strong) NSString *writeKey;

// The Read Key for this particular client.
@property (nonatomic, strong) NSString *readKey;

// NSLocationManager
@property (nonatomic, strong) CLLocationManager *locationManager;

// How many times the previous timestamp has been used.
@property (nonatomic) NSInteger numTimesTimestampUsed;

// The max number of events per collection.
@property (nonatomic, readonly) NSUInteger maxEventsPerCollection;

// The number of events to drop when aging out a collection.
@property (nonatomic, readonly) NSUInteger numberEventsToForget;

// A dispatch queue used for uploads.
@property (nonatomic) dispatch_queue_t uploadQueue;

// If we're running tests.
@property (nonatomic) Boolean isRunningTests;

/**
 Initializes KeenClient without setting its project ID or API key.
 @returns An instance of KeenClient.
 */
- (id)init;

/**
 Validates that the given project ID is valid.
 @param projectId The Keen project ID.
 @returns YES if project id is valid, NO otherwise.
 */
+ (BOOL)validateProjectId:(NSString *)projectId;

/**
 Validates that the given key is valid.
 @param key The key to check.
 @returns YES if key is valid, NO otherwise.
 */
+ (BOOL)validateKey:(NSString *)key;

/**
 Returns the path to the app's library/cache directory.
 @returns An NSString* that is a path to the app's documents directory.
 */
- (NSString *)cacheDirectory;

/**
 Returns the root keen directory where collection sub-directories exist.
 @returns An NSString* that is a path to the keen root directory.
 */
- (NSString *)keenDirectory;

/**
 Returns the direct child sub-directories of the root keen directory.
 @returns An NSArray* of NSStrings* that are names of sub-directories.
 */
- (NSArray *)keenSubDirectories;

/**
 Returns all the files and directories that are children of the argument path.
 @param path An NSString* that's a fully qualified path to a directory on the file system.
 @returns An NSArray* of NSStrings* that are names of sub-files or directories.
 */
- (NSArray *)contentsAtPath:(NSString *)path;

/**
 Returns the directory for a particular collection where events exist.
 @param collection The collection.
 @returns An NSString* that is a path to the collection directory.
 */
- (NSString *)eventDirectoryForCollection:(NSString *)collection;

/**
 Returns the full path to write an event to.
 @param collection The collection name.
 @param timestamp  The timestamp of the event.
 @returns An NSString* that is a path to the event to be written.
 */
- (NSString *)pathForEventInCollection:(NSString *)collection
                         WithTimestamp:(NSDate *)timestamp;

- (void)sendEvents:(NSData *)data completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;

- (void)handleAPIResponse:(NSURLResponse *)response
                  andData:(NSData *)responseData
                forEvents:(NSDictionary *)eventIds
                onSuccess:(void (^)())onSuccess
                  onError:(void (^)(NSString*, NSString*))onError;

/**
 Converts an NSDate* instance into a correctly formatted ISO-8601 compatible string.
 @param date The NSData* instance to convert.
 @returns An ISO-8601 compatible string representation of the date parameter.
 */
- (id)convertDate:(id)date;

/**
 Fills the error object with the given message appropriately.
 
 @return Always return NO.
 */
- (BOOL)handleError:(NSError **)error withErrorMessage:(NSString *)errorMessage;
@end

@implementation KeenClient

@synthesize projectId=_projectId;
@synthesize writeKey=_writeKey;
@synthesize readKey=_readKey;
@synthesize locationManager=_locationManager;
@synthesize currentLocation=_currentLocation;
@synthesize numTimesTimestampUsed=_numTimesTimestampUsed;
@synthesize isRunningTests=_isRunningTests;
@synthesize globalPropertiesDictionary=_globalPropertiesDictionary;
@synthesize globalPropertiesBlock=_globalPropertiesBlock;
@synthesize uploadQueue;

# pragma mark - Class lifecycle

+ (void)initialize {
    // initialize the cached client exactly once.
    
    if (self != [KeenClient class]) {
        /*
         Without this extra check, your initializations could run twice if you ever have a subclass that
         doesn't implement its own +initialize method. This is not just a theoretical concern, even if
         you don't write any subclasses. Apple's Key-Value Observing creates dynamic subclasses which
         don't override +initialize.
         */
        return;
    }

    [KeenClient disableLogging];
}

+ (void)disableLogging {
    loggingEnabled = NO;
}

+ (void)enableLogging {
    loggingEnabled = YES;
}

+ (Boolean)isLoggingEnabled {
    return loggingEnabled;
}

+ (void)clearAllEvents {
    [eventStore deleteAllEvents];
}

+ (KIOEventStore *) getEventStore {
    return eventStore;
}

- (id)init {
    self = [super init];
    
    // log the current version number
    if ([KeenClient isLoggingEnabled]) {
        KCLog(@"KeenClientTD %@", kKeenSdkVersion);
    }
        
    self.uploadQueue = dispatch_queue_create("com.treasuredata.uploader", DISPATCH_QUEUE_SERIAL);

    return self;
}

+ (BOOL)validateProjectId:(NSString *)projectId {
    // validate that project ID is acceptable
    if (!projectId || [projectId length] == 0) {
        return NO;
    }
    return YES;
}

+ (BOOL)validateKey:(NSString *)key {
    // for now just use the same rules as project ID
    return [KeenClient validateProjectId:key];
}

- (id)initWithProjectId:(NSString *)projectId andWriteKey:(NSString *)writeKey andReadKey:(NSString *)readKey {
    if (![KeenClient validateProjectId:projectId]) {
        return nil;
    }
    
    if (!eventStore) {
        eventStore = [[KIOEventStore alloc] init];
    }
    
    self = [self init];
    if (self) {
        self.projectId = projectId;
        eventStore.projectId = projectId;
        if (writeKey) {
            if (![KeenClient validateKey:writeKey]) {
                return nil;
            }
            self.writeKey = writeKey;
        }
        if (readKey) {
            if (![KeenClient validateKey:readKey]) {
                return nil;
            }
            self.readKey = readKey;
        }
    }

    return self;
}

# pragma mark - Get a shared client

+ (KeenClient *)sharedClientWithProjectId:(NSString *)projectId andWriteKey:(NSString *)writeKey andReadKey:(NSString *)readKey {
    if (!sharedClient) {
        sharedClient = [[KeenClient alloc] init];
    }
    if (![KeenClient validateProjectId:projectId]) {
        return nil;
    }

    if (!eventStore) {
        eventStore = [[KIOEventStore alloc] init];
    }
    sharedClient.projectId = projectId;
    eventStore.projectId = projectId;

    if (writeKey) {
        // only validate a non-nil value
        if (![KeenClient validateKey:writeKey]) {
            return nil;
        }
    }
    sharedClient.writeKey = writeKey;
    
    if (readKey) {
        // only validate a non-nil value
        if (![KeenClient validateKey:readKey]) {
            return nil;
        }
    }
    sharedClient.readKey = readKey;
    
    return sharedClient;
}

+ (KeenClient *)sharedClient {
    if (!sharedClient) {
        sharedClient = [[KeenClient alloc] init];
    }
    if (![KeenClient validateProjectId:sharedClient.projectId]) {
        KCLog(@"sharedClient requested before registering project ID!");
        return nil;
    }
    return sharedClient;
}

# pragma mark - Add events

- (Boolean)validateEventCollection:(NSString *)eventCollection error:(NSError **) anError {
    NSString *errorMessage = nil;
    
    if ([eventCollection rangeOfString:@"$"].location == 0) {
        errorMessage = @"An event collection name cannot start with the dollar sign ($) character.";
        return [self handleError:anError withErrorMessage:errorMessage];
    }
    if ([eventCollection length] > 64) {
        errorMessage = @"An event collection name cannot be longer than 64 characters.";
        return [self handleError:anError withErrorMessage:errorMessage];
    }
    return YES;
}

- (Boolean)validateEvent:(NSDictionary *)event withDepth:(NSUInteger)depth error:(NSError **) anError {
    NSString *errorMessage = nil;
    
    if (depth == 0) {
        if (!event || [event count] == 0) {
            errorMessage = @"You must specify a non-null, non-empty event.";
            return [self handleError:anError withErrorMessage:errorMessage];
        }
        id keenObject = [event objectForKey:@"keen"];
        if (keenObject != nil && ![keenObject isKindOfClass:[NSDictionary class]]) {
            errorMessage = @"An event's root-level property named 'keen' must be a dictionary.";
            return [self handleError:anError withErrorMessage:errorMessage];
        }
    }
    
    for (NSString *key in event) {
        // validate keys
        if ([key rangeOfString:@"."].location != NSNotFound) {
            errorMessage = @"An event cannot contain a property with the period (.) character in it.";
            return [self handleError:anError withErrorMessage:errorMessage];
        }
        if ([key rangeOfString:@"$"].location == 0) {
            errorMessage = @"An event cannot contain a property that starts with the dollar sign ($) character in it.";
            return [self handleError:anError withErrorMessage:errorMessage];
        }
        if ([key length] > 256) {
            errorMessage = @"An event cannot contain a property longer than 256 characters.";
            return [self handleError:anError withErrorMessage:errorMessage];
        }
        
        // now validate values
        id value = [event objectForKey:key];
        if ([value isKindOfClass:[NSString class]]) {
            // strings can't be longer than 10k
            if ([value length] > 10000) {
                errorMessage = @"An event cannot contain a property value longer than 10,000 characters.";
                return [self handleError:anError withErrorMessage:errorMessage];
            }
        } else if ([value isKindOfClass:[NSDictionary class]]) {
            if (![self validateEvent:value withDepth:depth+1 error:anError]) {
                return NO;
            }
        }
    }
    return YES;
}

- (BOOL)addEvent:(NSDictionary *)event toEventCollection:(NSString *)eventCollection error:(NSError **) anError {
    return [self addEvent:event withKeenProperties:nil toEventCollection:eventCollection error:anError];
}

- (BOOL)addEvent:(NSDictionary *)event withKeenProperties:(KeenProperties *)keenProperties toEventCollection:(NSString *)eventCollection error:(NSError **) anError {
    return [self addEvent:event withKeenProperties:nil toEventCollection:eventCollection error:anError onSuccess:nil onError:nil];
}

- (BOOL)addEvent:(NSDictionary *)event withKeenProperties:(KeenProperties *)keenProperties toEventCollection:(NSString *)eventCollection error:(NSError **) anError
       onSuccess:(void(^)())onSuccess
         onError:(void (^)(NSString* errorCode, NSString* message))onError {
    // make sure the write key has been set - can't do anything without that
    if (![KeenClient validateKey:self.writeKey]) {
        [NSException raise:@"KeenNoWriteKeyProvided" format:@"You tried to add an event without setting a write key, please set one!"];
    }

    // don't do anything if the event itself or the event collection name are invalid somehow.
    if (![self validateEventCollection:eventCollection error:anError]) {
        if (onError) {
            onError(ERROR_CODE_INVALID_EVENT, [*anError description]);
        }
        return NO;
    }
    if (![self validateEvent:event withDepth:0 error:anError]) {
        if (onError) {
            onError(ERROR_CODE_INVALID_EVENT, [*anError description]);
        }
        return NO;
    }
    
    KCLog(@"Adding event to collection: %@", eventCollection);
    
    // create the body of the event we'll send off. first copy over all keys from the global properties
    // dictionary, then copy over all the keys from the global properties block, then copy over all the
    // keys from the user-defined event.
    NSMutableDictionary *newEvent = [NSMutableDictionary dictionary];
    if (self.globalPropertiesDictionary) {
        [newEvent addEntriesFromDictionary:self.globalPropertiesDictionary];
    }
    if (self.globalPropertiesBlock) {
        NSDictionary *globalProperties = self.globalPropertiesBlock(eventCollection);
        if (globalProperties) {
            [newEvent addEntriesFromDictionary:globalProperties];
        }
    }
    [newEvent addEntriesFromDictionary:event];
    event = newEvent;
    // now make sure that we haven't hit the max number of events in this collection already
    NSUInteger eventCount = [eventStore getTotalEventCount];
    // We add 1 because we want to know if this will push us over the limit
    if (eventCount + 1 > self.maxEventsPerCollection) {
        // need to age out old data so the cache doesn't grow too large
        KCLog(@"Too many events in cache for %@, aging out old data.", eventCollection);
        KCLog(@"Count: %lu and Max: %lu", (unsigned long)eventCount, (unsigned long)self.maxEventsPerCollection);
        [eventStore deleteEventsFromOffset:[NSNumber numberWithUnsignedInteger: eventCount - self.numberEventsToForget]];
    }

    if (!keenProperties) {
        KeenProperties *newProperties = [[KeenProperties alloc] init];
        keenProperties = newProperties;
    }
    
    // this is the event we'll actually write
    NSMutableDictionary *eventToWrite = [NSMutableDictionary dictionaryWithDictionary:event];
    
    // either set "keen" only from keen properties or merge in
    NSDictionary *originalKeenDict = [eventToWrite objectForKey:@"keen"];
    if (originalKeenDict) {
        // have to merge
        NSMutableDictionary *keenDict = [self handleInvalidJSONInObject:keenProperties];
        [keenDict addEntriesFromDictionary:originalKeenDict];
        [eventToWrite setObject:keenDict forKey:@"keen"];
        
    } else {
        // just set it directly
        [eventToWrite setObject:keenProperties forKey:@"keen"];
    }
    
    NSError *error = nil;
    NSData *jsonData = [self serializeEventToJSON:eventToWrite error:&error];
    if (error) {
        if (onError) {
            onError(ERROR_CODE_DATA_CONVERSION, [*anError description]);
        }
        return [self handleError:anError
                withErrorMessage:[NSString stringWithFormat:@"An error occurred when serializing event to JSON: %@", [error localizedDescription]]
                underlayingError:error];
    }
    
    // write JSON to store
    eventStore.lastErrorMessage = nil;
    if (![eventStore addEvent:jsonData collection: eventCollection]) {
        if (onError) {
            onError(ERROR_CODE_STORAGE_ERROR, eventStore.lastErrorMessage);
        }
        return NO;
    }
    
    if (onSuccess) {
        onSuccess();
    }
    // log the event
    if ([KeenClient isLoggingEnabled]) {
        KCLog(@"Event: %@", eventToWrite);
    }

    return YES;
}

- (NSData *)serializeEventToJSON:(NSMutableDictionary *)event error:(NSError **) anError {
    id fixed = [self handleInvalidJSONInObject:event];
    
    if (![NSJSONSerialization isValidJSONObject:fixed]) {
        [self handleError:anError withErrorMessage:@"Event contains an invalid JSON type!"];
        return nil;
    }
    return [NSJSONSerialization dataWithJSONObject:fixed options:0 error:anError];
}

- (NSMutableDictionary *)makeDictionaryMutable:(NSDictionary *)dict {
    return [dict mutableCopy];
}

- (NSMutableArray *)makeArrayMutable:(NSArray *)array {
    return [array mutableCopy];
}

- (id)handleInvalidJSONInObject:(id)value {
    if (!value) {
        return value;
    }
    
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *mutDict = [self makeDictionaryMutable:value];
        NSArray *keys = [mutDict allKeys];
        for (NSString *dictKey in keys) {
            id newValue = [self handleInvalidJSONInObject:[mutDict objectForKey:dictKey]];
            [mutDict setObject:newValue forKey:dictKey];
        }
        return mutDict;
    } else if ([value isKindOfClass:[NSArray class]]) {
        // make sure the array is mutable and then recurse for every element
        NSMutableArray *mutArr = [self makeArrayMutable:value];
        for (NSUInteger i=0; i<[mutArr count]; i++) {
            id arrVal = [mutArr objectAtIndex:i];
            arrVal = [self handleInvalidJSONInObject:arrVal];
            [mutArr setObject:arrVal atIndexedSubscript:i];
        }
        return mutArr;
    } else if ([value isKindOfClass:[NSDate class]]) {
        return [self convertDate:value];
    } else if ([value isKindOfClass:[KeenProperties class]]) {
        KeenProperties *keenProperties = value;
        
        NSString *isoDate = [self convertDate:keenProperties.timestamp];
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithObject:isoDate forKey:@"timestamp"];
        
        CLLocation *location = keenProperties.location;
        if (location != nil) {
            NSNumber *longitude = [NSNumber numberWithDouble:location.coordinate.longitude];
            NSNumber *latitude = [NSNumber numberWithDouble:location.coordinate.latitude];
            NSArray *coordinatesArray = [NSArray arrayWithObjects:longitude, latitude, nil];
            NSDictionary *coordinatesDict = [NSDictionary dictionaryWithObject:coordinatesArray forKey:@"coordinates"];
            [dict setObject:coordinatesDict forKey:@"location"];
        }
        
        return dict;
    } else {
        return value;
    }
}

- (void)prepareJSONData:(NSData **)jsonData andEventIds:(NSMutableDictionary **)eventIds onError:(void (^)(NSString*, NSString*))onError {
    
    // set up the request dictionary we'll send out.
    NSMutableDictionary *requestDict = [NSMutableDictionary dictionary];
    
    // create a structure that will hold corresponding ids of all the events
    NSMutableDictionary *eventIdDict = [NSMutableDictionary dictionary];
    
    // get data for the API request we'll make
    NSMutableDictionary *events = [eventStore getEvents];
    
    NSError *error = nil;
    for (NSString *coll in events) {
        NSDictionary *collEvents = [events objectForKey:coll];
        
        // create a separate array for event data so our dictionary serializes properly
        NSMutableArray *eventsArray = [[NSMutableArray alloc] init];
        
        for (NSNumber *eid in collEvents) {
            NSData *ev = [collEvents objectForKey:eid];
            NSDictionary *eventDict = [NSJSONSerialization JSONObjectWithData:ev
                                                                      options:0
                                                                        error:&error];
            if (error) {
                KCLog(@"An error occurred when deserializing a saved event: %@", [error localizedDescription]);
                continue;
            }
            
            // add it to the array of events
            [eventsArray addObject:eventDict];
            if ([eventIdDict objectForKey:coll] == nil) {
                [eventIdDict setObject: [NSMutableArray array] forKey: coll];
            }
            [[eventIdDict objectForKey:coll] addObject: eid];
        }
        
        // add the array of events to the request
        [requestDict setObject:eventsArray forKey:coll];
    }
    
    if ([requestDict count] == 0) {
        KCLog(@"Request data is empty");
        return;
    }
    
    NSData *data = [NSJSONSerialization dataWithJSONObject:requestDict options:0 error:&error];
    if (error) {
        KCLog(@"An error occurred when serializing the final request data back to JSON: %@",
              [error localizedDescription]);
        // can't do much here.
        if (onError) {
            onError(ERROR_CODE_DATA_CONVERSION, [NSString stringWithFormat:@"An error occurred when serializing the final request data back to JSON: %@", [error localizedDescription]]);
        }
        return;
    }
    
    *jsonData = data;
    *eventIds = eventIdDict;
    
    if ([KeenClient isLoggingEnabled]) {
        KCLog(@"Uploading following events to Keen API: %@", requestDict);
    }
}

# pragma mark - Directory/path management

- (void)importFileData {
    // Save a flag that we've done the FS import so we don't waste
    // time on it in the future.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:true forKey:@"didFSImport"];
    [defaults synchronize];

    @try {
        // list all the directories under Keen
        NSArray *directories = [self keenSubDirectories];
        NSString *rootPath = [self keenDirectory];

        // Get a file manager so we can use it later
        NSFileManager *fileManager = [NSFileManager defaultManager];

        // We only need to do this import if the directory exists so check
        // that out first.
        if ([fileManager fileExistsAtPath:rootPath]) {
            // declare an error object
            NSError *error = nil;

            // iterate through each directory
            for (NSString *dirName in directories) {
                KCLog(@"Found directory: %@", dirName);
                // list contents of each directory
                NSString *dirPath = [rootPath stringByAppendingPathComponent:dirName];
                NSArray *files = [self contentsAtPath:dirPath];

                for (NSString *fileName in files) {
                    KCLog(@"Found file: %@/%@", dirName, fileName);
                    NSString *filePath = [dirPath stringByAppendingPathComponent:fileName];
                    // for each file, grab the JSON blob
                    NSData *data = [NSData dataWithContentsOfFile:filePath];
                    // deserialize it
                    error = nil;
                    if ([data length] > 0) {
                        // Attempt to deserialize this just to determine if it's valid
                        // or not. We don't actually care about the results.
                        [NSJSONSerialization JSONObjectWithData:data
                            options:0
                            error:&error];
                        if (error) {
                            // If we got an error we're not gonna add it
                            KCLog(@"An error occurred when deserializing a saved event: %@", [error localizedDescription]);
                        } else {
                            // All's well: Add it!
                            [eventStore addEvent:data collection:dirName];
                        }

                    }
                    // Regardless, delete it when we're done.
                    [fileManager removeItemAtPath:filePath error:nil];
                }
            }
            // Remove the keen directory at the end so we know not to do this again!
            [fileManager removeItemAtPath:rootPath error:nil];
        }
    }
    @catch (NSException *e) {
        KCLog(@"An error occurred when attempting to import events from the filesystem, will not run again: %@", e);
    }
}

- (NSString *)cacheDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    return documentsDirectory;
}

- (NSString *)keenDirectory {
    NSString *keenDirPath = [[self cacheDirectory] stringByAppendingPathComponent:@"keen"];
    return [keenDirPath stringByAppendingPathComponent:self.projectId];
}

- (NSArray *)keenSubDirectories {
    return [self contentsAtPath:[self keenDirectory]];
}

- (NSArray *)contentsAtPath:(NSString *) path {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *files = [fileManager contentsOfDirectoryAtPath:path error:&error];
    if (error) {
        KCLog(@"An error occurred when listing directory (%@) contents: %@", path, [error localizedDescription]);
        return nil;
    }
    return files;
}

- (NSString *)eventDirectoryForCollection:(NSString *)collection {
    return [[self keenDirectory] stringByAppendingPathComponent:collection];
}

- (NSString *)pathForEventInCollection:(NSString *)collection WithTimestamp:(NSDate *)timestamp {
    // get a file manager.
    NSFileManager *fileManager = [NSFileManager defaultManager];
    // determine the root of the filename.
    NSString *name = [NSString stringWithFormat:@"%f", [timestamp timeIntervalSince1970]];
    // get the path to the directory where the file will be written
    NSString *directory = [self eventDirectoryForCollection:collection];
    // start a counter that we'll use to make sure that even if multiple events are written with the same timestamp,
    // we'll be able to handle it.
    uint count = 0;

    // declare a tiny helper block to get the next path based on the counter.
    NSString * (^getNextPath)(uint count) = ^(uint count) {
        return [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%i", name, count]];
    };

    // starting with our root filename.0, see if a file exists.  if it doesn't, great.  but if it does, then go
    // on to filename.1, filename.2, etc.
    NSString *path = getNextPath(count);
    while ([fileManager fileExistsAtPath:path]) {
        count++;
        path = getNextPath(count);
    }

    return path;
}

# pragma mark - Uploading

- (void)uploadHelper:(void (^)())onSuccess onError:(void (^)(NSString*, NSString*))onError
{
    // only one thread should be doing an upload at a time.
    @synchronized(self) {

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

        // Check if we've done an import before. (A missing value returns NO)
        if (![defaults boolForKey:@"didFSImport"]) {
            // Slurp in any filesystem based events. This converts older fs-based
            // event storage into newer SQL-lite based storage.
            [self importFileData];
        }

        NSData *data = nil;
        NSMutableDictionary *eventIds = nil;
        [self prepareJSONData:&data andEventIds:&eventIds onError:onError];
        // get data for the API request we'll make

        if ([data length] > 0) {
            // then make an http request to the keen server.
            [self sendEvents:data completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                // then parse the http response and deal with it appropriately
                [self handleAPIResponse:response andData:data forEvents:eventIds onSuccess:onSuccess onError:onError];
            }];
        }
        else {
            // Callback may be needed even when bufferred data is empty to use the callback as a trigger of something in an application
            if (onSuccess) {
                onSuccess();
            }
        }
    }
}

- (void)handleAPIResponse:(NSURLResponse *)response 
                  andData:(NSData *)responseData
                forEvents:(NSDictionary *)eventIds
                onSuccess:(void (^)())onSuccess
                  onError:(void (^)(NSString*, NSString*))onError {
    if (!responseData) {
        KCLog(@"responseData was nil for some reason.  That's not great.");
        KCLog(@"response status code: %ld", (long)[((NSHTTPURLResponse *) response) statusCode]);
        
        NSInteger responseCode = [((NSHTTPURLResponse *)response) statusCode];
        if (onError) {
            onError(responseCode == 0 ? ERROR_CODE_NETWORK_ERROR : ERROR_CODE_SERVER_RESPONSE,
                    [NSString stringWithFormat:@"response status code: %ld", (long)[((NSHTTPURLResponse *) response) statusCode]]);
        }
        return;
    }
    NSInteger responseCode = [((NSHTTPURLResponse *)response) statusCode];
    // if the request succeeded, dig into the response to figure out which events succeeded and which failed
    if (responseCode == 200) {
        // deserialize the response
        NSError *error = nil;
        NSDictionary *responseDict = [NSJSONSerialization JSONObjectWithData:responseData
                                                                     options:0
                                                                       error:&error];
        if (error) {
            NSString *responseString = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
            KCLog(@"An error occurred when deserializing HTTP response JSON into dictionary.\nError: %@\nResponse: %@", [error localizedDescription], responseString);
            if (onError) {
                onError(ERROR_CODE_DATA_CONVERSION,
                        [NSString stringWithFormat:@"An error occurred when deserializing HTTP response JSON into dictionary.\nError: %@\nResponse: %@",
                            [error localizedDescription], responseString]);
            }
            return;
        }
        // now iterate through the keys of the response, which represent collection names
        NSArray *collectionNames = [responseDict allKeys];
        for (NSString *collectionName in collectionNames) {
            // grab the results for this collection
            NSArray *results = [responseDict objectForKey:collectionName];
            // go through and delete any successes and failures because of user error
            // (making sure to keep any failures due to server error)
            NSUInteger count = 0;
            for (NSDictionary *result in results) {
                Boolean deleteFile = YES;
                Boolean success = [[result objectForKey:kKeenSuccessParam] boolValue];
                if (!success) {
                    // grab error code and description
                    NSDictionary *errorDict = [result objectForKey:kKeenErrorParam];
                    NSString *errorCode = [errorDict objectForKey:kKeenNameParam];
                    if ([errorCode isEqualToString:kKeenInvalidCollectionNameError] ||
                        [errorCode isEqualToString:kKeenInvalidPropertyNameError] ||
                        [errorCode isEqualToString:kKeenInvalidPropertyValueError]) {
                        KCLog(@"An invalid event was found.  Deleting it.  Error: %@", 
                              [errorDict objectForKey:kKeenDescriptionParam]);
                        deleteFile = YES;
                    } else {
                        KCLog(@"The event could not be inserted for some reason.  Error name and description: %@, %@", 
                              errorCode, [errorDict objectForKey:kKeenDescriptionParam]);
                        deleteFile = NO;
                    }
                }
                // delete the file if we need to
                if (deleteFile) {
                    NSNumber *eid = [[eventIds objectForKey:collectionName] objectAtIndex:count];
                    [eventStore deleteEvent: eid];
                    KCLog(@"Successfully deleted event: %@", eid);
                }
                count++;
            }
        }
        if (onSuccess) {
            onSuccess();
        }
    } else {
        // response code was NOT 200, which means something else happened. log this.
        KCLog(@"Response code was NOT 200. It was: %ld", (long)responseCode);
        NSString *responseString = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
        KCLog(@"Response body was: %@", responseString);
        if (onError) {
            onError(responseCode == 0 ? ERROR_CODE_NETWORK_ERROR : ERROR_CODE_SERVER_RESPONSE,
                    [NSString stringWithFormat:@"Response code was NOT 200. It was: %ld", (long)responseCode]);
        }
    }
}

# pragma mark - HTTP request/response management

- (void)sendEvents:(NSData *)data completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
  // Should be overrided by TDClient
}

- (BOOL)handleError:(NSError **)error withErrorMessage:(NSString *)errorMessage {
    return [self handleError:error withErrorMessage:errorMessage underlayingError:nil];
}

- (BOOL)handleError:(NSError **)error withErrorMessage:(NSString *)errorMessage underlayingError:(NSError *)underlayingError {
    if (error != NULL) {
        const id<NSCopying> keys[] = {NSLocalizedDescriptionKey, NSUnderlyingErrorKey};
        const id objects[] = {errorMessage, underlayingError};
        NSUInteger count = underlayingError ? 2 : 1;
        NSDictionary *userInfo = [NSDictionary dictionaryWithObjects:objects forKeys:keys count:count];
        *error = [NSError errorWithDomain:kKeenErrorDomain code:1 userInfo:userInfo];
        KCLog(@"%@", *error);
    }

    return NO;
}

# pragma mark - NSDate => NSString

- (id)convertDate:(id)date {
    NSString *string = [eventStore convertNSDateToISO8601:date];
    return string;
}

- (id)handleUnsupportedJSONValue:(id)value {
    if ([value isKindOfClass:[NSDate class]]) {
        return [self convertDate:value];
    } else if ([value isKindOfClass:[KeenProperties class]]) {
        KeenProperties *keenProperties = (KeenProperties *)value;
        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithObject:keenProperties.timestamp forKey:@"timestamp"];
        CLLocation *location = keenProperties.location;
        if (location != nil) {
            NSNumber *longitude = [NSNumber numberWithDouble:location.coordinate.longitude];
            NSNumber *latitude = [NSNumber numberWithDouble:location.coordinate.latitude];
            NSArray *coordinatesArray = [NSArray arrayWithObjects:longitude, latitude, nil];
            NSDictionary *coordinatesDict = [NSDictionary dictionaryWithObject:coordinatesArray forKey:@"coordinates"];
            [dict setObject:coordinatesDict forKey:@"location"];
        }
        return dict;
    }
    return NULL;
}

# pragma mark - SDK

+ (NSString *)sdkVersion {
    return kKeenSdkVersion;
}

# pragma mark - To make testing easier

- (NSUInteger)maxEventsPerCollection {
    if (self.isRunningTests) {
        return 5;
    }
    return kKeenMaxEventsPerCollection;
}

- (NSUInteger)numberEventsToForget {
    if (self.isRunningTests) {
        return 2;
    }
    return kKeenNumberEventsToForget;
}

# pragma mark - Extending KeenClient library
- (void)uploadWithFinishedBlock:(void (^)()) block {
    dispatch_async(self.uploadQueue, ^{
        [self uploadHelper:block onError:^(NSString* errorCode, NSString* message) {
            block();
        }];
    });
}

- (void)uploadWithCallbacks:(void(^)())onSuccess onError:(void (^)(NSString* errorCode, NSString* message))onError {
    dispatch_async(self.uploadQueue, ^{
        [self uploadHelper:onSuccess onError:onError];
    });
}

- (void)addEventWithCallbacks:(NSDictionary *)event
            toEventCollection:(NSString *)eventCollection
                    onSuccess:(void(^)())onSuccess
                      onError:(void (^)(NSString* errorCode, NSString* message))onError {
    if (!onSuccess)
        onSuccess = ^(){};
    
    if (!onError)
        onError = ^(NSString* errorCode, NSString* message){};

    NSError *error = nil;

    [self addEvent:event withKeenProperties:nil toEventCollection:eventCollection error:&error onSuccess:onSuccess onError:onError];
}

+ (void)initializeEncryptionKey:(NSString*)encryptionKey {
    [KIOEventStore initializeEncryptionKey:encryptionKey];
}

@end
