#!/usr/bin/env bash
# A2 8-NPU IPv4/RoCE preflight. Read-only: every hccn_tool call uses -g.
# Usage: bash check_a2_network.sh [--allow-no-gateway]
# Tool override: HCCN_TOOL=/path/to/hccn_tool bash check_a2_network.sh
set -uo pipefail
export LC_ALL=C

allow_no_gateway=0
case "${1:-}" in
    '') ;;
    --allow-no-gateway) allow_no_gateway=1 ;;
    -h|--help)
        echo 'Usage: bash check_a2_network.sh [--allow-no-gateway]'
        echo '检查本机 0~7 卡 IPv4/RoCE；仅在确认无需网关时使用 --allow-no-gateway。'
        exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo '参数过多' >&2; exit 2; }

tool="${HCCN_TOOL:-}"
if [[ -z "$tool" ]]; then
    tool="$(command -v hccn_tool || true)"
    [[ -n "$tool" ]] || tool=/usr/local/Ascend/driver/tools/hccn_tool
fi
[[ -x "$tool" ]] || { echo "检查未完成：找不到可执行工具 $tool" >&2; exit 2; }
for dep in timeout awk tr cat; do
    command -v "$dep" >/dev/null 2>&1 || { echo "检查未完成：缺少 $dep" >&2; exit 2; }
done
command_timeout="${CHECK_TIMEOUT:-15}"
[[ "$command_timeout" =~ ^[1-9][0-9]*$ ]] || { echo 'CHECK_TIMEOUT 必须为正整数秒' >&2; exit 2; }

failures=0
passed=0
errors=()
declare -A seen_ips=()
raw=''
fail() {
    printf '[FAIL] NPU %s / %s：%s\n' "$i" "$item" "$1"
    errors+=("NPU $i / $item：$1")
    failures=$((failures + 1))
}
pass() {
    printf '[PASS] NPU %s / %s：%s\n' "$i" "$item" "$1"
    passed=$((passed + 1))
}
query() {
    local rc=0
    raw="$(timeout --kill-after=2s "${command_timeout}s" "$tool" -i "$i" "$1" -g 2>&1)" || rc=$?
    raw="${raw//$'\r'/}"
    printf '\n$ hccn_tool -i %s %s -g\n%s\n' "$i" "$1" "${raw:-(无输出)}"
    if (( rc != 0 )); then
        fail "命令失败或超时，退出码 $rc"
        return 1
    fi
    if [[ -z "${raw//[[:space:]]/}" ]]; then
        fail '命令输出为空'
        return 1
    fi
}
# Require exactly one named field; preserve colons inside interface names.
field() {
    awk -v key="$1" '
        { p=index($0, ":"); if (!p) next
          k=substr($0,1,p-1); gsub(/^[ \t]+|[ \t]+$/, "", k)
          if (tolower(k)==tolower(key)) {
              v=substr($0,p+1); gsub(/^[ \t]+|[ \t]+$/, "", v)
              result=v; n++
          }
        }
        END { if (n==1) print result }
    ' <<< "$raw"
}
# These two queries normally return one IPv4 address. Reject ambiguous output.
single_ipv4() {
    awk '{ for (j=1;j<=NF;j++) if ($j ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {v=$j;n++} }
         END {if(n==1) print v}' <<< "$(printf '%s' "$raw" | tr ':=,\t' '    ')"
}
valid_ipv4() {
    local addr="$1" octet
    local -a parts
    [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a parts <<< "$addr"
    for octet in "${parts[@]}"; do
        [[ ${#octet} -le 3 ]] && (( 10#$octet <= 255 )) || return 1
    done
}
unicast_ipv4() {
    valid_ipv4 "$1" || return 1
    local first="${1%%.*}"
    (( 10#$first > 0 && 10#$first < 224 && 10#$first != 127 ))
}
valid_mask() {
    valid_ipv4 "$1" || return 1
    local a b c d mask inverse
    IFS=. read -r a b c d <<< "$1"
    mask=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
    inverse=$(( (~mask) & 0xffffffff ))
    (( mask != 0 && (inverse & (inverse + 1)) == 0 ))
}
tls_switch() {
    awk '
        { rest=tolower($0)
          while (match(rest, /tls[ \t]+switch[ \t]*\[[^]]*\]/)) {
              v=substr(rest,RSTART,RLENGTH)
              sub(/^[^[]*\[/,"",v); sub(/\]$/,"",v)
              n++; result=v; rest=substr(rest,RSTART+RLENGTH)
          }
        }
        END { if (n==1 && (result=="0" || result=="1")) print result }
    ' <<< "$raw"
}
show_version_info() {
    local label="$1" version_file="$2" info version package_version
    printf '%s版本来源：%s\n' "$label" "$version_file"
    if ! info="$(cat -- "$version_file" 2>&1)"; then
        printf '%s版本号：未获取（版本文件不存在或无法读取）\n%s\n' "$label" "$info"
        return
    fi
    # Parse as text; do not source version.info or confuse compatible_version
    # and firmware_version (component version) with the top-level Version.
    version="$(awk -F= '
        { key=$1; gsub(/^[ \t]+|[ \t]+$/, "", key)
          if (tolower(key)=="version") {
              value=substr($0,index($0,"=")+1)
              gsub(/^[ \t\r]+|[ \t\r]+$/, "", value); n++
          }
        }
        END { if(n==1) print value }
    ' <<< "$info")"
    printf '%s版本号：%s\n' "$label" "${version:-未获取（Version 字段为空、重复或无法识别）}"
    if [[ "$label" == 固件 ]]; then
        package_version="$(awk -F= '
            { key=$1; gsub(/^[ \t]+|[ \t]+$/, "", key)
              if (tolower(key)=="package_version") {
                  value=substr($0,index($0,"=")+1)
                  gsub(/^[ \t\r]+|[ \t\r]+$/, "", value); n++
              }
            }
            END { if(n==1) print value }
        ' <<< "$info")"
        [[ -z "$package_version" ]] || printf '固件包版本号：%s\n' "$package_version"
    fi
}

printf 'A2 本机 IPv4/RoCE 检查：NPU 0~7，单项超时 %s 秒\n' "$command_timeout"
echo '范围：LLDP、链路、检测目标及其健康状态、网关、NPU IP/掩码、TLS全部开启（必须为1）。'
echo '不验证交换机端口规划、跨机全互通、驱动/CANN兼容性或模型推理。'
for i in {0..7}; do
    item=LLDP
    if query -lldp; then
        port="$(field Ifname)"
        case "${port,,}" in
            ''|unknown|none|null|n/a|--) fail '未取得有效的远端 Ifname（按提供的检查要求）' ;;
            *) pass "$port" ;;
        esac
    fi
    item=LINK
    if query -link; then
        status="$(field 'link status')"
        [[ "${status^^}" == UP ]] && pass "$status" || fail "链路不是 UP：${status:-无法识别}"
    fi
    item=NET_HEALTH
    if query -net_health; then
        status="$(field 'net health status')"
        [[ "${status,,}" == success ]] && pass "$status" || fail "健康状态不是 Success：${status:-无法识别}"
    fi
    item=NETDETECT
    if query -netdetect; then
        addr="$(single_ipv4)"
        unicast_ipv4 "$addr" && pass "$addr" || fail '检测目标缺失、无效或输出格式无法识别'
    fi
    item=GATEWAY
    if query -gateway; then
        addr="$(single_ipv4)"
        if [[ "$addr" == 0.0.0.0 && "$allow_no_gateway" == 1 ]]; then
            pass '0.0.0.0（已显式允许无网关；需自行确认符合组网规划）'
        elif unicast_ipv4 "$addr"; then
            pass "$addr"
        else
            fail '网关缺失、为零、无效或输出格式无法识别；确认无需网关时可用 --allow-no-gateway'
        fi
    fi
    item=IP
    if query -ip; then
        addr="$(field ipaddr)"
        mask="$(field netmask)"
        if ! unicast_ipv4 "$addr" || ! valid_mask "$mask"; then
            fail 'NPU IPv4 地址或连续子网掩码无效，或输出格式无法识别'
        else
            # Canonicalize decimal octets for duplicate detection.
            IFS=. read -r a b c d <<< "$addr"
            canonical="$((10#$a)).$((10#$b)).$((10#$c)).$((10#$d))"
            if [[ -n "${seen_ips[$canonical]+yes}" ]]; then
                fail "IP $addr 与本机 NPU ${seen_ips[$canonical]} 重复"
            else
                seen_ips[$canonical]="$i"
                pass "$addr / $mask"
            fi
        fi
    fi
done

echo
echo '===== TLS 状态检查 ====='
tls_failures_before="$failures"
for i in {0..7}; do
    item=TLS
    if query -tls; then
        status="$(tls_switch)"
        if [[ -z "$status" && "${raw,,}" != *switch* && "${raw,,}" == *'no certificate found'* ]]; then
            status=0
            echo '[INFO] no certificate found：按 TLS 关闭处理。'
        fi
        if [[ "$status" != 0 && "$status" != 1 ]]; then
            fail '无法唯一识别 tls switch[0] 或 tls switch[1]'
            continue
        fi
        if [[ "$status" == 1 ]]; then
            pass 'tls switch[1]（开启）'
        else
            fail 'tls switch[0]（关闭），通过标准要求为1（开启）'
        fi
    fi
done
if (( failures == tls_failures_before )); then
    echo 'TLS检查通过：本机0~7卡 tls switch 全部为1（开启）。'
    echo '[INFO] 还需核对参与通信的其他节点开关及证书配置是否一致。'
else
    echo 'TLS检查不通过：本机0~7卡必须全部为1（开启）；存在关闭、查询失败或无法识别。'
fi

# Display diagnostics even if earlier checks failed. Never change configuration.
diagnostic_errors=0
hccn_conf="${HCCN_CONF:-/etc/hccn.conf}"
printf '\n===== 查看 HCCN 配置 =====\n$ cat %q\n' "$hccn_conf"
if ! cat -- "$hccn_conf"; then
    echo '[FAIL] HCCN配置文件读取失败。'
    diagnostic_errors=$((diagnostic_errors + 1))
fi
printf '\n===== 重新获取各卡 IP（提取 ipaddr）=====\n'
echo '$ for i in {0..7}; do "$HCCN_TOOL" -i "$i" -ip -g | grep ipaddr; done'
for i in {0..7}; do
    rc=0
    raw="$(timeout --kill-after=2s "${command_timeout}s" "$tool" -i "$i" -ip -g 2>&1)" || rc=$?
    raw="${raw//$'\r'/}"
    addr="$(field ipaddr)"
    if (( rc != 0 )) || ! unicast_ipv4 "$addr"; then
        printf '[FAIL] NPU %s IP汇总查询失败（退出码 %s）或地址无法识别：\n%s\n' "$i" "$rc" "${raw:-(无输出)}"
        diagnostic_errors=$((diagnostic_errors + 1))
    else
        printf 'NPU %s  ipaddr:%s\n' "$i" "$addr"
    fi
done

printf '\n检查完成：通过 %s 项，失败 %s 项（共 56 项）；附加信息获取失败 %s 项。\n' "$passed" "$failures" "$diagnostic_errors"
result=0
if (( failures > 0 )); then
    printf '  - %s\n' "${errors[@]}"
    echo '环境检查不通过'
    result=1
elif (( diagnostic_errors > 0 )); then
    echo '环境检查未完成：请处理上述附加信息获取失败。'
    result=2
else
    echo '环境OK'
fi

echo
echo '===== 手动命令提示（仅打印，不自动执行）====='
printf 'HCCN_TOOL=%q\n' "$tool"
cat <<'COMMAND_HINTS'
# 开启本机 0~7 卡 TLS（各通信节点需保持一致；开启时需配套证书）
for i in {0..7}; do "$HCCN_TOOL" -i "$i" -tls -s enable 1; done

# 关闭本机 0~7 卡 TLS（关闭后将不满足本脚本的TLS通过标准）
for i in {0..7}; do "$HCCN_TOOL" -i "$i" -tls -s enable 0; done

# 修改后重新查询 TLS 开关
for i in {0..7}; do "$HCCN_TOOL" -i "$i" -tls -g; done

# 在当前测试节点执行，将 x.x.x.x 换成另一节点的目标 NPU IP（非管理网 IP）
# -i 0 表示本机发起测试的 NPU，可按实际测试卡号修改
hccn_tool -i 0 -ping -g address x.x.x.x
# hccn_tool 不在 PATH 时使用上面已设置的完整路径：
# "$HCCN_TOOL" -i 0 -ping -g address x.x.x.x
COMMAND_HINTS

printf '\n===== 驱动 / 固件版本 =====\n'
echo '以下读取宿主机安装版本记录，仅显示，不判断版本兼容性或重启后是否生效。'
show_version_info 驱动 "${DRIVER_VERSION_FILE:-/usr/local/Ascend/driver/version.info}"
show_version_info 固件 "${FIRMWARE_VERSION_FILE:-/usr/local/Ascend/firmware/version.info}"
exit "$result"
