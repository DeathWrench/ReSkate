#include "spotify_dashboard.h"
#include "external_player.h"
#include "external_audio.h"
#include "youtube_music.h"
#include "app_audio_capture.h"
#include "local_music_ui.h"
#include "music_inject.h"
#include "spotify_cover.h"
#include "spotify_device.h"
#include "spotify_station.h"
#include "spotify_web.h"
#include "Engine/Core/Json/json.h"
#include "Engine/Core/Log/logging.h"
#include <WinSock2.h>
#include <WS2tcpip.h>
#include <Windows.h>
#include <shellapi.h>
#include <algorithm>
#include <atomic>
#include <format>
#include <string>
#include <thread>

namespace dingosdk::spotify_dashboard {
namespace {
constexpr unsigned short first_port = 8421;
std::atomic<unsigned short> port{};
std::atomic<bool> started{};

constexpr char page[] = R"html(<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ReSkate · Spotify</title>
<style>
:root{--bg:#101214;--card:#1a1d21;--line:#2a2f36;--text:#e9edf1;--dim:#98a2ad;--green:#1ed760;--warn:#ffb454}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,Segoe UI,sans-serif}
main{max-width:760px;margin:0 auto;padding:28px 16px 60px}h1{font-size:22px;margin:0 0 4px}p.sub{color:var(--dim);margin:0 0 22px}
section{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px;margin:0 0 16px}
h2{font-size:15px;margin:0 0 10px;letter-spacing:.02em}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.grow{flex:1;min-width:0}
.dot{width:10px;height:10px;border-radius:50%;background:#555;flex:none}.dot.on{background:var(--green)}.dot.warn{background:var(--warn)}
.dim{color:var(--dim)}small{color:var(--dim)}
button{background:#2a2f36;color:var(--text);border:1px solid #3a414a;border-radius:8px;padding:8px 14px;font:inherit;cursor:pointer}
button:hover{background:#343a43}button.primary{background:var(--green);border-color:var(--green);color:#04130a;font-weight:600}
input[type=text]{background:#0e1012;color:var(--text);border:1px solid #3a414a;border-radius:8px;padding:8px 10px;font:inherit;width:100%}
input[type=range]{width:100%}select{background:#0e1012;color:var(--text);border:1px solid #3a414a;border-radius:8px;padding:8px 10px;font:inherit;width:100%}
.now{display:flex;gap:14px;align-items:center}.now img{width:72px;height:72px;border-radius:8px;object-fit:cover;background:#0e1012}
.title{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
ol{margin:8px 0 0;padding-left:20px;color:var(--dim)}ul{margin:8px 0 0;padding:0;list-style:none}li.pl{display:flex;justify-content:space-between;padding:6px 0;border-top:1px solid var(--line)}
code{background:#0e1012;border:1px solid var(--line);border-radius:6px;padding:1px 6px}
.note{color:var(--warn)}
</style></head><body><main>
<h1>ReSkate · Spotify</h1><p class="sub">Set up Spotify for the in-game music player. This page is only reachable from this computer.</p>

<section><h2>Now playing</h2>
<div class="now"><img id="cover" alt=""><div class="grow"><div class="title" id="title">Nothing yet</div><div class="dim" id="artist"></div><small id="tile"></small></div></div>
<div class="row" style="margin-top:12px"><button data-cmd="previous">Previous</button><button data-cmd="toggle" id="toggle">Play</button><button data-cmd="next">Next</button></div>
</section>

<section><h2>Spotify device</h2>
<div class="row"><span class="dot" id="deviceDot"></span><div class="grow" id="deviceText">…</div></div>
<ol id="deviceSteps"><li>Open Spotify on your phone or this computer (same network as this PC).</li><li>Open the device list and pick <b>ReSkate</b>.</li><li>That is remembered: next time it connects by itself.</li></ol>
<small>Needs Spotify Premium. Audio comes straight from Spotify into the game.</small>
</section>

<section><h2>Your playlists</h2>
<div class="row"><span class="dot" id="accountDot"></span><div class="grow" id="accountText">…</div><button id="login" class="primary">Sign in</button><button id="logout">Sign out</button><button id="refresh">Refresh</button></div>
<div id="clientBox" style="margin-top:12px"><small>Listing your playlists uses a Spotify developer app. Create one at developer.spotify.com, add the redirect URI <code>http://127.0.0.1:47824/callback</code>, and paste its client ID here.</small>
<div class="row" style="margin-top:8px"><div class="grow"><input type="text" id="client" placeholder="Client ID" autocomplete="off" spellcheck="false"></div><button id="saveClient">Save</button></div></div>
<div class="note" id="problem"></div>
<ul id="playlists"></ul>
<small>New playlists appear as tiles in the game's music screen the next time it is opened. A whole new row may need the game restarted.</small>
</section>

<section><h2>YouTube Music</h2>
<div id="ytSetup"><small>Plays YouTube videos and playlists through the game. It needs <b>yt-dlp</b>, a free tool that is not part of ReSkate: this downloads it (about 18 MB) from its own releases on GitHub into your ReSkate folder. Using it is against YouTube's terms of service; that choice is yours.</small>
<div class="row" style="margin-top:10px"><button id="ytTools" class="primary">Set up YouTube Music</button><small id="ytProgress"></small></div></div>
<div id="ytReady"><small>Paste a link to a YouTube or YouTube Music video or playlist (up to 100 songs each).</small>
<div class="row" style="margin-top:8px"><div class="grow"><input type="text" id="ytLink" placeholder="https://music.youtube.com/playlist?list=…" autocomplete="off" spellcheck="false"></div><button id="ytAdd">Add</button></div>
<ul id="ytLists"></ul>
<div style="margin-top:14px"><b>Private and age-restricted songs</b><br><small>These need your YouTube sign-in as a Netscape <code>cookies.txt</code> exported from your browser. Use an extension like <i>Get cookies.txt LOCALLY</i> on youtube.com to export it, then choose the file here. It is kept on this computer only, in your ReSkate folder; treat it like a password. With a sign-in set, each song takes a few seconds longer to start.</small>
<div class="row" style="margin-top:8px"><input type="file" id="ytCookies" accept=".txt,text/plain"><button id="ytCookiesRemove">Remove cookies.txt</button><small id="ytCookiesText"></small></div><div class="note" id="ytRuntime"></div></div>
<div class="row" style="margin-top:10px"><div style="width:190px">YouTube sign-in from</div><div class="grow"><select id="ytBrowser"><option value="">None</option><option value="firefox">Firefox</option><option value="edge">Edge</option><option value="chrome">Chrome</option><option value="brave">Brave</option><option value="opera">Opera</option><option value="vivaldi">Vivaldi</option></select></div></div>
<small>Or let yt-dlp read the sign-in from a browser directly. Firefox works best; Chrome and Edge often refuse while they are open. A cookies.txt, when you have added one, is used instead.</small><br><small>New playlists appear as tiles in the game's music screen the next time it is opened. A whole new row may need the game restarted.</small></div>
<div class="note" id="ytProblem"></div><small id="ytNone"></small>
</section>

<section><h2>External audio</h2>
<small>Play any app on this computer through the game: pick it here, then choose the <b>External Audio</b> tile in the game's music screen. The app's own sound is turned down while it plays through the game.</small>
<div class="row" style="margin-top:10px"><div class="grow"><select id="app"></select></div><button id="saveApp">Use this app</button></div>
<small id="appText"></small>
</section>

<section><h2>Sound</h2>
<div class="row"><div style="width:130px">Loudness <b id="gainText"></b></div><div class="grow"><input type="range" id="gain" min="0" max="400" step="5"></div></div>
<div class="row" style="margin-top:10px"><label><input type="checkbox" id="speakers"> Speakers in the world play Spotify too</label></div>
</section>
</main>
<script>
const $=id=>document.getElementById(id);let busy=false,gainHeld=0,cookieNote=0;
async function post(path,body){await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','X-ReSkate':'1'},body:JSON.stringify(body||{})});load()}
document.querySelectorAll('[data-cmd]').forEach(b=>b.onclick=()=>post('/api/command',{command:b.dataset.cmd}));
$('login').onclick=()=>post('/api/login');$('logout').onclick=()=>post('/api/logout');$('refresh').onclick=()=>post('/api/refresh');
$('saveClient').onclick=()=>post('/api/client',{id:$('client').value.trim()});
$('gain').oninput=()=>{gainHeld=Date.now();$('gainText').textContent=$('gain').value+'%'};$('gain').onchange=()=>post('/api/settings',{gain:+$('gain').value});
$('ytTools').onclick=()=>post('/api/youtube/tools');
$('ytAdd').onclick=()=>{const link=$('ytLink').value.trim();if(link){$('ytLink').value='';post('/api/youtube/add',{link})}};
$('ytCookies').onchange=async()=>{const f=$('ytCookies').files[0];if(!f)return;const text=await f.text();$('ytCookies').value='';
const r=await fetch('/api/youtube/cookies',{method:'POST',headers:{'Content-Type':'application/json','X-ReSkate':'1'},body:JSON.stringify({text})});
$('ytCookiesText').textContent=r.ok?'Saved.':'That is not a Netscape cookies.txt with YouTube cookies in it.';cookieNote=Date.now();load()};
$('ytCookiesRemove').onclick=()=>post('/api/youtube/cookies',{text:''});
$('ytBrowser').onchange=()=>post('/api/youtube/browser',{browser:$('ytBrowser').value});
$('saveApp').onclick=()=>post('/api/external',{app:$('app').value});
$('speakers').onchange=()=>post('/api/settings',{speakers:$('speakers').checked});
async function load(){if(busy)return;busy=true;try{const s=await (await fetch('/api/state')).json();
$('title').textContent=s.now.title||'Nothing yet';$('artist').textContent=s.now.artist||'';$('toggle').textContent=s.now.playing?'Pause':'Play';
$('tile').textContent=s.station?'A Spotify tile is on in the game':'No Spotify tile is on in the game: pick one in the music screen to hear it';
if(s.now.cover){if($('cover').dataset.src!==s.now.cover){$('cover').dataset.src=s.now.cover;$('cover').src=s.now.cover}}else{$('cover').removeAttribute('src');$('cover').dataset.src=''}
$('deviceDot').className='dot'+(s.device.connected?' on':' warn');$('deviceText').textContent=s.device.text;$('deviceSteps').style.display=s.device.connected?'none':'';
const a=s.account;$('accountDot').className='dot'+(a.signed_in?' on':'');
$('accountText').textContent=a.signed_in?('Signed in'+(a.user?' as '+a.user:'')+(a.busy?' · working…':'')):(a.has_client?'Not signed in':'No client ID yet');
$('login').style.display=a.signed_in||!a.has_client?'none':'';$('logout').style.display=a.signed_in?'':'none';$('refresh').style.display=a.signed_in?'':'none';
$('clientBox').style.display=a.signed_in?'none':'';if(document.activeElement!==$('client')&&!$('client').value)$('client').value=a.client||'';
$('problem').textContent=a.problem||'';
$('playlists').innerHTML='';for(const p of a.playlists){const li=document.createElement('li');li.className='pl';const n=document.createElement('span');n.textContent=p.name;const c=document.createElement('small');c.textContent=p.tracks+' tracks';li.append(n,c);$('playlists').append(li)}
const y=s.youtube;$('ytNone').textContent=y.available?'':'This ReSkate.dll was built without the part that plays it.';
$('ytSetup').style.display=y.available&&!y.tools?'':'none';$('ytReady').style.display=y.available&&y.tools?'':'none';
$('ytProgress').textContent=y.busy&&!y.tools?('Downloading… '+(y.percent?y.percent+'%':'')):'';$('ytTools').disabled=y.busy;$('ytAdd').disabled=y.busy;$('ytAdd').textContent=y.busy?'Working…':'Add';
$('ytProblem').textContent=y.problem||'';$('ytCookiesRemove').style.display=y.cookies?'':'none';$('ytRuntime').textContent=(y.cookies||y.browser)&&!y.runtime?'Getting what the sign-in needs (a small JavaScript runtime)… songs will not play until it is here. If this stays, check your connection or install Node.js (nodejs.org).':'';if(Date.now()-cookieNote>4000)$('ytCookiesText').textContent=y.cookies?'A cookies.txt is in use.':'';if(document.activeElement!==$('ytBrowser'))$('ytBrowser').value=y.browser||'';$('ytLists').innerHTML='';
y.playlists.forEach((p,i)=>{const li=document.createElement('li');li.className='pl';const n=document.createElement('span');n.textContent=p.name+' · '+p.songs+' songs';const b=document.createElement('button');b.textContent='Remove';b.onclick=()=>post('/api/youtube/remove',{index:i});li.append(n,b);$('ytLists').append(li)});
if(document.activeElement!==$('app')){const e=s.external,names=e.apps.includes(e.app)||!e.app?e.apps:[e.app,...e.apps];$('app').innerHTML='';
for(const n of names){const o=document.createElement('option');o.value=n;o.textContent=n+(e.apps.includes(n)?'':' (not playing sound now)');$('app').append(o)}if(e.app)$('app').value=e.app}
$('appText').textContent=s.external.app?('Using '+s.external.app+(s.external.on?' · on now · '+s.external.capture:'')):'No app picked yet. Only apps that are making sound right now are listed: start it playing first.';
if(Date.now()-gainHeld>1500){$('gain').value=s.settings.gain;$('gainText').textContent=s.settings.gain+'%'}$('speakers').checked=s.settings.speakers;
}catch(e){$('deviceText').textContent='The game is not answering (is it still running?)'}busy=false}
load();setInterval(load,2000);
</script></body></html>)html";

std::string state_json() {
    Json out = Json::object();
    const auto track = external_player::now();
    Json now = Json::object();
    now["artist"] = track.available ? track.artist : std::string();
    now["title"] = track.available ? track.title : std::string();
    now["playing"] = track.available && track.playing;
    now["cover"] = track.available ? spotify_cover::url() : std::string();
    out["now"] = std::move(now);
    out["station"] = spotify_station::active();
    Json device = Json::object();
    device["connected"] = spotify_device::connected();
    device["text"] = spotify_device::status();
    out["device"] = std::move(device);
    const auto account_state = spotify_web::state();
    Json account = Json::object();
    account["has_client"] = account_state.has_client;
    account["signed_in"] = account_state.signed_in;
    account["busy"] = account_state.busy;
    account["user"] = account_state.user;
    account["problem"] = account_state.problem;
    account["client"] = spotify_web::client();
    Json playlists = Json::array();
    for (const auto& playlist : spotify_web::playlists()) {
        Json entry = Json::object();
        entry["name"] = playlist.name;
        entry["tracks"] = static_cast<std::uint64_t>(playlist.tracks.size());
        playlists.push_back(std::move(entry));
    }
    account["playlists"] = std::move(playlists);
    out["account"] = std::move(account);
    {
        const auto tube = youtube_music::state();
        Json youtube = Json::object();
        youtube["available"] = tube.available;
        youtube["tools"] = tube.tools;
        youtube["busy"] = tube.busy;
        youtube["percent"] = static_cast<std::uint64_t>(tube.percent);
        youtube["problem"] = tube.problem;
        youtube["browser"] = tube.browser;
        youtube["cookies"] = tube.cookies;
        youtube["runtime"] = tube.runtime;
        Json lists = Json::array();
        for (const auto& playlist : tube.playlists) {
            Json entry = Json::object();
            entry["name"] = playlist.name;
            entry["songs"] = static_cast<std::uint64_t>(playlist.songs.size());
            lists.push_back(std::move(entry));
        }
        youtube["playlists"] = std::move(lists);
        out["youtube"] = std::move(youtube);
    }
    Json external = Json::object();
    external["app"] = external_audio::app();
    external["on"] = external_audio::on();
    {
        // (How its capture is going, for the player who hears nothing.)
        const auto capture = app_audio::state();
        external["capture"] = !external_audio::on() ? std::string()
            : !capture.capturing ? "Not capturing it" + (capture.problem.empty() ? std::string() : ": " + capture.problem)
            : capture.level > 0.0005f ? std::string("Capturing it: sound is coming through") : std::string("Capturing it, but it is silent: is it playing, and not muted in Windows' volume mixer?");
    }
    Json apps = Json::array();
    for (const auto& name : external_audio::apps()) apps.push_back(name);
    external["apps"] = std::move(apps);
    out["external"] = std::move(external);
    Json settings = Json::object();
    settings["gain"] = static_cast<std::uint64_t>(music_inject::gain() * 100.0f + 0.5f);
    settings["speakers"] = music_inject::mode() != 3;
    out["settings"] = std::move(settings);
    return out.dump();
}

// What a change asks for, done. False when it is not one of them.
bool change(const std::string& path, const std::string& body) {
    Json json = Json::object();
    try {
        if (!body.empty()) json = Json::parse(body);
    } catch (...) {
        return false;
    }
    if (!json.is_object()) return false;
    if (path == "/api/command") {
        const auto command = json.value("command", "");
        using external_player::Command;
        if (command == "play") external_player::send(Command::play);
        else if (command == "pause") external_player::send(Command::pause);
        else if (command == "toggle") external_player::send(Command::toggle);
        else if (command == "next") external_player::send(Command::next);
        else if (command == "previous") external_player::send(Command::previous);
        else return false;
    } else if (path == "/api/client") {
        const auto id = json.value("id", "");
        if (id.empty() || id.size() > 64 || !std::all_of(id.begin(), id.end(), [](unsigned char c) { return std::isalnum(c) != 0; })) return false;
        spotify_web::set_client(id);
    } else if (path == "/api/login") {
        spotify_web::login();
    } else if (path == "/api/logout") {
        spotify_web::logout();
    } else if (path == "/api/refresh") {
        spotify_web::refresh();
    } else if (path == "/api/youtube/tools") {
        youtube_music::fetch_tools();
    } else if (path == "/api/youtube/add") {
        youtube_music::add(json.value("link", ""));
    } else if (path == "/api/youtube/cookies") {
        if (!youtube_music::set_cookies(json.value("text", ""))) return false;
    } else if (path == "/api/youtube/browser") {
        youtube_music::set_browser(json.value("browser", ""));
    } else if (path == "/api/youtube/remove") {
        if (!json.contains("index") || !json.at("index").is_number()) return false;
        youtube_music::remove(static_cast<std::size_t>(std::clamp<std::int64_t>(json.at("index").get<std::int64_t>(), 0, 1000)));
    } else if (path == "/api/external") {
        external_audio::set_app(json.value("app", ""));
        profile_runtime::request_music_catalog_refresh();
        if (external_audio::on()) external_player::use_app(external_audio::app());
    } else if (path == "/api/settings") {
        if (json.contains("gain") && json.at("gain").is_number()) music_inject::set_gain(static_cast<float>(std::clamp<std::int64_t>(json.at("gain").get<std::int64_t>(), 0, 400)) / 100.0f);
        if (json.contains("speakers") && json.at("speakers").is_boolean()) music_inject::set_mode(json.at("speakers").get<bool>() ? 1 : 3);
    } else {
        return false;
    }
    return true;
}

void answer(SOCKET client, const char* status, const char* type, const std::string& body) {
    const auto head = std::format("HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n", status, type,
        body.size());
    send(client, head.data(), static_cast<int>(head.size()), 0);
    for (std::size_t sent = 0; sent < body.size();) {
        const int did = send(client, body.data() + sent, static_cast<int>(std::min<std::size_t>(body.size() - sent, 65536)), 0);
        if (did <= 0) break;
        sent += static_cast<std::size_t>(did);
    }
}
std::string header(const std::string& request, const std::string& name) {
    // (Names are matched as browsers write them here.)
    const auto at = request.find("\r\n" + name + ": ");
    if (at == std::string::npos) return {};
    const auto from = at + name.size() + 4;
    return request.substr(from, request.find("\r\n", from) - from);
}

void serve(SOCKET client) {
    DWORD timeout = 3000;
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
    std::string request;
    char buffer[4096];
    std::size_t head_end = std::string::npos;
    while (head_end == std::string::npos && request.size() < 16384) {
        const int got = recv(client, buffer, sizeof(buffer), 0);
        if (got <= 0) return;
        request.append(buffer, static_cast<std::size_t>(got));
        head_end = request.find("\r\n\r\n");
    }
    if (head_end == std::string::npos) return;
    std::size_t length{};
    try {
        if (const auto text = header(request, "Content-Length"); !text.empty()) length = std::stoul(text);
    } catch (...) {
        return;
    }
    if (length > 2 * 1024 * 1024) return answer(client, "413 Payload Too Large", "text/plain", "too large");
    while (request.size() < head_end + 4 + length) {
        const int got = recv(client, buffer, sizeof(buffer), 0);
        if (got <= 0) return;
        request.append(buffer, static_cast<std::size_t>(got));
    }
    const auto line = request.substr(0, request.find("\r\n"));
    const auto method = line.substr(0, line.find(' '));
    const auto path_from = method.size() + 1;
    const auto path = line.substr(path_from, line.find(' ', path_from) - path_from);
    // Only as itself: a request that names another host (a site made to resolve to this
    // computer) is not answered.
    const auto host = header(request, "Host");
    const auto own = std::to_string(port.load());
    if (host != "127.0.0.1:" + own && host != "localhost:" + own) return answer(client, "403 Forbidden", "text/plain", "not for this address");
    if (method == "GET" && (path == "/" || path == "/index.html")) return answer(client, "200 OK", "text/html; charset=utf-8", page);
    if (method == "GET" && path == "/api/state") return answer(client, "200 OK", "application/json", state_json());
    if (method == "POST") {
        // A change comes from this page alone: its script sends a header that a page of another
        // site cannot send without the browser asking first, which is refused by not answering.
        if (header(request, "X-ReSkate") != "1") return answer(client, "403 Forbidden", "text/plain", "not from the page");
        return change(path, request.substr(head_end + 4, length)) ? answer(client, "200 OK", "application/json", "{}") : answer(client, "400 Bad Request", "text/plain", "not understood");
    }
    answer(client, "404 Not Found", "text/plain", "nothing here");
}

void run() noexcept {
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return;
    SOCKET listener = INVALID_SOCKET;
    for (unsigned short candidate = first_port; candidate < first_port + 10 && listener == INVALID_SOCKET; ++candidate) {
        const SOCKET made = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        sockaddr_in at{};
        at.sin_family = AF_INET;
        at.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        at.sin_port = htons(candidate);
        if (made != INVALID_SOCKET && bind(made, reinterpret_cast<const sockaddr*>(&at), sizeof(at)) == 0 && listen(made, 8) == 0) {
            listener = made;
            port.store(candidate);
        } else if (made != INVALID_SOCKET) {
            closesocket(made);
        }
    }
    if (listener == INVALID_SOCKET) {
        try {
            logging::log(logging::Level::warning, logging::Channel::music, "Spotify setup page: no port on this computer was free for it.");
        } catch (...) {}
        return;
    }
    try {
        logging::log(logging::Level::info, logging::Channel::music, "Spotify setup page: {} (\"spotify setup\" in the console opens it).", address());
    } catch (...) {}
    for (;;) {
        const SOCKET client = accept(listener, nullptr, nullptr);
        if (client == INVALID_SOCKET) {
            Sleep(50);
            continue;
        }
        try {
            serve(client);
        } catch (...) {}
        shutdown(client, SD_SEND);
        closesocket(client);
    }
}
} // namespace

void start() noexcept {
    if (started.exchange(true)) return;
    try {
        std::thread(run).detach();
    } catch (...) {}
}
std::string address() {
    const auto at = port.load();
    return at ? "http://127.0.0.1:" + std::to_string(at) + "/" : std::string();
}
bool open() noexcept {
    try {
        const auto where = address();
        if (where.empty()) return false;
        const std::wstring wide(where.begin(), where.end());
        return reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL)) > 32;
    } catch (...) {
        return false;
    }
}
} // namespace dingosdk::spotify_dashboard
