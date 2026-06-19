import AVFoundation
import Combine
import Photos
import SwiftUI
import UIKit

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var permissionState: CameraPermissionState = .unknown
    @Published var mode: CameraMode = .photo
    @Published var flashMode: CameraFlashMode = .auto
    @Published var cameraPosition: CameraPosition = .back
    @Published var zoomFactor: CGFloat = 1
    @Published var maxZoomFactor: CGFloat = 1
    @Published var isSessionRunning = false
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var recentMedia: RecentMedia?
    @Published var statusMessage: String?
    @Published var focusIndicator: FocusIndicator?

    weak var previewLayer: AVCaptureVideoPreviewLayer?

    private let sessionQueue = DispatchQueue(label: "com.lensplus.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var activeDevice: AVCaptureDevice?
    private var pendingPhotoDelegate: PhotoCaptureDelegate?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?

    func requestPermissionsAndConfigure() {
        Task {
            let cameraAllowed = await requestVideoAccess()
            guard cameraAllowed else {
                await MainActor.run {
                    permissionState = .denied("카메라 권한이 필요합니다.")
                    statusMessage = "설정에서 카메라 접근을 허용해주세요."
                }
                return
            }

            _ = await requestAudioAccess()
            _ = await requestPhotoLibraryAccess()

            await MainActor.run {
                permissionState = .authorized
            }

            configureSession()
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            Task { @MainActor in
                self.isSessionRunning = true
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            Task { @MainActor in
                self.isSessionRunning = false
            }
        }
    }

    func setMode(_ newMode: CameraMode) {
        mode = newMode
        if newMode == .photo, isRecording {
            stopRecording()
        }
    }

    func cycleFlashMode() {
        switch flashMode {
        case .auto:
            flashMode = .on
        case .on:
            flashMode = .off
        case .off:
            flashMode = .auto
        }
    }

    func capture() {
        switch mode {
        case .photo:
            capturePhoto()
        case .video:
            isRecording ? stopRecording() : startRecording()
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            let currentPosition = self.activeDevice?.position ?? .back
            let nextPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
            guard let nextDevice = Self.makeCamera(position: nextPosition) else {
                self.publishStatus("사용 가능한 카메라를 찾을 수 없습니다.")
                return
            }

            do {
                let nextInput = try AVCaptureDeviceInput(device: nextDevice)
                self.session.beginConfiguration()
                if let videoInput = self.videoInput {
                    self.session.removeInput(videoInput)
                }
                if self.session.canAddInput(nextInput) {
                    self.session.addInput(nextInput)
                    self.videoInput = nextInput
                    self.activeDevice = nextDevice
                    self.updateVideoConnectionMirroring()
                    self.updatePreviewLayerConfiguration()
                }
                self.session.commitConfiguration()

                Task { @MainActor in
                    self.cameraPosition = nextPosition == .front ? .front : .back
                    self.syncZoomState(with: nextDevice)
                }
            } catch {
                self.publishStatus("카메라 전환에 실패했습니다.")
            }
        }
    }

    func focus(at viewPoint: CGPoint) {
        guard let previewLayer else { return }
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)

        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()

                Task { @MainActor in
                    self.focusIndicator = FocusIndicator(point: viewPoint)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                        self?.focusIndicator = nil
                    }
                }
            } catch {
                self.publishStatus("초점 조절에 실패했습니다.")
            }
        }
    }

    func setZoomFactor(_ factor: CGFloat) {
        let clamped = min(max(factor, 1), maxZoomFactor)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                Task { @MainActor in
                    self.zoomFactor = clamped
                }
            } catch {
                self.publishStatus("줌 조절에 실패했습니다.")
            }
        }
    }

    func applyPinchZoom(baseZoom: CGFloat, scale: CGFloat) {
        setZoomFactor(baseZoom * scale)
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = session
        updatePreviewLayerConfiguration()
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            do {
                guard let videoDevice = Self.makeCamera(position: .back) else {
                    self.session.commitConfiguration()
                    self.publishStatus("후면 카메라를 찾을 수 없습니다.")
                    return
                }

                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                if self.session.canAddInput(videoInput) {
                    self.session.addInput(videoInput)
                    self.videoInput = videoInput
                    self.activeDevice = videoDevice
                }

                if let audioDevice = AVCaptureDevice.default(for: .audio) {
                    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    if self.session.canAddInput(audioInput) {
                        self.session.addInput(audioInput)
                        self.audioInput = audioInput
                    }
                }

                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                }

                if self.session.canAddOutput(self.movieOutput) {
                    self.session.addOutput(self.movieOutput)
                }

                self.updateVideoConnectionMirroring()
                self.updatePreviewLayerConfiguration()
                self.session.commitConfiguration()

                Task { @MainActor in
                    self.syncZoomState(with: videoDevice)
                    self.startSession()
                }
            } catch {
                self.session.commitConfiguration()
                self.publishStatus("카메라 세션 구성에 실패했습니다.")
            }
        }
    }

    private func capturePhoto() {
        guard session.isRunning, activeDevice != nil, photoOutput.connection(with: .video) != nil else {
            publishStatus("카메라가 아직 준비되지 않았습니다.")
            return
        }

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality

        if photoOutput.supportedFlashModes.contains(avFlashMode) {
            settings.flashMode = avFlashMode
        }

        let delegate = PhotoCaptureDelegate { [weak self] result in
            guard let self else { return }
            self.pendingPhotoDelegate = nil

            switch result {
            case .success(let data):
                self.savePhoto(data)
            case .failure:
                self.publishStatus("사진 촬영에 실패했습니다.")
            }
        }

        pendingPhotoDelegate = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    private func startRecording() {
        guard !movieOutput.isRecording else { return }
        guard session.isRunning, activeDevice != nil, movieOutput.connection(with: .video) != nil else {
            publishStatus("카메라가 아직 준비되지 않았습니다.")
            return
        }

        setTorchForRecordingIfNeeded(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lensplus-\(UUID().uuidString)")
            .appendingPathExtension("mov")

        updateVideoConnectionMirroring()
        movieOutput.startRecording(to: url, recordingDelegate: self)

        recordingStartedAt = Date()
        Task { @MainActor in
            isRecording = true
            recordingDuration = 0
            startRecordingTimer()
        }
    }

    private func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    private func savePhoto(_ data: Data) {
        let thumbnail = UIImage(data: data)

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        } completionHandler: { [weak self] success, _ in
            guard let self else { return }
            if success {
                if let thumbnail {
                    self.updateRecentMedia(kind: .photo, thumbnail: thumbnail)
                }
                self.publishStatus("사진이 저장되었습니다.")
            } else {
                self.publishStatus("사진 저장에 실패했습니다.")
            }
        }
    }

    private func saveVideo(at url: URL) {
        let thumbnail = makeVideoThumbnail(url: url)

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        } completionHandler: { [weak self] success, _ in
            try? FileManager.default.removeItem(at: url)
            guard let self else { return }
            if success {
                if let thumbnail {
                    self.updateRecentMedia(kind: .video, thumbnail: thumbnail)
                }
                self.publishStatus("동영상이 저장되었습니다.")
            } else {
                self.publishStatus("동영상 저장에 실패했습니다.")
            }
        }
    }

    private func updateRecentMedia(kind: RecentMediaKind, thumbnail: UIImage) {
        Task { @MainActor in
            recentMedia = RecentMedia(kind: kind, thumbnail: thumbnail)
        }
    }

    private func makeVideoThumbnail(url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        do {
            let image = try generator.copyCGImage(at: .zero, actualTime: nil)
            return UIImage(cgImage: image)
        } catch {
            return nil
        }
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let recordingStartedAt = self.recordingStartedAt else { return }
            self.recordingDuration = Date().timeIntervalSince(recordingStartedAt)
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
    }

    private func updateVideoConnectionMirroring() {
        let shouldMirror = activeDevice?.position == .front
        movieOutput.connection(with: .video)?.automaticallyAdjustsVideoMirroring = false
        movieOutput.connection(with: .video)?.isVideoMirrored = shouldMirror
        photoOutput.connection(with: .video)?.automaticallyAdjustsVideoMirroring = false
        photoOutput.connection(with: .video)?.isVideoMirrored = shouldMirror
    }

    private func updatePreviewLayerConfiguration() {
        Task { @MainActor in
            guard let previewLayer else { return }
            previewLayer.videoGravity = .resizeAspectFill

            guard let connection = previewLayer.connection else { return }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = activeDevice?.position == .front
            }
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }

    private func setTorchForRecordingIfNeeded(_ enabled: Bool) {
        guard let device = activeDevice, device.hasTorch else { return }
        let shouldEnable = enabled && mode == .video && flashMode == .on

        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.torchMode = shouldEnable ? .on : .off
                device.unlockForConfiguration()
            } catch {
                self.publishStatus("플래시 제어에 실패했습니다.")
            }
        }
    }

    private func syncZoomState(with device: AVCaptureDevice) {
        maxZoomFactor = min(device.activeFormat.videoMaxZoomFactor, 8)
        zoomFactor = min(max(device.videoZoomFactor, 1), maxZoomFactor)
    }

    private var avFlashMode: AVCaptureDevice.FlashMode {
        switch flashMode {
        case .auto:
            .auto
        case .on:
            .on
        case .off:
            .off
        }
    }

    private func publishStatus(_ message: String) {
        Task { @MainActor in
            statusMessage = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                guard self?.statusMessage == message else { return }
                self?.statusMessage = nil
            }
        }
    }

    private static func makeCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInTripleCamera],
                mediaType: .video,
                position: .back
            )
            return discovery.devices.first
        }

        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
    }

    private func requestVideoAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .video)
        default:
            false
        }
    }

    private func requestAudioAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        default:
            false
        }
    }

    private func requestPhotoLibraryAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let nextStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return nextStatus == .authorized || nextStatus == .limited
        default:
            return false
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        setTorchForRecordingIfNeeded(false)

        Task { @MainActor in
            isRecording = false
            recordingDuration = 0
            stopRecordingTimer()
        }

        if error != nil {
            publishStatus("동영상 녹화에 실패했습니다.")
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }

        saveVideo(at: outputFileURL)
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(error))
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(CameraCaptureError.missingPhotoData))
            return
        }

        completion(.success(data))
    }
}

private enum CameraCaptureError: Error {
    case missingPhotoData
}
