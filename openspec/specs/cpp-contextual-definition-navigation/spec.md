# cpp-contextual-definition-navigation Specification

## Purpose

定义 C++ `gd` 在 UE 大型代码库中的上下文感知语义导航合同：只有真实编译 TU 中由
Clang 证明的实体身份（canonical USR / compiler-owned identity）可以驱动跳转。
边界：Tree-sitter、符号文本、receiver 文本、参数个数、workspace symbol、csearch、
GTAGS、文件距离与候选顺序 MUST NOT 选择、替换或否决 C++ 语义目标（P11/P12）；
显式搜索、`gr` references 与非 C++ 文件不受本契约约束，走独立的兼容链
（`docs/architecture-symbol-resolution.md` §6）。本 spec 只管跳转决策与其
异步/缓存/失败合同，不规定具体 UI 展现细节。

## Requirements

### Requirement: 跳转只接受编译器证明的语义身份

C++ `gd` SHALL 只接受当前 active build generation 下由 compiler-owned identity
关联的 declaration / definition destination。声明不能冒充定义；重载 SHALL 按
Clang 实体身份（USR）区分，不得以函数名、参数个数或渲染后签名作身份主键。
virtual call 若被静态证明选中派生 override，该 override SHALL 保持独立身份，
MUST NOT 被折叠成 base virtual identity。

#### Scenario: 唯一语义定义存在
- **WHEN** 用户在 active CDB 覆盖的位置触发 `gd`，语义系统证明唯一 canonical
  entity 与唯一 definition
- **THEN** 系统 SHALL 跳转到该 definition，且结果 SHALL NOT 被任何文本候选覆盖

### Requirement: Header 导航必须在已证明的 TU context 中求值，且以自动收敛为先

非自包含头文件被大量 TU include 是正常现象，MUST NOT 单独作为向用户提示选择的
理由。系统 SHALL 先尝试基于 compiler-emitted evidence（继承的 window origin
lineage、unity membership、候选求值后的 USR 一致性）自动收敛；只有候选求值后
确实产生不同实体或不同 definition 时才 SHALL 呈现选择，且展示 SHALL 说明分歧
内容，MUST NOT 仅列出 TU 文件名。收敛判据 MUST NOT 使用文件名相似度、路径距离
或候选返回顺序。

#### Scenario: 多个候选 TU 求值后一致
- **WHEN** 某头文件位置有多个候选 origin TU，在其中求值得到同一 canonical USR
  与同一 definition
- **THEN** 系统 SHALL 直接跳转，MUST NOT 提示用户选择 translation-unit context

### Requirement: 每次导航绑定不可变请求 snapshot，过期响应不得生效

每次导航 SHALL 建立不可变 request snapshot（action token、window/buffer、
subject URI、精确位置、document version、active build/CDB/index generation、
origin TU、compile-command fingerprint、provider client identity），并冻结
同一 action 使用的全部 unsaved overlays。异步阶段 MUST 使用该 snapshot 构造
请求，不得重新采样当前窗口位置或 overlay 集合。旧 generation、旧 document
version 或已取消 action 的响应 MUST NOT 产生跳转、通知覆盖或 lineage 变化。

#### Scenario: 请求发出后 buffer 或光标改变
- **WHEN** request snapshot 建立后用户切换 buffer 或移动光标，provider 请求
  尚未返回
- **THEN** provider params SHALL 仍对应原 snapshot
- **AND** 响应 MUST NOT 产生跳转、jumplist 或 context side effect

### Requirement: 导航终态必须显式且可解释

每次 `gd` SHALL 最终进入 `resolved`、`ambiguous-context`、
`invalid-semantic-context` 或 `unavailable` 之一，并附带稳定 `stage`/`reason`。
语义上下文根本不可用（index/generation 未就绪、无 proven TU、manifest 缺失）
时终态 MUST 为 `unavailable`，MUST NOT 归类为 `ambiguous-context`，也 MUST NOT
以候选列表（含 csearch/GTAGS/文本命中）代替诚实失败。系统 SHALL 为最近一次
`gd` 保存有界、脱敏的结构化 explain record（`UEDefExplain`），失败类 reason
SHALL 进入可迭代 probe feedback loop。

#### Scenario: 语义上下文不可用而非歧义
- **WHEN** controlled index 未就绪、无 proven TU context 或 manifest/selection
  缺失
- **THEN** 终态 SHALL 为 `unavailable` 并携带 readiness reason
- **AND** 系统 MUST NOT 返回 `ambiguous-context` 或呈现候选列表

### Requirement: 语义解析异步执行，复用 warm TU 并受资源上限约束

Clang 解析、TU 创建、reparse 与索引构建 SHALL 在 Neovim UI 主循环之外运行；
导航入口 SHALL 在 50ms 内归还 UI 控制权，超过 150ms 的活动请求 SHALL 显示可
取消进度。同一 snapshot/context 的暖查询 MUST NOT 重启完整编译器进程；TU 与
destination cache SHALL 受明确容量上限与 LRU 淘汰约束。每个 sidecar 请求
SHALL 有明确 host-side deadline；超时后 client SHALL 完成结构化失败并回收
仍卡在 native parse 中无法读取 cancel 的进程，不得让无响应进程永久阻塞后续
导航。

#### Scenario: libclang parse 超过请求期限
- **WHEN** sidecar 在 native parse 中超过配置的 request timeout 且无法处理
  协议 cancel
- **THEN** client SHALL 终止该 sidecar，并以 timeout/provider-unavailable
  完成请求
- **AND** pending map SHALL 清空，旧响应不得再产生跳转或状态覆盖

### Requirement: 实现不得修改引擎或项目源码

为头文件建立真实 TU 语义上下文的实现 SHALL 位于 Neovim 配置、其状态目录或
独立本地进程中，只读消费 build artifacts / compile database。系统 MUST NOT
修改 UE 引擎源码、项目源码，或为单个头文件注入持久化 source workaround。

#### Scenario: 头文件需要真实 include 顺序才能解析
- **WHEN** 头文件只有在真实 source TU 的 include 顺序与宏环境中才能完整解析
- **THEN** 系统 SHALL 在该真实 TU 中查询，MUST NOT 编辑头文件、`.cpp`、项目
  配置或提交 per-file forced-include 补丁

## 选型与踩坑

- **选型**：身份主键固定为 Clang canonical USR / compiler-owned identity，
  拒绝一切文本类启发式（符号名、receiver 文本、arity、渲染签名、文件距离、
  候选顺序）——理由见 P11/P12 与 `docs/architecture-symbol-resolution.md`
  §1；文本命中呈现为可选目标比诚实失败更有害。
- **选型**：header 多候选 TU 默认尝试自动收敛而非直接提示用户选择——「被
  很多 TU include」是正常现象，不是歧义；只有候选求值后**真正**产生不同实体
  才展示选择，且必须说明分歧内容而非只列 TU 文件名。
- **踩坑**：`SubmitActiveCmdBuffer` regression——同一无参 inline 重载体内嵌套
  调用一个双参数重载时，外层调用曾被错误折叠到无参重载或同 arity 的指针重载；
  现要求每次调用独立解析各自的 canonical identity，回归 fixture 覆盖二参数
  调用、无参 overload、header declaration 三步序列。
- **踩坑**：Android Vulkan `FVulkanCommandListContext::RHISubmitCommandsHint()`
  final override 曾被误判为 base RHI virtual method，跳到 `VulkanContext.h`
  的声明而非 `VulkanCommands.cpp` 的 out-of-line definition——派生 override
  的静态选中必须保持独立身份，不能被 base virtual identity 吸收。
- **重要事项**：sidecar 对同一 client/USR 共用 30 秒 provider hard ceiling
  以覆盖冷 UE preamble；TU 默认 LRU 容量为 1（可配置），30 秒无请求后 evict——
  实机 UE Android TU 可达数 GB working set。destination cache 独立 LRU，
  默认上限 128 项（`UE_SEMANTICD_MAX_LOOKUP_ENTRIES` 可配置）。NDJSON 帧大小
  上限 1 MiB，对完整帧与任意分块方式一致。
- **重要事项（工作区未提交改动，需保留）**：compiler destination 与已存在的
  目标 buffer 可能通过 symlink 或 canonical path alias 指向同一本地文件的
  不同路径拼写；destination 校验 SHALL 比较真实文件身份而非直接比较 provider
  URI 字符串，同时不同文件、被改动的目标 buffer、过期请求或不匹配的 USR 仍须
  被拒绝。
