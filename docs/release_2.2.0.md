# hana-alice/nvim 2.2.0 — 可审阅修改、工作恢复与可信运行反馈

> 版本：2.2.0
> 仓库：https://github.com/hana-alice/nvim-dot-files
> 日期：2026-10-03
> 类型：Minor；新增重构预览、文本恢复、命名运行配置与 UE 工具入口。
> 发布流程：本地实施、required-native 门禁与文档归档完成；提交/推送按 2026-10-04 收尾授权执行，tag 待明确请求。

## 0. 一句话概括

让日常编辑、跨文件修改、构建调试和返回工作现场形成可检查、可取消、保护新输入的流程。

## 1. 已实现的交付范围

- 后台构建和问题列表保留编辑焦点；首错跳转可一次 Ctrl-O 返回。阶段日志有界保留，任务展示真实可取得的退出码。
- 运行一次捕获项目/目标/配置/设备/包名；阶段 owner 拒绝取消和旧回调，最后成功等待实际 launch/attach 回应。
- 调试窗口按 session/tab 所有权清理，恢复未被用户改变的分屏、阅读点；logcat 在筛选、暂停/跟随和停止后保留历史。
- 命名运行配置按项目独立原子保存，显式预览差异与应用；设备 serial 不跨会话保存。
- 实际 LSP rename/code action 使用多文件预览、完整预检、保护回滚、批次撤销和可见恢复证据，不自动保存。
- 重启先检查未保存；大 session 可按需打开；崩溃文本以异步独立快照恢复为新未命名缓冲区。
- 12 条审校 UE 片段与普通 C++ 共存；UE 类创建限制到现有模块；Editor 测试有显式发现/运行/失败重跑入口。
- Hub 标明缺项和当前 client 的能力，复用原选择器；手册、速查表及架构归属同步。

## 2. 验证与未完成范围

最终 required-native 全量 **2692/2692，0 failed，0 skipped，exit 0**。
可重复的分层证据、反例修正、变更模块及性能范围见
[IDE 实施验收](ide-experience-validation.md)。用户操作见 [使用手册](USER_GUIDE.md)。

本版本不代表全工程索引性能恢复；没有以时间戳或 Git 状态开启 UBT 跳过。
所选 Android 设备已验证同 BuildId 的真实 attach、空 FString/数组、非零 FName 索引与 NULL UObject；
易读名称、非空数据、typed variables/GUI，以及实际 Editor 测试发现/执行、Actor/Component
全工程编译和 Blueprint 桥接仍未完成。
不添加依赖、不安装工具、不改变 SuperUnity 二次压缩/覆盖规则。

## 3. 本次工作归档

### 2026-10-03 — 让修改、运行与恢复保护用户正在做的工作

**Task**

执行已批准的 IDE 体验规划，分别验收原生交互、真实编译器、工程和设备，保留 SuperUnity 性能底线。

**Implemented**

- `lua/ue.lua` / `build_diagnostics.lua` / `bottom_panel.lua` 保留后台构建编辑现场、阶段日志与首错返回；`task_registry.lua` 展示真实可取得的退出码。
- Android `iterate` / `deploy` / `launch` 冻结一次运行的选择，取消和旧回调按 owner 隔离，成功等待实际 launch/attach 回应。
- DAP `_layout.lua` / `_log_view.lua` / `_operation.lua` 保护跨 tab 分屏和阅读点，筛选不重启 reader，停止后仍可回看有界日志。
- `refactor.lua` / `workspace_edit.lua` 提供编译器修改预览、过期拒绝、保护回滚与批次撤销；`refactor_command.lua` 拒绝取消后晚到的 applyEdit。
- `edit_recovery.lua` 异步保存独立快照，恢复只创建新 buffer；`session_restore.lua` 按需恢复大 session；`restart.lua` 先处理未保存再启动实例。
- `run_profiles.lua` / `project_state.lua` 提供项目隔离的命名配置与共享字段 ownership 验证；相同 tuple 不触发 setter，无法证明 ownership 时拒绝 target 回滚。
- `ue_hub.lua`、`blink.lua`、`snippets/unreal.json`、`ue_entities.lua`、`editor_tests.lua` 接通能力引导、12 条审校片段、已有模块类预览和显式 Editor 测试入口。
- 同步手册、速查、架构归属、知识库与回归映射；记录 editor behavior、task management、host driver 与 multi-instance spec 的重要选型。

**Pitfalls / Gotchas**

- 原生确认仍处理事件，动作/批次/目标跨等待必须保留同一 owner；取消后的 command response 不得回到默认自动应用。
- 共享字段回滚需要真实 receipt/CAS；相同值的 ABA 与跨 PID 写入不能只比较值。target tuple 无 receipt 时保留新状态并要求人工检查。
- 恢复发现按当前项目寻址、预算前排除 closed/live、优先最近 session；达到扫描上限明确提示受限，保留未扫描快照。
- 原有 overflow 回归改用持久化 marker 时间测试等号边界，避免同秒假设跨墙钟秒失败；没有修改 watcher 行为。
- 所选 Android 设备同 BuildId 实测确认 cached-app freezer 前置条件；成功 attach 和 raw 值不等于易读类型或 GUI 验收。

**Validation**

- 最终 required-native 全量 **2692/2692，0 failed，0 skipped，exit 0**，包含恢复发现补强的两条用例。
- 独立重构 30/30、运行配置 22/22、workflow 20/20、文本恢复 17/17；命令 141/141、host spawn 13/13。
- 修改/新增 51 个 Lua 文件 AST lint、新文件与修改范围格式检查通过；最终排版用 StyLua `--verify` 核验 AST 等价。
- 排版后 `ide_` 190/190、最终文档 `structure` 78/78，required-native 零失败/跳过；本地私有 denylist 与通用 secret 扫描 exit 0。
- 真实 Blink、RPC UI、UE clangd、UObject UHT 与 Android 真机限定样本及反例修正见 [实施验收](ide-experience-validation.md)。

**Follow-ups**

- 全工程索引/重复 prepare 性能、可靠 UBT 跳过、UE 类型易读显示、真实 Editor discovery/run、Actor/Component 编译及 Blueprint 桥接仍未完成。
- v2.2.0 本地归档完成，提交/推送按收尾授权执行；版本 tag 仍待明确请求。

### 2026-10-04 — 完成 IDE 改动的公开镜像收尾

**Task**

按当前授权，脱敏后同步说明、核对归档、提交并推送本批 IDE 改动。

**Implemented**

- `docs/USER_GUIDE.md`、`docs/ide-experience-validation.md`、`docs/release_2.2.0.md` 将实机代称泛化为通用 Android 设备描述，保持真实验证数据与未完成范围。
- 核对四份已修改主规格与实现/知识库/归档的一致性；当前无活跃 OpenSpec change，沿用直接更新主规格的既有流程。
- 原始协议、日志、设备和私有工程上下文继续留在忽略目录；本次仅向当前已批准的公开分支交付。

**Pitfalls / Gotchas**

- 隐私扫描独立于回归，提交、ref 更新和推送的原生 hooks 保持启用；commit message 同样检查。
- 不把 UI/原生回归全绿写为 UE 类型、Editor、完整工程编译或全量索引性能已验收。

**Validation**

- 独立只读审查覆盖本批 67 个修改/新增文件，无脱敏阻断项。
- 四份主 spec 严格校验、51 个 Lua 文件 AST、新 Lua 文件 StyLua 检查与 diff check 通过。
- 提交前 required-native 全量 **2692/2692，0 failed，0 skipped，exit 0**；工作区与提交说明的私有 denylist 和通用 secret 预检 exit 0。

**Follow-ups**

- 原有 UE 类型、真实 Editor 测试、Actor/Component 编译、Blueprint 与完整索引性能验收继续保留。
- 版本 tag 仍待明确请求。
