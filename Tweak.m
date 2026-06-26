// ==========================================
// Tweak.m - 通用去开屏广告插件（学习模式最终版）
// 适用于 iOS 16.6 + TrollStore
// ==========================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define SKIP_BTN_CHECK_DELAY  1.0
#define HEURISTIC_CHECK_DELAY 1.5
#define LONG_PRESS_DURATION   1.0
#define LEARN_TIMEOUT         10.0

#define TESTLOG(fmt, ...) NSLog(@"[AD-BLOCKER] " fmt, ##__VA_ARGS__)

// ---------- 前向声明 ----------
@class _FloatingWindow;
static void startLearningMode(void);
static void stopLearningMode(void);
static void updateFloatingLevel(void);
static void scanForAdsInTopWindow(void);
static UIButton *findSkipButtonInView(UIView *v);
static UIView *findFullScreenContainer(UIView *v);
static void addRule(NSString *adClass, NSString *btnClass, NSString *titleKeyword, NSString *accLabel);
static BOOL tryAutoSkipWithRules(UIView *adView);
static BOOL isLikelyAdView(UIView *v);
static void showLoadedToast(void);
static void createFloatingWindow(void);

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
@end

// ---------- 全局变量 ----------
static _FloatingWindow *floatingWindow = nil;
static UIButton *floatingBtn = nil;
static _AdBlockGestureHandler *gestureHandler = nil;
static BOOL learningMode = NO;
static NSTimer *learnTimeout = nil;
static BOOL learnRecorded = NO;

// ---------- 方法替换 ----------
static void replaceInstanceMethod(Class cls, SEL sel, id impBlock, IMP *origPtr) {
    Method m = class_getInstanceMethod(cls, sel);
    if(!m) return;
    IMP imp = imp_implementationWithBlock(impBlock);
    if(origPtr) *origPtr = method_setImplementation(m, imp);
    else method_setImplementation(m, imp);
}

// ---------- 触摸模拟 ----------
static void simulateTapAtPoint(CGPoint screenPoint) {
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
    CGPoint wp = [target convertPoint:screenPoint fromWindow:nil];
    UIView *hit = [target hitTest:wp withEvent:nil] ?: target;
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:hit forKey:@"view"];
    [touch setValue:@(wp) forKey:@"locationInWindow"];
    [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    UIEvent *ev = [[UIEvent alloc] init];
    [ev setValue:@[touch] forKey:@"touches"];
    [ev setValue:@(UIEventTypeTouches) forKey:@"type"];
    [hit touchesBegan:[NSSet setWithObject:touch] withEvent:ev];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.05*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        [hit touchesEnded:[NSSet setWithObject:touch] withEvent:ev];
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

// ---------- 学习模式 ----------
static void startLearningMode() {
    if(learningMode) return;
    learningMode = YES;
    learnRecorded = NO;
    [floatingBtn setTitle:@"学习中" forState:UIControlStateNormal];
    floatingBtn.backgroundColor = [UIColor blueColor];
    floatingWindow.windowLevel = UIWindowLevelNormal + 1;
    TESTLOG(@"📖 学习模式启动，请点击广告的跳过按钮");
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
    updateFloatingLevel();
    TESTLOG(@"📖 学习模式已退出");
}

// ---------- 悬浮窗层级更新 ----------
static void updateFloatingLevel(void) {
    if(!floatingWindow) return;
    CGFloat maxL = -1;
    for(UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
        for(UIWindow *w in sc.windows) if(w!=floatingWindow && w.windowLevel>maxL) maxL=w.windowLevel;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for(UIWindow *w in [UIApplication sharedApplication].windows) if(w!=floatingWindow && w.windowLevel>maxL) maxL=w.windowLevel;
#pragma clang diagnostic pop
    if(!learningMode) {
        floatingWindow.windowLevel = maxL + 1;
        [floatingWindow makeKeyAndVisible];
    }
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
    updateFloatingLevel();
    floatingWindow.backgroundColor = [UIColor clearColor];
    floatingWindow.userInteractionEnabled = YES;
    floatingWindow.rootViewController = [UIViewController new];
    floatingWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    floatingWindow.hidden = NO;
    [floatingWindow makeKeyAndVisible];

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
    TESTLOG(@"🔴 悬浮窗创建完成");
}

// ---------- 扫描广告 ----------
static BOOL isLikelyAdView(UIView *v) {
    CGRect b = [UIScreen mainScreen].bounds;
    if(v.frame.size.width < b.size.width*0.8 || v.frame.size.height < b.size.height*0.8) return NO;
    if(findSkipButtonInView(v)) return YES;
    NSString *c = NSStringFromClass([v class]);
    for(NSString *k in @[@"Splash",@"Ad",@"Launch",@"Popup"])
        if([c rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static void scanForAdsInTopWindow() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, HEURISTIC_CHECK_DELAY*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIWindow *top = nil; CGFloat maxL = -1;
        if(@available(iOS 13.0,*)) for(UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) if(sc.activationState == UISceneActivationStateForegroundActive) for(UIWindow *w in sc.windows) if(!w.hidden && w.alpha>0.01 && w.windowLevel>maxL){ maxL=w.windowLevel; top=w; }
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if(!top) for(UIWindow *w in [UIApplication sharedApplication].windows) if(!w.hidden && w.alpha>0.01 && w.windowLevel>maxL){ maxL=w.windowLevel; top=w; }
        #pragma clang diagnostic pop
        if(!top) return;
        UIView *root = top.rootViewController.view ?: top;
        for(UIView *sub in root.subviews) {
            if(isLikelyAdView(sub)) { if(tryAutoSkipWithRules(sub)) return; }
        }
    });
}

// ---------- Hook sendEvent: 学习模式触摸记录 ----------
static void (*orig_sendEvent)(id, SEL, UIEvent *);
static void swizzled_sendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    if(learningMode && !learnRecorded && event.type == UIEventTypeTouches) {
        NSSet *touches = [event allTouches];
        for(UITouch *touch in touches) {
            if(touch.phase == UITouchPhaseEnded) {
                UIView *view = touch.view;
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

// ---------- UIWindow 监控 ----------
static void (*orig_makeKeyAndVisible)(id, SEL);
static void swizzled_makeKeyAndVisible(UIWindow *self, SEL _cmd) {
    orig_makeKeyAndVisible(self, _cmd);
    if(self == floatingWindow) return;
    if(!learningMode) updateFloatingLevel();
    if(self.frame.size.width >= [UIScreen mainScreen].bounds.size.width*0.8 &&
       self.frame.size.height >= [UIScreen mainScreen].bounds.size.height*0.8 &&
       self.windowLevel > UIWindowLevelNormal) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, SKIP_BTN_CHECK_DELAY*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            for(UIView *sub in self.subviews) {
                if(isLikelyAdView(sub)) { if(tryAutoSkipWithRules(sub)) return; }
            }
        });
    }
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

    Method m = class_getInstanceMethod([UIWindow class], @selector(makeKeyAndVisible));
    if(m){ orig_makeKeyAndVisible = (void(*)(id,SEL))method_getImplementation(m); method_setImplementation(m, (IMP)swizzled_makeKeyAndVisible); }

    Method sm = class_getInstanceMethod([UIApplication class], @selector(sendEvent:));
    orig_sendEvent = (void(*)(id,SEL,UIEvent*))method_getImplementation(sm);
    method_setImplementation(sm, (IMP)swizzled_sendEvent);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *_){ 
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ createFloatingWindow(); scanForAdsInTopWindow(); });
    }];

    showLoadedToast();
}
