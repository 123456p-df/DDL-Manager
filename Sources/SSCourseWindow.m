#import "SSCourseWindow.h"
#import "SSGit.h"
#import "SSGitHub.h"
#import "SSLocalData.h"
#import "DDLCore.h"

extern NSColor *DDLCourseColor(NSString *role);
@interface SSCourseSurface : NSView
@property BOOL card;
@end
@implementation SSCourseSurface
- (void)drawRect:(NSRect)rect {
    [DDLCourseColor(self.card ? @"panel" : @"canvas") setFill];
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:self.card ? 16 : 0 yRadius:self.card ? 16 : 0];
    [path fill]; if (self.card) { [DDLCourseColor(@"line") setStroke]; [path stroke]; }
}
@end
@interface SSCourseButton : NSButton @end
@implementation SSCourseButton
- (void)drawRect:(NSRect)rect {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:8 yRadius:8];
    [DDLCourseColor(self.highlighted ? @"tint" : @"panel") setFill]; [path fill];
    [DDLCourseColor(@"line") setStroke]; [path stroke];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new]; style.alignment = NSTextAlignmentCenter;
    [self.title drawInRect:NSMakeRect(6, (NSHeight(self.bounds)-18)/2, NSWidth(self.bounds)-12, 20)
        withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSForegroundColorAttributeName:DDLCourseColor(self.enabled ? @"accent" : @"muted"), NSParagraphStyleAttributeName:style}];
    if (self.window.firstResponder == self) { [DDLCourseColor(@"accent") setStroke]; [path stroke]; }
}
@end
static NSTextField *SSLabel(NSString *text, NSRect frame, CGFloat size) {
    NSTextField *label = [NSTextField labelWithString:text]; label.frame = frame;
    label.font = [NSFont systemFontOfSize:size]; label.textColor = DDLCourseColor(@"ink");
    label.lineBreakMode = NSLineBreakByTruncatingTail; return label;
}
static NSButton *SSButton(NSString *text, id target, SEL action, NSRect frame) {
    NSButton *button = [[SSCourseButton alloc] initWithFrame:frame]; button.title = text; button.target = target; button.action = action;
    button.bordered = NO; [button setButtonType:NSButtonTypeMomentaryPushIn]; return button;
}

@interface SSCourseWindow ()
@property SSGitHub *github;
@property SSGit *git;
@property NSMutableArray<NSMutableDictionary *> *courses;
@property NSMutableDictionary<NSString *, NSArray *> *candidates;
@property NSArray<NSDictionary *> *availableForks;
@property dispatch_queue_t queue;
@property NSPopUpButton *coursePicker;
@property NSTableView *table;
@property NSTextView *detail;
@property NSTextField *accountLabel;
@property NSTextField *statusLabel;
@property NSTimer *timer;
@property BOOL busy;
@property BOOL scanning;
@property BOOL loginActive;
@property NSArray<NSButton *> *actionButtons;
@property NSDictionary *reports;
@property NSButton *reviewButton;
@property NSButton *conflictButton;
@property NSTextField *emptyLabel;
@end

@implementation SSCourseWindow
- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1040, 700)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        window.title = @"DDL-Manager · GitHub 课程";
        window.minSize = NSMakeSize(1040, 700); window.releasedWhenClosed = NO;
        self.github = [SSGitHub new]; self.git = [SSGit new];
        NSArray *saved = SSReadPlist(@"courses.plist");
        self.courses = NSMutableArray.array;
        for (id item in [saved isKindOfClass:NSArray.class] ? saved : @[]) if ([item isKindOfClass:NSDictionary.class] && [item[@"fork"] isKindOfClass:NSString.class]) [self.courses addObject:[item mutableCopy]];
        __weak typeof(self) weakSelf = self;
        self.git.identityVerifier = ^NSDictionary *(NSDictionary *course, NSError **error) { return [weakSelf.github verifyCourse:course error:error]; };
        self.candidates = NSMutableDictionary.dictionary;
        [self restoreScanResults:SSReadPlist(@"scan-results.plist")];
        self.queue = dispatch_queue_create("ss.homework.course-work", DISPATCH_QUEUE_SERIAL);
        [self buildUI]; [self refreshCourses];
    }
    return self;
}
- (void)restoreScanResults:(NSDictionary *)results {
    NSMutableDictionary *reports = NSMutableDictionary.dictionary;
    if ([results isKindOfClass:NSDictionary.class]) for (NSMutableDictionary *course in self.courses) {
        NSDictionary *report = results[course[@"fork"]];
        if (![report isKindOfClass:NSDictionary.class] || ![report[@"candidates"] isKindOfClass:NSArray.class]) continue;
        if (![report[@"coursePath"] isEqual:course[@"path"]] || ![report[@"upstream"] isEqual:course[@"upstream"]]) continue;
        reports[course[@"fork"]] = report; self.candidates[course[@"fork"]] = report[@"candidates"];
        if ([report[@"date"] isKindOfClass:NSDate.class]) course[@"lastScan"] = report[@"date"];
    }
    self.reports = reports;
}
- (void)buildUI {
    NSView *view = [[SSCourseSurface alloc] initWithFrame:NSMakeRect(0, 0, 1040, 700)];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; self.window.contentView = view;
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    [view addSubview:SSLabel(@"课程与作业", NSMakeRect(28, 645, 400, 32), 25)];
    self.accountLabel = SSLabel(@"GitHub：未登录", NSMakeRect(730, 651, 282, 22), 12); self.accountLabel.alignment = NSTextAlignmentRight; [view addSubview:self.accountLabel];
    [view addSubview:SSButton(@"账号与授权 ▾", self, @selector(accountMenu:), NSMakeRect(852, 614, 160, 30))];
    SSCourseSurface *card = [[SSCourseSurface alloc] initWithFrame:NSMakeRect(20, 469, 1000, 126)]; card.card = YES; card.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin; [view addSubview:card];
    self.coursePicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(38, 545, 480, 30) pullsDown:NO];
    self.coursePicker.target = self; self.coursePicker.action = @selector(courseChanged:); [view addSubview:self.coursePicker];
    [view addSubview:SSButton(@"添加课程", self, @selector(addFork:), NSMakeRect(720, 545, 120, 30))];
    [view addSubview:SSButton(@"课程设置 ▾", self, @selector(courseMenu:), NSMakeRect(852, 545, 150, 30))];
    [view addSubview:SSButton(@"↓ 更新课程文件", self, @selector(sync:), NSMakeRect(38, 494, 195, 36))];
    [view addSubview:SSButton(@"↑ 上传作业…", self, @selector(commit:), NSMakeRect(245, 494, 180, 36))];
    [view addSubview:SSButton(@"打开课程文件夹", self, @selector(openFolder:), NSMakeRect(437, 494, 170, 36))];
    self.conflictButton = SSButton(@"处理文件冲突…", self, @selector(continueMerge:), NSMakeRect(805, 494, 197, 36)); [view addSubview:self.conflictButton];
    [view addSubview:SSLabel(@"老师布置的作业", NSMakeRect(28, 414, 420, 28), 18)];
    [view addSubview:SSLabel(@"选一项作业，就能添加截止提醒。", NSMakeRect(28, 383, 650, 22), 12)];
    [view addSubview:SSButton(@"查找截止日期", self, @selector(scan:), NSMakeRect(852, 407, 160, 34))];
    self.statusLabel = SSLabel(@"先添加课程。", NSMakeRect(28, 337, 984, 28), 12); [view addSubview:self.statusLabel];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(28, 175, 984, 152)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; scroll.hasVerticalScroller = YES;
    scroll.borderType = NSNoBorder;
    self.table = [[NSTableView alloc] initWithFrame:scroll.bounds]; self.table.delegate = self; self.table.dataSource = self;
    self.table.rowHeight = 40; self.table.intercellSpacing = NSMakeSize(12, 4); self.table.usesAlternatingRowBackgroundColors = NO;
    for (NSArray *spec in @[@[@"title", @"作业", @510], @[@"due", @"截止时间", @270], @[@"state", @"提醒", @180]]) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        column.title = spec[1]; column.width = [spec[2] doubleValue]; [self.table addTableColumn:column];
    }
    self.table.headerView = [[NSTableHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 984, 28)];
    self.table.target = self; self.table.action = @selector(candidateSelected:);
    scroll.documentView = self.table; [view addSubview:scroll];
    self.emptyLabel = SSLabel(@"点击“查找截止日期”，看看老师布置了什么", NSMakeRect(60, 230, 900, 28), 14);
    self.emptyLabel.alignment = NSTextAlignmentCenter; self.emptyLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin; [view addSubview:self.emptyLabel];
    NSScrollView *detailScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(28, 28, 984, 90)];
    detailScroll.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin; detailScroll.hasVerticalScroller = YES;
    self.detail = [[NSTextView alloc] initWithFrame:detailScroll.bounds]; self.detail.editable = NO;
    self.detail.textContainerInset = NSMakeSize(12, 10); self.detail.font = [NSFont systemFontOfSize:12];
    detailScroll.documentView = self.detail; [view addSubview:detailScroll];
    self.reviewButton = SSButton(@"添加提醒…", self, @selector(review:), NSMakeRect(804, 128, 208, 34));
    self.reviewButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin; [view addSubview:self.reviewButton];
    [view addSubview:SSLabel(@"老师原文", NSMakeRect(28, 132, 400, 24), 13)];
    NSMutableArray *buttons = NSMutableArray.array;
    for (NSView *child in view.subviews) {
        if (NSMinY(child.frame) >= 337 && ![child isKindOfClass:SSCourseSurface.class]) child.autoresizingMask = NSViewMinYMargin | (NSMinX(child.frame) >= 720 ? NSViewMinXMargin : NSViewMaxXMargin);
        if ([child isKindOfClass:NSButton.class]) [buttons addObject:child];
    }
    self.coursePicker.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.actionButtons = buttons; [self refreshTheme];
}
- (void)refreshTheme {
    self.window.backgroundColor = DDLCourseColor(@"canvas");
    self.table.backgroundColor = DDLCourseColor(@"canvas");
    self.detail.backgroundColor = DDLCourseColor(@"panel"); self.detail.textColor = DDLCourseColor(@"ink");
    for (NSView *child in self.window.contentView.subviews) {
        child.needsDisplay = YES;
        if ([child isKindOfClass:NSTextField.class]) [(NSTextField *)child setTextColor:DDLCourseColor(@"ink")];
    }
    self.window.contentView.needsDisplay = YES; [self.table reloadData];
    self.table.headerView.needsDisplay = YES; self.table.enclosingScrollView.needsDisplay = YES;
}
- (void)updateActions {
    NSDictionary *course = [self course]; BOOL linked = [course[@"path"] length] > 0;
    BOOL merging = [course[@"pendingMergeTip"] length] > 0;
    for (NSButton *button in self.actionButtons) {
        SEL action = button.action; BOOL ready = YES;
        if (action == @selector(courseMenu:)) ready = course != nil;
        if (action == @selector(sync:) || action == @selector(commit:) || action == @selector(scan:) || action == @selector(openFolder:)) ready = linked;
        if (action == @selector(sync:) || action == @selector(commit:)) ready = ready && !merging;
        if (action == @selector(scan:)) {
            ready = ready && !self.scanning;
            button.title = self.scanning ? @"查找中…" : @"查找截止日期";
        }
        button.enabled = !self.busy && ready;
    }
    self.conflictButton.hidden = !merging;
    self.reviewButton.enabled = !self.busy && self.table.selectedRow >= 0;
    self.emptyLabel.hidden = self.visible.count > 0;
    self.emptyLabel.stringValue = !course ? @"添加课程后，作业会显示在这里" : (!linked ? @"先在“课程设置”中下载或关联课程文件夹" : (course[@"lastScan"] ? @"暂未找到带截止日期的作业" : @"点击“查找截止日期”，看看老师布置了什么"));
}
- (void)showMenu:(NSButton *)sender items:(NSArray *)items {
    NSMenu *menu = NSMenu.new;
    for (NSArray *spec in items) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:spec[0] action:NSSelectorFromString(spec[1]) keyEquivalent:@""]; item.target = self; [menu addItem:item];
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:sender];
}
- (void)accountMenu:(NSButton *)sender {
    if (self.loginActive) { [self cancelLogin:nil]; return; }
    [self showMenu:sender items:@[@[@"登录 GitHub…", @"login:"], @[@"授权课程仓库…", @"installApp:"], @[@"退出登录", @"signOut:"], @[@"开发者配置…", @"setClientID:"]]];
}
- (void)courseMenu:(NSButton *)sender {
    [self showMenu:sender items:@[@[@"关联已有课程文件夹…", @"linkFolder:"], @[@"下载课程到新文件夹…", @"cloneFork:"], @[@"查看详情", @"report:"], @[[[self course][@"enabled"] isEqual:@NO] ? @"开启自动查找截止日期（每 6 小时）" : @"暂停自动查找截止日期", @"toggleCourse:"], @[@"重试上传已提交的内容", @"push:"], @[@"移除课程关联…", @"removeCourse:"]]];
}
- (void)show { [self showWindow:nil]; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
- (void)startAutomaticChecks {
    if (self.timer) return;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:6 * 3600 target:self selector:@selector(scanAll:) userInfo:nil repeats:YES];
}
- (void)saveCourses { NSError *error = nil; if (!SSWritePlist(@"courses.plist", self.courses, &error)) [self showError:error]; }
- (NSMutableDictionary *)savedCourse:(NSDictionary *)course { for (NSMutableDictionary *saved in self.courses) if ([saved[@"fork"] isEqual:course[@"fork"]]) return saved; return nil; }
- (NSDictionary *)course { NSInteger index = self.coursePicker.indexOfSelectedItem; return index >= 0 && index < (NSInteger)self.courses.count ? self.courses[index] : nil; }
- (NSArray *)visible { NSString *fork = [self course][@"fork"]; return fork ? (self.candidates[fork] ?: @[]) : @[]; }
- (void)refreshCourses {
    NSInteger old = self.coursePicker.indexOfSelectedItem;
    [self.coursePicker removeAllItems];
    for (NSDictionary *course in self.courses) [self.coursePicker addItemWithTitle:course[@"fork"] ?: @"课程"];
    if (self.courses.count) [self.coursePicker selectItemAtIndex:MIN(MAX(old, 0), (NSInteger)self.courses.count - 1)];
    NSDictionary *course = [self course];
    if (!course) self.statusLabel.stringValue = @"先登录，再点击“添加课程”。";
    else if (![course[@"path"] length]) self.statusLabel.stringValue = @"在“课程设置”中选择“下载课程到新文件夹”或“关联已有课程文件夹”。";
    else {
        NSDictionary *report = self.reports[course[@"fork"]];
        NSDate *last = course[@"lastScan"];
        if (report[@"error"]) self.statusLabel.stringValue = @"查找失败，可在“课程设置 → 查看详情”中查看原因。";
        else if (last && self.candidates[course[@"fork"]]) self.statusLabel.stringValue = [NSString stringWithFormat:@"找到 %lu 项作业 · %@%@", (unsigned long)self.visible.count, DDLFormatDate(last, @"M月d日 HH:mm"), [course[@"enabled"] isEqual:@NO] ? @" · 自动查找已暂停" : @""];
        else self.statusLabel.stringValue = @"点击“查找截止日期”读取老师布置的作业。";
    }
    self.statusLabel.toolTip = nil;
    [self.table reloadData]; [self candidateSelected:nil]; [self updateActions];
}
- (void)status:(NSString *)message { self.statusLabel.stringValue = message ?: @""; self.statusLabel.toolTip = message; [self updateActions]; }
- (void)showError:(NSError *)error { if (error) { [self status:error.localizedDescription]; self.detail.string = error.localizedDescription; } }
- (void)work:(NSString *)message operation:(id (^)(NSError **))operation completion:(void (^)(id, NSError *))completion {
    if (self.busy) { [self status:@"已有操作正在执行，请稍候。"] ; return; }
    self.busy = YES; [self status:message];
    for (NSButton *button in self.actionButtons) button.enabled = NO;
    self.coursePicker.enabled = NO;
    // Allow cancelling a device login while the worker waits for GitHub.
    for (NSButton *button in self.actionButtons) if (button.action == @selector(accountMenu:) && self.loginActive) { button.enabled = YES; button.title = @"取消登录"; }
    dispatch_async(self.queue, ^{
        NSError *error = nil; id value = operation(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO; for (NSButton *button in self.actionButtons) button.enabled = YES; self.coursePicker.enabled = YES;
            for (NSButton *button in self.actionButtons) if (button.action == @selector(accountMenu:)) button.title = @"账号与授权 ▾";
            completion(value, error); [self updateActions];
        });
    });
}
- (void)setClientID:(id)sender {
    NSAlert *alert = [NSAlert new]; alert.messageText = @"GitHub App Client ID";
    alert.informativeText = @"填写开发者注册的 GitHub App 公开 Client ID 和安装链接。注册说明位于 docs/GITHUB_APP_SETUP.md。不要填写密钥或个人令牌。";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 42, 440, 28)]; field.stringValue = self.github.clientID ?: @"";
    NSTextField *install = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 440, 28)]; install.stringValue = self.github.installationURL ?: @""; install.placeholderString = @"https://github.com/apps/应用名称/installations/new";
    NSView *settings = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 70)]; [settings addSubview:field]; [settings addSubview:install];
    alert.accessoryView = settings; [alert addButtonWithTitle:@"保存"]; [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSString *identifier = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([identifier rangeOfString:@"^Iv[A-Za-z0-9.]{10,80}$" options:NSRegularExpressionSearch].location == NSNotFound) { [self status:@"Client ID 格式无效"]; return; }
    NSString *installationURL = [install.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (installationURL.length && [installationURL rangeOfString:@"^https://github\\.com/apps/[a-z0-9-]+/installations/new$" options:NSRegularExpressionSearch].location == NSNotFound) { [self status:@"安装页面链接格式无效。"]; return; }
    NSError *error = nil;
    if (!SSWritePlist(@"settings.plist", @{@"clientID":identifier, @"installationURL":installationURL}, &error)) { [self showError:error]; return; }
    self.github.clientID = identifier; self.github.installationURL = installationURL; [self status:@"已保存公开应用信息。请先安装授权，再登录。"];
}
- (void)login:(id)sender {
    [self work:@"正在登录 GitHub…" operation:^id(NSError **error) { return [self.github beginDeviceLogin:error]; } completion:^(NSDictionary *challenge, NSError *error) {
        if (!challenge) { [self showError:error]; return; }
        NSAlert *alert = [NSAlert new]; alert.messageText = [@"请在 GitHub 输入代码 " stringByAppendingString:challenge[@"user_code"] ?: @""];
        alert.informativeText = @"在浏览器中输入这段代码，允许软件访问你的课程仓库。";
        [alert addButtonWithTitle:@"打开 GitHub 并等待授权"]; [alert addButtonWithTitle:@"取消"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/login/device"]];
        self.loginActive = YES;
        [self work:@"等待 GitHub 授权…" operation:^id(NSError **innerError) { return @([self.github completeDeviceLogin:challenge error:innerError]); } completion:^(NSNumber *ok, NSError *innerError) {
            self.loginActive = NO;
            if (!ok.boolValue) { [self showError:innerError]; return; }
            self.accountLabel.stringValue = @"GitHub：已登录";
            [self status:@"GitHub 登录成功。请添加课程。"];
        }];
    }];
}
- (void)cancelLogin:(id)sender { if (self.loginActive) { [self.github cancelDeviceLogin]; [self status:@"正在取消登录…"]; } }
- (void)signOut:(id)sender { [self.github signOut]; self.accountLabel.stringValue = @"GitHub：未登录"; [self status:@"已退出登录；本地课程和 DDL 已保留。"] ; }
- (void)addFork:(id)sender {
    [self work:@"正在读取可添加的课程…" operation:^id(NSError **error) { return [self.github accessibleForks:error]; } completion:^(NSArray *forks, NSError *error) {
        if (!forks) { [self showError:error]; return; }
        self.availableForks = forks;
        self.accountLabel.stringValue = [NSString stringWithFormat:@"GitHub：已登录 · %lu 个课程", (unsigned long)forks.count];
        NSMutableArray *choices = [NSMutableArray array];
        for (NSDictionary *repo in forks) if (![self courseExists:repo[@"full_name"]]) [choices addObject:repo];
        if (!choices.count) { [self status:@"没有可添加的课程。请在“账号与授权 → 授权课程仓库”中选择你的课程仓库。"] ; return; }
        NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 410, 28) pullsDown:NO];
        for (NSDictionary *repo in choices) [picker addItemWithTitle:repo[@"full_name"]];
        NSAlert *alert = [NSAlert new]; alert.messageText = @"添加课程"; alert.accessoryView = picker;
        [alert addButtonWithTitle:@"添加"]; [alert addButtonWithTitle:@"取消"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
        NSDictionary *choice = choices[picker.indexOfSelectedItem];
        [self work:@"正在确认课程来源…" operation:^id(NSError **innerError) { return [self.github repository:choice[@"full_name"] error:innerError]; } completion:^(NSDictionary *details, NSError *innerError) {
            NSDictionary *parent = details[@"parent"];
            if (![parent isKindOfClass:NSDictionary.class] || ![parent[@"full_name"] isKindOfClass:NSString.class]) { [self status:@"未找到对应的老师课程，请选择从老师课程复制到自己账号的仓库。"] ; return; }
            if (!details[@"id"] || !parent[@"id"] || !details[@"owner"][@"id"]) { [self status:@"GitHub 未返回完整仓库身份，不能添加。"]; return; }
            NSMutableDictionary *course = [@{@"enabled":@YES, @"fork":details[@"full_name"], @"upstream":parent[@"full_name"], @"forkID":details[@"id"], @"upstreamID":parent[@"id"], @"ownerID":details[@"owner"][@"id"], @"timeZone":NSTimeZone.localTimeZone.name,
                @"branch":details[@"default_branch"] ?: @"main", @"upstreamBranch":parent[@"default_branch"] ?: @"main",
                @"upstreamURL":parent[@"clone_url"] ?: @""} mutableCopy];
            [self.courses addObject:course]; [self saveCourses]; [self refreshCourses];
            [self.coursePicker selectItemAtIndex:self.courses.count - 1]; [self refreshCourses];
            [self status:@"已添加课程。在“课程设置”中选择“下载课程到新文件夹”或“关联已有课程文件夹”。"];
        }];
    }];
}
- (BOOL)courseExists:(NSString *)fork { for (NSDictionary *course in self.courses) if ([course[@"fork"] caseInsensitiveCompare:fork] == NSOrderedSame) return YES; return NO; }
- (void)courseChanged:(id)sender { [self refreshCourses]; }
- (void)linkFolder:(id)sender {
    NSDictionary *current = [self course]; if (!current) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel]; panel.canChooseDirectories = YES; panel.canChooseFiles = NO; panel.allowsMultipleSelection = NO;
    if ([panel runModal] != NSModalResponseOK) return;
    NSMutableDictionary *course = [current mutableCopy]; course[@"path"] = panel.URL.path;
    [self work:@"正在关联课程文件夹…" operation:^id(NSError **error) { return @([self.git linkCourse:course error:error]); } completion:^(NSNumber *ok, NSError *error) {
        if (!ok.boolValue) { [self showError:error]; return; }
        NSMutableDictionary *saved = [self savedCourse:current]; [saved setDictionary:course]; [self saveCourses]; [self refreshCourses];
        [self status:@"已关联课程文件夹。可以更新课程或上传作业了。"];
    }];
}
- (void)cloneFork:(id)sender {
    NSDictionary *current = [self course]; if (!current) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel]; panel.canChooseDirectories = YES; panel.canChooseFiles = NO; panel.message = @"选择课程文件的保存位置";
    if ([panel runModal] != NSModalResponseOK) return;
    NSString *destination = [panel.URL.path stringByAppendingPathComponent:[current[@"fork"] lastPathComponent]];
    NSMutableDictionary *course = [current mutableCopy]; course[@"path"] = destination;
    NSAlert *transport = [NSAlert new]; transport.messageText = @"如何访问老师的课程？";
    transport.informativeText = @"一般选择 HTTPS。如果你已经配置了 SSH，也可以使用 SSH。";
    [transport addButtonWithTitle:@"HTTPS · Git 钥匙串"]; [transport addButtonWithTitle:@"SSH · 本机密钥"]; [transport addButtonWithTitle:@"取消"];
    NSModalResponse response = [transport runModal]; if (response == NSAlertThirdButtonReturn) return;
    course[@"upstreamURL"] = response == NSAlertSecondButtonReturn ? [NSString stringWithFormat:@"git@github.com:%@.git", course[@"upstream"]] : [NSString stringWithFormat:@"https://github.com/%@.git", course[@"upstream"]];
    [self work:@"正在下载课程文件…" operation:^id(NSError **error) {
        NSString *token = [self.github accessToken:error]; if (!token) return nil;
        if (![self.git cloneFork:course into:destination token:token error:error]) return @{@"cloned":@NO};
        return @{@"cloned":@YES, @"linked":@([self.git linkCourse:course error:error])};
    } completion:^(NSDictionary *result, NSError *error) {
        if ([result[@"cloned"] boolValue]) { [[self savedCourse:current] setDictionary:course]; [self saveCourses]; [self refreshCourses]; }
        if (![result[@"linked"] boolValue]) { [self showError:error]; return; }
        [self status:@"课程已下载。可以更新课程或上传作业了。"];
    }];
}
- (void)removeCourse:(id)sender {
    NSInteger index = self.coursePicker.indexOfSelectedItem; if (index < 0) return;
    NSAlert *alert = [NSAlert new]; alert.messageText = @"移除课程关联？"; alert.informativeText = @"不会删除本地仓库或已添加的 DDL。";
    [alert addButtonWithTitle:@"移除"]; [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [self.courses removeObjectAtIndex:index]; [self saveCourses]; [self refreshCourses];
}
- (void)scan:(id)sender { [self scanCourses:@[[self course] ?: @{}]]; }
- (void)toggleCourse:(id)sender {
    NSMutableDictionary *course = [self savedCourse:[self course]]; if (!course) return;
    course[@"enabled"] = @(course[@"enabled"] ? ![course[@"enabled"] boolValue] : NO); [self saveCourses]; [self refreshCourses];
}
- (void)installApp:(id)sender {
    NSURL *url = [NSURL URLWithString:self.github.installationURL];
    if ([url.scheme isEqual:@"https"] && [url.host isEqual:@"github.com"] && [url.path hasPrefix:@"/apps/"]) [NSWorkspace.sharedWorkspace openURL:url];
    else [self status:@"尚未配置安装页面。开发者请按仓库 docs/GITHUB_APP_SETUP.md 注册后填写公开安装链接。"];
}
- (void)scanAll:(id)sender {
    if (self.busy || self.scanning) return;
    NSMutableArray *enabled = NSMutableArray.array;
    for (NSDictionary *course in self.courses) if (!course[@"enabled"] || [course[@"enabled"] boolValue]) [enabled addObject:[course copy]];
    [self scanCourses:enabled];
}
- (NSMutableDictionary *)readScanCache {
    id cache = SSReadPlist(@"scan-cache.plist");
    return [cache isKindOfClass:NSDictionary.class] ? [cache mutableCopy] : NSMutableDictionary.dictionary;
}
- (void)writeScanCache:(NSDictionary *)cache { SSWritePlist(@"scan-cache.plist", cache, NULL); }
- (void)saveScanResults {
    // Keep the last successful result when a later network request fails.
    id stored = SSReadPlist(@"scan-results.plist");
    NSMutableDictionary *results = [stored isKindOfClass:NSDictionary.class] ? [stored mutableCopy] : NSMutableDictionary.dictionary;
    NSMutableSet *active = NSMutableSet.set;
    for (NSDictionary *course in self.courses) {
        NSString *fork = course[@"fork"]; [active addObject:fork];
        NSDictionary *report = self.reports[fork];
        if (report && !report[@"error"]) results[fork] = report;
    }
    for (NSString *fork in results.allKeys) if (![active containsObject:fork]) [results removeObjectForKey:fork];
    SSWritePlist(@"scan-results.plist", results, NULL);
}
- (void)scanCourses:(NSArray *)courses {
    if (self.busy || self.scanning) return;
    NSMutableArray *snapshots = NSMutableArray.array;
    for (NSDictionary *course in courses) if ([course[@"path"] length] && [course[@"fork"] length]) [snapshots addObject:[course copy]];
    if (!snapshots.count) return;
    self.scanning = YES; [self updateActions];
    dispatch_async(self.queue, ^{
        NSMutableDictionary *cache = [self readScanCache];
        NSMutableDictionary *result = NSMutableDictionary.dictionary;
        for (NSDictionary *course in snapshots) {
            NSError *scanError = nil;
            NSDictionary *scan = [self.git scanCourse:course cache:cache error:&scanError];
            NSMutableDictionary *report = [scan mutableCopy] ?: [@{@"error":scanError.localizedDescription ?: @"查找失败"} mutableCopy];
            report[@"coursePath"] = course[@"path"]; report[@"upstream"] = course[@"upstream"];
            result[course[@"fork"]] = report;
        }
        [self writeScanCache:cache];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanning = NO;
            NSMutableDictionary *reports = [self.reports mutableCopy] ?: NSMutableDictionary.dictionary;
            for (NSMutableDictionary *course in self.courses) {
                NSDictionary *scan = result[course[@"fork"]]; if (!scan) continue;
                // A removed or re-linked course must not receive an obsolete scan.
                if (![scan[@"coursePath"] isEqual:course[@"path"]] || ![scan[@"upstream"] isEqual:course[@"upstream"]]) continue;
                reports[course[@"fork"]] = scan;
                if (scan[@"error"]) continue;
                self.candidates[course[@"fork"]] = scan[@"candidates"] ?: @[];
                course[@"lastScan"] = scan[@"date"];
                if (scan[@"branch"]) course[@"upstreamBranch"] = scan[@"branch"];
            }
            self.reports = reports;
            [self saveCourses]; [self saveScanResults];
            // Do not replace the status of an upload/login queued during the scan.
            if (!self.busy) [self refreshCourses]; else [self updateActions];
        });
    });
}
- (void)sync:(id)sender {
    NSDictionary *course = [self course]; if (!course) return;
    [self work:@"正在更新课程文件…" operation:^id(NSError **error) {
        NSString *token = [self.github accessToken:error]; if (!token) return nil;
        return [self.git syncCourse:course token:token error:error];
    } completion:^(NSDictionary *result, NSError *error) {
        if (result[@"conflicts"]) {
            NSMutableDictionary *saved = [self savedCourse:course]; saved[@"pendingMergeTip"] = result[@"mergeHead"]; saved[@"pendingConflicts"] = result[@"conflicts"]; [self saveCourses];
            [self showError:error]; [self conflictGuide:course];
        }
        else if (!result) [self showError:error];
        else if (result[@"metadataRestoreWarning"]) [self status:result[@"metadataRestoreWarning"]];
        else { [self status:@"课程文件已更新。"] ; [self scan:nil]; }
    }];
}
- (void)continueMerge:(id)sender { NSDictionary *course = [self course]; if (course) [self conflictGuide:course]; }
- (void)finishMerge:(NSDictionary *)course {
    [self work:@"正在保存处理结果并上传…" operation:^id(NSError **error) {
        NSString *token = [self.github accessToken:error]; if (!token) return @NO;
        return @([self.git continueMergeForCourse:course token:token error:error]);
    } completion:^(NSNumber *ok, NSError *error) { if (ok.boolValue) { NSMutableDictionary *saved = [self savedCourse:course]; [saved removeObjectForKey:@"pendingMergeTip"]; [saved removeObjectForKey:@"pendingConflicts"]; [self saveCourses]; [self status:@"文件冲突已解决，内容已上传。"] ; } else [self showError:error]; }];
}
- (void)openFolder:(id)sender { NSString *path = [self course][@"path"]; if (path.length) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path]]; }
- (void)report:(id)sender {
    NSDictionary *course = [self course], *report = course ? self.reports[course[@"fork"]] : nil;
    NSMutableArray *parts = NSMutableArray.array;
    if (course) [parts addObject:[NSString stringWithFormat:@"老师：%@ / %@\n我的课程：%@ / %@\n本地：%@\n时区：%@", course[@"upstream"], course[@"upstreamBranch"], course[@"fork"], course[@"branch"], course[@"path"] ?: @"未关联", course[@"timeZone"] ?: NSTimeZone.localTimeZone.name]];
    if (report[@"error"]) [parts addObject:report[@"error"]];
    if ([report[@"skipped"] count]) [parts addObject:[@"跳过的文件：\n" stringByAppendingString:[report[@"skipped"] componentsJoinedByString:@"\n"]]];
    self.detail.string = parts.count ? [parts componentsJoinedByString:@"\n\n"] : @"还没有查找记录。";
}
- (void)push:(id)sender {
    NSDictionary *course = [self course]; if (!course) return;
    [self work:@"正在重新上传…" operation:^id(NSError **error) {
        NSString *token = [self.github accessToken:error]; if (!token) return @NO;
        return @([self.git pushCourse:course token:token error:error]);
    } completion:^(NSNumber *ok, NSError *error) { if (ok.boolValue) [self status:@"已上传到你的 GitHub 课程仓库。"] ; else [self showError:error]; }];
}
- (void)conflictGuide:(NSDictionary *)course {
    [self work:@"正在读取冲突状态…" operation:^id(NSError **error) { return [self.git conflicts:course error:error]; } completion:^(NSArray *files, NSError *error) {
        if (!files) { [self showError:error]; return; }
        if (![course[@"pendingMergeTip"] length]) { [self status:@"没有本应用记录的上游合并。请自行处理现有 Git 状态。"] ; return; }
        NSAlert *alert = NSAlert.new; alert.messageText = @"处理文件冲突";
        alert.informativeText = files.count ? @"在编辑器中打开文件，保留需要的内容并删除冲突标记。保存后勾选文件，点击“标记已解决”；全部解决后再点击“保存并上传”。" : @"文件已经处理好，点击下方按钮保存并上传。";
        NSView *list = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 550, MAX(30, files.count * 26))];
        NSMutableArray<NSButton *> *checks = NSMutableArray.array;
        for (NSUInteger i = 0; i < files.count; i++) {
            NSButton *check = [NSButton checkboxWithTitle:files[i] target:nil action:NULL]; check.frame = NSMakeRect(0, NSHeight(list.frame) - (i + 1) * 26, 545, 24); [list addSubview:check]; [checks addObject:check];
        }
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 570, MIN(260, NSHeight(list.frame)))]; scroll.hasVerticalScroller = YES; scroll.documentView = list; alert.accessoryView = scroll;
        [alert addButtonWithTitle:files.count ? @"标记已解决" : @"保存并上传"]; [alert addButtonWithTitle:@"打开课程文件夹"]; [alert addButtonWithTitle:@"撤销本次合并"]; [alert addButtonWithTitle:@"关闭"];
        NSModalResponse answer = [alert runModal];
        if (answer == NSAlertSecondButtonReturn) { [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:course[@"path"]]]; return; }
        if (answer == NSAlertThirdButtonReturn) {
            NSAlert *confirm = NSAlert.new; confirm.messageText = @"撤销此次上游合并？"; confirm.informativeText = @"本次冲突解决中的编辑可能被撤销。Git 会回到合并前的状态。";
            [confirm addButtonWithTitle:@"撤销合并"]; [confirm addButtonWithTitle:@"保留"];
            if ([confirm runModal] != NSAlertFirstButtonReturn) return;
            [self work:@"正在撤销此次合并…" operation:^id(NSError **innerError) { return @([self.git abortMerge:course error:innerError]); } completion:^(NSNumber *ok, NSError *innerError) {
                if (!ok.boolValue) { [self showError:innerError]; return; }
                NSMutableDictionary *saved = [self savedCourse:course]; [saved removeObjectForKey:@"pendingMergeTip"]; [saved removeObjectForKey:@"pendingConflicts"]; [self saveCourses]; [self status:@"已撤销此次上游合并。"];
            }]; return;
        }
        if (answer != NSAlertFirstButtonReturn) return;
        if (!files.count) { [self finishMerge:course]; return; }
        NSMutableArray *selected = NSMutableArray.array;
        for (NSUInteger i = 0; i < checks.count; i++) if (checks[i].state == NSControlStateValueOn) [selected addObject:files[i]];
        if (!selected.count) { [self status:@"请选择已经编辑并保存的冲突文件。"] ; return; }
        [self work:@"正在检查并标记冲突文件…" operation:^id(NSError **innerError) { return @([self.git stageResolvedFiles:course paths:selected error:innerError]); } completion:^(NSNumber *ok, NSError *innerError) { if (!ok.boolValue) [self showError:innerError]; else [self conflictGuide:course]; }];
    }];
}
- (void)commit:(id)sender {
    NSDictionary *course = [self course]; if (!course) return;
    [self work:@"正在读取本地修改…" operation:^id(NSError **error) { return [self.git changesForCourse:course error:error]; } completion:^(NSArray *changes, NSError *error) {
        if (!changes) { [self showError:error]; return; }
        if (!changes.count) { [self status:@"没有新的作业文件。之前上传失败的内容，可在“课程设置”中重试上传。"] ; return; }
        NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 590, 350)];
        NSView *list = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 565, MAX(30, changes.count * 27))];
        NSMutableArray<NSButton *> *checks = NSMutableArray.array;
        for (NSDictionary *change in changes) {
            NSString *name = [NSString stringWithFormat:@"%@  %@%@", change[@"status"], change[@"path"], [change[@"sensitive"] boolValue] ? @" · 敏感文件" : @""];
            NSButton *check = [NSButton checkboxWithTitle:name target:nil action:NULL]; check.state = NSControlStateValueOff; check.enabled = ![change[@"sensitive"] boolValue];
            check.frame = NSMakeRect(0, NSHeight(list.frame) - (checks.count + 1) * 27, 560, 25);
            [checks addObject:check]; [list addSubview:check];
        }
        NSTextField *message = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 570, 28)]; message.stringValue = @"更新作业"; message.placeholderString = @"说明，例如：完成第 3 周实验";
        [accessory addSubview:message];
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 45, 590, 300)]; scroll.hasVerticalScroller = YES; scroll.documentView = list; [accessory addSubview:scroll];
        NSAlert *alert = [NSAlert new]; alert.messageText = @"上传作业到我的 GitHub 仓库";
        alert.informativeText = @"选择要交的作业文件，确认后自动上传。"; alert.accessoryView = accessory;
        [alert addButtonWithTitle:@"提交并上传"]; [alert addButtonWithTitle:@"取消"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
        NSMutableArray *paths = NSMutableArray.array;
        for (NSUInteger i = 0; i < checks.count; i++) if (checks[i].state == NSControlStateValueOn) [paths addObject:changes[i][@"path"]];
        [self work:@"正在上传作业…" operation:^id(NSError **innerError) {
            NSDictionary *user = [self.github user:innerError]; if (!user) return @NO;
            NSString *token = [self.github accessToken:innerError]; if (!token) return @NO;
            return @([self.git commitCourse:course paths:paths message:message.stringValue login:user[@"login"] userID:user[@"id"] token:token error:innerError]);
        } completion:^(NSNumber *ok, NSError *innerError) { if (ok.boolValue) [self status:@"作业已上传。"] ; else [self showError:innerError]; }];
    }];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.visible.count; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSDictionary *candidate = self.visible[row]; NSString *key = column.identifier;
    NSString *value = @"";
    if ([key isEqual:@"title"]) value = candidate[@"title"];
    else if ([key isEqual:@"due"]) value = candidate[@"deadlineText"] ? [candidate[@"deadlineText"] stringByAppendingString:@" · 待确认"] : (!candidate[@"due"] ? @"截止待定" : ([candidate[@"needsDate"] boolValue] ? @"日期待确认" : ([candidate[@"needsTime"] boolValue] ? [DDLFormatDate(candidate[@"due"], @"yyyy-MM-dd") stringByAppendingString:@" · 待补时间"] : DDLFormatDate(candidate[@"due"], @"yyyy-MM-dd HH:mm"))));
    else if ([key isEqual:@"source"]) value = [NSString stringWithFormat:@"%@:%@", candidate[@"path"], candidate[@"line"]];
    else if ([key isEqual:@"state"]) value = [self stateForCandidate:candidate];
    NSTextField *label = [NSTextField labelWithString:value ?: @""]; label.lineBreakMode = NSLineBreakByTruncatingMiddle; label.toolTip = value; label.textColor = DDLCourseColor(@"ink"); return label;
}
- (NSString *)stateForCandidate:(NSDictionary *)candidate {
    for (NSDictionary *task in self.tasksProvider ? self.tasksProvider() : @[]) if ([task[@"sourceID"] isEqual:candidate[@"id"]])
        return [task[@"sourceBlobSHA"] isEqual:candidate[@"blobSHA"]] ? @"已添加" : @"有更新";
    return @"待添加";
}
- (void)candidateSelected:(id)sender {
    NSInteger row = self.table.selectedRow;
    NSDictionary *candidate = row >= 0 && row < (NSInteger)self.visible.count ? self.visible[row] : nil;
    self.detail.string = candidate ? [NSString stringWithFormat:@"%@ · %@:%@\n%@", candidate[@"repository"], candidate[@"path"], candidate[@"line"], candidate[@"snippet"]] : @"选一项作业，查看老师的具体要求。";
    self.reviewButton.title = candidate && [[self stateForCandidate:candidate] isEqual:@"有更新"] ? @"更新提醒…" : @"添加提醒…";
    [self updateActions];
}
- (void)review:(id)sender {
    NSInteger row = self.table.selectedRow; if (row < 0 || row >= (NSInteger)self.visible.count) return;
    NSMutableDictionary *candidate = [self.visible[row] mutableCopy];
    candidate[@"observedDue"] = candidate[@"due"];
    if ([candidate[@"needsTime"] boolValue] || [candidate[@"needsDate"] boolValue]) {
        NSAlert *alert = [NSAlert new]; alert.messageText = @"请确认老师的具体截止时间";
        alert.informativeText = candidate[@"deadlineText"] ? [NSString stringWithFormat:@"老师原文：%@\n相对日期取决于老师布置作业的时间，不能按今天推算。请确认完整日期和时间。", candidate[@"deadlineText"]] : @"文档缺少明确的年份、日期或时间。请依据老师原文或课程说明输入完整时间，不能默认当作 23:59。";
        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 28)]; field.stringValue = candidate[@"due"] ? DDLFormatDate(candidate[@"due"], @"yyyy-MM-dd") : @""; field.placeholderString = @"2026-10-08 20:00"; alert.accessoryView = field;
        [alert addButtonWithTitle:@"确认"]; [alert addButtonWithTitle:@"取消"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
        if ([field.stringValue rangeOfString:@"^20\\d{2}[-/]\\d{1,2}[-/]\\d{1,2}\\s+(?:[01]?\\d|2[0-3]):[0-5]\\d$" options:NSRegularExpressionSearch].location == NSNotFound) { [self status:@"请填写明确的时:分，例如 2026-10-01 20:00。"] ; return; }
        NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]; calendar.timeZone = [NSTimeZone timeZoneWithName:candidate[@"timeZone"] ?: NSTimeZone.localTimeZone.name] ?: NSTimeZone.localTimeZone;
        NSDate *due = DDLParseDate(field.stringValue, NSDate.date, calendar);
        if (!due) { [self status:@"截止时间格式无效。"] ; return; }
        candidate[@"due"] = due; candidate[@"needsTime"] = @NO; candidate[@"needsDate"] = @NO;
    }
    if (self.reviewCandidate) self.reviewCandidate(candidate);
}
@end
