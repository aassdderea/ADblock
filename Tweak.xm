#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kIsLearnedKey       = @"UniversalSkipper_IsLearned";
static NSString *const kLearnedClassKey    = @"UniversalSkipper_LearnedClass";
static NSString *const kLearnedTextKey     = @"UniversalSkipper_LearnedText";
static NSString *const kFakeNewUserKey     = @"UniversalSkipper_FakeNewUser";

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
        NSLog(@"[UniversalSkipper] ⚡️ 触发 UIControl");
        return;
    }
    for (UIGestureRecognizer *gesture in target.gestureRecognizers) {
        if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
            typedef void (*MsgSendVoidSEL)(id, SEL, NSInteger);
            ((MsgSendVoidSEL)objc_msgSend)(gesture, @selector(setState:), 3);
            typedef void (*MsgSendVoidEvent)(id, SEL, UIEvent *);
            ((MsgSendVoidEvent)objc_msgSend)(gesture, NSSelectorFromString(@"_recognize:"), [UIEvent new]);
            NSLog(@"[UniversalSkipper] ⚡️ 触发手势");
            return;
        }
    }
    // 兜底：模拟物理点击坐标
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
    NSLog(@"[UniversalSkipper] ⚡️ 模拟物理点击坐标");
}

// ==========================================
// 核心升级：模糊匹配引擎
// ==========================================
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
        NSString *currentText = extractTextFromView(view);
        
        // 1. 类名模糊匹配：只要保存的类名包含当前类名，或者当前类名包含保存的类名（去掉内存地址后缀）
        NSString *baseSavedClass = [[savedClass componentsSeparatedByString:@"_"] firstObject];
        NSString *baseCurrentClass = [[currentClass componentsSeparatedByString:@"_"] firstObject];
        BOOL classMatch = [currentClass isEqualToString:savedClass] || 
                          [baseCurrentClass isEqualToString:baseSavedClass] ||
                          [currentClass containsString:baseSavedClass] || 
                          [savedClass containsString:baseCurrentClass];
        
        // 2. 文本匹配：包含“跳过”、“skip”、“关闭”等关键字
        NSString *lowerText = [currentText lowercaseString];
        BOOL textMatch = [lowerText containsString:@"跳过"] || 
                         [lowerText containsString:@"skip"] || 
                         [lowerText containsString:@"关闭"] ||
                         (savedText.length > 0 && ([currentText containsString:savedText] || [savedText containsString:currentText]));
        
        // 3. 综合判断：类名匹配 且 (文本匹配 或 保存时就没有文本)
        if (classMatch && (textMatch || savedText.length == 0 || currentText.length == 0)) {
            // 确保不是普通的导航栏或 TabBar
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

%hook NSUserDefaults
- (id)objectForKey:(NSString *)defaultName {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kFakeNewUserKey]) {
        NSString *lowerKey = [defaultName lowercaseString];
        if ([lowerKey containsString:@"firstlaunch"] || [lowerKey containsString:@"haslaunched"] || 
            [lowerKey containsString:@"isfirst"] || [lowerKey containsString:@"newuser"] || [lowerKey containsString:@"guide"]) {
            return nil;
        }
    }
    return %orig;
}
%end

%ctor {
    NSLog(@"[UniversalSkipper] 🚀 插件已加载！");
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL isLearned = [defaults boolForKey:kIsLearnedKey];
    
    if (![defaults objectForKey:kFakeNewUserKey]) {
        [defaults setBool:YES forKey:kFakeNewUserKey];
        [defaults synchronize];
    }
    
    if (isLearned) {
        NSLog(@"[UniversalSkipper] 🧠 记忆已存在，进入自动跳过模式");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __block NSInteger count = 0;
            [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *timer) {
                count++;
                autoSkipAd();
                if (count >= 25) [timer invalidate]; // 扫描 7.5 秒
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
                        NSString *msg = [NSString stringWithFormat:@"已锁定: %@\n特征: %@\n\n(已开启模糊匹配与伪装新用户)", className, text.length > 0 ? text : @"(无)"];
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
        [defaults setBool:YES forKey:kFakeNewUserKey];
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
