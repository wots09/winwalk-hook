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

// ─────────────────────────────────────────────────
// Realm DB — dump ALL properties, auto-complete challenges
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
    
    for (unsigned long i = 0; i < schemaCount; i++) {
        id schemaObj = ((id (*)(id, SEL, unsigned long))objc_msgSend)(objectSchemas, sel_getUid("objectAtIndex:"), i);
        NSString *className = ((id (*)(id, SEL))objc_msgSend)(schemaObj, sel_getUid("className"));
        if (!className || !([className hasPrefix:@"winwalk."] || [className hasPrefix:@"Realm"])) continue;
        
        id properties = ((id (*)(id, SEL))objc_msgSend)(schemaObj, sel_getUid("properties"));
        unsigned long propCount = ((unsigned long (*)(id, SEL))objc_msgSend)(properties, sel_getUid("count"));
        
        // First pass: dump ALL property names (diagnostic)
        NSMutableArray *allPropNames = [NSMutableArray array];
        for (unsigned long j = 0; j < propCount; j++) {
            id prop = ((id (*)(id, SEL, unsigned long))objc_msgSend)(properties, sel_getUid("objectAtIndex:"), j);
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(prop, sel_getUid("name"));
            NSString *type = ((id (*)(id, SEL))objc_msgSend)(prop, sel_getUid("type"));
            [allPropNames addObject:[NSString stringWithFormat:@"%@(%@)", name, type ?: @"?"]];
        }
        
        // Second pass: build value map
        NSMutableDictionary *kv = [NSMutableDictionary dictionary];
        for (unsigned long j = 0; j < propCount; j++) {
            id prop = ((id (*)(id, SEL, unsigned long))objc_msgSend)(properties, sel_getUid("objectAtIndex:"), j);
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(prop, sel_getUid("name"));
            NSString *lower = name.lowercaseString;
            NSString *type = ((id (*)(id, SEL))objc_msgSend)(prop, sel_getUid("type"));
            NSString *lowerType = type.lowercaseString;
            
            // Coin properties → 999999
            if ([lower containsString:@"currentcoins"] || [lower isEqualToString:@"coins"] || [lower hasSuffix:@"coins"]) {
                kv[name] = @(kInjectedCoins);
            }
            // Step properties
            else if ([lower isEqualToString:@"step"]) {
                kv[name] = @100000;
            }
            else if ([lower isEqualToString:@"distance"]) {
                kv[name] = @80.0;
            }
            else if ([lower isEqualToString:@"calories"]) {
                kv[name] = @500;
            }
            else if ([lower isEqualToString:@"activetime"]) {
                kv[name] = @7200;
            }
            // Auto-complete: set isClaimReady, isCompleted, isUploaded to true
            else if (([lower containsString:@"claim"] && [lower containsString:@"ready"]) ||
                     [lower isEqualToString:@"iscompleted"] ||
                     [lower isEqualToString:@"completed"] ||
                     [lower isEqualToString:@"isuploaded"] ||
                     [lower isEqualToString:@"isdone"] ||
                     [lower isEqualToString:@"isfinished"] ||
                     [lower isEqualToString:@"canclaim"]) {
                if ([lowerType containsString:@"bool"] || [lowerType containsString:@"int"]) {
                    kv[name] = @YES;
                }
            }
            // Set progress fields to max (for challenge completion)
            else if ([lower containsString:@"progress"] || [lower containsString:@"count"] || 
                     [lower containsString:@"streak"] || [lower containsString:@"dayscompleted"]) {
                if ([lowerType containsString:@"int"] || [lowerType containsString:@"double"]) {
                    kv[name] = @999999;
                }
            }
        }
        
        if (kv.count == 0 && allPropNames.count == 0) continue;
        
        // Log the class structure on first pass
        static BOOL firstPass = YES;
        if (firstPass && allPropNames.count > 0) {
            WriteDiagnostic([NSString stringWithFormat:@"  %@ props: %@", className, [allPropNames componentsJoinedByString:@", "]]);
        }
        
        if (kv.count == 0) continue;
        
        id results = ((id (*)(id, SEL, NSString*, NSString*))objc_msgSend)(realm, sel_getUid("objects:where:"), className, nil);
        unsigned long objCount = ((unsigned long (*)(id, SEL))objc_msgSend)(results, sel_getUid("count"));
        
        for (unsigned long k = 0; k < objCount; k++) {
            id obj = ((id (*)(id, SEL, unsigned long))objc_msgSend)(results, sel_getUid("objectAtIndex:"), k);
            for (NSString *key in kv) {
                @try { ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), kv[key], key); }
                @catch (id e) {}
            }
        }
    }
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
    static BOOL firstDump = YES;
    if (firstDump) {
        WriteDiagnostic(@"✓ All class properties dumped above");
        firstDump = NO;
    }
}

// ─────────────────────────────────────────────────
// UserDefaults (unchanged)
// ─────────────────────────────────────────────────
static id (*orig_objectForKey)(id, SEL, NSString*);
static id hooked_objectForKey(id self, SEL _cmd, NSString *key) {
    if ([key.lowercaseString containsString:@"coin"] || [key.lowercaseString containsString:@"balance"])
        return @(kInjectedCoins);
    return orig_objectForKey(self, _cmd, key);
}

static void ForceWriteUserDefaults(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[@"totalCoin",@"totalIncomeCoins",@"weeklyLeagueCoins",
                            @"todayEarnedCoins",@"bonusCoin",@"incomeMissionCoins",
                            @"autoCollectionBonusCoins",@"videoMissionBonusCoins"]) {
        [ud setObject:@(kInjectedCoins) forKey:key];
    }
    [ud synchronize];
}

// ─── Constructor ───
__attribute__((constructor))
static void Init(void) {
    WriteDiagnostic(@"========== V14 — AUTO-COMPLETE CHALLENGES ==========");
    
    Method m = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
    orig_objectForKey = (void*)method_getImplementation(m);
    method_setImplementation(m, (IMP)hooked_objectForKey);
    
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
