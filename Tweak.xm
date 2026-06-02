#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==========================================
// 全局变量
// ==========================================
static UIView *g_overlayView = nil;
static UILabel *g_statusLabel = nil;
static NSArray *kSkipKeywords = nil;
static int g_scanCount = 0;
static BOOL g_hasClicked = NO;

// ==========================================
// UI 置顶 (保持不变)
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
// 🎯 核心修复：针对 CSJSkipButton 等隐藏按钮的强制点击
// ==========================================
static void forceTriggerSkip(UIView *skipButton) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 1. 优先尝试直接点击自身（万一它其实能响应）
            if ([skipButton isKindOfClass:[UIControl class]]) {
                [(UIControl *)skipButton sendActionsForControlEvents:UIControlEventTouchDown];
                [(UIControl *)skipButton sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
            if ([skipButton respondsToSelector:@selector(accessibilityActivate)]) {
                [skipButton accessibilityActivate];
            }
            
            // 2. 【关键】向上遍历父视图，寻找真正绑定手势的容器 (如 CSJSplashView)
            UIView *targetView = skipButton.superview;
            while (targetView) {
                // 尝试触发父视图的手势
                for (UIGestureRecognizer *gesture in targetView.gestureRecognizers) {
                    if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
                        [gesture setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                        NSLog(@"[AdBlocker] ✅ 成功触发父视图手势: %@", NSStringFromClass([targetView class]));
                        return;
                    }
                }
                // 尝试触发父视图的 UIControl 事件
                if ([targetView isKindOfClass:[UIControl class]]) {
                    [(UIControl *)targetView sendActionsForControlEvents:UIControlEventTouchUpInside];
                    NSLog(@"[AdBlocker] ✅ 成功触发父视图 UIControl: %@", NSStringFromClass([targetView class]));
                    return;
                }
                targetView = targetView.superview;
            }
            
            // 3. 【终极兜底】如果以上全失效，直接在 skipButton 的中心坐标伪造触摸
            // 获取 skipButton 在 window 中的绝对坐标
            CGRect rectInWindow = [skipButton convertRect:skipButton.bounds toView:nil];
            CGPoint centerPoint = CGPointMake(CGRectGetMidX(rectInWindow), CGRectGetMidY(rectInWindow));
            
            // 找到该坐标下真正可见、可交互的最顶层视图
            UIWindow *keyWindow = skipButton.window;
            if (keyWindow) {
                UIView *realHitView = [keyWindow hitTest:centerPoint withEvent:nil];
                if (realHitView && realHitView != keyWindow) {
                    NSLog(@"[AdBlocker] 🎯 坐标命中真实视图: %@，执行点击", NSStringFromClass([realHitView class]));
                    if ([realHitView isKindOfClass:[UIControl class]]) {
                        [(UIControl *)realHitView sendActionsForControlEvents:UIControlEventTouchUpInside];
                    } else {
                        for (UIGestureRecognizer *g in realHitView.gestureRecognizers) {
                            if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
                                [g setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                                break;
                            }
                        }
                    }
                }
            }
            
        } @catch (NSException *exception) {
            NSLog(@"[AdBlocker] ⚠️ 强制点击异常: %@", exception);
        }
    });
}

// ==========================================
// 雷达扫描 (忽略 hidden 状态，精准匹配)
// ==========================================
static BOOL scanAndDetect(UIView *view) {
    // ⚠️ 注意：这里不再检查 view.isHidden，因为 CSJSkipButton 是隐藏的！
    if (!view || view.alpha < 0.01) return NO; 
    if (view == g_overlayView) return NO;

    NSString *textToCheck = nil;
    NSString *className = NSStringFromClass([view class]);

    // 提取文字
    if ([view isKindOfClass:[UILabel class]]) {
        textToCheck = ((UILabel *)view).text;
    } else if ([view isKindOfClass:[UIButton class]]) {
        textToCheck = [(UIButton *)view currentTitle];
        if (!textToCheck) textToCheck = [(UIButton *)view titleLabel].text;
    }
    if (!textToCheck && view.isAccessibilityElement) {
        textToCheck = view.accessibilityLabel;
    }

    BOOL isMatch = NO;
    
    // 匹配规则 1：类名直接命中穿山甲跳过按钮
    if ([className isEqualToString:@"CSJSkipButton"]) {
        isMatch = YES;
    }
    // 匹配规则 2：文字包含跳过关键词
    if (!isMatch && textToCheck.length > 0 && textToCheck.length < 20) {
        for (NSString *keyword in kSkipKeywords) {
            if ([textToCheck containsString:keyword]) {
                isMatch = YES;
                break;
            }
        }
    }

    if (isMatch) {
        NSString *msg = [NSString stringWithFormat:@"🎯 发现目标!\n类名: %@\n文字: \"%@\"\nHidden: %@\n✅ 已执行强制跳过", 
                         className, textToCheck ?: @"无", view.isHidden ? @"YES" : @"NO"];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_statusLabel) {
                g_statusLabel.text = msg;
                g_statusLabel.textColor = [UIColor greenColor];
            }
        });
        
        forceTriggerSkip(view);
        return YES;
    }

    // 递归扫描子视图
    for (NSInteger i = view.subviews.count - 1; i >= 0; i--) {
        if (scanAndDetect(view.subviews[i])) return YES;
    }
    return NO;
}

// ==========================================
// 定时器 & 入口
// ==========================================
static void radarTick() {
    g_scanCount++;
    if (g_scanCount > 100 || g_hasClicked) return;

    ensureOverlayOnTop();
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *scanWindow = g_overlayView.window;
        if (scanWindow) {
            BOOL found = scanAndDetect(scanWindow);
            if (found) {
                g_hasClicked = YES;
            } else if (g_statusLabel) {
                g_statusLabel.text = [NSString stringWithFormat:@"🔍 雷达扫描中... (%d/100)\n暂未发现跳过按钮", g_scanCount];
                g_statusLabel.textColor = [UIColor yellowColor];
            }
        }
    });
}

%ctor {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    NSArray *blacklist = @[@"com.apple.springboard", @"com.apple.Preferences", @"com.apple.mobilesafari"];
    if (!bundleID || [blacklist containsObject:bundleID]) return;

    NSLog(@"[AdBlocker] 🚀 穿山甲专杀版已启动: %@", bundleID);
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
