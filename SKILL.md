---
name: ops-runbook
description: 仅在用户显式调用 $ops-runbook 时，按标题查询、写入或更新个人运维命令方案；普通问答和排障不得隐式读取或修改方案库。
---

# Ops Runbook

管理个人命令解决方案库：`C:\Users\49533\Desktop\解决方案命令.md`。

## 调用边界

- 只有用户在当前消息中明确写出 `$ops-runbook` 时才执行本 Skill。
- 普通问答、命令建议或排障过程不得读取、搜索、初始化或写入解决方案库。
- 每一次后续查询、写入、更新、合并或分别保留都需要再次显式调用 `$ops-runbook`。
- 不删除条目；更新前由脚本保留版本备份。

## 判断操作

根据用户的显式指令选择操作：

- “列出、有哪些”：`ListTitles`
- “查询、搜索”：`SearchTitle`
- “查看、读取”：先查询标题；唯一命中后执行 `ReadSection`
- “保存、记录、写入文件、加入”：检查冲突后执行 `AppendSection`
- “更新、修改某一个、替换、替代、覆盖”：执行 `UpdateSection`
- `ReplaceSection` 仅作为旧调用的兼容别名，新流程统一使用 `UpdateSection`

使用 `scripts/solution-library.ps1` 完成文件操作。不要直接编辑正式文档。

实际执行时，从本 `SKILL.md` 所在目录解析脚本绝对路径，不假设当前工作目录。

## 查询流程

1. 只用 `ListTitles` 或 `SearchTitle` 检查二级标题（`## `）。
2. 不搜索正文，也不为了找方案而通读全文。
3. 没有结果时只报告未命中，不初始化空文件。
4. 多个候选时只返回标题，请用户缩小范围。
5. 唯一命中且用户要求查看时，才用 `ReadSection` 读取该标题至下一个二级标题之间的正文。

## 写入流程

1. 读取 `references/entry-format.md`，将已解决案例整理成候选条目。
2. 先执行 `ValidateEntry -EntryPath <候选文件>`；失败时只报告错误，不写入。
3. 执行 `CheckConflicts -EntryPath <候选文件>`，保存返回的 `libraryHash`。
4. 完全同名时不追加，询问用户是否更新该条目。
5. 存在相似标题时停止写入，只列出标题并询问用户：
   - “分别保留”：用户需要在新消息中再次显式调用 `$ops-runbook`；重新检查冲突后，执行 `AppendSection -AllowSimilarTitle`。
   - “合并为一个”：请用户指定要合并到的完整标题；读取原条目，生成包含两者有效内容的完整候选条目，再执行更新流程。
6. 没有冲突时，执行 `AppendSection -EntryPath <候选文件> -ExpectedLibraryHash <libraryHash>`。
7. 报告新增标题、最新库哈希和备份路径；首次初始化没有备份。

“分别保留”只允许相似标题并存，完全同名标题仍不得重复追加。

## 更新流程

更新、替换、替代和覆盖都表示修改一个已存在的条目：

1. 当前消息必须再次显式调用 `$ops-runbook`，并明确写出要更新的完整旧标题。
2. 用 `ReadSection -Title <旧标题>` 读取原条目并取得 `libraryHash`。
3. 读取 `references/entry-format.md`，结合用户要求生成完整的新候选条目；不是局部文本补丁。
4. 候选条目的标题可以与旧标题不同。`-Title` 定位旧条目，候选条目的二级标题作为更新后的新标题。
5. 先执行 `ValidateEntry`。如果新标题与另一个非目标条目完全同名，停止更新。
6. 如果新标题与其他非目标条目相似，按“分别保留或合并为一个”的冲突流程询问用户。
7. 用户当前消息已经明确要求更新时，执行：

```powershell
& '<技能目录>\scripts\solution-library.ps1' `
  -Action UpdateSection `
  -Title '<完整旧标题>' `
  -EntryPath '<候选条目文件>' `
  -ExpectedLibraryHash '<ReadSection 返回的 libraryHash>' `
  -ConfirmUpdate
```

8. 报告旧标题、新标题、标题是否改变、最新库哈希和备份路径。

合并也使用 `UpdateSection`：把合并后的完整条目写回用户指定的原条目位置，不再追加第二个条目。

## 条目和验证规则

- 保存或更新前必须读取 `references/entry-format.md`。
- 状态默认写“未验证”；只有命令确实在目标环境中成功验证，才写“已验证”。
- 不保存密码、Token、Cookie、API Key、私钥、连接密钥或其他认证材料；使用 `<占位符>` 或环境变量。
- 元数据必须位于代码块外，并按状态、环境、权限的顺序各出现一次。
- 当前案例和通用命令模块各只有一个带语言标识且非空的代码块。
- 风险提示必须是条目的最后一个非空行。
- 删除、磁盘、网络、防火墙、账户或权限命令必须保留检查、验证和风险提示；回滚命令默认注释。

## 文件和安全规则

- 正式目标固定为 `C:\Users\49533\Desktop\解决方案命令.md`；用户明确说明文件已移动后，才修改 Skill 和脚本中的路径。
- `-AllowAlternatePath` 只用于隔离测试，处理正式请求时禁止使用。
- 空文件仅在首次成功追加时初始化为 `# 常用问题解决方案`。
- 写入和更新必须传入刚从 `CheckConflicts` 或 `ReadSection` 取得的 `-ExpectedLibraryHash`；哈希变化时重新检查。
- 更新必须携带 `-ConfirmUpdate`；兼容调用 `ReplaceSection -ConfirmReplace` 仍可使用。
- 相似标题只有在用户明确选择分别保留后，才能携带 `-AllowSimilarTitle`。
- 脚本用锁和原子替换写入，并把旧版本保存在同目录的 `解决方案命令.backups` 文件夹。
- 脚本返回 JSON。若 `ok` 为 `false`，说明错误并停止，不绕过脚本直接编辑正式文档。
