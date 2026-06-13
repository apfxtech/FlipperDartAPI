import Cocoa
import FlutterMacOS
import CoreBluetooth

// MARK: - Per-peripheral mutable state

private final class PeripheralState {
    // Service discovery
    var discoveryResult: FlutterResult?
    var pendingServices: Set<CBUUID> = []
    // Characteristic lookup by UUID
    var charMap: [CBUUID: CBCharacteristic] = [:]
    // Pending reads keyed by characteristic UUID
    var pendingReads: [CBUUID: FlutterResult] = [:]
    // Pending subscribe confirmations
    var pendingSubscribes: [CBUUID: FlutterResult] = [:]
    // Write-without-response queue. Only the final ATT packet owns the result
    // for the original split-write call.
    var noRspQueue: [(CBCharacteristic, Data, FlutterResult?)] = []
    // Write-with-response queues per characteristic (only one in-flight at a time)
    var rspQueue: [CBUUID: [(Data, FlutterResult)]] = [:]
}

// MARK: - Plugin

@objc(FlipperBlePlugin)
public final class FlipperBlePlugin: NSObject, FlutterPlugin {

    static let kMethodChannel = "com.qunleashed.flipper/ble"
    static let kEventChannel  = "com.qunleashed.flipper/ble/events"
    // Flipper negotiates ATT_MTU=414, so a Write Command can carry at most
    // ATT_MTU - 3 = 411 bytes. The 486-byte characteristic value limit is not
    // a valid single-packet write size.
    private static let flipperAttWritePayloadMax = 411

    // UUID of the Flipper Zero primary BLE service — used for system-device lookup
    private static let flipperSvcUUID = CBUUID(string: "8fe5b3d5-2e7f-4a98-2a48-7acc60fe0000")

    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = FlipperBlePlugin()
        FlutterMethodChannel(name: kMethodChannel, binaryMessenger: registrar.messenger)
            .setMethodCallHandler { [weak plugin] call, result in
                plugin?.handle(call, result: result)
            }
        FlutterEventChannel(name: kEventChannel, binaryMessenger: registrar.messenger)
            .setStreamHandler(plugin)
    }

    // MARK: - State

    // Dedicated serial queue for all CoreBluetooth work.
    // Keeps BLE callbacks off the main thread so Flutter UI and WiFi coexistence
    // scheduling on the shared Broadcom combo chip do not stall BLE events.
    private let bleQueue = DispatchQueue(
        label: "com.qunleashed.flipper.ble.cb",
        qos: .userInteractive
    )

    // Lazily created so the plugin registering does not, by itself, spin up a
    // second CBCentralManager. The Dart side now drives the whole BLE lifecycle
    // (scan + connect + GATT) through universal_ble's single central; this
    // native central is only built if some method channel call actually touches
    // it. Two coexisting CBCentralManagers in one process is exactly what Apple
    // warns against — they contend for connection-event scheduling and the link
    // drops with spurious supervision timeouts even while idle.
    //
    // First access is always on bleQueue (handle() dispatches there before any
    // central use, and every delegate callback already runs on bleQueue), so
    // the non-atomic lazy initialization stays single-threaded.
    private lazy var central: CBCentralManager = CBCentralManager(
        delegate: self, queue: bleQueue,
        options: [CBCentralManagerOptionShowPowerAlertKey: true]
    )
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var pstate: [UUID: PeripheralState] = [:]
    private var pendingConnects: [UUID: FlutterResult] = [:]
    private var pendingDisconnectReasons: [UUID: String] = [:]
    // UUIDs we are scanning for to satisfy a connect() call
    private var connectScanTargets: Set<UUID> = []
    private var eventSink: FlutterEventSink?

    // MARK: - Helpers

    private func st(_ p: CBPeripheral) -> PeripheralState {
        if let s = pstate[p.identifier] { return s }
        let s = PeripheralState()
        pstate[p.identifier] = s
        return s
    }

    // eventSink must be called on the main thread (Flutter requirement).
    // bleQueue callbacks dispatch here so BLE processing and event delivery are decoupled.
    private func emit(_ event: Any) {
        DispatchQueue.main.async { [weak self] in self?.eventSink?(event) }
    }

    private func centralStateStr() -> String {
        switch central.state {
        case .poweredOn:    return "poweredOn"
        case .poweredOff:   return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported:  return "unsupported"
        case .resetting:    return "resetting"
        default:            return "unknown"
        }
    }

    private func connStr(_ s: CBPeripheralState) -> String {
        switch s {
        case .connected:     return "connected"
        case .connecting:    return "connecting"
        case .disconnecting: return "disconnecting"
        default:             return "disconnected"
        }
    }

    private func propsMap(_ p: CBCharacteristicProperties) -> [String: Any] {[
        "canRead":       p.contains(.read),
        "canWrite":      p.contains(.write),
        "canWriteNoRsp": p.contains(.writeWithoutResponse),
        "canNotify":     p.contains(.notify),
        "canIndicate":   p.contains(.indicate),
    ]}

    private func peripheral(for id: String) -> CBPeripheral? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return peripherals[uuid]
    }

    // Locate a characteristic by its UUID across all discovered services.
    // Falls back to walking the peripheral tree if not yet in the state cache.
    private func findChar(_ svcStr: String, _ chrStr: String,
                           in p: CBPeripheral) -> CBCharacteristic? {
        let chrUUID = CBUUID(string: chrStr)
        if let ch = pstate[p.identifier]?.charMap[chrUUID] { return ch }
        let svcUUID = CBUUID(string: svcStr)
        return p.services?.first(where: { $0.uuid == svcUUID })?
                          .characteristics?.first(where: { $0.uuid == chrUUID })
    }

    // MARK: - Connect flow

    private func doConnect(_ uuid: UUID, result: @escaping FlutterResult) {
        // 1. Already in our manager's peripheral cache
        if let p = peripherals[uuid] {
            startConnect(p, result: result)
            return
        }
        // 2. Connected by any CBCentralManager in this process (e.g. universal_ble scanned it)
        if let p = central.retrieveConnectedPeripherals(withServices: [Self.flipperSvcUUID])
                          .first(where: { $0.identifier == uuid }) {
            peripherals[uuid] = p
            p.delegate = self
            startConnect(p, result: result)
            return
        }
        // 3. Previously connected — system BT database remembers it
        if let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            peripherals[uuid] = p
            p.delegate = self
            startConnect(p, result: result)
            return
        }
        // 4. Never seen by our manager — brief rescan to cache the peripheral
        guard central.state == .poweredOn else {
            result(FlutterError(code: "BT_UNAVAILABLE", message: "Bluetooth not powered on", details: nil))
            return
        }
        pendingConnects[uuid] = result
        connectScanTargets.insert(uuid)
        central.scanForPeripherals(withServices: [Self.flipperSvcUUID], options: nil)
    }

    private func startConnect(_ p: CBPeripheral, result: @escaping FlutterResult) {
        switch p.state {
        case .connected:
            // Already at system level — nothing to do
            result(nil)
            emit(["type": "connectionChange", "deviceId": p.identifier.uuidString,
                  "connected": true, "error": NSNull()])
        case .connecting:
            pendingConnects[p.identifier] = result
        default:
            pendingConnects[p.identifier] = result
            central.connect(p, options: nil)
        }
    }

    // MARK: - Write-without-response draining

    private func drainNoRspQueue(_ p: CBPeripheral) {
        let s = st(p)
        while !s.noRspQueue.isEmpty && p.canSendWriteWithoutResponse {
            let (ch, data, res) = s.noRspQueue.removeFirst()
            p.writeValue(data, for: ch, type: .withoutResponse)
            res?(nil)
        }
    }

    // MARK: - Method channel handler

    // Flutter calls handle() on the main thread.  We dispatch immediately to
    // bleQueue so the actual logic runs alongside CoreBluetooth callbacks — no
    // concurrent access to shared state.  Results are marshalled back to main
    // because Flutter requires FlutterResult to be called on the main thread.
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let r: FlutterResult = { v in DispatchQueue.main.async { result(v) } }
        bleQueue.async { [weak self] in self?.handleOnQueue(call, result: r) }
    }

    private func handleOnQueue(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {

        case "getState":
            result(centralStateStr())

        case "startScan":
            guard central.state == .poweredOn else {
                result(FlutterError(code: "BT_OFF", message: "Bluetooth not powered on", details: nil))
                return
            }
            let svcFilter = (args["withServices"] as? [String])?.map { CBUUID(string: $0) }
            central.scanForPeripherals(withServices: svcFilter,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            result(nil)

        case "stopScan":
            // Don't stop scan if we're in the middle of a connect-triggered scan
            if connectScanTargets.isEmpty { central.stopScan() }
            result(nil)

        case "getSystemDevices":
            let svcs = ((args["withServices"] as? [String]) ?? []).map { CBUUID(string: $0) }
            let connected = central.retrieveConnectedPeripherals(withServices: svcs)
            for p in connected { peripherals[p.identifier] = p; p.delegate = self }
            result(connected.map { p -> [String: Any] in [
                "deviceId": p.identifier.uuidString,
                "name":     p.name as Any,
                "services": (p.services ?? []).map { $0.uuid.uuidString.lowercased() }
            ]})

        case "getConnectionState":
            guard let id = args["deviceId"] as? String else { result("disconnected"); return }
            result(connStr(peripheral(for: id)?.state ?? .disconnected))

        case "connect":
            guard let id = args["deviceId"] as? String,
                  let uuid = UUID(uuidString: id) else {
                result(FlutterError(code: "INVALID_ARGS", message: "deviceId required", details: nil))
                return
            }
            doConnect(uuid, result: result)

        case "disconnect":
            if let id = args["deviceId"] as? String, let p = peripheral(for: id) {
                pstate.removeValue(forKey: p.identifier)
                pendingDisconnectReasons[p.identifier] = "Disconnect requested by Dart"
                central.cancelPeripheralConnection(p)
            }
            result(nil)

        case "discoverServices":
            guard let id = args["deviceId"] as? String, let p = peripheral(for: id) else {
                result(FlutterError(code: "NOT_FOUND", message: "Peripheral not found", details: nil))
                return
            }
            let s = st(p)
            s.discoveryResult = result
            s.pendingServices = []
            s.charMap = [:]
            p.discoverServices(nil)

        case "requestMtu":
            guard let id = args["deviceId"] as? String, let p = peripheral(for: id) else {
                result(23); return
            }
            // macOS negotiates MTU automatically. Report actual no-response write limit + 3
            // so the Dart side computes the correct chunk size via (mtu - 3).
            result(p.maximumWriteValueLength(for: .withoutResponse) + 3)

        case "subscribe":
            guard let id = args["deviceId"] as? String, let p = peripheral(for: id),
                  let svc = args["serviceUuid"] as? String,
                  let chr = args["charUuid"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing args", details: nil))
                return
            }
            guard let ch = findChar(svc, chr, in: p) else {
                result(FlutterError(code: "NOT_FOUND", message: "Char \(chr) not found", details: nil))
                return
            }
            st(p).pendingSubscribes[ch.uuid] = result
            // CoreBluetooth maps both NOTIFY and INDICATE to the same call;
            // the characteristic's properties determine which is used on the wire.
            p.setNotifyValue(true, for: ch)

        case "unsubscribe":
            if let id = args["deviceId"] as? String, let p = peripheral(for: id),
               let svc = args["serviceUuid"] as? String,
               let chr = args["charUuid"] as? String,
               let ch = findChar(svc, chr, in: p) {
                p.setNotifyValue(false, for: ch)
            }
            result(nil)

        case "write":
            guard let id = args["deviceId"] as? String, let p = peripheral(for: id),
                  let svc = args["serviceUuid"] as? String,
                  let chr = args["charUuid"] as? String,
                  let raw = args["data"] as? FlutterStandardTypedData else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing args", details: nil))
                return
            }
            guard let ch = findChar(svc, chr, in: p) else {
                result(FlutterError(code: "NOT_FOUND", message: "Char \(chr) not found", details: nil))
                return
            }
            let noRsp = args["withoutResponse"] as? Bool ?? false
            let s = st(p)
            if noRsp {
                guard ch.properties.contains(.writeWithoutResponse) else {
                    result(FlutterError(code: "WRITE_UNSUPPORTED", message: "Char \(chr) does not support writeWithoutResponse", details: nil))
                    return
                }
                let maxLength = min(
                    p.maximumWriteValueLength(for: .withoutResponse),
                    Self.flipperAttWritePayloadMax
                )
                guard maxLength > 0 else {
                    result(FlutterError(code: "WRITE_FAILED", message: "Invalid maximum write length", details: nil))
                    return
                }
                var offset = 0
                while offset < raw.data.count {
                    let end = min(offset + maxLength, raw.data.count)
                    let packet = raw.data.subdata(in: offset..<end)
                    let isFinal = end == raw.data.count
                    s.noRspQueue.append((ch, packet, isFinal ? result : nil))
                    offset = end
                }
                if raw.data.isEmpty {
                    result(nil)
                } else {
                    drainNoRspQueue(p)
                }
            } else {
                guard ch.properties.contains(.write) else {
                    result(FlutterError(code: "WRITE_UNSUPPORTED", message: "Char \(chr) does not support write", details: nil))
                    return
                }
                var q = s.rspQueue[ch.uuid] ?? []
                let wasEmpty = q.isEmpty
                q.append((raw.data, result))
                s.rspQueue[ch.uuid] = q
                if wasEmpty { p.writeValue(raw.data, for: ch, type: .withResponse) }
            }

        case "read":
            guard let id = args["deviceId"] as? String, let p = peripheral(for: id),
                  let svc = args["serviceUuid"] as? String,
                  let chr = args["charUuid"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing args", details: nil))
                return
            }
            guard let ch = findChar(svc, chr, in: p) else {
                result(FlutterError(code: "NOT_FOUND", message: "Char \(chr) not found", details: nil))
                return
            }
            st(p).pendingReads[ch.uuid] = result
            p.readValue(for: ch)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension FlipperBlePlugin: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit(["type": "availabilityChange", "available": central.state == .poweredOn])
        // If BT turned off while connects are pending, fail them
        if central.state != .poweredOn {
            let err = FlutterError(code: "BT_UNAVAILABLE", message: "Bluetooth became unavailable", details: nil)
            pendingConnects.values.forEach { $0(err) }
            pendingConnects.removeAll()
            connectScanTargets.removeAll()
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self

        // If we were scanning to satisfy a doConnect() call, connect now and stop scanning
        if connectScanTargets.remove(peripheral.identifier) != nil {
            if connectScanTargets.isEmpty { central.stopScan() }
            if let res = pendingConnects.removeValue(forKey: peripheral.identifier) {
                startConnect(peripheral, result: res)
            }
        }

        let svcUuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
                        .map { $0.uuidString.lowercased() }
        emit(["type":     "scanResult",
              "deviceId": peripheral.identifier.uuidString,
              "name":     peripheral.name as Any,
              "rssi":     RSSI.intValue,
              "services": svcUuids])
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        pendingConnects.removeValue(forKey: id)?(nil)
        emit(["type": "connectionChange", "deviceId": id.uuidString,
              "connected": true, "error": NSNull()])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        let id = peripheral.identifier
        let msg = error?.localizedDescription ?? "Connection failed"
        pendingConnects.removeValue(forKey: id)?(
            FlutterError(code: "CONNECT_FAILED", message: msg, details: nil)
        )
        emit(["type": "connectionChange", "deviceId": id.uuidString,
              "connected": false, "error": msg])
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        let id = peripheral.identifier
        // Fail any in-flight connect attempt
        if let res = pendingConnects.removeValue(forKey: id) {
            res(FlutterError(code: "DISCONNECTED", message: "Peripheral disconnected during connect", details: nil))
        }
        // Discard queued GATT operations — they're no longer valid
        pstate.removeValue(forKey: id)
        let message = pendingDisconnectReasons.removeValue(forKey: id)
            ?? error?.localizedDescription
            ?? "Unexpected peripheral disconnect without CoreBluetooth error"
        emit(["type": "connectionChange",
              "deviceId": id.uuidString,
              "connected": false,
              "error": message])
    }
}

// MARK: - CBPeripheralDelegate

extension FlipperBlePlugin: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let s = st(peripheral)
        guard let res = s.discoveryResult else { return }

        if let err = error {
            s.discoveryResult = nil
            res(FlutterError(code: "DISCOVER_SVC", message: err.localizedDescription, details: nil))
            return
        }

        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            s.discoveryResult = nil
            res([[String: Any]]())
            return
        }

        s.pendingServices = Set(services.map { $0.uuid })
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        let s = st(peripheral)
        s.pendingServices.remove(service.uuid)
        for ch in service.characteristics ?? [] { s.charMap[ch.uuid] = ch }

        guard s.pendingServices.isEmpty, let res = s.discoveryResult else { return }
        s.discoveryResult = nil

        let list: [[String: Any]] = (peripheral.services ?? []).map { svc in
            var entry: [String: Any] = ["uuid": svc.uuid.uuidString.lowercased()]
            entry["characteristics"] = (svc.characteristics ?? []).map { ch -> [String: Any] in
                var m: [String: Any] = propsMap(ch.properties)
                m["uuid"] = ch.uuid.uuidString.lowercased()
                return m
            }
            return entry
        }
        res(list)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        let s = st(peripheral)
        let uuid = characteristic.uuid

        // Pending read response
        if let res = s.pendingReads.removeValue(forKey: uuid) {
            if let err = error {
                res(FlutterError(code: "READ_FAILED", message: err.localizedDescription, details: nil))
            } else {
                res(FlutterStandardTypedData(bytes: characteristic.value ?? Data()))
            }
            return
        }

        // Notification / indication
        guard error == nil, let value = characteristic.value else { return }
        emit(["type":     "valueChange",
              "deviceId": peripheral.identifier.uuidString,
              "charUuid": uuid.uuidString.lowercased(),
              "value":    FlutterStandardTypedData(bytes: value)])
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        let s = st(peripheral)
        let uuid = characteristic.uuid
        guard var q = s.rspQueue[uuid], !q.isEmpty else { return }

        let (_, res) = q.removeFirst()
        if q.isEmpty {
            s.rspQueue.removeValue(forKey: uuid)
        } else {
            s.rspQueue[uuid] = q
            // Immediately start the next queued write
            peripheral.writeValue(q[0].0, for: characteristic, type: .withResponse)
        }

        if let err = error {
            res(FlutterError(code: "WRITE_FAILED", message: err.localizedDescription, details: nil))
        } else {
            res(nil)
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // BLE TX buffer has space — resume the write-without-response queue
        drainNoRspQueue(peripheral)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        let s = st(peripheral)
        guard let res = s.pendingSubscribes.removeValue(forKey: characteristic.uuid) else { return }
        if let err = error {
            res(FlutterError(code: "SUBSCRIBE_FAILED", message: err.localizedDescription, details: nil))
        } else {
            res(nil)
        }
    }
}

// MARK: - FlutterStreamHandler

extension FlipperBlePlugin: FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?,
                         eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
