//
//  CapacitorUpdaterNative.swift
//  CapgoCapacitorUpdater
//
//  Created by Swas Kunakorn on 16/7/24.
//

import Foundation
import Capacitor
import Alamofire
import Version

public class CapacitorUpdaterNative {
    public static let shared :CapacitorUpdaterNative = .init()
    public static var isRunning = false
    public var capacitorUpdater = CapacitorUpdater()
    private let updateUrl = Bundle.main.object(forInfoDictionaryKey: "CAPACITOR_UPDATER_URL") as? String ?? "https://wongnai.com/updates"
    private var currentVersionNative: Version = "0.0.0"
    public let TAG: String = "✨  Capacitor-updater-native:"
    public var versionBuild: String = Bundle.main.versionName ?? ""
    public var appId: String = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
    private let versionCode: String = Bundle.main.versionCode ?? ""
    private let periodCheckDelay = Bundle.main.object(forInfoDictionaryKey: "CAPACITOR_UPDATER_INTERVAL") as? Int ?? 3600 //3600 // 60 minutes
    private let autoUpdate = true
    private var directUpdate = true
    private var backgroundWork: DispatchWorkItem?
    private var taskRunning = false
    private var backgroundTaskID: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
    public var channel: String? = nil
    
    public init() {}
    
    public func update() {
        if CapacitorUpdaterNative.isRunning {
            print("\(self.TAG) Already running will ignore")
            // Already running ignore
            return
        }
        print("\(self.TAG) Running load")
        CapacitorUpdaterNative.isRunning = true
        let versionName = Bundle.main.versionName
        do {
            currentVersionNative = try Version(versionName ?? "0.0.0")
        } catch {
            print("\(TAG) Cannot parse versionName \(versionName)")
        }
        
        self.capacitorUpdater.versionBuild = Bundle.main.versionName ?? ""
        self.capacitorUpdater.appId = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
        self.capacitorUpdater.deviceID = (UserDefaults.standard.string(forKey: "appUUID") ?? UUID().uuidString).lowercased()
        UserDefaults.standard.set( self.capacitorUpdater.deviceID, forKey: "appUUID")
        UserDefaults.standard.synchronize()
        
        print("\(self.TAG) Current bundle: \(self.capacitorUpdater.getCurrentBundle().toJSON())")
        
        capacitorUpdater.autoReset()
        self.cleanupObsoleteVersions()
        self.checkForUpdateAfterDelay()
    }
    
    
    /**
        Reset to builtin version when native version has been upgraded
     */
    private func cleanupObsoleteVersions() {
        var LatestVersionNative: Version = "0.0.0"
        do {
            LatestVersionNative = try Version(UserDefaults.standard.string(forKey: "LatestVersionNative") ?? "0.0.0")
        } catch {
            print("\(TAG) Cannot get version native \(currentVersionNative)")
        }
        if LatestVersionNative != "0.0.0" && self.currentVersionNative.description != LatestVersionNative.description {
            _ = self._reset(toLastSuccessful: false)
            let res = capacitorUpdater.list()
            res.forEach { version in
                print("\(TAG) Deleting obsolete bundle: \(version)")
                let res = capacitorUpdater.delete(id: version.getId())
                if !res {
                    print("\(TAG) Delete failed, id \(version.getId()) doesn't exist")
                }
            }
        }
        UserDefaults.standard.set( self.currentVersionNative.description, forKey: "LatestVersionNative")
        UserDefaults.standard.synchronize()
    }
    
    func _reset(toLastSuccessful: Bool) -> Bool {
        
        let fallback = capacitorUpdater.getFallbackBundle()
        if toLastSuccessful && !fallback.isBuiltin() {
            return capacitorUpdater.set(bundle: fallback)
        }
        print("\(TAG) Resetting to builtin version")
        capacitorUpdater.reset()
        
        return true
    }
    
    private func checkForUpdate() {
        print("\(TAG) checkForUpdate()")
        guard let url = URL(string: self.updateUrl) else {
            print("\(self.TAG) Error no url or wrong format")
            return
        }

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else {
                return
            }
            
            let res = self.capacitorUpdater.getLatest(url: url, channel: self.channel)
            let current = self.capacitorUpdater.getCurrentBundle()
            
            if let error = res.error {
                print("\(self.TAG) Error found " + error)
                return
            }
            
            if res.version != current.getVersionName() {
                print("\(self.TAG) New version found: \(res.version) from current \(current.getVersionName())")
                self.backgroundDownload()
            }
            print("\(self.TAG) Version: \(current.getVersionName()) Result: \(res.version)")
        }
    }
    
    private func checkForUpdateAfterDelay() {
        print("\(self.TAG) checkForUpdateAfterDelay()")
        checkForUpdate() // Run update immediately without delay
        let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(periodCheckDelay), repeats: true) { [weak self] _ in
            guard let self = self else {
                return
            }
            
            print("\(self.TAG) schedule timer with delay: \(self.periodCheckDelay)")
            
            self.checkForUpdate()
        }
        print("\(self.TAG) run loop \(timer.description)")
        RunLoop.current.add(timer, forMode: .default)
    }
    
    private func backgroundDownload() {
        print("\(self.TAG) backgroundDownload()")
        guard let url = URL(string: self.updateUrl) else {
            print("\(self.TAG) Error no url or wrong format")
            return
        }
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else {
                return
            }
            
            self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Finish Download Tasks") { [weak self] in
                // End the task if time expires.
                self?.endBackGroundTask()
            }
            print("\(self.TAG) Check for update via \(self.updateUrl)")
            let res = self.capacitorUpdater.getLatest(url: url, channel: self.channel)
            let current = self.capacitorUpdater.getCurrentBundle()

            if (res.message) != nil {
                print("\(self.TAG) API message: \(res.message ?? "")")
                self.endBackGroundTaskWithNotif(msg: res.message ?? "", latestVersionName: res.version, current: current, error: false)
                return
            }
            let sessionKey = res.sessionKey ?? ""
            guard let downloadUrl = URL(string: res.url) else {
                print("\(self.TAG) Error no url or wrong format")
                self.endBackGroundTaskWithNotif(msg: "Error no url or wrong format", latestVersionName: res.version, current: current)
                return
            }
            let latestVersionName = res.version
            if latestVersionName != "" && current.getVersionName() != latestVersionName {
                do {
                    print("\(self.TAG) New bundle: \(latestVersionName) found. Current is: \(current.getVersionName()).")
                    var nextImpl = self.capacitorUpdater.getBundleInfoByVersionName(version: latestVersionName)
                    if nextImpl == nil || ((nextImpl?.isDeleted()) != nil) {
                        if (nextImpl?.isDeleted()) != nil {
                            print("\(self.TAG) Latest bundle already exists and will be deleted, download will overwrite it.")
                            let res = self.capacitorUpdater.delete(id: nextImpl!.getId(), removeInfo: true)
                            if res {
                                print("\(self.TAG) Delete version deleted: \(nextImpl!.toString())")
                            } else {
                                print("\(self.TAG) Failed to delete failed bundle: \(nextImpl!.toString())")
                            }
                        }
                        nextImpl = try self.capacitorUpdater.download(url: downloadUrl, version: latestVersionName, sessionKey: sessionKey)
                    }
                    guard let next = nextImpl else {
                        print("\(self.TAG) Error downloading file")
                        self.endBackGroundTaskWithNotif(msg: "Error downloading file", latestVersionName: latestVersionName, current: current)
                        return
                    }
                    if next.isErrorStatus() {
                        print("\(self.TAG) Latest version is in error state. Aborting update.")
                        self.endBackGroundTaskWithNotif(msg: "Latest version is in error state. Aborting update.", latestVersionName: latestVersionName, current: current)
                        return
                    }
                    if res.checksum != "" && next.getChecksum() != res.checksum {
                        print("\(self.TAG) Error checksum", next.getChecksum(), res.checksum)
                        self.capacitorUpdater.sendStats(action: "checksum_fail", versionName: next.getVersionName())
                        let id = next.getId()
                        let resDel = self.capacitorUpdater.delete(id: id)
                        if !resDel {
                            print("\(self.TAG) Delete failed, id \(id) doesn't exist")
                        }
                        self.endBackGroundTaskWithNotif(msg: "Error checksum", latestVersionName: latestVersionName, current: current)
                        return
                    }
                    if self.directUpdate {
                        _ = self.capacitorUpdater.set(bundle: next)
                        _ = self._reload()
                        self.directUpdate = false
                        self.endBackGroundTaskWithNotif(msg: "update installed", latestVersionName: latestVersionName, current: current, error: false)
                    } else {
                        _ = self.capacitorUpdater.setNextBundle(next: next.getId())
                        self.endBackGroundTaskWithNotif(msg: "update downloaded, will install next background", latestVersionName: latestVersionName, current: current, error: false)
                    }
                    return
                } catch {
                    print("\(self.TAG) Error downloading file", error.localizedDescription)
                    let current: BundleInfo = self.capacitorUpdater.getCurrentBundle()
                    self.endBackGroundTaskWithNotif(msg: "Error downloading file", latestVersionName: latestVersionName, current: current)
                    return
                }
            } else {
                print("\(self.TAG) No need to update, \(current.getId()) is the latest bundle.")
                self.endBackGroundTaskWithNotif(msg: "No need to update, \(current.getId()) is the latest bundle.", latestVersionName: latestVersionName, current: current, error: false)
                return
            }
        }
    }
    
    private func endBackGroundTask() {
        UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
        self.backgroundTaskID = UIBackgroundTaskIdentifier.invalid
    }
    
    private func endBackGroundTaskWithNotif(msg: String, latestVersionName: String, current: BundleInfo, error: Bool = true) {
        endBackGroundTask()
    }
    
    private func _reload() {
        // not reload
    }
}
