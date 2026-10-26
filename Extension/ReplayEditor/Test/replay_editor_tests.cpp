#include "Extension/ReplayEditor/replay_bridge.h"
#include "Extension/ReplayEditor/replay_edit.h"
#include "Extension/ReplayEditor/replay_motion.h"
#include "Extension/ReplayEditor/replay_program.h"
#include "Extension/ReplayEditor/replay_project_file.h"
#include <cmath>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>

// ReSkate's replay editor, the parts with no game code: the edit's operations, the curves, the edit
// made playable (its clock and its export playlist), the camera rigs and the project files.
using namespace dingosdk::replay_editor;

namespace {
void check(bool condition, const std::string& what) {
    if (!condition) throw std::runtime_error(what);
}
bool near(double a, double b, double tolerance = 1e-6) { return std::abs(a - b) <= tolerance; }

void edits() {
    Project p;
    const auto a = add_clip(p, 10, 14);
    const auto b = add_clip(p, 20, 21, 0, "first");
    check(p.clips.size() == 2 && p.clips[0].id == b && p.clips[1].id == a, "a clip goes where it is put");
    check(add_clip(p, 5, 5.01) != 0 && near(p.clips.back().length(), shortest_clip), "a clip is never shorter than the shortest");
    remove_clip(p, p.clips.back().id);
    // Keys: sorted, one near another replaces it.
    auto* clip = find_clip(p, a);
    put_key(clip->speed, {12, 0.5f, Ease::smooth});
    put_key(clip->speed, {11, 2.0f, Ease::linear});
    put_key(clip->speed, {12 + same_key / 2, 0.25f, Ease::smooth});
    check(clip->speed.size() == 2 && clip->speed[0].at == 11 && near(clip->speed[1].speed, 0.25), "keys sort and replace");
    put_key(clip->speed, {13, 100.0f, Ease::smooth});
    check(near(clip->speed.back().speed, fastest), "a speed stays in range");
    check(remove_key(clip->speed, 13) && clip->speed.size() == 2, "a key comes off");
    // Splitting keeps keys on both sides of the cut so each part reads the same at the cut.
    put_key(clip->camera, {10.5, Rig::free});
    put_key(clip->camera, {13.5, Rig::free});
    clip->titles.push_back({13.0, 1, "late"});
    const auto second = split_clip(p, a, 12.5);
    check(second.has_value(), "a clip splits inside");
    clip = find_clip(p, a);
    const auto* after = find_clip(p, *second);
    check(near(clip->out, 12.5) && near(after->in, 12.5) && near(after->out, 14), "the parts meet at the cut");
    check(clip->camera.size() == 2 && after->camera.size() == 2, "each part keeps the keys either side of the cut");
    check(clip->titles.empty() && after->titles.size() == 1, "titles go with the part they are in");
    check(!split_clip(p, a, 10.01).has_value(), "no split right at an end");
    // Moving and trimming.
    check(move_clip(p, *second, 0) && p.clips[0].id == *second, "a clip moves");
    trim_clip(p, a, 11, 11.02, std::array<double, 2>{0, 100});
    check(near(find_clip(p, a)->length(), shortest_clip), "a trim keeps the shortest clip");
    trim_clip(p, a, -5, 500, std::array<double, 2>{0, 100});
    check(near(find_clip(p, a)->in, 0) && near(find_clip(p, a)->out, 100), "a trim stays in the recording");
    // Undo and redo.
    History history;
    history.remember(p);
    remove_clip(p, a);
    check(history.undo(p) && find_clip(p, a), "undo brings it back");
    check(history.redo(p) && !find_clip(p, a), "redo takes it away again");
    check(!history.redo(p), "nothing more to redo");
}

void curves() {
    std::vector<double> times{0, 1, 3, 4}, values{0, 2, 1, 5}, velocities(4), work;
    check(spline_velocities(times, values, velocities, work), "the spline solves");
    std::vector<Ease> eases(4, Ease::smooth);
    for (std::size_t i = 0; i < times.size(); ++i)
        check(near(between_keys(times, values, eases, velocities, times[i]), values[i], 1e-9), "every key is met");
    // C2: the second derivative agrees on both sides of an inner key.
    const auto second = [&](double t, double h) {
        return (between_keys(times, values, eases, velocities, t + h) - 2 * between_keys(times, values, eases, velocities, t) +
                between_keys(times, values, eases, velocities, t - h)) / (h * h);
    };
    check(near(second(1 - 1e-3, 1e-4), second(1 + 1e-3, 1e-4), 0.05), "no jump in acceleration at a key");
    // The ends start and stop without accelerating.
    check(std::abs(second(1e-3, 1e-4)) < 0.05, "a natural end");
    // Other eases.
    std::vector<Ease> hold(4, Ease::hold);
    check(near(between_keys(times, values, hold, velocities, 0.9), 0), "hold keeps the key's value");
    std::vector<Ease> linear(4, Ease::linear);
    check(near(between_keys(times, values, linear, velocities, 0.5), 1), "linear goes straight");
    check(near(eased(Ease::ease_in_out, 0.5), 0.5) && eased(Ease::ease_in, 0.5) < 0.5 && eased(Ease::ease_out, 0.5) > 0.5, "eases");
    check(near(unwrap_degrees(-170, 170), 190), "angles unwrap");
}

void cameras() {
    // A camera from angles reads back as those angles.
    for (const float yaw : {-150.0f, -30.0f, 0.0f, 45.0f, 179.0f})
        for (const float pitch : {-60.0f, 0.0f, 30.0f})
            for (const float roll : {-20.0f, 0.0f, 10.0f}) {
                const auto pose = camera_from({1, 2, 3}, yaw, pitch, roll, 65);
                const auto a = camera_angles(pose.right, pose.up, pose.back);
                check(near(a[0], yaw, 1e-3) && near(a[1], pitch, 1e-3) && near(a[2], roll, 1e-3), "camera angles read back");
            }
    // Yaw 0 looks along +z, the way ReSkate's other cameras build their right vector.
    const auto ahead = camera_from({0, 0, 0}, 0, 0, 0, 65);
    check(near(ahead.back[2], -1) && near(ahead.right[0], -1), "the camera convention");
    const auto look = aim({0, 0, 0}, {10, 10, 10});
    check(near(look[0], 45, 1e-3) && look[1] > 35 && look[1] < 36, "aim");
}

void program_clock() {
    Project p;
    const auto a = add_clip(p, 100, 104);
    const auto b = add_clip(p, 50, 52);
    find_clip(p, b)->hold = 1;
    auto program = Program::build(p);
    check(near(program->clip_length(0), 4, 1e-6) && near(program->clip_length(1), 3, 1e-6), "lengths at speed 1, the hold added");
    check(near(program->duration(), 7, 1e-6), "the edit's length");
    auto place = program->at_edit(5);
    check(place && place->clip == 1 && near(place->replay, 51, 1e-6) && !place->holding, "edit time to footage");
    place = program->at_edit(6.5);
    check(place && place->clip == 1 && near(place->replay, 52) && place->holding, "in the hold");
    check(near(program->edit_time(0, 102), 2, 1e-6), "footage to edit time");
    // Half speed throughout: twice as long.
    find_clip(p, a)->speed = {{100, 0.5f, Ease::linear}};
    program = Program::build(p);
    check(near(program->clip_length(0), 8, 1e-3), "half speed doubles the length");
    check(near(program->speed(0, 101), 0.5), "the speed");
    // A ramp from 1x to 0.25x: longer than 4 s, shorter than 16 s.
    find_clip(p, a)->speed = {{100, 1, Ease::smooth}, {104, 0.25f, Ease::smooth}};
    program = Program::build(p);
    check(program->clip_length(0) > 4 && program->clip_length(0) < 16, "a ramp's length lies between");
    // Round trip edit time <-> footage.
    for (double e = 0.1; e < program->clip_length(0); e += 0.37) {
        const auto at = program->at_edit(e);
        check(at && near(program->edit_time(at->clip, at->replay), e, 1e-3), "edit time round trip");
    }
    // The export playlist: pieces in footage order per clip, a hold as a slowed hair.
    const auto pieces = program->export_pieces();
    double footage = 0, length = 0;
    for (const auto& piece : pieces) {
        check(piece.end > piece.start && piece.speed > 0, "a piece is forward");
        footage += piece.end - piece.start;
        length += (piece.end - piece.start) / piece.speed;
    }
    check(near(footage, 4 + 2, 0.002), "pieces cover the clips' footage (and the hold's hair)");
    check(near(length, program->duration(), 0.05), "pieces play as long as the edit");
    check(near(pieces.back().end, 52) && pieces.back().end - pieces.back().start < 0.01, "the hold's piece is last");
    check(pieces.front().clip == 0 && pieces.back().clip == 1, "each piece knows its clip");
    check(clip_index(p, b) == 1u, "clip index");
    check(program->clip_at_replay(51) == 1u && !program->clip_at_replay(70), "which clip holds a time");
}

void program_camera() {
    Project p;
    const auto id = add_clip(p, 0, 10);
    auto* clip = find_clip(p, id);
    CameraKey first;
    first.at = 0;
    first.position = {0, 2, 0};
    CameraKey second = first;
    second.at = 10;
    second.position = {10, 2, 0};
    second.yaw = 90;
    put_key(clip->camera, first);
    put_key(clip->camera, second);
    auto program = Program::build(p);
    const auto none = [](const Target&, double) { return std::optional<TargetPlace>{}; };
    auto pose = program->camera(0, 5, none);
    check(pose && near(pose->position[0], 5, 1e-3) && near(pose->position[1], 2, 1e-3), "a camera between two keys");
    check(program->camera(0, -1, none)->position[0] == 0 && near(program->camera(0, 11, none)->position[0], 10), "held past the ends");
    // Follow: rides behind the target as it moves along +x.
    clip->camera.clear();
    CameraKey follow;
    follow.rig = Rig::follow;
    follow.position = {0, 1.5f, 4}; // 4 m behind, 1.5 m up
    follow.target = {0, Part::body};
    put_key(clip->camera, follow);
    program = Program::build(p);
    const auto moving = [](const Target&, double t) {
        return std::optional<TargetPlace>{TargetPlace{{static_cast<float>(t), 0, 0}, {1, 0, 0}}};
    };
    pose = program->camera(0, 3, moving);
    check(pose && near(pose->position[0], -1, 1e-3) && near(pose->position[1], 1.5, 1e-3) && near(pose->position[2], 0, 1e-3),
          "a follow camera rides behind");
    const auto a = camera_angles(pose->right, pose->up, pose->back);
    check(near(a[0], 90, 0.5), "and looks at the target");
    // A follow key without its target has nowhere to be.
    check(!program->camera(0, 3, none), "no target, no follow camera");
    // Orbit: at its radius from the target.
    clip->camera.clear();
    CameraKey orbit;
    orbit.rig = Rig::orbit;
    orbit.position = {5, 2, 0};
    orbit.orbit_speed = 90;
    put_key(clip->camera, orbit);
    program = Program::build(p);
    const auto still = [](const Target&, double) { return std::optional<TargetPlace>{TargetPlace{{0, 0, 0}, {0, 0, 1}}}; };
    pose = program->camera(0, 1, still);
    check(pose && near(pose->position[0], 5, 1e-3) && near(pose->position[2], 0, 1e-3), "a quarter turn in a second at 90 deg/s");
    // Auto focus is the distance to the target.
    clip->camera[0].focus = -1;
    program = Program::build(p);
    pose = program->camera(0, 1, still);
    check(pose && near(pose->focus, std::sqrt(29.0), 1e-3), "focus on the target");
    // The handheld wobble stays within its amount.
    for (double t = 0; t < 30; t += 0.13) {
        const auto h = handheld(t, 2, 1.5f);
        check(std::abs(h[0]) <= 2.01 && std::abs(h[1]) <= 2.01 && std::abs(h[2]) <= 2.01, "shake within its amount");
    }
}

void files() {
    Project p;
    p.name = "Line at the Hub";
    p.level = "Levels/Game/BAM_LevelRoot";
    p.footage = 1234567890123ull;
    const auto id = add_clip(p, 3, 9, 0, "opener");
    auto* clip = find_clip(p, id);
    clip->hold = 0.5;
    clip->shake = 1.5f;
    clip->trick_labels = true;
    put_key(clip->speed, {4, 0.25f, Ease::ease_out});
    CameraKey key;
    key.at = 5;
    key.rig = Rig::orbit;
    key.target = {76561198000000001ull, Part::head};
    key.position = {4, 1, 30};
    key.focus = -1;
    put_key(clip->camera, key);
    put_key(clip->look, {6, Look{0.5f, 0.2f, 1.1f, 10, 0.4f, 0.3f, 0.2f, 0.1f}, Ease::hold});
    clip->titles.push_back({5, 2, "kickflip!", 0.5f, 0.3f, 1.5f, TitleStyle::label});
    std::string why;
    const auto back = from_json(to_json(p), why);
    check(back.has_value(), "a project reads back: " + why);
    check(back->name == p.name && back->level == p.level && back->footage == p.footage, "project fields");
    const auto& c = back->clips.at(0);
    check(c.name == "opener" && near(c.in, 3) && near(c.out, 9) && near(c.hold, 0.5) && c.trick_labels, "clip fields");
    check(c.speed.size() == 1 && c.speed[0].ease == Ease::ease_out, "speed keys");
    check(c.camera.size() == 1 && c.camera[0].rig == Rig::orbit && c.camera[0].target.player == 76561198000000001ull &&
              c.camera[0].target.part == Part::head && c.camera[0].focus < 0,
          "camera keys keep a Steam id whole");
    check(c.look.size() == 1 && c.look[0].look == clamped(Look{0.5f, 0.2f, 1.1f, 10, 0.4f, 0.3f, 0.2f, 0.1f}) && c.look[0].ease == Ease::hold,
          "look keys");
    check(c.titles.size() == 1 && c.titles[0].text == "kickflip!" && c.titles[0].style == TitleStyle::label, "titles");
    check(!from_json("{}", why) && !from_json("not json", why), "not a project");
    check(!from_json(R"({"reskate_replay_project": 999})", why), "a newer project is refused");
    // Damaged values come back in range.
    const auto damaged = from_json(R"({"reskate_replay_project":1,"clips":[{"id":1,"in":9,"out":3,"hold":-4,
        "camera":[{"at":1,"fov":900,"pitch":400,"rig":"nonsense"}]}]})", why);
    check(damaged && damaged->clips[0].in < damaged->clips[0].out && damaged->clips[0].hold == 0 &&
              damaged->clips[0].camera[0].fov <= 140 && damaged->clips[0].camera[0].pitch <= 90 &&
              damaged->clips[0].camera[0].rig == Rig::free,
          "damaged values are made safe");
    check(file_stem("../../evil name.rsedit") == "evil_name_rsedit", "a name is made safe as a file name");
    // Saved and listed.
    const auto folder = std::filesystem::temp_directory_path() / "reskate-replay-editor-tests";
    std::filesystem::remove_all(folder);
    const auto path = save_project(folder, p, why);
    check(!path.empty() && std::filesystem::exists(path), "a project saves: " + why);
    const auto list = list_projects(folder);
    check(list.size() == 1 && list[0].name == p.name, "and is listed");
    check(load_project(path, why).has_value(), "and loads");
    std::filesystem::remove_all(folder);
    // The editor's settings read back as written.
    Settings settings;
    settings.open_with_replay = false;
    {
        // The game's shape: 1080 high and as wide as a 2.45:1 screen, in 16-pixel blocks; too wide made shorter.
        ExportChoice wide{0, 60, 1920, 1080, 24000, true, true};
        const auto [w, h] = export_size(wide, 5120.0f / 2089.0f);
        check(h == 1088 && w == 2640 && w % 16 == 0, "export size keeps the game's shape");
        wide.height = 2160;
        const auto [w4, h4] = export_size(wide, 5120.0f / 2089.0f);
        check(w4 == 3840 && h4 % 16 == 0 && h4 < 2160 && std::abs(3840.0 / h4 - 5120.0 / 2089.0) < 0.02, "export size stays within 3840 wide");
        wide.game_shape = false;
        const auto [wf, hf] = export_size(wide, 5120.0f / 2089.0f);
        check(wf == 1920 && hf == 2160, "export size as chosen without the game's shape");
    }
    settings.export_choice = {1, 30, 1280, 720, 6000, true};
    settings.preset = 3;
    const auto read = settings_from_text(to_text(settings));
    check(!read.open_with_replay && read.export_choice.format == 1 && read.export_choice.fps == 30 && read.export_choice.width == 1280 &&
              read.export_choice.kbps == 6000 && read.preset == 3,
          "settings read back");
}
} // namespace

int main() {
    try {
        edits();
        curves();
        cameras();
        program_clock();
        program_camera();
        files();
        std::cout << "replay editor tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "replay editor test failed: " << error.what() << '\n';
        return 1;
    }
}
