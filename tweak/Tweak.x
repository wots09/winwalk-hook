#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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

// ─────────────────────────────────────────────────
// 1. Swallow "Oops" server error alerts
// ─────────────────────────────────────────────────

static void (*orig_presentVC_animated_completion)(id, SEL, id, BOOL, id);
static void hooked_presentVC(id self, SEL _cmd, UIViewController *vc, BOOL animated, id completion) {
    if ([vc isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)vc;
        NSString *title = alert.title ?: @"";
        NSString *msg = alert.message ?: @"";
        
        Log([NSString stringWithFormat:@"🚫 Alert intercepted: title=\"%@\" msg=\"%@\"", title, msg]);
        
        // Swallow server error / connectivity alerts
        if ([title containsString:@"Oops"] ||
            [msg containsString:@"can't reach the server"] ||
            [msg containsString:@"general error"] ||
            [title containsString:@"Error"] ||
            [msg containsString:@"try again later"] ||
            [msg containsString:@"Need more coins"]) {
            Log(@"  → SWALLOWED — alert suppressed");
            
            // Simulate tapping "OK" by calling the action handler
            for (UIAlertAction *action in alert.actions) {
                if (action.style == UIAlertActionStyleDefault || action.style == UIAlertActionStyleCancel) {
                    void (^handler)(UIAlertAction *) = [action valueForKey:@"handler"];
                    if (handler) handler(action);
                }
            }
            return; // Don't present the alert
        }
    }
    orig_presentVC_animated_completion(self, _cmd, vc, animated, completion);
}

// ─────────────────────────────────────────────────
// 2. Lightweight URL logging — hook NSURL init only
// ─────────────────────────────────────────────────

static id (*orig_NSURLSession_taskWithRequest)(id, SEL, id);
static id hooked_taskWithRequest(id self, SEL _cmd, NSURLRequest *req) {
    NSString *url = req.URL.absoluteString;
    // Only log app API calls (not ad SDKs)
    if (![url containsString:@"unity3d"] &&
        ![url containsString:@"vungle"] &&
        ![url containsString:@"fyber"] &&
        ![url containsString:@"google"] &&
        ![url containsString:@"firebase"] &&
        ![url containsString:@"applovin"] &&
        ![url containsString:@"moloco"]) {
        Log([NSString stringWithFormat:@"📡 %@ %@", req.HTTPMethod ?: @"GET", url]);
    }
    return orig_NSURLSession_taskWithRequest(self, _cmd, req);
}

// ─────────────────────────────────────────────────
// 3. UserDefaults (unchanged)
// ─────────────────────────────────────────────────

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

// ─────────────────────────────────────────────────
// 4. Realm (V18 precise writes)
// ─────────────────────────────────────────────────

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
                kv[@"step"] = @100000; kv[@"distance"] = @80.0;
                kv[@"calories"] = @500; kv[@"activeTime"] = @7200;
            } else if ([cn isEqualToString:@"RealmChallengeItem"]) {
                kv[@"coins"] = @(kInjectedCoins);
                kv[@"currentCoins"] = @(kInjectedCoins);
                kv[@"goalCoins"] = @1; kv[@"goalSteps"] = @1;
                kv[@"isClaimReady"] = @YES;
            } else if ([cn isEqualToString:@"RealmStreakChallengeItem"]) {
                kv[@"coins"] = @(kInjectedCoins);
                kv[@"isClaimReady"] = @YES; kv[@"isDone"] = @YES;
            } else if ([cn isEqualToString:@"RealmRewardItem"]) {
                kv[@"coins"] = @(kInjectedCoins); kv[@"minLevel"] = @0;
            } else if ([cn isEqualToString:@"RealmGiftCardItem"]) {
                kv[@"coins"] = @(kInjectedCoins);
            } else if ([cn isEqualToString:@"RealmGiftCardItemDetail"]) {
                kv[@"coins"] = @(kInjectedCoins);
            }
            
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
            if ([cn containsString:@"Challenge"] || [cn containsString:@"Streak"]) claimed += (int)oc;
        }
        
        ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
        Log([NSString stringWithFormat:@"Realm: %d objs (%d claimable)", patched, claimed]);
    } @catch (NSException *e) {
        Log([NSString stringWithFormat:@"Realm EXC: %@", e.reason]);
    }
}

// ─────────────────────────────────────────────────
// Constructor
// ─────────────────────────────────────────────────

__attribute__((constructor))
static void Init(void) {
    if (sDidInit) return;
    sDidInit = YES;
    Log(@"========== V19 — ALERT SUPPRESS + URL LOG ==========");
    
    // 1. Hook UIAlertController presentation
    Method alertM = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
    if (alertM) {
        orig_presentVC_animated_completion = (void*)method_getImplementation(alertM);
        method_setImplementation(alertM, (IMP)hooked_presentVC);
        Log(@"✓ Alert hook installed");
    }
    
    // 2. Hook NSURLSession dataTaskWithRequest (lightweight logging)
    Method taskM = class_getInstanceMethod([NSURLSession class], @selector(dataTaskWithRequest:));
    if (taskM) {
        orig_NSURLSession_taskWithRequest = (void*)method_getImplementation(taskM);
        method_setImplementation(taskM, (IMP)hooked_taskWithRequest);
        Log(@"✓ URL log hook installed");
    }
    
    // 3. Hook UserDefaults
    Method udM = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
    orig_objectForKey = (void*)method_getImplementation(udM);
    method_setImplementation(udM, (IMP)hooked_objectForKey);
    
    // 4. Realm patcher at T+12s
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
