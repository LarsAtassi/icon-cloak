// Usage: swift scripts/ctl.swift collapse|expand|log
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("dev.iconcloak.cmd"), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)
