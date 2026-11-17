# Codex Quota Widget

「用量额度」是一个 macOS 桌面小组件，可以查看 Codex 和 ChatGPT Work 的剩余额度。基于 SwiftUI 和 WidgetKit，支持系统小号、中号及液态玻璃外观。

- 显示账号返回的额度窗口、剩余百分比、重置时间和最近同步时间。有 5 小时和每周窗口时会分别显示。
- 配套应用在运行期间约每 15 分钟同步一次。点按小组件可打开应用并选择「立即同步」，桌面刷新时间由 macOS 调度。
- Codex 和 ChatGPT Work 共用额度。普通 ChatGPT 聊天的独立余额未通过当前接口提供。 [OpenAI 说明](https://learn.chatgpt.com/docs/use-chatgpt)

## 在自己的 Mac 上构建

需要 macOS 26 或以上、包含 macOS 26 或更新 SDK 的 Xcode 命令行工具，以及可通过 ChatGPT 账号登录的 Codex CLI。已在 Apple silicon 的 macOS 27.2 上验证。缺少命令行工具时可运行 `xcode-select --install`。 [Apple 命令行工具文档](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)

组件会查找系统或用户「应用程序」目录中 ChatGPT 自带的 Codex CLI，以及 `~/.local/bin/codex`、`/opt/homebrew/bin/codex` 和 `/usr/local/bin/codex`。请先用相应的 Codex CLI 完成 ChatGPT 登录。

在源码目录以当前用户运行以下命令。构建时会生成与当前用户匹配的沙盒读权限，并在本机签名。

```sh
bash ./build.sh "$HOME/Applications/用量额度.app"
open "$HOME/Applications/用量额度.app"
```

应用打开并完成第一次同步后，在桌面空白处右键，选择「编辑小组件」，搜索「用量额度」，选小号或中号。希望登录 macOS 后继续自动同步时，可在应用里开启「登录后自动同步」。 [Apple 桌面小组件指南](https://support.apple.com/zh-cn/guide/mac-help/mchl52be5da5/mac)

## 数据和权限

配套应用让本机 Codex CLI 通过官方 `account/rateLimits/read` 接口读取额度。登录和网络请求由 CLI 处理，读取额度无需发起模型对话。 [Codex App Server 文档](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)

配套应用把额度窗口、比例和时间写入 `~/Library/Application Support/Local OpenAI Usage/usage.json`。WidgetKit 扩展以只读权限读取这一个文件，凭据由 Codex CLI 管理。建议分发源码，由每位使用者在自己的 Mac 上构建。

## 卸载

从桌面移除小组件，关闭「登录后自动同步」，再用「活动监视器」退出 `OpenAIUsage`。将「用量额度」应用移到废纸篓。若也要清除本地用量快照，可删除 `~/Library/Application Support/Local OpenAI Usage`。

## 许可证

[MIT](LICENSE)
