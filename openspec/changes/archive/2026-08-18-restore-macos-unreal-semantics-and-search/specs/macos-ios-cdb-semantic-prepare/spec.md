## ADDED Requirements

### Requirement: clangd 启动必须绑定已解析工程的受控 CDB

MUST：clangd 命令必须在 LSP root 已解析后选择当前 project bucket 与 tuple 对应的 active
controlled CDB，并把 resolved argv 保留给 exact-command transport。不得在静态配置加载时把
CDB 固化到配置仓库或 engine root，也不得依赖原生 LSP 不执行的 legacy callback。

#### Scenario: 原生 LSP 为工程启动 clangd
- **WHEN** Neovim 原生 LSP 为一个已选择 project root 创建 clangd client
- **THEN** cmd factory 必须生成指向该 project-scoped active CDB 的 `--compile-commands-dir`
- **AND** exact-command transport 必须读取实际 resolved argv，而不是把 cmd factory 函数当作 argv

#### Scenario: CDB 只有 command 字段
- **WHEN** compiler-authored CDB entry 只提供 POSIX 或 Windows `command` 字符串
- **THEN** 受控 CDB 工具必须按该 command 的原始宿主语法转换为结构化 `arguments`
- **AND** 后续 definition 注入与 super-unity 处理不得通过重新拼接引号改变编译语义

### Requirement: Apple no-response super-unity SHALL require exact context proof

MUST：Apple toolchain 没有保留 `.o.rsp` 时，super-unity 只能复用 active CDB 中 compiler-authored
argv。一个 unity group 只有在所有 include member 都唯一映射、cwd 相同、剥离 source 与逐文件
写出参数后的编译上下文完全一致，并且 argv 含可验证 Apple target 或 SDK/sysroot 证据时才可合并。
系统不得合成 flags 的并集；任何证据不足都必须 exact per-file fallback。

#### Scenario: AppleClang 成员上下文完全一致
- **WHEN** IOS/Mac unity members 的 active CDB argv 具有相同 target、arch、sysroot、defines、includes 与 PCH 上下文
- **THEN** 系统必须从 exact argv 只替换原 source 并剥离对象/依赖写出参数
- **AND** wrapper argv 必须保留其余编译器语义参数

#### Scenario: 任一语义参数不同
- **WHEN** unity members 的 define、include、target、sysroot、PCH、cwd 或其他语义参数不同
- **THEN** 该 group 必须拒绝合并
- **AND** 每个 member 必须继续使用自己的 exact compile command

#### Scenario: 只有通用 arch 参数而无 Apple 证据
- **WHEN** CDB argv 含 `-arch`，但没有 Apple target 或 Apple SDK/sysroot 证据
- **THEN** 系统 MUST NOT 把它推断为 Apple compiler context
- **AND** no-response grouping 必须 exact fallback
