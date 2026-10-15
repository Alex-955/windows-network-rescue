# 测试与打包

普通使用者无需安装开发依赖。以下步骤供开发者验证代码。

## PowerShell 隔离测试

在仓库根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-auto.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-preview.ps1
```

也可以使用 `pwsh`。这些脚本只加载函数定义，不运行工具的 Windows 入口；网络配置写入、服务、续租、时间和探测状态均使用隔离模拟，临时文件在结束时清理。

- `verify.ps1`：原代理、自动/静态 DNS 的备份恢复和权限边界。
- `verify-auto.ps1`：多层判断、针对性修复、失败恢复、并发变化、次数限制及 HTML 转义。
- `verify-preview.ps1`：只读无修复调用、取消、明确确认、旧方案失效、目标变化和不扩大修复范围。

## 本地网络探测测试

需要开发用 Python 3，以及 `pwsh` 或 Windows PowerShell：

```text
python tests/verify-probes.py
```

脚本只启动一个绑定 `127.0.0.1` 随机端口的本地 HTTP 服务器，验证真实 .NET 探测函数如何处理 HTTP 200、302、500 和 TCP 监听端口，不访问公共测试网站，不修改系统配置。

如需指定 PowerShell，可设置 `NET_RESCUE_POWERSHELL` 为可执行文件完整路径。未指定时依次查找 `pwsh` 和 `powershell`。

## 验证边界

首个公开版本的开发验证环境为 macOS + PowerShell 7.4。测试通过代表这些隔离场景通过，不等同于已在真实 Windows 上完整验证。

最初案例实机验证过手动关闭系统代理后网页和语音软件恢复。新增自动修复、确认模式、不同 Windows 版本及 HTML 渲染仍需要进一步验证。

真实网络测试应使用可恢复的测试机。先运行 `CHECK-ONLY.cmd`，独立核对设置没有改变，再考虑可控故障；不要在生产、远程连接或组织网络上随意制造断网。

## 构建分享包

```text
python scripts/build_release.py
```

生成 `dist/Windows-Net-Rescue-v2.1.0.zip` 和 `dist/SHA256SUMS`。工具包只包含明确列出的运行文件与 MIT 许可证，不打包测试输出、报告、备份或本地历史。

打包脚本验证 PowerShell 的 UTF-8 BOM、Windows 启动文件换行与 ASCII 编码，并对 ZIP 逐文件回读核对。
