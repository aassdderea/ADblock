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
    // 使用最基础的初始化，设置极高的 windowLevel，确保永远悬浮在最顶层
    g_debugWindow = [[UIWindow alloc] initWithFrame:screenBounds];
    g_debugWindow.windowLevel = UIWindowLevelAlert + 9999; 
    g_debugWindow.backgroundColor = [UIColor clearColor];
    g_debugWindow.userInteractionEnabled = NO; // 穿透点击
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

// 显示底部调试提示
static void showDebugMessage(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        initDebugWindow();
        g_statusLabel.text = message;
        g_statusLabel.alpha = 1.0;
        
        // 4秒后自动淡出
        [UIView animateWithDuration:0.5 delay:4.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            g_statusLabel.alpha = 0;
        } completion:nil];
    });
}

// 在指定坐标画红圈
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
// 2. 底层响应链穿透点击 (无视 iOS 15+ 的 KVC 限制)
// ==========================================
static void forceClickView(UIView *targetView, CGPoint screenPoint) {
    // 方式A：直接调用视图的触摸事件 (最有效)
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

    // 方式B：如果是标准按钮，直接发送 Action
    if ([targetView isKindOfClass:[UIButton class]]) {
        [(UIButton *)targetView sendActionsForControlEvents:UIControlEventTouchDown];
        [(UIButton *)targetView sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
    
    // 方式C：尝试调用点击手势
    for (UIGestureRecognizer *gesture in targetView.gestureRecognizers) {
        if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
            [gesture setState:UIGestureRecognizerStateEnded];
        }
    }
}

// ==========================================
// 3. 深度雷达扫描 (递归查找所有可能的文字载体)
// ==========================================
static BOOL scanAndClick(UIView *view) {
    if (!view || view.isHidden || view.alpha < 0.1) return NO;

    // 获取视图在屏幕上的绝对中心点
    CGRect frameInWindow = [view convertRect:view.bounds toView:nil];
    CGPoint screenCenter = CGPointMake(CGRectGetMidX(frameInWindow), CGRectGetMidY(frameInWindow));
    
    // 过滤掉屏幕外或太小的视图
    if (frameInWindow.size.width < 10 || frameInWindow.size.height < 10) return NO;
    if (!CGRectContainsPoint([UIScreen mainScreen].bounds, screenCenter)) return NO;

    NSString *textToCheck = nil;

    // 提取文字：UILabel
    if ([view isKindOfClass:[UILabel class]]) {
        textToCheck = ((UILabel *)view).text;
    } 
    // 提取文字：UIButton
    else if ([view isKindOfClass:[UIButton class]]) {
        textToCheck = [(UIButton *)view currentTitle];
        if (!textToCheck) textToCheck = [(UIButton *)view titleLabel].text;
    }
    // 提取文字：无障碍标签 (很多自定义广告View把文字写在这里)
    if (!textToCheck && view.isAccessibilityElement) {
        textToCheck = view.accessibilityLabel;
    }

    // 匹配关键词
    if (textToCheck.length > 0) {
        for (NSString *keyword in kSkipKeywords) {
            if ([textToCheck containsString:keyword]) {
                NSString *msg = [NSString stringWithFormat:@"🎯 发现“%@”\n控件: %@\n已尝试模拟点击（点：%.0f, %.0f）", 
                                 keyword, NSStringFromClass([view class]), screenCenter.x, screenCenter.y];
                showDebugMessage(msg);
                drawRedCircleAtPoint(screenCenter);
                forceClickView(view, screenCenter);
                return YES; // 找到并点击，停止扫描
            }
        }
    }

    // 递归扫描子视图 (从后往前扫，因为后添加的视图通常在最上层)
    for (NSInteger i = view.subviews.count - 1; i >= 0; i--) {
        if (scanAndClick(view.subviews[i])) return YES;
    }
    
    return NO;
}

// ==========================================
// 4. 启动高频雷达定时器 (App 启动后狂扫 10 秒)
// ==========================================
static void startRadar() {
    dispatch_async(dispatch_get_main_queue(), ^{
        __block int scanCount = 0;
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer * _Nonnull timer) {
            scanCount++;
            if (scanCount > 50 || g_hasClicked) { // 扫描 50 次 (10秒) 或 已经点击过，就停止
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
            if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;
            
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
    // 保护系统进程
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSArray *blacklist = @[@"com.apple.springboard", @"com.apple.Preferences", @"com.apple.mobilesafari"];
    if (!bundleID || [blacklist containsObject:bundleID]) return;

    NSLog(@"[AdBlocker] 🚀 广告拦截雷达已启动: %@", bundleID);

    // 初始化关键词
    kSkipKeywords = @[
        @"跳过", @"关闭", @"Skip", @"skip",
        @"s", @"S", @"秒", @"跳过广告", @"关闭广告"
    ];

    // 监听 App 进入前台事件，每次回到前台都重新启动雷达
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification 
                                                      object:nil 
                                                       queue:[NSOperationQueue mainQueue] 
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        g_hasClicked = NO;
        startRadar();
    }];
    
    // 首次启动
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        startRadar();
    });
}
