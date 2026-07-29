## Context

当前 `lua/theme.lua` 用有序 `THEMES` 注册表统一控制 completion、picker、合法性检查、plugin lazy-load 与持久化。多数条目的 canonical name 与 `:colorscheme` name 相同；Sonokai 不同：插件只有 `sonokai` colorscheme，具体 variant 由加载前的 `g:sonokai_style` 决定。因此不能直接把 `sonokai` 当作公开名称，否则无法表达并冻结 Espresso，也容易让其他 variants 成为隐式入口。

## Goals / Non-Goals

**Goals:**

- 只接入 Sonokai Espresso，并在所有项目主题入口中使用稳定 canonical name `sonokai-espresso`。
- 每次加载都先设置 Espresso variant，再执行真实 `sonokai` colorscheme。
- 保持既有 registry/picker/persistence 架构和按需加载行为。

**Non-Goals:**

- 不暴露或配置 Sonokai 的其他五个 variants。
- 不修改 Sonokai palette，不 fork 或复制其 colorscheme 文件。
- 不改变默认主题 `monokai_ristretto`。

## Decisions

### D1：扩展 registry metadata，不增加特例命令

新增条目：`{ name="sonokai-espresso", label="Sonokai Espresso", plugin="sonokai", colorscheme="sonokai", before=... }`。`apply`/`load_startup` 通过统一 helper 读取 `colorscheme` 和执行 `before`。相比在命令 callback 里硬编码 Sonokai 分支，这让 canonical/public identity 与 runtime identity 的差异成为注册表数据，并保持 public API 可测试。

### D2：每次加载前强制 Espresso，并禁用同步 syntax-cache 生成

`before` hook 每次赋值 `vim.g.sonokai_style = "espresso"`，而不是只在 plugin spec `init` 设置一次。这样即使用户或其他脚本曾修改该全局变量，再次 `:Theme sonokai-espresso` 仍满足契约。同时固定 `vim.g.sonokai_better_performance = 0`：上游文档说明开启该选项后首次生成 syntax files 最长可达 5 秒，这与本仓 P6 禁止阻塞主线程冲突；关闭后的普通加载成本仅是上游所述的几十毫秒。

### D3：插件名显式设为 `sonokai`

Lazy spec 使用 `{ "sainnhe/sonokai", name="sonokai", lazy=true, priority=1000 }`，与 registry 的 lazy.load key 和 lockfile key一致。

### D4：runtime identity 折叠回 canonical identity

Sonokai 加载后 `vim.g.colors_name` 为 `sonokai`。`current()` 根据 registry 的 `colorscheme` 字段折叠为 `sonokai-espresso`，使 picker 当前项、取消预览恢复和持久化语义保持正确。

## Risks / Trade-offs

- [Sonokai 是 Vimscript 主题，加载可能比 Lua 主题慢] → 保持 lazy load；按上游文档，关闭 performance cache 的额外成本通常仅几十毫秒，并用实际加载回归覆盖。
- [开启 `better_performance` 首次会同步生成 syntax cache，最长约 5 秒] → 固定关闭该选项，避免违反 P6 主线程不卡顿约束。
- [用户原生执行 `:colorscheme sonokai` 也会被 `current()` 识别为 Espresso] → 项目在 plugin init 和每次受控加载都固定 style；原生命令不属于项目主题入口。
- [新增依赖违背默认不新增依赖] → 用户明确指定仓库与 variant，满足显式请求例外。

## Migration Plan

1. 增加 plugin spec 与 registry metadata/helper。
2. 安装 Sonokai 并锁定 `lazy-lock.json` commit。
3. 扩充 theme regression，验证六项严格集合、Espresso style 和 runtime identity。
4. 更新文档、规格、changelog，跑范围与全量回归。
5. 回滚时删除 registry 条目、plugin spec 与 lock entry；已持久化 `sonokai-espresso` 会被现有白名单校验安全迁移回默认主题。

## Open Questions

无。
