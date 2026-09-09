# Legion Zone Power Plan Tools

**0.3.0 新增中文 Windows GUI：通用电源计划管理 + 按版本开放的联想防重建。**

此版本作为预览版发布。临时 Server VM 原生恢复测试通过；资源库 5 个文件完成导入与参数检查，PowerX / ggOS 被该 VM 拒绝。Windows 10、完整 GUI 修改流程和游戏/重启防重建仍待实测，详见适配矩阵。

下载 [Releases](https://github.com/fananly233/legion-zone-power-plan-tools/releases) 中的 win-x64 便携 ZIP，解压后普通双击 LenovoPowerPlanTools.exe。无需安装 .NET 或 PowerShell 7；修改时单独请求管理员权限。

- 概览、电源计划、联想防重建、备份恢复四个页面，支持界面缩放。
- 收录 NexBox 的六个计划及 optimizerDuck，按需从固定提交下载并验证 SHA256。导入与激活分开，不自动试用。
- 支持本地 .pow 导入、参数查看、导出、切换、删除与恢复。保护 Windows 平衡，导入失败会检查并清理新 GUID 残留。
- Modern Standby / 未知状态只允许激活已确认的平衡类型；PowerX 在 AMD 或无法识别 CPU 上受限制。不会改待机机制或安装守护任务。
- 未适配的 Lenovo 版本仍可使用通用管理；DLL 补丁继续使用精确哈希白名单。

详见 [GUI 使用说明](docs/gui-guide.md)、[适配与实际验证范围](docs/compatibility.md)、[第三方来源声明](THIRD_PARTY_NOTICES.md)。本机备份、运行日志和厂商 DLL 不上传。

### 构建与测试

```powershell
dotnet run --project desktop/LegionPowerPlanTools.csproj
./tests/Run-Tests.ps1
./tests/Run-PatchTests.ps1
./tests/Run-WindowsPlanTests.ps1
dotnet run --project tests/DesktopChecks/DesktopChecks.csproj -c Release
./scripts/Publish-Portable.ps1
```

原生导入验证仅在临时虚拟机中执行，见 Desktop workflow。后文保留原命令行功能及其历史验证说明。

用于备份、删除和恢复 Lenovo Legion Zone 电源计划的 PowerShell 工具。

针对“删除联想电源计划后，启动游戏或切换模式又被创建”的情况，工具会关闭游戏自动性能切换，并把已知导入模板改名为 `.disabled-by-user`，阻止当前版本从原路径导入。所有修改前先创建本机备份。

**基础模板方案无法完整阻止自定义模式重建。** 已定位到托盘插件会把 Windows“平衡”重新导出到版本目录，再导入为自定义计划。新增的可选分支补丁专门跳过这段创建逻辑，详情见下文；它会使被修改 DLL 的联想数字签名失效，不会随基础脚本自动应用。

## 阻止自定义模式重建：可选分支补丁

`Block-CustomPlanRebuild.ps1` 仅接受已核验的 Legion Zone 2.0.28.8182 `LZTrayPlugin.dll` SHA256，修改两字节，将“计划不存在则创建”的条件跳转改为无条件跳过创建分支。它不会修改风扇曲线或硬件性能控制函数，不会关闭系统或软件的签名检查。

**实际影响：DLL 的厂商数字签名会失效。** 软件更新可能覆盖补丁，其他版本会被拒绝。若你不接受修改已签名程序文件，请只使用 `Status` / `-WhatIf`，不要执行 `Apply`。原始厂商 DLL 仅保存到本机备份，不在仓库分发。

```powershell
# 默认只读；查看文件版本、哈希与补丁状态
.\Block-CustomPlanRebuild.ps1
.\Block-CustomPlanRebuild.ps1 -Action Apply -WhatIf

# 明确接受上述影响后，在管理员 PowerShell 中执行
.\Block-CustomPlanRebuild.ps1 -Action Apply

# 撤销补丁，使用 Apply 输出的备份目录
.\Block-CustomPlanRebuild.ps1 -Action Restore -BackupDirectory '.\backups\patch-你的时间戳'
```

执行时会先备份原 DLL、已存在的自定义计划和活动计划标识，再暂时停止托盘、应用补丁、删除自定义计划、启动托盘并验证其实际加载目标 DLL。托盘初始化后等待 12 秒检查是否重新创建。若验证失败，尝试恢复原 DLL、自定义计划及活动计划，并保留错误记录。

补丁只处理自定义计划；三个普通计划仍由 `LegionPowerPlans.ps1` 管理。撤销补丁不会自动撤销之前的模板改名和 `PerformanceSwitch` 设置。完整撤销时按修改顺序倒序恢复对应备份。

**验证边界：**补丁转换、原始字节检查、备份恢复和加载失败回滚已通过隔离测试。2026-09-06 已在上述机型和版本实际应用：磁盘哈希匹配预期，重启托盘后确认加载目标 DLL，初始化后等待 12 秒自定义计划未重建，原非联想活动计划保持不变。签名状态如预期变为 HashMismatch。尚未验证启动游戏、系统重启和长期稳定性；真实恢复流程未执行，恢复与失败回滚使用隔离测试验证。

实现依据和方案限制见 [自定义计划重建分析](docs/custom-plan-rebuild.md)。

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

执行中断时保留备份及 `error.txt`。0.3.0 起，在完整备份后发生修改失败会尝试自动回滚，并把原始错误与回滚错误分别写入 `rollback.json`。不会自动清除失败备份；回滚未完成时可检查清单后手动恢复。

## 测试与验证边界

```powershell
.\tests\Run-Tests.ps1
.\tests\Run-PatchTests.ps1
```

测试使用临时文件夹和模块内模拟的电源、注册表接口，覆盖删除与恢复、保留非联想活动计划、重复执行、备份失败、删除中途失败、备份损坏、清单路径异常、模板冲突和版本不匹配。测试不操作真实电源计划或注册表。GitHub Actions 在 Windows PowerShell 与 PowerShell 7 下运行同样的隔离测试。

补丁测试另有 8 组，使用合成字节和模拟进程，覆盖仅修改两字节、保留跳转目标、拒绝未知文件/字节、等待托盘退出及超时、GUI 重启回调、补丁安装恢复、加载失败回滚、恢复中途失败、重复安装及损坏备份保护。测试不加载或修改真实联想 DLL。

本项目源自一次本机实际修改：原始脚本执行后等待 12 秒并复查，四个计划未出现、模板已改名、切换值为 0，随后再次复查通过。**本仓库重构版本的写入与恢复流程使用隔离测试验证，没有再次在真实系统执行。** 未验证重新开游戏、重启、长期稳定性、性能或续航。

项目整理期间，Windows PowerShell 5.1 和 PowerShell 7 均通过 11 组隔离测试，本机 `Status` 与 `Disable -WhatIf` 也已执行。只读检查同时发现上述自定义模式重新出现的问题；早期短时间复查通过不能视为持久性验证。

公开仓库仅包含源码、说明和测试；本机 `.pow`、清单、日志不上传，且通过 `.gitignore` 排除。

## 参考

- [Microsoft：Powercfg 命令行选项](https://learn.microsoft.com/zh-cn/windows-hardware/design/device-experiences/powercfg-command-line-options)：用于导出、导入、激活和删除电源计划。
- [联想：拯救者 Fn+Q 电源模式关联说明](https://iknow.lenovo.com.cn/app/detail/196192)：机型和年代之间存在不同的计划关联机制。

自动导入路径依据当前本机插件中的命令与模板路径分析，不是联想公开承诺的稳定接口。
