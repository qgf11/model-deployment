# 四机 A2：P DP4×TP2 + D DP16×TP1，DSpark W8A8

生成日期：2026-10-31。每台按 8 张 64GB NPU 配置，共 32 张卡。

本包基于用户已部署成功的新四机 DP2×TP4 配置，只调整 P 侧拓扑；默认 P 显存比例 0.95、D 0.96。本包尚未在新四机启动验证。

## 1. 拓扑与权重

| 文件夹 | 服务组织 | 全局 DP × TP | 本机 DP 数 | DP rank | NPU | engine_id / kv_port |
|---|---|---|---|---|---|---|
| P0 | 独立的单机 P 实例 | DP4 × TP2 | 4 | 0–3 | 0–7 | 0 / 30000 |
| P1 | 独立的单机 P 实例 | DP4 × TP2 | 4 | 0–3 | 0–7 | 1 / 30100 |
| D0 | 两机 D 集群的主节点 | DP16 × TP1 | 8 | 0–7 | 0–7 | 2 / 30200 |
| D1 | 同一个 D 集群的第二节点 | DP16 × TP1 | 8 | 8–15 | 0–7 | 2 / 30200 |

P0/P1 是两个独立的单机 DP4 组，并非跨机一个 DP8 组；每台有四个 DP rank，每个 rank 使用两张 NPU：0–1、2–3、4–5、6–7。D0/D1 共同组成一个全局 DP16 组。
全部开启 `--enable-expert-parallel`。D1 的 DP 地址必须指向 D0；P0、P1 分别指向自己。
代理部署在 P0，纳入 8 个 P HTTP 端点和 16 个 D HTTP 端点。

- 四机统一权重：`DeepSeek-V4-Flash-0731-w8a8`（DSpark W8A8）。
- 不使用 `DeepSeek-V4-Flash-w8a8-mtp` 或单机示例的 W4A8 测试权重。
- 四机镜像：`quay.io/ascend/vllm-ascend:v0.26.0rc2`（A2，无 `-a3` 后缀）。
- 四机 DSpark：`{"method":"dspark","num_speculative_tokens":7,"enforce_eager":true}`。
- 对照实际权重 `config.json`，确认检查点支持此 DSpark 推测数；如更改，四机同步更改，且至少为 5。

## 2. 相对官方 8 机示例的修改

| 参数 | 官方 A2 DSpark 示例 | 本配置 |
|---|---|---|
| P 机器数 | 4 | 2 |
| 每个 P 的 DP × TP | DP4 × TP2 | DP4 × TP2 |
| D 机器数 | 4 | 2 |
| 整个 D 集群的 DP × TP | DP32 × TP1 | DP16 × TP1 |
| D rank 起点 | 0 / 8 / 16 / 24 | 0 / 8 |
| Connector 的 prefill 布局 | DP4 / TP2 | DP4 / TP2，每个独立 P 实例，四机一致 |
| Connector 的 decode 布局 | DP32 / TP1 | **DP16 / TP1，四机脚本同步** |
| 上下文上限 | 200000 | 262144，输入与输出合计 |
| P / D 每步 token 预算 | 4096 / 256 | 4096 / 256 |
| P / D 每 DP rank 的序列上限 | 32 / 32 | 32 / 32 |
| P / D 显存占用比例 | 0.90 / 0.95 | 0.95 / 0.96 |

P 主模型使用 eager；D 主模型保留 `FULL_DECODE_ONLY`，DSpark 草稿模型 eager。
两侧使用 async scheduling、block size 32、hybrid KV cache manager；P 显式开启 DSA-CP 和 FlashComm1。
重算调度 `recompute_scheduler_enable` 仅在 D 侧开启；使用与镜像版本配套的官方代理。
`HCCL_CONNECT_TIMEOUT` 在 P0/P1 设为 1200，D0/D1 设为 1500，按照 A2 DSpark 官方示例区分；修改后需重启对应节点才能生效。
262144 是本部署要求，超过官方示例中的 200000；实际权重是否支持该长度及四机显存、KV Cache 容量尚需启动和长文本请求验证。上述序列数不代表已验证的容量或最佳性能。

## 3. 文件说明

每个节点文件夹可单独复制到对应服务器，不依赖其他文件夹：

- `cluster.env`：四台 IP、模型路径、镜像、容器名与日志根目录，四份应保持一致。
- `node.env`：节点身份、网卡名、rank 起点和实例标识。
- `start.sh`：**宿主机一键启动**，后台创建/复用容器，然后后台启动本机所有 DP rank。
- `docker_run.sh`：宿主机单独创建/复用后台容器，使用 `docker run -itd`。
- `stop.sh`：宿主机停止本机服务与容器，保留容器和全部日志。
- `start_in_container.sh` / `service_control.sh`：由宿主机入口自动调用，负责环境检查、启动、互斥与停止。
- `launch_online_dp.py`：启动与监视各 rank，任一 rank 异常退出即终止本机其他 rank。
- `run_dp_template.sh`：实际 vLLM 参数与运行环境。
- P0 另有官方代理源码、宿主机代理入口 `start_proxy.sh`、宿主机测试入口 `smoke_test.sh`，以及配套容器内部脚本。

脚本为 UTF-8、LF 换行。使用 `bash 文件名.sh`，不依赖可执行权限。

## 4. 节点地址与部署前确认

已按提供的顺序，在四个 `cluster.env` 中配置相同的四个 IP：

```bash
P0_IP=10.26.2.14
P1_IP=10.26.2.15
D0_IP=10.26.2.16
D1_IP=10.26.2.17
MODEL_PATH=/data1/DeepSeek-V4-Flash-0731-w8a8
P_DP_SIZE=4
P_TP_SIZE=2
D_DP_SIZE=16
D_TP_SIZE=1
P_MEMORY_UTILIZATION=0.95
D_MEMORY_UTILIZATION=0.96
MAX_MODEL_LEN=262144
SERVED_MODEL_NAME=deepseek
PROXY_PORT=1036
```

用户确认四台新机器使用 `bond1`，权重路径为 `/data1/DeepSeek-V4-Flash-0731-w8a8`；已填入每台配置。服务器实际网卡、权重文件内容和硬件状态尚未经本机读取；启动前仍需确认四机权重一致及服务器与 A2 镜像兼容。
宿主机 `/data1/` 整体挂载到容器 `/data1/`，两侧使用同一个权重绝对路径。
如果实际权重文件夹名称不同，修改四份 `MODEL_PATH`。宿主机只需 Bash、Docker，不需要安装 vLLM 或 Python。
四台必须为同一权重版本，不能只看目录名相同；应对照权重文件清单与校验值。
默认容器名为 `dsv4-flash`；四台独立宿主机可以使用同一个容器名。
如果已经有其他同名容器，脚本会停止并提示，不会删除或替换它；可修改 `CONTAINER_NAME`。

先确认驱动、固件、CANN、容器与 Mooncake 版本兼容，完成单机及跨机 NPU 网络验证。
原部署目录有 `check_a2_network.sh` 可单独上传用于单机检查；单机通过不等于跨机推理已通过。

例如在 P0 宿主机查看到另外三台的路由，并在 P1/D0/D1 各自反向检查到 P0 的路由：

```bash
# P0：查看出接口和源地址
ip route get 10.26.2.15
ip route get 10.26.2.16
ip route get 10.26.2.17
# 在 P1、D0、D1 上分别执行
ip route get 10.26.2.14
```

检查路由是否使用实际业务网卡和对应本机源 IP；还需分别验证业务端口与 NPU HCCN/RDMA 跨机链路。`ip route get` 仅显示路由选择，不能证明端口或 RDMA 可达。

网络需要覆盖业务 HTTP、DP/HCCL/Gloo 及 NPU RDMA 通信，不应只放行代理端口：

- P0/P1 HTTP：7100–7103；D0/D1 HTTP：7100–7107；P0 对外代理：1036。
- DP RPC：12321。P 是各自独立组；D 统一连接 D0。
- KV 基础端口：P0=30000、P1=30100、D=30200；connector 还会按 rank 分配监听端口。
- 8 卡 AscendDirectTransport 可能使用 20000–27999；HCCL 等也可能动态使用端口。
- `kv_port` 不放在上述 20000–27999 范围内；完整放行策略按实际网络和运行日志核实。

## 5. 切换与启动顺序

新包分别上传到四台服务器的 `/data1/dsv4-dp4tp2/`，不要覆盖现有 `/data1/dsv4-dp2tp4/`。两套方案共用机器、NPU、容器名、端口和日志目录，不能同时运行。切换前请确认可以中断服务，在各台用旧方案对应的 `stop.sh` 停止当前服务并确认进程退出，再用新方案的 `start.sh` 启动；不要改用新容器名尝试并行。保留旧目录供回退，详见下方切换步骤。

将对应文件夹上传到各自宿主机 `/data1/` 下，示例目录：

```text
P0 宿主机：/data1/dsv4-dp4tp2/P0/                                  /data1/logs/P0/
P1 宿主机：/data1/dsv4-dp4tp2/P1/                                  /data1/logs/P1/
D0 宿主机：/data1/dsv4-dp4tp2/D0/                                  /data1/logs/D0/
D1 宿主机：/data1/dsv4-dp4tp2/D1/                                  /data1/logs/D1/
每台权重：/data1/DeepSeek-V4-Flash-0731-w8a8/config.json
```

**切换会中断当前推理服务。** 确认实际旧脚本路径后，在对应宿主机依次执行（路径若不同，以服务器实际路径为准）：

```bash
# P0：停止旧代理、引擎和容器
bash /data1/dsv4-dp2tp4/P0/stop.sh
# P1
bash /data1/dsv4-dp2tp4/P1/stop.sh
# D0
bash /data1/dsv4-dp2tp4/D0/stop.sh
# D1
bash /data1/dsv4-dp2tp4/D1/stop.sh
```

检查各机原服务进程、端口和 NPU 占用已退出；若停止失败先排查，不要启动新方案。新方案会复用同名容器和日志目录，历史日志保留；`latest-*` 指向最近启动的日志。回退时在各机用本包对应 `stop.sh` 停止后，再从旧目录启动四台及 P0 代理。

**以下全部在宿主机执行，无需手动进入容器。** 分别在四台宿主机运行：

```bash
# D0 宿主机
bash /data1/dsv4-dp4tp2/D0/start.sh
# D1 宿主机
bash /data1/dsv4-dp4tp2/D1/start.sh
# P0 宿主机
bash /data1/dsv4-dp4tp2/P0/start.sh
# P1 宿主机
bash /data1/dsv4-dp4tp2/P1/start.sh
```

每条 `start.sh` 自动完成创建/复用后台容器和后台启动推理；关闭当前终端不会停止推理。
先启动 D0，随后立即在 D1 启动，两台 D 需共同完成初始化，无需等待 D0 单独就绪；再分别启动 P0/P1。
脚本返回 `launched in the background` 只表示进程已启动，**模型初始化和健康检查可能尚未完成**。
重复执行会通过锁检查已运行的服务，避免重复启动一套 rank。

启动前依赖检查会在镜像提供 jemalloc 时预加载它；网卡检查使用 Python 标准库读取配置网卡的主 IPv4 地址，无需容器安装 `ip` 命令。若配置使用的是网卡附加地址，该检查不适用。

在宿主机查看启动日志，例如 P0：

```bash
tail -F /data1/logs/P0/latest-engine.log
# 对应时间戳子目录保存各 rank 的详细推理日志
ls -lt /data1/logs/P0/
# 如需实时查看某个 rank，将下面的目录替换成实际时间戳
tail -F /data1/logs/P0/实际时间戳/rank-0.log
```

全部日志保存在宿主机 `/data1/logs/节点名/`：

- `engine-时间戳.log`：启动器、环境检查和 rank 退出信息；`latest-engine.log` 指向最近一次日志。
- `时间戳/rank-N.log`：各 DP rank 的 vLLM 推理日志。
- P0 的 `proxy-时间戳.log` 和 `latest-proxy.log`：代理日志。
- P0 的 `smoke-时间戳.json`：端到端请求响应。
- `ascend/`：容器 `/root/ascend/log` 的持久化目录。

不会删除历史日志。`docker logs dsv4-flash` 主要显示容器主进程日志；推理详细日志以这些文件为准。

四台后端就绪后，在 **P0 宿主机** 启动代理：

```bash
bash /data1/dsv4-dp4tp2/P0/start_proxy.sh
tail -F /data1/logs/P0/latest-proxy.log
```

代理启动时不再强制检查后端 `/health`，但推理请求仍需相应的 P/D 引擎就绪。建议结合各节点日志和健康接口确认状态。
健康接口可访问也不代表已完成 KV 传输与推理，应继续进行端到端验证。
官方代理使用容器内同版本 `vllm_ascend.patch.recompute_proxy`，入口会自动通过 docker exec 在容器中运行它。

## 6. 端到端验证

在 P0 宿主机另一个终端执行：

```bash
bash /data1/dsv4-dp4tp2/P0/smoke_test.sh
```

它通过 `P0_IP:1036/v1/chat/completions` 请求生成并保留 JSON 响应，检查 `choices` 和生成内容。
仅有非空 reasoning 也可能是 token 上限内仍在思考，应结合 finish_reason 查看，必要时提高 max_tokens。
再对照 P、D 日志确认实际 KV 传输、无重算/推理异常，并连续测试多次、混合长度、目标并发后再评估性能。
不要把直接请求 D 的成功等同于 P/D 链路成功。

外部请求示例：

```bash
curl --noproxy '*' http://10.26.2.14:1036/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek","messages":[{"role":"user","content":"请用中文简短介绍你自己。"}],"max_tokens":256,"temperature":0,"stream":false}'
```

## 7. 查看参数与停止

无需 NPU 即可查看生成命令（允许保留 IP 占位符）：

```bash
# 在对应节点文件夹中查看宿主机容器/服务启动命令
bash docker_run.sh --dry-run
bash start.sh --dry-run
# 查看本机所有 rank 的 vLLM 参数；本地执行需要 python3，但真正部署时由容器执行
bash start_in_container.sh --dry-run
# 仅 P0
bash start_proxy.sh --dry-run
bash proxy_in_container.sh --dry-run
```

停止时，在各宿主机执行对应 `stop.sh`，例如 P0：

```bash
bash /data1/dsv4-dp4tp2/P0/stop.sh
```

P0 会先停止代理，再停止推理；各节点随后停止自己的容器，保留日志和容器。
后续重新执行 `start.sh` 即可启动已停止的容器和服务。修改服务参数后，先 stop 再 start。
如果修改镜像或已有同名容器不属于本配置，使用新的 `CONTAINER_NAME`，不自动删除旧容器。
查看日志时 Ctrl+C 只退出 tail，不停止后台推理。

需要比较 D 的 eager/graph 时，两台 D 同时将 `D_ENFORCE_EAGER=1` 后重启比较。
这只是排查或对照开关；当前未据此声称修复任何具体版本的问题。

## 8. 来源和验证边界

- [官方 DeepSeek-V4-Flash 文档 5.2.2](https://docs.vllm.ai/projects/ascend/en/v0.26.0rc1/tutorials/models/DeepSeek-V4-Flash.html#a2-series-pd-separation-deployment)
- [官方 Mooncake 多机部署说明](https://docs.vllm.ai/projects/ascend/en/v0.26.0rc1/tutorials/features/pd_disaggregation_mooncake_multi_node.html)
- [随包官方代理源码，固定 v0.26.0rc2 提交](https://github.com/vllm-project/vllm-ascend/blob/155f68974c802633c19650ece430d41ee6802fa6/examples/disaggregated_prefill_v1/load_balance_proxy_server_example.py)

提供的文档 URL 属于 v0.26.0rc1 路径，但页面安装说明实际指定 A2 镜像 v0.26.0rc2，因此此包使用 rc2。
代理按 rc2 标签固定到提交 `155f68974c802633c19650ece430d41ee6802fa6`，保留官方文件原文和许可声明。
本包仅完成脚本语法、配置、离线命令生成及代理端点检查；未连接四台 A2，未验证实际启动、显存容量、跨机 KV 传输、推理正确性或吞吐。
