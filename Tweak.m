// ==========================================
// Tweak.m - 通用去开屏广告插件（iOS16 盾牌修复）
// ==========================================

// ... 前面所有代码保持不变，仅修改 addFloatingButton 和初始化部分 ...

// ========== 新增：安全获取当前活跃 Scene ==========
static UIWindowScene * _Nullable currentActiveScene(void) {
    __block UIWindowScene *scene = nil;
    if (@available(iOS 13.0, *)) {
        [[UIApplication sharedApplication].connectedScenes enumerateObjectsUsingBlock:^(UIScene *obj, BOOL *stop) {
            if ([obj isKindOfClass:[UIWindowScene class]] && obj.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)obj;
                *stop = YES;
            }
        }];
    }
    return scene;
}

// ========== 修改 addFloatingButton：增加重试机制 ==========
static void addFloatingButton() {
    // 延迟 0.5 秒，给 Scene 激活留足时间
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 尝试获取当前活跃 Scene，最多重试 10 次
        __block int retry = 0;
        __block UIWindowScene *scene = currentActiveScene();
        
        void (^createButton)(void) = ^{
            UIWindow *btnWin = [[UIWindow alloc] initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width - 60, 120, 50, 50)];
            // 关联 Scene（iOS 13+）
            if (scene) {
                btnWin.windowScene = scene;
            }
            // 提升层级：比状态栏还高，确保不被广告遮挡
            btnWin.windowLevel = UIWindowLevelStatusBar + 100;
            btnWin.backgroundColor = [UIColor clearColor];
            btnWin.hidden = NO;
            
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = btnWin.bounds;
            btn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.8];
            btn.layer.cornerRadius = 25;
            btn.layer.shadowColor = [UIColor blackColor].CGColor;
            btn.layer.shadowOffset = CGSizeMake(0, 2);
            btn.layer.shadowOpacity = 0.3;
            [btn setTitle:@"🛡️" forState:UIControlStateNormal];
            [btn addAction:[UIAction actionWithHandler:^(__kindof UIAction * _) {
                scanForAdsInTopWindow();
            }] forControlEvents:UIControlEventTouchUpInside];
            [btnWin addSubview:btn];
            
            // 拖动支持（代码不变）
            _AdBlockGestureHandler *handler = [[_AdBlockGestureHandler alloc] initWithBlock:^(UIPanGestureRecognizer *gesture) {
                static CGPoint start;
                if (gesture.state == UIGestureRecognizerStateBegan) {
                    start = [gesture locationInView:btnWin];
                } else {
                    CGPoint curr = [gesture locationInView:nil];
                    btnWin.frame = CGRectMake(curr.x - start.x, curr.y - start.y,
                                              btnWin.frame.size.width, btnWin.frame.size.height);
                }
            }];
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:handler action:@selector(handlePan:)];
            [btn addGestureRecognizer:pan];
            
            TESTLOG(@"🛡️ 悬浮按钮已创建 (Scene: %@)", scene);
        };
        
        if (scene) {
            createButton();
        } else {
            // 如果 Scene 还未就绪，每 0.2 秒重试一次
            __block NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer * _Nonnull t) {
                scene = currentActiveScene();
                if (scene || ++retry > 10) {
                    [t invalidate];
                    if (scene) {
                        createButton();
                    } else {
                        TESTLOG(@"❌ 未找到活跃 Scene，悬浮按钮创建失败");
                    }
                }
            }];
        }
    });
}

// ========== 初始化入口保持不变 ==========
__attribute__((constructor))
static void adblock_init() {
    TESTLOG(@"🚀 去广告插件初始化");
    applyKnownSDKHooks();
    
    Method m = class_getInstanceMethod([UIWindow class], @selector(makeKeyAndVisible));
    if (m) {
        orig_makeKeyAndVisible = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)swizzled_makeKeyAndVisible);
    }
    
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _) {
        scanForAdsInTopWindow();
    }];
    
    showLoadedToast();
    addFloatingButton();
}
