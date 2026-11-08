# A2 部署前网络检查

把 `check_a2_network.sh` 上传到每台 A2 **宿主机**，运行：

```bash
bash check_a2_network.sh
```

需要相应设备的查询权限；遇到权限不足时，以 root 用户执行。
脚本仅使用 `hccn_tool ... -g` 查询，不修改网络配置。文件为 UTF-8 无 BOM、LF 换行。

## 通过条件

先检查本机 0~7 卡的原有 6 项，再单独检查每卡 TLS，共 56 项：

| 检查项 | 命令 | 通过条件 |
|---|---|---|
| 远端交换机端口 | `-lldp -g` | 能解析到一个非空、非 unknown/none 等占位值的 `Ifname`；不核对实际布线规划 |
| 链路 | `-link -g` | `link status: UP` |
| 网络健康 | `-net_health -g` | `net health status: Success`；其他状态均失败 |
| 网络检测对象 | `-netdetect -g` | 返回一个有效、非零的 IPv4 单播地址 |
| 网关 | `-gateway -g` | 默认要求一个有效、非零的 IPv4 单播地址 |
| NPU IP/掩码 | `-ip -g` | 有效、非零的 IPv4 单播地址，连续且非零的子网掩码，本机各卡 IP 不重复 |
| TLS 全部开启 | `-tls -g` | 本机 0~7 卡必须全部唯一识别为 `tls switch[1]`（开启）；任意卡为 0、查询失败或无法识别均失败 |

每个命令还必须返回 0，并且输出非空。输出格式无法识别时按失败处理，保留原始输出供排查。
检测目标不强制等于网关，也不强制八张卡的交换机端口名称相同。

TLS 查询返回 0 且只提示 `no certificate found`、没有 switch 字段时，按关闭处理并判为失败；命令返回非零仍按查询失败处理。只核对本机开关全部为 1，不验证证书有效期、证书链或跨节点证书一致性。

TLS 检查通过会单独打印 `TLS检查通过：本机0~7卡 tls switch 全部为1（开启）。`；失败则指出卡号及原因。全部为 0 也不通过，不会打印“环境OK”。

随后继续显示：

1. `cat /etc/hccn.conf` 的内容。
2. 重新执行 0~7 卡 `-ip -g`，按 `NPU 卡号  ipaddr:地址` 汇总输出。
3. 总检查结果。
4. 开启、关闭和重新查询 TLS，以及跨节点 NPU ping 的手动命令提示。
5. 在输出末尾显示驱动、固件版本号和版本文件来源；固件文件含 `package_version` 时另列固件包版本号。

检查结果全部通过且上述配置文件、IP 汇总均成功获取时，在结果区打印：

```text
环境OK
```

有失败项时，继续检查其余卡，最后汇总卡号和原因，打印 `环境检查不通过`。

退出码：`0` 全部通过；`1` 56 项检查发现异常；`2` 工具缺失、参数错误，或检查项通过但配置文件/IP 汇总获取失败导致检查未完成。即使发现异常，也会继续显示配置、IP 汇总和命令提示，便于排查。

末尾打印的手动命令包括：

```bash
# HCCN_TOOL 会在提示区设为本次实际使用的工具路径
# 开启 TLS
for i in {0..7}; do "$HCCN_TOOL" -i "$i" -tls -s enable 1; done
# 关闭 TLS（关闭后不满足检查标准）
for i in {0..7}; do "$HCCN_TOOL" -i "$i" -tls -s enable 0; done
# 查询 TLS
for i in {0..7}; do "$HCCN_TOOL" -i "$i" -tls -g; done
# 在当前测试节点执行，替换为另一节点的目标 NPU IP
hccn_tool -i 0 -ping -g address x.x.x.x
```

这些命令仅打印，不自动执行。本脚本要求本机全部开启 TLS，关闭命令仅作操作参考；参与通信的节点间开关需保持一致，开启时还需核对配套证书配置。ping 的目标是另一节点的 NPU IP，`-i 0` 是本机发起测试的卡号。

## 可选设置

如果网络规划明确无需默认网关，可以允许网关值为 `0.0.0.0`，其他检查保持原标准：

```bash
bash check_a2_network.sh --allow-no-gateway
```

自动从 PATH 或 `/usr/local/Ascend/driver/tools/hccn_tool` 查找工具，也可以指定：

```bash
HCCN_TOOL=/实际路径/hccn_tool bash check_a2_network.sh
```

单项默认超时 15 秒，超时后再给 2 秒终止进程；可调整为 30 秒：

```bash
CHECK_TIMEOUT=30 bash check_a2_network.sh
```

默认查看 `/etc/hccn.conf`；如果实际配置在其他路径，可用 `HCCN_CONF=/实际路径/hccn.conf bash check_a2_network.sh` 指定。

末尾默认从以下安装信息文件读取版本号：

```text
驱动：/usr/local/Ascend/driver/version.info 中的 Version
固件：/usr/local/Ascend/firmware/version.info 中的 Version
固件包：同一固件文件中的 package_version（存在时显示）
```

非默认安装位置可通过 `DRIVER_VERSION_FILE`、`FIRMWARE_VERSION_FILE` 指定实际文件。文件读取失败或 Version 字段无法唯一识别时，显示“未获取”；版本显示不改变原有网络检查退出码，也不判断安装版本是否已生效或是否匹配 CANN。

需要保存日志时：

```bash
set -o pipefail
bash check_a2_network.sh 2>&1 | tee a2_network_check.log
```

## 检查范围与验证

`环境OK` 只表示上述本机 IPv4/RoCE 检查项通过。未提供预期交换机端口、IP、网关等规划清单，因此不核对这些值是否符合规划；也不证明跨服务器所有 NPU 两两互通、驱动/固件/CANN 版本兼容、HCCL 性能或模型推理成功。

原有网络检查曾通过 Bash 语法检查及 21 个模拟场景；信息显示逻辑曾通过配置/IP 汇总获取失败、显示顺序和命令提示等模拟验证。TLS 标准改为“全部为 1”后，重新验证了全部开启、全部关闭、仅一张卡关闭、无证书、无法识别和查询失败这 6 个场景：仅全部开启通过，其余均不打印“环境OK”并返回 1。尚未在真实 A2 服务器运行新标准。

参考：[华为 A2 HCCN 网络健康状态说明](https://www.hiascend.com/doc_center/source/zh/HDK/2610/A2/A2HCCN/hccntoola2_022.html)、[vLLM-Ascend 安装前网络检查](https://github.com/vllm-project/vllm-ascend/blob/main/docs/source/getting_started/installation.md)。

TLS 与 ping 参考：[华为 TLS 一致性排查与开关说明](https://www.hiascend.com/doc_center/source/en/canncommercial/850/commlib/hcclug/hcclug_000045.html)、[NPU 跨节点 ping 排查](https://www.hiascend.com/doc_center/source/en/canncommercial/800/hcclug/hcclug/hcclug_000055.html)。

版本读取参考：[华为环境检查中的驱动、固件版本查询](https://www.hiascend.com/doc_center/source/zh/mindcluster/70rc1/faultdiag/faultdiagug/mindxdlFDUG021.html)。
