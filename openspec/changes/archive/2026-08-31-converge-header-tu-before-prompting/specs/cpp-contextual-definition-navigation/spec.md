## ADDED Requirements

### Requirement: Header navigation SHALL converge on a TU before asking the user

非自包含头文件被**大量** TU include 是正常现象，不是歧义。因此"存在多个候选 origin TU"
MUST NOT 单独作为向用户提示选择的理由：它表示系统尚未决定用哪个 TU 求值，而不是该位置在不同
TU 中合法地指向不同实体。

多个候选 TU 时，系统 SHALL 先尝试基于 compiler-emitted evidence 自动收敛（继承的 window origin
lineage、subject 的 unity membership、以及在候选中求值后比较 canonical USR）。收敛 MUST NOT 依据
文件名相似度、路径距离、候选顺序或其他文本启发式选择 TU（P11/P12）。

若多个候选 TU 求值后得到**同一** canonical entity 与同一 definition destination，系统 SHALL 直接
跳转，MUST NOT 提示用户选择。

只有当候选 TU 求值后**确实产生不同实体**时，系统才 SHALL 呈现选择，且展示 SHALL 说明分歧内容
（不同实体或不同目标位置），MUST NOT 仅列出 TU 文件名——用户无法据 TU 名称判断哪个是所需目标。

既无法自动收敛、也无法证明存在真实分歧时，系统 SHALL 返回 `unavailable` 并给出可执行原因，
MUST NOT 以候选 TU 列表代替答案。

收敛过程 SHALL 保持异步且不阻塞 UI，其尝试范围 SHALL 有上界。

#### Scenario: Header is included by many TUs that agree
- **WHEN** 某头文件位置有多个候选 origin TU，且在其中求值得到同一 canonical USR 与同一 definition
- **THEN** 系统 SHALL 直接跳转到该 definition
- **AND** 系统 MUST NOT 提示用户选择 translation-unit context

#### Scenario: Candidate TUs genuinely disagree
- **WHEN** 候选 origin TU 求值后得到不同的 canonical entity 或不同的 definition 位置
- **THEN** 系统 SHALL 返回 `ambiguous-context` 并呈现分歧对应关系
- **AND** 展示 SHALL 包含实体/目标信息，MUST NOT 仅呈现 TU 文件名

#### Scenario: Convergence is impossible and disagreement is unproven
- **WHEN** 系统既不能自动确定 origin TU，也无法证明候选之间存在真实分歧
- **THEN** 系统 SHALL 返回 `unavailable` 及可执行原因
- **AND** MUST NOT 用候选 TU 列表代替定位结果

#### Scenario: Convergence must not guess from names or paths
- **WHEN** 系统在多个候选 TU 之间收敛
- **THEN** 判据 SHALL 限于 compiler-emitted dependency evidence、unity membership 与 canonical USR 一致性
- **AND** MUST NOT 使用文件名相似度、路径距离或候选返回顺序

#### Scenario: Inherited origin already proves the TU
- **WHEN** 当前窗口的 origin lineage 在同一 build generation 下已证明适用于该 subject
- **THEN** 系统 SHALL 直接使用该 TU，MUST NOT 重新提示选择
