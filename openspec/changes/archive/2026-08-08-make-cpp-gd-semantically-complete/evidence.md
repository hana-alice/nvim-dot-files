## Android Vulkan derived virtual baseline

### Subject

- Active compile entry: Android Test CDB（由 compile arguments 中的 Android intermediate include、PCH 与 VulkanRHI definitions 交叉确认）。
- Call site: `Engine/Source/Runtime/VulkanRHI/Private/VulkanViewport.cpp:207`。
- Receiver static type: `FVulkanCommandListContext&`。
- Expression: `Context.RHISubmitCommandsHint()`。
- Derived override declaration: `VulkanContext.h:95`，`final override`。
- Out-of-line definition（当前 checkout）: `VulkanCommands.cpp:1098`。

所有输出均已移除绝对路径、project name 和本机标识。

### Experiment A: real libclang sidecar

对 call-site exact cursor 使用 CDB 中的真实 compile command，sidecar 返回：

```json
{"label":"android-vulkan-derived-virtual-call","state":"resolved","usr_hash":"f72e360eff924d67","target":"VulkanContext.h:95","query_kind":"cold","cold_parse_ms":7196,"diagnostics":0,"process_rss_bytes":1533788160}
{"label":"android-vulkan-derived-virtual-call","state":"resolved","usr_hash":"f72e360eff924d67","target":"VulkanContext.h:95","query_kind":"warm","diagnostics":0,"process_rss_bytes":1533812736}
```

证明：exact call 可稳定解析到派生类 override identity；当前 origin TU 只能提供其 declaration，warm query 正常复用。

### Experiment B: real clangd LSP

在同一 CDB、同一 exact cursor 下分别查询 call site 与派生 declaration：

```json
{"case":"call","symbol":"RHISubmitCommandsHint","container":"FVulkanCommandListContext::","usr_hash":"f72e360eff924d67","definition":[{"file":"VulkanContext.h","line":95}],"implementation":[]}
{"case":"declaration","symbol":"RHISubmitCommandsHint","container":"FVulkanCommandListContext::","usr_hash":"f72e360eff924d67","definition":[{"file":"VulkanContext.h","line":95}],"implementation":[]}
```

证明：clangd 与 libclang 对派生 override identity 完全一致，但调用点和 declaration 的
destination 都停在 header；实际存在的 `.cpp` body 没有进入结果。这里曾把“缺少 definition
TU shard”列为待验证解释，后续 Experiment C 已证明它不足以解释全部现象：即使 indexer
产物明确记录 `.cpp` Definition，External.File 的 LSP definition 仍可只返回 declaration。

### Experiment C: falsification and controlled coverage

- `clangd-indexer` YAML 能看到目标 USR 的 `.cpp` `Definition` location；转换为 monolithic
  binary External index 后，真实 clangd LSP 仍只返回 header declaration。因此
  `External.File` / `--index-file` 不能作为 body authority。
- 人工跨 module super-unity 与把不同 compile context 强行并入同一 TU 都产生真实 Clang
  diagnostics；该路线被拒绝，不进入实现。
- compiler-authored UBT unity wrapper 使用其匹配 `.o.rsp` 做 `clangd --check` 为 0 error。
  current 构建的 31 个 Vulkan 源命令可由 4 个真实 wrapper 完整覆盖；生成器为 31/31
  成员写入 portable membership/module-root metadata，且不修改输入 CDB。
- 小型真实 clangd fixture 以 `--enable-config=false` + official
  `compilationDatabaseChanges` 验证 controlled BackgroundIndex 能提供跨 TU body；generation
  selector 回归证明同 generation 的 current/hot 不会降级已有 full。

### Experiment D: post-implementation Android Vulkan smoke

最终 smoke 只读消费 active Android CDB 与上述 4 个受控 wrapper，通过 libclang exact cursor
取得 canonical USR，再通过同一进程、同一 toolchain 的 C ABI cursor shim 在 module AST 中
按 exact USR 查 body。输出只保留 label、USR hash、basename/line 与性能指标：

| Case | USR hash | Destination | First lookup | Same-USR next subject |
|---|---|---|---:|---:|
| two-arg call | `5d67a4354da68a7b` | `VulkanCommandBuffer.cpp:645` | 30.7s | declaration 0ms |
| no-arg declaration | `65ed3e51ef6f4162` | `VulkanCommandBuffer.h:421` | 29.2s | call 0ms |
| derived virtual call | `f72e360eff924d67` | `VulkanCommands.cpp:1098` | 30.0s | derived declaration 0ms |

六用例全部 PASS，三个 identity 互异，call/declaration pair 内 identity 完全相同；derived
receiver 没有被折叠成 base method。每个首次结果均报告 cursor shim ABI 1，重复 identical
request 与同 canonical USR 的另一个 subject 都命中 resolved-only cache。默认 `max_tus=1`，
全程 `tu_count=1`；sidecar RSS 为 1797–1818 MiB。没有用并发 TU 换取冷路径速度。
引擎/项目源码未被写入，设备未访问。

### Acceptance consequence

该病例不得通过 name、base-class walk 或 arbitrary implementation picker 修复。验收必须证明：

1. exact expression 仍产生相同的派生 override identity；
2. compatible controlled module contexts 可见时，`gd` 直接到 `VulkanCommands.cpp` definition；
3. module/index partial 或 unready 时输出明确 coverage reason，不能宣称 virtual dispatch ambiguous，也不能退到 base method；
4. 对 base-typed、dynamic type 不可证明的 call，系统不猜派生 override。
