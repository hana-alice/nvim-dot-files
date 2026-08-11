# Design — add-nvim-core-functionality-audit

## Context

仓库已经有覆盖广泛的 headless regression，但测试证据分散在 unit/contract、fixture、工具链探测和
live workspace 脚本中。新审计的职责不是再造一套测试框架，而是把这些证据组织成一个可解释的
capability report，并补齐少量真实运行盲区。

现有证据基线：

| 能力 | 已有证据 | 主要缺口 |
|---|---|---|
| Lua/UE module | `smoke_spec.lua`、`ue_api_spec.lua` | 不覆盖完整 init/plugin startup |
| 命令/keymap/options/autocmd | 对应 `*_spec.lua` | 多为存在性/契约，不覆盖最小真实编辑事务 |
| Tree-sitter | plugin 配置 + `ue_goto.symbol` 使用 | 未验证已安装 parser 和真实 AST/error nodes |
| csearch | `utils_spec`、`csearch_build_guard_spec` | 无真实临时 cindex/csearch 查询闭环 |
| clangd/CDB | semantic/CDB fixture tests | 本机版本与 live CDB/LSP 是外部 gate |
| UE target/tasks | target driver/integration/tasks specs | 不应在通用 health 中触发真实 build/device side effect |
| 稳定性 | `stability_spec.lua` | 缺统一 handle/leak/startup evidence 摘要 |

## Goals

- 给出“什么正常、什么失败、什么只是缺外部条件”的可解释结论。
- 用真实 parser/process/file transaction 补充纯 mock 契约，但保持探测只读和有界。
- 同一 runner 可在 macOS、Windows、Linux 输出相同 schema；平台不具备的能力不伪装实现。
- 失败必须包含 stage、简短原因和可执行下一步，不输出敏感现场身份。

## Architecture

### 1. 两层执行模型

`deterministic` 层默认执行，允许写入唯一临时目录：

1. 启动/模块/命令契约；
2. 临时 buffer/file 编辑事务；
3. 已声明 Tree-sitter parser 的真实 fixture parse；
4. `rg` fallback 临时语料查询；
5. csearch/cindex 工具同时存在时的临时索引查询；
6. CDB/schema/target plan/async lifecycle fixture；
7. 重复 setup、任务结束和临时资源清理。

`live` 层必须显式传参并保持只读：

1. 解析当前已绑定 UE context；
2. 检查 active CDB/index 文件及 provenance，不生成或修复；
3. 对既有 csearch index 执行已知无害查询；
4. 复用 `scripts/ue_cpp_semantic_smoke.lua` 的外部 JSON spec；
5. 只探测设备/签名可用性，不执行 install/launch。

### 2. Capability report schema

```json
{
  "schema_version": 1,
  "overall": "PASS|FAIL|DEGRADED",
  "checks": [
    {
      "id": "treesitter.cpp.parse",
      "status": "PASS|FAIL|BLOCKED|SKIP",
      "duration_ms": 12,
      "summary": "cpp parser produced translation_unit without ERROR nodes",
      "next_step": null
    }
  ]
}
```

判定规则：

- deterministic 必需项出现 `FAIL` → `overall=FAIL`，进程退出非零。
- 必需外部工具缺失或 live gate 不满足 → 对应项 `BLOCKED`，总结果至多 `DEGRADED`，不得伪报失败。
- 用户未请求的 live/GUI/device 项 → `SKIP`。
- `PASS` 必须来自执行证据，不能仅来自函数存在或配置字符串存在。

### 3. 检查矩阵

#### Startup / basic editing

- 用真实配置启动子进程，捕获启动退出码和早期错误；禁止自动 plugin install/update。
- 在临时目录完成 create/open/edit/write/reopen，验证内容、filetype、关键 option 和 autocmd 结果。
- 验证命令和 keymap 注册；不自动触发 build、DAP、device 或 picker UI。

#### Tree-sitter

- 从配置声明中读取 mandatory parser 集合，首版为 `c`、`cpp`、`hlsl`，不另写一份漂移清单。
- 每个 parser 加载真实 fixture，执行 `get_parser():parse()`，验证 root type、非空 named node，且 fixture
  覆盖区域没有 `ERROR`/missing node。
- parser 未安装/不可加载为 `FAIL`（它是当前配置声明的基础能力）；用户未声明的语言只能 `SKIP`。
- Tree-sitter 状态与 clangd/CDB 完全独立展示。

#### csearch / project search

- `rg` 必须用临时语料验证 literal、case、文件路径和完整交付顺序。
- 只有 `cindex-uefilter` 与 `csearch` 都存在时，才在临时目录构建一次最小索引并通过公共
  `utils.code_search.stream` 查询已知 token；不得复用或覆盖用户现有 `CSEARCHINDEX`。
- csearch 工具缺失时该 backend 为 `BLOCKED`，但 `rg` fallback 通过则 project search capability
  为 `DEGRADED`，不是整体失败。
- staged/损坏 index 的恢复仍由现有回归负责，health runner 不复制这些内部用例。

#### clangd / CDB / UE semantics

- 检查实际 clangd path/version，并按仓库约束区分 compatible 与 blocked。
- deterministic 层验证最小 CDB JSON、response provenance 和 fixture semantic path，不运行 UE build。
- live 层只读取 active tuple、CDB/index/provenance，并在调用者提供 smoke spec 时运行现有 semantic smoke。
- Tree-sitter parse 可用但 clangd 版本不足时，报告 syntax `PASS`、compiler semantics `BLOCKED`。

#### Async / stability

- 所有 probe 带 deadline；超时为明确 `FAIL` 或 `BLOCKED`，不得无限等待。
- runner 退出前验证其创建的 job/timer/pipe 已终止，临时目录已清理。
- 连续运行两次必须得到相同 capability 集合，且第二次不依赖第一次留下的缓存或全局状态。

## Safety and privacy

- runner 不得运行安装、更新、构建、Cook、Package、Deploy、Launch、DAP attach 或设备写操作。
- 所有写入限定到 `mkdtemp`/`vim.fn.tempname()` 生成并验证的临时目录。
- JSON/report 默认只记录 basename、工具版本、状态和散列后的 identity；用户目录和 workspace root 脱敏。
- 清理失败必须作为独立 check 报告，不能静默吞掉。

## Alternatives considered

### 只运行现有全量回归

拒绝。它是必要 gate，但大部分用例刻意使用 mock/fixture，无法证明真实 parser 和 csearch binary 可用。

### 直接运行 `:checkhealth`

拒绝作为唯一答案。`checkhealth` 可作为一个输入，但不了解本仓的 CDB provenance、csearch index、
target driver 和 semantic sidecar 契约。

### 一次 health 自动修复所有缺失工具

拒绝。自动安装/更新会引入网络、副作用和版本漂移，并破坏“检查”和“修改”的边界。

### 把所有外部能力缺失都作为 FAIL

拒绝。没有设备、签名或 clangd 22.1.x 不代表基础 Neovim/Tree-sitter 已损坏；必须按 capability 分层。

## Decisions resolved for apply

1. 同时提供 headless script 与只读 `:NvimCoreHealth` 命令；两者调用同一 runner，不维护两套逻辑。
2. csearch/cindex 缺失时对应 check 为 `BLOCKED`，`rg` fallback 通过时 overall 为 `DEGRADED`；
   不把它误报成基础编辑失败，也不把缺少高性能 backend 隐藏成全绿。
3. startup probe 加载真实 init 和启动阶段 critical plugins，不强制加载全部可选/交互插件；探测环境
   显式关闭 Lazy missing-install、checker 和 change detection，保证只读。
