# Legion Zone Power Plan Tools

用于备份、删除和恢复 Lenovo Legion Zone 电源计划的 PowerShell 工具。

针对“删除联想电源计划后，启动游戏或切换模式又被创建”的情况，工具会关闭游戏自动性能切换，并把已知导入模板改名为 `.disabled-by-user`，阻止当前版本从原路径导入。所有修改前先创建本机备份。

**已知限制：自定义模式仍可能重新出现。** 后续本机只读检查发现，自定义模式 GUID 已再次存在，同时四份模板仍被禁用、`PerformanceSwitch` 仍为 `0`。这证明当前方案没有覆盖所有计划创建路径；尚未确定创建者或触发时机。工具可再次备份并删除它，但不保证永久阻止重建。

## 适用范围

| 项目 | 范围 |
| --- | --- |
| 系统 | Windows，64 位 Windows PowerShell 5.1 或 PowerShell 7 |
| 已检查的机器 | Legion Y7000P IRH8 |
| 支持的软件版本 | Legion Zone **2.0.28.8182**；其他版本的修改会被拒绝 |
| 删除对象 | 安静模式、均衡模式、野兽模式、自定义模式的四个固定 GUID |
| 权限 | 查看和预演无需管理员；修改和恢复需以管理员身份打开 PowerShell |

这是基于特定机器与安装版本整理的工具，不代表所有拯救者机型都适用。同版本不同机型也未验证。软件升级、修复或重装可能重建模板或重置开关，不能保证永久阻止。

## 快速开始

下载仓库 ZIP 并解压，或使用 Git：

```powershell
git clone https://github.com/fananly233/legion-zone-power-plan-tools.git
cd legion-zone-power-plan-tools
```

默认操作是只读查看：

```powershell
.\LegionPowerPlans.ps1
# 查看完整模板状态
.\LegionPowerPlans.ps1 -Action Status | ConvertTo-Json -Depth 5
```

预演：不备份、不修改注册表、模板或电源计划；显示操作意图与当前状态。

```powershell
.\LegionPowerPlans.ps1 -Action Disable -WhatIf
```

确认适用后，**以管理员身份打开 PowerShell**，进入项目目录执行：

```powershell
.\LegionPowerPlans.ps1 -Action Disable
```

备份自动存放在项目的 `backups/时间戳/`。也可以指定一个尚不存在的文件夹：

```powershell
.\LegionPowerPlans.ps1 -Action Disable -BackupDirectory 'D:\LegionBackups\before-disable'
```

如果本机执行策略阻止脚本，检查脚本内容后，可以仅对本次进程使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LegionPowerPlans.ps1 -Action Disable
```

## 如何恢复

使用本项目生成的完整备份文件夹：

```powershell
.\LegionPowerPlans.ps1 -Action Restore -BackupDirectory '.\backups\你的备份时间戳'
```

恢复会核对版本、安装路径、文件哈希和固定模板路径，再恢复原有模板启用状态、缺失的计划、游戏自动性能切换设置及原活动计划。已有相同 GUID 的计划保留，不覆盖后来修改的参数。模板内容与备份不一致时停止，避免覆盖更新后的文件。

备份可整体移动；内部文件使用相对文件名。请保留 `manifest.json` 和所有 `.pow` 文件。备份不能跨安装路径、版本或机器混用。

早期桌面备份包的清单格式与本项目不同：已有桌面备份请继续使用该文件夹自带的 `restore.ps1`，不要用本项目覆盖它。

## 实际改动

1. 读取安装版本、四个计划、活动计划、游戏性能切换值与四份模板。
2. 导出当前存在的目标计划，备份模板并记录 SHA256，完整写入清单后才修改系统。
3. 将 `HKLM\SOFTWARE\WOW6432Node\Lenovo\LegionZone\config` 下的 `PerformanceSwitch` 设为 `0`。
4. 对下表中的四份模板添加 `.disabled-by-user` 后缀。
5. 如果当前计划正是将被删除的联想计划，先切到 Windows 自带“平衡”；其他活动计划保持原样。
6. 删除仍存在的目标计划，并立即复查。已完全禁用时，重复执行不会再修改或创建备份。

| 名称 | 电源计划 GUID |
| --- | --- |
| 安静模式 | `16edbccd-dee9-4ec4-ace5-2f0b5f2a8975` |
| 均衡模式 | `85d583c5-cf2e-4197-80fd-3789a227a72c` |
| 野兽模式 | `52521609-efc9-4268-b9ba-67dea73f18b2` |
| 自定义模式 | `587d380f-60e4-8729-8b42-b40f65eae0ff` |

模板路径相对于 Legion Zone 安装目录：

```text
2.0.28.8182/config/X80_PowerPlan/Balance_Mode.pow
2.0.28.8182/config/X80_PowerPlan/Performance_Mode.pow
2.0.28.8182/config/X80_PowerPlan/Quiet_Mode.pow
config/SYS_SCHEME_BALANCE.pow
```

不会停止 Legion Zone、Gaming AI 或 Fn 热键服务，不修改 BIOS、风扇曲线、超频设置或软件更新设置，也不会安装后台清理任务。删除 Windows 计划不等于删除固件性能档位，Fn+Q 和软件中仍可能显示安静、均衡、野兽等模式。

执行中断时保留备份及 `error.txt`。如果完整 `manifest.json` 已产生，可以尝试恢复已完成的部分；脚本不自动回滚，也不会自动清除失败备份。

## 测试与验证边界

```powershell
.\tests\Run-Tests.ps1
```

测试使用临时文件夹和模块内模拟的电源、注册表接口，覆盖删除与恢复、保留非联想活动计划、重复执行、备份失败、删除中途失败、备份损坏、清单路径异常、模板冲突和版本不匹配。测试不操作真实电源计划或注册表。GitHub Actions 在 Windows PowerShell 与 PowerShell 7 下运行同样的隔离测试。

本项目源自一次本机实际修改：原始脚本执行后等待 12 秒并复查，四个计划未出现、模板已改名、切换值为 0，随后再次复查通过。**本仓库重构版本的写入与恢复流程使用隔离测试验证，没有再次在真实系统执行。** 未验证重新开游戏、重启、长期稳定性、性能或续航。

项目整理期间，Windows PowerShell 5.1 和 PowerShell 7 均通过 11 组隔离测试，本机 `Status` 与 `Disable -WhatIf` 也已执行。只读检查同时发现上述自定义模式重新出现的问题；早期短时间复查通过不能视为持久性验证。

公开仓库仅包含源码、说明和测试；本机 `.pow`、清单、日志不上传，且通过 `.gitignore` 排除。

## 参考

- [Microsoft：Powercfg 命令行选项](https://learn.microsoft.com/zh-cn/windows-hardware/design/device-experiences/powercfg-command-line-options)：用于导出、导入、激活和删除电源计划。
- [联想：拯救者 Fn+Q 电源模式关联说明](https://iknow.lenovo.com.cn/app/detail/196192)：机型和年代之间存在不同的计划关联机制。

自动导入路径依据当前本机插件中的命令与模板路径分析，不是联想公开承诺的稳定接口。
