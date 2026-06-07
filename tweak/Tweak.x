#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ─── Configurable values ───
static const NSInteger kInjectedCoins       = 999999;   // currentCoins + coins
static const NSInteger kInjectedSteps       = 100000;   // step count (100k → 1000 redeemable)
static const NSInteger kInjectedCalories    = 500;      // reasonable kcal
static const double   kInjectedDistance     = 80.0;     // km
static const NSInteger kInjectedActiveTime  = 7200;     // seconds (2 hours)

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
    Class realmClass = NSClassFromString(@"RLMRealm");
    if (!realmClass) return;
    
    id realm = ((id (*)(Class, SEL))objc_msgSend)(realmClass, sel_getUid("defaultRealm"));
    if (!realm) return;
    
    id schema = ((id (*)(id, SEL))objc_msgSend)(realm, sel_getUid("schema"));
    id objectSchemas = ((id (*)(id, SEL))objc_msgSend)(schema, sel_getUid("objectSchema"));
    unsigned long schemaCount = ((unsigned long (*)(id, SEL))objc_msgSend)(objectSchemas, sel_getUid("count"));
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("beginWriteTransaction"));
    
    int totalSets = 0;
    
    for (unsigned long i = 0; i < schemaCount; i++) {
        id schemaObj = ((id (*)(id, SEL, unsigned long))objc_msgSend)(objectSchemas, sel_getUid("objectAtIndex:"), i);
        NSString *className = ((id (*)(id, SEL))objc_msgSend)(schemaObj, sel_getUid("className"));
        if (!className || !([className hasPrefix:@"winwalk."] || [className hasPrefix:@"Realm"])) continue;
        
        id properties = ((id (*)(id, SEL))objc_msgSend)(schemaObj, sel_getUid("properties"));
        unsigned long propCount = ((unsigned long (*)(id, SEL))objc_msgSend)(properties, sel_getUid("count"));
        
        // Map property names to values
        NSMutableDictionary *keyValues = [NSMutableDictionary dictionary];
        for (unsigned long j = 0; j < propCount; j++) {
            id prop = ((id (*)(id, SEL, unsigned long))objc_msgSend)(properties, sel_getUid("objectAtIndex:"), j);
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(prop, sel_getUid("name"));
            NSString *lower = name.lowercaseString;
            
            if ([lower containsString:@"currentcoins"] || [lower isEqualToString:@"coins"] || [lower hasSuffix:@"coins"])
                keyValues[name] = @(kInjectedCoins);
            else if ([lower isEqualToString:@"step"])
                keyValues[name] = @(kInjectedSteps);
            else if ([lower isEqualToString:@"distance"])
                keyValues[name] = @(kInjectedDistance);
            else if ([lower isEqualToString:@"calories"])
                keyValues[name] = @(kInjectedCalories);
            else if ([lower isEqualToString:@"activetime"])
                keyValues[name] = @(kInjectedActiveTime);
        }
        
        if (keyValues.count == 0) continue;
        
        id results = ((id (*)(id, SEL, NSString*, NSString*))objc_msgSend)(realm, sel_getUid("objects:where:"), className, nil);
        unsigned long objCount = ((unsigned long (*)(id, SEL))objc_msgSend)(results, sel_getUid("count"));
        
        int sets = 0;
        for (unsigned long k = 0; k < objCount; k++) {
            id obj = ((id (*)(id, SEL, unsigned long))objc_msgSend)(results, sel_getUid("objectAtIndex:"), k);
            for (NSString *key in keyValues) {
                @try {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), keyValues[key], key);
                    sets++;
                } @catch (id e) {}
            }
        }
        totalSets += sets;
    }
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
    WriteDiagnostic([NSString stringWithFormat:@"Cycle: %d values written", totalSets]);
}

__attribute__((constructor))
static void Init(void) {
    WriteDiagnostic(@"========== V8 — CALIBRATED VALUES ==========");
    WriteDiagnostic([NSString stringWithFormat:@"Coins=%ld Steps=%ld kcal=%ld dist=%.0fkm",
                     (long)kInjectedCoins, (long)kInjectedSteps, (long)kInjectedCalories, kInjectedDistance]);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        PatchRealmDB();
        [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t) {
            PatchRealmDB();
        }];
    });
}
