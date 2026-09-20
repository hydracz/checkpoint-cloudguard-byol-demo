#!/usr/bin/env python3
"""Export the architecture guide with embedded diagrams and editable downloads."""

import base64
import json
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
SOURCE = DOCS / "architecture-and-walkthrough.md"
OUTPUT = SOURCE.with_suffix(".html")
GITHUB = "https://github.com/hydracz/checkpoint-cloudguard-byol-demo/blob/main/"
ASSETS = {
    DOCS / "diagrams/cloudguard-overview.svg": "image/svg+xml",
    DOCS / "diagrams/cloudguard-overview.excalidraw": "application/json",
    DOCS / "diagrams/cloudguard-network.svg": "image/svg+xml",
    DOCS / "diagrams/cloudguard-network.excalidraw": "application/json",
    DOCS / "checkpoint-cloudguard-byol-architecture.drawio": "application/xml",
    DOCS / "checkpoint-cloudguard-byol-test-architecture.svg": "image/svg+xml",
}


def pandoc(text, *options):
    result = subprocess.run(
        ["pandoc", "--sandbox", *options],
        input=text, capture_output=True, encoding="utf-8", cwd=ROOT,
    )
    if result.returncode:
        raise SystemExit(result.stderr.strip() or f"Pandoc exited with code {result.returncode}.")
    if result.stderr:
        print(result.stderr.strip(), file=sys.stderr)
    return result.stdout


def rewrite_links(node, assets):
    if isinstance(node, list):
        for child in node:
            rewrite_links(child, assets)
    elif isinstance(node, dict):
        for child in node.values():
            rewrite_links(child, assets)
        if node.get("t") not in {"Link", "Image"}:
            return
        attributes, _, destination = node["c"]
        target = urlsplit(destination[0])
        if target.scheme or target.netloc or not target.path:
            if node["t"] == "Image":
                raise ValueError("Offline guide images must use the declared local diagram assets.")
            return
        path = (DOCS / unquote(target.path)).resolve()
        relative = path.relative_to(ROOT)
        if path in assets:
            destination[0] = assets[path]
            if node["t"] == "Link":
                attributes[2].append(["download", path.name])
            else:
                attributes[1].append("architecture-diagram")
        elif node["t"] == "Image":
            raise ValueError(f"Undeclared offline image: {relative}")
        else:
            destination[0] = GITHUB + quote(relative.as_posix())
            if target.fragment:
                destination[0] += "#" + quote(target.fragment)


def main():
    if not shutil.which("pandoc"):
        raise SystemExit("ERROR: Pandoc is required to regenerate the optional HTML guide.")
    source = SOURCE.read_text(encoding="utf-8")
    document = json.loads(pandoc(source, "--from=gfm", "--to=json"))
    assets = {
        path: f"data:{mime};base64,{base64.b64encode(path.read_bytes()).decode('ascii')}"
        for path, mime in ASSETS.items()
    }
    rewrite_links(document, assets)
    document["meta"]["pagetitle"] = {"t": "MetaString", "c": source.splitlines()[0].removeprefix("# ")}
    rendered = pandoc(
        json.dumps(document, ensure_ascii=False),
        "--from=json", "--to=html5", "--standalone", "--toc", "--toc-depth=3", "--wrap=none",
        f"--template={DOCS / 'templates/architecture-guide.html'}",
    )
    OUTPUT.write_text(rendered, encoding="utf-8")
    print(f"Exported {OUTPUT.relative_to(ROOT)} ({OUTPUT.stat().st_size:,} bytes).")


if __name__ == "__main__":
    main()
