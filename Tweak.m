// ==========================================
// Tweak.m - 通用去开屏广告插件（根本修复版）
// 适用于 iOS 16.6 + TrollStore，红色按钮直接添加到最顶层窗口
// ==========================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------- 可调参数 ----------
#define SKIP_BTN_CHECK_DELAY  1.0
#define HEURISTIC_CHECK_DELAY 1.5
// ------------------------------

#define TESTLOG(fmt, ...) NSLog(@"[AD-BLOCKER] " fmt, ##__VA_ARGS__)

// 手势辅助类
@interface _AdBlockGestureHandler : NSObject
@property (nonatomic, copy) void (^panBlock)(UIPanGestureRecognizer *);
@end
@implementation _AdBlockGestureHandler
- (instancetype)initWithBlock:(void (^)(UIPanGestureRecognizer *))block {
    if (self = [super init]) _panBlock = block;
    return self;
}
- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (self.panBlock) self.panBlock(gesture);
}
@end

// ---------- 方法替换 ----------
static void replaceInstanceMethod(Class cls, SEL sel, id newImpBlock, IMP *origPtr) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP newImp = imp_implementationWithBlock(newImpBlock);
    if (origPtr) *origPtr = method_setImplementation(m, newImp);
    else method_setImplementation(m, newImp);
}

// ---------- 触摸模拟 ----------
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
    showTapIndicatorAtPoint(screenPoint);  // 可注释掉以去除红圈
    
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

static UIButton *findSkipButtonInView(UIView *view) {
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *title = btn.titleLabel.text;
        if (title && ([title containsString:@"跳过"] || [title containsString:@"Skip"] || [title containsString:@"关闭"]))
            return btn;
        NSString *accLabel = btn.accessibilityLabel;
        if (accLabel && ([accLabel containsString:@"跳过"] || [accLabel containsString:@"Skip"]))
            return btn;
    }
    for (UIView *sub in view.subviews) {
        UIButton *result = findSkipButtonInView(sub);
        if (result) return result;
    }
    return nil;
}

static CGPoint screenPointForView(UIView *view) {
    CGRect frameInScreen = [view convertRect:view.bounds toView:nil];
    return CGPointMake(CGRectGetMidX(frameInScreen), CGRectGetMidY(frameInScreen));
}

// ---------- 已知 SDK 拦截 ----------
static BOOL knownHookApplied = NO;
static void applyKnownSDKHooks() {
    if (knownHookApplied) return;
    knownHookApplied = YES;
    Class cls;
    cls = NSClassFromString(@"BUSplashAdView");
    if (cls) replaceInstanceMethod(cls, @selector(showInWindow:), ^(id self, UIWindow *window) {
        id delegate = [self valueForKey:@"delegate"];
        if (delegate && [delegate respondsToSelector:@selector(splashAdDidClose:)])
            [delegate performSelector:@selector(splashAdDidClose:) withObject:self];
    }, NULL);
    cls = NSClassFromString(@"GDTSplashAd");
    if (cls) replaceInstanceMethod(cls, @selector(loadAndShowInWindow:), ^(id self, UIWindow *window) {
        id delegate = [self valueForKey:@"delegate"];
        if (delegate && [delegate respondsToSelector:@selector(splashAdDidDismiss:)])
            [delegate performSelector:@selector(splashAdDidDismiss:) withObject:self];
    }, NULL);
    cls = NSClassFromString(@"BaiduMobAdSplash");
    if (cls) replaceInstanceMethod(cls, @selector(showInWindow:), ^(id self, UIWindow *window) {
        id delegate = [self valueForKey:@"delegate"];
        if (delegate && [delegate respondsToSelector:@selector(splashAdDidClose:)])
            [delegate performSelector:@selector(splashAdDidClose:) withObject:self];
    }, NULL);
}

// ---------- 规则持久化 ----------
static NSString *rulesPath() {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"com.adblocker.rules.plist"];
}
static NSMutableArray *loadRules() {
    NSArray *arr = [NSArray arrayWithContentsOfFile:rulesPath()];
    return arr ? [arr mutableCopy] : [NSMutableArray array];
}
static void saveRules(NSArray *rules) { [rules writeToFile:rulesPath() atomically:YES]; }
static void addRule(UIView *adView, UIButton *skipBtn) {
    NSDictionary *rule = @{
        @"adViewClass": NSStringFromClass([adView class]),
        @"skipBtnClass": NSStringFromClass([skipBtn class]),
        @"skipBtnTitle": skipBtn.titleLabel.text ?: @"",
        @"skipBtnAccLabel": skipBtn.accessibilityLabel ?: @""
    };
    NSMutableArray *rules = loadRules();
    if (![rules containsObject:rule]) {
        [rules addObject:rule];
        saveRules(rules);
        TESTLOG(@"✅ 规则已保存");
    }
}
static BOOL tryAutoSkipWithRules(UIView *adView) {
    NSArray *rules = loadRules();
    for (NSDictionary *rule in rules) {
        if ([NSStringFromClass([adView class]) isEqualToString:rule[@"adViewClass"]]) {
            UIButton *skip = nil;
            for (UIView *sub in adView.subviews) {
                if ([sub isKindOfClass:[UIButton class]] &&
                    [NSStringFromClass([sub class]) isEqualToString:rule[@"skipBtnClass"]]) {
                    skip = (UIButton *)sub; break;
                }
            }
            if (!skip) skip = findSkipButtonInView(adView);
            if (skip) simulateTapAtPoint(screenPointForView(skip));
            else [adView removeFromSuperview];
            return YES;
        }
    }
    return NO;
}

// ---------- 标记弹窗 ----------
static BOOL markUIShowing = NO;
static void showMarkUI(UIView *adView) {
    if (markUIShowing) return;
    markUIShowing = YES;
    
    // 获取最高层级窗口以关联 Scene
    UIWindow *topWin = nil;
    CGFloat maxLvl = -1;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            for (UIWindow *w in scene.windows) {
                if (!w.hidden && w.alpha>0.01 && w.windowLevel>maxLvl) {
                    maxLvl = w.windowLevel; topWin = w;
                }
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!topWin) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.hidden && w.alpha>0.01 && w.windowLevel>maxLvl) {
                maxLvl = w.windowLevel; topWin = w;
            }
        }
    }
#pragma clang diagnostic pop
    
    UIWindow *win = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    if (topWin) {
        if (@available(iOS 13.0, *)) {
            win.windowScene = topWin.windowScene;
        }
    }
    win.windowLevel = UIWindowLevelAlert + 1000;
    win.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    win.hidden = NO;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    win.rootViewController = vc;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"发现疑似开屏广告"
                                                                   message:@"要自动跳过这类广告吗？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak UIView *weakAd = adView;
    __weak UIWindow *weakWin = win;
    [alert addAction:[UIAlertAction actionWithTitle:@"仅跳过本次" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        markUIShowing = NO;
        UIButton *b = findSkipButtonInView(weakAd);
        if (b) simulateTapAtPoint(screenPointForView(b));
        weakWin.hidden = YES;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"总是自动跳过" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        markUIShowing = NO;
        UIButton *b = findSkipButtonInView(weakAd);
        if (b) { addRule(weakAd, b); simulateTapAtPoint(screenPointForView(b)); }
        weakWin.hidden = YES;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"不是广告" style:UIAlertActionStyleCancel handler:^(UIAlertAction *_) {
        markUIShowing = NO;
        weakWin.hidden = YES;
    }]];
    [vc presentViewController:alert animated:YES completion:nil];
}

// ---------- 启发式检测 ----------
static BOOL isLikelyAdView(UIView *view) {
    CGRect bounds = [UIScreen mainScreen].bounds;
    if (view.frame.size.width < bounds.size.width*0.8 || view.frame.size.height < bounds.size.height*0.8)
        return NO;
    if (findSkipButtonInView(view)) return YES;
    NSString *cls = NSStringFromClass([view class]);
    for (NSString *kw in @[@"Splash", @"Ad", @"Launch", @"Popup"])
        if ([cls rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static void scanForAdsInTopWindow() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(HEURISTIC_CHECK_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *top = nil;
        CGFloat maxLvl = -1;
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in scene.windows) {
                        if (!w.hidden && w.alpha>0.01 && w.windowLevel>maxLvl) {
                            maxLvl = w.windowLevel; top = w;
                        }
                    }
                }
            }
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (!top) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (!w.hidden && w.alpha>0.01 && w.windowLevel>maxLvl) {
                    maxLvl = w.windowLevel; top = w;
                }
            }
        }
#pragma clang diagnostic pop
        if (!top) return;
        
        NSArray *subviews = top.rootViewController.view ? top.rootViewController.view.subviews : top.subviews;
        for (UIView *sub in subviews) {
            if (isLikelyAdView(sub)) {
                if (tryAutoSkipWithRules(sub)) continue;
                showMarkUI(sub);
            }
        }
    });
}

// ---------- UIWindow 监控 ----------
static void (*orig_makeKeyAndVisible)(id, SEL);
static void swizzled_makeKeyAndVisible(UIWindow *self, SEL _cmd) {
    orig_makeKeyAndVisible(self, _cmd);
    if (self.frame.size.width >= [UIScreen mainScreen].bounds.size.width*0.8 &&
        self.frame.size.height >= [UIScreen mainScreen].bounds.size.height*0.8 &&
        self.windowLevel > UIWindowLevelNormal + 1) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SKIP_BTN_CHECK_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (UIView *sub in self.subviews) {
                if (isLikelyAdView(sub)) {
                    if (tryAutoSkipWithRules(sub)) return;
                    showMarkUI(sub);
                }
            }
        });
    }
}

// ========== 核心：将按钮直接添加到最顶层窗口的 subview 中 ==========
static BOOL floatingButtonAdded = NO;
static void addFloatingButtonToTopWindow() {
    if (floatingButtonAdded) return;
    
    // 获取当前 windowLevel 最高的窗口
    UIWindow *topWindow = nil;
    CGFloat maxLevel = -1;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            for (UIWindow *w in scene.windows) {
                if (!w.hidden && w.alpha > 0.01 && w.windowLevel > maxLevel) {
                    maxLevel = w.windowLevel;
                    topWindow = w;
                }
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!topWindow) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.hidden && w.alpha > 0.01 && w.windowLevel > maxLevel) {
                maxLevel = w.windowLevel;
                topWindow = w;
            }
        }
    }
#pragma clang diagnostic pop
    
    if (!topWindow) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            addFloatingButtonToTopWindow();
        });
        TESTLOG(@"⚠️ 未找到可用窗口，重试...");
        return;
    }
    
    floatingButtonAdded = YES;
    
    // 创建红色按钮
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 70, 150, 60, 60);
    btn.backgroundColor = [UIColor redColor];
    btn.layer.cornerRadius = 30;
    btn.layer.borderWidth = 3.0;
    btn.layer.borderColor = [UIColor whiteColor].CGColor;
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOffset = CGSizeMake(0, 4);
    btn.layer.shadowOpacity = 0.8;
    [btn setTitle:@"去广告" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    btn.layer.zPosition = CGFLOAT_MAX;
    
    // 点击事件
    [btn addAction:[UIAction actionWithHandler:^(__kindof UIAction * _) {
        scanForAdsInTopWindow();
    }] forControlEvents:UIControlEventTouchUpInside];
    
    // 拖动支持
    _AdBlockGestureHandler *handler = [[_AdBlockGestureHandler alloc] initWithBlock:^(UIPanGestureRecognizer *gesture) {
        static CGPoint start;
        if (gesture.state == UIGestureRecognizerStateBegan) {
            start = [gesture locationInView:btn];
        } else {
            CGPoint curr = [gesture locationInView:topWindow];
            btn.frame = CGRectMake(curr.x - start.x, curr.y - start.y,
                                   btn.frame.size.width, btn.frame.size.height);
        }
    }];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:handler action:@selector(handlePan:)];
    [btn addGestureRecognizer:pan];
    
    [topWindow addSubview:btn];
    TESTLOG(@"🔴 红色去广告按钮已添加到窗口 (level: %.0f)", topWindow.windowLevel);
}

// ---------- Toast 提示 ----------
static void showLoadedToast() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *toastWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    toastWin.windowScene = scene;
                    break;
                }
            }
        }
        toastWin.windowLevel = UIWindowLevelAlert + 999;
        toastWin.backgroundColor = [UIColor clearColor];
        toastWin.userInteractionEnabled = NO;
        toastWin.hidden = NO;
        
        UILabel *label = [[UILabel alloc] init];
        label.text = @"✅ AdBlock 已加载";
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:16];
        label.layer.cornerRadius = 10;
        label.layer.masksToBounds = YES;
        [label sizeToFit];
        CGRect frame = label.frame;
        frame.size.width += 30;
        frame.size.height += 16;
        label.frame = frame;
        label.center = CGPointMake(toastWin.bounds.size.width/2, toastWin.bounds.size.height - 100);
        [toastWin addSubview:label];
        
        label.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{
            label.alpha = 1;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
                label.alpha = 0;
            } completion:^(BOOL finished) {
                toastWin.hidden = YES;
            }];
        }];
    });
}

// ========== 初始化 ==========
__attribute__((constructor))
static void adblock_init() {
    TESTLOG(@"🚀 去广告插件初始化");
    applyKnownSDKHooks();
    
    Method m = class_getInstanceMethod([UIWindow class], @selector(makeKeyAndVisible));
    if (m) {
        orig_makeKeyAndVisible = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)swizzled_makeKeyAndVisible);
    }
    
    // 等 App 激活后再添加按钮，确保窗口已准备好
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            addFloatingButtonToTopWindow();
            scanForAdsInTopWindow();
        });
    }];
    
    showLoadedToast();
}
