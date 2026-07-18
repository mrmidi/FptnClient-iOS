#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <sstream>
#include <chrono>
#include "SwiftApiClient.h"

struct ServerConfig {
    std::string name;
    std::string host;
    int port;
    std::string md5_fingerprint;
};

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <config_txt_path>" << std::endl;
        return 1;
    }

    std::string config_path = argv[1];
    std::ifstream f(config_path);
    if (!f.is_open()) {
        std::cerr << "Failed to open config file: " << config_path << std::endl;
        return 1;
    }

    std::string username, password, strategy, sni;
    if (!std::getline(f, username) || !std::getline(f, password) || 
        !std::getline(f, strategy) || !std::getline(f, sni)) {
        std::cerr << "Failed to read header info from config" << std::endl;
        return 1;
    }

    std::cout << "Loaded credentials for: " << username << std::endl;
    std::cout << "Using censorship strategy: " << strategy << std::endl;
    std::cout << "Using SNI: " << sni << std::endl;

    std::vector<ServerConfig> servers;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty()) continue;
        std::stringstream ss(line);
        std::string name, host, port_str, md5;
        if (std::getline(ss, name, '|') && std::getline(ss, host, '|') && 
            std::getline(ss, port_str, '|') && std::getline(ss, md5, '|')) {
            servers.push_back({name, host, std::stoi(port_str), md5});
        }
    }

    std::cout << "Found " << servers.size() << " servers to test." << std::endl;
    std::cout << "--------------------------------------------------" << std::endl;

    for (const auto& s : servers) {
        std::cout << "\n[Server: " << s.name << " (" << s.host << ":" << s.port << ")]" << std::endl;

        SwiftApiClient client(
            s.host,
            s.port,
            sni,
            s.md5_fingerprint,
            strategy
        );

        // 1. Test Handshake
        std::cout << "  1. Testing testHandshake() API..." << std::endl;
        auto start = std::chrono::steady_clock::now();
        auto handshake = client.testHandshake(5);
        auto end = std::chrono::steady_clock::now();
        int latency = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();

        if (handshake.reachable) {
            std::cout << "     \033[32m✓ Handshake succeeded\033[0m (reported latency: " 
                      << handshake.latency_ms << "ms, real time: " << latency << "ms)" << std::endl;
        } else {
            std::cout << "     \033[31m✗ Handshake failed\033[0m: " << handshake.errmsg 
                      << " (real time: " << latency << "ms)" << std::endl;
        }

        // 2. Test HTTP POST login
        std::cout << "  2. Testing post(\"/api/v1/login\") API..." << std::endl;
        std::string request_body = "{\"username\":\"" + username + "\",\"password\":\"" + password + "\"}";
        
        start = std::chrono::steady_clock::now();
        auto response = client.post("/api/v1/login", request_body, 5);
        end = std::chrono::steady_clock::now();
        latency = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();

        std::cout << "     Response code: " << response.code << " (real time: " << latency << "ms)" << std::endl;
        if (response.code == 200) {
            std::cout << "     \033[32m✓ Login succeeded!\033[0m" << std::endl;
            if (response.body.length() > 50) {
                std::cout << "     ✓ Received token: " << response.body.substr(0, 45) << "..." << std::endl;
            } else {
                std::cout << "     ✓ Received body: " << response.body << std::endl;
            }
        } else {
            std::cout << "     \033[31m✗ Login failed!\033[0m Error: " << response.errmsg << std::endl;
            if (!response.body.empty()) {
                std::cout << "       Body: " << response.body << std::endl;
            }
        }
    }

    std::cout << "\n--------------------------------------------------" << std::endl;
    std::cout << "Diagnostics complete." << std::endl;
    return 0;
}
