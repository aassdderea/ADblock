#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 持久化存储 Key (记忆库)
// ==========================================
static NSString *const kIsLearnedKey       = @"UniversalSkipper_IsLearned";
static NSString *const kLearnedClassKey    = @"UniversalSkipper_LearnedClass";
static NSString *const kLearnedTextKey     = @"UniversalSkipper_LearnedText";
static NSString *const kFakeNewUserKey     = @"UniversalSkipper_FakeNewUser"; // 伪装新用户开关

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
}

static void autoSkipAd(void) {
    NSString *savedClass = [[NSUserDefaults standardUserDefaults] stringForKey:kLearnedClassKey];
    NSString *savedText = [[NSUserDefaults standardUserDefaults] stringForKey:kLearnedTextKey];
    if (!savedClass) return;
    
    NSArray<UIWindow *> *allWindows = getAllWindowsSorted();
    __block BOOL clicked = NO;
    __weak void (^weakTraverse)(UIView *);
    void (^traverse)(UIView *) = ^(UIView *view) {
        if (!view || view.isHidden || view.alpha < 0.1 || clicked) return;
        NSString *currentClass = NSStringFromClass([view class]);
        if ([currentClass isEqualToString:savedClass]) {
            NSString *currentText = extractTextFromView(view);
            if (savedText.length == 0 || [currentText containsString:savedText] || [savedText containsString:currentText] || [currentText containsString:@"跳过"]) {
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
// 核心 Hook：拦截 App 读取偏好设置，伪装新用户
// ==========================================
%hook NSUserDefaults
- (id)objectForKey:(NSString *)defaultName {
    // 如果开启了伪装新用户功能
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kFakeNewUserKey]) {
        // 拦截 App 常见的“是否首次启动”判断 Key
        // (这里列举了一些常见的，如果App用了别的，可以在日志里看)
        NSString *lowerKey = [defaultName lowercaseString];
        if ([lowerKey containsString:@"firstlaunch"] || 
            [lowerKey containsString:@"haslaunched"] || 
            [lowerKey containsString:@"isfirst"] ||
            [lowerKey containsString:@"newuser"] ||
            [lowerKey containsString:@"guide"]) {
            NSLog(@"[UniversalSkipper] 🎭 拦截到状态查询: %@ -> 伪装返回 nil (新用户)", defaultName);
            return nil; // 返回 nil，让 App 以为是首次启动
        }
    }
    return %orig;
}
%end

%ctor {
    NSLog(@"[UniversalSkipper] 🚀 插件已加载！");
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL isLearned = [defaults boolForKey:kIsLearnedKey];
    BOOL isFakeNewUser = [defaults boolForKey:kFakeNewUserKey];
    
    // 默认开启伪装新用户功能 (如果没有设置过)
    if (![defaults objectForKey:kFakeNewUserKey]) {
        [defaults setBool:YES forKey:kFakeNewUserKey];
        [defaults synchronize];
        isFakeNewUser = YES;
    }
    
    if (isFakeNewUser) {
        NSLog(@"[UniversalSkipper] 🎭 伪装新用户模式已开启，App 可能会以为你是第一次打开！");
    }
    
    if (isLearned) {
        NSLog(@"[UniversalSkipper] 🧠 记忆已存在，进入自动跳过模式");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __block NSInteger count = 0;
            [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
                count++;
                autoSkipAd();
                if (count >= 16) [timer invalidate];
            }];
        });
    } else {
        NSLog(@"[UniversalSkipper] 🎯 首次运行，等待用户手动点击跳过按钮...");
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
                NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                [defaults setBool:YES forKey:kIsLearnedKey];
                [defaults setObject:className forKey:kLearnedClassKey];
                [defaults setObject:text forKey:kLearnedTextKey];
                [defaults synchronize];
                isCapturing = NO;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIViewController *topVC = nil;
                    for (UIWindow *w in getAllWindowsSorted()) {
                        UIViewController *vc = w.rootViewController;
                        while (vc.presentedViewController) vc = vc.presentedViewController;
                        if (vc) { topVC = vc; break; }
                    }
                    if (topVC) {
                        NSString *msg = [NSString stringWithFormat:@"已锁定: %@\n特征: %@\n\n(已自动开启伪装新用户模式)", className, text.length > 0 ? text : @"(无)"];
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
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults removeObjectForKey:kIsLearnedKey];
        [defaults removeObjectForKey:kLearnedClassKey];
        [defaults removeObjectForKey:kLearnedTextKey];
        [defaults setBool:YES forKey:kFakeNewUserKey]; // 摇一摇时保持伪装开启
        [defaults synchronize];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🧹 记忆已清除" message:@"已重置并开启伪装新用户模式。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *vc = self.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (vc) [vc presentViewController:alert animated:YES completion:nil];
    }
    %orig;
}
%end
