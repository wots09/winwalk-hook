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
// NSURLProtocol subclass — intercepts ALL HTTP traffic
// ─────────────────────────────────────────────────

@interface WinwalkInterceptor : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *mutableData;
@end

@implementation WinwalkInterceptor

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // Only intercept HTTP/HTTPS
    if (![request.URL.scheme isEqualToString:@"http"] &&
        ![request.URL.scheme isEqualToString:@"https"]) return NO;
    
    // Don't intercept ourselves
    if ([NSURLProtocol propertyForKey:@"WinwalkHandled" inRequest:request]) return NO;
    
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *mutableRequest = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"WinwalkHandled" inRequest:mutableRequest];
    
    NSString *urlStr = self.request.URL.absoluteString;
    NSString *method = self.request.HTTPMethod ?: @"GET";
    
    // Log ALL requests (first 200 chars of URL)
    NSString *shortURL = urlStr.length > 200 ? [[urlStr substringToIndex:200] stringByAppendingString:@"..."] : urlStr;
    WriteDiagnostic([NSString stringWithFormat:@"📡 %@ %@", method, shortURL]);
    
    if (self.request.HTTPBody) {
        NSString *body = [[NSString alloc] initWithData:self.request.HTTPBody encoding:NSUTF8StringEncoding];
        if (body.length > 0) {
            if (body.length > 500) body = [[body substringToIndex:500] stringByAppendingString:@"..."];
            WriteDiagnostic([NSString stringWithFormat:@"   BODY: %@", body]);
        }
    }
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.protocolClasses = nil; // Don't re-intercept our own requests
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                          delegate:self
                                                     delegateQueue:nil];
    
    self.mutableData = [NSMutableData data];
    self.task = [session dataTaskWithRequest:mutableRequest];
    [self.task resume];
}

- (void)stopLoading {
    [self.task cancel];
    self.task = nil;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.mutableData appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        [self.client URLProtocol:self didFailWithError:error];
    } else {
        NSData *responseData = [self.mutableData copy];
        NSString *urlStr = self.request.URL.absoluteString;
        
        // Try to inject coin values into JSON responses
        BOOL injected = NO;
        @try {
            id json = [NSJSONSerialization JSONObjectWithData:responseData options:NSJSONReadingMutableContainers error:nil];
            
            if ([json isKindOfClass:[NSMutableDictionary class]]) {
                NSMutableDictionary *dict = (NSMutableDictionary *)json;
                if ([self injectCoinsIntoDict:dict]) {
                    injected = YES;
                    responseData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
                }
            } else if ([json isKindOfClass:[NSMutableArray class]]) {
                NSMutableArray *arr = (NSMutableArray *)json;
                BOOL anyInjected = NO;
                for (id item in arr) {
                    if ([item isKindOfClass:[NSMutableDictionary class]]) {
                        if ([self injectCoinsIntoDict:(NSMutableDictionary *)item]) anyInjected = YES;
                    }
                }
                if (anyInjected) {
                    injected = YES;
                    responseData = [NSJSONSerialization dataWithJSONObject:arr options:0 error:nil];
                }
            }
            
            if (injected) {
                WriteDiagnostic([NSString stringWithFormat:@"   ✏️ INJECTED 999999 into response: %@",
                                 urlStr.lastPathComponent]);
            }
        } @catch (id e) {}
        
        [self.client URLProtocol:self didLoadData:responseData];
        [self.client URLProtocolDidFinishLoading:self];
    }
}

- (BOOL)injectCoinsIntoDict:(NSMutableDictionary *)dict {
    BOOL found = NO;
    for (NSString *key in [dict allKeys]) {
        NSString *lower = key.lowercaseString;
        if (([lower containsString:@"coin"] || [lower containsString:@"balance"] || [lower isEqualToString:@"point"]) &&
            [dict[key] isKindOfClass:[NSNumber class]]) {
            NSInteger cv = [dict[key] integerValue];
            if (cv != kInjectedCoins && cv != 0) {
                dict[key] = @(kInjectedCoins);
                found = YES;
            }
        }
        // Recurse into nested dicts
        if ([dict[key] isKindOfClass:[NSMutableDictionary class]]) {
            if ([self injectCoinsIntoDict:(NSMutableDictionary *)dict[key]]) found = YES;
        }
        if ([dict[key] isKindOfClass:[NSMutableArray class]]) {
            for (id item in (NSMutableArray *)dict[key]) {
                if ([item isKindOfClass:[NSMutableDictionary class]]) {
                    if ([self injectCoinsIntoDict:(NSMutableDictionary *)item]) found = YES;
                }
            }
        }
    }
    return found;
}

@end

// ─────────────────────────────────────────────────
// UserDefaults hooks + force write (unchanged)
// ─────────────────────────────────────────────────

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
        if ([key.lowercaseString containsString:@"coin"] || [key.lowercaseString containsString:@"balance"]) dict[key] = @(kInjectedCoins);
    }
    return [dict copy];
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

// ─────────────────────────────────────────────────
// Realm DB patcher (unchanged)
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
    WriteDiagnostic(@"========== V12 — NSURLProtocol INTERCEPTOR ==========");
    
    // UserDefaults swizzles
    Method m1 = class_getInstanceMethod([NSUserDefaults class], @selector(objectForKey:));
    orig_objectForKey = (void*)method_getImplementation(m1);
    method_setImplementation(m1, (IMP)hooked_objectForKey);
    
    Method m2 = class_getInstanceMethod([NSUserDefaults class], @selector(integerForKey:));
    orig_integerForKey = (void*)method_getImplementation(m2);
    method_setImplementation(m2, (IMP)hooked_integerForKey);
    
    Method m3 = class_getInstanceMethod([NSUserDefaults class], @selector(dictionaryRepresentation));
    orig_dictionaryRepresentation = (void*)method_getImplementation(m3);
    method_setImplementation(m3, (IMP)hooked_dictionaryRepresentation);
    
    // Register NSURLProtocol to catch ALL HTTP traffic
    [NSURLProtocol registerClass:[WinwalkInterceptor class]];
    WriteDiagnostic(@"✓ NSURLProtocol registered");
    
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
