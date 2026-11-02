# Codex Account Manager

Windows 11 PowerShell WPF 第一版，用于通过 MSIX Invoke-CommandInDesktopPackage 启动三个独立的 Codex Desktop 配置。

双击 启动管理器.bat。点击 A/B/C 前，请先保存工作并正常退出当前 Codex Desktop。程序不会强制结束进程，也不会修改永久 CODEX_HOME。

每个账号使用独立的 CODEX_HOME，UserData 使用 %LOCALAPPDATA%\CodexAccountManager\A|B|C\UserData。

程序只检查 auth.json 是否存在，不读取其内容。日志仅记录账号代号、时间和启动错误，位于 logs\manager.log。

当前限制：第一版不实现用量统计；启动请求成功不等于登录身份已验证，界面会显示待确认；需要系统能找到 OpenAI.Codex MSIX 包；由于当前环境没有 .NET SDK，本版本使用 Windows PowerShell 5.1 + WPF。
