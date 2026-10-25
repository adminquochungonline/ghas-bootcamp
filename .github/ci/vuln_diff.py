#!/usr/bin/env python3
"""So sánh kết quả Trivy (JSON) của PR với nhánh base và quyết định gate CVE.

Repo này cố ý chứa nhiều dependency có lỗ hổng (phục vụ lab GHAS), nên gate tuyệt đối
"không có HIGH/CRITICAL" sẽ luôn fail. Gate ở đây là: PR không được *đưa thêm* CVE có
mức nghiêm trọng thuộc --severities so với base. CVE đã có sẵn vẫn được báo cáo đầy đủ.

Một CVE được coi là "đã có ở base" nếu cùng (vị trí, CVE, package), không xét version:
bump version mà CVE vẫn còn thì không phải lỗ hổng mới do PR đưa vào.
Vị trí = file manifest/thư viện (lang-pkgs) hoặc "os" cho package hệ điều hành của image.

Cách dùng:
  vuln_diff.py --name authn-service --head head.json [--base base.json] \
               [--severities HIGH,CRITICAL] [--report report.md]
Không có --base (service mới, base build lỗi): chỉ báo cáo, không chặn.

Exit code: 0 = pass, 1 = có CVE mới bị chặn.
"""
import argparse
import json
import os
import sys
from collections import Counter

ORDER = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]


def load(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    vulns = {}
    for result in data.get("Results") or []:
        location = "os" if result.get("Class") == "os-pkgs" else result.get("Target", "")
        for v in result.get("Vulnerabilities") or []:
            key = (location, v.get("VulnerabilityID"), v.get("PkgName"))
            vulns[key] = {
                "id": v.get("VulnerabilityID", ""),
                "pkg": v.get("PkgName", ""),
                "installed": v.get("InstalledVersion", ""),
                "fixed": v.get("FixedVersion") or "-",
                "severity": (v.get("Severity") or "UNKNOWN").upper(),
                "title": md((v.get("Title") or "")[:90]),
                "location": location,
            }
    return vulns


def md(text: str) -> str:
    return str(text).replace("|", "\\|").replace("\n", " ")


def rank(v):
    return ORDER.index(v["severity"]) if v["severity"] in ORDER else len(ORDER)


def counts(vulns):
    c = Counter(v["severity"] for v in vulns.values())
    return " · ".join(f"{s} **{c.get(s, 0)}**" for s in ORDER[:4])


def table(rows, limit):
    out = ["| Severity | CVE | Package | Installed | Fixed | Vị trí | Mô tả |", "|---|---|---|---|---|---|---|"]
    for v in rows[:limit]:
        out.append(f"| {v['severity']} | {v['id']} | {md(v['pkg'])} | {md(v['installed'])} | "
                   f"{md(v['fixed'])} | {md(v['location'])} | {v['title']} |")
    if len(rows) > limit:
        out.append(f"\n_… và {len(rows) - limit} dòng khác, xem file JSON trong artifact._")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--head", required=True)
    ap.add_argument("--base")
    ap.add_argument("--severities", default="HIGH,CRITICAL")
    ap.add_argument("--report")
    ap.add_argument("--max-rows", type=int, default=30)
    args = ap.parse_args()

    gate = {s.strip().upper() for s in args.severities.split(",") if s.strip()}
    head = load(args.head)
    base = load(args.base) if args.base and os.path.exists(args.base) else None

    lines = [f"- CVE hiện có (PR): {counts(head)}"]
    blocking = []
    if base is None:
        lines.append("- ⚠️ Không có kết quả base để so sánh: chỉ báo cáo, không chặn.")
        existing = sorted((v for v in head.values() if v["severity"] in gate), key=rank)
        if existing:
            lines += ["", f"<details><summary>{len(existing)} CVE {'/'.join(sorted(gate))}</summary>", ""]
            lines += table(existing, args.max_rows) + ["", "</details>"]
    else:
        new = [v for k, v in head.items() if k not in base]
        fixed = [v for k, v in base.items() if k not in head]
        blocking = sorted((v for v in new if v["severity"] in gate), key=rank)
        lines.append(f"- CVE ở base: {counts(base)}")
        lines.append(f"- CVE mới do PR đưa vào: **{len(new)}**, trong đó {'/'.join(sorted(gate))}: **{len(blocking)}**")
        lines.append(f"- CVE được PR khắc phục: **{len(fixed)}**")
        if blocking:
            lines += ["", f"**CVE mới bị chặn ({len(blocking)}):**", ""] + table(blocking, args.max_rows)
        fixed_gate = sorted((v for v in fixed if v["severity"] in gate), key=rank)
        if fixed_gate:
            lines += ["", f"<details><summary>{len(fixed_gate)} CVE {'/'.join(sorted(gate))} được khắc phục</summary>", ""]
            lines += table(fixed_gate, args.max_rows) + ["", "</details>"]

    text = "\n".join(lines) + "\n"
    print(text)
    if args.report:
        with open(args.report, "w", encoding="utf-8") as f:
            f.write(text)
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
