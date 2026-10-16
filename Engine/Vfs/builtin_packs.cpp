#include "builtin_packs.h"
#include <Windows.h>
#include <miniz.h>
#include <algorithm>
#include <format>
#include <fstream>
#include <span>
#include <string_view>

namespace dingosdk::mods {
namespace {
namespace fs = std::filesystem;
// Each pack: its RCDATA resource in ReSkate.dll (cmake/Runtime.cmake) and its folder name.
struct Embedded {
    const wchar_t* resource;
    const char* name;
};
constexpr Embedded embedded[]{{L"BUILTIN_PACK_FPV_DRONE", "fpv_drone"}};
constexpr std::uint64_t max_pack_bytes = 512ull * 1024 * 1024;
constexpr std::string_view version_file = ".builtin-version";

struct Source {
    HMODULE module{};
    bool owned{};
    Source() = default;
    Source(const Source&) = delete;
    Source& operator=(const Source&) = delete;
    ~Source() {
        if (owned && module) FreeLibrary(module);
    }
};
bool carries_packs(HMODULE module) {
    return module && FindResourceW(module, embedded[0].resource, MAKEINTRESOURCEW(10) /* RT_RCDATA */);
}
// ReSkate.dll: this module when it is the DLL (the game), else ReSkate.dll beside the program
// (the launcher, which sits beside Skate.exe and the DLL), as data only.
void open_source(Source& source) {
    HMODULE self{};
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCWSTR>(&carries_packs), &self) && carries_packs(self)) {
        source.module = self;
        return;
    }
    if (const auto loaded = GetModuleHandleW(L"ReSkate.dll"); carries_packs(loaded)) {
        source.module = loaded;
        return;
    }
    std::wstring program(32768, L'\0');
    const auto length = GetModuleFileNameW(nullptr, program.data(), static_cast<DWORD>(program.size()));
    if (!length || length >= program.size()) return;
    program.resize(length);
    const auto dll = fs::path(program).parent_path() / L"ReSkate.dll";
    source.module = LoadLibraryExW(dll.c_str(), nullptr, LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
    source.owned = source.module != nullptr;
}
std::span<const unsigned char> resource_bytes(HMODULE module, const wchar_t* name) {
    const auto resource = FindResourceW(module, name, MAKEINTRESOURCEW(10));
    if (!resource) return {};
    const auto loaded = LoadResource(module, resource);
    const auto size = SizeofResource(module, resource);
    const auto* data = loaded ? static_cast<const unsigned char*>(LockResource(loaded)) : nullptr;
    return data && size ? std::span<const unsigned char>(data, size) : std::span<const unsigned char>{};
}
// Which build of a pack this is: enough to tell when the one embedded changed.
std::string version_of(std::span<const unsigned char> bytes) {
    std::uint64_t hash = 0xcbf29ce484222325ULL;
    for (const auto byte : bytes) hash = (hash ^ byte) * 0x100000001b3ULL;
    return std::format("{:016x}-{}", hash, bytes.size());
}
std::string read_text(const fs::path& path) {
    std::ifstream input(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}
// A path inside the pack: relative, forward slashes, no "..", plain characters.
bool safe_entry(std::string_view name) {
    if (name.empty() || name.size() > 260 || name.front() == '/' || name.find(':') != std::string_view::npos ||
        name.find('\\') != std::string_view::npos)
        return false;
    std::size_t start = 0;
    while (start <= name.size()) {
        const auto end = std::min(name.find('/', start), name.size());
        const auto part = name.substr(start, end - start);
        if (part.empty() || part == "." || part == "..") return false;
        if (!std::all_of(part.begin(), part.end(), [](char c) {
                return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
            }))
            return false;
        start = end + 1;
    }
    return true;
}
bool unpack(std::span<const unsigned char> bytes, const fs::path& target, std::string& issue) {
    struct Zip {
        mz_zip_archive value{};
        ~Zip() { mz_zip_reader_end(&value); }
    } zip;
    if (!mz_zip_reader_init_mem(&zip.value, bytes.data(), bytes.size(), 0)) {
        issue = "the embedded pack is not a zip";
        return false;
    }
    const auto count = mz_zip_reader_get_num_files(&zip.value);
    std::uint64_t total{};
    for (mz_uint index = 0; index < count; ++index) {
        mz_zip_archive_file_stat info{};
        if (!mz_zip_reader_file_stat(&zip.value, index, &info) || info.m_is_encrypted) {
            issue = "the embedded pack has an unreadable entry";
            return false;
        }
        if (info.m_is_directory) continue;
        total += info.m_uncomp_size;
        if (!safe_entry(info.m_filename) || total > max_pack_bytes) {
            issue = std::string("the embedded pack has an entry it may not: ") + info.m_filename;
            return false;
        }
        const auto path = target / fs::path(info.m_filename);
        fs::create_directories(path.parent_path());
        struct File {
            HANDLE value;
            ~File() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
        } file{CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr)};
        struct Sink {
            HANDLE file;
            std::uint64_t written{}, limit;
        } sink{file.value, 0, info.m_uncomp_size};
        const auto write = [](void* opaque, mz_uint64 offset, const void* buffer, size_t size) -> size_t {
            auto& target = *static_cast<Sink*>(opaque);
            if (offset != target.written || size > target.limit - target.written) return 0;
            DWORD done{};
            if (!WriteFile(target.file, buffer, static_cast<DWORD>(size), &done, nullptr) || done != size) return 0;
            target.written += size;
            return size;
        };
        if (file.value == INVALID_HANDLE_VALUE || !mz_zip_reader_extract_to_callback(&zip.value, index, write, &sink, 0) ||
            sink.written != info.m_uncomp_size) {
            issue = std::string("could not unpack ") + info.m_filename;
            return false;
        }
    }
    return true;
}
} // namespace

std::vector<BuiltinPack> unpack_builtin_packs(const fs::path& mods_root, std::vector<std::string>& notes) noexcept {
    std::vector<BuiltinPack> packs;
    try {
        Source source;
        open_source(source);
        if (!source.module) return packs;
        for (const auto& pack : embedded) {
            const auto bytes = resource_bytes(source.module, pack.resource);
            if (bytes.empty()) continue;
            const auto directory = mods_root / std::string(builtin_folder) / pack.name;
            const auto version = version_of(bytes);
            std::error_code error;
            if (read_text(directory / version_file) != version) {
                // Unpacked beside it, then swapped in: a pack is never half there.
                const auto staging = fs::path(directory.wstring() + std::format(L".unpacking-{}", GetCurrentProcessId()));
                fs::remove_all(staging, error);
                std::string issue;
                if (!unpack(bytes, staging, issue)) {
                    fs::remove_all(staging, error);
                    notes.push_back(std::format("Built-in content {} could not be unpacked: {}", pack.name, issue));
                    continue;
                }
                std::ofstream(staging / version_file, std::ios::binary) << version;
                fs::remove_all(directory, error);
                fs::rename(staging, directory, error);
                if (error) {
                    fs::remove_all(staging, error);
                    notes.push_back(std::format("Built-in content {} could not be put in place ({})", pack.name, error.message()));
                    continue;
                }
                notes.push_back(std::format("Built-in content {} unpacked ({} bytes)", pack.name, bytes.size()));
            }
            packs.push_back({std::string("reskate-builtin-") + pack.name, directory});
        }
    } catch (const std::exception& failure) {
        notes.push_back(std::string("Built-in content could not be prepared: ") + failure.what());
    }
    return packs;
}
} // namespace dingosdk::mods
