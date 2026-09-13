# AI 编程助手技能包（通用一份）

`baota-docker/` 是**给 AI 编程助手看的**本仓库说明：红线、文件地图、命令速查、
排障入口。它不绑定任何工具 —— **Codex / CodeBuddy / Trae / 其它都放同一份**，
不要把同一内容复制成多份手工同步（必然漂移，历史上已经删过一份 Trae 副本）。

```
skills/
└── baota-docker/
    └── SKILL.md                     唯一入口：红线、文件地图、命令速查、排障入口
```

## 怎么装

把 `skills/baota-docker/` 整个目录放进对应工具的技能目录即可（具体路径以各工具文档为准）：

| 工具 | 常见位置 |
|---|---|
| Codex | `$CODEX_HOME/skills/`（默认 `~/.codex/skills/`） |
| CodeBuddy | `~/.codebuddy/skills/` |
| Trae | 按其技能文档指定的目录 |

也可以不安装：直接在对话里让助手读 `skills/baota-docker/SKILL.md`。

## 维护约定

- **只维护这一份**。需要给别的工具用，就复制/链接 `baota-docker/` 整个目录
- SKILL.md 只放「AI 不知道就会犯错」的东西：红线、文件地图、命令速查；
  细节写进 `docs/`，技能里只做索引 —— 正文与技能重复的地方，一律以 `docs/` 为准
- 改了仓库结构、命令、红线时，同步更新 `SKILL.md`（它是助手的第一入口）
