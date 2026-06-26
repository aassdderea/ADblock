// ==========================================
// Tweak.xm - 通用去开屏广告插件（已知全自动 + 未知首次标记）
// ==========================================
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

// ---------- 可调参数 ----------
#define SKIP_BTN_CHECK_DELAY  1.0   // 广告出现后多久开始寻找跳过按钮
#define HEURISTIC_CHECK_DELAY 1.5   // 延迟检测，给广告视图构建时间
// ------------------------------

#define TESTLOG(fmt, ...) NSLog(@"[AD-BLOCKER] " fmt, ##__VA_ARGS__)

// ========== 辅助：触摸模拟（保留你的红圈调试功能） ==========
static void showTapIndicatorAtPoint(CGPoint screenPoint) {
    CGFloat size = 40.0;
    UIWindow *indicatorWindow = [[UIWindow alloc] initWithFrame:CGRectMake(screenPoint.x - size/2, screenPoint.y - size/2, size, size)];
    indicatorWindow.windowLevel = UIWindowLevelAlert + 100;
    indicatorWindow.backgroundColor = [UIColor clearColor];
    indicatorWindow.userInteractionEnabled = NO;
    indicatorWindow.hidden = NO;
    
    UIView *indicator = [[UIView alloc] initWithFrame:indicatorWindow.bounds];
    indicator.layer.cornerRadius = size / 2;
    indicator.layer.borderWidth = 3.0;
    indicator.layer.borderColor = [UIColor redColor].CGColor;
    indicator.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.3];
    [indicatorWindow addSubview:indicator];
    
    [UIView animateWithDuration:0.3 delay:0.3 options:UIViewAnimationOptionCurveEaseOut animations:^{
        indicator.alpha = 0.0;
        indicator.transform = CGAffineTransformMakeScale(1.5, 1.5);
    } completion:^(BOOL finished) {
        indicatorWindow.hidden = YES;
    }];
}

static void simulateTapAtPoint(CGPoint screenPoint) {
    // 显示红圈反馈（调试用，可注释掉）
    showTapIndicatorAtPoint(screenPoint);
    
    UIWindow *targetWindow = nil;
    CGFloat maxLevel = -1;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (!w.isHidden && w.alpha > 0.01 && w.windowLevel > maxLevel) {
                        maxLevel = w.windowLevel;
                        targetWindow = w;
                    }
                }
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!targetWindow) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.isHidden && w.alpha > 0.01 && w.windowLevel > maxLevel) {
                maxLevel = w.windowLevel;
                targetWindow = w;
            }
        }
    }
#pragma clang diagnostic pop
    
    if (!targetWindow) return;
    
    CGPoint windowPoint = [targetWindow convertPoint:screenPoint fromWindow:nil];
    UIView *hitView = [targetWindow hitTest:windowPoint withEvent:nil];
    if (!hitView) hitView = targetWindow;
    
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:hitView forKey:@"view"];
    [touch setValue:@(windowPoint) forKey:@"locationInWindow"];
    [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    
    UIEvent *event = [[UIEvent alloc] init];
    [event setValue:@[touch] forKey:@"touches"];
    [event setValue:@(UIEventTypeTouches) forKey:@"type"];
    
    [hitView touchesBegan:[NSSet setWithObject:touch] withEvent:event];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        [hitView touchesEnded:[NSSet setWithObject:touch] withEvent:event];
    });
}

// 查找视图树中的“跳过/关闭”按钮
static UIButton *findSkipButtonInView(UIView *view) {
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *title = btn.titleLabel.text;
        if (title && ([title containsString:@"跳过"] || [title containsString:@"Skip"] || [title containsString:@"关闭"])) {
            return btn;
        }
        // 也可以检查 accessibilityLabel
        NSString *accLabel = btn.accessibilityLabel;
        if (accLabel && ([accLabel containsString:@"跳过"] || [accLabel containsString:@"Skip"])) {
            return btn;
        }
    }
    for (UIView *sub in view.subviews) {
        UIButton *result = findSkipButtonInView(sub);
        if (result) return result;
    }
    return nil;
}

// 获取按钮在屏幕上的绝对坐标
static CGPoint screenPointForView(UIView *view) {
    CGRect frameInScreen = [view convertRect:view.bounds toView:nil];
    return CGPointMake(CGRectGetMidX(frameInScreen), CGRectGetMidY(frameInScreen));
}

// ========== 已知 SDK 全自动 Hook ==========
// 以穿山甲 BUSplashAdView 为例，其他 SDK 同理可加
static BOOL knownHookApplied = NO;
static void applyKnownSDKHooks() {
    if (knownHookApplied) return;
    knownHookApplied = YES;
    
    // -------- 穿山甲：BUSplashAdView --------
    Class cls = NSClassFromString(@"BUSplashAdView");
    if (cls) {
        // hook showInWindow: 方法，阻止实际展示并直接通知代理广告已关闭
        __block void (*orig)(id, SEL, UIWindow*) = NULL;
        MSHookMessageEx(cls, @selector(showInWindow:), imp_implementationWithBlock(^(id self, UIWindow *window) {
            TESTLOG(@"🛑 [穿山甲] 拦截 BUSplashAdView showInWindow:");
            // 直接模拟关闭
            id delegate = [self valueForKey:@"delegate"];
            if (delegate && [delegate respondsToSelector:@selector(splashAdDidClose:)]) {
                [delegate performSelector:@selector(splashAdDidClose:) withObject:self];
            }
            // 不调用 %orig，即阻止广告展示
        }), (IMP*)&orig);
    }
    
    // -------- 优量汇：GDTSplashAd --------
    cls = NSClassFromString(@"GDTSplashAd");
    if (cls) {
        MSHookMessageEx(cls, @selector(loadAndShowInWindow:), imp_implementationWithBlock(^(id self, UIWindow *window) {
            TESTLOG(@"🛑 [优量汇] 拦截 GDTSplashAd loadAndShowInWindow:");
            id delegate = [self valueForKey:@"delegate"];
            if (delegate && [delegate respondsToSelector:@selector(splashAdDidDismiss:)]) {
                [delegate performSelector:@selector(splashAdDidDismiss:) withObject:self];
            }
        }), NULL);
    }
    
    // -------- 百度：BaiduMobAdSplash --------
    cls = NSClassFromString(@"BaiduMobAdSplash");
    if (cls) {
        MSHookMessageEx(cls, @selector(showInWindow:), imp_implementationWithBlock(^(id self, UIWindow *window) {
            TESTLOG(@"🛑 [百度] 拦截 BaiduMobAdSplash showInWindow:");
            id delegate = [self valueForKey:@"delegate"];
            if (delegate && [delegate respondsToSelector:@selector(splashAdDidClose:)]) {
                [delegate performSelector:@selector(splashAdDidClose:) withObject:self];
            }
        }), NULL);
    }
    
    // 可继续添加快手、AdMob 等，模式相同
}

// ========== 用户自定义规则（指纹）持久化 ==========
static NSString *documentsPath() {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static NSString *rulesFilePath() {
    return [documentsPath() stringByAppendingPathComponent:@"com.adblocker.rules.plist"];
}

static NSMutableArray<NSDictionary *> *loadCustomRules() {
    NSArray *arr = [NSArray arrayWithContentsOfFile:rulesFilePath()];
    return arr ? [arr mutableCopy] : [NSMutableArray array];
}

static void saveCustomRules(NSArray *rules) {
    [rules writeToFile:rulesFilePath() atomically:YES];
}

// 添加一条规则：记录广告视图的“类名+跳过按钮特征”，以便下次自动跳过
static void addCustomRule(UIView *adView, UIButton *skipBtn) {
    NSMutableDictionary *rule = [NSMutableDictionary dictionary];
    // 广告视图的类名作为主指纹
    rule[@"adViewClass"] = NSStringFromClass([adView class]);
    
    // 记录跳过按钮的可定位特征（类名、标题关键词、相对层级简单描述）
    rule[@"skipBtnClass"] = NSStringFromClass([skipBtn class]);
    if (skipBtn.titleLabel.text) {
        rule[@"skipBtnTitleKeyword"] = skipBtn.titleLabel.text;
    }
    if (skipBtn.accessibilityLabel) {
        rule[@"skipBtnAccLabelKeyword"] = skipBtn.accessibilityLabel;
    }
    // 也可以存一下按钮在屏幕上的区域比例，这里从简
    
    NSMutableArray *rules = loadCustomRules();
    // 避免重复添加相同类名的规则
    BOOL exists = NO;
    for (NSDictionary *r in rules) {
        if ([r[@"adViewClass"] isEqualToString:rule[@"adViewClass"]]) {
            exists = YES;
            break;
        }
    }
    if (!exists) {
        [rules addObject:rule];
        saveCustomRules(rules);
        TESTLOG(@"✅ 已添加自定义规则：%@", rule);
    }
}

// 根据规则尝试自动跳过广告
static BOOL tryAutoSkipWithRules(UIView *adView) {
    NSArray *rules = loadCustomRules();
    for (NSDictionary *rule in rules) {
        NSString *clsName = rule[@"adViewClass"];
        if ([NSStringFromClass([adView class]) isEqualToString:clsName]) {
            TESTLOG(@"🎯 命中自定义规则，尝试自动跳过: %@", clsName);
            // 寻找跳过按钮
            UIButton *skipBtn = nil;
            NSString *btnCls = rule[@"skipBtnClass"];
            // 优先按类名查找
            if (btnCls) {
                for (UIView *sub in adView.subviews) {
                    if ([NSStringFromClass([sub class]) isEqualToString:btnCls] && [sub isKindOfClass:[UIButton class]]) {
                        skipBtn = (UIButton *)sub;
                        break;
                    }
                }
            }
            if (!skipBtn) {
                // 回退到全视图遍历标题关键词
                skipBtn = findSkipButtonInView(adView);
            }
            if (skipBtn) {
                CGPoint pt = screenPointForView(skipBtn);
                simulateTapAtPoint(pt);
                return YES;
            } else {
                TESTLOG(@"⚠️ 规则存在但未找到跳过按钮，移除视图");
                [adView removeFromSuperview];
                return YES;
            }
        }
    }
    return NO;
}

// ========== 未知广告标记 UI ==========
static void showMarkUI(UIView *suspiciousView) {
    UIWindow *alertWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    alertWin.windowLevel = UIWindowLevelAlert + 200;
    alertWin.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    alertWin.hidden = NO;
    
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    alertWin.rootViewController = vc;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"发现疑似开屏广告" message:@"要自动跳过这类广告吗？" preferredStyle:UIAlertControllerStyleAlert];
    
    __weak UIView *weakAdView = suspiciousView;
    __weak UIWindow *weakWin = alertWin;
    
    UIAlertAction *skipOnce = [UIAlertAction actionWithTitle:@"仅跳过本次" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UIButton *skipBtn = findSkipButtonInView(weakAdView);
        if (skipBtn) {
            simulateTapAtPoint(screenPointForView(skipBtn));
        }
        weakWin.hidden = YES;
    }];
    
    UIAlertAction *skipAlways = [UIAlertAction actionWithTitle:@"总是自动跳过" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UIButton *skipBtn = findSkipButtonInView(weakAdView);
        if (skipBtn) {
            addCustomRule(weakAdView, skipBtn);
            simulateTapAtPoint(screenPointForView(skipBtn));
        }
        weakWin.hidden = YES;
    }];
    
    UIAlertAction *notAd = [UIAlertAction actionWithTitle:@"不是广告" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        weakWin.hidden = YES;
    }];
    
    [alert addAction:skipOnce];
    [alert addAction:skipAlways];
    [alert addAction:notAd];
    
    [vc presentViewController:alert animated:YES completion:nil];
}

// ========== 启发式检测：判断一个视图是否可能是开屏广告 ==========
static BOOL isLikelyAdView(UIView *view) {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    // 1. 覆盖大部分屏幕（面积 > 80%）
    if (view.frame.size.width < screenBounds.size.width * 0.8 ||
        view.frame.size.height < screenBounds.size.height * 0.8) {
        return NO;
    }
    
    // 2. 查找是否有“跳过/关闭”文字
    UIButton *skip = findSkipButtonInView(view);
    if (skip) {
        return YES;
    }
    
    // 3. 类名包含 Splash / Ad 等关键词
    NSString *className = NSStringFromClass([view class]);
    NSArray *keywords = @[@"Splash", @"Ad", @"Launch", @"Popup"];
    for (NSString *kw in keywords) {
        if ([className rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    
    return NO;
}

// ========== 监听新窗口/视图 ==========
static void startAdDetection() {
    // 延迟执行，等启动广告完全加载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(HEURISTIC_CHECK_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 遍历当前所有窗口的最顶层视图
        UIWindow *topWindow = nil;
        CGFloat maxLevel = -1;
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in scene.windows) {
                        if (!w.isHidden && w.alpha > 0.01 && w.windowLevel > maxLevel) {
                            maxLevel = w.windowLevel;
                            topWindow = w;
                        }
                    }
                }
            }
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (!topWindow) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (!w.isHidden && w.alpha > 0.01 && w.windowLevel > maxLevel) {
                    maxLevel = w.windowLevel;
                    topWindow = w;
                }
            }
        }
#pragma clang diagnostic pop
        
        if (!topWindow) return;
        
        // 直接在根视图的子视图中查找候选广告视图
        UIView *root = topWindow.rootViewController.view ?: topWindow;
        for (UIView *sub in root.subviews) {
            if (isLikelyAdView(sub)) {
                // 先尝试用户规则自动跳过
                if (tryAutoSkipWithRules(sub)) {
                    continue;
                }
                // 未命中规则，弹出标记 UI
                showMarkUI(sub);
            }
        }
    });
}

// ========== Hook UIWindow 的 makeKeyAndVisible 来拦截广告窗口 ==========
%hook UIWindow
- (void)makeKeyAndVisible {
    %orig;
    // 如果新窗口 windowLevel 较高且全屏，可能是广告专用窗口
    if (self.frame.size.width >= [UIScreen mainScreen].bounds.size.width * 0.8 &&
        self.frame.size.height >= [UIScreen mainScreen].bounds.size.height * 0.8 &&
        self.windowLevel > UIWindowLevelNormal + 1) {
        TESTLOG(@"🔍 检测到高等级全屏窗口: %@", NSStringFromClass([self class]));
        // 延迟一下，等窗口内容渲染
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SKIP_BTN_CHECK_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UIView *sub in self.subviews) {
                if (isLikelyAdView(sub)) {
                    if (tryAutoSkipWithRules(sub)) {
                        return;
                    }
                    showMarkUI(sub);
                }
            }
        });
    }
}
%end

// ========== 启动入口 ==========
%ctor {
    TESTLOG(@"🚀 通用去广告插件已加载");
    // 首先应用已知 SDK 的 Hook
    applyKnownSDKHooks();
    
    // 监听 App 激活，执行启发式检测
    // 这里 hook UIApplication 的 applicationDidBecomeActive: 来触发一次检测
    // 为避免多次触发，使用一次性标志
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class appDelegateClass = [[UIApplication sharedApplication].delegate class];
        if (appDelegateClass) {
            // 简单的替换方法（如果已有其他 hook 可能冲突，用 block 形式更好）
            // 这里改用订阅通知更安全
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification * _Nonnull note) {
                TESTLOG(@"📱 App 变为活跃，开始广告检测");
                startAdDetection();
            }];
        }
    });
}
