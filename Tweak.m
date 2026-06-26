// ==========================================
// Tweak.m - 通用去开屏广告插件（最终完美版）
// 适用于 iOS 16.6 + TrollStore
// ==========================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define SKIP_BTN_CHECK_DELAY  1.0
#define HEURISTIC_CHECK_DELAY 1.5
#define LONG_PRESS_DURATION   1.0
#define LEARN_TIMEOUT         10.0
#define MAX_OTHER_WINDOW_LEVEL 100000

#define TESTLOG(fmt, ...) NSLog(@"[AD-BLOCKER] " fmt, ##__VA_ARGS__)

// 前向声明
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
static void showRuleSavedToast(void);
static void createFloatingWindow(void);

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

@interface _FloatingWindow : UIWindow
@property (nonatomic, weak) UIButton *actionButton;
@end
@implementation _FloatingWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.actionButton && CGRectContainsPoint(self.actionButton.frame, point))
        return self.actionButton;
    return nil; // 穿透
}
- (BOOL)_canBecomeKeyWindow { return NO; }
@end

static _FloatingWindow *floatingWindow = nil;
static UIButton *floatingBtn = nil;
static _AdBlockGestureHandler *gestureHandler = nil;
static BOOL learningMode = NO;
static NSTimer *learnTimeout = nil;
static BOOL learnRecorded = NO;

static void replaceInstanceMethod(Class cls, SEL sel, id impBlock, IMP *origPtr) {
    Method m = class_getInstanceMethod(cls, sel);
    if(!m) return;
    IMP imp = imp_implementationWithBlock(impBlock);
    if(origPtr) *origPtr = method_setImplementation(m, imp);
    else method_setImplementation(m, imp);
}

// 获取除悬浮窗外最高层级窗口
static UIWindow * topWindowExcludingFloating(void) {
    UIWindow *top = nil;
    CGFloat maxLevel = -1;
    for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
        for (UIWindow *w in sc.windows) {
            if (w != floatingWindow && !w.hidden && w.alpha > 0.01 && w.windowLevel > maxLevel) {
                maxLevel = w.windowLevel;
                top = w;
            }
        }
    }
    return top;
}

static void simulateTapAtPoint(CGPoint screenPoint) {
    CGFloat jitterX = ((CGFloat)arc4random() / UINT32_MAX) * 4 - 2;
    CGFloat jitterY = ((CGFloat)arc4random() / UINT32_MAX) * 4 - 2;
    CGPoint point = CGPointMake(screenPoint.x + jitterX, screenPoint.y + jitterY);
    UIWindow *target = topWindowExcludingFloating();
    if (!target) return;
    CGPoint wp = [target convertPoint:point fromWindow:nil];
    UIView *hit = [target hitTest:wp withEvent:nil] ?: target;
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:hit forKey:@"view"]; [touch setValue:@(wp) forKey:@"locationInWindow"];
    [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"]; [touch setValue:@(1) forKey:@"tapCount"];
    [touch setValue:@(1.0) forKey:@"force"]; [touch setValue:@(5.0) forKey:@"majorRadius"];
    NSTimeInterval ts = [[NSProcessInfo processInfo] systemUptime];
    [touch setValue:@(ts) forKey:@"timestamp"];
    UIEvent *ev = [[UIEvent alloc] init]; [ev setValue:@[touch] forKey:@"touches"]; [ev setValue:@(UIEventTypeTouches) forKey:@"type"]; [ev setValue:@(ts) forKey:@"timestamp"];
    [hit touchesBegan:[NSSet setWithObject:touch] withEvent:ev];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.05*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"]; [touch setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"timestamp"];
        UIEvent *endEv = [[UIEvent alloc] init]; [endEv setValue:@[touch] forKey:@"touches"]; [endEv setValue:@(UIEventTypeTouches) forKey:@"type"]; [endEv setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"timestamp"];
        [hit touchesEnded:[NSSet setWithObject:touch] withEvent:endEv];
    });
}

static CGPoint screenPointForView(UIView *v) {
    CGRect r = [v convertRect:v.bounds toView:nil];
    return CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
}

static BOOL knownHooked = NO;
static void applyKnownSDKHooks() {
    if(knownHooked) return; knownHooked=YES;
    Class c;
    c=NSClassFromString(@"BUSplashAdView"); if(c) replaceInstanceMethod(c,@selector(showInWindow:),^(id s,UIWindow *w){ id d=[s valueForKey:@"delegate"]; if(d&&[d respondsToSelector:@selector(splashAdDidClose:)]) [d performSelector:@selector(splashAdDidClose:) withObject:s]; },NULL);
    c=NSClassFromString(@"GDTSplashAd"); if(c) replaceInstanceMethod(c,@selector(loadAndShowInWindow:),^(id s,UIWindow *w){ id d=[s valueForKey:@"delegate"]; if(d&&[d respondsToSelector:@selector(splashAdDidDismiss:)]) [d performSelector:@selector(splashAdDidDismiss:) withObject:s]; },NULL);
    c=NSClassFromString(@"BaiduMobAdSplash"); if(c) replaceInstanceMethod(c,@selector(showInWindow:),^(id s,UIWindow *w){ id d=[s valueForKey:@"delegate"]; if(d&&[d respondsToSelector:@selector(splashAdDidClose:)]) [d performSelector:@selector(splashAdDidClose:) withObject:s]; },NULL);
}

static NSString *rulesPath() { return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"com.adblocker.rules.plist"]; }
static NSMutableArray *loadRules() { NSArray *a = [NSArray arrayWithContentsOfFile:rulesPath()]; return a ? [a mutableCopy] : [NSMutableArray array]; }
static void saveRules(NSArray *r) { [r writeToFile:rulesPath() atomically:YES]; }
static void addRule(NSString *adClass, NSString *btnClass, NSString *titleKeyword, NSString *accLabel) {
    NSMutableArray *rules = loadRules();
    for(NSDictionary *r in rules) if([r[@"adViewClass"] isEqualToString:adClass]) return;
    [rules addObject:@{@"adViewClass":adClass, @"skipBtnClass":btnClass?:@"", @"skipBtnTitle":titleKeyword?:@"", @"skipBtnAccLabel":accLabel?:@""}];
    saveRules(rules);
    TESTLOG(@"✅ 规则已保存: ad=%@ btn=%@ title=%@", adClass, btnClass, titleKeyword);
}
static BOOL tryAutoSkipWithRules(UIView *adView) {
    NSArray *rules = loadRules();
    for(NSDictionary *r in rules) {
        if(![NSStringFromClass([adView class]) isEqualToString:r[@"adViewClass"]]) continue;
        UIButton *skip = nil;
        for(UIView *s in adView.subviews) if([s isKindOfClass:[UIButton class]]&&[NSStringFromClass([s class]) isEqualToString:r[@"skipBtnClass"]]) { skip=(UIButton*)s; break; }
        if(!skip) skip = findSkipButtonInView(adView);
        if(skip) simulateTapAtPoint(screenPointForView(skip)); else [adView removeFromSuperview];
        return YES;
    }
    return NO;
}

static UIButton *findSkipButtonInView(UIView *v) {
    if([v isKindOfClass:[UIButton class]]) { UIButton *b = (UIButton *)v; NSString *t = b.titleLabel.text?:b.accessibilityLabel; if(t&&([t containsString:@"跳过"]||[t containsString:@"Skip"]||[t containsString:@"关闭"])) return b; }
    for(UIView *sub in v.subviews) { UIButton *r = findSkipButtonInView(sub); if(r) return r; }
    return nil;
}

static UIView *findFullScreenContainer(UIView *v) {
    CGRect screen = [UIScreen mainScreen].bounds;
    UIView *cur = v.superview;
    while(cur) { if(cur.frame.size.width>=screen.size.width*0.8 && cur.frame.size.height>=screen.size.height*0.8) return cur; cur = cur.superview; }
    return nil;
}

static UIView *findViewWithClass(UIView *root, NSString *className) {
    if([NSStringFromClass([root class]) isEqualToString:className]) return root;
    for(UIView *sub in root.subviews) { UIView *f = findViewWithClass(sub, className); if(f) return f; }
    return nil;
}

// ========== 学习模式：降低悬浮窗层级让广告窗口可点击 ==========
static void startLearningMode() {
    if(learningMode) return; learningMode=YES; learnRecorded=NO;
    [floatingBtn setTitle:@"学习中" forState:UIControlStateNormal]; floatingBtn.backgroundColor=[UIColor blueColor];
    floatingWindow.windowLevel = MAX_OTHER_WINDOW_LEVEL - 1;
    [learnTimeout invalidate];
    learnTimeout = [NSTimer scheduledTimerWithTimeInterval:LEARN_TIMEOUT repeats:NO block:^(NSTimer *_){ stopLearningMode(); }];
    TESTLOG(@"📖 学习模式启动");
}

static void stopLearningMode() {
    if(!learningMode) return; learningMode=NO;
    [learnTimeout invalidate]; learnTimeout=nil;
    [floatingBtn setTitle:@"去广告" forState:UIControlStateNormal]; floatingBtn.backgroundColor=[UIColor redColor];
    ensureFloatingOnTop(); // 恢复最高层级
    TESTLOG(@"📖 学习模式已退出");
}

// ========== 核心：限制其他窗口层级 + 悬浮窗置顶 ==========
static void ensureFloatingOnTop(void) {
    if (!floatingWindow) return;
    if (!learningMode) {
        floatingWindow.windowLevel = MAX_OTHER_WINDOW_LEVEL + 1;
    }
    floatingWindow.hidden = NO;
    floatingWindow.alpha = 1.0;
    floatingWindow.userInteractionEnabled = YES;
    if (floatingWindow.isKeyWindow) {
        [floatingWindow resignKeyWindow];
    }
}

// ---------- 悬浮窗创建 ----------
static void createFloatingWindow() {
    if(floatingWindow) return;
    floatingWindow = [[_FloatingWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (sc.activationState == UISceneActivationStateForegroundActive) {
            floatingWindow.windowScene = sc; break;
        }
    }
    if (!floatingWindow.windowScene) {
        for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
            floatingWindow.windowScene = sc; break;
        }
    }
    floatingWindow.backgroundColor = [UIColor clearColor];
    floatingWindow.rootViewController = [UIViewController new];
    floatingWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    ensureFloatingOnTop();
    floatingWindow.hidden = NO;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom]; CGFloat s=60;
    btn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width-s-20, 150, s, s);
    btn.backgroundColor=[UIColor redColor]; btn.layer.cornerRadius=s/2; btn.layer.borderWidth=3; btn.layer.borderColor=[UIColor whiteColor].CGColor;
    btn.layer.shadowOffset=CGSizeMake(0,4); btn.layer.shadowOpacity=0.8;
    [btn setTitle:@"去广告" forState:UIControlStateNormal]; btn.titleLabel.font=[UIFont boldSystemFontOfSize:14];
    [btn addAction:[UIAction actionWithHandler:^(id _){ if(learningMode){ stopLearningMode(); return; } scanForAdsInTopWindow(); }] forControlEvents:UIControlEventTouchUpInside];

    gestureHandler = [[_AdBlockGestureHandler alloc] init];
    gestureHandler.panBlock = ^(UIPanGestureRecognizer *g){
        static CGPoint start; if(g.state==UIGestureRecognizerStateBegan) start=[g locationInView:btn];
        else { CGPoint p=[g locationInView:floatingWindow]; btn.frame=CGRectMake(p.x-start.x, p.y-start.y, s, s); }
    };
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gestureHandler action:@selector(handlePan:)];
    [btn addGestureRecognizer:pan];
    gestureHandler.longPressBlock = ^(UILongPressGestureRecognizer *g){ if(g.state==UIGestureRecognizerStateBegan && !learningMode) startLearningMode(); };
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:gestureHandler action:@selector(handleLongPress:)];
    lp.minimumPressDuration = LONG_PRESS_DURATION; lp.allowableMovement=10;
    [btn addGestureRecognizer:lp];

    [floatingWindow.rootViewController.view addSubview:btn];
    floatingWindow.actionButton = btn;
    floatingBtn = btn;
    TESTLOG(@"🔴 悬浮窗创建完成 (level: %.0f)", floatingWindow.windowLevel);
}

static void scanForAdsInTopWindow() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, HEURISTIC_CHECK_DELAY*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIWindow *top = topWindowExcludingFloating();
        if (!top) return;
        UIView *rootView = top.rootViewController.view ?: top;
        for (NSDictionary *rule in loadRules()) {
            UIView *adView = findViewWithClass(rootView, rule[@"adViewClass"]);
            if (adView) {
                if (tryAutoSkipWithRules(adView)) {
                    TESTLOG(@"✅ 自动跳过成功");
                }
            }
        }
    });
}

// ========== Hook sendEvent: 学习模式捕获 ==========
static void (*orig_sendEvent)(id, SEL, UIEvent *);
static void swizzled_sendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    if(learningMode && !learnRecorded && event.type==UIEventTypeTouches) {
        for(UITouch *t in [event allTouches]) {
            if(t.phase==UITouchPhaseEnded && t.tapCount==1 && [t.view isKindOfClass:[UIButton class]]) {
                UIButton *btn = (UIButton *)t.view;
                NSString *title = btn.titleLabel.text?:btn.accessibilityLabel?:@"";
                if([title containsString:@"跳过"]||[title containsString:@"Skip"]||[title containsString:@"关闭"]) {
                    learnRecorded=YES;
                    UIView *container = findFullScreenContainer(btn);
                    NSString *adClass = container ? NSStringFromClass([container class]) : @"UnknownAdView";
                    addRule(adClass, NSStringFromClass([btn class]), title, btn.accessibilityLabel);
                    stopLearningMode();
                    showRuleSavedToast(); // 显示提示
                    orig_sendEvent(self, _cmd, event);
                    return;
                }
            }
        }
    }
    orig_sendEvent(self, _cmd, event);
}

// ========== 主动限制其他窗口层级 ==========
static void (*orig_setWindowLevel)(id, SEL, CGFloat);
static void swizzled_setWindowLevel(UIWindow *self, SEL _cmd, CGFloat level) {
    if (self != floatingWindow && level > MAX_OTHER_WINDOW_LEVEL) {
        level = MAX_OTHER_WINDOW_LEVEL;
    }
    orig_setWindowLevel(self, _cmd, level);
    if (self != floatingWindow && !learningMode) {
        ensureFloatingOnTop();
    }
}

static void (*orig_setHidden)(id, SEL, BOOL);
static void swizzled_setHidden(UIWindow *self, SEL _cmd, BOOL hidden) {
    if(self==floatingWindow && hidden) return;
    orig_setHidden(self, _cmd, hidden);
}

static void (*orig_removeFromSuperview)(id, SEL);
static void swizzled_removeFromSuperview(UIWindow *self, SEL _cmd) {
    if(self==floatingWindow) return;
    orig_removeFromSuperview(self, _cmd);
}

static void (*orig_makeKeyAndVisible)(id, SEL);
static void swizzled_makeKeyAndVisible(UIWindow *self, SEL _cmd) {
    orig_makeKeyAndVisible(self, _cmd);
    if(self != floatingWindow && !learningMode) ensureFloatingOnTop();
}

static void (*orig_makeKeyWindow)(id, SEL);
static void swizzled_makeKeyWindow(UIWindow *self, SEL _cmd) {
    orig_makeKeyWindow(self, _cmd);
    if(self != floatingWindow && !learningMode) ensureFloatingOnTop();
}

// ========== Toast 提示 ==========
static void showLoadedToast() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive) {
                w.windowScene = sc; break;
            }
        }
        w.windowLevel=UIWindowLevelAlert+999; w.backgroundColor=[UIColor clearColor]; w.userInteractionEnabled=NO; w.hidden=NO;
        UILabel *l=[UILabel new]; l.text=@"✅ AdBlock 已加载"; l.textColor=[UIColor whiteColor]; l.backgroundColor=[[UIColor blackColor] colorWithAlphaComponent:0.7]; l.textAlignment=NSTextAlignmentCenter; l.font=[UIFont systemFontOfSize:16]; l.layer.cornerRadius=10; l.layer.masksToBounds=YES;
        [l sizeToFit]; CGRect f=l.frame; f.size.width+=30; f.size.height+=16; l.frame=f; l.center=CGPointMake(w.bounds.size.width/2, w.bounds.size.height-100);
        [w addSubview:l]; l.alpha=0; [UIView animateWithDuration:0.3 animations:^{ l.alpha=1; } completion:^(BOOL done){ [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{ l.alpha=0; } completion:^(BOOL done){ w.hidden=YES; }]; }];
    });
}

static void showRuleSavedToast() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive) {
                w.windowScene = sc; break;
            }
        }
        w.windowLevel=UIWindowLevelAlert+999; w.backgroundColor=[UIColor clearColor]; w.userInteractionEnabled=NO; w.hidden=NO;
        UILabel *l=[UILabel new]; l.text=@"✅ 规则已保存"; l.textColor=[UIColor whiteColor]; l.backgroundColor=[[UIColor blackColor] colorWithAlphaComponent:0.7]; l.textAlignment=NSTextAlignmentCenter; l.font=[UIFont systemFontOfSize:16]; l.layer.cornerRadius=10; l.layer.masksToBounds=YES;
        [l sizeToFit]; CGRect f=l.frame; f.size.width+=30; f.size.height+=16; l.frame=f; l.center=CGPointMake(w.bounds.size.width/2, w.bounds.size.height-100);
        [w addSubview:l]; l.alpha=0; [UIView animateWithDuration:0.3 animations:^{ l.alpha=1; } completion:^(BOOL done){ [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{ l.alpha=0; } completion:^(BOOL done){ w.hidden=YES; }]; }];
    });
}

__attribute__((constructor))
static void adblock_init() {
    applyKnownSDKHooks();
    Method m;
    m = class_getInstanceMethod([UIWindow class], @selector(setWindowLevel:)); orig_setWindowLevel=(void(*)(id,SEL,CGFloat))method_getImplementation(m); method_setImplementation(m,(IMP)swizzled_setWindowLevel);
    m = class_getInstanceMethod([UIWindow class], @selector(setHidden:)); orig_setHidden=(void(*)(id,SEL,BOOL))method_getImplementation(m); method_setImplementation(m,(IMP)swizzled_setHidden);
    m = class_getInstanceMethod([UIWindow class], @selector(removeFromSuperview)); orig_removeFromSuperview=(void(*)(id,SEL))method_getImplementation(m); method_setImplementation(m,(IMP)swizzled_removeFromSuperview);
    m = class_getInstanceMethod([UIWindow class], @selector(makeKeyAndVisible)); orig_makeKeyAndVisible=(void(*)(id,SEL))method_getImplementation(m); method_setImplementation(m,(IMP)swizzled_makeKeyAndVisible);
    m = class_getInstanceMethod([UIApplication class], @selector(sendEvent:)); orig_sendEvent=(void(*)(id,SEL,UIEvent*))method_getImplementation(m); method_setImplementation(m,(IMP)swizzled_sendEvent);
    SEL makeKeySel = NSSelectorFromString(@"_makeKeyWindow");
    if ([UIWindow instancesRespondToSelector:makeKeySel]) {
        m = class_getInstanceMethod([UIWindow class], makeKeySel);
        orig_makeKeyWindow = (void(*)(id,SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)swizzled_makeKeyWindow);
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *_){ dispatch_after(dispatch_time(DISPATCH_TIME_NOW,0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ createFloatingWindow(); scanForAdsInTopWindow(); }); }];
    showLoadedToast();
}
