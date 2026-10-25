add_library(dingosdk_steam_restart_guard STATIC
    Extension/Boot/steam_restart_guard.cpp
    Extension/Boot/offline_steam.cpp)

target_link_libraries(dingosdk_steam_restart_guard PUBLIC dingosdk_launcher_support dingosdk_hooks dingosdk_logging)
add_library(dingosdk_startup_interventions STATIC
    Extension/Boot/startup_interventions.cpp)

add_library(dingosdk_fast_travel_unlock STATIC
    Extension/Progression/fast_travel_unlock.cpp)

add_library(dingosdk_local_profile STATIC
    Extension/Profile/local_profile.cpp
    Extension/Profile/profile_defaults.cpp
    Extension/Profile/local_profile_store.cpp
    Extension/Profile/profile_update.cpp
    Extension/Profile/database_schema.cpp
    Extension/Profile/database_codec.cpp
    Extension/Objects/placement_database.cpp
    Extension/Objects/object_categories.cpp
    Extension/Profile/local_profile_legacy.cpp
    Extension/Customization/local_customization.cpp
    Extension/News/news_feed.cpp
    Extension/Progression/rip_score.cpp
    Extension/World/profile_policy.cpp
    Extension/Rendering/profile_policy.cpp
    Extension/Settings/input_bindings.cpp
    Extension/Progression/challenge_profile.cpp
    Extension/Objects/placements_store.cpp
    Extension/Objects/ParkEditor/park_document.cpp
    Extension/Objects/ParkEditor/park_mods.cpp
    Extension/Objects/ParkEditor/park_object_sets.cpp
)
target_link_libraries(dingosdk_local_profile PUBLIC dingosdk_fast_travel_unlock dingosdk_content_cache dingosdk_json dingosdk_storage dingosdk_mod_list)

include(cmake/ProfileData.cmake)

# Screen captures (Extension/Rendering/Capture, reskate.capture): the recording, matting, the card and the
# GIF / APNG / PNG writers, and WebM through a small VP8 encoder of its own (from Fit Check, pull request
# 326). No Windows or game code, so its tests run anywhere.
add_library(dingosdk_capture STATIC
    Extension/Rendering/Capture/capture_image.cpp
    Extension/Rendering/Capture/capture_matte.cpp
    Extension/Rendering/Capture/capture_panel.cpp
    Extension/Rendering/Capture/capture_png.cpp
    Extension/Rendering/Capture/capture_gif.cpp
    Extension/Rendering/Capture/capture_vp8.cpp
    Extension/Rendering/Capture/capture_webm.cpp
    Extension/Rendering/Capture/capture_recorder.cpp)
target_include_directories(dingosdk_capture PUBLIC "${PROJECT_SOURCE_DIR}")
# stb_truetype, as shipped with Dear ImGui.
target_include_directories(dingosdk_capture SYSTEM PRIVATE "${PROJECT_SOURCE_DIR}/External/imgui")
target_link_libraries(dingosdk_capture PUBLIC dingosdk_miniz)

# ReSkate's replay editor, the parts with no game code (Extension/ReplayEditor): the edit, its curves and
# camera maths, the edit made playable, project files and what the screen and the game's side share. The
# overlay draws the editor with it; the game's side (replay_session.cpp) is in the DLL.
add_library(dingosdk_replay_editor STATIC
    Extension/ReplayEditor/replay_edit.cpp
    Extension/ReplayEditor/replay_motion.cpp
    Extension/ReplayEditor/replay_program.cpp
    Extension/ReplayEditor/replay_project_file.cpp
    Extension/ReplayEditor/replay_bridge.cpp)
target_include_directories(dingosdk_replay_editor PUBLIC "${PROJECT_SOURCE_DIR}")
target_link_libraries(dingosdk_replay_editor PUBLIC dingosdk_json PRIVATE shell32 ole32)
