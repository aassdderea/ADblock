// ==========================================
// Tweak.m - 去开屏广告插件（编译修复版）
// iOS 16.x + TrollStore
// ==========================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>

#pragma mark - 配置

#define LONG_PRESS_DURATION     1.0
#define HEURISTIC_CHECK_DELAY   1.2
#define LEARN_TIMEOUT           15.0
#define SIMULATE_TOUCH_DELAY    0.04
#define MAX_OTHER_WINDOW_LEVEL  100000.0

#define ABLog(fmt, ...)  NSLog(@"[ADBLOCK] " fmt, ##__VA_ARGS__)

#pragma mark - 规则模型

@interface ABRule : NSObject <NSSecureCoding>
@property (nonatomic, copy) NSString *adClassName;
@property (nonatomic, copy) NSString *adClassSuffix;
@property (nonatomic, copy) NSString *btnClassName;
@property (nonatomic, copy) NSString *btnTitle;
@property (nonatomic, copy) NSString *btnAccLabel;
@end
@implementation ABRule
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)c {
    [c encodeObject:_adClassName forKey:@"ac"]; [c encodeObject:_adClassSuffix forKey:@"as"];
    [c encodeObject:_btnClassName forKey:@"bc"]; [c encodeObject:_btnTitle forKey:@"bt"];
    [c encodeObject:_btnAccLabel forKey:@"ba"];
}
- (instancetype)initWithCoder:(NSCoder *)c {
    if (self = [super init]) {
        _adClassName=[c decodeObjectOfClass:[NSString class] forKey:@"ac"];
        _adClassSuffix=[c decodeObjectOfClass:[NSString class] forKey:@"as"];
        _btnClassName=[c decodeObjectOfClass:[NSString class] forKey:@"bc"];
        _btnTitle=[c decodeObjectOfClass:[NSString class] forKey:@"bt"];
        _btnAccLabel=[c decodeObjectOfClass:[NSString class] forKey:@"ba"];
    }
    return self;
}
@end

#pragma mark - 手势代理

@interface ABGestureDelegate : NSObject
@property (nonatomic, copy) void (^panHandler)(UIPanGestureRecognizer *);
@property (nonatomic, copy) void (^longPressHandler)(UILongPressGestureRecognizer *);
- (void)handlePan:(UIPanGestureRecognizer *)g;
- (void)handleLongPress:(UILongPressGestureRecognizer *)g;
@end
@implementation ABGestureDelegate
- (void)handlePan:(UIPanGestureRecognizer *)g { if (self.panHandler) self.panHandler(g); }
- (void)handleLongPress:(UILongPressGestureRecognizer *)g { if (self.longPressHandler) self.longPressHandler(g); }
@end

#pragma mark - 悬浮窗

@interface ABFloatingWindow : UIWindow
@property (nonatomic, weak) UIButton *mainButton;
@end
@implementation ABFloatingWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.mainButton && CGRectContainsPoint(self.mainButton.frame, point)) return self.mainButton;
    return nil;
}
- (BOOL)_canBecomeKeyWindow { return NO; }
@end

#pragma mark - 全局状态

static pthread_mutex_t _lock = PTHREAD_MUTEX_INITIALIZER;
static ABFloatingWindow *_floatingWin = nil;
static UIButton         *_floatingBtn  = nil;
static ABGestureDelegate *_gestureDel  = nil;
static BOOL              _isLearning   = NO;
static NSMutableArray<ABRule *> *_rules = nil;

// 原始 IMP
static void (*_orig_sendTouches)(id, SEL, NSSet *, UIEvent *) = NULL;
static void (*_orig_setLevel)(id, SEL, CGFloat) = NULL;
static void (*_orig_setHidden)(id, SEL, BOOL) = NULL;
static void (*_orig_makeKeyVisible)(id, SEL) = NULL;

#pragma mark - 前向声明（按调用顺序）

static void _ensureOnTop(void);
static void _stopLearning(BOOL success);
static void _handleLearnCapture(UITouch *touch);
static void _scanAndSkip(void);
static void _simulateTapOnView(UIView *v);
static void _injectTouch(CGPoint pt);
static BOOL _tryDirectAction(UIButton *btn);

#pragma mark - 工具函数

static UIWindow *_topWindow(void) {
    UIWindow *top = nil;
    CGFloat maxLv = -1;
    for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (sc.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in sc.windows) {
            if (w == _floatingWin || w.hidden || w.alpha < 0.01) continue;
            if (w.windowLevel > maxLv) { maxLv = w.windowLevel; top = w; }
        }
    }
    return top;
}

static UIButton *_findSkipBtn(UIView *v) {
    if ([v isKindOfClass:[UIButton class]]) {
        NSString *t = [(UIButton *)v titleLabel].text ?: @"";
        NSString *a = v.accessibilityLabel ?: @"";
        NSArray *kw = @[@"跳过", @"skip", @"Skip", @"关闭", @"close"];
        for (NSString *k in kw) if ([t containsString:k] || [a containsString:k]) return (UIButton *)v;
    }
    for (UIView *sub in v.subviews) { UIButton *r = _findSkipBtn(sub); if (r) return r; }
    return nil;
}

static UIView *_adContainer(UIView *from) {
    CGRect scr = [UIScreen mainScreen].bounds;
    UIView *cur = from;
    while (cur) {
        if (cur.frame.size.width >= scr.size.width*0.8 && cur.frame.size.height >= scr.size.height*0.8) return cur;
        cur = cur.superview;
    }
    return nil;
}

static NSString *_classSuffix(NSString *name) {
    if (name.length <= 15) return name;
    return [name substringFromIndex:name.length - 15];
}

#pragma mark - 规则存储

static NSString *_rulesPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"adblock_rules.plist"];
}

static void _loadRules(void) {
    @try {
        NSData *d = [NSData dataWithContentsOfFile:_rulesPath()];
        NSSet *cls = [NSSet setWithArray:@[[NSMutableArray class],[ABRule class],[NSString class]]];
        _rules = d ? [NSKeyedUnarchiver unarchivedObjectOfClasses:cls fromData:d error:nil] : nil;
    } @catch (NSException *e) { _rules = nil; }
    if (!_rules) _rules = [NSMutableArray array];
}

static void _saveRules(void) {
    @try { [[NSKeyedArchiver archivedDataWithRootObject:_rules requiringSecureCoding:YES error:nil]
            writeToFile:_rulesPath() atomically:YES]; }
    @catch (NSException *e) { ABLog(@"保存规则失败: %@", e); }
}

#pragma mark - 模拟点击

static BOOL _tryDirectAction(UIButton *btn) {
    @try {
        NSSet *targets = [btn allTargets];
        if (!targets.count) return NO;
        for (id t in targets) {
            NSArray *actions = [btn actionsForTarget:t forControlEvents:UIControlEventTouchUpInside];
            for (NSString *a in actions ?: @[]) {
                SEL sel = NSSelectorFromString(a);
                if ([t respondsToSelector:sel]) {
                    ((void(*)(id, SEL))objc_msgSend)(t, sel);
                    return YES;
                }
            }
        }
        [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    } @catch (NSException *e) { return NO; }
}

static void _injectTouch(CGPoint pt) {
    UIWindow *w = _topWindow(); if (!w) return;
    CGPoint wp = [w convertPoint:pt fromWindow:nil];
    UIView *hit = [w hitTest:wp withEvent:nil] ?: w;

    UITouch *t = [[UITouch alloc] init];
    [t setValue:hit forKey:@"view"];
    [t setValue:@(wp) forKey:@"locationInWindow"];
    [t setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    [t setValue:@(1) forKey:@"tapCount"];
    [t setValue:@(1.0) forKey:@"force"];
    [t setValue:@(5.0) forKey:@"majorRadius"];
    NSTimeInterval ts = [[NSProcessInfo processInfo] systemUptime];
    [t setValue:@(ts) forKey:@"_timestamp"];

    UIEvent *ev = [[UIEvent alloc] init];
    [ev setValue:[NSSet setWithObject:t] forKey:@"touches"];
    [ev setValue:@(1) forKey:@"type"];

    [hit touchesBegan:[NSSet setWithObject:t] withEvent:ev];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, SIMULATE_TOUCH_DELAY*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [t setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        [t setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"_timestamp"];
        [hit touchesEnded:[NSSet setWithObject:t] withEvent:ev];
    });
}

static void _simulateTapOnView(UIView *v) {
    if ([v isKindOfClass:[UIButton class]] && _tryDirectAction((UIButton *)v)) {
        ABLog(@"策略1成功");
        return;
    }
    CGRect f = [v convertRect:v.bounds toView:nil];
    CGPoint c = CGPointMake(CGRectGetMidX(f)+((CGFloat)arc4random_uniform(400)/100.0-2),
                            CGRectGetMidY(f)+((CGFloat)arc4random_uniform(400)/100.0-2));
    _injectTouch(c);
}

#pragma mark - 悬浮窗管理

static void _ensureOnTop(void) {
    if (!_floatingWin) return;
    CGFloat maxLv = 0;
    for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes)
        for (UIWindow *w in sc.windows)
            if (w != _floatingWin && !w.hidden) maxLv = MAX(maxLv, w.windowLevel);
    if (!_isLearning) _floatingWin.windowLevel = MAX(maxLv + 1, MAX_OTHER_WINDOW_LEVEL + 1);
    _floatingWin.hidden = NO;
}

static void _createFloating(void) {
    if (_floatingWin) return;
    _floatingWin = [[ABFloatingWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes)
        if (sc.activationState == UISceneActivationStateForegroundActive) { _floatingWin.windowScene = sc; break; }
    if (!_floatingWin.windowScene)
        for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) { _floatingWin.windowScene = sc; break; }
    _floatingWin.backgroundColor = [UIColor clearColor];
    _floatingWin.rootViewController = [UIViewController new];
    _floatingWin.rootViewController.view.backgroundColor = [UIColor clearColor];
    _ensureOnTop();
    _floatingWin.hidden = NO;

    CGFloat s = 56, m = 16;
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width-s-m, 120, s, s);
    btn.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
    btn.layer.cornerRadius = s/2;
    btn.layer.borderWidth = 2.5; btn.layer.borderColor = [UIColor whiteColor].CGColor;
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [btn setTitle:@"去广告" forState:UIControlStateNormal];

    _gestureDel = [ABGestureDelegate new];

    // 单击扫描
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:_gestureDel action:@selector(handlePan:)];
    _gestureDel.panHandler = ^(UIPanGestureRecognizer *g) { if (!_isLearning) _scanAndSkip(); };
    [btn addGestureRecognizer:tap];

    // 长按学习
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:_gestureDel action:@selector(handleLongPress:)];
    lp.minimumPressDuration = LONG_PRESS_DURATION; lp.allowableMovement = 15;
    _gestureDel.longPressHandler = ^(UILongPressGestureRecognizer *g) {
        if (g.state == UIGestureRecognizerStateBegan && !_isLearning) {
            [self _startLearning]; // 调用自身的学习启动
        }
    };
    [btn addGestureRecognizer:lp];

    // 拖动
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:_gestureDel action:@selector(handlePan:)];
    _gestureDel.panHandler = ^(UIPanGestureRecognizer *g) {
        static CGPoint start;
        if (g.state == UIGestureRecognizerStateBegan) start = [g locationInView:btn];
        else { CGPoint p = [g locationInView:_floatingWin]; btn.center = CGPointMake(p.x-start.x+s/2, p.y-start.y+s/2); }
    };
    [btn addGestureRecognizer:pan];

    [_floatingWin.rootViewController.view addSubview:btn];
    _floatingWin.mainButton = btn; _floatingBtn = btn;
    ABLog(@"悬浮窗创建完成");
}

#pragma mark - 学习模式

static void _startLearning(void) {
    pthread_mutex_lock(&_lock);
    if (_isLearning) { pthread_mutex_unlock(&_lock); return; }
    _isLearning = YES;
    pthread_mutex_unlock(&_lock);

    dispatch_async(dispatch_get_main_queue(), ^{
        [_floatingBtn setTitle:@"学习中" forState:UIControlStateNormal];
        _floatingBtn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.9];
        _floatingWin.windowLevel = MAX_OTHER_WINDOW_LEVEL - 1;
        ABLog(@"学习模式启动");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, LEARN_TIMEOUT*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (_isLearning) _stopLearning(NO);
        });
    });
}

static void _stopLearning(BOOL success) {
    pthread_mutex_lock(&_lock);
    if (!_isLearning) { pthread_mutex_unlock(&_lock); return; }
    _isLearning = NO;
    pthread_mutex_unlock(&_lock);

    dispatch_async(dispatch_get_main_queue(), ^{
        [_floatingBtn setTitle:@"去广告" forState:UIControlStateNormal];
        _floatingBtn.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
        _ensureOnTop();
        ABLog(@"学习模式退出 success=%d", success);
    });
}

static void _handleLearnCapture(UITouch *touch) {
    if (!_isLearning || touch.phase != UITouchPhaseEnded || touch.tapCount != 1) return;
    if (touch.window == _floatingWin) return;

    CGPoint pt = [touch locationInView:nil];
    ABLog(@"捕获点击: %@", NSStringFromCGPoint(pt));

    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.15*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            UIWindow *top = _topWindow();
            if (!top) { _stopLearning(NO); return; }

            CGPoint wp = [top convertPoint:pt fromWindow:nil];
            UIView *hit = [top hitTest:wp withEvent:nil];
            UIButton *btn = nil;
            UIView *cur = hit;
            while (cur) { if ([cur isKindOfClass:[UIButton class]]) { btn = (UIButton *)cur; break; } cur = cur.superview; }
            if (!btn) { _stopLearning(NO); return; }

            NSString *title = btn.titleLabel.text ?: btn.accessibilityLabel ?: @"";
            BOOL isSkip = NO;
            for (NSString *k in @[@"跳过",@"skip",@"Skip",@"关闭",@"close"])
                if ([title containsString:k]) { isSkip = YES; break; }
            if (!isSkip) { _stopLearning(NO); return; }

            UIView *container = _adContainer(btn);
            NSString *adCls = container ? NSStringFromClass([container class]) : @"Unknown";

            ABRule *rule = [ABRule new];
            rule.adClassName = adCls;
            rule.adClassSuffix = _classSuffix(adCls);
            rule.btnClassName = NSStringFromClass([btn class]);
            rule.btnTitle = title;
            rule.btnAccLabel = btn.accessibilityLabel ?: @"";
            [_rules addObject:rule];
            _saveRules();
            _stopLearning(YES);
            ABLog(@"规则已保存: ad=%@ btn=%@", adCls, title);
        });
    });
}

#pragma mark - 自动扫描

static void _scanAndSkip(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, HEURISTIC_CHECK_DELAY*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIWindow *top = _topWindow();
        if (!top) return;
        UIView *root = top.rootViewController.view ?: top;

        // 规则匹配
        for (ABRule *rule in _rules) {
            __block UIView *adView = nil;
            void (^search)(UIView *) = ^(UIView *v) {
                if (adView) return;
                NSString *cls = NSStringFromClass([v class]);
                if ([cls isEqualToString:rule.adClassName] ||
                    [cls hasSuffix:rule.adClassSuffix] ||
                    [cls containsString:rule.adClassName]) { adView = v; return; }
                for (UIView *sub in v.subviews) search(sub);
            };
            search(root);
            if (!adView) continue;

            UIButton *btn = _findSkipBtn(adView);
            if (btn) { ABLog(@"规则命中"); _simulateTapOnView(btn); return; }
        }

        // 启发式
        UIButton *btn = _findSkipBtn(root);
        if (btn) { ABLog(@"启发式命中"); _simulateTapOnView(btn); return; }

        // 移除容器
        UIView *container = _adContainer(root);
        if (container && container != root) { ABLog(@"移除容器"); [container removeFromSuperview]; }
    });
}

#pragma mark - Hook 实现

static BOOL _inSetLevel = NO;
static void _hook_setLevel(UIWindow *self, SEL _cmd, CGFloat level) {
    if (_inSetLevel) { if (_orig_setLevel) _orig_setLevel(self, _cmd, level); return; }
    _inSetLevel = YES;
    if (self != _floatingWin && level > MAX_OTHER_WINDOW_LEVEL) level = MAX_OTHER_WINDOW_LEVEL;
    if (_orig_setLevel) _orig_setLevel(self, _cmd, level);
    if (self != _floatingWin && !_isLearning) dispatch_async(dispatch_get_main_queue(), ^{ _ensureOnTop(); });
    _inSetLevel = NO;
}

static void _hook_setHidden(UIWindow *self, SEL _cmd, BOOL hidden) {
    if (self == _floatingWin && hidden) return;
    if (_orig_setHidden) _orig_setHidden(self, _cmd, hidden);
}

static void _hook_makeKeyVisible(UIWindow *self, SEL _cmd) {
    if (_orig_makeKeyVisible) _orig_makeKeyVisible(self, _cmd);
    if (self != _floatingWin && !_isLearning) dispatch_async(dispatch_get_main_queue(), ^{ _ensureOnTop(); });
}

static void _hook_sendTouches(UIWindow *self, SEL _cmd, NSSet *touches, UIEvent *event) {
    if (_orig_sendTouches) _orig_sendTouches(self, _cmd, touches, event);
    @try { if (_isLearning) for (UITouch *t in touches) { _handleLearnCapture(t); break; } }
    @catch (NSException *e) {}
}

#pragma mark - 初始化

__attribute__((constructor))
static void _init(void) {
    _loadRules();

    Class c = [UIWindow class];
    Method m;

    SEL s = NSSelectorFromString(@"_sendTouchesForEvent:");
    m = class_getInstanceMethod(c, s);
    if (m) {
        IMP imp = imp_implementationWithBlock(^(UIWindow *self, NSSet *touches, UIEvent *event) { _hook_sendTouches(self, s, touches, event); });
        _orig_sendTouches = (void(*)(id,SEL,NSSet*,UIEvent*))method_setImplementation(m, imp);
    }

    m = class_getInstanceMethod(c, @selector(setWindowLevel:));
    if (m) {
        IMP imp = imp_implementationWithBlock(^(UIWindow *self, CGFloat level) { _hook_setLevel(self, @selector(setWindowLevel:), level); });
        _orig_setLevel = (void(*)(id,SEL,CGFloat))method_setImplementation(m, imp);
    }

    m = class_getInstanceMethod(c, @selector(setHidden:));
    if (m) {
        IMP imp = imp_implementationWithBlock(^(UIWindow *self, BOOL hidden) { _hook_setHidden(self, @selector(setHidden:), hidden); });
        _orig_setHidden = (void(*)(id,SEL,BOOL))method_setImplementation(m, imp);
    }

    m = class_getInstanceMethod(c, @selector(makeKeyAndVisible));
    if (m) {
        IMP imp = imp_implementationWithBlock(^(UIWindow *self) { _hook_makeKeyVisible(self, @selector(makeKeyAndVisible)); });
        _orig_makeKeyVisible = (void(*)(id,SEL))method_setImplementation(m, imp);
    }

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *_) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            _createFloating(); _scanAndSkip();
        });
    }];

    ABLog(@"AdBlock 初始化完成");
}
