# Skills

> 这个目录归档关于本 nvim 配置如何在大型工程仓上运转的 **流程级 / 工程级** 文档。
> 与 `docs/plans/` 区分：plans 是一次性的迭代计划，skills 是长期可复用的配方。

## 索引

| Skill | 用途 |
|---|---|
| [`ue-ide-bootstrap.md`](ue-ide-bootstrap.md) | 从零开始 (clone 完源码) 把一个 UE 大仓搭成 nvim IDE 的端到端流程 (8 步、110 min、+71 GB) |

## 命名约定

- 文件名 = skill 名（kebab-case）
- 顶部 YAML frontmatter 含 `name` / `description` / `trigger_keywords` / `related_skills`
- 内容力求 **可执行** + **可校验数字**（耗时 / 内存 / 磁盘）

## 添加新 skill

1. 写在 `docs/skills/<name>.md`
2. 更新本 README 的索引表
3. 命名遵从 trigger keyword 直觉（被搜的时候能想到的词）
