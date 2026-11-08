import Foundation

@main struct AppUpdateTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { checks += 1; precondition(value,message) }
    static func run(_ path: String, _ args: [String]) throws {
        let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
        try p.run();p.waitUntilExit();precondition(p.terminationStatus==0)
    }
    static func main() throws {
        let version=AppUpdateVersion("v0.2.30")!
        check(version>AppUpdateVersion("0.2.29")!,"numeric version ordering")
        check(AppUpdateVersion("0.2.10")!>AppUpdateVersion("0.2.9")!,"patch ordering")
        check(AppUpdateVersion("1.0.0")!>AppUpdateVersion("0.99.99")!,"major version ordering")
        for bad in ["", "v", "../0.2.30", "0.2", "0.2.30-beta", "v0.2.x", "0.2.-1"] { check(AppUpdateVersion(bad)==nil,"invalid version rejected") }
        let hash=String(repeating:"a",count:64)
        let name="TingQiao-macOS-arm64-0.2.30.dmg"
        var release:[String:Any]=["tag_name":"v0.2.30","draft":false,"prerelease":false,"html_url":"https://github.com/oswin-creator/tingqiao-realtime-translation/releases/tag/v0.2.30","assets":[["name":name,"size":100,"digest":"sha256:"+hash,"browser_download_url":"https://github.com/oswin-creator/tingqiao-realtime-translation/releases/download/v0.2.30/"+name]]]
        func data(_ value:[String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:value) }
        let offer=try AppUpdateOffer.parse(data(release))
        check(offer.sha256==hash && offer.version==version,"matching Mac asset with pinned SHA")
        for key in ["draft","prerelease"] {
            var bad=release;bad[key]=true
            do { _=try AppUpdateOffer.parse(data(bad));preconditionFailure("unpublished version accepted") } catch { checks += 1 }
        }
        for url in ["http://github.com/oswin-creator/tingqiao-realtime-translation/releases/download/v0.2.30/"+name,"https://evil.example/"+name,"https://github.com/other/repo/releases/download/v0.2.30/"+name,offer.download.absoluteString+"?url=other",offer.download.absoluteString+"#fragment"] {
            check(!AppUpdateOffer.validDownload(URL(string:url)!,version:version,name:name),"wrong update source rejected")
        }
        check(AppUpdateOffer.digest("sha256:"+hash)==hash && AppUpdateOffer.digest("sha256:bad")==nil,"digest validation")
        check(AppUpdateOffer.checksum(Data((hash+"  "+name+"\n").utf8),version:version)==hash,"checksum fallback")
        check(AppUpdateOffer.checksum(Data((hash+"  ../"+name+"\n").utf8),version:version)==nil,"checksum names stay exact")
        release["assets"]=[]
        do { _=try AppUpdateOffer.parse(data(release));preconditionFailure("missing asset accepted") } catch { checks += 1 }

        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("tingqiao-update-tests-\(UUID())")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        func app(_ name:String,_ version:String) throws -> URL {
            let url=root.appendingPathComponent(name+".app")
            try fm.createDirectory(at:url.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
            let info:[String:Any]=["CFBundleIdentifier":"cn.tingqiao.bridge","CFBundleExecutable":"TingQiao","CFBundleShortVersionString":version,"CFBundleVersion":"1","CFBundlePackageType":"APPL"]
            try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:url.appendingPathComponent("Contents/Info.plist"))
            try fm.copyItem(at:URL(fileURLWithPath:"/usr/bin/true"),to:url.appendingPathComponent("Contents/MacOS/TingQiao"))
            try run("/usr/bin/codesign",["--force","--sign","-","--identifier","cn.tingqiao.bridge",url.path])
            return url
        }
        let target=try app("Current","0.2.29"), staged=try app("Staged","0.2.30")
        let privateData=root.appendingPathComponent("records.json");try Data("retained data".utf8).write(to:privateData)
        let previous=try UpdateInstallation.replace(staged:staged,target:target)
        check(try UpdateInstallation.bundleVersion(target)=="0.2.30","new application installed")
        check(try UpdateInstallation.bundleVersion(previous)=="0.2.29","previous application kept for rollback")
        try UpdateInstallation.restore(previous:previous,target:target)
        check(try UpdateInstallation.bundleVersion(target)=="0.2.29","failed launch can restore old application")
        check(try String(contentsOf:privateData)=="retained data","records outside app remain untouched")
        let plist=staged.appendingPathComponent("Contents/Info.plist")
        try Data("tampered".utf8).write(to:plist)
        do { _=try UpdateInstallation.replace(staged:staged,target:target);preconditionFailure("damaged bundle installed") } catch { checks += 1 }
        check(try UpdateInstallation.bundleVersion(target)=="0.2.29","rejected update leaves current app intact")
        print("PASS: \(checks) update metadata, source, checksum and atomic installation checks")
    }
}
