#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const NSInteger kInjectedCoins = 999999;
static const NSInteger kInjectedSteps = 100000;

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

// ─────────────────────────────────────────────────
// PART 1: Hook NSUserDefaults — return 999999 for coin keys
// ─────────────────────────────────────────────────

static id (*orig_objectForKey)(id, SEL, NSString*);
static NSInteger (*orig_integerForKey)(id, SEL, NSString*);
static double (*orig_doubleForKey)(id, SEL, NSString*);

static id hooked_objectForKey(id self, SEL _cmd, NSString *key) {
    NSString *lower = key.lowercaseString;
    if ([lower containsString:@"coin"] || [lower containsString:@"balance"]) {
        return @(kInjectedCoins);
    }
    if ([lower containsString:@"step"] && ![lower containsString:@"stepgoal"] && ![lower containsString:@"stepcountgoal"]) {
        return @(kInjectedSteps);
    }
    return orig_objectForKey(self, _cmd, key);
}

static NSInteger hooked_integerForKey(id self, SEL _cmd, NSString *key) {
    NSString *lower = key.lowercaseString;
    if ([lower containsString:@"coin"] || [lower containsString:@"balance"]) return kInjectedCoins;
    if ([lower containsString:@"step"]) return kInjectedSteps;
    return orig_integerForKey(self, _cmd, key);
}

static double hooked_doubleForKey(id self, SEL _cmd, NSString *key) {
    NSString *lower = key.lowercaseString;
    if ([lower containsString:@"coin"] || [lower containsString:@"balance"]) return (double)kInjectedCoins;
    return orig_doubleForKey(self, _cmd, key);
}

// ─────────────────────────────────────────────────
// PART 2: Realm DB patcher (keep from V8)
// ─────────────────────────────────────────────────

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
                keyValues[name] = @80.0;
            else if ([lower isEqualToString:@"calories"])
                keyValues[name] = @500;
            else if ([lower isEqualToString:@"activetime"])
                keyValues[name] = @7200;
        }
        
        if (keyValues.count == 0) continue;
        
        id results = ((id (*)(id, SEL, NSString*, NSString*))objc_msgSend)(realm, sel_getUid("objects:where:"), className, nil);
        unsigned long objCount = ((unsigned long (*)(id, SEL))objc_msgSend)(results, sel_getUid("count"));
        
        for (unsigned long k = 0; k < objCount; k++) {
            id obj = ((id (*)(id, SEL, unsigned long))objc_msgSend)(results, sel_getUid("objectAtIndex:"), k);
            for (NSString *key in keyValues) {
                @try {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), keyValues[key], key);
                    totalSets++;
                } @catch (id e) {}
            }
        }
    }
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
}

// ─────────────────────────────────────────────────
// PART 3: Dump UserDefaults keys (diagnostic)
// ─────────────────────────────────────────────────

static void DumpUserDefaults(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *all = [ud dictionaryRepresentation];
    NSMutableString *coinKeys = [NSMutableString string];
    for (NSString *key in all) {
        NSString *lower = key.lowercaseString;
        if ([lower containsString:@"coin"] || [lower containsString:@"balance"] || 
            [lower containsString:@"reward"] || [lower containsString:@"step"]) {
            [coinKeys appendFormat:@"  %@ = %@\n", key, all[key]];
        }
    }
    WriteDiagnostic([NSString stringWithFormat:@"UserDefaults coin keys:\n%@", coinKeys.length ? coinKeys : @"  (none found)"]);
}

// ─────────────────────────────────────────────────
// Constructor
// ─────────────────────────────────────────────────

__attribute__((constructor))
static void Init(void) {
    WriteDiagnostic(@"========== V9 — USERDEFAULTS HOOK ==========");
    
    // Swizzle NSUserDefaults
    Method m1 = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
    if (m1) {
        orig_objectForKey = (void*)method_getImplementation(m1);
        method_setImplementation(m1, (IMP)hooked_objectForKey);
        WriteDiagnostic(@"✓ objectForKey: swizzled");
    }
    
    Method m2 = class_getInstanceMethod([NSUserDefaults class], @selector(integerForKey:));
    if (m2) {
        orig_integerForKey = (void*)method_getImplementation(m2);
        method_setImplementation(m2, (IMP)hooked_integerForKey);
        WriteDiagnostic(@"✓ integerForKey: swizzled");
    }
    
    Method m3 = class_getInstanceMethod([NSUserDefaults class], @selector(doubleForKey:));
    if (m3) {
        orig_doubleForKey = (void*)method_getImplementation(m3);
        method_setImplementation(m3, (IMP)hooked_doubleForKey);
        WriteDiagnostic(@"✓ doubleForKey: swizzled");
    }
    
    // Dump UserDefaults after a delay (app has initialized by then)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        DumpUserDefaults();
        PatchRealmDB();
        [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t) {
            PatchRealmDB();
        }];
    });
}
