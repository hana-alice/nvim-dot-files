## MODIFIED Requirements

### Requirement: derived CDB 必须保留 active command 的编译语义

full/current/hot 生成器 SHALL 只消费当前 active argv 明确引用且可验证的编译输入，MUST NOT 从源码路径猜测其他 target/platform/configuration 的 response、Definitions 或 UHT include。不能证明兼容时 SHALL 保留 exact command 或明确失败，不得把混合上下文作为 ready 产物发布。

#### Scenario: Android 与 Win64 Editor 中间产物共存
- **WHEN** active CDB 属于 Android，而磁盘还存在 Win64 Editor 的 response/Definitions/UHT
- **THEN** production default full pipeline SHALL 保留 Android 的语义 argv
- **AND** MUST NOT 注入 Editor 宏或 include 路径

#### Scenario: controlled CDB 显式依赖 Definitions 或 PCH
- **WHEN** active argv 明确引用 Definitions header 或 PCH
- **THEN** controlled Full/current pipeline SHALL 验证该显式文件存在，并保留原 argv 的条件宏与 PCH 语义
- **AND** 文件缺失 SHALL 返回失败且不发布 ready marker；不能用邻近 Editor 文件补齐

#### Scenario: PCH recipe has been generated but no binary was built
- **WHEN** `tools/prebuild_pch_v2.py` 只生成 response/batch 配方，未执行并验证 PCH 编译
- **THEN** 它 MUST NOT 将预期的 binary PCH 路径写入 active CDB；原文本 include 或原生编译参数 SHALL 保留
- **AND** 修复历史污染时，只允许移除本生成器路径、已存在的匹配 recipe 与相邻原文本 include 共同证明的缺失 binary 引用；外部或 binary-only PCH MUST 保持严格校验

#### Scenario: unity response 与 active command 矛盾
- **WHEN** response 的宏、include、target、语言或 PCH 与 active command 不同
- **THEN** unity 证明 SHALL 被拒绝，并使用 exact-command fallback
- **AND** 比较 MAY 忽略仅影响输出位置的参数和规范化后的 source 占位
- **AND** 已验证匹配的语义输入 MUST NOT 在最终 argv 中再次被删除

#### Scenario: 显式响应文件无法完整展开
- **WHEN** active argv 的 response 文件缺失或循环引用
- **THEN** 展开阶段 SHALL 保留整个原始 command，而不能发布部分展开的混合 argv

### Requirement: Prepare SHALL deliver a usable semantic index without extra user commands

`UEPrepare` 的完成语义 SHALL 覆盖 controlled index 的就绪状态。用户完成
`set platform → set project → build → UEPrepare` 后，SHALL NOT 需要额外记忆或执行任何平台专属
索引命令（如 `UEIndexFull`）才能获得可用的 C++ 定义跳转。

`UEIndexNow` / `UEIndexHot` / `UEIndexFull` SHALL 仅作为显式重建入口保留，MUST NOT 成为日常
流程的必要步骤。

当 prepare 完成而 index 尚未就绪时，系统 SHALL 明确告知当前处于 index 构建中或构建失败，
MUST NOT 让用户以为语义能力已可用。

#### Scenario: Habitual prepare flow yields working definition navigation
- **WHEN** 用户依次执行设置 platform、设置 project、构建、`UEPrepare`，且各步成功
- **THEN** controlled index SHALL 被构建并交付（manifest + selection + 提升后的 semantic CDB）
- **AND** 随后对已证明唯一定义的 C++ 符号执行 `gd` SHALL 到达该定义
- **AND** 流程 MUST NOT 要求用户执行 `UEIndexFull` 或其他索引命令

#### Scenario: Cold asynchronous prepare finishes before semantic delivery
- **WHEN** 首次异步 prepare 的 csearch 与 CDB pipeline 均已完成，且 CDB pipeline 成功
- **THEN** 完成分支 SHALL 调用受保护的 `schedule_prepare_delivery` 后再尝试唤醒 clangd
- **AND** CDB 尚未完成时 SHALL 等待，CDB 失败时 MUST NOT 调度交付或唤醒 clangd

#### Scenario: Prepare completes while index build is still running
- **WHEN** prepare 的 CDB 阶段完成但 controlled index 仍在构建
- **THEN** 系统 SHALL 通过进度指示表明 index 构建进行中
- **AND** 状态查询 SHALL 报告 index 尚未就绪，而不是报告 prepare 已整体完成
