#include "overlay_internal.h"
#include "Engine/Core/Log/logging.h"
#include <cmath>
#include <algorithm>
#include <array>
#include <cfloat>
#include <cstring>
#include <functional>

// Reads a presented frame back from the GPU for a screen capture (overlay.h, FrameGrabHost;
// reskate.capture), from Fit Check (pull request 326). The copy is made on the game's own queue right
// before the overlay draws, and waited for: a capture asks for a few hundred frames at most, and a
// frame's hitch then does not matter.
namespace dingosdk::overlay {
namespace {
std::atomic<const FrameGrabHost*> frame_grab_host{};
}
void set_frame_grab(const FrameGrabHost* host) noexcept { frame_grab_host.store(host); }
} // namespace dingosdk::overlay

namespace dingosdk::overlay::detail {
namespace {
// Render thread only (under the render mutex), like the rest of the overlay's graphics state.
struct Grab {
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12Resource> readback;
    UINT64 readback_size{};
    std::vector<std::uint8_t> converted; // 8-bit copy of a frame in a wider format
    DXGI_FORMAT warned{DXGI_FORMAT_UNKNOWN};
};
Grab& grab() { static auto* value = new Grab; return *value; } // process lifetime

float half_to_float(std::uint16_t h) noexcept {
    const std::uint32_t sign = (h >> 15) & 1, exponent = (h >> 10) & 31, mantissa = h & 0x3ff;
    float value;
    if (!exponent) value = std::ldexp(static_cast<float>(mantissa), -24);
    else if (exponent == 31) value = mantissa ? 0.0f : 65504.0f;
    else value = std::ldexp(static_cast<float>(mantissa | 0x400), static_cast<int>(exponent) - 25);
    return sign ? -value : value;
}
std::uint8_t linear_to_srgb8(float v) noexcept {
    v = std::clamp(v, 0.0f, 1.0f);
    const float s = v <= 0.0031308f ? v * 12.92f : 1.055f * std::pow(v, 1.0f / 2.4f) - 0.055f;
    return static_cast<std::uint8_t>(std::lround(s * 255.0f));
}

const FrameGrabHost* host() { return frame_grab_host.load(); }
} // namespace

bool frame_grab_pending() {
    const auto* h = host();
    if (!h || !h->active) return false;
    try { return h->active(); } catch (...) { return false; }
}

namespace {
// A presented frame copied for reading later, not waited for (copy_presented_frame).
struct Copy {
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12Resource> readback;
    UINT64 size{};
    UINT64 fence{}; // the copy's fence value; 0 while free
    int tag{};
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT layout{};
    std::uint32_t width{}, height{};
    DXGI_FORMAT format{DXGI_FORMAT_UNKNOWN};
};
std::array<Copy, 2>& copies() { static auto* value = new std::array<Copy, 2>; return *value; } // process lifetime
bool readable(DXGI_FORMAT format) {
    return format == DXGI_FORMAT_R8G8B8A8_UNORM || format == DXGI_FORMAT_R8G8B8A8_UNORM_SRGB || format == DXGI_FORMAT_B8G8R8A8_UNORM ||
           format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB || format == DXGI_FORMAT_R10G10B10A2_UNORM || format == DXGI_FORMAT_R16G16B16A16_FLOAT;
}
} // namespace

std::array<std::uint8_t, 3> FrameSampler::rgb(std::uint32_t x, std::uint32_t y) const noexcept {
    x = std::min(x, width - 1);
    y = std::min(y, height - 1);
    const auto* row = data + std::size_t{y} * pitch;
    switch (format) {
    case DXGI_FORMAT_B8G8R8A8_UNORM:
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: {
        const auto* p = row + std::size_t{x} * 4;
        return {p[2], p[1], p[0]};
    }
    case DXGI_FORMAT_R10G10B10A2_UNORM: {
        std::uint32_t packed;
        std::memcpy(&packed, row + std::size_t{x} * 4, 4);
        return {static_cast<std::uint8_t>((packed & 0x3ff) * 255 / 1023), static_cast<std::uint8_t>(((packed >> 10) & 0x3ff) * 255 / 1023),
                static_cast<std::uint8_t>(((packed >> 20) & 0x3ff) * 255 / 1023)};
    }
    case DXGI_FORMAT_R16G16B16A16_FLOAT: {
        std::uint16_t channel[4];
        std::memcpy(channel, row + std::size_t{x} * 8, 8);
        return {linear_to_srgb8(half_to_float(channel[0])), linear_to_srgb8(half_to_float(channel[1])), linear_to_srgb8(half_to_float(channel[2]))};
    }
    default: {
        const auto* p = row + std::size_t{x} * 4;
        return {p[0], p[1], p[2]};
    }
    }
}

bool copy_presented_frame(State& s, ID3D12Resource* buffer, int tag) {
    if (!buffer || !s.device || !s.queue || !s.fence) return false;
    Copy* free_copy = nullptr;
    for (auto& c : copies())
        if (!c.fence) {
            free_copy = &c;
            break;
        }
    if (!free_copy) return false;
    auto& c = *free_copy;
    const auto description = buffer->GetDesc();
    if (!readable(description.Format)) return false;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT layout{};
    UINT rows{};
    UINT64 row_bytes{}, total{};
    s.device->GetCopyableFootprints(&description, 0, 1, 0, &layout, &rows, &row_bytes, &total);
    if (!total || rows != description.Height) return false;
    if (!c.allocator && FAILED(s.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&c.allocator)))) return false;
    if (!c.commands) {
        if (FAILED(s.device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, c.allocator.Get(), nullptr, IID_PPV_ARGS(&c.commands))))
            return false;
        c.commands->Close();
    }
    if (c.size < total) {
        c.readback.Reset();
        c.size = 0;
        D3D12_HEAP_PROPERTIES heap{};
        heap.Type = D3D12_HEAP_TYPE_READBACK;
        D3D12_RESOURCE_DESC bytes{};
        bytes.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        bytes.Width = total;
        bytes.Height = 1;
        bytes.DepthOrArraySize = 1;
        bytes.MipLevels = 1;
        bytes.SampleDesc.Count = 1;
        bytes.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        if (FAILED(s.device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &bytes, D3D12_RESOURCE_STATE_COPY_DEST, nullptr,
                                                     IID_PPV_ARGS(&c.readback))))
            return false;
        c.size = total;
    }
    if (FAILED(c.allocator->Reset()) || FAILED(c.commands->Reset(c.allocator.Get(), nullptr))) return false;
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = buffer;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    c.commands->ResourceBarrier(1, &barrier);
    D3D12_TEXTURE_COPY_LOCATION to{}, from{};
    to.pResource = c.readback.Get();
    to.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    to.PlacedFootprint = layout;
    from.pResource = buffer;
    from.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    c.commands->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    std::swap(barrier.Transition.StateBefore, barrier.Transition.StateAfter);
    c.commands->ResourceBarrier(1, &barrier);
    if (FAILED(c.commands->Close())) return false;
    ID3D12CommandList* lists[] = {c.commands.Get()};
    s.queue->ExecuteCommandLists(1, lists);
    const UINT64 signal = ++s.next_fence;
    if (FAILED(s.queue->Signal(s.fence.Get(), signal))) return false;
    c.fence = signal;
    c.tag = tag;
    c.layout = layout;
    c.width = static_cast<std::uint32_t>(description.Width);
    c.height = description.Height;
    c.format = description.Format;
    return true;
}

void take_frame_copies(State& s, const std::function<void(int, const FrameSampler&)>& take) {
    if (!s.fence) return;
    const UINT64 done = s.fence->GetCompletedValue();
    for (auto& c : copies()) {
        if (!c.fence || done < c.fence) continue;
        void* mapped{};
        const D3D12_RANGE range{0, static_cast<SIZE_T>(c.size)};
        FrameSampler frame;
        if (SUCCEEDED(c.readback->Map(0, &range, &mapped)) && mapped)
            frame = {static_cast<const std::uint8_t*>(mapped) + c.layout.Offset, c.width, c.height, c.layout.Footprint.RowPitch, c.format};
        try { take(c.tag, frame); } catch (...) {}
        if (mapped) {
            const D3D12_RANGE nothing{};
            c.readback->Unmap(0, &nothing);
        }
        c.fence = 0;
    }
}

void release_frame_grab() {
    for (auto& c : copies()) c = {};
    auto& g = grab();
    g.commands.Reset();
    g.allocator.Reset();
    g.readback.Reset();
    g.readback_size = 0;
    g.converted = {};
}

void grab_presented_frame(State& s, ID3D12Resource* buffer) {
    const auto* h = host();
    if (!h || !h->wants_frame || !h->take_frame || !buffer || !s.device || !s.queue || !s.fence) return;
    bool wanted = false;
    try { wanted = h->wants_frame(); } catch (...) {}
    if (!wanted) return;
    read_presented_frame(s, buffer, [h](const GrabbedFrame& frame) { h->take_frame(frame); }, true);
}

void read_presented_frame(State& s, ID3D12Resource* buffer, const std::function<void(const GrabbedFrame&)>& take, bool with_depth) {
    if (!buffer || !s.device || !s.queue || !s.fence) return;
    auto& g = grab();
    const auto description = buffer->GetDesc();
    const auto format = description.Format;
    const bool eight_bit = format == DXGI_FORMAT_R8G8B8A8_UNORM || format == DXGI_FORMAT_R8G8B8A8_UNORM_SRGB ||
                           format == DXGI_FORMAT_B8G8R8A8_UNORM || format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
    const bool ten_bit = format == DXGI_FORMAT_R10G10B10A2_UNORM;
    const bool half = format == DXGI_FORMAT_R16G16B16A16_FLOAT;
    if (!eight_bit && !ten_bit && !half) {
        if (g.warned != format)
            logging::printf(logging::Level::warning, logging::Channel::graphics,
                            "Capture: the backbuffer format %u cannot be read back.", static_cast<unsigned>(format));
        g.warned = format;
        take({});
        return;
    }
    if ((ten_bit || half) && g.warned != format) {
        // An HDR swapchain: the picture is converted, but its colours will not match what SDR shows.
        logging::printf(logging::Level::warning, logging::Channel::graphics,
                        "Capture: the game is presenting in HDR (format %u); captured colours are converted to SDR and may look off.",
                        static_cast<unsigned>(format));
        g.warned = format;
    }
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT layout{};
    UINT rows{};
    UINT64 row_bytes{}, total{};
    s.device->GetCopyableFootprints(&description, 0, 1, 0, &layout, &rows, &row_bytes, &total);
    const auto fail = [&](const char* what) {
        logging::printf(logging::Level::warning, logging::Channel::graphics, "Capture: frame read-back failed at %s.", what);
        try { take({}); } catch (...) {}
    };
    if (!total || rows != description.Height) return fail("its layout");
    if (!g.allocator &&
        FAILED(s.device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&g.allocator))))
        return fail("CreateCommandAllocator");
    if (!g.commands) {
        if (FAILED(s.device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, g.allocator.Get(), nullptr, IID_PPV_ARGS(&g.commands))))
            return fail("CreateCommandList");
        g.commands->Close();
    }
    if (g.readback_size < total) {
        g.readback.Reset();
        D3D12_HEAP_PROPERTIES heap{};
        heap.Type = D3D12_HEAP_TYPE_READBACK;
        D3D12_RESOURCE_DESC bytes{};
        bytes.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        bytes.Width = total;
        bytes.Height = 1;
        bytes.DepthOrArraySize = 1;
        bytes.MipLevels = 1;
        bytes.SampleDesc.Count = 1;
        bytes.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        if (FAILED(s.device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &bytes, D3D12_RESOURCE_STATE_COPY_DEST,
                                                     nullptr, IID_PPV_ARGS(&g.readback))))
            return fail("CreateCommittedResource");
        g.readback_size = total;
    }
    if (FAILED(g.allocator->Reset()) || FAILED(g.commands->Reset(g.allocator.Get(), nullptr))) return fail("Reset");
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = buffer;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    g.commands->ResourceBarrier(1, &barrier);
    D3D12_TEXTURE_COPY_LOCATION to{}, from{};
    to.pResource = g.readback.Get();
    to.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    to.PlacedFootprint = layout;
    from.pResource = buffer;
    from.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    from.SubresourceIndex = 0;
    g.commands->CopyTextureRegion(&to, 0, 0, 0, &from, nullptr);
    std::swap(barrier.Transition.StateBefore, barrier.Transition.StateAfter);
    g.commands->ResourceBarrier(1, &barrier);
    if (FAILED(g.commands->Close())) return fail("Close");
    ID3D12CommandList* lists[] = {g.commands.Get()};
    s.queue->ExecuteCommandLists(1, lists);
    const UINT64 signal = ++s.next_fence;
    if (FAILED(s.queue->Signal(s.fence.Get(), signal)) || !completed(signal, render_fence_timeout_ms)) return fail("the GPU wait");
    void* mapped{};
    const D3D12_RANGE range{0, static_cast<SIZE_T>(total)};
    if (FAILED(g.readback->Map(0, &range, &mapped)) || !mapped) return fail("Map");
    const auto* pixels = static_cast<const std::uint8_t*>(mapped) + layout.Offset;
    const auto width = static_cast<std::uint32_t>(description.Width), height = description.Height;
    GrabbedFrame frame{pixels, width, height, layout.Footprint.RowPitch,
                       format == DXGI_FORMAT_B8G8R8A8_UNORM || format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB};
    if (!eight_bit) {
        g.converted.resize(std::size_t{width} * height * 4);
        for (std::uint32_t y = 0; y < height; ++y)
            for (std::uint32_t x = 0; x < width; ++x) {
                auto* out = g.converted.data() + (std::size_t{y} * width + x) * 4;
                const auto* in = pixels + std::size_t{y} * layout.Footprint.RowPitch;
                if (ten_bit) {
                    std::uint32_t packed;
                    std::memcpy(&packed, in + std::size_t{x} * 4, 4);
                    for (int c = 0; c < 3; ++c) out[c] = static_cast<std::uint8_t>(((packed >> (10 * c)) & 0x3ff) * 255 / 1023);
                } else {
                    std::uint16_t channel[4];
                    std::memcpy(channel, in + std::size_t{x} * 8, 8);
                    for (int c = 0; c < 3; ++c) out[c] = linear_to_srgb8(half_to_float(channel[c]));
                }
                out[3] = 255;
            }
        frame = {g.converted.data(), width, height, width * 4, false};
    }
    // The depth of this frame (a capture cuts what it shows out by it), when there is one.
    if (with_depth) {
        std::uint32_t depth_width{}, depth_height{};
        frame.depth = depth_tap_latest(depth_width, depth_height, frame.depth_pitch);
        if (frame.depth && (depth_width != width || depth_height != height)) frame.depth = nullptr;
    }
    try { take(frame); } catch (...) {}
    if (with_depth) depth_tap_done();
    const D3D12_RANGE nothing{};
    g.readback->Unmap(0, &nothing);
}
} // namespace dingosdk::overlay::detail
