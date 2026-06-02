// ==========================================
// Tweak.xm - GDT开屏广告跳过 (最终生产版)
// ==========================================
#import <UIKit/UIKit.h>
#import <objc/message.h>

static void triggerGDTSkip() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            // 1. 获取当前最顶层窗口
            UIWindow *topWindow = nil;
            CGFloat maxLevel = -1;
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *w in scene.windows) {
                        if (!w.isHidden && w.windowLevel > maxLevel) {
                            maxLevel = w.windowLevel;
                            topWindow = w;
                        }
                    }
                }
            }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if (!topWindow) {
                for (UIWindow *w in [UIApplication sharedApplication].windows) {
                    if (!w.isHidden && w.windowLevel > maxLevel) {
                        maxLevel = w.windowLevel;
                        topWindow = w;
                    }
                }
            }
#pragma clang diagnostic pop
            if (!topWindow) return;

            // 2. 查找 GDTSplashAdView 及其手势
            UIView *splashView = nil;
            UIGestureRecognizer *gdtGesture = nil;
            
            for (UIView *sub in topWindow.subviews) {
                NSString *cls = NSStringFromClass([sub class]);
                if ([cls containsString:@"GDTSplashAdView"]) {
                    splashView = sub;
                    break;
                }
            }
            if (!splashView) return;

            for (UIGestureRecognizer *g in splashView.gestureRecognizers) {
                if ([NSStringFromClass([g class]) containsString:@"GDTSystemGestureRecognizer"]) {
                    gdtGesture = g;
                    break;
                }
            }

            // 3. 主路径：handleSkipClick: (v@:@)
            SEL skipSel = @selector(handleSkipClick:);
            if (gdtGesture && [splashView respondsToSelector:skipSel]) {
                ((void(*)(id, SEL, id))objc_msgSend)(splashView, skipSel, gdtGesture);
                return;
            }

            // 4. 备用路径：delegate.splashAdClosed:
            if ([splashView respondsToSelector:@selector(delegate)]) {
                id delegate = [splashView performSelector:@selector(delegate)];
                SEL closedSel = @selector(splashAdClosed:);
                if (delegate && [delegate respondsToSelector:closedSel]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(delegate, closedSel, splashView);
                }
            }
        } @catch (NSException *e) {}
    });
}

%hook UIApplication
- (void)applicationDidBecomeActive:(UIApplication *)application {
    %orig;
    triggerGDTSkip();
}
%end
