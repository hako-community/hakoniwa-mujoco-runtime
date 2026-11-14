#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_endpoint_ffi.py (Linux) -- hakoniwa_pdu_endpoint の C 呼び出し部品（_c_endpoint_ffi*.so）を SDK に作る

  tools/windows/robo_sdk/build_endpoint_ffi.py の Linux 版。上流の build_c_endpoint_ffi.py から宣言（cdef）だけ借り、
  場所をローカル SDK に合わせて作る。pdu-endpoint は静的ライブラリ（PIC）、箱庭コアは SDK の共有ライブラリにリンクし、
  RUNPATH で SDK の lib を指すので LD_LIBRARY_PATH は要らない。

    build_endpoint_ffi.bash から呼ぶ（cffi の入った Python 3.12 で）:
      python build_endpoint_ffi.py <ROBO_ROOT>
    出力: <ROBO_ROOT>/sdk/linux-gcc-x64/sdk/hakoniwa-core/python/hakoniwa_pdu_endpoint/_c_endpoint_ffi*.so
"""
import importlib.util
import shutil
import sys
from pathlib import Path

ROBO = Path(sys.argv[1]).resolve()
SDK = ROBO / "sdk" / "linux-gcc-x64" / "sdk"
EP = SDK / "hakoniwa-pdu-endpoint"
CORE = SDK / "hakoniwa-core"
PKG = CORE / "python" / "hakoniwa_pdu_endpoint"
TMP = ROBO / "build" / "linux-gcc-x64" / "robo_sdk" / "endpoint_ffi"

spec = importlib.util.spec_from_file_location("upstream_ffi_build", PKG / "build_c_endpoint_ffi.py")
up = importlib.util.module_from_spec(spec)
spec.loader.exec_module(up)          # cdef（C 関数の宣言）が up.ffi に入る。configure_ffi は呼ばない

core_lib = CORE / "lib"
# 箱庭コアの静的ライブラリ（libhako.a など）があればそれを、無ければ共有ライブラリを使う
libs = ["hakoniwa_pdu_endpoint", "shakoc", "assets", "conductor"]
if (core_lib / "libhako.a").is_file() or (core_lib / "libhako.so").is_file():
    libs.append("hako")
up.ffi.set_source(
    "hakoniwa_pdu_endpoint._c_endpoint_ffi",
    '#include "hakoniwa/pdu/c_endpoint.h"',
    include_dirs=[str(EP / "include"), str(CORE / "include")],
    libraries=libs + ["stdc++", "pthread"],
    library_dirs=[str(EP / "lib"), str(core_lib)],
    runtime_library_dirs=[str(core_lib)],
)
TMP.mkdir(parents=True, exist_ok=True)
out = up.ffi.compile(tmpdir=str(TMP), verbose=True)
built = Path(out)
dst = PKG / built.name
shutil.copy2(built, dst)
print(f"[done] {dst}")
