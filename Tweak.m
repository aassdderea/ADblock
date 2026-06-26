// ==========================================
// Tweak.m - 通用去开屏广告插件（终极调试版）
// 适用于 iOS 16.6 + TrollStore
// ==========================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------- 可调参数 ----------
#define SKIP_BTN_CHECK_DELAY  1.0
#define HEURISTIC_CHECK_DELAY 1.5
#define LONG_PRESS_DURATION   1.0
#define LEARN_TIMEOUT         10.0
#define GUARD_INTERVAL        0.3
#define FLOATING_LEVEL        (UIWindowLevelStatusBar + 100000) // 极高但安全
// ------------------------------

#define TESTLOG(fmt, ...) NSLog(@"[AD-BLOCKER] " fmt, ##__VA_ARGS__)

// ---------- 前向声明 ----------
@class _FloatingWindow;
static void startLearningMode(void);
static void stopLearningMode(void);
static void ensureFloatingOnTop(void);
static void scanForAdsInTopWindow(void);
static UIButton *findSkipButtonInView(UIView *v);
static UIView *findFullScreenContainer(UIView *v);
static UIView *findViewWithClass(UIView *root, NSString *className);
static void addRule(NSString *adClass, NSString *btnClass, NSString *titleKeyword, NSString *accLabel);
static BOOL tryAutoSkipWithRules(UIView *adView);
static void showLoadedToast(void);
static void createFloatingWindow(void);
static void dumpAllWindows(void);

// ---------- 手势辅助类 ----------
@interface _AdBlockGestureHandler : NSObject
@property (nonatomic, copy) void (^panBlock)(UIPanGestureRecognizer *);
@property (nonatomic, copy) void (^longPressBlock)(UILongPressGestureRecognizer *);
- (void)handlePan:(UIPanGestureRecognizer *)g;
- (void)handleLongPress:(UILongPressGestureRecognizer *)g;
@end
@implementation _AdBlockGestureHandler
- (void)handlePan:(UIPanGestureRecognizer *)g { if(self.panBlock) self.panBlock(g); }
- (void)handleLongPress:(UILongPressGestureRecognizer *)g { if(self.longPressBlock) self.longPressBlock(g); }
@end

// ---------- 自定义窗口（触摸穿透） ----------
@interface _FloatingWindow : UIWindow
@property (nonatomic, weak) UIButton *actionButton;
@end
@implementation _FloatingWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.actionButton && CGRectContainsPoint(self.actionButton.frame, point))
        return self.actionButton;
    return nil;
}
// 拒绝成为 key window，避免干扰其他窗口
- (BOOL)_canBecomeKeyWindow { return NO; }
@end

// ---------- 全局变量 ----------
static _FloatingWindow *floatingWindow = nil;
static UIButton *floatingBtn = nil;
static _AdBlockGestureHandler *gestureHandler = nil;
static BOOL learningMode = NO;
static NSTimer *learnTimeout = nil;
static BOOL learnRecorded = NO;
static NSTimer *guardTimer = nil;

// ---------- 方法替换 ----------
static void replaceInstanceMethod(Class cls, SEL sel, id impBlock, IMP *origPtr) {
    Method m = class_getInstanceMethod(cls, sel);
    if(!m) return;
    IMP imp = imp_implementationWithBlock(impBlock);
    if(origPtr) *origPtr = method_setImplementation(m, imp);
    else method_setImplementation(m, imp);
}

// ---------- 触摸模拟（高仿真） ----------
static void simulateTapAtPoint(CGPoint screenPoint) {
    CGFloat jitterX = ((CGFloat)arc4random() / UINT32_MAX) * 4 - 2;
    CGFloat jitterY = ((CGFloat)arc4random() / UINT32_MAX) * 4 - 2;
    CGPoint point = CGPointMake(screenPoint.x + jitterX, screenPoint.y + jitterY);

    UIWindow *target = nil;
    CGFloat maxL = -1;
    if(@available(iOS 13.0,*)){
        for(UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes){
            if(sc.activationState == UISceneActivationStateForegroundActive){
                for(UIWindow *w in sc.windows){
                    if(!w.hidden && w.alpha>0.01 && w.windowLevel>maxL){ maxL=w.windowLevel; target=w; }
                }
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if(!target) for(UIWindow *w in [UIApplication sharedApplication].windows) if(!w.hidden&&w.alpha>0.01&&w.windowLevel>maxL){ maxL=w.windowLevel; target=w; }
#pragma clang diagnostic pop
    if(!target) return;
    CGPoint wp = [target convertPoint:point fromWindow:nil];
    UIView *hit = [target hitTest:wp withEvent:nil] ?: target;
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:hit forKey:@"view"];
    [touch setValue:@(wp) forKey:@"locationInWindow"];
    [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    [touch setValue:@(1) forKey:@"tapCount"];
    [touch setValue:@(1.0) forKey:@"force"];
    [touch setValue:@(5.0) forKey:@"majorRadius"];
    NSTimeInterval timestamp = [[NSProcessInfo processInfo] systemUptime];
    [touch setValue:@(timestamp) forKey:@"timestamp"];
    UIEvent *ev = [[UIEvent alloc] init];
    [ev setValue:@[touch] forKey:@"touches"];
    [ev setValue:@(UIEventTypeTouches) forKey:@"type"];
    [ev setValue:@(timestamp) forKey:@"timestamp"];
    [hit touchesBegan:[NSSet setWithObject:touch] withEvent:ev];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        [touch setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"timestamp"];
        UIEvent *endEv = [[UIEvent alloc] init];
        [endEv setValue:@[touch] forKey:@"touches"];
        [endEv setValue:@(UIEventTypeTouches) forKey:@"type"];
        [endEv setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"timestamp"];
        [hit touchesEnded:[NSSet setWithObject:touch] withEvent:endEv];
    });
}

static CGPoint screenPointForView(UIView *v) {
    CGRect r = [v convertRect:v.bounds toView:nil];
    return CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
}

// ---------- 已知 SDK 拦截 ----------
static BOOL knownHooked = NO;
static void applyKnownSDKHooks() {
    if(knownHooked) return; knownHooked=YES;
    Class c;
    c=NSClassFromString(@"BUSplashAdView");
    if(c) replaceInstanceMethod(c,@selector(showInWindow:),^(id s,UIWindow *w){
        id d=[s valueForKey:@"delegate"];
        if(d&&[d respondsToSelector:@selector(splashAdDidClose:)]) [d performSelector:@selector(splashAdDidClose:) withObject:s];
    },NULL);
    c=NSClassFromString(@"GDTSplashAd");
    if(c) replaceInstanceMethod(c,@selector(loadAndShowInWindow:),^(id s,UIWindow *w){
        id d=[s valueForKey:@"delegate"];
        if(d&&[d respondsToSelector:@selector(splashAdDidDismiss:)]) [d performSelector:@selector(splashAdDidDismiss:) withObject:s];
    },NULL);
    c=NSClassFromString(@"BaiduMobAdSplash");
    if(c) replaceInstanceMethod(c,@selector(showInWindow:),^(id s,UIWindow *w){
        id d=[s valueForKey:@"delegate"];
        if(d&&[d respondsToSelector:@selector(splashAdDidClose:)]) [d performSelector:@selector(splashAdDidClose:) withObject:s];
    },NULL);
}

// ---------- 规则存储 ----------
static NSString *rulesPath() {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"com.adblocker.rules.plist"];
}
static NSMutableArray *loadRules() {
    NSArray *a = [NSArray arrayWithContentsOfFile:rulesPath()];
    return a ? [a mutableCopy] : [NSMutableArray array];
}
static void saveRules(NSArray *r) { [r writeToFile:rulesPath() atomically:YES]; }
static void addRule(NSString *adClass, NSString *btnClass, NSString *titleKeyword, NSString *accLabel) {
    NSMutableArray *rules = loadRules();
    for(NSDictionary *r in rules) if([r[@"adViewClass"] isEqualToString:adClass]) return;
    NSDictionary *rule = @{@"adViewClass":adClass, @"skipBtnClass":btnClass ?: @"",
                           @"skipBtnTitle":titleKeyword ?: @"", @"skipBtnAccLabel":accLabel ?: @""};
    [rules addObject:rule];
    saveRules(rules);
    TESTLOG(@"✅ 规则保存: ad=%@, btn=%@, title=%@", adClass, btnClass, titleKeyword);
}
static BOOL tryAutoSkipWithRules(UIView *adView) {
    NSArray *rules = loadRules();
    for(NSDictionary *r in rules) {
        if(![NSStringFromClass([adView class]) isEqualToString:r[@"adViewClass"]]) continue;
        UIButton *skip = nil;
        NSString *bCls = r[@"skipBtnClass"];
        if(bCls.length) for(UIView *s in adView.subviews) if([s isKindOfClass:[UIButton class]] && [NSStringFromClass([s class]) isEqualToString:bCls]) { skip=(UIButton*)s; break; }
        if(!skip) for(UIView *s in adView.subviews) { UIButton *b = findSkipButtonInView(s); if(b) { skip=b; break; } }
        if(skip) simulateTapAtPoint(screenPointForView(skip));
        else [adView removeFromSuperview];
        return YES;
    }
    return NO;
}

// ---------- 查找跳过按钮 ----------
static UIButton *findSkipButtonInView(UIView *v) {
    if([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        NSString *t = b.titleLabel.text ?: b.accessibilityLabel;
        if(t && ([t containsString:@"跳过"]||[t containsString:@"Skip"]||[t containsString:@"关闭"])) return b;
    }
    for(UIView *sub in v.subviews) { UIButton *r = findSkipButtonInView(sub); if(r) return r; }
    return nil;
}

// ---------- 向上查找全屏容器视图 ----------
static UIView *findFullScreenContainer(UIView *v) {
    CGRect screen = [UIScreen mainScreen].bounds;
    UIView *cur = v.superview;
    while(cur) {
        if(cur.frame.size.width >= screen.size.width*0.8 && cur.frame.size.height >= screen.size.height*0.8)
            return cur;
        cur = cur.superview;
    }
    return nil;
}

// ---------- 递归按类名查找视图 ----------
static UIView *findViewWithClass(UIView *root, NSString *className) {
    if ([NSStringFromClass([root class]) isEqualToString:className]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = findViewWithClass(sub, className);
        if (found) return found;
    }
    return nil;
}

// ---------- 调试：打印所有窗口信息 ----------
static void dumpAllWindows() {
    NSMutableString *dbg = [NSMutableString stringWithString:@"\n=== 当前所有窗口 ===\n"];
    for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
        for (UIWindow *w in sc.windows) {
            [dbg appendFormat:@"  %@: level=%.0f hidden=%d alpha=%.2f frame=%@\n",
             NSStringFromClass([w class]), w.windowLevel, w.hidden, w.alpha, NSStringFromCGRect(w.frame)];
        }
    }
    [dbg appendString:@"=======================\n"];
    TESTLOG(@"%@", dbg);
}

// ---------- 学习模式 ----------
static void startLearningMode() {
    if(learningMode) return;
    learningMode = YES;
    learnRecorded = NO;
    [floatingBtn setTitle:@"学习中" forState:UIControlStateNormal];
    floatingBtn.backgroundColor = [UIColor blueColor];
    TESTLOG(@"📖 学习模式启动");
    [learnTimeout invalidate];
    learnTimeout = [NSTimer scheduledTimerWithTimeInterval:LEARN_TIMEOUT repeats:NO block:^(NSTimer * _) {
        TESTLOG(@"⏰ 学习模式超时自动退出");
        stopLearningMode();
    }];
}

static void stopLearningMode() {
    if(!learningMode) return;
    learningMode = NO;
    [learnTimeout invalidate];
    learnTimeout = nil;
    [floatingBtn setTitle:@"去广告" forState:UIControlStateNormal];
    floatingBtn.backgroundColor = [UIColor redColor];
    ensureFloatingOnTop();
    TESTLOG(@"📖 学习模式已退出");
}

// ========== 悬浮窗置顶（不成为key window） ==========
static void ensureFloatingOnTop() {
    if (!floatingWindow) return;
    floatingWindow.windowLevel = FLOATING_LEVEL;
    floatingWindow.hidden = NO;
    // 不再调用 makeKeyAndVisible，避免干扰其他窗口
    if (!floatingWindow.isKeyWindow) {
        // 如果确实需要成为key window才能接收事件？不需要，我们的触摸穿透窗口不需要key window。
    }
    // 调试日志
    TESTLOG(@"🔝 悬浮窗置顶: level=%.0f hidden=%d key=%d", floatingWindow.windowLevel, floatingWindow.hidden, floatingWindow.isKeyWindow);
}

// 守护定时器
static void startGuardTimer() {
    [guardTimer invalidate];
    guardTimer = [NSTimer scheduledTimerWithTimeInterval:GUARD_INTERVAL repeats:YES block:^(NSTimer *timer) {
        if (!floatingWindow) return;
        BOOL needFix = (floatingWindow.windowLevel < FLOATING_LEVEL - 1000) || floatingWindow.hidden;
        if (needFix) {
            TESTLOG(@"🔧 守护发现异常 (level=%.0f hidden=%d)，强制置顶", floatingWindow.windowLevel, floatingWindow.hidden);
            ensureFloatingOnTop();
        }
    }];
}

// ---------- 悬浮窗创建 ----------
static void createFloatingWindow() {
    if(floatingWindow) return;
    floatingWindow = [[_FloatingWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    if(@available(iOS 13.0,*)){
        for(UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if(sc.activationState == UISceneActivationStateForegroundActive){ floatingWindow.windowScene=sc; break; }
        }
        if(!floatingWindow.windowScene) for(UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) if([sc isKindOfClass:[UIWindowScene class]]){ floatingWindow.windowScene=sc; break; }
    }
    floatingWindow.backgroundColor = [UIColor clearColor];
    floatingWindow.userInteractionEnabled = YES;
    floatingWindow.rootViewController = [UIViewController new];
    floatingWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    ensureFloatingOnTop(); // 设置层级并显示

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    CGFloat s = 60;
    btn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width-s-20, 150, s, s);
    btn.backgroundColor = [UIColor redColor];
    btn.layer.cornerRadius = s/2;
    btn.layer.borderWidth = 3; btn.layer.borderColor = [UIColor whiteColor].CGColor;
    btn.layer.shadowOffset = CGSizeMake(0,4); btn.layer.shadowOpacity = 0.8;
    [btn setTitle:@"去广告" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];

    [btn addAction:[UIAction actionWithHandler:^(id _){ 
        if(learningMode) { stopLearningMode(); return; }
        TESTLOG(@"🔘 扫描广告"); 
        scanForAdsInTopWindow(); 
    }] forControlEvents:UIControlEventTouchUpInside];

    gestureHandler = [[_AdBlockGestureHandler alloc] init];
    gestureHandler.panBlock = ^(UIPanGestureRecognizer *g){
        static CGPoint start;
        if(g.state == UIGestureRecognizerStateBegan) start = [g locationInView:btn];
        else { CGPoint p = [g locationInView:floatingWindow]; btn.frame = CGRectMake(p.x-start.x, p.y-start.y, s, s); }
    };
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gestureHandler action:@selector(handlePan:)];
    [btn addGestureRecognizer:pan];

    gestureHandler.longPressBlock = ^(UILongPressGestureRecognizer *g){
        if(g.state == UIGestureRecognizerStateBegan) {
            if(!learningMode) startLearningMode();
        }
    };
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:gestureHandler action:@selector(handleLongPress:)];
    lp.minimumPressDuration = LONG_PRESS_DURATION;
    lp.allowableMovement = 10;
    [btn addGestureRecognizer:lp];

    [floatingWindow.rootViewController.view addSubview:btn];
    floatingWindow.actionButton = btn;
    floatingBtn = btn;
    startGuardTimer();
    TESTLOG(@"🔴 悬浮窗创建完成 (level: %.0f)", floatingWindow.windowLevel);
    dumpAllWindows(); // 创建时打印一次窗口列表
}

// ---------- 扫描广告 ----------
static void scanForAdsInTopWindow() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, HEURISTIC_CHECK_DELAY*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIWindow *top = nil; CGFloat maxL = -1;
        if(@available(iOS 13.0,*)) for(UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) if(sc.activationState == UISceneActivationStateForegroundActive) for(UIWindow *w in sc.windows) if(!w.hidden && w.alpha>0.01 && w.windowLevel>maxL){ maxL=w.windowLevel; top=w; }
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if(!top) for(UIWindow *w in [UIApplication sharedApplication].windows) if(!w.hidden && w.alpha>0.01 && w.windowLevel>maxL){ maxL=w.windowLevel; top=w; }
        #pragma clang diagnostic pop
        if(!top) return;

        NSArray *rules = loadRules();
        if (!rules.count) return;
        UIView *rootView = top.rootViewController.view ?: top;
        for (NSDictionary *rule in rules) {
            NSString *adClassName = rule[@"adViewClass"];
            if (!adClassName.length) continue;
            UIView *adView = findViewWithClass(rootView, adClassName);
            if (adView) {
                if (tryAutoSkipWithRules(adView)) {
                    TESTLOG(@"✅ 自动跳过成功 (规则: %@)", adClassName);
                }
            }
        }
    });
}

// ---------- Hook sendEvent: 学习模式过滤 ----------
static void (*orig_sendEvent)(id, SEL, UIEvent *);
static void swizzled_sendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    if(learningMode && !learnRecorded && event.type == UIEventTypeTouches) {
        NSSet *touches = [event allTouches];
        for(UITouch *touch in touches) {
            if(touch.phase == UITouchPhaseEnded && touch.tapCount == 1) {
                UIView *view = touch.view;
                UIWindow *touchWindow = touch.window;
                CGFloat maxLevel = -1;
                UIWindow *topWin = nil;
                for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
                    for (UIWindow *w in sc.windows) {
                        if (w.windowLevel > maxLevel) { maxLevel = w.windowLevel; topWin = w; }
                    }
                }
                if (touchWindow != topWin) break;
                if([view isKindOfClass:[UIButton class]]) {
                    UIButton *btn = (UIButton *)view;
                    NSString *title = btn.titleLabel.text ?: btn.accessibilityLabel ?: @"";
                    if([title containsString:@"跳过"] || [title containsString:@"Skip"] || [title containsString:@"关闭"]) {
                        learnRecorded = YES;
                        NSString *btnClass = NSStringFromClass([btn class]);
                        NSString *fixed = @"";
                        if([title containsString:@"跳过"]) fixed = @"跳过";
                        else if([title containsString:@"Skip"]) fixed = @"Skip";
                        else if([title containsString:@"关闭"]) fixed = @"关闭";
                        NSString *accLabel = btn.accessibilityLabel;
                        UIView *container = findFullScreenContainer(btn);
                        NSString *adClass = container ? NSStringFromClass([container class]) : @"UnknownAdView";
                        TESTLOG(@"📝 记录学习规则: adView=%@, skipBtn=%@, keyword=%@", adClass, btnClass, fixed);
                        addRule(adClass, btnClass, fixed, accLabel);
                        stopLearningMode();
                        orig_sendEvent(self, _cmd, event);
                        return;
                    }
                }
            }
        }
    }
    orig_sendEvent(self, _cmd, event);
}

// ---------- Hook setWindowLevel: 监控及抢回 ----------
static void (*orig_setWindowLevel)(id, SEL, CGFloat);
static void swizzled_setWindowLevel(UIWindow *self, SEL _cmd, CGFloat level) {
    orig_setWindowLevel(self, _cmd, level);
    if (!floatingWindow || self == floatingWindow) return;
    TESTLOG(@"⚠️ 窗口 %@ 设置层级为 %.0f", NSStringFromClass([self class]), level);
    if (level >= floatingWindow.windowLevel) {
        TESTLOG(@"🆘 窗口层级超越悬浮窗，强制置顶");
        ensureFloatingOnTop();
    }
}

// ---------- Hook setHidden: 防止悬浮窗被隐藏 ----------
static void (*orig_setHidden)(id, SEL, BOOL);
static void swizzled_setHidden(UIWindow *self, SEL _cmd, BOOL hidden) {
    if (self == floatingWindow && hidden) {
        TESTLOG(@"🛑 拦截企图隐藏悬浮窗");
        return;
    }
    orig_setHidden(self, _cmd, hidden);
}

// ---------- UIWindow makeKeyAndVisible 监控 ----------
static void (*orig_makeKeyAndVisible)(id, SEL);
static void swizzled_makeKeyAndVisible(UIWindow *self, SEL _cmd) {
    orig_makeKeyAndVisible(self, _cmd);
    if (self == floatingWindow) return;
    TESTLOG(@"📌 窗口 %@ 变为KeyWindow", NSStringFromClass([self class]));
    ensureFloatingOnTop();
    dumpAllWindows(); // 有窗口成为 key 时打印窗口列表
}

// ---------- Toast ----------
static void showLoadedToast() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        if(@available(iOS 13.0,*)) for(UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) if(sc.activationState==UISceneActivationStateForegroundActive){ w.windowScene=sc; break; }
        w.windowLevel = UIWindowLevelAlert+999; w.backgroundColor=[UIColor clearColor]; w.userInteractionEnabled=NO; w.hidden=NO;
        UILabel *l = [UILabel new]; l.text=@"✅ AdBlock 已加载"; l.textColor=[UIColor whiteColor]; l.backgroundColor=[[UIColor blackColor] colorWithAlphaComponent:0.7]; l.textAlignment=NSTextAlignmentCenter; l.font=[UIFont systemFontOfSize:16]; l.layer.cornerRadius=10; l.layer.masksToBounds=YES;
        [l sizeToFit]; CGRect f=l.frame; f.size.width+=30; f.size.height+=16; l.frame=f; l.center=CGPointMake(w.bounds.size.width/2, w.bounds.size.height-100);
        [w addSubview:l];
        l.alpha=0; [UIView animateWithDuration:0.3 animations:^{ l.alpha=1; } completion:^(BOOL done){ [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{ l.alpha=0; } completion:^(BOOL done){ w.hidden=YES; }]; }];
    });
}

// ========== 初始化 ==========
__attribute__((constructor))
static void adblock_init() {
    TESTLOG(@"🚀 初始化");
    applyKnownSDKHooks();

    Method levelMethod = class_getInstanceMethod([UIWindow class], @selector(setWindowLevel:));
    orig_setWindowLevel = (void (*)(id, SEL, CGFloat))method_getImplementation(levelMethod);
    method_setImplementation(levelMethod, (IMP)swizzled_setWindowLevel);

    Method hiddenMethod = class_getInstanceMethod([UIWindow class], @selector(setHidden:));
    orig_setHidden = (void (*)(id, SEL, BOOL))method_getImplementation(hiddenMethod);
    method_setImplementation(hiddenMethod, (IMP)swizzled_setHidden);

    Method keyMethod = class_getInstanceMethod([UIWindow class], @selector(makeKeyAndVisible));
    orig_makeKeyAndVisible = (void (*)(id, SEL))method_getImplementation(keyMethod);
    method_setImplementation(keyMethod, (IMP)swizzled_makeKeyAndVisible);

    Method sendMethod = class_getInstanceMethod([UIApplication class], @selector(sendEvent:));
    orig_sendEvent = (void (*)(id, SEL, UIEvent*))method_getImplementation(sendMethod);
    method_setImplementation(sendMethod, (IMP)swizzled_sendEvent);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *_){ 
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ 
            createFloatingWindow(); 
            scanForAdsInTopWindow(); 
        });
    }];

    showLoadedToast();
}
