#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <fishhook/fishhook.h>

static const NSInteger kInjectedCoins = 999999;

// ────────── Foward declarations ──────────
static void RLMSetAllCoins(Class cls, id realm, NSNumber *value);

// ────────── ObjC Swizzling ──────────
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

// ────────── fishhook for Swift getters ──────────
static NSInteger rep_coins(void) { return kInjectedCoins; }

static void installFishHooks(void) {
    struct rebinding rebindings[] = {
        {"_$s7winwalk11CoinBalanceV5coinsSivg", (void*)rep_coins, NULL},
        {"_$s7winwalk14StepCoinsQueryV5coinsSivg", (void*)rep_coins, NULL},
        {"_$s7winwalk13StepCoinBonusV5coinsSivg", (void*)rep_coins, NULL},
        {"_$s7winwalk14ChallengeStateV12currentCoinsSivg", (void*)rep_coins, NULL},
        {"_$s7winwalk9ChallengeV5coinsSivg", (void*)rep_coins, NULL},
        {"_$s7winwalk9ChallengeV12currentCoinsSivg", (void*)rep_coins, NULL},
    };
    rebind_symbols(rebindings,
        sizeof(rebindings) / sizeof(struct rebinding));
}

// ────────── Realm DB brute-force patcher ──────────
static void RLMSetAllCoins(Class cls, id realm, NSNumber *value) {
    id results = ((id (*)(Class, SEL, id))objc_msgSend)(cls, sel_getUid("allObjectsInRealm:"), realm);
    if (!results) return;
    
    id enumerator = ((id (*)(id, SEL))objc_msgSend)(results, sel_getUid("objectEnumerator"));
    if (!enumerator) return;
    
    id obj;
    while ((obj = ((id (*)(id, SEL))objc_msgSend)(enumerator, sel_getUid("nextObject")))) {
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), value, @"currentCoins");
        } @catch (id e) {}
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), value, @"coins");
        } @catch (id e) {}
        @try {
            ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), @99999900, @"step");
        } @catch (id e) {}
    }
}

static void patchRealmDB(void) {
    Class realmClass = NSClassFromString(@"RLMRealm");
    if (!realmClass) return;
    
    id realm = ((id (*)(Class, SEL))objc_msgSend)(realmClass, sel_getUid("defaultRealm"));
    if (!realm) return;
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("beginWriteTransaction"));
    
    NSArray *classNames = @[@"RealmChallengeItem", @"RealmRewardItem",
                            @"RealmStreakChallengeItem"];
    for (NSString *cn in classNames) {
        Class mc = NSClassFromString(cn);
        if (mc) RLMSetAllCoins(mc, realm, @(kInjectedCoins));
    }
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
}

// ────────── Constructor ──────────
__attribute__((constructor))
static void WinwalkHackInit(void) {
    NSLog(@"[WinwalkHack] =====================================");
    NSLog(@"[WinwalkHack] Dylib loaded — installing coin hooks");
    NSLog(@"[WinwalkHack] Injected coins: %ld", (long)kInjectedCoins);
    NSLog(@"[WinwalkHack] =====================================");
    
    swizzleAllCoinClasses();
    installFishHooks();
    
    [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t) {
        patchRealmDB();
    }];
    
    NSLog(@"[WinwalkHack] All hooks installed.");
}
