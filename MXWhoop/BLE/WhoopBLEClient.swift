import CoreBluetooth
import Foundation
import WhoopKit

/// CoreBluetooth client for WHOOP 5.0 / MG.
///
/// Connection recipe (noop / whoop-rs, hardware-verified):
///  1. Find the strap: reuse an OS-level connection (e.g. held by the official WHOOP app
///     on this iPhone — the bond is shared), otherwise scan for service FD4B0001.
///  2. Discover the custom service + standard Heart Rate / Battery / Device Information.
///  3. Subscribe to FD4B0003/04/05/07 and 2A37 (2A37 works even without a bond).
///  4. Write GET_HELLO *with response* to FD4B0002. The command characteristic needs an
///     encrypted link, so on first use iOS shows its pairing prompt here. Success of this
///     write means the link is bonded and the session is up.
///  5. The SensorHub then enables live HR (and IMU if wanted).
///
/// All callbacks run on the main queue.
final class WhoopBLEClient: NSObject, StrapLink {
    var onEvent: ((LinkEvent) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var notifyChars: [CBUUID: CBCharacteristic] = [:]
    private var assemblers: [CBUUID: FrameAssembler] = [:]
    private var sequencer = CommandSequencer()
    /// Labels of with-response writes in flight; CoreBluetooth completes them in order.
    private var pendingWrites: [String] = []
    private var queuedUntilReady: [CommandBody.Request] = []
    private var sessionReady = false
    private var wantConnection = false
    private var scanFallback: DispatchWorkItem?

    private static let lastStrapKey = "lastStrapIdentifier"
    private static let service = CBUUID(string: WhoopGATT.service)
    private static let commandWrite = CBUUID(string: WhoopGATT.commandWrite)
    private static let notifyUUIDs = Set(WhoopGATT.notifyCharacteristics.map { CBUUID(string: $0) })
    private static let hrService = CBUUID(string: WhoopGATT.heartRateService)
    private static let hrMeasurement = CBUUID(string: WhoopGATT.heartRateMeasurement)
    private static let batteryService = CBUUID(string: WhoopGATT.batteryService)
    private static let batteryLevel = CBUUID(string: WhoopGATT.batteryLevel)
    private static let disService = CBUUID(string: WhoopGATT.deviceInfoService)
    private static let disNames: [CBUUID: String] = [
        CBUUID(string: WhoopGATT.modelNumber): "Model",
        CBUUID(string: WhoopGATT.serialNumber): "Serial",
        CBUUID(string: WhoopGATT.firmwareRevision): "Firmware",
        CBUUID(string: WhoopGATT.hardwareRevision): "Hardware",
        CBUUID(string: WhoopGATT.manufacturerName): "Manufacturer",
    ]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: StrapLink

    func connect() {
        wantConnection = true
        guard central.state == .poweredOn else {
            emit(.log("Bluetooth not ready yet (\(central.state.rawValue)); will connect when it is."))
            return
        }
        startConnecting()
    }

    func disconnect() {
        wantConnection = false
        scanFallback?.cancel()
        if central.isScanning { central.stopScan() }
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        resetSession()
        emit(.state(.idle))
    }

    func send(_ request: CommandBody.Request) {
        guard let p = peripheral, p.state == .connected, let c = commandChar else {
            emit(.log("Not sent (\(request.label)): no connection"))
            return
        }
        guard sessionReady || request.command == CommandBody.hello.command else {
            queuedUntilReady.append(request)
            return
        }
        let (seq, frame) = sequencer.frame(request)
        pendingWrites.append(request.label)
        p.writeValue(Data(frame.bytes), for: c, type: .withResponse)
        emit(.commandSent(label: request.label, seq: seq, frame: frame))
    }

    // MARK: Connection flow

    private func startConnecting() {
        // 1. Already connected at the OS level (e.g. by the WHOOP app): share that bonded link.
        if let p = central.retrieveConnectedPeripherals(withServices: [Self.service]).first {
            emit(.log("Strap already connected to this iPhone — sharing the existing link."))
            attach(p)
            return
        }
        // 2. Scan for the WHOOP 5/MG service.
        emit(.state(.scanning))
        central.scanForPeripherals(withServices: [Self.service])
        // 3. Fallbacks: some firmware doesn't advertise the service UUID; and the last
        //    strap we used may be reachable without advertising.
        scanFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scanFallbackFired() }
        scanFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func scanFallbackFired() {
        guard wantConnection, peripheral == nil else { return }
        if let s = UserDefaults.standard.string(forKey: Self.lastStrapKey), let id = UUID(uuidString: s),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            emit(.log("Trying the last strap used (pending until it is in range)…"))
            central.stopScan()
            attach(p)
            return
        }
        emit(.log("No FD4B advertisement yet — widening scan to any device named WHOOP."))
        central.stopScan()
        central.scanForPeripherals(withServices: nil)
    }

    private func attach(_ p: CBPeripheral) {
        scanFallback?.cancel()
        peripheral = p
        p.delegate = self
        let name = p.name ?? "WHOOP"
        emit(.peripheral(name: name))
        emit(.state(.connecting(name)))
        central.connect(p)
    }

    private func resetSession() {
        commandChar = nil
        notifyChars.removeAll()
        assemblers.removeAll()
        pendingWrites.removeAll()
        queuedUntilReady.removeAll()
        sessionReady = false
    }

    private func sendHello() {
        emit(.state(.handshaking))
        send(CommandBody.hello)
    }

    private func sessionDidBecomeReady() {
        sessionReady = true
        if let p = peripheral {
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.lastStrapKey)
            // Subscriptions that failed before the link was encrypted can succeed now.
            for c in notifyChars.values where !c.isNotifying { p.setNotifyValue(true, for: c) }
        }
        emit(.state(.streaming))
        let queued = queuedUntilReady
        queuedUntilReady.removeAll()
        for request in queued { send(request) }
    }

    private func emit(_ e: LinkEvent) { onEvent?(e) }

    private static func isPairingError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == CBATTErrorDomain {
            return [CBATTError.insufficientAuthentication.rawValue,
                    CBATTError.insufficientEncryption.rawValue,
                    CBATTError.insufficientEncryptionKeySize.rawValue].contains(ns.code)
        }
        return ns.domain == CBErrorDomain && ns.code == CBError.peerRemovedPairingInformation.rawValue
    }

    static let pairingHelp = "Pairing refused. If the strap is paired with another phone, put it in pairing mode (tap the strap until the LED flashes blue). If iOS remembers an old pairing, forget the strap in Settings › Bluetooth, then connect again."
}

// MARK: - CBCentralManagerDelegate

extension WhoopBLEClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantConnection { startConnecting() } else { emit(.state(.idle)) }
        case .poweredOff: emit(.state(.unavailable("Bluetooth is off")))
        case .unauthorized: emit(.state(.unavailable("Bluetooth permission denied — enable it in Settings")))
        case .unsupported: emit(.state(.unavailable("Bluetooth LE unsupported here — use Demo mode")))
        default: emit(.state(.unavailable("Bluetooth unavailable")))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        if services.contains(CBUUID(string: WhoopGATT.whoop4Service)) {
            emit(.log("Ignoring \(name): WHOOP 4.0 uses a different protocol."))
            return
        }
        guard services.contains(Self.service) || name.uppercased().contains("WHOOP") else { return }
        emit(.log("Found \(name.isEmpty ? "strap" : name) (RSSI \(RSSI))"))
        central.stopScan()
        attach(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        resetSession()
        emit(.log("Connected; discovering services"))
        p.discoverServices([Self.service, Self.hrService, Self.batteryService, Self.disService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        let message = error.map { Self.isPairingError($0) ? Self.pairingHelp : "Connection failed: \($0.localizedDescription)" }
            ?? "Connection failed"
        emit(.state(.failed(message)))
        if wantConnection {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.wantConnection, central.state == .poweredOn else { return }
                central.connect(p)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        resetSession()
        guard wantConnection else { emit(.state(.idle)); return }
        if let error, Self.isPairingError(error) {
            emit(.state(.failed(Self.pairingHelp)))
        } else {
            emit(.state(.connecting(p.name ?? "WHOOP")))
            emit(.log("Link lost\(error.map { " (\($0.localizedDescription))" } ?? ""); reconnecting when in range"))
        }
        // A pending connect never times out: iOS completes it when the strap is back.
        central.connect(p)
    }
}

// MARK: - CBPeripheralDelegate

extension WhoopBLEClient: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { emit(.log("Service discovery failed: \(error.localizedDescription)")); return }
        let services = p.services ?? []
        if !services.contains(where: { $0.uuid == Self.service }) {
            emit(.state(.failed("This device has no WHOOP 5.0/MG service (FD4B0001).")))
        }
        services.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { emit(.log("Characteristic discovery failed: \(error.localizedDescription)")); return }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.commandWrite:
                commandChar = c
            case _ where Self.notifyUUIDs.contains(c.uuid):
                notifyChars[c.uuid] = c
                assemblers[c.uuid] = FrameAssembler()
                p.setNotifyValue(true, for: c)
            case Self.hrMeasurement:
                p.setNotifyValue(true, for: c)
            case Self.batteryLevel:
                p.readValue(for: c)
                if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
            case _ where Self.disNames[c.uuid] != nil:
                p.readValue(for: c)
            default:
                break
            }
        }
        if service.uuid == Self.service {
            if commandChar != nil { sendHello() }
            else { emit(.state(.failed("Command characteristic FD4B0002 missing."))) }
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        let label = pendingWrites.isEmpty ? "?" : pendingWrites.removeFirst()
        let isHello = label == CommandBody.hello.label
        if let error {
            if isHello, Self.isPairingError(error) {
                emit(.state(.failed(Self.pairingHelp)))
            } else {
                emit(.log("Write \(label) failed: \(error.localizedDescription)"))
                if isHello { emit(.state(.failed("Handshake failed: \(error.localizedDescription)"))) }
            }
            return
        }
        if isHello && !sessionReady {
            emit(.log("GET_HELLO acknowledged — link is bonded"))
            sessionDidBecomeReady()
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard let error else { return }
        // Before the bond completes the custom characteristics can refuse; we retry after hello.
        emit(.log("Subscribe \(c.uuid.uuidString.prefix(8)) failed: \(error.localizedDescription)"))
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let data = c.value else { return }
        let bytes = [UInt8](data)
        if var assembler = assemblers[c.uuid] {
            let outputs = assembler.append(bytes)
            assemblers[c.uuid] = assembler
            let channel = Self.channel(for: c.uuid)
            for out in outputs {
                switch out {
                case .frame(let f): emit(.frame(f, channel))
                case .corrupt(let raw, let why): emit(.corruptFrame(raw, why, channel))
                }
            }
            return
        }
        switch c.uuid {
        case Self.hrMeasurement:
            if let m = StandardHeartRate(bytes) { emit(.standardHR(m)) }
        case Self.batteryLevel:
            if let b = bytes.first { emit(.battery(Int(b))) }
        default:
            if let key = Self.disNames[c.uuid] {
                let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .controlCharacters.union(.whitespaces))
                emit(.deviceInfo(key: key, value: value))
            }
        }
    }

    private static func channel(for uuid: CBUUID) -> LinkChannel {
        switch uuid.uuidString.uppercased() {
        case WhoopGATT.commandNotify: .command
        case WhoopGATT.eventNotify: .event
        case WhoopGATT.memfaultNotify: .memfault
        default: .data
        }
    }
}
