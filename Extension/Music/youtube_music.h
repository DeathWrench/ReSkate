#pragma once
#include "external_player.h"
#include <string>
#include <vector>

// "YouTube Music" in the game's music screen: videos and playlists the player has added by
// their links (in the setup page, spotify_dashboard.h), each a tile there with its songs as
// rows. A song's sound is fetched by yt-dlp, which this runs, and decoded by the library that
// is built into the DLL (SpotifyHelper/src/stream.rs); it is heard through the game as
// Spotify's is.
//
// yt-dlp is not part of ReSkate: the player has it fetched from the setup page, from its own
// releases on GitHub, into <Local AppData>\ReSkate\bin. What is added is kept in
// <Local AppData>\ReSkate\youtube-music.json.
namespace dingosdk::youtube_music {
// What a station's playlist is called among the stations (spotify_station.h): this and its
// number; what a row's track is called: this and the video's id.
inline constexpr char station_prefix[] = "~yt:";
inline constexpr char track_prefix[] = "yt:";
// What the ids of its row's playlists in the music screen begin with.
inline constexpr char playlist_prefix[] = "youtube:";

struct Song {
    std::string id, artist, title;
};
struct Playlist {
    std::string name, url;
    std::string artwork; // served by the artwork server, or empty
    std::vector<Song> songs;
};
struct State {
    bool available{}; // the DLL was built with the library that decodes
    bool tools{};     // yt-dlp is there
    bool busy{};
    unsigned percent{}; // of yt-dlp fetched, while it is being
    std::string problem;
    std::string browser; // whose YouTube sign-in yt-dlp uses, or empty
    bool cookies{};      // a cookies.txt of the player's is kept, and is what it uses
    std::string runtime; // the JavaScript runtime yt-dlp is given ("node", "deno"), or empty: a sign-in does not work without one
    std::vector<Playlist> playlists;
};
// Reads what was kept, once, on a thread of its own, which does what takes time below.
void start() noexcept;
State state();
std::vector<Playlist> playlists();
// Fetches yt-dlp. Adds what a link is of (a video, a playlist). Takes one out.
void fetch_tools();
void add(const std::string& link);
void remove(std::size_t playlist);
// The browser whose YouTube sign-in yt-dlp is to use ("firefox", "edge", "chrome", "brave",
// "opera", "vivaldi"; empty for none): YouTube asks for one before it plays songs it has
// marked as not for everyone.
void set_browser(const std::string& browser);
// The same sign-in as a file: a Netscape cookies.txt the player exported from their browser
// (what private and age-restricted songs need), kept as
// <Local AppData>\ReSkate\youtube-cookies.txt and used before any browser. Empty takes it away.
// False when what was given is no such file.
bool set_cookies(const std::string& text);

// Whether one of its stations is the one that is on.
bool on() noexcept;
void set_on(bool on) noexcept;
// The rate of the sound it is giving, in Hz.
unsigned rate() noexcept;
// Plays a playlist, from a song of it when given (its video's id), else from where it was.
void play(std::size_t playlist, const std::string& song = {});
// What is playing, as external_player gives it; and play, pause, next and previous.
external_player::Track now();
std::uint64_t revision() noexcept;
void send(external_player::Command command) noexcept;
}
