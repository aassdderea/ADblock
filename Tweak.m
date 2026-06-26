// ==========================================
// Tweak.m - 通用去开屏广告插件 v2.1（编译修复版）
// 适用于 iOS 16.x + TrollStore + Theos
// ==========================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 配置常量

static const NSTimeInterval kLongPressDuration   = 1.0;
static const NSTimeInterval kHeuristicDelay      = 1.2;
static const NSTimeInterval kLearnTimeout        = 15.0;
static const NSTimeInterval kSimulateTouchDelay  = 0.04;
static const CGFloat        kFloatingBtnSize     = 56.0;
static const CGFloat        kFloatingBtnMargin   = 16.0;
static const CGFloat        kMaxOtherWindowLevel = 100000.0;

#pragma mark - 日志宏

#define ABLog(fmt, ...)  NSLog(@"[AD-BLOCK][%s] " fmt, __FUNCTION__, ##__VA_ARGS__)
#define ABWarn(fmt, ...) NSLog(@"[AD-BLOCK][WARN][%s] " fmt, __FUNCTION__, ##__VA_ARGS__)

#pragma mark - 前向声明（修复 implicit function declaration）

@class ABFloatingWindow;
static void ab_createFloatingWindow(void);
static void ab_ensureFloatingOnTop(void);
static void ab_startLearningMode(void);
static void ab_stopLearningMode(BOOL success);
static void ab_scanAndAutoSkip(void);
static void ab_simulateTapOnView(UIView *view);
static void ab_showToast(NSString *text, BOOL isSuccess);
static void _ab_installUIWindowHooks(void); // ← 关键：提前声明
static void _ab_hookKnownSDKs(void);

#pragma mark - 全局状态

static ABFloatingWindow *_floatingWindow = nil;
static UIButton         *_floatingBtn    = nil;
static BOOL              _isLearning     = NO;
static BOOL              _isInitialized  = NO;
static dispatch_block_t  _learnTimeoutBlock = nil;
static id                _activeObserver = nil; // ← 用于安全移除通知

static CGPoint           _capturedTapPoint;

#pragma mark - 规则模型（简化版，避免 NSSecureCoding 编译问题）

@interface ABRule : NSObject
@property (nonatomic, copy) NSString *adViewClassName;
@property (nonatomic, copy) NSString *skipBtnClassName;
@property (nonatomic, copy) NSString *skipBtnTitle;
@property (nonatomic, copy) NSString *skipBtnAccLabel;
@property (nonatomic, assign) NSUInteger hitCount;
+ (NSString *)rulesFilePath;
+ (NSMutableArray<ABRule *> *)loadAllRules;
+ (void)saveAllRules:(NSArray<ABRule *> *)rules;
- (BOOL)matchesAdView:(UIView *)adView skipButton:(UIButton **)outBtn;
@end

@implementation ABRule

+ (NSString *)rulesFilePath {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = paths.firstObject ?: NSTemporaryDirectory();
        path = [docDir stringByAppendingPathComponent:@"com.adblocker.rules.plist"];
    });
    return path;
}

+ (NSMutableArray<ABRule *> *)loadAllRules {
    @try {
        NSArray *raw = [NSArray arrayWithContentsOfFile:[self rulesFilePath]];
        if (!raw) return [NSMutableArray array];
        NSMutableArray *rules = [NSMutableArray array];
        for (NSDictionary *dict in raw) {
            ABRule *r = [ABRule new];
            r.adViewClassName = dict[@"adViewClassName"];
            r.skipBtnClassName = dict[@"skipBtnClassName"];
            r.skipBtnTitle = dict[@"skipBtnTitle"];
            r.skipBtnAccLabel = dict[@"skipBtnAccLabel"];
            r.hitCount = [dict[@"hitCount"] unsignedIntegerValue];
            [rules addObject:r];
        }
        return rules;
    } @catch (NSException *e) {
        return [NSMutableArray array];
    }
}

+ (void)saveAllRules:(NSArray<ABRule *> *)rules {
    @try {
        NSMutableArray *raw = [NSMutableArray array];
        for (ABRule *r in rules) {
            [raw addObject:@{
                @"adViewClassName": r.adViewClassName ?: @"",
                @"skipBtnClassName": r.skipBtnClassName ?: @"",
                @"skipBtnTitle": r.skipBtnTitle ?: @"",
                @"skipBtnAccLabel": r.skipBtnAccLabel ?: @"",
                @"hitCount": @(r.hitCount)
            }];
        }
        [raw writeToFile:[self rulesFilePath] atomically:YES];
    } @catch (NSException *e) {
        ABWarn(@"规则保存失败: %@", e);
    }
}

- (BOOL)matchesAdView:(UIView *)adView skipButton:(UIButton **)outBtn {
    NSString *clsName = NSStringFromClass([adView class]);
    BOOL match = [clsName isEqualToString:self.adViewClassName] ||
                 [clsName hasSuffix:self.adViewClassName] ||
                 [clsName containsString:self.adViewClassName];
    if (!match) return NO;

    UIButton *btn = [self _findSkipButtonIn:adView];
    if (outBtn) *outBtn = btn;
    return (btn != nil);
}

- (UIButton *)_findSkipButtonIn:(UIView *)v {
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)v;
        NSString *title = btn.titleLabel.text ?: btn.currentTitle ?: @"";
        NSString *acc = btn.accessibilityLabel ?: @"";
        NSArray *kw = @[@"跳过", @"skip", @"Skip", @"关闭", @"close"];
        for (NSString *k in kw) {
            if ([title containsString:k] || [acc containsString:k]) return btn;
        }
    }
    for (UIView *sub in v.subviews) {
        UIButton *r = [self _findSkipButtonIn:sub];
        if (r) return r;
    }
    return nil;
}

@end

#pragma mark - 手势代理

@interface ABGestureDelegate : NSObject
@property (nonatomic, copy) void (^panHandler)(UIPanGestureRecognizer *);
@property (nonatomic, copy) void (^longPressHandler)(UILongPressGestureRecognizer *);
@property (nonatomic, copy) void (^tapHandler)(UITapGestureRecognizer *);
@end

@implementation ABGestureDelegate
- (void)handlePan:(UIPanGestureRecognizer *)g { if (self.panHandler) self.panHandler(g); }
- (void)handleLongPress:(UILongPressGestureRecognizer *)g { if (self.longPressHandler) self.longPressHandler(g); }
- (void)handleTap:(UITapGestureRecognizer *)g { if (self.tapHandler) self.tapHandler(g); }
@end

#pragma mark - 悬浮窗

@interface ABFloatingWindow : UIWindow
@property (nonatomic, weak) UIButton *mainButton;
@end

@implementation ABFloatingWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.mainButton) {
        CGPoint btnPoint = [self.mainButton convertPoint:point fromView:self];
        if ([self.mainButton pointInside:btnPoint withEvent:event]) return self.mainButton;
    }
    return nil; // 完全穿透
}
- (BOOL)_canBecomeKeyWindow { return NO; }
@end

#pragma mark - 工具函数

// ← 修复：仅使用 UIWindowScene.windows，移除废弃的 [UIApplication windows]
static UIWindow *_ab_topWindow(void) {
    UIWindow *top = nil;
    CGFloat maxLevel = -1;
    @try {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in scene.windows) {
                if (w == _floatingWindow || w.hidden || w.alpha < 0.01) continue;
                if (w.windowLevel > maxLevel) {
                    maxLevel = w.windowLevel;
                    top = w;
                }
            }
        }
    } @catch (NSException *e) {
        ABWarn(@"获取顶层窗口异常: %@", e);
    }
    return top;
}

static UIButton *_ab_findSkipButton(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)root;
        NSString *title = btn.titleLabel.text ?: btn.currentTitle ?: @"";
        NSString *acc = btn.accessibilityLabel ?: @"";
        NSArray *kw = @[@"跳过", @"skip", @"Skip", @"关闭", @"close"];
        for (NSString *k in kw) {
            if ([title containsString:k] || [acc containsString:k]) return btn;
        }
    }
    for (UIView *sub in root.subviews) {
        UIButton *r = _ab_findSkipButton(sub);
        if (r) return r;
    }
    return nil;
}

static UIView *_ab_findAdContainer(UIView *fromView) {
    CGRect screen = [UIScreen mainScreen].bounds;
    UIView *candidate = nil;
    UIView *cur = fromView;
    while (cur) {
        if (cur.frame.size.width >= screen.size.width * 0.8 &&
            cur.frame.size.height >= screen.size.height * 0.8) {
            candidate = cur;
        }
        cur = cur.superview;
    }
    return candidate;
}

#pragma mark - 触摸模拟（三级策略，修复编译错误）

// ← 修复：使用 performSelector 替代 actionsForTarget:forControlEvents:
static BOOL _ab_tryDirectAction(UIButton *btn) {
    @try {
        // 通过 performSelector 动态调用 UIControl 的方法
        SEL allTargetsSel = NSSelectorFromString(@"allTargets");
        SEL actionsForTargetSel = NSSelectorFromString(@"actionsForTarget:forControlEvents:");

        if (![btn respondsToSelector:allTargetsSel]) return NO;

        NSSet *targets = ((NSSet *(*)(id, SEL))objc_msgSend)(btn, allTargetsSel);
        if (targets.count == 0) {
            // 回退：sendActionsForControlEvents
            [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }

        for (id target in targets) {
            if (![btn respondsToSelector:actionsForTargetSel]) continue;
            NSArray *actions = ((NSArray *(*)(id, SEL, id, UIControlEvent))objc_msgSend)(
                btn, actionsForTargetSel, target, UIControlEventTouchUpInside);
            for (NSString *actionName in actions ?: @[]) {
                SEL sel = NSSelectorFromString(actionName);
                if ([target respondsToSelector:sel]) {
                    ABLog(@"策略1: 直接调用 %@ → %@", NSStringFromClass([target class]), actionName);
                    ((void(*)(id, SEL))objc_msgSend)(target, sel);
                    return YES;
                }
            }
        }

        [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    } @catch (NSException *e) {
        ABWarn(@"策略1失败: %@", e);
        return NO;
    }
}

static void _ab_injectTouchViaSendEvent(CGPoint screenPoint) {
    UIWindow *targetWindow = _ab_topWindow();
    if (!targetWindow) return;

    CGPoint windowPoint = [targetWindow convertPoint:screenPoint fromWindow:nil];
    UIView *hitView = [targetWindow hitTest:windowPoint withEvent:nil];
    if (!hitView) hitView = targetWindow;

    @try {
        UITouch *touch = [[UITouch alloc] init];
        [touch setValue:@(windowPoint) forKey:@"locationInWindow"];
        [touch setValue:hitView forKey:@"view"];
        [touch setValue:targetWindow forKey:@"window"];
        [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
        [touch setValue:@(1) forKey:@"tapCount"];
        [touch setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"_timestamp"];

        UIEvent *event = [[UIEvent alloc] init];
        [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];
        [event setValue:@(1) forKey:@"type"];
        [event setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"_timestamp"];

        [[UIApplication sharedApplication] sendEvent:event];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSimulateTouchDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UITouch *endTouch = [[UITouch alloc] init];
            [endTouch setValue:@(windowPoint) forKey:@"locationInWindow"];
            [endTouch setValue:hitView forKey:@"view"];
            [endTouch setValue:targetWindow forKey:@"window"];
            [endTouch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
            [endTouch setValue:@(1) forKey:@"tapCount"];
            [endTouch setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"_timestamp"];

            UIEvent *endEvent = [[UIEvent alloc] init];
            [endEvent setValue:[NSSet setWithObject:endTouch] forKey:@"touches"];
            [endEvent setValue:@(1) forKey:@"type"];
            [endEvent setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"_timestamp"];

            [[UIApplication sharedApplication] sendEvent:endEvent];
        });
    } @catch (NSException *e) {
        ABWarn(@"策略2失败，回退策略3: %@", e);
        // ← 修复：touch 变量声明移到 @try 外部，此处重新创建
        UITouch *fallbackTouch = [[UITouch alloc] init];
        [fallbackTouch setValue:@(windowPoint) forKey:@"locationInWindow"];
        [fallbackTouch setValue:hitView forKey:@"view"];
        [fallbackTouch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
        [hitView touchesBegan:[NSSet setWithObject:fallbackTouch] withEvent:nil];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSimulateTouchDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [fallbackTouch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
            [hitView touchesEnded:[NSSet setWithObject:fallbackTouch] withEvent:nil];
        });
    }
}

static void ab_simulateTapOnView(UIView *view) {
    if (!view) return;
    @autoreleasepool {
        if ([view isKindOfClass:[UIButton class]]) {
            if (_ab_tryDirectAction((UIButton *)view)) {
                ABLog(@"✅ 策略1成功");
                return;
            }
        }
        CGRect frame = [view convertRect:view.bounds toView:nil];
        CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        center.x += ((CGFloat)arc4random_uniform(400) / 100.0) - 2.0;
        center.y += ((CGFloat)arc4random_uniform(400) / 100.0) - 2.0;
        _ab_injectTouchViaSendEvent(center);
    }
}

#pragma mark - 已知 SDK Hook

static BOOL _knownSDKHooked = NO;

static IMP _ab_replaceMethod(Class cls, SEL sel, id block) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP newImp = imp_implementationWithBlock(block);
    return method_setImplementation(m, newImp);
}

static void _ab_hookKnownSDKs(void) {
    if (_knownSDKHooked) return;
    _knownSDKHooked = YES;

    Class c;
    c = NSClassFromString(@"BUSplashAdView");
    if (c) {
        _ab_replaceMethod(c, @selector(showInWindow:), ^void(id self, UIWindow *w) {
            id delegate = [self valueForKey:@"delegate"];
            SEL closeSel = NSSelectorFromString(@"splashAdDidClose:");
            if (delegate && [delegate respondsToSelector:closeSel])
                ((void(*)(id, SEL, id))objc_msgSend)(delegate, closeSel, self);
        });
    }

    c = NSClassFromString(@"GDTSplashAd");
    if (c) {
        _ab_replaceMethod(c, @selector(loadAndShowInWindow:), ^void(id self, UIWindow *w) {
            id delegate = [self valueForKey:@"delegate"];
            SEL dismissSel = NSSelectorFromString(@"splashAdDidDismiss:");
            if (delegate && [delegate respondsToSelector:dismissSel])
                ((void(*)(id, SEL, id))objc_msgSend)(delegate, dismissSel, self);
        });
    }

    c = NSClassFromString(@"BaiduMobAdSplash");
    if (c) {
        _ab_replaceMethod(c, @selector(showInWindow:), ^void(id self, UIWindow *w) {
            id delegate = [self valueForKey:@"delegate"];
            SEL closeSel = NSSelectorFromString(@"splashAdDidClose:");
            if (delegate && [delegate respondsToSelector:closeSel])
                ((void(*)(id, SEL, id))objc_msgSend)(delegate, closeSel, self);
        });
    }
}

#pragma mark - 悬浮窗管理

static ABGestureDelegate *_gestureDelegate = nil;

static void ab_createFloatingWindow(void) {
    if (_floatingWindow) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_floatingWindow) return;

        _floatingWindow = [[ABFloatingWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive) {
                _floatingWindow.windowScene = sc;
                break;
            }
        }
        if (!_floatingWindow.windowScene) {
            for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
                _floatingWindow.windowScene = sc;
                break;
            }
        }

        _floatingWindow.backgroundColor = [UIColor clearColor];
        _floatingWindow.rootViewController = [UIViewController new];
        _floatingWindow.rootViewController.view.backgroundColor = [UIColor clearColor];

        CGFloat s = kFloatingBtnSize;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - s - kFloatingBtnMargin, 120, s, s);
        btn.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
        btn.layer.cornerRadius = s / 2.0;
        btn.layer.borderWidth = 2.5;
        btn.layer.borderColor = [UIColor whiteColor].CGColor;
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [btn setTitle:@"去广告" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

        // ← 修复：删除了 addTarget:nil action:NULL 的无效占位代码

        _gestureDelegate = [ABGestureDelegate new];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                         initWithTarget:_gestureDelegate action:@selector(handleTap:)];
        _gestureDelegate.tapHandler = ^(UITapGestureRecognizer *g) {
            if (_isLearning) return;
            ab_scanAndAutoSkip();
        };
        [btn addGestureRecognizer:tap];

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                                             initWithTarget:_gestureDelegate action:@selector(handleLongPress:)];
        lp.minimumPressDuration = kLongPressDuration;
        lp.allowableMovement = 15;
        _gestureDelegate.longPressHandler = ^(UILongPressGestureRecognizer *g) {
            if (g.state == UIGestureRecognizerStateBegan && !_isLearning)
                ab_startLearningMode();
        };
        [btn addGestureRecognizer:lp];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                        initWithTarget:_gestureDelegate action:@selector(handlePan:)];
        _gestureDelegate.panHandler = ^(UIPanGestureRecognizer *g) {
            static CGPoint startOffset;
            if (g.state == UIGestureRecognizerStateBegan) {
                startOffset = [g locationInView:btn];
            } else if (g.state == UIGestureRecognizerStateChanged) {
                CGPoint p = [g locationInView:_floatingWindow];
                btn.center = CGPointMake(p.x - startOffset.x + s/2, p.y - startOffset.y + s/2);
            }
        };
        [btn addGestureRecognizer:pan];

        [_floatingWindow.rootViewController.view addSubview:btn];
        _floatingWindow.mainButton = btn;
        _floatingBtn = btn;

        ab_ensureFloatingOnTop();
        _floatingWindow.hidden = NO;
        ABLog(@"🔴 悬浮窗已创建");
    });
}

static void ab_ensureFloatingOnTop(void) {
    if (!_floatingWindow) return;
    static BOOL _isAdjusting = NO;
    if (_isAdjusting) return;
    _isAdjusting = YES;

    if (!_isLearning) {
        CGFloat maxLevel = 0;
        @try {
            for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
                for (UIWindow *w in sc.windows) {
                    if (w != _floatingWindow && !w.hidden)
                        maxLevel = MAX(maxLevel, w.windowLevel);
                }
            }
        } @catch (NSException *e) {}
        CGFloat desired = MAX(maxLevel + 1.0, kMaxOtherWindowLevel + 1.0);
        if (_floatingWindow.windowLevel != desired)
            _floatingWindow.windowLevel = desired;
    }
    _floatingWindow.hidden = NO;
    _floatingWindow.alpha = 1.0;
    _isAdjusting = NO;
}

#pragma mark - 学习模式

static void ab_startLearningMode(void) {
    if (_isLearning) return;
    _isLearning = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        [_floatingBtn setTitle:@"学习中" forState:UIControlStateNormal];
        _floatingBtn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.9];
        _floatingWindow.windowLevel = kMaxOtherWindowLevel - 1.0;

        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        pulse.fromValue = @(1.0); pulse.toValue = @(1.15);
        pulse.duration = 0.6; pulse.autoreverses = YES; pulse.repeatCount = HUGE_VAL;
        [_floatingBtn.layer addAnimation:pulse forKey:@"learnPulse"];

        ab_showToast(@"📖 学习模式\n请点击「跳过」按钮", YES);

        _learnTimeoutBlock = ^{ ab_stopLearningMode(NO); };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLearnTimeout * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), _learnTimeoutBlock);
    });
}

static void ab_stopLearningMode(BOOL success) {
    if (!_isLearning) return;
    _isLearning = NO;
    _learnTimeoutBlock = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        [_floatingBtn setTitle:@"去广告" forState:UIControlStateNormal];
        _floatingBtn.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
        [_floatingBtn.layer removeAnimationForKey:@"learnPulse"];
        ab_ensureFloatingOnTop();
    });
}

static void _ab_handleLearningCapture(UITouch *touch, UIEvent *event) {
    if (!_isLearning || touch.phase != UITouchPhaseEnded || touch.tapCount != 1) return;
    if (touch.window == _floatingWindow) return;

    CGPoint screenPoint = [touch locationInView:nil];
    _capturedTapPoint = screenPoint;

    dispatch_async(dispatch_get_main_queue(), ^{
        _learnTimeoutBlock = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIWindow *topWin = _ab_topWindow();
            if (!topWin) { ab_stopLearningMode(NO); return; }

            CGPoint wp = [topWin convertPoint:screenPoint fromWindow:nil];
            UIView *hitView = [topWin hitTest:wp withEvent:nil];

            UIButton *skipBtn = nil;
            UIView *cur = hitView;
            while (cur) {
                if ([cur isKindOfClass:[UIButton class]]) { skipBtn = (UIButton *)cur; break; }
                cur = cur.superview;
            }

            // ← 修复：删除了未使用的 targets 变量和未完成的手势检测代码

            if (!skipBtn) {
                ab_stopLearningMode(NO);
                ab_showToast(@"❌ 未找到跳过按钮", NO);
                return;
            }

            NSString *title = skipBtn.titleLabel.text ?: skipBtn.currentTitle ?: @"";
            NSString *acc = skipBtn.accessibilityLabel ?: @"";
            BOOL isSkip = NO;
            for (NSString *kw in @[@"跳过", @"skip", @"Skip", @"关闭", @"close"]) {
                if ([title containsString:kw] || [acc containsString:kw]) { isSkip = YES; break; }
            }
            if (!isSkip) { ab_stopLearningMode(NO); return; }

            UIView *container = _ab_findAdContainer(skipBtn);
            NSString *adClass = container ? NSStringFromClass([container class]) : NSStringFromClass([skipBtn.superview class]);

            ABRule *rule = [ABRule new];
            rule.adViewClassName = adClass;
            rule.skipBtnClassName = NSStringFromClass([skipBtn class]);
            rule.skipBtnTitle = title;
            rule.skipBtnAccLabel = acc;
            rule.hitCount = 0;

            NSMutableArray *rules = [ABRule loadAllRules];
            BOOL dup = NO;
            for (ABRule *ex in rules) {
                if ([ex.adViewClassName isEqualToString:adClass]) { ex.hitCount++; dup = YES; break; }
            }
            if (!dup) [rules addObject:rule];
            [ABRule saveAllRules:rules];

            ab_stopLearningMode(YES);
            ab_showToast(@"✅ 规则已保存!", YES);
        });
    });
}

#pragma mark - 自动扫描

static void ab_scanAndAutoSkip(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHeuristicDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *top = _ab_topWindow();
        if (!top) { ab_showToast(@"⚠️ 未找到广告窗口", NO); return; }

        UIView *rootView = top.rootViewController.view ?: top;
        BOOL skipped = NO;

        for (ABRule *rule in [ABRule loadAllRules]) {
            UIButton *btn = nil;
            if ([rule matchesAdView:rootView skipButton:&btn]) {
                ab_simulateTapOnView(btn);
                rule.hitCount++;
                skipped = YES;
                break;
            }
            for (UIView *sub in rootView.subviews) {
                if ([rule matchesAdView:sub skipButton:&btn]) {
                    ab_simulateTapOnView(btn);
                    rule.hitCount++;
                    skipped = YES;
                    break;
                }
            }
            if (skipped) break;
        }

        if (!skipped) {
            UIButton *btn = _ab_findSkipButton(rootView);
            if (btn) { ab_simulateTapOnView(btn); skipped = YES; }
        }

        if (skipped) {
            ab_showToast(@"✅ 广告已跳过", YES);
        } else {
            ab_showToast(@"❌ 未发现广告", NO);
        }
    });
}

#pragma mark - Toast

static void ab_showToast(NSString *text, BOOL isSuccess) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_floatingWindow) return;
        UILabel *label = [[UILabel alloc] init];
        label.text = text;
        label.numberOfLines = 0;
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = isSuccess
            ? [[UIColor systemGreenColor] colorWithAlphaComponent:0.85]
            : [[UIColor systemGrayColor] colorWithAlphaComponent:0.85];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.layer.cornerRadius = 12;
        label.layer.masksToBounds = YES;

        CGFloat maxWidth = [UIScreen mainScreen].bounds.size.width - 60;
        CGSize size = [text boundingRectWithSize:CGSizeMake(maxWidth, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:@{NSFontAttributeName: label.font}
                                         context:nil].size;
        label.frame = CGRectMake(0, 0, MIN(size.width + 30, maxWidth), size.height + 20);
        label.center = CGPointMake(_floatingWindow.bounds.size.width / 2,
                                    _floatingWindow.bounds.size.height - 120);
        [_floatingWindow.rootViewController.view addSubview:label];
        label.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{ label.alpha = 1; }
                         completion:^(BOOL f) {
            [UIView animateWithDuration:0.3 delay:2.0 options:0 animations:^{ label.alpha = 0; }
                             completion:^(BOOL f2) { [label removeFromSuperview]; }];
        }];
    });
}

#pragma mark - UIWindow Hooks

static void (*_orig_sendTouchesForEvent)(id, SEL, NSSet *, UIEvent *) = NULL;
static void (*_orig_setWindowLevel)(id, SEL, CGFloat) = NULL;
static void (*_orig_setHidden)(id, SEL, BOOL) = NULL;
static void (*_orig_makeKeyAndVisible)(id, SEL) = NULL;

static void _hooked_sendTouchesForEvent(UIWindow *self, SEL _cmd, NSSet *touches, UIEvent *event) {
    if (_orig_sendTouchesForEvent) _orig_sendTouchesForEvent(self, _cmd, touches, event);
    @try {
        if (_isLearning) {
            for (UITouch *touch in touches) {
                if (touch.window == _floatingWindow) continue;
                _ab_handleLearningCapture(touch, event);
                break;
            }
        }
    } @catch (NSException *e) {}
}

static BOOL _isInWindowLevelHook = NO;
static void _hooked_setWindowLevel(UIWindow *self, SEL _cmd, CGFloat level) {
    if (_isInWindowLevelHook) {
        if (_orig_setWindowLevel) _orig_setWindowLevel(self, _cmd, level);
        return;
    }
    _isInWindowLevelHook = YES;
    if (self != _floatingWindow && level > kMaxOtherWindowLevel) level = kMaxOtherWindowLevel;
    if (_orig_setWindowLevel) _orig_setWindowLevel(self, _cmd, level);
    if (self != _floatingWindow && !_isLearning) {
        dispatch_async(dispatch_get_main_queue(), ^{ ab_ensureFloatingOnTop(); });
    }
    _isInWindowLevelHook = NO;
}

static void _hooked_setHidden(UIWindow *self, SEL _cmd, BOOL hidden) {
    if (self == _floatingWindow && hidden) return;
    if (_orig_setHidden) _orig_setHidden(self, _cmd, hidden);
}

static void _hooked_makeKeyAndVisible(UIWindow *self, SEL _cmd) {
    if (_orig_makeKeyAndVisible) _orig_makeKeyAndVisible(self, _cmd);
    if (self != _floatingWindow && !_isLearning) {
        dispatch_async(dispatch_get_main_queue(), ^{ ab_ensureFloatingOnTop(); });
    }
}

// ← 修复：函数定义在前向声明之后，不再报 implicit declaration
static void _ab_installUIWindowHooks(void) {
    static BOOL hooksInstalled = NO;
    if (hooksInstalled) return;
    hooksInstalled = YES;

    Class winClass = [UIWindow class];

    SEL sendSel = NSSelectorFromString(@"_sendTouchesForEvent:");
    Method sendMethod = class_getInstanceMethod(winClass, sendSel);
    if (sendMethod) {
        IMP newImp = imp_implementationWithBlock(^(UIWindow *self, NSSet *touches, UIEvent *event) {
            _hooked_sendTouchesForEvent(self, sendSel, touches, event);
        });
        _orig_sendTouchesForEvent = (void(*)(id,SEL,NSSet*,UIEvent*))method_setImplementation(sendMethod, newImp);
    }

    Method levelMethod = class_getInstanceMethod(winClass, @selector(setWindowLevel:));
    if (levelMethod) {
        IMP newImp = imp_implementationWithBlock(^(UIWindow *self, CGFloat level) {
            _hooked_setWindowLevel(self, @selector(setWindowLevel:), level);
        });
        _orig_setWindowLevel = (void(*)(id,SEL,CGFloat))method_setImplementation(levelMethod, newImp);
    }

    Method hiddenMethod = class_getInstanceMethod(winClass, @selector(setHidden:));
    if (hiddenMethod) {
        IMP newImp = imp_implementationWithBlock(^(UIWindow *self, BOOL hidden) {
            _hooked_setHidden(self, @selector(setHidden:), hidden);
        });
        _orig_setHidden = (void(*)(id,SEL,BOOL))method_setImplementation(hiddenMethod, newImp);
    }

    Method visibleMethod = class_getInstanceMethod(winClass, @selector(makeKeyAndVisible));
    if (visibleMethod) {
        IMP newImp = imp_implementationWithBlock(^(UIWindow *self) {
            _hooked_makeKeyAndVisible(self, @selector(makeKeyAndVisible));
        });
        _orig_makeKeyAndVisible = (void(*)(id,SEL))method_setImplementation(visibleMethod, newImp);
    }

    ABLog(@"✅ UIWindow Hooks 安装完成");
}

#pragma mark - 初始化

__attribute__((constructor))
static void _adblock_init(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _ab_hookKnownSDKs();

        // ← 修复：保存 observer 引用以便安全移除
        _activeObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (!_isInitialized) {
                        _isInitialized = YES;
                        _ab_installUIWindowHooks();
                        ab_createFloatingWindow();
                        ab_showToast(@"✅ AdBlock v2.1 已加载", YES);
                    } else {
                        ab_scanAndAutoSkip();
                    }
                });
            }];

        // ← 修复：使用具体 observer 对象移除，而非 nil
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillTerminateNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) {
                if (_activeObserver) {
                    [[NSNotificationCenter defaultCenter] removeObserver:_activeObserver];
                    _activeObserver = nil;
                }
            }];
    });
}
