#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ==========================================
// 核心配置：识别跳过按钮的“特征库”
// ==========================================
static NSString * const kSkipButtonRegex = @"(?i)^\\s*(跳过|skip|关闭|close|跳过\\s*\\d+|\\d+\\s*跳过|\\d+\\s*s|skip\\s*in\\s*\\d+)\\s*$";
static const CGFloat kMaxButtonArea = 25000.0; 
static const CGFloat kEdgeMarginRatio = 0.35; 

// ==========================================
// 核心逻辑：C 语言静态函数 (极速扫描)
// ==========================================
static UIButton * findSkipButtonInView(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) return nil;
    if (view.isHidden || view.alpha < 0.1) return nil;
    
    if ([view isKindOfClass:[UIButton class]] || [view isKindOfClass:UIControl.class]) {
        UIButton *btn = (UIButton *)view;
        
        // 1. 检查尺寸
        CGRect frame = btn.frame;
        CGFloat area = frame.size.width * frame.size.height;
        if (area > kMaxButtonArea || area < 100) goto check_subviews; 
        
        // 2. 检查位置
        UIWindow *window = btn.window;
        if (window) {
            CGFloat screenW = window.bounds.size.width;
            CGFloat screenH = window.bounds.size.height;
            CGPoint center = btn.center;
            CGPoint centerInWindow = [btn.superview convertPoint:center toView:window];
            
            BOOL isOnRightEdge = centerInWindow.x > screenW * (1.0 - kEdgeMarginRatio);
            BOOL isOnLeftEdge = centerInWindow.x < screenW * kEdgeMarginRatio;
            BOOL isOnTopEdge = centerInWindow.y < screenH * kEdgeMarginRatio;
            BOOL isOnBottomEdge = centerInWindow.y > screenH * (1.0 - kEdgeMarginRatio);
            
            BOOL isOnEdge = (isOnRightEdge && (isOnTopEdge || isOnBottomEdge)) || 
                            (isOnLeftEdge && isOnBottomEdge);
            
            if (isOnEdge) {
                // 3. 检查文本
                NSString *title = [btn titleForState:UIControlStateNormal];
                if (!title) title = btn.titleLabel.text;
                if (!title) title = btn.accessibilityLabel; 
                
                if (title && title.length > 0 && title.length < 15) {
                    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", kSkipButtonRegex];
                    if ([predicate evaluateWithObject:title]) {
                        return btn;
                    }
                }
            }
        }
    }
    
check_subviews:
    for (UIView *subview in view.subviews) {
        UIButton *found = findSkipButtonInView(subview);
        if (found) return found;
    }
    return nil;
}

// ==========================================
// 定时器控制逻辑 (彻底解决卡死闪退)
// ==========================================
static dispatch_source_t _skipTimer = nil;

static void startSkipTimer() {
    if (_skipTimer) return; // 防止重复启动
    
    _skipTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    
    // 每 0.5 秒扫描一次
    dispatch_source_set_timer(_skipTimer, dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), 0.5 * NSEC_PER_SEC, 0.1 * NSEC_PER_SEC);
    
    __block int scanCount = 0;
    dispatch_source_set_event_handler(_skipTimer, ^{
        scanCount++;
        
        // 超过 10 次 (5秒) 还没找到，直接放弃并销毁定时器，绝不拖泥带水
        if (scanCount > 10) {
            NSLog(@"[UniversalSkipper] ⏱️ 扫描超时，停止扫描");
            dispatch_source_cancel(_skipTimer);
            _skipTimer = nil;
            return;
        }
        
        UIWindow *keyWindow = nil;
        // 兼容 iOS 13+ 的多 Scene 架构
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in scene.windows) {
                        if (w.isKeyWindow) {
                            keyWindow = w;
                            break;
                        }
                    }
                }
                if (keyWindow) break;
            }
        }
        
        if (!keyWindow) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            keyWindow = [UIApplication sharedApplication].keyWindow;
            #pragma clang diagnostic pop
        }
        
        if (!keyWindow) return;
        
        // 过滤系统级 Window
        if (keyWindow.windowLevel >= UIWindowLevelAlert - 1) return;
        
        UIButton *target = findSkipButtonInView(keyWindow);
        if (target) {
            NSLog(@"[UniversalSkipper] 🎯 发现并点击跳过按钮: '%@'", target.titleLabel.text ?: target.accessibilityLabel);
            [target sendActionsForControlEvents:UIControlEventTouchUpInside];
            
            // 点击成功后，立刻销毁定时器
            dispatch_source_cancel(_skipTimer);
            _skipTimer = nil;
        }
    });
    
    dispatch_resume(_skipTimer);
}

// ==========================================
// Hook 组：监听 App 启动完成
// ==========================================
%group UniversalSkipper

%hook UIApplication
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL result = %orig;
    // App 启动完成后，延迟 0.5 秒启动扫描定时器（给广告 SDK 一点渲染时间）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        startSkipTimer();
    });
    return result;
}
%end

%end // UniversalSkipper

// ==========================================
// 初始化
// ==========================================
%ctor {
    NSLog(@"[UniversalSkipper] 🚀 Tweak loaded - 安全定时器版 (防闪退)");
    %init(UniversalSkipper);
}
