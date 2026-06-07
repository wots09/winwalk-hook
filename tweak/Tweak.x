#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const NSInteger kInjectedCoins = 999999;
static BOOL sDidInit = NO;
static BOOL sRealmStarted = NO;

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
// UserDefaults hooks (SAFE — proven working)
// ─────────────────────────────────────────────────

static id (*orig_objectForKey)(id, SEL, NSString*);
static NSInteger (*orig_integerForKey)(id, SEL, NSString*);

static id hooked_objectForKey(id self, SEL _cmd, NSString *key) {
    NSString *lower = key.lowercaseString;
    if ([lower containsString:@"coin"] || [lower containsString:@"balance"])
        return @(kInjectedCoins);
    return orig_objectForKey(self, _cmd, key);
}

static NSInteger hooked_integerForKey(id self, SEL _cmd, NSString *key) {
    NSString *lower = key.lowercaseString;
    if ([lower containsString:@"coin"] || [lower containsString:@"balance"])
        return kInjectedCoins;
    return orig_integerForKey(self, _cmd, key);
}

static void ForceWriteUserDefaults(void) {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        for (NSString *key in @[@"totalCoin",@"totalIncomeCoins",@"weeklyLeagueCoins",
                                @"todayEarnedCoins",@"bonusCoin",@"incomeMissionCoins",
                                @"autoCollectionBonusCoins",@"videoMissionBonusCoins"]) {
            [ud setObject:@(kInjectedCoins) forKey:key];
        }
        [ud synchronize];
    } @catch (id e) {
        WriteDiagnostic([NSString stringWithFormat:@"UserDefaults ERROR: %@", e]);
    }
}

// ─────────────────────────────────────────────────
// Realm DB — FULLY GUARDED
// ─────────────────────────────────────────────────

static void PatchRealmDB(void) {
    @try {
        Class realmClass = NSClassFromString(@"RLMRealm");
        if (!realmClass) return;
        
        id realm = ((id (*)(Class, SEL))objc_msgSend)(realmClass, sel_getUid("defaultRealm"));
        if (!realm) return;
        
        id schema = ((id (*)(id, SEL))objc_msgSend)(realm, sel_getUid("schema"));
        if (!schema) return;
        
        id objectSchemas = ((id (*)(id, SEL))objc_msgSend)(schema, sel_getUid("objectSchema"));
        if (!objectSchemas) return;
        
        unsigned long schemaCount = ((unsigned long (*)(id, SEL))objc_msgSend)(objectSchemas, sel_getUid("count"));
        if (schemaCount == 0) return;
        
        ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("beginWriteTransaction"));
        
        static BOOL firstDump = YES;
        int totalPatched = 0;
        
        for (unsigned long i = 0; i < schemaCount; i++) {
            @try {
                id schemaObj = ((id (*)(id, SEL, unsigned long))objc_msgSend)(objectSchemas, sel_getUid("objectAtIndex:"), i);
                NSString *className = ((id (*)(id, SEL))objc_msgSend)(schemaObj, sel_getUid("className"));
                if (!className || !([className hasPrefix:@"winwalk."] || [className hasPrefix:@"Realm"])) continue;
                
                id properties = ((id (*)(id, SEL))objc_msgSend)(schemaObj, sel_getUid("properties"));
                unsigned long propCount = ((unsigned long (*)(id, SEL))objc_msgSend)(properties, sel_getUid("count"));
                
                NSMutableArray *propDump = firstDump ? [NSMutableArray array] : nil;
                NSMutableDictionary *kv = [NSMutableDictionary dictionary];
                
                for (unsigned long j = 0; j < propCount; j++) {
                    id prop = ((id (*)(id, SEL, unsigned long))objc_msgSend)(properties, sel_getUid("objectAtIndex:"), j);
                    NSString *name = ((id (*)(id, SEL))objc_msgSend)(prop, sel_getUid("name"));
                    NSString *type = ((id (*)(id, SEL))objc_msgSend)(prop, sel_getUid("type"));
                    NSString *lower = name.lowercaseString;
                    NSString *lowerType = type.lowercaseString;
                    
                    if (firstDump) [propDump addObject:[NSString stringWithFormat:@"%@(%@)", name, type ?: @"?"]];
                    
                    if ([lower containsString:@"currentcoins"] || [lower isEqualToString:@"coins"] || [lower hasSuffix:@"coins"])
                        kv[name] = @(kInjectedCoins);
                    else if ([lower isEqualToString:@"step"])
                        kv[name] = @100000;
                    else if ([lower isEqualToString:@"distance"])
                        kv[name] = @80.0;
                    else if ([lower isEqualToString:@"calories"])
                        kv[name] = @500;
                    else if ([lower isEqualToString:@"activetime"])
                        kv[name] = @7200;
                    else if (([lower containsString:@"claim"] && [lower containsString:@"ready"]) ||
                             [lower isEqualToString:@"iscompleted"] || [lower isEqualToString:@"completed"] ||
                             [lower isEqualToString:@"isuploaded"] || [lower isEqualToString:@"isdone"] ||
                             [lower isEqualToString:@"isfinished"] || [lower isEqualToString:@"canclaim"]) {
                        if ([lowerType containsString:@"bool"] || [lowerType containsString:@"int"])
                            kv[name] = @YES;
                    }
                    else if ([lower containsString:@"progress"] || [lower containsString:@"count"] ||
                             [lower containsString:@"streak"] || [lower containsString:@"dayscompleted"] ||
                             [lower containsString:@"totalsteps"] || [lower containsString:@"requiredsteps"]) {
                        if ([lowerType containsString:@"int"] || [lowerType containsString:@"double"])
                            kv[name] = @999999;
                    }
                }
                
                if (firstDump && propDump.count > 0) {
                    WriteDiagnostic([NSString stringWithFormat:@"  %@ (%lu props): %@", className, propCount,
                                     [[propDump subarrayWithRange:NSMakeRange(0, MIN(8, propDump.count))] componentsJoinedByString:@", "]]);
                }
                
                if (kv.count == 0) continue;
                
                id results = ((id (*)(id, SEL, NSString*, NSString*))objc_msgSend)(realm, sel_getUid("objects:where:"), className, nil);
                if (!results) continue;
                
                unsigned long objCount = ((unsigned long (*)(id, SEL))objc_msgSend)(results, sel_getUid("count"));
                
                for (unsigned long k = 0; k < objCount; k++) {
                    id obj = ((id (*)(id, SEL, unsigned long))objc_msgSend)(results, sel_getUid("objectAtIndex:"), k);
                    if (!obj) continue;
                    for (NSString *key in kv) {
                        @try { ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), kv[key], key); }
                        @catch (id e2) {}
                    }
                }
                totalPatched += (int)objCount;
                
            } @catch (id e) {}
        }
        
        ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
        
        if (firstDump) {
            WriteDiagnostic(@"✓ Full property dump complete (see above)");
            firstDump = NO;
        }
        WriteDiagnostic([NSString stringWithFormat:@"Realm: %d objects patched", totalPatched]);
        
    } @catch (id e) {
        WriteDiagnostic([NSString stringWithFormat:@"Realm FATAL: %@", e]);
    }
}

// ─────────────────────────────────────────────────
// Constructor
// ─────────────────────────────────────────────────

__attribute__((constructor))
static void Init(void) {
    // Prevent double-init from dylib reload
    if (sDidInit) return;
    sDidInit = YES;
    
    WriteDiagnostic(@"========== V15 — GUARDED INIT +8s DELAY ==========");
    
    // UserDefaults hooks (safe, run immediately)
    @try {
        Method m1 = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
        if (m1) {
            orig_objectForKey = (void*)method_getImplementation(m1);
            method_setImplementation(m1, (IMP)hooked_objectForKey);
        }
        
        Method m2 = class_getInstanceMethod([NSUserDefaults class], @selector(integerForKey:));
        if (m2) {
            orig_integerForKey = (void*)method_getImplementation(m2);
            method_setImplementation(m2, (IMP)hooked_integerForKey);
        }
        
        WriteDiagnostic(@"✓ UserDefaults hooks installed");
    } @catch (id e) {
        WriteDiagnostic([NSString stringWithFormat:@"Init ERROR: %@", e]);
    }
    
    // Realm patcher: DELAYED 8 seconds to ensure DB is fully initialized
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (sRealmStarted) return;
        sRealmStarted = YES;
        
        ForceWriteUserDefaults();
        PatchRealmDB();
        
        // Then every 10 seconds
        [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t) {
            ForceWriteUserDefaults();
            PatchRealmDB();
        }];
        
        WriteDiagnostic(@"✓ Realm patcher started");
    });
}
