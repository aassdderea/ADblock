#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 核心升级 1：插件状态分离 (存到独立的文件中，防止被误杀)
// ==========================================
static NSString *const kPluginDomain       = @"com.universalskipper.welove520"; // 插件专属 Domain
static NSString *const kIsLearnedKey       = @"UniversalSkipper_IsLearned";
static NSString *const kLearnedClassKey    = @"UniversalSkipper_LearnedClass";
static NSString *const kLearnedTextKey     = @"UniversalSkipper_LearnedText";

// App 原本的 Domain
static NSString *const kAppDomain          = @"com.welove520.welove";

static BOOL isCapturing = NO;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSArray<UIWindow *> *getAllWindowsSorted(void) {
    NSMutableArray<UIWindow *> *allWindows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                [allWindows addObjectsFromArray:scene.windows];
            }
        }
    }
    if (allWindows.count == 0) [allWindows addObjectsFromArray:[UIApplication sharedApplication].windows];
    [allWindows sortUsingComparator:^NSComparisonResult(UIWindow *obj1, UIWindow *obj2) {
        return [@(obj2.windowLevel) compare:@(obj1.windowLevel)];
    }];
    return allWindows;
}
#pragma clang diagnostic pop

static UIView *findRealClickableTarget(UIView *hitView) {
    UIResponder *responder = hitView;
    while (responder) {
        if ([responder isKindOfClass:[UIControl class]]) return (UIView *)responder;
        if ([responder isKindOfClass:[UIView class]]) {
            UIView *view = (UIView *)responder;
            for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
                if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) return view;
            }
        }
        responder = [responder nextResponder];
    }
    return hitView;
}

static NSString *extractTextFromView(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) return ((UILabel *)view).text ?: @"";
    if ([view isKindOfClass:[UIButton class]]) return [(UIButton *)view currentTitle] ?: @"";
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) return ((UILabel *)sub).text ?: @"";
    }
    return @"";
}

static void performClickOnTarget(UIView *target) {
    if (!target) return;
    if ([target isKindOfClass:[UIControl class]]) {
        [(UIControl *)target sendActionsForControlEvents:UIControlEventTouchUpInside];
        return;
    }
    for (UIGestureRecognizer *gesture in target.gestureRecognizers) {
        if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
            typedef void (*MsgSendVoidSEL)(id, SEL, NSInteger);
            ((MsgSendVoidSEL)objc_msgSend)(gesture, @selector(setState:), 3);
            typedef void (*MsgSendVoidEvent)(id, SEL, UIEvent *);
            ((MsgSendVoidEvent)objc_msgSend)(gesture, NSSelectorFromString(@"_recognize:"), [UIEvent new]);
            return;
        }
    }
    // 兜底物理点击
    CGPoint center = target.center;
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    [touch setValue:[NSValue valueWithCGPoint:center] forKey:@"location"];
    UIEvent *event = [[UIEvent alloc] init];
    [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];
    [target.window sendEvent:event];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        [target.window sendEvent:event];
    });
}

static void autoSkipAd(void) {
    // 从独立的插件 Domain 读取记忆
    NSUserDefaults *pluginDefaults = [[NSUserDefaults alloc] initWithSuiteName:kPluginDomain];
    NSString *savedClass = [pluginDefaults stringForKey:kLearnedClassKey];
    NSString *savedText = [pluginDefaults stringForKey:kLearnedTextKey];
    if (!savedClass) return;
    
    NSArray<UIWindow *> *allWindows = getAllWindowsSorted();
    __block BOOL clicked = NO;
    __weak void (^weakTraverse)(UIView *);
    void (^traverse)(UIView *) = ^(UIView *view) {
        if (!view || view.isHidden || view.alpha < 0.1 || clicked) return;
        NSString *currentClass = NSStringFromClass([view class]);
        NSString *currentText = extractTextFromView(view);
        NSString *baseSavedClass = [[savedClass componentsSeparatedByString:@"_"] firstObject];
        NSString *baseCurrentClass = [[currentClass componentsSeparatedByString:@"_"] firstObject];
        BOOL classMatch = [currentClass isEqualToString:savedClass] || [baseCurrentClass isEqualToString:baseSavedClass] || [currentClass containsString:baseSavedClass] || [savedClass containsString:baseCurrentClass];
        NSString *lowerText = [currentText lowercaseString];
        BOOL textMatch = [lowerText containsString:@"跳过"] || [lowerText containsString:@"skip"] || [lowerText containsString:@"关闭"] || (savedText.length > 0 && ([currentText containsString:savedText] || [savedText containsString:currentText]));
        if (classMatch && (textMatch || savedText.length == 0 || currentText.length == 0)) {
            if (![currentClass containsString:@"Navigation"] && ![currentClass containsString:@"TabBar"]) {
                performClickOnTarget(view);
                clicked = YES;
                return;
            }
        }
        if (weakTraverse) for (UIView *sub in view.subviews) weakTraverse(sub);
    };
    weakTraverse = traverse;
    for (UIWindow *window in allWindows) { if (clicked) break; traverse(window); }
}

// ==========================================
// 核心升级 2：物理级状态重置 (在最早期执行)
// ==========================================
static void resetAppStateForNewUser(void) {
    NSUserDefaults *appDefaults = [[NSUserDefaults alloc] initWithSuiteName:kAppDomain];
    
    // 1. 备份必须保留的核心数据 (防止掉登录)
    // 根据你提供的 plist 分析，这些是维持登录和基础功能的关键 Key
    NSDictionary *backup = @{
        @"login_status": appDefaults[@"login_status"] ?: @"",
        @"flutter.accessToken": appDefaults[@"flutter.accessToken"] ?: @"",
        @"flutter.userId": appDefaults[@"flutter.userId"] ?: @"",
        @"flutter.userIdOtherHalf": appDefaults[@"flutter.userIdOtherHalf"] ?: @"",
        @"flutter.loveSpaceId": appDefaults[@"flutter.loveSpaceId"] ?: @"",
        @"key_last_login_record": appDefaults[@"key_last_login_record"] ?: @"",
        @"love_user_agreement_policy": appDefaults[@"love_user_agreement_policy"] ?: @"",
        @"love_user_agreement_policy2": appDefaults[@"love_user_agreement_policy2"] ?: @"",
        @"DEVICE_TOKEN_MANAGER_DEVICE_TOKEN_KEY": appDefaults[@"DEVICE_TOKEN_MANAGER_DEVICE_TOKEN_KEY"] ?: @""
    };
    
    // 2. 物理清空 App 的 plist 字典 (降维打击，让 App 以为自己是刚安装的新用户)
    NSDictionary *currentDict = [appDefaults dictionaryRepresentation];
    for (NSString *key in currentDict.allKeys) {
        [appDefaults removeObjectForKey:key];
    }
    
    // 3. 把备份的核心数据写回去
    for (NSString *key in backup) {
        id value = backup[key];
        if (value && ![value isEqual:@""]) {
            [appDefaults setObject:value forKey:key];
        }
    }
    
    // 4. 强制同步到磁盘
    [appDefaults synchronize];
    
    NSLog(@"[UniversalSkipper] 🧹 物理清空 App 状态完成，已伪装为新用户并保留登录状态！");
}

%ctor {
    NSLog(@"[UniversalSkipper] 🚀 插件已加载！");
    
    // 【关键】在插件初始化的第一时间，立刻执行物理清空！
    // 这比 Hook NSUserDefaults 要早且彻底得多
    resetAppStateForNewUser();
    
    NSUserDefaults *pluginDefaults = [[NSUserDefaults alloc] initWithSuiteName:kPluginDomain];
    BOOL isLearned = [pluginDefaults boolForKey:kIsLearnedKey];
    
    if (isLearned) {
        NSLog(@"[UniversalSkipper] 🧠 记忆已存在，进入自动跳过模式 (双保险)");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __block NSInteger count = 0;
            [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *timer) {
                count++;
                autoSkipAd();
                if (count >= 25) [timer invalidate];
            }];
        });
    } else {
        NSLog(@"[UniversalSkipper] 🎯 首次运行，等待用户手动点击...");
        isCapturing = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            isCapturing = NO;
        });
    }
}

%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (!isCapturing || event.type != UIEventTypeTouches) return;
    for (UITouch *touch in event.allTouches) {
        if (touch.phase == UITouchPhaseEnded) {
            CGPoint point = [touch locationInView:nil];
            UIView *hitView = nil;
            for (UIWindow *window in getAllWindowsSorted()) {
                hitView = [window hitTest:point withEvent:event];
                if (hitView) break;
            }
            if (hitView) {
                UIView *realTarget = findRealClickableTarget(hitView);
                NSString *className = NSStringFromClass([realTarget class]);
                if ([className containsString:@"Navigation"] || [className containsString:@"TabBar"] || [realTarget isKindOfClass:[UILabel class]]) continue;
                
                NSString *text = extractTextFromView(realTarget);
                
                // 保存到独立的插件 Domain，不再污染 App 的 plist
                NSUserDefaults *pluginDefaults = [[NSUserDefaults alloc] initWithSuiteName:kPluginDomain];
                [pluginDefaults setBool:YES forKey:kIsLearnedKey];
                [pluginDefaults setObject:className forKey:kLearnedClassKey];
                [pluginDefaults setObject:text forKey:kLearnedTextKey];
                [pluginDefaults synchronize];
                
                isCapturing = NO;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIViewController *topVC = nil;
                    for (UIWindow *w in getAllWindowsSorted()) {
                        UIViewController *vc = w.rootViewController;
                        while (vc.presentedViewController) vc = vc.presentedViewController;
                        if (vc) { topVC = vc; break; }
                    }
                    if (topVC) {
                        NSString *msg = [NSString stringWithFormat:@"已锁定: %@\n特征: %@\n\n(已开启物理清空+状态分离)", className, text.length > 0 ? text : @"(无)"];
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🎯 捕获成功" message:msg preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"太棒了" style:UIAlertActionStyleDefault handler:nil]];
                        [topVC presentViewController:alert animated:YES completion:nil];
                    }
                });
                break;
            }
        }
    }
}
%end

%hook UIWindow
- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        NSUserDefaults *pluginDefaults = [[NSUserDefaults alloc] initWithSuiteName:kPluginDomain];
        [pluginDefaults removeObjectForKey:kIsLearnedKey];
        [pluginDefaults removeObjectForKey:kLearnedClassKey];
        [pluginDefaults removeObjectForKey:kLearnedTextKey];
        [pluginDefaults synchronize];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🧹 记忆已清除" message:@"已重置插件记忆。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *vc = self.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (vc) [vc presentViewController:alert animated:YES completion:nil];
    }
    %orig;
}
%end
