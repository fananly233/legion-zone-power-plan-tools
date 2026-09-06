# 自定义计划的动态重建与可选补丁

## 已定位的重建机制

`LZTrayPlugin.dll` 的 `SetPowerPlanByFanMode` 处理模式 `0xff` 时会检查自定义计划 GUID。若不存在，则读取运行目录的 `config\SYS_SCHEME_BALANCE.pow`；文件也不存在时，会执行 `powercfg /EXPORT` 将 Windows“平衡”导出，再 `/IMPORT` 为自定义 GUID，随后 `/CHANGENAME`。

初始化、`SmartFanModeChangedCallBack`、`ThermalModeChangedCallBack` 均可到达这段逻辑。关闭 `PerformanceSwitch` 不等于禁用所有回调。

初次方案只改名安装根目录的 `config\SYS_SCHEME_BALANCE.pow`，漏掉了版本目录中的同名文件。更关键的是，即便补充改名版本目录的文件，程序仍能重新导出。

## 为什么没有使用占位文件夹

本机管理员实测发现：将同名路径换成目录可以阻止导出，但 `powercfg /IMPORT` 仍可能先创建目标计划条目，然后返回失败。测试计划已删除。只看退出码无法证明计划没有被创建。

单独拒绝路径的 `ReadAttributes` 权限，也未能让该机 `PathFileExistsW` 返回不存在。该试验仅发生在工作目录，结束后恢复了原权限。

以上方案均未应用到 Legion Zone 安装目录，也未纳入正式修复脚本。

## 精确分支补丁

仅适用于以下文件版本与内容：

| 项目 | 值 |
| --- | --- |
| Legion Zone | 2.0.28.8182 |
| 文件 | `LZTrayPlugin.dll` |
| 原始 SHA256 | `2683C4A52808468854D20631B16CEBD74B6DBCDDEF8D39D75C12EDCB97E7CDCB` |
| 补丁后 SHA256 | `E27CB2AC82BE579A419B17FD490121CC63F301AB7A8CC95ED077F486D7E1817C` |
| 文件偏移 | `0xF675F` |
| 对应 RVA | `0xF735F` |
| 原始六字节 | `0F 85 05 01 00 00` |
| 替换后六字节 | `90 E9 05 01 00 00` |
| 跳转目标 RVA | `0xF746A` |

原指令是 `JNE rel32`；替换后是 `NOP; JMP rel32`。两组指令总长均为 6 字节，跳转位移不变，因此只改变前两个字节，不移动后续代码。不论自定义计划是否存在，均跳过该处创建分支。

这些地址依据该 DLL 的静态分析，不代表进程的实际加载地址。脚本同时检查完整原始哈希、局部原始字节和最终哈希；其他版本或任何不同内容均拒绝修改。

## 影响和恢复

修改后原 DLL 的厂商数字签名失效。脚本不修改证书、签名验证策略、安全软件或驱动。不保证所有环境允许加载此文件；加载失败时会尝试自动恢复已备份的原始文件。

只修改这条托盘创建路径，不能由此证明不存在其他独立创建者。当前有隔离测试及静态验证，真实应用验证和长期观察必须另外记录。软件更新后应重新检查版本及内容，不能强行套用旧偏移。

仓库不包含原始或修改后的厂商 DLL。执行者应保留整个本机备份目录，通过 `Block-CustomPlanRebuild.ps1 -Action Restore` 恢复。恢复操作会校验原始 DLL 哈希，并拒绝覆盖未经识别的当前文件。
