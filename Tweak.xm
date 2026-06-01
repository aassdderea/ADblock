#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 核心：视频播放器“拔管”组 (解决卡顿，不闪退)
// ==========================================
%group PlayerKillerHooks

// 穿山甲视频播放器：让它创建，但剥夺尺寸和播放能力
%hook BU_ZFPlayerView
- (void)layoutSubviews {
    %orig; 
    UIView *v = (UIView *)self;
    v.frame = CGRectZero; // 零尺寸，不参与渲染
    v.clipsToBounds = YES;
}
- (void)didMoveToWindow {
    %orig;
    // 尝试调用播放器的暂停/停止方法，防止后台解码消耗 CPU
    if ([self respondsToSelector:@selector(pause)]) {
        [self performSelector:@selector(pause)];
    }
    if ([self respondsToSelector:@selector(stop)]) {
        [self performSelector:@selector(stop)];
    }
}
%end

// 广点通视频播放器：同样剥夺尺寸
%hook GDTVideoPlayerView
- (void)layoutSubviews {
    %orig;
    UIView *v = (UIView *)self;
    v.frame = CGRectZero;
    v.clipsToBounds = YES;
}
- (void)didMoveToWindow {
    %orig;
    if ([self respondsToSelector:@selector(pause)]) {
        [self performSelector:@selector(pause)];
    }
}
%end

%end // PlayerKillerHooks


// ==========================================
// 1. 穿山甲 (CSJ/BU) 秒进组：精准点击跳过
// ==========================================
%group CSJHooks

%hook CSJSkipButton
// 只要按钮一布局，立刻模拟点击
- (void)layoutSubviews {
    %orig;
    UIButton *btn = (UIButton *)self;
    btn.hidden = NO;
    btn.alpha = 1.0;
    btn.userInteractionEnabled = YES;
    
    // 只要它在屏幕上，就自动点击
    if (btn.superview && btn.window) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (btn.superview && btn.window) {
                NSLog(@"[AdBlock] 🎯 CSJ Skip Button auto-clicked for instant entry!");
                [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
        });
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig(NO); // 强制显示
}
%end

// 拦截 CSJ 的倒计时视图，直接隐藏倒计时数字（眼不见心不烦）
%hook CSJCountdownView
- (void)layoutSubviews {
    %orig;
    ((UIView *)self).hidden = YES;
}
%end

%end // CSJHooks


// ==========================================
// 2. 广点通 (GDT) 秒进组：强制 Dismiss
// ==========================================
%group GDTHooks

%hook GDTSplashViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSLog(@"[AdBlock] 🎯 GDT Splash VC appeared, dismissing instantly!");
    
    UIViewController *vc = (UIViewController *)self;
    
    // 尝试调用 GDT 内部的跳过/关闭方法
    if ([vc respondsToSelector:@selector(skipAction)]) {
        [vc performSelector:@selector(skipAction)];
    } else if ([vc respondsToSelector:@selector(closeAd)]) {
        [vc performSelector:@selector(closeAd)];
    }
    
    // 兜底方案：强制 dismiss
    dispatch_async(dispatch_get_main_queue(), ^{
        if (vc.presentingViewController) {
            [vc dismissViewControllerAnimated:NO completion:nil];
        } else {
            // 如果是直接 add 到 window 上的，直接移除 view
            [vc.view removeFromSuperview];
        }
    });
}

- (BOOL)isBeingDismissed { return YES; }
%end

%end // GDTHooks


// ==========================================
// 3. 通用防御组：清理残留遮罩
// ==========================================
%group UniversalHooks

// 拦截 SDK 创建的独立全屏广告 Window，在广告关闭后清理
%hook UIWindow
- (void)makeKeyAndVisible {
    NSString *rootVCClass = NSStringFromClass([self.rootViewController class]);
    // 注意：这里不再无脑 hidden=YES，而是让广告正常显示以便触发跳过
    // 只在广告 Window 失去焦点时，确保它被隐藏
    %orig;
}

- (void)resignKeyWindow {
    %orig;
    NSString *rootVCClass = NSStringFromClass([self.rootViewController class]);
    if ([rootVCClass containsString:@"Splash"] || 
        [rootVCClass containsString:@"Ad"] ||
        [rootVCClass containsString:@"GDT"] ||
        [rootVCClass containsString:@"CSJ"]) {
        // 广告 Window 失去焦点后，立刻隐藏并清理
        self.hidden = YES;
        self.rootViewController = nil;
    }
}
%end

%end // UniversalHooks


// ==========================================
// 4. 初始化：精准激活
// ==========================================
%ctor {
    NSLog(@"[AdBlock] Tweak v7.0 loaded - Instant Entry & Smooth Mode");
    
    // 激活视频播放器拔管
    Class buPlayer = objc_getClass("BU_ZFPlayerView");
    Class gdtPlayer = objc_getClass("GDTVideoPlayerView");
    if (buPlayer || gdtPlayer) {
        %init(PlayerKillerHooks, 
              BU_ZFPlayerView = buPlayer ?: [UIView class], 
              GDTVideoPlayerView = gdtPlayer ?: [UIView class]);
    }
    
    // 激活 CSJ 秒进
    Class csjSkipClass = objc_getClass("CSJSkipButton");
    Class csjCountdown = objc_getClass("CSJCountdownView");
    if (csjSkipClass) {
        %init(CSJHooks, 
              CSJSkipButton = csjSkipClass, 
              CSJCountdownView = csjCountdown ?: [UIView class]);
    }
    
    // 激活 GDT 秒进
    Class gdtVCClass = objc_getClass("GDTSplashViewController");
    if (gdtVCClass) {
        %init(GDTHooks, GDTSplashViewController = gdtVCClass);
    }
    
    %init(UniversalHooks);
}
