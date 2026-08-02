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
