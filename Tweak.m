// ==========================================
// Tweak.m - 通用去开屏广告插件（稳定版 - 已修复编译错误）
// 适用于 TrollStore + TrollFools 注入
// ==========================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------- 可调参数 ----------
#define SKIP_BTN_CHECK_DELAY  1.0
#define HEURISTIC_CHECK_DELAY 1.5
// ------------------------------

#define TESTLOG(fmt, ...) NSLog(@"[AD-BLOCKER] " fmt, ##__VA_ARGS__)

// ========== 辅助类：手势处理目标 ==========
@interface _AdBlockGestureHandler : NSObject
@property (nonatomic, copy) void (^panBlock)(UIPanGestureRecognizer *);
- (instancetype)initWithBlock:(void (^)(UIPanGestureRecognizer *))block;
@end
@implementation _AdBlockGestureHandler
- (instancetype)initWithBlock:(void (^)(UIPanGestureRecognizer *))block {
    if (self = [super init]) {
        _panBlock = block;
    }
    return self;
}
- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (self.panBlock) self.panBlock(gesture);
}
@end

// ========== 方法替换（纯 Runtime） ==========
static void replaceInstanceMethod(Class cls, SEL sel, id newImpBlock, IMP *origPtr) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP newImp = imp_implementationWithBlock(newImpBlock);
    if (origPtr) *origPtr = method_setImplementation(m, newImp);
    else method_setImplementation(m, newImp);
}

// ========== 触摸模拟 ==========
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
    // 调试红圈，不需要可注释
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

static CGPoint screenPointForView(UIView *view) {
    CGRect frameInScreen = [view convertRect:view.bounds toView:nil];
    return CGPointMake(CGRectGetMidX(frameInScreen), CGRectGetMidY(frameInScreen));
}

// ========== 已知 SDK 自动 Hook ==========
static BOOL knownHookApplied = NO;
static void applyKnownSDKHooks() {
    if (knownHookApplied) return;
    knownHookApplied = YES;
    
    Class cls;
    // 穿山甲
    cls = NSClassFromString(@"BUSplashAdView");
    if (cls) {
        replaceInstanceMethod(cls, @selector(showInWindow:), ^(id self, UIWindow *window) {
            TESTLOG(@"🛑 [穿山甲] 拦截");
            id delegate = [self valueForKey:@"delegate"];
            if (delegate && [delegate respondsToSelector:@selector(splashAdDidClose:)]) {
                [delegate performSelector:@selector(splashAdDidClose:) withObject:self];
            }
        }, NULL);
    }
    // 优量汇
    cls = NSClassFromString(@"GDTSplashAd");
    if (cls) {
        replaceInstanceMethod(cls, @selector(loadAndShowInWindow:), ^(id self, UIWindow *window) {
            TESTLOG(@"🛑 [优量汇] 拦截");
            id delegate = [self valueForKey:@"delegate"];
            if (delegate && [delegate respondsToSelector:@selector(splashAdDidDismiss:)]) {
                [delegate performSelector:@selector(splashAdDidDismiss:) withObject:self];
            }
        }, NULL);
    }
    // 百度
    cls = NSClassFromString(@"BaiduMobAdSplash");
    if (cls) {
        replaceInstanceMethod(cls, @selector(showInWindow:), ^(id self, UIWindow *window) {
            TESTLOG(@"🛑 [百度] 拦截");
            id delegate = [self valueForKey:@"delegate"];
            if (delegate && [delegate respondsToSelector:@selector(splashAdDidClose:)]) {
                [delegate performSelector:@selector(splashAdDidClose:) withObject:self];
            }
        }, NULL);
    }
}

// ========== 用户规则持久化 ==========
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
    if (skipBtn.titleLabel.text) rule[@"skipBtnTitleKeyword"] = skipBtn.titleLabel.text;
    if (skipBtn.accessibilityLabel) rule[@"skipBtnAccLabelKeyword"] = skipBtn.accessibilityLabel;
    
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
        TESTLOG(@"✅ 已添加规则：%@", rule);
    }
}
static BOOL tryAutoSkipWithRules(UIView *adView) {
    NSArray *rules = loadCustomRules();
    for (NSDictionary *rule in rules) {
        if ([NSStringFromClass([adView class]) isEqualToString:rule[@"adViewClass"]]) {
            TESTLOG(@"🎯 命中规则，自动跳过");
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
            if (!skipBtn) skipBtn = findSkipButtonInView(adView);
            if (skipBtn) {
                simulateTapAtPoint(screenPointForView(skipBtn));
                return YES;
            } else {
                [adView removeFromSuperview];
                return YES;
            }
        }
    }
    return NO;
}

// ========== 标记弹窗（修复自动消失） ==========
static BOOL markUIShowing = NO;

static void showMarkUI(UIView *suspiciousView) {
    if (markUIShowing) return;
    markUIShowing = YES;
    
    UIWindow *alertWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    alertWin.windowLevel = UIWindowLevelAlert + 1000;
    alertWin.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    alertWin.hidden = NO;
    
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    alertWin.rootViewController = vc;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"发现疑似开屏广告" 
                                                                   message:@"要自动跳过这类广告吗？" 
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    __weak UIView *weakAdView = suspiciousView;
    __weak UIWindow *weakWin = alertWin;
    
    UIAlertAction *skipOnce = [UIAlertAction actionWithTitle:@"仅跳过本次" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        markUIShowing = NO;
        UIButton *skipBtn = findSkipButtonInView(weakAdView);
        if (skipBtn) simulateTapAtPoint(screenPointForView(skipBtn));
        weakWin.hidden = YES;
    }];
    
    UIAlertAction *skipAlways = [UIAlertAction actionWithTitle:@"总是自动跳过" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        markUIShowing = NO;
        UIButton *skipBtn = findSkipButtonInView(weakAdView);
        if (skipBtn) {
            addCustomRule(weakAdView, skipBtn);
            simulateTapAtPoint(screenPointForView(skipBtn));
        }
        weakWin.hidden = YES;
    }];
    
    UIAlertAction *notAd = [UIAlertAction actionWithTitle:@"不是广告" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        markUIShowing = NO;
        weakWin.hidden = YES;
    }];
    
    [alert addAction:skipOnce];
    [alert addAction:skipAlways];
    [alert addAction:notAd];
    
    [vc presentViewController:alert animated:YES completion:nil];
}

// ========== 启发式检测 ==========
static BOOL isLikelyAdView(UIView *view) {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    if (view.frame.size.width < screenBounds.size.width * 0.8 ||
        view.frame.size.height < screenBounds.size.height * 0.8) {
        return NO;
    }
    if (findSkipButtonInView(view)) return YES;
    NSString *className = NSStringFromClass([view class]);
    NSArray *keywords = @[@"Splash", @"Ad", @"Launch", @"Popup"];
    for (NSString *kw in keywords) {
        if ([className rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static void scanForAdsInTopWindow() {
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
                if (tryAutoSkipWithRules(sub)) continue;
                showMarkUI(sub);
            }
        }
    });
}

// ========== 拦截新窗口 ==========
static void (*orig_makeKeyAndVisible)(id, SEL);
static void swizzled_makeKeyAndVisible(UIWindow *self, SEL _cmd) {
    orig_makeKeyAndVisible(self, _cmd);
    if (self.frame.size.width >= [UIScreen mainScreen].bounds.size.width * 0.8 &&
        self.frame.size.height >= [UIScreen mainScreen].bounds.size.height * 0.8 &&
        self.windowLevel > UIWindowLevelNormal + 1) {
        TESTLOG(@"🔍 检测到高等级窗口");
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

// ========== 悬浮按钮（手动触发） ==========
static void addFloatingButton() {
    UIWindow *btnWin = [[UIWindow alloc] initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width - 60, 100, 50, 50)];
    btnWin.windowLevel = UIWindowLevelAlert + 1001;
    btnWin.backgroundColor = [UIColor clearColor];
    btnWin.hidden = NO;
    
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = btnWin.bounds;
    btn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.7];
    btn.layer.cornerRadius = 25;
    [btn setTitle:@"🛡️" forState:UIControlStateNormal];
    [btn addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull action) {
        scanForAdsInTopWindow();
    }] forControlEvents:UIControlEventTouchUpInside];
    [btnWin addSubview:btn];
    
    // 拖动支持（使用辅助类处理手势回调）
    _AdBlockGestureHandler *handler = [[_AdBlockGestureHandler alloc] initWithBlock:^(UIPanGestureRecognizer *gesture) {
        static CGPoint startPoint;
        if (gesture.state == UIGestureRecognizerStateBegan) {
            startPoint = [gesture locationInView:btnWin];
        } else {
            CGPoint curr = [gesture locationInView:nil];
            CGPoint newOrigin = CGPointMake(curr.x - startPoint.x, curr.y - startPoint.y);
            btnWin.frame = (CGRect){ .origin = newOrigin, .size = btnWin.frame.size };
        }
    }];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:handler action:@selector(handlePan:)];
    [btn addGestureRecognizer:pan];
}

// ========== 初始化 ==========
__attribute__((constructor))
static void adblock_init() {
    TESTLOG(@"🚀 通用去广告插件已加载");
    
    applyKnownSDKHooks();
    
    // Hook UIWindow
    Method m = class_getInstanceMethod([UIWindow class], @selector(makeKeyAndVisible));
    if (m) {
        orig_makeKeyAndVisible = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)swizzled_makeKeyAndVisible);
    }
    
    // 激活检测
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        TESTLOG(@"📱 App 活跃，开始广告检测");
        scanForAdsInTopWindow();
    }];
    
    // 显示悬浮按钮（可拖动）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        addFloatingButton();
    });
}
