
//
//  ViewController.swift
//  Vision_PoseDetector
//
//  Created by J_Min on 2022/11/05.
//

import UIKit
import AVFoundation
import VideoToolbox
import Vision

typealias LandMarkPosition = (x: CGFloat, y: CGFloat)

class ViewController: UIViewController {

    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var angleLabel: UILabel!
    
    private let videoCapture = VideoCaptureManager()
    private var currentImage: CGImage?
    private var imageSize: CGSize = .zero
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        videoCapture.delegate = self
        videoCapture.startSession()
        
        imageView.contentMode = .scaleAspectFill
        imageView.layer.masksToBounds = true
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        videoCapture.changeOutputOrientation()
    }
    
    private func detect(from image: CGImage) {
        imageSize = CGSize(width: image.width, height: image.height)
        let requestHandler = VNImageRequestHandler(cgImage: image)
        let request = VNDetectHumanBodyPoseRequest(completionHandler: handleBodyPoseDetection)
        
        do {
            try requestHandler.perform([request])
        } catch {
            print("request cannot perform")
        }
    }
    
    private func handleBodyPoseDetection(request: VNRequest, error: Error?) {
        guard let observations = request.results as? [VNRecognizedPointsObservation] else { return }
        if observations.count == 0 {
            // failed find pose
            guard let cgImage = currentImage else { return }
            
            imageView.image = UIImage(cgImage: cgImage)
        } else {
            // find pose
            observations.forEach { processObservation($0) }
        }
    }
    
    private func processObservation(_ observation: VNRecognizedPointsObservation) {
        guard let recognizedPoints = try? observation.recognizedPoints(forGroupKey: .all) else { return }
        
        let points: [(VNRecognizedPointKey, CGPoint)] = recognizedPoints.values.compactMap {
            guard $0.confidence > 0 else { return nil }
            let point = VNImagePointForNormalizedPoint($0.location, Int(imageSize.width), Int(imageSize.height))
            return ($0.identifier, point)
        }
        
        print("points ---> ")
        points.forEach {
            print($0.0.rawValue, $0.1)
        }
        print(" <--- points")
        
        let angleJointName: [VNHumanBodyPoseObservation.JointName] = [
            .rightShoulder, .rightElbow, .rightWrist
        ]
        
        let cgPoints = points.map { $0.1 }
        let image = currentImage?.drawPoints(points: cgPoints)
        imageView.image = image
        
        var firstLandmark: LandMarkPosition?
        var midLandmark: LandMarkPosition?
        var lastLandmark: LandMarkPosition?
        
        points.forEach { key, point in
            if key == angleJointName[0].rawValue {
                firstLandmark = (x: point.x, y: point.y)
            } else if key == angleJointName[1].rawValue {
                midLandmark = (x: point.x, y: point.y)
            } else if key == angleJointName[2].rawValue {
                lastLandmark = (x: point.x, y: point.y)
            }
        }
        
        guard let first = firstLandmark,
              let mid = midLandmark,
              let last = lastLandmark else {
            return
        }
        let angle = angle(firstLandmark: first, midLandmark: mid, lastLandmark: last)
        angleLabel.text = String(format: "💪 %.2f", angle)
        print("💪 right arm angle --> ", angle)
    }
    
    private func angle(
        firstLandmark: LandMarkPosition,
        midLandmark: LandMarkPosition,
        lastLandmark: LandMarkPosition
    ) -> CGFloat {
        // MARK: - 2차원 각도
        let angle1 = atan2(lastLandmark.y - midLandmark.y,
                           lastLandmark.x - midLandmark.x)
        let angle2 = atan2(firstLandmark.y - midLandmark.y,
                           firstLandmark.x - midLandmark.x)
        let radians: CGFloat = angle1 - angle2
        var angle = radians * 180.0 / .pi
        angle = abs(angle)
        if angle > 180.0 {
            angle = 360.0 - angle
        }
        
        return filter(degree: angle)
    }
    
    private var filterAngle = CGFloat.zero
    private var filterValue: CGFloat = 0.2
    
    private func filter(degree: CGFloat) -> CGFloat {
        filterAngle = filterAngle * (1 - filterValue) + degree * filterValue
        
        return filterAngle
    }
}

extension ViewController: VideoCaptureDelegate {
    func updateFrame(image: CGImage?) {
        guard let image = image else { return }
        currentImage = image
        detect(from: image)
    }
}

protocol VideoCaptureDelegate: AnyObject {
    func updateFrame(image: CGImage?)
}

final class VideoCaptureManager: NSObject {
    private lazy var session = AVCaptureSession()
    private var lastFrame: CMSampleBuffer?
    private let sessionQueue = DispatchQueue(label: "sessionQueue")
    private let outputQueue = DispatchQueue(label: "outputQueue")
    private var filterDegree: CGFloat = 0
    private let filterValue: CGFloat = 0.2
    weak var delegate: VideoCaptureDelegate?
    private var output = AVCaptureVideoDataOutput()
    
    override init() {
        super.init()
        setUpCaptureSessionInput()
        setUpCaptureSessionOutput()
    }
    
    // MARK: - setup Camera
    private func captureDevice(forPosition position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        )
        return discoverySession.devices.first { $0.position == position }
    }
    
    private func setUpCaptureSessionOutput() {
        sessionQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            self.session.beginConfiguration()
            self.session.sessionPreset = AVCaptureSession.Preset.high
            
            self.output.videoSettings = [
                (kCVPixelBufferPixelFormatTypeKey as String): kCVPixelFormatType_32BGRA
            ]
            self.output.alwaysDiscardsLateVideoFrames = true
            let outputQueue = self.outputQueue
            self.output.setSampleBufferDelegate(self, queue: outputQueue)
            guard self.session.canAddOutput(self.output) else {
                return
            }
            self.session.addOutput(self.output)
            self.session.commitConfiguration()
            
            DispatchQueue.main.async {
                self.changeOutputOrientation()
            }
        }
    }
    
    private func setUpCaptureSessionInput() {
        sessionQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            let cameraPosition: AVCaptureDevice.Position = .front
            guard let device = self.captureDevice(forPosition: cameraPosition) else {
                return
            }
            do {
                self.session.beginConfiguration()
                let currentInputs = self.session.inputs
                for input in currentInputs {
                    self.session.removeInput(input)
                }
                
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    return
                }
                self.session.addInput(input)
                
                do {
                    try device.lockForConfiguration()
                    device.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: 15)
                    device.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: 15)
                    device.unlockForConfiguration()
                } catch let error {
                    print(error.localizedDescription)
                }
                
                self.session.commitConfiguration()
            } catch {
                print("Failed to create capture device input: \(error.localizedDescription)")
            }
        }
    }
    
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            self.session.startRunning()
        }
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            self.session.stopRunning()
        }
    }
    
    func changeOutputOrientation() {
        let deviceOrientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.windowScene?.interfaceOrientation
        
        if let deviceOrientation {
            switch deviceOrientation {
            case .portrait:
                self.output.connection(with: .video)?.videoOrientation = .portrait
            case .landscapeLeft:
                self.output.connection(with: .video)?.videoOrientation = .landscapeLeft
            case .landscapeRight:
                self.output.connection(with: .video)?.videoOrientation = .landscapeRight
            case .portraitUpsideDown:
                self.output.connection(with: .video)?.videoOrientation = .portraitUpsideDown
            default:
                self.output.connection(with: .video)?.videoOrientation = .portrait
            }
        } else {
            self.output.connection(with: .video)?.videoOrientation = .portrait
        }
    }
}

extension VideoCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
            else { return }
        var image: CGImage?
        
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.updateFrame(image: image)
        }
    }
}

extension CGImage {
    func drawPoints(points: [CGPoint]) -> UIImage? {
        
        let cntx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: bitsPerComponent, bytesPerRow: 0, space: colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        cntx?.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        for point in points {
            cntx?.setFillColor(UIColor.blue.cgColor)
            cntx?.addArc(center: point, radius: 10, startAngle: 0, endAngle: 2 * CGFloat.pi, clockwise: false)
            cntx?.drawPath(using: .fill)
        }
        let cgImage = cntx?.makeImage()
        if let cgImage = cgImage {
            let img = UIImage(cgImage: cgImage)
            return img
        }
        return nil
    }
}

