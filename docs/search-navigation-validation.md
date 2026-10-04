# 搜索、连续阅读与窗口找回验收（2026-10-04）

本批针对「找文件、查内容、读调用关系、关闭窗口后继续工作」的完整流程。
用户入口见 [使用手册](USER_GUIDE.md) 与 [速查表](ue_lazyvim_cheatsheet.md)。
实现基线为 `758815e`；本页区分真实工具、原生输入与受控回调实验。

## 已交付范围

| 使用场景 | 行为 | 主要归属 |
|---|---|---|
| `<C-w>q` 后找不到内容 | `<leader>wM` / `UEWorkspace` 按需列出跨 tab 窗口、隐藏 buffer、结果、任务和日志；先聚焦已有窗口，再恢复关闭的内容 | `utils/workspace.lua` |
| 保存结果后继续阅读 | Ctrl-Q 被动保存到原生 quickfix 历史；当前构建列表、焦点、侧栏和可见 quickfix view 保持 | `workspace.lua`、`search_recipe.lua` |
| 粘贴路径与分享位置 | 文件选择器接受引号、空格、正反斜杠和 `file:line:column`；列为 one-based UTF-8 byte；Ctrl-Y 复制位置、Alt-V 垂直分屏 | `file_query.lua`、Snacks 配置 |
| 搜索结果定位与反馈 | 可证明的命中保留真实 span；未知 span 明确行定位；区分等待、空结果、模式无效、截断、超时、索引不可用 | `code_search/location.lua`、`stream_reader.lua`、`search_ui.lua` |
| 收窄范围后继续查找 | Alt-D 选择范围，Alt-F 设置 include/exclude/扩展名；内容 query 与后置筛选分开；同 query 的模式变化也取消旧请求 | `search_picker.lua`、`search_controls.lua` |
| 恢复最近搜索 | 优先恢复实际最近一次 csearch 或 rg；历史保留完整模式、范围和有界筛选条件；锁内合并跨进程写入 | `search_recipe.lua`、`search_history_store.lua` |
| all-files 的首次与重复选择 | 独立异步文件清单，同一范围和参数保留相同文件集合；完成后进程内复用，F5 显式刷新 | `file_inventory.lua` |
| 阅读引用、header 和候选 | `gr`、`ch`、`UEPeek` 绑定同一源窗口、文档、项目与 client；唯一 Peek 也先预览，确认后跳转 | `ue_goto/reading*.lua` |
| 连续调查调用与继承关系 | `UERelations` 逐层按需请求，折叠/取消停止自身待处理请求，重复节点和受限结果可见；显式返回调查起点 | `ue_goto/relations.lua`、`reading_owner.lua` |

关闭窗口不停止任务；任务状态从现有 handle 查询，停止只作用于注册且允许停止的任务。
DAP 沿用自身 session 生命周期。恢复隐藏内容不覆盖未保存源码；底部内容继续复用每 tab 的既有 host。
历史本身和 quickfix 列表有界，不承诺已经淘汰的结果永久保留。

## 保留的约束与简化

- 不添加依赖；继续使用已安装的 Snacks、fd、rg、csearch、clangd 和 GLOBAL。
- 将 `ue.lua` 的搜索选择器实现移到独立 owner，旧 facade 与 helper seam 保留；抽取前后 `grep_cache`、`ue_api`、`ue_goto_behavior` 共 **192/192**。
- 合并两份搜索管道生命周期；去掉选择器的周期 watchdog，按原生 abort/error 与单次 deadline 停止本次请求；结果按有界批次交付。
- rg 复用实际 Snacks provider 生成的 argv 与 transform，保持原生匹配 span 和 glob 顺序；不增加第二份 rg 参数解析器。
- CPP 定义 Peek 复用 compiler identity 与 build context 证明；扩展名大小写不改变 authority。`gd` 不新增文本/GTAGS fallback；引用的 GTAGS 兼容结果标明来源和覆盖未知。
- 每次 indexed 请求都检查 `require_index`，打开 picker 后索引消失也不会隐式启动 rg。
- view 恢复限定在显式阅读返回和同步 pin 保存动作；没有全局 BufEnter cursor 守护。
- 文件清单不修改 csearch/GTAGS 的构建输入；本批不修改 CDB、prepare、SuperUnity 分组或索引发布机制。
- `ue.lua` 行数门禁从 10562 降到 9860；新增运行时模块沿用 800 行上限。

## 验证证据

最终 required-native 全量：**2835/2835，0 failed，0 skipped，exit 0**，包含 legacy jumper 旁路。
52 个改动源码/fixture 的 SHA256 在启动与完成之间一致，测试期间未换源码。
此前一轮因可选字段兼容失败为 2825/2832；修复与 fixture API 适配后重新跑完整门禁，未把失败轮算通过。

| 范围 | 已取得的证据 | 可证明的边界 |
|---|---|---|
| 搜索精度与状态 | `search_precision` 8/8、`search_state` 14/14；实际 cindex/csearch 和原生 child pipe 的 EOF、无换行 tail、cap、timeout、stop | 同一小型搜索 fixture 与 producer 生命周期 |
| 搜索原生交互 | Snacks 2.31.0，RPC UI 输入 12 阶段、180 次 grid flush；严格大小写最终 byte14，显示列15；中文前缀 byte21；全词 byte18；rg regex span byte7..14 | 真正列表渲染与确认坐标；80ms 受控回调延后用于 stale 分支，不是工程延迟 |
| 路径、历史与保存 | 14 组 RPC UI 交互，303 次 flush；6 种路径、3 种位置往返、Alt-V 保留 dirty 源、完整条件恢复、被动 pin；相关 5 filters 125/125 | 已安装 Snacks 的实际输入；剪贴板使用隔离 provider |
| 历史多 writer | 两个真实 Neovim PID，经 barrier 同时写入，共 240 次使用零丢失 | 锁内重新读取、合并与原子发布；不代表任意故障模型 |
| 文件清单 | `file_inventory` 12/12；13 个 all-files 冷热集合相同，含非代码类型；code 4 个；热查询无新增扫描，超预算仍显示完整 13 个 | 原生 fd 小范围 fixture；未实测大型工程 RSS/延迟 |
| 窗口找回与 pin | `ide_workspace` 14/14；RPC `nvim_input` 关闭再找回、两 tab quickfix 滚动、真实存活任务/终端、不干预外部进程 | 同进程窗口与现有任务生命周期；不是跨重启任务调度 |
| 状态线程边界 | `search_ui_status` 3/3，真实 uv timer fast-event 触发；新 query generation 拒绝晚到状态 | 主循环调度与 picker generation；不是像素验收 |
| GTAGS owner | `search_gtags_owner` 3/3，过期请求在 spawn、通知和 quickfix 等副作用之前被拒绝 | 受控 transport 与真实 Neovim buffer；实际 GLOBAL 另见导航实测 |
| 导航与关系 | 30 个原生场景通过；clangd 22.1.5、GLOBAL 6.6.12；source TU 的真实 symbolInfo/USR 与 definition；三层出向调用/基类/派生类；真实 GLOBAL 131 hits 与存活 child 取消；最后 scoped 组合加 responsiveness 共 569/569 | 一条真实 fixture CDB；UE discovery/readiness/prepare 接线使用 seam，不证明真实 UE ready、header 多 TU 或 sidecar；scoped 组合不是一次全量 |
| 完整任务回放 A11 | 复制位置→实际 files picker 粘贴/确认→references→另一 dirty 窗输入→UEReadCancel→恢复最近 `grep/middle`；最终 byte35、源/另一输入/qf ID 均保留；5 command API calls、1 确认、1 次文字输入/6 字符、1 复制/1 粘贴分开记录 | 同一 fixture 的连续流程；动作计数不代表独立使用者首次发现率或真实工程耗时 |
| Unicode 分享与显式返回 | 原生阅读 Ctrl-Y →本机 OS `+` clipboard→Ctrl-V 文件选择器→Enter，UTF-16 转 byte35，最终 `[7,35]`；两 tab/三 splits/manual fold30 的显式返回 view/fold 一致；新输入保留，主动改布局拒绝返回 | 小型实际 clangd fixture 与本机 clipboard 单次往返；没有物理 GUI 键盘验收 |
| Hub 搜索接线 | `ide_hub` 8/8，新增反例 7/8→8/8；独立实例截获实际 Snacks sg 的 code masks 与 directory fallback，缺 mapping 一次 WARN | 同名入口采用同一已注册映射，避免条件漂移 |
| 文档与结构 | `structure` 78/78、`cheatsheet` 202/202、`keymaps` 64/64；filter 映射与治理 spec 同步 | 文档链接、命令冻结与入口接线 |

可重复的仓内用例：

- [窗口与任务](../tests/cases/ide_workspace_spec.lua)、[独立文件清单](../tests/cases/file_inventory_spec.lua)。
- [搜索交互](../tests/cases/search_interaction_spec.lua)、[精度](../tests/cases/search_precision_spec.lua)、[状态](../tests/cases/search_state_spec.lua)、[原生 UI](../tests/cases/search_precision_ui_spec.lua)。
- [fast-event](../tests/cases/search_ui_status_spec.lua)、[GTAGS owner](../tests/cases/search_gtags_owner_spec.lua)、[连续阅读](../tests/cases/ue_goto_reading_spec.lua)、[关系展开](../tests/cases/ue_goto_relations_spec.lua)、[Hub 接线](../tests/cases/ide_hub_spec.lua)。
- 原生搜索回放入口为 [位置与筛选](../tests/fixtures/search_precision_ui.py)、[路径与完整条件](../tests/fixtures/search_interaction_native.py)。
- 原生连续阅读与完整旅程入口为 [导航回放](../tests/fixtures/navigation_native.py)，编译器/UE seam 分层在 [fixture](../tests/fixtures/navigation_native.lua) 顶部说明。

运行 `nvim --headless -l tests/run.lua`，最终编译器验收启用 `NVIM_TEST_REQUIRE_NATIVE=1`。
原始 RPC、协议和 fixture 工作路径留在忽略目录；公开文档只保留通用样本、版本和结果。

## 反例与修正留底

| 独立反例 | 原行为 | 修正与证据 |
|---|---|---|
| 原生 qf 历史已满且当前在最旧列表 | pin 可能淘汰当前构建列表 | 改为副作用前拒绝；十个列表 ID、内容、当前 ID 和布局保留；新反例由 red 到 green |
| quickfix 已滚到后部且跨两 tab 可见 | `chistory` 后 view 回到行首 | 同步捕获/恢复仍属于同 tab/window/buffer/current ID 的 view；实际滚动输入 red 到 green |
| 序列化 rg query 含原始 inline 参数 | 恢复入口绕过条件 allowlist | 拒绝危险原始参数和未知 schema；不执行被构造的外部程序；csearch 字面内容保持字面语义 |
| fast-event 写 picker title | uv 回调调用窗口 API 失败 | schedule 到主循环并重新验证 generation/closed；3 条回归 red 到 green |
| 折叠后再展开、关闭再恢复 | 旧关系请求仍待处理，或 loading 无法恢复 | 每 node 取消并清理待处理状态，展开只保留本次请求；受控 client seam 独立复验通过 |
| Snacks 把 UTF-16 location 改成 byte pos | 刷新树复用被修改的 loc，保存列错误 | 每次生成独立 loc/pos，provider opaque item 保留；真实 Snacks resolve_loc/native qf 独立复验通过 |
| CPP context chooser 获得焦点 | 被当成陌生窗口，owner 取消 | context chooser 归属当前操作，不放宽全局 focus 守卫；真实 Snacks 浮窗与 nvim_input 独立复验通过，不代表 header 多 TU proof |
| 确认过程中关闭 picker 触发编辑/新意图 | 检查完成后仍可能执行旧跳转 | close 后及最终切换前再次验证源、目标与 owner；受控 client seam 独立复验通过 |
| `.CPP` / `.H` 大写扩展名 | Peek 可能进入普通 LSP 路线 | 与既有 extension classifier 同源，保留 compiler proof；受控 compiler/client seam 独立复验通过 |
| 阅读列表的列协议 | 直接使用 Snacks file formatter，显示 byte0/未解析 UTF-16 列 | 接通共用 clone formatter；真实 resolve_loc char6→byte10，列表显示11，原 row/loc 不变；新增回归 34/35→35/35，独立复验通过 |
| owned context 关闭后的同位置 CursorMoved | scoped semantic 的 once autocmd 无条件取消，确认后异步 dispatch 失效 | scoped 操作仅在 snapshot 真变化时取消，并继续监听；实际 Snacks+nvim_input 确认后同位置有效、随后真实编辑失效，独立复验通过；普通 gd 原生浮窗仍失效 |
| 全量门禁的可选字段兼容 | 缺 picker title 与缺 provider 第三参数导致 7 条失败 | title 安全兜底，references 归一化缺省/legacy payload；旧异步用例完整保留，20/20；reading 新增三条为38/38，原生30重跑通过 |
| 查询生命周期的旧 fixture | 仍只模拟已撤掉的 watchdog，不支持 Async:on | 适配已安装 Snacks 的 abort/error 事件接口；原六条 padding/延后/最终 drain/停止/零晚到命中断言保留，另断无 polling timer；6/6，search_115/115、grep_cache36/36 |

索引状态、source provenance 和覆盖未知不会因为 producer 完成而变为完整工程覆盖。
零命中的措辞限定到已搜索范围，未知 csearch regex 列不伪装为精确命中。

## 预算与性能边界

| 数据 | 当前预算 |
|---|---|
| 被动 pin | 5000 rows、8 MiB 文本、8 KiB recipe；原生 qf 历史最多十份 |
| 条件历史 | 每项目 300 entries、2 MiB；schema/version/mode/source allowlist |
| include/exclude/type/root | 每类最多 16 条；glob 256、extension 32、root 4096 UTF-8 bytes |
| 文件清单 cache | 200000 paths、64 MiB 路径字符串 bytes、8 scopes 的进程内总预算；不是 RSS 上限 |
| 一次阅读列表 | 最多 1000 rows，超出时标明受限 |
| 按需关系 | 256 nodes、每次 128 children、16 层；实际原生展开样本与上限分别记录 |

文件缓存是显式 F5 刷新的完成快照。未完成、取消或失败的扫描不发布缓存；超预算保留完整显示而不缓存。
缓存和请求减少的 fixture 证据不能替代真实全工程耗时、CPU、内存、索引完成或重复 prepare 实测。

搜索核心局部 LuaLS 同配置比较：原 `init.lua` baseline 8 个 warning，当前 4 个；
新增 `location`、`stream_reader`、`picker` 为零。余项为既有 builder 的 nil 与 luv spawn 注解，
没有关闭诊断，没有宣称全仓 typecheck 全绿。五份主 spec strict 通过；49 个改动 Lua AST、
28 个新增 Lua StyLua、3 个 Python fixture AST 与 diff check 通过。
独立实现审查 APPROVED，增量修改经内存反向实验验证能重新触发原失败断言。
最终 66 个文件全文、author/committer metadata 与提交说明经本机私有 denylist 和通用 secret
扫描均 exit 0，独立公开审查无阻断；正常 pre-commit/ref/pre-push hooks 保持启用。

## 未完成事项

- 物理 GUI 的 DPI、字体/主题、Alt 键路由与 GPU 绘制未测；Linux 实机未测。OS 剪贴板仅取得本机 Unicode 单次往返证据；原生 RPC UI 通过不代替物理前端验收。
- 现有用户 GUI 的热重载未执行；本批运行验证来自隔离的新 Neovim 实例。
- 完整 UE 工程 all-files/search/调用树的耗时与 RSS、完整 SuperUnity 压缩与索引性能、重复 prepare 仍需现场验收。
- 真实 probe 三条历史复发计数未改变：provider/complete failures 6 对旧处置 3，identity-missing/complete 3 对 1，semantic-tu-unavailable/complete 3 对 2。原 subject 缺失，沿用 [前批处置理由](ide-experience-validation.md#report-first)，本批 fixture 不能关闭这些记录。
- 前批 UE 类型易读/非空变量显示、真实 Editor 测试发现/执行、Actor/Component 全工程编译、Blueprint 桥接及可靠 UBT 跳过继续保留。
- 本批提交、公开镜像推送与版本归档按既有授权执行；版本 tag 未获单独请求。
