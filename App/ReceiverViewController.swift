import UIKit
import NetworkExtension
import CoreLocation

final class ReceiverViewController: UIViewController, CLLocationManagerDelegate {
    private let receiver = NativeReceiver()
    private let browserBridge = BrowserBridge()
    private let bluetooth = BLEBootstrap()
    private let sameDevice = SameDeviceProbe()
    private let controlBrowser = CarPlayControlBrowser()
    private let receiverBrowser = TDSCarKitReceiverBrowser()
    private let receiverPicker = UIButton(type: .system)
    private var remoteTarget: TDSCarKitReceiverBrowser.Target?
    private let modeControl = UISegmentedControl(items: ["接收", "本机", "发送到 iPad"])
    private var networkFields: [UIView] = []
    private let nameField = UITextField()
    private let ipField = UITextField()
    private let ssidField = UITextField()
    private let passwordField = UITextField()
    private let channelField = UITextField()
    private var channelRow: UIView!
    private let autoChannelSwitch = UISwitch()
    private var autoChannelRow: UIStackView!
    private let savedWifiButton = UIButton(type: .system)
    private let passwordToggle = UIButton(type: .system)
    private let openNetworkSwitch = UISwitch()
    private let audioSwitch = UISwitch()
    private let driveControl = UISegmentedControl(items: ["左舵", "右舵"])
    private var driveRow: UIView!
    private let networkButton = UIButton(type: .system)
    private let networkSummary = UILabel()
    private let hotspotNote = UILabel()
    private let locationManager = CLLocationManager()
    private var awaitingNetworkPermission = false
    private var fetchingNetwork = false
    private var canDetectWiFiName: Bool { (Bundle.main.object(forInfoDictionaryKey: "TDSWiFiNameDetection") as? String) == "YES" }
    private var settingsStack: UIStackView!
    private var settingsVisible = false
    private let diagnosticsButton = UIButton(type: .system)
    private var diagnosticsStack: UIStackView!
    private let orientationControl = UISegmentedControl(items: ["横屏", "竖屏"])
    private var orientationRow: UIView!
    private let bluetoothSetupSwitch = UISwitch()
    private var bluetoothSetupRow: UIView!
    private var needsNetworkDetails: Bool { modeControl.selectedSegmentIndex != 0 || bluetoothSetupSwitch.isOn }
    private let startButton = UIButton(type: .system)
    private let heading = UILabel()
    private let explanation = UILabel()
    private let statusLabel = UILabel()
    private let connectionHelp = UILabel()
    private let logView = UITextView()
    private let videoSurface = H264Surface()
    private let fullscreenButton = UIButton(type: .system)
    private let forgetPasswordButton = UIButton(type: .system)
    private let passwordStatus = UILabel()
    private var contentStack: UIStackView!
    private var videoHeight: NSLayoutConstraint!
    private var fullscreenContainer: UIView?
    private var fullscreenConstraints: [NSLayoutConstraint] = []
    override var prefersStatusBarHidden: Bool { fullscreenContainer != nil }
    override var prefersHomeIndicatorAutoHidden: Bool { fullscreenContainer != nil }
    private var displayedVideo = false
    private var identity: AccessoryIdentity?
    private var running = false
    private var lines: [String] = []
    private var launchedTransportTest = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !running { modeChanged() }
        #if DEBUG
        if !launchedTransportTest, ProcessInfo.processInfo.arguments.contains("--test-local-transport") {
            launchedTransportTest = true
            modeControl.selectedSegmentIndex = 1; modeChanged(); toggleReceiver()
        }
        #endif
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "CarPlay 车机"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(toggleSettings))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "设置"
        locationManager.delegate = self
        heading.font = .preferredFont(forTextStyle: .largeTitle)
        heading.numberOfLines = 0

        explanation.font = .preferredFont(forTextStyle: .body); explanation.textColor = .secondaryLabel; explanation.numberOfLines = 0
        [heading, explanation, statusLabel, connectionHelp, networkSummary].forEach { $0.adjustsFontForContentSizeCategory = true; $0.lineBreakMode = .byWordWrapping }
        statusLabel.font = .preferredFont(forTextStyle: .headline); statusLabel.numberOfLines = 0
        nameField.text = UserDefaults.standard.string(forKey: "receiverName") ?? "CarPlay 车机"
        ipField.text = ReceiverConfiguration.localIPv4Addresses().first
        ssidField.text = UserDefaults.standard.string(forKey: "wifiSSID")
        ssidField.addTarget(self, action: #selector(networkNameChanged), for: .editingChanged)
        ssidField.addTarget(self, action: #selector(loadWiFiPassword), for: .editingDidEnd)
        channelField.text = String(UserDefaults.standard.object(forKey: "wifiChannel") as? Int ?? 36)
        channelField.keyboardType = .numberPad
        channelRow = field(channelField, title: "Wi-Fi 信道")
        networkFields = [field(nameField, title: "接收器名称"), field(ipField, title: "本机 Wi-Fi IP 地址"),
            field(ssidField, title: "当前连接的 Wi-Fi 名称"), field(passwordField, title: "Wi-Fi 密码"),
            channelRow]
        let openLabel = UILabel(); openLabel.text = "开放网络（无密码）"; openLabel.font = .preferredFont(forTextStyle: .footnote)
        let openRow = UIStackView(arrangedSubviews: [openLabel, openNetworkSwitch]); openRow.spacing = 12
        networkFields.append(openRow)
        let autoLabel = UILabel(); autoLabel.text = "自动尝试信道（中国大陆全部信道）"; autoLabel.font = .preferredFont(forTextStyle: .footnote)
        autoChannelSwitch.isOn = UserDefaults.standard.bool(forKey: "autoChannel")
        autoChannelSwitch.addTarget(self, action: #selector(autoChannelChanged), for: .valueChanged)
        autoChannelRow = UIStackView(arrangedSubviews: [autoLabel, autoChannelSwitch]); autoChannelRow.spacing = 12
        networkFields.append(autoChannelRow)
        audioSwitch.isOn = UserDefaults.standard.object(forKey: "speakerAudio") as? Bool ?? true
        let audioLabel = UILabel(); audioLabel.text = "在本机播放音频"; audioLabel.font = .preferredFont(forTextStyle: .footnote)
        let audioRow = UIStackView(arrangedSubviews: [audioLabel, audioSwitch]); audioRow.spacing = 12
        networkFields.append(audioRow)
        let bluetoothLabel = UILabel(); bluetoothLabel.text = "蓝牙连接（实验性）"; bluetoothLabel.font = .preferredFont(forTextStyle: .footnote)
        bluetoothSetupSwitch.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        bluetoothSetupRow = UIStackView(arrangedSubviews: [bluetoothLabel, bluetoothSetupSwitch])
        (bluetoothSetupRow as? UIStackView)?.spacing = 12
        let storedMode = UserDefaults.standard.object(forKey: "connectionMode") as? Int ?? 2
        modeControl.selectedSegmentIndex = UIDevice.current.userInterfaceIdiom == .phone ? min(2, max(0, storedMode)) : 0
        modeControl.isHidden = UIDevice.current.userInterfaceIdiom == .pad
        modeControl.setEnabled(UIDevice.current.userInterfaceIdiom == .phone, forSegmentAt: 1)
        modeControl.setEnabled(UIDevice.current.userInterfaceIdiom == .phone, forSegmentAt: 2)
        if UIDevice.current.userInterfaceIdiom == .phone, UserDefaults.standard.bool(forKey: "sendToReceiver") {
            modeControl.selectedSegmentIndex = 2
        }
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        connectionHelp.font = .preferredFont(forTextStyle: .body)
        connectionHelp.textColor = .secondaryLabel; connectionHelp.numberOfLines = 0
        receiverPicker.titleLabel?.font = .preferredFont(forTextStyle: .body)
        receiverPicker.setTitleColor(.label, for: .normal)
        receiverPicker.layer.borderWidth = 1
        receiverPicker.layer.borderColor = UIColor.separator.cgColor
        receiverPicker.layer.cornerRadius = 8
        receiverPicker.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        receiverPicker.showsMenuAsPrimaryAction = true
        let stack = UIStackView(arrangedSubviews: [heading, explanation, statusLabel, connectionHelp, receiverPicker])
        settingsStack = UIStackView(arrangedSubviews: [modeControl, bluetoothSetupRow!] + networkFields)
        settingsStack.axis = .vertical; settingsStack.spacing = 16
        settingsStack.isLayoutMarginsRelativeArrangement = true
        settingsStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16)
        settingsStack.backgroundColor = .secondarySystemGroupedBackground; settingsStack.layer.cornerRadius = 20
        settingsStack.isHidden = true
        driveControl.selectedSegmentIndex = (UserDefaults.standard.object(forKey: "rightHandDrive") as? Bool ?? true) ? 1 : 0
        driveControl.addTarget(self, action: #selector(driveChanged), for: .valueChanged)
        let driveLabel = UILabel(); driveLabel.text = "驾驶位"
        let driveStack = UIStackView(arrangedSubviews: [driveLabel, driveControl]); driveStack.axis = .vertical; driveStack.spacing = 8
        driveRow = driveStack; settingsStack.insertArrangedSubview(driveStack, at: 1)
        networkButton.setTitle("检测当前 Wi-Fi", for: .normal)
        networkButton.addTarget(self, action: #selector(detectNetwork), for: .touchUpInside)
        settingsStack.insertArrangedSubview(networkButton, at: 2)
        networkSummary.font = .preferredFont(forTextStyle: .footnote); networkSummary.textColor = .secondaryLabel; networkSummary.numberOfLines = 0
        stack.addArrangedSubview(networkSummary)
        hotspotNote.font = .preferredFont(forTextStyle: .footnote); hotspotNote.textColor = .secondaryLabel; hotspotNote.numberOfLines = 0
        hotspotNote.text = "iPhone 热点：请在设置中开启个人热点并让 iPad 连接它；同时为 CarPlay 握手保留一份 Wi-Fi 配置。热点密码由 iOS 管理。"
        settingsStack.addArrangedSubview(hotspotNote)
        contentStack = stack
        orientationControl.selectedSegmentIndex = UserDefaults.standard.bool(forKey: "portraitDisplay") ? 1 : 0
        orientationControl.addTarget(self, action: #selector(orientationChanged), for: .valueChanged)
        let orientationLabel = UILabel(); orientationLabel.text = "CarPlay 方向"
        let orientationNote = UILabel(); orientationNote.text = "连接前选择；更改布局需停止后重连。"; orientationNote.numberOfLines = 0
        orientationNote.font = .preferredFont(forTextStyle: .footnote); orientationNote.textColor = .secondaryLabel
        let orientationStack = UIStackView(arrangedSubviews: [orientationLabel, orientationControl, orientationNote])
        orientationStack.axis = .vertical; orientationStack.spacing = 8
        orientationRow = orientationStack; settingsStack.insertArrangedSubview(orientationStack, at: 2)
        passwordField.isSecureTextEntry = true
        passwordToggle.setImage(UIImage(systemName: "eye"), for: .normal)
        passwordToggle.addTarget(self, action: #selector(togglePasswordVisibility), for: .touchUpInside)
        passwordField.rightView = passwordToggle
        passwordField.rightViewMode = .always
        ipField.keyboardType = .decimalPad
        let note = UILabel(); note.numberOfLines = 0; note.font = .preferredFont(forTextStyle: .footnote); note.textColor = .secondaryLabel
        note.text = "Wi-Fi 密码会在启动时安全存入本机钥匙串，不会写入日志。"
        settingsStack.addArrangedSubview(note)
        networkFields.append(note)
        passwordStatus.font = .preferredFont(forTextStyle: .footnote); passwordStatus.numberOfLines = 0
        passwordStatus.textColor = .secondaryLabel
        forgetPasswordButton.setTitle("忘记已保存的 Wi-Fi 密码", for: .normal)
        forgetPasswordButton.addTarget(self, action: #selector(forgetWiFiPassword), for: .touchUpInside)
        savedWifiButton.setTitle("已保存的 Wi-Fi", for: .normal)
        savedWifiButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        savedWifiButton.contentHorizontalAlignment = .leading
        savedWifiButton.showsMenuAsPrimaryAction = true
        refreshSavedWifiMenu()
        settingsStack.addArrangedSubview(savedWifiButton)
        settingsStack.addArrangedSubview(passwordStatus); settingsStack.addArrangedSubview(forgetPasswordButton)
        startButton.setTitle("启动接收器", for: .normal)
        startButton.setTitleColor(.white, for: .normal)
        startButton.backgroundColor = view.tintColor
        startButton.layer.cornerRadius = 12
        startButton.contentEdgeInsets = UIEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        startButton.addTarget(self, action: #selector(toggleReceiver), for: .touchUpInside)
        stack.addArrangedSubview(startButton)
        stack.addArrangedSubview(settingsStack)
        videoSurface.isHidden = true
        videoHeight = videoSurface.heightAnchor.constraint(equalTo: videoSurface.widthAnchor, multiplier: displayAspectHeight)
        videoHeight.priority = .defaultLow
        videoHeight.isActive = true
        stack.addArrangedSubview(videoSurface)
        fullscreenButton.setTitle("全屏显示 CarPlay", for: .normal)
        fullscreenButton.addTarget(self, action: #selector(showFullscreen), for: .touchUpInside)
        fullscreenButton.isHidden = true; stack.addArrangedSubview(fullscreenButton)
        logView.isEditable = false; logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.backgroundColor = .secondarySystemBackground; logView.layer.cornerRadius = 12
        logView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        diagnosticsButton.setTitle("显示诊断日志", for: .normal)
        diagnosticsButton.addTarget(self, action: #selector(toggleDiagnostics), for: .touchUpInside)
        let copyButton = UIButton(type: .system); copyButton.setTitle("复制日志", for: .normal)
        copyButton.addTarget(self, action: #selector(copyLog), for: .touchUpInside)
        diagnosticsStack = UIStackView(arrangedSubviews: [logView, copyButton]); diagnosticsStack.axis = .vertical; diagnosticsStack.spacing = 8
        diagnosticsStack.isHidden = true
        settingsStack.addArrangedSubview(diagnosticsButton); settingsStack.addArrangedSubview(diagnosticsStack)
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        preferredWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            preferredWidth, stack.widthAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 720)
        ])
        receiver.onLog = { [weak self] in self?.log($0) }; bluetooth.onLog = { [weak self] in self?.log($0) }
        receiver.onControlConnected = { [weak self] in self?.sameDevice.didConnectControl() }
        receiver.onVideo = { [weak self] data in
            guard let self, self.running else { return }
            do {
                try self.videoSurface.enqueue(accessUnit: data)
                self.browserBridge.push(accessUnit: data)
                self.videoSurface.isHidden = false
                if !self.displayedVideo {
                    self.displayedVideo = true; self.statusLabel.text = "正在接收 CarPlay 视频"
                    self.fullscreenButton.isHidden = false
                    self.log("视频已送达本地显示层")
                    self.showFullscreen()
                }
            } catch { self.log("视频显示错误：\(error)") }
        }
        videoSurface.onLog = { [weak self] in self?.log($0) }
        videoSurface.onTouch = { [weak self] point, down in
            self?.receiver.touch(x: UInt16(clamping: Int(point.x)), y: UInt16(clamping: Int(point.y)), down: down)
        }
        browserBridge.onLog = { [weak self] in self?.log($0) }
        browserBridge.onTouch = { [weak self] x, y, down in
            self?.receiver.touch(x: x, y: y, down: down)
        }
        browserBridge.start(port: 8081)
        log("浏览器显示：在同一局域网浏览器打开 http://\(ReceiverConfiguration.localIPv4Addresses().first ?? "<IP>"):8081")
        receiver.onFailure = { [weak self] in self?.stop() }
        bluetooth.onFailure = { [weak self] message in
            self?.stop()
            self?.statusLabel.text = message
        }
        bluetooth.onAdvertising = { [weak self] in
            guard let self, self.running else { return }
            self.statusLabel.text = "蓝牙广播中 · 等待 iPhone"
        }
        controlBrowser.onLog = { [weak self] in self?.log($0) }
        receiverBrowser.onLog = { [weak self] in self?.log($0) }
        receiverBrowser.onTargets = { [weak self] targets in
            guard let self, !self.running, self.modeControl.selectedSegmentIndex == 2 else { return }
            if let selected = self.remoteTarget, !targets.contains(selected) { self.remoteTarget = nil }
            self.receiverPicker.isEnabled = !targets.isEmpty
            self.receiverPicker.setTitle(self.remoteTarget.map { "\($0.name) · \($0.address)" }
                ?? (targets.isEmpty ? "正在搜索 iPad 接收器…" : "选择 iPad 接收器"), for: .normal)
            self.receiverPicker.menu = UIMenu(children: targets.map { target in
                UIAction(title: target.name) { [weak self] _ in
                    self?.remoteTarget = target
                    self?.receiverPicker.setTitle("\(target.name) · \(target.address)", for: .normal)
                }
            })
        }
        sameDevice.onStage = { [weak self] message in
            guard let self else { return }
            if self.modeControl.selectedSegmentIndex == 2 {
                self.statusLabel.text = message.contains("requested")
                    ? "已请求连接 · 请保持 App 在前台" : "正在连接 iPad…"
            } else { self.statusLabel.text = "正在连接 CarPlay…" }
        }
        sameDevice.onLog = { [weak self] in self?.log($0) }
        sameDevice.onFinished = { [weak self] message in
            self?.stop()
            self?.statusLabel.text = message
        }
        loadIdentity()
        loadWiFiPassword()
        modeChanged()
        #if targetEnvironment(macCatalyst)
        log("在 Mac Catalyst 上运行原生 UIKit target；无外部接收进程")
        #elseif targetEnvironment(simulator)
        log("模拟器：此处不校验蓝牙硬件连接")
        #else
        log("正在原生 iPad/iPhone 上运行")
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(foregrounded), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    private func field(_ input: UITextField, title: String) -> UIView {
        let label = UILabel(); label.text = title; label.font = .preferredFont(forTextStyle: .caption1)
        input.borderStyle = .roundedRect; input.autocorrectionType = .no; input.autocapitalizationType = .none
        let stack = UIStackView(arrangedSubviews: [label, input]); stack.axis = .vertical; stack.spacing = 5
        return stack
    }
    private var displayAspectHeight: CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return 720.0 / 1280.0 }
        let size = view.window?.windowScene?.screen.bounds.size ?? UIScreen.main.bounds.size
        let landscape = min(size.width, size.height) / max(size.width, size.height)
        return orientationControl.selectedSegmentIndex == 1 ? 1 / landscape : landscape
    }
    private func configureDisplay(_ config: inout ReceiverConfiguration) {
        let portrait = UIDevice.current.userInterfaceIdiom == .pad && orientationControl.selectedSegmentIndex == 1
        let aspect = displayAspectHeight
        config.rightHandDrive = driveControl.selectedSegmentIndex == 1
        config.width = portrait ? Int((1280 / aspect / 16).rounded()) * 16 : 1280
        config.height = portrait ? 1280 : Int((1280 * aspect / 16).rounded()) * 16
    }
    @objc private func toggleSettings() {
        settingsVisible.toggle(); settingsStack.isHidden = !settingsVisible
        navigationItem.rightBarButtonItem?.image = UIImage(systemName: settingsVisible ? "xmark" : "gearshape")
        navigationItem.rightBarButtonItem?.accessibilityLabel = settingsVisible ? "关闭设置" : "设置"
        if !settingsVisible { view.endEditing(true) }
    }
    private func revealSettings() { if !settingsVisible { toggleSettings() } }
    @objc private func toggleDiagnostics() {
        diagnosticsStack.isHidden.toggle()
        diagnosticsButton.setTitle(diagnosticsStack.isHidden ? "显示诊断日志" : "隐藏诊断日志", for: .normal)
        if !diagnosticsStack.isHidden { logView.text = lines.joined(separator: "\n") }
    }
    @objc private func driveChanged() {
        UserDefaults.standard.set(driveControl.selectedSegmentIndex == 1, forKey: "rightHandDrive")
    }
    @objc private func orientationChanged() {
        guard !running else { return }
        UserDefaults.standard.set(orientationControl.selectedSegmentIndex == 1, forKey: "portraitDisplay")
        videoHeight.isActive = false
        videoHeight = videoSurface.heightAnchor.constraint(equalTo: videoSurface.widthAnchor, multiplier: displayAspectHeight)
        videoHeight.priority = .defaultLow
        videoHeight.isActive = true
    }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        guard fullscreenContainer != nil else { return .all }
        if UIDevice.current.userInterfaceIdiom == .pad {
            return orientationControl.selectedSegmentIndex == 1 ? .portrait : .landscape
        }
        return .landscape
    }
    @objc private func showFullscreen() {
        guard displayedVideo, fullscreenContainer == nil else { return }
        view.endEditing(true)
        contentStack.removeArrangedSubview(videoSurface); videoSurface.removeFromSuperview(); videoHeight.isActive = false
        let container = UIView(); container.backgroundColor = .black; container.translatesAutoresizingMaskIntoConstraints = false
        fullscreenContainer = container; view.addSubview(container); container.addSubview(videoSurface)
        videoSurface.translatesAutoresizingMaskIntoConstraints = false
        let settings = UIButton(type: .system)
        settings.setImage(UIImage(systemName: "gearshape.fill"), for: .normal)
        settings.tintColor = .white
        settings.backgroundColor = UIColor(white: 0.2, alpha: 0.8)
        settings.layer.cornerRadius = 8
        settings.accessibilityLabel = "CarPlay 车机设置"
        settings.addTarget(self, action: #selector(showConnectionSettings), for: .touchUpInside)
        settings.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(settings)
        fullscreenConstraints = [container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor), container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor), videoSurface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoSurface.trailingAnchor.constraint(equalTo: container.trailingAnchor), videoSurface.topAnchor.constraint(equalTo: container.topAnchor),
            videoSurface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            settings.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            settings.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -8)]
        NSLayoutConstraint.activate(fullscreenConstraints)
        navigationController?.setNavigationBarHidden(true, animated: false)
        setNeedsStatusBarAppearanceUpdate(); setNeedsUpdateOfHomeIndicatorAutoHidden()
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations)) { [weak self] _ in
                self?.log("旋转设备到全屏方向")
            }
        } else {
            let target: UIInterfaceOrientation = UIDevice.current.userInterfaceIdiom == .pad
                ? (orientationControl.selectedSegmentIndex == 1 ? .portrait : .landscapeRight)
                : .landscapeRight
            UIDevice.current.setValue(target.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
    @objc private func showConnectionSettings() { hideFullscreen(); revealSettings() }
    @objc private func hideFullscreen() {
        guard let container = fullscreenContainer else { return }
        NSLayoutConstraint.deactivate(fullscreenConstraints); fullscreenConstraints = []
        videoSurface.removeFromSuperview(); container.removeFromSuperview(); fullscreenContainer = nil
        let index = contentStack.arrangedSubviews.firstIndex(of: fullscreenButton) ?? contentStack.arrangedSubviews.count
        contentStack.insertArrangedSubview(videoSurface, at: index); videoHeight.isActive = true
        navigationController?.setNavigationBarHidden(false, animated: false)
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
        setNeedsStatusBarAppearanceUpdate(); setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
    @objc private func networkNameChanged() {
        passwordField.text = ""; openNetworkSwitch.isOn = false; passwordStatus.text = ""
        refreshNetworkSummary()
    }
    @objc private func loadWiFiPassword() {
        do {
            if let saved = try WiFiCredentials.password(for: ssidField.text ?? "") {
                passwordField.text = saved; openNetworkSwitch.isOn = saved.isEmpty
                passwordStatus.text = "已从钥匙串加载已保存的 Wi-Fi 信息"
            }
        } catch { passwordStatus.text = "无法读取已保存的 Wi-Fi 密码，请在下方输入。" }
    }
    private func refreshNetworkSummary() {
        let address = ReceiverConfiguration.personalHotspotAddress() ?? ReceiverConfiguration.localIPv4Addresses().first
        let hotspot = UIDevice.current.userInterfaceIdiom == .phone && ReceiverConfiguration.personalHotspotAddress() != nil
        if hotspot {
            networkSummary.text = "个人热点已开启 · 本机地址：\(address ?? "未知")"
        } else if let ssid = ssidField.text, !ssid.isEmpty {
            networkSummary.text = "当前 Wi-Fi：\(ssid) · 本机地址：\(address ?? "未知")"
        } else {
            networkSummary.text = "请填写当前 Wi-Fi 名称 · 本机地址：\(address ?? "未知")"
        }
    }
    @objc private func detectNetwork() { refreshCurrentNetwork(requestPermission: true) }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard awaitingNetworkPermission else { return }
        awaitingNetworkPermission = false
        refreshCurrentNetwork(requestPermission: false)
    }
    private func refreshCurrentNetwork(requestPermission: Bool) {
        guard canDetectWiFiName, !running, !fetchingNetwork, needsNetworkDetails else { return }
        if UIDevice.current.userInterfaceIdiom == .phone, ReceiverConfiguration.personalHotspotAddress() != nil {
            loadWiFiPassword(); refreshNetworkSummary(); return
        }
        let authorization = locationManager.authorizationStatus
        if authorization == .notDetermined, requestPermission {
            awaitingNetworkPermission = true; locationManager.requestWhenInUseAuthorization(); return
        }
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            if requestPermission { networkSummary.text = "请在设置中允许定位以检测 Wi-Fi，或手动输入网络。" }
            return
        }
        fetchingNetwork = true
        let previousSSID = ssidField.text
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            DispatchQueue.main.async {
                guard let self else { return }; self.fetchingNetwork = false
                guard !self.running, self.ssidField.text == previousSSID else { return }
                guard let network else {
                    if requestPermission { self.networkSummary.text = "无法获取 Wi-Fi 名称。请保留已保存的配置或手动输入。" }
                    return
                }
                if self.ssidField.text != network.ssid {
                    self.ssidField.text = network.ssid; self.networkNameChanged(); self.loadWiFiPassword()
                }
                self.refreshNetworkSummary()
            }
        }
    }
    @objc private func forgetWiFiPassword() {
        do {
            try WiFiCredentials.forget(ssidField.text ?? ""); passwordField.text = ""
            passwordStatus.text = "已从本机删除已保存的密码"
            refreshSavedWifiMenu()
        } catch { passwordStatus.text = "无法删除已保存的密码。" }
    }
    @objc private func togglePasswordVisibility() {
        passwordField.isSecureTextEntry.toggle()
        passwordToggle.setImage(UIImage(systemName: passwordField.isSecureTextEntry ? "eye" : "eye.slash"), for: .normal)
    }
    @objc private func autoChannelChanged() {
        UserDefaults.standard.set(autoChannelSwitch.isOn, forKey: "autoChannel")
        channelRow.isHidden = autoChannelSwitch.isOn
        channelField.isEnabled = !autoChannelSwitch.isOn
    }
    private func refreshSavedWifiMenu() {
        let ssids = WiFiCredentials.allSSIDs()
        savedWifiButton.isEnabled = !ssids.isEmpty
        savedWifiButton.menu = UIMenu(title: "已保存的 Wi-Fi", children: ssids.map { ssid in
            UIAction(title: ssid) { [weak self] _ in self?.applySavedWiFi(ssid) }
        })
    }
    private func applySavedWiFi(_ ssid: String) {
        ssidField.text = ssid
        if let saved = try? WiFiCredentials.password(for: ssid) {
            passwordField.text = saved ?? ""
            openNetworkSwitch.isOn = (saved ?? "").isEmpty
        }
        passwordStatus.text = "已选择 \(ssid)"
        refreshNetworkSummary()
    }
    private func saveSettings(_ config: ReceiverConfiguration) -> Bool {
        do { if needsNetworkDetails { try WiFiCredentials.save(config.password, for: config.ssid) } }
        catch { statusLabel.text = "无法安全保存 Wi-Fi 密码，请重试。"; return false }
        if needsNetworkDetails {
            passwordStatus.text = "Wi-Fi 密码已存入钥匙串"
            UserDefaults.standard.set(config.ssid, forKey: "wifiSSID")
            UserDefaults.standard.set(Int(config.wifiChannel), forKey: "wifiChannel")
            refreshSavedWifiMenu()
        }
        UserDefaults.standard.set(audioSwitch.isOn, forKey: "speakerAudio")
        if modeControl.selectedSegmentIndex != 2 { UserDefaults.standard.set(config.name, forKey: "receiverName") }
        return true
    }
    private func loadIdentity() {
        do {
            guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Identity") else { return }
            identity = try AccessoryIdentity(certificateChain: Data(contentsOf: folder.appendingPathComponent("certificate.p7b")),
                leafCertificate: Data(contentsOf: folder.appendingPathComponent("leaf.cer")),
                privateKeyX963: Data(contentsOf: folder.appendingPathComponent("private.x963")))
            statusLabel.text = "就绪，可连接"
            log("证书与私钥匹配；ECDSA 自检通过")
        } catch {
            statusLabel.text = "本地身份缺失或无效"; startButton.isEnabled = false
            log("构建前请把附件认证文件放入 .local/Identity。身份错误：\(error.localizedDescription)")
        }
    }
    @objc private func toggleReceiver() {
        if running { stop(); return }
        if !running, modeControl.selectedSegmentIndex != 2 {
            ipField.text = ReceiverConfiguration.personalHotspotAddress() ?? ReceiverConfiguration.localIPv4Addresses().first
        }
        let autoChannel = autoChannelSwitch.isOn && modeControl.selectedSegmentIndex != 2
        let channel: UInt8
        if autoChannel {
            channel = ReceiverConfiguration.chinaChannels.first ?? 36
        } else {
            guard let entered = needsNetworkDetails ? UInt8(channelField.text ?? "") : UInt8(36), (1...196).contains(entered) else {
                revealSettings(); statusLabel.text = "请输入 1 到 196 之间的 Wi-Fi 信道。"; return
            }
            channel = entered
        }
        guard !needsNetworkDetails || openNetworkSwitch.isOn || !(passwordField.text ?? "").isEmpty else {
            statusLabel.text = "请输入 Wi-Fi 密码；如为开放网络请勾选“开放网络”。"
            revealSettings(); passwordField.becomeFirstResponder(); return
        }
        let password = !needsNetworkDetails || openNetworkSwitch.isOn ? "" : (passwordField.text ?? "")
        if modeControl.selectedSegmentIndex == 2 {
            guard let identity, let target = remoteTarget else {
                statusLabel.text = "请先选择 iPad 接收器，并确保两台设备在同一 Wi-Fi。"; return
            }
            let config = ReceiverConfiguration(name: target.name, address: target.address,
                ssid: ssidField.text ?? "", password: password, port: target.port,
                wifiChannel: channel, autoChannel: false, audioEnabled: false, deviceID: target.deviceID)
            do { try config.validate(requiresLocalAddress: false) } catch {
                revealSettings(); statusLabel.text = error.localizedDescription; return
            }
            guard saveSettings(config) else { return }
            view.endEditing(true); running = true; modeControl.isEnabled = false; setEditing(false)
            receiverPicker.isEnabled = false; receiverBrowser.stop()
            UIApplication.shared.isIdleTimerDisabled = true
            startButton.setTitle("停止 iPad 连接", for: .normal)
            log("正在请求本 iPhone 的 CarPlay 到 \(target.name)（\(target.address):\(target.port)）")
            sameDevice.start(configuration: config, identity: identity, expectsLocalControl: false)
            return
        }
        if modeControl.selectedSegmentIndex == 1 {
            guard let identity else { return }
            let bridge = ReceiverConfiguration.personalHotspotAddress()
            if bridge == nil {
                log("未检测到热点桥接接口，改用 127.0.0.1 回环地址请求 CarPlay 会话（实验性）。")
            }
            var config = ReceiverConfiguration(name: nameField.text ?? "CarPlay 车机", address: bridge ?? "127.0.0.1",
                ssid: ssidField.text ?? "", password: password, wifiChannel: channel, autoChannel: autoChannel,
                audioEnabled: audioSwitch.isOn, deviceID: ReceiverConfiguration.persistentDeviceID())
            configureDisplay(&config)
            do { try config.validate() } catch {
                revealSettings(); statusLabel.text = error.localizedDescription; return
            }
            guard saveSettings(config) else { return }
            view.endEditing(true)
            running = true; modeControl.isEnabled = false; setEditing(false)
            startButton.setTitle("停止接收器", for: .normal)
            statusLabel.text = "正在启动本机 CarPlay 接收器…"
            UIApplication.shared.isIdleTimerDisabled = true
            receiver.onListening = { [weak self] port in
                guard let self, self.running else { return }
                var live = config; live.port = port
                self.controlBrowser.start()
                self.sameDevice.start(configuration: live, identity: identity)
            }
            receiver.start(configuration: config, identity: identity)
            return
        }
        guard let identity else { return }
        var config = ReceiverConfiguration(name: nameField.text ?? "CarPlay 车机", address: ipField.text ?? "",
            ssid: ssidField.text ?? "", password: password, wifiChannel: channel, autoChannel: autoChannel,
            audioEnabled: audioSwitch.isOn, deviceID: ReceiverConfiguration.persistentDeviceID())
        configureDisplay(&config)
        do { try config.validate(requiresWiFiCredentials: needsNetworkDetails) } catch {
            statusLabel.text = error.localizedDescription
            log("无法启动：\(error.localizedDescription)")
            revealSettings(); if config.ssid.isEmpty { ssidField.becomeFirstResponder() }
            return
        }
        guard saveSettings(config) else { return }
        view.endEditing(true)
        running = true; modeControl.isEnabled = false; setEditing(false); startButton.setTitle("停止接收器", for: .normal)
        UIApplication.shared.isIdleTimerDisabled = true; statusLabel.text = "正在启动本地监听…"
        receiver.onListening = { [weak self] port in
            guard let self, self.running else { return }
            var live = config; live.port = port
            self.statusLabel.text = "等待你的 iPhone"
            if self.bluetoothSetupSwitch.isOn { self.bluetooth.start(configuration: live) }
        }
        receiver.start(configuration: config, identity: identity)
    }
    private func stop() {
        hideFullscreen(); fullscreenButton.isHidden = true
        displayedVideo = false; videoSurface.reset(); videoSurface.isHidden = true
        browserBridge.reset()
        running = false; receiver.onListening = nil; bluetooth.stop(); sameDevice.stop(); controlBrowser.stop(); receiver.stop()
        receiverBrowser.stop()
        modeControl.isEnabled = true
        UIApplication.shared.isIdleTimerDisabled = false; setEditing(true)
        modeChanged()
        statusLabel.text = identity == nil ? "需要配置" : "已断开"
        log("接收器已停止")
    }
    @objc private func modeChanged() {
        UserDefaults.standard.set(modeControl.selectedSegmentIndex, forKey: "connectionMode")
        let local = modeControl.selectedSegmentIndex == 1
        let remote = modeControl.selectedSegmentIndex == 2
        receiverBrowser.stop(); remoteTarget = nil
        receiverPicker.isHidden = !remote
        if remote {
            receiverPicker.menu = nil; receiverPicker.isEnabled = false
            receiverPicker.setTitle("正在搜索 iPad 接收器…", for: .normal)
            receiverBrowser.start()
        }
        heading.text = remote ? "连接到 iPad" : local ? "在本机运行 CarPlay" : "CarPlay 显示器"
        explanation.text = remote ? "选择 iPad 并把 CarPlay 投到它的屏幕。"
            : local ? "在本设备上显示 CarPlay。" : "从 iPhone 提供导航、音乐与触控。"
        connectionHelp.text = remote
            ? "使用同一 Wi-Fi，或让 iPad 连接本 iPhone 的个人热点。"
            : local ? (ReceiverConfiguration.personalHotspotAddress() == nil
                ? "未检测到热点桥接，将用回环地址尝试；更稳定可开启热点并让设备连上。"
                : "在本 iPhone 启动 CarPlay，连接期间保持 App 前台。")
            : "先在这里启动显示器，再到 iPhone 上打开本应用进行连接。"
        driveRow.isHidden = remote
        hotspotNote.isHidden = !needsNetworkDetails
        networkButton.isHidden = !needsNetworkDetails || !canDetectWiFiName
        refreshNetworkSummary()
        orientationRow.isHidden = remote || UIDevice.current.userInterfaceIdiom != .pad
        bluetoothSetupRow.isHidden = local || remote
        networkFields.enumerated().forEach { index, field in
            let networkDetail = [2, 3, 4, 5, 6, 8].contains(index)
            field.isHidden = ((local || remote) && index < 2) || (remote && index == 7) || (!needsNetworkDetails && networkDetail)
        }
        if autoChannelSwitch.isOn {
            channelRow.isHidden = true
            channelField.isEnabled = false
        }
        savedWifiButton.isHidden = !needsNetworkDetails
        passwordStatus.isHidden = !needsNetworkDetails; forgetPasswordButton.isHidden = !needsNetworkDetails
        startButton.isEnabled = identity != nil
        startButton.setTitle(remote ? "连接到 iPad" : local ? "在本机启动" : "启动 CarPlay 显示器", for: .normal)
        statusLabel.text = identity == nil ? "需要配置" : remote ? "选择显示器" : "就绪"
        refreshCurrentNetwork(requestPermission: false)
    }
    private func setEditing(_ value: Bool) {
        [nameField, ipField, ssidField, passwordField, channelField].forEach { $0.isEnabled = value }
        openNetworkSwitch.isEnabled = value
        audioSwitch.isEnabled = value
        orientationControl.isEnabled = value
        driveControl.isEnabled = value
        networkButton.isEnabled = value
        bluetoothSetupSwitch.isEnabled = value
        forgetPasswordButton.isEnabled = value
        autoChannelSwitch.isEnabled = value
        passwordToggle.isEnabled = value
        if value { refreshSavedWifiMenu() } else { savedWifiButton.isEnabled = false }
    }
    @objc private func foregrounded() {
        guard !running else { return }
        ipField.text = ReceiverConfiguration.personalHotspotAddress() ?? ReceiverConfiguration.localIPv4Addresses().first
        modeChanged()
    }
    @objc private func backgrounded() {
        // 配合 UIBackgroundModes(audio/voip) 保持 CarPlay 会话在后台继续运行，不再停止。
        receiverBrowser.stop()
    }
    @objc private func copyLog() { UIPasteboard.general.string = lines.joined(separator: "\n") }
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lines.append("\(timestamp)  \(message)"); if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        if diagnosticsStack != nil, !diagnosticsStack.isHidden, settingsVisible { logView.text = lines.joined(separator: "\n") }
        if diagnosticsStack != nil, !diagnosticsStack.isHidden, settingsVisible, !logView.text.isEmpty { logView.scrollRangeToVisible(NSRange(location: logView.text.utf16.count - 1, length: 1)) }
        NSLog("[TDSCarKit] %@", message)
    }
}
