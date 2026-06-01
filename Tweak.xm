#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==========================================
// 方案一：直接隐藏/移除开屏广告视图（最稳妥）
// ==========================================

%hook CSJNativeExpressSplashVideoAdView
- (void)didMoveToSuperview {
    // 阻止穿山甲开屏视频广告添加到视图层级
    NSLog(@"[AdBlock] Blocked CSJ Splash Video Ad");
    [self removeFromSuperview];
}
%end

%hook GDTSplashDLView
- (void)didMoveToSuperview {
    // 阻止优量汇开屏广告添加到视图层级
    NSLog(@"[AdBlock] Blocked GDT Splash DL Ad");
    [self removeFromSuperview];
}
%end

// ==========================================
// 方案二：从源头拦截广告展示方法
// ==========================================

// 穿山甲开屏展示拦截
%hook BUSplashAd
- (void)showInWindow:(UIWindow *)window {
    NSLog(@"[AdBlock] Intercepted BUSplashAd showInWindow");
    // 不调用原方法，直接返回
}
%end

// 优量汇开屏展示拦截
%hook GDTSplashAd
- (void)showAdInWindow:(UIWindow *)window withBottomView:(UIView *)bottomView skipView:(UIView *)skipView {
    NSLog(@"[AdBlock] Intercepted GDTSplashAd showAdInWindow");
}
%end

// ==========================================
// 方案三：加速跳过（如果不想完全移除，仅秒跳）
// ==========================================

%hook CSJSplashView
- (void)setCountdownTime:(CGFloat)time {
    // 将倒计时强制设为0，实现秒跳
    %orig(0);
}
%end
