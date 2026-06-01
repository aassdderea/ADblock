#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 核心修复：安全瘫痪视频播放器 (解决卡顿且不闪退)
// ==========================================
%group PlayerKillerHooks

// 穿山甲视频播放器：让它正常创建，但强制隐藏并剥夺尺寸
%hook BU_ZFPlayerView
- (void)layoutSubviews {
    %orig; // 必须调用原方法，防止 SDK 内部状态机崩溃
    UIView *v = (UIView *)self;
    if (!v.hidden || !CGRectEqualToRect(v.frame, CGRectZero)) {
        v.hidden = YES;
        v.frame = CGRectZero;
        v.userInteractionEnabled = NO;
    }
}
- (void)didMoveToWindow {
    %orig;
    ((UIView *)self).hidden = YES;
}
%end

// 广点通视频播放器：同样安全瘫痪
%hook GDTVideoPlayerView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    if (!v.hidden || !CGRectEqualToRect(v.frame, CGRectZero)) {
        v.hidden = YES;
        v.frame = CGRectZero;
        v.userInteractionEnabled = NO;
    }
}
- (void)didMoveToWindow {
    %orig;
    ((UIView *)self).hidden = YES;
}
%end

// 穿山甲播放器控制层：强制隐藏
%hook BU_ZFPlayerControlView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    v.hidden = YES;
    v.frame = CGRectZero;
}
%end

%end // PlayerKillerHooks


// ==========================================
// 1. 穿山甲 (CSJ/BU) 破甲组：安全跳过
// ==========================================
%group CSJHooks

%hook CSJSkipButton
- (void)setHidden:(BOOL)hidden {
    %orig(NO); // 强制显示
    UIButton *btn = (UIButton *)self;
    // 增加 superview 和 window 检查，防止按钮被销毁后发送事件导致闪退
    if (btn.superview && btn.window) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // 再次检查，确保在异步执行时按钮依然存在
            if (btn.superview && btn.window) {
                NSLog(@"[AdBlock] 🎯 CSJ Skip Button auto-clicked safely!");
                [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
        });
    }
}
- (void)setAlpha:(CGFloat)alpha { %orig(1.0); }
%end

%hook CSJNativeExpressSplashVideoAdView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    v.hidden = YES;
    v.frame = CGRectZero;
}
%end

%end // CSJHooks


// ==========================================
// 2. 广点通 (GDT) 破甲组：安全 Dismiss
// ==========================================
%group GDTHooks

%hook GDTSplashViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSLog(@"[AdBlock] 🎯 GDT Splash VC dismissing safely!");
    
    // 将 self 转换为 UIViewController 以访问 presentingViewController 属性
    UIViewController *vc = (UIViewController *)self;
    
    // 使用安全的 dismiss 方式
    if (vc.presentingViewController) {
        [vc dismissViewControllerAnimated:NO completion:nil];
    } else {
        // 如果没有 presentingViewController，尝试直接 dismiss
        [vc dismissViewControllerAnimated:NO completion:nil];
    }
}
- (BOOL)isBeingDismissed { return YES; }
%end

%hook GDTSplashDLView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    v.hidden = YES;
    v.frame = CGRectZero;
}
%end

%end // GDTHooks


// ==========================================
// 3. 通用防御组：清理全屏遮罩 (移除 Snapshot 误杀)
// ==========================================
%group UniversalHooks

%hook UIWindow
- (void)makeKeyAndVisible {
    NSString *rootVCClass = NSStringFromClass([self.rootViewController class]);
    // 仅拦截明确的广告 Window，不再拦截 Snapshot
    if ([rootVCClass containsString:@"Splash"] || 
        [rootVCClass containsString:@"Ad"] ||
        [rootVCClass containsString:@"GDT"] ||
        [rootVCClass containsString:@"CSJ"]) {
        NSLog(@"[AdBlock] Blocked suspicious Ad UIWindow: %@", rootVCClass);
        self.hidden = YES;
        return;
    }
    %orig;
}
%end

%end // UniversalHooks


// ==========================================
// 4. 初始化：精准激活
// ==========================================
%ctor {
    NSLog(@"[AdBlock] Tweak v6.1 loaded - Safe Paralysis Mode (No Crash)");
    
    // 激活视频播放器安全瘫痪
    Class buPlayer = objc_getClass("BU_ZFPlayerView");
    Class gdtPlayer = objc_getClass("GDTVideoPlayerView");
    Class buControl = objc_getClass("BU_ZFPlayerControlView");
    if (buPlayer || gdtPlayer || buControl) {
        %init(PlayerKillerHooks, 
              BU_ZFPlayerView = buPlayer ?: [UIView class], 
              GDTVideoPlayerView = gdtPlayer ?: [UIView class],
              BU_ZFPlayerControlView = buControl ?: [UIView class]);
    }
    
    // 激活 CSJ Hook
    Class csjSkipClass = objc_getClass("CSJSkipButton");
    Class csjVideoAd = objc_getClass("CSJNativeExpressSplashVideoAdView");
    if (csjSkipClass || csjVideoAd) {
        %init(CSJHooks, 
              CSJSkipButton = csjSkipClass ?: [UIButton class], 
              CSJNativeExpressSplashVideoAdView = csjVideoAd ?: [UIView class]);
    }
    
    // 激活 GDT Hook
    Class gdtVCClass = objc_getClass("GDTSplashViewController");
    Class gdtDLView = objc_getClass("GDTSplashDLView");
    if (gdtVCClass || gdtDLView) {
        %init(GDTHooks, 
              GDTSplashViewController = gdtVCClass ?: [UIViewController class], 
              GDTSplashDLView = gdtDLView ?: [UIView class]);
    }
    
    %init(UniversalHooks);
}
