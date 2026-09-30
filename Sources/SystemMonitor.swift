import Foundation
import Darwin
import AppKit

struct DiskInfo: Identifiable {
    let id = UUID()
    let name: String
    let mountPath: String
    let total: UInt64
    let available: UInt64
    var used: UInt64 { total > available ? total - available : 0 }
}

final class SystemMonitor {
    // Se llama en el hilo principal cada vez que hay datos nuevos
    var onChange: (() -> Void)?

    // RAM
    private(set) var ramTotal: UInt64 = 0
    private(set) var ramUsed: UInt64 = 0
    private(set) var ramFree: UInt64 = 0

    // Discos
    private(set) var disks: [DiskInfo] = []

    // Red (bytes/segundo)
    private(set) var downloadRate: Double = 0
    private(set) var uploadRate: Double = 0

    // Ping (ms), nil = sin respuesta
    private(set) var pingMs: Double? = nil

    // CPU (0…1) y estado térmico
    private(set) var cpuUsage: Double = 0
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    // Historial de red (bytes/s, últimas 60 muestras ≈ 2 min)
    private(set) var downHistory: [Double] = []
    private(set) var upHistory: [Double] = []

    // Uso de contexto de Kimi (conversación activa)
    private(set) var kimiContextUsed: Int = 0
    private(set) var kimiContextMax: Int = 0
    private(set) var kimiContextAvailable = false

    // Test de velocidad (Mbps)
    private(set) var speedTestRunning = false
    private(set) var speedDown: Double? = nil
    private(set) var speedUp: Double? = nil

    private var timer: Timer?
    private var lastRx: UInt64 = 0
    private var lastTx: UInt64 = 0
    private var lastSampleTime: Date = Date()
    private var prevCpuTicks: [(user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)]?

    func start() {
        refreshFast()
        refreshPing()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshFast()
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshPing()
        }
    }

    // MARK: - Actualización rápida (RAM, discos, red) — hilo principal

    func refreshFast() {
        refreshMemory()
        refreshCPU()
        refreshThermal()
        refreshDisks()
        refreshNetwork()
        refreshKimiUsage()
        onChange?()
    }

    private func refreshMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let pageSize = UInt64(vm_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        let used = UInt64(stats.active_count) * pageSize
                 + UInt64(stats.wire_count) * pageSize
                 + UInt64(stats.compressor_page_count) * pageSize
        let free = total > used ? total - used : 0
        ramTotal = total
        ramUsed = min(used, total)
        ramFree = free
    }

    // MARK: - CPU

    private func refreshCPU() {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &numCPUs, &cpuInfo, &numCpuInfo)
        guard result == KERN_SUCCESS, let info = cpuInfo else { return }
        defer {
            let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }
        var ticks: [(user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)] = []
        for i in 0..<Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * i
            ticks.append((
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                sys: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }
        if let prev = prevCpuTicks, prev.count == ticks.count {
            var usedSum = 0.0
            var totalSum = 0.0
            for (a, b) in zip(prev, ticks) {
                let dUser = Double(b.user &- a.user)
                let dSys = Double(b.sys &- a.sys)
                let dIdle = Double(b.idle &- a.idle)
                let dNice = Double(b.nice &- a.nice)
                usedSum += dUser + dSys + dNice
                totalSum += dUser + dSys + dNice + dIdle
            }
            cpuUsage = totalSum > 0 ? min(max(usedSum / totalSum, 0), 1) : 0
        }
        prevCpuTicks = ticks
    }

    // MARK: - Estado térmico

    private func refreshThermal() {
        thermalState = ProcessInfo.processInfo.thermalState
    }

    static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Moderada"
        case .serious: return "Alta"
        case .critical: return "Crítica"
        @unknown default: return "—"
        }
    }

    // MARK: - Uso de contexto de Kimi

    private func refreshKimiUsage() {
        let path = NSHomeDirectory()
            + "/Library/Application Support/kimi-desktop/kimi-agent/conversation-context-usage.json"
        guard let data = FileManager.default.contents(atPath: path),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else {
            kimiContextAvailable = false
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var bestDate = Date.distantPast
        var found = false
        for (_, entry) in dict {
            guard let used = entry["contextTokens"] as? Int,
                  let maxTokens = entry["maxContextTokens"] as? Int else { continue }
            let date = (entry["updatedAt"] as? String)
                .flatMap { formatter.date(from: $0) } ?? .distantPast
            if date >= bestDate {
                bestDate = date
                kimiContextUsed = used
                kimiContextMax = maxTokens
                found = true
            }
        }
        kimiContextAvailable = found
    }

    private func refreshDisks() {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) else { return }

        var result: [DiskInfo] = []
        var seen: Set<String> = []
        for url in urls {
            let path = url.path
            // Solo el volumen raíz y volúmenes reales montados en /Volumes
            guard path == "/" || path.hasPrefix("/Volumes/") else { continue }
            guard let values = try? url.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity,
                  total > 0 else { continue }
            let available = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            let name = values.volumeName ?? url.lastPathComponent
            // Evitar duplicados (p. ej. "Macintosh HD" y su volumen de datos)
            let signature = "\(total)-\(name)"
            guard !seen.contains(signature) else { continue }
            seen.insert(signature)
            result.append(DiskInfo(name: name, mountPath: path,
                                   total: UInt64(total), available: available))
        }
        disks = result
    }

    private func refreshNetwork() {
        let (rx, tx) = interfaceBytes()
        let now = Date()
        let interval = now.timeIntervalSince(lastSampleTime)
        if interval > 0, lastRx > 0 {
            downloadRate = rx >= lastRx ? Double(rx - lastRx) / interval : 0
            uploadRate = tx >= lastTx ? Double(tx - lastTx) / interval : 0
        }
        lastRx = rx
        lastTx = tx
        lastSampleTime = now

        // Historial para el gráfico (máx. 60 muestras ≈ 2 minutos)
        downHistory.append(downloadRate)
        upHistory.append(uploadRate)
        if downHistory.count > 60 { downHistory.removeFirst(downHistory.count - 60) }
        if upHistory.count > 60 { upHistory.removeFirst(upHistory.count - 60) }
    }

    /// Suma de bytes recibidos/transmitidos en interfaces físicas (en0, en1, …)
    private func interfaceBytes() -> (rx: UInt64, tx: UInt64) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(addrs) }
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = ptr?.pointee {
            let name = String(cString: iface.ifa_name)
            if name.hasPrefix("en"), let data = iface.ifa_data {
                let ifData = data.assumingMemoryBound(to: if_data.self).pointee
                rx += UInt64(bitPattern: Int64(ifData.ifi_ibytes))
                tx += UInt64(bitPattern: Int64(ifData.ifi_obytes))
            }
            ptr = iface.ifa_next
        }
        return (rx, tx)
    }

    // MARK: - Ping

    func refreshPing() {
        Task {
            let value = await Self.measurePing()
            await MainActor.run {
                self.pingMs = value
                self.onChange?()
            }
        }
    }

    nonisolated private static func measurePing() async -> Double? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/sbin/ping")
                process.arguments = ["-c", "1", "-t", "2", "1.1.1.1"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                // Buscar "time=12.34 ms"
                if let range = output.range(of: "time=") {
                    let rest = output[range.upperBound...]
                    let number = rest.prefix { $0.isNumber || $0 == "." }
                    continuation.resume(returning: Double(number))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Test de velocidad (Cloudflare)

    func runSpeedTest() {
        guard !speedTestRunning else { return }
        speedTestRunning = true
        speedDown = nil
        speedUp = nil
        onChange?()
        Task {
            let down = await Self.measureDownload()
            let up = await Self.measureUpload()
            await MainActor.run {
                self.speedDown = down
                self.speedUp = up
                self.speedTestRunning = false
                self.onChange?()
            }
        }
    }

    /// Descarga 20 MB y devuelve Mbps
    nonisolated private static func measureDownload() async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=20000000") else { return nil }
        let start = Date()
        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            let session = URLSession(configuration: config)
            let (data, _) = try await session.data(from: url)
            let seconds = Date().timeIntervalSince(start)
            guard seconds > 0 else { return nil }
            return Double(data.count) * 8 / seconds / 1_000_000
        } catch {
            return nil
        }
    }

    /// Sube 5 MB y devuelve Mbps
    nonisolated private static func measureUpload() async -> Double? {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let payload = Data(count: 5_000_000)
        let start = Date()
        do {
            let config = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: config)
            _ = try await session.upload(for: request, from: payload)
            let seconds = Date().timeIntervalSince(start)
            guard seconds > 0 else { return nil }
            return Double(payload.count) * 8 / seconds / 1_000_000
        } catch {
            return nil
        }
    }

    // MARK: - Formateo

    static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    static func formatRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
        } else if bytesPerSecond >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}
