// Tweak.xm - 必须在最顶部导入这两个头文件
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
// ==========================================
// 🎯 增强版：多SDK兼容 + 自动监听 + 四层触发
// ==========================================

// 已知广告SDK跳过按钮类名白名单（不区分大小写匹配）
static NSArray<NSString *> *kSkipButtonClassNames = nil;
static dispatch_once_t kSkipButtonOnceToken;

static BOOL isKnownSkipButton(UIView *view) {
    dispatch_once(&kSkipButtonOnceToken, ^{
        kSkipButtonClassNames = @[
            // 腾讯广点通 GDT
            @"GDTDLLabel", @"GDTSkipButton", @"GDTMediaView",
            // 穿山甲 CSJ / Pangle
            @"CSJSkipButton", @"TTAdSkipButton", @"BUAdSkipButton", @"BUSkipButton",
            // 快手 KS
            @"KSSkipButton", @"KSAdSkipButton",
            // Unity Ads
            @"UnityAdsSkipButton", @"UADSSkipButton",
            // 通用兜底
            @"SkipButton", @"CloseButton", @"AdSkipView"
        ];
    });
    
    NSString *className = NSStringFromClass([view class]);
    for (NSString *knownName in kSkipButtonClassNames) {
        if ([className rangeOfString:knownName options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static void forceTriggerSkip(UIView *skipView) {
    if (!skipView || ![skipView isKindOfClass:[UIView class]]) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSString *className = NSStringFromClass([skipView class]);
            NSLog(@"[AdBlocker] 🚀 开始强制跳过: %@", className);
            
            // ✅ 1. UIControl 事件模拟
            if ([skipView isKindOfClass:[UIControl class]]) {
                [(UIControl *)skipView sendActionsForControlEvents:UIControlEventTouchDown];
                [(UIControl *)skipView sendActionsForControlEvents:UIControlEventTouchUpInside];
                NSLog(@"[AdBlocker] ✅ 触发自身 UIControl");
                return;
            }
            
            // ✅ 2. 无障碍激活
            if ([skipView respondsToSelector:@selector(accessibilityActivate)]) {
                BOOL result = [skipView accessibilityActivate];
                NSLog(@"[AdBlocker] ✅ accessibilityActivate 结果: %d", result);
                if (result) return;
            }
            
            // ✅ 3. 向上遍历父视图寻找手势/UIControl
            UIView *targetView = skipView;
            int maxDepth = 5;
            while (targetView && maxDepth-- > 0) {
                // 检查手势识别器
                for (UIGestureRecognizer *gesture in targetView.gestureRecognizers) {
                    if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
                        [gesture setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                        NSLog(@"[AdBlocker] ✅ 成功触发手势: %@ on %@",
                              NSStringFromClass([gesture class]),
                              NSStringFromClass([targetView class]));
                        return;
                    }
                }
                
                // 检查父级 UIControl
                if ([targetView isKindOfClass:[UIControl class]] && targetView != skipView) {
                    [(UIControl *)targetView sendActionsForControlEvents:UIControlEventTouchUpInside];
                    NSLog(@"[AdBlocker] ✅ 成功触发父级 UIControl: %@",
                          NSStringFromClass([targetView class]));
                    return;
                }
                
                targetView = targetView.superview;
            }
            
            // ✅ 4. hitTest 坐标硬探（终极兜底）
            CGRect rectInWindow = [skipView convertRect:skipView.bounds toView:nil];
            CGPoint centerPoint = CGPointMake(CGRectGetMidX(rectInWindow), CGRectGetMidY(rectInWindow));
            
            UIWindow *keyWindow = skipView.window;
            if (!keyWindow) {
                // iOS 13+ 多窗口兼容
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]]) {
                        keyWindow = ((UIWindowScene *)scene).windows.firstObject;
                        if (keyWindow) break;
                    }
                }
            }
            
            if (keyWindow) {
                UIView *realHitView = [keyWindow hitTest:centerPoint withEvent:nil];
                if (realHitView && realHitView != keyWindow && realHitView != skipView) {
                    NSLog(@"[AdBlocker] 🎯 hitTest 命中真实视图: %@",
                          NSStringFromClass([realHitView class]));
                    
                    if ([realHitView isKindOfClass:[UIControl class]]) {
                        [(UIControl *)realHitView sendActionsForControlEvents:UIControlEventTouchUpInside];
                    } else {
                        for (UIGestureRecognizer *g in realHitView.gestureRecognizers) {
                            if ([g isKindOfClass:[UITapGestureRecognizer class]]) {
                                [g setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                                NSLog(@"[AdBlocker] ✅ hitTest 触发了手势: %@", NSStringFromClass([g class]));
                                break;
                            }
                        }
                    }
                    return;
                }
            }
            
            NSLog(@"[AdBlocker] ⚠️ 所有触发方式均未成功: %@", className);
            
        } @catch (NSException *e) {
            NSLog(@"[AdBlocker] ❌ 跳过异常: %@", e);
        }
    });
}

// ==========================================
// 🔗 Hook 入口：自动监听广告跳过按钮出现
// ==========================================
%hook UIView

- (void)didMoveToWindow {
    %orig;
    
    // 仅当视图被添加到窗口时检查
    if (self.window && isKnownSkipButton(self)) {
        // 延迟一帧确保布局完成
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            forceTriggerSkip(self);
        });
    }
}

%end
