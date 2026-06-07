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

// ─── Find the REAL class name (Objective-C runtime uses Swift module prefix) ───
static NSArray *FindRealmCoinClasses(void) {
    NSMutableArray *found = [NSMutableArray array];
    unsigned int count = 0;
    Class *all = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(all[i]);
        // Match Realm model classes from winwalk — they all have "winwalk.Realm" prefix
        if ([name hasPrefix:@"winwalk.Realm"]) {
            [found addObject:name];
        }
    }
    free(all);
    return found;
}

// ─── Dump all properties of a Realm object to find coin-related keys ───
static NSArray *FindCoinPropertyNames(Class cls) {
    NSMutableArray *keys = [NSMutableArray array];
    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        NSString *pname = [NSString stringWithUTF8String:property_getName(props[i])];
        NSString *lower = pname.lowercaseString;
        if ([lower containsString:@"coin"] || [lower containsString:@"step"] || 
            [lower containsString:@"balance"] || [lower containsString:@"reward"]) {
            [keys addObject:pname];
        }
    }
    free(props);
    return keys;
}

static void PatchRealmDB(void) {
    WriteDiagnostic(@"─── Realm DB Patch Cycle ───");
    
    // Step 1: Find all Realm classes
    NSArray *realmClasses = FindRealmCoinClasses();
    WriteDiagnostic([NSString stringWithFormat:@"Found %lu Realm classes: %@", 
                     (unsigned long)realmClasses.count, realmClasses]);
    
    // Step 2: Get default Realm
    Class realmClass = NSClassFromString(@"RLMRealm");
    if (!realmClass) {
        WriteDiagnostic(@"FATAL: RLMRealm not found — Realm framework may not be loaded yet");
        return;
    }
    
    id realm = ((id (*)(Class, SEL))objc_msgSend)(realmClass, sel_getUid("defaultRealm"));
    if (!realm) {
        if (!realm) {
            WriteDiagnostic(@"FATAL: Cannot obtain Realm instance — DB not initialized yet");
            return;
        }
    }
    WriteDiagnostic(@"Realm instance obtained ✓");
    
    // Step 3: Begin write transaction
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("beginWriteTransaction"));
    
    int totalPatched = 0;
    
    for (NSString *className in realmClasses) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        
        // Find coin-related properties on this class
        NSArray *coinProps = FindCoinPropertyNames(cls);
        if (coinProps.count == 0) {
            WriteDiagnostic([NSString stringWithFormat:@"  %@ — no coin properties", className]);
            continue;
        }
        
        WriteDiagnostic([NSString stringWithFormat:@"  %@ coin props: %@", className, coinProps]);
        
        // Get all objects of this class
        id results = ((id (*)(Class, SEL, id))objc_msgSend)(cls, sel_getUid("allObjectsInRealm:"), realm);
        if (!results) continue;
        
        id enumerator = ((id (*)(id, SEL))objc_msgSend)(results, sel_getUid("objectEnumerator"));
        if (!enumerator) continue;
        
        int objCount = 0;
        id obj;
        while ((obj = ((id (*)(id, SEL))objc_msgSend)(enumerator, sel_getUid("nextObject")))) {
            for (NSString *key in coinProps) {
                NSNumber *val = nil;
                if ([key.lowercaseString containsString:@"step"]) {
                    val = @99999900;
                } else {
                    val = @(kInjectedCoins);
                }
                @try {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), val, key);
                } @catch (id e) {
                    WriteDiagnostic([NSString stringWithFormat:@"    ERROR setting %@.%@ = %@", className, key, e]);
                }
            }
            objCount++;
        }
        totalPatched += objCount;
        WriteDiagnostic([NSString stringWithFormat:@"  %@: patched %d objects", className, objCount]);
    }
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
    WriteDiagnostic([NSString stringWithFormat:@"TOTAL: %d objects patched across %lu classes", 
                     totalPatched, (unsigned long)realmClasses.count]);
}

__attribute__((constructor))
static void WinwalkHackInit(void) {
    WriteDiagnostic(@"========== WINWALK HACK V4 — REALM DB PATCHER ==========");
    WriteDiagnostic([NSString stringWithFormat:@"Target coins: %ld steps: 99999900", (long)kInjectedCoins]);
    
    // Run Realm patch on a delay to ensure DB is initialized
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        PatchRealmDB();
        // Then run every 10 seconds
        [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t) {
            PatchRealmDB();
        }];
    });
    
    WriteDiagnostic(@"Init complete — Realm patcher scheduled at T+5s");
}
