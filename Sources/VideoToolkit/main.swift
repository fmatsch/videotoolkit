import Foundation

let args = CommandLine.arguments
if args.count > 1 && args[1] == "--cli" {
    let sema = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task.detached {
        code = await CLI.run(Array(args.dropFirst(2)))
        sema.signal()
    }
    sema.wait()
    exit(code)
} else {
    VideoToolkitApp.main()
}
