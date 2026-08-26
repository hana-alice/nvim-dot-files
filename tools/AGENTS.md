# tools/ — Python/Go 工具与开发脚本

> 继承 `../AGENTS.md`（根强制入口）。本目录非 Lua 运行时代码，但同样遵守可发现/可记录纪律。

## 用途

不依赖 Neovim 运行的独立工具：CDB 生成/裁剪（`build_*_cdb.py`、`prune_*`、`slim_*`、`inject_*`）、
PCH 预编译（`prebuild_pch*.py`）、clangd controlled BackgroundIndex CDB
（`build_{clangd_index,full_cdb,hot_super_unity_cdb}.py`）、DAP 探针（`dap_*probe*.py`）、
csearch 索引器 `cindex-uefilter/`（Go fork），及若干 `.lua` headless 探针/e2e。

### 卡顿（stall）诊断三件套

`stall_profile.lua` / `stall_attribute.lua` / `stall_repro.lua` 用于定位「IDE 卡了，是谁占的」。
**默认不启用**（P5/P6），只在排查时手动注入。

| 工具 | 回答什么 | 怎么用 |
|---|---|---|
| `stall_attribute.lua` | **归属判定**：这段 gap 是本进程内阻塞，还是被剥夺调度 | 看 `cpu/gap` 比值：≈1 = 本进程内阻塞；≈0 = 宿主超订 |
| `stall_repro.lua` | 每个导航键的真实延迟（含 autocmd/statuscolumn/redraw） | 在**活实例**上回放按键；默认只跑只读场景 |
| `stall_profile.lua` | 哪段 Lua 跑得多（**不**回答谁占了这 250ms） | `jit.profile` 采样，空闲时会误记到最后运行的栈 |

**必须在活的 GUI 实例上跑**，用 `--server` 注入：

```
nvim --headless --server //./pipe/nvim.<PID>.0 --remote-expr \
  "luaeval('dofile(_A)', 'C:/Users/<you>/AppData/Local/nvim/tools/stall_attribute.lua')"
```

**为什么不能用 `--headless` 复现**：headless 无渲染线程、无 UI 管道，几乎不需要 CPU，
**结构上看不到 UI 争用**——2026-08-25 排查中 6 次 headless 实验全报告「主循环很顺」，
而用户 GUI 会话正以 30 stalls/min 卡顿。详见 `../docs/CONSTRAINTS.md` K52。

## 什么属于这里 / 不属于这里

- **属于**：能脱离 nvim 单独跑的 utility / 探针 / 索引器。
- **不属于**：运行时配置（→ `../lua/`）、安装/profiling/lint 脚本（→ `../scripts/`）。

## 专属约定

- **不动第三方 / 生成物**：`cindex-uefilter/`（Go 源）、`__pycache__/` 不随意重排或重写。
- 工具幂等 + skip-if-unchanged：生成器写前比对，避免使下游 cache 失效。→ C4.6
- DAP 探针是历史调试资产，与 `lua/ue/dap/` 配方对照看；权威坑在 `../docs/CONSTRAINTS.md §二`。
- 公开镜像安全：工具不得硬编码 secret 或新私有路径。

## 改动 → 必跑回归

controlled BackgroundIndex 生成器由 `index_generation` / `cpp_semantic_index` 覆盖；其他工具
改动后手动跑对应工具验证，并在 `../docs/changelog.md` 记录（含验证方式）。

## 先读

`../docs/skills/ue-ide-bootstrap.md`（端到端搭建用到这些工具）、`../docs/TOOLING.md`。

**治理 spec**（可观察行为的权威；与本文冲突时以 spec 为准）：
`../openspec/specs/nvim-core-functionality-audit/spec.md`、
`../openspec/specs/codebase-health-audit/spec.md`、
`../openspec/specs/editor-behavior-regression/spec.md`（主循环余量 / stall 诊断纪律）。
