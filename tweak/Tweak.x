#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <fishhook/fishhook.h>

static const NSInteger kInjectedCoins = 999999;

// ──────── Forward declarations ────────
static void installFishHooksDelayed(void);

// ──────── ObjC Swizzling (SAFE to run in constructor) ────────
static NSInteger hookedCoinsGetter(id self, SEL _cmd) { return kInjectedCoins; }
static NSInteger hookedCurrentCoinsGetter(id self, SEL _cmd) { return kInjectedCoins; }
static NSInteger hookedStepGetter(id self, SEL _cmd) { return 99999900; }

static void swizzleGetterIfExists(Class cls, SEL originalSel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, originalSel);
    if (m) {
        method_setImplementation(m, (IMP)newImp);
        NSLog(@"[WinwalkHack] Swizzled -[%@ %@]", 
              NSStringFromClass(cls), NSStringFromSelector(originalSel));
    }
}

static void swizzleAllCoinClasses(void) {
    NSArray *selectors = @[@"coins", @"currentCoins", @"step", @"value",
                           @"coinBalance", @"coinValue", @"rewardCoins"];
    IMP coinImp = (IMP)hookedCoinsGetter;
    IMP currentCoinImp = (IMP)hookedCurrentCoinsGetter;
    IMP stepImp = (IMP)hookedStepGetter;
    
    unsigned int classCount = 0;
    Class *allClasses = objc_copyClassList(&classCount);
    
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = allClasses[i];
        NSString *cname = NSStringFromClass(cls);
        
        if ([cname containsString:@"winwalk"] ||
            [cname containsString:@"Winwalk"] ||
            [cname containsString:@"Realm"]) {
            
            for (NSString *selName in selectors) {
                SEL sel = NSSelectorFromString(selName);
                if ([selName isEqualToString:@"step"]) {
                    swizzleGetterIfExists(cls, sel, stepImp);
                } else if ([selName containsString:@"currentCoins"]) {
                    swizzleGetterIfExists(cls, sel, currentCoinImp);
                } else {
                    swizzleGetterIfExists(cls, sel, coinImp);
                }
            }
        }
    }
    free(allClasses);
}

// ──────── fishhook — DELAYED to prevent crash ────────
static NSInteger rep_coins(void) { return kInjectedCoins; }

static void installFishHooksDelayed(void) {
    NSLog(@"[WinwalkHack] Installing fishhook (delayed) ...");
    struct rebinding rebindings[] = {
        {"_$s7winwalk11CoinBalanceV5coinsSivg",             (void*)rep_coins, NULL},
        {"_$s7winwalk14StepCoinsQueryV5coinsSivg",          (void*)rep_coins, NULL},
        {"_$s7winwalk13StepCoinBonusV5coinsSivg",           (void*)rep_coins, NULL},
        {"_$s7winwalk14ChallengeStateV12currentCoinsSivg",  (void*)rep_coins, NULL},
        {"_$s7winwalk9ChallengeV5coinsSivg",                (void*)rep_coins, NULL},
        {"_$s7winwalk9ChallengeV12currentCoinsSivg",        (void*)rep_coins, NULL},
    };
    int count = sizeof(rebindings) / sizeof(struct rebinding);
    int result = rebind_symbols(rebindings, count);
    NSLog(@"[WinwalkHack] fishhook done: %d rebindings, result=%d", count, result);
}

// ──────── Realm DB brute-force patcher ────────
static void patchRealmDB(void) {
    Class realmClass = NSClassFromString(@"RLMRealm");
    if (!realmClass) return;

    id realm = ((id (*)(Class, SEL))objc_msgSend)(realmClass, sel_getUid("defaultRealm"));
    if (!realm) return;

    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("beginWriteTransaction"));

    NSArray *classNames = @[@"RealmChallengeItem", @"RealmRewardItem",
                            @"RealmStreakChallengeItem"];
    NSArray *keys = @[@"coins", @"currentCoins", @"step"];
    NSArray *values = @[@(kInjectedCoins), @(kInjectedCoins), @99999900];

    for (NSString *cn in classNames) {
        Class mc = NSClassFromString(cn);
        if (!mc) continue;
        id results = ((id (*)(Class, SEL, id))objc_msgSend)(mc, sel_getUid("allObjectsInRealm:"), realm);
        if (!results) continue;
        id enumerator = ((id (*)(id, SEL))objc_msgSend)(results, sel_getUid("objectEnumerator"));
        if (!enumerator) continue;
        id obj;
        while ((obj = ((id (*)(id, SEL))objc_msgSend)(enumerator, sel_getUid("nextObject")))) {
            for (int i = 0; i < 3; i++) {
                @try {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), values[i], keys[i]);
                } @catch (id e) {}
            }
        }
    }

    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
}

// ──────── Constructor — SAFE: no fishhook here ────────
__attribute__((constructor))
static void WinwalkHackInit(void) {
    NSLog(@"[WinwalkHack] =====================================");
    NSLog(@"[WinwalkHack] Dylib v2 — coin hooks loading");
    NSLog(@"[WinwalkHack] Injected value: %ld coins", (long)kInjectedCoins);
    NSLog(@"[WinwalkHack] =====================================");
    
    // Stage 1: ObjC swizzling (safe immediately)
    swizzleAllCoinClasses();
    NSLog(@"[WinwalkHack] Stage 1 done: ObjC swizzling");
    
    // Stage 2: Delay fishhook by 3 seconds (prevents dyld crash)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        installFishHooksDelayed();
    });
    
    // Stage 3: Realm DB fallback every 10 seconds
    [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t) {
        patchRealmDB();
    }];
    
    NSLog(@"[WinwalkHack] Init complete. fishhook staged for +3s.");
}
