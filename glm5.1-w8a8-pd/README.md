# GLM-5.1 W8A8 · A2 四 P 四 D · v0.23.0.post1

> **公开仓库示例：** 节点 IP 已替换为文档示例地址（192.0.2.0/24），不能直接用于部署。请在八个节点的 `service.sh`、`run_dp_template.sh` 和 P0 代理配置中替换为实际地址，检查网卡、模型路径、镜像和端口，再执行预览。以下为历史配置与验证记录，完整 P→D 链路尚待现场验证。

根据聊天「四个D实例挂掉了，帮我分析下」和原项目的实际脚本迁移。
目标组件：**vLLM-Ascend 0.23.0.post1 + vLLM 0.23.0**。
使用 A2 镜像 `quay.io/ascend/vllm-ascend:v0.23.0.post1`，不是 `-a3` / `-a5` 标签。
本目录是单独生成的新部署文件，旧项目不受影响。

## 机器对应关系

四 P 四 D 指八台机器，实际为 **4 个 P 引擎、8 个 D 引擎**。

| 目录 | IP / bond1 | DP rank | 本机 NPU 分配 | TP | API 端口 | engine_id |
|---|---|---|---|---|---|---|
| p0 | 192.0.2.10 | 0 | 0–7 | 8 | 6606 | 0 |
| p1 | 192.0.2.11 | 1 | 0–7 | 8 | 6606 | 1 |
| p2 | 192.0.2.12 | 2 | 0–7 | 8 | 6606 | 2 |
| p3 | 192.0.2.13 | 3 | 0–7 | 8 | 6606 | 3 |
| d0 | 192.0.2.20 | 0、1 | 0–3 / 4–7 | 4 | 6606 / 6607 | 100、101 |
| d1 | 192.0.2.21 | 2、3 | 0–3 / 4–7 | 4 | 6606 / 6607 | 102、103 |
| d2 | 192.0.2.22 | 4、5 | 0–3 / 4–7 | 4 | 6606 / 6607 | 104、105 |
| d3 | 192.0.2.23 | 6、7 | 0–3 / 4–7 | 4 | 6606 / 6607 | 106、107 |

P 组为 DP4×TP8，主地址 `192.0.2.10:10521`；D 组为 DP8×TP4，主地址 `192.0.2.20:10521`。
保留专家并行，各组需要全部 rank 参加，不能只启动 p0/d0 后等待整组服务就绪。
Mooncake 的 kv_port 基值分别是 P 30000、D 30100；实际握手/传输端口还有 rank 偏移和动态分配，不应只放通这两个端口。
代理在 P0 的 `192.0.2.10:9000`，连接表已包含 4 个 P 和 8 个 D API 地址。

## 宿主机上传和启动

**所有操作均在 Linux 宿主机完成，不需要手动进入容器。**
将每台机器对应节点目录的**全部文件**上传到该宿主机 `/data1/`。
例如 P0 上传本项目 `p0/` 里的文件，D2 上传 `d2/` 里的文件；不要把八个节点的同名文件混在一台机器上。
也支持保留子目录，上传为 `/data1/p0/`、`/data1/d2/`，并在该子目录执行命令。
无论哪种摆放方式，日志默认直接保存在宿主机 `/data1/`。

每台必需的五个文件：

```text
/data1/service.sh
/data1/host_common.sh
/data1/container_entry.sh
/data1/launch_online_dp.py
/data1/run_dp_template.sh
```

P0 额外上传 `proxy.sh`、`proxy_container.sh`、`load_balance_proxy_server_example.py`。
模型默认仍在宿主机 `/data1/GLM-5.1-w8a8/`，对外模型名 `glm-pro`。
宿主机只需 Docker 和 Bash；Python、vLLM、代理依赖使用镜像内部环境。

### 1. 首次准备

在八台机器上准备相同镜像和模型，核对驱动/固件与镜像 CANN 的兼容性。
可提前导入镜像，或执行：

```bash
docker pull quay.io/ascend/vllm-ascend:v0.23.0.post1
```

脚本启动前通过 `docker image inspect` 检查本机镜像，缺失时退出并提示导入/拉取。为兼容现场 Docker，启动命令不使用 `--pull=never` 和 `--init`。按实际安装情况检查宿主机的 `/usr/local/Ascend/driver`、`/usr/local/dcmi`、`/etc/ascend_install.info`、`/usr/local/bin/npu-smi` 挂载路径。
服务容器使用 host 网络、8 张 NPU 和 512 GiB 共享内存上限（按实际使用量消耗宿主机内存）。
脚本目录只读挂载到容器 `/opt/glm51`，宿主机 `/data1` 读写挂载到容器 `/data1`；模型目录单独只读挂载。

### 2. 在每台宿主机直接启动

```bash
cd /data1
bash service.sh --dry-run  # 只预览 Docker 命令和日志路径，不启动容器
bash service.sh            # 后台创建容器并启动本机 P 或 D 服务
bash service.sh logs       # 实时查看本机总日志，Ctrl+C 只退出查看
```

若上传为 `/data1/p0/`，将上述 `cd /data1` 改为 `cd /data1/p0`，其余不变。
脚本中的节点身份、IP 和 rank 已固定，不需要输入 P/D 编号。八台各执行自己的 `service.sh`。
启动命令返回不表示模型已就绪；及时启动整组全部 rank，并观察日志中的加载、通信初始化和 API 就绪情况。
D 节点会自动启动两个引擎，分别使用 0–3、4–7 卡。

常用操作仍在宿主机执行：

```bash
bash service.sh status    # 查看容器状态；不等同于模型健康检查
bash service.sh stop      # 停止本机服务，最长等待 60 秒
bash service.sh           # 停止完成后重新创建并启动，使用当前脚本和环境变量
```

容器名固定为 `glm51-post1-p0` 等。重复启动会拒绝，不会覆盖或停止已有容器。
容器退出后自动移除（`--rm`），日志保留在宿主机；因此已退出容器的 `status` 可能显示不存在，排查时查看宿主机日志。
脚本的 `stop` 只操作标签匹配的本节点容器。整个 P/D 并行组有关联，停止单机可能影响组内其他机器。

### 修改参数后的停止、上传和重启

当前默认：服务共享内存上限 `--shm-size=512g`，对外模型名 `glm-pro`，上下文 `--max-model-len 141312`，代理访问端口 `9000`。
上下文上限计入输入和输出总长度；能否在当前权重与显存配置下启动并运行到该长度，需要目标机器验证。
内部 P/D API 端口仍为 `6606/6607`，客户端入口为 `http://192.0.2.10:9000/v1/chat/completions`。

先在 P0 的宿主机脚本目录停止代理：

```bash
bash proxy.sh stop
```

再在八台机器各自的宿主机脚本目录停止本机服务，等待所有旧服务退出：

```bash
bash service.sh stop
```

每台上传该节点更新后的 `host_common.sh`、`run_dp_template.sh`；P0 另上传更新后的 `proxy_container.sh` 和 `load_balance_proxy_server_example.py`。
覆盖到实际使用的目录（平铺 `/data1/` 或 `/data1/节点名/`）。
然后在八台对应目录先预览，再启动全部节点：

```bash
bash service.sh --dry-run
bash service.sh
```

等全部 API 引擎就绪后，在 P0 执行 `bash proxy.sh`。
这些参数仅在新建容器/服务进程时生效；直接覆盖文件不会改变已经运行的模型参数。
所有操作只针对本项目命名的容器，宿主机 `/data1/` 的旧日志保留。
本次只修改本地部署文件，未操作服务器上的运行服务。

### 已处理的现场启动问题

- `unknown flag: --pull`：现场部分 Docker 不支持该参数，八个节点已统一移除 `--pull=never`，保留启动前的本地镜像检查。
- `exec: "docker-init": executable file not found in $PATH`：现场缺少 Docker init 程序，八个节点已统一移除 `--init`；P0 代理复用同一宿主机脚本，也包含此修正。
- `Container already exists`：保留重复启动保护。先执行 `bash service.sh status`；若容器正在运行，先查看日志，需要重启时再执行 `bash service.sh stop`。不要直接强制删除正在运行的容器。
- 若此前启动失败留下 `Created` / `Exited` 容器，先确认状态，再执行 `docker rm glm51-post1-节点名` 删除该失败容器，然后重新启动。
- `No log record`：启动失败时可能尚未生成 `.latest` 记录，应先处理 `bash service.sh` 当场输出的错误；若容器已运行，检查 `/data1/service_glm51_节点名_*.log`。

本次修正只影响后续创建容器的命令。已运行的服务无需为此立即重启；服务器上已经手动完成同样修改的文件，不必重复操作。

#### D3：ZerosLike / tiling 初始化失败（2026-10-11）

**现象与定位：** D3 启动时出现以下错误，随后服务退出；容器因 `--rm` 自动移除，故障日志仍保留在宿主机 `/data1/`。

```text
aclnnInplaceZero failed, error code is 361001
SpaceRegistry is nullptr, op type is ZerosLike
Reason: The tiling function does not exist.
InitTilingParseCtx failed
```

用户现场对照显示，D2 与 D3 使用相同镜像 ID、910B2 和 25.5.2 驱动，但容器运行环境不同：

| 项目 | D2 | D3 |
|---|---|---|
| Docker | 18.09.0，EulerVersion 18.09.0.335，2024 年构建 | 18.09.0，Docker CE，2018 年构建 |
| 内核 | 5.10.0-136.49.0.127.10.oe2203.bclinux.aarch64 | 4.19.90-2211.5.0.0178.22.uel20.aarch64 |
| libseccomp | 2.5.3-1.oe2203.aarch64 | 2.5.0-4.uel20.aarch64 |
| 默认 seccomp 下检查 CANN 文件 | 正常，`test -r` 返回 0 | `Operation not permitted`，`test -r` 返回 1 |
| 加 `--security-opt seccomp=unconfined` 后 | 正常 | 恢复正常，`test -r` 返回 0 |

文件检查在相同镜像、无 NPU/驱动挂载、`--network none` 的临时容器中完成，检查对象包括 `/usr/local/Ascend/cann-9.1.0` 和下面的库：

```text
/usr/local/Ascend/cann-9.1.0/opp/built-in/op_impl/ai_core/tbe/op_tiling/lib/linux/aarch64/liboptiling.so
```

随后在 D3 映射全部 8 张 NPU 及管理设备、挂载驱动，设置 `ASCEND_RT_VISIBLE_DEVICES=4,5,6,7`。Python 检测到 4 个设备，选择逻辑设备 `npu:0`，执行小张量 `zero_()`、`zeros_like()` 和同步：

| seccomp 设置 | `ACL_OP_INIT_MODE` | 默认环境 / 显式加载 CANN 环境 |
|---|---|---|
| 默认策略 | 0、1 | 均复现 tiling / ZerosLike 错误 |
| `unconfined` | 0 | 均输出 `ZerosLike PASS: 0.0`，退出码 0 |
| `unconfined` | 1 | 均输出 `ZerosLike PASS: 0.0`，退出码 0 |

对照实验将本次故障定位到 **D3 默认 seccomp 策略与镜像运行环境的兼容问题**。具体被拦截的系统调用尚未追踪，不能仅凭这些结果断言是某个 syscall。修改 `ACL_OP_INIT_MODE` 或补充加载 CANN 环境均未单独解决问题；成功测试仍出现 CANN/HDK 的 32 padding 提示，该提示不能单独作为失败依据。

**已同步的修改：** 仅在 `d3/host_common.sh` 的 service 分支增加：

```bash
if [[ "$PROCESS_KIND" == service ]]; then
    command+=(--security-opt seccomp=unconfined)
    command+=(--shm-size=512g
        --mount "type=bind,source=$model_dir,target=/data1/GLM-5.1-w8a8,readonly"
        --env MODEL_PATH=/data1/GLM-5.1-w8a8/)
```

`d3/run_dp_template.sh` 保持 `ACL_OP_INIT_MODE=1`。其他节点、MTP、DP/TP 和模型参数保持原配置。此项为 D3 单个服务容器的临时兼容措施，会取消该容器的 seccomp 系统调用过滤；没有全局关闭 Docker 安全策略，也没有增加 `--privileged`。长期应评估与宿主机系统匹配的受维护容器运行时，升级后重新验证默认策略。

**部署与验证范围：** 将更新后的 `d3/host_common.sh` 上传到 D3 的 `/data1/d3/host_common.sh`（如脚本平铺，则为 `/data1/host_common.sh`），在对应目录执行 `bash service.sh --dry-run`，确认输出含 `--security-opt seccomp=unconfined`。该参数需要重新创建服务容器才能生效；若此次故障已使 D 并行组退出或失联，应在 D0–D3 各自停止残留服务，再启动完整 D 组并检查各引擎日志。

目前现场验证通过的是 D3 文件访问及上述单个逻辑设备的小张量算子测试，**不代表全部 NPU、跨机通信、完整模型加载或 P→D 链路已验证通过**。本地脚本已通过语法和启动命令预览检查；上传、服务重建及完整推理验证仍需在目标机器完成。

### 3. 日志位置

所有日志直接写入宿主机 `/data1/`，例如：

```text
/data1/service_glm51_p0_20261010_120000_12345.log    # P0 总日志
/data1/service_glm51_d2_20261010_120000_12345.log    # D2 总日志
/data1/glm_d2_dp4_port6606_20261010_120001_100.log   # D2 第一个引擎
/data1/glm_d2_dp5_port6607_20261010_120001_101.log   # D2 第二个引擎
/data1/proxy_glm51_p0_20261010_123000_12346.log      # P0 代理日志
```

时间戳和进程号会随每次启动变化，旧日志不会被覆盖。
`service_glm51_节点.latest` / `proxy_glm51_p0.latest` 是记录最新日志文件名的小文本文件，供 `logs` 命令使用。
总日志包含启动器、版本信息和各引擎输出；每个引擎另有独立日志，便于定位 rank。
这些是服务标准输出/错误日志；Ascend 设备底层 plog/device 日志仍按驱动自身配置采集。

### 4. 在 P0 宿主机启动代理

等所有 P/D API 引擎就绪后，在 P0 存放脚本的目录执行：

```bash
bash proxy.sh
bash proxy.sh logs
```

代理使用独立容器 `glm51-post1-p0-proxy`，不占用 NPU，入口仍为 `192.0.2.10:9000`。
同样支持 `bash proxy.sh stop`、`status`、`--dry-run`。

通过代理测试完整链路：

```bash
curl --noproxy '*' -sS -i http://192.0.2.10:9000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"glm-pro","messages":[{"role":"user","content":"请用一句话介绍你自己。"}],"max_tokens":1024,"stream":false}'
```

结合 P、D 日志确认请求经过预填充、KV 传输和解码；健康检查或直接请求 D 成功不能单独证明完整链路。
保留原代理 OpenAI 接口、`/v1/messages` 兼容逻辑及新版 `kv_transfer_params` 整体透传。

### 5. 可选覆盖

宿主机模型路径不同时：

```bash
MODEL_DIR=/实际模型目录 bash service.sh
```

脚本仍将该路径只读挂载到容器 `/data1/GLM-5.1-w8a8/`。
`MODEL_PATH` 也接受宿主机模型目录作为兼容别名，优先级低于 `MODEL_DIR`。
`SERVED_MODEL_NAME` 可覆盖模型名；八台与客户端保持一致。
`IMAGE` 可指定本机镜像别名；确保实际内容仍为本次 post1 基线。
`HOST_DATA_DIR` 可覆盖宿主机日志目录，默认即用户要求的 `/data1`；使用管理命令时要提供相同值。
根目录 `docker_run.sh` 仅作为上传整个项目时的便捷入口，等价于调用相应节点的 `service.sh`，单节点上传不需要它。

## 本次迁移内容

- 删除旧 `kv_connector_module_path`，使用插件注册的 `MooncakeConnectorV1`。
- 删除旧 `use_ascend_direct` 扩展字段，保留 P/D 拓扑描述；kv_port 使用整数。
- 将 `enable_npugraph_ex`、`fuse_qknorm_rope`、`fuse_muls_add` 移至 `additional-config.ascend_compilation_config`。
- 使用 `VLLM_MOONCAKE_ABORT_REQUEST_TIMEOUT=480`。
- MTP 默认仍为 3，P/D 都加 `enforce_eager:true`；P 主模型 eager，D 主模型保留 `FULL_DECODE_ONLY`。
- P 关闭 MLAPO，D 保留开启；FlashComm1 用新版 additional-config 配置，P 开、D 关；删除旧拼错的变量。
- 每个独立引擎的 engine_id 唯一；启动器传播失败状态并清理本机同批启动的进程。
- 上下文设为 141312 token（138 × 1024）；P 的 batch=4096 / seqs=32 / memory=0.96，以及 D 的 batch=32 / seqs=8 / memory=0.95。

## MTP 对照和验证边界

默认配置遵循原部署意图，启用 MTP=3。若先做 MTP 关闭基线，在**全部八台机器**使用：

```bash
MTP_TOKENS=0 bash service.sh --dry-run
MTP_TOKENS=0 bash service.sh
```

恢复时先结束上一组服务，再在所有节点使用 `MTP_TOKENS=3 bash service.sh`。
不要在同一组中混用 MTP 设置；无需修改八份模板即可切换。
MTP、模型路径和模型名等覆盖值会由宿主机脚本传入新容器；修改配置后先停止旧服务再启动。

初始脚本生成阶段完成了本地语法、生成参数、代理元数据转发，以及宿主机入口的模拟检查：八台挂载/端口/身份、重复启动拦截、停止目标校验、日志落盘和引擎非零退出传播。该阶段的 Docker 和模型启动使用模拟程序验证。2026-10-11 用户提供了现场启动故障和 D3 真实 NPU 算子对照结果，见上文故障记录；尚无八台完整服务及端到端推理验证通过的证据。
本版本和新增的 MTP eager 参数**不构成 131072 边界越界已修复的证据**。
目标环境还需验证：完整 P→D 链路、MTP 关闭/开启对照、接近当前 141312 上限的边界请求及后续请求、长时间稳定性与显存余量。
如需缩小为一 P 一 D，必须同时调整 DP/EP 组大小、rank、Mooncake 拓扑和代理后端，不能只停掉其余六台。

## 固定版本参考

- [GLM-5/5.1 指南](https://github.com/vllm-project/vllm-ascend/blob/v0.23.0.post1/docs/source/tutorials/models/GLM5.md)
- [Ascend 配置解析](https://github.com/vllm-project/vllm-ascend/blob/v0.23.0.post1/vllm_ascend/ascend_config.py)
- [连接器注册](https://github.com/vllm-project/vllm-ascend/blob/v0.23.0.post1/vllm_ascend/distributed/kv_transfer/__init__.py)
- [Mooncake 实现](https://github.com/vllm-project/vllm-ascend/blob/v0.23.0.post1/vllm_ascend/distributed/kv_transfer/kv_p2p/mooncake_connector.py)
- [同版本代理参考](https://github.com/vllm-project/vllm-ascend/blob/v0.23.0.post1/examples/disaggregated_prefill_v1/load_balance_proxy_server_example.py)
