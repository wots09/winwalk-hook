#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const NSInteger kInjectedCoins = 999999;
static BOOL sDidInit = NO;

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
    for (NSString *k in @[@"totalCoin",@"totalIncomeCoins",@"weeklyLeagueCoins",
                          @"todayEarnedCoins",@"bonusCoin",@"incomeMissionCoins",
                          @"autoCollectionBonusCoins"])
        [ud setObject:@(kInjectedCoins) forKey:k];
    [ud synchronize];
}

// ─── Realm — PRECISE writes using discovered property names from V17 ───
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
        int patched = 0, claimed = 0;
        
        for (unsigned long i = 0; i < n; i++) {
            id so = ((id (*)(id, SEL, unsigned long))objc_msgSend)(schemas, sel_getUid("objectAtIndex:"), i);
            NSString *cn = ((id (*)(id, SEL))objc_msgSend)(so, sel_getUid("className"));
            if (!cn || !([cn hasPrefix:@"winwalk."] || [cn hasPrefix:@"Realm"])) continue;
            
            NSMutableDictionary *kv = [NSMutableDictionary dictionary];
            
            if ([cn isEqualToString:@"RealmDailyStepModel"]) {
                kv[@"step"] = @100000;
                kv[@"distance"] = @80.0;
                kv[@"calories"] = @500;
                kv[@"activeTime"] = @7200;
            }
            else if ([cn isEqualToString:@"RealmChallengeItem"]) {
                kv[@"coins"] = @(kInjectedCoins);
                kv[@"currentCoins"] = @(kInjectedCoins);
                kv[@"goalCoins"] = @1;
                kv[@"goalSteps"] = @1;
                kv[@"isClaimReady"] = @YES;
            }
            else if ([cn isEqualToString:@"RealmStreakChallengeItem"]) {
                kv[@"coins"] = @(kInjectedCoins);
                kv[@"isClaimReady"] = @YES;
                kv[@"isDone"] = @YES;
            }
            else if ([cn isEqualToString:@"RealmRewardItem"]) {
                kv[@"coins"] = @(kInjectedCoins);
                kv[@"minLevel"] = @0;
            }
            else if ([cn isEqualToString:@"RealmGiftCardItem"]) {
                kv[@"coins"] = @(kInjectedCoins);
            }
            else if ([cn isEqualToString:@"RealmGiftCardItemDetail"]) {
                kv[@"coins"] = @(kInjectedCoins);
            }
            
            if (!kv.count) continue;
            
            id results = ((id (*)(id, SEL, NSString*, NSString*))objc_msgSend)(realm, sel_getUid("objects:where:"), cn, nil);
            unsigned long oc = ((unsigned long (*)(id, SEL))objc_msgSend)(results, sel_getUid("count"));
            for (unsigned long k = 0; k < oc; k++) {
                id obj = ((id (*)(id, SEL, unsigned long))objc_msgSend)(results, sel_getUid("objectAtIndex:"), k);
                for (NSString *key in kv) {
                    @try { ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), kv[key], key); }
                    @catch (id e2) {}
                }
            }
            patched += (int)oc;
            if ([cn containsString:@"Challenge"] || [cn containsString:@"Streak"]) claimed += (int)oc;
        }
        
        ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
        Log([NSString stringWithFormat:@"Realm: %d objs (%d claimable)", patched, claimed]);
    } @catch (NSException *e) {
        Log([NSString stringWithFormat:@"Realm EXC: %@", e.reason]);
    }
}

__attribute__((constructor))
static void Init(void) {
    if (sDidInit) return;
    sDidInit = YES;
    Log(@"========== V18 — PRECISE WRITES ==========");
    
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
        Log(@"✓ Running");
    });
}
