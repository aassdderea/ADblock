// ==========================================
// Tweak.m - 通用去开屏广告插件 v2.0（优化版）
// 适用于 iOS 16.x + TrollStore
// ==========================================
// 编译: clang -shared -fobjc-arc -framework UIKit -framework IOKit Tweak.m -o libadblock.dylib
// 注入: 放入 /usr/lib/TweakInject/ 或使用 TrollStore 直接注入
// ==========================================

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <pthread.h>

#pragma mark - 配置常量

static const NSTimeInterval kLongPressDuration   = 1.0;
static const NSTimeInterval kHeuristicDelay      = 1.2;
static const NSTimeInterval kLearnTimeout        = 15.0;
static const NSTimeInterval kSimulateTouchDelay  = 0.04;
static const CGFloat        kFloatingBtnSize     = 56.0;
static const CGFloat        kFloatingBtnMargin   = 16.0;
static const CGFloat        kMaxOtherWindowLevel = 100000.0;
static const NSInteger      kRuleVersion         = 2;

#pragma mark - 日志宏

#define ABLog(fmt, ...)  NSLog(@"[AD-BLOCK][%s] " fmt, __FUNCTION__, ##__VA_ARGS__)
#define ABWarn(fmt, ...) NSLog(@"[AD-BLOCK][WARN][%s] " fmt, __FUNCTION__, ##__VA_ARGS__)
#define ABErr(fmt, ...)  NSLog(@"[AD-BLOCK][ERROR][%s] " fmt, __FUNCTION__, ##__VA_ARGS__)

#ifdef DEBUG
#define ABDebug(fmt, ...) NSLog(@"[AD-BLOCK][DEBUG][%s] " fmt, __FUNCTION__, ##__VA_ARGS__)
#else
#define ABDebug(fmt, ...)
#endif

#pragma mark - 前向声明

@class ABFloatingWindow;
@class ABAnalysisReport;

static void ab_createFloatingWindow(void);
static void ab_ensureFloatingOnTop(void);
static void ab_startLearningMode(void);
static void ab_stopLearningMode(BOOL success);
static void ab_scanAndAutoSkip(void);
static void ab_simulateTapOnView(UIView *view);
static void ab_simulateTapAtPoint(CGPoint screenPoint);
static ABAnalysisReport *ab_analyzeViewHierarchy(UIView *btn, CGPoint tapPoint);
static void ab_showToast(NSString *text, BOOL isSuccess);

#pragma mark - 线程安全的全局状态

// 用 pthread_mutex 保护关键状态
static pthread_mutex_t _stateLock = PTHREAD_MUTEX_INITIALIZER;

static ABFloatingWindow *_floatingWindow = nil;
static UIButton         *_floatingBtn    = nil;
static BOOL              _isLearning     = NO;
static BOOL              _isInitialized  = NO;
static BOOL              _windowLevelHookInstalled = NO;
static dispatch_block_t  _learnTimeoutBlock = nil;

// 学习模式捕获数据
static CGPoint           _capturedTapPoint;
static __weak UIView    *_capturedHitView = nil;

#pragma mark - 规则数据模型

@interface ABRule : NSObject <NSSecureCoding>
@property (nonatomic, copy)   NSString *adViewClassName;      // 广告容器类名
@property (nonatomic, copy)   NSString *adViewClassSuffix;    // 类名后缀（模糊匹配用）
@property (nonatomic, copy)   NSString *skipBtnClassName;     // 跳过按钮类名
@property (nonatomic, copy)   NSString *skipBtnTitle;         // 按钮标题关键字
@property (nonatomic, copy)   NSString *skipBtnAccLabel;      // 无障碍标签
@property (nonatomic, copy)   NSString *parentClassName;      // 父视图类名（辅助匹配）
@property (nonatomic, assign) NSInteger depth;                // 按钮在广告容器中的层级深度
@property (nonatomic, assign) CGRect    btnRelativeFrame;     // 按钮相对容器的归一化坐标
@property (nonatomic, assign) NSInteger ruleVersion;
@property (nonatomic, assign) NSUInteger hitCount;            // 命中次数
@property (nonatomic, copy)   NSDate    *lastHitDate;
+ (NSString *)rulesFilePath;
+ (NSMutableArray<ABRule *> *)loadAllRules;
+ (void)saveAllRules:(NSArray<ABRule *> *)rules;
- (BOOL)matchesAdView:(UIView *)adView skipButton:(UIButton **)outBtn;
@end

@implementation ABRule

+ (BOOL)supportsSecureCoding { return YES; }

+ (NSString *)rulesFilePath {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = paths.firstObject ?: NSTemporaryDirectory();
        path = [docDir stringByAppendingPathComponent:@"com.adblocker.rules.v2.plist"];
    });
    return path;
}

+ (NSMutableArray<ABRule *> *)loadAllRules {
    @try {
        NSData *data = [NSData dataWithContentsOfFile:[self rulesFilePath]];
        if (!data) return [NSMutableArray array];
        NSSet *classes = [NSSet setWithArray:@[[ABRule class], [NSArray class], [NSDictionary class],
                                                [NSString class], [NSDate class], [NSNumber class]]];
        NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:nil];
        unarchiver.requiresSecureCoding = YES;
        NSArray *rules = [unarchiver decodeObjectOfClasses:classes forKey:@"rules"];
        [unarchiver finishDecoding];
        return rules ? [rules mutableCopy] : [NSMutableArray array];
    } @catch (NSException *e) {
        ABWarn(@"规则加载失败: %@", e);
        return [NSMutableArray array];
    }
}

+ (void)saveAllRules:(NSArray<ABRule *> *)rules {
    @try {
        NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
        [archiver encodeObject:rules forKey:@"rules"];
        [archiver finishEncoding];
        [archiver.encodedData writeToFile:[self rulesFilePath] atomically:YES];
        ABLog(@"✅ 已保存 %lu 条规则到 %@", (unsigned long)rules.count, [self rulesFilePath]);
    } @catch (NSException *e) {
        ABErr(@"规则保存失败: %@", e);
    }
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:_adViewClassName forKey:@"adViewClassName"];
    [coder encodeObject:_adViewClassSuffix forKey:@"adViewClassSuffix"];
    [coder encodeObject:_skipBtnClassName forKey:@"skipBtnClassName"];
    [coder encodeObject:_skipBtnTitle forKey:@"skipBtnTitle"];
    [coder encodeObject:_skipBtnAccLabel forKey:@"skipBtnAccLabel"];
    [coder encodeObject:_parentClassName forKey:@"parentClassName"];
    [coder encodeInteger:_depth forKey:@"depth"];
    [coder encodeCGRect:_btnRelativeFrame forKey:@"btnRelativeFrame"];
    [coder encodeInteger:_ruleVersion forKey:@"ruleVersion"];
    [coder encodeInteger:_hitCount forKey:@"hitCount"];
    [coder encodeObject:_lastHitDate forKey:@"lastHitDate"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _adViewClassName  = [coder decodeObjectOfClass:[NSString class] forKey:@"adViewClassName"];
        _adViewClassSuffix = [coder decodeObjectOfClass:[NSString class] forKey:@"adViewClassSuffix"];
        _skipBtnClassName = [coder decodeObjectOfClass:[NSString class] forKey:@"skipBtnClassName"];
        _skipBtnTitle     = [coder decodeObjectOfClass:[NSString class] forKey:@"skipBtnTitle"];
        _skipBtnAccLabel  = [coder decodeObjectOfClass:[NSString class] forKey:@"skipBtnAccLabel"];
        _parentClassName  = [coder decodeObjectOfClass:[NSString class] forKey:@"parentClassName"];
        _depth            = [coder decodeIntegerForKey:@"depth"];
        _btnRelativeFrame = [coder decodeCGRectForKey:@"btnRelativeFrame"];
        _ruleVersion      = [coder decodeIntegerForKey:@"ruleVersion"];
        _hitCount         = [coder decodeIntegerForKey:@"hitCount"];
        _lastHitDate      = [coder decodeObjectOfClass:[NSDate class] forKey:@"lastHitDate"];
    }
    return self;
}

/// 模糊匹配：类名可能带前缀/后缀（如 __XXSplashAdView）
- (BOOL)matchesAdView:(UIView *)adView skipButton:(UIButton **)outBtn {
    NSString *clsName = NSStringFromClass([adView class]);

    // 策略1: 精确匹配
    BOOL classMatch = [clsName isEqualToString:self.adViewClassName];
    // 策略2: 后缀匹配（应对SDK混淆/版本变化）
    if (!classMatch && self.adViewClassSuffix.length > 3) {
        classMatch = [clsName hasSuffix:self.adViewClassSuffix];
    }
    // 策略3: 包含匹配（最宽松）
    if (!classMatch && self.adViewClassName.length > 5) {
        classMatch = [clsName containsString:self.adViewClassName];
    }
    if (!classMatch) return NO;

    // 在 adView 中查找跳过按钮
    UIButton *btn = [self _findSkipButtonIn:adView];
    if (outBtn) *outBtn = btn;
    return (btn != nil);
}

- (UIButton *)_findSkipButtonIn:(UIView *)root {
    // 优先按类名精确查找
    if (self.skipBtnClassName.length > 0) {
        UIButton *found = (UIButton *)[self _findSubviewOfClassNamed:self.skipBtnClassName in:root];
        if (found && [found isKindOfClass:[UIButton class]]) {
            if ([self _isSkipButton:found]) return found;
        }
    }
    // 回退：关键字启发式搜索
    return [self _heuristicFindSkipButtonIn:root];
}

- (UIView *)_findSubviewOfClassNamed:(NSString *)name in:(UIView *)root {
    if ([NSStringFromClass([root class]) isEqualToString:name]) return root;
    for (UIView *sub in root.subviews) {
        UIView *f = [self _findSubviewOfClassNamed:name in:sub];
        if (f) return f;
    }
    return nil;
}

- (UIButton *)_heuristicFindSkipButtonIn:(UIView *)v {
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)v;
        if ([self _isSkipButton:btn]) return btn;
    }
    // 也检查 UITapGestureRecognizer 挂在 UILabel/UIView 上的情况
    if (![v isKindOfClass:[UIButton class]] && v.userInteractionEnabled) {
        for (UIGestureRecognizer *gr in v.gestureRecognizers ?: @[]) {
            if ([gr isKindOfClass:[UITapGestureRecognizer class]]) {
                NSString *text = @"";
                if ([v respondsToSelector:@selector(text)]) text = [(id)v text];
                if ([v respondsToSelector:@selector(accessibilityLabel)]) text = v.accessibilityLabel ?: text;
                if ([self _textContainsSkipKeyword:text]) {
                    // 创建一个伪按钮包装
                    ABLog(@"找到非按钮跳过控件: %@", NSStringFromClass([v class]));
                    // 返回 nil 但后续会用 simulateTapAtPoint 处理
                }
            }
        }
    }
    for (UIView *sub in v.subviews) {
        UIButton *r = [self _heuristicFindSkipButtonIn:sub];
        if (r) return r;
    }
    return nil;
}

- (BOOL)_isSkipButton:(UIButton *)btn {
    NSString *title = btn.titleLabel.text ?: @"";
    NSString *accLabel = btn.accessibilityLabel ?: @"";
    NSString *currentTitle = btn.currentTitle ?: @"";
    return [self _textContainsSkipKeyword:title] ||
           [self _textContainsSkipKeyword:accLabel] ||
           [self _textContainsSkipKeyword:currentTitle];
}

- (BOOL)_textContainsSkipKeyword:(NSString *)text {
    if (!text.length) return NO;
    NSArray *keywords = @[@"跳过", @"skip", @"Skip", @"SKIP",
                          @"关闭", @"close", @"Close",
                          @"跳过广告", @"关闭广告", @"倒计时"];
    for (NSString *kw in keywords) {
        if ([text containsString:kw]) return YES;
    }
    return NO;
}

@end

#pragma mark - 分析报告模型

@interface ABAnalysisReport : NSObject
@property (nonatomic, strong) UIView   *adContainerView;   // 广告容器
@property (nonatomic, strong) UIButton *skipButton;         // 跳过按钮
@property (nonatomic, strong) UIView   *tapTargetView;      // 实际被点击的 view
@property (nonatomic, copy)   NSString *adContainerClassName;
@property (nonatomic, copy)   NSString *adContainerClassSuffix;
@property (nonatomic, copy)   NSString *skipBtnClassName;
@property (nonatomic, copy)   NSString *skipBtnTitle;
@property (nonatomic, copy)   NSString *skipBtnAccLabel;
@property (nonatomic, copy)   NSString *parentClassName;
@property (nonatomic, assign) NSInteger depth;
@property (nonatomic, copy)   NSArray<NSString *> *hierarchyChain; // 从按钮到容器的类名链
@property (nonatomic, copy)   NSArray<NSString *> *targetActions;  // 按钮的 target-action 信息
@property (nonatomic, copy)   NSDictionary *extraInfo;             // 额外诊断信息
- (ABRule *)generateRule;
- (NSString *)description;
@end

@implementation ABAnalysisReport

- (ABRule *)generateRule {
    ABRule *rule = [ABRule new];
    rule.adViewClassName   = self.adContainerClassName ?: @"";
    rule.adViewClassSuffix = self.adContainerClassSuffix ?: @"";
    rule.skipBtnClassName  = self.skipBtnClassName ?: @"";
    rule.skipBtnTitle      = self.skipBtnTitle ?: @"";
    rule.skipBtnAccLabel   = self.skipBtnAccLabel ?: @"";
    rule.parentClassName   = self.parentClassName ?: @"";
    rule.depth             = self.depth;
    rule.ruleVersion       = kRuleVersion;
    rule.hitCount          = 0;
    rule.lastHitDate       = [NSDate date];

    // 计算归一化坐标
    if (self.adContainerView && self.skipButton) {
        CGRect btnFrame = [self.skipButton convertRect:self.skipButton.bounds toView:self.adContainerView];
        CGRect containerBounds = self.adContainerView.bounds;
        if (containerBounds.size.width > 0 && containerBounds.size.height > 0) {
            rule.btnRelativeFrame = CGRectMake(
                btnFrame.origin.x / containerBounds.size.width,
                btnFrame.origin.y / containerBounds.size.height,
                btnFrame.size.width / containerBounds.size.width,
                btnFrame.size.height / containerBounds.size.height
            );
        }
    }
    return rule;
}

- (NSString *)description {
    NSMutableString *s = [NSMutableString stringWithString:@"\n========== 广告分析报告 ==========\n"];
    [s appendFormat:@"广告容器: %@\n", self.adContainerClassName ?: @"(nil)"];
    [s appendFormat:@"容器后缀: %@\n", self.adContainerClassSuffix ?: @"(nil)"];
    [s appendFormat:@"父视图类: %@\n", self.parentClassName ?: @"(nil)"];
    [s appendFormat:@"跳过按钮: %@\n", self.skipBtnClassName ?: @"(nil)"];
    [s appendFormat:@"按钮标题: %@\n", self.skipBtnTitle ?: @"(nil)"];
    [s appendFormat:@"无障碍标签: %@\n", self.skipBtnAccLabel ?: @"(nil)"];
    [s appendFormat:@"层级深度: %ld\n", (long)self.depth];
    [s appendFormat:@"视图链: %@\n", [self.hierarchyChain componentsJoinedByString:@" → "]];
    [s appendFormat:@"Target-Actions: %@\n", [self.targetActions componentsJoinedByString:@", "]];
    [s appendFormat:@"额外信息: %@\n", self.extraInfo];
    [s appendString:@"==================================\n"];
    return [s copy];
}

@end

#pragma mark - 手势处理代理

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
@property (nonatomic, assign) BOOL isInteracting; // 防止穿透冲突
@end

@implementation ABFloatingWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // 只有点在按钮上时才拦截，其他全部穿透
    if (self.mainButton) {
        CGPoint btnPoint = [self.mainButton convertPoint:point fromView:self];
        if ([self.mainButton pointInside:btnPoint withEvent:event]) {
            return self.mainButton;
        }
    }
    // 学习模式下完全穿透，让用户能点到广告
    if (_isLearning) return nil;
    return nil;
}

- (BOOL)_canBecomeKeyWindow { return NO; }

// iOS 13+ scene-based window
- (BOOL)_shouldCreateContextAsSecure { return NO; }

@end

#pragma mark - 核心工具函数

/// 安全获取顶层窗口（排除自己的悬浮窗）
static UIWindow *_ab_topWindow(void) {
    UIWindow *top = nil;
    CGFloat maxLevel = -1;

    @try {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in scene.windows) {
                if (w == _floatingWindow) continue;
                if (w.hidden || w.alpha < 0.01) continue;
                if (w.windowLevel > maxLevel) {
                    maxLevel = w.windowLevel;
                    top = w;
                }
            }
        }
        // 回退：如果没有 scene-based window，尝试老式 API
        if (!top) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w == _floatingWindow) continue;
                if (w.hidden || w.alpha < 0.01) continue;
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

/// 递归查找"跳过"按钮（增强版）
static UIButton *_ab_findSkipButton(UIView *root) {
    if (!root) return nil;

    if ([root isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)root;
        NSString *title = btn.titleLabel.text ?: btn.currentTitle ?: @"";
        NSString *accLabel = btn.accessibilityLabel ?: @"";
        NSArray *kw = @[@"跳过", @"skip", @"Skip", @"关闭", @"close", @"关闭广告"];
        for (NSString *k in kw) {
            if ([title containsString:k] || [accLabel containsString:k]) return btn;
        }
    }

    for (UIView *sub in root.subviews) {
        UIButton *r = _ab_findSkipButton(sub);
        if (r) return r;
    }
    return nil;
}

/// 查找全屏广告容器（向上遍历找到占满屏幕的视图）
static UIView *_ab_findAdContainer(UIView *fromView) {
    CGRect screen = [UIScreen mainScreen].bounds;
    UIView *candidate = nil;

    UIView *cur = fromView;
    while (cur) {
        CGRect frame = cur.frame;
        // 容器至少占屏幕 80%
        if (frame.size.width  >= screen.size.width  * 0.8 &&
            frame.size.height >= screen.size.height * 0.8) {
            candidate = cur;
            // 继续往上找，可能还有更合适的
        }
        cur = cur.superview;
    }
    return candidate;
}

/// 提取类名的"核心后缀"（去掉常见前缀如 _、__、数字等）
static NSString *_ab_classSuffix(NSString *className) {
    if (!className.length) return @"";
    // 去掉前导下划线和数字
    NSString *clean = className;
    while (clean.length > 0 && ([clean hasPrefix:@"_"] || [clean hasPrefix:@"0"] ||
           [clean hasPrefix:@"1"] || [clean hasPrefix:@"2"] || [clean hasPrefix:@"3"] ||
           [clean hasPrefix:@"4"] || [clean hasPrefix:@"5"] || [clean hasPrefix:@"6"] ||
           [clean hasPrefix:@"7"] || [clean hasPrefix:@"8"] || [clean hasPrefix:@"9"])) {
        clean = [clean substringFromIndex:1];
    }
    // 取后 15 个字符作为后缀标识
    if (clean.length > 15) {
        return [clean substringFromIndex:clean.length - 15];
    }
    return clean;
}

#pragma mark - 深度分析引擎

static ABAnalysisReport *_ab_deepAnalyze(UIButton *tappedBtn, CGPoint tapPoint) {
    ABAnalysisReport *report = [ABAnalysisReport new];
    report.skipButton = tappedBtn;
    report.skipBtnClassName = NSStringFromClass([tappedBtn class]);
    report.skipBtnTitle = tappedBtn.titleLabel.text ?: tappedBtn.currentTitle ?: @"";
    report.skipBtnAccLabel = tappedBtn.accessibilityLabel ?: @"";

    // 1. 查找广告容器
    UIView *container = _ab_findAdContainer(tappedBtn);
    if (!container) {
        // 如果没找到全屏容器，用 tappedBtn 的顶层 superview
        container = tappedBtn;
        while (container.superview) container = container.superview;
    }
    report.adContainerView = container;
    report.adContainerClassName = NSStringFromClass([container class]);
    report.adContainerClassSuffix = _ab_classSuffix(NSStringFromClass([container class]));

    // 2. 记录层级深度
    NSInteger depth = 0;
    UIView *cur = tappedBtn;
    NSMutableArray *chain = [NSMutableArray array];
    while (cur && cur != container) {
        [chain addObject:NSStringFromClass([cur class])];
        cur = cur.superview;
        depth++;
    }
    [chain addObject:NSStringFromClass([container class])];
    report.depth = depth;
    report.hierarchyChain = [chain copy];

    // 3. 父视图类名
    report.parentClassName = tappedBtn.superview ? NSStringFromClass([tappedBtn.superview class]) : @"";

    // 4. 提取 target-action 信息（诊断用）
    NSMutableArray *actions = [NSMutableArray array];
    @try {
        // UIControl 的 allTargets 和 actionsForTarget:forControlEvent:
        NSSet *targets = [tappedBtn allTargets];
        for (id target in targets) {
            NSArray *acts = [tappedBtn actionsForTarget:target forControlEvents:UIControlEventTouchUpInside];
            for (NSString *act in acts ?: @[]) {
                [actions addObject:[NSString stringWithFormat:@"%@→%@", NSStringFromClass([target class]), act]];
            }
        }
    } @catch (NSException *e) {
        [actions addObject:@"(无法获取)"];
    }
    report.targetActions = [actions copy];

    // 5. 额外诊断信息
    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    extra[@"btnFrame"] = NSStringFromCGRect(tappedBtn.frame);
    extra[@"btnHidden"] = @(tappedBtn.isHidden);
    extra[@"btnEnabled"] = @(tappedBtn.isEnabled);
    extra[@"btnAlpha"] = @(tappedBtn.alpha);
    extra[@"containerFrame"] = NSStringFromCGRect(container.frame);
    extra[@"tapPoint"] = NSStringFromCGPoint(tapPoint);

    // 检查是否有手势识别器
    NSMutableArray *gestures = [NSMutableArray array];
    UIView *scanView = tappedBtn;
    while (scanView) {
        for (UIGestureRecognizer *gr in scanView.gestureRecognizers ?: @[]) {
            [gestures addObject:[NSString stringWithFormat:@"%@(enabled=%d)",
                                 NSStringFromClass([gr class]), gr.isEnabled]];
        }
        if (scanView == container) break;
        scanView = scanView.superview;
    }
    extra[@"gestureRecognizers"] = gestures;

    report.extraInfo = [extra copy];
    return report;
}

#pragma mark - 触摸模拟（三级策略）

/// 策略1: 直接发送 UIControl action（最可靠）
static BOOL _ab_tryDirectAction(UIButton *btn) {
    @try {
        NSSet *targets = [btn allTargets];
        if (targets.count == 0) return NO;

        for (id target in targets) {
            NSArray *actions = [btn actionsForTarget:target forControlEvents:UIControlEventTouchUpInside];
            for (NSString *actionName in actions) {
                SEL sel = NSSelectorFromString(actionName);
                if ([target respondsToSelector:sel]) {
                    ABLog(@"策略1: 直接调用 %@ → %@", NSStringFromClass([target class]), actionName);
                    // 使用 performSelector 或 objc_msgSend
                    ((void(*)(id, SEL))objc_msgSend)(target, sel);
                    return YES;
                }
            }
        }

        // 尝试 sendActionsForControlEvents
        ABLog(@"策略1b: sendActionsForControlEvents");
        [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    } @catch (NSException *e) {
        ABWarn(@"策略1失败: %@", e);
        return NO;
    }
}

/// 策略2: 通过 UIApplication sendEvent: 注入触摸事件（高仿真）
static void _ab_injectTouchViaSendEvent(CGPoint screenPoint) {
    UIWindow *targetWindow = _ab_topWindow();
    if (!targetWindow) return;

    CGPoint windowPoint = [targetWindow convertPoint:screenPoint fromWindow:nil];
    UIView *hitView = [targetWindow hitTest:windowPoint withEvent:nil];
    if (!hitView) hitView = targetWindow;

    ABLog(@"策略2: 注入触摸到 %@ at %@", NSStringFromClass([hitView class]), NSStringFromCGPoint(windowPoint));

    // 使用 IOKit 私有 API 创建 IOHIDEvent（最底层，最真实）
    // 回退方案：构造 UITouch + UIEvent 通过 UIApplication sendEvent:

    @try {
        // 创建 UITouch - iOS 16 兼容方式
        UITouch *touch = [[UITouch alloc] init];

        // 使用 KVC 设置私有 ivar（iOS 16 兼容的 key 名）
        [touch setValue:@(windowPoint) forKey:@"locationInWindow"];
        [touch setValue:hitView forKey:@"view"];
        [touch setValue:targetWindow forKey:@"window"];
        [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
        [touch setValue:@(1) forKey:@"tapCount"];
        [touch setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"_timestamp"];
        [touch setValue:@(5.0) forKey:@"majorRadius"];
        [touch setValue:@(5.0) forKey:@"_majorRadius"];

        // 创建 UIEvent
        UIEvent *event = [[UIEvent alloc] init];
        [event setValue:[NSSet setWithObject:touch] forKey:@"touches"];
        [event setValue:@(1) forKey:@"type"]; // UIEventTypeTouches
        [event setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"_timestamp"];

        // 通过 UIApplication sendEvent: 分发
        [[UIApplication sharedApplication] sendEvent:event];

        // 延迟发送 Ended
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
        ABWarn(@"策略2失败，回退到策略3: %@", e);
        // 策略3: 直接调用 touchesBegan/Ended
        [hitView touchesBegan:[NSSet setWithObject:touch] withEvent:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSimulateTouchDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [hitView touchesEnded:[NSSet setWithObject:touch] withEvent:nil];
        });
    }
}

/// 策略3: 直接调用 view 的 touchesBegan/Ended（最后的保底）
static void _ab_directTouchCall(UIView *view, CGPoint pointInWindow) {
    ABLog(@"策略3: 直接触摸调用 %@", NSStringFromClass([view class]));
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:@(pointInWindow) forKey:@"locationInWindow"];
    [touch setValue:view forKey:@"view"];
    [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
    [touch setValue:@(1) forKey:@"tapCount"];
    [touch setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"_timestamp"];

    [view touchesBegan:[NSSet setWithObject:touch] withEvent:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSimulateTouchDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
        [touch setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"_timestamp"];
        [view touchesEnded:[NSSet setWithObject:touch] withEvent:nil];
    });
}

/// 主入口：模拟点击（三级策略依次尝试）
static void ab_simulateTapOnView(UIView *view) {
    if (!view) return;

    @autoreleasepool {
        // 策略1: 如果是 UIButton，先尝试直接 action 调用
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)view;
            if (_ab_tryDirectAction(btn)) {
                ABLog(@"✅ 策略1成功: 直接 action 调用");
                return;
            }
        }

        // 策略2: 通过 sendEvent: 注入（最接近真实触摸）
        CGRect frame = [view convertRect:view.bounds toView:nil];
        CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));

        // 添加微小随机偏移，模拟人手
        center.x += ((CGFloat)arc4random_uniform(400) / 100.0) - 2.0;
        center.y += ((CGFloat)arc4random_uniform(400) / 100.0) - 2.0;

        _ab_injectTouchViaSendEvent(center);
    }
}

/// 坐标模拟点击（用于学习模式回放）
static void ab_simulateTapAtPoint(CGPoint screenPoint) {
    UIWindow *win = _ab_topWindow();
    if (!win) return;
    CGPoint wp = [win convertPoint:screenPoint fromWindow:nil];
    UIView *hit = [win hitTest:wp withEvent:nil] ?: win;

    // 先尝试找按钮并直接 action
    UIView *cur = hit;
    while (cur) {
        if ([cur isKindOfClass:[UIButton class]]) {
            if (_ab_tryDirectAction((UIButton *)cur)) return;
            break;
        }
        cur = cur.superview;
    }

    // 回退到注入触摸
    _ab_injectTouchViaSendEvent(screenPoint);
}

#pragma mark - 已知 SDK Hook

static BOOL _knownSDKHooked = NO;

/// 通用 hook 辅助函数
static IMP _ab_replaceMethod(Class cls, SEL sel, id block) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP newImp = imp_implementationWithBlock(block);
    IMP oldImp = method_setImplementation(m, newImp);
    return oldImp;
}

static void _ab_hookKnownSDKs(void) {
    if (_knownSDKHooked) return;
    _knownSDKHooked = YES;

    // 穿山甲 (CSJ / Bytedance)
    Class c;
    c = NSClassFromString(@"BUSplashAdView");
    if (c) {
        _ab_replaceMethod(c, @selector(showInWindow:), ^void(id self, UIWindow *w) {
            ABLog(@"穿山甲开屏广告已拦截");
            id delegate = [self valueForKey:@"delegate"];
            SEL closeSel = NSSelectorFromString(@"splashAdDidClose:");
            if (delegate && [delegate respondsToSelector:closeSel]) {
                ((void(*)(id, SEL, id))objc_msgSend)(delegate, closeSel, self);
            }
        });
    }

    // 优量汇 (GDT / Tencent)
    c = NSClassFromString(@"GDTSplashAd");
    if (c) {
        _ab_replaceMethod(c, @selector(loadAndShowInWindow:), ^void(id self, UIWindow *w) {
            ABLog(@"优量汇开屏广告已拦截");
            id delegate = [self valueForKey:@"delegate"];
            SEL dismissSel = NSSelectorFromString(@"splashAdDidDismiss:");
            if (delegate && [delegate respondsToSelector:dismissSel]) {
                ((void(*)(id, SEL, id))objc_msgSend)(delegate, dismissSel, self);
            }
        });
    }

    // 百度广告
    c = NSClassFromString(@"BaiduMobAdSplash");
    if (c) {
        _ab_replaceMethod(c, @selector(showInWindow:), ^void(id self, UIWindow *w) {
            ABLog(@"百度开屏广告已拦截");
            id delegate = [self valueForKey:@"delegate"];
            SEL closeSel = NSSelectorFromString(@"splashAdDidClose:");
            if (delegate && [delegate respondsToSelector:closeSel]) {
                ((void(*)(id, SEL, id))objc_msgSend)(delegate, closeSel, self);
            }
        });
    }

    // 快手广告
    c = NSClassFromString(@"KsAdSplashView");
    if (c) {
        _ab_replaceMethod(c, @selector(showInWindow:), ^void(id self, UIWindow *w) {
            ABLog(@"快手开屏广告已拦截");
            id delegate = [self valueForKey:@"delegate"];
            SEL closeSel = NSSelectorFromString(@"splashAdDidClose:");
            if (delegate && [delegate respondsToSelector:closeSel]) {
                ((void(*)(id, SEL, id))objc_msgSend)(delegate, closeSel, self);
            }
        });
    }

    ABLog(@"已知 SDK Hook 安装完成");
}

#pragma mark - 悬浮窗创建与管理

static ABGestureDelegate *_gestureDelegate = nil;

static void ab_createFloatingWindow(void) {
    if (_floatingWindow) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (_floatingWindow) return;

        _floatingWindow = [[ABFloatingWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

        // 绑定到活跃的 scene
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
        _floatingWindow.userInteractionEnabled = YES;

        // 创建主按钮
        CGFloat s = kFloatingBtnSize;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - s - kFloatingBtnMargin,
                               120, s, s);
        btn.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
        btn.layer.cornerRadius = s / 2.0;
        btn.layer.borderWidth = 2.5;
        btn.layer.borderColor = [UIColor whiteColor].CGColor;
        btn.layer.shadowColor = [UIColor blackColor].CGColor;
        btn.layer.shadowOffset = CGSizeMake(0, 3);
        btn.layer.shadowOpacity = 0.4;
        btn.layer.shadowRadius = 6;
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [btn setTitle:@"去广告" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

        // 单击：扫描并自动跳过
        [_floatingBtn addTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside]; // placeholder
        _gestureDelegate = [ABGestureDelegate new];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                         initWithTarget:_gestureDelegate action:@selector(handleTap:)];
        _gestureDelegate.tapHandler = ^(UITapGestureRecognizer *g) {
            if (_isLearning) return;
            ab_scanAndAutoSkip();
        };
        [btn addGestureRecognizer:tap];

        // 长按：进入学习模式
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                                             initWithTarget:_gestureDelegate action:@selector(handleLongPress:)];
        lp.minimumPressDuration = kLongPressDuration;
        lp.allowableMovement = 15;
        _gestureDelegate.longPressHandler = ^(UILongPressGestureRecognizer *g) {
            if (g.state == UIGestureRecognizerStateBegan && !_isLearning) {
                ab_startLearningMode();
            }
        };
        [btn addGestureRecognizer:lp];

        // 拖拽移动
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

        ABLog(@"🔴 悬浮窗已创建 (level=%.0f, scene=%@)",
              _floatingWindow.windowLevel,
              _floatingWindow.windowScene ? @"yes" : @"no");
    });
}

static void ab_ensureFloatingOnTop(void) {
    if (!_floatingWindow) return;

    static BOOL _isAdjusting = NO;
    if (_isAdjusting) return; // 防止递归
    _isAdjusting = YES;

    if (!_isLearning) {
        // 确保层级高于所有其他窗口
        CGFloat maxLevel = 0;
        @try {
            for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
                for (UIWindow *w in sc.windows) {
                    if (w != _floatingWindow && !w.hidden) {
                        maxLevel = MAX(maxLevel, w.windowLevel);
                    }
                }
            }
        } @catch (NSException *e) {}

        CGFloat desiredLevel = MAX(maxLevel + 1.0, kMaxOtherWindowLevel + 1.0);
        if (_floatingWindow.windowLevel != desiredLevel) {
            _floatingWindow.windowLevel = desiredLevel;
        }
    }

    _floatingWindow.hidden = NO;
    _floatingWindow.alpha = 1.0;
    _isAdjusting = NO;
}

#pragma mark - 学习模式

static void ab_startLearningMode(void) {
    pthread_mutex_lock(&_stateLock);
    if (_isLearning) {
        pthread_mutex_unlock(&_stateLock);
        return;
    }
    _isLearning = YES;
    pthread_mutex_unlock(&_stateLock);

    dispatch_async(dispatch_get_main_queue(), ^{
        [_floatingBtn setTitle:@"学习中" forState:UIControlStateNormal];
        _floatingBtn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.9];

        // 降低悬浮窗层级让触摸穿透
        _floatingWindow.windowLevel = kMaxOtherWindowLevel - 1.0;

        // 添加脉冲动画提示用户
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        pulse.fromValue = @(1.0);
        pulse.toValue = @(1.15);
        pulse.duration = 0.6;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VAL;
        [_floatingBtn.layer addAnimation:pulse forKey:@"learnPulse"];

        ab_showToast(@"📖 学习模式已启动\n请点击广告的「跳过」按钮", YES);

        // 超时保护
        _learnTimeoutBlock = ^{
            ab_stopLearningMode(NO);
            ab_showToast(@"⏰ 学习超时，已自动退出", NO);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLearnTimeout * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), _learnTimeoutBlock);

        ABLog(@"📖 学习模式启动，等待用户点击跳过按钮...");
    });
}

static void ab_stopLearningMode(BOOL success) {
    pthread_mutex_lock(&_stateLock);
    if (!_isLearning) {
        pthread_mutex_unlock(&_stateLock);
        return;
    }
    _isLearning = NO;
    pthread_mutex_unlock(&_stateLock);

    // 取消超时
    _learnTimeoutBlock = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        [_floatingBtn setTitle:@"去广告" forState:UIControlStateNormal];
        _floatingBtn.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
        [_floatingBtn.layer removeAnimationForKey:@"learnPulse"];
        ab_ensureFloatingOnTop();
    });

    ABLog(@"📖 学习模式已退出 (success=%d)", success);
}

#pragma mark - 学习捕获处理

/// 学习模式的核心：捕获用户点击并分析
static void _ab_handleLearningCapture(UITouch *touch, UIEvent *event) {
    if (!_isLearning) return;
    if (touch.phase != UITouchPhaseEnded) return;
    if (touch.tapCount != 1) return;

    // 获取点击位置
    CGPoint screenPoint = [touch locationInView:nil];
    UIWindow *touchWindow = touch.window;

    // 排除点在自己悬浮窗上的情况
    if (touchWindow == _floatingWindow) return;

    ABLog(@"📝 捕获点击: screen=%@ window=%@",
          NSStringFromCGPoint(screenPoint),
          NSStringFromClass([touchWindow class]));

    // 保存捕获数据
    _capturedTapPoint = screenPoint;

    // 异步分析（避免阻塞触摸响应链）
    dispatch_async(dispatch_get_main_queue(), ^{
        // 取消超时
        _learnTimeoutBlock = nil;

        // 短暂延迟，让广告 SDK 有机会处理点击
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{

            UIWindow *topWin = _ab_topWindow();
            if (!topWin) {
                ab_stopLearningMode(NO);
                ab_showToast(@"❌ 无法获取广告窗口", NO);
                return;
            }

            // 从点击位置找到被点击的 view
            CGPoint windowPoint = [topWin convertPoint:screenPoint fromWindow:nil];
            UIView *hitView = [topWin hitTest:windowPoint withEvent:nil];

            // 向上查找 UIButton
            UIButton *skipBtn = nil;
            UIView *cur = hitView;
            while (cur) {
                if ([cur isKindOfClass:[UIButton class]]) {
                    skipBtn = (UIButton *)cur;
                    break;
                }
                cur = cur.superview;
            }

            // 如果没找到 UIButton，也检查 UILabel 上的手势（有些 SDK 用 label + tapGesture）
            if (!skipBtn && hitView) {
                // 检查 hitView 或上层是否有 tap 手势
                UIView *gestureView = hitView;
                while (gestureView) {
                    for (UIGestureRecognizer *gr in gestureView.gestureRecognizers ?: @[]) {
                        if ([gr isKindOfClass:[UITapGestureRecognizer class]] && gr.isEnabled) {
                            ABLog(@"找到手势识别器: %@ on %@", NSStringFromClass([gr class]), NSStringFromClass([gestureView class]));
                            // 创建一个虚拟的"按钮"记录
                            // 这里直接触发手势
                            [gr setState:UIGestureRecognizerStateBegan];
                            // 触发 target-action
                            NSSet *targets = [gr valueForKey:@"_targets"];
                            // ... 复杂，暂时跳过
                            break;
                        }
                    }
                    if (gestureView == gestureView.superview) break;
                    gestureView = gestureView.superview;
                }
            }

            if (!skipBtn) {
                ab_stopLearningMode(NO);
                ab_showToast(@"❌ 未找到跳过按钮\n请准确点击「跳过」按钮", NO);
                ABWarn(@"学习模式：未在点击位置找到跳过按钮 hitView=%@", NSStringFromClass([hitView class]));
                return;
            }

            // ===== 深度分析 =====
            ABAnalysisReport *report = _ab_deepAnalyze(skipBtn, screenPoint);
            ABLog(@"%@", report.description);

            // 验证按钮文本
            NSString *title = report.skipBtnTitle;
            NSString *accLabel = report.skipBtnAccLabel;
            BOOL isSkipBtn = NO;
            NSArray *keywords = @[@"跳过", @"skip", @"Skip", @"关闭", @"close", @"关闭广告", @"跳过广告"];
            for (NSString *kw in keywords) {
                if ([title containsString:kw] || [accLabel containsString:kw]) {
                    isSkipBtn = YES;
                    break;
                }
            }

            if (!isSkipBtn) {
                ab_stopLearningMode(NO);
                ab_showToast([NSString stringWithFormat:@"⚠️ 该按钮不像跳过按钮\n标题: %@", title], NO);
                return;
            }

            // ===== 生成并保存规则 =====
            ABRule *rule = [report generateRule];

            // 去重检查
            NSMutableArray *rules = [ABRule loadAllRules];
            BOOL duplicate = NO;
            for (ABRule *existing in rules) {
                if ([existing.adViewClassName isEqualToString:rule.adViewClassName] &&
                    [existing.skipBtnClassName isEqualToString:rule.skipBtnClassName]) {
                    existing.hitCount++;
                    existing.lastHitDate = [NSDate date];
                    duplicate = YES;
                    ABLog(@"规则已存在，更新命中次数");
                    break;
                }
            }
            if (!duplicate) {
                [rules addObject:rule];
            }
            [ABRule saveAllRules:rules];

            ab_stopLearningMode(YES);
            ab_showToast([NSString stringWithFormat:@"✅ 规则已保存!\n广告: %@\n按钮: %@",
                          rule.adViewClassSuffix, rule.skipBtnTitle], YES);
        });
    });
}

#pragma mark - 自动扫描跳过

static void ab_scanAndAutoSkip(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHeuristicDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{

        UIWindow *top = _ab_topWindow();
        if (!top) {
            ab_showToast(@"⚠️ 未找到广告窗口", NO);
            return;
        }

        UIView *rootView = top.rootViewController.view ?: top;
        BOOL skipped = NO;

        // 1. 先尝试已保存的规则匹配
        NSArray *rules = [ABRule loadAllRules];
        for (ABRule *rule in rules) {
            UIButton *btn = nil;
            if ([rule matchesAdView:rootView skipButton:&btn]) {
                ABLog(@"✅ 规则命中: %@", rule.adViewClassName);
                ab_simulateTapOnView(btn);
                rule.hitCount++;
                rule.lastHitDate = [NSDate date];
                skipped = YES;
                break;
            }

            // 也搜索子视图
            for (UIView *sub in rootView.subviews) {
                if ([rule matchesAdView:sub skipButton:&btn]) {
                    ABLog(@"✅ 规则命中(子视图): %@", rule.adViewClassName);
                    ab_simulateTapOnView(btn);
                    rule.hitCount++;
                    rule.lastHitDate = [NSDate date];
                    skipped = YES;
                    break;
                }
            }
            if (skipped) break;
        }

        // 保存更新的命中计数
        if (skipped) {
            [ABRule saveAllRules:[ABRule loadAllRules]]; // 简单重新加载保存
        }

        if (!skipped) {
            // 2. 回退：启发式搜索跳过按钮
            UIButton *btn = _ab_findSkipButton(rootView);
            if (btn) {
                ABLog(@"✅ 启发式找到跳过按钮: %@", btn.titleLabel.text);
                ab_simulateTapOnView(btn);
                skipped = YES;
            }
        }

        if (skipped) {
            ab_showToast(@"✅ 广告已跳过", YES);
        } else {
            // 3. 最后尝试：直接移除广告视图
            UIView *container = _ab_findAdContainer(rootView);
            if (container && container != rootView) {
                ABLog(@"⚠️ 未找到跳过按钮，尝试直接移除广告容器");
                [UIView animateWithDuration:0.25 animations:^{
                    container.alpha = 0;
                } completion:^(BOOL finished) {
                    [container removeFromSuperview];
                }];
                ab_showToast(@"⚠️ 未找到跳过按钮\n已尝试移除广告", NO);
            } else {
                ab_showToast(@"❌ 当前页面未发现广告", NO);
            }
        }
    });
}

#pragma mark - Toast 通知

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

        // 临时添加到悬浮窗（不影响 hitTest）
        [_floatingWindow.rootViewController.view addSubview:label];

        label.alpha = 0;
        label.transform = CGAffineTransformMakeTranslation(0, 20);

        [UIView animateWithDuration:0.3
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            label.alpha = 1;
            label.transform = CGAffineTransformIdentity;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.3
                                  delay:2.0
                                options:UIViewAnimationOptionCurveEaseIn
                             animations:^{
                label.alpha = 0;
                label.transform = CGAffineTransformMakeTranslation(0, -20);
            } completion:^(BOOL finished) {
                [label removeFromSuperview];
            }];
        }];
    });
}

#pragma mark - UIWindow Hooks

// 保存原始 IMP
static void (*_orig_sendTouchesForEvent)(id, SEL, NSSet *, UIEvent *) = NULL;
static void (*_orig_setWindowLevel)(id, SEL, CGFloat) = NULL;
static void (*_orig_setHidden)(id, SEL, BOOL) = NULL;
static void (*_orig_makeKeyAndVisible)(id, SEL) = NULL;
static void (*_orig_UIWindow_init)(id, SEL) = NULL;

// Hook: _sendTouchesForEvent: (学习模式核心捕获点)
static void _hooked_sendTouchesForEvent(UIWindow *self, SEL _cmd, NSSet *touches, UIEvent *event) {
    // 先调用原始实现
    if (_orig_sendTouchesForEvent) {
        _orig_sendTouchesForEvent(self, _cmd, touches, event);
    }

    // 学习模式捕获
    @try {
        if (_isLearning) {
            for (UITouch *touch in touches) {
                if (touch.window == _floatingWindow) continue;
                _ab_handleLearningCapture(touch, event);
                break; // 只处理第一个 touch
            }
        }
    } @catch (NSException *e) {
        ABWarn(@"学习捕获异常: %@", e);
    }
}

// Hook: setWindowLevel: (防止广告窗口盖过悬浮窗)
static BOOL _isInWindowLevelHook = NO; // 递归保护

static void _hooked_setWindowLevel(UIWindow *self, SEL _cmd, CGFloat level) {
    if (_isInWindowLevelHook) {
        if (_orig_setWindowLevel) _orig_setWindowLevel(self, _cmd, level);
        return;
    }

    _isInWindowLevelHook = YES;

    // 限制其他窗口的层级
    if (self != _floatingWindow && level > kMaxOtherWindowLevel) {
        ABDebug(@"限制窗口 %@ 层级: %.0f → %.0f", NSStringFromClass([self class]), level, kMaxOtherWindowLevel);
        level = kMaxOtherWindowLevel;
    }

    if (_orig_setWindowLevel) {
        _orig_setWindowLevel(self, _cmd, level);
    }

    // 确保悬浮窗在最上面（但要避免递归）
    if (self != _floatingWindow && !_isLearning) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ab_ensureFloatingOnTop();
        });
    }

    _isInWindowLevelHook = NO;
}

// Hook: setHidden: (防止悬浮窗被隐藏)
static void _hooked_setHidden(UIWindow *self, SEL _cmd, BOOL hidden) {
    if (self == _floatingWindow && hidden) {
        ABDebug(@"阻止隐藏悬浮窗");
        return;
    }
    if (_orig_setHidden) {
        _orig_setHidden(self, _cmd, hidden);
    }
}

// Hook: makeKeyAndVisible (新窗口出现时确保悬浮窗在顶部)
static void _hooked_makeKeyAndVisible(UIWindow *self, SEL _cmd) {
    if (_orig_makeKeyAndVisible) {
        _orig_makeKeyAndVisible(self, _cmd);
    }
    if (self != _floatingWindow && !_isLearning) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ab_ensureFloatingOnTop();
        });
    }
}

#pragma mark - Method Swizzling 工具

static BOOL _ab_swizzleMethod(Class cls, SEL origSel, SEL newSel) {
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method newMethod = class_getInstanceMethod(cls, newSel);
    if (!origMethod || !newMethod) return NO;

    BOOL didAdd = class_addMethod(cls, origSel,
                                   method_getImplementation(newMethod),
                                   method_getTypeEncoding(newMethod));
    if (didAdd) {
        class_replaceMethod(cls, newSel,
                           method_getImplementation(origMethod),
                           method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, newMethod);
    }
    return YES;
}

#pragma mark - 初始化入口

__attribute__((constructor))
static void _adblock_init(void) {
    // 延迟到 UIApplication 就绪后再初始化
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 安装 SDK hooks
        _ab_hookKnownSDKs();

        // 监听 App 生命周期
        [[NSNotificationCenter defaultCenter]
         addObserverForName:UIApplicationDidFinishLaunchingNotification
         object:nil queue:[NSOperationQueue mainQueue]
         usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                _ab_installUIWindowHooks();
                ab_createFloatingWindow();

                // 延迟 Toast
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    ab_showToast(@"✅ AdBlock v2.0 已加载", YES);
                });
            });
        }];

        // 如果 App 已经在前台（注入到已运行的进程），直接初始化
        [[NSNotificationCenter defaultCenter]
         addObserverForName:UIApplicationDidBecomeActiveNotification
         object:nil queue:[NSOperationQueue mainQueue]
         usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!_isInitialized) {
                    _isInitialized = YES;
                    _ab_installUIWindowHooks();
                    ab_createFloatingWindow();
                    ab_showToast(@"✅ AdBlock v2.0 已加载", YES);
                } else {
                    // 每次回到前台，扫描并自动跳过
                    ab_scanAndAutoSkip();
                }
            });
        }];

        // 清理
        [[NSNotificationCenter defaultCenter]
         addObserverForName:UIApplicationWillTerminateNotification
         object:nil queue:[NSOperationQueue mainQueue]
         usingBlock:^(NSNotification *note) {
            [[NSNotificationCenter defaultCenter] removeObserver:nil];
            pthread_mutex_destroy(&_stateLock);
        }];
    });
}

static void _ab_installUIWindowHooks(void) {
    static BOOL hooksInstalled = NO;
    if (hooksInstalled) return;
    hooksInstalled = YES;

    Class winClass = [UIWindow class];

    // 1. Hook _sendTouchesForEvent: (学习模式核心)
    SEL sendSel = NSSelectorFromString(@"_sendTouchesForEvent:");
    Method sendMethod = class_getInstanceMethod(winClass, sendSel);
    if (sendMethod) {
        IMP newImp = imp_implementationWithBlock(^(UIWindow *self, NSSet *touches, UIEvent *event) {
            _hooked_sendTouchesForEvent(self, sendSel, touches, event);
        });
        _orig_sendTouchesForEvent = (void(*)(id,SEL,NSSet*,UIEvent*))method_setImplementation(sendMethod, newImp);
        ABLog(@"✅ Hook: _sendTouchesForEvent:");
    } else {
        ABWarn(@"❌ 无法获取 _sendTouchesForEvent:");
    }

    // 2. Hook setWindowLevel:
    Method levelMethod = class_getInstanceMethod(winClass, @selector(setWindowLevel:));
    if (levelMethod) {
        IMP newImp = imp_implementationWithBlock(^(UIWindow *self, CGFloat level) {
            _hooked_setWindowLevel(self, @selector(setWindowLevel:), level);
        });
        _orig_setWindowLevel = (void(*)(id,SEL,CGFloat))method_setImplementation(levelMethod, newImp);
        ABLog(@"✅ Hook: setWindowLevel:");
    }

    // 3. Hook setHidden:
    Method hiddenMethod = class_getInstanceMethod(winClass, @selector(setHidden:));
    if (hiddenMethod) {
        IMP newImp = imp_implementationWithBlock(^(UIWindow *self, BOOL hidden) {
            _hooked_setHidden(self, @selector(setHidden:), hidden);
        });
        _orig_setHidden = (void(*)(id,SEL,BOOL))method_setImplementation(hiddenMethod, newImp);
        ABLog(@"✅ Hook: setHidden:");
    }

    // 4. Hook makeKeyAndVisible
    Method visibleMethod = class_getInstanceMethod(winClass, @selector(makeKeyAndVisible));
    if (visibleMethod) {
        IMP newImp = imp_implementationWithBlock(^(UIWindow *self) {
            _hooked_makeKeyAndVisible(self, @selector(makeKeyAndVisible));
        });
        _orig_makeKeyAndVisible = (void(*)(id,SEL))method_setImplementation(visibleMethod, newImp);
        ABLog(@"✅ Hook: makeKeyAndVisible");
    }

    ABLog(@"所有 UIWindow Hook 安装完成");
}
