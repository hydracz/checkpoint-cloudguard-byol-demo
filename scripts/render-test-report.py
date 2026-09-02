#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import html
import json
import re
import shlex
from pathlib import Path
from urllib.parse import quote


CASE_INFO = {
    "T01": (
        "主工作负载默认路由",
        "主工作负载的 Active 0.0.0.0/0 路由应指向 CloudGuard backend IP。",
    ),
    "T02": (
        "远端工作负载默认路由",
        "远端工作负载的 Active 0.0.0.0/0 路由应指向 CloudGuard backend IP。",
    ),
    "T03": (
        "跨区域东西向访问",
        "主工作负载访问远端工作负载 TCP/8080，应返回演示页面。",
    ),
    "T04": (
        "允许的 HTTPS 出站",
        "主工作负载访问允许的 HTTPS URL，应返回 HTTP 200。",
    ),
    "T05": (
        "域名阻断",
        "主工作负载访问 example.com，应连接失败或返回阻断响应。",
    ),
    "T06": (
        "URL Path 阻断",
        "allowed path 应返回 200，blocked path 不应返回相同成功内容。",
    ),
    "T07": (
        "HTTPS Inspection",
        "启用 TLS Inspection 时，实际叶子证书 issuer 应为配置的企业/演示 CA。",
    ),
    "T08": (
        "Firewall Policy 配置",
        "Gateway 应包含已启用的双向 Geo、L7、管理和数据路径规则。",
    ),
    "T09": (
        "Check Point Log Exporter",
        "azure-monitor Log Exporter 应处于 Running 状态。",
    ),
    "T10": (
        "Firewall 日志摄取",
        "Log Analytics 应返回包含 action=Accept/Drop 的 Firewall 日志。",
    ),
    "T11": (
        "不可变保留策略",
        "Storage immutability policy 的保留天数应与部署配置一致。",
    ),
    "T12": (
        "资源区域合规",
        "资源位置应只包含批准的 EU region 或 global。",
    ),
    "T13": (
        "可选南北向入站",
        "启用 DNAT 时，从批准来源访问 Public IP:18080 应返回主工作负载页面。",
    ),
    "T14": (
        "CloudGuard 镜像与 Plan",
        "VM image reference 和 Marketplace Plan 应与部署配置完全一致。",
    ),
    "T15": (
        "Gaia 版本",
        "Gateway 实际 Gaia 版本应与 checkpoint_os_version 一致。",
    ),
    "T16": (
        "东西向源地址保留",
        "远端工作负载日志应看到主工作负载 IP，而不是 Gateway Hide NAT 地址。",
    ),
    "T17": (
        "管理 NSG Rules",
        "SSH、Gaia Portal 和 SmartConsole rules 应为 Allow，来源应与 management_cidrs 一致。",
    ),
}

STATUS_LABELS = {
    "PASS": "通过",
    "FAIL": "失败",
    "SKIP": "跳过",
    "RECONCILED": "临时恢复后通过",
    "PENDING_INGESTION": "等待日志摄取",
}


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-dir", required=True)
    parser.add_argument("--exit-code", required=True, type=int)
    return parser.parse_args()


def read_json(path, default):
    if not path.is_file():
        return default
    try:
        with path.open(encoding="utf-8") as source:
            return json.load(source)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return default


def output_value(outputs, key, default=None):
    entry = outputs.get(key)
    if not isinstance(entry, dict) or "value" not in entry:
        return default
    return entry["value"]


def sha256(path):
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def esc(value):
    return html.escape(str(value), quote=True)


def display_value(value):
    if value is None or value == "":
        return "-"
    if isinstance(value, bool):
        return "是" if value else "否"
    if isinstance(value, list):
        return ", ".join(str(item) for item in value)
    return str(value)


def status_badge(status):
    label = STATUS_LABELS.get(status, status)
    css_status = re.sub(r"[^a-z0-9_-]", "-", status.lower())
    return f'<span class="status {esc(css_status)}">{esc(label)}</span>'


def preformatted(text):
    return f"<pre><code>{esc(text.rstrip())}</code></pre>"


def evidence_link(filename, digest):
    if not filename:
        return "-"
    link = f'<a href="{quote(filename)}">{esc(filename)}</a>'
    if digest:
        link += f'<div class="hash">SHA-256: {esc(digest)}</div>'
    return link


def load_results(evidence_dir, temporary_ssh_rule_created):
    results_path = evidence_dir / "results.tsv"
    if not results_path.is_file():
        return []

    results = []
    with results_path.open(encoding="utf-8") as source:
        for line in source:
            case_id, status, evidence = line.rstrip("\n").split("|", 2)
            if (
                case_id == "T17"
                and status == "PASS"
                and temporary_ssh_rule_created
            ):
                status = "RECONCILED"
            evidence_path = evidence_dir / evidence
            title, expected = CASE_INFO.get(
                case_id, (case_id, "请查看原始证据。")
            )
            results.append(
                {
                    "id": case_id,
                    "title": title,
                    "expected": expected,
                    "status": status,
                    "evidence": evidence,
                    "evidenceSha256": sha256(evidence_path),
                }
            )
    return sorted(results, key=lambda item: int(item["id"][1:]))


def build_configuration(outputs, metadata, stage2):
    image_id = output_value(outputs, "checkpoint_image_id")
    if image_id:
        image = image_id
    else:
        image = "checkpoint:{offer}:{plan}".format(
            offer=output_value(outputs, "checkpoint_offer", "-"),
            plan=output_value(outputs, "checkpoint_plan", "-"),
        )
    return {
        "Outputs 来源": metadata.get("outputsSource", "unknown"),
        "Subscription ID": output_value(outputs, "subscription_id"),
        "Resource Group": output_value(outputs, "resource_group_name"),
        "Check Point 版本": output_value(outputs, "checkpoint_os_version"),
        "Gateway VM": output_value(outputs, "checkpoint_vm_name"),
        "Gateway Public IP": output_value(outputs, "checkpoint_public_ip"),
        "Gateway Backend IP": output_value(
            outputs, "checkpoint_backend_private_ip"
        ),
        "CloudGuard Image": image,
        "Image 需要 Plan": output_value(
            outputs, "checkpoint_image_requires_plan"
        ),
        "Management CIDRs": output_value(outputs, "management_cidrs", []),
        "Policy Package": output_value(outputs, "policy_package_name"),
        "本次执行 Firewall 配置": stage2.get("configurePolicy", False),
        "TLS Inspection": output_value(outputs, "enable_tls_inspection"),
        "R81 TLS 已人工配置": output_value(
            outputs, "r81_tls_manually_configured"
        ),
        "启用入站演示": output_value(outputs, "enable_inbound_demo"),
        "主工作负载 VM": output_value(outputs, "eu_workload_vm_name"),
        "主工作负载 IP": output_value(
            outputs, "eu_workload_private_ip"
        ),
        "远端工作负载 VM": output_value(
            outputs, "remote_workload_vm_name"
        ),
        "远端工作负载 IP": output_value(
            outputs, "remote_workload_private_ip"
        ),
        "Log Analytics Workspace": output_value(
            outputs, "log_analytics_workspace_customer_id"
        ),
        "Audit Storage Account": output_value(
            outputs, "audit_storage_account_name"
        ),
        "Audit Container": output_value(outputs, "audit_container_name"),
        "Immutable Retention Days": output_value(
            outputs, "immutable_retention_days"
        ),
        "测试期间临时恢复 SSH Rule": metadata.get(
            "temporarySshRuleCreated", False
        ),
        "显式提供 Public CA": stage2.get("caFileProvided", False),
    }


def decode_first_json(text):
    start = text.find("{")
    if start < 0:
        return None
    try:
        value, _ = json.JSONDecoder().raw_decode(text[start:])
    except json.JSONDecodeError:
        return None
    return value


def run_command_streams(path):
    payload = read_json(path, None)
    if not isinstance(payload, dict) or not isinstance(
        payload.get("value"), list
    ):
        if path.is_file():
            return (
                path.read_text(encoding="utf-8", errors="replace").strip(),
                "",
            )
        return "", ""

    stdout_parts = []
    stderr_parts = []
    for item in payload["value"]:
        message = item.get("message", "") if isinstance(item, dict) else ""
        if "[stdout]\n" not in message:
            if message.strip():
                stdout_parts.append(message.strip())
            continue
        _, remainder = message.split("[stdout]\n", 1)
        if "\n[stderr]\n" in remainder:
            stdout, stderr = remainder.split("\n[stderr]\n", 1)
        else:
            stdout, stderr = remainder, ""
        if stdout.strip():
            stdout_parts.append(stdout.strip())
        if stderr.strip():
            stderr_parts.append(stderr.strip())
    return "\n".join(stdout_parts), "\n".join(stderr_parts)


def firewall_rule_evidence(path):
    if not path.is_file():
        return [], "", "", "Network"
    text, stderr = run_command_streams(path)
    if stderr:
        text = f"{text}\n{stderr}"
    rulebase = decode_first_json(text)
    if not isinstance(rulebase, dict):
        return (
            [],
            extract_gaia_version(text),
            extract_exporter(text),
            "Network",
        )

    names = {
        item.get("uid"): item.get("name", item.get("uid"))
        for item in rulebase.get("objects-dictionary", [])
        if isinstance(item, dict)
    }

    def resolve(values):
        if not isinstance(values, list):
            values = [values]
        return ", ".join(names.get(value, str(value)) for value in values)

    rules = []
    for rule in rulebase.get("rulebase", []):
        if not isinstance(rule, dict):
            continue
        name = rule.get("name", "")
        if not name.startswith("CloudGuard Demo - "):
            continue
        rules.append(
            {
                "number": rule.get("rule-number"),
                "name": name,
                "source": resolve(rule.get("source", [])),
                "destination": resolve(rule.get("destination", [])),
                "service": resolve(rule.get("service", [])),
                "action": resolve(rule.get("action")),
                "enabled": rule.get("enabled", True),
                "installOn": resolve(rule.get("install-on", [])),
            }
        )
    return (
        rules,
        extract_gaia_version(text),
        extract_exporter(text),
        rulebase.get("name", "Network"),
    )


def extract_gaia_version(text):
    lines = [
        line
        for line in text.splitlines()
        if line.startswith("Product version Check Point Gaia ")
        or line.startswith("OS build ")
        or line.startswith("OS kernel version ")
    ]
    return "\n".join(lines)


def extract_exporter(text):
    match = re.search(
        r"(?ms)^name:\s*azure-monitor\s*$.*?(?=\n\S|\Z)", text
    )
    if match:
        return match.group(0).strip()
    lines = [
        line.strip()
        for line in text.splitlines()
        if "azure-monitor" in line or "status:" in line
    ]
    return "\n".join(lines[-5:])


def parse_syslog_fields(message):
    fields = {}
    try:
        tokens = shlex.split(message)
    except ValueError:
        tokens = message.split()
    for token in tokens:
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        fields[key.rstrip(":")] = value
    return fields


def firewall_log_evidence(path):
    records = read_json(path, [])
    if isinstance(records, dict) and isinstance(records.get("tables"), list):
        converted = []
        for table in records["tables"]:
            columns = [
                column.get("name")
                for column in table.get("columns", [])
                if isinstance(column, dict)
            ]
            for row in table.get("rows", []):
                if isinstance(row, list) and len(row) == len(columns):
                    converted.append(dict(zip(columns, row)))
        records = converted
    if not isinstance(records, list):
        return []
    logs = []
    for record in records:
        if not isinstance(record, dict):
            continue
        message = record.get("SyslogMessage", "")
        fields = parse_syslog_fields(message)
        action = fields.get("action") or fields.get("rule_action")
        if action not in {"Accept", "Drop"}:
            continue
        logs.append(
            {
                "time": record.get("TimeGenerated")
                or record.get("EventTime")
                or "-",
                "action": action,
                "source": fields.get("src", "-"),
                "destination": fields.get("dst", "-"),
                "service": fields.get("service_id")
                or fields.get("service")
                or fields.get("proto", "-"),
                "rule": fields.get("rule_name", "-"),
                "message": message,
            }
        )
    return logs[:30]


def captured_run_command(path):
    stdout, stderr = run_command_streams(path)
    targets = []
    commands = []
    visible = [
        line
        for line in stdout.splitlines()
        if not line.startswith("__DEMO_RESULT=")
        and not line.startswith("EXECUTED_ON=")
        and not line.startswith("COMMAND=")
    ]
    for line in stdout.splitlines():
        if line.startswith("EXECUTED_ON="):
            targets.append(line.split("=", 1)[1])
        elif line.startswith("COMMAND="):
            commands.append(line.split("=", 1)[1])
    observed = "\n".join(visible).strip()
    if stderr.strip():
        observed = (
            f"{observed}\n\nSTDERR:\n{stderr.strip()}"
            if observed
            else f"STDERR:\n{stderr.strip()}"
        )
    if observed:
        return {
            "target": ", ".join(dict.fromkeys(targets)),
            "commands": commands,
            "observed": observed,
        }
    if any(
        line.startswith("__DEMO_RESULT=") for line in stdout.splitlines()
    ):
        observed = (
            "该历史证据由旧版采集器生成，只保留了测试状态，未保留命令响应正文。"
            "请使用当前版本重新执行以获取 HTTP 状态和响应内容。"
        )
    return {
        "target": ", ".join(dict.fromkeys(targets)),
        "commands": commands,
        "observed": observed or "没有可显示的远端命令输出。",
    }


def q(value):
    return shlex.quote(str(value))


def multiline_command(parts):
    return " \\\n  ".join(parts)


def case_command(case_id, outputs, rulebase_name):
    subscription = output_value(outputs, "subscription_id", "<SUBSCRIPTION>")
    resource_group = output_value(
        outputs, "resource_group_name", "<RESOURCE_GROUP>"
    )
    gateway_vm = output_value(outputs, "checkpoint_vm_name", "<GATEWAY>")
    gateway_ip = output_value(
        outputs, "checkpoint_public_ip", "<GATEWAY_PUBLIC_IP>"
    )
    gateway_nsg = str(
        output_value(outputs, "checkpoint_nsg_id", "<GATEWAY_NSG>")
    ).rsplit("/", 1)[-1]
    eu_vm = output_value(outputs, "eu_workload_vm_name", "<PRIMARY_VM>")
    remote_vm = output_value(
        outputs, "remote_workload_vm_name", "<REMOTE_VM>"
    )
    eu_nic = output_value(outputs, "eu_workload_nic_name", "<PRIMARY_NIC>")
    remote_nic = output_value(
        outputs, "remote_workload_nic_name", "<REMOTE_NIC>"
    )
    eu_ip = output_value(outputs, "eu_workload_private_ip", "<PRIMARY_IP>")
    remote_ip = output_value(
        outputs, "remote_workload_private_ip", "<REMOTE_IP>"
    )
    workspace = output_value(
        outputs,
        "log_analytics_workspace_customer_id",
        "<LOG_ANALYTICS_WORKSPACE>",
    )
    account = output_value(
        outputs, "audit_storage_account_name", "<STORAGE_ACCOUNT>"
    )
    container = output_value(
        outputs, "audit_container_name", "<CONTAINER>"
    )
    tls_enabled = output_value(outputs, "enable_tls_inspection", False)
    scheme = "https" if tls_enabled else "http"

    azure_target = "Azure Control Plane"
    commands = {
        "T01": (
            azure_target,
            multiline_command(
                [
                    "az network nic show-effective-route-table",
                    f"--subscription {q(subscription)}",
                    f"--resource-group {q(resource_group)}",
                    f"--name {q(eu_nic)}",
                    "--output json",
                ]
            ),
        ),
        "T02": (
            azure_target,
            multiline_command(
                [
                    "az network nic show-effective-route-table",
                    f"--subscription {q(subscription)}",
                    f"--resource-group {q(resource_group)}",
                    f"--name {q(remote_nic)}",
                    "--output json",
                ]
            ),
        ),
        "T03": (
            f"{eu_vm} (通过 Azure Run Command 执行)",
            f"curl -fsS --connect-timeout 10 --max-time 20 http://{remote_ip}:8080/",
        ),
        "T04": (
            f"{eu_vm} (通过 Azure Run Command 执行)",
            "curl -fsS --connect-timeout 10 --max-time 30 "
            "https://httpbin.org/anything/allowed",
        ),
        "T05": (
            f"{eu_vm} (通过 Azure Run Command 执行)",
            "curl -sS --connect-timeout 10 --max-time 20 https://example.com/",
        ),
        "T06": (
            f"{eu_vm} (通过 Azure Run Command 执行)",
            "\n".join(
                [
                    f"curl -sS --connect-timeout 10 --max-time 30 {scheme}://httpbin.org/anything/allowed",
                    f"curl -sS --connect-timeout 10 --max-time 30 {scheme}://httpbin.org/anything/blocked",
                ]
            ),
        ),
        "T07": (
            f"{eu_vm} (通过 Azure Run Command 执行)",
            "openssl s_client -connect www.microsoft.com:443 "
            "-servername www.microsoft.com </dev/null | "
            "openssl x509 -noout -issuer -nameopt RFC2253",
        ),
        "T08": (
            f"{gateway_vm} (Gaia Management API)",
            "mgmt_cli -r true show access-rulebase "
            f"name {q(rulebase_name or 'Network')} limit 500 "
            "details-level standard --format json",
        ),
        "T09": (
            f"{gateway_vm} (Gaia Shell)",
            "cp_log_export status",
        ),
        "T10": (
            azure_target,
            multiline_command(
                [
                    "az monitor log-analytics query",
                    f"--subscription {q(subscription)}",
                    f"--workspace {q(workspace)}",
                    "--analytics-query \"Syslog | where TimeGenerated > ago(2h) "
                    "| where SyslogMessage contains 'action=\\\"Accept\\\"' "
                    "or SyslogMessage contains 'action=\\\"Drop\\\"' "
                    "or SyslogMessage contains 'rule_action=\\\"Accept\\\"' "
                    "or SyslogMessage contains 'rule_action=\\\"Drop\\\"' "
                    "| project TimeGenerated, Computer, HostName, SeverityLevel, SyslogMessage "
                    "| order by TimeGenerated desc | take 50\"",
                    "--output json",
                ]
            ),
        ),
        "T11": (
            azure_target,
            multiline_command(
                [
                    "az storage container immutability-policy show",
                    f"--subscription {q(subscription)}",
                    f"--resource-group {q(resource_group)}",
                    f"--account-name {q(account)}",
                    f"--container-name {q(container)}",
                    "--output json",
                ]
            ),
        ),
        "T12": (
            azure_target,
            multiline_command(
                [
                    "az resource list",
                    f"--subscription {q(subscription)}",
                    f"--resource-group {q(resource_group)}",
                    "--query '[].{name:name,type:type,location:location}'",
                    "--output json",
                ]
            ),
        ),
        "T13": (
            "测试执行终端（必须位于批准来源）",
            f"curl -fsS --connect-timeout 10 --max-time 30 http://{gateway_ip}:18080/",
        ),
        "T14": (
            azure_target,
            multiline_command(
                [
                    "az vm show",
                    f"--subscription {q(subscription)}",
                    f"--resource-group {q(resource_group)}",
                    f"--name {q(gateway_vm)}",
                    "--query '{name:name,location:location,vmSize:hardwareProfile.vmSize,"
                    "imageReference:storageProfile.imageReference,plan:plan,"
                    "provisioningState:provisioningState}'",
                    "--output json",
                ]
            ),
        ),
        "T15": (
            f"{gateway_vm} (Gaia Shell)",
            'clish -c "show version all"',
        ),
        "T16": (
            f"{remote_vm} (通过 Azure Run Command 执行)",
            "journalctl -u demo-web.service --since '10 minutes ago' "
            f"--no-pager | grep -F {q(eu_ip)}",
        ),
        "T17": (
            azure_target,
            multiline_command(
                [
                    "az network nsg rule list",
                    f"--subscription {q(subscription)}",
                    f"--resource-group {q(resource_group)}",
                    f"--nsg-name {q(gateway_nsg)}",
                    "--output json",
                ]
            ),
        ),
    }
    return commands.get(case_id, ("未知", "请查看原始证据。"))


def selected_json(path, selector):
    payload = read_json(path, None)
    if payload is None:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    return json.dumps(selector(payload), indent=2, ensure_ascii=False)


def case_observation(case_id, evidence_path, rules, gaia, exporter, logs):
    if not evidence_path.is_file():
        return "原始证据文件不存在。"
    if case_id in {"T03", "T04", "T05", "T06", "T07", "T16"}:
        return captured_run_command(evidence_path)["observed"]
    if case_id in {"T01", "T02"}:
        return selected_json(
            evidence_path,
            lambda data: [
                {
                    "addressPrefix": route.get("addressPrefix"),
                    "nextHopType": route.get("nextHopType"),
                    "nextHopIpAddress": route.get("nextHopIpAddress"),
                    "state": route.get("state"),
                }
                for route in data.get("value", [])
                if "0.0.0.0/0" in route.get("addressPrefix", [])
            ],
        )
    if case_id == "T08":
        if not rules:
            return evidence_path.read_text(
                encoding="utf-8", errors="replace"
            ).strip()
        return "\n".join(
            f'{rule["number"]}. {rule["name"]} -> {rule["action"]}'
            for rule in rules
        )
    if case_id == "T09":
        return exporter or evidence_path.read_text(
            encoding="utf-8", errors="replace"
        ).strip()
    if case_id == "T10":
        return f"提取到 {len(logs)} 条包含 Firewall action 的日志；详见“Firewall 日志佐证”。"
    if case_id == "T11":
        return selected_json(
            evidence_path,
            lambda data: {
                key: data.get(key)
                for key in (
                    "immutabilityPeriodSinceCreationInDays",
                    "immutabilityPeriodInDays",
                    "state",
                    "etag",
                )
                if key in data
            },
        )
    if case_id == "T12":
        return selected_json(
            evidence_path,
            lambda data: {
                "resourceCount": len(data),
                "locations": sorted(
                    {
                        item.get("location")
                        for item in data
                        if item.get("location")
                    }
                ),
            },
        )
    if case_id == "T13":
        return evidence_path.read_text(
            encoding="utf-8", errors="replace"
        ).strip()
    if case_id == "T14":
        return selected_json(evidence_path, lambda data: data)
    if case_id == "T15":
        return gaia or evidence_path.read_text(
            encoding="utf-8", errors="replace"
        ).strip()
    if case_id == "T17":
        return selected_json(
            evidence_path,
            lambda data: [
                {
                    "name": rule.get("name"),
                    "priority": rule.get("priority"),
                    "access": rule.get("access"),
                    "port": rule.get("destinationPortRange"),
                    "sources": rule.get("sourceAddressPrefixes")
                    or [rule.get("sourceAddressPrefix")],
                }
                for rule in data
                if str(rule.get("name", "")).startswith("AllowRestricted")
            ],
        )
    return evidence_path.read_text(
        encoding="utf-8", errors="replace"
    ).strip()


def render_configuration(configuration):
    rows = "\n".join(
        f"<tr><th>{esc(key)}</th><td>{esc(display_value(value))}</td></tr>"
        for key, value in configuration.items()
    )
    return f'<table class="kv"><tbody>{rows}</tbody></table>'


def render_firewall_rules(rules):
    if not rules:
        return '<p class="muted">未从 T08 证据中解析到 CloudGuard Demo rules。</p>'
    rows = []
    for rule in rules:
        rows.append(
            "<tr>"
            f'<td>{esc(rule["number"])}</td>'
            f'<td>{esc(rule["name"])}</td>'
            f'<td>{esc(rule["source"])}</td>'
            f'<td>{esc(rule["destination"])}</td>'
            f'<td>{esc(rule["service"])}</td>'
            f'<td>{esc(rule["action"])}</td>'
            f'<td>{"是" if rule["enabled"] else "否"}</td>'
            "</tr>"
        )
    return (
        '<table><thead><tr><th>#</th><th>Rule</th><th>Source</th>'
        "<th>Destination</th><th>Service/Application</th><th>Action</th>"
        f'<th>Enabled</th></tr></thead><tbody>{"".join(rows)}</tbody></table>'
    )


def render_firewall_logs(logs, evidence_filename):
    if not logs:
        return (
            '<p class="muted">未解析到带 action 的 Firewall 日志。'
            f'请查看 <a href="{quote(evidence_filename)}">{esc(evidence_filename)}</a>。</p>'
        )
    rows = []
    for item in logs:
        rows.append(
            "<tr>"
            f'<td>{esc(item["time"])}</td>'
            f'<td>{esc(item["action"])}</td>'
            f'<td>{esc(item["source"])}</td>'
            f'<td>{esc(item["destination"])}</td>'
            f'<td>{esc(item["service"])}</td>'
            f'<td>{esc(item["rule"])}</td>'
            "<td><details><summary>查看</summary>"
            f'{preformatted(item["message"])}</details></td>'
            "</tr>"
        )
    return (
        '<table><thead><tr><th>Time (UTC)</th><th>Action</th><th>Source</th>'
        "<th>Destination</th><th>Service</th><th>Rule</th><th>Raw Log</th>"
        f'</tr></thead><tbody>{"".join(rows)}</tbody></table>'
        f'<p class="source">原始日志：<a href="{quote(evidence_filename)}">'
        f"{esc(evidence_filename)}</a></p>"
    )


def render_result_summary(results):
    rows = []
    for result in results:
        rows.append(
            "<tr>"
            f'<td><a href="#{esc(result["id"])}">{esc(result["id"])}</a></td>'
            f'<td>{esc(result["title"])}</td>'
            f'<td>{status_badge(result["status"])}</td>'
            f'<td>{evidence_link(result["evidence"], result["evidenceSha256"])}</td>'
            "</tr>"
        )
    return (
        '<table><thead><tr><th>ID</th><th>验证项</th><th>结果</th>'
        f'<th>原始证据</th></tr></thead><tbody>{"".join(rows)}</tbody></table>'
    )


def render_test_details(
    results, outputs, evidence_dir, rulebase_name, rules, gaia, exporter, logs
):
    sections = []
    for result in results:
        evidence_path = evidence_dir / result["evidence"]
        target, command = case_command(result["id"], outputs, rulebase_name)
        if result["id"] in {"T03", "T04", "T05", "T06", "T07", "T16"}:
            captured = captured_run_command(evidence_path)
            if captured["target"]:
                target = (
                    f'{target}; 实际 hostname: {captured["target"]}'
                )
            if captured["commands"]:
                command = "\n".join(captured["commands"])
            else:
                command = (
                    "# 历史证据未记录远端命令；以下为当前版本定义的验证命令\n"
                    f"{command}"
                )
        observation = case_observation(
            result["id"],
            evidence_path,
            rules,
            gaia,
            exporter,
            logs,
        )
        sections.append(
            f'<article class="test-card" id="{esc(result["id"])}">'
            '<div class="test-heading">'
            f'<h3>{esc(result["id"])} · {esc(result["title"])}</h3>'
            f'{status_badge(result["status"])}</div>'
            '<dl class="test-meta">'
            f"<dt>执行位置</dt><dd>{esc(target)}</dd>"
            f"<dt>验证目标</dt><dd>{esc(result['expected'])}</dd>"
            "</dl>"
            "<h4>执行命令</h4>"
            f"{preformatted(command)}"
            "<h4>实际观察结果</h4>"
            f"{preformatted(observation)}"
            '<div class="evidence">原始证据：'
            f'{evidence_link(result["evidence"], result["evidenceSha256"])}</div>'
            "</article>"
        )
    return "\n".join(sections)


def render_r81_tls_guidance(outputs, results):
    if output_value(outputs, "checkpoint_os_version") != "R81":
        return ""
    t07 = next(
        (result for result in results if result["id"] == "T07"), None
    )
    if not t07 or t07["status"] == "PASS":
        return ""

    tls_enabled = output_value(outputs, "enable_tls_inspection", False)
    manual_ready = output_value(
        outputs, "r81_tls_manually_configured", False
    )
    reason = (
        "当前 enable_tls_inspection=false，脚本按设计跳过 T07。"
        if not tls_enabled
        else "当前 R81 SmartConsole bootstrap 或 public CA 输入尚未满足 T07 条件。"
    )
    state = (
        f"enable_tls_inspection={str(tls_enabled).lower()}, "
        f"r81_tls_manually_configured={str(manual_ready).lower()}"
    )
    commands = """# 1. 在 R81 tfvars 中记录已完成的 SmartConsole 配置
enable_tls_inspection       = true
r81_tls_manually_configured = true

# 2. 让 Terraform outputs 反映这两个开关（不会自动创建 R81 CA）
./scripts/plan.sh --var-file <R81_TFVARS>
terraform -chdir=infra apply -input=false -auto-approve "$(pwd)/.local/plan.tfplan"
terraform -chdir=infra output -json > .local/r81-tls-validation-outputs.json

# 3. 安装 public CA trust、保留 SmartConsole 配置并执行 T01-T17/T07
./scripts/validate-existing.sh \\
  --outputs-file .local/r81-tls-validation-outputs.json \\
  --expected-release R81 \\
  --configure-policy \\
  --ca-file <SMARTCONSOLE_EXPORTED_PUBLIC_CA>"""
    return f"""
  <h2>R81 HTTPS Inspection（T07）前置条件与半自动完成步骤</h2>
  <div class="panel">
    <div class="warning"><strong>T07 当前状态：{esc(STATUS_LABELS.get(t07["status"], t07["status"]))}</strong><br>
      {esc(reason)} 当前参数：<code>{esc(state)}</code>。</div>

    <h3>前置条件</h3>
    <ul>
      <li>R81 standalone Gateway 与 Management API 正常，受保护 workload 的默认路由经过该 Gateway。</li>
      <li>客户 BYOL 已激活 Firewall、Application Control、URL Filtering 和 HTTPS Inspection blades。</li>
      <li>使用与 R81 匹配的 SmartConsole，并从 <code>management_cidrs</code> 允许的来源连接。</li>
      <li>已确认客户允许进行 TLS 解密，并明确 bypass 范围、证书固定应用和隐私边界。</li>
    </ul>

    <h3>SmartConsole 中的 Firewall/HTTPS Inspection 配置</h3>
    <ol>
      <li><strong>Gateways &amp; Servers</strong> → 编辑 standalone Gateway → <strong>HTTPS Inspection</strong>。</li>
      <li>选择 <strong>Create</strong> 创建 outbound CA，或 <strong>Import</strong> 导入客户批准的 CA/P12；
        私钥和密码只留在受控 Management 环境。</li>
      <li>使用 <strong>Export certificate</strong> 导出只含公钥的 PEM/DER trust certificate，
        后续 <code>--ca-file</code> 使用该文件，不能使用私钥/P12。</li>
      <li>选择 <strong>Enable HTTPS Inspection</strong>。</li>
      <li><strong>Menu → Manage policies and layers</strong>，在 package 中启用
        <strong>Access Control &amp; HTTPS Inspection</strong>。</li>
      <li>在 HTTPS Inspection rulebase 中先添加客户批准的 Bypass rules，再添加 outbound Inspect rule：
        Source=受保护网络、Destination=Internet、Service=HTTPS、Action=Inspect、
        Certificate=Outbound Certificate、Track=Log、Install On=standalone Gateway。</li>
      <li>Publish，并将 Access Control policy Install 到 standalone Gateway。</li>
    </ol>

    <h3>更新部署状态并运行验证</h3>
    {preformatted(commands)}
    <p>第二阶段会把导出的 public CA 安装到两台 workload trust store，然后在实际 workload 上执行：</p>
    {preformatted('openssl s_client -connect www.microsoft.com:443 -servername www.microsoft.com </dev/null | openssl x509 -noout -issuer -nameopt RFC2253')}
    <p>只有实际 leaf certificate issuer 与 <code>--ca-file</code> 的 subject 匹配时，T07 才记为 PASS。
      如果测试订阅会删除 SSH NSG rule，可在最终命令前显式设置
      <code>CHECKPOINT_RECONCILE_SSH_RULE=true</code>。</p>
  </div>
"""


def firewall_configuration_status(evidence_dir, requested, results):
    if not requested:
        return "本次仅验证现有配置"
    candidates = [
        evidence_dir / "firewall-configuration-output.txt",
        evidence_dir / "firewall-configuration-output.json",
    ]
    for path in candidates:
        if not path.is_file():
            continue
        stdout, _ = run_command_streams(path)
        if "DEMO_CONFIGURATION_STATUS=complete" in stdout:
            return "配置完成"
    t08 = next(
        (result for result in results if result["id"] == "T08"), None
    )
    if t08 and t08["status"] == "PASS":
        return "Firewall rules 验证通过（未保留配置命令回执）"
    return "未确认完成"


def render_html(
    evidence_dir,
    generated_utc,
    overall_status,
    configuration,
    outputs,
    results,
    rules,
    rulebase_name,
    gaia,
    exporter,
    logs,
    cleanup_complete,
):
    counts = {}
    for result in results:
        counts[result["status"]] = counts.get(result["status"], 0) + 1
    count_cards = "".join(
        '<div class="count-card">'
        f'<strong>{count}</strong><span>{esc(STATUS_LABELS.get(status, status))}</span>'
        "</div>"
        for status, count in sorted(counts.items())
    )
    overall_label = {
        "PASS": "全部通过",
        "PASS_WITH_NOTES": "通过（含说明项）",
        "FAIL": "存在失败项",
    }.get(overall_status, overall_status)
    cleanup_text = "已清理" if cleanup_complete else "未记录清理或环境保留"
    firewall_status = (
        f"已读取 {len(rules)} 条 CloudGuard Demo rules"
        if rules
        else "未读取到规则"
    )

    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CloudGuard 部署验证报告</title>
  <style>
    :root {{ --green:#166534; --red:#991b1b; --amber:#92400e; --blue:#1d4ed8;
      --ink:#172033; --muted:#5f6b7a; --line:#d9e0e8; --bg:#f5f7fa; }}
    * {{ box-sizing:border-box; }}
    body {{ margin:0; color:var(--ink); background:var(--bg);
      font:14px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei",sans-serif; }}
    main {{ max-width:1280px; margin:0 auto; padding:36px 28px 72px; }}
    h1 {{ margin:0 0 8px; font-size:30px; }}
    h2 {{ margin:36px 0 14px; border-bottom:2px solid var(--line); padding-bottom:8px; }}
    h3 {{ margin:0; font-size:17px; }}
    h4 {{ margin:18px 0 7px; }}
    a {{ color:var(--blue); }}
    .hero,.panel,.test-card {{ background:white; border:1px solid var(--line);
      border-radius:10px; box-shadow:0 2px 8px rgba(15,23,42,.05); }}
    .hero {{ padding:26px; }}
    .hero-meta {{ display:flex; gap:24px; flex-wrap:wrap; color:var(--muted); }}
    .counts {{ display:flex; gap:12px; flex-wrap:wrap; margin-top:20px; }}
    .count-card {{ min-width:110px; padding:12px 16px; border-radius:8px; background:#eef3f8; }}
    .count-card strong {{ display:block; font-size:24px; }}
    .count-card span {{ color:var(--muted); }}
    .panel {{ padding:20px; overflow:auto; }}
    table {{ width:100%; border-collapse:collapse; background:white; }}
    th,td {{ border:1px solid var(--line); padding:9px 10px; vertical-align:top; text-align:left; }}
    thead th,.kv th {{ background:#eef3f8; }}
    .kv th {{ width:260px; }}
    .status {{ display:inline-block; padding:3px 9px; border-radius:999px; font-weight:650; white-space:nowrap; }}
    .status.pass {{ color:var(--green); background:#dcfce7; }}
    .status.fail,.status.pending_ingestion {{ color:var(--red); background:#fee2e2; }}
    .status.skip {{ color:var(--amber); background:#fef3c7; }}
    .status.reconciled {{ color:#075985; background:#e0f2fe; }}
    .overall {{ font-size:20px; font-weight:700; margin:14px 0; }}
    .test-card {{ padding:20px; margin:16px 0; scroll-margin-top:20px; }}
    .test-heading {{ display:flex; justify-content:space-between; gap:16px; align-items:center; }}
    .test-meta {{ display:grid; grid-template-columns:100px 1fr; gap:6px 12px; }}
    .test-meta dt {{ font-weight:650; color:var(--muted); }}
    .test-meta dd {{ margin:0; }}
    pre {{ margin:0; padding:13px; overflow:auto; border-radius:7px;
      background:#0f172a; color:#e2e8f0; white-space:pre-wrap; word-break:break-word; }}
    .hash {{ color:var(--muted); font-size:11px; word-break:break-all; margin-top:3px; }}
    .evidence,.source,.muted {{ color:var(--muted); margin-top:12px; }}
    .two-col {{ display:grid; grid-template-columns:1fr 1fr; gap:16px; }}
    .note {{ border-left:4px solid #0ea5e9; padding:12px 14px; background:#e0f2fe; }}
    .warning {{ border-left:4px solid #f59e0b; padding:12px 14px; margin-bottom:18px; background:#fffbeb; }}
    details summary {{ cursor:pointer; color:var(--blue); }}
    @media (max-width:800px) {{ .two-col {{ grid-template-columns:1fr; }} main {{ padding:20px 12px 48px; }} }}
    @media print {{ body {{ background:white; }} main {{ max-width:none; padding:0; }}
      .hero,.panel,.test-card {{ box-shadow:none; break-inside:avoid; }} a {{ color:inherit; text-decoration:none; }} }}
  </style>
</head>
<body>
<main>
  <section class="hero">
    <h1>CloudGuard 部署验证报告</h1>
    <div class="hero-meta">
      <span>生成时间（UTC）：{esc(generated_utc)}</span>
      <span>版本：{esc(display_value(configuration.get("Check Point 版本")))}</span>
      <span>Resource Group：{esc(display_value(configuration.get("Resource Group")))}</span>
    </div>
    <div class="overall">{esc(overall_label)}</div>
    <div class="counts">{count_cards}</div>
  </section>

  <h2>环境与配置</h2>
  <div class="panel">{render_configuration(configuration)}</div>

  <h2>Firewall 配置验证</h2>
  <div class="two-col">
    <div class="panel"><h3>Gaia 版本</h3>{preformatted(gaia or "未提取到 Gaia 版本")}</div>
    <div class="panel"><h3>Log Exporter</h3>{preformatted(exporter or "未提取到 Log Exporter 状态")}</div>
  </div>
  <div class="panel" style="margin-top:16px">
    <p><strong>{esc(firewall_status)}</strong></p>
    {render_firewall_rules(rules)}
  </div>

  <h2>测试结果汇总</h2>
  <div class="panel">{render_result_summary(results)}</div>

  <h2>测试详情：命令与实际结果</h2>
  {render_test_details(results, outputs, evidence_dir, rulebase_name, rules, gaia, exporter, logs)}

  {render_r81_tls_guidance(outputs, results)}

  <h2>Firewall 日志佐证</h2>
  <div class="panel">
    <p>以下记录来自 Log Analytics，筛选条件要求 SyslogMessage 包含 <code>action=</code>。
    表格保留 Action、源/目的、Service 和命中 Rule；完整原始消息可展开查看。</p>
    {render_firewall_logs(logs, "T10-log-analytics.json")}
  </div>

  <h2>说明</h2>
  <div class="panel">
    <p class="note"><strong>RECONCILED</strong> 表示测试环境的外部策略删除了 SSH NSG rule，
    测试期间临时恢复并在结束时删除；它不是普通 PASS。<strong>SKIP</strong> 表示对应可选功能未启用。</p>
    <p>测试环境清理状态：{esc(cleanup_text)}。</p>
    <p>客户报告不包含脚本执行 trace、Terraform apply/destroy 过程或中间调试日志。
    这些文件仍保留在 evidence 目录，供工程排障使用。</p>
  </div>
</main>
</body>
</html>
"""


def main():
    args = parse_args()
    evidence_dir = Path(args.evidence_dir).resolve()
    evidence_dir.mkdir(parents=True, exist_ok=True)

    outputs = read_json(evidence_dir / "deployment-outputs.json", {})
    metadata = read_json(evidence_dir / "validation-metadata.json", {})
    stage2 = read_json(evidence_dir / "stage2-metadata.json", {})
    command_trace = evidence_dir / "commands.log"
    temporary_ssh_rule_created = metadata.get(
        "temporarySshRuleCreated", False
    )
    if (
        not temporary_ssh_rule_created
        and command_trace.is_file()
        and "Restoring Terraform-managed SSH NSG rule"
        in command_trace.read_text(encoding="utf-8", errors="replace")
    ):
        temporary_ssh_rule_created = True
        metadata["temporarySshRuleCreated"] = True

    configuration = build_configuration(outputs, metadata, stage2)
    results = load_results(evidence_dir, temporary_ssh_rule_created)
    configuration["Firewall 配置执行结果"] = firewall_configuration_status(
        evidence_dir, stage2.get("configurePolicy", False), results
    )
    generated_utc = datetime.datetime.now(datetime.timezone.utc).isoformat()
    if args.exit_code != 0:
        overall_status = "FAIL"
    elif any(result["status"] != "PASS" for result in results):
        overall_status = "PASS_WITH_NOTES"
    else:
        overall_status = "PASS"

    policy_evidence = evidence_dir / "T08-T09-policy-and-exporter.json"
    rules, gaia, exporter, rulebase_name = firewall_rule_evidence(
        policy_evidence
    )
    logs = firewall_log_evidence(
        evidence_dir / "T10-log-analytics.json"
    )
    cleanup_log = evidence_dir / "cleanup.log"
    cleanup_complete = (
        cleanup_log.is_file()
        and "Destroy complete!" in cleanup_log.read_text(
            encoding="utf-8", errors="replace"
        )
    )

    summary = {
        "schemaVersion": 3,
        "generatedUtc": generated_utc,
        "overallStatus": overall_status,
        "exitCode": args.exit_code,
        "configuration": configuration,
        "firewallRuleCount": len(rules),
        "firewallActionLogCount": len(logs),
        "results": results,
        "report": "report.html",
        "note": (
            "The customer-facing HTML contains configuration, logical test "
            "commands, observed results, firewall rules, and firewall logs. "
            "Script traces remain separate engineering evidence."
        ),
    }
    with (evidence_dir / "configuration.json").open(
        "w", encoding="utf-8"
    ) as output:
        json.dump(configuration, output, indent=2, ensure_ascii=False)
        output.write("\n")
    with (evidence_dir / "summary.json").open(
        "w", encoding="utf-8"
    ) as output:
        json.dump(summary, output, indent=2, ensure_ascii=False)
        output.write("\n")
    (evidence_dir / "report.html").write_text(
        render_html(
            evidence_dir,
            generated_utc,
            overall_status,
            configuration,
            outputs,
            results,
            rules,
            rulebase_name,
            gaia,
            exporter,
            logs,
            cleanup_complete,
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
