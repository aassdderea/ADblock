// ==========================================
// Tweak.xm - GDT跳过雷达 (持续监听+异步日志版)
// ==========================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static UIView *g_overlayView = nil;
static UILabel *g_statusLabel = nil;
static NSArray *kSkipKeywords = nil;
static CFAbsoluteTime g_startTime = 0;
static BOOL g_collectionEnded = NO;

// ⭐ 异步日志队列，避免主线程阻塞
static dispatch_queue_t g_logQueue = nil;

// ==========================================
// 📁 异步日志工具
// ==========================================
static NSString *getDiagLogPath() {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        path = [paths.firstObject stringByAppendingPathComponent:@"adblock_diag.log"];
    });
    return path;
}

static void writeDiagLog(NSString *message) {
    if (!message || g_collectionEnded) return;
    NSString *msgCopy = [message copy];
    dispatch_async(g_logQueue, ^{
        @try {
            NSString *logPath = getDiagLogPath();
            CFAbsoluteTime relative = CFAbsoluteTimeGetCurrent() - g_startTime;
            NSString *entry = [NSString stringWithFormat:@"[+%.2fs] %@\n", relative, msgCopy];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
            if (!fh) {
                [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
                fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
            }
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    });
}

// ==========================================
// 🔬 轻量级持续诊断（可在主线程安全执行）
// ==========================================
static void lightweightDiagnose(UIView *skipView, NSString *triggerReason) {
    if (!skipView) return;
    
    writeDiagLog([NSString stringWithFormat:@"📍 诊断触发: %@", triggerReason]);
    
    // 仅记录视图层级和类名，不做 method enumeration
    NSMutableArray *info = [NSMutableArray array];
    UIView *v = skipView;
    int depth = 0;
    while (v && depth <= 15) {
        NSString *cls = NSStringFromClass([v class]);
        [info addObject:[NSString stringWithFormat:@"d%d:%@", depth, cls]];
        
        // 仅对 GDT/Splash 类记录手势和 delegate（轻量）
        if ([cls containsString:@"GDT"] || [cls containsString:@"Splash"]) {
            NSUInteger gestureCount = v.gestureRecognizers.count;
            [info addObject:[NSString stringWithFormat:@"  ↳ gestures:%lu", (unsigned long)gestureCount]];
            
            if ([v respondsToSelector:@selector(delegate)]) {
                @try {
                    id del = [v performSelector:@selector(delegate)];
                    [info addObject:[NSString stringWithFormat:@"  ↳ delegate:%@", del ? NSStringFromClass([del class]) : @"nil"]];
                } @catch (NSException *e) {
                    [info addObject:@"  ↳ delegate:EXCEPTION"];
                }
            }
        }
        v = v.superview;
        depth++;
    }
    
    writeDiagLog([info componentsJoinedByString:@"\n"]);
}

// ==========================================
// UI 置顶保障
// ==========================================
static void ensureOverlayOnTop() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *topWindow = nil;
        CGFloat maxLevel = -1;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (!w.isHidden && w.windowLevel > maxLevel) {
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
                if (!w.isHidden && w.windowLevel > maxLevel) {
                    maxLevel = w.windowLevel;
                    topWindow = w;
                }
            }
        }
#pragma clang diagnostic pop
        if (!topWindow) return;

        if (!g_overlayView || g_overlayView.window != topWindow) {
            [g_overlayView removeFromSuperview];
            g_overlayView = [[UIView alloc] initWithFrame:topWindow.bounds];
            g_overlayView.backgroundColor = [UIColor clearColor];
            g_overlayView.userInteractionEnabled = NO;
            g_overlayView.layer.zPosition = 999999;
            
            g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, topWindow.bounds.size.height - 150, topWindow.bounds.size.width - 40, 80)];
            g_statusLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
            g_statusLabel.textColor = [UIColor yellowColor];
            g_statusLabel.textAlignment = NSTextAlignmentCenter;
            g_statusLabel.font = [UIFont boldSystemFontOfSize:16];
            g_statusLabel.layer.cornerRadius = 10;
            g_statusLabel.clipsToBounds = YES;
            g_statusLabel.numberOfLines = 0;
            g_statusLabel.text = @"🔍 延长采集模式\n请等待广告出现...";
            
            [g_overlayView addSubview:g_statusLabel];
            [topWindow addSubview:g_overlayView];
        }
    });
}

// ==========================================
// 持续扫描（不再短路，每帧都记录状态）
// ==========================================
static void continuousScan(UIView *view) {
    if (!view || view.isHidden || view.alpha < 0.1 || view == g_overlayView) return;

    NSString *textToCheck = nil;
    if ([view isKindOfClass:[UILabel class]]) textToCheck = ((UILabel *)view).text;
    else if ([view isKindOfClass:[UIButton class]]) {
        textToCheck = [(UIButton *)view currentTitle];
        if (!textToCheck) textToCheck = [(UIButton *)view titleLabel].text;
    }
    if (!textToCheck && view.isAccessibilityElement) textToCheck = view.accessibilityLabel;

    if (textToCheck.length > 0 && textToCheck.length < 20) {
        for (NSString *keyword in kSkipKeywords) {
            if ([textToCheck containsString:keyword]) {
                CFAbsoluteTime relative = CFAbsoluteTimeGetCurrent() - g_startTime;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        g_statusLabel.text = [NSString stringWithFormat:@"🎯 \"%@\" 可见\n+%.1fs | 请手动点击跳过", textToCheck, relative];
                        g_statusLabel.textColor = [UIColor orangeColor];
                    }
                });
                // ⭐ 每次扫描到都记录，但限制频率避免刷屏
                static CFAbsoluteTime lastLogTime = 0;
                if (relative - lastLogTime > 0.5) {
                    lastLogTime = relative;
                    lightweightDiagnose(view, [NSString stringWithFormat:@"keyword='%@' visible", keyword]);
                }
                break;
            }
        }
    }

    for (NSInteger i = view.subviews.count - 1; i >= 0; i--) {
        continuousScan(view.subviews[i]);
    }
}

// ==========================================
// 定时器 & 生命周期
// ==========================================
static void radarTick() {
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - g_startTime;
    if (elapsed > 6.0) {
        g_collectionEnded = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_statusLabel) {
                g_statusLabel.text = @"✅ 6秒采集窗口已结束\n请导出日志";
                g_statusLabel.textColor = [UIColor greenColor];
            }
        });
        writeDiagLog(@"⏱️ 6秒采集窗口结束");
        return;
    }
    
    ensureOverlayOnTop();
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *scanWindow = g_overlayView.window;
        if (scanWindow) {
            continuousScan(scanWindow);
            if (g_statusLabel && elapsed <= 6.0) {
                // 仅在未锁定时更新倒计时
                if (![g_statusLabel.text containsString:@"🎯"]) {
                    g_statusLabel.text = [NSString stringWithFormat:@"🔍 采集中... (+%.1fs/6.0s)", elapsed];
                    g_statusLabel.textColor = [UIColor yellowColor];
                }
            }
        }
    });
    
    // ⭐ 每帧心跳日志，证明定时器存活
    static int heartbeatCounter = 0;
    if (++heartbeatCounter % 20 == 0) { // 约每秒1次
        writeDiagLog([NSString stringWithFormat:@"💓 heartbeat +%.2fs", elapsed]);
    }
}

%hook UIApplication
- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    g_startTime = CFAbsoluteTimeGetCurrent();
    g_collectionEnded = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_statusLabel) {
            g_statusLabel.text = @"🔍 采集已重启\n请在6秒内手动点击跳过";
            g_statusLabel.textColor = [UIColor yellowColor];
        }
    });
    writeDiagLog(@"🔄 采集窗口已重置 (6s)");
}
%end

%ctor {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSArray *blacklist = @[@"com.apple.springboard", @"com.apple.Preferences", @"com.apple.mobilesafari"];
    if (!bundleID || [blacklist containsObject:bundleID]) return;

    // ⭐ 初始化异步日志队列
    g_logQueue = dispatch_queue_create("com.adblock.diaglog", DISPATCH_QUEUE_SERIAL);
    
    g_startTime = CFAbsoluteTimeGetCurrent();
    [[NSFileManager defaultManager] removeItemAtPath:getDiagLogPath() error:nil];
    writeDiagLog([NSString stringWithFormat:@"🚀 GDT持续监听版已启动: %@", bundleID]);

    kSkipKeywords = @[@"跳过", @"关闭", @"Skip", @"skip", @"s", @"S", @"秒"];

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (g_collectionEnded) { [timer invalidate]; return; }
            radarTick();
        }];
    });
}
