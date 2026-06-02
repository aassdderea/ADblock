// ==========================================
// Tweak.xm - GDT跳过雷达 (延长采集版)
// ==========================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static UIView *g_overlayView = nil;
static UILabel *g_statusLabel = nil;
static NSArray *kSkipKeywords = nil;
static int g_scanCount = 0;
static BOOL g_hasSkipped = NO;
static CFAbsoluteTime g_startTime = 0; // ⭐ 新增：记录启动时间

// ==========================================
// 📁 日志工具
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
    if (!message) return;
    @try {
        NSString *logPath = getDiagLogPath();
        // ⭐ 日志中增加相对时间戳，方便定位第4秒的操作
        CFAbsoluteTime relative = CFAbsoluteTimeGetCurrent() - g_startTime;
        NSString *entry = [NSString stringWithFormat:@"[+%.2fs] %@\n", relative, message];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        }
        [fh seekToEndOfFile];
        [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}

// ==========================================
// 🔬 安全诊断（零调用，仅读取）
// ==========================================
static void safeDiagnoseGDT(UIView *skipView) {
    if (!skipView) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            writeDiagLog(@"====== 安全诊断开始（无方法调用） ======");
            
            NSMutableArray *gdtObjects = [NSMutableArray array];
            UIView *v = skipView;
            while (v) {
                NSString *cls = NSStringFromClass([v class]);
                if ([cls containsString:@"GDT"] || [cls containsString:@"Splash"]) {
                    [gdtObjects addObject:v];
                }
                v = v.superview;
            }
            
            UIWindow *win = skipView.window;
            if (win) {
                for (UIView *sub in win.subviews) {
                    NSString *cls = NSStringFromClass([sub class]);
                    if (([cls containsString:@"GDT"] || [cls containsString:@"Splash"]) && ![gdtObjects containsObject:sub]) {
                        [gdtObjects addObject:sub];
                    }
                }
            }
            
            writeDiagLog([NSString stringWithFormat:@"找到 %lu 个GDT相关对象", (unsigned long)gdtObjects.count]);
            
            for (id obj in gdtObjects) {
                NSString *objCls = NSStringFromClass([obj class]);
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList([obj class], &methodCount);
                
                writeDiagLog([NSString stringWithFormat:@"--- %@ (%lu methods) ---", objCls, (unsigned long)methodCount]);
                
                for (unsigned int i = 0; i < methodCount; i++) {
                    SEL sel = method_getName(methods[i]);
                    NSString *selName = NSStringFromSelector(sel);
                    const char *typeEncoding = method_getTypeEncoding(methods[i]);
                    
                    NSString *lower = [selName lowercaseString];
                    BOOL isSkipRelated = [lower containsString:@"skip"] || 
                                        [lower containsString:@"close"] || 
                                        [lower containsString:@"click"] || 
                                        [lower containsString:@"tap"] ||
                                        [lower containsString:@"dismiss"] ||
                                        [lower containsString:@"handle"] ||
                                        [lower containsString:@"on"] ||
                                        [lower containsString:@"button"] ||
                                        [lower containsString:@"action"] ||
                                        [lower containsString:@"finish"] ||
                                        [lower containsString:@"complete"];
                    
                    if (isSkipRelated) {
                        writeDiagLog([NSString stringWithFormat:@"  🎯 %@ | type: %s", selName, typeEncoding ? typeEncoding : "unknown"]);
                    }
                }
                free(methods);
                
                if ([obj respondsToSelector:@selector(delegate)]) {
                    @try {
                        id delegate = [obj performSelector:@selector(delegate)];
                        if (delegate) {
                            NSString *delCls = NSStringFromClass([delegate class]);
                            writeDiagLog([NSString stringWithFormat:@"%@.delegate = %@", objCls, delCls]);
                            
                            NSArray *delSels = @[@"splashAdClosed:", @"splashAdDidClose:", @"splashAdSuccessPresentScreen:", 
                                                 @"unifiedNativeAdDidClose:", @"nativeAdDidClose:", @"splashAdExposured:"];
                            for (NSString *selName in delSels) {
                                if ([delegate respondsToSelector:NSSelectorFromString(selName)]) {
                                    writeDiagLog([NSString stringWithFormat:@"  ✅ delegate implements: %@", selName]);
                                }
                            }
                        }
                    } @catch (NSException *e) {
                        writeDiagLog([NSString stringWithFormat:@"⚠️ delegate读取异常: %@", e.reason]);
                    }
                }
            }
            
            writeDiagLog(@"====== 安全诊断结束 ======\n");
            
        } @catch (NSException *e) {
            writeDiagLog([NSString stringWithFormat:@"❌ 诊断异常: %@", e]);
        }
    });
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
// 深度雷达扫描
// ==========================================
static BOOL scanAndTrigger(UIView *view) {
    if (!view || view.isHidden || view.alpha < 0.1 || view == g_overlayView) return NO;

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
                // ⭐ 不再立即返回YES停止扫描，而是持续记录
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        CFAbsoluteTime relative = CFAbsoluteTimeGetCurrent() - g_startTime;
                        g_statusLabel.text = [NSString stringWithFormat:@"🎯 已锁定 \"%@\"\n采集窗口剩余 %.1fs", textToCheck, MAX(0, 6.0 - relative)];
                        g_statusLabel.textColor = [UIColor orangeColor];
                    }
                });
                
                safeDiagnoseGDT(view);
                // ⭐ 关键：这里不返回 YES，让扫描继续
            }
        }
    }

    for (NSInteger i = view.subviews.count - 1; i >= 0; i--) {
        scanAndTrigger(view.subviews[i]); // ⭐ 移除短路返回
    }
    return NO; // ⭐ 始终返回NO，保持雷达运转
}

// ==========================================
// 定时器 & 生命周期
// ==========================================
static void radarTick() {
    // ⭐ 改为基于时间的6秒窗口，而非次数
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - g_startTime;
    if (elapsed > 6.0) {
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
            scanAndTrigger(scanWindow);
            if (g_statusLabel && elapsed <= 6.0) {
                g_statusLabel.text = [NSString stringWithFormat:@"🔍 采集中... (+%.1fs/6.0s)", elapsed];
                g_statusLabel.textColor = [UIColor yellowColor];
            }
        }
    });
}

%hook UIApplication
- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    g_startTime = CFAbsoluteTimeGetCurrent(); // ⭐ 重置计时起点
    g_scanCount = 0;
    g_hasSkipped = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_statusLabel) {
            g_statusLabel.text = @"🔍 延长采集模式已重启\n请在6秒内手动点击跳过";
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

    g_startTime = CFAbsoluteTimeGetCurrent();
    [[NSFileManager defaultManager] removeItemAtPath:getDiagLogPath() error:nil];
    writeDiagLog([NSString stringWithFormat:@"🚀 GDT延长采集版已启动: %@", bundleID]);

    kSkipKeywords = @[@"跳过", @"关闭", @"Skip", @"skip", @"s", @"S", @"秒"];

    dispatch_async(dispatch_get_main_queue(), ^{
        // ⭐ 提高刷新率到50ms，确保捕捉瞬时操作
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer * _Nonnull timer) {
            CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - g_startTime;
            if (elapsed > 6.0) { [timer invalidate]; return; }
            radarTick();
        }];
    });
}
