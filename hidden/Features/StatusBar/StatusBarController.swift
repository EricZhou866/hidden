//
//  StatusBarController.swift
//  vanillaClone
//
//  Created by Thanh Nguyen on 1/30/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

import AppKit

class StatusBarController {
    
    //MARK: - Variables
    private var timer:Timer? = nil
    
    //MARK: - BarItems
        
    private let btnExpandCollapse = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let btnSeparate = NSStatusBar.system.statusItem(withLength: 1)
    private var btnAlwaysHidden:NSStatusItem? = nil
    
    private var btnHiddenLength: CGFloat = 20
    private var btnHiddenCollapseLength: CGFloat = 2000
    
    private var btnAlwaysHiddenLength: CGFloat = Preferences.alwaysHiddenSectionEnabled ? 20 : 0
    private var btnAlwaysHiddenEnableExpandCollapseLength: CGFloat = Preferences.alwaysHiddenSectionEnabled ? 2000 : 0
    
    private let imgIconLine = NSImage(named:NSImage.Name("ic_line"))
    
    private var isCollapsed: Bool {
        // Compare with > rather than == so the state survives updateCollapsedLengths
        // changing btnHiddenCollapseLength while the bar is collapsed (PR #354).
        return self.btnSeparate.length > self.btnHiddenLength
    }
    
    private var isBtnSeparateValidPosition: Bool {
        guard
            let btnExpandCollapseX = self.btnExpandCollapse.button?.getOrigin?.x,
            let btnSeparateX = self.btnSeparate.button?.getOrigin?.x
            else {return false}
        
        if Constant.isUsingLTRLanguage {
            return btnExpandCollapseX >= btnSeparateX
        } else {
            return btnExpandCollapseX <= btnSeparateX
        }
    }
    
    private var isBtnAlwaysHiddenValidPosition: Bool {
        if !Preferences.alwaysHiddenSectionEnabled { return true }
        
        guard
            let btnSeparateX = self.btnSeparate.button?.getOrigin?.x,
            let btnAlwaysHiddenX = self.btnAlwaysHidden?.button?.getOrigin?.x
            else {return false}
        
        if Constant.isUsingLTRLanguage {
            return btnSeparateX >= btnAlwaysHiddenX
        } else {
            return btnSeparateX <= btnAlwaysHiddenX
        }
    }
    
    private var isToggle = false

    // SPEC-003 (macOS 27 hide-mechanism, #360). macOS 27 re-architected the menu
    // bar into a single composited surface, and with it the layout response to an
    // over-long status item: the length is still honored exactly (the separator's
    // window really does become as wide as asked), but an item too long to fit is
    // EJECTED from the layout instead of laid out, and an ejected item pushes
    // nothing. `screenWidth * 2` always lands past that cutoff, so collapsing does
    // nothing at all - the whole bug.
    //
    // The cutoff cannot be computed: it is where the separator would grow past the
    // left edge of the status region (the notch on some Macs, the frontmost app's
    // menus on others), so it moves with the display, with the frontmost app, and
    // with how full the bar already is. It has to be measured on the live bar.
    private var calibratedCollapseLength: CGFloat?
    private var isCalibrating = false
    private var lastCalibrationDate: Date?
    // Bumped whenever a measurement in flight is invalidated (display change), so
    // the async probe chain it belongs to drops out instead of writing a result
    // measured against a menu bar that no longer exists.
    private var calibrationGeneration = 0

    private var hoverMonitor: Any?
    private var hoverDwellTimer: Timer?

    // True while the pointer sits in any screen's menubar band (the strip between
    // visibleFrame.maxY and frame.maxY, which is the menubar's exact height there).
    // On fullscreen spaces the menubar is hidden and the band collapses to ~zero,
    // so this returns false there: intentional, no visible menubar = no deferral.
    private var isMouseInMenuBar: Bool {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
                && mouse.y >= screen.visibleFrame.maxY && mouse.y <= screen.frame.maxY
        }
    }

    // The preferences window is an ordinary app window, not in the menu bar, so
    // the mouse-in-menubar guard does not cover it. With "use full menu bar on
    // expanding" on, an auto-collapse deactivates the app and dismisses this
    // window mid-edit (#170, same family as #66/#151). Defer the collapse while
    // it is on screen. isWindowLoaded short-circuits without force-loading the
    // window when preferences were never opened.
    private var isPreferencesWindowVisible: Bool {
        let wc = PreferencesWindowController.shared
        return wc.isWindowLoaded && (wc.window?.isVisible ?? false)
    }
    
    //MARK: - Methods
    init() {
        updateCollapsedLengths()
        setupUI()
        restoreRemovedStatusItems()
        setupAlwayHideStatusBar()
        setupHoverToExpandIfEnabled()
        NotificationCenter.default.addObserver(self, selector: #selector(handleScreenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.collapseMenuBar()
        }
        
        if Preferences.areSeparatorsHidden {hideSeparators()}
        autoCollapseIfNeeded()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        hoverDwellTimer?.invalidate()
        if let monitor = hoverMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // Opt-in via `defaults write com.dwarvesv.minimalbar hoverToExpand -bool true`.
    // No monitor is installed at all unless the pref is true at launch.
    private func setupHoverToExpandIfEnabled() {
        guard Preferences.hoverToExpand else { return }
        NSLog("HoverToExpand: enabled, installing global mouse monitor")
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self = self else { return }
            guard !self.isCalibrating, self.isCollapsed && self.isMouseInMenuBar else {
                self.hoverDwellTimer?.invalidate()
                self.hoverDwellTimer = nil
                return
            }
            // Short dwell so a pointer merely passing through doesn't expand.
            guard self.hoverDwellTimer == nil else { return }
            self.hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.hoverDwellTimer = nil
                if !self.isCalibrating, self.isCollapsed && self.isMouseInMenuBar {
                    self.expandMenubar()
                }
            }
        }
    }
    
    @objc private func handleScreenParametersChanged() {
        // Re-apply the recomputed length to the LIVE item when collapsed, or a
        // display hot-plug leaves the separator at a stale length (PR #354).
        let wasCollapsed = isCollapsed
        updateCollapsedLengths()
        // A display hot-plug moves the status region, so a length calibrated for
        // the old configuration is meaningless; measure again on the next collapse.
        calibratedCollapseLength = nil
        calibrationGeneration += 1
        isCalibrating = false
        if wasCollapsed {
            applyCollapseLength()
            if Preferences.areSeparatorsHidden {
                btnAlwaysHidden?.length = alwaysHiddenCollapseLength
            }
        }
    }

    private func updateCollapsedLengths() {
        // The menubar replicates across every attached display, so the collapse
        // length must cover the WIDEST screen, not NSScreen.main (the focused one);
        // sizing from a narrower screen leaks hidden icons on wider displays.
        // frame.width, not visibleFrame: the menubar spans the full frame width.
        let screenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1728
        // Keep collapse length bounded to avoid pathological layout/memory behavior;
        // macOS enforces a hard 10,000pt maximum on NSStatusItem.length (PR #354).
        let boundedCollapseLength = max(500, min(screenWidth * 2, 10_000))
        btnHiddenCollapseLength = boundedCollapseLength
        btnAlwaysHiddenEnableExpandCollapseLength = Preferences.alwaysHiddenSectionEnabled ? boundedCollapseLength : 0
    }
    
    private func restoreRemovedStatusItems() {
        // Cmd-dragging a status item off the bar is persisted by macOS via
        // autosaveName, leaving the app running but unreachable. These items are
        // the app's only UI, so they self-restore at launch.
        btnExpandCollapse.isVisible = true
        btnSeparate.isVisible = true
    }

    private func setupUI() {
        if let button = btnSeparate.button {
            button.image = self.imgIconLine
        }
        let menu = self.getContextMenu()
        btnSeparate.menu = menu

        updateAutoCollapseMenuTitle()
        
        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
            button.target = self
            
            button.action = #selector(self.btnExpandCollapsePressed(sender:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        btnExpandCollapse.autosaveName = "hiddenbar_expandcollapse";
        btnSeparate.autosaveName = "hiddenbar_separate";
    }
    
    @objc func btnExpandCollapsePressed(sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent {

            let isOptionKeyPressed = event.modifierFlags.contains(NSEvent.ModifierFlags.option)

            if event.type == NSEvent.EventType.leftMouseUp && !isOptionKeyPressed{
                self.expandCollapseIfNeeded()
            } else if event.type == NSEvent.EventType.rightMouseUp && !isOptionKeyPressed {
                // Right-click opens the same context menu the separator has (#356),
                // making settings reachable from the control everyone clicks.
                // The separators/always-hidden toggle stays on option-click.
                showContextMenu(from: sender)
            } else {
                // Both option+left and option+right land here: separators toggle.
                self.showHideSeparatorsAndAlwayHideArea()
            }
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        guard let menu = btnSeparate.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
    }
    
    func showHideSeparatorsAndAlwayHideArea() {
        if isCalibrating {return}
        Preferences.areSeparatorsHidden ? self.showSeparators() : self.hideSeparators()
        
        if self.isCollapsed {self.expandMenubar()}
    }
    
    private func showSeparators() {
        Preferences.areSeparatorsHidden = false
        
        if !self.isCollapsed {
            self.btnSeparate.length = self.btnHiddenLength
        }
        self.btnAlwaysHidden?.length = self.btnAlwaysHiddenLength
    }
    
    private func hideSeparators() {
        guard self.isBtnAlwaysHiddenValidPosition else {return}
        
        Preferences.areSeparatorsHidden = true
        
        if !self.isCollapsed {
            self.btnSeparate.length = self.btnHiddenLength
        }
        self.btnAlwaysHidden?.length = self.alwaysHiddenCollapseLength
    }
    
    func expandCollapseIfNeeded() {
        // isCollapsed is derived from the separator's length, which sweeps through
        // the probe widths while calibrating, so a toggle would read the wrong
        // state. The measurement is sub-second and runs once per configuration.
        if isCalibrating {return}
        //prevented rapid click cause icon show many in Dock
        if isToggle {return}
        isToggle = true
        self.isCollapsed ? self.expandMenubar() : self.collapseMenuBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isToggle = false
        }
    }
    
    private func collapseMenuBar() {
        guard self.isBtnSeparateValidPosition && !self.isCollapsed else {
            autoCollapseIfNeeded()
            return
        }

        applyCollapseLength()
        if let button = btnExpandCollapse.button {
            button.image = Assets.expandImage
        }
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.accessory)
            NSApp.deactivate()
        }
    }
    private func expandMenubar() {
        guard self.isCollapsed else {return}
        btnSeparate.length = btnHiddenLength
        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
        }
        autoCollapseIfNeeded()
        
        if Preferences.useFullStatusBarOnExpandEnabled {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            
        }
    }
    
    private func autoCollapseIfNeeded() {
        guard Preferences.isAutoHide else {return}
        guard !isCollapsed else { return }

        startTimerToAutoHide()
    }

    // macOS 27+ ejects an over-long status item from the menu bar layout instead
    // of laying it out, so the collapse length has to be measured there. Older
    // systems reflow around any length and keep the computed one.
    private static var menuBarEjectsOverlongItems: Bool {
        // Deliberately a runtime version read, not #available: the SDK this app is
        // built against need not know about macOS 27 for the check to be correct.
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    // Layout is applied asynchronously by the menu bar host; reading a frame
    // sooner than this returns the pre-layout value, which reads as "ejected" and
    // would collapse the calibration onto its lower bound (= no hiding at all).
    private static let layoutSettleDelay: TimeInterval = 0.12
    // How far the separator's arrow-facing edge may drift while still laid out.
    private static let ejectionTolerance: CGFloat = 8
    private static let calibrationPrecision: CGFloat = 8
    private static let minimumCalibrationInterval: TimeInterval = 5
    // Headroom kept below the measured cutoff, roughly one icon's width. The two
    // failure modes are not symmetric: overshooting ejects the separator and hides
    // NOTHING, while undershooting only leaves the icons nearest the separator
    // showing. Icons another app adds after the measurement move the cutoff down,
    // which is what the headroom buys.
    //
    // Both bounds were measured on 27.0 (26A428) against a second process holding
    // the hidden-zone icons:
    //   - at the bare cutoff (margin 0, applied 1031 of 1031) two icons added
    //     afterwards ejected the separator and hiding stopped completely;
    //     applying 979 (margin 52) in the same bar hid them.
    //   - with too much headroom (margin 120, applied 739 of 859) the icon nearest
    //     the separator stayed visible; that bar needed 764.
    // 60pt is the value that satisfies both, and margins of 30-200 all hid
    // cleanly in the bars where there was room to spare.
    private static let ejectionSafetyMargin: CGFloat = 60
    private static let ejectionSafetyFraction: CGFloat = 0.06

    private var alwaysHiddenCollapseLength: CGFloat {
        guard Preferences.alwaysHiddenSectionEnabled else { return 0 }
        guard StatusBarController.menuBarEjectsOverlongItems else { return btnAlwaysHiddenEnableExpandCollapseLength }
        // The always-hidden separator sits further left and therefore has its own,
        // smaller cutoff; the regular separator's measurement is reused as a proxy
        // rather than flickering the bar a second time. Worst case it is ejected,
        // which costs hiding in that section but nothing else.
        return calibratedCollapseLength ?? btnAlwaysHiddenEnableExpandCollapseLength
    }

    // The separator grows away from the arrow, so while it is laid out the edge
    // facing the arrow stays put. An ejected item is placed by itself instead, and
    // that edge jumps out by roughly the requested length - the one signal that
    // separates the two states. The item's own width tracks the request in BOTH
    // states and cannot be used.
    private var separatorArrowFacingEdge: CGFloat? {
        guard let button = btnSeparate.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return Constant.isUsingLTRLanguage ? frame.maxX : frame.minX
    }

    private func isSeparatorEjected(baseline: CGFloat) -> Bool {
        guard let edge = separatorArrowFacingEdge else { return true }
        if Constant.isUsingLTRLanguage {
            return edge > baseline + StatusBarController.ejectionTolerance
        } else {
            return edge < baseline - StatusBarController.ejectionTolerance
        }
    }

    private func afterLayoutSettles(_ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + StatusBarController.layoutSettleDelay, execute: work)
    }

    private func applyCollapseLength() {
        guard StatusBarController.menuBarEjectsOverlongItems else {
            btnSeparate.length = btnHiddenCollapseLength
            return
        }
        guard let calibrated = calibratedCollapseLength else {
            // Not measured yet: the calibration itself ends by applying its result,
            // so it performs this collapse. Without a backing window there is
            // nothing to measure against, so fall back to the computed length and
            // let the next collapse try again - it keeps the length, the arrow
            // image and the derived isCollapsed state consistent.
            if btnSeparate.button?.window == nil {
                btnSeparate.length = btnHiddenCollapseLength
            } else {
                calibrateCollapseLength()
            }
            return
        }
        btnSeparate.length = calibrated
        // The cutoff moves whenever the bar's contents change, so a length that
        // was good when measured can be ejected by the time it is applied again.
        // Writing the length forces a re-layout, which is what makes this read
        // trustworthy: a read taken WITHOUT changing the length returns the last
        // computed frame and would report a stale "fine".
        afterLayoutSettles { [weak self] in
            guard let self = self, self.isCollapsed, !self.isCalibrating else { return }
            guard let baseline = self.calibrationBaseline,
                  self.isSeparatorEjected(baseline: baseline) else { return }
            // Rate-limited so a bar that genuinely cannot fit the separator does
            // not thrash: the next collapse will try again.
            if let last = self.lastCalibrationDate,
               Date().timeIntervalSince(last) < StatusBarController.minimumCalibrationInterval {
                return
            }
            NSLog("HideMechanism: cached length \(calibrated) is ejected now, re-measuring")
            self.calibratedCollapseLength = nil
            self.calibrateCollapseLength()
        }
    }

    // The arrow-facing edge as measured with the separator at its resting width,
    // i.e. the reference an ejected item departs from.
    private var calibrationBaseline: CGFloat?

    // Binary-search the largest length the menu bar still lays out. Runs once per
    // display configuration; the separator visibly steps through the probe widths
    // for about a second, which is why the result is cached.
    private func calibrateCollapseLength() {
        guard !isCalibrating, btnSeparate.button?.window != nil else { return }
        isCalibrating = true
        calibrationGeneration += 1
        let generation = calibrationGeneration

        btnSeparate.length = btnHiddenLength
        afterLayoutSettles { [weak self] in
            guard let self = self, generation == self.calibrationGeneration else { return }
            guard let baseline = self.separatorArrowFacingEdge else {
                self.isCalibrating = false
                return
            }
            self.calibrationBaseline = baseline

            var low = self.btnHiddenLength
            var high = self.btnHiddenCollapseLength
            var best = self.btnHiddenLength

            func probe() {
                guard high - low > StatusBarController.calibrationPrecision else {
                    self.isCalibrating = false
                    self.calibrationGeneration += 1
                    guard best > self.btnHiddenLength else {
                        // Not even a few points are laid out: this menu bar cannot
                        // hide anything by inflation. Leave the bar expanded and
                        // the arrow honest rather than sitting in a collapsed state
                        // that hides nothing.
                        NSLog("HideMechanism: no length is laid out on this menu bar, hiding unavailable")
                        self.lastCalibrationDate = Date()
                        self.btnSeparate.length = self.btnHiddenLength
                        self.btnExpandCollapse.button?.image = Assets.collapseImage
                        return
                    }
                    let margin = min(StatusBarController.ejectionSafetyMargin,
                                     best * StatusBarController.ejectionSafetyFraction)
                    best -= margin
                    self.calibratedCollapseLength = best
                    self.lastCalibrationDate = Date()
                    NSLog("HideMechanism: calibrated collapse length \(best) (baseline edge \(baseline), ceiling \(self.btnHiddenCollapseLength))")
                    // Land in whichever state the bar was meant to be in: the
                    // calibration is what performs the first collapse.
                    self.btnSeparate.length = best
                    if Preferences.areSeparatorsHidden {
                        self.btnAlwaysHidden?.length = self.alwaysHiddenCollapseLength
                    }
                    return
                }
                let mid = (low + high) / 2
                self.btnSeparate.length = mid
                self.afterLayoutSettles {
                    guard generation == self.calibrationGeneration else { return }
                    if self.isSeparatorEjected(baseline: baseline) {
                        high = mid
                    } else {
                        best = mid
                        low = mid
                    }
                    probe()
                }
            }
            probe()
        }
    }
    
    private func startTimerToAutoHide() {
        timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: Preferences.numberOfSecondForAutoHide, repeats: false) { [weak self] _ in
            guard let self = self, Preferences.isAutoHide else { return }
            // Don't yank the bar shut mid-interaction: while the pointer is in the
            // menubar (hovering, clicking, dragging icons), defer and re-arm.
            // Intentionally unbounded; each re-arm invalidates the previous timer,
            // so deferral never accumulates timers. A measurement in flight defers
            // the same way rather than dropping the pending auto-collapse.
            if self.isCalibrating || self.isMouseInMenuBar || self.isPreferencesWindowVisible {
                self.startTimerToAutoHide()
            } else {
                self.collapseMenuBar()
            }
        }
    }
    
    private func getContextMenu() -> NSMenu {
        let menu = NSMenu()
        
        let prefItem = NSMenuItem(title: "Preferences...".localized, action: #selector(openPreferenceViewControllerIfNeeded), keyEquivalent: "P")
        prefItem.target = self
        menu.addItem(prefItem)
        
        let toggleAutoHideItem = NSMenuItem(title: "Toggle Auto Collapse".localized, action: #selector(toggleAutoHide), keyEquivalent: "t")
        toggleAutoHideItem.target = self
        toggleAutoHideItem.tag = 1
        NotificationCenter.default.addObserver(self, selector: #selector(updateAutoHide), name: .prefsChanged, object: nil)
        menu.addItem(toggleAutoHideItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit".localized, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        return menu
    }
    
    private func updateAutoCollapseMenuTitle() {
        guard let toggleAutoHideItem = btnSeparate.menu?.item(withTag: 1) else { return }
        if Preferences.isAutoHide {
            toggleAutoHideItem.title = "Disable Auto Collapse".localized
        } else {
            toggleAutoHideItem.title = "Enable Auto Collapse".localized
        }
    }
    
    @objc func updateAutoHide() {
        updateAutoCollapseMenuTitle()
        autoCollapseIfNeeded()
    }
    
    @objc func openPreferenceViewControllerIfNeeded() {
        Util.showPrefWindow()
    }
    
    @objc func toggleAutoHide() {
        Preferences.isAutoHide.toggle()
    }
}


//MARK: - Alway hide feature
extension StatusBarController {
    private func setupAlwayHideStatusBar() {
        NotificationCenter.default.addObserver(self, selector: #selector(toggleStatusBarIfNeeded), name: .alwayHideToggle, object: nil)
        toggleStatusBarIfNeeded()
    }
    @objc private func toggleStatusBarIfNeeded() {
        updateCollapsedLengths()

        if Preferences.alwaysHiddenSectionEnabled {
            if let existing = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(existing)
            }
            self.btnAlwaysHidden = NSStatusBar.system.statusItem(withLength: btnAlwaysHiddenLength)
            if let button = btnAlwaysHidden?.button {
                button.image = self.imgIconLine
                button.appearsDisabled = true
            }
            self.btnAlwaysHidden?.autosaveName = "hiddenbar_terminate"
            self.btnAlwaysHidden?.isVisible = true
        } else {
            if let existing = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(existing)
            }
            self.btnAlwaysHidden = nil
        }
    }
}
