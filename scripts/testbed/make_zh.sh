#!/bin/bash
# Chinese files with known content (evals/chinese.json): a report, a lease, meeting minutes, a parts list and a plan.
# Written as text, so they need no toolchain: the point is the words, not how they were made.
#   scripts/testbed/make_zh.sh <dir>       e.g. ~/DigUpTestbed/synthetic/lang/zh
set -euo pipefail
Z="${1:?usage: make_zh.sh <dir>}"
mkdir -p "$Z"

cat > "$Z/项目验收报告.txt" <<'EOF'
关于本项目验收报告的说明

一、验收范围
本次验收覆盖数据采集层、平台层和应用层三个部分。

二、测试记录
压力测试连续运行七十二小时，未出现服务中断。
安全扫描发现三处中危漏洞，已在整改计划中列出。

三、整改计划
漏洞修复预计两周内完成，复测通过后提交最终验收报告。
EOF

cat > "$Z/租赁合同.txt" <<'EOF'
房屋租赁合同

第一条 租赁期限
租期为两年，自二零二六年一月一日起至二零二七年十二月三十一日止。

第二条 租金
月租金为人民币贰万伍仟元整，每月五日前支付。

第三条 押金条款
承租方应于签约时支付两个月租金作为押金，共计伍万元整。
租期届满且无违约情形的，押金于十五个工作日内无息退还。
逾期未付租金的，按日计收千分之五违约金。
EOF

cat > "$Z/会议纪要.md" <<'EOF'
# 数字孪生二期 项目启动会

## 参会人员
张三、李四、王五、赵六

## 讨论要点
- 整体架构沿用一期方案，新增实时数据接入能力
- 数据采集层需要支持 OPC UA 和 Modbus 两种协议
- 平台层采用容器化部署，保证高可用
- 应用层优先交付设备健康管理模块

## 待办
张三负责整理技术规范，下周三前提交。
李四负责梳理网络拓扑，与客户确认现场条件。
EOF

cat > "$Z/供应商清单.txt" <<'EOF'
序号	物料编码	名称	数量	单价
1	NET-C9300-48P	思科交换机	2	18500
2	FW-FORTIGATE-200G	飞塔防火墙	1	42000
3	SRV-DELL-R760	戴尔服务器	3	76000
4	UPS-APC-3000	不间断电源	2	9800
EOF

cat > "$Z/数字化转型方案.txt" <<'EOF'
制造业数字化转型整体方案

本方案围绕生产效率、质量追溯和设备可用性三个维度展开。
通过 MES 系统实现工单下发、过程采集和质量判定闭环。
结合 IIoT 平台采集设备运行数据，构建设备健康模型。
预期效果：设备综合效率提升百分之十二，质量成本下降百分之八。
EOF
