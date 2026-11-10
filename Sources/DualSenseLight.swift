import Foundation
import IOKit.hid

/// Writes the DualSense light bar. USB and Bluetooth use the same color fields;
/// Bluetooth adds the 0x31 header and CRC. Trigger and rumble bytes stay untouched.
final class DualSenseLight {
    private enum Transport { case usb, bluetooth }

    var onInput: ((DualSenseInput) -> Void)?
    var onConnection: ((Bool) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var transport: Transport = .usb
    private var sequence: UInt8 = 0
    private var loggedReports = 0
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    private(set) var isConnected = false

    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func requestInputMonitoring() {
        guard !inputMonitoringGranted else { return }
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    deinit {
        reportBuffer.deallocate()
    }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        let matching = [0x0CE6, 0x0DF2].map { product -> [String: Any] in
            [kIOHIDVendorIDKey as String: 0x054C, kIOHIDProductIDKey as String: product]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<DualSenseLight>.fromOpaque(context).takeUnretainedValue().connected(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<DualSenseLight>.fromOpaque(context).takeUnretainedValue().removed(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    func stop() {
        set(LightColor(red: 0, green: 0, blue: 0))
        if let manager {
            IOHIDManagerClose(manager, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        }
        manager = nil
        device = nil
        isConnected = false
    }

    @discardableResult
    func set(_ color: LightColor) -> Bool {
        guard let device else { return false }
        let report = transport == .usb ? Self.usbReport(color) : Self.bluetoothReport(color, sequence: &sequence)
        return report.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), base, report.count)
            return result == kIOReturnSuccess
        }
    }

    private func connected(_ device: IOHIDDevice) {
        guard self.device == nil else { return }
        self.device = device
        let name = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
        transport = name?.lowercased().contains("bluetooth") == true ? .bluetooth : .usb
        if transport == .bluetooth {
            var buffer = [UInt8](repeating: 0, count: 64)
            var length = buffer.count
            _ = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0x05, &buffer, &length)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 256, { context, _, _, _, reportID, report, length in
            guard let context, length > 0 else { return }
            let service = Unmanaged<DualSenseLight>.fromOpaque(context).takeUnretainedValue()
            var bytes = [UInt8](UnsafeBufferPointer(start: report, count: Int(length)))
            if bytes.first != 0x01 && bytes.first != 0x31 {
                bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
            }
            let input = DualSenseInput.parse(bytes)
            service.record(bytes, parsed: input != nil)
            if let input { service.onInput?(input) }
        }, context)
        isConnected = true
        onConnection?(true)
    }

    private func removed(_ device: IOHIDDevice) {
        guard device == self.device else { return }
        self.device = nil
        sequence = 0
        isConnected = false
        onConnection?(false)
    }

    private func record(_ bytes: [UInt8], parsed: Bool) {
        loggedReports += 1
        guard loggedReports <= 4 || loggedReports % 500 == 0 else { return }
        let hex = bytes.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
        AppLog.write("hid #\(loggedReports) parsed=\(parsed) \(hex)")
    }

    private static func channel(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, Int((value * 255).rounded()))))
    }

    private static func usbReport(_ color: LightColor) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 48)
        report[0] = 0x02
        paint(&report, origin: 0, color)
        return report
    }

    private static func bluetoothReport(_ color: LightColor, sequence: inout UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 78)
        report[0] = 0x31
        report[1] = (sequence & 0x0F) << 4
        report[2] = 0x10
        sequence = (sequence + 1) & 0x0F
        paint(&report, origin: 2, color)
        let crc = crc32(seed: 0xA2, bytes: report.prefix(74))
        report[74] = UInt8(crc & 0xFF)
        report[75] = UInt8((crc >> 8) & 0xFF)
        report[76] = UInt8((crc >> 16) & 0xFF)
        report[77] = UInt8((crc >> 24) & 0xFF)
        return report
    }

    /// `origin` is 0 for USB and 2 for Bluetooth, so the color fields line up.
    private static func paint(_ report: inout [UInt8], origin: Int, _ color: LightColor) {
        report[origin + 2] |= 0x04
        report[origin + 39] |= 0x02
        report[origin + 42] = 0x02
        report[origin + 43] = 0x00
        report[origin + 45] = channel(color.red)
        report[origin + 46] = channel(color.green)
        report[origin + 47] = channel(color.blue)
    }

    private static func crc32(seed: UInt8, bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        func mix(_ byte: UInt8) {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        mix(seed)
        for byte in bytes { mix(byte) }
        return ~crc
    }
}
