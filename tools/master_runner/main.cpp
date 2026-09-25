#include <hako.hpp>
#include <charconv>
#include <chrono>
#include <csignal>
#include <filesystem>
#include <iostream>
#include <string_view>
#include <thread>

namespace {
volatile std::sig_atomic_t stopped = 0;
void Stop(int) { stopped = 1; }
bool Milliseconds(std::string_view text, int& value) {
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);
    return parsed.ec == std::errc{} && parsed.ptr == text.data() + text.size() &&
           value > 0 && value <= 60'000;
}
}

// An application-owned entry point using the installed core's public API.
// The upstream hako-master source and executable are not used.
int main(int argc, char** argv) {
    int tick_ms = 0, max_delay_ms = 0;
    if (argc != 4 || !Milliseconds(argv[1], tick_ms) ||
        !Milliseconds(argv[2], max_delay_ms)) {
        std::cerr << "Usage: hako-runtime-master <tick_ms> <max_delay_ms> <stop_file>\n";
        return 2;
    }
    const std::filesystem::path stop_file(argv[3]);
    if (std::filesystem::exists(stop_file)) {
        std::cerr << "Stop file already exists; use a fresh run directory\n";
        return 2;
    }
    std::signal(SIGINT, Stop);
    std::signal(SIGTERM, Stop);
    if (!hako::init()) return 1;
    int result = 0;
    try {
        // Destroy the controller before releasing the process-wide core.
        auto master = hako::create_master();
        if (!master) throw std::runtime_error("create_master failed");
        master->set_config_simtime(max_delay_ms * 1000, tick_ms * 1000);
        std::cout << "hako-runtime-master READY" << std::endl;
        while (!stopped && !std::filesystem::exists(stop_file)) {
            master->execute();
            std::this_thread::sleep_for(std::chrono::milliseconds(tick_ms));
        }
    } catch (const std::exception& error) {
        std::cerr << error.what() << std::endl;
        result = 1;
    }
    hako::destroy();
    std::cout << "hako-runtime-master EXIT " << result << std::endl;
    return result;
}
