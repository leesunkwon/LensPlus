import SwiftUI

struct CameraView: View {
    @StateObject private var camera = CameraController()
    @State private var baseZoomFactor: CGFloat = 1
    @State private var selectedMedia: RecentMedia?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    CameraPreview(controller: camera)
                        .aspectRatio(0.75, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .opacity(camera.permissionState == .authorized ? 1 : 0)
                        .clipped()
                        .gesture(tapGesture)
                        .simultaneousGesture(zoomGesture)
                        .overlay(alignment: .topLeading) {
                            if let focusIndicator = camera.focusIndicator {
                                FocusRing()
                                    .position(focusIndicator.point)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                    Spacer(minLength: 0)
                }
                .padding(.top, proxy.safeAreaInsets.top)
                .ignoresSafeArea(edges: .bottom)

                cameraChrome(proxy: proxy)

                if case .denied(let message) = camera.permissionState {
                    PermissionOverlay(message: message)
                }

                if let statusMessage = camera.statusMessage {
                    StatusToast(message: statusMessage)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.22), value: camera.focusIndicator?.id)
            .animation(.snappy(duration: 0.22), value: camera.statusMessage)
            .sheet(item: $selectedMedia) { media in
                RecentMediaPreview(media: media)
            }
        }
        .task {
            camera.requestPermissionsAndConfigure()
        }
        .onDisappear {
            camera.stopSession()
        }
    }

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                camera.focus(at: value.location)
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                camera.applyPinchZoom(baseZoom: baseZoomFactor, scale: value.magnification)
            }
            .onEnded { _ in
                baseZoomFactor = camera.zoomFactor
            }
    }

    private func cameraChrome(proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 18)
                .padding(.top, proxy.safeAreaInsets.top + 8)

            Spacer()

            zoomControls
                .padding(.bottom, 18)

            bottomControls
                .padding(.horizontal, 20)
                .padding(.bottom, max(proxy.safeAreaInsets.bottom, 14))
        }
        .ignoresSafeArea(edges: .top)
    }

    private var topBar: some View {
        HStack {
            GlassIconButton(
                systemName: camera.flashMode.iconName,
                accessibilityLabel: "플래시 \(camera.flashMode.rawValue)"
            ) {
                camera.cycleFlashMode()
            }

            Spacer()

            if camera.isRecording {
                RecordingBadge(duration: camera.recordingDuration)
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            zoomButton(title: "1x", value: 1)
            zoomButton(title: "2x", value: min(2, max(camera.maxZoomFactor, 1)))
        }
        .padding(6)
        .glassCapsule()
    }

    private func zoomButton(title: String, value: CGFloat) -> some View {
        Button {
            camera.setZoomFactor(value)
            baseZoomFactor = value
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isZoomSelected(value) ? .bold : .semibold))
                .foregroundStyle(isZoomSelected(value) ? .yellow : .white)
                .frame(width: 42, height: 32)
                .background {
                    if isZoomSelected(value) {
                        Circle()
                            .fill(.black.opacity(0.36))
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(value > camera.maxZoomFactor)
        .opacity(value > camera.maxZoomFactor ? 0.35 : 1)
    }

    private func isZoomSelected(_ value: CGFloat) -> Bool {
        abs(camera.zoomFactor - value) < 0.15
    }

    private var bottomControls: some View {
        VStack(spacing: 18) {
            modePicker

            HStack(alignment: .center) {
                thumbnailButton

                Spacer()

                ShutterButton(mode: camera.mode, isRecording: camera.isRecording) {
                    camera.capture()
                }

                Spacer()

                GlassIconButton(systemName: "arrow.triangle.2.circlepath.camera", accessibilityLabel: "카메라 전환") {
                    camera.switchCamera()
                }
                .frame(width: 62, height: 62)
            }
            .frame(height: 86)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 22) {
            ForEach(CameraMode.allCases) { mode in
                Button {
                    camera.setMode(mode)
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 13, weight: camera.mode == mode ? .bold : .semibold))
                        .foregroundStyle(camera.mode == mode ? .yellow : .white.opacity(0.72))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassCapsule()
    }

    private var thumbnailButton: some View {
        Button {
            selectedMedia = camera.recentMedia
        } label: {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black.opacity(0.36))
                    .frame(width: 56, height: 56)
                    .overlay {
                        if let image = camera.recentMedia?.thumbnail {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.64))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white.opacity(0.45), lineWidth: 1)
                    }

                if camera.recentMedia?.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.56), in: Circle())
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(camera.recentMedia == nil)
        .opacity(camera.recentMedia == nil ? 0.72 : 1)
        .frame(width: 62, height: 62)
    }
}

private struct ShutterButton: View {
    let mode: CameraMode
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 5)
                    .frame(width: 78, height: 78)

                if mode == .photo {
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                } else {
                    RoundedRectangle(cornerRadius: isRecording ? 7 : 31, style: .continuous)
                        .fill(.red)
                        .frame(width: isRecording ? 31 : 62, height: isRecording ? 31 : 62)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .photo ? "사진 촬영" : isRecording ? "녹화 중지" : "동영상 녹화")
    }
}

private struct GlassIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .glassCircle()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct RecordingBadge: View {
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text(formatDuration(duration))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassCapsule()
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct FocusRing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(.yellow, lineWidth: 1.8)
            .frame(width: 82, height: 82)
            .shadow(color: .yellow.opacity(0.35), radius: 8)
    }
}

private struct PermissionOverlay: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 34, weight: .semibold))
            Text(message)
                .font(.system(size: 17, weight: .bold))
            Text("카메라, 마이크, 사진 접근 권한을 허용하면 촬영을 시작할 수 있습니다.")
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.76))
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 320)
        .glassRounded(cornerRadius: 24)
    }
}

private struct StatusToast: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassCapsule()
            .padding(.horizontal, 24)
    }
}

private struct RecentMediaPreview: View {
    let media: RecentMedia
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Image(uiImage: media.thumbnail)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)

            VStack(alignment: .trailing, spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .glassCircle()
                }
                .buttonStyle(.plain)

                Label(media.kind == .photo ? "최근 사진" : "최근 동영상", systemImage: media.kind == .photo ? "photo" : "video.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .glassCapsule()
            }
            .padding(18)
        }
    }
}

private extension View {
    func glassCapsule() -> some View {
        background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
    }

    func glassCircle() -> some View {
        background(.ultraThinMaterial, in: Circle())
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.24), radius: 14, y: 6)
    }

    func glassRounded(cornerRadius: CGFloat) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.24), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
    }
}
