// ==========================================
// Tweak.xm - GDT跳过雷达 (安全诊断版)
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
// 🔬 安全诊断（零调用，仅读取）
// ==========================================
static void safeDiagnoseGDT(UIView *skipView) {
    if (!skipView) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            writeDiagLog(@"====== 安全诊断开始（无方法调用） ======");
            
            // 1. 收集所有 GDT/Splash 相关对象
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
            
            // 2. 仅枚举并记录方法签名（不调用！）
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
                
                // 3. 仅记录 delegate 信息（不调用！）
                if ([obj respondsToSelector:@selector(delegate)]) {
                    @try {
                        id delegate = [obj performSelector:@selector(delegate)];
                        if (delegate) {
                            NSString *delCls = NSStringFromClass([delegate class]);
                            writeDiagLog([NSString stringWithFormat:@"%@.delegate = %@", objCls, delCls]);
                            
                            // 仅检查 delegate 是否实现关键方法（不执行）
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
            
            // 4. 仅发送最安全的跳过通知（不带 object/userInfo，避免触发校验）
            writeDiagLog(@"--- 发送安全通知 ---");
            NSArray *safeNotifications = @[
                @"GDTSplashAdDidCloseNotification",
                @"kGDTSplashAdSkipNotify"
            ];
            for (NSString *notifName in safeNotifications) {
                @try {
                    [[NSNotificationCenter defaultCenter] postNotificationName:notifName object:nil userInfo:nil];
                    writeDiagLog([NSString stringWithFormat:@"📢 已发送: %@", notifName]);
                } @catch (NSException *e) {
                    writeDiagLog([NSString stringWithFormat:@"❌ 通知异常: %@", e.reason]);
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
            g_statusLabel.text = @"🔍 安全诊断模式\n正在收集GDT信息...";
            
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
                        g_statusLabel.text = [NSString stringWithFormat:@"🎯 已锁定 \"%@\"\n安全诊断中...", textToCheck];
                        g_statusLabel.textColor = [UIColor orangeColor];
                    }
                });
                
                safeDiagnoseGDT(view);
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        g_statusLabel.text = [NSString stringWithFormat:@"✅ 诊断完成\n请查看日志\n文字: \"%@\"", textToCheck];
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
            g_statusLabel.text = @"🔍 安全诊断模式已重启";
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
    writeDiagLog([NSString stringWithFormat:@"🚀 GDT安全诊断版已启动: %@", bundleID]);

    kSkipKeywords = @[@"跳过", @"关闭", @"Skip", @"skip", @"s", @"S", @"秒"];

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (g_scanCount > 100 && !g_hasSkipped) { [timer invalidate]; return; }
            radarTick();
        }];
    });
}
