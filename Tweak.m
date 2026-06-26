// ==========================================
// Tweak.m - 通用去开屏广告插件（最终无干扰版）
// 适用于 iOS 16.6 + TrollStore
// ==========================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define LONG_PRESS_DURATION   1.0
#define HEURISTIC_CHECK_DELAY 1.5
#define MAX_OTHER_WINDOW_LEVEL 100000

#define TESTLOG(fmt, ...) NSLog(@"[AD-BLOCKER] " fmt, ##__VA_ARGS__)

@class _FloatingWindow;
static void ensureFloatingOnTop(void);
static void scanForAdsInTopWindow(void);
static UIButton *findSkipButtonInView(UIView *v);
static UIView *findViewWithClass(UIView *root, NSString *className);
static void addRule(NSString *adClass, NSString *btnClass, NSString *titleKeyword, NSString *accLabel);
static BOOL tryAutoSkipWithRules(UIView *adView);
static void showLoadedToast(void);
static void showToast(NSString *text);
static void createFloatingWindow(void);
static void showConfirmPanel(void);

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
    return nil;
}
- (BOOL)_canBecomeKeyWindow { return NO; }
@end

static _FloatingWindow *floatingWindow = nil;
static UIButton *floatingBtn = nil;
static _AdBlockGestureHandler *gestureHandler = nil;
static BOOL pendingMark = NO;

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

// 递归查找全屏广告容器
static UIView *findFullScreenAdView(UIView *root) {
    CGRect screen = [UIScreen mainScreen].bounds;
    if (root.frame.size.width >= screen.size.width * 0.8 &&
        root.frame.size.height >= screen.size.height * 0.8) {
        return root;
    }
    for (UIView *sub in root.subviews) {
        UIView *found = findFullScreenAdView(sub);
        if (found) return found;
    }
    return nil;
}

// 本版本不再需要模拟点击（标记时仅保存规则）
static void simulateTapAtPoint(CGPoint screenPoint) { /* 保留空实现，供自动跳过使用 */ }

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
        if(skip) {
            // 模拟点击跳过按钮
            CGFloat jitterX = ((CGFloat)arc4random() / UINT32_MAX) * 4 - 2;
            CGFloat jitterY = ((CGFloat)arc4random() / UINT32_MAX) * 4 - 2;
            CGPoint point = CGPointMake(screenPointForView(skip).x + jitterX, screenPointForView(skip).y + jitterY);
            UIWindow *target = topWindowExcludingFloating();
            if (target) {
                CGPoint wp = [target convertPoint:point fromWindow:nil];
                UIView *hit = [target hitTest:wp withEvent:nil] ?: skip;
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
        } else {
            [adView removeFromSuperview];
        }
        return YES;
    }
    return NO;
}

static UIButton *findSkipButtonInView(UIView *v) {
    if([v isKindOfClass:[UIButton class]]) { UIButton *b = (UIButton *)v; NSString *t = b.titleLabel.text?:b.accessibilityLabel; if(t&&([t containsString:@"跳过"]||[t containsString:@"Skip"]||[t containsString:@"关闭"])) return b; }
    for(UIView *sub in v.subviews) { UIButton *r = findSkipButtonInView(sub); if(r) return r; }
    return nil;
}

static UIView *findViewWithClass(UIView *root, NSString *className) {
    if([NSStringFromClass([root class]) isEqualToString:className]) return root;
    for(UIView *sub in root.subviews) { UIView *f = findViewWithClass(sub, className); if(f) return f; }
    return nil;
}

// ========== 自定义确认面板（不干扰广告窗口） ==========
static void showConfirmPanel(void) {
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(40, 200, floatingWindow.bounds.size.width - 80, 150)];
    panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    panel.layer.cornerRadius = 12;
    panel.alpha = 0;
    [floatingWindow.rootViewController.view addSubview:panel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 20, panel.bounds.size.width, 30)];
    title.text = @"确认标记此类广告？";
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:18];
    [panel addSubview:title];

    // 显示识别的类名
    UIWindow *top = topWindowExcludingFloating();
    UIView *adView = top ? findFullScreenAdView(top.rootViewController.view ?: top) : nil;
    NSString *className = adView ? NSStringFromClass([adView class]) : @"未知";
    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(0, 55, panel.bounds.size.width, 20)];
    subtitle.text = [NSString stringWithFormat:@"广告容器: %@", className];
    subtitle.textColor = [UIColor lightGrayColor];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.font = [UIFont systemFontOfSize:14];
    [panel addSubview:subtitle];

    UIButton *confirmBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    confirmBtn.frame = CGRectMake(panel.bounds.size.width/2 - 80, 95, 70, 36);
    [confirmBtn setTitle:@"确认" forState:UIControlStateNormal];
    [confirmBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    confirmBtn.backgroundColor = [UIColor systemBlueColor];
    confirmBtn.layer.cornerRadius = 8;
    [panel addSubview:confirmBtn];

    UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelBtn.frame = CGRectMake(panel.bounds.size.width/2 + 10, 95, 70, 36);
    [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
    [cancelBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    cancelBtn.backgroundColor = [UIColor grayColor];
    cancelBtn.layer.cornerRadius = 8;
    [panel addSubview:cancelBtn];

    __weak UIView *weakPanel = panel;
    confirmBtn addAction:[UIAction actionWithHandler:^(id _){
        [weakPanel removeFromSuperview];
        UIButton *skip = findSkipButtonInView(adView);
        addRule(NSStringFromClass([adView class]),
                skip ? NSStringFromClass([skip class]) : @"",
                skip ? skip.titleLabel.text ?: @"" : @"",
                skip ? skip.accessibilityLabel ?: @"" : @"");
        showToast(@"✅ 规则已保存，下次自动跳过");
        cancelPendingMark();
    }] forControlEvents:UIControlEventTouchUpInside];

    cancelBtn addAction:[UIAction actionWithHandler:^(id _){
        [weakPanel removeFromSuperview];
        cancelPendingMark();
    }] forControlEvents:UIControlEventTouchUpInside];

    [UIView animateWithDuration:0.25 animations:^{ panel.alpha = 1; }];
}

// ========== 标记状态管理 ==========
static void enterPendingMark(void) {
    pendingMark = YES;
    [floatingBtn setTitle:@"待标记" forState:UIControlStateNormal];
    floatingBtn.backgroundColor = [UIColor blueColor];
}

static void cancelPendingMark(void) {
    pendingMark = NO;
    [floatingBtn setTitle:@"去广告" forState:UIControlStateNormal];
    floatingBtn.backgroundColor = [UIColor redColor];
}

// ========== 悬浮窗管理 ==========
static void ensureFloatingOnTop(void) {
    if (!floatingWindow) return;
    floatingWindow.windowLevel = MAX_OTHER_WINDOW_LEVEL + 1;
    floatingWindow.hidden = NO;
    floatingWindow.alpha = 1.0;
}

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
    [btn addAction:[UIAction actionWithHandler:^(id _){
        if (pendingMark) {
            showConfirmPanel();
        } else {
            scanForAdsInTopWindow();
        }
    }] forControlEvents:UIControlEventTouchUpInside];

    gestureHandler = [[_AdBlockGestureHandler alloc] init];
    gestureHandler.panBlock = ^(UIPanGestureRecognizer *g){
        static CGPoint start; if(g.state==UIGestureRecognizerStateBegan) start=[g locationInView:btn];
        else { CGPoint p=[g locationInView:floatingWindow]; btn.frame=CGRectMake(p.x-start.x, p.y-start.y, s, s); }
    };
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gestureHandler action:@selector(handlePan:)];
    [btn addGestureRecognizer:pan];
    gestureHandler.longPressBlock = ^(UILongPressGestureRecognizer *g){
        if(g.state == UIGestureRecognizerStateBegan && !pendingMark) {
            enterPendingMark();
        }
    };
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:gestureHandler action:@selector(handleLongPress:)];
    lp.minimumPressDuration = LONG_PRESS_DURATION;
    lp.allowableMovement = 10;
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

// ========== Hook: 限制其他窗口层级 ==========
static void (*orig_setWindowLevel)(id, SEL, CGFloat);
static void swizzled_setWindowLevel(UIWindow *self, SEL _cmd, CGFloat level) {
    if (self != floatingWindow && level > MAX_OTHER_WINDOW_LEVEL) {
        level = MAX_OTHER_WINDOW_LEVEL;
    }
    orig_setWindowLevel(self, _cmd, level);
    if (self != floatingWindow) ensureFloatingOnTop();
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
    if(self != floatingWindow) ensureFloatingOnTop();
}

// Toast
static void showLoadedToast() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        showToast(@"✅ AdBlock 已加载");
    });
}

static void showToast(NSString *text) {
    UILabel *l = [UILabel new];
    l.text = text;
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:16];
    l.layer.cornerRadius = 10;
    l.layer.masksToBounds = YES;
    [l sizeToFit];
    CGRect f = l.frame;
    f.size.width += 30;
    f.size.height += 16;
    l.frame = f;
    l.center = CGPointMake(floatingWindow.bounds.size.width / 2, floatingWindow.bounds.size.height - 100);
    [floatingWindow.rootViewController.view addSubview:l];
    l.alpha = 0;
    [UIView animateWithDuration:0.3 animations:^{ l.alpha = 1; } completion:^(BOOL done) {
        [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseOut animations:^{ l.alpha = 0; } completion:^(BOOL done) { [l removeFromSuperview]; }];
    }];
}

// ========== 初始化 ==========
__attribute__((constructor))
static void adblock_init() {
    applyKnownSDKHooks();

    Method m;
    m = class_getInstanceMethod([UIWindow class], @selector(setWindowLevel:)); orig_setWindowLevel=(void(*)(id,SEL,CGFloat))method_getImplementation(m); method_setImplementation(m,(IMP)swizzled_setWindowLevel);
    m = class_getInstanceMethod([UIWindow class], @selector(setHidden:)); orig_setHidden=(void(*)(id,SEL,BOOL))method_getImplementation(m); method_setImplementation(m,(IMP)swizzled_setHidden);
    m = class_getInstanceMethod([UIWindow class], @selector(removeFromSuperview)); orig_removeFromSuperview=(void(*)(id,SEL))method_getImplementation(m); method_setImplementation(m,(IMP)swizzled_removeFromSuperview);
    m = class_getInstanceMethod([UIWindow class], @selector(makeKeyAndVisible)); orig_makeKeyAndVisible=(void(*)(id,SEL))method_getImplementation(m); method_setImplementation(m,(IMP)swizzled_makeKeyAndVisible);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *_){ dispatch_after(dispatch_time(DISPATCH_TIME_NOW,0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ createFloatingWindow(); scanForAdsInTopWindow(); }); }];
    showLoadedToast();
}
