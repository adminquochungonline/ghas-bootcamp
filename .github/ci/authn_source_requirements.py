#!/usr/bin/env python3
"""Sinh danh sách gói để kiểm tra authn-service theo phiên bản trong authn-service/requirements.txt.

Image triển khai (deploy/azure/authn-service) cài requirements.runtime.txt, nên PR chỉ sửa
authn-service/requirements.txt (phần lớn PR pip của Dependabot) không làm image thay đổi.
Bản thân requirements.txt cũng không cài nguyên vẹn được trên Python hiện đại vì chứa các gói
cố ý cũ cho lab (PyGObject, pycrypto, cryptography 2.6.1...).

Script này lấy danh sách gói app thực sự dùng từ requirements.runtime.txt, nhưng ưu tiên
phiên bản ghi trong authn-service/requirements.txt. Gói chỉ có trong runtime (vd gunicorn)
giữ nguyên phiên bản runtime.

Cách dùng: authn_source_requirements.py <requirements.txt> <requirements.runtime.txt> <output>
"""
import re
import sys

NAME_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)")


def normalize(name: str) -> str:
    # PEP 503: không phân biệt hoa thường và các ký tự - _ .
    return re.sub(r"[-_.]+", "-", name).lower()


def read_pins(path: str) -> dict:
    pins = {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            m = NAME_RE.match(line)
            if m:
                pins[normalize(m.group(1))] = line
    return pins


def main(source_path: str, runtime_path: str, out_path: str) -> int:
    source = read_pins(source_path)
    runtime = read_pins(runtime_path)
    resolved = []
    for name, runtime_pin in runtime.items():
        pin = source.get(name, runtime_pin)
        origin = "requirements.txt" if name in source else "runtime"
        resolved.append(pin)
        print(f"  {pin:<32} ({origin})")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(resolved) + "\n")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(*sys.argv[1:]))
