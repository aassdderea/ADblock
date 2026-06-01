#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 1. 穿山甲 (CSJ/BU) 破甲组：强制显示并点击隐藏按钮
// ==========================================
%group CSJHooks

// 核心破甲：拦截 CSJSkipButton 的隐藏行为，强制让它显示并自动点击
%hook CSJSkipButton
- (void)setHidden:(BOOL)hidden {
    // 无论 SDK 怎么隐藏，我们强制让它显示
    %orig(NO); 
    
    // 将 self 转换为 UIButton 以访问 superview 属性
    UIButton *btn = (UIButton *)self;
    
    // 只要它一出现，立刻自动触发点击事件（模拟用户跳过）
    dispatch_async(dispatch_get_main_queue(), ^{
        if (btn.superview) {
            NSLog(@"[AdBlock] 🎯 CSJ Skip Button forced visible & auto-clicked!");
            [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        }
    });
}

// 防御 SDK 修改 Alpha 值
- (void)setAlpha:(CGFloat)alpha {
    %orig(1.0); // 强制透明度为 1
}
%end

// 拦截视频开屏广告视图，直接移除
%hook CSJNativeExpressSplashVideoAdView
- (void)didMoveToWindow {
    %orig;
    // 将 self 转换为 UIView 以访问 window 属性
    UIView *view = (UIView *)self;
    if (view.window) {
        NSLog(@"[AdBlock] Removing CSJ Video Splash Ad View");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [view removeFromSuperview];
        });
    }
}
%end

%end // CSJHooks


// ==========================================
// 2. 广点通 (GDT) 破甲组：秒杀 Present 弹出的控制器
// ==========================================
%group GDTHooks

// 核心破甲：GDT 是通过 present 弹出的，我们在它出现的瞬间直接 dismiss
%hook GDTSplashViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSLog(@"[AdBlock] 🎯 GDT Splash VC appeared, force dismissing instantly!");
    // 无动画立刻关闭，完美触发 SDK 的正常关闭回调，不会卡 10 秒
    [self dismissViewControllerAnimated:NO completion:nil];
}

// 防御 SDK 阻止 dismiss
- (BOOL)isBeingDismissed {
    return YES; // 欺骗 SDK 让它以为自己正在被关闭
}
%end

// 移除 GDT 的底层视图
%hook GDTSplashDLView
- (void)didMoveToWindow {
    %orig;
    // 将 self 转换为 UIView 以访问 window 属性
    UIView *view = (UIView *)self;
    if (view.window) {
        NSLog(@"[AdBlock] Removing GDTSplashDLView");
        dispatch_async(dispatch_get_main_queue(), ^{
            [view removeFromSuperview];
        });
    }
}
%end

%end // GDTHooks


// ==========================================
// 3. 通用防御组：清理全屏遮罩
// ==========================================
%group UniversalHooks

%hook UIWindow
- (void)makeKeyAndVisible {
    NSString *rootVCClass = NSStringFromClass([self.rootViewController class]);
    // 拦截 SDK 创建的独立全屏广告 Window
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
    NSLog(@"[AdBlock] Tweak v4.1 loaded - Anti-Hide & Auto-Dismiss Mode");
    
    // 动态加载类，确保 Hook 生效
    Class csjSkipClass = objc_getClass("CSJSkipButton");
    if (csjSkipClass) {
        NSLog(@"[AdBlock] Activating CSJ Anti-Hide hooks");
        %init(CSJHooks, CSJSkipButton = csjSkipClass, CSJNativeExpressSplashVideoAdView = objc_getClass("CSJNativeExpressSplashVideoAdView"));
    }
    
    Class gdtVCClass = objc_getClass("GDTSplashViewController");
    if (gdtVCClass) {
        NSLog(@"[AdBlock] Activating GDT Auto-Dismiss hooks");
        %init(GDTHooks, GDTSplashViewController = gdtVCClass, GDTSplashDLView = objc_getClass("GDTSplashDLView"));
    }
    
    %init(UniversalHooks);
}
