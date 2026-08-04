# hana-alice/nvim 1.3.0 — Minor Release

> Version: 1.3.0
> Repo:    https://github.com/hana-alice/nvim-dot-files
> Platform: Windows 11 + Neovide GUI (primary) / WSL2 (secondary)
> Date:    2026-08-04
> Type:    Minor release (Android SO inner loop, UEPrepare/CDB integrity, restrained C++ semantic hierarchy)

---

## One-line summary

Android C++ iteration now has a verified **SO-only build and root-device quick deploy** path that skips Gradle/APK assembly, matches normal APK strip output, atomically replaces `libUE4.so`, and automatically rolls back failed launches. This release also prevents concurrent CDB writers, narrows nested-project indexing, repairs csearch bootstrap behavior, and consolidates six C++ themes around a calmer mature-IDE semantic hierarchy.

## Release gate

- OpenSpec `android-so-quick-deploy` and `refine-cpp-semantic-visual-hierarchy` archived; their main specs pass strict validation.
- Full regression: `nvim --headless -l tests/run.lua` → **679/679 passed**.
- PowerShell parser: `ue_android_so_build.ps1` and `ue_android_so_deploy.ps1` both pass.
- Live SO-only build: 13.1 seconds, exit 0, final APK timestamp unchanged, no Gradle phase.
- Live root deploy after metadata hardening: 26.3 seconds; remote SHA-256, PID, captured metadata and `/proc/<pid>/maps` verified on USB serial `0123456789ABCDEF`.
- Gradle Debug, Gradle Release and quick-deploy stripped SO are byte-identical: 347,075,200 bytes, SHA-256 `831A32F2E89EE9AA84B79381C3646BA664EE981D19D7AA09B2FFB196092C5F5C`.
- Git tag `v1.3.0` is intentionally pending explicit user confirmation.

---

## Working log (sliced from docs/changelog.md Unreleased, newest first)

### 2026-08-04 — feat(android): SO-only 构建与真机快速部署

**Task** — 在不修改定制引擎或游戏项目源码的前提下，把 Android C++ 日常迭代从“编译 + Gradle 组包 + APK 安装”缩短为“编译/链接 SO + root 原子替换”。

**Implemented**

- `scripts/ue_android_so_build.ps1` 使用 UBT `-WriteOutdatedActions` + `-Mode=Execute -Actions=...` 两阶段，只执行 compile/link action graph。
- `lua/ue.lua` 注册 `:UEBuildAndroidSO`、`:UEDeployAndroidSO`；按当前 Target/Configuration 精确定位 arm64 SO，并复用会话全局 Android serial 与包名。
- `scripts/ue_android_so_deploy.ps1` 动态读取 `nativeLibraryDir`，对临时副本执行 `llvm-strip --strip-unneeded`，备份安装原版，恢复 owner/mode/SELinux context 后同目录原子替换。
- 部署后校验主机/设备 SHA-256、应用 PID、短期存活与 `/proc/<pid>/maps`；任何替换后失败自动回滚并重启原版。
- 新增小写 `<leader>us` / `<leader>uq`，同步 README、cheatsheet、AI context、命令冻结清单和回归测试。
- 新增并归档 OpenSpec `android-so-quick-deploy`。

**Pitfalls / Gotchas**

- `-SkipDeploy` 在当前定制引擎中会被 Android platform reset 覆盖，实测仍进入 Gradle；两阶段 action graph 是经过源码控制流和真实构建双重验证的替代方案。
- 同一设备同时以 USB/TCP serial 在线，所有设备操作必须显式使用 `adb -s <selected serial>`。
- PowerShell 5 把 `adb push` stderr 进度包装成 `NativeCommandError`，外部命令采集必须以真实 `$LASTEXITCODE` 为准。
- 快速部署只适用于 userdebug/root 设备；APK 重装会覆盖替换后的 SO。

**Validation**

- 专项回归：`ue_api` 47/47、`ue_cdb` 12/12、`csearch_build_guard` 21/21、`commands` 86/86、`keymaps` 52/52、`cheatsheet` 117/117、`ue_context` 3/3。
- 原始 SO 3,294,054,400 bytes；strip 后 347,075,200 bytes。Gradle Debug/Release 与 quick deploy hash 完全一致，strip 前后 GNU Build ID 均为 `004dafc47c09bcf31795f1673a0b2639d3081f6b`。
- 真机替换后目标为动态解析的 `/data/app/.../lib/arm64/libUE4.so`；脚本从安装文件捕获 `uid=1000`、`gid=1000`、mode `755`、context `u:object_r:apk_data_file:s0`，替换后逐项复查一致，远端 hash 和运行时映射也通过验证。

### 2026-08-03 — fix(ueprepare): 收敛重建、CDB 竞争与性能停顿

**Task** — 解释并修复 UEPrepare 看似每次重建 cindex、CDB JSON 随机损坏和 122 秒主线程 stall。

**Implemented**

- nested-project 默认扫描根锚定唯一 `Source/*/*.uproject` 目录，避免把 sibling config/SDK/generated data 纳入索引。
- `project_scan_roots` 成为缓存身份的一部分；扫描策略变化只触发一次有意重建。
- csearch `.files` 快照缺失时，仅在主索引可用且 canonical list 指纹一致时 bootstrap skip。
- `lua/ue/cdb/pipeline.lua` 增加单 writer 锁、失败回调和可靠释放；UEPrepare fast path 覆盖 async CDB + pipeline + partition 完整生命周期。
- 删除 clangd 已弃用的私有 `offsetEncoding` capability。

**Evidence**

- 旧 workspace list 701,778 行，其中 project 条目 565,648；新 nested roots 原始扫描输入为 121,702 文件。
- 两份重叠错误日志在两个不同 Python stage 解析同一 CDB 位置时报 `JSONDecodeError`，闭环到并发 writer 撕裂文件。
- 专项回归和全量回归全部通过。

### 2026-07-29 — feat(theme): 成熟 IDE 风格的 C++ 语义层级

**Task** — 将上一版八角色八色、大片粗斜体的 C/C++ semantic highlighting 收敛为更克制且可读的主题内角色族。

**Implemented**

- 六主题统一为 type/data/local/callable/macro 五个协调色族；允许 namespace/type、enum/field、parameter/local 的有意共享。
- 基础角色与 completion kind 只携带 foreground，不再强制 bold/italic。
- 中和 clangd declaration/definition、readonly/static/abstract/virtual、scope 等高优先级 modifier；deprecated 只保留 strikethrough。
- 调整应用顺序，使主题原生 Treesitter role 可作为精确 C/C++ profile 来源。
- 更新并归档 `refine-cpp-semantic-visual-hierarchy`，同步主规格和 theme/smoke tests。

### 2026-07-29 — docs(agent): 收敛规则读取范围

- SESSION START 在每个新 context 只执行一次。
- 只读取实际修改目录的最近本地规则和当前 change 直接相关 spec；提交前全量测试不等于预读全部文档。
- 影响面不明确或出现新证据时才扩大读取范围。

### 2026-07-29 — feat(theme): C++ 角色对比、Sonokai Espresso 与统一主题入口

**Implemented**

- 建立跨 Treesitter、clangd semantic token、Blink/nvim-cmp completion 的 C/C++ 角色一致性。
- 集成唯一公开入口 `sonokai-espresso`，每次加载固定 Espresso variant，禁用首次同步 syntax cache 的高延迟路径。
- 将主题入口收敛为六项：Monokai Ristretto、Rider Light、Ubuntu Terminal、Unokai、Catppuccin、Sonokai Espresso；删除历史 alias/variant 旁路。
- 主题与 probe 回归覆盖 canonical registry、持久化迁移、ColorScheme replay 和异步 probe 存储隔离。

---

## Compatibility and limits

- SO quick deploy requires Android root via `su 0`; normal user devices and production releases continue to use APK/Tinker workflows.
- The host unstripped SO remains the symbol source for LLDB/CrashSight. Device/APK SO intentionally contains only required dynamic symbols.
- The first UEPrepare after upgrading intentionally invalidates the old broad scan-root cache identity; later runs should use skip/add/reset based on actual file-set change.

## Files and ownership

- Android build/deploy orchestration: `lua/ue.lua`, `scripts/ue_android_so_build.ps1`, `scripts/ue_android_so_deploy.ps1`.
- CDB integrity and index scope: `lua/ue.lua`, `lua/ue/cdb/pipeline.lua`.
- Semantic hierarchy: `lua/highlights.lua`, `openspec/specs/cpp-semantic-highlighting/spec.md`.
- Persistent contracts: `openspec/specs/android-so-quick-deploy/spec.md`, `docs/architecture/overview.md`, `memory/project_overview.md`.
