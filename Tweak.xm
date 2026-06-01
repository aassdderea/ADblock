#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==========================================
// 方案一：直接隐藏/移除开屏广告视图（最稳妥）
// ==========================================

%hook CSJNativeExpressSplashVideoAdView
- (void)didMoveToSuperview {
    NSLog(@"[AdBlock] Blocked CSJ Splash Video Ad");
    // 关键修复：将 self 强转为 UIView* 以调用 removeFromSuperview
    [(UIView *)self removeFromSuperview];
}
%end

%hook GDTSplashDLView
- (void)didMoveToSuperview {
    NSLog(@"[AdBlock] Blocked GDT Splash DL Ad");
    [(UIView *)self removeFromSuperview];
}
%end

// ==========================================
// 方案二：从源头拦截广告展示方法
// ==========================================

%hook BUSplashAd
- (void)showInWindow:(UIWindow *)window {
    NSLog(@"[AdBlock] Intercepted BUSplashAd showInWindow");
    // 不调用 %orig，直接返回即可拦截
}
%end

%hook GDTSplashAd
- (void)showAdInWindow:(UIWindow *)window withBottomView:(UIView *)bottomView skipView:(UIView *)skipView {
    NSLog(@"[AdBlock] Intercepted GDTSplashAd showAdInWindow");
}
%end

// ==========================================
// 方案三：加速跳过（可选）
// ==========================================

%hook CSJSplashView
- (void)setCountdownTime:(CGFloat)time {
    %orig(0);
}
%end
