#include "replay_editor_internal.h"
#include <algorithm>
#include <cmath>
#include <format>

// The replay editor's timeline, as a video editor's: track names down the left; SOURCE, the whole
// recording as a filmstrip with what happened (tricks, slams, players) and the clips taken from it;
// then the SEQUENCE on its own clock: the edit's clips one after another as long as each plays, each
// with its pictures, and under them the camera, speed, look and title keys of every clip.
namespace dingosdk::overlay::replay_ui {
namespace {
constexpr float header_width = 96;

ImFont* font_or(ImFont* font) { return font ? font : ImGui::GetFont(); }

ImU32 moment_colour(re::MomentKind kind) {
    switch (kind) {
    case re::MomentKind::trick: return colour(255, 205, 40);
    case re::MomentKind::slam: return colour(235, 70, 60);
    case re::MomentKind::joined:
    case re::MomentKind::left: return colour(90, 170, 255);
    case re::MomentKind::mark: return colour(245, 245, 245);
    }
    return colour(245, 245, 245);
}

void track_header(ImDrawList* draw, ImVec2 a, ImVec2 z, const char* name, bool active) {
    auto& u = ui();
    draw->AddRectFilled(a, z, active ? colour(52, 66, 92) : palette::header);
    draw->AddLine({a.x, z.y}, {z.x, z.y}, palette::line);
    ImFont* font = font_or(u.fonts.bold);
    const float size = 12 * u.k;
    const auto extent = font->CalcTextSizeA(size, FLT_MAX, 0, name);
    draw->AddText(font, size, {a.x + 10 * u.k, a.y + (z.y - a.y - extent.y) / 2}, active ? palette::text : palette::dim, name);
}

// A time ruler: ticks as far apart as read well, labelled from `zero`.
void ruler(ImDrawList* draw, ImVec2 a, ImVec2 z, double from, double to, double zero) {
    auto& u = ui();
    draw->AddRectFilled(a, z, colour(30, 30, 30));
    const float w = z.x - a.x;
    const double span = std::max(1e-3, to - from);
    double step = 1;
    for (const double candidate : {0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0, 600.0})
        if (span / candidate <= w / (80 * u.k)) {
            step = candidate;
            break;
        }
    ImFont* font = font_or(u.fonts.body);
    for (double t = std::ceil((from - zero) / step) * step + zero; t <= to; t += step) {
        const float x = a.x + static_cast<float>((t - from) / span) * w;
        draw->AddLine({x, z.y - 7 * u.k}, {x, z.y}, colour(150, 150, 150));
        const auto label = timecode(t - zero);
        draw->AddText(font, 10.5f * u.k, {x + 3 * u.k, a.y + 1 * u.k}, colour(150, 150, 150), label.c_str());
    }
    for (double t = std::ceil((from - zero) / (step / 4)) * (step / 4) + zero; t <= to; t += step / 4) {
        const float x = a.x + static_cast<float>((t - from) / span) * w;
        draw->AddLine({x, z.y - 3 * u.k}, {x, z.y}, colour(90, 90, 90));
    }
}

void zoom_view(double& from, double& to, double pivot, double factor, double least_from, double most_to) {
    const double span = std::clamp((to - from) * factor, 1.0, std::max(1.0, most_to - least_from));
    const double fraction = (pivot - from) / std::max(1e-9, to - from);
    from = std::clamp(pivot - span * fraction, least_from, std::max(least_from, most_to - span));
    to = from + span;
}
} // namespace

std::vector<double> edit_points() {
    std::vector<double> points;
    const auto s = status();
    points.push_back(s.window_start);
    points.push_back(s.window_end);
    for (const auto& clip : ui().project.clips) {
        points.push_back(clip.in);
        points.push_back(clip.out);
    }
    if (const auto* clip = selected_clip()) {
        for (const auto& k : clip->camera) points.push_back(k.at);
        for (const auto& k : clip->speed) points.push_back(k.at);
        for (const auto& k : clip->look) points.push_back(k.at);
        for (const auto& t : clip->titles) points.push_back(t.at);
    }
    if (const auto moments = re::bridge().moments())
        for (const auto& m : *moments) points.push_back(m.at);
    if (ui().mark_in) points.push_back(*ui().mark_in);
    if (ui().mark_out) points.push_back(*ui().mark_out);
    std::sort(points.begin(), points.end());
    points.erase(std::unique(points.begin(), points.end(), [](double a, double b) { return std::abs(a - b) < 1.0 / 240; }), points.end());
    return points;
}

void draw_timeline(ImVec2 a, ImVec2 z) {
    auto& u = ui();
    const auto s = status();
    const float k = u.k;
    ImDrawList* draw = ImGui::GetWindowDrawList();
    const auto& io = ImGui::GetIO();
    draw->AddRectFilled(a, z, palette::panel);
    panel_tabs(draw, a, z.x - a.x, {"Timeline"}, 0);
    const float left = a.x + header_width * k, right = z.x - 8 * k, w = right - left;
    float y = a.y + 24 * k + 4 * k;
    const double t_now = now();

    // ---- SOURCE: the whole recording ---------------------------------------------------------
    const double window_from = s.window_start, window_to = std::max(s.window_end, s.window_start + 1);
    if (!(u.view_to > u.view_from) || u.view_to > window_to + 1 || u.view_from < window_from - 1) {
        u.view_from = window_from;
        u.view_to = window_to;
    }
    const auto x_of = [&](double t) { return left + static_cast<float>((t - u.view_from) / (u.view_to - u.view_from)) * w; };
    const auto t_of = [&](float x) { return u.view_from + (x - left) / w * (u.view_to - u.view_from); };
    const float source_top = y, ruler_h = 16 * k, film_h = 54 * k, marks_h = 16 * k;
    ruler(draw, {left, y}, {right, y + ruler_h}, u.view_from, u.view_to, window_from);
    track_header(draw, {a.x, y}, {left - 2 * k, y + ruler_h + film_h + marks_h}, "SOURCE", u.mode == re::PlayMode::footage);
    y += ruler_h;
    const float film_top = y, film_bottom = y + film_h;
    {
        const float cell = film_h * 16.0f / 9.0f;
        draw->PushClipRect({left, film_top}, {right, film_bottom}, true);
        for (float x = left; x < right; x += cell) {
            const ImVec2 ca{x, film_top}, cz{x + cell, film_bottom};
            if (const auto picture = filmstrip_cell(t_of(x + cell * 0.5f))) draw->AddImage(picture->texture, ca, cz, picture->uv0, picture->uv1);
            else draw->AddRectFilled(ca, cz, colour(44, 44, 44));
            draw->AddLine({x, film_top}, {x, film_bottom}, colour(0, 0, 0, 160));
        }
        // The clips taken from it: a band along the top and the pictures tinted.
        for (const auto& clip : u.project.clips) {
            const float ca = std::max(x_of(clip.in), left), cz = std::min(x_of(clip.out), right);
            if (cz < left || ca > right) continue;
            const bool selected = clip.id == u.selected;
            draw->AddRectFilled({ca, film_top}, {cz, film_bottom}, selected ? colour(110, 125, 200, 80) : colour(110, 125, 200, 40));
            draw->AddRectFilled({ca, film_top}, {cz, film_top + 4 * k}, selected ? palette::clip_selected : palette::clip);
        }
        // In to out, outlined.
        if (u.mark_in || u.mark_out) {
            const double ia = u.mark_in.value_or(window_from), oz = u.mark_out.value_or(t_now);
            const float xa = std::max(x_of(std::min(ia, oz)), left), xz = std::min(x_of(std::max(ia, oz)), right);
            draw->AddRectFilled({xa, film_top}, {xz, film_bottom}, colour(255, 255, 255, 40));
            draw->AddRect({xa, film_top}, {xz, film_bottom}, colour(255, 255, 255, 230), 0, 0, 2 * k);
        }
        draw->PopClipRect();
    }
    y = film_bottom;
    draw->AddRectFilled({left, y}, {right, y + marks_h}, colour(28, 28, 28));
    if (const auto moments = re::bridge().moments()) {
        const re::Moment* hovered = nullptr;
        for (const auto& m : *moments) {
            const float x = x_of(m.at);
            if (x < left || x > right) continue;
            const float height = m.kind == re::MomentKind::trick ? std::clamp(5 + m.points / 500.0f, 5.0f, 14.0f) * k : 8 * k;
            draw->AddRectFilled({x - 1.5f * k, y + marks_h - height - 1 * k}, {x + 1.5f * k, y + marks_h - 1 * k}, moment_colour(m.kind));
            if (std::abs(io.MousePos.x - x) < 4 * k && io.MousePos.y >= y && io.MousePos.y <= y + marks_h) hovered = &m;
        }
        if (hovered) {
            ImGui::BeginTooltip();
            if (hovered->kind == re::MomentKind::trick) ImGui::Text("%s  %.0f", hovered->text.c_str(), hovered->points);
            else if (hovered->kind == re::MomentKind::joined) ImGui::Text("%s joined", hovered->text.c_str());
            else if (hovered->kind == re::MomentKind::left) ImGui::Text("%s left", hovered->text.c_str());
            else ImGui::TextUnformatted(hovered->text.c_str());
            ImGui::TextDisabled("click to go there; C makes a clip of it");
            ImGui::EndTooltip();
            if (ImGui::IsMouseClicked(ImGuiMouseButton_Left)) seek(hovered->at);
        }
    }
    y += marks_h;
    // The source playhead.
    if (const float px = x_of(t_now); px >= left && px <= right) {
        draw->AddLine({px, source_top}, {px, y}, palette::playhead, 2 * k);
        draw->AddTriangleFilled({px - 6 * k, source_top}, {px + 6 * k, source_top}, {px, source_top + 8 * k}, palette::playhead);
    }
    // Scrub by pressing and dragging; the wheel zooms about the pointer; the middle or right button pans.
    const bool over_source = ImGui::IsMouseHoveringRect({left, source_top}, {right, film_bottom});
    if (over_source && ImGui::IsMouseClicked(ImGuiMouseButton_Left)) {
        u.scrubbing = true;
        u.mode = re::PlayMode::footage;
    }
    if (u.scrubbing) {
        if (ImGui::IsMouseDown(ImGuiMouseButton_Left)) {
            u.playing = false;
            seek(std::clamp(t_of(io.MousePos.x), window_from, window_to));
        } else u.scrubbing = false;
    }
    if (ImGui::IsMouseHoveringRect({left, source_top}, {right, y}) && io.MouseWheel != 0)
        zoom_view(u.view_from, u.view_to, t_of(io.MousePos.x), io.MouseWheel > 0 ? 0.8 : 1.25, window_from, window_to);
    if (ImGui::IsMouseHoveringRect({left, source_top}, {right, y}) &&
        (ImGui::IsMouseDragging(ImGuiMouseButton_Middle, 1) || ImGui::IsMouseDragging(ImGuiMouseButton_Right, 1))) {
        const double span = u.view_to - u.view_from, shift = -io.MouseDelta.x / w * span;
        u.view_from = std::clamp(u.view_from + shift, window_from, std::max(window_from, window_to - span));
        u.view_to = u.view_from + span;
    }
    y += 8 * k;

    // ---- SEQUENCE: the edit on its own clock -------------------------------------------------------
    const auto program = u.program;
    const double duration = program ? program->duration() : 0;
    const double shown_to = std::max(5.0, duration * 1.05);
    if (!(u.sequence_to > u.sequence_from) || u.sequence_to > shown_to * 4 + 10) {
        u.sequence_from = 0;
        u.sequence_to = shown_to;
    }
    const auto e_of = [&](double e) { return left + static_cast<float>((e - u.sequence_from) / (u.sequence_to - u.sequence_from)) * w; };
    const auto edit_at = [&](float x) { return u.sequence_from + (x - left) / w * (u.sequence_to - u.sequence_from); };
    const float sequence_top = y, track_h = 50 * k, lane_h = std::max(18.0f * k, (z.y - y - ruler_h - track_h - 8 * k) / 4);
    ruler(draw, {left, y}, {right, y + ruler_h}, u.sequence_from, u.sequence_to, 0);
    track_header(draw, {a.x, y}, {left - 2 * k, y + ruler_h}, "SEQUENCE", u.mode == re::PlayMode::edit);
    y += ruler_h;
    // V1: the clips, with their pictures.
    track_header(draw, {a.x, y}, {left - 2 * k, y + track_h}, "V1", u.lane == Lane::clips);
    draw->AddRectFilled({left, y}, {right, y + track_h}, palette::well);
    draw->PushClipRect({left, y}, {right, y + track_h}, true);
    ImFont* bold = font_or(u.fonts.bold);
    if (program && !program->empty()) {
        for (std::size_t i = 0; i < u.project.clips.size(); ++i) {
            const auto& clip = u.project.clips[i];
            const float ca = e_of(program->clip_start(i)), cz = e_of(program->clip_start(i) + program->clip_length(i));
            if (cz < left || ca > right) continue;
            const bool selected = clip.id == u.selected;
            const bool gone = clip.out < s.window_start || clip.in > s.window_end || u.project.footage != s.run;
            const ImVec2 ra{ca + 1, y + 3 * k}, rz{cz - 1, y + track_h - 3 * k};
            draw->AddRectFilled(ra, rz, gone ? colour(110, 50, 50) : selected ? palette::clip_selected : palette::clip, 3 * k);
            // Its pictures, along the part of it that plays footage.
            const float picture_w = (rz.y - ra.y - 16 * k) * 16.0f / 9.0f;
            draw->PushClipRect({std::max(ra.x, left), ra.y}, {std::min(rz.x, right), rz.y}, true);
            for (float x = ra.x + 2 * k; x < rz.x && picture_w > 4; x += picture_w) {
                const double e = edit_at(x + picture_w * 0.5f);
                if (const auto place = program->at_edit(e); place && place->clip == i)
                    if (const auto picture = filmstrip_cell(place->replay))
                        draw->AddImage(picture->texture, {x, ra.y + 16 * k}, {x + picture_w, rz.y - 2 * k}, picture->uv0, picture->uv1);
            }
            draw->AddText(bold, 11.5f * k, {ra.x + 5 * k, ra.y + 2 * k}, colour(255, 255, 255), clip.name.c_str());
            draw->PopClipRect();
            if (clip.hold > 0) {
                const float hold_x = e_of(program->clip_start(i) + program->clip_length(i) - clip.hold);
                draw->AddRectFilled({hold_x, ra.y}, rz, colour(255, 255, 255, 60), 3 * k);
            }
            if (selected) draw->AddRect(ra, rz, colour(255, 255, 255), 3 * k, 0, 1.5f * k);
        }
    } else {
        draw->AddText(font_or(u.fonts.body), 12.5f * k, {left + 10 * k, y + track_h / 2 - 8 * k}, palette::dim,
                      "Empty sequence: set In (I) and Out (O) on SOURCE and press A, or press C beside a moment.");
    }
    draw->PopClipRect();
    const float track_top = y;
    // Press a clip to pick it and play the sequence from there; drag it to move it; drag its ends to trim.
    const bool over_track = ImGui::IsMouseHoveringRect({left, track_top}, {right, track_top + track_h});
    if (over_track && ImGui::IsMouseClicked(ImGuiMouseButton_Left) && program && !program->empty()) {
        const double e = std::clamp(edit_at(io.MousePos.x), 0.0, duration);
        if (const auto place = program->at_edit(e)) {
            const auto& clip = u.project.clips[place->clip];
            const float ca = e_of(program->clip_start(place->clip)), cz = e_of(program->clip_start(place->clip) + program->clip_length(place->clip));
            u.selected = clip.id;
            u.key.reset();
            u.lane = Lane::clips;
            u.drag_clip = clip.id;
            u.drag_edge = io.MousePos.x < ca + 8 * k ? -1 : io.MousePos.x > cz - 8 * k ? 1 : 0;
            u.drag_from_in = clip.in;
            u.drag_from_out = clip.out;
            u.drag_x = io.MousePos.x;
            u.drag_remembered = false;
            u.mode = re::PlayMode::edit;
            seek(place->replay, static_cast<int>(place->clip));
        }
    }
    if (u.drag_clip && ImGui::IsMouseDragging(ImGuiMouseButton_Left, 4) && program) {
        if (const auto index = re::clip_index(u.project, u.drag_clip)) {
            if (!u.drag_remembered) {
                remember();
                u.drag_remembered = true;
            }
            if (u.drag_edge == 0) {
                const double e = std::clamp(edit_at(io.MousePos.x), 0.0, duration);
                std::size_t target = u.project.clips.size() - 1;
                for (std::size_t i = 0; i < u.project.clips.size(); ++i)
                    if (e < program->clip_start(i) + program->clip_length(i)) {
                        target = i;
                        break;
                    }
                if (target != *index && re::move_clip(u.project, u.drag_clip, target)) changed();
            } else {
                const double moved = (io.MousePos.x - u.drag_x) / w * (u.sequence_to - u.sequence_from);
                const std::array<double, 2> window{s.window_start, s.window_end};
                if (u.drag_edge < 0) re::trim_clip(u.project, u.drag_clip, u.drag_from_in + moved, u.drag_from_out, window);
                else re::trim_clip(u.project, u.drag_clip, u.drag_from_in, u.drag_from_out + moved, window);
                changed();
                if (const auto* clip = re::find_clip(u.project, u.drag_clip)) seek(u.drag_edge < 0 ? clip->in : clip->out);
            }
        }
    }
    y += track_h;
    // The keys of every clip, at their places in the sequence.
    const Lane lanes[]{Lane::camera, Lane::speed, Lane::look, Lane::titles};
    const char* names[]{"CAMERA", "SPEED", "LOOK", "TITLES"};
    const ImU32 fills[]{palette::camera_key, palette::speed_key, palette::look_key, palette::title_key};
    for (int lane = 0; lane < 4; ++lane) {
        const ImVec2 la{left, y}, lz{right, y + lane_h};
        track_header(draw, {a.x, y}, {left - 2 * k, y + lane_h}, names[lane], u.lane == lanes[lane]);
        draw->AddRectFilled(la, lz, lane % 2 ? colour(30, 30, 30) : colour(33, 33, 33));
        draw->PushClipRect(la, lz, true);
        struct Hit {
            std::size_t clip;
            double at;
            float x;
        };
        std::vector<Hit> hits;
        if (program)
            for (std::size_t i = 0; i < u.project.clips.size(); ++i) {
                const auto& clip = u.project.clips[i];
                const bool selected_clip_lane = clip.id == u.selected;
                const auto put = [&](double at) {
                    if (at < clip.in - 1e-6 || at > clip.out + 1e-6) return;
                    const float x = e_of(program->edit_time(i, at));
                    const bool selected = selected_clip_lane && u.key && u.key->lane == lanes[lane] && std::abs(u.key->at - at) < re::same_key;
                    diamond(draw, {x, (la.y + lz.y) / 2}, 5.5f * k, fills[lane], selected);
                    hits.push_back({i, at, x});
                };
                if (lanes[lane] == Lane::speed) {
                    // The speed curve: 0.05x at the bottom to 2x at the top.
                    ImVec2 previous{};
                    for (int p = 0; p <= 48; ++p) {
                        const double at = clip.in + clip.length() * p / 48.0;
                        const float v = std::clamp(program->speed(i, at), 0.0f, 2.0f);
                        const ImVec2 point{e_of(program->edit_time(i, at)), lz.y - 3 * k - (lane_h - 6 * k) * v / 2};
                        if (p) draw->AddLine(previous, point, colour(120, 220, 140, 200), 1.5f * k);
                        previous = point;
                    }
                    for (const auto& key : clip.speed) put(key.at);
                } else if (lanes[lane] == Lane::camera) for (const auto& key : clip.camera) put(key.at);
                else if (lanes[lane] == Lane::look) for (const auto& key : clip.look) put(key.at);
                else
                    for (const auto& title : clip.titles) {
                        const float ta = e_of(program->edit_time(i, title.at)), tz = e_of(program->edit_time(i, std::min(clip.out, title.at + title.length)));
                        draw->AddRectFilled({ta, la.y + 4 * k}, {std::max(ta + 4 * k, tz), lz.y - 4 * k}, colour(235, 235, 235, 150), 3 * k);
                        draw->AddText(font_or(u.fonts.body), 10.5f * k, {ta + 3 * k, la.y + 4 * k}, colour(20, 20, 20), title.text.c_str());
                        hits.push_back({i, title.at, ta});
                    }
            }
        draw->PopClipRect();
        // Press a key to pick it (and go there); drag to move it inside its clip; the right button takes it off.
        if (ImGui::IsMouseHoveringRect(la, lz) && (ImGui::IsMouseClicked(ImGuiMouseButton_Left) || ImGui::IsMouseClicked(ImGuiMouseButton_Right))) {
            u.lane = lanes[lane];
            const Hit* best = nullptr;
            for (const auto& hit : hits)
                if (std::abs(hit.x - io.MousePos.x) < 8 * k && (!best || std::abs(hit.x - io.MousePos.x) < std::abs(best->x - io.MousePos.x))) best = &hit;
            if (best) {
                u.selected = u.project.clips[best->clip].id;
                u.key = KeyRef{lanes[lane], best->at};
                if (lanes[lane] == Lane::titles) u.effects_tab = EffectsTab::titles;
                if (ImGui::IsMouseClicked(ImGuiMouseButton_Right)) delete_selection();
                else {
                    u.drag_key = u.key;
                    u.drag_key_from = best->at;
                    u.drag_remembered = false;
                    seek(best->at, static_cast<int>(best->clip));
                }
            } else if (program && !program->empty()) {
                if (const auto place = program->at_edit(std::clamp(edit_at(io.MousePos.x), 0.0, duration))) {
                    u.selected = u.project.clips[place->clip].id;
                    u.key.reset();
                    seek(place->replay, static_cast<int>(place->clip));
                }
            }
        }
        if (u.drag_key && u.drag_key->lane == lanes[lane] && lanes[lane] != Lane::titles && ImGui::IsMouseDragging(ImGuiMouseButton_Left, 3) && program) {
            if (auto* clip = selected_clip())
                if (const auto index = re::clip_index(u.project, clip->id))
                    if (const auto place = program->at_edit(std::clamp(edit_at(io.MousePos.x), 0.0, duration)); place && place->clip == *index) {
                        const auto move = [&](auto& keys) {
                            auto* key = re::key_at(keys, u.drag_key->at);
                            if (!key) return;
                            for (const auto& other : keys)
                                if (&other != key && std::abs(other.at - place->replay) < re::same_key * 2) return;
                            if (!u.drag_remembered) {
                                remember();
                                u.drag_remembered = true;
                                key = re::key_at(keys, u.drag_key->at);
                            }
                            key->at = place->replay;
                            std::stable_sort(keys.begin(), keys.end(), [](const auto& x, const auto& y) { return x.at < y.at; });
                            u.drag_key->at = place->replay;
                            u.key = u.drag_key;
                            changed();
                        };
                        if (lanes[lane] == Lane::camera) move(clip->camera);
                        else if (lanes[lane] == Lane::speed) move(clip->speed);
                        else if (lanes[lane] == Lane::look) move(clip->look);
                    }
        }
        if (ImGui::IsMouseHoveringRect({a.x, y}, {left, y + lane_h}) && ImGui::IsMouseClicked(ImGuiMouseButton_Left)) u.lane = lanes[lane];
        y += lane_h;
    }
    // Scrub the sequence on its ruler; the wheel zooms it.
    const bool over_ruler = ImGui::IsMouseHoveringRect({left, sequence_top}, {right, sequence_top + ruler_h});
    if (over_ruler && ImGui::IsMouseClicked(ImGuiMouseButton_Left)) u.sequence_scrubbing = true;
    if (u.sequence_scrubbing) {
        if (ImGui::IsMouseDown(ImGuiMouseButton_Left) && program && !program->empty()) {
            u.playing = false;
            u.mode = re::PlayMode::edit;
            if (const auto place = program->at_edit(std::clamp(edit_at(io.MousePos.x), 0.0, duration))) seek(place->replay, static_cast<int>(place->clip));
        } else u.sequence_scrubbing = false;
    }
    if (ImGui::IsMouseHoveringRect({left, sequence_top}, {right, z.y}) && io.MouseWheel != 0)
        zoom_view(u.sequence_from, u.sequence_to, edit_at(io.MousePos.x), io.MouseWheel > 0 ? 0.8 : 1.25, 0, shown_to);
    // The sequence's playhead, while the playhead is in a clip of it.
    if (const auto e = sequence_now()) {
        const float px = e_of(*e);
        if (px >= left && px <= right) {
            draw->AddLine({px, sequence_top}, {px, y}, palette::playhead, 2 * k);
            draw->AddTriangleFilled({px - 6 * k, sequence_top}, {px + 6 * k, sequence_top}, {px, sequence_top + 8 * k}, palette::playhead);
        }
    }
    if (!ImGui::IsMouseDown(ImGuiMouseButton_Left)) {
        u.drag_clip = 0;
        u.drag_key.reset();
    }
}
} // namespace dingosdk::overlay::replay_ui
