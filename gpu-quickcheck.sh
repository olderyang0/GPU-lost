#!/usr/bin/env bash
# =============================================================================
# gpu-quickcheck.sh — 显卡掉卡快速排查（零落盘 / 纯只读 / 可直接粘贴执行）
#
# 【零痕迹原则】
#   不在客户机器上创建任何文件、不写日志、不改配置、不重启服务。
#   所有中间结果只存在于内存变量与管道中，脚本退出后机器无任何变化。
#
# 【执行方式】
#   A. 推荐（脚本也不落盘，通过管道喂给远端的 bash）：
#        ssh root@<客户机> 'bash -s -- --expect 8' < gpu-quickcheck.sh
#   B. 已登录客户机，直接粘贴执行（先 unset HISTFILE 让命令不进 history）：
#        unset HISTFILE; bash -s -- --expect 8
#
# 【排查顺序】
#   1. nvidia-smi 盘点：卡少了吗（与 lspci 硬件在位数量交叉验证）
#   2. 内核日志：Xid / 掉总线 / PCIe AER，原始报错行原样打印
#   3. 定位掉的那张卡：总线地址 / 物理槽位 / UUID / SN / 型号
#
# 【退出码】0 正常  10 有卡未被驱动接管  20 确认缺卡  3 无 nvidia-smi
# =============================================================================
set -uo pipefail

EXPECT=0
VERBOSE=0
NOCLR=0

usage() {
  cat <<EOF
gpu-quickcheck — 显卡掉卡快速排查（只读、零落盘）

用法: bash -s -- [选项]
  --expect N    你这台机器应有几张卡（如 8）。给了才能判断"真的少了"
  --no-color    关闭彩色（重定向到文件或日志时自动关闭）
  -v            额外打印每张卡的详细上下文
  -h            显示本帮助

示例:
  bash -s -- --expect 8                     # 8 卡整机
  ssh root@10.0.0.5 'bash -s -- --expect 8' < gpu-quickcheck.sh
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --expect)     shift; EXPECT="${1:-0}" ;;
    --no-color)   NOCLR=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done
case "$EXPECT" in ''|*[!0-9]*) EXPECT=0 ;; esac

if [ "$NOCLR" -eq 1 ] || [ ! -t 1 ]; then
  R='' G='' Y='' B='' D='' N=''
else
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[90m'; N=$'\033[0m'
fi

say()  { printf '%s\n' "$*"; }
sec()  { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s[OK]%s %s\n' "$G" "$N" "$*"; }
bad()  { printf '  %s[X ]%s %s\n' "$R" "$N" "$*"; }
warn() { printf '  %s[! ]%s %s\n' "$Y" "$N" "$*"; }
inf()  { printf '  %s[- ]%s %s\n' "$D" "$N" "$*"; }
raw()  { printf '        %s|%s %s\n' "$D" "$N" "$*"; }
hint() { printf '  %s    %s%s\n' "$D" "$*" "$N"; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# 把 0000:61:00.0 / 61:00.0 / 0000:61:00 统一成短键 61:00
key_of() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' \
    | sed -e 's/^0000://' -e 's/\.0$//' -e 's/[[:space:]]//g'
}
# 短键还原成完整总线地址
bus_of() {
  local k="$1"
  case "$k" in
    *:*) printf '0000:%s.0' "${k%.0}" ;;
    *)   printf '%s' "$k" ;;
  esac
}

run_user="$(id -un 2>/dev/null || echo unknown)"
is_root=0
[ "$(id -u 2>/dev/null || echo 1)" = "0" ] && is_root=1

# =============================================================================
sec "环境"
inf "主机  $(hostname 2>/dev/null || echo unknown)   用户 $run_user$([ "$is_root" -eq 1 ] && echo ' (root)')"
inf "系统  $( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}") || echo unknown )  内核 $(uname -r 2>/dev/null || echo unknown)"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  bad "未找到 nvidia-smi —— 非 NVIDIA 平台，或驱动未安装"
  exit 3
fi
if ! nvidia-smi >/dev/null 2>&1; then
  bad "nvidia-smi 执行失败，原始报错："
  nvidia-smi 2>&1 | sed -n '1,8p' | while IFS= read -r l; do raw "$l"; done
  hint "这类多半是驱动层问题（驱动未加载 / 版本不匹配），不是显卡坏"
  exit 3
fi
drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d ' \r')"
inf "驱动  ${drv:-unknown}"

# =============================================================================
sec "1/3  显卡盘点"
# ---- 驱动层看到的卡 -------------------------------------------------------
SMI="$(nvidia-smi --query-gpu=index,uuid,pci.bus_id,serial,name,pcie.link.width.current,pcie.link.width.max \
        --format=csv,noheader,nounits 2>/dev/null)"
SMI_N=$(printf '%s\n' "$SMI" | grep -c . || true)

# ---- 硬件层在位的卡（PCI 设备 ID 10de = NVIDIA，class 0300/0302 = 显示/3D）--
LSPCI_GPU="$(lspci -nn 2>/dev/null | grep -i '\[10de:' | grep -iE 'vga compatible|3d controller')"
LSPCI_N=$(printf '%s\n' "$LSPCI_GPU" | grep -c . || true)

# ---- 槽位：优先 lspci -vv 的 Physical Slot（不需要 root）------------------
DMI_CACHE=""; DMI_LOADED=0
dmi_load() {
  [ "$DMI_LOADED" -eq 1 ] && return 0
  DMI_LOADED=1
  command -v dmidecode >/dev/null 2>&1 || return 0
  [ "$is_root" -eq 1 ] || return 0
  DMI_CACHE="$(dmidecode -t slot 2>/dev/null)"
}
slot_of() {
  local b="$1" s
  s="$(lspci -vv -s "$b" 2>/dev/null | sed -n 's/.*Physical Slot: *//p' | head -1 | tr -d ' \r')"
  case "$s" in
    ''|'0'|'<empty>'|'empty'|'Slot 0')
      dmi_load
      if [ -n "$DMI_CACHE" ]; then
        s="$(printf '%s\n' "$DMI_CACHE" | awk -v w="$(printf '%s' "$b" | tr 'A-Z' 'a-z')" '
          /Designation:/ { d=$0; sub(/.*Designation:[ \t]*/,"",d); sub(/[ \t\r]*$/,"",d) }
          /Bus Address:/ { x=$0; sub(/.*Bus Address:[ \t]*/,"",x); gsub(/[ \t\r]/,"",x);
                           if (length(x)>0 && tolower(x)==w) { print d; exit } }')"
        case "$s" in ''|'0'|'<empty>') s='' ;; esac
      fi
      ;;
  esac
  # 纯数字槽位补上 SLOT 前缀，读起来更直观
  case "$s" in
    ''|'-') printf '%s' '-' ;;
    [0-9]*) printf 'SLOT %s' "$s" ;;
    *)      printf '%s' "$s" ;;
  esac
}

if [ "$SMI_N" -gt 0 ]; then
  printf '  %s%-4s %-15s %-11s %-18s %-11s %s%s\n' "$D" "IDX" "BUS" "SLOT" "SERIAL" "PCIE" "NAME" "$N"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    IFS=',' read -r c_idx c_uuid c_bus c_sn c_name c_w c_wmax <<< "$line"
    c_idx="$(trim "$c_idx")"; c_bus="$(trim "$c_bus")"; c_sn="$(trim "$c_sn")"
    c_name="$(trim "$c_name")"; c_w="$(trim "$c_w")"; c_wmax="$(trim "$c_wmax")"
    printf '  %-4s %-15s %-11s %-18s %-11s %s\n' \
      "$c_idx" "$c_bus" "$(slot_of "$c_bus")" "${c_sn:-N/A}" "x${c_w}/x${c_wmax}" "$c_name"
  done <<< "$SMI"
fi

# ---- 三个数字摆在一起 -----------------------------------------------------
[ "$EXPECT" -gt 0 ] && base="$EXPECT" || base="$LSPCI_N"
say ""
inf "驱动识别 ${SMI_N} 张 | 总线在位 ${LSPCI_N} 张 | 你期望 ${EXPECT:-未指定} 张"

# 差异判定
GONE_BUSES=""      # 在总线上但驱动没接管的（lspci 有 / smi 无）
if [ "$LSPCI_N" -gt 0 ] && [ "$SMI_N" -lt "$LSPCI_N" ]; then
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    kb="$(key_of "${l%% *}")"
    case "$(printf '%s\n' "$SMI" | tr 'A-Z' 'a-z')" in
      *"$kb"*) : ;;
      *) GONE_BUSES="${GONE_BUSES}${kb}"$'\n' ;;
    esac
  done <<< "$LSPCI_GPU"
fi

CARD_MISSING=0; STUCK=0; DRVSTUCK_N=0
if [ -n "$GONE_BUSES" ]; then
  DRVSTUCK_N=$(printf '%s' "$GONE_BUSES" | grep -c . || true)
  STUCK=1
fi
if [ "$base" -gt 0 ] && [ "$SMI_N" -lt "$base" ]; then
  CARD_MISSING=1
fi

if [ "$CARD_MISSING" -eq 0 ] && [ "$STUCK" -eq 0 ]; then
  ok "卡数量正常（${SMI_N} 张），继续查日志"
else
  [ "$CARD_MISSING" -eq 1 ] && bad "少卡：驱动只认到 ${SMI_N} 张，期望 ${base} 张，缺 $((base - SMI_N)) 张"
  [ "$STUCK" -eq 1 ] && warn "有 ${DRVSTUCK_N} 张卡在 PCIe 总线上，但 nvidia-smi 没接管"
fi

# PCIe 宽度降级（掉卡前的早期信号）
while IFS= read -r line; do
  [ -z "$line" ] && continue
  IFS=',' read -r c_idx c_uuid c_bus c_sn c_name c_w c_wmax <<< "$line"
  c_wmax="$(trim "$c_wmax")"
  case "$c_wmax" in ''|'[N/A]'|'N/A') continue ;; esac
  if [ "$c_wmax" -lt 8 ] 2>/dev/null; then
    warn "$(trim "$c_bus") 最大带宽只有 x${c_wmax}（正常应 ≥ x8），插槽/Riser 可能有问题"
  fi
done <<< "$SMI"

# =============================================================================
sec "2/3  内核日志（Xid / 掉总线 / PCIe AER）"

klog() {
  local out=''
  if command -v journalctl >/dev/null 2>&1; then
    out="$(journalctl -k -b --no-pager 2>/dev/null)"
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  if command -v dmesg >/dev/null 2>&1; then
    out="$(dmesg 2>/dev/null)"
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  fi
  [ -r /var/log/kern.log ] && cat /var/log/kern.log 2>/dev/null
  return 0
}

KLOG="$(klog)"      # 只在内存里，不写文件
KLOG_N=$(printf '%s\n' "$KLOG" | grep -c . || true)
if [ "$KLOG_N" -eq 0 ]; then
  warn "内核日志读不到（dmesg_restrict=1 或权限不足）"
  hint "非 root 时这一步会缺失；用 sudo 或 root 重跑才能拿到 Xid"
  KLOG_OK=0
else
  inf "日志来源：本次启动，共 ${KLOG_N} 行"
  KLOG_OK=1
fi

XID_LINES=''; XID_N=0
if [ "$KLOG_OK" -eq 1 ]; then
  XID_LINES="$(printf '%s\n' "$KLOG" | grep -iE 'Xid' || true)"
  XID_N=$(printf '%s' "$XID_LINES" | grep -c . || true)
fi

if [ "$XID_N" -eq 0 ]; then
  ok "Xid：本次启动未发现 Xid 事件"
else
  bad "Xid：发现 ${XID_N} 条，原始记录如下"
  if [ "$XID_N" -le 200 ] || [ "$VERBOSE" -eq 1 ]; then
    printf '%s\n' "$XID_LINES" | while IFS= read -r l; do [ -n "$l" ] && raw "$l"; done
  else
    printf '%s\n' "$XID_LINES" | head -40 | while IFS= read -r l; do [ -n "$l" ] && raw "$l"; done
    hint "...（共 ${XID_N} 条，仅显示前 40 条；加 -v 看全部）"
  fi
  # 归类提示：只取 Xid 后面的数字，避开 PCI:0000 里的数字
  xids="$(printf '%s\n' "$XID_LINES" | awk '
    {
      n = split($0, a, "Xid"); if (n < 2) next
      rest = a[n]; code = ""
      if (match(rest, /\)[[:space:]]*:[[:space:]]*[0-9]+/)) {
        s = substr(rest, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); code = s
      } else if (match(rest, /^[: ]+[0-9]+/)) {
        s = substr(rest, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); code = s
      }
      if (code != "") print code
    }' | sort -n | uniq -c | awk '{printf "Xid %s×%s  ", $2, $1}')"
  [ -n "$xids" ] && hint "汇总：$xids"
  hint "79/48/119/120/143/154/158 = 掉卡·显存类；13/31/32/38/39/43 = 多为应用或越界，先查程序"
fi

# 掉总线 / 初始化失败
BUSFALL="$(printf '%s\n' "$KLOG" | grep -iE 'has fallen off the bus|RmInitAdapter failed|Error while waiting for GPU progress|nvidia-modeset: ERROR' || true)"
BUSFALL_N=$(printf '%s' "$BUSFALL" | grep -c . || true)
if [ "$BUSFALL_N" -gt 0 ]; then
  bad "掉总线 / 初始化失败：${BUSFALL_N} 条"
  printf '%s\n' "$BUSFALL" | head -20 | while IFS= read -r l; do [ -n "$l" ] && raw "$l"; done
else
  [ "$KLOG_OK" -eq 1 ] && ok "未发现 GPU 掉总线 / 初始化失败"
fi

# PCIe AER（链路层，往插槽/Riser/Switch 方向查）
AER="$(printf '%s\n' "$KLOG" | grep -iE 'AER:|Bus Uncorrectable|Uncorrected error' || true)"
AER_N=$(printf '%s' "$AER" | grep -c . || true)
if [ "$AER_N" -gt 0 ]; then
  warn "PCIe AER：${AER_N} 条（链路层报错，优先怀疑插槽 / Riser / Switch 板）"
  printf '%s\n' "$AER" | head -10 | while IFS= read -r l; do [ -n "$l" ] && raw "$l"; done
else
  [ "$KLOG_OK" -eq 1 ] && ok "PCIe AER：无"
fi

# 其他值得看的：nvidia 初始化报错、MCE、OOM killer
OTHER="$(printf '%s\n' "$KLOG" | grep -iE 'NVRM.*(failed|error|timeout)|Machine check|MCE|Out of memory: Kill' \
        | grep -viE 'Xid|fallen off|RmInitAdapter|modeset: ERROR' || true)"
OTHER_N=$(printf '%s' "$OTHER" | grep -c . || true)
if [ "$OTHER_N" -gt 0 ]; then
  warn "其他异常：${OTHER_N} 条"
  printf '%s\n' "$OTHER" | head -10 | while IFS= read -r l; do [ -n "$l" ] && raw "$l"; done
fi

# =============================================================================
sec "3/3  定位出问题的那张卡"

# 收集嫌疑总线：日志里报错涉及的 + 总线上有但驱动没接管的
SUSPECT=""
add_suspect() {
  local k="$1" x
  while IFS= read -r x; do [ "$x" = "$k" ] && return 0; done <<< "${SUSPECT:-}"
  SUSPECT="${SUSPECT}$k"$'\n'
}

if [ "$KLOG_OK" -eq 1 ]; then
  # Xid 行形如: NVRM: Xid (PCI:0000:61:00): 79, ...
  # 用进程替换而非管道，保证 add_suspect 修改的是当前 shell 的变量
  while IFS= read -r k; do [ -n "$k" ] && add_suspect "$k"; done < <(
    printf '%s\n' "$XID_LINES" | while IFS= read -r l; do
      [ -z "$l" ] && continue
      k="$(key_of "$(printf '%s' "$l" | sed -n 's/.*PCI:\([0-9a-fA-F:.]*\).*/\1/p')")"
      [ -n "$k" ] && printf '%s\n' "$k"
    done
  )
  # 掉总线行 / AER 行里出现的设备地址
  while IFS= read -r k; do [ -n "$k" ] && add_suspect "$k"; done < <(
    printf '%s\n' "$KLOG" | grep -iE 'fallen off the bus|AER:|Uncorrectable' | while IFS= read -r l; do
      b="$(printf '%s' "$l" | grep -oiE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]' | tail -1)"
      [ -n "$b" ] && key_of "$b"
    done
  )
fi
# 总线上有、驱动没接管的
while IFS= read -r k; do [ -n "$k" ] && add_suspect "$k"; done <<< "${GONE_BUSES:-}"

# 逐个嫌疑卡给出完整信息
SUSPECT_N=$(printf '%s' "$SUSPECT" | grep -c . || true)
if [ "$SUSPECT_N" -eq 0 ]; then
  if [ "$CARD_MISSING" -eq 1 ]; then
    warn "数量上少了卡，但没有日志指向具体是哪一张（Xid 已被刷新 / 无权限读日志）"
    hint "此时可用的定位手段："
    hint "  · BMC / iDRAC / iLO 的 GPU 在位与告警页（最直接）"
    hint "  · 交叉换槽后重跑本脚本，看报错是否随卡走"
  else
    ok "没有发现可疑显卡"
  fi
fi

i=0
while IFS= read -r k; do
  [ -z "$k" ] && continue
  i=$((i + 1))
  fb="$(bus_of "$k")"
  sl="$(slot_of "$fb")"
  # 该卡当前是否还在
  in_smi=0; s_uuid=''; s_sn=''; s_name=''
  if printf '%s\n' "$SMI" | tr 'A-Z' 'a-z' | grep -q "$k"; then
    in_smi=1
    while IFS= read -r line; do
      IFS=',' read -r c_idx c_uuid c_bus c_sn c_name c_w c_wmax <<< "$line"
      case "$(trim "$c_bus" | tr 'A-Z' 'a-z')" in
        *"$k"*) s_uuid="$(trim "$c_uuid")"; s_sn="$(trim "$c_sn")"; s_name="$(trim "$c_name")"; break ;;
      esac
    done <<< "$SMI"
  fi
  in_pci=0
  if printf '%s\n' "$LSPCI_GPU" | grep -qi "^${k}\."; then in_pci=1; fi

  say ""
  say "  ${Y}--- 可疑卡 #${i} ---${N}"
  inf "总线地址   ${fb}"
  inf "物理槽位   ${sl}"
  if [ "$sl" = "-" ]; then
    hint "槽位名取不到：设备已不在总线上，lspci 读不出；用 root 重跑可让 dmidecode 补出槽位"
  fi
  inf "在位状态   $(
      if [ "$in_smi" -eq 1 ]; then printf '驱动已识别（当前在位）'
      elif [ "$in_pci" -eq 1 ]; then printf '在总线上，但驱动未接管'
      else printf '已从 PCIe 总线消失'; fi)"

  # UUID：驱动层 → /proc → 日志，三级追溯
  if [ -n "$s_uuid" ]; then
    inf "UUID       ${s_uuid}"
    [ -n "$s_sn" ] && inf "SN         ${s_sn}"
    [ -n "$s_name" ] && inf "型号       ${s_name}"
  else
    pk=''
    for d in /proc/driver/nvidia/gpus/*/; do
      [ -r "$d/information" ] || continue
      bl="$(sed -n 's/^Bus Location:[[:space:]]*//p' "$d/information" 2>/dev/null | tr -d ' \r')"
      [ -n "$bl" ] || continue
      [ "$(key_of "$bl")" = "$k" ] || continue
      pk="$(sed -n 's/^GPU UUID:[[:space:]]*//p' "$d/information" 2>/dev/null | tr -d ' \r')"
      [ -n "$pk" ] && { inf "UUID       ${pk}"; inf "来源       /proc/driver/nvidia/gpus/${bl}/information"; }
      break
    done
    if [ -z "$pk" ] && [ "$KLOG_OK" -eq 1 ]; then
      lk="$(printf '%s\n' "$KLOG" | grep -iE "$k" | grep -oiE 'GPU-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
      [ -n "$lk" ] && { inf "UUID       ${lk}"; inf "来源       内核日志邻近行"; }
      lsn="$(printf '%s\n' "$KLOG" | grep -iE "$k" | sed -n 's/.*Board Serial Number:[[:space:]]*//p' | head -1 | tr -d ' \r')"
      [ -n "$lsn" ] && inf "SN         ${lsn}"
    fi
    if [ -z "$pk" ] && [ -z "${lk:-}" ]; then
      inf "UUID       -（驱动未加载该设备，本机读不到）"
      hint "以「总线地址 + 物理槽位 + 型号」作为报修凭据；UUID 可等卡恢复后重跑，或从 BMC / 资产台账获取"
    fi
    # 型号从 lspci 取，去掉总线号和 class 前缀
    ln="$(printf '%s\n' "$LSPCI_GPU" | grep -i "^${k}\." | head -1 \
          | sed -e 's/^[^ ]* [^:]*: //' -e 's/ \[10de:[0-9a-f]*\]//' -e 's/ (rev.*//')"
    [ -n "$ln" ] && inf "型号       ${ln}"
  fi

  # 该总线相关的全部原始日志 —— 现场最想看到的东西
  if [ "$KLOG_OK" -eq 1 ]; then
    mine="$(printf '%s\n' "$KLOG" | grep -iE "(0000:)?${k}(\.0)?[^0-9a-f]" | grep -viE 'fallback|nvidia-smi' || true)"
    mn=$(printf '%s' "$mine" | grep -c . || true)
    if [ "$mn" -gt 0 ]; then
      say ""
      inf "该总线相关日志 ${mn} 条（原始输出）："
      printf '%s\n' "$mine" | head -15 | while IFS= read -r l; do [ -n "$l" ] && raw "$l"; done
      [ "$mn" -gt 15 ] && hint "（仅显示前 15 条）"
    fi
  fi
done <<< "$SUSPECT"

# =============================================================================
sec "结论与下一步"

say "  驱动识别 ${SMI_N} 张 / 总线在位 ${LSPCI_N} 张 / 期望 ${EXPECT:-未指定} 张"
say ""

RC=0
if [ "$CARD_MISSING" -eq 1 ] && [ "$DRVSTUCK_N" -gt 0 ]; then
  bad "存在掉卡，且有卡卡在「总线上但驱动没接管」——优先按驱动/初始化处理，别急着拆机"
  hint "① 重启一次（很多掉卡重启即恢复）；仍不行再试 nvidia-smi -r 重置"
  hint "② 恢复后立刻重跑本脚本，确认总线地址与槽位是否还是同一张"
  hint "③ 反复在同一槽位复现 → 该槽位/Riser/供电有问题；换了槽还复现 → 卡体故障"
  RC=20
elif [ "$CARD_MISSING" -eq 1 ]; then
  bad "确认掉卡：期望 ${base} 张，实际只认到 ${SMI_N} 张，缺 $((base - SMI_N)) 张；且总线上也查不到了"
  hint "① 断电 AC（不是 reboot）+ 重新插拔该卡做接触复位"
  hint "② 上电仍不识别 → 把该卡与正常卡对调槽位，判断「随卡走还是随槽走」"
  hint "③ 随卡走 → 记 SN 走返修；随槽走 → 查插槽 / Riser / Switch 板 / 供电线"
  RC=20
elif [ "$DRVSTUCK_N" -gt 0 ]; then
  warn "卡都在，但有 ${DRVSTUCK_N} 张未被驱动接管"
  hint "重启或重载驱动后重跑本脚本复测；同时看上面 AER 报错是否集中在这些总线"
  RC=10
elif [ "$XID_N" -gt 0 ]; then
  app=0
  printf '%s\n' "$XID_LINES" | grep -qE 'Xid[^:]*:[[:space:]]*(13|31|32|38|39)\b' && app=1
  if [ "$app" -eq 1 ]; then
    warn "卡数量正常，但出现应用类 Xid（13/31 等）：先查业务程序、CUDA 版本、显存越界"
    RC=10
  else
    warn "卡数量正常，但日志有硬件类 Xid：属于「还没掉、正在掉」的前兆"
    hint "固定频率压测复现（gpu_burn / dcgmi diag），复现即按上面第②③步对调槽位验证"
    RC=20
  fi
else
  ok "未发现掉卡迹象，卡数量与日志均正常"
  hint "若业务侧仍报错，问题多半在应用层或虚拟化配置（如 host-passthrough 未开）"
fi

say ""
hint "本脚本未在客户机器上创建或修改任何文件，退出后无残留。"
exit "$RC"
