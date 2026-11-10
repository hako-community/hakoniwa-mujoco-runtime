#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_endpoint_ffi.py — hakoniwa_pdu_endpoint（Python）の C 呼び出し部品（_c_endpoint_ffi.pyd）を SDK に作る

  SDK に入る hakoniwa_pdu_endpoint は Python 部分だけで、C ライブラリを呼ぶ cffi の部品が無い
  （import すると ModuleNotFoundError: _c_endpoint_ffi）。上流の build_c_endpoint_ffi.py は上流リポジトリの
  並び（include/・build/）を前提に場所を探すので、宣言（cdef）だけ借り、場所をローカル SDK に合わせて作る。
  pdu-endpoint と箱庭コアは静的ライブラリとしてリンクするので、DLL は要らない。

    build_endpoint_ffi.ps1 から呼ぶ（VS 2022 x64 の開発者環境・cffi の入った Python 3.12 で）:
      python build_endpoint_ffi.py <RoboRoot>
    出力: <RoboRoot>/sdk/windows-msvc-x64/sdk/hakoniwa-core/python/hakoniwa_pdu_endpoint/_c_endpoint_ffi*.pyd
"""
import importlib.util
import shutil
import sys
from pathlib import Path

ROBO = Path(sys.argv[1]).resolve()
SDK = ROBO / "sdk" / "windows-msvc-x64" / "sdk"
EP = SDK / "hakoniwa-pdu-endpoint"
CORE = SDK / "hakoniwa-core"
PKG = CORE / "python" / "hakoniwa_pdu_endpoint"
TMP = ROBO / "build" / "windows-msvc-x64" / "robo_sdk" / "endpoint_ffi"

spec = importlib.util.spec_from_file_location("upstream_ffi_build", PKG / "build_c_endpoint_ffi.py")
up = importlib.util.module_from_spec(spec)
spec.loader.exec_module(up)          # cdef（C 関数の宣言）が up.ffi に入る。configure_ffi は呼ばない

up.ffi.set_source(
    "hakoniwa_pdu_endpoint._c_endpoint_ffi",
    '#include "hakoniwa/pdu/c_endpoint.h"',
    include_dirs=[str(EP / "include"), str(CORE / "include")],
    libraries=["hakoniwa_pdu_endpoint", "shakoc", "assets", "conductor", "hako", "ws2_32", "mswsock", "advapi32"],
    library_dirs=[str(EP / "lib"), str(CORE / "lib")],
    extra_compile_args=["/utf-8"],
)
TMP.mkdir(parents=True, exist_ok=True)
out = up.ffi.compile(tmpdir=str(TMP), verbose=True)
built = Path(out)
dst = PKG / built.name
shutil.copy2(built, dst)
print(f"[done] {dst}")
