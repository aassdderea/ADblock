#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#pragma mark - 配置常量

static NSString *const kPluginVersion = @"2.1";
static CGFloat const kFloatingButtonSize = 44.0;
// ← 修复：UIWindowLevelAlert 在旧SDK中不是编译期常量，直接硬编码 (2000.0 - 1.0)
static CGFloat const kMaxOtherWindowLevel = 1999.0;
static NSTimeInterval const kSimulateTouchDelay = 0.05;
static NSString *const kRulesFileName = @"AdBlockRules.plist";

#pragma mark - 日志宏

#define ABLog(fmt, ...) NSLog(@"[AD-BLOCK] " fmt, ##__VA_ARGS__)
#define ABWarn(fmt, ...) NSLog(@"[AD-BLOCK][WARN] " fmt, ##__VA_ARGS__)

#pragma mark - 全局状态

static UIWindow *_floatingWindow = nil;
static UIButton *_floatingButton = nil;
static BOOL _isLearning = NO;
static NSMutableArray *_learningSteps = nil;
static NSMutableDictionary *_savedRules = nil;

// ← 核心修复：递归保护锁
static BOOL _isSimulatingTouch = NO;
static BOOL _isAdjustingWindowLevel = NO;

// Hook 原始方法指针
static void (*_orig_sendTouchesForEvent)(UIWindow *, SEL, NSSet *, UIEvent *) = NULL;
static void (*_orig_setWindowLevel)(UIWindow *, SEL, CGFloat) = NULL;
static void (*_orig_setHidden)(UIWindow *, SEL, BOOL) = NULL;
static void (*_orig_makeKeyAndVisible)(UIWindow *, SEL) = NULL;

#pragma mark - 手势回调前置声明

static void _ab_onFloatingButtonTap(UITapGestureRecognizer *g);
static void _ab_onFloatingButtonLongPress(UILongPressGestureRecognizer *g);
static void _ab_onFloatingButtonPan(UIPanGestureRecognizer *g);

#pragma mark - 工具函数

static NSString *_ab_rulesFilePath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [[paths firstObject] stringByAppendingPathComponent:kRulesFileName];
}

static void _ab_loadRules(void) {
    @try {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:_ab_rulesFilePath()];
        _savedRules = dict ? [dict mutableCopy] : [NSMutableDictionary dictionary];
    } @catch (NSException *e) {
        _savedRules = [NSMutableDictionary dictionary];
    }
}

static void _ab_saveRules(void) {
    @try {
        [_savedRules writeToFile:_ab_rulesFilePath() atomically:YES];
    } @catch (NSException *e) {
        ABWarn(@"保存规则失败: %@", e);
    }
}

static UIWindow *_ab_topWindow(void) {
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w != _floatingWindow && !w.isHidden && w.windowLevel >= UIWindowLevelNormal) {
                    return w;
                }
            }
        }
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w != _floatingWindow && !w.isHidden && w.windowLevel >= UIWindowLevelNormal) return w;
    }
    return nil;
}

static void _ab_showToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *old = (UILabel *)[_floatingWindow viewWithTag:999];
        [old removeFromSuperview];

        UILabel *toast = [[UILabel alloc] init];
        toast.tag = 999;
        toast.text = message;
        toast.textColor = [UIColor whiteColor];
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        toast.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.layer.cornerRadius = 8;
        toast.clipsToBounds = YES;
        [toast sizeToFit];
        CGRect frame = toast.frame;
        frame.size.width += 32;
        frame.size.height += 16;

        UIWindow *win = _floatingWindow ?: _ab_topWindow();
        if (!win) return;
        toast.frame = frame;
        toast.center = CGPointMake(win.bounds.size.width / 2.0, win.bounds.size.height * 0.75);
        [win addSubview:toast];

        [UIView animateWithDuration:0.3 delay:1.5 options:0 animations:^{
            toast.alpha = 0;
        } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    });
}

#pragma mark - 悬浮窗置顶保障

static void ab_ensureFloatingOnTop(void) {
    if (!_floatingWindow || _isAdjustingWindowLevel) return;
    _isAdjustingWindowLevel = YES;
    @try {
        _floatingWindow.windowLevel = UIWindowLevelAlert + 100;
        _floatingWindow.hidden = NO;
        if (!_floatingWindow.isKeyWindow) {
            [_floatingWindow makeKeyAndVisible];
        }
    } @catch (NSException *e) {}
    _isAdjustingWindowLevel = NO;
}

#pragma mark - 触摸模拟（三级策略，防卡死版）

static BOOL _ab_tryDirectAction(UIButton *btn) {
    @try {
        SEL allTargetsSel = NSSelectorFromString(@"allTargets");
        SEL actionsForTargetSel = NSSelectorFromString(@"actionsForTarget:forControlEvents:");

        if (![btn respondsToSelector:allTargetsSel]) return NO;

        NSSet *targets = ((NSSet *(*)(id, SEL))objc_msgSend)(btn, allTargetsSel);
        if (targets.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
            });
            return YES;
        }

        for (id target in targets) {
            if (![btn respondsToSelector:actionsForTargetSel]) continue;
            NSArray *actions = ((NSArray *(*)(id, SEL, id, NSUInteger))objc_msgSend)(
                btn, actionsForTargetSel, target, UIControlEventTouchUpInside);
            for (NSString *actionName in actions ?: @[]) {
                SEL sel = NSSelectorFromString(actionName);
                if ([target respondsToSelector:sel]) {
                    ABLog(@"策略1: 直接调用 %@ → %@", NSStringFromClass([target class]), actionName);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ((void(*)(id, SEL))objc_msgSend)(target, sel);
                    });
                    return YES;
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        });
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

    _isSimulatingTouch = YES;

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

            dispatch_async(dispatch_get_main_queue(), ^{
                _isSimulatingTouch = NO;
            });
        });
    } @catch (NSException *e) {
        ABWarn(@"策略2失败，回退策略3: %@", e);
        UITouch *fallbackTouch = [[UITouch alloc] init];
        [fallbackTouch setValue:@(windowPoint) forKey:@"locationInWindow"];
        [fallbackTouch setValue:hitView forKey:@"view"];
        [fallbackTouch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
        [hitView touchesBegan:[NSSet setWithObject:fallbackTouch] withEvent:nil];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSimulateTouchDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [fallbackTouch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
            [hitView touchesEnded:[NSSet setWithObject:fallbackTouch] withEvent:nil];
            _isSimulatingTouch = NO;
        });
    }
}

static void _ab_simulateTapOnView(UIView *view) {
    if (!view) return;
    CGPoint center = [view.superview convertPoint:view.center toView:nil];

    if ([view isKindOfClass:[UIButton class]]) {
        if (_ab_tryDirectAction((UIButton *)view)) return;
    }

    _ab_injectTouchViaSendEvent(center);
}

#pragma mark - 学习模式捕获

static void _ab_handleLearningCapture(UITouch *touch, UIEvent *event) {
    if (!_isLearning || !touch) return;

    UIView *view = touch.view;
    if (!view || view == _floatingWindow || [view isDescendantOfView:_floatingWindow]) return;

    NSMutableDictionary *step = [NSMutableDictionary dictionary];
    step[@"className"] = NSStringFromClass([view class]);
    step[@"frame"] = NSStringFromCGRect(view.frame);
    step[@"tag"] = @(view.tag);

    if (view.accessibilityIdentifier.length > 0) {
        step[@"accessibilityId"] = view.accessibilityIdentifier;
    }

    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        step[@"buttonTitle"] = [btn titleForState:UIControlStateNormal] ?: @"";
    }

    [_learningSteps addObject:step];
    ABLog(@"学习模式捕获: %@ tag=%ld", step[@"className"], (long)view.tag);
    _ab_showToast([NSString stringWithFormat:@"📝 已记录步骤 %lu", (unsigned long)_learningSteps.count]);
}

#pragma mark - UIWindow Hooks（带递归保护）

static void _hooked_sendTouchesForEvent(UIWindow *self, SEL _cmd, NSSet *touches, UIEvent *event) {
    if (_isSimulatingTouch) {
        if (_orig_sendTouchesForEvent) _orig_sendTouchesForEvent(self, _cmd, touches, event);
        return;
    }

    if (_orig_sendTouchesForEvent) _orig_sendTouchesForEvent(self, _cmd, touches, event);

    @try {
        if (_isLearning) {
            for (UITouch *touch in touches) {
                if (touch.phase == UITouchPhaseBegan && touch.window != _floatingWindow) {
                    _ab_handleLearningCapture(touch, event);
                    break;
                }
            }
        }
    } @catch (NSException *e) {}
}

static void _hooked_setWindowLevel(UIWindow *self, SEL _cmd, CGFloat level) {
    if (_isAdjustingWindowLevel) {
        if (_orig_setWindowLevel) _orig_setWindowLevel(self, _cmd, level);
        return;
    }

    _isAdjustingWindowLevel = YES;

    if (self != _floatingWindow && level > kMaxOtherWindowLevel) {
        level = kMaxOtherWindowLevel;
    }
    if (_orig_setWindowLevel) _orig_setWindowLevel(self, _cmd, level);

    if (self != _floatingWindow && !_isLearning && !_isSimulatingTouch) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ab_ensureFloatingOnTop();
        });
    }

    _isAdjustingWindowLevel = NO;
}

static void _hooked_setHidden(UIWindow *self, SEL _cmd, BOOL hidden) {
    if (_orig_setHidden) _orig_setHidden(self, _cmd, hidden);
    if (self == _floatingWindow && hidden && !_isLearning) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ab_ensureFloatingOnTop();
        });
    }
}

static void _hooked_makeKeyAndVisible(UIWindow *self, SEL _cmd) {
    if (_orig_makeKeyAndVisible) _orig_makeKeyAndVisible(self, _cmd);
    if (self != _floatingWindow && !_isLearning && !_isSimulatingTouch) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ab_ensureFloatingOnTop();
        });
    }
}

#pragma mark - Hook 安装

static void _ab_installUIWindowHooks(void) {
    Class cls = [UIWindow class];

    Method m1 = class_getInstanceMethod(cls, @selector(sendTouchesForEvent:));
    if (m1) {
        _orig_sendTouchesForEvent = (void (*)(UIWindow *, SEL, NSSet *, UIEvent *))method_getImplementation(m1);
        method_setImplementation(m1, (IMP)_hooked_sendTouchesForEvent);
    }

    Method m2 = class_getInstanceMethod(cls, @selector(setWindowLevel:));
    if (m2) {
        _orig_setWindowLevel = (void (*)(UIWindow *, SEL, CGFloat))method_getImplementation(m2);
        method_setImplementation(m2, (IMP)_hooked_setWindowLevel);
    }

    Method m3 = class_getInstanceMethod(cls, @selector(setHidden:));
    if (m3) {
        _orig_setHidden = (void (*)(UIWindow *, SEL, BOOL))method_getImplementation(m3);
        method_setImplementation(m3, (IMP)_hooked_setHidden);
    }

    Method m4 = class_getInstanceMethod(cls, @selector(makeKeyAndVisible));
    if (m4) {
        _orig_makeKeyAndVisible = (void (*)(UIWindow *, SEL))method_getImplementation(m4);
        method_setImplementation(m4, (IMP)_hooked_makeKeyAndVisible);
    }

    ABLog(@"✅ UIWindow Hooks 安装完成");
}

#pragma mark - 手势回调实现（兼容旧版 SDK）

static void _ab_onFloatingButtonTap(UITapGestureRecognizer *g) {
    if (g.state != UIGestureRecognizerStateRecognized) return;

    if (_isLearning) {
        if (_learningSteps.count > 0) {
            NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
            _savedRules[bundleId] = [_learningSteps copy];
            _ab_saveRules();
            _ab_showToast([NSString stringWithFormat:@"✅ 已保存 %lu 条规则", (unsigned long)_learningSteps.count]);
        } else {
            _ab_showToast(@"⚠️ 未捕获到任何步骤");
        }
        _isLearning = NO;
        [_floatingButton setTitle:@"去广告" forState:UIControlStateNormal];
        _floatingButton.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
        _learningSteps = nil;
    } else {
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        NSArray *rules = _savedRules[bundleId];
        if (rules.count == 0) {
            _ab_showToast(@"💡 长按按钮进入学习模式录制规则");
            return;
        }
        ABLog(@"执行 %lu 条规则", (unsigned long)rules.count);
        for (NSDictionary *step in rules) {
            UIWindow *win = _ab_topWindow();
            if (!win) break;
            NSString *clsName = step[@"className"];
            NSInteger tag = [step[@"tag"] integerValue];
            Class cls = NSClassFromString(clsName);
            if (!cls) continue;

            __block UIView *target = nil;
            NSMutableArray *queue = [NSMutableArray arrayWithObject:win.rootViewController.view];
            while (queue.count > 0 && !target) {
                UIView *v = queue.firstObject;
                [queue removeObjectAtIndex:0];
                if ([v isKindOfClass:cls] && v.tag == tag) {
                    target = v;
                    break;
                }
                for (UIView *sub in v.subviews) [queue addObject:sub];
            }

            if (target && !target.isHidden && target.alpha > 0.01) {
                _ab_simulateTapOnView(target);
                ABLog(@"命中规则: %@ tag=%ld", clsName, (long)tag);
            }
        }
        _ab_showToast(@"✅ 规则执行完成");
    }
}

static void _ab_onFloatingButtonLongPress(UILongPressGestureRecognizer *g) {
    if (g.state != UIGestureRecognizerStateBegan) return;

    _isLearning = !_isLearning;
    if (_isLearning) {
        _learningSteps = [NSMutableArray array];
        [_floatingButton setTitle:@"学习中" forState:UIControlStateNormal];
        _floatingButton.backgroundColor = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.9];
        _ab_showToast(@"📖 学习模式已开启，请点击跳过按钮");

        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        pulse.fromValue = @(1.0);
        pulse.toValue = @(1.15);
        pulse.duration = 0.6;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        [_floatingButton.layer addAnimation:pulse forKey:@"learningPulse"];
    } else {
        [_floatingButton setTitle:@"去广告" forState:UIControlStateNormal];
        _floatingButton.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
        [_floatingButton.layer removeAnimationForKey:@"learningPulse"];
        _learningSteps = nil;
        _ab_showToast(@"📖 学习模式已关闭");
    }
}

static void _ab_onFloatingButtonPan(UIPanGestureRecognizer *g) {
    CGPoint translation = [g translationInView:_floatingWindow.superview ?: g.view];
    CGRect frame = _floatingWindow.frame;
    frame.origin.x += translation.x;
    frame.origin.y += translation.y;

    // ← 新增：边界钳制，防止拖出屏幕导致点不到
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    frame.origin.x = MAX(0, MIN(frame.origin.x, screenBounds.size.width - kFloatingButtonSize));
    frame.origin.y = MAX(0, MIN(frame.origin.y, screenBounds.size.height - kFloatingButtonSize));

    _floatingWindow.frame = frame;
    [g setTranslation:CGPointZero inView:g.view];
}

#pragma mark - 悬浮窗 UI 构建

static void _ab_createFloatingUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_floatingWindow) return;

        // ← 修复1: 先获取真实屏幕尺寸，再创建 Window
        CGRect screenBounds = CGRectZero;
        UIWindowScene *activeScene = nil;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = scene;
                screenBounds = scene.coordinateSpace.bounds;
                break;
            }
        }
        // Fallback: 旧版 SDK 或 Scene 未就绪时使用 mainScreen
        if (CGRectIsEmpty(screenBounds) || CGRectEqualToRect(screenBounds, CGRectZero)) {
            screenBounds = [UIScreen mainScreen].bounds;
        }

        // ← 修复2: 初始位置直接设为屏幕右侧居中，而非 (0,0)
        CGFloat startX = screenBounds.size.width - kFloatingButtonSize - 20.0;
        CGFloat startY = screenBounds.size.height * 0.35;
        _floatingWindow = [[UIWindow alloc] initWithFrame:CGRectMake(startX, startY, kFloatingButtonSize, kFloatingButtonSize)];
        _floatingWindow.windowLevel = UIWindowLevelAlert + 100;
        _floatingWindow.backgroundColor = [UIColor clearColor];
        _floatingWindow.layer.cornerRadius = kFloatingButtonSize / 2.0;
        _floatingWindow.clipsToBounds = YES;

        if (activeScene) {
            _floatingWindow.windowScene = activeScene;
        }

        _floatingButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _floatingButton.frame = _floatingWindow.bounds;
        _floatingButton.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
        [_floatingButton setTitle:@"去广告" forState:UIControlStateNormal];
        [_floatingButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _floatingButton.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        _floatingButton.layer.cornerRadius = kFloatingButtonSize / 2.0;

        // ← 兼容旧版 SDK：通过 class_addMethod 将 C 函数注册为 ObjC 方法
        class_addMethod([UIButton class], @selector(_ab_onFloatingButtonTap:),
                        (IMP)_ab_onFloatingButtonTap, "v@:@");
        class_addMethod([UIButton class], @selector(_ab_onFloatingButtonLongPress:),
                        (IMP)_ab_onFloatingButtonLongPress, "v@:@");
        class_addMethod([UIButton class], @selector(_ab_onFloatingButtonPan:),
                        (IMP)_ab_onFloatingButtonPan, "v@:@");

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:_floatingButton
                                                                              action:@selector(_ab_onFloatingButtonTap:)];
        tap.numberOfTapsRequired = 1;
        [_floatingButton addGestureRecognizer:tap];

        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:_floatingButton
                                                                                                action:@selector(_ab_onFloatingButtonLongPress:)];
        longPress.minimumPressDuration = 0.8;
        [_floatingButton addGestureRecognizer:longPress];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:_floatingButton
                                                                              action:@selector(_ab_onFloatingButtonPan:)];
        [_floatingButton addGestureRecognizer:pan];

        [_floatingWindow addSubview:_floatingButton];
        [_floatingWindow makeKeyAndVisible];

        // ← 修复3: makeKeyAndVisible 后再次强制校正位置（防止被系统重置）
        dispatch_async(dispatch_get_main_queue(), ^{
            CGRect safeFrame = CGRectMake(startX, startY, kFloatingButtonSize, kFloatingButtonSize);
            _floatingWindow.frame = safeFrame;
            _floatingWindow.hidden = NO;
            ABLog(@"✅ 悬浮窗最终位置: %@", NSStringFromCGRect(safeFrame));
        });

        ABLog(@"✅ 悬浮窗创建完成");
    });
}

#pragma mark - Constructor (TrollFools dyld 自动调用)

__attribute__((constructor))
static void _adblock_init(void) {
    @autoreleasepool {
        ABLog(@"🚀 AdBlock v%@ 初始化...", kPluginVersion);

        _ab_loadRules();
        _ab_installUIWindowHooks();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            _ab_createFloatingUI();
            _ab_showToast([NSString stringWithFormat:@"✅ AdBlock v%@ 已加载", kPluginVersion]);
        });
    }
}
