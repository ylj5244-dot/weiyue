# 微阅 1.0.11：安装、迁移与源码构建

发行版本为 **1.0.11，构建号 17**。应用要求 **macOS 14 或更新版本**，同一份通用应用包含 **Apple Silicon（arm64）与 Intel（x86_64）** 两种原生架构。无需为了运行应用安装 Node.js、Xcode 或其他开发工具。Intel 架构已交叉编译并检查；若未在 Intel 真机运行过，不能据此宣称已经完成 Intel 真机验收。

## 安装或升级

发行目录包含以下文件：

| 文件 | 用途 |
| --- | --- |
| `微阅-1.0.11-macOS-universal.dmg` | 推荐安装包，包含应用和「Applications」快捷入口 |
| `微阅-1.0.11-macOS-universal.zip` | 同一应用的备用压缩包 |
| `微阅-1.0.11-源码.zip` | 可独立构建的源码、资源、测试、打包脚本和文档 |
| `微阅-1.0.11-安装说明.txt` | 无需开发工具即可阅读的中文说明 |
| `SHA256SUMS.txt` | 每份发行文件的 SHA-256 校验值 |

1. 若正在使用旧版，先通过「退出微阅」或 Command+Q 退出，等待保存完成。
2. 打开 DMG，将「微阅」拖入旁边的「Applications / 应用程序」。更新时替换旧应用即可；如果旧版放在个人目录 `~/Applications/`，请拖到原位置替换，避免保留两份而误开旧版。ZIP 版本解压后同样拖入所用的应用程序目录。
3. 从「应用程序」启动微阅。安装包不含任何人的聊天记录、登录态、收藏、个人偏好、附件或 API Key；这些由每位使用者在自己的 Mac 上保存。
4. 更新同一台 Mac 的应用会继续使用原资料目录，不要为升级删除资料目录。已有 API Key 仍在 macOS 钥匙串中；系统如果要求重新授权，请使用应用设置里的「授权已保存的 Key」。

本发行使用 **ad hoc 本机签名**，没有 Apple Developer ID 签名，也没有 Apple 公证或 App Store 审核。签名完整性检查通过不等于已获 Apple 信任。下载后如果 macOS 阻止打开，应先确认来源，再到「系统设置 → 隐私与安全性」查看对应提示，选择「仍要打开」并按系统要求确认；系统版本不同，措辞可能略有差异。不要关闭整个系统的安全保护。

校验文件完整性可在发行文件所在文件夹运行：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

校验值只能检查文件是否与这份清单一致，不能单独证明文件来源可信。

## 换一台 Mac

只复制安装包或源码不会带上个人数据。若要迁移阅读位置、标记、收藏、AI 讨论、长期偏好与已经缓存的附件：

1. 在两台 Mac 上退出微阅；若新 Mac 已有资料，先分别备份，避免覆盖。
2. 旧 Mac 的访达中按 `Command + Shift + G`，输入 `~/Library/Application Support/WeiboReader/`。应用「设置 → 存储与自动清理 → 查看本地保存位置」也能打开这个目录。
3. 把整个 `WeiboReader` 文件夹经可信方式复制到新 Mac 的 `~/Library/Application Support/` 下。不要只复制某一个账号 JSON，附件和备份文件也在同一资料目录内。本版本不支持自动合并两个已有资料库。
4. 在新 Mac 安装微阅并重新登录原来的微博账号。资料按账号隔离，登录其他账号不会看到原账号记录。
5. API Key 保存在旧 Mac 的钥匙串，**不在上述目录或源码包内**。在新 Mac 重新配置所用 AI 服务的 Key，以及已启用的联网搜索服务 Key。微博网页登录会话也需要重新登录。
6. 曾经「另存」到桌面、下载等外部目录的文件需要另外复制。原绝对路径可能已失效；复制过的内部缓存仍在资料目录，可从原资料重新另存。

备份文件包含私人聊天、偏好和讨论内容，请自行妥善保管。核对新 Mac 上的阅读位置、标记、收藏、讨论和附件后，再处理旧备份。

## 在源码包中构建

需要 macOS、Xcode Command Line Tools（或完整 Xcode，包含 macOS SDK 与 Swift 编译器），以及 **Node.js 22 或更新版本**。项目不依赖 npm 包，也不需要 `npm install`。较旧的工具链若无法识别 SDK 或 Swift 语法，请先更新 Command Line Tools。

安装 Apple 命令行工具：

```sh
xcode-select --install
```

安装 Node.js 后，解压源码 ZIP，在终端进入解压出的 `微阅-1.0.11-源码` 文件夹，检查工具：

```sh
xcrun swiftc --version
node --version
```

执行自动测试并构建：

```sh
bash scripts/test.sh
bash scripts/build.sh
```

构建结果为 `build/微阅.app`，默认先分别编译 arm64 和 x86_64，再合并成通用可执行文件，并在合并后完成 ad hoc 签名。构建失败不会替换上一份成功的应用。脚本不会自动安装、打开或退出任何已有应用。

本机开发时可以只编译一种架构以节省时间：

```sh
WEIYUE_ARCHS=arm64 bash scripts/build.sh
# Intel Mac 的本机开发可使用：
WEIYUE_ARCHS=x86_64 bash scripts/build.sh
```

完整界面验收需要登录到 macOS 桌面，会打开独立的测试窗口，使用临时合成数据，不读写真实账号资料，也不向外部 AI 发送请求：

```sh
bash scripts/test-desktop-ui.sh
bash scripts/test-range-summary-ui.sh
bash scripts/test-discussion-history-ui.sh
bash scripts/test-web-search-ui.sh
bash scripts/test-speaker-groups-ui.sh
bash scripts/test-group-unread-ui.sh
bash scripts/test-reading-anchors-ui.sh
bash scripts/test-standby-ui.sh
bash scripts/test-compact-ai-ui.sh
bash scripts/test-reading-appearance-ui.sh
bash scripts/test-product-logic-ui.sh
bash scripts/test-reader-actions-ui.sh
bash scripts/test-reader-layout-ui.sh
bash scripts/test-attachment-actions-ui.sh
bash scripts/test-attachment-preview-ui.sh
bash scripts/test-reader-controls-v108-ui.sh
bash scripts/test-background-lifecycle-ui.sh
bash scripts/test-discussion-title-native.sh
bash scripts/test-discussion-titles-ui.sh
bash scripts/test-reading-appearance-v109-ui.sh
bash scripts/test-storage-preview-ui.sh
```

测试与构建文件写入源码目录内的 `build/`；这与正式应用的 `~/Library/Application Support/WeiboReader/` 资料目录不同。

## 生成发行包

```sh
bash scripts/package-release.sh
```

脚本会重新构建通用应用，核对版本 **1.0.11 (17)**、两个架构和签名，随后生成 DMG、应用 ZIP、源码 ZIP、中文安装说明以及校验清单。产物在 `build/releases/`。已经生成通用构建时，可跳过重复编译：

```sh
bash scripts/package-release.sh --skip-build
```

单架构或版本不匹配的应用会被拒绝打包。打包过程可重复执行；压缩映像的卷信息、签名或工具链可能使不同机器或不同次运行产生不同字节和校验值，因此不承诺跨机器的逐字节一致。

源码导出采用白名单：Git 跟踪的源码目录文件、明确列出的本轮新文件，以及显式传入的 `--extra-source 相对路径`。只接收 `Sources/`、`Resources/`、`scripts/`、`tests/`、`docs/` 中的 Swift、JavaScript、CSS、HTML、Shell 和 Markdown 源文件，以及根目录说明文件和固定的 `Resources/ui/skin-example.weiyue-skin.json` 皮肤样例；拒绝符号链接和私人数据目录。不复制 `.git/`、`build/`、`.test-data/`、账号 JSON、密钥文件、日志、安装包或其他生成产物。新增合法源码文件应加入 Git，或在打包时明确传入。

源码 ZIP 内的 `SOURCE-MANIFEST.txt` 列出实际包含的文件。在没有 Git 元数据的解压目录中，打包脚本使用这份清单，仍可重新构建和打包。若在解压目录新增文件，可使用 `--extra-source` 添加；该参数同样受文件类型和路径限制。

发布前可独立检查应用：

```sh
xcrun lipo -archs build/微阅.app/Contents/MacOS/WeiboReader
codesign --verify --deep --strict build/微阅.app
hdiutil verify build/releases/微阅-1.0.11-macOS-universal.dmg
unzip -l build/releases/微阅-1.0.11-源码.zip
```

应用源码架构为 AppKit + WKWebView。源码包不包含 API Key；运行时每位使用者配置自己的账号与服务。修改代码后应重新运行对应测试，不能仅凭成功编译判断群聊、联网搜索或真实 AI 服务已验收。

## 阅读密度、皮肤与字体

「设置 → 阅读与皮肤」提供五档正文密度、同一成员消息的独立五档间距和三套内置皮肤，继续支持微阅 JSON 皮肤与 TTF／OTF 字体导入。新功能见 [1.0.11 使用说明](reading-refinement-v111.md)，导入格式见 [阅读与皮肤说明](reading-appearance-v108.md)。迁移整个 `WeiboReader` 数据目录时，其中的 `阅读与皮肤` 文件夹也需要一并复制。

## 关闭窗口与退出

从 1.0.8 起，点击主窗口的红色关闭按钮会保留后台进程与会话。点击 Dock 图标恢复原窗口。需要退出或替换新版应用时，请选择菜单「微阅 → 退出微阅」或按 Command+Q，等待保存完成；只关闭窗口不会结束进程。

后台生命周期验收：`bash scripts/test-background-lifecycle-ui.sh`。该宿主编译实际 AppDelegate，使用独立临时网页验证关窗、重开和主动退出，不运行真实账号启动流程。
