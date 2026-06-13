## Why

`<leader>/` 的 UE 全代码搜索当前会出现结果不全：在 csearch/rg 流式输出尾部、csearch 工具探测失败缓存、或平台/项目切换后缓存失效时，用户可能看到缺失结果而没有明确提示。这个问题直接影响大型 UE 工程里查符号、查引用和查配置的可信度，必须把完整性、回退可见性和回归覆盖固定下来。

## What Changes

- 修复 `cached_grep` 的 csearch/rg 流式交付顺序，保证所有已解析命中先进入 picker，再触发完成信号。
- 修复 csearch/cindex 工具探测的负缓存问题，只缓存成功路径，UEPrepare、项目切换、平台切换后可重新探测。
- 将 grep-facing 缓存按平台/配置分路径，避免切平台后复用旧平台的 csearch/gtags 文件列表。
- 在无 csearch index 且无 cached file list 时让 fallback 明确可见，避免以普通标题呈现可能漏文件的慢速目录遍历。
- 增加 headless 回归测试覆盖缓存路径、迁移、探测重置、流式完成顺序和 fallback 标识。

## Capabilities

### New Capabilities
- `ue-code-search`: 定义 UE 全代码搜索的完整性、缓存选择、平台隔离、回退提示和回归验证契约。

### Modified Capabilities

## Impact

- 主要影响 `lua/ue.lua` 的 `cached_grep`、UEPrepare finalize、项目/平台切换缓存失效逻辑。
- 影响 `lua/utils/code_search/init.lua` 的 csearch/rg backend、工具探测缓存和流式回调顺序。
- 影响 `lua/plugins/snacks.lua` 中 `<leader>/` fallback picker 标题与行为。
- 需要更新 `tests/cases/grep_cache_spec.lua` 或新增相邻用例，并按本仓规则更新 `docs/changelog.md`。
- 不引入新依赖，不改变 `<leader>/` 键位入口，不改变 LazyVim/snacks 的外部 API。
