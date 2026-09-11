# 🤖 AI 编程助手技能包

把本项目的使用方式固化成 skill，让 AI 助手在改这个仓库时自动遵守那些
「不写下来就会被违反」的约定（比如配置常量只写一处、运行期脚本不能放进持久化目录）。

```
skills/
├── README.md            本文件
├── codebuddy/           CodeBuddy / CodeBuddy IDE
│   └── baota-docker/
│       ├── SKILL.md             入口：红线、文件地图、命令速查、排障入口
│       └── references/
│           ├── architecture.md  持久化方案与启动链的设计理由
│           └── troubleshooting.md  症状 → 原因 → 处置
└── trae/                Trae（预留位）
    └── baota-docker/
        └── SKILL.md     与 codebuddy 版同步的内容；references 直接复用上面那一份，不重复维护
```

## 用法

### CodeBuddy

把 `skills/codebuddy/baota-docker/` 复制到 `~/.codebuddy/skills/`，
或者在本仓库里直接引用（CodeBuddy 会识别 `.codebuddy/skills/` 与项目内的 skill 目录）。

触发词：宝塔、baota、baota-docker、面板容器化，或任何在本仓库里的改动。

### Trae

`skills/trae/baota-docker/SKILL.md` 是预留位，内容与 codebuddy 版保持一致。
Trae 的 skill 加载目录与 CodeBuddy 不同，使用前请按 Trae 的规范放置。

## 维护约定

- **两个目录的内容必须保持同步**。改了 codebuddy 版，trae 版要跟着改
- SKILL.md 只放「AI 不知道就会犯错」的东西：项目红线、文件地图、命令速查。
  细节放 `references/`，按需加载（progressive disclosure）
- 文档正文在 `docs/`，skill 只做索引和红线，不重复大段说明
