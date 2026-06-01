#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==========================================
// 1. 广点通 (GDT) 专属修复：直接干掉控制器
// ==========================================

// 拦截 GDT 的开屏控制器，一旦显示立刻无动画关闭
%hook GDTSplashViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSLog(@"[AdBlock] Force dismissing GDTSplashViewController");
    // 直接 dismiss 掉这个挡住点击的全屏控制器
    [self dismissViewControllerAnimated:NO completion:nil];
}
%end

// 拦截 GDT 广告展示方法（从源头掐断）
%hook GDTSplashAd
- (void)showAdInWindow:(UIWindow *)window withBottomView:(UIView *)bottomView skipView:(UIView *)skipView {
    NSLog(@"[AdBlock] Intercepted GDTSplashAd showAdInWindow");
    // 不调用 %orig，直接返回
}
%end

// 移除 GDT 视图（兜底）
%hook GDTSplashDLView
- (void)didMoveToSuperview {
    %orig;
    NSLog(@"[AdBlock] Blocked GDTSplashDLView");
    [(UIView *)self removeFromSuperview];
}
%end

// ==========================================
// 2. 穿山甲 (CSJ/BU) 专属修复：自动点击跳过
// ==========================================

// 拦截穿山甲开屏视图
%hook CSJSplashView
- (void)didMoveToWindow {
    %orig;
    NSLog(@"[AdBlock] CSJSplashView didMoveToWindow, trying to auto-skip");
    
    // 延迟 0.1 秒确保子视图（跳过按钮）已经加载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 遍历子视图寻找 "CSJSkipButton" 或包含 "跳过" 的按钮
        for (UIView *subview in self.subviews) {
            if ([NSStringFromClass([subview class]) containsString:@"SkipButton"] || 
                [subview isKindOfClass:[UIButton class]]) {
                UIButton *btn = (UIButton *)subview;
                // 模拟点击跳过按钮
                [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                NSLog(@"[AdBlock] Auto-clicked CSJ Skip Button");
                break;
            }
        }
    });
}

// 拦截倒计时，直接设为0
- (void)setCountdownTime:(CGFloat)time {
    %orig(0);
}
%end

// 移除穿山甲视频广告视图（兜底）
%hook CSJNativeExpressSplashVideoAdView
- (void)didMoveToSuperview {
    %orig;
    NSLog(@"[AdBlock] Blocked CSJNativeExpressSplashVideoAdView");
    [(UIView *)self removeFromSuperview];
}
%end

// 拦截穿山甲展示方法（从源头掐断）
%hook BUSplashAd
- (void)showInWindow:(UIWindow *)window {
    NSLog(@"[AdBlock] Intercepted BUSplashAd showInWindow");
}
%end

// ==========================================
// 3. 通用防御：清理残留的透明遮罩 Window
// ==========================================

// 如果 SDK 创建了一个新的全屏 Window 来放广告，我们把它隐藏
%hook UIWindow
- (void)makeKeyAndVisible {
    // 检查 window 的 rootViewController 是否是广告相关
    NSString *rootVCClass = NSStringFromClass([self.rootViewController class]);
    if ([rootVCClass containsString:@"Splash"] || 
        [rootVCClass containsString:@"Ad"] ||
        [rootVCClass containsString:@"GDT"] ||
        [rootVCClass containsString:@"CSJ"]) {
        NSLog(@"[AdBlock] Blocked suspicious UIWindow: %@", rootVCClass);
        self.hidden = YES;
        return;
    }
    %orig;
}
%end
