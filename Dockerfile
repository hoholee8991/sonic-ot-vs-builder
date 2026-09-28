# SONiC OT-VS builder — 建置驅動層(編譯發生在 slave 容器,由 make 經 host docker.sock 產生)
#
# 基底釘 digest(builder 層級錨點,2026-09-25):
#   只影響驅動層;slave 基底另由契約釘(bullseye = da5c2dc5... Joe 9/1 錨點)
FROM debian:bookworm@sha256:f37a335e82bca302e955fa39f9dfe28f1be618f016f8a2b56318e5a5111afc26

# UID 對齊 host 使用者,使掛載樹內的檔案擁有權一致
ARG UID=1000
# j2 版本對齊既有成功建置(j2cli 0.3.10 / Jinja2 3.1.6,渲染 slave Dockerfile.j2 用)
ARG J2CLI_VER=0.3.10
ARG JINJA2_VER=3.1.6

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git jq less make procps psmisc telnet wget kmod \
      iputils-ping python3 python3-venv \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m venv /opt/j2 \
 && /opt/j2/bin/pip install --no-cache-dir "j2cli==${J2CLI_VER}" "Jinja2==${JINJA2_VER}" \
 && ln -s /opt/j2/bin/j2 /usr/local/bin/j2 \
 && useradd -m -s /bin/bash -u "${UID}" builder \
 && mkdir -p /var/cache/sonic \
 && chown -R builder:builder /var/cache/sonic

# 入口腳本烘進映像(/opt/builder/):使用者沒抓 repo 時可從映像取出
COPY Dockerfile build.sh run.sh README.md watch-v3.ps1 /opt/builder/

USER builder
ENV HOME=/home/builder
