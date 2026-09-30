## Why

成功 prepare 后 C++ 跳转仍可能因未交付索引、错误 provider 分类、未生成 PCH 输入或错误实体角色判断而失败。
本 change 补录本线程已完成修复与主动审计，保留尚未解决的真实索引缺口。

## What Changes

- 成功 cold prepare 调度语义交付；区分 provider 未挂载与方法不支持。
- PCH 配方不发布不存在的 binary 输入，仅修复有充分生成器证据的历史污染。
- 跨 TU 函数定义通过目标 exact command、同一 client 和 USR 验证。
- 宏、alias、namespace 按 compiler referent 关联；保留声明角色、取消和多 client 证据边界。
- 主动检查真实文件 312 个去重符号位置，记录残余问题与回归证据。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `cpp-contextual-definition-navigation`：provider、目标身份、实体角色与 definition-self 语义。
- `cpp-semantic-index-coverage`：cold prepare 交付和 PCH 输入真实性。

## Impact

涉及 `lua/utils/ue_goto/`、`lua/ue.lua` 的一个交付调用、PCH 配方工具及对应回归。
不包含工作区中另行进行的分布式构建、package 文件或真实项目输入。
