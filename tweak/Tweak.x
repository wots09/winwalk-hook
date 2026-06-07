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

// ─── V25: handles PascalCase + Result key ───
static void FixResponse(NSMutableDictionary *dict) {
    // 1. Neutralize ReturnValue (negative → 0)
    if ([dict[@"ReturnValue"] respondsToSelector:@selector(integerValue)] && [dict[@"ReturnValue"] integerValue] < 0) {
        Log([NSString stringWithFormat:@"  ReturnValue %ld→0", (long)[dict[@"ReturnValue"] integerValue]]);
        dict[@"ReturnValue"] = @0;
    }
    if ([dict[@"returnValue"] respondsToSelector:@selector(integerValue)] && [dict[@"returnValue"] integerValue] < 0) {
        dict[@"returnValue"] = @0;
    }
    
    // 2. Suppress error display
    if (dict[@"ShowsMessage"]) dict[@"ShowsMessage"] = @NO;
    if (dict[@"showsMessage"]) dict[@"showsMessage"] = @NO;
    if (dict[@"Message"]) dict[@"Message"] = @"OK";
    if (dict[@"message"]) dict[@"message"] = @"OK";
    
    // 3. Inject 999999 into Result if it's a number (the GetUserCoins pattern)
    if ([dict[@"Result"] isKindOfClass:[NSNumber class]]) {
        dict[@"Result"] = @(kInjectedCoins);
        Log(@"  Result(number) → 999999");
    }
    // If Result is array of objects, recurse
    if ([dict[@"Result"] isKindOfClass:[NSMutableArray class]]) {
        for (id item in (NSMutableArray *)dict[@"Result"])
            if ([item isKindOfClass:[NSMutableDictionary class]]) FixResponse(item);
    }
    
    // 4. Fix IsClaimReady (PascalCase) + coin-related fields
    NSArray *claimKeys = @[@"IsClaimReady", @"isClaimReady", @"isDone", @"IsDone", @"canClaim", @"CanClaim"];
    for (NSString *ck in claimKeys) {
        if (dict[ck]) dict[ck] = @YES;
    }
    
    // 5. Inject coins into any remaining coin/balance/point/result/coins keys
    for (NSString *key in [dict allKeys]) {
        NSString *lower = [key lowercaseString];
        if (([lower containsString:@"coin"] || [lower containsString:@"balance"] || [lower isEqualToString:@"point"] || [lower isEqualToString:@"result"]) &&
            [dict[key] isKindOfClass:[NSNumber class]] && [dict[key] integerValue] != kInjectedCoins) {
            dict[key] = @(kInjectedCoins);
        }
        if ([dict[key] isKindOfClass:[NSMutableDictionary class]]) FixResponse(dict[key]);
        if ([dict[key] isKindOfClass:[NSMutableArray class]]) {
            for (id item in (NSMutableArray *)dict[key])
                if ([item isKindOfClass:[NSMutableDictionary class]]) FixResponse(item);
        }
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
    @try {
        id json = [NSJSONSerialization JSONObjectWithData:raw options:NSJSONReadingMutableContainers error:nil];
        if ([json isKindOfClass:[NSMutableDictionary class]]) {
            FixResponse((NSMutableDictionary *)json);
            raw = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
        } else if ([json isKindOfClass:[NSMutableArray class]]) {
            for (id item in (NSMutableArray *)json)
                if ([item isKindOfClass:[NSMutableDictionary class]]) FixResponse(item);
            raw = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
        }
        if (raw.length < 200) {
            NSString *s = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
            if (s) Log([NSString stringWithFormat:@"  → %@", s]);
        }
    } @catch (id e) {}
    [self.client URLProtocol:self didLoadData:raw];
    [self.client URLProtocolDidFinishLoading:self];
}

@end

// ─── Config hooks ───
static id (*orig_defCfg)(Class, SEL); static id (*orig_ephCfg)(Class, SEL); static id (*orig_initCfg)(id, SEL, id);
static void InjectProto(id cfg) {
    @try {
        NSMutableArray *p = [[cfg valueForKey:@"protocolClasses"] mutableCopy] ?: [NSMutableArray array];
        Class wp = NSClassFromString(@"WinwalkProtocol");
        if (wp && ![p containsObject:wp]) { [p insertObject:wp atIndex:0]; [cfg setValue:p forKey:@"protocolClasses"]; }
    } @catch (id e) {}
}
static id hk_defCfg(Class s, SEL c) { id x = orig_defCfg(s,c); InjectProto(x); return x; }
static id hk_ephCfg(Class s, SEL c) { id x = orig_ephCfg(s,c); InjectProto(x); return x; }
static id hk_initCfg(id s, SEL c, id cfg) { InjectProto(cfg); return orig_initCfg(s,c,cfg); }

// ─── Alerts ───
static void (*orig_pVC)(id, SEL, UIViewController*, BOOL, id);
static void hk_pVC(id s, SEL c, UIViewController *vc, BOOL a, id cb) {
    if ([vc isKindOfClass:[UIAlertController class]]) {
        UIAlertController *al = (UIAlertController *)vc;
        NSString *t = [NSString stringWithFormat:@"\"%@\" / \"%@\"", al.title?:@"", al.message?:@""];
        if ([t containsString:@"Oops"] || [t containsString:@"can't reach"] ||
            [t containsString:@"general error"] || [t containsString:@"try again later"] ||
            [t containsString:@"Need more coin"] || [t containsString:@"error occurred"]) {
            Log([NSString stringWithFormat:@"🚫 Swallowed: %@", t]);
            for (UIAlertAction *ac in al.actions)
                if (ac.style == UIAlertActionStyleDefault || ac.style == UIAlertActionStyleCancel) {
                    void (^h)(UIAlertAction*) = [ac valueForKey:@"handler"]; if (h) { h(ac); break; }
                }
            return;
        }
    }
    orig_pVC(s,c,vc,a,cb);
}

// ─── UserDefaults ───
static id (*orig_ud)(id, SEL, NSString*);
static id hk_ud(id s, SEL c, NSString *k) {
    if ([k.lowercaseString containsString:@"coin"] || [k.lowercaseString containsString:@"balance"]) return @(kInjectedCoins);
    return orig_ud(s,c,k);
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
        id schemas = ((id (*)(id, SEL))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)(realm, sel_getUid("schema")), sel_getUid("objectSchema"));
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

__attribute__((constructor))
static void Init(void) {
    if (sDidInit) return; sDidInit = YES;
    Log(@"========== V25 — ISCLAIMREADY + RESULT FIX ==========");
    [NSURLProtocol registerClass:[WinwalkProtocol class]];
    Method cm1 = class_getClassMethod([NSURLSessionConfiguration class], @selector(defaultSessionConfiguration));
    orig_defCfg = (void*)method_getImplementation(cm1); method_setImplementation(cm1, (IMP)hk_defCfg);
    Method cm2 = class_getClassMethod([NSURLSessionConfiguration class], @selector(ephemeralSessionConfiguration));
    orig_ephCfg = (void*)method_getImplementation(cm2); method_setImplementation(cm2, (IMP)hk_ephCfg);
    Method im = class_getInstanceMethod([NSURLSession class], @selector(initWithConfiguration:));
    orig_initCfg = (void*)method_getImplementation(im); method_setImplementation(im, (IMP)hk_initCfg);
    Log(@"✓ Protocol");
    Method am = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
    orig_pVC = (void*)method_getImplementation(am); method_setImplementation(am, (IMP)hk_pVC);
    Method um = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
    orig_ud = (void*)method_getImplementation(um); method_setImplementation(um, (IMP)hk_ud);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ForceUD(); PatchRealm();
        [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(NSTimer *t) { ForceUD(); PatchRealm(); }];
        Log(@"✓ Running");
    });
}
