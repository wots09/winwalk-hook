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

// ─── Hook NSUserDefaults getters (display layer) ───
static id (*orig_objectForKey)(id, SEL, NSString*);
static NSInteger (*orig_integerForKey)(id, SEL, NSString*);
static NSDictionary* (*orig_dictionaryRepresentation)(id, SEL);

static id hooked_objectForKey(id self, SEL _cmd, NSString *key) {
    NSString *lower = key.lowercaseString;
    if ([lower containsString:@"coin"] || [lower containsString:@"balance"]) return @(kInjectedCoins);
    return orig_objectForKey(self, _cmd, key);
}

static NSInteger hooked_integerForKey(id self, SEL _cmd, NSString *key) {
    NSString *lower = key.lowercaseString;
    if ([lower containsString:@"coin"] || [lower containsString:@"balance"]) return kInjectedCoins;
    return orig_integerForKey(self, _cmd, key);
}

// Hook dictionaryRepresentation — inject fake coin values into the raw dict
static NSDictionary* hooked_dictionaryRepresentation(id self, SEL _cmd) {
    NSMutableDictionary *dict = [orig_dictionaryRepresentation(self, _cmd) mutableCopy];
    for (NSString *key in [dict allKeys]) {
        NSString *lower = key.lowercaseString;
        if ([lower containsString:@"coin"] || [lower containsString:@"balance"]) {
            dict[key] = @(kInjectedCoins);
        }
    }
    return [dict copy];
}

// ─── Directly write coin values to UserDefaults (overwrites real values) ───
static void ForceWriteUserDefaults(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    
    // Core coin balance keys (from V9 diagnostic)
    [ud setObject:@(kInjectedCoins) forKey:@"totalCoin"];
    [ud setInteger:kInjectedCoins forKey:@"totalCoin"];
    [ud setObject:@(kInjectedCoins) forKey:@"totalIncomeCoins"];
    [ud setObject:@(kInjectedCoins) forKey:@"weeklyLeagueCoins"];
    [ud setObject:@(kInjectedCoins) forKey:@"todayEarnedCoins"];
    [ud setObject:@(kInjectedCoins) forKey:@"bonusCoin"];
    [ud setObject:@(kInjectedCoins) forKey:@"incomeMissionCoins"];
    [ud setObject:@(kInjectedCoins) forKey:@"autoCollectionBonusCoins"];
    
    // Any key containing "coin" or "balance" in the current dictionary
    NSDictionary *all = [ud dictionaryRepresentation];
    for (NSString *key in all) {
        NSString *lower = key.lowercaseString;
        if (([lower containsString:@"coin"] || [lower containsString:@"balance"]) &&
            ![lower containsString:@"popup"] &&
            ![lower containsString:@"history"] &&
            ![lower containsString:@"first"] &&
            ![lower containsString:@"should"] &&
            ![lower containsString:@"enable"] &&
            ![lower containsString:@"capping"] &&
            ![lower containsString:@"pacing"] &&
            ![lower containsString:@"setting"] &&
            ![lower containsString:@"next"] &&
            ![lower containsString:@"mission"] &&
            ![lower containsString:@"reward"] &&
            ![lower containsString:@"video"]) {
            all = nil; // break reference
            [ud setObject:@(kInjectedCoins) forKey:key];
        }
    }
    [ud synchronize];
    WriteDiagnostic(@"UserDefaults: force-written coin keys to 999999");
}

// ─── Realm DB patcher (unchanged) ───
static void PatchRealmDB(void) {
    Class realmClass = NSClassFromString(@"RLMRealm");
    if (!realmClass) return;
    id realm = ((id (*)(Class, SEL))objc_msgSend)(realmClass, sel_getUid("defaultRealm"));
    if (!realm) return;
    id schema = ((id (*)(id, SEL))objc_msgSend)(realm, sel_getUid("schema"));
    id objectSchemas = ((id (*)(id, SEL))objc_msgSend)(schema, sel_getUid("objectSchema"));
    unsigned long schemaCount = ((unsigned long (*)(id, SEL))objc_msgSend)(objectSchemas, sel_getUid("count"));
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("beginWriteTransaction"));
    
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
                keyValues[name] = @100000;
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
                @try { ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), keyValues[key], key); }
                @catch (id e) {}
            }
        }
    }
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
}

// ─── Constructor ───
__attribute__((constructor))
static void Init(void) {
    WriteDiagnostic(@"========== V10 — FORCE WRITE + DICT HOOK ==========");
    
    // Swizzle NSUserDefaults
    Method m1 = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
    orig_objectForKey = (void*)method_getImplementation(m1);
    method_setImplementation(m1, (IMP)hooked_objectForKey);
    
    Method m2 = class_getInstanceMethod([NSUserDefaults class], @selector(integerForKey:));
    orig_integerForKey = (void*)method_getImplementation(m2);
    method_setImplementation(m2, (IMP)hooked_integerForKey);
    
    Method m3 = class_getInstanceMethod([NSUserDefaults class], @selector(dictionaryRepresentation));
    orig_dictionaryRepresentation = (void*)method_getImplementation(m3);
    method_setImplementation(m3, (IMP)hooked_dictionaryRepresentation);
    
    WriteDiagnostic(@"Swizzles installed ✓");
    
    // Delayed execution (app fully initialized)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        ForceWriteUserDefaults();
        PatchRealmDB();
        [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t) {
            ForceWriteUserDefaults();
            PatchRealmDB();
        }];
    });
}
