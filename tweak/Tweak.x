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

static void PatchRealmDB(void) {
    WriteDiagnostic(@"─── Cycle ───");
    
    Class realmClass = NSClassFromString(@"RLMRealm");
    if (!realmClass) { WriteDiagnostic(@"RLMRealm MISSING"); return; }
    
    id realm = ((id (*)(Class, SEL))objc_msgSend)(realmClass, sel_getUid("defaultRealm"));
    if (!realm) { WriteDiagnostic(@"defaultRealm=nil"); return; }
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("beginWriteTransaction"));
    
    // Every possible coin/step key — try all on every object
    NSArray *allKeys = @[
        @"coins", @"currentCoins", @"step", @"coinBalance",
        @"coinValue", @"rewardCoins", @"remainingCoin",
        @"currentStep", @"totalCoins", @"earnedCoins",
        @"bonusCoins", @"dailyCoins", @"distance",
        @"calories", @"activeTime"
    ];
    
    // All 9 Realm classes discovered in V4
    NSArray *classNames = @[
        @"winwalk.RealmChallengeItem",
        @"winwalk.RealmRewardItem",
        @"winwalk.RealmStreakChallengeItem",
        @"winwalk.RealmDailyStepModel",
        @"winwalk.RealmRewardShop",
        @"winwalk.RealmGiftCardItemDetail",
        @"winwalk.RealmGiftCardItem",
        @"winwalk.RealmActor",
        @"winwalk.RealmConfiguration"
    ];
    
    int totalObjects = 0;
    int totalSetters = 0;
    
    for (NSString *cn in classNames) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        
        id results = ((id (*)(Class, SEL, id))objc_msgSend)(cls, sel_getUid("allObjectsInRealm:"), realm);
        if (!results) continue;
        
        id enumerator = ((id (*)(id, SEL))objc_msgSend)(results, sel_getUid("objectEnumerator"));
        if (!enumerator) continue;
        
        int objCount = 0;
        int keyHits = 0;
        NSMutableString *hitKeys = [NSMutableString string];
        BOOL firstObj = YES;
        
        id obj;
        while ((obj = ((id (*)(id, SEL))objc_msgSend)(enumerator, sel_getUid("nextObject")))) {
            for (NSString *key in allKeys) {
                NSNumber *val = @(kInjectedCoins);
                if ([key.lowercaseString containsString:@"step"]) val = @99999900;
                
                // Try setting — KVC throws if key doesn't exist
                @try {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(obj, sel_getUid("setValue:forKey:"), val, key);
                    keyHits++;
                    if (firstObj) [hitKeys appendFormat:@" %@", key];
                } @catch (id e) {
                    // Key doesn't exist on this class — expected for most
                }
            }
            firstObj = NO;
            objCount++;
        }
        
        if (objCount > 0) {
            totalObjects += objCount;
            totalSetters += keyHits;
            WriteDiagnostic([NSString stringWithFormat:@"  %@: %d objs, %d sets, keys=%@",
                             cn, objCount, keyHits, hitKeys.length ? hitKeys : @"(none)"]);
        }
    }
    
    ((void (*)(id, SEL))objc_msgSend)(realm, sel_getUid("commitWriteTransaction"));
    WriteDiagnostic([NSString stringWithFormat:@"TOTAL: %d objects, %d values written", totalObjects, totalSetters]);
}

__attribute__((constructor))
static void WinwalkHackInit(void) {
    WriteDiagnostic(@"========== V5 — BRUTE FORCE KVC ==========");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        PatchRealmDB();
        [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t) {
            PatchRealmDB();
        }];
    });
}
