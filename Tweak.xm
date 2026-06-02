#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==========================================
// 🎯 自定义跳过按钮关键词（支持模糊匹配）
// ==========================================
static NSArray *kSkipKeywords = nil;

// 全局调试窗口和标签
static UIWindow *g_debugWindow = nil;
static UILabel *g_statusLabel = nil;
static BOOL g_hasClicked = NO; // 防止重复点击

// ==========================================
// 1. 强制创建悬浮提示窗口 (最简单粗暴，保证100%显示)
// ==========================================
static void initDebugWindow() {
    if (g_debugWindow) return;
    
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    g_debugWindow = [[UIWindow alloc] initWithFrame:screenBounds];
    g_debugWindow.windowLevel = UIWindowLevelAlert + 9999; 
    g_debugWindow.backgroundColor = [UIColor clearColor];
    g_debugWindow.userInteractionEnabled = NO;
    g_debugWindow.hidden = NO;
    
    CGFloat width = screenBounds.size.width - 40;
    g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, screenBounds.size.height - 150, width, 60)];
    g_statusLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    g_statusLabel.textColor = [UIColor greenColor];
    g_statusLabel.textAlignment = NSTextAlignmentCenter;
    g_statusLabel.font = [UIFont boldSystemFontOfSize:14];
    g_statusLabel.layer.cornerRadius = 10;
    g_statusLabel.clipsToBounds = YES;
    g_statusLabel.numberOfLines = 0;
    g_statusLabel.alpha = 0;
    [g_debugWindow addSubview:g_statusLabel];
}

static void showDebugMessage(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        initDebugWindow();
        g_statusLabel.text = message;
        g_statusLabel.alpha = 1.0;
        
        [UIView animateWithDuration:0.5 delay:4.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            g_statusLabel.alpha = 0;
        } completion:nil];
    });
}

static void drawRedCircleAtPoint(CGPoint point) {
    dispatch_async(dispatch_get_main_queue(), ^{
        initDebugWindow();
        UIView *circle = [[UIView alloc] initWithFrame:CGRectMake(point.x - 30, point.y - 30, 60, 60)];
        circle.layer.cornerRadius = 30;
        circle.layer.borderWidth = 4;
        circle.layer.borderColor = [UIColor redColor].CGColor;
        circle.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.3];
        circle.userInteractionEnabled = NO;
        [g_debugWindow addSubview:circle];
        
        [UIView animateWithDuration:0.5 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
            circle.alpha = 0;
        } completion:^(BOOL finished) {
            [circle removeFromSuperview];
        }];
    });
}

// ==========================================
// 2. 底层响应链穿透点击
// ==========================================
static void forceClickView(UIView *targetView, CGPoint screenPoint) {
    UITouch *fakeTouch = [[UITouch alloc] init];
    [fakeTouch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    [fakeTouch setValue:[NSValue valueWithCGPoint:[targetView convertPoint:screenPoint fromView:nil]] forKey:@"location"];
    
    NSSet *touches = [NSSet setWithObject:fakeTouch];
    UIEvent *fakeEvent = [[UIEvent alloc] init];
    
    if ([targetView respondsToSelector:@selector(touchesBegan:withEvent:)]) {
        [targetView touchesBegan:touches withEvent:fakeEvent];
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [fakeTouch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        if ([targetView respondsToSelector:@selector(touchesEnded:withEvent:)]) {
            [targetView touchesEnded:touches withEvent:fakeEvent];
        }
    });

    if ([targetView isKindOfClass:[UIButton class]]) {
        [(UIButton *)targetView sendActionsForControlEvents:UIControlEventTouchDown];
        [(UIButton *)targetView sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
    
    for (UIGestureRecognizer *gesture in targetView.gestureRecognizers) {
        if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
            [gesture setState:UIGestureRecognizerStateEnded];
        }
    }
}

// ==========================================
// 3. 深度雷达扫描
// ==========================================
static BOOL scanAndClick(UIView *view) {
    if (!view || view.isHidden || view.alpha < 0.1) return NO;

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
                NSString *msg = [NSString stringWithFormat:@"🎯 发现“%@”\n控件: %@\n已尝试模拟点击（点：%.0f, %.0f）", 
                                 keyword, NSStringFromClass([view class]), screenCenter.x, screenCenter.y];
                showDebugMessage(msg);
                drawRedCircleAtPoint(screenCenter);
                forceClickView(view, screenCenter);
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
            
            // 优先使用 iOS 13+ 的新 API 获取 keyWindow
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in scene.windows) {
                        if (w.isKeyWindow) { keyWindow = w; break; }
                    }
                }
            }
            
            // 【修复点】：使用 Pragma 忽略废弃警告，保留老 API 作为保底兼容
            if (!keyWindow) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                keyWindow = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
            }
            
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

    NSLog(@"[AdBlocker] 🚀 广告拦截雷达已启动: %@", bundleID);

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
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        startRadar();
    });
}
