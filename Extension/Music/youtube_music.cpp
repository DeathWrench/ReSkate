#include "youtube_music.h"
#include "app_audio_capture.h"
#include "spotify_cover.h"
#include "local_music_ui.h"
#include "Engine/Core/Json/json.h"
#include "Engine/Core/Log/logging.h"
#include "Engine/Vfs/https_download.h"
#include "Extension/Boot/user_data_redirect.h"
#include <Windows.h>
#include <bcrypt.h>
#include <objbase.h>
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <format>
#include <fstream>
#include <mutex>
#include <thread>

#if DINGOSDK_SPOTIFY_DEVICE
// SpotifyHelper/src/stream.rs, linked into the DLL (cmake/Runtime.cmake).
extern "C" {
std::uint64_t reskate_stream_play(const char* program, const char* arguments, void (*sound)(const float* samples, std::uint32_t frames, std::uint32_t rate),
    void (*ended)(std::uint64_t stream, const char* how));
void reskate_stream_stop();
}
#endif

namespace dingosdk::youtube_music {
namespace {
constexpr wchar_t agent[] = L"ReSkate";
constexpr wchar_t tool_address[] = L"https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe";
constexpr wchar_t runtime_address[] = L"https://github.com/quickjs-ng/quickjs/releases/latest/download/qjs-windows-x86_64.exe";
constexpr wchar_t sums_address[] = L"https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS";
constexpr std::size_t most_songs = 100, most_playlists = 12;

std::mutex mutex; // everything below it
std::condition_variable wake;
std::deque<std::string> commands; // "tools", "add <link>", "covers"
std::vector<Playlist> library;
std::string problem_text, browser_name;
bool is_busy{}, have_tools{}, have_cookies{};
std::atomic<bool> started{}, is_on{}, paused{};
std::atomic<unsigned> sound_rate{44100}, fetched_percent{};
https::Watch tool_watch;
// What is playing.
std::size_t playing_list{}, playing_song{};
std::uint64_t playing_stream{};
int failures{};
external_player::Track track;
std::atomic<std::uint64_t> changes{1}, wanted_stream{}, begun_at{}, heard_stream{};

void say(logging::Level level, const std::string& text) noexcept {
    try {
        logging::log(level, logging::Channel::music, "YouTube Music: {}", text);
    } catch (...) {}
}
void problem(const std::string& text) {
    {
        std::lock_guard lock(mutex);
        problem_text = text;
    }
    if (!text.empty()) say(logging::Level::warning, text);
}
std::filesystem::path home() { return redirected_local_app_data().parent_path(); }
std::filesystem::path tool() { return home() / L"bin" / L"yt-dlp.exe"; }
std::filesystem::path cookies_file() { return home() / L"youtube-cookies.txt"; }
std::filesystem::path kept_file() { return home() / L"youtube-music.json"; }
std::string narrow(const std::wstring& text) {
    if (text.empty()) return {};
    std::string out(static_cast<std::size_t>(WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr)), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), static_cast<int>(out.size()), nullptr, nullptr);
    return out;
}
std::wstring wide(const std::string& text) {
    if (text.empty()) return {};
    std::wstring out(static_cast<std::size_t>(MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0)), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), static_cast<int>(out.size()));
    return out;
}
// A video's id is eleven letters, digits, '-' and '_'.
bool video_id(const std::string& id) {
    return id.size() == 11 && std::all_of(id.begin(), id.end(), [](unsigned char c) { return std::isalnum(c) || c == '-' || c == '_'; });
}
// Text the music screen can show as it is: no control characters, and not over long.
std::string shown(std::string text) {
    std::erase_if(text, [](unsigned char c) { return c < 0x20; });
    while (!text.empty() && text.back() == ' ') text.pop_back();
    while (!text.empty() && text.front() == ' ') text.erase(text.begin());
    if (text.size() > 120) {
        text.resize(120);
        while (!text.empty() && (static_cast<unsigned char>(text.back()) & 0xc0) == 0x80) text.pop_back(); // (not in the middle of a character)
        if (!text.empty() && static_cast<unsigned char>(text.back()) >= 0xc0) text.pop_back();
    }
    return text;
}

// A JavaScript runtime for yt-dlp, which YouTube's pages need worked out when they are asked
// for as a signed-in player (without one, every song fails once there is a sign-in: seen
// 2026-10-12). Node.js when it is installed, or Deno in ReSkate's bin folder, as they are the
// quicker (a song begins in about four seconds); else QuickJS, which this fetches into the bin
// folder itself (about seven seconds: both timed 2026-10-12). The name yt-dlp knows it by and
// where it is; empty when there is none.
std::filesystem::path quickjs() { return home() / L"bin" / L"qjs.exe"; }
std::pair<std::string, std::string> javascript() {
    std::error_code ignored;
    wchar_t path[MAX_PATH]{};
    if (SearchPathW(nullptr, L"node.exe", nullptr, MAX_PATH, path, nullptr)) return {"node", narrow(path)};
    if (const auto deno = home() / L"bin" / L"deno.exe"; std::filesystem::exists(deno, ignored)) return {"deno", narrow(deno.wstring())};
    if (std::filesystem::exists(quickjs(), ignored)) return {"quickjs", narrow(quickjs().wstring())};
    return {};
}
// (With the mutex held.) What yt-dlp is run with for the player's YouTube sign-in: their
// cookies.txt when one is kept, else the browser they picked, else nothing.
std::vector<std::string> sign_in() {
    std::vector<std::string> arguments;
    if (!have_cookies && browser_name.empty()) return arguments; // (no sign-in: yt-dlp asks YouTube in a way that needs no runtime, and is quicker)
    if (const auto [name, path] = javascript(); !name.empty()) arguments = {"--no-js-runtimes", "--js-runtimes", name + ":" + path};
    if (have_cookies) arguments.insert(arguments.end(), {"--cookies", narrow(cookies_file().wstring())});
    else arguments.insert(arguments.end(), {"--cookies-from-browser", browser_name});
    return arguments;
}
bool good_browser(const std::string& browser) {
    for (const char* known : {"", "firefox", "edge", "chrome", "brave", "opera", "vivaldi"})
        if (browser == known) return true;
    return false;
}

void keep() {
    try {
        Json lists = Json::array();
        {
            std::lock_guard lock(mutex);
            for (const auto& playlist : library) {
                Json songs = Json::array();
                for (const auto& song : playlist.songs) {
                    Json entry = Json::object();
                    entry["id"] = song.id;
                    entry["artist"] = song.artist;
                    entry["title"] = song.title;
                    songs.push_back(std::move(entry));
                }
                Json entry = Json::object();
                entry["name"] = playlist.name;
                entry["url"] = playlist.url;
                entry["songs"] = std::move(songs);
                lists.push_back(std::move(entry));
            }
        }
        Json json = Json::object();
        json["playlists"] = std::move(lists);
        {
            std::lock_guard lock(mutex);
            json["browser"] = browser_name;
        }
        std::error_code ignored;
        std::filesystem::create_directories(home(), ignored);
        std::ofstream(kept_file(), std::ios::binary | std::ios::trunc) << json.dump(2);
    } catch (...) {}
}
void read_kept() {
    try {
        std::ifstream in(kept_file(), std::ios::binary);
        if (!in) return;
        const auto json = Json::parse(std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()));
        if (const auto browser = json.value("browser", ""); good_browser(browser)) {
            std::lock_guard lock(mutex);
            browser_name = browser;
        }
        if (!json.contains("playlists") || !json.at("playlists").is_array()) return;
        std::vector<Playlist> read;
        const auto& lists = json.at("playlists");
        for (std::size_t i = 0; i < lists.size() && read.size() < most_playlists; ++i) {
            const auto& list = lists.at(i);
            if (!list.is_object() || !list.contains("songs") || !list.at("songs").is_array()) continue;
            Playlist playlist{shown(list.value("name", "")), list.value("url", ""), {}, {}};
            const auto& songs = list.at("songs");
            for (std::size_t s = 0; s < songs.size() && playlist.songs.size() < most_songs; ++s) {
                if (!songs.at(s).is_object()) continue;
                Song song{songs.at(s).value("id", ""), shown(songs.at(s).value("artist", "")), shown(songs.at(s).value("title", ""))};
                if (video_id(song.id) && !song.artist.empty() && !song.title.empty()) playlist.songs.push_back(std::move(song));
            }
            if (!playlist.name.empty() && !playlist.songs.empty()) read.push_back(std::move(playlist));
        }
        std::lock_guard lock(mutex);
        library = std::move(read);
    } catch (...) {}
}

// Runs yt-dlp and gives what it wrote, or nothing when it could not be run or took too long.
std::optional<std::string> run_tool(const std::vector<std::string>& arguments, DWORD milliseconds) {
    SECURITY_ATTRIBUTES inherit{sizeof(inherit), nullptr, TRUE};
    HANDLE read{}, write{};
    if (!CreatePipe(&read, &write, &inherit, 0)) return std::nullopt;
    SetHandleInformation(read, HANDLE_FLAG_INHERIT, 0);
    std::wstring command = L"\"" + tool().wstring() + L"\"";
    for (const auto& argument : arguments) {
        // (None of what is passed has a quote in it: a link is checked before it is.)
        command += L" \"" + wide(argument) + L"\"";
    }
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdOutput = write;
    const auto nothing = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_EXISTING, 0, nullptr);
    startup.hStdInput = startup.hStdError = nothing;
    PROCESS_INFORMATION process{};
    const bool made = CreateProcessW(tool().c_str(), command.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process) != 0;
    CloseHandle(write);
    if (nothing != INVALID_HANDLE_VALUE) CloseHandle(nothing);
    if (!made) {
        CloseHandle(read);
        return std::nullopt;
    }
    // (Taken out of the way if it takes too long: its pipe closing ends the reading below.)
    std::thread([process = process.hProcess, milliseconds] {
        if (WaitForSingleObject(process, milliseconds) == WAIT_TIMEOUT) TerminateProcess(process, 1);
        CloseHandle(process);
    }).detach();
    CloseHandle(process.hThread);
    std::string output;
    char buffer[8192];
    for (DWORD got{}; ReadFile(read, buffer, sizeof(buffer), &got, nullptr) && got && output.size() < 16 * 1024 * 1024;) output.append(buffer, got);
    CloseHandle(read);
    return output;
}

// A song's artist and title out of what yt-dlp says of a video: a title of the form
// "artist - title" is taken apart, and otherwise the channel is the artist.
Song song_of(const Json& entry) {
    Song song{entry.value("id", ""), {}, {}};
    auto title = entry.value("title", "");
    auto channel = entry.contains("channel") && entry.at("channel").is_string() ? entry.at("channel").string() : entry.contains("uploader") && entry.at("uploader").is_string() ? entry.at("uploader").string() : std::string();
    if (channel.ends_with(" - Topic")) channel.resize(channel.size() - 8);
    if (const auto dash = title.find(" - "); dash != std::string::npos && dash > 0 && dash + 3 < title.size()) {
        song.artist = shown(title.substr(0, dash));
        song.title = shown(title.substr(dash + 3));
    } else {
        song.artist = shown(channel.empty() ? std::string("YouTube") : channel);
        song.title = shown(title);
    }
    return song;
}

// A link is one of YouTube's, and has nothing in it that a command line would take amiss.
bool good_link(const std::string& link) {
    if (link.size() > 300 || std::any_of(link.begin(), link.end(), [](unsigned char c) { return c <= 0x20 || c == '"' || c == '\\' || c == '^' || c == '%' || c >= 0x7f; })) return false;
    for (const char* start : {"https://www.youtube.com/", "https://youtube.com/", "https://music.youtube.com/", "https://m.youtube.com/", "https://youtu.be/"})
        if (link.starts_with(start)) return true;
    return false;
}

void add_link(const std::string& link) {
    if (!good_link(link)) return problem("that is not a link to a YouTube video or playlist");
    std::vector<std::string> arguments{"--flat-playlist", "-J", "--no-warnings"};
    {
        std::lock_guard lock(mutex);
        for (auto& argument : sign_in()) arguments.push_back(std::move(argument));
    }
    arguments.push_back(link);
    const auto output = run_tool(arguments, 90000);
    if (!output || output->empty()) return problem("yt-dlp could not read that link");
    Playlist playlist{{}, link, {}, {}};
    try {
        const auto json = Json::parse(*output);
        playlist.name = shown(json.value("title", ""));
        if (json.contains("entries") && json.at("entries").is_array()) {
            const auto& entries = json.at("entries");
            for (std::size_t i = 0; i < entries.size() && playlist.songs.size() < most_songs; ++i)
                if (entries.at(i).is_object())
                    if (auto song = song_of(entries.at(i)); video_id(song.id) && !song.artist.empty() && !song.title.empty() &&
                        std::none_of(playlist.songs.begin(), playlist.songs.end(), [&](const Song& other) { return other.artist == song.artist && other.title == song.title; }))
                        playlist.songs.push_back(std::move(song));
        } else if (auto song = song_of(json); video_id(song.id) && !song.artist.empty() && !song.title.empty()) {
            playlist.songs.push_back(std::move(song));
        }
    } catch (...) {
        return problem("what yt-dlp said of that link could not be read");
    }
    if (playlist.name.empty() || playlist.songs.empty()) return problem("there is nothing to play at that link");
    {
        std::lock_guard lock(mutex);
        if (library.size() >= most_playlists) {
            problem_text = "there is room for no more than twelve";
            return;
        }
        library.push_back(playlist);
        problem_text.clear();
    }
    keep();
    say(logging::Level::info, std::format("added \"{}\" ({} song(s)).", playlist.name, playlist.songs.size()));
}

// The picture of a song (its video's), for a playlist's tile or for what is playing.
std::vector<std::uint8_t> picture(const std::string& id) {
    const auto image = https::get_text(L"https://i.ytimg.com/vi/" + wide(id) + L"/hqdefault.jpg", 2 * 1024 * 1024, 10, agent);
    return image ? std::vector<std::uint8_t>(image->begin(), image->end()) : std::vector<std::uint8_t>{};
}
// Each playlist's tile is its first song's picture.
void make_covers() {
    std::vector<std::pair<std::size_t, std::string>> wanted;
    {
        std::lock_guard lock(mutex);
        for (std::size_t i = 0; i < library.size(); ++i)
            if (library[i].artwork.empty() && !library[i].songs.empty()) wanted.emplace_back(i, library[i].songs.front().id);
    }
    for (const auto& [index, id] : wanted) {
        const auto address = spotify_cover::serve(picture(id), "youtube-" + id + ".png");
        std::lock_guard lock(mutex);
        if (index < library.size() && !library[index].songs.empty() && library[index].songs.front().id == id) library[index].artwork = address;
    }
}

std::string hex_sha256(const std::filesystem::path& file) {
    std::ifstream in(file, std::ios::binary);
    const std::vector<char> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    unsigned char digest[32]{};
    if (bytes.empty() || BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0, reinterpret_cast<PUCHAR>(const_cast<char*>(bytes.data())), static_cast<ULONG>(bytes.size()), digest, sizeof(digest)) != 0) return {};
    std::string hex;
    for (const auto byte : digest) hex += std::format("{:02x}", byte);
    return hex;
}
// yt-dlp, from its own releases, checked against the sums published beside it.
void fetch_tool() {
    std::error_code ignored;
    std::filesystem::create_directories(tool().parent_path(), ignored);
    const auto fetched = tool().parent_path() / L"yt-dlp.fetching";
    std::filesystem::remove(fetched, ignored);
    tool_watch.received.store(0);
    tool_watch.total.store(0);
    std::atomic<bool> fetching{true};
    std::thread progress([&] {
        while (fetching.load()) {
            const auto total = tool_watch.total.load();
            fetched_percent.store(total ? static_cast<unsigned>(tool_watch.received.load() * 100 / total) : 0);
            Sleep(200);
        }
    });
    const auto result = https::get(tool_address, fetched, 96ull * 1024 * 1024, 600, agent, &tool_watch);
    fetching.store(false);
    progress.join();
    fetched_percent.store(0);
    if (!result.ok) {
        std::filesystem::remove(fetched, ignored);
        return problem(std::format("yt-dlp could not be fetched ({}, {})", result.http_status, result.error));
    }
    const auto sums = https::get_text(sums_address, 64 * 1024, 30, agent);
    const auto sum = hex_sha256(fetched);
    if (!sums || sum.empty() || sums->find(sum + "  yt-dlp.exe") == std::string::npos) {
        std::filesystem::remove(fetched, ignored);
        return problem("what was fetched is not the yt-dlp its releases say it is: it was not kept");
    }
    std::filesystem::remove(tool(), ignored);
    std::filesystem::rename(fetched, tool(), ignored);
    const bool there = std::filesystem::exists(tool(), ignored);
    {
        std::lock_guard lock(mutex);
        have_tools = there;
        if (there) problem_text.clear();
    }
    if (there) say(logging::Level::info, "yt-dlp was fetched.");
    else problem("yt-dlp could not be put in its place");
}

// QuickJS, from its own releases, when there is no runtime for yt-dlp on this computer.
void fetch_runtime() {
    if (!javascript().first.empty()) return;
    std::error_code ignored;
    std::filesystem::create_directories(quickjs().parent_path(), ignored);
    const auto fetched = quickjs().parent_path() / L"qjs.fetching";
    std::filesystem::remove(fetched, ignored);
    const auto result = https::get(runtime_address, fetched, 32ull * 1024 * 1024, 300, agent);
    char start[2]{};
    if (result.ok) std::ifstream(fetched, std::ios::binary).read(start, 2);
    // (A Windows program, and of a size a runtime is.)
    if (!result.ok || start[0] != 'M' || start[1] != 'Z' || std::filesystem::file_size(fetched, ignored) < 256 * 1024) {
        std::filesystem::remove(fetched, ignored);
        return problem("the JavaScript runtime a YouTube sign-in needs (QuickJS) could not be fetched; Node.js, when it is installed, does as well");
    }
    std::filesystem::rename(fetched, quickjs(), ignored);
    say(logging::Level::info, "QuickJS was fetched, for songs that need the YouTube sign-in.");
}

void run() noexcept {
    const bool initialized = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)); // (pictures are converted on this thread)
    read_kept();
    {
        std::error_code ignored;
        std::lock_guard lock(mutex);
        have_tools = std::filesystem::exists(tool(), ignored);
        have_cookies = std::filesystem::exists(cookies_file(), ignored);
    }
    try {
        bool signed_in{};
        {
            std::lock_guard lock(mutex);
            signed_in = have_tools && (have_cookies || !browser_name.empty());
        }
        if (signed_in) fetch_runtime(); // (a sign-in set by a ReSkate that did not fetch one)
        make_covers();
    } catch (...) {}
    for (;;) {
        std::string command;
        {
            std::unique_lock lock(mutex);
            is_busy = false;
            wake.wait(lock, [] { return !commands.empty(); });
            command = std::move(commands.front());
            commands.pop_front();
            is_busy = true;
        }
        try {
            if (command == "tools") {
                fetch_tool();
                fetch_runtime();
            } else if (command == "runtime") fetch_runtime();
            if (command.starts_with("add ")) {
                add_link(command.substr(4));
                make_covers();
            }
            profile_runtime::request_music_catalog_refresh();
        } catch (...) {}
    }
    if (initialized) CoUninitialize();
}
void ask(std::string command) {
    start();
    {
        std::lock_guard lock(mutex);
        if (commands.size() < 8) commands.push_back(std::move(command));
    }
    wake.notify_one();
}

// --- playing ---

// The sound of the song that is playing, on the decoder's thread. It is taken as fast as the
// game hears it; while the player has it paused, none is taken.
void sound(const float* samples, std::uint32_t frames, std::uint32_t rate) {
    const auto mine = wanted_stream.load(std::memory_order_relaxed);
    sound_rate.store(rate, std::memory_order_relaxed);
    // (The first of a song's sound: how long it was in coming, into the log.)
    if (mine && heard_stream.exchange(mine, std::memory_order_relaxed) != mine)
        say(logging::Level::info, std::format("the song's sound began {:.1f} s after it was asked for.", static_cast<double>(GetTickCount64() - begun_at.load(std::memory_order_relaxed)) / 1000.0));
    for (int waited = 0; paused.load(std::memory_order_relaxed) || app_audio::ahead_frames() > rate * 15 / 100; ++waited) {
        if (wanted_stream.load(std::memory_order_relaxed) != mine) return; // (another song is wanted)
        if (!paused.load(std::memory_order_relaxed) && waited >= 125) return; // (the game is not listening)
        Sleep(4);
    }
    app_audio::push(samples, frames);
}
void begin(std::size_t list, std::size_t song);
// A song is over: the next of its playlist, and round again after its last.
void ended(std::uint64_t stream, const char* how) {
    try {
        std::size_t list{}, next{};
        {
            std::lock_guard lock(mutex);
            if (stream != playing_stream || list >= library.size()) return; // (it was stopped for another)
            list = playing_list;
            if (list >= library.size() || library[list].songs.empty()) return;
            const bool failed = std::string_view(how).starts_with("failed");
            failures = failed ? failures + 1 : 0;
            if (failed) {
                const auto& title = library[list].songs[playing_song % library[list].songs.size()].title;
                say(logging::Level::warning, std::format("\"{}\" {}.", title, how));
                // (The usual reason: YouTube wants a sign-in before it plays it.)
                problem_text = "\"" + title + "\" could not be played and was passed over. YouTube asks for a sign-in for private and age-restricted songs: add your cookies.txt below.";
            }
            if (failures >= 4) {
                problem_text = "songs are not playing (yt-dlp may need to be fetched again, or YouTube is not letting them be)";
                return;
            }
            next = (playing_song + 1) % library[list].songs.size();
        }
        begin(list, next);
    } catch (...) {}
}
void fetch_picture(std::string id, std::uint64_t of) {
    try {
        auto image = picture(id);
        if (image.empty()) return;
        std::lock_guard lock(mutex);
        if (track.revision != of) return;
        track.artwork = std::move(image);
        ++track.artwork_revision;
        changes.fetch_add(1, std::memory_order_relaxed);
    } catch (...) {}
}
void begin(std::size_t list, std::size_t song) {
#if DINGOSDK_SPOTIFY_DEVICE
    std::string id;
    std::uint64_t of{};
    {
        std::lock_guard lock(mutex);
        if (!have_tools || list >= library.size() || library[list].songs.empty()) return;
        song %= library[list].songs.size();
        if (playing_stream && list == playing_list && song == playing_song && GetTickCount64() - begun_at.load(std::memory_order_relaxed) < 3000) return;
        begun_at.store(GetTickCount64(), std::memory_order_relaxed);
        const auto& chosen = library[list].songs[song];
        id = chosen.id;
        playing_list = list;
        playing_song = song;
        track.available = true;
        track.spotify = false;
        track.app = "YouTube Music";
        track.can_next = track.can_previous = track.can_pause = track.can_play = true;
        track.artist = chosen.artist;
        track.title = chosen.title;
        track.album.clear();
        track.artwork.clear();
        track.playing = true;
        of = ++track.revision;
        paused.store(false);
        const auto program = narrow(tool().wstring());
        std::string arguments = "-f\n140/bestaudio[ext=m4a]\n--no-playlist\n--quiet\n--no-warnings\n";
        for (const auto& argument : sign_in()) arguments += argument + "\n";
        arguments += "-o\n-\nhttps://www.youtube.com/watch?v=" + id;
        // (The number the stream will have is known before it is begun: its sound is asked for it.)
        playing_stream = reskate_stream_play(program.c_str(), arguments.c_str(), &sound, &ended);
        wanted_stream.store(playing_stream, std::memory_order_relaxed);
    }
    changes.fetch_add(1, std::memory_order_relaxed);
    try {
        std::thread(fetch_picture, id, of).detach();
    } catch (...) {}
#else
    (void)list;
    (void)song;
#endif
}
} // namespace

void start() noexcept {
    if (started.exchange(true)) return;
    try {
        std::thread(run).detach();
    } catch (...) {}
}
State state() {
    std::lock_guard lock(mutex);
    State out;
#if DINGOSDK_SPOTIFY_DEVICE
    out.available = true;
#endif
    out.tools = have_tools;
    out.busy = is_busy;
    out.percent = fetched_percent.load();
    out.problem = problem_text;
    out.browser = browser_name;
    out.cookies = have_cookies;
    out.runtime = javascript().first;
    out.playlists = library;
    return out;
}
std::vector<Playlist> playlists() {
    std::lock_guard lock(mutex);
    return have_tools ? library : std::vector<Playlist>{};
}
void fetch_tools() { ask("tools"); }
void add(const std::string& link) { ask("add " + link); }
void remove(std::size_t playlist) {
    {
        std::lock_guard lock(mutex);
        if (playlist >= library.size()) return;
        library.erase(library.begin() + static_cast<std::ptrdiff_t>(playlist));
    }
    keep();
    profile_runtime::request_music_catalog_refresh();
}

void set_browser(const std::string& browser) {
    if (!good_browser(browser)) return;
    {
        std::lock_guard lock(mutex);
        browser_name = browser;
        problem_text.clear();
        failures = 0;
    }
    keep();
    if (!browser.empty()) ask("runtime");
}

bool set_cookies(const std::string& text) {
    std::error_code ignored;
    if (text.empty()) {
        std::filesystem::remove(cookies_file(), ignored);
        std::lock_guard lock(mutex);
        have_cookies = false;
        return true;
    }
    // A Netscape cookie file: its first line says so, and it has YouTube's cookies in it.
    if (text.size() > 1024 * 1024 || !(text.starts_with("# Netscape HTTP Cookie File") || text.starts_with("# HTTP Cookie File")) || text.find("youtube.com") == std::string::npos ||
        text.find('\0') != std::string::npos)
        return false;
    std::filesystem::create_directories(home(), ignored);
    {
        std::ofstream out(cookies_file(), std::ios::binary | std::ios::trunc);
        out << text;
        if (!out) return false;
    }
    {
        std::lock_guard lock(mutex);
        have_cookies = true;
        problem_text.clear();
        failures = 0;
    }
    ask("runtime");
    return true;
}

bool on() noexcept { return is_on.load(std::memory_order_relaxed); }
void set_on(bool on) noexcept {
    if (is_on.exchange(on, std::memory_order_relaxed) && !on) {
#if DINGOSDK_SPOTIFY_DEVICE
        // (Its song is stopped as another kind of station takes over.)
        wanted_stream.store(0, std::memory_order_relaxed);
        reskate_stream_stop();
#endif
        std::lock_guard lock(mutex);
        playing_stream = 0;
        track.playing = false;
    }
}
unsigned rate() noexcept { return sound_rate.load(std::memory_order_relaxed); }
void play(std::size_t playlist, const std::string& song) {
    std::size_t at{};
    {
        std::lock_guard lock(mutex);
        if (playlist >= library.size()) return;
        // (The same playlist again, with no song asked for, goes on from where it was.)
        if (song.empty() && playlist == playing_list && playing_stream) {
            paused.store(false);
            track.playing = true;
            changes.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        for (std::size_t i = 0; i < library[playlist].songs.size(); ++i)
            if (library[playlist].songs[i].id == song) at = i;
        failures = 0;
    }
    begin(playlist, at);
}
external_player::Track now() {
    std::lock_guard lock(mutex);
    return track;
}
std::uint64_t revision() noexcept { return changes.load(std::memory_order_relaxed); }
void send(external_player::Command command) noexcept {
    try {
        using external_player::Command;
        std::size_t list{}, song{}, count{};
        {
            std::lock_guard lock(mutex);
            list = playing_list;
            song = playing_song;
            count = list < library.size() ? library[list].songs.size() : 0;
            if (command == Command::pause || command == Command::play || command == Command::toggle) {
                const bool pause = command == Command::pause || (command == Command::toggle && !paused.load());
                paused.store(pause);
                track.playing = !pause && playing_stream != 0;
                changes.fetch_add(1, std::memory_order_relaxed);
                return;
            }
            failures = 0;
        }
        if (!count) return;
        begin(list, command == Command::next ? (song + 1) % count : (song + count - 1) % count);
    } catch (...) {}
}
} // namespace dingosdk::youtube_music
