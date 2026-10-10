#!/bin/zsh
# Builds a local ZIP only. Uploading to GitHub Releases is a separate maintainer action.
set -euo pipefail
TASK_DIR="${0:A:h}"
cd "$TASK_DIR"
mode="${1:-}"
if [[ -n "$mode" && "$mode" != "--candidate" ]]; then
  print -u2 -- '用法：zsh release.sh [--candidate]'
  exit 2
fi
if [[ "$mode" != "--candidate" ]]; then
  python3 - <<'PY'
import plistlib
from pathlib import Path
config = plistlib.loads(Path('Config/GitHubApp.plist').read_bytes())
if not config.get('clientID') or not config.get('installationURL'):
    raise SystemExit('正式包需要公开 GitHub App 配置，请按 docs/GITHUB_APP_SETUP.md 注册。')
PY
fi
zsh build.sh
zsh verify-import.sh
zsh verify-homework.sh
zsh verify-forms.sh
zsh verify-course-ui.sh
python3 Tests/SecurityAuditTests.py
app='build/DDL-Manager.app'
codesign --verify --deep --strict "$app"
[[ "$(lipo -archs "$app/Contents/MacOS/DDLManager")" == "arm64" ]]
python3 Tools/security-audit.py --history --artifacts "$app" build/qa --ocr build/tests/privacy-ocr --report build/security-audit.json
mkdir -p build/releases
stage='build/releases/package'
# Only explicit deliverables are copied; no task database, token store or repository metadata.
rm -rf "$stage"
mkdir -p "$stage"
cp -R "$app" "$stage/DDL-Manager.app"
cp LICENSE "$stage/"
cp docs/ATTRIBUTION.md docs/GITHUB_APP_SETUP.md docs/SECURITY.md docs/VERIFICATION.md docs/CHANGELOG.md "$stage/"
python3 - <<'PY'
from pathlib import Path
Path('build/releases/package/安装说明.txt').write_text('''DDL-Manager 6.2 · macOS 13+ · Apple 芯片

更新步骤
1. 先退出旧版（⌘Q）。
2. 解压安装包，将 DDL-Manager.app 放到“应用程序”文件夹。
3. 从“应用程序”打开新版。启动后不要移动正在运行的应用。

此包使用临时签名，未经 Apple 公证。若首次打开被系统阻止，可在“系统设置 → 隐私与安全性”中按系统提示选择“仍要打开”。

课程与作业
在“账号与授权”中登录，在“添加课程”中选择自己的课程。
在“课程设置”中选择“下载课程到新文件夹”或“关联已有课程文件夹”。
“更新课程文件”获取老师资料；“上传作业”选择文件后自动提交并上传。
“查找截止日期”读取老师文档；“添加提醒”确认后保存到主界面。
打开软件不会立即查找，后续自动查找每 6 小时在后台进行。
系统杂项文件无需上传；文件冲突出现时按页面引导处理。

钥匙串授权
新版首次访问登录信息时，macOS 可能要求输入 Mac 登录密码，可选择“始终允许”。运行中会复用登录信息，减少连续弹窗。不同构建版本的临时签名会变化，因此以后更新仍可能要求首次授权。

数据与提醒
从此前 6.0 测试版更新时，已有任务和课程信息继续沿用。从原版 5.x 迁移时，请先导出任务备份，再在新版导入。
提醒需要系统通知权限。关闭窗口后软件仍在菜单栏运行；退出、关机或休眠期间不执行定时查找。
登录信息持久化存于本机钥匙串，不包含在此安装包或任务备份中。

更新内容与验证范围见 CHANGELOG.md 和 VERIFICATION.md。真实 GitHub 网络与钥匙串弹窗仍需实机验证。
''')
PY
suffix=''
[[ "$mode" == "--candidate" ]] && suffix='-candidate'
archive="build/releases/DDL-Manager-6.2-macOS-arm64${suffix}.zip"
/usr/bin/ditto -c -k --sequesterRsrc "$stage" "$archive"
python3 Tools/security-audit.py --artifacts "$archive" --ocr build/tests/privacy-ocr --report build/release-audit.json
(cd "${archive:h}" && /usr/bin/shasum -a 256 "${archive:t}") > "${archive}.sha256"
print -r -- "已生成本机安装包：$archive"
