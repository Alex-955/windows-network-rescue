# Windows Network Rescue

Windows 10 / 11 离线网络诊断与针对性修复工具。无需安装 360、Python 或其他运行依赖，使用 Windows 自带的 PowerShell。

**先看检测结果和修复方案，由你确认后再改设置。** 也提供严格只读模式，以及独立的自动修复入口。

> 当前版本：**v2.1，预发布阶段**。最初案例中，关闭残留系统代理后恢复了上网；新增自动修复和预览流程已通过隔离测试，尚未完成真实 Windows 环境下的全面验证。建议先运行只读检测。

## 下载与开始使用

**[下载工具压缩包](https://github.com/Alex-955/windows-network-rescue/releases/download/v2.1.0/Windows-Net-Rescue-v2.1.0.zip)** · [查看版本说明和校验值](https://github.com/Alex-955/windows-network-rescue/releases/tag/v2.1.0)

1. 在能上网的设备上下载压缩包，通过 U 盘、NAS 或其他方式传到 Windows 电脑。
2. 把压缩包复制到本机桌面，右键选择“全部解压”。不要直接在压缩包中运行，也不要只复制一个 `.cmd` 文件。
3. 打开 `Windows-Net-Rescue` 文件夹，先双击 **`CHECK-ONLY.cmd`**。
4. 等待检测完成，查看窗口和本地 HTML 报告。通常需要数分钟。
5. 如果需要按方案修复，运行 **`PREVIEW.cmd`**。看清对象、步骤与影响后，在命令窗口输入大写 **`APPLY`** 才执行；直接回车则取消。

只读检测无需主动提权。需要修复服务、DHCP、DNS 或时间时，工具会提示管理员权限；以管理员身份重新运行 `PREVIEW.cmd` 后，仍需重新检测和确认。

也可以从仓库页面选择 **Code → Download ZIP** 下载源码，再进入其中的 `Windows-Net-Rescue` 子目录运行。

## 四个入口，分别做什么

| 入口 | 行为 | 何时使用 |
| --- | --- | --- |
| **`CHECK-ONLY.cmd`** | 只检测、展示拟修复方案并保存报告，不执行修复，也不清 DNS 缓存 | 首次使用、正常网络测试 |
| **`PREVIEW.cmd`** | 先只读预览，收到准确的 `APPLY` 才执行当前方案 | 希望自己确认每一步 |
| `START.cmd` | 先做详细诊断，再显示手动操作菜单 | 手动修复、查看报告或恢复备份 |
| `AUTO-FIX.cmd` | 根据证据尝试修复，不逐项征求确认 | 已理解处理范围并愿意自动执行 |

预览会显示：**检测依据、拟处理对象、操作步骤、影响、恢复方式和所需权限**。执行前重新检测，方案或目标变化就停止；修好一层后发现另一类故障，需要重新预览确认。

HTML 页面只展示结果，不能替你批准或执行系统修改。程序不安装后台任务，运行一轮后结束。

## 能检查和处理哪些问题

| 层次 | 检查与处理 |
| --- | --- |
| WiFi、网卡、驱动线索 | 识别未连接、无网卡等状态，提示连接 WiFi 或检查设备管理器 |
| 网络服务 | 按条件启动原本设为自动、却已停止的 WLAN / DHCP / DNS 服务 |
| IP、DHCP、地址冲突 | 对明确的单张 DHCP 网卡重新申请地址，不先释放地址，不改静态 IP |
| 网关、路由、IPv6 | 收集默认路由、拆分路由及 IPv6 信息，给出热点对照建议 |
| DNS | 两个域名对照默认与公共 DNS；按条件清缓存、备份后试用通过测试的公共 DNS |
| 系统代理、Clash | 直连成功、代理路径失败且本地端口不可达时，按条件清理残留手动代理 |
| 网络认证页面 | 根据 HTTP 重定向或内容变化提示可能需要登录 |
| 系统时间、HTTPS | 收集证书错误和时钟线索，按条件请求 Windows 使用原时间源同步 |
| hosts、WinHTTP、环境变量、VPN | 提供线索和具体建议，保留可能有用途的自定义设置 |

检测到相关代理/VPN 进程、组织策略、多网卡、手动 IP/DNS 等情况时，会保留相应配置或要求进一步人工处理。网关 Ping 失败、单个网站失败，都不会单独作为断网定论。

详细条件见工具目录中的 [使用说明](Windows-Net-Rescue/使用说明.txt)。离线 HTML 指南需下载后在本地打开。

## 修改、备份和恢复

- DNS 和代理修改前保存原配置，修改后独立回读并复测。
- 尝试无效时，只有当前配置仍与本次修改一致，才尝试恢复，避免覆盖其他程序的改动。
- 恢复 DNS / 代理：运行 **`START.cmd` → 菜单 5**。支持恢复早期版本生成的备份。
- 服务启动、DHCP 续租和时间同步不属于菜单 5 可撤销的配置备份：续租可能短暂影响局域网连接，同步可能调整时钟。
- 不会自动卸载驱动、关闭防火墙、删除 WiFi 密码、重置全部 TCP/IP 或重启电脑。高级 Winsock 重置仅在手动菜单中提供，不能一键撤销。

管理员提示如果要求另一个账户的密码，运行账户会改变，代理设置也对应那个账户。请留意窗口显示的账户；单位电脑应遵守组织策略。

## 报告与隐私

在资源管理器地址栏输入以下路径：

```text
%LOCALAPPDATA%\Windows-Net-Rescue
```

- `Reports`：文本、JSON、HTML 检测结果和操作记录。
- `Backups`：修改前的 DNS / 代理配置。

**工具不会上传这些文件。** 诊断仍会向百度、腾讯、微软和公共 DNS 发送少量常规测试请求；“离线”指运行无需下载依赖。

报告可能包含电脑名、WiFi 名称、局域网地址、代理 URL、hosts 条目，代理 URL 也可能含令牌。反馈问题时请先脱敏，不要直接上传整个报告目录或备份文件。

## 这个工具怎么来的

最初是一次紧急排障：Windows 能连 WiFi、能访问 NAS，但百度和语音软件都无法联网，第一反应是 DNS 出了问题。

通过另一台设备制作脚本并经 NAS 传到故障电脑后，检测发现 DNS 有成功结果，直连网站的表现优于系统代理路径。备份中保留了一个本地手动代理地址。关闭系统代理后，网页和语音软件都恢复了连接。

之后工具逐步增加了自动判断、多层排查、HTML 结果页，以及“先预览、确认后再执行”的模式。这个案例说明了最初功能的实际效果；它不代表所有新增修复场景都经过实机验证。

## 验证范围与已知限制

已完成 PowerShell 语法检查、隔离模拟测试，以及受控本地 HTTP/TCP 测试。测试覆盖只读路径不调用修复、拒绝确认、确认后复测、旧方案失效、恢复原配置和防止修复范围扩大。

目前尚未完成真实 Windows 各种网络故障下的端到端验证，HTML 尚未完成浏览器渲染检查。浏览器安全 DNS、独立代理、应用自己的网络设置，可能与本工具的测试路径不同。

本工具面向家庭 Windows 10/11 环境，不保证修复运营商断线、硬件损坏、密码错误或组织网络问题。Windows 7/8 不在支持范围内。

## 开发与反馈

- [测试方法](docs/TESTING.md)
- [版本变化](CHANGELOG.md)
- [参与改进](CONTRIBUTING.md)
- [安全反馈与隐私](SECURITY.md)
- [提交问题](https://github.com/Alex-955/windows-network-rescue/issues/new)

反馈请描述 Windows 版本、使用的入口、实际症状、是否使用代理/VPN、手机连接同一 WiFi 是否正常，以及脱敏后的错误提示。请区分“命令成功返回”和“实际恢复上网”。

## 许可证与参考

使用 [MIT 许可证](LICENSE)，可以使用、修改和分享，请保留许可证和版权声明。

相关命令和排查思路参考：[微软 WiFi 排查](https://support.microsoft.com/en-us/windows/experience/connectivity-networking/fix-wi-fi-connection-issues-in-windows)、[ipconfig](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/ipconfig)、[Windows 时间服务](https://learn.microsoft.com/en-us/windows-server/networking/windows-time-service/windows-time-service-tools-and-settings)、[DNS 配置](https://learn.microsoft.com/en-us/powershell/module/dnsclient/set-dnsclientserveraddress)、[Clash Verge Rev Windows FAQ](https://www.clashverge.dev/faq/windows.html)。
