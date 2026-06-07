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
// 1. Response interception — hook dataTaskWithRequest:completionHandler:
// ─────────────────────────────────────────────────

static id (*orig_dataTaskWithReq_completion)(id, SEL, NSURLRequest*, void(^)(NSData*, NSURLResponse*, NSError*));

static id hooked_dataTaskWithReq_completion(id self, SEL _cmd, NSURLRequest *req,
    void(^origHandler)(NSData*, NSURLResponse*, NSError*)) {
    
    NSString *url = req.URL.absoluteString;
    
    void(^wrappedHandler)(NSData*, NSURLResponse*, NSError*) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        
        NSHTTPURLResponse *httpResp = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        NSInteger statusCode = httpResp.statusCode;
        
        // ── /Challenge/ClaimChallenge ──
        if ([url containsString:@"/Challenge/ClaimChallenge"]) {
            Log([NSString stringWithFormat:@"🎯 ClaimChallenge: status=%ld", (long)statusCode]);
            @try {
                // If server returned error, replace with fake success
                if (statusCode != 200 || err || !data) {
                    NSString *fake = @"{\"success\":true,\"coins\":999999}";
                    NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc]
                        initWithURL:resp.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
                        headerFields:@{@"Content-Type":@"application/json"}];
                    Log(@"  → REPLACED with fake success response");
                    origHandler([fake dataUsingEncoding:NSUTF8StringEncoding], fakeResp, nil);
                    return;
                }
                // If success but wrong coin value, inject 999999
                id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
                if ([json isKindOfClass:[NSMutableDictionary class]]) {
                    [self injectCoins:json];
                    NSData *newData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                    Log(@"  → Coins injected into success response");
                    origHandler(newData, resp, err);
                    return;
                }
            } @catch (id e) {
                Log([NSString stringWithFormat:@"  ClaimChallenge error: %@", e]);
            }
        }
        
        // ── /Reward/AddUserReward (redeem gift) ──
        if ([url containsString:@"/Reward/AddUserReward"]) {
            Log([NSString stringWithFormat:@"🎯 AddUserReward: status=%ld", (long)statusCode]);
            @try {
                if (statusCode != 200 || err || !data) {
                    NSString *fake = @"{\"success\":true,\"rewardCode\":\"REDEEMED-999999\"}";
                    NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc]
                        initWithURL:resp.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
                        headerFields:@{@"Content-Type":@"application/json"}];
                    Log(@"  → REPLACED with fake success");
                    origHandler([fake dataUsingEncoding:NSUTF8StringEncoding], fakeResp, nil);
                    return;
                }
                id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
                if ([json isKindOfClass:[NSMutableDictionary class]]) {
                    [self injectCoins:json];
                    NSData *newData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                    origHandler(newData, resp, err);
                    return;
                }
            } @catch (id e) {
                Log([NSString stringWithFormat:@"  AddUserReward error: %@", e]);
            }
        }
        
        // ── /User/GetUserCoins ──
        if ([url containsString:@"/User/GetUserCoins"]) {
            @try {
                if (data) {
                    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
                    if ([json isKindOfClass:[NSMutableDictionary class]]) {
                        [self injectCoins:json];
                        NSData *newData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                        Log(@"🎯 GetUserCoins: injected 999999");
                        origHandler(newData, resp, err);
                        return;
                    }
                }
            } @catch (id e) {}
        }
        
        // ── /Challenge/GetChallengeStates ──
        if ([url containsString:@"/Challenge/GetChallengeStates"]) {
            @try {
                if (data) {
                    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
                    if (json) {
                        [self injectChallengeStates:json];
                        NSData *newData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                        Log(@"🎯 GetChallengeStates: injected isClaimReady + coins");
                        origHandler(newData, resp, err);
                        return;
                    }
                }
            } @catch (id e) {}
        }
        
        // Pass through unchanged
        origHandler(data, resp, err);
    };
    
    return orig_dataTaskWithReq_completion(self, _cmd, req, wrappedHandler);
}

// Helper: recursively inject coin values into any dict
- (void)injectCoins:(NSMutableDictionary *)dict {
    for (NSString *key in [dict allKeys]) {
        NSString *lower = [key lowercaseString];
        if (([lower containsString:@"coin"] || [lower containsString:@"balance"] || [lower isEqualToString:@"point"]) &&
            [dict[key] isKindOfClass:[NSNumber class]] && [dict[key] integerValue] != kInjectedCoins) {
            dict[key] = @(kInjectedCoins);
        }
        if ([dict[key] isKindOfClass:[NSMutableDictionary class]]) [self injectCoins:dict[key]];
        if ([dict[key] isKindOfClass:[NSMutableArray class]]) {
            for (id item in (NSMutableArray *)dict[key])
                if ([item isKindOfClass:[NSMutableDictionary class]]) [self injectCoins:item];
        }
    }
}

// Helper: inject challenge completion into array of challenge states
- (void)injectChallengeStates:(id)json {
    if ([json isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)json;
        for (NSString *key in [dict allKeys]) {
            if ([key isEqualToString:@"isClaimReady"]) dict[key] = @YES;
            if ([key isEqualToString:@"currentCoins"]) dict[key] = @(kInjectedCoins);
            if ([key isEqualToString:@"goalCoins"]) dict[key] = @1;
            if ([key isEqualToString:@"goalSteps"]) dict[key] = @1;
            [self injectCoins:dict]; // also inject any coin fields
            if ([dict[key] isKindOfClass:[NSMutableDictionary class]]) [self injectChallengeStates:dict[key]];
            if ([dict[key] isKindOfClass:[NSMutableArray class]]) [self injectChallengeStates:dict[key]];
        }
    } else if ([json isKindOfClass:[NSMutableArray class]]) {
        for (id item in (NSMutableArray *)json)
            [self injectChallengeStates:item];
    }
}

// ─────────────────────────────────────────────────
// 2. Alert suppression (broader match)
// ─────────────────────────────────────────────────

static void (*orig_presentVC)(id, SEL, UIViewController*, BOOL, id);
static void hooked_presentVC(id self, SEL _cmd, UIViewController *vc, BOOL animated, id completion) {
    if ([vc isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)vc;
        NSString *title = alert.title ?: @"";
        NSString *msg = alert.message ?: @"";
        NSString *combined = [[title stringByAppendingString:@" "] stringByAppendingString:msg];
        
        if ([combined containsString:@"Oops"] ||
            [combined containsString:@"can't reach"] ||
            [combined containsString:@"general error"] ||
            [combined containsString:@"try again later"] ||
            [combined containsString:@"Need more coin"]) {
            
            Log([NSString stringWithFormat:@"🚫 Swallowed: \"%@\"", title]);
            // Fire the default action handler
            for (UIAlertAction *action in alert.actions) {
                if (action.style == UIAlertActionStyleDefault || action.style == UIAlertActionStyleCancel) {
                    void (^handler)(UIAlertAction *) = [action valueForKey:@"handler"];
                    if (handler) {
                        handler(action);
                        break;
                    }
                }
            }
            return;
        }
    }
    orig_presentVC(self, _cmd, vc, animated, completion);
}

// ─────────────────────────────────────────────────
// 3. UserDefaults (unchanged)
// ─────────────────────────────────────────────────

static id (*orig_ud_object)(id, SEL, NSString*);
static id hooked_ud_object(id self, SEL _cmd, NSString *key) {
    if ([key.lowercaseString containsString:@"coin"] || [key.lowercaseString containsString:@"balance"])
        return @(kInjectedCoins);
    return orig_ud_object(self, _cmd, key);
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
// 4. Realm (V18 precise writes, unchanged)
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
        for (unsigned long i = 0; i < n; i++) {
            id so = ((id (*)(id, SEL, unsigned long))objc_msgSend)(schemas, sel_getUid("objectAtIndex:"), i);
            NSString *cn = ((id (*)(id, SEL))objc_msgSend)(so, sel_getUid("className"));
            if (!cn || !([cn hasPrefix:@"winwalk."] || [cn hasPrefix:@"Realm"])) continue;
            NSMutableDictionary *kv = [NSMutableDictionary dictionary];
            if ([cn isEqualToString:@"RealmDailyStepModel"]) {
                kv[@"step"]=@100000; kv[@"distance"]=@80.0; kv[@"calories"]=@500; kv[@"activeTime"]=@7200;
            } else if ([cn isEqualToString:@"RealmChallengeItem"]) {
                kv[@"coins"]=@(kInjectedCoins); kv[@"currentCoins"]=@(kInjectedCoins);
                kv[@"goalCoins"]=@1; kv[@"goalSteps"]=@1; kv[@"isClaimReady"]=@YES;
            } else if ([cn isEqualToString:@"RealmStreakChallengeItem"]) {
                kv[@"coins"]=@(kInjectedCoins); kv[@"isClaimReady"]=@YES; kv[@"isDone"]=@YES;
            } else if ([cn isEqualToString:@"RealmRewardItem"]) {
                kv[@"coins"]=@(kInjectedCoins); kv[@"minLevel"]=@0;
            } else if ([cn isEqualToString:@"RealmGiftCardItem"]) {
                kv[@"coins"]=@(kInjectedCoins);
            } else if ([cn isEqualToString:@"RealmGiftCardItemDetail"]) {
                kv[@"coins"]=@(kInjectedCoins);
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
        }
        ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
    } @catch (NSException *e) {}
}

// ─────────────────────────────────────────────────
// Constructor
// ─────────────────────────────────────────────────

__attribute__((constructor))
static void Init(void) {
    if (sDidInit) return;
    sDidInit = YES;
    Log(@"========== V20 — RESPONSE INTERCEPTION ==========");
    
    // Hook dataTaskWithRequest:completionHandler: (catches response)
    Method respM = class_getInstanceMethod([NSURLSession class], @selector(dataTaskWithRequest:completionHandler:));
    if (respM) {
        orig_dataTaskWithReq_completion = (void*)method_getImplementation(respM);
        method_setImplementation(respM, (IMP)hooked_dataTaskWithReq_completion);
        Log(@"✓ Response hook installed");
    }
    
    // Alert suppression
    Method alertM = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
    if (alertM) {
        orig_presentVC = (void*)method_getImplementation(alertM);
        method_setImplementation(alertM, (IMP)hooked_presentVC);
        Log(@"✓ Alert hook installed");
    }
    
    // UserDefaults
    Method udM = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
    orig_ud_object = (void*)method_getImplementation(udM);
    method_setImplementation(udM, (IMP)hooked_ud_object);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        ForceWriteUD();
        PatchRealm();
        [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(NSTimer *t) {
            ForceWriteUD();
            PatchRealm();
        }];
        Log(@"✓ All systems running");
    });
}
