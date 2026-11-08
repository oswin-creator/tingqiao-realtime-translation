import Foundation

@main struct SigningContinuityTests {
    static func run(_ arguments: [String]) throws {
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/codesign");p.arguments=arguments
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
        try p.run();p.waitUntilExit();precondition(p.terminationStatus==0)
    }
    static func main() throws {
        let args=CommandLine.arguments
        precondition(args.count==3,"Pass signing identity and keychain path")
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("tingqiao-signature-test-\(UUID())")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        func app(_ name: String,_ version: String,_ identity: String) throws -> URL {
            let app=root.appendingPathComponent(name+".app")
            try fm.createDirectory(at:app.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
            let info:[String:Any]=["CFBundleIdentifier":"cn.tingqiao.bridge","CFBundleExecutable":"TingQiao","CFBundleShortVersionString":version,"CFBundlePackageType":"APPL"]
            try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
            try fm.copyItem(at:URL(fileURLWithPath:"/usr/bin/true"),to:app.appendingPathComponent("Contents/MacOS/TingQiao"))
            var options=["--force","--sign",identity,"--identifier","cn.tingqiao.bridge"]
            if identity != "-" { options += ["--keychain",args[2]] }
            try run(options+[app.path]);return app
        }
        let old=try app("Old","0.2.29",args[1]),new=try app("New","0.2.30",args[1]),other=try app("Adhoc","0.2.31","-")
        try UpdateInstallation.verifyIdentity(from:old,to:new)
        try UpdateInstallation.verifySignature(new)
        do { try UpdateInstallation.verifyIdentity(from:old,to:other);preconditionFailure("different signing identity accepted") }
        catch UpdateInstallation.Failure.identity {}
        try UpdateInstallation.verifyIdentity(from:other,to:new)
        let previous=try UpdateInstallation.replace(staged:new,target:old)
        let version=try UpdateInstallation.bundleVersion(old);precondition(version=="0.2.30")
        try UpdateInstallation.restore(previous:previous,target:old)
        let restored=try UpdateInstallation.bundleVersion(old);precondition(restored=="0.2.29")
        print("PASS: same-certificate update accepted, changed identity rejected, ad-hoc migration allowed, signed install and rollback verified.")
    }
}
