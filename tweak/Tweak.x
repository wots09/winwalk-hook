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
    
    id schema = ((id (*)(id, SEL))objc_msgSend)(realm, sel_getUid("schema"));
    if (!schema) { WriteDiagnostic(@"schema=nil"); return; }
    
    id objectSchemas = ((id (*)(id, SEL))objc_msgSend)(schema, sel_getUid("objectSchema"));
    if (!objectSchemas) { WriteDiagnostic(@"objectSchema=nil"); return; }
    
    unsigned long schemaCount = ((unsigned long (*)(id, SEL))objc_msgSend)(objectSchemas, sel_getUid("count"));
    WriteDiagnostic([NSString stringWithFormat:@"Schema: %lu types", schemaCount]);
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("beginWriteTransaction"));
    
    int totalObjects = 0;
    int totalSets = 0;
    
    // Iterate schema using count + objectAtIndex (RLMResults-style)
    for (unsigned long i = 0; i < schemaCount; i++) {
        id schemaObj = ((id (*)(id, SEL, unsigned long))objc_msgSend)(objectSchemas, sel_getUid("objectAtIndex:"), i);
        if (!schemaObj) continue;
        
        NSString *className = ((id (*)(id, SEL))objc_msgSend)(schemaObj, sel_getUid("className"));
        if (!className || !([className hasPrefix:@"winwalk."] || [className hasPrefix:@"Realm"])) continue;
        
        // Discover coin/step keys from schema properties
        id properties = ((id (*)(id, SEL))objc_msgSend)(schemaObj, sel_getUid("properties"));
        if (!properties) continue;
        
        unsigned long propCount = ((unsigned long (*)(id, SEL))objc_msgSend)(properties, sel_getUid("count"));
        NSMutableArray *validKeys = [NSMutableArray array];
        
        for (unsigned long j = 0; j < propCount; j++) {
            id prop = ((id (*)(id, SEL, unsigned long))objc_msgSend)(properties, sel_getUid("objectAtIndex:"), j);
            NSString *propName = ((id (*)(id, SEL))objc_msgSend)(prop, sel_getUid("name"));
            NSString *lower = propName.lowercaseString;
            if ([lower containsString:@"coin"] || [lower containsString:@"step"] ||
                [lower containsString:@"balance"] || [lower containsString:@"reward"] ||
                [lower containsString:@"distance"] || [lower containsString:@"calories"]) {
                [validKeys addObject:propName];
            }
        }
        
        if (validKeys.count == 0) {
            WriteDiagnostic([NSString stringWithFormat:@"  %@ — no coin props", className]);
            continue;
        }
        
        // Query all objects: [realm allObjects] not available, use objects:where: with nil predicate
        id results = ((id (*)(id, SEL, NSString*, NSString*))objc_msgSend)(
            realm, sel_getUid("objects:where:"), className, nil);
        if (!results) continue;
        
        // Iterate RLMResults using count + objectAtIndex
        unsigned long objCount = ((unsigned long (*)(id, SEL))objc_msgSend)(results, sel_getUid("count"));
        if (objCount == 0) {
            WriteDiagnostic([NSString stringWithFormat:@"  %@ — 0 objects", className]);
            continue;
        }
        
        int sets = 0;
        for (unsigned long k = 0; k < objCount; k++) {
            id obj = ((id (*)(id, SEL, unsigned long))objc_msgSend)(results, sel_getUid("objectAtIndex:"), k);
            if (!obj) continue;
            
            for (NSString *key in validKeys) {
                NSNumber *val = @(kInjectedCoins);
                if ([key.lowercaseString containsString:@"step"]) val = @99999900;
                @try {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), val, key);
                    sets++;
                } @catch (id e) {}
            }
        }
        
        totalObjects += (int)objCount;
        totalSets += sets;
        WriteDiagnostic([NSString stringWithFormat:@"  %@: %lu objs, %d sets, keys=%@",
                         className, objCount, sets, validKeys]);
    }
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
    WriteDiagnostic([NSString stringWithFormat:@"TOTAL: %d objects, %d values written", totalObjects, totalSets]);
}

__attribute__((constructor))
static void WinwalkHackInit(void) {
    WriteDiagnostic(@"========== V7 — index-based iteration ==========");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        PatchRealmDB();
        [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t) {
            PatchRealmDB();
        }];
    });
}
