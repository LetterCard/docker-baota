# ==============================================================================
#  baota-docker · 常用命令入口
#
#  用法：make <目标> [LINE=12_version|13_version]（也接受显示名 12.x / 13.x）
#
#  目标：help / build / up / down / restart / logs / ps / exec / version /
#        health          功能检查（面板 / 凭据 / 备份 / 重建 / 入口守卫）
#        health-degrade  只读持久化根是否真被识别为降级
#        health-upgrade  版本护栏 + 升级前快照
#        health-all      一次跑全三套
#        backup          全量备份   reset-system  重置系统层（CONFIRM=yes）
#        lint            静态检查（语法 / 配置真源 / 命名 / 注释 / 链接）
#
#  线参数（安装脚本 / 基础镜像 / 版本）从 image/lines.conf 读，Dockerfile 只有一份；
#  镜像标签可用 BAOTA_IMAGE=... make up 覆盖。
# ==============================================================================

LINE ?= 12_version
IMAGE   ?= baota:dev
SHELL   := /bin/bash

ROOT_DIR := $(shell pwd)
# 线参数的真源：image/lines.conf（各线的地址成对排列）
# 字段：line display version install probe tag base
# 注意：# 在 make 的变量赋值里会被当成注释，必须写成 \#（配方行里则不用）
LINE_ROW := $(shell grep -vE '^[[:space:]]*(\#|$$)' image/lines.conf 2> /dev/null | awk '$$1=="$(LINE)"||$$2=="$(LINE)"{print; exit}')
LINE_VERSION_FILE := $(word 3,$(LINE_ROW))
LINE_URL  := $(word 4,$(LINE_ROW))
LINE_BASE_IMAGE := $(word 7,$(LINE_ROW))
LINE_VER  := $(shell [ -n "$(LINE_VERSION_FILE)" ] && tr -d '[:space:]' < "$(LINE_VERSION_FILE)" 2>/dev/null)
# 系统层顶层目录的真源：image/conf/defaults.env 的 PERSIST_SYSTEM_DIRS。
# 只取不含 / 的项 —— reset-system 重置的正是这些顶层目录；
# /www/server（面板里装的组件）刻意保留，理由见 reset-system 的注释
SYSTEM_DIRS := $(shell sed -n 's/^PERSIST_SYSTEM_DIRS="$${PERSIST_SYSTEM_DIRS:-\(.*\)}"$$/\1/p' image/conf/defaults.env | tr ' ' '\n' | grep -v / | tr '\n' ' ')
# 编排文件与 Dockerfile 同在仓库根（docker build -f image/Dockerfile .），
# 所以 up/down/logs 等目标直接 cd 到 ROOT_DIR —— 不另设等价的 COMPOSE_DIR 别名
# （同一个概念两个名字，改一处漏一处就是幽灵 bug）

# shellcheck 可能由 pip --user 安装（macOS 系统 Python 在 ~/Library/Python/<版本>/bin，
# 不在默认 PATH）。已在 PATH 就直接用，否则自动定位，避免本地 lint 静默跳过
SHELLCHECK_BIN := $(shell command -v shellcheck 2>/dev/null || find $(HOME)/Library/Python $(HOME)/.local -name shellcheck -type f 2>/dev/null | head -1)
ifneq ($(SHELLCHECK_BIN),)
export PATH := $(dir $(SHELLCHECK_BIN)):$(PATH)
endif

.DEFAULT_GOAL := help
.PHONY: help build up down restart logs ps exec health health-degrade health-upgrade \
        health-all backup reset-system lint version

help: ## 显示本帮助
	@echo 'baota-docker · make <目标> [LINE=12.0.0|13.0.0] [IMAGE=标签]'
	@echo
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo '  当前 LINE=$(LINE)  IMAGE=$(IMAGE)'

build: ## 构建镜像（LINE=12_version|13_version，IMAGE=标签）
	@[ -n "$(LINE_ROW)" ] || { echo "❌ image/lines.conf 里没有这条线：$(LINE)（可选：$$(grep -vE '^[[:space:]]*#' image/lines.conf | awk '{print $$1}' | tr '\n' ' '))"; exit 1; }
	docker build -f image/Dockerfile \
	    --build-arg "BASE_IMAGE=$(LINE_BASE_IMAGE)" \
	    --build-arg "INSTALL_URL=$(LINE_URL)" \
	    --build-arg "LINE=$(LINE)" \
	    --build-arg "IMAGE_VERSION=$(LINE_VER)" \
	    -t $(IMAGE) .

up: ## 启动容器
	cd $(ROOT_DIR) && docker compose up -d

down: ## 停止并移除容器
	cd $(ROOT_DIR) && docker compose down

restart: ## 重启容器
	cd $(ROOT_DIR) && docker compose restart

logs: ## 跟踪日志（首次登录凭据在这里）
	cd $(ROOT_DIR) && docker compose logs -f baota

ps: ## 查看健康状态
	cd $(ROOT_DIR) && docker compose ps

exec: ## 进入容器（make exec CMD="bt default"）
	cd $(ROOT_DIR) && docker compose exec baota $(or $(CMD),bash)

# 三套发布前检查的统一入口（.github/scripts/check/），
# 各覆盖一个互不相关的失效面：
#   core     功能检查 —— 「功能完整性」
#   degrade  持久化降级场景 —— 「挂载正确性」
#   upgrade  升级 / 降级路径 —— 「版本演进」
CHECK_DIR := .github/scripts/check
CHECK_VERSION := $(or $(VERSION),$(LINE_VER))

health: ## 功能检查（全新卷 + 同卷重建）
	bash $(CHECK_DIR)/run.sh core "$(IMAGE)" "$(CHECK_VERSION)"

health-degrade: ## 持久化降级场景（只读持久化根是否被识别为 critical）
	bash $(CHECK_DIR)/run.sh degrade "$(IMAGE)"

health-upgrade: ## 升级 / 降级路径（版本护栏 + 升级前快照）
	bash $(CHECK_DIR)/run.sh upgrade "$(IMAGE)" "$(CHECK_VERSION)"

health-all: ## 三套全部跑一遍，任一失败即终止
	bash $(CHECK_DIR)/run.sh all "$(IMAGE)" "$(CHECK_VERSION)"

backup: ## 在运行中的容器里生成一份全量备份
	docker exec baota baota-backup $(OPTS)

# 重置系统层：清空 PERSIST_SYSTEM_DIRS 里各**顶层**目录（清单从 defaults.env 读，
# 不在本文件另抄一份），让系统层回到「当前镜像」的状态。
# 会丢：apt 装的软件、手工改过的 /etc、计划任务、root 家目录（含 .ssh）、历史日志
# 不丢：面板账号与配置、站点、数据库、备份、证书 —— 全在 data/www（bind 层）；
#   面板组件（data/.system/www/server）也刻意不动 —— 重置它等于让用户重装环境；
#   真要清就手动删那个目录。
#   .baota 元数据同样保留：里面有镜像版本记录，删了会被判「首次使用」、
#   升级前快照逻辑随之失效（没有可回滚的旧数据）
#
# 红线：必须先 down —— 容器运行时系统层正挂着 overlay，此时删 upper 是未定义行为
reset-system: ## 重置系统层（保留数据层）：make reset-system CONFIRM=yes
	@[ "$(CONFIRM)" = "yes" ] || { \
	    echo '⚠️  系统层将被清空，以下内容会丢失：'; \
	    echo '    apt 装的软件、手工改过的 /etc、计划任务、root 家目录、历史日志'; \
	    echo '  以下内容不受影响：面板账号与配置、站点、数据库、备份、证书，'; \
	    echo '                  以及面板里装的组件（PHP / nginx / MySQL…）'; \
	    echo '  确认执行：make reset-system CONFIRM=yes'; \
	    exit 1; \
	}
	@set -eu; \
	cd "$(ROOT_DIR)"; \
	SYSTEM=data/.system; \
	if [ ! -d "$$SYSTEM" ]; then \
	    echo "未找到系统层目录（$$SYSTEM）。容器还没启动过，或挂载方式与本项目不符。"; \
	    exit 1; \
	fi; \
	echo "系统层目录：$$SYSTEM"; \
	docker compose down; \
	for d in $(SYSTEM_DIRS); do \
	    if [ -d "$$SYSTEM/$$d" ]; then \
	        rm -rf "$$SYSTEM/$$d"; \
	        echo "  已清空 $$SYSTEM/$$d"; \
	    fi; \
	done; \
	# www/ 里的 server/ 是面板里装的组件，按设计保留（见目标说明）
	if [ -d "$$SYSTEM/www" ]; then \
	    echo "  保留 $$SYSTEM/www（面板里装的组件，重置它等于让用户重装环境）"; \
	fi; \
	echo '系统层已重置（.baota 元数据保留）'; \
	docker compose up -d; \
	echo '完成。查看启动日志：make logs'

version: ## 打印各条线记录的已发布宝塔版本
	@awk '/^[[:space:]]*#/ {next} NF<3 {next} { \
	    v=$$3; getline ver < v; gsub(/[[:space:]]/,"",ver); \
	    printf "%s (%s) : %s\n", $$2, $$1, ver; close(v) \
	 }' image/lines.conf

lint: ## 静态检查：shellcheck + bash -n + YAML 语法
	@echo '--- bash -n ---'
	@for f in image/build/*.sh image/scripts/entrypoint.sh \
	          image/scripts/backup.sh \
	          .github/scripts/check/*.sh \
	          .github/scripts/lint/*.sh \
	          .github/scripts/drift/*.sh; do \
	    bash -n "$$f" && echo "  ok  $$f" || { echo "  FAIL $$f"; exit 1; }; \
	 done
	@echo '--- sh -n (POSIX) ---'
	@for f in image/scripts/init.sh image/scripts/healthcheck.sh \
	          image/conf/defaults.env; do \
	    sh -n "$$f" && echo "  ok  $$f" || { echo "  FAIL $$f"; exit 1; }; \
	 done
	@echo '--- shellcheck ---'
	@if command -v shellcheck >/dev/null 2>&1; then \
	    shellcheck -x -S warning image/build/*.sh image/scripts/*.sh \
	               .github/scripts/check/*.sh \
	               .github/scripts/drift/*.sh \
	        && echo '  shellcheck 通过'; \
	 else \
	    echo '  未安装 shellcheck，跳过（安装与排查见 docs/development.md「本地构建」）'; \
	 fi
	@echo '--- BT-Panel 字面量（非注释行）检查 ---'
	@BAD=$$(grep -rn 'BT-Panel' image/build image/scripts .github/scripts/check 2>/dev/null \
	      | grep -vE ':[0-9]+:[[:space:]]*#' || true); \
	 if [ -n "$$BAD" ]; then \
	   echo '  FAIL 非注释行出现 BT-Panel 字面量：'; \
	   echo "$$BAD"; \
	   echo '  bt7.init 用 ps|grep 匹配该字面量判断面板是否运行，误匹配会让面板跳过启动'; \
	   exit 1; \
	 fi; \
	 echo '  ok  无非注释的 BT-Panel 字面量'
	@echo '--- 配置真源一致性（defaults.env vs 各脚本兜底）---'
	@bash .github/scripts/lint/config.sh
	@echo '--- 命名规范（禁用标识符 / 容器名 / 卷名 / 变量前后缀 / 术语）---'
	@bash .github/scripts/lint/naming.sh
	@echo '--- 注释体积（文件头 ≤16 行、注释块 ≤10 行）---'
	@bash .github/scripts/lint/comments.sh
	@echo '--- YAML 语法 ---'
	@for f in docker-compose.yml \
	          .github/workflows/*.yml; do \
	    python3 -c "import sys,yaml;yaml.safe_load(open('$$f'))" \
	        && echo "  ok  $$f" || { echo "  FAIL $$f"; exit 1; }; \
	 done
	@echo '--- workflow 内嵌脚本语法 ---'
	@bash .github/scripts/lint/workflow.sh
	@echo '--- 文档链接与锚点 ---'
	@bash .github/scripts/lint/links.sh
