#import <Foundation/Foundation.h>

%ctor {
    // ==========================================
    // 自动获取当前注入 App 的 Bundle ID
    // ==========================================
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    
    // 兜底保护：如果获取不到 Bundle ID（极少数情况），则取消执行
    if (!bundleID || bundleID.length == 0) {
        NSLog(@"[UniversalPlistCleaner] ❌ 无法获取 Bundle ID，取消执行。");
        return;
    }
    
    // 防止注入到系统核心进程（如 SpringBoard）时误删系统配置
    NSArray *blacklist = @[
        @"com.apple.springboard",
        @"com.apple.backboardd",
        @"com.apple.Preferences",
        @"com.apple.mobilesafari"
    ];
    if ([blacklist containsObject:bundleID]) {
        NSLog(@"[UniversalPlistCleaner] ⏭️ 检测到系统进程 [%@]，跳过执行。", bundleID);
        return;
    }
    
    NSLog(@"[UniversalPlistCleaner] 🚀 目标 App Bundle ID: %@, 开始执行清理...", bundleID);
    
    // ==========================================
    // 第一重打击：调用系统 API 清空 Domain 缓存
    // ==========================================
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:bundleID];
    
    // ==========================================
    // 第二重打击：物理删除 plist 文件 (降维打击)
    // ==========================================
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    if (paths.count > 0) {
        NSString *prefsDir = [paths.firstObject stringByAppendingPathComponent:@"Preferences"];
        NSString *plistPath = [prefsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", bundleID]];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:plistPath]) {
            NSError *error = nil;
            [fileManager removeItemAtPath:plistPath error:&error];
            if (!error) {
                NSLog(@"[UniversalPlistCleaner] 🗑️ 物理删除成功: %@", plistPath);
            } else {
                NSLog(@"[UniversalPlistCleaner] ⚠️ 物理删除失败: %@", error.localizedDescription);
            }
        } else {
            NSLog(@"[UniversalPlistCleaner] ℹ️ 文件不存在，无需删除: %@", plistPath);
        }
    }
    
    // 强制同步一次，确保系统立刻刷新状态
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    NSLog(@"[UniversalPlistCleaner] ✅ 清理完成！App [%@] 将以为自己是第一次安装。", bundleID);
}
