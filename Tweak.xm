#import <Foundation/Foundation.h>

// ==========================================
// 🎯 白名单配置区 (你想保留的登录核心 Key)
// 如果以后发现掉登录了，抓包看看缺什么 Key，加到这里就行！
// ==========================================
static NSArray *const kKeysToKeep = @[
    @"login_status",
    @"flutter.accessToken",
    @"flutter.userId",
    @"token",
    @"uid",
    @"is_login",
    @"user_info"
];

%ctor {
    // 1. 获取当前注入 App 的 Bundle ID
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID || bundleID.length == 0) return;

    // 保护系统进程
    NSArray *blacklist = @[@"com.apple.springboard", @"com.apple.backboardd", @"com.apple.Preferences", @"com.apple.mobilesafari"];
    if ([blacklist containsObject:bundleID]) return;

    NSLog(@"[GhostLogin] 🚀 目标 App: %@, 开始执行【金蝉脱壳】...", bundleID);

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // ==========================================
    // 第一步：【提取】备份核心登录 Key
    // ==========================================
    NSMutableDictionary *backupData = [NSMutableDictionary dictionary];
    for (NSString *key in kKeysToKeep) {
        id value = [defaults objectForKey:key];
        if (value) {
            backupData[key] = value;
            NSLog(@"[GhostLogin] 🔑 提取到关键数据: [%@] = %@", key, value);
        }
    }
    
    if (backupData.count == 0) {
        NSLog(@"[GhostLogin] ℹ️ 未检测到任何登录 Key，说明当前是未登录状态，直接执行纯净清理。");
    }

    // ==========================================
    // 第二步：【洗白】清空内存缓存与 Domain
    // ==========================================
    [defaults removePersistentDomainForName:bundleID];

    // ==========================================
    // 第三步：【降维】物理删除 plist 文件
    // ==========================================
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    if (paths.count > 0) {
        NSString *prefsDir = [paths.firstObject stringByAppendingPathComponent:@"Preferences"];
        NSString *plistPath = [prefsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", bundleID]];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:plistPath]) {
            [fileManager removeItemAtPath:plistPath error:nil];
            NSLog(@"[GhostLogin] 🗑️ 物理删除旧 plist 成功!");
        }
    }

    // ==========================================
    // 第四步：【还魂】将备份的登录 Key 写回并刷盘
    // ==========================================
    if (backupData.count > 0) {
        for (NSString *key in backupData) {
            [defaults setObject:backupData[key] forKey:key];
        }
        NSLog(@"[GhostLogin] 💉 已将 %lu 个登录 Key 写回内存!", (unsigned long)backupData.count);
    }
    
    // 强制同步，让系统立刻生成一份只包含登录信息的“干净” plist 文件
    [defaults synchronize];
    
    NSLog(@"[GhostLogin] ✅ 【金蝉脱壳】完成！App 现在以为自己是刚安装的新设备，但拥有老用户的登录态。");
}
