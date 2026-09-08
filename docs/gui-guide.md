# 联想电源计划工具 0.3.0 使用说明

解压整个便携包，普通双击 LenovoPowerPlanTools.exe。程序自带 .NET 运行环境，无需 PowerShell 7；不要先以管理员身份打开主界面。修改时会单独弹出 Windows 管理员提示，取消不会执行操作。

## 日常使用

- 概览显示当前活动计划、CPU、机型、Modern Standby 和联想软件适配状态。
- 电源计划页面上半部分是本机已有计划。选中后可查看完整 AC/DC 参数、导出、激活或删除。Windows 平衡计划受到保护。
- 下半部分是 7 个第三方计划。下载与导入分开，导入不会自动激活。点击来源可查看固定上游版本，点击许可证可查看上游声明。
- 支持导入自行取得的本地 .pow；工具会识别与目录中相同哈希的文件并沿用限制。本地未知文件由用户判断来源，激活仍受现代待机类型检查。
- 界面可切换 100%、125%、150% 缩放；内容可滚动。

计划名称不代表已验证适用性。PowerX v2 的源说明警告部分 AMD CPU 可能蓝屏，本工具禁止 AMD 或未识别 CPU 使用已识别的该计划。ggOS 是桌面游戏取向。其他计划也不承诺提高帧率、续航或降低温度。

Modern Standby 支持状态未知时按保守规则处理：只有在交流电及电池下均确认属于平衡类型的计划可以激活。不会更改 PlatformAoAcOverride 或强行关闭现代待机。

## 联想防重建

首版只有 Legion Zone 2.0.28.8182 的已知模板规则及指定 SHA256 的 DLL 补丁。其他软件和版本显示未适配，通用管理仍然可用。

“备份并清理联想计划”关闭自动切换、改名模板并删除四个已知 GUID；不能单独彻底阻止自定义计划动态重建。

高级分支补丁修改两字节、使厂商 DLL 签名失效。只有匹配的文件才能应用；操作会暂时停止托盘，由普通权限界面重新启动，管理员工作进程验证 DLL 加载。软件更新可能覆盖补丁。操作失败会尝试恢复并保留原始错误及恢复错误。

Windows 电源计划与 Fn+Q、风扇曲线、固件性能档位不同；工具不控制这些硬件设置，也不安装后台守护或开机任务。

## 备份与恢复

新操作的备份在 %ProgramData%\LenovoPowerPlanTools\backups。下载缓存在 %LocalAppData%\LenovoPowerPlanTools\cache。失败诊断会保留在相应目录的 session-* 文件夹。不会自动上传这些文件。

在备份恢复页面选择记录，或选择含 manifest.json 的完整目录。通用备份校验本机标识、计划文件哈希和操作类型；检测到同 GUID 冲突或导入后参数发生变化时停止，保留用户后续修改。恢复切换操作会重新启用记录中的原活动计划。

项目原有 SchemaVersion 1 基础/补丁备份通过对应旧恢复模块处理：校验安装路径、版本与文件哈希；这些旧格式没有机器绑定。更早的桌面备份包请使用其原配套 restore.ps1，不混合不同备份的文件。

如果报告 RollbackIncomplete 或 RestoreIncomplete，请先查看该记录中的错误，不要反复点击。恢复结果包含未完成步骤；不代表所有失败情况都能自动恢复。

## 命令行与构建

原 LegionPowerPlans.ps1 和 Block-CustomPlanRebuild.ps1 参数保持兼容。新增 WindowsPowerPlans.ps1，默认 Status，支持 Import、Activate、Export、Delete、Restore 和 -WhatIf。

开发环境需要 .NET 10 SDK。运行 scripts/Publish-Portable.ps1 生成自包含 win-x64 ZIP；测试命令及实际覆盖范围见仓库 README 和适配与验证文档。
