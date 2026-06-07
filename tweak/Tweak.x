#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const NSInteger kInjectedCoins = 999999;
static BOOL sDidInit = NO;
static BOOL sFirstDump = YES;

static void Log(NSString *msg) {
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

// ─── UserDefaults (V10 proven-safe) ───
static id (*orig_objectForKey)(id, SEL, NSString*);

static id hooked_objectForKey(id self, SEL _cmd, NSString *key) {
    if ([key.lowercaseString containsString:@"coin"] || [key.lowercaseString containsString:@"balance"])
        return @(kInjectedCoins);
    return orig_objectForKey(self, _cmd, key);
}

static void ForceWriteUD(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:@(kInjectedCoins) forKey:@"totalCoin"];
    [ud setObject:@(kInjectedCoins) forKey:@"totalIncomeCoins"];
    [ud setObject:@(kInjectedCoins) forKey:@"weeklyLeagueCoins"];
    [ud setObject:@(kInjectedCoins) forKey:@"todayEarnedCoins"];
    [ud setObject:@(kInjectedCoins) forKey:@"bonusCoin"];
    [ud setObject:@(kInjectedCoins) forKey:@"incomeMissionCoins"];
    [ud setObject:@(kInjectedCoins) forKey:@"autoCollectionBonusCoins"];
    [ud synchronize];
}

// ─── Realm — READ-ONLY dump, then ONLY V10-proven safe writes ───
static void PatchRealm(void) {
    @try {
        Class rc = NSClassFromString(@"RLMRealm");
        if (!rc) return;
        id realm = ((id (*)(Class, SEL))objc_msgSend)(rc, sel_getUid("defaultRealm"));
        if (!realm) return;
        id schema = ((id (*)(id, SEL))objc_msgSend)(realm, sel_getUid("schema"));
        id schemas = ((id (*)(id, SEL))objc_msgSend)(schema, sel_getUid("objectSchema"));
        unsigned long n = ((unsigned long (*)(id, SEL))objc_msgSend)(schemas, sel_getUid("count"));
        
        if (sFirstDump) Log([NSString stringWithFormat:@"=== Schema: %lu types ===", n]);
        
        ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("beginWriteTransaction"));
        int patched = 0;
        
        for (unsigned long i = 0; i < n; i++) {
            id so = ((id (*)(id, SEL, unsigned long))objc_msgSend)(schemas, sel_getUid("objectAtIndex:"), i);
            NSString *cn = ((id (*)(id, SEL))objc_msgSend)(so, sel_getUid("className"));
            if (!cn || !([cn hasPrefix:@"winwalk."] || [cn hasPrefix:@"Realm"])) continue;
            
            id props = ((id (*)(id, SEL))objc_msgSend)(so, sel_getUid("properties"));
            unsigned long pc = ((unsigned long (*)(id, SEL))objc_msgSend)(props, sel_getUid("count"));
            
            NSMutableDictionary *kv = [NSMutableDictionary dictionary];
            NSMutableArray *dump = sFirstDump ? [NSMutableArray array] : nil;
            
            for (unsigned long j = 0; j < pc; j++) {
                id prop = ((id (*)(id, SEL, unsigned long))objc_msgSend)(props, sel_getUid("objectAtIndex:"), j);
                NSString *name = ((id (*)(id, SEL))objc_msgSend)(prop, sel_getUid("name"));
                NSString *type = ((id (*)(id, SEL))objc_msgSend)(prop, sel_getUid("type"));
                NSString *lower = [name lowercaseString];
                
                if (sFirstDump) [dump addObject:[NSString stringWithFormat:@"%@(%@)", name, type ?: @"?"]];
                
                // ONLY V10-proven safe writes — nothing else
                if ([lower containsString:@"coin"] || [lower hasSuffix:@"coins"] || [lower containsString:@"balance"])
                    kv[name] = @(kInjectedCoins);
                else if ([lower isEqualToString:@"step"])
                    kv[name] = @100000;
                else if ([lower isEqualToString:@"distance"])
                    kv[name] = @80.0;
                else if ([lower isEqualToString:@"calories"])
                    kv[name] = @500;
                else if ([lower isEqualToString:@"activetime"])
                    kv[name] = @7200;
            }
            
            if (sFirstDump && dump.count > 0)
                Log([NSString stringWithFormat:@"  %@: %@", cn, [dump componentsJoinedByString:@", "]]);
            
            if (!kv.count) continue;
            
            id results = ((id (*)(id, SEL, NSString*, NSString*))objc_msgSend)(realm, sel_getUid("objects:where:"), cn, nil);
            if (!results) continue;
            unsigned long oc = ((unsigned long (*)(id, SEL))objc_msgSend)(results, sel_getUid("count"));
            for (unsigned long k = 0; k < oc; k++) {
                id obj = ((id (*)(id, SEL, unsigned long))objc_msgSend)(results, sel_getUid("objectAtIndex:"), k);
                for (NSString *key in kv)
                    @try { ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), kv[key], key); }
                    @catch (id e2) {}
            }
            patched += (int)oc;
        }
        
        ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
        if (sFirstDump) { Log(@"=== End Dump ==="); sFirstDump = NO; }
        Log([NSString stringWithFormat:@"Realm: %d objs", patched]);
    } @catch (id e) {
        Log([NSString stringWithFormat:@"Realm EXC: %@", e]);
    }
}

// ─── Constructor ───
__attribute__((constructor))
static void Init(void) {
    if (sDidInit) return;
    sDidInit = YES;
    Log(@"========== V16 — READ-ONLY DUMP, SAFE WRITES ==========");
    
    Method m = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
    orig_objectForKey = (void*)method_getImplementation(m);
    method_setImplementation(m, (IMP)hooked_objectForKey);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        ForceWriteUD();
        PatchRealm();
        [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(NSTimer *t) {
            ForceWriteUD();
            PatchRealm();
        }];
        Log(@"✓ Patcher started");
    });
}
