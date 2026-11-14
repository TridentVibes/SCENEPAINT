import AppKit
@main struct SourceChecks{
    @MainActor static func main()async throws{
        let mode=CommandLine.arguments.dropFirst().first ?? "all"
        switch mode{
        case "startup":try await MotionStartupChecks.main()
        case "motion":try await MotionChecks.main()
        case "queue":try await FreezeQueueChecks.main()
        case "material":try await V01MaterialRestoreChecks.main()
        case "package":try ProjectPackageChecks.main()
        case "drawing":try await DrawingUpgradeChecks.main()
        case "all":
            try await MotionStartupChecks.main()
            try await MotionChecks.main()
            try await FreezeQueueChecks.main()
            try await V01MaterialRestoreChecks.main()
            try ProjectPackageChecks.main()
            try await DrawingUpgradeChecks.main()
        default:throw SceneError.message("Choose all, startup, motion, queue, material, package or drawing.")
        }
    }
}
