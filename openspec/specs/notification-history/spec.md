# notification-history Specification

## Purpose

定义本 Neovim 配置中用户可见通知、报错和关键反馈的可回看历史行为，并约束记录内容、容量、查看入口与安装结果摘要，使短暂 UI 消息在后续诊断中仍有可靠证据。

## Requirements

### Requirement: 通知历史记录
系统 SHALL 记录本配置层发出的用户可见通知历史，记录至少包含时间、等级、来源和消息正文，并重点覆盖用户触发命令产生的反馈。

#### Scenario: 记录受控通知
- **WHEN** 配置代码通过通知历史模块或受控日志通知 helper 发出一条 INFO/WARN/ERROR 提示
- **THEN** 系统 SHALL 在通知历史中追加一条包含时间、等级、来源和消息正文的记录

#### Scenario: 记录用户触发命令反馈
- **WHEN** 用户执行本配置提供的命令或快捷键且该动作产生成功、警告、错误或关键状态提示
- **THEN** 系统 SHALL 通过通知历史记录该提示，除非该提示被明确归类为低价值瞬时提示

#### Scenario: 历史容量受限
- **WHEN** 通知历史记录数量超过实现定义的上限
- **THEN** 系统 SHALL 丢弃最旧记录并保留最新记录

### Requirement: 通知历史查看入口
系统 SHALL 提供用户可调用的入口查看最近通知、报错和信息提示历史。

#### Scenario: 打开历史视图
- **WHEN** 用户执行通知历史查看命令
- **THEN** 系统 SHALL 打开一个只读历史视图，按最近优先展示记录

#### Scenario: 历史为空
- **WHEN** 用户执行通知历史查看命令且当前没有记录
- **THEN** 系统 SHALL 展示空状态，而不是报错

#### Scenario: 清空历史
- **WHEN** 用户执行通知历史清空命令
- **THEN** 系统 SHALL 清空内存中的通知历史记录

### Requirement: Android 安装结果可回看
系统 SHALL 在 Android APK 安装流程中记录可回看的安装生命周期摘要。

#### Scenario: Android 安装开始
- **WHEN** 用户执行 `:UEInstallAndroid` 且系统找到待安装 APK 并启动 `adb install`
- **THEN** 通知历史 SHALL 记录一条安装开始记录，包含 APK 文件名或可识别摘要

#### Scenario: Android 安装成功
- **WHEN** `adb install` 以 exit code 0 结束
- **THEN** 通知历史 SHALL 记录一条安装成功记录，使用户能回看安装已成功

#### Scenario: Android 安装失败
- **WHEN** `adb install` 以非 0 exit code 结束
- **THEN** 通知历史 SHALL 记录一条安装失败记录，包含 exit code、精选错误摘要和可用时的修复 hint

#### Scenario: Android 安装失败详情仍落盘
- **WHEN** Android 安装失败并产生 stdout 或 stderr
- **THEN** 系统 SHALL 继续把完整输出写入 `:NvimLog`
- **AND** 通知历史 SHALL 只保存适合 UI 展示的摘要并提示用户查看 `:NvimLog`

### Requirement: 新增提示默认可回看
系统 SHALL 要求新增的用户触发提示默认进入通知历史，避免继续产生不可回看的短暂反馈路径。

#### Scenario: 新增用户命令提示
- **WHEN** 后续实现新增或修改一个用户触发命令，并需要向用户展示结果、警告或错误
- **THEN** 该实现 SHALL 使用历史感知通知 helper 或显式记录到通知历史

#### Scenario: 低价值提示例外
- **WHEN** 某个提示只是频繁、瞬时、无决策价值的低价值状态刷新
- **THEN** 实现 MAY 不记录该提示
- **AND** 该例外 MUST NOT 影响成功/失败/错误/用户下一步行动类提示的可回看性
