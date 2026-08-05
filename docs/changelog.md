# Neovim Config Changelog

Working log for every change inside `~/AppData/Local/nvim/`. Every commit
should add an entry here even if it's tiny — the goal is total recall across
sessions, not curated release notes. When entries pile up, slice off a
versioned `RELEASE_vX.Y.Z.md` (see `release_1.0.0.md` for the format) and
keep this file rolling forward as the unreleased section.

## Entry template

```
### YYYY-MM-DD — Short title

**Task** (one line — why you touched the config)

**Implemented**
- bullet list of concrete changes (file paths + function names)

**Pitfalls / Gotchas**
- traps hit during the change, with the fix

**Validation**
- how you proved it works (headless probe, live nvim test, etc.)

**Follow-ups**
- links to `.hermes/plans/*.md` or TODO bullets
```

## How to use

1. Before touching anything under `~/AppData/Local/nvim/`, skim the latest
   N entries here. Fresh sessions don't carry context — this is where you
   recover it.
2. After landing a change (even a one-line patch), append an entry. The
   **Validation** field MUST state which regression scope you ran (a filter
   like `dap`/`commands`, or full `nvim --headless -l tests/run.lua`) and the
   result — see `docs/testing-regression.md` for the change→filter map.
3. When 8–12 entries have piled up OR a coherent multi-change effort wraps,
   cut a **milestone**: bump the version by semver (BREAKING→major, new
   capability→minor, fix→patch), move entries into `docs/release_vX.Y.Z.md`,
   run the **full** regression as a gate, tag the commit (`vX.Y.Z`,
   confirm with the user first), and leave a one-line cross-link under
   "Released" below. If the milestone touched architecture, also update
   `memory/` and `docs/architecture/overview.md`. (Authoritative: root
   `CLAUDE.md` Definition of Done; `docs/CONSTRAINTS.md §三 C7/C8`.)

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`
- `v1.1.0` → `docs/release_1.1.0.md`
- `v1.2.0` → `docs/release_1.2.0.md`
- `v1.3.0` → `docs/release_1.3.0.md` (tag pending explicit confirmation)

## Unreleased

### 2026-08-05 — 泛化 Android 项目标识并修复 SO receipt/APK 基线

**Task**

修复 `<Space>us` 已生成 SO、但 `<Space>uq` 错报 `Android SO not found`，并阻止新 JNI SO 被注入不兼容的旧 APK。

**Implemented**

- `lua/ue.lua` `android_so_from_receipt` 校验 UBT `<Target>.target` 的 TargetName/Platform/Configuration，并解析 receipt 声明的真实 SO build product；兼容 UE4 实际输出的 `<Target>-arm64.so`，不按 mtime 或通配符猜配置。
- receipt 含多个 `.so` 时，仅接受名称匹配当前动态 Target、类型为 Executable 的唯一主产物；插件 SO 或歧义候选不会被部署到 `libUE4.so`。
- nested `.uproject`、Android packageInfo 和 DAP symbol package 发现改为动态 `Source/<Project>` / `<Target>_Symbols_v*` / `<Target>-arm64`，不再把现场项目名当协议。
- `scripts/ue_android_so_deploy.ps1` 在 strip/push 前比较源 SO 同目录 `packageInfo.txt` 与设备安装包的 package/versionCode；不匹配时要求先通过 `<Space>ui` 安装一次基线 APK。
- `scripts/ue_android_so_deploy.ps1` 用 .NET `SHA256.ComputeHash(Stream)` 替代环境相关的 `Get-FileHash` cmdlet，保持大 SO 流式计算且不要求额外 PowerShell module。
- 回归 fixture 统一改用虚构的非 `Client` 项目，并覆盖 matching receipt、插件 SO 排除、错误配置、nested 项目与 DAP 符号发现；同步两个主规格、架构说明与 K44/K45 坑位。

**Pitfalls / Gotchas**

- 当前 UE4 的 Development 产物使用配置中性 `<Target>-arm64.so`；配置身份必须读 `<Target>.target`，不能从通用文件名推测。
- 首次真机替换虽然通过 ELF/hash/metadata/maps，但旧 APK 缺少新 SO 所需的 Java 方法，触发 `NoSuchMethodError` → SIGABRT；自动回滚后原应用恢复运行。
- 安装 matching versionCode APK 后同一 SO 成功部署并持续运行，证明失败是 Java/JNI 基线不匹配而非 strip 或文件替换问题。

**Validation**

- 回归测试先以 47/48 精确复现 receipt 文件名缺陷；最终 `ue_api` 51/51、`dap` 55/55、`ue_context` 3/3 passed，包含非 `Client` 项目、插件 SO 排除和多主产物歧义拒绝。
- 不匹配 APK 基线实测在 strip/push 前拒绝；匹配 APK 后实机部署 exit 0，hash/metadata/PID/maps 全部通过。
- 移除 `Get-FileHash` 后以同一真机路径复验：exit 0，.NET 流式 SHA-256 与设备端 `sha256sum` 一致，应用启动并映射替换后的 `libUE4.so`。
- `openspec validate android-so-quick-deploy|android-dap-attach|ue-code-search --type spec --strict`：全部 valid。
- `nvim --headless -l tests/run.lua`：688/688 passed；PowerShell AST、敏感信息扫描与 `git diff --check` 通过。

**Follow-ups**

- 纯 C++ 改动可持续使用 `<Space>us` → `<Space>uq`；Java/JNI/manifest/Gradle 输入变化后必须先重新安装一次匹配 APK 基线。

### 2026-08-04 — 过滤 Windows fs_event 元数据洪水

**Task**

处理持久化性能探针中反复出现的 `dirty-set-flood/cap-hit`，避免 1000 条伪 dirty 路径拖慢每次 picker 搜索。

**Implemented**

- `lua/utils/ue_watch.lua` 缓存当前 `csearch.idx` 内容时间锚；Windows/libuv 的已有文件 `change` 仅在文件 LAST_WRITE 晚于索引时进入 `persistent_dirty`。
- rename/create/delete、无索引和缺失 mtime 证据的场景继续保守记录，避免把带旧 timestamp 的新文件误过滤。
- 全量 csearch 成功清空 dirty 时同步推进 anchor，防止构建期间排队的旧元数据通知立刻重新污染集合。
- `tests/cases/ue_watch_csearch_spec.lua` 新增旧/equal/newer mtime、rename 与无索引行为回归；`ue-code-search` 主规格和 K43 坑位同步。

**Pitfalls / Gotchas**

- libuv Windows backend 同时订阅 LAST_ACCESS/ATTRIBUTES/SECURITY/LAST_WRITE，但只向 Lua 暴露统一 `change`；仅检查“文件仍存在”无法判定内容是否真的变化。
- 现场 1000 条 dirty 中 960 条已存在于刚生成的 csearch snapshot，只有 9 条内容 mtime 晚于索引；旧实现把元数据扫描放大成 overlay 洪水。
- `csearch-smart-build/reset: no snapshot` 的最新记录来自项目切换后的首次构建；当前 `csearch.idx.files` 已存在且与索引同时完成，属于预期冷启动，不另改逻辑。

**Validation**

- `nvim --headless -l tests/run.lua ue_watch_csearch`：11/11 passed。
- 现场 1000 条 dirty 回放：保留 9 条真实新写入，过滤 991 条索引前元数据事件，耗时 43.529 ms。
- `nvim --headless -l tests/run.lua`：682/682 passed。
- `openspec validate ue-code-search --type spec --strict`：valid。

**Follow-ups**

- 修复加载后重新观察 `dirty-set-flood`；若仍有 cap-hit，按新证据区分真实批量源码变更与其他事件源。
