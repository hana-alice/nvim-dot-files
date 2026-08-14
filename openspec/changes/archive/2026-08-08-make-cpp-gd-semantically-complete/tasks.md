## 1. 先锁定旧实现会失败的行为

- [x] 1.1 在 `ue_goto_behavior` 中把“definition 只返回原 declaration 时保持原地”改成 declaration 上必须继续解析跨 TU definition，并分别覆盖 reference→definition、reference→declaration→definition、already-at-definition。
- [x] 1.2 为 immutable request snapshot 增加回归：请求建立后切 buffer/窗口/光标，发给 provider 的 URI/position 仍来自原 snapshot，返回结果不得产生 stale side effect。
- [x] 1.3 为 header context 增加回归：同窗口从 source 进入 header A 后直接打开不属于该 TU 的 header B，旧 lineage 必须失效并重新 catalog。
- [x] 1.4 建立真实 clangd controlled BackgroundIndex fixture，证明 exact-command transport、full body reachability 与 partial/full generation gate；保留 External.File 不能兑现 body 的反证。
- [x] 1.5 扩展脱敏真实 UE smoke：除 `SubmitActiveCmdBuffer` 二参数/无参/declaration→definition 外，加入 active Android CDB 中 `FVulkanCommandListContext& Context` 调用 `RHISubmitCommandsHint()` 的派生 `final override`；断言 exact USR 属于派生类且最终落到 `VulkanCommands.cpp` body，记录旧行为只停 `VulkanContext.h` declaration 的证据。

## 2. 建立索引 generation 与覆盖单调性

- [x] 2.1 为 current/hot/full artifact 写入并读取 generation manifest：build key、normalized CDB digest、toolchain identity、CDB hash、module-set hash、coverage level 与完成时间。
- [x] 2.2 实现纯函数式 active index selector，仅允许同 generation 的覆盖超集晋升；用乱序 phase completion、同级重建与新 generation 切换测试证明确定性。
- [x] 2.3 修改 index promotion，使同 generation 的 current/hot 不再覆盖已有 full controlled baseline；没有 full 时只挂载当前最宽 partial artifact。
- [x] 2.4 让 clangd restart 只跟随 chosen controlled manifest fingerprint 变化；固定 `--enable-config=false` 并删除 `.clangd`/`--index-file` authority，未被选择的窄 artifact 完成不得重启或降级 active coverage。
- [x] 2.5 为 dirty module/live buffer 增加 freshness 判定：exact-command/unsaved overlay 优先于静态 baseline，无法证明新鲜的 cross-TU destination 返回 `index-stale-for-module`。
- [x] 2.6 在 index status 中暴露脱敏 generation、coverage level、module/TU 摘要、freshness、chosen base 与 partial/full 收敛状态。

## 3. 引入统一 Semantic Transaction

- [x] 3.1 新增 headless-testable transaction/coordinator 模块，定义不可变 subject/build/context/entity/index/result evidence 数据结构和一次且仅一次 terminal callback。
- [x] 3.2 将 LSP params 改为从 snapshot 指定的 bufnr/URI/position/document version 构造，不再在 provider dispatch 时读取当前窗口。
- [x] 3.3 将 clangd `symbolInfo`/`definition` provider 改为 structured result，保留 client id、capability、USR/opaque id、error、timeout、locations 与 elapsed，不再把所有失败折叠为 `nil`。
- [x] 3.4 扩展 sidecar query response，返回 compiler-owned entity/cursor role、canonical identity、declaration/definition 与 per-context diagnostics，并按 canonical identity 聚合而不是把 declaration 展示位置混入 identity key。
- [x] 3.5 为 transaction 实现固定 `stage`/`reason` 枚举与协议验证，保持四个公开 terminal state，并测试 malformed/unsupported/timeout/conflict/multiple/stale 分支。

## 4. 修复 header context 生命周期

- [x] 4.1 用 lineage record 取代裸 window origin，绑定 generation、source action、origin TU、dependency evidence fingerprint 与 subject-header membership。
- [x] 4.2 只有 membership 已证明时才继承 header context；`query-file-not-in-tu` 必须撤销旧证据并在同一 snapshot 下最多重新 catalog 一次。
- [x] 4.3 保持 direct-open header 的 proven-context catalog 与多 context 显式选择，验证选择只作用于当前 lineage 且 build/generation 变化后失效。
- [x] 4.4 汇总所有 context 的 unresolved evidence，不能再只用第一个 context 的 state/reason/diagnostics 代表全部失败。

## 5. 完成 canonical entity 到 definition 的路由

- [x] 5.1 将 source 路径接入 coordinator：exact active CDB proof、proven-TU libclang identity、同 generation module definition lookup 与 stale/generation 门禁。
- [x] 5.2 将 header 路径接入 coordinator：proven origin TU 的 libclang identity/in-TU destination、同 USR module AST destination，以及 module contexts 暂不可用时 identity-verified clangd secondary destination。
- [x] 5.3 实现 role-driven 行为：reference/call→selected entity definition、declaration→definition、definition→`already-at-definition`；静态语义明确选中 derived virtual override 时保持该 override identity，base-typed 动态目标不明时不得猜派生类；partial coverage 下可落同一 declaration，但不得把它当下一次 `gd` 的终点。
- [x] 5.4 对 identity conflict、provider capability failure、partial index miss、complete index miss 与 multiple definitions 分别返回规范 reason，删除 generic `invalid-semantic-context` 混报。
- [x] 5.5 删除 `lsp_fallback.lua` 中旧的 header/source destination callback 决策、声明原地终止分支及不再使用的 C++ location/cache glue，确认非 C++ 路径行为和测试不变。

## 6. 建立 explain、探针与性能门禁

- [x] 6.1 实现最近一次 C++ `gd` 的有界脱敏 explain record 与用户命令，展示 snapshot、context、identity、provider、index coverage、destination filtering、terminal stage/reason 与 elapsed。
- [x] 6.2 为失败类 `stage/reason/generation-class` 增加去重 probe，为 cold/warm/index-wait/TU count/RSS 增加性能 probe，并遵守现有 TTL/cap/pcall/no-notify 合同。
- [x] 6.3 验证 `gd` 入口异步归还 UI，150ms 后才显示可取消 progress；取消、新请求与 generation 切换均能关闭进度且不泄漏 callback/timer。
- [x] 6.4 验证 warm transaction 不创建新 TU/进程、不重读全 CDB，LRU/idle eviction 使 TU count 与 RSS 随配置上限有界。

## 7. 完成语义一致性矩阵与交付门禁

- [x] 7.1 扩展真实 libclang fixture，覆盖 overload、derived-static-receiver/base-static-receiver virtual call、constructor/destructor、type/alias、field/variable、enum member、namespace alias、macro、template specialization、operator 及适用的 reference/declaration/inline/out-of-line role。
- [x] 7.2 扩展真实 clangd controlled BackgroundIndex + module AST E2E，覆盖 full→current/hot 覆盖不降级、partial/complete miss、dirty overlay、CDB/generation 签名切换与 restart gate；External.File 只保留为反证。
- [x] 7.3 在可用 UE checkout 上运行脱敏 `SubmitActiveCmdBuffer` 与 Android Vulkan derived virtual smoke，分别证明 overload identity 不串线、declaration 能继续到 `.cpp` body、派生 receiver 的 selected override 不被折叠为 base method；把命令、generation 摘要和结果写入 change evidence。
- [x] 7.4 按 `tests/AGENTS.md` 映射运行 semantic/index 相关 filters，随后运行全量 `nvim --headless -l tests/run.lua`，修复到全绿。
- [x] 7.5 更新 `docs/changelog.md`、symbol-resolution/index 架构文档与相关本地规则，记录删除的旧合同、实测性能、已知边界和完整 Validation。
- [x] 7.6 运行 `openspec validate make-cpp-gd-semantically-complete --strict`，复核无 engine/project 源码修改、无文本 fallback、无未脱敏路径，并使 change 就绪可供后续 sync/archive。
