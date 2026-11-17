# Codex Quota Widget

「用量额度」是一款查看 Codex 和 ChatGPT Work 共享额度的 macOS 应用。它使用 SwiftUI 和 WidgetKit 提供小号、中号桌面小组件，并在配备灵动岛的 MacBook Pro 上使用 ActivityKit 显示原生实时活动。

- 显示账号返回的额度窗口、剩余百分比、重置时间和最近同步时间。有 5 小时和每周窗口时会分别显示。
- 配套应用在运行期间约每 15 分钟同步一次。点按小组件可打开应用并选择「立即同步」，桌面刷新时间由 macOS 调度。
- Codex 和 ChatGPT Work 共用额度。普通 ChatGPT 聊天的独立余额未通过当前接口提供。 [OpenAI 说明](https://learn.chatgpt.com/docs/use-chatgpt)

## 在自己的 Mac 上构建

需要 macOS 26 或以上、包含 macOS 26 或更新 SDK 的 Xcode 命令行工具，以及可通过 ChatGPT 账号登录的 Codex CLI。已在 Apple silicon 的 macOS 27.2 上验证。缺少命令行工具时可运行 `xcode-select --install`。 [Apple 命令行工具文档](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)

组件会查找系统或用户「应用程序」目录中 ChatGPT 自带的 Codex CLI，以及 `~/.local/bin/codex`、`/opt/homebrew/bin/codex` 和 `/usr/local/bin/codex`。请先用相应的 Codex CLI 完成 ChatGPT 登录。

在终端运行以下命令。构建时会生成与当前用户匹配的沙盒读权限，并在本机签名。

```sh
git clone https://github.com/TongShawn12138/codex-quota-widget.git
cd codex-quota-widget
bash ./build.sh "$HOME/Applications/用量额度.app"
open "$HOME/Applications/用量额度.app"
```

应用打开并完成第一次同步后，在桌面空白处右键，选择「编辑小组件」，搜索「用量额度」，选小号或中号。希望登录 macOS 后继续自动同步时，可在应用里开启「登录后自动同步」。 [Apple 桌面小组件指南](https://support.apple.com/zh-cn/guide/mac-help/mchl52be5da5/mac)

## 在 PROLED XDR MacBook Pro 的灵动岛上显示

原生实时活动需要 macOS 27.3 或以上，并用 macOS 27.3 或更新的 SDK 构建。在源码目录运行以下命令确认当前 SDK 并构建。若装有多个版本的开发工具，可以通过 `DEVELOPER_DIR` 指定本次构建使用的 Xcode。

```sh
xcrun --sdk macosx --show-sdk-version
QUOTA_REQUIRE_LIVE_ACTIVITY=1 bash ./build.sh "$HOME/Applications/用量额度.app"
open "$HOME/Applications/用量额度.app"
```

打开「用量额度」，开启「ChatGPT 运行时在灵动岛显示」。ChatGPT 桌面版打开或在后台运行时可显示额度活动，完全退出 ChatGPT 时收起。关闭「用量额度」的窗口后，它会继续监测状态。如果 macOS 要求在前台创建活动，请打开一次「用量额度」窗口。点按灵动岛中的额度活动可展开，查看各时段剩余和已用比例、重置时间与同步状态。

当 macOS 将额度活动缩成圆形时，左半环表示 7 天剩余额度，右半环表示 5 小时剩余额度。两侧各自按剩余比例填充。活动的显示顺序、样式和有效时间由 macOS 决定。 [Apple 的 Mac 实时活动开发说明](https://developer.apple.com/videos/play/tech-talks/111467/)

覆盖安装前，先通过「活动监视器」退出 `OpenAIUsage`。升级后如果已启用活动但界面空白，通过「活动监视器」退出 `OpenAIUsageWidget`，再在「用量额度」中关闭并重新开启灵动岛开关，让系统重新读取扩展。

### 显示任务进度

额度实时活动运行时，应用约每 30 秒查看一次任务状态。应用通过 Codex CLI 的实验性云端任务命令查询最近 20 条，并统计其中尚未完成的任务。展开后视空间最多显示两项任务的详情。普通 ChatGPT 对话及其他未通过 Codex CLI 提供的 ChatGPT Work 任务进度暂时无法读取。 [Codex 云端任务命令](https://learn.chatgpt.com/docs/cli/reference#codex-cloud-list)

本机 Codex 任务可选择启用随源码提供的事件脚本，显示项目名、当前状态和运行时长。Codex 建立计划时，会显示已完成的步骤数与总数，否则显示已记录的工具操作次数。复制 [示例配置](Hooks/hooks.example.json) 到 `~/.codex/hooks.json`。如已有配置，将示例中的项目合并进现有的 `hooks` 对象。把每个命令中的占位路径替换为 [record-work.py](Hooks/record-work.py) 的绝对路径，然后在 Codex 的「设置 → Hooks」中审核启用。 [Codex Hooks 文档](https://learn.chatgpt.com/docs/hooks)

脚本在本机保存项目目录名、状态、时间和进度计数，任务结束时清除对应记录。应用会忽略超过 10 分钟没有更新的本地记录。系统可能在登录界面或其他实时活动界面显示项目名及云端任务名称。卸载时可从 Codex 配置移除添加过的脚本条目。

## 数据和权限

配套应用让本机 Codex CLI 通过官方 `account/rateLimits/read` 接口读取额度。登录和网络请求由 CLI 处理，读取额度无需发起模型对话。 [Codex App Server 文档](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)

配套应用把额度窗口、比例和时间写入 `~/Library/Application Support/Local OpenAI Usage/usage.json`。WidgetKit 扩展以只读权限读取这一个文件，凭据由 Codex CLI 管理。建议分发源码，由每位使用者在自己的 Mac 上构建。

## 卸载

从桌面移除小组件，关闭「登录后自动同步」，再用「活动监视器」退出 `OpenAIUsage`。将「用量额度」应用移到废纸篓。若也要清除本地用量快照，可删除 `~/Library/Application Support/Local OpenAI Usage`。

## 许可证

[MIT](LICENSE)
