// ==========================================
// Tweak.xm - 通用广告跳过雷达 (GDT终极修复版)
// ==========================================
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 全局变量
// ==========================================
static UIView *g_overlayView = nil;
static UILabel *g_statusLabel = nil;
static NSArray *kSkipKeywords = nil;
static int g_scanCount = 0;
static BOOL g_hasSkipped = NO;

// ==========================================
// 📁 日志工具（保留用于验证）
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
// 🎯 GDT 专属触发引擎
// ==========================================
static void triggerGDTSkip(UIView *skipView) {
    if (!skipView) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            CGRect frame = [skipView convertRect:skipView.bounds toView:nil];
            CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
            
            writeDiagLog(@"====== GDT专属触发开始 ======");
            writeDiagLog([NSString stringWithFormat:@"目标坐标: (%.0f,%.0f)", center.x, center.y]);
            
            // 1. 找到 GDTSystemGestureRecognizer
            UIGestureRecognizer *gdtGesture = nil;
            UIView *gestureHost = nil;
            UIView *searchView = skipView;
            int depth = 0;
            
            while (searchView && depth <= 10) {
                for (UIGestureRecognizer *g in searchView.gestureRecognizers) {
                    if ([NSStringFromClass([g class]) containsString:@"GDT"]) {
                        gdtGesture = g;
                        gestureHost = searchView;
                        break;
                    }
                }
                if (gdtGesture) break;
                searchView = searchView.superview;
                depth++;
            }
            
            if (!gdtGesture) {
                writeDiagLog(@"❌ 未找到GDT手势");
                return;
            }
            
            writeDiagLog([NSString stringWithFormat:@"✅ 找到手势: %@ on %@", 
                          NSStringFromClass([gdtGesture class]), NSStringFromClass([gestureHost class])]);
            
            // 2. ⭐ 核心修复：设置 beginTouchPoint 为真实点击坐标
            SEL setBeginTouchPointSel = @selector(setBeginTouchPoint:);
            if ([gdtGesture respondsToSelector:setBeginTouchPointSel]) {
                ((void(*)(id,SEL,CGPoint))objc_msgSend)(gdtGesture, setBeginTouchPointSel, center);
                writeDiagLog(@"✅ 已设置 beginTouchPoint");
            } else {
                writeDiagLog(@"⚠️ setBeginTouchPoint: 不可用");
            }
            
            // 3. 注入带正确坐标的触摸事件
            UITouch *fakeTouch = [[UITouch alloc] init];
            // 通过 KVC 设置 touch 的 window 和 view，确保 location 返回正确值
            [fakeTouch setValue:skipView.window forKey:@"_window"];
            [fakeTouch setValue:skipView forKey:@"_view"];
            [fakeTouch setValue:@(center) forKey:@"_locationInWindow"];
            
            NSSet *touches = [NSSet setWithObject:fakeTouch];
            UIEvent *event = [[UIEvent alloc] init];
            
            SEL beganSel = @selector(touchesBegan:withEvent:);
            SEL endedSel = @selector(touchesEnded:withEvent:);
            
            if ([gdtGesture respondsToSelector:beganSel]) {
                ((void(*)(id,SEL,id,id))objc_msgSend)(gdtGesture, beganSel, touches, event);
                writeDiagLog(@"✅ touchesBegan 已注入");
            }
            
            usleep(30000); // 30ms 模拟真实触摸间隔
            
            if ([gdtGesture respondsToSelector:endedSel]) {
                ((void(*)(id,SEL,id,id))objc_msgSend)(gdtGesture, endedSel, touches, event);
                writeDiagLog(@"✅ touchesEnded 已注入");
            }
            
            // 4. 备用：对 GDTSplashDLView 发送点击（部分版本跳过逻辑在此）
            UIView *splashView = gestureHost;
            while (splashView && ![NSStringFromClass([splashView class]) containsString:@"Splash"]) {
                splashView = splashView.superview;
            }
            if (splashView) {
                writeDiagLog([NSString stringWithFormat:@"🔄 找到SplashView: %@", NSStringFromClass([splashView class])]);
                // 尝试调用常见的跳过方法
                NSArray *possibleSelectors = @[@"onSkipClick", @"skipButtonClicked", @"handleSkipTap:", @"splashDidClick"];
                for (NSString *selName in possibleSelectors) {
                    SEL sel = NSSelectorFromString(selName);
                    if ([splashView respondsToSelector:sel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [splashView performSelector:sel withObject:nil];
                        #pragma clang diagnostic pop
                        writeDiagLog([NSString stringWithFormat:@"✅ SplashView.%@ 已调用", selName]);
                        break;
                    }
                }
            }
            
            writeDiagLog(@"====== GDT专属触发结束 ======\n");
            
        } @catch (NSException *e) {
            writeDiagLog([NSString stringWithFormat:@"❌ 触发异常: %@", e]);
        }
    });
}

// ==========================================
// UI 置顶保障（同前，略作精简）
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
                        g_statusLabel.text = [NSString stringWithFormat:@"🎯 已锁定目标\n文字: \"%@\"\n正在触发...", textToCheck];
                        g_statusLabel.textColor = [UIColor orangeColor];
                    }
                });
                
                triggerGDTSkip(view);
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        g_statusLabel.text = [NSString stringWithFormat:@"✅ 已尝试跳过！\n文字: \"%@\"", textToCheck];
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
                g_statusLabel.text = @"⏱️ 扫描超时\n未发现可跳过的广告";
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
                g_statusLabel.text = [NSString stringWithFormat:@"🔍 雷达扫描中... (%d/100)", g_scanCount];
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
            g_statusLabel.text = @"🔍 雷达已重启...\n正在扫描广告按钮";
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
    writeDiagLog([NSString stringWithFormat:@"🚀 GDT终极修复版已启动: %@", bundleID]);

    kSkipKeywords = @[@"跳过", @"关闭", @"Skip", @"skip", @"s", @"S", @"秒"];

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (g_scanCount > 100 && !g_hasSkipped) { [timer invalidate]; return; }
            radarTick();
        }];
    });
}
