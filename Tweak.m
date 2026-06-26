// ==========================================
// Tweak.m - 通用去开屏广告插件（纯 Runtime，无 Substrate 依赖）
// 适用于 TrollStore + TrollFools 注入
// ==========================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------- 可调参数 ----------
#define SKIP_BTN_CHECK_DELAY  1.0   // 广告出现后多久开始寻找跳过按钮
#define HEURISTIC_CHECK_DELAY 1.5   // 延迟检测，给广告视图构建时间
// ------------------------------

#define TESTLOG(fmt, ...) NSLog(@"[AD-BLOCKER] " fmt, ##__VA_ARGS__)

// ========== 辅助：方法替换（等效 MSHookMessageEx） ==========
static void replaceInstanceMethod(Class cls, SEL sel, id newImpBlock, IMP *origPtr) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP newImp = imp_implementationWithBlock(newImpBlock);
    if (origPtr) *origPtr = method_setImplementation(m, newImp);
    else method_setImplementation(m, newImp);
}

// ========== 辅助：触摸模拟及红圈调试 ==========
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
static BOOL knownHookApplied = NO;
static void applyKnownSDKHooks() {
    if (knownHookApplied) return;
    knownHookApplied = YES;
    
    Class cls;
    
    // 穿山甲：BUSplashAdView
    cls = NSClassFromString(@"BUSplashAdView");
    if (cls) {
        replaceInstanceMethod(cls, @selector(showInWindow:), ^(id self, UIWindow *window) {
            TESTLOG(@"🛑 [穿山甲] 拦截 BUSplashAdView showInWindow:");
            id delegate = [self valueForKey:@"delegate"];
            if (delegate && [delegate respondsToSelector:@selector(splashAdDidClose:)]) {
                [delegate performSelector:@selector(splashAdDidClose:) withObject:self];
            }
        }, NULL);
    }
    
    // 优量汇：GDTSplashAd
    cls = NSClassFromString(@"GDTSplashAd");
    if (cls) {
        replaceInstanceMethod(cls, @selector(loadAndShowInWindow:), ^(id self, UIWindow *window) {
            TESTLOG(@"🛑 [优量汇] 拦截 GDTSplashAd loadAndShowInWindow:");
            id delegate = [self valueForKey:@"delegate"];
            if (delegate && [delegate respondsToSelector:@selector(splashAdDidDismiss:)]) {
                [delegate performSelector:@selector(splashAdDidDismiss:) withObject:self];
            }
        }, NULL);
    }
    
    // 百度：BaiduMobAdSplash
    cls = NSClassFromString(@"BaiduMobAdSplash");
    if (cls) {
        replaceInstanceMethod(cls, @selector(showInWindow:), ^(id self, UIWindow *window) {
            TESTLOG(@"🛑 [百度] 拦截 BaiduMobAdSplash showInWindow:");
            id delegate = [self valueForKey:@"delegate"];
            if (delegate && [delegate respondsToSelector:@selector(splashAdDidClose:)]) {
                [delegate performSelector:@selector(splashAdDidClose:) withObject:self];
            }
        }, NULL);
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

static void addCustomRule(UIView *adView, UIButton *skipBtn) {
    NSMutableDictionary *rule = [NSMutableDictionary dictionary];
    rule[@"adViewClass"] = NSStringFromClass([adView class]);
    rule[@"skipBtnClass"] = NSStringFromClass([skipBtn class]);
    if (skipBtn.titleLabel.text) {
        rule[@"skipBtnTitleKeyword"] = skipBtn.titleLabel.text;
    }
    if (skipBtn.accessibilityLabel) {
        rule[@"skipBtnAccLabelKeyword"] = skipBtn.accessibilityLabel;
    }
    
    NSMutableArray *rules = loadCustomRules();
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

static BOOL tryAutoSkipWithRules(UIView *adView) {
    NSArray *rules = loadCustomRules();
    for (NSDictionary *rule in rules) {
        NSString *clsName = rule[@"adViewClass"];
        if ([NSStringFromClass([adView class]) isEqualToString:clsName]) {
            TESTLOG(@"🎯 命中自定义规则，尝试自动跳过: %@", clsName);
            UIButton *skipBtn = nil;
            NSString *btnCls = rule[@"skipBtnClass"];
            if (btnCls) {
                for (UIView *sub in adView.subviews) {
                    if ([NSStringFromClass([sub class]) isEqualToString:btnCls] && [sub isKindOfClass:[UIButton class]]) {
                        skipBtn = (UIButton *)sub;
                        break;
                    }
                }
            }
            if (!skipBtn) {
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

// ========== 启发式检测：判断视图是否可能是开屏广告 ==========
static BOOL isLikelyAdView(UIView *view) {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    if (view.frame.size.width < screenBounds.size.width * 0.8 ||
        view.frame.size.height < screenBounds.size.height * 0.8) {
        return NO;
    }
    
    UIButton *skip = findSkipButtonInView(view);
    if (skip) return YES;
    
    NSString *className = NSStringFromClass([view class]);
    NSArray *keywords = @[@"Splash", @"Ad", @"Launch", @"Popup"];
    for (NSString *kw in keywords) {
        if ([className rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

// ========== 检测当前顶层窗口中的广告 ==========
static void scanForAdsInTopWindow() {
    // 延迟执行，等启动广告完全加载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(HEURISTIC_CHECK_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
        
        UIView *root = topWindow.rootViewController.view ?: topWindow;
        for (UIView *sub in root.subviews) {
            if (isLikelyAdView(sub)) {
                if (tryAutoSkipWithRules(sub)) {
                    continue;
                }
                showMarkUI(sub);
            }
        }
    });
}

// ========== 拦截 UIWindow 的 makeKeyAndVisible ==========
static void (*orig_makeKeyAndVisible)(id, SEL);
static void swizzled_makeKeyAndVisible(UIWindow *self, SEL _cmd) {
    orig_makeKeyAndVisible(self, _cmd);
    
    if (self.frame.size.width >= [UIScreen mainScreen].bounds.size.width * 0.8 &&
        self.frame.size.height >= [UIScreen mainScreen].bounds.size.height * 0.8 &&
        self.windowLevel > UIWindowLevelNormal + 1) {
        TESTLOG(@"🔍 检测到高等级全屏窗口: %@", NSStringFromClass([self class]));
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

// ========== 初始化入口 ==========
__attribute__((constructor))
static void adblock_init() {
    TESTLOG(@"🚀 通用去广告插件已加载");
    
    // 应用已知 SDK Hook
    applyKnownSDKHooks();
    
    // 替换 UIWindow 的 makeKeyAndVisible 方法
    Method m = class_getInstanceMethod([UIWindow class], @selector(makeKeyAndVisible));
    if (m) {
        orig_makeKeyAndVisible = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)swizzled_makeKeyAndVisible);
    }
    
    // 监听 App 激活，进行启发式检测
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        TESTLOG(@"📱 App 变为活跃，开始广告检测");
        scanForAdsInTopWindow();
    }];
}
