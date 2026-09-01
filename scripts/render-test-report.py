#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import json
from pathlib import Path


CASE_TITLES = {
    "T01": "Primary workload default route",
    "T02": "Remote workload default route",
    "T03": "Cross-region east-west traffic",
    "T04": "Allowed HTTPS egress",
    "T05": "Blocked domain",
    "T06": "Blocked URL path",
    "T07": "TLS inspection",
    "T08": "Bidirectional Geo and L7 policy",
    "T09": "Check Point Log Exporter",
    "T10": "Log Analytics ingestion",
    "T11": "Immutable retention policy",
    "T12": "Approved resource locations",
    "T13": "Optional north-south ingress",
    "T14": "CloudGuard image and plan",
    "T15": "Guest Gaia release",
    "T16": "East-west source preservation",
    "T17": "Management NSG rules",
}


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-dir", required=True)
    parser.add_argument("--exit-code", required=True, type=int)
    return parser.parse_args()


def read_json(path, default):
    if not path.is_file():
        return default
    with path.open(encoding="utf-8") as source:
        return json.load(source)


def output_value(outputs, key, default=None):
    entry = outputs.get(key)
    if not isinstance(entry, dict) or "value" not in entry:
        return default
    return entry["value"]


def evidence_hash(path):
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def markdown_value(value):
    if value is None or value == "":
        rendered = "-"
    elif isinstance(value, bool):
        rendered = str(value).lower()
    elif isinstance(value, list):
        rendered = ", ".join(str(item) for item in value)
    else:
        rendered = str(value)
    return rendered.replace("|", "\\|").replace("\n", "<br>")


def fenced(text, language="text"):
    text = text.rstrip("\n")
    fence = "```"
    while fence in text:
        fence += "`"
    return f"{fence}{language}\n{text}\n{fence}"


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
        "Outputs source": metadata.get("outputsSource", "unknown"),
        "Subscription ID": output_value(outputs, "subscription_id"),
        "Resource group": output_value(outputs, "resource_group_name"),
        "Checkpoint release": output_value(outputs, "checkpoint_os_version"),
        "Gateway VM": output_value(outputs, "checkpoint_vm_name"),
        "Gateway public IP": output_value(outputs, "checkpoint_public_ip"),
        "Gateway backend IP": output_value(
            outputs, "checkpoint_backend_private_ip"
        ),
        "CloudGuard image": image,
        "Image requires plan": output_value(
            outputs, "checkpoint_image_requires_plan"
        ),
        "Management CIDRs": output_value(outputs, "management_cidrs", []),
        "Policy package": output_value(outputs, "policy_package_name"),
        "Policy skipped in deployment state": output_value(
            outputs, "skip_policy_configuration"
        ),
        "Stage-two policy configuration requested": stage2.get(
            "configurePolicy", False
        ),
        "Temporary SSH rule created during validation": metadata.get(
            "temporarySshRuleCreated", False
        ),
        "Explicit public CA supplied": stage2.get("caFileProvided", False),
        "TLS inspection": output_value(outputs, "enable_tls_inspection"),
        "R81 TLS manually configured": output_value(
            outputs, "r81_tls_manually_configured"
        ),
        "Inbound demo": output_value(outputs, "enable_inbound_demo"),
        "Primary workload VM": output_value(outputs, "eu_workload_vm_name"),
        "Primary workload IP": output_value(
            outputs, "eu_workload_private_ip"
        ),
        "Remote workload VM": output_value(
            outputs, "remote_workload_vm_name"
        ),
        "Remote workload IP": output_value(
            outputs, "remote_workload_private_ip"
        ),
        "Log Analytics workspace": output_value(
            outputs, "log_analytics_workspace_customer_id"
        ),
        "Audit storage account": output_value(
            outputs, "audit_storage_account_name"
        ),
        "Audit container": output_value(outputs, "audit_container_name"),
        "Immutable retention days": output_value(
            outputs, "immutable_retention_days"
        ),
    }


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
            results.append(
                {
                    "id": case_id,
                    "title": CASE_TITLES.get(case_id, case_id),
                    "status": status,
                    "evidence": evidence,
                    "evidenceSha256": evidence_hash(evidence_path),
                }
            )
    return sorted(results, key=lambda item: int(item["id"][1:]))


def render_report(
    evidence_dir, generated_utc, overall_status, configuration, results
):
    lines = [
        "# CloudGuard Deployment Validation Report",
        "",
        f"- Generated (UTC): `{generated_utc}`",
        f"- Overall status: **{overall_status}**",
        f"- Evidence directory: `{evidence_dir.name}`",
        "",
        "## Configuration",
        "",
        "| Field | Value |",
        "| --- | --- |",
    ]
    for key, value in configuration.items():
        lines.append(f"| {key} | {markdown_value(value)} |")

    counts = {}
    for result in results:
        counts[result["status"]] = counts.get(result["status"], 0) + 1
    count_text = ", ".join(
        f"{status}={count}" for status, count in sorted(counts.items())
    )
    lines.extend(
        [
            "",
            "## Test results",
            "",
            count_text or "No test cases completed.",
            "",
            "| ID | Check | Status | Raw evidence | SHA-256 |",
            "| --- | --- | --- | --- | --- |",
        ]
    )
    for result in results:
        lines.append(
            "| {id} | {title} | **{status}** | `{evidence}` | `{digest}` |".format(
                id=result["id"],
                title=result["title"],
                status=result["status"],
                evidence=result["evidence"],
                digest=result["evidenceSha256"] or "missing",
            )
        )

    configure_log = evidence_dir / "configure-policy.log"
    if configure_log.is_file():
        lines.extend(
            [
                "",
                "## Stage-two configuration output",
                "",
                fenced(configure_log.read_text(encoding="utf-8", errors="replace")),
            ]
        )

    lines.extend(["", "## Actual test outputs"])
    if not results:
        lines.extend(["", "No raw test outputs were produced."])
    for result in results:
        evidence_path = evidence_dir / result["evidence"]
        if evidence_path.is_file():
            output = evidence_path.read_text(
                encoding="utf-8", errors="replace"
            )
        else:
            output = "Evidence file is missing."
        lines.extend(
            [
                "",
                f"### {result['id']} - {result['title']} - {result['status']}",
                "",
                f"Raw evidence: `{result['evidence']}`",
                "",
                fenced(output),
            ]
        )

    command_trace = evidence_dir / "commands.log"
    if command_trace.is_file():
        lines.extend(
            [
                "",
                "## Exact command trace",
                "",
                "This is the Bash execution trace captured during stage two.",
                "",
                fenced(
                    command_trace.read_text(
                        encoding="utf-8", errors="replace"
                    ),
                    "console",
                ),
            ]
        )

    run_log = evidence_dir / "run-tests.log"
    if run_log.is_file():
        lines.extend(
            [
                "",
                "## Test runner output",
                "",
                fenced(run_log.read_text(encoding="utf-8", errors="replace")),
            ]
        )

    cleanup_log = evidence_dir / "cleanup.log"
    if cleanup_log.is_file():
        lines.extend(
            [
                "",
                "## Cleanup output",
                "",
                fenced(cleanup_log.read_text(encoding="utf-8", errors="replace")),
            ]
        )

    return "\n".join(lines) + "\n"


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
    generated_utc = datetime.datetime.now(
        datetime.timezone.utc
    ).isoformat()
    if args.exit_code != 0:
        overall_status = "FAIL"
    elif any(result["status"] != "PASS" for result in results):
        overall_status = "PASS_WITH_NOTES"
    else:
        overall_status = "PASS"

    summary = {
        "schemaVersion": 2,
        "generatedUtc": generated_utc,
        "overallStatus": overall_status,
        "exitCode": args.exit_code,
        "configuration": configuration,
        "results": results,
        "note": (
            "SKIP and RECONCILED are not reported as PASS. RECONCILED means "
            "a temporary SSH NSG rule was created for validation and removed "
            "afterward. PENDING_INGESTION and FAIL produce a non-zero exit code."
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
    (evidence_dir / "report.md").write_text(
        render_report(
            evidence_dir,
            generated_utc,
            overall_status,
            configuration,
            results,
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
