//
//  PerformanceMonitor.swift
//  Nook
//
//  Lightweight system performance sampling for the notch UI.
//

import Combine
import Darwin
import Foundation
import IOKit.ps

struct PerformanceSnapshot: Equatable {
    var cpuUsage: Double
    var cpuCoreUsages: [Double]
    var cpuLoadAverages: [Double]
    var memory: PerformanceMemorySnapshot
    var battery: PerformanceBatterySnapshot
    var network: PerformanceNetworkSnapshot
    var sampledAt: Date

    static let empty = PerformanceSnapshot(
        cpuUsage: 0,
        cpuCoreUsages: [],
        cpuLoadAverages: [],
        memory: .empty,
        battery: .unavailable,
        network: .empty,
        sampledAt: Date()
    )
}

struct PerformanceMemorySnapshot: Equatable {
    var usedBytes: UInt64
    var totalBytes: UInt64
    var appMemoryBytes: UInt64
    var wiredMemoryBytes: UInt64
    var compressedBytes: UInt64
    var cachedFilesBytes: UInt64
    var swapUsedBytes: UInt64
    var processes: [PerformanceProcessSnapshot]

    static let empty = PerformanceMemorySnapshot(
        usedBytes: 0,
        totalBytes: Foundation.ProcessInfo.processInfo.physicalMemory,
        appMemoryBytes: 0,
        wiredMemoryBytes: 0,
        compressedBytes: 0,
        cachedFilesBytes: 0,
        swapUsedBytes: 0,
        processes: []
    )

    var usage: Double {
        usage(for: usedBytes)
    }

    var appMemoryUsage: Double {
        usage(for: appMemoryBytes)
    }

    var wiredMemoryUsage: Double {
        usage(for: wiredMemoryBytes)
    }

    var compressedUsage: Double {
        usage(for: compressedBytes)
    }

    var cachedFilesUsage: Double {
        usage(for: cachedFilesBytes)
    }

    func usage(for bytes: UInt64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(bytes) / Double(totalBytes), 0), 1)
    }
}

struct PerformanceProcessSnapshot: Identifiable, Equatable {
    var pid: pid_t
    var name: String
    var executablePath: String?
    var residentMemoryBytes: UInt64
    var memoryUsage: Double

    var id: pid_t { pid }
}

struct PerformanceBatterySnapshot: Equatable {
    var level: Double?
    var isCharging: Bool
    var isPluggedIn: Bool
    var timeRemainingMinutes: Int?

    static let unavailable = PerformanceBatterySnapshot(
        level: nil,
        isCharging: false,
        isPluggedIn: false,
        timeRemainingMinutes: nil
    )
}

struct PerformanceNetworkSnapshot: Equatable {
    var downloadBytesPerSecond: UInt64
    var uploadBytesPerSecond: UInt64
    var receivedBytes: UInt64
    var sentBytes: UInt64
    var interfaces: [PerformanceNetworkInterfaceSnapshot]

    static let empty = PerformanceNetworkSnapshot(
        downloadBytesPerSecond: 0,
        uploadBytesPerSecond: 0,
        receivedBytes: 0,
        sentBytes: 0,
        interfaces: []
    )
}

struct PerformanceNetworkInterfaceSnapshot: Identifiable, Equatable {
    var name: String
    var downloadBytesPerSecond: UInt64
    var uploadBytesPerSecond: UInt64
    var receivedBytes: UInt64
    var sentBytes: UInt64

    var id: String { name }
}

struct PerformanceHistorySample: Identifiable, Equatable {
    var sampledAt: Date
    var cpuUsage: Double
    var memoryUsage: Double
    var appMemoryUsage: Double
    var wiredMemoryUsage: Double
    var compressedMemoryUsage: Double
    var cachedFilesUsage: Double
    var batteryLevel: Double?
    var downloadBytesPerSecond: UInt64
    var uploadBytesPerSecond: UInt64

    var id: TimeInterval { sampledAt.timeIntervalSinceReferenceDate }
}

@MainActor
final class PerformanceMonitor: ObservableObject {
    @Published private(set) var snapshot: PerformanceSnapshot = .empty
    @Published private(set) var history: [PerformanceHistorySample] = []

    private struct CPUTicks {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64
    }

    private struct CPUUsageSample {
        let totalUsage: Double
        let coreUsages: [Double]
    }

    private struct NetworkInterfaceTotals {
        let name: String
        let receivedBytes: UInt64
        let sentBytes: UInt64
    }

    private struct NetworkTotals {
        let receivedBytes: UInt64
        let sentBytes: UInt64
        let interfaces: [NetworkInterfaceTotals]
        let sampledAt: Date
    }

    private let sampleInterval: TimeInterval
    private let processSampleInterval: TimeInterval = 10
    private let maxHistorySampleCount = 90
    private var timer: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var isProcessDetailsActive = false
    private var previousCPUTicks: [CPUTicks]?
    private var previousNetworkTotals: NetworkTotals?
    private var lastProcessSampleAt: Date = .distantPast
    private var lastProcessSnapshots: [PerformanceProcessSnapshot] = []

    init(sampleInterval: TimeInterval = 2) {
        self.sampleInterval = sampleInterval
    }

    deinit {
        timer?.invalidate()
        if let powerSourceRunLoopSource {
            CFRunLoopSourceInvalidate(powerSourceRunLoopSource)
        }
    }

    func setActive(_ isActive: Bool) {
        if isActive {
            start()
        } else {
            stop()
        }
    }

    func refresh() {
        let previousCPUUsage = snapshot.cpuUsage
        let previousCoreUsages = snapshot.cpuCoreUsages
        let cpuSample = readCPUUsage()
        let cpuUsage = cpuSample?.totalUsage ?? previousCPUUsage
        let cpuCoreUsages = cpuSample?.coreUsages ?? previousCoreUsages
        let cpuLoadAverages = readLoadAverages()
        let memory = readMemorySnapshot() ?? snapshot.memory
        let battery = readBatterySnapshot() ?? .unavailable
        let network = readNetworkSnapshot()

        let updatedSnapshot = PerformanceSnapshot(
            cpuUsage: cpuUsage,
            cpuCoreUsages: cpuCoreUsages,
            cpuLoadAverages: cpuLoadAverages,
            memory: memory,
            battery: battery,
            network: network,
            sampledAt: Date()
        )
        snapshot = updatedSnapshot
        recordHistory(from: updatedSnapshot)
    }

    func setProcessDetailsActive(_ isActive: Bool) {
        guard isProcessDetailsActive != isActive else { return }

        isProcessDetailsActive = isActive
        lastProcessSampleAt = .distantPast

        if !isActive {
            lastProcessSnapshots.removeAll(keepingCapacity: false)
            clearSnapshotProcessDetails()
        }
    }

    private func start() {
        guard timer == nil else { return }

        startPowerSourceNotifications()
        refresh()

        let timer = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        stopPowerSourceNotifications()
        setProcessDetailsActive(false)
        history.removeAll(keepingCapacity: false)
    }

    private func startPowerSourceNotifications() {
        guard powerSourceRunLoopSource == nil else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }

            let monitor = Unmanaged<PerformanceMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                monitor.handlePowerSourceDidChange()
            }
        }, context)?.takeRetainedValue() else {
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceRunLoopSource = source
    }

    private func stopPowerSourceNotifications() {
        guard let powerSourceRunLoopSource else { return }

        CFRunLoopSourceInvalidate(powerSourceRunLoopSource)
        self.powerSourceRunLoopSource = nil
    }

    private func handlePowerSourceDidChange() {
        refreshBatteryState()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            Task { @MainActor in
                self?.refreshBatteryState()
            }
        }
    }

    private func refreshBatteryState() {
        var updatedSnapshot = snapshot
        updatedSnapshot.battery = readBatterySnapshot() ?? .unavailable
        updatedSnapshot.sampledAt = Date()
        snapshot = updatedSnapshot
        recordHistory(from: updatedSnapshot)
    }

    private func recordHistory(from snapshot: PerformanceSnapshot) {
        let sample = PerformanceHistorySample(
            sampledAt: snapshot.sampledAt,
            cpuUsage: snapshot.cpuUsage,
            memoryUsage: snapshot.memory.usage,
            appMemoryUsage: snapshot.memory.appMemoryUsage,
            wiredMemoryUsage: snapshot.memory.wiredMemoryUsage,
            compressedMemoryUsage: snapshot.memory.compressedUsage,
            cachedFilesUsage: snapshot.memory.cachedFilesUsage,
            batteryLevel: snapshot.battery.level,
            downloadBytesPerSecond: snapshot.network.downloadBytesPerSecond,
            uploadBytesPerSecond: snapshot.network.uploadBytesPerSecond
        )

        if let lastSample = history.last,
           sample.sampledAt.timeIntervalSince(lastSample.sampledAt) < 0.75 {
            history[history.index(before: history.endIndex)] = sample
        } else {
            history.append(sample)
        }

        if history.count > maxHistorySampleCount {
            history.removeFirst(history.count - maxHistorySampleCount)
        }
    }

    private func readCPUUsage() -> CPUUsageSample? {
        guard let currentTicks = readCPUTicks(), !currentTicks.isEmpty else {
            return nil
        }

        defer {
            previousCPUTicks = currentTicks
        }

        guard let previousTicks = previousCPUTicks, previousTicks.count == currentTicks.count else {
            return nil
        }

        var totalDelta: UInt64 = 0
        var idleDelta: UInt64 = 0
        var coreUsages: [Double] = []

        for (current, previous) in zip(currentTicks, previousTicks) {
            let user = delta(current.user, previous.user)
            let system = delta(current.system, previous.system)
            let idle = delta(current.idle, previous.idle)
            let nice = delta(current.nice, previous.nice)

            totalDelta += user + system + idle + nice
            idleDelta += idle

            let coreTotal = user + system + idle + nice
            if coreTotal > 0 {
                coreUsages.append(min(max(Double(coreTotal - idle) / Double(coreTotal), 0), 1))
            } else {
                coreUsages.append(0)
            }
        }

        guard totalDelta > 0 else { return nil }
        let busyDelta = totalDelta - idleDelta
        return CPUUsageSample(
            totalUsage: min(max(Double(busyDelta) / Double(totalDelta), 0), 1),
            coreUsages: coreUsages
        )
    }

    private func readLoadAverages() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        let count = loads.withUnsafeMutableBufferPointer { buffer in
            getloadavg(buffer.baseAddress, Int32(buffer.count))
        }

        guard count > 0 else {
            return snapshot.cpuLoadAverages
        }

        return Array(loads.prefix(Int(count)))
    }

    private func readCPUTicks() -> [CPUTicks]? {
        var processorCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &cpuInfo,
            &cpuInfoCount
        )

        guard result == KERN_SUCCESS, let cpuInfo else {
            return nil
        }

        defer {
            let byteCount = vm_size_t(Int(cpuInfoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), byteCount)
        }

        let buffer = UnsafeBufferPointer(start: cpuInfo, count: Int(cpuInfoCount))
        let stateCount = Int(CPU_STATE_MAX)

        return (0..<Int(processorCount)).compactMap { cpuIndex in
            let offset = cpuIndex * stateCount
            guard offset + Int(CPU_STATE_NICE) < buffer.count else {
                return nil
            }

            return CPUTicks(
                user: tickValue(buffer[offset + Int(CPU_STATE_USER)]),
                system: tickValue(buffer[offset + Int(CPU_STATE_SYSTEM)]),
                idle: tickValue(buffer[offset + Int(CPU_STATE_IDLE)]),
                nice: tickValue(buffer[offset + Int(CPU_STATE_NICE)])
            )
        }
    }

    private func readMemorySnapshot() -> PerformanceMemorySnapshot? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return nil
        }

        let totalBytes = Foundation.ProcessInfo.processInfo.physicalMemory
        let pageBytes = UInt64(pageSize)
        let appMemoryBytes = pageBytes * pageDelta(stats.internal_page_count, stats.purgeable_count)
        let wiredMemoryBytes = pageBytes * UInt64(stats.wire_count)
        let compressedBytes = pageBytes * UInt64(stats.compressor_page_count)
        let cachedFilesBytes = pageBytes * (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count))
        let usedBytes = min(
            totalBytes,
            appMemoryBytes + wiredMemoryBytes + compressedBytes
        )

        return PerformanceMemorySnapshot(
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            appMemoryBytes: appMemoryBytes,
            wiredMemoryBytes: wiredMemoryBytes,
            compressedBytes: compressedBytes,
            cachedFilesBytes: cachedFilesBytes,
            swapUsedBytes: readSwapUsedBytes(),
            processes: isProcessDetailsActive ? readCachedProcessSnapshots(totalMemory: totalBytes) : []
        )
    }

    private func readSwapUsedBytes() -> UInt64 {
        var swapUsage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let result = sysctlbyname("vm.swapusage", &swapUsage, &size, nil, 0)

        guard result == 0 else {
            return 0
        }

        return UInt64(swapUsage.xsu_used)
    }

    private func clearSnapshotProcessDetails() {
        guard !snapshot.memory.processes.isEmpty else { return }

        var updatedMemory = snapshot.memory
        updatedMemory.processes.removeAll(keepingCapacity: false)

        var updatedSnapshot = snapshot
        updatedSnapshot.memory = updatedMemory
        updatedSnapshot.sampledAt = Date()
        snapshot = updatedSnapshot
    }

    private func readCachedProcessSnapshots(totalMemory: UInt64) -> [PerformanceProcessSnapshot] {
        let now = Date()
        guard now.timeIntervalSince(lastProcessSampleAt) >= processSampleInterval || lastProcessSnapshots.isEmpty else {
            return lastProcessSnapshots
        }

        lastProcessSampleAt = now
        lastProcessSnapshots = readProcessSnapshots(totalMemory: totalMemory)
        return lastProcessSnapshots
    }

    private func readProcessSnapshots(totalMemory: UInt64) -> [PerformanceProcessSnapshot] {
        var capacity = 4096

        while capacity <= 32768 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))

            if count <= 0 {
                return []
            }

            if count < capacity {
                return pids.prefix(count)
                    .compactMap { processSnapshot(for: $0, totalMemory: totalMemory) }
                    .sorted {
                        if $0.residentMemoryBytes == $1.residentMemoryBytes {
                            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                        }
                        return $0.residentMemoryBytes > $1.residentMemoryBytes
                    }
            }

            capacity *= 2
        }

        return []
    }

    private func processSnapshot(for pid: pid_t, totalMemory: UInt64) -> PerformanceProcessSnapshot? {
        guard pid > 0 else { return nil }

        var taskInfo = proc_taskinfo()
        let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        let taskResult = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize)

        guard taskResult == taskInfoSize, taskInfo.pti_resident_size > 0 else {
            return nil
        }

        let residentMemoryBytes = UInt64(taskInfo.pti_resident_size)
        let memoryUsage = totalMemory > 0 ? min(max(Double(residentMemoryBytes) / Double(totalMemory), 0), 1) : 0
        let executablePath = executablePath(for: pid)

        return PerformanceProcessSnapshot(
            pid: pid,
            name: processName(for: pid, executablePath: executablePath),
            executablePath: executablePath,
            residentMemoryBytes: residentMemoryBytes,
            memoryUsage: memoryUsage
        )
    }

    private func processName(for pid: pid_t, executablePath: String?) -> String {
        var bsdInfo = proc_bsdinfo()
        let bsdInfoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let bsdResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdInfoSize)

        if bsdResult == bsdInfoSize {
            let name = cString(from: bsdInfo.pbi_name)
            if !name.isEmpty {
                return name
            }
        }

        if let executablePath {
            let pathName = URL(fileURLWithPath: executablePath).lastPathComponent
            if !pathName.isEmpty {
                return pathName
            }
        }

        return "Process \(pid)"
    }

    private func executablePath(for pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathResult = proc_pidpath(pid, &path, UInt32(path.count))
        guard pathResult > 0 else {
            return nil
        }

        let pathString = String(cString: path)
        return pathString.isEmpty ? nil : pathString
    }

    private func readBatterySnapshot() -> PerformanceBatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let currentCapacity = description[kIOPSCurrentCapacityKey as String] as? Int,
                  let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Int,
                  maxCapacity > 0 else {
                continue
            }

            let state = description[kIOPSPowerSourceStateKey as String] as? String
            let isPluggedIn = state == (kIOPSACPowerValue as String)
            let isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
            let timeKey = isCharging ? kIOPSTimeToFullChargeKey as String : kIOPSTimeToEmptyKey as String
            let rawTimeRemaining = description[timeKey] as? Int
            let timeRemaining = rawTimeRemaining.flatMap { $0 > 0 ? $0 : nil }

            return PerformanceBatterySnapshot(
                level: min(max(Double(currentCapacity) / Double(maxCapacity), 0), 1),
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                timeRemainingMinutes: timeRemaining
            )
        }

        return nil
    }

    private func readNetworkSnapshot() -> PerformanceNetworkSnapshot {
        let currentTotals = readNetworkTotals()

        defer {
            previousNetworkTotals = currentTotals
        }

        guard let previousTotals = previousNetworkTotals else {
            return PerformanceNetworkSnapshot(
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0,
                receivedBytes: currentTotals.receivedBytes,
                sentBytes: currentTotals.sentBytes,
                interfaces: currentTotals.interfaces
                    .map {
                        PerformanceNetworkInterfaceSnapshot(
                            name: $0.name,
                            downloadBytesPerSecond: 0,
                            uploadBytesPerSecond: 0,
                            receivedBytes: $0.receivedBytes,
                            sentBytes: $0.sentBytes
                        )
                    }
                    .sorted { $0.name < $1.name }
            )
        }

        let elapsed = max(currentTotals.sampledAt.timeIntervalSince(previousTotals.sampledAt), 0.001)
        let receivedDelta = delta(currentTotals.receivedBytes, previousTotals.receivedBytes)
        let sentDelta = delta(currentTotals.sentBytes, previousTotals.sentBytes)
        let previousInterfaces = Dictionary(uniqueKeysWithValues: previousTotals.interfaces.map { ($0.name, $0) })
        let interfaces = currentTotals.interfaces
            .map { current in
                let previous = previousInterfaces[current.name]
                let download = UInt64(Double(delta(current.receivedBytes, previous?.receivedBytes ?? current.receivedBytes)) / elapsed)
                let upload = UInt64(Double(delta(current.sentBytes, previous?.sentBytes ?? current.sentBytes)) / elapsed)

                return PerformanceNetworkInterfaceSnapshot(
                    name: current.name,
                    downloadBytesPerSecond: download,
                    uploadBytesPerSecond: upload,
                    receivedBytes: current.receivedBytes,
                    sentBytes: current.sentBytes
                )
            }
            .sorted {
                let lhsRate = $0.downloadBytesPerSecond + $0.uploadBytesPerSecond
                let rhsRate = $1.downloadBytesPerSecond + $1.uploadBytesPerSecond
                if lhsRate == rhsRate {
                    return $0.name < $1.name
                }
                return lhsRate > rhsRate
            }

        return PerformanceNetworkSnapshot(
            downloadBytesPerSecond: UInt64(Double(receivedDelta) / elapsed),
            uploadBytesPerSecond: UInt64(Double(sentDelta) / elapsed),
            receivedBytes: currentTotals.receivedBytes,
            sentBytes: currentTotals.sentBytes,
            interfaces: interfaces
        )
    }

    private func readNetworkTotals() -> NetworkTotals {
        var receivedBytes: UInt64 = 0
        var sentBytes: UInt64 = 0
        var interfaceTotals: [String: (receivedBytes: UInt64, sentBytes: UInt64)] = [:]
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        if getifaddrs(&interfaces) == 0, let firstInterface = interfaces {
            defer {
                freeifaddrs(firstInterface)
            }

            var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
            while let interfacePointer = pointer {
                let interface = interfacePointer.pointee
                pointer = interface.ifa_next

                let flags = Int32(interface.ifa_flags)
                guard (flags & IFF_UP) != 0,
                      (flags & IFF_RUNNING) != 0,
                      (flags & IFF_LOOPBACK) == 0,
                      let address = interface.ifa_addr,
                      Int32(address.pointee.sa_family) == AF_LINK,
                      let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else {
                    continue
                }

                let name = String(cString: interface.ifa_name)
                let received = UInt64(data.ifi_ibytes)
                let sent = UInt64(data.ifi_obytes)

                receivedBytes += received
                sentBytes += sent

                let existing = interfaceTotals[name] ?? (receivedBytes: 0, sentBytes: 0)
                interfaceTotals[name] = (
                    receivedBytes: existing.receivedBytes + received,
                    sentBytes: existing.sentBytes + sent
                )
            }
        }

        return NetworkTotals(
            receivedBytes: receivedBytes,
            sentBytes: sentBytes,
            interfaces: interfaceTotals.map {
                NetworkInterfaceTotals(
                    name: $0.key,
                    receivedBytes: $0.value.receivedBytes,
                    sentBytes: $0.value.sentBytes
                )
            },
            sampledAt: Date()
        )
    }

    private func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private func pageDelta(_ current: natural_t, _ previous: natural_t) -> UInt64 {
        let currentValue = UInt64(current)
        let previousValue = UInt64(previous)
        return currentValue >= previousValue ? currentValue - previousValue : 0
    }

    private func tickValue(_ value: integer_t) -> UInt64 {
        UInt64(UInt32(bitPattern: value))
    }

    private func cString<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { rawBuffer in
            let chars = rawBuffer.bindMemory(to: CChar.self)
            return String(cString: Array(chars) + [0])
        }
    }
}
