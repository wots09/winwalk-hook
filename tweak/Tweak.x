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

// ─── JSON helpers ───
static void ForceSuccess(NSMutableDictionary *dict) {
    // Force success flag
    if (dict[@"success"] && ![dict[@"success"] boolValue]) {
        dict[@"success"] = @YES;
        Log(@"  → forced 'success' to true");
    }
    if (dict[@"isSuccess"]) dict[@"isSuccess"] = @YES;
    if (dict[@"error"]) dict[@"error"] = [NSNull null];
    if (dict[@"message"] && [[dict[@"message"] lowercaseString] containsString:@"error"])
        dict[@"message"] = @"OK";
    if (dict[@"status"] && [dict[@"status"] intValue] != 200)
        dict[@"status"] = @200;
}

static void InjectCoins(NSMutableDictionary *dict) {
    ForceSuccess(dict);
    for (NSString *key in [dict allKeys]) {
        NSString *lower = [key lowercaseString];
        if (([lower containsString:@"coin"] || [lower containsString:@"balance"] || [lower isEqualToString:@"point"]) &&
            [dict[key] isKindOfClass:[NSNumber class]]) {
            dict[key] = @(kInjectedCoins);
        }
        if ([dict[key] isKindOfClass:[NSMutableDictionary class]]) InjectCoins(dict[key]);
        if ([dict[key] isKindOfClass:[NSMutableArray class]]) {
            for (id item in (NSMutableArray *)dict[key])
                if ([item isKindOfClass:[NSMutableDictionary class]]) InjectCoins(item);
        }
    }
}

static void InjectChallengeStates(id json) {
    if ([json isKindOfClass:[NSMutableDictionary class]]) {
        ForceSuccess((NSMutableDictionary *)json);
        NSMutableDictionary *dict = (NSMutableDictionary *)json;
        for (NSString *key in [dict allKeys]) {
            if ([key isEqualToString:@"isClaimReady"]) dict[key] = @YES;
            if ([key isEqualToString:@"currentCoins"]) dict[key] = @(kInjectedCoins);
            if ([key isEqualToString:@"goalCoins"]) dict[key] = @1;
            if ([key isEqualToString:@"goalSteps"]) dict[key] = @1;
            InjectCoins(dict);
            if ([dict[key] isKindOfClass:[NSMutableDictionary class]]) InjectChallengeStates(dict[key]);
            if ([dict[key] isKindOfClass:[NSMutableArray class]]) InjectChallengeStates(dict[key]);
        }
    } else if ([json isKindOfClass:[NSMutableArray class]]) {
        for (id item in (NSMutableArray *)json) InjectChallengeStates(item);
    }
}

// ─── NSURLProtocol ───
@interface WinwalkProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableData *mData;
@end

@implementation WinwalkProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)req {
    if (![req.URL.scheme hasPrefix:@"http"]) return NO;
    if ([NSURLProtocol propertyForKey:@"__wp" inRequest:req]) return NO;
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)req { return req; }

- (void)startLoading {
    NSMutableURLRequest *mr = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"__wp" inRequest:mr];
    NSString *url = mr.URL.absoluteString;
    if ([url containsString:@"ClaimChallenge"] || [url containsString:@"AddUserReward"] ||
        [url containsString:@"GetUserCoins"] || [url containsString:@"GetChallengeStates"])
        Log([NSString stringWithFormat:@"🎯 %@ %@", mr.HTTPMethod, url]);
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.protocolClasses = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    self.mData = [NSMutableData data];
    [[session dataTaskWithRequest:mr] resume];
}

- (void)stopLoading {}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)r
    completionHandler:(void (^)(NSURLSessionResponseDisposition))h {
    [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    h(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d { [self.mData appendData:d]; }

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)err {
    if (err) { [self.client URLProtocol:self didFailWithError:err]; return; }
    NSData *raw = [self.mData copy];
    NSString *url = self.request.URL.absoluteString;
    NSHTTPURLResponse *http = [t.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)t.response : nil;
    NSInteger status = http.statusCode;
    
    BOOL needsFake = NO;
    
    if ([url containsString:@"ClaimChallenge"]) {
        Log([NSString stringWithFormat:@"  ClaimChallenge: HTTP %ld", (long)status]);
        if (status != 200 || !raw) needsFake = YES;
        else {
            @try {
                id json = [NSJSONSerialization JSONObjectWithData:raw options:NSJSONReadingMutableContainers error:nil];
                if ([json isKindOfClass:[NSMutableDictionary class]]) {
                    // Check if server returned failure in JSON body
                    id succ = [(NSMutableDictionary *)json objectForKey:@"success"];
                    if (succ && ![succ boolValue]) {
                        Log(@"  → Server returned success=false, replacing with fake success");
                        needsFake = YES;
                    } else {
                        InjectCoins(json);
                        raw = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                    }
                }
            } @catch (id e) { needsFake = YES; }
        }
        if (needsFake) {
            NSString *fake = @"{\"success\":true,\"coins\":999999}";
            NSHTTPURLResponse *fr = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json"}];
            [self.client URLProtocol:self didReceiveResponse:fr cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            [self.client URLProtocol:self didLoadData:[fake dataUsingEncoding:NSUTF8StringEncoding]];
            [self.client URLProtocolDidFinishLoading:self];
            Log(@"  → FAKE SUCCESS");
            return;
        }
    }
    
    if ([url containsString:@"AddUserReward"]) {
        Log([NSString stringWithFormat:@"  AddUserReward: HTTP %ld", (long)status]);
        if (status != 200 || !raw) needsFake = YES;
        else {
            @try {
                id json = [NSJSONSerialization JSONObjectWithData:raw options:NSJSONReadingMutableContainers error:nil];
                if ([json isKindOfClass:[NSMutableDictionary class]]) {
                    id succ = [(NSMutableDictionary *)json objectForKey:@"success"];
                    if (succ && ![succ boolValue]) {
                        Log(@"  → success=false, faking");
                        needsFake = YES;
                    } else {
                        InjectCoins(json);
                        raw = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                    }
                }
            } @catch (id e) { needsFake = YES; }
        }
        if (needsFake) {
            NSString *fake = @"{\"success\":true,\"rewardCode\":\"REDEEMED\",\"coins\":999999}";
            NSHTTPURLResponse *fr = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json"}];
            [self.client URLProtocol:self didReceiveResponse:fr cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            [self.client URLProtocol:self didLoadData:[fake dataUsingEncoding:NSUTF8StringEncoding]];
            [self.client URLProtocolDidFinishLoading:self];
            Log(@"  → FAKE SUCCESS");
            return;
        }
    }
    
    if ([url containsString:@"GetUserCoins"] && raw) {
        @try {
            id json = [NSJSONSerialization JSONObjectWithData:raw options:NSJSONReadingMutableContainers error:nil];
            if ([json isKindOfClass:[NSMutableDictionary class]]) { InjectCoins(json); raw = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil]; }
        } @catch (id e) {}
    }
    
    if ([url containsString:@"GetChallengeStates"] && raw) {
        @try {
            id json = [NSJSONSerialization JSONObjectWithData:raw options:NSJSONReadingMutableContainers error:nil];
            if (json) { InjectChallengeStates(json); raw = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil]; }
        } @catch (id e) {}
    }
    
    [self.client URLProtocol:self didLoadData:raw];
    [self.client URLProtocolDidFinishLoading:self];
}

@end

// ─── Config hooks ───
static id (*orig_defaultCfg)(Class, SEL);
static id (*orig_ephemeralCfg)(Class, SEL);
static id (*orig_initWithCfg)(id, SEL, id);

static void InjectProtocol(id cfg) {
    @try {
        NSMutableArray *p = [[cfg valueForKey:@"protocolClasses"] mutableCopy] ?: [NSMutableArray array];
        Class wp = NSClassFromString(@"WinwalkProtocol");
        if (wp && ![p containsObject:wp]) { [p insertObject:wp atIndex:0]; [cfg setValue:p forKey:@"protocolClasses"]; }
    } @catch (id e) {}
}

static id hooked_defaultCfg(Class self, SEL _cmd) { id c = orig_defaultCfg(self, _cmd); InjectProtocol(c); return c; }
static id hooked_ephemeralCfg(Class self, SEL _cmd) { id c = orig_ephemeralCfg(self, _cmd); InjectProtocol(c); return c; }
static id hooked_initWithCfg(id self, SEL _cmd, id cfg) { InjectProtocol(cfg); return orig_initWithCfg(self, _cmd, cfg); }

// ─── Alerts ───
static void (*orig_presentVC)(id, SEL, UIViewController*, BOOL, id);
static void hooked_presentVC(id self, SEL _cmd, UIViewController *vc, BOOL animated, id completion) {
    if ([vc isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)vc;
        NSString *c = [NSString stringWithFormat:@"%@ %@", alert.title ?: @"", alert.message ?: @""];
        if ([c containsString:@"Oops"] || [c containsString:@"can't reach"] ||
            [c containsString:@"general error"] || [c containsString:@"try again later"] ||
            [c containsString:@"Need more coin"]) {
            Log([NSString stringWithFormat:@"🚫 Swallowed: \"%@\"", alert.title]);
            for (UIAlertAction *a in alert.actions)
                if (a.style == UIAlertActionStyleDefault || a.style == UIAlertActionStyleCancel) {
                    void (^h)(UIAlertAction *) = [a valueForKey:@"handler"]; if (h) { h(a); break; }
                }
            return;
        }
    }
    orig_presentVC(self, _cmd, vc, animated, completion);
}

// ─── UserDefaults ───
static id (*orig_ud)(id, SEL, NSString*);
static id hooked_ud(id self, SEL _cmd, NSString *key) {
    if ([key.lowercaseString containsString:@"coin"] || [key.lowercaseString containsString:@"balance"]) return @(kInjectedCoins);
    return orig_ud(self, _cmd, key);
}

static void ForceUD(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (NSString *k in @[@"totalCoin",@"totalIncomeCoins",@"weeklyLeagueCoins",
                          @"todayEarnedCoins",@"bonusCoin",@"incomeMissionCoins",@"autoCollectionBonusCoins"])
        [ud setObject:@(kInjectedCoins) forKey:k];
    [ud synchronize];
}

// ─── Realm ───
static void PatchRealm(void) {
    @try {
        Class rc = NSClassFromString(@"RLMRealm"); if (!rc) return;
        id realm = ((id (*)(Class, SEL))objc_msgSend)(rc, sel_getUid("defaultRealm")); if (!realm) return;
        id schema = ((id (*)(id, SEL))objc_msgSend)(realm, sel_getUid("schema"));
        id schemas = ((id (*)(id, SEL))objc_msgSend)(schema, sel_getUid("objectSchema"));
        unsigned long n = ((unsigned long (*)(id, SEL))objc_msgSend)(schemas, sel_getUid("count"));
        ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("beginWriteTransaction"));
        for (unsigned long i = 0; i < n; i++) {
            id so = ((id (*)(id, SEL, unsigned long))objc_msgSend)(schemas, sel_getUid("objectAtIndex:"), i);
            NSString *cn = ((id (*)(id, SEL))objc_msgSend)(so, sel_getUid("className"));
            if (!cn || !([cn hasPrefix:@"winwalk."] || [cn hasPrefix:@"Realm"])) continue;
            NSMutableDictionary *kv = [NSMutableDictionary dictionary];
            if ([cn isEqualToString:@"RealmDailyStepModel"]) { kv[@"step"]=@100000; kv[@"distance"]=@80.0; kv[@"calories"]=@500; kv[@"activeTime"]=@7200; }
            else if ([cn isEqualToString:@"RealmChallengeItem"]) { kv[@"coins"]=@(kInjectedCoins); kv[@"currentCoins"]=@(kInjectedCoins); kv[@"goalCoins"]=@1; kv[@"goalSteps"]=@1; kv[@"isClaimReady"]=@YES; }
            else if ([cn isEqualToString:@"RealmStreakChallengeItem"]) { kv[@"coins"]=@(kInjectedCoins); kv[@"isClaimReady"]=@YES; kv[@"isDone"]=@YES; }
            else if ([cn isEqualToString:@"RealmRewardItem"]) { kv[@"coins"]=@(kInjectedCoins); kv[@"minLevel"]=@0; }
            else if ([cn isEqualToString:@"RealmGiftCardItem"]) { kv[@"coins"]=@(kInjectedCoins); }
            else if ([cn isEqualToString:@"RealmGiftCardItemDetail"]) { kv[@"coins"]=@(kInjectedCoins); }
            if (!kv.count) continue;
            id results = ((id (*)(id, SEL, NSString*, NSString*))objc_msgSend)(realm, sel_getUid("objects:where:"), cn, nil);
            unsigned long oc = ((unsigned long (*)(id, SEL))objc_msgSend)(results, sel_getUid("count"));
            for (unsigned long k = 0; k < oc; k++) {
                id obj = ((id (*)(id, SEL, unsigned long))objc_msgSend)(results, sel_getUid("objectAtIndex:"), k);
                for (NSString *key in kv) @try { ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), kv[key], key); } @catch (id e2) {}
            }
        }
        ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
    } @catch (NSException *e) {}
}

// ─── Init ───
__attribute__((constructor))
static void Init(void) {
    if (sDidInit) return; sDidInit = YES;
    Log(@"========== V22 — FORCE SUCCESS FLAG ==========");
    [NSURLProtocol registerClass:[WinwalkProtocol class]];
    Method cm1 = class_getClassMethod([NSURLSessionConfiguration class], @selector(defaultSessionConfiguration));
    orig_defaultCfg = (void*)method_getImplementation(cm1); method_setImplementation(cm1, (IMP)hooked_defaultCfg);
    Method cm2 = class_getClassMethod([NSURLSessionConfiguration class], @selector(ephemeralSessionConfiguration));
    orig_ephemeralCfg = (void*)method_getImplementation(cm2); method_setImplementation(cm2, (IMP)hooked_ephemeralCfg);
    Method im = class_getInstanceMethod([NSURLSession class], @selector(initWithConfiguration:));
    orig_initWithCfg = (void*)method_getImplementation(im); method_setImplementation(im, (IMP)hooked_initWithCfg);
    Log(@"✓ Protocol hooks");
    Method am = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
    orig_presentVC = (void*)method_getImplementation(am); method_setImplementation(am, (IMP)hooked_presentVC);
    Method um = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
    orig_ud = (void*)method_getImplementation(um); method_setImplementation(um, (IMP)hooked_ud);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ForceUD(); PatchRealm();
        [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(NSTimer *t) { ForceUD(); PatchRealm(); }];
        Log(@"✓ Running");
    });
}
