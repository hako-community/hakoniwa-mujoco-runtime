cmake_minimum_required(VERSION 3.16)

project(hakoniwa-mujoco-runtime
    VERSION 1.0.0
    DESCRIPTION "MuJoCo backend + Hakoniwa asset runtime, split out of hakoniwa-mujoco-robots"
    LANGUAGES C CXX
)

# =============================================================================
# 位置づけ
#   hakoniwa-mujoco-sensor（上位・センサ）が依存する **下位レイヤ**。
#     sensor  ──依存──>  runtime  ──依存──>  hakoniwa-core / MuJoCo
#   逆方向の依存は持たない（sensors/** を一切参照しない）。
#
# 提供するもの
#   - 物理の型とインタフェース : primitive_types.hpp / physics.hpp / actuator.hpp
#   - MuJoCo バックエンド実装  : physics/physics_impl.hpp, actuator/*_impl.hpp（ヘッダオンリー）
#   - 共通ユーティリティ       : common/{update_scheduler,json_utils}.hpp
#   - 設定 JSON スキーマ       : config/json_config_utils.hpp
#   - 箱庭アセット基盤         : config/asset_manifest, runtime/hakoniwa_asset_lifecycle
# =============================================================================

option(HAKO_RUNTIME_BUILD_ASSET "Build Hakoniwa asset layer (needs hakoniwa-core / pdu-endpoint)" ON)

set(MUJOCO_INCLUDE_DIR "" CACHE PATH "Directory containing mujoco/mujoco.h")
set(HAKONIWA_INSTALL_PREFIX "/usr/local/hakoniwa" CACHE PATH "hakoniwa-core install prefix")
set(HAKONIWA_PDU_ENDPOINT_PREFIX "" CACHE PATH "hakoniwa_pdu_endpoint install prefix")
set(NLOHMANN_JSON_INCLUDE_DIR "" CACHE PATH "Directory containing nlohmann/json.hpp")

# このアーカイブは libmujoco をリンクしない（リンクは最終実行体の責務）。
# それでも **どの版のヘッダで physics_impl.hpp をコンパイルしたか** は効く:
# ヘッダと、最終実行体がリンクする libmujoco の版が違えば mjModel/mjData の
# レイアウトがずれ、ビルドは通って実行時に SEGV する。版の選択が 2 リポジトリに
# またがる分、上位レイヤ単独の不一致より原因を追いにくい。
# そこで探索順は
#   1) include と lib が揃っている root（＝リリース tarball）。上位の
#      hakoniwa-mujoco-sensor と同じ既定に着地させ、レイヤ間で版を揃える。
#   2) ヘッダしか無い場所
if(NOT MUJOCO_INCLUDE_DIR)
    foreach(_root
        "${CMAKE_CURRENT_SOURCE_DIR}/../../.cache/deps/mujoco_bin-src"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../../.cache/deps/mujoco_bin-src"
        "/usr/local"
        "/opt/mujoco")
        if(EXISTS "${_root}/include/mujoco/mujoco.h" AND EXISTS "${_root}/lib/libmujoco.so")
            set(MUJOCO_INCLUDE_DIR "${_root}/include")
            break()
        endif()
    endforeach()
endif()
if(NOT MUJOCO_INCLUDE_DIR)
    foreach(_cand "/usr/local/include")
        if(EXISTS "${_cand}/mujoco/mujoco.h")
            set(MUJOCO_INCLUDE_DIR "${_cand}")
            break()
        endif()
    endforeach()
endif()
if(NOT MUJOCO_INCLUDE_DIR)
    message(FATAL_ERROR "MUJOCO_INCLUDE_DIR を指定してください（mujoco/mujoco.h のある場所）")
endif()

# ヘッダの版を必ず表示する。レイヤをまたいだ突き合わせは、まずこれが見えないと
# できない（上位の hakoniwa-mujoco-sensor も同じ形式で表示する）。
# 隣に libmujoco.so があるならその場で版一致まで検査し、違えば configure を止める。
set(MUJOCO_LIB_DIR "" CACHE PATH "Directory containing libmujoco.so (版一致の検査に使う。リンクはしない)")
if(EXISTS "${MUJOCO_INCLUDE_DIR}/mujoco/mujoco.h")
    file(STRINGS "${MUJOCO_INCLUDE_DIR}/mujoco/mujoco.h" _mj_ver_line
         REGEX "^#define +mjVERSION_HEADER +[0-9]+")
    if(_mj_ver_line MATCHES "([0-9]+)$")
        set(_mj_v "${CMAKE_MATCH_1}")
        math(EXPR _mj_major "${_mj_v} / 1000000")
        math(EXPR _mj_minor "(${_mj_v} / 1000) % 1000")
        math(EXPR _mj_patch "${_mj_v} % 1000")
        set(MUJOCO_HEADER_VERSION "${_mj_major}.${_mj_minor}.${_mj_patch}")
        message(STATUS "MuJoCo header version: ${MUJOCO_HEADER_VERSION} (${MUJOCO_INCLUDE_DIR})")

        if(NOT MUJOCO_LIB_DIR)
            get_filename_component(_mj_root "${MUJOCO_INCLUDE_DIR}" DIRECTORY)
            if(EXISTS "${_mj_root}/lib/libmujoco.so")
                set(MUJOCO_LIB_DIR "${_mj_root}/lib")
            endif()
        endif()
        if(MUJOCO_LIB_DIR AND EXISTS "${MUJOCO_LIB_DIR}/libmujoco.so")
            get_filename_component(_mj_real "${MUJOCO_LIB_DIR}/libmujoco.so" REALPATH)
            if(_mj_real MATCHES "libmujoco\\.so\\.([0-9]+\\.[0-9]+\\.[0-9]+)")
                set(_mj_lib_ver "${CMAKE_MATCH_1}")
                if(NOT MUJOCO_HEADER_VERSION VERSION_EQUAL _mj_lib_ver)
                    message(FATAL_ERROR
                        "MuJoCo のヘッダとライブラリの版が一致しません。\n"
                        "  header ${MUJOCO_HEADER_VERSION}: ${MUJOCO_INCLUDE_DIR}\n"
                        "  lib    ${_mj_lib_ver}: ${_mj_real}\n"
                        "このヘッダで組んだ成果物を、その libmujoco をリンクする実行体に"
                        "混ぜると実行時に SEGV します。"
                        "include と lib を同じ root から組で指定してください:\n"
                        "  cmake -S . -B build -DMUJOCO_INCLUDE_DIR=<root>/include "
                        "-DMUJOCO_LIB_DIR=<root>/lib")
                endif()
                message(STATUS "MuJoCo version check: header/lib とも ${_mj_lib_ver}")
            endif()
        endif()
    endif()
endif()

# --- ライブラリ本体 -----------------------------------------------------------
set(_runtime_srcs src/config/asset_manifest.cpp)
if(HAKO_RUNTIME_BUILD_ASSET)
    list(APPEND _runtime_srcs src/runtime/hakoniwa_asset_lifecycle.cpp)
endif()

add_library(hako_mujoco_runtime STATIC ${_runtime_srcs})
target_compile_features(hako_mujoco_runtime PUBLIC cxx_std_20)

target_include_directories(hako_mujoco_runtime PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_include_directories(hako_mujoco_runtime SYSTEM PUBLIC
    ${MUJOCO_INCLUDE_DIR}
    ${HAKONIWA_INSTALL_PREFIX}/include
    ${HAKONIWA_INSTALL_PREFIX}/include/hakoniwa       # hako_asset.h / hako_conductor.h
    ${HAKONIWA_INSTALL_PREFIX}/include/hakoniwa/pdu   # 生成 PDU 型ヘッダ
)
if(NLOHMANN_JSON_INCLUDE_DIR)
    target_include_directories(hako_mujoco_runtime SYSTEM PUBLIC ${NLOHMANN_JSON_INCLUDE_DIR})
endif()
if(HAKONIWA_PDU_ENDPOINT_PREFIX)
    target_include_directories(hako_mujoco_runtime SYSTEM PUBLIC
        ${HAKONIWA_PDU_ENDPOINT_PREFIX}/include)
endif()

# libmujoco / hakoniwa-core のリンクは最終実行体（PLANT）の責務。
# このアーカイブはヘッダ解決だけを保証する。
