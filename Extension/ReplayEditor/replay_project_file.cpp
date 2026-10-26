#include "replay_project_file.h"
#include "Engine/Core/Json/json.h"
#include <algorithm>
#include <cctype>
#include <fstream>
#include <sstream>

namespace dingosdk::replay_editor {
namespace {
constexpr std::size_t largest_file = 8u << 20;

Json vec(const Vec3& v) { return Json::array({Json(v[0]), Json(v[1]), Json(v[2])}); }
Vec3 vec_of(const Json& j) {
    Vec3 v{};
    if (!j.is_array()) return v;
    for (std::size_t i = 0; i < 3 && i < j.size(); ++i)
        if (j.at(i).is_number()) v[i] = j.at(i).get<float>();
    return v;
}
template <class T> T number(const Json& j, std::string_view key, T fallback) {
    if (!j.is_object() || !j.contains(key) || !j.at(key).is_number()) return fallback;
    return j.at(key).get<T>();
}
std::string text(const Json& j, std::string_view key) {
    if (!j.is_object() || !j.contains(key) || !j.at(key).is_string()) return {};
    return j.at(key).string();
}
bool flag(const Json& j, std::string_view key, bool fallback = false) {
    if (!j.is_object() || !j.contains(key) || !j.at(key).is_boolean()) return fallback;
    return j.at(key).get<bool>();
}
Ease ease_of(const Json& j) { return ease_from(text(j, "ease")).value_or(Ease::smooth); }
template <class E, std::size_t N> E named(const Json& j, std::string_view key, const std::array<E, N>& all, const char* (*name)(E) noexcept,
                                         E fallback) {
    const auto value = text(j, key);
    for (const auto e : all)
        if (value == name(e)) return e;
    return fallback;
}
constexpr std::array<Part, 3> all_parts{Part::body, Part::head, Part::board};
constexpr std::array<TitleStyle, 4> all_styles{TitleStyle::title, TitleStyle::caption, TitleStyle::label, TitleStyle::lower_third};

Json look_json(const Look& l) {
    Json j = Json::object();
    j["exposure"] = l.exposure;
    j["saturation"] = l.saturation;
    j["contrast"] = l.contrast;
    j["hue"] = l.hue;
    j["vignette"] = l.vignette;
    j["barrel"] = l.barrel;
    j["grain"] = l.grain;
    j["aberration"] = l.aberration;
    return j;
}
Look look_of(const Json& j) {
    Look l;
    l.exposure = number(j, "exposure", l.exposure);
    l.saturation = number(j, "saturation", l.saturation);
    l.contrast = number(j, "contrast", l.contrast);
    l.hue = number(j, "hue", l.hue);
    l.vignette = number(j, "vignette", l.vignette);
    l.barrel = number(j, "barrel", l.barrel);
    l.grain = number(j, "grain", l.grain);
    l.aberration = number(j, "aberration", l.aberration);
    return l;
}
}

std::string to_json(const Project& project) {
    Json root = Json::object();
    root["reskate_replay_project"] = project_version;
    root["name"] = project.name;
    root["level"] = project.level;
    root["footage"] = project.footage;
    root["next_id"] = project.next_id;
    Json clips = Json::array({});
    for (const auto& clip : project.clips) {
        Json c = Json::object();
        c["id"] = clip.id;
        c["name"] = clip.name;
        c["in"] = clip.in;
        c["out"] = clip.out;
        c["hold"] = clip.hold;
        c["shake"] = clip.shake;
        c["shake_rate"] = clip.shake_rate;
        c["trick_labels"] = clip.trick_labels;
        Json speed = Json::array({});
        for (const auto& k : clip.speed) {
            Json j = Json::object();
            j["at"] = k.at;
            j["speed"] = k.speed;
            j["ease"] = std::string(ease_name(k.ease));
            speed.push_back(std::move(j));
        }
        c["speed"] = std::move(speed);
        Json camera = Json::array({});
        for (const auto& k : clip.camera) {
            Json j = Json::object();
            j["at"] = k.at;
            j["rig"] = std::string(rig_name(k.rig));
            j["ease"] = std::string(ease_name(k.ease));
            j["position"] = vec(k.position);
            j["yaw"] = k.yaw;
            j["pitch"] = k.pitch;
            j["roll"] = k.roll;
            j["fov"] = k.fov;
            j["orbit_speed"] = k.orbit_speed;
            j["target_player"] = std::to_string(k.target.player); // a Steam id does not fit a double
            j["target_part"] = std::string(part_name(k.target.part));
            j["focus"] = k.focus;
            j["blur"] = k.blur;
            camera.push_back(std::move(j));
        }
        c["camera"] = std::move(camera);
        Json look = Json::array({});
        for (const auto& k : clip.look) {
            Json j = look_json(k.look);
            j["at"] = k.at;
            j["ease"] = std::string(ease_name(k.ease));
            look.push_back(std::move(j));
        }
        c["look"] = std::move(look);
        Json titles = Json::array({});
        for (const auto& t : clip.titles) {
            Json j = Json::object();
            j["at"] = t.at;
            j["length"] = t.length;
            j["text"] = t.text;
            j["x"] = t.x;
            j["y"] = t.y;
            j["size"] = t.size;
            j["style"] = std::string(title_style_name(t.style));
            titles.push_back(std::move(j));
        }
        c["titles"] = std::move(titles);
        clips.push_back(std::move(c));
    }
    root["clips"] = std::move(clips);
    return root.dump(1);
}

std::optional<Project> from_json(std::string_view source, std::string& why) {
    Json root;
    try {
        root = Json::parse(source, {largest_file, 16, 1u << 20});
    } catch (const std::exception& error) {
        why = std::string("not valid JSON: ") + error.what();
        return std::nullopt;
    }
    if (!root.is_object() || !root.contains("reskate_replay_project")) {
        why = "not a ReSkate replay project";
        return std::nullopt;
    }
    if (number(root, "reskate_replay_project", 0) > project_version) {
        why = "made by a newer ReSkate";
        return std::nullopt;
    }
    try {
        Project project;
        project.name = text(root, "name");
        project.level = text(root, "level");
        project.footage = number<std::uint64_t>(root, "footage", 0);
        project.next_id = number<std::uint64_t>(root, "next_id", 1);
        if (root.contains("clips") && root.at("clips").is_array())
            for (const auto& c : root.at("clips")) {
                if (!c.is_object() || project.clips.size() >= 2000) continue;
                Clip clip;
                clip.id = number<std::uint64_t>(c, "id", 0);
                clip.name = text(c, "name");
                clip.in = number(c, "in", 0.0);
                clip.out = number(c, "out", clip.in + 1);
                clip.hold = number(c, "hold", 0.0);
                clip.shake = number(c, "shake", 0.0f);
                clip.shake_rate = number(c, "shake_rate", 1.2f);
                clip.trick_labels = flag(c, "trick_labels");
                if (c.contains("speed") && c.at("speed").is_array())
                    for (const auto& j : c.at("speed"))
                        if (j.is_object() && clip.speed.size() < 4000) clip.speed.push_back({number(j, "at", 0.0), number(j, "speed", 1.0f), ease_of(j)});
                if (c.contains("camera") && c.at("camera").is_array())
                    for (const auto& j : c.at("camera")) {
                        if (!j.is_object() || clip.camera.size() >= 4000) continue;
                        CameraKey k;
                        k.at = number(j, "at", 0.0);
                        k.rig = named(j, "rig", all_rigs, rig_name, Rig::free);
                        k.ease = ease_of(j);
                        if (j.contains("position")) k.position = vec_of(j.at("position"));
                        k.yaw = number(j, "yaw", 0.0f);
                        k.pitch = number(j, "pitch", 0.0f);
                        k.roll = number(j, "roll", 0.0f);
                        k.fov = number(j, "fov", 65.0f);
                        k.orbit_speed = number(j, "orbit_speed", 20.0f);
                        try { k.target.player = std::stoull(text(j, "target_player").empty() ? "0" : text(j, "target_player")); }
                        catch (...) { k.target.player = 0; }
                        k.target.part = named(j, "target_part", all_parts, part_name, Part::body);
                        k.focus = number(j, "focus", 0.0f);
                        k.blur = number(j, "blur", 0.5f);
                        clip.camera.push_back(k);
                    }
                if (c.contains("look") && c.at("look").is_array())
                    for (const auto& j : c.at("look"))
                        if (j.is_object() && clip.look.size() < 4000) clip.look.push_back({number(j, "at", 0.0), look_of(j), ease_of(j)});
                if (c.contains("titles") && c.at("titles").is_array())
                    for (const auto& j : c.at("titles")) {
                        if (!j.is_object() || clip.titles.size() >= 500) continue;
                        Title t;
                        t.at = number(j, "at", 0.0);
                        t.length = number(j, "length", 3.0);
                        t.text = text(j, "text");
                        t.x = number(j, "x", .5f);
                        t.y = number(j, "y", .8f);
                        t.size = number(j, "size", 1.0f);
                        t.style = named(j, "style", all_styles, title_style_name, TitleStyle::title);
                        clip.titles.push_back(std::move(t));
                    }
                project.clips.push_back(std::move(clip));
            }
        normalize(project);
        return project;
    } catch (const std::exception& error) {
        why = std::string("the project is damaged: ") + error.what();
        return std::nullopt;
    }
}

std::string file_stem(std::string_view name) {
    std::string stem;
    for (const unsigned char c : name) {
        if (stem.size() >= 60) break;
        if (std::isalnum(c) || c == '-' || c == '_') stem += static_cast<char>(c);
        else if (c == ' ' || c == '.') stem += '_';
    }
    while (!stem.empty() && stem.back() == '_') stem.pop_back();
    while (!stem.empty() && stem.front() == '_') stem.erase(stem.begin());
    return stem.empty() ? "replay" : stem;
}

std::vector<ProjectFile> list_projects(const std::filesystem::path& folder) {
    std::vector<ProjectFile> files;
    std::error_code error;
    for (std::filesystem::directory_iterator it(folder, error), end; !error && it != end; it.increment(error)) {
        if (!it->is_regular_file(error) || it->path().extension() != L".rsedit") continue;
        ProjectFile file;
        file.path = it->path();
        file.written = it->last_write_time(error);
        std::string why;
        if (const auto project = load_project(file.path, why)) file.name = project->name;
        else continue;
        files.push_back(std::move(file));
        if (files.size() >= 500) break;
    }
    std::sort(files.begin(), files.end(), [](const ProjectFile& a, const ProjectFile& b) { return a.written > b.written; });
    return files;
}

std::filesystem::path save_project(const std::filesystem::path& folder, const Project& project, std::string& why) {
    std::error_code error;
    std::filesystem::create_directories(folder, error);
    const auto path = folder / (file_stem(project.name) + ".rsedit");
    const auto temporary = std::filesystem::path(path).concat(L".tmp");
    {
        std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
        if (!out) {
            why = "the Replays folder cannot be written";
            return {};
        }
        const auto json = to_json(project);
        out.write(json.data(), static_cast<std::streamsize>(json.size()));
        if (!out) {
            why = "the project could not be written";
            return {};
        }
    }
    std::filesystem::rename(temporary, path, error);
    if (error) {
        why = "the project could not be written: " + error.message();
        std::filesystem::remove(temporary, error);
        return {};
    }
    return path;
}

std::optional<Project> load_project(const std::filesystem::path& file, std::string& why) {
    std::error_code error;
    const auto size = std::filesystem::file_size(file, error);
    if (error || size > largest_file) {
        why = error ? "the file cannot be read" : "the file is too large to be a project";
        return std::nullopt;
    }
    std::ifstream in(file, std::ios::binary);
    std::ostringstream text;
    text << in.rdbuf();
    if (!in && !in.eof()) {
        why = "the file cannot be read";
        return std::nullopt;
    }
    return from_json(text.str(), why);
}
} // namespace dingosdk::replay_editor
