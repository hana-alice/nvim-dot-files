# notification-history Specification

## Purpose

定义本 Neovim 配置中用户可见通知、报错和关键反馈的可回看历史行为：记录内容、容量、查看
入口与安装结果摘要，使短暂 UI 消息在后续诊断中仍有可靠证据。管边界：只管「配置层自己发出的
通知是否可回看」，不管通知的具体展示样式或第三方插件通知。

## Requirements

### Requirement: 通知历史记录

系统 SHALL 记录本配置层发出的用户可见通知历史，记录至少包含时间、等级、来源和消息正文，并
重点覆盖用户触发命令产生的反馈；历史容量超出实现定义上限时 SHALL 丢弃最旧记录并保留最新。

#### Scenario: 记录受控通知
- **WHEN** 配置代码通过通知历史模块或受控日志通知 helper 发出一条 INFO/WARN/ERROR 提示
- **THEN** 系统 SHALL 在通知历史中追加一条包含时间、等级、来源和消息正文的记录

### Requirement: 通知历史查看入口

系统 SHALL 提供用户可调用的入口查看最近通知历史；历史为空时 SHALL 展示空状态而不是报错；
用户可清空历史。

#### Scenario: 打开历史视图
- **WHEN** 用户执行通知历史查看命令
- **THEN** 系统 SHALL 打开一个只读历史视图，按最近优先展示记录

### Requirement: Android 安装结果可回看

系统 SHALL 在 Android APK 安装流程（`:UEInstallAndroid` / `adb install`）中记录可回看的安装
生命周期摘要（开始、成功、失败及 exit code），失败详情的完整 stdout/stderr SHALL 落盘到
`:NvimLog`，通知历史只保存适合 UI 展示的摘要并提示用户查看 `:NvimLog`。

#### Scenario: Android 安装失败
- **WHEN** `adb install` 以非 0 exit code 结束
- **THEN** 通知历史 SHALL 记录一条安装失败记录，包含 exit code、精选错误摘要和可用时的修复
  hint

### Requirement: 新增提示默认可回看

系统 SHALL 要求新增的用户触发提示默认进入通知历史，避免继续产生不可回看的短暂反馈路径；
只有频繁、瞬时、无决策价值的低价值状态刷新 MAY 例外，该例外 MUST NOT 影响
成功/失败/错误/用户下一步行动类提示的可回看性。

#### Scenario: 新增用户命令提示
- **WHEN** 后续实现新增或修改一个用户触发命令，并需要向用户展示结果、警告或错误
- **THEN** 该实现 SHALL 使用历史感知通知 helper 或显式记录到通知历史

## 选型与踩坑

- **选型**：通知历史保存在内存而非落盘，容量满后直接丢弃最旧记录——理由是这是「短暂 UI
  消息的回看窗口」，不是持久化审计日志；持久化诉求由 `:NvimLog`（Android 安装失败详情等）
  承担，两者职责分离。
- **重要事项**：「低价值瞬时提示」例外没有机器可判定的边界，依赖实现者判断；这是已知的
  主观判定缺口，不是设计遗漏。
