#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 核心破甲：彻底瘫痪视频播放器 (解决卡顿的元凶)
// ==========================================
%group PlayerKillerHooks

// 穿山甲视频播放器：直接替换为零大小的空视图
%hook BU_ZFPlayerView
- (instancetype)initWithFrame:(CGRect)frame {
    UIView *dummyView = [[UIView alloc] initWithFrame:CGRectZero];
    dummyView.hidden = YES;
    dummyView.userInteractionEnabled = NO;
    return (id)dummyView; 
}
- (void)layoutSubviews { %orig; ((UIView *)self).hidden = YES; ((UIView *)self).frame = CGRectZero; }
%end

// 广点通视频播放器：同样替换为空视图
%hook GDTVideoPlayerView
- (instancetype)initWithFrame:(CGRect)frame {
    UIView *dummyView = [[UIView alloc] initWithFrame:CGRectZero];
    dummyView.hidden = YES;
    dummyView.userInteractionEnabled = NO;
    return (id)dummyView;
}
- (void)layoutSubviews { %orig; ((UIView *)self).hidden = YES; ((UIView *)self).frame = CGRectZero; }
%end

// 穿山甲播放器控制层：强制隐藏
%hook BU_ZFPlayerControlView
- (void)layoutSubviews { %orig; ((UIView *)self).hidden = YES; ((UIView *)self).frame = CGRectZero; }
%end

%end // PlayerKillerHooks


// ==========================================
// 1. 穿山甲 (CSJ/BU) 破甲组：强制显示并点击隐藏按钮
// ==========================================
%group CSJHooks

%hook CSJSkipButton
- (void)setHidden:(BOOL)hidden {
    %orig(NO); // 强制显示
    UIButton *btn = (UIButton *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (btn.superview) {
            NSLog(@"[AdBlock] 🎯 CSJ Skip Button forced visible & auto-clicked!");
            [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        }
    });
}
- (void)setAlpha:(CGFloat)alpha { %orig(1.0); }
%end

// 视频开屏广告视图：早期拦截，零开销
%hook CSJNativeExpressSplashVideoAdView
- (instancetype)initWithFrame:(CGRect)frame {
    UIView *dummy = [[UIView alloc] initWithFrame:CGRectZero];
    dummy.hidden = YES;
    return (id)dummy;
}
%end

%end // CSJHooks


// ==========================================
// 2. 广点通 (GDT) 破甲组：秒杀 Present 弹出的控制器
// ==========================================
%group GDTHooks

%hook GDTSplashViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSLog(@"[AdBlock] 🎯 GDT Splash VC appeared, force dismissing instantly!");
    [self dismissViewControllerAnimated:NO completion:nil];
}
- (BOOL)isBeingDismissed { return YES; }
%end

%hook GDTSplashDLView
- (instancetype)initWithFrame:(CGRect)frame {
    UIView *dummy = [[UIView alloc] initWithFrame:CGRectZero];
    dummy.hidden = YES;
    return (id)dummy;
}
%end

%end // GDTHooks


// ==========================================
// 3. 通用防御组：清理全屏遮罩与流氓 Window
// ==========================================
%group UniversalHooks

%hook UIWindow
- (void)makeKeyAndVisible {
    NSString *rootVCClass = NSStringFromClass([self.rootViewController class]);
    // 拦截 SDK 创建的独立全屏广告 Window，以及挂载到 SnapshotWindow 的行为
    if ([rootVCClass containsString:@"Splash"] || 
        [rootVCClass containsString:@"Ad"] ||
        [rootVCClass containsString:@"GDT"] ||
        [rootVCClass containsString:@"CSJ"] ||
        [NSStringFromClass([self class]) containsString:@"Snapshot"]) {
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
    NSLog(@"[AdBlock] Tweak v5.0 loaded - Zero Render Overhead Mode");
    
    // 激活视频播放器杀手 (解决卡顿的核心)
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
