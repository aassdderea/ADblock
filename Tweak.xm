#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 持久化存储 Key (记忆库)
// ==========================================
static NSString *const kIsLearnedKey       = @"UniversalSkipper_IsLearned";
static NSString *const kLearnedClassKey    = @"UniversalSkipper_LearnedClass";
static NSString *const kLearnedTextKey     = @"UniversalSkipper_LearnedText";

// 全局状态：是否正在捕获点击
static BOOL isCapturing = NO;

// ==========================================
// 兼容 iOS 13+ 的全局 Window 获取函数
// ==========================================
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
    if (allWindows.count == 0) {
        [allWindows addObjectsFromArray:[UIApplication sharedApplication].windows];
    }
    // 按 windowLevel 降序排列（最上面的窗口优先）
    [allWindows sortUsingComparator:^NSComparisonResult(UIWindow *obj1, UIWindow *obj2) {
        return [@(obj2.windowLevel) compare:@(obj1.windowLevel)];
    }];
    return allWindows;
}
#pragma clang diagnostic pop

// ==========================================
// 核心逻辑 1：顺藤摸瓜，寻找真正响应点击的控件
// ==========================================
static UIView *findRealClickableTarget(UIView *hitView) {
    UIResponder *responder = hitView;
    while (responder) {
        // 1. 如果是 UIControl (如 UIButton)，直接返回
        if ([responder isKindOfClass:[UIControl class]]) {
            return (UIView *)responder;
        }
        // 2. 如果是 UIView 且绑定了 UITapGestureRecognizer，返回它
        if ([responder isKindOfClass:[UIView class]]) {
            UIView *view = (UIView *)responder;
            for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
                if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
                    return view;
                }
            }
        }
        // 3. 继续向上找父视图或下一个响应者
        responder = [responder nextResponder];
    }
    // 如果实在找不到，就返回最初点击的那个 View (兜底)
    return hitView;
}

// ==========================================
// 核心逻辑 2：提取控件的文本特征
// ==========================================
static NSString *extractTextFromView(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) return ((UILabel *)view).text ?: @"";
    if ([view isKindOfClass:[UIButton class]]) return [(UIButton *)view currentTitle] ?: @"";
    
    // 如果真实控件是 UIView，尝试从它的子视图里找 UILabel 的文字
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            return ((UILabel *)sub).text ?: @"";
        }
    }
    return @"";
}

// ==========================================
// 核心逻辑 3：模拟点击 (针对真实控件)
// ==========================================
static void performClickOnTarget(UIView *target) {
    if (!target) return;
    
    // 如果是 UIControl，直接发送点击事件
    if ([target isKindOfClass:[UIControl class]]) {
        [(UIControl *)target sendActionsForControlEvents:UIControlEventTouchUpInside];
        NSLog(@"[UniversalSkipper] ⚡️ 成功触发 UIControl 点击");
        return;
    }
    
    // 如果是带有手势的 UIView，触发手势
    for (UIGestureRecognizer *gesture in target.gestureRecognizers) {
        if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
            typedef void (*MsgSendVoidSEL)(id, SEL, NSInteger);
            ((MsgSendVoidSEL)objc_msgSend)(gesture, @selector(setState:), 3); // Recognized
            typedef void (*MsgSendVoidEvent)(id, SEL, UIEvent *);
            ((MsgSendVoidEvent)objc_msgSend)(gesture, NSSelectorFromString(@"_recognize:"), [UIEvent new]);
            NSLog(@"[UniversalSkipper] ⚡️ 成功触发手势识别器");
            return;
        }
    }
    NSLog(@"[UniversalSkipper] ⚠️ 找到了目标但无法触发: %@", target);
}

// ==========================================
// 执行模式：全局搜索并自动跳过
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
        if ([currentClass isEqualToString:savedClass]) {
            NSString *currentText = extractTextFromView(view);
            // 匹配类名，并且文本包含关系（防止同类名但不同文本的误触）
            if (savedText.length == 0 || [currentText containsString:savedText] || [savedText containsString:currentText] || [currentText containsString:@"跳过"]) {
                performClickOnTarget(view);
                clicked = YES;
                return;
            }
        }
        
        if (weakTraverse) {
            for (UIView *sub in view.subviews) weakTraverse(sub);
        }
    };
    weakTraverse = traverse;
    
    for (UIWindow *window in allWindows) {
        if (clicked) break;
        traverse(window);
    }
}

// ==========================================
// 插件入口
// ==========================================
%ctor {
    NSLog(@"[UniversalSkipper] 🚀 插件已加载！");
    
    BOOL isLearned = [[NSUserDefaults standardUserDefaults] boolForKey:kIsLearnedKey];
    
    if (isLearned) {
        NSLog(@"[UniversalSkipper] 🧠 记忆已存在，进入自动跳过模式");
        // 延迟 1.5 秒后开始自动扫描并点击，持续 8 秒
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __block NSInteger count = 0;
            [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
                count++;
                autoSkipAd();
                if (count >= 16) [timer invalidate]; // 8秒后停止
            }];
        });
    } else {
        NSLog(@"[UniversalSkipper] 🎯 首次运行，等待用户手动点击跳过按钮...");
        isCapturing = YES;
        // 15秒后如果还没捕获到，自动关闭捕获状态，防止后台误捕获
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            isCapturing = NO;
        });
    }
}

// ==========================================
// 核心 Hook：拦截全局触摸事件，捕获你的真实点击
// ==========================================
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig; // 先让系统正常处理点击
    
    // 如果不在捕获模式，或者不是手指抬起的事件，直接忽略
    if (!isCapturing || event.type != UIEventTypeTouches) return;
    
    for (UITouch *touch in event.allTouches) {
        if (touch.phase == UITouchPhaseEnded) {
            CGPoint point = [touch locationInView:nil]; // 获取屏幕绝对坐标
            
            // 遍历所有 Window，找到被点击的最深层 View
            UIView *hitView = nil;
            for (UIWindow *window in getAllWindowsSorted()) {
                hitView = [window hitTest:point withEvent:event];
                if (hitView) break;
            }
            
            if (hitView) {
                // 【关键】顺藤摸瓜找真实按钮
                UIView *realTarget = findRealClickableTarget(hitView);
                NSString *className = NSStringFromClass([realTarget class]);
                
                // 过滤掉明显的非广告控件（如导航栏、TabBar、普通文本）
                if ([className containsString:@"Navigation"] || 
                    [className containsString:@"TabBar"] ||
                    [realTarget isKindOfClass:[UILabel class]]) { // 如果找了一圈还是UILabel，说明它真的只是个文本，跳过
                    continue; 
                }
                
                NSString *text = extractTextFromView(realTarget);
                NSLog(@"[UniversalSkipper] 🕵️ 捕获到点击！真实控件: %@, 文本: %@", className, text);
                
                // 保存记忆
                NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                [defaults setBool:YES forKey:kIsLearnedKey];
                [defaults setObject:className forKey:kLearnedClassKey];
                [defaults setObject:text forKey:kLearnedTextKey];
                [defaults synchronize];
                
                isCapturing = NO; // 停止捕获
                
                // 弹窗通知
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIViewController *topVC = nil;
                    for (UIWindow *w in getAllWindowsSorted()) {
                        UIViewController *vc = w.rootViewController;
                        while (vc.presentedViewController) vc = vc.presentedViewController;
                        if (vc) { topVC = vc; break; }
                    }
                    if (topVC) {
                        NSString *msg = [NSString stringWithFormat:@"已锁定真实控件:\n类名: %@\n特征文本: %@\n\n下次启动将自动为您跳过！", className, text.length > 0 ? text : @"(无)"];
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🎯 捕获成功" message:msg preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"太棒了" style:UIAlertActionStyleDefault handler:nil]];
                        [topVC presentViewController:alert animated:YES completion:nil];
                    }
                });
                break; // 只捕获第一次有效的点击
            }
        }
    }
}
%end

// ==========================================
// 隐藏功能：摇一摇清除记忆
// ==========================================
%hook UIWindow
- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults removeObjectForKey:kIsLearnedKey];
        [defaults removeObjectForKey:kLearnedClassKey];
        [defaults removeObjectForKey:kLearnedTextKey];
        [defaults synchronize];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🧹 记忆已清除" message:@"请重启App并手动点击一次跳过按钮重新学习。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
        
        UIViewController *vc = self.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (vc) [vc presentViewController:alert animated:YES completion:nil];
    }
    %orig;
}
%end
