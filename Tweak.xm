#import <UIKit/UIKit.h>

// ==========================================
// 全局变量
// ==========================================
static UIView *g_overlayView = nil;
static UILabel *g_statusLabel = nil;
static NSArray *kSkipKeywords = nil;
static int g_scanCount = 0;
static BOOL g_hasClicked = NO; // 防止重复点击

// ==========================================
// 第一步：确保 UI 在任何页面（包括广告页）绝对置顶
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
            if (g_overlayView) [g_overlayView removeFromSuperview];
            
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
// 第三步：安全模拟点击（三重保险策略）
// ==========================================
static void safeTriggerClick(UIView *targetView) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 策略 1：如果是标准按钮/控件，直接发送原生点击事件（最安全、最标准）
            if ([targetView isKindOfClass:[UIControl class]]) {
                [(UIControl *)targetView sendActionsForControlEvents:UIControlEventTouchDown];
                [(UIControl *)targetView sendActionsForControlEvents:UIControlEventTouchUpInside];
                return;
            }
            
            // 策略 2：调用 iOS 无障碍激活（针对很多自定义 View 的跳过按钮极其有效）
            if ([targetView respondsToSelector:@selector(accessibilityActivate)]) {
                if ([targetView accessibilityActivate]) return;
            }
            
            // 策略 3：KVC 状态机欺骗法（安全触发手势，无 ARC 报错，无闪退风险）
            for (UIGestureRecognizer *gesture in targetView.gestureRecognizers) {
                if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
                    [gesture setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                    return;
                }
            }
            
        } @catch (NSException *exception) {
            NSLog(@"[AdBlocker] ⚠️ 触发点击时捕获异常: %@", exception);
        }
    });
}

// ==========================================
// 第二步：深度雷达扫描 + 触发点击
// ==========================================
static BOOL scanAndDetect(UIView *view) {
    if (!view || view.isHidden || view.alpha < 0.1) return NO;
    if (view == g_overlayView) return NO;

    NSString *textToCheck = nil;

    if ([view isKindOfClass:[UILabel class]]) {
        textToCheck = ((UILabel *)view).text;
    } 
    else if ([view isKindOfClass:[UIButton class]]) {
        textToCheck = [(UIButton *)view currentTitle];
        if (!textToCheck) textToCheck = [(UIButton *)view titleLabel].text;
    }
    if (!textToCheck && view.isAccessibilityElement) {
        textToCheck = view.accessibilityLabel;
    }

    if (textToCheck.length > 0 && textToCheck.length < 20) {
        for (NSString *keyword in kSkipKeywords) {
            if ([textToCheck containsString:keyword]) {
                CGRect frameInWindow = [view convertRect:view.bounds toView:nil];
                NSString *msg = [NSString stringWithFormat:@"🎯 发现目标！\n文字: \"%@\"\n类名: %@\n✅ 已执行安全跳过点击", 
                                 textToCheck, NSStringFromClass([view class])];
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (g_statusLabel) {
                        g_statusLabel.text = msg;
                        g_statusLabel.textColor = [UIColor greenColor];
                    }
                });
                
                // 🔥 触发安全点击
                safeTriggerClick(view);
                return YES;
            }
        }
    }

    for (NSInteger i = view.subviews.count - 1; i >= 0; i--) {
        if (scanAndDetect(view.subviews[i])) return YES;
    }
    
    return NO;
}

// ==========================================
// 定时器核心逻辑
// ==========================================
static void radarTick() {
    g_scanCount++;
    if (g_scanCount > 100 || g_hasClicked) { 
        return; 
    }

    ensureOverlayOnTop();

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *scanWindow = g_overlayView.window;
        if (scanWindow) {
            BOOL found = scanAndDetect(scanWindow);
            if (found) {
                g_hasClicked = YES; // 标记已点击，停止扫描
            } else if (g_statusLabel) {
                g_statusLabel.text = [NSString stringWithFormat:@"🔍 雷达扫描中... (%d/100)\n暂未发现跳过按钮", g_scanCount];
                g_statusLabel.textColor = [UIColor yellowColor];
            }
        }
    });
}

// ==========================================
// 插件入口
// ==========================================
%ctor {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSArray *blacklist = @[@"com.apple.springboard", @"com.apple.Preferences", @"com.apple.mobilesafari"];
    if (!bundleID || [blacklist containsObject:bundleID]) return;

    NSLog(@"[AdBlocker] 🚀 最终完整版：广告拦截器已启动: %@", bundleID);

    kSkipKeywords = @[@"跳过", @"关闭", @"Skip", @"skip", @"s", @"S", @"秒"];

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (g_scanCount > 100 || g_hasClicked) {
                [timer invalidate];
                return;
            }
            radarTick();
        }];
    });
}
