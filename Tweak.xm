#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 核心：视频播放器“拔管”组 (解决卡顿，不闪退)
// ==========================================
%group PlayerKillerHooks

%hook BU_ZFPlayerView
- (void)layoutSubviews {
    %orig; 
    UIView *v = (UIView *)self;
    v.frame = CGRectZero; // 零尺寸，不参与渲染
    v.clipsToBounds = YES;
}
- (void)didMoveToWindow {
    %orig;
    if ([self respondsToSelector:@selector(pause)]) {
        [self performSelector:@selector(pause)];
    }
    if ([self respondsToSelector:@selector(stop)]) {
        [self performSelector:@selector(stop)];
    }
}
%end

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
// 1. 穿山甲 (CSJ/BU) 秒进组：纯物理点击
// ==========================================
%group CSJHooks

// 强制显示跳过按钮并自动点击（这是最安全的跳过，SDK 会正常触发关闭回调）
%hook CSJSkipButton
- (void)layoutSubviews {
    %orig;
    UIButton *btn = (UIButton *)self;
    btn.hidden = NO;
    btn.alpha = 1.0;
    btn.userInteractionEnabled = YES;
    
    if (btn.superview && btn.window) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (btn.superview && btn.window) {
                NSLog(@"[AdBlock] 🎯 CSJ Skip Button auto-clicked!");
                [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
            }
        });
    }
}
- (void)setHidden:(BOOL)hidden { %orig(NO); }
- (void)setAlpha:(CGFloat)alpha { %orig(1.0); }
%end

// 隐藏倒计时数字，眼不见心不烦
%hook CSJCountdownView
- (void)layoutSubviews {
    %orig;
    ((UIView *)self).hidden = YES;
}
%end

%end // CSJHooks


// ==========================================
// 2. 广点通 (GDT) 秒进组：物理跳过
// ==========================================
%group GDTHooks

%hook GDTSplashViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSLog(@"[AdBlock] 🎯 GDT Splash VC appeared, trying skipAction!");
    
    UIViewController *vc = (UIViewController *)self;
    // 尝试调用 GDT 内部的跳过方法
    if ([vc respondsToSelector:@selector(skipAction)]) {
        [vc performSelector:@selector(skipAction)];
    } else if ([vc respondsToSelector:@selector(closeAd)]) {
        [vc performSelector:@selector(closeAd)];
    }
}
%end

%end // GDTHooks


// ==========================================
// 3. 终极兜底：暴力唤醒主界面 (解决黑屏的核心)
// ==========================================
%group UniversalHooks

%hook UIWindow
- (void)setHidden:(BOOL)hidden {
    %orig;
    // 如果 SDK 试图隐藏广告 Window，我们顺势强制唤醒 App 的主 Window
    if (hidden == YES) {
        NSString *rootVCClass = NSStringFromClass([self.rootViewController class]);
        if (rootVCClass && 
           ([rootVCClass containsString:@"Splash"] || 
            [rootVCClass containsString:@"Ad"] ||
            [rootVCClass containsString:@"GDT"] ||
            [rootVCClass containsString:@"CSJ"])) {
            
            NSLog(@"[AdBlock] 🛡️ Ad Window hidden, force waking up App main windows!");
            dispatch_async(dispatch_get_main_queue(), ^{
                
                // 【修复】使用 pragma 忽略 iOS 15.0 的废弃警告，确保编译通过
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                NSArray<UIWindow *> *allWindows = [UIApplication sharedApplication].windows;
                #pragma clang diagnostic pop
                
                for (UIWindow *w in allWindows) {
                    NSString *wRootClass = NSStringFromClass([w.rootViewController class]);
                    // 找到 App 的主界面 Window (LoveTabBarViewController / LaunchUserInfoViewController)
                    if (w != self && wRootClass && 
                       ([wRootClass containsString:@"Love"] || 
                        [wRootClass containsString:@"Launch"] ||
                        [wRootClass containsString:@"Main"] ||
                        [wRootClass containsString:@"TabBar"])) {
                        
                        w.hidden = NO; // 强制显示 Window
                        [w makeKeyWindow];
                        
                        // 强制显示其内部的所有子视图 (破解 hidden=YES 死锁)
                        for (UIView *sub in w.rootViewController.view.subviews) {
                            sub.hidden = NO;
                        }
                        w.rootViewController.view.hidden = NO;
                    }
                }
            });
        }
    }
}
%end

%end // UniversalHooks


// ==========================================
// 4. 初始化：精准激活
// ==========================================
%ctor {
    NSLog(@"[AdBlock] Tweak v9.1 loaded - Physical Skip & Force Wakeup (Fixed Deprecated Warning)");
    
    // 激活视频播放器拔管
    Class buPlayer = objc_getClass("BU_ZFPlayerView");
    Class gdtPlayer = objc_getClass("GDTVideoPlayerView");
    if (buPlayer || gdtPlayer) {
        %init(PlayerKillerHooks, 
              BU_ZFPlayerView = buPlayer ?: [UIView class], 
              GDTVideoPlayerView = gdtPlayer ?: [UIView class]);
    }
    
    // 激活 CSJ 物理跳过
    Class csjSkipClass = objc_getClass("CSJSkipButton");
    Class csjCountdown = objc_getClass("CSJCountdownView");
    if (csjSkipClass) {
        %init(CSJHooks, 
              CSJSkipButton = csjSkipClass, 
              CSJCountdownView = csjCountdown ?: [UIView class]);
    }
    
    // 激活 GDT 物理跳过
    Class gdtVCClass = objc_getClass("GDTSplashViewController");
    if (gdtVCClass) {
        %init(GDTHooks, GDTSplashViewController = gdtVCClass);
    }
    
    %init(UniversalHooks);
}
