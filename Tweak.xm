// ==========================================
// Tweak.xm - GDT跳过雷达 (方法级探测版)
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
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [[NSDate date] description], message];
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
// 🔬 GDT 方法级深度探测 + 触发
// ==========================================
static void probeAndTriggerGDT(UIView *skipView) {
    if (!skipView) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            writeDiagLog(@"====== GDT方法级探测开始 ======");
            
            // 1. 收集所有 GDT 相关对象实例
            NSMutableArray *gdtObjects = [NSMutableArray array];
            
            // 从 skipView 向上遍历收集
            UIView *v = skipView;
            while (v) {
                NSString *cls = NSStringFromClass([v class]);
                if ([cls containsString:@"GDT"] || [cls containsString:@"Splash"]) {
                    [gdtObjects addObject:v];
                }
                v = v.superview;
            }
            
            // 遍历当前 window 所有子视图补充收集
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
            
            // 2. 对每个 GDT 对象枚举所有实例方法，筛选跳过相关方法
            NSMutableSet *calledMethods = [NSMutableSet set];
            
            for (id obj in gdtObjects) {
                NSString *objCls = NSStringFromClass([obj class]);
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList([obj class], &methodCount);
                
                writeDiagLog([NSString stringWithFormat:@"--- %@ (%lu methods) ---", objCls, (unsigned long)methodCount]);
                
                for (unsigned int i = 0; i < methodCount; i++) {
                    SEL sel = method_getName(methods[i]);
                    NSString *selName = NSStringFromSelector(sel);
                    
                    // 筛选包含 skip/close/click/tap/dismiss/handle/on 的方法
                    NSString *lower = [selName lowercaseString];
                    BOOL isSkipRelated = [lower containsString:@"skip"] || 
                                        [lower containsString:@"close"] || 
                                        [lower containsString:@"click"] || 
                                        [lower containsString:@"tap"] ||
                                        [lower containsString:@"dismiss"] ||
                                        [lower containsString:@"handle"] ||
                                        [lower containsString:@"on"] ||
                                        [lower containsString:@"button"] ||
                                        [lower containsString:@"action"];
                    
                    if (isSkipRelated) {
                        writeDiagLog([NSString stringWithFormat:@"  🎯 %@", selName]);
                        
                        // 尝试调用（仅对无参或单参方法）
                        const char *typeEncoding = method_getTypeEncoding(methods[i]);
                        // typeEncoding[0] 是返回类型，[1]是@, [2]是:, 之后是参数
                        // 无额外参数时长度 <= 3 (@:@)
                        NSUInteger argCount = strlen(typeEncoding) > 3 ? 1 : 0;
                        
                        NSString *callKey = [NSString stringWithFormat:@"%@.%@", objCls, selName];
                        if (![calledMethods containsObject:callKey]) {
                            [calledMethods addObject:callKey];
                            @try {
                                if (argCount == 0) {
                                    #pragma clang diagnostic push
                                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                                    [obj performSelector:sel];
                                    #pragma clang diagnostic pop
                                } else {
                                    // 单参方法传入自身或nil
                                    #pragma clang diagnostic push
                                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                                    [obj performSelector:sel withObject:obj];
                                    #pragma clang diagnostic pop
                                }
                                writeDiagLog([NSString stringWithFormat:@"     ✅ 已调用 %@.%@", objCls, selName]);
                            } @catch (NSException *e) {
                                writeDiagLog([NSString stringWithFormat:@"     ❌ 调用异常: %@", e.reason]);
                            }
                        }
                    }
                }
                free(methods);
            }
            
            // 3. 检查 NotificationCenter 中是否有 GDT 相关的跳过通知
            writeDiagLog(@"--- 检查已知GDT通知 ---");
            NSArray *knownNotifications = @[
                @"GDTSplashAdDidCloseNotification",
                @"GDTSplashAdSkipNotification", 
                @"GDTSplashAdClickedNotification",
                @"GDTUnifiedBannerAdDidCloseNotification",
                @"kGDTSplashAdSkipNotify",
                @"kGDTSplashAdCloseNotify"
            ];
            
            for (NSString *notifName in knownNotifications) {
                @try {
                    [[NSNotificationCenter defaultCenter] postNotificationName:notifName object:nil];
                    writeDiagLog([NSString stringWithFormat:@"📢 已发送通知: %@", notifName]);
                } @catch (NSException *e) {
                    writeDiagLog([NSString stringWithFormat:@"❌ 通知异常: %@", e.reason]);
                }
            }
            
            // 4. 尝试通过 delegate 触发
            writeDiagLog(@"--- 检查delegate ---");
            for (id obj in gdtObjects) {
                if ([obj respondsToSelector:@selector(delegate)]) {
                    id delegate = [obj performSelector:@selector(delegate)];
                    if (delegate) {
                        NSString *delCls = NSStringFromClass([delegate class]);
                        writeDiagLog([NSString stringWithFormat:@"%@.delegate = %@", NSStringFromClass([obj class]), delCls]);
                        
                        // 检查 delegate 是否实现了 splashAdSuccessPresentScreen / splashAdClosed 等方法
                        NSArray *delSels = @[@"splashAdClosed:", @"splashAdDidClose:", @"splashAdSuccessPresentScreen:", 
                                             @"unifiedNativeAdDidClose:", @"nativeAdDidClose:"];
                        for (NSString *selName in delSels) {
                            SEL sel = NSSelectorFromString(selName);
                            if ([delegate respondsToSelector:sel]) {
                                @try {
                                    #pragma clang diagnostic push
                                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                                    [delegate performSelector:sel withObject:obj];
                                    #pragma clang diagnostic pop
                                    writeDiagLog([NSString stringWithFormat:@"✅ delegate.%@ 已调用", selName]);
                                } @catch (NSException *e) {
                                    writeDiagLog([NSString stringWithFormat:@"❌ delegate调用异常: %@", e.reason]);
                                }
                            }
                        }
                    }
                }
            }
            
            writeDiagLog(@"====== GDT方法级探测结束 ======\n");
            
        } @catch (NSException *e) {
            writeDiagLog([NSString stringWithFormat:@"❌ 探测异常: %@", e]);
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
            g_statusLabel.text = @"🔍 雷达已启动...\n正在扫描广告按钮";
            
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
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        g_statusLabel.text = [NSString stringWithFormat:@"🎯 已锁定 \"%@\"\n正在探测跳过方法...", textToCheck];
                        g_statusLabel.textColor = [UIColor orangeColor];
                    }
                });
                
                probeAndTriggerGDT(view);
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        g_statusLabel.text = [NSString stringWithFormat:@"✅ 探测完成\n文字: \"%@\"\n请查看日志", textToCheck];
                        g_statusLabel.textColor = [UIColor greenColor];
                    }
                });
                return YES;
            }
        }
    }

    for (NSInteger i = view.subviews.count - 1; i >= 0; i--) {
        if (scanAndTrigger(view.subviews[i])) return YES;
    }
    return NO;
}

// ==========================================
// 定时器 & 生命周期
// ==========================================
static void radarTick() {
    if (g_hasSkipped) return;
    g_scanCount++;
    if (g_scanCount > 100) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_statusLabel && !g_hasSkipped) {
                g_statusLabel.text = @"⏱️ 扫描超时";
                g_statusLabel.textColor = [UIColor grayColor];
            }
        });
        return;
    }
    ensureOverlayOnTop();
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *scanWindow = g_overlayView.window;
        if (scanWindow) {
            BOOL found = scanAndTrigger(scanWindow);
            if (found) g_hasSkipped = YES;
            else if (g_statusLabel && !g_hasSkipped) {
                g_statusLabel.text = [NSString stringWithFormat:@"🔍 扫描中... (%d/100)", g_scanCount];
                g_statusLabel.textColor = [UIColor yellowColor];
            }
        }
    });
}

%hook UIApplication
- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    g_scanCount = 0;
    g_hasSkipped = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_statusLabel) {
            g_statusLabel.text = @"🔍 雷达已重启...";
            g_statusLabel.textColor = [UIColor yellowColor];
        }
    });
    writeDiagLog(@"🔄 扫描状态已重置");
}
%end

%ctor {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSArray *blacklist = @[@"com.apple.springboard", @"com.apple.Preferences", @"com.apple.mobilesafari"];
    if (!bundleID || [blacklist containsObject:bundleID]) return;

    [[NSFileManager defaultManager] removeItemAtPath:getDiagLogPath() error:nil];
    writeDiagLog([NSString stringWithFormat:@"🚀 GDT方法级探测版已启动: %@", bundleID]);

    kSkipKeywords = @[@"跳过", @"关闭", @"Skip", @"skip", @"s", @"S", @"秒"];

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (g_scanCount > 100 && !g_hasSkipped) { [timer invalidate]; return; }
            radarTick();
        }];
    });
}
