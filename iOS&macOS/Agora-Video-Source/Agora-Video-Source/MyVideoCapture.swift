//
//  MyVideoCapture.swift
//  Agora-Video-Source
//
//  Created by GongYuhua on 2017/4/11.
//  Copyright © 2017年 Agora. All rights reserved.
//  Updated by CJ Lazell on 2020/8/31
//

import UIKit
import AVFoundation
import Photos

protocol MyVideoCaptureDelegate {
    func myVideoCapture(_ capture: MyVideoCapture, didOutputSampleBuffer pixelBuffer: CVPixelBuffer, rotation: Int, timeStamp: CMTime)
}

enum Camera: Int {
    case front = 1
    case back = 0

    static func defaultCamera() -> Camera {
        return .front
    }

    func next() -> Camera {
        switch self {
            case .back: return .front
            case .front: return .back
        }
    }
}

class MyVideoCapture: NSObject {

    fileprivate var delegate: MyVideoCaptureDelegate?
    private var videoView: MyVideoView

    private enum _CaptureState {
        case idle, start, capturing, end
    }
    private var _captureState = _CaptureState.idle
    @IBAction func capture(_ sender: Any) {
        switch _captureState {
        case .idle:
            _captureState = .start
        case .capturing:
            _captureState = .end
        default:
            break
        }
    }

    private var _captureSession: AVCaptureSession?
    private var _videoOutput: AVCaptureVideoDataOutput?
    private var _assetWriter: AVAssetWriter?
    private var _assetWriterInput: AVAssetWriterInput?
    private var _adpater: AVAssetWriterInputPixelBufferAdaptor?
    private var _filename = "FOOBAR"
    private var _time: Double = 0

    private var currentCamera = Camera.defaultCamera()
    private let captureSession: AVCaptureSession
    private let captureQueue: DispatchQueue
    private var currentOutput: AVCaptureVideoDataOutput? {
        if let outputs = self.captureSession.outputs as? [AVCaptureVideoDataOutput] {
            return outputs.first
        } else {
            return nil
        }
    }

    init(delegate: MyVideoCaptureDelegate?, videoView: MyVideoView) {
        self.delegate = delegate
        self.videoView = videoView

        captureSession = AVCaptureSession()
        captureSession.usesApplicationAudioSession = false

        let captureOutput = AVCaptureVideoDataOutput()
        captureOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        if captureSession.canAddOutput(captureOutput) {
            captureSession.addOutput(captureOutput)
        }

        captureQueue = DispatchQueue(label: "MyCaptureQueue")

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        videoView.insertCaptureVideoPreviewLayer(previewLayer: previewLayer)
    }

    deinit {
        captureSession.stopRunning()
    }

    func startCapture(ofCamera camera: Camera) {
        guard let currentOutput = currentOutput else {
            return
        }


        currentCamera = camera
        currentOutput.setSampleBufferDelegate(self, queue: captureQueue)

        captureQueue.async { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.changeCaptureDevice(toIndex: camera.rawValue, ofSession: strongSelf.captureSession)
            strongSelf.captureSession.beginConfiguration()
            if strongSelf.captureSession.canSetSessionPreset(AVCaptureSession.Preset.vga640x480) {
                strongSelf.captureSession.sessionPreset = AVCaptureSession.Preset.vga640x480
            }
            strongSelf.captureSession.commitConfiguration()
            strongSelf.captureSession.startRunning()
            strongSelf._videoOutput = currentOutput
            strongSelf._captureSession = strongSelf.captureSession
            strongSelf._captureState = .start
        }
    }

    func stopCapture() {
        _captureState = .end
        currentOutput?.setSampleBufferDelegate(nil, queue: nil)
        captureQueue.async { [weak self] in
            self?.captureSession.stopRunning()
            guard let strongSelf = self else {
                return
            }
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("\(strongSelf._filename).mov")
            print(url)
            strongSelf._assetWriterInput?.markAsFinished()
            strongSelf._assetWriter?.finishWriting {
                let status = PHPhotoLibrary.authorizationStatus()

                //no access granted yet
                if status == .notDetermined || status == .denied{
                    PHPhotoLibrary.requestAuthorization({auth in
                                                            if auth == .authorized{
                                                                self?.saveInPhotoLibrary(url)
                                                            }else{
                                                                print("user denied access to photo Library")
                                                            }
                                                        })

                    //access granted by user already
                }else{
                    self?.saveInPhotoLibrary(url)
                }
            }
        }
    }

    func switchCamera() {
        stopCapture()
        currentCamera = currentCamera.next()
        startCapture(ofCamera: currentCamera)
    }

    private func saveInPhotoLibrary(_ url:URL){
        PHPhotoLibrary.shared().performChanges({

            //add video to PhotoLibrary here
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                                               }) { completed, error in
        if completed {
            print("save complete! path : " + url.absoluteString)
        }else{
            print("save failed")
        }
        }
    }
}

private extension MyVideoCapture {
    func changeCaptureDevice(toIndex index: Int, ofSession captureSession: AVCaptureSession) {
        guard let captureDevice = captureDevice(atIndex: index) else {
            return
        }

        let currentInputs = captureSession.inputs as? [AVCaptureDeviceInput]
        let currentInput = currentInputs?.first

        if let currentInputName = currentInput?.device.localizedName,
        currentInputName == captureDevice.uniqueID {
            return
        }

        guard let newInput = try? AVCaptureDeviceInput(device: captureDevice) else {
            return
        }

        captureSession.beginConfiguration()
        if let currentInput = currentInput {
            captureSession.removeInput(currentInput)
        }
        if captureSession.canAddInput(newInput) {
            captureSession.addInput(newInput)
        }
        captureSession.commitConfiguration()
    }

    func captureDevice(atIndex index: Int) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.devices(for: AVMediaType.video)

        let count = devices.count
        guard count > 0, index >= 0 else {
            return nil
        }

        let device: AVCaptureDevice
        if index >= count {
            device = devices.last!
        } else {
            device = devices[index]
        }

        return device
    }
}

extension MyVideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        DispatchQueue.main.async {[weak self] in
            guard let weakSelf = self else {
                return
            }

            weakSelf.delegate?.myVideoCapture(weakSelf, didOutputSampleBuffer: pixelBuffer, rotation: 90, timeStamp: time)
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        print(_captureState)

        switch _captureState {
        case .start:
            // Set up recorder
            _filename = UUID().uuidString
            let videoPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("\(_filename).mov")

            print("================================")
            print(videoPath)
            print("================================")

            let writer = try! AVAssetWriter(outputURL: videoPath, fileType: .mov)
            let settings = _videoOutput!.recommendedVideoSettingsForAssetWriter(writingTo: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings) // [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080])
            input.mediaTimeScale = CMTimeScale(bitPattern: 600)
            input.expectsMediaDataInRealTime = true
            input.transform = CGAffineTransform(rotationAngle: .pi/2)
            let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            if writer.canAdd(input) {
                writer.add(input)
            }
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            _assetWriter = writer
            _assetWriterInput = input
            _adpater = adapter
            _captureState = .capturing
            _time = timestamp
        case .capturing:
            if _assetWriterInput?.isReadyForMoreMediaData == true {
                let time = CMTime(seconds: timestamp - _time, preferredTimescale: CMTimeScale(600))
                _adpater?.append(CMSampleBufferGetImageBuffer(sampleBuffer)!, withPresentationTime: time)
            }
            break
        default:
            break
        }
    }
}
