// Ставит APK Runner обработчиком файлов .apk/.xapk по умолчанию.
// Использование: set-default-handler <bundle-id>

import CoreServices
import Foundation

let bundleID = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "dev.smm959.apkrunner"

let status = LSSetDefaultRoleHandlerForContentType(
    "public.archive.apk" as CFString,
    .all,
    bundleID as CFString
)

if status == 0 {
    print("Обработчик .apk/.xapk: \(bundleID)")
} else {
    FileHandle.standardError.write("Не удалось назначить обработчик, код \(status)\n".data(using: .utf8)!)
    exit(1)
}
