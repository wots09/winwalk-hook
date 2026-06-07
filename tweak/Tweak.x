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

// ─────────────────────────────────────
// NETWORK INTERCEPTION — Hook NSURLSession dataTaskWithRequest
// to log and modify API calls
// ─────────────────────────────────────

static id (*orig_dataTaskWithRequest_completionHandler)(id, SEL, NSURLRequest*, void(^)(NSData*, NSURLResponse*, NSError*));

static id hooked_dataTaskWithRequest_completionHandler(id self, SEL _cmd, NSURLRequest *req, void(^handler)(NSData*, NSURLResponse*, NSError*)) {
    NSURL *url = req.URL;
    NSString *urlStr = url.absoluteString;
    
    // Log all API calls to identify coin/balance endpoints
    if ([urlStr containsString:@"coin"] || [urlStr containsString:@"balance"] ||
        [urlStr containsString:@"reward"] || [urlStr containsString:@"redeem"] ||
        [urlStr containsString:@"gift"] || [urlStr containsString:@"shop"] ||
        [urlStr containsString:@"user"] || [urlStr containsString:@"profile"] ||
        [urlStr containsString:@"wallet"] || [urlStr containsString:@"mission"]) {
        
        WriteDiagnostic([NSString stringWithFormat:@"📡 REQ: %@", urlStr]);
        
        if (req.HTTPBody) {
            NSString *bodyStr = [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding];
            if (bodyStr.length > 500) bodyStr = [[bodyStr substringToIndex:500] stringByAppendingString:@"..."];
            WriteDiagnostic([NSString stringWithFormat:@"   BODY: %@", bodyStr ?: @"(binary)"]);                   
        }
    }
    
    // Wrap completion handler to intercept responses
    void(^wrappedHandler)(NSData*, NSURLResponse*, NSError*) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        if ([urlStr containsString:@"coin"] || [urlStr containsString:@"balance"] ||
            [urlStr containsString:@"reward"] || [urlStr containsString:@"redeem"] ||
            [urlStr containsString:@"gift"] || [urlStr containsString:@"wallet"] ||
            [urlStr containsString:@"user"]) {
            
            if (data) {
                NSString *respStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (respStr.length > 800) respStr = [[respStr substringToIndex:800] stringByAppendingString:@"..."];
                WriteDiagnostic([NSString stringWithFormat:@"📡 RESP(%@): %@", url.lastPathComponent, respStr ?: @"(binary)"]);
                
                // Attempt to inject coin values into JSON responses
                @try {
                    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
                    if ([json isKindOfClass:[NSMutableDictionary class]]) {
                        NSMutableDictionary *dict = (NSMutableDictionary *)json;
                        BOOL modified = NO;
                        for (NSString *key in [dict allKeys]) {
                            NSString *lower = key.lowercaseString;
                            if (([lower containsString:@"coin"] || [lower containsString:@"balance"]) &&
                                [dict[key] isKindOfClass:[NSNumber class]]) {
                                NSInteger currentVal = [dict[key] integerValue];
                                if (currentVal > 0 && currentVal < kInjectedCoins) {
                                    dict[key] = @(kInjectedCoins);
                                    modified = YES;
                                }
                            }
                        }
                        if (modified) {
                            NSData *newData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
                            if (newData) {
                                WriteDiagnostic(@"   ✏️ Injected 999999 into response JSON");
                                handler(newData, resp, err);
                                return;
                            }
                        }
                    }
                } @catch (id e) {}
            }
        }
        handler(data, resp, err);
    };
    
    return orig_dataTaskWithRequest_completionHandler(self, _cmd, req, wrappedHandler);
}

// ─────────────────────────────────────
// UserDefaults hooks + force write (V10, unchanged)
// ─────────────────────────────────────

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

static NSDictionary* hooked_dictionaryRepresentation(id self, SEL _cmd) {
    NSMutableDictionary *dict = [orig_dictionaryRepresentation(self, _cmd) mutableCopy];
    for (NSString *key in [dict allKeys]) {
        if ([key.lowercaseString containsString:@"coin"] || [key.lowercaseString containsString:@"balance"]) {
            dict[key] = @(kInjectedCoins);
        }
    }
    return [dict copy];
}

static void ForceWriteUserDefaults(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSArray *keys = @[@"totalCoin", @"totalIncomeCoins", @"weeklyLeagueCoins",
                      @"todayEarnedCoins", @"bonusCoin", @"incomeMissionCoins",
                      @"autoCollectionBonusCoins", @"videoMissionBonusCoins"];
    for (NSString *key in keys) {
        [ud setObject:@(kInjectedCoins) forKey:key];
    }
    [ud synchronize];
}

// ─────────────────────────────────────
// Realm DB patcher (V10, unchanged)
// ─────────────────────────────────────

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
        NSString *cn = ((id (*)(id, SEL))objc_msgSend)(schemaObj, sel_getUid("className"));
        if (!cn || !([cn hasPrefix:@"winwalk."] || [cn hasPrefix:@"Realm"])) continue;
        id props = ((id (*)(id, SEL))objc_msgSend)(schemaObj, sel_getUid("properties"));
        unsigned long pc = ((unsigned long (*)(id, SEL))objc_msgSend)(props, sel_getUid("count"));
        NSMutableDictionary *kv = [NSMutableDictionary dictionary];
        for (unsigned long j = 0; j < pc; j++) {
            id prop = ((id (*)(id, SEL, unsigned long))objc_msgSend)(props, sel_getUid("objectAtIndex:"), j);
            NSString *name = ((id (*)(id, SEL))objc_msgSend)(prop, sel_getUid("name"));
            NSString *l = name.lowercaseString;
            if ([l containsString:@"currentcoins"] || [l isEqualToString:@"coins"] || [l hasSuffix:@"coins"]) kv[name] = @(kInjectedCoins);
            else if ([l isEqualToString:@"step"]) kv[name] = @100000;
            else if ([l isEqualToString:@"distance"]) kv[name] = @80.0;
            else if ([l isEqualToString:@"calories"]) kv[name] = @500;
            else if ([l isEqualToString:@"activetime"]) kv[name] = @7200;
        }
        if (!kv.count) continue;
        id results = ((id (*)(id, SEL, NSString*, NSString*))objc_msgSend)(realm, sel_getUid("objects:where:"), cn, nil);
        unsigned long oc = ((unsigned long (*)(id, SEL))objc_msgSend)(results, sel_getUid("count"));
        for (unsigned long k = 0; k < oc; k++) {
            id obj = ((id (*)(id, SEL, unsigned long))objc_msgSend)(results, sel_getUid("objectAtIndex:"), k);
            for (NSString *key in kv) {
                @try { ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), kv[key], key); }
                @catch (id e) {}
            }
        }
    }
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
}

// ─── Constructor ───
__attribute__((constructor))
static void Init(void) {
    WriteDiagnostic(@"========== V11 — NETWORK INTERCEPTION ==========");
    
    // NSUserDefaults swizzles
    Method m1 = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
    orig_objectForKey = (void*)method_getImplementation(m1);
    method_setImplementation(m1, (IMP)hooked_objectForKey);
    
    Method m2 = class_getInstanceMethod([NSUserDefaults class], @selector(integerForKey:));
    orig_integerForKey = (void*)method_getImplementation(m2);
    method_setImplementation(m2, (IMP)hooked_integerForKey);
    
    Method m3 = class_getInstanceMethod([NSUserDefaults class], @selector(dictionaryRepresentation));
    orig_dictionaryRepresentation = (void*)method_getImplementation(m3);
    method_setImplementation(m3, (IMP)hooked_dictionaryRepresentation);
    
    // NSURLSession swizzle for network interception
    // Hook the default session's dataTaskWithRequest:completionHandler:
    // NSURLSession dataTaskWithRequest:completionHandler: is on the instance
    Class sessionClass = [NSURLSession class];
    Method netM = class_getInstanceMethod(sessionClass, @selector(dataTaskWithRequest:completionHandler:));
    if (netM) {
        orig_dataTaskWithRequest_completionHandler = (void*)method_getImplementation(netM);
        method_setImplementation(netM, (IMP)hooked_dataTaskWithRequest_completionHandler);
        WriteDiagnostic(@"✓ NSURLSession hooked");
    } else {
        WriteDiagnostic(@"✗ NSURLSession hook FAILED");
    }
    
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
