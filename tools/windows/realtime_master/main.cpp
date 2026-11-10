// hako-realtime-master — 箱庭の時間を「壁時計に合わせて」進めるマスタ（Windows ネイティブ）
//
//   hako-realtime-master <tick_ms> <max_delay_ms> <stop_file> [speed]
//
// runtime の master_runner は「execute → sleep(tick)」を繰り返す。Windows では sleep の分解能が粗く
// （1 ms のつもりが数 ms〜15.6 ms）、箱庭の時間が実時間の 0.14 倍でしか進まなかった（devai_hako H2・2026-10-12）。
// こちらは execute() が時間を進めたとき（= 全アセットが追いついたとき）だけ、次の締め切り
//   t0 + 進めた回数 × tick / speed
// まで待つ。アセットが遅れているときは短く待って execute を繰り返す。遅れが 200 ms を超えたら基準をずらす
// （まとめて進めない）。タイマー分解能は timeBeginPeriod(1) で 1 ms に上げる。
#include <hako.hpp>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>
#include <thread>
#ifdef _WIN32
#include <windows.h>
#include <timeapi.h>
#endif

namespace {
volatile std::sig_atomic_t stopped = 0;
void Stop(int) { stopped = 1; }
}  // namespace

int main(int argc, char** argv) {
    if (argc < 4 || argc > 5) {
        std::cerr << "Usage: hako-realtime-master <tick_ms> <max_delay_ms> <stop_file> [speed]\n";
        return 2;
    }
    const int tick_ms = std::atoi(argv[1]);
    const int max_delay_ms = std::atoi(argv[2]);
    const std::filesystem::path stop_file(argv[3]);
    const double speed = argc == 5 ? std::atof(argv[4]) : 1.0;
    if (tick_ms <= 0 || max_delay_ms <= 0 || speed <= 0.0) {
        std::cerr << "tick_ms, max_delay_ms and speed must be positive\n";
        return 2;
    }
    if (std::filesystem::exists(stop_file)) {
        std::cerr << "Stop file already exists; use a fresh run directory\n";
        return 2;
    }
    std::signal(SIGINT, Stop);
    std::signal(SIGTERM, Stop);
#ifdef _WIN32
    timeBeginPeriod(1);
#endif
    if (!hako::init()) return 1;
    int result = 0;
    try {
        auto master = hako::create_master();
        if (!master) throw std::runtime_error("create_master failed");
        master->set_config_simtime(static_cast<HakoTimeType>(max_delay_ms) * 1000,
                                   static_cast<HakoTimeType>(tick_ms) * 1000);
        std::cout << "hako-realtime-master READY tick=" << tick_ms << "ms max_delay=" << max_delay_ms
                  << "ms speed=" << speed << std::endl;
        using clock = std::chrono::steady_clock;
        const auto tick = std::chrono::duration<double>(tick_ms / 1000.0 / speed);
        auto t0 = clock::now();
        long long advanced = 0, report_at = 0, lag_resets = 0, loops = 0;
        auto report_wall = clock::now();
        while (!stopped) {
            if ((++loops & 0x3ff) == 0 && std::filesystem::exists(stop_file)) break;
            if (master->execute()) {
                if (advanced == 0) {
                    t0 = clock::now();
                    report_wall = t0;
                }
                ++advanced;
                const auto deadline = t0 + std::chrono::duration_cast<clock::duration>(tick * advanced);
                const auto now = clock::now();
                if (now > deadline + std::chrono::milliseconds(200)) {
                    t0 += now - deadline;                  // 遅れすぎ: まとめて進めず基準をずらす
                    ++lag_resets;
                } else if (deadline > now) {
                    std::this_thread::sleep_until(deadline);
                }
                if (advanced - report_at >= 5000 / tick_ms) {   // 約 5 秒（箱庭時間）ごと
                    const double wall = std::chrono::duration<double>(clock::now() - report_wall).count();
                    const double sim = (advanced - report_at) * tick_ms / 1000.0;
                    std::cout << "[master] sim=" << advanced * tick_ms / 1000.0 << "s ratio=" << sim / wall
                              << " lag_resets=" << lag_resets << std::endl;
                    report_at = advanced;
                    report_wall = clock::now();
                }
            } else {
                std::this_thread::sleep_for(std::chrono::microseconds(200));   // アセット待ち・開始待ち
            }
        }
    } catch (const std::exception& error) {
        std::cerr << error.what() << std::endl;
        result = 1;
    }
    hako::destroy();
#ifdef _WIN32
    timeEndPeriod(1);
#endif
    std::cout << "hako-realtime-master EXIT " << result << std::endl;
    return result;
}
