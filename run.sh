#!/usr/bin/env bash
# SONiC OT-VS VM 啟動(host/WSL 側執行;qemu 需 /dev/kvm,不進 builder 容器)
# 指令逐字對齊 docs/SONiC-OT-VS-Build-Troubleshooting.md §8.1(已驗證可開機)
set -euo pipefail

IMG="${1:-}"
VM_DIR="${VM_DIR:-$HOME/sonic-vm-images}"
PORT_SSH="${PORT_SSH:-3041}"
PORT_TELNET="${PORT_TELNET:-9000}"
MEM="${MEM:-8192}"
SMP="${SMP:-4}"

[ -n "$IMG" ] || { echo "用法: $0 <sonic-*.img.gz 或 .img>"; exit 1; }
[ -f "$IMG" ] || { echo "ERROR: 找不到 $IMG"; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "ERROR: 需要 qemu-system-x86(WSL 內安裝)"; exit 1; }

mkdir -p "$VM_DIR"
BASE="$(basename "$IMG")"; BASE="${BASE%.gz}"
Q="$VM_DIR/$BASE"

# 只在目標不存在時解壓(保留 .gz 原檔;增量:重複啟動沿用同一 qcow2)
if [ ! -f "$Q" ]; then
  echo "解壓 $IMG → $Q"
  gunzip -dc "$IMG" > "$Q"
fi

# KVM 加速:可寫才帶 -enable-kvm,否則退 TCG(慢,E21 教訓)
KVM=()
if [ -w /dev/kvm ]; then
  KVM=(-enable-kvm)
else
  echo "WARN: /dev/kvm 不可寫 → TCG 軟體模擬(慢;WSL2 應可啟用嵌套虛擬化)"
fi

echo "啟動 VM: $Q(SSH 127.0.0.1:$PORT_SSH / serial telnet 127.0.0.1:$PORT_TELNET)"
echo "登入: admin / YourPaSsWoRd   停止: pkill -f qemu-system-x86_64"
exec qemu-system-x86_64 "${KVM[@]}" -m "$MEM" -smp "$SMP" \
  -drive file="$Q",media=disk,if=virtio \
  -device e1000,netdev=n0 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${PORT_SSH}-:22 \
  -serial telnet:127.0.0.1:${PORT_TELNET},server,nowait \
  -display none
