# SONiC OT-VS Builder 容器

一個可以**增量編譯 SONiC 映像**的 Docker 環境。原始碼樹不在映像內——掛載進來使用;重複建置只編譯你改動的部分。

## 架構一圖

```
┌─ builder 容器(git/make/j2/docker CLI)────────────────┐
│  make init / configure / target                        │
│      │ 經掛入的 host docker.sock                        │
│      ▼ 產生 slave 容器(真正編譯處,--privileged)        │
│  slave(-v $PWD:/sonic)→ .deb → 映像 → .img.gz          │
└────────────────────────────────────────────────────────┘
```

- builder = 驅動層;slave = 編譯層(基底 digest 由契約釘死,跨機一致)
- 增量來源:原始碼樹裡的 `target/` 記錄已完成產物,`make` 只重編改動的套件

## 前置需求

- Linux 或 WSL2 + docker(WSL 內 docker-ce)
- **原始碼樹必須在 Linux 原生檔案系統**(WSL 鐵律:禁 `/mnt/c`、`/mnt/d`——I/O 慢且符號連結壞)
- `/dev/kvm` 可寫則建置與 VM 有 KVM 加速;否則 TCG(慢)
- host 使用者 uid 建議 1000(與映像內 builder 一致;不一致用 `docker build --build-arg UID=$(id -u)` 自建)

## 如何開映像檔(進入開發環境)

```bash
# 進入互動 shell:可改碼、git commit、查看編譯環境(原始碼在 $SRC 掛載處)
SRC=~/sonic-buildimage ~/builder/build.sh shell
```

容器內 `/home/user/sonic-buildimage`(= host 的 SRC 路徑,恆等映射)就是完整 git repo,直接開發。

## 如何在裡面 build(增量)

```bash
SRC=~/sonic-buildimage ~/builder/build.sh slave   # 首次:make init + configure(之後秒過)
SRC=~/sonic-buildimage ~/builder/build.sh full    # 增量主建置 → target/sonic-ot-vs.img.gz
SRC=~/sonic-buildimage ~/builder/build.sh logs    # 跟蹤進度
SRC=~/sonic-buildimage ~/builder/build.sh stop    # 終止建置容器
```

- 改了程式碼 → `build.sh full`:只重編改動的套件(20 分鐘級);全新樹 → 4–12h
- `build.sh full` 在 host 側以 `setsid` 託管,斷線不影響;崩潰後重跑同一指令自動續跑(快取)
- 產出映像開機驗證:`SRC=~/sonic-buildimage ~/builder/run.sh <img.gz>`(SSH 3041 / telnet 9000,admin/YourPaSsWoRd)
- ⚠️ **勿呼叫 `make slave`**(legacy 鏈,內層無此 target);slave 由主建置自然產生

## 給他人:快速裝設環境(離線 tar 三步)

```bash
# 0. 前置:Linux/WSL2 + docker(見上)+ git

# 1. 載入 builder 映像(從提供者處取得 ot-vs-builder-*.tar.gz)
docker load -i ot-vs-builder-20260928.tar.gz          # ~150MB

# 2. 取原始碼樹 + 腳本
git clone -b tom https://github.com/hoholee8991/sonic-buildimage.git ~/sonic-buildimage
git clone https://github.com/hoholee8991/sonic-ot-vs-builder.git ~/builder

# 3. 建置(首次 4-12h 從零;之後增量)
SRC=~/sonic-buildimage ~/builder/build.sh full
```

- **加速選項**:若提供者一併給了 `sonic-slaves-*.tar.gz`(8–13GB×3),先 `docker load` 它 → 免去首次 slave 建置 ~2h;不載也行,slave 基底已釘 digest,自動重建結果一致
- 若腳本不在 repo,可從映像取出:`docker run --rm ot-vs-builder:2026-09-28 cat /opt/builder/build.sh > build.sh`

## 路徑契約(必讀)

- `SRC` 可為任意**絕對**路徑;容器內以**同一路徑**掛載(恆等映射),非固定 `/sonic`
- **原因**:slave 由 host daemon 產生,`Makefile.work` 用 `-v $PWD:/sonic` 掛載,daemon 在 **host** 解析路徑;容器內路徑與 host 不同就會掛到不存在的目錄
- slave 容器**內部**仍是 `/sonic`(上游慣例,不變)
- 開發:`build.sh shell` 進容器;git commit 可在容器內(gitconfig 已掛入);**push 建議回 host 做**(容器內無 Windows GCM credential helper;需容器內 push 時自備 PAT)

## 建置行為

| 情境 | 耗時 | 原因 |
|------|------|------|
| 本機重跑(有 `target/`) | 增量(只編改過的) | make 機制 |
| slave 重建(j2/釘選未變) | 秒級 | digest 釘死 → docker cache 命中 |
| 新機器 fresh clone | full 4–12h | `target/` 不進 git |

- 失敗排查:`make-build.log` 找最後一個 `[ FAIL LOG START ]` → 對照 `docs/SONiC-OT-VS-Build-Troubleshooting.md` §3 → 修正後刪該壞產物重跑(快取續跑)
- WSL 斷線恢復 SOP:`wsl --shutdown` → 20s → 重啟 → `systemctl is-active docker` → 重跑 `build.sh full`(或用 `watch-v3.ps1` 自動保姆)

## 已知差異與陷阱(對 Joe 的 Fedora 環境)

- **`DOCKER_BUILDKIT=0`**:docker-base 等階段上游本來就用 classic builder(實測 docker 29.8.1 仍支援,build.sh 不需特別設定;BuildKit 用於 slave 建置,兩者共存)
- **勿呼叫 `make slave`**:會走 legacy `EXTRA_DOCKER_TARGETS` 鏈(內層無此 target);slave 由主建置自然產生
- 基底 digest 釘選在 `files/build/versions/default/versions-docker` 表(鍵 `amd64:amd64/debian:*`)+ slave j2 路徑自帶 `amd64/`;registry 必須空值,非空會疊出 `amd64/amd64/debian`(A7)
- 6asic 平台已裁撤:`build_image.sh` 的 `generate_kvm_image 6` 已移除,不再產出 6asic 映像
- j2 工具 = j2cli 0.3.10 + Jinja2 3.1.6(venv 安裝避開 PEP 668);builder 基底 bookworm digest 釘 `f37a335e...`(builder 層級錨點)
