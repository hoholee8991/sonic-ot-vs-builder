#!/usr/bin/env bash
# SONiC OT-VS builder 入口(host/WSL 側執行;把工作丟進 builder 容器)
#
# 路徑契約(必讀):SRC 掛載進容器時用「恆等映射」(容器內路徑 == host 路徑)。
# 原因:slave 容器由 host docker daemon 產生,Makefile.work 以 -v $PWD:/sonic 掛載,
#       daemon 在 host 解析該路徑;容器內路徑若不同(如 /sonic)daemon 會掛到不存在的目錄。
# slave 容器內部仍是 /sonic(上游慣例,不受影響)。
set -euo pipefail

IMAGE="${IMAGE:-ot-vs-builder:2026-09-28}"
SRC="${SRC:-$HOME/sonic-buildimage}"
JOBS="${JOBS:-6}"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "需要 docker(WSL 內安裝 docker-ce)"
[[ "$SRC" = /* ]] || die "SRC 必須是絕對路徑(恆等映射需求),目前: $SRC"
[ -d "$SRC/.git" ] || die "SRC='$SRC' 不是 git repo。取得樹: git clone -b tom https://github.com/hoholee8991/sonic-buildimage.git <路徑> 之後以 SRC=<路徑> 重跑"

DOCKER_GID="$(getent group docker | cut -d: -f3)"
[ -n "$DOCKER_GID" ] || die "找不到 docker 群組(docker 尚未安裝完成?)"

# slave 的鎖目錄由 daemon 從 HOST 掛載(/tmp 是 tmpfs,WSL 重啟即清空;
# 不先備好會被 docker 以 root:755 重建 → slave 內 uid 1000 touch 被拒)
sudo rm -rf /tmp/docklock 2>/dev/null || rm -rf /tmp/docklock 2>/dev/null || true
mkdir -m 0777 -p /tmp/docklock

GITCFG=()
[ -f "$HOME/.gitconfig" ] && GITCFG=(-v "$HOME/.gitconfig:/home/builder/.gitconfig:ro")

# docker CLI 與 sock 掛入:slave 由 builder 內的 make 經 host daemon 產生(DooD)
# buildx plugin 一併掛入:CLI 從 cli-plugins 目錄找 buildx,容器內沒有會報
# "BuildKit is enabled but the buildx component is missing"
# DEFAULT_CONTAINER_REGISTRY 空(=Joe 對齊):slave 與 docker-base 的 j2 均由
# {{ prefix }}amd64/debian 路徑組成(version-control 以表 amd64:amd64/debian:*
# 條目補 @digest)——registry 非空會造成 amd64/amd64 雙重路徑(2026-09-25 實證)
COMMON=(
  --group-add "$DOCKER_GID"
  -w "$SRC"
  -v "$SRC:$SRC"
  -v /var/run/docker.sock:/var/run/docker.sock
  -v /usr/bin/docker:/usr/bin/docker:ro
  -v /usr/libexec/docker/cli-plugins:/usr/local/lib/docker/cli-plugins:ro
  -e DEFAULT_CONTAINER_REGISTRY=
  "${GITCFG[@]}"
)

MAKE_LOG="$SRC/make-build.log"

sub="${1:-help}"
case "$sub" in
  shell)   # 互動開發(git / 改碼;commit 可在容器內,push 建議回 host)
    exec docker run -it --rm "${COMMON[@]}" "$IMAGE" bash
    ;;
  slave)   # V2 驗證:init + configure(驅動鏈;slave 由主建置自然產生,勿呼叫 make slave——
           # 它會走 legacy EXTRA_DOCKER_TARGETS 鏈,內層無 slave target)
    exec docker run --rm "${COMMON[@]}" "$IMAGE" \
      bash -c 'make init && make configure PLATFORM=ot-vs'
    ;;
  full)    # V3:主建置(SOP §6 全序;host 側 setsid 脫離 + 前景容器——
           # 實測 docker -d 分離容器會在 ~4min 被 SIGTERM(143),前景容器不會)
    docker rm -f ot-vs-build >/dev/null 2>&1 || true
    RUN_CMD=(docker run --name ot-vs-build "${COMMON[@]}" "$IMAGE" \
      bash -c "{ make init && make configure PLATFORM=ot-vs && make SONIC_BUILD_JOBS=$JOBS target/sonic-ot-vs.img.gz; echo EXIT=\$?; } > '$SRC/make-build.log' 2>&1")
    setsid "${RUN_CMD[@]}" > /dev/null 2>&1 &
    sleep 2
    docker ps --format '{{.Names}} {{.Status}}' | grep ot-vs-build || die "容器未啟動,檢查 docker ps"
    echo "建置已啟動(host setsid 託管)。"
    echo "輪詢:  ./build.sh logs   或   tail -f $SRC/make-build.log"
    echo "狀態:  grep -c 'FAIL LOG END' $SRC/make-build.log(>0 即有失敗)"
    ;;
  logs)
    [ -f "$MAKE_LOG" ] || die "尚無 $MAKE_LOG(先跑 ./build.sh full)"
    exec tail -n 20 -f "$MAKE_LOG"
    ;;
  status)
    [ -f "$MAKE_LOG" ] || die "尚無 $MAKE_LOG"
    echo "FAIL 數: $(grep -c 'FAIL LOG END' "$MAKE_LOG" || true)"
    echo "最後一行: $(tail -1 "$MAKE_LOG")"
    ;;
  stop)
    docker rm -f ot-vs-build
    ;;
  *)
    cat <<EOF
用法: SRC=<sonic-buildimage 絕對路徑> ./build.sh <子命令>
  shell    進入容器互動 shell(開發、git)
  slave    make init + configure + slave(驗證驅動鏈)
  full     主建置(分離容器,4-12h)
  logs     跟蹤建置 log      status  檢查 FAIL 數
  stop     終止建置容器
變數: IMAGE(預設 ot-vs-builder:2026-09-25) JOBS(預設 6)
EOF
    ;;
esac
