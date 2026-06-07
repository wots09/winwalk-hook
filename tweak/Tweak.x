#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const NSInteger kInjectedCoins = 999999;
static BOOL sDidInit = NO;
static BOOL sDumped = NO;

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

// ─── UserDefaults ───
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

// ─── Realm — ONLY V10-safe writes, dump names only (no type call) ───
static void PatchRealm(void) {
    @try {
        Class rc = NSClassFromString(@"RLMRealm");
        if (!rc) return;
        id realm = ((id (*)(Class, SEL))objc_msgSend)(rc, sel_getUid("defaultRealm"));
        if (!realm) return;
        
        id schema = ((id (*)(id, SEL))objc_msgSend)(realm, sel_getUid("schema"));
        id schemas = ((id (*)(id, SEL))objc_msgSend)(schema, sel_getUid("objectSchema"));
        unsigned long n = ((unsigned long (*)(id, SEL))objc_msgSend)(schemas, sel_getUid("count"));
        
        ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("beginWriteTransaction"));
        int patched = 0;
        
        for (unsigned long i = 0; i < n; i++) {
            id so = ((id (*)(id, SEL, unsigned long))objc_msgSend)(schemas, sel_getUid("objectAtIndex:"), i);
            NSString *cn = ((id (*)(id, SEL))objc_msgSend)(so, sel_getUid("className"));
            if (!cn || !([cn hasPrefix:@"winwalk."] || [cn hasPrefix:@"Realm"])) continue;
            
            id props = ((id (*)(id, SEL))objc_msgSend)(so, sel_getUid("properties"));
            unsigned long pc = ((unsigned long (*)(id, SEL))objc_msgSend)(props, sel_getUid("count"));
            
            NSMutableDictionary *kv = [NSMutableDictionary dictionary];
            NSMutableArray *names = (!sDumped) ? [NSMutableArray array] : nil;
            
            for (unsigned long j = 0; j < pc; j++) {
                id prop = ((id (*)(id, SEL, unsigned long))objc_msgSend)(props, sel_getUid("objectAtIndex:"), j);
                NSString *name = ((id (*)(id, SEL))objc_msgSend)(prop, sel_getUid("name"));
                NSString *lower = [name lowercaseString];
                
                if (names) [names addObject:name];
                
                // V10-safe writes ONLY
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
            
            if (names && names.count > 0)
                Log([NSString stringWithFormat:@"  %@: %@", cn, [names componentsJoinedByString:@", "]]);
            
            if (!kv.count) continue;
            
            id results = ((id (*)(id, SEL, NSString*, NSString*))objc_msgSend)(realm, sel_getUid("objects:where:"), cn, nil);
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
        if (!sDumped) { Log(@"=== Property dump complete ==="); sDumped = YES; }
        Log([NSString stringWithFormat:@"Realm: %d objects", patched]);
    } @catch (NSException *e) {
        Log([NSString stringWithFormat:@"Realm EXC: %@ — %@", e.name, e.reason]);
    }
}

__attribute__((constructor))
static void Init(void) {
    if (sDidInit) return;
    sDidInit = YES;
    Log(@"========== V17 — NO TYPE CALL, SAFE ==========");
    
    Method m = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
    orig_objectForKey = (void*)method_getImplementation(m);
    method_setImplementation(m, (IMP)hooked_objectForKey);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        ForceWriteUD();
        PatchRealm();
        [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(NSTimer *t) {
            ForceWriteUD();
            PatchRealm();
        }];
        Log(@"✓ Patcher running");
    });
}
