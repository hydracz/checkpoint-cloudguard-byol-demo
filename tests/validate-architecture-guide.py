#!/usr/bin/env python3
"""Check the offline guide and editable diagrams without third-party packages."""

import base64
import ipaddress
import json
import re
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
SVG = "{http://www.w3.org/2000/svg}"


def require(condition, message):
    if not condition:
        raise SystemExit(f"ERROR: {message}")


class GuideParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []
        self.links = []
        self.images = []
        self.code_blocks = []
        self.visible_text = []
        self.in_pre = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        require(tag not in {"script", "iframe", "link"}, f"Unexpected external/active asset: {tag}")
        if "id" in attrs:
            self.ids.append(attrs["id"])
        if tag == "a":
            self.links.append(attrs)
        if tag == "img":
            self.images.append(attrs)
        if tag == "pre":
            self.in_pre = True
            self.code_blocks.append("")

    def handle_endtag(self, tag):
        if tag == "pre":
            self.in_pre = False

    def handle_data(self, data):
        self.visible_text.append(data)
        if self.in_pre:
            self.code_blocks[-1] += data


def embedded_bytes(uri):
    header, separator, payload = uri.partition(",")
    require(separator and header.startswith("data:") and header.endswith(";base64"),
            "An offline asset must be a base64 data URI.")
    return base64.b64decode(payload, validate=True)


def check_diagrams():
    for name in ("cloudguard-overview", "cloudguard-network"):
        scene = json.loads((DOCS / "diagrams" / f"{name}.excalidraw").read_text(encoding="utf-8"))
        elements = {element["id"]: element for element in scene["elements"]}
        require(len(elements) == len(scene["elements"]), f"{name}: duplicate element IDs")
        image = ET.parse(DOCS / "diagrams" / f"{name}.svg")
        for key, element in elements.items():
            if element["type"] == "text":
                require(element["fontFamily"] == 5, f"{name}/{key}: unexpected font family")
                require(element["text"] == element["originalText"], f"{name}/{key}: stale originalText")
                text = image.find(f'.//{SVG}text[@id="{key}"]')
                require(text is not None, f"{name}/{key}: missing SVG text")
                lines = "\n".join("".join(line.itertext()) for line in text.findall(f"{SVG}tspan"))
                require(lines == element["text"], f"{name}/{key}: SVG text differs from editable source")
            if element["type"] == "arrow":
                for field in ("startBinding", "endBinding"):
                    binding = element.get(field)
                    if binding:
                        target = elements[binding["elementId"]]
                        require(any(item["id"] == key for item in target.get("boundElements") or []),
                                f"{name}/{key}: missing reciprocal binding")
            for binding in element.get("boundElements") or []:
                arrow = elements[binding["id"]]
                targets = [
                    arrow[field]["elementId"]
                    for field in ("startBinding", "endBinding") if arrow.get(field)
                ]
                require(key in targets, f"{name}/{key}: bound arrow points elsewhere")
    drawio = ET.parse(DOCS / "checkpoint-cloudguard-byol-architecture.drawio")
    preview = ET.parse(DOCS / "checkpoint-cloudguard-byol-test-architecture.svg")
    for key in ("r-eu-rt", "r-bastion"):
        cell = drawio.find(f'.//mxCell[@id="{key}"]')
        text = preview.find(f'.//*[@data-cell-id="{key}"]//{SVG}text')
        require(cell is not None and text is not None, f"Missing draw.io preview cell: {key}")
        lines = "\n".join("".join(line.itertext()) for line in text.findall(f"{SVG}tspan"))
        require(lines == cell.get("value"), f"Stale draw.io preview label: {key}")


def check_guide():
    page = GuideParser()
    page.feed((DOCS / "architecture-and-walkthrough.html").read_text(encoding="utf-8"))
    require(len(page.ids) == len(set(page.ids)), "Duplicate HTML anchor IDs")
    assets = {
        path.name: path
        for path in (
            DOCS / "diagrams/cloudguard-overview.svg",
            DOCS / "diagrams/cloudguard-overview.excalidraw",
            DOCS / "diagrams/cloudguard-network.svg",
            DOCS / "diagrams/cloudguard-network.excalidraw",
            DOCS / "checkpoint-cloudguard-byol-architecture.drawio",
            DOCS / "checkpoint-cloudguard-byol-test-architecture.svg",
        )
    }
    downloads = set()
    for link in page.links:
        href = link.get("href", "")
        if href.startswith("#"):
            require(unquote(href[1:]) in page.ids, f"Broken HTML anchor: {href}")
        elif "download" in link:
            name = link["download"]
            require(name in assets, f"Unexpected embedded download: {name}")
            require(embedded_bytes(href) == assets[name].read_bytes(), f"Stale embedded download: {name}")
            downloads.add(name)
        else:
            require(href.startswith("https://"), f"Nonportable HTML link: {href}")
    require(downloads == set(assets), "Missing editable diagram downloads")
    require(len(page.images) == 2, "The offline guide must contain both diagram previews")
    for image, name in zip(page.images, ("cloudguard-overview.svg", "cloudguard-network.svg")):
        require(embedded_bytes(image["src"]) == assets[name].read_bytes(), f"Stale preview: {name}")

    expected_routes = {
        f"hub-inspect-{str(network).replace('.', '-').replace('/', '-')}"
        for network in ipaddress.ip_network("10.60.0.0/16").address_exclude(
            ipaddress.ip_network("10.60.4.0/26")
        )
    }
    require(set(re.findall(r"hub-inspect-[0-9-]+", "".join(page.visible_text))) == expected_routes,
            "The offline guide must include all ten precise Hub complement routes")
    source = (DOCS / "architecture-and-walkthrough.md").read_text(encoding="utf-8")
    code_blocks = [
        "\n".join(line[len(indent):] if line.startswith(indent) else line for line in body.splitlines())
        for indent, body in re.findall(r"(?m)^( *)```[^\n]*\n([\s\S]*?)^\1```[ \t]*(?:\n|$)", source)
    ]
    require(code_blocks == [block.rstrip("\n") for block in page.code_blocks],
            "HTML code examples differ from Markdown source")


if __name__ == "__main__":
    check_diagrams()
    check_guide()
    print("Architecture diagrams and offline guide assets are consistent.")
