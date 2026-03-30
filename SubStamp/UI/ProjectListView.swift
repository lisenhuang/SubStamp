import SwiftUI

struct ProjectListView: View {
    let onOpenProject: (JobModel) -> Void

    @State private var projects: [ProjectSummary] = []
    @State private var pendingDelete: ProjectSummary?
    @State private var pendingRename: ProjectSummary?
    @State private var showClearAllConfirmation = false
    @State private var showClearNonProjectConfirmation = false
    @State private var totalManagedStorageBytes: Int64 = 0
    @State private var totalSavedProjectStorageBytes: Int64 = 0
    @State private var totalNonProjectStorageBytes: Int64 = 0
    @State private var renameText = ""
    @AppStorage(SetupPreferences.projectAutosaveKey) private var projectAutosaveEnabled = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private let jobStore = JobStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.l) {
                    autoSaveCard

                    if projects.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: AppSpacing.m) {
                            ForEach(projects) { project in
                                projectCard(project)
                            }
                        }
                        .padding(AppSpacing.l)
                    }
                }
                .padding(.bottom, AppSpacing.l)
            }
            .background(AppColors.background.ignoresSafeArea())
            .navigationTitle(String(localized: "Projects", bundle: .forLocale(locale)))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Close", bundle: .forLocale(locale))) {
                        dismiss()
                    }
                }
            }
        }
        .task {
            reloadProjects()
        }
        .alert(
            Text(String(localized: "Delete Project?", bundle: .forLocale(locale))),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { project in
            Button(String(localized: "Delete", bundle: .forLocale(locale)), role: .destructive) {
                jobStore.deleteSavedProject(id: project.id)
                reloadProjects()
            }
            Button(String(localized: "Cancel", bundle: .forLocale(locale)), role: .cancel) { }
        } message: { _ in
            Text(String(localized: "This will remove the saved project and its local files.", bundle: .forLocale(locale)))
        }
        .alert(
            Text(String(localized: "Rename Project", bundle: .forLocale(locale))),
            isPresented: Binding(
                get: { pendingRename != nil },
                set: {
                    if !$0 {
                        pendingRename = nil
                        renameText = ""
                    }
                }
            ),
            presenting: pendingRename
        ) { project in
            TextField(String(localized: "Project name", bundle: .forLocale(locale)), text: $renameText)
            Button(String(localized: "Save", bundle: .forLocale(locale))) {
                jobStore.renameSavedProject(id: project.id, to: renameText)
                pendingRename = nil
                renameText = ""
                reloadProjects()
            }
            Button(String(localized: "Cancel", bundle: .forLocale(locale)), role: .cancel) {
                pendingRename = nil
                renameText = ""
            }
        } message: { _ in
            Text(String(localized: "Leave the name empty to use the video file name.", bundle: .forLocale(locale)))
        }
        .alert(Text(String(localized: "Clear All Projects?", bundle: .forLocale(locale))), isPresented: $showClearAllConfirmation) {
            Button(String(localized: "Clear All", bundle: .forLocale(locale)), role: .destructive) {
                jobStore.deleteAllSavedProjects()
                reloadProjects()
            }
            Button(String(localized: "Cancel", bundle: .forLocale(locale)), role: .cancel) { }
        } message: {
            Text(String(localized: "This will remove all saved projects, unfinished drafts, and cached local video files.", bundle: .forLocale(locale)))
        }
        .alert(Text(String(localized: "Clear Non-Project Files?", bundle: .forLocale(locale))), isPresented: $showClearNonProjectConfirmation) {
            Button(String(localized: "Clear Other Files", bundle: .forLocale(locale)), role: .destructive) {
                jobStore.deleteManagedFilesNotBelongingToSavedProjects()
                reloadProjects()
            }
            Button(String(localized: "Cancel", bundle: .forLocale(locale)), role: .cancel) { }
        } message: {
            Text(String(localized: "This will remove unfinished drafts and cached local files that are not referenced by saved projects.", bundle: .forLocale(locale)))
        }
    }

    private var autoSaveCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            Toggle(isOn: $projectAutosaveEnabled) {
                Text(String(localized: "Auto-save projects", bundle: .forLocale(locale)))
                    .font(AppTypography.bodyEmphasis)
                    .foregroundStyle(AppColors.primaryText)
            }
            .onChange(of: projectAutosaveEnabled) { _, newValue in
                SetupPreferences.saveProjectAutosave(newValue)
            }

                Text(String(localized: "When enabled, changes from Preview & Export are saved to Projects automatically.", bundle: .forLocale(locale)))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.secondaryText)

            Divider()

            HStack {
                Text(String(localized: "Total files size", bundle: .forLocale(locale)))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.secondaryText)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: totalManagedStorageBytes, countStyle: .file))
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundStyle(AppColors.primaryText)
            }

            HStack {
                Text(String(localized: "Saved projects size", bundle: .forLocale(locale)))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.secondaryText)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: totalSavedProjectStorageBytes, countStyle: .file))
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundStyle(AppColors.primaryText)
            }

            HStack {
                Text(String(localized: "Other local files", bundle: .forLocale(locale)))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.secondaryText)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: totalNonProjectStorageBytes, countStyle: .file))
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundStyle(AppColors.primaryText)
            }

            Button(role: .destructive) {
                showClearNonProjectConfirmation = true
            } label: {
                Label(String(localized: "Clear Other Files", bundle: .forLocale(locale)), systemImage: "trash.slash")
                    .font(AppTypography.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.s)
            }
            .buttonStyle(.bordered)
            .disabled(totalNonProjectStorageBytes <= 0)

            Button(role: .destructive) {
                showClearAllConfirmation = true
            } label: {
                Label(String(localized: "Clear All", bundle: .forLocale(locale)), systemImage: "trash")
                    .font(AppTypography.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.s)
            }
            .buttonStyle(.bordered)
            .disabled(totalManagedStorageBytes <= 0)
        }
        .padding()
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
        .padding(.horizontal, AppSpacing.l)
        .padding(.top, AppSpacing.l)
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.m) {
            Image(systemName: "folder")
                .font(.system(size: 42))
                .foregroundStyle(AppColors.secondaryText)

            Text(String(localized: "No saved projects yet.", bundle: .forLocale(locale)))
                .font(AppTypography.bodyEmphasis)
                .foregroundStyle(AppColors.primaryText)

            Text(String(localized: "Save a project after transcription or editing to reopen it later.", bundle: .forLocale(locale)))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppSpacing.xl)
    }

    private func projectCard(_ project: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.s) {
            HStack(alignment: .top, spacing: AppSpacing.s) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(project.displayName)
                            .font(AppTypography.bodyEmphasis)
                            .foregroundStyle(AppColors.primaryText)
                            .lineLimit(2)

                        Button {
                            pendingRename = project
                            renameText = project.job.projectName ?? project.displayName
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppColors.secondaryText)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Rename Project", bundle: .forLocale(locale)))
                    }

                    Text(projectSubtitle(project))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }

                Spacer()

                if !project.videoExists {
                    Text(String(localized: "Video missing", bundle: .forLocale(locale)))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.warning)
                }
            }

            Text(projectDetail(project))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.secondaryText)

            HStack {
                Text(String(localized: "Size", bundle: .forLocale(locale)))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.secondaryText)
                Spacer()
                Text(project.formattedDiskUsage)
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundStyle(AppColors.primaryText)
            }

            HStack(spacing: AppSpacing.s) {
                Button {
                    onOpenProject(project.job)
                    dismiss()
                } label: {
                    Label(String(localized: "Open", bundle: .forLocale(locale)), systemImage: "folder")
                        .font(AppTypography.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.s)
                        .foregroundStyle(project.videoExists ? Color.white : AppColors.secondaryText)
                        .background(project.videoExists ? AppColors.accent : AppColors.cardBorder)
                        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius))
                }
                .buttonStyle(.plain)
                .disabled(!project.videoExists)

                Button {
                    pendingDelete = project
                } label: {
                    Label(String(localized: "Delete", bundle: .forLocale(locale)), systemImage: "trash")
                        .font(AppTypography.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.s)
                        .foregroundStyle(AppColors.primaryText)
                        .background(AppColors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppSpacing.controlCornerRadius)
                                .stroke(AppColors.cardBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppSpacing.cardCornerRadius)
                .stroke(AppColors.cardBorder, lineWidth: 1)
        )
    }

    private func projectSubtitle(_ project: ProjectSummary) -> String {
        let audioName = locale.localizedString(forIdentifier: project.job.transcriptionLocale) ?? project.job.transcriptionLocale
        let subtitle1Name = locale.localizedString(forIdentifier: project.job.language1Locale) ?? project.job.language1Locale
        let subtitle2Name: String? = project.job.translationTargetLocale.flatMap {
            locale.localizedString(forIdentifier: $0) ?? $0
        }

        if let subtitle2Name {
            return "\(audioName) -> \(subtitle1Name) + \(subtitle2Name)"
        }
        return "\(audioName) -> \(subtitle1Name)"
    }

    private func projectDetail(_ project: ProjectSummary) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: project.job.updatedAt, relativeTo: Date())
        let cueLabel = String(
            format: String(localized: "%d cues", bundle: .forLocale(locale)),
            project.cueCount
        )
        let status = project.hasTranslatedCues
            ? String(localized: "Translated", bundle: .forLocale(locale))
            : String(localized: "Transcript only", bundle: .forLocale(locale))
        return "\(cueLabel) • \(status) • \(relative)"
    }

    private func reloadProjects() {
        projects = jobStore.loadProjectSummaries()
        totalManagedStorageBytes = jobStore.totalManagedFileDiskUsageBytes()
        totalSavedProjectStorageBytes = jobStore.totalSavedProjectDiskUsageBytes()
        totalNonProjectStorageBytes = jobStore.totalNonProjectManagedDiskUsageBytes()
    }
}
