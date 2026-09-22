// Sends a test command to a dev build of IconCloak (scripts/build-app.sh --dev builds this as build/ctl).
// Usage: build/ctl collapse|expand|log|axdump|pressoverflow|click:x,y|cmddrag:x1,x2|autohide:<s>
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("dev.iconcloak.cmd"), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)
