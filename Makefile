# ==============================================================================
#  baota-docker · 常用命令入口
#
#  用法：make <目标> [CHANNEL=stable|release]
#
#  目标：
#    help            显示本帮助
#    build           构建镜像（默认 CHANNEL=stable，标签 baota:dev）
#    up / down       用对应通道的 compose 启停
#    restart / logs / ps / exec
#  health 系列（三套，覆盖不同的失效面）：
#    health          18 项功能检查（面板 / 凭据 / 备份 / 重建不丢数据）
#    health-mounts   挂载方式与降级场景（混合挂载 + 只读降级是否真被识别）
#    health-upgrade  升级 / 降级路径（版本护栏 + 快照 + 启动器刷新）
#    health-all      一次跑全三套
#
#    backup          在运行的容器里生成一份全量备份
#    reset-system    重置系统层（保留数据层）：make reset-system CONFIRM=yes
#    reset-panel     重置面板代码到镜像版本（保留配置与数据库）
#    lint            shellcheck + bash -n + YAML 语法检查
#    version         打印两个通道当前记录的宝塔版本
# ==============================================================================

CHANNEL ?= stable
IMAGE   ?= baota:dev
SHELL   := /bin/bash

ROOT_DIR   := $(shell pwd)
CHANNEL_DIR := $(ROOT_DIR)/$(CHANNEL)

# shellcheck 可能由 pip --user 安装（macOS 系统 Python 在 ~/Library/Python/<版本>/bin，
# 不在默认 PATH）。已在 PATH 就直接用，否则自动定位，避免本地 lint 静默跳过
SHELLCHECK_BIN := $(shell command -v shellcheck 2>/dev/null || find $(HOME)/Library/Python $(HOME)/.local -name shellcheck -type f 2>/dev/null | head -1)
ifneq ($(SHELLCHECK_BIN),)
export PATH := $(dir $(SHELLCHECK_BIN)):$(PATH)
endif

.DEFAULT_GOAL := help
.PHONY: help build up down restart logs ps exec health health-mounts health-upgrade \
        health-all backup reset-system reset-panel lint version

help: ## 显示本帮助
	@echo 'baota-docker · make <目标> [CHANNEL=stable|release] [IMAGE=标签]'
	@echo
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo '  当前 CHANNEL=$(CHANNEL)  IMAGE=$(IMAGE)'

build: ## 构建镜像（CHANNEL=stable|release，IMAGE=标签）
	docker build -f $(CHANNEL_DIR)/Dockerfile -t $(IMAGE) .

up: ## 启动容器
	cd $(CHANNEL_DIR) && docker compose up -d

down: ## 停止并移除容器
	cd $(CHANNEL_DIR) && docker compose down

restart: ## 重启容器
	cd $(CHANNEL_DIR) && docker compose restart

logs: ## 跟踪日志（首次登录凭据在这里）
	cd $(CHANNEL_DIR) && docker compose logs -f baota

ps: ## 查看健康状态
	cd $(CHANNEL_DIR) && docker compose ps

exec: ## 进入容器（make exec CMD="bt default"）
	cd $(CHANNEL_DIR) && docker compose exec baota $(or $(CMD),bash)

# 三套发布前检查的统一入口（.github/scripts/health-check/），
# 各覆盖一个互不相关的失效面：
#   core     19 项功能检查 —— 「功能完整性」
#   mounts   挂载方式与降级场景 —— 「挂载正确性」
#   upgrade  升级 / 降级路径 —— 「版本演进」
HC := .github/scripts/health-check
HC_VERSION := $(or $(VERSION),$(shell tr -d '[:space:]' < $(CHANNEL_DIR)/VERSION))

health: ## 19 项功能检查（全新卷 + 同卷重建）
	bash $(HC)/run.sh core "$(IMAGE)" "$(HC_VERSION)"

health-mounts: ## 挂载方式与降级场景（混合挂载 + 只读降级）
	bash $(HC)/run.sh mounts "$(IMAGE)"

health-upgrade: ## 升级 / 降级路径（版本护栏 + 快照 + 启动器刷新）
	bash $(HC)/run.sh upgrade "$(IMAGE)" "$(HC_VERSION)"

health-all: ## 三套全部跑一遍，任一失败即终止
	bash $(HC)/run.sh all "$(IMAGE)" "$(HC_VERSION)"

backup: ## 在运行中的容器里生成一份全量备份
	docker exec baota baota-backup $(OPTS)

# 重置系统层：清空 etc usr var root opt home srv 的持久化内容，
# 让系统层回到「当前镜像」的状态。数据层（/www：面板 / 站点 / 数据库 / 备份）
# 完全不受影响 —— 这正是把持久化拆成两层的意义。
#
# 会丢什么：apt 装的软件、手工改过的 /etc、计划任务（/var/spool/cron）、
#           root 家目录（含 .ssh/authorized_keys）、/var/log 历史日志
# 什么不丢：面板账号与配置、站点文件、数据库、备份、证书（都在数据层）
#
# .baota 元数据刻意保留：里面有镜像版本记录，删了会被判成「首次使用」，
# 导致升级前快照逻辑失效（没有可回滚的旧数据）
#
# 必须先 down：容器运行时系统层正挂着 overlay，此时删 upper 是未定义行为
reset-system: ## 重置系统层（保留数据层）：make reset-system CONFIRM=yes
	@[ "$(CONFIRM)" = "yes" ] || { \
	    echo '⚠️  系统层将被清空，以下内容会丢失：'; \
	    echo '    apt 装的软件、手工改过的 /etc、计划任务、root 家目录、历史日志'; \
	    echo '  以下内容不受影响：面板账号与配置、站点、数据库、备份、证书'; \
	    echo '  确认执行：make reset-system CONFIRM=yes'; \
	    exit 1; \
	}
	@set -eu; \
	cd "$(CHANNEL_DIR)"; \
	if [ -d system ]; then SYS=system; else SYS=data/system; fi; \
	if [ ! -d "$$SYS" ]; then \
	    echo "未找到系统层目录（$$SYS）。容器还没启动过，或挂载方式不是这两种。"; \
	    exit 1; \
	fi; \
	echo "系统层目录：$$SYS"; \
	docker compose down; \
	for d in etc usr var root opt home srv; do \
	    if [ -d "$$SYS/$$d" ]; then \
	        rm -rf "$$SYS/$$d"; \
	        echo "  已清空 $$SYS/$$d"; \
	    fi; \
	done; \
	if [ -d "$$SYS/www" ] && [ -z "$$(ls -A "$$SYS/www" 2>/dev/null)" ]; then \
	    rm -rf "$$SYS/www"; echo "  已清理空的 $$SYS/www（旧版本遗留）"; \
	elif [ -d "$$SYS/www" ]; then \
	    echo "  跳过非空的 $$SYS/www（里面可能有数据，未自动删除，请自行确认）"; \
	fi; \
	echo '系统层已重置（.baota 元数据保留）'; \
	docker compose up -d; \
	echo '完成。查看启动日志：make logs CHANNEL=$(CHANNEL)'

# 重置面板代码：把 /www/server/panel 下（除 data / pyenv 外）被更新、被改动过的
# 文件从持久化层里删掉。容器下次启动时，overlay 视图会自动回落到镜像里的版本 ——
# 直接删 upper 文件不会产生 whiteout，效果等于「这些文件从未被改过」。
#
# 适用场景：在面板里误点了「更新」。面板更新会把新版文件写进持久化层，
# 永久屏蔽镜像层，之后无论怎么重建镜像都不再生效（启动日志会告警
# 「面板实际版本与镜像版本不一致」）。audit_panel_version 只能发现、不能修复，
# 这个目标就是修复手段。
#
# 刻意保留的目录：
#   data   面板配置、SQLite 数据库、端口与安全入口 —— 重置它们等于重装面板
#   pyenv  Python 运行环境。面板更新也会动它，但插件装过的 pip 包同样在这里，
#          默认不重置；确需彻底重置时加 RESET_PYENV=yes
#
# 会丢什么：已安装的面板插件（panel/plugin，可从软件商店重装）
# 不受影响：站点、MySQL 数据、备份、证书（都在 panel 之外）
#
# 面板代码路径：/www 走 overlay，upper 在 data/system/panel（不属于业务直通层），
# 所以容器里的 /www/server/panel 对应宿主 data/system/panel/server/panel。
# 这个位置与挂载方式无关（单挂 ./data:/data 与混合挂载都一样），无需分支判断。
# 数据层根仍是 data/，业务三目录在 data/www 下（wwwroot / backup / server/data），
# 与面板 upper 分属两层，重置面板不会碰到它们
reset-panel: ## 重置面板代码到镜像版本：make reset-panel CONFIRM=yes
	@[ "$(CONFIRM)" = "yes" ] || { \
	    echo '⚠️  面板代码将重置回当前镜像的版本：'; \
	    echo '    丢弃：被面板更新 / 手工改动过的代码文件'; \
	    echo '          已安装的面板插件（panel/plugin，可从软件商店重装）'; \
	    echo '    保留：panel/data（面板配置与数据库）、panel/pyenv（Python 环境）'; \
	    echo '    站点、MySQL 数据、备份、证书完全不受影响'; \
	    echo '  适用：在面板里误点了「更新」，启动日志提示面板版本与镜像版本不一致'; \
	    echo '  可选：连 pyenv 一起重置（插件装过的 pip 包会丢）：'; \
	    echo '        make reset-panel CONFIRM=yes RESET_PYENV=yes'; \
	    echo '  确认执行：make reset-panel CONFIRM=yes'; \
	    exit 1; \
	}
	@set -eu; \
	cd "$(CHANNEL_DIR)"; \
	PANEL=data/system/panel/server/panel; \
	if [ ! -d "$$PANEL" ]; then \
	    echo "未找到面板目录：$$PANEL。容器还没启动过，或挂载方式不是这两种。"; \
	    exit 1; \
	fi; \
	echo "面板目录：$$PANEL"; \
	if [ "$(RESET_PYENV)" = "yes" ]; then echo 'Python 环境：重置'; else echo 'Python 环境：保留'; fi; \
	docker compose down; \
	for item in "$$PANEL"/* "$$PANEL"/.[!.]*; do \
	    if [ -e "$$item" ]; then \
	        base=$$(basename "$$item"); \
	        case "$$base" in data|pyenv) continue ;; esac; \
	        rm -rf "$$item"; \
	        echo "  已重置 $$base"; \
	    fi; \
	done; \
	if [ "$(RESET_PYENV)" = "yes" ]; then \
	    rm -rf "$$PANEL/pyenv"; \
	    echo '  已重置 pyenv（插件装过的 pip 包随之清除）'; \
	fi; \
	echo '面板代码已重置（panel/data 与站点 / 数据库均保留）'; \
	docker compose up -d; \
	echo '完成。启动后确认日志里不再出现「面板实际版本与镜像版本不一致」：'; \
	echo '  make logs CHANNEL=$(CHANNEL)'

version: ## 打印两个通道记录的宝塔版本
	@echo "stable : $(shell tr -d '[:space:]' < stable/VERSION)"
	@echo "release: $(shell tr -d '[:space:]' < release/VERSION)"

lint: ## 静态检查：shellcheck + bash -n + YAML 语法
	@echo '--- bash -n ---'
	@for f in shared/build/*.sh shared/scripts/entrypoint.sh \
	          shared/scripts/backup.sh \
	          .github/scripts/health-check/*.sh \
	          .github/scripts/drift-check/*.sh; do \
	    bash -n "$$f" && echo "  ok  $$f" || { echo "  FAIL $$f"; exit 1; }; \
	 done
	@echo '--- sh -n (POSIX) ---'
	@for f in shared/scripts/init-mounts.sh shared/scripts/healthcheck.sh \
	          shared/conf/defaults.env; do \
	    sh -n "$$f" && echo "  ok  $$f" || { echo "  FAIL $$f"; exit 1; }; \
	 done
	@echo '--- shellcheck ---'
	@if command -v shellcheck >/dev/null 2>&1; then \
	    shellcheck -x -S warning shared/build/*.sh shared/scripts/*.sh \
	               .github/scripts/health-check/*.sh \
	               .github/scripts/drift-check/*.sh \
	        && echo '  shellcheck 通过'; \
	 else \
	    echo '  未安装 shellcheck，跳过（安装与排查见 docs/development.md「本地构建」）'; \
	 fi
	@echo '--- YAML 语法 ---'
	@for f in stable/docker-compose.yml release/docker-compose.yml \
	          .github/workflows/*.yml; do \
	    python3 -c "import sys,yaml;yaml.safe_load(open('$$f'))" \
	        && echo "  ok  $$f" || { echo "  FAIL $$f"; exit 1; }; \
	 done
