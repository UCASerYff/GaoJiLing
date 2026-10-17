# 搞机灵维护接口交接（V1.11）

仅说明本应用提供的接口，不改变其他应用的源码、安装、数据库或登记。消费者必须读取实际安装包内 GaoCapabilities.json 并核对 Info.plist 的 bundleID/版本；未安装或未声明该模式时禁用动作，不回退为直接删除。

| action | 输入与参数 | 用户确认与结果 |
| --- | --- | --- |
| storage.inspect / metadata（默认） | 恰一 directory reference；mode 可省略或 metadata；无 items | 核对实际目录身份后按原元数据引擎分析。结果保留 scope/complete/statistics。 |
| storage.inspect / duplicates | 恰一 directory reference；mode=duplicates；无 items | 第一次批准仅预填范围并返回 pending/awaitingUser；本人在存储页再次确认内容读取后，先持久 executing 再启动独立内容引擎。不会自动勾选/移动副本。 |
| cleanup.review | 无 items/references，parameters={} | 原白名单扫描与本机逐项选择/确认；真实移动回执后才可 completed。 |
| apps.uninstall.review | 恰一 application reference（真实 bundleID 与身份），parameters={} | 本机确认、分类预览、默认不选；真实卸载事务/receipt 后才可 completed。 |

保持 GaoAction V1：manifest≤1MiB、items+references≤256、payload≤2GiB、TTL 120秒；批准后长任务不因请求TTL中断，生成结果重新计时。nonce 和来源 bundleID 不证明来源身份；目录/App引用只传上下文，不传权限。无回调 URL、shell、HTTP服务或跨应用共享资料库。

## duplicates 结果

无 items/references/个人路径报告。provenance 新增 mode=duplicates；scope 保持 {referenceID,displayName,kind:directory}，complete 是实际完整性，workflowState 与核心 status 一致。statistics 全部为真实非负整数：

- allocatedBytes/logicalBytes/files/entries/skippedCount：已确认唯一普通文件的分配空间/逻辑长度/文件数/检查条目/跳过数；部分扫描仅是已读部分。
- duplicateGroups：确认完全相同的内容组数。
- duplicateFiles：各组除建议保留项之外的独立实物数；保护文件仍不获得移动许可。
- duplicateLogicalBytes/duplicateAllocatedBytes：上述重复实物的估算占用，不是已释放或保证可释放的容量。
- contentBytesRead：本次各摘要及逐字节核验实际读取量。

默认同inode/硬链接只算一个实物。取消、预算、权限、云占位、跨卷和文件变化会给 cancelled/partial/failed，不能报告完整范围没有重复。恢复事务是本应用另行明确确认的本机操作，不由 storage.inspect 请求直接触发。

## 真实双方验收（待本人配合）

用实际安装的消费者在其生产入口生成自建目录/App请求；在搞机灵核对引用并本人确认；metadata/duplicates核对真实operation和完整性，清理/卸载只选自建样本并核对真实receipt；本人点击“发送结果”，消费者独立验证 inReplyTo/摘要/来源关联并接受，重复接收不重放。结果与请求TTL内操作需按实际生产时钟进行，不将固定fixture的测试时间当生产时间。

本次默认不自动冒烟或启动窗口。生产协调器隔离测试证明状态/结果映射及安全门控，不能代替已安装双方的GUI、原生Trash/恢复或自建应用正常退出验收；这些步骤须按私有人工计划另行记录。
