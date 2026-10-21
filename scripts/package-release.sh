#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="1.0.12"
BUILD="18"
SKIP_BUILD=0
EXTRA_SOURCES=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    --extra-source)
      if [ "$#" -lt 2 ]; then printf '%s\n' '--extra-source 后须提供仓库内相对路径。' >&2; exit 1; fi
      EXTRA_SOURCES+=("$2"); shift 2 ;;
    --help|-h)
      printf '%s\n' '用法：bash scripts/package-release.sh [--skip-build] [--extra-source 路径]' '默认重新构建双架构应用；--skip-build 只接受已签名的 1.0.12 (18) 双架构构建。' '产物：build/releases/ 中的英文文件名 DMG、应用 ZIP、源码 ZIP、中文安装说明、LICENSE.txt 和 SHA256SUMS.txt。'; exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 1 ;;
  esac
done
if [ "$SKIP_BUILD" -eq 0 ]; then WEIYUE_ARCHS="arm64 x86_64" bash scripts/build.sh; fi

APP="$ROOT/build/微阅.app"
PLIST="$APP/Contents/Info.plist"
if [ ! -f "$PLIST" ]; then printf '未找到构建产物，请先运行 scripts/build.sh。\n' >&2; exit 1; fi
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" != "$VERSION" ] || [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" != "$BUILD" ]; then
  printf '应用版本不匹配，需要 %s (%s)。\n' "$VERSION" "$BUILD" >&2; exit 1
fi
for arch in arm64 x86_64; do
  xcrun lipo "$APP/Contents/MacOS/WeiboReader" -verify_arch "$arch"
done
codesign --verify --deep --strict "$APP"

mkdir -p "$ROOT/build/releases"
WORK="$(mktemp -d "$ROOT/build/.release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
RELEASE="$ROOT/build/releases"
STEM="weiyue-$VERSION"
SOURCE_ROOT="$WORK/$STEM-source"
mkdir -p "$SOURCE_ROOT" "$WORK/安装盘" "$WORK/产物"

# Export only tracked source files and these intentional additions. Never copy
# the whole working directory: it may contain real-account caches or secrets.
node - "$ROOT" "$SOURCE_ROOT" ${EXTRA_SOURCES[@]+"${EXTRA_SOURCES[@]}"} <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const [root, destination, ...extras] = process.argv.slice(2);
const additions = [
  'Sources/WebSearchClient.swift', 'Resources/ui/web-search.js', 'Resources/ui/speaker-groups.js', 'Resources/ui/reader-personalization.js', 'Resources/ui/reader-personalization.css', 'Resources/ui/inline-translation.js', 'Resources/ui/inline-translation.css', 'Resources/ui/message-actions.js',
  'tests/web-search.test.cjs', 'tests/speaker-groups.test.cjs', 'tests/WebSearchTests.swift', 'tests/WebSearchUIHarness.swift',
  'scripts/test-web-search-ui.sh', 'docs/verification-v102.md',
  'scripts/package-release.sh', 'docs/install-and-build.md',
  'Sources/AttachmentPreview.swift', 'Resources/ui/attachment-actions.js',
  'Resources/ui/attachment-actions.css', 'Resources/ui/font-controls.css',
  'tests/attachment-actions.test.cjs', 'tests/font-controls.test.cjs',
  'tests/AttachmentPreviewTests.swift', 'tests/AttachmentActionsUIHarness.swift', 'tests/AttachmentPreviewUIHarness.swift',
  'scripts/test-attachment-actions-ui.sh', 'scripts/test-attachment-preview-ui.sh',
  'docs/attachment-reading-v107.md', 'docs/verification-v107.md',
  'Sources/ReadingAppearance.swift', 'Resources/ui/reading-appearance.js', 'Resources/ui/reading-appearance.css',
  'Resources/ui/reader-controls-v108.css', 'Resources/ui/skin-example.weiyue-skin.json',
  'tests/reading-appearance.test.cjs', 'tests/reader-controls-v108.test.cjs', 'tests/ReadingAppearanceTests.swift',
  'tests/ReaderControlsV108UIHarness.swift', 'scripts/test-reader-controls-v108-ui.sh', 'docs/reading-appearance-v108.md', 'docs/verification-v108.md',
  'tests/BackgroundLifecycleUIHarness.swift', 'scripts/test-background-lifecycle-ui.sh',
  'Sources/DiscussionTitles.swift', 'Resources/ui/discussion-titles.js', 'Resources/ui/discussion-titles.css',
  'tests/discussion-titles.test.cjs', 'tests/discussion-title-rpc.test.cjs', 'tests/DiscussionTitleTests.swift', 'tests/DiscussionTitlesUIHarness.swift',
  'tests/ReadingAppearanceV109UIHarness.swift', 'scripts/test-discussion-title-native.sh',
  'scripts/test-discussion-titles-ui.sh', 'scripts/test-reading-appearance-v109-ui.sh',
  'docs/implementation-v109.md', 'docs/reading-title-skins-v109.md', 'docs/verification-v109.md'
];
const gitRoot = cp.spawnSync('git', ['rev-parse', '--show-toplevel'], {cwd: root, encoding: 'utf8'});
const ownsRepository = gitRoot.status === 0 && fs.realpathSync(gitRoot.stdout.trim()) === fs.realpathSync(root);
const tracked = ownsRepository ? cp.spawnSync('git', ['ls-files', '-z', '--cached'], {cwd: root, encoding: 'utf8'}) : {status: 1};
let candidates;
if (tracked.status === 0) candidates = tracked.stdout.split('\0').filter(Boolean);
else {
  const manifest = path.join(root, 'SOURCE-MANIFEST.txt');
  if (!fs.existsSync(manifest)) throw new Error('源码打包需要 Git 文件列表，或发行源码中的 SOURCE-MANIFEST.txt。');
  candidates = fs.readFileSync(manifest, 'utf8').split('\n').filter(Boolean);
}
for (const file of additions) if (fs.existsSync(path.join(root, file))) candidates.push(file);
for (const file of extras) {
  if (!fs.existsSync(path.join(root, file))) throw new Error(`额外源码不存在：${file}`);
  candidates.push(file);
}
const v110Sources = ["Sources/StorageUsage.swift", "Sources/RetentionPolicy.swift", "Sources/AutomaticCleanup.swift", "Sources/ContentPreview.swift", "Resources/ui/storage-management.js", "Resources/ui/content-preview.js", "Resources/ui/storage-preview.css", "Resources/ui/reader-discovery.js", "Resources/ui/reader-discovery.css", "tests/StorageUsageTests.swift", "tests/RetentionPolicyTests.swift", "tests/AutomaticCleanupTests.swift", "tests/ContentPreviewTests.swift", "tests/StoragePreviewUIHarness.swift", "tests/storage-management.test.cjs", "tests/storage-rpc.test.cjs", "tests/reader-discovery.test.cjs", "scripts/test-storage-preview-ui.sh", "docs/storage-preview-v110.md", "docs/verification-v110.md"];
for (const file of v110Sources) {
  if (!fs.existsSync(path.join(root, file))) throw new Error(`源码包缺少 1.0.12 文件：${file}`);
  candidates.push(file);
}
const v111Sources = ['Resources/ui/message-sizing.js','Resources/ui/reading-text.js','Resources/ui/settings-navigation.js','Resources/ui/settings-navigation.css','Resources/ui/weibo-emoticons.js','tests/message-sizing.test.cjs','tests/reading-text.test.cjs','tests/ReadingRefinementUIHarness.swift','tests/ContentPreviewResponsiveTests.swift','scripts/test-reading-refinement-ui.sh','scripts/test-content-preview-responsive.sh','docs/reading-refinement-v111.md','docs/verification-v111.md','docs/weibo-emoticons.md'];
const emoticonPaths = new Set(Object.values(require(path.join(root,'Resources/ui/weibo-emoticons.js'))).map(file=>'Resources/ui/'+file));
for(const file of [...v111Sources,...emoticonPaths]){
  if(!fs.existsSync(path.join(root,file)))throw new Error(`源码包缺少 1.0.12 文件：${file}`);
  candidates.push(file);
}
const v112Sources = ['Resources/ui/compact-reader.js','Resources/ui/compact-reader.css','tests/compact-reader.test.cjs','tests/CompactReaderUIHarness.swift','scripts/test-compact-reader-ui.sh','docs/compact-reader-v112.md','docs/verification-v112.md','docs/releases/v1.0.12.md'];
for (const file of v112Sources) {
  if (!fs.existsSync(path.join(root,file))) throw new Error(`源码包缺少 1.0.12 文件：${file}`);
  candidates.push(file);
}
const rootFiles = new Set(['README.md', 'LICENSE', '.gitignore', 'design-qa.md']);
function allowed(file) {
  if (rootFiles.has(file) || file === 'Resources/ui/skin-example.weiyue-skin.json') return true;
  if(emoticonPaths.has(file) && /^Resources\/ui\/emoticons\/[A-Za-z0-9_-]+\.png$/.test(file))return true;
  const parts = file.split('/');
  if (parts.some(part => !part || part.startsWith('.') || /[\r\n\\]/.test(part))) return false;
  if (!['Sources', 'Resources', 'scripts', 'tests', 'docs'].includes(parts[0])) return false;
  if (parts.some(part => /^(?:build|node_modules|accounts?|credentials?|secrets?|private|attachments?|附件)$/i.test(part))) return false;
  return /\.(?:swift|js|cjs|css|html|sh|md)$/.test(file);
}
for (const file of extras) if (!allowed(file)) throw new Error(`额外源码不在允许范围：${file}`);
const files = [...new Set(candidates.filter(allowed))].sort();
if (!files.includes('LICENSE')) throw new Error('源码包缺少 MIT 许可证。');
for (const required of ['Sources/DiscussionTitles.swift','Resources/ui/discussion-titles.js','Resources/ui/discussion-titles.css','tests/discussion-titles.test.cjs','tests/DiscussionTitleTests.swift','tests/DiscussionTitlesUIHarness.swift','tests/ReadingAppearanceV109UIHarness.swift','scripts/test-discussion-title-native.sh','scripts/test-discussion-titles-ui.sh','scripts/test-reading-appearance-v109-ui.sh','docs/reading-title-skins-v109.md','docs/verification-v109.md','tests/BackgroundLifecycleUIHarness.swift','scripts/test-background-lifecycle-ui.sh','Sources/ReadingAppearance.swift','Resources/ui/reading-appearance.js','Resources/ui/reading-appearance.css','Resources/ui/reader-controls-v108.css','Resources/ui/skin-example.weiyue-skin.json','tests/ReaderControlsV108UIHarness.swift','scripts/test-reader-controls-v108-ui.sh','docs/reading-appearance-v108.md','docs/verification-v108.md','README.md','scripts/build.sh','scripts/package-release.sh','docs/install-and-build.md','Sources/App.swift','Sources/WebSearchClient.swift','Resources/ui/index.html','Resources/ui/group-unread.js','Resources/ui/speaker-groups.js', 'Resources/ui/reader-personalization.js', 'Resources/ui/reader-personalization.css', 'Resources/ui/inline-translation.js', 'Resources/ui/inline-translation.css', 'Resources/ui/message-actions.js','Resources/ui/web-search.js','Sources/AttachmentPreview.swift','Resources/ui/attachment-actions.js','Resources/ui/attachment-actions.css','Resources/ui/font-controls.css']) {
  if (!files.includes(required)) throw new Error(`源码包缺少必需文件：${required}`);
}
if (!files.includes('tests/discussion-title-rpc.test.cjs')) throw new Error('源码包缺少标题超时与取消回归测试。');
let epoch = Number(process.env.SOURCE_DATE_EPOCH);
if (!Number.isFinite(epoch) || epoch < 0) {
  const commit = cp.spawnSync('git', ['log', '-1', '--format=%ct'], {cwd: root, encoding: 'utf8'});
  epoch = commit.status === 0 ? Number(commit.stdout.trim()) : 0;
}
// ZIP timestamps cannot represent dates before 1980. Stable source timestamps
// make inventories and repeat packaging easier to compare.
const timestamp = new Date(Math.max(315532800, epoch || 0) * 1000);
for (const file of files) {
  let current = root;
  for (const part of file.split('/')) {
    current = path.join(current, part);
    if (fs.lstatSync(current).isSymbolicLink()) throw new Error(`源码包拒绝符号链接：${file}`);
  }
  const stat = fs.statSync(current);
  if (!stat.isFile()) throw new Error(`源码包只接收普通文件：${file}`);
  const target = path.join(destination, file);
  fs.mkdirSync(path.dirname(target), {recursive: true});
  fs.copyFileSync(current, target);
  fs.chmodSync(target, stat.mode & 0o111 ? 0o755 : 0o644);
  fs.utimesSync(target, timestamp, timestamp);
}
fs.writeFileSync(path.join(destination, 'SOURCE-MANIFEST.txt'), files.join('\n') + '\n');
fs.utimesSync(path.join(destination, 'SOURCE-MANIFEST.txt'), timestamp, timestamp);
console.log(`已导出 ${files.length} 份源码/文档；不含 Git、构建产物或用户数据。`);
NODE

cat > "$WORK/产物/$STEM-installation.txt" <<'NOTE'
微阅 1.0.12（构建 18）安装说明

适用：macOS 14 或更新版本，Apple Silicon 与 Intel Mac。

1.0.12 更新：
- 阅读顶部收紧为群信息和常用工具两行，宽阅读栏的搜索、关注、类型、筛选、时段总结和字号同排。
- 群名旁显示同步状态，点开查看详细进度、本地记录范围、立即同步和加载更早消息。
- 成员与日期筛选收进下拉菜单；使用中的筛选显示条件及清除入口。
- 返回跳转前、最新和手动续读点移至阅读区右下角，并避让多选操作栏。
- 保留消息正文样式、关注分组、表情、网页与附件预览、存储清理和原有阅读位置。

1. 打开「weiyue-1.0.12-macOS-universal.dmg」，把「微阅」拖入旁边的「Applications / 应用程序」。
2. 如果正在使用旧版，先通过菜单「退出微阅」或 Command+Q 退出，再替换应用；不要删除本地资料目录。
   旧版若在个人 ~/Applications/ 目录，请拖到原位置替换，避免保留两份而误开旧版。
3. 从「应用程序」打开微阅。更新同一台 Mac 的应用通常保留原资料和钥匙串中的 Key。
4. 本发行包采用本机 ad hoc 签名，尚未进行 Apple Developer ID 签名或 Apple 公证。
   下载后如被 macOS 阻止，请先确认文件来自可信来源，再到「系统设置 → 隐私与安全性」
   查看微阅的阻止提示，选择「仍要打开」并按系统提示确认。不同系统措辞可能略有变化。
   无须关闭整个系统的安全保护。

ZIP 版是同一个应用的备用压缩包，解压后把微阅拖入「应用程序」即可。
源码 ZIP 供开发或在另一台 Mac 编译，内含完整安装、迁移与构建文档：docs/install-and-build.md。

迁移到另一台 Mac：
- 先在两台 Mac 上退出微阅，并备份各自已有数据。
- 在访达按 Command+Shift+G，输入 ~/Library/Application Support/WeiboReader/
  将旧 Mac 的整个 WeiboReader 文件夹安全复制到新 Mac 的相同位置。
  请勿直接覆盖新 Mac 已有的不同资料；本版本没有自动合并两个资料库的功能。
- 新 Mac 需要重新登录同一个微博账号，并重新配置 API Key；Key 不随源码或上述文件夹迁移。
- 「另存」到外部文件夹的文件需另行复制；原来的绝对路径可能失效，可从原资料重新另存。

安装包与源码包均不包含聊天记录、收藏、个人偏好、附件、微博登录态或 API Key。
SHA256SUMS.txt 用于校验文件是否完整；它本身不证明来源可信。
NOTE
ditto --norsrc --noextattr "$APP" "$WORK/安装盘/微阅.app"
ln -s /Applications "$WORK/安装盘/Applications"
cp "$WORK/产物/$STEM-installation.txt" "$WORK/安装盘/安装说明.txt"
cp "$ROOT/LICENSE" "$WORK/产物/LICENSE.txt"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$WORK/产物/$STEM-macOS-universal.zip"
ditto -c -k --norsrc --noextattr --keepParent "$SOURCE_ROOT" "$WORK/产物/$STEM-source.zip"
hdiutil create -quiet -volname "微阅 $VERSION" -srcfolder "$WORK/安装盘" -format UDZO -ov "$WORK/产物/$STEM-macOS-universal.dmg"
hdiutil verify "$WORK/产物/$STEM-macOS-universal.dmg" >/dev/null
(
  cd "$WORK/产物"
  shasum -a 256 "$STEM-macOS-universal.dmg" "$STEM-macOS-universal.zip" "$STEM-source.zip" "$STEM-installation.txt" LICENSE.txt > SHA256SUMS.txt
)
for file in "$WORK/产物/"*; do mv -f "$file" "$RELEASE/"; done
printf '发行文件已生成：%s\n' "$RELEASE"
