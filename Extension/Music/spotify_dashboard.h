#pragma once
#include <string>

// A page in the player's browser for setting Spotify up, served by the game on this computer
// alone (http://127.0.0.1:8421): the game's Spotify device and whether an account is on it,
// the sign-in that lists the player's playlists (its client id, signing in and out), what is
// playing with play, pause and next, and how loud it is through the game. "spotify setup" in
// the console opens it.
//
// It listens on the loopback address only, answers only requests addressed to it by that
// address, and takes changes only from its own page (a header a page of another site cannot
// send without being refused first).
namespace dingosdk::spotify_dashboard {
// Starts serving, once, on a thread of its own.
void start() noexcept;
// The page's address, or empty when it is not being served.
std::string address();
// Opens it in the player's browser.
bool open() noexcept;
}
