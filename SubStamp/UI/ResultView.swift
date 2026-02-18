import Combine
import CryptoKit
import Photos
import Security
import StoreKit
import SwiftUI
import UIKit

struct ResultView: View {
    let outputURL: URL
    let sourceVideoURL: URL
    let exportPreset: ExportPreset
    var onBackToEdit: (() -> Void)?
    var onStartOver: () -> Void

    @StateObject private var purchaseManager = PurchaseManager()

    @State private var metadata: VideoMetadata?
    @State private var saveStatus: String?
    @State private var isSaving = false
    @State private var hasSavedToPhotos = false
    @State private var showStartOverConfirmation = false
    @State private var quotaSnapshot = SaveShareQuotaStore.Snapshot.initial
    @State private var shareShouldConsumeQuota = false
    @State private var showShareSheet = false
    @State private var showPaywall = false

    @Environment(\.locale) private var locale

    private var videoFingerprint: String {
        SaveShareQuotaStore.fingerprint(for: sourceVideoURL)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.l) {
                if let onBackToEdit {
                    HStack {
                        Button {
                            onBackToEdit()
                        } label: {
                            Label("Back to edit", systemImage: "chevron.left")
                                .font(AppTypography.bodyEmphasis)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        Spacer()
                    }
                }

                WizardHeaderView(
                    step: 4,
                    total: 4,
                    title: "Result",
                    subtitle: "Your subtitled video is ready."
                )

                VideoPreviewView(url: outputURL)
                    .frame(height: 240)

                if let metadata {
                    VStack(alignment: .leading, spacing: AppSpacing.s) {
                        Text("Export details")
                            .font(AppTypography.bodyEmphasis)
                        HStack {
                            Text("Preset")
                            Spacer()
                            Text(exportPreset.rawValue.capitalized)
                        }
                        HStack {
                            Text("Resolution")
                            Spacer()
                            Text("\(Int(metadata.resolution.width)) × \(Int(metadata.resolution.height))")
                        }
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text(TimeFormatting.duration(metadata.duration))
                        }
                        HStack {
                            Text("Estimated size")
                            Spacer()
                            Text(metadata.estimatedSize)
                        }
                    }
                    .font(AppTypography.body)
                    .padding()
                    .background(AppColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                            .stroke(AppColors.cardBorder, lineWidth: 1)
                    )
                }

                if let saveStatus {
                    Text(saveStatus)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }

                if !purchaseManager.hasPremiumAccess {
                    Text("Free users can save to Photos or share up to \(quotaSnapshot.limit) different videos. Each video counts once.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                } else {
                    Text("Premium unlocked: unlimited saves and sharing.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }

                PrimaryButton(
                    title: isSaving ? "Saving..." : "Save to Photos",
                    systemImage: "square.and.arrow.down",
                    isEnabled: !isSaving
                ) {
                    Task { await beginSaveFlow() }
                }

                PrimaryButton(
                    title: "Share",
                    systemImage: "square.and.arrow.up",
                    isEnabled: !isSaving
                ) {
                    Task { await beginShareFlow() }
                }

                PrimaryButton(title: "Start another", systemImage: "arrow.counterclockwise") {
                    if hasSavedToPhotos {
                        onStartOver()
                    } else {
                        showStartOverConfirmation = true
                    }
                }
            }
            .padding(AppSpacing.l)
        }
        .background(AppColors.background)
        .alert(Text(String(localized: "Not saved to Photos", bundle: .forLocale(locale))), isPresented: $showStartOverConfirmation) {
            Button(String(localized: "Continue", bundle: .forLocale(locale)), role: .destructive) { onStartOver() }
            Button(String(localized: "Cancel", bundle: .forLocale(locale)), role: .cancel) {}
        } message: {
            Text(String(localized: "You haven't saved this video to Photos yet. Continue anyway?", bundle: .forLocale(locale)))
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(activityItems: [outputURL]) { completed in
                onShareFinished(completed: completed)
            }
        }
        .sheet(isPresented: $showPaywall) {
            PurchasePaywallView(
                purchaseManager: purchaseManager,
                usedCount: quotaSnapshot.usedCount,
                freeLimit: quotaSnapshot.limit
            ) {
                Task { await refreshQuotaSnapshot() }
            }
        }
        .task {
            metadata = await VideoMetadata.load(from: outputURL)
            await purchaseManager.prepareIfNeeded()
            await refreshQuotaSnapshot()
        }
        .onChange(of: purchaseManager.hasPremiumAccess) { _, _ in
            Task { await refreshQuotaSnapshot() }
        }
    }

    @MainActor
    private func beginSaveFlow() async {
        let decision = await SaveShareQuotaStore.shared.evaluateAccess(
            for: videoFingerprint,
            isPaid: purchaseManager.hasPremiumAccess
        )
        quotaSnapshot = decision.snapshot

        guard decision.isAllowed else {
            saveStatus = "Free save/share limit reached. Please unlock premium to continue."
            showPaywall = true
            return
        }

        saveToPhotos(recordQuotaOnSuccess: decision.shouldConsumeQuota, isPaidAtActionTime: decision.isPaid)
    }

    @MainActor
    private func beginShareFlow() async {
        let decision = await SaveShareQuotaStore.shared.evaluateAccess(
            for: videoFingerprint,
            isPaid: purchaseManager.hasPremiumAccess
        )
        quotaSnapshot = decision.snapshot

        guard decision.isAllowed else {
            saveStatus = "Free save/share limit reached. Please unlock premium to continue."
            showPaywall = true
            return
        }

        shareShouldConsumeQuota = decision.shouldConsumeQuota
        showShareSheet = true
    }

    @MainActor
    private func onShareFinished(completed: Bool) {
        let shouldConsumeQuota = shareShouldConsumeQuota
        shareShouldConsumeQuota = false
        guard completed else { return }
        saveStatus = "Shared successfully."

        Task {
            if shouldConsumeQuota {
                let updated = await SaveShareQuotaStore.shared.recordSuccess(for: videoFingerprint)
                await MainActor.run {
                    quotaSnapshot = updated
                }
            } else {
                await refreshQuotaSnapshot()
            }
        }
    }

    private func saveToPhotos(recordQuotaOnSuccess: Bool, isPaidAtActionTime: Bool) {
        print("[SAVE] saveToPhotos() called")
        print("[SAVE] outputURL: \(outputURL)")
        print("[SAVE] File exists: \(FileManager.default.fileExists(atPath: outputURL.path))")

        let fingerprint = videoFingerprint
        isSaving = true
        saveStatus = String(localized: "Saving to Photos...", bundle: .forLocale(locale))

        // Use a plain Task (not @MainActor) to avoid the Swift 6 libdispatch crash
        Task.detached { [outputURL, recordQuotaOnSuccess, isPaidAtActionTime, fingerprint] in
            print("[SAVE] Detached task started")

            do {
                try await PhotoSaver.saveVideoToPhotos(fileURL: outputURL)
                print("[SAVE] Save completed successfully")

                let latestQuota: SaveShareQuotaStore.Snapshot
                if recordQuotaOnSuccess {
                    latestQuota = await SaveShareQuotaStore.shared.recordSuccess(for: fingerprint)
                } else {
                    latestQuota = await SaveShareQuotaStore.shared.snapshot(for: fingerprint, isPaid: isPaidAtActionTime)
                }

                await MainActor.run {
                    self.isSaving = false
                    self.saveStatus = String(localized: "Saved to Photos!", bundle: .forLocale(self.locale))
                    self.hasSavedToPhotos = true
                    self.quotaSnapshot = latestQuota
                }
            } catch {
                print("[SAVE] Save failed: \(error)")

                await MainActor.run {
                    self.isSaving = false
                    self.saveStatus = String(localized: "Failed:", bundle: .forLocale(self.locale)) + " \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    private func refreshQuotaSnapshot() async {
        quotaSnapshot = await SaveShareQuotaStore.shared.snapshot(
            for: videoFingerprint,
            isPaid: purchaseManager.hasPremiumAccess
        )
    }
}

/// Non-actor helper to avoid Swift 6 MainActor + PHPhotoLibrary crash
/// Uses performChangesAndWait on a dedicated serial queue as recommended workaround
enum PhotoSaveError: Error {
    case notAuthorized
    case fileNotFound
    case saveFailed(Error)
}

final class PhotoSaver: Sendable {
    private static let queue = DispatchQueue(label: "substamp.photos.save")
    
    static func saveVideoToPhotos(fileURL: URL) async throws {
        print("[PhotoSaver] Starting save for: \(fileURL.lastPathComponent)")
        
        // Request authorization (this is fine to do async)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        print("[PhotoSaver] Authorization status: \(status.rawValue)")
        
        guard status == .authorized || status == .limited else {
            throw PhotoSaveError.notAuthorized
        }
        
        // Check file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("[PhotoSaver] ERROR: File not found at \(fileURL.path)")
            throw PhotoSaveError.fileNotFound
        }
        
        print("[PhotoSaver] Calling performChangesAndWait on serial queue...")
        
        // Use performChangesAndWait on a dedicated queue to avoid Swift 6 crash
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try PHPhotoLibrary.shared().performChangesAndWait {
                        print("[PhotoSaver] Inside performChangesAndWait block")
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.shouldMoveFile = false
                        request.addResource(with: .video, fileURL: fileURL, options: options)
                        print("[PhotoSaver] Asset creation request added")
                    }
                    print("[PhotoSaver] performChangesAndWait completed successfully")
                    continuation.resume()
                } catch {
                    print("[PhotoSaver] performChangesAndWait FAILED: \(error)")
                    continuation.resume(throwing: PhotoSaveError.saveFailed(error))
                }
            }
        }
        
        print("[PhotoSaver] Save operation completed")
    }
}

@MainActor
final class PurchaseManager: ObservableObject {
    static let weeklyProductID = "com.huanglisen.SubStamp.pro.weekly.v2"
    static let lifetimeProductID = "com.huanglisen.SubStamp.pro.lifetime"
    static let supportedProductIDs: Set<String> = [weeklyProductID, lifetimeProductID]

    @Published private(set) var products: [Product] = []
    @Published private(set) var hasPremiumAccess = false
    @Published private(set) var hasCheckedEntitlements = false
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isProcessingPurchase = false
    @Published var errorMessage: String?

    private var transactionUpdatesTask: Task<Void, Never>?

    deinit {
        transactionUpdatesTask?.cancel()
    }

    func prepareIfNeeded() async {
        startObservingTransactionUpdatesIfNeeded()
        await refreshEntitlements()
        if products.isEmpty {
            await loadProducts()
        }
    }

    func prepareEntitlementsIfNeeded() async {
        startObservingTransactionUpdatesIfNeeded()
        await refreshEntitlements()
    }

    func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let loaded = try await Product.products(for: Array(Self.supportedProductIDs))
            let order = [Self.weeklyProductID, Self.lifetimeProductID]
            products = loaded.sorted { lhs, rhs in
                let left = order.firstIndex(of: lhs.id) ?? Int.max
                let right = order.firstIndex(of: rhs.id) ?? Int.max
                return left < right
            }
        } catch {
            errorMessage = "Unable to load purchase options. \(error.localizedDescription)"
        }
    }

    func purchase(_ product: Product) async {
        guard !isProcessingPurchase else { return }
        isProcessingPurchase = true
        errorMessage = nil
        defer { isProcessingPurchase = false }

        do {
            let result = try await product.purchase()
            switch result {
            case let .success(verificationResult):
                switch verificationResult {
                case let .verified(transaction):
                    await transaction.finish()
                    await refreshEntitlements()
                case .unverified:
                    errorMessage = "Purchase could not be verified."
                }
            case .pending:
                errorMessage = "Purchase is pending approval."
            case .userCancelled:
                break
            @unknown default:
                errorMessage = "Purchase did not complete."
            }
        } catch {
            errorMessage = "Purchase failed. \(error.localizedDescription)"
        }
    }

    func restorePurchases() async {
        errorMessage = nil
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            errorMessage = "Restore failed. \(error.localizedDescription)"
        }
    }

    func refreshEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else { continue }
            if Self.supportedProductIDs.contains(transaction.productID) {
                unlocked = true
            }
        }
        hasPremiumAccess = unlocked
        hasCheckedEntitlements = true
    }

    private func startObservingTransactionUpdatesIfNeeded() {
        guard transactionUpdatesTask == nil else { return }
        let supportedIDs = Self.supportedProductIDs
        transactionUpdatesTask = Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard case let .verified(transaction) = result else { continue }
                guard supportedIDs.contains(transaction.productID) else { continue }
                await self.refreshEntitlements()
            }
        }
    }
}

actor SaveShareQuotaStore {
    static let shared = SaveShareQuotaStore()
    static let freeLimit = 3

    struct Snapshot: Sendable {
        let usedCount: Int
        let remainingCount: Int
        let limit: Int
        let alreadyCountedForCurrentVideo: Bool

        static let initial = Snapshot(
            usedCount: 0,
            remainingCount: SaveShareQuotaStore.freeLimit,
            limit: SaveShareQuotaStore.freeLimit,
            alreadyCountedForCurrentVideo: false
        )
    }

    struct AccessDecision: Sendable {
        let isAllowed: Bool
        let shouldConsumeQuota: Bool
        let isPaid: Bool
        let snapshot: Snapshot
    }

    private struct PersistedQuota: Codable {
        var usedCount: Int
        var countedFingerprints: Set<String>

        static let empty = PersistedQuota(usedCount: 0, countedFingerprints: [])
    }

    private let keychainService = Bundle.main.bundleIdentifier ?? "com.huanglisen.SubStamp"
    private let keychainAccount = "save-share-quota.v1"

    static func fingerprint(for outputURL: URL) -> String {
        let standardizedPath = outputURL.standardizedFileURL.path
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        let seed = "\(standardizedPath)|\(fileSize)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func evaluateAccess(for fingerprint: String, isPaid: Bool) async -> AccessDecision {
        let stored = loadPersistedQuota()
        let alreadyCounted = stored.countedFingerprints.contains(fingerprint)
        let remaining = max(0, Self.freeLimit - stored.usedCount)

        let snapshot = Snapshot(
            usedCount: stored.usedCount,
            remainingCount: remaining,
            limit: Self.freeLimit,
            alreadyCountedForCurrentVideo: alreadyCounted
        )

        if isPaid {
            return AccessDecision(
                isAllowed: true,
                shouldConsumeQuota: false,
                isPaid: true,
                snapshot: snapshot
            )
        }
        if alreadyCounted {
            return AccessDecision(
                isAllowed: true,
                shouldConsumeQuota: false,
                isPaid: false,
                snapshot: snapshot
            )
        }
        if stored.usedCount < Self.freeLimit {
            return AccessDecision(
                isAllowed: true,
                shouldConsumeQuota: true,
                isPaid: false,
                snapshot: snapshot
            )
        }
        return AccessDecision(
            isAllowed: false,
            shouldConsumeQuota: false,
            isPaid: false,
            snapshot: snapshot
        )
    }

    func snapshot(for fingerprint: String, isPaid: Bool) async -> Snapshot {
        let stored = loadPersistedQuota()
        let alreadyCounted = stored.countedFingerprints.contains(fingerprint)
        let remaining = isPaid ? Self.freeLimit : max(0, Self.freeLimit - stored.usedCount)
        return Snapshot(
            usedCount: stored.usedCount,
            remainingCount: remaining,
            limit: Self.freeLimit,
            alreadyCountedForCurrentVideo: alreadyCounted
        )
    }

    func recordSuccess(for fingerprint: String) async -> Snapshot {
        var stored = loadPersistedQuota()

        if !stored.countedFingerprints.contains(fingerprint) {
            stored.countedFingerprints.insert(fingerprint)
            stored.usedCount += 1
            savePersistedQuota(stored)
        }

        let remaining = max(0, Self.freeLimit - stored.usedCount)
        return Snapshot(
            usedCount: stored.usedCount,
            remainingCount: remaining,
            limit: Self.freeLimit,
            alreadyCountedForCurrentVideo: true
        )
    }

    func totalUsedCount() -> Int {
        loadPersistedQuota().usedCount
    }

    private func loadPersistedQuota() -> PersistedQuota {
        guard
            let data = KeychainStore.readData(
                service: keychainService,
                account: keychainAccount
            ),
            let decoded = try? JSONDecoder().decode(PersistedQuota.self, from: data)
        else {
            return .empty
        }
        return decoded
    }

    private func savePersistedQuota(_ quota: PersistedQuota) {
        guard let data = try? JSONEncoder().encode(quota) else { return }
        KeychainStore.writeData(data, service: keychainService, account: keychainAccount)
    }
}

private enum KeychainStore {
    nonisolated static func readData(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    nonisolated static func writeData(_ data: Data, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var completion: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, _ in
            completion(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct PurchasePaywallView: View {
    @ObservedObject var purchaseManager: PurchaseManager
    let usedCount: Int
    let freeLimit: Int
    var onUnlocked: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let weekly = purchaseManager.product(for: PurchaseManager.weeklyProductID)
        let lifetime = purchaseManager.product(for: PurchaseManager.lifetimeProductID)

        NavigationStack {
            VStack(alignment: .leading, spacing: AppSpacing.m) {
                Text("Unlock Pro")
                    .font(AppTypography.title)
                Text("Free users can save to Photos or share up to \(freeLimit) different videos. Each video counts once. Upgrade to Pro for unlimited saving and sharing.")
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.secondaryText)

                SubscriptionStoreView(productIDs: [PurchaseManager.weeklyProductID]) {
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("Weekly Subscription")
                            .font(AppTypography.bodyEmphasis)
                        Text("Unlimited exports, saving, and sharing. Cancel anytime.")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .subscriptionStorePolicyDestination(url: AppLegal.termsOfUseURL, for: .termsOfService)
                .subscriptionStorePolicyDestination(url: AppLegal.privacyPolicyURL, for: .privacyPolicy)

                if purchaseManager.isLoadingProducts {
                    ProgressView("Loading purchase options...")
                } else if let lifetime {
                    payButton(
                        title: "Lifetime Unlock",
                        subtitle: lifetime.displayPrice
                    ) {
                        Task { await purchaseManager.purchase(lifetime) }
                    }
                }

                Button("Restore Purchases") {
                    Task { await purchaseManager.restorePurchases() }
                }
                .font(AppTypography.bodyEmphasis)
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: AppSpacing.s) {
                    Divider()
                    Text("Subscription details")
                        .font(AppTypography.bodyEmphasis)

                    if let weekly {
                        Text("Weekly subscription (1 week): \(weekly.displayPrice) per week. Auto-renewable.")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    } else {
                        Text("Weekly subscription (1 week): billed weekly. Price will appear once the App Store products load.")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }

                    Text("Payment will be charged to your Apple ID account at confirmation of purchase. Subscription automatically renews unless cancelled at least 24 hours before the end of the current period. Manage or cancel in Settings > Apple ID > Subscriptions.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)

                    HStack {
                        Link("Privacy Policy", destination: AppLegal.privacyPolicyURL)
                        Spacer()
                        Link("Terms of Use (EULA)", destination: AppLegal.termsOfUseURL)
                    }
                    .font(AppTypography.caption)
                }

                if let errorMessage = purchaseManager.errorMessage {
                    Text(errorMessage)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.error)
                }

                Spacer(minLength: 0)
            }
            .padding(AppSpacing.l)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            await purchaseManager.prepareIfNeeded()
        }
        .onChange(of: purchaseManager.hasPremiumAccess) { _, unlocked in
            if unlocked {
                onUnlocked()
                dismiss()
            }
        }
    }

    private func payButton(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(title)
                        .font(AppTypography.bodyEmphasis)
                    Text(subtitle)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                Spacer()
                if purchaseManager.isProcessingPurchase {
                    ProgressView()
                } else {
                    Image(systemName: "lock.open")
                        .font(AppTypography.bodyEmphasis)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(AppSpacing.m)
            .background(AppColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius)
                    .stroke(AppColors.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(purchaseManager.isProcessingPurchase)
    }
}

private enum AppLegal {
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyPolicyURL = URL(string: "https://lisenhuang.vercel.app/privacy-substamp.html")!
}
