#!/usr/bin/env python3
import argparse
import ipaddress
import json


MANAGEMENT_PORTS = {22, 443, 18190, 19009}
PRIVATE_NETWORKS = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
]
SAFE_SERVICE_TAGS = {"virtualnetwork", "azureloadbalancer"}


def port_spec_covers_management(spec):
    if spec == "*":
        return True
    try:
        if "-" in spec:
            start, end = (int(value) for value in spec.split("-", 1))
            return any(start <= port <= end for port in MANAGEMENT_PORTS)
        return int(spec) in MANAGEMENT_PORTS
    except (TypeError, ValueError):
        return True


def source_is_private(source):
    if source.lower() in SAFE_SERVICE_TAGS:
        return True
    try:
        network = ipaddress.ip_network(source, strict=False)
    except ValueError:
        return False
    return network.version == 4 and any(
        network.subnet_of(private_network) for private_network in PRIVATE_NETWORKS
    )


def rules_are_safe(rules):
    for rule in rules:
        if (
            rule.get("direction", "").lower() != "inbound"
            or rule.get("access", "").lower() != "allow"
        ):
            continue
        port_specs = rule.get("destinationPortRanges") or [
            rule.get("destinationPortRange", "")
        ]
        if not any(port_spec_covers_management(spec) for spec in port_specs):
            continue
        sources = rule.get("sourceAddressPrefixes") or [
            rule.get("sourceAddressPrefix", "")
        ]
        if not sources or any(not source_is_private(source) for source in sources):
            return False
    return True


def self_test():
    assert rules_are_safe(
        [
            {
                "direction": "Inbound",
                "access": "Allow",
                "destinationPortRange": "*",
                "sourceAddressPrefix": "10.61.0.0/16",
            }
        ]
    )
    assert not rules_are_safe(
        [
            {
                "direction": "Inbound",
                "access": "Allow",
                "destinationPortRange": "443",
                "sourceAddressPrefix": "203.0.113.10/32",
            }
        ]
    )
    assert not rules_are_safe(
        [
            {
                "direction": "Inbound",
                "access": "Allow",
                "destinationPortRange": "1-65535",
                "sourceAddressPrefix": "Internet",
            }
        ]
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", nargs="?")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return
    if not args.evidence:
        parser.error("evidence is required unless --self-test is used")
    with open(args.evidence, encoding="utf-8") as source:
        rules = json.load(source)
    if not rules_are_safe(rules):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
