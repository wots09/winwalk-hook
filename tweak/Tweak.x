#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const NSInteger kInjectedCoins = 999999;

static void WriteDiagnostic(NSString *msg) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) docs = @"/tmp";
    NSString *path = [docs stringByAppendingPathComponent:@"winwalk_hack_log.txt"];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static void PatchRealmDB(void) {
    WriteDiagnostic(@"─── Cycle ───");
    
    Class realmClass = NSClassFromString(@"RLMRealm");
    if (!realmClass) { WriteDiagnostic(@"RLMRealm MISSING"); return; }
    
    id realm = ((id (*)(Class, SEL))objc_msgSend)(realmClass, sel_getUid("defaultRealm"));
    if (!realm) { WriteDiagnostic(@"defaultRealm=nil"); return; }
    
    // Get the schema to discover actual class names + property names
    id schema = ((id (*)(id, SEL))objc_msgSend)(realm, sel_getUid("schema"));
    if (!schema) { WriteDiagnostic(@"schema=nil"); return; }
    
    id objectSchemas = ((id (*)(id, SEL))objc_msgSend)(schema, sel_getUid("objectSchema"));
    if (!objectSchemas) { WriteDiagnostic(@"objectSchema=nil"); return; }
    
    unsigned long schemaCount = ((unsigned long (*)(id, SEL))objc_msgSend)(objectSchemas, sel_getUid("count"));
    WriteDiagnostic([NSString stringWithFormat:@"Schema: %lu object types", schemaCount]);
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("beginWriteTransaction"));
    
    int totalObjects = 0;
    int totalSets = 0;
    
    // Iterate schema objects
    id schemaEnumerator = ((id (*)(id, SEL))objc_msgSend)(objectSchemas, sel_getUid("objectEnumerator"));
    id schemaObj;
    while ((schemaObj = ((id (*)(id, SEL))objc_msgSend)(schemaEnumerator, sel_getUid("nextObject")))) {
        @try {
            // Get class name from schema
            NSString *className = ((id (*)(id, SEL))objc_msgSend)(schemaObj, sel_getUid("className"));
            if (!className) continue;
            
            // Only act on winwalk classes
            if (![className hasPrefix:@"winwalk."] && ![className hasPrefix:@"Realm"]) continue;
            
            // Get properties for this schema object
            id properties = ((id (*)(id, SEL))objc_msgSend)(schemaObj, sel_getUid("properties"));
            if (!properties) continue;
            
            // Discover which coin/step keys actually exist
            NSMutableArray *validKeys = [NSMutableArray array];
            id propEnumerator = ((id (*)(id, SEL))objc_msgSend)(properties, sel_getUid("objectEnumerator"));
            id prop;
            while ((prop = ((id (*)(id, SEL))objc_msgSend)(propEnumerator, sel_getUid("nextObject")))) {
                NSString *propName = ((id (*)(id, SEL))objc_msgSend)(prop, sel_getUid("name"));
                NSString *lower = propName.lowercaseString;
                if ([lower containsString:@"coin"] || [lower containsString:@"step"] ||
                    [lower containsString:@"balance"] || [lower containsString:@"reward"] ||
                    [lower containsString:@"distance"] || [lower containsString:@"calories"]) {
                    [validKeys addObject:propName];
                }
            }
            
            if (validKeys.count == 0) continue;
            
            // Query all objects of this type using RLMRealm's objects:where: API
            // [realm objects:@"ClassName" where:nil] — returns all objects
            id results = ((id (*)(id, SEL, NSString*, NSString*))objc_msgSend)(
                realm, sel_getUid("objects:where:"), className, nil);
            if (!results) continue;
            
            id objEnumerator = ((id (*)(id, SEL))objc_msgSend)(results, sel_getUid("objectEnumerator"));
            if (!objEnumerator) continue;
            
            int objCount = 0;
            int sets = 0;
            id obj;
            while ((obj = ((id (*)(id, SEL))objc_msgSend)(objEnumerator, sel_getUid("nextObject")))) {
                for (NSString *key in validKeys) {
                    NSNumber *val = @(kInjectedCoins);
                    if ([key.lowercaseString containsString:@"step"]) val = @99999900;
                    @try {
                        ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), val, key);
                        sets++;
                    } @catch (id e) {}
                }
                objCount++;
            }
            
            totalObjects += objCount;
            totalSets += sets;
            WriteDiagnostic([NSString stringWithFormat:@"  %@: %d objs, %d sets, keys=%@",
                             className, objCount, sets, validKeys]);
            
        } @catch (id e) {
            WriteDiagnostic([NSString stringWithFormat:@"  ERROR: %@", e]);
        }
    }
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
    WriteDiagnostic([NSString stringWithFormat:@"TOTAL: %d objects, %d values written", totalObjects, totalSets]);
}

__attribute__((constructor))
static void WinwalkHackInit(void) {
    WriteDiagnostic(@"========== V6 — SCHEMA-DRIVEN KVC ==========");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        PatchRealmDB();
        [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t) {
            PatchRealmDB();
        }];
    });
}
