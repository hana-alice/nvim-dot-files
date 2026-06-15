# tools/ — Python/Go 工具与开发脚本

> 继承 `../CLAUDE.md`（根强制入口）。本目录非 Lua 运行时代码，但同样遵守可发现/可记录纪律。

## 用途

不依赖 Neovim 运行的独立工具：CDB 生成/裁剪（`build_*_cdb.py`、`prune_*`、`slim_*`、`inject_*`）、
PCH 预编译（`prebuild_pch*.py`）、clangd 索引（`build_clangd_index.py`）、DAP 探针（`dap_*probe*.py`）、
csearch 索引器 `cindex-uefilter/`（Go fork），及若干 `.lua` headless 探针/e2e。

## 什么属于这里 / 不属于这里

- **属于**：能脱离 nvim 单独跑的 utility / 探针 / 索引器。
- **不属于**：运行时配置（→ `../lua/`）、安装/profiling/lint 脚本（→ `../scripts/`）。

## 专属约定

- **不动第三方 / 生成物**：`cindex-uefilter/`（Go 源）、`__pycache__/` 不随意重排或重写。
- 工具幂等 + skip-if-unchanged：生成器写前比对，避免使下游 cache 失效。→ C4.6
- DAP 探针是历史调试资产，与 `lua/ue/dap/` 配方对照看；权威坑在 `../docs/CONSTRAINTS.md §二`。
- 公开镜像安全：工具不得硬编码 secret 或新私有路径。

## 改动 → 必跑回归

工具本身不在 headless 套件内；改动后手动跑对应工具验证，并在 `../docs/changelog.md` 记录（含验证方式）。

## 先读

`../docs/skills/ue-ide-bootstrap.md`（端到端搭建用到这些工具）、`../docs/TOOLING.md`。
