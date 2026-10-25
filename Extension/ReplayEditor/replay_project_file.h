#pragma once
#include "replay_edit.h"
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

// Projects as files: JSON, one project each, in %LOCALAPPDATA%\ReSkate\Replays (the folder is the
// caller's, so the tests can use their own). The footage is not in the file (it lives in the game
// only while it runs): a project opened in a later run keeps its clips, keys and titles, and the
// screen says its footage is gone.
namespace dingosdk::replay_editor {
inline constexpr int project_version = 1;
std::string to_json(const Project& project);
// Nothing (and why) when it is not a project; a project otherwise, normalized.
std::optional<Project> from_json(std::string_view text, std::string& why);

struct ProjectFile {
    std::filesystem::path path;
    std::string name;
    std::filesystem::file_time_type written{};
};
// The folder's projects, newest first.
std::vector<ProjectFile> list_projects(const std::filesystem::path& folder);
// Writes the project (its file name made from its name); the path written, or empty and why.
std::filesystem::path save_project(const std::filesystem::path& folder, const Project& project, std::string& why);
std::optional<Project> load_project(const std::filesystem::path& file, std::string& why);
// A name made safe as a file name.
std::string file_stem(std::string_view name);
} // namespace dingosdk::replay_editor
