# Tasks — Neovim 基本功能健康审计

## 1. 冻结现有证据与失败语义

- [x] 1.1 记录当前全量回归、真实启动、parser、csearch/cindex、rg、clangd 和 UE context 的只读基线。
- [x] 1.2 建立 `PASS`、`FAIL`、`BLOCKED`、`SKIP` 与 overall `PASS/FAIL/DEGRADED` 的纯函数测试。
- [x] 1.3 为敏感路径、设备、证书和环境值定义脱敏 fixture；报告不得固定现场身份。
- [x] 1.4 决定 design 中三个 open decisions，并在 apply 前写回 design。

## 2. 统一 health runner

- [x] 2.1 新增只读 headless runner，支持人类可读输出、JSON 输出、deterministic/live 模式和 filter。
- [x] 2.2 为每个 check 实现稳定 id、stage、status、duration、summary、next_step schema。
- [x] 2.3 实现有界 deadline、异常隔离、退出码聚合和临时资源统一清理。
- [x] 2.4 证明 runner 不执行安装、更新、build/package/deploy/launch/DAP 或持久化状态修改。

## 3. 启动与基础编辑

- [x] 3.1 以真实配置启动隔离子进程，捕获完整 init/Lazy startup 错误且禁止自动安装更新。
- [x] 3.2 在临时目录验证 create/open/edit/write/reopen 内容一致性。
- [x] 3.3 验证 filetype、关键 options、autocmd、用户命令和 keymap 注册。
- [x] 3.4 验证重复 setup/startup 不产生重复 autocmd、命令冲突或泄漏状态。

## 4. Tree-sitter 语法树

- [x] 4.1 从 plugin spec 解析 mandatory parser 集合，避免在 health runner 维护第二份语言清单。
- [x] 4.2 为 `c`、`cpp`、`hlsl` 建立最小真实 fixture，逐个加载 parser 并检查 root/named/error/missing node。
- [x] 4.3 覆盖 parser 缺失、加载失败、fixture syntax error 和 parser 正常四类结果。
- [x] 4.4 证明 Tree-sitter 与 clangd/CDB 状态独立，任一侧失败不篡改另一侧结论。

## 5. csearch 与 fallback 搜索

- [x] 5.1 复用临时语料验证 `rg` fallback 的 literal/case/path/完整交付顺序。
- [x] 5.2 工具齐备时，在临时目录执行真实 cindex/csearch build/query，并经公共 dispatcher 返回预期命中。
- [x] 5.3 验证 csearch 缺失、cindex 缺失、命令失败、空/损坏临时索引和用户 `CSEARCHINDEX` 不被污染。
- [x] 5.4 报告实际 backend、索引 identity、命中数与耗时，不输出用户 workspace 路径。

## 6. clangd、CDB 与 UE 集成

- [x] 6.1 探测实际 clangd path/version，按 22.1.x 约束报告 compatible 或 blocked。
- [x] 6.2 deterministic 层验证最小 CDB/schema、response provenance 和 semantic fixture，不执行 UE build。
- [x] 6.3 live 层只读验证 active tuple、CDB、clangd index 与 csearch index provenance/freshness。
- [x] 6.4 在调用者显式提供外部 smoke spec 时复用 `scripts/ue_cpp_semantic_smoke.lua`，否则标记 SKIP。
- [x] 6.5 验证 target registry/host capability plan 可生成，但不执行 build/package/device 命令。

## 7. 稳定性、文档与验证

- [x] 7.1 验证所有 probe deadline、cancel、process exit、pipe/timer close 和临时目录清理。
- [x] 7.2 连续运行两次并比较 capability id/status shape，证明无上一轮隐式状态依赖。
- [x] 7.3 新增 `core_health` 回归 filter，同步 `tests/AGENTS.md` 和 `docs/testing-regression.md`。
- [x] 7.4 更新 README/cheatsheet，准确说明 deterministic 与 live/GUI/device gate。
- [x] 7.5 运行 scoped tests、完整回归、格式和静态检查，并记录实际证据与已知外部阻塞。
- [x] 7.6 完成后更新 changelog/milestone；未经真实 live gate 不宣称对应 capability E2E 通过。
