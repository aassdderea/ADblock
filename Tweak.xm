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
    // 尝试调用播放器的暂停/停止方法，防止后台解码消耗 CPU
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
// 1. 穿山甲 (CSJ/BU) 秒进组：时光机模式
// ==========================================
%group CSJHooks

// 【核心】欺骗倒计时管理器，让它以为时间已经到了
%hook CSJSplashAdManager
- (NSTimeInterval)splashAdDuration { return 0.1; }
- (NSTimeInterval)duration { return 0.1; }
- (NSTimeInterval)countdownTime { return 0; }
%end

// 针对可能存在的 Ad 实例拦截
%hook BUSplashAd
- (NSTimeInterval)duration { return 0.1; }
%end

// 强制显示跳过按钮并自动点击（双重保险）
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
%end

%end // CSJHooks


// ==========================================
// 2. 广点通 (GDT) 秒进组：时光机模式
// ==========================================
%group GDTHooks

// 【核心】欺骗 GDT 的倒计时和展示时间 (已修复重载冲突)
%hook GDTSplashAd
- (NSTimeInterval)fetchDelay { return 0.1; }
- (NSTimeInterval)duration { return 0.1; }
%end

// 拦截 GDT 的倒计时视图，防止 UI 渲染开销
%hook GDTSplashCountdownView
- (void)layoutSubviews {
    %orig;
    ((UIView *)self).hidden = YES;
}
%end

%end // GDTHooks


// ==========================================
// 3. 通用防御组：安全放行与清理
// ==========================================
%group UniversalHooks

%hook UIWindow
- (void)makeKeyAndVisible {
    %orig; // 必须放行，让 SDK 正常接管和交还 Window，防止黑屏
}

- (void)resignKeyWindow {
    %orig;
    // 当广告 Window 失去焦点（说明 SDK 已经走完正常流程准备关闭了），我们顺手清理
    NSString *rootVCClass = NSStringFromClass([self.rootViewController class]);
    if (rootVCClass && 
       ([rootVCClass containsString:@"Splash"] || 
        [rootVCClass containsString:@"Ad"] ||
        [rootVCClass containsString:@"GDT"] ||
        [rootVCClass containsString:@"CSJ"])) {
        self.hidden = YES;
    }
}
%end

%end // UniversalHooks


// ==========================================
// 4. 初始化：精准激活
// ==========================================
%ctor {
    NSLog(@"[AdBlock] Tweak v8.1 loaded - Time Machine Mode (Fixed Overload)");
    
    // 激活视频播放器拔管
    Class buPlayer = objc_getClass("BU_ZFPlayerView");
    Class gdtPlayer = objc_getClass("GDTVideoPlayerView");
    if (buPlayer || gdtPlayer) {
        %init(PlayerKillerHooks, 
              BU_ZFPlayerView = buPlayer ?: [UIView class], 
              GDTVideoPlayerView = gdtPlayer ?: [UIView class]);
    }
    
    // 激活 CSJ 时光机
    Class csjSkipClass = objc_getClass("CSJSkipButton");
    Class csjManager = objc_getClass("CSJSplashAdManager");
    Class buSplashAd = objc_getClass("BUSplashAd");
    if (csjSkipClass || csjManager || buSplashAd) {
        %init(CSJHooks, 
              CSJSkipButton = csjSkipClass ?: [UIButton class],
              CSJSplashAdManager = csjManager ?: [NSObject class],
              BUSplashAd = buSplashAd ?: [NSObject class]);
    }
    
    // 激活 GDT 时光机
    Class gdtSplashAd = objc_getClass("GDTSplashAd");
    Class gdtCountdown = objc_getClass("GDTSplashCountdownView");
    if (gdtSplashAd || gdtCountdown) {
        %init(GDTHooks, 
              GDTSplashAd = gdtSplashAd ?: [NSObject class],
              GDTSplashCountdownView = gdtCountdown ?: [UIView class]);
    }
    
    %init(UniversalHooks);
}
