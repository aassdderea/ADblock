#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==========================================
// 1. 安全 Hook 工具方法
// ==========================================

static BOOL classExists(NSString *className) {
    return NSClassFromString(className) != nil;
}

static SEL selectorFromString(NSString *selName) {
    return NSSelectorFromString(selName);
}

// ==========================================
// 2. 广点通 (GDT) 修复：通过运行时安全 Hook
// ==========================================

%group GDTHooks
// 尝试 Hook GDT 的开屏控制器
%hookf(void, dismissViewControllerAnimated_completion_, UIViewController *self, BOOL animated, void (^completion)(void)) {
    NSString *className = NSStringFromClass([self class]);
    if ([className containsString:@"Splash"] || [className containsString:@"GDT"]) {
        NSLog(@"[AdBlock] Force dismissing GDT ad controller: %@", className);
        // 直接返回，不执行原方法
        return;
    }
    %orig(self, animated, completion);
}
%end

// 移除 GDT 广告视图
%hookf(void, didMoveToSuperview, UIView *self) {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if ([className containsString:@"GDTSplashDLView"] || 
        [className containsString:@"GDTAdView"] || 
        [className containsString:@"SplashAd"]) {
        NSLog(@"[AdBlock] Removing GDT ad view: %@", className);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self removeFromSuperview];
        });
    }
}
%end
%end

// ==========================================
// 3. 穿山甲 (CSJ/BU) 修复：通过运行时安全 Hook
// ==========================================

%group CSJHooks
// 自动跳过穿山甲广告
%hookf(void, didMoveToWindow, UIView *self) {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if ([className containsString:@"CSJSplashView"] || 
        [className containsString:@"BUSplashView"]) {
        NSLog(@"[AdBlock] Found CSJ splash view: %@", className);
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // 遍历所有子视图，查找跳过按钮
            for (UIView *subview in [self subviews]) {
                if ([subview isKindOfClass:[UIButton class]]) {
                    UIButton *btn = (UIButton *)subview;
                    NSString *btnTitle = [btn titleForState:UIControlStateNormal];
                    if (btnTitle && ([btnTitle containsString:@"跳过"] || 
                                     [btnTitle containsString:@"Skip"] || 
                                     [btnTitle containsString:@"skip"])) {
                        NSLog(@"[AdBlock] Auto-clicking skip button: %@", btnTitle);
                        [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                        break;
                    }
                }
            }
            
            // 如果没找到按钮，1秒后强制移除自己
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.superview) {
                    NSLog(@"[AdBlock] Forcibly removing CSJ splash view");
                    [self removeFromSuperview];
                }
            });
        });
    }
}
%end

// 拦截穿山甲广告展示
static void (*orig_BU_ads_load)(id, SEL, id);
static void new_BU_ads_load(id self, SEL _cmd, id arg) {
    NSLog(@"[AdBlock] Intercepted BUSplashAd load");
    // 不调用原方法
}
%end

// ==========================================
// 4. 通用防御：清理透明遮罩
// ==========================================

%group UniversalHooks
// 检测并移除全屏遮罩视图
%hookf(void, layoutSubviews, UIView *self) {
    %orig;
    
    if (self.frame.size.width >= [UIScreen mainScreen].bounds.size.width - 10 &&
        self.frame.size.height >= [UIScreen mainScreen].bounds.size.height - 10) {
        
        NSString *className = NSStringFromClass([self class]);
        if ([className containsString:@"Ad"] || 
            [className containsString:@"Splash"] || 
            [className containsString:@"Overlay"] ||
            [className containsString:@"Mask"]) {
            
            if (self.alpha < 0.1 || self.backgroundColor == [UIColor clearColor]) {
                NSLog(@"[AdBlock] Removing transparent overlay: %@", className);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self removeFromSuperview];
                });
            }
        }
    }
}
%end

// 监控窗口层级变化
%hookf(void, makeKeyAndVisible, UIWindow *self) {
    %orig;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (window != [UIApplication sharedApplication].keyWindow && 
                window.windowLevel > UIWindowLevelNormal) {
                
                NSString *rootVCClass = NSStringFromClass([window.rootViewController class]);
                if ([rootVCClass containsString:@"Ad"] || 
                    [rootVCClass containsString:@"Splash"] || 
                    [rootVCClass containsString:@"GDT"] || 
                    [rootVCClass containsString:@"CSJ"]) {
                    
                    NSLog(@"[AdBlock] Hiding suspicious ad window: %@", rootVCClass);
                    window.hidden = YES;
                }
            }
        }
    });
}
%end
%end

// ==========================================
// 5. 初始化：按需激活 Hook 组
// ==========================================

%ctor {
    NSLog(@"[AdBlock] Tweak loaded");
    
    // 按需激活 Hook 组
    if (classExists(@"GDTSplashViewController") || classExists(@"GDTSplashDLView")) {
        NSLog(@"[AdBlock] Activating GDT hooks");
        %init(GDTHooks);
    }
    
    if (classExists(@"CSJSplashView") || classExists(@"BUSplashAd")) {
        NSLog(@"[AdBlock] Activating CSJ hooks");
        %init(CSJHooks);
        
        // 尝试 Hook 穿山甲广告加载方法
        Class busClass = NSClassFromString(@"BUSplashAd");
        if (busClass) {
            MSHookMessageEx(busClass, @selector(loadAd), (IMP)new_BU_ads_load, (IMP *)&orig_BU_ads_load);
        }
    }
    
    // 激活通用防御
    %init(UniversalHooks);
    
    // 强制刷新界面
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication].keyWindow layoutIfNeeded];
    });
}
