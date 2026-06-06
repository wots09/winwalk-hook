#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <fishhook/fishhook.h>

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
    NSLog(@"%@", line);
}

static void DumpCoinClasses(void) {
    unsigned int count = 0;
    Class *all = objc_copyClassList(&count);
    NSMutableString *found = [NSMutableString string];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(all[i]);
        if ([name.lowercaseString containsString:@"coin"] || 
            [name.lowercaseString containsString:@"step"] ||
            [name.lowercaseString containsString:@"challenge"] ||
            [name.lowercaseString containsString:@"reward"] ||
            [name containsString:@"Realm"]) {
            [found appendFormat:@"  %@\n", name];
        }
    }
    free(all);
    WriteDiagnostic([NSString stringWithFormat:@"Relevant classes:\n%@", found]);
}

static NSInteger hookedCoinsGetter(id self, SEL _cmd) { return kInjectedCoins; }
static NSInteger hookedCurrentCoinsGetter(id self, SEL _cmd) { return kInjectedCoins; }
static NSInteger hookedStepGetter(id self, SEL _cmd) { return 99999900; }

static void swizzleGetterIfExists(Class cls, SEL originalSel, IMP newImp, NSMutableString *log) {
    Method m = class_getInstanceMethod(cls, originalSel);
    if (m) {
        method_setImplementation(m, (IMP)newImp);
        [log appendFormat:@"  + %@.%@\n", NSStringFromClass(cls), NSStringFromSelector(originalSel)];
    }
}

static void swizzleAllCoinClasses(void) {
    NSArray *selectors = @[@"coins", @"currentCoins", @"step", @"value",
                           @"coinBalance", @"coinValue", @"rewardCoins", 
                           @"currentStep", @"remainingCoin"];
    IMP coinImp = (IMP)hookedCoinsGetter;
    IMP curImp = (IMP)hookedCurrentCoinsGetter;
    IMP stepImp = (IMP)hookedStepGetter;
    
    NSMutableString *log = [NSMutableString string];
    unsigned int classCount = 0;
    Class *allClasses = objc_copyClassList(&classCount);
    
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = allClasses[i];
        NSString *cname = NSStringFromClass(cls);
        if ([cname containsString:@"winwalk"] || [cname containsString:@"Winwalk"] || [cname containsString:@"Realm"]) {
            for (NSString *selName in selectors) {
                SEL sel = NSSelectorFromString(selName);
                if ([selName isEqualToString:@"step"] || [selName isEqualToString:@"currentStep"])
                    swizzleGetterIfExists(cls, sel, stepImp, log);
                else if ([selName containsString:@"currentCoins"] || [selName containsString:@"remainingCoin"])
                    swizzleGetterIfExists(cls, sel, curImp, log);
                else
                    swizzleGetterIfExists(cls, sel, coinImp, log);
            }
        }
    }
    free(allClasses);
    WriteDiagnostic([NSString stringWithFormat:@"Swizzled:\n%@", log]);
}

static NSInteger rep_coins(void) { return kInjectedCoins; }

static void installFishHooksDelayed(void) {
    WriteDiagnostic(@"fishhook: installing...");
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
    WriteDiagnostic([NSString stringWithFormat:@"fishhook: %d rebindings, ret=%d", count, result]);
    for (int i = 0; i < count; i++) {
        void *orig = dlsym(RTLD_DEFAULT, rebindings[i].name);
        WriteDiagnostic([NSString stringWithFormat:@"  %s → %s", rebindings[i].name, orig ? "FOUND" : "MISSING"]);
    }
}

static void patchRealmDB(void) {
    Class realmClass = NSClassFromString(@"RLMRealm");
    if (!realmClass) { WriteDiagnostic(@"Realm: RLMRealm NOT found"); return; }
    id realm = ((id (*)(Class, SEL))objc_msgSend)(realmClass, sel_getUid("defaultRealm"));
    if (!realm) { WriteDiagnostic(@"Realm: defaultRealm=nil"); return; }
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("beginWriteTransaction"));
    NSArray *cn = @[@"RealmChallengeItem",@"RealmRewardItem",@"RealmStreakChallengeItem",@"RealmDailyStepModel"];
    NSArray *keys = @[@"coins",@"currentCoins",@"step"];
    NSArray *vals = @[@(kInjectedCoins),@(kInjectedCoins),@99999900];
    NSMutableString *dbLog = [NSMutableString string];
    for (NSString *c in cn) {
        Class mc = NSClassFromString(c);
        if (!mc) { [dbLog appendFormat:@"  %@ MISSING\n", c]; continue; }
        id results = ((id (*)(Class,SEL,id))objc_msgSend)(mc, sel_getUid("allObjectsInRealm:"), realm);
        if (!results) { [dbLog appendFormat:@"  %@: no results\n", c]; continue; }
        id it = ((id (*)(id,SEL))objc_msgSend)(results, sel_getUid("objectEnumerator"));
        if (!it) continue;
        int n = 0; id obj;
        while ((obj = ((id (*)(id,SEL))objc_msgSend)(it, sel_getUid("nextObject")))) {
            for (int j=0;j<3;j++) @try{((void(*)(id,SEL,id,id))objc_msgSend)(obj,sel_getUid("setValue:forKey:"),vals[j],keys[j]);}@catch(id e){}
            n++;
        }
        [dbLog appendFormat:@"  %@: %d objects\n", c, n];
    }
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
    WriteDiagnostic([NSString stringWithFormat:@"Realm patch:\n%@", dbLog]);
}

__attribute__((constructor))
static void WinwalkHackInit(void) {
    WriteDiagnostic(@"========== WINWALK HACK V3 LOADED ==========");
    WriteDiagnostic([NSString stringWithFormat:@"Target coins: %ld", (long)kInjectedCoins]);
    DumpCoinClasses();
    swizzleAllCoinClasses();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        installFishHooksDelayed();
    });
    [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t){ patchRealmDB(); }];
    WriteDiagnostic(@"Init complete — log file active.");
}
