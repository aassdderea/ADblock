#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==========================================
// 🎯 自定义跳过按钮关键词（支持模糊匹配）
// ==========================================
static NSArray *kSkipKeywords = nil;

// 全局调试层和状态
static UIView *g_debugOverlay = nil;
static UILabel *g_statusLabel = nil;
static BOOL g_hasClicked = NO;

// ==========================================
// 1. 安全的悬浮提示层 (加在 keyWindow 上，防闪退)
// ==========================================
static void initDebugOverlay() {
    if (g_debugOverlay) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
            }
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
        
        if (!keyWindow) return;

        g_debugOverlay = [[UIView alloc] initWithFrame:keyWindow.bounds];
        g_debugOverlay.backgroundColor = [UIColor clearColor];
        g_debugOverlay.userInteractionEnabled = NO;
        g_debugOverlay.layer.zPosition = 99999;
        [keyWindow addSubview:g_debugOverlay];
        
        CGFloat width = keyWindow.bounds.size.width - 40;
        g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, keyWindow.bounds.size.height - 150, width, 60)];
        g_statusLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        g_statusLabel.textColor = [UIColor greenColor];
        g_statusLabel.textAlignment = NSTextAlignmentCenter;
        g_statusLabel.font = [UIFont boldSystemFontOfSize:14];
        g_statusLabel.layer.cornerRadius = 10;
        g_statusLabel.clipsToBounds = YES;
        g_statusLabel.numberOfLines = 0;
        g_statusLabel.alpha = 0;
        [g_debugOverlay addSubview:g_statusLabel];
    });
}

static void showDebugMessage(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_debugOverlay) initDebugOverlay();
        if (!g_statusLabel) return;
        
        g_statusLabel.text = message;
        g_statusLabel.alpha = 1.0;
        
        [UIView animateWithDuration:0.5 delay:4.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            g_statusLabel.alpha = 0;
        } completion:nil];
    });
}

static void drawRedCircleAtPoint(CGPoint point) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_debugOverlay) initDebugOverlay();
        if (!g_debugOverlay) return;
        
        UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(point.x - 30, point.y - 30, 60, 60)];
        circle.layer.cornerRadius = 30;
        circle.layer.borderWidth = 4;
        circle.layer.borderColor = [UIColor redColor].CGColor;
        circle.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.3];
        circle.userInteractionEnabled = NO;
        [g_debugOverlay addSubview:circle];
        
        [UIView animateWithDuration:0.5 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
            circle.alpha = 0;
        } completion:^(BOOL finished) {
            [circle removeFromSuperview];
        }];
    });
}

// ==========================================
// 2. 绝对安全的点击触发机制 (彻底移除 ARC 报错代码和导致闪退的私有 API)
// ==========================================
static void safeTriggerClick(UIView *targetView) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 方式A：如果是标准按钮/控件，直接发送原生点击事件
            if ([targetView isKindOfClass:[UIControl class]]) {
                [(UIControl *)targetView sendActionsForControlEvents:UIControlEventTouchDown];
                [(UIControl *)targetView sendActionsForControlEvents:UIControlEventTouchUpInside];
                return;
            }
            
            // 方式B：调用 iOS 无障碍激活 (针对自定义 View 极其有效)
            if ([targetView respondsToSelector:@selector(accessibilityActivate)]) {
                if ([targetView accessibilityActivate]) return;
            }
            
            // 方式C：KVC 状态机欺骗法 (安全触发 UITapGestureRecognizer，无 ARC 报错)
            for (UIGestureRecognizer *gesture in targetView.gestureRecognizers) {
                if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
                    [gesture setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                    return;
                }
            }
            
            // 方式D：如果当前 View 没手势，尝试向上找它的父视图
            UIView *superView = targetView.superview;
            while (superView) {
                for (UIGestureRecognizer *gesture in superView.gestureRecognizers) {
                    if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
                        [gesture setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                        return;
                    }
                }
                if ([superView isKindOfClass:[UIControl class]]) {
                    [(UIControl *)superView sendActionsForControlEvents:UIControlEventTouchUpInside];
                    return;
                }
                superView = superView.superview;
            }
            
        } @catch (NSException *exception) {
            NSLog(@"[AdBlocker] ⚠️ 触发点击时捕获异常: %@", exception);
        }
    });
}

// ==========================================
// 3. 深度雷达扫描
// ==========================================
static BOOL scanAndClick(UIView *view) {
    if (!view || view.isHidden || view.alpha < 0.1) return NO;
    if (view == g_debugOverlay) return NO;

    CGRect frameInWindow = [view convertRect:view.bounds toView:nil];
    CGPoint screenCenter = CGPointMake(CGRectGetMidX(frameInWindow), CGRectGetMidY(frameInWindow));
    
    if (frameInWindow.size.width < 10 || frameInWindow.size.height < 10) return NO;
    if (!CGRectContainsPoint([UIScreen mainScreen].bounds, screenCenter)) return NO;

    NSString *textToCheck = nil;

    if ([view isKindOfClass:[UILabel class]]) {
        textToCheck = ((UILabel *)view).text;
    } 
    else if ([view isKindOfClass:[UIButton class]]) {
        textToCheck = [(UIButton *)view currentTitle];
        if (!textToCheck) textToCheck = [(UIButton *)view titleLabel].text;
    }
    if (!textToCheck && view.isAccessibilityElement) {
        textToCheck = view.accessibilityLabel;
    }

    if (textToCheck.length > 0) {
        for (NSString *keyword in kSkipKeywords) {
            if ([textToCheck containsString:keyword]) {
                NSString *msg = [NSString stringWithFormat:@"🎯 发现“%@”\n控件: %@\n已执行安全点击", 
                                 keyword, NSStringFromClass([view class])];
                showDebugMessage(msg);
                drawRedCircleAtPoint(screenCenter);
                safeTriggerClick(view);
                return YES;
            }
        }
    }

    for (NSInteger i = view.subviews.count - 1; i >= 0; i--) {
        if (scanAndClick(view.subviews[i])) return YES;
    }
    
    return NO;
}

// ==========================================
// 4. 启动高频雷达定时器
// ==========================================
static void startRadar() {
    dispatch_async(dispatch_get_main_queue(), ^{
        __block int scanCount = 0;
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer * _Nonnull timer) {
            scanCount++;
            if (scanCount > 50 || g_hasClicked) {
                [timer invalidate];
                return;
            }
            
            UIWindow *keyWindow = nil;
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in scene.windows) {
                        if (w.isKeyWindow) { keyWindow = w; break; }
                    }
                }
            }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
            
            if (keyWindow) {
                if (scanAndClick(keyWindow)) {
                    g_hasClicked = YES;
                    [timer invalidate];
                }
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    });
}

// ==========================================
// 5. 插件入口
// ==========================================
%ctor {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSArray *blacklist = @[@"com.apple.springboard", @"com.apple.Preferences", @"com.apple.mobilesafari"];
    if (!bundleID || [blacklist containsObject:bundleID]) return;

    NSLog(@"[AdBlocker] 🚀 安全版广告拦截雷达已启动: %@", bundleID);

    kSkipKeywords = @[
        @"跳过", @"关闭", @"Skip", @"skip",
        @"s", @"S", @"秒", @"跳过广告", @"关闭广告"
    ];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification 
                                                      object:nil 
                                                       queue:[NSOperationQueue mainQueue] 
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        g_hasClicked = NO;
        startRadar();
    }];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        startRadar();
    });
}
