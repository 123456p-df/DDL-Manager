// Uses synthetic data only; never logs in, persists settings or starts background scans.
#define main DDLApplicationMain
#import "../Sources/App.m"
#undef main
#import "../Sources/SSCourseWindow.m"
#import "../Sources/SSAssignments.h"
static NSUInteger checks;
static void Check(BOOL condition, NSString *label) { checks++; if (!condition) { fprintf(stderr, "FAIL: %s\n", label.UTF8String); exit(1); } }
static void Capture(NSView *view, NSString *path) {
    [view.window makeKeyAndOrderFront:nil];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    [view.window displayIfNeeded];
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    Check([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES], @"preview saved");
}
// Hold a synthetic scan to verify interactivity during a slow request.
@interface SlowCourseGit : SSGit
@property dispatch_semaphore_t releaseScan;
@property NSUInteger calls;
@end
@implementation SlowCourseGit
- (NSDictionary *)scanCourse:(NSDictionary *)course cache:(NSMutableDictionary *)cache error:(NSError **)error {
    self.calls++; dispatch_semaphore_wait(self.releaseScan, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return @{@"candidates":@[], @"date":NSDate.date, @"branch":@"main"};
}
@end
@interface ScanPreviewWindow : SSCourseWindow @end
@implementation ScanPreviewWindow
- (void)saveCourses {}
- (NSMutableDictionary *)readScanCache { return NSMutableDictionary.dictionary; }
- (void)writeScanCache:(NSDictionary *)cache {}
- (void)saveScanResults {}
@end
static void BackgroundScanTests(void) {
    ScanPreviewWindow *window = ScanPreviewWindow.new;
    window.courses = [@[[ @{@"fork":@"student/one", @"upstream":@"teacher/one", @"path":@"/synthetic/one"} mutableCopy], [@{@"fork":@"student/two", @"upstream":@"teacher/two", @"path":@"/synthetic/two"} mutableCopy]] mutableCopy];
    [window refreshCourses];
    NSError *cause = [NSError errorWithDomain:@"SSGit" code:2 userInfo:@{NSLocalizedDescriptionKey:@"同一个文件有不同修改，请点击处理文件冲突。", @"mergeHead":@"synthetic-tip", @"conflicts":@[@"answer.py"], @"coursePath":@"/synthetic/one"}];
    NSMutableDictionary *info = cause.userInfo.mutableCopy; info[NSUnderlyingErrorKey] = cause; info[NSLocalizedDescriptionKey] = @"同一个文件有不同修改，请点击处理文件冲突。\n作业已保存在本地，尚未上传。";
    [window showError:[NSError errorWithDomain:@"SSGit" code:2 userInfo:info]];
    Check([window.statusLabel.stringValue hasPrefix:@"同一个文件"] && [window.detail.string containsString:@"尚未上传"], @"visible status leads with cause while details retain saved-work notice");
    Check(!window.conflictButton.hidden && [window.courses[0][@"pendingMergeTip"] isEqual:@"synthetic-tip"], @"failed upload exposes recoverable conflict action");
    [window.courses[0] removeObjectForKey:@"pendingMergeTip"]; [window.courses[0] removeObjectForKey:@"pendingConflicts"]; [window refreshCourses];
    SlowCourseGit *git = SlowCourseGit.new; git.releaseScan = dispatch_semaphore_create(0); window.git = git;
    [window startAutomaticChecks]; NSTimer *timer = window.timer;
    [window startAutomaticChecks];
    Check(!window.scanning && !window.busy && git.calls == 0, @"startup only schedules checks without scanning immediately");
    Check(window.timer == timer, @"automatic check scheduling is idempotent");
    [window scan:nil]; [window scan:nil];
    Check(window.scanning && !window.busy && window.coursePicker.enabled, @"slow scan does not lock course picker or foreground work");
    for (NSButton *button in window.actionButtons) {
        if (button.action == @selector(scan:)) Check(!button.enabled && [button.title isEqual:@"查找中…"], @"scan button prevents duplicate requests");
        if (button.action == @selector(commit:) || button.action == @selector(sync:) || button.action == @selector(courseMenu:)) Check(button.enabled, @"other course actions remain available during lookup");
    }
    [window.coursePicker selectItemAtIndex:1]; [window courseChanged:nil];
    Check([[window course][@"fork"] isEqual:@"student/two"], @"course switching works during a scan");
    dispatch_semaphore_signal(git.releaseScan);
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:5];
    while (window.scanning && [limit timeIntervalSinceNow] > 0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(!window.scanning && git.calls == 1 && window.candidates[@"student/one"] != nil, @"one background result finishes without duplicate scanning");
    Check([[window course][@"fork"] isEqual:@"student/two"] && ![window.statusLabel.stringValue containsString:@"找到 0"], @"scan completion keeps selected course and its status");
    NSDictionary *savedResult = window.reports;
    window.candidates = NSMutableDictionary.dictionary; [window restoreScanResults:savedResult];
    Check(window.candidates[@"student/one"] != nil && window.reports[@"student/one"] != nil, @"saved scan result restores without a network request");
    window.candidates = NSMutableDictionary.dictionary; window.courses[0][@"path"] = @"/synthetic/moved";
    [window restoreScanResults:savedResult];
    Check(window.candidates[@"student/one"] == nil, @"cached result for a different folder is not reused");
    [window.timer invalidate];
}
int main(void) { @autoreleasepool {
    if (![NSProcessInfo.processInfo.arguments containsObject:@"--preview"]) return 2;
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    BackgroundScanTests();
    AppDelegate *app = [AppDelegate new]; NSApp.delegate = app;
    [app applicationDidFinishLaunching:[NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:NSApp]];
    Check(app.preview && !app.courseWindow, @"preview never starts GitHub checks");
    for (NSView *child in app.header.subviews) if ([child isKindOfClass:ActionButton.class] && [[(ActionButton *)child title] isEqual:@"GitHub 课程与作业"])
        Check(!NSIntersectsRect([app.header convertRect:child.frame toView:app.root], app.themePicker.frame), @"course entry does not overlap theme control");
    SSCourseWindow *courses = SSCourseWindow.new;
    courses.courses = NSMutableArray.array; [courses refreshCourses];
    Check(courses.visible.count == 0, @"empty course list is safe");
    Check(!courses.reviewButton.enabled && !courses.emptyLabel.hidden, @"empty view explains next step and disables reminder action");
    Check(courses.conflictButton.hidden, @"conflict action hidden during normal use");
    NSMutableDictionary *course = [@{@"fork":@"student/course", @"upstream":@"teacher/course", @"branch":@"main", @"upstreamBranch":@"main", @"enabled":@YES, @"path":@"/示例/课程", @"lastScan":NSDate.date} mutableCopy];
    [courses.courses addObject:course];
    course[@"pendingMergeTip"] = @"synthetic-merge"; [courses refreshCourses];
    Check(!courses.conflictButton.hidden && courses.conflictButton.enabled, @"pending merge exposes conflict action");
    [course removeObjectForKey:@"pendingMergeTip"];
    NSDate *due = DDLParseDate(@"2026-10-08 23:59", NSDate.date, Cal());
    NSDictionary *candidate = @{@"id":@"teacher/course|README.md|作业一|1", @"title":@"作业一 · 实验报告", @"due":due, @"repository":@"teacher/course", @"path":@"README.md", @"line":@12, @"blobSHA":@"version1", @"needsDate":@NO, @"needsTime":@NO, @"snippet":@"## 作业一 · 实验报告\n截止时间：2026-10-08 23:59\n提交实验报告和源代码。"};
    courses.candidates[course[@"fork"]] = @[candidate];
    courses.tasksProvider = ^NSArray * { return [app snapshot]; };
    __block NSDictionary *reviewed;
    courses.reviewCandidate = ^(NSDictionary *value) { reviewed = value; };
    [courses refreshCourses]; [courses show];
    [courses.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO]; [courses candidateSelected:nil];
    Check([courses.detail.string containsString:@"README.md:12"], @"source snippet and line displayed");
    Check([[courses stateForCandidate:candidate] isEqual:@"待添加"], @"discovery needs review");
    NSUInteger before = app.tasks.count;
    [courses review:nil]; Check(reviewed != nil && app.tasks.count == before, @"review only delivers a draft");
    [app reviewGitHubCandidate:reviewed];
    Check(app.editor && app.tasks.count == before, @"review editor does not silently import");
    Check([app.editor.task[@"announcedDue"] isEqual:due] && [app.editor.task[@"sourceID"] isEqual:candidate[@"id"]], @"teacher deadline and provenance retained");
    [app.editor save:nil];
    Check(app.tasks.count == before + 1, @"explicit save imports task");
    Check([[courses stateForCandidate:candidate] isEqual:@"已添加"], @"same source version does not duplicate");
    NSMutableDictionary *saved = app.tasks.lastObject;
    saved[@"due"] = [due dateByAddingTimeInterval:-3 * 3600]; saved[@"leadDays"] = @(-1); saved[@"title"] = @"我的自定义标题";
    NSMutableDictionary *updated = candidate.mutableCopy; updated[@"blobSHA"] = @"version2"; updated[@"due"] = [due dateByAddingTimeInterval:86400];
    Check([[courses stateForCandidate:updated] isEqual:@"有更新"], @"changed source presents update suggestion");
    [app reviewGitHubCandidate:updated];
    Check([app.editor.task[@"due"] isEqual:saved[@"due"]] && [app.editor.task[@"title"] isEqual:@"我的自定义标题"], @"update draft preserves manually edited task");
    Check([saved[@"sourceBlobSHA"] isEqual:@"version1"], @"review alone never overwrites source state");
    [app closeEditor];
    [courses.window setContentSize:NSMakeSize(1200, 800)];
    Check(NSMaxY(courses.table.enclosingScrollView.frame) <= NSMinY(courses.statusLabel.frame), @"resized table does not overlap controls");
    Check(NSMaxY(courses.detail.enclosingScrollView.frame) < NSMinY(courses.table.enclosingScrollView.frame), @"details remain below table");
    NSDictionary *weekly = [SSAssignmentsFromDocument(@"# 规则\n- 截止时间：本周日 21:00\n# 任务\n完成附件作业：运动学基础和牛顿定律。", @"teacher/course", @"assignment-04.md", @"v1", NSDate.date, Cal()) firstObject];
    courses.candidates[course[@"fork"]] = @[weekly]; [courses refreshCourses];
    NSTextField *dueLabel = (NSTextField *)[courses tableView:courses.table viewForTableColumn:[courses.table tableColumnWithIdentifier:@"due"] row:0];
    Check([dueLabel.stringValue isEqual:@"本周日 21:00 · 待确认"], @"relative deadline displays teacher wording instead of unknown deadline");
    [courses.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO]; [courses candidateSelected:nil];
    Check([courses.detail.string containsString:@"牛顿定律"] && [courses.detail.string containsString:@"本周日 21:00"], @"relative deadline and assignment instructions are visible together");
    Check(courses.table.tableColumns.count == 3, @"source location stays in details instead of crowding table");
    Check(NSMaxY(courses.detail.enclosingScrollView.frame) < NSMinY(courses.reviewButton.frame), @"reminder action stays above full-width source preview");
    Capture(courses.window.contentView, @"build/qa/github-courses.png");
    courses.candidates[course[@"fork"]] = @[];
    courses.reports = @{course[@"fork"]:@{@"candidates":@[]}, @"student/other":@{@"error":@"other course failure"}};
    [courses refreshCourses];
    Check([courses.statusLabel.stringValue hasPrefix:@"找到 0 项作业"] && ![courses.statusLabel.stringValue containsString:@"other"], @"summary only describes selected course");
    Check([courses.emptyLabel.stringValue isEqual:@"暂未找到带截止日期的作业"], @"completed empty scan has a clear result");
    Check([courses.detail.string isEqual:@"选一项作业，查看老师的具体要求。"], @"empty preview uses one short sentence");
    CurrentTheme = 5; [courses refreshTheme];
    Capture(courses.window.contentView, @"build/qa/github-courses-empty.png");
    [course removeObjectForKey:@"path"]; [courses refreshCourses];
    Check([courses.statusLabel.stringValue containsString:@"下载课程到新文件夹"] && ![courses.statusLabel.stringValue containsString:@"克隆"], @"setup guidance uses exact visible menu labels");
    CurrentTheme = 1;

    Capture(app.root, @"build/qa/ddl-calendar.png");
    [courses.window orderOut:nil]; [app.window orderOut:nil]; [app.ticker invalidate]; [NSStatusBar.systemStatusBar removeStatusItem:app.statusItem];
    printf("PASS: %lu homework AppKit assertions\n", (unsigned long)checks);
} return 0; }
